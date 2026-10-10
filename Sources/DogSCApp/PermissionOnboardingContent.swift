import AppKit
import SwiftUI

enum PermissionOnboardingStyle {
    static let size = NSSize(width: 640, height: 460)
    static let background = RecorderStyle.canvasNSColor
    static let ink = RecorderStyle.ink
    static let muted = RecorderStyle.muted
    static let line = RecorderStyle.chrome.opacity(0.08)
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
                    .foregroundStyle(RecorderStyle.ink)
            }
            .opacity(presentation.isIntroAnimating ? 0 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text("准备好录制").font(.appUI(size: 26, weight: .semibold))
                    .foregroundStyle(RecorderStyle.ink)
                Text("完成以下授权，开始录制")
                    .font(.appUI(size: 14)).foregroundStyle(PermissionOnboardingStyle.muted)
            }
            .padding(.top, 18)
            .modifier(introReveal(0))

            VStack(spacing: 0) {
                permissionRow(.screenRecording)
                    .firstUseTourTarget("permission.screen", in: .permissions, highlight: .rounded(15, corners: .top))
                Rectangle().fill(PermissionOnboardingStyle.line).frame(height: 0.5).padding(.horizontal, 18)
                permissionRow(.accessibility)
                    .firstUseTourTarget("permission.pointer", in: .permissions, highlight: .rounded(15, corners: .bottom))
            }
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(RecorderStyle.base)
                    .shadow(color: RecorderStyle.lift.opacity(0.875), radius: 14, y: 6)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(
                        LinearGradient(
                            colors: [RecorderStyle.edgeTop, RecorderStyle.edgeBottom],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
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
                        Image(systemName: "arrow.right")
                    }
                    .font(.appUI(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 34)
                }
                .buttonStyle(PermissionActionButtonStyle(primary: true, focused: isEntryButtonFocused))
                .focused($isEntryButtonFocused).focusEffectDisabled()
                .firstUseTourTarget("permission.finish", in: .permissions, highlight: .rounded(10))
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
        Label("返回后自动检查", systemImage: "checkmark.circle")
    }

    private var optionalPermissionNote: some View {
        Label("摄像头和麦克风在启用时再授权", systemImage: "video")
    }

    private func permissionRow(_ permission: RequiredRecordingPermissionKind) -> some View {
        let granted = permission.isGranted(in: model)
        return HStack(spacing: 14) {
            Image(systemName: permission.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(RecorderStyle.ink)
                .frame(width: 40, height: 40)
                .background(RecorderStyle.chrome.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(permission.title).font(.appUI(size: 14, weight: .semibold))
                    .foregroundStyle(RecorderStyle.ink)
                Text(permission.purpose).font(.appUI(size: 12))
                    .foregroundStyle(PermissionOnboardingStyle.muted)
            }
            Spacer(minLength: 12)
            if granted {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.appUI(size: 12, weight: .medium))
                    .foregroundStyle(RecorderStyle.positiveInk)
                    .frame(width: 92, height: 34)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
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
        .animation(SpringMotion.fluid, value: granted)
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
            .animation(animates ? .spring(response: 0.62, dampingFraction: 0.86)
                .delay(Double(order) * 0.07) : nil, value: isShown)
    }
}

private struct PermissionActionButtonStyle: ButtonStyle {
    var primary = false
    var focused = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(primary ? RecorderStyle.onPrimary : RecorderStyle.ink)
            .background(
                primary ? RecorderStyle.primaryFill.opacity(configuration.isPressed ? 0.82 : (hovered ? 1.0 : 0.94))
                    : RecorderStyle.chrome.opacity(configuration.isPressed ? 0.16 : (hovered ? 0.14 : 0.08)),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(focused ? RecorderStyle.chrome.opacity(0.6) : (primary ? Color.clear : RecorderStyle.chrome.opacity(0.12)),
                                  lineWidth: focused ? 1.5 : 0.75)
            }
            .shadow(color: .black.opacity(configuration.isPressed ? 0 : 0.2), radius: 3, y: 1)
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
                .background(RecorderStyle.chrome.opacity(hovered ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 15))
                .shadow(color: RecorderStyle.lift, radius: 6, y: 3)
                .onHover { hovered = $0 }
            VStack(alignment: .leading, spacing: 7) {
                Text("找不到 DogSC？").font(.appUI(size: 15, weight: .semibold))
                    .foregroundStyle(RecorderStyle.ink)
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
                .fill(RecorderStyle.base)
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(RecorderStyle.chrome.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: RecorderStyle.lift, radius: 10, y: 4)
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
