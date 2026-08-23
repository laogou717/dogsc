import AppKit
import Foundation
import RecorderCore

struct RecordingRunID: RawRepresentable, Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum RecordingPlanError: LocalizedError, Equatable {
    case targetDoesNotMatchConfiguration
    case invalidDisplay
    case invalidWindow
    case invalidArea
    case invalidDevice
    case displayUnavailable
    case windowUnavailable
    case deviceUnavailable
    case missingCamera
    case missingMicrophone

    var errorDescription: String? {
        switch self {
        case .targetDoesNotMatchConfiguration:
            "录制目标已变更，请重新选择显示器、窗口、区域或设备。"
        case .invalidDisplay:
            "请先选择要录制的显示器。"
        case .invalidWindow:
            "请先选择要录制的窗口。"
        case .invalidArea:
            "请先拖动选择要录制的区域。"
        case .invalidDevice:
            "请先选择要录制的 iPhone 或 iPad。"
        case .displayUnavailable:
            "已选择的显示器已断开，请重新选择。"
        case .windowUnavailable:
            "已选择的窗口已关闭，请重新选择。"
        case .deviceUnavailable:
            "已选择的 iPhone 或 iPad 已断开，请重新选择。"
        case .missingCamera:
            "已开启摄像头，但没有选择可用的摄像头。"
        case .missingMicrophone:
            "已开启麦克风，但没有选择可用的麦克风。"
        }
    }
}

/// A recording job is planned exactly once at the setup -> preparing boundary.
/// Target identity and every track decision remain value snapshots for the
/// complete async lifetime of that run.
struct RecordingPlan: Equatable, Sendable {
    let target: CaptureSelectionTarget
    let configuration: CaptureConfiguration
    /// Exact media-input identities frozen at the setup -> preparing boundary.
    /// Enabled recording tracks never become automatic/default requests.
    let inputDeviceRequests: [CaptureInputDeviceRequest]
    /// Fixed capture frame for display/area targets and a bootstrap frame for
    /// windows. Live window geometry belongs to CaptureWindowGeometryRuntime.
    let pointerCaptureFrame: CGRect
    let automaticallyCreatesZooms: Bool

    init(
        target: CaptureSelectionTarget,
        configuration: CaptureConfiguration,
        pointerCaptureFrame: CGRect,
        automaticallyCreatesZooms: Bool = true
    ) throws {
        let materialized = target.materializing(in: configuration)
        guard materialized == configuration else {
            throw RecordingPlanError.targetDoesNotMatchConfiguration
        }
        switch target {
        case let .display(id, _):
            guard id != 0 else { throw RecordingPlanError.invalidDisplay }
        case let .window(id, _, _, _):
            guard id != 0 else { throw RecordingPlanError.invalidWindow }
        case let .area(displayID, _, rect):
            guard displayID != nil,
                  rect == rect.constrained(),
                  rect.x.isFinite, rect.y.isFinite,
                  rect.width.isFinite, rect.height.isFinite else {
                throw RecordingPlanError.invalidArea
            }
        case let .device(id, _):
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordingPlanError.invalidDevice
            }
        }
        if configuration.recordsCamera,
           configuration.cameraDeviceID?.isEmpty != false {
            throw RecordingPlanError.missingCamera
        }
        if configuration.recordsMicrophone,
           configuration.microphoneDeviceID?.isEmpty != false {
            throw RecordingPlanError.missingMicrophone
        }
        var inputDeviceRequests: [CaptureInputDeviceRequest] = []
        if case let .device(id, _) = target {
            inputDeviceRequests.append(.exact(role: .iosDevice, uniqueID: id))
        }
        if configuration.recordsCamera,
           let cameraDeviceID = configuration.cameraDeviceID {
            inputDeviceRequests.append(.exact(role: .camera, uniqueID: cameraDeviceID))
        }
        if configuration.recordsMicrophone,
           let microphoneDeviceID = configuration.microphoneDeviceID {
            inputDeviceRequests.append(.exact(role: .microphone, uniqueID: microphoneDeviceID))
        }
        self.target = target
        self.configuration = configuration
        self.inputDeviceRequests = inputDeviceRequests
        self.pointerCaptureFrame = pointerCaptureFrame
        self.automaticallyCreatesZooms = automaticallyCreatesZooms
    }

    var primaryRecordingRelativePath: String {
        if configuration.source == .device {
            return "media/device-0001.mov"
        }
        return configuration.captureCodec.usesMOVContainer
            ? "media/screen-0001.mov"
            : "media/screen-0001.mp4"
    }

    var initialMediaManifest: ProjectMediaManifest {
        ProjectMediaManifest(
            screen: ProjectMediaReference(relativePath: primaryRecordingRelativePath),
            camera: configuration.recordsCamera
                ? ProjectMediaReference(relativePath: "media/camera-0001.mov") : nil,
            microphone: configuration.recordsMicrophone
                ? ProjectMediaReference(relativePath: "media/microphone.m4a") : nil,
            pointerEvents: configuration.source == .device
                ? nil : ProjectMediaReference(relativePath: "events/pointer.jsonl")
        )
    }

    func validateAvailability(
        displayIDs: Set<UInt32>,
        windowIDs: Set<UInt32>,
        deviceIDs: Set<String>
    ) throws {
        switch target {
        case let .display(id, _):
            guard displayIDs.contains(id) else { throw RecordingPlanError.displayUnavailable }
        case let .area(displayID, _, _):
            guard let displayID, displayIDs.contains(displayID) else {
                throw RecordingPlanError.displayUnavailable
            }
        case let .window(id, _, _, _):
            guard windowIDs.contains(id) else { throw RecordingPlanError.windowUnavailable }
        case let .device(id, _):
            guard deviceIDs.contains(id) else { throw RecordingPlanError.deviceUnavailable }
        }
    }

}

