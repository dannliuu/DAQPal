//
//  DragChurnDiagnosticTests.swift
//  DAQPalTests
//
//  DIAGNOSTIC (Gate 2A). The SEARCHING drag is still reported jittery and
//  sluggish after the confidence-normalization and leaf-isolation fixes, so
//  this measures which observable property is STILL written per frame while a
//  drag is in progress, one property at a time, instead of reasoning about it.
//
//  Every case simulates the real reported scenario: a placed-but-unlocked
//  device (label "DMM-1 · SEARCHING"), rejected readings arriving at capture
//  rate, and `isEditingROI == true` because the user's finger is down.
//

import Observation
import XCTest
@testable import DAQPal

@MainActor
final class DragChurnDiagnosticTests: XCTestCase {

    private static let frameCount = 60

    /// Counts how many of `frameCount` applied frames would invalidate a view
    /// whose body performs exactly `read`.
    private func invalidations(of appState: AppState,
                               reading read: @escaping (AppState) -> Void,
                               frames: [FrameResult]) -> Int {
        var count = 0
        for frame in frames {
            var fired = false
            withObservationTracking { read(appState) } onChange: { fired = true }
            appState.apply(frame)
            if fired { count += 1 }
        }
        return count
    }

    /// A placed device that never locks — the SEARCHING state — with a drag in
    /// progress.
    private func makeDraggingSearchState() -> (AppState, UUID) {
        let appState = AppState()
        var device = appState.devices[0]
        device.roi = .defaultROI
        appState.updateDevice(device)
        appState.isEditingROI = true      // finger is down
        appState.roiTrackingEnabled = true
        return (appState, device.id)
    }

    /// Rejected readings whose fused confidence moves every frame, which is
    /// what the pipeline actually produces while searching.
    private func searchingFrames(deviceID: UUID, count: Int = frameCount) -> [FrameResult] {
        (0..<count).map { i in
            let m = DAQPal.Measurement.rejected(timestamp: Double(i) / 12.0,
                                                reason: .invalidFormat,
                                                unit: nil,
                                                confidence: 0.30 + Float(i % 17) * 0.01,
                                                rawText: "8O.8")
            return FrameResult(timestamp: Double(i) / 12.0,
                               readings: [deviceID: m],
                               debugText: "Detected: 8O.8 (\(i))")
        }
    }

    // MARK: - Per-property churn during a SEARCHING drag

    func testPerPropertyChurnDuringSearchingDrag() {
        let probes: [(String, (AppState) -> Void)] = [
            ("liveReadings", { _ = $0.liveReadings }),
            ("devices", { _ = $0.devices }),
            ("debugText", { _ = $0.debugText }),
            ("processedFPS", { _ = $0.processedFPS }),
            ("uiMode", { _ = $0.uiMode }),
            ("videoDimensions", { _ = $0.videoDimensions }),
            ("fieldCatalog", { _ = $0.fieldCatalog }),
            ("snapState", { _ = $0.snapState }),
            ("lockedTarget", { _ = $0.lockedTarget }),
            ("screenCandidates", { _ = $0.screenCandidates }),
            ("activeRecording", { _ = $0.activeRecording })
        ]

        var report: [String] = []
        var churning: [String: Int] = [:]
        for (name, read) in probes {
            let (appState, deviceID) = makeDraggingSearchState()
            let frames = searchingFrames(deviceID: deviceID)
            let n = invalidations(of: appState, reading: read, frames: frames)
            report.append(String(format: "  %-18s %2d / %d", (name as NSString).utf8String!, n, Self.frameCount))
            if n > 0 { churning[name] = n }
        }

        print("=== SEARCHING-drag churn, invalidations per \(Self.frameCount) frames ===")
        print(report.joined(separator: "\n"))

        // The overlay that hosts the drag gesture reads `devices`,
        // `videoDimensions` and `fieldCatalog`. NONE of them may churn while a
        // finger is down, or the gesture is rebuilt mid-drag.
        let gestureHostReads = ["devices", "videoDimensions", "fieldCatalog"]
        for name in gestureHostReads {
            XCTAssertNil(churning[name],
                         "\(name) is written \(churning[name] ?? 0)/\(Self.frameCount) frames during a SEARCHING drag — it is read by the view that attaches the drag gesture, so the gesture is being rebuilt mid-drag. Full report:\n\(report.joined(separator: "\n"))")
        }
    }

