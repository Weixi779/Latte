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
    var operations = 1_000_000
    var capacity = 4_096
    var keySpace = 8_192
    var valueSize = 4_096
    var runs = 6

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
            case "--capacity":
                options.capacity = try positiveInteger(value, for: argument)
            case "--key-space":
                options.keySpace = try positiveInteger(value, for: argument)
            case "--value-size":
                options.valueSize = try positiveInteger(value, for: argument)
            case "--runs":
                options.runs = try positiveInteger(value, for: argument)
            default:
                throw BenchmarkError.unknownArgument(argument)
            }
            index += 2
        }

        guard options.keySpace > options.capacity else {
            throw BenchmarkError.invalidValue(
                "--key-space must be greater than --capacity"
            )
        }
        guard options.capacity <= Int.max / options.valueSize else {
            throw BenchmarkError.invalidValue(
                "--capacity multiplied by --value-size is too large"
            )
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

private struct PreparedMeasurement {
    let execute: () -> UInt64
    let verify: (UInt64) throws -> Void
}

private typealias MemoryCache = LRUMemoryCache<Int, Data>

private func makeCache(
    options: Options,
    statisticsMode: StatisticsMode
) -> MemoryCache {
    MemoryCache(
        configuration: .init(
            maximumCost: options.capacity * options.valueSize,
            isStatisticsEnabled: statisticsMode.isEnabled,
            weigher: { _, data in data.count }
        )
    )
}

private func populate(
    _ cache: MemoryCache,
    count: Int,
    value: Data
) {
    for key in 0..<count {
        cache.insert(value, for: key)
    }
}

private func measureComparison(
    name: String,
    operations: Int,
    options: Options,
    prepare: (StatisticsMode) -> PreparedMeasurement
) throws -> Comparison {
    var disabledSamples = MeasurementSamples()
    var enabledSamples = MeasurementSamples()
    disabledSamples.durations.reserveCapacity(options.runs)
    enabledSamples.durations.reserveCapacity(options.runs)

    for run in 0..<options.runs {
        for statisticsMode in statisticsModes(for: run) {
            let prepared = prepare(statisticsMode)
            let start = DispatchTime.now().uptimeNanoseconds
            let checksum = prepared.execute()
            let duration = DispatchTime.now().uptimeNanoseconds - start
            try prepared.verify(checksum)

            switch statisticsMode {
            case .disabled:
                disabledSamples.record(
                    duration: duration,
                    checksum: checksum
                )
            case .enabled:
                enabledSamples.record(
                    duration: duration,
                    checksum: checksum
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

private func statisticsModes(for run: Int) -> [StatisticsMode] {
    run.isMultiple(of: 2)
        ? [.disabled, .enabled]
        : [.enabled, .disabled]
}

private func run(options: Options) throws -> [Comparison] {
    let value = Data(repeating: 0xA5, count: options.valueSize)
    let residentCost = options.capacity * options.valueSize
    var results: [Comparison] = []

    results.append(
        try measureComparison(
            name: "warm-hit",
            operations: options.operations,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                var checksum: UInt64 = 0
                for operation in 0..<options.operations {
                    let key = operation % options.capacity
                    checksum &+= UInt64(cache.value(for: key)?.count ?? 0)
                }
                return checksum
            } verify: { _ in
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "warm-hit"
                ) { statistics in
                    statistics == CacheStatistics(
                        hitCount: UInt64(options.operations),
                        residentCount: options.capacity,
                        residentCost: residentCost
                    )
                }
            }
        }
    )

    results.append(
        try measureComparison(
            name: "miss",
            operations: options.operations,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                var checksum: UInt64 = 0
                for operation in 0..<options.operations {
                    let key = options.capacity
                        + operation % (options.keySpace - options.capacity)
                    if cache.value(for: key) == nil {
                        checksum &+= 1
                    }
                }
                return checksum
            } verify: { _ in
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "miss"
                ) { statistics in
                    statistics == CacheStatistics(
                        missCount: UInt64(options.operations),
                        residentCount: options.capacity,
                        residentCost: residentCost
                    )
                }
            }
        }
    )

    results.append(
        try measureComparison(
            name: "resident-overwrite",
            operations: options.operations,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                for operation in 0..<options.operations {
                    cache.insert(
                        value,
                        for: operation % options.capacity
                    )
                }
                return UInt64(options.operations)
            } verify: { _ in
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "resident-overwrite"
                ) { statistics in
                    statistics == CacheStatistics(
                        residentCount: options.capacity,
                        residentCost: residentCost
                    )
                }
            }
        }
    )

    results.append(
        try measureComparison(
            name: "evicting-insert",
            operations: options.operations,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                let distanceToWrap = options.keySpace
                    - options.capacity
                for operation in 0..<options.operations {
                    let offset = operation % options.keySpace
                    let key = offset < distanceToWrap
                        ? options.capacity + offset
                        : offset - distanceToWrap
                    cache.insert(value, for: key)
                }
                return UInt64(options.operations)
            } verify: { _ in
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "evicting-insert"
                ) { statistics in
                    statistics == CacheStatistics(
                        evictionCount: UInt64(options.operations),
                        evictedCost: saturatingProduct(
                            options.operations,
                            options.valueSize
                        ),
                        residentCount: options.capacity,
                        residentCost: residentCost
                    )
                }
            }
        }
    )

    let mixedRequestCount = mixedReadCount(operations: options.operations)
    results.append(
        try measureComparison(
            name: "mixed-80r-15w-5d",
            operations: options.operations,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                var checksum: UInt64 = 0
                for operation in 0..<options.operations {
                    let key = mixedKey(
                        operation: operation,
                        keySpace: options.keySpace
                    )
                    switch operation % 20 {
                    case 0..<16:
                        if cache.value(for: key) != nil {
                            checksum &+= 1
                        }
                    case 16..<19:
                        cache.insert(value, for: key)
                    default:
                        cache.removeValue(for: key)
                    }
                }
                return checksum
            } verify: { checksum in
                let requestCount = UInt64(mixedRequestCount)
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "mixed-80r-15w-5d"
                ) { statistics in
                    statistics.hitCount == checksum
                        && statistics.missCount
                            == requestCount - checksum
                        && statistics.rejectionCount == 0
                        && statistics.residentCount <= options.capacity
                        && statistics.residentCost
                            == statistics.residentCount * options.valueSize
                }
            }
        }
    )

    results.append(
        try measureComparison(
            name: "remove-all",
            operations: 1,
            options: options
        ) { statisticsMode in
            let cache = makeCache(
                options: options,
                statisticsMode: statisticsMode
            )
            populate(cache, count: options.capacity, value: value)
            return PreparedMeasurement {
                cache.removeAll()
                return UInt64(options.capacity)
            } verify: { _ in
                try verifyStatistics(
                    cache.statistics,
                    mode: statisticsMode,
                    scenario: "remove-all"
                ) { statistics in
                    statistics == CacheStatistics()
                }
            }
        }
    )

    return results
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

