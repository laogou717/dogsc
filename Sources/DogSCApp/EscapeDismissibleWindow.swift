import AppKit

/// Auxiliary windows share the close button's delegate and persistence path.
/// Field editors and attached sheets handle Escape before the window responder.
final class EscapeDismissibleWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        guard attachedSheet == nil else {
            super.cancelOperation(sender)
            return
        }
        performClose(sender)
    }
}
