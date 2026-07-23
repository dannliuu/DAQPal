//
//  SyntheticPipelineTests.swift
//  DAQPalTests
//
//  End-to-end pipeline coverage with NO camera and NO Simulator camera
//  access: `SyntheticDisplayRenderer` renders known strings into pixel
//  buffers, which drive `MeasurementProcessor` directly (spec §40.3
//  testability boundary).
//
//  Honesty note: this validates pipeline WIRING (crop -> OCR -> validate ->
//  fuse), not real-DMM recognition accuracy — `SyntheticDisplayRenderer`
//  explicitly documents itself as not a model of real display optics. Vision
//  results on rendered synthetic text can vary by OS/Simulator version, so
//  every assertion here is gated on Vision having produced *some* text first;
//  when it produces none at all, the test skips with a clear message rather
//  than asserting a fabricated pass.
//

import CoreGraphics
import XCTest
@testable import DAQPal

final class SyntheticPipelineTests: XCTestCase {

    /// Renders `text` into a pixel buffer and wraps it as a frame. Skips
    /// (rather than fails) if the renderer itself can't allocate a buffer —
    /// that is an environment limitation, not a pipeline defect.
    private func makeFrame(text: String, timestamp: TimeInterval,
                           renderer: SyntheticDisplayRenderer) throws -> TimestampedFrame {
        guard let buffer = renderer.render(text: text) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: timestamp)
    }

    func testKnownReading_isEventuallyAcceptedAtItsRenderedValue() async throws {
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(), roi: SyntheticDisplayRenderer.displayROI,
                                             format: .defaultDMM)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var acceptedValue: Double?
        // Several identical frames: gives the physical validator a baseline
        // and the temporal window a chance to fill, without depending on any
        // single frame's OCR result (Vision on synthetic renders varies).
        for i in 0..<8 {
            let frame = try makeFrame(text: "12.347", timestamp: Double(i) * (1.0 / 12.0), renderer: renderer)
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[config.id] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted { acceptedValue = measurement.value }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        guard let acceptedValue else {
            return XCTFail("expected at least one accepted \"12.347\" reading across 8 identical synthetic frames")
        }
        XCTAssertEqual(acceptedValue, 12.347, accuracy: 0.001)
    }

    func testGarbageReading_isNeverAccepted() async throws {
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(), roi: SyntheticDisplayRenderer.displayROI,
                                             format: .defaultDMM)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var everAccepted = false
        var lastReason: RejectionReason?
        for i in 0..<5 {
            let frame = try makeFrame(text: "1A.34B", timestamp: Double(i) * (1.0 / 12.0), renderer: renderer)
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[config.id] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted { everAccepted = true }
            lastReason = measurement.rejectionReason
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        // The exact reason depends on what Vision reads back for a garbled
        // string (could be invalidFormat or, if it reads nothing sensible,
        // displayLost); the invariant that must hold is "never accepted".
        XCTAssertFalse(everAccepted, "a garbled display string must never be accepted as a valid reading")
        if !everAccepted {
            XCTAssertNotNil(lastReason, "a rejected reading should always carry a rejection reason")
        }
    }

    func testUnconstrainedDevice_acceptsFreeNumberDimensionlessAndReportsObservedROI() async throws {
        // Real-device fix: a freshly added device is `.unconstrained` (Mode 3 —
        // free numeric, no unit, no range). A rendered "12.347" must be accepted
        // as a bare number, carry no unit, and publish where its text sat so ROI
        // auto-tracking can follow a shaking display.
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var accepted: DAQPal.Measurement?
        var observedROI: NormalizedROI?
        for i in 0..<8 {
            let frame = try makeFrame(text: "12.347", timestamp: Double(i) * (1.0 / 12.0), renderer: renderer)
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[config.id] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted {
                accepted = measurement
                observedROI = result.observedROIs[config.id]
            }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        guard let accepted else {
            return XCTFail("an unconstrained device should accept a rendered \"12.347\"")
        }
        XCTAssertEqual(accepted.value, 12.347, accuracy: 0.001)
        XCTAssertNil(accepted.unit, "unconstrained default is dimensionless")

        // Every accepted reading must publish an observed ROI, and it should
        // overlap the panel we rendered into. Loose intersection only — Vision's
        // box hugs the glyphs, not the whole panel.
        guard let observedROI else {
            return XCTFail("an accepted reading must publish an observed ROI for auto-tracking")
        }
        XCTAssertTrue(observedROI.cgRect.intersects(SyntheticDisplayRenderer.displayROI.cgRect),
                      "observed ROI \(observedROI) should overlap the rendered panel")
    }

    func testUnconfiguredDevice_producesNoReading() async throws {
        // No `update(devices:)` call at all: process must not throw and must
        // simply produce no readings (spec: "no devices" is a valid state).
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let frame = try makeFrame(text: "12.347", timestamp: 0, renderer: renderer)
        let result = await processor.process(frame: frame)
        XCTAssertTrue(result.readings.isEmpty)
    }
}
