//
//  VideoImportModel.swift
//  DAQPal
//
//  Offline video-import path (Milestone 12). A recorded instrument-display
//  video — normal speed OR slow-motion — is processed through the *same*
//  recognition/validation pipeline the live camera uses, producing a normal
//  `CompletedSession` (results screen + CSV come for free).
//
//  Two pieces live here:
//    1. `TimeScalingFrameSource` — the slow-motion normalization seam.
//    2. `VideoImportModel` — drives metadata load → ROI/speed configuration →
//       background processing → results, entirely off the live camera pipeline.
//

import AVFoundation
import CoreGraphics
import Foundation
import Observation
import UIKit

// MARK: - Slow-motion normalization seam

/// Wraps any `FrameSource` and rescales each frame's timestamp by a constant
/// `factor`, leaving the pixel buffer untouched.
///
/// This is the single point where slow-motion video is normalized back to real
/// capture time. A phone that bakes 120 fps into a 30 fps container stretches
/// one real second across four playback seconds; multiplying every asset
/// presentation timestamp by `0.25` restores real elapsed time so downstream
/// timestamps (and therefore samples/second, graph x-axis and CSV
/// `timestamp_s`) reflect what actually happened in front of the instrument.
/// `factor == 1.0` is the identity transform (normal-speed footage, or a raw
/// high-frame-rate recording whose timestamps are already real time).
///
/// Frame count is unaffected — every decoded frame is still processed; only the
/// timestamp label changes. A positive `factor` preserves monotonicity.
struct TimeScalingFrameSource: FrameSource {
    let wrapped: any FrameSource
    let factor: Double

    init(wrapping wrapped: any FrameSource, factor: Double) {
        self.wrapped = wrapped
        self.factor = factor
    }

