//
//  CoordinateDebugOverlayTests.swift
//  DAQPalTests
//
//  The coordinate chain `CoordinateDebugOverlay` displays, asserted as pure
//  math. A HUD that reports where a tap landed is only evidence if its own
//  arithmetic is pinned, so everything the overlay prints is computed by
//  `CoordinateProbe` and checked here — no SwiftUI rendering, no camera.
//
//  What is deliberately CHARACTERIZED rather than asserted away: under
//  aspect-fill the container shows only part of the frame, so "outside the
//  viewport" and "outside the frame" are NOT the same predicate. The tests
//  below pin both halves of that, including the half that is easy to state
//  wrongly (see `testPointOutsideViewport_onOverflowAxis_canStillBeInsideFrame`).
//
//  Deterministic: fixed sizes, and the sweep draws from `SeededGenerator`.
//

#if DEBUG

import CoreGraphics
import XCTest
@testable import DAQPal

final class CoordinateDebugOverlayTests: XCTestCase {

    /// Portrait capture buffer, as the pipeline sees it after orientation.
    private let contentSize = CGSize(width: 1080, height: 1920)

    /// Container aspect 0.5571 against content aspect 0.5625 — close enough to
    /// be realistic, different enough that aspect-fill genuinely crops. A 1:1
    /// container would let a mapping bug pass unnoticed.
    private let containerSize = CGSize(width: 390, height: 700)

    private var mapper: AspectFillMapper {
        AspectFillMapper(contentSize: contentSize, containerSize: containerSize)
    }

    /// A container whose aspect is wider than the content's, so the OTHER axis
    /// is the one that overflows. Every claim about "the fitting axis" is
    /// checked in both orientations of the crop.
    private var wideMapper: AspectFillMapper {
        AspectFillMapper(contentSize: contentSize, containerSize: CGSize(width: 900, height: 700))
    }

    private static let pointTolerance: CGFloat = 1e-9

    // MARK: - Round trips

    func testViewPointRoundTripIsIdentity() {
        let probes = [CGPoint(x: 0, y: 0),
                      CGPoint(x: 195, y: 350),
                      CGPoint(x: 390, y: 700),
                      CGPoint(x: 12.5, y: 687.25),
                      CGPoint(x: -40, y: 900)]
        for point in probes {
            let error = CoordinateProbe.roundTripError(viewPoint: point, mapper: mapper)
            XCTAssertEqual(error, 0, accuracy: Self.pointTolerance,
                           "view -> normalized -> view drifted at \(point)")
        }
    }

    func testNormalizedRoundTripIsIdentity() {
        let probes = [CGPoint(x: 0, y: 0),
                      CGPoint(x: 0.5, y: 0.5),
                      CGPoint(x: 1, y: 1),
                      CGPoint(x: 0.0137, y: 0.9942),
                      CGPoint(x: -0.2, y: 1.4)]
        for point in probes {
            let error = CoordinateProbe.roundTripError(normalized: point, mapper: mapper)
            XCTAssertEqual(error, 0, accuracy: Self.pointTolerance,
                           "normalized -> view -> normalized drifted at \(point)")
        }
    }

    /// Both container shapes, so neither crop orientation is special-cased.
    func testRoundTripIsIdentityForBothCropOrientations() {
        for m in [mapper, wideMapper] {
            for point in [CGPoint(x: 1, y: 1), CGPoint(x: 137.5, y: 421.25)] {
                XCTAssertEqual(CoordinateProbe.roundTripError(viewPoint: point, mapper: m), 0,
                               accuracy: Self.pointTolerance)
            }
        }
    }

    // MARK: - Inside / outside

    /// On the axis that aspect-fill fits EXACTLY (content origin 0 there),
    /// leaving the viewport always means leaving the frame.
    func testPointOutsideViewport_onFittingAxis_mapsOutsideUnitRange() {
        // Container 390x700 against a 0.5625 content aspect: height fits, width
        // overflows. Confirm that reading of the mapper before relying on it.
        XCTAssertEqual(mapper.contentOrigin.y, 0, accuracy: 1e-9)
        XCTAssertLessThan(mapper.contentOrigin.x, 0)

        let above = CoordinateProbe.sample(viewPoint: CGPoint(x: 195, y: -1), mapper: mapper)
        XCTAssertFalse(above.isInsideContainer)
        XCTAssertFalse(above.isInsideFrame)
        XCTAssertLessThan(above.normalized.y, 0)

        let below = CoordinateProbe.sample(viewPoint: CGPoint(x: 195, y: 701), mapper: mapper)
        XCTAssertFalse(below.isInsideContainer)
        XCTAssertFalse(below.isInsideFrame)
        XCTAssertGreaterThan(below.normalized.y, 1)
    }

