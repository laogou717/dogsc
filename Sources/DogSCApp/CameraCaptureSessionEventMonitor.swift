import AVFoundation
import Foundation

enum CameraCaptureSessionEvent: @unchecked Sendable {
    case runtimeError(NSError)
    case interrupted
    case interruptionEnded
}

/// Converts AVCaptureSession's notification-only failure channel into one
/// recorder-owned event stream. Without this bridge a camera can stop while
/// the screen writer keeps running, producing tracks that silently diverge.
final class CameraCaptureSessionEventMonitor {
    private var observers: [NSObjectProtocol] = []

    init(
        session: AVCaptureSession,
        handler: @escaping @Sendable (CameraCaptureSessionEvent) -> Void
    ) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
                ?? NSError(
                    domain: AVFoundationErrorDomain,
                    code: AVError.unknown.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "摄像头会话发生未知运行错误"]
                )
            handler(.runtimeError(error))
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { _ in
            handler(.interrupted)
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { _ in
            handler(.interruptionEnded)
        })
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
    }
}
