//
//  SegmentAmbiguitySweepTests.swift
//  DAQPalTests
//
//  The seven-segment / decimal-point validation sweep.
//
//  WHY THIS SWEEP EXISTS
//  ---------------------
//  The target hardware is a seven-segment IR thermometer and the recorded
//  failure is `90.0` read as `900`. Every digit is right; only the separator is
//  gone; the result is a well-formed number that is wrong by 10x, survives range
//  checks, and looks perfectly stable to the temporal filter. An accuracy number
//  that folds that case in with "read a 5 as a 6" answers the wrong question, so
//  this sweep reports the two rates SEPARATELY through `ReadingVerdict`:
//
//    * decimal-only   — decimalMissing / decimalSpurious / decimalMisplaced
//    * digit error    — at least one glyph decoded wrong
//
//  Every case is reported as a `ValidationOutcome` and aggregated by
//  `ValidationReport` (see `Support/ValidationHarness.swift`); the only thing
//  added here is a per-group DEFECT-MIX printer, because `summary(groupedBy:)`
//  groups by exact rate alone and the mix is the whole point.
//
//  WHAT IS MEASURED, AND WHAT IS NOT
//  ---------------------------------
//  Imagery comes from `SyntheticDisplayGenerator` (bundled DSEG7/DSEG14 fonts,
//  deterministic augmentation). It is a stand-in for physical display optics,
//  not a model of them, so these are numbers for the incumbent engine on a
//  SYNTHETIC distribution — not a real-instrument accuracy claim.
//
//  Apple Vision is measured at 14.6% (`.accurate`) / 41.7% (dual-pass) on
//  seven-segment glyphs, so nothing here asserts an accuracy threshold. The
//  assertions are structural: the sweep runs to completion, every case yields an
//  outcome, and the manipulations the sweep performs actually do what they claim
//  (see the segment-dropout test, which verifies its own erasure). The rates are
//  printed and allowed to speak.
//
//  MEASURED, iOS 26.5 simulator, Debug, `OCRManager` (dual-pass Vision)
//  ---------------------------------------------------------------------
//  Ambiguity sweep, 96 cases: 30.2% exact, 20.8% digit error, 8.3% decimal-only
//  — and every one of those eight is `decimalMissing`. Zero `decimalSpurious`,
//  zero `decimalMisplaced` in either Vision sweep: the engine does not invent
//  separators or move them, it DROPS them, which is exactly the `90.0` -> `900`
//  report. Coverage sweep, 81 cases: 45.7% exact, 23.5% digit error, 11.1%
//  decimal-only (again all missing).
//
//  The `sans-clean` control row reads 93.8% on the identical strings and optics.
//  The gap is the FONT, not the corpus: `.5` loses its separator in 3 of 3
//  seven-segment renders, and `7seg-ghosted` — unlit segments faintly visible —
//  is the only variant at 0.0% exact.
//
//  CI
//  --
//  `testAmbiguityPairSweep` and `testGlyphAndSeparatorCoverageSweep` each run a
//  Vision pass per case and are SLOW. Exclude them at the invocation level when
//  running the fast sweep:
//
//      xcodebuild test ... -skip-testing:DAQPalTests/SegmentAmbiguitySweepTests
//
//  The font-coverage and segment-dropout tests are pure arithmetic and cheap.
//

import CoreGraphics
import CoreText
import CoreVideo
import Foundation
import XCTest
@testable import DAQPal

final class SegmentAmbiguitySweepTests: XCTestCase {

    // MARK: - Corpus vocabulary

    /// One rendered case. `rendered` is what the panel shows; `truth` is what
    /// the pipeline must RECORD from it. They differ wherever the display
    /// carries decoration that is not part of the value — a leading `+`, a unit
    /// suffix, a degree mark — so a correctly stripped unit is not scored as a
    /// digit error.
    private struct SweepCase {
        let rendered: String
        let truth: String
        let parameters: [String: String]
    }

    /// A rendering condition: glyph technology plus optical degradation.
    private struct Variant {
        let name: String
        let style: DisplayGlyphStyle
        let augmentation: DisplayAugmentation
    }

    /// Render size. Larger than the generator's 640x280 default so a five-glyph
    /// line still clears Vision's minimum text height by a wide margin — the
    /// sweep is measuring glyph shape, not resolution starvation.
    private static let renderSize = CGSize(width: 960, height: 400)

