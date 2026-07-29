# LRUFileCache V1 实施计划

> 状态：Stage 0 至 Stage D 已完成；下一步进入 Stage E
> 日期：2026-07-29
> 主视角：状态所有权
> 辅助视角：API 边界、失败语义与不必要复杂度

## 1. 目标

V1 增加一个 Apple 全平台、Swift 6、文件目录驱动的
`LRUFileCache<Key>`：

- 对外遵循 `AsyncCaching<Key, Data>`；
- 每个公开操作都在对应文件 I/O 完成后返回；
- 使用调用者提供的稳定 Key material 和 Latte 内部 SHA-256 文件名；
- 使用文件系统观察到的实际分配大小进行容量管理；
- 使用 LRU 和可配置高低水位回收文件；
- 支持整个 Cache 实例级别的 TTL 与 TTI；
- 可以在进程重启后从目录和文件元数据重建状态；
- 不引入 public Policy、Backend、Storage、Decision 或 Transaction 抽象。

V1 的成功标准不是提供任意算法与任意介质的自由组装，而是证明：

> `Caching` / `AsyncCaching` 足以作为调用侧替换边界，同时每个完整
> Cache 可以诚实拥有自己的算法、介质、生命周期和失败语义。

## 2. 已冻结边界

### 2.1 公共边界

保留：

- `Caching`；
- `AsyncCaching`；
- `LRUMemoryCache`；
- `LRUFileCache` 作为新的完整 Cache family。

不公开：

- `CachePolicy`；
- `CacheDecision`；
- `CacheMutation`；
- `Storage`；
- `Backend`；
- 文件系统操作协议；
- LRU 链表或 metadata index。

`LRUFileCache` 只遵循 `AsyncCaching`。V1 不提供同步文件 Cache，也不提供
async → sync 适配。

### 2.2 Value 与 Key

- `Value` 固定为 `Data`；
- `Key` 继续满足 `Hashable`，以符合 `AsyncCaching`；
- 调用者提供 `@Sendable (Key) throws -> Data`，负责产生跨进程稳定的
  Key material；
- Latte 使用 SHA-256 把该 Data 转换为安全、固定长度的文件名；
- SHA-256 使用 Apple 平台自带 CryptoKit，不增加第三方 crypto dependency；
- 不使用 Swift `Hasher` 或 `hashValue` 持久化身份；
- 不保存原始 Key，也不承诺可从目录反向恢复 Key。

stable key encoder 可能被多个调用任务同时执行，因此它的实现必须符合
`@Sendable` 约束，不依赖未同步的可变状态。

### 2.3 I/O 与并发

- public API 为 `async throws`；
- Foundation / FileManager 的阻塞操作在专用串行 I/O executor 上同步执行；
- 不在 Swift cooperative executor 上直接进行大块阻塞文件 I/O；
- 一个串行所有者同时拥有文件操作顺序、metadata index、LRU 顺序和累计占用；
- 操作排队前响应 Task cancellation；I/O 或 publish 已开始后必须完成状态收敛，
  不在一半状态中途退出；
- 不使用 fire-and-forget 写入；
- 不提供 `flush()`、`start()`、`prepare()` 或隐藏的 lazy readiness；
- async throwing initializer 完成目录创建、扫描、恢复和首轮清理后才返回；
- ownership marker 只验证目录属于 Latte，不充当实例锁；
- V1 把一个 Cache 实例、一个进程独占一个目录作为调用者前置条件；
- 多实例共享目录和多进程一致性不在 V1 范围。

### 2.4 容量

- `maximumDiskUsage` 是主要容量配置，单位为 byte；
- 文件 cost 优先读取 `totalFileAllocatedSize`；
- 无法读取 allocated size 时回退到逻辑 `fileSize`；
- 容量是观察值和软约束，不声明为严格文件系统 quota；
- 默认 high watermark 为 `0.95`；
- 默认 low watermark 为 `0.90`；
- 必须满足 `0 < low < high <= 1`；
- observed usage 严格超过 high watermark 时开始回收；恰好等于 high 时不触发；
- 候选最终 allocated size 严格超过 high watermark 时拒绝；
- 候选不超过 high watermark 时允许接纳，并只在本次 insert 的回收中受保护；
- 回收直到不高于 low watermark，或者只剩本次候选时停止；
- 单独位于 low 与 high 之间的候选允许保留；
- 本次 insert 结束后候选恢复为普通 resident，后续可以被正常淘汰；
- 回收前先删除已过期文件，再按 LRU 删除未过期文件；
- 明显超过 high watermark byte limit 的 Data 可以在写入前拒绝；
- 最终 URL 的发布后 allocated size 才是接纳与容量计算的状态真相；
- 原子写入的临时文件可能造成短暂超额，V1 不承诺消除该峰值。

一次未抛错的 `insert` 不保证随后一定 hit。超大对象拒绝、并发覆盖、过期和
容量回收都属于正常 Cache 行为。

