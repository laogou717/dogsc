import SwiftUI

/// The same full-width native first-click target as the recorder toolbar.
/// Labels and glyphs are visual only; one target owns the entire row.
struct RecorderSaveActionRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var enabled = true
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.appUI(size: 16)).frame(width: 20)
                Text(appLocalized(title)).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail {
                    Text(appLocalized(detail)).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                } else {
                    Image(systemName: "chevron.right").font(.appUI(size: 10, weight: .medium)).foregroundStyle(RecorderStyle.muted)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 38)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.13), value: pressed)
            .allowsHitTesting(false).accessibilityHidden(true)
            RecorderActionTrigger(action: action, accessibilityLabel: appLocalized(title), isEnabled: enabled,
                                  cornerRadius: 10, highlightOpacity: 0.055, onPressChange: { pressed = $0 })
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Fixed leading labels and a shared trailing switch edge; native Toggle keeps
/// keyboard/accessibility semantics and makes the whole row clickable.
struct RecorderSaveToggleRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(appLocalized(title)).font(.appUI(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small).tint(RecorderStyle.mint)
        .frame(maxWidth: .infinity, minHeight: 32)
    }
}
