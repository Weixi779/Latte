# cache statistics

Latte provides opt-in, process-local statistics for both memory and file caches.
The shared snapshot makes the two implementations familiar to inspect without
pretending that their storage costs or concurrency models are identical.

Statistics are intended for validation, benchmarks, and runtime inspection.
They are disabled by default and do not change cache behavior, persistence
formats, or the core `Caching` and `AsyncCaching` protocols.

## configuration

Statistics are selected when a cache is constructed:

```swift
let memoryCache = LRUMemoryCache<String, Data>(
    configuration: .init(
        maximumCost: 100,
        isStatisticsEnabled: true
    )
)

let fileCache = try await LRUFileCache<String>(
    directory: directory,
    configuration: .init(
        maximumDiskUsage: 100 * 1024 * 1024,
        isStatisticsEnabled: true
    ),
    stableKeyEncoder: { Data($0.utf8) }
)
```

The setting has no dynamic toggle:

- disabled caches return `nil` from `statistics`;
- enabled caches return a zero-valued snapshot before their first operation.

## snapshot

```swift
public struct CacheStatistics: Sendable, Equatable {
    public let hitCount: UInt64
    public let missCount: UInt64
    public let evictionCount: UInt64
    public let evictedCost: UInt64
    public let rejectionCount: UInt64
    public let residentCount: Int
    public let residentCost: Int

    public var requestCount: UInt64 { get }
    public var hitRate: Double? { get }
}
```

All values are nonnegative. Counters and derived totals saturate rather than
overflow. `hitRate` is `nil` before any completed request and is calculated
from the unsaturated floating-point sum of hits and misses, so it remains
meaningful even after `requestCount` saturates.

`residentCost` and `evictedCost` use the cache implementation's cost unit.
Memory caches use their configured weigher; file caches use allocated bytes
when available and logical bytes as a fallback. Cost values are directly
comparable only when their units match.

## capabilities

Statistics use dedicated capability protocols instead of changing the core
cache protocols:

```swift
public protocol CacheStatisticsProviding {
    var statistics: CacheStatistics? { get }
}

public protocol AsyncCacheStatisticsProviding {
    var statistics: CacheStatistics? { get async }
}
```

`LRUMemoryCache` adopts `CacheStatisticsProviding`. `LRUFileCache` adopts
`AsyncCacheStatisticsProviding`.

These capabilities live in the main `Latte` target. Disabled collection is
intentionally lightweight, and keeping the protocols with the cache
implementations avoids an extra module boundary for one value type and two
accessors.

## metric semantics

### requests

A request is counted only when `value(for:)` returns normally:

- returned value: one hit;
- returned `nil`: one miss;
- propagated error: neither hit nor miss.

Internal storage failures that preserve the existing lookup result still count
that result. For example, a failed expired-file cleanup that returns `nil` is a
miss, while a failed access-time touch that still returns data is a hit.

### rejections

A rejection is an insertion candidate that the cache declines before it
becomes resident, such as an oversized value or an invalid file-cache cost
result.

A failed replacement for an already-resident key does not remove the existing
value. An insertion that throws after partially completing capacity trimming
is not a rejection.

### evictions

Evictions count entries selected and removed to satisfy capacity. Explicit
removal, expiration, reconciliation, and startup cleanup are not evictions.

Each successfully completed victim contributes one eviction and its cost. If a
selected file victim has already disappeared, removing it from the
authoritative inventory still counts as an eviction. If trimming removes some
victims and then fails, completed victims remain counted and the failed,
still-tracked victim does not.

### residency

`residentCount` and `residentCost` describe the cache's authoritative state at
the same synchronization point as the historical counters.

They are derived from current state rather than accumulated as independent
deltas. This keeps snapshots aligned with replacements, explicit removals,
expiration, reconciliation, and partial failures.

## state and lifecycle

### memory cache

The accumulator is owned by the same lock that protects the LRU list, lookup
table, and total cost. Snapshot creation occurs under that lock, while key and
value destruction remains outside it.

### file cache

The accumulator is owned by the file cache's existing serial worker together
with its inventory and total cost. Reading `statistics` is nonthrowing,
performs no file-system I/O, and remains available after the cache enters an
unavailable state.

Recovered files contribute to initial residency, but historical counters start
at zero for every cache instance. Statistics are not persisted and do not
cross process launches.

## measurement

The memory and file benchmark executables can compare collection-disabled and
collection-enabled workloads.

Each logical run pairs both modes and alternates AB/BA order. Run counts must
be positive and even so each mode occupies each execution position equally.
Snapshot retrieval and validation occur outside the timed region. Results
report absolute duration and enabled-versus-disabled overhead; memory and file
throughput are reported separately.

See the benchmark READMEs for commands and workload details.

## compatibility

Statistics are additive:

- existing initializer selectors remain available;
- `Caching` and `AsyncCaching` are unchanged;
- file layout, marker format, and recovery behavior are unchanged;
- collection remains disabled unless explicitly requested.

## deferred work

The current API deliberately excludes reset, persisted counters, histograms,
latency measurement, event streams, exporters, and byte hit rate. These
features require separate ownership and overhead decisions and can be added
without changing the snapshot semantics above.
