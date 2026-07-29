// swift-tools-version: 6.0
//
//  Package.swift
//  FileMetadataProbe
//
//  Created by weixi on 2026/7/29.
//

import PackageDescription

let package = Package(
    name: "FileMetadataProbe",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "FileMetadataProbe",
            targets: ["FileMetadataProbe"]
        ),
    ],
    targets: [
        .target(name: "FileMetadataProbe"),
        .testTarget(
            name: "FileMetadataProbeTests",
            dependencies: ["FileMetadataProbe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
