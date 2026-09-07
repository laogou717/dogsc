import AppKit
import CoreText
import SwiftUI

/// The bundled, unmodified font is registered once, only for this process.
/// Missing resources fall back to the system face. Timeline timecodes retain
/// system monospaced metrics; this never changes text authored into a movie.
enum AppTypography {
    private static let registered: Bool = {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Fonts") else { return false }
        var success = true
        for weight in ["55-Regular", "65-Medium", "75-SemiBold"] {
            let url = root.appendingPathComponent("AlibabaPuHuiTi-3-\(weight).otf")
            guard FileManager.default.fileExists(atPath: url.path) else { success = false; continue }
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
            if NSFont(name: "AlibabaPuHuiTi_3_\(weight.replacingOccurrences(of: "-", with: "_"))", size: 13) == nil { success = false }
        }
        return success
    }()

    static func font(size: CGFloat, weight: Font.Weight, design: Font.Design) -> Font {
        guard design != .monospaced, registered else {
            return .system(size: size, weight: weight, design: design)
        }
        let face: String
        switch weight {
        case .semibold, .bold, .heavy, .black: face = "75_SemiBold"
        case .medium: face = "65_Medium"
        default: face = "55_Regular"
        }
        return .custom("AlibabaPuHuiTi_3_\(face)", fixedSize: size)
    }
}

extension Font {
    static func appUI(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        AppTypography.font(size: size, weight: weight, design: design)
    }

    static func appUI(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 26
        case .title: size = 22
        case .title2: size = 18
        case .title3: size = 16
        case .headline, .body: size = 13
        case .subheadline, .callout: size = 12
        case .footnote, .caption: size = 11
        case .caption2: size = 10
        @unknown default: size = 13
        }
        return appUI(size: size, weight: weight ?? (style == .headline ? .semibold : .regular))
    }
}
