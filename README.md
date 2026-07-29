# Latte

A modern caching infrastructure for Swift across Apple platforms.

Inspired by Caffeine, Moka, Ristretto, and cache2k, but not a port of them.

## requirements

Requires Swift 6 and iOS 16, macOS 13, Mac Catalyst 16, tvOS 16, watchOS 9,
or visionOS 1.

0.1.0 提供 `Caching`、`AsyncCaching` 两种最小缓存协议，以及
`LRUMemoryCache`、`LRUFileCache` 两个完整实现。具体 Cache 可以拥有不同的
cost、expiration、容量与持久化能力。

## installation

Add Latte to a Swift package:

```swift
dependencies: [
    .package(
        url: "https://github.com/Weixi779/Latte.git",
        from: "0.1.0"
    ),
]
```

## memory cache

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
```

## file cache

文件 Cache 使用调用者提供的稳定 Key material，并在专属目录内管理文件：

```swift
let fileCache = try await LRUFileCache<URL>(
    directory: cachesDirectory.appendingPathComponent(
        "network-images",
        isDirectory: true
    ),
    configuration: .init(
        maximumDiskUsage: 512 * 1024 * 1024,
        timeToLive: .seconds(7 * 24 * 60 * 60),
        timeToIdle: .seconds(24 * 60 * 60),
        accessTimeUpdateInterval: .seconds(5 * 60),
        isStatisticsEnabled: true
    ),
    stableKeyEncoder: { url in
        Data(url.absoluteString.utf8)
    }
)

try await fileCache.insert(downloadedData, for: imageURL)
let cachedData = try await fileCache.value(for: imageURL)
```

同一 Key 必须在不同启动中产生相同 material。该 encoder 可能被多个调用任务并发
执行，不能依赖未同步的可变状态。目录必须专属于一个 Cache 实例和进程。

## statistics

统计默认关闭，并在构造 Cache 时显式开启：

```swift
let memoryCache = LRUMemoryCache<String, Data>(
    configuration: .init(
        maximumCost: 60 * 1024 * 1024,
        isStatisticsEnabled: true,
        weigher: { _, data in data.count }
    )
)

let memoryStatistics = memoryCache.statistics
let fileStatistics = await fileCache.statistics
```

`LRUMemoryCache` 通过 `CacheStatisticsProviding` 同步提供快照，
`LRUFileCache` 通过 `AsyncCacheStatisticsProviding` 异步提供快照。关闭时返回
`nil`；开启后可以读取 hit、miss、eviction、rejection、resident count/cost
以及派生的 request count 和 hit rate。

统计属于单个 Cache 实例，只保存在内存中，不跨进程启动持久化。文件 Cache
重建时会恢复当前 residency，但历史计数从零开始。

## composition

Latte 不编排网络请求或图片解码。网络图片层可以通过两个最小协议注入不同的完整
Cache，并自行决定 raw `Data` 与 decoded image 的生命周期：

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

    func store(
        data: Data,
        decodedImage: Image,
        for url: URL
    ) async throws {
        try await file.insert(data, for: url)
        memory.insert(decodedImage, for: url)
    }
}
```

需要不同的容量、expiration 或存储语义时，创建并注入另一个 Cache 实例；调用层
不需要知道具体实现内部的 Policy、文件结构或并发 owner。

## technical documentation

- [Architecture](docs/architecture.md)
- [Cache statistics](docs/cache-statistics-plan.md)
- [File cache](docs/file-cache.md)
- [Filesystem evidence](probes/file-metadata/results.md)
- [Benchmarks](benchmarks/README.md)

当前的 LRU、SIEVE、SLRU、W-TinyLFU 与论文原始版 S3-FIFO 命中率实验见
[Policy hit-rate benchmark](benchmarks/policy-hit-rate/README.md)。
