//
//  DAQPalTests.swift
//  DAQPalTests
//
//  Trivial smoke test: the contract's public types/constants exist and are
//  wired together as documented. Real coverage lives in the per-module
//  suites alongside this file (FormatValidatorTests, ValidationPipelineTests,
//  CSVExporterTests, RecordingSessionTests, SyntheticPipelineTests, etc).
//

import XCTest
@testable import DAQPal

final class DAQPalTests: XCTestCase {

    func testProductNaming_isDAQPalEverywhere() {
        // Hard project rule: the product is DAQPal, never a legacy name.
        XCTAssertEqual(CSVExporter.fileName, "daqpal_session.csv")
    }

    @MainActor
    func testAppStateConstants() {
        XCTAssertEqual(AppState.lockTimeout, 1.0)
        XCTAssertGreaterThan(AppState.maxDevices, 0)
    }

    @MainActor
    func testAppState_defaultsToOneDevice() {
        let appState = AppState()
        XCTAssertEqual(appState.devices.count, 1)
        XCTAssertFalse(appState.isRecording)
        XCTAssertNil(appState.completedSession)
    }

    func testDevice_makeDefault_isUnconstrainedAndDimensionless() {
        // Field-report decision (2026-07-23): new devices start dimensionless
        // with lenient numeric extraction — no unit, no range, no grammar
        // assumption. Strict format is opt-in via the format sheet.
        let device = Device.makeDefault(index: 1)
        XCTAssertEqual(device.name, "DMM-1")
        XCTAssertEqual(device.displayFormat, DisplayFormat.unconstrained)
        XCTAssertFalse(device.displayFormat.constrainToFormat)
        XCTAssertNil(device.displayFormat.unit)
        XCTAssertNil(device.displayFormat.minimumValue)
        XCTAssertNil(device.displayFormat.maximumValue)
        XCTAssertNil(device.roi)
    }

    func testDisplayFormat_defaultDMM_matchesSpecCanonicalExample() {
        XCTAssertEqual(DisplayFormat.defaultDMM.patternPreview, "±XX.XXX V")
    }

    func testMeasurement_rejectedConvenience_isNeverAccepted() {
        let m = Measurement.rejected(timestamp: 0, reason: .displayLost)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .displayLost)
        XCTAssertTrue(m.value.isNaN)
    }

    func testRejectionReason_allCasesHaveADisplayLabel() {
        for reason in RejectionReason.allCases {
            XCTAssertFalse(reason.displayLabel.isEmpty)
        }
    }
}
