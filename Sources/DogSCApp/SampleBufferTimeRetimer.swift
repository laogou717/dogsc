import CoreMedia

/// Re-bases Core Media samples onto the recording timeline while keeping the
/// overwhelmingly common one-timing-entry path on the stack. Screen frames
/// and normal PCM/AAC buffers expose one timing entry even when an audio
/// buffer contains many samples; allocating a Swift array for every callback
/// is therefore unnecessary.
enum SampleBufferTimeRetimer {
    static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset.isNumeric, offset > .zero else { return sampleBuffer }

        var entryCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else { return sampleBuffer }

        if entryCount == 1 {
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            )
            guard CMSampleBufferGetSampleTimingInfo(
                sampleBuffer,
                at: 0,
                timingInfoOut: &timing
            ) == noErr else { return nil }
            adjust(&timing, subtracting: offset)
            return copiedBuffer(
                sampleBuffer,
                entryCount: 1,
                timing: &timing
            )
        }

        var timing = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: entryCount
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: entryCount,
            arrayToFill: &timing,
            entriesNeededOut: &entryCount
        ) == noErr else { return nil }
        for index in timing.indices {
            adjust(&timing[index], subtracting: offset)
        }
        return timing.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return nil }
            return copiedBuffer(
                sampleBuffer,
                entryCount: entryCount,
                timing: baseAddress
            )
        }
    }

    private static func adjust(
        _ timing: inout CMSampleTimingInfo,
        subtracting offset: CMTime
    ) {
        if timing.presentationTimeStamp.isValid {
            timing.presentationTimeStamp = timing.presentationTimeStamp - offset
        }
        if timing.decodeTimeStamp.isValid {
            timing.decodeTimeStamp = timing.decodeTimeStamp - offset
        }
    }

    private static func copiedBuffer(
        _ sampleBuffer: CMSampleBuffer,
        entryCount: Int,
        timing: UnsafePointer<CMSampleTimingInfo>
    ) -> CMSampleBuffer? {
        var adjusted: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: timing,
            sampleBufferOut: &adjusted
        ) == noErr else { return nil }
        return adjusted
    }
}
