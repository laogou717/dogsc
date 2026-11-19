import AppKit
import RecorderCore
import SwiftUI
import UniformTypeIdentifiers
import os

/// Internal drags carry data, not text/URLs inferred from a string prefix.
/// Both timeline destinations and the canvas read this same representation.
enum EditorMediaDrag {
    static let mediaType = UTType(exportedAs: "cn.laogou.dogsc.media-drag", conformingTo: .data)
    static let recordingType = UTType(exportedAs: "cn.laogou.dogsc.recording-drag", conformingTo: .data)
    static let types: [UTType] = [mediaType, recordingType, .fileURL]
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "media-drag")
    @MainActor private static weak var localProvider: NSItemProvider?
    @MainActor private static var localItem: Item?

    enum Item: Codable, Sendable {
        case asset(UUID)
        case library(String)
        case recording(UUID)
        case file(URL)
    }

    @MainActor static func provider(for item: Item) -> NSItemProvider {
        let type = if case .recording = item { recordingType } else { mediaType }
        let provider = NSItemProvider()
        let data = try! JSONEncoder().encode(item)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        localProvider = provider
        localItem = item
        logger.notice("media drag began type=\(type.identifier, privacy: .public)")
        return provider
    }

    /// Hover may inspect our own in-memory drag, never the system payload.
    /// DropInfo.itemProviders is only valid inside performDrop.
    @MainActor static func previewItem(for info: DropInfo) -> Item? {
        guard localProvider != nil, let item = localItem else { return nil }
        let type = if case .recording = item { recordingType } else { mediaType }
        return info.hasItemsConforming(to: [type]) ? item : nil
    }

    @MainActor static func endLocalDrag() {
        localProvider = nil
        localItem = nil
    }

    @discardableResult
    static func read(_ providers: [NSItemProvider], onFailure: @escaping @MainActor () -> Void = {},
                     receive: @escaping @MainActor (Item) -> Void) -> Bool {
        readAll(providers, onFailure: onFailure) { items in
            if let first = items.first { receive(first) }
        }
    }

    /// Start every load synchronously in the drop callback. Completion order
    /// must not turn a multi-file gesture into separate import dialogs.
    @discardableResult
    static func readAll(_ providers: [NSItemProvider], onFailure: @escaping @MainActor () -> Void = {},
                        receive: @escaping @MainActor ([Item]) -> Void) -> Bool {
        for type in [mediaType, recordingType] {
            if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(type.identifier) }) {
                provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                    guard let data, let item = try? JSONDecoder().decode(Item.self, from: data) else {
                        logger.error("media drop data unavailable: \(String(describing: error), privacy: .public)")
                        Task { @MainActor in onFailure() }
                        return
                    }
                    Task { @MainActor in receive([item]) }
                }
                return true
            }
        }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        let batch = FileDropBatch(count: files.count, onFailure: onFailure, receive: receive)
        for (index, provider) in files.enumerated() {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else {
                    logger.error("file drop URL unavailable: \(String(describing: error), privacy: .public)")
                    batch.complete(index: index, item: nil)
                    return
                }
                batch.complete(index: index, item: .file(url))
            }
        }
        return true
    }

    private final class FileDropBatch: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        private var items: [Item?]
        private let onFailure: @MainActor () -> Void
        private let receive: @MainActor ([Item]) -> Void

        init(count: Int, onFailure: @escaping @MainActor () -> Void,
             receive: @escaping @MainActor ([Item]) -> Void) {
            remaining = count
            items = Array(repeating: nil, count: count)
            self.onFailure = onFailure
            self.receive = receive
        }

        func complete(index: Int, item: Item?) {
            lock.lock()
            items[index] = item
            remaining -= 1
            let finished = remaining == 0
            let result = finished ? items.compactMap { $0 } : []
            let succeeded = finished && result.count == items.count
            lock.unlock()
            guard finished else { return }
            Task { @MainActor [receive, onFailure] in
                if succeeded { receive(result) } else { onFailure() }
            }
        }
    }

    @MainActor
    static func asset(for item: Item, in store: EditorStore) -> MediaAsset? {
        switch item {
        case let .asset(id): return store.project.timeline.mediaAssets.first { $0.id == id }
        case let .library(path): return store.importMediaAssets([URL(fileURLWithPath: path)]).first
        case let .file(url): return store.importMediaAssets([url]).first
        case .recording: return nil
        }
    }
}

/// A single destination covers the whole timeline document. Child clip hit
/// regions and empty rows cannot swallow drops intended for another track.
struct TimelineMediaDropDelegate: DropDelegate {
    private static let logger = Logger(subsystem: "cn.laogou.dogsc", category: "media-drag")
    let inspect: (EditorMediaDrag.Item?) -> Void
    let update: (CGPoint, Bool) -> Bool
    let exit: () -> Void
    let prepare: (CGPoint) -> (@MainActor ([EditorMediaDrag.Item]) -> Void)?
    let failed: @MainActor () -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: EditorMediaDrag.types) }
    func dropEntered(info: DropInfo) {
        Self.logger.notice("media drag entered timeline")
        inspect(EditorMediaDrag.previewItem(for: info))
        _ = update(info.location, offersOverlay(info))
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: update(info.location, offersOverlay(info)) ? .copy : .cancel)
    }
    func dropExited(info: DropInfo) { exit() }
    func performDrop(info: DropInfo) -> Bool {
        // Resolve the row before dismissing the temporary empty overlay row.
        let action = prepare(info.location)
        Self.logger.notice("timeline media drop destination=\(action == nil ? "unavailable" : "accepted", privacy: .public)")
        defer { exit(); EditorMediaDrag.endLocalDrag() }
        guard let action else { return false }
        return EditorMediaDrag.readAll(info.itemProviders(for: EditorMediaDrag.types), onFailure: failed, receive: action)
    }
    private func offersOverlay(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [EditorMediaDrag.mediaType, .fileURL])
    }
}
