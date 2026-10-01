import Foundation

enum ExportStage: Int, Sendable {
    case preparing, processing, finishing, cancelling

    func title(audioOnly: Bool) -> String {
        switch self {
        case .preparing: appLocalized("正在准备素材")
        case .processing: appLocalized(audioOnly ? "正在处理音频" : "正在合成与编码")
        case .finishing: appLocalized("正在完成文件")
        case .cancelling: appLocalized("正在取消导出")
        }
    }
}

/// One-second UI telemetry; media workers still use the coalesced progress
/// relay. Uptime avoids wall-clock changes and no timer survives a finished job.
struct ExportStatus: Equatable {
    var stage: ExportStage = .preparing
    var elapsed: TimeInterval = 0
    var remaining: TimeInterval?
    var secondsWithoutProgress: TimeInterval = 0
    var audioOnly = false

    var title: String { stage.title(audioOnly: audioOnly) }
    var elapsedLabel: String {
        String(format: appLocalized("已用时 %@"), Self.durationText(elapsed))
    }
    var remainingLabel: String {
        if stage == .cancelling { return appLocalized("正在释放导出资源…") }
        if secondsWithoutProgress >= 20 {
            return appLocalized("暂未收到新进度，可继续等待或取消后重试")
        }
        if stage == .finishing { return appLocalized("正在写入最终文件…") }
        guard let remaining else { return appLocalized("正在估算剩余时间…") }
        return String(format: appLocalized("预计剩余约 %@"), Self.durationText(remaining))
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let value = max(Int(seconds.isFinite ? seconds.rounded(.up) : 0), 0)
        if value >= 3_600 {
            return String(format: "%d:%02d:%02d", value / 3_600, (value / 60) % 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

struct ExportTimeEstimator {
    private struct Sample { let time: TimeInterval; let progress: Double }
    private var samples: [Sample] = []
    private var lastProgress: Double = 0
    private var lastAdvance: TimeInterval = 0

    mutating func restart(at elapsed: TimeInterval, progress: Double) {
        samples = []
        lastProgress = progress
        lastAdvance = elapsed
    }

    mutating func sample(elapsed: TimeInterval, progress: Double) -> (remaining: TimeInterval?, idle: TimeInterval) {
        if progress > lastProgress + 0.000_001 {
            lastProgress = progress
            lastAdvance = elapsed
        }
        samples.append(Sample(time: elapsed, progress: progress))
        samples.removeAll { $0.time < elapsed - 24 }
        let idle = max(elapsed - lastAdvance, 0)
        guard idle < 5, progress >= 0.03, progress < 1,
              let first = samples.first, elapsed - first.time >= 10,
              let middle = samples.first(where: { $0.time >= (first.time + elapsed) / 2 }) else {
            return (nil, idle)
        }
        let firstRate = (middle.progress - first.progress) / max(middle.time - first.time, 0.001)
        let lastRate = (progress - middle.progress) / max(elapsed - middle.time, 0.001)
        // Effects can change encoding speed substantially. Hide an estimate
        // when the recent and earlier halves disagree instead of counting down
        // a number that no longer describes the current workload.
        guard firstRate > 0, lastRate > 0,
              (0.65...1.55).contains(lastRate / firstRate) else { return (nil, idle) }
        let rate = (progress - first.progress) / (elapsed - first.time)
        let estimate = (1 - progress) / rate
        guard estimate.isFinite, estimate > 0 else { return (nil, idle) }
        return ((estimate / 5).rounded(.up) * 5, idle)
    }
}
