//
//  LRUFileCacheTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/29.
//

import Foundation
import Testing
@testable import Latte

@Suite("LRU file cache")
struct LRUFileCacheTests {
    @Test("Basic CRUD preserves the ownership marker")
    func basicCRUD() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)

        #expect(try await cache.value(for: "image") == nil)

        try await cache.insert(Data("first".utf8), for: "image")
        #expect(try await cache.value(for: "image") == Data("first".utf8))

        try await cache.insert(Data("second".utf8), for: "image")
        #expect(try await cache.value(for: "image") == Data("second".utf8))

        try await cache.removeValue(for: "image")
        #expect(try await cache.value(for: "image") == nil)

        try await cache.insert(Data("a".utf8), for: "a")
        try await cache.insert(Data("b".utf8), for: "b")
        try await cache.removeAll()

        #expect(try await cache.value(for: "a") == nil)
        #expect(try await cache.value(for: "b") == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    FileCacheLayout.markerFilename
                ).path
            )
        )
        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
    }

    @Test("A restart rebuilds resident state from directory truth")
    func restartRecovery() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let cache = try await makeCache(at: directory)
            try await cache.insert(Data("one".utf8), for: "one")
            try await cache.insert(Data("two".utf8), for: "two")
        }

        let recovered = try await makeCache(at: directory)
        #expect(try await recovered.value(for: "one") == Data("one".utf8))
        #expect(try await recovered.value(for: "two") == Data("two".utf8))
    }

    @Test("A legal directory removes interrupted Latte staging artifacts")
    func cleansInterruptedResidentStaging() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await makeCache(at: directory)
        let stagingURL = directory.appendingPathComponent(
            FileCacheLayout.temporaryArtifactFilename()
        )
        try FoundationFileCacheFileAccess().writeStagingData(
            Data(repeating: 0xAB, count: 64),
            to: stagingURL
        )

        _ = try await makeCache(at: directory)
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
    }

    @Test("Startup ignores resident and staging files that disappear")
    func startupIgnoresDisappearingKnownArtifacts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let residentFilename = FileCacheFilename(
            stableKeyMaterial: Data("resident".utf8)
        )

        do {
            let cache = try await makeCache(at: directory)
            try await cache.insert(Data("value".utf8), for: "resident")
        }

        let stagingName = FileCacheLayout.temporaryArtifactFilename()
        let stagingURL = directory.appendingPathComponent(stagingName)
        try FoundationFileCacheFileAccess().writeStagingData(
            Data("staging".utf8),
            to: stagingURL
        )
        let access = DisappearingInventoryFileAccess(targetNames: [
            residentFilename.rawValue,
            stagingName,
        ])

        let recovered = try await makeCache(
            at: directory,
            fileAccess: access
        )

        #expect(try await recovered.value(for: "resident") == nil)
        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
    }

    @Test("Startup fails closed when the marker disappears during scan")
    func startupRejectsDisappearingMarker() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await makeCache(at: directory)
        let access = DisappearingInventoryFileAccess(targetNames: [
            FileCacheLayout.markerFilename
        ])

        await #expect(throws: LRUFileCacheError.missingOwnershipMarker) {
            _ = try await makeCache(
                at: directory,
                fileAccess: access
            )
        }
    }

    @Test("An interrupted first marker publication can finish on restart")
    func recoversInterruptedMarkerPublication() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stagingURL = directory.appendingPathComponent(
            FileCacheLayout.temporaryArtifactFilename()
        )
        try FoundationFileCacheFileAccess().writeStagingData(
            FileCacheOwnershipMarker.currentData,
            to: stagingURL
        )

        let cache = try await makeCache(at: directory)
        try await cache.insert(Data("value".utf8), for: "key")

        #expect(try await cache.value(for: "key") == Data("value".utf8))
        #expect(!FileManager.default.fileExists(atPath: stagingURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    FileCacheLayout.markerFilename
                ).path
            )
        )
    }

    @Test("An unowned nonempty directory is never modified")
    func rejectsUnownedDirectoryWithoutModification() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let userFile = directory.appendingPathComponent("notes.txt")
        let contents = Data("keep me".utf8)
        try contents.write(to: userFile)

        await #expect(throws: LRUFileCacheError.missingOwnershipMarker) {
            _ = try await makeCache(at: directory)
        }
        #expect(try Data(contentsOf: userFile) == contents)
    }

    @Test("Unknown and nonregular items fail closed")
    func rejectsUnknownAndNonregularItems() async throws {
        let unknownDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: unknownDirectory) }
        _ = try await makeCache(at: unknownDirectory)
        let unknownURL = unknownDirectory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unknownURL)

        await #expect(
            throws: LRUFileCacheError.unknownDirectoryItem("notes.txt")
        ) {
            _ = try await makeCache(at: unknownDirectory)
        }
        #expect(FileManager.default.fileExists(atPath: unknownURL.path))

        let nonregularDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: nonregularDirectory) }
        _ = try await makeCache(at: nonregularDirectory)
        let nestedURL = nonregularDirectory.appendingPathComponent(
            "nested",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: nestedURL,
            withIntermediateDirectories: true
        )

        await #expect(
            throws: LRUFileCacheError.nonRegularDirectoryItem("nested")
        ) {
            _ = try await makeCache(at: nonregularDirectory)
        }
        #expect(FileManager.default.fileExists(atPath: nestedURL.path))
    }

    @Test("An invalid ownership marker fails without cleanup")
    func rejectsInvalidMarkerWithoutModification() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent(
            FileCacheLayout.markerFilename
        )
        let invalidMarker = Data("not-a-marker".utf8)
        try invalidMarker.write(to: markerURL)

        await #expect(throws: LRUFileCacheError.invalidOwnershipMarker) {
            _ = try await makeCache(at: directory)
        }
        #expect(try Data(contentsOf: markerURL) == invalidMarker)
    }

    @Test("Concurrent same-key operations remain serialized and readable")
    func concurrentSameKeyOperations() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        let candidates = (0..<100).map { Data("value-\($0)".utf8) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for candidate in candidates {
                group.addTask {
                    try await cache.insert(candidate, for: "shared")
                    _ = try await cache.value(for: "shared")
                }
            }
            try await group.waitForAll()
        }

        let result = try #require(try await cache.value(for: "shared"))
        #expect(candidates.contains(result))

        let restarted = try await makeCache(at: directory)
        #expect(try await restarted.value(for: "shared") == result)
    }

    @Test("Stable key encoder failures propagate before I/O")
    func stableKeyEncoderFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await LRUFileCache<String>(
            directory: directory,
            configuration: configuration
        ) { _ in
            throw LRUFileCacheTestError.encoding
        }

        await #expect(throws: LRUFileCacheTestError.encoding) {
            try await cache.insert(Data(), for: "key")
        }
        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
    }

    @Test("A staging write failure preserves the old resident")
    func stagingWriteFailurePreservesOldResident() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let cache = try await makeCache(at: directory, fileAccess: access)
        let oldValue = Data("old".utf8)
        try await cache.insert(oldValue, for: "key")
        access.failNext(.writeStagingData)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.insert(Data("new".utf8), for: "key")
        }
        #expect(try await cache.value(for: "key") == oldValue)
    }

    @Test("A resident removal failure is recoverable")
    func residentRemovalFailureIsRecoverable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let cache = try await makeCache(at: directory, fileAccess: access)
        let value = Data("resident".utf8)
        try await cache.insert(value, for: "key")
        access.failNext(.removeItem)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.removeValue(for: "key")
        }
        #expect(try await cache.value(for: "key") == value)

        try await cache.removeValue(for: "key")
        #expect(try await cache.value(for: "key") == nil)
    }

    @Test("A remove-all failure retains only undeleted resident state")
    func removeAllFailureRetainsAccurateState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let cache = try await makeCache(at: directory, fileAccess: access)
        try await cache.insert(Data("a".utf8), for: "a")
        try await cache.insert(Data("b".utf8), for: "b")
        access.failNext(.removeItem)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.removeAll()
        }

        let remaining = try await [
            cache.value(for: "a"),
            cache.value(for: "b"),
        ].compactMap { $0 }
        #expect(remaining.count == 1)

        try await cache.removeAll()
        #expect(try await cache.value(for: "a") == nil)
        #expect(try await cache.value(for: "b") == nil)
    }

    @Test("Remove all cleans the complete validated directory inventory")
    func removeAllCleansCompleteInventory() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        try await cache.insert(Data("known".utf8), for: "known")

        let externalFilename = FileCacheFilename(
            stableKeyMaterial: Data("external".utf8)
        )
        let externalURL = directory.appendingPathComponent(
            externalFilename.rawValue
        )
        try Data("external".utf8).write(to: externalURL)
        let stagingURL = directory.appendingPathComponent(
            FileCacheLayout.temporaryArtifactFilename()
        )
        try FoundationFileCacheFileAccess().writeStagingData(
            Data("staging".utf8),
            to: stagingURL
        )

        try await cache.removeAll()

        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
        let restarted = try await makeCache(at: directory)
        #expect(try await restarted.value(for: "known") == nil)
        #expect(try await restarted.value(for: "external") == nil)
    }

    @Test("Remove all forgets residents deleted before enumeration")
    func removeAllForgetsExternallyDeletedResident() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        let first = Data("first".utf8)
        let second = Data("second".utf8)
        try await cache.insert(first, for: "key")
        let filename = FileCacheFilename(
            stableKeyMaterial: Data("key".utf8)
        )
        try FileManager.default.removeItem(
            at: directory.appendingPathComponent(filename.rawValue)
        )

        try await cache.removeAll()
        try await cache.insert(second, for: "key")

        #expect(try await cache.value(for: "key") == second)
    }

    @Test("Remove all fails closed before deleting for an invalid marker")
    func removeAllRejectsInvalidMarkerWithoutDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        try await cache.insert(Data("resident".utf8), for: "key")
        let markerURL = directory.appendingPathComponent(
            FileCacheLayout.markerFilename
        )
        try Data("invalid".utf8).write(to: markerURL)
        let namesBeforeRemoval = try directoryItemNames(in: directory)

        await #expect(throws: LRUFileCacheError.invalidOwnershipMarker) {
            try await cache.removeAll()
        }

        #expect(
            try directoryItemNames(in: directory) == namesBeforeRemoval
        )
        await #expect(throws: LRUFileCacheError.unavailable) {
            _ = try await cache.value(for: "key")
        }
    }

    @Test("Remove all fails closed before deleting an unknown item")
    func removeAllRejectsUnknownItemWithoutDeletion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        try await cache.insert(Data("resident".utf8), for: "key")
        let unknownURL = directory.appendingPathComponent("notes.txt")
        try Data("unknown".utf8).write(to: unknownURL)
        let namesBeforeRemoval = try directoryItemNames(in: directory)

        await #expect(
            throws: LRUFileCacheError.unknownDirectoryItem("notes.txt")
        ) {
            try await cache.removeAll()
        }

        #expect(
            try directoryItemNames(in: directory) == namesBeforeRemoval
        )
        await #expect(throws: LRUFileCacheError.unavailable) {
            try await cache.removeAll()
        }
    }

    @Test("A post-publish metadata failure converges to a miss")
    func publishedMetadataFailureConvergesToMiss() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let cache = try await makeCache(at: directory, fileAccess: access)
        access.failAfter(.metadata, successfulCalls: 1)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.insert(Data("value".utf8), for: "key")
        }
        #expect(try await cache.value(for: "key") == nil)

        let restarted = try await makeCache(at: directory)
        #expect(try await restarted.value(for: "key") == nil)
    }

    @Test("A reconciliation failure makes the instance unavailable")
    func reconciliationFailureFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faultingAccess = FaultInjectingFileCacheAccess()
        let access = MetadataAdaptingFileCacheAccess(
            base: faultingAccess,
            sizeMode: .residentOverhead(10)
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(maximumDiskUsage: 100),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )
        faultingAccess.failNext(.contentsOfDirectory)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.insert(
                Data(repeating: 1, count: 90),
                for: "candidate"
            )
        }
        await #expect(throws: LRUFileCacheError.unavailable) {
            _ = try await cache.value(for: "candidate")
        }
    }

    @Test("A staging cleanup failure makes the instance unavailable")
    func stagingCleanupFailureFailsClosed() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let cache = try await makeCache(at: directory, fileAccess: access)
        access.failNext(.writeStagingData)
        access.failNext(.removeItem)

        await #expect(throws: LRUFileCacheError.self) {
            try await cache.insert(Data("value".utf8), for: "key")
        }
        await #expect(throws: LRUFileCacheError.unavailable) {
            _ = try await cache.value(for: "key")
        }
    }

    @Test("A touch failure preserves the hit and retries bookkeeping")
    func touchFailurePreservesHitAndRetries() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let clock = MutableFileCacheWallClock(date: Date())
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                accessTimeUpdateInterval: .seconds(60)
            ),
            fileAccess: access,
            wallClock: clock
        )
        let value = Data("value".utf8)
        try await cache.insert(value, for: "key")
        clock.advance(by: 120)
        access.failNext(.setModificationDate)

        #expect(try await cache.value(for: "key") == value)
        #expect(access.callCount(for: .setModificationDate) == 2)

        #expect(try await cache.value(for: "key") == value)
        #expect(access.callCount(for: .setModificationDate) == 3)

        #expect(try await cache.value(for: "key") == value)
        #expect(access.callCount(for: .setModificationDate) == 3)
    }

    @Test("A zero touch interval persists every hit")
    func zeroTouchIntervalPersistsEveryHit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = FaultInjectingFileCacheAccess()
        let clock = MutableFileCacheWallClock(date: Date())
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToIdle: .seconds(60)
            ),
            fileAccess: access,
            wallClock: clock
        )
        let value = Data("value".utf8)
        try await cache.insert(value, for: "key")

        #expect(try await cache.value(for: "key") == value)
        #expect(try await cache.value(for: "key") == value)
        #expect(access.callCount(for: .setModificationDate) == 3)
    }

    @Test("Capacity does not trim at the exact high watermark")
    func exactHighWatermarkDoesNotTrim() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1
            ),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data(repeating: 1, count: 6), for: "a")
        try await cache.insert(Data(repeating: 2, count: 4), for: "b")

        #expect(try await cache.value(for: "a") != nil)
        #expect(try await cache.value(for: "b") != nil)
    }

    @Test("Capacity trims least-recent residents down to low watermark")
    func capacityTrimsToLowWatermark() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1
            ),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data(repeating: 1, count: 4), for: "a")
        try await cache.insert(Data(repeating: 2, count: 4), for: "b")
        _ = try await cache.value(for: "a")
        try await cache.insert(Data(repeating: 3, count: 3), for: "c")

        #expect(try await cache.value(for: "a") == nil)
        #expect(try await cache.value(for: "b") == nil)
        #expect(try await cache.value(for: "c") != nil)
    }

    @Test("The current candidate is protected only for its insertion")
    func candidateProtectionIsScopedToInsertion() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(maximumDiskUsage: 100),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data(repeating: 1, count: 4), for: "old")
        try await cache.insert(
            Data(repeating: 2, count: 93),
            for: "candidate"
        )

        #expect(try await cache.value(for: "old") == nil)
        #expect(try await cache.value(for: "candidate") != nil)

        try await cache.insert(Data(repeating: 3, count: 4), for: "next")

        #expect(try await cache.value(for: "candidate") == nil)
        #expect(try await cache.value(for: "next") != nil)
    }

    @Test("An oversized update is a normal rejection")
    func oversizedUpdatePreservesOldResident() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(maximumDiskUsage: 100),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )
        let oldValue = Data(repeating: 1, count: 10)

        try await cache.insert(oldValue, for: "key")
        try await cache.insert(
            Data(repeating: 2, count: 96),
            for: "key"
        )

        #expect(try await cache.value(for: "key") == oldValue)
    }

    @Test("Final allocated size is the admission truth")
    func finalAllocatedSizeRejectsCandidate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .residentOverhead(10)
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(maximumDiskUsage: 100),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(
            Data(repeating: 1, count: 90),
            for: "candidate"
        )

        #expect(try await cache.value(for: "candidate") == nil)
        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
    }

    @Test("An overwrite replaces its contribution to observed usage")
    func overwriteUpdatesObservedUsageByDelta() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1
            ),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data(repeating: 1, count: 6), for: "a")
        try await cache.insert(Data(repeating: 2, count: 3), for: "b")
        try await cache.insert(Data(repeating: 3, count: 2), for: "a")

        #expect(try await cache.value(for: "a") != nil)
        #expect(try await cache.value(for: "b") != nil)
    }

    @Test("Startup trims recovered residents using directory truth")
    func startupTrimsRecoveredResidents() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated
        )

        do {
            let unbounded = try await makeCache(
                at: directory,
                configuration: configuration,
                fileAccess: access,
                wallClock: TestFileCacheWallClock()
            )
            try await unbounded.insert(
                Data(repeating: 1, count: 4),
                for: "a"
            )
            try await unbounded.insert(
                Data(repeating: 2, count: 4),
                for: "b"
            )
            try await unbounded.insert(
                Data(repeating: 3, count: 4),
                for: "c"
            )
        }

        let bounded = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1
            ),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        #expect(try await bounded.value(for: "a") == nil)
        #expect(try await bounded.value(for: "b") == nil)
        #expect(try await bounded.value(for: "c") != nil)
    }

    @Test("Capacity falls back to logical size")
    func capacityFallsBackToLogicalSize() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalFallback
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(maximumDiskUsage: 10),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data(repeating: 1, count: 6), for: "a")
        try await cache.insert(Data(repeating: 2, count: 5), for: "b")

        #expect(try await cache.value(for: "a") == nil)
        #expect(try await cache.value(for: "b") != nil)
    }

    @Test("A trim deletion failure leaves state aligned with disk")
    func trimDeletionFailurePreservesAccurateState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let faultingAccess = FaultInjectingFileCacheAccess()
        let access = MetadataAdaptingFileCacheAccess(
            base: faultingAccess,
            sizeMode: .logicalAsAllocated
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1
            ),
            fileAccess: access,
            wallClock: TestFileCacheWallClock()
        )
        let a = Data(repeating: 1, count: 4)
        let b = Data(repeating: 2, count: 4)
        let c = Data(repeating: 3, count: 3)
        try await cache.insert(a, for: "a")
        try await cache.insert(b, for: "b")
        faultingAccess.failNext(.removeItem)

        await #expect(throws: InjectedFileCacheError.expected) {
            try await cache.insert(c, for: "c")
        }

        #expect(try await cache.value(for: "a") == a)
        #expect(try await cache.value(for: "b") == b)
        #expect(try await cache.value(for: "c") == c)
    }

    @Test("TTL expires from the latest successful write")
    func timeToLiveExpiration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToLive: .seconds(10)
            ),
            fileAccess: access,
            wallClock: clock
        )

        try await cache.insert(Data("value".utf8), for: "key")
        clock.advance(by: 10)

        #expect(try await cache.value(for: "key") == nil)
    }

    @Test("An expiration cleanup failure remains a miss and retries")
    func expirationCleanupFailureRemainsMiss() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let faultingAccess = FaultInjectingFileCacheAccess()
        let access = MetadataAdaptingFileCacheAccess(
            base: faultingAccess,
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToLive: .seconds(10)
            ),
            fileAccess: access,
            wallClock: clock
        )
        try await cache.insert(Data("value".utf8), for: "key")
        clock.advance(by: 10)
        faultingAccess.failNext(.removeItem)

        #expect(try await cache.value(for: "key") == nil)
        #expect(try await cache.value(for: "key") == nil)
        #expect(faultingAccess.callCount(for: .removeItem) == 2)
        #expect(try await cache.value(for: "key") == nil)
    }

    @Test("A hit refreshes in-process TTI without sleeping")
    func hitRefreshesTimeToIdle() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = Data("value".utf8)
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToIdle: .seconds(10),
                accessTimeUpdateInterval: .seconds(60)
            ),
            fileAccess: access,
            wallClock: clock
        )

        try await cache.insert(value, for: "key")
        clock.advance(by: 6)
        #expect(try await cache.value(for: "key") == value)
        clock.advance(by: 6)
        #expect(try await cache.value(for: "key") == value)
        clock.advance(by: 10)
        #expect(try await cache.value(for: "key") == nil)
    }

    @Test("TTL and TTI expire when either limit is reached")
    func combinedExpirationUsesEarliestLimit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToLive: .seconds(100),
                timeToIdle: .seconds(10)
            ),
            fileAccess: access,
            wallClock: clock
        )

        try await cache.insert(Data("value".utf8), for: "key")
        clock.advance(by: 10)

        #expect(try await cache.value(for: "key") == nil)
    }

    @Test("Disabled expiration keeps old residents available")
    func disabledExpiration() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = Data("value".utf8)
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let cache = try await makeCache(
            at: directory,
            configuration: configuration,
            fileAccess: MetadataAdaptingFileCacheAccess(),
            wallClock: clock
        )

        try await cache.insert(value, for: "key")
        clock.advance(by: 31_536_000)

        #expect(try await cache.value(for: "key") == value)
    }

    @Test("A zero expiration duration retains nothing")
    func zeroExpirationRetainsNothing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToLive: .zero
            ),
            fileAccess: MetadataAdaptingFileCacheAccess(),
            wallClock: TestFileCacheWallClock()
        )

        try await cache.insert(Data("value".utf8), for: "key")

        #expect(try await cache.value(for: "key") == nil)
        #expect(try directoryItemNames(in: directory) == [
            FileCacheLayout.markerFilename
        ])
    }

    @Test("Restart restores persisted TTI")
    func restartRestoresTimeToIdle() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            creationDateFollowsModificationDate: true
        )
        let expiringConfiguration = LRUFileCache<String>.Configuration(
            maximumDiskUsage: .max,
            timeToIdle: .seconds(10)
        )

        do {
            let cache = try await makeCache(
                at: directory,
                configuration: expiringConfiguration,
                fileAccess: access,
                wallClock: clock
            )
            try await cache.insert(Data("value".utf8), for: "key")
        }
        clock.advance(by: 10)

        let restarted = try await makeCache(
            at: directory,
            configuration: expiringConfiguration,
            fileAccess: access,
            wallClock: clock
        )

        #expect(try await restarted.value(for: "key") == nil)
    }

    @Test("Overwrite resets TTL")
    func overwriteResetsTimeToLive() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: .max,
                timeToLive: .seconds(10)
            ),
            fileAccess: access,
            wallClock: clock
        )

        try await cache.insert(Data("old".utf8), for: "key")
        clock.advance(by: 9)
        try await cache.insert(Data("new".utf8), for: "key")
        clock.advance(by: 9)

        #expect(try await cache.value(for: "key") == Data("new".utf8))
    }

    @Test("Insertion removes expired residents before LRU trimming")
    func insertionRemovesExpiredResidentsFirst() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = MutableFileCacheWallClock(
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let access = MetadataAdaptingFileCacheAccess(
            sizeMode: .logicalAsAllocated,
            creationDateFollowsModificationDate: true
        )
        let cache = try await makeCache(
            at: directory,
            configuration: .init(
                maximumDiskUsage: 10,
                lowWatermark: 0.5,
                highWatermark: 1,
                timeToLive: .seconds(10)
            ),
            fileAccess: access,
            wallClock: clock
        )

        try await cache.insert(Data(repeating: 1, count: 6), for: "expired")
        clock.advance(by: 10)
        try await cache.insert(Data(repeating: 2, count: 5), for: "new")

        #expect(try await cache.value(for: "expired") == nil)
        #expect(try await cache.value(for: "new") != nil)
    }

    @Test("A Sendable key cache can cross an actor boundary")
    func crossActorUse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = try await makeCache(at: directory)
        let consumer = FileCacheConsumer()

        let result = try await consumer.roundTrip(cache)

        #expect(result == Data("actor".utf8))
    }

    @Test(
        "Invalid configurations fail before taking directory ownership",
        arguments: [
            LRUFileCache<String>.Configuration(maximumDiskUsage: -1),
            .init(maximumDiskUsage: 1, lowWatermark: -0.1),
            .init(maximumDiskUsage: 1, lowWatermark: 0),
            .init(maximumDiskUsage: 1, highWatermark: 1.1),
            .init(
                maximumDiskUsage: 1,
                lowWatermark: 0.9,
                highWatermark: 0.9
            ),
            .init(
                maximumDiskUsage: 1,
                lowWatermark: 0.9,
                highWatermark: 0.8
            ),
            .init(maximumDiskUsage: 1, timeToLive: .seconds(-1)),
            .init(maximumDiskUsage: 1, timeToIdle: .seconds(-1)),
            .init(
                maximumDiskUsage: 1,
                accessTimeUpdateInterval: .seconds(-1)
            ),
        ]
    )
    func invalidConfiguration(
        _ invalidConfiguration: LRUFileCache<String>.Configuration
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "latte-invalid-configuration-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: LRUFileCacheError.self) {
            _ = try await LRUFileCache<String>(
                directory: root,
                configuration: invalidConfiguration,
                stableKeyEncoder: encodeString
            )
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private var configuration: LRUFileCache<String>.Configuration {
        .init(maximumDiskUsage: .max)
    }

    private func makeCache(
        at directory: URL
    ) async throws -> LRUFileCache<String> {
        try await LRUFileCache(
            directory: directory,
            configuration: configuration,
            stableKeyEncoder: encodeString
        )
    }

    private func makeCache(
        at directory: URL,
        fileAccess: any FileCacheFileAccess
    ) async throws -> LRUFileCache<String> {
        try await LRUFileCache(
            directory: directory,
            configuration: configuration,
            stableKeyEncoder: encodeString,
            fileAccess: fileAccess,
            wallClock: TestFileCacheWallClock()
        )
    }

    private func makeCache(
        at directory: URL,
        configuration: LRUFileCache<String>.Configuration,
        fileAccess: any FileCacheFileAccess,
        wallClock: any FileCacheWallClock
    ) async throws -> LRUFileCache<String> {
        try await LRUFileCache(
            directory: directory,
            configuration: configuration,
            stableKeyEncoder: encodeString,
            fileAccess: fileAccess,
            wallClock: wallClock
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "latte-lru-file-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func directoryItemNames(in directory: URL) throws -> Set<String> {
        Set(
            try FileManager.default.contentsOfDirectory(
                atPath: directory.path
            )
        )
    }
}

private actor FileCacheConsumer {
    func roundTrip(
        _ cache: LRUFileCache<String>
    ) async throws -> Data? {
        let value = Data("actor".utf8)
        try await cache.insert(value, for: "key")
        return try await cache.value(for: "key")
    }
}

private enum LRUFileCacheTestError: Error, Equatable {
    case encoding
}

private enum InjectedFileCacheError: Error, Equatable {
    case expected
}

private enum FileCacheAccessOperation: Hashable {
    case contentsOfDirectory
    case writeStagingData
    case metadata
    case setModificationDate
    case removeItem
}

private final class FaultInjectingFileCacheAccess:
    FileCacheFileAccess,
    @unchecked Sendable {
    private let foundation = FoundationFileCacheFileAccess()
    private let failures = LockedValue(
        [FileCacheAccessOperation: Int]()
    )
    private let delayedFailures = LockedValue(
        [FileCacheAccessOperation: Int]()
    )
    private let callCounts = LockedValue(
        [FileCacheAccessOperation: Int]()
    )

    func failNext(_ operation: FileCacheAccessOperation) {
        failures.withLock { failures in
            failures[operation, default: 0] += 1
        }
    }

    func failAfter(
        _ operation: FileCacheAccessOperation,
        successfulCalls: Int
    ) {
        precondition(successfulCalls >= 0)
        delayedFailures.withLock { failures in
            failures[operation] = successfulCalls
        }
    }

    func callCount(for operation: FileCacheAccessOperation) -> Int {
        callCounts.withLock { $0[operation, default: 0] }
    }

    func createDirectory(at url: URL) throws {
        try foundation.createDirectory(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        recordCall(to: .contentsOfDirectory)
        try consumeFailure(for: .contentsOfDirectory)
        return try foundation.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try foundation.readData(at: url)
    }

    func writeStagingData(_ data: Data, to url: URL) throws {
        recordCall(to: .writeStagingData)
        try consumeFailure(for: .writeStagingData)
        try foundation.writeStagingData(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try foundation.moveItem(at: source, to: destination)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        try foundation.replaceItem(at: destination, with: source)
    }

    func metadata(at url: URL) throws -> FileCacheFileMetadata {
        recordCall(to: .metadata)
        try consumeFailure(for: .metadata)
        return try foundation.metadata(at: url)
    }

    func setModificationDate(_ date: Date, at url: URL) throws {
        recordCall(to: .setModificationDate)
        try consumeFailure(for: .setModificationDate)
        try foundation.setModificationDate(date, at: url)
    }

    func removeItem(at url: URL) throws {
        recordCall(to: .removeItem)
        try consumeFailure(for: .removeItem)
        try foundation.removeItem(at: url)
    }

    private func recordCall(to operation: FileCacheAccessOperation) {
        callCounts.withLock { counts in
            counts[operation, default: 0] += 1
        }
    }

    private func consumeFailure(
        for operation: FileCacheAccessOperation
    ) throws {
        let shouldFailAfterDelay = delayedFailures.withLock { failures in
            guard let remaining = failures[operation] else {
                return false
            }
            if remaining == 0 {
                failures.removeValue(forKey: operation)
                return true
            }
            failures[operation] = remaining - 1
            return false
        }
        if shouldFailAfterDelay {
            throw InjectedFileCacheError.expected
        }

        let shouldFail = failures.withLock { failures in
            guard let count = failures[operation], count > 0 else {
                return false
            }
            if count == 1 {
                failures.removeValue(forKey: operation)
            } else {
                failures[operation] = count - 1
            }
            return true
        }

        if shouldFail {
            throw InjectedFileCacheError.expected
        }
    }
}

private final class DisappearingInventoryFileAccess:
    FileCacheFileAccess,
    @unchecked Sendable {
    private let foundation = FoundationFileCacheFileAccess()
    private let targetNames: Set<String>
    private let isArmed = LockedValue(true)

    init(targetNames: Set<String>) {
        self.targetNames = targetNames
    }

    func createDirectory(at url: URL) throws {
        try foundation.createDirectory(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        let contents = try foundation.contentsOfDirectory(at: url)
        let shouldRemove = isArmed.withLock { isArmed in
            defer { isArmed = false }
            return isArmed
        }
        if shouldRemove {
            for item in contents
            where targetNames.contains(item.lastPathComponent) {
                try foundation.removeItem(at: item)
            }
        }
        return contents
    }

    func readData(at url: URL) throws -> Data {
        try foundation.readData(at: url)
    }

    func writeStagingData(_ data: Data, to url: URL) throws {
        try foundation.writeStagingData(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try foundation.moveItem(at: source, to: destination)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        try foundation.replaceItem(at: destination, with: source)
    }

    func metadata(at url: URL) throws -> FileCacheFileMetadata {
        try foundation.metadata(at: url)
    }

    func setModificationDate(_ date: Date, at url: URL) throws {
        try foundation.setModificationDate(date, at: url)
    }

    func removeItem(at url: URL) throws {
        try foundation.removeItem(at: url)
    }
}

private enum MetadataSizeMode: Sendable {
    case foundation
    case logicalAsAllocated
    case logicalFallback
    case residentOverhead(Int)
}

private struct MetadataAdaptingFileCacheAccess: FileCacheFileAccess {
    private let base: any FileCacheFileAccess
    private let sizeMode: MetadataSizeMode
    private let creationDateFollowsModificationDate: Bool

    init(
        base: any FileCacheFileAccess = FoundationFileCacheFileAccess(),
        sizeMode: MetadataSizeMode = .foundation,
        creationDateFollowsModificationDate: Bool = false
    ) {
        self.base = base
        self.sizeMode = sizeMode
        self.creationDateFollowsModificationDate =
            creationDateFollowsModificationDate
    }

    func createDirectory(at url: URL) throws {
        try base.createDirectory(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try base.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try base.readData(at: url)
    }

    func writeStagingData(_ data: Data, to url: URL) throws {
        try base.writeStagingData(data, to: url)
    }

    func moveItem(at source: URL, to destination: URL) throws {
        try base.moveItem(at: source, to: destination)
    }

    func replaceItem(at destination: URL, with source: URL) throws {
        try base.replaceItem(at: destination, with: source)
    }

    func metadata(at url: URL) throws -> FileCacheFileMetadata {
        let metadata = try base.metadata(at: url)
        let allocatedSize: Int?
        switch sizeMode {
        case .foundation:
            allocatedSize = metadata.allocatedSize
        case .logicalAsAllocated:
            allocatedSize = metadata.logicalSize
        case .logicalFallback:
            allocatedSize = nil
        case let .residentOverhead(overhead):
            if FileCacheFilename(
                residentFilename: url.lastPathComponent
            ) != nil, let logicalSize = metadata.logicalSize {
                allocatedSize = logicalSize + overhead
            } else {
                allocatedSize = metadata.logicalSize
            }
        }

        return FileCacheFileMetadata(
            isRegularFile: metadata.isRegularFile,
            allocatedSize: allocatedSize,
            logicalSize: metadata.logicalSize,
            creationDate: creationDateFollowsModificationDate
                ? metadata.modificationDate
                : metadata.creationDate,
            modificationDate: metadata.modificationDate
        )
    }

    func setModificationDate(_ date: Date, at url: URL) throws {
        try base.setModificationDate(date, at: url)
    }

    func removeItem(at url: URL) throws {
        try base.removeItem(at: url)
    }
}

private struct TestFileCacheWallClock: FileCacheWallClock {
    func now() -> Date {
        Date()
    }
}

private final class MutableFileCacheWallClock:
    FileCacheWallClock,
    @unchecked Sendable {
    private let date: LockedValue<Date>

    init(date: Date) {
        self.date = LockedValue(date)
    }

    func now() -> Date {
        date.withLock { $0 }
    }

    func advance(by interval: TimeInterval) {
        date.withLock { date in
            date = date.addingTimeInterval(interval)
        }
    }
}

private let encodeString: @Sendable (String) throws -> Data = {
    Data($0.utf8)
}
