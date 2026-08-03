//
//  DriftRegressionTests.swift
//  DAQPalTests
//
//  End-to-end regression for the fast-motion drift defect (remediation plan
//  Phase 19, ARCHITECTURE.md §9): under fast motion the tracker drifted onto
//  background while reporting healthy, the UI stayed LOCKED, and OCR kept
//  producing values — while the detector was re-proposing the real panel at
//  high confidence elsewhere. The fix under test is the REAL pipeline:
//  `ScreenLockPipeline` with a real `ScreenCandidateDetector` and a real
//  `VisionScreenTracker` over real rendered frames.
//
//  Timing realism, stated plainly: every frame here runs real Vision tracking
//  and many frames run real Vision rectangle+text detection on 1080×1920
//  rendered buffers (~50–100 ms per detection pass on the Simulator), so these
//  tests take tens of seconds of WALL-CLOCK time. That is accepted — this is
//  the keystone integration proof, not a unit test.
//
//  Determinism: frame timestamps are synthetic (`Double(i) / 12`), poses are
//  driven explicitly, no Date(), no sleeps, no randomness in this file. Vision
//  itself is the only nondeterministic component, which is exactly what the
//  probe test at the top pins down before the scenario tests interpret it.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class DriftRegressionTests: XCTestCase {

    // MARK: - Rig

    private let renderer = SyntheticDisplayRenderer()
    /// 12 fps — the synthetic source's native rate.
    private let fps = 12.0
    private var dt: TimeInterval { 1.0 / fps }

    private func frame(pose: DisplayPose, at t: TimeInterval) throws -> TimestampedFrame {
        guard let buffer = renderer.render(text: "12.347", pose: pose) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: t)
    }

    private func truthQuad(for pose: DisplayPose) -> ScreenQuad {
        ScreenQuad(roi: renderer.panelROI(for: pose))
    }

    // MARK: - Probe: can Vision see the synthetic panel at all?
    //
    // Everything below depends on `ScreenCandidateDetector` proposing the
    // rendered panel. If it cannot on this OS/Simulator, the scenario tests
    // have no premise, and the honest outcome is THIS test failing with a
    // description of what the detector actually returned — not the scenario
    // tests quietly weakening their assertions.

    func testDetectorProposesTheSteadySyntheticPanel() async throws {
        let detector = ScreenCandidateDetector()
        let truth = truthQuad(for: .identity)
        var bestIoU: CGFloat = 0
        var bestConfidence: Float = 0
        var lastPass: [String] = []

        // Several passes at the pipeline's acquiring cadence so temporal
        // stability accumulates as it would live.
        for i in 0..<8 {
            let probeFrame = try frame(pose: .identity, at: Double(i) * 0.25)
            let candidates = await detector.detect(in: probeFrame)
            lastPass = candidates.map {
                String(format: "conf %.3f iou %.3f box %@",
                       $0.confidence,
                       $0.quad.boundingBoxIoU(with: truth),
                       String(describing: $0.quad.boundingBox))
            }
            for candidate in candidates {
                let iou = candidate.quad.boundingBoxIoU(with: truth)
                if iou > bestIoU { bestIoU = iou }
                if iou >= 0.3 { bestConfidence = max(bestConfidence, candidate.confidence) }
            }
        }

        XCTAssertGreaterThanOrEqual(bestIoU, 0.3,
                                    "the detector never proposed anything overlapping the panel "
                                    + "(best IoU \(bestIoU)); last pass returned: \(lastPass)")
        // Lock requires fused confidence ≥ SnapTuning.enterLock (0.90) for 3
        // consecutive frames. If the detector tops out below that, the
        // scenario tests cannot lock and this message says so directly.
        XCTAssertGreaterThanOrEqual(bestConfidence, SnapTuning.default.enterLock,
                                    "the panel candidate peaked at fused confidence "
                                    + "\(bestConfidence) < enterLock "
                                    + "\(SnapTuning.default.enterLock); the pipeline cannot lock "
                                    + "on this OS/Simulator. Last pass: \(lastPass)")
    }

    // MARK: - Shared drivers

    /// A selected numeric field in canonical target space — what makes
    /// `fieldROIs` meaningfully non-empty while measurements are valid.
    private var selectedNumericField: ScreenField {
        ScreenField(region: NormalizedROI(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
                    kind: .numeric, label: "VOLTS", format: .unconstrained,
                    isSelected: true, detectionConfidence: 0.9)
    }

    /// Runs steady frames at `pose` until the pipeline locks. Returns the frame
    /// index of the locking frame, or fails with the best candidate confidence
    /// seen (the honest diagnosis when Vision underperforms the lock gate).
    private func driveToLock(_ pipeline: ScreenLockPipeline,
                             pose: DisplayPose,
                             frameIndex: inout Int,
                             bound: Int) async throws -> Int? {
        var bestConfidence: Float = 0
        let limit = frameIndex + bound
        while frameIndex < limit {
            let f = try frame(pose: pose, at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: f,
                                                selection: truthQuad(for: pose),
                                                isUserDragging: false)
            let lockedAt = frameIndex
            frameIndex += 1
            bestConfidence = max(bestConfidence, update.candidates.map(\.confidence).max() ?? 0)
            if update.didLock {
                XCTAssertTrue(update.measurementsValid,
                              "a freshly committed lock must start with valid measurements")
                return lockedAt
            }
        }
        XCTFail("no lock within \(bound) steady frames; best fused candidate confidence "
                + "seen was \(bestConfidence) (enterLock is \(SnapTuning.default.enterLock))")
        return nil
    }

    // MARK: - The keystone: fast-motion drift must invalidate, then relock
    //
    // Scenario (plan Phase 19). Steady panel → lock → the panel moves faster
    // than any tracker can follow (modelled as: gone for 3 frames, then steady
    // at a far position — a super-frame-rate translation, the limiting case of
    // `.bounce`'s wall-to-wall motion). The OLD behavior fails every drift
    // assertion below: the UI stayed LOCKED and ROIs kept flowing while the
    // tracked quad sat on background.
    //
    // WALL-CLOCK WARNING: this runs real Vision tracking every frame plus real
    // detection passes over ~2 minutes of simulated recovery — expect tens of
    // seconds.

    func testFastMotionDriftInvalidatesMeasurementsThenRelocks() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)

        let homePose = DisplayPose.identity
        // Far position: same shape, centered high in the frame. Chosen so the
        // stale tracked quad (home) and the real panel are ~0.35 apart in
        // normalized units — far beyond `attractionRadius`, so nothing can
        // silently re-grab without genuinely re-verifying geometry.
        let movedPose = DisplayPose(center: CGPoint(x: 0.5, y: 0.16),
                                    roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        // The super-fast transit itself: the panel is off-frame for 3 frames
        // (0.25 s), i.e. it moved faster than one frame can capture.
        let transitPose = DisplayPose(center: CGPoint(x: 0.5, y: 1.8),
                                      roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        let movedTruth = truthQuad(for: movedPose)

        var frameIndex = 0

        // --- Phase A: steady until locked -------------------------------
        guard let lockFrame = try await driveToLock(pipeline, pose: homePose,
                                                    frameIndex: &frameIndex, bound: 72) else {
            return
        }
        await pipeline.setSelectedFields([selectedNumericField])

        // --- Phase B: steady while locked: valid, ROIs flowing ----------
        var sawFieldROI = false
        for i in 0..<12 {
            let f = try frame(pose: homePose, at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: f,
                                                selection: truthQuad(for: homePose),
                                                isUserDragging: false)
            frameIndex += 1
            guard case .locked = update.snapState else {
                return XCTFail("lock did not survive steady frame \(i) after locking: "
                               + "\(update.snapState)")
            }
            XCTAssertTrue(update.measurementsValid,
                          "steady locked frame \(i) lost measurement validity")
            if !update.fieldROIs.isEmpty { sawFieldROI = true }
        }
        XCTAssertTrue(sawFieldROI,
                      "a selected numeric field never produced a tracked-geometry ROI "
                      + "while locked and valid")

        // --- Phase C: THE DRIFT -----------------------------------------
        let driftStart = frameIndex
        var firstLowIoU: Int?
        var invalidFrame: Int?
        var leftLockedFrame: Int?
        var relockFrame: Int?
        var sawDidLockOnRelock = false
        var violations: [String] = []

        let recoveryBound = driftStart + 3 + 150 // transit + 12.5 s of recovery
        while frameIndex < recoveryBound, relockFrame == nil {
            let inTransit = frameIndex < driftStart + 3
            let pose = inTransit ? transitPose : movedPose
            let f = try frame(pose: pose, at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: f,
                                                selection: inTransit ? nil : truthQuad(for: movedPose),
                                                isUserDragging: false)
            let index = frameIndex
            frameIndex += 1

            // Tracked-vs-ground-truth overlap. During transit the panel is
            // off-frame, so any tracked quad is by definition not on it.
            let iou = update.target.map { $0.quad.boundingBoxIoU(with: movedTruth) } ?? 0
            if firstLowIoU == nil, iou < 0.1 { firstLowIoU = index }

            if invalidFrame == nil, !update.measurementsValid { invalidFrame = index }
            if leftLockedFrame == nil {
                if case .locked = update.snapState {} else { leftLockedFrame = index }
            }

            // 4a: once invalidated, measurements must NEVER be valid again
            // while the geometry still points away from the real panel.
            if update.measurementsValid, iou < 0.5 {
                violations.append("frame \(index): measurementsValid with tracked/truth IoU \(iou)")
            }
            // 4c: no field ROI may flow while unverified.
            if invalidFrame != nil, !update.measurementsValid, !update.fieldROIs.isEmpty {
                violations.append("frame \(index): fieldROIs flowed while invalid")
            }

            // Recovery: valid measurements on locked, ground-truth-aligned
            // geometry. `didLock` is the organic path (reacquisition timeout →
            // release → fresh acquisition); a corroborated tracker recovery is
            // also legitimate — the IoU gate above is what makes either honest.
            if update.measurementsValid, iou >= 0.5, invalidFrame != nil {
                if case .locked = update.snapState {
                    relockFrame = index
                    sawDidLockOnRelock = update.didLock
                }
            }
        }

        XCTAssertTrue(violations.isEmpty, "drift-window violations: \(violations)")

        guard let firstLowIoU else {
            return XCTFail("the tracked quad never diverged from ground truth (IoU stayed "
                           + "≥ 0.1) — the drift scenario did not exercise the defect")
        }
        guard let invalidFrame else {
            return XCTFail("measurementsValid never went false after the drift began at "
                           + "frame \(driftStart) — the OLD drift behavior (values keep "
                           + "flowing from background)")
        }
        // 4a bound: locked-cadence detection is 0.5 s (6 frames) and the stale
        // tracker timeout is 0.75 s (9 frames); 15 frames covers both paths
        // with margin.
        XCTAssertLessThanOrEqual(invalidFrame, firstLowIoU + 15,
                                 "measurements stayed valid for \(invalidFrame - firstLowIoU) "
                                 + "frames after the tracked quad left the panel")
        guard let leftLockedFrame else {
            return XCTFail("the snap state never left plain .locked after the drift — "
                           + "the UI would have shown LOCKED over background")
        }
        XCTAssertLessThanOrEqual(leftLockedFrame, firstLowIoU + 15,
                                 "snap state stayed .locked for \(leftLockedFrame - firstLowIoU) "
                                 + "frames after the tracked quad left the panel")
        guard let relockFrame else {
            return XCTFail("the pipeline never re-locked on the panel's new position within "
                           + "\(recoveryBound - driftStart) frames of the drift "
                           + "(invalidated at \(invalidFrame), left .locked at \(leftLockedFrame))")
        }

        // --- Phase D: the relock is a real, verified lock ---------------
        await pipeline.setSelectedFields([selectedNumericField])
        var sawFieldROIAfterRelock = false
        for i in 0..<12 {
            let f = try frame(pose: movedPose, at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: f,
                                                selection: truthQuad(for: movedPose),
                                                isUserDragging: false)
            frameIndex += 1
            guard case .locked = update.snapState else {
                return XCTFail("relock did not survive steady frame \(i): \(update.snapState)")
            }
            XCTAssertTrue(update.measurementsValid, "relocked steady frame \(i) went invalid")
            let iou = update.target.map { $0.quad.boundingBoxIoU(with: movedTruth) } ?? 0
            XCTAssertGreaterThanOrEqual(iou, 0.5,
                                        "relocked geometry does not cover the real panel (frame \(i))")
            if !update.fieldROIs.isEmpty { sawFieldROIAfterRelock = true }
        }
        XCTAssertTrue(sawFieldROIAfterRelock,
                      "field ROIs never resumed after a verified relock")

        print("DRIFT-METRICS: lockFrame=\(lockFrame) driftStart=\(driftStart) "
              + "firstLowIoU=\(firstLowIoU) invalidFrame=\(invalidFrame) "
              + "leftLockedFrame=\(leftLockedFrame) relockFrame=\(relockFrame) "
              + "relockViaDidLock=\(sawDidLockOnRelock)")
    }

    // MARK: - The other direction: a good lock must not be poisoned
    //
    // Requirement: 10+ seconds of synthetic time steadily locked, with the
    // verifier revalidating every 0.5 s (20+ passes), must keep
    // `measurementsValid == true` on EVERY frame. Catches an over-aggressive
    // veto — a verifier that slowly accumulates false strikes against a
    // perfectly good lock.
    //
    // WALL-CLOCK WARNING: ~130 real Vision tracking passes plus ~20 detection
    // passes — expect tens of seconds.

    func testSteadyLockKeepsMeasurementsValidForTenSeconds() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)

        var frameIndex = 0
        guard try await driveToLock(pipeline, pose: .identity,
                                    frameIndex: &frameIndex, bound: 72) != nil else {
            return
        }
        await pipeline.setSelectedFields([selectedNumericField])

        let steadyFrames = Int(10.5 * fps) // > 10 s of synthetic time
        var invalidFrames: [Int] = []
        var nonLockedFrames: [Int] = []
        for _ in 0..<steadyFrames {
            let f = try frame(pose: .identity, at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: f,
                                                selection: truthQuad(for: .identity),
                                                isUserDragging: false)
            if !update.measurementsValid { invalidFrames.append(frameIndex) }
            if case .locked = update.snapState {} else { nonLockedFrames.append(frameIndex) }
            frameIndex += 1
        }

        XCTAssertTrue(nonLockedFrames.isEmpty,
                      "a steady panel dropped out of .locked on frames \(nonLockedFrames)")
        XCTAssertTrue(invalidFrames.isEmpty,
                      "the verifier poisoned a good steady lock: measurementsValid went "
                      + "false on \(invalidFrames.count) of \(steadyFrames) frames "
                      + "(first at \(invalidFrames.first.map(String.init) ?? "-")) — "
                      + "an over-aggressive veto")
    }
}
