import Foundation

struct EditorPlaybackTimelineSnapshot: Equatable {
    let outputTime: TimeInterval
    let duration: TimeInterval
    let isPlaying: Bool
    var allowsViewportReveal = true
}

@MainActor
protocol EditorPlaybackTimelineObserver: AnyObject {
    func editorPlaybackTimelineDidUpdate(_ snapshot: EditorPlaybackTimelineSnapshot)
}

@MainActor
final class EditorPlaybackTimelineObserverHub {
    private final class WeakBox {
        weak var value: (any EditorPlaybackTimelineObserver)?

        init(_ value: any EditorPlaybackTimelineObserver) {
            self.value = value
        }
    }

    private var observers: [WeakBox] = []

    func add(
        _ observer: any EditorPlaybackTimelineObserver,
        current snapshot: EditorPlaybackTimelineSnapshot
    ) {
        remove(observer)
        observers.append(WeakBox(observer))
        observer.editorPlaybackTimelineDidUpdate(snapshot)
    }

    func remove(_ observer: any EditorPlaybackTimelineObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    func publish(_ snapshot: EditorPlaybackTimelineSnapshot) {
        var containsExpiredObserver = false
        for box in observers {
            if let observer = box.value {
                observer.editorPlaybackTimelineDidUpdate(snapshot)
            } else {
                containsExpiredObserver = true
            }
        }
        if containsExpiredObserver {
            observers.removeAll { $0.value == nil }
        }
    }
}
