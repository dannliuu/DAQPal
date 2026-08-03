//
//  GatingTests.swift
//  DAQPalTests
//
//  WP-D: tracking-invalidity must be observable end to end.
//
//  Covers three seams:
//  1. `MeasurementProcessor.process(trackingValid:)` — a field-backed device
//     gated by invalid tracking emits a REJECTED `.trackingInvalid`
//     measurement instead of silence (rejected readings are logged, never
//     dropped), while manual devices and the valid-tracking skip path are
//     untouched.
//  2. `AppState` — `applyScreenLock` publishes `measurementsValid`, and the
//     per-device card lock for FIELD-BACKED devices requires (tracking valid
//     AND OCR recency); manual devices keep the recency-only rule.
//  3. `TemporalConsensus` wiring — an 808 ↔ 80.8 flip-flop through the full
//     processor path never publishes both orders of magnitude.
//
//  Pure-logic tests drive the processor with a blank pixel buffer (no Vision
//  dependency: gated devices are rejected before recognition runs). The one
//  Vision-dependent test follows the SyntheticPipelineTests honesty pattern:
//  it XCTSkips with a diagnostic when Vision reads nothing, never fake-passes.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class GatingTests: XCTestCase {

    // MARK: - Helpers

    /// A blank BGRA frame — sufficient for every test that never needs OCR to
    /// actually read anything (gated devices are rejected pre-recognition;
    /// manual devices on a blank frame reject as `.displayLost`).
    private func makeBlankFrame(timestamp: TimeInterval) throws -> TimestampedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed (\(status)) in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: timestamp)
    }

    private func roi(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NormalizedROI {
        NormalizedROI(x: x, y: y, width: w, height: h)
    }

    // MARK: - 1. Processor gate: invalid tracking ⇒ rejected, not silent

    func testInvalidTracking_fieldBackedDeviceEmitsRejectedTrackingInvalid() async throws {
        let processor = MeasurementProcessor()
        let fieldBacked = UUID()
        let format = DisplayFormat.defaultDMM
        await processor.update(devices: [
            DeviceRecognitionConfig(id: fieldBacked, roi: .defaultROI, format: format)
        ])

        let result = await processor.process(frame: try makeBlankFrame(timestamp: 1.0),
                                             roiOverrides: [:],
                                             requiringOverride: [fieldBacked],
                                             trackingValid: false)

        let measurement = try XCTUnwrap(result.readings[fieldBacked],
                                        "invalid tracking must produce a rejected measurement, not silence")
        XCTAssertFalse(measurement.accepted)
        XCTAssertEqual(measurement.rejectionReason, .trackingInvalid)
        XCTAssertEqual(measurement.timestamp, 1.0)
        XCTAssertEqual(measurement.unit, format.unit, "the device's unit must survive into the rejected row")
        XCTAssertFalse(measurement.value.isFinite, "no value was read; the cell must stay empty in export")
    }

    func testInvalidTracking_gatesEvenWhenAnOverrideIsPresent() async throws {
        // `ScreenLockUpdate` empties `fieldROIs` whenever `measurementsValid`
        // is false, so this cannot happen by construction — but the Phase 14
        // invariant (`TrackingHealthy = false ⇒ MeasurementValid = false`,
        // even at 99% OCR confidence) must hold even if a stale override
        // slips through: the uncorroborated geometry is never read.
        let processor = MeasurementProcessor()
        let fieldBacked = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: fieldBacked, roi: .defaultROI, format: .unconstrained)
        ])

        let result = await processor.process(frame: try makeBlankFrame(timestamp: 2.0),
                                             roiOverrides: [fieldBacked: roi(0.3, 0.3, 0.3, 0.1)],
                                             requiringOverride: [fieldBacked],
                                             trackingValid: false)

        XCTAssertEqual(result.readings[fieldBacked]?.rejectionReason, .trackingInvalid,
                       "an override delivered alongside invalid tracking must be ignored, not recognized")
    }

    func testValidTracking_missingOverrideStillSkipsSilently() async throws {
        // Preserved behavior (PipelineBudgetTests relies on it too): with
        // VALID tracking, a field-backed device that simply has no override
        // this frame is skipped — that is a per-frame mapping gap, not a
        // tracking failure, and inventing a rejection for it would flood the
        // record.
        let processor = MeasurementProcessor()
        let fieldBacked = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: fieldBacked, roi: .defaultROI, format: .unconstrained)
        ])

        let result = await processor.process(frame: try makeBlankFrame(timestamp: 3.0),
                                             roiOverrides: [:],
                                             requiringOverride: [fieldBacked],
                                             trackingValid: true)

        XCTAssertNil(result.readings[fieldBacked])
    }

    func testInvalidTracking_manualDeviceIsUnaffected() async throws {
        let processor = MeasurementProcessor()
        let manual = UUID(), fieldBacked = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: manual, roi: roi(0.2, 0.4, 0.5, 0.15), format: .unconstrained),
            DeviceRecognitionConfig(id: fieldBacked, roi: roi(0.2, 0.6, 0.5, 0.15), format: .unconstrained)
        ])

        let result = await processor.process(frame: try makeBlankFrame(timestamp: 4.0),
                                             roiOverrides: [:],
                                             requiringOverride: [fieldBacked],
                                             trackingValid: false)

        XCTAssertEqual(result.readings[fieldBacked]?.rejectionReason, .trackingInvalid)
        let manualMeasurement = try XCTUnwrap(result.readings[manual],
                                              "the manual device must still be processed normally")
        XCTAssertNotEqual(manualMeasurement.rejectionReason, .trackingInvalid,
                          "manual fallback stays ungated by design")
    }

    // MARK: - 2. AppState publishes measurementsValid and gates the card lock

    @MainActor
    private func makeLockUpdate(target: TrackedTarget,
                                measurementsValid: Bool,
                                analyzedFields: [ScreenField]? = nil) -> ScreenLockUpdate {
        var update = ScreenLockUpdate(isIdle: false)
        update.snapState = .locked(targetID: target.id)
        update.target = target
        update.measurementsValid = measurementsValid
        update.analyzedFields = analyzedFields
        return update
    }

    private func makeTarget() -> TrackedTarget {
        let quad = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.3, width: 0.5, height: 0.3))
        return TrackedTarget(id: UUID(), quad: quad, referenceQuad: quad,
                             detectionConfidence: 0.9, trackingConfidence: 0.9,
                             health: .healthy, lastUpdated: 0, degradedSince: nil)
    }

    /// Locks a target with one numeric field, selects it (creating its
    /// field-backed device), and returns the field/device id.
    @MainActor
    private func setUpFieldBackedDevice(in appState: AppState,
                                        target: TrackedTarget) throws -> UUID {
        let field = ScreenField(region: NormalizedROI(x: 0.1, y: 0.1, width: 0.4, height: 0.2),
                                kind: .numeric)
        appState.applyScreenLock(makeLockUpdate(target: target,
                                                measurementsValid: true,
                                                analyzedFields: [field]))
        let fieldID = try XCTUnwrap(appState.fieldCatalog?.fields.first?.id)
        appState.toggleFieldSelection(fieldID)
        XCTAssertTrue(appState.fieldBackedDeviceIDs.contains(fieldID),
                      "selecting a numeric field must create a field-backed device")
        return fieldID
    }

    @MainActor
    func testApplyScreenLock_publishesMeasurementsValid() {
        let appState = AppState()
        XCTAssertFalse(appState.trackingMeasurementsValid)

        let target = makeTarget()
        appState.applyScreenLock(makeLockUpdate(target: target, measurementsValid: true))
        XCTAssertTrue(appState.trackingMeasurementsValid)

        appState.applyScreenLock(makeLockUpdate(target: target, measurementsValid: false))
        XCTAssertFalse(appState.trackingMeasurementsValid)

        // Idle (pipeline disabled) always reads as not-valid.
        appState.applyScreenLock(makeLockUpdate(target: target, measurementsValid: true))
        appState.applyScreenLock(ScreenLockUpdate(isIdle: true))
        XCTAssertFalse(appState.trackingMeasurementsValid)
    }

    @MainActor
    func testFieldBackedCardLock_dropsTheMomentTrackingIsInvalidated() throws {
        let appState = AppState()
        let target = makeTarget()
        let fieldID = try setUpFieldBackedDevice(in: appState, target: target)

        let accepted = Measurement(timestamp: 10.0, value: 12.347, unit: "V",
                                   confidence: 0.9, accepted: true)
        appState.apply(FrameResult(timestamp: 10.0,
                                   readings: [fieldID: accepted],
                                   debugText: nil))
        XCTAssertEqual(appState.liveReadings[fieldID]?.locked, true,
                       "valid tracking + fresh accepted reading must show LOCKED")

        // Geometry invalidated: the chip must drop NOW, well inside the 1.0 s
        // OCR-recency timeout it previously coasted on.
        appState.applyScreenLock(makeLockUpdate(target: target, measurementsValid: false))
        XCTAssertEqual(appState.liveReadings[fieldID]?.locked, false,
                       "invalidated tracking must drop the card lock immediately")

        // And it must STAY down on subsequent frames despite OCR recency.
        appState.apply(FrameResult(timestamp: 10.1, readings: [:], debugText: nil))
        XCTAssertEqual(appState.liveReadings[fieldID]?.locked, false,
                       "OCR recency alone must not re-light a field-backed lock under invalid tracking")

        // Tracking restored + fresh accepted reading: lock returns.
        appState.applyScreenLock(makeLockUpdate(target: target, measurementsValid: true))
        appState.apply(FrameResult(timestamp: 10.2,
                                   readings: [fieldID: Measurement(timestamp: 10.2, value: 12.347,
                                                                   unit: "V", confidence: 0.9,
                                                                   accepted: true)],
                                   debugText: nil))
        XCTAssertEqual(appState.liveReadings[fieldID]?.locked, true)
    }

    @MainActor
    func testManualDeviceCardLock_ignoresTrackingValidity() throws {
        let appState = AppState()
        var device = try XCTUnwrap(appState.devices.first)
        device.roi = roi(0.2, 0.4, 0.5, 0.15)
        appState.updateDevice(device)
        XCTAssertFalse(appState.trackingMeasurementsValid)

        let accepted = Measurement(timestamp: 5.0, value: 1.5, unit: nil,
                                   confidence: 0.9, accepted: true)
        appState.apply(FrameResult(timestamp: 5.0,
                                   readings: [device.id: accepted],
                                   debugText: nil))
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true,
                       "a manual-ROI device's lock is recency-only — never gated on tracking validity")
    }

    // MARK: - 3. TemporalConsensus wiring: 808 ↔ 80.8 gated in the full path

    func testFlipFlop_neverPublishesBothOrdersOfMagnitude() async throws {
        // The exact defect TemporalConsensus exists for: a display whose
        // decimal point survives preprocessing only sometimes alternates
        // between 80.8 and 808. Through the FULL processor path (crop → OCR →
        // validate → fuse → consensus), at most one of the two forms may ever
        // be accepted — publishing both would be a silent 10× flip.
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var acceptedValues: [Double] = []
        for i in 0..<14 {
            let text = i.isMultiple(of: 2) ? "80.8" : "808"
            guard let buffer = renderer.render(text: text) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            let frame = TimestampedFrame(pixelBuffer: buffer, timestamp: Double(i) * (1.0 / 12.0))
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[config.id] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted { acceptedValues.append(measurement.value) }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }

        let accepted808 = acceptedValues.contains { abs($0 - 808) < 1 }
        let accepted80_8 = acceptedValues.contains { abs($0 - 80.8) < 0.1 }
        XCTAssertFalse(accepted808 && accepted80_8,
                       "flip-flop published BOTH 808 and 80.8 (accepted: \(acceptedValues)) — the 10× gate failed")
    }

    func testStableReading_stillAcceptedThroughConsensusGate() async throws {
        // The gate must not tax the healthy path: a steady rendered value is
        // still accepted (mirrors SyntheticPipelineTests, now through the
        // consensus-wired processor).
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var acceptedValue: Double?
        for i in 0..<8 {
            guard let buffer = renderer.render(text: "80.8") else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            let frame = TimestampedFrame(pixelBuffer: buffer, timestamp: Double(i) * (1.0 / 12.0))
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[config.id] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted { acceptedValue = measurement.value }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        let value = try XCTUnwrap(acceptedValue,
                                  "a steady \"80.8\" must still be accepted with the consensus gate wired in")
        XCTAssertEqual(value, 80.8, accuracy: 0.001)
    }
}
