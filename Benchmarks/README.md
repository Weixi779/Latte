# Benchmarks

Latte keeps three benchmark layers separate:

- [Policy hit-rate benchmark](PolicyHitRateBenchmark/README.md) replays traces
  against policy-only simulations and reports object/byte hit rates.
- [Memory cache operation benchmark](MemoryCacheBenchmark/README.md) measures
  complete concrete `LRUMemoryCache` operations.
- [File cache operation benchmark](FileCacheBenchmark/README.md) measures
  complete awaited `LRUFileCache` operations on a declared filesystem.

The operation benchmarks intentionally use separate executables and result
tables. A synchronous memory operation and an asynchronous file operation are
not interchangeable latency samples, even though both implementations satisfy
Latte's minimal Cache behavior contracts.
