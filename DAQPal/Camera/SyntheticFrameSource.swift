//
//  SyntheticFrameSource.swift
//  DAQPal
//

import CoreGraphics
import CoreVideo
import Foundation
import os
import UIKit

/// Opt-in, deterministic rendering degradation layered on top of a
/// `DisplayPose` — simulates real-optics effects (`SyntheticDisplayRenderer`'s
/// pose transform simulates only geometry). All fields default to "off" so
/// `render(text:pose:)` and any pre-existing call keeps producing exactly the
/// original frames. Every effect is a pure function of its inputs — never
/// `Double.random`/`arc4random` — so tests replay identical frames.
struct RenderDegradation: Equatable, Sendable {
    /// Fraction (0...1) of the panel's height covered by an opaque bar
    /// growing from the bottom edge — simulates a hand/probe over the
    /// display. Deterministic placement, never random.
    var occlusion: CGFloat = 0
    /// Motion-blur strength in points: the panel is drawn `blurSampleCount`
    /// times at offsets along a fixed diagonal direction (poses don't carry
    /// a velocity to blur along) at reduced alpha, then once more at full
    /// alpha and zero offset for a sharp core. 0 disables it.
    var blurRadius: CGFloat = 0
    /// Per-pixel noise magnitude (0...1). Applied via a deterministic
    /// integer hash of (x, y, frameIndex) — never a random source — so
    /// replaying the same frame index reproduces identical pixels.
    var noiseAmount: CGFloat = 0
    /// Panel luminance multiplier; 1 = unchanged, <1 darkens, >1 brightens.
    var brightness: CGFloat = 1

    /// No degradation — the default for every existing call site.
    static let none = RenderDegradation()
}

/// Renders a clearly-synthetic DMM-style display into a `CVPixelBuffer`:
/// a near-black instrument body with a lighter LCD panel showing large
/// monospaced digits. Used by `SyntheticFrameSource` (Simulator demo) and
/// directly by tests that need frames for arbitrary strings.
///
/// Honesty note: this is a stand-in for a physical display, not a model of
/// real DMM optics (segment gaps, glare, viewing angle). It exists so the
/// full recognition pipeline is exercisable without camera hardware — it
/// must never be presented as real-instrument data (see `CaptureStatus.simulated`
/// and the "SYNTHETIC SOURCE" UI labeling).
struct SyntheticDisplayRenderer {
    let size: CGSize

    /// Normalized location of the rendered LCD panel, top-left origin —
    /// matches project-wide ROI space. Lets a Simulator user drag a device
    /// window onto the panel, and lets tests build a `DeviceRecognitionConfig`
    /// that points at exactly where digits are drawn.
    static let displayROI = NormalizedROI(x: 0.12, y: 0.44, width: 0.76, height: 0.13)

    init(size: CGSize = CGSize(width: 1080, height: 1920)) {
        self.size = size
    }

    /// Draws `text` centered in the LCD panel over a `#0B0C0F` body, with the
    /// panel positioned/rotated/foreshortened by `pose` (default: the
    /// original static layout — that path is drawing-op-identical to the
    /// pre-motion renderer, which existing tests and fixtures rely on).
    /// Returns `nil` if the pixel buffer or bitmap context cannot be created.
    func render(text: String, pose: DisplayPose = .identity) -> CVPixelBuffer? {
        render(text: text, pose: pose, degradation: .none)
    }

    /// `render(text:pose:)` plus opt-in, deterministic optics degradation.
    /// `frameIndex` seeds the noise hash only — pass the actual frame index
    /// so noise varies frame-to-frame; a fixed index still replays exactly.
    func render(text: String, pose: DisplayPose = .identity,
                degradation: RenderDegradation, frameIndex: Int = 0) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // premultipliedFirst + byteOrder32Little is the standard recipe for a
        // bitmap context whose memory layout matches kCVPixelFormatType_32BGRA.
        guard let context = CGContext(data: base,
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }

        // CGContext's native origin is bottom-left; flip to top-left/y-down
        // so this drawing code and `NormalizedROI.pixelRect(in:)` agree.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(Self.backgroundColor)
        context.fill(CGRect(origin: .zero, size: size))

        // No degradation and no blur is the original code path, kept
        // byte-identical (no save/restore round-trip, no extra draws) since
        // fixtures and tests diff pixels against it.
        if degradation.blurRadius <= 0 {
            drawPose(text: text, pose: pose, context: context, degradation: degradation)
        } else {
            drawMotionBlurred(text: text, pose: pose, context: context, degradation: degradation)
        }