    /// The documented ambiguity pairs. Each MEMBER is its own case (with the
    /// pair recorded as a parameter) so the report names which pair fails, not
    /// just that some pair did.
    ///
    /// The first four are glyph-level: the members differ by one or two lit
    /// segments, so a single mis-thresholded segment swaps them. The last four
    /// are separator-level: identical digit sequences that differ only in
    /// whether — or where — a decimal point sits.
    private static let ambiguityPairs: [(pair: String, members: [String])] = [
        ("8-vs-0", ["8", "0"]),            // differ by segment g alone
        ("3-vs-8", ["3", "8"]),            // differ by e and f
        ("5-vs-6", ["5", "6"]),            // differ by e alone
        ("1-vs-7", ["1", "7"]),            // differ by a (and f, in DSEG7 Classic)
        ("0.8-vs-08", ["0.8", "08"]),      // separator vs leading zero
        ("80.8-vs-808", ["80.8", "808"]),  // the spec's motivating 10x pair
        ("1.00-vs-100", ["1.00", "100"]),  // significant trailing zeros
        ("-20.5-vs-20.5", ["-20.5", "20.5"]) // sign, digits identical
    ]

    /// Glyph, sign, separator and decoration coverage. Grouped so the report can
    /// answer "which CLASS of character breaks", not only "which string".
    private static let coverageCases: [(rendered: String, truth: String, group: String)] = {
        var cases: [(String, String, String)] = []
        for digit in "0123456789" {
            cases.append((String(digit), String(digit), "digit"))
        }
        cases += [
            // Separator in every position it can occupy on a small display.
            ("0.5", "0.5", "decimalPoint"),
            (".5", ".5", "decimalPoint"),
            // Sign. `+` is display decoration only: the recorded value carries
            // no plus, so truth drops it while the render keeps it.
            ("-5", "-5", "negativeSign"),
            ("-0.5", "-0.5", "negativeSign"),
            ("+5", "5", "positiveSign"),
            ("+0.5", "0.5", "positiveSign"),
            // Decoration the reading must survive without absorbing it.
            ("90.0°", "90.0", "degreeSymbol"),
            ("90.0C", "90.0", "unit"),
            ("12.3V", "12.3", "unit"),
            // Leading zeros: preserved as written by `FormatValidator`, so a
            // dropped one is a digit error and not a formatting nicety.
            ("08", "08", "leadingZero"),
            ("008", "008", "leadingZero"),
            ("0.80", "0.80", "leadingZero"),
            ("00.8", "00.8", "leadingZero"),
            // Trailing zeros: significant on an instrument display, and the
            // digits that make `1.00` and `100` indistinguishable once the
            // separator is lost.
            ("80", "80", "trailingZero"),
            ("800", "800", "trailingZero"),
            ("8.0", "8.0", "trailingZero"),
            ("8.00", "8.00", "trailingZero")
        ]
        return cases.map { (rendered: $0.0, truth: $0.1, group: $0.2) }
    }()

    /// Rendering conditions for the ambiguity sweep.
    ///
    /// `faint` and `ghosted` are the generator's real degradation knobs aimed at
    /// the segment question: `contrast` collapses glyph/background separation
    /// (a fading LCD, where a weakly driven segment is the first thing to go),
    /// and `ghosting` draws the "all segments on" `8` residue behind the glyphs
    /// at ~0.43 alpha — unlit segments faintly visible, which is precisely how a
    /// reader turns a `0` into an `8`. The `sans` row is a CONTROL: same strings,
    /// same optics, proportional glyphs, so the report separates "this string is
    /// hard" from "this FONT is hard".
    private static let ambiguityVariants: [Variant] = {
        var faint = DisplayAugmentation.clean
        faint.contrast = 0.35
        var ghosted = DisplayAugmentation.clean
        ghosted.ghosting = 0.85
        var cleanInverted = DisplayAugmentation.clean
        cleanInverted.polarityInverted = true
        return [
            Variant(name: "7seg-clean", style: .sevenSegment, augmentation: .clean),
            Variant(name: "7seg-moderate", style: .sevenSegment, augmentation: .moderate),
            Variant(name: "7seg-faint", style: .sevenSegment, augmentation: faint),
            Variant(name: "7seg-ghosted", style: .sevenSegment, augmentation: ghosted),
            Variant(name: "7seg-inverted", style: .sevenSegment, augmentation: cleanInverted),
            Variant(name: "sans-clean", style: .sans, augmentation: .clean)
        ]
    }()

