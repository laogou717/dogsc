import AppKit
import Combine

/// Owns the editor-facing File/Edit main-menu entries.
///
/// The app ships without a WindowGroup scene, so no standard Edit menu ever
/// existed and undo/redo was reachable only through the toolbar buttons.
/// Menu items here validate on demand against the live UndoManager (and an
/// editable text field's own undo manager first), mirroring how the Delete
/// key monitor already respects text editing.
@MainActor
final class EditorMenuBridge: NSObject {
    static let shared = EditorMenuBridge()

    private let fileMenuIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu"
    )
    private let editMenuIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.edit-menu"
    )

    /// The current editor generation's undo manager, attached by EditorView
    /// for exactly as long as that editor is alive.
    private weak var editorUndoManager: UndoManager?
    private(set) var isEditorActive = false

    /// EditorView subscribes and presents its export sheet; the menu must not
    /// reach into SwiftUI state directly.
    let exportRequest = PassthroughSubject<Void, Never>()

    func attachEditor(undoManager: UndoManager?) {
        editorUndoManager = undoManager
        isEditorActive = true
    }

    func detachEditor(undoManager: UndoManager?) {
        guard editorUndoManager === undoManager else { return }
        editorUndoManager = nil
        isEditorActive = false
    }

    func installMainMenuItems() {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }
        if !mainMenu.items.contains(where: { $0.identifier == fileMenuIdentifier }) {
            let fileMenu = NSMenu(title: "文件")
            fileMenu.addItem(makeItem(
                title: "打开项目…",
                action: #selector(openProjectFromMenu(_:)),
                keyEquivalent: "o"
            ))
            fileMenu.addItem(makeItem(
                title: "导出成片…",
                action: #selector(exportFromMenu(_:)),
                keyEquivalent: "e"
            ))
            let root = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
            root.identifier = fileMenuIdentifier
            root.submenu = fileMenu
            mainMenu.insertItem(root, at: 1)
        }
        if !mainMenu.items.contains(where: { $0.identifier == editMenuIdentifier }) {
            let editMenu = NSMenu(title: "编辑")
            editMenu.addItem(makeItem(
                title: "撤销",
                action: #selector(undoFromMenu(_:)),
                keyEquivalent: "z"
            ))
            editMenu.addItem(makeItem(
                title: "重做",
                action: #selector(redoFromMenu(_:)),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            ))
            let root = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
            root.identifier = editMenuIdentifier
            root.submenu = editMenu
            mainMenu.insertItem(root, at: 2)
        }
    }

    private func makeItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    @objc private func openProjectFromMenu(_ sender: NSMenuItem) {
        WindowCoordinator.openProjectFromMenu()
    }

    @objc private func exportFromMenu(_ sender: NSMenuItem) {
        exportRequest.send()
    }

    @objc private func undoFromMenu(_ sender: NSMenuItem) {
        if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
           textView.isEditable {
            textView.undoManager?.undo()
            return
        }
        editorUndoManager?.undo()
    }

    @objc private func redoFromMenu(_ sender: NSMenuItem) {
        if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
           textView.isEditable {
            textView.undoManager?.redo()
            return
        }
        editorUndoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoFromMenu(_:)):
            if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable {
                menuItem.title = "撤销"
                return textView.undoManager?.canUndo ?? false
            }
            if let name = editorUndoManager?.undoActionName, !name.isEmpty {
                menuItem.title = "撤销“\(name)”"
            } else {
                menuItem.title = "撤销"
            }
            return editorUndoManager?.canUndo ?? false
        case #selector(redoFromMenu(_:)):
            if let textView = NSApplication.shared.keyWindow?.firstResponder as? NSTextView,
               textView.isEditable {
                menuItem.title = "重做"
                return textView.undoManager?.canRedo ?? false
            }
            if let name = editorUndoManager?.redoActionName, !name.isEmpty {
                menuItem.title = "重做“\(name)”"
            } else {
                menuItem.title = "重做"
            }
            return editorUndoManager?.canRedo ?? false
        case #selector(exportFromMenu(_:)):
            return isEditorActive
        case #selector(openProjectFromMenu(_:)):
            return true
        default:
            return true
        }
    }
}
