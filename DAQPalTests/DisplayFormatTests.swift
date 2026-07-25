//
//  DisplayFormatTests.swift
//  DAQPalTests
//
//  Covers `DisplayFormat`'s derived presentation properties against the
//  doc-comment examples in DisplayFormat.swift.
//

import XCTest
@testable import DAQPal

final class DisplayFormatTests: XCTestCase {

    // MARK: - patternPreview

    func testPatternPreview_defaultDMM() {
        // digitCount 5, decimalPosition 2, signed, unit "V" -> "±XX.XXX V".
        XCTAssertEqual(DisplayFormat.defaultDMM.patternPreview, "±XX.XXX V")
    }

    func testPatternPreview_decimalPositionZero() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 0,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, ".XXXXX")
    }

    func testPatternPreview_integerDisplay() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "XXXXX")
    }

    func testPatternPreview_unsignedNoUnit() {
        let format = DisplayFormat(digitCount: 4, decimalPosition: 1,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "X.XXX")
    }

    // MARK: - fractionDigits

    func testFractionDigits_decimalPositionTwo() {
        XCTAssertEqual(DisplayFormat.defaultDMM.fractionDigits, 3)
    }

    func testFractionDigits_integerDisplay() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.fractionDigits, 0)
    }

    func testFractionDigits_decimalPositionZero() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 0,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.fractionDigits, 5)
    }

    // MARK: - placeholder

    func testPlaceholder_decimalPositionTwo() {
        XCTAssertEqual(DisplayFormat.defaultDMM.placeholder, "——.———")
    }

    func testPlaceholder_integerDisplay() {
        let format = DisplayFormat(digitCount: 4, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.placeholder, "————")
    }

    // MARK: - formatted(_:)

    func testFormatted_finiteValue() {
        XCTAssertEqual(DisplayFormat.defaultDMM.formatted(12.347), "12.347")
    }

    func testFormatted_roundsToFractionDigits() {
        XCTAssertEqual(DisplayFormat.defaultDMM.formatted(12.3456), "12.346")
    }

    func testFormatted_nanFallsBackToPlaceholder() {
        XCTAssertEqual(DisplayFormat.defaultDMM.formatted(.nan), DisplayFormat.defaultDMM.placeholder)
    }

    func testFormatted_integerDisplayHasNoDecimalPoint() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.formatted(12345), "12345")
    }

    // MARK: - Unconstrained (Mode 3) natural formatting
    //
    // The seed digit fields (5/2) must NOT drive rendering when
    // `constrainToFormat == false`; values render naturally so a display
    // showing "230" reads "230", not "230.000" (the reported "awkward digits"
    // issue).

    func testFormatted_unconstrainedIntegerHasNoDecimalPoint() {
        // 230 through the 5/2 seed would have been "230.000"; natural is "230".
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(230), "230")
    }

    func testFormatted_unconstrainedTrimsTrailingZeros() {
        // 12.4 would have been "12.400"; natural trims to "12.4".
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(12.4), "12.4")
    }

    func testFormatted_unconstrainedNegativeSmall() {
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(-0.05), "-0.05")
    }

    func testFormatted_unconstrainedSmallStaysPlainDecimal() {
        // Small magnitudes stay plain decimal, never scientific ("1.23e-04").
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(0.000123), "0.000123")
    }

    func testFormatted_unconstrainedZeroIsBarePlainZero() {
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(0), "0")
    }

    func testFormatted_unconstrainedNaNFallsBackToNeutralPlaceholder() {
        XCTAssertEqual(DisplayFormat.unconstrained.formatted(.nan), "———")
    }

    func testPlaceholder_unconstrainedIsNeutralDashes() {
        // No fake decimal pattern — a neutral "———" regardless of seed digits.
        XCTAssertEqual(DisplayFormat.unconstrained.placeholder, "———")
    }

    func testNaturalString_matchesTrimmingRules() {
        XCTAssertEqual(DisplayFormat.naturalString(230), "230")
        XCTAssertEqual(DisplayFormat.naturalString(12.4), "12.4")
        XCTAssertEqual(DisplayFormat.naturalString(-0.05), "-0.05")
        XCTAssertEqual(DisplayFormat.naturalString(0.000123), "0.000123")
        XCTAssertEqual(DisplayFormat.naturalString(0), "0")
    }

    // MARK: - Arbitrary digit counts (UI now configures any count)
    //
    // The digit-count stepper's bound (`DisplayFormat.digitCountRange`) is a
    // UI limit only; the derived presentation properties themselves have never
    // been bounded, so they must hold from 1 digit up to the widest formats.

    // digitCount 1 + nil decimal — a single-digit integer display, the only
    // shape a 1-digit count can take (no interior separator possible).
    func testSingleDigitInteger_patternPreview() {
        let format = DisplayFormat(digitCount: 1, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "X")
    }

    func testSingleDigitInteger_placeholder() {
        let format = DisplayFormat(digitCount: 1, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.placeholder, "—")
    }

    func testSingleDigitInteger_fractionDigitsAndFormatted() {
        let format = DisplayFormat(digitCount: 1, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.fractionDigits, 0)
        XCTAssertEqual(format.formatted(7), "7")
    }

    // 10 digits / decimalPosition 4 -> 4 integer, 6 fraction.
    func testTenDigitFourDecimal_patternPreview() {
        let format = DisplayFormat(digitCount: 10, decimalPosition: 4,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "XXXX.XXXXXX")
    }

    func testTenDigitFourDecimal_placeholderAndFractionDigits() {
        let format = DisplayFormat(digitCount: 10, decimalPosition: 4,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.placeholder, "————.——————")
        XCTAssertEqual(format.fractionDigits, 6)
    }

    // 12 digits / decimalPosition 11 -> 11 integer, 1 fraction.
    func testTwelveDigitElevenDecimal_patternPreview() {
        let format = DisplayFormat(digitCount: 12, decimalPosition: 11,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "XXXXXXXXXXX.X")
    }

    func testTwelveDigitElevenDecimal_placeholderAndFractionDigits() {
        let format = DisplayFormat(digitCount: 12, decimalPosition: 11,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.placeholder, "———————————.—")
        XCTAssertEqual(format.fractionDigits, 1)
    }

    // The widest signed pattern the sheet can now produce (12/9): this is the
    // ±XXXXXXXXX.XXX string the preview panel scales down to fit.
    func testTwelveDigitSigned_patternPreview() {
        let format = DisplayFormat(digitCount: 12, decimalPosition: 9,
                                   signAllowed: true, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "±XXXXXXXXX.XXX")
    }

    // decimalPosition nil at a larger count -> a wide integer display.
    func testLargeIntegerDisplay_nilDecimal() {
        let format = DisplayFormat(digitCount: 10, decimalPosition: nil,
                                   signAllowed: false, unit: nil,
                                   minimumValue: nil, maximumValue: nil)
        XCTAssertEqual(format.patternPreview, "XXXXXXXXXX")
        XCTAssertEqual(format.placeholder, "——————————")
        XCTAssertEqual(format.fractionDigits, 0)
        XCTAssertEqual(format.formatted(1234567890), "1234567890")
    }
}
