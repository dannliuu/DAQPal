//
//  TrackVerifierTests.swift
//  DAQPalTests
//
//  Unit coverage for `TrackVerifier` — the independent geometric verification
//  of a tracked lock (remediation plan Phases 7–8). Pure logic: candidates and
//  quads are built directly, timestamps are synthetic, no Vision, no Date(),
//  no randomness.
//
//  The contract under test, stated plainly:
//    * A confident candidate overlapping the tracked quad (by IoU, or by
//      center distance for a tighter crop of the same display) CORROBORATES.
//    * A confident candidate elsewhere with nothing near the tracked quad is
//      the drift signature: DIVERGED, a hard veto, sticky until a later
//      corroborated pass clears it.
//    * Nothing confident anywhere is UNSUPPORTED — a strike, not a veto;
//      `strikesToUnverified` consecutive strikes unverify.
//    * A candidate below `testimonyConfidence` can neither veto nor
//      corroborate.
//

import CoreGraphics
import XCTest
@testable import DAQPal

final class TrackVerifierTests: XCTestCase {

    // MARK: - Fixtures

    private func quad(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> ScreenQuad {
        ScreenQuad(roi: NormalizedROI(x: x, y: y, width: w, height: h))
    }

    private func candidate(_ quad: ScreenQuad, confidence: Float) -> ScreenCandidate {
        ScreenCandidate(quad: quad, signals: .zero, confidence: confidence)
    }

    /// The tracked display used throughout: a landscape panel on the left.
    private var tracked: ScreenQuad { quad(0.10, 0.40, 0.35, 0.15) }
    /// A display far from `tracked` — no bounding-box overlap, center distance
    /// far beyond the corroboration radius.
    private var farAway: ScreenQuad { quad(0.60, 0.05, 0.35, 0.15) }

    // MARK: - Corroboration

    func testConfidentOverlappingCandidateCorroborates() {
        var verifier = TrackVerifier()
        let verdict = verifier.evaluate(tracked: tracked,
                                        candidates: [candidate(tracked, confidence: 0.9)],
                                        timestamp: 1.0)
        XCTAssertEqual(verdict, .corroborated)
        XCTAssertFalse(verifier.isUnverified)
        XCTAssertEqual(verifier.lastCorroboratedAt, 1.0)
    }

    /// The detector legitimately proposes a *tighter crop* of the same display
    /// (bezel excluded, say). IoU collapses below the corroboration threshold,
    /// but the centers coincide — this must corroborate, never veto.
    func testTighterCropOfSameDisplayCorroboratesByCenterDistance() {
        var verifier = TrackVerifier()
        // A concentric crop well under half the tracked area, so its IoU is
        // unambiguously below the 0.30 gate while its center coincides exactly.
        let crop = quad(0.2275, 0.4525, 0.10, 0.05) // same center (0.2775, 0.4775)
        let iou = crop.boundingBoxIoU(with: tracked)
        XCTAssertLessThan(iou, verifier.corroborationIoU,
                          "precondition: the crop must fail the IoU gate, or this "
                          + "test is not exercising the center-distance path")

        let verdict = verifier.evaluate(tracked: tracked,
                                        candidates: [candidate(crop, confidence: 0.85)],
                                        timestamp: 2.0)
        XCTAssertEqual(verdict, .corroborated,
                       "a tighter crop of the same display was treated as divergence")
        XCTAssertFalse(verifier.isUnverified)
    }

    // MARK: - Divergence

    func testConfidentCandidateElsewhereWithNothingNearbyDiverges() {
        var verifier = TrackVerifier()
        let verdict = verifier.evaluate(tracked: tracked,
                                        candidates: [candidate(farAway, confidence: 0.94)],
                                        timestamp: 1.0)
        // The associated value is `CGFloat(confidence)`; converting the same
        // Float keeps the comparison exact.
        XCTAssertEqual(verdict, .diverged(strongestElsewhere: CGFloat(Float(0.94))))
        XCTAssertTrue(verifier.isUnverified, "a diverged lock must read as unverified")
    }

    /// Divergence is sticky: neither empty passes nor time clears it — only a
    /// later corroborated pass does.
    func testDivergenceIsStickyUntilACorroboratedPassClearsIt() {
        var verifier = TrackVerifier()
        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(farAway, confidence: 0.94)],
                              timestamp: 1.0)
        XCTAssertTrue(verifier.isUnverified)

