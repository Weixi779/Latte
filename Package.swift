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
        .iOS(.v16),
        .macOS(.v13),
        .macCatalyst(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "Latte",
            targets: ["Latte"]
        ),
        .executable(
            name: "PolicyHitRateBenchmark",
            targets: ["PolicyHitRateBenchmark"]
        ),
        .executable(
            name: "MemoryCacheBenchmark",
            targets: ["MemoryCacheBenchmark"]
        ),
        .executable(
            name: "FileCacheBenchmark",
            targets: ["FileCacheBenchmark"]
        ),
    ],
    targets: [
        .target(name: "Latte"),
        .executableTarget(
            name: "PolicyHitRateBenchmark",
            path: "benchmarks/policy-hit-rate",
            exclude: ["data", "README.md"],
            resources: [.copy("fixtures")]
        ),
        .executableTarget(
            name: "MemoryCacheBenchmark",
            dependencies: ["Latte"],
            path: "benchmarks/memory-cache",
            exclude: ["README.md"]
        ),
        .executableTarget(
            name: "FileCacheBenchmark",
            dependencies: ["Latte"],
            path: "benchmarks/file-cache",
            exclude: ["README.md"]
        ),
        .testTarget(
            name: "LatteTests",
            dependencies: ["Latte"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
