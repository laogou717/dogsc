import AppKit
import Foundation
import ImageIO
import Security

/// EDT-054: the in-app AI conversation. A provider is either a coding agent
/// already installed on this Mac (Codex / Claude Code, reaching DogSC through
/// the bundled `dogsc-mcp`) or any OpenAI-compatible API key (DogSC runs the
/// tool loop itself). Every edit flows through AgentBridgeServer, which
/// reports progress into this conversation.
@MainActor
final class AgentChatModel: ObservableObject {
    static let shared = AgentChatModel()

    /// In-app providers: a coding-agent CLI the user installed and signed in
    /// to themselves (DogSC only launches it; it never sees credentials), or
    /// an OpenAI-compatible API key.
    enum Provider: String, CaseIterable, Identifiable {
        case codex, claude, gemini, kimi, api
        var id: String { rawValue }
        var title: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude Code"
            case .gemini: "Antigravity CLI"
            case .kimi: "Kimi Code"
            case .api: appLocalized("API Key")
            }
        }
        /// For the narrow AI switcher.
        var shortTitle: String {
            switch self {
            case .codex: "Codex"
            case .claude: "Claude"
            case .gemini: "Antigravity"
            case .kimi: "Kimi"
            case .api: "API"
            }
        }
        var executable: String? {
            switch self {
            case .codex: "codex"
            case .claude: "claude"
            case .gemini: "agy"
            case .kimi: "kimi"
            case .api: nil
            }
        }
        /// CLIs whose model and effort DogSC keeps per provider.
        var isCLI: Bool { executable != nil }
    }

    /// Keep the persisted `gemini` provider ID so existing conversations and
    /// preferences migrate without losing their selected provider.
    private static var antigravityDefaultModel: CodexModel {
        CodexModel(slug: "", name: appLocalized("CLI 默认"), summary: "", efforts: [], defaultEffort: "")
    }

    /// Claude Code's model aliases (always the latest of each family).
    static let claudeModels: [CodexModel] = [
        CodexModel(slug: "opus", name: "Opus", summary: appLocalized("最强，适合复杂的多步修改和创作"),
                   efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high"),
        CodexModel(slug: "sonnet", name: "Sonnet", summary: appLocalized("主力模型，日常修改的首选"),
                   efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
        CodexModel(slug: "haiku", name: "Haiku", summary: appLocalized("更快，适合改字幕、调参数"),
                   efforts: ["low", "medium", "high"], defaultEffort: "low"),
    ]

    enum CodexAccount: Equatable { case unknown, checking, signedIn, signedOut, signingIn }

    /// One entry of Codex's own model catalog (`codex debug models`).
    struct CodexModel: Identifiable, Hashable {
        let slug: String
        let name: String
        let summary: String
        let efforts: [String]
        let defaultEffort: String
        var id: String { slug }
    }

    /// EDT-060: a reference sent with a request — an image the AI looks at,
    /// or a text file whose contents it reads. Stored in the project's AI
    /// folder so the conversation keeps it.
    struct Attachment: Identifiable, Equatable, Codable, Sendable {
        enum Kind: String, Codable, Sendable { case image, text }
        var id = UUID()
        var kind: Kind
        var path: String
        var name: String
    }

    /// One edit the AI made during a turn, shown as a row in the turn's
    /// step list. `time` lets the row move the playhead to the change.
    struct Step: Identifiable, Equatable, Codable, Sendable {
        var id = UUID()
        var title: String
        var detail: String? = nil
        var time: Double? = nil
        var done = true
        /// Preview frames the step produced, shown as thumbnails.
        var images: [String]? = nil
        /// Optional so saved conversations from earlier builds still decode.
        var method: String? = nil

        var readOnlyMethod: String? {
            if let method {
                return Self.readOnlyMethods.contains(method) ? method : nil
            }
            // Narrow compatibility for old steps emitted by our own bridge.
            // Never group an unknown title or an edit based on text similarity.
            let legacy: [(String, String)] = [
                ("分析了语音与停顿", "audio.analyzeEdits"),
                ("读取了项目信息", "project.summary"),
                ("读取了现有字幕", "subtitles.get"),
                ("查看了素材箱", "media.list"),
                ("查看了画面", "canvas.snapshot"),
                ("预览了动效画面", "html.preview"),
                ("查看了时间线", "timeline.inspect"),
            ]
            return legacy.first { title == $0.0 || title == appLocalized($0.0) }?.1
        }

        private static let readOnlyMethods: Set<String> = [
            "project.summary", "media.list", "timeline.get", "timeline.inspect",
            "pointer.events", "subtitles.get", "settings.get", "app.help",
            "audio.transcribe", "audio.analyzeEdits", "canvas.snapshot", "html.preview",
        ]
    }

    /// What the running turn is doing right now, shown in the one live row
    /// at the bottom of the conversation.
    struct Activity: Equatable {
        enum Kind: Equatable { case thinking, writing, tool, rendering }
        var kind: Kind
        var title: String
        /// The tail of the model's live thinking, when the CLI streams it.
        var thought: String = ""
        /// 0…1 for long DogSC work (rendering a clip, transcribing).
        var progress: Double? = nil
        var detail: String? = nil
    }

    /// What a finished turn changed, line by line (`标题动画 · 新增 0:00–0:03`).
    struct Change: Equatable, Codable, Sendable {
        var label: String
        var value: String
    }

    struct Message: Identifiable, Equatable, Codable, Sendable {
        enum Role: String, Codable, Sendable { case user, assistant, activity, error, steps, result }
        enum Action: String, Codable, Sendable { case signIn, chooseModel, switchProvider }
        var id = UUID()
        let role: Role
        var text: String
        var action: Action? = nil
        var detail: String? = nil
        var attachments: [Attachment]? = nil
        var steps: [Step]? = nil
        var changes: [Change]? = nil
        /// "GPT-6.1 · 中 · 41 秒" under a reply.
        var meta: String? = nil
        /// The turn whose edits a result card can undo.
        var turn: UUID? = nil
        var reverted: Bool? = nil
    }

    /// A past conversation of this project, newest first in the history list.
    struct ThreadSummary: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let date: Date
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp"]
    static let textExtensions: Set<String> = ["txt", "md", "markdown", "srt", "vtt", "csv", "json"]
    static let maxAttachments = 6

    /// Attachments waiting to be sent with the next message.
    @Published private(set) var pendingAttachments: [Attachment] = []

    private var attachmentsFolder: URL? {
        guard let workspace = AgentBridgeServer.shared.workspaceURL else { return nil }
        let folder = workspace.appendingPathComponent("attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Copies dropped/picked images and text files into the AI folder.
    @discardableResult
    func attach(_ urls: [URL]) -> Bool {
        guard let folder = attachmentsFolder else { return false }
        var added = false
        for url in urls where pendingAttachments.count < Self.maxAttachments {
            let ext = url.pathExtension.lowercased()
            let kind: Attachment.Kind
            if Self.imageExtensions.contains(ext) { kind = .image }
            else if Self.textExtensions.contains(ext) { kind = .text }
            else { continue }
            let destination = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-\(url.lastPathComponent)")
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { continue }
            pendingAttachments.append(Attachment(kind: kind, path: destination.path, name: url.lastPathComponent))
            added = true
        }
        return added
    }

    /// Saves a pasted picture (e.g. a screenshot) as PNG.
    @discardableResult
    func attach(image: NSImage) -> Bool {
        guard pendingAttachments.count < Self.maxAttachments, let folder = attachmentsFolder,
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        let name = String(format: appLocalized("粘贴的图片 %lld.png"), Int64(pendingAttachments.count + 1))
        let destination = folder.appendingPathComponent("\(UUID().uuidString.prefix(8))-pasted.png")
        guard (try? png.write(to: destination)) != nil else { return false }
        pendingAttachments.append(Attachment(kind: .image, path: destination.path, name: name))
        return true
    }

    func removePendingAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Consume recognized attachments even at the limit, so an image's URL or
    /// fallback text cannot leak into the message or the monitor's paste action.
    @discardableResult
    func pasteAttachments(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let content = AgentAttachmentPasteboard.read(pasteboard) else { return false }
        switch content {
        case let .files(urls): attach(urls)
        case let .image(image): attach(image: image)
        }
        return true
    }

    /// Text files inlined into the request, images described by path.
    private static func attachmentNote(_ attachments: [Attachment]) -> String {
        guard !attachments.isEmpty else { return "" }
        var note = "\n\nAttachments from the user:"
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                note += "\n- Reference image \"\(attachment.name)\" (\(attachment.path)). If it shows a design, match its style:"
                    + " palette, typography, layout, spacing and motion feel. After creating motion, compare html_preview frames with it."
            case .text:
                let content = (try? String(contentsOfFile: attachment.path, encoding: .utf8)) ?? ""
                note += "\n- File \"\(attachment.name)\":\n```\n\(content.prefix(20_000))\n```"
            }
        }
        return note
    }

    @Published private(set) var provider: Provider?
    @Published private(set) var messages: [Message] = [] {
        didSet { messagesRevision &+= 1; saveConversation() }
    }
    private(set) var messagesRevision: UInt64 = 0
    private let conversationPersistence = AgentConversationPersistence()
    private var historyRevision: UInt64 = 0
    private var conversationWorkspace: URL?
    private var conversationURL: URL?
    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    /// When the running turn began, for the elapsed time under the reply.
    @Published private(set) var turnStartedAt: Date?
    @Published private(set) var activity: Activity?
    /// Messages typed while a turn runs; sent when it ends (or at once when
    /// the user chooses to interrupt).
    struct QueuedMessage: Equatable {
        let text: String
        let attachments: [Attachment]
    }
    @Published private(set) var queued: [QueuedMessage] = []
    private var turnID: UUID?
    private var turnStepsMessage: UUID?
    @Published private(set) var threads: [ThreadSummary] = []
    @Published var apiBaseURL: String
    @Published var apiModel: String
    @Published private(set) var codexAccount: CodexAccount = .unknown
    /// Empty uses Codex's default model for the signed-in account. DogSC runs
    /// Codex with its own settings, so a broken global config cannot break it.
    @Published var codexModel: String {
        didSet { UserDefaults.standard.set(codexModel, forKey: "agent.codex.model") }
    }
    @Published var codexEffort: String {
        didSet { UserDefaults.standard.set(codexEffort, forKey: "agent.codex.effort") }
    }
    @Published var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: "agent.claude.model") }
    }
    @Published var claudeEffort: String {
        didSet { UserDefaults.standard.set(claudeEffort, forKey: "agent.claude.effort") }
    }
    @Published private(set) var claudeAccount: CodexAccount = .unknown
    /// Model / effort chosen for Antigravity and Kimi (empty = the CLI's default).
    @Published var otherModel: [String: String] = [:] {
        didSet { UserDefaults.standard.set(otherModel, forKey: "agent.cli.model") }
    }
    @Published var otherEffort: [String: String] = [:] {
        didSet { UserDefaults.standard.set(otherEffort, forKey: "agent.cli.effort") }
    }
    @Published private(set) var otherAccount: [String: CodexAccount] = [:]
    @Published private(set) var antigravityModels: [CodexModel] = []
    /// Models Kimi Code's own config declares.
    @Published private(set) var kimiModels: [CodexModel] = []
    /// Models the API endpoint lists (`GET /models`); empty until loaded.
    @Published private(set) var apiModels: [String] = []
    @Published private(set) var apiModelsState: CodexAccount = .unknown
    @Published private(set) var codexModels: [CodexModel] = []
    @Published private(set) var codexModelsFailed = false
    private var isLoadingCodexModels = false

    var selectedCodexModel: CodexModel? {
        codexModels.first { $0.slug == codexModel } ?? codexModels.first
    }

    var selectedClaudeModel: CodexModel {
        Self.claudeModels.first { $0.slug == claudeModel } ?? Self.claudeModels[1]
    }

    /// The model list and current choice for the connected CLI.
    var cliModels: [CodexModel] {
        switch provider {
        case .claude: Self.claudeModels
        case .gemini: [Self.antigravityDefaultModel] + antigravityModels
        case .kimi: kimiModels
        default: codexModels
        }
    }

    var selectedCLIModel: CodexModel? {
        switch provider {
        case .claude: selectedClaudeModel
        case .gemini, .kimi:
            cliModels.first { $0.slug == otherModel[provider!.rawValue] } ?? cliModels.first
        default: selectedCodexModel
        }
    }

    var cliEffort: String {
        switch provider {
        case .claude: claudeEffort
        case .gemini, .kimi: otherEffort[provider!.rawValue] ?? ""
        default: codexEffort
        }
    }

    func selectCLIModel(_ model: CodexModel) {
        switch provider {
        case .claude:
            claudeModel = model.slug
            if !model.efforts.contains(claudeEffort) { claudeEffort = model.defaultEffort }
        case .gemini, .kimi:
            let key = provider!.rawValue
            otherModel[key] = model.slug
            if !model.efforts.contains(otherEffort[key] ?? "") { otherEffort[key] = model.defaultEffort }
        default:
            UserDefaults.standard.set(true, forKey: "agent.codex.modelChosen")
            codexModel = model.slug
            if !model.efforts.contains(codexEffort) { codexEffort = model.defaultEffort }
        }
    }

    func setCLIEffort(_ effort: String) {
        switch provider {
        case .claude: claudeEffort = effort
        case .gemini, .kimi: otherEffort[provider!.rawValue] = effort
        default: codexEffort = effort
        }
    }

    /// Whether the connected CLI is signed in (for the dot on the model button).
    var cliAccount: CodexAccount {
        switch provider {
        case .claude: claudeAccount
        case .gemini, .kimi: otherAccount[provider!.rawValue] ?? .unknown
        default: codexAccount
        }
    }

    func account(for candidate: Provider) -> CodexAccount {
        switch candidate {
        case .codex: codexAccount
        case .claude: claudeAccount
        case .gemini, .kimi: otherAccount[candidate.rawValue] ?? .unknown
        case .api: .signedIn
        }
    }

    func refreshAccount(_ candidate: Provider) {
        switch candidate {
        case .codex: refreshCodexAccount()
        case .claude: refreshClaudeAccount()
        case .gemini: refreshAntigravityAccount()
        case .kimi: refreshKimiAccount()
        case .api: break
        }
    }

    func signIn(_ candidate: Provider) {
        switch candidate {
        case .codex: signInToCodex()
        case .claude: signInToClaude()
        case .gemini, .kimi:
            guard let executable = AgentCLI.path(for: candidate.executable!) else { return }
            otherAccount[candidate.rawValue] = .signingIn
            // Both sign in inside their own terminal UI.
            let command = candidate == .kimi ? "'\(executable)' login" : "'\(executable)'"
            let script = "tell application \"Terminal\" to do script \"\(command)\"\ntell application \"Terminal\" to activate"
            NSAppleScript(source: script)?.executeAndReturnError(nil)
        case .api: break
        }
    }

    /// Listing the CLI's catalog checks its own saved login without sending
    /// a model prompt or copying credentials out of the system keychain.
    func refreshAntigravityAccount() {
        guard otherAccount["gemini"] != .checking else { return }
        guard AgentCLI.isInstalled("agy") else { otherAccount["gemini"] = .unknown; return }
        otherAccount["gemini"] = .checking
        Self.run("agy", ["models"], timeout: 30, mergesStandardError: true) { status, output in
            let catalog = AntigravityCLI.models(from: output)
            Task { @MainActor in
                if status == 0, !catalog.isEmpty {
                    self.antigravityModels = catalog.map {
                        CodexModel(slug: $0.slug, name: $0.name, summary: "", efforts: [], defaultEffort: "")
                    }
                    self.otherAccount["gemini"] = .signedIn
                } else {
                    self.otherAccount["gemini"] = Self.cliProblem(in: output, name: "Antigravity CLI")?.action == .signIn
                        ? .signedOut : .unknown
                }
            }
        }
    }

    /// Kimi Code keeps its own sign-in and model list under ~/.kimi-code.
    func refreshKimiAccount() {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".kimi-code")
        let credentials = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("credentials").path)) ?? []
        otherAccount["kimi"] = credentials.isEmpty ? .signedOut : .signedIn
        kimiModels = Self.kimiModels(from: home.appendingPathComponent("config.toml"))
    }

    /// `[models."alias"]` tables with display_name / support_efforts.
    static func kimiModels(from url: URL) -> [CodexModel] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var models: [CodexModel] = []
        var current: (slug: String, name: String, efforts: [String], effort: String)?
        func flush() {
            if let c = current {
                models.append(CodexModel(slug: c.slug, name: c.name.isEmpty ? c.slug : c.name, summary: "",
                                         efforts: c.efforts, defaultEffort: c.effort))
            }
            current = nil
        }
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                flush()
                if line.hasPrefix("[models.\""), let end = line.dropFirst(9).firstIndex(of: "\"") {
                    current = (String(line.dropFirst(9)[..<end]), "", [], "")
                }
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch key {
            case "display_name": current?.name = unquoted
            case "default_effort": current?.effort = unquoted
            case "support_efforts":
                current?.efforts = value.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                    .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
            default: break
            }
        }
        flush()
        return models
    }

    /// What the user is actually talking to, e.g. "GPT-5.6-Sol · 中".
    var modelLabel: String {
        switch provider {
        case .codex, .claude, .gemini, .kimi:
            guard let model = selectedCLIModel else { return provider?.title ?? "" }
            return effortLabel.isEmpty ? model.name : "\(model.name) · \(effortLabel)"
        case .api: return apiModel
        case nil: return ""
        }
    }

    var effortLabel: String {
        guard let model = selectedCLIModel else { return appLocalized("模型") }
        let effort = cliEffort.isEmpty ? model.defaultEffort : cliEffort
        return effort.isEmpty ? "" : Self.effortName(effort)
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "minimal": appLocalized("极简")
        case "low": appLocalized("低")
        case "medium": appLocalized("中")
        case "high": appLocalized("高")
        case "xhigh": appLocalized("很高")
        case "max": appLocalized("最高")
        case "ultra": appLocalized("超高")
        default: effort
        }
    }

    /// Reads the models this Codex account can use, in Codex's own order.
    func loadCodexModels() {
        guard !isLoadingCodexModels, AgentCLI.isInstalled("codex") else { return }
        isLoadingCodexModels = true
        codexModelsFailed = false
        Self.run("codex", ["debug", "models"]) { _, output in
            let data = Data(output.utf8)
            guard let start = output.firstIndex(of: "{"),
                  let json = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any]
                    ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any]),
                  let entries = json["models"] as? [[String: Any]] else {
                Task { @MainActor in
                    self.isLoadingCodexModels = false
                    self.codexModelsFailed = true
                }
                return
            }
            let models = entries
                .filter { ($0["visibility"] as? String) == "list" }
                .sorted { ($0["priority"] as? Int ?? 0) < ($1["priority"] as? Int ?? 0) }
                .compactMap { entry -> CodexModel? in
                    guard let slug = entry["slug"] as? String else { return nil }
                    let efforts = (entry["supported_reasoning_levels"] as? [[String: Any]] ?? []).compactMap { $0["effort"] as? String }
                    return CodexModel(
                        slug: slug,
                        name: entry["display_name"] as? String ?? slug,
                        summary: entry["description"] as? String ?? "",
                        efforts: efforts,
                        defaultEffort: entry["default_reasoning_level"] as? String ?? "medium"
                    )
                }
            Task { @MainActor in
                self.isLoadingCodexModels = false
                self.codexModelsFailed = models.isEmpty
                self.codexModels = models
                let chosen = UserDefaults.standard.bool(forKey: "agent.codex.modelChosen")
                if let first = models.first,
                   !chosen || !models.contains(where: { $0.slug == self.codexModel }) {
                    self.codexModel = first.slug
                    self.codexEffort = first.defaultEffort
                }
            }
        }
    }

    private var process: Process?
    private var antigravitySession: AntigravitySession?
    private var apiTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: "agent.provider").flatMap(Provider.init(rawValue:))
        apiBaseURL = defaults.string(forKey: "agent.api.baseURL") ?? "https://api.openai.com/v1"
        apiModel = defaults.string(forKey: "agent.api.model") ?? "gpt-4.1"
        codexModel = defaults.string(forKey: "agent.codex.model") ?? ""
        codexEffort = defaults.string(forKey: "agent.codex.effort") ?? ""
        claudeModel = defaults.string(forKey: "agent.claude.model") ?? "sonnet"
        claudeEffort = defaults.string(forKey: "agent.claude.effort") ?? ""
        otherModel = defaults.dictionary(forKey: "agent.cli.model") as? [String: String] ?? [:]
        otherEffort = defaults.dictionary(forKey: "agent.cli.effort") as? [String: String] ?? [:]
        if provider == .api, Keychain.read() == nil { provider = nil }
        if let executable = provider?.executable, !AgentCLI.isInstalled(executable) { provider = nil }
        AgentCLI.prewarm(Provider.allCases.compactMap(\.executable))
        if provider == .codex { loadCodexModels() }
    }

    // MARK: Connection

    func isAvailable(_ candidate: Provider) -> Bool {
        candidate.executable.map { AgentCLI.isInstalled($0) } ?? true
    }

    var hasStoredKey: Bool { Keychain.read() != nil }

    /// Asks the installed Codex whether it is signed in (`codex login status`).
    func refreshCodexAccount() {
        guard AgentCLI.isInstalled("codex") else { codexAccount = .unknown; return }
        codexAccount = .checking
        Self.run("codex", ["login", "status"]) { status, _ in
            Task { @MainActor in
                self.codexAccount = status == 0 ? .signedIn : .signedOut
                if status == 0 {
                    self.loadCodexModels()
                    let hadSignInCard = self.messages.contains { $0.action == .signIn }
                    self.messages.removeAll { $0.action == .signIn }
                    if hadSignInCard {
                        self.messages.append(Message(role: .activity, text: appLocalized("Codex 已登录，可以继续了")))
                    }
                }
            }
        }
    }

    /// Asks the installed Claude Code whether it can run (`claude auth status`).
    func refreshClaudeAccount() {
        guard AgentCLI.isInstalled("claude") else { claudeAccount = .unknown; return }
        claudeAccount = .checking
        Self.run("claude", ["auth", "status"]) { status, output in
            let loggedIn = status == 0 && (output.contains("\"loggedIn\": true") || output.contains("\"loggedIn\":true"))
            Task { @MainActor in
                self.claudeAccount = loggedIn ? .signedIn : .signedOut
                if loggedIn { self.messages.removeAll { $0.action == .signIn } }
            }
        }
    }

    /// Claude Code signs in inside its own terminal; DogSC opens Terminal
    /// with `claude auth login` and checks again when the user returns.
    func signInToClaude() {
        guard let executable = AgentCLI.path(for: "claude") else { return }
        claudeAccount = .signingIn
        let script = "tell application \"Terminal\" to do script \"'\(executable)' auth login\"\ntell application \"Terminal\" to activate"
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    /// Reads the models an OpenAI-compatible endpoint offers (`GET /models`).
    func loadAPIModels(apiKey: String? = nil) {
        guard let key = apiKey.flatMap({ $0.isEmpty ? nil : $0 }) ?? Keychain.read(),
              let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespaces))?.appendingPathComponent("models") else {
            apiModels = []; apiModelsState = .unknown; return
        }
        apiModelsState = .checking
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            // Anthropic's API lists models with its own headers.
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            let models: [String]
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }.filter(Self.isChatModel).sorted(by: Self.newerFirst)
            } else {
                models = []
            }
            await MainActor.run {
                self.apiModels = models
                self.apiModelsState = models.isEmpty ? .signedOut : .signedIn
                if !models.isEmpty, !models.contains(self.apiModel) { self.apiModel = models[0] }
            }
        }
    }

    /// Hides embedding, audio, image and moderation models from the picker.
    private static func isChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !["embed", "whisper", "tts", "dall-e", "moderation", "audio", "transcribe", "image", "realtime", "search"]
            .contains { lower.contains($0) }
    }

    private static func newerFirst(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Starts Codex's own sign-in, which opens the browser. DogSC never sees
    /// or stores the account credentials.
    func signInToCodex() {
        guard AgentCLI.isInstalled("codex") else { return }
        codexAccount = .signingIn
        Self.run("codex", ["login"], timeout: nil) { _, _ in
            Task { @MainActor in self.refreshCodexAccount() }
        }
    }

    private nonisolated static func run(_ name: String, _ arguments: [String], timeout: TimeInterval? = 30,
                                        mergesStandardError: Bool = false,
                                        completion: @escaping @Sendable (Int32, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let executable = AgentCLI.path(for: name) else {
                completion(-1, String(format: appLocalized("没有找到 %@。"), name))
                return
            }
            let result = AgentCLICommand.run(executable, arguments, timeout: timeout, mergesStandardError: mergesStandardError)
            completion(result.status, result.output)
        }
    }

    func connect(_ candidate: Provider, apiKey: String? = nil) {
        if candidate == .api {
            if let apiKey, !apiKey.isEmpty { Keychain.write(apiKey) }
            guard Keychain.read() != nil else { return }
            UserDefaults.standard.set(apiBaseURL, forKey: "agent.api.baseURL")
            UserDefaults.standard.set(apiModel, forKey: "agent.api.model")
        } else if !isAvailable(candidate) {
            return
        }
        if candidate != .gemini { closeIdleAntigravitySession() }
        provider = candidate
        UserDefaults.standard.set(candidate.rawValue, forKey: "agent.provider")
        if candidate == .codex, codexModels.isEmpty { loadCodexModels() }
        if candidate == .claude { refreshClaudeAccount() }
        if candidate == .gemini { refreshAntigravityAccount() }
        if candidate == .kimi { refreshKimiAccount() }
    }

    /// AIs that can take over this conversation right now: installed CLIs
    /// (and the API when a key is stored).
    var switchableProviders: [Provider] {
        Provider.allCases.filter { $0 == .api ? hasStoredKey : isAvailable($0) }
    }

    /// Hands the open conversation to another AI. DogSC keeps the history and
    /// sends it with every turn, so the next message continues where this
    /// one left off — only the previous model's private reasoning stays behind.
    func switchProvider(to candidate: Provider) {
        guard candidate != provider, !isRunning else { return }
        connect(candidate)
        guard provider == candidate, !messages.isEmpty else { return }
        messages.append(Message(role: .activity, text: String(format: appLocalized("已切换到 %@，接着这段对话继续"), candidate.title)))
    }

    /// After a quota error: the same request again, on another AI.
    func continueElsewhere(_ candidate: Provider, from messageID: UUID) {
        guard !isRunning else { return }
        dismiss(messageID)
        switchProvider(to: candidate)
        guard let last = messages.last(where: { $0.role == .user }) else { return }
        send(last.text)
    }

    func disconnect() {
        stop()
        closeIdleAntigravitySession()
        provider = nil
        UserDefaults.standard.removeObject(forKey: "agent.provider")
    }

    func forgetKey() {
        Keychain.delete()
        if provider == .api { disconnect() }
    }

    /// Each project keeps its own conversation in its AI workspace.
    func loadConversation() {
        guard let workspace = AgentBridgeServer.shared.conversationRootURL,
              conversationWorkspace != workspace else { return }
        conversationWorkspace = workspace
        threads = []
        let latest = conversationPersistence.latest(in: workspace)
        open(latest.url, messages: latest.messages)
        refreshThreads()
    }

    /// End the outgoing turn while its bridge still points at its own store.
    /// Any subsequent CLI completion carries the retired turn ID.
    func closeProjectConversation() {
        queued = []
        interruptRequested = false
        if isRunning {
            stop()
            if isRunning { finish(reply: nil, turn: turnID, collectMedia: false) }
        }
        closeIdleAntigravitySession()
        conversationPersistence.flush()
        historyRevision &+= 1
        conversationWorkspace = nil
        conversationURL = nil
        messages = []
        threads = []
        queued = []
        pendingAttachments = []
    }

    private func threadURL(_ id: String, in workspace: URL) -> URL {
        id == "conversation" ? workspace.appendingPathComponent("conversation.json")
            : workspace.appendingPathComponent("conversations", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func open(_ url: URL, messages list: [Message]) {
        closeIdleAntigravitySession()
        conversationURL = nil
        pendingAttachments = []
        queued = []
        messages = Self.groupingLegacyActivity(list)
        conversationURL = url
    }

    /// Earlier builds stored each edit as its own line; show a run of them
    /// as one step list like new turns.
    private static func groupingLegacyActivity(_ list: [Message]) -> [Message] {
        var out: [Message] = []
        for message in list {
            guard message.role == .activity else { out.append(message); continue }
            let step = Step(title: message.text)
            if let last = out.indices.last, out[last].role == .steps {
                out[last].steps = (out[last].steps ?? []) + [step]
            } else {
                out.append(Message(role: .steps, text: "", steps: [step]))
            }
        }
        return out
    }

    var currentThreadID: String? { conversationURL?.deletingPathExtension().lastPathComponent }

    /// The title of a thread is its first request.
    var threadTitle: String {
        messages.first(where: { $0.role == .user })?.text ?? appLocalized("新对话")
    }

    func refreshThreads() {
        historyRevision &+= 1
        let revision = historyRevision
        guard let workspace = AgentBridgeServer.shared.conversationRootURL else { threads = []; return }
        conversationPersistence.summaries(in: workspace) { [weak self] result in
            EditorMainRunLoop.perform { [weak self] in
                guard let self, self.historyRevision == revision,
                      AgentBridgeServer.shared.conversationRootURL == workspace else { return }
                self.threads = result
            }
        }
    }

    func openThread(_ id: String) {
        guard !isRunning, let workspace = AgentBridgeServer.shared.conversationRootURL else { return }
        let url = threadURL(id, in: workspace)
        guard currentThreadID != id else { return }
        conversationPersistence.flush()
        guard let list = conversationPersistence.messages(at: url) else { refreshThreads(); return }
        open(url, messages: list)
    }

    /// Starts an empty thread; the current one stays in the history.
    func newThread() {
        guard !isRunning, let workspace = AgentBridgeServer.shared.conversationRootURL else { return }
        conversationPersistence.flush()
        open(AgentConversationPersistence.newThreadURL(in: workspace), messages: [])
        refreshThreads()
    }

    func deleteThread(_ id: String) {
        guard let workspace = AgentBridgeServer.shared.conversationRootURL else { return }
        AntigravityCheckpoint.save(nil, thread: id, workspace: AgentBridgeServer.workspace(for: id, in: workspace))
        let url = threadURL(id, in: workspace)
        let isCurrent = currentThreadID == id
        conversationPersistence.remove(url)
        if isCurrent { newThread() } else { refreshThreads() }
    }

    private func saveConversation() {
        guard let conversationURL, !messages.isEmpty else { return }
        conversationPersistence.save(messages, to: conversationURL)
    }

    func dismiss(_ id: UUID) {
        messages.removeAll { $0.id == id }
    }

    func clear() {
        stop()
        closeIdleAntigravitySession()
        if let thread = currentThreadID, let workspace = AgentBridgeServer.shared.workspaceURL {
            AntigravityCheckpoint.save(nil, thread: thread, workspace: workspace)
        }
        messages.removeAll()
    }

    /// Short, readable model names for the picker: one line of use each.
    func modelUse(_ model: CodexModel) -> String {
        // These catalogs already contain localized usage descriptions. The
        // keyword mapping below is only needed for external model summaries.
        if provider == .claude || provider == .gemini { return model.summary }
        let text = (model.summary + " " + model.slug).lowercased()
        let older = Self.isOlder(model)
        let use: String
        if text.contains("frontier") || text.contains("most demanding") || text.contains("most capable") {
            use = appLocalized("最强，适合复杂的多步修改和创作")
        } else if text.contains("fast") || text.contains("efficient") || text.contains("affordable") || text.contains("mini") || text.contains("nano") {
            use = appLocalized("更快，适合改字幕、调参数")
        } else if text.contains("codex") {
            use = appLocalized("擅长生成动画和脚本")
        } else if text.contains("balanced") || text.contains("straightforward") {
            use = appLocalized("均衡，适合常规修改")
        } else {
            use = appLocalized("主力模型，日常修改的首选")
        }
        return older ? appLocalized("旧版") + " · " + use : use
    }

    /// Previous generations go under 旧版模型 in the picker.
    static func isOlder(_ model: CodexModel) -> Bool {
        let summary = model.summary.lowercased()
        return summary.contains("older") || summary.contains("previous")
    }

    static func effortHint(_ effort: String) -> String {
        switch effort {
        case "minimal", "low": appLocalized("最快，适合简单的修改。")
        case "medium": appLocalized("日常修改用“中”就够了。")
        case "high": appLocalized("更仔细，适合多步修改，会慢一些。")
        default: appLocalized("最仔细，适合复杂的创作，会明显更慢。")
        }
    }

    /// One line describing what the AI can see in the open project.
    var projectContext: [String] { AgentBridgeServer.shared.contextLabels() }

    /// One message for any other agent: install the skill and the MCP server.
    static var installInstructions: String {
        // Stable paths (refreshed at every launch), so moving or updating
        // DogSC never breaks the connection.
        let mcp = AgentIntegrations.mcpLauncher.path
        let skill = AgentIntegrations.bundledSkill?.path ?? ""
        return """
        请帮我安装 DogSC 的编辑能力，之后你就可以直接编辑我在 DogSC 里打开的项目：
        1. 添加一个名为 "dogsc" 的 MCP 服务器（stdio，用户级），启动命令：\(String(reflecting: mcp))，不需要参数。工具调用超时请设为 15 分钟（渲染动效、转写会比较久）。使用时 DogSC 需要保持打开。
        2. 把这个 Skill 复制到你的技能目录，技能名 dogsc-editor（目录里放 SKILL.md）：\(String(reflecting: skill))
           常见位置：Claude Code ~/.claude/skills/dogsc-editor/；Codex ~/.codex/skills/dogsc-editor/；Antigravity CLI ~/.gemini/antigravity-cli/skills/dogsc-editor/；其他支持 Agent Skills 的工具 ~/.agents/skills/dogsc-editor/。不支持技能的工具可跳过，MCP 服务器连接时会自带使用说明。
        3. 装好后调用 dogsc 的 project_summary 工具，确认已连接并告诉我项目名称。
        4. 一次性的工作文件放在当前 project_summary 返回的 workspace。
        """
    }

    // MARK: Conversation

    func send(_ text: String) {
        var request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !isStopping, !request.isEmpty || !attachments.isEmpty, let provider else { return }
        if request.isEmpty { request = appLocalized("参考附件") }
        pendingAttachments = []
        if isRunning {
            queued.append(QueuedMessage(text: request, attachments: attachments))
            return
        }
        startTurn(request, attachments: attachments, provider: provider)
    }

    private func startTurn(_ request: String, attachments: [Attachment], provider: Provider) {
        let history = messages.compactMap { message -> Message? in
            switch message.role {
            case .user, .assistant: return message
            case .steps:
                // Earlier edits, so a follow-up (or a turn after an
                // interruption) knows what is already in the project.
                let titles = (message.steps ?? []).map(\.title).joined(separator: "; ")
                return titles.isEmpty ? nil : Message(role: .assistant, text: "[Done in DogSC: \(titles)]")
            case .activity where message.text.hasPrefix(appLocalized("已切换到")):
                return Message(role: .assistant, text: "[The conversation moved to another AI here; continue it.]")
            default: return nil
            }
        }.reduced()
        messages.append(Message(role: .user, text: request, attachments: attachments.isEmpty ? nil : attachments))
        isRunning = true
        turnStartedAt = Date()
        activity = Activity(kind: .thinking, title: appLocalized("正在思考"))
        let turn = UUID()
        turnID = turn
        turnStepsMessage = nil
        AgentBridgeServer.shared.beginUndoBatch(turn: turn)
        if AgentOperationLog.shared != nil {
            let skill = Self.skillText
            AgentBridgeServer.shared.recordDiagnostics("turn.started", turn: turn, fields: [
                "provider": provider.rawValue,
                "requestedModel": provider == .api ? apiModel
                    : (provider == .codex ? codexModel : selectedCLIModel?.slug ?? ""),
                "modelLabel": modelLabel,
                "effort": provider == .api ? "" : cliEffort,
                "request": request,
                "skillSHA256": AgentOperationLog.digest(Data(skill.utf8)),
                "skill": skill,
                "history": history.map { ["role": $0.role.rawValue, "text": $0.text] },
                "attachments": attachments.map { ["kind": $0.kind.rawValue, "name": $0.name, "path": $0.path] },
            ])
        }
        AgentBridgeServer.shared.activityHandler = { [weak self] summary in
            guard self?.acceptsOutput(from: turn) == true else { return }
            self?.appendStep(AgentChatModel.Step(title: summary))
        }
        AgentBridgeServer.shared.stepHandler = { [weak self] step in
            guard let self, self.acceptsOutput(from: turn) else { return }
            if provider == .gemini { self.antigravitySession?.noteProgress() }
            self.appendStep(step)
            self.activity = Activity(kind: .thinking, title: appLocalized("正在思考"))
        }
        AgentBridgeServer.shared.progressHandler = { [weak self] title, progress, detail in
            guard let self, self.acceptsOutput(from: turn) else { return }
            if provider == .gemini { self.antigravitySession?.noteProgress() }
            self.activity = Activity(kind: .rendering, title: title, progress: progress, detail: detail)
        }
        if let command = provider.executable {
            Task {
                let executable = await AgentCLI.resolvedPath(for: command)
                guard acceptsOutput(from: turn) else { return }
                switch provider {
                case .codex: runCodex(executable: executable, request: request, attachments: attachments, history: history)
                case .claude: runClaude(executable: executable, request: request, attachments: attachments, history: history)
                case .gemini: runAntigravity(executable: executable, request: request, attachments: attachments, history: history)
                case .kimi: runKimi(executable: executable, request: request, attachments: attachments, history: history)
                case .api: break
                }
            }
        } else {
            runAPI(request: request, attachments: attachments, history: history)
        }
    }

    func stop() {
        guard !isStopping else { return }
        queued = []
        interruptRequested = false
        requestStop(interrupting: false)
    }

    private func requestStop(interrupting: Bool) {
        guard isRunning, !isStopping else { return }
        stopRequested = true
        interruptRequested = interrupting
        isStopping = true
        activity = Activity(kind: .thinking, title: appLocalized(interrupting ? "正在打断…" : "正在停止…"))
        AgentBridgeServer.shared.recordDiagnostics("turn.stopRequested", turn: turnID,
            fields: ["intent": interrupting ? "interrupt" : "stop"])
        if let session = antigravitySession, process === session.process {
            session.cancel()
        } else if let process { AgentProcessCancellation.request(process) }
        apiTask?.cancel()
        AgentBridgeServer.shared.cancelRunning()
        if process == nil, apiTask == nil { finish(reply: nil, turn: turnID) }
    }

    /// Stops the running turn and sends the queued messages right away.
    /// What the turn already changed stays; the next turn sees it.
    func interruptWithQueued() {
        guard !isStopping, !queued.isEmpty else { return }
        guard isRunning else { sendQueued(); return }
        requestStop(interrupting: true)
    }

    func removeQueued(at index: Int) {
        guard queued.indices.contains(index) else { return }
        queued.remove(at: index)
    }

    private var interruptRequested = false
    private var stopRequested = false

    var needsTerminationWait: Bool { isRunning || antigravitySession?.process.isRunning == true }

    private func closeIdleAntigravitySession() {
        guard !isRunning else { return }
        antigravitySession?.cancel()
        antigravitySession = nil
    }

    func prepareForTermination() async -> Bool {
        stop()
        let deadline = Date().addingTimeInterval(8)
        while isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard !isRunning else { return false }
        let idle = antigravitySession
        closeIdleAntigravitySession()
        while idle?.process.isRunning == true, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        return idle?.process.isRunning != true
    }

    func closeIdleSessionsForTermination() {
        closeIdleAntigravitySession()
    }

    private func sendQueued() {
        guard !queued.isEmpty, !isRunning, let provider else { return }
        let text = queued.map(\.text).joined(separator: "\n")
        let attachments = queued.flatMap(\.attachments)
        queued = []
        startTurn(text, attachments: attachments, provider: provider)
    }

    nonisolated private func postActivity(_ update: Activity, turn: UUID?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, acceptsOutput(from: turn) else { return }
            setLiveActivity(update)
        }
    }

    /// Live progress from a CLI's stream (thinking text, tool in use).
    func setLiveActivity(_ update: Activity) {
        guard isRunning, !isStopping else { return }
        // A DogSC render in progress keeps its own row.
        if activity?.kind == .rendering, update.kind != .rendering { return }
        activity = update
    }

    /// Every edit of the running turn lands in one step list, placed after
    /// whatever the assistant has said so far.
    private func appendStep(_ step: Step) {
        // A card collects consecutive edits; once the assistant has said
        // something after it, the next edit opens a new card below.
        if let id = turnStepsMessage, let index = messages.lastIndex(where: { $0.id == id }), index == messages.count - 1 {
            messages[index].steps = (messages[index].steps ?? []) + [step]
        } else {
            let message = Message(role: .steps, text: "", steps: [step], turn: turnID)
            turnStepsMessage = message.id
            messages.append(message)
        }
    }

    private func acceptsOutput(from turn: UUID?) -> Bool {
        isRunning && !isStopping && turn != nil && turnID == turn
    }

    private func finish(reply: String?, error: String? = nil, action: Message.Action? = nil,
                        detail: String? = nil, turn expectedTurn: UUID? = nil, collectMedia: Bool = true) {
        guard isRunning, expectedTurn == nil || expectedTurn == turnID else { return }
        if collectMedia { AgentBridgeServer.shared.collectWorkspaceMedia() }
        let changes = AgentBridgeServer.shared.endUndoBatch()
        let elapsed = turnStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if !changes.isEmpty, let turnID {
            messages.append(Message(role: .result, text: appLocalized("本轮修改已应用"),
                                    changes: changes, turn: turnID))
        }
        if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(Message(role: .assistant, text: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if error == nil, let last = messages.lastIndex(where: { $0.role == .assistant }),
           last > (messages.lastIndex(where: { $0.role == .user }) ?? -1) {
            messages[last].meta = [modelLabel, Self.elapsedText(elapsed)].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if AgentOperationLog.shared != nil {
            let first = messages.lastIndex(where: { $0.role == .user }) ?? messages.startIndex
            AgentBridgeServer.shared.recordDiagnostics("turn.finished", turn: turnID, fields: [
                "status": stopRequested ? "cancelled" : (error == nil ? "succeeded" : "failed"),
                "durationMS": elapsed * 1_000,
                "error": error as Any? ?? NSNull(),
                "detail": detail as Any? ?? NSNull(),
                "messages": messages[first...].map {
                    ["role": $0.role.rawValue, "text": $0.text,
                     "steps": ($0.steps ?? []).map(\.title)] as [String: Any]
                },
                "changes": changes.map { ["label": $0.label, "value": $0.value] },
            ])
        }
        let stopped = stopRequested
        let continues = interruptRequested && !queued.isEmpty
        stopRequested = false
        if let error, !stopped { messages.append(Message(role: .error, text: error, action: action, detail: detail)) }
        if stopped, !continues { messages.append(Message(role: .activity, text: appLocalized("已停止"))) }
        isRunning = false
        isStopping = false
        turnStartedAt = nil
        activity = nil
        turnID = nil
        turnStepsMessage = nil
        process = nil
        apiTask = nil
        AgentBridgeServer.shared.activityHandler = nil
        AgentBridgeServer.shared.stepHandler = nil
        AgentBridgeServer.shared.progressHandler = nil
        // Queued follow-ups go out now; after an interruption the stop
        // notice is not an error the user needs to read.
        interruptRequested = false
        if continues {
            messages.append(Message(role: .activity, text: appLocalized("已打断，继续处理你的新消息")))
        }
        if !queued.isEmpty, !stopped || continues {
            DispatchQueue.main.async { [weak self] in self?.sendQueued() }
        }
    }

    /// What the model is doing, from the tool it called.
    nonisolated static func toolTitle(_ raw: String) -> String {
        let name = raw.replacingOccurrences(of: "mcp__dogsc__", with: "").replacingOccurrences(of: "dogsc.", with: "")
            .replacingOccurrences(of: "dogsc__", with: "")
        switch name {
        case "project_summary": return appLocalized("正在读取项目信息")
        case "canvas_snapshot": return appLocalized("正在看当前画面")
        case "subtitles_get": return appLocalized("正在读取字幕")
        case "audio_transcribe": return appLocalized("正在转写音频")
        case "audio_analyze_edits": return appLocalized("正在分析语音与停顿")
        case "subtitles_set", "subtitles_set_from_words", "subtitles_update_text": return appLocalized("正在写入字幕")
        case "subtitles_align_to_speech": return appLocalized("正在对齐字幕")
        case "html_create": return appLocalized("正在制作动效")
        case "html_update": return appLocalized("正在更新动效")
        case "html_preview": return appLocalized("正在预览动效")
        case "sound_create": return appLocalized("正在制作音效")
        case "sound_download": return appLocalized("正在下载音效")
        case "timeline_get", "timeline_inspect": return appLocalized("正在查看时间线")
        case "timeline_cut", "timeline_update": return appLocalized("正在剪辑")
        case "timeline_remove": return appLocalized("正在删除片段")
        case "pointer_events": return appLocalized("正在查看鼠标点击")
        case "zoom_add": return appLocalized("正在添加缩放")
        case "motion3d_add": return appLocalized("正在添加 3D 运镜")
        case "highlight_add": return appLocalized("正在添加标记")
        case "settings_get", "settings_set": return appLocalized("正在调整设置")
        case "app_help": return appLocalized("正在查看使用说明")
        case "timeline_add_audio": return appLocalized("正在添加音频")
        case "timeline_add_video", "timeline_add_sticker": return appLocalized("正在放置素材")
        case "timeline_insert_black": return appLocalized("正在插入黑场")
        case "media_list", "media_import", "image_download": return appLocalized("正在整理素材")
        case "Read", "read_file", "ReadFile": return appLocalized("正在读文件")
        case "Write", "Edit", "write_file", "replace", "WriteFile": return appLocalized("正在写文件")
        case "Bash", "run_shell_command", "Shell": return appLocalized("正在运行命令")
        case "WebSearch", "google_web_search", "WebFetch", "web_fetch": return appLocalized("正在搜索资料")
        default: return appLocalized("正在处理")
        }
    }

    static func elapsedText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s < 60 ? String(format: appLocalized("%lld 秒"), Int64(max(s, 1)))
            : String(format: appLocalized("%lld 分 %lld 秒"), Int64(s / 60), Int64(s % 60))
    }

    /// Puts the project back to how it was before the turn's edits.
    func revert(_ messageID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == messageID }),
              let turn = messages[index].turn,
              AgentBridgeServer.shared.revert(turn: turn) else { return }
        messages[index].reverted = true
    }

    /// Plays the programme from a time the AI changed.
    func preview(at time: Double) { AgentBridgeServer.shared.preview(at: time) }
    func locate(_ time: Double) { AgentBridgeServer.shared.locate(time) }

    /// Asks the same question again. The answer being redone and anything
    /// after it are replaced, so the retry is visible right where it was.
    func retry(_ messageID: UUID) {
        guard !isRunning, let index = messages.firstIndex(where: { $0.id == messageID }),
              let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) else { return }
        let user = messages[userIndex]
        // The latest reply is replaced in place; an older one is asked again
        // at the end, so nothing said since is lost. Edits the earlier turn
        // made stay (and stay revertible from their own card).
        if !messages[(index + 1)...].contains(where: { $0.role == .user }) {
            messages.removeSubrange(index...)
            if userIndex == messages.count - 1 { messages.removeLast() }
        }
        pendingAttachments = user.attachments ?? []
        send(user.text)
    }

    private static var skillText: String {
        Bundle.main.url(forResource: "DogSC-Skill", withExtension: "md", subdirectory: "Agent")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }

    private static func briefing(history: [Message]) -> String {
        var text = """
        You are the editing assistant inside DogSC, a macOS screen-recording editor. Use the DogSC tools \
        within the scope of the user's request. Reply briefly in the user's language and report what you inspected or changed.

        \(skillText)
        """
        if !history.isEmpty {
            text += "\n\nConversation so far:\n" + history.map {
                ($0.role == .user ? "User: " : "Assistant: ") + $0.text
            }.joined(separator: "\n")
        }
        return text
    }

    // MARK: Codex (the user's own install and sign-in)

    private func runCodex(executable: String?, request: String, attachments: [Attachment], history: [Message]) {
        let runningTurn = turnID
        guard let executable else {
            finish(reply: nil, error: appLocalized("没有找到 Codex，请先安装。"))
            return
        }
        guard let workspace = AgentBridgeServer.shared.workspaceURL else {
            finish(reply: nil, error: appLocalized("项目还没有准备好，请稍后再试。"))
            return
        }
        let mcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dogsc-mcp").path
        let prompt = Self.briefing(history: history)
            + "\n\nYour working folder is this conversation's workspace: \(workspace.path). Keep one-off working files there (transcripts, previews)."
            + "\n\nUser request: " + request + Self.attachmentNote(attachments)
        let replyURL = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-agent-\(UUID().uuidString).txt")
        var arguments = [
            "--search", "exec", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ephemeral",
            "--cd", workspace.path, "--sandbox", "workspace-write",
            "-c", "mcp_servers.dogsc.command=\"\(mcp)\"",
            "-c", "mcp_servers.dogsc.default_tools_approval_mode=\"approve\"",
            "-c", "mcp_servers.dogsc.tool_timeout_sec=900",
            "--output-last-message", replyURL.path,
        ]
        let model = codexModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { arguments += ["-c", "model=\"\(model)\""] }
        let effort = codexEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { arguments += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        // Images go to the model itself; `--` keeps the prompt from being
        // read as one more image path.
        arguments += attachments.filter { $0.kind == .image }.map { "--image=\($0.path)" }
        arguments += ["--", prompt]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentCLI.searchPath
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        /// `--json` prints one event per line; the agent's own messages are
        /// shown as they arrive, everything else stays in the log for details.
        final class Stream: @unchecked Sendable {
            var log = ""
            var lastMessage: String?
        }
        let stream = Stream()
        let consume: @Sendable ([Data], Data) -> Void = { [weak self] lines, _ in
            var messages: [String] = []
            for line in lines {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = event["type"] as? String else {
                    stream.log += String(decoding: line, as: UTF8.self) + "\n"
                    continue
                }
                if type == "item.started" || type == "item.updated", let item = event["item"] as? [String: Any] {
                    let kind = item["type"] as? String ?? ""
                    let update: Activity? = switch kind {
                    case "reasoning": Activity(kind: .thinking, title: appLocalized("正在思考"), thought: String(((item["text"] as? String) ?? "").suffix(400)))
                    case "mcp_tool_call": Activity(kind: .tool, title: AgentChatModel.toolTitle((item["tool"] as? String) ?? ""))
                    case "command_execution": Activity(kind: .tool, title: appLocalized("正在运行命令"), detail: item["command"] as? String)
                    case "file_change": Activity(kind: .tool, title: appLocalized("正在写文件"))
                    case "web_search": Activity(kind: .tool, title: appLocalized("正在搜索资料"))
                    default: nil
                    }
                    if let update { self?.postActivity(update, turn: runningTurn) }
                }
                if type == "item.completed", let item = event["item"] as? [String: Any], item["type"] as? String == "reasoning",
                   let text = item["text"] as? String {
                    self?.postActivity(Activity(kind: .thinking, title: appLocalized("正在思考"), thought: String(text.suffix(400))), turn: runningTurn)
                }
                if type == "item.completed", let item = event["item"] as? [String: Any],
                   item["type"] as? String == "agent_message", let text = item["text"] as? String {
                    messages.append(text)
                    stream.lastMessage = text
                } else if type == "error", let message = event["message"] as? String {
                    stream.log += "ERROR: \(message)\n"
                } else if type == "turn.failed", let error = event["error"] as? [String: Any],
                          let message = error["message"] as? String {
                    stream.log += "ERROR: \(message)\n"
                }
            }
            guard !messages.isEmpty else { return }
            DispatchQueue.main.async {
                guard self?.acceptsOutput(from: runningTurn) == true else { return }
                for text in messages where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self?.messages.append(Message(role: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
        }
        let complete: @Sendable (Process) -> Void = { finished in
            let log = stream.log
            let streamed = stream.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            DispatchQueue.main.async {
                let reply = (try? String(contentsOf: replyURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: replyURL)
                if reason == .uncaughtSignal {
                    self.finish(reply: nil, error: appLocalized("已停止。"), turn: runningTurn)
                } else if status == 0, let reply, !reply.isEmpty {
                    self.finish(reply: reply == streamed ? nil : reply, turn: runningTurn)
                } else if status == 0, streamed != nil {
                    self.finish(reply: nil, turn: runningTurn)
                } else if let problem = Self.codexProblem(in: log, model: model) {
                    self.finish(reply: nil, error: problem.message, action: problem.action, detail: Self.tail(log), turn: runningTurn)
                } else {
                    self.finish(reply: nil, error: appLocalized("Codex 没有完成这次请求。"), detail: Self.tail(log), turn: runningTurn)
                }
            }
        }
        do {
            try AgentCLICommand.startLines(task, consume: consume, finished: complete)
            process = task
        } catch {
            finish(reply: nil, error: error.localizedDescription)
        }
    }

    // MARK: Claude Code (the user's own install and sign-in)

    private func runClaude(executable: String?, request: String, attachments: [Attachment], history: [Message]) {
        let runningTurn = turnID
        guard let executable else {
            finish(reply: nil, error: appLocalized("没有找到 Claude Code，请先安装。"))
            return
        }
        guard let workspace = AgentBridgeServer.shared.workspaceURL else {
            finish(reply: nil, error: appLocalized("项目还没有准备好，请稍后再试。"))
            return
        }
        let mcp = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dogsc-mcp").path
        let config = workspace.appendingPathComponent(".dogsc-mcp.json")
        let configJSON: [String: Any] = ["mcpServers": ["dogsc": ["type": "stdio", "command": mcp, "args": [] as [String]]]]
        if let data = try? JSONSerialization.data(withJSONObject: configJSON) { try? data.write(to: config, options: .atomic) }
        let system = Self.briefing(history: history)
            + "\n\nYour working folder is this conversation's workspace: \(workspace.path). Keep one-off working files there (transcripts, previews)."
        // Claude Code reads images itself from a path in the prompt.
        let images = attachments.filter { $0.kind == .image }.map { "\n- Look at this reference image: \($0.path)" }.joined()
        let prompt = request + Self.attachmentNote(attachments.filter { $0.kind == .text }) + images
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--no-session-persistence",
            "--strict-mcp-config", "--mcp-config", config.path,
            "--append-system-prompt", system,
            // Project editing and read-only source research for requested assets.
            "--permission-mode", "acceptEdits",
            "--allowedTools", "mcp__dogsc", "Read", "Write", "Edit", "Glob", "Grep", "WebSearch", "WebFetch",
            "--model", selectedClaudeModel.slug,
        ]
        let effort = claudeEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !effort.isEmpty { arguments += ["--effort", effort] }
        arguments += ["--", prompt]

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentCLI.searchPath
        // DogSC tools can run for minutes (transcribing a long recording);
        // the default per-tool timeout would give up and make it retry.
        environment["MCP_TOOL_TIMEOUT"] = "900000"
        task.environment = environment
        task.standardInput = FileHandle.nullDevice
        final class Stream: @unchecked Sendable {
            var log = ""
            var result: String?
            var resultIsError = false
            var lastText: String?
            var thinking = ""
            var writing = ""
        }
        let stream = Stream()
        let consume: @Sendable ([Data], Data) -> Void = { [weak self] lines, _ in
            var texts: [String] = []
            var live: Activity?
            for line in lines {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let type = event["type"] as? String else {
                    stream.log += String(decoding: line, as: UTF8.self) + "\n"
                    continue
                }
                switch type {
                case "stream_event":
                    let inner = event["event"] as? [String: Any] ?? [:]
                    let delta = inner["delta"] as? [String: Any] ?? [:]
                    let block = inner["content_block"] as? [String: Any] ?? [:]
                    if let piece = delta["thinking"] as? String {
                        stream.thinking = String((stream.thinking + piece).suffix(400))
                        live = Activity(kind: .thinking, title: appLocalized("正在思考"), thought: stream.thinking)
                    } else if let piece = delta["text"] as? String {
                        stream.writing = String((stream.writing + piece).suffix(400))
                        live = Activity(kind: .writing, title: appLocalized("正在回复"), thought: stream.writing)
                    } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                        stream.thinking = ""; stream.writing = ""
                        live = Activity(kind: .tool, title: AgentChatModel.toolTitle(name))
                    } else if inner["type"] as? String == "message_start" {
                        stream.thinking = ""; stream.writing = ""
                    }
                case "assistant":
                    let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                    for part in content where part["type"] as? String == "text" {
                        if let text = part["text"] as? String,
                           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            texts.append(text)
                            stream.lastText = text
                        }
                    }
                case "result":
                    stream.result = event["result"] as? String
                    stream.resultIsError = (event["is_error"] as? Bool) ?? false
                    if stream.resultIsError { stream.log += "ERROR: \(stream.result ?? "")\n" }
                default:
                    break
                }
            }
            if !texts.isEmpty { stream.writing = "" }
            DispatchQueue.main.async {
                guard self?.acceptsOutput(from: runningTurn) == true else { return }
                if let live { self?.setLiveActivity(live) }
                for text in texts {
                    self?.messages.append(Message(role: .assistant, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                if !texts.isEmpty { self?.setLiveActivity(Activity(kind: .thinking, title: appLocalized("正在思考"))) }
            }
        }
        let complete: @Sendable (Process) -> Void = { finished in
            let log = stream.log, result = stream.result, isError = stream.resultIsError
            let streamed = stream.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finished.terminationStatus
            let reason = finished.terminationReason
            DispatchQueue.main.async {
                try? FileManager.default.removeItem(at: config)
                let reply = result?.trimmingCharacters(in: .whitespacesAndNewlines)
                if reason == .uncaughtSignal {
                    self.finish(reply: nil, error: appLocalized("已停止。"), turn: runningTurn)
                } else if status == 0, !isError {
                    self.finish(reply: reply == streamed ? nil : reply, turn: runningTurn)
                } else if let problem = Self.claudeProblem(in: log + (reply ?? "")) {
                    self.finish(reply: nil, error: problem.message, action: problem.action, detail: Self.tail(log), turn: runningTurn)
                } else {
                    self.finish(reply: nil, error: appLocalized("Claude Code 没有完成这次请求。"), detail: Self.tail(log), turn: runningTurn)
                }
            }
        }
        do {
            try AgentCLICommand.startLines(task, consume: consume, finished: complete)
            process = task
        } catch {
            finish(reply: nil, error: error.localizedDescription)
        }
    }

    // MARK: Antigravity CLI and Kimi Code

    private func runAntigravity(executable: String?, request: String, attachments: [Attachment], history: [Message]) {
        let runningTurn = turnID
        guard let executable else {
            finish(reply: nil, error: appLocalized("没有找到 Antigravity CLI，请先安装 agy。")); return
        }
        guard let workspace = AgentBridgeServer.shared.workspaceURL, let thread = currentThreadID else {
            finish(reply: nil, error: appLocalized("项目还没有准备好，请稍后再试。")); return
        }
        let fm = FileManager.default
        let dir = workspace.appendingPathComponent(".agents", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let config = dir.appendingPathComponent("mcp_config.json")
            var settings = (try? Data(contentsOf: config))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            var servers = settings["mcpServers"] as? [String: Any] ?? [:]
            servers["dogsc"] = ["command": Self.mcpPath, "args": [] as [String], "timeoutSeconds": 900] as [String: Any]
            settings["mcpServers"] = servers
            try JSONSerialization.data(withJSONObject: settings).write(to: config, options: .atomic)
            // Remove only the briefing generated by the former adapter. User
            // instruction files must survive both a turn and a provider switch.
            let legacy = workspace.appendingPathComponent("GEMINI.md")
            if let text = try? String(contentsOf: legacy, encoding: .utf8),
               text.hasPrefix("You are the editing assistant inside DogSC, a macOS screen-recording editor.") {
                try fm.removeItem(at: legacy)
            }
        } catch {
            finish(reply: nil, error: error.localizedDescription)
            return
        }
        let images = attachments.filter { $0.kind == .image }.map { "\n- Inspect this reference image at its exact path: \($0.path)" }.joined()
        let model = selectedCLIModel?.slug ?? ""
        let key = [workspace.path, thread, model, cliEffort].joined(separator: "\n")
        var checkpoint = AntigravityCheckpoint.load(thread: thread, workspace: workspace)
        if let message = checkpoint?.messageID, !messages.contains(where: { $0.id == message }) {
            checkpoint = nil
        }
        let digest = AgentOperationLog.digest(Data(Self.systemBriefing(history: [], workspace: workspace).utf8))
        var context = history
        if let message = checkpoint?.messageID, let index = messages.firstIndex(where: { $0.id == message }) {
            // Changes made by another provider since the last native turn are
            // context, not another request to repeat its tool calls.
            context = messages.dropFirst(index + 1).dropLast().compactMap { message in
                switch message.role {
                case .user, .assistant: return message
                case .steps:
                    return Message(role: .assistant, text: "[Done in DogSC: \((message.steps ?? []).map(\.title).joined(separator: "; "))]")
                default: return nil
                }
            }
        }
        let needsBriefing = checkpoint == nil || checkpoint?.briefingDigest != digest
        var prompt = needsBriefing ? Self.systemBriefing(history: context, workspace: workspace) + "\n\n" : ""
        if !needsBriefing, !context.isEmpty {
            prompt += "Context added in DogSC since your previous turn (already happened):\n"
                + context.map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n") + "\n\n"
        }
        prompt += "Current user request:\n" + request + Self.attachmentNote(attachments.filter { $0.kind == .text }) + images
        var arguments = ["--input-format", "stream-json", "--output-format", "stream-json", "--dangerously-skip-permissions"]
        if !model.isEmpty { arguments += ["--model", model] }
        if !cliEffort.isEmpty { arguments += ["--effort", cliEffort] }
        if let id = checkpoint?.conversationID { arguments += ["--conversation", id] }
        do {
            let session: AntigravitySession
            if let existing = antigravitySession, existing.key == key, existing.canSend, checkpoint != nil {
                session = existing
            } else {
                antigravitySession?.cancel()
                session = try AntigravitySession(key: key, executable: executable, arguments: arguments, workspace: workspace)
                antigravitySession = session
            }
            var nativeID = checkpoint?.conversationID
            let previous = checkpoint
            var succeeded = false
            var textMessages: [String: UUID] = [:]
            try session.send(prompt, onSilence: { [weak self] silence in
                guard let self, self.acceptsOutput(from: runningTurn) else { return }
                switch silence {
                case .waiting:
                    AgentBridgeServer.shared.recordDiagnostics("antigravity.waiting", turn: runningTurn,
                        fields: ["lastActivity": self.activity?.title ?? ""], includeProject: false)
                    if self.activity?.kind != .tool, self.activity?.kind != .rendering {
                        self.setLiveActivity(Activity(kind: .thinking, title: appLocalized("等待 Antigravity 返回下一步")))
                    }
                case .expired:
                    AgentBridgeServer.shared.recordDiagnostics("antigravity.inactivityTimeout", turn: runningTurn,
                        fields: ["lastActivity": self.activity?.title ?? ""], includeProject: false)
                    self.isStopping = true
                    self.activity = Activity(kind: .thinking, title: appLocalized("正在停止…"))
                    AgentBridgeServer.shared.cancelRunning()
                }
            }, update: { [weak self] update in
                guard let self, self.turnID == runningTurn else { return }
                if update.status == "SUCCESS", self.acceptsOutput(from: runningTurn) { succeeded = true }
                if let id = update.conversationID, id != nativeID {
                    nativeID = id
                    AntigravityCheckpoint.save(.init(conversationID: id, messageID: previous?.messageID,
                        briefingDigest: previous?.briefingDigest ?? ""), thread: thread, workspace: workspace)
                }
                if update.event == "init" || update.status != nil || update.toolName != nil {
                    var fields: [String: Any] = ["event": update.event, "conversationID": nativeID ?? ""]
                    if let name = update.toolName { fields["tool"] = name }
                    if let detail = update.toolDetail { fields["parameters"] = detail }
                    if let state = update.state { fields["state"] = state }
                    if let index = update.stepIndex { fields["stepIndex"] = index }
                    if let status = update.status { fields["status"] = status }
                    if let usage = update.usage { fields["usageCumulative"] = usage }
                    if let configuration = update.configuration { fields["configuration"] = configuration }
                    AgentBridgeServer.shared.recordDiagnostics(update.status == nil ? "antigravity.progress" : "antigravity.result", turn: runningTurn, fields: fields)
                }
                guard self.acceptsOutput(from: runningTurn) else { return }
                for text in update.texts where !text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let id = textMessages[text.key], let index = self.messages.firstIndex(where: { $0.id == id }) {
                        self.messages[index].text = text.value
                    } else {
                        let message = Message(role: .assistant, text: text.value)
                        textMessages[text.key] = message.id
                        self.messages.append(message)
                    }
                }
                if update.finishedTool {
                    self.setLiveActivity(Activity(kind: .thinking, title: appLocalized("正在思考")))
                } else if let tool = update.toolName {
                    self.setLiveActivity(Activity(kind: .tool, title: Self.toolTitle(tool), detail: update.toolDetail))
                } else if !update.texts.isEmpty {
                    self.setLiveActivity(Activity(kind: .writing, title: appLocalized("正在回复")))
                }
            }, completion: { [weak self] error, detail in
                guard let self, self.turnID == runningTurn else { return }
                if let error, let problem = Self.cliProblem(in: error + "\n" + detail, name: "Antigravity CLI") {
                    self.finish(reply: nil, error: problem.message, action: problem.action, detail: detail, turn: runningTurn)
                } else {
                    self.finish(reply: nil, error: error, detail: detail.isEmpty ? nil : detail, turn: runningTurn)
                }
                let failure = ((error ?? "") + "\n" + detail).lowercased()
                let missingSession = failure.range(of: #"conversation[^\n]{0,200}(not found|does not exist)|(?:unable|failed) to load[^\n]{0,40}conversation"#,
                    options: .regularExpression) != nil
                if missingSession {
                    AntigravityCheckpoint.save(nil, thread: thread, workspace: workspace)
                    self.antigravitySession?.cancel()
                    self.antigravitySession = nil
                } else if let nativeID {
                    AntigravityCheckpoint.save(.init(conversationID: nativeID, messageID: self.messages.last?.id,
                        briefingDigest: succeeded ? digest : previous?.briefingDigest ?? ""), thread: thread, workspace: workspace)
                }
            })
            process = session.process
        } catch {
            antigravitySession?.cancel()
            antigravitySession = nil
            finish(reply: nil, error: error.localizedDescription, turn: runningTurn)
        }
    }

    private func runKimi(executable: String?, request: String, attachments: [Attachment], history: [Message]) {
        guard let executable else {
            finish(reply: nil, error: appLocalized("没有找到 Kimi Code，请先安装。")); return
        }
        guard let workspace = AgentBridgeServer.shared.workspaceURL else {
            finish(reply: nil, error: appLocalized("项目还没有准备好，请稍后再试。")); return
        }
        let fm = FileManager.default
        // Kimi reads a project-level MCP file from <cwd>/.kimi-code/mcp.json.
        let dir = workspace.appendingPathComponent(".kimi-code", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let mcp: [String: Any] = ["mcpServers": ["dogsc": ["command": Self.mcpPath, "args": [] as [String]]]]
        if let data = try? JSONSerialization.data(withJSONObject: mcp) {
            try? data.write(to: dir.appendingPathComponent("mcp.json"), options: .atomic)
        }
        let images = attachments.filter { $0.kind == .image }.map { "\n- Look at this reference image: \($0.path)" }.joined()
        let prompt = Self.systemBriefing(history: history, workspace: workspace) + "\n\nCurrent user request:\n" + request
        var arguments = ["-p", prompt + Self.attachmentNote(attachments.filter { $0.kind == .text }) + images,
                         "--output-format", "stream-json"]
        if let model = selectedCLIModel?.slug, !model.isEmpty { arguments += ["-m", model] }
        runStreamJSON(executable: executable, arguments: arguments, workspace: workspace,
                      environment: ["KIMI_CODE_TRUST_WORKSPACE": "1"], name: "Kimi Code")
    }

    private static var mcpPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dogsc-mcp").path
    }

    private static func systemBriefing(history: [Message], workspace: URL) -> String {
        briefing(history: history)
            + "\n\nYour working folder is this conversation's workspace: \(workspace.path). Keep one-off working files there (transcripts, previews)."
    }

    /// Kimi's independent `role` / `content` headless stream.
    private func runStreamJSON(executable: String, arguments: [String], workspace: URL,
                               environment extra: [String: String], name: String) {
        let runningTurn = turnID
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.currentDirectoryURL = workspace
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentCLI.searchPath
        environment.merge(extra) { _, new in new }
        task.environment = environment
        task.standardInput = FileHandle.nullDevice

        final class Stream: @unchecked Sendable {
            var log = ""
            var partial = ""
            var lastText: String?
            var failed: String?
        }
        let stream = Stream()
        let consume: @Sendable ([Data], Data) -> Void = { [weak self] lines, pending in
            var texts: [String] = []
            for line in lines {
                guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    let text = String(decoding: line, as: UTF8.self)
                    stream.log += text + "\n"
                    continue
                }
                let type = event["type"] as? String
                let role = event["role"] as? String
                if type == "error" || type == "result" && (event["status"] as? String) == "error" {
                    stream.failed = (event["message"] as? String) ?? (event["error"] as? [String: Any])?["message"] as? String ?? "error"
                    stream.log += "ERROR: \(stream.failed!)\n"
                    continue
                }
                // Kimi's assistant messages carry tool_calls and content.
                if let calls = event["tool_calls"] as? [[String: Any]],
                   let name = (calls.first?["function"] as? [String: Any])?["name"] as? String {
                    self?.postActivity(Activity(kind: .tool, title: AgentChatModel.toolTitle(name)), turn: runningTurn)
                } else if type == "tool_use", let name = (event["tool_name"] as? String) ?? (event["name"] as? String) {
                    self?.postActivity(Activity(kind: .tool, title: AgentChatModel.toolTitle(name)), turn: runningTurn)
                } else if role == "tool" || type == "tool_result" {
                    self?.postActivity(Activity(kind: .thinking, title: appLocalized("正在思考")), turn: runningTurn)
                }
                guard role == "assistant", let content = event["content"] as? String else {
                    if type == "message", role == nil, let content = event["content"] as? String { stream.log += content + "\n" }
                    continue
                }
                if (event["delta"] as? Bool) == true {
                    stream.partial += content
                } else {
                    let text = (stream.partial + content).trimmingCharacters(in: .whitespacesAndNewlines)
                    stream.partial = ""
                    if !text.isEmpty { texts.append(text); stream.lastText = text }
                }
            }
            // A signed-out CLI asks to open the browser and waits forever.
            let wantsSignIn = (stream.log + String(decoding: pending, as: UTF8.self))
                .contains("Opening authentication page")
            let cancelForSignIn = wantsSignIn && stream.failed == nil
            if cancelForSignIn { stream.failed = "Opening authentication page" }
            if cancelForSignIn { AgentProcessCancellation.request(task) }
            guard !texts.isEmpty else { return }
            DispatchQueue.main.async {
                guard self?.acceptsOutput(from: runningTurn) == true else { return }
                for text in texts { self?.messages.append(Message(role: .assistant, text: text)) }
            }
        }
        let complete: @Sendable (Process) -> Void = { finished in
            var finalTexts: [String] = []
            let partial = stream.partial
            if !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { finalTexts.append(partial) }
            let log = stream.log, failed = stream.failed
            let leftover = finalTexts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finished.terminationStatus, reason = finished.terminationReason
            DispatchQueue.main.async {
                if reason == .uncaughtSignal, failed == nil {
                    self.finish(reply: nil, error: appLocalized("已停止。"), turn: runningTurn)
                } else if status == 0, failed == nil {
                    self.finish(reply: leftover.isEmpty ? nil : leftover, turn: runningTurn)
                } else if let problem = Self.cliProblem(in: log + (failed ?? ""), name: name) {
                    self.finish(reply: nil, error: problem.message, action: problem.action, detail: Self.tail(log), turn: runningTurn)
                } else {
                    self.finish(reply: nil, error: String(format: appLocalized("%@ 没有完成这次请求。"), name), detail: Self.tail(log), turn: runningTurn)
                }
            }
        }
        do {
            try AgentCLICommand.startLines(task, consume: consume, finished: complete)
            process = task
        } catch {
            finish(reply: nil, error: error.localizedDescription)
        }
    }

    private static func cliProblem(in log: String, name: String) -> (message: String, action: Message.Action?)? {
        let text = log.lowercased()
        if text.contains("authentication") || text.contains("login") || text.contains("401") || text.contains("unauthorized")
            || text.contains("not logged in") || text.contains("not authenticated")
            || text.contains("opening authentication page") {
            return (String(format: appLocalized("%@ 还没有登录。"), name), .signIn)
        }
        if text.contains("quota") || text.contains("rate limit") || text.contains("429") || text.contains("usage limit") {
            return (String(format: appLocalized("%@ 的使用额度已用完。可以换一个 AI 接着这段对话继续。"), name), .switchProvider)
        }
        if text.contains("model") && (text.contains("not found") || text.contains("not available") || text.contains("unknown")) {
            return (appLocalized("这个模型不能用你的账号调用，换一个模型试试。"), .chooseModel)
        }
        return nil
    }

    private static func claudeProblem(in log: String) -> (message: String, action: Message.Action?)? {
        let text = log.lowercased()
        if text.contains("not logged in") || text.contains("please run /login") || text.contains("invalid api key")
            || text.contains("authentication") || text.contains("401") {
            return (appLocalized("Claude Code 还没有登录。"), .signIn)
        }
        if text.contains("usage limit") || text.contains("rate limit") || text.contains("429") || text.contains("credit balance") {
            return (appLocalized("Claude Code 的使用额度已用完。可以换一个 AI 接着这段对话继续。"), .switchProvider)
        }
        if text.contains("model") && (text.contains("not found") || text.contains("not available") || text.contains("invalid")) {
            return (appLocalized("这个模型不能用你的账号调用，换一个模型试试。"), .chooseModel)
        }
        return nil
    }

    /// Turns Codex's error lines (never the whole log, which also contains
    /// tool output and numbers) into one sentence and the action that fixes it.
    private static func codexProblem(in log: String, model: String) -> (message: String, action: Message.Action?)? {
        let errors = log.split(separator: "\n")
            .filter { $0.hasPrefix("ERROR") || $0.contains("\"type\":\"error\"") || $0.hasPrefix("Error:") }
            .joined(separator: "\n")
            .lowercased()
        guard !errors.isEmpty else { return nil }
        if errors.contains("model_not_found") || errors.contains("model is not supported") {
            let name = model.isEmpty ? appLocalized("默认模型") : model
            return (String(format: appLocalized("模型 %@ 不能用你的账号调用。换一个模型，或留空使用 Codex 默认。"), name), .chooseModel)
        }
        if errors.contains("\"status\":401") || errors.contains("not logged in") || errors.contains("please log in")
            || errors.contains("login required") || errors.contains("unauthorized") {
            return (appLocalized("Codex 还没有登录。"), .signIn)
        }
        if errors.contains("\"status\":429") || errors.contains("usage limit") || errors.contains("rate limit") {
            return (appLocalized("Codex 的使用额度已用完。可以换一个 AI 接着这段对话继续。"), .switchProvider)
        }
        return nil
    }

    /// A reference image as a JPEG data URL, at most 2048 px on its long side.
    private static func imageDataURL(_ attachment: Attachment) -> String? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: attachment.path) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        else { return nil }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private static func tail(_ log: String) -> String {
        log.split(separator: "\n").filter { !$0.contains("User request:") }.suffix(8).joined(separator: "\n")
    }

    // MARK: OpenAI-compatible API with tool calling

    nonisolated(unsafe) private static let tools: [[String: Any]] = {
        func fn(_ name: String, _ description: String, _ properties: [String: Any] = [:], _ required: [String] = []) -> [String: Any] {
            ["type": "function", "function": [
                "name": name, "description": description,
                "parameters": ["type": "object", "properties": properties, "required": required],
            ]]
        }
        let number: [String: Any] = ["type": "number"], string: [String: Any] = ["type": "string"]
        return [
            fn("project_summary", "Title, output duration (s), playhead, clip counts, motionUsage by template/source, and footage (recording sources and timed main/overlay visuals)."),
            fn("media_list", "List existing media: scope project (default), shared (reusable files), library (favorites), or all; optional kind video/image/audio/animation. Returns IDs, names, paths and missing status.", ["scope": string, "kind": string]),
            fn("media_import", "Import media into the project bin. External files get a project-owned copy.",
               ["paths": ["type": "array", "items": string]], ["paths"]),
            fn("image_download", "Import a direct HTTPS PNG, JPEG, WebP or standalone SVG (imported as PNG) into shared media and the project bin. Supply the source page URL and optional display name. Returns assetId, path and projectPath for image slots.",
               ["url": string, "sourceURL": string, "name": string], ["url", "sourceURL"]),
            fn("sound_download", "Download an existing CC0 sound into shared media and keep a project copy; retries reuse existing files. Supply its direct audio url, source page sourceURL and verified CC0 licenseURL. Returns local path and duration. Place with timeline_add_audio or attach via html_create soundPath.",
               ["url": string, "sourceURL": string, "licenseURL": string, "name": string], ["url", "sourceURL", "licenseURL"]),
            fn("audio_export", "Write the edited program audio (M4A, output time) and return its path.", ["path": string]),
            fn("timeline_add_audio", "Place music or a sound effect. Reuses the same path/start/kind on a retry.",
               ["path": string, "start": number, "kind": ["type": "string", "enum": ["music", "effect"]], "volume": number, "fadeIn": number, "fadeOut": number], ["path", "start"]),
            fn("timeline_add_video", "Place fitted B-roll. maskShape and maskCornerRadius control the video mask (radius as a fraction of its short edge, default 0.12). pictureInPicture puts the camera above the video; videoInFront puts the video above. Omit cameraMode to use the last manual choice, initially camera above.",
               ["path": string, "start": number, "x": number, "y": number, "width": number, "volume": number,
                      "maskShape": ["type": "string", "enum": ["矩形", "圆角矩形", "圆形"]],
                      "maskCornerRadius": ["type": "number", "minimum": 0, "maximum": 0.5],
                      "cameraMode": ["type": "string", "enum": ["videoInFront", "pictureInPicture"]]], ["path", "start"]),
            fn("subtitles_get", "Current subtitle cues with stable IDs, text and output times."),
            fn("subtitles_update_text", "Correct text/translation on specific subtitle IDs. Preserves every cue's start, end and order. Use for local corrections.",
               ["cues": ["type": "array", "items": ["type": "object", "properties": ["id": string, "text": string, "secondary": string], "required": ["id"]]]], ["cues"]),
            fn("subtitles_set", "Replace all subtitles at the supplied times. Use subtitles_update_text for local corrections.",
               ["cues": ["type": "array", "items": ["type": "object", "properties": ["id": string, "start": number, "end": number, "text": string, "secondary": string], "required": ["start", "end", "text"]]]], ["cues"]),
            fn("subtitles_style", "Subtitle style: defaults fontScale 0.03, bottomMargin 0.05, backgroundOpacity 1; existing custom styles are preserved.", ["fontScale": number, "bottomMargin": number, "backgroundOpacity": number, "showsSecondary": ["type": "boolean"]]),
            fn("timeline_get", "Everything on the timeline in output seconds, with ids: main-track segments, zooms, 3D moves, highlights, overlays, audio. Object IDs address individual occurrences. Zooms include authored transitions/easing; zoomJoins reports evaluated gap, leftExitDuration, rightEnterDuration, fullFrameHold at 1x and continuous handoff. These expose timing for editorial choices, not automatic merging. Overlays include layerIndex.", [:], [] as [String]),
            fn("timeline_inspect", "Read native editable values for timeline objects, optionally filtered by ids. Returns a project revision and objects {id,kind,value}. Main clip value exposes source {start,end,speed}, audio, sceneStyle and media. source uses media seconds; output timing and availableSource bounds are reported separately.", ["ids": ["type": "array", "items": string]]),
            fn("timeline_update", "Apply partial patches to existing native objects in one undoable edit. changes [{id,patch}] uses the value shape from timeline_inspect; omitted fields stay unchanged. Supports zoom, 3D, camera motion, highlight, sticker, animation, video, audio, subtitle, and main clip source/media/appearance/audio. On a video, patch maskShape (矩形/圆角矩形/圆形), maskCornerRadius (0–0.5 of short edge), cameraMode (pictureInPicture/videoInFront), or layerIndex among visual overlays. Main patch.source {start?,end?,speed?} trims or extends media-source edges and ripples dependent tracks, like manual edge dragging. Optional revision detects intervening edits. Returns actual updated values.",
               ["revision": string, "changes": ["type": "array", "items": ["type": "object", "properties": ["id": string, "patch": ["type": "object"]], "required": ["id", "patch"]]]], ["changes"]),
            fn("timeline_add_sticker", "Place an image as a native editable sticker over the program. start/end are output seconds; x/y are canvas centre coordinates (0-1); width is canvas width fraction.",
               ["path": string, "start": number, "end": number, "x": number, "y": number, "width": number, "opacity": number], ["path", "start", "end"]),
            fn("timeline_cut", "Cut output-time ranges in one undoable edit; dependent tracks follow. Use ranges [{start,end}], or analysisId with wordRanges [{from,to,start?,end?}] and pauses [{id,keep}]. Word IDs are inclusive; defaults are recognizer endpoints, optional start/end are exact overrides. keep is remaining pause seconds (default 0.25, minimum 0). Acoustic evidence is advisory, not permission. analysisId checks the audio snapshot; explicit ranges may be included with it. Optional revision from timeline_get binds any cut to that project state. Returns appliedRanges and, when matching speech analysis is cached, cutReview for every new join: fine edge waveform, retained quiet, utterance context and current segment IDs/source bounds for further timeline_update edits. remainingPauses lists all retained pause candidates, including those within kept sentences, in the new output clock.", ["revision": string, "analysisId": string,
                      "wordRanges": ["type": "array", "items": ["type": "object", "properties": ["from": ["type": "integer"], "to": ["type": "integer"], "start": number, "end": number], "required": ["from", "to"]]],
                      "pauses": ["type": "array", "items": ["type": "object", "properties": ["id": ["type": "integer"], "keep": number], "required": ["id"]]],
                      "ranges": ["type": "array", "items": ["type": "object", "properties": ["start": number, "end": number], "required": ["start", "end"]]]], []),
            fn("timeline_remove", "Delete clips by id (zoom, 3D, highlight, overlay, audio, subtitle, video or main-track segment) in one undoable step. Ids come from timeline_get.", ["ids": ["type": "array", "items": ["type": "string"]]], ["ids"]),
            fn("pointer_events", "Recorded mouse clicks (and optionally moves) in output seconds with x,y (0-1 of the recording). Clicks show where the viewer's attention was — good zoom targets.", ["from": ["type": "number"], "to": ["type": "number"], "kinds": ["type": "array", "items": ["type": "string", "enum": ["click", "move"]]]], [] as [String]),
            fn("zoom_add", "Zoom the recording (default target recording) or the frontmost active imported video (target overlayVideo). x,y = focus in the targeted source (0-1), scale 1.05-4 (default: the project's). start begins entrance; end begins return; transition is seconds per leg. Choose the span around the actual explanation or action. Touching zooms on the same surface continue without a 1x reset. Existing target, startTime/endTime, focus, scale and separate transition durations are editable with timeline_update; timeline_get reports zoomJoins.", ["start": ["type": "number"], "end": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "scale": ["type": "number"], "transition": ["type": "number"], "target": ["type": "string", "enum": ["recording", "overlayVideo"]]], ["start", "end", "x", "y"]),
            fn("motion3d_add", "Add a 3D move of the recording (tilt in degrees). Position and timing are editable.", ["start": ["type": "number"], "end": ["type": "number"], "rotationX": ["type": "number"], "rotationY": ["type": "number"], "rotationZ": ["type": "number"], "scale": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "leadIn": ["type": "number"]], ["start", "end"]),
            fn("highlight_add", "Highlight a box on the recording: 'spotlight' dims everything else to draw the eye, 'blur' hides the box (passwords, private data). Box is 0-1 of the recording, top-left origin.", ["start": ["type": "number"], "end": ["type": "number"], "x": ["type": "number"], "y": ["type": "number"], "width": ["type": "number"], "height": ["type": "number"], "style": ["type": "string", "enum": ["spotlight", "blur"]], "dim": ["type": "number"]], ["start", "end", "x", "y", "width", "height"]),
            fn("settings_get", "The whole-video settings as JSON: canvas (background, padding, corners, device frame), camera bubble, audio levels, cursor, motion defaults, export settings.", [:], [] as [String]),
            fn("settings_set", "Change whole-video settings with a JSON patch in the same shape as settings_get (merged, one undoable step). Invalid values are refused with the reason — read settings_get first.", ["patch": ["type": "object"]], ["patch"]),
            fn("app_help", "How DogSC itself is used: where each setting lives, shortcuts and step-by-step paths. Use it to answer the user's 'how do I…' questions accurately.", ["topic": ["type": "string"]], [] as [String]),
            fn("timeline_insert_black", "Insert a black clip into the main track at start (default 2 s).", ["start": number, "duration": number], ["start"]),
            fn("template_read", "Browse local style packs. Folders return immediate entries and all nested HTML paths in templates. Folder and template results include applicable README paths and introductions in styleGuides. Pass a returned relative path to read a README, or inspect fields, editable imageSlots, camera placement and soundCues. includeSource returns authored HTML.",
               ["path": string, "includeSource": ["type": "boolean"]], [] as [String]),
            fn("html_create", "Create and place an HTML motion (see skill). Supply html or a templatePath from template_read. For a speech-timed overlay, supply speechAnchor instead of start. It aligns a local visual beat (seconds, default 0) with the onset of a numbered transcript word. placement overlay|main. Identical retries reuse the placement; revisions use html_update. copy:true creates an independent asset. Both tracks use the HTML score unless sound or soundPath overrides it.",
               ["name": string, "html": string, "templatePath": string, "start": number, "speechAnchor": ["type": "object", "properties": [
                    "analysisId": string, "word": ["type": "integer"], "localTime": number],
                    "required": ["analysisId", "word"], "additionalProperties": false], "duration": number, "placement": string, "x": number, "y": number,
                "width": number, "framed": ["type": "boolean"], "copy": ["type": "boolean"], "soundPath": string, "sound": ["type": "array", "items": ["type": "object"]]], ["name", "placement"]),
            fn("html_update", "Revise an existing HTML motion in this project. Supply exactly one current clip/asset id or path, plus the full html. Preserves IDs, timing, per-instance fields and user edits; one bin item, undoable. Returns the new path; other projects retain their source.",
               ["id": string, "path": string, "html": string], ["html"]),
            fn("html_preview", "Render PNG frames of an HTML motion page at given times.", ["path": string, "times": ["type": "array", "items": number]], ["path"]),
            fn("sound_create", "Synthesise a sound effect (types: whoosh, swoosh_down, riser, hit, boom, click, tick, pop, ding, chime, shimmer, glitch, tone) from events [{type, at, duration?, volume?, pitch?, pan?}]; with start, place it on an audio track.",
               ["name": string, "events": ["type": "array", "items": ["type": "object"]], "start": number, "volume": number], ["name", "events"]),
            fn("canvas_snapshot", "Render a specified output time independently of the editor playhead. Returns PNG path, requested/rendered time, decoded source timestamp, source/clip IDs and coordinate geometry. view canvas (default) includes all effects and reports the active caption’s subtitleRestingRect in top-left canvas pixels. source shows the uncropped recording. maxDimension defaults to 1280 (64...8192).", ["time": number, "view": string, "maxDimension": number]),
            fn("audio_transcribe", "Transcribe the program voice; returns phrases and numbered tokens {i,s,e,t}. Cached with audio_analyze_edits; refresh forces reanalysis. Use audio_analyze_edits for speech cutting.", ["language": string, "refresh": ["type": "boolean"]]),
            fn("audio_analyze_edits", "Raw speech, independent local waveform evidence, suggested cut times, pause IDs, utterance context spanning pauses, nearby repeated phrases with surrounding takes, and existing edit joins in output seconds. Suggestions can fall inside recognizer ranges; none is an automatic deletion or sentence verdict. from/to select a window (default 180 s, pages up to 300 s). includeWords adds token boundaries; includeWaveform adds broad peak dBFS bins. Joins always include fine local waveform; utterance context is not split by silence. pauseGroups combines brief-noise-separated pauses with text context and optional acousticInterior cut ranges. Cached with audio_transcribe; refresh reanalyses. analysisId ties word IDs and pauses to this audio snapshot. Frame counts use the current export videoFrameRate, independently of the audio measurementStep. Existing joins expose leftQuietFrames/rightQuietFrames; cutReview exposes left/right quietFrames and total retainedQuietFrames. Short includeWaveform windows give finer local detail.", ["language": string, "from": number, "to": number, "includeWords": ["type": "boolean"], "includeWaveform": ["type": "boolean"], "refresh": ["type": "boolean"]]),
            fn("subtitles_set_from_words", "Generate captions from inclusive from/to word IDs. Omit text for faithful transcript wording and automatic profanity filtering. Put translations in secondary; use subtitles_update_text for specific recognition errors. Only supply text for an explicitly requested rewrite. Local waveform evidence refines edges. holdToNext extends the cue to the next start; explicit start/end take priority. Returns cue IDs, times and gaps.",
               ["analysisId": string, "cues": ["type": "array", "items": ["type": "object", "properties": [
                   "from": ["type": "integer"], "to": ["type": "integer"], "text": ["type": "string", "description": "Omit unless the user explicitly requested a rewrite."], "secondary": string, "start": number, "end": number, "holdToNext": ["type": "boolean"],
               ], "required": ["from", "to"]]]], ["cues"]),
            fn("subtitles_align_to_speech", "Refine measured silence inside existing subtitle edges without shifting neighboring cues."),
        ]
    }()

    private static let toolMethods: [String: String] = [
        "project_summary": "project.summary", "media_list": "media.list",
        "media_import": "media.import", "audio_export": "audio.export",
        "sound_download": "sound.download", "image_download": "image.download",
        "timeline_add_audio": "timeline.addAudio",
        "timeline_add_video": "timeline.addVideo", "subtitles_get": "subtitles.get", "subtitles_set": "subtitles.set", "subtitles_update_text": "subtitles.updateText", "subtitles_style": "subtitles.style",
        "audio_analyze_edits": "audio.analyzeEdits", "audio_transcribe": "audio.transcribe", "subtitles_set_from_words": "subtitles.fromWords", "subtitles_align_to_speech": "subtitles.alignToSpeech",
        "canvas_snapshot": "canvas.snapshot", "timeline_insert_black": "timeline.insertBlack",
        "timeline_get": "timeline.get", "timeline_inspect": "timeline.inspect",
        "timeline_update": "timeline.update", "timeline_add_sticker": "timeline.addSticker",
        "timeline_cut": "timeline.cut",
        "timeline_remove": "timeline.remove",
        "pointer_events": "pointer.events",
        "zoom_add": "zoom.add",
        "motion3d_add": "motion3d.add",
        "highlight_add": "highlight.add",
        "settings_get": "settings.get",
        "settings_set": "settings.set",
        "app_help": "app.help", "sound_create": "sound.create",
        "template_read": "template.read", "html_create": "html.create", "html_update": "html.update", "html_preview": "html.preview",
    ]

    private func runAPI(request: String, attachments: [Attachment], history: [Message]) {
        let runningTurn = turnID
        guard let key = Keychain.read(), let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("chat/completions") else {
            finish(reply: nil, error: appLocalized("API 设置不完整。"))
            return
        }
        let model = apiModel
        var conversation: [[String: Any]] = [["role": "system", "content": Self.briefing(history: [])]]
        for message in history {
            conversation.append(["role": message.role == .user ? "user" : "assistant", "content": message.text])
        }
        let images = attachments.filter { $0.kind == .image }.compactMap(Self.imageDataURL)
        let text = request + Self.attachmentNote(attachments)
        if images.isEmpty {
            conversation.append(["role": "user", "content": text])
        } else {
            conversation.append(["role": "user", "content": [["type": "text", "text": text]]
                + images.map { ["type": "image_url", "image_url": ["url": $0]] }])
        }
        apiTask = Task { [weak self] in
            do {
                // The same tools as the MCP server; DogSC runs the agent loop itself.
                var seesImages = true
                var pendingImages: [String] = []
                for _ in 0..<40 {
                    try Task.checkCancellation()
                    var body = try JSONSerialization.data(withJSONObject: ["model": model, "messages": conversation, "tools": Self.tools])
                    var (data, status) = try await Self.post(url: url, key: key, body: body)
                    try Task.checkCancellation()
                    // A text-only model refuses image parts: drop them once and continue without.
                    if status == 400, seesImages, Self.hasImageParts(conversation) {
                        seesImages = false
                        conversation = Self.withoutImageParts(conversation)
                        body = try JSONSerialization.data(withJSONObject: ["model": model, "messages": conversation, "tools": Self.tools])
                        (data, status) = try await Self.post(url: url, key: key, body: body)
                    }
                    try Task.checkCancellation()
                    let reply = try Self.parseReply(data: data, status: status)
                    let calls = reply["tool_calls"] as? [[String: Any]] ?? []
                    var assistant: [String: Any] = ["role": "assistant", "content": reply["content"] as? String ?? ""]
                    if !calls.isEmpty { assistant["tool_calls"] = calls }
                    // DeepSeek's thinking models expect their reasoning back
                    // between the tool calls of one turn.
                    if let reasoning = reply["reasoning_content"] as? String, !reasoning.isEmpty {
                        assistant["reasoning_content"] = reasoning
                    }
                    conversation.append(assistant)
                    if calls.isEmpty {
                        self?.finish(reply: reply["content"] as? String, turn: runningTurn)
                        return
                    }
                    for call in calls {
                        try Task.checkCancellation()
                        let function = call["function"] as? [String: Any] ?? [:]
                        let name = function["name"] as? String ?? ""
                        let arguments = (function["arguments"] as? String)
                            .flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
                        var content: String
                        do {
                            guard let method = Self.toolMethods[name] else { throw AgentBridgeServer.BridgeError(message: "Unknown tool \(name)") }
                            let result = try await AgentBridgeServer.shared.perform(method, arguments)
                            try Task.checkCancellation()
                            if seesImages {
                                let paths: [String]
                                switch method {
                                case "canvas.snapshot": paths = ((result as? [String: Any])?["path"] as? String).map { [$0] } ?? []
                                case "html.preview": paths = result as? [String] ?? []
                                default: paths = []
                                }
                                pendingImages += paths.prefix(6).compactMap {
                                    Self.imageDataURL(Attachment(kind: .image, path: $0, name: ""))
                                }
                            }
                            content = JSONSerialization.isValidJSONObject(result)
                                ? String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
                                : "\(result)"
                        } catch {
                            content = "Error: \(error.localizedDescription)"
                        }
                        conversation.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": content])
                    }
                    if !pendingImages.isEmpty {
                        conversation.append(["role": "user", "content": [["type": "text", "text": Self.renderedFramesNote]]
                            + pendingImages.map { ["type": "image_url", "image_url": ["url": $0]] }])
                        pendingImages = []
                    }
                }
                self?.finish(reply: nil, error: appLocalized("步骤太多，已停止。"), turn: runningTurn)
            } catch is CancellationError {
                self?.finish(reply: nil, error: appLocalized("已停止。"), turn: runningTurn)
            } catch {
                self?.finish(reply: nil, error: error.localizedDescription, turn: runningTurn)
            }
        }
    }

    private nonisolated static let renderedFramesNote = "The frames you just rendered:"

    private nonisolated static func hasImageParts(_ conversation: [[String: Any]]) -> Bool {
        conversation.contains { message in
            (message["content"] as? [[String: Any]])?.contains { $0["type"] as? String == "image_url" } == true
        }
    }

    /// The conversation as text only: rendered-frame notes go, an image
    /// the user attached becomes its text part.
    private nonisolated static func withoutImageParts(_ conversation: [[String: Any]]) -> [[String: Any]] {
        conversation.compactMap { message in
            guard let parts = message["content"] as? [[String: Any]] else { return message }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if text == renderedFramesNote { return nil }
            var copy = message
            copy["content"] = text
            return copy
        }
    }

    private nonisolated static func post(url: URL, key: String, body: Data) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private static func parseReply(data: Data, status: Int) throws -> [String: Any] {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status >= 400 || status == 0 {
            let message = (json["error"] as? [String: Any])?["message"] as? String ?? "HTTP \(status)"
            throw AgentBridgeServer.BridgeError(message: message)
        }
        guard let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
            throw AgentBridgeServer.BridgeError(message: appLocalized("模型没有返回内容。"))
        }
        return message
    }
}

/// The API key lives in the login keychain, never in preferences.
enum Keychain {
    private static var query: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "cn.laogou.dogsc.agent",
        kSecAttrAccount as String: "api-key",
    ] }

    static func read() -> String? {
        var item: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) {
        delete()
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

extension Array where Element == AgentChatModel.Message {
    /// The conversation as sent with each turn: the latest 24 messages in
    /// full, older ones shortened to a line each so a long thread (or one
    /// handed to another AI) still carries what was asked and done.
    func reduced() -> [AgentChatModel.Message] {
        guard count > 24 else { return self }
        let older = dropLast(24).suffix(60).map { message -> AgentChatModel.Message in
            var copy = message
            let flat = message.text.replacingOccurrences(of: "\n", with: " ")
            copy.text = flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
            return copy
        }
        return Array(older) + suffix(24)
    }
}