例如 maximum 为 100、high 为 95、low 为 90，候选最终占 93，旧 resident
占 4：总量 97 触发回收，旧 resident 被淘汰后剩余 93。此时虽然仍高于 low，
也必须停止，不能继续删除当前候选。候选是否接纳不应取决于无关旧 resident。

### 2.5 Expiration

TTL 与 TTI 都是整个 `LRUFileCache` 实例的配置：

- `timeToLive: Duration?`；
- `timeToIdle: Duration?`；
- `nil` 表示禁用；
- 两者同时存在时，任意一个到期即视为 miss；
- 不提供 per-entry expiration；
- 需要不同期限时创建不同 Cache 实例。

语义：

- TTL 从最近一次成功写入该 Key 开始；
- TTI 从最近一次成功读取或写入该 Key 开始；
- 进程内每次 hit 都立即更新内存中的 last access；
- 文件 modification date 用作跨启动的近似 last access；
- `accessTimeUpdateInterval: Duration` 控制 modification date 的持久化节流；
- `.zero` 表示每次 hit 都持久化，作为 V1 默认值；
- 节流只影响崩溃或重启后的 TTI 近似，不降低进程内判断精度；
- 如果 touch interval 大于 TTI，重启后可能比进程内更早过期；这是调用者可见的
  best-effort 权衡，不自动改写配置；
- 不存在后台待提交 touch，公开调用返回后不会遗留隐藏 I/O。

V1 只做机会式清理：

- 初始化扫描时；
- 查找目标 Key 时；
- 容量回收开始时。

不增加 timer、App lifecycle hook 或后台 sweep。空闲 Cache 可以暂时在磁盘上
保留已过期文件，但绝不会返回已过期内容。

## 3. 建议公共 API 形状

以下形状用于冻结职责和配置，不要求逐字保留命名：

```swift
public final class LRUFileCache<Key: Hashable>: AsyncCaching {
    public typealias Value = Data
    public typealias StableKeyEncoder = @Sendable (Key) throws -> Data

    public struct Configuration: Sendable {
        public let maximumDiskUsage: Int
        public let lowWatermark: Double
        public let highWatermark: Double
        public let timeToLive: Duration?
        public let timeToIdle: Duration?
        public let accessTimeUpdateInterval: Duration
    }

    public init(
        directory: URL,
        configuration: Configuration,
        stableKeyEncoder: @escaping StableKeyEncoder
    ) async throws

    public func value(for key: Key) async throws -> Data?
    public func insert(_ value: Data, for key: Key) async throws
    public func removeValue(for key: Key) async throws
    public func removeAll() async throws
}

extension LRUFileCache: @unchecked Sendable where Key: Sendable {}
```

`LRUFileCache` 的具体并发合同冻结为条件式
`@unchecked Sendable where Key: Sendable`：

- 不扩大 `AsyncCaching` 的 associated type 约束；
- `Key` 不满足 `Sendable` 时，类型仍可在当前隔离域使用，但不获得
  `Sendable` conformance；
- `@unchecked` 来自编译器无法证明 DispatchQueue 隔离，不代表放弃检查；
- final class、专用串行 owner、不可逃逸的内部状态和 `@Sendable` key encoder
  共同承担该承诺；
- 使用跨 actor 编译测试和并发状态机测试验证实际调用形状。

配置验证：

- `maximumDiskUsage >= 0`；
- watermark 满足顺序与范围约束；
- TTL、TTI 与 touch interval 不得为负；
- TTL 或 TTI 为 `.zero` 时条目立即过期；
- `maximumDiskUsage == 0` 时 Cache 合法存在，但不保留写入。

构造错误属于编程错误的配置使用 precondition；目录创建、扫描、metadata
读取等环境错误由 async initializer 抛出。

## 4. 内部结构

### 4.1 共享的是数据结构，不是 Policy

Stage A 前的 `LRUPolicy` 同时拥有：

- cost 上限；
- total cost；
- recency；
- admission / rejection；
- victim decision。

它适合当时的内存实现，却不适合文件 Cache 的高低水位、真实分配大小、过期优先
清理和非事务 I/O。Stage A 已把共同部分收缩为 package/internal 的纯顺序结构：

```text
LRUList<Identity>
├── insertAsMostRecent
├── touch
├── remove
├── leastRecentlyUsed
└── removeAll
```

它不认识 Value、cost、capacity、expiration、文件或 `CacheDecision`。

随后：

```text
LRUMemoryCache.State
├── entries: Key → Value + cost
├── totalCost
└── recency: LRUList<Key>

LRUFileCache.State
├── entries: Filename → FileMetadata
├── observedDiskUsage
└── recency: LRUList<Filename>
```

由各自完整 Cache 决定何时插入、拒绝和淘汰。迁移已经删除：

- `CacheDecision.swift`；
- `CacheEntryDescriptor`；
- 现有容量感知的 `LRUPolicy`；
- 只验证该虚假分层的 `LRUPolicyTests`。

