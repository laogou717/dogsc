import SwiftUI

/// Owns only the sleep cover animation. Playback and Metal retirement stay
/// with their native owners; the completion releases a frozen drawable.
@MainActor
final class EditorCanvasSleepPresentation: ObservableObject {
    @Published private(set) var opacity: Double = 0
    private var animationRevision: UInt64 = 0
    private var isAnimating = false
    private var pendingCompletion: (() -> Void)?

    func setCovered(_ covered: Bool, reducesMotion: Bool, completion: @escaping () -> Void) {
        pendingCompletion = completion
        let target = covered ? 1.0 : 0.0
        guard target != opacity else {
            // A second loss of focus during the same fade replaces the native
            // completion, but must still wait for that fade to finish.
            if !isAnimating { finishPendingCompletion() }
            return
        }

        animationRevision &+= 1
        let revision = animationRevision
        isAnimating = true
        let animation: Animation? = reducesMotion ? nil : .easeInOut(duration: 0.26)
        withAnimation(animation, completionCriteria: .removed) {
            opacity = target
        } completion: { [weak self] in
            guard let self, self.animationRevision == revision else { return }
            self.isAnimating = false
            self.finishPendingCompletion()
        }
    }

    func invalidate() {
        animationRevision &+= 1
        pendingCompletion = nil
        isAnimating = false
    }

    private func finishPendingCompletion() {
        let completion = pendingCompletion
        pendingCompletion = nil
        completion?()
    }
}
