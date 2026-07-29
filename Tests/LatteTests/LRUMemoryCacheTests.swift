//
//  LRUMemoryCacheTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/29.
//

import Dispatch
import Testing
@testable import Latte

@Suite("LRUMemoryCache")
struct LRUMemoryCacheTests {
    @Test("A hit refreshes recency")
    func hitRefreshesRecency() {
        let cache = LRUMemoryCache<String, Int>(
            configuration: .init(maximumCost: 2)
        )
        cache.insert(1, for: "a")
        cache.insert(2, for: "b")

        #expect(cache.value(for: "a") == 1)
        cache.insert(3, for: "c")

        #expect(cache.value(for: "a") == 1)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == 3)
    }

    @Test("Weighted insertion can evict multiple least-recent values")
    func weightedInsertionEvictsMultipleValues() {
        let cache = LRUMemoryCache<String, Int>(
            configuration: .init(
                maximumCost: 10,
                weigher: { _, value in value }
            )
        )
        cache.insert(2, for: "a")
        cache.insert(3, for: "b")
        cache.insert(4, for: "c")

        cache.insert(8, for: "d")

        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c") == nil)
        #expect(cache.value(for: "d") == 8)
    }

    @Test("Updating a resident replaces its value, cost, and recency")
    func updateReplacesResident() {
        struct Value: Equatable {
            let payload: String
            let cost: Int
        }

        let cache = LRUMemoryCache<String, Value>(
            configuration: .init(
                maximumCost: 10,
                weigher: { _, value in value.cost }
            )
        )
        cache.insert(Value(payload: "old", cost: 3), for: "a")
        cache.insert(Value(payload: "b", cost: 3), for: "b")
        cache.insert(Value(payload: "c", cost: 3), for: "c")

        cache.insert(Value(payload: "new", cost: 6), for: "a")

        #expect(cache.value(for: "a")?.payload == "new")
        #expect(cache.value(for: "b") == nil)
        #expect(cache.value(for: "c")?.payload == "c")
    }

    @Test("An oversized update preserves the old resident")
    func oversizedUpdatePreservesResident() {
        let cache = LRUMemoryCache<String, Int>(
            configuration: .init(
                maximumCost: 5,
                weigher: { _, value in value }
            )
        )
        cache.insert(3, for: "a")

        cache.insert(6, for: "a")

        #expect(cache.value(for: "a") == 3)
    }

    @Test("Zero-cost values are valid")
    func zeroCostValuesAreValid() {
        let cache = LRUMemoryCache<Int, Int>(
            configuration: .init(
                maximumCost: 0,
                weigher: { _, _ in 0 }
            )
        )

        for value in 0..<10 {
            cache.insert(value, for: value)
        }

        for value in 0..<10 {
            #expect(cache.value(for: value) == value)
        }
    }

    @Test("Cost is captured as an insertion-time snapshot")
    func costIsInsertionSnapshot() {
        final class Value {
            var cost: Int

            init(cost: Int) {
                self.cost = cost
            }
        }

        let cache = LRUMemoryCache<String, Value>(
            configuration: .init(
                maximumCost: 5,
                weigher: { _, value in value.cost }
            )
        )
        let first = Value(cost: 2)
        cache.insert(first, for: "a")

        first.cost = 100
        cache.insert(Value(cost: 3), for: "b")

        #expect(cache.value(for: "a") === first)
        #expect(cache.value(for: "b") != nil)

        cache.insert(Value(cost: 1), for: "c")

        #expect(cache.value(for: "a") == nil)
        #expect(cache.value(for: "b") != nil)
        #expect(cache.value(for: "c") != nil)
    }

    @Test("Concurrent operations preserve a usable cache state")
    func concurrentOperations() {
        let count = 1_000
        let cache = LRUMemoryCache<Int, Int>(
            configuration: .init(maximumCost: count)
        )

        DispatchQueue.concurrentPerform(iterations: count) { key in
            cache.insert(key, for: key)
        }

        DispatchQueue.concurrentPerform(iterations: count) { key in
            #expect(cache.value(for: key) == key)
        }

        cache.removeAll()
        cache.insert(42, for: 42)

        #expect(cache.value(for: 42) == 42)
    }

