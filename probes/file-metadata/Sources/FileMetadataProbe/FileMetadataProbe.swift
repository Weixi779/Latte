//
//  FileMetadataProbe.swift
//  FileMetadataProbe
//
//  Created by weixi on 2026/7/29.
//

import Foundation

/// Evidence collected from one target platform's real Foundation file APIs.
public struct FileMetadataProbeReport: Codable, Sendable {
    public let operatingSystemVersion: String
    public let executionEnvironment: String
    public let sourceBeforeMove: FileMetadataSnapshot
    public let destinationAfterMove: FileMetadataSnapshot
    public let originalBeforeReplacement: FileMetadataSnapshot
    public let candidateBeforeReplacement: FileMetadataSnapshot
    public let destinationAfterReplacement: FileMetadataSnapshot
    public let destinationAfterTouch: FileMetadataSnapshot
    public let directoryMetadata: FileMetadataSnapshot
    public let replacementPayloadMatchesCandidate: Bool

    public var movePreservedCreationDate: Bool {
        sourceBeforeMove.creationDate == destinationAfterMove.creationDate
    }

    public var movePreservedModificationDate: Bool {
        sourceBeforeMove.modificationDate == destinationAfterMove.modificationDate
    }

    public var replacementUsesCandidateCreationDate: Bool {
        candidateBeforeReplacement.creationDate
            == destinationAfterReplacement.creationDate
    }

    public var replacementUsesCandidateModificationDate: Bool {
        candidateBeforeReplacement.modificationDate
            == destinationAfterReplacement.modificationDate
    }

    public var replacementResetCreationDate: Bool {
        originalBeforeReplacement.creationDate
            != destinationAfterReplacement.creationDate
    }

    public var touchPersistedModificationDate: Bool {
        destinationAfterReplacement.modificationDate
            != destinationAfterTouch.modificationDate
    }

    public var finalAllocatedSizeIsReadable: Bool {
        destinationAfterReplacement.totalFileAllocatedSize != nil
            || destinationAfterReplacement.fileSize != nil
    }

    public func formattedJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// A snapshot read from one URL after a filesystem operation has completed.
public struct FileMetadataSnapshot: Codable, Equatable, Sendable {
    public let isRegularFile: Bool?
    public let totalFileAllocatedSize: Int?
    public let fileSize: Int?
    public let creationDate: Date?
    public let modificationDate: Date?
}

/// Runs the Stage 0 filesystem probe without depending on Latte product code.
public enum FileMetadataProbe {
    private static let metadataKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .totalFileAllocatedSizeKey,
        .fileSizeKey,
        .creationDateKey,
        .contentModificationDateKey,
    ]

    /// Runs atomic move, replacement, timestamp touch, and allocation probes.
    ///
    /// The caller owns `rootDirectory`. The probe creates and removes one
    /// uniquely named child directory inside it.
    public static func run(
        in rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> FileMetadataProbeReport {
        let workspace = rootDirectory.appendingPathComponent(
            "latte-file-metadata-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        defer {
            try? fileManager.removeItem(at: workspace)
        }

        let oldDate = Date(timeIntervalSinceReferenceDate: 100_000_000)
        let candidateDate = Date(timeIntervalSinceReferenceDate: 500_000_000)
        let touchDate = Date(timeIntervalSinceReferenceDate: 700_000_000)

        let moveSource = workspace.appendingPathComponent("move-source")
        let moveDestination = workspace.appendingPathComponent("move-destination")
        try Data(repeating: 0x11, count: 8_193).write(
            to: moveSource,
            options: .atomic
        )
        try setDates(
            creationDate: candidateDate,
            modificationDate: candidateDate,
            at: moveSource,
            fileManager: fileManager
        )
        let sourceBeforeMove = try metadata(at: moveSource)

        try fileManager.moveItem(at: moveSource, to: moveDestination)
        let destinationAfterMove = try metadata(at: moveDestination)

        let replacementDestination = workspace.appendingPathComponent(
            "replacement-destination"
        )
        let replacementCandidate = workspace.appendingPathComponent(
            "replacement-candidate"
        )
        let originalPayload = Data(repeating: 0x22, count: 4_097)
        let candidatePayload = Data(repeating: 0x33, count: 12_289)

        try originalPayload.write(to: replacementDestination, options: .atomic)
        try setDates(
            creationDate: oldDate,
            modificationDate: oldDate,
            at: replacementDestination,
            fileManager: fileManager
        )
        let originalBeforeReplacement = try metadata(
            at: replacementDestination
        )

        try candidatePayload.write(to: replacementCandidate, options: .atomic)
        try setDates(
            creationDate: candidateDate,
            modificationDate: candidateDate,
            at: replacementCandidate,
            fileManager: fileManager
        )
        let candidateBeforeReplacement = try metadata(
            at: replacementCandidate
        )

        _ = try fileManager.replaceItemAt(
            replacementDestination,
            withItemAt: replacementCandidate,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
        let destinationAfterReplacement = try metadata(
            at: replacementDestination
        )
        let replacementPayloadMatchesCandidate =
            try Data(contentsOf: replacementDestination) == candidatePayload

        try setDates(
            creationDate: destinationAfterReplacement.creationDate,
            modificationDate: touchDate,
            at: replacementDestination,
            fileManager: fileManager
        )
        let destinationAfterTouch = try metadata(
            at: replacementDestination
        )
        let directoryMetadata = try metadata(at: workspace)

        return FileMetadataProbeReport(
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            executionEnvironment: executionEnvironment,
            sourceBeforeMove: sourceBeforeMove,
            destinationAfterMove: destinationAfterMove,
            originalBeforeReplacement: originalBeforeReplacement,
            candidateBeforeReplacement: candidateBeforeReplacement,
            destinationAfterReplacement: destinationAfterReplacement,
            destinationAfterTouch: destinationAfterTouch,
            directoryMetadata: directoryMetadata,
            replacementPayloadMatchesCandidate: replacementPayloadMatchesCandidate
        )
    }

    private static func metadata(
        at url: URL
    ) throws -> FileMetadataSnapshot {
        var uncachedURL = URL(fileURLWithPath: url.path)
        uncachedURL.removeAllCachedResourceValues()
        let values = try uncachedURL.resourceValues(forKeys: metadataKeys)
        return FileMetadataSnapshot(
            isRegularFile: values.isRegularFile,
            totalFileAllocatedSize: values.totalFileAllocatedSize,
            fileSize: values.fileSize,
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate
        )
    }

    private static func setDates(
        creationDate: Date?,
        modificationDate: Date,
        at url: URL,
        fileManager: FileManager
    ) throws {
        var attributes: [FileAttributeKey: Any] = [
            .modificationDate: modificationDate,
        ]
        if let creationDate {
            attributes[.creationDate] = creationDate
        }
        try fileManager.setAttributes(
            attributes,
            ofItemAtPath: url.path
        )
    }

    private static var executionEnvironment: String {
        #if targetEnvironment(simulator)
        "simulator"
        #elseif os(macOS)
        "macOS-host"
        #else
        "device"
        #endif
    }
}
