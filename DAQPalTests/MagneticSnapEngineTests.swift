//
//  MagneticSnapEngineTests.swift
//  DAQPalTests
//
//  The magnetic acquisition state machine, driven entirely by synthetic
//  candidates and synthetic timestamps. No camera, no Vision, no clock — which
//  is the whole reason `MagneticSnapEngine` is a value type with an explicit
//  `timestamp` parameter.
//
//  Geometry note: every quad here is the same size, so the mean corner distance
//  between two of them is exactly their offset. That makes the expected
//  attraction trajectory closed-form and the radius assertions readable.
//

import XCTest
@testable import DAQPal

final class MagneticSnapEngineTests: XCTestCase {

    private let tuning = SnapTuning.default
    private let candidateID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let challengerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    // MARK: - Fixtures

    private func quad(offsetX: CGFloat) -> ScreenQuad {
        ScreenQuad(roi: NormalizedROI(x: 0.3 + offsetX, y: 0.4, width: 0.3, height: 0.2))
    }

    private var target: ScreenQuad { quad(offsetX: 0) }

    private func candidate(id: UUID? = nil,
                           confidence: Float,
                           quad: ScreenQuad? = nil) -> ScreenCandidate {
        ScreenCandidate(id: id ?? candidateID,
                        quad: quad ?? target,
                        signals: .zero,
                        confidence: confidence)
    }

    /// Frame timestamps at the engine's reference rate.
    private func time(_ index: Int, rate: Double = 30) -> TimeInterval { Double(index) / rate }

    // MARK: - Happy path

    func testManualToCandidateToAttractionToPreviewToLock() {
        var engine = MagneticSnapEngine()
        var selection = quad(offsetX: 0.10)
        var frame = 0

        func step(_ confidence: Float) -> SnapOutcome {
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(frame))
            selection = outcome.quad
            frame += 1
            return outcome
        }

        XCTAssertEqual(engine.state, .manual)

        XCTAssertEqual(step(0.65).state, .candidateDetected(candidateID: candidateID))
        // Detection alone must not move the window.
        XCTAssertEqual(selection.meanCornerDistance(to: target), 0.10, accuracy: 1e-9)

        for _ in 0..<3 {
            XCTAssertEqual(step(0.75).state, .magneticAttraction(candidateID: candidateID))
        }
        // Three frames of 25% error closure at the reference rate.
        XCTAssertEqual(selection.meanCornerDistance(to: target),
                       0.10 * pow(0.75, 3), accuracy: 1e-9)

        XCTAssertEqual(step(0.85).state, .snapPreview(candidateID: candidateID))

        let first = step(0.92)
        XCTAssertEqual(first.state, .snapPreview(candidateID: candidateID))
        XCTAssertEqual(first.lockProgress, 1)
        XCTAssertFalse(first.didLock)

        let second = step(0.92)
        XCTAssertEqual(second.lockProgress, 2)
        XCTAssertFalse(second.didLock)

