//
//  QuadTrackerTests.swift
//  DAQPalTests
//
//  Deterministic coverage for the tracking layer's decision path: `QuadSanity`'s
//  gates, `DampedQuadTracker`'s smoothing/confidence policy, and the
//  `TrackedQuadGate` that composes them — which is the same object
//  `VisionScreenTracker` runs every Vision observation through, so this is the
//  shipped policy and not a parallel implementation of it.
//
//  `VNTrackRectangleRequest` itself is deliberately not exercised for tracking
//  *quality*: it needs a real image sequence to build its appearance model, so
//  driving it with synthetic single frames would assert nothing. What is
//  exercised on the actor is the lifecycle it owns.
//
//  No `Date()`, no randomness, no sleeps — every timestamp is synthetic.
//

import CoreGraphics
import CoreVideo
import Vision
import XCTest
@testable import DAQPal

final class QuadTrackerTests: XCTestCase {

    private var dt: TimeInterval { 1.0 / 30.0 }

    // MARK: - Helpers

    private func quad(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> ScreenQuad {
        ScreenQuad(roi: NormalizedROI(x: x, y: y, width: w, height: h))
    }

    /// A quad translated by (dx, dy).
    private func shifted(_ q: ScreenQuad, dx: CGFloat, dy: CGFloat) -> ScreenQuad {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        return ScreenQuad(topLeft: move(q.topLeft), topRight: move(q.topRight),
                          bottomRight: move(q.bottomRight), bottomLeft: move(q.bottomLeft))
    }

    /// A quad with a perspective-like shear: top edge narrowed about the center.
    private func keystoned(_ q: ScreenQuad, by amount: CGFloat) -> ScreenQuad {
        let c = q.center
        func pull(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + (c.x - p.x) * amount, y: p.y) }
        return ScreenQuad(topLeft: pull(q.topLeft), topRight: pull(q.topRight),
                          bottomRight: q.bottomRight, bottomLeft: q.bottomLeft)
    }

    /// The same four points, delivered with top and bottom slots swapped. This
    /// is what a detector relabel looks like: identical geometry on screen,
    /// mirrored canonical space.
    private func verticallyRelabelled(_ q: ScreenQuad) -> ScreenQuad {
        ScreenQuad(topLeft: q.bottomLeft, topRight: q.bottomRight,
                   bottomRight: q.topRight, bottomLeft: q.topLeft)
    }

    /// The same four points, rotated one slot around the winding order.
    private func cyclicallyRelabelled(_ q: ScreenQuad) -> ScreenQuad {
        ScreenQuad(topLeft: q.topRight, topRight: q.bottomRight,
                   bottomRight: q.bottomLeft, bottomLeft: q.topLeft)
    }

    /// Reflex vertex at bottomRight — nonzero area, but not solvable.
    private var nonConvexQuad: ScreenQuad {
        ScreenQuad(topLeft: CGPoint(x: 0.2, y: 0.2),
                   topRight: CGPoint(x: 0.5, y: 0.2),
                   bottomRight: CGPoint(x: 0.3, y: 0.28),
                   bottomLeft: CGPoint(x: 0.2, y: 0.4))
    }

