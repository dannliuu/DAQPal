//
//  OverlayGeometryTests.swift
//  DAQPalTests
//
//  Spec §8A / Gate 6A: the lock overlay must be SCREEN-relative — it wraps the
//  tracked quadrilateral, keystones under yaw/pitch, rotates under roll, scales
//  with distance, keeps corner identity through a full turn, and refuses to
//  draw degenerate geometry.
//
//  Everything here is pure geometry on `OverlayQuadGeometry` / `LockRenderStyle`
//  — no SwiftUI rendering, no Vision, no camera. Ground truth comes from
//  `DemoMotionModel`/`DisplayPose` and is cross-checked against
//  `SyntheticDisplayRenderer.panelROI(for:)`, the renderer's own published
//  bounding box, so the test's idea of "where the panel is" cannot silently
//  drift from what the renderer actually draws.
//
//  Deterministic: synthetic `t = i/fps`, no `Date()`, no sleeps, no randomness.
//

import CoreGraphics
import SwiftUI
import XCTest
@testable import DAQPal

final class OverlayGeometryTests: XCTestCase {

    // MARK: Fixtures

    private let frameSize = CGSize(width: 1080, height: 1920)
    private let renderer = SyntheticDisplayRenderer(size: CGSize(width: 1080, height: 1920))

    /// Deliberately a DIFFERENT aspect ratio than the content, so aspect-fill
    /// genuinely crops. A mapping bug cannot hide behind an incidental 1:1 map.
    private let containerSize = CGSize(width: 390, height: 700)

    private var mapper: AspectFillMapper {
        AspectFillMapper(contentSize: frameSize, containerSize: containerSize)
    }

    private let fps: Double = 12
    private var dt: TimeInterval { 1.0 / fps }

    /// Aspect-fill math written out independently of `AspectFillMapper`, so the
    /// expected view points are not produced by the code under test.
    private func expectedViewPoint(_ p: CGPoint) -> CGPoint {
        let s = max(containerSize.width / frameSize.width, containerSize.height / frameSize.height)
        let originX = (containerSize.width - frameSize.width * s) / 2
        let originY = (containerSize.height - frameSize.height * s) / 2
        return CGPoint(x: p.x * frameSize.width * s + originX,
                       y: p.y * frameSize.height * s + originY)
    }

    /// The panel's four corners as the renderer draws them for `pose`, in
    /// normalized top-left-origin frame space.
    ///
    /// Mirrors `SyntheticDisplayRenderer.drawPose`: half-extents scaled by the
    /// foreshortening/apparent-size factors, rotated by `roll` in the renderer's
    /// flipped (y-down) context, translated to `pose.center`.
    /// `assertGroundTruthAgreesWithRenderer` pins this against `panelROI(for:)`.
    private func groundTruthQuad(for pose: DisplayPose) -> ScreenQuad {
        let base = SyntheticDisplayRenderer.displayROI.pixelRect(in: frameSize)
        let combinedScale = max(pose.scale, 0.05)
        let halfWidth = base.width / 2 * max(pose.yawScale, 0.05) * combinedScale
        let halfHeight = base.height / 2 * max(pose.pitchScale, 0.05) * combinedScale
        let center = CGPoint(x: pose.center.x * frameSize.width, y: pose.center.y * frameSize.height)
        let cosR = cos(pose.roll), sinR = sin(pose.roll)
        func corner(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint {
            CGPoint(x: (center.x + dx * cosR - dy * sinR) / frameSize.width,
                    y: (center.y + dx * sinR + dy * cosR) / frameSize.height)
        }
        return ScreenQuad(topLeft: corner(-halfWidth, -halfHeight),
                          topRight: corner(halfWidth, -halfHeight),
                          bottomRight: corner(halfWidth, halfHeight),
                          bottomLeft: corner(-halfWidth, halfHeight))
    }

    private func target(_ quad: ScreenQuad) -> TrackedTarget {
        TrackedTarget(quad: quad, detectionConfidence: 1)
    }

    // MARK: Assertions

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint, accuracy: CGFloat,
                             _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "\(message) — x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "\(message) — y", file: file, line: line)
    }

