import AppKit
import SwiftUI

/// The only recorder surface created before required screen/accessibility
/// authorization is complete. Capture selectors deliberately do not exist in
/// this hierarchy, so an area mask can never precede the permission flow.
struct RequiredRecordingPermissionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.white)

            VStack(alignment: .leading, spacing: 3) {
                Text("开始前需要完成授权")
                    .font(.system(size: 13, weight: .semibold))
                Text("录屏和辅助功能就绪后，才会显示录制工具。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            permissionStatus(
                title: "屏幕录制",
                isGranted: model.hasVerifiedScreenRecordingPermission
                    || (model.hasCompletedRequiredPermissionOnboarding
                        && model.captureReadiness.hasScreenRecordingPermission)
            )
            permissionStatus(
                title: "辅助功能",
                isGranted: model.hasAccessibilityPermission
            )

            Button(action: model.continueRequiredPermissionOnboarding) {
                HStack(spacing: 6) {
                    if model.isCheckingRequiredPermissions {
                        ProgressView().controlSize(.mini)
                    }
                    Text(model.requiredPermissionActionTitle)
                        .fontWeight(.semibold)
                }
                .frame(width: 132, height: 36)
                .background(Color.white, in: Capsule())
                .foregroundStyle(Color.black)
            }
            .buttonStyle(.plain)
            .disabled(model.isCheckingRequiredPermissions)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .frame(width: setupWindowWidth(), height: 64)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(setupBarBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(RecorderAccessibilityID.permissionGate)
        .onAppear(perform: model.beginRequiredPermissionOnboardingIfNeeded)
    }

    private func permissionStatus(title: String, isGranted: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isGranted ? Color.green : Color.secondary)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .frame(width: 86, alignment: .leading)
    }
}
