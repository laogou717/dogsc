import AppKit
import AVFoundation
import Foundation
import RecorderCore
import SwiftUI

struct SystemWallpaperAsset: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case current
        case systemImage
        case screenSaverVideo
    }

    let id: String
    let name: String
    let url: URL
    let kind: Kind
    let familyName: String
    let variantName: String
    let variantColorRGB: UInt32?

    var isVideo: Bool {
        kind == .screenSaverVideo
            || SystemWallpaperLibrary.isVideoURL(url)
    }
}

struct SystemWallpaperGroup: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let assets: [SystemWallpaperAsset]
    let isCurrentDesktop: Bool

    var preferredAsset: SystemWallpaperAsset? { assets.first }
}

private struct CurrentDesktopResolution: Sendable {
    let url: URL
    let familyName: String
    let variantName: String
}

private struct StoredDesktopSelection: Sendable {
    let providerID: String
    let appearance: String?
    let filePaths: [String]
    let identifiers: [String]
}

fileprivate struct SystemWallpaperScanResult: Sendable {
    let assets: [SystemWallpaperAsset]
    let currentDesktopIssue: String?
    let changeToken: String
}

enum SystemWallpaperLibrary {
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    private static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "tif", "tiff", "webp",
    ]

    static func isVideoURL(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// Apple-managed wallpaper and screensaver files remain local references.
    /// A user-selected image elsewhere on disk can still be copied into the
    /// project, but system artwork must not silently become a redistributed
    /// project asset merely because it is the current desktop.
    static func isAppleManagedMediaURL(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/System/Library/Desktop Pictures/",
            "/System/Library/Screen Savers/",
            "/System/Library/ExtensionKit/Extensions/",
            "/Library/Application Support/com.apple.idleassetsd/",
            "\(home)/Library/Application Support/com.apple.idleassetsd/",
            "\(home)/Library/Application Support/com.apple.wallpaper/",
        ]
        return roots.contains { path.hasPrefix($0) }
    }

    /// NSWorkspace can return a `.madesktop` descriptor for an Apple dynamic
    /// desktop. The descriptor is data, not pixels; resolve its readable
    /// thumbnail rather than pretending the executable/screensaver surface is
    /// an image file. Installed MOV/MP4 assets are handled separately below.
    static func resolvedMediaURL(forDesktopImageURL url: URL) -> URL? {
        guard url.pathExtension.lowercased() == "madesktop" else {
            return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
        }
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any],
              let thumbnailPath = plist["thumbnailPath"] as? String else {
            return nil
        }
        let thumbnailURL = URL(fileURLWithPath: thumbnailPath)
        return FileManager.default.isReadableFile(atPath: thumbnailURL.path)
            ? thumbnailURL
            : nil
    }

    @MainActor
    static func currentBackgroundSource() -> BackgroundSource? {
        guard let mediaURL = resolveCurrentDesktop()?.url else { return nil }
        if isVideoURL(mediaURL) {
            return .systemVideo(absolutePath: mediaURL.path)
        }
        return .systemImage(absolutePath: mediaURL.path)
    }

    @MainActor
    private static func resolveCurrentDesktop() -> CurrentDesktopResolution? {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let workspaceURL = screen
            .flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
            .flatMap(resolvedMediaURL(forDesktopImageURL:))
        let storedSelection = storedDesktopSelection()

        // Since macOS moved newer wallpapers into ExtensionKit providers,
        // NSWorkspace may return DefaultDesktop.heic even while a completely
        // different provider is visibly active. Resolve the provider and its
        // selected appearance first; keep the public API as the fallback for
        // ordinary file-backed/custom wallpapers and older macOS releases.
        if let storedSelection,
           let storedURL = mediaURL(for: storedSelection) {
            let descriptor = wallpaperDescriptor(
                for: storedURL.deletingPathExtension().lastPathComponent,
                isVideo: isVideoURL(storedURL)
            )
            let providerName = providerDisplayName(
                providerID: storedSelection.providerID,
                fallback: descriptor.family
            )
            let variant = localizedAppearance(storedSelection.appearance)
                ?? descriptor.variant
            return CurrentDesktopResolution(
                url: storedURL,
                familyName: providerName,
                variantName: variant
            )
        }

        guard let workspaceURL,
              workspaceURL.path != "/System/Library/CoreServices/DefaultDesktop.heic"
                || storedSelection == nil else {
            return nil
        }
        let descriptor = wallpaperDescriptor(
            for: workspaceURL.deletingPathExtension().lastPathComponent,
            isVideo: isVideoURL(workspaceURL)
        )
        return CurrentDesktopResolution(
            url: workspaceURL,
            familyName: descriptor.family,
            variantName: descriptor.variant
        )
    }

    @MainActor
    fileprivate static func scan() async -> SystemWallpaperScanResult {
        let currentDesktop = resolveCurrentDesktop()
        return await Task.detached(priority: .utility) {
            scanOnWorker(currentDesktop: currentDesktop)
        }.value
    }

    private nonisolated static func scanOnWorker(
        currentDesktop: CurrentDesktopResolution?
    ) -> SystemWallpaperScanResult {
        let fileManager = FileManager.default
        var results: [SystemWallpaperAsset] = []
        var seen = Set<String>()
        let home = fileManager.homeDirectoryForCurrentUser
        let aerialNames: [String: String] = {
            let manifestURL = home.appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json"
            )
            guard let data = try? Data(contentsOf: manifestURL),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let assets = root["assets"] as? [[String: Any]] else { return [:] }
            return Dictionary(uniqueKeysWithValues: assets.compactMap { asset in
                guard let id = asset["id"] as? String else { return nil }
                let label = (asset["accessibilityLabel"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (id, label?.isEmpty == false ? label! : id)
            })
        }()

        func append(
            _ url: URL,
            kind: SystemWallpaperAsset.Kind,
            name: String? = nil,
            familyName: String? = nil,
            variantName: String? = nil
        ) {
            let normalized = url.standardizedFileURL.resolvingSymlinksInPath()
            guard fileManager.isReadableFile(atPath: normalized.path),
                  seen.insert("\(kind.rawValue):\(normalized.path)").inserted else { return }
            let stem = normalized.deletingPathExtension().lastPathComponent
            let fallbackLabel: String = if kind == .screenSaverVideo,
                                           UUID(uuidString: stem) != nil {
                "本机屏保 · \(stem.prefix(4))"
            } else {
                stem
            }
            let label = name ?? aerialNames[stem] ?? fallbackLabel
            let descriptor = wallpaperDescriptor(
                for: label,
                isVideo: kind == .screenSaverVideo || isVideoURL(normalized)
            )
            results.append(SystemWallpaperAsset(
                id: "\(kind.rawValue):\(normalized.path)",
                name: label,
                url: normalized,
                kind: kind,
                familyName: familyName ?? descriptor.family,
                variantName: variantName ?? descriptor.variant,
                variantColorRGB: variantColorRGB(for: variantName ?? descriptor.variant)
            ))
        }

        if let currentDesktop {
            append(
                currentDesktop.url,
                kind: .current,
                name: "当前桌面 · \(currentDesktop.familyName)",
                familyName: "当前桌面",
                variantName: "\(currentDesktop.familyName) · \(currentDesktop.variantName)"
            )
        }

        let imageRoots = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true),
        ]
        for root in imageRoots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                append(url, kind: .systemImage)
            }
        }

        // Hidden full-resolution wallpaper bundles and the newer ExtensionKit
        // providers are separate from the legacy root. Do not ingest
        // `.thumbnails` or files whose name says thumbnail: those are picker
        // posters (often only 214 px), not usable editor backgrounds.
        let providerResourceRoots = wallpaperProviderResourceRoots()
        let recursiveImageRoots = [
            URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers", isDirectory: true),
        ] + providerResourceRoots
        for root in recursiveImageRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                let path = url.path.lowercased()
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                guard imageExtensions.contains(url.pathExtension.lowercased()),
                      !path.contains("/.thumbnails/"),
                      !stem.contains("thumbnail") else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 128 * 1_024 else {
                    continue
                }
                append(url, kind: .systemImage)
            }
        }

        let videoRoots = [
            URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true),
            home.appendingPathComponent("Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos", isDirectory: true),
        ] + providerResourceRoots
        for root in videoRoots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            var accepted = 0
            for case let url as URL in enumerator {
                guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values?.isRegularFile == true, (values?.fileSize ?? 0) > 4_096 else { continue }
                append(url, kind: .screenSaverVideo)
                accepted += 1
                // Aerial libraries can contain several resolutions of the
                // same hundreds of scenes. Keep the inspector bounded; the
                // custom-file picker remains available for everything else.
                if accepted >= 120 { break }
            }
        }
        return SystemWallpaperScanResult(
            assets: results,
            currentDesktopIssue: currentDesktop == nil
                ? "当前桌面由系统壁纸扩展生成，暂时没有可安全导入的本地像素资源。"
                : nil,
            changeToken: scanChangeTokenOnWorker()
        )
    }

    private nonisolated static func storedDesktopSelection() -> StoredDesktopSelection? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let indexURL = home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
        )
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else { return nil }

        var content: [String: Any]?
        for key in ["AllSpacesAndDisplays", "SystemDefault"] {
            guard let container = root[key] as? [String: Any] else { continue }
            if let linked = container["Linked"] as? [String: Any],
               let linkedContent = linked["Content"] as? [String: Any] {
                content = linkedContent
                break
            }
        }
        if content == nil {
            content = firstWallpaperContent(in: root)
        }
        guard let content,
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              let providerID = choice["Provider"] as? String else { return nil }

        var strings: [String] = []
        collectStrings(from: choice["Files"], into: &strings)
        collectStrings(from: choice["Configuration"], into: &strings)
        var appearance: String?
        if let encoded = content["EncodedOptionValues"] as? Data,
           let decoded = try? PropertyListSerialization.propertyList(
               from: encoded,
               options: [],
               format: nil
           ) {
            collectStrings(from: decoded, into: &strings)
            appearance = nestedString(
                decoded,
                keys: ["values", "appearance", "picker", "_0", "id"]
            )
        }
        let filePaths = strings.compactMap { value -> String? in
            if value.hasPrefix("file://"), let url = URL(string: value) {
                return url.path
            }
            return value.hasPrefix("/") ? value : nil
        }
        return StoredDesktopSelection(
            providerID: providerID,
            appearance: appearance,
            filePaths: Array(Set(filePaths)).sorted(),
            identifiers: strings.filter { UUID(uuidString: $0) != nil }
        )
    }

    private nonisolated static func firstWallpaperContent(
        in value: Any
    ) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if dictionary["Choices"] is [[String: Any]] {
                return dictionary
            }
            for child in dictionary.values {
                if let found = firstWallpaperContent(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstWallpaperContent(in: child) { return found }
            }
        }
        return nil
    }

    private nonisolated static func mediaURL(
        for selection: StoredDesktopSelection
    ) -> URL? {
        let fileManager = FileManager.default
        for path in selection.filePaths {
            let candidate = URL(fileURLWithPath: path)
            if let resolved = resolvedMediaURL(forDesktopImageURL: candidate) {
                return resolved
            }
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let aerialRoot = home.appendingPathComponent(
            "Library/Application Support/com.apple.wallpaper/aerials/videos",
            isDirectory: true
        )
        for identifier in selection.identifiers {
            for ext in videoExtensions.sorted() {
                let candidate = aerialRoot.appendingPathComponent("\(identifier).\(ext)")
                if fileManager.isReadableFile(atPath: candidate.path) { return candidate }
            }
        }

        guard let bundleURL = wallpaperProviderBundleURL(
            providerID: selection.providerID
        ) else { return nil }
        let resourcesURL = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard let enumerator = fileManager.enumerator(
            at: resourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var images: [URL] = []
        var videos: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let stem = url.deletingPathExtension().lastPathComponent.lowercased()
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            if videoExtensions.contains(ext), (values?.fileSize ?? 0) > 4_096 {
                videos.append(url)
            } else if imageExtensions.contains(ext),
                      !stem.contains("thumbnail"),
                      (values?.fileSize ?? 0) > 128 * 1_024 {
                images.append(url)
            }
        }
        if let video = preferredResource(videos, appearance: selection.appearance) {
            return video
        }
        return preferredResource(images, appearance: selection.appearance)
    }

    private nonisolated static func wallpaperProviderBundleURL(
        providerID: String
    ) -> URL? {
        let root = URL(
            fileURLWithPath: "/System/Library/ExtensionKit/Extensions",
            isDirectory: true
        )
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return children.first { Bundle(url: $0)?.bundleIdentifier == providerID }
    }

    private nonisolated static func wallpaperProviderResourceRoots() -> [URL] {
        let root = URL(
            fileURLWithPath: "/System/Library/ExtensionKit/Extensions",
            isDirectory: true
        )
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { bundleURL in
            let bundleID = Bundle(url: bundleURL)?.bundleIdentifier?.lowercased() ?? ""
            let name = bundleURL.lastPathComponent.lowercased()
            guard bundleID.contains("wallpaper") || name.contains("wallpaper") else {
                return nil
            }
            return bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
    }

    private nonisolated static func preferredResource(
        _ resources: [URL],
        appearance: String?
    ) -> URL? {
        guard !resources.isEmpty else { return nil }
        let normalizedAppearance = appearance?.lowercased()
        if let normalizedAppearance,
           let exact = resources.first(where: {
               $0.deletingPathExtension().lastPathComponent.lowercased()
                   .contains(normalizedAppearance)
           }) {
            return exact
        }
        return resources.sorted { $0.path < $1.path }.first
    }

    private nonisolated static func providerDisplayName(
        providerID: String,
        fallback: String
    ) -> String {
        guard let bundleURL = wallpaperProviderBundleURL(providerID: providerID) else {
            return fallback
        }
        let manifestURL = bundleURL.appendingPathComponent(
            "Contents/Resources/manifest.json"
        )
        if let data = try? Data(contentsOf: manifestURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let identifier = root["identifier"] as? String,
           !identifier.isEmpty {
            return identifier
        }
        let displayName = Bundle(url: bundleURL)?
            .object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        return displayName?
            .replacingOccurrences(of: "Wallpaper", with: "")
            .replacingOccurrences(of: "Extension", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? fallback
    }

    private nonisolated static func nestedString(
        _ value: Any,
        keys: [String]
    ) -> String? {
        var current: Any = value
        for key in keys {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else { return nil }
            current = next
        }
        return current as? String
    }

    private nonisolated static func collectStrings(
        from value: Any?,
        into result: inout [String]
    ) {
        guard let value else { return }
        if let string = value as? String {
            result.append(string)
        } else if let data = value as? Data,
                  let decoded = try? PropertyListSerialization.propertyList(
                      from: data,
                      options: [],
                      format: nil
                  ) {
            collectStrings(from: decoded, into: &result)
        } else if let array = value as? [Any] {
            array.forEach { collectStrings(from: $0, into: &result) }
        } else if let dictionary = value as? [String: Any] {
            dictionary.values.forEach { collectStrings(from: $0, into: &result) }
        }
    }

    private nonisolated static func localizedAppearance(_ value: String?) -> String? {
        switch value?.lowercased() {
        case "dark": return "深色"
        case "light": return "浅色"
        case "dynamic": return "动态"
        case "automatic", "auto": return "自动"
        default: return nil
        }
    }

    private nonisolated static func wallpaperDescriptor(
        for rawName: String,
        isVideo: Bool
    ) -> (family: String, variant: String) {
        let spaced = rawName
            .replacingOccurrences(
                of: "([a-z])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: "i Mac", with: "iMac")
            .replacingOccurrences(of: "Mac Book", with: "MacBook")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixes: [(String, String)] = [
            ("Light Landscape", "浅色 · 横向"), ("Dark Landscape", "深色 · 横向"),
            ("Light Portrait", "浅色 · 纵向"), ("Dark Portrait", "深色 · 纵向"),
            ("Sky Blue", "天蓝"), ("Space Gray Pro", "深空灰 Pro"),
            ("Electric Blue", "电光蓝"), ("Rose Gold", "玫瑰金"),
            ("Light", "浅色"), ("Dark", "深色"), ("Silver", "银色"),
            ("Purple", "紫色"), ("Yellow", "黄色"), ("Orange", "橙色"),
            ("Magenta", "洋红"), ("Green", "绿色"), ("Blue", "蓝色"),
            ("Pink", "粉色"), ("Red", "红色"), ("Grey", "灰色"),
            ("Gray", "灰色"), ("Black", "黑色"), ("White", "白色"),
        ]
        for (suffix, localized) in suffixes where spaced.hasSuffix(" \(suffix)") {
            let family = String(spaced.dropLast(suffix.count + 1))
            return (family, localized)
        }
        return (spaced, isVideo ? "动态" : "默认")
    }

    nonisolated static func variantSortRank(_ variant: String) -> Int {
        let normalized = variant.lowercased()
        let order = [
            "自动", "动态", "蓝色", "天蓝", "浅色", "深色", "银色", "深空灰",
            "绿色", "黄色", "橙色", "粉色", "紫色", "红色", "黑色", "白色",
            "默认",
        ]
        return order.firstIndex(where: { normalized.contains($0) }) ?? order.count
    }

    private nonisolated static func variantColorRGB(for variant: String) -> UInt32? {
        let value = variant.lowercased()
        if value.contains("天蓝") { return 0x68_B7_EB }
        if value.contains("蓝") { return 0x4E_78_E8 }
        if value.contains("粉") { return 0xEA_81_AD }
        if value.contains("紫") { return 0x8B_6D_D5 }
        if value.contains("黄") || value.contains("金") { return 0xE5_BD_54 }
        if value.contains("橙") { return 0xE9_8C_55 }
        if value.contains("红") { return 0xD8_59_56 }
        if value.contains("绿") { return 0x65_AA_78 }
        if value.contains("银") || value.contains("浅色") { return 0xD7_D9_DA }
        if value.contains("灰") { return 0x70_73_78 }
        if value.contains("深色") || value.contains("黑") { return 0x2D_30_36 }
        return nil
    }

    private nonisolated static func scanChangeTokenOnWorker() -> String {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let urls = [
            home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist"),
            home.appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials/videos", isDirectory: true),
            home.appendingPathComponent("Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/ExtensionKit/Extensions", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Desktop Pictures", isDirectory: true),
            URL(fileURLWithPath: "/Library/Screen Savers", isDirectory: true),
            home.appendingPathComponent("Library/Screen Savers", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true),
        ]
        return urls.map { url in
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = attributes?[.size] as? NSNumber
            return "\(url.path):\(date):\(size?.int64Value ?? 0)"
        }.joined(separator: "|")
    }

    nonisolated static func changeToken() async -> String {
        await Task.detached(priority: .utility) { scanChangeTokenOnWorker() }.value
    }
}

@MainActor
final class SystemWallpaperCatalog: ObservableObject {
    @Published private(set) var assets: [SystemWallpaperAsset] = []
    @Published private(set) var isLoading = false
    @Published private(set) var currentDesktopIssue: String?
    private var didLoad = false
    private var lastChangeToken = ""

    var currentDesktopGroup: SystemWallpaperGroup? {
        let current = assets.filter { $0.kind == .current }
        guard !current.isEmpty else { return nil }
        return SystemWallpaperGroup(
            id: "current-desktop",
            name: "当前桌面",
            assets: current,
            isCurrentDesktop: true
        )
    }

    var imageGroups: [SystemWallpaperGroup] {
        groupedAssets(assets.filter { $0.kind == .systemImage })
    }

    var videoGroups: [SystemWallpaperGroup] {
        groupedAssets(assets.filter { $0.kind == .screenSaverVideo })
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        didLoad = true
        isLoading = true
        let result = await SystemWallpaperLibrary.scan()
        guard !Task.isCancelled else {
            isLoading = false
            return
        }
        assets = result.assets
        currentDesktopIssue = result.currentDesktopIssue
        lastChangeToken = result.changeToken
        isLoading = false
    }

    func monitorChanges() async {
        if !didLoad { await loadIfNeeded() }
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            let token = await SystemWallpaperLibrary.changeToken()
            guard !Task.isCancelled else { return }
            if token != lastChangeToken {
                await refresh()
            }
        }
    }

    private func groupedAssets(
        _ source: [SystemWallpaperAsset]
    ) -> [SystemWallpaperGroup] {
        Dictionary(grouping: source) { $0.familyName.localizedLowercase }
            .map { key, assets in
                let deduplicated = Dictionary(grouping: assets) {
                    $0.variantName.localizedLowercase
                }.compactMap { _, variants -> SystemWallpaperAsset? in
                    variants.max { lhs, rhs in
                        let lhsSize = ((try? lhs.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        let rhsSize = ((try? rhs.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                        return lhsSize < rhsSize
                    }
                }
                let sorted = deduplicated.sorted {
                    let leftRank = SystemWallpaperLibrary.variantSortRank($0.variantName)
                    let rightRank = SystemWallpaperLibrary.variantSortRank($1.variantName)
                    if leftRank != rightRank { return leftRank < rightRank }
                    if $0.variantName != $1.variantName {
                        return $0.variantName.localizedStandardCompare($1.variantName) == .orderedAscending
                    }
                    return $0.url.path < $1.url.path
                }
                return SystemWallpaperGroup(
                    id: "group:\(key)",
                    name: sorted.first?.familyName ?? key,
                    assets: sorted,
                    isCurrentDesktop: false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private actor SystemWallpaperThumbnailDecodeGate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        permits = max(limit, 1)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
enum SystemWallpaperThumbnailLoader {
    /// System HEIC files and Aerial videos can be 4K/6K. The picker only draws
    /// a roughly 92×54 point card, so keep one shared, bounded thumbnail cache
    /// and never decode a full still merely to populate the grid.
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 42
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    private static let gridAspectRatio: CGFloat = 92.0 / 54.0
    /// A wallpaper page can expose many local 4K movies at once. Allowing every
    /// visible tile to launch an AVAssetImageGenerator concurrently can starve
    /// the selected movie's first hardware decode. Two background generators
    /// keep scrolling responsive without competing with live playback.
    private static let videoDecodeGate = SystemWallpaperThumbnailDecodeGate(
        limit: 2
    )

    private static func cacheKey(for url: URL) -> NSString {
        url.standardizedFileURL.resolvingSymlinksInPath().path as NSString
    }

    static func cachedImage(at url: URL) -> NSImage? {
        cache.object(forKey: cacheKey(for: url))
    }

    static func image(for asset: SystemWallpaperAsset) async -> NSImage? {
        await image(at: asset.url, isVideo: asset.isVideo)
    }

    /// The selected tile and canvas preview share one path-keyed cache. A
    /// visible tile can therefore become an immediate poster for a 6K HEIC or
    /// 4K screensaver instead of making the canvas repeat the same decode.
    static func image(at url: URL, isVideo: Bool) async -> NSImage? {
        let key = cacheKey(for: url)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let decoded: NSImage?
        if !isVideo {
            decoded = await WallpaperThumbnailLoader.image(
                at: url,
                maximumPixelSize: 360,
                aspectRatio: gridAspectRatio
            )
        } else {
            await videoDecodeGate.acquire()
            if Task.isCancelled {
                await videoDecodeGate.release()
                return nil
            }
            let avAsset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: avAsset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 360, height: 220)
            do {
                let result = try await generator.image(at: .zero)
                decoded = Task.isCancelled
                    ? nil
                    : NSImage(cgImage: result.image, size: .zero)
            } catch {
                decoded = nil
            }
            await videoDecodeGate.release()
        }

        guard let decoded, !Task.isCancelled else { return nil }
        cache.setObject(
            decoded,
            forKey: key,
            cost: WallpaperThumbnailDecoder.decodedByteCost(of: decoded)
        )
        return decoded
    }
}

struct SystemWallpaperThumbnail: View {
    let asset: SystemWallpaperAsset
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.10)
                    Image(systemName: asset.isVideo ? "film.fill" : "photo.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipped()
        .task(id: asset.id) {
            image = nil
            image = await SystemWallpaperThumbnailLoader.image(for: asset)
        }
    }
}
