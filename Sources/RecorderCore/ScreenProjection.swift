import Foundation

public struct ProjectedScreenPointMapper: Sendable {
    private let sourceRect: CompositionRect
    private let topLeft: CompositionPoint
    private let a: Double
    private let b: Double
    private let d: Double
    private let e: Double
    private let perspectiveX: Double
    private let perspectiveY: Double

    fileprivate init?(
        quad: ProjectedScreenQuad,
        sourceRect: CompositionRect
    ) {
        guard sourceRect.width.isFinite,
              sourceRect.height.isFinite,
              sourceRect.width > 0,
              sourceRect.height > 0,
              quad.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return nil
        }

        let dx1 = quad.topRight.x - quad.bottomRight.x
        let dx2 = quad.bottomLeft.x - quad.bottomRight.x
        let dx3 = quad.topLeft.x - quad.topRight.x
            + quad.bottomRight.x - quad.bottomLeft.x
        let dy1 = quad.topRight.y - quad.bottomRight.y
        let dy2 = quad.bottomLeft.y - quad.bottomRight.y
        let dy3 = quad.topLeft.y - quad.topRight.y
            + quad.bottomRight.y - quad.bottomLeft.y
        let denominator = dx1 * dy2 - dx2 * dy1

        if abs(dx3) <= 0.000_000_001,
           abs(dy3) <= 0.000_000_001 {
            perspectiveX = 0
            perspectiveY = 0
        } else {
            guard abs(denominator) > 0.000_000_001 else { return nil }
            perspectiveX = (dx3 * dy2 - dx2 * dy3) / denominator
            perspectiveY = (dx1 * dy3 - dx3 * dy1) / denominator
        }

        self.sourceRect = sourceRect
        topLeft = quad.topLeft
        a = quad.topRight.x - quad.topLeft.x + perspectiveX * quad.topRight.x
        b = quad.bottomLeft.x - quad.topLeft.x + perspectiveY * quad.bottomLeft.x
        d = quad.topRight.y - quad.topLeft.y + perspectiveX * quad.topRight.y
        e = quad.bottomLeft.y - quad.topLeft.y + perspectiveY * quad.bottomLeft.y
    }

    public func project(_ point: CompositionPoint) -> CompositionPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let x = (point.x - sourceRect.x) / sourceRect.width
        let y = (point.y - sourceRect.y) / sourceRect.height
        let divisor = perspectiveX * x + perspectiveY * y + 1
        guard divisor.isFinite, abs(divisor) > 0.000_000_001 else { return nil }
        let projected = CompositionPoint(
            x: (a * x + b * y + topLeft.x) / divisor,
            y: (d * x + e * y + topLeft.y) / divisor
        )
        guard projected.x.isFinite, projected.y.isFinite else { return nil }
        return projected
    }
    /// Exact inverse of the same homography used by the renderer. Editing a
    /// tilted plane must not approximate perspective using its top/left edges.
    public func unproject(_ point: CompositionPoint) -> CompositionPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let aa = a - point.x * perspectiveX
        let bb = b - point.x * perspectiveY
        let dd = d - point.y * perspectiveX
        let ee = e - point.y * perspectiveY
        let determinant = aa * ee - bb * dd
        guard abs(determinant) > 0.000_000_001 else { return nil }
        let x = point.x - topLeft.x, y = point.y - topLeft.y
        let u = (x * ee - bb * y) / determinant
        let v = (aa * y - x * dd) / determinant
        let result = CompositionPoint(x: sourceRect.x + u * sourceRect.width,
                                      y: sourceRect.y + v * sourceRect.height)
        return result.x.isFinite && result.y.isFinite ? result : nil
    }

}

public struct ProjectedScreenQuad: Equatable, Sendable {
    public var topLeft: CompositionPoint
    public var topRight: CompositionPoint
    public var bottomRight: CompositionPoint
    public var bottomLeft: CompositionPoint

