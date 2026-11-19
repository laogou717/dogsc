import Accelerate
import AVFoundation
import Foundation

/// Measures a stable loudness baseline on each original recording. Cutting
/// the timeline never changes that baseline or requires another measurement.
enum AudioLoudnessAnalyzer {
    struct Profile: Codable, Equatable, Sendable {
        let integratedLUFS: Double?
        let calibrationGain: Float
        let hasAudibleProgramAudio: Bool

        static let unity = Self(
            integratedLUFS: nil,
            calibrationGain: 1,
            hasAudibleProgramAudio: false
        )
    }

    static let targetLUFS: Double = -16
    static let maxBoostDB: Double = 14
    static let minimumLUFS: Double = -42

    private static let analysisSampleRate: Double = 48_000
    private static let hopFrames = 4_800 // 100 ms at 48 kHz (4 hops = 400 ms block)
    // ITU-R BS.1770-4 Table 1 & Table 2 K-weighting biquad coefficients at 48 kHz:
    // Stage 1 (spherical head high-shelf) followed by Stage 2 (RLB high-pass).
    private static let kWeightingCoefficients48k: [Double] = [
        1.53512485958697, -2.69169618940638, 1.19839281085285,
        -1.69065929318241, 0.73248077421585,
        1.0, -2.0, 1.0,
        -1.99004745483398, 0.99007225036621,
    ]
    // biquadm lays out coefficients by section, then channel. Both channels
    // use the same K-weighting, with independent filter history in the setup.
    private static let stereoCoefficients = stride(from: 0, to: 10, by: 5).flatMap { start in
        let section = Array(kWeightingCoefficients48k[start..<(start + 5)])
        return section + section
    }

    /// Pure BS.1770-4 gating and calibration policy over 100 ms stereo hop
    /// mean-square energies (after K-weighting). Exposed internal for tests.
    static func evaluate(hopEnergies: [Double]) -> Profile {
        guard hopEnergies.count >= 4 else { return .unity }
        var blockEnergies: [Double] = []
        blockEnergies.reserveCapacity(hopEnergies.count - 3)
        for index in 0...(hopEnergies.count - 4) {
            let blockMeanSquare = 0.25 * (
                hopEnergies[index]
                    + hopEnergies[index + 1]
                    + hopEnergies[index + 2]
                    + hopEnergies[index + 3]
            )
            blockEnergies.append(blockMeanSquare)
        }

        let minimumAudibleBlocks = 8 // Ignore noise and isolated clicks.

        let absoluteGateEnergy = pow(10.0, (-70.0 + 0.691) / 10.0)
        let audibleFloorEnergy = pow(10.0, (minimumLUFS + 0.691) / 10.0)
        let absolutePassed = blockEnergies.filter { $0 > absoluteGateEnergy }
        let audibleBlockCount = blockEnergies.reduce(into: 0) { count, energy in
            if energy > audibleFloorEnergy { count += 1 }
        }
        guard !absolutePassed.isEmpty, audibleBlockCount >= minimumAudibleBlocks else {
            return .unity
        }

        let absoluteMean = absolutePassed.reduce(0, +) / Double(absolutePassed.count)
        let absoluteLUFS = -0.691 + 10.0 * log10(absoluteMean)
        let relativeGateEnergy = pow(10.0, (absoluteLUFS - 10.0 + 0.691) / 10.0)
        let gatedBlocks = absolutePassed.filter { $0 > relativeGateEnergy }
        guard !gatedBlocks.isEmpty else { return .unity }

        let gatedMean = gatedBlocks.reduce(0, +) / Double(gatedBlocks.count)
        let integratedLUFS = -0.691 + 10.0 * log10(gatedMean)
        guard integratedLUFS.isFinite, integratedLUFS >= minimumLUFS else {
            return .unity
        }

        // Only lift quiet recordings; never unexpectedly attenuate a source
        // that is already at or above the target level.
        let boostDB = min(max(targetLUFS - integratedLUFS, 0), maxBoostDB)
        let gain = Float(pow(10.0, boostDB / 20.0))
        return Profile(
            integratedLUFS: integratedLUFS,
            calibrationGain: gain.isFinite ? max(gain, 1) : 1,
            hasAudibleProgramAudio: true
        )
    }

    /// Streaming meter shared by source decoding and the numerical tests.
    /// K-weighting and gating run during the existing PCM pass, not another
    /// full AVAssetReader traversal of the original recording.
    final class Meter {
        private let setup = vDSP_biquadm_CreateSetup(AudioLoudnessAnalyzer.stereoCoefficients, 2, 2)
        private var filteredL = [Float](repeating: 0, count: hopFrames)
        private var filteredR = [Float](repeating: 0, count: hopFrames)
        private var energies: [Double] = []
        private var accumulatedEnergy: Double = 0
        private var accumulatedFrames = 0

        deinit { if let setup { vDSP_biquadm_DestroySetup(setup) } }

        func consume(_ buffer: AVAudioPCMBuffer) {
            guard let setup, buffer.frameLength > 0,
                  let data = buffer.audioBufferList.pointee.mBuffers.mData else { return }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.frameLength)
            var offset = 0
            while offset < count {
                let chunk = min(hopFrames - accumulatedFrames, count - offset)
                filteredL.withUnsafeMutableBufferPointer { left in
                    filteredR.withUnsafeMutableBufferPointer { right in
                        var inputs = [UnsafePointer(samples + offset * 2), UnsafePointer(samples + offset * 2 + 1)]
                        var outputs = [left.baseAddress!, right.baseAddress!]
                        vDSP_biquadm(setup, &inputs, 2, &outputs, 1, vDSP_Length(chunk))
                    }
                }
                var left: Float = 0
                var right: Float = 0
                vDSP_svesq(filteredL, 1, &left, vDSP_Length(chunk))
                vDSP_svesq(filteredR, 1, &right, vDSP_Length(chunk))
                accumulatedEnergy += Double(left + right)
                accumulatedFrames += chunk
                offset += chunk
                if accumulatedFrames == hopFrames {
                    energies.append(accumulatedEnergy / Double(hopFrames))
                    accumulatedFrames = 0
                    accumulatedEnergy = 0
                }
            }
        }

        var profile: Profile { evaluate(hopEnergies: energies) }
    }

    static func analyze48kStereoSamples(left: [Float], right: [Float]) -> Profile {
        let count = min(left.count, right.count)
        guard count > 0 else { return .unity }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: analysisSampleRate,
            channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for frame in 0..<count { samples[frame * 2] = left[frame]; samples[frame * 2 + 1] = right[frame] }
        let meter = Meter()
        meter.consume(buffer)
        return meter.profile
    }
}
