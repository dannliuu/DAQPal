//
//  FormatValidatorTests.swift
//  DAQPalTests
//
//  Exercises `FormatValidator.parse(_:format:)` against the spec's Mode 2
//  examples (5-digit / decimalPosition 2) plus the integer and
//  decimalPosition-0 shapes and the documented OCR confusable normalization.
//

import XCTest
@testable import DAQPal

final class FormatValidatorTests: XCTestCase {

    /// The spec's canonical 5-digit / decimalPosition-2 grammar, e.g. `XX.XXX`.
    private let signed = DisplayFormat(digitCount: 5, decimalPosition: 2,
                                       signAllowed: true, unit: "V",
                                       minimumValue: -20, maximumValue: 20)
    private let unsigned = DisplayFormat(digitCount: 5, decimalPosition: 2,
                                         signAllowed: false, unit: "V",
                                         minimumValue: 0, maximumValue: 20)

    // MARK: - Valid vectors (spec examples)

    func testValid_plainPositive() {
        XCTAssertEqual(FormatValidator.parse("12.347", format: signed), .valid(12.347))
    }

    func testValid_negativeWithSignAllowed() {
        XCTAssertEqual(FormatValidator.parse("-1.234", format: signed), .valid(-1.234))
    }

    func testValid_maxDigits() {
        XCTAssertEqual(FormatValidator.parse("19.999", format: signed), .valid(19.999))
    }

    func testValid_explicitPlusSign() {
        XCTAssertEqual(FormatValidator.parse("+1.234", format: signed), .valid(1.234))
    }

    func testValid_unitSuffixStripped() {
        // Trailing configured unit, space-separated, is tolerated.
        XCTAssertEqual(FormatValidator.parse("12.347 V", format: signed), .valid(12.347))
    }

    func testValid_unitSuffixStrippedNoSpace() {
        XCTAssertEqual(FormatValidator.parse("12.347V", format: signed), .valid(12.347))
    }

    // MARK: - Invalid vectors (spec examples)

    func testInvalid_strayLetterSurvivesConfusableNormalization() {
        // "B" -> "8" is a documented confusable, but "A" is not, so the
        // grammar check must still fail on the untouched "A".
        guard case .invalid = FormatValidator.parse("1A.34B", format: signed) else {
            return XCTFail("expected invalid due to stray letter 'A'")
        }
    }

    func testInvalid_doubleDecimalPoint() {
        guard case .invalid = FormatValidator.parse("12..34", format: signed) else {
            return XCTFail("expected invalid: two separators split into 3 parts")
        }
    }

    func testInvalid_tooManyDigits() {
        guard case .invalid = FormatValidator.parse("123.4567", format: signed) else {
            return XCTFail("expected invalid: exceeds both integer and fraction digit counts")
        }
    }

    func testInvalid_twoSeparators() {
        guard case .invalid = FormatValidator.parse("12.34.7", format: signed) else {
            return XCTFail("expected invalid: two '.' characters")
        }
    }

    func testInvalid_signWhenDisallowed() {
        guard case .invalid = FormatValidator.parse("-1.234", format: unsigned) else {
            return XCTFail("expected invalid: sign not allowed by this format")
        }
    }

    func testInvalid_wrongDecimalPosition() {
        // 3 integer digits exceeds decimalPosition == 2.
        guard case .invalid = FormatValidator.parse("123.47", format: signed) else {
            return XCTFail("expected invalid: integer part longer than decimalPosition")
        }
    }

    func testInvalid_wrongFractionDigitCount() {
        // Only 2 fraction digits, format requires digitCount - decimalPosition == 3.
        guard case .invalid = FormatValidator.parse("12.34", format: signed) else {
            return XCTFail("expected invalid: fraction digit count must equal digitCount - decimalPosition")
        }
    }

    func testInvalid_empty() {
        guard case .invalid = FormatValidator.parse("", format: signed) else {
            return XCTFail("expected invalid: empty text")
        }
    }

    // MARK: - Integer format (decimalPosition == nil)

    func testIntegerFormat_fullDigitsValid() {
        let integerFormat = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                          signAllowed: false, unit: nil,
                                          minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(FormatValidator.parse("12345", format: integerFormat), .valid(12345))
    }

    func testIntegerFormat_fewerLeadingDigitsValid() {
        // Documented choice: fewer leading digits are accepted (leading-blanked
        // display), matching the same allowance as the decimal case.
        let integerFormat = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                          signAllowed: false, unit: nil,
                                          minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(FormatValidator.parse("123", format: integerFormat), .valid(123))
    }

