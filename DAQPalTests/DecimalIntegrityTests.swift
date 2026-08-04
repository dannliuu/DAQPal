//
//  DecimalIntegrityTests.swift
//  DAQPalTests
//
//  Spec §11A / Gate 11A — the decimal separator as a DATA-INTEGRITY property.
//
//  A lost separator produces a well-formed number that is wrong by a factor of
//  ten or more: `12.345` read as `12345` is numeric, has the right digits in
//  the right order, and passes every check that only asks "does this parse?".
//  Range validation catches it by luck; temporal filtering actively hides it,
//  because a consistently shifted series is perfectly self-consistent. These
//  tests pin the separator's own behaviour, separately from the digits'.
//

import XCTest
@testable import DAQPal

final class DecimalIntegrityTests: XCTestCase {

    /// Unconstrained (spec Mode 3) — no declared digit count or decimal
    /// position, so the separator must be resolved from the text alone.
    private let lenient = DisplayFormat.unconstrained

    /// The spec's canonical strict DMM grammar, ±XX.XXX, dimensionless here so
    /// unit stripping never enters these assertions.
    private let strict = DisplayFormat(digitCount: 5, decimalPosition: 2,
                                       signAllowed: true, unit: nil,
                                       minimumValue: nil, maximumValue: nil)

    /// Signals an unmet extraction expectation without XCTSkip, which would
    /// mark the test skipped and swallow the failure it was reporting.
    private struct NoReading: Error {}

    private func extracted(_ text: String,
                           file: StaticString = #filePath,
                           line: UInt = #line) throws -> NumericReading {
        switch FormatValidator.extractReading(from: text) {
        case .number(let reading): return reading
        case .none:
            XCTFail("'\(text)' yielded no numeric token", file: file, line: line)
            throw NoReading()
        case .rejected(let reason):
            XCTFail("'\(text)' was rejected as \(reason.rawValue)", file: file, line: line)
            throw NoReading()
        }
    }

    // MARK: - Positive vectors: exact values, lenient path

    func testPositiveVectorsParseToExactValues() throws {
        let vectors: [(String, Double)] = [
            ("12.345", 12.345),
            ("0.001", 0.001),
            ("99.9", 99.9),
            ("-1.25", -1.25),
            (".5", 0.5),
            ("100.0", 100.0),
            ("0.0", 0.0),
            ("-0.001", -0.001),
            ("1234.5", 1234.5),
            ("12.3456", 12.3456),
            ("1.000", 1.000),
        ]
        for (text, expected) in vectors {
            let reading = try extracted(text)
            XCTAssertEqual(reading.value, expected, "'\(text)' must parse to \(expected)")
            XCTAssertEqual(FormatValidator.value(from: text, format: lenient), .valid(expected),
                           "'\(text)' through the Mode 3 entry point")
        }
    }

    /// The separator was read directly, so the determination is certain and the
    /// reported position matches `DisplayFormat.decimalPosition`'s convention
    /// (digits BEFORE the separator).
    func testPositiveVectorsReportSeparatorPresenceAndPosition() throws {
        let cases: [(text: String, position: Int, fraction: Int)] = [
            ("12.345", 2, 3),
            ("0.001", 1, 3),
            (".5", 0, 1),
            ("-1.25", 1, 2),
            ("1234.5", 4, 1),
        ]
        for c in cases {
            let d = try extracted(c.text).decimal
            XCTAssertTrue(d.separatorDetected, "'\(c.text)' separator presence")
            XCTAssertEqual(d.separatorPosition, c.position, "'\(c.text)' separator position")
            XCTAssertEqual(d.fractionDigitCount, c.fraction, "'\(c.text)' fraction digits")
            XCTAssertEqual(d.confidence, FormatValidator.readSeparatorCertainty,
                           "'\(c.text)': a directly read '.' is a certain determination")
        }
    }

    /// Display fidelity: `Double` cannot carry significant trailing zeros, so
    /// the written form must survive the parse alongside the value.
    func testTrailingZerosPreservedForDisplay() throws {
        XCTAssertEqual(try extracted("1.000").text, "1.000")
        XCTAssertEqual(try extracted("100.0").text, "100.0")
        XCTAssertEqual(try extracted("0.0").text, "0.0")
        XCTAssertEqual(try extracted("1.000").decimal.fractionDigitCount, 3)

        // ...and through the strict grammar, which is where a configured
        // display's resolution is known exactly.
        guard case .valid(let reading) = FormatValidator.strictReading("1.000", format: strict) else {
            return XCTFail("1.000 must satisfy the ±XX.XXX grammar")
        }
        XCTAssertEqual(reading.value, 1.0)
        XCTAssertEqual(reading.text, "1.000", "trailing zeros are significant for display fidelity")
    }

