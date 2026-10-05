# Tarjim iOS SDK

Downloads a project's released translation files, verifies them, installs them atomically and answers
string lookups in an iOS app.

## Status

Pre-release. The public API is not usable yet.

## Requirements

- iOS 15 or later. CI runs the tests on iOS 16.4 and 26.5 simulators; no hosted runner can obtain an
  iOS 15 simulator runtime, so iOS 15 is verified on a device before each release.
- Swift 6.0 or later toolchain (Xcode 16+), Swift 6 language mode

## Installation

```swift
.package(url: "https://github.com/Tarjim-io/tarjim-ios-sdk", from: "0.1.0")
```

No version is tagged yet, so this line will not resolve until the first release.

## Licence

MIT. See [LICENSE](LICENSE).
