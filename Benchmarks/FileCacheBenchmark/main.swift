//
//  main.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

import Dispatch
import Foundation
import Latte

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct Options {
    var operations = 2_000
    var residentCount = 256
    var keySpace = 512
    var valueSize = 65_536
    var readRatio = 0.80
    var touchIntervalSeconds = 60.0
    var runs = 3
    var directoryRoot = FileManager.default.temporaryDirectory

    static func parse(_ arguments: [String]) throws -> Self {
        var options = Self()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" {
                printUsage()
                exit(EXIT_SUCCESS)
            }

            guard index + 1 < arguments.count else {
                throw BenchmarkError.missingValue(argument)
            }
            let value = arguments[index + 1]

            switch argument {
            case "--operations":
                options.operations = try positiveInteger(value, for: argument)
            case "--residents":
                options.residentCount = try positiveInteger(
                    value,
                    for: argument
                )
            case "--key-space":
                options.keySpace = try positiveInteger(value, for: argument)
            case "--value-size":
                options.valueSize = try positiveInteger(value, for: argument)
            case "--read-ratio":
                options.readRatio = try ratio(value, for: argument)
            case "--touch-interval":
                options.touchIntervalSeconds = try nonnegativeDouble(
                    value,
                    for: argument
                )
            case "--runs":
                options.runs = try positiveInteger(value, for: argument)
            case "--directory":
                options.directoryRoot = URL(
                    fileURLWithPath: value,
                    isDirectory: true
                )
            default:
                throw BenchmarkError.unknownArgument(argument)
            }
            index += 2
        }

        guard options.keySpace > options.residentCount else {
            throw BenchmarkError.invalidValue(
                "--key-space must be greater than --residents"
            )
        }
        guard options.operations <= Int.max / 2 else {
            throw BenchmarkError.invalidValue("--operations is too large")
        }
        return options
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(String)

    var description: String {
        switch self {
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)"
        case let .missingValue(argument):
            "Missing value for \(argument)"
        case let .invalidValue(message):
            message
        }
    }
}

private struct Measurement {
    let name: String
    let operations: Int
    let medianNanoseconds: UInt64
    let checksum: UInt64

    var nanosecondsPerOperation: Double {
        Double(medianNanoseconds) / Double(operations)
    }

    var operationsPerSecond: Double {
        1_000_000_000 / nanosecondsPerOperation
    }
}

private struct PreparedCache {
    let directory: URL
    let cache: LRUFileCache<Int>
}

