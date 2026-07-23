//
//  DigitSegmenterTests.swift
//  DAQPalTests
//
//  Geometry coverage for the documented fixed-pitch digit-cell STUB
//  (`DigitSegmenter`). Not an accuracy test — this only checks the cell
//  count/geometry contract the pipeline relies on.
//

import XCTest
@testable import DAQPal

final class DigitSegmenterTests: XCTestCase {

    private let segmenter = DigitSegmenter()
    private let roi = NormalizedROI(x: 0.1, y: 0.4, width: 0.6, height: 0.15)

    private func format(digitCount: Int, decimalPosition: Int? = 2) -> DisplayFormat {
        DisplayFormat(digitCount: digitCount, decimalPosition: decimalPosition,
                     signAllowed: true, unit: "V", minimumValue: nil, maximumValue: nil)
    }

    func testCellCount_matchesDigitCount() {
        for digitCount in [4, 5, 6] {
            let cells = segmenter.digitCells(in: roi, format: format(digitCount: digitCount))
            XCTAssertEqual(cells.count, digitCount)
        }
    }

    func testCells_equalWidth() {
        let cells = segmenter.digitCells(in: roi, format: format(digitCount: 5))
        let expectedWidth = roi.width / 5
        for cell in cells {
            XCTAssertEqual(cell.width, expectedWidth, accuracy: 1e-9)
        }
    }

    func testCells_spanFullHeightOfROI() {
        let cells = segmenter.digitCells(in: roi, format: format(digitCount: 6))
        for cell in cells {
            XCTAssertEqual(cell.y, roi.y, accuracy: 1e-9)
            XCTAssertEqual(cell.height, roi.height, accuracy: 1e-9)
        }
    }

    func testCells_leftToRightWithNoGapsOrOverlaps() {
        let cells = segmenter.digitCells(in: roi, format: format(digitCount: 5))
        XCTAssertEqual(cells.first!.x, roi.x, accuracy: 1e-9)
        for i in 1..<cells.count {
            // Each cell starts exactly where the previous one ended.
            XCTAssertEqual(cells[i].x, cells[i - 1].x + cells[i - 1].width, accuracy: 1e-9)
        }
        let last = cells.last!
        XCTAssertEqual(last.x + last.width, roi.x + roi.width, accuracy: 1e-9)
    }

    func testCells_sumOfWidthsEqualsROIWidth() {
        let cells = segmenter.digitCells(in: roi, format: format(digitCount: 4))
        let totalWidth = cells.reduce(0) { $0 + $1.width }
        XCTAssertEqual(totalWidth, roi.width, accuracy: 1e-9)
    }

    func testCells_independentOfDecimalPosition() {
        // Per the documented stub, the decimal separator gets no cell of its
        // own — cell geometry depends only on digitCount.
        let withDecimal = segmenter.digitCells(in: roi, format: format(digitCount: 5, decimalPosition: 2))
        let integerOnly = segmenter.digitCells(in: roi, format: format(digitCount: 5, decimalPosition: nil))
        XCTAssertEqual(withDecimal, integerOnly)
    }

    func testZeroDigitCount_producesNoCells() {
        let cells = segmenter.digitCells(in: roi, format: format(digitCount: 0, decimalPosition: nil))
        XCTAssertTrue(cells.isEmpty)
    }
}
