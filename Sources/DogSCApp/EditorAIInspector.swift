import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// EDT-054: the AI page of the library. Before a provider is connected it is
/// a short setup; afterwards the setup folds away and the page is only a
/// conversation, with the composer pinned to the bottom.
struct EditorAIInspector: View {
    @ObservedObject private var chat = AgentChatModel.shared

    var body: some View {
        Group {
            if chat.provider == nil {
                AgentSetupView(chat: chat)
                    .transition(.opacity)
            } else {
                AgentConversationView(chat: chat)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: chat.provider == nil)
    }
}

enum AgentCLI {
    static let searchPath = [
        "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "\(NSHomeDirectory())/.npm-global/bin", "\(NSHomeDirectory())/.bun/bin",
        "\(NSHomeDirectory())/.volta/bin", "/usr/bin", "/bin",
    ].joined(separator: ":")

    /// Official Codex builds that ship inside OpenAI's desktop apps.
    private static let bundledCodex = [
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        "\(NSHomeDirectory())/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
    ]

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var resolved: [String: (path: String, version: String)?] = [:]
    }
    private static let cache = Cache()

    static func path(for name: String) -> String? { resolve(name)?.path }

    /// Cheap check for views: is any copy on disk? Never runs the tool, so it
    /// is safe inside SwiftUI updates.
    static func isInstalled(_ name: String) -> Bool {
        cache.lock.lock()
        if let hit = cache.resolved[name] { cache.lock.unlock(); return hit != nil }
        cache.lock.unlock()
        return candidates(for: name).contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Finds every CLI's newest copy off the main thread, once.
    static func prewarm(_ names: [String]) {
        DispatchQueue.global(qos: .utility).async { for name in names { _ = resolve(name) } }
    }

    private static func candidates(for name: String) -> [String] {
        var list = searchPath.split(separator: ":").map { "\($0)/\(name)" }
        if name == "codex" { list += bundledCodex }
        // DeepSeek Harness desktop ships its command inside the app.
        if name == "dsh" {
            list += ["/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh",
                     "\(NSHomeDirectory())/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh"]
        }
        return list
    }

    static func resolvedPath(for name: String) async -> String? {
        await Task.detached(priority: .userInitiated) { path(for: name) }.value
    }

    /// Several copies of a CLI can be installed (npm, Homebrew, the one inside
    /// the ChatGPT app). An outdated copy cannot use newer models, so always
    /// pick the newest version found.
    private static func resolve(_ name: String) -> (path: String, version: String)? {
        cache.lock.lock()
        if let hit = cache.resolved[name] { cache.lock.unlock(); return hit }
        cache.lock.unlock()
        var seen = Set<String>()
        let found = candidates(for: name)
            .filter { FileManager.default.isExecutableFile(atPath: $0) }
            .filter { seen.insert(URL(fileURLWithPath: $0).resolvingSymlinksInPath().path).inserted }
            .compactMap { path -> (path: String, version: String)? in
                guard let version = versionString(of: path) else { return nil }
                return (path, version)
            }
            .max { compare($0.version, $1.version) }
        cache.lock.lock(); cache.resolved[name] = found; cache.lock.unlock()
        return found
    }

    private static func versionString(of path: String) -> String? {
        let (status, text) = AgentCLICommand.run(path, ["--version"], timeout: 10)
        guard status == 0 else { return nil }
        return text.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Numeric comparison of the leading "major.minor.patch".
    private static func compare(_ lhs: String, _ rhs: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let a = parts(lhs), b = parts(rhs)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

// MARK: - Setup

private struct AgentSetupView: View {
    @ObservedObject var chat: AgentChatModel
    @State private var showsAPIForm = false
    @State private var apiKey = ""
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(appLocalized("AI 助手"))
                        .font(EditorTypography.pageTitle)
                        .foregroundStyle(EditorTheme.primaryText)
                    Text(appLocalized("连接后可以用文字让它剪辑、加字幕、做动效。"))
                        .font(EditorTypography.helper)
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)

                VStack(spacing: 0) {
                    ForEach([AgentChatModel.Provider.codex, .claude, .gemini, .kimi]) { candidate in
                        cliRow(candidate)
                        Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.leading, 44)
                    }
                    apiRow
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EditorTheme.groupSurface))

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentChatModel.installInstructions, forType: .string)
                    withAnimation(.easeOut(duration: 0.15)) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { copied = false } }
                } label: {
                    HStack(spacing: 5) {
                        EditorSymbol(copied ? "checkmark" : "arrow.up.forward.app", size: 10)
                            .font(.system(size: 10, weight: .semibold))
                        Text(appLocalized(copied ? "已复制，发给你的 AI 工具即可" : "在其他工具中使用（如 Claude Code 或 Codex 等）"))
                            .font(.appUI(size: 11))
                    }
                    .foregroundStyle(EditorTheme.secondaryText)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(appLocalized("复制一段安装说明，发给你的 AI 工具，它会自己装好 DogSC 的技能"))
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .scrollIndicators(.never)
    }

    private func optionIcon(_ symbol: String) -> some View {
        EditorSymbol(symbol, size: 12)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EditorTheme.primaryText)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(EditorTheme.chrome(0.07)))
    }

    private func pill(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.appUI(size: 11, weight: .semibold))
                .foregroundStyle(EditorTheme.onAccentFill)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(EditorTheme.accent))
        }
        .buttonStyle(.plain)
    }

    /// One row per installed coding CLI: name, sign-in state, connect.
    private func cliRow(_ candidate: AgentChatModel.Provider) -> some View {
        let installed = chat.isAvailable(candidate)
        let account = chat.account(for: candidate)
        return HStack(spacing: 10) {
            optionIcon("terminal")
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.title)
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                Text(cliStatus(candidate, installed: installed, account: account))
                    .font(.appUI(size: 11))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if installed {
                switch account {
                case .signedIn: pill(appLocalized("连接")) { chat.connect(candidate) }
                case .signedOut: pill(appLocalized("登录")) { chat.signIn(candidate) }
                case .signingIn: pill(appLocalized("已登录")) { chat.refreshAccount(candidate) }
                case .checking, .unknown: ProgressView().controlSize(.small)
                }
            }
        }
        .padding(10)
        .opacity(installed ? 1 : 0.5)
        .onAppear { if installed, account == .unknown { chat.refreshAccount(candidate) } }
    }

    private func cliStatus(_ candidate: AgentChatModel.Provider, installed: Bool, account: AgentChatModel.CodexAccount) -> String {
        guard installed else { return appLocalized("未安装") }
        switch account {
        case .signedIn:
            switch candidate {
            case .codex: return appLocalized("你的 ChatGPT 账号")
            case .claude: return appLocalized("你的 Claude 账号或 API Key")
            case .gemini: return appLocalized("你的 Google 账号")
            case .kimi: return appLocalized("你的 Kimi 账号")
            case .api: return ""
            }
        case .signedOut: return appLocalized("未登录")
        case .signingIn: return candidate == .codex ? appLocalized("在浏览器中完成登录") : appLocalized("在终端中完成登录后点“已登录”")
        case .checking, .unknown: return appLocalized("检查中…")
        }
    }

    private var apiRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                optionIcon("key")
                VStack(alignment: .leading, spacing: 1) {
                    Text(appLocalized("API Key"))
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text(appLocalized("OpenAI 兼容接口"))
                        .font(.appUI(size: 11))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
                Spacer(minLength: 0)
                EditorSymbol("chevron.down", size: 10)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .rotationEffect(.degrees(showsAPIForm ? 180 : 0))
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.snappy(duration: 0.22)) { showsAPIForm.toggle() } }
            if showsAPIForm {
                VStack(spacing: 0) {
                    field(appLocalized("地址"), text: $chat.apiBaseURL, secure: false)
                    field(appLocalized("Key"), text: $apiKey, secure: true,
                          placeholder: chat.hasStoredKey ? appLocalized("已保存") : "sk-…")
                    apiModelField
                    HStack {
                        Spacer()
                        pill(appLocalized("连接")) {
                            chat.connect(.api, apiKey: apiKey)
                            apiKey = ""
                        }
                        .disabled(apiKey.isEmpty && !chat.hasStoredKey)
                        .opacity(apiKey.isEmpty && !chat.hasStoredKey ? 0.4 : 1)
                    }
                    .padding(10)
                }
                .transition(.opacity)
            }
        }
    }

    /// The models the endpoint offers, read with the key; typing a name
    /// stays possible for endpoints that do not list models.
    private var apiModelField: some View {
        HStack(spacing: 10) {
            Text(appLocalized("模型"))
                .font(.appUI(size: 11))
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: 36, alignment: .leading)
            if chat.apiModels.isEmpty {
                TextField("gpt-4.1", text: $chat.apiModel)
                    .textFieldStyle(.plain)
                    .font(.appUI(size: 12))
            } else {
                Menu {
                    ForEach(chat.apiModels, id: \.self) { model in
                        Button(model) { chat.apiModel = model }
                    }
                } label: {
                    Text(chat.apiModel).font(.appUI(size: 12)).foregroundStyle(EditorTheme.primaryText)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Button {
                chat.loadAPIModels(apiKey: apiKey)
            } label: {
                if chat.apiModelsState == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(appLocalized(chat.apiModels.isEmpty ? "读取列表" : "刷新"))
                        .font(.appUI(size: 11))
                        .foregroundStyle(EditorTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)
            .disabled(apiKey.isEmpty && !chat.hasStoredKey)
            .help(appLocalized("用这个 Key 读取接口提供的模型"))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .overlay(alignment: .top) { Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.leading, 12) }
        .onAppear { if chat.apiModels.isEmpty, chat.hasStoredKey { chat.loadAPIModels() } }
        .onChange(of: apiKey) { _, key in
            if key.count > 20 { chat.loadAPIModels(apiKey: key) }
        }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool, placeholder: String? = nil) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.appUI(size: 11))
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: 36, alignment: .leading)
            Group {
                if secure {
                    SecureField(placeholder ?? title, text: text)
                } else {
                    TextField(placeholder ?? title, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.appUI(size: 12))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .overlay(alignment: .top) { Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.leading, 12) }
    }
}

