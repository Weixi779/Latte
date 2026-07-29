//
//  FileCacheFileAccess.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import Foundation

package struct FileCacheFileMetadata: Equatable, Sendable {
    package let isRegularFile: Bool?
    package let allocatedSize: Int?
    package let logicalSize: Int?
    package let creationDate: Date?
    package let modificationDate: Date?
}

package protocol FileCacheFileAccess: Sendable {
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func readData(at url: URL) throws -> Data
    func writeStagingData(_ data: Data, to url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func replaceItem(at destination: URL, with source: URL) throws
    func metadata(at url: URL) throws -> FileCacheFileMetadata
    func setModificationDate(_ date: Date, at url: URL) throws
    func removeItem(at url: URL) throws
}

package struct FoundationFileCacheFileAccess: FileCacheFileAccess {
    package init() {}

    package func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }

    package func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        )
    }

    package func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    package func writeStagingData(_ data: Data, to url: URL) throws {
        precondition(
            FileCacheLayout.isTemporaryArtifactFilename(
                url.lastPathComponent
            ),
            "File cache writes must target a Latte staging artifact"
        )

        try data.write(to: url)
    }

    package func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    package func replaceItem(at destination: URL, with source: URL) throws {
        _ = try FileManager.default.replaceItemAt(
            destination,
            withItemAt: source,
            backupItemName: nil,
            options: [.usingNewMetadataOnly]
        )
    }

    package func metadata(at url: URL) throws -> FileCacheFileMetadata {
        var uncachedURL = URL(fileURLWithPath: url.path)
        uncachedURL.removeAllCachedResourceValues()
        let values = try uncachedURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
            .creationDateKey,
            .contentModificationDateKey,
        ])

        return FileCacheFileMetadata(
            isRegularFile: values.isRegularFile,
            allocatedSize: values.totalFileAllocatedSize,
            logicalSize: values.fileSize,
            creationDate: values.creationDate,
            modificationDate: values.contentModificationDate
        )
    }

    package func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    package func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
