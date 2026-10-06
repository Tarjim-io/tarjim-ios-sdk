import SwiftUI
import Tarjim

/// Holds the update stream from before `Tarjim.start`, so an event sent before the first view appears is not lost.
@MainActor
final class UpdateModel: ObservableObject {
    @Published private(set) var status = "none"
    /// Bumped to render again: text that is already on screen does not change by itself.
    @Published private(set) var generation = 0

    private var listening: Task<Void, Never>?

    init() {
        let updates = Tarjim.updates()
        listening = Task { [weak self] in
            for await update in updates {
                switch update {
                case .downloaded: self?.status = "downloaded"
                case .activated:
                    self?.status = "activated"
                    self?.generation += 1
                }
            }
        }
    }

    deinit { listening?.cancel() }

    func render() { generation += 1 }
}