// MARK: - Conversation

/// EDT-064: the conversation, Claude-style. The user's words sit in a light
/// bubble on the right; the assistant writes plain prose. Each turn's edits
/// form one step list, and a finished turn ends in a result card that says
/// what changed and can play it or put it all back.
private struct AgentConversationView: View {
    @ObservedObject var chat: AgentChatModel
    @State private var draft = ""
    @State private var showsModelSettings = false
    @State private var showsHistory = false
    @State private var followsLatest = true
    @State private var hasNewOutput = false
    @State private var viewportHeight: CGFloat = 0
    @State private var followLatestUpdate = EditorMainAction()
    @State private var scrollFollow = AIConversationFollowState()
    @FocusState private var composerFocused: Bool

    private let suggestions: [(icon: AppLineIcon.Kind, text: String, prompt: String?)] = [
        (.list, "生成中英双语字幕", nil),
        (.sparkle, "在开头做一个标题动画", nil),
        (.speaker, "加一段轻柔的背景音乐", nil),
        (.scissors, "智能剪辑", "帮我智能剪辑这个项目。"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if !chat.messages.isEmpty { threadHeader }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(chat.messages) { message in
                            MessageRow(chat: chat, message: message, isRunning: chat.isRunning, provider: chat.provider,
                                switchableProviders: message.role == .error ? chat.switchableProviders : [], onDismiss: { chat.dismiss(message.id) }) { action in
                                switch action {
                                case .signIn: if let provider = chat.provider { chat.signIn(provider) }
                                case .chooseModel, .switchProvider: showsModelSettings = true
                                }
                            }
                            .equatable()
                            .id(message.id)
                        }
                        if chat.isRunning {
                            LiveActivityRow(activity: chat.activity, startedAt: chat.turnStartedAt).id("working")
                        }
                        Color.clear.frame(height: 1).id("ai-bottom")
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: AIConversationBottomKey.self,
                                value: AIConversationScrollMetrics(originY: geometry.frame(in: .named("ai-scroll")).minY,
                                    height: geometry.size.height))
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.never)
                .coordinateSpace(name: "ai-scroll")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
                .onPreferenceChange(AIConversationBottomKey.self) { metrics in
                    switch scrollFollow.observe(metrics, viewportHeight: viewportHeight, following: followsLatest) {
                    case .atBottom:
                        if !followsLatest { followsLatest = true }
                        if hasNewOutput { hasNewOutput = false }
                    case .readingHistory:
                        if followsLatest { followsLatest = false }
                        followLatestUpdate.cancel()
                    case .follow:
                        followLatestUpdate.submit {
                            guard followsLatest else { return }
                            proxy.scrollTo("ai-bottom", anchor: .bottom)
                        }
                    case .none: break
                    }
                }
                .overlay { if chat.messages.isEmpty { emptyState } }
                .overlay(alignment: .bottom) {
                    if hasNewOutput {
                        Button {
                            followsLatest = true
                            hasNewOutput = false
                            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("ai-bottom", anchor: .bottom) }
                        } label: {
                            HStack(spacing: 5) {
                                Text(appLocalized("有新进展"))
                                EditorSymbol("arrow.down", size: 10)
                            }
                            .font(.appUI(size: 12))
                            .foregroundStyle(EditorTheme.accent)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(EditorTheme.panelRaised, in: Capsule())
                            .overlay(Capsule().strokeBorder(EditorTheme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 8)
                    }
                }
                .onChange(of: chat.currentThreadID) { _, _ in
                    scrollFollow.reset()
                    followsLatest = true
                    hasNewOutput = false
                    followLatestUpdate.submit {
                        guard followsLatest else { return }
                        proxy.scrollTo("ai-bottom", anchor: .bottom)
                    }
                }
                .onChange(of: chat.messagesRevision) { _, _ in
                    guard followsLatest else { hasNewOutput = true; return }
                    // Streaming produces many updates. Do not restart a scroll
                    // animation for every token or drag readers out of history.
                    followLatestUpdate.submit {
                        guard followsLatest else { return }
                        proxy.scrollTo("ai-bottom", anchor: .bottom)
                    }
                }

            }
            composer
        }
        // History drops down from the header inside the panel, like a menu.
        .overlay(alignment: .topTrailing) {
            if showsHistory {
                ZStack(alignment: .topTrailing) {
                    Color.black.opacity(0.001)
                        .onTapGesture { withAnimation(SpringMotion.panel) { showsHistory = false } }
                    ThreadHistoryPopover(chat: chat) {
                        withAnimation(SpringMotion.panel) { showsHistory = false }
                    }
                    .padding(.top, 40).padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
                .onExitCommand { withAnimation(SpringMotion.panel) { showsHistory = false } }
            }
        }
    }

    /// The thread's name and the history / new-thread controls.
    private var threadHeader: some View {
        HStack(spacing: 6) {
            Text(chat.threadTitle)
                .font(.appUI(size: 14, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            headerButtons
        }
        .padding(.leading, 14).padding(.trailing, 8)
        .frame(height: 40)
    }

    private var headerButtons: some View {
        HStack(spacing: 2) {
            AIIconButton(icon: .clock, help: "对话记录") {
                chat.refreshThreads()
                withAnimation(SpringMotion.panel) { showsHistory.toggle() }
            }
            AIIconButton(icon: .plus, help: "新对话") { chat.newThread() }
                .disabled(chat.isRunning || chat.messages.isEmpty)
            Menu {
                Button(appLocalized("打开 AI 工作区")) {
                    if let url = AgentBridgeServer.shared.workspaceURL { NSWorkspace.shared.open(url) }
                }
                Button(appLocalized("复制给其他 AI 工具的安装说明")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(AgentChatModel.installInstructions, forType: .string)
                }
                Divider()
                Button(appLocalized("更换 AI")) { chat.disconnect() }
                if chat.provider == .api {
                    Button(appLocalized("删除保存的 API Key"), role: .destructive) { chat.forgetKey() }
                }
            } label: {
                EditorSymbol("ellipsis", size: 13)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(AIPressStyle(radius: 6))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(appLocalized("更多"))
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Spacer(); headerButtons }
            Spacer(minLength: 0)
            Text(appLocalized("想怎么改这段视频？"))
                .font(.appUI(size: 20, weight: .semibold))
                .foregroundStyle(EditorTheme.primaryText)
            Text(appLocalized("AI 能读到当前项目，直接帮你改字幕、加动画、配音乐、调画面。每一步都能撤销。"))
                .font(.appUI(size: 14))
                .foregroundStyle(EditorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            let context = chat.projectContext
            if !context.isEmpty {
                AIFlowLayout(spacing: 6) {
                    ForEach(context, id: \.self) { label in
                        Text(label)
                            .font(.appUI(size: 12))
                            .foregroundStyle(EditorTheme.secondaryText)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(EditorTheme.controlWell))
                    }
                }
            }
            VStack(spacing: 6) {
                ForEach(suggestions, id: \.text) { item in
                    Button { chat.send(appLocalized(item.prompt ?? item.text)) } label: {
                        HStack(spacing: 10) {
                            AppLineIcon(kind: item.icon, size: 15).foregroundStyle(EditorTheme.secondaryText)
                            Text(appLocalized(item.text))
                                .font(.appUI(size: 14))
                                .foregroundStyle(EditorTheme.primaryText)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EditorTheme.panelRaised))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AIPressStyle())
                    .help(appLocalized(item.prompt ?? item.text))
                }
            }
        }
        .padding(.leading, 14).padding(.trailing, 8).padding(.bottom, 16)
        .padding(.top, 6)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !chat.pendingAttachments.isEmpty
    }

    private func pickAttachments() {
        AppFilePanel.open(configure: { panel in
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = (AgentChatModel.imageExtensions.union(AgentChatModel.textExtensions))
                .compactMap { UTType(filenameExtension: $0) }
            panel.message = appLocalized("选择参考图片或文本文件")
        }) { urls in
            if let urls { chat.attach(urls) }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            queueBar
            composerBox
        }
        .animation(SpringMotion.panel, value: chat.queued)
    }

    private var composerBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.pendingAttachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(chat.pendingAttachments) { attachment in
                            PendingAttachmentTile(attachment: attachment) { chat.removePendingAttachment(attachment.id) }
                        }
                    }
                    .padding(.horizontal, 2).padding(.top, 6)
                }
                .scrollIndicators(.never)
            }
            TextField(appLocalized(chat.messages.isEmpty ? "描述你想要的修改，⌘V 粘贴截图…"
                                    : chat.isRunning ? "补充说明，或问问它在做什么…" : "继续说…"),
                      text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.appUI(size: 14))
                .foregroundStyle(EditorTheme.primaryText)
                .lineLimit(2...8)
                .focused($composerFocused)
                .onSubmit(submit)
                .background(AgentComposerInputBridge(isFocused: composerFocused, onSubmit: submit,
                    onPaste: { chat.pasteAttachments() }))
                .onPasteCommand(of: [.image, .fileURL]) { _ in chat.pasteAttachments() }
                .padding(.horizontal, 6).padding(.top, 4)
            HStack(spacing: 4) {
                AIIconButton(icon: .plus, help: "添加图片或文件（也可以直接粘贴或拖进来）", action: pickAttachments)
                    .disabled(chat.pendingAttachments.count >= AgentChatModel.maxAttachments)
                if !chat.pendingAttachments.isEmpty {
                    Text(verbatim: "\(chat.pendingAttachments.count) / \(AgentChatModel.maxAttachments)")
                        .font(.appUI(size: 12).monospacedDigit())
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                Spacer(minLength: 4)
                modelButton
                sendButton
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(composerFocused ? EditorTheme.accent.opacity(0.55) : EditorTheme.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.03), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.06), radius: 9, y: 3)
        .padding(.horizontal, 10).padding(.bottom, 10)
        .animation(SpringMotion.micro, value: composerFocused)
    }

    /// The model and how hard it thinks, as one quiet button (Claude-style).
    private var modelButton: some View {
        Button { showsModelSettings.toggle() } label: {
            HStack(spacing: 5) {
                Circle().fill(chat.cliAccount == .signedOut ? EditorTheme.amberAccent : EditorTheme.success)
                    .frame(width: 6, height: 6)
                Text(modelButtonTitle)
                    .font(.appUI(size: 13))
                    .lineLimit(1)
                AppLineIcon(kind: showsModelSettings ? .chevronUp : .chevronDown, size: 11)
            }
            .foregroundStyle(showsModelSettings ? EditorTheme.primaryText : EditorTheme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(showsModelSettings ? EditorTheme.controlWell : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(AIPressStyle())
        .help(chat.modelLabel)
        .editorContentSizedPopover(isPresented: $showsModelSettings, width: 300) {
            ComposerModelPopover(chat: chat)
        }
    }

    private var modelButtonTitle: String {
        switch chat.provider {
        case .codex, .claude, .gemini, .kimi:
            guard let model = chat.selectedCLIModel else { return chat.provider?.title ?? appLocalized("模型") }
            return chat.effortLabel.isEmpty ? model.name : model.name + " · " + chat.effortLabel
        case .api: return chat.apiModel
        case nil: return ""
        }
    }

    private var sendButton: some View {
        let stops = chat.isRunning && !canSend
        return Button {
            stops ? chat.stop() : submit()
        } label: {
            ZStack {
                if chat.isStopping {
                    ProgressView().controlSize(.mini).tint(EditorTheme.onAccentFill)
                } else if stops {
                    RoundedRectangle(cornerRadius: 2, style: .continuous).frame(width: 10, height: 10)
                } else {
                    AppLineIcon(kind: .chevronUp, size: 15)
                }
            }
            .foregroundStyle(chat.isRunning || canSend ? EditorTheme.onAccentFill : EditorTheme.tertiaryText)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chat.isRunning || canSend ? EditorTheme.accent : EditorTheme.selectionWash))
        }
        .buttonStyle(AIPressStyle())
        .disabled(chat.isStopping || !chat.isRunning && !canSend)
        .help(appLocalized(chat.isStopping ? "正在停止…" : stops ? "停止" : chat.isRunning ? "排队发送（当前任务结束后发出）" : "发送"))
        .accessibilityLabel(appLocalized(chat.isStopping ? "正在停止…" : stops ? "停止" : "发送"))
    }

    private func submit() {
        guard canSend, !chat.isStopping else { return }
        chat.send(draft)
        draft = ""
    }

    /// Messages typed during a run wait here: send now (interrupting, the
    /// work so far is kept) or let them go out when the turn ends.
    @ViewBuilder
    private var queueBar: some View {
        if !chat.queued.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(chat.queued.enumerated()), id: \.offset) { index, message in
                    HStack(spacing: 8) {
                        AppLineIcon(kind: .clock, size: 13).foregroundStyle(EditorTheme.tertiaryText)
                        Text(message.text).font(.appUI(size: 13)).foregroundStyle(EditorTheme.primaryText).lineLimit(2)
                        Spacer(minLength: 4)
                        AIIconButton(icon: .close, help: "取消这条", size: 22) { chat.removeQueued(at: index) }
                    }
                }
                HStack(spacing: 6) {
                    Text(appLocalized(chat.isStopping ? "正在打断…" : chat.isRunning ? "当前任务结束后自动发送" : "即将发送"))
                        .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
                    Spacer()
                    if chat.isRunning {
                        Button(appLocalized("立即打断并发送")) { chat.interruptWithQueued() }
                            .buttonStyle(AISmallButtonStyle(filled: true))
                            .disabled(chat.isStopping)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EditorTheme.panelRaised))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
            .padding(.horizontal, 10).padding(.bottom, 6)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

private struct MessageRow: View, @MainActor Equatable {
    let chat: AgentChatModel
    let message: AgentChatModel.Message
    let isRunning: Bool
    let provider: AgentChatModel.Provider?
    let switchableProviders: [AgentChatModel.Provider]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chat === rhs.chat && lhs.message == rhs.message && lhs.isRunning == rhs.isRunning
            && lhs.provider == rhs.provider && lhs.switchableProviders == rhs.switchableProviders
    }

    let onDismiss: () -> Void
    let onAction: (AgentChatModel.Message.Action) -> Void
    @State private var showsDetail = false
    @State private var stepsExpanded = false
    @State private var stepContentHeight: CGFloat = 44
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .user: userTurn
        case .assistant: assistantText
        case .activity:
            // A stop the user asked for is a quiet note, not a success tick.
            let neutral = message.text == appLocalized("已停止") || message.text == appLocalized("已打断，继续处理你的新消息")
                || message.text.hasPrefix(appLocalized("已切换到"))
            HStack(spacing: 6) {
                if neutral {
                    Circle().fill(EditorTheme.tertiaryText).frame(width: 5, height: 5).frame(width: 13)
                } else {
                    AppLineIcon(kind: .checkCircle, size: 13).foregroundStyle(EditorTheme.success)
                }
                Text(message.text).font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
            }
        case .steps: stepList
        case .result: resultCard
        case .error: errorCard
        }
    }

    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let attachments = message.attachments, !attachments.isEmpty {
                let images = attachments.filter { $0.kind == .image }
                let files = attachments.filter { $0.kind == .text }
                if images.count == 1, let image = images.first {
                    SentImage(attachment: image, size: CGSize(width: 200, height: 120))
                } else if !images.isEmpty {
                    AIFlowLayout(spacing: 6, alignment: .trailing) {
                        ForEach(images) { SentImage(attachment: $0, size: CGSize(width: 88, height: 64)) }
                    }
                }
                ForEach(files) { FileChip(attachment: $0) }
            }
            AIFoldableText(text: message.text, lineLimit: 4, lineSpacing: 2)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EditorTheme.selectionWash))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 32)
    }

    private var assistantText: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Parsed here, not through LocalizedStringKey: with the app in
            // Chinese that path lays text out with extra space after every
            // full-width comma and colon.
            AIFoldableText(text: message.text, markdown: true, isStreaming: isRunning && message.meta == nil)
                // A comfortable line when the panel is dragged wide.
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let meta = message.meta {
                HStack(spacing: 2) {
                    Text(meta).font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
                        .padding(.trailing, 6)
                    AIIconButton(icon: copied ? .check : .paste, help: copied ? "已复制" : "复制", size: 24) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                        withAnimation(SpringMotion.micro) { copied = true }
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(1.6))
                            withAnimation(SpringMotion.micro) { copied = false }
                        }
                    }
                    AIIconButton(icon: .refresh, help: "重新回答", size: 24) { chat.retry(message.id) }
                        .disabled(isRunning)
                    if copied {
                        Text(appLocalized("已复制"))
                            .font(.appUI(size: 12))
                            .foregroundStyle(EditorTheme.tertiaryText)
                            .padding(.leading, 4)
                            .transition(.opacity)
                    }
                }
            }
        }
    }

    /// The turn's edits, one row each. A row that touched the timeline can
    /// move the playhead there.
    private var stepList: some View {
        let steps = message.steps ?? []
        return VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { stepsExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Text(appLocalized("操作记录"))
                        .font(.appUI(size: 13, weight: .semibold))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text(String(format: appLocalized("%lld 次"), Int64(steps.count)))
                        .font(.appUI(size: 13).monospacedDigit())
                        .foregroundStyle(EditorTheme.secondaryText)
                    Spacer(minLength: 0)
                    AppLineIcon(kind: stepsExpanded ? .chevronUp : .chevronDown, size: 11)
                        .foregroundStyle(EditorTheme.tertiaryText)
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if stepsExpanded {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(AgentStepGroup.collect(steps)) { group in
                            Rectangle().fill(EditorTheme.hairline).frame(height: 1)
                            AIStepGroupRow(group: group, onLocate: chat.locate)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if abs(stepContentHeight - height) > 1 { stepContentHeight = height }
                    }
                }
                .scrollIndicators(.visible)
                .frame(height: min(340, max(44, stepContentHeight)))

            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// What the turn changed, with play and undo.
    private var resultCard: some View {
        let reverted = message.reverted == true
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                AppLineIcon(kind: reverted ? .undo : .check, size: 13)
                    .foregroundStyle(reverted ? EditorTheme.secondaryText : EditorTheme.success)
                Text(reverted ? appLocalized("已撤销这些修改") : message.text)
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
            }
            if let changes = message.changes, !reverted {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(changes, id: \.label) { change in
                        GridRow {
                            Text(change.label).foregroundStyle(EditorTheme.secondaryText)
                            Text(change.value).foregroundStyle(EditorTheme.primaryText).monospacedDigit()
                        }
                    }
                }
                .font(.appUI(size: 13))
            }
            if !reverted {
                HStack(spacing: 6) {
                    if let time = firstStepTime {
                        Button { chat.preview(at: time) } label: {
                            HStack(spacing: 5) { AppLineIcon(kind: .play, size: 11); Text(appLocalized("预览")) }
                        }
                        .buttonStyle(AISmallButtonStyle(filled: true))
                    }
                    Button(appLocalized("撤销全部")) { chat.revert(message.id) }
                        .buttonStyle(AISmallButtonStyle(filled: false))
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
    }

    private var firstStepTime: Double? {
        guard let turn = message.turn else { return nil }
        return chat.messages.first { $0.role == .steps && $0.turn == turn }?
            .steps?.compactMap(\.time).min()
    }

    private var errorCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(appLocalized("没有完成这次请求"))
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.destructiveText)
                Spacer(minLength: 4)
                AIIconButton(icon: .close, help: "关闭", size: 22, action: onDismiss)
            }
            Text(message.text)
                .font(.appUI(size: 13))
                .foregroundStyle(EditorTheme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if message.action == .switchProvider {
                    // Quota used up: the same request on another AI, same conversation.
                    let others = switchableProviders.filter { $0 != provider }
                    if others.isEmpty {
                        Button(appLocalized("换一个模型")) { onAction(.chooseModel) }
                            .buttonStyle(AISmallButtonStyle(filled: true))
                    } else {
                        Menu {
                            ForEach(others) { provider in
                                Button(provider.title) { chat.continueElsewhere(provider, from: message.id) }
                            }
                        } label: {
                            Text(appLocalized("换个 AI 继续"))
                        }
                        .menuStyle(.button)
                        .buttonStyle(AISmallButtonStyle(filled: true))
                        .fixedSize()
                    }
                } else if let action = message.action {
                    Button(appLocalized(action == .signIn ? String(format: appLocalized("重新登录 %@"), provider?.title ?? "")
                                                          : "换一个模型")) { onAction(action) }
                        .buttonStyle(AISmallButtonStyle(filled: true))
                }
                if message.detail != nil {
                    Button(appLocalized(showsDetail ? "收起详情" : "查看详情")) {
                        withAnimation(SpringMotion.panel) { showsDetail.toggle() }
                    }
                    .buttonStyle(AISmallButtonStyle(filled: false))
                }
            }
            if showsDetail, let detail = message.detail {
                ScrollView {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(EditorTheme.chrome(0.04)))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(EditorTheme.destructiveText.opacity(0.07)))
    }
}

