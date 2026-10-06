import SwiftUI

/// Hosts the storyboard scene. A label reads its localized text once, when it loads, so the caller gives this view a
/// new `.id` to have the scene instantiated again.
struct StoryboardLabel: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIStoryboard(name: "Main", bundle: .main).instantiateViewController(withIdentifier: "Label")
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}
