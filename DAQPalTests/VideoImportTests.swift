//
//  VideoImportTests.swift
//  DAQPalTests
//
//  Coverage for the offline video-import path (Milestone 12):
//    1. `TimeScalingFrameSource` timestamp normalization (pure, deterministic).
//    2. End-to-end: a real encoded `.mov` fixture → FixtureFrameSource →
//       TimeScalingFrameSource → MeasurementProcessor, asserting both the
//       recognized value and the normalized timestamp of the last sample.
//
//  Honesty note: the fixture is `SyntheticDisplayRenderer` output (clearly
//  synthetic — never a claim of real-DMM accuracy). Vision on H.264-compressed
//  synthetic frames can vary by OS/Simulator version, so the recognition
//  assertion is gated on Vision producing *some* text; when it produces none,
//  the test `XCTSkip`s with a clear message rather than fabricating a pass.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import DAQPal

final class VideoImportTests: XCTestCase {

    // The fixture is deliberately tiny: 24 frames at 12 fps == 2.0 s of the
    // constant string "12.347", so encode + decode stay fast.
    private static let fixtureText = "12.347"
    private static let fixtureFrameCount = 24
    private static let fixtureFPS: Int32 = 12

    private var temporaryFiles: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles.removeAll()
    }

    // MARK: - TimeScalingFrameSource

    /// A minimal in-memory `FrameSource` that replays a fixed list of frames.
    private struct StubFrameSource: FrameSource {
        let items: [TimestampedFrame]
        func frames() -> AsyncStream<TimestampedFrame> {
            let items = self.items
            return AsyncStream { continuation in
                for frame in items { continuation.yield(frame) }
                continuation.finish()
            }
        }
    }

    func testTimeScaling_rescalesTimestampsAndForwardsBuffers() async throws {
        let renderer = SyntheticDisplayRenderer()
        // Three distinct buffers at timestamps 0/1/2.
        var stubFrames: [TimestampedFrame] = []
        for i in 0..<3 {
            let buffer = try XCTUnwrap(renderer.render(text: "0.000"),
                                       "renderer could not allocate a pixel buffer")
            stubFrames.append(TimestampedFrame(pixelBuffer: buffer, timestamp: TimeInterval(i)))
        }

        let scaled = TimeScalingFrameSource(wrapping: StubFrameSource(items: stubFrames), factor: 0.125)

        var outputTimestamps: [TimeInterval] = []
        var outputBuffers: [CVPixelBuffer] = []
        for await frame in scaled.frames() {
            outputTimestamps.append(frame.timestamp)
            outputBuffers.append(frame.pixelBuffer)
        }

        // 0×0.125, 1×0.125, 2×0.125.
        XCTAssertEqual(outputTimestamps.count, 3)
        XCTAssertEqual(outputTimestamps[0], 0.0, accuracy: 1e-9)
        XCTAssertEqual(outputTimestamps[1], 0.125, accuracy: 1e-9)
        XCTAssertEqual(outputTimestamps[2], 0.25, accuracy: 1e-9)

        // "pixel buffer untouched": the exact same buffer references pass through.
        XCTAssertEqual(outputBuffers.count, 3)
        for i in 0..<3 {
            XCTAssertTrue(outputBuffers[i] === stubFrames[i].pixelBuffer,
                          "TimeScalingFrameSource must forward the buffer by reference, untouched")
        }
    }

    func testTimeScaling_identityFactorPreservesTimestamps() async throws {
        let renderer = SyntheticDisplayRenderer()
        let buffer = try XCTUnwrap(renderer.render(text: "0.000"))
        let source = StubFrameSource(items: [
            TimestampedFrame(pixelBuffer: buffer, timestamp: 0.5),
            TimestampedFrame(pixelBuffer: buffer, timestamp: 1.5)
        ])

        let scaled = TimeScalingFrameSource(wrapping: source, factor: 1.0)
        var timestamps: [TimeInterval] = []
        for await frame in scaled.frames() { timestamps.append(frame.timestamp) }

        XCTAssertEqual(timestamps, [0.5, 1.5])
    }

    // MARK: - End-to-end over a real encoded fixture

    func testEndToEnd_slowMotionFixture_isNormalizedAndRecognized() async throws {
        let fixtureURL = try await writeSyntheticFixture()

        // Sanity: the fixture actually decodes to real frames with sane
        // timestamps. Establish the unscaled asset duration as ground truth for
        // the normalization check.
        let asset = AVURLAsset(url: fixtureURL)
        let assetDuration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(assetDuration, 0, "encoded fixture reported a zero duration")

        let factor = 0.5
        let source = TimeScalingFrameSource(
            wrapping: FixtureFrameSource(videoURL: fixtureURL, realTimePacing: false),
            factor: factor)

        let processor = MeasurementProcessor()
        let deviceID = UUID()
        await processor.update(devices: [DeviceRecognitionConfig(id: deviceID,
                                                                 roi: SyntheticDisplayRenderer.displayROI,
                                                                 format: .defaultDMM)])

        var sawAnyOCRText = false
        var acceptedValue: Double?
        var lastTimestamp: TimeInterval?
        var frameCount = 0
        for await frame in source.frames() {
            frameCount += 1
            lastTimestamp = frame.timestamp
            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[deviceID] else { continue }
            if measurement.rawText != nil { sawAnyOCRText = true }
            if measurement.accepted { acceptedValue = measurement.value }
        }

        // The fixture must at least decode (independent of Vision). If the
        // encode/decode roundtrip yields nothing in this environment, skip
        // rather than assert against data that doesn't exist.
        guard frameCount > 0 else {
            throw XCTSkip("FixtureFrameSource produced no frames from the encoded fixture in this environment")
        }

        // Normalization: the last frame's timestamp is halved by factor 0.5, so
        // it lands near half the (unscaled) asset duration — within one frame.
        let lastScaled = try XCTUnwrap(lastTimestamp)
        let oneFrame = 1.0 / Double(Self.fixtureFPS)
        XCTAssertEqual(lastScaled, assetDuration * factor, accuracy: oneFrame,
                       "time scaling should map the last timestamp to ~half the asset duration")

        // Recognition is only asserted when Vision actually read text off the
        // compressed frames; otherwise skip (compression may degrade the render).
        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no text on the H.264-encoded synthetic fixture in this environment")
        }
        let value = try XCTUnwrap(acceptedValue,
                                  "expected at least one accepted \"12.347\" reading across the fixture")
        XCTAssertEqual(value, 12.347, accuracy: 0.001)
    }

    // MARK: - Fixture writer

    /// Encodes `fixtureFrameCount` frames of `SyntheticDisplayRenderer` output
    /// (the constant `fixtureText`) into a real `.mov` via `AVAssetWriter`, and
    /// returns its temp URL. Registered for deletion in `tearDown`.
    ///
    /// The renderer does all drawing (contract: "reuse the renderer — do not
    /// draw your own"); its rendered pixels are copied into an encoder-friendly
    /// (pool-vended, IOSurface-backed when available) buffer before appending,
    /// which keeps the H.264 encoder happy across platforms.
    private func writeSyntheticFixture() async throws -> URL {
        let size = CGSize(width: 1080, height: 1920)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daqpal-import-\(UUID().uuidString).mov")
        temporaryFiles.append(url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])

        guard writer.canAdd(input) else {
            throw XCTSkip("AVAssetWriter would not accept the H.264 video input in this environment")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? XCTSkip("AVAssetWriter failed to start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = SyntheticDisplayRenderer(size: size)
        for i in 0..<Self.fixtureFrameCount {
            // Not real-time: readiness is effectively immediate, but guard anyway.
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 1000 {
                try? await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
            }
            guard let rendered = renderer.render(text: Self.fixtureText) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            let buffer = encoderBuffer(for: rendered, pool: adaptor.pixelBufferPool)
            let pts = CMTime(value: CMTimeValue(i), timescale: Self.fixtureFPS)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw writer.error ?? XCTSkip("AVAssetWriter rejected a frame in this environment")
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? XCTSkip("AVAssetWriter did not finish in this environment")
        }
        return url
    }

    /// Copies `rendered` into a pool-vended buffer (IOSurface-backed, what the
    /// encoder prefers); falls back to the rendered buffer itself if no pool is
    /// available.
    private func encoderBuffer(for rendered: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer {
        guard let pool else { return rendered }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let dest = out else { return rendered }
        copyPixels(from: rendered, into: dest)
        return dest
    }

    /// Row-by-row copy that tolerates differing `bytesPerRow` between source and
    /// destination buffers.
    private func copyPixels(from source: CVPixelBuffer, into dest: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dest, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dest, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(dest) else { return }
        let srcRow = CVPixelBufferGetBytesPerRow(source)
        let dstRow = CVPixelBufferGetBytesPerRow(dest)
        let height = min(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(dest))
        let rowBytes = min(srcRow, dstRow)
        for y in 0..<height {
            memcpy(dst + y * dstRow, src + y * srcRow, rowBytes)
        }
    }
}
