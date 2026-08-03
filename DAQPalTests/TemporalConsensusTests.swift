//
//  TemporalConsensusTests.swift
//  DAQPalTests
//
//  Spec §11A — the 808 / 80.8 flip-flop.
//
//  A temperature gun's decimal point is a few pixels; it survives
//  preprocessing only sometimes. Accepting `808` on the frame where the dot
//  was lost is a silent 10× error that every other gate waves through: the
//  digits are right, the order is right, the number parses, and once the
//  series shifts it is perfectly self-consistent to a value-distance temporal
//  filter. These tests pin the two behaviours that stop it — a decimal event
//  needs far more evidence than an ordinary update, and a window that cannot
//  agree says so instead of picking a side — while proving the guard does not
//  suppress genuine measurement change.
//
//  All timestamps are synthetic frame times. No Date(), no sleeps, no
//  randomness: every assertion is a pure function of the input sequence.
//

import XCTest
@testable import DAQPal

final class TemporalConsensusTests: XCTestCase {

    // MARK: - Fixtures

    /// Synthetic 30 fps frame presentation time.
    private func frameTime(_ index: Int) -> TimeInterval { Double(index) / 30.0 }

    /// One reading to feed the consensus.
    private struct Frame {
        let value: Double
        let text: String
        let decimalConfidence: Float
        let digitConfidence: Float
    }

    private func frame(_ text: String,
                       decimal: Float = 0.95,
                       digit: Float = 0.95) -> Frame {
        guard let value = Double(text) else {
            XCTFail("Test fixture text \(text) is not numeric")
            return Frame(value: .nan, text: text,
                         decimalConfidence: decimal, digitConfidence: digit)
        }
        return Frame(value: value, text: text,
                     decimalConfidence: decimal, digitConfidence: digit)
    }

    /// Feeds `frames` starting at frame index `startIndex` and returns every
    /// outcome, so a test can assert on any point in the sequence.
    @discardableResult
    private func feed(_ frames: [Frame],
                      into consensus: inout TemporalConsensus,
                      prior: InferredFormat? = nil,
                      startIndex: Int = 0) -> [TemporalConsensus.Outcome] {
        var outcomes: [TemporalConsensus.Outcome] = []
        for (offset, frame) in frames.enumerated() {
            outcomes.append(consensus.observe(value: frame.value,
                                              text: frame.text,
                                              decimalConfidence: frame.decimalConfidence,
                                              digitConfidence: frame.digitConfidence,
                                              formatPrior: prior,
                                              timestamp: frameTime(startIndex + offset)))
        }
        return outcomes
    }

    private func repeated(_ text: String,
                          _ count: Int,
                          decimal: Float = 0.95,
                          digit: Float = 0.95) -> [Frame] {
        (0..<count).map { _ in frame(text, decimal: decimal, digit: digit) }
    }

    // MARK: - THE HEADLINE TEST

    /// Direction 1: a stable `80.8` series interrupted by ONE `808` must not
    /// flip the published reading. This is the whole point of the type.
    func testSingleDroppedSeparatorDoesNotFlipStableReading() {
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("80.8", 5) + [frame("808")], into: &consensus)

        // The stable run publishes 80.8.
        XCTAssertEqual(outcomes[4].value, 80.8)
        XCTAssertEqual(outcomes[4].text, "80.8")

