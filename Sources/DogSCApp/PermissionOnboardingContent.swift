import AppKit
import SwiftUI

enum PermissionOnboardingStyle {
    static let size = NSSize(width: 640, height: 460)
    // The editor's palette: neutral ground, white card, ink type.
    static let background = NSColor(EditorTheme.backgroundDeep)
    static let ink = EditorTheme.primaryText
    static let muted = EditorTheme.secondaryText
    static let line = EditorTheme.hairline
    static let card = EditorTheme.panelRaised
    static let brandInset = CGPoint(x: 36, y: 34)
    static let brandSize: CGFloat = 32
    static let cardRadius: CGFloat = 12
    static let buttonRadius: CGFloat = 8
}

/// The same live permission page sits underneath the introduction from its
/// first frame. The animation never renders or owns a second set of controls.
struct RequiredRecordingPermissionView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: PermissionOnboardingPresentation
    var isReview = false
    var onContinue: (() -> Void)?
    var onOpenSettings: ((RequiredRecordingPermissionKind) -> Void)?
    @FocusState private var focusedPermission: RequiredRecordingPermissionKind?
    @FocusState private var isEntryButtonFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high)
                    .frame(width: PermissionOnboardingStyle.brandSize, height: PermissionOnboardingStyle.brandSize)
                Text("DogSC").font(.appUI(size: 15, weight: .semibold))
                    .foregroundStyle(PermissionOnboardingStyle.ink)
            }
            .opacity(presentation.isIntroAnimating ? 0 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text("准备好录制").font(.appUI(size: 26, weight: .semibold))
                    .foregroundStyle(PermissionOnboardingStyle.ink)
                Text("完成以下授权，开始录制")
                    .font(.appUI(size: 14)).foregroundStyle(PermissionOnboardingStyle.muted)
            }
            .padding(.top, 18)
            .modifier(introReveal(0))

            VStack(spacing: 0) {
                permissionRow(.screenRecording)
                    .firstUseTourTarget("permission.screen", in: .permissions, highlight: .rounded(12, corners: .top))
                Rectangle().fill(PermissionOnboardingStyle.line).frame(height: 0.5).padding(.horizontal, 18)
                permissionRow(.accessibility)
                    .firstUseTourTarget("permission.pointer", in: .permissions, highlight: .rounded(12, corners: .bottom))
            }
            .background {
                RoundedRectangle(cornerRadius: PermissionOnboardingStyle.cardRadius, style: .continuous)
                    .fill(PermissionOnboardingStyle.card)
                    .shadow(color: EditorTheme.contactShadow, radius: 1, y: 0.5)
                    .shadow(color: EditorTheme.ambientShadow, radius: 12, y: 4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: PermissionOnboardingStyle.cardRadius, style: .continuous)
                    .strokeBorder(EditorTheme.hairline, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(.top, 22)
            .modifier(introReveal(1))

            permissionNotes.padding(.top, 20)
                .modifier(introReveal(2))

            Spacer(minLength: 18)
            if model.hasRequiredRecordingPermissions {
                Button {
                    isEntryButtonFocused = false
                    if let onContinue { onContinue() }
                    else { model.finishRequiredPermissionOnboarding() }
                } label: {
                    HStack(spacing: 8) {
                        Text(isReview ? appLocalized("完成") : appLocalized("进入 DogSC"))
                        EditorSymbol("arrow.right")
                    }
                    .font(.appUI(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(PermissionActionButtonStyle(primary: true, focused: isEntryButtonFocused))
                .focused($isEntryButtonFocused).focusEffectDisabled()
                .firstUseTourTarget("permission.finish", in: .permissions, highlight: .rounded(8))
                .modifier(introReveal(3))
            }
        }
        .padding(.horizontal, PermissionOnboardingStyle.brandInset.x)
        .padding(.top, PermissionOnboardingStyle.brandInset.y)
        .padding(.bottom, 28)
        .frame(width: PermissionOnboardingStyle.size.width, height: PermissionOnboardingStyle.size.height)
        .allowsHitTesting(!presentation.isIntroAnimating)
        // The AppKit window uses a full-size content view. Its fixed page
        // already reserves the titlebar in brandInset; applying that safe
        // area again pushes the page below its frame and clips footer space.
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(PermissionOnboardingStyle.ink)
        .background(Color(nsColor: PermissionOnboardingStyle.background))
        .appControlFocusAppearance()
        .firstUseTour(.permissions)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.permissionGate)
        .onChange(of: model.permissionTourAccess, initial: true) { _, access in
            FirstUseTourController.controller(for: .permissions).updatePermissions(access)
        }
        .task(id: presentation.isTourReady) {
            guard presentation.isTourReady else { return }
            if model.showsRequiredPermissionGate { model.beginRequiredPermissionOnboardingIfNeeded() }
            while !Task.isCancelled, presentation.isTourReady {
                if model.phase == .setup {
                    await model.verifyRequiredRecordingPermissions()
                } else if isReview {
                    model.refreshRequiredRecordingPermissions()
                } else { return }
                // Checking permissions may update the visible state, but must
                // never activate the recorder while System Settings owns focus.
                // The ready page's explicit Continue action owns that handoff.
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
    }

    private func introReveal(_ order: Int) -> PermissionIntroReveal {
        PermissionIntroReveal(isShown: presentation.introStage >= .settling,
                              animates: presentation.animatesIntro, order: order)
    }

    private var permissionNotes: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                automaticCheckNote
                optionalPermissionNote
            }
            .fixedSize()
            VStack(alignment: .leading, spacing: 6) {
                automaticCheckNote
                optionalPermissionNote
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.appUI(size: 12))
        .foregroundStyle(PermissionOnboardingStyle.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var automaticCheckNote: some View {
        EditorSymbolLabel("返回后自动检查", systemImage: "checkmark.circle")
    }

    private var optionalPermissionNote: some View {
        EditorSymbolLabel("摄像头和麦克风在启用时再授权", systemImage: "video")
    }

    private func permissionRow(_ permission: RequiredRecordingPermissionKind) -> some View {
        let granted = permission.isGranted(in: model)
        return HStack(spacing: 14) {
            EditorSymbol(permission.systemImage, size: 17)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(PermissionOnboardingStyle.ink)
                .frame(width: 40, height: 40)
                .background(EditorTheme.controlWell, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title).font(.appUI(size: 14, weight: .semibold))
                    .foregroundStyle(PermissionOnboardingStyle.ink)
                Text(permission.purpose).font(.appUI(size: 12))
                    .foregroundStyle(PermissionOnboardingStyle.muted)
            }
            Spacer(minLength: 12)
            if granted {
                EditorSymbolLabel("已授权", systemImage: "checkmark.circle.fill")
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(EditorTheme.success)
                    .frame(width: 92, height: 34)
                    .transition(.opacity)
            } else {
                Button {
                    focusedPermission = nil
                    NSApplication.shared.keyWindow?.makeFirstResponder(nil)
                    if let onOpenSettings { onOpenSettings(permission) }
                    else { model.openRequiredPermissionSettings(permission) }
                } label: {
                    Text("打开设置").font(.appUI(size: 12, weight: .medium))
                        .frame(width: 92, height: 34)
                }
                .buttonStyle(PermissionActionButtonStyle(focused: focusedPermission == permission))
                .focused($focusedPermission, equals: permission).focusEffectDisabled()
                .accessibilityLabel("打开\(permission.title)设置")
            }
        }
        .padding(.horizontal, 18).frame(height: 76)
        .animation(SpringMotion.fade, value: granted)
        .accessibilityElement(children: .contain)
    }
}

/// Page content waits beneath the opening title, then rises in reading order
/// as the brand docks into the header. Offsets never change the laid-out
/// frames that the first-use tour measures.
private struct PermissionIntroReveal: ViewModifier {
    let isShown: Bool
    let animates: Bool
    let order: Int

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown ? 0 : 16)
            .animation(animates ? .timingCurve(0.2, 0, 0, 1, duration: 0.42)
                .delay(Double(order) * 0.06) : nil, value: isShown)
    }
}