        // Empty passes accumulate strikes but must not clear the divergence.
        for i in 0..<2 {
            let verdict = verifier.evaluate(tracked: tracked, candidates: [],
                                            timestamp: 1.5 + Double(i) * 0.5)
            XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: i + 1))
            XCTAssertTrue(verifier.isUnverified,
                          "divergence cleared by an empty pass — it must be sticky")
        }

        // A weak candidate near the tracked quad must not clear it either.
        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(tracked, confidence: 0.3)],
                              timestamp: 3.0)
        XCTAssertTrue(verifier.isUnverified,
                      "divergence cleared by sub-testimony evidence")

        // Corroboration clears it.
        let verdict = verifier.evaluate(tracked: tracked,
                                        candidates: [candidate(tracked, confidence: 0.9)],
                                        timestamp: 3.5)
        XCTAssertEqual(verdict, .corroborated)
        XCTAssertFalse(verifier.isUnverified)
    }

    // MARK: - Unsupported strikes

    func testASingleUnsupportedPassDoesNotUnverify() {
        var verifier = TrackVerifier()
        let verdict = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 1.0)
        XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: 1))
        XCTAssertFalse(verifier.isUnverified,
                       "one missed detection is noise, not an unverified lock")
    }

    func testThreeConsecutiveEmptyPassesUnverify() {
        var verifier = TrackVerifier()
        for i in 1...3 {
            let verdict = verifier.evaluate(tracked: tracked, candidates: [],
                                            timestamp: Double(i))
            XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: i))
            if i < verifier.strikesToUnverified {
                XCTAssertFalse(verifier.isUnverified, "unverified after only \(i) strikes")
            }
        }
        XCTAssertTrue(verifier.isUnverified)
    }

    func testCorroborationResetsTheStrikeCount() {
        var verifier = TrackVerifier()
        _ = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 1.0)
        _ = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 2.0)
        XCTAssertEqual(verifier.consecutiveUnsupported, 2)

        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(tracked, confidence: 0.9)],
                              timestamp: 3.0)
        XCTAssertEqual(verifier.consecutiveUnsupported, 0)

        // Two more strikes after the reset must not unverify: 2 + 2 never
        // reaches 3 *consecutive*.
        _ = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 4.0)
        let verdict = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 5.0)
        XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: 2))
        XCTAssertFalse(verifier.isUnverified)
    }

    // MARK: - Weak testimony (below `testimonyConfidence`)

    /// A weak far-away candidate cannot veto: the pass counts as unsupported,
    /// never as diverged.
    func testWeakCandidateElsewhereCannotVeto() {
        var verifier = TrackVerifier()
        let weak = candidate(farAway, confidence: verifier.testimonyConfidence - 0.05)
        let verdict = verifier.evaluate(tracked: tracked, candidates: [weak], timestamp: 1.0)
        XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: 1),
                       "a sub-testimony candidate vetoed the lock")
        XCTAssertFalse(verifier.isUnverified)
    }

    /// A weak nearby candidate cannot corroborate: strikes keep accumulating
    /// exactly as if the pass were empty.
    func testWeakCandidateNearbyCannotCorroborate() {
        var verifier = TrackVerifier()
        let weak = candidate(tracked, confidence: verifier.testimonyConfidence - 0.05)
        for i in 1...verifier.strikesToUnverified {
            let verdict = verifier.evaluate(tracked: tracked, candidates: [weak],
                                            timestamp: Double(i))
            XCTAssertEqual(verdict, .unsupported(consecutiveStrikes: i),
                           "a sub-testimony candidate corroborated the lock")
        }
        XCTAssertTrue(verifier.isUnverified)
    }

    /// The threshold is inclusive: a candidate exactly at `testimonyConfidence`
    /// testifies in both directions.
    func testTestimonyThresholdIsInclusive() {
        var corroborating = TrackVerifier()
        let atThresholdNear = candidate(tracked, confidence: corroborating.testimonyConfidence)
        XCTAssertEqual(corroborating.evaluate(tracked: tracked,
                                              candidates: [atThresholdNear],
                                              timestamp: 1.0),
                       .corroborated)

        var vetoing = TrackVerifier()
        let atThresholdFar = candidate(farAway, confidence: vetoing.testimonyConfidence)
        XCTAssertEqual(vetoing.evaluate(tracked: tracked,
                                        candidates: [atThresholdFar],
                                        timestamp: 1.0),
                       .diverged(strongestElsewhere: CGFloat(vetoing.testimonyConfidence)))
    }

    // MARK: - Multi-display false-veto guard (the critical case)

    /// Two real displays in frame. The tracked one is corroborated by a nearby
    /// confident candidate; a second display elsewhere scores even higher. The
    /// presence of a STRONGER candidate elsewhere must not veto a lock that is
    /// itself corroborated — corroboration is checked first, absolutely.
    func testStrongerCandidateElsewhereDoesNotVetoACorroboratedLock() {
        let displayA = candidate(tracked, confidence: 0.72)   // the locked display
        let displayB = candidate(farAway, confidence: 0.96)   // a brighter rival

        // Order must not matter: the rival first, the corroborator second, and
        // vice versa.
        for candidates in [[displayB, displayA], [displayA, displayB]] {
            var verifier = TrackVerifier()
            let verdict = verifier.evaluate(tracked: tracked, candidates: candidates,
                                            timestamp: 1.0)
            XCTAssertEqual(verdict, .corroborated,
                           "a corroborated lock was vetoed because a second display "
                           + "scored higher elsewhere — the multi-display false veto")
            XCTAssertFalse(verifier.isUnverified)
        }
    }

    // MARK: - Lifecycle

    func testBeginLockResetsDivergenceAndStrikes() {
        var verifier = TrackVerifier()
        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(farAway, confidence: 0.94)],
                              timestamp: 1.0)
        _ = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 2.0)
        _ = verifier.evaluate(tracked: tracked, candidates: [], timestamp: 3.0)
        XCTAssertTrue(verifier.isUnverified)

        verifier.beginLock(at: 4.0)

        XCTAssertFalse(verifier.isUnverified,
                       "a fresh lock starts verified — it was just created from a "
                       + "detector candidate")
        XCTAssertEqual(verifier.consecutiveUnsupported, 0)
        XCTAssertEqual(verifier.lastCorroboratedAt, 4.0)
    }

    func testResetClearsEverything() {
        var verifier = TrackVerifier()
        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(tracked, confidence: 0.9)],
                              timestamp: 1.0)
        _ = verifier.evaluate(tracked: tracked,
                              candidates: [candidate(farAway, confidence: 0.94)],
                              timestamp: 2.0)
        XCTAssertTrue(verifier.isUnverified)

        verifier.reset()

        XCTAssertFalse(verifier.isUnverified)
        XCTAssertEqual(verifier.consecutiveUnsupported, 0)
        XCTAssertNil(verifier.lastCorroboratedAt)
        XCTAssertEqual(verifier, TrackVerifier(), "reset must return to the initial state")
    }

    // MARK: - Determinism

    /// The same evaluation sequence run twice from a fresh verifier must yield
    /// identical verdicts and identical final state.
    func testSameSequenceTwiceYieldsSameVerdicts() {
        let sequence: [(candidates: [ScreenCandidate], t: TimeInterval)] = [
            ([candidate(tracked, confidence: 0.9)], 0.5),
            ([], 1.0),
            ([candidate(farAway, confidence: 0.94)], 1.5),
            ([candidate(farAway, confidence: 0.5)], 2.0),
            ([], 2.5),
            ([candidate(tracked, confidence: 0.72), candidate(farAway, confidence: 0.96)], 3.0),
            ([], 3.5),
            ([], 4.0),
            ([], 4.5),
            ([candidate(tracked, confidence: 0.65)], 5.0)
        ]

        func run() -> (verdicts: [TrackVerifier.Verdict], final: TrackVerifier) {
            var verifier = TrackVerifier()
            var verdicts: [TrackVerifier.Verdict] = []
            for step in sequence {
                verdicts.append(verifier.evaluate(tracked: tracked,
                                                  candidates: step.candidates,
                                                  timestamp: step.t))
            }
            return (verdicts, verifier)
        }

        let first = run()
        let second = run()
        XCTAssertEqual(first.verdicts, second.verdicts)
        XCTAssertEqual(first.final, second.final)

        // And the sequence itself exercised all three verdict kinds — a guard
        // against this test silently degenerating.
        XCTAssertTrue(first.verdicts.contains(.corroborated))
        XCTAssertTrue(first.verdicts.contains { if case .diverged = $0 { return true }; return false })
        XCTAssertTrue(first.verdicts.contains { if case .unsupported = $0 { return true }; return false })
    }
    // MARK: - Motion coupling (the live-failure fix)

    /// Same candidate id, overlapping on consecutive passes. Stable id +
    /// stable center is required so coupling can be evaluated.
    private func persistentCandidate(id: UUID, _ q: ScreenQuad,
                                     confidence: Float = 0.9,
                                     stability: Float = 0) -> ScreenCandidate {
        var signals = ScreenSignals.zero
        signals.temporalStability = stability
        return ScreenCandidate(id: id, quad: q, signals: signals, confidence: confidence)
    }

    /// The exact live failure: a quad drifted onto the bounce path is
    /// overlapped every ~1.5 s by the panel itself sweeping through. The first
    /// verifier version counted that sweep as corroboration and kept a dead
    /// lock alive indefinitely (six consecutive evidence frames, ARCHITECTURE
    /// §11). Overlap while moving INDEPENDENTLY of the lock must be a hard
    /// veto, not a blessing.
    func testTransit_displaySweepingThroughParkedLock_isHardVeto() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.40, 0.40, 0.15)   // drifted lock, static
        let id = UUID()

        // Pass 1: panel overlaps the parked quad while passing through.
        let pass1 = verifier.evaluate(tracked: parked,
                                      candidates: [persistentCandidate(id: id, quad(0.28, 0.38, 0.40, 0.15))],
                                      timestamp: 0.0)
        XCTAssertEqual(pass1, .corroborated,
                       "First overlap carries no motion history; corroboration is the only honest verdict.")

        // Pass 2: same candidate, still overlapping, but its center moved
        // 0.05 while the tracked quad did not move at all.
        let pass2 = verifier.evaluate(tracked: parked,
                                      candidates: [persistentCandidate(id: id, quad(0.33, 0.38, 0.40, 0.15))],
                                      timestamp: 0.5)
        guard case .transit(let relative) = pass2 else {
            return XCTFail("A display moving independently through a parked lock must be transit, got \(pass2)")
        }
        XCTAssertGreaterThan(relative, 0.07, "transit reports a RATE (units/sec)")
        XCTAssertTrue(verifier.isUnverified, "Transit is a hard veto.")
    }

    func testCoupledMotion_lockRidingItsDisplay_staysCorroborated() {
        var verifier = TrackVerifier()
        let id = UUID()
        // Both the tracked quad and the candidate translate together by 0.05
        // per pass — an attached lock following a moving display.
        for step in 0..<4 {
            let dx = CGFloat(step) * 0.05
            let tracked = quad(0.30 + dx, 0.40, 0.40, 0.15)
            let seen = persistentCandidate(id: id, quad(0.29 + dx, 0.39, 0.40, 0.15))
            let verdict = verifier.evaluate(tracked: tracked, candidates: [seen],
                                            timestamp: Double(step) * 0.5)
            XCTAssertEqual(verdict, .corroborated,
                           "Coupled motion at step \(step) must corroborate — vetoing an attached lock on a moving display would be a worse bug than the drift itself.")
        }
        XCTAssertFalse(verifier.isUnverified)
    }

    func testTransit_isStickyUntilCoupledCorroboration() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.40, 0.40, 0.15)
        let id = UUID()
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: id, quad(0.28, 0.38, 0.40, 0.15))],
                              timestamp: 0.0)
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: id, quad(0.33, 0.38, 0.40, 0.15))],
                              timestamp: 0.5)
        XCTAssertTrue(verifier.isUnverified)

        // A later pass where the same candidate has SETTLED onto the quad
        // (no relative motion) is genuine attachment again.
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: id, quad(0.33, 0.38, 0.40, 0.15))],
                              timestamp: 1.0)
        let final = verifier.evaluate(tracked: parked,
                                      candidates: [persistentCandidate(id: id, quad(0.33, 0.38, 0.40, 0.15))],
                                      timestamp: 1.5)
        XCTAssertEqual(final, .corroborated)
        XCTAssertFalse(verifier.isUnverified,
                       "A settled, coupled corroboration must clear the transit veto.")
    }

    /// Coupling is id-INDEPENDENT by design: live evidence showed fast motion
    /// destroys detector id stability (a fresh id nearly every pass), which
    /// let every sweep-through corroborate as a "first sighting" and the
    /// transit veto never engaged. Any witness overlapping the quad claims to
    /// be our display, so its motion owes consistency with ours regardless of
    /// the id the detector minted this pass.
    func testIDChurn_smallRelativeMotion_staysCorroborated() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.40, 0.40, 0.15)
        // Different ids, but the witness barely moved relative to the quad —
        // detector jitter on an attached lock. Must not veto.
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: UUID(), quad(0.29, 0.39, 0.40, 0.15))],
                              timestamp: 0.0)
        let verdict = verifier.evaluate(tracked: parked,
                                        candidates: [persistentCandidate(id: UUID(), quad(0.31, 0.41, 0.40, 0.15))],
                                        timestamp: 0.5)
        XCTAssertEqual(verdict, .corroborated)
        XCTAssertFalse(verifier.isUnverified)
    }

    /// The id-churn ESCAPE observed live: the bouncing panel sweeps through a
    /// parked lock with a NEW id on each pass. The first implementation keyed
    /// coupling on id equality, so every sweep corroborated and the dead lock
    /// lived indefinitely. Transit must fire on relative motion alone.
    func testIDChurn_sweepThroughStillTriggersTransit() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.40, 0.40, 0.15)
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: UUID(), quad(0.26, 0.38, 0.40, 0.15))],
                              timestamp: 0.0)
        // New id, same physical panel, 0.06 further along its path while the
        // tracked quad has not moved.
        let verdict = verifier.evaluate(tracked: parked,
                                        candidates: [persistentCandidate(id: UUID(), quad(0.32, 0.38, 0.40, 0.15))],
                                        timestamp: 0.5)
        guard case .transit = verdict else {
            return XCTFail("A sweeping panel with a churned id must still register as transit — id churn was the live escape. Got \(verdict)")
        }
        XCTAssertTrue(verifier.isUnverified)
    }

    /// Stale memory must not poison coupling: a witness from long ago cannot
    /// testify about motion now (legitimate slow travel would read as a jump).
    func testCouplingMemory_expiresAfterMaxAge() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.40, 0.40, 0.15)
        _ = verifier.evaluate(tracked: parked,
                              candidates: [persistentCandidate(id: UUID(), quad(0.26, 0.38, 0.40, 0.15))],
                              timestamp: 0.0)
        // 5 s later — far beyond couplingMemoryMaxAge. Large displacement, but
        // the memory is stale, so this is a fresh sighting, not transit.
        let verdict = verifier.evaluate(tracked: parked,
                                        candidates: [persistentCandidate(id: UUID(), quad(0.33, 0.41, 0.40, 0.15))],
                                        timestamp: 5.0)
        XCTAssertEqual(verdict, .corroborated)
    }

    // MARK: - Persistence testimony (the 40–42% blur gap)

    /// Measured live: a display under fast motion re-proposes at 40–42%
    /// confidence — below the 0.60 testimony bar — so DIVERGED could never
    /// fire while the lock sat on background. Persistence (temporal stability)
    /// lets a real-but-blurred display testify.
    func testPersistentBlurredCandidateElsewhere_canTestifyDivergence() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.70, 0.40, 0.15)
        let blurred = persistentCandidate(id: UUID(), quad(0.30, 0.10, 0.40, 0.15),
                                          confidence: 0.42, stability: 0.8)
        let verdict = verifier.evaluate(tracked: parked, candidates: [blurred], timestamp: 0.0)
        guard case .diverged = verdict else {
            return XCTFail("A persistent 42% candidate elsewhere is the measured signature of the real display under motion; it must be able to veto. Got \(verdict)")
        }
        XCTAssertTrue(verifier.isUnverified)
    }

    func testUnstableWeakCandidate_stillCannotTestify() {
        var verifier = TrackVerifier()
        let parked = quad(0.30, 0.70, 0.40, 0.15)
        let phantom = persistentCandidate(id: UUID(), quad(0.30, 0.10, 0.40, 0.15),
                                          confidence: 0.42, stability: 0.1)
        let verdict = verifier.evaluate(tracked: parked, candidates: [phantom], timestamp: 0.0)
        guard case .unsupported = verdict else {
            return XCTFail("A one-frame 42% phantom must not veto a lock. Got \(verdict)")
        }
    }

    // MARK: - Veto-escape and false-veto fixes (adversarial findings)

    /// The corroboration radius scaled by the LONGER side was a veto escape.
    /// An instrument panel is wide and short — the synthetic rig is
    /// 0.76 x 0.13 normalized — so `0.75 x max(...)` allowed a "corroborating"
    /// center 0.57 units away, more than half the frame. A quad completely off
    /// the display would still be blessed by it.
    func testCorroborationRadius_scalesWithShorterSide_notLonger() {
        var verifier = TrackVerifier()
        // Panel-shaped tracked quad: wide and short, like a real readout.
        let tracked = quad(0.12, 0.44, 0.76, 0.13)
        // A candidate displaced 0.30 vertically — nowhere near the same
        // display, and with zero bounding-box overlap.
        let farAway = candidate(quad(0.12, 0.80, 0.76, 0.13), confidence: 0.9)
        XCTAssertEqual(farAway.quad.boundingBoxIoU(with: tracked), 0,
                       "Precondition: the escape only matters when IoU is zero.")

        let verdict = verifier.evaluate(tracked: tracked, candidates: [farAway], timestamp: 0)
        guard case .diverged = verdict else {
            return XCTFail("A candidate 0.30 away from a 0.13-tall panel is a DIFFERENT display and must diverge, not corroborate. Got \(verdict)")
        }
    }

    /// The legitimate case the center test exists for must still work: the
    /// detector proposing a tighter crop of the same display, whose center
    /// barely moves.
    func testCorroborationRadius_tighterCropOfSameDisplay_stillCorroborates() {
        var verifier = TrackVerifier()
        let tracked = quad(0.12, 0.44, 0.76, 0.13)
        // Same display, detector proposes a tighter box: center within ~0.02.
        let tighter = candidate(quad(0.20, 0.455, 0.60, 0.10), confidence: 0.9)
        XCTAssertEqual(verifier.evaluate(tracked: tracked, candidates: [tighter], timestamp: 0),
                       .corroborated)
    }

    /// Coupling compares a RATE, so an unevenly-spaced detection pass cannot
    /// masquerade as motion. Detection is nominally every 0.5 s but a pass may
    /// arrive up to couplingMemoryMaxAge (1.6 s) later and is still used — a
    /// raw-displacement bound would treat the same physical speed as 3x after
    /// a delayed pass and false-veto a correctly tracked display.
    func testCoupling_delayedPass_doesNotFalseVetoAttachedLock() {
        var verifier = TrackVerifier()
        let id = UUID()
        // Display and lock both drift together at a slow, trackable
        // 0.03 units/sec; witness carries a small independent jitter.
        let v: CGFloat = 0.03
        var t = 0.0
        _ = verifier.evaluate(tracked: quad(0.12, 0.44, 0.76, 0.13),
                              candidates: [persistentCandidate(id: id, quad(0.12, 0.44, 0.76, 0.13))],
                              timestamp: t)
        // A LATE pass: 1.5 s instead of 0.5 s. Both moved v*1.5 = 0.045
        // together — well past the old 0.035 raw-displacement bound, but the
        // RELATIVE rate is only jitter.
        t = 1.5
        let d = v * 1.5
        let verdict = verifier.evaluate(tracked: quad(0.12 + d, 0.44, 0.76, 0.13),
                                        candidates: [persistentCandidate(id: id, quad(0.12 + d + 0.004, 0.44, 0.76, 0.13))],
                                        timestamp: t)
        XCTAssertEqual(verdict, .corroborated,
                       "A delayed detection pass must not false-veto an attached lock — scheduling jitter is not motion.")
        XCTAssertFalse(verifier.isUnverified)
    }

    /// The rate formulation must still catch the live failure regardless of
    /// pass spacing: a static drifted quad swept by a panel moving 0.11/s.
    func testCoupling_sweepThroughVetoesAtAnyPassSpacing() {
        for gap in [0.4, 0.5, 1.0, 1.5] {
            var verifier = TrackVerifier()
            let parked = quad(0.12, 0.44, 0.76, 0.13)
            let id = UUID()
            _ = verifier.evaluate(tracked: parked,
                                  candidates: [persistentCandidate(id: id, quad(0.10, 0.44, 0.76, 0.13))],
                                  timestamp: 0)
            // Panel travels 0.11 units/sec through the static quad.
            let travelled = 0.11 * gap
            let verdict = verifier.evaluate(tracked: parked,
                                            candidates: [persistentCandidate(id: id, quad(0.10 + travelled, 0.44, 0.76, 0.13))],
                                            timestamp: gap)
            guard case .transit = verdict else {
                return XCTFail("A 0.11/s sweep must veto at pass spacing \(gap)s. Got \(verdict)")
            }
        }
    }

}