private struct AIStepGroupRow: View {
    let group: AgentStepGroup
    let onLocate: (Double) -> Void
    @State private var expanded = false

    var body: some View {
        if group.isRepeatedRead {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        AppLineIcon(kind: .eye, size: 14).foregroundStyle(EditorTheme.secondaryText)
                        Text(group.steps[0].title).font(.appUI(size: 13))
                            .foregroundStyle(EditorTheme.primaryText)
                        Spacer(minLength: 4)
                        Text(String(format: appLocalized("%lld 次"), Int64(group.steps.count)))
                            .font(.appUI(size: 12).monospacedDigit()).foregroundStyle(EditorTheme.tertiaryText)
                        AppLineIcon(kind: expanded ? .chevronUp : .chevronDown, size: 10)
                            .foregroundStyle(EditorTheme.tertiaryText)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if expanded {
                    ForEach(group.steps) { step in
                        Rectangle().fill(EditorTheme.hairline).frame(height: 1)
                        StepRow(step: step, onLocate: step.time.map { time in { onLocate(time) } })
                    }
                }
            }
        } else if let step = group.steps.first {
            StepRow(step: step, onLocate: step.time.map { time in { onLocate(time) } })
        }
    }
}

private struct StepRow: View {
    let step: AgentChatModel.Step
    let onLocate: (() -> Void)?
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row
            if let images = step.images, !images.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(images, id: \.self) { path in
                            StepThumbnail(path: path)
                        }
                    }
                }
                .scrollIndicators(.never)
                .padding(.leading, 34).padding(.trailing, 10).padding(.bottom, 8)
            }
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                if step.readOnlyMethod != nil {
                    AppLineIcon(kind: .eye, size: 14).foregroundStyle(EditorTheme.secondaryText)
                } else {
                    Circle().fill(EditorTheme.success)
                    AppLineIcon(kind: .check, size: 9).foregroundStyle(.white)
                }
            }
            .frame(width: 16, height: 16)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.title)
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.primaryText)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(EditorTheme.tertiaryText)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if let onLocate {
                Button(appLocalized("定位"), action: onLocate)
                    .buttonStyle(.plain)
                    .font(.appUI(size: 12))
                    .foregroundStyle(hovered ? EditorTheme.accent : EditorTheme.tertiaryText)
                    .onHover { hovered = $0 }
                    .help(appLocalized("把播放头移到这里"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

private struct StepSpinner: View {
    @State private var turning = false
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(EditorTheme.accent, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .frame(width: 16, height: 16)
            .onAppear {
                guard !RecorderMotion.reduces else { return }
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}

/// "12 秒" that keeps counting while a turn runs.
private struct ElapsedText: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(AgentChatModel.elapsedText(context.date.timeIntervalSince(since)))
                .font(.appUI(size: 12).monospacedDigit())
                .foregroundStyle(EditorTheme.tertiaryText)
        }
    }
}

/// The one "working" row of a turn: what it is doing now, its live thinking
/// (folded to two lines, expandable), and a progress bar for long work.
private struct LiveActivityRow: View {
    let activity: AgentChatModel.Activity?
    let startedAt: Date?
    @State private var expanded = false

    var body: some View {
        let title = activity?.title ?? appLocalized("正在思考")
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StepSpinner()
                Text(title)
                    .font(.appUI(size: 13, weight: .medium))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .contentTransition(.opacity)
                if let startedAt { ElapsedText(since: startedAt) }
                Spacer(minLength: 0)
                if let thought = activity?.thought, !thought.isEmpty {
                    Button {
                        withAnimation(SpringMotion.panel) { expanded.toggle() }
                    } label: {
                        AppLineIcon(kind: expanded ? .chevronUp : .chevronDown, size: 11)
                            .foregroundStyle(EditorTheme.tertiaryText)
                            .frame(width: 22, height: 22).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(appLocalized(expanded ? "收起" : "展开它正在想的内容"))
                }
            }
            if let progress = activity?.progress {
                VStack(alignment: .leading, spacing: 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(EditorTheme.controlWell)
                            Capsule().fill(EditorTheme.accent).frame(width: max(proxy.size.width * progress, 4))
                        }
                    }
                    .frame(height: 4)
                    if let detail = activity?.detail {
                        Text(detail).font(.appUI(size: 12).monospacedDigit()).foregroundStyle(EditorTheme.tertiaryText)
                    }
                }
                .padding(.leading, 24)
                .animation(.linear(duration: 0.2), value: progress)
            } else if let detail = activity?.detail, !detail.isEmpty {
                Text(detail).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle).padding(.leading, 24)
            }
            if let thought = activity?.thought, !thought.isEmpty {
                Text(thought.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.appUI(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(expanded ? 12 : 2)
                    .truncationMode(.head)
                    .padding(.leading, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(SpringMotion.micro, value: title)
    }
}

/// A preview frame the AI rendered, shown in its step; click to open.
private struct StepThumbnail: View {
    let path: String
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            // A checker-free dark ground so transparent overlays read.
            Color(white: 0.16)
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        .help(URL(fileURLWithPath: path).lastPathComponent)
        .task(id: path) { image = await AttachmentThumbnails.load(path) }
    }
}

// MARK: Attachments

/// An image the user sent, shown as a picture above their words.
private struct SentImage: View {
    let attachment: AgentChatModel.Attachment
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            EditorTheme.controlWell
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) }
        .help(attachment.name)
        .task(id: attachment.path) { image = await AttachmentThumbnails.load(attachment.path) }
    }
}

