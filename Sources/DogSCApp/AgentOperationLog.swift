import CryptoKit
import Foundation
import os
import RecorderCore

/// Local development diagnostics, outside the project and the agent workspace.
/// Nothing from this recorder is added to prompts, tool responses or the UI.
final class AgentOperationLog: @unchecked Sendable {
    static let shared: AgentOperationLog? = {
        guard Bundle.main.bundleIdentifier == "cn.laogou.dogsc.dev" else { return nil }
        return AgentOperationLog()
    }()

    @TaskLocal static var callID: UUID?

    /// Fields are immutable JSON values from tool requests/results. The
    /// unchecked wrapper only transfers that value snapshot to the writer.
    private struct Entry: @unchecked Sendable {
        let date: Date
        let event: String
        var fields: [String: Any]
        let project: RecorderProject?
    }

    private let queue = DispatchQueue(label: "cn.laogou.dogsc.agent-operation-log", qos: .utility)
    private let directory: URL
    private let sessionID = UUID().uuidString
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "agent-operation-log")

    // Accessed only on queue.
    private var file: FileHandle?
    private var sequence = 0
    private var failed = false
    private var savedPayloads = Set<String>()
    private var lastProject: RecorderProject?
    private var lastProjectReference: [String: Any]?
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let timestamp = Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-")
        directory = library.appendingPathComponent("Logs/DogSC/AI", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(ProcessInfo.processInfo.processIdentifier)-\(sessionID.prefix(8))",
                                    isDirectory: true)
        let bundle = Bundle.main
        var metadata: [String: Any] = [
            "bundleID": bundle.bundleIdentifier ?? "",
            "appVersion": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "buildVersion": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "processID": ProcessInfo.processInfo.processIdentifier,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let executable = bundle.executableURL {
            metadata["executable"] = executable.path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
               let modified = attributes[.modificationDate] as? Date {
                metadata["executableModifiedAt"] = modified.formatted(.iso8601)
            }
        }
        record("session.started", fields: metadata)
    }

    func record(_ event: String, fields: [String: Any], project: RecorderProject? = nil) {
        let entry = Entry(date: Date(), event: event, fields: fields, project: project)
        queue.async { self.append(entry) }
    }

    /// Preserve the exact recognizer tokens and boundary evidence once, so
    /// later word IDs, paging requests and rejected joins remain traceable.
    func recordSpeech(_ analysis: SpeechEditAnalysis, fields: [String: Any]) {
        let entry = Entry(date: Date(), event: "speech.analysis", fields: fields, project: nil)
        queue.async {
            var entry = entry
            func span(_ value: SpeechEditAnalysis.Span?) -> Any {
                guard let value else { return NSNull() }
                return ["start": value.start, "end": value.end]
            }
            entry.fields["analysisId"] = analysis.id
            entry.fields["analysis"] = [
                "id": analysis.id,
                "duration": analysis.duration,
                "measuredDuration": analysis.measuredDuration,
                "words": analysis.transcript.words.enumerated().map { i, word in
                    ["i": i, "start": word.start, "end": word.end, "text": word.text] as [String: Any]
                },
                "phrases": analysis.transcript.segments.map {
                    ["start": $0.start, "end": $0.end, "text": $0.text,
                     "from": $0.firstWord, "to": $0.lastWord] as [String: Any]
                },
                "units": analysis.units.map {
                    ["from": $0.from, "to": $0.to, "text": $0.text,
                     "sentencePunctuation": $0.sentencePunctuation] as [String: Any]
                },
                "boundaries": analysis.boundaries.map {
                    ["beforeWord": $0.beforeWord, "start": $0.start, "end": $0.end,
                     "evidence": $0.evidence, "quiet": span($0.quiet),
                     "cutAfterLeft": $0.cutAfterLeft as Any? ?? NSNull(),
                     "cutBeforeRight": $0.cutBeforeRight as Any? ?? NSNull(),
                     "tokenCut": $0.tokenCut as Any? ?? NSNull()] as [String: Any]
                },
                "regions": analysis.regions.map {
                    ["segmentId": $0.segmentID.uuidString, "sourceId": $0.sourceID.uuidString,
                     "start": $0.start, "end": $0.end, "audible": $0.audible] as [String: Any]
                },
                "acoustic": analysis.acoustics.description(from: 0, to: analysis.duration, includeWaveform: false),
                "waveform": ["step": analysis.acoustics.activity.frameDuration,
                    "levelDBFS": analysis.acoustics.activity.levels.map { $0.isFinite ? Int($0.rounded()) : -120 }] as [String: Any],
                "pauseGroups": analysis.pauseGroupDescription(from: 0, to: analysis.duration),
                "utterances": analysis.utterances.description(words: analysis.transcript.words, from: 0, to: analysis.duration),
                "repeatedPhrases": analysis.repetitions.description(words: analysis.transcript.words,
                    units: analysis.utterances.contexts.map(\.words), from: 0, to: analysis.duration),
                "subtitleAlignment": analysis.subtitleAlignment.description(raw: analysis.transcript.words),
            ]
            self.append(entry)
        }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func append(_ entry: Entry) {
        guard !failed else { return }
        do {
            try prepareFile()
            var row = Self.sanitized(entry.fields) as? [String: Any] ?? [:]
            // Long transcripts, HTML and history stay readable in separate,
            // content-addressed JSON files. Repeated payloads are written once.
            for key in ["parameters", "result", "request", "skill", "history", "messages", "analysis", "resolvedRanges", "evidence", "appliedRanges", "sourceSpans", "cutReview"] {
                guard let value = row[key] else { continue }
                let data = try Self.json(value)
                if data.count > 16_384 || key == "analysis" || key == "skill" {
                    row[key] = try payloadReference(data)
                }
            }
            if let project = entry.project {
                if lastProject != project || lastProjectReference == nil {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    let reference = try payloadReference(encoder.encode(project))
                    lastProject = project
                    lastProjectReference = reference
                }
                row["projectSnapshot"] = lastProjectReference
            }
            sequence += 1
            row["schemaVersion"] = 1
            row["sessionId"] = sessionID
            row["sequence"] = sequence
            row["timestamp"] = timestampFormatter.string(from: entry.date)
            row["event"] = entry.event
            var data = try Self.json(row)
            data.append(0x0A)
            try file?.write(contentsOf: data)
        } catch {
            // Diagnostic I/O never fails an edit or changes its result.
            failed = true
            try? file?.close()
            file = nil
            Self.logger.error("AI operation logging stopped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func prepareFile() throws {
        guard file == nil else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("payloads", isDirectory: true),
                               withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("events.jsonl")
        guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
    }

    private func payloadReference(_ data: Data) throws -> [String: Any] {
        let hash = Self.digest(data)
        let path = "payloads/\(hash).json"
        if !savedPayloads.contains(hash) {
            let url = directory.appendingPathComponent(path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            savedPayloads.insert(hash)
        }
        return ["$ref": path, "sha256": hash, "bytes": data.count]
    }

    private static func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value,
                                   options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    private static func sanitized(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.mapValuesWithKeys { key, value in
                let name = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if ["authorization", "apikey", "accesstoken", "refreshtoken", "clientsecret", "password"].contains(name) {
                    return "[redacted]"
                }
                return sanitized(value)
            }
        }
        if let array = value as? [Any] { return array.map(sanitized) }
        if let number = value as? NSNumber, !number.doubleValue.isFinite { return number.stringValue }
        return value
    }
}

private extension Dictionary where Key == String, Value == Any {
    func mapValuesWithKeys(_ transform: (String, Any) -> Any) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}