        if degradation.noiseAmount > 0 {
            applyNoise(base: base, bytesPerRow: bytesPerRow, amount: degradation.noiseAmount, frameIndex: frameIndex)
        }

        return buffer
    }

    /// One sharp draw of the panel at `pose`, with `degradation`'s
    /// non-blur effects (occlusion/brightness) applied. `pose == .identity`
    /// skips the translate/rotate/scale round-trip entirely — the path
    /// existing tests and fixtures diff pixels against.
    private func drawPose(text: String, pose: DisplayPose, context: CGContext,
                          degradation: RenderDegradation) {
        if pose == .identity {
            drawPanel(text: text, in: Self.displayROI.pixelRect(in: size), context: context, degradation: degradation)
        } else {
            // Transformed panel: same base rect, drawn centered on the origin
            // under translate → rotate(roll) → scale(yaw/pitch foreshortening
            // × apparent-size scale). Affine only — a deliberate
            // approximation of perspective (see `DemoMotion` doc note).
            let base = Self.displayROI.pixelRect(in: size)
            context.saveGState()
            context.translateBy(x: pose.center.x * size.width, y: pose.center.y * size.height)
            context.rotate(by: pose.roll)
            let combinedScale = max(pose.scale, 0.05)
            context.scaleBy(x: max(pose.yawScale, 0.05) * combinedScale,
                            y: max(pose.pitchScale, 0.05) * combinedScale)
            let rect = CGRect(x: -base.width / 2, y: -base.height / 2,
                              width: base.width, height: base.height)
            drawPanel(text: text, in: rect, context: context, degradation: degradation)
            context.restoreGState()
        }
    }

    /// Motion blur: `blurSampleCount - 1` faded "ghost" copies of the panel
    /// offset along a fixed diagonal direction (a `DisplayPose` carries no
    /// velocity to blur along the *true* motion direction — an honest
    /// approximation, matching this renderer's affine-only stance elsewhere),
    /// plus one sharp copy at the true position/alpha on top.
    private func drawMotionBlurred(text: String, pose: DisplayPose, context: CGContext,
                                   degradation: RenderDegradation) {
        let direction = CGVector(dx: 0.7071, dy: 0.7071)
        let sampleCount = 5
        let ghostAlpha: CGFloat = 0.35 / CGFloat(sampleCount - 1)
        for i in 0..<(sampleCount - 1) {
            let offsetFraction = CGFloat(i + 1) / CGFloat(sampleCount) - 0.5
            let offsetPoints = degradation.blurRadius * offsetFraction
            var ghostPose = pose
            ghostPose.center = CGPoint(x: pose.center.x + direction.dx * offsetPoints / size.width,
                                       y: pose.center.y + direction.dy * offsetPoints / size.height)
            context.setAlpha(ghostAlpha)
            drawPose(text: text, pose: ghostPose, context: context, degradation: .none)
        }
        context.setAlpha(1)
        drawPose(text: text, pose: pose, context: context, degradation: degradation)
    }

    /// Per-pixel deterministic noise directly on the rendered `32BGRA`
    /// buffer, added after all drawing so it reads as sensor noise rather
    /// than being smoothed by antialiasing. Alpha is left untouched.
    private func applyNoise(base: UnsafeMutableRawPointer, bytesPerRow: Int, amount: CGFloat, frameIndex: Int) {
        let magnitude = Int32((min(max(amount, 0), 1) * 48).rounded())
        guard magnitude > 0 else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let width = Int(size.width), height = Int(size.height)
        let span = UInt32(2 * magnitude + 1)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let hash = Self.noiseHash(x: x, y: y, frameIndex: frameIndex)
                let delta = Int32(hash % span) - magnitude
                let pixel = row + x * 4
                pixel[0] = Self.clampedAdd(pixel[0], delta)
                pixel[1] = Self.clampedAdd(pixel[1], delta)
                pixel[2] = Self.clampedAdd(pixel[2], delta)
            }
        }
    }

    /// Cheap integer mix (splitmix-style avalanche) — deterministic and
    /// collision-resistant enough for visual noise; never a random source, so
    /// the same (x, y, frameIndex) always yields the same byte.
    private static func noiseHash(x: Int, y: Int, frameIndex: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ frameIndex &* 2_246_822_519)
        h ^= h >> 15
        h = h &* 2_654_435_761
        h ^= h >> 13
        return h
    }

    private static func clampedAdd(_ value: UInt8, _ delta: Int32) -> UInt8 {
        UInt8(clamping: Int32(value) + delta)
    }

    /// Panel + centered digits, exactly as the original single-path renderer
    /// drew them, plus `degradation`'s occlusion/brightness (both no-ops at
    /// their default values, so the identity/no-degradation path stays
    /// byte-identical). `panelRect` is in the context's *current* coordinate
    /// space, so the transformed path above reuses this unchanged.
    private func drawPanel(text: String, in panelRect: CGRect, context: CGContext,
                           degradation: RenderDegradation = .none) {
        context.setFillColor(Self.panelColor)
        context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()

        UIGraphicsPushContext(context)
        let fontSize = panelRect.height * 0.62
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor(red: 0x14 / 255, green: 0x1A / 255, blue: 0x12 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ])
        let textSize = attributed.size()
        let textRect = CGRect(x: panelRect.minX,
                              y: panelRect.midY - textSize.height / 2,
                              width: panelRect.width,
                              height: textSize.height)
        attributed.draw(in: textRect)
        UIGraphicsPopContext()

        // Both no-ops at their default values (brightness 1, occlusion 0),
        // so the undegraded path draws nothing extra here.
        if degradation.brightness != 1 {
            let clampedBrightness = max(0, degradation.brightness)
            context.saveGState()
            context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
            context.clip()
            if clampedBrightness < 1 {
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1 - clampedBrightness))
                context.fill(panelRect)
            } else {
                // `.screen` blend approximates lifting luminance without the
                // panel ever inverting to solid white.
                context.setBlendMode(.screen)
                let liftAlpha = min(1, (clampedBrightness - 1) / 1.5)
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: liftAlpha))
                context.fill(panelRect)
            }
            context.restoreGState()
        }
        if degradation.occlusion > 0 {
            // A bar growing from the bottom edge — deterministic placement,
            // simulating a hand/probe over part of the display.
            let fraction = min(max(degradation.occlusion, 0), 1)
            let barRect = CGRect(x: panelRect.minX, y: panelRect.maxY - panelRect.height * fraction,
                                 width: panelRect.width, height: panelRect.height * fraction)
            context.setFillColor(Self.occlusionColor)
            context.fill(barRect)
        }
    }

    /// Ground-truth normalized bounding box of the panel as drawn for `pose` —
    /// what tracking tests compare the ROI window against. Mirrors the render
    /// transform: half-extents scaled by the foreshortening/scale factors,
    /// then the axis-aligned bounds of the rolled rect, clamped to the frame.
    func panelROI(for pose: DisplayPose) -> NormalizedROI {
        guard pose != .identity else { return Self.displayROI }
        let base = Self.displayROI.pixelRect(in: size)
        let combinedScale = max(pose.scale, 0.05)
        let halfWidth = base.width / 2 * max(pose.yawScale, 0.05) * combinedScale
        let halfHeight = base.height / 2 * max(pose.pitchScale, 0.05) * combinedScale
        let cosR = abs(cos(pose.roll))
        let sinR = abs(sin(pose.roll))
        let boundsHalfWidth = halfWidth * cosR + halfHeight * sinR
        let boundsHalfHeight = halfWidth * sinR + halfHeight * cosR
        let center = CGPoint(x: pose.center.x * size.width, y: pose.center.y * size.height)
        return NormalizedROI(x: (center.x - boundsHalfWidth) / size.width,
                             y: (center.y - boundsHalfHeight) / size.height,
                             width: boundsHalfWidth * 2 / size.width,
                             height: boundsHalfHeight * 2 / size.height).clamped()
    }

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let backgroundColor = CGColor(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255, alpha: 1)
    private static let panelColor = CGColor(red: 0xC9 / 255, green: 0xD6 / 255, blue: 0xC2 / 255, alpha: 1)
    private static let occlusionColor = CGColor(red: 0x2B / 255, green: 0x2B / 255, blue: 0x2B / 255, alpha: 1)
}

