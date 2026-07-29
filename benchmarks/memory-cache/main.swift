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
    var runs = 5

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

private typealias MemoryCache = LRUMemoryCache<Int, Data>

private func makeCache(
    options: Options
) -> MemoryCache {
    MemoryCache(
        configuration: .init(
            maximumCost: options.capacity * options.valueSize,
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

private func measure(
    name: String,
    operations: Int,
    runs: Int,
    prepare: () -> () -> UInt64
) -> Measurement {
    var durations: [UInt64] = []
    durations.reserveCapacity(runs)
    var checksum: UInt64 = 0

    for _ in 0..<runs {
        let execute = prepare()
        let start = DispatchTime.now().uptimeNanoseconds
        checksum &+= execute()
        durations.append(DispatchTime.now().uptimeNanoseconds - start)
    }

    durations.sort()
    return Measurement(
        name: name,
        operations: operations,
        medianNanoseconds: durations[durations.count / 2],
        checksum: checksum
    )
}

private func run(options: Options) -> [Measurement] {
    let value = Data(repeating: 0xA5, count: options.valueSize)
    var results: [Measurement] = []

    results.append(
        measure(
            name: "warm-hit",
            operations: options.operations,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
                var checksum: UInt64 = 0
                for operation in 0..<options.operations {
                    let key = operation % options.capacity
                    checksum &+= UInt64(cache.value(for: key)?.count ?? 0)
                }
                return checksum
            }
        }
    )

    results.append(
        measure(
            name: "miss",
            operations: options.operations,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
                var checksum: UInt64 = 0
                for operation in 0..<options.operations {
                    let key = options.capacity
                        + operation % (options.keySpace - options.capacity)
                    if cache.value(for: key) == nil {
                        checksum &+= 1
                    }
                }
                return checksum
            }
        }
    )

    results.append(
        measure(
            name: "resident-overwrite",
            operations: options.operations,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
                for operation in 0..<options.operations {
                    cache.insert(
                        value,
                        for: operation % options.capacity
                    )
                }
                return UInt64(options.operations)
            }
        }
    )

    results.append(
        measure(
            name: "evicting-insert",
            operations: options.operations,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
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
            }
        }
    )

    results.append(
        measure(
            name: "mixed-80r-15w-5d",
            operations: options.operations,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
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
            }
        }
    )

    results.append(
        measure(
            name: "remove-all",
            operations: 1,
            runs: options.runs
        ) {
            let cache = makeCache(options: options)
            populate(cache, count: options.capacity, value: value)
            return {
                cache.removeAll()
                return UInt64(options.capacity)
            }
        }
    )

    return results
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
    _ results: [Measurement],
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
        Usage: MemoryCacheBenchmark [options]
          --operations <count>  Operations per main scenario (default 1000000)
          --capacity <count>    Resident entry capacity (default 4096)
          --key-space <count>   Workload key space (default 8192)
          --value-size <bytes>  Data size per value (default 4096)
          --runs <count>        Independent timed runs (default 5)
          --help                Show this help
        """
    )
}

do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    printResults(run(options: options), options: options)
} catch {
    fputs("MemoryCacheBenchmark: \(error)\n", stderr)
    printUsage()
    exit(EXIT_FAILURE)
}
