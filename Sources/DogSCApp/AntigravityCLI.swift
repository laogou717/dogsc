import Foundation

/// Antigravity's headless protocol differs from the former Gemini CLI.
/// Keep catalog and stream parsing independent of the chat view lifecycle.
enum AntigravityCLI {
    struct Model: Sendable {
        let slug: String
        let name: String
    }

    static func models(from output: String) -> [Model] {
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let separator = line.range(of: "\t")
                ?? line.range(of: #"\s{2,}"#, options: .regularExpression)
            guard let separator else { return nil }
            let slug = String(line[..<separator.lowerBound])
            let name = line[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            guard slug.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/-]*$"#, options: .regularExpression) != nil,
                  !name.isEmpty, seen.insert(slug).inserted else { return nil }
            return Model(slug: slug, name: name)
        }
    }

    struct StreamUpdate: Sendable {
        struct Text: Sendable {
            let key: String
            let value: String
        }
        var texts: [Text] = []
        var event = ""
        var conversationID: String?
        var state: String?
        var stepIndex: Int?
        var toolName: String?
        var toolDetail: String?
        var finishedTool = false
        var status: String?
        var error: String?
        var usage: [String: Int]?
        var configuration: [String: String]?
    }

    struct StreamDecoder {
        private var steps: [Int: String] = [:]

        mutating func consume(_ event: [String: Any]) -> StreamUpdate {
            var update = StreamUpdate()
            update.event = event["event"] as? String ?? ""
            update.conversationID = event["conversation_id"] as? String
            switch event["event"] as? String {
            case "init":
                update.configuration = (event["init"] as? [String: Any])?.compactMapValues { $0 as? String }
            case "step_update":
                guard let step = event["step_update"] as? [String: Any] else { return update }
                let state = step["state"] as? String
                update.state = state
                update.stepIndex = step["step_index"] as? Int
                update.conversationID = step["conversation_id"] as? String ?? update.conversationID
                if step["step_type"] as? String == "tool" {
                    update.toolName = step["tool_name"] as? String
                    let info = step["tool_info"] as? [String: Any]
                    if let parameters = info?["parameters"], JSONSerialization.isValidJSONObject(parameters),
                       let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]) {
                        update.toolDetail = String(String(decoding: data, as: UTF8.self).prefix(2_000))
                    }
                    if state == "DONE" { update.finishedTool = true }
                } else if step["step_type"] as? String == "agent_response", let index = update.stepIndex {
                    if let delta = step["text_delta"] as? String, !delta.isEmpty {
                        steps[index, default: ""] += delta
                        update.texts.append(.init(key: String(index), value: steps[index] ?? ""))
                    }
                }
            case "result":
                guard let result = event["result"] as? [String: Any] else { return update }
                update.conversationID = result["conversation_id"] as? String ?? update.conversationID
                update.status = (result["status"] as? String)?.uppercased() ?? "ERROR"
                update.usage = result["usage"] as? [String: Int]
                if let response = result["response"] as? String {
                    let text = response.trimmingCharacters(in: .whitespacesAndNewlines)
                    let emitted = steps.keys.sorted().compactMap { steps[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    if !text.isEmpty, emitted.last != text, emitted.joined(separator: "\n\n") != text {
                        update.texts.append(.init(key: "result", value: text))
                    }
                }
                if update.status != "SUCCESS" {
                    update.error = result["error"] as? String
                        ?? (result["error"] as? [String: Any])?["message"] as? String
                        ?? "Antigravity CLI: \(update.status ?? "ERROR")"
                }
                steps = [:]
            case "error":
                update.status = "ERROR"
                update.error = event["message"] as? String
                    ?? event["error"] as? String
                    ?? (event["error"] as? [String: Any])?["message"] as? String
                    ?? "Antigravity CLI returned an error."
            default: break
            }
            return update
        }
    }
}
