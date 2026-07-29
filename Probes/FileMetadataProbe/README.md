# FileMetadataProbe

This standalone Swift package is Latte's Stage 0 evidence probe. It does not
import or modify the Latte product target.

The recorded validation matrix and findings are in [RESULTS.md](RESULTS.md).

It verifies the Foundation and filesystem behavior required by the proposed
directory-truth `LRUFileCache` model:

- atomic move metadata;
- `replaceItemAt` with `.usingNewMetadataOnly`;
- creation date replacement for overwrite TTL;
- modification date updates for persisted TTI;
- final-URL allocated and logical size;
- ordinary-file classification.

Run the macOS probe:

```sh
swift test --package-path Probes/FileMetadataProbe
```

Use the package's shared test scheme with `xcodebuild` to execute the same
probe in available Apple Simulator runtimes. Every test owns a unique temporary
directory, so the suite does not rely on execution order or shared files.

```sh
cd Probes/FileMetadataProbe
xcodebuild test \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme FileMetadataProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The gate passes only when metadata is read again from the final URL after
publish. Temporary-file metadata is evidence for preflight only and is never
treated as the final resident state. Foundation resource values are cached, so
the probe reconstructs the URL from its path and clears cached resource values
before every metadata read.
