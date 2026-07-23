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
}
