//
//  CapturePerformanceTests.swift
//  DAQPalTests
//
//  Performance REGRESSION tests for the capture screen's frame path
//  (spec Build Gate 2, "performance regression test added").
//
//  These do not time anything — a wall-clock assertion would be flaky on CI and
//  would not pin the actual defect. They assert the *mechanism* that caused the
//  original ROI drag lag: `AppState.apply()` runs at frame rate, and every
//  ungated write to an `@Observable` property invalidates every SwiftUI view
//  that reads it. When the whole capture screen's body read per-frame state,
//  dragging an ROI window competed with a full-screen re-render 12–30×/s.
//
//  `withObservationTracking` lets us observe exactly that: register the reads a
//  view body performs, apply a frame, and check whether SwiftUI would have been
//  told to re-render. A frame that changes nothing the UI displays must produce
//  zero invalidations.
//

import Observation
import XCTest
@testable import DAQPal

@MainActor
final class CapturePerformanceTests: XCTestCase {

    // MARK: Helpers

    /// Registers the observable reads a capture-screen body performs, runs
    /// `mutation`, and reports whether SwiftUI would have been asked to
    /// re-render. `withObservationTracking`'s `onChange` is one-shot and fires
    /// synchronously on the first mutation of any tracked property.
    private func wouldInvalidateUI(_ appState: AppState, during mutation: () -> Void) -> Bool {
        var invalidated = false
        withObservationTracking {
            // Everything CameraCaptureScreen + its subviews read per frame.
            _ = appState.liveReadings
            _ = appState.debugText
            _ = appState.processedFPS
            _ = appState.devices
            _ = appState.uiMode
        } onChange: {
            invalidated = true
        }
        mutation()
        return invalidated
    }

    private func makeAppState(roi: NormalizedROI? = .defaultROI) -> (AppState, Device) {
        let appState = AppState()
        var device = appState.devices[0]
        device.roi = roi
        appState.updateDevice(device)
        // ROI tracking would legitimately move the window on accepted readings;
        // these tests isolate the publish path, so tracking is disabled unless a
        // test is specifically about it.
        appState.roiTrackingEnabled = false
        return (appState, device)
    }

    /// Feeds enough frames at a steady cadence for the rolling rate estimate to
    /// settle. The first frames legitimately move `processedFPS` from 0 to the
    /// capture rate — the footer really does change from "—" to "12" — so tests
    /// about the *steady state* must start after that transient, not count it
    /// as a spurious invalidation. `testProcessedFPS_warmUpTransientIsExpected`
    /// covers the transient itself.
    private func primeRateEstimate(_ appState: AppState, deviceID: UUID?, frames: Int = 4) {
        for i in 0..<frames {
            let t = Double(i) / 12.0
            if let deviceID {
                appState.apply(frame(deviceID: deviceID, timestamp: t, value: 12.345))
            } else {
                appState.apply(FrameResult(timestamp: t, readings: [:], debugText: nil))
            }
        }
    }

    private func frame(deviceID: UUID,
                       timestamp: TimeInterval,
                       value: Double,
                       confidence: Float = 0.95,
                       debugText: String? = "Detected: 12.345 (0.95)") -> FrameResult {
        let measurement = DAQPal.Measurement(timestamp: timestamp,
                                             value: value,
                                             unit: nil,
                                             confidence: confidence,
                                             accepted: true)
        return FrameResult(timestamp: timestamp,
                           readings: [deviceID: measurement],
                           debugText: debugText)
    }

    // MARK: The regression that caused the drag lag

    /// The core assertion: a frame carrying the SAME reading as the previous
    /// frame must not invalidate the UI. Before the fix every frame wrote
    /// `liveReadings`, `debugText` and `processedFPS` unconditionally, so this
    /// was an invalidation on every single frame.
    func testApply_identicalFrame_doesNotInvalidateUI() {
        let (appState, device) = makeAppState()

        appState.apply(frame(deviceID: device.id, timestamp: 1.0, value: 12.345))
        // Second frame: same value, same confidence, same debug text. Only the
        // timestamp advances, and a timestamp the UI never displays must not
        // cause a re-render.
        let invalidated = wouldInvalidateUI(appState) {
            appState.apply(self.frame(deviceID: device.id, timestamp: 1.0, value: 12.345))
        }

        XCTAssertFalse(invalidated,
                       "A frame with unchanged displayed state must not invalidate the capture UI — this is the ROI drag-lag regression.")
    }

    /// A sustained run of identical frames must stay at zero invalidations, not
    /// merely start there.
    func testApply_manyIdenticalFrames_produceNoInvalidations() {
        let (appState, device) = makeAppState()
        primeRateEstimate(appState, deviceID: device.id)

        var invalidations = 0
        for i in 4...64 {
            let t = Double(i) / 12.0
            if wouldInvalidateUI(appState, during: {
                appState.apply(self.frame(deviceID: device.id, timestamp: t, value: 12.345))
            }) {
                invalidations += 1
            }
        }

        XCTAssertEqual(invalidations, 0,
                       "60 frames of an unchanging reading invalidated the UI \(invalidations) times.")
    }

    /// The counterpart to the steady-state tests: the rate estimate settling
    /// from "unknown" to the real capture rate IS a displayed change, and must
    /// reach the footer. Asserting this explicitly keeps the priming in the
    /// other tests honest — it documents the transient rather than hiding it.
    func testProcessedFPS_warmUpTransientIsExpected() {
        let (appState, device) = makeAppState()
        XCTAssertEqual(appState.processedFPS, 0)

        appState.apply(frame(deviceID: device.id, timestamp: 0, value: 12.345))
        XCTAssertEqual(appState.processedFPS, 0, "One frame is not enough to estimate a rate.")

        appState.apply(frame(deviceID: device.id, timestamp: 1.0 / 12.0, value: 12.345))
        XCTAssertEqual(appState.processedFPS, 12, accuracy: 0.001,
                       "The second frame should establish the rate the footer displays.")
    }

