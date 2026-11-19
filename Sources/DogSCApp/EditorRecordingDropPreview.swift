import RecorderCore
import SwiftUI

/// Hover uses only metadata already owned by this process. External files
/// are inspected after the user releases them, when payload access is valid.
@MainActor
final class EditorRecordingDropPreview: ObservableObject {
    struct Item: Equatable {
        let name: String
        let duration: TimeInterval?
        var label: String {
            duration.map { name + " · " + RecordingSourcePresentation.duration($0) } ?? name
        }
    }
    @Published private(set) var item: Item?
    func end() { item = nil }

    func begin(item value: EditorMediaDrag.Item?, project: RecorderProject,
               durations: [UUID: TimeInterval]) {
        end()
        guard let value else { return }
        switch value {
        case let .recording(id):
            guard project.source(id) != nil else { return }
            item = Item(name: RecordingSourcePresentation.name(id, in: project), duration: durations[id])
        case let .asset(id):
            if let asset = project.timeline.mediaAssets.first(where: { $0.id == id }) {
                item = Item(name: asset.name, duration: nil)
            }
        case let .library(path):
            item = Item(name: URL(fileURLWithPath: path).lastPathComponent, duration: nil)
        case let .file(url):
            item = Item(name: url.deletingPathExtension().lastPathComponent, duration: nil)
        }
    }
}
