import CoreImage
import Foundation
import Vision

struct CameraBeautyFrame: Sendable {
    struct Identity: Equatable, Sendable {
        let sourceID: UUID?
        let mediaGeneration: UInt64
        let discontinuityID: UInt64
    }
    let tracker: CameraBeautyTracker
    let time: TimeInterval
    var sourceID: UUID? = nil
    var mediaGeneration: UInt64 = 0
    var discontinuityID: UInt64 = 0
    var identity: Identity {
        Identity(sourceID: sourceID, mediaGeneration: mediaGeneration, discontinuityID: discontinuityID)
    }
}

/// Geometry and strength only: never blend successive image recipes, which
/// would retain a growing chain of camera buffers and blur moving faces.
struct CameraBeautyContinuity {
    struct Track {
        let id: UUID
        var region: CameraBeautyRenderer.FaceRegion
        var target: CameraBeautyRenderer.FaceRegion
        var lastDetection: TimeInterval
    }
    private(set) var tracks: [Track] = []
    private var lastTime: TimeInterval?

    mutating func update(at time: TimeInterval, detected: [CameraBeautyRenderer.FaceRegion]?,
                         tracked: [UUID: CGRect] = [:]) -> [Track] {
        let firstFrame = lastTime == nil
        let dt = max(time - (lastTime ?? time - 1.0 / 30), 0)
        lastTime = time
        for index in tracks.indices {
            if let bounds = tracked[tracks[index].id] {
                tracks[index].target = Self.remap(tracks[index].target, to: bounds)
            }
        }
        var unmatched = Set(tracks.indices)
        for region in detected ?? [] {
            let match = unmatched.min { Self.distance(tracks[$0].target.bounds, region.bounds)
                < Self.distance(tracks[$1].target.bounds, region.bounds) }
            if let index = match, Self.distance(tracks[index].target.bounds, region.bounds) < 0.9 {
                unmatched.remove(index)
                var next = Self.remap(tracks[index].target, to: region.bounds)
                for slot in region.protectedRegions.indices {
                    let feature = region.protectedRegions[slot]
                    if slot >= next.protectedRegions.count { next.protectedRegions.append(feature) }
                    else if !feature.isNull { next.protectedRegions[slot] = feature }
                }
                tracks[index].target = next
                tracks[index].lastDetection = time
            } else {
                var next = region
                // A fresh paused/seek frame must show the requested strength
                // immediately; only a later reacquisition needs a fade-in.
                next.opacity = firstFrame ? 1 : 0
                tracks.append(Track(id: UUID(), region: next, target: region, lastDetection: time))
            }
        }
        for index in tracks.indices {
            tracks[index].region = Self.stabilize(tracks[index].region, toward: tracks[index].target, dt: dt)
            // Brief occlusion keeps the effect; prolonged loss fades it away.
            let age = time - tracks[index].lastDetection
            let target = min(max(1 - (age - 0.4) / 0.3, 0), 1)
            let current = tracks[index].region.opacity
            let step = dt / 0.12
            tracks[index].region.opacity = current + min(max(target - current, -step), step)
        }
        tracks.removeAll { time - $0.lastDetection > 0.7 && $0.region.opacity <= 0.001 }
        return tracks
    }

    private static func stabilize(_ old: CameraBeautyRenderer.FaceRegion,
                                  toward target: CameraBeautyRenderer.FaceRegion, dt: Double) -> CameraBeautyRenderer.FaceRegion {
        let a = old.bounds, b = target.bounds
        let size = max(a.width, a.height, 0.001)
        let movement = hypot(a.midX - b.midX, a.midY - b.midY)
        let positionAlpha = 1 - exp(-dt / (0.055 / (1 + movement / size * 30)))
        let sizeAlpha = 1 - exp(-dt / 0.18)
        func approach(_ from: Double, _ to: Double, alpha: Double, tolerance: Double) -> Double {
            abs(to - from) <= tolerance ? from : from + (to - from) * alpha
        }
        let width = approach(a.width, b.width, alpha: sizeAlpha, tolerance: a.width * 0.01)
        let height = approach(a.height, b.height, alpha: sizeAlpha, tolerance: a.height * 0.01)
        let x = approach(a.midX, b.midX, alpha: positionAlpha, tolerance: size * 0.004)
        let y = approach(a.midY, b.midY, alpha: positionAlpha, tolerance: size * 0.004)
        let bounds = CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height)
        var result = remap(old, to: bounds)
        let previousMapped = result.protectedRegions
        // Landmark slots are stable (left eye, right eye, brows, lips). Smooth
        // in face-local coordinates so translating a face cannot pull its
        // feature protection toward a different feature or behind the face.
        let featureAlpha = 1 - exp(-dt / 0.09)
        result.protectedRegions = target.protectedRegions.enumerated().map { slot, feature in
            let previous = slot < old.protectedRegions.count ? old.protectedRegions[slot] : .null
            guard !feature.isNull else {
                return slot < previousMapped.count ? previousMapped[slot] : .null
            }
            func local(_ rect: CGRect, in face: CGRect) -> CGRect {
                CGRect(x: (rect.minX - face.minX) / face.width, y: (rect.minY - face.minY) / face.height,
                       width: rect.width / face.width, height: rect.height / face.height)
            }
            var value = local(feature, in: b)
            if !previous.isNull {
                let oldValue = local(previous, in: a)
                value = CGRect(
                    x: approach(oldValue.minX, value.minX, alpha: featureAlpha, tolerance: 0.008),
                    y: approach(oldValue.minY, value.minY, alpha: featureAlpha, tolerance: 0.008),
                    width: approach(oldValue.width, value.width, alpha: featureAlpha, tolerance: 0.008),
                    height: approach(oldValue.height, value.height, alpha: featureAlpha, tolerance: 0.008))
            }
            return CGRect(x: bounds.minX + value.minX * bounds.width, y: bounds.minY + value.minY * bounds.height,
                          width: value.width * bounds.width, height: value.height * bounds.height)
        }
        return result
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> Double {
        let size = max(a.width, a.height, b.width, b.height, 0.001)
        return hypot(a.midX - b.midX, a.midY - b.midY) / size
            + abs(log(max(b.width, 0.001) / max(a.width, 0.001))) * 0.3
    }

