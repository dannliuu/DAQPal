//
//  DemoMotion.swift
//  DAQPal
//
//  Motion patterns for the Simulator's synthetic display — a stress-test rig
//  for ROI tracking and recognition-under-motion. Tapping the SYNTHETIC chip
//  cycles patterns; `-daqpal-demo-motion <name>` selects one at launch.
//  Modes: steady, yaw, pitch, roll, tumble, bounce, scale, driftDiagonal,
//  stress.
//
//  Honesty note: like `SyntheticDisplayRenderer`, this simulates *geometry*
//  only (a display translating/rotating/foreshortening/scaling in frame),
//  not real optics. Real-optics degradation (motion blur, sensor noise,
//  occlusion, lighting) is a *separate, opt-in* layer —
//  `RenderDegradation` in `SyntheticFrameSource.swift` — applied by the
//  renderer, not by this pose model. Passing here is necessary, not
//  sufficient, for real handheld robustness.
//

import CoreGraphics
import Foundation

/// Selectable motion pattern for the synthetic display.
enum DemoMotion: String, CaseIterable, Sendable {
    /// The original static panel.
    case steady
    /// Oscillating rotation about the vertical axis — rendered as horizontal
    /// foreshortening (an affine approximation; CoreGraphics has no
    /// perspective transform), the dominant visual effect of yaw.
    case yaw
    /// Oscillating rotation about the horizontal axis — vertical
    /// foreshortening.
    case pitch
    /// Oscillating in-plane rotation. Amplitude is kept within what Vision's
    /// text recognizer tolerates (~±10°) so the pattern tests tracking, not
    /// just guaranteed rejection.
    case roll
    /// Yaw + pitch + roll at incommensurate frequencies, so the pose never
    /// exactly repeats.
    case tumble
    /// Classic bouncing-DVD-logo translation: constant velocity, elastic
    /// reflection off the frame edges.
    case bounce
    /// Panel apparent size oscillates (zoom in/out), e.g. a probe moving
    /// closer to/further from the camera. Position and rotation untouched.
    case scale
    /// Slow constant diagonal translation that wraps toroidally at the
    /// frame edges — distinct from `.bounce`'s faster, elastic-reflection
    /// velocity; a gentle sustained-translation test.
    case driftDiagonal
    /// Everything at once: fast translation (elastic reflection, faster
    /// than `.bounce`) + yaw + pitch + roll + scale oscillation, all at
    /// incommensurate frequencies. The renderer additionally applies a
    /// moderate default `RenderDegradation` (blur + noise + occasional
    /// occlusion) when this mode is active, so one tap gives a genuinely
    /// hard scenario.
    case stress

    var displayLabel: String { rawValue.uppercased() }

    /// Cycle order = declaration order.
    var next: DemoMotion {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self) else { return .steady }
        return all[(index + 1) % all.count]
    }
}

/// Where and how the synthetic LCD panel is drawn for one frame. All values
/// are deterministic functions of elapsed time (plus integrated bounce state)
/// — no randomness, so tests can replay exact sequences.
struct DisplayPose: Equatable, Sendable {
    /// Panel center in normalized top-left-origin frame coordinates.
    var center: CGPoint
    /// In-plane rotation in radians (positive = clockwise on screen, since
    /// the render context is y-down).
    var roll: CGFloat
    /// Horizontal foreshortening factor, `cos(yawAngle)` ∈ (0, 1].
    var yawScale: CGFloat
    /// Vertical foreshortening factor, `cos(pitchAngle)` ∈ (0, 1].
    var pitchScale: CGFloat
    /// Apparent-size multiplier applied on top of `yawScale`/`pitchScale`
    /// (a probe moving closer to/further from the camera). Defaults to 1 so
    /// every existing call site — none of which mention `scale` — keeps
    /// producing the original, unscaled pose.
    var scale: CGFloat = 1

    /// The un-moved pose: panel centered exactly on
    /// `SyntheticDisplayRenderer.displayROI`, no rotation, no foreshortening,
    /// no scale change.
    /// Rendering this pose is byte-identical to the pre-motion renderer.
    static let identity = DisplayPose(center: DemoMotionModel.homeCenter,
                                      roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
}

/// Advances a `DisplayPose` over time for one `DemoMotion`. Value type; the
/// frame loop owns one instance and calls `pose(at:dt:)` once per frame.
/// Bounce position/velocity persist across mode switches, and non-bounce
/// modes glide the panel back to its home position rather than teleporting.
struct DemoMotionModel: Sendable {
    var mode: DemoMotion = .steady

