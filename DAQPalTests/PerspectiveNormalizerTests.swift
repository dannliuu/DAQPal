//
//  PerspectiveNormalizerTests.swift
//  DAQPalTests
//
//  Coverage for `PerspectiveNormalizer` (spec §10, Phase 9). The orientation
//  test is the important one: a flipped top-left/bottom-left mapping into
//  Core Image's coordinate space would silently produce an upside-down
//  canonical image, which would corrupt every field coordinate and OCR read
//  downstream without ever throwing or returning nil.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class PerspectiveNormalizerTests: XCTestCase {

    // MARK: - Aspect ratio

    func testCanonicalImage_identityPosePanel_matchesExpectedAspectRatio() throws {
        let renderer = SyntheticDisplayRenderer()
        guard let buffer = renderer.render(text: "12.345", pose: .identity) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        let roi = SyntheticDisplayRenderer.displayROI
        let quad = ScreenQuad(roi: roi)

        guard let canonical = PerspectiveNormalizer.canonicalImage(from: buffer, quad: quad) else {
            return XCTFail("expected a canonical image for a convex, well-sized identity-pose panel quad")
        }

        let width = CVPixelBufferGetWidth(canonical)
        let height = CVPixelBufferGetHeight(canonical)
        XCTAssertGreaterThan(width, 0)
        XCTAssertGreaterThan(height, 0)

        let expectedAspect = (roi.width * renderer.size.width) / (roi.height * renderer.size.height)
        let actualAspect = Double(width) / Double(height)
        XCTAssertEqual(actualAspect, Double(expectedAspect), accuracy: 0.05,
                       "canonical image aspect ratio should track the quad's apparent pixel resolution, not be squashed to a default")
    }

    // MARK: - Orientation (the important test)

    /// Builds a buffer whose top half (rows nearest y=0 in the project's
    /// top-left convention — the same raw memory rows `PixelBufferROI` and
    /// `NormalizedROI.pixelRect` address directly) is bright and whose
    /// bottom half is dark, then warps the *whole frame* (a quad at exactly
    /// the buffer's own corners) through `canonicalImage` and asserts the
    /// canonical output keeps bright-on-top. A reversed corner mapping would
    /// flip this and the test would fail loudly instead of silently
    /// corrupting downstream field coordinates.
    func testCanonicalImage_preservesTopBottomOrientation() throws {
        let width = 200, height = 300
        guard let buffer = makeTopBottomSplitBuffer(width: width, height: height) else {
            throw XCTSkip("could not allocate the synthetic split buffer in this environment")
        }
        // Sanity: the source buffer really is bright-on-top before warping.
        let sourceTop = meanLuminance(buffer, rows: 0..<(height / 4))
        let sourceBottom = meanLuminance(buffer, rows: (height - height / 4)..<height)
        XCTAssertGreaterThan(sourceTop, sourceBottom + 100, "test fixture setup should itself be bright-on-top")

        let fullFrameQuad = ScreenQuad(roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1))
        guard let canonical = PerspectiveNormalizer.canonicalImage(from: buffer, quad: fullFrameQuad,
                                                                   outputSize: CGSize(width: 100, height: 150)) else {
            return XCTFail("expected a canonical image for the full-frame identity quad")
        }

        let canonicalHeight = CVPixelBufferGetHeight(canonical)
        let canonicalTop = meanLuminance(canonical, rows: 0..<(canonicalHeight / 4))
        let canonicalBottom = meanLuminance(canonical, rows: (canonicalHeight - canonicalHeight / 4)..<canonicalHeight)

        XCTAssertGreaterThan(canonicalTop, canonicalBottom + 50,
                             "canonical image top rows should stay bright and bottom rows dark — an upside-down " +
                             "result here means the ScreenQuad→CIPerspectiveCorrection corner mapping is flipped")
    }

    /// Same orientation check through a genuinely tilted (non-axis-aligned)
    /// quad, so the general homography path — not just the trivial identity
    /// corner case — is exercised.
    func testCanonicalImage_preservesOrientation_forTiltedQuad() throws {
        let width = 400, height = 400
        guard let buffer = makeTopBottomSplitBuffer(width: width, height: height) else {
            throw XCTSkip("could not allocate the synthetic split buffer in this environment")
        }
        // A trapezoid: top edge narrower than the bottom, both edges still
        // spanning the full bright-top/dark-bottom split, corners well
        // inside the frame so CIPerspectiveCorrection has real work to do.
        let quad = ScreenQuad(topLeft: CGPoint(x: 0.3, y: 0.1),
                              topRight: CGPoint(x: 0.7, y: 0.1),
                              bottomRight: CGPoint(x: 0.9, y: 0.9),
                              bottomLeft: CGPoint(x: 0.1, y: 0.9))
        XCTAssertTrue(quad.isConvex, "test fixture quad must itself be convex")

        guard let canonical = PerspectiveNormalizer.canonicalImage(from: buffer, quad: quad,
                                                                   outputSize: CGSize(width: 100, height: 100)) else {
            return XCTFail("expected a canonical image for a convex tilted quad")
        }

        let canonicalHeight = CVPixelBufferGetHeight(canonical)
        let canonicalTop = meanLuminance(canonical, rows: 0..<(canonicalHeight / 4))
        let canonicalBottom = meanLuminance(canonical, rows: (canonicalHeight - canonicalHeight / 4)..<canonicalHeight)
        XCTAssertGreaterThan(canonicalTop, canonicalBottom + 50,
                             "tilted-quad canonical image should still be bright-on-top")
    }

    // MARK: - Rejections

    func testCanonicalImage_nonConvexQuad_returnsNil() {
        // Bowtie: diagonals cross, so this is self-intersecting, not convex.
        let quad = ScreenQuad(topLeft: CGPoint(x: 0, y: 0),
                              topRight: CGPoint(x: 1, y: 1),
                              bottomRight: CGPoint(x: 1, y: 0),
                              bottomLeft: CGPoint(x: 0, y: 1))
        XCTAssertFalse(quad.isConvex, "test fixture quad must itself be non-convex")

        guard let buffer = makeTopBottomSplitBuffer(width: 100, height: 100) else { return }
        XCTAssertNil(PerspectiveNormalizer.canonicalImage(from: buffer, quad: quad))
    }

    func testCanonicalImage_degenerateZeroAreaQuad_returnsNil() {
        // All four corners collinear (a vertical line) — zero area.
        let quad = ScreenQuad(topLeft: CGPoint(x: 0.5, y: 0.1),
                              topRight: CGPoint(x: 0.5, y: 0.1),
                              bottomRight: CGPoint(x: 0.5, y: 0.9),
                              bottomLeft: CGPoint(x: 0.5, y: 0.9))
        XCTAssertEqual(quad.area, 0, accuracy: 1e-9, "test fixture quad must itself be zero-area")

        guard let buffer = makeTopBottomSplitBuffer(width: 100, height: 100) else { return }
        XCTAssertNil(PerspectiveNormalizer.canonicalImage(from: buffer, quad: quad))
    }

    func testCanonicalImage_tinyQuad_returnsNilRatherThanDegenerateBuffer() {
        // Convex and non-degenerate, but tiny enough that the derived output
        // size collapses below the minimum usable edge.
        let quad = ScreenQuad(topLeft: CGPoint(x: 0.500, y: 0.500),
                              topRight: CGPoint(x: 0.501, y: 0.500),
                              bottomRight: CGPoint(x: 0.501, y: 0.501),
                              bottomLeft: CGPoint(x: 0.500, y: 0.501))
        XCTAssertTrue(quad.isConvex, "test fixture quad must itself be convex")

        guard let buffer = makeTopBottomSplitBuffer(width: 100, height: 100) else { return }
        XCTAssertNil(PerspectiveNormalizer.canonicalImage(from: buffer, quad: quad))
    }

    // MARK: - canonicalRegion

    func testCanonicalRegion_fullCanonicalSquare_mapsToQuadBoundingBox() {
        let roi = NormalizedROI(x: 0.2, y: 0.3, width: 0.5, height: 0.4)
        let quad = ScreenQuad(roi: roi)
        let region = NormalizedROI(x: 0, y: 0, width: 1, height: 1)

        guard let mapped = PerspectiveNormalizer.canonicalRegion(region, ofQuad: quad) else {
            return XCTFail("expected a mapped region for an axis-aligned quad")
        }
        XCTAssertEqual(mapped.x, roi.x, accuracy: 1e-6)
        XCTAssertEqual(mapped.y, roi.y, accuracy: 1e-6)
        XCTAssertEqual(mapped.width, roi.width, accuracy: 1e-6)
        XCTAssertEqual(mapped.height, roi.height, accuracy: 1e-6)
    }

    func testCanonicalRegion_centeredSubregion_staysInsideQuadBounds() {
        let roi = NormalizedROI(x: 0.1, y: 0.1, width: 0.6, height: 0.6)
        let quad = ScreenQuad(roi: roi)
        let region = NormalizedROI(x: 0.25, y: 0.25, width: 0.5, height: 0.5)

        guard let mapped = PerspectiveNormalizer.canonicalRegion(region, ofQuad: quad) else {
            return XCTFail("expected a mapped region")
        }
        XCTAssertGreaterThanOrEqual(mapped.x, roi.x - 1e-6)
        XCTAssertGreaterThanOrEqual(mapped.y, roi.y - 1e-6)
        XCTAssertLessThanOrEqual(mapped.x + mapped.width, roi.x + roi.width + 1e-6)
        XCTAssertLessThanOrEqual(mapped.y + mapped.height, roi.y + roi.height + 1e-6)
    }

    func testCanonicalRegion_nonConvexQuad_returnsNil() {
        let quad = ScreenQuad(topLeft: CGPoint(x: 0, y: 0),
                              topRight: CGPoint(x: 1, y: 1),
                              bottomRight: CGPoint(x: 1, y: 0),
                              bottomLeft: CGPoint(x: 0, y: 1))
        let region = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        XCTAssertNil(PerspectiveNormalizer.canonicalRegion(region, ofQuad: quad))
    }

    // MARK: - Fixtures

    /// A 32BGRA buffer, bright (white) on the rows nearest memory row 0 /
    /// top-left-normalized y=0, dark (black) on the rows nearest the end of
    /// the buffer — written directly to memory so the fixture makes no
    /// assumption about `CIImage`/`CGContext` conventions, only about the
    /// project's own established one (`NormalizedROI.pixelRect`,
    /// `PixelBufferROI`): row 0 is the top of the image.
    private func makeTopBottomSplitBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            let bright: UInt8 = y < height / 2 ? 255 : 0
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                p[0] = bright; p[1] = bright; p[2] = bright; p[3] = 255
            }
        }
        return buffer
    }

    /// Mean B/G/R byte value (0...255) across the given row range, full
    /// buffer width. Direct memory read — same "row 0 is top" convention as
    /// `makeTopBottomSplitBuffer`.
    private func meanLuminance(_ buffer: CVPixelBuffer, rows: Range<Int>) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let width = CVPixelBufferGetWidth(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum: Double = 0
        var count = 0
        for y in rows {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                sum += Double(p[0]) + Double(p[1]) + Double(p[2])
                count += 3
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }
}
