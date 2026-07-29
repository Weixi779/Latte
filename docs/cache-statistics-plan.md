# cache statistics plan

## status

This document records the accepted first implementation of cache statistics.
Stages A through D are complete in the current source tree. It remains the
design and verification record for the capability rather than release notes.

The change is a scoped extension of the existing cache state machines. It does
not introduce another library target, a generic policy abstraction, or an
external metrics system.

## objective

Latte needs a small, stable statistics capability that can:

- compare complete cache implementations under the same workload;
- expose policy outcomes that the minimal cache contracts intentionally hide;
- validate hit rate, admission, eviction, and capacity behavior;
- measure the cost of statistics collection itself.

`LRUMemoryCache` and `LRUFileCache` use the same snapshot semantics. Their
access protocols remain separate because one implementation is synchronous and
the other serializes work asynchronously.

## accepted boundary

- Statistics collection is disabled by default.
- Collection is selected when the cache is constructed.
- There is no public dynamic enable, disable, or reset operation.
- A disabled cache returns `nil` from its statistics capability.
- An enabled cache with no observed operations returns a non-`nil` zero
  snapshot.
- Counters belong to one cache instance and begin after successful
  construction.
- Memory and file counters do not persist across process launches.
- Recovered file residents contribute to current residency but not to
  historical counters.
- Statistics state remains in the existing Latte target.
- Exporters, persisted reports, histograms, event streams, and application
  lifecycle integration are deferred.

## public api

### snapshot

Add one immutable value type:

```swift
public struct CacheStatistics: Sendable, Equatable {
    public let hitCount: UInt64
    public let missCount: UInt64
    public let evictionCount: UInt64
    public let evictedCost: UInt64
    public let rejectionCount: UInt64
    public let residentCount: Int
    public let residentCost: Int

    public init(
        hitCount: UInt64 = 0,
        missCount: UInt64 = 0,
        evictionCount: UInt64 = 0,
        evictedCost: UInt64 = 0,
        rejectionCount: UInt64 = 0,
        residentCount: Int = 0,
        residentCost: Int = 0
    )

    public var requestCount: UInt64 { get }
    public var hitRate: Double? { get }
}
```

All stored values are nonnegative. `requestCount` is the saturating sum of
`hitCount` and `missCount`. The initializer preconditions that `residentCount`
and `residentCost` are nonnegative, matching the concrete cache state types and
their existing configuration style.

`hitRate` is `nil` when both request counters are zero. Otherwise it is computed
from the unsaturated floating-point total:

```swift
let total = Double(hitCount) + Double(missCount)
return Double(hitCount) / total
```

It must not divide by the saturated `requestCount`, because two independently
saturated counters still retain a meaningful ratio.

The public initializer is required because the public capability protocols can
be implemented by cache types outside Latte.

### capabilities

Add parallel synchronous and asynchronous capability protocols:

```swift
public protocol CacheStatisticsProviding {
    var statistics: CacheStatistics? { get }
}

public protocol AsyncCacheStatisticsProviding {
    var statistics: CacheStatistics? { get async }
}
```

The protocols do not refine `Sendable`. This matches `Caching` and
`AsyncCaching` and preserves the concrete caches' existing conditional
`Sendable` conformances. The snapshot itself is `Sendable`.

`LRUMemoryCache` conforms to `CacheStatisticsProviding`.
`LRUFileCache` conforms to `AsyncCacheStatisticsProviding`.

The asynchronous getter does not throw. File statistics are in-memory state,
not a filesystem query, and remain inspectable when the cache has become
unavailable for storage operations.

### configuration

Add a construction-time option to both concrete configurations:

```swift
isStatisticsEnabled: Bool = false
```

A Boolean is sufficient for the accepted enabled/disabled model. A mode enum
would add a public type without another supported collection mode.

## metric semantics

### requests

A lookup contributes exactly one request outcome only when it returns normally:

| result | hit | miss |
|---|---:|---:|
| returns a value | +1 | 0 |
| returns `nil` | 0 | +1 |
| throws to the caller | 0 | 0 |

A file lookup can miss because the resident is absent, expired, or disappeared
from the filesystem. These remain ordinary misses. A propagated key-encoding
or storage error records no request outcome.

An internal storage error that the current file-cache state machine deliberately
absorbs does not suppress the normally returned outcome. An expiration-cleanup
deletion failure still returns `nil` and records one miss. A touch persistence
failure still returns the data and records one hit, including when the touch
discovers that the file disappeared after its data was read.

### rejection

`rejectionCount` increments when an insertion returns normally without
admitting its candidate because of cache configuration or policy.

Current examples are:

- memory cost greater than `maximumCost`;
- file `maximumDiskUsage` equal to zero;
- immediate TTL or TTI expiration;
- logical data or observed allocated size greater than the high watermark;
- a future admission policy rejecting a candidate.

A thrown insertion is not a rejection. Replacing an existing value is not a
rejection when the new candidate becomes resident.

### eviction

