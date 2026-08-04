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

    // MARK: - THE ASYMMETRY
    //
    // Seeing a separator is EVIDENCE. Not seeing one is NOT. The two tests
    // below are the same experiment run in opposite directions, and the fact
    // that they disagree is the entire rule.
    //
    // DELIBERATE BEHAVIOUR CHANGE. These two replace a single earlier test,
    // `testSustainedDroppedSeparatorWithHighRescueConfidenceMigrates`, which
    // fed 6× "808" at decimal 0.95 and asserted the anchor MIGRATED to "808".
    // That test encoded the bug, for three independent reasons:
    //
    //   1. Its stated premise was "the separator verdict is confident there is
    //      genuinely no separator, which is the corroboration a decimal event
    //      requires". Confidence in an ABSENCE is not evidence of an absence
    //      when the absence is measured from TEXT: a dot destroyed by
    //      thresholding leaves exactly the same text as a display that never
    //      had one. That is the failure `TemporalConsensus` exists for.
    //   2. It conflated `DecimalRescue`'s PIXEL-level absence verdict — which
    //      is real evidence, is capped at 0.5 by `betweenDigitsOnlyCeiling`,
    //      and is not wired into this path yet — with `FormatValidator`'s
    //      TEXT-level absence, which is not evidence at all.
    //   3. Its input is unreachable in production. No shipping path yields a
    //      separator-free text at decimal confidence 0.95:
    //      `FormatValidator.undeclaredIntegerCertainty` is 0.75, and
    //      `MeasurementProcessor`'s `?? 1` fallback is dead because a `.parsed`
    //      outcome always carries a `DecimalAnalysis`. A test whose only
    //      passing input cannot occur is not protecting a behaviour.

    /// The open direction. A sustained `80.8` against an established `808`
    /// MUST migrate: the new form carries a separator that was actually read,
    /// which is evidence, so the guard is a higher bar and not a permanent
    /// lock. A display really can start showing its decimal point.
    func testSustainedSeparatorGainMigrates() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("808", 5, decimal: FormatValidator.undeclaredIntegerCertainty),
                 into: &consensus)

        let outcomes = feed(repeated("80.8", 6, decimal: FormatValidator.readSeparatorCertainty),
                            into: &consensus,
                            startIndex: 5)

        XCTAssertEqual(outcomes[0].value, 808, "first contradicting frame is still held off")
        let final = outcomes[outcomes.count - 1]
        XCTAssertEqual(final.value, 80.8)
        XCTAssertEqual(final.text, "80.8")
        XCTAssertEqual(consensus.anchoredText, "80.8")
        XCTAssertFalse(final.isAmbiguous,
                       "sustained, corroborated evidence must resolve, not stay ambiguous")
    }

    /// The closed direction, at the MAXIMUM possible confidence. "However
    /// confident" is the assertion's whole content: no value on the absence
    /// channel may buy a 10× change, because there is no value that makes
    /// "I saw no dot" distinguishable from "the dot did not survive".
    func testSustainedSeparatorLossNeverMigratesHoweverConfident() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 5), into: &consensus)

        let outcomes = feed(repeated("808", 6, decimal: 1.0), into: &consensus, startIndex: 5)

        XCTAssertEqual(consensus.anchoredText, "80.8",
                       "an absence claim must not carry a 10× migration at ANY confidence")
        for outcome in outcomes {
            XCTAssertNotEqual(outcome.value, 808,
                              "uncorroborated 808 must never be published as the reading")
        }
        // From the migration point on it is a first-class disagreement, not a
        // quiet hold — the two refusal causes must stay distinguishable in the
        // reason string, since `RejectionReason` flattens both to
        // `.ambiguousDecimal` downstream.
        for index in 3..<outcomes.count {
            XCTAssertTrue(outcomes[index].isAmbiguous,
                          "frame \(index + 5) should report the disagreement")
        }
        guard case .ambiguous(let reason, _) = outcomes[outcomes.count - 1] else {
            return XCTFail("expected .ambiguous")
        }
        XCTAssertTrue(reason.contains("NO separator"),
                      "the refusal must say WHICH cause fired; got: \(reason)")
    }

    /// The executable form of the defect. Without this, the inversion can
    /// silently return the next time either constant is "harmonized".
    func testCorroborationBarOutranksAnAbsenceClaim() {
        XCTAssertGreaterThan(TemporalConsensus.decimalRescueConfidence,
                             FormatValidator.undeclaredIntegerCertainty,
                             "\"I saw no separator\" must never outscore the bar for "
                             + "\"the glyph corroborates\"")
        XCTAssertLessThanOrEqual(TemporalConsensus.decimalRescueConfidence,
                                 FormatValidator.commaDecimalCertainty,
                                 "a comma resolved by grouping shape is still a separator that "
                                 + "was read, and must still be able to corroborate")
    }

    /// Same numbers, opposite outcomes. This is what proves the rule is
    /// STRUCTURAL rather than numeric: at an identical decimal confidence of
    /// 1.0, gaining a separator migrates and losing one does not.
    func testIdenticalConfidenceMigratesOneWayOnly() {
        var gaining = TemporalConsensus()
        _ = feed(repeated("808", 5, decimal: 1.0), into: &gaining)
        _ = feed(repeated("80.8", 6, decimal: 1.0), into: &gaining, startIndex: 5)
        XCTAssertEqual(gaining.anchoredText, "80.8", "seeing a separator IS evidence")

        var losing = TemporalConsensus()
        _ = feed(repeated("80.8", 5, decimal: 1.0), into: &losing)
        _ = feed(repeated("808", 6, decimal: 1.0), into: &losing, startIndex: 5)
        XCTAssertEqual(losing.anchoredText, "80.8", "not seeing one is NOT evidence")
    }

    /// The same asymmetry driven by the values the PRODUCTION parser actually
    /// emits, rather than by hand-picked literals. Every other acceptance
    /// assertion in the suite hand-picks its decimal confidence, which is
    /// exactly why the 0.75-vs-0.70 inversion was invisible for so long.
    func testProductionSeparatorConfidencesDriveTheAsymmetry() throws {
        guard case .number(let integerReading) = FormatValidator.extractReading(from: "808"),
              case .number(let decimalReading) = FormatValidator.extractReading(from: "80.8") else {
            return XCTFail("both forms must extract on the lenient Mode 3 path")
        }
        let integerConfidence = integerReading.decimal.confidence
        let decimalConfidence = decimalReading.decimal.confidence

        var gaining = TemporalConsensus()
        _ = feed(repeated("808", 5, decimal: integerConfidence), into: &gaining)
        _ = feed(repeated("80.8", 6, decimal: decimalConfidence), into: &gaining, startIndex: 5)
        XCTAssertEqual(gaining.anchoredText, "80.8",
                       "the production separator verdict (\(decimalConfidence)) must corroborate")

        var losing = TemporalConsensus()
        _ = feed(repeated("80.8", 5, decimal: decimalConfidence), into: &losing)
        _ = feed(repeated("808", 6, decimal: integerConfidence), into: &losing, startIndex: 5)
        XCTAssertEqual(losing.anchoredText, "80.8",
                       "the production absence verdict (\(integerConfidence)) must NOT corroborate")
    }

    /// The threshold, isolated on a separator-BEARING form so it is the only
    /// thing under test. Without this,
    /// `testSustainedDroppedSeparatorWithoutCorroborationDoesNotMigrate` is the
    /// suite's only threshold test and it is now vacuous — it passes for two
    /// independent reasons (no separator AND a low confidence).
    func testSeparatorBearingFormStillNeedsTheRaisedThreshold() {
        var weak = TemporalConsensus()
        _ = feed(repeated("808", 5), into: &weak)
        _ = feed(repeated("80.8", 6, decimal: 0.70), into: &weak, startIndex: 5)
        XCTAssertEqual(weak.anchoredText, "808",
                       "0.70 sits below the raised bar and must no longer buy a 10× change")

        var strong = TemporalConsensus()
        _ = feed(repeated("808", 5), into: &strong)
        _ = feed(repeated("80.8", 6, decimal: 0.80), into: &strong, startIndex: 5)
        XCTAssertEqual(strong.anchoredText, "80.8",
                       "a structurally resolved separator must still be able to corroborate")
    }

    /// The same sustained series WITHOUT corroboration (the separator verdict is
    /// itself unsure) must not migrate. Evidence quality, not just repetition,
    /// is what buys a 10× change.
    ///
    /// NOTE: this now passes for two independent reasons (the new form has no
    /// separator, AND 0.4 is below the bar), so it no longer discriminates the
    /// threshold. It is kept as a behavioural pin;
    /// `testSeparatorBearingFormStillNeedsTheRaisedThreshold` restores the
    /// threshold discrimination.
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

    // MARK: - H3: the cost of the asymmetry, measured and printed

    /// THE PRICE OF THE RULE, stated out loud rather than smoothed over.
    ///
    /// Once a separator-bearing form is anchored, a display that genuinely
    /// STOPS showing its separator refuses forever: `expire` releases the anchor
    /// only when the window fully EMPTIES (> `windowHorizon` with no
    /// observations), so while frames keep arriving the integer run yields
    /// `.ambiguous` on every frame — even after the anchor's own support in the
    /// window has fallen to zero.
    ///
    /// This is correct under the product promise and D10: "this is an integer
    /// display" and "this display's dot stopped surviving preprocessing" are
    /// the same observation, and refusal is the answer for that class. It is
    /// still a cost, and it is printed so it appears in CI output rather than
    /// being inferred from a pass rate.
    ///
    /// HANDOFF TO B6: the deadlock escape must NOT be `reset()`-and-re-anchor.
    /// Releasing the anchor lets the window re-anchor on the integer form in
    /// `anchorSupport` (2) frames and publishes the 10× error through the back
    /// door — this exact bug, one layer up. The escape must be "stay refused and
    /// surface a re-configuration request", or a user-declared `DisplayFormat`
    /// (Mode 2), which is the only authority permitted to settle a decimal
    /// position.
    func testH3CostSeparatorAnchoredDisplayThatLosesItsDotRefusesForever() {
        var consensus = TemporalConsensus()
        _ = feed(repeated("80.8", 2), into: &consensus)
        let run = feed(repeated("808", 20, decimal: FormatValidator.undeclaredIntegerCertainty),
                       into: &consensus,
                       startIndex: 2)

        let refused = run.filter(\.isAmbiguous).count
        let published808 = run.filter { $0.value == 808 }.count
        print("""

        === H3 COST (TemporalConsensus, separator-anchored integer run) ===
        anchor "80.8" (2 frames) then 20 frames of "808" at the production \
        absence verdict \(FormatValidator.undeclaredIntegerCertainty):
          refused (.ambiguous): \(refused) / \(run.count)
          published as 808:     \(published808) / \(run.count)
          anchor after the run: \(consensus.anchoredText ?? "nil")
        A genuine integer instrument whose FIRST anchored form carried a \
        separator is refused indefinitely. Accepted per the product promise; \
        handed to B6 with the escape constraint above.

        """)

        XCTAssertEqual(published808, 0, "the 10× form must never be published")
        XCTAssertEqual(consensus.anchoredText, "80.8", "the anchor is held, not migrated")
        XCTAssertGreaterThanOrEqual(refused, 15,
                                    "the sustained run must REFUSE, not quietly hold forever")
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

    /// The full truth table for the decade predicate, which is now used in TWO
    /// places — across frames (the anchor guard in `MeasurementProcessor`) and
    /// WITHIN one frame (`decimalConflict`, the two-candidate refusal). Pinning
    /// it here keeps ONE definition of "these two readings differ only by a
    /// decimal shift" in the codebase instead of two that can drift apart.
    func testDecimalShiftPredicateTruthTable() {
        func shift(_ a: String, _ b: String) -> Int? {
            guard let aValue = Double(a), let bValue = Double(b) else {
                XCTFail("fixture \(a)/\(b) is not numeric"); return nil
            }
            return TemporalConsensus.decimalShiftExponent(from: aValue, text: a,
                                                          to: bValue, text: b)
        }

        // FIRES — the same digits at two decimal positions.
        for pair in [("900", "90.0"), ("808", "80.8"), ("5", ".5"), ("1.00", "100"),
                     ("99.9", "999"), ("12.5", "1.25"), ("100.0", "1000")] {
            XCTAssertNotNil(shift(pair.0, pair.1), "\(pair.0) vs \(pair.1) is a decade pair")
        }

        // DOES NOT FIRE, and each row is load-bearing.
        XCTAssertNil(shift("900", "92.7"),
                     "two different FIELDS — the hazard the digit-count rule exists for")
        XCTAssertNil(shift("0.000", "000"), "zero: a dropped separator here is not a scale error")
        XCTAssertNil(shift("0.00", "0"), "zero vs zero")
        XCTAssertNil(shift("12.345", "345"), "tokenizer truncation is the tokenizer's job")
        XCTAssertNil(shift("-20.5", "20.5"), "a pure sign flip is a digit error, not a decade one")
        XCTAssertNil(shift("-8.08", "80.8"),
                     "KNOWN GAP: sign flip AND decade together — widening this would swallow "
                     + "pure sign flips, which the verdict taxonomy defines as not a scale error")
        XCTAssertNil(shift("88888", "88"),
                     "a truncated reading is not a decade neighbour — this is the measured false "
                     + "positive of the looser 'spans one decade of magnitude' rule")
        XCTAssertNil(shift("12.347", "12.347"), "identical readings never conflict")
        XCTAssertNil(shift("1.5", "1.50"), "same value, different written precision")
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
