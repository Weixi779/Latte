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
    var runs = 4
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
        guard options.runs.isMultiple(of: 2) else {
            throw BenchmarkError.invalidValue(
                "--runs must be an even positive integer"
            )
        }
        return options
    }
}

private enum BenchmarkError: Error, CustomStringConvertible {
    case unknownArgument(String)
    case missingValue(String)
    case invalidValue(String)
    case invalidStatistics(String)

    var description: String {
        switch self {
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)"
        case let .missingValue(argument):
            "Missing value for \(argument)"
        case let .invalidValue(message):
            message
        case let .invalidStatistics(message):
            "Invalid statistics: \(message)"
        }
    }
}

private enum StatisticsMode: CaseIterable {
    case disabled
    case enabled

    var name: String {
        switch self {
        case .disabled:
            "disabled"
        case .enabled:
            "enabled"
        }
    }

    var isEnabled: Bool {
        self == .enabled
    }
}

private struct Measurement {
    let name: String
    let statisticsMode: StatisticsMode
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

private struct Comparison {
    let disabled: Measurement
    let enabled: Measurement

    var relativeOverheadPercent: Double {
        let baseline = disabled.nanosecondsPerOperation
        return (enabled.nanosecondsPerOperation - baseline) / baseline * 100
    }
}

private struct MeasurementSamples {
    var durations: [UInt64] = []
    var checksum: UInt64 = 0

    mutating func record(
        duration: UInt64,
        checksum: UInt64
    ) {
        durations.append(duration)
        self.checksum &+= checksum
    }