/// A text file the user sent: name and size.
private struct FileChip: View {
    let attachment: AgentChatModel.Attachment
    var body: some View {
        HStack(spacing: 6) {
            AppLineIcon(kind: .list, size: 13).foregroundStyle(EditorTheme.secondaryText)
            Text(attachment.name).font(.appUI(size: 13)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(EditorTheme.primaryText)
            Text(AttachmentThumbnails.sizeText(attachment.path))
                .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) }
    }
}

/// An attachment waiting in the composer: a 56 pt square with ×.
private struct PendingAttachmentTile: View {
    let attachment: AgentChatModel.Attachment
    let onRemove: () -> Void
    @State private var image: NSImage?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if attachment.kind == .image {
                    ZStack {
                        EditorTheme.controlWell
                        if let image {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(width: 56, height: 56)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.name).font(.appUI(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(EditorTheme.primaryText)
                        Text(AttachmentThumbnails.lineText(attachment.path))
                            .font(.appUI(size: 11)).foregroundStyle(EditorTheme.secondaryText)
                    }
                    .padding(.horizontal, 8)
                    .frame(width: 100, height: 56, alignment: .leading)
                    .background(EditorTheme.controlWell)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
            .help(attachment.name)
            Button(action: onRemove) {
                AppLineIcon(kind: .close, size: 9)
                    .foregroundStyle(EditorTheme.panelRaised)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(EditorTheme.primaryText))
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .accessibilityLabel(appLocalized("移除附件"))
        }
        .task(id: attachment.path) {
            guard attachment.kind == .image else { return }
            image = await AttachmentThumbnails.load(attachment.path)
        }
    }
}

/// Small, downsampled thumbnails so a 5K screenshot never stalls the panel.
private enum AttachmentThumbnails {
    static func load(_ path: String) async -> NSImage? {
        await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
    }

