import AppKit
import CoreMedia
import Foundation
import RecorderCore

struct PointerRecordingStart: Equatable, Sendable {
    let wallTime: Date
    let hostTime: TimeInterval
}

@MainActor
struct PointerCaptureFrameSource {
    private let resolve: @MainActor () -> CGRect?

    private init(resolve: @escaping @MainActor () -> CGRect?) {
        self.resolve = resolve
    }

    static func fixed(_ frame: CGRect) -> PointerCaptureFrameSource {
        PointerCaptureFrameSource { frame }
    }

    static func trackedWindow(
        windowID: UInt32,
        frameProvider: @escaping @MainActor (UInt32) -> CGRect?
    ) -> PointerCaptureFrameSource {
        PointerCaptureFrameSource {
            frameProvider(windowID)
        }
    }

    func currentFrame() -> CGRect? {
        guard let frame = resolve(),
              frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else { return nil }
        return frame
    }
}

enum PointerCoordinateMapper {
    /// CGEvent locations use Quartz's top-left global coordinate system while
    /// the capture frames below use AppKit's bottom-left system. Mixing the two
    /// silently mirrors Y (and is especially visible for window capture).
    static func appKitPoint(
        fromQuartz point: CGPoint,
        mainDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    static func normalized(point: CGPoint, in frame: CGRect) -> NormalizedPoint? {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else { return nil }
        return NormalizedPoint(
            x: min(max((point.x - frame.minX) / frame.width, 0), 1),
            y: min(max(1 - (point.y - frame.minY) / frame.height, 0), 1)
        )
    }
}

struct PointerEventOrderingState {
    private(set) var isMonotonic = true
    private var lastTime: TimeInterval?

    mutating func reset() {
        isMonotonic = true
        lastTime = nil
    }

    mutating func observe(time: TimeInterval) {
        if let lastTime, time < lastTime { isMonotonic = false }
        self.lastTime = time
    }

    func finalized(_ records: [PointerEventRecord]) -> [PointerEventRecord] {
        isMonotonic ? records : records.sorted { $0.time < $1.time }
    }
}

private final class PointerEventBuffer: @unchecked Sendable {
    private static let relevantPointerModifierFlags: CGEventFlags = [
        .maskCommand, .maskAlternate, .maskControl, .maskShift,
        .maskAlphaShift, .maskSecondaryFn,
    ]
    private let lock = NSLock()
    private var startedAtUptime: TimeInterval?
    private var pausedAtUptime: TimeInterval?
    private var accumulatedPausedDuration: TimeInterval = 0
    private var captureFrame: CGRect?
    private var mainDisplayHeight: CGFloat = 0
    private var records: [PointerEventRecord] = []
    private var lastMoveTime: TimeInterval = -.infinity
    private var currentCursorAssetID: CursorAssetID?
    private var ordering = PointerEventOrderingState()
    private var eventTap: CFMachPort?

    func start(
        at uptime: TimeInterval,
        captureFrame: CGRect,
        initialPointer: CGPoint,
        mainDisplayHeight: CGFloat,
        initialCursorAssetID: CursorAssetID
    ) {
        lock.lock()
        defer { lock.unlock() }
        startedAtUptime = uptime
        pausedAtUptime = nil
        accumulatedPausedDuration = 0
        self.captureFrame = captureFrame
        self.mainDisplayHeight = mainDisplayHeight
        records.removeAll(keepingCapacity: true)
        lastMoveTime = -.infinity
        ordering.reset()
        currentCursorAssetID = initialCursorAssetID
        if let normalized = PointerCoordinateMapper.normalized(
            point: initialPointer,
            in: captureFrame
        ) {
            appendRecordLocked(
                PointerEventRecord(
                    time: 0,
                    location: normalized,
                    kind: .move,
                    cursorAssetID: initialCursorAssetID
                )
            )
        }
    }

