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

}
