import CoreMedia
import AudioToolbox
import Foundation

/// Re-bases Core Media samples onto the recording timeline while keeping the
/// overwhelmingly common one-timing-entry path on the stack. Screen frames
/// and normal PCM/AAC buffers expose one timing entry even when an audio
/// buffer contains many samples; allocating a Swift array for every callback
/// is therefore unnecessary.
enum SampleBufferTimeRetimer {
    static func audioPauseOffset(
        _ seconds: TimeInterval,
        format: CMFormatDescription?
    ) -> CMTime {
        let rate = format.flatMap(CMAudioFormatDescriptionGetStreamBasicDescription)?
            .pointee.mSampleRate ?? 0
        let timescale = rate.isFinite && rate >= 1 && rate <= Double(Int32.max)
            ? Int32(rate.rounded()) : 1_000_000_000
        return CMTimeConvertScale(
            CMTime(seconds: seconds, preferredTimescale: 1_000_000_000),
            timescale: timescale, method: .roundHalfAwayFromZero
        )
    }

    /// AAC encoders can compact a hole between PCM appends even when their
    /// timestamps describe it. Fill a shared resume boundary once, preserving
    /// actual sample positions instead of moving all later sound forward.
    static func audioResumeSample(
        matching sampleBuffer: CMSampleBuffer,
        from start: CMTime,
        to end: CMTime
    ) throws -> CMSampleBuffer? {
        guard end > start,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mSampleRate.isFinite, asbd.mSampleRate >= 1,
              asbd.mSampleRate <= Double(Int32.max) else { return nil }
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBytesPerFrame > 0,
              asbd.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger) != 0
        else { throw NSError(domain: NSOSStatusErrorDomain, code: -50) }
        let gap = CMTimeConvertScale(
            end - start, timescale: Int32(asbd.mSampleRate.rounded()), method: .roundHalfAwayFromZero
        )
        guard gap.isNumeric, gap.value > 0 else { return nil }
        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? Int(asbd.mChannelsPerFrame) : 1
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let (totalFrames, frameOverflow) = Int(gap.value).addingReportingOverflow(frames)
        let (bytes, overflow) = totalFrames.multipliedReportingOverflow(
            by: Int(asbd.mBytesPerFrame) * planes
        )
        guard !frameOverflow, !overflow, bytes > 0 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        }
        var block: CMBlockBuffer?
        var result = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        )
        guard result == noErr, let block else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
        }
        result = CMBlockBufferFillDataBytes(
            with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes
        )
        guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        // Keep padding and the real sample in one append. If the writer is
        // back-pressured, a retry cannot accidentally append the padding twice.
        var listSize = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil,
            bufferListSize: 0, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: nil
        )
        guard listSize >= MemoryLayout<AudioBufferList>.size else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: listSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        var retainedBlock: CMBlockBuffer?
        result = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list,
            bufferListSize: listSize, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, blockBufferOut: &retainedBlock
        )
        guard result == noErr, Int(list.pointee.mNumberBuffers) == planes else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result == noErr ? -50 : result))
        }
        let planeBytes = frames * Int(asbd.mBytesPerFrame)
        let gapBytes = Int(gap.value) * Int(asbd.mBytesPerFrame)
        for (index, source) in UnsafeMutableAudioBufferListPointer(list).enumerated() {
            guard let data = source.mData, Int(source.mDataByteSize) >= planeBytes else {
                throw NSError(domain: NSOSStatusErrorDomain, code: -50)
            }
            result = CMBlockBufferReplaceDataBytes(
                with: data, blockBuffer: block,
                offsetIntoDestination: index * (planeBytes + gapBytes) + gapBytes,
                dataLength: planeBytes
            )
            guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        }
        var padded: CMSampleBuffer?
        result = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: totalFrames, presentationTimeStamp: start,
            packetDescriptions: nil, sampleBufferOut: &padded
        )
        guard result == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(result)) }
        return padded
    }

    static func retimed(
        _ sampleBuffer: CMSampleBuffer,
        subtracting offset: CMTime
    ) -> CMSampleBuffer? {
        guard offset.isNumeric, offset > .zero else { return sampleBuffer }
        return shiftedCopy(sampleBuffer, subtracting: offset)
    }

    /// Convert samples from an AVCaptureSession master clock to the fixed
    /// presentation clock used by a separate video writer.
    static func retimed(_ sampleBuffer: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer? {
        let sourceTime = sampleBuffer.presentationTimeStamp
        guard sourceTime.isNumeric, presentationTime.isNumeric else { return nil }
        return shiftedCopy(sampleBuffer, subtracting: sourceTime - presentationTime)
    }

    private static func shiftedCopy(_ sampleBuffer: CMSampleBuffer, subtracting offset: CMTime) -> CMSampleBuffer? {

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
