//
//  Measurement.swift
//  DAQPal
//

import Foundation

/// Why a candidate reading was rejected by the validation pipeline (spec §18).
enum RejectionReason: String, Codable, Sendable, CaseIterable {
    case lowOCRConfidence = "LOW_OCR_CONFIDENCE"
    /// Every gate passed on its OWN factor, but their PRODUCT collapsed below
    /// what those gates can legitimately produce
    /// (`ConfidenceEngine.minimumFusedConfidence`). Deliberately distinct from
    /// `.lowOCRConfidence`, which asserts a specific measured fact — that the
    /// raw text was untrustworthy — and that claim is provably FALSE here, since
    /// this reason is unreachable unless the OCR gate already passed. Reusing it
    /// would put a fabricated cause in the audit column of the exported row.
    /// Structurally this is an invariant violation: some factor was applied
    /// without being gated. Emitted so the failure is visible in the record
    /// instead of being laundered as an OCR problem — the remedy for
    /// LOW_OCR_CONFIDENCE is the operator's (light, focus, ROI); the remedy for
    /// this is the developer's.
    case lowFusedConfidence = "LOW_FUSED_CONFIDENCE"
    case invalidFormat = "INVALID_FORMAT"
    case outOfRange = "OUT_OF_RANGE"
    case temporalInconsistency = "TEMPORAL_INCONSISTENCY"
    case excessiveRateOfChange = "EXCESSIVE_RATE_OF_CHANGE"
    case ambiguousDigit = "AMBIGUOUS_DIGIT"
    /// The DECIMAL SEPARATOR's presence or position could not be determined
    /// (spec §11A). Distinct from `.invalidFormat`: the digits themselves are
    /// well formed, which is exactly what makes this dangerous — dropping a
    /// separator yields a well-formed number wrong by a factor of ten or more,
    /// and a consistently shifted series looks perfectly stable to the temporal
    /// filter. Raised instead of emitting the digits as an integer.
    case ambiguousDecimal = "AMBIGUOUS_DECIMAL"
    case displayLost = "DISPLAY_LOST"
    /// A field-backed device's tracked geometry was NOT independently verified
    /// this frame (remediation plan Phase 14: `TrackingHealthy = false ⇒
    /// MeasurementValid = false`, even at 99% OCR confidence). The pixels may
    /// have been read perfectly — the reading is rejected because the geometry
    /// it would be attributed to is uncorroborated, so the value could belong
    /// to anything that happens to sit at that location. Emitted instead of
    /// silence: rejected readings are logged, never dropped.
    case trackingInvalid = "TRACKING_INVALID"

    /// Short uppercase label for the rejection flash chip,
    /// e.g. "✕ REJECTED — FORMAT MISMATCH".
    var displayLabel: String {
        switch self {
        case .lowOCRConfidence: "LOW CONFIDENCE"
        case .lowFusedConfidence: "LOW FUSED CONFIDENCE"
        case .invalidFormat: "FORMAT MISMATCH"
        case .outOfRange: "OUT OF RANGE"
        case .temporalInconsistency: "TEMPORAL INCONSISTENCY"
        case .excessiveRateOfChange: "RATE OF CHANGE"
        case .ambiguousDigit: "AMBIGUOUS DIGIT"
        case .ambiguousDecimal: "AMBIGUOUS DECIMAL"
        case .displayLost: "DISPLAY LOST"
        case .trackingInvalid: "TRACKING INVALID"
        }
    }
}

/// What the parser determined about a reading's DECIMAL SEPARATOR, scored
/// independently of the digits (spec §11A).
///
/// Digit confidence and separator confidence are different properties: OCR can
/// be certain of every glyph and still leave the separator undetermined (a
/// dropped point, a comma that could be either a decimal mark or a thousands
/// group). Carrying the separator verdict separately is what lets
/// `ConfidenceEngine` stop a reading with confident digits from inheriting
/// their confidence when the separator is a guess.
struct DecimalAnalysis: Equatable, Sendable {
    /// Whether a separator was found in the reading.
    let separatorDetected: Bool
    /// Digits BEFORE the separator, using `DisplayFormat.decimalPosition`'s
    /// convention (`0` for `.5`). `nil` when no separator was detected.
    let separatorPosition: Int?
    /// Digits written after the separator, as recognized — trailing zeros
    /// included, so `1.000` reports 3 and not 0.
    let fractionDigitCount: Int
    /// 0...1 confidence in the SEPARATOR DETERMINATION itself, not in the
    /// digits. 1 means presence and position are unambiguous; lower values mean
    /// the reading was resolved by inference and should depress overall trust.
    let confidence: Float

    init(separatorDetected: Bool,
         separatorPosition: Int?,
         fractionDigitCount: Int,
         confidence: Float) {
        self.separatorDetected = separatorDetected
        self.separatorPosition = separatorPosition
        self.fractionDigitCount = fractionDigitCount
        self.confidence = confidence
    }

    /// A display that declares no separator and showed none — nothing to be
    /// uncertain about, so this is neutral in fusion.
    static let integerDisplay = DecimalAnalysis(separatorDetected: false,
                                                separatorPosition: nil,
                                                fractionDigitCount: 0,
                                                confidence: 1)
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
    /// The separator verdict for this reading (spec §11A), when the parser
    /// produced one. `nil` on paths that never analysed a separator.
    let decimal: DecimalAnalysis?
    /// The parsed number as WRITTEN, with the separator canonicalized to "."
    /// and trailing zeros preserved (`1.000` stays `"1.000"`). `value` alone
    /// cannot carry that: `Double(1.000) == 1`, so structured output that
    /// formats from `value` loses significant trailing digits.
    let displayText: String?

    init(timestamp: TimeInterval,
         value: Double,
         unit: String?,
         confidence: Float,
         accepted: Bool,
         rejectionReason: RejectionReason? = nil,
         rawText: String? = nil,
         digitConfidences: [Float]? = nil,
         decimal: DecimalAnalysis? = nil,
         displayText: String? = nil) {
        self.timestamp = timestamp
        self.value = value
        self.unit = unit
        self.confidence = confidence
        self.accepted = accepted
        self.rejectionReason = rejectionReason
        self.rawText = rawText
        self.digitConfidences = digitConfidences
        self.decimal = decimal
        self.displayText = displayText
    }

    /// Convenience for a rejected reading.
    static func rejected(timestamp: TimeInterval,
                         reason: RejectionReason,
                         value: Double = .nan,
                         unit: String? = nil,
                         confidence: Float = 0,
                         rawText: String? = nil,
                         digitConfidences: [Float]? = nil,
                         decimal: DecimalAnalysis? = nil,
                         displayText: String? = nil) -> Measurement {
        Measurement(timestamp: timestamp,
                    value: value,
                    unit: unit,
                    confidence: confidence,
                    accepted: false,
                    rejectionReason: reason,
                    rawText: rawText,
                    digitConfidences: digitConfidences,
                    decimal: decimal,
                    displayText: displayText)
    }
}