    static func sizeText(_ path: String) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func lineText(_ path: String) -> String {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return String(format: appLocalized("%lld 行"), Int64(text.split(separator: "\n", omittingEmptySubsequences: false).count))
    }
}

// MARK: Model picker

/// Claude-style picker: each model with one line on what it is for, a tick
/// on the current one; the thinking level as four named choices.
private struct ComposerModelPopover: View {
    @ObservedObject var chat: AgentChatModel
    @State private var showsOlder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chat.switchableProviders.count > 1 {
                providerSection
                divider
            }
            if chat.provider == .api {
                apiSection
            } else if chat.provider == .codex, chat.codexModels.isEmpty, chat.codexModelsFailed {
                HStack(spacing: 8) {
                    Text(appLocalized("没能读取模型列表。"))
                        .font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
                    Button(appLocalized("重试")) { chat.loadCodexModels() }
                        .buttonStyle(AISmallButtonStyle(filled: false))
                }
                .padding(12)
            } else if chat.cliModels.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity).padding(20)
                    .onAppear { chat.loadCodexModels() }
            } else {
                section("模型")
                let current = chat.cliModels.filter { !AgentChatModel.isOlder($0) }
                let older = chat.cliModels.filter { AgentChatModel.isOlder($0) }
                ForEach(current.isEmpty ? chat.cliModels : current) { model in
                    modelRow(model)
                }
                if !current.isEmpty, !older.isEmpty {
                    Button {
                        showsOlder.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Text(appLocalized("旧版模型")).font(.appUI(size: 13))
                            Text(verbatim: "\(older.count)").font(.appUI(size: 13).monospacedDigit())
                                .foregroundStyle(EditorTheme.tertiaryText)
                            Spacer()
                            AppLineIcon(kind: showsOlder ? .chevronUp : .chevronDown, size: 11)
                        }
                        .foregroundStyle(EditorTheme.secondaryText)
                        .padding(.horizontal, 10).frame(height: 32)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(AIRowStyle())
                    if showsOlder || older.contains(where: { $0.slug == chat.selectedCLIModel?.slug }) {
                        ForEach(older) { model in modelRow(model) }
                    }
                }
                if let model = chat.selectedCLIModel {
                    let efforts = Self.efforts(for: model)
                    if efforts.count > 1 {
                        divider
                        effortSection(model: model, efforts: efforts)
                    }
                }
                divider
                accountRow
            }
        }
        .padding(6)
        .frame(width: 300)
        // Measure the complete list independently of the floating viewport.
        // The presenter sizes the window and scrolls only at the screen edge.
        .fixedSize(horizontal: false, vertical: true)
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
        .onChange(of: chat.provider) { _, _ in showsOlder = false }
    }

    /// The AI answering this conversation. Switching keeps the conversation:
    /// the next message goes to the new one with everything said so far.
    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            section("AI")
            let providers = chat.switchableProviders
            // The same segmented control the thinking level uses, so switching
            // AI slides like every other choice in the editor instead of
            // snapping. It was the only hand-rolled segmented row left here.
            EditorSegmentedControl(
                options: providers,
                title: { $0.shortTitle },
                compactTitle: { $0 == .gemini ? "AGY" : nil },
                accessibilityTitle: { $0.title },
                optionHelp: { $0.title },
                selection: Binding(
                    get: { chat.provider ?? providers.first ?? .codex },
                    set: { chat.switchProvider(to: $0) }
                )
            )
            .disabled(chat.isRunning)
            .padding(.horizontal, 6)
            if !chat.messages.isEmpty {
                Text(appLocalized("切换后接着当前对话继续。"))
                    .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
                    .padding(.horizontal, 10).padding(.top, 2)
            }
        }
    }

    private static func efforts(for model: AgentChatModel.CodexModel) -> [String] {
        let preferred = ["low", "medium", "high", "xhigh"]
        let list = model.efforts.filter { preferred.contains($0) }
        return list.isEmpty ? model.efforts : list
    }

    private func section(_ title: String) -> some View {
        Text(appLocalized(title))
            .font(.appUI(size: 12))
            .foregroundStyle(EditorTheme.tertiaryText)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
    }

    private var divider: some View {
        Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 6)
    }

    private func modelRow(_ model: AgentChatModel.CodexModel) -> some View {
        let selected = chat.selectedCLIModel?.slug == model.slug
        return Button {
            chat.selectCLIModel(model)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.appUI(size: 14, weight: .medium))
                        .foregroundStyle(EditorTheme.primaryText)
                    Text(chat.modelUse(model))
                        .font(.appUI(size: 12))
                        .foregroundStyle(EditorTheme.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                AppLineIcon(kind: .check, size: 14)
                    .foregroundStyle(EditorTheme.accent)
                    .padding(.top, 2)
                    .opacity(selected ? 1 : 0)
                    .scaleEffect(selected ? 1 : 0.6)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .animation(SpringMotion.micro, value: selected)
        }
        .buttonStyle(AIRowStyle())
    }

    private func effortSection(model: AgentChatModel.CodexModel, efforts: [String]) -> some View {
        let current = chat.cliEffort.isEmpty ? model.defaultEffort : chat.cliEffort
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(appLocalized("思考强度")).font(.appUI(size: 13)).foregroundStyle(EditorTheme.primaryText)
                Spacer()
                Text(AgentChatModel.effortName(current)).font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
            }
            EditorSegmentedControl(
                options: efforts,
                title: { AgentChatModel.effortName($0) },
                selection: Binding(get: { efforts.contains(current) ? current : efforts[0] },
                                   set: { chat.setCLIEffort($0) })
            )
            Text(AgentChatModel.effortHint(current))
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.tertiaryText)
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
    }

    private var accountRow: some View {
        HStack(spacing: 8) {
            let signedOut = chat.cliAccount == .signedOut
            Circle().fill(signedOut ? EditorTheme.amberAccent : EditorTheme.success)
                .frame(width: 6, height: 6)
            Text((chat.provider?.title ?? "") + " · " + appLocalized(signedOut ? "未登录" : "已登录"))
                .font(.appUI(size: 13)).foregroundStyle(EditorTheme.secondaryText)
            Spacer()
            if signedOut {
                Button(appLocalized("登录")) {
                    if let provider = chat.provider { chat.signIn(provider) }
                }
                .buttonStyle(AISmallButtonStyle(filled: true))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .onAppear {
            if let provider = chat.provider, chat.cliAccount == .unknown { chat.refreshAccount(provider) }
        }
    }

    /// API models as the same Claude-style list, read from the endpoint;
    /// a field to type a name when the endpoint does not list models.
    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            section("模型")
            if chat.apiModels.isEmpty {
                TextField("gpt-4.1", text: $chat.apiModel)
                    .textFieldStyle(.plain)
                    .font(.appUI(size: 14))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EditorTheme.controlWell))
                    .padding(.horizontal, 6).padding(.bottom, 4)
                    .onSubmit { UserDefaults.standard.set(chat.apiModel, forKey: "agent.api.model") }
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(chat.apiModels, id: \.self) { model in
                            Button {
                                chat.apiModel = model
                                UserDefaults.standard.set(model, forKey: "agent.api.model")
                            } label: {
                                HStack {
                                    Text(model).font(.appUI(size: 14)).foregroundStyle(EditorTheme.primaryText)
                                    Spacer()
                                    if model == chat.apiModel {
                                        AppLineIcon(kind: .check, size: 14).foregroundStyle(EditorTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 10).frame(height: 34)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(AIRowStyle())
                        }
                    }
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
            }
            divider
            HStack {
                Text(chat.apiBaseURL)
                    .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(appLocalized("刷新列表")) { chat.loadAPIModels() }
                    .buttonStyle(AISmallButtonStyle(filled: false))
            }
            .padding(.horizontal, 10).padding(.bottom, 2)
        }
        .onAppear { if chat.apiModels.isEmpty { chat.loadAPIModels() } }
    }
}

