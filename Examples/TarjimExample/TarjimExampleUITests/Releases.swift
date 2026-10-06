/// The releases the stub serves. The texts differ from the app's own (`… from the app`) so a test can tell which
/// source answered.
extension StubRelease {
    static let first = StubRelease(releaseId: 1, files: [
        .strings(namespace: "app", locale: "en", ["greeting": "Hello from Tarjim"]),
        .strings(namespace: "app", locale: "ar", ["greeting": "مرحبا من ترجم"]),
        .plural(namespace: "app", locale: "en", key: "items.count", one: "%d item from Tarjim", other: "%d items from Tarjim"),
        .strings(namespace: "Main", locale: "en", ["tjm-lb-l01.text": "Storyboard from Tarjim"]),
        .strings(namespace: "Main", locale: "ar", ["tjm-lb-l01.text": "القصة من ترجم"]),
    ])

    static let second = StubRelease(releaseId: 2, files: [
        .strings(namespace: "app", locale: "en", ["greeting": "Hello again from Tarjim"]),
        .strings(namespace: "app", locale: "ar", ["greeting": "مرحبا مجددا من ترجم"]),
        .plural(namespace: "app", locale: "en", key: "items.count", one: "%d item from Tarjim", other: "%d items from Tarjim"),
        .strings(namespace: "Main", locale: "en", ["tjm-lb-l01.text": "Storyboard from Tarjim"]),
        .strings(namespace: "Main", locale: "ar", ["tjm-lb-l01.text": "القصة من ترجم"]),
    ])
}
