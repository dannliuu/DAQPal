//
//  SegmentCellScannerTests.swift
//  DAQPalTests
//
//  Exercises the column-scan cell segmenter against the Phase 1 synthetic
//  generator's DSEG7 renders — the display technology `DecimalRescue` measurably
//  cannot segment.
//
//  THE POINT OF THIS FILE. `DecimalRescueTests` records, as a measured fact,
//  that connected-component labeling on a clean DSEG7 "80.8" finds 21 components
//  and no digits, so the separator's position is unrecoverable there. These
//  tests assert the same input now yields a POSITION, and — more importantly —
//  that the safety property is preserved: across every preset the scanner
//  reports either the correct position or none, never a wrong one. A wrong
//  decimal position is a silent factor-of-ten error in exported data; a missing
//  one only costs recall and is resolved upstream by the format prior and
//  `TemporalConsensus`.
//
//  These are correctness tests over SYNTHETIC glyphs. They make no claim about
//  recognition accuracy on real instruments.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class SegmentCellScannerTests: XCTestCase {

    private func makeGenerator() throws -> SyntheticDisplayGenerator {
        try SyntheticDisplayGenerator()
    }

    /// Digits before the separator, from the literal — the ground truth every
    /// assertion below compares against.
    private func expectedPosition(_ text: String) -> Int? {
        guard let dot = text.firstIndex(of: ".") else { return nil }
        return text[text.startIndex..<dot].filter(\.isNumber).count
    }

    private func scanSingleRow(_ text: String,
                               style: DisplayGlyphStyle = .sevenSegment,
                               augmentation: DisplayAugmentation = .clean,
                               name: String = "clean") throws -> SegmentCellScanner.Row? {
        let generator = try makeGenerator()
        let sample = try generator.lineSample(text: text, style: style,
                                              augmentation: augmentation,
                                              augmentationName: name)
        return SegmentCellScanner.scan(sample.pixelBuffer).first
    }

    // MARK: - The case connected components cannot do

    /// `DecimalRescueTests.testSegmentFacesAreNotSegmentedByThisLayer` asserts
    /// the component labeler reports NO position for this exact input. Column
    /// scanning recovers it, which is the entire reason this component exists.
    func testDSEG7DecimalPositionRecoveredWhereComponentLabelingCannot() throws {
        let generator = try makeGenerator()
        let sample = try generator.lineSample(text: "80.8", style: .sevenSegment,
                                              augmentation: .clean, augmentationName: "clean")

        // Baseline: the existing layer still cannot place it, so this test is
        // measuring a real delta rather than restating something already true.
        let rescue = DecimalRescue.analyze(canonicalImage: sample.pixelBuffer, digitCount: 3)
        XCTAssertNil(rescue.position,
                     "precondition changed — DecimalRescue now reports a position for DSEG7 '80.8' (\(rescue.rationale))")

        guard let row = SegmentCellScanner.scan(sample.pixelBuffer).first else {
            return XCTFail("scanner found no row in DSEG7 '80.8'")
        }
        XCTAssertEqual(row.digitCount, 3,
                       "DSEG7 '80.8' should segment into 3 digit runs — \(row.rationale)")
        XCTAssertEqual(row.separatorPosition, 2,
                       "DSEG7 '80.8' separator should follow 2 digits — \(row.rationale)")
        XCTAssertEqual(row.integrity, .clean, "band integrity — \(row.rationale)")
    }

    // MARK: - The spec's decimal regression battery

    /// The literals named in the spec's decimal-integrity section.
    func testDecimalPositionAcrossFormatBattery() throws {
        let cases = ["12.345", "0.001", "99.9", "-1.25", "100.0", "808"]
        for text in cases {
            guard let row = try scanSingleRow(text) else {
                XCTFail("scanner found no row for DSEG7 '\(text)'")
                continue
            }
            XCTAssertEqual(row.separatorPosition, expectedPosition(text),
                           "DSEG7 '\(text)': position \(row.separatorPosition.map(String.init) ?? "nil") — \(row.rationale)")
            XCTAssertEqual(row.digitCount, text.filter(\.isNumber).count,
                           "DSEG7 '\(text)': digit count — \(row.rationale)")
        }
    }

    /// Leading-zero suppression is universal on multimeters, and it is the case
    /// `DecimalRescue` structurally cannot see (its candidates must sit BETWEEN
    /// two digits). The scanner is not blocked by that geometry, but a single
    /// digit still leaves nothing to corroborate against, so this asserts the
    /// honest outcome — never a wrong position — rather than a recall win the
    /// implementation does not yet earn.
    func testLeadingSeparatorNeverReportsAWrongPosition() throws {
        for text in [".5", ".808"] {
            guard let row = try scanSingleRow(text) else { continue }
            if let position = row.separatorPosition {
                XCTAssertEqual(position, 0,
                               "DSEG7 '\(text)': leading separator reported as position \(position) — \(row.rationale)")
            }
        }
    }

    // MARK: - Safety property under optical degradation

    /// The property that matters most: degrade the image however you like, and
    /// the answer is correct or absent — never wrong. Bloom fusing two glyphs
    /// into one column run must surface as `.fused` and suppress the position,
    /// not shift it by one.
    func testNeverReportsAWrongPositionAcrossPresets() throws {
        let generator = try makeGenerator()
        var reported = 0
        var suppressed = 0
        for text in ["12.345", "80.8", "99.9", "100.0"] {
            let truth = expectedPosition(text)
            for preset in DisplayAugmentation.presets {
                let sample = try generator.lineSample(text: text, style: .sevenSegment,
                                                      augmentation: preset.augmentation,
                                                      augmentationName: preset.name)
                guard let row = SegmentCellScanner.scan(sample.pixelBuffer).first else {
                    suppressed += 1
                    continue
                }
                if let position = row.separatorPosition {
                    XCTAssertEqual(position, truth,
                                   "DSEG7/\(preset.name) '\(text)': WRONG position \(position), expected \(truth.map(String.init) ?? "nil") — \(row.rationale)")
                    reported += 1
                } else {
                    suppressed += 1
                }
            }
        }
        // Reported as a measurement, not asserted as a threshold: recall under
        // degradation is what the physical-device session exists to establish.
        print("SegmentCellScanner preset sweep: \(reported) positions reported, \(suppressed) suppressed")
        XCTAssertGreaterThan(reported, 0, "no position survived any preset — the scanner is inert")
    }

    // MARK: - End-to-end: cells feed the existing sampler

    /// The cells exist to be read. This closes the loop through
    /// `SevenSegmentSampler` and reconstructs the literal, which is the only
    /// test here that proves the cell BOUNDARIES are right rather than merely
    /// countable — a cell offset by half a glyph still counts to three.
    func testCellsReconstructTheReadingThroughSevenSegmentSampler() throws {
        let generator = try makeGenerator()
        let sampler = SevenSegmentSampler()
        for text in ["80.8", "12.345", "99.9"] {
            let sample = try generator.lineSample(text: text, style: .sevenSegment,
                                                  augmentation: .clean, augmentationName: "clean")
            guard let row = SegmentCellScanner.scan(sample.pixelBuffer).first else {
                XCTFail("no row for '\(text)'")
                continue
            }
            var decoded = ""
            for cell in row.cells {
                switch cell.kind {
                case .digit:
                    let reading = sampler.readDigit(in: sample.pixelBuffer, cell: cell.region)
                    decoded.append(reading.digit ?? "?")
                case .separator:
                    decoded.append(".")
                case .minus:
                    decoded.append("-")
                }
            }
            XCTAssertEqual(decoded, text,
                           "DSEG7 '\(text)' reconstructed as '\(decoded)' — \(row.rationale)")
        }
    }

    // MARK: - Determinism

    func testScanIsDeterministic() throws {
        let generator = try makeGenerator()
        let sample = try generator.lineSample(text: "12.345", style: .sevenSegment,
                                              augmentation: .moderate, augmentationName: "moderate")
        let first = SegmentCellScanner.scan(sample.pixelBuffer)
        let second = SegmentCellScanner.scan(sample.pixelBuffer)
        XCTAssertEqual(first, second, "same buffer produced different scans")
    }

    // MARK: - Raster faces still work

    /// Column scanning is not segment-specific — it should hold up on the
    /// proportional face too, where each glyph is one component and the existing
    /// layer already worked. A regression here would mean the new path cannot
    /// simply replace the old one.
    func testProportionalFaceAlsoSegments() throws {
        guard let row = try scanSingleRow("12.345", style: .sans) else {
            return XCTFail("no row for sans '12.345'")
        }
        XCTAssertEqual(row.digitCount, 5, "sans '12.345' digit count — \(row.rationale)")
        XCTAssertEqual(row.separatorPosition, 2, "sans '12.345' position — \(row.rationale)")
    }
}