    func testIntegerFormat_rejectsSeparator() {
        let integerFormat = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                          signAllowed: false, unit: nil,
                                          minimumValue: nil, maximumValue: nil)
        guard case .invalid = FormatValidator.parse("12.345", format: integerFormat) else {
            return XCTFail("expected invalid: decimalPosition nil means no separator allowed")
        }
    }

    // MARK: - decimalPosition == 0 (".XXXXX")

    func testDecimalPositionZero_valid() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 0,
                                   signAllowed: true, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(FormatValidator.parse(".12345", format: format), .valid(0.12345))
    }

    func testDecimalPositionZero_signedValid() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 0,
                                   signAllowed: true, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(FormatValidator.parse("-.12345", format: format), .valid(-0.12345))
    }

    func testDecimalPositionZero_rejectsLeadingDigit() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 0,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        guard case .invalid = FormatValidator.parse("1.2345", format: format) else {
            return XCTFail("expected invalid: decimalPosition 0 requires an empty integer part")
        }
    }

    // MARK: - OCR confusable normalization

    func testConfusable_letterOBecomesZero() {
        XCTAssertEqual(FormatValidator.parse("O2.347", format: signed), .valid(2.347))
    }

    func testConfusable_lowercaseLBecomesOne() {
        XCTAssertEqual(FormatValidator.parse("l2.347", format: signed), .valid(12.347))
    }

    func testConfusable_capitalIBecomesOne() {
        XCTAssertEqual(FormatValidator.parse("I2.347", format: signed), .valid(12.347))
    }

    func testConfusable_SBecomesFive() {
        XCTAssertEqual(FormatValidator.parse("1S.234", format: signed), .valid(15.234))
    }

    func testConfusable_BBecomesEight() {
        XCTAssertEqual(FormatValidator.parse("1B.234", format: signed), .valid(18.234))
    }

    // MARK: - Instance forwarding

    func testInstanceMethodForwardsToStatic() {
        let validator = FormatValidator()
        XCTAssertEqual(validator.parse("12.347", format: signed),
                       FormatValidator.parse("12.347", format: signed))
    }

    // MARK: - Lenient numeric extraction (spec Mode 3 — unknown format)

    /// A dimensionless, unconstrained format like a freshly added device.
    private let lenient = DisplayFormat(digitCount: 5, decimalPosition: 2,
                                        signAllowed: true, unit: nil,
                                        minimumValue: nil, maximumValue: nil,
                                        constrainToFormat: false)

    func testExtract_ignoresSurroundingText() {
        let result = FormatValidator.extractNumber(from: "AUTO 12.3 mV")
        XCTAssertEqual(result?.value, 12.3)
        XCTAssertEqual(result?.matched, "12.3")
    }

    func testExtract_leadingSignAndBareDecimal() {
        let result = FormatValidator.extractNumber(from: "-.5")
        XCTAssertEqual(result?.value, -0.5)
        XCTAssertEqual(result?.matched, "-.5")
    }

    func testExtract_doubledSeparatorIsRejectedNotCoerced() {
        // DELIBERATE BEHAVIOUR CHANGE (spec §11A / Gate 11A). This test
        // previously asserted that "12.34.7" was COERCED to 12.34 by taking the
        // "richest token". That is exactly the failure mode §11A forbids: a
        // malformed decimal must never be silently reinterpreted as a
        // well-formed one, because the result is numerically valid and wrong.
        // `12.34.5` is listed verbatim in the spec's negative vectors as
        // "must be rejected, not coerced". Rejecting loses one reading;
        // coercing silently corrupts the recorded series.
        XCTAssertNil(FormatValidator.extractNumber(from: "12.34.7"))
    }

    func testExtract_singleSeparatorStillExtractsNormally() {
        // The rejection above must not have broken ordinary lenient extraction.
        let result = FormatValidator.extractNumber(from: "AUTO 12.34 mV")
        XCTAssertEqual(result?.value, 12.34)
        XCTAssertEqual(result?.matched, "12.34")
    }

    func testExtract_noDigitsReturnsNil() {
        XCTAssertNil(FormatValidator.extractNumber(from: "HOLD"))
    }

    func testExtract_appliesConfusableNormalizationBeforeTokenizing() {
        // l->1 and O->0 run before the numeric scan, so "l2.3O" -> "12.30".
        let result = FormatValidator.extractNumber(from: "l2.3O")
        XCTAssertEqual(result?.value, 12.30)
        XCTAssertEqual(result?.matched, "12.30")
    }

    // MARK: - value(from:format:) dispatch on constrainToFormat

    func testDispatch_constrainedStaysStrict() {
        // The trailing junk lenient mode tolerates must still be rejected under
        // the strict grammar when the format is constrained.
        guard case .invalid = FormatValidator.value(from: "12.34.7", format: signed) else {
            return XCTFail("constrained dispatch must reject via the strict grammar")
        }
        XCTAssertEqual(FormatValidator.value(from: "12.347", format: signed), .valid(12.347))
    }

    func testDispatch_unconstrainedUsesLenientExtraction() {
        XCTAssertEqual(FormatValidator.value(from: "AUTO 12.3 mV", format: lenient), .valid(12.3))
    }

    func testDispatch_lenientRejectsMalformedDecimalRatherThanCoercing() {
        // See `testExtract_doubledSeparatorIsRejectedNotCoerced`: lenient mode
        // is lenient about SURROUNDING junk, never about the decimal itself.
        //
        // The reason is `.invalidFormat`, not `.ambiguousDecimal`, and the
        // distinction is deliberate: "12.34.7" is structurally MALFORMED — no
        // reading of it is well-formed — whereas `.ambiguousDecimal` means the
        // digits are fine but the separator's presence or position cannot be
        // determined ("12 345", or a grouped "12,345" with no declared format).
        // Spec §11A requires these be rejected rather than coerced; it does not
        // dictate which rejection reason, and conflating the two would make the
        // ambiguity signal useless for diagnosing real decimal loss.
        XCTAssertEqual(FormatValidator.value(from: "12.34.7", format: lenient),
                       .invalid(.invalidFormat))
    }

    func testDispatch_lenientKeepsTwoSeparateReadingsOnOneLine() {
        // Regression guard for the over-rejection introduced with the split
        // detector: a whitespace gap only means "one number split in two" when
        // NEITHER side kept a separator. Two well-formed decimals on one line
        // are two readings, not one broken one, and must not be rejected —
        // `ScreenCandidateDetector.numericScore` uses this same entry point as a
        // display-detection heuristic, so rejecting here would make real
        // multi-value instrument panels harder to detect as screens.
        if case .invalid = FormatValidator.value(from: "12.3 45.6", format: lenient) {
            XCTFail("A line carrying two well-formed decimals must not be rejected as ambiguous.")
        }
    }

    func testDispatch_lenientStillRejectsAGenuineSplitReading() {
        // The case the split detector exists for: two BARE digit runs separated
        // by whitespace is the signature of a dropped separator ("12 345"), and
        // picking either fragment would be an order-of-magnitude error.
        XCTAssertEqual(FormatValidator.value(from: "12 345", format: lenient),
                       .invalid(.ambiguousDecimal))
    }

    func testDispatch_unconstrainedNoDigitsIsInvalidFormat() {
        XCTAssertEqual(FormatValidator.value(from: "HOLD", format: .unconstrained),
                       .invalid(.invalidFormat))
    }

    func testDispatch_instanceForwardsToStatic() {
        let validator = FormatValidator()
        XCTAssertEqual(validator.value(from: "AUTO 12.3", format: lenient),
                       FormatValidator.value(from: "AUTO 12.3", format: lenient))
    }

    // MARK: - Larger strict grammar (10-digit / decimalPosition 4)
    //
    // The strict parse has no built-in digit-count ceiling (the 4/5/6 limit was
    // only the old sheet UI), so a high-count format must enforce its grammar
    // exactly the way the 5-digit case does.

    /// 4 integer digits + 6 fraction digits (digitCount 10 − decimalPosition 4).
    private let tenDigitFourDecimal = DisplayFormat(digitCount: 10, decimalPosition: 4,
                                                    signAllowed: true, unit: nil,
                                                    minimumValue: nil, maximumValue: nil)

    func testLargeFormat_exactCountValid() {
        XCTAssertEqual(FormatValidator.parse("1000.500000", format: tenDigitFourDecimal), .valid(1000.5))
    }

    func testLargeFormat_offByOneFractionInvalid() {
        // 5 fraction digits where the grammar requires exactly 6.
        guard case .invalid = FormatValidator.parse("1000.50000", format: tenDigitFourDecimal) else {
            return XCTFail("expected invalid: fraction digit count must equal digitCount − decimalPosition")
        }
    }

    func testLargeFormat_offByOneIntegerInvalid() {
        // 5 integer digits exceeds decimalPosition == 4.
        guard case .invalid = FormatValidator.parse("12345.567890", format: tenDigitFourDecimal) else {
            return XCTFail("expected invalid: integer part longer than decimalPosition")
        }
    }

    func testLargeFormat_leadingBlankAllowanceApplies() {
        // Fewer leading integer digits are accepted (leading-blanked display),
        // the same allowance the 5-digit format relies on.
        XCTAssertEqual(FormatValidator.parse("5.500000", format: tenDigitFourDecimal), .valid(5.5))
        XCTAssertEqual(FormatValidator.parse("-5.500000", format: tenDigitFourDecimal), .valid(-5.5))
    }
}
