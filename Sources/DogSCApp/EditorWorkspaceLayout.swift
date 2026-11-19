import Foundation
import SwiftUI

/// Window-local chrome sizing. A 1080p display can need compact controls even
/// when its editor is maximized. Use the hosting screen's available points as
/// well as window space; a large desktop keeps its established layout.
/// Backing pixels and recording/export sizes never enter this calculation.
struct EditorWorkspaceLayout: Equatable {
    static let minimumWindowSize = CGSize(width: 840, height: 600)
    let size: CGSize
    var screenSize: CGSize? = nil

    var compression: CGFloat {
        let windowPressure = max((1440 - size.width) / 360, (820 - size.height) / 220)
        let screenPressure = screenSize.map {
            max((2048 - $0.width) / 640, (1200 - $0.height) / 260)
        } ?? 0
        return min(max(max(windowPressure, screenPressure), 0), 1)
    }

    var isCompact: Bool { compression > 0 }
    var outerInset: CGFloat { value(regular: 16, compact: 10) }
    var timelineGap: CGFloat { value(regular: 12, compact: 8) }
    var compactTimelineControls: Bool { isCompact && size.width < 1320 }
    var iconOnlyTimelineControls: Bool { isCompact && size.width < 1120 }

    func value(regular: CGFloat, compact: CGFloat) -> CGFloat {
        regular + (compact - regular) * compression
    }

    func timelineHeight(preferred: CGFloat?, availableHeight: CGFloat) -> CGFloat {
        let surrounding = timelineGap + outerInset
        let budget = max(availableHeight - value(regular: 320, compact: 260) - surrounding, 170)
        // Compact tracks must not displace the whole monitor/inspector when
        // several lanes are visible. The existing desktop budget is untouched.
        let compactBudget = max(min(budget, availableHeight * 0.44), 170)
        return min((preferred ?? value(regular: 300, compact: 228)).rounded(.up),
                   value(regular: budget, compact: compactBudget))
    }
}
