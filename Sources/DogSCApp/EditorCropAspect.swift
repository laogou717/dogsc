import Foundation
import RecorderCore
import SwiftUI

/// Aspect constraint for the crop draft. It is tool state, not document
/// state: the committed crop is still a plain `NormalizedCrop`, so a locked
/// ratio never leaks into the project or undo history.
enum EditorCropAspect: Hashable, CaseIterable, Sendable {
    case free
    case original
    case widescreen
    case vertical
    case square
    case classic

    var title: String {
        switch self {
        case .free: "自由"
        case .original: "原始"
        case .widescreen: "16:9"
        case .vertical: "9:16"
        case .square: "1:1"
        case .classic: "4:3"
        }
    }

    var help: String {
        switch self {
        case .free: "自由裁切"
        case .original: "原始比例"
        default: title
        }
    }

    /// Width ÷ height in pixels, or nil when free.
    func pixelRatio(source: CGSize) -> Double? {
        switch self {
        case .free: nil
        case .original: Double(max(source.width, 1) / max(source.height, 1))
        case .widescreen: 16.0 / 9.0
        case .vertical: 9.0 / 16.0
        case .square: 1
        case .classic: 4.0 / 3.0
        }
    }

    /// The ratio in normalized crop space (width ÷ height of a
    /// `NormalizedCrop` whose pixels have `pixelRatio`).
    func normalizedRatio(source: CGSize) -> Double? {
        pixelRatio(source: source).map {
            $0 * Double(max(source.height, 1)) / Double(max(source.width, 1))
        }
    }

    /// The preset an existing crop already matches, so reopening a 16:9
    /// crop shows 16:9 instead of 自由. A full-frame crop reads as free.
    static func matching(_ crop: NormalizedCrop, source: CGSize) -> EditorCropAspect {
        let crop = crop.clamped()
        guard crop != .full, source.width > 0, source.height > 0 else { return .free }
        let ratio = crop.width * Double(source.width) / max(crop.height * Double(source.height), 1)
        return [.widescreen, .vertical, .square, .classic, .original].first { option in
            guard let target = option.pixelRatio(source: source) else { return false }
            return abs(ratio / target - 1) < 0.004
        } ?? .free
    }
}

/// Shared between the canvas handles and the inspector's ratio control.
@MainActor
final class EditorCropAspectLock: ObservableObject {
    static let shared = EditorCropAspectLock()
    @Published var aspect: EditorCropAspect = .free
    /// Set when a crop session starts; the inspector, which knows the
    /// source size, resolves it once to the preset the crop already matches.
    private(set) var needsInitialMatch = false

    func beginSession() {
        aspect = .free
        needsInitialMatch = true
    }

    func resolveInitialMatch(_ crop: NormalizedCrop, source: CGSize) {
        guard needsInitialMatch, source.width > 0, source.height > 0 else { return }
        needsInitialMatch = false
        aspect = EditorCropAspect.matching(crop, source: source)
    }
}

/// Who the running crop session is framing: the recording — the default, and
/// every occurrence of it — or the one clip it opened on. Like the ratio lock
/// this is tool state; the document stores only crops, on the recording or on
/// that clip, so there is nothing session-shaped to undo.
@MainActor
final class EditorCropScope: ObservableObject {
    static let shared = EditorCropScope()

    /// The occurrence 仅这一段 would write to, nil outside a session.
    private(set) var segmentID: UUID?
    /// How often the session's recording appears on the main track. With one
    /// occurrence the two scopes are the same thing, so the choice is hidden.
    private(set) var occurrences = 1
    @Published private(set) var isSegmentOnly = false

    var offersChoice: Bool { segmentID != nil && occurrences > 1 }

    func begin(segmentID: UUID?, occurrences: Int, isSegmentOnly: Bool) {
        self.segmentID = segmentID
        self.occurrences = max(occurrences, 1)
        self.isSegmentOnly = segmentID != nil && isSegmentOnly
    }

    /// The rectangle the session is editing, read from whichever owner the
    /// current scope names.
    func crop(in store: EditorStore, sourceID: UUID?) -> NormalizedCrop {
        if isSegmentOnly, let segmentID,
           let crop = store.previewProject.timeline.recordingSegment(id: segmentID)?.crop {
            return crop
        }
        return sourceID.flatMap { store.previewProject.source($0)?.crop } ?? .full
    }

    func update(_ crop: NormalizedCrop, in store: EditorStore, sourceID: UUID?) {
        store.updateInteraction { project in
            if isSegmentOnly, let segmentID {
                project.setSegmentCrop(crop, forSegmentID: segmentID)
            } else if let sourceID {
                // One crop per recording: every occurrence of the source,
                // styled or not, follows the same rectangle.
                project.setCrop(crop, for: sourceID)
            }
        }
    }

    /// Changing the scope moves where the rectangle is written, not the
    /// rectangle itself: narrowing hands the recording back the crop it had
    /// when the session opened, widening drops the clip's own rectangle.
    func setSegmentOnly(_ value: Bool, in store: EditorStore, sourceID: UUID?) {
        guard let segmentID, isSegmentOnly != value else { return }
        let draft = crop(in: store, sourceID: sourceID)
        let committed = sourceID.flatMap { store.project.source($0)?.crop } ?? .full
        isSegmentOnly = value
        store.updateInteraction { project in
            if value {
                project.setSegmentCrop(draft, forSegmentID: segmentID)
                if let sourceID { project.setCrop(committed, for: sourceID) }
            } else {
                project.setSegmentCrop(nil, forSegmentID: segmentID)
                if let sourceID { project.setCrop(draft, for: sourceID) }
            }
        }
    }
}

