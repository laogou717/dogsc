import AVFoundation
import Foundation
import VideoToolbox

/// Owns the fixed writer canvas and the VideoToolbox transfer session needed
/// when a camera driver changes buffer dimensions during an active recording.
/// The writer therefore keeps one aspect-preserving contract for the whole file.
final class CameraSampleWriterFrameNormalizer {
    private var transferSession: VTPixelTransferSession?
    private var fitsSourceInsideCanvas = false
    private(set) var width: Int?
    private(set) var height: Int?
    private(set) var pixelFormat: OSType?

    deinit {
        reset()
    }

    func prepareContract(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        sourceWidth: Int,
        sourceHeight: Int,
        sourcePixelFormat: OSType,
        roleName: String,
        fitsSourceInsideCanvas: Bool = false
    ) throws {
        reset()
        self.fitsSourceInsideCanvas = fitsSourceInsideCanvas
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        if Self.needsNormalization(
            contractWidth: width,
            contractHeight: height,
            contractPixelFormat: pixelFormat,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            sourcePixelFormat: sourcePixelFormat
        ) {
            try prepareTransferSession(roleName: roleName)
        }
    }

    func needsNormalization(_ imageBuffer: CVPixelBuffer) -> Bool {
        guard let width, let height, let pixelFormat else { return false }
        return Self.needsNormalization(
            contractWidth: width,
            contractHeight: height,
            contractPixelFormat: pixelFormat,
            sourceWidth: CVPixelBufferGetWidth(imageBuffer),
            sourceHeight: CVPixelBufferGetHeight(imageBuffer),
            sourcePixelFormat: CVPixelBufferGetPixelFormatType(imageBuffer)
        )
    }

    static func needsNormalization(
        contractWidth: Int,
        contractHeight: Int,
        contractPixelFormat: OSType,
        sourceWidth: Int,
        sourceHeight: Int,
        sourcePixelFormat: OSType
    ) -> Bool {
        sourceWidth != contractWidth
            || sourceHeight != contractHeight
            || sourcePixelFormat != contractPixelFormat
    }

    func normalizedImageBuffer(
        _ imageBuffer: CVPixelBuffer,
        pool: CVPixelBufferPool?,
        roleName: String
    ) throws -> CVPixelBuffer {
        guard let width, let height else { return imageBuffer }
        guard needsNormalization(imageBuffer) else { return imageBuffer }

        try prepareTransferSession(roleName: roleName)
        guard let transferSession,
              let pool else {
            throw CameraRecorderError.recordingFailed(
                roleName,
                "摄像头画面规格转换缓冲池尚未准备"
            )
        }
        var destination: CVPixelBuffer?
        let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &destination
        )
        guard allocationStatus == kCVReturnSuccess, let destination else {
            throw CameraRecorderError.recordingFailed(
                roleName,
                String(format: appLocalized("无法申请摄像头等比裁切缓冲（%@）"), "\(allocationStatus)")
            )
        }
        CVBufferPropagateAttachments(imageBuffer, destination)
        let transferStatus = VTPixelTransferSessionTransferImage(
            transferSession,
            from: imageBuffer,
            to: destination
        )
        guard transferStatus == noErr else {
            throw CameraRecorderError.recordingFailed(
                roleName,
                String(format: appLocalized("无法把摄像头画面等比转换为 %@（%@）"), "\(width)x\(height)", "\(transferStatus)")
            )
        }
        return destination
    }

    func reset() {
        if let transferSession {
            VTPixelTransferSessionInvalidate(transferSession)
        }
        transferSession = nil
        width = nil
        height = nil
        pixelFormat = nil
    }

    private func prepareTransferSession(roleName: String) throws {
        guard transferSession == nil else { return }
        var createdSession: VTPixelTransferSession?
        let creationStatus = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &createdSession
        )
        guard creationStatus == noErr, let createdSession else {
            throw CameraRecorderError.recordingFailed(
                roleName,
                String(format: appLocalized("无法创建摄像头画面规格转换器（%@）"), "\(creationStatus)")
            )
        }
        let scalingStatus = VTSessionSetProperty(
            createdSession,
            key: kVTPixelTransferPropertyKey_ScalingMode,
            value: fitsSourceInsideCanvas ? kVTScalingMode_Letterbox : kVTScalingMode_Trim
        )
        let realtimeStatus = VTSessionSetProperty(
            createdSession,
            key: kVTPixelTransferPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard scalingStatus == noErr, realtimeStatus == noErr else {
            VTPixelTransferSessionInvalidate(createdSession)
            throw CameraRecorderError.recordingFailed(
                roleName,
                String(format: appLocalized("无法配置摄像头等比裁切（%@）"), "\(scalingStatus)/\(realtimeStatus)")
            )
        }
        transferSession = createdSession
    }
}
