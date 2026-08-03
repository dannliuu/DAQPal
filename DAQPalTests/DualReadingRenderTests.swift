//
//  DualReadingRenderTests.swift
//  DAQPalTests
//
//  The Simulator's synthetic panel showed exactly one number, so window
//  sub-field selection — which only engages when a placed window contains two
//  or more numbers — could not be exercised without the physical instrument.
//  These tests cover the dual-reading panel that closes that gap.
//
//  The oracle is `NumberBandSplitter`, not a pixel diff: the render is only
//  useful if the SHIPPING localizer can separate the two readings from it. A
//  render that merges them under projection would look right to the eye and
//  still leave the feature unreachable.
//
//  These assert structural facts about a SYNTHETIC render. They say nothing
//  about recognition accuracy on real instruments — that claim belongs to
//  `NumberBandSplitterTests`, which is driven by a photograph of the target
//  hardware.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class DualReadingRenderTests: XCTestCase {

    /// The panel crop a user's window would produce when placed on the
    /// synthetic display — candidate regions are expressed in this crop's
    /// space, so the splitter must be fed exactly it.
    private func panelCrop(primary: String, secondary: String?) throws -> CVPixelBuffer {
        let renderer = SyntheticDisplayRenderer()
        let frame = try XCTUnwrap(renderer.render(text: primary, secondary: secondary, pose: .identity))
        return try XCTUnwrap(PixelBufferROI.cropped(frame, to: SyntheticDisplayRenderer.displayROI))
    }

    /// A failure here has to say WHAT was localized, because the question under
    /// test is whether projection separates the two readings at all.
    private func report(_ candidates: [NumberBandSplitter.Candidate]) -> String {
        candidates.enumerated().map { i, c in
            String(format: "  [%d] x=%.3f y=%.3f w=%.3f h=%.3f glyphH=%.3f ink=%.2f",
                   i, c.region.x, c.region.y, c.region.width, c.region.height,
                   c.glyphHeight, c.inkDensity)
        }.joined(separator: "\n")
    }

    // MARK: The point of the feature

    func testDualReadingPanel_yieldsTwoVerticallySeparatedCandidates() throws {
        let candidates = NumberBandSplitter.candidates(in: try panelCrop(primary: "90.0", secondary: "92.7"))
        let report = report(candidates)
        print("=== NumberBandSplitter on the dual-reading synthetic panel ===\n\(report)")

        XCTAssertGreaterThanOrEqual(candidates.count, 2,
            "Expected both readings (90.0 and 92.7) to be localized. Got \(candidates.count):\n\(report)")

        // Candidates are ranked tallest-first, so the primary is index 0.
        let primary = try XCTUnwrap(candidates.first)
        let below = candidates.dropFirst().filter { $0.region.y > primary.region.y }
        XCTAssertFalse(below.isEmpty,
            "No candidate below the primary — the two readings rendered as one band.\n\(report)")

        let secondary = try XCTUnwrap(below.max(by: { $0.glyphHeight < $1.glyphHeight }))
        XCTAssertLessThan(secondary.glyphHeight, primary.glyphHeight,
            "The secondary reading must render shorter than the primary.\n\(report)")

        // Separation must be a real band of background, not two candidates
        // whose boxes abut or overlap — a window sub-field crop taken from one
        // would otherwise clip glyphs from the other.
        XCTAssertGreaterThan(secondary.region.y, primary.region.y + primary.region.height,
            "The two readings' regions are not vertically disjoint.\n\(report)")
    }

    /// The size relationship is the signal the sub-field UI ranks on, so it has
    /// to survive font metrics rather than merely being requested in points.
    /// Measured on this render: 0.179 / 0.319 = 0.56 of the primary's height.
    func testSecondaryRendersAboutSixtyPercentOfThePrimaryHeight() throws {
        let candidates = NumberBandSplitter.candidates(in: try panelCrop(primary: "90.0", secondary: "92.7"))
        let report = report(candidates)
        let primary = try XCTUnwrap(candidates.first)
        let secondary = try XCTUnwrap(candidates.dropFirst().filter { $0.region.y > primary.region.y }
            .max(by: { $0.glyphHeight < $1.glyphHeight }))
        let ratio = secondary.glyphHeight / primary.glyphHeight
        XCTAssertGreaterThan(ratio, 0.45,
            "Secondary is so much shorter it would read as a legend, not a reading (\(ratio)).\n\(report)")
        XCTAssertLessThan(ratio, 0.75,
            "Secondary is too close to the primary's height to rank unambiguously (\(ratio)).\n\(report)")
    }

    func testDualReadingRenderIsDeterministic() throws {
        let a = NumberBandSplitter.candidates(in: try panelCrop(primary: "90.0", secondary: "92.7"))
        let b = NumberBandSplitter.candidates(in: try panelCrop(primary: "90.0", secondary: "92.7"))
        XCTAssertEqual(a, b, "The same panel content must render and split reproducibly")
    }

    // MARK: The single-reading panel is unchanged

    /// Every other synthetic test and fixture depends on the one-number panel,
    /// and the sub-field UI must not offer a second box where there is only one
    /// reading.
    func testSingleReadingPanel_stillYieldsOneDominantCandidate() throws {
        let candidates = NumberBandSplitter.candidates(in: try panelCrop(primary: "12.345", secondary: nil))
        let report = report(candidates)
        print("=== NumberBandSplitter on the single-reading synthetic panel ===\n\(report)")

        let primary = try XCTUnwrap(candidates.first)
        XCTAssertGreaterThan(primary.glyphHeight, 0.2,
            "A single centred reading should dominate its crop.\n\(report)")
        // Anything else found must sit in the primary's own band; a candidate
        // above or below it would be a phantom second reading.
        for c in candidates.dropFirst() {
            XCTAssertLessThan(c.region.y, primary.region.y + primary.region.height,
                "A phantom band was found below the only reading.\n\(report)")
            XCTAssertGreaterThan(c.region.y + c.region.height, primary.region.y,
                "A phantom band was found above the only reading.\n\(report)")
        }
    }

    /// `secondary: nil` must reach the original drawing code, not a rewritten
    /// equivalent — the pre-existing renderer output is what fixtures compare
    /// against.
    func testOmittingSecondaryRendersTheOriginalPanelBytes() throws {
        let renderer = SyntheticDisplayRenderer()
        let original = try XCTUnwrap(renderer.render(text: "12.345", pose: .identity))
        let explicitNil = try XCTUnwrap(renderer.render(text: "12.345", secondary: nil, pose: .identity))
        XCTAssertEqual(pixelData(original), pixelData(explicitNil))
    }

    func testDualReadingPanelDiffersFromTheSingleReadingPanel() throws {
        let renderer = SyntheticDisplayRenderer()
        let single = try XCTUnwrap(renderer.render(text: "90.0", pose: .identity))
        let dual = try XCTUnwrap(renderer.render(text: "90.0", secondary: "92.7", pose: .identity))
        XCTAssertNotEqual(pixelData(single), pixelData(dual))
    }

    /// DIAGNOSTIC: dumps the row ink profile through the shipping
    /// `LuminanceGrid`, so a band that fails to separate is read from the real
    /// code path rather than inferred from the rendered image.
    func testDiagnostic_rowProfileOfTheDualReadingPanel() throws {
        let crop = try panelCrop(primary: "90.0", secondary: "92.7")
        let g = try XCTUnwrap(LuminanceGrid(buffer: crop, maxLongEdge: 900, minEdge: 24))
        let thr = g.inkThreshold()
        var prof = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height {
            var n = 0
            for x in 0..<g.width where g.isInk(x, y, thr) { n += 1 }
            prof[y] = n
        }
        // Peak and median both reported because the gate has been derived from
        // each at different times; the pair says which readings a change to
        // that policy would strand.
        let nonZero = prof.filter { $0 > 0 }.sorted()
        let median = nonZero.isEmpty ? 0 : nonZero[nonZero.count / 2]
        let peak = max(1, prof.max() ?? 1)
        var lines: [String] = []
        for y in 0..<g.height where y % max(1, g.height / 40) == 0 {
            let bar = String(repeating: "#", count: Int(40 * Double(prof[y]) / Double(peak)))
            lines.append(String(format: "  y=%.3f %4d %@", Double(y) / Double(g.height), prof[y], bar))
        }
        print("""
        === dual-reading panel row profile ===
        grid \(g.width)x\(g.height) threshold=\(thr) peak=\(peak) median(nonzero)=\(median)
        \(lines.joined(separator: "\n"))
        """)
    }

    /// Separation must not depend on which digits happen to be showing. Row ink
    /// varies a lot with glyph shape — `7` contributes one diagonal where `8`
    /// contributes two closed loops — so a layout that only separates for one
    /// lucky pair would fail the moment the demo's value drifted.
    func testSeparationHoldsAcrossTheValuesTheDemoRenders() throws {
        for (primary, secondary) in [("90.0", "92.7"), ("90.0", "88.8"),
                                     ("12.345", "12.650"), ("88.888", "88.888"),
                                     ("-0.05", "-0.05")] {
            let candidates = NumberBandSplitter.candidates(in: try panelCrop(primary: primary,
                                                                            secondary: secondary))
            let report = report(candidates)
            let top = try XCTUnwrap(candidates.first, "\(primary)/\(secondary): nothing localized")
            let below = candidates.dropFirst().filter { $0.region.y > top.region.y + top.region.height }
            XCTAssertFalse(below.isEmpty,
                "\(primary)/\(secondary): no candidate below the primary's band.\n\(report)")
            for c in below {
                XCTAssertLessThan(c.glyphHeight, top.glyphHeight,
                    "\(primary)/\(secondary): the lower reading is not shorter.\n\(report)")
            }
        }
    }

    // MARK: The Simulator demo path

    /// `-daqpal-dual-reading` reaches the rendered frames — proved through the
    /// frame stream rather than the renderer, because that is the path
    /// `CaptureStack` actually feeds to `WindowFieldAnalyzer`.
    func testFrameSourceRendersTwoReadingsWhenDualReadingIsRequested() async throws {
        let candidates = try await firstFrameCandidates(dualReading: true)
        let report = report(candidates)
        let top = try XCTUnwrap(candidates.first, "nothing localized in the first demo frame")
        XCTAssertFalse(candidates.dropFirst().filter { $0.region.y > top.region.y + top.region.height }.isEmpty,
            "The dual-reading demo stream produced only one band.\n\(report)")
    }

    /// The default Simulator run must be untouched: one reading, as every other
    /// synthetic test and the existing demo expect.
    func testFrameSourceDefaultsToASingleReading() async throws {
        XCTAssertFalse(SyntheticFrameSource.dualReadingRequested,
                       "The test process was launched without -daqpal-dual-reading")
        let candidates = try await firstFrameCandidates(dualReading: false)
        let report = report(candidates)
        let top = try XCTUnwrap(candidates.first, "nothing localized in the first demo frame")
        for c in candidates.dropFirst() {
            XCTAssertLessThan(c.region.y, top.region.y + top.region.height,
                "The default demo stream grew a second band.\n\(report)")
        }
    }

    private func firstFrameCandidates(dualReading: Bool) async throws -> [NumberBandSplitter.Candidate] {
        let source = SyntheticFrameSource(dualReading: dualReading)
        var frames = source.frames().makeAsyncIterator()
        let first = await frames.next()
        let frame = try XCTUnwrap(first, "the synthetic source yielded no frame")
        let crop = try XCTUnwrap(PixelBufferROI.cropped(frame.pixelBuffer,
                                                        to: SyntheticFrameSource.displayROI))
        return NumberBandSplitter.candidates(in: crop)
    }

    /// Snapshots a locked 32BGRA buffer's active pixel region, ignoring any
    /// trailing row padding so the comparison is over real pixels only.
    private func pixelData(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var data = Data(capacity: width * height * 4)
        for y in 0..<height {
            data.append(contentsOf: UnsafeBufferPointer(start: ptr + y * bytesPerRow, count: width * 4))
        }
        return data
    }
}