    /// Coverage runs on fewer conditions than the ambiguity sweep — the question
    /// there is which CHARACTERS survive, not how they degrade.
    private static let coverageVariants: [Variant] = [
        Variant(name: "7seg-clean", style: .sevenSegment, augmentation: .clean),
        Variant(name: "7seg-moderate", style: .sevenSegment, augmentation: .moderate),
        Variant(name: "sans-clean", style: .sans, augmentation: .clean)
    ]

    override func setUp() {
        super.setUp()
        // ~180 Vision `.accurate` passes (the concurrent `.fast` rescue hides
        // inside them) plus a 960x400 render each, on a Debug build.
        executionTimeAllowance = 900
    }

    // MARK: - Sweep 1: the ambiguity pairs

    func testAmbiguityPairSweep() async throws {
        let generator = try SyntheticDisplayGenerator()
        let engine = OCRManager()
        let clock = ContinuousClock()

        var outcomes: [ValidationOutcome] = []
        for (pair, members) in Self.ambiguityPairs {
            for member in members {
                let truth = Self.canonicalTruth(of: member)
                for variant in Self.ambiguityVariants {
                    let sweepCase = SweepCase(rendered: member, truth: truth,
                                              parameters: ["pair": pair,
                                                           "member": member,
                                                           "variant": variant.name,
                                                           "style": variant.style.rawValue])
                    outcomes.append(try await measure(sweepCase, variant: variant, sweep: "segment-ambiguity",
                                                      generator: generator, engine: engine, clock: clock))
                }
            }
        }

        let report = ValidationReport(sweep: "segment-ambiguity", outcomes: outcomes)
        print(report.summary(groupedBy: "variant"))
        print(defectBreakdown(report, by: "pair", title: "AMBIGUITY PAIR"))
        print(defectBreakdown(report, by: "variant", title: "RENDER VARIANT"))
        print(headlineRates(report))

        let expected = Self.ambiguityPairs.reduce(0) { $0 + $1.members.count } * Self.ambiguityVariants.count
        XCTAssertEqual(report.total, expected, "every pair member x variant must produce an outcome")
        XCTAssertTrue(outcomes.allSatisfy { !$0.id.isEmpty }, "every outcome must be replayable from its id")
        XCTAssertTrue(outcomes.allSatisfy { $0.durationMS > 0 }, "every engine call must take measurable time")

        // Only an unusable engine skips. A LOW rate is a result and is reported;
        // no rate is asserted, because Vision's measured seven-segment ceiling
        // (14.6% `.accurate`, 41.7% dual-pass) is below any threshold worth
        // pinning.
        try XCTSkipIf(report.detectionRate == 0,
                      "Vision returned no candidates for any case — engine unavailable in this environment")
    }

    // MARK: - Sweep 2: glyph, sign, separator and decoration coverage

    func testGlyphAndSeparatorCoverageSweep() async throws {
        let generator = try SyntheticDisplayGenerator()
        let engine = OCRManager()
        let clock = ContinuousClock()

        var outcomes: [ValidationOutcome] = []
        for coverage in Self.coverageCases {
            let truth = Self.canonicalTruth(of: coverage.truth)
            for variant in Self.coverageVariants {
                let sweepCase = SweepCase(rendered: coverage.rendered, truth: truth,
                                          parameters: ["group": coverage.group,
                                                       "rendered": coverage.rendered,
                                                       "variant": variant.name,
                                                       "style": variant.style.rawValue])
                outcomes.append(try await measure(sweepCase, variant: variant, sweep: "segment-coverage",
                                                  generator: generator, engine: engine, clock: clock))
            }
        }

        let report = ValidationReport(sweep: "segment-coverage", outcomes: outcomes)
        print(report.summary(groupedBy: "variant"))
        print(defectBreakdown(report, by: "group", title: "CHARACTER CLASS"))
        print(defectBreakdown(report, by: "rendered", title: "RENDERED STRING"))
        print(headlineRates(report))

        XCTAssertEqual(report.total, Self.coverageCases.count * Self.coverageVariants.count,
                       "every coverage case x variant must produce an outcome")
        try XCTSkipIf(report.detectionRate == 0,
                      "Vision returned no candidates for any case — engine unavailable in this environment")
    }

    // MARK: - Sweep 3: per-segment failure

