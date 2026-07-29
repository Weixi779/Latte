//
//  LRUFileCache.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import Foundation

private protocol FileCacheRuntimeState: Sendable {
    mutating func start() throws
    mutating func value(
        for filename: FileCacheFilename
    ) throws -> Data?
    mutating func insert(
        _ data: Data,
        for filename: FileCacheFilename
    ) throws
    mutating func removeValue(
        for filename: FileCacheFilename
    ) throws
    mutating func removeAll() throws
}

/// Errors produced by `LRUFileCache` before an underlying file-system error
/// can be reported directly.
public enum LRUFileCacheError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case missingOwnershipMarker
    case invalidOwnershipMarker
    case unexpectedCacheFamily(String)
    case unsupportedFormatVersion(Int)
    case duplicateDirectoryItem(String)
    case nonRegularDirectoryItem(String)
    case unknownDirectoryItem(String)
    case temporaryArtifactCleanupFailed(String)
    case residentRecoveryFailed(String)
    case publishedMetadataUnavailable(String)
    case unavailable
}

/// A persistent `Data` cache whose resident files are ordered by recent use.
///
/// The supplied directory is exclusively owned by the cache. Latte records
/// that ownership with a marker and refuses to modify a non-empty directory
/// whose contents cannot be proven to belong to this cache family.
///
/// Capacity is an observed soft limit based on each resident's allocated file
/// size, with logical size as a fallback. Expiration is instance-wide and is
/// cleaned opportunistically during startup, lookup, and insertion.
public final class LRUFileCache<Key: Hashable>: AsyncCaching {
    public typealias Value = Data
    public typealias StableKeyEncoder = @Sendable (Key) throws -> Data

    /// Instance-wide storage and expiration settings.
    ///
    /// Settings apply uniformly to every resident. Use separate cache
    /// instances when different capacity or expiration behavior is required.
    public struct Configuration: Sendable {
        /// The observed soft capacity in bytes.
        public let maximumDiskUsage: Int

        /// The fraction to which an over-capacity cache is trimmed.
        public let lowWatermark: Double

        /// The fraction above which trimming begins.
        public let highWatermark: Double

        /// The lifetime measured from the latest successful write.
        public let timeToLive: Duration?

        /// The idle lifetime measured from the latest successful read or write.
        public let timeToIdle: Duration?

        /// The minimum interval between persistent access-date updates.
        public let accessTimeUpdateInterval: Duration

        public init(
            maximumDiskUsage: Int,
            lowWatermark: Double = 0.90,
            highWatermark: Double = 0.95,
            timeToLive: Duration? = nil,
            timeToIdle: Duration? = nil,
            accessTimeUpdateInterval: Duration = .zero
        ) {
            self.maximumDiskUsage = maximumDiskUsage
            self.lowWatermark = lowWatermark
            self.highWatermark = highWatermark
            self.timeToLive = timeToLive
            self.timeToIdle = timeToIdle
            self.accessTimeUpdateInterval = accessTimeUpdateInterval
        }
    }

    private struct Resident: Sendable {
        let url: URL
        let allocatedSize: Int
        let writtenDate: Date
        var lastAccessDate: Date
        var lastPersistedAccessDate: Date
    }

    private struct State: FileCacheRuntimeState {
        let directory: URL
        let configuration: Configuration
        let fileAccess: any FileCacheFileAccess
        let wallClock: any FileCacheWallClock
        var residents: [FileCacheFilename: Resident] = [:]
        var recency = LRUList<FileCacheFilename>()
        var observedDiskUsage = 0
        var isAvailable = true

        mutating func start() throws {
            try fileAccess.createDirectory(at: directory)
            var itemURLs = try fileAccess.contentsOfDirectory(at: directory)

            if itemURLs.isEmpty {
                try publishOwnershipMarker()
                itemURLs = try fileAccess.contentsOfDirectory(at: directory)
            } else if !itemURLs.contains(where: {
                $0.lastPathComponent == FileCacheLayout.markerFilename
            }) {
                guard try recoverInterruptedMarkerPublication(from: itemURLs)
                else {
                    throw LRUFileCacheError.missingOwnershipMarker
                }
                itemURLs = try fileAccess.contentsOfDirectory(at: directory)
            }

            let inventory = try validatedInventory(for: itemURLs)
            try removeTemporaryArtifacts(inventory.temporaryArtifacts)
            try rebuildResidents(inventory.residents)
            let now = wallClock.now()
            try removeExpiredResidents(now: now)
            try trimToLowWatermarkIfNeeded(protecting: nil)
        }

