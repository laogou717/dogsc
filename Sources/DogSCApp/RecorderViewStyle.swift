import AppKit
import AVKit
import Combine
import QuartzCore
import RecorderCore
import SwiftUI

extension Color {
    init(hex: HexColor) {
        let components = hex.components
        self.init(
            red: components.red,
            green: components.green,
            blue: components.blue
        )
    }

    var hexColor: HexColor {
        guard let color = NSColor(self).usingColorSpace(.sRGB) else { return .white }
        let red = UInt32((min(max(color.redComponent, 0), 1) * 255).rounded())
        let green = UInt32((min(max(color.greenComponent, 0), 1) * 255).rounded())
        let blue = UInt32((min(max(color.blueComponent, 0), 1) * 255).rounded())
        return HexColor(
            rgb24: red << 16 | green << 8 | blue
        )
    }
}
