import SwiftUI
import Tarjim

@main
struct TarjimExampleApp: App {
    init() {
        // Before any view exists, so the first lookup already goes through Tarjim.
        Self.resetStoreIfAsked()
        let environment = ProcessInfo.processInfo.environment
        Tarjim.start(TarjimConfiguration(
            projectId: Int(environment["TARJIM_EXAMPLE_PROJECT_ID"] ?? "") ?? 0,
            apiKey: environment["TARJIM_EXAMPLE_API_KEY"] ?? "YOUR_API_KEY",
            host: URL(string: environment["TARJIM_EXAMPLE_HOST"] ?? "https://tarjim.invalid")!,
            defaultBundle: .namespace("app"),
            fallbackLanguage: "en"))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
