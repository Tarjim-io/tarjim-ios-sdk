import SwiftUI
import Tarjim

struct ContentView: View {
    @State private var status = "none"
    /// Bumped to render again: text that is already on screen does not change by itself.
    @State private var generation = 0

    var body: some View {
        VStack(spacing: 16) {
            // A string literal here is a LocalizedStringKey, so it is read through the main bundle.
            Text("greeting").accessibilityIdentifier("proxied")
            Text(Tarjim.string("greeting")).accessibilityIdentifier("explicit")
            StoryboardLabel().frame(height: 40)
            Text(Tarjim.string("items.count", 3)).accessibilityIdentifier("formatted")
            Text(status).accessibilityIdentifier("status")
            Button("Activate update") {
                Task {
                    _ = await Tarjim.activatePendingUpdate()
                }
            }
            .accessibilityIdentifier("activate")
            Button("Arabic") { choose("ar") }.accessibilityIdentifier("lang-ar")
            Button("System language") { choose(nil) }.accessibilityIdentifier("lang-system")
        }
        .id(generation)
        .padding()
        .task {
            // `Tarjim.start` works in the background and sends no event for the install that is already active, so
            // the first frame can show the app's own text. One later render picks up what the launch installed.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            generation += 1
        }
        .task {
            for await update in Tarjim.updates() {
                switch update {
                case .downloaded: status = "downloaded"
                case .activated:
                    status = "activated"
                    generation += 1
                }
            }
        }
    }

    private func choose(_ language: String?) {
        Task {
            await Tarjim.setLanguage(language)
            generation += 1
        }
    }
}