/// Programmatically-rendered DMM frames for the Simulator (no camera
/// hardware) and for pipeline tests (spec §40.3). Never a stand-in for
/// real-DMM accuracy — see `SyntheticDisplayRenderer` doc comment.
///
/// The value drifts slowly (`12.3 + 0.35·sin(0.4t)`) so the capture UI,
/// validators, and temporal filter all have something changing to react to.
final class SyntheticFrameSource: FrameSource {
    /// Forwards `SyntheticDisplayRenderer.displayROI` for convenience.
    static let displayROI = SyntheticDisplayRenderer.displayROI

    private let renderer: SyntheticDisplayRenderer
    private let frameInterval: TimeInterval
    /// Motion pattern, switchable live from the UI while the frame loop reads
    /// it once per frame. `OSAllocatedUnfairLock` because writes come from
    /// the MainActor and reads from the frame task.
    private let motionState: OSAllocatedUnfairLock<DemoMotion>
    /// Explicit degradation override, switchable live the same way as
    /// `motionState`. `.none` (the default) means "no explicit override" —
    /// `.stress` mode then supplies its own moderate default (see
    /// `stressDegradation(frameIndex:)`) so one tap gives a hard scenario
    /// without the caller wiring up degradation manually. Setting anything
    /// non-`.none` here takes precedence over that automatic default.
    private let degradationState: OSAllocatedUnfairLock<RenderDegradation>