    public init(
        topLeft: CompositionPoint,
        topRight: CompositionPoint,
        bottomRight: CompositionPoint,
        bottomLeft: CompositionPoint
    ) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    public var bounds: CompositionRect {
        let points = corners
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        return CompositionRect(
            x: minX,
            y: minY,
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }

    /// Corners in the same semantic order as the unprojected screen. Keeping
    /// this order explicit lets editor interaction geometry follow the exact
    /// quad consumed by the renderer instead of falling back to its axis-
    /// aligned bounds.
    public var corners: [CompositionPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// The projected centre used by interaction affordances. For a
    /// perspective quad this is intentionally the average of all four visible
    /// corners, rather than the centre of the axis-aligned bounds.
    public var center: CompositionPoint {
        CompositionPoint(
            x: corners.reduce(0) { $0 + $1.x } / 4,
            y: corners.reduce(0) { $0 + $1.y } / 4
        )
    }

    /// The semantic lower-right corner remains the resize affordance even
    /// after rotation. Using `bounds.maxX/maxY` would put the handle on an
    /// unrelated corner as soon as the screen rotates around Z or Y.
    public var resizeHandlePoint: CompositionPoint { bottomRight }

    /// Projects an arbitrary point authored in `sourceRect` through the same
    /// homography as the four screen corners. Preview overlays use this to
    /// remain independent GPU layers during 3D motion instead of falling back
    /// into a full-canvas raster pass. Coordinates outside the rectangle are
    /// intentionally supported for cursor sprites and shadows.
    public func project(
        _ point: CompositionPoint,
        from sourceRect: CompositionRect
    ) -> CompositionPoint? {
        projector(from: sourceRect)?.project(point)
    }

    /// Builds the unit-square homography once so several overlay corners in
    /// the same display tick can reuse it. `project(_:from:)` remains the
    /// convenient one-point API for interaction code.
    public func projector(
        from sourceRect: CompositionRect
    ) -> ProjectedScreenPointMapper? {
        ProjectedScreenPointMapper(quad: self, sourceRect: sourceRect)
    }

    /// Converts a canvas-space drag into a signed resize amount along the
    /// screen's semantic top-left → bottom-right diagonal. This keeps resize
    /// direction intuitive after 3D/Z rotation and makes motion orthogonal to
    /// that diagonal contribute nothing. The result is normalized by the
    /// caller's reference length.
    public func semanticResizeDelta(
        translation: CompositionPoint,
        referenceLength: Double
    ) -> Double {
        guard translation.x.isFinite,
              translation.y.isFinite,
              referenceLength.isFinite else { return 0 }
        let dx = resizeHandlePoint.x - topLeft.x
        let dy = resizeHandlePoint.y - topLeft.y
        let length = hypot(dx, dy)
        guard length > 0.000_001 else { return 0 }
        let unitX = dx / length
        let unitY = dy / length
        let projectedTravel = translation.x * unitX + translation.y * unitY
        let identityEquivalentGain = abs(unitX) + abs(unitY)
        return projectedTravel * identityEquivalentGain / max(referenceLength, 1)
    }

    /// Returns whether a canvas-space point lies inside the projected screen.
    /// Boundary points are included. The winding implementation works for
    /// clockwise and counter-clockwise quads and safely returns `false` for
    /// non-finite or collapsed geometry.
    public func contains(
        _ point: CompositionPoint,
        tolerance: Double = 0.000_001
    ) -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              tolerance.isFinite,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return false
        }

        let epsilon = max(tolerance, 0)
        let twiceArea = corners.indices.reduce(0.0) { result, index in
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            return result + start.x * end.y - end.x * start.y
        }
        guard abs(twiceArea) > epsilon else { return false }

        var windingNumber = 0

        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]

            if Self.point(
                point,
                liesOnSegmentFrom: start,
                to: end,
                tolerance: epsilon
            ) {
                return true
            }