        mutating func value(for filename: FileCacheFilename) throws -> Data? {
            try requireAvailable()
            guard var resident = residents[filename] else {
                return nil
            }

            let now = wallClock.now()
            if isExpired(resident, at: now) {
                do {
                    try fileAccess.removeItem(at: resident.url)
                    forgetResident(filename)
                } catch {
                    if isMissingFileError(error) {
                        forgetResident(filename)
                    }
                }
                return nil
            }

            let data: Data
            do {
                data = try fileAccess.readData(at: resident.url)
            } catch {
                if isMissingFileError(error) {
                    forgetResident(filename)
                    return nil
                }
                throw error
            }

            if shouldPersistAccess(
                now: now,
                lastPersisted: resident.lastPersistedAccessDate
            ) {
                do {
                    try fileAccess.setModificationDate(now, at: resident.url)
                    resident.lastPersistedAccessDate = now
                } catch {
                    if isMissingFileError(error) {
                        forgetResident(filename)
                        return data
                    }
                }
            }

            resident.lastAccessDate = now
            residents[filename] = resident
            recency.moveToMostRecent(filename)
            return data
        }

        mutating func insert(
            _ data: Data,
            for filename: FileCacheFilename
        ) throws {
            try requireAvailable()
            guard configuration.maximumDiskUsage > 0,
                  !hasImmediateExpiration,
                  data.count <= highWatermarkLimit
            else {
                return
            }

            let destination = directory.appendingPathComponent(
                filename.rawValue,
                isDirectory: false
            )
            let temporaryName = FileCacheLayout.temporaryArtifactFilename()
            let temporaryURL = directory.appendingPathComponent(
                temporaryName,
                isDirectory: false
            )
            let now = wallClock.now()
            var published = false
            let resident: Resident

            do {
                try fileAccess.writeStagingData(data, to: temporaryURL)
                try fileAccess.setModificationDate(now, at: temporaryURL)
                let temporaryMetadata = try fileAccess.metadata(
                    at: temporaryURL
                )
                let temporarySize = try observedSize(
                    from: temporaryMetadata,
                    filename: temporaryName
                )
                if temporarySize > highWatermarkLimit {
                    try removeTemporaryArtifact(
                        at: temporaryURL,
                        name: temporaryName
                    )
                    return
                }

                if residents[filename] == nil {
                    try fileAccess.moveItem(
                        at: temporaryURL,
                        to: destination
                    )
                } else {
                    try fileAccess.replaceItem(
                        at: destination,
                        with: temporaryURL
                    )
                }
                published = true

                let metadata = try fileAccess.metadata(at: destination)
                resident = try makeResident(
                    url: destination,
                    metadata: metadata
                )
            } catch {
                if published {
                    try discardPublishedCandidateAndReconcile(
                        filename,
                        at: destination
                    )
                } else {
                    do {
                        try fileAccess.removeItem(at: temporaryURL)
                    } catch {
                        if !isMissingFileError(error) {
                            isAvailable = false
                            throw LRUFileCacheError
                                .temporaryArtifactCleanupFailed(
                                    temporaryName
                                )
                        }
                    }
                }

                throw error
            }

            if resident.allocatedSize > highWatermarkLimit {
                try discardPublishedCandidateAndReconcile(
                    filename,
                    at: destination
                )
                return
            }

            recordResident(resident, for: filename)
            try removeExpiredResidents(now: now)
            try trimToLowWatermarkIfNeeded(protecting: filename)
        }

        mutating func removeValue(
            for filename: FileCacheFilename
        ) throws {
            try requireAvailable()
            guard let resident = residents[filename] else {
                return
            }

            do {
                try fileAccess.removeItem(at: resident.url)
            } catch {
                guard isMissingFileError(error) else {
                    throw error
                }
            }
            forgetResident(filename)
        }

