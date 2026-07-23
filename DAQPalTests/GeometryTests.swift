//
//  GeometryTests.swift
//  DAQPalTests
//
//  Pure-math coverage for `AspectFillMapper` (view <-> normalized conversion)
//  and `NormalizedROI` (clamping, pixel-rect conversion). No camera, no UI.
//

import XCTest
@testable import DAQPal

final class GeometryTests: XCTestCase {

    private let contentSize = CGSize(width: 1080, height: 1920)

    // MARK: - AspectFillMapper: scale/origin for the three container shapes

    func testExactFit_scaleIsOneAndOriginIsZero() {
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: contentSize)
        XCTAssertEqual(mapper.scale, 1, accuracy: 1e-9)
        XCTAssertEqual(mapper.contentOrigin.x, 0, accuracy: 1e-9)
        XCTAssertEqual(mapper.contentOrigin.y, 0, accuracy: 1e-9)
    }

    func testContainerTaller_thanContentAspect_overflowsWidth() {
        // Container is relatively taller/narrower than the content's aspect,
        // so aspect-fill must scale by height and overflow horizontally.
        let container = CGSize(width: 400, height: 1000)
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: container)
        let expectedScale = container.height / contentSize.height
        XCTAssertEqual(mapper.scale, expectedScale, accuracy: 1e-9)
        // Scaled content width exceeds the container -> negative x origin.
        XCTAssertLessThan(mapper.contentOrigin.x, 0)
        XCTAssertEqual(mapper.contentOrigin.y, 0, accuracy: 1e-9)
    }

    func testContainerWider_thanContentAspect_overflowsHeight() {
        // Container is relatively wider/shorter than the content's aspect, so
        // aspect-fill must scale by width and overflow vertically.
        let container = CGSize(width: 1200, height: 900)
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: container)
        let expectedScale = container.width / contentSize.width
        XCTAssertEqual(mapper.scale, expectedScale, accuracy: 1e-9)
        XCTAssertEqual(mapper.contentOrigin.x, 0, accuracy: 1e-9)
        XCTAssertLessThan(mapper.contentOrigin.y, 0)
    }

    // MARK: - Roundtrip: normalized -> view -> normalized

    private func assertRoundtrip(_ roi: NormalizedROI, mapper: AspectFillMapper,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let viewRect = mapper.viewRect(fromNormalized: roi)
        let back = mapper.normalizedRect(fromViewRect: viewRect)
        XCTAssertEqual(back.x, roi.x, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(back.y, roi.y, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(back.width, roi.width, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(back.height, roi.height, accuracy: 1e-6, file: file, line: line)
    }

    func testRoundtrip_exactFit() {
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: contentSize)
        assertRoundtrip(NormalizedROI(x: 0.25, y: 0.4, width: 0.3, height: 0.15), mapper: mapper)
    }

    func testRoundtrip_contentWiderThanContainer() {
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: CGSize(width: 400, height: 1000))
        assertRoundtrip(NormalizedROI(x: 0.1, y: 0.5, width: 0.4, height: 0.2), mapper: mapper)
    }

    func testRoundtrip_contentTallerThanContainer() {
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: CGSize(width: 1200, height: 900))
        assertRoundtrip(NormalizedROI(x: 0.05, y: 0.1, width: 0.6, height: 0.3), mapper: mapper)
    }

    func testPointRoundtrip() {
        let mapper = AspectFillMapper(contentSize: contentSize, containerSize: CGSize(width: 390, height: 844))
        let p = CGPoint(x: 0.37, y: 0.62)
        let viewPoint = mapper.viewPoint(fromNormalized: p)
        let back = mapper.normalizedPoint(fromViewPoint: viewPoint)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-6)
    }

    // MARK: - NormalizedROI.clamped()

    func testClamped_withinBoundsUnchanged() {
        let roi = NormalizedROI(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        XCTAssertEqual(roi.clamped(), roi)
    }

    func testClamped_belowMinimumSizeGrowsToMinimum() {
        let roi = NormalizedROI(x: 0.5, y: 0.5, width: 0.001, height: 0.001)
        let clamped = roi.clamped()
        XCTAssertGreaterThanOrEqual(clamped.width, NormalizedROI.minimumWidth)
        XCTAssertGreaterThanOrEqual(clamped.height, NormalizedROI.minimumHeight)
    }

    func testClamped_negativeOriginPushedToZero() {
        let roi = NormalizedROI(x: -0.3, y: -0.2, width: 0.3, height: 0.2)
        let clamped = roi.clamped()
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
    }

    func testClamped_overflowingRightEdgePulledIntoUnitSquare() {
        let roi = NormalizedROI(x: 0.9, y: 0.9, width: 0.5, height: 0.5)
        let clamped = roi.clamped()
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1.0 + 1e-9)
        XCTAssertLessThanOrEqual(clamped.y + clamped.height, 1.0 + 1e-9)
    }

    func testClamped_fullUnitSquareUnaffected() {
        let roi = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let clamped = roi.clamped()
        XCTAssertEqual(clamped, roi)
    }

    // MARK: - NormalizedROI.pixelRect(in:)

    func testPixelRect_scalesAndIsIntegral() {
        let roi = NormalizedROI(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
        let rect = roi.pixelRect(in: contentSize)
        XCTAssertEqual(rect, rect.integral)
        XCTAssertEqual(rect.origin.x, 0.25 * contentSize.width, accuracy: 1)
        XCTAssertEqual(rect.origin.y, 0.5 * contentSize.height, accuracy: 1)
        XCTAssertEqual(rect.width, 0.5 * contentSize.width, accuracy: 1)
        XCTAssertEqual(rect.height, 0.25 * contentSize.height, accuracy: 1)
    }

    func testPixelRect_clampedToImageBounds() {
        // An ROI that (before clamping) would overflow the image must still
        // produce a pixel rect fully inside the image bounds.
        let roi = NormalizedROI(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
        let rect = roi.pixelRect(in: contentSize)
        XCTAssertTrue(CGRect(origin: .zero, size: contentSize).contains(rect))
    }
}
