# Latte
A modern caching infrastructure for Swift across Apple platforms.

Inspired by Caffeine, Moka, Ristretto, and cache2k, but not a port of them.

Requires Swift 6 and iOS 16, macOS 13, Mac Catalyst 16, tvOS 16, watchOS 9,
or visionOS 1.

Latte 当前的产品方向、已接受边界与待验证问题见 [DIRECTION.md](DIRECTION.md)。

V1 已提供 `Caching`、`AsyncCaching` 两种最小缓存协议，以及首个完整实现
`LRUMemoryCache`。下一个完整实现 `LRUFileCache` 的冻结边界与实施顺序见
[LRU file cache plan](LRU_FILE_CACHE_PLAN.md)，文件系统假设的 Stage 0
验证结果见
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

当前的 LRU、SIEVE、SLRU、W-TinyLFU 与论文原始版 S3-FIFO 命中率实验见
[Policy hit-rate benchmark](Benchmarks/PolicyHitRateBenchmark/README.md)。
