//
//  PoseTrajectoryTests.swift
//  DAQPalTests
//
//  PoseTrajectory contract tests: pure-function determinism (replayable from
//  a timestamp alone), the fastTranslation peak-speed floor that reproduces
//  the tracker-drift defect, the stepJump teleport, bounce3D's closed-form
//  reflections, and envelope/bounds discipline for every trajectory.
//

import CoreGraphics
import XCTest
@testable import DAQPal

final class PoseTrajectoryTests: XCTestCase {

    /// Same timestamp → identical pose, evaluated twice and out of order —
    /// the "no hidden integrated state" contract.
    func testDeterministicReplayFromTimestampAlone() {
        let timestamps: [TimeInterval] = [0, 0.017, 1.3, 7.99, 8.01, 12.345, 33.3, 100.7]
        for trajectory in PoseTrajectory.allCases {
            // Forward, backward, and repeated evaluation must all agree.
            let forward = timestamps.map { trajectory.pose(at: $0) }
            let backward = timestamps.reversed().map { trajectory.pose(at: $0) }.reversed()
            XCTAssertEqual(forward, Array(backward), "\(trajectory) is order-dependent")
            for (t, pose) in zip(timestamps, forward) {
                XCTAssertEqual(trajectory.pose(at: t), pose, "\(trajectory) not replayable at t=\(t)")
            }
        }
    }

    func testGroundTruthQuadMatchesPoseProjection() {
        for trajectory in PoseTrajectory.allCases {
            let t = 4.2
            let expected = trajectory.pose(at: t)
                .projectedQuad(panelSize: PoseTrajectory.defaultPanelSize,
                               frameAspect: PoseTrajectory.defaultFrameAspect)
            XCTAssertEqual(trajectory.groundTruthQuad(at: t), expected, "\(trajectory)")
        }
    }

    /// fastTranslation must peak at ≥ 0.6 normalized units/s — measured by
    /// finite differences at 240 Hz, not trusted from the constant.
    func testFastTranslationPeakSpeedExceedsTrackerFollowRate() {
        let dt: TimeInterval = 1.0 / 240.0
        var peak: CGFloat = 0
        var t: TimeInterval = 0
        while t < 4 {
            let a = PoseTrajectory.fastTranslation.pose(at: t).center
            let b = PoseTrajectory.fastTranslation.pose(at: t + dt).center
            peak = max(peak, hypot(b.x - a.x, b.y - a.y) / CGFloat(dt))
            t += dt
        }
        XCTAssertGreaterThanOrEqual(peak, 0.6,
                                    "measured peak \(peak) u/s — must exceed the ~0.24 u/s tracker follow rate by design")
        // The exposed closed-form constant is documented as a LOWER BOUND on
        // the true peak (the x component adds on top when phases align).
        XCTAssertGreaterThanOrEqual(peak, PoseTrajectory.fastTranslationPeakSpeed - 0.01)
        XCTAssertGreaterThanOrEqual(PoseTrajectory.fastTranslationPeakSpeed, 0.6)
    }

    /// stepJump: static on each side of the jump, a distant teleport at
    /// `stepJumpTime`.
    func testStepJumpDiscontinuity() {
        let before = PoseTrajectory.stepJump.pose(at: 0.5)
        let justBefore = PoseTrajectory.stepJump.pose(at: PoseTrajectory.stepJumpTime - 0.01)
        let justAfter = PoseTrajectory.stepJump.pose(at: PoseTrajectory.stepJumpTime + 0.01)
        let after = PoseTrajectory.stepJump.pose(at: 60)

        XCTAssertEqual(before, justBefore, "pose must be static before the jump")
        XCTAssertEqual(justAfter, after, "pose must be static after the jump")
        let jump = hypot(justAfter.center.x - justBefore.center.x,
                         justAfter.center.y - justBefore.center.y)
        XCTAssertGreaterThanOrEqual(jump, 0.3, "teleport of \(jump) u is not 'distant'")
    }