private func mixedReadCount(operations: Int) -> Int {
    operations / 20 * 16 + min(operations % 20, 16)
}

private func saturatingProduct(_ lhs: Int, _ rhs: Int) -> UInt64 {
    let (product, overflow) = UInt64(lhs).multipliedReportingOverflow(
        by: UInt64(rhs)
    )
    return overflow ? .max : product
}

private func mixedKey(
    operation: Int,
    keySpace: Int
) -> Int {
    let mixed = UInt64(operation) &* 6_364_136_223_846_793_005
        &+ 1_442_695_040_888_963_407
    return Int(mixed % UInt64(keySpace))
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

private func printResults(
    _ results: [Comparison],
    options: Options
) {
    print("MemoryCacheBenchmark")
    print("dispatch: concrete LRUMemoryCache")
    print("build configuration: \(buildConfiguration())")
    print("OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
    print(
        "active processors: "
            + String(ProcessInfo.processInfo.activeProcessorCount)
    )
    print("operations per main scenario: \(options.operations)")
    print("capacity: \(options.capacity) entries")
    print("key space: \(options.keySpace)")
    print("value size: \(options.valueSize) bytes")
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
        Usage: MemoryCacheBenchmark [options]
          --operations <count>  Operations per main scenario (default 1000000)
          --capacity <count>    Resident entry capacity (default 4096)
          --key-space <count>   Workload key space (default 8192)
          --value-size <bytes>  Data size per value (default 4096)
          --runs <count>        Even independent timed runs (default 6)
          --help                Show this help
        """
    )
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    printResults(try run(options: options), options: options)
} catch {
    fputs("MemoryCacheBenchmark: \(error)\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}
