# benchmarks

Latte keeps three benchmark layers separate:

- [Policy hit-rate benchmark](policy-hit-rate/README.md) replays traces
  against policy-only simulations and reports object/byte hit rates.
- [Memory cache operation benchmark](memory-cache/README.md) measures
  complete concrete `LRUMemoryCache` operations.
- [File cache operation benchmark](file-cache/README.md) measures
  complete awaited `LRUFileCache` operations on a declared filesystem.

The operation benchmarks intentionally use separate executables and result
tables. A synchronous memory operation and an asynchronous file operation are
not interchangeable latency samples, even though both implementations satisfy
Latte's minimal Cache behavior contracts.

Both operation benchmarks run every deterministic scenario with statistics
disabled and enabled. Each run pairs both modes and alternates their AB/BA
execution order across runs to reduce time-order bias. They preserve disabled
as the reported baseline, verify the resulting snapshot after timing, and
report absolute measurements plus relative enabled-versus-disabled collection
overhead. Snapshot retrieval and validation are outside the timed region.