        let third = step(0.92)
        XCTAssertTrue(third.didLock)
        XCTAssertEqual(third.state, .locked(targetID: candidateID))
        XCTAssertEqual(third.lockedCandidate?.id, candidateID)
        // Committing snaps exactly onto the candidate, not one lerp short.
        XCTAssertEqual(third.quad, target)
    }

    // MARK: - Hysteresis

    /// Confidence dithering across `enterAttraction` must not flap the state.
    func testOscillatingConfidenceAroundAttractionThresholdDoesNotFlap() {
        var engine = MagneticSnapEngine()
        // Selection is deliberately NOT advanced from the outcome, so the
        // distance stays fixed and confidence is the only variable.
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.72)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        for i in 1...20 {
            // 0.65 is below enterAttraction (0.70) but above exitAttraction (0.60).
            let confidence: Float = i.isMultiple(of: 2) ? 0.72 : 0.65
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .magneticAttraction(candidateID: candidateID),
                           "flapped on frame \(i) at confidence \(confidence)")
        }
    }

    func testOscillatingConfidenceAroundDetectionThresholdDoesNotFlap() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.25)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.62)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .candidateDetected(candidateID: candidateID))

        for i in 1...20 {
            let confidence: Float = i.isMultiple(of: 2) ? 0.62 : 0.55
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .candidateDetected(candidateID: candidateID),
                           "flapped on frame \(i) at confidence \(confidence)")
        }
    }

    func testOscillatingConfidenceAroundPreviewThresholdDoesNotFlap() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.05)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.82)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .snapPreview(candidateID: candidateID))

        for i in 1...20 {
            let confidence: Float = i.isMultiple(of: 2) ? 0.82 : 0.72
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .snapPreview(candidateID: candidateID),
                           "flapped on frame \(i) at confidence \(confidence)")
        }
    }

    /// Dropping under the *exit* threshold still releases — hysteresis must not
    /// become a one-way latch.
    func testConfidenceBelowExitDetectionReleasesToManual() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        let outcome = engine.update(selection: selection,
                                    candidates: [candidate(confidence: 0.45)],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(1))
        XCTAssertEqual(outcome.state, .manual)
        XCTAssertTrue(outcome.didRelease)
        XCTAssertEqual(outcome.quad, selection)
    }

    /// Distance dithering across `alignmentRadius` must not flap preview either.
    func testOscillatingDistanceAroundAlignmentRadiusDoesNotFlap() {
        var engine = MagneticSnapEngine()

        _ = engine.update(selection: quad(offsetX: 0.05),
                          candidates: [candidate(confidence: 0.85)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .snapPreview(candidateID: candidateID))

        for i in 1...20 {
            // 0.068 is outside alignmentRadius (0.06) but inside the padded
            // hold radius (0.06 * 1.25 = 0.075).
            let offset: CGFloat = i.isMultiple(of: 2) ? 0.05 : 0.068
            let outcome = engine.update(selection: quad(offsetX: offset),
                                        candidates: [candidate(confidence: 0.85)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .snapPreview(candidateID: candidateID),
                           "flapped on frame \(i) at offset \(offset)")
        }
    }

    // MARK: - Lock commitment

    func testSingleLuckyFrameDoesNotLock() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.03)
        // Two qualifying frames, one dropout, two more: never three in a row.
        let confidences: [Float] = [0.92, 0.92, 0.85, 0.92, 0.92]

        for (i, confidence) in confidences.enumerated() {
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertFalse(outcome.didLock, "locked early on frame \(i)")
            XCTAssertEqual(outcome.state, .snapPreview(candidateID: candidateID))
        }
        XCTAssertEqual(engine.lockProgress, 2)

        let outcome = engine.update(selection: selection,
                                    candidates: [candidate(confidence: 0.92)],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(confidences.count))
        XCTAssertTrue(outcome.didLock)
        XCTAssertEqual(outcome.state, .locked(targetID: candidateID))
    }

    func testMisalignedFramesNeverLockHoweverConfident() {
        var engine = MagneticSnapEngine()
        // Inside attraction range but outside alignmentRadius, forever.
        let selection = quad(offsetX: 0.12)

        for i in 0..<20 {
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: 0.99)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertFalse(outcome.didLock)
            XCTAssertEqual(outcome.state, .magneticAttraction(candidateID: candidateID))
        }
    }

    // MARK: - User override

    func testDraggingDoesNotMoveTheWindow() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        let outcome = engine.update(selection: selection,
                                    candidates: [candidate(confidence: 0.95)],
                                    trackingConfidence: nil,
                                    isUserDragging: true,
                                    timestamp: time(0))
        XCTAssertEqual(outcome.quad, selection)
        XCTAssertEqual(outcome.lockProgress, 0)
        XCTAssertFalse(outcome.didLock)
    }

    func testDragBeyondReleaseRadiusReleasesAndSuppressesUntilRearmed() {
        var engine = MagneticSnapEngine()
        let confidence: Float = 0.75

        _ = engine.update(selection: quad(offsetX: 0.10),
                          candidates: [candidate(confidence: confidence)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        // Dragged clear of the candidate: releaseRadius is 0.30.
        let released = engine.update(selection: quad(offsetX: 0.35),
                                     candidates: [candidate(confidence: confidence)],
                                     trackingConfidence: nil,
                                     isUserDragging: true,
                                     timestamp: time(1))
        XCTAssertEqual(released.state, .manual)
        XCTAssertTrue(released.didRelease)
        XCTAssertEqual(engine.suppressedCandidateID, candidateID)

        // Dragged back over the candidate — the magnet must not grab back while
        // the finger is still down.
        for i in 2...5 {
            let outcome = engine.update(selection: quad(offsetX: 0.04),
                                        candidates: [candidate(confidence: confidence)],
                                        trackingConfidence: nil,
                                        isUserDragging: true,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .manual, "re-grabbed mid-drag on frame \(i)")
            XCTAssertEqual(outcome.quad, quad(offsetX: 0.04))
        }

        // Finger lifted inside attraction range: the candidate is armed again.
        let rearmed = engine.update(selection: quad(offsetX: 0.04),
                                    candidates: [candidate(confidence: confidence)],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(6))
        XCTAssertEqual(rearmed.state, .magneticAttraction(candidateID: candidateID))
        XCTAssertNil(engine.suppressedCandidateID)
    }

    func testExplicitReleaseSuppressesUntilTheWindowLeavesAndReturns() {
        var engine = MagneticSnapEngine()

        _ = engine.update(selection: quad(offsetX: 0.10),
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        engine.release()
        XCTAssertEqual(engine.state, .manual)

        // Sitting right next to the candidate is not enough — the user said no.
        for i in 1...5 {
            let outcome = engine.update(selection: quad(offsetX: 0.10),
                                        candidates: [candidate(confidence: 0.75)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .manual, "re-attracted after release on frame \(i)")
        }

        // Out past releaseRadius, then back in: armed again.
        _ = engine.update(selection: quad(offsetX: 0.40),
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(6))
        let rearmed = engine.update(selection: quad(offsetX: 0.10),
                                    candidates: [candidate(confidence: 0.75)],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(7))
        XCTAssertEqual(rearmed.state, .magneticAttraction(candidateID: candidateID))
    }

    func testResetClearsSuppressionAndState() {
        var engine = MagneticSnapEngine()
        _ = engine.update(selection: quad(offsetX: 0.10),
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        engine.release()
        engine.reset()

        XCTAssertEqual(engine.state, .manual)
        XCTAssertNil(engine.suppressedCandidateID)

        let outcome = engine.update(selection: quad(offsetX: 0.10),
                                    candidates: [candidate(confidence: 0.75)],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(1))
        XCTAssertEqual(outcome.state, .magneticAttraction(candidateID: candidateID))
    }

    // MARK: - Target switching

    func testSwitchingTargetsRequiresAMeaningfulMargin() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: -0.02)
        let incumbent = candidate(confidence: 0.75)

        _ = engine.update(selection: selection,
                          candidates: [incumbent],
                          trackingConfidence: nil,
                          isUserDragging: false,
                          timestamp: time(0))
        XCTAssertEqual(engine.state.candidateID, candidateID)

        // Slightly better challenger: score edge is well under switchMargin.
        let marginal = candidate(id: challengerID, confidence: 0.85, quad: quad(offsetX: 0.03))
        let held = engine.update(selection: selection,
                                 candidates: [incumbent, marginal],
                                 trackingConfidence: nil,
                                 isUserDragging: false,
                                 timestamp: time(1))
        XCTAssertEqual(held.state.candidateID, candidateID, "switched on a marginal challenger")

        // Decisively better challenger: same proximity, far higher confidence.
        let decisive = candidate(id: challengerID, confidence: 0.98, quad: quad(offsetX: -0.04))
        let switched = engine.update(selection: selection,
                                     candidates: [incumbent, decisive],
                                     trackingConfidence: nil,
                                     isUserDragging: false,
                                     timestamp: time(2))
        XCTAssertEqual(switched.state.candidateID, challengerID)
    }

    func testSwitchingTargetsResetsLockProgress() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.05)
        let incumbent = candidate(confidence: 0.90)

        for i in 0..<2 {
            _ = engine.update(selection: selection,
                              candidates: [incumbent],
                              trackingConfidence: nil,
                              isUserDragging: false,
                              timestamp: time(i))
        }
        XCTAssertEqual(engine.lockProgress, 2)

        // Perfectly confident and exactly under the window: enough to clear the
        // switch margin even against a lock-grade incumbent.
        let decisive = candidate(id: challengerID, confidence: 1.0, quad: selection)
        let outcome = engine.update(selection: selection,
                                    candidates: [incumbent, decisive],
                                    trackingConfidence: nil,
                                    isUserDragging: false,
                                    timestamp: time(2))
        XCTAssertEqual(outcome.state.candidateID, challengerID)
        XCTAssertEqual(outcome.lockProgress, 1, "lock progress carried over to a new target")
        XCTAssertFalse(outcome.didLock)
    }

    // MARK: - Attraction dynamics

    func testAttractionIsMonotonicAndNeverOvershoots() {
        var engine = MagneticSnapEngine()
        var selection = quad(offsetX: -0.15)
        var previousDistance = selection.meanCornerDistance(to: target)

        for i in 0..<60 {
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: 0.75)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            selection = outcome.quad
            let distance = selection.meanCornerDistance(to: target)

            XCTAssertLessThan(distance, previousDistance, "not monotonic on frame \(i)")
            XCTAssertGreaterThanOrEqual(distance, 0)
            // Started to the left of the target; overshoot would cross it.
            XCTAssertLessThanOrEqual(selection.topLeft.x, target.topLeft.x + 1e-12,
                                     "overshot on frame \(i)")
            previousDistance = distance
        }
        XCTAssertEqual(previousDistance, 0.15 * pow(0.75, 60), accuracy: 1e-12)
    }

    /// The felt pull must not change with capture rate: 1 s of attraction at
    /// 60 fps has to land where 1 s at 30 fps does.
    func testAttractionIsFrameRateIndependent() {
        func distanceAfterOneSecond(rate: Double) -> CGFloat {
            var engine = MagneticSnapEngine()
            var selection = quad(offsetX: 0.20)
            for i in 0...Int(rate) {
                let outcome = engine.update(selection: selection,
                                            candidates: [candidate(confidence: 0.75)],
                                            trackingConfidence: nil,
                                            isUserDragging: false,
                                            timestamp: time(i, rate: rate))
                selection = outcome.quad
            }
            return selection.meanCornerDistance(to: target)
        }

        XCTAssertEqual(distanceAfterOneSecond(rate: 60),
                       distanceAfterOneSecond(rate: 30), accuracy: 1e-9)
        XCTAssertEqual(distanceAfterOneSecond(rate: 15),
                       distanceAfterOneSecond(rate: 30), accuracy: 1e-9)
    }

    // MARK: - Locked / degraded / reacquisition

    /// Drives a fresh engine to `.locked` and returns it with the frame index
    /// to continue from.
    private func lockedEngine() -> MagneticSnapEngine {
        var engine = MagneticSnapEngine()
        for i in 0..<tuning.framesToLock {
            _ = engine.update(selection: target,
                              candidates: [candidate(confidence: 0.95)],
                              trackingConfidence: nil,
                              isUserDragging: false,
                              timestamp: time(i))
        }
        XCTAssertEqual(engine.state, .locked(targetID: candidateID))
        return engine
    }

    func testDegradedTimesOutToReacquisitionThenBackToManual() {
        var engine = lockedEngine()

        let degraded = engine.update(selection: target, candidates: [],
                                     trackingConfidence: 0.40, isUserDragging: false,
                                     timestamp: 10.0)
        XCTAssertEqual(degraded.state, .trackingDegraded(targetID: candidateID))

        let stillDegraded = engine.update(selection: target, candidates: [],
                                          trackingConfidence: 0.40, isUserDragging: false,
                                          timestamp: 10.5)
        XCTAssertEqual(stillDegraded.state, .trackingDegraded(targetID: candidateID))

        // degradedTimeout is 1.0 s.
        let reacquiring = engine.update(selection: target, candidates: [],
                                        trackingConfidence: 0.40, isUserDragging: false,
                                        timestamp: 11.1)
        XCTAssertEqual(reacquiring.state, .reacquisition(targetID: candidateID))

        let stillReacquiring = engine.update(selection: target, candidates: [],
                                             trackingConfidence: 0.40, isUserDragging: false,
                                             timestamp: 14.0)
        XCTAssertEqual(stillReacquiring.state, .reacquisition(targetID: candidateID))

        // reacquisitionTimeout is 5.0 s from 11.1.
        let gaveUp = engine.update(selection: target, candidates: [],
                                   trackingConfidence: 0.40, isUserDragging: false,
                                   timestamp: 16.2)
        XCTAssertEqual(gaveUp.state, .manual)
        XCTAssertTrue(gaveUp.didRelease)
    }

    func testDegradedRecoversToLockedAfterSustainedHealth() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.40,
                          isUserDragging: false, timestamp: 10.0)
        XCTAssertEqual(engine.state, .trackingDegraded(targetID: candidateID))

        // One good frame is not recovery.
        let first = engine.update(selection: target, candidates: [],
                                  trackingConfidence: 0.80, isUserDragging: false,
                                  timestamp: 10.2)
        XCTAssertEqual(first.state, .trackingDegraded(targetID: candidateID))

        let recovered = engine.update(selection: target, candidates: [],
                                      trackingConfidence: 0.80, isUserDragging: false,
                                      timestamp: 10.4)
        XCTAssertEqual(recovered.state, .locked(targetID: candidateID))

        // Recovery must clear the degradation clock, not merely mask it.
        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.40,
                          isUserDragging: false, timestamp: 11.0)
        let stillDegraded = engine.update(selection: target, candidates: [],
                                          trackingConfidence: 0.40, isUserDragging: false,
                                          timestamp: 11.5)
        XCTAssertEqual(stillDegraded.state, .trackingDegraded(targetID: candidateID))
    }

    /// A tracker flickering healthy for one frame must not restart the
    /// degradation clock, or `degradedTimeout` is never reached.
    func testOneHealthyFrameDoesNotRestartTheDegradationClock() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.40,
                          isUserDragging: false, timestamp: 10.0)
        XCTAssertEqual(engine.state, .trackingDegraded(targetID: candidateID))

        let flicker = engine.update(selection: target, candidates: [],
                                    trackingConfidence: 0.80, isUserDragging: false,
                                    timestamp: 10.5)
        XCTAssertEqual(flicker.state, .trackingDegraded(targetID: candidateID))

        // degradedTimeout is 1.0 s measured from 10.0, not from the flicker.
        let reacquiring = engine.update(selection: target, candidates: [],
                                        trackingConfidence: 0.40, isUserDragging: false,
                                        timestamp: 11.05)
        XCTAssertEqual(reacquiring.state, .reacquisition(targetID: candidateID))
    }

    /// A marginal tracker dithering across `degradedTracking` must neither flap
    /// the state nor stall the timeout.
    func testDitheringTrackingConfidenceDoesNotFlapAndStillTimesOut() {
        var engine = lockedEngine()
        var reachedReacquisition = false

        for i in 0..<40 {
            let confidence: Float = i.isMultiple(of: 2) ? 0.54 : 0.56
            let timestamp = 10.0 + Double(i) * 0.05
            let outcome = engine.update(selection: target, candidates: nil,
                                        trackingConfidence: confidence,
                                        isUserDragging: false, timestamp: timestamp)
            if outcome.state == .reacquisition(targetID: candidateID) {
                reachedReacquisition = true
                XCTAssertGreaterThanOrEqual(timestamp, 11.0)
                break
            }
            XCTAssertEqual(outcome.state, .trackingDegraded(targetID: candidateID),
                           "flapped on frame \(i) at confidence \(confidence)")
        }
        XCTAssertTrue(reachedReacquisition, "degradedTimeout was never reached")
    }

    func testConfidenceBelowLostGoesStraightToReacquisition() {
        var engine = lockedEngine()

        let outcome = engine.update(selection: target, candidates: [],
                                    trackingConfidence: 0.10, isUserDragging: false,
                                    timestamp: 10.0)
        XCTAssertEqual(outcome.state, .reacquisition(targetID: candidateID))
    }

    func testNilTrackingConfidenceCountsAsDegradedNotLost() {
        var engine = lockedEngine()

        let outcome = engine.update(selection: target, candidates: [],
                                    trackingConfidence: nil, isUserDragging: false,
                                    timestamp: 10.0)
        XCTAssertEqual(outcome.state, .trackingDegraded(targetID: candidateID))
    }

    func testReacquisitionRecoversThroughTheDetectorKeepingTheTargetID() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.10,
                          isUserDragging: false, timestamp: 10.0)
        XCTAssertEqual(engine.state, .reacquisition(targetID: candidateID))

        let found = candidate(id: challengerID, confidence: 0.95, quad: quad(offsetX: 0.05))
        for i in 0..<(tuning.framesToLock - 1) {
            let outcome = engine.update(selection: target, candidates: [found],
                                        trackingConfidence: 0.10, isUserDragging: false,
                                        timestamp: 10.1 + Double(i) * 0.1)
            XCTAssertEqual(outcome.state, .reacquisition(targetID: candidateID))
            XCTAssertFalse(outcome.didLock)
        }

        let relocked = engine.update(selection: target, candidates: [found],
                                     trackingConfidence: 0.10, isUserDragging: false,
                                     timestamp: 10.5)
        XCTAssertTrue(relocked.didLock)
        // Same target id: the fields authored against it survive the dropout.
        XCTAssertEqual(relocked.state, .locked(targetID: candidateID))
        XCTAssertEqual(relocked.quad, found.quad)
        // The reported candidate carries the target id too, so a caller keyed
        // on `lockedCandidate.id` addresses the same target it locked first.
        XCTAssertEqual(relocked.lockedCandidate?.id, relocked.state.targetID)
        XCTAssertEqual(relocked.lockedCandidate?.id, candidateID)
        XCTAssertEqual(relocked.lockedCandidate?.quad, found.quad)
        XCTAssertEqual(relocked.lockedCandidate?.confidence, found.confidence)
    }

    /// Reacquisition runs at detector cadence too: frames with no fresh
    /// proposals must not reset the relock counter.
    func testReacquisitionAccumulatesAcrossFramesWhereTheDetectorDidNotRun() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: nil, trackingConfidence: 0.10,
                          isUserDragging: false, timestamp: 10.0)
        XCTAssertEqual(engine.state, .reacquisition(targetID: candidateID))

        let found = candidate(id: challengerID, confidence: 0.95, quad: quad(offsetX: 0.05))
        var outcomes: [SnapOutcome] = []
        for i in 0..<tuning.framesToLock {
            outcomes.append(engine.update(selection: target,
                                          candidates: i == 0 ? [found] : nil,
                                          trackingConfidence: 0.10,
                                          isUserDragging: false,
                                          timestamp: 10.1 + Double(i) * 0.1))
        }

        XCTAssertEqual(outcomes.map(\.didLock), [false, false, true])
        XCTAssertEqual(engine.state, .locked(targetID: candidateID))
        XCTAssertEqual(outcomes.last?.quad, found.quad)
    }

    // MARK: - Detector cadence

    /// The architectural case: detection is expensive and runs on a fraction of
    /// frames, so `framesToLock` consecutive qualifying frames have to be
    /// reachable when most frames carry no detector output at all.
    func testLockIsReachableWhenTheDetectorRunsOnlyEveryFifthFrame() {
        var engine = MagneticSnapEngine()
        var selection = quad(offsetX: 0.16)
        var lockFrame: Int?

        for i in 0..<40 {
            let detectorRan = i.isMultiple(of: 5)
            let outcome = engine.update(selection: selection,
                                        candidates: detectorRan
                                            ? [candidate(confidence: 0.95)]
                                            : nil,
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: time(i))
            selection = outcome.quad
            if outcome.didLock {
                lockFrame = i
                XCTAssertEqual(outcome.state, .locked(targetID: candidateID))
                XCTAssertEqual(outcome.lockedCandidate?.id, candidateID)
                XCTAssertFalse(detectorRan,
                               "the lock landed on a detection frame; the gap is untested")
                break
            }
            XCTAssertNotEqual(outcome.state, .manual,
                              "engagement collapsed on frame \(i) (detector ran: \(detectorRan))")
            XCTAssertEqual(outcome.engagedCandidate?.id, candidateID)
        }

        XCTAssertNotNil(lockFrame, "no lock is reachable at a 1-in-5 detector cadence")
    }

    /// Between detections the magnet keeps pulling against the last reported
    /// geometry — the trajectory must match a frame-by-frame detector exactly.
    func testAttractionContinuesWhileTheDetectorIsSilent() {
        func distanceAfter(frames: Int, detectorEvery cadence: Int) -> CGFloat {
            var engine = MagneticSnapEngine()
            var selection = quad(offsetX: 0.15)
            for i in 0..<frames {
                let outcome = engine.update(selection: selection,
                                            candidates: i.isMultiple(of: cadence)
                                                ? [candidate(confidence: 0.75)]
                                                : nil,
                                            trackingConfidence: nil,
                                            isUserDragging: false,
                                            timestamp: time(i))
                selection = outcome.quad
            }
            return selection.meanCornerDistance(to: target)
        }

        XCTAssertEqual(distanceAfter(frames: 12, detectorEvery: 4),
                       distanceAfter(frames: 12, detectorEvery: 1), accuracy: 1e-12)
    }

    /// `[]` is "the detector ran and found nothing" — one such frame is not a
    /// vanished display, but a sustained absence is.
    func testEngagementSurvivesABriefDropoutButNotALongOne() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0)
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        let survived = engine.update(selection: selection, candidates: [],
                                     trackingConfidence: nil, isUserDragging: false,
                                     timestamp: 0.1)
        XCTAssertEqual(survived.state, .magneticAttraction(candidateID: candidateID))
        XCTAssertFalse(survived.didRelease)

        // Past candidateGraceInterval (0.4 s) the candidate is genuinely gone.
        let dropped = engine.update(selection: selection, candidates: [],
                                    trackingConfidence: nil, isUserDragging: false,
                                    timestamp: 0.6)
        XCTAssertEqual(dropped.state, .manual)
        XCTAssertTrue(dropped.didRelease)
        XCTAssertNil(dropped.engagedCandidate)
        XCTAssertNil(dropped.alignmentDistance)
    }

    /// `nil` is "the detector did not run", which is evidence of nothing, so
    /// carry-forward is unconditional however long the run lasts. The wired
    /// pipeline detects every 2 s while locked — five times
    /// `candidateGraceInterval` — so anything that ages `nil` frames drops the
    /// engagement between detections as a matter of course.
    func testEngagementSurvivesAnyNumberOfFramesWhereTheDetectorDidNotRun() {
        var engine = MagneticSnapEngine()
        // Fixed selection inside attractionRadius (0.18) and outside
        // alignmentRadius (0.06): engaged, never locking, so 100 frames of
        // engagement are observable.
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0)
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        // 100 frames spanning 10 s — 25× the grace interval.
        for i in 1...100 {
            let timestamp = Double(i) * 0.1
            let outcome = engine.update(selection: selection, candidates: nil,
                                        trackingConfidence: nil, isUserDragging: false,
                                        timestamp: timestamp)
            XCTAssertEqual(outcome.state, .magneticAttraction(candidateID: candidateID),
                           "engagement aged out on frame \(i) (t = \(timestamp)) with no detector evidence")
            XCTAssertEqual(outcome.engagedCandidate?.id, candidateID)
            XCTAssertFalse(outcome.didRelease)
        }
    }

    /// The contrast that makes the previous test mean something: the identical
    /// frame sequence with `[]` instead of `nil` — the detector running and
    /// finding nothing — must age the engagement out over the grace interval.
    func testEngagementAgesOutWhenTheDetectorRunsAndKeepsFindingNothing() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0)
        XCTAssertEqual(engine.state, .magneticAttraction(candidateID: candidateID))

        var releasedAt: TimeInterval?
        for i in 1...100 where releasedAt == nil {
            let timestamp = Double(i) * 0.1
            let outcome = engine.update(selection: selection, candidates: [],
                                        trackingConfidence: nil, isUserDragging: false,
                                        timestamp: timestamp)
            if outcome.state == .manual { releasedAt = timestamp }
        }

        XCTAssertNotNil(releasedAt, "an emptily-detecting stream must eventually let go")
        XCTAssertGreaterThan(releasedAt ?? 0, engine.candidateGraceInterval,
                             "one missed detection is not a vanished display")
        XCTAssertLessThanOrEqual(releasedAt ?? .infinity, engine.candidateGraceInterval + 0.2,
                                 "the engagement outlived the grace interval by more than one detection")
    }

    /// A dropped detection must not undo a deliberate user rejection.
    func testSuppressionSurvivesADetectorDropout() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        _ = engine.update(selection: selection,
                          candidates: [candidate(confidence: 0.75)],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0)
        engine.release()
        XCTAssertEqual(engine.suppressedCandidateID, candidateID)

        _ = engine.update(selection: selection, candidates: [],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0.1)
        XCTAssertEqual(engine.suppressedCandidateID, candidateID,
                       "a missed detection cleared the user's rejection")

        _ = engine.update(selection: selection, candidates: nil,
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0.2)
        XCTAssertEqual(engine.suppressedCandidateID, candidateID)

        let stillSuppressed = engine.update(selection: selection,
                                            candidates: [candidate(confidence: 0.75)],
                                            trackingConfidence: nil, isUserDragging: false,
                                            timestamp: 0.3)
        XCTAssertEqual(stillSuppressed.state, .manual, "re-attracted a rejected candidate")

        // Absent for longer than the grace window does count as out of range:
        // coming back within reach with the finger up re-arms it.
        _ = engine.update(selection: selection, candidates: [],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 1.0)
        let rearmed = engine.update(selection: selection,
                                    candidates: [candidate(confidence: 0.75)],
                                    trackingConfidence: nil, isUserDragging: false,
                                    timestamp: 1.1)
        XCTAssertEqual(rearmed.state, .magneticAttraction(candidateID: candidateID))
        XCTAssertNil(engine.suppressedCandidateID)
    }

    /// The anti-switching margin has to apply on frames where the detector
    /// happens to report only the challenger.
    func testChallengerCannotStealTheWindowDuringAnIncumbentDropout() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: -0.02)
        let incumbent = candidate(confidence: 0.75)
        let challenger = candidate(id: challengerID, confidence: 0.85, quad: quad(offsetX: 0.03))

        _ = engine.update(selection: selection, candidates: [incumbent],
                          trackingConfidence: nil, isUserDragging: false, timestamp: 0)
        XCTAssertEqual(engine.state.candidateID, candidateID)

        let held = engine.update(selection: selection, candidates: [challenger],
                                 trackingConfidence: nil, isUserDragging: false,
                                 timestamp: 0.1)
        XCTAssertEqual(held.state.candidateID, candidateID,
                       "challenger took the window with no margin on one dropped frame")

        let stillHeld = engine.update(selection: selection, candidates: nil,
                                      trackingConfidence: nil, isUserDragging: false,
                                      timestamp: 0.2)
        XCTAssertEqual(stillHeld.state.candidateID, candidateID)

        // Once the incumbent is genuinely gone the challenger may take over.
        let switched = engine.update(selection: selection, candidates: [challenger],
                                     trackingConfidence: nil, isUserDragging: false,
                                     timestamp: 0.7)
        XCTAssertEqual(switched.state.candidateID, challengerID)
    }

    func testCandidatesAreIgnoredWhileHealthilyLocked() {
        var engine = lockedEngine()
        let other = candidate(id: challengerID, confidence: 0.99, quad: quad(offsetX: 0.02))

        let outcome = engine.update(selection: target, candidates: [other],
                                    trackingConfidence: 0.95, isUserDragging: false,
                                    timestamp: 10.0)
        XCTAssertEqual(outcome.state, .locked(targetID: candidateID))
        XCTAssertEqual(outcome.quad, target)
        XCTAssertFalse(outcome.didLock)
    }

    /// A relock re-stamps the detector's fresh proposal with the *existing*
    /// target id, so the id the engine reports and the id the detector keeps
    /// proposing are different. Suppression has to follow the detector's id, or
    /// `release()` bars an id nothing ever offers and the magnet re-grabs the
    /// display the user just rejected on the next frame.
    func testReleaseAfterADetectorDrivenRelockSuppressesWhatTheDetectorProposes() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.10,
                          isUserDragging: false, timestamp: 10.0)
        XCTAssertEqual(engine.state, .reacquisition(targetID: candidateID))

        let found = candidate(id: challengerID, confidence: 0.95, quad: quad(offsetX: 0.05))
        for i in 0..<tuning.framesToLock {
            _ = engine.update(selection: target, candidates: [found],
                              trackingConfidence: 0.10, isUserDragging: false,
                              timestamp: 10.1 + Double(i) * 0.1)
        }
        XCTAssertEqual(engine.state, .locked(targetID: candidateID),
                       "the relock keeps the original target id — that is the setup, not the defect")

        engine.release()
        XCTAssertEqual(engine.state, .manual)
        XCTAssertEqual(engine.suppressedCandidateID, challengerID,
                       "suppressed an id the detector will never propose")

        // The detector goes on proposing the same display, lock-grade and right
        // under the window. Without the user's rejection this locks in three
        // frames; with it, nothing may happen at all.
        for i in 0..<8 {
            let outcome = engine.update(selection: target, candidates: [found],
                                        trackingConfidence: nil, isUserDragging: false,
                                        timestamp: 11.0 + Double(i) * 0.1)
            XCTAssertEqual(outcome.state, .manual,
                           "re-grabbed the rejected display on frame \(i)")
            XCTAssertFalse(outcome.didLock)
        }
    }

    func testReleaseFromLockReturnsToManual() {
        var engine = lockedEngine()
        engine.release()
        XCTAssertEqual(engine.state, .manual)
        XCTAssertEqual(engine.suppressedCandidateID, candidateID)
    }

    // MARK: - Degenerate inputs

    /// Frame sources do not share a clock — a camera's host time reads in the
    /// tens of thousands of seconds, a synthetic source starts at zero — so a
    /// backwards jump must restart the interval instead of wedging it.
    func testTimestampRegressionRestartsTheDegradedTimeout() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: nil, trackingConfidence: 0.40,
                          isUserDragging: false, timestamp: 51_234.7)
        XCTAssertEqual(engine.state, .trackingDegraded(targetID: candidateID))

        let afterJump = engine.update(selection: target, candidates: nil,
                                      trackingConfidence: 0.40, isUserDragging: false,
                                      timestamp: 0.0)
        XCTAssertEqual(afterJump.state, .trackingDegraded(targetID: candidateID))

        let timedOut = engine.update(selection: target, candidates: nil,
                                     trackingConfidence: 0.40, isUserDragging: false,
                                     timestamp: 1.05)
        XCTAssertEqual(timedOut.state, .reacquisition(targetID: candidateID),
                       "the degraded timeout never fired after a clock regression")
    }

    func testTimestampRegressionRestartsTheReacquisitionTimeout() {
        var engine = lockedEngine()

        _ = engine.update(selection: target, candidates: [], trackingConfidence: 0.10,
                          isUserDragging: false, timestamp: 51_234.7)
        XCTAssertEqual(engine.state, .reacquisition(targetID: candidateID))

        let afterJump = engine.update(selection: target, candidates: [],
                                      trackingConfidence: 0.10, isUserDragging: false,
                                      timestamp: 0.0)
        XCTAssertEqual(afterJump.state, .reacquisition(targetID: candidateID))

        let stillTrying = engine.update(selection: target, candidates: [],
                                        trackingConfidence: 0.10, isUserDragging: false,
                                        timestamp: 4.0)
        XCTAssertEqual(stillTrying.state, .reacquisition(targetID: candidateID))

        let gaveUp = engine.update(selection: target, candidates: [],
                                   trackingConfidence: 0.10, isUserDragging: false,
                                   timestamp: 5.05)
        XCTAssertEqual(gaveUp.state, .manual,
                       "the reacquisition timeout never fired after a clock regression")
    }

    /// `alignmentDistance` describes the candidate the outcome is about, so it
    /// must be nil exactly when there is no such candidate.
    func testAlignmentDistanceIsNilWheneverNoCandidateIsInPlay() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.10)

        // Above exitDetection (0.50) so it survives scoring, below
        // enterDetection (0.60) so it earns no rung at all.
        let weak = engine.update(selection: selection,
                                 candidates: [candidate(confidence: 0.55)],
                                 trackingConfidence: nil, isUserDragging: false,
                                 timestamp: time(0))
        XCTAssertEqual(weak.state, .manual)
        XCTAssertNil(weak.engagedCandidate)
        XCTAssertNil(weak.alignmentDistance)

        let engaged = engine.update(selection: selection,
                                    candidates: [candidate(confidence: 0.75)],
                                    trackingConfidence: nil, isUserDragging: false,
                                    timestamp: time(1))
        XCTAssertNotNil(engaged.engagedCandidate)
        XCTAssertEqual(engaged.alignmentDistance ?? -1, 0.10, accuracy: 1e-9)
    }

    func testNoCandidatesStaysManualAndLeavesTheWindowAlone() {
        var engine = MagneticSnapEngine()
        let selection = quad(offsetX: 0.1)

        for i in 0..<5 {
            let outcome = engine.update(selection: selection, candidates: [],
                                        trackingConfidence: nil, isUserDragging: false,
                                        timestamp: time(i))
            XCTAssertEqual(outcome.state, .manual)
            XCTAssertEqual(outcome.quad, selection)
            XCTAssertFalse(outcome.didRelease)
        }
    }

    func testRepeatedTimestampsDoNotStallOrTeleport() {
        var engine = MagneticSnapEngine()
        var selection = quad(offsetX: 0.10)

        for _ in 0..<3 {
            let outcome = engine.update(selection: selection,
                                        candidates: [candidate(confidence: 0.75)],
                                        trackingConfidence: nil,
                                        isUserDragging: false,
                                        timestamp: 5.0)
            selection = outcome.quad
        }
        // A non-advancing clock falls back to the nominal interval rather than
        // producing a zero or infinite step.
        XCTAssertEqual(selection.meanCornerDistance(to: target),
                       0.10 * pow(0.75, 3), accuracy: 1e-9)
    }
}
