import AppKit
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An authoring-time import. The renderer only reads the resulting project file.
enum RemoteImageDownload {
    struct Image: Sendable {
        let bytes: Data
        let suffix: String
        let digest: String
    }

    private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            let url = try? RemoteSoundDownloader.remoteURL(request.url?.absoluteString ?? "")
            completionHandler(url == nil ? nil : request)
        }
    }

    static func fetch(_ url: URL) async throws -> Image {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: HTTPSRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(from: url)
        let limit = 12 * 1024 * 1024
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RemoteSoundDownloader.Failure(message: "Image request failed. Use a direct HTTPS image URL.")
        }
        guard response.expectedContentLength <= Int64(limit) else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        for try await byte in stream {
            guard data.count < limit else { throw CocoaError(.fileReadTooLarge) }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try decoded(data)
    }

    static func decoded(_ data: Data) throws -> Image {
        let prefix = String(decoding: data.prefix(256), as: UTF8.self)
        if prefix.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))).first == "<" {
            let png = try rasterizedSVG(data)
            return Image(bytes: png, suffix: "png", digest: digest(data))
        }
        let types = [UTType.png.identifier: "png", UTType.jpeg.identifier: "jpg", UTType.webP.identifier: "webp"]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?, let suffix = types[type],
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 48_000_000 / height,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 32
              ] as CFDictionary) != nil else {
            throw RemoteSoundDownloader.Failure(message: "Choose a standalone SVG or a decodable PNG, JPEG or WebP image under 48 megapixels.")
        }
        return Image(bytes: data, suffix: suffix, digest: digest(data))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Rasterize self-contained vector artwork using the native image loader. A
    /// fixed pixel buffer also gives small favicon viewBoxes a usable editing size.
    private static func rasterizedSVG(_ data: Data) throws -> Data {
        let invalid = RemoteSoundDownloader.Failure(message: "Use a self-contained SVG logo or its PNG version.")
        guard data.count <= 2 * 1024 * 1024, let xml = String(data: data, encoding: .utf8),
              xml.range(of: "<!ENTITY", options: .caseInsensitive) == nil,
              let doc = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]),
              let root = doc.rootElement(), root.localName == "svg", root.uri == "http://www.w3.org/2000/svg",
              (try doc.nodes(forXPath: "//*[local-name()='image' or local-name()='script' or local-name()='foreignObject'] | //@*[local-name()='href' and not(starts-with(., '#'))]")).isEmpty,
              !xml.localizedCaseInsensitiveContains("@import"),
              xml.range(of: #"url\(\s*['"]?\s*[^#\s'"]"#, options: [.regularExpression, .caseInsensitive]) == nil,
              let image = NSImage(data: data), image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { throw invalid }
        let scale = 1024 / max(image.size.width, image.size.height)
        let size = CGSize(width: max(1, (image.size.width * scale).rounded()),
                          height: max(1, (image.size.height * scale).rounded()))
        var rect = CGRect(origin: .zero, size: size)
        guard let buffer = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                     bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let artwork = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw invalid }
        buffer.interpolationQuality = .high
        buffer.draw(artwork, in: CGRect(origin: .zero, size: size))
        guard let result = buffer.makeImage(),
              let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { throw invalid }
        return png
    }
}
