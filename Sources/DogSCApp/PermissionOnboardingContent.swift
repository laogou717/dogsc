import AppKit
import SwiftUI

enum PermissionOnboardingStyle {
    static let size = NSSize(width: 640, height: 460)
    static let background = NSColor(red: 0.975, green: 0.979, blue: 0.982, alpha: 1)
    static let ink = Color(red: 0.16, green: 0.18, blue: 0.19)
    static let muted = Color(red: 0.46, green: 0.49, blue: 0.51)
    static let line = Color.black.opacity(0.075)
    static let brandInset = CGPoint(x: 36, y: 34)
    static let brandSize: CGFloat = 32
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
            }
            .opacity(presentation.isIntroAnimating ? 0 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text("准备好录制").font(.appUI(size: 26, weight: .semibold))
                Text("完成以下授权，开始录制")
                    .font(.appUI(size: 14)).foregroundStyle(PermissionOnboardingStyle.muted)
            }
            .padding(.top, 18)

            VStack(spacing: 0) {
                permissionRow(.screenRecording)
                    .firstUseTourTarget("permission.screen", in: .permissions, highlight: .rounded(15, corners: .top))
                Rectangle().fill(PermissionOnboardingStyle.line).frame(height: 0.5).padding(.horizontal, 18)
                permissionRow(.accessibility)
                    .firstUseTourTarget("permission.pointer", in: .permissions, highlight: .rounded(15, corners: .bottom))
            }
            .background(.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 15))
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(PermissionOnboardingStyle.line, lineWidth: 0.75)
                    .allowsHitTesting(false)
            }
            .padding(.top, 22)

            VStack(alignment: .leading, spacing: 9) {
                Label("返回后自动检查", systemImage: "checkmark.circle")
                Label("摄像头和麦克风在启用时再授权", systemImage: "video")
            }
            .font(.appUI(size: 12))
            .foregroundStyle(PermissionOnboardingStyle.muted)
            .padding(.top, 20)

            Spacer(minLength: 10)
            if model.hasRequiredRecordingPermissions {
                Button {
                    isEntryButtonFocused = false
                    if let onContinue { onContinue() }
                    else { model.finishRequiredPermissionOnboarding() }
                } label: {
                    HStack(spacing: 8) {
                        Text(isReview ? appLocalized("完成") : appLocalized("进入 DogSC"))
                        Image(systemName: "arrow.right")
                    }
                    .font(.appUI(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(PermissionActionButtonStyle(primary: true, focused: isEntryButtonFocused))
                .focused($isEntryButtonFocused).focusEffectDisabled()
                .firstUseTourTarget("permission.finish", in: .permissions, highlight: .rounded(10))
            }
        }
        .padding(.horizontal, PermissionOnboardingStyle.brandInset.x)
        .padding(.top, PermissionOnboardingStyle.brandInset.y)
        .padding(.bottom, 24)
        .frame(width: PermissionOnboardingStyle.size.width, height: PermissionOnboardingStyle.size.height)
        .foregroundStyle(PermissionOnboardingStyle.ink)
        .background(Color(nsColor: PermissionOnboardingStyle.background))
        .preferredColorScheme(.light)
        .appControlFocusAppearance()
        .firstUseTour(.permissions, enabled: presentation.isTourReady && !presentation.isIntroAnimating)
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

    private func permissionRow(_ permission: RequiredRecordingPermissionKind) -> some View {
        let granted = permission.isGranted(in: model)
        return HStack(spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.appUI(size: 23, weight: .regular)).frame(width: 30)
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title).font(.appUI(size: 14, weight: .semibold))
                Text(permission.purpose).font(.appUI(size: 12))
                    .foregroundStyle(PermissionOnboardingStyle.muted)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.19, green: 0.57, blue: 0.41))
                    .frame(width: 92, height: 34)
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
        .accessibilityElement(children: .contain)
    }
}

private struct PermissionActionButtonStyle: ButtonStyle {
    var primary = false
    var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? .white : PermissionOnboardingStyle.ink)
            .background(
                primary ? Color(white: configuration.isPressed ? 0.13 : (hovered ? 0.23 : 0.18))
                    : Color(white: configuration.isPressed ? 0.91 : (hovered ? 0.95 : 0.985)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? PermissionOnboardingStyle.ink.opacity(0.45) : PermissionOnboardingStyle.line,
                                  lineWidth: focused ? 1.5 : 0.75)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.025), radius: 2, y: 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
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
                .background(.white.opacity(hovered ? 1 : 0.64), in: RoundedRectangle(cornerRadius: 15))
                .shadow(color: .black.opacity(hovered ? 0.08 : 0.04), radius: 6, y: 3)
                .onHover { hovered = $0 }
            VStack(alignment: .leading, spacing: 7) {
                Text("找不到 DogSC？").font(.appUI(size: 15, weight: .semibold))
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
                .fill(Color(nsColor: PermissionOnboardingStyle.background))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.95), lineWidth: 0.75)
                }
        }
        .preferredColorScheme(.light)
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
