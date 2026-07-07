import Foundation
import AnglesiteCore

/// Thin, `Identifiable` model driving the dependency-update-offer sheet
/// (spec §5). Holds the already-computed offers and forwards the user's
/// decision — no comparison/diff logic lives here, that's all in
/// `AnglesiteCore` (`DependencySyncChecker`/`DependencySyncApplier`).
@MainActor
final class DependencyUpdateModel: Identifiable {
    nonisolated let id = UUID()
    let offers: [DependencyUpdateOffer]
    private let onDecision: (_ accepted: Bool) -> Void

    init(offers: [DependencyUpdateOffer], onDecision: @escaping (_ accepted: Bool) -> Void) {
        self.offers = offers
        self.onDecision = onDecision
    }

    func update() { onDecision(true) }
    func skip() { onDecision(false) }
}