    /// What a FAILED SEGMENT does to the reading, measured with the
    /// deterministic `SevenSegmentSampler` rather than Vision — the question is
    /// which digit a broken glyph becomes, and a reader that answers "nothing"
    /// for most clean glyphs cannot answer it.
    ///
    /// LIMITATION, stated plainly: `SyntheticDisplayGenerator` renders whole
    /// glyphs from the DSEG7 font and has NO per-segment control. Segment
    /// failure is therefore applied here, after rendering, by compositing over
    /// the segment's region of the glyph envelope — fully (a dead segment) or
    /// partially (a weakly driven one). That is a geometric approximation of a
    /// segment failure, not a font-level one, so the sweep VERIFIES its own
    /// manipulation: for the `missing` mode it asserts the sampler's measured
    /// segment pattern lost exactly the targeted bit. A dropout that did not
    /// actually drop the segment fails the test rather than quietly reporting a
    /// meaningless recognition.
    func testSegmentDropoutSweep() throws {
        let generator = try SyntheticDisplayGenerator()
        let sampler = SevenSegmentSampler()
        // 2x the generator's default tile so a segment rectangle lands on whole
        // pixels; the sampler is resolution-independent.
        let tileSize = CGSize(width: 64, height: 96)
        let cell = NormalizedROI(x: 0, y: 0, width: 1, height: 1)

        // The envelope comes from '8' — every segment lit — and is reused for
        // every digit. Per-digit ink boxes cannot serve: DSEG7 is monospaced so
        // all ten glyphs share one envelope, but '1' lights only b and c, whose
        // ink box is a narrow bar. Placing b at "the right edge of the ink box"
        // there covers a sliver of the bar instead of the segment, and the
        // dropout silently does nothing.
        let envelopeTile = try generator.digitTile(character: "8", style: .sevenSegment,
                                                   augmentation: .clean, size: tileSize)
        let envelope = try XCTUnwrap(Self.inkBoundingBox(of: envelopeTile),
                                     "the '8' tile must contain ink to define the segment envelope")

        var outcomes: [ValidationOutcome] = []
        var baselinePatterns: [Character: UInt8] = [:]
        let clock = ContinuousClock()

        for digit in "0123456789" {
            let clean = try generator.digitTile(character: digit, style: .sevenSegment,
                                                augmentation: .clean, size: tileSize)
            let baseline = sampler.readDigit(in: clean, cell: cell)
            // The sweep's precondition: without it, a changed reading below
            // would not be attributable to the dropped segment.
            XCTAssertEqual(baseline.digit, digit,
                           "undegraded '\(digit)' must decode before its segments are broken")
            baselinePatterns[digit] = baseline.segmentPattern

            for segment in Segment.allCases where baseline.segmentPattern & segment.bit != 0 {
                for mode in SegmentFailure.allCases {
                    let tile = try generator.digitTile(character: digit, style: .sevenSegment,
                                                       augmentation: .clean, size: tileSize)
                    let erased = Self.degrade(tile, segment: segment,
                                              retaining: mode.retainedInk, envelope: envelope)
                    XCTAssertGreaterThan(erased, 0,
                                         "'\(digit)' segment \(segment.name) \(mode.rawValue): "
                                             + "the manipulation changed no pixels")

                    let start = clock.now
                    let reading = sampler.readDigit(in: tile, cell: cell)
                    let elapsed = Self.milliseconds(clock.now - start)

                    if mode == .missing {
                        // Validates the MANIPULATION independently of the
                        // reader: after a full erase the segment's region must
                        // hold no ink at all.
                        XCTAssertEqual(Self.residualInk(tile, segment: segment, envelope: envelope), 0,
                                       "'\(digit)' segment \(segment.name) still has ink after erasure")
                        if digit == "1" {
                            // CHARACTERIZED BLIND SPOT. `SevenSegmentSampler`
                            // decodes '1' by aspect ratio — a narrow ink box
                            // short-circuits to 0x06 without any segment ever
                            // being sampled. So killing b or c leaves the
                            // remaining bar narrow, the shortcut still fires,
                            // and a HALF-DEAD '1' is indistinguishable from a
                            // healthy one. Pinned rather than excluded: this is
                            // the one digit whose segment failures the reader
                            // cannot see.
                            XCTAssertEqual(reading.segmentPattern, 0x06,
                                           "'1' with segment \(segment.name) erased is expected to keep "
                                               + "reading 0x06 via the aspect-ratio shortcut")
                        } else {
                            XCTAssertEqual(reading.segmentPattern & segment.bit, 0,
                                           "'\(digit)' segment \(segment.name) was erased but still reads lit "
                                               + "(pattern 0x\(String(reading.segmentPattern, radix: 16)))")
                        }
                    }

                    let predicted = reading.digit.map(String.init)
                    outcomes.append(ValidationOutcome(
                        id: "segment-dropout/\(digit)/\(segment.name)/\(mode.rawValue)",
                        sweep: "segment-dropout",
                        parameters: ["digit": String(digit),
                                     "segment": segment.name,
                                     "mode": mode.rawValue,
                                     "transition": "\(digit)->\(predicted ?? "-")"],
                        truth: String(digit),
                        predicted: predicted,
                        verdict: ReadingComparison.verdict(truth: String(digit), predicted: predicted),
                        geometry: nil,
                        confidence: reading.confidence,
                        durationMS: elapsed))
                }
            }
        }

        let report = ValidationReport(sweep: "segment-dropout", outcomes: outcomes)
        print(report.summary(groupedBy: "segment"))
        print(defectBreakdown(report, by: "segment", title: "BROKEN SEGMENT"))
        print(defectBreakdown(report, by: "mode", title: "FAILURE MODE"))
        print(transitionTable(outcomes))
        print("  measured DSEG7 patterns: "
              + "0123456789".map { "\($0)=0x\(String(baselinePatterns[$0] ?? 0, radix: 16))" }
                  .joined(separator: " "))

        XCTAssertFalse(outcomes.isEmpty, "the dropout sweep must measure at least one segment failure")
        XCTAssertEqual(baselinePatterns.count, 10, "every digit must contribute a baseline pattern")
    }