    func measurement(
        name: String,
        statisticsMode: StatisticsMode,
        operations: Int
    ) -> Measurement {
        let sortedDurations = durations.sorted()
        return Measurement(
            name: name,
            statisticsMode: statisticsMode,
            operations: operations,
            medianNanoseconds: sortedDurations[sortedDurations.count / 2],
            checksum: checksum
        )
    }
}

private struct PreparedCache {
    let directory: URL
    let cache: LRUFileCache<Int>
    let initialStatistics: CacheStatistics?
}

private let stableIntEncoder: @Sendable (Int) throws -> Data = { key in
    var value = Int64(key).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private func makeCache(
    directory: URL,
    options: Options,
    statisticsMode: StatisticsMode
) async throws -> LRUFileCache<Int> {
    try await LRUFileCache(
        directory: directory,
        configuration: .init(
            maximumDiskUsage: .max,
            accessTimeUpdateInterval: .seconds(
                options.touchIntervalSeconds
            ),
            isStatisticsEnabled: statisticsMode.isEnabled
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

private func run(
    options: Options,
    sessionRoot: URL
) async throws -> [Comparison] {
    let value = Data(repeating: 0x5A, count: options.valueSize)
    var results: [Comparison] = []

    results.append(
        try await measureCacheComparison(
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
        } validate: { prepared, _, statistics in
            guard let initial = prepared.initialStatistics else {
                return false
            }
            return statistics == CacheStatistics(
                hitCount: UInt64(options.operations),
                residentCount: options.residentCount,
                residentCost: initial.residentCost
            )
        }
    )

    results.append(
        try await measureCacheComparison(
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
        } validate: { prepared, _, statistics in
            guard let initial = prepared.initialStatistics else {
                return false
            }
            return statistics == CacheStatistics(
                missCount: UInt64(options.operations),
                residentCount: options.residentCount,
                residentCost: initial.residentCost
            )
        }
    )

    results.append(
        try await measureCacheComparison(
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
        } validate: { _, _, statistics in
            statistics.hitCount == 0
                && statistics.missCount == 0
                && statistics.evictionCount == 0
                && statistics.rejectionCount == 0
                && statistics.residentCount == options.residentCount
        }
    )

    let readThreshold = Int(options.readRatio * 10_000)
    let mixedRequestCount = mixedReadCount(
        operations: options.operations,
        readThreshold: readThreshold
    )
    results.append(
        try await measureCacheComparison(
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
        } validate: { _, checksum, statistics in
            let requestCount = UInt64(mixedRequestCount)
            return statistics.hitCount == checksum
                && statistics.missCount == requestCount - checksum
                && statistics.evictionCount == 0
                && statistics.rejectionCount == 0
                && statistics.residentCount >= options.residentCount
                && statistics.residentCount <= options.keySpace
        }
    )

    results.append(
        try await measureCacheComparison(
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
        } validate: { _, _, statistics in
            statistics.hitCount == 0
                && statistics.missCount == 0
                && statistics.evictionCount == 0
                && statistics.rejectionCount == 0
                && statistics.residentCount == options.residentCount
        }
    )

    results.append(
        try await measureCacheComparison(
            name: "remove-all",
            operations: 1,
            options: options,
            sessionRoot: sessionRoot,
            value: value
        ) { prepared in
            try await prepared.cache.removeAll()
            return UInt64(options.residentCount)
        } validate: { _, _, statistics in
            statistics == CacheStatistics()
        }
    )

    results.append(
        try await measureColdRebuildComparison(
            options: options,
            sessionRoot: sessionRoot,
            value: value
        )
    )

    return results
}

private func measureCacheComparison(
    name: String,
    operations: Int,
    options: Options,
    sessionRoot: URL,
    value: Data,
    execute: @escaping (PreparedCache) async throws -> UInt64,
    validate: @escaping (
        PreparedCache,
        UInt64,
        CacheStatistics
    ) -> Bool
) async throws -> Comparison {
    var disabledSamples = MeasurementSamples()
    var enabledSamples = MeasurementSamples()
    disabledSamples.durations.reserveCapacity(options.runs)
    enabledSamples.durations.reserveCapacity(options.runs)

    for run in 0..<options.runs {
        for statisticsMode in statisticsModes(for: run) {
            let sample = try await measureCacheRun(
                name: name,
                statisticsMode: statisticsMode,
                run: run,
                options: options,
                sessionRoot: sessionRoot,
                value: value,
                execute: execute,
                validate: validate
            )
            switch statisticsMode {
            case .disabled:
                disabledSamples.record(
                    duration: sample.duration,
                    checksum: sample.checksum
                )
            case .enabled:
                enabledSamples.record(
                    duration: sample.duration,
                    checksum: sample.checksum
                )
            }
        }
    }
    let disabled = disabledSamples.measurement(
        name: name,
        statisticsMode: .disabled,
        operations: operations
    )
    let enabled = enabledSamples.measurement(
        name: name,
        statisticsMode: .enabled,
        operations: operations
    )
    guard disabled.checksum == enabled.checksum else {
        throw BenchmarkError.invalidStatistics(
            "\(name) produced different disabled and enabled checksums"
        )
    }
    return Comparison(disabled: disabled, enabled: enabled)
}

private func measureCacheRun(
    name: String,
    statisticsMode: StatisticsMode,
    run: Int,
    options: Options,
    sessionRoot: URL,
    value: Data,
    execute: @escaping (PreparedCache) async throws -> UInt64,
    validate: @escaping (
        PreparedCache,
        UInt64,
        CacheStatistics
    ) -> Bool
) async throws -> (duration: UInt64, checksum: UInt64) {
    let directory = scenarioDirectory(
        root: sessionRoot,
        name: name,
        statisticsMode: statisticsMode,
        run: run
    )
    let cache = try await makeCache(
        directory: directory,
        options: options,
        statisticsMode: statisticsMode
    )
    do {
        try await populate(
            cache,
            count: options.residentCount,
            value: value
        )
        let initialStatistics = await cache.statistics
        try verifyStatistics(
            initialStatistics,
            mode: statisticsMode,
            scenario: "\(name) setup"
        ) { statistics in
            statistics == CacheStatistics(
                residentCount: options.residentCount,
                residentCost: statistics.residentCost
            )
        }
        let prepared = PreparedCache(
            directory: directory,
            cache: cache,
            initialStatistics: initialStatistics
        )
        let start = DispatchTime.now().uptimeNanoseconds
        let checksum = try await execute(prepared)
        let duration = DispatchTime.now().uptimeNanoseconds - start
        let statistics = await prepared.cache.statistics
        try verifyStatistics(
            statistics,
            mode: statisticsMode,
            scenario: name
        ) {
            validate(prepared, checksum, $0)
        }
        try FileManager.default.removeItem(at: directory)
        return (duration, checksum)
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func measureColdRebuildComparison(
    options: Options,
    sessionRoot: URL,
    value: Data
) async throws -> Comparison {
    var disabledSamples = MeasurementSamples()
    var enabledSamples = MeasurementSamples()
    disabledSamples.durations.reserveCapacity(options.runs)
    enabledSamples.durations.reserveCapacity(options.runs)

    for run in 0..<options.runs {
        for statisticsMode in statisticsModes(for: run) {
            let sample = try await measureColdRebuildRun(
                statisticsMode: statisticsMode,
                run: run,
                options: options,
                sessionRoot: sessionRoot,
                value: value
            )
            switch statisticsMode {
            case .disabled:
                disabledSamples.record(
                    duration: sample.duration,
                    checksum: sample.checksum
                )
            case .enabled:
                enabledSamples.record(
                    duration: sample.duration,
                    checksum: sample.checksum
                )
            }
        }
    }
    let disabled = disabledSamples.measurement(
        name: "cold-rebuild",
        statisticsMode: .disabled,
        operations: 1
    )
    let enabled = enabledSamples.measurement(
        name: "cold-rebuild",
        statisticsMode: .enabled,
        operations: 1
    )
    guard disabled.checksum == enabled.checksum else {
        throw BenchmarkError.invalidStatistics(
            "cold-rebuild produced different disabled and enabled checksums"
        )
    }
    return Comparison(disabled: disabled, enabled: enabled)
}

private func measureColdRebuildRun(
    statisticsMode: StatisticsMode,
    run: Int,
    options: Options,
    sessionRoot: URL,
    value: Data
) async throws -> (duration: UInt64, checksum: UInt64) {
    let directory = scenarioDirectory(
        root: sessionRoot,
        name: "cold-rebuild",
        statisticsMode: statisticsMode,
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
            options: options,
            statisticsMode: statisticsMode
        )
        let duration = DispatchTime.now().uptimeNanoseconds - start
        let statistics = await recovered.statistics
        try verifyStatistics(
            statistics,
            mode: statisticsMode,
            scenario: "cold-rebuild"
        ) { statistics in
            statistics.hitCount == 0
                && statistics.missCount == 0
                && statistics.evictionCount == 0
                && statistics.rejectionCount == 0
                && statistics.residentCount == options.residentCount
        }
        withExtendedLifetime(recovered) {}
        try FileManager.default.removeItem(at: directory)
        return (duration, UInt64(options.residentCount))
    } catch {
        try? FileManager.default.removeItem(at: directory)
        throw error
    }
}

private func statisticsModes(for run: Int) -> [StatisticsMode] {
    run.isMultiple(of: 2)
        ? [.disabled, .enabled]
        : [.enabled, .disabled]
}

private func createPopulatedDirectory(
    _ directory: URL,
    options: Options,
    value: Data
) async throws {
    let cache = try await makeCache(
        directory: directory,
        options: options,
        statisticsMode: .disabled
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
    statisticsMode: StatisticsMode,
    run: Int
) -> URL {
    root.appendingPathComponent(
        "\(name)-\(statisticsMode.name)-\(run)",
        isDirectory: true
    )
}

private func verifyStatistics(
    _ statistics: CacheStatistics?,
    mode: StatisticsMode,
    scenario: String,
    enabledMatches: (CacheStatistics) -> Bool
) throws {
    switch mode {
    case .disabled:
        guard statistics == nil else {
            throw BenchmarkError.invalidStatistics(
                "\(scenario) disabled collection returned a snapshot"
            )
        }
    case .enabled:
        guard let statistics, enabledMatches(statistics) else {
            throw BenchmarkError.invalidStatistics(
                "\(scenario) enabled snapshot did not match its workload"
            )
        }
    }
}

private func mixedReadCount(
    operations: Int,
    readThreshold: Int
) -> Int {
    var count = 0
    for operation in 0..<operations {
        if Int(mixedToken(operation: operation) % 10_000) < readThreshold {
            count += 1
        }
    }
    return count
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
    _ results: [Comparison],
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
    print("statistics pairing: even disabled/enabled, odd enabled/disabled")
    print("statistics getter and validation: outside timed region")
    print()
    print("absolute results")
    print("scenario\tstatistics\tmedian ns/op\toperations/s\tchecksum")

    for comparison in results {
        for result in [comparison.disabled, comparison.enabled] {
            print(
                String(
                    format: "%@\t%@\t%.2f\t%.0f\t%llu",
                    result.name,
                    result.statisticsMode.name,
                    result.nanosecondsPerOperation,
                    result.operationsPerSecond,
                    result.checksum
                )
            )
        }
    }

    print()
    print("relative statistics collection overhead")
    print("scenario\tenabled vs disabled")
    for comparison in results {
        print(
            String(
                format: "%@\t%+.2f%%",
                comparison.disabled.name,
                comparison.relativeOverheadPercent
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
          --runs <count>          Even independent timed runs (default 4)
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
