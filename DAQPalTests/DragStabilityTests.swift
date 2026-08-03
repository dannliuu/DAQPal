//
//  DragStabilityTests.swift
//  DAQPalTests
//
//  Spec §3A / Gate 2A: the selection window jittered while being dragged, but
//  only while its label read "DMM-1 · SEARCHING".
//
//  Measured mechanism (60 frames per scenario, `withObservationTracking` over
//  exactly what `ROISelectionOverlay.body` reads, before the fix):
//
//    SEARCHING · rejected · VARYING confidence   60/60 frames invalidated
//    SEARCHING · rejected · CONSTANT confidence   1/60 frames invalidated
//    LOCKED    · steady value · VARYING conf.    60/60 frames invalidated
//    LOCKED    · steady value · CONSTANT conf.    1/60 frames invalidated
//
//  So the churn driver is confidence, and nothing else. In SEARCHING that
//  churn is pure waste — no view displays an unlocked device's confidence
//  (`DeviceReadingCard.confidence` returns 0 unless locked; `ROIWindowLabel`'s
//  SEARCHING branch shows no percentage) — yet it republished `liveReadings`
//  at capture rate, rebuilding the overlay's body and every `DragGesture` in
//  it while a finger was down.
//
//  Two independent fixes, tested here:
//    A. `AppState.apply` normalizes an unlocked reading's confidence to 0, so
//       the change gate actually holds in SEARCHING (tests 1-2).
//    B. `ROISelectionOverlay`/`ROIWindowView` no longer read `liveReadings` in
//       any body that attaches a gesture; the lock-dependent visuals moved to
//       leaves. This is the fix that also covers the LOCKED row above, where
//       the churn is legitimate and cannot be gated away. Its structural
//       property — that the drag math is a pure function of a frozen anchor —
//       is what tests 3 and 5 pin.
//
//  All logic tests: no Date(), no sleeps, no randomness.
//

import Observation
import XCTest
@testable import DAQPal

@MainActor
final class DragStabilityTests: XCTestCase {

    // MARK: Helpers

    private func makeAppState(roi: NormalizedROI? = .defaultROI) -> (AppState, Device) {
        let appState = AppState()
        var device = appState.devices[0]
        device.roi = roi
        appState.updateDevice(device)
        // These tests isolate the publish path; auto-tracking is enabled only
        // by the test that is specifically about it.
        appState.roiTrackingEnabled = false
        return (appState, device)
    }

    /// Registers exactly the observable reads `ROISelectionOverlay.body`
    /// performs, runs `mutation`, and reports whether SwiftUI would have been
    /// asked to rebuild it — and with it every `ROIWindowView` and every
    /// `DragGesture` those bodies attach.
    private func overlayWouldInvalidate(_ appState: AppState, during mutation: () -> Void) -> Bool {
        var invalidated = false
        withObservationTracking {
            _ = appState.devices
            _ = appState.videoDimensions
            _ = appState.fieldCatalog
            // The read that used to be here in production code, and is the
            // reason this whole test file exists. Tracking it is what makes
            // these assertions meaningful even after Fix B removed it: it
            // proves Fix A holds the gate at the source.
            _ = appState.liveReadings
        } onChange: {
            invalidated = true
        }
        mutation()
        return invalidated
    }

    private func measurement(_ t: TimeInterval,
                             value: Double,
                             confidence: Float,
                             accepted: Bool) -> DAQPal.Measurement {
        DAQPal.Measurement(timestamp: t, value: value, unit: nil,
                           confidence: confidence, accepted: accepted)
    }

    /// A confidence that moves every frame the way a real rejected OCR pass
    /// does — deterministic, but never twice the same in this range.
    private func wanderingConfidence(_ i: Int, base: Double, swing: Double) -> Float {
        Float(base + swing * sin(Double(i) * 0.7))
    }

