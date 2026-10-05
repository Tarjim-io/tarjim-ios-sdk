# Releasing

A release is a bare semantic-version tag (`0.2.0`) on `main`; tags are protected. Before tagging:

1. CI is green on `main`: Swift 6.0, the latest Xcode, and the iOS 16.4 and 26.5 simulators.
2. On a physical device running iOS 15 (no hosted runner has an iOS 15 simulator), with a test app:
   - the package tests pass when run from Xcode on the device;
   - first launch downloads and shows text; a second release shows at the next cold start;
   - `NSLocalizedString`, a storyboard label and SwiftUI `Text("key")` show downloaded text;
   - an Arabic plural and a regional selection (`ar-EG` then `ar`) format with the text's locale;
   - the script check of the locale selector (for example `zh-Hant` text is not served in a `zh-Hans` app).
3. The privacy manifest still matches what the SDK sends (see the README's Privacy section).
4. The README describes every public API change since the last tag.
5. Tag: `git tag 0.x.y && git push origin 0.x.y`; then publish release notes on GitHub listing the changes.
