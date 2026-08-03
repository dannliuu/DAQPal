//
//  DegradationRenderTests.swift
//  DAQPalTests
//
//  `RenderDegradation` carries the image-quality axes a validation sweep
//  varies. Two things have to hold for a sweep built on it to mean anything,
//  and neither is visible by eye:
//
//  1. Every knob is INERT at its default. Hundreds of existing tests and
//     fixtures diff pixels against the undegraded render, so a knob that
//     perturbs the frame by one least-significant bit when nobody asked for it
//     would silently rewrite the baseline.
//  2. Every knob moves the image in the direction its name claims, by a
//     measurable amount. A sweep over a knob that does nothing — or does the
//     opposite — reports accuracy numbers that are pure fiction.
//
//  So everything here is MEASURED off the rendered pixels: luminance mean and
//  standard deviation, per-channel means, edge energy, impulse fraction, and
//  the centroid of the glare's own contribution. Nothing is eyeballed, and
//  nothing is asserted about recognition accuracy — that claim belongs to the
//  benchmark suites, which consume these knobs.
//
//  Effect sizes on the 480×854 panel crop, so a sweep author knows what a
//  given setting is worth before spending frames on it:
//
//    contrast 0.35 / 1.6      luminance sd 0.227 -> 0.079 / 0.300
//    gamma 2.2 / 0.45         luminance mean 0.775 -> 0.631 / 0.871
//    glare i=0.35 r=0.15      +0.144 inside r/2, exactly 0.000 beyond 2r
//    illumination linear 0.5  right-minus-left -0.009 -> +0.338
//    illumination radial 0.5  centre-minus-edge -0.104 -> +0.253
//    colorTemperature ±0.6    R-B +0.022 -> +0.396 / -0.381, green untouched
//    saltPepper 0.05          5.06% of pixels saturated, salt share 0.500
//    defocus 5                edge energy -49.7% in x, -51.2% in y
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class DegradationRenderTests: XCTestCase {

    /// Small enough that the per-pixel defocus and noise passes are cheap in
    /// the Debug configuration these tests run under, large enough that the
    /// panel crop is ~40 000 pixels — plenty for stable means and moments.
    private let size = CGSize(width: 480, height: 854)
    private let sample = "12.345"

    private var renderer: SyntheticDisplayRenderer { SyntheticDisplayRenderer(size: size) }

    private func render(_ degradation: RenderDegradation = .none, frameIndex: Int = 0) throws -> CVPixelBuffer {
        try XCTUnwrap(renderer.render(text: sample, pose: .identity,
                                      degradation: degradation, frameIndex: frameIndex))
    }

    // MARK: - 1. Defaults are inert

    /// The regression guard for every pixel-diffing test in the suite: a
    /// degradation whose every field is spelled out at its default must reach
    /// the exact bytes of the original two-argument render.
    func testEveryNewKnobAtItsDefaultRendersTheOriginalBytes() throws {
        let explicit = RenderDegradation(occlusion: 0, blurRadius: 0, noiseAmount: 0, brightness: 1,
                                         contrast: 1, gamma: 1, glare: .none, illuminationGradient: .none,
                                         colorTemperature: 0, saltPepperAmount: 0, defocusRadius: 0)
        XCTAssertEqual(explicit, .none, "A fully-defaulted degradation must still equal .none")

        let original = try XCTUnwrap(renderer.render(text: sample, pose: .identity))
        // A non-zero frame index too: the new knobs take frameIndex, and one
        // that leaked into the drawing when off would break frame-to-frame
        // stability for every existing caller.
        let degraded = try render(explicit, frameIndex: 7)
        XCTAssertEqual(pixelData(original), pixelData(degraded))
    }

    /// The same guard at the shipping frame size and through the transformed
    /// draw path, which is where the fixtures and the demo stream live.
    func testDefaultsAreInertAtTheShippingSizeAndUnderAPose() throws {
        let full = SyntheticDisplayRenderer()
        XCTAssertEqual(pixelData(try XCTUnwrap(full.render(text: sample, pose: .identity))),
                       pixelData(try XCTUnwrap(full.render(text: sample, pose: .identity,
                                                           degradation: .none, frameIndex: 3))))

        let pose = DisplayPose(center: CGPoint(x: 0.52, y: 0.47), roll: 0.12,
                               yawScale: 0.85, pitchScale: 0.95, scale: 0.9)
        let r = renderer
        XCTAssertEqual(pixelData(try XCTUnwrap(r.render(text: sample, pose: pose))),
                       pixelData(try XCTUnwrap(r.render(text: sample, pose: pose,
                                                        degradation: .none, frameIndex: 11))))
    }

    /// Half-specified glare and a zero-strength gradient are still "off" —
    /// a sweep that ramps radius from 0 with intensity still at 0 must not
    /// start drawing, or the sweep's first row is not the clean case.
    func testHalfSpecifiedPanelEffectsStayInert() throws {
        let baseline = pixelData(try render())
        let radiusOnly = RenderDegradation(glare: PanelGlare(radius: 0.4, intensity: 0))
        let intensityOnly = RenderDegradation(glare: PanelGlare(radius: 0, intensity: 0.8))
        let zeroStrength = RenderDegradation(
            illuminationGradient: IlluminationGradient(shape: .radial, direction: 1.2, strength: 0))
        XCTAssertEqual(baseline, pixelData(try render(radiusOnly)))
        XCTAssertEqual(baseline, pixelData(try render(intensityOnly)))
        XCTAssertEqual(baseline, pixelData(try render(zeroStrength)))
    }

    // MARK: - 2. Each knob moves the image the way its name claims

    func testContrastFlattensAndExpandsThePanelsLuminanceSpread() throws {
        let base = try panel(render())
        let low = try panel(render(RenderDegradation(contrast: 0.35)))
        let high = try panel(render(RenderDegradation(contrast: 1.6)))
        print(String(format: "contrast: sd base=%.4f  0.35=%.4f  1.6=%.4f",
                     base.luminanceSD, low.luminanceSD, high.luminanceSD))

        XCTAssertLessThan(low.luminanceSD, base.luminanceSD * 0.6,
            "contrast 0.35 barely flattened the panel (sd \(base.luminanceSD) -> \(low.luminanceSD))")
        XCTAssertGreaterThan(high.luminanceSD, base.luminanceSD * 1.05,
            "contrast 1.6 did not expand the panel (sd \(base.luminanceSD) -> \(high.luminanceSD))")
        // Flattening is TOWARD mid-grey, not toward black: a low-contrast
        // capture is washed out, and a knob that merely darkened would be
        // indistinguishable from `brightness` in a sweep.
        XCTAssertLessThan(abs(low.luminanceMean - 0.5), abs(base.luminanceMean - 0.5),
            "contrast 0.35 moved the panel away from mid-grey (\(base.luminanceMean) -> \(low.luminanceMean))")
    }

    func testGammaDarkensMidtonesAboveOneAndLiftsThemBelowIt() throws {
        let base = try panel(render())
        let dark = try panel(render(RenderDegradation(gamma: 2.2)))
        let light = try panel(render(RenderDegradation(gamma: 0.45)))
        print(String(format: "gamma: mean base=%.4f  2.2=%.4f  0.45=%.4f",
                     base.luminanceMean, dark.luminanceMean, light.luminanceMean))

        XCTAssertLessThan(dark.luminanceMean, base.luminanceMean * 0.85,
            "gamma 2.2 did not darken the panel (\(base.luminanceMean) -> \(dark.luminanceMean))")
        XCTAssertGreaterThan(light.luminanceMean, base.luminanceMean * 1.05,
            "gamma 0.45 did not lift the panel (\(base.luminanceMean) -> \(light.luminanceMean))")
    }

    /// Glare must be LOCAL. A highlight that lifts the whole panel is just
    /// `brightness` under another name and would tell a sweep nothing new.
    func testGlareRaisesLuminanceNearItsCentreAndNowhereElse() throws {
        let centre = CGPoint(x: 0.3, y: 0.5)
        let radius: CGFloat = 0.15
        let base = try panel(render())
        let lit = try panel(render(RenderDegradation(glare: PanelGlare(center: centre,
                                                                      radius: radius,
                                                                      intensity: 0.35))))
        let near = lit.meanLuminance(withinUnitRadius: radius * 0.5, of: centre)
            - base.meanLuminance(withinUnitRadius: radius * 0.5, of: centre)
        let far = lit.meanLuminance(beyondUnitRadius: radius * 2, of: centre)
            - base.meanLuminance(beyondUnitRadius: radius * 2, of: centre)
        print(String(format: "glare: dL near-centre=%+.4f  beyond-2r=%+.4f", near, far))

        // Measured +0.1435 at intensity 0.35: the core saturates outright and
        // the shoulder inside half-radius averages ~0.175 of alpha, which is
        // where the rest of the lift comes from.
        XCTAssertGreaterThan(near, 0.12,
            "The highlight's core barely brightened (dL=\(near))")
        XCTAssertLessThan(abs(far), 0.001,
            "The highlight leaked past its radius (dL=\(far))")
    }

    func testLinearIlluminationGradientTiltsLuminanceAlongItsDirection() throws {
        let base = try panel(render())
        // direction 0 points at +x, and the panel is drawn in a top-left-origin
        // space, so the bright end is the right-hand edge.
        let tilted = try panel(render(RenderDegradation(
            illuminationGradient: IlluminationGradient(shape: .linear, direction: 0, strength: 0.5))))
        let baseTilt = base.meanLuminance(unitXIn: 0.7...1) - base.meanLuminance(unitXIn: 0...0.3)
        let litTilt = tilted.meanLuminance(unitXIn: 0.7...1) - tilted.meanLuminance(unitXIn: 0...0.3)
        print(String(format: "illumination(linear): right-minus-left base=%+.4f  strength 0.5=%+.4f",
                     baseTilt, litTilt))
        XCTAssertGreaterThan(litTilt - baseTilt, 0.3,
            "The backlight ramp did not tilt across the panel (\(baseTilt) -> \(litTilt))")

        // A negated strength must mirror the ramp rather than merely weaken it.
        let flipped = try panel(render(RenderDegradation(
            illuminationGradient: IlluminationGradient(shape: .linear, direction: 0, strength: -0.5))))
        let flippedTilt = flipped.meanLuminance(unitXIn: 0.7...1) - flipped.meanLuminance(unitXIn: 0...0.3)
        XCTAssertLessThan(flippedTilt - baseTilt, -0.3,
            "Negative strength did not mirror the ramp (\(flippedTilt))")
    }

    func testRadialIlluminationGradientBrightensTheCentreAndDarkensTheEdge() throws {
        let centre = CGPoint(x: 0.5, y: 0.5)
        let base = try panel(render())
        let vignetted = try panel(render(RenderDegradation(
            illuminationGradient: IlluminationGradient(shape: .radial, strength: 0.5))))
        let baseFalloff = base.meanLuminance(withinUnitRadius: 0.12, of: centre)
            - base.meanLuminance(beyondUnitRadius: 0.35, of: centre)
        let litFalloff = vignetted.meanLuminance(withinUnitRadius: 0.12, of: centre)
            - vignetted.meanLuminance(beyondUnitRadius: 0.35, of: centre)
        print(String(format: "illumination(radial): centre-minus-edge base=%+.4f  strength 0.5=%+.4f",
                     baseFalloff, litFalloff))
        XCTAssertGreaterThan(litFalloff - baseFalloff, 0.25,
            "The vignette did not open a centre-to-edge gap (\(baseFalloff) -> \(litFalloff))")
    }

    func testColorTemperatureSplitsRedAndBlueInTheStatedDirection() throws {
        let base = try panel(render())
        let warm = try panel(render(RenderDegradation(colorTemperature: 0.6)))
        let cool = try panel(render(RenderDegradation(colorTemperature: -0.6)))
        print(String(format: "colorTemperature: R-B base=%+.4f  +0.6=%+.4f  -0.6=%+.4f",
                     base.redMinusBlue, warm.redMinusBlue, cool.redMinusBlue))

        XCTAssertGreaterThan(warm.redMinusBlue - base.redMinusBlue, 0.15,
            "Positive colorTemperature did not push amber (\(base.redMinusBlue) -> \(warm.redMinusBlue))")
        XCTAssertLessThan(cool.redMinusBlue - base.redMinusBlue, -0.15,
            "Negative colorTemperature did not push blue (\(base.redMinusBlue) -> \(cool.redMinusBlue))")
        // Green is the reference channel — a white-balance error that moved all
        // three would be a brightness change wearing a colour costume.
        XCTAssertEqual(warm.greenMean, base.greenMean, accuracy: 0.002)
        XCTAssertEqual(cool.greenMean, base.greenMean, accuracy: 0.002)
    }

    func testSaltPepperHitsTheRequestedFractionAndSplitsBothWays() throws {
        let base = try panel(render())
        let speckled = try panel(render(RenderDegradation(saltPepperAmount: 0.05)))
        print(String(format: "saltPepper: impulse fraction base=%.5f  0.05=%.5f (salt share %.3f)",
                     base.impulseFraction, speckled.impulseFraction, speckled.saltShare))

        XCTAssertEqual(base.impulseFraction, 0, accuracy: 1e-9,
                       "The clean panel already contains saturated pixels")
        XCTAssertEqual(speckled.impulseFraction, 0.05, accuracy: 0.006,
            "Impulse rate missed its target (\(speckled.impulseFraction))")
        XCTAssertEqual(speckled.saltShare, 0.5, accuracy: 0.08,
            "Salt and pepper are not balanced (salt share \(speckled.saltShare))")
        // Distinct from the Gaussian knob: impulse noise leaves most pixels
        // untouched, where `noiseAmount` perturbs essentially all of them.
        let gaussian = try panel(render(RenderDegradation(noiseAmount: 0.05)))
        XCTAssertLessThan(gaussian.impulseFraction, 0.001,
            "noiseAmount is saturating pixels — the two noise knobs have collapsed together")
    }

    func testDefocusCollapsesEdgeEnergyInBothAxes() throws {
        let base = try panel(render())
        let soft = try panel(render(RenderDegradation(defocusRadius: 5)))
        let horizontalDrop = 1 - soft.horizontalEdgeEnergy / base.horizontalEdgeEnergy
        let verticalDrop = 1 - soft.verticalEdgeEnergy / base.verticalEdgeEnergy
        print(String(format: "defocus r=5: edge energy dx %.5f -> %.5f (-%.1f%%), dy %.5f -> %.5f (-%.1f%%)",
                     base.horizontalEdgeEnergy, soft.horizontalEdgeEnergy, horizontalDrop * 100,
                     base.verticalEdgeEnergy, soft.verticalEdgeEnergy, verticalDrop * 100))

        XCTAssertGreaterThan(horizontalDrop, 0.4,
            "Defocus barely softened horizontal edges (-\(horizontalDrop * 100)%)")
        XCTAssertGreaterThan(verticalDrop, 0.4,
            "Defocus barely softened vertical edges (-\(verticalDrop * 100)%)")
        // Symmetry is the whole point of having this knob alongside the
        // directional `blurRadius`: it must not favour one axis.
        XCTAssertEqual(horizontalDrop, verticalDrop, accuracy: 0.15,
            "Defocus is directional (dx -\(horizontalDrop), dy -\(verticalDrop))")
    }

    // MARK: - 3. Determinism

    /// Every knob on at once, replayed. This is the property the whole
    /// validation vocabulary rests on: a failing sweep row must be
    /// reproducible from its seed and frame index alone.
    func testAllKnobsTogetherReplayByteForByte() throws {
        let brutal = Self.everythingOn
        XCTAssertEqual(pixelData(try render(brutal, frameIndex: 5)),
                       pixelData(try render(brutal, frameIndex: 5)))
    }

    /// The contrast that makes the previous test mean something: the same
    /// parameters at a DIFFERENT frame index must actually produce a
    /// different frame, or "deterministic" would be satisfied by a renderer
    /// that ignores frameIndex entirely.
    func testFrameIndexAdvancesTheDegradedFrame() throws {
        let brutal = Self.everythingOn
        XCTAssertNotEqual(pixelData(try render(brutal, frameIndex: 5)),
                          pixelData(try render(brutal, frameIndex: 6)))
    }

    // MARK: - 4. Moving glare

    /// `drift` has to move the highlight across the panel, monotonically and
    /// by a useful amount — a "moving glare" scenario that shifts the spot by
    /// a couple of pixels per frame is a static glare with extra bookkeeping.
    func testDriftingGlareSweepsAcrossThePanel() throws {
        let glare = PanelGlare(center: CGPoint(x: 0.2, y: 0.5), radius: 0.12,
                               intensity: 0.45, drift: CGVector(dx: 0.06, dy: 0))
        let base = try panel(render())
        var centroids: [Double] = []
        for frame in 0...5 {
            centroids.append(try panel(render(RenderDegradation(glare: glare), frameIndex: frame))
                .glareCentroidX(against: base))
        }
        print("glare drift 0.06/frame: centroid x = "
              + centroids.map { String(format: "%.3f", $0) }.joined(separator: ", "))

        for (i, pair) in zip(centroids, centroids.dropFirst()).enumerated() {
            XCTAssertGreaterThan(pair.1, pair.0 + 0.03,
                "The highlight stalled between frames \(i) and \(i + 1) (\(pair.0) -> \(pair.1))")
        }
        XCTAssertGreaterThan(centroids.last! - centroids.first!, 0.25,
            "Five frames of drift moved the highlight by \(centroids.last! - centroids.first!) panel widths")
    }

    /// Zero drift means zero drift: a sweep that wants a fixed highlight must
    /// get pixels that do not move with the frame index.
    func testStationaryGlareDoesNotMoveWithFrameIndex() throws {
        let still = RenderDegradation(glare: PanelGlare(center: CGPoint(x: 0.35, y: 0.5),
                                                        radius: 0.12, intensity: 0.45))
        XCTAssertEqual(pixelData(try render(still, frameIndex: 0)),
                       pixelData(try render(still, frameIndex: 40)))
    }

    /// The drift path folds instead of wrapping, so a long sequence keeps the
    /// spot on the panel without a single-frame teleport that no reflection
    /// makes and that a temporal filter would find suspiciously easy.
    func testGlareDriftStaysOnThePanelAndNeverTeleports() {
        let glare = PanelGlare(center: CGPoint(x: 0.2, y: 0.4),
                               radius: 0.1, intensity: 0.5,
                               drift: CGVector(dx: 0.07, dy: -0.031))
        var previous = glare.center(atFrame: 0)
        for frame in 1...400 {
            let c = glare.center(atFrame: frame)
            XCTAssert((0...1).contains(c.x) && (0...1).contains(c.y),
                      "frame \(frame): highlight left the panel at \(c)")
            XCTAssertLessThanOrEqual(abs(c.x - previous.x), 0.07 + 1e-9,
                                     "frame \(frame): the highlight jumped in x")
            XCTAssertLessThanOrEqual(abs(c.y - previous.y), 0.031 + 1e-9,
                                     "frame \(frame): the highlight jumped in y")
            previous = c
        }
    }

    // MARK: - The perspective path carries the same knobs

    /// The 3-D path composites through CoreImage, so it is never pixel-diffed
    /// (see the `render(text:pose3D:)` doc note). What is asserted is that the
    /// new knobs reach it at all: a sweep over true perspective poses would
    /// otherwise silently measure clean frames.
    func testNewKnobsReachThePerspectiveRenderPath() throws {
        let r = renderer
        let pose = DisplayPose3D(yaw: 0.35, pitch: -0.2, roll: 0.1)
        let clean = try panel(XCTUnwrap(r.render(text: sample, pose3D: pose)))
        let glared = try panel(XCTUnwrap(r.render(text: sample, pose3D: pose,
                                                  degradation: RenderDegradation(
                                                      glare: PanelGlare(center: CGPoint(x: 0.5, y: 0.5),
                                                                        radius: 0.3, intensity: 0.6)))))
        let dark = try panel(XCTUnwrap(r.render(text: sample, pose3D: pose,
                                                degradation: RenderDegradation(gamma: 2.4))))
        print(String(format: "perspective: mean clean=%.4f  glare=%.4f  gamma 2.4=%.4f",
                     clean.luminanceMean, glared.luminanceMean, dark.luminanceMean))
        XCTAssertGreaterThan(glared.luminanceMean, clean.luminanceMean + 0.02,
                             "Glare did not reach the warped panel")
        XCTAssertLessThan(dark.luminanceMean, clean.luminanceMean * 0.9,
                          "The transfer curve did not reach the warped frame")
    }

    // MARK: - Measurement

    private static let everythingOn = RenderDegradation(
        occlusion: 0.12, blurRadius: 4, noiseAmount: 0.08, brightness: 0.9,
        contrast: 0.8, gamma: 1.3,
        glare: PanelGlare(center: CGPoint(x: 0.3, y: 0.5), radius: 0.14,
                          intensity: 0.4, drift: CGVector(dx: 0.05, dy: 0.01)),
        illuminationGradient: IlluminationGradient(shape: .linear, direction: 0.4, strength: 0.25),
        colorTemperature: 0.3, saltPepperAmount: 0.02, defocusRadius: 3)

    /// The panel crop's pixels in a form the direction assertions can measure.
    /// Channels are kept separate because the white-balance knob is invisible
    /// in luminance alone.
    private struct Panel {
        let width: Int
        let height: Int
        let luminance: [Double]
        let red: [Double]
        let green: [Double]
        let blue: [Double]
        /// Pixels forced to full black or full white in all three channels.
        let impulseCount: Int
        let saltCount: Int

        var luminanceMean: Double { luminance.reduce(0, +) / Double(luminance.count) }
        var luminanceSD: Double {
            let m = luminanceMean
            return (luminance.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(luminance.count)).squareRoot()
        }
        var greenMean: Double { green.reduce(0, +) / Double(green.count) }
        var redMinusBlue: Double {
            (red.reduce(0, +) - blue.reduce(0, +)) / Double(red.count)
        }
        var impulseFraction: Double { Double(impulseCount) / Double(luminance.count) }
        var saltShare: Double { impulseCount == 0 ? 0 : Double(saltCount) / Double(impulseCount) }

        /// Mean absolute first difference along x over the panel's middle
        /// fifths — a scale-free stand-in for how much edge contrast the frame
        /// still carries.
        ///
        /// The margin is not cosmetic. The crop's boundary IS the panel's own
        /// edge, so a blur drags the body-to-panel step (0.78 of luminance)
        /// inward and manufactures edge energy that was previously outside the
        /// crop. That contamination scales with 1/extent, so on this 364×111
        /// panel it swamps the vertical measurement while barely touching the
        /// horizontal one: measured undropped, defocus r=5 read as -34.4% in x
        /// against -7.7% in y, purely from where the border sits.
        var horizontalEdgeEnergy: Double { edgeEnergy(dx: 1, dy: 0) }
        var verticalEdgeEnergy: Double { edgeEnergy(dx: 0, dy: 1) }

        private func edgeEnergy(dx: Int, dy: Int) -> Double {
            let mx = width / 5, my = height / 5
            var total = 0.0
            var n = 0
            for y in my..<(height - my) {
                for x in mx..<(width - mx) {
                    total += abs(luminance[y * width + x] - luminance[(y - dy) * width + x - dx])
                    n += 1
                }
            }
            return total / Double(n)
        }

        /// Unit panel coordinates are the same space `PanelGlare.center` uses,
        /// so a probe region here means exactly what the knob means.
        private func unit(_ x: Int, _ y: Int) -> CGPoint {
            CGPoint(x: (Double(x) + 0.5) / Double(width), y: (Double(y) + 0.5) / Double(height))
        }

        /// Distances are measured in units of panel WIDTH on both axes, so a
        /// circle here is the same circle the renderer draws on a panel that
        /// is far wider than it is tall.
        private func distance(_ p: CGPoint, _ q: CGPoint) -> Double {
            let aspect = Double(height) / Double(width)
            return hypot(Double(p.x - q.x), Double(p.y - q.y) * aspect)
        }

        func meanLuminance(withinUnitRadius r: CGFloat, of centre: CGPoint) -> Double {
            mean { distance(unit($0, $1), centre) <= Double(r) }
        }

        func meanLuminance(beyondUnitRadius r: CGFloat, of centre: CGPoint) -> Double {
            mean { distance(unit($0, $1), centre) > Double(r) }
        }

        func meanLuminance(unitXIn range: ClosedRange<Double>) -> Double {
            mean { x, _ in range.contains((Double(x) + 0.5) / Double(width)) }
        }

        private func mean(_ include: (Int, Int) -> Bool) -> Double {
            var total = 0.0
            var n = 0
            for y in 0..<height {
                for x in 0..<width where include(x, y) {
                    total += luminance[y * width + x]
                    n += 1
                }
            }
            return n == 0 ? 0 : total / Double(n)
        }

        /// Centroid (in unit panel widths) of this panel's luminance GAIN over
        /// `baseline`. Isolating the highlight's own contribution is what makes
        /// the measurement independent of which digits happen to be showing.
        func glareCentroidX(against baseline: Panel) -> Double {
            var weighted = 0.0
            var total = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let gain = max(0, luminance[y * width + x] - baseline.luminance[y * width + x])
                    weighted += gain * (Double(x) + 0.5) / Double(width)
                    total += gain
                }
            }
            return total == 0 ? .nan : weighted / total
        }
    }

    private func panel(_ buffer: CVPixelBuffer) throws -> Panel {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let frame = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let rect = SyntheticDisplayRenderer.displayROI.pixelRect(in: frame)
        let x0 = Int(rect.minX.rounded()), y0 = Int(rect.minY.rounded())
        let w = Int(rect.width.rounded()), h = Int(rect.height.rounded())

        var luminance = [Double](), red = [Double](), green = [Double](), blue = [Double]()
        luminance.reserveCapacity(w * h)
        var impulse = 0, salt = 0
        for y in 0..<h {
            let row = ptr + (y0 + y) * bytesPerRow
            for x in 0..<w {
                let pixel = row + (x0 + x) * 4
                // 32BGRA: byte 0 is blue, byte 2 is red.
                let b = Double(pixel[0]) / 255, g = Double(pixel[1]) / 255, r = Double(pixel[2]) / 255
                blue.append(b); green.append(g); red.append(r)
                luminance.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
                if pixel[0] == pixel[1], pixel[1] == pixel[2] {
                    if pixel[0] == 255 { impulse += 1; salt += 1 } else if pixel[0] == 0 { impulse += 1 }
                }
            }
        }
        return Panel(width: w, height: h, luminance: luminance, red: red, green: green, blue: blue,
                     impulseCount: impulse, saltCount: salt)
    }

    /// Snapshots a locked 32BGRA buffer's active pixel region, ignoring any
    /// trailing row padding so the comparison is over real pixels only.
    private func pixelData(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var data = Data(capacity: width * height * 4)
        for y in 0..<height {
            data.append(contentsOf: UnsafeBufferPointer(start: ptr + y * bytesPerRow, count: width * 4))
        }
        return data
    }
}
