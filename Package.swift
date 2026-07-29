// swift-tools-version: 6.0
//
//  Package.swift
//  Latte
//
//  Created by weixi on 2026/7/25.
//

import PackageDescription

let package = Package(
    name: "Latte",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .macCatalyst(.v15),
        .tvOS(.v15),
        .watchOS(.v8),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Latte",
            targets: ["Latte"]
        ),
    ],
    targets: [
        .target(name: "Latte"),
        .testTarget(
            name: "LatteTests",
            dependencies: ["Latte"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
