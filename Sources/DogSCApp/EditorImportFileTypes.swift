import AppKit
import UniformTypeIdentifiers

enum EditorImportFileTypes {
    // UTType(filenameExtension:) defaults to conformance to public.data.
    // DogSC projects conform to com.apple.package, so use their declared type.
    static let recordingProject = UTType(exportedAs: "cn.laogou.dogsc-project", conformingTo: .package)

    @MainActor static func configure(_ panel: NSOpenPanel, extensions: [String]) {
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = extensions.compactMap { ext in
            ext == "dogscproject" || ext == "silkyproject"
                ? recordingProject : UTType(filenameExtension: ext)
        }
    }
}

/// Shared entry point for project/media imports.
@MainActor
enum EditorImportFilePicker {
    static func choose(directory: URL?, extensions: [String], completion: @escaping @MainActor ([URL]) -> Void) {
        AppFilePanel.open(configure: { panel in
            panel.directoryURL = directory
            panel.allowsMultipleSelection = true
            EditorImportFileTypes.configure(panel, extensions: extensions)
        }) { urls in
            if let urls { completion(urls) }
        }
    }
}
