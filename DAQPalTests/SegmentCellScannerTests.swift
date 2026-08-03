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
import UIKit
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

    // MARK: - Row identity on the real instrument (two stacked readings)

    /// The real instrument photo, cropped to the LCD and rotated upright.
    /// Loader copied from `NumberBandSplitterTests` — the same fixture, read the
    /// same way, so a bundling change fails both tests identically.
    private func realDisplayBuffer() throws -> CVPixelBuffer {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "ir_gun_display", withExtension: "png") else {
            throw XCTSkip("ir_gun_display.png fixture not present in the test bundle")
        }
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data)?.cgImage else {
            throw XCTSkip("fixture could not be decoded")
        }
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        let out = try XCTUnwrap(pb, "could not allocate pixel buffer")
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out),
                            width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        try XCTUnwrap(ctx).draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }

    /// The target instrument shows two readings stacked. Row identity must
    /// separate a large main reading from a smaller legend line, or a merged
    /// band would count legend glyphs as digits.
    ///
    /// THIS IS THE ONLY GUARD ON THE MERGE'S ACCEPTANCE TEST. The band merge is
    /// triggered by a wide-and-flat aspect, and on this photo the annunciator
    /// strip trips that trigger legitimately; only the glyph-count proof refuses
    /// it. Measured: accepting that merge collapses the 90.0 reading to 2 digit
    /// runs with no separator. No synthetic render reproduces this — the
    /// generator cannot draw two lines — so weakening this test silently loses
    /// the target instrument's primary reading.
    func testTwoRowInstrumentSplitsMainReadingFromLegendLine() throws {
        let rows = SegmentCellScanner.scan(try realDisplayBuffer())
        let report = rows.map { String(format: "y=%.3f..%.3f digits=%d sep=%@ %@",
                                       $0.band.y, $0.band.y + $0.band.height, $0.digitCount,
                                       $0.separatorPosition.map(String.init) ?? "nil",
                                       String(describing: $0.integrity)) }
            .joined(separator: "\n  ")
        // NOT `.first`: on a real crop the topmost band is a digit-less strip.
        let readings = rows.filter { $0.digitCount >= 2 }
        XCTAssertGreaterThanOrEqual(readings.count, 2,
                                    "expected the main reading and the MAX line as separate rows:\n  \(report)")
        let main = try XCTUnwrap(readings.max(by: { $0.band.height < $1.band.height }))
        XCTAssertEqual(main.separatorPosition, 2, "main reading 90.0 — \(main.rationale)")
        XCTAssertEqual(main.integrity, .clean)
        XCTAssertLessThan(main.band.height, 0.55,
                          "a row spanning both lines means they were merged:\n  \(report)")
        let below = readings.filter { $0.band.y > main.band.y + main.band.height }
        XCTAssertFalse(below.isEmpty, "the MAX line was absorbed into the main row:\n  \(report)")
        for row in below where row.separatorPosition != nil {
            XCTAssertEqual(row.separatorPosition, 2, "92.7 — wrong position \(row.rationale)")
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

    /// Column scanning is not segment-specific — segmentation must hold up on
    /// the proportional face too. It does: the digit count is exact.
    ///
    /// DECIMAL RECALL ON PROPORTIONAL FACES IS A KNOWN OPEN GAP, and this test
    /// asserts the SAFETY form (correct or none) rather than a recall guarantee
    /// the component does not provide. Measured 2026-08-03 on sans "12.345":
    /// three separator candidates survive shape screening — a peel off the '2'
    /// (x89-116, aspect 1.75), the REAL dot as a native run (x254-285, aspect
    /// 1.00), and a peel off the '4' (x495-510, base 0.20) — so the band is
    /// multi-candidate and the position is suppressed.
    ///
    /// Do NOT "fix" this by preferring native runs over peeled ones. That was
    /// implemented and reverted the same day: it recovers this dot but converts
    /// 7 of HEAD's refusals into WRONG positions across a 600-case differential
    /// (see the peel-policy note in SegmentCellScanner.swift). A wrong decimal
    /// position is a silent factor-of-ten error in exported data; a missing one
    /// only costs recall. For the record, HEAD reported 3 here — wrong — so
    /// suppression is already a strict improvement on this case.
    func testProportionalFaceAlsoSegments() throws {
        guard let row = try scanSingleRow("12.345", style: .sans) else {
            return XCTFail("no row for sans '12.345'")
        }
        XCTAssertEqual(row.digitCount, 5, "sans '12.345' digit count — \(row.rationale)")
        if let position = row.separatorPosition {
            XCTAssertEqual(position, 2,
                           "sans '12.345': reported a WRONG position \(position) — \(row.rationale)")
        }
    }
}
