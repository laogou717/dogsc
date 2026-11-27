import RecorderCore

/// Search and ordering depend on the catalog, not hover, selection or scroll.
@MainActor
final class EditorMediaPresentationCache {
    private struct Input: Equatable {
        let project: [MediaAsset]
        let library: [AssetLibrary.Entry]
        let scope: String
        let filter: String
        let query: String
    }
    private var input: Input?
    private var result: [MediaAsset] = []

    func assets(project: [MediaAsset], library: [AssetLibrary.Entry], scope: String,
                filter: String, query: String) -> [MediaAsset] {
        let next = Input(project: project, library: library, scope: scope, filter: filter,
            query: query.trimmingCharacters(in: .whitespaces))
        if next == input { return result }
        input = next
        let source = scope == "project" ? project : library.filter(\.favorite).map { MediaAsset(id: $0.id, path: $0.path, kind: $0.kind, name: $0.name, importedAt: $0.addedAt) }
        result = filter == "recording" ? [] : source.filter {
            (MediaAssetKind(rawValue: filter) == nil || $0.kind.rawValue == filter)
                && (next.query.isEmpty || $0.name.localizedCaseInsensitiveContains(next.query))
        }.sorted { $0.importedAt == $1.importedAt ? $0.id.uuidString < $1.id.uuidString : $0.importedAt > $1.importedAt }
        return result
    }
}
