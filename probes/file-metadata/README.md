# file metadata probe

This standalone Swift package is Latte 0.1.0's filesystem evidence probe. It
does not import or modify the Latte product target.

The recorded validation matrix and findings are in [results.md](results.md).

It verifies the Foundation and filesystem behavior required by the implemented
directory-truth `LRUFileCache` model:

- atomic move metadata;
- `replaceItemAt` with `.usingNewMetadataOnly`;
- creation date replacement for overwrite TTL;
- modification date updates for persisted TTI;
- final-URL allocated and logical size;
- ordinary-file classification.

Run the macOS probe:

```sh
swift test --package-path probes/file-metadata
```

Use the package's shared test scheme with `xcodebuild` to execute the same
probe in available Apple Simulator runtimes. Every test owns a unique temporary
directory, so the suite does not rely on execution order or shared files.

```sh
cd probes/file-metadata
xcodebuild test \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme FileMetadataProbe \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Pure Swift package tests are tool-hosted and cannot execute on an iOS device.
The minimal `ios-host` project supplies only the required application host and
compiles the same test source used by `swift test`:

```sh
xcodebuild test \
  -project probes/file-metadata/ios-host/host.xcodeproj \
  -scheme FileMetadataProbeHost \
  -destination 'platform=iOS,name=YOUR_DEVICE_NAME' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

The gate passes only when metadata is read again from the final URL after
publish. Temporary-file metadata is evidence for preflight only and is never
treated as the final resident state. Foundation resource values are cached, so
the probe reconstructs the URL from its path and clears cached resource values
before every metadata read.
