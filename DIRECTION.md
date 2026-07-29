# Latte：V1 方向与实施基线

> 状态：实施中；公共协议、`LRUMemoryCache` 与 `LRUFileCache` Stage C 已完成，
> 下一步实现文件容量水位与 TTL / TTI
> 更新日期：2026-07-29

## 1. Latte 是什么

Latte 是面向 Apple 全平台的 Swift 缓存基础设施。

它不尝试把 Storage、Admission、Eviction 与 Expiration 设计成可以任意拼装的乐高，也不承诺所有缓存算法拥有相同能力。论文与真实实现已经证明，LRU、S3-FIFO、SIEVE、W-TinyLFU 等算法拥有不同的状态、容量和生命周期；强行统一内部结构只会得到失真的抽象。

Latte 对外只统一完整 Cache 的最小行为，并提供经过测试与 benchmark 校准的具体实现：

```text
调用者
├── Caching
│   ├── LRUMemoryCache
│   ├── 未来的其他同步 Cache
│   └── 用户自定义实现
└── AsyncCaching
    ├── V1 的 LRUFileCache
    ├── SQLite / UserDefaults / Keychain 等实现
    └── 用户自定义实现
```

Latte 的底线是：

> 在相同执行模型内，调用者可以通过同一套最小缓存协议替换完整 Cache 实现。

Latte 统一的是调用语言和可替换边界，不是构造参数、内部算法或功能全集。

## 2. 首要消费者

Latte 的首要真实消费者是网络图片缓存，但 Latte 本身不实现网络图片管线。

调用者可以分别依赖：

```text
Caching<ImageKey, DecodedImage>
└── 同步内存热路径

AsyncCaching<StableKey, Data>
└── 文件、SQLite 或其他持久化实现
```

网络图片库继续拥有：

- 网络请求；
- HTTP 语义；
- 图片解码与处理；
- 内存与磁盘的查询顺序；
- decode 后回填内存；
- encoded Data 与 decoded image 之间的 representation 转换。

Latte 只提供独立缓存。V1 不提供自动 Memory + Disk 二级缓存容器。

## 3. 稳定公共协议

### 3.1 同步缓存

```swift
public protocol Caching<Key, Value> {
    associatedtype Key: Hashable
    associatedtype Value

    func value(for key: Key) -> Value?
    func insert(_ value: Value, for key: Key)
    func removeValue(for key: Key)
    func removeAll()
}
```

`Caching` 面向不需要 suspension 或可恢复 IO error 的同步实现。V1 的 `LRUMemoryCache` 是第一个实现。

`Caching` 不等同于“所有内存实现”，也不禁止其他合理的同步实现；协议描述的是执行语义，不是存储介质。

### 3.2 异步缓存

```swift
public protocol AsyncCaching<Key, Value> {
    associatedtype Key: Hashable
    associatedtype Value

    func value(for key: Key) async throws -> Value?
    func insert(_ value: Value, for key: Key) async throws
    func removeValue(for key: Key) async throws
    func removeAll() async throws
}
```

`AsyncCaching` 面向文件、SQLite、Keychain 或其他可能等待、失败、取消的实现。

同步实现不被迫使用 `await`。异步实现也不允许通过阻塞线程伪装成 `Caching`。未来可以研究 sync → async adapter，但不承诺 async → sync 适配。

### 3.3 共同语义

- `value(for:)` 返回 `Value` 表示 hit，返回 `nil` 表示 miss。
- miss 包括从未存在、已淘汰、已过期或被系统清理，不公开 miss reason enum。
- `AsyncCaching.value(for:)` 的 `throw` 表示真实存储故障或取消，不能把故障伪装成 miss。
- `insert` 表示把 Value 提交给当前 Cache 处理，不保证之后一定命中。
- Admission rejection、超大对象、容量淘汰和 expiration 都可能让一次成功调用最终不可命中；这些不是数据库写入承诺。
- `AsyncCaching.insert` 的 `throw` 表示实现未能完成其对外承诺；算法正常拒绝不是 IO error。
- `removeValue` 与 `removeAll` 表达显式失效；具体算法必须维护自己的 queue、ghost、hand、weight 或其他状态。

协议不包含：

- cost；
- TTL 或 TTI；
- maximum count / weight；
- admission result；
- queue ratio；
- ghost history；
- durability；
- transaction；
- checkpoint；
- concrete storage path。

