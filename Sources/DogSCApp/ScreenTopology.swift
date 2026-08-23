import AppKit
import CoreGraphics
import Foundation

/// Value-semantic facts for one currently active AppKit screen. `NSScreen`
/// instances are deliberately kept behind the live snapshot provider because
/// they must not become long-lived topology identities.
struct ScreenTopologyNode: Equatable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect
    let pixelSize: CGSize
    let backingScale: CGFloat
    let maximumFramesPerSecond: Int

    fileprivate var geometryFacts: GeometryFacts {
        GeometryFacts(frame: frame, visibleFrame: visibleFrame)
    }

    fileprivate var modeFacts: ModeFacts {
        ModeFacts(
            pixelSize: pixelSize,
            backingScale: backingScale,
            maximumFramesPerSecond: maximumFramesPerSecond
        )
    }

    fileprivate struct GeometryFacts: Equatable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    fileprivate struct ModeFacts: Equatable {
        let pixelSize: CGSize
        let backingScale: CGFloat
        let maximumFramesPerSecond: Int
    }
}

/// One stable, post-reconfiguration view of all active screens. Display IDs are
/// the only keys; neither array order nor localized display names are identity.
struct ScreenTopologySnapshot: Equatable, Sendable {
    let generation: UInt64
    let nodesByID: [UInt32: ScreenTopologyNode]
    let mainDisplayID: UInt32?

    init(
        generation: UInt64,
        nodes: [ScreenTopologyNode],
        mainDisplayID: UInt32?
    ) {
        self.generation = generation
        nodesByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in
            newest
        })
        self.mainDisplayID = mainDisplayID
    }

    var nodes: [ScreenTopologyNode] {
        nodesByID.values.sorted { $0.id < $1.id }
    }

    func node(for displayID: UInt32) -> ScreenTopologyNode? {
        nodesByID[displayID]
    }

    fileprivate func assigningGeneration(_ replacement: UInt64) -> Self {
        Self(
            generation: replacement,
            nodes: nodes,
            mainDisplayID: mainDisplayID
        )
    }

    @MainActor
    static func current(generation: UInt64) -> Self {
        let nodes = NSScreen.screens.compactMap { screen -> ScreenTopologyNode? in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let mode = CGDisplayCopyDisplayMode(displayID)
            let pixelWidth = mode?.pixelWidth ?? CGDisplayPixelsWide(displayID)
            let pixelHeight = mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
            return ScreenTopologyNode(
                id: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                pixelSize: CGSize(
                    width: max(pixelWidth, 1),
                    height: max(pixelHeight, 1)
                ),
                backingScale: max(screen.backingScaleFactor, 1),
                maximumFramesPerSecond: max(screen.maximumFramesPerSecond, 1)
            )
        }
        // `NSScreen.main` follows the key window and can therefore change from
        // an ordinary focus switch. CoreGraphics is the stable identity of the
        // display configured as the system's main display.
        let systemMainDisplayID = UInt32(CGMainDisplayID())
        let mainDisplayID = nodes.contains(where: { $0.id == systemMainDisplayID })
            ? systemMainDisplayID
            : nil
        return Self(
            generation: generation,
            nodes: nodes,
            mainDisplayID: mainDisplayID
        )
    }
}

/// Classified changes between two stable snapshots. A common display may
/// appear in both geometry and mode sets when a reconfiguration changed both.
struct ScreenTopologyDelta: Equatable, Sendable {
    let previousGeneration: UInt64
    let generation: UInt64
    let added: Set<UInt32>
    let removed: Set<UInt32>
    let geometryChanged: Set<UInt32>
    let modeChanged: Set<UInt32>
    let mainChanged: Bool

    var isEmpty: Bool {
        added.isEmpty
            && removed.isEmpty
            && geometryChanged.isEmpty
            && modeChanged.isEmpty
            && !mainChanged
    }

    static func between(
        _ previous: ScreenTopologySnapshot,
        _ replacement: ScreenTopologySnapshot
    ) -> Self {
        let previousIDs = Set(previous.nodesByID.keys)
        let replacementIDs = Set(replacement.nodesByID.keys)
        let commonIDs = previousIDs.intersection(replacementIDs)
        let geometryChanged = Set(commonIDs.filter { displayID in
            previous.nodesByID[displayID]?.geometryFacts
                != replacement.nodesByID[displayID]?.geometryFacts
        })
        let modeChanged = Set(commonIDs.filter { displayID in
            previous.nodesByID[displayID]?.modeFacts
                != replacement.nodesByID[displayID]?.modeFacts
        })
        return Self(
            previousGeneration: previous.generation,
            generation: replacement.generation,
            added: replacementIDs.subtracting(previousIDs),
            removed: previousIDs.subtracting(replacementIDs),
            geometryChanged: geometryChanged,
            modeChanged: modeChanged,
            mainChanged: previous.mainDisplayID != replacement.mainDisplayID
        )
    }
}