/// Pure crop geometry in normalized source space (origin top-left).
enum EditorCropGeometry {
    /// The largest rectangle of `ratio` inside the source, centred on the
    /// current crop's centre and kept within the source.
    static func fitted(ratio: Double, around crop: NormalizedCrop) -> NormalizedCrop {
        let ratio = max(ratio, 0.001)
        var width = 1.0
        var height = 1.0 / ratio
        if height > 1 {
            height = 1
            width = ratio
        }
        let centerX = crop.x + crop.width / 2
        let centerY = crop.y + crop.height / 2
        return NormalizedCrop(
            x: min(max(centerX - width / 2, 0), 1 - width),
            y: min(max(centerY - height / 2, 0), 1 - height),
            width: width,
            height: height
        )
    }

    static func resized(
        _ origin: NormalizedCrop,
        handle: CropHandle,
        dx: Double,
        dy: Double,
        ratio: Double?,
        minimumWidth: Double,
        minimumHeight: Double
    ) -> NormalizedCrop {
        if let ratio {
            return lockedResize(origin, handle: handle, dx: dx, dy: dy, ratio: max(ratio, 0.001),
                                minimumWidth: minimumWidth, minimumHeight: minimumHeight)
        }
        var left = origin.x
        var right = origin.x + origin.width
        var top = origin.y
        var bottom = origin.y + origin.height
        let movesLeft = [.topLeft, .left, .bottomLeft].contains(handle)
        let movesRight = [.topRight, .right, .bottomRight].contains(handle)
        let movesTop = [.topLeft, .top, .topRight].contains(handle)
        let movesBottom = [.bottomLeft, .bottom, .bottomRight].contains(handle)
        if movesLeft { left = min(max(left + dx, 0), right - minimumWidth) }
        if movesRight { right = max(min(right + dx, 1), left + minimumWidth) }
        if movesTop { top = min(max(top + dy, 0), bottom - minimumHeight) }
        if movesBottom { bottom = max(min(bottom + dy, 1), top + minimumHeight) }
        return NormalizedCrop(x: left, y: top, width: right - left, height: bottom - top).clamped()
    }

    /// Corners keep the opposite corner fixed and follow whichever axis the
    /// pointer moved further along; edges keep the opposite edge fixed and
    /// grow the other axis about its centre.
    private static func lockedResize(
        _ origin: NormalizedCrop,
        handle: CropHandle,
        dx: Double,
        dy: Double,
        ratio: Double,
        minimumWidth: Double,
        minimumHeight: Double
    ) -> NormalizedCrop {
        let left = origin.x
        let top = origin.y
        let right = origin.x + origin.width
        let bottom = origin.y + origin.height
        let minWidth = max(minimumWidth, minimumHeight * ratio)

        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let growsRight = handle == .topRight || handle == .bottomRight
            let growsDown = handle == .bottomLeft || handle == .bottomRight
            let byWidth = origin.width + (growsRight ? dx : -dx)
            let byHeight = (origin.height + (growsDown ? dy : -dy)) * ratio
            var width = abs(byWidth - origin.width) >= abs(byHeight - origin.width) ? byWidth : byHeight
            let maxWidth = min(growsRight ? 1 - left : right, (growsDown ? 1 - top : bottom) * ratio)
            width = min(max(width, min(minWidth, maxWidth)), maxWidth)
            let height = width / ratio
            return NormalizedCrop(
                x: growsRight ? left : right - width,
                y: growsDown ? top : bottom - height,
                width: width,
                height: height
            )
        case .left, .right:
            let proposed = origin.width + (handle == .right ? dx : -dx)
            let maxWidth = min(handle == .right ? 1 - left : right, ratio)
            let width = min(max(proposed, min(minWidth, maxWidth)), maxWidth)
            let height = width / ratio
            let centerY = origin.y + origin.height / 2
            return NormalizedCrop(
                x: handle == .right ? left : right - width,
                y: min(max(centerY - height / 2, 0), 1 - height),
                width: width,
                height: height
            )
        case .top, .bottom:
            let proposed = origin.height + (handle == .bottom ? dy : -dy)
            let maxHeight = min(handle == .bottom ? 1 - top : bottom, 1 / ratio)
            let minHeight = minWidth / ratio
            let height = min(max(proposed, min(minHeight, maxHeight)), maxHeight)
            let width = height * ratio
            let centerX = origin.x + origin.width / 2
            return NormalizedCrop(
                x: min(max(centerX - width / 2, 0), 1 - width),
                y: handle == .bottom ? top : bottom - height,
                width: width,
                height: height
            )
        }
    }

    static func pixelSizeText(_ crop: NormalizedCrop, source: CGSize) -> String {
        let crop = crop.clamped()
        return "\(max(Int((crop.width * Double(source.width)).rounded()), 1)) × "
            + "\(max(Int((crop.height * Double(source.height)).rounded()), 1))"
    }
}