    // MARK: - Font coverage

    /// Which of the sweep's characters the bundled DSEG7 face actually carries.
    /// A missing glyph renders as `.notdef` and would be scored as a
    /// recognition failure that is really a fixture gap, so the gap is measured
    /// and named here instead.
    func testDSEG7CoversTheSweepCharacters() throws {
        let bundle = Bundle(for: SyntheticDisplayGenerator.self)
        let url = try XCTUnwrap(bundle.url(forResource: "DSEG7Classic-Regular", withExtension: "ttf")
                                ?? bundle.url(forResource: "DSEG7Classic-Regular", withExtension: "ttf",
                                              subdirectory: "Fonts"),
                                "DSEG7Classic-Regular.ttf must be bundled with the test target")
        let data = try XCTUnwrap(try? Data(contentsOf: url))
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let cgFont = try XCTUnwrap(CGFont(provider))
        let font = CTFontCreateWithGraphicsFont(cgFont, 32, nil, nil)

        var present: [Character] = []
        var missing: [Character] = []
        for character in "0123456789.,-+°CFV" {
            var units = Array(String(character).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            let mapped = CTFontGetGlyphsForCharacters(font, &units, &glyphs, units.count)
            if mapped && glyphs.allSatisfy({ $0 != 0 }) { present.append(character) }
            else { missing.append(character) }
        }
        print("=== DSEG7 GLYPH COVERAGE ===")
        print("  present: \(String(present))")
        print("  missing: \(String(missing))")

        // The numeric alphabet is a hard requirement of the fixture; decoration
        // is not, and whatever is absent is named above rather than assumed.
        for required in "0123456789.-" {
            XCTAssertTrue(present.contains(required),
                          "DSEG7 must provide '\(required)' — the sweep renders it as ground truth")
        }
    }

    // MARK: - Measurement

    private func measure(_ sweepCase: SweepCase,
                         variant: Variant,
                         sweep: String,
                         generator: SyntheticDisplayGenerator,
                         engine: any OCREngine,
                         clock: ContinuousClock) async throws -> ValidationOutcome {
        let sample = try generator.lineSample(text: sweepCase.rendered,
                                              style: variant.style,
                                              augmentation: variant.augmentation,
                                              augmentationName: variant.name,
                                              size: Self.renderSize)
        let start = clock.now
        // The whole buffer IS the display, as in `RecognitionBenchmark`.
        let candidates = (try? await engine.recognize(in: sample.pixelBuffer,
                                                      regionOfInterest: nil)) ?? []
        let elapsed = Self.milliseconds(clock.now - start)

        let reading = Self.pipelineReading(candidates)
        var parameters = sweepCase.parameters
        parameters["truth"] = sweepCase.truth
        return ValidationOutcome(id: "\(sweep)/\(variant.name)/\(sweepCase.rendered)",
                                 sweep: sweep,
                                 parameters: parameters,
                                 truth: sweepCase.truth,
                                 predicted: reading?.text,
                                 verdict: ReadingComparison.verdict(truth: sweepCase.truth,
                                                                    predicted: reading?.text),
                                 geometry: nil,
                                 confidence: reading?.confidence ?? 0,
                                 durationMS: elapsed)
    }

    /// What the pipeline would RECORD: the first candidate, in engine-preferred
    /// order, that `FormatValidator` resolves to a number — the same choice the
    /// downstream picker makes, so the sweep scores the shipping behaviour and
    /// not a best-of-all-hypotheses upper bound. The reading is taken as
    /// WRITTEN (separator canonicalized to `.`, trailing zeros preserved, unit
    /// and `+` stripped), which is what makes the separator scorable.
    private static func pipelineReading(_ candidates: [OCRCandidate]) -> (text: String, confidence: Float)? {
        for candidate in candidates {
            if case .number(let reading) = FormatValidator.extractReading(from: candidate.text) {
                return (reading.text, candidate.confidence)
            }
        }
        return nil
    }

    /// Ground truth put through the same canonicalization as the prediction, so
    /// a formatting convention (`+5` recording as `5`) can never masquerade as a
    /// digit error. Labels that do not parse — none currently do — fall back to
    /// themselves.
    private static func canonicalTruth(of label: String) -> String {
        if case .number(let reading) = FormatValidator.extractReading(from: label) { return reading.text }
        return label
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) * 1e-15
    }

