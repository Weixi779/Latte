# Memory cache operation benchmark

`MemoryCacheBenchmark` measures complete public operations on a concrete
`LRUMemoryCache<Int, Data>`. It is not a Policy simulator and it does not place
an existential or generic wrapper between the workload and the Cache.

The default workload fixes:

- 1,000,000 operations per main scenario;
- 4,096 resident entries;
- 8,192 possible keys;
- 4 KiB `Data` values;
- five independent timed runs;
- median wall-clock duration;
- a deterministic 80% read / 15% write / 5% remove mixed workload.

Scenarios separately measure warm hits, misses, resident overwrites, insertions
that cause eviction, the mixed workload, and `removeAll`. Cache construction and
prefill are outside the timed region. `removeAll` reports one operation per run
and therefore should be interpreted separately from the high-volume scenarios.
The evicting-insert sequence rotates through the entire key space starting
immediately after the prefilled range. Because `key-space` must be greater than
`capacity`, every timed insertion is a miss against a full Cache and therefore
causes one eviction.

Run a release build:

```sh
swift run -c release MemoryCacheBenchmark
```

Override the workload:

```sh
swift run -c release MemoryCacheBenchmark \
  --operations 2000000 \
  --capacity 8192 \
  --key-space 16384 \
  --value-size 65536 \
  --runs 5
```

The reported values are local measurements for the current machine, OS and
compiler. They are not portable latency guarantees. Compare results only when
the command, build mode, hardware and surrounding system load are controlled.