    func recordCursorShapeChange(
        _ assetID: CursorAssetID,
        timestamp: TimeInterval,
        appKitLocation: CGPoint
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard let startedAtUptime, pausedAtUptime == nil, let captureFrame,
              currentCursorAssetID != assetID else { return }
        let time = timestamp - startedAtUptime - accumulatedPausedDuration
        guard time.isFinite, time >= 0,
              let normalized = PointerCoordinateMapper.normalized(
                  point: appKitLocation,
                  in: captureFrame
              ) else { return }
        currentCursorAssetID = assetID
        appendRecordLocked(
            PointerEventRecord(
                time: time,
                location: normalized,
                kind: .move,
                cursorAssetID: assetID
            )
        )
    }

    func updateCaptureFrame(_ frame: CGRect) {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else { return }
        lock.lock()
        captureFrame = frame
        lock.unlock()
    }

    func attachEventTap(_ tap: CFMachPort?) {
        lock.lock()
        eventTap = tap
        lock.unlock()
    }

    func pause(at uptime: TimeInterval) {
        lock.lock()
        if startedAtUptime != nil, pausedAtUptime == nil {
            pausedAtUptime = uptime
        }
        lock.unlock()
    }

    func resume(at uptime: TimeInterval) {
        lock.lock()
        if let pausedAtUptime {
            accumulatedPausedDuration += max(uptime - pausedAtUptime, 0)
            self.pausedAtUptime = nil
        }
        lock.unlock()
    }

    func stop() -> [PointerEventRecord] {
        lock.lock()
        defer { lock.unlock() }
        startedAtUptime = nil
        pausedAtUptime = nil
        captureFrame = nil
        currentCursorAssetID = nil
        // Quartz event-tap timestamps are normally delivered in monotonic
        // order. Sorting and copying ~576k points at the end of a 40-minute
        // 240 Hz track only delays finalization and briefly doubles memory.
        // Preserve the old sorted guarantee only for the exceptional path in
        // which callbacks actually arrived out of order.
        let finalized = ordering.finalized(records)
        // Transfer the backing storage to the caller. Keeping `records`
        // alive here would retain the complete previous track until the next
        // recording starts; assigning an empty array releases that ownership
        // without copying the monotonic fast path.
        records = []
        ordering.reset()
        return finalized
    }

    func receive(
        type: CGEventType,
        timestamp: TimeInterval,
        quartzLocation: CGPoint,
        flags: CGEventFlags
    ) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = eventTap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let point: CGPoint
        lock.lock()
        point = PointerCoordinateMapper.appKitPoint(
            fromQuartz: quartzLocation,
            mainDisplayHeight: mainDisplayHeight
        )
        appendLocked(type: type, timestamp: timestamp, appKitLocation: point, flags: flags)
        lock.unlock()
    }

    func receiveFallback(_ event: NSEvent) {
        let type: CGEventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .rightMouseDown: type = .rightMouseDown
        case .leftMouseDragged: type = .leftMouseDragged
        case .rightMouseDragged: type = .rightMouseDragged
        default: type = .mouseMoved
        }
        if let cgEvent = event.cgEvent {
            receive(
                type: type,
                timestamp: Double(cgEvent.timestamp) / 1_000_000_000,
                quartzLocation: cgEvent.location,
                flags: cgEvent.flags
            )
            return
        }
        lock.lock()
        appendLocked(
            type: type,
            timestamp: event.timestamp,
            appKitLocation: NSEvent.mouseLocation,
            flags: Self.cgFlags(from: event.modifierFlags)
        )
        lock.unlock()
    }

    private func appendLocked(
        type: CGEventType,
        timestamp: TimeInterval,
        appKitLocation: CGPoint,
        flags: CGEventFlags
    ) {
        guard let startedAtUptime, pausedAtUptime == nil, let captureFrame else { return }
        let time = timestamp - startedAtUptime - accumulatedPausedDuration
        guard time.isFinite, time >= 0 else { return }
        let kind: PointerEventKind
        switch type {
        case .leftMouseDown:
            kind = .leftClick
        case .rightMouseDown:
            kind = .rightClick
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            // Keep at most 240 positions/s. This preserves two physical samples
            // per 120 Hz output frame without allowing a 1000 Hz gaming mouse
            // to create a multi-gigabyte JSON track.
            guard time - lastMoveTime >= 1.0 / 240.0 else { return }
            lastMoveTime = time
            kind = .move
        default:
            return
        }
        guard let normalized = PointerCoordinateMapper.normalized(
            point: appKitLocation,
            in: captureFrame
        ) else { return }
        appendRecordLocked(PointerEventRecord(
            time: time,
            location: normalized,
            kind: kind,
            modifiers: Self.pointerModifiers(from: flags),
            cursorAssetID: currentCursorAssetID
        ))
    }

    private func appendRecordLocked(_ record: PointerEventRecord) {
        ordering.observe(time: record.time)
        records.append(record)
    }

    private static func pointerModifiers(from flags: CGEventFlags) -> [PointerModifier] {
        guard !flags.intersection(relevantPointerModifierFlags).isEmpty else { return [] }
        return PointerModifier.allCases.filter { modifier in
            switch modifier {
            case .command: return flags.contains(.maskCommand)
            case .option: return flags.contains(.maskAlternate)
            case .control: return flags.contains(.maskControl)
            case .shift: return flags.contains(.maskShift)
            case .capsLock: return flags.contains(.maskAlphaShift)
            case .function: return flags.contains(.maskSecondaryFn)
            }
        }
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.capsLock) { result.insert(.maskAlphaShift) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }
}

