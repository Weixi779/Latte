//
//  LRUMemoryCache.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// A thread-safe, cost-aware in-memory least-recently-used cache.
///
/// Lookups refresh recency. Insertions can evict one or more least-recently
/// used values until the configured cost budget is satisfied.
public final class LRUMemoryCache<Key: Hashable, Value>: Caching {
    /// Construction-time settings for an ``LRUMemoryCache``.
    public struct Configuration {
        /// Computes the nonnegative cost recorded for a value at insertion.
        ///
        /// A weigher can be called concurrently when callers insert from
        /// multiple threads. It must not rely on unsynchronized mutable state.
        public typealias Weigher = @Sendable (Key, Value) -> Int

        private enum CostCalculation {
            case unit
            case custom(Weigher)
        }

        /// The maximum sum of the recorded costs of resident values.
        public let maximumCost: Int

        /// Whether this cache instance collects statistics.
        public let isStatisticsEnabled: Bool

        private let costCalculation: CostCalculation

        /// Creates a configuration that gives every value a cost of one,
        /// making `maximumCost` an entry-count bound.
        public init(maximumCost: Int) {
            self.init(
                maximumCost: maximumCost,
                isStatisticsEnabled: false
            )
        }

        /// Creates a configuration that gives every value a cost of one
        /// and optionally collects statistics.
        public init(
            maximumCost: Int,
            isStatisticsEnabled: Bool
        ) {
            precondition(maximumCost >= 0, "Maximum cost must not be negative")

            self.maximumCost = maximumCost
            self.isStatisticsEnabled = isStatisticsEnabled
            self.costCalculation = .unit
        }

        /// Creates a configuration with a custom value weigher.
        public init(
            maximumCost: Int,
            weigher: @escaping Weigher
        ) {
            self.init(
                maximumCost: maximumCost,
                isStatisticsEnabled: false,
                weigher: weigher
            )
        }

        /// Creates a configuration with a custom value weigher
        /// and optionally collects statistics.
        public init(
            maximumCost: Int,
            isStatisticsEnabled: Bool,
            weigher: @escaping Weigher
        ) {
            precondition(maximumCost >= 0, "Maximum cost must not be negative")

            self.maximumCost = maximumCost
            self.isStatisticsEnabled = isStatisticsEnabled
            self.costCalculation = .custom(weigher)
        }

        fileprivate func cost(for key: Key, value: Value) -> Int {
            switch costCalculation {
            case .unit:
                1
            case let .custom(weigher):
                weigher(key, value)
            }
        }
    }

    private struct Entry {
        let key: Key
        let value: Value
        let cost: Int
    }

    private struct State {
        var entries: [Key: Entry] = [:]
        var recency = LRUList<Key>()
        var totalCost = 0
    }

    private let configuration: Configuration
    private let state: LockedValue<State>

    /// Creates an empty cache.
    public init(configuration: Configuration) {
        self.configuration = configuration
        self.state = LockedValue(State())
    }

    public func value(for key: Key) -> Value? {
        state.withLock { state in
            guard let entry = state.entries[key] else {
                return nil
            }

            precondition(
                state.recency.moveToMostRecent(key),
                "LRU metadata is missing for a resident value"
            )
            return entry.value
        }
    }

    public func insert(_ value: Value, for key: Key) {
        let cost = configuration.cost(for: key, value: value)
        precondition(cost >= 0, "Cache entry cost must not be negative")
        guard cost <= configuration.maximumCost else {
            return
        }

        let retiredEntries = state.withLock { state in
            var retiredEntries: [Entry] = []

            if let replaced = state.entries.removeValue(forKey: key) {
                guard state.recency.remove(key) != nil else {
                    preconditionFailure(
                        "LRU metadata is missing for a resident value"
                    )
                }
                state.totalCost -= replaced.cost
                retiredEntries.append(replaced)
            }

            let costAvailableToResidents = configuration.maximumCost - cost
            while state.totalCost > costAvailableToResidents {
                guard let victimKey = state.recency.removeLeastRecentlyUsed(),
                      let victim = state.entries.removeValue(forKey: victimKey)
                else {
                    preconditionFailure(
                        "LRU cost exceeded without a resident victim"
                    )
                }

                state.totalCost -= victim.cost
                retiredEntries.append(victim)
            }

            state.recency.append(key)
            state.entries[key] = Entry(key: key, value: value, cost: cost)
            state.totalCost += cost
            return retiredEntries
        }

        withExtendedLifetime(retiredEntries) {}
    }

    public func removeValue(for key: Key) {
        let retiredEntry = state.withLock { state in
            let removedEntry = state.entries.removeValue(forKey: key)
            let removedKey = state.recency.remove(key)

            precondition(
                (removedEntry != nil) == (removedKey != nil),
                "Resident values and LRU metadata are inconsistent"
            )
            if let removedEntry {
                state.totalCost -= removedEntry.cost
            }
            return removedEntry
        }

        withExtendedLifetime(retiredEntry) {}
    }

    public func removeAll() {
        let retiredEntries = state.withLock { state in
            var retiredEntries: [Key: Entry] = [:]
            swap(&state.entries, &retiredEntries)
            state.recency.removeAll()
            state.totalCost = 0
            return retiredEntries
        }

        withExtendedLifetime(retiredEntries) {}
    }
}

extension LRUMemoryCache: @unchecked Sendable
where Key: Sendable, Value: Sendable {}
