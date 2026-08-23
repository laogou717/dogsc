import AVFoundation
import Foundation

enum CaptureDeviceOperationDomain: CaseIterable, Hashable, Sendable {
    case catalogRefresh
    case screenDevice
    case camera
    case microphone
}

struct CaptureDeviceOperationToken: Equatable, Sendable {
    let domain: CaptureDeviceOperationDomain
    let generation: UInt64
}

/// A small, pure state machine used to reject completions from superseded
/// device work. Device IDs are not sufficient here: a disconnected USB camera
/// can reconnect with the same ID while its previous release/preview task is
/// still suspended in AVFoundation.
struct CaptureDeviceGenerationState: Sendable {
    private var generations: [CaptureDeviceOperationDomain: UInt64] = [:]

    mutating func begin(_ domain: CaptureDeviceOperationDomain) -> CaptureDeviceOperationToken {
        var next = (generations[domain] ?? 0) &+ 1
        if next == 0 { next = 1 }
        generations[domain] = next
        return CaptureDeviceOperationToken(domain: domain, generation: next)
    }

    func isCurrent(_ token: CaptureDeviceOperationToken) -> Bool {
        generations[token.domain] == token.generation
    }
}

/// NotificationCenter returns opaque, non-Sendable observer tokens. This
/// ordinary owner removes them without asking an actor-isolated deinitializer
/// to read or transfer those tokens.
private final class CaptureDeviceObservationBag {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(
        center: NotificationCenter,
        names: [Notification.Name],
        handler: @escaping @Sendable (Notification) -> Void
    ) {
        self.center = center
        tokens = names.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main,
                using: handler
            )
        }
    }

    deinit {
        for token in tokens {
            center.removeObserver(token)
        }
    }
}

/// Owns the complete connection-observation and refresh-burst lifecycle while
/// AppModel remains responsible for applying a refreshed catalog to published
/// configuration and preview state.
@MainActor
final class CaptureDeviceLifecycle {
    typealias RefreshCatalog = @MainActor () -> Void

    private static let defaultRefreshDelays: [Duration] = [
        .zero,
        .milliseconds(250),
        .milliseconds(500),
        .seconds(1),
        .seconds(2),
        .seconds(3),
        .seconds(5),
    ]

    private let notificationCenter: NotificationCenter
    private let refreshDelays: [Duration]
    private let refreshCatalog: RefreshCatalog
    private var observations: CaptureDeviceObservationBag?
    private var observationSessionID: UUID?
    private var refreshTask: Task<Void, Never>?
    private var generations = CaptureDeviceGenerationState()

    init(
        notificationCenter: NotificationCenter = .default,
        refreshDelays: [Duration]? = nil,
        refreshCatalog: @escaping RefreshCatalog
    ) {
        self.notificationCenter = notificationCenter
        self.refreshDelays = refreshDelays ?? Self.defaultRefreshDelays
        self.refreshCatalog = refreshCatalog
    }

    func start() {
        guard observations == nil else { return }
        let sessionID = UUID()
        observationSessionID = sessionID
        observations = CaptureDeviceObservationBag(
            center: notificationCenter,
            names: [
                AVCaptureDevice.wasConnectedNotification,
                AVCaptureDevice.wasDisconnectedNotification,
            ]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConnectionChange(for: sessionID)
            }
        }
        refreshCatalog()
    }

    func stop() {
        observationSessionID = nil
        observations = nil
        refreshTask?.cancel()
        refreshTask = nil
        _ = generations.begin(.catalogRefresh)
    }

    private func handleConnectionChange(for sessionID: UUID) {
        // Notification delivery can already be queued when stop() removes the
        // observer. Reject that work, including work from an earlier start()
        // that arrives after a fast stop/start cycle.
        guard observationSessionID == sessionID else { return }
        scheduleCatalogRefresh()
    }

    func begin(_ domain: CaptureDeviceOperationDomain) -> CaptureDeviceOperationToken {
        generations.begin(domain)
    }

    func isCurrent(_ token: CaptureDeviceOperationToken) -> Bool {
        generations.isCurrent(token)
    }

    func scheduleCatalogRefresh() {
        refreshTask?.cancel()
        let operation = generations.begin(.catalogRefresh)
        let delays = refreshDelays
        refreshTask = Task { @MainActor [weak self] in
            // USB cameras and iOS screen-capture endpoints can announce their
            // underlying AV device before every media endpoint is queryable.
            // The cumulative delays intentionally preserve the existing burst.
            for delay in delays {
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                }
                guard let self,
                      !Task.isCancelled,
                      self.generations.isCurrent(operation) else { return }
                self.refreshCatalog()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