/// Owns the Quartz event tap on a dedicated run loop. Pointer timestamps must
/// not be delayed by SwiftUI/AppKit work on the main run loop: once those input
/// samples arrive in a burst, post-production interpolation cannot reconstruct
/// the user's original velocity or click timing.
private final class PointerEventTapRunner: @unchecked Sendable {
    private let buffer: PointerEventBuffer
    private let lock = NSLock()
    private let startup = DispatchSemaphore(value: 0)
    private var didInstall = false
    private var shouldStop = false
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init(buffer: PointerEventBuffer) {
        self.buffer = buffer
    }

    func start() -> Bool {
        lock.lock()
        shouldStop = false
        lock.unlock()
        let thread = Thread { [self] in
            runEventLoop()
        }
        thread.name = "cn.laogou.dogsc.pointer-events"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        guard startup.wait(timeout: .now() + 1) == .success else {
            stop()
            return false
        }
        lock.lock()
        let installed = didInstall
        lock.unlock()
        return installed
    }

    func stop() {
        lock.lock()
        shouldStop = true
        let runLoop = runLoop
        let tap = tap
        lock.unlock()
        buffer.attachEventTap(nil)
        if let tap { CFMachPortInvalidate(tap) }
        if let runLoop {
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        thread = nil
    }

    private func runEventLoop() {
        let eventTypes: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown,
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) {
            $0 | (CGEventMask(1) << CGEventMask($1.rawValue))
        }
        let userInfo = Unmanaged.passUnretained(buffer).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let buffer = Unmanaged<PointerEventBuffer>
                    .fromOpaque(userInfo).takeUnretainedValue()
                buffer.receive(
                    type: type,
                    timestamp: Double(event.timestamp) / 1_000_000_000,
                    quartzLocation: event.location,
                    flags: event.flags
                )
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            lock.lock()
            didInstall = false
            lock.unlock()
            startup.signal()
            return
        }

        let runLoop = CFRunLoopGetCurrent()
        lock.lock()
        guard !shouldStop else {
            didInstall = false
            lock.unlock()
            CFMachPortInvalidate(tap)
            startup.signal()
            return
        }
        self.runLoop = runLoop
        self.tap = tap
        self.source = source
        didInstall = true
        lock.unlock()
        buffer.attachEventTap(tap)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        startup.signal()
        lock.lock()
        let shouldRun = !shouldStop
        lock.unlock()
        if shouldRun { CFRunLoopRun() }
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        buffer.attachEventTap(nil)
        lock.lock()
        self.runLoop = nil
        self.tap = nil
        self.source = nil
        lock.unlock()
    }
}

@MainActor
final class PointerEventRecorder {
    private let buffer = PointerEventBuffer()
    private var eventTapRunner: PointerEventTapRunner?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var frameSource: PointerCaptureFrameSource?
    private var frameRefreshTimer: Timer?
    private var cursorShapeTimer: Timer?
    private var lastObservedSystemCursor: NSCursor?
    private var previousMouseCoalescingEnabled: Bool?

