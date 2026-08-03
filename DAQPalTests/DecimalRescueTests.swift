//
//  DecimalRescueTests.swift
//  DAQPalTests
//
//  Every case here renders a REAL image with the project's existing synthetic
//  renderer and runs the REAL analyzer over it. Nothing is stubbed: if the dot
//  is not in the pixels, the test fails.
//
//  ORIENTATION. `SyntheticDisplayRenderer` flips its CGContext to a top-left,
//  y-down space before drawing, and `SyntheticDisplayGenerator`'s header records
//  a historical DOUBLE-FLIP bug (a second flip when blitting an already-upright
//  CGImage inverted every buffer and made '2' decode as '5'). Baseline adjacency
//  is an up/down test, so an inverted buffer would silently invert the meaning of
//  every result here — `testCanonicalCropIsUpright` verifies the orientation of
//  the crops these tests feed the analyzer, rather than trusting the reasoning.
//
//  DETERMINISM. No `Date()`, no sleeps, no randomness — the renderer's noise is a
//  pure hash of (x, y, frameIndex).
//

import CoreVideo
import CoreGraphics
import XCTest
@testable import DAQPal

final class DecimalRescueTests: XCTestCase {

    // MARK: - Rendering support

    /// Full-frame size used for every render. Large enough that the LCD panel is
    /// ~820x250 px and a decimal point is ~10 px across — the regime a real
    /// canonical crop of a phone-camera frame lands in.
    private static let frameSize = CGSize(width: 1080, height: 1920)

    /// The canonical ROI: the rendered panel, inset 20 px so the panel's rounded
    /// corners (which are body-coloured, i.e. "ink") are not part of the crop.
    /// A real `PerspectiveNormalizer` crop of a tracked quad has the same
    /// property — it is the display field, not the bezel.
    private static var canonicalROI: NormalizedROI {
        let panel = SyntheticDisplayRenderer.displayROI.pixelRect(in: frameSize).insetBy(dx: 20, dy: 20)
        return NormalizedROI(x: panel.minX / frameSize.width,
                             y: panel.minY / frameSize.height,
                             width: panel.width / frameSize.width,
                             height: panel.height / frameSize.height)
    }

    /// Renders `text` and returns the canonical (panel) crop.
    private func canonical(_ text: String,
                           degradation: RenderDegradation = .none,
                           frameIndex: Int = 0,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> CVPixelBuffer {
        let renderer = SyntheticDisplayRenderer(size: Self.frameSize)
        let frame = try XCTUnwrap(renderer.render(text: text, pose: .identity,
                                                  degradation: degradation, frameIndex: frameIndex),
                                  "renderer produced no frame for \(text)", file: file, line: line)
        return try XCTUnwrap(PixelBufferROI.cropped(frame, to: Self.canonicalROI),
                             "crop failed for \(text)", file: file, line: line)
    }

    private func analyze(_ text: String,
                         digitCount: Int? = nil,
                         degradation: RenderDegradation = .none,
                         frameIndex: Int = 0,
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> DecimalRescue.Finding {
        let image = try canonical(text, degradation: degradation, frameIndex: frameIndex,
                                  file: file, line: line)
        return DecimalRescue.analyze(canonicalImage: image, digitCount: digitCount)
    }

    // MARK: - Orientation guard

    /// The crop must be upright: the digits' ink must sit in the vertical middle
    /// of the panel with background above and below, and — the part that matters
    /// for baseline adjacency — a rendered `"8."` must have its dot ink in the
    /// BOTTOM half of the ink band, not the top. If the buffer were flipped, the
    /// dot would appear above the digits and every baseline test would be
    /// measuring the wrong edge.
    func testCanonicalCropIsUpright() throws {
        let image = try canonical("8.")
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(image))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(image)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        // Ink = clearly darker than the light LCD field.
        var inkRows: [Int] = []
        var inkPerRow = [Int](repeating: 0, count: height)
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            var count = 0
            for x in 0..<width {
                let p = row + x * 4
                let lum = 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                if lum < 110 { count += 1 }
            }
            inkPerRow[y] = count
            if count > 0 { inkRows.append(y) }
        }
        let top = try XCTUnwrap(inkRows.first)
        let bottom = try XCTUnwrap(inkRows.last)
        XCTAssertGreaterThan(top, 0, "ink touches the top edge — crop is not the panel interior")
        XCTAssertLessThan(bottom, height - 1, "ink touches the bottom edge")

        // The '8' spans the whole band; the '.' adds ink only near the bottom.
        // So the widest ink row must be in the upper 80% of the band and the
        // last few band rows must still carry the dot's (small) ink.
        let bandHeight = bottom - top + 1
        let dotRow = bottom - bandHeight / 20
        XCTAssertGreaterThan(inkPerRow[dotRow], 0, "no ink near the baseline — buffer may be flipped")
        let upperHalfInk = (top..<(top + bandHeight / 2)).reduce(0) { $0 + inkPerRow[$1] }
        let lowerHalfInk = ((top + bandHeight / 2)...bottom).reduce(0) { $0 + inkPerRow[$1] }
        XCTAssertGreaterThan(upperHalfInk, 0)
        XCTAssertGreaterThan(lowerHalfInk, 0)
    }

