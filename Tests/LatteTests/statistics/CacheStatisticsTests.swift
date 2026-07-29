//
//  CacheStatisticsTests.swift
//  LatteTests
//
//  Created by weixi on 2026/7/29.
//

import Testing
@testable import Latte

@Suite("Cache statistics")
struct CacheStatisticsTests {
    @Test("Snapshot preserves counters and residency")
    func snapshotValues() {
        let statistics = CacheStatistics(
            hitCount: 7,
            missCount: 3,
            evictionCount: 2,
            evictedCost: 11,
            rejectionCount: 1,
            residentCount: 4,
            residentCost: 19
        )

        #expect(statistics.hitCount == 7)
        #expect(statistics.missCount == 3)
        #expect(statistics.evictionCount == 2)
        #expect(statistics.evictedCost == 11)
        #expect(statistics.rejectionCount == 1)
        #expect(statistics.residentCount == 4)
        #expect(statistics.residentCost == 19)
        #expect(statistics.requestCount == 10)
        #expect(statistics.hitRate == 0.7)
    }

    @Test("Zero requests have no hit rate")
    func zeroRequestHitRate() {
        let statistics = CacheStatistics()

        #expect(statistics.requestCount == 0)
        #expect(statistics.hitRate == nil)
    }

    @Test("Request count saturates without distorting hit rate")
    func saturatedRequestCount() {
        let statistics = CacheStatistics(
            hitCount: .max,
            missCount: .max
        )

        #expect(statistics.requestCount == .max)
        #expect(statistics.hitRate == 0.5)
    }

    @Test("Statistics values satisfy Swift concurrency checking")
    func sendableValues() {
        requireSendable(CacheStatistics.self)
        requireSendable(CacheStatisticsAccumulator.self)
    }

    @Test("Accumulator records outcomes and residency")
    func accumulatorSnapshot() {
        var accumulator = CacheStatisticsAccumulator()
        accumulator.recordHit()
        accumulator.recordMiss()
        accumulator.recordRejection()
        accumulator.recordEviction(cost: 7)

        #expect(
            accumulator.snapshot(
                residentCount: 2,
                residentCost: 9
            ) == CacheStatistics(
                hitCount: 1,
                missCount: 1,
                evictionCount: 1,
                evictedCost: 7,
                rejectionCount: 1,
                residentCount: 2,
                residentCost: 9
            )
        )
    }

    @Test("Accumulator counters saturate")
    func accumulatorSaturation() {
        var accumulator = CacheStatisticsAccumulator(
            hitCount: .max,
            missCount: .max,
            evictionCount: .max,
            evictedCost: .max,
            rejectionCount: .max
        )

        accumulator.recordHit()
        accumulator.recordMiss()
        accumulator.recordEviction(cost: 1)
        accumulator.recordRejection()

        #expect(
            accumulator.snapshot(
                residentCount: 0,
                residentCost: 0
            ) == CacheStatistics(
                hitCount: .max,
                missCount: .max,
                evictionCount: .max,
                evictedCost: .max,
                rejectionCount: .max
            )
        )
    }

    @Test("Construction-time statistics collection defaults to disabled")
    func configurationDefaults() {
        let memory = LRUMemoryCache<String, Int>.Configuration(
            maximumCost: 1
        )
        let weightedMemory = LRUMemoryCache<String, Int>.Configuration(
            maximumCost: 1,
            weigher: { _, value in value }
        )
        let trailingClosureMemory =
            LRUMemoryCache<String, Int>.Configuration(
                maximumCost: 1
            ) { _, value in
                value
            }
        let file = LRUFileCache<String>.Configuration(
            maximumDiskUsage: 1
        )

        #expect(!memory.isStatisticsEnabled)
        #expect(!weightedMemory.isStatisticsEnabled)
        #expect(!trailingClosureMemory.isStatisticsEnabled)
        #expect(!file.isStatisticsEnabled)
    }

    @Test("Construction-time statistics collection can be enabled")
    func enabledConfigurations() {
        let memory = LRUMemoryCache<String, Int>.Configuration(
            maximumCost: 1,
            isStatisticsEnabled: true
        )
        let weightedMemory = LRUMemoryCache<String, Int>.Configuration(
            maximumCost: 1,
            isStatisticsEnabled: true,
            weigher: { _, value in value }
        )
        let file = LRUFileCache<String>.Configuration(
            maximumDiskUsage: 1,
            isStatisticsEnabled: true
        )

        #expect(memory.isStatisticsEnabled)
        #expect(weightedMemory.isStatisticsEnabled)
        #expect(file.isStatisticsEnabled)
    }

    @Test("Original initializer references remain source compatible")
    func initializerReferences() {
        typealias MemoryConfiguration =
            LRUMemoryCache<String, Int>.Configuration
        typealias FileConfiguration = LRUFileCache<String>.Configuration

        let makeMemory: (Int) -> MemoryConfiguration =
            MemoryConfiguration.init(maximumCost:)
        let makeWeightedMemory:
            (Int, @escaping MemoryConfiguration.Weigher) -> MemoryConfiguration =
            MemoryConfiguration.init(maximumCost:weigher:)
        let makeConfiguredFile:
            (
                Int,
                Double,
                Double,
                Duration?,
                Duration?,
                Duration
            ) -> FileConfiguration =
            FileConfiguration.init(
                maximumDiskUsage:
                lowWatermark:
                highWatermark:
                timeToLive:
                timeToIdle:
                accessTimeUpdateInterval:
            )

        #expect(!makeMemory(1).isStatisticsEnabled)
        #expect(!makeWeightedMemory(1, { _, value in value }).isStatisticsEnabled)
        #expect(
            !makeConfiguredFile(
                1,
                0.8,
                0.9,
                nil,
                nil,
                .zero
            ).isStatisticsEnabled
        )
    }
}

private func requireSendable<T: Sendable>(_: T.Type) {}

private struct SynchronousStatisticsShape: CacheStatisticsProviding {
    let statistics: CacheStatistics?
}

private struct AsynchronousStatisticsShape: AsyncCacheStatisticsProviding {
    let storedStatistics: CacheStatistics?

    var statistics: CacheStatistics? {
        get async {
            storedStatistics
        }
    }
}

@Test("Statistics capabilities distinguish disabled and zero snapshots")
func statisticsCapabilityShapes() async {
    let disabled = SynchronousStatisticsShape(statistics: nil)
    let enabled = AsynchronousStatisticsShape(
        storedStatistics: CacheStatistics()
    )

    #expect(disabled.statistics == nil)
    #expect(await enabled.statistics == CacheStatistics())
}

#if compiler(>=6.2) && os(macOS)
@Test("Negative resident count fails its precondition")
func negativeResidentCount() async {
    await #expect(processExitsWith: .failure) {
        _ = CacheStatistics(residentCount: -1)
    }
}

@Test("Negative resident cost fails its precondition")
func negativeResidentCost() async {
    await #expect(processExitsWith: .failure) {
        _ = CacheStatistics(residentCost: -1)
    }
}
#endif
