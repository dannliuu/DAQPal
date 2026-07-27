//
//  ScreenCandidateDetectorTests.swift
//  DAQPalTests
//
//  Coverage for the pure, deterministic surface of `ScreenCandidateDetector`:
//  the aspect-ratio and numeric scorers, the point-in-quad test, the tuning
//  band the Vision request is derived from, and — the one that matters most —
//  corner-label continuity through rotation.
//
//  No Vision, no pixel buffers, no Date(), no randomness: every fixture is a
//  hand-constructed quad or string, and the rotation sweep is generated from a
//  closed-form rotation about a fixed centre.
//

import CoreGraphics
import Foundation
import XCTest
@testable import DAQPal

final class ScreenCandidateDetectorTests: XCTestCase {

    private typealias Detector = ScreenCandidateDetector

    // MARK: - Fixtures

    /// The reviewer's failing geometry: a 4:1 readout, 0.40 × 0.10, centred
    /// off the frame's diagonal at (0.5, 0.4). This is the shape whose
    /// `argmin(x² + y²)` corner anchor switches under roll.
    private static let panelCenter = CGPoint(x: 0.5, y: 0.4)
    private static let panelWidth: CGFloat = 0.40
    private static let panelHeight: CGFloat = 0.10

    /// The panel rolled by `degrees`, corners labeled by physical identity
    /// (TL → TR → BR → BL) — the ground truth a continuous labeling must
    /// reproduce. Screen space is y-down, so positive is clockwise.
    private func rolledPanel(degrees: CGFloat,
                             center: CGPoint = ScreenCandidateDetectorTests.panelCenter) -> ScreenQuad {
        let theta = degrees * .pi / 180
        let c = cos(theta), s = sin(theta)
        let hw = Self.panelWidth / 2, hh = Self.panelHeight / 2
        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x * c - y * s,
                    y: center.y + x * s + y * c)
        }
        return ScreenQuad(topLeft: place(-hw, -hh),
                          topRight: place(hw, -hh),
                          bottomRight: place(hw, hh),
                          bottomLeft: place(-hw, hh))
    }

    private let unitQuad = ScreenQuad(topLeft: CGPoint(x: 0.2, y: 0.2),
                                      topRight: CGPoint(x: 0.8, y: 0.2),
                                      bottomRight: CGPoint(x: 0.8, y: 0.6),
                                      bottomLeft: CGPoint(x: 0.2, y: 0.6))

    private func assertPointEqual(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat,
                                  _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Corner-label continuity (the critical fix)

    /// The defect this replaces, stated as a test so the fix cannot be quietly
    /// reverted: re-deriving labels from frame position every frame flips the
    /// anchor mid-sweep, and the quad's apparent aspect ratio flips with it.
    func testFramePositionAnchorFlipsAspectDuringRoll() {
        var aspects: Set<Int> = []
        for step in 0...180 {
            let quad = rolledPanel(degrees: CGFloat(step) * 0.5).normalizedCornerOrder()
            aspects.insert(Int((quad.aspectRatio * 100).rounded()))
        }
        // 4.00 and its reciprocal 0.25 — width and height swapping places.
        XCTAssertEqual(aspects, [400, 25],
                       "positional anchoring is expected to swap width and height mid-roll")
    }

    /// Slowly rolling the panel through 90°, with each frame's proposal handed
    /// over in whatever order the positional anchor produces, must still yield
    /// labels glued to the same physical corners.
    func testContinuousLabelingTracksPhysicalCornersThroughRoll() {
        var previous = rolledPanel(degrees: 0)
        var worstLabelError: CGFloat = 0
        var worstStep: CGFloat = 0

        for step in 1...180 {
            let degrees = CGFloat(step) * 0.5
            let truth = rolledPanel(degrees: degrees)
            // Simulate a detector-supplied labeling that is anchored to the
            // frame rather than to the screen.
            let proposal = truth.normalizedCornerOrder()
            let stable = Detector.continuousLabeling(of: proposal, matching: previous)

            for (labeled, expected) in zip(stable.corners, truth.corners) {
                worstLabelError = max(worstLabelError, ScreenQuad.distance(labeled, expected))
            }
            worstStep = max(worstStep, stable.meanCornerDistance(to: previous))
            previous = stable
        }

        XCTAssertEqual(worstLabelError, 0, accuracy: 1e-12,
                       "labels must stay on their physical corners through the whole sweep")
        // 0.5° of roll moves a corner by at most ~0.002 in normalized units;
        // a label rotation would show up here as ~half the quad's diagonal.
        XCTAssertLessThan(worstStep, 0.01)
    }

    /// The same sweep without the fix, as the numeric contrast: consecutive
    /// frames jump by roughly half the quad's diagonal at the flip.
    func testFramePositionAnchorProducesLargeCornerJump() {
        var previous = rolledPanel(degrees: 0).normalizedCornerOrder()
        var worstStep: CGFloat = 0
        for step in 1...180 {
            let quad = rolledPanel(degrees: CGFloat(step) * 0.5).normalizedCornerOrder()
            worstStep = max(worstStep, quad.meanCornerDistance(to: previous))
            previous = quad
        }
        XCTAssertGreaterThan(worstStep, 0.2)
    }

    /// Aspect ratio — and therefore `aspectRatioScore`, and therefore fused
    /// confidence — must not flap while the panel rolls.
    func testAspectScoreIsStableUnderContinuousLabeling() {
        var previous = rolledPanel(degrees: 0)
        for step in 1...180 {
            let truth = rolledPanel(degrees: CGFloat(step) * 0.5)
            let stable = Detector.continuousLabeling(of: truth.normalizedCornerOrder(),
                                                     matching: previous)
            XCTAssertEqual(stable.aspectRatio, 4.0, accuracy: 1e-9)
            XCTAssertEqual(Detector.aspectRatioScore(stable.aspectRatio), 1.0, accuracy: 1e-6)
            previous = stable
        }
    }

    /// Sub-degree jitter around the anchor's switch point (≈38.75°) is the
    /// concrete failure the reviewer traced: alternating frames, alternating
    /// labels. Continuity must hold across the boundary in both directions.
    func testContinuousLabelingSurvivesJitterAcrossAnchorBoundary() {
        let jitter: [CGFloat] = [38.5, 39.0, 38.6, 39.1, 38.4, 39.2, 38.8]
        var previous = rolledPanel(degrees: 38.5)
        for degrees in jitter {
            let truth = rolledPanel(degrees: degrees)
            let stable = Detector.continuousLabeling(of: truth.normalizedCornerOrder(),
                                                     matching: previous)
            assertPointEqual(stable.topLeft, truth.topLeft, accuracy: 1e-12)
            assertPointEqual(stable.bottomRight, truth.bottomRight, accuracy: 1e-12)
            previous = stable
        }
    }

    func testContinuousLabelingIsIdentityForAnAlreadyAlignedQuad() {
        XCTAssertEqual(Detector.continuousLabeling(of: unitQuad, matching: unitQuad), unitQuad)
    }

    /// Any of the four cyclic rotations of the same physical quad must be
    /// mapped back onto the reference labeling.
    func testContinuousLabelingUndoesEveryCyclicRotation() {
        let p = unitQuad.corners
        for shift in 0..<4 {
            let rotated = ScreenQuad(topLeft: p[shift],
                                     topRight: p[(shift + 1) % 4],
                                     bottomRight: p[(shift + 2) % 4],
                                     bottomLeft: p[(shift + 3) % 4])
            XCTAssertEqual(Detector.continuousLabeling(of: rotated, matching: unitQuad),
                           unitQuad,
                           "shift \(shift) was not undone")
        }
    }

    /// A 180° roll is the case the frozen `ScreenQuad` doc calls out: the
    /// semantic `topLeft` ends up at the bottom right of the frame and must
    /// stay labeled `topLeft`.
    func testContinuousLabelingKeepsLabelsThroughFullHalfTurn() {
        var previous = rolledPanel(degrees: 0)
        let start = previous
        for step in 1...360 {
            let truth = rolledPanel(degrees: CGFloat(step) * 0.5)
            previous = Detector.continuousLabeling(of: truth.normalizedCornerOrder(),
                                                   matching: previous)
        }
        // 180° later, the corner that started upper-left is now lower-right.
        XCTAssertGreaterThan(previous.topLeft.x, start.topLeft.x)
        XCTAssertGreaterThan(previous.topLeft.y, start.topLeft.y)
        assertPointEqual(previous.topLeft, rolledPanel(degrees: 180).topLeft, accuracy: 1e-9)
    }

    // MARK: - First-frame labeling (uprightLabeling)

    /// The blocking defect, stated as a sweep: a candidate FIRST seen past the
    /// positional anchor's flip angle used to be labeled a quarter turn off for
    /// the rest of its life, which turns a 4:1 readout into a 1:4 one, pins
    /// `aspectRatioScore` at ~0 and makes the display permanently un-lockable.
    /// First-frame labeling must therefore come from the quad's shape, so the
    /// same panel reports the same aspect ratio at every roll.
    func testUprightLabelingKeepsAspectRatioThroughTheWholeRollSweep() {
        let expected = Self.panelWidth / Self.panelHeight
        for step in 0...360 {
            let degrees = CGFloat(step) * 0.5   // 0…180° in half-degree steps
            let labeled = Detector.uprightLabeling(of: rolledPanel(degrees: degrees))
            XCTAssertEqual(labeled.aspectRatio, expected, accuracy: 1e-9,
                           "roll \(degrees)° transposed the first-frame labeling")
            XCTAssertEqual(Detector.aspectRatioScore(labeled.aspectRatio), 1.0, accuracy: 1e-6,
                           "roll \(degrees)° scored outside the display band")
        }
    }

    /// The exact angles the old `argmin(x² + y²)` anchor flipped at for this
    /// panel (≈38.75°, and again half a turn later), called out separately so a
    /// regression names itself.
    func testUprightLabelingIsUnaffectedByTheOldAnchorFlipThreshold() {
        for degrees in [38.0, 38.7, 38.75, 38.8, 39.5, 128.7, 128.75, 128.8] as [CGFloat] {
            let quad = rolledPanel(degrees: degrees)
            XCTAssertEqual(Detector.uprightLabeling(of: quad).aspectRatio, 4.0, accuracy: 1e-9,
                           "roll \(degrees)°")
        }
        // Contrast: the anchor this replaced does transpose across that boundary.
        XCTAssertNotEqual(rolledPanel(degrees: 38.0).normalizedCornerOrder().aspectRatio,
                          rolledPanel(degrees: 39.5).normalizedCornerOrder().aspectRatio,
                          accuracy: 0.5,
                          "the positional anchor is expected to transpose across its flip angle")
    }

    /// Position independence, stated directly: the same shape at three frame
    /// positions must produce the same labeling up to the translation between
    /// them. The old anchor could not do this — its choice of `topLeft` was the
    /// corner nearest the frame origin.
    func testUprightLabelingIsPositionIndependent() {
        // Three positions on opposite sides of the frame diagonal — the axis the
        // old `argmin(x² + y²)` anchor was sensitive to.
        let positions = [CGPoint(x: 0.5, y: 0.4),
                         CGPoint(x: 0.9, y: 0.1),
                         CGPoint(x: 0.1, y: 0.9)]
        for degrees in [0, 17, 45, 61, 90, 118, 155, 180] as [CGFloat] {
            let reference = Detector.uprightLabeling(of: rolledPanel(degrees: degrees,
                                                                    center: positions[0]))
            for position in positions.dropFirst() {
                let labeled = Detector.uprightLabeling(of: rolledPanel(degrees: degrees,
                                                                      center: position))
                let dx = position.x - positions[0].x, dy = position.y - positions[0].y
                for (index, pair) in zip(labeled.corners, reference.corners).enumerated() {
                    assertPointEqual(pair.0,
                                     CGPoint(x: pair.1.x + dx, y: pair.1.y + dy),
                                     accuracy: 1e-12,
                                     "corner \(index) at roll \(degrees)° moved with frame position")
                }
            }
        }
    }

    /// The contrast that makes the previous test meaningful: the anchor being
    /// replaced IS position dependent for this shape.
    func testFramePositionAnchorIsPositionDependent() {
        let lowerLeft = CGPoint(x: 0.9, y: 0.1), upperRight = CGPoint(x: 0.1, y: 0.9)
        let a = rolledPanel(degrees: 45, center: lowerLeft).normalizedCornerOrder()
        let b = rolledPanel(degrees: 45, center: upperRight).normalizedCornerOrder()
        let shifted = CGPoint(x: a.topLeft.x + upperRight.x - lowerLeft.x,
                              y: a.topLeft.y + upperRight.y - lowerLeft.y)
        XCTAssertGreaterThan(ScreenQuad.distance(b.topLeft, shifted), 0.01,
                             "positional anchoring is expected to label the same shape differently")
    }

    /// A portrait quad is the same physical situation seen a quarter turn over,
    /// so it must label as its long:short ratio too — that is what keeps the
    /// aspect band meaningful.
    func testUprightLabelingReportsLongOverShortForAPortraitQuad() {
        let portrait = ScreenQuad(topLeft: CGPoint(x: 0.45, y: 0.20),
                                  topRight: CGPoint(x: 0.55, y: 0.20),
                                  bottomRight: CGPoint(x: 0.55, y: 0.60),
                                  bottomLeft: CGPoint(x: 0.45, y: 0.60))
        XCTAssertEqual(portrait.aspectRatio, 0.25, accuracy: 1e-9)
        XCTAssertEqual(Detector.uprightLabeling(of: portrait).aspectRatio, 4.0, accuracy: 1e-9)
    }

    /// An already-upright landscape quad is left exactly as it came in, so the
    /// common case costs nothing and reads identically to the manual workflow.
    func testUprightLabelingIsIdentityForAnUprightLandscapeQuad() {
        XCTAssertEqual(Detector.uprightLabeling(of: unitQuad), unitQuad)
    }

    /// Labeling must be a pure relabeling: same four points, cyclic order
    /// preserved (so winding, convexity and the homography survive it).
    func testUprightLabelingOnlyCyclicallyRotatesCorners() {
        for degrees in [0, 33, 77, 91, 149, 180] as [CGFloat] {
            let quad = rolledPanel(degrees: degrees)
            let labeled = Detector.uprightLabeling(of: quad)
            let p = quad.corners
            let rotations = (0..<4).map { shift in
                (0..<4).map { p[($0 + shift) % 4] }
            }
            XCTAssertTrue(rotations.contains { rotation in
                zip(rotation, labeled.corners).allSatisfy {
                    ScreenQuad.distance($0, $1) < 1e-12
                }
            }, "roll \(degrees)° produced a non-cyclic relabeling")
            XCTAssertTrue(labeled.isConvex, "roll \(degrees)° lost convexity")
        }
    }

    /// Idempotent: labeling an already-labeled quad changes nothing, so the
    /// first frame is a fixed point and not a source of drift.
    func testUprightLabelingIsIdempotent() {
        for step in 0...72 {
            let quad = rolledPanel(degrees: CGFloat(step) * 2.5)
            let once = Detector.uprightLabeling(of: quad)
            XCTAssertEqual(Detector.uprightLabeling(of: once), once)
        }
    }

    /// Deterministic at the ties — a square and a panel rolled exactly 90° have
    /// no unique answer, and must still give the same one every call.
    func testUprightLabelingIsDeterministicAtTies() {
        let square = ScreenQuad(topLeft: CGPoint(x: 0.3, y: 0.3),
                                topRight: CGPoint(x: 0.7, y: 0.3),
                                bottomRight: CGPoint(x: 0.7, y: 0.7),
                                bottomLeft: CGPoint(x: 0.3, y: 0.7))
        XCTAssertEqual(Detector.uprightLabeling(of: square),
                       Detector.uprightLabeling(of: square))
        let sideways = rolledPanel(degrees: 90)
        XCTAssertEqual(Detector.uprightLabeling(of: sideways),
                       Detector.uprightLabeling(of: sideways))
        XCTAssertEqual(Detector.uprightLabeling(of: sideways).aspectRatio, 4.0, accuracy: 1e-9)
    }

    /// Never throws, never fabricates: a non-finite proposal comes back
    /// untouched rather than producing NaN corner labels.
    func testUprightLabelingPassesThroughNonFiniteQuads() {
        var broken = unitQuad
        broken.topRight = CGPoint(x: .nan, y: 0.2)
        XCTAssertEqual(Detector.uprightLabeling(of: broken).topLeft, broken.topLeft)
        var infinite = unitQuad
        infinite.bottomLeft = CGPoint(x: 0.2, y: .infinity)
        XCTAssertEqual(Detector.uprightLabeling(of: infinite).topLeft, infinite.topLeft)
    }

    /// First-frame labeling and the matched path must compose: a candidate
    /// acquired at an awkward roll, then tracked, keeps a 4:1 aspect for the
    /// whole sweep. This is the end-to-end statement of the defect.
    func testUprightAcquisitionFollowedByTrackingHoldsAspectRatio() {
        for acquisitionAngle in [0, 40, 95, 140] as [CGFloat] {
            var previous = Detector.uprightLabeling(of: rolledPanel(degrees: acquisitionAngle))
            XCTAssertEqual(previous.aspectRatio, 4.0, accuracy: 1e-9,
                           "acquired at \(acquisitionAngle)°")
            for step in 1...40 {
                let truth = rolledPanel(degrees: acquisitionAngle + CGFloat(step) * 0.5)
                previous = Detector.continuousLabeling(of: truth.normalizedCornerOrder(),
                                                       matching: previous)
                XCTAssertEqual(previous.aspectRatio, 4.0, accuracy: 1e-9,
                               "acquired at \(acquisitionAngle)°, tracked \(step) steps")
            }
        }
    }

    // MARK: - aspectRatioScore

    func testAspectRatioScoreIsOneAcrossTheWholeBand() {
        for aspect in [1.5, 2.0, 3.0, 4.0, 5.0, 5.5, 6.0] as [CGFloat] {
            XCTAssertEqual(Detector.aspectRatioScore(aspect), 1.0, accuracy: 1e-6,
                           "aspect \(aspect) should be inside the display band")
        }
    }

    func testAspectRatioScoreFallsOffBelowTheBand() {
        // Band low = 1.5, zero at low/3 = 0.5, linear between.
        XCTAssertEqual(Detector.aspectRatioScore(0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(0.4), 0, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(1.0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(1.25), 0.75, accuracy: 1e-6)
    }

    func testAspectRatioScoreFallsOffAboveTheBand() {
        // Band high = 6.0, zero at high * 2 = 12, linear between.
        XCTAssertEqual(Detector.aspectRatioScore(9.0), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(7.5), 0.75, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(12.0), 0, accuracy: 1e-6)
        XCTAssertEqual(Detector.aspectRatioScore(20.0), 0, accuracy: 1e-6)
    }

    func testAspectRatioScoreIsMonotonicAcrossTheSweep() {
        var previous = Detector.aspectRatioScore(0.01)
        var aspect: CGFloat = 0.01
        while aspect <= 1.5 {
            let score = Detector.aspectRatioScore(aspect)
            XCTAssertGreaterThanOrEqual(score, previous - 1e-6, "score dipped at \(aspect)")
            previous = score
            aspect += 0.01
        }
        previous = 1
        aspect = 6.0
        while aspect <= 13 {
            let score = Detector.aspectRatioScore(aspect)
            XCTAssertLessThanOrEqual(score, previous + 1e-6, "score rose at \(aspect)")
            previous = score
            aspect += 0.01
        }
    }

    func testAspectRatioScoreRejectsDegenerateInput() {
        XCTAssertEqual(Detector.aspectRatioScore(.nan), 0)
        XCTAssertEqual(Detector.aspectRatioScore(.infinity), 0)
        XCTAssertEqual(Detector.aspectRatioScore(0), 0)
        XCTAssertEqual(Detector.aspectRatioScore(-2), 0)
        XCTAssertEqual(Detector.aspectRatioScore(2, low: 0, high: 4), 0)
        XCTAssertEqual(Detector.aspectRatioScore(2, low: 4, high: 2), 0)
    }

    // MARK: - Request/scoring band consistency

    /// Vision's rectangle aspect is short/long, so the request's lower bound is
    /// the reciprocal of the scorer's upper band edge. Anything else advertises
    /// a plateau the request cannot deliver.
    func testRequestAspectBoundAdmitsTheWholeScoredBand() {
        let tuning = ScreenCandidateDetector.Tuning.default
        XCTAssertEqual(tuning.minimumAspectRatio,
                       Float(1 / tuning.displayAspectHigh),
                       accuracy: 1e-6)
        // The longest shape the request can emit must still score a full 1.
        let longest = 1 / CGFloat(tuning.minimumAspectRatio)
        XCTAssertEqual(Detector.aspectRatioScore(longest,
                                                 low: tuning.displayAspectLow,
                                                 high: tuning.displayAspectHigh),
                       1.0, accuracy: 1e-6)
        // A 5.5:1 multi-line readout, previously rejected by a 0.2 bound.
        XCTAssertLessThan(tuning.minimumAspectRatio, Float(1.0 / 5.5))
    }

    func testRequestAspectBoundTracksANarrowedBand() {
        var tuning = ScreenCandidateDetector.Tuning.default
        tuning.displayAspectHigh = 4
        XCTAssertEqual(tuning.minimumAspectRatio, 0.25, accuracy: 1e-6)
    }

    // MARK: - numericScore

    func testNumericScoreIsZeroForNoStrings() {
        XCTAssertEqual(Detector.numericScore(for: []), 0)
    }

    func testNumericScoreIsOneForPureDigits() {
        XCTAssertEqual(Detector.numericScore(for: ["123"]), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Detector.numericScore(for: ["12", "345", "6"]), 1.0, accuracy: 1e-6)
    }

    func testNumericScoreIsZeroForPureLetters() {
        XCTAssertEqual(Detector.numericScore(for: ["HOLD", "AUTO"]), 0, accuracy: 1e-6)
    }

    func testNumericScoreBlendsParseFractionAndDigitDensity() {
        // "12.345": parses (1.0) and 5 of 6 non-space characters are digits.
        XCTAssertEqual(Detector.numericScore(for: ["12.345"]),
                       0.6 + 0.4 * (5.0 / 6.0), accuracy: 1e-5)
        // "CH1 12.345 V": parses, 6 of 10 non-space characters are digits.
        XCTAssertEqual(Detector.numericScore(for: ["CH1 12.345 V"]),
                       0.6 + 0.4 * 0.6, accuracy: 1e-5)
    }

    /// The whole reason for the blend: a labelled reading must outscore a pure
    /// annunciator even though both "parse cleanly" in their own way.
    func testNumericScorePrefersReadoutsOverAnnunciators() {
        let readout = Detector.numericScore(for: ["12.345"])
        let mixed = Detector.numericScore(for: ["CH1 12.345 V"])
        let annunciator = Detector.numericScore(for: ["HOLD AUTO"])
        XCTAssertGreaterThan(readout, mixed)
        XCTAssertGreaterThan(mixed, annunciator)
    }

    func testNumericScoreStaysInUnitRange() {
        for strings in [["0"], ["-1.5"], [""], ["   "], ["...", "12"], ["V"]] {
            let score = Detector.numericScore(for: strings)
            XCTAssertGreaterThanOrEqual(score, 0, "\(strings)")
            XCTAssertLessThanOrEqual(score, 1, "\(strings)")
        }
    }

    // MARK: - quadContains

    func testQuadContainsInteriorPoints() {
        XCTAssertTrue(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: 0.4)))
        XCTAssertTrue(Detector.quadContains(unitQuad, CGPoint(x: 0.25, y: 0.25)))
        XCTAssertTrue(Detector.quadContains(unitQuad, unitQuad.center))
    }

    func testQuadContainsRejectsExteriorPoints() {
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.1, y: 0.4)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.9, y: 0.4)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: 0.1)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: 0.9)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0, y: 0)))
    }

    func testQuadContainsAcceptsEdgeAndVertexPoints() {
        XCTAssertTrue(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: 0.2)))
        XCTAssertTrue(Detector.quadContains(unitQuad, CGPoint(x: 0.2, y: 0.4)))
        XCTAssertTrue(Detector.quadContains(unitQuad, unitQuad.topLeft))
        XCTAssertTrue(Detector.quadContains(unitQuad, unitQuad.bottomRight))
    }

    func testQuadContainsIsWindingAgnostic() {
        let reversed = ScreenQuad(topLeft: unitQuad.bottomLeft,
                                  topRight: unitQuad.bottomRight,
                                  bottomRight: unitQuad.topRight,
                                  bottomLeft: unitQuad.topLeft)
        XCTAssertTrue(Detector.quadContains(reversed, CGPoint(x: 0.5, y: 0.4)))
        XCTAssertFalse(Detector.quadContains(reversed, CGPoint(x: 0.05, y: 0.4)))
    }

    /// The defect: every comparison against NaN is false, so a NaN point set
    /// neither sign and fell through as "inside". A NaN text box would then be
    /// counted inside every candidate on the frame.
    func testQuadContainsRejectsNonFinitePoints() {
        let nan = CGFloat.nan
        let infinite = CGFloat.infinity
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: nan, y: nan)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: nan, y: 0.4)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: nan)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: infinite, y: 0.4)))
        XCTAssertFalse(Detector.quadContains(unitQuad, CGPoint(x: 0.5, y: -infinite)))
    }

    func testQuadContainsRejectsNonFiniteQuads() {
        var broken = unitQuad
        broken.topRight = CGPoint(x: CGFloat.nan, y: 0.2)
        XCTAssertFalse(Detector.quadContains(broken, CGPoint(x: 0.5, y: 0.4)))
    }

    // MARK: - Stability model

    /// Stability integrates frame-time seconds, so the same physical dwell must
    /// produce the same value regardless of capture rate. Drives the detector's
    /// own accumulator, not a copy of it.
    func testStabilityAccumulationIsFrameRateIndependent() {
        /// Replays a dwell as `fps` evenly spaced frames, exactly as the pass
        /// does: one `risenStability` step per frame at that frame's spacing.
        func stability(afterSeconds dwell: TimeInterval, fps: Double) -> Float {
            var value: Float = 0
            let frames = Int((dwell * fps).rounded())
            let step = 1 / fps
            for _ in 0..<frames {
                value = Detector.risenStability(value, elapsed: step)
            }
            return value
        }

        // Dwells that land on a whole frame at both rates, so the comparison is
        // about the model and not about frame quantization.
        for dwell in [1.0 / 12, 2.0 / 12, 3.0 / 12, 4.0 / 12] as [TimeInterval] {
            let slow = stability(afterSeconds: dwell, fps: 12)
            let fast = stability(afterSeconds: dwell, fps: 60)
            XCTAssertEqual(slow, fast, accuracy: 1e-5,
                           "\(dwell)s of dwell scored differently at 12 fps and 60 fps")
        }
        // Full dwell saturates at exactly the advertised rise time, whatever
        // the frame spacing.
        let rise = ScreenCandidateDetector.Tuning.default.stabilityRiseTime
        XCTAssertEqual(Detector.risenStability(0, elapsed: rise), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Detector.risenStability(0, elapsed: rise / 2), 0.5, accuracy: 1e-6)
    }

    /// One long frame interval must be worth exactly as much as the many short
    /// ones it spans — the property a frame-count model cannot have.
    func testStabilityIsAdditiveOverFrameSpacing() {
        let rise = ScreenCandidateDetector.Tuning.default.stabilityRiseTime
        var stepped: Float = 0
        for _ in 0..<8 {
            stepped = Detector.risenStability(stepped, elapsed: rise / 16)
        }
        let single = Detector.risenStability(0, elapsed: rise / 2)
        XCTAssertEqual(stepped, single, accuracy: 1e-6)
    }

    func testStabilityClampsToUnitRange() {
        XCTAssertEqual(Detector.risenStability(0.9, elapsed: 10), 1.0, accuracy: 1e-6)
        XCTAssertEqual(Detector.decayedStability(0.1, elapsed: 10), 0, accuracy: 1e-6)
        XCTAssertEqual(Detector.risenStability(-5, elapsed: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(Detector.decayedStability(5, elapsed: 0), 1.0, accuracy: 1e-6)
    }

    /// An out-of-order frame yields a negative interval; it must contribute
    /// nothing rather than unwinding stability already earned.
    func testStabilityIgnoresNegativeAndNonFiniteIntervals() {
        XCTAssertEqual(Detector.risenStability(0.5, elapsed: -1), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.decayedStability(0.5, elapsed: -1), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.risenStability(0.5, elapsed: .nan), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.decayedStability(0.5, elapsed: .infinity), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Detector.risenStability(0.5, elapsed: 1, riseTime: 0), 0.5, accuracy: 1e-6)
    }

    /// Rise and decay must be exact inverses at equal elapsed time, so a
    /// candidate that flickers out for one interval and back loses exactly what
    /// that interval was worth.
    func testStabilityDecayMirrorsRise() {
        let tuning = ScreenCandidateDetector.Tuning.default
        XCTAssertEqual(tuning.stabilityRiseTime, tuning.stabilityDecayTime, accuracy: 1e-9)
        let up = Detector.risenStability(0.4, elapsed: 0.1)
        let down = Detector.decayedStability(up, elapsed: 0.1)
        XCTAssertEqual(down, 0.4, accuracy: 1e-6)
    }

    func testStabilityTuningIsExpressedInSeconds() {
        let tuning = ScreenCandidateDetector.Tuning.default
        XCTAssertGreaterThan(tuning.stabilityRiseTime, 0)
        XCTAssertGreaterThan(tuning.stabilityDecayTime, 0)
        // Saturating must be reachable well inside the identity timeout,
        // otherwise a candidate can never earn full stability before its
        // identity is eligible to expire.
        XCTAssertLessThan(tuning.stabilityRiseTime, tuning.historyTimeout)
    }

    func testHistoryIsCapped() {
        XCTAssertGreaterThan(ScreenCandidateDetector.Tuning.default.maximumHistory,
                             ScreenCandidateDetector.Tuning.default.maximumObservations)
        XCTAssertLessThan(ScreenCandidateDetector.Tuning.default.maximumHistory, 256)
    }

    // MARK: - Actor surface

    /// `reset` must be reachable and must not require a live frame — the frame
    /// source swap path calls it directly.
    func testResetIsSafeOnAFreshDetector() async {
        let detector = ScreenCandidateDetector()
        await detector.reset()
        await detector.reset()
    }
}
