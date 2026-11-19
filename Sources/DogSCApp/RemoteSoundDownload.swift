import AVFoundation
import CryptoKit
import Foundation

/// Network work stays outside the editor actor. Files become library assets
/// only after a complete, decodable download; playback never streams them.
struct RemoteSoundDownloader: Sendable {
    static let shared = RemoteSoundDownloader()
    let fetch: @Sendable (URLRequest) async throws -> (URL, URLResponse)

    init(session: URLSession = .shared) {
        fetch = { try await session.download(for: $0) }
    }

    init(fetch: @escaping @Sendable (URLRequest) async throws -> (URL, URLResponse)) {
        self.fetch = fetch
    }

    struct Download: Sendable {
        let file: URL
        let duration: Double
        let source: AssetLibrary.RemoteSource
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func remoteURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else {
            throw Failure(message: "Use an absolute HTTPS URL without embedded credentials.")
        }
        return url
    }

    static func isCC0(_ raw: String) -> Bool {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              ["creativecommons.org", "www.creativecommons.org"].contains(url.host?.lowercased() ?? "") else { return false }
        return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "publicdomain/zero/1.0"
    }

    private func request(_ url: URL, timeout: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("DogSC/1.0 (CC0 sound download)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Failure(message: "The sound server returned no HTTP response.") }
        if http.statusCode == 429 {
            let retry = http.value(forHTTPHeaderField: "Retry-After").map { " Retry-After: \($0)." } ?? " Try again later."
            throw Failure(message: "Sound service rate limit reached.\(retry)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure(message: "Sound request failed (HTTP \(http.statusCode)). Choose another result or try later.")
        }
        return http
    }

    func download(url: String, sourceURL: String, licenseURL: String) async throws -> Download {
        guard Self.isCC0(licenseURL) else { throw Failure(message: "Only CC0 1.0 sounds are supported; provide the verified CC0 license URL.") }
        let remote = try Self.remoteURL(url)
        _ = try Self.remoteURL(sourceURL)
        let (temporary, response) = try await fetch(request(remote, timeout: 90))
        defer { try? FileManager.default.removeItem(at: temporary) }
        let http = try checked(response)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 64 * 1_024 * 1_024 else { throw Failure(message: "Choose a sound file smaller than 64 MB.") }
        let suffixes = [response.suggestedFilename.map { URL(fileURLWithPath: $0).pathExtension.lowercased() },
                        remote.pathExtension.lowercased(), Self.audioExtension(http.mimeType)].compactMap { $0 }
        guard let suffix = suffixes.first(where: { ["mp3", "m4a", "wav", "aiff", "aif", "aac", "caf", "flac"].contains($0) }) else {
            throw Failure(message: "Download a direct MP3, WAV, M4A, AIFF, AAC, CAF or FLAC file, not a page or ZIP.")
        }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("dogsc-sound-\(UUID()).\(suffix)")
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: staged) } }
        try FileManager.default.moveItem(at: temporary, to: staged)
        let asset = AVURLAsset(url: staged)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let playable = try await asset.load(.isPlayable)
        guard duration.isFinite, duration > 0, !tracks.isEmpty, playable else { throw Failure(message: "The downloaded file contains no playable audio.") }
        let file = try FileHandle(forReadingFrom: staged)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        try Task.checkCancellation()
        keep = true
        return Download(file: staged, duration: duration,
            source: .init(url: url, pageURL: sourceURL, licenseURL: licenseURL, sha256: digest))
    }

    private static func audioExtension(_ mime: String?) -> String? {
        switch mime {
        case "audio/mpeg": "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/mp4", "audio/x-m4a": "m4a"
        case "audio/aac": "aac"
        case "audio/aiff", "audio/x-aiff": "aiff"
        case "audio/flac", "audio/x-flac": "flac"
        default: nil
        }
    }
}
