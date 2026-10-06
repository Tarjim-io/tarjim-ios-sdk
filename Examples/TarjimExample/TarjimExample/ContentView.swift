import SwiftUI
import Tarjim

struct ContentView: View {
    @ObservedObject var model: UpdateModel

    var body: some View {
        VStack(spacing: 16) {
            // A string literal here is a LocalizedStringKey, so it is read through the main bundle.
            Text("greeting").accessibilityIdentifier("proxied")
            Text(Tarjim.string("greeting")).accessibilityIdentifier("explicit")
            StoryboardLabel().frame(height: 40)
            Text(Tarjim.string("items.count", 3)).accessibilityIdentifier("formatted")
            Text(model.status).accessibilityIdentifier("status")
            Button("Activate update") {
                Task {
                    _ = await Tarjim.activatePendingUpdate()
                }
            }
            .accessibilityIdentifier("activate")
            Button("Arabic") { choose("ar") }.accessibilityIdentifier("lang-ar")
            Button("System language") { choose(nil) }.accessibilityIdentifier("lang-system")
        }
        .id(model.generation)
        .padding()
    }

    private func choose(_ language: String?) {
        Task {
            await Tarjim.setLanguage(language)
            model.render()
        }
    }
}