    /// Pins `groundTruthQuad` to the renderer's own published ROI.
    ///
    /// Two documented exclusions, both properties of `panelROI(for:)` rather
    /// than of the overlay:
    ///  * `pose == .identity` takes an early-out that returns the *un-rounded*
    ///    `displayROI`, while every other path goes through
    ///    `pixelRect(in:)`, which returns an INTEGRAL rect. The two differ by
    ///    up to a pixel — see `testIdentityPose_matchesTheRenderersStaticROI`.
    ///  * poses whose panel leaves the frame, since `panelROI` clamps and the
    ///    quad deliberately does not.
    private func assertGroundTruthAgreesWithRenderer(_ pose: DisplayPose, _ label: String,
                                                     file: StaticString = #filePath, line: UInt = #line) {
        guard pose != .identity else { return }
        let box = groundTruthQuad(for: pose).boundingBox
        guard box.x >= 0, box.y >= 0, box.x + box.width <= 1, box.y + box.height <= 1 else { return }
        let panel = renderer.panelROI(for: pose)
        XCTAssertEqual(box.x, panel.x, accuracy: 1e-9, "\(label) — bbox x", file: file, line: line)
        XCTAssertEqual(box.y, panel.y, accuracy: 1e-9, "\(label) — bbox y", file: file, line: line)
        XCTAssertEqual(box.width, panel.width, accuracy: 1e-9, "\(label) — bbox width", file: file, line: line)
        XCTAssertEqual(box.height, panel.height, accuracy: 1e-9, "\(label) — bbox height", file: file, line: line)
    }

    /// The overlay must project every semantic corner to exactly where the
    /// aspect-fill mapping puts it — vertex-for-vertex, in order.
    private func assertOverlayWrapsPanel(at pose: DisplayPose, _ label: String,
                                         file: StaticString = #filePath, line: UInt = #line) {
        assertGroundTruthAgreesWithRenderer(pose, label, file: file, line: line)
        let truth = groundTruthQuad(for: pose)
        guard let corners = OverlayQuadGeometry.viewCorners(of: target(truth).quad, mapper: mapper) else {
            XCTFail("\(label): a drawable panel quad was rejected", file: file, line: line)
            return
        }
        XCTAssertEqual(corners.count, 4, label, file: file, line: line)
        let names = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        for i in 0..<4 {
            assertPoint(corners[i], expectedViewPoint(truth.corners[i]), accuracy: 1e-6,
                        "\(label) — \(names[i])", file: file, line: line)
        }
    }

    // MARK: - Ground-truth chain

    /// The unmoved panel must sit on `displayROI`, within the one-pixel rounding
    /// `NormalizedROI.pixelRect(in:)` introduces (`raw.integral`). This is the
    /// anchor for every sweep below: if this drifts, so does everything else.
    func testIdentityPose_matchesTheRenderersStaticROI() {
        let box = groundTruthQuad(for: .identity).boundingBox
        let roi = SyntheticDisplayRenderer.displayROI
        let pixelX = 1 / frameSize.width, pixelY = 1 / frameSize.height
        XCTAssertEqual(box.x, roi.x, accuracy: pixelX)
        XCTAssertEqual(box.y, roi.y, accuracy: pixelY)
        XCTAssertEqual(box.width, roi.width, accuracy: 2 * pixelX)
        XCTAssertEqual(box.height, roi.height, accuracy: 2 * pixelY)
        XCTAssertEqual(renderer.panelROI(for: .identity), roi,
                       "the renderer's identity fast path returns displayROI verbatim")
    }

    // MARK: - 1. Yaw sweep

    func testProjectedVertices_matchPanelCorners_acrossYawSweep() {
        var model = DemoMotionModel()
        model.mode = .yaw
        var sawStrongForeshortening = false
        for i in 0..<Int(8 * fps) {
            let pose = model.pose(at: Double(i) * dt, dt: dt)
            assertOverlayWrapsPanel(at: pose, "yaw frame \(i)")
            if pose.yawScale < 0.7 { sawStrongForeshortening = true }
        }
        XCTAssertTrue(sawStrongForeshortening,
                      "the yaw sweep must actually reach strong foreshortening, or this test proves nothing")
    }

