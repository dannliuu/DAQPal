//
//  SeparatorLedgerTests.swift
//  DAQPalTests
//
//  WS-B B0.5 — THE EVIDENCE GATE for spec §11A decimal integrity.
//
//  THE PRODUCT PROMISE THIS MEASURES
//  "When DAQPal cannot establish that a reading is correct, it refuses or flags
//   it rather than silently exporting an incorrect number."
//  A wrong decimal position is a silent factor-of-ten error in exported
//  measurement data. Refusal is cheap. Wrong-and-accepted is catastrophic.
//
//  WHAT THIS FILE IS, AND WHY IT IS NOT A UNIT TEST
//  `DecimalIntegrityTests` pins the PARSER's vectors; `TemporalConsensusTests`
//  pins the LEDGER's rules. Neither can answer the only question that matters
//  for the promise above: across a realistic frame sequence, how many readings
//  does the SHIPPING pipeline export that are wrong? That is a property of the
//  whole chain — `FormatValidator` → `ConfidenceEngine` → `TemporalConsensus` →
//  the consensus demotion in `MeasurementProcessor.finalize` — and of the ORDER
//  frames arrive in. So this harness drives the real `MeasurementProcessor`.
//
//  WHY A SCRIPTED ENGINE AND NOT RENDERED PIXELS. The defects under test are
//  properties of the TEXT sequence ("the dot stops surviving at frame 30"), and
//  the recognizer is exactly the thing being held constant. Rendering pixels and
//  hoping Vision transcribes them a particular way is not a controlled
//  experiment: it measures Vision, which drifts between OS revisions, instead of
//  measuring the gates. The injected engine changes NOTHING downstream of
//  `OCRManager` — every gate, every constant and every demotion below it is the
//  shipping code path.
//
//  WHY NOT REIMPLEMENT THE FINALIZE CHAIN IN THE TEST. It would then measure a
//  COPY of the pipeline, and a fix landed in `MeasurementProcessor.finalize`
//  would not move these numbers. The harness must exercise the shipping
//  `finalize`, including the consensus demotion, or its ledger is fiction.
//
//  DETERMINISM. No `Date()`, no sleeps, no randomness. Frame index travels on
//  the pixel buffer's attachment rather than in an engine-side counter, because
//  `MeasurementProcessor` fans recognition into a task group — a counter would
//  make the transcript depend on task scheduling and the ledger would stop being
//  reproducible.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class SeparatorLedgerTests: XCTestCase {

    // MARK: - Scripted recognizer

    /// A pure function of the frame: `script[frameIndex]`. Holds no cursor.
    private final class ScriptedOCR: OCREngine, @unchecked Sendable {
        static let frameIndexKey = "DAQPalScriptedFrameIndex"

        private let script: [[OCRCandidate]]

        init(script: [[OCRCandidate]]) { self.script = script }

        func recognize(in pixelBuffer: CVPixelBuffer,
                       regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
            // `OCREngine` receives only the pixel buffer, and the script must be
            // addressed by FRAME, not by call order — see the header note on
            // determinism.
            let attached = CVBufferCopyAttachment(pixelBuffer,
                                                  ScriptedOCR.frameIndexKey as CFString,
                                                  nil) as? NSNumber
            guard let index = attached?.intValue,
                  index >= 0, index < script.count else { return [] }
            return script[index]
        }
    }

    /// 32×32 blank BGRA. Never read: every scenario runs
    /// `DisplayFormat.unconstrained`, so `constrainToFormat == false` and the
    /// seven-segment `samplerCrossCheck` is skipped entirely.
    private func makeFrame(index: Int) throws -> TimestampedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 32, 32,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            XCTFail("CVPixelBufferCreate failed (\(status)) — a gate whose failure mode is 'skipped' is not a gate")
            throw NSError(domain: "SeparatorLedger", code: Int(status))
        }
        CVBufferSetAttachment(buffer, ScriptedOCR.frameIndexKey as CFString,
                              NSNumber(value: index), .shouldPropagate)
        // 30 fps, so 90 frames span 3.0 s and `TemporalConsensus.windowHorizon`
        // (2.0 s) expires only across S7's blackout — which is what that row is
        // for.
        return TimestampedFrame(pixelBuffer: buffer, timestamp: Double(index) / 30.0)
    }

    // MARK: - Scenarios

    private struct Scenario {
        let name: String
        /// What the instrument actually displays on each frame.
        let truth: [String]
        /// What the recognizer transcribes; `nil` = it returned nothing.
        let ocr: [String?]
        /// Diagnostic rows are PRINTED but not GATED — see S9.
        var isDiagnostic = false
        /// Wrong-and-accepted readings expected in the D10 COLD-START WINDOW —
        /// the frames before the recognizer has EVER transcribed a separator for
        /// this device. Pinned to an exact number so it can neither grow
        /// unnoticed nor be quietly written off. See `Row` for why this window
        /// is scored separately.
        var expectedColdStartWrong = 0

        /// Index of the first frame whose transcript contains a separator, or
        /// `nil` if the recognizer never produces one.
        var firstSeparatorFrame: Int? {
            ocr.firstIndex { $0?.contains(where: { $0 == "." || $0 == "," }) ?? false }
        }
    }

    private static let frameCount = 90

    private static func constant(_ text: String) -> [String] {
        Array(repeating: text, count: frameCount)
    }

    private static func constantOCR(_ text: String?) -> [String?] {
        Array(repeating: text, count: frameCount)
    }

    /// Switches from `first` to `second` at `at`.
    private static func switching(_ first: String?, to second: String?, at index: Int) -> [String?] {
        (0..<frameCount).map { $0 < index ? first : second }
    }

    private static func switching(_ first: String, to second: String, at index: Int) -> [String] {
        (0..<frameCount).map { $0 < index ? first : second }
    }

    /// The eight gated scenarios plus one diagnostic.
    ///
    /// EVERY scenario runs `DisplayFormat.unconstrained` — the shipping default
    /// from `Device.makeDefault`. This is load-bearing, not convenience:
    /// `FormatValidator.undeclaredIntegerCertainty` is reachable ONLY on the
    /// lenient Mode-3 path (`decompose`, `declared: false`). A DECLARED integer
    /// display scores `readSeparatorCertainty`, and a declared `decimalPosition`
    /// already refuses a missing separator outright. A ledger built on
    /// constrained formats would measure 0 wrong and prove nothing.
    private static let scenarios: [Scenario] = [
        // S1 — the healthy path. Any refusal here is a tax the fix must not levy.
        Scenario(name: "S1 stable decimal",
                 truth: constant("80.8"),
                 ocr: constantOCR("80.8")),

        // S2 — H3's headline cost row, REPORTED SEPARATELY. Kept clean (no
        // injected noise) so the genuine-integer cost reads as an unambiguous
        // number rather than one needing a caveat.
        Scenario(name: "S2 genuine integer [H3]",
                 truth: constant("1750"),
                 ocr: constantOCR("1750")),

        // S3 — THE HEADLINE. The display never changes; the dot simply stops
        // surviving preprocessing at frame 30. Every accepted "808" here is a
        // silent 10x error in exported data.
        Scenario(name: "S3 dropped separator",
                 truth: constant("80.8"),
                 ocr: switching("80.8", to: "808", at: 30)),

        // S4 — the migration that must STAY permitted. Seeing a separator IS
        // evidence; this is the asymmetry's open direction. Its first 30 frames
        // are the D10 cold-start window: the display shows 80.8 throughout, the
        // dot does not survive until frame 30, and NOTHING downstream of
        // recognition can know that — see `Row`.
        Scenario(name: "S4 separator recovery",
                 truth: constant("80.8"),
                 ocr: switching("808", to: "80.8", at: 30),
                 expectedColdStartWrong: 30),

        // S5 — false-positive guard: a REAL decade change (autorange), same
        // digit count, separator read in both forms. Must survive.
        Scenario(name: "S5 legit decade change",
                 truth: switching("12.34", to: "123.4", at: 45),
                 ocr: switching("12.34", to: "123.4", at: 45)),

        // S6 — the leading-separator class. All 7 device-benchmark failures are
        // this shape: the display shows ".5", Vision transcribes the dot as a
        // bullet, the token grammar discards it, a bare 5 is parsed.
        Scenario(name: "S6 leading separator",
                 truth: constant(".5"),
                 ocr: switching(".5", to: "\u{2022}5", at: 15)),

        // S7 — intermittent dropout. Lost frames must refuse without corrupting
        // the anchor. The 20-frame blackout is 0.67 s — under `windowHorizon`,
        // so the anchor is defended rather than released.
        Scenario(name: "S7 intermittent dropout",
                 truth: constant("80.8"),
                 ocr: (0..<frameCount).map { (index: Int) -> String? in
                     (50...69).contains(index) || index % 6 == 5 ? nil : "80.8"
                 }),

        // S8 — warmup / cold start. No anchor exists to defend, so the ledger
        // cannot help: the most-digits picker returns the "345" FRAGMENT of
        // "12•345" and it becomes the thing everything else is measured against.
        Scenario(name: "S8 warmup / cold start",
                 truth: constant("12.345"),
                 ocr: (0..<frameCount).map { (index: Int) -> String? in
                     switch index {
                     case 0...1: nil
                     case 2...4: "12\u{2022}345"
                     default: "12.345"
                     }
                 }),

        // S9 — DIAGNOSTIC, NON-GATING. The mirror of S5: a legitimate decade
        // change INTO an integer form. Its OCR transcript is TEXT-IDENTICAL in
        // kind to S3's, so no rule operating on text can separate them. Present
        // to PRICE that impossibility (spec D10), printed with the others,
        // excluded from the assertion.
        Scenario(name: "S9 legit decade into integer [diagnostic]",
                 truth: switching("99.8", to: "998", at: 45),
                 ocr: switching("99.8", to: "998", at: 45),
                 isDiagnostic: true),
    ]

    // MARK: - Scoring

    /// One scenario's ledger.
    ///
    /// WHY WRONG-AND-ACCEPTED IS SPLIT IN TWO. Both halves are readings this app
    /// exported that were wrong — the split is not an excuse, it is a diagnosis,
    /// and both are printed.
    ///
    ///   `wrongAfterSeparatorSeen` — the GATED number. A separator has been
    ///   transcribed at least once for this device, so the pipeline HAS the
    ///   evidence needed to know that this display carries a decimal point, and
    ///   any wrong reading after that point is a gate that failed. This must be
    ///   zero.
    ///
    ///   `wrongInColdStartWindow` — frames before the recognizer has EVER
    ///   produced a separator for this device. Here "the display is an integer
    ///   display" and "the display's dot has not survived preprocessing yet" are
    ///   the SAME OBSERVATION, with no anchor, no prior and no pixel evidence to
    ///   appeal to. This is MASTER_PLAN D10 stated as a measurement: zero-config
    ///   decimal determination is impossible from Vision text on the target.
    ///   RANK 1–3 cannot move it, and only two things can: a user-declared
    ///   `DisplayFormat` (Mode 2), or a pixel-level separator verdict
    ///   (`DecimalRescue`, WS-B B1, currently unwired). The third option —
    ///   dropping `FormatValidator.undeclaredIntegerCertainty` below
    ///   `ConfidenceEngine.decimalVetoThreshold` so every undeclared bare
    ///   integer is refused — closes it by refusing an ENTIRE DEVICE CLASS
    ///   (S2 goes 90/90 correct → 0/90 refused) and is a B1 product decision,
    ///   not a RANK-1 side effect. It is pinned to an exact expected count so it
    ///   cannot grow unnoticed.
    private struct Row {
        let name: String
        let isDiagnostic: Bool
        let expectedColdStartWrong: Int
        var correct = 0
        var wrongInColdStartWindow = 0
        var wrongAfterSeparatorSeen = 0
        var refused = 0
        var verdicts: [ReadingVerdict: Int] = [:]
        var refusalReasons: [String: Int] = [:]
        var examples: [String] = []

        var wrongAndAccepted: Int { wrongInColdStartWindow + wrongAfterSeparatorSeen }
    }

    /// Runs one scenario through the real `MeasurementProcessor`.
    ///
    /// TWO SCORING PROPERTIES THAT ARE NOT INCIDENTAL:
    ///
    /// 1. Comparison is on the WRITTEN form, not the parsed `Double`. This is
    ///    what makes an H1 violation detectable: if any grammar or ledger ever
    ///    REWRITES a published value ("900" → "90.0"), it surfaces here as
    ///    wrong-and-accepted. A value-only comparison would hide it.
    /// 2. Refusal REASONS are tallied, not just counts. "Refused" is not
    ///    self-justifying — a DISPLAY_LOST and an AMBIGUOUS_DECIMAL are
    ///    different evidence, and a change that converts one into the other, or
    ///    refuses the right rows for the wrong reason, must be visible.
    private func run(_ scenario: Scenario) async throws -> Row {
        let script: [[OCRCandidate]] = scenario.ocr.map { text in
            guard let text else { return [] }
            return [OCRCandidate(text: text, confidence: 0.95)]
        }
        let processor = MeasurementProcessor(ocr: OCRManager(engine: ScriptedOCR(script: script)))
        let id = UUID()
        await processor.update(devices: [DeviceRecognitionConfig(id: id,
                                                                 roi: .defaultROI,
                                                                 format: .unconstrained)])

        var row = Row(name: scenario.name,
                      isDiagnostic: scenario.isDiagnostic,
                      expectedColdStartWrong: scenario.expectedColdStartWrong)
        let firstSeparatorFrame = scenario.firstSeparatorFrame
        for index in 0..<Self.frameCount {
            let frame = try makeFrame(index: index)
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[id] else {
                XCTFail("\(scenario.name): frame \(index) produced no measurement at all")
                continue
            }
            guard measurement.accepted else {
                row.refused += 1
                let reason = measurement.rejectionReason?.rawValue ?? "UNSPECIFIED"
                row.refusalReasons[reason, default: 0] += 1
                continue
            }
            let published = measurement.displayText ?? DisplayFormat.naturalString(measurement.value)
            let verdict = ReadingComparison.verdict(truth: scenario.truth[index], predicted: published)
            row.verdicts[verdict, default: 0] += 1
            if verdict.isCorrect {
                row.correct += 1
            } else {
                let coldStart = firstSeparatorFrame.map { index < $0 } ?? true
                if coldStart { row.wrongInColdStartWindow += 1 } else { row.wrongAfterSeparatorSeen += 1 }
                if row.examples.count < 3 {
                    row.examples.append("f\(index) truth \(scenario.truth[index]) "
                                        + "→ exported \(published) [\(verdict.rawValue)]"
                                        + (coldStart ? " {D10 cold start}" : ""))
                }
            }
        }
        return row
    }

    // MARK: - The gate

    /// The B0.5 evidence gate. ALWAYS prints the full ledger before asserting:
    /// a gate that fails without printing the cost is the thing H3 forbids, and
    /// an accept-rate-only report would let "refuses everything" read as an
    /// integrity win.
    func testSeparatorLedgerExportsNoWrongReadings() async throws {
        var rows: [Row] = []
        for scenario in Self.scenarios {
            rows.append(try await run(scenario))
        }

        var out = "\n=== SEPARATOR LEDGER (WS-B B0.5) — \(Self.frameCount) frames per scenario ===\n"
        out += "SYNTHETIC transcripts (spec D6): these are scripted OCR texts, NOT an\n"
        out += "instrument-accuracy claim. What they measure is the GATES.\n\n"
        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }
        for row in rows {
            let total = row.correct + row.wrongAndAccepted + row.refused
            out += pad(row.name, 42)
                + " correct \(row.correct)"
                + " | WRONG-ACCEPTED \(row.wrongAndAccepted)"
                + " (gate \(row.wrongAfterSeparatorSeen)"
                + " + D10 cold start \(row.wrongInColdStartWindow))"
                + " | refused \(row.refused)  (of \(total))\n"
            if !row.refusalReasons.isEmpty {
                let reasons = row.refusalReasons.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                out += "    refusals: \(reasons)\n"
            }
            let defects = row.verdicts.filter { !$0.key.isCorrect }
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { "\($0.key.rawValue)=\($0.value)" }
            if !defects.isEmpty { out += "    accepted defects: \(defects.joined(separator: " "))\n" }
            for example in row.examples { out += "    e.g. \(example)\n" }
            if row.isDiagnostic { out += "    [DIAGNOSTIC — printed, not gated]\n" }
        }
        print(out)

        for row in rows where !row.isDiagnostic {
            XCTAssertEqual(row.wrongAfterSeparatorSeen, 0,
                           "\(row.name): \(row.wrongAfterSeparatorSeen) wrong-and-accepted readings "
                           + "were exported AFTER a separator had been observed — the pipeline had "
                           + "the evidence and a gate failed. \(row.examples.joined(separator: "; "))")
            XCTAssertEqual(row.wrongInColdStartWindow, row.expectedColdStartWrong,
                           "\(row.name): the D10 cold-start window is pinned at "
                           + "\(row.expectedColdStartWrong); it must not grow, and if it SHRANK, "
                           + "say which change bought that and re-baseline this number rather than "
                           + "letting it drift. \(row.examples.joined(separator: "; "))")
        }

        // THE RECALL FLOOR. Without this the gate above is satisfied by a
        // pipeline that refuses EVERY frame — zero wrong-and-accepted is
        // trivially true when nothing is accepted at all. That is the same
        // defect as the yield floor MASTER_PLAN §1 adds to DoD-1/DoD-2, and it
        // is the failure mode this whole task is most likely to drift into,
        // because every change here makes the wrong-counts look better by
        // refusing more.
        //
        // Measured 2026-08-04 on the shipped B0.5 (ranks 1-2, rank 3 reverted).
        // These are FLOORS, not equalities: a change that recovers MORE correct
        // readings should pass. A change that recovers fewer must justify itself
        // here, in the diff, rather than passing quietly.
        let recallFloor: [String: Int] = [
            "S1 stable decimal": 90,      // clean stream, must not lose any
            "S2 genuine integer [H3]": 90, // integers still accepted — see the H3 note
            "S3 dropped separator": 30,
            "S4 separator recovery": 56,
            "S5 legit decade change": 86,
            "S6 leading separator": 15,
            "S7 intermittent dropout": 58,
            "S8 warmup / cold start": 85,
        ]
        for row in rows where !row.isDiagnostic {
            guard let floor = recallFloor[row.name] else {
                XCTFail("\(row.name) has no recall floor — every gated scenario needs one, or a "
                        + "refuse-everything regression passes this suite green")
                continue
            }
            XCTAssertGreaterThanOrEqual(
                row.correct, floor,
                "\(row.name): correct readings fell to \(row.correct), below the pinned floor "
                + "of \(floor). Refusing more is not automatically progress — this is the "
                + "over-refusal side of the trade and it must be argued, not absorbed.")
        }
    }

    // MARK: - Within-frame decade conflict (RANK 3)
    //
    // Two parseable readings of ONE frame that are a decimal shift of each other
    // are two mutually exclusive MAGNITUDES for the same field. The candidate
    // loop used to `break` at the first parse, so a contradicting second reading
    // was never even computed and nothing downstream could see it.
    //
    // This is a TRIPWIRE, not a present-tense fix. Measured over the synthetic
    // corpus and the one real fixture this repo owns, it currently catches
    // nothing and costs nothing — its value is forward-looking (a second engine,
    // a looser ROI, or a wired `SegmentCellScanner` producing a second reading).
    // Both halves of that belong in the report together.

    /// One frame's measurement under a scripted candidate list.
    private func measureOneFrame(candidates: [String]) async throws -> DAQPal.Measurement {
        let script = [candidates.map { OCRCandidate(text: $0, confidence: 0.95) }]
        let processor = MeasurementProcessor(ocr: OCRManager(engine: ScriptedOCR(script: script)))
        let id = UUID()
        await processor.update(devices: [DeviceRecognitionConfig(id: id,
                                                                 roi: .defaultROI,
                                                                 format: .unconstrained)])
        let result = await processor.process(frame: try makeFrame(index: 0))
        guard let measurement = result.readings[id] else {
            XCTFail("no measurement produced — a gate whose failure mode is 'skipped' is not a gate")
            throw NSError(domain: "SeparatorLedger", code: -1)
        }
        return measurement
    }

    // RANK-3 TESTS REMOVED 2026-08-04 with the code they covered.
    //
    // `testWithinFrameDecadeConflictIsRefused`,
    // `testTwoDifferentFieldsAreNotADecadeConflictAndThePickerIsUnchanged` and
    // `testZeroFormsAreNotADecadeConflict` pinned the within-frame decade
    // refusal in `MeasurementProcessor`, which was reverted — see the
    // REVERTED note there for the measured reasons.
    //
    // Note what these tests could NOT have caught, because it is the reason the
    // feature was reverted rather than tuned: every scenario in this file
    // scripts exactly ONE candidate per frame, so a rule that only fires on
    // MULTI-candidate frames is structurally unable to fire inside this gate.
    // The tests passed while the feature's real cost was invisible. Any
    // reinstatement must first extend this harness to script multi-candidate
    // frames, or it will reproduce exactly that blind spot.
}
