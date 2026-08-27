import CoreMedia
import Foundation
import ScreenCaptureKit

/// Reads ScreenCaptureKit's Core Media attachment dictionary without bridging
/// the complete CFArray/CFDictionary pair into new Swift collections on every
/// captured frame.
enum ScreenCaptureFrameMetadata {
    private static let statusKey = SCStreamFrameInfo.status.rawValue

    static func status(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ),
            CFArrayGetCount(attachments) > 0,
            let rawDictionary = CFArrayGetValueAtIndex(attachments, 0)
        else { return nil }

        // ScreenCaptureKit documents each array item as a CFDictionary. Keep
        // the framework-owned object unretained and fetch only the status key;
        // `as? [[SCStreamFrameInfo: Any]]` materializes two Swift collections.
        let dictionary = Unmanaged<NSDictionary>
            .fromOpaque(rawDictionary)
            .takeUnretainedValue()
        guard let rawStatus = dictionary.object(forKey: statusKey) as? NSNumber else {
            return nil
        }
        return SCFrameStatus(rawValue: rawStatus.intValue)
    }
}