    // MARK: - Negative vectors: rejected, never coerced

    func testMalformedSeparatorStructuresAreRejected() {
        for text in ["12..345", "12.34.5", "12.", "."] {
            switch FormatValidator.extractReading(from: text) {
            case .number(let reading):
                XCTFail("'\(text)' must not be coerced to a number; got \(reading.value)")
            case .none, .rejected:
                break
            }
            guard case .invalid = FormatValidator.value(from: text, format: lenient) else {
                return XCTFail("'\(text)' must be rejected by the Mode 3 entry point")
            }
        }
    }

    /// The salvage that used to hide these: "12..345" tokenized into `12.` and
    /// `.345` and the most-digits rule returned 0.345 — three orders of
    /// magnitude off, and well formed.
    func testMalformedStructuresDoNotSalvageAPrefixOrSuffix() {
        XCTAssertNil(FormatValidator.extractNumber(from: "12..345"))
        XCTAssertNil(FormatValidator.extractNumber(from: "12.34.5"))
        XCTAssertNil(FormatValidator.extractNumber(from: "12."))
    }

    // MARK: - Defect 1 regression: a split reading is not a menu

    /// `"12 345"` is `12.345` with the separator recognized as a space, or
    /// `12345`, or two numbers. The old max-digits selection answered **345**.
    func testSpaceSplitReadingNeverReturnsTheFragment() {
        let result = FormatValidator.extractNumber(from: "12 345")
        XCTAssertNotEqual(result?.value, 345, "the fragment of a split reading is not the reading")
        XCTAssertNil(result, "an unresolvable split must produce no value at all")

        XCTAssertEqual(FormatValidator.extractReading(from: "12 345"),
                       .rejected(.ambiguousDecimal))
        XCTAssertEqual(FormatValidator.value(from: "12 345", format: lenient),
                       .invalid(.ambiguousDecimal))
    }

    /// A caption's digit is not half of a split: "CH1 12.345 V" must still read
    /// 12.345, and "CH1 1750 RPM" must still read 1750.
    func testCaptionDigitsDoNotLookLikeASplit() throws {
        XCTAssertEqual(try extracted("CH1 12.345 V").value, 12.345)
        XCTAssertEqual(try extracted("CH1 1750 RPM").value, 1750)
        XCTAssertEqual(try extracted("AUTO 12.3 mV").value, 12.3)
    }

    // MARK: - Defect 3 regression: an UNIDENTIFIED glyph in separator position
    //
    // The tokenizer used to split at any glyph outside `[0-9.,]` and the picker
    // then took the fragment with the most digits — with NO trace that anything
    // had been dropped. Measured on the shipping path: "80•8" (a display truly
    // showing 80.8, whose dot Vision transcribed as a bullet) parsed as 80, and
    // "12•345" parsed as 345. Every one is a silent power-of-ten error in
    // exported data, which is the exact failure §11A exists to prevent.
    //
    // THE GLYPH IS NEVER READ AS A SEPARATOR. The obvious-looking fix — "a
    // non-alphanumeric glyph in separator position is separator evidence" —
    // is REJECTED and must not be implemented: it authors a decimal position
    // from a mark the recognizer could not classify, so a degree sign, a
    // thousands comma, a colon lobe or a glare speck becomes a decimal point.
    // It converts a class that TRUNCATES into a class that INVENTS magnitude.
    // Same trigger, opposite action: refuse.

    /// The mandated refusals. Asserted through BOTH entry points so the reason
    /// survives the dispatcher and is not flattened to `.invalidFormat` on its
    /// way to the UI.
    func testForeignGlyphBetweenDigitRunsIsRefusedNotTruncated() {
        let cases: [(text: String, wouldHaveParsedAs: Double)] = [
            ("80\u{2022}8", 80),      // BULLET — the measured live corruption
            ("12\u{2022}345", 345),   // ...and its truncating twin
            ("80\u{00B7}8", 80),      // MIDDLE DOT
            ("12:345", 345),          // COLON — a lobe of a segment display
            ("80\u{00B0}8", 80),      // DEGREE SIGN
            ("80-8", 80),             // an infix hyphen the sign rule cannot claim
        ]
        for c in cases {
            XCTAssertEqual(FormatValidator.extractReading(from: c.text),
                           .rejected(.ambiguousDecimal),
                           "'\(c.text)' must refuse, not return \(c.wouldHaveParsedAs)")
            XCTAssertEqual(FormatValidator.value(from: c.text, format: lenient),
                           .invalid(.ambiguousDecimal),
                           "'\(c.text)': the reason must survive the Mode 3 dispatcher")
            XCTAssertNotEqual(FormatValidator.extractNumber(from: c.text)?.value,
                              c.wouldHaveParsedAs,
                              "'\(c.text)': the fragment is not the reading")
        }
    }