/// Small value state for invalidating work captured under an older topology.
/// Future selector/panel restorations can retain `generation`, then refuse to
/// order a stale surface when `isCurrent(_:)` becomes false.
struct ScreenTopologyReconfigurationState: Equatable, Sendable {
    private(set) var generation: UInt64

    init(generation: UInt64 = 0) {
        self.generation = generation
    }

    @discardableResult
    mutating func advance() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation
    }
}

/// A narrow Sendable owner for NotificationCenter's Objective-C observer token.
/// `NSObjectProtocol` itself is not Sendable, but NotificationCenter permits
/// observer removal from any thread. The lock makes token consumption atomic,
/// so explicit stop and nonisolated deinit can safely share idempotent cleanup.
private final class ScreenTopologyObserverLease: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let lock = NSLock()
    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter, observer: NSObjectProtocol) {
        self.notificationCenter = notificationCenter
        self.observer = observer
    }

    func cancel() {
        let observerToRemove: NSObjectProtocol?
        lock.lock()
        observerToRemove = observer
        observer = nil
        lock.unlock()

        if let observerToRemove {
            notificationCenter.removeObserver(observerToRemove)
        }
    }

    deinit {
        cancel()
    }
}

/// App-scoped source of stable screen facts. It intentionally owns no capture
/// state and performs no selector or window mutation. The AppKit notification
/// is authoritative for this first batch; CoreGraphics will-change callbacks
/// can be added later without changing the published value contract.
@MainActor
final class ScreenTopologyMonitor {
    typealias SnapshotProvider = @MainActor (UInt64) -> ScreenTopologySnapshot
    typealias StableRefreshScheduler = (
        @escaping @MainActor @Sendable () -> Void
    ) -> Void

    private(set) var snapshot: ScreenTopologySnapshot
    var onChange: ((ScreenTopologySnapshot, ScreenTopologyDelta) -> Void)?

    private let notificationCenter: NotificationCenter
    private let snapshotProvider: SnapshotProvider
    private let scheduleStableRefresh: StableRefreshScheduler
    private var observerLease: ScreenTopologyObserverLease?
    private var refreshIsScheduled = false
    private var lifecycleGeneration: UInt64 = 0
    private var reconfigurationState: ScreenTopologyReconfigurationState

    init(
        notificationCenter: NotificationCenter = .default,
        snapshotProvider: @escaping SnapshotProvider = ScreenTopologySnapshot.current(
            generation:
        ),
        scheduleStableRefresh: @escaping StableRefreshScheduler = { operation in
            RunLoop.main.perform {
                MainActor.assumeIsolated {
                    operation()
                }
            }
        }
    ) {
        self.notificationCenter = notificationCenter
        self.snapshotProvider = snapshotProvider
        self.scheduleStableRefresh = scheduleStableRefresh
        let initial = snapshotProvider(0).assigningGeneration(0)
        snapshot = initial
        reconfigurationState = ScreenTopologyReconfigurationState(
            generation: initial.generation
        )
    }

    var isRunning: Bool { observerLease != nil }

    func start() {
        guard observerLease == nil else { return }
        lifecycleGeneration &+= 1
        let observer = notificationCenter.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleRefreshAfterScreenParametersChange()
            }
        }
        observerLease = ScreenTopologyObserverLease(
            notificationCenter: notificationCenter,
            observer: observer
        )
    }

    func stop() {
        lifecycleGeneration &+= 1
        refreshIsScheduled = false
        observerLease?.cancel()
        observerLease = nil
    }

    deinit {
        observerLease?.cancel()
    }

    private func scheduleRefreshAfterScreenParametersChange() {
        guard observerLease != nil, !refreshIsScheduled else { return }
        refreshIsScheduled = true
        let scheduledLifecycleGeneration = lifecycleGeneration
        scheduleStableRefresh { [weak self] in
            guard let self,
                  self.observerLease != nil,
                  self.lifecycleGeneration == scheduledLifecycleGeneration,
                  self.refreshIsScheduled else { return }
            self.refreshIsScheduled = false
            self.publishStableSnapshot()
        }
    }

    private func publishStableSnapshot() {
        let generation = reconfigurationState.advance()
        let replacement = snapshotProvider(generation).assigningGeneration(generation)
        let delta = ScreenTopologyDelta.between(snapshot, replacement)
        snapshot = replacement
        onChange?(replacement, delta)
    }
}
