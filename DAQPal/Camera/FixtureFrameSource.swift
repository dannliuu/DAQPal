//
//  FixtureFrameSource.swift
//  DAQPal
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Reads a bundled video fixture frame-by-frame via `AVAssetReader`
/// (spec §40.3 fixture harness: `dmm_001.mov` + ground-truth CSV). No camera
/// or UI dependency, so recognition/validation are testable without hardware
/// or GUI automation — the same `MeasurementProcessor` consumes the identical
/// `TimestampedFrame` type as the live path.
///
/// `@unchecked Sendable` justification: the only mutable state is the local
/// `AVAssetReader` object graph created and owned exclusively inside the
/// single `Task` spawned by `frames()`; no other code ever touches it.
final class FixtureFrameSource: FrameSource, @unchecked Sendable {

    private let videoURL: URL
    private let realTimePacing: Bool

    /// - Parameters:
    ///   - videoURL: Location of the fixture video (e.g. `dmm_001.mov`).
    ///   - realTimePacing: When `true`, frames are yielded spaced by their
    ///     original presentation-time deltas (via `Task.sleep`), emulating
    ///     live capture. When `false` (default — what tests use), frames are
    ///     yielded as fast as they can be decoded.
    init(videoURL: URL, realTimePacing: Bool = false) {
        self.videoURL = videoURL
        self.realTimePacing = realTimePacing
    }

    func frames() -> AsyncStream<TimestampedFrame> {
        let videoURL = self.videoURL
        let realTimePacing = self.realTimePacing
        return AsyncStream { continuation in
            let task = Task {
                await Self.pump(videoURL: videoURL, realTimePacing: realTimePacing, continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Runs entirely on a background `Task`; touches no shared/main state.
    private static func pump(videoURL: URL,
                             realTimePacing: Bool,
                             continuation: AsyncStream<TimestampedFrame>.Continuation) async {
        let asset = AVURLAsset(url: videoURL)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return }

            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return }
            reader.add(output)
            guard reader.startReading() else { return }

            var previousPTS: TimeInterval?
            while !Task.isCancelled, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

                if realTimePacing, let previousPTS {
                    let delta = pts - previousPTS
                    if delta > 0 {
                        try? await Task.sleep(for: .seconds(delta))
                    }
                }
                previousPTS = pts

                continuation.yield(TimestampedFrame(pixelBuffer: pixelBuffer, timestamp: pts))
            }
        } catch {
            // Fixture missing/unreadable: the stream simply ends with no
            // frames. Tests treat an empty run as "no data" and `XCTSkip`
            // rather than asserting a fabricated pass.
        }
    }
}
