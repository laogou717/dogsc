import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import RecorderCore

enum CoreAudioSystemAudioTapError: LocalizedError {
    case unavailable
    case selectedApplicationUnavailable(String)
    case coreAudio(operation: String, status: OSStatus)
    case invalidFormat
    case invalidInputBuffer

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Core Audio 系统声音捕获需要 macOS 14.2 或更高版本"
        case let .selectedApplicationUnavailable(bundleIdentifier):
            return "Core Audio 没有找到所选 App 的输出进程：\(bundleIdentifier)"
        case let .coreAudio(operation, status):
            let code = Self.fourCharacterCode(status)
            return "\(operation) 失败（\(status) / \(code)）"
        case .invalidFormat:
            return "Core Audio 系统声音 Tap 返回了无效格式"
        case .invalidInputBuffer:
            return "Core Audio 系统声音 Tap 返回了无效样本块"
        }
    }

    private static func fourCharacterCode(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes: [UInt8] = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "0x\(String(value, radix: 16))"
        }
        return String(bytes: bytes, encoding: .ascii) ?? "0x\(String(value, radix: 16))"
    }
}

/// System-audio capture backed by Apple's Core Audio process-tap API.
///
/// REC-001/REC-002/REC-004/NAT-001: a second display-level SCStream cut the
/// measured foreground cadence from 60.00 to 28.80 fps even when its auxiliary
/// surface was only 2x2 at 1 fps. A process tap reads the HAL audio mix without
/// creating another WindowServer compositor, while retaining host-clock PTS for
/// the native-video passthrough mux.
@available(macOS 14.2, *)
final class CoreAudioSystemAudioTap: @unchecked Sendable {
    private let ioQueue = DispatchQueue(
        label: "cn.laogou.dogsc.core-audio-system-tap",
        qos: .userInitiated
    )
    private let output: NativeSystemAudioCaptureOutput
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isRunning = false