对应测试转移到：

- `LRUList` 的顺序与结构不变量测试；
- `LRUMemoryCache` 的 cost / eviction 行为测试；
- `LRUFileCache` 的容量 / expiration / I/O 行为测试。

Policy hit-rate benchmark 拥有自己的 simulator，不依赖上述产品内部类型，继续保留。

### 4.2 目录归属、文件身份与布局

V1 使用一个平铺、由 ownership marker 标记的目录：

```text
cache-directory/
├── .latte-cache
├── <sha256>
├── <sha256>
└── .latte-<temporary artifact>
```

- `.latte-cache` 只保存固定 magic、Cache family 与 format version；
- marker 不保存 Key、resident、LRU、容量、TTL 或 TTI，因此不是 manifest；
- marker 证明目录由 Latte 管理，但不证明当前只有一个实例或进程正在使用；
- 正式文件名只包含 SHA-256 十六进制结果；
- 临时文件使用 Latte 保留前缀；
- 只有合法 marker 与完整目录分类通过后，初始化才删除遗留临时文件；
- index 使用文件名作为 identity，因此启动时无需恢复原始 Key；
- Key hash collision 被视为 SHA-256 的现实不可达风险，不增加原始 Key sidecar。

目录接管规则：

- 目录不存在：创建目录与 marker；
- 目录已存在且为空：写入 marker 后接管；
- 目录非空但 marker 缺失、损坏或版本未知：初始化失败，零删除；
- marker 合法但出现未知名称或非普通目录项：初始化失败，零删除；
- 必须先完成整份 inventory 分类，再开始任何自愈或清理，不能边扫描边删除；
- 只有正式 SHA-256 文件和 Latte 保留 artifact 属于可清理范围；
- `removeAll()` 保留 marker 和目录本身。

“验证目录归属”不能写成“验证运行期独占”。如果未来要支持多个实例或进程共享，
需要独立的 file lock / coordination 设计，marker 不能承担该职责。

### 4.3 Metadata

每个 resident 文件的内存 metadata 至少包含：

- URL / filename identity；
- observed allocated size；
- written date；
- last access date；
- last persisted access date。

持久化映射：

- file creation date 表示最近一次写入时间，用于 TTL；
- file modification date 表示最近一次持久化访问，用于 TTI；
- 当前进程中的 last access 以内存值为准；
- 不持久化 `ContinuousClock.Instant`；
- 对 wall clock 跳变的精确防护不进入 V1，使用明确测试固定现有行为。

覆盖写入必须产生新的 written date。directory truth、无 manifest 在 Stage 0
完成前属于 **Needs Evidence**；现已由本计划记录的 Stage 0 证据接受为 V1 模型。

Stage 0 必须验证：

- 新文件、atomic move 与 atomic replace 后的 creation / modification date；
- 使用 `.usingNewMetadataOnly` 时，最终 URL 是否采用新文件 metadata；
- overwrite 能否可靠重置 TTL written date；
- modification date touch 能否可靠表达跨启动 TTI；
- replace / move 前后的 `totalFileAllocatedSize` 与 `fileSize`；
- 最终 URL 的 metadata 是否可能与临时文件不同。

无论 Stage 0 结果如何，发布后都必须重新读取正式 URL 的 metadata。临时文件
metadata 只用于发布前的明显超大拒绝，不能直接登记为 resident truth。

Foundation 会缓存 `URLResourceValues`。最终 URL 的 metadata helper 必须从路径
重新构造 URL，并在读取前调用 `removeAllCachedResourceValues()`；不能复用 publish
前或 touch 前持有的 URL 直接读取，否则可能观察到旧的 modification date。

如果目标文件系统不能可靠支持该模型，立即暂停后续实施，重新选择：

- 使用 xattr 或 sidecar 持久化时间；
- 接受 manifest；
- 降低跨启动 TTL / TTI 承诺；
- 收窄无法验证的平台范围。

不得一边保留“directory truth、无 manifest”的文档承诺，一边在实现中静默加入
另一套持久化状态源。

平台证据入口：

