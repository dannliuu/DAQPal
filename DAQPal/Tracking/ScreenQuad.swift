//
//  ScreenQuad.swift
//  DAQPal
//
//  Four-corner screen geometry and the homography that maps it to a canonical
//  (axis-aligned, unit-square) view of the display — spec §8/§10 "Screen
//  Geometry" and "Canonical Perspective Normalization".
//
//  Why a quad and not a rect: once a display is tracked through yaw/pitch, its
//  outline in the frame is a general convex quadrilateral, not an axis-aligned
//  rectangle. Field regions are stored in CANONICAL space (target-relative)
//  so they stay glued to the same physical part of the display as the device
//  moves. `NormalizedROI` stays the app-wide axis-aligned type and this layer
//  is strictly additive — `boundingBox` converts back for every existing code
//  path (crop, Vision regionOfInterest, ROI overlay).
//
//  Coordinate space: normalized 0...1, TOP-LEFT origin, matching `NormalizedROI`
//  and the project-wide "normalized ROI space == buffer space == oriented
//  preview space" rule.
//

import CoreGraphics
import Foundation

/// A convex quadrilateral outlining a display in normalized frame space.
///
/// Corner names are *semantic* (which corner of the physical screen this is),
/// not positional — after a 180° roll the `topLeft` corner sits at the bottom
/// right of the frame. Keeping them semantic is what makes canonical-space
/// field coordinates stable through rotation.
struct ScreenQuad: Codable, Equatable, Hashable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    init(topLeft: CGPoint, topRight: CGPoint, bottomRight: CGPoint, bottomLeft: CGPoint) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// Axis-aligned quad from a rect — the lossless promotion of the existing
    /// `NormalizedROI` model, so a manually placed window is a valid target.
    init(roi: NormalizedROI) {
        let r = roi.cgRect
        self.init(topLeft: CGPoint(x: r.minX, y: r.minY),
                  topRight: CGPoint(x: r.maxX, y: r.minY),
                  bottomRight: CGPoint(x: r.maxX, y: r.maxY),
                  bottomLeft: CGPoint(x: r.minX, y: r.maxY))
    }

    /// Corners in winding order (TL → TR → BR → BL).
    var corners: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    /// The unit square — canonical screen space.
    static let canonical = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))

    /// Tightest axis-aligned box containing the quad. This is the bridge back
    /// to every existing `NormalizedROI` consumer (crop, Vision ROI, overlay).
    var boundingBox: NormalizedROI {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        return NormalizedROI(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    var center: CGPoint {
        CGPoint(x: corners.map(\.x).reduce(0, +) / 4,
                y: corners.map(\.y).reduce(0, +) / 4)
    }

    /// Shoelace area (always non-negative). Zero for a degenerate quad.
    var area: CGFloat {
        let p = corners
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// Mean of the two horizontal edge lengths — the display's apparent width.
    var meanWidth: CGFloat {
        (Self.distance(topLeft, topRight) + Self.distance(bottomLeft, bottomRight)) / 2
    }

    /// Mean of the two vertical edge lengths — the display's apparent height.
    var meanHeight: CGFloat {
        (Self.distance(topLeft, bottomLeft) + Self.distance(topRight, bottomRight)) / 2
    }

    var aspectRatio: CGFloat {
        meanHeight > 0 ? meanWidth / meanHeight : 0
    }

    /// In-plane rotation of the top edge, radians, positive clockwise on
    /// screen (y-down space).
    var rollAngle: CGFloat {
        atan2(topRight.y - topLeft.y, topRight.x - topLeft.x)
    }

    /// True when the quad is convex and non-degenerate — the precondition for
    /// a solvable homography. Detectors must reject anything else.
    var isConvex: Bool {
        guard area > 1e-9 else { return false }
        let p = corners
        var positive = false, negative = false
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if cross > 1e-12 { positive = true }
            if cross < -1e-12 { negative = true }
            if positive && negative { return false }
        }
        return positive != negative
    }

    /// Per-corner linear interpolation toward `other`. The smoothing primitive
    /// for magnetic attraction and tracker damping — corner-wise lerp keeps a
    /// convex quad convex, so intermediate frames stay solvable.
    func interpolated(toward other: ScreenQuad, t: CGFloat) -> ScreenQuad {
        let clampedT = min(max(t, 0), 1)
        func lerp(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * clampedT, y: a.y + (b.y - a.y) * clampedT)
        }
        return ScreenQuad(topLeft: lerp(topLeft, other.topLeft),
                          topRight: lerp(topRight, other.topRight),
                          bottomRight: lerp(bottomRight, other.bottomRight),
                          bottomLeft: lerp(bottomLeft, other.bottomLeft))
    }

    /// Mean corner-to-corner distance to `other` — the geometric distance
    /// metric used by snap proximity and tracker confidence.
    func meanCornerDistance(to other: ScreenQuad) -> CGFloat {
        zip(corners, other.corners)
            .map { Self.distance($0, $1) }
            .reduce(0, +) / 4
    }

    /// Intersection-over-union of the two bounding boxes. Cheap overlap signal
    /// for candidate matching and snap scoring.
    func boundingBoxIoU(with other: ScreenQuad) -> CGFloat {
        let a = boundingBox.cgRect, b = other.boundingBox.cgRect
        let intersection = a.intersection(b)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea: CGFloat = intersection.width * intersection.height
        let areaA: CGFloat = a.width * a.height
        let areaB: CGFloat = b.width * b.height
        let unionArea: CGFloat = areaA + areaB - intersectionArea
        return unionArea > 0 ? intersectionArea / unionArea : 0
    }

    /// Expands (or, with a negative amount, contracts) the quad about its
    /// center — used to pad a detected screen boundary before OCR.
    func expanded(by amount: CGFloat) -> ScreenQuad {
        let c = center
        func push(_ p: CGPoint) -> CGPoint {
            let dx = p.x - c.x, dy = p.y - c.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9 else { return p }
            return CGPoint(x: p.x + dx / length * amount, y: p.y + dy / length * amount)
        }
        return ScreenQuad(topLeft: push(topLeft), topRight: push(topRight),
                          bottomRight: push(bottomRight), bottomLeft: push(bottomLeft))
    }

    /// Rotates the corner labels so `topLeft` is the corner nearest the frame
    /// origin. Vision's rectangle detector reports corners in its own order;
    /// normalizing here keeps canonical space consistently oriented for
    /// upright displays. Not applied to tracked quads — an already-locked
    /// target must keep its labeling through rotation.
    func normalizedCornerOrder() -> ScreenQuad {
        let p = corners
        guard let startIndex = p.indices.min(by: { a, b in
            (p[a].x * p[a].x + p[a].y * p[a].y) < (p[b].x * p[b].x + p[b].y * p[b].y)
        }) else { return self }
        let rotated = (0..<4).map { p[(startIndex + $0) % 4] }
        return ScreenQuad(topLeft: rotated[0], topRight: rotated[1],
                          bottomRight: rotated[2], bottomLeft: rotated[3])
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// A 3×3 projective transform between two planes, row-major.
///
/// Solved by direct linear transform from exactly four point correspondences
/// (`m[8]` fixed at 1, leaving 8 unknowns and 8 equations). This is the
/// mathematical core of perspective normalization: warping a tilted display
/// back to a rectangle so field regions and OCR see a consistent image.
struct Homography: Equatable, Sendable {
    /// Row-major 3×3: [m0 m1 m2; m3 m4 m5; m6 m7 m8].
    let m: [CGFloat]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    init(m: [CGFloat]) {
        precondition(m.count == 9, "Homography requires 9 elements")
        self.m = m
    }

    /// Solves the transform taking `source` corners to `destination` corners.
    /// Returns nil when the system is singular (degenerate/non-convex quad) —
    /// callers treat that as "no usable geometry this frame" rather than
    /// crashing or producing garbage coordinates.
    static func solve(from source: ScreenQuad, to destination: ScreenQuad) -> Homography? {
        let s = source.corners, d = destination.corners
        // Two rows per correspondence; see the DLT derivation in the doc above.
        var a = [[CGFloat]](repeating: [CGFloat](repeating: 0, count: 9), count: 8)
        for i in 0..<4 {
            let x = s[i].x, y = s[i].y, u = d[i].x, v = d[i].y
            a[i * 2] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
            a[i * 2 + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
        }
        guard let h = solveLinearSystem(&a) else { return nil }
        return Homography(m: h + [1])
    }

    /// Maps `source` onto the unit square — the canonical screen transform.
    static func toCanonical(from source: ScreenQuad) -> Homography? {
        solve(from: source, to: .canonical)
    }

    /// Applies the transform to a point. Returns nil when the point maps to
    /// (or beyond) the horizon — w ≈ 0 means "behind the camera plane", which
    /// has no valid 2-D image position.
    func apply(_ p: CGPoint) -> CGPoint? {
        let w = m[6] * p.x + m[7] * p.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return CGPoint(x: (m[0] * p.x + m[1] * p.y + m[2]) / w,
                       y: (m[3] * p.x + m[4] * p.y + m[5]) / w)
    }

    /// Applies the transform to all four corners. Nil if any corner is
    /// unmappable.
    func apply(_ quad: ScreenQuad) -> ScreenQuad? {
        let mapped = quad.corners.compactMap(apply)
        guard mapped.count == 4 else { return nil }
        return ScreenQuad(topLeft: mapped[0], topRight: mapped[1],
                          bottomRight: mapped[2], bottomLeft: mapped[3])
    }

    /// Inverse transform (3×3 adjugate ÷ determinant); nil when singular.
    func inverted() -> Homography? {
        let a = m
        let c0 = a[4] * a[8] - a[5] * a[7]
        let c1 = a[5] * a[6] - a[3] * a[8]
        let c2 = a[3] * a[7] - a[4] * a[6]
        let det = a[0] * c0 + a[1] * c1 + a[2] * c2
        guard abs(det) > 1e-12 else { return nil }
        let inv: [CGFloat] = [
            c0 / det,
            (a[2] * a[7] - a[1] * a[8]) / det,
            (a[1] * a[5] - a[2] * a[4]) / det,
            c1 / det,
            (a[0] * a[8] - a[2] * a[6]) / det,
            (a[2] * a[3] - a[0] * a[5]) / det,
            c2 / det,
            (a[1] * a[6] - a[0] * a[7]) / det,
            (a[0] * a[4] - a[1] * a[3]) / det
        ]
        return Homography(m: inv)
    }

    /// Gaussian elimination with partial pivoting on an 8×9 augmented matrix.
    /// Returns the 8 unknowns, or nil if the system is singular.
    private static func solveLinearSystem(_ a: inout [[CGFloat]]) -> [CGFloat]? {
        let n = 8
        for col in 0..<n {
            // Partial pivot: largest magnitude in this column at/below the
            // diagonal, which is what keeps a near-degenerate quad from
            // producing wildly wrong coefficients instead of a clean nil.
            var pivotRow = col
            for row in (col + 1)..<n where abs(a[row][col]) > abs(a[pivotRow][col]) {
                pivotRow = row
            }
            guard abs(a[pivotRow][col]) > 1e-12 else { return nil }
            if pivotRow != col { a.swapAt(pivotRow, col) }

            let pivot = a[col][col]
            for k in col...n { a[col][k] /= pivot }
            for row in 0..<n where row != col {
                let factor = a[row][col]
                guard factor != 0 else { continue }
                for k in col...n { a[row][k] -= factor * a[col][k] }
            }
        }
        return (0..<n).map { a[$0][n] }
    }
}