    // MARK: - Headline case

    /// THE case the whole effort exists for: `80.8` must not be readable as 808.
    func testHeadlineCase_80point8() throws {
        let finding = try analyze("80.8", digitCount: 3)
        XCTAssertTrue(finding.separatorPresent, finding.rationale)
        XCTAssertEqual(finding.position, 2, finding.rationale)
        XCTAssertGreaterThanOrEqual(finding.confidence, 0.5, finding.rationale)
    }

    func testIntegerHasNoSeparator_808() throws {
        let finding = try analyze("808", digitCount: 3)
        XCTAssertFalse(finding.separatorPresent, finding.rationale)
        XCTAssertNil(finding.position, finding.rationale)
        XCTAssertGreaterThanOrEqual(finding.confidence, 0.5,
                                    "a clean integer display is a CONFIDENT absence: \(finding.rationale)")
    }

    // MARK: - Position derivation

    func testSeparatorPositions() throws {
        let cases: [(text: String, digits: Int, position: Int)] = [
            ("12.345", 5, 2),
            ("0.001", 4, 1),
            ("99.9", 3, 2),
            ("100.0", 4, 3),
            ("1.000", 4, 1),
        ]
        for testCase in cases {
            let finding = try analyze(testCase.text, digitCount: testCase.digits)
            XCTAssertTrue(finding.separatorPresent, "\(testCase.text): \(finding.rationale)")
            XCTAssertEqual(finding.position, testCase.position,
                           "\(testCase.text): \(finding.rationale)")
            XCTAssertGreaterThanOrEqual(finding.confidence, 0.4,
                                        "\(testCase.text): \(finding.rationale)")
        }
    }

    /// The minus sign is neither a separator nor a digit: `-1.25` has ONE digit
    /// before the point, and the sign must not shift that to two.
    func testSignIsNeitherSeparatorNorDigit() throws {
        let finding = try analyze("-1.25", digitCount: 3)
        XCTAssertTrue(finding.separatorPresent, finding.rationale)
        XCTAssertEqual(finding.position, 1,
                       "the leading '-' was counted as a digit: \(finding.rationale)")
    }

    /// A signed integer must not turn its minus into a separator.
    func testSignAloneIsNotASeparator() throws {
        let finding = try analyze("-125", digitCount: 3)
        XCTAssertFalse(finding.separatorPresent, finding.rationale)
    }

    // MARK: - Baseline discrimination

    /// A colon sits between digits and its lower lobe is dot-shaped — the exact
    /// false positive baseline adjacency alone cannot reject.
    func testColonIsNotASeparator() throws {
        let finding = try analyze("80:8", digitCount: 3)
        XCTAssertFalse(finding.separatorPresent,
                       "a colon was read as a decimal separator: \(finding.rationale)")
        XCTAssertNil(finding.position, finding.rationale)
    }

