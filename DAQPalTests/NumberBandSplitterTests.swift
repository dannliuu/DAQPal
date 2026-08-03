//
//  NumberBandSplitterTests.swift
//  DAQPalTests
//
//  Validated against a PHOTOGRAPH OF THE REAL TARGET INSTRUMENT
//  (`Fixtures/ir_gun_display.png`) — an IR thermometer showing `90.0` large
//  with `92.7` smaller beside a `MAX` legend. Every prior decimal/field result
//  in this project was measured on synthetic renders; this is the first test
//  driven by the actual hardware, which is the only thing that can tell us
//  whether the feature works for its intended user.
//
//  The splitter deliberately favours RECALL: the user picks the box they want,
//  so a spurious candidate costs one ignored rectangle while a missed reading
//  costs the feature. Assertions are written accordingly — they require the two
//  readings to be found and separated, not that nothing else is offered.
//

import CoreVideo
import UIKit
import XCTest
@testable import DAQPal

final class NumberBandSplitterTests: XCTestCase {

    // MARK: Fixture loading

    /// The real instrument photo, cropped to the LCD and rotated upright.
    private func realDisplayBuffer() throws -> CVPixelBuffer {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "ir_gun_display", withExtension: "png") else {
            throw XCTSkip("ir_gun_display.png fixture not present in the test bundle")
        }
        let data = try Data(contentsOf: url)
        guard let image = UIImage(data: data)?.cgImage else {
            throw XCTSkip("fixture could not be decoded")
        }
        return try buffer(from: image)
    }

    private func buffer(from image: CGImage) throws -> CVPixelBuffer {
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

    // MARK: The headline case — the real device

    func testRealInstrument_findsBothReadingsAsSeparateCandidates() throws {
        let candidates = NumberBandSplitter.candidates(in: try realDisplayBuffer())

        // Diagnostic first: a failure here should say WHAT was found, because
        // the whole feasibility question is "does projection localize these".
        let report = candidates.enumerated().map { i, c in
            String(format: "  [%d] x=%.3f y=%.3f w=%.3f h=%.3f glyphH=%.3f ink=%.2f",
                   i, c.region.x, c.region.y, c.region.width, c.region.height,
                   c.glyphHeight, c.inkDensity)
        }.joined(separator: "\n")
        print("=== NumberBandSplitter on REAL IR gun display ===\n\(report)")

        XCTAssertGreaterThanOrEqual(candidates.count, 2,
            "Expected at least the two readings (90.0 and 92.7). Got \(candidates.count):\n\(report)")

        // The primary reading is the tallest element and sits in the upper half
        // of the LCD; MAX is shorter and lower. Rank order must reflect that.
        let primary = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(primary.glyphHeight, 0.10,
            "Primary glyph height implausibly small — the band was probably split.\n\(report)")

        // A separate candidate must exist BELOW the primary: the MAX reading.
        let below = candidates.dropFirst().filter { $0.region.y > primary.region.y }
        XCTAssertFalse(below.isEmpty,
            "No candidate found below the primary reading — 90.0 and 92.7 were not separated.\n\(report)")

        // …and it must be genuinely smaller, which is the signal the UI ranks on.
        let secondary = try XCTUnwrap(below.max(by: { $0.glyphHeight < $1.glyphHeight }))
        XCTAssertLessThan(secondary.glyphHeight, primary.glyphHeight,
            "The MAX reading should be shorter than the primary.\n\(report)")
    }

    /// The `MAX` legend sits on the same row as the `92.7` reading. Column
    /// grouping must split them, or selecting "the MAX number" would hand OCR a
    /// box containing the word MAX.
    func testRealInstrument_separatesLegendFromReadingOnTheSameRow() throws {
        let candidates = NumberBandSplitter.candidates(in: try realDisplayBuffer())
        let lower = candidates.filter { $0.region.y > 0.45 }
        XCTAssertGreaterThanOrEqual(lower.count, 2,
            "Expected the MAX legend and the 92.7 reading as separate candidates on the lower band; got \(lower.count)")
        // No single lower candidate may span most of the width — that would mean
        // legend and reading were merged.
        for c in lower {
            XCTAssertLessThan(c.region.width, 0.92,
                "A lower-band candidate spans the full width, so the legend and reading were not separated")
        }
    }

    func testRealInstrument_isDeterministic() throws {
        let a = NumberBandSplitter.candidates(in: try realDisplayBuffer())
        let b = NumberBandSplitter.candidates(in: try realDisplayBuffer())
        XCTAssertEqual(a, b, "Splitting must be reproducible for the same input")
    }

    // MARK: Synthetic controls

    /// One reading, one candidate — the splitter must not manufacture bands.
    func testSyntheticSinglePanel_yieldsOnePrimaryCandidate() throws {
        let renderer = SyntheticDisplayRenderer()
        let frame = try XCTUnwrap(renderer.render(text: "12.345", pose: .identity))
        let crop = try XCTUnwrap(PixelBufferROI.cropped(frame, to: SyntheticDisplayRenderer.displayROI))
        let candidates = NumberBandSplitter.candidates(in: crop)
        XCTAssertGreaterThanOrEqual(candidates.count, 1)
        let primary = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(primary.glyphHeight, 0.2,
                             "A single centred reading should dominate its crop")
    }

    func testDegenerateInput_returnsEmptyRatherThanThrowing() throws {
        var tiny: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA, nil, &tiny)
        let buffer = try XCTUnwrap(tiny)
        XCTAssertTrue(NumberBandSplitter.candidates(in: buffer).isEmpty)
    }

    /// Regions are expressed in the CROP's space, which is what lets a selected
    /// sub-box ride along when the parent window is dragged or resized.
    func testCandidateRegionsAreWithinTheUnitSquare() throws {
        for c in NumberBandSplitter.candidates(in: try realDisplayBuffer()) {
            XCTAssertGreaterThanOrEqual(c.region.x, 0)
            XCTAssertGreaterThanOrEqual(c.region.y, 0)
            XCTAssertLessThanOrEqual(c.region.x + c.region.width, 1.0001)
            XCTAssertLessThanOrEqual(c.region.y + c.region.height, 1.0001)
        }
    }
    /// DIAGNOSTIC: dumps the row ink profile as the shipping grid computes it,
    /// so band-splitting failures are read from the real code path rather than
    /// inferred from a side-channel image conversion (which silently transposed
    /// and cost an hour).
    func testDiagnostic_rowProfileOfRealDisplay() throws {
        let buffer = try realDisplayBuffer()
        print("=== buffer \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer)) ===")
        guard let g = LuminanceGrid(buffer: buffer, maxLongEdge: 900, minEdge: 24) else {
            return XCTFail("grid could not be built")
        }
        let thr = g.inkThreshold()
        print("grid \(g.width)x\(g.height) threshold=\(thr)")
        var prof = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height {
            var n = 0
            for x in 0..<g.width where g.isInk(x, y, thr) { n += 1 }
            prof[y] = n
        }
        let peak = max(1, prof.max() ?? 1)
        let step = max(1, g.height / 34)
        var lines: [String] = []
        for y in stride(from: 0, to: g.height, by: step) {
            let seg = prof[y..<min(g.height, y + step)]
            let avg = seg.reduce(0, +) / max(1, seg.count)
            let bar = String(repeating: "#", count: Int(40 * Double(avg) / Double(peak)))
            lines.append(String(format: "  y=%.3f  %4d %@", Double(y) / Double(g.height), avg, bar))
        }
        print("TRACE:\n" + NumberBandSplitter.debugRowTrace(buffer))
        print("ROW INK PROFILE (peak=\(peak) of width \(g.width)):\n" + lines.joined(separator: "\n"))
    }

}