private struct PermissionActionButtonStyle: ButtonStyle {
    var primary = false
    var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: PermissionOnboardingStyle.buttonRadius, style: .continuous)
        return configuration.label
            .foregroundStyle(primary ? EditorTheme.onAccentFill : EditorTheme.primaryText)
            .background(primary ? EditorTheme.accent : EditorTheme.controlWell, in: shape)
            .overlay {
                shape.fill(Color.black.opacity(configuration.isPressed ? 0.12 : hovered ? 0.06 : 0))
            }
            .overlay {
                shape.strokeBorder(EditorTheme.accent.opacity(focused ? 1 : 0), lineWidth: 2)
            }
            .contentShape(shape)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PermissionDragAssistantView: View {
    let permission: RequiredRecordingPermissionKind
    let applicationURL: URL
    let onApplicationDragEnded: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 18) {
            DraggableApplicationIcon(applicationURL: applicationURL, onDragEnded: onApplicationDragEnded)
                .frame(width: 72, height: 72)
                .background(EditorTheme.chrome(hovered ? 0.1 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onHover { hovered = $0 }
            VStack(alignment: .leading, spacing: 7) {
                Text("找不到 DogSC？").font(.appUI(size: 15, weight: .semibold))
                    .foregroundStyle(PermissionOnboardingStyle.ink)
                Text(String(format: appLocalized("把图标拖入“%@”列表，再打开开关。"), permission.settingsListName))
                    .font(.appUI(size: 13)).foregroundStyle(PermissionOnboardingStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity).frame(height: 116)
        .foregroundStyle(PermissionOnboardingStyle.ink)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(PermissionOnboardingStyle.card)
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(EditorTheme.hairline, lineWidth: 1)
                }
                .shadow(color: EditorTheme.ambientShadow, radius: 12, y: 4)
        }
        .appControlFocusAppearance()
    }
}

@MainActor
extension AppModel {
    var permissionTourAccess: PermissionTourFlow.Access {
        PermissionTourFlow.Access(screen: hasScreenRecordingPermissionForOnboarding,
                                  accessibility: hasAccessibilityPermission)
    }
}
