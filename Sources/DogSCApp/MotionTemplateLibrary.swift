import Foundation

/// User-authored style packs. Browsing is read-only; placement creates a project asset.
enum MotionTemplateLibrary {
    static let folder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("DogSC/模板", isDirectory: true)

    static func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    static func file(_ path: String) throws -> URL {
        let url = folder.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
        guard contains(url), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        return url
    }

    // The AI edits cue timing and fields without round-tripping large audio payloads.
    // Replace the reference with the real samples before saving the standalone project copy.
    static func embedReferencedSamples(in html: String) throws -> String {
        guard let range = try MotionSoundScore.jsonRange(id: "dogsc-samples", in: html),
              html[range].contains("$template"),
              let reference = try JSONDecoder().decode([String: String].self, from: Data(html[range].utf8))["$template"]
        else { return html }
        let template = try String(contentsOf: file(reference), encoding: .utf8)
        guard let samples = try MotionSoundScore.jsonRange(id: "dogsc-samples", in: template) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return html.replacingCharacters(in: range, with: template[samples])
    }

    static func read(_ path: String?, includeSource: Bool) throws -> [String: Any] {
        let manager = FileManager.default
        let url = try path.flatMap { $0.isEmpty ? nil : try file($0) } ?? folder
        if url == folder && !manager.fileExists(atPath: url.path) { return ["entries": [], "templates": [], "styleGuides": []] }
        let isDirectory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if isDirectory {
            var result: [String: Any] = try listing(in: url, relativeTo: folder)
            result["styleGuides"] = styleGuides(in: url, relativeTo: folder)
            return result
        }
        guard url.lastPathComponent == "README.md" || HTMLMotion.isHTMLMotion(url.path) else { throw CocoaError(.fileReadInvalidFileName) }
        let content = try String(contentsOf: url, encoding: .utf8)
        if url.lastPathComponent == "README.md" { return ["guide": content] }
        var result: [String: Any] = ["path": path ?? "", "name": url.deletingPathExtension().lastPathComponent]
        result["styleGuides"] = styleGuides(in: url.deletingLastPathComponent(), relativeTo: folder)
        result["duration"] = HTMLMotion.declaredDuration(path: url.path)
        result["imageSlots"] = imageSlots(in: content)
        if let params = HTMLMotion.paramsJSON(in: content) {
            result["properties"] = try? JSONSerialization.jsonObject(with: Data(params.utf8))
        }
        if let slot = HTMLMotion.cameraSlot(in: content) {
            result["cameraSlot"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(slot))
        }
        let score = try MotionSoundScore.read(in: content)
        result["hasSoundtrack"] = score != nil
        if let score { result["soundCues"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(score.cues)) }
        if let range = try MotionSoundScore.jsonRange(id: "dogsc-sound-notes", in: content) {
            result["soundDesign"] = try? JSONDecoder().decode(String.self, from: Data(content[range].utf8))
        }
        if includeSource {
            var source = HTMLMotionPage.authoredPage(content)
            if let path, let range = try MotionSoundScore.jsonRange(id: "dogsc-samples", in: source) {
                let reference = try JSONEncoder().encode(["$template": path])
                source.replaceSubrange(range, with: String(decoding: reference, as: UTF8.self))
            }
            result["html"] = source
        }
        return result
    }

    /// Include the applicable author notes even when a client opens a nested template directly.
    static func styleGuides(in directory: URL, relativeTo root: URL) -> [[String: String]] {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        var current = directory.standardizedFileURL.resolvingSymlinksInPath()
        var guides: [[String: String]] = []
        while current.path == base.path || current.path.hasPrefix(base.path + "/") {
            let readme = current.appendingPathComponent("README.md")
            if let info = try? readme.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
               info.isRegularFile == true, info.isSymbolicLink != true,
               let markdown = try? String(contentsOf: readme, encoding: .utf8) {
                let path = readme.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")
                var guide = ["path": path]
                let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                    .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                let introduction = lines.drop(while: { $0.isEmpty || $0.hasPrefix("# ") })
                    .prefix(while: { !$0.isEmpty && !$0.hasPrefix("#") }).joined(separator: " ")
                if !introduction.isEmpty { guide["introduction"] = String(introduction.prefix(1200)) }
                guides.append(guide)
            }
            if current.path == base.path { break }
            current.deleteLastPathComponent()
        }
        return guides.reversed()
    }

    /// List every candidate without loading HTML or its embedded media.
    static func listing(in url: URL, relativeTo root: URL) throws -> [String: [String]] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey]
        var entries: [String] = []
        var templates: [String] = []
        var unreadable: [String] = []
        func collect(_ directory: URL, prefix: String) throws {
            let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys),
                                                           options: .skipsHiddenFiles)
            for child in children {
                let relativePath = prefix + child.lastPathComponent
                guard let values = try? child.resourceValues(forKeys: keys) else {
                    unreadable.append(relativePath)
                    continue
                }
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    if directory == url { entries.append(relativePath) }
                    do { try collect(child, prefix: relativePath + "/") } catch { unreadable.append(relativePath) }
                } else if values.isRegularFile == true {
                    let isTemplate = HTMLMotion.isHTMLMotion(child.path)
                    if isTemplate { templates.append(relativePath) }
                    if directory == url && (isTemplate || child.lastPathComponent == "README.md") {
                        entries.append(relativePath)
                    }
                }
            }
        }
        let subpath = url.resolvingSymlinksInPath().pathComponents
            .dropFirst(root.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
        try collect(url, prefix: subpath.isEmpty ? "" : subpath + "/")
        var listing = ["entries": entries.sorted(), "templates": templates.sorted()]
        if !unreadable.isEmpty { listing["unreadable"] = unreadable.sorted() }
        return listing
    }

    /// Read authored image elements without running scripts or loading their sources.
    /// Keys follow the same precedence as the element inspector's dogscKey.
    static func imageSlots(in html: String) -> [[String: String]] {
        guard html.range(of: "<img", options: .caseInsensitive) != nil,
              let document = try? XMLDocument(data: Data(("\u{FEFF}" + html).utf8),
                                              options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let nodes = try? document.nodes(forXPath: "//img[not(ancestor::template)]") else { return [] }
        return nodes.compactMap { node in
            guard let image = node as? XMLElement else { return nil }
            func attribute(_ name: String) -> String? {
                image.attribute(forName: name)?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let key = attribute("id").map({ "#" + $0 })
                    ?? attribute("data-param").map({ "param:" + $0 })
                    ?? attribute("data-name").map({ "name:" + $0 }) else { return nil }
            return ["key": key, "name": attribute("data-name") ?? attribute("alt") ?? key]
        }
    }
}
