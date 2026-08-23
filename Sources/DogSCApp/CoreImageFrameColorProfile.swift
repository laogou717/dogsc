import AVFoundation
import CoreImage
import CoreVideo
import Metal
import RecorderCore

enum FrameColorProfileError: LocalizedError {
    case unsupported(FrameColorContract)
    case unavailableColorSpace

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "当前版本只支持桌面 SDR 成片。"
        case .unavailableColorSpace:
            "系统无法建立 sRGB 色彩空间。"
        }
    }
}

/// One executable lowering of RecorderCore's color contract. Preview and
/// export must construct their Core Image contexts through this value instead
/// of falling back to a display-dependent RGB space.
struct CoreImageFrameColorProfile: @unchecked Sendable {
    let contract: FrameColorContract
    let workingColorSpace: CGColorSpace
    let outputColorSpace: CGColorSpace

    init(contract: FrameColorContract) throws {
        guard contract == .sdrDesktop else {
            throw FrameColorProfileError.unsupported(contract)
        }
        guard let working = CGColorSpace(name: CGColorSpace.linearSRGB),
              let output = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FrameColorProfileError.unavailableColorSpace
        }
        self.contract = contract
        workingColorSpace = working
        outputColorSpace = output
    }

    func makeContext(cacheIntermediates: Bool) -> CIContext {
        CIContext(options: [
            .cacheIntermediates: cacheIntermediates,
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: outputColorSpace,
        ])
    }

    /// PRE-001...PRE-006: the editor presents through a CAMetalLayer. Building
    /// the context against that exact device lets Core Image encode directly
    /// into the drawable instead of creating a CPU-backed CGImage every tick.
    func makeMetalContext(
        device: MTLDevice,
        cacheIntermediates: Bool
    ) -> CIContext {
        CIContext(mtlDevice: device, options: [
            .cacheIntermediates: cacheIntermediates,
            .workingColorSpace: workingColorSpace,
            .outputColorSpace: outputColorSpace,
        ])
    }

    var avVideoColorProperties: [String: String] {
        [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: kCVImageBufferTransferFunction_sRGB as String,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
    }

    func applyAttachments(to pixelBuffer: CVPixelBuffer) {
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_709_2,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_sRGB,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_709_2,
            .shouldPropagate
        )
    }
}
