import AppKit
import SwiftUI

let permissionOnboardingWindowIdentifier = NSUserInterfaceItemIdentifier(
    "cn.laogou.dogsc.permission-onboarding"
)

enum RequiredRecordingPermissionKind: String, CaseIterable, Identifiable, Sendable {
    case screenRecording
    case accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording: "录制显示器、窗口或选定区域"
        case .accessibility: "记录鼠标移动与点击"
        }
    }

    var systemImage: String {
        switch self {
        case .screenRecording: "display"
        case .accessibility: "accessibility"
        }
    }

    var settingsSection: String {
        switch self {
        case .screenRecording: "Privacy_ScreenCapture"
        case .accessibility: "Privacy_Accessibility"
        }
    }

    var settingsListName: String {
        switch self {
        case .screenRecording: "屏幕与系统音频录制"
        case .accessibility: "辅助功能"
        }
    }

    @MainActor
    func isGranted(in model: AppModel) -> Bool {
        switch self {
        case .screenRecording: model.hasScreenRecordingPermissionForOnboarding
        case .accessibility: model.hasAccessibilityPermission
        }
    }
}

/// A real first-run page. Capture selectors do not exist in this hierarchy,
/// so masks and recording controls cannot appear before required permissions.
struct RequiredRecordingPermissionView: View {
    @ObservedObject var model: AppModel
    @State private var waitsForExplicitStart = false

