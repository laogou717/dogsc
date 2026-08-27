import AppKit
import RecorderCore
import SwiftUI

struct ZoomFocusMap: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let outputTime: TimeInterval
    let sourcePixelSize: CGSize
    @Binding var focus: NormalizedPoint
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var thumbnail: NSImage?
    @State private var isEditingFocus = false

    var body: some View {
        GeometryReader { geometry in
            let mapRect = focusMapRect(in: geometry.size)
            let guideInset = ZoomViewportTransform.compositionGuideInset

            ZStack {
                Color.black.opacity(0.5)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    Color.black.opacity(0.42)
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                        }
                }

                Color.black.opacity(0.08)

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.22),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    .frame(
                        width: mapRect.width * CGFloat(1 - guideInset * 2),
                        height: mapRect.height * CGFloat(1 - guideInset * 2)
                    )
                    .position(x: mapRect.midX, y: mapRect.midY)
                    .allowsHitTesting(false)

                Circle()
                    .fill(Color.black.opacity(0.2))
                    .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.5))
                    .overlay(Circle().stroke(editorAccent.opacity(0.9), lineWidth: 4).padding(4))
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.5), radius: 5, y: 2)
                    .position(
                        x: mapRect.minX + CGFloat(focus.x) * mapRect.width,
                        y: mapRect.minY + CGFloat(focus.y) * mapRect.height
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                beginFocusEditingIfNeeded()
                                focus = normalizedFocus(at: value.location, in: mapRect)
                            }
                            .onEnded { _ in endFocusEditing() }
                    )
                    .accessibilityLabel("缩放焦点")
                    .accessibilityValue(
                        "水平 \(Int(focus.x * 100))%，垂直 \(Int(focus.y * 100))%"
                    )
                    .accessibilityHint("拖动以选择缩放锚点，可以移动到四个角")
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginFocusEditingIfNeeded()
                        focus = normalizedFocus(at: value.location, in: mapRect)
                    }
                    .onEnded { _ in endFocusEditing() }
            )
        }
        .frame(height: 148)
        .task(id: thumbnailRequestID) {
            await loadThumbnail()
        }
    }

    private func focusMapRect(in size: CGSize) -> CGRect {
        let padded = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 12)
        let sourceAspect = max(sourcePixelSize.width / max(sourcePixelSize.height, 1), 0.01)
        let widthFromHeight = padded.height * sourceAspect
        if widthFromHeight <= padded.width {
            return CGRect(
                x: padded.midX - widthFromHeight / 2,
                y: padded.minY,
                width: widthFromHeight,
                height: padded.height
            )
        }
        let heightFromWidth = padded.width / sourceAspect
        return CGRect(
            x: padded.minX,
            y: padded.midY - heightFromWidth / 2,
            width: padded.width,
            height: heightFromWidth
        )
    }

    private func normalizedFocus(at point: CGPoint, in rect: CGRect) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(Double((point.x - rect.minX) / max(rect.width, 1)), 0), 1),
            y: min(max(Double((point.y - rect.minY) / max(rect.height, 1)), 0), 1)
        )
    }

    private func beginFocusEditingIfNeeded() {
        guard !isEditingFocus else { return }
        isEditingFocus = true
        onEditingChanged(true)
    }

    private func endFocusEditing() {
        guard isEditingFocus else { return }
        isEditingFocus = false
        onEditingChanged(false)
    }

    private var thumbnailRequestID: String {
        let generation = mediaSession.prepared?.generation.description ?? "none"
        return "\(generation)#\(String(format: "%.3f", outputTime))"
    }

    @MainActor
    private func loadThumbnail() async {
        guard let image = await mediaSession.thumbnail(atOutputTime: outputTime) else {
            thumbnail = nil
            return
        }
        thumbnail = NSImage(cgImage: image, size: .zero)
    }
}
