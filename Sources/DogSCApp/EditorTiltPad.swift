import SwiftUI

/// The four everyday screen-3D poses (屏幕 3D · 姿态). The inspector's preset
/// tiles and the canvas float bar both offer exactly these.
enum EditorScreenTiltPreset: CaseIterable, Identifiable {
    case leanLeft, leanRight, topDown, front

    var id: Self { self }

    var title: String {
        switch self {
        case .leanLeft: "左倾"
        case .leanRight: "右倾"
        case .topDown: "俯视"
        case .front: "正面"
        }
    }

    var rotationX: Double {
        switch self {
        case .leanLeft: 0
        case .leanRight: 6
        case .topDown: 22
        case .front: 0
        }
    }

    var rotationY: Double {
        switch self {
        case .leanLeft: 16
        case .leanRight: -14
        case .topDown: 0
        case .front: 0
        }
    }

    /// The small card inside the preset tile, tilted the way the pose leans.
    var thumbnailAxis: (x: CGFloat, y: CGFloat, angle: Double) {
        switch self {
        case .leanLeft: (0, 1, 18)
        case .leanRight: (0, 1, -18)
        case .topDown: (1, 0, 30)
        case .front: (0, 1, 0)
        }
    }

    /// The preset the current pose matches (within half a degree), if any.
    static func matching(rotationX: Double, rotationY: Double) -> Self? {
        allCases.first { abs($0.rotationX - rotationX) < 0.5 && abs($0.rotationY - rotationY) < 0.5 }
    }
}

/// Direct 3D orientation control for the screen-motion target (屏幕 3D ·
/// 姿态): a 132-high well holding a card in perspective — drag anywhere to
/// tilt it — four pose presets under it, then exact X / Y / Z angles.
struct EditorTiltPad: View {
    @State private var dragOrigin: (x: Double, y: Double)?
    @State private var activeAxis: Axis?
    @State private var hasPreview = false
    @State private var hoveredPreset: EditorScreenTiltPreset?

    let rotationX: Double
    let rotationY: Double
    let onChanged: (Double, Double) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void
    var onTextPreviewValidityChanged: (Bool) -> Void = { _ in }
    /// Z (in-plane) rotation; the third box appears when it is supplied.
    var rotationZ: Double? = nil
    var onZChanged: ((Double) -> Void)? = nil

    static let maximumX = 28.0
    static let maximumY = 32.0
    static let maximumZ = 30.0
    /// Degrees of tilt per point of pointer travel.
    static let dragGain = 0.3