    // MARK: - Segment failure model

    /// The seven canonical segments, with the region each occupies expressed as
    /// fractions of the GLYPH ENVELOPE — the ink box of a fully lit '8', which
    /// is what stays fixed as the generator centres a ~0.6-height glyph and is
    /// shared by all ten digits because DSEG7 is monospaced.
    private enum Segment: Int, CaseIterable {
        case a = 0, b, c, d, e, f, g

        var bit: UInt8 { UInt8(1) << UInt8(rawValue) }

        var name: String {
            switch self {
            case .a: return "a-top"
            case .b: return "b-upperRight"
            case .c: return "c-lowerRight"
            case .d: return "d-bottom"
            case .e: return "e-lowerLeft"
            case .f: return "f-upperLeft"
            case .g: return "g-middle"
            }
        }

        /// Deliberately overshoots the envelope on the outer edge and stops
        /// short of the shared corners on the inner one: a segment must be fully
        /// covered while its neighbours' end caps survive, which is what the
        /// per-case pattern assertion checks.
        var region: CGRect {
            switch self {
            case .a: return CGRect(x: 0.18, y: -0.05, width: 0.64, height: 0.20)
            case .b: return CGRect(x: 0.82, y: 0.08, width: 0.23, height: 0.34)
            case .c: return CGRect(x: 0.82, y: 0.58, width: 0.23, height: 0.34)
            case .d: return CGRect(x: 0.18, y: 0.85, width: 0.64, height: 0.20)
            case .e: return CGRect(x: -0.05, y: 0.58, width: 0.23, height: 0.34)
            case .f: return CGRect(x: -0.05, y: 0.08, width: 0.23, height: 0.34)
            case .g: return CGRect(x: 0.18, y: 0.43, width: 0.64, height: 0.14)
            }
        }
    }

    /// Three illumination levels for the failing segment, straddling the
    /// midpoint threshold `SevenSegmentSampler` derives from the cell's own
    /// luminance range. Measured on the clean DSEG7 tiles: at 0.35 the reader is
    /// indistinguishable from a dead segment (identical verdicts on all 50
    /// cases), at 0.65 it decodes every digit correctly — so the sampler's
    /// segment cliff sits between 35% and 65% of full drive, with no measured
    /// intermediate regime.
    private enum SegmentFailure: String, CaseIterable {
        case missing
        case faint
        case dim

        var retainedInk: Double {
            switch self {
            case .missing: return 0
            case .faint: return 0.35
            case .dim: return 0.65
            }
        }
    }