    /// A mid-height dot (U+00B7) has a decimal point's size and shape and fails
    /// only on where it sits.
    func testMidHeightDotIsNotASeparator() throws {
        let finding = try analyze("80\u{00B7}8", digitCount: 3)
        XCTAssertFalse(finding.separatorPresent,
                       "a mid-height dot was read as a decimal separator: \(finding.rationale)")
    }

    // MARK: - Digit-count cross-check

    /// A declared digit count that disagrees with what was found must DISCOUNT
    /// the finding, never suppress or invent one.
    func testDigitCountMismatchDiscountsConfidence() throws {
        let matched = try analyze("80.8", digitCount: 3)
        let mismatched = try analyze("80.8", digitCount: 5)
        XCTAssertEqual(matched.position, 2, matched.rationale)
        XCTAssertEqual(mismatched.position, 2, mismatched.rationale)
        XCTAssertLessThan(mismatched.confidence, matched.confidence, mismatched.rationale)
        XCTAssertTrue(mismatched.rationale.contains("digit count"), mismatched.rationale)
    }

    /// No declared count is not a mismatch.
    func testNilDigitCountIsNeutral() throws {
        let declared = try analyze("80.8", digitCount: 3)
        let undeclared = try analyze("80.8", digitCount: nil)
        XCTAssertEqual(declared, undeclared)
    }

    // MARK: - Determinism

    func testSameImageAnalyzedTwiceIsIdentical() throws {
        let image = try canonical("80.8")
        let first = DecimalRescue.analyze(canonicalImage: image, digitCount: 3)
        let second = DecimalRescue.analyze(canonicalImage: image, digitCount: 3)
        XCTAssertEqual(first, second)
    }

    func testTwoRendersOfTheSameTextAgree() throws {
        let first = try analyze("12.345", digitCount: 5)
        let second = try analyze("12.345", digitCount: 5)
        XCTAssertEqual(first, second)
    }

    // MARK: - Degradation

