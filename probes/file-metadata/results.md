# file metadata probe results

> Date: 2026-07-29
>
> Xcode: 26.6 (17F113)
>
> Swift: 6.3.3
>
> macOS host: 26.5.1 (25F80)

## conclusion

The directory-truth persistence model is accepted for `LRUFileCache` 0.1.0 on
the evidence currently available:

- atomic move preserves candidate metadata;
- replacement with `.usingNewMetadataOnly` publishes the candidate payload and
  metadata at the final URL;
- replacement changes the old creation date, so overwrite can reset the TTL
  written date;
- modification date touch persists, so it can represent cross-launch TTI;
- allocated size is readable for regular files, with logical size available as
  the fallback;
- directories are not reported as regular files.

No critical filesystem assumption failed. The primary iOS physical-device gate
is complete. tvOS and visionOS runtime evidence remain deferred. SDK
compilation or source type-checking is not reported as runtime validation.

## validation matrix

| Target | Validation | Result |
|---|---|---|
| macOS 26.5.1 APFS | Debug runtime, 6 tests | Pass |
| macOS 26.5.1 APFS | Release runtime, 6 tests | Pass |
| iOS 26.5 Simulator, iPhone 17 Pro | Runtime, 6 tests | Pass |
| iOS 26.5.2, iPhone 15 Pro | Physical-device runtime, 6 tests | Pass |
| watchOS 26.5 Simulator, Series 11 46 mm | Runtime, 6 tests | Pass |
| Mac Catalyst | Runtime, 6 tests | Pass |
| iOS device SDK | Swift package build | Pass |
| watchOS device SDK | Swift package build | Pass |
| tvOS 26.5 SDK | Swift 6 source type-check | Pass |
| visionOS 26.5 SDK | Swift 6 source type-check | Pass |
| tvOS runtime / Xcode package integration | Full platform component unavailable | Not run |
| visionOS runtime / Xcode package integration | Full platform component unavailable | Not run |

The installed Xcode exposes the tvOS and visionOS SDKs, so direct Swift 6
type-checks are possible. Xcode reports the full tvOS 26.5 and visionOS 26.5
platform components as not installed; those targets therefore cannot currently
be selected as Swift package destinations.

## observed metadata

The probe intentionally uses payload sizes that cross filesystem allocation
blocks:

| Operation | Logical bytes | Allocated bytes |
|---|---:|---:|
| Atomic-move candidate | 8,193 | 12,288 |
| Replacement destination before publish | 4,097 | 8,192 |
| Replacement candidate and final resident | 12,289 | 16,384 |

Across the runtime targets:

- the final replacement payload matched the candidate;
- final creation and modification dates matched the candidate dates;
- the final creation date differed from the old resident date;
- touch changed the persisted modification date;
- the directory reported `isRegularFile == false`.

Allocated size remains an observation rather than a strict quota. The product
implementation must read the final resident URL after publish and use
`fileSize` only when `totalFileAllocatedSize` is unavailable.

## resource-value cache finding

The first macOS run exposed stale `contentModificationDate` when the same URL
value was reused after touch. The filesystem had updated, but Foundation
returned cached resource values.

The final probe therefore reconstructs a URL from the path and calls
`removeAllCachedResourceValues()` before every metadata read. `LRUFileCache`
must preserve this rule for post-publish reads, TTI touches, reconciliation,
and initialization inventory.

## commands

```sh
swift test --package-path probes/file-metadata
swift test --package-path probes/file-metadata -c release
```

Simulator and Catalyst runs use the shared workspace:

```sh
cd probes/file-metadata
xcodebuild test \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme FileMetadataProbe \
  -destination '<available destination>'
```

iOS physical-device execution uses the minimal application host required by
Xcode for device test bundles:

```sh
xcodebuild test \
  -project probes/file-metadata/ios-host/host.xcodeproj \
  -scheme FileMetadataProbeHost \
  -destination 'platform=iOS,name=YOUR_DEVICE_NAME' \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID
```
