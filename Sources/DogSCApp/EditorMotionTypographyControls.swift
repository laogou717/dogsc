import RecorderCore
import SwiftUI

/// The canvas bar and inspector write the same clip-local overrides.
struct EditorMotionTypographyControls: View {
    let element: MotionElement
    let edit: MotionElementEdit
    let onFamily: (String?) -> Void
    let onWeight: (Int) -> Void
    @State private var showsFonts = false

    private var isBold: Bool { (edit.fontWeight ?? element.fontWeight ?? 400) >= 600 }

    var body: some View {
        HStack(spacing: 1) {
            EditorFloatBarButton(symbol: "bold", help: "加粗", isOn: isBold) {
                onWeight(isBold ? 400 : 700)
            }
            EditorFloatBarButton(title: "字体", help: "字体", isOn: showsFonts) { showsFonts = true }
                .editorPopover(isPresented: $showsFonts, arrowEdge: .bottom) {
                    FontFamilyPicker(selected: edit.fontFamily, defaultTitle: "原始字体") { family in
                        onFamily(family)
                        showsFonts = false
                    }
                }
        }
        .task { EditorFontFamilyCatalog.shared.prepare() }
    }
}
