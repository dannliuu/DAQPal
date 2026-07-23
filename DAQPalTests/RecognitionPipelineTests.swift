//
//  RecognitionPipelineTests.swift
//  DAQPalTests
//
//  Spec §40.3 fixture harness: drives `MeasurementProcessor` against a real
//  recorded DMM video (`Fixtures/dmm_001.mov`) and its ground-truth CSV
//  (`Fixtures/dmm_001.csv`), with NO camera, NO Simulator camera access, and
//  NO GUI automation. See `Fixtures/README.md` for the fixture format and how
//  to record one.
//
//  No fixture ships with this repository yet, so this test `XCTSkip`s until
//  one is added — it asserts nothing fabricated in the meantime, per the
//  project's honesty rules (no accuracy claims without real data).
//

import XCTest
@testable import DAQPal

final class RecognitionPipelineTests: XCTestCase {

    private static let fixtureName = "dmm_001"

    /// Ground-truth row: relative seconds + expected display value.
    private struct GroundTruthRow {
        let timestamp: TimeInterval
        let value: Double
    }

    private func fixtureURL(extension ext: String) -> URL? {
        let bundle = Bundle(for: RecognitionPipelineTests.self)
        // Filesystem-synchronized groups may or may not preserve the
        // "Fixtures" subdirectory inside the test bundle depending on how
        // Xcode packages folder references vs. groups — try both.
        return bundle.url(forResource: Self.fixtureName, withExtension: ext, subdirectory: "Fixtures")
            ?? bundle.url(forResource: Self.fixtureName, withExtension: ext)
    }

    /// Parses `timestamp,value` rows. Any header line (non-numeric first
    /// column) is naturally skipped since it fails the `Double(...)` parse.
    private func parseGroundTruth(_ text: String) -> [GroundTruthRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let columns = line.split(separator: ",")
            guard columns.count >= 2,
                  let timestamp = Double(columns[0].trimmingCharacters(in: .whitespaces)),
                  let value = Double(columns[1].trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return GroundTruthRow(timestamp: timestamp, value: value)
        }
    }

    func testStableVoltageReading() async throws {
        guard let videoURL = fixtureURL(extension: "mov"),
              let csvURL = fixtureURL(extension: "csv") else {
            throw XCTSkip("""
                Fixture \(Self.fixtureName).mov not present — record a real DMM fixture \
                per DAQPalTests/Fixtures/README.md
                """)
        }

        let groundTruth = parseGroundTruth(try String(contentsOf: csvURL, encoding: .utf8))
        guard !groundTruth.isEmpty else {
            throw XCTSkip("\(Self.fixtureName).csv contained no parseable ground-truth rows")
        }

        // NOTE: once a real fixture is recorded, replace this placeholder ROI
        // with the fixture's actual display location (spec §40.5 step 24
        // still leaves ROI discovery manual for the MVP). Kept generous and
        // centered so the loop below is exercised end-to-end the day a
        // fixture lands, per the contract's "runs the day a fixture lands"
        // requirement.
        let knownROI = NormalizedROI.defaultROI
        let format = DisplayFormat.defaultDMM

        let fixture = FixtureFrameSource(videoURL: videoURL, realTimePacing: false)
        let processor = MeasurementProcessor()
        let deviceID = UUID()
        await processor.update(devices: [DeviceRecognitionConfig(id: deviceID, roi: knownROI, format: format)])

        // `DAQPal.`-qualified: a bare `Measurement` type annotation is
        // ambiguous with `Foundation.Measurement<UnitType>`, which is
        // visible here even without an explicit `import Foundation`.
        var results: [DAQPal.Measurement] = []
        for await frame in fixture.frames() {
            let frameResult = await processor.process(frame: frame)
            if let measurement = frameResult.readings[deviceID] {
                results.append(measurement)
            }
        }

        guard !results.isEmpty else {
            throw XCTSkip("FixtureFrameSource produced no frames from \(Self.fixtureName).mov")
        }

        let accepted = results.filter(\.accepted)
        let acceptanceRate = Double(accepted.count) / Double(results.count)
        XCTAssertGreaterThan(acceptanceRate, 0.8,
                             "acceptance rate \(acceptanceRate) too low against \(Self.fixtureName) ground truth")

        // Match each accepted reading to the nearest ground-truth row (by
        // timestamp) and check value accuracy. Tolerance is intentionally
        // generous (format-level, not sub-digit) until a real fixture
        // establishes an actual accuracy baseline.
        var errors: [Double] = []
        for measurement in accepted {
            guard let nearest = groundTruth.min(by: {
                abs($0.timestamp - measurement.timestamp) < abs($1.timestamp - measurement.timestamp)
            }) else { continue }
            errors.append(abs(measurement.value - nearest.value))
        }
        guard !errors.isEmpty else {
            return XCTFail("no accepted readings could be matched to a ground-truth timestamp")
        }
        let meanAbsoluteError = errors.reduce(0, +) / Double(errors.count)
        XCTAssertLessThan(meanAbsoluteError, 0.05,
                          "mean |value - ground truth| \(meanAbsoluteError) exceeds tolerance")
    }

    func testGarbageFrameIsRejected() async throws {
        // A second fixture with an injected out-of-range/garbage frame, per
        // spec step 32. Optional: only runs if provided.
        let bundle = Bundle(for: RecognitionPipelineTests.self)
        let garbageName = "dmm_001_garbage"
        guard let videoURL = bundle.url(forResource: garbageName, withExtension: "mov", subdirectory: "Fixtures")
            ?? bundle.url(forResource: garbageName, withExtension: "mov") else {
            throw XCTSkip("Fixture \(garbageName).mov not present — optional per Fixtures/README.md")
        }

        let fixture = FixtureFrameSource(videoURL: videoURL, realTimePacing: false)
        let processor = MeasurementProcessor()
        let deviceID = UUID()
        await processor.update(devices: [DeviceRecognitionConfig(id: deviceID, roi: NormalizedROI.defaultROI,
                                                                  format: .defaultDMM)])

        var sawRejection = false
        for await frame in fixture.frames() {
            let result = await processor.process(frame: frame)
            if let measurement = result.readings[deviceID], !measurement.accepted {
                sawRejection = true
            }
        }
        XCTAssertTrue(sawRejection, "the garbage-frame fixture should produce at least one rejected reading")
    }
}