// MARK: History

private struct ThreadHistoryPopover: View {
    @ObservedObject var chat: AgentChatModel
    let onClose: () -> Void

    var body: some View {
        let others = chat.threads.filter { $0.id != chat.currentThreadID }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(appLocalized("对话记录"))
                    .font(.appUI(size: 13, weight: .semibold))
                    .foregroundStyle(EditorTheme.primaryText)
                Spacer()
                Button {
                    chat.newThread()
                    onClose()
                } label: {
                    HStack(spacing: 4) { AppLineIcon(kind: .plus, size: 11); Text(appLocalized("新对话")) }
                }
                .buttonStyle(AISmallButtonStyle(filled: false))
                .disabled(chat.isRunning || chat.messages.isEmpty)
            }
            .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
            Rectangle().fill(EditorTheme.hairline).frame(height: 1).padding(.vertical, 4)
            if others.isEmpty {
                Text(appLocalized("还没有更早的对话。开始新对话后，当前这段会保存在这里。"))
                    .font(.appUI(size: 13))
                    .foregroundStyle(EditorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(others) { thread in
                            ThreadRow(thread: thread) {
                                chat.openThread(thread.id)
                                onClose()
                            } onDelete: {
                                chat.deleteThread(thread.id)
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(6)
        .frame(maxWidth: 300)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
    }
}

private struct ThreadRow: View {
    let thread: AgentChatModel.ThreadSummary
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.title).font(.appUI(size: 14)).lineLimit(1)
                    .foregroundStyle(EditorTheme.primaryText)
                Text(thread.date, format: .relative(presentation: .named))
                    .font(.appUI(size: 12)).foregroundStyle(EditorTheme.tertiaryText)
            }
            Spacer(minLength: 4)
            if hovered {
                AIIconButton(icon: .trash, help: "删除这段对话", size: 24, action: onDelete)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(EditorTheme.chrome(hovered ? 0.045 : 0)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovered = $0 }
        .animation(SpringMotion.micro, value: hovered)
    }
}

// MARK: Small controls

private struct AIIconButton: View {
    let icon: AppLineIcon.Kind
    let help: String
    var size: CGFloat = 28
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            AppLineIcon(kind: icon, size: size > 24 ? 15 : 13)
                .foregroundStyle(EditorTheme.secondaryText)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(AIPressStyle(radius: 6))
        .opacity(isEnabled ? 1 : 0.4)
        .help(appLocalized(help))
        .accessibilityLabel(appLocalized(help))
    }
}

