# file cache

## contract

`LRUFileCache<Key>` is a persistent `AsyncCaching<Key, Data>` implementation.
Every public operation returns only after its corresponding file I/O and state
convergence finish.

Construction requires:

- a dedicated directory owned by one cache instance in one process;
- a valid instance-wide configuration;
- a `@Sendable (Key) throws -> Data` encoder that produces deterministic key
  material across launches.

Latte hashes the key material with SHA-256 and never persists the original key.
Encoder failures propagate before file I/O. The encoder can run concurrently in
multiple calling tasks and must not depend on unsynchronized mutable state.

The cache is conditionally `Sendable` when `Key` is `Sendable`.

## directory format

The directory is flat:

```text
<cache directory>/
├── .latte-cache
├── <64-character lowercase sha-256 resident>
└── .latte-tmp-<identifier>
```

`.latte-cache` records the cache family and format version. It proves directory
ownership but is not a manifest or a runtime lock.

Initialization and `removeAll` classify the complete directory before deleting
anything:

- the marker and residents must be regular files;
- canonical SHA-256 names are residents;
- `.latte-tmp-*` names are Latte staging artifacts;
- unknown names, duplicate names, and nonregular items fail closed.

Unknown items are never deleted by Latte.

## state

One serial worker owns:

- the validated directory;
- resident URL and file metadata;
- LRU order;
- observed disk usage;
- availability after consistency failures.

The directory and final file metadata are persistence truth. There is no
manifest, journal, or checkpoint. Startup reconstructs in-memory state from the
directory.

## capacity

`maximumDiskUsage` is an observed soft limit, not a filesystem quota.

- Cost uses `totalFileAllocatedSize` when available and falls back to
  `fileSize`.
- The default high watermark is `0.95`.
- The default low watermark is `0.90`.
- Trimming begins only when observed usage is strictly above the high
  watermark and continues until it is at or below the low watermark.
- Expired residents are removed before LRU victims.
- The current candidate is protected only during its own insertion.
- A candidate larger than the high limit is normally rejected.
- A candidate between the low and high limits can remain as the only resident.

Temporary allocation created by atomic publication is part of filesystem
behavior and can temporarily exceed the observed cache limit.

## expiration

TTL and TTI apply uniformly to the cache instance.

- TTL is measured from the latest successful write.
- TTI is measured from the latest successful read or write.
- Expiration occurs when either configured limit is reached.
- Cleanup is opportunistic during startup, lookup, and insertion.
- No timer, application lifecycle hook, or background sweep is created.

Creation date persists the written time. Modification date persists the last
access time. In-process access is tracked exactly; modification-date writes can
be throttled with `accessTimeUpdateInterval`.

With a nonzero update interval, in-process TTI and recency remain exact, while
the persisted modification date can lag by at most one interval. After a
process restart, TTI can therefore expire up to one interval early and restored
LRU order can be up to one interval stale. The default `.zero` interval
persists every successful access and preserves exact cross-launch semantics.

A touch failure does not turn a successful read into an error. The cache
returns the data, updates in-memory recency, and retries persistence on a later
eligible hit.

## startup

Initialization:

1. validates configuration;
2. creates or opens the directory;
3. publishes or validates the ownership marker;
4. classifies the complete inventory;
5. removes known interrupted staging artifacts;
6. reads final resident metadata;
7. repairs residents that disappeared during scanning;
8. removes expired residents;
9. rebuilds LRU order and observed usage;
10. trims to the low watermark when required.

The initializer returns only after the cache is ready. An invalid marker,
unknown item, nonregular item, or unrecoverable accounting gap causes
initialization to fail without deleting unowned data.

## lookup

Lookup:

1. encodes and hashes the key in the calling task;
2. submits the filename to the serial worker;
3. returns `nil` when the resident is absent or expired;
4. reads data from the resident file;
5. repairs state and returns `nil` if the file disappeared;
6. refreshes in-memory access time and LRU;
7. persists modification time when the touch interval allows it.

A real data-read failure is thrown.

## insertion

Insertion:

1. encodes and hashes the key;
2. rejects immediate-expiration, zero-capacity, or obviously oversized
   candidates;
3. writes a unique staging file in the cache directory;
4. validates staging metadata;
5. atomically moves or replaces the final resident;
6. rereads metadata from the final URL;
7. records the resident only after final metadata is valid;
8. removes expired residents and then trims LRU victims.

An overwrite publication failure preserves the old resident. If publication
succeeds but final metadata cannot be established, the cache removes the
unaccountable file and reconciles the complete directory.

A successfully published cache write is not a database transaction. A later
trim failure is thrown, but already completed file changes are not rolled back.
In-memory state must continue to reflect successful filesystem operations.

## removal

`removeValue` succeeds when the resident is absent. If the file disappeared, it
repairs state and succeeds. Other deletion failures are thrown while the
resident metadata remains available for retry.

`removeAll`:

- revalidates the complete inventory;
- removes all residents and Latte staging artifacts;
- preserves the marker and directory;
- forgets files already missing from disk;
- keeps metadata for resident deletions that failed;
- throws the first deletion error after completing other safe cleanup.

Marker, inventory, or staging-cleanup failures make the instance unavailable
because disk usage can no longer be represented safely.

## failure model

| condition | result |
|---|---|
| key encoder failure | throw before I/O |
| absent, evicted, expired, or externally removed resident | `nil` |
| normal capacity rejection | successful return |
| staging write or publication failure | throw; preserve old resident |
| staging cleanup failure | throw; instance unavailable |
| final metadata failure with successful reconciliation | throw original error; instance remains usable |
| reconciliation failure | throw; instance unavailable |
| expiration deletion failure | `nil`; retain metadata for retry |
| touch failure after a successful read | return data; retry later |
| explicit resident deletion failure | throw; retain resident metadata |
| invalid marker or inventory during `removeAll` | zero deletion; instance unavailable |
| task cancelled before queueing | `CancellationError`; no I/O starts |

Once file I/O or publication starts, cancellation does not interrupt the
operation halfway through state convergence.

## filesystem evidence

The persistence model depends on final-URL metadata behavior verified by the
standalone probe:

- atomic move preserves candidate metadata;
- replacement publishes candidate payload and metadata;
- replacement resets creation date for overwrite TTL;
- modification-date touch persists TTI state;
- allocated size is available with logical-size fallback;
- regular-file classification is reliable on validated targets.

See [file metadata results](../probes/file-metadata/results.md) for the recorded
platform matrix. Runtime evidence unavailable in the current development
environment is reported as deferred rather than inferred from SDK compilation.

## non-goals

The implementation does not provide strict quota enforcement, per-entry
expiration, background cleanup, directory sharing, file locking, encryption,
compression, serialization, or observability.
