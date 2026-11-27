import SwiftUI

struct StudioPrompter: View {
    @ObservedObject var store: RecorderMemoStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let microphone: MicrophoneRecorder
    let phase: AppPhase
    let discarding: Bool
    let deviceID: String?
    @Binding var presented: Bool
    @AppStorage("cameraStudio.prompter.x") private var horizontal = 0.5
    @AppStorage("cameraStudio.prompter.y") private var vertical = 0.04
    @AppStorage("cameraStudio.prompter.warn") private var warnsOffScript = false
    @GestureState private var translation = CGSize.zero
    @State private var script = StudioPrompterScript(text: "", width: 300, fontSize: 22)
    @State private var cursor = StudioPrompterCursor()
    @State private var editing = false
    @State private var editorOffset = 0
    @State private var requestedOffset: Int?
    @State private var takeStartOffset: Int?
    @State private var locale = Locale.current
    @State private var unavailable: String?
    @State private var hovered = false

    private var offset: Int { script.lines.isEmpty ? 0 : script.lines[cursor.index].offset }
    private struct Listening: Equatable { let device: String?; let locale: Locale }
    private struct Layout: Equatable, Sendable { let text: String; let width: CGFloat; let font: CGFloat }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = min(max(size.width * 0.52, 290), 544, max(1, size.width - 16))
            // Leave room for the handle, margins and a recognition notice even at the minimum window size.
            let font = min(store.fontSize, max(12, floor((size.height - 72) / (CGFloat(store.lineCount) * 1.32))))
            let layout = presented && !editing
                ? Layout(text: store.text, width: floor(width - 36), font: font) : nil
            ZStack {
                if presented {
                    if editing {
                        Color.black.opacity(0.16)
                        editor(in: size)
                    } else {
                        card(in: size, width: width, font: font)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .onChange(of: presented, initial: true) {
                if presented {
                    if store.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { beginEditing() }
                } else {
                    editing = false
                    store.save()
                }
            }
            .onChange(of: phase) {
                if phase == .preparing { takeStartOffset = offset }
                if phase == .finishing, discarding, let takeStartOffset {
                    cursor.seek(script.line(at: takeStartOffset))
                }
            }
            .onChange(of: editing) {
                if !editing { store.save() }
            }
            .onDisappear { store.save() }
            .task(id: layout) {
                guard let layout else { return }
                // Coalesce live window resizing before laying out a long manuscript.
                if !script.lines.isEmpty { try? await Task.sleep(for: .milliseconds(80)) }
                guard !Task.isCancelled else { return }
                let work = Task.detached(priority: .userInitiated) {
                    (StudioPrompterScript(text: layout.text, width: layout.width, fontSize: layout.font),
                     StudioPrompterSpeech.language(for: layout.text))
                }
                let (updated, language) = await withTaskCancellationHandler {
                    await work.value
                } onCancel: { work.cancel() }
                guard !Task.isCancelled else { return }
                adopt(updated)
                locale = language
            }
            .task(id: Listening(device: presented && !editing && !script.lines.isEmpty ? deviceID : nil, locale: locale)) {
                unavailable = nil
                guard presented, !editing, deviceID != nil, !script.lines.isEmpty else { return }
                await StudioPrompterSpeech.follow(microphone, locale: locale) { update in
                    switch update {
                    case .sessionStarted: cursor.newUtterance()
                    case let .words(text): cursor.hear(text, in: script)
                    case let .unavailable(reason): unavailable = reason
                    }
                }
            }
        }
    }

    private func adopt(_ updated: StudioPrompterScript) {
        let old = script.lines.isEmpty ? nil : script.lines[cursor.index]
        var index = updated.line(at: requestedOffset ?? old?.offset ?? 0)
        if requestedOffset == nil, updated.source != script.source, let old, !updated.lines.isEmpty, updated.lines[index].text != old.text,
           let nearest = updated.lines.indices.filter({ updated.lines[$0].text == old.text }).min(by: {
               abs(updated.lines[$0].offset - old.offset) < abs(updated.lines[$1].offset - old.offset)
           }) { index = nearest }
        requestedOffset = nil
        script = updated
        cursor.seek(index)
    }

    private func beginEditing() {
        editorOffset = offset
        editing = true
    }

    private func card(in size: CGSize, width: CGFloat, font: CGFloat) -> some View {
        let cues = script.lines
        let lineHeight = ceil(font * 1.32)
        let notice = unavailable ?? (warnsOffScript && cursor.offScript ? "未对上稿，可从附近一句接着读" : nil)
        let lines = store.lineCount
        let header: CGFloat = 26
        let height = header + CGFloat(lines) * lineHeight + 10 + (notice == nil ? 0 : 19)
        let travelX = max(0, size.width - width - 16)
        let travelY = max(0, size.height - height - 16)
        let x = min(max(horizontal * travelX + translation.width, 0), travelX)
        let y = min(max(vertical * travelY + translation.height, 0), travelY)
        let controlsVisible = hovered || unavailable != nil || deviceID == nil

        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Capsule().fill(.white.opacity(0.36)).frame(width: 26, height: 3)
                HStack(spacing: 2) {
                    HStack(spacing: 2) {
                        control("chevron.up", "上一行") { cursor.seek(max(0, cursor.index - 1)) }
                            .disabled(cursor.index == 0)
                        control("chevron.down", "下一行") { cursor.seek(min(script.lines.count - 1, cursor.index + 1)) }
                            .disabled(cursor.index + 1 >= script.lines.count)
                    }.opacity(controlsVisible ? 1 : 0.45)
                    Spacer()
                    control("pencil", "编辑稿件", action: beginEditing)
                }
            }
            .frame(height: header)
            VStack(alignment: .leading, spacing: 0) {
                if cues.isEmpty {
                    Button(appLocalized("写下或粘贴要讲的内容…"), action: beginEditing).buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(cursor.visibleLineIndices(rowCount: lines), id: \.self) { index in
                            if cues.indices.contains(index) {
                                cue(cues[index].text, size: font, current: index == cursor.index, height: lineHeight)
                                    .transition(.opacity)
                            } else {
                                Color.clear.frame(height: lineHeight).accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(height: CGFloat(lines) * lineHeight, alignment: .topLeading)
                    .clipped()
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: cursor.index)
                }
                if let notice {
                    Text(appLocalized(notice)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1).frame(height: 19)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18).padding(.bottom, 10)
        .frame(width: width, height: height, alignment: .top)
        .foregroundStyle(.white)
        .background(.black.opacity(store.opacity * 0.8), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)) }
        .contentShape(Rectangle())
        .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("studio.preview"))
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in
                if travelX > 0 { horizontal = min(max(horizontal + value.translation.width / travelX, 0), 1) }
                if travelY > 0 { vertical = min(max(vertical + value.translation.height / travelY, 0), 1) }
            })
        .onHover { hovered = $0 }
        .position(x: 8 + x + width / 2, y: 8 + y + height / 2)
    }

    private func cue(_ text: String, size: CGFloat, current: Bool, height: CGFloat) -> some View {
        Text(verbatim: text).font(.system(size: size, weight: current ? .semibold : .regular))
            .foregroundStyle(.white.opacity(current ? 1 : 0.68)).lineLimit(1).minimumScaleFactor(0.9)
            .frame(height: height, alignment: .leading)
    }

    private func control(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(appLocalized(label)).accessibilityLabel(appLocalized(label))
    }

    private func editor(in size: CGSize) -> some View {
        let width = min(660, max(500, size.width * 0.69), max(1, size.width - 20))
        let height = min(480, max(310, size.height * 0.84), max(1, size.height - 14))
        return VStack(alignment: .leading, spacing: 0) {
            Text(appLocalized("编辑稿件")).font(.appUI(size: 17, weight: .semibold))
                .padding(.bottom, 10)
            Rectangle().fill(RecorderStyle.line).frame(height: 1)
            ZStack(alignment: .topLeading) {
                RecorderMemoTextView(text: $store.text, fontSize: 17,
                                     initialOffset: offset, onCursorChange: { editorOffset = $0 })
                if store.text.isEmpty {
                    Text(appLocalized("写下或粘贴要讲的内容…")).font(.system(size: 17))
                        .foregroundStyle(RecorderStyle.muted).padding(.horizontal, 19)
                        .padding(.vertical, 14).allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(RecorderStyle.line).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { lineControls; Spacer(minLength: 6); editorActions }
                VStack(alignment: .leading, spacing: 4) {
                    lineControls
                    HStack { Spacer(); editorActions }
                }
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 12)
        .frame(width: width, height: height)
        .modifier(RecorderSurface(radius: RecorderStyle.cardRadius, castsShadow: true))
    }

    private var lineControls: some View {
        HStack(spacing: 6) {
            EditorActionMenu(title: "提词设置", items: [
                .action("偏离稿件时提示", isOn: warnsOffScript) { warnsOffScript.toggle() }
            ], arrowEdge: .top) {
                Image(systemName: "slider.horizontal.3").frame(width: 24, height: 28)
            }
            Text(appLocalized("显示行数")).font(.appUI(size: 12, weight: .medium))
            EditorSegmentedControl(options: [1, 2, 3], title: { String($0) }, selection: $store.lineCount)
                .environment(\.recordingDesignControls, true).frame(width: 98)
                .accessibilityElement(children: .contain).accessibilityLabel(appLocalized("显示行数"))
        }
        .fixedSize()
    }

    private var editorActions: some View {
        HStack(spacing: 6) {
            Button(appLocalized("从光标处读")) {
                requestedOffset = editorOffset
                editing = false
            }
            .buttonStyle(EditorGhostButtonStyle()).disabled(store.text.isEmpty)
            Button(appLocalized("完成")) { editing = false }
                .buttonStyle(EditorPrimaryButtonStyle(minHeight: 28))
                .keyboardShortcut(.return, modifiers: .command)
        }
        .fixedSize()
    }
}
