import Foundation

enum CameraCaptureFormatSelector {
    /// 摄像头的 PIP 显示不需要盲目上 4K：横屏格式优先选择
    /// 1080p 档以内的最高像素；如果没有该档位，再退回最高像素横屏。
    /// 手机屏幕或只有竖屏格式的设备则保持它们的原始方向。
    static func preferredFormatIndex(
        dimensions: [(width: Int, height: Int)],
        prefersLandscape: Bool
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

        guard prefersLandscape else { return highestPixels(in: valid) }
        let landscape = valid.filter { $0.element.width >= $0.element.height }
        guard !landscape.isEmpty else { return highestPixels(in: valid) }
        let fullHDPixels = 1920 * 1080
        let withinCap = landscape.filter {
            $0.element.width * $0.element.height <= Int(Double(fullHDPixels) * 1.05)
        }
        return highestPixels(in: withinCap.isEmpty ? landscape : withinCap)
    }
}