    private func frame(_ appState: AppState,
                       _ deviceID: UUID,
                       index i: Int,
                       confidence: Float,
                       accepted: Bool,
                       value: Double = 12.345) {
        let t = Double(i) / 12.0
        appState.apply(FrameResult(timestamp: t,
                                   readings: [deviceID: measurement(t, value: value,
                                                                    confidence: confidence,
                                                                    accepted: accepted)],
                                   debugText: nil))
    }

    // MARK: 1 — the churn regression that caused the drag jitter

    /// A SEARCHING device fed rejected readings whose confidence moves every
    /// frame must publish NOTHING after the first frame. Before Fix A this
    /// republished `liveReadings` on all 59 measured frames, so the overlay —
    /// and the gesture mid-drag — was rebuilt at capture rate.
    func testSearchingDevice_varyingConfidenceOnRejectedReadings_doesNotChurn() {
        let (appState, device) = makeAppState()

        // First frame legitimately publishes: nil → a real LiveReading, and
        // uiMode goes selectingROI → live. Measure the steady state after it.
        frame(appState, device.id, index: 0,
              confidence: wanderingConfidence(0, base: 0.30, swing: 0.20), accepted: false)
        let settled = appState.liveReadings[device.id]
        XCTAssertEqual(settled?.locked, false, "Precondition: the device must be SEARCHING.")

        var invalidations = 0
        let frames = 1..<60
        for i in frames {
            if overlayWouldInvalidate(appState, during: {
                self.frame(appState, device.id, index: i,
                           confidence: self.wanderingConfidence(i, base: 0.30, swing: 0.20),
                           accepted: false)
            }) {
                invalidations += 1
            }
        }

        XCTAssertEqual(invalidations, 0,
                       "A SEARCHING device republished liveReadings on \(invalidations)/\(frames.count) frames. Nothing displays an unlocked device's confidence, so each of those rebuilt ROISelectionOverlay — and any DragGesture in it — for no visible change.")
        XCTAssertEqual(appState.liveReadings[device.id], settled,
                       "The published reading itself changed across frames that display identically.")
    }

    /// The same guarantee stated as a property of the published value rather
    /// than of the observation system: while unlocked, the confidence the UI
    /// never shows must not be published at all.
    func testSearchingDevice_publishedConfidenceIsNormalizedToZero() {
        let (appState, device) = makeAppState()
        frame(appState, device.id, index: 0, confidence: 0.73, accepted: false)

        XCTAssertEqual(appState.liveReadings[device.id]?.locked, false)
        XCTAssertEqual(appState.liveReadings[device.id]?.confidence, 0,
                       "An unlocked device must publish no confidence — no view reads it in that state.")
        XCTAssertNil(appState.liveReadings[device.id]?.value,
                     "An unlocked device must publish no value — the card shows the placeholder.")
    }

    // MARK: 2 — do not over-normalize

    /// The counterpart guard. A LOCKED device's confidence IS displayed (the
    /// reading card's bar and percentage, and the ROI window label), so it must
    /// keep publishing. Normalizing it away would silently freeze the bar.
    func testLockedDevice_varyingConfidence_stillPublishes() {
        let (appState, device) = makeAppState()

        frame(appState, device.id, index: 0, confidence: 0.80, accepted: true)
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true,
                       "Precondition: an accepted reading must lock the device.")

        // Same value, different confidence, still within the lock timeout.
        let before = appState.liveReadings[device.id]
        let invalidated = overlayWouldInvalidate(appState) {
            self.frame(appState, device.id, index: 1, confidence: 0.42, accepted: true)
        }

        XCTAssertTrue(invalidated, "A locked device's changed confidence must reach the UI.")
        XCTAssertEqual(appState.liveReadings[device.id]?.confidence ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertNotEqual(appState.liveReadings[device.id], before)
        XCTAssertEqual(appState.liveReadings[device.id]?.value, 12.345,
                       "A locked device must still publish its value.")
    }

    /// The transition out of lock must publish too — that is a visible change
    /// (yellow solid border → dashed searching border, LOCKED → SEARCHING).
    func testLockTransition_publishes() {
        let (appState, device) = makeAppState()
        frame(appState, device.id, index: 0, confidence: 0.90, accepted: true)
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true)

