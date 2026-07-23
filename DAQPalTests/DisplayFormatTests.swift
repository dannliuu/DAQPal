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
}