这些能力属于具体 Cache family。

## 4. 具体 Cache family

### 4.1 命名

当算法与介质都会改变能力和实现时，类型名称同时表达二者：

```text
LRUMemoryCache
LRUFileCache
S3FIFOMemoryCache
S3FIFOFileCache
```

`LRUFileCache` 比泛化的 `LRUDiskCache` 更诚实，因为它明确承诺文件实现。如果未来存在真正隐藏多种磁盘机制的统一实现，再讨论 `Disk` 命名。

不是所有实现都必须机械采用“算法 + 介质”格式。例如直接封装系统存储语义的 `KeychainCache` 或 `UserDefaultsCache` 可以使用更自然的领域名称。名称必须暴露真正影响使用者判断的事实。

### 4.2 Configuration

构造侧不承诺统一：

```swift
let memory = LRUMemoryCache(
    configuration: .init(
        maximumCost: maximumCost,
        weigher: weigher
    )
)
```

未来的其他实现可以拥有完全不同的配置：

```swift
let cache = S3FIFOMemoryCache(
    configuration: .init(
        maximumCount: maximumCount,
        smallQueueRatio: 0.1,
        ghostQueueRatio: 0.9
    )
)
```

调用者替换 Cache 时可以在 composition root 修改 construction，但业务使用侧继续只依赖 `Caching` 或 `AsyncCaching`。

### 4.3 能力允许不对称

LRU 适合在自身状态机中实现 cost、TTL、TTI 和主动删除，不代表其他算法必须支持同样能力。

例如：

- `LRUMemoryCache` 可以使用 weigher 与 maximum cost；
- S3-FIFO 可以使用 Small、Main、Ghost 与自己的容量比例；
- 某些 Cache 可以支持 TTL 但不支持 TTI；
- 某些 Cache 可以只保证惰性 expiration；
- 持久化 Cache 可以拥有不同 durability 与 recovery。

如果在论文算法上增加 expiration、weight 或主动清理，它就是新的完整 Cache 组合，需要重新测试与 benchmark，不能继续把论文原始结果当成证明。

## 5. 内部所有权

每个完整 Cache 实现是以下状态的唯一所有者：

- Value residency；
- 算法元数据；
- 并发与操作顺序；
- 配置生命周期；
- 失败与恢复语义；
- 该实现支持的 expiration、cleanup 或 durability。

`LRUFileCache` 使用不承载 resident 状态的 ownership marker 确认目录属于 Latte。
marker 不是 manifest，也不是 file lock；多实例或多进程共享目录仍不属于 V1。
未知目录项不能被 Cache 删除。

算法与低层存储机制可以作为内部组件分离，但不是两个由外部协调的平级状态源。

V1 不公开：

- `CachePolicy`；
- `Storage`；
- `Backend`；
- `ManagedCache<Storage, Policy>`；
- `CacheDecision`；
- `CacheMutation`。

这些类型可以在 package/internal 范围服务具体实现。只有多个真实 Cache 出现相同的生命周期、失败语义和重复代码后，才考虑提升公共 capability。

## 6. V1：LRUMemoryCache

### 6.1 当前实现

仓库已有：

- `Caching` 与 `AsyncCaching` 公共协议；
- 线程安全、cost-aware 的 `LRUMemoryCache`；
- 只拥有 Key 与 recency 的 index-backed `LRUList`；
- 由 `LRUMemoryCache.State` 直接拥有的 total cost、拒绝和 victim 选择；
- 完整 Cache 行为与并发测试；
- 确定性 `LRUList` 结构测试；
- Key / Value 析构重入回归测试；
- 完整 `LRUMemoryCache` 的 20,000 次 seeded differential test；
- async throwing、目录驱动的 `LRUFileCache<Key>` 基础 CRUD；
- ownership marker、完整 inventory 验证与启动索引重建；
- stable key material 到 SHA-256 resident filename 的映射；
- 受控 staging publish、故障收敛与 fail-closed 状态；
- 条件式 `LRUFileCache: @unchecked Sendable where Key: Sendable`；
- 同 key 并发、重启恢复、完整 `removeAll` inventory、touch 降级、故障注入与
  跨 actor 测试；
- Policy hit-rate benchmark。

