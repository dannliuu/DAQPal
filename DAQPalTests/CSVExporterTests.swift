//
//  CSVExporterTests.swift
//  DAQPalTests
//
//  Golden-string coverage for `CSVExporter`, built directly from
//  `CSVExporter.swift`'s documented field order/rounding rather than assumed
//  from the spec prose, per the "ui-results" agent's handoff note.
//

import Foundation
import XCTest
@testable import DAQPal

final class CSVExporterTests: XCTestCase {

    // MARK: - Single-device schema

    func testSingleDevice_goldenString() {
        let device = Device(id: UUID(), name: "DMM-1", model: "",
                            displayFormat: DisplayFormat(digitCount: 5, decimalPosition: 2,
                                                         signAllowed: true, unit: "V",
                                                         minimumValue: -20, maximumValue: 20),
                            roi: nil)

        let accepted = Measurement(timestamp: 100.0, value: 12.347, unit: "V",
                                   confidence: 0.913, accepted: true)
        let rejected = Measurement.rejected(timestamp: 100.5, reason: .outOfRange,
                                            value: .nan, unit: "V", confidence: 0)

        let samples = [
            RecordingSample(timestamp: 100.0, readings: [device.id: accepted]),
            RecordingSample(timestamp: 100.5, readings: [device.id: rejected]),
            // No reading at all for the device on this frame.
            RecordingSample(timestamp: 101.0, readings: [:]),
        ]
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [device], samples: samples,
                                       firstTimestamp: 100.0, lastTimestamp: 101.0)