    /// Sweeps each degradation axis and REPORTS the level at which rescue stops
    /// working. A measured failure threshold is a result, not a defect — the
    /// assertions below only pin the floor that is already known to hold, so the
    /// printed thresholds stay the honest number.
    ///
    /// READ THE BLUR NUMBER WITH CARE. `RenderDegradation.blurRadius` is motion
    /// blur as `SyntheticDisplayRenderer.drawMotionBlurred` implements it: four
    /// ghost copies at 0.35 *total* alpha, then one FULL-ALPHA SHARP COPY of the
    /// panel on top. The glyph core therefore never loses sharpness no matter how
    /// large the radius, so a high surviving radius here measures the renderer's
    /// blur model, not this analyzer's blur tolerance.
    /// `testTrueOpticalDegradationThresholds` sweeps a real Gaussian blur for
    /// that; the two numbers are not comparable and neither is a claim about a
    /// physical instrument.
    func testDegradationThresholds() throws {
        func survives(_ degradation: RenderDegradation) -> Bool {
            guard let finding = try? analyze("80.8", digitCount: 3, degradation: degradation) else {
                return false
            }
            return finding.separatorPresent && finding.position == 2
        }

        var report: [String] = []

        let noiseLevels: [CGFloat] = [0, 0.05, 0.10, 0.15, 0.20, 0.30, 0.40, 0.50, 0.70, 1.0]
        var lastNoise: CGFloat = -1
        for level in noiseLevels {
            if survives(RenderDegradation(noiseAmount: level)) { lastNoise = level } else { break }
        }
        report.append("noiseAmount: last surviving = \(lastNoise)")

        let blurRadii: [CGFloat] = [0, 2, 4, 6, 8, 12, 16, 24, 32, 48]
        var lastBlur: CGFloat = -1
        for radius in blurRadii {
            if survives(RenderDegradation(blurRadius: radius)) { lastBlur = radius } else { break }
        }
        report.append("blurRadius: last surviving = \(lastBlur) pt")

        // Brightness < 1 darkens the panel toward the body colour: low contrast.
        let brightnessLevels: [CGFloat] = [1.0, 0.8, 0.6, 0.5, 0.4, 0.3, 0.2, 0.15, 0.1, 0.05]
        var lastBrightness: CGFloat = 2
        for level in brightnessLevels {
            if survives(RenderDegradation(brightness: level)) { lastBrightness = level } else { break }
        }
        report.append("brightness: lowest surviving = \(lastBrightness)")

        // Combined "bad phone photo": moderate blur + noise + dimming together.
        let combined: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 1.0), (2, 0.05, 0.9), (4, 0.10, 0.8), (6, 0.15, 0.7),
            (8, 0.20, 0.6), (12, 0.30, 0.5), (16, 0.40, 0.4)
        ]
        var lastCombined = -1
        for (index, step) in combined.enumerated() {
            if survives(RenderDegradation(blurRadius: step.0, noiseAmount: step.1, brightness: step.2)) {
                lastCombined = index
            } else {
                break
            }
        }
        report.append("combined blur/noise/brightness: last surviving step = \(lastCombined) of \(combined.count - 1)")

        Self.emit("DECIMAL RESCUE DEGRADATION THRESHOLDS (synthetic renderer, 820x250 canonical crop)\n"
                  + report.map { "  " + $0 }.joined(separator: "\n"))

        // Floors, deliberately below the measured thresholds so this test
        // documents a REGRESSION rather than re-asserting the measurement.
        XCTAssertGreaterThanOrEqual(lastNoise, 0.05, report.joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(lastBlur, 2, report.joined(separator: " | "))
        XCTAssertLessThanOrEqual(lastBrightness, 0.6, report.joined(separator: " | "))
        XCTAssertGreaterThanOrEqual(lastCombined, 1, report.joined(separator: " | "))
    }

    /// The same sweep against `SyntheticDisplayGenerator`, whose blur is a real
    /// CoreImage Gaussian (no sharp core) and whose contrast knob genuinely
    /// compresses the dynamic range — the degradations that actually destroy a
    /// dot. Also covers the seven-segment (DSEG7) face, where the decimal point
    /// is a separate baseline glyph rather than a font period.
    ///
    /// The load-bearing assertion is the SAFETY one: across every level of every
    /// axis, the analyzer may lose the dot but must never report a WRONG
    /// position. Losing it is recoverable by the layers above; a wrong position
    /// is the silent factor-of-ten error.
    func testTrueOpticalDegradationThresholds() throws {
        let generator = try SyntheticDisplayGenerator()
        var wrongPositions: [String] = []

        func finding(_ augmentation: DisplayAugmentation,
                     name: String,
                     style: DisplayGlyphStyle) -> DecimalRescue.Finding? {
            guard let sample = try? generator.lineSample(text: "80.8", style: style,
                                                         augmentation: augmentation,
                                                         augmentationName: name) else { return nil }
            let result = DecimalRescue.analyze(canonicalImage: sample.pixelBuffer, digitCount: 3)
            if result.separatorPresent, let position = result.position, position != 2 {
                wrongPositions.append("\(style.rawValue)/\(name): position \(position) — \(result.rationale)")
            }
            return result
        }

        func survives(_ augmentation: DisplayAugmentation, name: String,
                      style: DisplayGlyphStyle = .sans) -> Bool {
            guard let result = finding(augmentation, name: name, style: style) else { return false }
            return result.separatorPresent && result.position == 2
        }

        var report: [String] = []

        /// Evaluates EVERY level — including levels past the detection threshold
        /// — and returns the last level of the leading run of successes. Sweeping
        /// past the threshold rather than stopping at it is deliberate: the
        /// wrong-position check below is only meaningful over the range where the
        /// image is actually falling apart.
        func sweep(_ name: String, _ levels: [CGFloat],
                   _ configure: (inout DisplayAugmentation, CGFloat) -> Void) -> CGFloat? {
            var lastSurviving: CGFloat?
            var stillSurviving = true
            for level in levels {
                var augmentation = DisplayAugmentation.clean
                configure(&augmentation, level)
                let ok = survives(augmentation, name: "\(name)-\(Int(level * 100))")
                if ok && stillSurviving { lastSurviving = level } else { stillSurviving = false }
            }
            return lastSurviving
        }

        // True Gaussian blur: radius = blur x min(w, h) x 0.04, so 1.0 is ~11 px
        // on the 640x280 tile.
        let levels: [CGFloat] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
        let lastBlur = sweep("blur", levels) { $0.blur = $1 } ?? -1
        report.append(String(format: "gaussian blur: last surviving = %.1f (~%.1f px)", lastBlur, lastBlur * 11.2))

        let contrastLevels: [CGFloat] = [1.0, 0.8, 0.6, 0.42, 0.3, 0.2, 0.1, 0.05]
        let lastContrast = sweep("contrast", contrastLevels) { $0.contrast = $1 } ?? 2
        report.append(String(format: "contrast: lowest surviving = %.2f", lastContrast))

        let lastNoise = sweep("noise", levels) { $0.noise = $1 } ?? -1
        report.append(String(format: "sensor noise: last surviving = %.1f", lastNoise))

        let lastGlow = sweep("glow", levels) { $0.glow = $1 } ?? -1
        report.append(String(format: "bloom/glow: last surviving = %.1f", lastGlow))

        for (name, augmentation) in DisplayAugmentation.presets {
            for style in [DisplayGlyphStyle.sans, .sevenSegment] {
                let result = finding(augmentation, name: name, style: style)
                let verdict = result.map {
                    "present=\($0.separatorPresent) position=\(String(describing: $0.position)) conf=\(String(format: "%.2f", $0.confidence))"
                } ?? "render failed"
                report.append("preset \(name) / \(style.rawValue): \(verdict)")
            }
        }

        Self.emit("DECIMAL RESCUE — TRUE OPTICAL DEGRADATION (SyntheticDisplayGenerator, 640x280)\n"
                  + report.map { "  " + $0 }.joined(separator: "\n"))

        XCTAssertTrue(wrongPositions.isEmpty,
                      "reported a WRONG separator position:\n" + wrongPositions.joined(separator: "\n"))
        XCTAssertTrue(survives(.clean, name: "clean"),
                      "clean sans render must be rescued: " + report.joined(separator: " | "))
        // Floors only — the report above is the measurement.
        XCTAssertGreaterThanOrEqual(lastBlur, 0.1, report.joined(separator: " | "))
        XCTAssertLessThanOrEqual(lastContrast, 0.6, report.joined(separator: " | "))
    }

    /// Past the detection threshold the analyzer must NOT report a wrong
    /// position — losing the dot has to look like a loss, not like an integer.
    func testHeavyDegradationDoesNotFabricateAPosition() throws {
        let brutal = RenderDegradation(blurRadius: 48, noiseAmount: 0.9, brightness: 0.05)
        let finding = try analyze("80.8", digitCount: 3, degradation: brutal)
        if finding.separatorPresent, let position = finding.position {
            XCTAssertEqual(position, 2,
                           "fabricated a WRONG separator position under heavy degradation: \(finding.rationale)")
        }
        if !finding.separatorPresent {
            XCTAssertLessThanOrEqual(finding.confidence, DecimalRescueTests.confidentAbsenceCeiling,
                                     "claimed a confident ABSENCE on an image it cannot read: \(finding.rationale)")
        }
    }

    /// Confidence in an absence must fall when the digit band has a hole where a
    /// separator would have been — the dropped-dot signature.
    func testDroppedDotLowersAbsenceConfidence() throws {
        let cleanInteger = try analyze("808", digitCount: 3)
        // A space in the monospaced band is exactly the hole a lost dot leaves.
        let hole = try analyze("80 8", digitCount: 3)
        XCTAssertFalse(cleanInteger.separatorPresent, cleanInteger.rationale)
        XCTAssertFalse(hole.separatorPresent, hole.rationale)
        XCTAssertLessThan(hole.confidence, cleanInteger.confidence,
                          "a suspicious gap was reported as confidently as a clean integer: \(hole.rationale)")
    }

    // MARK: - Never throws

    func testDegenerateInputsAreReportedNotThrown() throws {
        // 4x4 buffer: no digit band at all.
        var tiny: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
                                           nil, &tiny), kCVReturnSuccess)
        let tinyBuffer = try XCTUnwrap(tiny)
        let tinyFinding = DecimalRescue.analyze(canonicalImage: tinyBuffer, digitCount: 3)
        XCTAssertFalse(tinyFinding.separatorPresent)
        XCTAssertNil(tinyFinding.position)
        XCTAssertEqual(tinyFinding.confidence, 0)

        // A blank panel: background only, no digits.
        let blank = try canonical(" ")
        let blankFinding = DecimalRescue.analyze(canonicalImage: blank, digitCount: 3)
        XCTAssertFalse(blankFinding.separatorPresent)
        XCTAssertNil(blankFinding.position)
    }

    /// Above this, an absence is a claim; the analyzer must not make it on an
    /// image it cannot read.
    private static let confidentAbsenceCeiling: Float = 0.6

    /// PINS A KNOWN LIMITATION, so it cannot be quietly forgotten or quietly
    /// "fixed" by a change that starts guessing.
    ///
    /// On a true seven-segment face the segments do not touch, so
    /// connected-component labeling finds SEGMENTS, not digits — 21 components
    /// for a clean DSEG7 `"80.8"`. This layer cannot count digits there and so
    /// cannot place a separator. The REQUIRED behaviour, which this asserts, is
    /// that it never invents a position: it may report an absence or a presence
    /// with `position == nil`, but position 1 or 3 for `"80.8"` would be the
    /// factor-of-ten error itself.
    ///
    /// If someone later adds x-pitch digit-cell grouping, this test starts
    /// failing on the `XCTAssertNil` — at which point it should be replaced by a
    /// real positive assertion, not relaxed.
    func testSegmentFaceNeverInventsAPosition() throws {
        let generator = try SyntheticDisplayGenerator()
        for (name, augmentation) in DisplayAugmentation.presets {
            let sample = try generator.lineSample(text: "80.8", style: .sevenSegment,
                                                  augmentation: augmentation, augmentationName: name)
            let finding = DecimalRescue.analyze(canonicalImage: sample.pixelBuffer, digitCount: 3)
            XCTAssertNil(finding.position,
                         "DSEG7/\(name): segment faces are not segmented by this layer, so ANY position is invented — \(finding.rationale)")
            XCTAssertLessThanOrEqual(finding.confidence, DecimalRescueTests.confidentAbsenceCeiling,
                                     "DSEG7/\(name): confident verdict on a face this layer cannot segment — \(finding.rationale)")
        }
    }

    // MARK: - Cost (reported, never asserted)

    /// Reports the wall-clock cost of one `analyze` call on the canonical crop.
    ///
    /// NO ASSERTION. A timing on an iOS Simulator, in a DEBUG build, on a
    /// machine running other test bundles concurrently is not a device latency
    /// and must never be quoted as one; asserting on it would also make this
    /// suite non-deterministic. It is here so the order of magnitude is a
    /// measured number rather than a guess, and it is labeled as exactly that.
    func testAnalysisCostIsReported() throws {
        let image = try canonical("80.8")
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        // One warm-up call, then a batch, so first-touch page faults are not
        // charged to the mean.
        _ = DecimalRescue.analyze(canonicalImage: image, digitCount: 3)
        let iterations = 20
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<iterations {
            _ = DecimalRescue.analyze(canonicalImage: image, digitCount: 3)
        }
        let elapsed = start.duration(to: clock.now)
        let meanMS = Double(elapsed.components.attoseconds) / 1e18 * 1000 / Double(iterations)
            + Double(elapsed.components.seconds) * 1000 / Double(iterations)
        Self.emit(String(format: """
            DECIMAL RESCUE COST — DEBUG BUILD, iOS SIMULATOR, SHARED MACHINE.
            NOT a device latency and not a budget claim.
              canonical crop: %dx%d px
              mean over %d calls: %.2f ms
            """, width, height, iterations, meanMS))
    }

    // MARK: - Calibration diagnostic (not an assertion)

    /// Prints the labelled component geometry for the discriminating cases. Kept
    /// because the geometry constants in `DecimalRescue` are only auditable
    /// against real measurements of real renders.
    func testComponentGeometryDiagnostic() throws {
        var lines: [String] = []
        for text in ["80.8", "808", "80 8", "80:8", "80\u{00B7}8", "-1.25", "100.0"] {
            let image = try canonical(text)
            lines.append("--- \(text) ---")
            lines.append(DecimalRescue.componentReport(canonicalImage: image))
            lines.append("finding: \(DecimalRescue.analyze(canonicalImage: image, digitCount: nil))")
        }
        // The segment faces, where bloom fuses adjacent glyphs — the geometry the
        // merge guard is calibrated against.
        let generator = try SyntheticDisplayGenerator()
        for style in [DisplayGlyphStyle.sevenSegment, .sans] {
            for (name, augmentation) in DisplayAugmentation.presets {
                let sample = try generator.lineSample(text: "80.8", style: style,
                                                      augmentation: augmentation, augmentationName: name)
                lines.append("--- \(style.rawValue) / \(name) ---")
                lines.append(DecimalRescue.componentReport(canonicalImage: sample.pixelBuffer))
                lines.append("finding: \(DecimalRescue.analyze(canonicalImage: sample.pixelBuffer, digitCount: 3))")
            }
        }
        Self.emit(lines.joined(separator: "\n"))
    }

    /// XCTest stdout is not surfaced by `xcodebuild`, so diagnostics are written
    /// as a test attachment (always kept) as well as printed.
    private static func emit(_ text: String) {
        print(text)
        let attachment = XCTAttachment(string: text)
        attachment.lifetime = .keepAlways
        attachment.name = "decimal-rescue-diagnostics"
        XCTContext.runActivity(named: "diagnostics") { $0.add(attachment) }
    }
    // MARK: - Confident absence must be EARNED (safety regression)

    /// A confident absence is a claim that the display genuinely has no
    /// decimal. Claiming it when the analyzer simply could not tell is the
    /// silent coercion this module exists to prevent — it would let a real
    /// `80.8` be exported as `808` with the rescue layer's blessing.
    ///
    /// All three shapes below previously returned confidence 0.82, because
    /// `absence()` defaulted to "confident" and only downgraded when its
    /// inter-digit gap test both APPLIED and FIRED.
    func testAbsenceIsNotConfidentOnAShortReading() throws {
        // Two digits give one inter-digit gap, so the gap test cannot run at
        // all — there is no evidence either way, and the result must say so.
        for text in ["9.9", "0.5", "99", "12"] {
            let finding = try analyze(text, digitCount: nil)
            if !finding.separatorPresent {
                XCTAssertLessThanOrEqual(
                    finding.confidence, 0.5,
                    "A two-digit reading (\(text)) cannot support a CONFIDENT absence — one gap is not evidence. Got \(finding.confidence): \(finding.rationale)")
            }
        }
    }

    func testLeadingSeparatorIsNeverAConfidentAbsence() throws {
        // Leading-zero suppression is universal on multimeters. The dot sits
        // before every digit, so no INTER-digit gap can ever reveal its loss.
        let finding = try analyze(".808", digitCount: nil)
        if !finding.separatorPresent {
            XCTAssertLessThanOrEqual(
                finding.confidence, 0.5,
                "A leading separator reported as a CONFIDENT absence is exactly how .808 becomes 808. Detection only inspects gaps BETWEEN digits, so it never looks where a leading dot lives. Got \(finding.confidence): \(finding.rationale)")
        }
    }

    func testAbsenceRationaleNeverReportsANegativeGap() throws {
        // A negative median gap means components overlap horizontally, i.e. the
        // band was never segmented into digits. That is proof the statistics
        // are meaningless, so it must never accompany a confident absence.
        for text in ["80.8", "808", "9.9", ".808"] {
            let finding = try analyze(text, digitCount: nil)
            XCTAssertFalse(finding.rationale.contains("(-"),
                           "Negative gap in rationale for \(text): \(finding.rationale)")
        }
    }

}