    /// Current panel center — integrated for `.bounce`, relaxed toward
    /// `homeCenter` for every other mode.
    private var center: CGPoint = DemoMotionModel.homeCenter
    /// Bounce velocity in normalized units/second. Deliberately below the ROI
    /// tracker's maximum follow speed (`AppState.trackingMaxStep` × processed
    /// fps ≈ 0.24/s) so a healthy tracker *can* hold the lock — the stress is
    /// in the sustained motion and the wall reflections, not in being
    /// physically unfollowable.
    private var velocity = CGVector(dx: 0.11, dy: 0.083)
    /// `.stress` translation velocity — faster than `.bounce`'s, and an
    /// incommensurate direction, so the two never coincide. Kept as separate
    /// state (rather than reusing `velocity`) so switching between `.bounce`
    /// and `.stress` doesn't splice one mode's speed onto the other.
    private var stressVelocity = CGVector(dx: 0.19, dy: -0.15)
    /// `.driftDiagonal` translation, integrated into the shared `center` like
    /// bounce/stress but wrapped (not reflected) at the walls — deliberately
    /// slower than `.bounce`'s velocity (see `driftVelocity`).
    static let driftVelocity = CGVector(dx: 0.028, dy: 0.021)

    /// Home = the static `displayROI` center, derived (not duplicated) so the
    /// two can never drift apart.
    static var homeCenter: CGPoint {
        let roi = SyntheticDisplayRenderer.displayROI
        return CGPoint(x: roi.x + roi.width / 2, y: roi.y + roi.height / 2)
    }

    /// Peak yaw/pitch tilt. cos(55°) ≈ 0.57 — digits squeeze to ~half their
    /// width at the extremes, which is where recognizers start failing; the
    /// oscillation sweeps through the whole easy→hard range.
    static let maxTiltAngle: CGFloat = 55 * .pi / 180
    /// Peak roll, within Vision's practical text-rotation tolerance.
    static let maxRollAngle: CGFloat = 10 * .pi / 180
    /// Bounce keeps the panel center at least this far from each frame edge
    /// (panel half-extent + a small pad) so the panel never clips off-frame.
    static let bounceInsetX: CGFloat = SyntheticDisplayRenderer.displayROI.width / 2 + 0.01
    static let bounceInsetY: CGFloat = SyntheticDisplayRenderer.displayROI.height / 2 + 0.01
    /// Glide-home speed (normalized units/s) after leaving bounce mode.
    static let homingSpeed: CGFloat = 0.35
    /// `.scale` oscillation midpoint/amplitude: 0.95 ± 0.45 covers 0.5x–1.4x,
    /// the spec's zoom range.
    static let scaleMidpoint: CGFloat = 0.95
    static let scaleAmplitude: CGFloat = 0.45
    /// Scale never collapses to (or below) zero, matching the floor already
    /// applied to yaw/pitch foreshortening.
    static let minScale: CGFloat = 0.15

