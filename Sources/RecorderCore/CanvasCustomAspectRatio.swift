import Foundation

public struct CanvasCustomAspectRatio: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double = 16, height: Double = 9) {
        self.width = width
        self.height = height
    }

    public var value: Double {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 16 / 9 }
        return min(max(width / height, 0.1), 10)
    }
}

public extension CanvasStyle {
    var resolvedFixedAspectRatio: Double? {
        switch aspectRatio {
        case .adaptive: nil
        case .landscape: 16 / 9
        case .portrait: 9 / 16
        case .standard: 4 / 3
        case .standardPortrait: 3 / 4
        case .cinema: 2.39
        case .cinemaPortrait: 1 / 2.39
        case .square: 1
        case .custom: customAspectRatio.value
        }
    }
}
