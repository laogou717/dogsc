import RecorderCore

extension ElementMotionCurve {
    var editorTitle: String {
        switch self {
        case .smooth: "顺滑"
        case .swift: "利落"
        case .gentle: "柔和"
        }
    }

    var editorSymbol: String {
        switch self {
        case .smooth: "waveform.path"
        case .swift: "bolt.fill"
        case .gentle: "wind"
        }
    }

    var editorDetail: String {
        switch self {
        case .smooth: "均衡加减速，适合大多数元素。"
        case .swift: "快速进入并干净收尾，节奏更明确。"
        case .gentle: "起落更慢，适合较大的画面和样机。"
        }
    }
}
