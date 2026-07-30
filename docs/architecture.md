# architecture

## scope

Latte 0.2.1 is a Swift 6 caching library for Apple platforms. It exposes two
minimal behavior contracts and two complete cache implementations:

| contract | implementation | execution model |
|---|---|---|
| `Caching<Key, Value>` | `LRUMemoryCache` | synchronous |
| `AsyncCaching<Key, Value>` | `LRUFileCache<Key>` with `Data` values | asynchronous and throwing |

The public boundary standardizes cache use, not construction, algorithms,
storage, capacity, expiration, or durability.

Supported deployment targets are iOS 16, macOS 13, Mac Catalyst 16, tvOS 16,
watchOS 9, and visionOS 1.

## contract semantics

- `value(for:)` returns a resident value or `nil` for a miss.
- A miss can mean never inserted, evicted, expired, explicitly removed, or
  removed by the system.
- `AsyncCaching` throws only for storage failures or cancellation. An ordinary
  miss is not an error.
- `insert` submits a candidate. A successful call does not guarantee a later
  hit because a concrete cache may reject or evict it.
- Algorithmic rejection is normal cache behavior, not an I/O failure.
- `removeValue` and `removeAll` explicitly invalidate entries.

Cost, capacity, TTL, TTI, admission results, durability, storage paths, and
algorithm state remain concrete-cache capabilities.

## statistics capability

Statistics are an optional concrete-cache capability, not part of `Caching` or
`AsyncCaching`:

| capability | implementation | access |
|---|---|---|
| `CacheStatisticsProviding` | `LRUMemoryCache` | synchronous snapshot |
| `AsyncCacheStatisticsProviding` | `LRUFileCache` | asynchronous snapshot |

Collection is disabled by default and selected at construction. Disabled
instances return `nil`; enabled instances return one coherent
`CacheStatistics` snapshot containing request outcomes, capacity outcomes, and
current residency.

The accumulator stays inside the cache's existing synchronization owner.
Residency is derived from authoritative cache state at snapshot time rather
than maintained as a second counter. Statistics do not change the minimal
behavior contracts or introduce a shared policy abstraction.

## ownership

Each complete cache owns one coherent state machine:

- resident values;
- algorithm metadata;
- capacity accounting;
- operation ordering and synchronization;
- expiration and cleanup;
- failure and recovery semantics.

Internal structures can be shared, but they do not become independently
coordinated public policy or storage layers.

Latte intentionally does not expose `CachePolicy`, `Storage`, `Backend`,
`CacheDecision`, or a generic storage-policy composition type. A new public
capability requires repeated behavior and at least two real consumers or
implementations.

## memory cache

`LRUMemoryCache` is thread-safe and cost-aware.

- `LRUList` owns only key identity and recency.
- The cache state owns values, recorded cost, admission, and victim selection.
- Cost is captured at insertion time.
- Zero cost is valid.
- A candidate larger than `maximumCost` is rejected without replacing an
  existing resident for the same key.
- Updating a resident replaces its value and cost and refreshes recency.
- One insertion can evict multiple least-recent residents.
- Values and LRU metadata change in one synchronization boundary.
- Removed keys and values are released outside that boundary so `deinit` can
  safely reenter the cache.

## file cache

`LRUFileCache` is an awaited, directory-backed `Data` cache. One serial owner
coordinates file I/O, resident metadata, recency, expiration, and observed disk
usage. Initializers complete directory validation and recovery before returning.

Its persistence and failure model is documented in
[file-cache.md](file-cache.md).

## composition

Latte stops where business orchestration begins. A network image layer can use:

```text
Caching<URL, DecodedImage>
└── synchronous memory hot path

AsyncCaching<URL, Data>
└── persistent encoded data
```

The consumer still owns networking, HTTP semantics, decoding, memory/file
lookup order, and representation conversion. Latte 0.2.1 does not provide an
automatic memory-plus-file cache.

## package organization

Latte remains one library target and one public import:

```text
Sources/Latte/
├── protocols/
├── memory/
├── file/
├── statistics/
└── support/
```

The target is not split because both implementations share the public
contracts, there is no platform or dependency divergence, and no consumer
requires independently versioned modules. Benchmark executables remain
separate targets because they have independent entry points and workloads.

A target split should be reconsidered only when a real constraint appears,
such as a memory-only distribution requirement, optional heavy file
dependencies, platform divergence, or independent module evolution.

## non-goals

Latte 0.2.1 does not include:

- per-entry expiration or background expiration sweeps;
- production S3-FIFO, SIEVE, SLRU, TinyLFU, or W-TinyLFU caches;
- public policy, storage, or backend composition;
- automatic memory/file orchestration;
- multi-instance or multi-process directory sharing;
- file locking, manifests, journals, checkpoints, or database transactions;
- encryption, compression, or `Codable` storage;
- networking, HTTP caching, image decoding, UI, or Combine;
- persisted statistics, event streams, tracing, or external metrics exporters.

## evolution

New cache families should:

1. implement one complete cache;
2. state their actual capabilities;
3. satisfy the common behavior contract;
4. test their own algorithm and medium invariants;
5. benchmark a declared workload;
6. extract shared public capabilities only after repeated implementations prove
   the same lifecycle and semantics.

Research papers, another library's API, and hypothetical future reuse are
inputs, not requirements.

## evidence

- Filesystem assumptions: [file metadata results](../probes/file-metadata/results.md)
- Benchmark methodology: [benchmarks](../benchmarks/README.md)
- Cache statistics: [cache-statistics.md](cache-statistics.md)
- File cache design: [file-cache.md](file-cache.md)
