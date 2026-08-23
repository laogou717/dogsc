import Darwin
import Foundation
import Metal
import RecorderCore

/// Samples only public, low-cost counters once per recovery heartbeat. It does
/// no process enumeration and never runs on a media callback queue.
final class RecordingPerformanceMonitor: @unchecked Sendable {
    private struct CPUCounters {
        let processNanoseconds: UInt64
        let residentBytes: UInt64
        let systemUsedTicks: UInt64
        let systemTotalTicks: UInt64
    }

    private let lock = NSLock()
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private let volumeURL: URL
    private let metalDevice: MTLDevice?
    private var previousCounters: CPUCounters?
    private var previousUptime: TimeInterval?
    private var summaryStorage: RecordingPerformanceSummary?

    init(volumeURL: URL, metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        self.volumeURL = volumeURL
        self.metalDevice = metalDevice
    }

    func sample() -> RecordingPerformanceSample? {
        guard let current = Self.cpuCounters() else { return nil }
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        defer { lock.unlock() }
        let wallDelta = previousUptime.map { max(uptime - $0, 0) } ?? 0
        let processDelta = previousCounters.map {
            current.processNanoseconds &- $0.processNanoseconds
        } ?? 0
        let systemUsedDelta = previousCounters.map {
            current.systemUsedTicks &- $0.systemUsedTicks
        } ?? 0
        let systemTotalDelta = previousCounters.map {
            current.systemTotalTicks &- $0.systemTotalTicks
        } ?? 0
        previousCounters = current
        previousUptime = uptime

        let processCPU = wallDelta > 0
            ? Double(processDelta) / 1_000_000_000 / wallDelta * 100
            : 0
        let systemCPU = systemTotalDelta > 0
            ? Double(systemUsedDelta) / Double(systemTotalDelta) * 100
            : 0
        let sample = RecordingPerformanceSample(
            elapsed: max(uptime - startedAt, 0),
            processCPUPercent: processCPU,
            systemCPUPercent: systemCPU,
            processResidentBytes: current.residentBytes,
            processMetalAllocatedBytes: metalDevice.map { UInt64($0.currentAllocatedSize) },
            availableDiskBytes: Self.availableDiskBytes(at: volumeURL),
            thermalState: Self.thermalState(ProcessInfo.processInfo.thermalState)
        )
        summaryStorage = summaryStorage?.including(sample)
            ?? RecordingPerformanceSummary(sample: sample)
        return sample
    }

    var summary: RecordingPerformanceSummary? {
        lock.lock()
        defer { lock.unlock() }
        return summaryStorage
    }

    private static func cpuCounters() -> CPUCounters? {
        var taskInfo = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
        let result = withUnsafeMutablePointer(to: &taskInfo) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: Int(taskSize)) {
                proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, $0, taskSize)
            }
        }
        guard result == taskSize else { return nil }

        var cpuLoad = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let hostResult = withUnsafeMutablePointer(to: &cpuLoad) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard hostResult == KERN_SUCCESS else { return nil }
        let user = UInt64(cpuLoad.cpu_ticks.0)
        let system = UInt64(cpuLoad.cpu_ticks.1)
        let idle = UInt64(cpuLoad.cpu_ticks.2)
        let nice = UInt64(cpuLoad.cpu_ticks.3)
        return CPUCounters(
            processNanoseconds: taskInfo.pti_total_user &+ taskInfo.pti_total_system,
            residentBytes: taskInfo.pti_resident_size,
            systemUsedTicks: user &+ system &+ nice,
            systemTotalTicks: user &+ system &+ idle &+ nice
        )
    }

    private static func availableDiskBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let available = values?.volumeAvailableCapacityForImportantUsage {
            return available
        }
        if let available = values?.volumeAvailableCapacity {
            return Int64(available)
        }
        // Some mounted or virtual volumes do not expose URL capacity resource
        // keys even though the public filesystem attributes are available.
        // Keep recording diagnostics useful on those volumes as well.
        let attributes = try? FileManager.default.attributesOfFileSystem(
            forPath: url.path
        )
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func thermalState(
        _ state: ProcessInfo.ThermalState
    ) -> RecordingThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .unknown
        }
    }
}
