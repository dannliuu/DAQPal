//
//  SyntheticFrameSource.swift
//  DAQPal
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation
import os
import UIKit

/// A specular highlight on the panel: the bright blob a light source reflects
/// off an LCD's cover glass, which destroys segment contrast locally while
/// leaving the rest of the display perfectly readable.
///
/// `center` is in unit panel coordinates with a top-left origin, matching
/// `NormalizedROI`, so the spot rides the panel through both the affine and
/// the perspective warp. `radius` is a fraction of the panel's WIDTH so the
/// spot stays round in panel pixels on a wide, short LCD.
struct PanelGlare: Equatable, Sendable {
    var center = CGPoint(x: 0.5, y: 0.5)
    /// 0 disables the highlight, as does a zero `intensity`.
    var radius: CGFloat = 0
    /// Additive luminance at the core (0...1).
    var intensity: CGFloat = 0
    /// Unit-panel movement per frame. A hand-held instrument's glare sweeps
    /// across the display as the operator's wrist turns, and a highlight that
    /// parks over one digit forever is a much easier case than one that
    /// crosses them in turn.
    var drift = CGVector.zero

    static let none = PanelGlare()

    var isActive: Bool { radius > 0 && intensity > 0 }

    /// Pure function of `frameIndex` — no clock, no random source — so any
    /// frame of a drifting sequence replays from its index alone.
    func center(atFrame frameIndex: Int) -> CGPoint {
        let f = CGFloat(frameIndex)
        return CGPoint(x: Self.folded(center.x + drift.dx * f),
                       y: Self.folded(center.y + drift.dy * f))
    }

    /// Triangle wave folding the real line into 0...1. A modulo wrap would
    /// teleport the highlight across the panel between two adjacent frames,
    /// which no physical reflection does and which would make a temporal
    /// filter's job artificially easy at the seam.
    private static func folded(_ v: CGFloat) -> CGFloat {
        let t = v.truncatingRemainder(dividingBy: 2)
        let u = t < 0 ? t + 2 : t
        return u <= 1 ? u : 2 - u
    }
}

/// Uneven illumination across the panel — a failing edge-lit backlight, or a
/// room light falling off across the display.
struct IlluminationGradient: Equatable, Sendable {
    enum Shape: Sendable {
        /// Ramp along `direction`: uneven backlight, one edge hot.
        case linear
        /// Ramp outward from the panel centre: bright-centre / dark-edge.
        case radial
    }

    var shape: Shape = .linear
    /// Radians in the panel's top-left-origin space, pointing at the BRIGHT
    /// end. Ignored for `.radial`, whose bright end is the centre.
    var direction: CGFloat = 0
    /// Signed peak luminance swing at each end of the ramp (0...1). Negative
    /// swaps the bright and dark ends, which is how a dark-centre panel or a
    /// hot trailing edge is expressed without a second field.
    var strength: CGFloat = 0

    static let none = IlluminationGradient()

    var isActive: Bool { strength != 0 }
}

