# Policy hit-rate benchmark

This executable compares LRU, SIEVE, equal-sized multi-segment SLRU,
deterministic W-TinyLFU, and the original S3-FIFO policy from
[“FIFO Queues are All You Need for Cache Eviction”][s3fifo-paper] (SOSP 2023).

All policy implementations, reference models, trace parsing, and metric
collection live in `main.swift`. The executable has no dependency on Latte or
another cache implementation.

## Metrics

- `objects` capacity mode gives every resident object a cost of one. This is
  the paper's default comparison model.
- `bytes` capacity mode uses the request's object size as its policy cost. This
  is an additional weighted experiment for Latte's cost-aware direction.
- Object hit rate and byte hit rate are always reported separately.
- Raw object misses and missed bytes make absolute differences inspectable
  without inventing network or disk semantics that this simulator does not own.
- Median nanoseconds per request and requests per second compare replay cost.

Each policy independently and serially replays the full trace with fresh state.
The default is three timed runs. Each run computes its average nanoseconds per
request; the benchmark reports the median of those averages and verifies that
all runs produced identical hit metrics. Timing starts after policy
construction and includes cost selection, the policy request, and metric
accumulation. It excludes trace loading, policy construction, and reporting.

The benchmark runs deterministic differential checks against simple array-based
models for all five policies before loading a trace. The W-TinyLFU check also
compares its packed frequency sketch with an independent unpacked model on
every request.

SIEVE follows the [NSDI 2024 paper][sieve-paper] and official libCacheSim
implementation. Entries remain in insertion order, a hit only sets one visited
bit, and an independent hand scans from older toward newer entries. During
eviction the hand clears visited entries and evicts the first unvisited entry.

W-TinyLFU follows the fixed-size
[Caffeine simulator policy][caffeine-policy]: a 1% admission window, an SLRU
main region split into 20% probation and 80% protected, and a four-depth,
four-bit Count-Min sketch with periodic aging. Admission is deterministic:
the window candidate replaces the probation victim only when its estimated
frequency is strictly greater. Caffeine's optional random admission jitter is
disabled so repeated runs have identical results.

The object-capacity mode is the canonical comparison. The byte-capacity mode
is explicitly a cost-aware extension: queue budgets use bytes, while sketch
width is estimated from the number of average-sized objects the byte budget
can hold. It must not be read as a reproduction of the
[TinyLFU paper][tinylfu-paper].

It was also calibrated against libCacheSim's
`cloudPhysicsIO.oracleGeneral.bin` fixture. At all eight official capacity
points from 128 MiB through 1 GiB, LRU, SIEVE, five-segment SLRU, and S3-FIFO
reproduced libCacheSim's exact object miss counts and missed-byte counts.
Five segments are used only for this calibration because that is the explicit
configuration of libCacheSim's SLRU test fixture. The primary experiment uses
the paper's four equal segments. W-TinyLFU is excluded from this claim because
the libCacheSim fixture has no asserted W-TinyLFU reference result.

## Dataset

Large local traces belong in `Data/`, which is ignored by Git. For the bundled
10-million-request Twitter cluster 52 excerpt:

```sh
mkdir -p Benchmarks/PolicyHitRateBenchmark/Data
zstd -d \
  Research/libCacheSim-develop/data/twitter_cluster52_10m.csv.zst \
  -o Benchmarks/PolicyHitRateBenchmark/Data/twitter_cluster52_10m.csv
```

This excerpt comes from the Twitter cache trace released with CacheLib/OSDI
2020, but it is only the first 10 million requests, not the complete paper
dataset. It is useful for development comparisons and must not be presented as
a reproduction of the S3-FIFO paper's full 6,594-trace evaluation.

## Recorded result

Run on 2026-07-26 with the first 10 million requests of Twitter cluster 52.
The trace footprint was 897,664 objects and 174,722,570 bytes.

| Capacity semantics | Footprint | Metric | LRU | SIEVE | SLRU-4 | W-TinyLFU | S3-FIFO |
|---|---:|---|---:|---:|---:|---:|---:|
| Objects | 0.1% | Object hit | 62.0837% | 63.3607% | 63.4690% | 61.3248% | 65.1517% |
| Objects | 1% | Object hit | 76.2596% | 77.7503% | 77.3127% | 79.0188% | 79.5771% |
| Objects | 10% | Object hit | 86.4341% | 86.9944% | 86.9153% | 86.0930% | 87.6366% |
| Bytes | 0.1% | Byte hit | 58.7985% | 59.6376% | 59.5970% | 56.0569% | 61.1704% |
| Bytes | 1% | Byte hit | 74.4278% | 76.6876% | 75.9813% | 77.8429% | 78.7458% |
| Bytes | 10% | Byte hit | 86.4019% | 87.2927% | 86.9753% | 86.6718% | 87.9561% |