An eviction is the logical removal of one resident selected to enforce
capacity.

- Each selected and removed victim increments `evictionCount`.
- Its recorded cost is added to `evictedCost`.
- One insertion can evict multiple residents.
- Replacement, explicit removal, `removeAll`, expiration, startup cleanup, and
  external filesystem disappearance are not evictions.
- A failed victim deletion that leaves the resident tracked records no
  eviction.
- A victim already missing from disk is forgotten and records one logical
  eviction because capacity enforcement selected and removed that resident
  from the cache state.
- If a file trim removes one or more victims and then throws on a later victim,
  every completed victim remains counted, the failed tracked victim is not
  counted, the throwing insertion is not a rejection, and residency reflects
  the completed filesystem and state mutations.

The cumulative cost uses the same unit as the concrete cache's resident cost.
Cost values from different cache instances are directly comparable only when
their configurations use the same cost unit.

### residency

Residency is sampled from the cache's current authoritative state:

| implementation | `residentCount` | `residentCost` |
|---|---|---|
| `LRUMemoryCache` | `entries.count` | `totalCost` |
| `LRUFileCache` | `residents.count` | `observedDiskUsage` |

Memory cost is the configured weigher's unit. File cost is the observed
allocated size with the existing logical-size fallback.

File residency excludes the ownership marker, staging artifacts, directory
metadata, and the in-memory statistics accumulator. Memory residency likewise
excludes cache metadata and statistics overhead.

## state ownership

### shared accumulator

Add an internal accumulator containing only cumulative counters:

```swift
struct CacheStatisticsAccumulator {
    var hitCount: UInt64
    var missCount: UInt64
    var evictionCount: UInt64
    var evictedCost: UInt64
    var rejectionCount: UInt64
}
```

Counter updates saturate at `UInt64.max`. Statistics must never trap or change
cache behavior because a counter overflowed.

The accumulator is optional in concrete state:

```swift
var statistics: CacheStatisticsAccumulator?
```

`nil` is the internal disabled state. Current residency is supplied when the
accumulator creates a public snapshot; it is not duplicated in the accumulator.

### memory cache

The accumulator lives inside `LRUMemoryCache.State`.

- Request outcomes are recorded inside the existing `LockedValue` critical
  section.
- Rejections known before entering the current mutation section must record
  through the same state lock.
- Capacity victims update eviction count and cost in the same mutation that
  removes them.
- The public snapshot is assembled under the same lock from the accumulator,
  `entries.count`, and `totalCost`.
- No atomics, second lock, recorder object, callback, or asynchronous work is
  added.
- Retired values and keys continue to be released outside the lock.

### file cache

The accumulator lives inside `LRUFileCache.State`, behind `FileCacheWorker`.

- Every recorded outcome is decided and updated by the serial state owner.
- Snapshot creation reads the accumulator, `residents.count`, and
  `observedDiskUsage` without filesystem I/O.
- Add a nonthrowing read-only worker inspection path for the asynchronous
  statistics getter. It queues behind preceding state work but does not perform
  cancellation or storage failure mapping.
- Extend the private runtime-state protocol with a read-only statistics
  snapshot requirement.
- A successful `start()` establishes residents and capacity first. Historical
  counters exposed by the completed instance begin at zero.
- Later unavailability does not erase the accumulated counters or prevent
  inspection.

The file cache does not write statistics into its directory. Cache reads remain
reads except for the existing TTI touch behavior.

## package organization

Keep one public `Latte` target and add a feature folder:

```text
Sources/Latte/
├── statistics/
│   ├── CacheStatistics.swift
│   ├── CacheStatisticsProviding.swift
│   └── CacheStatisticsAccumulator.swift
├── protocols/
├── memory/
├── file/
└── support/
```

The snapshot and protocols are core cache capabilities. A future target can
own exporters or persistence when those capabilities acquire independent
dependencies and consumers.

## implementation stages

### stage a — public statistics foundation

- Add `CacheStatistics`.
- Add the synchronous and asynchronous capability protocols.
- Add the internal saturating accumulator.
- Add `isStatisticsEnabled` to both configurations with a default of `false`.
- Verify public construction, derived metrics, disabled semantics, and Swift 6
  concurrency checking.

Stage A does not record concrete cache operations yet.

### stage b — memory cache integration

- Move the optional accumulator into `LRUMemoryCache.State`.
- Record normal hit and miss outcomes.
- Record oversized candidate rejection.
- Record every capacity victim and its cost.
- Assemble coherent residency and counters under the existing lock.
- Preserve lock-external destruction and current reentrancy behavior.

Stage B is complete when the memory implementation satisfies the public
statistics semantics under sequential, concurrent, replacement, rejection,
multi-victim eviction, explicit removal, and `removeAll` workloads.

### stage c — file cache integration

- Extend the private runtime state with snapshot access.
- Add the nonthrowing serialized worker inspection path.
- Begin the observable counter epoch after successful startup.
- Record lookup outcomes at the final returned-result branches.
- Record every normal insertion-rejection path.
- Record capacity victims and observed cost without counting expiration,
  reconciliation, replacement, or explicit removal.