        mutating func removeAll() throws {
            try requireAvailable()
            let inventory: FileCacheInventory
            do {
                let itemURLs = try fileAccess.contentsOfDirectory(
                    at: directory
                )
                inventory = try validatedInventory(for: itemURLs)
            } catch {
                isAvailable = false
                throw error
            }

            let inventoriedResidents = Set(inventory.residents)
            let missingResidents = residents.keys.filter {
                !inventoriedResidents.contains($0)
            }
            for filename in missingResidents {
                forgetResident(filename)
            }

            var firstError: (any Error)?

            for filename in inventory.residents {
                let url = directory.appendingPathComponent(
                    filename.rawValue,
                    isDirectory: false
                )

                do {
                    try fileAccess.removeItem(at: url)
                    forgetResident(filename)
                } catch {
                    if isMissingFileError(error) {
                        forgetResident(filename)
                        continue
                    }

                    if residents[filename] == nil {
                        do {
                            let metadata = try fileAccess.metadata(at: url)
                            let resident = try makeResident(
                                url: url,
                                metadata: metadata
                            )
                            recordResident(resident, for: filename)
                        } catch {
                            if !isMissingFileError(error) {
                                isAvailable = false
                            }
                        }
                    }

                    if firstError == nil {
                        firstError = error
                    }
                }
            }

            for name in inventory.temporaryArtifacts {
                let url = directory.appendingPathComponent(
                    name,
                    isDirectory: false
                )
                do {
                    try fileAccess.removeItem(at: url)
                } catch {
                    if isMissingFileError(error) {
                        continue
                    }

                    isAvailable = false
                    if firstError == nil {
                        firstError = LRUFileCacheError
                            .temporaryArtifactCleanupFailed(name)
                    }
                }
            }

            if let firstError {
                throw firstError
            }
        }

        private mutating func publishOwnershipMarker() throws {
            let temporaryName = FileCacheLayout.temporaryArtifactFilename()
            let temporaryURL = directory.appendingPathComponent(
                temporaryName,
                isDirectory: false
            )
            let markerURL = directory.appendingPathComponent(
                FileCacheLayout.markerFilename,
                isDirectory: false
            )

            do {
                try fileAccess.writeStagingData(
                    FileCacheOwnershipMarker.currentData,
                    to: temporaryURL
                )
                try fileAccess.moveItem(at: temporaryURL, to: markerURL)
            } catch {
                do {
                    try fileAccess.removeItem(at: temporaryURL)
                } catch {
                    if !isMissingFileError(error) {
                        throw LRUFileCacheError
                            .temporaryArtifactCleanupFailed(temporaryName)
                    }
                }
                throw error
            }
        }

        private mutating func recoverInterruptedMarkerPublication(
            from itemURLs: [URL]
        ) throws -> Bool {
            guard itemURLs.count == 1,
                  let temporaryURL = itemURLs.first,
                  FileCacheLayout.isTemporaryArtifactFilename(
                      temporaryURL.lastPathComponent
                  )
            else {
                return false
            }

            let metadata = try fileAccess.metadata(at: temporaryURL)
            guard metadata.isRegularFile == true else {
                return false
            }
            let data = try fileAccess.readData(at: temporaryURL)
            guard (try? FileCacheOwnershipMarker.validate(data)) != nil else {
                return false
            }

            let markerURL = directory.appendingPathComponent(
                FileCacheLayout.markerFilename,
                isDirectory: false
            )
            try fileAccess.moveItem(at: temporaryURL, to: markerURL)
            return true
        }

        private func validatedInventory(
            for itemURLs: [URL]
        ) throws -> FileCacheInventory {
            var entries: [FileCacheDirectoryEntry] = []
            entries.reserveCapacity(itemURLs.count)

            for url in itemURLs {
                let name = url.lastPathComponent
                let isMarker = name == FileCacheLayout.markerFilename
                let isKnownArtifact = FileCacheFilename(
                    residentFilename: name
                ) != nil || FileCacheLayout.isTemporaryArtifactFilename(name)

                do {
                    let metadata = try fileAccess.metadata(at: url)
                    entries.append(
                        FileCacheDirectoryEntry(
                            name: name,
                            isRegularFile: metadata.isRegularFile
                        )
                    )
                } catch {
                    guard isMissingFileError(error) else {
                        throw error
                    }
                    if isMarker {
                        throw LRUFileCacheError.missingOwnershipMarker
                    }
                    if !isKnownArtifact {
                        throw LRUFileCacheError.unknownDirectoryItem(name)
                    }
                }
            }

            let inventory: FileCacheInventory
            do {
                inventory = try FileCacheInventoryClassifier.classify(entries)
            } catch let error as FileCacheInventoryError {
                throw mapInventoryError(error)
            }

            let markerURL = directory.appendingPathComponent(
                FileCacheLayout.markerFilename,
                isDirectory: false
            )
            let markerData: Data
            do {
                markerData = try fileAccess.readData(at: markerURL)
            } catch {
                if isMissingFileError(error) {
                    throw LRUFileCacheError.missingOwnershipMarker
                }
                throw error
            }
            do {
                try FileCacheOwnershipMarker.validate(markerData)
            } catch let error as FileCacheMarkerError {
                throw mapMarkerError(error)
            }

            return inventory
        }