    private func makeFrame(timestamp: TimeInterval) throws -> TimestampedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 320, 240,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        XCTAssertEqual(status, kCVReturnSuccess)
        return TimestampedFrame(pixelBuffer: try XCTUnwrap(buffer), timestamp: timestamp)
    }

    // MARK: - Seeding

    func testDampedTracker_firstObservationIsAdoptedExactly() {
        var tracker = DampedQuadTracker()
        let observed = quad(x: 0.2, y: 0.3, w: 0.4, h: 0.2)

        let update = tracker.update(observed: observed, at: 0)

        XCTAssertEqual(update?.quad, observed, "the first observation seeds the tracker with no smoothing to apply")
        XCTAssertEqual(update?.confidence, 1)
        XCTAssertEqual(tracker.quad, observed)
    }

    func testDampedTracker_resetClearsState() {
        var tracker = DampedQuadTracker()
        tracker.update(observed: quad(x: 0.2, y: 0.3, w: 0.4, h: 0.2), at: 0)
        tracker.reset()

        XCTAssertNil(tracker.quad)
        XCTAssertNil(tracker.lastTimestamp)
        XCTAssertEqual(tracker.confidence, 0)
    }

    func testDampedTracker_startDiscardsPreviousTarget() {
        var tracker = DampedQuadTracker()
        tracker.start(quad: quad(x: 0.1, y: 0.1, w: 0.2, h: 0.1), at: 0)
        let replacement = quad(x: 0.6, y: 0.6, w: 0.3, h: 0.2)
        tracker.start(quad: replacement, at: 1)

        XCTAssertEqual(tracker.quad, replacement, "a new target must not inherit the previous geometry")
        XCTAssertEqual(tracker.lastTimestamp, 1)
    }

    func testDampedTracker_startRejectsUnsolvableSeed() {
        var tracker = DampedQuadTracker()
        let seeded = tracker.start(quad: nonConvexQuad, at: 0)

        XCTAssertFalse(seeded, "a non-convex seed has no solvable homography and must be refused")
        XCTAssertNil(tracker.quad, "a refused seed must not become the tracked geometry")
        XCTAssertEqual(tracker.confidence, 0)
    }

    func testDampedTracker_refusedSeedDoesNotStrandPreviousTarget() {
        var tracker = DampedQuadTracker()
        tracker.start(quad: quad(x: 0.1, y: 0.1, w: 0.2, h: 0.1), at: 0)

        XCTAssertFalse(tracker.start(quad: nonConvexQuad, at: 1))
        XCTAssertNil(tracker.quad, "a refused seed clears the tracker rather than silently keeping the old target")
    }

    // MARK: - Tuning validation

    func testDampedTracker_invalidTuningIsClampedOnAssignment() {
        var tracker = DampedQuadTracker()
        tracker.responsiveness = 5
        tracker.referenceInterval = -1
        tracker.jumpTolerance = 0

        XCTAssertEqual(tracker.responsiveness, 1)
        XCTAssertGreaterThan(tracker.referenceInterval, 0, "a non-positive reference interval freezes damping")
        XCTAssertGreaterThan(tracker.jumpTolerance, 0, "a zero tolerance makes every confidence NaN")
    }

    func testDampedTracker_zeroJumpToleranceCannotProduceNaNConfidence() {
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.jumpTolerance = 0
        let start = quad(x: 0.3, y: 0.3, w: 0.2, h: 0.2)
        tracker.start(quad: start, at: 0)

        tracker.update(observed: shifted(start, dx: 0.01, dy: 0), at: dt)

        XCTAssertFalse(tracker.confidence.isNaN, "NaN compares false against every threshold, defeating degraded/lost")
        XCTAssertTrue((0...1).contains(tracker.confidence))
    }

    // MARK: - Convergence

    func testDampedTracker_convergesTowardStaticObservation() {
        let start = quad(x: 0.1, y: 0.1, w: 0.3, h: 0.2)
        let target = quad(x: 0.5, y: 0.4, w: 0.3, h: 0.2)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: start, at: 0)

        var previousDistance = start.meanCornerDistance(to: target)
        for i in 1...20 {
            guard let update = tracker.update(observed: target, at: Double(i) * dt) else {
                return XCTFail("static convex observation must always produce an update")
            }
            let distance = update.quad.meanCornerDistance(to: target)
            XCTAssertLessThan(distance, previousDistance, "step \(i) must move strictly closer to the observation")
            previousDistance = distance
        }
        XCTAssertLessThan(previousDistance, 1e-4, "20 half-steps must be visually converged")
    }

    func testDampedTracker_convergenceIsMonotoneNotOvershooting() {
        let start = quad(x: 0.1, y: 0.1, w: 0.3, h: 0.2)
        let target = shifted(start, dx: 0.2, dy: 0)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: start, at: 0)

        for i in 1...10 {
            guard let update = tracker.update(observed: target, at: Double(i) * dt) else {
                return XCTFail("expected an update")
            }
            // Damping closes a fraction of the error; x must stay inside the
            // interval [start, target] on every frame.
            XCTAssertGreaterThanOrEqual(update.quad.topLeft.x, start.topLeft.x)
            XCTAssertLessThanOrEqual(update.quad.topLeft.x, target.topLeft.x)
        }
    }

    func testDampedTracker_responsivenessOneFollowsObservationExactly() {
        var tracker = DampedQuadTracker(responsiveness: 1, referenceInterval: dt)
        let start = quad(x: 0.1, y: 0.1, w: 0.3, h: 0.2)
        tracker.start(quad: start, at: 0)
        let observed = quad(x: 0.5, y: 0.5, w: 0.3, h: 0.2)

        let update = tracker.update(observed: observed, at: dt)

        XCTAssertEqual(update?.quad.topLeft.x ?? -1, observed.topLeft.x, accuracy: 1e-12)
        XCTAssertEqual(update?.quad.bottomRight.y ?? -1, observed.bottomRight.y, accuracy: 1e-12)
    }

    // MARK: - Frame-rate scaling

    func testDampingFactor_matchesResponsivenessAtTheReferenceInterval() {
        let tracker = DampedQuadTracker(responsiveness: 0.25, referenceInterval: dt)
        XCTAssertEqual(tracker.dampingFactor(dt: dt), 0.25, accuracy: 1e-12)
    }

    func testDampingFactor_twoHalfStepsEqualOneFullStep() {
        let tracker = DampedQuadTracker(responsiveness: 0.4, referenceInterval: dt)
        let half = tracker.dampingFactor(dt: dt / 2)
        let full = tracker.dampingFactor(dt: dt)
        // Remaining error multiplies, so (1-half)^2 must equal (1-full).
        XCTAssertEqual((1 - half) * (1 - half), 1 - full, accuracy: 1e-12)
    }

    /// Frame-rate scaling only has observable consequences while the target is
    /// *moving*: against a static observation any exponential law converges to
    /// the same place, so equal-wall-time convergence is an algebraic identity
    /// that no damping law can fail. Against a target moving at constant
    /// velocity the tracker settles at a steady-state lag, and that lag is where
    /// a per-frame-constant law diverges — it would halve the lag going from 30
    /// to 60 fps and double it going to 15, i.e. tracking accuracy would become
    /// a function of CPU load. Frame-rate scaling leaves a residual difference
    /// (the discretization of a continuous exponential), which is why the bands
    /// below are ratios rather than equalities.
    func testDampedTracker_trackingLagIsFrameRateIndependentForAMovingTarget() {
        let base = quad(x: 0.1, y: 0.4, w: 0.3, h: 0.2)
        let velocity: CGFloat = 0.2

        func lagAfterOneSecond(frameRate: Double) -> CGFloat {
            var tracker = DampedQuadTracker(responsiveness: 0.3, referenceInterval: 1.0 / 30.0)
            tracker.start(quad: base, at: 0)
            let step = 1.0 / frameRate
            for i in 1...Int(frameRate) {
                let t = Double(i) * step
                tracker.update(observed: shifted(base, dx: velocity * CGFloat(t), dy: 0), at: t)
            }
            let truth = shifted(base, dx: velocity, dy: 0)
            return tracker.quad?.meanCornerDistance(to: truth) ?? .infinity
        }

        let at15 = lagAfterOneSecond(frameRate: 15)
        let at30 = lagAfterOneSecond(frameRate: 30)
        let at60 = lagAfterOneSecond(frameRate: 60)

        XCTAssertGreaterThan(at30, 0, "a moving target must produce a measurable lag to compare")
        XCTAssertEqual(at60 / at30, 1, accuracy: 0.4,
                       "doubling the capture rate must not materially change how far behind the target the tracker sits")
        XCTAssertEqual(at15 / at30, 1, accuracy: 0.4,
                       "halving the capture rate must not materially change how far behind the target the tracker sits")
    }

    func testDampedTracker_nonAdvancingTimestampStillMakesProgress() {
        let start = quad(x: 0.1, y: 0.1, w: 0.3, h: 0.2)
        let target = shifted(start, dx: 0.2, dy: 0)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: start, at: 5)

        // A repeated or backwards timestamp must not freeze the tracker.
        guard let update = tracker.update(observed: target, at: 5) else {
            return XCTFail("expected an update")
        }
        XCTAssertLessThan(update.quad.meanCornerDistance(to: target),
                          start.meanCornerDistance(to: target))
    }

    // MARK: - Confidence

    func testDampedTracker_largeJumpLowersConfidence() {
        let start = quad(x: 0.3, y: 0.3, w: 0.2, h: 0.2)

        func confidence(afterJump dx: CGFloat) -> Float {
            var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
            tracker.start(quad: start, at: 0)
            tracker.update(observed: shifted(start, dx: dx, dy: 0), at: dt)
            return tracker.confidence
        }

        let small = confidence(afterJump: 0.01)
        let medium = confidence(afterJump: 0.08)
        let large = confidence(afterJump: 0.16)

        XCTAssertGreaterThan(small, medium)
        XCTAssertGreaterThan(medium, large)
        XCTAssertGreaterThan(small, 0.9, "a 5%-of-target jump is normal hand motion")
    }

    func testDampedTracker_jumpBeyondToleranceReportsZeroConfidence() {
        let start = quad(x: 0.1, y: 0.1, w: 0.2, h: 0.2)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt, jumpTolerance: 1.0)
        tracker.start(quad: start, at: 0)

        // Jump of a full target size in each axis: normalized jump > 1.
        tracker.update(observed: shifted(start, dx: 0.4, dy: 0.4), at: dt)

        XCTAssertEqual(tracker.confidence, 0, "confidence must floor at zero, never go negative")
    }

    func testDampedTracker_confidenceIsScaleFree() {
        // The same jump expressed as a fraction of target size must score the
        // same for a small distant display and a large near one.
        func confidence(size: CGFloat) -> Float {
            let base = quad(x: 0.1, y: 0.1, w: size, h: size)
            var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
            tracker.start(quad: base, at: 0)
            tracker.update(observed: shifted(base, dx: size * 0.1, dy: 0), at: dt)
            return tracker.confidence
        }

        XCTAssertEqual(confidence(size: 0.1), confidence(size: 0.5), accuracy: 1e-6)
    }

    func testDampedTracker_confidenceIsDtNormalized() {
        // Identical physical motion — same displacement per second — sampled at
        // two capture rates. Normalizing the jump by dt is what stops a dropped
        // frame from reading as a tracking failure.
        func confidence(frameRate: Double) -> Float {
            let base = quad(x: 0.3, y: 0.3, w: 0.2, h: 0.2)
            var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: 1.0 / 30.0)
            tracker.start(quad: base, at: 0)
            let step = 1.0 / frameRate
            tracker.update(observed: shifted(base, dx: 0.2 * CGFloat(step), dy: 0), at: step)
            return tracker.confidence
        }

        XCTAssertEqual(confidence(frameRate: 60), confidence(frameRate: 30), accuracy: 1e-6)
        XCTAssertEqual(confidence(frameRate: 15), confidence(frameRate: 30), accuracy: 1e-6)
        XCTAssertLessThan(confidence(frameRate: 30), 1, "the test motion must actually cost confidence")
    }

    func testDampedTracker_largerObservationCannotBuyABetterScore() {
        // Two observations with an identical mean corner jump: one a pure
        // translation of the tracked quad, one a uniform 1.7× expansion about
        // its centre. Normalizing by the *observation's* size made the larger
        // one score better purely by inflating its own denominator; normalizing
        // by the smaller of the two makes the jump the only thing that matters.
        let current = quad(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        let expanded = quad(x: 0.33, y: 0.33, w: 0.34, h: 0.34)
        let translated = shifted(current, dx: 0.07, dy: 0.07)

        XCTAssertEqual(current.meanCornerDistance(to: expanded),
                       current.meanCornerDistance(to: translated),
                       accuracy: 1e-12,
                       "the two observations must present the same jump for the comparison to mean anything")
        XCTAssertGreaterThan(QuadSanity.meanSize(expanded), QuadSanity.meanSize(current))

        func confidence(after observed: ScreenQuad) -> Float {
            var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
            tracker.start(quad: current, at: 0)
            tracker.update(observed: observed, at: dt)
            return tracker.confidence
        }

        XCTAssertEqual(confidence(after: expanded), confidence(after: translated), accuracy: 1e-6,
                       "a larger observation must not score better for the same jump")
        XCTAssertLessThan(confidence(after: expanded), 1)
    }

    func testDampedTracker_areaBlowupIsRejectedOutright() {
        let start = quad(x: 0.4, y: 0.4, w: 0.2, h: 0.2)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: start, at: 0)

        // Full-frame quad replacing a small display: 25× the area in one frame.
        XCTAssertNil(tracker.update(observed: quad(x: 0, y: 0, w: 1, h: 1), at: dt))
        XCTAssertEqual(tracker.quad, start, "a rejected frame must leave the estimate untouched")
    }

    func testDampedTracker_steadyObservationKeepsConfidenceHigh() {
        let target = quad(x: 0.25, y: 0.25, w: 0.4, h: 0.25)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: target, at: 0)

        for i in 1...30 {
            tracker.update(observed: target, at: Double(i) * dt)
        }
        XCTAssertEqual(tracker.confidence, 1, accuracy: 1e-6)
    }

    // MARK: - Convexity

    func testDampedTracker_smoothingNeverProducesNonConvexQuadFromConvexInputs() {
        let start = quad(x: 0.05, y: 0.05, w: 0.5, h: 0.3)
        var tracker = DampedQuadTracker(responsiveness: 0.35, referenceInterval: dt)
        tracker.start(quad: start, at: 0)

        // A deterministic sweep of translation + keystone: every observation is
        // convex, so every smoothed result must be too.
        for i in 1...60 {
            let phase = CGFloat(i) / 60
            let observed = keystoned(shifted(start, dx: phase * 0.3, dy: phase * 0.2),
                                     by: phase * 0.6)
            XCTAssertTrue(observed.isConvex, "test input at step \(i) must itself be convex")
            guard let update = tracker.update(observed: observed, at: Double(i) * dt) else {
                return XCTFail("convex observation at step \(i) must produce an update")
            }
            XCTAssertTrue(update.quad.isConvex, "smoothed quad at step \(i) must stay convex")
            XCTAssertGreaterThan(update.quad.area, 0)
        }
    }

    func testDampedTracker_nonConvexObservationIsRejectedAndLeavesStateIntact() {
        let start = quad(x: 0.2, y: 0.2, w: 0.3, h: 0.2)
        var tracker = DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt)
        tracker.start(quad: start, at: 0)

        let reflex = nonConvexQuad
        XCTAssertFalse(reflex.isConvex, "test input must actually be non-convex")

        XCTAssertNil(tracker.update(observed: reflex, at: dt))
        XCTAssertEqual(tracker.quad, start, "a rejected frame must leave the estimate untouched")
        XCTAssertEqual(tracker.lastTimestamp, 0)
    }

    // MARK: - QuadSanity gates

    func testQuadSanity_areaRatioBandWidensWithElapsedTime() {
        let oneFrame = QuadSanity.areaRatioBounds(dt: dt, referenceInterval: dt)
        let threeFrames = QuadSanity.areaRatioBounds(dt: dt * 3, referenceInterval: dt)

        XCTAssertEqual(oneFrame.max, QuadSanity.maxAreaGrowth, accuracy: 1e-9,
                       "at the nominal frame interval the gate is unchanged")
        XCTAssertGreaterThan(threeFrames.max, oneFrame.max,
                             "dropped frames make a larger delta legitimate, so the gate must be a rate not a per-frame limit")
        XCTAssertEqual(threeFrames.min * threeFrames.max, 1, accuracy: 1e-9,
                       "growth and shrink limits are reciprocal")
    }

    func testQuadSanity_areaRatioBandIsCappedForLongGaps() {
        let long = QuadSanity.areaRatioBounds(dt: 60, referenceInterval: dt)
        XCTAssertEqual(long.max,
                       pow(QuadSanity.maxAreaGrowth, QuadSanity.maxRelaxedIntervals),
                       accuracy: 1e-6,
                       "a stall must widen the gate, not switch it off")
    }

    func testQuadSanity_verticalRelabelPassesEveryOtherGate() {
        // The point of the orientation check: this frame is indistinguishable
        // from a good one by convexity, area and frame overlap.
        let good = quad(x: 0.2, y: 0.3, w: 0.4, h: 0.2)
        let relabelled = verticallyRelabelled(good)

        XCTAssertTrue(relabelled.isConvex)
        XCTAssertTrue(QuadSanity.intersectsFrame(relabelled))
        XCTAssertEqual(relabelled.area, good.area, accuracy: 1e-12)
        XCTAssertFalse(QuadSanity.isOrientationContinuous(previous: good, observed: relabelled),
                       "a reversed winding is a relabel, and it mirrors canonical space")
    }

    func testQuadSanity_cyclicRelabelIsRejected() {
        let good = quad(x: 0.35, y: 0.35, w: 0.3, h: 0.3)
        let relabelled = cyclicallyRelabelled(good)

        XCTAssertEqual(QuadSanity.signedArea(relabelled).sign, QuadSanity.signedArea(good).sign,
                       "a cyclic relabel keeps the winding, so the sign check alone cannot catch it")
        XCTAssertFalse(QuadSanity.isOrientationContinuous(previous: good, observed: relabelled))
    }

    func testQuadSanity_ordinaryMotionStaysOrientationContinuous() {
        let previous = quad(x: 0.2, y: 0.3, w: 0.4, h: 0.2)

        XCTAssertTrue(QuadSanity.isOrientationContinuous(previous: previous,
                                                         observed: shifted(previous, dx: 0.05, dy: 0.03)))
        XCTAssertTrue(QuadSanity.isOrientationContinuous(previous: previous,
                                                         observed: keystoned(previous, by: 0.3)))
        XCTAssertTrue(QuadSanity.isOrientationContinuous(previous: previous,
                                                         observed: quad(x: 0.1, y: 0.2, w: 0.7, h: 0.4)),
                      "walking toward the display is motion, not a relabel")
    }

    func testQuadSanity_intersectsFrameRejectsFullyOffscreenGeometry() {
        XCTAssertTrue(QuadSanity.intersectsFrame(quad(x: 0.9, y: 0.9, w: 0.4, h: 0.4)),
                      "a partly visible display is still trackable")
        XCTAssertFalse(QuadSanity.intersectsFrame(quad(x: 1.4, y: 0.2, w: 0.3, h: 0.2)))
        XCTAssertFalse(QuadSanity.intersectsFrame(quad(x: 0.2, y: -0.9, w: 0.3, h: 0.2)))
    }

    // MARK: - TrackedQuadGate (the shipped decision path)

    func testGate_seedRefusesUnsolvableGeometry() {
        var gate = TrackedQuadGate()
        XCTAssertFalse(gate.seed(quad: nonConvexQuad, at: 0))
        XCTAssertNil(gate.lastAccepted)
    }

    func testGate_acceptsOrdinaryMotion() {
        let start = quad(x: 0.3, y: 0.3, w: 0.3, h: 0.2)
        var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        XCTAssertTrue(gate.seed(quad: start, at: 0))

        let outcome = gate.admit(shifted(start, dx: 0.02, dy: 0.01), visionConfidence: 1, at: dt)

        guard case .accepted(let update) = outcome else {
            return XCTFail("ordinary motion must be accepted, got \(outcome)")
        }
        XCTAssertGreaterThan(update.confidence, 0.8)
        XCTAssertEqual(gate.consecutiveRejections, 0)
        XCTAssertEqual(gate.lastAccepted, update.quad)
    }

    func testGate_rejectsRelabelledObservation() {
        let start = quad(x: 0.2, y: 0.3, w: 0.4, h: 0.2)
        var gate = TrackedQuadGate()
        gate.seed(quad: start, at: 0)

        let outcome = gate.admit(verticallyRelabelled(start), visionConfidence: 1, at: dt)

        XCTAssertEqual(outcome.rejection, .orientation)
        XCTAssertEqual(gate.lastAccepted, start, "a rejected frame must not become the reference geometry")
    }

    func testGate_rejectsOffFrameObservation() {
        var gate = TrackedQuadGate()
        gate.seed(quad: quad(x: 0.4, y: 0.4, w: 0.2, h: 0.2), at: 0)

        let outcome = gate.admit(quad(x: 1.5, y: 0.4, w: 0.2, h: 0.2), visionConfidence: 1, at: dt)

        XCTAssertEqual(outcome.rejection, .offFrame)
    }

    func testGate_rejectsNonConvexObservation() {
        var gate = TrackedQuadGate()
        gate.seed(quad: quad(x: 0.2, y: 0.2, w: 0.3, h: 0.2), at: 0)

        XCTAssertEqual(gate.admit(nonConvexQuad, visionConfidence: 1, at: dt).rejection, .nonConvex)
    }

    func testGate_areaGateRejectsAtNominalRateButAllowsTheSameChangeAcrossDroppedFrames() {
        let start = quad(x: 0.1, y: 0.1, w: 0.1, h: 0.1)
        let grown = quad(x: 0.1, y: 0.1, w: 0.25, h: 0.25)   // 6.25× the area

        var tight = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        tight.seed(quad: start, at: 0)
        XCTAssertEqual(tight.admit(grown, visionConfidence: 1, at: dt).rejection, .areaRate)

        var relaxed = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        relaxed.seed(quad: start, at: 0)
        // Same geometry change, but two frames were dropped getting here.
        XCTAssertNotNil(relaxed.admit(grown, visionConfidence: 1, at: dt * 3).update,
                        "a per-frame area gate rejects normal motion whenever the pipeline drops frames")
    }

    func testGate_recoversAfterSustainedRejection() {
        let start = quad(x: 0.1, y: 0.1, w: 0.05, h: 0.05)
        // Far outside even the fully relaxed area band, so nothing but the
        // recovery path can let it through.
        let huge = quad(x: 0.2, y: 0.2, w: 0.6, h: 0.6)

        var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        gate.seed(quad: start, at: 0)

        for i in 1...TrackedQuadGate.rejectionsBeforeReseed {
            let outcome = gate.admit(huge, visionConfidence: 1, at: Double(i) * dt)
            XCTAssertEqual(outcome.rejection, .areaRate, "frame \(i) must still be rejected")
        }

        let recovery = gate.admit(huge, visionConfidence: 1,
                                  at: Double(TrackedQuadGate.rejectionsBeforeReseed + 1) * dt)
        guard case .reseeded(let update) = recovery else {
            return XCTFail("the tracker must re-seed rather than reject forever, got \(recovery)")
        }
        XCTAssertEqual(update.quad, huge)
        XCTAssertEqual(gate.lastAccepted, huge)
        XCTAssertEqual(gate.consecutiveRejections, 0)
        XCTAssertLessThan(update.confidence, SnapTuning.default.degradedTracking,
                          "a re-seed must report as degraded, not as a healthy frame")

        // And the tracker is usable again immediately afterwards.
        let next = gate.admit(shifted(huge, dx: 0.01, dy: 0),
                              visionConfidence: 1,
                              at: Double(TrackedQuadGate.rejectionsBeforeReseed + 2) * dt)
        XCTAssertNotNil(next.update)
    }

    /// Re-seeding is a recovery from *bad observations*, not a licence to
    /// change which display is being tracked. Field regions are canonical-space
    /// projections of the tracked quad, so a migrated lock reads every value
    /// off the wrong screen while still reporting a healthy target.
    func testGate_recoveryRefusesToMigrateToUnrelatedGeometry() {
        let start = quad(x: 0.05, y: 0.05, w: 0.08, h: 0.08)
        // Plausible on its own terms — convex, on screen, same winding — but on
        // the far side of the frame and nowhere near the tracked display.
        let elsewhere = quad(x: 0.75, y: 0.75, w: 0.2, h: 0.2)
        XCTAssertTrue(elsewhere.isConvex)
        XCTAssertTrue(QuadSanity.intersectsFrame(elsewhere))
        XCTAssertTrue(QuadSanity.isOrientationContinuous(previous: start, observed: elsewhere),
                      "the migration must be blocked on proximity, not smuggled past by another gate")
        XCTAssertEqual(start.boundingBoxIoU(with: elsewhere), 0, accuracy: 1e-12)

        var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        gate.seed(quad: start, at: 0)

        // Recovery arms on consecutive rejections of ANY kind, so the run of
        // unusable frames that gets us there is deliberately unrelated to the
        // observation being offered afterwards.
        for i in 1...TrackedQuadGate.rejectionsBeforeReseed {
            XCTAssertEqual(gate.admit(nonConvexQuad, visionConfidence: 1, at: Double(i) * dt).rejection,
                           .nonConvex, "frame \(i) must still be rejected")
        }
        XCTAssertEqual(gate.consecutiveRejections, TrackedQuadGate.rejectionsBeforeReseed)

        // Well past the re-seed threshold, and it stays rejected however long
        // the unrelated geometry keeps arriving.
        for i in 1...5 {
            let frame = TrackedQuadGate.rejectionsBeforeReseed + i
            let outcome = gate.admit(elsewhere, visionConfidence: 1, at: Double(frame) * dt)
            XCTAssertEqual(outcome.rejection, .proximity,
                           "the lock migrated to unrelated geometry on frame \(frame)")
        }
        XCTAssertEqual(gate.lastAccepted, start,
                       "a refused re-seed must leave the reference geometry alone")
    }

    /// The other half of the same gate: recovery must still work for the case
    /// it exists for — the same display, changed too much for the area gate.
    func testGate_recoveryAdoptsAReseedThatOverlapsTheLastGoodQuad() {
        let start = quad(x: 0.3, y: 0.3, w: 0.1, h: 0.1)
        // 9× the area — far outside the area band — but still overlapping the
        // tracked quad, i.e. the user walked up to the same instrument.
        let nearer = quad(x: 0.28, y: 0.28, w: 0.3, h: 0.3)
        XCTAssertGreaterThan(start.boundingBoxIoU(with: nearer), QuadSanity.reseedMinimumIoU)

        var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        gate.seed(quad: start, at: 0)
        for i in 1...TrackedQuadGate.rejectionsBeforeReseed {
            XCTAssertEqual(gate.admit(nonConvexQuad, visionConfidence: 1, at: Double(i) * dt).rejection,
                           .nonConvex)
        }

        let recovery = gate.admit(nearer, visionConfidence: 1,
                                  at: Double(TrackedQuadGate.rejectionsBeforeReseed + 1) * dt)
        guard case .reseeded(let update) = recovery else {
            return XCTFail("an overlapping re-seed is the case recovery exists for, got \(recovery)")
        }
        XCTAssertEqual(update.quad, nearer)
        XCTAssertEqual(gate.lastAccepted, nearer)
    }

    /// A re-seed that reported below `lostTracking` would be strictly worse than
    /// the rejection it replaces: a rejection returns nil and leaves the snap
    /// engine's hysteresis in charge, whereas a lost confidence forces
    /// reacquisition on the frame the tracker actually recovered.
    func testGate_reseedNeverReportsBelowLostTracking() {
        let start = quad(x: 0.1, y: 0.1, w: 0.05, h: 0.05)
        let huge = quad(x: 0.2, y: 0.2, w: 0.6, h: 0.6)

        for vision in [Float(0), 0.25, 0.5, 1] {
            var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
            gate.seed(quad: start, at: 0)
            for i in 1...TrackedQuadGate.rejectionsBeforeReseed {
                _ = gate.admit(huge, visionConfidence: vision, at: Double(i) * dt)
            }
            let recovery = gate.admit(huge, visionConfidence: vision,
                                      at: Double(TrackedQuadGate.rejectionsBeforeReseed + 1) * dt)
            guard case .reseeded(let update) = recovery else {
                return XCTFail("expected a re-seed at vision confidence \(vision), got \(recovery)")
            }
            XCTAssertGreaterThanOrEqual(update.confidence, SnapTuning.default.lostTracking,
                                        "a re-seed reported as lost at vision confidence \(vision)")
            XCTAssertLessThan(update.confidence, SnapTuning.default.degradedTracking,
                              "a re-seed must still have to re-earn its confidence")
        }
    }

    func testGate_recoveryStillRefusesARelabel() {
        let start = quad(x: 0.1, y: 0.1, w: 0.05, h: 0.05)
        let huge = quad(x: 0.2, y: 0.2, w: 0.6, h: 0.6)

        var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        gate.seed(quad: start, at: 0)
        for i in 1...TrackedQuadGate.rejectionsBeforeReseed {
            _ = gate.admit(huge, visionConfidence: 1, at: Double(i) * dt)
        }

        let outcome = gate.admit(verticallyRelabelled(huge), visionConfidence: 1,
                                 at: Double(TrackedQuadGate.rejectionsBeforeReseed + 1) * dt)
        XCTAssertEqual(outcome.rejection, .orientation,
                       "re-seeding onto a mirrored labeling would mirror canonical space instead of recovering")
    }

    func testGate_visionConfidenceAttenuatesButDoesNotReplaceTheGeometricScore() {
        let start = quad(x: 0.3, y: 0.3, w: 0.3, h: 0.2)

        func confidence(vision: Float) -> Float {
            var gate = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
            gate.seed(quad: start, at: 0)
            return gate.admit(shifted(start, dx: 0.02, dy: 0), visionConfidence: vision, at: dt).update?.confidence ?? -1
        }

        var reference = TrackedQuadGate(damping: DampedQuadTracker(responsiveness: 0.5, referenceInterval: dt))
        reference.seed(quad: start, at: 0)
        _ = reference.admit(shifted(start, dx: 0.02, dy: 0), visionConfidence: 1, at: dt)
        let geometric = reference.damping.confidence

        XCTAssertEqual(confidence(vision: 1), geometric, accuracy: 1e-6,
                       "a confident Vision frame leaves the geometric score untouched")
        XCTAssertEqual(confidence(vision: 0),
                       geometric * TrackedQuadGate.visionConfidenceFloor,
                       accuracy: 1e-6,
                       "Vision at zero attenuates by the floor rather than zeroing the score")
        XCTAssertGreaterThan(confidence(vision: 0), 0,
                             "Vision's uncalibrated score must not by itself declare a steady target lost")
    }

    func testGate_blendClampsOutOfRangeVisionConfidence() {
        XCTAssertEqual(TrackedQuadGate.blend(damped: 1, vision: 5), 1, accuracy: 1e-6)
        XCTAssertEqual(TrackedQuadGate.blend(damped: 1, vision: -3),
                       TrackedQuadGate.visionConfidenceFloor, accuracy: 1e-6)
        XCTAssertFalse(TrackedQuadGate.blend(damped: 1, vision: .nan).isNaN)
    }

    func testGate_resetClearsRecoveryState() {
        var gate = TrackedQuadGate()
        gate.seed(quad: quad(x: 0.1, y: 0.1, w: 0.05, h: 0.05), at: 0)
        _ = gate.admit(quad(x: 0.2, y: 0.2, w: 0.6, h: 0.6), visionConfidence: 1, at: dt)
        gate.reset()

        XCTAssertNil(gate.lastAccepted)
        XCTAssertEqual(gate.consecutiveRejections, 0)
        XCTAssertNil(gate.damping.quad)
    }

    // MARK: - VisionScreenTracker lifecycle

    func testVisionTracker_refusesAnUnsolvableSeedAndSurvivesRepeatedReset() async throws {
        let tracker = VisionScreenTracker()

        await tracker.startTracking(quad: nonConvexQuad, in: try makeFrame(timestamp: 0))
        let update = await tracker.track(frame: try makeFrame(timestamp: dt))

        XCTAssertNil(update, "a seed with no solvable homography must not produce tracked geometry")

        await tracker.reset()
        await tracker.reset()
        let afterReset = await tracker.track(frame: try makeFrame(timestamp: 2 * dt))
        XCTAssertNil(afterReset)
    }

    // MARK: - Vision coordinate conversion

    func testVisionConversion_roundTripsThroughBottomLeftSpace() {
        let original = ScreenQuad(topLeft: CGPoint(x: 0.12, y: 0.20),
                                  topRight: CGPoint(x: 0.71, y: 0.26),
                                  bottomRight: CGPoint(x: 0.68, y: 0.55),
                                  bottomLeft: CGPoint(x: 0.15, y: 0.49))

        let observation = VisionScreenTracker.visionObservation(from: original)
        let restored = VisionScreenTracker.quad(from: observation)

        for (a, b) in zip(original.corners, restored.corners) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testVisionConversion_flipsOnlyTheVerticalAxis() {
        let q = quad(x: 0.2, y: 0.1, w: 0.4, h: 0.3)
        let observation = VisionScreenTracker.visionObservation(from: q)

        XCTAssertEqual(observation.topLeft.x, 0.2, accuracy: 1e-6, "x is unchanged between the two conventions")
        XCTAssertEqual(observation.topLeft.y, 0.9, accuracy: 1e-6, "top-left y = 0.1 becomes 0.9 in bottom-left space")
        XCTAssertEqual(observation.bottomLeft.y, 0.6, accuracy: 1e-6)
        XCTAssertGreaterThan(observation.topLeft.y, observation.bottomLeft.y,
                             "in Vision's bottom-left space the visually-upper corner has the larger y")
    }
}
