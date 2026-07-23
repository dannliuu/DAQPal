//
//  ConfidenceEngine.swift
//  DAQPal
//
//  Multi-source confidence fusion (spec §19, Milestone 6). The final
//  confidence is NOT the raw OCR confidence — it is the product of independent
//  gates so that any single failing source collapses trust:
//
//      final = OCRConfidence × FormatValidity × PhysicalValidity × TemporalConsistency
//
//  Format and physical validity are hard {0,1} gates; OCR and temporal are
//  continuous 0...1. A reading is accepted only when every gate passes.
//

import Foundation

/// Stateless fusion of the pipeline's per-source signals into a `Measurement`.
struct ConfidenceEngine {
    /// Readings below this raw OCR confidence are rejected outright — the text
    /// itself is untrustworthy, so downstream validity is moot (spec §19 gate).
    static let lowOCRConfidenceThreshold: Float = 0.3

    /// Fuses the per-source signals for one candidate reading into a final
    /// `Measurement`.
    ///
    /// - Parameters:
    ///   - ocrConfidence: raw engine confidence, 0...1.
    ///   - formatValid: whether `FormatValidator` accepted the text.
    ///   - physicalRejection: `PhysicalValidator`'s verdict (`nil` = plausible).
    ///   - temporalConsistency: `TemporalFilter` agreement score, 0...1.
    ///   - temporalRejected: whether the temporal window flagged the reading.
    ///
    /// Rejection precedence (first failing gate names the reason): format →
    /// low OCR → physical (range/rate) → temporal. `final ≤ ocrConfidence`
    /// always, since every other factor is in 0...1.
    func fuse(timestamp: TimeInterval,
              value: Double,
              unit: String?,
              rawText: String?,
              ocrConfidence: Float,
              formatValid: Bool,
              physicalRejection: RejectionReason?,
              temporalConsistency: Float,
              temporalRejected: Bool,
              digitConfidences: [Float]? = nil) -> Measurement {
        let formatFactor: Float = formatValid ? 1 : 0
        let physicalFactor: Float = physicalRejection == nil ? 1 : 0
        let temporalFactor = max(0, min(1, temporalConsistency))
        let ocr = max(0, min(1, ocrConfidence))
        let finalConfidence = ocr * formatFactor * physicalFactor * temporalFactor

        let reason: RejectionReason?
        if !formatValid {
            reason = .invalidFormat
        } else if ocr < Self.lowOCRConfidenceThreshold {
            reason = .lowOCRConfidence
        } else if let physicalRejection {
            reason = physicalRejection
        } else if temporalRejected {
            reason = .temporalInconsistency
        } else {
            reason = nil
        }

        return Measurement(timestamp: timestamp,
                           value: value,
                           unit: unit,
                           confidence: finalConfidence,
                           accepted: reason == nil,
                           rejectionReason: reason,
                           rawText: rawText,
                           digitConfidences: digitConfidences)
    }
}
