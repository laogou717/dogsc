import Foundation

/// One canonical 24-bit sRGB color value shared by project persistence,
/// preview scene evaluation and export rendering.
public struct HexColor: Hashable, Sendable, Codable {
    public struct Components: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    public let rgb24: UInt32

    /// Creates a color from a programmer-authored 24-bit RGB literal.
    public init(rgb24: UInt32) {
        precondition(rgb24 <= 0xFF_FF_FF, "HexColor requires a 24-bit RGB value")
        self.rgb24 = rgb24
    }

    /// Strictly accepts `RRGGBB` or `#RRGGBB`, with surrounding whitespace.
    public init?(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.first == "#" ? String(trimmed.dropFirst()) : trimmed
        let bytes = Array(digits.utf8)
        guard bytes.count == 6,
              bytes.allSatisfy(Self.isASCIIHexDigit),
              let value = UInt32(digits, radix: 16) else { return nil }
        rgb24 = value
    }

    public var components: Components {
        Components(
            red: Double((rgb24 >> 16) & 0xFF) / 255,
            green: Double((rgb24 >> 8) & 0xFF) / 255,
            blue: Double(rgb24 & 0xFF) / 255
        )
    }

    /// The sole persisted and display representation.
    public var hexString: String {
        String(format: "#%06X", rgb24)
    }

    public static let white = HexColor(rgb24: 0xFF_FF_FF)
    public static let black = HexColor(rgb24: 0x00_00_00)
    public static let defaultBackground = HexColor(rgb24: 0x2D_33_42)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let source = try container.decode(String.self)
        guard let color = HexColor(source) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected #RRGGBB or RRGGBB sRGB color"
            )
        }
        self = color
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 48...57, 65...70, 97...102:
            return true
        default:
            return false
        }
    }
}
