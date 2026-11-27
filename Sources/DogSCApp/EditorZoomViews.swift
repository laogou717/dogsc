import AppKit
import RecorderCore
import SwiftUI

struct ZoomFocusMap: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let outputTime: TimeInterval
    let sourcePixelSize: CGSize
    var overlay: VideoClip? = nil
    @Binding var focus: NormalizedPoint
    var allowsEditing = true
    var refreshesDuringPlayback = false
    var isPlaying = false
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onEditingCancelled: () -> Void = { }
    var onTextPreviewValidityChanged: (Bool) -> Void = { _ in }

    @State private var thumbnail: NSImage?
    @State private var isEditingFocus = false
    @State private var isCoordinateEditing = false
    @State private var isMapHovered = false

    var body: some View {
        TimelineView(.animation(
            minimumInterval: 1.0 / 30.0,
            paused: !refreshesDuringPlayback || !isPlaying
                || isCoordinateEditing || isEditingFocus
        )) { _ in
            let displayedFocus = focus
            VStack(alignment: .leading, spacing: 9) {
                focusSurface(displayedFocus)

                HStack(spacing: 8) {
                    if allowsEditing {
                        EditorPairedParameterReadouts(
                            first: EditorPairedParameterValue(
                                title: "X",
                                accessibilityTitle: "缩放焦点 X 坐标",
                                value: clamp01(displayedFocus.x),
                                range: 0...1,
                                displayText: EditorSliderValueFormat.percent.text(for: clamp01(displayedFocus.x)),
                                inputFormat: .percent
                            ),
                            second: EditorPairedParameterValue(
                                title: "Y",
                                accessibilityTitle: "缩放焦点 Y 坐标",
                                value: clamp01(displayedFocus.y),
                                range: 0...1,
                                displayText: EditorSliderValueFormat.percent.text(for: clamp01(displayedFocus.y)),
                                inputFormat: .percent
                            ),
                            onChanged: { x, y in
                                beginFocusEditingIfNeeded()
                                focus = NormalizedPoint(x: x, y: y)
                            },
                            onEnded: endFocusEditing,
                            onCancelled: cancelFocusEditing,
                            onEditingChanged: { isCoordinateEditing = $0 },
                            onTextPreviewValidityChanged: onTextPreviewValidityChanged
                        )
                        Button {
                            beginFocusEditingIfNeeded()
                            focus = NormalizedPoint(x: 0.5, y: 0.5)
                            endFocusEditing()
                        } label: {
                            EditorSymbol("scope", size: 18)
                                .font(.appUI(size: 13))
                                .frame(width: 32, height: 30)
                        }
                        .buttonStyle(EditorSoftRaisedButtonStyle())
                        .appButtonKeyboardFocus(in: RoundedRectangle(cornerRadius: EditorInterfaceRadius.compact, style: .continuous))
                        .disabled(isCentered(displayedFocus))
                        .help("焦点居中")
                        .accessibilityLabel("居中缩放焦点")
                    }
                }
            }
        }
        .task(id: thumbnailRequestID) {
            await loadThumbnail()
        }
        .onDisappear {
            if isEditingFocus {
                cancelFocusEditing()
            }
        }
    }

    private func focusSurface(_ displayedFocus: NormalizedPoint) -> some View {
        GeometryReader { geometry in
            let mapRect = focusMapRect(in: geometry.size)
            let guideInset = ZoomViewportTransform.compositionGuideInset
            let point = CGPoint(
                x: mapRect.minX + CGFloat(clamp01(displayedFocus.x)) * mapRect.width,
                y: mapRect.minY + CGFloat(clamp01(displayedFocus.y)) * mapRect.height
            )
            let isActive = isEditingFocus || isCoordinateEditing

            ZStack {
                EditorTheme.chrome(0.04)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(EditorTheme.chrome(0.035))
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)

                    ProgressView()
                        .controlSize(.small)
                        .position(x: mapRect.midX, y: mapRect.midY)
                }

                Color.clear

                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(
                        Color.white.opacity(0.65),
                        style: StrokeStyle(lineWidth: 0.75, dash: [4, 4])
                    )
                    .frame(
                        width: mapRect.width * CGFloat(1 - guideInset * 2),
                        height: mapRect.height * CGFloat(1 - guideInset * 2)
                    )
                    .position(x: mapRect.midX, y: mapRect.midY)
                    .allowsHitTesting(false)

                if isActive {
                    Path { path in
                        path.move(to: CGPoint(x: point.x, y: mapRect.minY))
                        path.addLine(to: CGPoint(x: point.x, y: mapRect.maxY))
                        path.move(to: CGPoint(x: mapRect.minX, y: point.y))
                        path.addLine(to: CGPoint(x: mapRect.maxX, y: point.y))
                    }
                    .stroke(
                        EditorTheme.selectionTint.opacity(0.7),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                    )
                    .allowsHitTesting(false)
                }

                if allowsEditing {
                // The editor's one position puck: paper disc, ink pip.
                ZStack {
                    Circle()
                        .fill(.white)
                        .overlay { Circle().strokeBorder(.black.opacity(0.08), lineWidth: 0.5) }
                        .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
                        .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                        .frame(width: 22, height: 22)
                    Circle()
                        .fill(Color(white: 0.12))
                        .frame(width: 8, height: 8)
                }
                .scaleEffect(isActive && !RecorderMotion.reduces ? 1.1 : 1)
                .animation(SpringMotion.snappy, value: isActive)
                .position(point)
                .transaction { $0.animation = nil }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        EditorTheme.selectionTint.opacity(isActive ? 0.8 : isMapHovered ? 0.35 : 0),
                        lineWidth: 0.5
                    )
                    .animation(SpringMotion.hover, value: isMapHovered)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginFocusEditingIfNeeded()
                        focus = normalizedFocus(at: value.location, in: mapRect)
                    }
                    .onEnded { _ in endFocusEditing() }
            )
            .allowsHitTesting(allowsEditing && !isCoordinateEditing)
            .onHover { hovering in
                withAnimation(SpringMotion.interactive) {
                    isMapHovered = hovering
                }
            }
            .accessibilityHidden(true)
        }
        .frame(height: min(max(312 / max(sourcePixelSize.width / max(sourcePixelSize.height, 0.000_001), 0.5), 150), 200))
        .accessibilityIdentifier("zoom.focus-map")
    }

    private func focusMapRect(in size: CGSize) -> CGRect {
        let padded = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
        let sourceAspect = max(sourcePixelSize.width / max(sourcePixelSize.height, 0.000_001), 0.01)
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

    private func cancelFocusEditing() {
        guard isEditingFocus else { return }
        isEditingFocus = false
        onEditingCancelled()
    }

    private func isCentered(_ displayedFocus: NormalizedPoint) -> Bool {
        abs(displayedFocus.x - 0.5) < 0.000_5
            && abs(displayedFocus.y - 0.5) < 0.000_5
    }

    private func clamp01(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0.5, 0), 1)
    }

    private var thumbnailRequestID: String {
        let generation = mediaSession.prepared?.generation.description ?? "none"
        if let overlay {
            let sourceTime = FrameVideoScene(clip: overlay, at: outputTime).sourceTime
            return "\(generation)#\(overlay.id)#\(overlay.sourcePath)#\(sourceTime)"
        }
        return "\(generation)#\(String(format: "%.3f", outputTime))"
    }

    @MainActor
    private func loadThumbnail() async {
        thumbnail = nil
        let image = await mediaSession.thumbnail(atOutputTime: outputTime, overlay: overlay)
        guard !Task.isCancelled else { return }
        thumbnail = image.map { NSImage(cgImage: $0, size: .zero) }
    }
}