/// Opt-in, deterministic rendering degradation layered on top of a
/// `DisplayPose` — simulates real-optics effects (`SyntheticDisplayRenderer`'s
/// pose transform simulates only geometry). All fields default to "off" so
/// `render(text:pose:)` and any pre-existing call keeps producing exactly the
/// original frames. Every effect is a pure function of its inputs — never
/// `Double.random`/`arc4random` — so tests replay identical frames.
///
/// Two families live here. Panel-surface knobs (occlusion, brightness, glare,
/// illumination) are drawn INTO the panel and therefore ride the pose warp;
/// sensor knobs (contrast, gamma, white balance, noise, impulse noise,
/// defocus) act on the finished frame the way a camera does.
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

    // Fields below are declared after the original four so every existing
    // memberwise call site keeps compiling unchanged.

    /// Contrast about mid-grey, `v' = (v - 0.5)·contrast + 0.5`. <1 flattens
    /// toward mid-grey (the washed-out capture of a display shot against a
    /// bright window); >1 expands and eventually clips both ends.
    var contrast: CGFloat = 1
    /// Power-law transfer, `v' = v^gamma`, applied after `contrast`. >1
    /// darkens midtones, <1 lifts them — the axis along which a camera's
    /// tone curve pushes a light LCD toward or away from its ink.
    var gamma: CGFloat = 1
    var glare: PanelGlare = .none
    var illuminationGradient: IlluminationGradient = .none
    /// White-balance error (-1...1): negative pushes blue (open shade),
    /// positive pushes amber (tungsten). ±1 is a 1.5×/0.5× red-blue split.
    var colorTemperature: CGFloat = 0
    /// Impulse ("salt and pepper") noise: the fraction of pixels forced to
    /// full black or full white. Deliberately distinct from `noiseAmount`'s
    /// zero-mean jitter — impulse noise survives temporal averaging and lands
    /// squarely on a thresholding segment sampler.
    var saltPepperAmount: CGFloat = 0
    /// Symmetric out-of-focus blur in pixels. Distinct from `blurRadius`,
    /// which smears along one fixed diagonal: a defocused lens spreads a
    /// point in every direction, so it costs edge contrast without leaving
    /// the direction cue a deblurring step could exploit.
    var defocusRadius: CGFloat = 0

    /// No degradation — the default for every existing call site.
    static let none = RenderDegradation()

    /// Whether the post-draw per-pixel pass has anything to do. `false` for
    /// every default-valued knob, which is what keeps `render(text:pose:)`
    /// byte-identical to the pre-degradation renderer.
    var hasPixelEffects: Bool {
        noiseAmount > 0 || saltPepperAmount > 0 || contrast != 1 || gamma != 1 || colorTemperature != 0
    }

    /// The knobs applied while DRAWING the panel. The perspective path bakes
    /// only these into its flat panel — the sensor knobs are applied once on
    /// the warped output instead, where a real camera would apply them.
    var panelSurfaceOnly: RenderDegradation {
        var stripped = self
        stripped.blurRadius = 0
        stripped.noiseAmount = 0
        stripped.saltPepperAmount = 0
        stripped.contrast = 1
        stripped.gamma = 1
        stripped.colorTemperature = 0
        stripped.defocusRadius = 0
        return stripped
    }
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
    ///
    /// A non-nil `secondary` stacks a second, smaller reading below `text` on
    /// the same panel — see `drawStackedReadings(primary:secondary:in:)`.
    func render(text: String, secondary: String? = nil,
                pose: DisplayPose = .identity) -> CVPixelBuffer? {
        render(text: text, secondary: secondary, pose: pose, degradation: .none)
    }

    /// `render(text:pose:)` plus opt-in, deterministic optics degradation.
    /// `frameIndex` seeds the noise hash only — pass the actual frame index
    /// so noise varies frame-to-frame; a fixed index still replays exactly.
    func render(text: String, secondary: String? = nil, pose: DisplayPose = .identity,
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
            drawPose(text: text, secondary: secondary, pose: pose, context: context,
                     degradation: degradation, frameIndex: frameIndex)
        } else {
            drawMotionBlurred(text: text, secondary: secondary, pose: pose, context: context,
                              degradation: degradation, frameIndex: frameIndex)
        }

        // Optics before sensor: defocus spreads what the lens saw, then the
        // transfer curve and noise act on what the sensor read.
        if degradation.defocusRadius > 0 {
            applyDefocus(base: base, bytesPerRow: bytesPerRow, radius: degradation.defocusRadius)
        }
        if degradation.hasPixelEffects {
            applyPixelEffects(base: base, bytesPerRow: bytesPerRow,
                              degradation: degradation, frameIndex: frameIndex)
        }

        return buffer
    }

    /// One sharp draw of the panel at `pose`, with `degradation`'s
    /// non-blur effects (occlusion/brightness) applied. `pose == .identity`
    /// skips the translate/rotate/scale round-trip entirely — the path
    /// existing tests and fixtures diff pixels against.
    private func drawPose(text: String, secondary: String? = nil, pose: DisplayPose, context: CGContext,
                          degradation: RenderDegradation, frameIndex: Int = 0) {
        if pose == .identity {
            drawPanel(text: text, secondary: secondary, in: Self.displayROI.pixelRect(in: size),
                      context: context, degradation: degradation, frameIndex: frameIndex)
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
            drawPanel(text: text, secondary: secondary, in: rect, context: context,
                      degradation: degradation, frameIndex: frameIndex)
            context.restoreGState()
        }
    }

    /// Motion blur: `blurSampleCount - 1` faded "ghost" copies of the panel
    /// offset along a fixed diagonal direction (a `DisplayPose` carries no
    /// velocity to blur along the *true* motion direction — an honest
    /// approximation, matching this renderer's affine-only stance elsewhere),
    /// plus one sharp copy at the true position/alpha on top.
    private func drawMotionBlurred(text: String, secondary: String? = nil, pose: DisplayPose, context: CGContext,
                                   degradation: RenderDegradation, frameIndex: Int = 0) {
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
            drawPose(text: text, secondary: secondary, pose: ghostPose, context: context, degradation: .none)
        }
        context.setAlpha(1)
        drawPose(text: text, secondary: secondary, pose: pose, context: context,
                 degradation: degradation, frameIndex: frameIndex)
    }

    /// Every sensor-side effect in ONE pass over the rendered `32BGRA` buffer:
    /// transfer curve (contrast → gamma → white balance) as a per-channel
    /// 256-entry table, then Gaussian-ish jitter, then impulse noise on top.
    /// Applied after all drawing so the noise reads as sensor noise rather
    /// than being smoothed by antialiasing. Alpha is left untouched.
    ///
    /// One fused pass rather than one per knob: a 1080×1920 frame is 2 Mpx and
    /// a validation sweep renders thousands of them. Each knob still costs
    /// nothing when off — the table is built only when a transfer knob moved,
    /// and the whole pass is skipped when `hasPixelEffects` is false, which is
    /// what keeps the undegraded render byte-identical.
    private func applyPixelEffects(base: UnsafeMutableRawPointer, bytesPerRow: Int,
                                   degradation: RenderDegradation, frameIndex: Int) {
        let tables = Self.transferTables(contrast: degradation.contrast,
                                         gamma: degradation.gamma,
                                         colorTemperature: degradation.colorTemperature)
        let (lutB, lutG, lutR) = tables ?? ([], [], [])
        let hasTransfer = tables != nil
        let magnitude = Int32((min(max(degradation.noiseAmount, 0), 1) * 48).rounded())
        let span = UInt32(2 * magnitude + 1)
        // Impulse rate is quantized to 1/10 000 so the decision is an integer
        // compare against a hash bucket rather than a float multiply per pixel.
        let impulseRate = UInt32((min(max(degradation.saltPepperAmount, 0), 1) * 10_000).rounded())
        guard hasTransfer || magnitude > 0 || impulseRate > 0 else { return }

        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let width = Int(size.width), height = Int(size.height)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let pixel = row + x * 4
                if hasTransfer {
                    pixel[0] = lutB[Int(pixel[0])]
                    pixel[1] = lutG[Int(pixel[1])]
                    pixel[2] = lutR[Int(pixel[2])]
                }
                if magnitude > 0 {
                    let hash = Self.noiseHash(x: x, y: y, frameIndex: frameIndex)
                    let delta = Int32(hash % span) - magnitude
                    pixel[0] = Self.clampedAdd(pixel[0], delta)
                    pixel[1] = Self.clampedAdd(pixel[1], delta)
                    pixel[2] = Self.clampedAdd(pixel[2], delta)
                }
                if impulseRate > 0 {
                    let hash = Self.impulseHash(x: x, y: y, frameIndex: frameIndex)
                    if hash % 10_000 < impulseRate {
                        // Impulse noise REPLACES the sample rather than adding
                        // to it — that is what makes it survive averaging.
                        // Bit 24 is far enough from the low-order bits the rate
                        // compare consumes to split salt from pepper evenly.
                        let level: UInt8 = (hash >> 24) & 1 == 0 ? 0 : 255
                        pixel[0] = level
                        pixel[1] = level
                        pixel[2] = level
                    }
                }
            }
        }
    }

    /// Per-channel byte tables for contrast → gamma → white balance, or `nil`
    /// when all three are at their defaults so the caller can skip the lookup
    /// entirely. Channel order matches the buffer's B, G, R byte order.
    private static func transferTables(contrast: CGFloat, gamma: CGFloat,
                                       colorTemperature: CGFloat) -> ([UInt8], [UInt8], [UInt8])? {
        guard contrast != 1 || gamma != 1 || colorTemperature != 0 else { return nil }
        let contrast = max(contrast, 0)
        // A zero or negative exponent is not a tone curve; clamp rather than
        // hand `pow` an input it answers with infinity.
        let gamma = max(gamma, 0.01)
        let temperature = min(max(colorTemperature, -1), 1)
        // ±1 lands on a 1.5×/0.5× red-blue split: severe enough that a
        // luminance-only recognizer notices, short of a fully monochrome cast.
        let redGain = 1 + temperature * 0.5
        let blueGain = 1 - temperature * 0.5
        var blue = [UInt8](repeating: 0, count: 256)
        var green = [UInt8](repeating: 0, count: 256)
        var red = [UInt8](repeating: 0, count: 256)
        for v in 0..<256 {
            let value = CGFloat(v) / 255
            let curved = pow(max((value - 0.5) * contrast + 0.5, 0), gamma)
            blue[v] = UInt8(clamping: Int((curved * blueGain * 255).rounded()))
            green[v] = UInt8(clamping: Int((curved * 255).rounded()))
            red[v] = UInt8(clamping: Int((curved * redGain * 255).rounded()))
        }
        return (blue, green, red)
    }

    /// Deterministic separable box blur over the whole frame, run twice so the
    /// effective point spread is a triangle rather than a square — one box
    /// pass leaves axis-aligned corners no lens produces. Written in Swift
    /// rather than through CoreImage because this render path promises
    /// byte-determinism and CoreImage's resampling does not.
    private func applyDefocus(base: UnsafeMutableRawPointer, bytesPerRow: Int, radius: CGFloat) {
        // 64 px on the long edge is already a completely unreadable panel;
        // beyond that the cost is real and the frame carries no signal.
        let r = Int(min(max(radius, 0), 64).rounded())
        guard r > 0 else { return }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let width = Int(size.width), height = Int(size.height)
        guard width > 1, height > 1 else { return }
        var scratch = [UInt8](repeating: 0, count: max(width, height) * 3)
        for _ in 0..<2 {
            blurRows(ptr, bytesPerRow: bytesPerRow, width: width, height: height, radius: r, scratch: &scratch)
            blurColumns(ptr, bytesPerRow: bytesPerRow, width: width, height: height, radius: r, scratch: &scratch)
        }
    }

    /// One horizontal box pass with a sliding sum, edges clamped. `scratch`
    /// holds the row's original B/G/R so the running sum reads pre-blur
    /// samples while the row is being overwritten in place.
    private func blurRows(_ ptr: UnsafeMutablePointer<UInt8>, bytesPerRow: Int,
                          width: Int, height: Int, radius: Int, scratch: inout [UInt8]) {
        let window = Int32(2 * radius + 1)
        let half = window / 2
        scratch.withUnsafeMutableBufferPointer { src in
            for y in 0..<height {
                let row = ptr + y * bytesPerRow
                for x in 0..<width {
                    src[x * 3] = row[x * 4]
                    src[x * 3 + 1] = row[x * 4 + 1]
                    src[x * 3 + 2] = row[x * 4 + 2]
                }
                var sum = (Int32(0), Int32(0), Int32(0))
                for i in -radius...radius {
                    let xi = min(max(i, 0), width - 1) * 3
                    sum.0 += Int32(src[xi])
                    sum.1 += Int32(src[xi + 1])
                    sum.2 += Int32(src[xi + 2])
                }
                for x in 0..<width {
                    row[x * 4] = UInt8((sum.0 + half) / window)
                    row[x * 4 + 1] = UInt8((sum.1 + half) / window)
                    row[x * 4 + 2] = UInt8((sum.2 + half) / window)
                    let out = min(max(x - radius, 0), width - 1) * 3
                    let into = min(max(x + radius + 1, 0), width - 1) * 3
                    sum.0 += Int32(src[into]) - Int32(src[out])
                    sum.1 += Int32(src[into + 1]) - Int32(src[out + 1])
                    sum.2 += Int32(src[into + 2]) - Int32(src[out + 2])
                }
            }
        }
    }

    /// The vertical twin of `blurRows`. Column-major access is cache-hostile,
    /// but the alternative is a full transposed copy of the frame, which costs
    /// more memory than the passes save.
    private func blurColumns(_ ptr: UnsafeMutablePointer<UInt8>, bytesPerRow: Int,
                             width: Int, height: Int, radius: Int, scratch: inout [UInt8]) {
        let window = Int32(2 * radius + 1)
        let half = window / 2
        scratch.withUnsafeMutableBufferPointer { src in
            for x in 0..<width {
                for y in 0..<height {
                    let pixel = ptr + y * bytesPerRow + x * 4
                    src[y * 3] = pixel[0]
                    src[y * 3 + 1] = pixel[1]
                    src[y * 3 + 2] = pixel[2]
                }
                var sum = (Int32(0), Int32(0), Int32(0))
                for i in -radius...radius {
                    let yi = min(max(i, 0), height - 1) * 3
                    sum.0 += Int32(src[yi])
                    sum.1 += Int32(src[yi + 1])
                    sum.2 += Int32(src[yi + 2])
                }
                for y in 0..<height {
                    let pixel = ptr + y * bytesPerRow + x * 4
                    pixel[0] = UInt8((sum.0 + half) / window)
                    pixel[1] = UInt8((sum.1 + half) / window)
                    pixel[2] = UInt8((sum.2 + half) / window)
                    let out = min(max(y - radius, 0), height - 1) * 3
                    let into = min(max(y + radius + 1, 0), height - 1) * 3
                    sum.0 += Int32(src[into]) - Int32(src[out])
                    sum.1 += Int32(src[into + 1]) - Int32(src[out + 1])
                    sum.2 += Int32(src[into + 2]) - Int32(src[out + 2])
                }
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

    /// A second, independent stream for impulse noise. Different multipliers
    /// and shift distances keep the impulse mask uncorrelated with
    /// `noiseHash`, so raising both knobs together does not preferentially
    /// drop salt onto pixels the Gaussian draw already brightened.
    private static func impulseHash(x: Int, y: Int, frameIndex: Int) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x &* 2_654_435_761 &+ y &* 40_503 &+ frameIndex &* 1_597_334_677)
        h ^= h >> 16
        h = h &* 2_246_822_519
        h ^= h >> 11
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
    private func drawPanel(text: String, secondary: String? = nil, in panelRect: CGRect, context: CGContext,
                           degradation: RenderDegradation = .none, frameIndex: Int = 0) {
        context.setFillColor(Self.panelColor)
        context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()

        UIGraphicsPushContext(context)
        if let secondary {
            drawStackedReadings(primary: text, secondary: secondary, in: panelRect)
        } else {
            let fontSize = panelRect.height * 0.62
            let attributed = Self.reading(text, fontSize: fontSize)
            let textSize = attributed.size()
            let textRect = CGRect(x: panelRect.minX,
                                  y: panelRect.midY - textSize.height / 2,
                                  width: panelRect.width,
                                  height: textSize.height)
            attributed.draw(in: textRect)
        }
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
        if degradation.illuminationGradient.isActive {
            drawIllumination(degradation.illuminationGradient, in: panelRect, context: context)
        }
        if degradation.glare.isActive {
            drawGlare(degradation.glare, frameIndex: frameIndex, in: panelRect, context: context)
        }
        if degradation.occlusion > 0 {
            // A bar growing from the bottom edge — deterministic placement,
            // simulating a hand/probe over part of the display. Drawn last
            // because a hand blocks the reflection it would otherwise sit
            // under, not the other way round.
            let fraction = min(max(degradation.occlusion, 0), 1)
            let barRect = CGRect(x: panelRect.minX, y: panelRect.maxY - panelRect.height * fraction,
                                 width: panelRect.width, height: panelRect.height * fraction)
            context.setFillColor(Self.occlusionColor)
            context.fill(barRect)
        }
    }

    /// Uneven illumination as ONE ramp clipped to the panel: a pure white lift
    /// fading to nothing over the first half, a pure black crush growing from
    /// nothing over the second. Two draws (one lift, one crush) would double
    /// the fill cost for the same result.
    ///
    /// The colour switches at a DUPLICATED midpoint location rather than
    /// interpolating through it. CGGradient interpolates colour and alpha
    /// independently, so a single white→grey→black ramp washes its own ends
    /// out — measured at strength 0.5, it recovered only 0.27 of luminance
    /// swing across the panel where the hard switch recovers 0.35. Alpha still
    /// reaches zero at the seam, so nothing is visible there.
    private func drawIllumination(_ gradient: IlluminationGradient, in panelRect: CGRect,
                                  context: CGContext) {
        let strength = min(abs(gradient.strength), 1)
        guard strength > 0 else { return }
        let lift = CGColor(red: 1, green: 1, blue: 1, alpha: strength)
        let liftEnd = CGColor(red: 1, green: 1, blue: 1, alpha: 0)
        let crushStart = CGColor(red: 0, green: 0, blue: 0, alpha: 0)
        let crush = CGColor(red: 0, green: 0, blue: 0, alpha: strength)
        let stops = gradient.strength >= 0
            ? [lift, liftEnd, crushStart, crush]
            : [crush, crushStart, liftEnd, lift]
        guard let ramp = CGGradient(colorsSpace: Self.colorSpace, colors: stops as CFArray,
                                    locations: [0, 0.5, 0.5, 1]) else { return }
        let center = CGPoint(x: panelRect.midX, y: panelRect.midY)
        context.saveGState()
        context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.clip()
        switch gradient.shape {
        case .linear:
            // The ramp spans the panel's own half-extents along `direction`,
            // so the full swing is visible whatever the panel's aspect ratio.
            let half = CGPoint(x: cos(gradient.direction) * panelRect.width / 2,
                               y: sin(gradient.direction) * panelRect.height / 2)
            context.drawLinearGradient(ramp,
                                       start: CGPoint(x: center.x + half.x, y: center.y + half.y),
                                       end: CGPoint(x: center.x - half.x, y: center.y - half.y),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        case .radial:
            context.drawRadialGradient(ramp, startCenter: center, startRadius: 0,
                                       endCenter: center,
                                       endRadius: hypot(panelRect.width, panelRect.height) / 2,
                                       options: [.drawsAfterEndLocation])
        }
        context.restoreGState()
    }

    /// Additive specular highlight, clipped to the panel so the reflection
    /// cannot spill onto the instrument body. The falloff carries a hot core
    /// (full intensity to a quarter of it by mid-radius) and a long shoulder:
    /// a linear ramp reads as a soft blob that a threshold sails through,
    /// where a real highlight saturates its centre outright.
    private func drawGlare(_ glare: PanelGlare, frameIndex: Int, in panelRect: CGRect,
                           context: CGContext) {
        let intensity = min(max(glare.intensity, 0), 1)
        let radius = max(glare.radius, 0) * panelRect.width
        guard intensity > 0, radius > 0 else { return }
        let unit = glare.center(atFrame: frameIndex)
        let center = CGPoint(x: panelRect.minX + unit.x * panelRect.width,
                             y: panelRect.minY + unit.y * panelRect.height)
        let stops = [CGColor(red: 1, green: 1, blue: 1, alpha: intensity),
                     CGColor(red: 1, green: 1, blue: 1, alpha: intensity * 0.25),
                     CGColor(red: 1, green: 1, blue: 1, alpha: 0)]
        guard let ramp = CGGradient(colorsSpace: Self.colorSpace, colors: stops as CFArray,
                                    locations: [0, 0.5, 1]) else { return }
        context.saveGState()
        context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.clip()
        context.setBlendMode(.plusLighter)
        context.drawRadialGradient(ramp, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
        context.restoreGState()
    }

    /// Two readings stacked on one panel, after the handheld IR thermometer
    /// this project targets: a large current reading with a smaller held/max
    /// one below it (`Fixtures/ir_gun_display.png` shows `90.0` over a smaller
    /// `92.7`). This is the only synthetic content containing more than one
    /// number, so it is what makes window sub-field selection reachable
    /// without the physical instrument.
    ///
    /// The layout is driven by the panel's own height rather than by font
    /// metrics so the vertical gap between the two readings survives any font
    /// substitution: a `NumberBandSplitter` row projection must find a run of
    /// clean background between them, or the two readings come back as one
    /// band and the feature has nothing to split.
    private func drawStackedReadings(primary: String, secondary: String, in panelRect: CGRect) {
        let primaryText = Self.reading(primary, fontSize: panelRect.height * Self.stackedPrimaryFontFraction)
        let secondaryText = Self.reading(secondary,
                                         fontSize: panelRect.height * Self.stackedPrimaryFontFraction
                                             * Self.stackedSecondaryFontFraction)
        let primarySize = primaryText.size()
        let secondarySize = secondaryText.size()
        let gap = panelRect.height * Self.stackedGapFraction
        // Centering the whole block keeps the panel's ground-truth ROI
        // (`panelROI(for:)`) an honest bound on the drawn content, exactly as
        // in the single-reading case.
        let top = panelRect.midY - (primarySize.height + gap + secondarySize.height) / 2
        primaryText.draw(in: CGRect(x: panelRect.minX, y: top,
                                    width: panelRect.width, height: primarySize.height))
        secondaryText.draw(in: CGRect(x: panelRect.minX, y: top + primarySize.height + gap,
                                      width: panelRect.width, height: secondarySize.height))
    }

    /// Centered digits in the panel's ink colour — the single-reading path's
    /// original attributes, shared so both layouts render the same glyphs.
    private static func reading(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor(red: 0x14 / 255, green: 0x1A / 255, blue: 0x12 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ])
    }

    /// Stacked-layout geometry. The primary is smaller than the single-reading
    /// 0.62 because it now shares the panel. The secondary's 0.58 is chosen to
    /// be unmistakably smaller — `NumberBandSplitter` ranks on glyph height, so
    /// a near-equal secondary would make the ordering a coin toss — while
    /// staying large enough to read as a reading rather than a legend.
    private static let stackedPrimaryFontFraction: CGFloat = 0.44
    private static let stackedSecondaryFontFraction: CGFloat = 0.58
    /// Background between the two line boxes. Line boxes already carry
    /// descender/ascender leading, so the gap of clean pixels between the
    /// GLYPHS is materially larger than this.
    private static let stackedGapFraction: CGFloat = 0.09

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

// MARK: - True-perspective render path (DisplayPose3D)

extension SyntheticDisplayRenderer {
    /// Shared CoreImage context for the perspective path — created exactly
    /// once for the process; `CIContext` is documented thread-safe for
    /// concurrent use.
    private static let perspectiveContext = CIContext()

    /// Renders the panel under a TRUE 3-D pose: the flat panel content is
    /// drawn once at identity (the exact same panel drawing as the affine
    /// path, supersampled 2×), warped to `pose3D.projectedQuad(...)` with
    /// `CIPerspectiveTransform`, and composited over the same dark instrument
    /// body. Output is a 32BGRA `CVPixelBuffer` at the renderer's size, like
    /// the affine path.
    ///
    /// Contract: GEOMETRY accuracy — the rendered panel's corners land on
    /// `projectedQuad`'s corners (unit-tested to ~3 px), and the same inputs
    /// always produce the same geometry. Byte-determinism is NOT promised
    /// (CoreImage's resampling may vary across OS versions); never pixel-diff
    /// this path.
    ///
    /// Degradation semantics: the panel-surface knobs (occlusion, brightness,
    /// glare, illumination) are applied to the FLAT panel so they ride it
    /// through the warp — an occluding bar and a specular highlight both
    /// keystone with the display, which is the honest reading of "a hand over
    /// the panel" and "a reflection on its cover glass". Motion-blur ghosts
    /// are composited post-warp along the same fixed diagonal as the affine
    /// path with the sharp copy on top at the true position; defocus, the
    /// transfer curve and both noise streams run on the output buffer through
    /// the identical deterministic (x, y, frameIndex) code the affine path
    /// uses.
    func render(text: String, secondary: String? = nil, pose3D: DisplayPose3D,
                degradation: RenderDegradation = .none, frameIndex: Int = 0) -> CVPixelBuffer? {
        let frameAspect = size.width / size.height
        let quad = pose3D.projectedQuad(panelSize: CGSize(width: Self.displayROI.width,
                                                          height: Self.displayROI.height),
                                        frameAspect: frameAspect)
        guard let flatPanel = flatPanelImage(text: text, secondary: secondary,
                                             degradation: degradation,
                                             frameIndex: frameIndex) else { return nil }

        // CIPerspectiveTransform maps the input image's extent corners to the
        // four given points; "topLeft" is the image's visual top-left, which
        // is exactly the quad's SEMANTIC topLeft since the flat panel is
        // drawn upright.
        let warp = CIFilter.perspectiveTransform()
        warp.inputImage = flatPanel
        warp.topLeft = ciPoint(quad.topLeft)
        warp.topRight = ciPoint(quad.topRight)
        warp.bottomRight = ciPoint(quad.bottomRight)
        warp.bottomLeft = ciPoint(quad.bottomLeft)
        guard var panel = warp.outputImage else { return nil }

        if degradation.blurRadius > 0 {
            panel = Self.motionBlurComposite(panel, radius: degradation.blurRadius)
        }

        let frameRect = CGRect(origin: .zero, size: size)
        let background = CIImage(color: CIColor(cgColor: Self.backgroundColor)).cropped(to: frameRect)
        let composed = panel.composited(over: background).cropped(to: frameRect)

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
        Self.perspectiveContext.render(composed, to: buffer, bounds: frameRect,
                                       colorSpace: Self.colorSpace)

        if degradation.defocusRadius > 0 || degradation.hasPixelEffects {
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
                if degradation.defocusRadius > 0 {
                    applyDefocus(base: base, bytesPerRow: bytesPerRow, radius: degradation.defocusRadius)
                }
                if degradation.hasPixelEffects {
                    applyPixelEffects(base: base, bytesPerRow: bytesPerRow,
                                      degradation: degradation, frameIndex: frameIndex)
                }
            }
        }
        return buffer
    }

    /// The flat (identity) panel content as a CIImage: same rect proportions,
    /// corner radius, font, and colors as the affine identity panel, drawn at
    /// 2× resolution so the perspective resample has headroom, on a
    /// TRANSPARENT background so only the rounded panel composites over the
    /// body. Sensor-side knobs are stripped here (`panelSurfaceOnly`) — they
    /// are applied post-warp, where a camera would apply them.
    private func flatPanelImage(text: String, secondary: String? = nil,
                                degradation: RenderDegradation, frameIndex: Int = 0) -> CIImage? {
        let panelRect = Self.displayROI.pixelRect(in: size)
        let supersample: CGFloat = 2
        let pixelWidth = Int((panelRect.width * supersample).rounded(.up))
        let pixelHeight = Int((panelRect.height * supersample).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(data: nil,
                                      width: pixelWidth,
                                      height: pixelHeight,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        // Same top-left/y-down flip as the main render path, then the 2×
        // supersample; drawing in 1×-sized coordinates keeps the corner
        // radius and font metrics identical to the affine panel.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: 1, y: -1)
        context.scaleBy(x: supersample, y: supersample)

        drawPanel(text: text, secondary: secondary,
                  in: CGRect(x: 0, y: 0, width: panelRect.width, height: panelRect.height),
                  context: context,
                  degradation: degradation.panelSurfaceOnly,
                  frameIndex: frameIndex)
        guard let cgImage = context.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Normalized top-left-origin point → CoreImage working coordinates
    /// (pixels, bottom-left origin).
    private func ciPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * size.width, y: size.height - p.y * size.height)
    }

    /// Post-warp motion-blur ghosts: the same fixed-diagonal, 5-sample,
    /// sharp-core-on-top recipe as the affine path's `drawMotionBlurred`,
    /// built by compositing alpha-scaled translated copies. The final sharp
    /// copy at zero offset preserves the geometry contract. The diagonal's y
    /// component is negated because CI space is y-up.
    private static func motionBlurComposite(_ image: CIImage, radius: CGFloat) -> CIImage {
        let direction = CGVector(dx: 0.7071, dy: -0.7071)
        let sampleCount = 5
        let ghostAlpha = 0.35 / CGFloat(sampleCount - 1)
        // Uniform scale of all four premultiplied channels = opacity scale.
        let fade: [String: Any] = [
            "inputRVector": CIVector(x: ghostAlpha, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: ghostAlpha, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: ghostAlpha, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: ghostAlpha)
        ]
        var stack: CIImage?
        for i in 0..<(sampleCount - 1) {
            let offsetFraction = CGFloat(i + 1) / CGFloat(sampleCount) - 0.5
            let offset = radius * offsetFraction
            let ghost = image
                .transformed(by: CGAffineTransform(translationX: direction.dx * offset,
                                                   y: direction.dy * offset))
                .applyingFilter("CIColorMatrix", parameters: fade)
            stack = stack.map { ghost.composited(over: $0) } ?? ghost
        }
        return stack.map { image.composited(over: $0) } ?? image
    }
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
    /// Stacks a second, smaller "MAX" reading under the drifting primary, so
    /// the Simulator can reach the window sub-field flow — which only engages
    /// when a placed window contains two or more numbers, and therefore cannot
    /// be exercised at all against the single-reading panel.
    private let dualReading: Bool

    /// DEBUG-only launch switch, resolved once: `ProcessInfo.arguments` is
    /// fixed for the life of the process, and the frame loop must not pay for
    /// an argument scan. Release builds never render the dual panel, matching
    /// the rest of the `-daqpal-…` demo hooks (see `DebugDemo`).
    static let dualReadingRequested: Bool = {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-daqpal-dual-reading")
#else
        false
#endif
    }()

    init(fps: Double = 12,
         size: CGSize = CGSize(width: 1080, height: 1920),
         motion: DemoMotion = .steady,
         degradation: RenderDegradation = .none,
         dualReading: Bool = SyntheticFrameSource.dualReadingRequested) {
        self.renderer = SyntheticDisplayRenderer(size: size)
        self.frameInterval = 1.0 / fps
        self.motionState = OSAllocatedUnfairLock(initialState: motion)
        self.degradationState = OSAllocatedUnfairLock(initialState: degradation)
        self.dualReading = dualReading
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
        let dualReading = self.dualReading
        // Newest-frame-wins: a stalled consumer sees the latest frame, not a
        // growing backlog of stale ones (the default policy is .unbounded,
        // which would buffer every rendered frame indefinitely).
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                // Monotonic pacing clock — never wall-clock `Date`, so
                // timestamps stay correct regardless of system clock changes.
                let clock = ContinuousClock()
                let start = clock.now
                var frameIndex = 0
                var motionModel = DemoMotionModel()
                // Peak-so-far, mirroring the target instrument's MAX display.
                // Seeded below the value curve's trough so the first frame sets it.
                var peakValue = -Double.greatestFiniteMagnitude
                while !Task.isCancelled {
                    let elapsed = Double(frameIndex) * frameInterval
                    let value = 12.3 + 0.35 * sin(0.4 * elapsed)
                    let text = String(format: "%.3f", value)
                    var secondary: String?
                    if dualReading {
                        peakValue = max(peakValue, value)
                        secondary = String(format: "%.3f", peakValue)
                    }
                    let mode = motionState.withLock { $0 }
                    motionModel.mode = mode
                    let pose = motionModel.pose(at: elapsed, dt: frameInterval)
                    let explicitDegradation = degradationState.withLock { $0 }
                    let degradation = (mode == .stress && explicitDegradation == .none)
                        ? Self.stressDegradation(frameIndex: frameIndex)
                        : explicitDegradation
                    if let buffer = renderer.render(text: text, secondary: secondary, pose: pose,
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