    /// Blends `segment`'s region of the glyph toward the tile background,
    /// keeping `retained` of the original ink. Returns the number of pixels it
    /// actually changed, so a manipulation that silently did nothing is
    /// detectable. Operates on 32BGRA (the project-wide capture format).
    @discardableResult
    private static func degrade(_ buffer: CVPixelBuffer,
                                segment: Segment,
                                retaining retained: Double,
                                envelope: CGRect) -> Int {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        // The corner is background by construction: the generator centres the
        // glyph and both palettes fill the field first.
        let background = (pointer[0], pointer[1], pointer[2])

        guard let box = pixelRegion(of: segment, in: envelope, width: width, height: height) else { return 0 }

        var changed = 0
        for y in box.minY..<box.maxY {
            let row = pointer + y * bytesPerRow
            for x in box.minX..<box.maxX {
                let pixel = row + x * 4
                let before = (pixel[0], pixel[1], pixel[2])
                pixel[0] = blend(before.0, toward: background.0, retaining: retained)
                pixel[1] = blend(before.1, toward: background.1, retaining: retained)
                pixel[2] = blend(before.2, toward: background.2, retaining: retained)
                if (pixel[0], pixel[1], pixel[2]) != before { changed += 1 }
            }
        }
        return changed
    }

    /// Pixels inside `segment`'s region that still differ from the tile
    /// background. The tolerance is generous next to the clean DSEG7 palette's
    /// ~170-level glyph/background separation, so it counts real ink and not
    /// resampling fringe.
    private static func residualInk(_ buffer: CVPixelBuffer,
                                    segment: Segment,
                                    envelope: CGRect,
                                    tolerance: Double = 30) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        func luminance(_ pixel: UnsafeMutablePointer<UInt8>) -> Double {
            0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
        }
        let background = luminance(pointer)

        guard let box = pixelRegion(of: segment, in: envelope, width: width, height: height) else { return 0 }