    private static func remap(_ region: CameraBeautyRenderer.FaceRegion, to bounds: CGRect) -> CameraBeautyRenderer.FaceRegion {
        let old = region.bounds
        guard old.width > 0, old.height > 0 else { return region }
        var result = region
        result.bounds = bounds
        result.protectedRegions = region.protectedRegions.map {
            guard !$0.isNull else { return .null }
            return CGRect(x: bounds.minX + ($0.minX - old.minX) / old.width * bounds.width,
                   y: bounds.minY + ($0.minY - old.minY) / old.height * bounds.height,
                   width: $0.width / old.width * bounds.width, height: $0.height / old.height * bounds.height)
        }
        return result
    }
}

/// One owner per live processor, preview surface or export job. All Vision
/// state is serialized; source changes and seeks cannot borrow another face.
final class CameraBeautyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var sequence = VNSequenceRequestHandler()
    private var requests: [UUID: VNTrackObjectRequest] = [:]
    private var trackingBounds: [UUID: CGRect] = [:]
    private var continuity = CameraBeautyContinuity()
    private var identity: CameraBeautyFrame.Identity?
    private var extent = CGRect.zero
    private var lastTime: TimeInterval?
    private var lastDetection = -Double.infinity
    private var lastSource: CIImage?
    private var lastRegions: [CameraBeautyRenderer.FaceRegion] = []
    private let detect: (CIImage, CIContext) -> [CameraBeautyRenderer.FaceRegion]

    init(detect: @escaping (CIImage, CIContext) -> [CameraBeautyRenderer.FaceRegion] = CameraBeautyRenderer.detectFaces) {
        self.detect = detect
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        clear()
    }

    private func clear() {
        sequence = VNSequenceRequestHandler()
        requests = [:]
        trackingBounds = [:]
        continuity = CameraBeautyContinuity()
        identity = nil
        lastTime = nil
        lastDetection = -.infinity
        lastSource = nil
        lastRegions = []
    }

    func regions(for source: CIImage, frame: CameraBeautyFrame) -> [CameraBeautyRenderer.FaceRegion] {
        lock.lock(); defer { lock.unlock() }
        guard frame.time.isFinite else { clear(); return [] }
        if identity != frame.identity || extent != source.extent
            || lastTime.map({ frame.time < $0 || frame.time - $0 > 0.3 }) == true {
            clear()
        }
        identity = frame.identity
        extent = source.extent
        lastTime = frame.time
        if lastSource === source { return lastRegions }
        let image = CameraBeautyRenderer.analysisImage(source)
        var tracked: [UUID: CGRect] = [:]
        if !requests.isEmpty {
            do {
                try sequence.perform(Array(requests.values), on: image, orientation: .up)
                for (id, request) in requests {
                    if let observation = request.results?.first as? VNDetectedObjectObservation, observation.confidence >= 0.5 {
                        // Object-tracker scale differs from the face detector's
                        // box. Use inter-frame translation only; face detection
                        // remains the authority for face size and landmarks.
                        let bounds = observation.boundingBox
                        if let previous = trackingBounds[id], let face = continuity.tracks.first(where: { $0.id == id }) {
                            let dx = bounds.midX - previous.midX, dy = bounds.midY - previous.midY
                            if hypot(dx, dy) < max(face.target.bounds.width, face.target.bounds.height) * 0.35 {
                                tracked[id] = face.target.bounds.offsetBy(dx: dx, dy: dy)
                            }
                        }
                        trackingBounds[id] = bounds
                        request.inputObservation = observation
                    }
                }
            } catch {
                sequence = VNSequenceRequestHandler()
                requests = [:]
                trackingBounds = [:]
            }
        }
        var detected: [CameraBeautyRenderer.FaceRegion]?
        if frame.time - lastDetection >= 0.12 {
            detected = detect(image, context)
            lastDetection = frame.time
        }
        let faces = continuity.update(at: frame.time, detected: detected, tracked: tracked)
        let ids = Set(faces.map(\.id))
        requests = requests.filter { ids.contains($0.key) }
        trackingBounds = trackingBounds.filter { ids.contains($0.key) }
        for face in faces where requests[face.id] == nil {
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: face.region.bounds))
            request.trackingLevel = .accurate
            requests[face.id] = request
        }
        lastSource = source
        lastRegions = faces.map(\.region)
        return lastRegions
    }
}