            if start.y <= point.y {
                if end.y > point.y,
                   Self.cross(start, end, point) > epsilon {
                    windingNumber += 1
                }
            } else if end.y <= point.y,
                      Self.cross(start, end, point) < -epsilon {
                windingNumber -= 1
            }
        }

        return windingNumber != 0
    }

    private static func cross(
        _ start: CompositionPoint,
        _ end: CompositionPoint,
        _ point: CompositionPoint
    ) -> Double {
        (end.x - start.x) * (point.y - start.y)
            - (end.y - start.y) * (point.x - start.x)
    }

    private static func point(
        _ point: CompositionPoint,
        liesOnSegmentFrom start: CompositionPoint,
        to end: CompositionPoint,
        tolerance: Double
    ) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > tolerance * tolerance else {
            return hypot(point.x - start.x, point.y - start.y) <= tolerance
        }

        let parameter = ((point.x - start.x) * dx + (point.y - start.y) * dy)
            / lengthSquared
        guard parameter >= -tolerance, parameter <= 1 + tolerance else {
            return false
        }
        let nearest = CompositionPoint(
            x: start.x + parameter * dx,
            y: start.y + parameter * dy
        )
        return hypot(point.x - nearest.x, point.y - nearest.y) <= tolerance
    }
}

/// Deterministic projection geometry for the decorated screen layer.
///
/// The input and output both use top-left canvas coordinates. Preview and
/// export can therefore consume the same four corners, then perform only their
/// final API-specific coordinate conversion. `perspective == 0` is an
/// orthographic projection; larger values increase depth without changing an
/// unrotated card.
public enum ScreenProjection {
    public static func project(
        rect: CompositionRect,
        rotationX: Double,
        rotationY: Double,
        rotationZ: Double,
        perspective: Double,
        anchor: CompositionPoint? = nil
    ) -> ProjectedScreenQuad {
        let safeWidth = max(rect.width, 0)
        let safeHeight = max(rect.height, 0)
        let fallbackAnchor = CompositionPoint(x: rect.midX, y: rect.midY)
        let pivot = if let anchor,
                       anchor.x.isFinite,
                       anchor.y.isFinite {
            anchor
        } else {
            fallbackAnchor
        }
        let maximumDimension = max(rect.width, rect.height, 1)
        let depth = min(max(perspective, 0), 2)
        let cameraDistance = depth > 0
            ? maximumDimension * 2 / max(depth, 0.000_1)
            : .infinity

        let rx = degreesToRadians(rotationX)
        let ry = degreesToRadians(rotationY)
        let rz = degreesToRadians(rotationZ)
        let sinX = sin(rx)
        let cosX = cos(rx)
        let sinY = sin(ry)
        let cosY = cos(ry)
        let sinZ = sin(rz)
        let cosZ = cos(rz)

        func point(_ x: Double, _ y: Double) -> CompositionPoint {
            // Rotate around X, then Y, then Z. The screen starts on z=0.
            let xAfterX = x
            let yAfterX = y * cosX
            let zAfterX = y * sinX

            let xAfterY = xAfterX * cosY + zAfterX * sinY
            let yAfterY = yAfterX
            let zAfterY = -xAfterX * sinY + zAfterX * cosY

            let xAfterZ = xAfterY * cosZ - yAfterY * sinZ
            let yAfterZ = xAfterY * sinZ + yAfterY * cosZ

            let projectionScale: Double
            if cameraDistance.isFinite {
                // Keep the denominator away from zero for authored extremes;
                // validation can constrain controls without the renderer ever
                // producing NaN/Infinity.
                let denominator = max(
                    cameraDistance - zAfterY,
                    cameraDistance * 0.12
                )
                projectionScale = cameraDistance / denominator
            } else {
                projectionScale = 1
            }
            return CompositionPoint(
                x: pivot.x + xAfterZ * projectionScale,
                y: pivot.y + yAfterZ * projectionScale
            )
        }

        return ProjectedScreenQuad(
            topLeft: point(rect.x - pivot.x, rect.y - pivot.y),
            topRight: point(rect.x + safeWidth - pivot.x, rect.y - pivot.y),
            bottomRight: point(
                rect.x + safeWidth - pivot.x,
                rect.y + safeHeight - pivot.y
            ),
            bottomLeft: point(rect.x - pivot.x, rect.y + safeHeight - pivot.y)
        )
    }

    private static func degreesToRadians(_ value: Double) -> Double {
        value * .pi / 180
    }
}