        var count = 0
        for y in box.minY..<box.maxY {
            let row = pointer + y * bytesPerRow
            for x in box.minX..<box.maxX where abs(luminance(row + x * 4) - background) > tolerance {
                count += 1
            }
        }
        return count
    }

    /// `segment.region` resolved to pixel bounds inside a tile, clamped. nil
    /// when the clamp leaves nothing.
    private static func pixelRegion(of segment: Segment, in envelope: CGRect,
                                    width: Int, height: Int) -> (minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let region = segment.region
        let minX = max(0, Int((envelope.minX + region.minX * envelope.width).rounded()))
        let maxX = min(width, Int((envelope.minX + region.maxX * envelope.width).rounded()))
        let minY = max(0, Int((envelope.minY + region.minY * envelope.height).rounded()))
        let maxY = min(height, Int((envelope.minY + region.maxY * envelope.height).rounded()))
        guard minX < maxX, minY < maxY else { return nil }
        return (minX, maxX, minY, maxY)
    }

    private static func blend(_ value: UInt8, toward background: UInt8, retaining retained: Double) -> UInt8 {
        let mixed = Double(background) + (Double(value) - Double(background)) * retained
        return UInt8(max(0, min(255, mixed.rounded())))
    }

    /// Pixel-space ink box of a 32BGRA tile.
    private static func inkBoundingBox(of buffer: CVPixelBuffer) -> CGRect? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        return inkBoundingBox(base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidth(buffer),
                              height: CVPixelBufferGetHeight(buffer),
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
    }

    /// Tightest box containing pixels that differ from the corner background by
    /// more than a third of the tile's own luminance range. Polarity-agnostic:
    /// it measures distance from background rather than assuming dark ink.
    private static func inkBoundingBox(_ pointer: UnsafeMutablePointer<UInt8>,
                                       width: Int, height: Int, bytesPerRow: Int) -> CGRect? {
        func luminance(_ pixel: UnsafeMutablePointer<UInt8>) -> Double {
            0.114 * Double(pixel[0]) + 0.587 * Double(pixel[1]) + 0.299 * Double(pixel[2])
        }
        let background = luminance(pointer)
        var maximumDelta = 0.0
        for y in 0..<height {
            let row = pointer + y * bytesPerRow
            for x in 0..<width {
                maximumDelta = max(maximumDelta, abs(luminance(row + x * 4) - background))
            }
        }
        guard maximumDelta > 1 else { return nil }
        let threshold = maximumDelta / 3

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = pointer + y * bytesPerRow
            for x in 0..<width where abs(luminance(row + x * 4) - background) > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    // MARK: - Reporting

    /// Per-group DEFECT MIX. `ValidationReport.summary(groupedBy:)` ranks groups
    /// by exact rate, which cannot distinguish the two failures this project
    /// cares about, so the columns here split them: `dec-only` is every digit
    /// right with the separator wrong, `digit` is a glyph decoded wrong. Rows
    /// are ordered worst-exact-first so the failing group leads.
    private func defectBreakdown(_ report: ValidationReport, by parameter: String, title: String) -> String {
        let groups = Dictionary(grouping: report.outcomes.filter { $0.parameters[parameter] != nil }) {
            $0.parameters[parameter]!
        }
        let widths = [16, 4, 8, 10, 8, 6, 6, 7, 6]
        let header = ["dec-only", "digit", "miss", "spur", "mispl", "none"]
        var lines = ["--- \(report.sweep) by \(title) ---",
                     row([parameter, "N", "exact"] + header, widths)]

        var rows: [(value: String, exact: Double, cells: [String])] = []
        for (value, group) in groups {
            func count(_ verdict: ReadingVerdict) -> Int { group.filter { $0.verdict == verdict }.count }
            let n = Double(group.count)
            let exact = Double(count(.exact)) / n
            let decimalOnly = Double(group.filter { $0.verdict.isDecimalOnlyFailure }.count) / n
            let cells: [String] = [value,
                                   String(group.count),
                                   percent(exact),
                                   percent(decimalOnly),
                                   percent(Double(count(.digitError)) / n),
                                   String(count(.decimalMissing)),
                                   String(count(.decimalSpurious)),
                                   String(count(.decimalMisplaced)),
                                   String(count(.notDetected))]
            rows.append((value, exact, cells))
        }
        rows.sort { $0.exact == $1.exact ? $0.value < $1.value : $0.exact < $1.exact }

        for entry in rows { lines.append(row(entry.cells, widths)) }
        if let worst = rows.first {
            lines.append("  worst \(parameter): \(worst.value) at \(percent(worst.exact)) exact")
        }
        return lines.joined(separator: "\n")
    }

    /// The two rates the task turns on, stated once, unmixed.
    private func headlineRates(_ report: ValidationReport) -> String {
        let digitErrors = report.outcomes.filter { $0.verdict == .digitError }.count
        let decimalOnly = report.outcomes.filter { $0.verdict.isDecimalOnlyFailure }.count
        let missing = report.outcomes.filter { $0.verdict == .decimalMissing }.count
        return ["--- \(report.sweep) HEADLINE ---",
                "  decimal-only failures  \(percent(Double(decimalOnly) / Double(max(1, report.total)))) "
                    + "(\(decimalOnly)/\(report.total)), of which decimalMissing = \(missing)",
                "  digit errors           \(percent(Double(digitErrors) / Double(max(1, report.total)))) "
                    + "(\(digitErrors)/\(report.total))"].joined(separator: "\n")
    }

    /// Which digit each broken glyph BECAME. The dropout sweep's actual product:
    /// `8` losing segment g reading as `0` is the mechanism behind the `8-vs-0`
    /// pair, and this is where it shows up by name.
    private func transitionTable(_ outcomes: [ValidationOutcome]) -> String {
        var lines = ["--- segment-dropout TRANSITIONS ---"]
        let byDigit = Dictionary(grouping: outcomes) { $0.parameters["digit"] ?? "?" }
        for digit in byDigit.keys.sorted() {
            let entries = (byDigit[digit] ?? [])
                .sorted { ($0.parameters["segment"] ?? "") < ($1.parameters["segment"] ?? "") }
                .map { "\($0.parameters["segment"]?.prefix(1) ?? "?")"
                    + "/\($0.parameters["mode"]?.prefix(2) ?? "?")"
                    + "->\($0.predicted ?? "nil")" }
            lines.append("  \(digit): " + entries.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value * 100) }

    /// First cell left-justified (it is the label), the rest right-justified.
    private func row(_ cells: [String], _ widths: [Int]) -> String {
        var text = "  "
        for (index, cell) in cells.enumerated() {
            let width = index < widths.count ? widths[index] : 8
            let clipped = cell.count > width - 1 ? String(cell.prefix(width - 1)) : cell
            let padding = String(repeating: " ", count: width - 1 - clipped.count)
            text += index == 0 ? clipped + padding + " " : padding + clipped + " "
        }
        return text
    }
}
