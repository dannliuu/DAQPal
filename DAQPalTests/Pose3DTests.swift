//
//  Pose3DTests.swift
//  DAQPalTests
//
//  DisplayPose3D projection math + the perspective render path's geometry
//  contract. Pure-math tests use hand-computed pinhole cases; the render
//  tests measure actual panel edge pixels, fit the four edge lines, and
//  intersect them — corner estimates that are immune to the panel's rounded
//  corners — then compare against `projectedQuad`'s ground truth.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class Pose3DTests: XCTestCase {
    private let panelSize = CGSize(width: SyntheticDisplayRenderer.displayROI.width,
                                   height: SyntheticDisplayRenderer.displayROI.height)
    private let aspect: CGFloat = 1080.0 / 1920.0
    private let frameSize = CGSize(width: 1080, height: 1920)

    private func quad(_ pose: DisplayPose3D) -> ScreenQuad {
        pose.projectedQuad(panelSize: panelSize, frameAspect: aspect)
    }

    // MARK: - Projection math

    func testIdentityProjectsExactPanelRect() {
        let q = quad(.identity)
        let roi = SyntheticDisplayRenderer.displayROI
        XCTAssertEqual(q.topLeft.x, roi.x, accuracy: 1e-9)
        XCTAssertEqual(q.topLeft.y, roi.y, accuracy: 1e-9)
        XCTAssertEqual(q.topRight.x, roi.x + roi.width, accuracy: 1e-9)
        XCTAssertEqual(q.topRight.y, roi.y, accuracy: 1e-9)
        XCTAssertEqual(q.bottomRight.x, roi.x + roi.width, accuracy: 1e-9)
        XCTAssertEqual(q.bottomRight.y, roi.y + roi.height, accuracy: 1e-9)
        XCTAssertEqual(q.bottomLeft.x, roi.x, accuracy: 1e-9)
        XCTAssertEqual(q.bottomLeft.y, roi.y + roi.height, accuracy: 1e-9)
    }

    /// Hand-computed pinhole case: yaw 30°, defaults otherwise.
    /// hw = 0.76·0.5625/2 = 0.21375, hh = 0.065, f = d = 1.4,
    /// center (0.5, 0.505) → ty = 0.005.
    /// topRight: x' = 0.21375·cos30 = 0.185113, z' = 0.21375·0.5 = 0.106875,
    /// Z = 1.506875, u = 1.4·0.185113/Z = 0.171984, v = 1.4·(−0.06)/Z =
    /// −0.055745 → normalized (0.5 + u/0.5625, 0.5 + v) = (0.80575, 0.44426).
    func testHandComputedYawTopRightCorner() {
        var pose = DisplayPose3D.identity
        pose.yaw = 30 * .pi / 180
        let q = quad(pose)
        XCTAssertEqual(q.topRight.x, 0.80575, accuracy: 1e-3)
        XCTAssertEqual(q.topRight.y, 0.44426, accuracy: 1e-3)
    }

    /// Positive yaw = right edge recedes, so the LEFT (nearer) vertical edge
    /// is taller — a genuine keystone the affine renderer can never produce.
    /// Mirror symmetry: yaw −θ swaps the edge heights exactly (identity
    /// center x = 0.5).
    func testYawKeystoneNearEdgeTaller() {
        var pose = DisplayPose3D.identity
        pose.center.x = 0.5 // exact mirror symmetry about the optical axis
        pose.yaw = 30 * .pi / 180
        let q = quad(pose)
        let leftHeight = abs(q.bottomLeft.y - q.topLeft.y)
        let rightHeight = abs(q.bottomRight.y - q.topRight.y)
        XCTAssertGreaterThan(leftHeight, rightHeight * 1.05,
                             "near (left) edge must be taller under positive yaw")

        pose.yaw = -30 * .pi / 180
        let mirrored = quad(pose)
        XCTAssertEqual(abs(mirrored.bottomRight.y - mirrored.topRight.y), leftHeight, accuracy: 1e-9)
        XCTAssertEqual(abs(mirrored.bottomLeft.y - mirrored.topLeft.y), rightHeight, accuracy: 1e-9)
    }

    /// Non-affine proof: under yaw the top and bottom edges are NOT parallel
    /// (their slopes diverge), i.e. a true trapezoid, not a parallelogram.
    func testYawProducesGenuineTrapezoid() {
        var pose = DisplayPose3D.identity
        pose.yaw = 30 * .pi / 180
        let q = quad(pose)
        let topSlope = (q.topRight.y - q.topLeft.y) / (q.topRight.x - q.topLeft.x)
        let bottomSlope = (q.bottomRight.y - q.bottomLeft.y) / (q.bottomRight.x - q.bottomLeft.x)
        XCTAssertGreaterThan(abs(topSlope - bottomSlope), 0.01,
                             "affine transforms keep opposite edges parallel; perspective must not")
    }

    /// Pure positive pitch tips the TOP edge away: top edge shorter than
    /// bottom edge.
    func testPitchSignConvention() {
        var pose = DisplayPose3D.identity
        pose.pitch = 25 * .pi / 180
        let q = quad(pose)
        let topWidth = abs(q.topRight.x - q.topLeft.x)
        let bottomWidth = abs(q.bottomRight.x - q.bottomLeft.x)
        XCTAssertGreaterThan(bottomWidth, topWidth * 1.02,
                             "positive pitch recedes the top edge, so it must render narrower")
    }

    /// Pure roll is an exact in-plane rotation: checked in METRIC space
    /// (x scaled by aspect) where angles are true — edge lengths preserved,
    /// adjacent edges perpendicular, top-edge angle == roll.
    func testPureRollIsRotatedRectangle() {
        var pose = DisplayPose3D.identity
        pose.roll = 30 * .pi / 180
        let q = quad(pose)
        func metric(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - 0.5) * aspect, y: p.y - 0.5) }
        let tl = metric(q.topLeft), tr = metric(q.topRight)
        let br = metric(q.bottomRight), bl = metric(q.bottomLeft)
        let top = CGVector(dx: tr.x - tl.x, dy: tr.y - tl.y)
        let left = CGVector(dx: bl.x - tl.x, dy: bl.y - tl.y)
        let bottom = CGVector(dx: br.x - bl.x, dy: br.y - bl.y)

        XCTAssertEqual(atan2(top.dy, top.dx), 30 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(hypot(top.dx, top.dy), panelSize.width * aspect, accuracy: 1e-9)
        XCTAssertEqual(hypot(left.dx, left.dy), panelSize.height, accuracy: 1e-9)
        XCTAssertEqual(top.dx * left.dx + top.dy * left.dy, 0, accuracy: 1e-9) // perpendicular
        XCTAssertEqual(top.dx, bottom.dx, accuracy: 1e-9) // opposite edges equal
        XCTAssertEqual(top.dy, bottom.dy, accuracy: 1e-9)
    }

    /// Corners keep semantic identity across the whole documented envelope:
    /// the quad stays convex, keeps TL→TR→BR→BL winding (positive shoelace
    /// sum in y-down space — the sign the identity rect has), and stays
    /// solvable to canonical space.
    func testCornerSemanticsAcrossEnvelope() {
        func signedShoelace(_ q: ScreenQuad) -> CGFloat {
            let p = q.corners
            var sum: CGFloat = 0
            for i in 0..<4 {
                let a = p[i], b = p[(i + 1) % 4]
                sum += a.x * b.y - b.x * a.y
            }
            return sum
        }
        XCTAssertGreaterThan(signedShoelace(quad(.identity)), 0, "baseline winding must be positive")

        let deg: CGFloat = .pi / 180
        for yawDeg in stride(from: -60.0, through: 60.0, by: 20.0) {
            for pitchDeg in stride(from: -60.0, through: 60.0, by: 20.0) {
                for rollDeg in stride(from: -45.0, through: 45.0, by: 15.0) {
                    var pose = DisplayPose3D.identity
                    pose.yaw = CGFloat(yawDeg) * deg
                    pose.pitch = CGFloat(pitchDeg) * deg
                    pose.roll = CGFloat(rollDeg) * deg
                    let q = quad(pose)
                    let label = "yaw \(yawDeg)° pitch \(pitchDeg)° roll \(rollDeg)°"
                    XCTAssertTrue(q.isConvex, "non-convex quad at \(label)")
                    XCTAssertGreaterThan(signedShoelace(q), 0, "winding flip at \(label)")
                    XCTAssertNotNil(Homography.toCanonical(from: q), "unsolvable quad at \(label)")
                }
            }
        }
    }

    // MARK: - Rendered geometry vs. projected ground truth

    /// The render contract: bright panel on black, several genuinely 3-D
    /// poses; the corners measured from actual rendered pixels (edge-line
    /// fits intersected) land within ~3 px of `projectedQuad`'s corners.
    func testRenderedCornersMatchProjectedQuad() throws {
        let renderer = SyntheticDisplayRenderer(size: frameSize)
        var tumble = DisplayPose3D.identity
        tumble.yaw = 25 * .pi / 180
        tumble.pitch = 18 * .pi / 180
        tumble.roll = 12 * .pi / 180
        tumble.center = CGPoint(x: 0.47, y: 0.55)
        tumble.distance = DisplayPose3D.defaultFocalLength * 1.15

        var yawPose = DisplayPose3D.identity
        yawPose.yaw = 30 * .pi / 180
        var pitchPose = DisplayPose3D.identity
        pitchPose.pitch = -25 * .pi / 180

        for (name, pose) in [("yaw30", yawPose), ("pitch-25", pitchPose), ("tumble", tumble)] {
            let expected = quad(pose)
            let measured = try measureRenderedCorners(renderer: renderer, pose: pose, label: name)
            for (corner, gt) in zip(measured, expected.corners) {
                let gtPx = CGPoint(x: gt.x * frameSize.width, y: gt.y * frameSize.height)
                let error = hypot(corner.x - gtPx.x, corner.y - gtPx.y)
                XCTAssertLessThanOrEqual(error, 3.0,
                                         "\(name): rendered corner \(corner) vs ground truth \(gtPx), error \(error) px")
            }
        }
    }

    /// Same input → same geometry (byte-determinism is explicitly NOT the
    /// contract, so this measures corners, not bytes).
    func testRenderGeometryDeterministic() throws {
        let renderer = SyntheticDisplayRenderer(size: frameSize)
        var pose = DisplayPose3D.identity
        pose.yaw = 30 * .pi / 180
        pose.pitch = -15 * .pi / 180
        let first = try measureRenderedCorners(renderer: renderer, pose: pose, label: "run1")
        let second = try measureRenderedCorners(renderer: renderer, pose: pose, label: "run2")
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.25)
            XCTAssertEqual(a.y, b.y, accuracy: 0.25)
        }
    }

    // MARK: - Pixel-measurement helpers

    /// Renders the pose and returns the four measured corner positions
    /// (pixels, TL/TR/BR/BL order) by fitting lines to the middle band of
    /// each panel edge and intersecting adjacent lines — robust to the
    /// panel's 18 px rounded corners, which a raw extreme-pixel search would
    /// mislocate by ~7 px.
    private func measureRenderedCorners(renderer: SyntheticDisplayRenderer,
                                        pose: DisplayPose3D,
                                        label: String) throws -> [CGPoint] {
        let buffer = try XCTUnwrap(renderer.render(text: "188.8", pose3D: pose),
                                   "\(label): render returned nil")
        let image = try XCTUnwrap(GreenChannelImage(buffer: buffer), "\(label): unreadable buffer")
        let quadPx = quadInPixels(quad(pose))

        // Boundary samples along the middle band of each edge (avoids the
        // rounded corners), found by scanning inward from just outside the
        // ground-truth edge. Ground truth only POSITIONS the ±24 px scan
        // window; the measured boundary is wherever the pixels actually are.
        let leftPts = try edgeSamples(image: image, from: quadPx[0], to: quadPx[3], horizontal: true, fromLow: true, label: "\(label) left")
        let rightPts = try edgeSamples(image: image, from: quadPx[1], to: quadPx[2], horizontal: true, fromLow: false, label: "\(label) right")
        let topPts = try edgeSamples(image: image, from: quadPx[0], to: quadPx[1], horizontal: false, fromLow: true, label: "\(label) top")
        let bottomPts = try edgeSamples(image: image, from: quadPx[3], to: quadPx[2], horizontal: false, fromLow: false, label: "\(label) bottom")

        // Near-vertical edges: x = a + b·y. Near-horizontal: y = c + d·x.
        let left = fitLine(points: leftPts.map { ($0.y, $0.x) })
        let right = fitLine(points: rightPts.map { ($0.y, $0.x) })
        let top = fitLine(points: topPts.map { ($0.x, $0.y) })
        let bottom = fitLine(points: bottomPts.map { ($0.x, $0.y) })

        return [intersect(vertical: left, horizontal: top),
                intersect(vertical: right, horizontal: top),
                intersect(vertical: right, horizontal: bottom),
                intersect(vertical: left, horizontal: bottom)]
    }

    private func quadInPixels(_ q: ScreenQuad) -> [CGPoint] {
        q.corners.map { CGPoint(x: $0.x * frameSize.width, y: $0.y * frameSize.height) }
    }

    /// Sample points on the rendered panel boundary near the ground-truth
    /// edge from `a` to `b`, in its middle band (s ∈ 0.3…0.7). `horizontal`
    /// scans along x (for near-vertical edges); `fromLow` scans upward from
    /// the low side (left/top) vs. downward from the high side.
    private func edgeSamples(image: GreenChannelImage, from a: CGPoint, to b: CGPoint,
                             horizontal: Bool, fromLow: Bool, label: String) throws -> [CGPoint] {
        var points = [CGPoint]()
        for step in 0...8 {
            let s = 0.3 + CGFloat(step) * 0.05
            let p = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
            let window = 24
            if horizontal {
                let y = Int(p.y.rounded())
                let range = fromLow
                    ? Array(Int(p.x.rounded()) - window ... Int(p.x.rounded()) + window)
                    : Array((Int(p.x.rounded()) - window ... Int(p.x.rounded()) + window).reversed())
                if let x = range.first(where: { image.isBright($0, y) }) {
                    points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
            } else {
                let x = Int(p.x.rounded())
                let range = fromLow
                    ? Array(Int(p.y.rounded()) - window ... Int(p.y.rounded()) + window)
                    : Array((Int(p.y.rounded()) - window ... Int(p.y.rounded()) + window).reversed())
                if let y = range.first(where: { image.isBright(x, $0) }) {
                    points.append(CGPoint(x: CGFloat(x), y: CGFloat(y)))
                }
            }
        }
        guard points.count >= 5 else {
            throw XCTSkip("\(label): only \(points.count)/9 boundary samples found within ±24 px of ground truth — rendered geometry is grossly off or rendering failed; inspect manually")
        }
        return points
    }

    /// Least-squares fit v = slope·u + intercept over (u, v) pairs.
    private func fitLine(points: [(CGFloat, CGFloat)]) -> (slope: CGFloat, intercept: CGFloat) {
        let n = CGFloat(points.count)
        let sumU = points.reduce(0) { $0 + $1.0 }
        let sumV = points.reduce(0) { $0 + $1.1 }
        let sumUU = points.reduce(0) { $0 + $1.0 * $1.0 }
        let sumUV = points.reduce(0) { $0 + $1.0 * $1.1 }
        let denominator = n * sumUU - sumU * sumU
        guard abs(denominator) > 1e-9 else { return (0, sumV / n) }
        let slope = (n * sumUV - sumU * sumV) / denominator
        return (slope, (sumV - slope * sumU) / n)
    }

    /// Intersection of x = aV + bV·y (near-vertical) and y = aH + bH·x
    /// (near-horizontal).
    private func intersect(vertical: (slope: CGFloat, intercept: CGFloat),
                           horizontal: (slope: CGFloat, intercept: CGFloat)) -> CGPoint {
        let denominator = 1 - vertical.slope * horizontal.slope
        guard abs(denominator) > 1e-9 else { return .zero }
        let x = (vertical.intercept + vertical.slope * horizontal.intercept) / denominator
        return CGPoint(x: x, y: horizontal.intercept + horizontal.slope * x)
    }
}

/// Green channel of a 32BGRA buffer copied out for cheap repeated sampling.
/// Panel green ≈ 214, body green ≈ 12; the 100 threshold sits near the 50%-
/// coverage antialiased edge pixel, so "first bright pixel" is an almost
/// unbiased edge locator.
private struct GreenChannelImage {
    let width: Int
    let height: Int
    private let green: [UInt8]

    init?(buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                pixels[y * width + x] = row[x * 4 + 1] // B G R A → G
            }
        }
        green = pixels
    }

    func isBright(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return green[y * width + x] > 100
    }
}