    var body: some View {
        VStack(spacing: 0) {
            header

            VStack(spacing: 12) {
                ForEach(RequiredRecordingPermissionKind.allCases) { permission in
                    permissionRow(permission)
                }
            }
            .padding(.top, 28)

            HStack(spacing: 8) {
                Image(systemName: "video.badge.ellipsis")
                    .foregroundStyle(.secondary)
                Text("摄像头和麦克风只会在你启用它们时询问。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 18)

            Spacer(minLength: 24)

            footer
        }
        .padding(.horizontal, 42)
        .padding(.top, 44)
        .padding(.bottom, 30)
        .frame(width: 640, height: 460)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.095, green: 0.10, blue: 0.115),
                    Color(red: 0.052, green: 0.055, blue: 0.065),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.permissionGate)
        .task {
            // Existing development installs may already have both TCC grants
            // while this new onboarding has never been completed. Keep that
            // all-green page visible until the user chooses to enter; a real
            // first-time flow that starts with a missing grant advances
            // automatically once the final permission becomes ready.
            waitsForExplicitStart = model.captureReadiness.hasScreenRecordingPermission
                && model.hasAccessibilityPermission
                && !model.hasCompletedRequiredPermissionOnboarding
            model.beginRequiredPermissionOnboardingIfNeeded()

            while !Task.isCancelled, model.showsRequiredPermissionGate {
                await model.verifyRequiredRecordingPermissions()
                if model.hasRequiredRecordingPermissions,
                   !waitsForExplicitStart {
                    model.finishRequiredPermissionOnboarding()
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(0.35), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 7) {
                Text("准备好录制")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("完成两项必需权限，\(AppIdentity.displayName) 才会显示录制工具。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private func permissionRow(
        _ permission: RequiredRecordingPermissionKind
    ) -> some View {
        let granted = permission.isGranted(in: model)
        return HStack(spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.orange)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.green)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.green.opacity(0.10), in: Capsule())
                    .accessibilityLabel("\(permission.title)已授权")
            } else {
                Button("打开系统设置") {
                    model.openRequiredPermissionSettings(permission)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(white: 0.88))
                .foregroundStyle(Color.black)
                .controlSize(.regular)
                .accessibilityLabel("打开\(permission.title)设置")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var footer: some View {
        if model.hasRequiredRecordingPermissions {
            Button {
                model.finishRequiredPermissionOnboarding()
            } label: {
                Label("进入 \(AppIdentity.displayName)", systemImage: "arrow.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.white)
            .foregroundStyle(Color.black)
            .accessibilityHint("关闭首次使用页并显示录制工具")
        } else {
            HStack(spacing: 9) {
                if model.isCheckingRequiredPermissions {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                }
                Text("从系统设置返回后会自动检查，无需再点击“检测”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: 42)
        }
    }
}

struct PermissionDragAssistantView: View {
    let permission: RequiredRecordingPermissionKind
    let applicationURL: URL

    var body: some View {
        HStack(spacing: 16) {
            DraggableApplicationIcon(applicationURL: applicationURL)
                .frame(width: 72, height: 72)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
                .overlay {
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.75)
                }

            VStack(alignment: .leading, spacing: 7) {
                Text("在列表里找不到 \(AppIdentity.displayName)？")
                    .font(.system(size: 14, weight: .semibold))
                Text("把左侧图标拖到“\(permission.settingsListName)”的应用列表，再打开开关。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18)
        .frame(width: 360, height: 116)
        .background(Color(red: 0.07, green: 0.073, blue: 0.085))
    }
}

private struct DraggableApplicationIcon: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context: Context) -> ApplicationBundleDragView {
        ApplicationBundleDragView(applicationURL: applicationURL)
    }

    func updateNSView(_ nsView: ApplicationBundleDragView, context: Context) {
        nsView.applicationURL = applicationURL
    }
}

@MainActor
private final class ApplicationBundleDragView: NSView, NSDraggingSource {
    var applicationURL: URL {
        didSet {
            icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
            needsDisplay = true
        }
    }
    private var icon: NSImage
    private var isDraggingApplication = false

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        super.init(frame: .zero)
        setAccessibilityRole(.button)
        setAccessibilityLabel("可拖动的 \(AppIdentity.displayName) 应用图标")
        setAccessibilityHelp("拖到系统设置的应用列表")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon.draw(
            in: bounds.insetBy(dx: 9, dy: 9),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDraggingApplication else { return }
        isDraggingApplication = true
        let item = NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        isDraggingApplication = false
    }
}

@MainActor
final class RequiredPermissionWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let hostingController: NSHostingController<RequiredRecordingPermissionView>
    private let windowController: NSWindowController
    private let dragAssistant = PermissionDragAssistantWindowController()
    private var hasPositionedWindow = false

    init(model: AppModel) {
        self.model = model
        hostingController = NSHostingController(
            rootView: RequiredRecordingPermissionView(model: model)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        windowController = NSWindowController(window: window)
        super.init()
        window.identifier = permissionOnboardingWindowIdentifier
        window.title = "开始使用 \(AppIdentity.displayName)"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .documentWindow
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = hostingController
        window.delegate = self
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    var isVisible: Bool { windowController.window?.isVisible == true }

    func present() {
        guard let window = windowController.window else { return }
        guard !window.isVisible else { return }
        if !hasPositionedWindow {
            positionAtVisualCenter(window)
            hasPositionedWindow = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        dragAssistant.hide()
        windowController.window?.orderOut(nil)
    }

    func bringToFront() {
        guard let window = windowController.window else { return }
        if !hasPositionedWindow {
            positionAtVisualCenter(window)
            hasPositionedWindow = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showDragAssistant(for permission: RequiredRecordingPermissionKind) {
        dragAssistant.show(
            permission: permission,
            applicationURL: Bundle.main.bundleURL,
            referenceWindowFrame: windowController.window?.frame,
            referenceScreen: windowController.window?.screen
        )
    }

    private func positionAtVisualCenter(_ window: NSWindow) {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) })
            ?? window.screen
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            window.center()
            return
        }
        var frame = window.frame
        frame.origin = NSPoint(
            x: visibleFrame.midX - frame.width / 2,
            y: visibleFrame.midY - frame.height / 2
        )
        window.setFrame(frame.integral, display: false)
    }

    func refreshDragAssistantState() {
        guard let permission = dragAssistant.permission,
              permission.isGranted(in: model) else { return }
        dragAssistant.hide()
    }

    func shutdown() {
        dragAssistant.shutdown()
        windowController.window?.orderOut(nil)
        windowController.window?.contentViewController = nil
        windowController.close()
    }
}

@MainActor
private final class PermissionDragAssistantWindowController {
    private static let panelSize = NSSize(width: 360, height: 116)
    private static let attachmentGap: CGFloat = 10
    private static let screenInset: CGFloat = 12

    private var panel: NSPanel?
    private var hostingController: NSHostingController<PermissionDragAssistantView>?
    private var settingsFollowTask: Task<Void, Never>?
    private(set) var permission: RequiredRecordingPermissionKind?

    func show(
        permission: RequiredRecordingPermissionKind,
        applicationURL: URL,
        referenceWindowFrame: NSRect?,
        referenceScreen: NSScreen?
    ) {
        self.permission = permission
        let root = PermissionDragAssistantView(
            permission: permission,
            applicationURL: applicationURL
        )
        let host: NSHostingController<PermissionDragAssistantView>
        if let hostingController {
            hostingController.rootView = root
            host = hostingController
        } else {
            host = NSHostingController(rootView: root)
            hostingController = host
        }

        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: Self.panelSize),
                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "添加 \(AppIdentity.displayName)"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.tabbingMode = .disallowed
            panel.appearance = NSAppearance(named: .darkAqua)
            self.panel = panel
        }
        panel.contentViewController = host

        if let referenceWindowFrame,
           let visibleFrame = (referenceScreen ?? NSScreen.main)?.visibleFrame {
            panel.setFrame(
                attachedFrame(
                    to: referenceWindowFrame,
                    panelSize: panel.frame.size,
                    visibleFrame: visibleFrame
                ),
                display: false
            )
        }
        panel.orderFrontRegardless()
        beginFollowingSystemSettings()
    }

    func hide() {
        settingsFollowTask?.cancel()
        settingsFollowTask = nil
        permission = nil
        panel?.orderOut(nil)
    }

    func shutdown() {
        settingsFollowTask?.cancel()
        settingsFollowTask = nil
        permission = nil
        panel?.orderOut(nil)
        panel?.contentViewController = nil
        panel?.close()
        panel = nil
        hostingController = nil
    }

    private func beginFollowingSystemSettings() {
        settingsFollowTask?.cancel()
        settingsFollowTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.followSystemSettingsWindow()
                try? await Task.sleep(for: .milliseconds(120))
            }
        }
    }

    private func followSystemSettingsWindow() {
        guard let panel,
              panel.isVisible,
              let settingsFrame = Self.systemSettingsWindowFrame(),
              let screen = Self.screen(containingMostOf: settingsFrame) else { return }
        let target = attachedFrame(
            to: settingsFrame,
            panelSize: panel.frame.size,
            visibleFrame: screen.visibleFrame
        )
        guard panel.frame.origin != target.origin else { return }
        panel.setFrameOrigin(target.origin)
    }

    private func attachedFrame(
        to referenceFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect
    ) -> NSRect {
        let minimumX = visibleFrame.minX + Self.screenInset
        let maximumX = max(
            visibleFrame.maxX - panelSize.width - Self.screenInset,
            minimumX
        )
        let centeredX = referenceFrame.midX - panelSize.width / 2
        let x = min(max(centeredX, minimumX), maximumX)
        let belowY = referenceFrame.minY - panelSize.height - Self.attachmentGap
        let aboveY = referenceFrame.maxY + Self.attachmentGap
        let y: CGFloat
        if belowY >= visibleFrame.minY + Self.screenInset {
            y = belowY
        } else {
            y = min(
                aboveY,
                visibleFrame.maxY - panelSize.height - Self.screenInset
            )
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: panelSize).integral
    }

    private static func systemSettingsWindowFrame() -> NSRect? {
        guard let application = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.systempreferences"
        }),
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        let candidate = windowInfo.compactMap { info -> CGRect? in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                    == application.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 480,
                  frame.height >= 320 else { return nil }
            return frame
        }
        .max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
        guard let candidate else { return nil }

        // CGWindow bounds use a top-left global origin; AppKit windows use a
        // bottom-left origin. The primary display's top edge is their bridge.
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(
            x: candidate.minX,
            y: primaryTop - candidate.maxY,
            width: candidate.width,
            height: candidate.height
        ).integral
    }

    private static func screen(containingMostOf frame: NSRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                < rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
        }
    }
}
