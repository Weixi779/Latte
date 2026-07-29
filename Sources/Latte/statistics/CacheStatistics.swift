//
//  CacheStatistics.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

/// A snapshot of cumulative cache outcomes and current residency.
///
/// Cost units belong to the concrete cache. Cost values from different cache
/// instances are directly comparable only when their configurations use the
/// same unit.
public struct CacheStatistics: Sendable, Equatable {
    /// The number of lookups that returned a cached value.
    public let hitCount: UInt64

    /// The number of lookups that returned an ordinary cache miss.
    public let missCount: UInt64

    /// The number of residents removed to enforce capacity.
    public let evictionCount: UInt64

    /// The cumulative cost of residents removed to enforce capacity.
    public let evictedCost: UInt64

    /// The number of candidates normally rejected by configuration or policy.
    public let rejectionCount: UInt64

    /// The number of values resident when this snapshot was created.
    public let residentCount: Int

    /// The total cost of values resident when this snapshot was created.
    public let residentCost: Int

    /// Creates a statistics snapshot.
    public init(
        hitCount: UInt64 = 0,
        missCount: UInt64 = 0,
        evictionCount: UInt64 = 0,
        evictedCost: UInt64 = 0,
        rejectionCount: UInt64 = 0,
        residentCount: Int = 0,
        residentCost: Int = 0
    ) {
        precondition(
            residentCount >= 0,
            "Resident count must not be negative"
        )
        precondition(
            residentCost >= 0,
            "Resident cost must not be negative"
        )

        self.hitCount = hitCount
        self.missCount = missCount
        self.evictionCount = evictionCount
        self.evictedCost = evictedCost
        self.rejectionCount = rejectionCount
        self.residentCount = residentCount
        self.residentCost = residentCost
    }

    /// The saturating sum of cache hits and misses.
    public var requestCount: UInt64 {
        let (result, overflow) = hitCount.addingReportingOverflow(missCount)
        return overflow ? .max : result
    }

    /// The fraction of completed lookup outcomes that were hits.
    ///
    /// The value is `nil` when no lookup outcome has been recorded.
    public var hitRate: Double? {
        guard hitCount != 0 || missCount != 0 else {
            return nil
        }

        let hits = Double(hitCount)
        return hits / (hits + Double(missCount))
    }
}
