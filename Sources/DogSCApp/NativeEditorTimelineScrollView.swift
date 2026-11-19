import AppKit
import SwiftUI

/// AppKit owns the horizontal viewport and document geometry. Scrolling never
/// enters SwiftUI ScrollView's synchronous commit/layout feedback path.
struct NativeEditorTimelineScrollView<Content: View>: NSViewRepresentable {
    let playbackController: EditorPlaybackController
    let documentWidth: CGFloat
    let documentHeight: CGFloat
    let onResolve: (NSScrollView?) -> Void
    let content: Content

    @MainActor
    final class Coordinator: NSObject, EditorPlaybackTimelineObserver {
        weak var resolvedScrollView: NSScrollView?
        weak var playbackController: EditorPlaybackController?
        private var previousIsPlaying: Bool?

        func configure(playbackController: EditorPlaybackController) {
            guard self.playbackController !== playbackController else { return }
            self.playbackController?.removeNativeTimelineObserver(self)
            previousIsPlaying = nil
            self.playbackController = playbackController
            playbackController.addNativeTimelineObserver(self)
        }

        func resolve(_ scrollView: NSScrollView?) {
            resolvedScrollView = scrollView
        }

        func invalidate() {
            playbackController?.removeNativeTimelineObserver(self)
            playbackController = nil
            resolvedScrollView = nil
            previousIsPlaying = nil
        }

        func editorPlaybackTimelineDidUpdate(
            _ snapshot: EditorPlaybackTimelineSnapshot
        ) {
            let previous = previousIsPlaying
            previousIsPlaying = snapshot.isPlaying
            // Initial attachment and ordinary clock ticks never move the
            // viewport. Only a real play/pause transition may reveal it.
            guard let previous, previous != snapshot.isPlaying,
                  snapshot.allowsViewportReveal,
                  let playbackController else { return }
            // Pause publishes its state before the final sampled time. Wait
            // until that synchronous operation finishes, then use the actual
            // stopped position rather than the preceding display refresh.
            DispatchQueue.main.async { [weak self, weak playbackController] in
                guard let self, let playbackController,
                      self.playbackController === playbackController else { return }
                self.revealPlayheadIfOutsideViewport(
                    outputTime: playbackController.outputTime,
                    duration: playbackController.duration
                )
            }
        }

        private func revealPlayheadIfOutsideViewport(
            outputTime: TimeInterval,
            duration: TimeInterval
        ) {
            guard let scrollView = resolvedScrollView,
                  outputTime.isFinite,
                  duration.isFinite,
                  duration > 0 else { return }
            let clipView = scrollView.contentView
            let viewportWidth = max(clipView.bounds.width, 1)
            let documentWidth = max(
                scrollView.documentView?.bounds.width ?? viewportWidth,
                viewportWidth
            )
            let progress = min(max(outputTime / duration, 0), 1)
            let playheadX = documentWidth * CGFloat(progress)
            guard playheadX < clipView.bounds.minX ||
                  playheadX > clipView.bounds.maxX else { return }
            let maximumOffset = max(documentWidth - viewportWidth, 0)
            let targetOffset = min(
                max(playheadX - viewportWidth / 2, 0),
                maximumOffset
            )
            guard abs(clipView.bounds.origin.x - targetOffset) > 0.5 else { return }
            clipView.scroll(
                to: NSPoint(x: targetOffset, y: clipView.bounds.origin.y)
            )
            scrollView.reflectScrolledClipView(clipView)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.scrollerInsets = NSEdgeInsets()
        let document = NSHostingView(rootView: NativeTimelineHostedContent(content: content, environment: context.environment))
        document.sizingOptions = []
        document.frame = CGRect(x: 0, y: 0, width: max(documentWidth, 1), height: max(documentHeight, 1))
        scroll.documentView = document
        context.coordinator.configure(playbackController: playbackController)
        context.coordinator.resolve(scroll)
        DispatchQueue.main.async { [weak scroll] in onResolve(scroll) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.configure(playbackController: playbackController)
        guard let document = scroll.documentView as? NSHostingView<NativeTimelineHostedContent<Content>> else { return }
        document.rootView = NativeTimelineHostedContent(content: content, environment: context.environment)
        let size = CGSize(width: max(documentWidth, 1), height: max(documentHeight, 1))
        if document.frame.size != size { document.setFrameSize(size) }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.invalidate()
        scroll.documentView = nil
    }
}

private struct NativeTimelineHostedContent<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}