    func testYaw_shrinksApparentWidthOnly() {
        let flat = DisplayPose(center: DemoMotionModel.homeCenter, roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        let yawed = DisplayPose(center: DemoMotionModel.homeCenter, roll: 0, yawScale: 0.5, pitchScale: 1, scale: 1)
        let a = groundTruthQuad(for: flat), b = groundTruthQuad(for: yawed)
        XCTAssertEqual(b.meanWidth, a.meanWidth * 0.5, accuracy: 1e-9)
        XCTAssertEqual(b.meanHeight, a.meanHeight, accuracy: 1e-9)
        XCTAssertNotNil(OverlayQuadGeometry.viewCorners(of: b, mapper: mapper))
    }

    // MARK: - 2. Pitch, roll and scale sweeps

    func testProjectedVertices_matchPanelCorners_acrossPitchSweep() {
        var model = DemoMotionModel()
        model.mode = .pitch
        var sawStrongForeshortening = false
        for i in 0..<Int(8 * fps) {
            let pose = model.pose(at: Double(i) * dt, dt: dt)
            assertOverlayWrapsPanel(at: pose, "pitch frame \(i)")
            if pose.pitchScale < 0.7 { sawStrongForeshortening = true }
        }
        XCTAssertTrue(sawStrongForeshortening, "the pitch sweep must reach strong foreshortening")
    }

    func testProjectedVertices_matchPanelCorners_acrossRollSweep() {
        var model = DemoMotionModel()
        model.mode = .roll
        var sawRotation = false
        for i in 0..<Int(10 * fps) {
            let pose = model.pose(at: Double(i) * dt, dt: dt)
            assertOverlayWrapsPanel(at: pose, "roll frame \(i)")
            if abs(pose.roll) > DemoMotionModel.maxRollAngle * 0.8 { sawRotation = true }
        }
        XCTAssertTrue(sawRotation, "the roll sweep must reach near-peak rotation")
    }

    func testProjectedVertices_matchPanelCorners_acrossScaleSweep() {
        var model = DemoMotionModel()
        model.mode = .scale
        var minScale = CGFloat.greatestFiniteMagnitude
        var maxScale: CGFloat = 0
        for i in 0..<Int(12 * fps) {
            let pose = model.pose(at: Double(i) * dt, dt: dt)
            assertOverlayWrapsPanel(at: pose, "scale frame \(i)")
            minScale = min(minScale, pose.scale)
            maxScale = max(maxScale, pose.scale)
        }
        XCTAssertLessThan(minScale, 0.7, "the scale sweep must zoom out meaningfully")
        XCTAssertGreaterThan(maxScale, 1.2, "the scale sweep must zoom in meaningfully")
    }

    func testScale_preservesApparentAspectRatio() {
        let base = DisplayPose(center: DemoMotionModel.homeCenter, roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        let baseAspect = groundTruthQuad(for: base).aspectRatio
        for s in [CGFloat(0.5), 0.8, 1.2, 1.4] {
            var pose = base
            pose.scale = s
            let quad = groundTruthQuad(for: pose)
            XCTAssertEqual(quad.aspectRatio, baseAspect, accuracy: 1e-9,
                           "apparent aspect ratio must survive a pure distance change (scale \(s))")
            guard let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) else {
                XCTFail("scale \(s) rejected"); continue
            }
            let bounds = OverlayQuadGeometry.boundingRect(corners)
            XCTAssertEqual(bounds.width / bounds.height,
                           baseAspect * frameSize.width / frameSize.height, accuracy: 1e-6,
                           "view-space extent must scale uniformly (scale \(s))")
        }
    }

    // MARK: - Mapping-path parity with ROISelectionOverlay

    /// `TargetGeometryOverlay`, `FieldSelectionOverlay` and `ROISelectionOverlay`
    /// must all go through the same `AspectFillMapper` math. A divergence would
    /// offset one overlay in exactly one capture mode — the hardest class of bug
    /// to see in a screenshot.
    func testAxisAlignedQuad_projectsToTheSameRectROISelectionOverlayWouldDraw() {
        let roi = NormalizedROI(x: 0.2, y: 0.3, width: 0.4, height: 0.25)
        let quad = ScreenQuad(roi: roi)
        guard let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) else {
            return XCTFail("axis-aligned quad must be drawable")
        }
        let roiRect = mapper.viewRect(fromNormalized: roi)
        assertPoint(corners[0], CGPoint(x: roiRect.minX, y: roiRect.minY), accuracy: 1e-9, "topLeft")
        assertPoint(corners[1], CGPoint(x: roiRect.maxX, y: roiRect.minY), accuracy: 1e-9, "topRight")
        assertPoint(corners[2], CGPoint(x: roiRect.maxX, y: roiRect.maxY), accuracy: 1e-9, "bottomRight")
        assertPoint(corners[3], CGPoint(x: roiRect.minX, y: roiRect.maxY), accuracy: 1e-9, "bottomLeft")
    }