    /// The same class, pinned across the glyph set Vision actually produces on
    /// segment faces and glare.
    func testForeignGlyphRefusalCoversTheObservedGlyphSet() {
        for text in ["80\u{2019}8", "80'8", "80*8", "80;8", "80\u{2044}8", "8\u{2022}08"] {
            XCTAssertEqual(FormatValidator.extractReading(from: text),
                           .rejected(.ambiguousDecimal),
                           "'\(text)' must refuse")
        }
    }

    /// The LEADING-separator class, which is a single token and so never reaches
    /// the gap rule: the display shows ".5", the dot is transcribed as a speck,
    /// the token grammar discards it and a bare 5 is published — a 10× error.
    func testLeadingForeignGlyphIsRefusedNotStripped() {
        for text in ["\u{2022}5", "\u{00B7}5", "\u{00B0}5", "'5"] {
            XCTAssertEqual(FormatValidator.extractReading(from: text),
                           .rejected(.ambiguousDecimal),
                           "'\(text)' is '.5' or it is '5' with a speck; the text cannot say which")
        }
        // A token that carries its OWN separator has no decimal position at
        // stake, so the leading mark is just decoration.
        XCTAssertEqual(try? extracted("\u{2022}0.5").value, 0.5)
    }

    /// A LETTER in the gap is an IDENTIFIED glyph and cannot be a decimal point,
    /// so it marks a genuine field boundary rather than a broken number. The
    /// exemption is Unicode-wide on purpose: "µ" and "Ω" are units.
    ///
    /// These rows are FIELD-SELECTION errors, not magnitude errors — the same
    /// behaviour whitespace already has — and refusing them would reject
    /// legitimate multi-field panel lines and degrade
    /// `ScreenCandidateDetector.numericScore`, which uses this entry point as a
    /// display-detection heuristic.
    func testLetterInTheGapIsAFieldBoundaryNotAForeignGlyph() {
        for text in ["12\u{00B0}C 345", "12 V 345", "12 \u{03A9} 345", "12\u{00B5}345"] {
            if case .rejected = FormatValidator.extractReading(from: text) {
                XCTFail("'\(text)': a letter-bearing gap is a field boundary, not a split")
            }
        }
        // ...and a unit glued to a well-formed decimal is untouched.
        XCTAssertEqual(try? extracted("98.6 \u{00B0}F").value, 98.6)
        XCTAssertEqual(try? extracted("90.0\u{00B0}").value, 90.0)
        XCTAssertEqual(try? extracted("0.5\u{03A9}").value, 0.5)
    }

    /// A glyph preceded by a letter or digit is a LABEL delimiter between two
    /// fields ("T1:5"), not a mark inside one number, so it does not refuse.
    func testLabelDelimiterIsNotALeadingForeignGlyph() {
        XCTAssertEqual(try? extracted("T1:5").value, 5)
        XCTAssertEqual(try? extracted("DC VOLTS: 12.345").value, 12.345)
    }

    /// H3 — THE COST OF THE TOKENIZER RULE, named rather than smoothed over.
    ///
    /// `"(12345)"` is a bare integer in parentheses and this is a PURE RECALL
    /// LOSS with no safety argument: the leading "(" is an unclassifiable glyph
    /// in separator position and the rule cannot tell it from a speck.
    /// `"(12.345)"` is unaffected, because that token carries its own separator.
    ///
    /// The other two are net safety gains: both were already returning a
    /// FRAGMENT of an ambiguous line, and a date is not a reading at all —
    /// today it inflates `ScreenCandidateDetector.numericScore` for regions that
    /// are not displays.
    func testTokenizerRefusalCostIsPinned() {
        XCTAssertEqual(FormatValidator.extractReading(from: "(12345)"),
                       .rejected(.ambiguousDecimal),
                       "PURE RECALL LOSS, accepted knowingly — see this test's doc comment")
        XCTAssertEqual(try? extracted("(12.345)").value, 12.345,
                       "a token carrying its own separator is unaffected")
        XCTAssertEqual(FormatValidator.extractReading(from: "80 - 8"),
                       .rejected(.ambiguousDecimal))
        XCTAssertEqual(FormatValidator.extractReading(from: "2024-01-15"),
                       .rejected(.ambiguousDecimal),
                       "a date is not a reading")
    }

