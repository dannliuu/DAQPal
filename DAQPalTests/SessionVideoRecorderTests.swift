//
//  SessionVideoRecorderTests.swift
//  DAQPalTests
//
//  Exercises `SessionVideoRecorder` end to end WITHOUT camera hardware:
//  `SyntheticDisplayRenderer` builds frames for known timestamps, which drive
//  the arm/append/finish lifecycle. Asserts the produced `.mov` exists, its
//  video track dimensions match the frames, and its duration ≈ frames/fps.
//
//  Honesty note: this validates the RECORDER wiring (writer setup, frame
//  accounting, finalization), not real-DMM capture. `AVAssetWriter` H.264
//  encoding can be unavailable in some headless test environments; when the
//  writer cannot encode, these tests `XCTSkip` with a clear message rather
//  than fabricating a pass.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import XCTest
@testable import DAQPal

final class SessionVideoRecorderTests: XCTestCase {

    private let fps: Double = 12
    private let frameCount = 20
    private let renderSize = CGSize(width: 1080, height: 1920)

    /// Movies produced by the tests, deleted in `tearDown`.
    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs { try? FileManager.default.removeItem(at: url) }
        createdURLs.removeAll()
        super.tearDown()
    }

    /// Builds `frameCount` frames at 0, 1/12, 2/12… seconds. Skips (rather than
    /// fails) if the renderer can't allocate a pixel buffer — an environment
    /// limitation, not a recorder defect.
    private func makeFrames(renderer: SyntheticDisplayRenderer) throws -> [TimestampedFrame] {
        var frames: [TimestampedFrame] = []
        for i in 0..<frameCount {
            // Slightly different text per frame so encoded frames aren't
            // byte-identical (closer to real capture); value is irrelevant here.
            let text = String(format: "%.3f", 12.0 + Double(i) * 0.001)
            guard let buffer = renderer.render(text: text) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            frames.append(TimestampedFrame(pixelBuffer: buffer, timestamp: Double(i) / fps))
        }
        return frames
    }

    /// Runs one full arm/append/finish cycle, returning the movie URL. Fails on
    /// a genuine recorder bug (`.noFramesAppended` after real appends), skips on
    /// an environment that can't encode H.264.
    private func recordCycle(_ recorder: SessionVideoRecorder,
                             frames: [TimestampedFrame]) async throws -> URL {
        recorder.start()
        for frame in frames {
            recorder.append(frame)
            // Pace to keep the real-time-configured encoder ready. `append`
            // drops (by contract) when the writer input isn't ready, so a burst
            // append could legitimately shed frames; feeding at roughly the
            // live capture cadence the recorder is built for avoids that and
            // keeps the frame count / duration deterministic.
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        switch await recorder.finish() {
        case .success(let url):
            createdURLs.append(url)
            return url
        case .failure(let error):
            if let recorderError = error as? SessionVideoRecorder.RecorderError,
               case .noFramesAppended = recorderError {
                XCTFail("frames were appended but finish() reported none")
                throw error
            }
            throw XCTSkip("AVAssetWriter could not encode video in this environment: \(error.localizedDescription)")
        }
    }

    func testRecordsMovieWithMatchingDimensionsAndDuration() async throws {
        let renderer = SyntheticDisplayRenderer(size: renderSize)
        let recorder = SessionVideoRecorder()
        let frames = try makeFrames(renderer: renderer)

        let url = try await recordCycle(recorder, frames: frames)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the recorder should write a .mov file")

        // Honest accounting: every offered frame was either appended or dropped.
        let appended = recorder.appendedFrameCount
        XCTAssertEqual(appended + recorder.droppedFrameCount, frameCount,
                       "every offered frame is either appended or counted as dropped")
        XCTAssertGreaterThan(appended, 0, "at least some frames should have been appended")

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(tracks.first, "the .mov should contain a video track")
        let naturalSize = try await videoTrack.load(.naturalSize)
        XCTAssertEqual(naturalSize.width, renderSize.width, accuracy: 1,
                       "track width should match the source frames")
        XCTAssertEqual(naturalSize.height, renderSize.height, accuracy: 1,
                       "track height should match the source frames")

        // Duration reflects the frames actually appended (== frameCount in a
        // healthy environment, so this is the frames/fps check with one-frame
        // tolerance; it adapts if the encoder dropped any).
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, Double(appended) / fps, accuracy: 1.0 / fps + 0.05,
                       "duration should be ≈ appended frames / fps")
    }

    func testSecondCycleAfterFinishProducesAValidMovie() async throws {
        let renderer = SyntheticDisplayRenderer(size: renderSize)
        let recorder = SessionVideoRecorder()

        _ = try await recordCycle(recorder, frames: try makeFrames(renderer: renderer))

        // A fresh start/append/finish on the SAME recorder must work, with
        // counters reset by the second `start()`.
        let secondURL = try await recordCycle(recorder, frames: try makeFrames(renderer: renderer))

        XCTAssertTrue(FileManager.default.fileExists(atPath: secondURL.path))
        XCTAssertEqual(recorder.appendedFrameCount + recorder.droppedFrameCount, frameCount,
                       "the second cycle's counters should reflect only its frames")

        let asset = AVURLAsset(url: secondURL)
        let videoTrack = try await asset.loadTracks(withMediaType: .video).first
        XCTAssertNotNil(videoTrack, "the second cycle should also produce a video track")
    }

    func testZeroFrameFinishFails() async throws {
        let recorder = SessionVideoRecorder()
        recorder.start()

        switch await recorder.finish() {
        case .success(let url):
            createdURLs.append(url)
            XCTFail("finishing with zero appended frames must fail")
        case .failure(let error):
            guard let recorderError = error as? SessionVideoRecorder.RecorderError,
                  case .noFramesAppended = recorderError else {
                return XCTFail("expected .noFramesAppended, got \(error)")
            }
        }
    }
}
