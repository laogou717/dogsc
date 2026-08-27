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
final class EditorMenuBridge: NSObject, NSMenuItemValidation {
    static let shared = EditorMenuBridge()

    private let fileMenuIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu"
    )
    private let editMenuIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.edit-menu"
    )
    private let projectMediaSeparatorIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.project-media-separator"
    )
    private let exportProjectMediaItemIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.export-project-media"
    )
    private let replaceCameraMediaItemIdentifier = NSUserInterfaceItemIdentifier(
        "cn.laogou.dogsc.file-menu.replace-camera-media"
    )

    /// The current editor generation's undo manager, attached by EditorView
    /// for exactly as long as that editor is alive.
    private weak var editorUndoManager: UndoManager?
    private(set) var isEditorActive = false

    /// EditorView subscribes and presents its export sheet; the menu must not
    /// reach into SwiftUI state directly.
    let exportRequest = PassthroughSubject<Void, Never>()
    /// AppKit cannot close the editor window while a SwiftUI sheet is still
    /// attached. Route Quit through the live editor once so it can dismiss
    /// transient panels before the normal save/termination path continues.
    let quitRequest = PassthroughSubject<Void, Never>()

    func attachEditor(undoManager: UndoManager?) {
        editorUndoManager = undoManager
        isEditorActive = true
        setEditorMenuItemsVisible(true)
    }

    func detachEditor(undoManager: UndoManager?) {
        guard editorUndoManager === undoManager else { return }
        editorUndoManager = nil
        isEditorActive = false
        setEditorMenuItemsVisible(false)
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
        installEditItems(in: mainMenu)
        removeUnavailableHelpMenu(from: mainMenu)
    }

    /// The floating recorder has no editable text, resizable document window,
    /// or full-screen surface. Leaving Edit/View/Window visible there exposes
    /// almost entirely disabled system commands. Keep those menus for the
    /// editor, where they describe real actions, and leave the recorder with
    /// only application-level and file-opening commands.
    func setEditorMenuItemsVisible(_ isVisible: Bool) {
        guard let mainMenu = NSApplication.shared.mainMenu else { return }

        mainMenu.items.first(where: {
            $0.identifier == editMenuIdentifier
        })?.isHidden = !isVisible

        if let fileMenu = mainMenu.items.first(where: {
            $0.identifier == fileMenuIdentifier
        })?.submenu {
            fileMenu.items.first(where: {
                $0.action == #selector(exportFromMenu(_:))
            })?.isHidden = !isVisible
            for identifier in [
                projectMediaSeparatorIdentifier,
                exportProjectMediaItemIdentifier,
                replaceCameraMediaItemIdentifier,
            ] {
                fileMenu.items.first(where: {
                    $0.identifier == identifier
                })?.isHidden = !isVisible
            }
        }

        let fullScreenAction = #selector(NSWindow.toggleFullScreen(_:))
        mainMenu.items.first(where: { root in
            root.submenu !== NSApplication.shared.windowsMenu
                && (root.submenu?.items.contains(where: {
                    $0.action == fullScreenAction
                }) == true
                    || ["显示", "View"].contains(root.title)
                    || ["显示", "View"].contains(root.submenu?.title ?? ""))
        })?.isHidden = !isVisible

        if let windowsMenu = NSApplication.shared.windowsMenu {
            mainMenu.items.first(where: {
                $0.submenu === windowsMenu
            })?.isHidden = !isVisible
        }
    }

    /// The app does not ship an Apple Help Book. Leaving SwiftUI's generated
    /// `showHelp:` item in place therefore ends in a system "help not found"
    /// alert. Do not expose a dead menu until the product has real in-app help.
    private func removeUnavailableHelpMenu(from mainMenu: NSMenu) {
        let showHelpSelector = #selector(NSApplication.showHelp(_:))
        let generatedHelpRoots = mainMenu.items.dropFirst().filter { root in
            guard let submenu = root.submenu else { return false }
            return submenu.items.contains(where: { $0.action == showHelpSelector })
                || submenu.title == "帮助"
        }
        NSApplication.shared.helpMenu = nil
        for root in generatedHelpRoots {
            mainMenu.removeItem(root)
        }
    }

    /// SwiftUI already provides the native Edit menu (cut/copy/paste/select
    /// all). Reuse its undo/redo rows instead of inserting a second top-level
    /// "编辑" menu beside it.
    private func installEditItems(in mainMenu: NSMenu) {
        let undoSelector = Selector(("undo:"))
        let redoSelector = Selector(("redo:"))
        let existingRoot = mainMenu.items.first { root in
            guard let submenu = root.submenu else { return false }
            return root.identifier == editMenuIdentifier
                || submenu.items.contains(where: { item in
                    item.action == undoSelector
                        || item.action == redoSelector
                        || item.action == #selector(undoFromMenu(_:))
                        || item.action == #selector(redoFromMenu(_:))
                })
        }

        let root: NSMenuItem
        let editMenu: NSMenu
        if let existingRoot, let existingMenu = existingRoot.submenu {
            root = existingRoot
            editMenu = existingMenu
        } else {
            editMenu = NSMenu(title: "编辑")
            root = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
            root.submenu = editMenu
            mainMenu.insertItem(root, at: min(2, mainMenu.items.count))
        }
        root.identifier = editMenuIdentifier

        let undoItem = editMenu.items.first { item in
            item.action == undoSelector || item.action == #selector(undoFromMenu(_:))
        } ?? {
            let item = makeItem(
                title: "撤销",
                action: #selector(undoFromMenu(_:)),
                keyEquivalent: "z"
            )
            editMenu.insertItem(item, at: 0)
            return item
        }()
        configure(
            undoItem,
            title: "撤销",
            action: #selector(undoFromMenu(_:)),
            keyEquivalent: "z",
            modifiers: [.command]
        )

        let redoItem = editMenu.items.first { item in
            item.action == redoSelector || item.action == #selector(redoFromMenu(_:))
        } ?? {
            let item = makeItem(
                title: "重做",
                action: #selector(redoFromMenu(_:)),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
            editMenu.insertItem(item, at: min(1, editMenu.items.count))
            return item
        }()
        configure(
            redoItem,
            title: "重做",
            action: #selector(redoFromMenu(_:)),
            keyEquivalent: "z",
            modifiers: [.command, .shift]
        )
    }

    private func configure(
        _ item: NSMenuItem,
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) {
        item.title = title
        item.target = self
        item.action = action
        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = modifiers
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