    // MARK: - Defect 2 regression: comma handling

    /// `"12,345"` tokenized into `12` and `345` and returned **345**. It is
    /// genuinely ambiguous — 12345 grouped, or 12.345 with a decimal comma —
    /// so with no declared format it must be rejected, not guessed.
    func testCommaSplitReadingNeverReturnsTheFragment() {
        let result = FormatValidator.extractNumber(from: "12,345")
        XCTAssertNotEqual(result?.value, 345, "the fragment after a comma is not the reading")
        XCTAssertNil(result)
        XCTAssertEqual(FormatValidator.extractReading(from: "12,345"),
                       .rejected(.ambiguousDecimal))
    }

    /// Where the grouping shape RULES OUT a thousands separator, the comma can
    /// only be a decimal mark — resolvable, and resolved.
    func testLoneCommaResolvesAsDecimalWhenGroupingIsImpossible() throws {
        XCTAssertEqual(try extracted("12,34").value, 12.34)
        XCTAssertEqual(try extracted("0,5").value, 0.5)
        XCTAssertEqual(try extracted("1,2345").value, 1.2345)
        XCTAssertEqual(try extracted("1234,567").value, 1234.567,
                       "4 digits before the comma cannot be a thousands group")

        // Resolved by inference, so the determination is deliberately NOT
        // certain — it rests on a locale assumption.
        let d = try extracted("12,34").decimal
        XCTAssertTrue(d.separatorDetected)
        XCTAssertEqual(d.separatorPosition, 2)
        XCTAssertLessThan(d.confidence, FormatValidator.readSeparatorCertainty)
    }

    /// Repeated grouping commas cannot be decimal marks — that shape is
    /// unambiguous, and the value is the grouped integer.
    func testDigitGroupingIsDistinguishedFromADecimalMark() throws {
        XCTAssertEqual(try extracted("1,234,567").value, 1234567)
        XCTAssertFalse(try extracted("1,234,567").decimal.separatorDetected)

        XCTAssertEqual(try extracted("1,234.5").value, 1234.5)
        XCTAssertEqual(try extracted("1,234.5").decimal.separatorPosition, 4)
    }

    /// Grouping that does not group ("1,23.4" — 2 digits in a thousands slot)
    /// is malformed, not a hint to be interpreted.
    func testMalformedGroupingIsRejected() {
        for text in ["1,23.4", "1,2345.6", "12,345,6"] {
            if case .number(let reading) = FormatValidator.extractReading(from: text) {
                XCTFail("'\(text)' must not be coerced; got \(reading.value)")
            }
        }
    }

    // MARK: - Separator expected but absent

    /// The heart of §11A: a declared decimal position with no separator in the
    /// text. Emitting the digits as an integer would publish a number wrong by
    /// a factor of 1000 that passes range and temporal checks. It must raise
    /// `AMBIGUOUS_DECIMAL` instead.
    func testDeclaredSeparatorMissingRaisesAmbiguousDecimal() {
        XCTAssertEqual(FormatValidator.parse("12345", format: strict),
                       .invalid(.ambiguousDecimal))
        XCTAssertEqual(FormatValidator.value(from: "12345", format: strict),
                       .invalid(.ambiguousDecimal))
        // The whitespace-stripping step means a split reading reaches the same
        // gate under a constrained format.
        XCTAssertEqual(FormatValidator.parse("12 345", format: strict),
                       .invalid(.ambiguousDecimal))

        // And never the integer.
        if case .valid(let value) = FormatValidator.parse("12345", format: strict) {
            XCTFail("expected rejection, got \(value)")
        }
    }

    func testAmbiguousDecimalHasARejectionLabelInTheExistingStyle() {
        XCTAssertEqual(RejectionReason.ambiguousDecimal.rawValue, "AMBIGUOUS_DECIMAL")
        XCTAssertEqual(RejectionReason.ambiguousDecimal.displayLabel, "AMBIGUOUS DECIMAL")
    }

    // MARK: - Fixed decimal position support