private struct AIPressStyle: ButtonStyle {
    var radius: CGFloat = 8
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        PressBody(configuration: configuration, radius: radius)
    }
    struct PressBody: View {
        let configuration: ButtonStyleConfiguration
        let radius: CGFloat
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(EditorTheme.chrome(configuration.isPressed ? 0.08 : hovered ? 0.045 : 0)))
                .onHover { hovered = $0 }
                .animation(SpringMotion.micro, value: hovered)
        }
    }
}

private struct AIRowStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        AIPressStyle.PressBody(configuration: configuration, radius: 8)
    }
}

private struct AISmallButtonStyle: ButtonStyle {
    let filled: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appUI(size: 13))
            .foregroundStyle(filled ? EditorTheme.onAccentFill : EditorTheme.secondaryText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(filled ? EditorTheme.accent.opacity(configuration.isPressed ? 0.85 : 1)
                             : EditorTheme.chrome(configuration.isPressed ? 0.06 : 0)))
            .contentShape(Rectangle())
    }
}

/// Wraps chips onto as many rows as they need.
private struct AIFlowLayout: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += rowHeight + spacing; x = 0; rowHeight = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var rows: [[(Subviews.Element, CGSize)]] = [[]]
        var x: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width { rows.append([]); x = 0 }
            rows[rows.count - 1].append((view, size))
            x += size.width + spacing
        }
        var y = bounds.minY
        for row in rows {
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(row.count - 1, 0))
            var cursor = alignment == .trailing ? bounds.maxX - rowWidth : bounds.minX
            let height = row.map(\.1.height).max() ?? 0
            for (view, size) in row {
                view.place(at: CGPoint(x: cursor, y: y), proposal: ProposedViewSize(size))
                cursor += size.width + spacing
            }
            y += height + spacing
        }
    }
}

