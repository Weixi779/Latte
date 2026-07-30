# Latte

[![Release](https://img.shields.io/github/v/release/Weixi779/Latte)](https://github.com/Weixi779/Latte/releases/latest)
![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS%20%7C%20Mac%20Catalyst%20%7C%20tvOS%20%7C%20watchOS%20%7C%20visionOS-blue)
![Swift](https://img.shields.io/badge/Swift-6.0%2B-orange)
![SPM](https://img.shields.io/badge/SPM-Supported-brightgreen)
![License](https://img.shields.io/github/license/Weixi779/Latte)

[English](README.md) | 简体中文

一个专注于 Apple 平台的 Swift 缓存库。

Latte 定义了最小的同步与异步缓存协议，并提供完整的内存和文件缓存实现。两种
Cache 可以拥有各自真实的容量、过期、持久化和并发模型。

```swift
let cache = LRUMemoryCache<String, Data>(
    configuration: .init(maximumCost: 100)
)

cache.insert(data, for: key)
let cached = cache.value(for: key)
```

设计参考了 Caffeine、Moka、Ristretto 和 cache2k，但不是它们的移植版本。

## 特性

- **最小行为协议**：同步缓存使用 `Caching`，需要 await 且可能抛错的缓存使用
  `AsyncCaching`。
- **支持 cost 的内存 LRU**：weighted capacity、多 victim 淘汰、线程安全操作，
  以及锁外释放对象。
- **持久化文件 LRU**：atomic publication、目录所有权、启动恢复、TTL、TTI，
  以及基于 allocated size 的容量计算。
- **可选统计能力**：观察 hit、miss、rejection、eviction、evicted cost 和当前
  residency。
- **诚实的组合边界**：内存和文件 Cache 统一行为协议，但不伪造相同的存储或
  执行模型。
- **适配 Swift Concurrency**：公开并发边界遵循 Swift 6 `Sendable` 语义。

## 系统要求

- Swift 6.0+
- iOS 16+
- macOS 13+
- Mac Catalyst 16+
- tvOS 16+
- watchOS 9+
- visionOS 1+

## 安装

通过 Swift Package Manager 集成：

```swift
dependencies: [
    .package(
        url: "https://github.com/Weixi779/Latte.git",
        from: "0.2.1"
    )
]
```

## 内存缓存

`LRUMemoryCache` 是同步、线程安全且支持 cost 的缓存。不提供自定义 weigher 时，
每个 entry 的 cost 为一。

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

Cost 在插入时记录为快照。超过最大 cost 的 candidate 会被拒绝，并且不会替换
同一 key 已经存在的 resident。

## 文件缓存

`LRUFileCache` 是异步、基于目录的 `Data` 缓存。它独占调用方提供的目录，并在
新实例启动时以目录事实重建 resident state。

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

同一个逻辑 key 必须在不同启动中产生相同 material。Encoder 可能被并发调用，
不能依赖未同步的可变状态。一个缓存目录不能与其他 Cache 实例或进程共享。

## 统计

统计默认关闭，并在构造 Cache 时显式开启：

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

`LRUMemoryCache` 通过 `CacheStatisticsProviding` 同步提供快照；
`LRUFileCache` 通过 `AsyncCacheStatisticsProviding` 异步提供快照。关闭时返回
`nil`；开启后可以读取 hit、miss、rejection、capacity eviction、evicted cost、
resident count/cost，以及派生的 request count 和 hit rate。

统计属于单个 Cache 实例，不会持久化。文件 Cache 重启后会恢复当前 residency，
但历史计数会从零开始一个新的 epoch。

## 组合

Latte 不负责网络请求、图片解码或业务层的多级缓存编排。应用可以直接组合两个最小
协议：

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

不同的容量、过期或存储语义应该由不同 Cache 实例承载。调用层不需要知道具体实现
内部的 policy、文件结构或并发 owner。

## 行为语义

- `value(for:)` 返回 resident value，普通 miss 返回 `nil`。
- `AsyncCaching` 只对存储失败或取消抛错，普通 miss 不是错误。
- 插入只是提交 candidate；具体 Cache 可以正常拒绝或随后淘汰它。
- 显式删除与容量淘汰是不同的行为。
- 文件 Cache 的磁盘软上限优先使用 observed allocated size，无法获取时回退到
  logical size。
- File Cache 开启 access-time throttling 后，进程内 TTI 和 recency 仍然精确；
  持久化状态最多落后一个 touch interval。

## 性能测试

Latte 将 policy 研究与具体 Cache 操作测量分开：

- [Policy hit-rate benchmark](benchmarks/policy-hit-rate/README.md)
- [Memory cache operation benchmark](benchmarks/memory-cache/README.md)
- [File cache operation benchmark](benchmarks/file-cache/README.md)

Policy benchmark 会报告 LRU、SIEVE、SLRU、W-TinyLFU 和论文原始版 S3-FIFO 的
object/byte hit rate。Operation benchmark 测量完整的 public cache call，并通过
配对 AB/BA workload 对比 statistics disabled/enabled 的开销。

## 技术文档

- [Architecture](docs/architecture.md)
- [Cache statistics](docs/cache-statistics.md)
- [File cache](docs/file-cache.md)
- [Filesystem evidence](probes/file-metadata/results.md)
- [Benchmark methodology](benchmarks/README.md)

## 许可证

Latte 基于 Apache-2.0 许可证开源。详情见 [LICENSE](LICENSE)。