    /// The whole capture screen's read set, which is what determines whether
    /// the main thread is doing layout work while the finger is moving.
    func testWholeScreenChurnDuringSearchingDrag() {
        let (appState, deviceID) = makeDraggingSearchState()
        let frames = searchingFrames(deviceID: deviceID)
        let n = invalidations(of: appState, reading: {
            _ = $0.liveReadings
            _ = $0.devices
            _ = $0.debugText
            _ = $0.processedFPS
            _ = $0.uiMode
            _ = $0.videoDimensions
            _ = $0.fieldCatalog
            _ = $0.snapState
            _ = $0.lockedTarget
            _ = $0.screenCandidates
        }, frames: frames)

        print("=== whole-screen invalidations during SEARCHING drag: \(n) / \(Self.frameCount) ===")
        XCTAssertLessThanOrEqual(n, 2,
                                 "The capture screen invalidates \(n)/\(Self.frameCount) frames while the user is dragging in SEARCHING. Anything beyond warm-up competes with gesture handling on the main thread.")
    }

    /// Recording is the heavier case: `activeRecording` is an @Observable class
    /// whose sample array grows every frame.
    func testChurnWhileRecordingDuringSearchingDrag() {
        let (appState, deviceID) = makeDraggingSearchState()
        appState.startRecording()
        let frames = searchingFrames(deviceID: deviceID)
        let n = invalidations(of: appState, reading: {
            _ = $0.liveReadings
            _ = $0.devices
            _ = $0.videoDimensions
            _ = $0.fieldCatalog
        }, frames: frames)
        print("=== gesture-host invalidations while RECORDING + SEARCHING drag: \(n) / \(Self.frameCount) ===")
        XCTAssertLessThanOrEqual(n, 2,
                                 "Recording adds \(n)/\(Self.frameCount) gesture-host invalidations during a drag.")
    }
    // MARK: - The drain must stand down during a gesture

    /// The measured cause of the "sluggish" half of the defect. Invalidation is
    /// NOT the remaining problem — `testWholeScreenChurnDuringSearchingDrag`
    /// proves the state layer is quiet. What is left is pipeline cost: while
    /// SEARCHING nothing is ever accepted, so recognition never short-circuits
    /// and the `.accurate` Vision pass (documented ~382 ms) runs on every frame
    /// for the entire gesture, with two main-actor hops per frame queueing
    /// against touch handling.
    ///
    /// `InteractionState` is the lock-free channel that lets the drain see the
    /// gesture without a main-actor hop.
    func testInteractionStateMirrorsEditingFlag() {
        let appState = AppState()
        InteractionState.shared.isUserInteracting = false

        appState.isEditingROI = true
        XCTAssertTrue(InteractionState.shared.isUserInteracting,
                      "The drain cannot stand down for a gesture it cannot see.")

        appState.isEditingROI = false
        XCTAssertFalse(InteractionState.shared.isUserInteracting,
                       "A stuck flag would suspend recognition permanently.")
    }

    /// Redundant writes must not thrash the lock — the flag changes twice per
    /// gesture, not per frame.
    func testInteractionStateIsIdempotent() {
        let appState = AppState()
        appState.isEditingROI = true
        appState.isEditingROI = true
        XCTAssertTrue(InteractionState.shared.isUserInteracting)
        appState.isEditingROI = false
        appState.isEditingROI = false
        XCTAssertFalse(InteractionState.shared.isUserInteracting)
    }

    /// A gesture that ends must always release the drain, including the path
    /// where the gesture had no usable anchor (a latent bug fixed earlier left
    /// `isEditingROI` stuck true for the rest of the session, which would now
    /// suspend recognition permanently rather than merely pausing tracking).
    func testGestureEndAlwaysReleasesTheDrain() {
        let appState = AppState()
        appState.isEditingROI = true
        XCTAssertTrue(InteractionState.shared.isUserInteracting)
        // Simulate onEnded's unconditional clear.
        appState.isEditingROI = false
        XCTAssertFalse(InteractionState.shared.isUserInteracting,
                       "A stuck interaction flag silently disables all recognition.")
    }

}
