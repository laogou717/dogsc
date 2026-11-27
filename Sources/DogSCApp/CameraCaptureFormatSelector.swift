import RecorderCore

enum CameraCaptureFormatSelector {
    /// For a webcam, keep the source orientation when choosing a quality tier.
    /// Wired iOS screen capture continues to select its highest resolution.
    static func preferredFormatIndex(
        dimensions: [(width: Int, height: Int)],
        sourceIsLandscape: Bool?,
        requestedQuality: CameraCaptureResolution? = nil
    ) -> Int? {
        let valid = dimensions.enumerated().filter {
            $0.element.width > 0 && $0.element.height > 0
        }
        guard !valid.isEmpty else { return nil }

        func highestPixels(
            in candidates: [(offset: Int, element: (width: Int, height: Int))]
        ) -> Int {
            candidates.max {
                $0.element.width * $0.element.height
                    < $1.element.width * $1.element.height
            }!.offset
        }

        guard let sourceIsLandscape else { return highestPixels(in: valid) }
        let matching = valid.filter { ($0.element.width >= $0.element.height) == sourceIsLandscape }
        let candidates = matching.isEmpty ? valid : matching
        if let quality = requestedQuality?.qualitySize,
           let exact = candidates.first(where: {
               max($0.element.width, $0.element.height) == quality.width
                   && min($0.element.width, $0.element.height) == quality.height
           }) { return exact.offset }

        // A quality tier available only in the other orientation may be selected
        // from an older preference or before turning the camera.
        let pixelLimit = requestedQuality.map { $0.width * $0.height } ?? Int(1920.0 * 1080 * 1.05)
        let withinCap = candidates.filter { $0.element.width * $0.element.height <= pixelLimit }
        if !withinCap.isEmpty { return highestPixels(in: withinCap) }
        return candidates.min {
            $0.element.width * $0.element.height < $1.element.width * $1.element.height
        }?.offset
    }
}