    init(fps: Double = 12,
         size: CGSize = CGSize(width: 1080, height: 1920),
         motion: DemoMotion = .steady,
         degradation: RenderDegradation = .none) {
        self.renderer = SyntheticDisplayRenderer(size: size)
        self.frameInterval = 1.0 / fps
        self.motionState = OSAllocatedUnfairLock(initialState: motion)
        self.degradationState = OSAllocatedUnfairLock(initialState: degradation)
    }

    /// Thread-safe live switch; takes effect on the next rendered frame.
    /// Bounce position and velocity persist across switches (the panel glides
    /// home rather than teleporting when leaving bounce).
    func setMotion(_ motion: DemoMotion) {
        motionState.withLock { $0 = motion }
    }

    var motion: DemoMotion {
        motionState.withLock { $0 }
    }

    /// Thread-safe live switch, mirroring `setMotion(_:)`; takes effect on
    /// the next rendered frame. Pass `.none` to clear an explicit override
    /// and fall back to `.stress`'s automatic default (if active).
    func setDegradation(_ degradation: RenderDegradation) {
        degradationState.withLock { $0 = degradation }
    }

    var degradation: RenderDegradation {
        degradationState.withLock { $0 }
    }

    /// `.stress`'s automatic default when no explicit override is set:
    /// moderate blur + noise throughout, plus a brief opaque occlusion every
    /// few seconds — a stand-in for a hand/probe crossing the display.
    /// Purely a function of `frameIndex`, so it replays identically.
    private static func stressDegradation(frameIndex: Int) -> RenderDegradation {
        let cyclePosition = frameIndex % 36 // 3s at the default 12fps
        let occlusion: CGFloat = cyclePosition < 6 ? 0.22 : 0
        return RenderDegradation(occlusion: occlusion, blurRadius: 6, noiseAmount: 0.05, brightness: 1)
    }

    func frames() -> AsyncStream<TimestampedFrame> {
        let renderer = self.renderer
        let frameInterval = self.frameInterval
        // Lock handles are value-typed views of shared state — copying one
        // into the task avoids capturing (and retaining) `self`.
        let motionState = self.motionState
        let degradationState = self.degradationState
        return AsyncStream { continuation in
            let task = Task {
                // Monotonic pacing clock — never wall-clock `Date`, so
                // timestamps stay correct regardless of system clock changes.
                let clock = ContinuousClock()
                let start = clock.now
                var frameIndex = 0
                var motionModel = DemoMotionModel()
                while !Task.isCancelled {
                    let elapsed = Double(frameIndex) * frameInterval
                    let value = 12.3 + 0.35 * sin(0.4 * elapsed)
                    let text = String(format: "%.3f", value)
                    let mode = motionState.withLock { $0 }
                    motionModel.mode = mode
                    let pose = motionModel.pose(at: elapsed, dt: frameInterval)
                    let explicitDegradation = degradationState.withLock { $0 }
                    let degradation = (mode == .stress && explicitDegradation == .none)
                        ? Self.stressDegradation(frameIndex: frameIndex)
                        : explicitDegradation
                    if let buffer = renderer.render(text: text, pose: pose,
                                                    degradation: degradation, frameIndex: frameIndex) {
                        continuation.yield(TimestampedFrame(pixelBuffer: buffer, timestamp: elapsed))
                    }
                    frameIndex += 1
                    let nextElapsed = Double(frameIndex) * frameInterval
                    do {
                        try await clock.sleep(until: start.advanced(by: .seconds(nextElapsed)))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
