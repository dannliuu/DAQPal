//
//  PoseTrajectory.swift
//  DAQPal
//
//  Deterministic 3-D pose trajectories for homography-tracking benchmarks.
//
//  Contract: every trajectory is a PURE function of the timestamp `t` — no
//  hidden integrated state anywhere — so ground truth is replayable from a
//  timestamp alone: any consumer (renderer, benchmark harness, test) that
//  evaluates `pose(at: t)` gets bit-identical answers, in any order, at any
//  sample rate. Even `bounce3D`'s wall reflections are computed in closed
//  form (a triangle wave), not integrated.
//
//  Amplitudes are chosen so the default panel
//  (`SyntheticDisplayRenderer.displayROI`, 0.76 × 0.13) stays inside the
//  1080×1920 frame throughout, and all rotations stay inside
//  `DisplayPose3D`'s documented envelope (|yaw|,|pitch| ≤ 60°, |roll| ≤ 45°).
//

import CoreGraphics
import Foundation

/// A named, deterministic pose-vs-time curve. `pose(at:)` yields the
/// `DisplayPose3D` for any timestamp; `groundTruthQuad(at:)` is the projected
/// four-corner ground truth benchmarks compare a tracker against.
enum PoseTrajectory: String, CaseIterable, Sendable {
    /// Static panel at the home pose.
    case steady
    /// ±45° yaw sinusoid — pure keystone sweep.
    case yawSweep
    /// ±35° pitch sinusoid.
    case pitchSweep
    /// ±25° roll sinusoid — beyond Vision's text tolerance on purpose; this
    /// rig benchmarks GEOMETRY tracking, not OCR.
    case rollSweep
    /// Yaw + pitch + roll + translation + depth, all sinusoids at
    /// incommensurate frequencies so the pose never exactly repeats.
    case tumble3D
    /// Lateral translation with peak speed ≥ 0.6 normalized units/s —
    /// deliberately ABOVE the ~0.24 u/s the existing ROI tracker can follow
    /// (`AppState.trackingMaxStep` × processed fps), to reproduce the
    /// tracking-drift defect on demand.
    case fastTranslation
    /// Static pose that TELEPORTS to a distant position at
    /// `Self.stepJumpTime` — the reacquisition benchmark.
    case stepJump
    /// Constant-speed translation reflecting elastically off the frame walls
    /// (closed-form triangle wave, still a pure function of `t`), plus mild
    /// yaw/pitch and a slow depth swell.
    case bounce3D

    /// Normalized size of the default synthetic panel, forwarded from the
    /// renderer so the two can never drift apart.
    static let defaultPanelSize = CGSize(width: SyntheticDisplayRenderer.displayROI.width,
                                         height: SyntheticDisplayRenderer.displayROI.height)
    /// The synthetic frame is 1080×1920.
    static let defaultFrameAspect: CGFloat = 1080.0 / 1920.0
    /// When `stepJump` teleports.
    static let stepJumpTime: TimeInterval = 8

    /// Closed-form peak of `fastTranslation`'s DOMINANT (y) velocity
    /// component, normalized units/s — a guaranteed LOWER BOUND on the true
    /// commanded peak speed (the x component adds up to ~0.34 u/s on top
    /// when the phases align). Exposed so benchmarks can state a provable
    /// speed floor without a finite-difference estimate.
    static let fastTranslationPeakSpeed: CGFloat = 0.24 * 2 * .pi * 0.5

    /// The pose at time `t`. Pure — no state, no side effects.
    func pose(at t: TimeInterval) -> DisplayPose3D {
        let time = CGFloat(t)
        let f = DisplayPose3D.defaultFocalLength
        let home = DisplayPose3D.homeCenter
        var pose = DisplayPose3D()

        switch self {
        case .steady:
            break

        case .yawSweep:
            pose.yaw = Self.deg(45) * sin(2 * .pi * 0.15 * time)

        case .pitchSweep:
            pose.pitch = Self.deg(35) * sin(2 * .pi * 0.15 * time)

        case .rollSweep:
            pose.roll = Self.deg(25) * sin(2 * .pi * 0.12 * time)

        case .tumble3D:
            pose.yaw = Self.deg(30) * sin(2 * .pi * 0.13 * time)
            pose.pitch = Self.deg(22) * sin(2 * .pi * 0.09 * time + 1.1)
            pose.roll = Self.deg(15) * sin(2 * .pi * 0.17 * time + 0.4)
            pose.center = CGPoint(x: home.x + 0.05 * sin(2 * .pi * 0.07 * time),
                                  y: home.y + 0.06 * sin(2 * .pi * 0.05 * time + 0.9))
            // Depth only recedes (≥ f) so the enlarged panel never clips.
            pose.distance = f * (1.2 + 0.2 * sin(2 * .pi * 0.06 * time + 2.3))

        case .fastTranslation:
            // Dominant y component: 0.24 × 2π×0.5 ≈ 0.75 u/s peak — see
            // `fastTranslationPeakSpeed`. The x component adds a little
            // 2-D-ness without pushing the wide panel off-frame.
            pose.center = CGPoint(x: home.x + 0.06 * sin(2 * .pi * 0.9 * time),
                                  y: home.y + 0.24 * sin(2 * .pi * 0.5 * time))

        case .stepJump:
            // Recede to 2.2f so the panel is small enough that the jump is
            // a genuinely distant teleport (~0.62 normalized units).
            pose.distance = f * 2.2
            pose.center = t < Self.stepJumpTime
                ? CGPoint(x: 0.30, y: 0.28)
                : CGPoint(x: 0.72, y: 0.74)

        case .bounce3D:
            pose.center = CGPoint(x: Self.reflected(start: home.x, velocity: 0.16, t: time, lo: 0.38, hi: 0.62),
                                  y: Self.reflected(start: home.y, velocity: 0.12, t: time, lo: 0.20, hi: 0.80))
            pose.yaw = Self.deg(20) * sin(2 * .pi * 0.08 * time)
            pose.pitch = Self.deg(15) * sin(2 * .pi * 0.06 * time + 0.5)
            pose.distance = f * (1.3 + 0.25 * sin(2 * .pi * 0.11 * time))
        }
        return pose
    }

    /// Ground-truth screen quad at time `t` — `pose(at:)` projected with the
    /// default synthetic panel geometry (override for non-default rigs).
    func groundTruthQuad(at t: TimeInterval,
                         panelSize: CGSize = PoseTrajectory.defaultPanelSize,
                         frameAspect: CGFloat = PoseTrajectory.defaultFrameAspect) -> ScreenQuad {
        pose(at: t).projectedQuad(panelSize: panelSize, frameAspect: frameAspect)
    }

    /// Closed-form position of a point moving at constant `velocity` from
    /// `start`, reflecting elastically off `lo`/`hi` — a triangle wave in
    /// `t`, NOT an integration, so replay from any timestamp is exact.
    static func reflected(start: CGFloat, velocity: CGFloat, t: CGFloat,
                          lo: CGFloat, hi: CGFloat) -> CGFloat {
        let range = hi - lo
        guard range > 0 else { return lo }
        let raw = (start - lo + velocity * t).truncatingRemainder(dividingBy: 2 * range)
        let phase = raw < 0 ? raw + 2 * range : raw
        return phase <= range ? lo + phase : hi - (phase - range)
    }

    private static func deg(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
}