    @Test("Mixed concurrent operations preserve state coherence")
    func mixedConcurrentOperations() {
        let keyCount = 8
        let cache = LRUMemoryCache<Int, Int>(
            configuration: .init(maximumCost: 4)
        )

        DispatchQueue.concurrentPerform(iterations: 20_000) { iteration in
            let key = iteration % keyCount

            switch iteration % 7 {
            case 0, 1:
                cache.insert(key, for: key)
            case 2, 3:
                _ = cache.value(for: key)
            case 4:
                cache.removeValue(for: key)
            case 5:
                cache.removeAll()
            default:
                cache.insert(key, for: key)
                _ = cache.value(for: key)
            }
        }

        cache.removeAll()
        for key in 0..<5 {
            cache.insert(key, for: key)
        }

        #expect(cache.value(for: 0) == nil)
        for key in 1..<5 {
            #expect(cache.value(for: key) == key)
        }
    }

    @Test("Matches a reference cache across 20,000 seeded operations")
    func matchesSeededReferenceCache() {
        let maximumCost = 31
        let keyCount = 47
        let cache = LRUMemoryCache<Int, DifferentialValue>(
            configuration: .init(
                maximumCost: maximumCost,
                weigher: { _, value in value.cost }
            )
        )
        var model = LRUMemoryCacheModel(maximumCost: maximumCost)
        var generator = SeededGenerator(seed: 0x1A77_ECAC)

        for sequence in 0..<20_000 {
            if sequence > 0, sequence.isMultiple(of: 997) {
                cache.removeAll()
                model.removeAll()
            }

            let key = Int(generator.next() % UInt64(keyCount))

            switch generator.next() % 4 {
            case 0:
                let actual = cache.value(for: key)
                let expected = model.value(for: key)
                #expect(actual == expected)

            case 1:
                cache.removeValue(for: key)
                model.removeValue(for: key)

            default:
                let value = DifferentialValue(
                    payload: sequence,
                    cost: Int(generator.next() % 40)
                )
                cache.insert(value, for: key)
                model.insert(value, for: key)

                let actual = cache.value(for: key)
                let expected = model.value(for: key)
                #expect(actual == expected)
            }

            let observedKey = Int(generator.next() % UInt64(keyCount))
            let actualObservation = cache.value(for: observedKey)
            let expectedObservation = model.value(for: observedKey)
            #expect(actualObservation == expectedObservation)
            #expect(model.totalCost <= maximumCost)
        }

        for key in 0..<keyCount {
            let actual = cache.value(for: key)
            let expected = model.value(for: key)
            #expect(actual == expected)
        }
    }

    @Test(
        "Retired values can reenter the cache while deinitializing",
        arguments: RetirementPath.allCases
    )
    fileprivate func deinitializationCanReenterCache(_ path: RetirementPath) {
        let didDeinitialize = DispatchSemaphore(value: 0)
        let didFinishOperation = DispatchSemaphore(value: 0)
        let cache = LRUMemoryCache<String, ReentrantValue>(
            configuration: .init(maximumCost: 1)
        )
        cache.insert(
            ReentrantValue {
                cache.removeAll()
                didDeinitialize.signal()
            },
            for: "resident"
        )

        DispatchQueue.global().async {
            path.retireValue(from: cache)
            didFinishOperation.signal()
        }

        let operationResult = didFinishOperation.wait(
            timeout: .now() + .seconds(2)
        )
        #expect(operationResult == .success)
        guard operationResult == .success else {
            return
        }

        #expect(
            didDeinitialize.wait(timeout: .now() + .seconds(2)) == .success
        )
    }

    @Test(
        "Retired keys can reenter the cache while deinitializing",
        arguments: RetirementPath.allCases
    )
    fileprivate func keyDeinitializationCanReenterCache(
        _ path: RetirementPath
    ) {
        let didDeinitialize = DispatchSemaphore(value: 0)
        let didFinishOperation = DispatchSemaphore(value: 0)
        let cache = LRUMemoryCache<ReentrantKey, Int>(
            configuration: .init(maximumCost: 1)
        )

        func insertResident() {
            let resident = ReentrantKey(
                id: "resident",
                onDeinitialize: { [unowned cache] in
                    cache.removeAll()
                    didDeinitialize.signal()
                }
            )
            cache.insert(1, for: resident)
        }

        insertResident()
        let residentProbe = ReentrantKey(id: "resident")

        DispatchQueue.global().async {
            path.retireKey(from: cache, residentProbe: residentProbe)
            didFinishOperation.signal()
        }

        let operationResult = didFinishOperation.wait(
            timeout: .now() + .seconds(2)
        )
        #expect(operationResult == .success)
        guard operationResult == .success else {
            return
        }

        #expect(
            didDeinitialize.wait(timeout: .now() + .seconds(2)) == .success
        )
    }
}