当前 `LRUMemoryCache` 已经拥有真实 Value、公共 Cache API 与并发状态。
`LRUFileCache` 已经拥有真实 `Data`、目录归属、串行 I/O 与基础持久化状态；
allocated-size 水位、TTL / TTI 和完整 Cache operation benchmark 仍待补充。

### 6.2 V1 结构

```text
LRUMemoryCache
└── 单一受保护 State
    ├── entries: Key → Value + recorded cost
    └── lru: Key → cost + recency
```

`LRUMemoryCache` 使用共享引用语义。Value residency 与 LRU metadata 必须在同一个同步临界区中改变，不能分别加锁或先发布其中一份状态。

内部可以直接使用 Dictionary；V1 不为了包装 Dictionary 创建没有独立职责的 `MemoryStore` protocol。

### 6.3 cost

cost 不进入 `Caching.insert`。

`LRUMemoryCache.Configuration` 拥有：

- `maximumCost`；
- 根据 Key 与 Value 计算 cost 的 weigher。

cost 在插入时计算并记录为 snapshot。Value 后续发生影响容量的内部变化时，调用者需要重新插入；Cache 不尝试观察任意 Value 的可变状态。

V1 语义：

- cost 必须非负；
- 零 cost 合法；
- 超过 `maximumCost` 的候选不进入缓存；
- 如果同一个 key 已经 resident，而新候选超大，旧 resident 保持不变；
- 更新已有 key 时以新 Value 与新 cost 替换，并刷新 recency；
- 一次大对象插入可以淘汰多个 LRU victims。

### 6.4 操作顺序

- read hit：读取 Value，并在返回前刷新 recency；
- read miss：返回 `nil`；
- insert admit：更新 LRU、删除 victims、写入 Value；
- insert reject：Value 与 resident LRU state 不变；
- remove：Value 与 LRU metadata 同步删除；
- removeAll：两份状态同步清空。

同步内存路径不 `await`、不 `throws`。

### 6.5 并发

V1 的 `LRUMemoryCache` 必须支持多线程安全调用。

这要求：

- 所有 Value 与 LRU 状态变化经过同一个临界区；
- 不在锁外修改算法状态；
- 淘汰、替换和删除只在锁内摘除所有权，实际 Key / Value 释放发生在锁外；
- 任意 Key / Value 的 `deinit` 可以重入 Cache，不会再次获取尚未释放的锁；
- 不依赖 actor 或 `await`；
- 不把 `Caching` 过早强制继承 `Sendable`；
- 具体 `Sendable` 形状在 Swift 6 编译与真实图片 Value 接入时验证。

并发安全只保证 Cache 容器状态，不替任意 Value 提供线程安全。

### 6.6 V1 保留、调整与新增

保留：

- 当前 index-backed LRU 数据结构；
- 当前 LRU 行为与 differential test；
- 已有 Policy hit-rate benchmark。

调整：

- 把共同部分收缩成只负责顺序的内部 LRU 数据结构；
- `LRUMemoryCache` 自己拥有 cost、容量、拒绝和淘汰；
- 删除 `CacheDecision`、descriptor 与容量感知 `LRUPolicy`；
- 删除源码注释中“未来由通用 Store/Backend coordinator 解释”的旧假设。

新增：

- `Caching`；
- `AsyncCaching`；
- `LRUMemoryCache`；
- `LRUFileCache`；
- maximum cost 与 weigher configuration；
- 文件 allocated-size 容量、高低水位、实例级 TTL 与 TTI；
- 完整 Cache 行为测试；
- 并发不变量测试；
- 完整 `LRUMemoryCache` 操作 benchmark。

`LRUFileCache` 的冻结边界、错误语义与实施顺序见
[LRU_FILE_CACHE_PLAN.md](LRU_FILE_CACHE_PLAN.md)。

## 7. 测试与 Benchmark

协议为 Latte 提供统一 workload，而不是强迫实现拥有相同内部机制。

### 7.1 协议行为测试

可以对所有 `Caching` 实现复用共同测试：

- 在实现接纳并保留条目的测试场景中，读取返回当前 resident Value；
- miss 返回 `nil`，而不是内部原因或错误包装；
- 对同一个 key 的成功更新不会返回旧 Value；
- remove 与 removeAll 使条目失效；
- 不暴露内部 miss reason。

`AsyncCaching` 使用对应的异步行为测试，并额外验证错误与取消。共同测试夹具可以为不同实现提供各自的有效 configuration，但不能假设相同 cost、容量或 admission。