        // The spurious frame does NOT become the published reading, and the
        // decimal is not coerced away.
        let interrupted = outcomes[5]
        XCTAssertFalse(interrupted.isAmbiguous,
                       "one contradicting frame is noise, not a disagreement")
        XCTAssertEqual(interrupted.value, 80.8,
                       "a single 808 must never overwrite a stable 80.8 — that is the 10× error")
        XCTAssertEqual(interrupted.text, "80.8")
        XCTAssertEqual(consensus.anchoredText, "80.8")
    }

    /// Direction 2: a SUSTAINED `808` series with high decimal-rescue
    /// confidence must eventually migrate — the guard is a higher evidence bar,
    /// not a permanent lock. A display really can change format.
    func testSustainedDroppedSeparatorWithHighRescueConfidenceMigrates() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 5), into: &consensus)

        // The separator verdict is confident that there is genuinely no
        // separator on these frames (decimal rescue found no dot at high
        // certainty), which is the corroboration a decimal event requires.
        let outcomes = feed(repeated("808", 6, decimal: 0.95),
                            into: &consensus,
                            startIndex: 5)

        XCTAssertEqual(outcomes[0].value, 80.8, "first contradicting frame is still held off")
        let final = outcomes[outcomes.count - 1]
        XCTAssertEqual(final.value, 808)
        XCTAssertEqual(final.text, "808")
        XCTAssertEqual(consensus.anchoredText, "808")
        if case .ambiguous = final {
            XCTFail("sustained, corroborated evidence must resolve, not stay ambiguous")
        }
    }

    /// The same sustained series WITHOUT corroboration (the separator verdict is
    /// itself unsure) must not migrate. Evidence quality, not just repetition,
    /// is what buys a 10× change.
    func testSustainedDroppedSeparatorWithoutCorroborationDoesNotMigrate() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 5), into: &consensus)
        let outcomes = feed(repeated("808", 6, decimal: 0.4),
                            into: &consensus,
                            startIndex: 5)

        XCTAssertNotEqual(consensus.anchoredText, "808",
                          "an unsure separator verdict must not carry a 10× migration")
        // It never silently publishes 808 either — it either holds 80.8 or
        // reports the disagreement.
        for outcome in outcomes {
            XCTAssertNotEqual(outcome.value, 808,
                              "uncorroborated 808 must never be published as the reading")
        }
    }

    // MARK: - Rule 4: genuine change must still get through

    func testGradualRealChangePassesThroughAsChanging() {
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("80.8", 2)
                            + [frame("81.2"), frame("81.9"), frame("82.4")],
                            into: &consensus)

        for (index, expected) in [(2, 81.2), (3, 81.9), (4, 82.4)] {
            guard case .changing(let value, _, _) = outcomes[index] else {
                XCTFail("frame \(index) should be .changing, got \(outcomes[index])")
                continue
            }
            XCTAssertEqual(value, expected, accuracy: 1e-9)
        }
        XCTAssertEqual(consensus.anchoredValue, 82.4)
    }

    /// A ramp that crosses a digit-count boundary (99.8 → 100.2) is a real
    /// change, not a decimal event: the digit count changes, so no separator
    /// move can explain it.
    func testRampAcrossDigitBoundaryIsNotTreatedAsDecimalEvent() {
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("99.8", 2) + [frame("100.2"), frame("100.7")],
                            into: &consensus)
        XCTAssertEqual(outcomes[3].value, 100.7)
        XCTAssertFalse(outcomes[3].isAmbiguous)
    }

    // MARK: - Rule 5: ambiguity is a first-class result

    func testAlternatingFormsYieldAmbiguousRatherThanAnArbitraryPick() {
        var consensus = TemporalConsensus()
        let outcomes = feed([frame("808"), frame("80.8"),
                             frame("808"), frame("80.8"),
                             frame("808"), frame("80.8")],
                            into: &consensus)

        let final = outcomes[outcomes.count - 1]
        guard case .ambiguous(_, let candidates) = final else {
            return XCTFail("alternating 808/80.8 must be ambiguous, got \(final)")
        }
        XCTAssertEqual(candidates, [80.8, 808],
                       "both contenders are reported; neither is chosen")
        XCTAssertNil(consensus.anchoredText,
                     "a flip-flopping window must not anchor either side")

        // And it never published a value while flip-flopping past the first
        // provisional frame.
        for outcome in outcomes.dropFirst() {
            XCTAssertTrue(outcome.isAmbiguous,
                          "no side may be published while the window flip-flops")
        }
    }

    // MARK: - Rule 3: one noisy frame never overwrites a stable reading

    func testSingleNonDecimalOutlierDoesNotOverwriteStableReading() {
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("80.8", 3) + [frame("12.3"), frame("80.8")],
                            into: &consensus)

        XCTAssertEqual(outcomes[3].value, 80.8, "a lone wild frame must not take over")
        XCTAssertEqual(outcomes[3].text, "80.8")
        XCTAssertEqual(outcomes[4].value, 80.8)
        XCTAssertEqual(consensus.anchoredText, "80.8")
    }

    /// Holding the anchor against a contradicting frame must be visible in the
    /// confidence, not silent.
    func testHeldFrameReportsDepressedConfidence() {
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("80.8", 4) + [frame("808")], into: &consensus)
        guard let held = outcomes[4].confidence, let clean = outcomes[3].confidence else {
            return XCTFail("both frames should publish a confidence")
        }
        XCTAssertLessThan(held, clean, "a contested frame must not look as good as a clean one")
    }

    // MARK: - Consensus never rewrites

    /// The published text is always one the caller supplied — the consensus
    /// selects among observations, it never synthesizes a corrected reading.
    func testConsensusNeverSynthesizesAReading() {
        var consensus = TemporalConsensus()
        let supplied: Set<String> = ["80.8", "808"]
        let outcomes = feed(repeated("80.8", 4) + [frame("808")] + repeated("80.8", 2),
                            into: &consensus)
        for outcome in outcomes {
            if let text = outcome.text {
                XCTAssertTrue(supplied.contains(text), "unexpected synthesized text \(text)")
            }
        }
    }

    /// A format prior may weight confidence but must never change the value or
    /// the text that gets published.
    func testFormatPriorDoesNotRewriteAReading() {
        let prior = InferredFormat(grammar: ReadingGrammar(integerDigits: 3,
                                                           fractionDigits: 0,
                                                           separatorPresent: false),
                                   stability: 1,
                                   supportingObservations: 12)
        var consensus = TemporalConsensus()
        let outcomes = feed(repeated("80.8", 4), into: &consensus, prior: prior)
        XCTAssertEqual(outcomes[3].value, 80.8,
                       "an integer-format prior must not rewrite 80.8 into 808")
        XCTAssertEqual(outcomes[3].text, "80.8")

        // It IS allowed to depress the confidence of a reading it disagrees with.
        var unbiased = TemporalConsensus()
        let neutral = feed(repeated("80.8", 4), into: &unbiased)
        guard let biasedConfidence = outcomes[3].confidence,
              let neutralConfidence = neutral[3].confidence else {
            return XCTFail("both runs should publish a confidence")
        }
        XCTAssertLessThan(biasedConfidence, neutralConfidence)
    }

    // MARK: - Decimal-event detection

    func testDecimalShiftDetectionRequiresSameDigitCountAndPowerOfTenRatio() {
        // Separator dropped: same digits, ×10.
        XCTAssertEqual(TemporalConsensus.decimalShiftExponent(from: 80.8, text: "80.8",
                                                              to: 808, text: "808"), 1)
        // Separator added: the inverse.
        XCTAssertEqual(TemporalConsensus.decimalShiftExponent(from: 808, text: "808",
                                                              to: 80.8, text: "80.8"), -1)
        // Two places.
        XCTAssertEqual(TemporalConsensus.decimalShiftExponent(from: 1.23, text: "1.23",
                                                              to: 123, text: "123"), 2)
        // A new digit appeared — a separator cannot do that.
        XCTAssertNil(TemporalConsensus.decimalShiftExponent(from: 80.8, text: "80.8",
                                                            to: 8080, text: "8080"))
        // An ordinary measurement change.
        XCTAssertNil(TemporalConsensus.decimalShiftExponent(from: 80.8, text: "80.8",
                                                            to: 81.2, text: "81.2"))
        // Sign flip is not a separator event.
        XCTAssertNil(TemporalConsensus.decimalShiftExponent(from: 80.8, text: "80.8",
                                                            to: -808, text: "-808"))
        // Zero has no ratio.
        XCTAssertNil(TemporalConsensus.decimalShiftExponent(from: 0, text: "0.0",
                                                            to: 0, text: "00"))
    }

    // MARK: - Lifecycle

    func testResetClearsAnchorAndWindow() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 4), into: &consensus)
        XCTAssertEqual(consensus.anchoredText, "80.8")
        consensus.reset()
        XCTAssertNil(consensus.anchoredText)
        XCTAssertNil(consensus.anchoredValue)

        // After reset the very first frame is provisional again.
        let outcomes = feed([frame("808")], into: &consensus)
        guard case .changing = outcomes[0] else {
            return XCTFail("first frame after reset should be provisional, got \(outcomes[0])")
        }
    }

    func testNonFiniteReadingIsNotEvidenceAndHoldsTheAnchor() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 4), into: &consensus)
        let outcome = consensus.observe(value: .nan, text: "---",
                                        decimalConfidence: 0, digitConfidence: 0,
                                        formatPrior: nil, timestamp: frameTime(4))
        XCTAssertEqual(outcome.value, 80.8)
        XCTAssertEqual(consensus.anchoredText, "80.8")
    }

    // MARK: - Determinism

    func testIdenticalSequencesProduceIdenticalOutcomes() {
        let sequence = repeated("80.8", 3)
            + [frame("808"), frame("80.8"), frame("808"), frame("808"),
               frame("808"), frame("808"), frame("81.2")]

        var first = TemporalConsensus()
        var second = TemporalConsensus()
        let a = feed(sequence, into: &first)
        let b = feed(sequence, into: &second)

        XCTAssertEqual(a, b)
        XCTAssertEqual(first.anchoredText, second.anchoredText)
    }

    // MARK: - Format inference

    func testSingleFrameCannotEstablishAFormat() {
        var inference = DisplayFormatInference()
        XCTAssertNil(inference.observe(text: "80.8"),
                     "one high-confidence frame is exactly what a dropped separator looks like")
        XCTAssertNil(inference.observe(text: "80.8"))
        XCTAssertNil(inference.observe(text: "80.8"))
        XCTAssertNotNil(inference.observe(text: "80.8"),
                        "four consistent observations establish the grammar")
        XCTAssertEqual(inference.current?.pattern, "##.#")
    }

    func testFormatMigratesOnlyOnSustainedEvidence() {
        var inference = DisplayFormatInference()
        for _ in 0..<6 { inference.observe(text: "80.8") }
        XCTAssertEqual(inference.current?.pattern, "##.#")

        // A legitimate range change (a temp gun going past 100) starts arriving.
        for _ in 0..<3 { inference.observe(text: "120.5") }
        XCTAssertEqual(inference.current?.pattern, "##.#",
                       "three frames must not migrate an established grammar")

        for _ in 0..<4 { inference.observe(text: "120.5") }
        XCTAssertEqual(inference.current?.pattern, "###.#",
                       "sustained evidence must migrate — a locked grammar caused mass rejections")
    }

    /// Migration must be strictly harder than first establishment.
    func testMigrationBarIsHigherThanEstablishmentBar() {
        XCTAssertGreaterThan(DisplayFormatInference.migrateSupport,
                             DisplayFormatInference.establishSupport)
        XCTAssertGreaterThanOrEqual(DisplayFormatInference.windowSize,
                                    DisplayFormatInference.migrateSupport)
    }

    func testInferenceIgnoresUnparseableTextWithoutDisturbingThePrior() {
        var inference = DisplayFormatInference()
        for _ in 0..<4 { inference.observe(text: "80.8") }
        let established = inference.current
        inference.observe(text: "HOLD")
        inference.observe(text: "--.-")
        XCTAssertEqual(inference.current, established)
    }

    func testFormatPriorIsAPriorNotAConstraint() {
        var inference = DisplayFormatInference()
        for _ in 0..<8 { inference.observe(text: "80.8") }
        guard let prior = inference.current else { return XCTFail("expected a prior") }

        let matching = ReadingGrammar(text: "81.2")!
        let rangeChange = ReadingGrammar(text: "120.5")!
        let precisionChange = ReadingGrammar(text: "80.85")!
        let separatorMissing = ReadingGrammar(text: "808")!

        // Ordering is the load-bearing property.
        XCTAssertEqual(prior.plausibility(of: matching), 1, accuracy: 1e-6)
        XCTAssertGreaterThan(prior.plausibility(of: rangeChange),
                             prior.plausibility(of: precisionChange))
        XCTAssertGreaterThan(prior.plausibility(of: precisionChange),
                             prior.plausibility(of: separatorMissing))
        // Never zero: a prior depresses, it does not veto.
        XCTAssertGreaterThan(prior.plausibility(of: separatorMissing), 0)
    }

    /// A weak prior must barely move anything — that is what stops an
    /// under-evidenced grammar from becoming a de facto constraint.
    func testWeakPriorIsNearlyNeutral() {
        let weak = InferredFormat(grammar: ReadingGrammar(integerDigits: 2,
                                                          fractionDigits: 1,
                                                          separatorPresent: true),
                                  stability: 0,
                                  supportingObservations: 1)
        XCTAssertEqual(weak.plausibility(of: ReadingGrammar(text: "808")!), 1, accuracy: 1e-6)
    }

    func testInferenceIsDeterministic() {
        let texts = ["80.8", "80.8", "808", "80.8", "120.5", "120.5",
                     "80.8", "120.5", "120.5", "120.5", "120.5", "120.5", "120.5"]
        var first = DisplayFormatInference()
        var second = DisplayFormatInference()
        var a: [InferredFormat?] = []
        var b: [InferredFormat?] = []
        for text in texts { a.append(first.observe(text: text)) }
        for text in texts { b.append(second.observe(text: text)) }
        XCTAssertEqual(a, b)
    }

    func testReadingGrammarParsing() {
        XCTAssertEqual(ReadingGrammar(text: "80.8")?.pattern, "##.#")
        XCTAssertEqual(ReadingGrammar(text: "-1.234")?.pattern, "#.###")
        XCTAssertEqual(ReadingGrammar(text: "808")?.pattern, "###")
        XCTAssertEqual(ReadingGrammar(text: "1.000")?.fractionDigits, 3,
                       "trailing zeros are part of the layout")
        XCTAssertNil(ReadingGrammar(text: "12."), "a trailing separator is not a grammar")
        XCTAssertNil(ReadingGrammar(text: "1.2.3"))
        XCTAssertNil(ReadingGrammar(text: "HOLD"))
        XCTAssertNil(ReadingGrammar(text: ""))
    }
}
