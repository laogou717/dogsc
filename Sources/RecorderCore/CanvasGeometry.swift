import Foundation

public extension CanvasStyle {
    /// The source aspect is measured after the authored crop. Preview and export
    /// share this calculation so adaptive margins remain equal at every size.
    func resolvedAspectRatio(sourceAspectRatio: Double) -> Double {
        if let fixed = resolvedFixedAspectRatio { return fixed }
        let size = adaptiveSize(width: max(sourceAspectRatio, 0.01), height: 1)
        return size.width / size.height
    }

    private func adaptiveSize(width: Double, height: Double) -> (width: Double, height: Double) {
        let fractions = paddingInsets.scaled(
            by: 1 / CanvasPadding.referenceShortEdge,
            maximum: CanvasPadding.maximumFraction
        )
        let horizontal = fractions.left + fractions.right
        let vertical = fractions.top + fractions.bottom
        // Either dimension can become the short edge with asymmetric margins.
        // Solve both candidates, then select the smaller final canvas edge.
        let shortEdge = min(width / (1 - horizontal), height / (1 - vertical))
        return (width + horizontal * shortEdge, height + vertical * shortEdge)
    }

    func pixelDimensions(
        resolution: CanvasResolution,
        sourceAspectRatio: Double? = nil,
        sourcePixelSize: CanvasDimensions? = nil
    ) -> CanvasDimensions {
        if resolution == .source {
            return sourcePixelDimensions(sourcePixelSize)
        }
        guard let preset = resolution.presetEdges else {
            return sourcePixelDimensions(sourcePixelSize)
        }
        let shortEdge = preset.short
        switch aspectRatio {
        case .adaptive:
            let source = sourcePixelSize ?? CanvasDimensions(width: 1_920, height: 1_080)
            let crop = crop.clamped()
            let croppedAspect = sourceAspectRatio
                ?? (Double(source.width) * crop.width / (Double(source.height) * crop.height))
            let ratio = resolvedAspectRatio(sourceAspectRatio: croppedAspect)
            let longEdge = preset.long
            if ratio >= 1 {
                return CanvasDimensions(
                    width: even(longEdge),
                    height: even(Double(longEdge) / ratio)
                )
            }
            return CanvasDimensions(
                width: even(Double(longEdge) * ratio),
                height: even(longEdge)
            )
        case .landscape:
            return CanvasDimensions(width: shortEdge * 16 / 9, height: shortEdge)
        case .standard:
            return CanvasDimensions(width: shortEdge * 4 / 3, height: shortEdge)
        case .portrait:
            return CanvasDimensions(width: shortEdge, height: shortEdge * 16 / 9)
        case .square:
            return CanvasDimensions(width: shortEdge, height: shortEdge)
        case .standardPortrait:
            return CanvasDimensions(width: shortEdge, height: shortEdge * 4 / 3)
        case .cinema, .cinemaPortrait, .custom:
            let ratio = resolvedFixedAspectRatio ?? 1
            let long = Double(preset.long)
            return ratio >= 1
                ? CanvasDimensions(width: even(long), height: even(long / ratio))
                : CanvasDimensions(width: even(long * ratio), height: even(long))
        }
    }

    /// Adaptive canvases surround the native cropped pixels with equal margins.
    /// Fixed ratios continue to fit inside the cropped pixel envelope.
    private func sourcePixelDimensions(
        _ sourcePixelSize: CanvasDimensions?
    ) -> CanvasDimensions {
        let source = sourcePixelSize ?? CanvasDimensions(width: 1_920, height: 1_080)
        let crop = crop.clamped()
        let croppedWidth = max(Double(source.width) * crop.width, 2)
        let croppedHeight = max(Double(source.height) * crop.height, 2)

        guard aspectRatio != .adaptive else {
            let size = adaptiveSize(width: croppedWidth, height: croppedHeight)
            return CanvasDimensions(width: even(size.width), height: even(size.height))
        }

        let targetRatio = resolvedFixedAspectRatio ?? croppedWidth / croppedHeight
        if croppedWidth / croppedHeight >= targetRatio {
            return CanvasDimensions(
                width: even(croppedHeight * targetRatio),
                height: even(croppedHeight)
            )
        }
        return CanvasDimensions(
            width: even(croppedWidth),
            height: even(croppedWidth / targetRatio)
        )
    }

    private func even(_ value: Double) -> Int {
        max(Int((value / 2).rounded()) * 2, 2)
    }

    private func even(_ value: Int) -> Int {
        max(value - value % 2, 2)
    }
}

extension CanvasResolution {
    fileprivate var presetEdges: (short: Int, long: Int)? {
        switch self {
        case .source: return nil
        case .fullHD: return (1_080, 1_920)
        case .quadHD: return (1_440, 2_560)
        case .ultraHD: return (2_160, 3_840)
        }
    }
}