    /// The gating must not be so aggressive that the UI stops updating — a
    /// genuinely new value has to reach the screen.
    func testApply_changedValue_doesInvalidateUI() {
        let (appState, device) = makeAppState()
        appState.apply(frame(deviceID: device.id, timestamp: 1.0, value: 12.345))

        let invalidated = wouldInvalidateUI(appState) {
            appState.apply(self.frame(deviceID: device.id, timestamp: 1.05, value: 12.999))
        }

        XCTAssertTrue(invalidated, "A changed reading must reach the UI.")
    }

    /// Confidence drives the live card's bar and percentage, so a change there
    /// must also publish.
    func testApply_changedConfidence_doesInvalidateUI() {
        let (appState, device) = makeAppState()
        appState.apply(frame(deviceID: device.id, timestamp: 1.0, value: 12.345, confidence: 0.95))

        let invalidated = wouldInvalidateUI(appState) {
            appState.apply(self.frame(deviceID: device.id, timestamp: 1.05, value: 12.345, confidence: 0.42))
        }

        XCTAssertTrue(invalidated, "A changed confidence must reach the confidence bar.")
    }

    // MARK: Debug overlay is opt-in work

    /// `debugText` is only rendered while the OCR overlay is on. Writing it on
    /// every frame regardless invalidated the screen even with the overlay
    /// hidden, which is pure waste in the common case.
    func testApply_debugTextNotPublishedWhileOverlayHidden() {
        let (appState, device) = makeAppState()
        XCTAssertFalse(appState.showDebugOverlay, "Overlay is expected to default off.")

        appState.apply(frame(deviceID: device.id, timestamp: 1.0, value: 12.345, debugText: "Detected: A"))
        let invalidated = wouldInvalidateUI(appState) {
            // Different debug text, everything else identical.
            appState.apply(self.frame(deviceID: device.id, timestamp: 1.0, value: 12.345, debugText: "Detected: B"))
        }

        XCTAssertFalse(invalidated, "Debug text must not be published while the overlay is hidden.")
        XCTAssertNil(appState.debugText)
    }

    func testApply_debugTextPublishedWhileOverlayVisible() {
        let (appState, device) = makeAppState()
        appState.showDebugOverlay = true

        appState.apply(frame(deviceID: device.id, timestamp: 1.0, value: 12.345, debugText: "Detected: A"))
        XCTAssertEqual(appState.debugText, "Detected: A")

        let invalidated = wouldInvalidateUI(appState) {
            appState.apply(self.frame(deviceID: device.id, timestamp: 1.05, value: 12.345, debugText: "Detected: B"))
        }
        XCTAssertTrue(invalidated)
        XCTAssertEqual(appState.debugText, "Detected: B")
    }

    // MARK: Processing-rate meter

    /// The footer shows the rate as a rounded integer. Republishing a rate that
    /// wobbles between 11.98 and 12.02 would invalidate the footer every frame
    /// while displaying the identical string.
    func testProcessedFPS_onlyPublishesWhenDisplayedValueChanges() {
        let (appState, device) = makeAppState()

        // Prime a steady 12 fps cadence.
        for i in 0...12 {
            appState.apply(frame(deviceID: device.id, timestamp: Double(i) / 12.0, value: 12.345))
        }
        let settled = appState.processedFPS
        XCTAssertEqual(settled, 12, accuracy: 1.0, "Expected the rate estimate to settle near the 12 fps input cadence.")

        // Keep feeding the same cadence; the displayed integer cannot change.
        var rateChanged = false
        for i in 13...36 {
            let before = appState.processedFPS
            appState.apply(frame(deviceID: device.id, timestamp: Double(i) / 12.0, value: 12.345))
            if appState.processedFPS != before { rateChanged = true }
        }
        XCTAssertFalse(rateChanged,
                       "A steady capture cadence republished processedFPS despite the displayed integer being unchanged.")
    }

    // MARK: Unplaced devices

    /// A device with no ROI reports `.empty` forever; that must be written once,
    /// not re-assigned every frame.
    func testApply_unplacedDevice_doesNotInvalidateRepeatedly() {
        let (appState, device) = makeAppState(roi: nil)
        primeRateEstimate(appState, deviceID: nil)

        let invalidated = wouldInvalidateUI(appState) {
            appState.apply(FrameResult(timestamp: 4.0 / 12.0, readings: [:], debugText: nil))
        }

        XCTAssertFalse(invalidated, "An unplaced device re-published its empty reading.")
        XCTAssertEqual(appState.liveReadings[device.id], .empty)
    }

    // MARK: ROI editing pauses tracking

    /// Auto-tracking must not fight the finger: while `isEditingROI` is set, an
    /// accepted reading must not move the window.
    func testROITracking_pausedWhileEditing() {
        let (appState, device) = makeAppState()
        appState.roiTrackingEnabled = true
        appState.isEditingROI = true

        let originalROI = appState.devices[0].roi
        let observed = NormalizedROI(x: 0.6, y: 0.6, width: 0.3, height: 0.1)
        let measurement = DAQPal.Measurement(timestamp: 1.0, value: 12.345, unit: nil,
                                             confidence: 0.95, accepted: true)
        appState.apply(FrameResult(timestamp: 1.0,
                                   readings: [device.id: measurement],
                                   debugText: nil,
                                   observedROIs: [device.id: observed]))

        XCTAssertEqual(appState.devices[0].roi, originalROI,
                       "ROI auto-tracking moved the window while the user was dragging it.")
    }
}
