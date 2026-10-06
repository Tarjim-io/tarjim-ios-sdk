# Tarjim iOS SDK

Shows a project's released translations in an iOS app without an app update. The SDK downloads the release's
`.strings` and `.stringsdict` files, checks every file's hash, installs them atomically, and answers lookups — falling
back to the text the app was built with.

## Status

Pre-release (`0.x`). The API may still change before `1.0`.

## Requirements

- iOS 15 or later (iPadOS and Mac Catalyst with it). CI runs the tests on iOS 16.4 and 26.5 simulators; no hosted
  runner can obtain an iOS 15 simulator runtime, so iOS 15 is verified on a device before each release.
- Swift 6.0 or later toolchain (Xcode 16+), Swift 6 language mode.

## Installation

```swift
.package(url: "https://github.com/Tarjim-io/tarjim-ios-sdk", from: "0.1.0")
```

No version is tagged yet, so this line will not resolve until the first release.

## Setup

Call `start` once, early, on the main thread — in `application(_:didFinishLaunchingWithOptions:)` or your SwiftUI
`App`'s initialiser:

```swift
import Tarjim

Tarjim.start(TarjimConfiguration(
    projectId: 7,
    apiKey: "<a key bound to your track and stage>",
    host: URL(string: "https://api.example.com")!,
    defaultBundle: .custom("app"),
    fallbackLanguage: "en"
))
```

- `defaultBundle` is the Tarjim bundle a lookup reads when it names none. It is required so that adding a bundle to
  the release later never changes what an existing lookup means. A lookup can name a bundle by type and name:
  `.namespace("checkout")` or `.custom("home")`.
- `fallbackLanguage` is served, for the whole app, to a user whose language the release does not have — after the
  app's own text in the user's language. A key missing in the user's language never shows another language.
- The key is sent only in a header, only to `host`. Use a key bound to a track and stage, with read access only.

On the main thread, `start` serves the release already stored on the device before it returns, waiting at most about a
second for it; the network work happens in the background. Lookups made before the first download is installed
read the app's own text. Called off the main thread, `start` returns at once and everything happens in the background.

## Looking up text

Existing code keeps working: with the main-bundle proxy (on by default), `NSLocalizedString`, storyboards, xibs and
SwiftUI `Text("key")` in the default environment show downloaded text. Or ask directly:

```swift
Tarjim.string("checkout.title")
Tarjim.string("cart.items", 3)                        // formatted with the locale of the text found
Tarjim.string("pay.button", bundle: .namespace("checkout"))
```

The order is always: the downloaded text, the app's own text, the key. Each string is formatted with the locale it
was found in, so plurals and digits follow the text.

Text is shown as written. One difference to know: SwiftUI `Text("key")` reached through the proxy renders Markdown in the
text (`**bold**`), as Apple does for its own strings, while `Tarjim.string` returns the characters verbatim.

Not reached by the proxy — use `Tarjim.string` there: a view under an explicit `.environment(\.locale, …)`,
`String(localized:)` / `LocalizedStringResource`, `CFBundleCopyLocalizedString`, and SwiftUI interpolation of a
plural (`Text("cart.items \(n)")` looks up `cart.items %lld`). Set `interceptsMainBundle = false` to turn the proxy off.

## When updates appear

- The first download, or one for a language the user just switched to, is shown as soon as it is complete.
- A later update is shown at the next cold start, or when the user returns after more than an hour away — never under
  the user's hands. `await Tarjim.activatePendingUpdate()` shows it now (for example from the update event).
- An update that makes the app crash at launch twice in a row is reverted and not taken again while the server names
  it. Launches the system makes in the background never count.
- Checks run only while the app is active, at the cadence the server sets.

```swift
for await update in Tarjim.updates() {   // .downloaded, .activated — on a real change only
    if update == .activated { reloadVisibleText() }
}
```

A screen already on display is not redrawn by the SDK; refresh it from `.activated` if you need to.

## Choosing the language in the app

```swift
await Tarjim.setLanguage("ar")   // after start; remembered across launches
await Tarjim.setLanguage(nil)    // follow the app's language again
```

Only Tarjim text changes: layout direction, system text and number formats stay with the app's language. A language
the release does not have is ignored — and kept, so it applies once a release adds it. `Tarjim.locale` is the locale
text is served in.

## Reports

```swift
configuration.onReport = { report in log(report.message) }   // called once per condition, off the main thread
```

A report is sent once per condition until the condition is seen resolved: a release in a format this SDK version does
not know, a release with no iOS strings, a file failing its hash, a file unavailable for three checks in a row, a
rejected key, or a reverted update. Normal states — no change, offline, throttled, nothing released yet — are never
reported. Nothing is sent over the network; without a handler a line goes to the unified log at debug level.

## Privacy

The SDK ships a privacy manifest. It does not track. Update checks carry a `User-Agent` naming the SDK version, the
app version, the iOS version and the app's language, plus — unless `sendsInstallIdentifier = false` — a random
identifier the SDK creates per install (new on reinstall and when the key changes), so active installs can be
counted. Downloads from the CDN carry no header of the SDK's own; the system's default `User-Agent` still goes out. The
language in the `User-Agent` is the app's language, fixed when the SDK starts; it does not follow `setLanguage` or the
fallback language.

## Licence

MIT. See [LICENSE](LICENSE).