    /// KNOWN AND INTENDED ASYMMETRY. On the overflowing axis a point just
    /// outside the viewport is still inside the captured frame — aspect-fill
    /// crops that axis, so the frame extends past the visible edge. The naive
    /// claim "outside the viewport maps outside 0...1" is FALSE there, and the
    /// overlay reports the two predicates separately for exactly this reason.
    func testPointOutsideViewport_onOverflowAxis_canStillBeInsideFrame() {
        let justOutside = CoordinateProbe.sample(viewPoint: CGPoint(x: -1, y: 350), mapper: mapper)
        XCTAssertFalse(justOutside.isInsideContainer)
        XCTAssertTrue(justOutside.isInsideFrame,
                      "the frame overflows the viewport horizontally; -1 pt is still on it")
        XCTAssertGreaterThan(justOutside.normalized.x, 0)

        // Far enough out — past the cropped-away margin — and it does leave the
        // frame. The margin is |contentOrigin.x| points wide on each side.
        let margin = -mapper.contentOrigin.x
        let wellOutside = CoordinateProbe.sample(viewPoint: CGPoint(x: -margin - 1, y: 350), mapper: mapper)
        XCTAssertFalse(wellOutside.isInsideFrame)
        XCTAssertLessThan(wellOutside.normalized.x, 0)
    }

    /// Same asymmetry, other axis, so the result is a property of the crop and
    /// not of this particular container.
    func testOverflowAxisFollowsTheContainerAspect() {
        XCTAssertEqual(wideMapper.contentOrigin.x, 0, accuracy: 1e-9)
        XCTAssertLessThan(wideMapper.contentOrigin.y, 0)

        let leftOfViewport = CoordinateProbe.sample(viewPoint: CGPoint(x: -1, y: 350), mapper: wideMapper)
        XCTAssertFalse(leftOfViewport.isInsideFrame)

        let aboveViewport = CoordinateProbe.sample(viewPoint: CGPoint(x: 450, y: -1), mapper: wideMapper)
        XCTAssertTrue(aboveViewport.isInsideFrame)
    }

