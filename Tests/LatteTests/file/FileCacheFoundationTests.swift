//
//  FileCacheFoundationTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/29.
//

import Foundation
import Testing
@testable import Latte

@Suite("File cache foundations")
struct FileCacheFoundationTests {
    @Test("Stable material produces a lowercase SHA-256 filename")
    func stableFilename() {
        let filename = FileCacheFilename(
            stableKeyMaterial: Data("hello".utf8)
        )

        #expect(
            filename.rawValue
                == "2cf24dba5fb0a30e26e83b2ac5b9e29e"
                    + "1b161e5c1fa7425e73043362938b9824"
        )
        #expect(
            FileCacheFilename(residentFilename: filename.rawValue) == filename
        )
        #expect(
            FileCacheFilename(stableKeyMaterial: Data("other".utf8))
                != filename
        )
    }

    @Test(
        "Resident filenames reject noncanonical or unsafe names",
        arguments: [
            "",
            String(repeating: "a", count: 63),
            String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64),
            "../" + String(repeating: "a", count: 64),
        ]
    )
    func rejectsInvalidResidentFilename(_ name: String) {
        #expect(FileCacheFilename(residentFilename: name) == nil)
    }

    @Test("Ownership marker validates magic, family, and version")
    func ownershipMarker() throws {
        try FileCacheOwnershipMarker.validate(
            FileCacheOwnershipMarker.currentData
        )

        #expect(throws: FileCacheMarkerError.invalidMagic) {
            try FileCacheOwnershipMarker.validate(
                markerData(magic: "OTHER")
            )
        }
        #expect(
            throws: FileCacheMarkerError.unexpectedFamily("another-cache")
        ) {
            try FileCacheOwnershipMarker.validate(
                markerData(family: "another-cache")
            )
        }
        #expect(throws: FileCacheMarkerError.unsupportedVersion(2)) {
            try FileCacheOwnershipMarker.validate(
                markerData(version: 2)
            )
        }
    }

    @Test("Inventory classification is complete and deterministic")
    func inventoryClassification() throws {
        let first = FileCacheFilename(
            stableKeyMaterial: Data("first".utf8)
        )
        let second = FileCacheFilename(
            stableKeyMaterial: Data("second".utf8)
        )
        let temporary = FileCacheLayout.temporaryArtifactFilename(
            identifier: UUID(
                uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
            )!
        )
        let inventory = try FileCacheInventoryClassifier.classify([
            .init(name: second.rawValue, isRegularFile: true),
            .init(name: temporary, isRegularFile: true),
            .init(
                name: FileCacheLayout.markerFilename,
                isRegularFile: true
            ),
            .init(name: first.rawValue, isRegularFile: true),
        ])

        #expect(
            inventory.residents.map(\.rawValue)
                == [first.rawValue, second.rawValue].sorted()
        )
        #expect(inventory.temporaryArtifacts == [temporary])
    }

    @Test("Inventory rejects unowned and nonregular entries")
    func inventoryRejectsUnsafeEntries() {
        #expect(throws: FileCacheInventoryError.missingMarker) {
            try FileCacheInventoryClassifier.classify([])
        }
        #expect(throws: FileCacheInventoryError.unknownItem("notes.txt")) {
            try FileCacheInventoryClassifier.classify([
                markerEntry(),
                .init(name: "notes.txt", isRegularFile: true),
            ])
        }
        #expect(
            throws: FileCacheInventoryError.nonRegularItem("directory")
        ) {
            try FileCacheInventoryClassifier.classify([
                markerEntry(),
                .init(name: "directory", isRegularFile: false),
            ])
        }
        #expect(
            throws: FileCacheInventoryError.duplicateName(
                FileCacheLayout.markerFilename
            )
        ) {
            try FileCacheInventoryClassifier.classify([
                markerEntry(),
                markerEntry(),
            ])
        }
    }

    @Test("Foundation file access performs the required primitive operations")
    func foundationFileAccess() throws {
        let access = FoundationFileCacheFileAccess()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "latte-file-access-\(UUID().uuidString)",
            isDirectory: true
        )
        try access.createDirectory(at: root)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let markerURL = try publishMarker(in: root, using: access)
        #expect(
            try access.readData(at: markerURL)
                == FileCacheOwnershipMarker.currentData
        )

        let moveSource = stagingURL(in: root)
        let moveDestination = root.appendingPathComponent("move-destination")
        try access.writeStagingData(Data([1, 2, 3]), to: moveSource)
        try access.moveItem(at: moveSource, to: moveDestination)
        #expect(!FileManager.default.fileExists(atPath: moveSource.path))
        #expect(try access.readData(at: moveDestination) == Data([1, 2, 3]))

        let replacement = stagingURL(in: root)
        try access.writeStagingData(
            Data([4, 5, 6, 7]),
            to: replacement
        )
        try access.replaceItem(at: moveDestination, with: replacement)
        #expect(
            try access.readData(at: moveDestination) == Data([4, 5, 6, 7])
        )

        let touchDate = Date(timeIntervalSinceReferenceDate: 700_000_000)
        try access.setModificationDate(touchDate, at: moveDestination)
        let metadata = try access.metadata(at: moveDestination)
        #expect(metadata.isRegularFile == true)
        #expect(metadata.logicalSize == 4)
        #expect(metadata.allocatedSize != nil || metadata.logicalSize != nil)
        #expect(metadata.modificationDate == touchDate)

        let names = try access.contentsOfDirectory(at: root).map {
            $0.lastPathComponent
        }
        #expect(Set(names) == [
            FileCacheLayout.markerFilename,
            "move-destination",
        ])

        try access.removeItem(at: moveDestination)
        #expect(
            !FileManager.default.fileExists(atPath: moveDestination.path)
        )
    }

    @Test("Interrupted staging artifacts are classifiable and removable")
    func interruptedStagingArtifact() throws {
        let access = FoundationFileCacheFileAccess()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "latte-interrupted-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try access.createDirectory(at: root)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        _ = try publishMarker(in: root, using: access)
        let interruptedStagingURL = stagingURL(in: root)
        try access.writeStagingData(
            Data(repeating: 0xAB, count: 4_097),
            to: interruptedStagingURL
        )

        let entries = try access.contentsOfDirectory(at: root).map { url in
            let metadata = try access.metadata(at: url)
            return FileCacheDirectoryEntry(
                name: url.lastPathComponent,
                isRegularFile: metadata.isRegularFile
            )
        }
        let inventory = try FileCacheInventoryClassifier.classify(entries)

        #expect(
            inventory.temporaryArtifacts
                == [interruptedStagingURL.lastPathComponent]
        )

        for artifact in inventory.temporaryArtifacts {
            try access.removeItem(
                at: root.appendingPathComponent(artifact)
            )
        }

        let remainingNames = try access.contentsOfDirectory(at: root).map {
            $0.lastPathComponent
        }
        #expect(remainingNames == [FileCacheLayout.markerFilename])
    }

    @Test("Wall-clock behavior is injectable without sleeping")
    func injectableWallClock() {
        let expected = Date(timeIntervalSinceReferenceDate: 123_456)
        let clock: any FileCacheWallClock = FixedFileCacheWallClock(expected)

        #expect(clock.now() == expected)
    }

    @Test("File cache worker serializes state and propagates cancellation")
    func fileCacheWorker() async throws {
        let worker = FileCacheWorker(state: [Int]())
        let counts = try await withThrowingTaskGroup(
            of: Int.self,
            returning: [Int].self
        ) { group in
            for value in 0..<100 {
                group.addTask {
                    try await worker.perform { state in
                        state.append(value)
                        return state.count
                    }
                }
            }

            var counts: [Int] = []
            for try await count in group {
                counts.append(count)
            }
            return counts
        }
        let finalState = try await worker.perform { $0 }
        let inspectedState = await worker.inspect { $0 }

        #expect(Set(counts) == Set(1...100))
        #expect(Set(finalState) == Set(0..<100))
        #expect(Set(inspectedState) == Set(0..<100))

        let didExecute = LockedValue(false)
        let cancelled = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }

            try await worker.perform { _ in
                didExecute.withLock { $0 = true }
            }
        }

        do {
            try await cancelled.value
            Issue.record("A cancelled operation unexpectedly executed")
        } catch is CancellationError {
            // Expected.
        }
        let operationExecuted = didExecute.withLock { $0 }
        #expect(!operationExecuted)

        let cancelledInspection = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return await worker.inspect { $0.count }
        }
        #expect(await cancelledInspection.value == 100)

        do {
            let _: Int = try await worker.perform { _ in
                throw FileCacheFoundationTestError.expected
            }
            Issue.record("A worker error was unexpectedly swallowed")
        } catch let error as FileCacheFoundationTestError {
            #expect(error == .expected)
        }
    }

    @Test("Inspection queues behind a preceding mutation")
    func fileCacheWorkerInspectionOrdering() async throws {
        let worker = FileCacheWorker(state: [Int]())
        let mutationEntered = FileCacheAsyncSignal()
        let allowMutationToFinish = DispatchSemaphore(value: 0)
        let mutation = Task {
            try await worker.perform { state in
                Task {
                    await mutationEntered.signal()
                }
                allowMutationToFinish.wait()
                state.append(1)
            }
        }
        await mutationEntered.wait()
        let probe = FileCacheInspectionProbe()
        let inspection = Task {
            await probe.inspect(worker)
        }
        await probe.waitUntilStarted()
        await Task.yield()

        allowMutationToFinish.signal()

        try await mutation.value
        #expect(await inspection.value == [1])
    }

    private func markerData(
        magic: String = "LATTE-CACHE",
        family: String = "lru-file-cache",
        version: Int = 1
    ) -> Data {
        Data(
            """
            \(magic)
            family=\(family)
            format=\(version)

            """.utf8
        )
    }

    private func markerEntry() -> FileCacheDirectoryEntry {
        FileCacheDirectoryEntry(
            name: FileCacheLayout.markerFilename,
            isRegularFile: true
        )
    }

    private func publishMarker(
        in directory: URL,
        using access: FoundationFileCacheFileAccess
    ) throws -> URL {
        let stagingURL = stagingURL(in: directory)
        let markerURL = directory.appendingPathComponent(
            FileCacheLayout.markerFilename
        )
        try access.writeStagingData(
            FileCacheOwnershipMarker.currentData,
            to: stagingURL
        )
        try access.moveItem(at: stagingURL, to: markerURL)
        return markerURL
    }

    private func stagingURL(in directory: URL) -> URL {
        directory.appendingPathComponent(
            FileCacheLayout.temporaryArtifactFilename()
        )
    }
}

private struct FixedFileCacheWallClock: FileCacheWallClock {
    let date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        date
    }
}

private actor FileCacheAsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isSignaled = false

    func wait() async {
        guard !isSignaled else {
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal() {
        isSignaled = true
        continuation?.resume()
        continuation = nil
    }
}

private actor FileCacheInspectionProbe {
    private var isStarted = false

    func inspect(_ worker: FileCacheWorker<[Int]>) async -> [Int] {
        isStarted = true
        return await worker.inspect { $0 }
    }

    func waitUntilStarted() async {
        while !isStarted {
            await Task.yield()
        }
    }
}

private enum FileCacheFoundationTestError: Error, Equatable {
    case expected
}
