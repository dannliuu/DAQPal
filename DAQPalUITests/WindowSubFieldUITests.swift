//
//  WindowSubFieldUITests.swift
//  DAQPalUITests
//
//  End-to-end proof that in-window sub-field selection actually reaches the
//  screen. The unit tests prove the splitter localizes two readings and that
//  the state machine turns a selection into a device; neither can tell whether
//  the boxes are mounted, hit-testable, or positioned inside the window — and
//  every earlier defect in this feature's neighbourhood (the drag-latency
//  regression, the field-device ROI filter) was invisible to unit tests and
//  visible immediately on a running app.
//
//  `-daqpal-dual-reading` renders a large primary reading over a smaller one,
//  as the target IR thermometer does; `-daqpal-auto-roi` lands a window on that
//  panel so no synthetic drag is needed to reach the placed state.
//

import XCTest

final class WindowSubFieldUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// The whole user-facing promise: two numbers in one window ⇒ a box per
    /// number, tappable, and a tap creates a second recorded column.
    func testSubFieldChipsAppearAndSelectingOneAddsADevice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-daqpal-auto-roi", "-daqpal-dual-reading"]
        app.launch()

        let main = app.buttons["MAIN reading in this window"]
        XCTAssertTrue(main.waitForExistence(timeout: 20),
                      "No sub-field chip appeared over a window containing two readings")

        let aux = app.buttons["AUX 1 reading in this window"]
        XCTAssertTrue(aux.waitForExistence(timeout: 5),
                      "Only one candidate was offered — the second reading was not localized on screen")

        let candidates = XCTAttachment(screenshot: app.screenshot())
        candidates.lifetime = .keepAlways
        add(candidates)

        // The device-count chip is the visible proof that a selection becomes a
        // recordable column rather than merely highlighting a rectangle.
        XCTAssertTrue(app.staticTexts["1 configured device"].exists,
                      "Expected a single device before any sub-field is selected")

        XCTAssertEqual(main.value as? String, "Not selected")
        main.tap()
        XCTAssertEqual(main.value as? String, "Selected for capture",
                       "Tapping the chip did not toggle the selection")

        XCTAssertTrue(app.staticTexts["2 configured devices"].waitForExistence(timeout: 5),
                      "Selecting a sub-field did not create its own device, so it would never get a CSV column")

        let selected = XCTAttachment(screenshot: app.screenshot())
        selected.lifetime = .keepAlways
        selected.name = "sub-field selected"
        add(selected)

        // Deselecting must give the device back, or repeated taps would leak
        // columns into the recording.
        main.tap()
        let returned = app.staticTexts["1 configured device"].waitForExistence(timeout: 5)
        if !returned {
            let chips = app.staticTexts.allElementsBoundByIndex
                .compactMap { $0.label.contains("configured device") ? $0.label : nil }
            XCTFail("Deselect left the device behind. Device chip now reads \(chips); "
                    + "chip value is \(String(describing: main.value)); "
                    + "chip exists: \(main.exists)")
        }
    }

    // A single-reading display SHOULD offer no boxes, but currently can offer
    // two when the reading is split at its decimal point. That is measured and
    // documented in `WindowSubFieldTests
    // .testNoSingleReadingValueOffersASpuriousChoice`, at unit level where the
    // failure rate is quantified instead of being a coin flip on one launch.

}