    func testPointInsideViewportIsInsideBothPredicates() {
        let sample = CoordinateProbe.sample(viewPoint: CGPoint(x: 195, y: 350), mapper: mapper)
        XCTAssertTrue(sample.isInsideContainer)
        XCTAssertTrue(sample.isInsideFrame)
        // Dead centre of the viewport is dead centre of the frame: aspect-fill
        // crops symmetrically.
        XCTAssertEqual(sample.normalized.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(sample.normalized.y, 0.5, accuracy: 1e-9)
    }

    func testBufferPointIsNormalizedScaledByBufferSize() {
        let sample = CoordinateProbe.sample(viewPoint: CGPoint(x: 195, y: 350), mapper: mapper)
        XCTAssertEqual(sample.bufferPoint.x, 540, accuracy: 1e-6)
        XCTAssertEqual(sample.bufferPoint.y, 960, accuracy: 1e-6)
    }

    // MARK: - Visible region

    func testVisibleFrameRegionIsFullOnFittingAxisAndCroppedOnTheOther() {
        let visible = CoordinateProbe.visibleFrameRegion(in: mapper)
        // Height fits exactly for this container.
        XCTAssertEqual(visible.y, 0, accuracy: 1e-9)
        XCTAssertEqual(visible.height, 1, accuracy: 1e-9)
        // Width is cropped, symmetrically about the centre.
        XCTAssertGreaterThan(visible.x, 0)
        XCTAssertLessThan(visible.width, 1)
        XCTAssertEqual(visible.x + visible.width / 2, 0.5, accuracy: 1e-9)

        let wide = CoordinateProbe.visibleFrameRegion(in: wideMapper)
        XCTAssertEqual(wide.x, 0, accuracy: 1e-9)
        XCTAssertEqual(wide.width, 1, accuracy: 1e-9)
        XCTAssertLessThan(wide.height, 1)
        XCTAssertEqual(wide.y + wide.height / 2, 0.5, accuracy: 1e-9)
    }

    func testVisibleFrameRegionIsExactlyTheUnitSquareWhenNoCropIsNeeded() {
        let exact = AspectFillMapper(contentSize: contentSize, containerSize: contentSize)
        let visible = CoordinateProbe.visibleFrameRegion(in: exact)
        XCTAssertEqual(visible.x, 0, accuracy: 1e-9)
        XCTAssertEqual(visible.y, 0, accuracy: 1e-9)
        XCTAssertEqual(visible.width, 1, accuracy: 1e-9)
        XCTAssertEqual(visible.height, 1, accuracy: 1e-9)
    }

    /// The region has to agree with the predicate: every corner of the viewport
    /// is inside the frame exactly when the visible region is the unit square,
    /// and the region's own corners map back to the viewport's corners.
    func testVisibleFrameRegionCornersMapBackToTheViewportCorners() {
        let visible = CoordinateProbe.visibleFrameRegion(in: mapper)
        let topLeft = mapper.viewPoint(fromNormalized: CGPoint(x: visible.x, y: visible.y))
        let bottomRight = mapper.viewPoint(fromNormalized: CGPoint(x: visible.x + visible.width,
                                                                  y: visible.y + visible.height))
        XCTAssertEqual(topLeft.x, 0, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 0, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.x, containerSize.width, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.y, containerSize.height, accuracy: 1e-9)
    }

    // MARK: - Aspect-fill fidelity

    /// The probe must not carry its own copy of the aspect-fill mapping. If it
    /// ever did, this is where the two would disagree.
    func testProbeAgreesWithAspectFillMapper() {
        var generator = SeededGenerator(seed: 0x0C00_4D1E)
        for _ in 0..<200 {
            let point = CGPoint(x: CGFloat.random(in: -200...600, using: &generator),
                                y: CGFloat.random(in: -200...900, using: &generator))
            let sample = CoordinateProbe.sample(viewPoint: point, mapper: mapper)
            let expected = mapper.normalizedPoint(fromViewPoint: point)
            XCTAssertEqual(sample.normalized.x, expected.x, accuracy: 1e-12)
            XCTAssertEqual(sample.normalized.y, expected.y, accuracy: 1e-12)
        }
    }

    /// A normalized ROI drawn through the probe's digit-cell path lands on the
    /// same view rect `ROISelectionOverlay` would draw it at.
    func testDigitCellRectsUseTheSameMappingAsTheROIOverlay() {
        let roi = NormalizedROI(x: 0.2, y: 0.4, width: 0.6, height: 0.12)
        var device = Device.makeDefault(index: 1)
        device.roi = roi
        device.displayFormat = DisplayFormat(digitCount: 4,
                                             decimalPosition: 1,
                                             signAllowed: false,
                                             unit: "C",
                                             minimumValue: nil,
                                             maximumValue: nil)

        let rects = CoordinateProbe.digitCellRects(for: device, mapper: mapper)
        XCTAssertEqual(rects.count, 4)

        let whole = mapper.viewRect(fromNormalized: roi)
        XCTAssertEqual(rects[0].minX, whole.minX, accuracy: 1e-9)
        XCTAssertEqual(rects[3].maxX, whole.maxX, accuracy: 1e-9)
        for rect in rects {
            XCTAssertEqual(rect.minY, whole.minY, accuracy: 1e-9)
            XCTAssertEqual(rect.height, whole.height, accuracy: 1e-9)
        }
    }

    /// The fixed-pitch model produces identical gaps by construction. The
    /// hardware procedure measures the spread against a real display; this pins
    /// the baseline the tester is comparing to, so a non-zero field spread can
    /// only come from the display, never from the arithmetic.
    func testDigitCellPitchIsUniformForTheFixedPitchModel() {
        var device = Device.makeDefault(index: 1)
        device.roi = NormalizedROI(x: 0.1, y: 0.3, width: 0.7, height: 0.2)
        device.displayFormat = DisplayFormat(digitCount: 5,
                                             decimalPosition: 1,
                                             signAllowed: false,
                                             unit: nil,
                                             minimumValue: nil,
                                             maximumValue: nil)

        let pitches = CoordinateProbe.digitCellPitches(
            CoordinateProbe.digitCellRects(for: device, mapper: mapper))
        XCTAssertEqual(pitches.count, 4)
        guard let smallest = pitches.min(), let largest = pitches.max() else {
            return XCTFail("no pitches for a 5-digit format")
        }
        XCTAssertEqual(largest - smallest, 0, accuracy: 1e-9)
    }

    func testUnplacedDeviceHasNoDigitCells() {
        let device = Device.makeDefault(index: 2)
        XCTAssertNil(device.roi)
        XCTAssertTrue(CoordinateProbe.digitCellRects(for: device, mapper: mapper).isEmpty)
    }

    // MARK: - Quad chain

    /// The quad the overlay draws must survive the trip back to normalized
    /// space, since that is the space the tracker and the crop path work in.
    /// Reported through `GeometryError`, the shared vocabulary for quad
    /// agreement, rather than a bespoke corner-distance check.
    func testQuadSurvivesViewRoundTripWithinFloatingPointNoise() {
        let quad = ScreenQuad(topLeft: CGPoint(x: 0.22, y: 0.31),
                              topRight: CGPoint(x: 0.79, y: 0.27),
                              bottomRight: CGPoint(x: 0.83, y: 0.55),
                              bottomLeft: CGPoint(x: 0.18, y: 0.60))
        guard let viewCorners = CoordinateProbe.viewCorners(of: quad, mapper: mapper) else {
            return XCTFail("a convex, non-degenerate quad must be drawable")
        }
        let back = CoordinateProbe.normalizedCorners(fromViewCorners: viewCorners, mapper: mapper)
        guard let error = GeometryError.between(predicted: back, truth: quad.corners) else {
            return XCTFail("both quads have four corners")
        }
        XCTAssertEqual(error.maxCornerError, 0, accuracy: 1e-12)
        XCTAssertEqual(error.centerError, 0, accuracy: 1e-12)
        XCTAssertEqual(error.iou, 1, accuracy: 1e-9)
    }

    func testDegenerateQuadIsReportedAsNotDrawable() {
        let sliver = ScreenQuad(topLeft: CGPoint(x: 0.5, y: 0.5),
                                topRight: CGPoint(x: 0.5, y: 0.5),
                                bottomRight: CGPoint(x: 0.5, y: 0.5),
                                bottomLeft: CGPoint(x: 0.5, y: 0.5))
        XCTAssertNil(CoordinateProbe.viewCorners(of: sliver, mapper: mapper))
    }

    // MARK: - Matrix readout

    func testIdentityHomographyRendersAsTheIdentityMatrix() {
        let rows = CoordinateProbe.matrixRows(.identity)
        XCTAssertEqual(rows.count, 3)
        let values = rows.flatMap { $0.split(separator: " ").compactMap { Double($0) } }
        XCTAssertEqual(values, [1, 0, 0, 0, 1, 0, 0, 0, 1])
    }

    /// Row-major, matching `Homography.m`'s documented layout — a transposed
    /// readout would be silently wrong for every asymmetric matrix.
    func testMatrixRowsAreRowMajor() {
        let h = Homography(m: [1, 2, 3, 4, 5, 6, 7, 8, 1])
        let rows = CoordinateProbe.matrixRows(h)
        XCTAssertEqual(rows[0].split(separator: " ").compactMap { Double($0) }, [1, 2, 3])
        XCTAssertEqual(rows[1].split(separator: " ").compactMap { Double($0) }, [4, 5, 6])
        XCTAssertEqual(rows[2].split(separator: " ").compactMap { Double($0) }, [7, 8, 1])
    }

    // MARK: - Touch log

    @MainActor
    func testTouchLogRecordsDownAndUpAndCountsOnlyDowns() {
        let log = CoordinateTouchLog.shared
        log.reset()
        defer { log.reset() }

        XCTAssertNil(log.lastViewPoint)

        log.record(viewPoint: CGPoint(x: 120, y: 240), phase: .began)
        XCTAssertEqual(log.touchCount, 1)
        XCTAssertEqual(log.lastPhase, .began)

        log.record(viewPoint: CGPoint(x: 122, y: 246), phase: .ended)
        XCTAssertEqual(log.touchCount, 1, "a lift is not a new touch")
        XCTAssertEqual(log.lastPhase, .ended)
        XCTAssertEqual(log.lastViewPoint?.x, 122)

        log.record(viewPoint: CGPoint(x: 10, y: 10), phase: .began)
        XCTAssertEqual(log.touchCount, 2)
    }

    /// The log stores only the view point; the normalized form is derived, so a
    /// container resize between the tap and the readout produces the correct
    /// normalized coordinate rather than a stale one.
    @MainActor
    func testStoredTouchConvertsAgainstWhicheverMapperIsCurrent() {
        let log = CoordinateTouchLog.shared
        log.reset()
        defer { log.reset() }

        log.record(viewPoint: CGPoint(x: 195, y: 350), phase: .began)
        guard let point = log.lastViewPoint else { return XCTFail("touch not recorded") }

        XCTAssertEqual(CoordinateProbe.sample(viewPoint: point, mapper: mapper).normalized.y,
                       0.5, accuracy: 1e-9)
        // Same stored point, a container half as tall: the normalized result
        // must move, and it must move the way aspect-fill says.
        let shorter = AspectFillMapper(contentSize: contentSize,
                                       containerSize: CGSize(width: 390, height: 350))
        XCTAssertEqual(CoordinateProbe.sample(viewPoint: point, mapper: shorter).normalized.y,
                       shorter.normalizedPoint(fromViewPoint: point).y, accuracy: 1e-12)
    }

    // MARK: - Seeded sweep, reported through the shared harness

    /// Round-trips 300 pseudo-random points across five container shapes and
    /// reports each through `ValidationOutcome`, so the coordinate chain is
    /// scored with the same vocabulary as the recognition sweeps instead of a
    /// parallel metric.
    ///
    /// Truth and prediction are the point printed at the precision the overlay
    /// prints it — 4 decimals of normalized space, ~0.2 px on a 1080-wide
    /// buffer. `exact` therefore means "indistinguishable on the HUD", which is
    /// the claim the hardware procedure actually leans on.
    func testCoordinateRoundTripSweepIsExactEverywhere() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let containers = [CGSize(width: 390, height: 700),
                          CGSize(width: 430, height: 932),
                          CGSize(width: 900, height: 700),
                          CGSize(width: 1080, height: 1920),
                          CGSize(width: 320, height: 320)]
        var outcomes: [ValidationOutcome] = []

        for container in containers {
            let m = AspectFillMapper(contentSize: contentSize, containerSize: container)
            for index in 0..<60 {
                let point = CGPoint(x: CGFloat.random(in: -50...(container.width + 50), using: &generator),
                                    y: CGFloat.random(in: -50...(container.height + 50), using: &generator))
                let start = ContinuousClock.now
                let normalized = CoordinateProbe.sample(viewPoint: point, mapper: m).normalized
                let back = m.viewPoint(fromNormalized: normalized)
                let elapsed = ContinuousClock.now - start

                let truth = CoordinateProbe.format(point)
                let predicted = CoordinateProbe.format(back)
                outcomes.append(ValidationOutcome(
                    id: "coord/\(Int(container.width))x\(Int(container.height))/\(index)",
                    sweep: "coordinate-round-trip",
                    parameters: ["container": "\(Int(container.width))x\(Int(container.height))",
                                 "insideFrame": CoordinateProbe.isInsideFrame(normalized) ? "yes" : "no"],
                    truth: truth,
                    predicted: predicted,
                    verdict: ReadingComparison.verdict(truth: truth, predicted: predicted),
                    geometry: nil,
                    confidence: 1,
                    durationMS: Double(elapsed.components.attoseconds) / 1e15))
            }
        }

        let report = ValidationReport(sweep: "coordinate-round-trip", outcomes: outcomes)
        print(report.summary(groupedBy: "container"))
        XCTAssertEqual(report.total, 300)
        XCTAssertEqual(report.exactRate, 1,
                       "view -> normalized -> view must be exact at HUD precision everywhere")
    }
}

#endif
