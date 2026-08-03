//
//  DragLatencyUITests.swift
//  DAQPalUITests
//
//  Performs a REAL drag against the running app and reads back the interval
//  distribution the gesture actually experienced.
//
//  Why this exists: three successive diagnoses of the "jittery and sluggish"
//  SEARCHING drag were argued from reading code, and the symptom survived all
//  three. Unit tests can prove the state layer is quiet; only a real gesture
//  can show whether callbacks are delivered evenly. A smooth drag produces
//  ticks at the display refresh interval (~8.3 ms at 120 Hz, ~16.7 ms at
//  60 Hz); starvation shows up in the TAIL, so the assertions are on p95, the
//  worst interval and the stall count — never the mean, which hides exactly
//  the stalls that are perceptible.
//

import XCTest

final class DragLatencyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Drags the ROI window while the pipeline is in SEARCHING and reports the
    /// callback-interval distribution.
    @MainActor
    func testDragLatencyWhileSearching() throws {
        let app = XCUIApplication()
        // -daqpal-auto-roi places device 1's window over the synthetic display.
        // It never locks on the default unconstrained format quickly enough to
        // leave SEARCHING during the drag, which is the reported condition.
        app.launchArguments = ["-daqpal-auto-roi"]
        app.launch()

        // Let the capture pipeline reach steady state before touching anything.
        Thread.sleep(forTimeInterval: 4)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10), "App window never appeared")

        // A slow, many-step drag across the viewport — the gesture that is
        // reported as jittery. `press(forDuration:thenDragTo:)` produces a
        // continuous stream of touch events rather than a single jump.
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
        start.press(forDuration: 0.4, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

        // The probe publishes its summary on gesture end.
        let probe = app.staticTexts["gesture-latency"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10),
                      "No gesture-latency reading was published — the drag may not have hit the ROI window.")

        let summary = probe.label
        print("=== MEASURED DRAG LATENCY (SEARCHING) ===")
        print(summary)
        XCTContext.runActivity(named: "drag latency") { activity in
            let attachment = XCTAttachment(string: summary)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        // Parse "ticks N · p50 X.Xms · p95 X.Xms · max X.Xms · stalls N".
        /// The summary carries both probes, so keys like "p95 " appear twice —
        /// `occurrence` selects which one.
        func value(after key: String, occurrence: Int = 1) -> Double? {
            var searchStart = summary.startIndex
            for _ in 0..<occurrence {
                guard let range = summary.range(of: key, range: searchStart..<summary.endIndex) else { return nil }
                searchStart = range.upperBound
            }
            let token = summary[searchStart...].prefix { "0123456789.".contains($0) }
            return Double(token)
        }

        let ticks = value(after: "ticks ") ?? 0
        let p95 = value(after: "p95 ") ?? .infinity
        let worst = value(after: "max ") ?? .infinity
        let stalls = value(after: "stalls ") ?? .infinity

        XCTAssertGreaterThan(ticks, 10,
                             "Only \(ticks) gesture callbacks for a 0.4s+ drag — the gesture is being starved or the drag missed. \(summary)")
        XCTAssertLessThan(p95, 40,
                          "p95 callback interval \(p95)ms — a smooth drag delivers ~8-17ms. \(summary)")
        XCTAssertLessThan(worst, 120,
                          "Worst callback gap \(worst)ms is a visible stall. \(summary)")
        XCTAssertLessThan(stalls, 2,
                          "\(stalls) stalls over 50ms during one drag. \(summary)")

        // RENDER cadence — the half that actually corresponds to judder.
        // Touch callbacks arrive at display rate whether or not compositing
        // keeps up, so the assertions above can pass on a visibly stuttering
        // drag. A dropped frame is an interval longer than 1.5x the display's
        // own frame duration.
        let frames = value(after: "frames ") ?? 0
        let framesP95 = value(after: "p95 ", occurrence: 2) ?? .infinity
        let dropped = value(after: "dropped ") ?? .infinity

        XCTAssertGreaterThan(frames, 10,
                             "Only \(frames) composited frames during the drag. \(summary)")
        XCTAssertLessThan(dropped, 3,
                          "\(dropped) DROPPED FRAMES during one drag — this is what reads as judder, and it is invisible to the callback measurements above. \(summary)")
        XCTAssertLessThan(framesP95, 34,
                          "p95 frame interval \(framesP95)ms — sustained frame drops. \(summary)")
    }
    /// CONTROL CONDITION. The same synthetic drag with the capture UI mounted
    /// but the frame pump never started. XCUITest synthesizes drags rather than replaying a real 120 Hz
    /// touch stream, so a low tick count is ambiguous on its own: it could mean
    /// the app is starved, or simply that XCUITest emitted few events. Running
    /// the identical gesture against an idle app separates the two. Whatever
    /// this reports is XCUITest's own event rate — the floor that the
    /// capture-running measurement must be compared against, not zero.
    @MainActor
    func testDragLatencyControl_noCapturePipeline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-daqpal-auto-roi", "-daqpal-idle-capture"]
        app.launch()
        Thread.sleep(forTimeInterval: 2)

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.42))
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62))
        start.press(forDuration: 0.4, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.3)

        let probe = app.staticTexts["gesture-latency"]
        XCTAssertTrue(probe.waitForExistence(timeout: 10),
                      "No gesture-latency reading in the control run — the drag missed the window.")

        print("=== CONTROL (no capture pipeline) ===")
        print(probe.label)
        let attachment = XCTAttachment(string: probe.label)
        attachment.lifetime = .keepAlways
        add(attachment)

        // No assertion on absolute numbers: this run EXISTS to establish
        // XCUITest's own event rate. It is read alongside the capture-running
        // measurement, and the comparison is the result.
    }

}