        // Rejected readings past `AppState.lockTimeout` (1 s at 12 fps ⇒ frame
        // 13 is 1.083 s after frame 0).
        let invalidated = overlayWouldInvalidate(appState) {
            self.frame(appState, device.id, index: 13, confidence: 0.31, accepted: false)
        }
        XCTAssertTrue(invalidated, "Losing lock must reach the UI.")
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, false)
        XCTAssertEqual(appState.liveReadings[device.id]?.confidence, 0)
    }

    // MARK: 3 — the drag itself is monotonic

    /// Every `onChanged` tick reapplies the gesture's CUMULATIVE translation to
    /// a frozen anchor. So a drag whose translation advances monotonically
    /// produces an origin that advances monotonically, with no reversal between
    /// consecutive steps — which is exactly what "jitter" would violate.
    func testDrag_monotonicTranslations_produceMonotonicOrigin() {
        let container = CGSize(width: 390, height: 700)
        let anchor = CGRect(x: 40, y: 100, width: 120, height: 60)

        // A realistic finger path: uneven step sizes, always forward.
        let deltas: [CGFloat] = [2, 5, 3, 9, 1, 14, 6, 2, 11, 4, 7, 3, 8, 5, 1]
        var cumulative = CGSize.zero
        var rects: [CGRect] = []
        for d in deltas {
            cumulative.width += d
            cumulative.height += d * 1.5
            rects.append(ROIWindowGeometry.movedRect(anchor: anchor,
                                                     translation: cumulative,
                                                     containerSize: container))
        }

        var previous = ROIWindowGeometry.movedRect(anchor: anchor,
                                                   translation: .zero,
                                                   containerSize: container)
        for (step, rect) in rects.enumerated() {
            XCTAssertGreaterThanOrEqual(rect.origin.x, previous.origin.x,
                                        "Step \(step) moved the window BACKWARDS in x (\(previous.origin.x) → \(rect.origin.x)).")
            XCTAssertGreaterThanOrEqual(rect.origin.y, previous.origin.y,
                                        "Step \(step) moved the window BACKWARDS in y (\(previous.origin.y) → \(rect.origin.y)).")
            XCTAssertEqual(rect.size, anchor.size,
                           "A move must never change the window's size.")
            previous = rect
        }
        XCTAssertGreaterThan(previous.origin.x, anchor.origin.x,
                             "Precondition: the drag must actually have moved the window.")
    }

    /// Anchor-relative math means a DROPPED tick cannot displace the result —
    /// the defect a rebuilt gesture would introduce. Feeding the same
    /// cumulative translation after skipping intermediate ticks lands in the
    /// identical place.
    func testDrag_droppedTicksDoNotDisplaceTheResult() {
        let container = CGSize(width: 390, height: 700)
        let anchor = CGRect(x: 40, y: 100, width: 120, height: 60)
        let final = CGSize(width: 73, height: 51)

        let viaEveryTick = ROIWindowGeometry.movedRect(anchor: anchor, translation: final,
                                                       containerSize: container)
        // Same endpoint reached after arbitrarily many intermediate ticks were
        // evaluated (and their results discarded).
        for w in stride(from: CGFloat(0), through: final.width, by: 7) {
            _ = ROIWindowGeometry.movedRect(anchor: anchor,
                                            translation: CGSize(width: w, height: w),
                                            containerSize: container)
        }
        let viaDroppedTicks = ROIWindowGeometry.movedRect(anchor: anchor, translation: final,
                                                          containerSize: container)

        XCTAssertEqual(viaEveryTick, viaDroppedTicks,
                       "The move math must depend only on (frozen anchor, cumulative translation).")
    }

    /// Clamping must pin the window at the edge, not bounce it.
    func testDrag_clampsAtContainerEdgeWithoutReversing() {
        let container = CGSize(width: 390, height: 700)
        // Starts fully inside the container, near the bottom-right corner, so
        // the clamp is reached by dragging rather than being in effect already.
        let anchor = CGRect(x: 240, y: 600, width: 120, height: 60)

        var previous = anchor
        for step in 1...40 {
            let rect = ROIWindowGeometry.movedRect(anchor: anchor,
                                                   translation: CGSize(width: CGFloat(step) * 10,
                                                                       height: CGFloat(step) * 10),
                                                   containerSize: container)
            XCTAssertGreaterThanOrEqual(rect.origin.x, previous.origin.x)
            XCTAssertGreaterThanOrEqual(rect.origin.y, previous.origin.y)
            XCTAssertLessThanOrEqual(rect.maxX, container.width + 0.0001)
            XCTAssertLessThanOrEqual(rect.maxY, container.height + 0.0001)
            previous = rect
        }
        XCTAssertEqual(previous.maxX, container.width, accuracy: 0.0001)
        XCTAssertEqual(previous.maxY, container.height, accuracy: 0.0001)
    }

    // MARK: 4 — no automatic writer moves geometry while the finger is down

    /// `isEditingROI` pauses ROI auto-tracking. An accepted reading arriving
    /// with an `observedROI` far from the window must not move it mid-drag.
    func testAutomaticWriters_doNotMoveGeometryWhileEditing() {
        let (appState, device) = makeAppState()
        appState.roiTrackingEnabled = true
        appState.isEditingROI = true

        let original = appState.devices[0].roi
        let observed = NormalizedROI(x: 0.6, y: 0.7, width: 0.3, height: 0.1)
        for i in 0..<20 {
            let t = Double(i) / 12.0
            appState.apply(FrameResult(timestamp: t,
                                       readings: [device.id: measurement(t, value: 12.345,
                                                                         confidence: 0.9,
                                                                         accepted: true)],
                                       debugText: nil,
                                       observedROIs: [device.id: observed]))
        }

        XCTAssertEqual(appState.devices[0].roi, original,
                       "An automatic writer moved the ROI while the user was dragging it.")
        // And the pipeline is told about the drag too, so nothing downstream
        // re-derives geometry from a stale selection.
        XCTAssertTrue(appState.screenLockInputs().isUserDragging,
                      "The screen-lock pipeline must be told the user is dragging.")
    }

    /// The pause must be exactly that — a pause. Once the gesture ends,
    /// tracking has to resume, or the fix would silently disable it.
    func testAutomaticWriters_resumeAfterEditingEnds() {
        let (appState, device) = makeAppState()
        appState.roiTrackingEnabled = true
        appState.isEditingROI = false

        let original = appState.devices[0].roi
        let observed = NormalizedROI(x: 0.6, y: 0.7, width: 0.3, height: 0.1)
        appState.apply(FrameResult(timestamp: 1.0,
                                   readings: [device.id: measurement(1.0, value: 12.345,
                                                                     confidence: 0.9,
                                                                     accepted: true)],
                                   debugText: nil,
                                   observedROIs: [device.id: observed]))

        XCTAssertNotEqual(appState.devices[0].roi, original,
                          "ROI auto-tracking did not resume after the gesture ended.")
    }

    // MARK: 5 — what is committed is what was last rendered

    /// `onEnded` recomputes from the same frozen anchor with the same pure
    /// function, so given the final translation it reproduces the last rect the
    /// user saw, exactly.
    func testCommit_reproducesTheLastRenderedRect() {
        let container = CGSize(width: 390, height: 700)
        let anchor = CGRect(x: 40, y: 100, width: 120, height: 60)

        var cumulative = CGSize.zero
        var lastRendered = anchor
        for d in [CGFloat(3), 7, 2, 11, 6, 4] {
            cumulative.width += d
            cumulative.height += d
            lastRendered = ROIWindowGeometry.movedRect(anchor: anchor, translation: cumulative,
                                                       containerSize: container)
        }

        // What `.onEnded` computes, from the same anchor and the same final
        // cumulative translation.
        let committed = ROIWindowGeometry.movedRect(anchor: anchor, translation: cumulative,
                                                    containerSize: container)
        XCTAssertEqual(committed, lastRendered,
                       "The rect committed on gesture end differs from the last one rendered.")
    }

    /// And the commit's round trip through normalized ROI space must land back
    /// on the same view rect — otherwise the window would visibly jump the
    /// instant the finger lifted, which reads as jitter at the end of a drag.
    func testCommit_normalizedRoundTripPreservesGeometry() {
        let mapper = AspectFillMapper(contentSize: CGSize(width: 1080, height: 1920),
                                      containerSize: CGSize(width: 390, height: 700))
        let anchor = mapper.viewRect(fromNormalized: .defaultROI)
        let rendered = ROIWindowGeometry.movedRect(anchor: anchor,
                                                   translation: CGSize(width: 33, height: 21),
                                                   containerSize: mapper.containerSize)

        // Exactly what `ROIWindowView.commit` does…
        let normalized = mapper.normalizedRect(fromViewRect: rendered).clamped()
        // …and exactly what `currentRect` renders once `liveDragRect` is nil.
        let redrawn = mapper.viewRect(fromNormalized: normalized)

        XCTAssertEqual(redrawn.origin.x, rendered.origin.x, accuracy: 0.001)
        XCTAssertEqual(redrawn.origin.y, rendered.origin.y, accuracy: 0.001)
        XCTAssertEqual(redrawn.size.width, rendered.size.width, accuracy: 0.001)
        XCTAssertEqual(redrawn.size.height, rendered.size.height, accuracy: 0.001)
    }

    /// The resize path shares the frozen-anchor property, and must also honour
    /// the minimum size without collapsing or flipping the rect.
    func testResize_isAnchorRelativeAndRespectsMinimumSize() {
        let container = CGSize(width: 390, height: 700)
        let anchor = CGRect(x: 100, y: 200, width: 120, height: 60)
        let minimum: CGFloat = 32

        for handle in ROIResizeHandle.allCases {
            // Idempotent for a given cumulative translation.
            let t = CGSize(width: -400, height: -400)
            let a = ROIWindowGeometry.resizedRect(handle: handle, anchor: anchor, translation: t,
                                                  containerSize: container, minimumSize: minimum)
            let b = ROIWindowGeometry.resizedRect(handle: handle, anchor: anchor, translation: t,
                                                  containerSize: container, minimumSize: minimum)
            XCTAssertEqual(a, b, "\(handle) resize is not a pure function of (anchor, translation).")
            XCTAssertGreaterThanOrEqual(a.width, minimum, "\(handle) collapsed the window's width.")
            XCTAssertGreaterThanOrEqual(a.height, minimum, "\(handle) collapsed the window's height.")

            // Zero translation must be the identity.
            XCTAssertEqual(ROIWindowGeometry.resizedRect(handle: handle, anchor: anchor,
                                                         translation: .zero,
                                                         containerSize: container,
                                                         minimumSize: minimum),
                           anchor,
                           "\(handle) moved the window on a zero-translation tick.")
        }
    }

    // MARK: The manual fallback must be untouched (project invariant 4)

    /// Everything above must hold with the intelligent pipeline off, which is
    /// the shipping default and the mandated fallback.
    func testManualWorkflow_unaffectedWithScreenLockDisabled() {
        let (appState, device) = makeAppState(roi: nil)
        XCTAssertFalse(appState.screenLockEnabled)

        // Placing the ROI by hand is what a committed drag does.
        var placed = device
        placed.roi = NormalizedROI(x: 0.2, y: 0.3, width: 0.4, height: 0.12)
        appState.updateDevice(placed)
        XCTAssertEqual(appState.devices[0].roi, placed.roi)

        // It then locks on accepted readings and searches on rejected ones.
        frame(appState, device.id, index: 0, confidence: 0.91, accepted: true)
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true)
        XCTAssertEqual(appState.liveReadings[device.id]?.confidence ?? -1, 0.91, accuracy: 0.0001)

        frame(appState, device.id, index: 13, confidence: 0.44, accepted: false)
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, false)
    }
}
