//
//  ScreenGeometryTests.swift
//  DAQPalTests
//
//  Coverage for the frozen screen-geometry contract (`ScreenQuad`,
//  `Homography`) in `DAQPal/Tracking/ScreenQuad.swift` — corner winding,
//  metrics, convexity, interpolation, and the DLT homography solve/apply/
//  invert round trip, including a genuine (non-affine) perspective case.
//
//  All fixtures are hand-constructed CGPoints; no randomness, no Date(), no
//  Vision/OCR involvement, so results are fully deterministic.
//

import CoreGraphics
import XCTest
@testable import DAQPal

final class ScreenGeometryTests: XCTestCase {

    // MARK: - Fixtures

    /// A general (asymmetric, non-parallelogram) convex quad used to exercise
    /// the homography solve on something more demanding than a square.
    private let genericQuad = ScreenQuad(topLeft: CGPoint(x: 0.15, y: 0.1),
                                         topRight: CGPoint(x: 0.85, y: 0.05),
                                         bottomRight: CGPoint(x: 0.9, y: 0.88),
                                         bottomLeft: CGPoint(x: 0.05, y: 0.92))

    /// Isosceles trapezoid, top edge narrower than bottom — the classic
    /// "display tilted away" perspective shape. Symmetric about x = 0.5 so
    /// the top-edge midpoint has a hand-provable canonical image.
    private let trapezoidQuad = ScreenQuad(topLeft: CGPoint(x: 0.3, y: 0.2),
                                           topRight: CGPoint(x: 0.7, y: 0.2),
                                           bottomRight: CGPoint(x: 0.9, y: 0.8),
                                           bottomLeft: CGPoint(x: 0.1, y: 0.8))

    // MARK: - Helpers

