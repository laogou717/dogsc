import SwiftUI

/// A bounded set of real source frames. Ripple movement changes placement,
/// not the identity of the media shown inside each following clip.
struct EditorTimelineFilmstrip: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let sourceStart: TimeInterval
    let sourceDuration: TimeInterval
    let isEnabled: Bool
    @Environment(\.editorIsActive) private var isEditorActive
    @State private var loadedRequestID: String?
    @State private var frames: [CGImage] = []

    private var requestID: String {
        "\(mediaSession.prepared?.generation ?? 0):\(sourceStart):\(sourceDuration)"
    }

    var body: some View {
        GeometryReader { geometry in
            if !frames.isEmpty {
                filmstrip(size: geometry.size)
            } else {
                EditorTheme.panelRaised
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: "\(requestID):\(isEditorActive):\(isEnabled)") {
            guard isEnabled, isEditorActive, loadedRequestID != requestID else { return }
            // A quick reversal cancels before any decoder work is started.
            // Existing pictures stay mounted and return immediately.
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard mediaSession.prepared != nil, sourceDuration > 0 else { return }
            let count = min(4, max(1, Int(ceil(sourceDuration / 3))))
            var decoded: [CGImage] = []
            for index in 0..<count {
                guard !Task.isCancelled else { return }
                let time = sourceStart + sourceDuration * (Double(index) + 0.5) / Double(count)
                if let frame = await mediaSession.filmstripThumbnail(atSourceTime: time) {
                    guard !Task.isCancelled else { return }
                    decoded.append(frame)
                }
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            withTransaction(Transaction(animation: nil)) {
                frames = decoded
                loadedRequestID = requestID
            }
        }
    }

    private func filmstrip(size: CGSize) -> some View {
        HStack(spacing: 0) {
            ForEach(frames.indices, id: \.self) { index in
                Image(decorative: frames[index], scale: 1)
                    .resizable().scaledToFill()
                    .frame(width: size.width / CGFloat(frames.count), height: size.height)
                    .clipped()
            }
        }
    }
}
