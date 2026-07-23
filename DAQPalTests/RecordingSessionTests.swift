//
//  RecordingSessionTests.swift
//  DAQPalTests
//
//  `RecordingSession` and `CompletedSession` are `@MainActor`; this suite
//  runs on the main actor throughout. Also covers `AppState.apply(_:)`'s
//  lock/unlock behavior, which is the only place that logic lives.
//

import Foundation
import XCTest
@testable import DAQPal

@MainActor
final class RecordingSessionTests: XCTestCase {

    private let deviceID = UUID()

    private func result(timestamp: TimeInterval, accepted: Bool, value: Double = 12.347,
                        reason: RejectionReason? = nil) -> FrameResult {
        let measurement: Measurement
        if accepted {
            measurement = Measurement(timestamp: timestamp, value: value, unit: "V",
                                      confidence: 0.9, accepted: true)
        } else {
            measurement = Measurement.rejected(timestamp: timestamp, reason: reason ?? .displayLost,
                                               value: value, unit: "V", confidence: 0.1)
        }
        return FrameResult(timestamp: timestamp, readings: [deviceID: measurement], debugText: nil)
    }

    // MARK: - RecordingSession.append / counters

    func testAppend_incrementsAcceptedCount() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: true))
        session.append(result(timestamp: 0.1, accepted: true))
        XCTAssertEqual(session.acceptedCount, 2)
        XCTAssertEqual(session.rejectedCount, 0)
        XCTAssertEqual(session.sampleCount, 2)
    }

    func testAppend_incrementsRejectedCount() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: false, reason: .outOfRange))
        XCTAssertEqual(session.rejectedCount, 1)
        XCTAssertEqual(session.acceptedCount, 0)
    }

    func testAppend_tracksLastRejection() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: false, reason: .outOfRange))
        session.append(result(timestamp: 0.1, accepted: true))
        session.append(result(timestamp: 0.2, accepted: false, reason: .temporalInconsistency))
        XCTAssertEqual(session.lastRejection?.reason, .temporalInconsistency)
        XCTAssertEqual(session.lastRejection?.timestamp, 0.2)
    }

    func testElapsed_derivedFromMonotonicTimestamps() {
        let session = RecordingSession()
        XCTAssertEqual(session.elapsed, 0)
        session.append(result(timestamp: 10.0, accepted: true))
        session.append(result(timestamp: 12.5, accepted: true))
        XCTAssertEqual(session.elapsed, 2.5, accuracy: 1e-9)
    }

    // MARK: - recentAcceptedValues

    func testRecentAcceptedValues_oldestToNewestExcludingRejected() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: true, value: 1))
        session.append(result(timestamp: 0.1, accepted: false, value: 999, reason: .outOfRange))
        session.append(result(timestamp: 0.2, accepted: true, value: 2))
        session.append(result(timestamp: 0.3, accepted: true, value: 3))
        XCTAssertEqual(session.recentAcceptedValues(for: deviceID), [1, 2, 3])
    }

    func testRecentAcceptedValues_respectsLimit() {
        let session = RecordingSession()
        for i in 0..<10 {
            session.append(result(timestamp: Double(i) * 0.1, accepted: true, value: Double(i)))
        }
        let values = session.recentAcceptedValues(for: deviceID, limit: 3)
        XCTAssertEqual(values, [7, 8, 9])
    }

    func testRecentAcceptedValues_unknownDeviceIsEmpty() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: true))
        XCTAssertEqual(session.recentAcceptedValues(for: UUID()), [])
    }

    // MARK: - finish(devices:) -> CompletedSession

    func testFinish_producesConsistentSnapshot() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: true, value: 10))
        session.append(result(timestamp: 1, accepted: false, value: .nan, reason: .displayLost))
        session.append(result(timestamp: 2, accepted: true, value: 12))

        let device = Device.makeDefault(index: 1)
        let completed = session.finish(devices: [device])

        XCTAssertEqual(completed.id, session.id)
        XCTAssertEqual(completed.sampleCount, 3)
        XCTAssertEqual(completed.acceptedCount, 2)
        XCTAssertEqual(completed.rejectedCount, 1)
        XCTAssertEqual(completed.duration, 2, accuracy: 1e-9)
        XCTAssertEqual(completed.devices.map(\.id), [device.id])
    }

    // MARK: - CompletedSession derived stats

    func testCompletedSession_samplesPerSecond() {
        let session = RecordingSession()
        for i in 0..<5 {
            session.append(result(timestamp: Double(i), accepted: true))
        }
        let completed = session.finish(devices: [Device.makeDefault(index: 1)])
        // 5 samples over a 4s span.
        XCTAssertEqual(completed.samplesPerSecond, 5.0 / 4.0, accuracy: 1e-9)
    }

    func testCompletedSession_relativeTime() {
        let session = RecordingSession()
        session.append(result(timestamp: 100, accepted: true))
        session.append(result(timestamp: 103, accepted: true))
        let completed = session.finish(devices: [Device.makeDefault(index: 1)])
        XCTAssertEqual(completed.relativeTime(103), 3, accuracy: 1e-9)
    }

    func testCompletedSession_acceptedPointsExcludeRejectedAndNonFinite() {
        let session = RecordingSession()
        session.append(result(timestamp: 0, accepted: true, value: 5))
        session.append(result(timestamp: 1, accepted: false, value: .nan, reason: .displayLost))
        session.append(result(timestamp: 2, accepted: true, value: 7))
        let completed = session.finish(devices: [Device.makeDefault(index: 1)])
        let points = completed.acceptedPoints(for: deviceID)
        XCTAssertEqual(points.map(\.value), [5, 7])
        XCTAssertEqual(points.map(\.time), [0, 2])
    }

    func testCompletedSession_emptySessionHasZeroDuration() {
        let session = RecordingSession()
        let completed = session.finish(devices: [Device.makeDefault(index: 1)])
        XCTAssertEqual(completed.duration, 0)
        XCTAssertEqual(completed.samplesPerSecond, 0)
    }

    // MARK: - AppState.apply(_:) lock behavior

    func testAppState_acceptedReadingLocksDevice() {
        var device = Device.makeDefault(index: 1)
        device.roi = NormalizedROI.defaultROI
        let appState = AppState(devices: [device])

        appState.apply(result(timestamp: 0, accepted: true, value: 12.347))

        let reading = appState.liveReadings[device.id]
        XCTAssertEqual(reading?.locked, true)
        XCTAssertEqual(reading?.value, 12.347)
        XCTAssertEqual(reading?.accepted, true)
    }

    func testAppState_staleReadingUnlocksAfterLockTimeout() {
        var device = Device.makeDefault(index: 1)
        device.roi = NormalizedROI.defaultROI
        let appState = AppState(devices: [device])

        appState.apply(result(timestamp: 0, accepted: true, value: 12.347))
        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true)

        // A later frame with no reading at all for this device, beyond the
        // lock timeout, must unlock it and clear the displayed value.
        let laterTimestamp = AppState.lockTimeout + 0.5
        appState.apply(FrameResult(timestamp: laterTimestamp, readings: [:], debugText: nil))

        let reading = appState.liveReadings[device.id]
        XCTAssertEqual(reading?.locked, false)
        XCTAssertNil(reading?.value)
    }

    func testAppState_withinLockTimeoutStaysLocked() {
        var device = Device.makeDefault(index: 1)
        device.roi = NormalizedROI.defaultROI
        let appState = AppState(devices: [device])

        appState.apply(result(timestamp: 0, accepted: true, value: 12.347))
        // Well inside the lock timeout, even with no fresh reading.
        appState.apply(FrameResult(timestamp: AppState.lockTimeout * 0.5, readings: [:], debugText: nil))

        XCTAssertEqual(appState.liveReadings[device.id]?.locked, true)
        XCTAssertEqual(appState.liveReadings[device.id]?.value, 12.347)
    }

    func testAppState_deviceWithoutROIIsAlwaysEmpty() {
        let device = Device.makeDefault(index: 1) // roi == nil
        let appState = AppState(devices: [device])
        appState.apply(FrameResult(timestamp: 0, readings: [:], debugText: nil))
        XCTAssertEqual(appState.liveReadings[device.id], .empty)
    }
}
