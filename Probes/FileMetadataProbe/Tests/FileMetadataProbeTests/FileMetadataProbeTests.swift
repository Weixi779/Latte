//
//  FileMetadataProbeTests.swift
//  FileMetadataProbeTests
//
//  Created by weixi on 2026/7/29.
//

import Foundation
import Testing
@testable import FileMetadataProbe

@Suite("Foundation file metadata")
struct FileMetadataProbeTests {
    @Test("Atomic move preserves the candidate metadata")
    func atomicMovePreservesMetadata() throws {
        let report = try makeReport()

        #expect(report.sourceBeforeMove.isRegularFile == true)
        #expect(report.destinationAfterMove.isRegularFile == true)
        #expect(report.movePreservedCreationDate)
        #expect(report.movePreservedModificationDate)
    }

    @Test("Replacement publishes candidate metadata at the final URL")
    func replacementUsesCandidateMetadata() throws {
        let report = try makeReport()

        let originalCreationDate = try #require(
            report.originalBeforeReplacement.creationDate
        )
        let candidateCreationDate = try #require(
            report.candidateBeforeReplacement.creationDate
        )
        #expect(originalCreationDate != candidateCreationDate)
        #expect(report.replacementPayloadMatchesCandidate)
        #expect(report.replacementUsesCandidateCreationDate)
        #expect(report.replacementUsesCandidateModificationDate)
        #expect(report.replacementResetCreationDate)
    }

    @Test("The final URL exposes an allocated or logical size")
    func finalSizeIsReadable() throws {
        let report = try makeReport()

        #expect(report.finalAllocatedSizeIsReadable)
        #expect(report.destinationAfterReplacement.fileSize == 12_289)
    }

    @Test("Modification date can persist a TTI touch")
    func modificationDateTouchPersists() throws {
        let report = try makeReport()

        #expect(report.touchPersistedModificationDate)
    }

    @Test("A directory is not classified as a regular file")
    func directoryIsNotRegularFile() throws {
        let report = try makeReport()

        #expect(report.directoryMetadata.isRegularFile == false)
    }

    @Test("Print the platform evidence report")
    func evidenceReport() throws {
        let report = try makeReport()

        print(try report.formattedJSON())
    }

    private func makeReport() throws -> FileMetadataProbeReport {
        try FileMetadataProbe.run(
            in: FileManager.default.temporaryDirectory
        )
    }
}
