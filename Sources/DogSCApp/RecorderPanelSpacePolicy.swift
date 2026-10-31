import AppKit

/// A notch surface belongs to the display, so revealing the desktop must not
/// sweep it toward the Dock with ordinary application windows.
enum RecorderPanelSpacePolicy {
    static func collectionBehavior(isDocked: Bool) -> NSWindow.CollectionBehavior {
        let floating: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        guard isDocked else { return floating }
        return floating.union([.stationary, .canJoinAllApplications])
    }
}
