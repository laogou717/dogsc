import AppKit
import RecorderCore
import SwiftUI

struct ZoomFocusMap: View {
    @ObservedObject var mediaSession: EditorMediaSession
    let outputTime: TimeInterval
    let sourcePixelSize: CGSize
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
                            Image(systemName: "scope")
                                .font(.appUI(size: 14))
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
                EditorTheme.chrome(0.025)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(width: mapRect.width, height: mapRect.height)
                        .position(x: mapRect.midX, y: mapRect.midY)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
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
                        EditorTheme.platinumAccent.opacity(0.30),
                        style: StrokeStyle(lineWidth: 0.75, dash: [2.5, 3.5])
                    )
                    .allowsHitTesting(false)
                }

                if allowsEditing {
                Image(systemName: "plus")
                    .font(.appUI(size: 24, weight: .ultraLight))
                    .foregroundStyle(EditorTheme.selectionTint)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.9), in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                .position(point)
                .transaction { $0.animation = nil }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(
                        isActive
                            ? EditorTheme.platinumAccent.opacity(0.28)
                            : EditorTheme.chrome(isMapHovered ? 0.18 : 0.11),
                        lineWidth: isActive ? 1 : 0.75
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
        .frame(height: min(max(312 / max(sourcePixelSize.width / max(sourcePixelSize.height, 1), 0.5), 150), 200))
        .accessibilityIdentifier("zoom.focus-map")
    }

    private func focusMapRect(in size: CGSize) -> CGRect {
        let padded = CGRect(origin: .zero, size: size).insetBy(dx: 8, dy: 8)
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