struct RecordingStartedTracks: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    static let screen = Self(rawValue: 1 << 0)
    static let device = Self(rawValue: 1 << 1)
    static let camera = Self(rawValue: 1 << 2)
    static let microphone = Self(rawValue: 1 << 3)
    static let pointer = Self(rawValue: 1 << 4)
}

struct RecordingRun: Equatable, Sendable {
    let id: RecordingRunID
    let plan: RecordingPlan
    let startedTracks: RecordingStartedTracks

    func adding(_ track: RecordingStartedTracks) -> RecordingRun {
        RecordingRun(id: id, plan: plan, startedTracks: startedTracks.union(track))
    }
}

/// Value-semantic generation state. Replacing an active run makes every late
/// completion carrying its previous ID unable to mutate the new run.
struct RecordingRunState: Sendable {
    private(set) var active: RecordingRun?

    mutating func begin(
        _ plan: RecordingPlan,
        id: RecordingRunID = RecordingRunID()
    ) -> RecordingRun {
        let run = RecordingRun(id: id, plan: plan, startedTracks: [])
        active = run
        return run
    }

    func isCurrent(_ id: RecordingRunID) -> Bool {
        active?.id == id
    }

    @discardableResult
    mutating func markStarted(
        _ track: RecordingStartedTracks,
        for id: RecordingRunID
    ) -> Bool {
        guard let run = active, run.id == id else { return false }
        active = run.adding(track)
        return true
    }

    @discardableResult
    mutating func end(_ id: RecordingRunID) -> RecordingRun? {
        guard active?.id == id else { return nil }
        defer { active = nil }
        return active
    }
}

@MainActor
func pointerCaptureFrame(
    for configuration: CaptureConfiguration,
    availableWindows: [CaptureWindowInfo]
) throws -> CGRect {
    func screenFrame(_ displayID: UInt32?) throws -> CGRect {
        guard let screen = AppKitCaptureDisplayResolver.resolveScreen(
            requestedID: displayID
        ) else {
            if displayID != nil {
                throw RecordingPlanError.displayUnavailable
            }
            throw RecordingPlanError.invalidDisplay
        }
        return screen.frame
    }

    switch configuration.source {
    case .display:
        return try screenFrame(configuration.displayID)
    case .area:
        let screen = try screenFrame(configuration.displayID)
        guard let area = configuration.area?.constrained() else { return screen }
        return CGRect(
            x: screen.minX + area.x * screen.width,
            y: screen.minY + (1 - area.y - area.height) * screen.height,
            width: area.width * screen.width,
            height: area.height * screen.height
        )
    case .window:
        guard let window = availableWindows.first(where: { $0.id == configuration.windowID }) else {
            // 窗口在 plan 冻结与录制开始之间已关闭：静默退化为整屏会让指针
            // 事件按整屏归一化而视频轨按窗口裁切，光标位置全部错位。必须显式失败。
            throw RecordingPlanError.windowUnavailable
        }
        let mainDisplayHeight = CGDisplayBounds(CGMainDisplayID()).height
        return CGRect(
            x: window.frame.minX,
            y: mainDisplayHeight - window.frame.maxY,
            width: window.frame.width,
            height: window.frame.height
        )
    case .device:
        return .zero
    }
}

func currentCaptureWindowIDs() -> Set<UInt32> {
    guard let descriptions = CGWindowListCopyWindowInfo(
        [.optionAll, .excludeDesktopElements],
        kCGNullWindowID
    ) as? [[String: Any]] else { return [] }
    return Set(descriptions.compactMap { description in
        (description[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    })
}