        let expected = """
        timestamp,value,unit,confidence,accepted,rejection_reason
        0.000,12.347,V,0.913,true,
        0.500,,V,0.000,false,OUT_OF_RANGE
        1.000,,,,false,

        """
        XCTAssertEqual(CSVExporter.csvString(for: session), expected)
    }

    func testSingleDevice_valueOmittedWhenNonFinite() {
        let device = Device.makeDefault(index: 1)
        let m = Measurement.rejected(timestamp: 0, reason: .displayLost)
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [device],
                                       samples: [RecordingSample(timestamp: 0, readings: [device.id: m])],
                                       firstTimestamp: 0, lastTimestamp: 0)
        let csv = CSVExporter.csvString(for: session)
        let dataRow = csv.split(separator: "\n")[1]
        // "timestamp,value,unit,confidence,accepted,rejection_reason" ->
        // value column must be empty for a NaN reading.
        let fields = dataRow.split(separator: ",", omittingEmptySubsequences: false)
        XCTAssertEqual(fields[1], "")
    }

    // MARK: - Multi-device schema

    func testMultiDevice_goldenString() {
        var device1 = Device.makeDefault(index: 1) // name "DMM-1" -> prefix "dmm1"
        device1.displayFormat = DisplayFormat(digitCount: 5, decimalPosition: 2,
                                              signAllowed: true, unit: "V",
                                              minimumValue: -20, maximumValue: 20)
        var device2 = Device.makeDefault(index: 2) // name "DMM-2" -> prefix "dmm2"
        device2.displayFormat = DisplayFormat(digitCount: 4, decimalPosition: 1,
                                              signAllowed: false, unit: "Ω",
                                              minimumValue: 0, maximumValue: 1000)

        XCTAssertEqual(device1.columnPrefix, "dmm1")
        XCTAssertEqual(device2.columnPrefix, "dmm2")

        let m1 = Measurement(timestamp: 100.0, value: 12.347, unit: "V", confidence: 0.913, accepted: true)
        let m2 = Measurement.rejected(timestamp: 100.5, reason: .lowOCRConfidence, value: .nan,
                                      unit: "Ω", confidence: 0.1)
        let m2b = Measurement(timestamp: 100.5, value: 1.234, unit: "Ω", confidence: 0.75, accepted: true)

        let samples = [
            // Row 1: device1 accepted, device2 missing entirely.
            RecordingSample(timestamp: 100.0, readings: [device1.id: m1]),
            // Row 2: device1 missing, device2 accepted.
            RecordingSample(timestamp: 100.5, readings: [device2.id: m2b]),
        ]
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [device1, device2], samples: samples,
                                       firstTimestamp: 100.0, lastTimestamp: 100.5)

        let expected = """
        timestamp_s,dmm1_value_V,dmm1_confidence,dmm1_valid,dmm2_value_ohm,dmm2_confidence,dmm2_valid
        0.000,12.347,0.913,1,,,0
        0.500,,,0,1.234,0.750,1

        """
        XCTAssertEqual(CSVExporter.csvString(for: session), expected)
        _ = m2 // silence unused-immutable warning; kept to document the rejected-value shape.
    }

    func testMultiDevice_rejectedRowLogsValueButValidZero() {
        var device1 = Device.makeDefault(index: 1)
        device1.displayFormat = DisplayFormat(digitCount: 5, decimalPosition: 2, signAllowed: true,
                                              unit: "V", minimumValue: -20, maximumValue: 20)
        var device2 = Device.makeDefault(index: 2)
        device2.displayFormat = .defaultDMM

        // Rejected reading with a finite value must still log the value
        // (never silently dropped) but with valid=0.
        let rejectedButFinite = Measurement(timestamp: 0, value: 99.999, unit: "V",
                                            confidence: 0.4, accepted: false,
                                            rejectionReason: .outOfRange)
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [device1, device2],
                                       samples: [RecordingSample(timestamp: 0,
                                                                 readings: [device1.id: rejectedButFinite])],
                                       firstTimestamp: 0, lastTimestamp: 0)
        let csv = CSVExporter.csvString(for: session)
        let dataRow = csv.split(separator: "\n")[1]
        let fields = dataRow.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        // timestamp_s, dmm1_value_V, dmm1_confidence, dmm1_valid, dmm2_value_V, dmm2_confidence, dmm2_valid
        XCTAssertEqual(fields[1], "99.999")
        XCTAssertEqual(fields[3], "0")
        XCTAssertEqual(fields[4], "") // device2 had no reading at all this row
        XCTAssertEqual(fields[6], "0")
    }

    func testUnitSanitization_ohmAndDegreesC() {
        var ohmDevice = Device.makeDefault(index: 1)
        ohmDevice.displayFormat = DisplayFormat(digitCount: 4, decimalPosition: 1, signAllowed: false,
                                                unit: "Ω", minimumValue: nil, maximumValue: nil)
        var celsiusDevice = Device.makeDefault(index: 2)
        celsiusDevice.displayFormat = DisplayFormat(digitCount: 4, decimalPosition: 1, signAllowed: false,
                                                    unit: "°C", minimumValue: nil, maximumValue: nil)
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [ohmDevice, celsiusDevice], samples: [],
                                       firstTimestamp: nil, lastTimestamp: nil)
        let header = CSVExporter.csvString(for: session).split(separator: "\n").first!
        XCTAssertTrue(header.contains("_value_ohm"))
        XCTAssertTrue(header.contains("_value_degC"))
    }

    // MARK: - File export

    func testFileName() {
        XCTAssertEqual(CSVExporter.fileName, "daqpal_session.csv")
    }

    func testExportFile_writesReadableFileMatchingCSVString() throws {
        let device = Device.makeDefault(index: 1)
        let m = Measurement(timestamp: 0, value: 1, unit: device.unit, confidence: 1, accepted: true)
        let session = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                       devices: [device],
                                       samples: [RecordingSample(timestamp: 0, readings: [device.id: m])],
                                       firstTimestamp: 0, lastTimestamp: 0)
        let url = try CSVExporter.exportFile(for: session)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "daqpal_session.csv")
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, CSVExporter.csvString(for: session))
    }

    func testExportFile_overwritesPreviousExport() throws {
        let deviceA = Device.makeDefault(index: 1)
        let sessionA = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                        devices: [deviceA], samples: [],
                                        firstTimestamp: nil, lastTimestamp: nil)
        let urlA = try CSVExporter.exportFile(for: sessionA)

        let deviceB = Device.makeDefault(index: 1)
        let mB = Measurement(timestamp: 0, value: 5, unit: deviceB.unit, confidence: 1, accepted: true)
        let sessionB = CompletedSession(id: UUID(), startedAt: Date(), endedAt: Date(),
                                        devices: [deviceB],
                                        samples: [RecordingSample(timestamp: 0, readings: [deviceB.id: mB])],
                                        firstTimestamp: 0, lastTimestamp: 0)
        let urlB = try CSVExporter.exportFile(for: sessionB)
        defer { try? FileManager.default.removeItem(at: urlB) }

        XCTAssertEqual(urlA, urlB)
        let written = try String(contentsOf: urlB, encoding: .utf8)
        XCTAssertEqual(written, CSVExporter.csvString(for: sessionB))
    }
}
