//
//  FileCacheFormat.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import CryptoKit
import Foundation

package enum FileCacheLayout {
    package static let markerFilename = ".latte-cache"
    package static let temporaryArtifactPrefix = ".latte-tmp-"

    package static func temporaryArtifactFilename(
        identifier: UUID = UUID()
    ) -> String {
        temporaryArtifactPrefix + identifier.uuidString.lowercased()
    }

    package static func isTemporaryArtifactFilename(_ name: String) -> Bool {
        guard name.hasPrefix(temporaryArtifactPrefix) else {
            return false
        }

        let suffix = name.dropFirst(temporaryArtifactPrefix.count)
        return !suffix.isEmpty && suffix.utf8.allSatisfy { byte in
            byte == 0x2D
                || (0x30...0x39).contains(byte)
                || (0x61...0x7A).contains(byte)
        }
    }
}

package struct FileCacheFilename: Hashable, Sendable {
    package let rawValue: String

    package init(stableKeyMaterial: Data) {
        let digest = SHA256.hash(data: stableKeyMaterial)
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(SHA256.Digest.byteCount * 2)

        for byte in digest {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0F)])
        }

        self.rawValue = String(decoding: encoded, as: UTF8.self)
    }

    package init?(residentFilename: String) {
        guard residentFilename.utf8.count == 64,
              residentFilename.utf8.allSatisfy({ byte in
                  (0x30...0x39).contains(byte)
                      || (0x61...0x66).contains(byte)
              })
        else {
            return nil
        }

        self.rawValue = residentFilename
    }
}

package enum FileCacheMarkerError: Error, Equatable, Sendable {
    case invalidUTF8
    case malformed
    case invalidMagic
    case unexpectedFamily(String)
    case unsupportedVersion(Int)
}

package enum FileCacheOwnershipMarker {
    package static let currentFormatVersion = 1

    private static let magic = "LATTE-CACHE"
    private static let family = "lru-file-cache"

    package static var currentData: Data {
        Data(
            """
            \(magic)
            family=\(family)
            format=\(currentFormatVersion)

            """.utf8
        )
    }

    package static func validate(_ data: Data) throws {
        guard let contents = String(data: data, encoding: .utf8) else {
            throw FileCacheMarkerError.invalidUTF8
        }

        let lines = contents.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard lines.count == 4, lines[3].isEmpty else {
            throw FileCacheMarkerError.malformed
        }
        guard lines[0] == magic else {
            throw FileCacheMarkerError.invalidMagic
        }
        guard lines[1].hasPrefix("family=") else {
            throw FileCacheMarkerError.malformed
        }

        let actualFamily = String(lines[1].dropFirst("family=".count))
        guard actualFamily == family else {
            throw FileCacheMarkerError.unexpectedFamily(actualFamily)
        }
        guard lines[2].hasPrefix("format="),
              let version = Int(lines[2].dropFirst("format=".count))
        else {
            throw FileCacheMarkerError.malformed
        }
        guard version == currentFormatVersion else {
            throw FileCacheMarkerError.unsupportedVersion(version)
        }
    }
}

package struct FileCacheDirectoryEntry: Equatable, Sendable {
    package let name: String
    package let isRegularFile: Bool?

    package init(name: String, isRegularFile: Bool?) {
        self.name = name
        self.isRegularFile = isRegularFile
    }
}

package struct FileCacheInventory: Equatable, Sendable {
    package let residents: [FileCacheFilename]
    package let temporaryArtifacts: [String]
}

package enum FileCacheInventoryError: Error, Equatable, Sendable {
    case missingMarker
    case duplicateName(String)
    case nonRegularItem(String)
    case unknownItem(String)
}

package enum FileCacheInventoryClassifier {
    package static func classify(
        _ entries: [FileCacheDirectoryEntry]
    ) throws -> FileCacheInventory {
        let sortedEntries = entries.sorted { $0.name < $1.name }
        var seenNames: Set<String> = []

        for entry in sortedEntries {
            guard seenNames.insert(entry.name).inserted else {
                throw FileCacheInventoryError.duplicateName(entry.name)
            }
        }

        guard let marker = sortedEntries.first(where: {
            $0.name == FileCacheLayout.markerFilename
        }) else {
            throw FileCacheInventoryError.missingMarker
        }
        guard marker.isRegularFile == true else {
            throw FileCacheInventoryError.nonRegularItem(marker.name)
        }

        var residents: [FileCacheFilename] = []
        var temporaryArtifacts: [String] = []

        for entry in sortedEntries
        where entry.name != FileCacheLayout.markerFilename {
            guard entry.isRegularFile == true else {
                throw FileCacheInventoryError.nonRegularItem(entry.name)
            }

            if let filename = FileCacheFilename(
                residentFilename: entry.name
            ) {
                residents.append(filename)
            } else if FileCacheLayout.isTemporaryArtifactFilename(entry.name) {
                temporaryArtifacts.append(entry.name)
            } else {
                throw FileCacheInventoryError.unknownItem(entry.name)
            }
        }

        return FileCacheInventory(
            residents: residents,
            temporaryArtifacts: temporaryArtifacts
        )
    }
}
