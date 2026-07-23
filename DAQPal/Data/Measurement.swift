//
//  Measurement.swift
//  DAQPal
//

import Foundation

/// Why a candidate reading was rejected by the validation pipeline (spec §18).
enum RejectionReason: String, Codable, Sendable, CaseIterable {
    case lowOCRConfidence = "LOW_OCR_CONFIDENCE"
    case invalidFormat = "INVALID_FORMAT"
    case outOfRange = "OUT_OF_RANGE"
    case temporalInconsistency = "TEMPORAL_INCONSISTENCY"
    case excessiveRateOfChange = "EXCESSIVE_RATE_OF_CHANGE"
    case ambiguousDigit = "AMBIGUOUS_DIGIT"
    case displayLost = "DISPLAY_LOST"

    /// Short uppercase label for the rejection flash chip,
    /// e.g. "✕ REJECTED — FORMAT MISMATCH".
    var displayLabel: String {
        switch self {
        case .lowOCRConfidence: "LOW CONFIDENCE"
        case .invalidFormat: "FORMAT MISMATCH"
        case .outOfRange: "OUT OF RANGE"
        case .temporalInconsistency: "TEMPORAL INCONSISTENCY"
        case .excessiveRateOfChange: "RATE OF CHANGE"
        case .ambiguousDigit: "AMBIGUOUS DIGIT"
        case .displayLost: "DISPLAY LOST"
        }
    }
}

/// One validated (accepted or rejected) reading of a single device on a single
/// processed frame (spec §18).
///
/// `timestamp` is the **monotonic capture timestamp** of the source frame in
/// seconds (`CMSampleBuffer` presentation time), used for all sequencing.
/// Wall-clock time lives on the session (`RecordingSession.startedAt`), not
/// here.
struct Measurement: Sendable {
    let timestamp: TimeInterval
    /// Parsed numeric value; `.nan` when no value could be reconstructed
    /// (the raw text is still preserved in `rawText` for traceability).
    let value: Double
    let unit: String?
    /// Final fused confidence in 0...1 (spec §19) — not the raw OCR confidence.
    let confidence: Float
    let accepted: Bool
    let rejectionReason: RejectionReason?
    /// Raw recognized text before parsing, for traceability/debugging.
    let rawText: String?
    /// Per-digit confidences when the digit-level path produced this reading.
    let digitConfidences: [Float]?

    init(timestamp: TimeInterval,
         value: Double,
         unit: String?,
         confidence: Float,
         accepted: Bool,
         rejectionReason: RejectionReason? = nil,
         rawText: String? = nil,
         digitConfidences: [Float]? = nil) {
        self.timestamp = timestamp
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.accepted = accepted
        self.rejectionReason = rejectionReason
        self.rawText = rawText
        self.digitConfidences = digitConfidences
    }

    /// Convenience for a rejected reading.
    static func rejected(timestamp: TimeInterval,
                         reason: RejectionReason,
                         value: Double = .nan,
                         unit: String? = nil,
                         confidence: Float = 0,
                         rawText: String? = nil,
                         digitConfidences: [Float]? = nil) -> Measurement {
        Measurement(timestamp: timestamp,
                    value: value,
                    unit: unit,
                    confidence: confidence,
                    accepted: false,
                    rejectionReason: reason,
                    rawText: rawText,
                    digitConfidences: digitConfidences)
    }
}