共同测试只验证协议承诺。LRU recency、S3-FIFO Ghost 或 File recovery 必须由各自实现测试。

### 7.2 V1 算法测试

`LRUMemoryCache` 需要覆盖：

- 容量边界；
- zero cost；
- oversized candidate；
- repeated key；
- access refresh；
- multiple-victim eviction；
- total cost 与 resident keys 一致；
- 多线程操作后 Value 与 LRU metadata 不分叉；
- 已有 20,000 次 seeded LRU differential test 继续通过。

### 7.3 Benchmark

Latte 将 benchmark 作为早期产品能力：

- 同一协议 workload 可以比较不同同步 Cache 的吞吐、延迟与内存开销；
- 相同 trace 可以比较算法的对象命中率与字节命中率；
- 完整 Cache benchmark 与纯 Policy simulator 分开；
- 直接具体类型调用与协议抽象路径需要区分，避免把 existential/generic dispatch 成本误算成算法成本；
- `Caching` 与 `AsyncCaching` 不做没有 IO 条件说明的横向吞吐排名；
- 论文算法增加 expiration、weight 或其他功能后重新建立 benchmark，不沿用论文原始结论。

因此 Latte 即使不提供万能 Policy 组装器，仍然为 Swift 社区提供统一行为合同、参考实现、测试方法和可复现比较环境。

## 8. 平台与兼容性

- Swift tools version 6.0；
- Swift 6 language mode；
- iOS 16；
- macOS 13；
- Mac Catalyst 16；
- tvOS 16；
- watchOS 9；
- visionOS 1。

V1 必须在 Package 支持的全部平台上保持可编译。具体运行验证根据当前开发环境和风险选择。

## 9. V1 非目标

- per-entry expiration；
- timer、App lifecycle hook 与后台 expiration sweep；
- V2 observability API；
- S3-FIFO、SIEVE、SLRU、TinyLFU 或 W-TinyLFU 的生产接入；
- public Policy / Storage / Backend；
- Storage × Policy 自动组合；
- Memory + Disk 自动层级编排；
- 多实例或多进程共享同一缓存目录；
- file lock 与运行期独占协调；
- Codable；
- checkpoint、journal、事务与崩溃恢复；
- 网络请求、HTTP Cache、图片解码、图片处理、UI 或 Combine。

## 10. 后续演进规则

Latte 从完整 Cache family 演进，不从假想的万能协议演进。

新增算法或介质时：

1. 先实现完整 Cache；
2. 明确它真实支持的能力；
3. 使用协议行为测试验证可替换性；
4. 使用算法与介质特有测试验证不变量；
5. 在明确 workload 下 benchmark；
6. 只有重复结构得到两个以上真实实现证明后，才抽取公共 capability。

以下证据可以重新打开公共抽象：

- 多个 Cache family 重复同一份 configuration 与语义；
- 多个持久化实现重复同一套事务和 recovery；
- 多个消费者重复稳定的 Memory + Disk 编排；
- 多个算法能够无损共享同一种 expiration 或 cost contract。

论文、其他库的 API、单个实现和“以后可能需要”都只能提供候选，不能单独升级公共 Requirement。

## 11. V1 完成标准

V1 完成需要同时满足：

- `Caching` 公共协议可用；
- `AsyncCaching` 公共协议可用，并能由外部持久化 Cache 实现；
- `LRUMemoryCache` 完成并符合协议；
- `LRUFileCache` 完成并符合 `AsyncCaching<Key, Data>`；
- stable key、allocated-size 水位、TTL 与 TTI 行为通过测试；
- ownership marker、未知目录零删除和临时 artifact fail-closed 行为通过测试；
- `LRUFileCache` 在 `Key: Sendable` 时提供经过跨 actor 验证的条件式
  `@unchecked Sendable`；
- Swift 6 build 与 tests 通过；
- LRU 行为、并发与 differential tests 通过；
- Policy hit-rate benchmark 保留；
- 完整 `LRUMemoryCache` operation benchmark 能运行；
- 完整 `LRUFileCache` benchmark 能运行，并清楚说明文件系统、Data size、
  warm / cold 状态与读写条件；
- README 示例能够展示网络图片库如何注入 `Caching`；
- 文档不再暗示 Policy、Storage 或 Backend 可以任意组合。