    /// A declared `decimalPosition` is the strongest available evidence, so it
    /// resolves a comma that is ambiguous on its own.
    func testDeclaredPositionResolvesAnAmbiguousComma() throws {
        guard case .valid(let reading) = FormatValidator.strictReading("12,345", format: strict) else {
            return XCTFail("a declared ±XX.XXX grammar resolves '12,345' as 12.345")
        }
        XCTAssertEqual(reading.value, 12.345)
        XCTAssertEqual(reading.decimal.separatorPosition, 2)
        XCTAssertLessThan(reading.decimal.confidence, FormatValidator.readSeparatorCertainty,
                          "resolved by the format, not read from the glyph")

        // An integer display declares the opposite, and gets the opposite.
        let counter = DisplayFormat(digitCount: 5, decimalPosition: nil, signAllowed: false,
                                    unit: nil, minimumValue: nil, maximumValue: nil)
        guard case .valid(let grouped) = FormatValidator.strictReading("12,345", format: counter) else {
            return XCTFail("an integer display reads '12,345' as a grouped 12345")
        }
        XCTAssertEqual(grouped.value, 12345)
        XCTAssertFalse(grouped.decimal.separatorDetected)
    }

    /// A separator anywhere other than the declared position is a format
    /// violation, not a reading to be rescaled.
    func testSeparatorAwayFromTheDeclaredPositionIsAFormatViolation() {
        // Declared 2 integer / 3 fraction digits.
        XCTAssertEqual(FormatValidator.parse("123.45", format: strict), .invalid(.invalidFormat))
        XCTAssertEqual(FormatValidator.parse("1.2345", format: strict), .invalid(.invalidFormat))
        // An integer display tolerates no separator at all.
        let counter = DisplayFormat(digitCount: 5, decimalPosition: nil, signAllowed: false,
                                    unit: nil, minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(FormatValidator.parse("12.345", format: counter), .invalid(.invalidFormat))
    }

    /// An integer display that shows no separator has nothing to be uncertain
    /// about — the determination is certain and neutral in fusion.
    func testDeclaredIntegerDisplayHasACertainSeparatorVerdict() throws {
        let counter = DisplayFormat(digitCount: 5, decimalPosition: nil, signAllowed: false,
                                    unit: nil, minimumValue: nil, maximumValue: nil)
        guard case .valid(let reading) = FormatValidator.strictReading("12345", format: counter) else {
            return XCTFail("an integer display accepts 12345")
        }
        XCTAssertFalse(reading.decimal.separatorDetected)
        XCTAssertNil(reading.decimal.separatorPosition)
        XCTAssertEqual(reading.decimal.confidence, FormatValidator.readSeparatorCertainty)
    }

    /// An UNDECLARED integer reading is a different case: text alone cannot
    /// exclude a dropped separator, so the determination is below neutral and
    /// will depress the fused confidence.
    func testUndeclaredIntegerSeparatorVerdictIsBelowCertain() throws {
        let d = try extracted("1750").decimal
        XCTAssertFalse(d.separatorDetected)
        XCTAssertLessThan(d.confidence, FormatValidator.readSeparatorCertainty)
        XCTAssertGreaterThan(d.confidence, ConfidenceEngine.decimalVetoThreshold,
                             "an undeclared integer is uncertain, not rejected")
    }

    // MARK: - Confidence fusion

    private let engine = ConfidenceEngine()

    private func fused(decimalConfidence: Float) -> DAQPal.Measurement {
        let decimal = DecimalAnalysis(separatorDetected: true,
                                      separatorPosition: 2,
                                      fractionDigitCount: 3,
                                      confidence: decimalConfidence)
        return engine.fuse(timestamp: 0, value: 12.345, unit: nil, rawText: "12.345",
                           ocrConfidence: 0.95, formatValid: true, physicalRejection: nil,
                           temporalConsistency: 1, temporalRejected: false,
                           decimal: decimal)
    }

    /// The requirement in one assertion: confident digits must NOT carry an
    /// unconfident separator through at full strength.
    func testLowDecimalConfidenceDepressesTheFusedConfidence() {
        let certain = fused(decimalConfidence: 1)
        let shaky = fused(decimalConfidence: 0.6)
        XCTAssertLessThan(shaky.confidence, certain.confidence)
        XCTAssertTrue(certain.accepted)
        XCTAssertTrue(shaky.accepted, "0.6 is above the veto threshold — depressed, not rejected")
        XCTAssertLessThan(shaky.confidence, 0.95,
                          "the reading must not inherit the digits' confidence")
    }

    /// Corroborate-or-veto, in the `CrossCheckOutcome` mould: a certain
    /// separator is NEUTRAL and never inflates, and the absence of any analysis
    /// leaves untouched call sites exactly where they were.
    func testCertainSeparatorIsNeutralAndAbsentAnalysisChangesNothing() {
        let baseline = engine.fuse(timestamp: 0, value: 12.345, unit: nil, rawText: "12.345",
                                   ocrConfidence: 0.95, formatValid: true, physicalRejection: nil,
                                   temporalConsistency: 1, temporalRejected: false)
        XCTAssertEqual(fused(decimalConfidence: 1).confidence, baseline.confidence, accuracy: 1e-6)
        XCTAssertNil(baseline.decimal)
    }

    func testDecimalFactorNeverPushesConfidenceAboveOCRConfidence() {
        for decimalConfidence: Float in [0, 0.5, 0.75, 1, 2] {
            let m = fused(decimalConfidence: decimalConfidence)
            XCTAssertLessThanOrEqual(m.confidence, 0.95,
                                     "final ≤ ocrConfidence must hold for every separator verdict")
        }
    }

    func testVeryLowDecimalConfidenceVetoesAsAmbiguousDecimal() {
        let m = fused(decimalConfidence: ConfidenceEngine.decimalVetoThreshold - 0.01)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .ambiguousDecimal)
    }