    private func assertPointEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat,
                                  _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "\(message) (x: \(a.x) vs \(b.x))", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "\(message) (y: \(a.y) vs \(b.y))", file: file, line: line)
    }

    private func assertQuadEqual(_ a: ScreenQuad, _ b: ScreenQuad, accuracy: CGFloat,
                                 _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        assertPointEqual(a.topLeft, b.topLeft, accuracy: accuracy, "\(message) topLeft", file: file, line: line)
        assertPointEqual(a.topRight, b.topRight, accuracy: accuracy, "\(message) topRight", file: file, line: line)
        assertPointEqual(a.bottomRight, b.bottomRight, accuracy: accuracy, "\(message) bottomRight", file: file, line: line)
        assertPointEqual(a.bottomLeft, b.bottomLeft, accuracy: accuracy, "\(message) bottomLeft", file: file, line: line)
    }

    private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// Rotates a point about `center` by `theta` radians using the same
    /// convention `rollAngle` measures against (positive = the sense in
    /// which `atan2(dy, dx)` increases).
    private func rotated(_ p: CGPoint, about center: CGPoint, by theta: CGFloat) -> CGPoint {
        let dx = p.x - center.x, dy = p.y - center.y
        let c = cos(theta), s = sin(theta)
        return CGPoint(x: center.x + dx * c - dy * s, y: center.y + dx * s + dy * c)
    }

    private func rotatedQuad(_ q: ScreenQuad, about center: CGPoint, by theta: CGFloat) -> ScreenQuad {
        ScreenQuad(topLeft: rotated(q.topLeft, about: center, by: theta),
                  topRight: rotated(q.topRight, about: center, by: theta),
                  bottomRight: rotated(q.bottomRight, about: center, by: theta),
                  bottomLeft: rotated(q.bottomLeft, about: center, by: theta))
    }

    // MARK: - ScreenQuad.init(roi:) round trip

    func testInitFromROI_boundingBoxRoundTrips() {
        let rects: [NormalizedROI] = [
            NormalizedROI(x: 0, y: 0, width: 1, height: 1),
            NormalizedROI(x: 0.25, y: 0.42, width: 0.5, height: 0.16),
            NormalizedROI(x: 0.1, y: 0.2, width: 0.3, height: 0.15),
            NormalizedROI(x: 0.05, y: 0.6, width: 0.9, height: 0.35)
        ]
        for r in rects {
            let box = ScreenQuad(roi: r).boundingBox
            XCTAssertEqual(box.x, r.x, accuracy: 1e-9)
            XCTAssertEqual(box.y, r.y, accuracy: 1e-9)
            XCTAssertEqual(box.width, r.width, accuracy: 1e-9)
            XCTAssertEqual(box.height, r.height, accuracy: 1e-9)
        }
    }

    // MARK: - ScreenQuad.corners winding order

    func testCorners_windingOrderIsTLTRBRBL() {
        let r = NormalizedROI(x: 0.2, y: 0.3, width: 0.4, height: 0.1)
        let q = ScreenQuad(roi: r)
        XCTAssertEqual(q.corners, [q.topLeft, q.topRight, q.bottomRight, q.bottomLeft])
        XCTAssertEqual(q.topLeft, CGPoint(x: r.cgRect.minX, y: r.cgRect.minY))
        XCTAssertEqual(q.topRight, CGPoint(x: r.cgRect.maxX, y: r.cgRect.minY))
        XCTAssertEqual(q.bottomRight, CGPoint(x: r.cgRect.maxX, y: r.cgRect.maxY))
        XCTAssertEqual(q.bottomLeft, CGPoint(x: r.cgRect.minX, y: r.cgRect.maxY))
    }

    // MARK: - ScreenQuad.area

    func testArea_unitSquareIsOne() {
        let q = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(q.area, 1, accuracy: 1e-9)
    }

    func testArea_halfSizeSquareIsQuarter() {
        let q = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(q.area, 0.25, accuracy: 1e-9)
    }

    func testArea_isNonNegativeForReversedWinding() {
        // Same square boundary, traversed the opposite direction — a valid
        // simple polygon, just wound the other way.
        let q = ScreenQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 0, y: 1),
                           bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 1, y: 0))
        XCTAssertEqual(q.area, 1, accuracy: 1e-9)
    }

    // MARK: - ScreenQuad.meanWidth / meanHeight / aspectRatio

    func testMeanDimensions_axisAlignedRectMatchesWidthHeight() {
        let r = NormalizedROI(x: 0.1, y: 0.1, width: 0.6, height: 0.3)
        let q = ScreenQuad(roi: r)
        XCTAssertEqual(q.meanWidth, 0.6, accuracy: 1e-9)
        XCTAssertEqual(q.meanHeight, 0.3, accuracy: 1e-9)
        XCTAssertEqual(q.aspectRatio, 2.0, accuracy: 1e-9)
    }

    // MARK: - ScreenQuad.rollAngle

    func testRollAngle_zeroForAxisAligned() {
        let q = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.2, width: 0.3, height: 0.2))
        XCTAssertEqual(q.rollAngle, 0, accuracy: 1e-9)
    }

    func testRollAngle_matchesAppliedRotation() {
        let base = ScreenQuad(roi: NormalizedROI(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
        let center = base.center
        for theta: CGFloat in [0.1, 0.3, -0.5, 1.0] {
            let rotatedQ = rotatedQuad(base, about: center, by: theta)
            XCTAssertEqual(rotatedQ.rollAngle, theta, accuracy: 1e-6, "theta \(theta)")
        }
    }

    // MARK: - ScreenQuad.isConvex

    func testIsConvex_trueForAxisAlignedRect() {
        XCTAssertTrue(ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1)).isConvex)
    }

    func testIsConvex_trueForRotatedRect() {
        let base = ScreenQuad(roi: NormalizedROI(x: 0.3, y: 0.3, width: 0.3, height: 0.2))
        let rotatedQ = rotatedQuad(base, about: base.center, by: 0.4)
        XCTAssertTrue(rotatedQ.isConvex)
    }

    func testIsConvex_falseForBowtie() {
        // Diagonal corners crossed: TL-TR and BR-BL edges intersect in the
        // middle, the textbook self-intersecting quadrilateral.
        let bowtie = ScreenQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 1),
                                bottomRight: CGPoint(x: 1, y: 0), bottomLeft: CGPoint(x: 0, y: 1))
        XCTAssertFalse(bowtie.isConvex)
    }

    func testIsConvex_falseForZeroAreaDegenerate() {
        let p = CGPoint(x: 0.4, y: 0.4)
        let degenerate = ScreenQuad(topLeft: p, topRight: p, bottomRight: p, bottomLeft: p)
        XCTAssertFalse(degenerate.isConvex)
    }

    func testIsConvex_falseForThreeCollinearCorners() {
        // topLeft, topRight, bottomRight all lie on y = 0, with the winding
        // order backtracking over itself before reaching bottomLeft — a
        // genuine self-intersection caused by the collinear triple, not a
        // borderline "straight angle" case.
        let collinear = ScreenQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 1, y: 0),
                                   bottomRight: CGPoint(x: 0.5, y: 0), bottomLeft: CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(collinear.area, 1e-9, "sanity: this must exercise the winding check, not the area guard")
        XCTAssertFalse(collinear.isConvex)
    }

    // MARK: - ScreenQuad.interpolated(toward:t:)

    func testInterpolated_tZeroReturnsSelf() {
        let result = genericQuad.interpolated(toward: trapezoidQuad, t: 0)
        assertQuadEqual(result, genericQuad, accuracy: 1e-9)
    }

    func testInterpolated_tOneReturnsOther() {
        let result = genericQuad.interpolated(toward: trapezoidQuad, t: 1)
        assertQuadEqual(result, trapezoidQuad, accuracy: 1e-9)
    }

    func testInterpolated_tHalfIsPerCornerMidpoint() {
        let result = genericQuad.interpolated(toward: trapezoidQuad, t: 0.5)
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        assertPointEqual(result.topLeft, mid(genericQuad.topLeft, trapezoidQuad.topLeft), accuracy: 1e-9)
        assertPointEqual(result.topRight, mid(genericQuad.topRight, trapezoidQuad.topRight), accuracy: 1e-9)
        assertPointEqual(result.bottomRight, mid(genericQuad.bottomRight, trapezoidQuad.bottomRight), accuracy: 1e-9)
        assertPointEqual(result.bottomLeft, mid(genericQuad.bottomLeft, trapezoidQuad.bottomLeft), accuracy: 1e-9)
    }

    func testInterpolated_tIsClampedOutOfRange() {
        let below = genericQuad.interpolated(toward: trapezoidQuad, t: -3)
        assertQuadEqual(below, genericQuad, accuracy: 1e-9, "t below 0 should clamp to self")

        let above = genericQuad.interpolated(toward: trapezoidQuad, t: 4)
        assertQuadEqual(above, trapezoidQuad, accuracy: 1e-9, "t above 1 should clamp to other")
    }

    func testInterpolated_betweenConvexQuadsStaysConvex() {
        XCTAssertTrue(genericQuad.isConvex, "sanity: fixture must be convex")
        XCTAssertTrue(trapezoidQuad.isConvex, "sanity: fixture must be convex")
        for t: CGFloat in [0, 0.25, 0.5, 0.75, 1] {
            let mid = genericQuad.interpolated(toward: trapezoidQuad, t: t)
            XCTAssertTrue(mid.isConvex, "t \(t) should stay convex")
        }
    }

    // MARK: - ScreenQuad.meanCornerDistance

    func testMeanCornerDistance_zeroToItself() {
        XCTAssertEqual(genericQuad.meanCornerDistance(to: genericQuad), 0, accuracy: 1e-9)
    }

    func testMeanCornerDistance_equalsTranslationDistance() {
        let base = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        let dx: CGFloat = 0.2, dy: CGFloat = 0.15
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        let translated = ScreenQuad(topLeft: shift(base.topLeft), topRight: shift(base.topRight),
                                    bottomRight: shift(base.bottomRight), bottomLeft: shift(base.bottomLeft))
        let expected = (dx * dx + dy * dy).squareRoot()
        XCTAssertEqual(base.meanCornerDistance(to: translated), expected, accuracy: 1e-9)
    }

    // MARK: - ScreenQuad.boundingBoxIoU

    func testBoundingBoxIoU_oneForIdentical() {
        let q = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.2, width: 0.4, height: 0.3))
        XCTAssertEqual(q.boundingBoxIoU(with: q), 1, accuracy: 1e-9)
    }

    func testBoundingBoxIoU_zeroForDisjoint() {
        let a = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        let b = ScreenQuad(roi: NormalizedROI(x: 5, y: 5, width: 1, height: 1))
        XCTAssertEqual(a.boundingBoxIoU(with: b), 0, accuracy: 1e-9)
    }

    func testBoundingBoxIoU_knownPartialOverlap() {
        // Two unit squares offset by 0.5 in x: intersection 0.5×1 = 0.5,
        // union 1 + 1 - 0.5 = 1.5, IoU = 1/3.
        let a = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        let b = ScreenQuad(roi: NormalizedROI(x: 0.5, y: 0, width: 1, height: 1))
        XCTAssertEqual(a.boundingBoxIoU(with: b), 1.0 / 3.0, accuracy: 1e-9)
    }

    // MARK: - ScreenQuad.expanded(by:)

    func testExpanded_growsAreaAndKeepsCenterFixed() {
        let base = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        let expanded = base.expanded(by: 0.2)
        XCTAssertGreaterThan(expanded.area, base.area)
        assertPointEqual(expanded.center, base.center, accuracy: 1e-9)
    }

    // MARK: - ScreenQuad.normalizedCornerOrder()

    func testNormalizedCornerOrder_putsNearestOriginCornerFirst() {
        // Same square as the "no-op" case below, but corner labels
        // deliberately scrambled so the nearest-origin point (0,0) is
        // currently stored under `bottomRight`.
        let scrambled = ScreenQuad(topLeft: CGPoint(x: 1, y: 1), topRight: CGPoint(x: 0, y: 1),
                                   bottomRight: CGPoint(x: 0, y: 0), bottomLeft: CGPoint(x: 1, y: 0))
        let normalized = scrambled.normalizedCornerOrder()
        XCTAssertEqual(normalized.topLeft, CGPoint(x: 0, y: 0))
        XCTAssertEqual(normalized.topRight, CGPoint(x: 1, y: 0))
        XCTAssertEqual(normalized.bottomRight, CGPoint(x: 1, y: 1))
        XCTAssertEqual(normalized.bottomLeft, CGPoint(x: 0, y: 1))
    }

    func testNormalizedCornerOrder_noOpForAlreadyNormalizedRect() {
        let q = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(q.normalizedCornerOrder(), q)
    }

    // MARK: - Homography.solve identical quads map points to themselves

    func testSolve_identicalQuads_mapsInteriorPointsToThemselves() {
        guard let h = Homography.solve(from: genericQuad, to: genericQuad) else {
            return XCTFail("non-degenerate convex quad must be solvable")
        }
        let interiorPoints = [
            genericQuad.center,
            lerp(genericQuad.topLeft, genericQuad.bottomRight, 0.3),
            lerp(genericQuad.topRight, genericQuad.bottomLeft, 0.6),
            lerp(genericQuad.topLeft, genericQuad.topRight, 0.5)
        ]
        for p in interiorPoints {
            guard let mapped = h.apply(p) else { return XCTFail("point \(p) should be mappable") }
            assertPointEqual(mapped, p, accuracy: 1e-6, "point \(p)")
        }
    }

    // MARK: - Homography.toCanonical maps corners exactly

    func testToCanonical_mapsArbitraryConvexQuadCornersToUnitSquare() {
        guard let h = Homography.toCanonical(from: genericQuad) else {
            return XCTFail("convex quad must be solvable to canonical")
        }
        guard let tl = h.apply(genericQuad.topLeft), let tr = h.apply(genericQuad.topRight),
              let br = h.apply(genericQuad.bottomRight), let bl = h.apply(genericQuad.bottomLeft) else {
            return XCTFail("all corners should be mappable")
        }
        assertPointEqual(tl, CGPoint(x: 0, y: 0), accuracy: 1e-6, "topLeft")
        assertPointEqual(tr, CGPoint(x: 1, y: 0), accuracy: 1e-6, "topRight")
        assertPointEqual(br, CGPoint(x: 1, y: 1), accuracy: 1e-6, "bottomRight")
        assertPointEqual(bl, CGPoint(x: 0, y: 1), accuracy: 1e-6, "bottomLeft")
    }

    // MARK: - Homography round trip (toCanonical + inverted)

    func testToCanonical_composedWithInverted_roundTripsInteriorPoints() {
        guard let h = Homography.toCanonical(from: genericQuad), let hInv = h.inverted() else {
            return XCTFail("both the forward and inverse transform must exist")
        }
        let interiorPoints = [
            genericQuad.center,
            lerp(genericQuad.topLeft, genericQuad.bottomRight, 0.3),
            lerp(genericQuad.topRight, genericQuad.bottomLeft, 0.6),
            lerp(genericQuad.topLeft, genericQuad.topRight, 0.5)
        ]
        for p in interiorPoints {
            guard let forward = h.apply(p), let back = hInv.apply(forward) else {
                return XCTFail("point \(p) should round-trip through canonical space")
            }
            assertPointEqual(back, p, accuracy: 1e-6, "point \(p)")
        }
    }

    // MARK: - Homography translation/scale (hand-computed)

    func testSolve_pureTranslationAndScale_matchesHandComputedMatrix() {
        let source = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        // x' = 2x + 2, y' = 2y + 3 — a pure affine map, no perspective term.
        let destination = ScreenQuad(topLeft: CGPoint(x: 2, y: 3), topRight: CGPoint(x: 4, y: 3),
                                     bottomRight: CGPoint(x: 4, y: 5), bottomLeft: CGPoint(x: 2, y: 5))
        guard let h = Homography.solve(from: source, to: destination) else {
            return XCTFail("axis-aligned squares must be solvable")
        }
        let expected: [CGFloat] = [2, 0, 2, 0, 2, 3, 0, 0, 1]
        for i in 0..<9 {
            XCTAssertEqual(h.m[i], expected[i], accuracy: 1e-6, "m[\(i)]")
        }
        guard let mapped = h.apply(CGPoint(x: 0.5, y: 0.5)) else { return XCTFail("center should be mappable") }
        assertPointEqual(mapped, CGPoint(x: 3, y: 4), accuracy: 1e-6)
    }

    // MARK: - Homography genuine perspective (trapezoid)

    func testSolve_trapezoidToCanonical_topEdgeMidpointMapsToHalfZero() {
        guard let h = Homography.toCanonical(from: trapezoidQuad) else {
            return XCTFail("trapezoid must be solvable to canonical")
        }
        let topMidpoint = lerp(trapezoidQuad.topLeft, trapezoidQuad.topRight, 0.5)
        guard let mapped = h.apply(topMidpoint) else { return XCTFail("top edge midpoint should be mappable") }
        assertPointEqual(mapped, CGPoint(x: 0.5, y: 0), accuracy: 1e-6)
    }

    func testSolve_trapezoidToCanonical_hasNonzeroProjectiveTerm() {
        guard let h = Homography.toCanonical(from: trapezoidQuad) else {
            return XCTFail("trapezoid must be solvable to canonical")
        }
        // For a pure affine map m[6] == m[7] == 0. A real trapezoid (not a
        // parallelogram) must have at least one nonzero, or the transform
        // could not actually be doing perspective work.
        XCTAssertTrue(abs(h.m[6]) > 1e-3 || abs(h.m[7]) > 1e-3,
                      "expected a nonzero projective term, got m6=\(h.m[6]) m7=\(h.m[7])")
    }

    func testSolve_trapezoidToCanonical_divergesFromNaiveAffineFit() {
        guard let h = Homography.toCanonical(from: trapezoidQuad) else {
            return XCTFail("trapezoid must be solvable to canonical")
        }
        // Hand-derived affine map fit from only 3 corners (topLeft, topRight,
        // bottomLeft) to their canonical images (0,0), (1,0), (0,1) — the
        // unique affine transform satisfying those three correspondences.
        // Derivation (by hand, exact fractions):
        //   TR - TL = (0.4, 0)  -> (1, 0)   =>  A00 = 2.5,      A10 = 0
        //   BL - TL = (-0.2,0.6)-> (0, 1)   =>  A01 = 5/6,      A11 = 5/3
        //   b = -A * TL
        let a00: CGFloat = 2.5, a01: CGFloat = 5.0 / 6.0
        let a10: CGFloat = 0, a11: CGFloat = 5.0 / 3.0
        let tl = trapezoidQuad.topLeft
        let b0 = -(a00 * tl.x + a01 * tl.y)
        let b1 = -(a10 * tl.x + a11 * tl.y)
        let br = trapezoidQuad.bottomRight
        let naiveAffinePrediction = CGPoint(x: a00 * br.x + a01 * br.y + b0,
                                            y: a10 * br.x + a11 * br.y + b1)
        // Sanity: this hand-derived affine fit predicts (2, 1) for bottomRight.
        assertPointEqual(naiveAffinePrediction, CGPoint(x: 2, y: 1), accuracy: 1e-6,
                         "sanity check on the hand-derived affine fit itself")

        guard let trueMapped = h.apply(br) else { return XCTFail("bottomRight should be mappable") }
        assertPointEqual(trueMapped, CGPoint(x: 1, y: 1), accuracy: 1e-6, "true homography must hit the canonical corner")

        let divergence = (naiveAffinePrediction.x - trueMapped.x)
        XCTAssertGreaterThan(abs(divergence), 0.5,
                             "a naive 3-point affine fit should NOT predict the same image as the true projective transform")
    }

    // MARK: - Homography.solve returns nil for degenerate quads

    func testSolve_returnsNilForAllCornersIdentical() {
        let p = CGPoint(x: 0.5, y: 0.5)
        let degenerate = ScreenQuad(topLeft: p, topRight: p, bottomRight: p, bottomLeft: p)
        XCTAssertNil(Homography.solve(from: degenerate, to: .canonical))
    }

    func testSolve_returnsNilForCollinearCorners() {
        let collinear = ScreenQuad(topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 0.3, y: 0),
                                   bottomRight: CGPoint(x: 0.6, y: 0), bottomLeft: CGPoint(x: 1, y: 0))
        XCTAssertNil(Homography.solve(from: collinear, to: .canonical))
    }

    // MARK: - Homography.apply(_ quad:) nil propagation

    func testApplyQuad_returnsNilIfAnyCornerUnmappable() {
        // w = x + 1, so any point with x = -1 sits exactly on the horizon.
        let h = Homography(m: [1, 0, 0, 0, 1, 0, 1, 0, 1])
        XCTAssertNil(h.apply(CGPoint(x: -1, y: 0.2)), "sanity: the single point must itself be unmappable")

        let quadWithUnmappableCorner = ScreenQuad(topLeft: CGPoint(x: -1, y: 0.2),
                                                  topRight: CGPoint(x: 0.5, y: 0.3),
                                                  bottomRight: CGPoint(x: 0.6, y: 0.6),
                                                  bottomLeft: CGPoint(x: 0.1, y: 0.7))
        XCTAssertNil(h.apply(quadWithUnmappableCorner))

        let safeQuad = ScreenQuad.canonical
        XCTAssertNotNil(h.apply(safeQuad), "sanity: a quad with all-mappable corners should still succeed")
    }

    // MARK: - Homography.inverted() nil for singular matrix

    func testInverted_returnsNilForSingularMatrix() {
        // Two identical rows -> determinant 0.
        let singular = Homography(m: [1, 0, 0, 1, 0, 0, 0, 0, 1])
        XCTAssertNil(singular.inverted())
    }

    // MARK: - Homography.identity

    func testIdentity_mapsEveryPointToItself() {
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1),
            CGPoint(x: -2, y: 3),
            CGPoint(x: 10, y: -5)
        ]
        for p in points {
            guard let mapped = Homography.identity.apply(p) else { return XCTFail("identity should map every point") }
            assertPointEqual(mapped, p, accuracy: 1e-9, "point \(p)")
        }
    }
}
