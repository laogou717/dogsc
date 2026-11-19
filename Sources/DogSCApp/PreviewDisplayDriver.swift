import Foundation
import os
import QuartzCore
import RecorderCore

/// Owns both drawable acquisition and CAMetalDisplayLink on one run loop.
/// A paused link still owns its layer: invalidate it before acquiring a
/// stationary or retirement drawable with nextDrawable().
final class PreviewDisplayDriver: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var loop: CFRunLoop?
        var layer: CAMetalLayer?
        var active = false
        var needsFrame = false
        var stopped = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let receive: @Sendable (PreviewDisplayFrame?) -> Void
    private var thread: Thread?
    // The following two fields belong exclusively to the display thread.
    private var link: CAMetalDisplayLink?
    private weak var linkedLayer: CAMetalLayer?

    init(receive: @escaping @Sendable (PreviewDisplayFrame?) -> Void) {
        self.receive = receive
        super.init()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "cn.laogou.dogsc.preview-display"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }
    func configure(layer: CAMetalLayer?, active: Bool) {
        let loop = state.withLockUnchecked { s -> CFRunLoop? in
            guard !s.stopped else { return nil }
            guard s.layer !== layer || s.active != active else { return nil }
            if s.layer !== layer || active { s.needsFrame = false }
            s.layer = layer; s.active = active
            return s.loop
        }
        scheduleConfiguration(on: loop)
    }
    func requestFrame() {
        let loop = state.withLockUnchecked { s -> CFRunLoop? in
            guard !s.stopped, !s.active, s.layer != nil, !s.needsFrame else { return nil }
            s.needsFrame = true
            return s.loop
        }
        scheduleConfiguration(on: loop)
    }
    private func scheduleConfiguration(on loop: CFRunLoop?) {
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { [weak self] in self?.applyConfiguration() }
            CFRunLoopWakeUp(loop)
        }
    }
    func invalidate() {
        let loop = state.withLockUnchecked { s in s.stopped = true; s.layer = nil; s.needsFrame = false; return s.loop }
        if let loop {
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { CFRunLoopStop(CFRunLoopGetCurrent()) }
            CFRunLoopWakeUp(loop)
        }
    }
    private func run() {
        autoreleasepool {
            let loop = CFRunLoopGetCurrent()!
            let keepAlive = Port()
            RunLoop.current.add(keepAlive, forMode: .default)
            let stopped = state.withLockUnchecked { s in s.loop = loop; return s.stopped }
            if !stopped {
                applyConfiguration()
                while !state.withLockUnchecked({ $0.stopped }) {
                    autoreleasepool { _ = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 3_600, true) }
                }
            }
            link?.invalidate(); link = nil; linkedLayer = nil
            keepAlive.invalidate()
            state.withLockUnchecked { $0.loop = nil }
        }
    }
    private func applyConfiguration() {
        let (layer, active, stopped, needsFrame) = state.withLockUnchecked { s in
            defer { s.needsFrame = false }
            return (s.layer, s.active, s.stopped, s.needsFrame)
        }
        guard !stopped else { CFRunLoopStop(CFRunLoopGetCurrent()); return }
        if linkedLayer !== layer || !active {
            link?.invalidate(); link = nil; linkedLayer = nil
            if active, let layer {
                linkedLayer = layer
                let link = CAMetalDisplayLink(metalLayer: layer)
                link.delegate = self
                let rate = Float(PreviewAnimationCadence.framesPerSecond)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
                link.preferredFrameLatency = 2
                link.add(to: .current, forMode: .common)
                self.link = link
            }
        }
        if !active, needsFrame, let layer {
            // No display link can attach between invalidation and acquisition:
            // both operations are confined to this thread.
            let frame = layer.nextDrawable().map {
                PreviewDisplayFrame(drawable: $0, presentationTime: CACurrentMediaTime())
            }
            receive(frame)
        }
    }
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        guard link === self.link,
              state.withLockUnchecked({ $0.active && !$0.stopped && $0.layer === linkedLayer }) else { return }
        receive(PreviewDisplayFrame(update: update))
    }
}
