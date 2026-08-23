import AppKit
import CoreGraphics
import Foundation

/// Ephemeral geometry for one immutable capture-window identity. This is never
/// persisted into the project; it exists only while selecting or recording.
struct CaptureWindowGeometry: Equatable, Sendable {
    let windowID: UInt32
    let frame: CGRect
}

enum CaptureWindowSelectionPolicy {
    static func hover(
        previous: CaptureWindowInfo?,
        pointerIsInsideRecorderWindow: Bool,
        frontmostCandidate: CaptureWindowInfo?
    ) -> CaptureWindowInfo? {
        pointerIsInsideRecorderWindow ? previous : frontmostCandidate
    }

    static func lockedWindow(
        id: UInt32,
        catalog: [CaptureWindowInfo],
        geometry: CaptureWindowGeometry?
    ) -> CaptureWindowInfo? {
        guard geometry?.windowID == id else { return nil }
        return catalog.first(where: { $0.id == id })
    }
}

enum CaptureWindowGeometryLookup {
    private static let queue = DispatchQueue(
        label: "cn.laogou.dogsc.window-geometry",
        qos: .utility
    )

    static func live(windowID: UInt32) -> CaptureWindowGeometry? {
        guard let descriptions = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow, .excludeDesktopElements],
            CGWindowID(windowID)
        ) as? [[String: Any]] else { return nil }
        return resolve(
            windowID: windowID,
            descriptions: descriptions,
            mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height
        )
    }

    /// CGWindowListCopyWindowInfo is a synchronous WindowServer round trip.
    /// Recording polls must not execute it on MainActor, where a slow response
    /// blocks the recorder toolbar and every AppKit event in the process.
    static func background(windowID: UInt32) async -> CaptureWindowGeometry? {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: live(windowID: windowID))
            }
        }
    }

    static func resolve(
        windowID: UInt32,
        descriptions: [[String: Any]],
        mainDisplayHeight: CGFloat
    ) -> CaptureWindowGeometry? {
        guard let description = descriptions.first(where: {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
        }),
              (description[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let boundsDictionary = description[kCGWindowBounds as String] as? NSDictionary,
              let quartzFrame = CGRect(
                  dictionaryRepresentation: boundsDictionary as CFDictionary
              ),
              quartzFrame.width > 0,
              quartzFrame.height > 0 else { return nil }
        return CaptureWindowGeometry(
            windowID: windowID,
            frame: CGRect(
                x: quartzFrame.minX,
                y: mainDisplayHeight - quartzFrame.maxY,
                width: quartzFrame.width,
                height: quartzFrame.height
            )
        )
    }
}

/// Owns only live geometry. The immutable window ID still belongs to the
/// RecordingPlan/CaptureSelectionTarget boundary.
@MainActor
final class CaptureWindowGeometryRuntime {
    typealias Lookup = @MainActor (UInt32) -> CaptureWindowGeometry?
    typealias PollingLookup = @Sendable (UInt32) async -> CaptureWindowGeometry?

    var onChange: ((CaptureWindowGeometry?) -> Void)?
    private(set) var windowID: UInt32?
    private(set) var geometry: CaptureWindowGeometry?

    private let lookup: Lookup
    private let pollingLookup: PollingLookup
    private let pollInterval: Duration?
    private var pollingTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        pollInterval: Duration? = .milliseconds(75),
        lookup: @escaping Lookup = CaptureWindowGeometryLookup.live(windowID:),
        pollingLookup: @escaping PollingLookup = { windowID in
            await CaptureWindowGeometryLookup.background(windowID: windowID)
        }
    ) {
        self.pollInterval = pollInterval
        self.lookup = lookup
        self.pollingLookup = pollingLookup
    }

    func start(
        windowID: UInt32,
        initialFrame: CGRect,
        pollInterval overrideInterval: Duration? = nil
    ) {
        generation &+= 1
        let activeGeneration = generation
        pollingTask?.cancel()
        self.windowID = windowID
        publish(CaptureWindowGeometry(windowID: windowID, frame: initialFrame))
        // 录制高亮不需要悬停级的跟手精度：13Hz 的窗口服务器同步查询在录制
        // 期间与 SwiftUI 录制面板争抢主线程，降到 250ms 视觉无感知差异。
        let interval = overrideInterval ?? pollInterval
        guard let interval else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == activeGeneration else { return }
                let replacement = await self.pollingLookup(windowID)
                guard !Task.isCancelled,
                      self.generation == activeGeneration,
                      self.windowID == windowID else { return }
                self.publishLookupResult(replacement, expectedWindowID: windowID)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func refreshNow() {
        guard let windowID else { return }
        let replacement = lookup(windowID)
        publishLookupResult(replacement, expectedWindowID: windowID)
    }

    private func publishLookupResult(
        _ replacement: CaptureWindowGeometry?,
        expectedWindowID windowID: UInt32
    ) {
        guard replacement?.windowID == windowID else {
            publish(nil)
            return
        }
        publish(replacement)
    }

    func frame(for requestedWindowID: UInt32) -> CGRect? {
        guard windowID == requestedWindowID,
              geometry?.windowID == requestedWindowID else { return nil }
        return geometry?.frame
    }

    func stop() {
        generation &+= 1
        pollingTask?.cancel()
        pollingTask = nil
        windowID = nil
        publish(nil)
    }

    private func publish(_ replacement: CaptureWindowGeometry?) {
        guard replacement != geometry else { return }
        geometry = replacement
        onChange?(replacement)
    }
}