Timing was recorded on 2026-07-28 using a 16-core Apple M4 Max, macOS 26.5.1,
Swift 6.3.3, and a release build. Values below are median nanoseconds per
request from three independent object-capacity replays:

| Footprint | LRU | SIEVE | SLRU-4 | W-TinyLFU | S3-FIFO |
|---:|---:|---:|---:|---:|---:|
| 0.1% | 61.67 | 41.98 | 111.71 | 225.45 | 61.98 |
| 1% | 68.82 | 36.16 | 121.32 | 194.19 | 52.86 |
| 10% | 87.51 | 35.76 | 156.43 | 187.66 | 58.98 |

These are in-process replay-loop measurements, not portable latency promises.
They are useful for comparisons produced by the same build and machine.
SIEVE was fastest at all three primary capacities; W-TinyLFU was slowest.

The canonical 1% W-TinyLFU window is strong at the 1% footprint, but it is not
uniformly superior on this trace. S3-FIFO wins all six primary points.
SIEVE improves on LRU at every point, and beats SLRU-4 at five of six points;
at the smallest object capacity it trails SLRU-4 by 0.1083 percentage points.
It does this without frequency sketches, ghost queues, or recency updates on
hits.
W-TinyLFU is also sensitive to its static window:

| W-TinyLFU window | 0.1% footprint | 1% footprint | 10% footprint |
|---:|---:|---:|---:|
| 1% (canonical run) | 61.3248% | 79.0188% | 86.0930% |
| 5% | 65.0633% | 79.8785% | 86.7128% |
| 10% | 66.3247% | 79.9776% | 86.9205% |
| 20% | 66.7270% | 79.9202% | 86.9842% |
| S3-FIFO baseline | 65.1517% | 79.5771% | 87.6366% |

This sweep is diagnostic, not a replacement for the canonical result: a larger
window helps the smaller Twitter capacities, while no tested static window
beats S3-FIFO at the 10% footprint. Adaptive window sizing remains separate
future work.

The CloudPhysics calibration trace shows a different shape. Five-segment SLRU
and W-TinyLFU both cross workload-specific hot-set boundaries:

| Byte capacity | LRU | SIEVE | SLRU-5 | W-TinyLFU | S3-FIFO |
|---:|---:|---:|---:|---:|---:|
| 128 MiB | 18.0009% | 19.4719% | 21.2941% | 20.8682% | 21.5725% |
| 256 MiB | 21.1545% | 23.8443% | 23.8399% | 27.8418% | 27.6495% |
| 512 MiB | 28.2335% | 32.6375% | 29.5674% | 34.7636% | 32.5638% |
| 640 MiB | 36.3373% | 38.5758% | 33.7958% | 33.7238% | 37.3858% |
| 768 MiB | 36.6798% | 41.8461% | 42.3519% | 40.9662% | 38.2263% |
| 1 GiB | 37.0311% | 43.4663% | 50.7667% | 52.1946% | 38.2157% |

These are object hit rates under byte capacity. The policy ranking and even
monotonicity are workload- and partition-sensitive; at 1 GiB W-TinyLFU leads,
while at 640 MiB SIEVE leads.

## Run

```sh
swift run -c release PolicyHitRateBenchmark
```

Choose capacity ratios, capacity semantics, or a different CSV:

```sh
swift run -c release PolicyHitRateBenchmark \
  --trace /path/to/trace.csv \
  --ratios 0.001,0.01,0.1 \
  --mode objects \
  --slru-segments 4 \
  --wtinylfu-window 0.01 \
  --wtinylfu-protected 0.80 \
  --timing-runs 3
```

The same executable can replay an uncompressed libCacheSim `oracleGeneral`
binary trace and accept exact capacities:

```sh
swift run -c release PolicyHitRateBenchmark \
  --trace /path/to/trace.oracleGeneral.bin \
  --capacities 134217728,268435456 \
  --mode bytes
```

The CSV reader expects the libCacheSim sample layout:

```text
# time, object, size, next_access_vtime
0, 13053225291711363978, 737, 13
```

[caffeine-policy]: https://github.com/ben-manes/caffeine/blob/master/simulator/src/main/java/com/github/benmanes/caffeine/cache/simulator/policy/sketch/WindowTinyLfuPolicy.java
[s3fifo-paper]: https://junchengyang.com/publication/sosp23-s3fifo.pdf
[sieve-paper]: https://www.usenix.org/conference/nsdi24/presentation/zhang-yazhuo
[tinylfu-paper]: https://arxiv.org/abs/1512.00727