    private enum Axis: Hashable { case x, y, z }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poseWell
            presets
            rotationRow
        }
    }

    // MARK: Pose well

    private var poseWell: some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(EditorTheme.chrome(0.045))
            GeometryReader { proxy in
                let width = proxy.size.width * 0.46
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.624, green: 0.702, blue: 0.773), Color(red: 0.875, green: 0.902, blue: 0.925)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4), lineWidth: 1)
                    }
                    .frame(width: width, height: width * 10 / 16)
                    .shadow(color: .black.opacity(0.18), radius: 12, y: 10)
                    .rotation3DEffect(.degrees(clamped(rotationX, Self.maximumX)), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                    .rotation3DEffect(.degrees(clamped(rotationY, Self.maximumY)), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .rotationEffect(.degrees(rotationZ ?? 0))
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    .transaction { $0.animation = nil }
            }
            .allowsHitTesting(false)
            Text(appLocalized("拖动倾斜"))
                .font(.appUI(size: 11))
                .foregroundStyle(EditorTheme.tertiaryText)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = dragOrigin ?? (rotationX, rotationY)
                    if dragOrigin == nil { dragOrigin = origin }
                    let x = clamped(origin.x - Double(value.translation.height) * Self.dragGain, Self.maximumX)
                    let y = clamped(origin.y + Double(value.translation.width) * Self.dragGain, Self.maximumY)
                    onChanged(x, y)
                }
                .onEnded { _ in
                    guard dragOrigin != nil else { return }
                    dragOrigin = nil
                    onEnded()
                }
        )
        .editorCursor(dragOrigin == nil ? .openHand : .closedHand)
        .accessibilityElement()
        .accessibilityLabel(appLocalized("3D 姿态"))
        .accessibilityHint(appLocalized("拖动倾斜"))
        .accessibilityIdentifier("screen-motion.tilt-pad")
    }

    // MARK: Presets

    private var presets: some View {
        let current = EditorScreenTiltPreset.matching(rotationX: rotationX, rotationY: rotationY)
        return HStack(spacing: 6) {
            ForEach(EditorScreenTiltPreset.allCases) { preset in
                presetTile(preset, isSelected: current == preset)
            }
        }
    }

    private func presetTile(_ preset: EditorScreenTiltPreset, isSelected: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let axis = preset.thumbnailAxis
        return Button {
            withAnimation(SpringMotion.standard) {
                onChanged(preset.rotationX, preset.rotationY)
                onEnded()
            }
        } label: {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(EditorConsole.Track.screenMotion.fill.opacity(0.55))
                .frame(width: 24, height: 15)
                .rotation3DEffect(.degrees(axis.angle), axis: (x: axis.x, y: axis.y, z: 0), perspective: 0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(shape.fill(EditorTheme.chrome(hoveredPreset == preset ? 0.08 : 0.045)))
                // The chosen pose: a 1.5-pt accent ring standing 2 pt off the tile.
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(EditorTheme.accent, lineWidth: 1.5)
                            .padding(-3.5)
                    }
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { hoveredPreset = preset } else if hoveredPreset == preset { hoveredPreset = nil }
        }
        .animation(SpringMotion.micro, value: hoveredPreset)
        .help(appLocalized(preset.title))
        .accessibilityLabel(appLocalized(preset.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Exact angles

    private var rotationRow: some View {
        HStack(spacing: EditorPropertyRowMetrics.gap) {
            Text(appLocalized("旋转"))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .lineLimit(1)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            HStack(spacing: 6) {
                angleField("X", accessibility: "3D 倾斜 X 角度", axis: .x, value: rotationX, limit: Self.maximumX)
                angleField("Y", accessibility: "3D 倾斜 Y 角度", axis: .y, value: rotationY, limit: Self.maximumY)
                if let rotationZ, onZChanged != nil {
                    angleField("Z", accessibility: "平面旋转角度", axis: .z, value: rotationZ, limit: Self.maximumZ)
                }
            }
        }
        .frame(minHeight: EditorPropertyRowMetrics.height)
    }

    private func angleField(_ title: String, accessibility: String, axis: Axis, value: Double, limit: Double) -> some View {
        let format = EditorSliderValueFormat.degrees
        return EditorScrubField(
            title: title,
            accessibilityTitle: accessibility,
            displayText: "\(Int(value.rounded()))°",
            editingText: format.editingText(for: value),
            value: clamped(value, limit),
            range: -limit...limit,
            isActive: activeAxis == axis,
            onBegin: { activeAxis = axis; hasPreview = false },
            onScrub: { apply($0, axis: axis) },
            onPreviewText: { text in
                guard let parsed = format.value(from: text) else {
                    onTextPreviewValidityChanged(false)
                    return false
                }
                onTextPreviewValidityChanged(true)
                apply(clamped(parsed, limit), axis: axis)
                return true
            },
            onFinish: { commits in
                guard activeAxis == axis else { return }
                activeAxis = nil
                if hasPreview { commits ? onEnded() : onCancelled() }
                hasPreview = false
            }
        )
    }

    private func apply(_ value: Double, axis: Axis) {
        hasPreview = true
        switch axis {
        case .x: onChanged(value, rotationY)
        case .y: onChanged(rotationX, value)
        case .z: onZChanged?(value)
        }
    }

    private func clamped(_ value: Double, _ limit: Double) -> Double {
        min(max(value.isFinite ? value : 0, -limit), limit)
    }
}