        private mutating func removeTemporaryArtifacts(
            _ names: [String]
        ) throws {
            for name in names {
                let url = directory.appendingPathComponent(
                    name,
                    isDirectory: false
                )
                do {
                    try fileAccess.removeItem(at: url)
                } catch {
                    if !isMissingFileError(error) {
                        isAvailable = false
                        throw LRUFileCacheError
                            .temporaryArtifactCleanupFailed(name)
                    }
                }
            }
        }

        private mutating func rebuildResidents(
            _ filenames: [FileCacheFilename]
        ) throws {
            let snapshot = try recoverResidents(filenames)
            residents = snapshot.residents
            recency = snapshot.recency
            observedDiskUsage = snapshot.observedDiskUsage
        }

        private func recoverResidents(
            _ filenames: [FileCacheFilename]
        ) throws -> (
            residents: [FileCacheFilename: Resident],
            recency: LRUList<FileCacheFilename>,
            observedDiskUsage: Int
        ) {
            var recovered: [
                (filename: FileCacheFilename, resident: Resident)
            ] = []
            recovered.reserveCapacity(filenames.count)

            for filename in filenames {
                let url = directory.appendingPathComponent(
                    filename.rawValue,
                    isDirectory: false
                )

                do {
                    let metadata = try fileAccess.metadata(at: url)
                    recovered.append(
                        (
                            filename,
                            try makeResident(url: url, metadata: metadata)
                        )
                    )
                } catch {
                    if isMissingFileError(error) {
                        continue
                    }

                    do {
                        try fileAccess.removeItem(at: url)
                    } catch {
                        if !isMissingFileError(error) {
                            throw LRUFileCacheError
                                .residentRecoveryFailed(filename.rawValue)
                        }
                    }
                }
            }

            recovered.sort {
                if $0.resident.lastAccessDate
                    == $1.resident.lastAccessDate {
                    return $0.filename.rawValue < $1.filename.rawValue
                }
                return $0.resident.lastAccessDate
                    < $1.resident.lastAccessDate
            }

            var residents: [FileCacheFilename: Resident] = [:]
            var recency = LRUList<FileCacheFilename>()
            var observedDiskUsage = 0
            for item in recovered {
                residents[item.filename] = item.resident
                recency.append(item.filename)
                observedDiskUsage += item.resident.allocatedSize
            }

            return (residents, recency, observedDiskUsage)
        }

        private func makeResident(
            url: URL,
            metadata: FileCacheFileMetadata
        ) throws -> Resident {
            guard metadata.isRegularFile == true,
                  let writtenDate = metadata.creationDate,
                  let lastAccessDate = metadata.modificationDate,
                  let size = metadata.allocatedSize ?? metadata.logicalSize,
                  size >= 0
            else {
                throw LRUFileCacheError.publishedMetadataUnavailable(
                    url.lastPathComponent
                )
            }

            return Resident(
                url: url,
                allocatedSize: size,
                writtenDate: writtenDate,
                lastAccessDate: lastAccessDate,
                lastPersistedAccessDate: lastAccessDate
            )
        }

        private func observedSize(
            from metadata: FileCacheFileMetadata,
            filename: String
        ) throws -> Int {
            guard metadata.isRegularFile == true,
                  let size = metadata.allocatedSize ?? metadata.logicalSize,
                  size >= 0
            else {
                throw LRUFileCacheError.publishedMetadataUnavailable(
                    filename
                )
            }
            return size
        }

        private mutating func removeTemporaryArtifact(
            at url: URL,
            name: String
        ) throws {
            do {
                try fileAccess.removeItem(at: url)
            } catch {
                guard isMissingFileError(error) else {
                    isAvailable = false
                    throw LRUFileCacheError
                        .temporaryArtifactCleanupFailed(name)
                }
            }
        }

