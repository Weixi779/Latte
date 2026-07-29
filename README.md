# Latte
A modern caching infrastructure for Swift across Apple platforms.

Inspired by Caffeine, Moka, Ristretto, and cache2k, but not a port of them.

Requires Swift 6 and iOS 16, macOS 13, Mac Catalyst 16, tvOS 16, watchOS 9,
or visionOS 1.

Latte 的产品方向、已接受边界与演进规则见 [DIRECTION.md](DIRECTION.md)。

V1 已提供 `Caching`、`AsyncCaching` 两种最小缓存协议，以及
`LRUMemoryCache`、`LRUFileCache` 两个完整实现。文件 Cache 的设计边界、
失败语义与实施记录见
[LRU file cache plan](LRU_FILE_CACHE_PLAN.md)，文件系统假设的验证结果见
[FileMetadataProbe results](Probes/FileMetadataProbe/RESULTS.md)。具体 Cache
可以拥有不同的 cost、expiration、容量与持久化能力。

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
        accessTimeUpdateInterval: .seconds(5 * 60)
    ),
    stableKeyEncoder: { url in
        Data(url.absoluteString.utf8)
    }
)

try await fileCache.insert(downloadedData, for: imageURL)
let cachedData = try await fileCache.value(for: imageURL)
```

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

当前的 LRU、SIEVE、SLRU、W-TinyLFU 与论文原始版 S3-FIFO 命中率实验见
[Policy hit-rate benchmark](Benchmarks/PolicyHitRateBenchmark/README.md)。
完整 Cache 的 operation benchmark 入口见
[Benchmarks](Benchmarks/README.md)。
