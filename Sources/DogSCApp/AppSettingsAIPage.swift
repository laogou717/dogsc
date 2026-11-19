import AppKit
import SwiftUI

/// Settings → AI: which AI the editor talks to, its model and effort, and
/// the connection state of every provider. Everything reads and writes
/// `AgentChatModel.shared`, the same state the AI panel uses.
struct AppSettingsAIPage: View {
    @ObservedObject private var chat = AgentChatModel.shared
    @ObservedObject private var integrations = AgentIntegrations.shared
    @State private var showsAPIKeySheet = false
    @State private var copiedInstructions = false

    private static let cliProviders: [AgentChatModel.Provider] = [.codex, .claude, .gemini, .kimi]

    var body: some View {
        SettingsPageHeader(title: "AI", lead: "AI 剪辑、字幕和动效用哪一家")
        SettingsGroup {
            SettingsRow("默认 AI", detail: "对话里也可以随时切换", last: chat.provider == nil) {
                SettingsMenu(chat.provider?.title ?? appLocalized("未选择")) {
                    ForEach(AgentChatModel.Provider.allCases) { candidate in
                        Button {
                            if chat.provider == nil { chat.connect(candidate) } else { chat.switchProvider(to: candidate) }
                        } label: {
                            if chat.provider == candidate {
                                Label(candidate.title, systemImage: "checkmark")
                            } else {
                                Text(candidate.title)
                            }
                        }
                        .disabled(!isSelectable(candidate))
                    }
                }
                .disabled(chat.isRunning)
                .accessibilityLabel(appLocalized("默认 AI"))
            }
            if chat.provider != nil {
                SettingsRow("模型", last: efforts.isEmpty) { modelMenu }
                if !efforts.isEmpty {
                    SettingsRow("思考强度", detail: "越高越慢、越仔细", last: true) {
                        AppSegmentedChoice(
                            options: efforts,
                            selection: Binding(
                                get: { currentEffort },
                                set: { chat.setCLIEffort($0) }
                            ),
                            label: { AgentChatModel.effortName($0) },
                            optionMinWidth: 52
                        )
                    }
                }
            }
        }
        SettingsGroup("连接") {
            ForEach(Self.cliProviders) { candidate in
                connectionRow(candidate)
            }
            SettingsRow("API Key", detail: "OpenAI 兼容接口", last: true) {
                if chat.hasStoredKey { SettingsStatusPill(text: "已保存", kind: .ok) }
                Button(appLocalized("设置…")) { showsAPIKeySheet = true }
                    .buttonStyle(.appSheet)
            }
        }
        SettingsGroup("在其他 AI 里编辑 DogSC") {
            ForEach(AgentIntegrations.Target.allCases) { target in
                integrationRow(target)
            }
            SettingsRow("其他 AI", detail: "复制一段安装说明，发给任意支持 MCP 的 AI", last: true) {
                Button(appLocalized(copiedInstructions ? "已复制" : "复制说明")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentChatModel.installInstructions, forType: .string)
                    copiedInstructions = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedInstructions = false }
                }
                .buttonStyle(.appSheet)
            }
        }
        .onAppear {
            integrations.refresh()
            for candidate in Self.cliProviders
            where chat.isAvailable(candidate) && chat.account(for: candidate) == .unknown {
                chat.refreshAccount(candidate)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            for candidate in Self.cliProviders where chat.account(for: candidate) == .signingIn {
                chat.refreshAccount(candidate)
            }
        }
        .sheet(isPresented: $showsAPIKeySheet) { SettingsAPIKeySheet(chat: chat) }
    }

    private func isSelectable(_ candidate: AgentChatModel.Provider) -> Bool {
        candidate == .api ? chat.hasStoredKey : chat.isAvailable(candidate)
    }

    // MARK: Model

    @ViewBuilder
    private var modelMenu: some View {
        if chat.provider == .api {
            SettingsMenu(chat.apiModel.isEmpty ? appLocalized("模型") : chat.apiModel) {
                if chat.apiModels.isEmpty {
                    Button(appLocalized("读取模型列表")) { chat.loadAPIModels() }
                } else {
                    ForEach(chat.apiModels, id: \.self) { model in
                        Button(model) {
                            chat.apiModel = model
                            UserDefaults.standard.set(model, forKey: "agent.api.model")
                        }
                    }
                }
            }
            .onAppear { if chat.apiModels.isEmpty, chat.hasStoredKey { chat.loadAPIModels() } }
        } else {
            SettingsMenu(chat.selectedCLIModel.map { model in
                chat.effortLabel.isEmpty ? model.name : "\(model.name) · \(chat.effortLabel)"
            } ?? appLocalized("默认模型")) {
                ForEach(chat.cliModels) { model in
                    Button {
                        chat.selectCLIModel(model)
                    } label: {
                        if chat.selectedCLIModel?.slug == model.slug {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                    }
                }
            }
            .disabled(chat.cliModels.isEmpty)
            .onAppear { if chat.provider == .codex, chat.codexModels.isEmpty { chat.loadCodexModels() } }
        }
    }

    private var efforts: [String] {
        guard chat.provider != .api else { return [] }
        return chat.selectedCLIModel?.efforts ?? []
    }

    private var currentEffort: String {
        let effort = chat.cliEffort
        return efforts.contains(effort) ? effort : (chat.selectedCLIModel?.defaultEffort ?? "")
    }

    // MARK: Connections

    private func connectionRow(_ candidate: AgentChatModel.Provider) -> some View {
        let installed = chat.isAvailable(candidate)
        let account = chat.account(for: candidate)
        return SettingsRow(candidate.title, detail: connectionDetail(installed: installed, account: account)) {
            if !installed {
                SettingsStatusPill(text: "未安装", kind: .later)
            } else {
                switch account {
                case .signedIn:
                    SettingsStatusPill(text: "已连接", kind: .ok)
                case .signedOut:
                    SettingsStatusPill(text: "未登录", kind: .missing)
                    Button(appLocalized("登录")) { chat.signIn(candidate) }.buttonStyle(.appSheet)
                case .signingIn:
                    Button(appLocalized("已登录")) { chat.refreshAccount(candidate) }.buttonStyle(.appSheet)
                case .checking, .unknown:
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Other AIs

    private func integrationRow(_ target: AgentIntegrations.Target) -> some View {
        let state = integrations.state(target)
        let detail: String? = switch state {
        case .notInstalled: nil
        case .disconnected: "连接后，在它里面就能直接编辑打开的项目"
        case .outdated: "连接信息过期了，点“更新”"
        case .connected: target.skillFolder == nil ? "已添加 DogSC 工具，使用说明随工具一起提供" : "已添加 DogSC 工具和技能"
        case .working: "正在处理…"
        case .failed(let message): message
        }
        return SettingsRow(target.title, detail: detail) {
            switch state {
            case .notInstalled:
                SettingsStatusPill(text: "未安装", kind: .later)
            case .disconnected, .failed:
                Button(appLocalized("连接")) { integrations.connect(target) }.buttonStyle(.appSheet)
            case .outdated:
                Button(appLocalized("更新")) { integrations.connect(target) }.buttonStyle(.appSheet)
            case .connected:
                SettingsStatusPill(text: "已连接", kind: .ok)
                Button(appLocalized("移除")) { integrations.disconnect(target) }.buttonStyle(.appSheet)
            case .working:
                ProgressView().controlSize(.small)
            }
        }
        .help(appLocalized("在它自己的用户配置里添加名为 dogsc 的 MCP 服务器，并安装 dogsc-editor 技能；使用时 DogSC 需要保持打开。"))
    }

    private func connectionDetail(installed: Bool, account: AgentChatModel.CodexAccount) -> String? {
        guard installed else { return nil }
        switch account {
        case .signedIn: return "已登录"
        case .signedOut: return "在终端或浏览器中登录后即可使用"
        case .signingIn: return "完成登录后点“已登录”"
        case .checking, .unknown: return "检查中…"
        }
    }
}

/// The OpenAI-compatible endpoint: address, key (kept in the keychain),
/// model. The same fields the AI panel's setup used.
private struct SettingsAPIKeySheet: View {
    @ObservedObject var chat: AgentChatModel

    /// Common OpenAI-compatible endpoints and a sensible first model.
    static let apiPresets: [(name: String, url: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-v4-flash"),
        ("OpenAI", "https://api.openai.com/v1", "gpt-4.1"),
        // Model lists change often; these load the service's own list.
        ("Kimi（月之暗面）", "https://api.moonshot.cn/v1", ""),
        ("通义千问", "https://dashscope.aliyuncs.com/compatible-mode/v1", ""),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", ""),
        ("OpenRouter", "https://openrouter.ai/api/v1", ""),
    ]

    static func presetName(for url: String) -> String {
        apiPresets.first { url.trimmingCharacters(in: .whitespaces).hasPrefix($0.url) }?.name ?? appLocalized("自定义")
    }
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("API Key").font(.appUI(size: 17, weight: .semibold))
                Spacer()
                Button { dismiss() } label: { AppLineIcon(kind: .close, size: 16) }
                    .buttonStyle(.editorDismissIcon(size: 28))
                    .accessibilityLabel(appLocalized("关闭"))
            }
            Text("OpenAI 兼容接口。Key 只保存在本机钥匙串里。")
                .font(.appUI(size: 12.5))
                .foregroundStyle(EditorTheme.tertiaryText)
                .padding(.bottom, 8)
            SettingsRow("服务商", detail: "选一个自动填好地址") {
                SettingsMenu(Self.presetName(for: chat.apiBaseURL)) {
                    ForEach(Self.apiPresets, id: \.url) { preset in
                        Button(preset.name) {
                            chat.apiBaseURL = preset.url
                            // A model name from another service would fail here.
                            chat.apiModel = preset.model
                            if chat.hasStoredKey { chat.loadAPIModels() }
                        }
                    }
                }
            }
            SettingsRow("地址") {
                TextField("https://api.openai.com/v1", text: $chat.apiBaseURL)
                    .textFieldStyle(.plain).font(.appUI(size: 13))
                    .padding(.horizontal, 10).frame(width: 260, height: 30)
                    .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            SettingsRow("Key") {
                SecureField(chat.hasStoredKey ? appLocalized("已保存") : "sk-…", text: $apiKey)
                    .textFieldStyle(.plain).font(.appUI(size: 13))
                    .padding(.horizontal, 10).frame(width: 260, height: 30)
                    .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            SettingsRow("模型", last: true) {
                if chat.apiModels.isEmpty {
                    TextField("gpt-4.1", text: $chat.apiModel)
                        .textFieldStyle(.plain).font(.appUI(size: 13))
                        .padding(.horizontal, 10).frame(width: 180, height: 30)
                        .background(EditorTheme.chrome(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    SettingsMenu(chat.apiModel) {
                        ForEach(chat.apiModels, id: \.self) { model in
                            Button(model) { chat.apiModel = model }
                        }
                    }
                }
                Button {
                    chat.loadAPIModels(apiKey: apiKey)
                } label: {
                    if chat.apiModelsState == .checking { ProgressView().controlSize(.mini) } else { Text("读取列表") }
                }
                .buttonStyle(.appSheetGhost)
                .disabled(apiKey.isEmpty && !chat.hasStoredKey)
            }
            HStack(spacing: 10) {
                if chat.hasStoredKey {
                    Button(appLocalized("删除 Key")) { chat.forgetKey() }
                        .buttonStyle(.appSheetGhost)
                }
                Spacer()
                Button(appLocalized("取消")) { dismiss() }.buttonStyle(.appSheet(.ghost, large: true))
                Button(appLocalized("保存并连接")) {
                    chat.connect(.api, apiKey: apiKey)
                    apiKey = ""
                    dismiss()
                }
                .buttonStyle(.appSheet(.primary, large: true))
                .keyboardShortcut(.defaultAction)
                .disabled(apiKey.isEmpty && !chat.hasStoredKey)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(width: 500)
        .background(EditorTheme.panelSurface)
        .appControlFocusAppearance()
        .onExitCommand { dismiss() }
        .onChange(of: apiKey) { _, key in
            if key.count > 20 { chat.loadAPIModels(apiKey: key) }
        }
    }
}

/// Settings → 快捷键: the editor's real shortcuts, read-only.
struct AppSettingsShortcutsPage: View {
    private struct Entry: Identifiable {
        let action: String
        let keys: [String]
        var id: String { action }
    }

    private let groups: [(String, [Entry])] = [
        ("播放", [
            Entry(action: "播放 / 暂停", keys: ["空格"]),
            Entry(action: "逐帧", keys: ["←", "→"]),
            Entry(action: "前后移动 5 帧", keys: ["⇧←", "⇧→"]),
        ]),
        ("剪辑", [
            Entry(action: "选择 / 切割工具", keys: ["A", "B"]),
            Entry(action: "在播放头切开", keys: ["S"]),
            Entry(action: "波纹删除前 / 后", keys: ["Q", "W"]),
            Entry(action: "删除选中项", keys: ["D", "Delete"]),
            Entry(action: "复制 / 粘贴效果片段", keys: ["⌘C", "⌘V"]),
            Entry(action: "粘贴属性", keys: ["⌘⇧V"]),
        ]),
        ("通用", [
            Entry(action: "让 AI 修改", keys: ["⌘K"]),
            Entry(action: "导出", keys: ["⌘E"]),
            Entry(action: "导出选中的主片段", keys: ["⌥X"]),
            Entry(action: "撤销 / 重做", keys: ["⌘Z", "⌘⇧Z"]),
            Entry(action: "显示 / 隐藏素材面板", keys: ["⌥⌘L"]),
            Entry(action: "导入录屏项目", keys: ["⌥⌘I"]),
            Entry(action: "快捷键速查", keys: ["⌘/"]),
            Entry(action: "设置", keys: ["⌘,"]),
        ]),
    ]

    var body: some View {
        SettingsPageHeader(title: "快捷键", lead: "编辑器里最常用的操作")
        ForEach(groups, id: \.0) { title, entries in
            SettingsGroup(title) {
                ForEach(entries) { entry in
                    SettingsRow(entry.action, last: entry.id == entries.last?.id) {
                        HStack(spacing: 4) {
                            ForEach(entry.keys, id: \.self) { SettingsKeyCap(key: $0) }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(entry.keys.map(appLocalized).joined(separator: " "))
                    }
                }
            }
        }
    }
}