    func frames() -> AsyncStream<TimestampedFrame> {
        // Pull the upstream stream out first: `AsyncStream<TimestampedFrame>`
        // is `Sendable` (unlike `any FrameSource`), so only Sendable values
        // cross into the relay `Task`. The pixel buffer is forwarded by
        // reference — untouched — honoring the frame's linear-ownership rule.
        let upstream = wrapped.frames()
        let factor = self.factor
        return AsyncStream { continuation in
            let task = Task {
                for await frame in upstream {
                    continuation.yield(TimestampedFrame(pixelBuffer: frame.pixelBuffer,
                                                        timestamp: frame.timestamp * factor))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Import model

/// Drives one video import from file selection through to a finished
/// `CompletedSession`, without ever touching the live capture pipeline
/// (`appState.processor` / `liveReadings` / live device ROIs are never read or
/// written). All UI-visible state is MainActor-isolated; the heavy per-frame
/// work runs on a detached task and only hops back to main to publish progress
/// and results.
@MainActor
@Observable
final class VideoImportModel {

    /// Where the import is in its lifecycle. `processing` carries live counts so
    /// the UI can show "frames 120 / ~288".
    enum Phase: Equatable {
        case loading
        case configuring
        case processing(framesProcessed: Int, estimatedTotal: Int?)
        case finished
        case failed(String)
    }

    /// Slow-motion presets. `factor` is the multiplier applied to asset
    /// timestamps to recover real capture time (see `TimeScalingFrameSource`).
    static let speedPresets: [(label: String, factor: Double)] = [
        ("1×", 1.0),
        ("¼× · 120 FPS", 0.25),
        ("⅛× · 240 FPS", 0.125)
    ]

    /// Progress is throttled to one main-actor hop per this many processed
    /// frames — enough for a smooth counter without flooding the main queue.
    private static let progressThrottle = 5

    // MARK: Inputs

    /// Local (already security-scope-copied) URL of the video to import.
    let videoURL: URL
    /// Snapshot copy of the capture screen's first device. Only its identity,
    /// `name` and `displayFormat` matter here; its ROI is replaced by the one
    /// the user draws over this video's first frame.
    let device: Device

    /// ROI drawn over the first frame. Starts `nil`; the configure UI sets it.
    var roi: NormalizedROI?

    /// Chosen normalization factor (see `speedPresets`). Defaults to normal
    /// speed.
    var speedFactor: Double = 1.0

    // MARK: Outputs

    private(set) var phase: Phase = .loading
    /// First frame of the video, upright, for the ROI-placement viewport.
    private(set) var firstFrame: UIImage?
    /// Oriented (display-upright) frame dimensions — the `AspectFillMapper`
    /// content size so ROI view coords map to the exact pixels processing sees.
    private(set) var videoDimensions: CGSize?
    /// The video track's nominal frame rate (fps) as stored in the file.
    private(set) var nominalFrameRate: Float?
    /// Asset duration in seconds (playback time, before normalization).
    private(set) var assetDuration: TimeInterval?

    /// A file whose track already runs at ≥100 fps is a raw high-frame-rate
    /// recording: its timestamps are already real capture time, so 1× is the
    /// correct choice and the UI says so.
    var suggestsRealTime: Bool { (nominalFrameRate ?? 0) >= 100 }

    /// Real-time duration after normalization (`assetDuration × speedFactor`),
    /// for the configure caption. Convenience only.
    var normalizedDuration: TimeInterval? {
        assetDuration.map { $0 * speedFactor }
    }

    private var processingTask: Task<Void, Never>?

    init(videoURL: URL, device: Device) {
        self.videoURL = videoURL
        self.device = device
    }

    // MARK: Metadata

    /// Loads first frame, oriented dimensions, frame rate and duration.
    /// `.loading → .configuring` on success, `.failed` otherwise. The awaits
    /// free the main thread; AVFoundation does the decode work off-main.
    func loadMetadata() async {
        phase = .loading
        let asset = AVURLAsset(url: videoURL)
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                phase = .failed("This file has no video track.")
                return
            }

            let (naturalSize, transform, frameRate) = try await track.load(.naturalSize,
                                                                           .preferredTransform,
                                                                           .nominalFrameRate)
            let duration = try await asset.load(.duration)

            // Apply only the transform's linear part to the natural size to get
            // the display-upright dimensions (portrait video shot in landscape
            // sensor space, etc.); `abs` folds away rotation sign.
            let oriented = naturalSize.applying(transform)
            let orientedSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .positiveInfinity
            let cgImage = try await generator.image(at: .zero).image

            self.videoDimensions = orientedSize
            self.nominalFrameRate = frameRate
            self.assetDuration = duration.seconds.isFinite ? duration.seconds : nil
            self.firstFrame = UIImage(cgImage: cgImage)
            self.phase = .configuring
        } catch {
            phase = .failed("Couldn't read this video: \(error.localizedDescription)")
        }
    }

    // MARK: Processing

    /// Kicks off offline processing on a detached task. Requires a placed ROI
    /// and the configuring phase; otherwise a no-op.
    ///
    /// A fresh `MeasurementProcessor` is used so the live pipeline actor is
    /// never disturbed. The frame source is a `FixtureFrameSource` (no real-time
    /// pacing — decode as fast as possible) wrapped in a `TimeScalingFrameSource`
    /// to normalize slow-motion timestamps. Results are collected off-main; only
    /// progress updates and the final publish hop to the MainActor.
    func startProcessing(appState: AppState) {
        guard let roi, phase == .configuring else { return }

        // Snapshot device carries its own placed ROI into the results/CSV.
        var deviceSnapshot = device
        deviceSnapshot.roi = roi

        let config = DeviceRecognitionConfig(id: device.id, roi: roi, format: device.displayFormat)
        let source = TimeScalingFrameSource(
            wrapping: FixtureFrameSource(videoURL: videoURL, realTimePacing: false),
            factor: speedFactor)
        // Start the stream on main: the resulting `AsyncStream` is Sendable and
        // is the only frame-source value that crosses into the detached task.
        let stream = source.frames()
        let estimatedTotal = estimatedFrameTotal()
        let throttle = Self.progressThrottle

        phase = .processing(framesProcessed: 0, estimatedTotal: estimatedTotal)

        processingTask = Task.detached(priority: .userInitiated) { [weak self] in
            let processor = MeasurementProcessor()
            await processor.update(devices: [config])

            var samples: [RecordingSample] = []
            for await frame in stream {
                if Task.isCancelled { return }
                let result = await processor.process(frame: frame)
                samples.append(RecordingSample(timestamp: result.timestamp, readings: result.readings))
                if samples.count % throttle == 0 {
                    let count = samples.count
                    // Bind to an immutable local before the hop: `self` is the
                    // outer weak optional, and referencing it directly inside a
                    // nested sendable closure trips Swift-6 capture diagnostics.
                    // The local strengthens `self` only for this brief call.
                    let model = self
                    await MainActor.run {
                        model?.updateProgress(framesProcessed: count, estimatedTotal: estimatedTotal)
                    }
                }
            }

            if Task.isCancelled { return }

            let collected = samples
            let model = self
            await MainActor.run {
                model?.finishProcessing(samples: collected, device: deviceSnapshot, appState: appState)
            }
        }
    }

    /// Cancels in-flight processing and returns to configuring so the user can
    /// re-place the ROI or pick a different speed and try again.
    func cancel() {
        processingTask?.cancel()
        processingTask = nil
        phase = .configuring
    }

    // MARK: MainActor callbacks from the processing task

    private func updateProgress(framesProcessed: Int, estimatedTotal: Int?) {
        // Ignore stragglers that land after a cancel/finish already moved us out
        // of the processing phase.
        guard case .processing = phase else { return }
        phase = .processing(framesProcessed: framesProcessed, estimatedTotal: estimatedTotal)
    }

    private func finishProcessing(samples: [RecordingSample], device: Device, appState: AppState) {
        // A cancel that raced the final hop already reset the phase; don't
        // resurrect a cancelled run into results.
        guard case .processing = phase else { return }

        guard !samples.isEmpty else {
            phase = .failed("No readable video frames")
            return
        }

        // Timestamps are monotonic (ascending PTS × positive factor), so the
        // first/last samples bound the session.
        let session = CompletedSession(id: UUID(),
                                       startedAt: Date(),
                                       endedAt: Date(),
                                       devices: [device],
                                       samples: samples,
                                       firstTimestamp: samples.first?.timestamp,
                                       lastTimestamp: samples.last?.timestamp)
        appState.completedSession = session
        appState.showResults = true
        phase = .finished
    }

    // MARK: Helpers

    /// Frame-count estimate for the progress bar, from the *original* footage
    /// (duration × nominal fps) — time scaling doesn't change how many frames
    /// are decoded. `nil` when either input is unknown.
    private func estimatedFrameTotal() -> Int? {
        guard let assetDuration, let nominalFrameRate,
              assetDuration > 0, nominalFrameRate > 0 else { return nil }
        return Int((assetDuration * Double(nominalFrameRate)).rounded())
    }
}