/// ⌘K: a one-line request over the canvas. Sending hands it to the AI page
/// in the library, which then shows the conversation at full height.
struct EditorQuickPrompt: View {
    @ObservedObject private var chat = AgentChatModel.shared
    let onSend: () -> Void
    let onClose: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppLineIcon(kind: .sparkle, size: 15)
                .foregroundStyle(EditorTheme.accent)
            TextField(appLocalized(chat.provider == nil ? "先在左侧 AI 页连接一个 AI" : "让 AI 修改这个视频…"), text: $draft)
                .textFieldStyle(.plain)
                .font(.appUI(size: 15))
                .foregroundStyle(EditorTheme.primaryText)
                .focused($focused)
                .disabled(chat.provider == nil)
                .onSubmit(send)
                .onExitCommand(perform: onClose)
            Text(appLocalized("↵ 发送"))
                .font(.appUI(size: 12))
                .foregroundStyle(EditorTheme.tertiaryText)
        }
        .padding(.horizontal, 14)
        .frame(width: 520, height: 48)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EditorTheme.panelRaised))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(EditorTheme.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .onAppear { focused = true }
        .onChange(of: focused) { _, isFocused in if !isFocused, draft.isEmpty { onClose() } }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.send(text)
        draft = ""
        onSend()
    }
}