    /// Precedence: an earlier failing gate still names the reason, so the
    /// decimal veto cannot mask a format or OCR failure.
    func testDecimalVetoDoesNotOutrankEarlierGates() {
        let decimal = DecimalAnalysis(separatorDetected: false, separatorPosition: nil,
                                      fractionDigitCount: 0, confidence: 0)
        let lowOCR = engine.fuse(timestamp: 0, value: 12.345, unit: nil, rawText: "12.345",
                                 ocrConfidence: 0.1, formatValid: true, physicalRejection: nil,
                                 temporalConsistency: 1, temporalRejected: false,
                                 decimal: decimal)
        XCTAssertEqual(lowOCR.rejectionReason, .lowOCRConfidence)

        let badFormat = engine.fuse(timestamp: 0, value: .nan, unit: nil, rawText: "junk",
                                    ocrConfidence: 0.9, formatValid: false, physicalRejection: nil,
                                    temporalConsistency: 1, temporalRejected: false,
                                    decimal: decimal)
        XCTAssertEqual(badFormat.rejectionReason, .invalidFormat)
    }

    /// The parser's own reason survives the format gate instead of being
    /// flattened to `INVALID_FORMAT` — a dropped separator and unparseable
    /// junk are different failures and must be reported as such.
    func testParserRejectionReasonSurvivesFusion() {
        let m = engine.fuse(timestamp: 0, value: .nan, unit: nil, rawText: "12345",
                            ocrConfidence: 0.9, formatValid: false, physicalRejection: nil,
                            temporalConsistency: 1, temporalRejected: false,
                            formatRejection: .ambiguousDecimal)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .ambiguousDecimal)
    }

    /// The written form reaches the `Measurement`, so structured output can
    /// render `1.000` rather than `1`.
    func testDisplayTextReachesTheMeasurement() throws {
        let reading = try extracted("1.000")
        let m = engine.fuse(timestamp: 0, value: reading.value, unit: nil, rawText: "1.000",
                            ocrConfidence: 0.9, formatValid: true, physicalRejection: nil,
                            temporalConsistency: 1, temporalRejected: false,
                            decimal: reading.decimal, displayText: reading.text)
        XCTAssertEqual(m.displayText, "1.000")
        XCTAssertEqual(m.value, 1.0)
        XCTAssertEqual(m.decimal?.fractionDigitCount, 3)
    }

    // MARK: - Order-of-magnitude property

    /// The failure this gate exists for, stated as a property: for every
    /// positive vector, dropping the separator must never yield a value the
    /// parser will publish.
    func testDroppingTheSeparatorNeverPublishesTheShiftedValue() {
        for text in ["12.345", "0.001", "-1.25", "1234.5", "1.000"] {
            let stripped = text.replacingOccurrences(of: ".", with: "")
            let shifted = FormatValidator.value(from: stripped, format: strict)
            XCTAssertEqual(shifted, .invalid(.ambiguousDecimal),
                           "'\(stripped)' (from '\(text)') must not be published under a format "
                           + "that declares a separator")
        }
    }
}
