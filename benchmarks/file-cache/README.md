# file cache operation benchmark

`FileCacheBenchmark` measures complete awaited operations on a concrete
`LRUFileCache<Int>`. Every timed public call includes its synchronous file I/O
on Latte's serial owner. Setup, prefill, reporting and cleanup are outside the
timed region.

The default workload fixes:

- 2,000 operations per main scenario;
- 256 prefilled resident files;
- 512 possible keys;
- 64 KiB `Data` values;
- a deterministic 80% read / 20% write mixed workload;
- a 60-second persisted access-touch interval;
- three independent timed runs;
- median wall-clock duration.

Each run owns a fresh subdirectory under the selected root. The executable
prints that root, the volume format when Foundation exposes it, and whether the
volume is local. Use `--directory` to deliberately select APFS, a simulator
container, external storage, or another filesystem.

## scenarios

- `warm-hit` and `warm-miss` use an already initialized and populated Cache;
  an indexed miss does not read a resident file;
- `resident-overwrite` measures atomic replacement and final metadata reads;
- `mixed-read-write` uses the configured deterministic read/write ratio;
- `remove-insert-cycle` reports each remove and insert as a separate operation;
- `remove-all` times one deletion of the full resident set per run;
- `cold-rebuild` times one initializer that reconstructs all resident metadata
  from an existing directory.

The default touch interval means repeated warm hits normally read `Data` and
update in-memory recency without persisting modification time on every hit.
Pass `--touch-interval 0` to measure the default `LRUFileCache` behavior where
every successful hit attempts a persistent touch.

Run a release build:

```sh
swift run -c release FileCacheBenchmark
```

Run on a specific filesystem with a different workload:

```sh
swift run -c release FileCacheBenchmark \
  --directory /path/on/the/target/volume \
  --operations 5000 \
  --residents 512 \
  --key-space 1024 \
  --value-size 262144 \
  --read-ratio 0.90 \
  --touch-interval 0 \
  --runs 5
```

Temporary peak allocation from atomic writes remains part of the filesystem
behavior, but directory cleanup is excluded from timing. The results are local
measurements, not portable latency promises.

Do not compare this table directly with `MemoryCacheBenchmark`: the sync and
async Cache families own different media and execution costs. Compare file
results only when filesystem, Data size, residency, read/write ratio, touch
configuration, build mode and hardware are controlled.