    /// bounce3D: continuous through wall reflections (speed never exceeds
    /// the commanded velocity magnitude) and the panel quad never leaves the
    /// frame.
    func testBounce3DContinuityAndBounds() {
        let dt: TimeInterval = 1.0 / 60.0
        var t: TimeInterval = 0
        var previous = PoseTrajectory.bounce3D.pose(at: 0).center
        while t < 40 {
            t += dt
            let pose = PoseTrajectory.bounce3D.pose(at: t)
            let step = hypot(pose.center.x - previous.x, pose.center.y - previous.y)
            XCTAssertLessThanOrEqual(step, 0.01,
                                     "teleport-sized step \(step) at t=\(t) — reflection must be continuous")
            previous = pose.center

            let box = PoseTrajectory.bounce3D.groundTruthQuad(at: t).boundingBox
            XCTAssertGreaterThanOrEqual(box.x, 0, "panel left edge off-frame at t=\(t)")
            XCTAssertGreaterThanOrEqual(box.y, 0, "panel top edge off-frame at t=\(t)")
            XCTAssertLessThanOrEqual(box.x + box.width, 1, "panel right edge off-frame at t=\(t)")
            XCTAssertLessThanOrEqual(box.y + box.height, 1, "panel bottom edge off-frame at t=\(t)")
        }
    }

    /// Closed-form reflection helper: exact triangle-wave values.
    func testReflectedClosedForm() {
        // start 0.5, v 0.1, range [0.4, 0.6]: hits 0.6 at t=1, back to 0.4
        // at t=3, back to 0.6 at t=5.
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: 0, lo: 0.4, hi: 0.6), 0.5, accuracy: 1e-12)
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: 1, lo: 0.4, hi: 0.6), 0.6, accuracy: 1e-12)
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: 2, lo: 0.4, hi: 0.6), 0.5, accuracy: 1e-12)
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: 3, lo: 0.4, hi: 0.6), 0.4, accuracy: 1e-12)
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: 5, lo: 0.4, hi: 0.6), 0.6, accuracy: 1e-12)
        // Negative time is equally well-defined (pure function of t).
        XCTAssertEqual(PoseTrajectory.reflected(start: 0.5, velocity: 0.1, t: -1, lo: 0.4, hi: 0.6), 0.4, accuracy: 1e-12)
    }

    /// Sweeps actually reach their advertised amplitudes (and never exceed
    /// them), and every trajectory stays inside DisplayPose3D's documented
    /// envelope with a convex, solvable quad throughout.
    func testAmplitudesAndEnvelope() {
        let deg: CGFloat = .pi / 180
        var maxYaw: CGFloat = 0, maxPitch: CGFloat = 0, maxRoll: CGFloat = 0
        var t: TimeInterval = 0
        while t <= 60 {
            for trajectory in PoseTrajectory.allCases {
                let pose = trajectory.pose(at: t)
                XCTAssertLessThanOrEqual(abs(pose.yaw), 60 * deg + 1e-9, "\(trajectory) yaw out of envelope at t=\(t)")
                XCTAssertLessThanOrEqual(abs(pose.pitch), 60 * deg + 1e-9, "\(trajectory) pitch out of envelope at t=\(t)")
                XCTAssertLessThanOrEqual(abs(pose.roll), 45 * deg + 1e-9, "\(trajectory) roll out of envelope at t=\(t)")
                let quad = trajectory.groundTruthQuad(at: t)
                XCTAssertTrue(quad.isConvex, "\(trajectory) quad non-convex at t=\(t)")
                XCTAssertNotNil(Homography.toCanonical(from: quad), "\(trajectory) quad unsolvable at t=\(t)")
                if trajectory == .yawSweep { maxYaw = max(maxYaw, abs(pose.yaw)) }
                if trajectory == .pitchSweep { maxPitch = max(maxPitch, abs(pose.pitch)) }
                if trajectory == .rollSweep { maxRoll = max(maxRoll, abs(pose.roll)) }
            }
            t += 0.05
        }
        XCTAssertGreaterThanOrEqual(maxYaw, 44.9 * deg, "yawSweep never reached ±45°")
        XCTAssertLessThanOrEqual(maxYaw, 45 * deg + 1e-9)
        XCTAssertGreaterThanOrEqual(maxPitch, 34.9 * deg, "pitchSweep never reached ±35°")
        XCTAssertGreaterThanOrEqual(maxRoll, 24.9 * deg, "rollSweep never reached ±25°")
    }
}