private struct DifferentialValue: Equatable, Sendable {
    let payload: Int
    let cost: Int
}

private struct LRUMemoryCacheModel {
    let maximumCost: Int
    private(set) var totalCost = 0
    private var keys: [Int] = []
    private var entries: [Int: DifferentialValue] = [:]

    init(maximumCost: Int) {
        self.maximumCost = maximumCost
    }

    mutating func value(for key: Int) -> DifferentialValue? {
        guard let value = entries[key],
              let index = keys.firstIndex(of: key)
        else {
            return nil
        }

        keys.remove(at: index)
        keys.append(key)
        return value
    }

    mutating func insert(_ value: DifferentialValue, for key: Int) {
        guard value.cost <= maximumCost else {
            return
        }

        if let index = keys.firstIndex(of: key),
           let replaced = entries.removeValue(forKey: key)
        {
            keys.remove(at: index)
            totalCost -= replaced.cost
        }

        while totalCost > maximumCost - value.cost {
            let victim = keys.removeFirst()
            totalCost -= entries.removeValue(forKey: victim)!.cost
        }

        keys.append(key)
        entries[key] = value
        totalCost += value.cost
    }

    mutating func removeValue(for key: Int) {
        guard let index = keys.firstIndex(of: key),
              let removed = entries.removeValue(forKey: key)
        else {
            return
        }

        keys.remove(at: index)
        totalCost -= removed.cost
    }

    mutating func removeAll() {
        keys.removeAll()
        entries.removeAll()
        totalCost = 0
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

private enum RetirementPath: CaseIterable, CustomTestStringConvertible, Sendable {
    case removal
    case eviction
    case update
    case removeAll

    var testDescription: String {
        switch self {
        case .removal:
            "explicit removal"
        case .eviction:
            "capacity eviction"
        case .update:
            "same-key update"
        case .removeAll:
            "remove all"
        }
    }

    func retireValue(
        from cache: LRUMemoryCache<String, ReentrantValue>
    ) {
        switch self {
        case .removal:
            cache.removeValue(for: "resident")
        case .eviction:
            cache.insert(ReentrantValue {}, for: "replacement")
        case .update:
            cache.insert(ReentrantValue {}, for: "resident")
        case .removeAll:
            cache.removeAll()
        }
    }

    func retireKey(
        from cache: LRUMemoryCache<ReentrantKey, Int>,
        residentProbe: ReentrantKey
    ) {
        switch self {
        case .removal:
            cache.removeValue(for: residentProbe)
        case .eviction:
            cache.insert(2, for: ReentrantKey(id: "replacement"))
        case .update:
            cache.insert(2, for: residentProbe)
        case .removeAll:
            cache.removeAll()
        }
    }
}

private final class ReentrantValue: @unchecked Sendable {
    private let onDeinitialize: @Sendable () -> Void

    init(onDeinitialize: @escaping @Sendable () -> Void) {
        self.onDeinitialize = onDeinitialize
    }

    deinit {
        onDeinitialize()
    }
}

private final class ReentrantKey: Hashable, @unchecked Sendable {
    let id: String
    private let onDeinitialize: @Sendable () -> Void

    init(
        id: String,
        onDeinitialize: @escaping @Sendable () -> Void = {}
    ) {
        self.id = id
        self.onDeinitialize = onDeinitialize
    }

    static func == (lhs: ReentrantKey, rhs: ReentrantKey) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    deinit {
        onDeinitialize()
    }
}
