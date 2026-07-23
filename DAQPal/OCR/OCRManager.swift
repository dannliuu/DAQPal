//
//  OCRManager.swift
//  DAQPal
//
//  The OCR replaceability seam (spec §14–§15): everything downstream of this
//  facade depends only on `OCREngine`, so swapping Vision for PaddleOCR, a
//  seven-segment recognizer, or a specialized tiny digit classifier
//  (spec §12–§13) is a one-line routing change here — no pipeline changes.
//

import CoreVideo
import Foundation

/// One recognized text hypothesis for a region.
struct OCRCandidate: Equatable, Sendable {
    let text: String
    /// Engine-reported confidence in 0...1 (raw OCR confidence, NOT the fused
    /// measurement confidence — see `ConfidenceEngine`).
    let confidence: Float
    /// Where the text sits, top-left normalized in the coordinate space of
    /// the buffer the engine was handed (full-frame when a `regionOfInterest`
    /// was used — engines convert). Feeds ROI auto-tracking. Optional: engines
    /// without localization report nil.
    let boundingBox: NormalizedROI?

    init(text: String, confidence: Float, boundingBox: NormalizedROI? = nil) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}

/// A text recognizer over upright pixel buffers.
///
/// `regionOfInterest` uses the project-wide `NormalizedROI` convention
/// (top-left origin, 0...1 in the upright image); implementations convert to
/// their native coordinate space internally. `nil` means the whole buffer.
protocol OCREngine {
    func recognize(in pixelBuffer: CVPixelBuffer,
                   regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate]
}

/// Facade the measurement pipeline talks to.
///
/// Today it routes every request to `VisionOCR`. Future engines (PaddleOCR via
/// ONNX, `SevenSegmentRecognizer`, specialized digit models — spec §12–§14)
/// plug in behind the same `OCREngine` protocol without touching
/// `MeasurementProcessor`.
final class OCRManager: OCREngine {
    private let engine: any OCREngine

    init(engine: any OCREngine = VisionOCR()) {
        self.engine = engine
    }

    func recognize(in pixelBuffer: CVPixelBuffer,
                   regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
        try await engine.recognize(in: pixelBuffer, regionOfInterest: regionOfInterest)
    }
}
