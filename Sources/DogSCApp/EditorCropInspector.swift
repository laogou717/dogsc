import RecorderCore
import SwiftUI

/// 裁切 inspector: a ratio lock, the four margins as two paired number rows,
/// the resulting size, and 还原. Every edit writes the crop draft; the parent
/// interaction commits or cancels it as a whole.
struct EditorCropInspector: View {
    @Binding var cropDraft: NormalizedCrop
    let sourcePixelSize: CGSize
    /// nil when the session has nothing to narrow to: a recording that
    /// appears once is its own clip, so offering a choice would be noise.
    var scope: Scope? = nil
    @ObservedObject private var lock = EditorCropAspectLock.shared
    @ObservedObject private var cropScope = EditorCropScope.shared
    @State private var editOrigin: NormalizedCrop?

    /// What the panel needs to name and move the session's scope. The owner
    /// supplies the clip's label; the scope itself lives in `EditorCropScope`.
    struct Scope {
        let segmentLabel: String
        let onChange: (Bool) -> Void
    }

    enum Choice: Hashable, CaseIterable {
        case recording
        case segment

        var title: String { self == .recording ? "整份录制" : "仅这一段" }
        var help: String {
            self == .recording
                ? "这份录制的每一处都用同一个裁切"
                : "只有这一段用这个裁切，其余仍跟随整份录制"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let scope {
                EditorInspectorSection("范围") {
                    EditorSegmentedControl(
                        options: Choice.allCases,
                        title: { $0.title },
                        optionHelp: { $0.help },
                        selection: Binding(
                            get: { cropScope.isSegmentOnly ? .segment : .recording },
                            set: { scope.onChange($0 == .segment) }
                        )
                    )
                    .accessibilityIdentifier("editor.crop.scope")
                    Text(cropScope.isSegmentOnly
                        ? String(format: appLocalized("仅 %@ 使用此裁切，其余片段跟随整份录制。"), scope.segmentLabel)
                        : appLocalized("整份录制的每一处都使用此裁切。"))
                        .font(.appUI(size: 11))
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            EditorInspectorSection("比例") {
                EditorSegmentedControl(
                    options: EditorCropAspect.allCases,
                    title: { $0.title },
                    optionHelp: { $0.help },
                    selection: Binding(
                        get: { lock.aspect },
                        set: { applyAspect($0) }
                    )
                )
                .accessibilityIdentifier("editor.crop.aspect")
            }

            EditorInspectorSection("边距") {
                marginRow("水平", first: ("左", .left), second: ("右", .right), pixels: sourcePixelSize.width)
                marginRow("垂直", first: ("上", .top), second: ("下", .bottom), pixels: sourcePixelSize.height)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: EditorPropertyRowMetrics.gap) {
                    Text(appLocalized("裁切后尺寸"))
                        .foregroundStyle(EditorTheme.tertiaryText)
                    Spacer(minLength: 0)
                    Text(EditorCropGeometry.pixelSizeText(cropDraft, source: sourcePixelSize))
                        .font(.appUI(size: 12, design: .monospaced))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .contentTransition(.numericText())
                }
                .font(.appUI(size: 12))
                .frame(height: 22)
                .accessibilityElement(children: .combine)

                Button {
                    withAnimation(SpringMotion.standard) {
                        lock.aspect = .free
                        cropDraft = .full
                    }
                } label: {
                    HStack(spacing: 6) {
                        AppLineIcon(kind: .refresh, size: 13)
                        Text(appLocalized("还原"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorQuiet)
                .disabled(cropDraft.clamped() == .full)
                .help(appLocalized("还原为完整画面"))
                .accessibilityIdentifier("editor.crop.reset")

                Text(appLocalized("在画面上拖动边缘或四角，拖动框内可整体移动。"))
                    .font(.appUI(size: 11))
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
        .onAppear { lock.resolveInitialMatch(cropDraft, source: sourcePixelSize) }
    }

    private func applyAspect(_ aspect: EditorCropAspect) {
        lock.aspect = aspect
        guard let ratio = aspect.normalizedRatio(source: sourcePixelSize) else { return }
        withAnimation(SpringMotion.standard) {
            cropDraft = EditorCropGeometry.fitted(ratio: ratio, around: cropDraft.clamped())
        }
    }

    // MARK: Margins

    private func marginRow(
        _ title: String,
        first: (title: String, edge: CropEdge),
        second: (title: String, edge: CropEdge),
        pixels: CGFloat
    ) -> some View {
        HStack(spacing: EditorPropertyRowMetrics.gap) {
            Text(appLocalized(title))
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: EditorPropertyRowMetrics.labelWidth, alignment: .leading)
            EditorPairedParameterReadouts(
                first: marginValue(first.title, edge: first.edge, pixels: pixels),
                second: marginValue(second.title, edge: second.edge, pixels: pixels),
                onChanged: { a, b in
                    setMargins(first.edge, Int(a.rounded()), second.edge, Int(b.rounded()), pixels: pixels)
                },
                onEnded: { editOrigin = nil },
                onCancelled: {
                    if let editOrigin { cropDraft = editOrigin }
                    editOrigin = nil
                },
                onEditingChanged: { editing in
                    if editing { editOrigin = cropDraft.clamped() }
                }
            )
        }
        .frame(height: EditorPropertyRowMetrics.height)
    }

    private func marginValue(_ title: String, edge: CropEdge, pixels: CGFloat) -> EditorPairedParameterValue {
        let value = Double(pixelValue(edge, pixels: pixels))
        return EditorPairedParameterValue(
            title: title,
            accessibilityTitle: "\(title)侧裁切",
            value: value,
            range: 0...Double(max(maximumPixelValue(edge, pixels: pixels), 0)),
            displayText: "\(Int(value))",
            inputFormat: .points
        )
    }

    private func setMargins(_ a: CropEdge, _ aValue: Int, _ b: CropEdge, _ bValue: Int, pixels: CGFloat) {
        // Typed margins are exact; a ratio lock would fight them.
        if lock.aspect != .free { lock.aspect = .free }
        let dimension = max(Double(pixels), 1)
        let minimum = min(max(24 / dimension, 0.001), 0.5)
        let current = cropDraft.clamped()
        var edges: [CropEdge: Double] = [
            .left: current.left, .right: current.right,
            .top: current.top, .bottom: current.bottom,
        ]
        let opposite: [CropEdge: CropEdge] = [.left: .right, .right: .left, .top: .bottom, .bottom: .top]
        for (edge, raw) in [(a, aValue), (b, bValue)] {
            let normalized = min(max(Double(raw) / dimension, 0), 1)
            let other = edges[opposite[edge]!] ?? 0
            edges[edge] = min(normalized, max(1 - other - minimum, 0))
        }
        cropDraft = .fromEdges(
            left: edges[.left] ?? 0, right: edges[.right] ?? 0,
            top: edges[.top] ?? 0, bottom: edges[.bottom] ?? 0
        )
    }

    private func pixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let crop = cropDraft.clamped()
        let value: Double = switch edge {
        case .left: crop.left
        case .right: crop.right
        case .top: crop.top
        case .bottom: crop.bottom
        }
        return max(Int((value * Double(max(pixels, 1))).rounded()), 0)
    }

    private func maximumPixelValue(_ edge: CropEdge, pixels: CGFloat) -> Int {
        let dimension = max(Double(pixels), 1)
        let crop = cropDraft.clamped()
        let opposite: Double = switch edge {
        case .left: crop.right
        case .right: crop.left
        case .top: crop.bottom
        case .bottom: crop.top
        }
        let minimum = min(max(24 / dimension, 0.001), 0.5)
        return max(Int(floor((1 - opposite - minimum) * dimension)), 0)
    }
}
