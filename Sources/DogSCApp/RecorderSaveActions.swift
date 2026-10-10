import SwiftUI

/// The same full-width native first-click target as the recorder toolbar.
/// Labels and glyphs are visual only; one target owns the entire row.
struct RecorderSaveActionRow: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var enabled = true
    var showsChevron = true
    let action: () -> Void
    @State private var pressed = false

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                    .foregroundStyle(RecorderStyle.muted)
                Text(appLocalized(title)).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let detail {
                    Text(appLocalized(detail)).font(.appUI(size: 11)).foregroundStyle(RecorderStyle.muted)
                } else if showsChevron {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(RecorderStyle.faint)
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 36)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.13), value: pressed)
            .allowsHitTesting(false).accessibilityHidden(true)
            RecorderActionTrigger(action: action, accessibilityLabel: appLocalized(title), isEnabled: enabled,
                                  cornerRadius: 9, highlightOpacity: 0.05, onPressChange: { pressed = $0 })
        }
        .frame(maxWidth: .infinity, minHeight: 36)
        .opacity(enabled ? 1 : 0.4)
    }
}

/// Fixed leading labels and a shared trailing switch edge; native Toggle keeps
/// keyboard/accessibility semantics and makes the whole row clickable.
struct RecorderSaveToggleRow: View {
    let title: String
    var symbol: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).frame(width: 18)
                        .foregroundStyle(RecorderStyle.muted)
                }
                Text(appLocalized(title)).font(.appUI(size: 13))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch).controlSize(.small).tint(RecorderStyle.mint)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 34)
    }
}
