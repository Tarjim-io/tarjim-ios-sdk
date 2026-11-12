import SwiftUI
import Tarjim

@main
struct TarjimExampleApp: App {
    @StateObject private var model: UpdateModel

    init() {
        // Before any view exists, so the first lookup already goes through Tarjim.
        Self.resetStoreIfAsked()
        // Built here, not in the autoclosure `StateObject` runs later, so its stream is open before `start` activates
        // anything.
        let model = UpdateModel()
        _model = StateObject(wrappedValue: model)
        let environment = ProcessInfo.processInfo.environment
        let placeholder = URL(string: "https://tarjim.invalid/t/0/projects/0/delivery/meta")!
        // A pasted value often carries a trailing newline, which `URL(string:)` would percent-encode into the path.
        let deliveryURL = environment["TARJIM_EXAMPLE_DELIVERY_URL"]
            .flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? placeholder
        Tarjim.start(TarjimConfiguration(
            deliveryURL: deliveryURL,
            apiKey: environment["TARJIM_EXAMPLE_API_KEY"] ?? "YOUR_API_KEY",
            defaultBundle: .namespace("app"),
            fallbackLanguage: "en"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }

    /// The UI tests start every run from a clean install; the SDK keeps its store in Application Support.
    private static func resetStoreIfAsked() {
        guard CommandLine.arguments.contains("-TarjimExampleReset"),
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: false)
        else { return }
        try? FileManager.default.removeItem(at: support)
    }
}