    /// Pose for the frame at elapsed time `t`; `dt` is the interval since the
    /// previous frame (used to integrate bounce/drift/stress and homing).
    mutating func pose(at t: TimeInterval, dt: TimeInterval) -> DisplayPose {
        switch mode {
        case .bounce:
            Self.integrateReflecting(center: &center, velocity: &velocity, dt: CGFloat(dt))
        case .stress:
            Self.integrateReflecting(center: &center, velocity: &stressVelocity, dt: CGFloat(dt))
        case .driftDiagonal:
            integrateDrift(dt: CGFloat(dt))
        default:
            glideHome(dt: CGFloat(dt))
        }

        var pose = DisplayPose(center: center, roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        switch mode {
        case .steady, .bounce, .driftDiagonal:
            break
        case .yaw:
            pose.yawScale = Self.foreshortening(Self.maxTiltAngle * sin(2 * .pi * 0.16 * t))
        case .pitch:
            pose.pitchScale = Self.foreshortening(Self.maxTiltAngle * sin(2 * .pi * 0.16 * t))
        case .roll:
            pose.roll = Self.maxRollAngle * sin(2 * .pi * 0.12 * t)
        case .tumble:
            pose.yawScale = Self.foreshortening(Self.maxTiltAngle * 0.7 * sin(2 * .pi * 0.13 * t))
            pose.pitchScale = Self.foreshortening(Self.maxTiltAngle * 0.5 * sin(2 * .pi * 0.09 * t + 1.1))
            pose.roll = Self.maxRollAngle * sin(2 * .pi * 0.17 * t + 0.4)
        case .scale:
            pose.scale = Self.scaleFactor(at: t, frequency: 0.14, phase: 0)
        case .stress:
            pose.yawScale = Self.foreshortening(Self.maxTiltAngle * 0.7 * sin(2 * .pi * 0.21 * t))
            pose.pitchScale = Self.foreshortening(Self.maxTiltAngle * 0.5 * sin(2 * .pi * 0.19 * t + 1.1))
            pose.roll = Self.maxRollAngle * sin(2 * .pi * 0.23 * t + 0.4)
            pose.scale = Self.scaleFactor(at: t, frequency: 0.11, phase: 0.7)
        }
        return pose
    }

    /// `midpoint ± amplitude`, floored so the panel never collapses to (or
    /// past) zero size.
    private static func scaleFactor(at t: TimeInterval, frequency: Double, phase: Double) -> CGFloat {
        max(Self.minScale, Self.scaleMidpoint + Self.scaleAmplitude * sin(2 * .pi * frequency * t + phase))
    }

    /// `cos(angle)` floored away from zero so the panel never degenerates to
    /// an invisible sliver (and the renderer's scale never hits 0).
    private static func foreshortening(_ angle: CGFloat) -> CGFloat {
        max(0.15, cos(angle))
    }

    /// Elastic reflection off the frame edges; shared by `.bounce` and
    /// `.stress`, each driving its own `velocity` so the two modes' speeds
    /// never bleed into one another across a mode switch. `static` (rather
    /// than a mutating instance method taking `velocity` as a second inout
    /// argument) sidesteps an exclusivity violation: a mutating method call
    /// already holds an inout access to all of `self` for its duration, so a
    /// second inout argument aliasing one of `self`'s stored properties
    /// (`velocity`/`stressVelocity`) would overlap it.
    private static func integrateReflecting(center: inout CGPoint, velocity: inout CGVector, dt: CGFloat) {
        var x = center.x + velocity.dx * dt
        var y = center.y + velocity.dy * dt
        let minX = Self.bounceInsetX, maxX = 1 - Self.bounceInsetX
        let minY = Self.bounceInsetY, maxY = 1 - Self.bounceInsetY
        // Elastic reflection; the overshoot is folded back inside so position
        // stays continuous through the wall contact.
        if x < minX { x = min(2 * minX - x, maxX); velocity.dx = abs(velocity.dx) }
        if x > maxX { x = max(2 * maxX - x, minX); velocity.dx = -abs(velocity.dx) }
        if y < minY { y = min(2 * minY - y, maxY); velocity.dy = abs(velocity.dy) }
        if y > maxY { y = max(2 * maxY - y, minY); velocity.dy = -abs(velocity.dy) }
        center = CGPoint(x: x, y: y)
    }

    /// Toroidal wrap at the frame edges — position re-enters from the
    /// opposite wall rather than bouncing back, the behavior that
    /// distinguishes `.driftDiagonal` from `.bounce`/`.stress`. Safe against
    /// overshoot: `driftVelocity * dt` is far smaller than the wrap range for
    /// any realistic frame interval.
    private mutating func integrateDrift(dt: CGFloat) {
        let minX = Self.bounceInsetX, maxX = 1 - Self.bounceInsetX
        let minY = Self.bounceInsetY, maxY = 1 - Self.bounceInsetY
        let rangeX = maxX - minX
        let rangeY = maxY - minY
        var x = center.x + Self.driftVelocity.dx * dt
        var y = center.y + Self.driftVelocity.dy * dt
        if x > maxX { x -= rangeX }
        if x < minX { x += rangeX }
        if y > maxY { y -= rangeY }
        if y < minY { y += rangeY }
        center = CGPoint(x: x, y: y)
    }

    private mutating func glideHome(dt: CGFloat) {
        let home = Self.homeCenter
        let dx = home.x - center.x
        let dy = home.y - center.y
        let distance = (dx * dx + dy * dy).squareRoot()
        let step = Self.homingSpeed * dt
        guard distance > 0.0005, distance > step else {
            center = home
            return
        }
        center = CGPoint(x: center.x + dx / distance * step,
                         y: center.y + dy / distance * step)
    }
}
