import AppKit
import Foundation
import RecorderCore

/// The single display-identity policy used at every capture boundary.
///
/// A caller that supplies an ID has selected a concrete privacy boundary. That
/// identity must never degrade to another display. Default selection is allowed
/// only when no ID was requested explicitly.
enum CaptureDisplayResolver {
    static func resolve<Candidate>(
        requestedID: UInt32?,
        candidates: [Candidate],
        candidateID: (Candidate) -> UInt32?,
        preferredDefaultID: UInt32?
    ) -> Candidate? {
        if let requestedID {
            return candidates.first { candidateID($0) == requestedID }
        }
        if let preferredDefaultID,
           let preferred = candidates.first(where: {
               candidateID($0) == preferredDefaultID
           }) {
            return preferred
        }
        return candidates.first { candidateID($0) != nil }
    }
}

struct CaptureDisplayIdentity: Equatable, Sendable {
    let id: UInt32
    let name: String
}

struct CaptureAreaSelectionResult: Equatable, Sendable {
    let display: CaptureDisplayIdentity
    let rect: NormalizedRect
}

enum CaptureAreaSelectionOutcome: Equatable, Sendable {
    case selected(CaptureAreaSelectionResult)
    case cancelled
    case displayUnavailable(requestedID: UInt32?)
}

@MainActor
enum AppKitCaptureDisplayResolver {
    static func resolveScreen(requestedID: UInt32?) -> NSScreen? {
        CaptureDisplayResolver.resolve(
            requestedID: requestedID,
            candidates: NSScreen.screens,
            candidateID: displayID(for:),
            preferredDefaultID: NSScreen.main.flatMap(displayID(for:))
        )
    }

    static func identity(for screen: NSScreen) -> CaptureDisplayIdentity? {
        guard let id = displayID(for: screen) else { return nil }
        return CaptureDisplayIdentity(id: id, name: screen.localizedName)
    }

    static func displayID(for screen: NSScreen) -> UInt32? {
        (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
    }
}
