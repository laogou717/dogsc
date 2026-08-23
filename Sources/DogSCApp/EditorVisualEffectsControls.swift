import RecorderCore
import SwiftUI

/// Typed creative-frame entry. Keeping this feature outside the inspector
/// shell prevents the router from becoming the implementation owner again.
struct EditorScreenFramePicker: View {
    @ObservedObject var editorStore: EditorStore
    let onError: (String) -> Void

    var body: some View {
        Picker(
            "创意边框",
            selection: editorCanvasBinding(
                store: editorStore,
                keyPath: \.screenFrame,
                actionName: "更换屏幕边框",
                onError: onError
            )
        ) {
            ForEach(ScreenFrameStyle.allCases) { style in
                Text(style.editorDisplayName).tag(style)
            }
        }
        .pickerStyle(.menu)
        .help("边框会和屏幕、光标一起缩放并进行 3D 变形")
    }
}

/// Transform motion blur is a shared render-plan feature, not a view-only
/// effect. Temporal samples reuse the decoded media frame and blur authored
/// camera/screen/cursor motion; they do not claim media-internal optical blur.
struct EditorFrameMotionBlurControls: View {
    @ObservedObject var editorStore: EditorStore
    let onError: (String) -> Void

    var body: some View {
        EditorDisclosure("运镜动态模糊") {
            VStack(alignment: .leading, spacing: 11) {
                EditorToggle(
                    isOn: motionBinding(
                        \.frameMotionBlur.isEnabled,
                        actionName: "切换运动模糊"
                    ),
                    title: "启用运镜模糊"
                )
                if editorStore.project.motion.frameMotionBlur.isEnabled {
                    EditorTransactionalSliderRow(
                        editorStore: editorStore,
                        title: "快门角度",
                        value: motionBinding(
                            \.frameMotionBlur.shutterAngle,
                            actionName: "调整运动模糊快门"
                        ),
                        range: 0...360,
                        commandScope: .motion,
                        format: .degrees,
                        onError: onError
                    )
                    Picker(
                        "采样数",
                        selection: motionBinding(
                            \.frameMotionBlur.sampleCount,
                            actionName: "调整运动模糊采样"
                        )
                    ) {
                        ForEach([4, 8, 12, 16, 24, 32], id: \.self) { count in
                            Text("\(count) 次").tag(count)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Text("作用于缩放、平移、3D、光标和摄像头图层运动；预览与导出共用采样，采样越高导出越慢。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func motionBinding<Value>(
        _ keyPath: WritableKeyPath<MotionStyle, Value>,
        actionName: String
    ) -> Binding<Value> {
        editorMotionBinding(
            store: editorStore,
            keyPath: keyPath,
            actionName: actionName,
            onError: onError
        )
    }
}

private extension ScreenFrameStyle {
    var editorDisplayName: String {
        switch self {
        case .none: "无"
        case .windowLight: "macOS 窗口·浅色"
        case .windowDark: "macOS 窗口·深色"
        case .browserLight: "浏览器·浅色"
        case .browserDark: "浏览器·深色"
        }
    }
}
