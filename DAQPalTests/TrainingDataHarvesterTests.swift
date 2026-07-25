//
//  TrainingDataHarvesterTests.swift
//  DAQPalTests
//
//  Honesty note: like `SyntheticPipelineTests`, this exercises HARVESTER
//  WIRING (accept → stabilize → crop → label) against
//  `SyntheticDisplayRenderer`'s clearly-synthetic frames, not real-DMM
//  recognition accuracy. Every assertion that depends on Vision actually
//  reading text is gated on a probe pass first; when Vision produces no text
//  at all in this environment, the test skips rather than asserting a
//  fabricated pass. Assertions that don't depend on OCR quality (the
//  no-clobber file behavior) run unconditionally.
//

import CoreGraphics
import ImageIO
import XCTest
@testable import DAQPal

/// Minimal `FrameSource` wrapping a pre-built array of frames, so a test can
/// drive the exact same rendered frames through two independent pipeline runs
/// (an OCR-presence probe, then the harvester itself) deterministically —
/// no live pacing, no timing dependency.
private struct ArrayFrameSource: FrameSource {
    let frameList: [TimestampedFrame]

    func frames() -> AsyncStream<TimestampedFrame> {
        AsyncStream { continuation in
            for frame in frameList { continuation.yield(frame) }
            continuation.finish()
        }
    }
}

final class TrainingDataHarvesterTests: XCTestCase {
    private let sampleCount = 12
    private let frameInterval: TimeInterval = 1.0 / 12.0