        private mutating func discardPublishedCandidateAndReconcile(
            _ filename: FileCacheFilename,
            at url: URL
        ) throws {
            do {
                try fileAccess.removeItem(at: url)
            } catch {
                guard isMissingFileError(error) else {
                    isAvailable = false
                    throw LRUFileCacheError.publishedMetadataUnavailable(
                        filename.rawValue
                    )
                }
            }
            forgetResident(filename)

            do {
                let itemURLs = try fileAccess.contentsOfDirectory(
                    at: directory
                )
                let inventory = try validatedInventory(for: itemURLs)
                try removeTemporaryArtifacts(inventory.temporaryArtifacts)
                let snapshot = try recoverResidents(inventory.residents)
                residents = snapshot.residents
                recency = snapshot.recency
                observedDiskUsage = snapshot.observedDiskUsage
            } catch {
                isAvailable = false
                throw error
            }
        }

        private mutating func removeExpiredResidents(
            now: Date
        ) throws {
            guard hasExpiration else {
                return
            }

            for filename in recency.keys {
                guard let resident = residents[filename],
                      isExpired(resident, at: now)
                else {
                    continue
                }

                do {
                    try fileAccess.removeItem(at: resident.url)
                    forgetResident(filename)
                } catch {
                    if isMissingFileError(error) {
                        forgetResident(filename)
                    } else {
                        throw error
                    }
                }
            }
        }

        private mutating func trimToLowWatermarkIfNeeded(
            protecting protectedFilename: FileCacheFilename?
        ) throws {
            guard observedDiskUsage > highWatermarkLimit else {
                return
            }

            while observedDiskUsage > lowWatermarkLimit {
                guard let victim = recency.leastRecentlyUsedKey,
                      victim != protectedFilename,
                      let resident = residents[victim]
                else {
                    return
                }

                do {
                    try fileAccess.removeItem(at: resident.url)
                    forgetResident(victim)
                } catch {
                    if isMissingFileError(error) {
                        forgetResident(victim)
                    } else {
                        throw error
                    }
                }
            }
        }

        private func isExpired(
            _ resident: Resident,
            at now: Date
        ) -> Bool {
            if let timeToLive = configuration.timeToLive,
               now.timeIntervalSince(resident.writtenDate)
                   >= timeToLive.timeInterval {
                return true
            }
            if let timeToIdle = configuration.timeToIdle,
               now.timeIntervalSince(resident.lastAccessDate)
                   >= timeToIdle.timeInterval {
                return true
            }
            return false
        }

        private var hasImmediateExpiration: Bool {
            configuration.timeToLive == .zero
                || configuration.timeToIdle == .zero
        }

        private var hasExpiration: Bool {
            configuration.timeToLive != nil
                || configuration.timeToIdle != nil
        }

        private var lowWatermarkLimit: Int {
            byteLimit(for: configuration.lowWatermark)
        }

        private var highWatermarkLimit: Int {
            byteLimit(for: configuration.highWatermark)
        }

        private func byteLimit(for watermark: Double) -> Int {
            if watermark >= 1 {
                return configuration.maximumDiskUsage
            }
            let scaled = Double(configuration.maximumDiskUsage) * watermark
            if scaled >= Double(Int.max) {
                return .max
            }
            return Int(scaled.rounded(.down))
        }

        private mutating func recordResident(
            _ resident: Resident,
            for filename: FileCacheFilename
        ) {
            if let previous = residents.updateValue(
                resident,
                forKey: filename
            ) {
                observedDiskUsage -= previous.allocatedSize
                recency.moveToMostRecent(filename)
            } else {
                recency.append(filename)
            }
            observedDiskUsage += resident.allocatedSize
        }

        private mutating func forgetResident(
            _ filename: FileCacheFilename
        ) {
            guard let resident = residents.removeValue(forKey: filename)
            else {
                return
            }
            observedDiskUsage -= resident.allocatedSize
            recency.remove(filename)
        }

        private func shouldPersistAccess(
            now: Date,
            lastPersisted: Date
        ) -> Bool {
            let elapsed = now.timeIntervalSince(lastPersisted)
            return elapsed >= configuration.accessTimeUpdateInterval
                .timeInterval
        }

        private func requireAvailable() throws {
            guard isAvailable else {
                throw LRUFileCacheError.unavailable
            }
        }
    }

    private let stableKeyEncoder: StableKeyEncoder
    private let worker: FileCacheWorker<any FileCacheRuntimeState>