    // MARK: - 3. Proof of shear

    /// A rolled target's outline must NOT be axis-aligned. An implementation
    /// that had regressed to drawing `quad.boundingBox` would pass a
    /// translation-only test and fail this one.
    func testRolledTarget_outlineIsNotAxisAligned() {
        let pose = DisplayPose(center: DemoMotionModel.homeCenter,
                               roll: 12 * .pi / 180, yawScale: 1, pitchScale: 1, scale: 1)
        let quad = groundTruthQuad(for: pose)

        XCTAssertFalse(OverlayQuadGeometry.isAxisAligned(quad, toleranceDegrees: 2),
                       "a 12° rolled quad must not read as axis-aligned")
        for angle in OverlayQuadGeometry.edgeAnglesDegrees(quad) {
            let folded = abs(angle.truncatingRemainder(dividingBy: 90))
            XCTAssertGreaterThan(min(folded, 90 - folded), 2,
                                 "every edge must be more than 2° off the axes, got \(angle)°")
        }

        // And the projected vertices must differ from the bounding box's.
        guard let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) else {
            return XCTFail("rolled quad must be drawable")
        }
        let box = OverlayQuadGeometry.boundingRect(corners)
        let boxCorners = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                          CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        let maxDeviation = (0..<4).map { ScreenQuad.distance(corners[$0], boxCorners[$0]) }.max() ?? 0
        XCTAssertGreaterThan(maxDeviation, 4,
                             "projected vertices must be visibly distinct from the bounding box corners")
        // The bounding box also over-covers, which is why it is wrong to draw.
        XCTAssertLessThan(quad.area, quad.boundingBox.width * quad.boundingBox.height * 0.98)
    }

    /// A genuine keystone (perspective, not affine) has NON-PARALLEL opposite
    /// edges. Any bounding-box or parallelogram approximation fails this.
    func testKeystonedTarget_opposingEdgesAreNonParallel() {
        let quad = ScreenQuad(topLeft: CGPoint(x: 0.30, y: 0.40),
                              topRight: CGPoint(x: 0.70, y: 0.42),
                              bottomRight: CGPoint(x: 0.78, y: 0.62),
                              bottomLeft: CGPoint(x: 0.22, y: 0.60))
        XCTAssertTrue(quad.isConvex)
        XCTAssertNotNil(OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper))
        XCTAssertFalse(OverlayQuadGeometry.isAxisAligned(quad, toleranceDegrees: 2))

        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat {
            let u = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let v = CGPoint(x: d.x - c.x, y: d.y - c.y)
            return u.x * v.y - u.y * v.x
        }
        XCTAssertGreaterThan(abs(cross(quad.topLeft, quad.topRight, quad.bottomLeft, quad.bottomRight)), 1e-3,
                             "top and bottom edges must converge (keystone), not stay parallel")
        XCTAssertGreaterThan(abs(cross(quad.topLeft, quad.bottomLeft, quad.topRight, quad.bottomRight)), 1e-3,
                             "left and right edges must converge (keystone), not stay parallel")
    }

    /// Corner brackets are drawn ALONG the projected edges, so they shear with
    /// the quad instead of reading as axis-aligned ticks.
    func testCornerBrackets_lieOnTheProjectedEdges() {
        let pose = DisplayPose(center: DemoMotionModel.homeCenter,
                               roll: 25 * .pi / 180, yawScale: 0.6, pitchScale: 1, scale: 1)
        guard let corners = OverlayQuadGeometry.viewCorners(of: groundTruthQuad(for: pose), mapper: mapper) else {
            return XCTFail("quad must be drawable")
        }
        let segments = OverlayQuadGeometry.bracketSegments(corners, fraction: 0.2)
        XCTAssertEqual(segments.count, 8, "two segments per corner")
        for (index, segment) in segments.enumerated() {
            let cornerIndex = index / 2
            let neighbor = index.isMultiple(of: 2)
                ? corners[(cornerIndex + 1) % 4]
                : corners[(cornerIndex + 3) % 4]
            assertPoint(segment.0, corners[cornerIndex], accuracy: 1e-9, "segment \(index) start")
            let expectedEnd = CGPoint(x: corners[cornerIndex].x + (neighbor.x - corners[cornerIndex].x) * 0.2,
                                      y: corners[cornerIndex].y + (neighbor.y - corners[cornerIndex].y) * 0.2)
            assertPoint(segment.1, expectedEnd, accuracy: 1e-9, "segment \(index) end")
            // Non-axis-aligned: the bracket inherits the sheared edge direction.
            let dx = segment.1.x - segment.0.x, dy = segment.1.y - segment.0.y
            XCTAssertGreaterThan(abs(dx) + abs(dy), 0.5, "segment \(index) must have length")
            XCTAssertGreaterThan(min(abs(dx), abs(dy)), 1e-6,
                                 "segment \(index) must be oblique, i.e. following the rotated edge")
        }
    }

    // MARK: - 4. Corner identity through a full rotation

    /// Through 0–360° the marker drawn at the display's top-left must stay on
    /// the display's top-left. The failure mode this guards is a naive
    /// nearest-to-frame-origin relabel, which swaps vertices past ~45°.
    func testCornerIdentity_isStableThroughFullRotationSweep() {
        let stepDegrees: CGFloat = 3
        let base = SyntheticDisplayRenderer.displayROI.pixelRect(in: frameSize)
        // Corner orbit radius, converted to view points: the largest legitimate
        // per-step movement is the chord of that circle over one step.
        let s = max(containerSize.width / frameSize.width, containerSize.height / frameSize.height)
        let radius = (base.width * base.width + base.height * base.height).squareRoot() / 2 * s
        let maxStep = 2 * radius * sin(stepDegrees * .pi / 180 / 2) * 1.05

        var previous: [CGPoint]?
        var sawNaiveRelabel = false

        for degrees in stride(from: CGFloat(0), through: 360, by: stepDegrees) {
            let pose = DisplayPose(center: DemoMotionModel.homeCenter,
                                   roll: degrees * .pi / 180, yawScale: 1, pitchScale: 1, scale: 1)
            let quad = groundTruthQuad(for: pose)
            guard let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) else {
                XCTFail("quad at \(degrees)° must be drawable"); continue
            }

            // Identity: vertex n is semantic corner n, at every angle.
            for i in 0..<4 {
                assertPoint(corners[i], expectedViewPoint(quad.corners[i]), accuracy: 1e-6,
                            "corner \(i) at \(degrees)°")
            }

            // Continuity: no vertex may jump further than one step's arc.
            if let previous {
                for i in 0..<4 {
                    XCTAssertLessThanOrEqual(ScreenQuad.distance(previous[i], corners[i]), maxStep,
                                             "corner \(i) jumped between \(degrees - stepDegrees)° and \(degrees)° — vertices swapped")
                }
            }
            previous = corners

            // Evidence that the naive rule really would have swapped here.
            if quad.normalizedCornerOrder().topLeft != quad.topLeft { sawNaiveRelabel = true }
        }

        XCTAssertTrue(sawNaiveRelabel,
                      "the sweep must pass through angles where a nearest-to-origin rule relabels, otherwise the continuity assertion is vacuous")
    }

    // MARK: - 5. Degenerate and non-convex rejection

    func testNonConvexQuad_isRejectedNotDrawn() {
        // Bow-tie: the classic self-intersecting projection.
        let bowtie = ScreenQuad(topLeft: CGPoint(x: 0.2, y: 0.2),
                                topRight: CGPoint(x: 0.8, y: 0.8),
                                bottomRight: CGPoint(x: 0.8, y: 0.2),
                                bottomLeft: CGPoint(x: 0.2, y: 0.8))
        XCTAssertFalse(bowtie.isConvex)
        XCTAssertFalse(OverlayQuadGeometry.isDrawable(bowtie))
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: bowtie, mapper: mapper))
    }

    func testDegenerateQuads_areRejected() {
        let collapsed = ScreenQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: collapsed, mapper: mapper), "zero-area quad")

        let collinear = ScreenQuad(topLeft: CGPoint(x: 0.1, y: 0.5),
                                   topRight: CGPoint(x: 0.4, y: 0.5),
                                   bottomRight: CGPoint(x: 0.7, y: 0.5),
                                   bottomLeft: CGPoint(x: 0.9, y: 0.5))
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: collinear, mapper: mapper), "collinear quad")

        let sliver = ScreenQuad(topLeft: CGPoint(x: 0.5, y: 0.5),
                                topRight: CGPoint(x: 0.5 + 1e-6, y: 0.5),
                                bottomRight: CGPoint(x: 0.5 + 1e-6, y: 0.5 + 1e-6),
                                bottomLeft: CGPoint(x: 0.5, y: 0.5 + 1e-6))
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: sliver, mapper: mapper), "sub-threshold sliver")

        let notFinite = ScreenQuad(topLeft: CGPoint(x: .nan, y: 0.2),
                                   topRight: CGPoint(x: 0.8, y: 0.2),
                                   bottomRight: CGPoint(x: 0.8, y: 0.8),
                                   bottomLeft: CGPoint(x: 0.2, y: 0.8))
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: notFinite, mapper: mapper), "non-finite corner")

        let infinite = ScreenQuad(topLeft: CGPoint(x: 0.2, y: 0.2),
                                  topRight: CGPoint(x: .infinity, y: 0.2),
                                  bottomRight: CGPoint(x: 0.8, y: 0.8),
                                  bottomLeft: CGPoint(x: 0.2, y: 0.8))
        XCTAssertNil(OverlayQuadGeometry.viewCorners(of: infinite, mapper: mapper), "infinite corner")
    }

    func testDegenerateTarget_yieldsNoFieldQuad() {
        let collapsed = ScreenQuad(topLeft: .zero, topRight: .zero, bottomRight: .zero, bottomLeft: .zero)
        let region = NormalizedROI(x: 0.1, y: 0.1, width: 0.3, height: 0.2)
        XCTAssertNil(OverlayQuadGeometry.projectedFieldQuad(region, in: target(collapsed)),
                     "a target with no solvable homography must project no field outline")
    }

    func testZeroSizedContainer_doesNotProduceNonFinitePoints() {
        let degenerateMapper = AspectFillMapper(contentSize: frameSize, containerSize: .zero)
        let quad = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: degenerateMapper)
        XCTAssertNotNil(corners)
        for p in corners ?? [] {
            XCTAssertTrue(p.x.isFinite && p.y.isFinite, "mapping must never emit a non-finite point")
        }
    }

    // MARK: - 6. Field regions project to quads, not boxes

    /// The field outline must be the projected QUAD. Under rotation that quad's
    /// area is strictly smaller than its axis-aligned bounding box — which is
    /// exactly what `ScreenField.frameRegion(in:)` returns, and exactly why the
    /// overlay must not use it for drawing.
    func testFieldRegion_projectsToQuadSmallerThanItsBoundingBox() {
        let pose = DisplayPose(center: DemoMotionModel.homeCenter,
                               roll: 30 * .pi / 180, yawScale: 1, pitchScale: 1, scale: 1)
        let tracked = target(groundTruthQuad(for: pose))
        let region = NormalizedROI(x: 0.10, y: 0.20, width: 0.35, height: 0.45)

        guard let quad = OverlayQuadGeometry.projectedFieldQuad(region, in: tracked) else {
            return XCTFail("a rotated field region must still project to a drawable quad")
        }
        let box = quad.boundingBox
        let boxArea = box.width * box.height
        XCTAssertGreaterThan(boxArea, 0)
        XCTAssertLessThan(quad.area, boxArea * 0.95,
                          "the projected quad must be materially smaller than its bounding box under rotation")

        // The bounding box is precisely what the OCR-facing API hands back.
        let field = ScreenField(region: region)
        guard let frameROI = field.frameRegion(in: tracked) else {
            return XCTFail("frameRegion must resolve for a solvable target")
        }
        XCTAssertEqual(frameROI.x, box.x, accuracy: 1e-9)
        XCTAssertEqual(frameROI.y, box.y, accuracy: 1e-9)
        XCTAssertEqual(frameROI.width, box.width, accuracy: 1e-9)
        XCTAssertEqual(frameROI.height, box.height, accuracy: 1e-9)

        XCTAssertFalse(OverlayQuadGeometry.isAxisAligned(quad, toleranceDegrees: 2),
                       "a field on a rolled display must not draw as an axis-aligned rect")
    }

    func testFieldRegion_underNoRotation_matchesItsBoundingBox() {
        let tracked = target(ScreenQuad(roi: NormalizedROI(x: 0.1, y: 0.1, width: 0.8, height: 0.6)))
        let region = NormalizedROI(x: 0.25, y: 0.30, width: 0.4, height: 0.2)
        guard let quad = OverlayQuadGeometry.projectedFieldQuad(region, in: tracked) else {
            return XCTFail("axis-aligned target must project a drawable field quad")
        }
        let box = quad.boundingBox
        XCTAssertEqual(quad.area, box.width * box.height, accuracy: 1e-9,
                       "with no rotation or keystone the quad and its box coincide")
        XCTAssertTrue(OverlayQuadGeometry.isAxisAligned(quad, toleranceDegrees: 1e-3))
        // Position sanity: the region maps into the target's own extent.
        XCTAssertEqual(box.x, 0.1 + 0.25 * 0.8, accuracy: 1e-9)
        XCTAssertEqual(box.y, 0.1 + 0.30 * 0.6, accuracy: 1e-9)
    }

    /// The field outline must follow the target every frame, not snap at the
    /// detection cadence — moving only the target's quad must move the field.
    func testFieldQuad_followsTargetGeometryFrameToFrame() {
        let region = NormalizedROI(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        var model = DemoMotionModel()
        model.mode = .tumble
        var previousCentre: CGPoint?
        var movedFrames = 0
        for i in 0..<Int(4 * fps) {
            let pose = model.pose(at: Double(i) * dt, dt: dt)
            guard let quad = OverlayQuadGeometry.projectedFieldQuad(region, in: target(groundTruthQuad(for: pose))) else {
                XCTFail("frame \(i): field quad must resolve"); continue
            }
            if let previousCentre, ScreenQuad.distance(previousCentre, quad.center) > 1e-9 { movedFrames += 1 }
            previousCentre = quad.center
        }
        XCTAssertGreaterThan(movedFrames, Int(3 * fps),
                             "the field outline must update on essentially every tracked frame")
    }

    // MARK: - Lock quality must be visually distinct

    func testLockRenderStyle_mapsSnapStatesAndKeepsThemDistinct() {
        let id = UUID()
        XCTAssertEqual(LockRenderStyle.forSnapState(.locked(targetID: id)), .healthy)
        XCTAssertEqual(LockRenderStyle.forSnapState(.trackingDegraded(targetID: id)), .degraded)
        XCTAssertEqual(LockRenderStyle.forSnapState(.reacquisition(targetID: id)), .reacquiring)
        XCTAssertEqual(LockRenderStyle.forSnapState(.manual), .provisional)
        XCTAssertEqual(LockRenderStyle.forSnapState(.snapPreview(candidateID: id)), .provisional)
    }

    func testLockRenderStyle_healthyLockLooksDifferentFromADriftingOne() {
        let healthy = LockRenderStyle.healthy
        let degraded = LockRenderStyle.degraded
        let reacquiring = LockRenderStyle.reacquiring

        // Only a healthy lock claims full authority.
        XCTAssertTrue(healthy.dash.isEmpty, "a healthy lock is solid")
        XCTAssertFalse(degraded.dash.isEmpty, "a degraded lock must be dashed")
        XCTAssertFalse(reacquiring.dash.isEmpty, "a reacquiring lock must be dashed")
        XCTAssertNotEqual(degraded.dash, reacquiring.dash, "degraded and reacquiring must not share a dash pattern")

        XCTAssertGreaterThan(healthy.lineWidth, degraded.lineWidth)
        XCTAssertGreaterThan(healthy.opacity, degraded.opacity)
        XCTAssertGreaterThan(degraded.opacity, reacquiring.opacity)

        XCTAssertTrue(healthy.markerIsFilled)
        XCTAssertFalse(degraded.markerIsFilled)
        XCTAssertFalse(reacquiring.markerIsFilled)

        XCTAssertTrue(healthy.showsGlow)
        XCTAssertFalse(degraded.showsGlow)
        XCTAssertFalse(reacquiring.showsGlow)

        // Redundant coding: the difference survives greyscale and colour blindness.
        let descriptions = Set([healthy, degraded, reacquiring, .provisional].map(\.qualityDescription))
        XCTAssertEqual(descriptions.count, 4, "each lock quality must be describable distinctly")
    }

    // MARK: - Path construction

    func testClosedPath_visitsEveryProjectedVertex() {
        let quad = groundTruthQuad(for: DisplayPose(center: DemoMotionModel.homeCenter,
                                                    roll: 18 * .pi / 180,
                                                    yawScale: 0.7, pitchScale: 0.9, scale: 1.1))
        guard let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) else {
            return XCTFail("quad must be drawable")
        }
        // SwiftUI's `Path` stores coordinates in SINGLE precision, so the
        // round-trip through it loses ~2e-6 pt against the double-precision
        // projection. That is four orders of magnitude below one device pixel;
        // the tolerance acknowledges the storage, it does not hide slop.
        let pathAccuracy: CGFloat = 1e-3

        // Walk the path's elements: four vertices, straight edges only, closed.
        // Curves or extra vertices would mean the outline is not the quad.
        var visited: [CGPoint] = []
        var closed = false
        OverlayQuadGeometry.closedPath(corners).forEach { element in
            switch element {
            case .move(let to): visited.append(to)
            case .line(let to): visited.append(to)
            case .closeSubpath: closed = true
            default: XCTFail("the outline must be straight edges only, got \(element)")
            }
        }
        XCTAssertEqual(visited.count, 4, "one vertex per tracked corner")
        XCTAssertTrue(closed, "the outline must be a closed quadrilateral")
        for i in 0..<visited.count {
            assertPoint(visited[i], corners[i], accuracy: pathAccuracy, "path vertex \(i)")
        }

        // A shape whose own path already carries absolute view points must not
        // be re-anchored by the frame it is proposed.
        var shapeVisited: [CGPoint] = []
        ProjectedQuadShape(corners: corners).path(in: .zero).forEach { element in
            if case .move(let to) = element { shapeVisited.append(to) }
            if case .line(let to) = element { shapeVisited.append(to) }
        }
        XCTAssertEqual(shapeVisited.count, 4)
        for i in 0..<shapeVisited.count {
            assertPoint(shapeVisited[i], corners[i], accuracy: pathAccuracy, "shape vertex \(i)")
        }
    }

    func testBoundingRect_ofEmptyCornersIsZero() {
        XCTAssertEqual(OverlayQuadGeometry.boundingRect([]), .zero)
        XCTAssertTrue(OverlayQuadGeometry.bracketSegments([]).isEmpty)
        XCTAssertTrue(OverlayQuadGeometry.closedPath([]).isEmpty)
    }
}