private let stableIntEncoder: @Sendable (Int) throws -> Data = { key in
    var value = Int64(key).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func makeCache(
    directory: URL,
    options: Options
) async throws -> LRUFileCache<Int> {
    try await LRUFileCache(
        directory: directory,
        configuration: .init(
            maximumDiskUsage: .max,
            accessTimeUpdateInterval: .seconds(
                options.touchIntervalSeconds
            )
        ),
        stableKeyEncoder: stableIntEncoder
    )
}

private func populate(
    _ cache: LRUFileCache<Int>,
    count: Int,
    value: Data
) async throws {
    for key in 0..<count {
        try await cache.insert(value, for: key)
    }
}

private func measure<State>(
    name: String,
    operations: Int,
    runs: Int,
    prepare: (Int) async throws -> State,
    execute: (State) async throws -> UInt64,
    cleanup: (State) throws -> Void
) async throws -> Measurement {
    var durations: [UInt64] = []
    durations.reserveCapacity(runs)
    var checksum: UInt64 = 0

    for run in 0..<runs {
        let state = try await prepare(run)
        do {
            let start = DispatchTime.now().uptimeNanoseconds
            checksum &+= try await execute(state)
            durations.append(
                DispatchTime.now().uptimeNanoseconds - start
            )
            try cleanup(state)
        } catch {
            try? cleanup(state)
            throw error
        }
    }

    durations.sort()
    return Measurement(
        name: name,
        operations: operations,
        medianNanoseconds: durations[durations.count / 2],
        checksum: checksum
    )
}

private func run(
    options: Options,
    sessionRoot: URL
) async throws -> [Measurement] {
    let value = Data(repeating: 0x5A, count: options.valueSize)
    var results: [Measurement] = []

    results.append(
        try await measureCacheScenario(
            name: "warm-hit",
            operations: options.operations,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            var checksum: UInt64 = 0
            for operation in 0..<options.operations {
                let key = operation % options.residentCount
                checksum &+= UInt64(
                    try await prepared.cache.value(for: key)?.count ?? 0
                )
            }
            return checksum
        }
    )

    results.append(
        try await measureCacheScenario(
            name: "warm-miss",
            operations: options.operations,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            var checksum: UInt64 = 0
            for operation in 0..<options.operations {
                let key = options.residentCount
                    + operation % (
                        options.keySpace - options.residentCount
                    )
                if try await prepared.cache.value(for: key) == nil {
                    checksum &+= 1
                }
            }
            return checksum
        }
    )

    results.append(
        try await measureCacheScenario(
            name: "resident-overwrite",
            operations: options.operations,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            for operation in 0..<options.operations {
                try await prepared.cache.insert(
                    value,
                    for: operation % options.residentCount
                )
            }
            return UInt64(options.operations)
        }
    )

    let readThreshold = Int(options.readRatio * 10_000)
    results.append(
        try await measureCacheScenario(
            name: "mixed-read-write",
            operations: options.operations,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            var checksum: UInt64 = 0
            for operation in 0..<options.operations {
                let token = mixedToken(operation: operation)
                let key = Int(token % UInt64(options.keySpace))
                if Int(token % 10_000) < readThreshold {
                    if try await prepared.cache.value(for: key) != nil {
                        checksum &+= 1
                    }
                } else {
                    try await prepared.cache.insert(value, for: key)
                }
            }
            return checksum
        }
    )

    results.append(
        try await measureCacheScenario(
            name: "remove-insert-cycle",
            operations: options.operations * 2,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            for operation in 0..<options.operations {
                let key = operation % options.residentCount
                try await prepared.cache.removeValue(for: key)
                try await prepared.cache.insert(value, for: key)
            }
            return UInt64(options.operations)
        }
    )

    results.append(
        try await measureCacheScenario(
            name: "remove-all",
            operations: 1,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            try await prepared.cache.removeAll()
            return UInt64(options.residentCount)
        }
    )

    results.append(
        try await measureColdRebuild(
            options: options,
            sessionRoot: sessionRoot,
            value: value
        )
    )

    return results
}

private func measureCacheScenario(
    name: String,
    operations: Int,
    options: Options,
    sessionRoot: URL,
    value: Data,
    execute: @escaping (PreparedCache) async throws -> UInt64
) async throws -> Measurement {
    try await measure(
        name: name,
        operations: operations,
        runs: options.runs
    ) { run in
        let directory = scenarioDirectory(
            root: sessionRoot,
            name: name,
            run: run
        )
        let cache = try await makeCache(
            directory: directory,
            options: options
        )
        try await populate(
            cache,
            count: options.residentCount,
            value: value
        )
        return PreparedCache(directory: directory, cache: cache)
    } execute: { prepared in
        try await execute(prepared)
    } cleanup: { prepared in
        try FileManager.default.removeItem(at: prepared.directory)
    }
}

private func measureColdRebuild(
    options: Options,
    sessionRoot: URL,
    value: Data
) async throws -> Measurement {
    var durations: [UInt64] = []
    durations.reserveCapacity(options.runs)
    var checksum: UInt64 = 0

    for run in 0..<options.runs {
        let directory = scenarioDirectory(
            root: sessionRoot,
            name: "cold-rebuild",
            run: run
        )
        do {
            try await createPopulatedDirectory(
                directory,
                options: options,
                value: value
            )
            let start = DispatchTime.now().uptimeNanoseconds
            let recovered = try await makeCache(
                directory: directory,
                options: options
            )
            durations.append(
                DispatchTime.now().uptimeNanoseconds - start
            )
            checksum &+= UInt64(options.residentCount)
            withExtendedLifetime(recovered) {}
            try FileManager.default.removeItem(at: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    durations.sort()
    return Measurement(
        name: "cold-rebuild",
        operations: 1,
        medianNanoseconds: durations[durations.count / 2],
        checksum: checksum
    )
}

private func createPopulatedDirectory(
    _ directory: URL,
    options: Options,
    value: Data
) async throws {
    let cache = try await makeCache(
        directory: directory,
        options: options
    )
    try await populate(
        cache,
        count: options.residentCount,
        value: value
    )
}

private func scenarioDirectory(
    root: URL,
    name: String,
    run: Int
) -> URL {
    root.appendingPathComponent(
        "\(name)-\(run)",
        isDirectory: true
    )
}

private func mixedToken(operation: Int) -> UInt64 {
    UInt64(operation) &* 6_364_136_223_846_793_005
        &+ 1_442_695_040_888_963_407
}

private func positiveInteger(
    _ value: String,
    for argument: String
) throws -> Int {
    guard let result = Int(value), result > 0 else {
        throw BenchmarkError.invalidValue(
            "\(argument) must be a positive integer"
        )
    }
    return result
}

private func ratio(
    _ value: String,
    for argument: String
) throws -> Double {
    guard let result = Double(value),
          result.isFinite,
          result >= 0,
          result <= 1
    else {
        throw BenchmarkError.invalidValue(
            "\(argument) must be between zero and one"
        )
    }
    return result
}

private func nonnegativeDouble(
    _ value: String,
    for argument: String
) throws -> Double {
    guard let result = Double(value),
          result.isFinite,
          result >= 0
    else {
        throw BenchmarkError.invalidValue(
            "\(argument) must be nonnegative"
        )
    }
    return result
}

private func printResults(
    _ results: [Measurement],
    options: Options,
    sessionRoot: URL
) {
    let values = try? options.directoryRoot.resourceValues(forKeys: [
        .volumeLocalizedFormatDescriptionKey,
        .volumeIsLocalKey,
    ])
    let volumeIsLocal: Bool? = values?.volumeIsLocal

    print("FileCacheBenchmark")
    print("dispatch: concrete LRUFileCache")
    print("build configuration: \(buildConfiguration())")
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "active processors: "
            + String(ProcessInfo.processInfo.activeProcessorCount)
    )
    print("directory root: \(options.directoryRoot.path)")
    print(
        "volume format: "
            + (values?.volumeLocalizedFormatDescription ?? "unknown")
    )
    print(
        "volume is local: "
            + (volumeIsLocal.map { String($0) } ?? "unknown")
    )
    print("session directory: \(sessionRoot.path)")
    print("operations per main scenario: \(options.operations)")
    print("resident files: \(options.residentCount)")
    print("key space: \(options.keySpace)")
    print("value size: \(options.valueSize) bytes")
    print(
        String(
            format: "mixed read/write ratio: %.2f / %.2f",
            options.readRatio,
            1 - options.readRatio
        )
    )
    print(
        String(
            format: "access touch interval: %.3f seconds",
            options.touchIntervalSeconds
        )
    )
    print("timed runs: \(options.runs)")
    print()
    print("scenario\tmedian ns/op\toperations/s\tchecksum")

    for result in results {
        print(
            String(
                format: "%@\t%.2f\t%.0f\t%llu",
                result.name,
                result.nanosecondsPerOperation,
                result.operationsPerSecond,
                result.checksum
            )
        )
    }
}

private func buildConfiguration() -> String {
#if DEBUG
    "debug"
#else
    "release"
#endif
}

private func printUsage() {
    print(
        """
        Usage: FileCacheBenchmark [options]
          --operations <count>    Operations per main scenario (default 2000)
          --residents <count>     Prefilled resident files (default 256)
          --key-space <count>     Workload key space (default 512)
          --value-size <bytes>    Data size per value (default 65536)
          --read-ratio <0...1>    Mixed workload read fraction (default 0.80)
          --touch-interval <sec>  Persistent access touch interval (default 60)
          --runs <count>          Independent timed runs (default 3)
          --directory <path>      Parent directory for benchmark files
          --help                  Show this help
        """
    )
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    try FileManager.default.createDirectory(
        at: options.directoryRoot,
        withIntermediateDirectories: true
    )
    let sessionRoot = options.directoryRoot.appendingPathComponent(
        "latte-file-cache-benchmark-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: sessionRoot,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: sessionRoot) }

    let results = try await run(
        options: options,
        sessionRoot: sessionRoot
    )
    printResults(
        results,
        options: options,
        sessionRoot: sessionRoot
    )
} catch {
    fputs("FileCacheBenchmark: \(error)\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}