    /// Global monitors require the Accessibility permission and only receive
    /// events from *other* applications — movement over this app's own windows
    /// (recorder bar, editor) is invisible to them. The local monitor covers
    /// those windows; both share the same global `NSEvent.mouseLocation`, so
    /// coordinates stay consistent.
    private static let eventMask: NSEvent.EventTypeMask = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .leftMouseDown,
        .rightMouseDown,
    ]

    @discardableResult
    func start(frameSource: PointerCaptureFrameSource) async -> PointerRecordingStart? {
        _ = stop()
        guard let initialFrame = frameSource.currentFrame() else { return nil }
        self.frameSource = frameSource
        // REC-002/CUR-001: record the exact pointer epoch in the same Core Media
        // host-clock domain as ScreenCaptureKit video PTS. Date is retained only
        // as a fallback for non-SCK sources; wall-clock adjustments can no longer
        // shift the reconstructed cursor against native screen video.
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let wallTime = Date()
        let initialCursor = NSCursor.currentSystem
        let initialCursorAssetID = CursorAssetLibrary.recordedSystemAssetID(
            for: initialCursor
        ) ?? .systemArrow
        lastObservedSystemCursor = initialCursor
        buffer.start(
            at: hostTime,
            captureFrame: initialFrame,
            initialPointer: NSEvent.mouseLocation,
            mainDisplayHeight: CGDisplayBounds(CGMainDisplayID()).height,
            initialCursorAssetID: initialCursorAssetID
        )
        previousMouseCoalescingEnabled = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = false
        installFrameRefreshTimer()
        installCursorShapeTimer()
        if !(await installEventTap()) { installMonitorFallback() }
        guard !Task.isCancelled else {
            _ = stop()
            return nil
        }
        return PointerRecordingStart(wallTime: wallTime, hostTime: hostTime)
    }

    @discardableResult
    func stop() -> [PointerEventRecord] {
        frameRefreshTimer?.invalidate()
        frameRefreshTimer = nil
        cursorShapeTimer?.invalidate()
        cursorShapeTimer = nil
        lastObservedSystemCursor = nil
        eventTapRunner?.stop()
        eventTapRunner = nil
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        globalMonitor = nil
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        if let previousMouseCoalescingEnabled {
            NSEvent.isMouseCoalescingEnabled = previousMouseCoalescingEnabled
        }
        previousMouseCoalescingEnabled = nil
        frameSource = nil
        return buffer.stop()
    }

    func pause() {
        buffer.pause(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    func resume() {
        buffer.resume(at: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        sampleSystemCursorShape(force: true)
    }

    private func installFrameRefreshTimer() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let frame = self.frameSource?.currentFrame() else { return }
                self.buffer.updateCaptureFrame(frame)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameRefreshTimer = timer
    }

    private func installCursorShapeTimer() {
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampleSystemCursorShape(force: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorShapeTimer = timer
    }

    private func sampleSystemCursorShape(force: Bool) {
        guard let cursor = NSCursor.currentSystem else { return }
        if !force, cursor === lastObservedSystemCursor { return }
        lastObservedSystemCursor = cursor
        guard let assetID = CursorAssetLibrary.recordedSystemAssetID(for: cursor) else {
            return
        }
        buffer.recordCursorShapeChange(
            assetID,
            timestamp: CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            appKitLocation: NSEvent.mouseLocation
        )
    }

    private func installEventTap() async -> Bool {
        let runner = PointerEventTapRunner(buffer: buffer)
        // `runner.start()` waits on a semaphore until its dedicated run-loop
        // thread has installed the Quartz tap (up to one second). Never block
        // MainActor here: permission trouble or system load would otherwise
        // freeze the recording bar and delay every other startup completion.
        let installed = await Task.detached(priority: .userInitiated) {
            runner.start()
        }.value
        guard !Task.isCancelled, installed else {
            runner.stop()
            return false
        }
        eventTapRunner = runner
        return true
    }

    private func installMonitorFallback() {
        let buffer = buffer
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.eventMask) { event in
            buffer.receiveFallback(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.eventMask) { event in
            buffer.receiveFallback(event)
            return event
        }
    }
}