- [FileManager.ItemReplacementOptions](https://developer.apple.com/documentation/foundation/filemanager/itemreplacementoptions)；
- [URLResourceValues.creationDate](https://developer.apple.com/documentation/foundation/urlresourcevalues/creationdate)；
- [URLResourceValues.totalFileAllocatedSize](https://developer.apple.com/documentation/foundation/urlresourcevalues/totalfileallocatedsize)。

### 4.4 File access seam

增加一个很窄的 package/internal 文件访问边界，仅服务：

- 向 Latte 自有 staging URL 直接写入；
- 通过 move / replace 原子发布；
- Data 读取；
- 目录枚举；
- resource metadata 读取；
- modification date touch；
- 单文件和全目录清理；
- 目录创建。

生产实现使用 Foundation。测试实现用于稳定注入：

- write failure；
- read failure；
- metadata failure；
- remove failure；
- allocated size 与 logical size 差异；
- 文件在操作间消失。

这个 seam 不是 public Backend，不承载 Policy，也不能被用户自由组合。

不得在 Cache 目录内使用 `Data.write(options: .atomic)`。Foundation 的 atomic
write 会创建命名不受 Latte 控制的 auxiliary file，进程中断后可能与严格
inventory 规则冲突。所有 marker 与 resident 写入必须先直接写到 Latte 生成的
`.latte-tmp-*` URL，再通过 move / replace 发布；因此中断残留仍属于可证明、
可分类和可清理的 artifact。

## 5. 操作状态机

### 5.1 初始化

1. 验证配置；
2. 创建专用串行 I/O executor；
3. 创建目录，或读取现有目录；
4. 对新建或已有空目录写入 ownership marker；
5. 对非空目录验证 marker magic、Cache family 与 format version；
6. 枚举并分类完整 inventory，不执行删除；
7. 发现未知名称或非普通目录项时零修改失败；
8. inventory 全部合法后，删除已知 Latte 临时 artifact；
9. 对普通正式文件读取容量与时间 metadata；
10. 自愈已确认归属的单文件异常；
11. 把已过期文件从磁盘删除；
12. 以持久化 last access 重建 LRU；
13. 计算 observed disk usage；
14. 如果超过 high watermark，回收到 low watermark；
15. 状态完整后 initializer 返回。

初始化失败分类冻结为：

- 目录创建、目录枚举、目录权限等目录级错误：initializer 抛错；
- 扫描期间文件消失：忽略；
- 非空目录缺少合法 marker：零删除并抛错；
- 未知目录项或 `isRegularFile != true`：零删除并抛错；
- 已确认归属的 Latte 临时 artifact：尝试删除；
- 临时 artifact 无法删除：initializer 抛错；
- 单文件 required metadata 损坏或缺失：尝试删除并继续；
- `totalFileAllocatedSize == nil`：回退 `fileSize`，不单独视为损坏；
- 文件既无法可靠计量又无法删除：initializer 抛错；
- 单文件异常不能让 observed usage 留下不可计量的洞。

“required metadata”包含普通文件身份、可计量大小和 LRU 所需时间；启用 TTL /
TTI 后还包含对应的 written / last-access 时间。初始化只在目录级故障或无法自愈
且会破坏容量不变量时失败。

### 5.2 Lookup

1. 在调用任务中执行 stable key encoder 和 SHA-256；
2. 把 filename identity 提交给串行 I/O executor；
3. index 不存在时返回 `nil`；
4. 判断 TTL / TTI；
5. 已过期时机会式删除文件：成功则移除 metadata，失败则保留为 expired resident
   以便后续重试；无论哪种情况都返回 `nil`；
6. 读取 Data；
7. 文件已被系统移除时同步修正 state 并返回 `nil`；
8. 其他 read error 抛出；
9. 更新内存 last access 与 LRU；
10. 达到 touch interval 时更新 modification date；
11. 返回 Data。

touch 是 TTI 的近似持久化 bookkeeping。touch 失败不应把已经成功读取的 Value
变成业务错误；保留内存 last access，并在后续符合条件的 hit 再尝试。V2 使用
观测能力暴露此类退化。

### 5.3 Insert

1. 编码并 hash Key；
2. 明显超大或零容量时正常拒绝，不改动已有 resident；
3. 把候选同步写入同目录的唯一临时文件；
4. 查询临时文件的 allocated size 与时间属性；
5. metadata 查询失败时清理临时文件；清理成功则抛出原始错误，清理失败则实例
   进入不可用状态；
6. 临时文件已明显超过 high limit 时清理临时文件；清理成功则正常拒绝并保留旧
   resident，清理失败则实例进入不可用状态；
7. 使用原子 move / replace 把临时文件发布到正式文件名；
8. 使用 `.usingNewMetadataOnly`，并在发布后重新读取正式 URL 的 metadata；
9. 最终 allocated size 超过 high limit 时删除正式候选并执行目录 reconciliation；
10. 最终 metadata 合法时才登记为 most recent，并更新 observed usage；
11. 删除已过期 resident；
12. 总量超过 high 时保护当前候选，优先按 LRU 淘汰旧 resident；
13. 回收到 low，或者只剩当前候选时停止；
14. 所有属于本次调用的 I/O 完成后返回。

这里的临时文件是同一次 awaited insert 内的原子发布机制，不是隐藏的 staging
cache，也不会在方法返回后继续写入。覆盖写发布失败时必须保留旧文件；对应平台
行为通过 Foundation file-access integration test 固定。publish 失败后必须检查
临时 artifact 是否仍存在并执行清理；清理失败同样使实例进入不可用状态。

运行期间任何 Latte 临时 artifact 都由当前串行 owner 负责。它不能作为不可见
占用留在 `observedDiskUsage` 之外：

- cleanup 成功：按原操作语义返回或抛错；
- cleanup 失败：不尝试把临时文件伪装成 resident，也不继续提供可能低估容量的
  Cache；实例进入不可用状态；
- reconciliation 必须先分类并删除所有已知临时 artifact；
- reconciliation 无法删除临时 artifact 时失败，并保持实例不可用。
- reconciliation 发现 marker 无效、未知名称或非普通目录项时不得删除它们，并使
  实例保持不可用，因为 observed usage 已无法覆盖完整目录。

发布成功到最终 metadata 登记完成之间是串行 owner 内部的不可观察阶段。若最终
metadata 读取失败：

1. 不把临时 metadata 提交到 index；
2. 尝试删除已经发布但无法计量的正式文件；
3. 从目录重新扫描并原子替换整份内存 index、LRU 与 observed usage；
4. reconciliation 成功后，本次 insert 仍抛出原始 metadata error，但 Cache
   可以继续使用；
5. reconciliation 也失败时，把该实例标记为不可用；后续操作持续抛出一致性错误，
   直到调用者销毁并重新创建实例。

同 Key 的旧文件在 publish 成功后可能已经被替换。V1 是 Cache 而不是事务存储，
因此上述异常路径不承诺恢复旧 Value；它只承诺不继续使用无法计量的内存状态。

最终 metadata 显示候选超过 high limit 时属于正常容量拒绝：删除候选并
reconcile；收敛成功后 `insert` 正常返回，收敛失败则抛错并标记实例不可用。

文件系统不是事务数据库。写入已经发布后发生回收失败时，方法抛错，但不承诺回滚
此前成功的文件变更；内存 state 必须与实际成功的文件操作保持一致，下一次启动
也能从目录重建。

### 5.4 Remove

`removeValue`：

- 不存在时成功返回；
- 文件已消失时修正 state 并成功返回；
- 其他删除错误抛出，并保留未成功删除的 resident metadata。

`removeAll`：

- 先完成整份 inventory 分类，再清理全部正式文件和 Latte 临时文件；
- 清理完成后保留 marker 与目录；
- 未知目录项不属于 Latte，不能由 `removeAll` 删除；
- 发现 marker 无效、未知名称或非普通目录项时，零删除、抛错并使实例不可用；
- 对每个成功删除或已经缺失的文件同步移除 metadata；
- 正式 resident 删除失败时保留对应 metadata 与 observed usage，完成其他可安全
  清理后抛出首个错误；由于状态仍可准确表达磁盘，实例可以继续使用；
- Latte 临时 artifact 清理失败时完成能够安全收敛的步骤、抛错并使实例不可用；
- marker 异常、未知目录项和非普通目录项属于归属或计量不变量失败，同样使实例
  不可用；
- 不删除目录本身。只有全部失败都属于可准确保留 metadata 的正式 resident
  删除失败时，Cache 实例才保持可继续使用。

## 6. 错误语义

| 场景 | 对外结果 |
|---|---|
| Key encoder 失败 | 抛错 |
| 从未存在、已淘汰、已过期 | `nil` |
| 目标文件在读取前被系统清理 | `nil`，修正 index |
| Data read 真实失败 | 抛错 |
| 原子写失败 | 抛错；已有文件应保持 |
| 临时 metadata / publish 失败且 artifact 清理成功 | 按原错误语义结束，不泄漏占用 |
| Latte 临时 artifact 清理失败 | 实例进入不可用状态，后续操作持续抛错 |
| 候选因容量正常拒绝 | 成功返回 |
| 显式 remove 真实失败 | 抛错 |
| `removeAll` 正式 resident 删除失败 | 保留 metadata 与占用、抛错，实例可继续使用 |
| `removeAll` 临时 artifact / marker / inventory 失败 | 抛错，实例不可用 |
| hit 后 modification date touch 失败 | 仍返回 Data，稍后重试 |
| 机会式过期删除失败 | `nil`；保留 expired metadata 与占用，等待后续重试 |
| 容量回收真实失败 | insert / init 抛错 |
| publish 后最终 metadata 读取失败 | 删除不可计量文件、reconcile、抛出原始错误 |
| publish 后文件无法计量且无法自愈 | 实例进入不可用状态，后续操作持续抛错 |
| 排队前 Task 已取消 | 抛出 `CancellationError`，不开始 I/O |

不增加 `CacheLookup`、miss reason enum 或 result wrapper。

## 7. 实施顺序

### Stage 0：验证文件系统模型，不改产品代码

- 建立独立 probe，不修改 `Sources/Latte`；
- 验证新建、atomic move、atomic replace 和 `.usingNewMetadataOnly`；
- 每次 publish 后读取最终 URL 的 creation date、modification date、
  `totalFileAllocatedSize` 与 `fileSize`；
- 验证 overwrite 后 TTL written date 是否重置；
- 验证 modification date touch；
- 验证普通文件识别与 allocated-size fallback；
- 至少覆盖 macOS APFS、iOS Simulator data container 和可用的
  tvOS / watchOS / visionOS Simulator；
- V1 发布前补充 iOS device 验证；
- 对所有声明平台执行 SDK 编译检查，并明确记录无法运行验证的平台。

Stage 0 是证据门。creation / modification date、replace metadata 或最终
allocated size 任一关键假设不成立时，停止，不进入 Stage A；先回到持久化模型
决策，不能用现有内存重构投入倒逼保留失败的方案。

#### Stage 0 结论（2026-07-29）

Stage 0 已通过，完整记录见
[FileMetadataProbe results](Probes/FileMetadataProbe/RESULTS.md)：

- macOS APFS、iOS Simulator、watchOS Simulator 与 Mac Catalyst 的运行验证通过；
- atomic move 保留候选 metadata；
- `.usingNewMetadataOnly` replacement 的最终 URL 使用候选 creation /
  modification date，overwrite 可以重置 TTL written date；
- modification date touch 可以表达跨启动 TTI；
- 最终 URL 可以读取 allocated size，并在不可用时保留 logical-size fallback；
- iOS、macOS、Mac Catalyst 与 watchOS 完整构建或测试通过；
- tvOS 与 visionOS 源码分别对对应 SDK 完成 Swift 6 type-check；
- 当前 Xcode 未安装 tvOS / visionOS 完整平台组件，因此这两个平台没有
  Xcode package 集成构建与运行时证据；可用后必须补跑；
- iOS 真机运行验证仍按原计划作为 V1 发布门。

没有关键文件系统假设失败。directory truth、无 manifest 从 **Needs Evidence**
升级为 V1 已接受模型；缺失的平台运行时证据必须如实保留，不能外推为已验证。

### Stage A：收回旧 LRU 抽象

完成于 2026-07-29：

- 在重构前增加 `ReentrantKey` 回归测试；
- 保留现有 `ReentrantValue` 测试；
- 提取纯顺序 `LRUList`；
- 让 `LRUMemoryCache` 自己拥有 total cost、拒绝和 victim 选择；
- 保留 `Entry.key` 或等价的锁外 Key 生命周期护栏；
- LRU node 被移除时，必须确保其 Key 仍由锁外 retired ownership 持有；
- 删除 `CacheDecision`、descriptor 与容量感知 `LRUPolicy`；
- 把 20,000 次 seeded differential test 迁移到完整 `LRUMemoryCache` 状态机；
- 保持所有现有行为、并发、Key / Value 析构重入和 differential tests 通过。

Stage A 完成后，`LRUList` 只拥有 Key 与 recency。`LRUMemoryCache.State`
直接拥有 entries、total cost、拒绝和 victim 选择；`CacheDecision`、
`CacheEntryDescriptor`、容量感知 `LRUPolicy` 与对应 Policy tests 已删除。

### Stage B：建立文件与时间基础

完成于 2026-07-29：

- 提升 Package 最低平台版本；
- 增加 ownership marker、format version 与两阶段 inventory classification；
- 增加 SHA-256 stable filename；
- 增加 Foundation file access seam；
- 增加可控 wall-clock seam；
- 增加专用串行 I/O executor。

Stage B 的所有类型保持 `package` 可见性：

- `FileCacheFilename` 只接受稳定 Key material，输出 canonical lowercase SHA-256；
- marker 固定 magic、Cache family 与 format version，不承载 resident 状态；
- inventory classifier 完整分类后才返回结果，本身不执行删除；
- Foundation seam 保留 throwing I/O 语义，并在每次 metadata 读取前清除
  `URLResourceValues` 缓存；
- 所有写入直接落到 `.latte-tmp-*` staging URL，再通过 move / replace 发布，
  不依赖 Foundation 自行命名的 atomic-write auxiliary file；
- wall-clock seam 允许测试注入时间，不依赖真实 sleep；
- `FileCacheWorker` 使用实例专属串行队列，在 operation 完成后才恢复 continuation，
  并在排队前传播任务取消。

本阶段没有增加 public Backend、Storage 或 `LRUFileCache` CRUD。

### Stage C：实现启动恢复与基础 CRUD

完成于 2026-07-29：

- async throwing initializer；
- 目录扫描和 index 重建；
- read / atomic write / remove / removeAll；
- 同 Key 并发操作全部由串行 owner 排序；
- 实现条件式 `@unchecked Sendable where Key: Sendable`；
- 使用跨 actor 编译测试验证 Sendable 形状，不提前扩大公共协议要求。

`LRUFileCache<Key>` 现在固定遵循 `AsyncCaching<Key, Data>`。stable key encoder
在操作进入串行 owner 前生成 key material；worker 内只处理 SHA-256 文件名、
resident metadata、LRU 顺序与文件 I/O。

启动恢复会在任何删除前验证完整 inventory 与 marker。空目录通过受控
`.latte-tmp-*` staging 发布 marker；如果首次发布在 rename 前中断，下一次启动
只会在目录中唯一 artifact 是合法 marker staging 时完成接管。合法目录内遗留
的 resident staging 会在完整分类后清理；清理失败则 fail closed。

基础 CRUD 已冻结以下失败语义：

- staging 写入或 publish 失败时清理候选，旧 resident 保持可读；
- publish 已完成但最终 metadata 无法建立时删除正式文件并收敛为 miss；
- resident 删除失败时保留内存 metadata，实例仍可继续使用；
- 临时 artifact 清理失败时实例进入不可用状态；
- `removeAll` 删除前重新验证完整 directory inventory，清理运行期新增的 resident
  与 staging，并保留 ownership marker；
- marker、未知名称或非普通目录项异常时 `removeAll` 零删除并使实例不可用；
- hit 后 touch 失败仍返回 Data、刷新内存 LRU，并保留持久化时间以便后续重试；
- 启动枚举后的 resident / staging 消失会被忽略，marker 消失仍 fail closed；
- 同 key 混合并发与跨 actor 使用由测试覆盖。

Stage C 尚未启用 maximum disk usage、水位回收或 TTL / TTI 失效；这些配置已经
进入公共形状，但对应行为仍严格属于 Stage D。

Stage C 验证结果：

- macOS Debug、Release 与 Thread Sanitizer 下 48 个测试全部通过；
- iOS Simulator、watchOS Simulator 与 Mac Catalyst 完整构建通过；
- tvOS 16 与 visionOS 1 源码分别对已安装 SDK 完成 Swift 6 type-check；
- 本机仍未安装 tvOS / visionOS 完整平台组件，因此没有对应 Xcode package
  集成构建或运行时证据。

### Stage D：加入容量与 expiration

- observed allocated size；
- oversized candidate；
- high / low watermark；
- LRU trim；
- TTL / TTI；
- throttled access-date persistence；
- 初始化和容量路径的过期优先清理。

Stage D 已完成：

- 容量优先使用最终正式文件的 allocated size，缺失时回退 logical size；
- 严格超过 high watermark 才触发回收，并回收到 low watermark；
- 本次候选只在当前 insert 中受保护，单条 oversized 属于正常拒绝；
- trim 失败不伪装成 publish 失败，已成功的文件变更和内存 state 保持一致；
- TTL / TTI 使用实例级 `Duration`，支持进程内精确刷新、持久化 touch 节流与
  重启恢复；
- 初始化、目标 lookup 和 insert 路径执行机会式过期清理，不引入后台任务；
- expiration 全部关闭时跳过 resident 遍历，批量 trim 使用 O(1) LRU 头节点选择；
- `removeAll` 在 inventory 验证后同步清除已被系统移除的 resident state；
- 发布后 metadata 异常和最终尺寸拒绝都会通过完整目录 reconciliation 收敛；
- Debug、Release 与 Thread Sanitizer 下 69 个测试全部通过；
- iOS 16、watchOS 9 与 Mac Catalyst 16 通用目标构建通过；
- tvOS 16 与 visionOS 1 使用对应 SDK 完成 Swift 6 源码 type-check。

### Stage E：交付验证与文档

- Debug 与 Release build / tests；
- 所有声明平台至少完成编译验证；
- README 增加网络图片场景的 memory / file 注入示例；
- 更新 `DIRECTION.md` 完成状态；
- 保留 Policy hit-rate benchmark；
- 增加完整 `LRUMemoryCache` operation benchmark；
- 增加完整 `LRUFileCache` benchmark，并固定文件系统、Data size、warm / cold
  状态、读写比例和目录重建条件；
- benchmark 必须能够运行并说明测量对象；不把首次结果宣传成跨设备稳定结论，
  也不直接比较同步内存与异步文件 Cache 的裸吞吐。

## 8. 验证矩阵

### 8.1 协议与 CRUD

- miss、insert、hit、update、remove、removeAll；
- 同 Key 覆盖不会返回旧 Data；
- initializer 返回时已有文件立刻可读；
- public async 方法返回时对应 I/O 已结束；
- Cache 被跨任务调用时状态不分叉。
- `Key: Sendable` 时 `LRUFileCache` 可以安全跨 actor 传递；
- 非 `Sendable` Key 不获得具体 Cache 的 `Sendable` conformance。

### 8.2 Stable Key

- 相同 stable material 跨实例生成相同文件名；
- 不同 Key material 生成不同文件名；
- encoder error 原样传播；
- 文件名不包含调用者原始字符串或路径字符。

### 8.3 Capacity

- 优先使用 allocated size；
- metadata 缺失时回退 logical size；
- overwrite 正确计算 size delta；
- 未到 high 不 trim；
- 超过 high 后回收到 low；
- 候选位于 low 与 high 之间时可以单独保留；
- 本次候选不因无关旧 resident 而被继续 trim；
- 下一次 insert 时前一候选不再受保护；
- 先清过期，再清 LRU；
- 单条 oversized 正常拒绝；
- 原子临时文件峰值不被误写成严格 quota 承诺；
- trim 删除失败时 state 与实际文件保持一致。

### 8.4 TTL / TTI

- TTL only；
- TTI only；
- TTL + TTI 任一到期；
- disabled expiration；
- zero duration 立即过期；
- hit 刷新进程内 TTI；
- touch interval 为 zero；
- touch interval 节流；
- 重启后从 creation / modification date 恢复；
- overwrite 重置 TTL；
- touch failure 不吞掉成功 hit；
- 不使用真实 sleep，全部通过可控 clock。

### 8.5 Recovery 与错误

- 不存在的目录由 Latte 创建并写入 marker；
- 已有空目录可以由 Latte 写入 marker 后接管；
- 非空且无 marker 的目录初始化失败并保持零修改；
- marker 损坏或版本未知时初始化失败并保持零修改；
- 合法 marker 下出现未知名称时初始化失败并保持零修改；
- 非普通目录项初始化失败，不递归删除；
- `removeAll` 保留 marker；
- 遗留临时文件；
- 初始化时临时文件清理失败；
- 运行时临时 metadata 失败且 cleanup 成功；
- 运行时 publish 失败且 cleanup 成功；
- 任意临时 artifact cleanup 失败使实例不可用；
- reconciliation 不会忽略临时 artifact 的磁盘占用；
- 初始化时过期文件；
- 初始化时已超过 high watermark；
- metadata 损坏文件被删除后继续初始化；
- 无法计量但可以删除的文件不会阻塞初始化；
- 无法计量且无法删除时初始化失败；
- read / write / metadata / touch / remove failure；
- 操作间文件消失；
- 写入失败保留旧 resident；
- metadata 失败不把不可计量文件留在活跃 index；
- publish 后最终 metadata 失败触发 reconciliation；
- reconciliation 失败使实例进入不可用状态；
- `removeAll` 正式 resident 部分删除失败时保留准确 metadata，实例可继续使用；
- `removeAll` 临时 artifact 清理失败时实例不可用；
- `removeAll` marker 异常、未知名称或非普通目录项时零删除且实例不可用。

### 8.6 并发与顺序

- 共享小 keyspace 的 read / insert / remove 交错；
- 同 Key 多次 insert；
- insert 与 removeAll 竞争；
- lookup 与 expiration / eviction 竞争；
- 每个调用只观察串行化后的完整状态；
- 无隐藏 fire-and-forget I/O；
- 不以随机压力测试替代确定性状态机测试。

## 9. V1 明确不做

- Memory + File 自动二级缓存编排；
- SQLite、UserDefaults、Keychain 实现；
- S3-FIFO、SIEVE、SLRU、TinyLFU 或 W-TinyLFU 的生产实现；
- per-entry expiration；
- timer / lifecycle / background sweep；
- strict quota；
- 多实例或多进程共享目录；
- file lock 与运行期独占验证；
- Stage 0 通过 directory-truth 模型后，不增加 manifest、journal、checkpoint
  或数据库级事务；如果证据门失败，本项必须重新讨论并同步修改本文档；
- encryption、compression、Codable；
- networking、HTTP、图片解码或 Combine；
- public 文件系统 / Backend 扩展点；
- V2 observability API。

## 10. V2 预留但不占位

V2 观测方向包括：

- Request Hit Ratio；
- Byte Hit Ratio；
- hit / miss lookup latency；
- bytes read / written / evicted；
- File Occupancy。

V1 不提前加入 event、callback、metrics snapshot 或 miss reason。Cache 本地只能可靠
计算自己观察到的请求、时延、字节和占用；标准 Byte Hit Ratio 与完整 miss 成本
通常需要上层网络图片编排提供未命中对象大小、网络和解码信息。

## 11. 实施前最后检查

确认本计划即冻结以下选择：

1. `LRUFileCache<Key>` + `Data` + `AsyncCaching`；
2. stable key material 由调用者提供，Latte 负责 SHA-256；
3. 专用串行 I/O owner，所有方法 await 自己的 I/O；
4. directory truth、无 manifest 已通过 Stage 0 证据门；
5. allocated-size 软容量与 95% / 90% 默认水位；
6. 实例级 TTL / TTI，`Duration`，机会式清理；
7. 复用纯 LRU 顺序数据结构，不复用 `CacheDecision`；
8. ownership marker 只证明目录归属，不承担 Cache 状态或运行期锁；
9. 临时 artifact 清理失败时 fail closed；
10. `LRUFileCache` 条件式提供 `@unchecked Sendable where Key: Sendable`；
11. V2 才加入观测。

Stage 0 的持久化模型已经再次确认，Stage A、Stage B 与 Stage C 已完成。下一
实施边界是 Stage D 的 allocated-size 容量、水位回收和实例级 expiration。
