import Foundation

/// AppKit runs a nested event-tracking loop during native scrolling and
/// dragging. A main-queue block can wait until that loop exits; render-slot
/// completion must keep running there so playback cannot exhaust its slots.
enum EditorMainRunLoop {
    nonisolated static func perform(_ action: @escaping @MainActor @Sendable () -> Void) {
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { action() }
        }
    }
}
