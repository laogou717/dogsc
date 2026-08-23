import Foundation

public enum RecordingThermalState: String, Codable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

/// One low-frequency system/process sample associated with a recording run.
/// Media-path counters remain in their dedicated screen/camera/audio types.
public struct RecordingPerformanceSample: Codable, Equatable, Sendable {
    public let elapsed: TimeInterval
    public let processCPUPercent: Double
    public let systemCPUPercent: Double
    public let processResidentBytes: UInt64
    public let processMetalAllocatedBytes: UInt64?
    public let availableDiskBytes: Int64?
    public let thermalState: RecordingThermalState

    public init(
        elapsed: TimeInterval,
        processCPUPercent: Double,
        systemCPUPercent: Double,
        processResidentBytes: UInt64,
        processMetalAllocatedBytes: UInt64? = nil,
        availableDiskBytes: Int64? = nil,
        thermalState: RecordingThermalState
    ) {
        self.elapsed = max(elapsed.isFinite ? elapsed : 0, 0)
        self.processCPUPercent = max(processCPUPercent.isFinite ? processCPUPercent : 0, 0)
        self.systemCPUPercent = min(
            max(systemCPUPercent.isFinite ? systemCPUPercent : 0, 0),
            100
        )
        self.processResidentBytes = processResidentBytes
        self.processMetalAllocatedBytes = processMetalAllocatedBytes
        self.availableDiskBytes = availableDiskBytes
        self.thermalState = thermalState
    }
}

public struct RecordingPerformanceSummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let peakProcessCPUPercent: Double
    public let peakSystemCPUPercent: Double
    public let peakProcessResidentBytes: UInt64
    public let peakProcessMetalAllocatedBytes: UInt64?
    public let minimumAvailableDiskBytes: Int64?
    public let worstThermalState: RecordingThermalState

    public init(samples: [RecordingPerformanceSample]) {
        var summary: Self?
        for sample in samples {
            summary = summary?.including(sample) ?? Self(sample: sample)
        }
        self = summary ?? Self.empty
    }

    public init(sample: RecordingPerformanceSample) {
        sampleCount = 1
        peakProcessCPUPercent = sample.processCPUPercent
        peakSystemCPUPercent = sample.systemCPUPercent
        peakProcessResidentBytes = sample.processResidentBytes
        peakProcessMetalAllocatedBytes = sample.processMetalAllocatedBytes
        minimumAvailableDiskBytes = sample.availableDiskBytes
        worstThermalState = sample.thermalState
    }

    /// Extends a persisted peak summary without retaining or rescanning its
    /// complete sample history. The JSONL recovery journal remains the source
    /// of truth for individual samples; this value is only the compact manifest
    /// summary needed while a recording is active.
    public func including(_ sample: RecordingPerformanceSample) -> Self {
        Self(
            sampleCount: sampleCount + 1,
            peakProcessCPUPercent: max(peakProcessCPUPercent, sample.processCPUPercent),
            peakSystemCPUPercent: max(peakSystemCPUPercent, sample.systemCPUPercent),
            peakProcessResidentBytes: max(
                peakProcessResidentBytes,
                sample.processResidentBytes
            ),
            peakProcessMetalAllocatedBytes: Self.maximum(
                peakProcessMetalAllocatedBytes,
                sample.processMetalAllocatedBytes
            ),
            minimumAvailableDiskBytes: Self.minimum(
                minimumAvailableDiskBytes,
                sample.availableDiskBytes
            ),
            worstThermalState: Self.severity(sample.thermalState)
                > Self.severity(worstThermalState)
                ? sample.thermalState
                : worstThermalState
        )
    }

    private init(
        sampleCount: Int,
        peakProcessCPUPercent: Double,
        peakSystemCPUPercent: Double,
        peakProcessResidentBytes: UInt64,
        peakProcessMetalAllocatedBytes: UInt64?,
        minimumAvailableDiskBytes: Int64?,
        worstThermalState: RecordingThermalState
    ) {
        self.sampleCount = sampleCount
        self.peakProcessCPUPercent = peakProcessCPUPercent
        self.peakSystemCPUPercent = peakSystemCPUPercent
        self.peakProcessResidentBytes = peakProcessResidentBytes
        self.peakProcessMetalAllocatedBytes = peakProcessMetalAllocatedBytes
        self.minimumAvailableDiskBytes = minimumAvailableDiskBytes
        self.worstThermalState = worstThermalState
    }

    private static var empty: Self {
        Self(
            sampleCount: 0,
            peakProcessCPUPercent: 0,
            peakSystemCPUPercent: 0,
            peakProcessResidentBytes: 0,
            peakProcessMetalAllocatedBytes: nil,
            minimumAvailableDiskBytes: nil,
            worstThermalState: .unknown
        )
    }

    private static func maximum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): max(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func minimum<T: Comparable>(_ lhs: T?, _ rhs: T?) -> T? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): min(lhs, rhs)
        case let (lhs?, nil): lhs
        case let (nil, rhs?): rhs
        case (nil, nil): nil
        }
    }

    private static func severity(_ state: RecordingThermalState) -> Int {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .unknown: -1
        }
    }
}