    init(
        scope: SystemAudioScope,
        selectedApplicationBundleIdentifier: String?,
        output: NativeSystemAudioCaptureOutput
    ) throws {
        self.output = output

        let description: CATapDescription
        switch scope {
        case .all:
            let ownProcess = try Self.processObjectID(for: getpid())
            description = CATapDescription(
                stereoGlobalTapButExcludeProcesses: ownProcess.map { [$0] } ?? []
            )
        case .selectedApplication:
            guard let selectedApplicationBundleIdentifier else {
                throw CoreAudioSystemAudioTapError.selectedApplicationUnavailable("—")
            }
            let processIDs = try Self.processObjectIDs(
                bundleIdentifier: selectedApplicationBundleIdentifier
            )
            guard !processIDs.isEmpty else {
                throw CoreAudioSystemAudioTapError.selectedApplicationUnavailable(
                    selectedApplicationBundleIdentifier
                )
            }
            description = CATapDescription(stereoMixdownOfProcesses: processIDs)
        }
        let privateDeviceName = "\(AppIdentity.displayName)系统声音"
        description.name = privateDeviceName
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try Self.check(
            AudioHardwareCreateProcessTap(description, &createdTapID),
            operation: "创建 Core Audio 进程 Tap"
        )
        tapID = createdTapID

        do {
            var streamFormat = try Self.streamFormat(forTap: createdTapID)
            guard streamFormat.mSampleRate > 0,
                  streamFormat.mChannelsPerFrame > 0,
                  streamFormat.mBytesPerFrame > 0 else {
                throw CoreAudioSystemAudioTapError.invalidFormat
            }
            var formatDescription: CMAudioFormatDescription?
            let formatStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &streamFormat,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            )
            try Self.check(formatStatus, operation: "建立 Core Audio 格式描述")
            guard let formatDescription else {
                throw CoreAudioSystemAudioTapError.invalidFormat
            }

            let aggregateUID = "cn.laogou.dogsc.tap.\(UUID().uuidString)"
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: privateDeviceName,
                kAudioAggregateDeviceUIDKey: aggregateUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]],
            ]
            var createdAggregateID = AudioObjectID(kAudioObjectUnknown)
            try Self.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &createdAggregateID
                ),
                operation: "创建 Core Audio 私有聚合设备"
            )
            aggregateDeviceID = createdAggregateID

            var createdIOProcID: AudioDeviceIOProcID?
            let writerOutput = output
            let callbackFormat = streamFormat
            try Self.check(
                AudioDeviceCreateIOProcIDWithBlock(
                    &createdIOProcID,
                    createdAggregateID,
                    ioQueue
                ) { _, inputData, inputTime, _, _ in
                    guard let sampleBuffer = Self.makeSampleBuffer(
                        inputData: inputData,
                        inputTime: inputTime,
                        streamFormat: callbackFormat,
                        formatDescription: formatDescription
                    ) else { return }
                    writerOutput.append(sampleBuffer: sampleBuffer)
                },
                operation: "建立 Core Audio 输入回调"
            )
            guard let createdIOProcID else {
                throw CoreAudioSystemAudioTapError.invalidInputBuffer
            }
            ioProcID = createdIOProcID
        } catch {
            cleanup()
            throw error
        }
    }

    deinit {
        cleanup()
    }

    func start() throws {
        guard !isRunning, let ioProcID else { return }
        try Self.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "启动 Core Audio 系统声音 Tap"
        )
        isRunning = true
    }

    func stop() throws {
        guard isRunning, let ioProcID else { return }
        defer { isRunning = false }
        try Self.check(
            AudioDeviceStop(aggregateDeviceID, ioProcID),
            operation: "停止 Core Audio 系统声音 Tap"
        )
    }

    private func cleanup() {
        if isRunning, let ioProcID {
            _ = AudioDeviceStop(aggregateDeviceID, ioProcID)
            isRunning = false
        }
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateDeviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func makeSampleBuffer(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: UnsafePointer<AudioTimeStamp>,
        streamFormat: AudioStreamBasicDescription,
        formatDescription: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        guard let firstBuffer = buffers.first,
              firstBuffer.mData != nil,
              firstBuffer.mDataByteSize > 0 else { return nil }
        let bytesPerFrame = max(Int(streamFormat.mBytesPerFrame), 1)
        let frameCount = Int(firstBuffer.mDataByteSize) / bytesPerFrame
        guard frameCount > 0 else { return nil }

        let hostTime = inputTime.pointee.mHostTime > 0
            ? inputTime.pointee.mHostTime
            : AudioGetCurrentHostTime()
        let presentationTime = CMClockMakeHostTimeFromSystemUnits(hostTime)
        guard presentationTime.isNumeric else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMAudioSampleBufferCreateWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }
        let copyStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            bufferList: inputData
        )
        guard copyStatus == noErr,
              CMSampleBufferSetDataReady(sampleBuffer) == noErr else { return nil }
        return sampleBuffer
    }

    private static func streamFormat(
        forTap tapID: AudioObjectID
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            operation: "读取 Core Audio Tap 格式"
        )
        return format
    }

    private static func processObjectID(for pid: pid_t) throws -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var processID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &processID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifier,
                &size,
                &objectID
            )
        }
        if status == kAudioHardwareBadObjectError { return nil }
        try check(status, operation: "查找当前 App 的 Core Audio 进程")
        return objectID == kAudioObjectUnknown ? nil : objectID
    }

    private static func processObjectIDs(
        bundleIdentifier: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &dataSize
            ),
            operation: "读取 Core Audio 进程列表大小"
        )
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objectIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try objectIDs.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            try check(
                AudioObjectGetPropertyData(
                    AudioObjectID(kAudioObjectSystemObject),
                    &address,
                    0,
                    nil,
                    &dataSize,
                    baseAddress
                ),
                operation: "读取 Core Audio 进程列表"
            )
        }
        return objectIDs.filter { objectID in
            processBundleIdentifier(for: objectID) == bundleIdentifier
        }
    }

    private static func processBundleIdentifier(
        for objectID: AudioObjectID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanagedBundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            &unmanagedBundleID
        )
        guard status == noErr, let unmanagedBundleID else { return nil }
        return unmanagedBundleID.takeRetainedValue() as String
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioSystemAudioTapError.coreAudio(
                operation: operation,
                status: status
            )
        }
    }
}