    private func makeFrame(text: String, index: Int,
                           renderer: SyntheticDisplayRenderer) throws -> TimestampedFrame {
        guard let buffer = renderer.render(text: text) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: Double(index) * frameInterval)
    }

    private func makeTempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TrainingDataHarvesterTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Splits `labels.csv` into data rows, dropping the header line and any
    /// session-separator comment lines. No embedded-comma handling — this
    /// harvester only ever writes plain digit/decimal text in this suite.
    private func dataRows(in csv: String) -> [[String]] {
        csv.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.hasPrefix("#") && $0 != "filename,value,raw_text,confidence,timestamp" }
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    func testStableAcceptedReading_isHarvestedWithMatchingLabelAndCrop() async throws {
        let renderer = SyntheticDisplayRenderer()
        let device = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)

        // Probe pass on a throwaway processor: does Vision see ANY text on
        // these synthetic frames in this environment at all? If not, the
        // whole test is inconclusive about the harvester's own logic — skip
        // rather than fail (same guard as SyntheticPipelineTests).
        let probeProcessor = MeasurementProcessor()
        await probeProcessor.update(devices: [device])
        var sawAnyOCRText = false
        for i in 0..<sampleCount {
            let frame = try makeFrame(text: "12.347", index: i, renderer: renderer)
            let result = await probeProcessor.process(frame: frame)
            if result.readings[device.id]?.rawText != nil { sawAnyOCRText = true }
        }
        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }

        // The real run: a fresh processor, fresh frames, driven entirely by
        // the harvester. `minimumConfidence` is deliberately below the
        // ~0.6-0.9 range VisionOCR's `.accurate` level is documented to
        // produce on clean synthetic digits (see VisionOCR.swift) so this
        // test isn't brittle to exact calibration — it's testing the
        // harvester's plumbing, not claiming an accuracy number.
        let tempDir = makeTempDirectory()
        let harvester = TrainingDataHarvester(config: .init(outputDirectory: tempDir,
                                                             minimumConfidence: 0.5,
                                                             stabilityStreak: 3,
                                                             maxSamples: 100))
        let harvestProcessor = MeasurementProcessor()
        var frames: [TimestampedFrame] = []
        for i in 0..<sampleCount {
            frames.append(try makeFrame(text: "12.347", index: i, renderer: renderer))
        }
        let summary = try await harvester.harvest(source: ArrayFrameSource(frameList: frames),
                                                   device: device,
                                                   processor: harvestProcessor)

        XCTAssertEqual(summary.framesSeen, sampleCount)
        guard summary.samplesWritten > 0 else {
            return XCTFail("""
                expected at least one stable, accepted "12.347" reading to be harvested; \
                Vision did produce text on these frames (probe pass), so zero samples \
                indicates a harvester defect rather than an environment limitation
                """)
        }

        // labels.csv: header present, one data row per harvested sample, each
        // parseable and matching the rendered value.
        let csv = try String(contentsOf: summary.labelsFileURL, encoding: .utf8)
        XCTAssertTrue(csv.hasPrefix("filename,value,raw_text,confidence,timestamp\n"))
        let rows = dataRows(in: csv)
        XCTAssertEqual(rows.count, summary.samplesWritten)

        let expectedCropRect = SyntheticDisplayRenderer.displayROI.clamped()
            .pixelRect(in: CGSize(width: 1080, height: 1920))

        for row in rows {
            XCTAssertEqual(row.count, 5, "expected filename,value,raw_text,confidence,timestamp")
            let filename = row[0]
            guard let value = Double(row[1]) else {
                return XCTFail("labels.csv value field \"\(row[1])\" did not parse as a Double")
            }
            XCTAssertEqual(value, 12.347, accuracy: 0.001)
            guard let confidence = Float(row[3]) else {
                return XCTFail("labels.csv confidence field \"\(row[3])\" did not parse as a Float")
            }
            XCTAssertGreaterThanOrEqual(confidence, 0.5)
            XCTAssertNotNil(TimeInterval(row[4]), "timestamp field should parse")

            // The crop file exists and decodes as a PNG sized like the ROI.
            let cropURL = summary.cropsDirectoryURL.appendingPathComponent(filename)
            guard let imageSource = CGImageSourceCreateWithURL(cropURL as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                return XCTFail("crop \(filename) is not a decodable image")
            }
            XCTAssertEqual(width, Int(expectedCropRect.width))
            XCTAssertEqual(height, Int(expectedCropRect.height))
        }
    }

    func testGarbageSource_yieldsZeroSamples() async throws {
        let renderer = SyntheticDisplayRenderer()
        let device = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        // A blank panel (no text drawn) never yields an OCR candidate, so
        // this assertion holds deterministically regardless of Vision's
        // behavior on rendered synthetic digits elsewhere in this suite.
        var frames: [TimestampedFrame] = []
        for i in 0..<5 {
            frames.append(try makeFrame(text: "", index: i, renderer: renderer))
        }

        let tempDir = makeTempDirectory()
        let harvester = TrainingDataHarvester(config: .init(outputDirectory: tempDir))
        let processor = MeasurementProcessor()
        let summary = try await harvester.harvest(source: ArrayFrameSource(frameList: frames),
                                                   device: device,
                                                   processor: processor)

        XCTAssertEqual(summary.framesSeen, 5)
        XCTAssertEqual(summary.samplesWritten, 0)
    }

    func testHarvest_neverOverwritesExistingLabelsCSV() async throws {
        // Deterministic, no OCR dependency: seed labels.csv with prior
        // "session" content, run a harvest that itself yields nothing new,
        // and confirm the prior rows are preserved verbatim rather than
        // truncated.
        let tempDir = makeTempDirectory()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let labelsURL = tempDir.appendingPathComponent("labels.csv")
        let seeded = "filename,value,raw_text,confidence,timestamp\n"
            + "sample_000000_0ms.png,1.000000,1.000,0.9000,0.000000\n"
        try seeded.write(to: labelsURL, atomically: true, encoding: .utf8)

        let renderer = SyntheticDisplayRenderer()
        let device = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        let frame = try makeFrame(text: "", index: 0, renderer: renderer)
        let harvester = TrainingDataHarvester(config: .init(outputDirectory: tempDir))
        let processor = MeasurementProcessor()
        _ = try await harvester.harvest(source: ArrayFrameSource(frameList: [frame]),
                                        device: device,
                                        processor: processor)

        let after = try String(contentsOf: labelsURL, encoding: .utf8)
        XCTAssertTrue(after.hasPrefix(seeded), "existing labeled rows must be preserved, not overwritten")
        XCTAssertGreaterThan(after.count, seeded.count,
                             "a session separator should be appended even when no new rows are written")
    }
}
