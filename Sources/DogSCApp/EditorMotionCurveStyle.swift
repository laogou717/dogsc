import RecorderCore

extension ElementMotionCurve {
    var editorTitle: String {
        switch self {
        case .smooth: return "顺滑"
        case .swift: return "利落"
        case .gentle: return "柔和"
        }
    }

    var editorSymbol: String {
        switch self {
        case .smooth: return "waveform.path"
        case .swift: return "bolt.fill"
        case .gentle: return "wind"
        }
    }

    var editorDetail: String {
        switch self {
        case .smooth: return "均衡加减速，适合大多数元素。"
        case .swift: return "快速进入并干净收尾，节奏更明确。"
        case .gentle: return "起落更慢，适合较大的画面和样机。"
        }
    }
}
