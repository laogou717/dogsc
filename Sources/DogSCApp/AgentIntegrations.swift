import AppKit
import Foundation

/// Lets AIs outside DogSC (Claude Code, Codex, Antigravity CLI, Kimi Code,
/// OpenCode, DeepSeek Harness) edit the open project: one click registers
/// the "dogsc" MCP server in that tool's own user config and installs the
/// dogsc-editor skill where the tool looks for skills.
///
/// Everything points at stable files under Application Support, refreshed
/// on every launch, so moving or updating DogSC never breaks a connection
/// and an installed skill never goes stale.
@MainActor
final class AgentIntegrations: ObservableObject {
    static let shared = AgentIntegrations()

    enum Target: String, CaseIterable, Identifiable {
        case claude, codex, gemini, kimi, opencode, deepseek
        var id: String { rawValue }

        var title: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .gemini: "Antigravity CLI"
            case .kimi: "Kimi Code"
            case .opencode: "OpenCode"
            case .deepseek: "DeepSeek Harness"
            }
        }

        var executable: String {
            switch self {
            case .claude: "claude"
            case .codex: "codex"
            case .gemini: "agy"
            case .kimi: "kimi"
            case .opencode: "opencode"
            case .deepseek: "dsh"
            }
        }

        /// Where this tool reads user skills; nil when it has none (the MCP
        /// server's own instructions still carry the guide).
        var skillFolder: URL? {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .claude: return home.appendingPathComponent(".claude/skills/dogsc-editor", isDirectory: true)
            case .codex: return home.appendingPathComponent(".codex/skills/dogsc-editor", isDirectory: true)
            // DeepSeek Harness scans ~/.agents/skills (shared with other agents).
            case .deepseek: return home.appendingPathComponent(".agents/skills/dogsc-editor", isDirectory: true)
            case .gemini: return home.appendingPathComponent(".gemini/antigravity-cli/skills/dogsc-editor", isDirectory: true)
            case .kimi, .opencode: return nil
            }
        }

        /// The desktop app counts too: DeepSeek Harness reads ~/.dsh.
        var isInstalled: Bool {
            if AgentCLI.isInstalled(executable) { return true }
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .deepseek: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".dsh").path)
            case .kimi: return FileManager.default.fileExists(atPath: home.appendingPathComponent(".kimi-code").path)
            default: return false
            }
        }
    }

    enum State: Equatable { case notInstalled, disconnected, outdated, connected, working, failed(String) }

    @Published private(set) var states: [Target: State] = [:]

    // MARK: Stable files

    nonisolated static var supportFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DogSC", isDirectory: true)
    }

    /// A launcher that always runs the dogsc-mcp of the DogSC opened last.
    nonisolated static var mcpLauncher: URL { supportFolder.appendingPathComponent("bin/dogsc-mcp") }

    private static var bundledMCP: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/dogsc-mcp").path
    }

    nonisolated static var bundledSkill: URL? {
        Bundle.main.url(forResource: "DogSC-Skill", withExtension: "md", subdirectory: "Agent")
    }

    /// Call once at launch: rewrite the launcher for this copy of DogSC and
    /// bring every installed skill up to date.
    func refreshStableFiles() {
        let fm = FileManager.default
        let launcher = Self.mcpLauncher
        try? fm.createDirectory(at: launcher.deletingLastPathComponent(), withIntermediateDirectories: true)
        let quoted = Self.bundledMCP.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/sh\n# Written by DogSC at launch; runs the DogSC opened most recently.\nexec '\(quoted)' \"$@\"\n"
        if (try? String(contentsOf: launcher, encoding: .utf8)) != script {
            try? script.write(to: launcher, atomically: true, encoding: .utf8)
        }
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        if let source = Self.bundledSkill, let skill = try? Data(contentsOf: source) {
            for target in Target.allCases {
                guard let folder = target.skillFolder else { continue }
                let file = folder.appendingPathComponent("SKILL.md")
                if fm.fileExists(atPath: file.path), (try? Data(contentsOf: file)) != skill {
                    try? skill.write(to: file, options: .atomic)
                }
            }
        }
        refresh()
    }

    // MARK: State

    func refresh() {
        for target in Target.allCases where states[target] != .working {
            states[target] = currentState(target)
        }
    }

    func state(_ target: Target) -> State { states[target] ?? currentState(target) }

    private func currentState(_ target: Target) -> State {
        guard target.isInstalled else { return .notInstalled }
        guard let command = registeredCommand(target) else { return .disconnected }
        let skillOK = target.skillFolder.map {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path)
        } ?? true
        return command == Self.mcpLauncher.path && skillOK ? .connected : .outdated
    }

    /// The command the tool will start for "dogsc", read from its config.
    private func registeredCommand(_ target: Target) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func json(_ path: String) -> [String: Any]? {
            (try? Data(contentsOf: home.appendingPathComponent(path)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        switch target {
        case .claude:
            return ((json(".claude.json")?["mcpServers"] as? [String: Any])?["dogsc"] as? [String: Any])?["command"] as? String
        case .gemini:
            return ((json(".gemini/config/mcp_config.json")?["mcpServers"] as? [String: Any])?["dogsc"] as? [String: Any])?["command"] as? String
        case .kimi:
            return ((json(".kimi-code/mcp.json")?["mcpServers"] as? [String: Any])?["dogsc"] as? [String: Any])?["command"] as? String
        case .opencode:
            let entry = (json(".config/opencode/opencode.json")?["mcp"] as? [String: Any])?["dogsc"] as? [String: Any]
            return (entry?["command"] as? [String])?.first
        case .codex:
            guard let text = try? String(contentsOf: home.appendingPathComponent(".codex/config.toml"), encoding: .utf8),
                  let header = text.range(of: "[mcp_servers.dogsc]") else { return nil }
            let rest = text[header.upperBound...]
            let table = rest.range(of: "\n[").map { rest[..<$0.lowerBound] } ?? rest
            for line in table.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("command") , let q1 = trimmed.firstIndex(of: "\""), let q2 = trimmed.lastIndex(of: "\""), q1 < q2 {
                    return String(trimmed[trimmed.index(after: q1)..<q2])
                }
            }
            return ""
        case .deepseek:
            guard let text = try? String(contentsOf: Self.dshPatchFile, encoding: .utf8),
                  let start = text.range(of: Self.dshBegin), let end = text.range(of: Self.dshEnd),
                  start.upperBound < end.lowerBound else { return nil }
            let block = text[start.upperBound..<end.lowerBound]
            for line in block.split(separator: "\n") where line.contains("command:") {
                return line.split(separator: ":", maxSplits: 1).last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            }
            return ""
        }
    }

    // MARK: Connect / disconnect

    func connect(_ target: Target) {
        states[target] = .working
        let launcher = Self.mcpLauncher.path
        Task.detached(priority: .userInitiated) {
            let error = Self.register(target, command: launcher)
            if error == nil { Self.installSkill(target) }
            await MainActor.run {
                self.states[target] = error.map { .failed($0) } ?? self.currentState(target)
            }
        }
    }

    func disconnect(_ target: Target) {
        states[target] = .working
        Task.detached(priority: .userInitiated) {
            Self.unregister(target)
            if let folder = target.skillFolder { try? FileManager.default.removeItem(at: folder) }
            await MainActor.run { self.states[target] = self.currentState(target) }
        }
    }

    nonisolated private static func installSkill(_ target: Target) {
        guard let folder = target.skillFolder, let source = bundledSkill,
              let skill = try? Data(contentsOf: source) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? skill.write(to: folder.appendingPathComponent("SKILL.md"), options: .atomic)
    }

    /// Returns an error message, or nil on success.
    nonisolated private static func register(_ target: Target, command: String) -> String? {
        switch target {
        case .claude:
            _ = runCLI("claude", ["mcp", "remove", "-s", "user", "dogsc"])
            return runCLI("claude", ["mcp", "add", "-s", "user", "dogsc", "--", command])
        case .codex:
            _ = runCLI("codex", ["mcp", "remove", "dogsc"])
            if let error = runCLI("codex", ["mcp", "add", "dogsc", "--", command]) { return error }
            // Rendering a motion or transcribing can outlast Codex's 60 s default.
            let config = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
            if var text = try? String(contentsOf: config, encoding: .utf8),
               let header = text.range(of: "[mcp_servers.dogsc]\n"),
               !text[header.upperBound...].prefix(400).contains("tool_timeout_sec") {
                text.insert(contentsOf: "tool_timeout_sec = 900\n", at: header.upperBound)
                try? text.write(to: config, atomically: true, encoding: .utf8)
            }
            return nil
        case .gemini:
            return editJSON(".gemini/config/mcp_config.json") { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers["dogsc"] = ["command": command, "args": [] as [String], "timeoutSeconds": 900] as [String: Any]
                root["mcpServers"] = servers
            }
        case .kimi:
            return editJSON(".kimi-code/mcp.json") { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers["dogsc"] = ["command": command, "args": [] as [String]]
                root["mcpServers"] = servers
            }
        case .opencode:
            return editJSON(".config/opencode/opencode.json") { root in
                var servers = root["mcp"] as? [String: Any] ?? [:]
                servers["dogsc"] = ["type": "local", "command": [command], "enabled": true, "timeout": 900_000] as [String: Any]
                root["mcp"] = servers
            }
        case .deepseek:
            return editDSHPatch(command: command)
        }
    }

    nonisolated private static func unregister(_ target: Target) {
        switch target {
        case .claude: _ = runCLI("claude", ["mcp", "remove", "-s", "user", "dogsc"])
        case .codex: _ = runCLI("codex", ["mcp", "remove", "dogsc"])
        case .gemini:
            _ = editJSON(".gemini/config/mcp_config.json") { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers["dogsc"] = nil
                root["mcpServers"] = servers
            }
        case .kimi:
            _ = editJSON(".kimi-code/mcp.json") { root in
                var servers = root["mcpServers"] as? [String: Any] ?? [:]
                servers["dogsc"] = nil
                root["mcpServers"] = servers
            }
        case .opencode:
            _ = editJSON(".config/opencode/opencode.json") { root in
                var servers = root["mcp"] as? [String: Any] ?? [:]
                servers["dogsc"] = nil
                root["mcp"] = servers
            }
        case .deepseek: _ = editDSHPatch(command: nil)
        }
    }

    // MARK: DeepSeek Harness (~/.dsh/cordis.patch.yml)

    nonisolated static var dshPatchFile: URL {
        let env = ProcessInfo.processInfo.environment["DSH_HOME"]
        let home = env.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh")
        return home.appendingPathComponent("cordis.patch.yml")
    }
    nonisolated static let dshBegin = "# >>> DogSC (managed by DogSC; edit in DogSC Settings › AI)"
    nonisolated static let dshEnd = "# <<< DogSC"

    /// The MCP client entry, as a Harness patch `insert` item.
    nonisolated static func dshEntry(command: String) -> String {
        let escaped = command.replacingOccurrences(of: "'", with: "''")
        return """
        - insert:
            - id: mcp-dogsc
              name: '@deepseek-ai/dsh-mcp-client'
              config:
                serverName: dogsc
                transport: stdio
                command: '\(escaped)'
                toolCallTimeoutMs: 900000
        """
    }

    /// Adds (or with nil removes) DogSC's block in the home patch layer,
    /// leaving everything else the user wrote untouched.
    nonisolated private static func editDSHPatch(command: String?) -> String? {
        let file = dshPatchFile
        let fm = FileManager.default
        var text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let start = text.range(of: dshBegin), let end = text.range(of: dshEnd, range: start.upperBound..<text.endIndex) {
            var upper = end.upperBound
            if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
            text.removeSubrange(start.lowerBound..<upper)
        }
        // An empty list literal cannot be followed by list items.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces) != "[]" }
        text = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if let command {
            text += (text.isEmpty ? "" : "\n\n") + dshBegin + "\n" + dshEntry(command: command) + "\n" + dshEnd
        }
        // The Harness rejects an empty or comments-only layer.
        let meaningful = text.split(separator: "\n").contains {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return !t.isEmpty && !t.hasPrefix("#")
        }
        if !meaningful { text += (text.isEmpty ? "" : "\n") + "[]" }
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (text + "\n").write(to: file, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Helpers

    nonisolated private static func editJSON(_ relativePath: String, _ change: (inout [String: Any]) -> Void) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(relativePath)
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return String(format: appLocalized("无法读取 %@，请检查这个文件的格式。"), url.path)
            }
            root = parsed
        }
        change(&root)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs a tool's own `mcp` command; returns its message on failure.
    nonisolated private static func runCLI(_ name: String, _ arguments: [String]) -> String? {
        guard let path = AgentCLI.path(for: name) else {
            return String(format: appLocalized("没有找到 %@。"), name)
        }
        let result = AgentCLICommand.run(path, arguments, timeout: 60, mergesStandardError: true)
        return result.status == 0 ? nil : result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