    public init(
        directory: URL,
        configuration: Configuration,
        stableKeyEncoder: @escaping StableKeyEncoder
    ) async throws {
        try Self.validate(configuration)

        let state: any FileCacheRuntimeState = State(
            directory: directory,
            configuration: configuration,
            fileAccess: FoundationFileCacheFileAccess(),
            wallClock: SystemFileCacheWallClock()
        )
        let worker = FileCacheWorker(state: state)
        try await worker.perform { state in
            try state.start()
        }

        self.stableKeyEncoder = stableKeyEncoder
        self.worker = worker
    }

    package init(
        directory: URL,
        configuration: Configuration,
        stableKeyEncoder: @escaping StableKeyEncoder,
        fileAccess: any FileCacheFileAccess,
        wallClock: any FileCacheWallClock
    ) async throws {
        try Self.validate(configuration)

        let state: any FileCacheRuntimeState = State(
            directory: directory,
            configuration: configuration,
            fileAccess: fileAccess,
            wallClock: wallClock
        )
        let worker = FileCacheWorker(state: state)
        try await worker.perform { state in
            try state.start()
        }

        self.stableKeyEncoder = stableKeyEncoder
        self.worker = worker
    }

    public func value(for key: Key) async throws -> Data? {
        let filename = try filename(for: key)
        return try await worker.perform { state in
            try state.value(for: filename)
        }
    }

    public func insert(_ value: Data, for key: Key) async throws {
        let filename = try filename(for: key)
        try await worker.perform { state in
            try state.insert(value, for: filename)
        }
    }

    public func removeValue(for key: Key) async throws {
        let filename = try filename(for: key)
        try await worker.perform { state in
            try state.removeValue(for: filename)
        }
    }

    public func removeAll() async throws {
        try await worker.perform { state in
            try state.removeAll()
        }
    }

    private func filename(for key: Key) throws -> FileCacheFilename {
        FileCacheFilename(
            stableKeyMaterial: try stableKeyEncoder(key)
        )
    }

    private static func validate(
        _ configuration: Configuration
    ) throws {
        guard configuration.maximumDiskUsage >= 0 else {
            throw LRUFileCacheError.invalidConfiguration(
                "maximumDiskUsage must be nonnegative"
            )
        }
        guard configuration.lowWatermark > 0,
              configuration.lowWatermark < 1
        else {
            throw LRUFileCacheError.invalidConfiguration(
                "lowWatermark must be greater than zero and less than one"
            )
        }
        guard configuration.highWatermark > 0,
              configuration.highWatermark <= 1
        else {
            throw LRUFileCacheError.invalidConfiguration(
                "highWatermark must be greater than zero and at most one"
            )
        }
        guard configuration.lowWatermark
            < configuration.highWatermark else {
            throw LRUFileCacheError.invalidConfiguration(
                "lowWatermark must be less than highWatermark"
            )
        }
        guard configuration.timeToLive.map({ $0 >= .zero }) ?? true else {
            throw LRUFileCacheError.invalidConfiguration(
                "timeToLive must be nonnegative"
            )
        }
        guard configuration.timeToIdle.map({ $0 >= .zero }) ?? true else {
            throw LRUFileCacheError.invalidConfiguration(
                "timeToIdle must be nonnegative"
            )
        }
        guard configuration.accessTimeUpdateInterval >= .zero else {
            throw LRUFileCacheError.invalidConfiguration(
                "accessTimeUpdateInterval must be nonnegative"
            )
        }
    }
}

extension LRUFileCache: @unchecked Sendable where Key: Sendable {}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1e18
    }
}

private func isMissingFileError(_ error: any Error) -> Bool {
    let cocoaError = error as NSError
    guard cocoaError.domain == NSCocoaErrorDomain else {
        return false
    }

    return cocoaError.code == CocoaError.fileNoSuchFile.rawValue
        || cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
}

private func mapInventoryError(
    _ error: FileCacheInventoryError
) -> LRUFileCacheError {
    switch error {
    case .missingMarker:
        return .missingOwnershipMarker
    case let .duplicateName(name):
        return .duplicateDirectoryItem(name)
    case let .nonRegularItem(name):
        return .nonRegularDirectoryItem(name)
    case let .unknownItem(name):
        return .unknownDirectoryItem(name)
    }
}

private func mapMarkerError(
    _ error: FileCacheMarkerError
) -> LRUFileCacheError {
    switch error {
    case .invalidUTF8, .malformed, .invalidMagic:
        return .invalidOwnershipMarker
    case let .unexpectedFamily(family):
        return .unexpectedCacheFamily(family)
    case let .unsupportedVersion(version):
        return .unsupportedFormatVersion(version)
    }
}
