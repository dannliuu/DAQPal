//
//  FrameSource.swift
//  DAQPal
//
//  The testability seam (spec §40.3): live capture and file/synthetic fixtures
//  feed the identical frame type into the identical pipeline, so recognition
//  and validation are testable with no camera hardware, no Simulator camera,
//  and no GUI automation.
//

import CoreVideo
import Foundation

/// A single video frame with a monotonic capture timestamp.
///
/// Concurrency strategy (documented per project rules): `CVPixelBuffer` is not
/// `Sendable`. `TimestampedFrame` is declared `@unchecked Sendable` because the
/// buffer's ownership is transferred **linearly**: the producer (capture
/// delegate / asset reader / synthesizer) hands the frame to exactly one
/// consumer (`FrameProcessor` → `MeasurementProcessor`), never retains it after
/// yielding, and no code mutates a buffer after handoff. Frames are only ever
/// read (Vision/CoreImage) downstream.
struct TimestampedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    /// Monotonic seconds (CMSampleBuffer presentation time or equivalent).
    let timestamp: TimeInterval
}

/// A source of upright (portrait-oriented) frames.
///
/// Conformances:
/// - `LiveCameraFrameSource` — AVCaptureSession video data output (production).
/// - `FixtureFrameSource` — bundled video file via AVAssetReader (tests).
/// - `SyntheticFrameSource` — programmatically rendered DMM frames
///   (Simulator demo + tests; clearly synthetic, never a claim of real-DMM
///   accuracy).
protocol FrameSource {
    func frames() -> AsyncStream<TimestampedFrame>
}

/// Result of processing one frame across all configured devices.
struct FrameResult: Sendable {
    let timestamp: TimeInterval
    /// Keyed by `Device.id`. Devices without a confirmed ROI are absent.
    let readings: [UUID: Measurement]
    /// Raw whole-ROI OCR text (first configured device) for the debug overlay.
    let debugText: String?
    /// Full-frame normalized bounding box of the ACCEPTED reading's text per
    /// device — feeds ROI auto-tracking (`AppState`) so the window can follow
    /// a shaking display. Absent for rejected/missing readings.
    let observedROIs: [UUID: NormalizedROI]

    init(timestamp: TimeInterval,
         readings: [UUID: Measurement],
         debugText: String?,
         observedROIs: [UUID: NormalizedROI] = [:]) {
        self.timestamp = timestamp
        self.readings = readings
        self.debugText = debugText
        self.observedROIs = observedROIs
    }
}