- Keep statistics available after storage unavailability.
- Confirm that a recreated cache recovers residency with zero historical
  counters.

Stage C is complete when file tests cover normal I/O, injected metadata and
deletion races, expiration, startup recovery, trimming, and fail-closed state.

### stage d — measurement and documentation

- Extend the memory and file operation benchmarks with disabled and enabled
  collection runs.
- Run both modes with the same deterministic workload, operation order, input
  data, iteration count, and timing method.
- Keep statistics snapshot retrieval and correctness verification outside the
  timed region so the benchmark measures collection rather than getter
  serialization.
- Keep the current disabled run as the behavioral and performance baseline.
- Verify snapshots against the declared operation counts after timing ends.
- Report absolute operation latency or throughput and relative enabled-versus-
  disabled overhead.
- Report memory and file results separately. Do not rank their throughput
  against each other.
- Do not change the policy hit-rate simulator; it owns trace-level object and
  byte metrics independently of Latte.
- Update the README and architecture documentation with the new capability.
- Update file-cache documentation with process-local, nonpersistent statistics
  semantics.
- Remove observability from the current non-goal lists while keeping exporters,
  persistence, and event streams deferred.

## verification

### snapshot tests

- all-zero enabled snapshot;
- disabled cache returns `nil`;
- negative `residentCount` and `residentCost` trigger their initializer
  preconditions;
- request count saturation;
- `hitRate == nil` with no requests;
- correct nonzero hit rate;
- `.max` hit and miss counters produce a `0.5` hit rate even though
  `requestCount` saturates;
- public initializer and equality.

### memory tests

- hit and miss accounting;
- oversized rejection preserves an existing same-key resident;
- replacement is not eviction;
- multi-victim eviction count and cost;
- explicit removal and `removeAll` do not increment eviction;
- resident count and cost after every mutation class;
- concurrent operations produce coherent snapshots;
- statistics do not move destruction back under the cache lock.

### file tests

- startup recovery affects residency but leaves counters at zero;
- hit, absent miss, expired miss, and externally removed miss;
- propagated key-encoding and storage failures record no request outcome;
- expiration-cleanup deletion failure is absorbed, retains retryable metadata,
  returns `nil`, and records one miss;
- touch persistence failure is absorbed, returns data, and records one hit;
- successful read followed by touch disappearance remains a hit while
  residency reflects the discovered disappearance;
- every normal oversize or immediate-expiration rejection path;
- trim eviction count and allocated cost;
- partial trim success followed by deletion failure counts only completed
  victims, records no rejection, and preserves completed residency changes;
- replacement, expiration cleanup, reconciliation, explicit removal, and
  `removeAll` are not evictions;
- statistics remain readable when storage operations report unavailable;
- counters do not survive instance recreation;
- concurrent callers observe worker-serialized snapshots.

### project validation

- Debug and Release tests;
- Thread Sanitizer tests;
- Release warnings-as-errors build;
- supported Apple SDK compile checks;
- memory and file benchmark smoke runs with statistics disabled and enabled;
- identical deterministic benchmark workloads with snapshot access outside
  timed regions;
- absolute benchmark results and relative collection overhead, reported
  separately for memory and file caches;
- `git diff --check`.

No simulator or physical-device runtime is required unless implementation
changes the existing filesystem behavior. Statistics must not create new file
metadata assumptions.

## compatibility and migration

- Existing cache construction remains source-compatible because collection
  defaults to disabled.
- Existing `Caching` and `AsyncCaching` contracts do not change.
- Existing concrete cache operations retain their return and failure
  semantics.
- Statistics conformance is additive.
- No cache directory format or ownership marker version changes.
- No persisted migration is required.

## deferred work

- dynamic enable, disable, or reset;
- snapshot delta algebra and measurement windows;
- persistent or cross-process counters;
- application background or termination snapshots;
- byte hit rate and missed-byte accounting;
- latency histograms and percentiles;
- storage-error and expiration-cause breakdowns;
- event listeners, logging, signposts, and tracing;
- Metrics, OpenTelemetry, Prometheus, or custom exporters;
- a separate observability target;
- Bedrock benchmark migration.

These items require new consumers, semantics, or measured pressure before they
reopen the boundary.

## implementation risks

- Memory statistics execute on the hottest cache path. Disabled and enabled
  overhead must be measured rather than assumed.
- Recording before an operation's final result can misclassify thrown file
  operations. Counters must be updated at outcome branches.
- Eviction, replacement, expiration, reconciliation, and explicit invalidation
  share removal helpers but have different public meanings. Cause must remain
  known at the decision site.
- Residency must be derived from existing state, not mirrored in counters.
- The asynchronous snapshot must not turn an in-memory inspection into a
  filesystem or persistence operation.
- Future fields must not be added merely because another library reports them;
  each field needs a stable meaning in both current cache implementations.
