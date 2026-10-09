import Foundation

public enum CanvasPaddingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case uniform
    case axes
    case independent

    public var id: Self { self }
}

/// Authored margins use the final canvas short edge as their common unit.
/// The mode controls editing linkage; geometry always reads the four edges.
public struct CanvasPadding: Codable, Equatable, Sendable {
    public static let referenceShortEdge: Double = 1080
    public static let maximumFraction: Double = 0.42

    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double
    public private(set) var mode: CanvasPaddingMode

    public init(uniform value: Double = 100) {
        self.init(top: value, right: value, bottom: value, left: value, mode: .uniform)
    }

    public init(top: Double, right: Double, bottom: Double, left: Double,
                mode: CanvasPaddingMode = .independent) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
        self.mode = mode
    }

    public var average: Double { (top + right + bottom + left) / 4 }

    public mutating func setMode(_ newMode: CanvasPaddingMode) {
        guard mode != newMode else { return }
        switch newMode {
        case .uniform:
            self = Self(uniform: average)
        case .axes:
            let vertical = (top + bottom) / 2
            let horizontal = (left + right) / 2
            top = vertical
            bottom = vertical
            left = horizontal
            right = horizontal
        case .independent:
            break
        }
        mode = newMode
    }

    public mutating func setValue(_ value: Double, for edge: WritableKeyPath<Self, Double>) {
        switch mode {
        case .uniform:
            self = Self(uniform: value)
        case .axes:
            if edge == \Self.top || edge == \Self.bottom {
                top = value
                bottom = value
            } else {
                left = value
                right = value
            }
        case .independent:
            self[keyPath: edge] = value
        }
    }

    public func scaled(by scale: Double, maximum: Double) -> Self {
        func resolve(_ value: Double) -> Double { min(max(value * scale, 0), maximum) }
        return Self(top: resolve(top), right: resolve(right), bottom: resolve(bottom),
                    left: resolve(left), mode: mode)
    }
}
