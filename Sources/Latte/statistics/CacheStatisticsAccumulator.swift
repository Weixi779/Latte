//
//  CacheStatisticsAccumulator.swift
//  Latte
//
//  Created by weixi on 2026/7/29.
//

struct CacheStatisticsAccumulator: Sendable {
    private(set) var hitCount: UInt64
    private(set) var missCount: UInt64
    private(set) var evictionCount: UInt64
    private(set) var evictedCost: UInt64
    private(set) var rejectionCount: UInt64

    init(
        hitCount: UInt64 = 0,
        missCount: UInt64 = 0,
        evictionCount: UInt64 = 0,
        evictedCost: UInt64 = 0,
        rejectionCount: UInt64 = 0
    ) {
        self.hitCount = hitCount
        self.missCount = missCount
        self.evictionCount = evictionCount
        self.evictedCost = evictedCost
        self.rejectionCount = rejectionCount
    }

    mutating func recordHit() {
        hitCount = addingWithoutOverflow(hitCount, 1)
    }

    mutating func recordMiss() {
        missCount = addingWithoutOverflow(missCount, 1)
    }

    mutating func recordRejection() {
        rejectionCount = addingWithoutOverflow(rejectionCount, 1)
    }

    mutating func recordEviction(cost: Int) {
        precondition(cost >= 0, "Evicted cost must not be negative")

        evictionCount = addingWithoutOverflow(evictionCount, 1)
        evictedCost = addingWithoutOverflow(evictedCost, UInt64(cost))
    }

    func snapshot(
        residentCount: Int,
        residentCost: Int
    ) -> CacheStatistics {
        CacheStatistics(
            hitCount: hitCount,
            missCount: missCount,
            evictionCount: evictionCount,
            evictedCost: evictedCost,
            rejectionCount: rejectionCount,
            residentCount: residentCount,
            residentCost: residentCost
        )
    }

    private func addingWithoutOverflow(
        _ lhs: UInt64,
        _ rhs: UInt64
    ) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
