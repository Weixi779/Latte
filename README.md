# Latte

[![Release](https://img.shields.io/github/v/release/Weixi779/Latte)](https://github.com/Weixi779/Latte/releases/latest)
![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Mac%20Catalyst%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-blue)
![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange)
![SPM](https://img.shields.io/badge/SPM-Supported-brightgreen)
![License](https://img.shields.io/github/license/Weixi779/Latte)

English | [简体中文](README_CN.md)

A focused caching library for Swift across Apple platforms.

Latte defines small synchronous and asynchronous cache contracts, then provides
complete memory and file implementations with their own capacity, expiration,
persistence, and concurrency models.

```swift
let cache = LRUMemoryCache<String, Data>(
    configuration: .init(maximumCost: 100)
)

cache.insert(data, for: key)
let cached = cache.value(for: key)
```

Inspired by Caffeine, Moka, Ristretto, and cache2k, but not a port of them.

## features

- **Small behavior contracts**: use `Caching` for synchronous caches and
  `AsyncCaching` for awaited, throwing caches.
- **Cost-aware memory LRU**: weighted capacity, multi-victim eviction,
  thread-safe operations, and lock-outside destruction.
- **Persistent file LRU**: atomic publication, directory ownership,
  startup recovery, TTL, TTI, and allocated-size capacity accounting.
- **Optional statistics**: inspect hits, misses, rejections, evictions,
  evicted cost, and current residency.
- **Honest composition**: memory and file caches share behavior contracts
  without pretending that their storage or execution models are identical.
- **Swift concurrency ready**: public concurrency boundaries use Swift 6
  `Sendable` semantics.

## requirements

- Swift 6.0+
- iOS 16+
- macOS 13+
- Mac Catalyst 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+

## installation

Add Latte with Swift Package Manager:

```swift
dependencies: [
    .package(
        url: "https://github.com/Weixi779/Latte.git",
        from: "0.2.1"
    )
]
```

## memory cache

`LRUMemoryCache` is synchronous, thread-safe, and cost-aware. Without a custom
weigher, every entry has a cost of one.

```swift
import Foundation
import Latte

let cache = LRUMemoryCache<String, Data>(
    configuration: .init(
        maximumCost: 60 * 1024 * 1024,
        weigher: { _, data in data.count }
    )
)

cache.insert(data, for: key)
let cached = cache.value(for: key)

cache.removeValue(for: key)
cache.removeAll()
```

Cost is captured when a value is inserted. An oversized candidate is rejected
without replacing an existing resident for the same key.

## file cache

`LRUFileCache` is an asynchronous, directory-backed `Data` cache. It owns the
supplied directory exclusively and rebuilds resident state from directory
truth when a new instance starts.

```swift
import Foundation
import Latte

let fileCache = try await LRUFileCache<URL>(
    directory: cachesDirectory.appendingPathComponent(
        "network-images",
        isDirectory: true
    ),
    configuration: .init(
        maximumDiskUsage: 512 * 1024 * 1024,
        timeToLive: .seconds(7 * 24 * 60 * 60),
        timeToIdle: .seconds(24 * 60 * 60),
        accessTimeUpdateInterval: .seconds(5 * 60)
    ),
    stableKeyEncoder: { url in
        Data(url.absoluteString.utf8)
    }
)

try await fileCache.insert(downloadedData, for: imageURL)
let cachedData = try await fileCache.value(for: imageURL)
```

The same logical key must produce identical material across launches. The
encoder can be called concurrently and must not depend on unsynchronized
mutable state. A cache directory must not be shared with another cache instance
or process.

## statistics

Statistics are disabled by default and selected when a cache is constructed:

```swift
let memoryCache = LRUMemoryCache<String, Data>(
    configuration: .init(
        maximumCost: 60 * 1024 * 1024,
        isStatisticsEnabled: true,
        weigher: { _, data in data.count }
    )
)

let fileCache = try await LRUFileCache<String>(
    directory: directory,
    configuration: .init(
        maximumDiskUsage: 512 * 1024 * 1024,
        isStatisticsEnabled: true
    ),
    stableKeyEncoder: { Data($0.utf8) }
)

let memoryStatistics = memoryCache.statistics
let fileStatistics = await fileCache.statistics
```

`LRUMemoryCache` exposes synchronous snapshots through
`CacheStatisticsProviding`; `LRUFileCache` uses
`AsyncCacheStatisticsProviding`. Disabled caches return `nil`. Enabled caches
return hits, misses, rejections, capacity evictions, evicted cost, current
resident count/cost, request count, and hit rate.

Statistics belong to one cache instance and are not persisted. A file cache
restores residency after restart, while its historical counters begin a new
epoch at zero.

## composition

Latte does not orchestrate networking, image decoding, or business-specific
cache tiers. Applications can compose the two minimal contracts directly:

```swift
struct NetworkImageCache<Image> {
    private let memory: any Caching<URL, Image>
    private let file: any AsyncCaching<URL, Data>

    init(
        memory: any Caching<URL, Image>,
        file: any AsyncCaching<URL, Data>
    ) {
        self.memory = memory
        self.file = file
    }

    func cachedImage(
        for url: URL,
        decode: (Data) throws -> Image
    ) async throws -> Image? {
        if let image = memory.value(for: url) {
            return image
        }
        guard let data = try await file.value(for: url) else {
            return nil
        }

        let image = try decode(data)
        memory.insert(image, for: url)
        return image
    }
}
```

Different capacity, expiration, or storage semantics belong in separate cache
instances. The consumer does not need to know their internal policy, file
layout, or synchronization owner.

## behavior

- `value(for:)` returns a resident value or `nil` for an ordinary miss.
- `AsyncCaching` throws for storage failures or cancellation, not for a miss.
- Insertion submits a candidate; a cache may normally reject or later evict it.
- Explicit removal is different from capacity eviction.
- The file cache uses a soft disk limit based on observed allocated size, with
  logical size as a fallback.
- When file-cache access-time updates are throttled, in-process TTI and recency
  remain exact; persisted state can lag by at most one touch interval.

## benchmarks

Latte keeps policy research and concrete operation measurements separate:

- [Policy hit-rate benchmark](benchmarks/policy-hit-rate/README.md)
- [Memory cache operation benchmark](benchmarks/memory-cache/README.md)
- [File cache operation benchmark](benchmarks/file-cache/README.md)

The policy benchmark reports object and byte hit rates for LRU, SIEVE, SLRU,
W-TinyLFU, and the paper-original S3-FIFO. Operation benchmarks report complete
public cache calls and can measure statistics-disabled versus
statistics-enabled overhead with paired AB/BA workloads.

## technical documentation

- [Architecture](docs/architecture.md)
- [Cache statistics](docs/cache-statistics.md)
- [File cache](docs/file-cache.md)
- [Filesystem evidence](probes/file-metadata/results.md)
- [Benchmark methodology](benchmarks/README.md)

## license

Latte is available under the Apache-2.0 license. See [LICENSE](LICENSE).
