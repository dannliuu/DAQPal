//
//  ConfidenceEngine.swift
//  DAQPal
//
//  Multi-source confidence fusion (spec §19, Milestone 6). The final
//  confidence is NOT the raw OCR confidence — it is the product of independent
//  gates so that any single failing source collapses trust:
//
//      final = OCRConfidence × FormatValidity × PhysicalValidity × TemporalConsistency
//              × DecimalCertainty × CrossCheckAgreement
//
//  Format and physical validity are hard {0,1} gates; OCR and temporal are
//  continuous 0...1. A reading is accepted only when every gate passes.
//
//  DecimalCertainty (spec §11A) is scored SEPARATELY from digit confidence and
//  fused as a corroborate-or-veto factor in the `CrossCheckOutcome` mould: a
//  separator that was read directly contributes 1 and is neutral, while one
//  that was inferred contributes its own certainty and DEPRESSES the result.
//  A reading with confident digits must not inherit that confidence when its
//  separator is a guess — a dropped separator is a well-formed number wrong by
//  a factor of ten, invisible to every other gate here. Below
//  `decimalVetoThreshold` the factor also rejects, as `.ambiguousDecimal`.
//
//  CrossCheckAgreement is the OCR_RESEARCH.md Phase 4 fusion factor: a second,
//  independent reader (the classical `SevenSegmentSampler`) either corroborates
//  the OCR value or vetoes it — it NEVER inflates. Agreement/absence leaves the
//  product untouched (== 1); a disagreement contributes `(1 − samplerConfidence)`,
//  and a confident disagreement additionally rejects the reading. This honors
//  the spec's "reject uncertain over accept incorrect": two independent readers
//  who confidently disagree mean the digit is ambiguous.
//

import Foundation

/// The verdict of an independent cross-check reader (the classical
/// `SevenSegmentSampler`) on the same reading the OCR engine produced. Resolved
/// by the pipeline — agreement is defined against the display's resolution — and
/// fused by `ConfidenceEngine.fuse` per OCR_RESEARCH.md Phase 4 (corroborate or
/// veto, never inflate).
enum CrossCheckOutcome: Equatable, Sendable {
    /// The sampler abstained or does not apply (unconstrained format, unread
    /// digit cells, or a path that already used those cells). Neutral.
    case notAvailable
    /// The sampler read the same value (within half a least-significant digit);
    /// `samplerConfidence` is its own 0...1 confidence in that reading.
    case agrees(samplerConfidence: Float)
    /// The sampler confidently read a DIFFERENT value. `samplerConfidence` is its
    /// 0...1 confidence; `samplerValue` is what it read (kept for traceability).
    case disagrees(samplerConfidence: Float, samplerValue: Double)
}

/// Stateless fusion of the pipeline's per-source signals into a `Measurement`.
struct ConfidenceEngine {
    /// Readings below this raw OCR confidence are rejected outright — the text
    /// itself is untrustworthy, so downstream validity is moot (spec §19 gate).
    static let lowOCRConfidenceThreshold: Float = 0.3

    /// A disagreeing cross-check at or above this sampler confidence VETOES the
    /// reading as `.ambiguousDigit`: two independent readers that confidently
    /// disagree mean the digit is ambiguous. Below it, the disagreement only
    /// depresses the fused confidence (never inflates, never auto-rejects on
    /// this gate alone).
    static let crossCheckVetoThreshold: Float = 0.5

    /// A separator determination below this certainty VETOES the reading as
    /// `.ambiguousDecimal`. Spec §11A treats decimal position as a
    /// data-integrity property, so "reject uncertain over accept incorrect"
    /// applies with full force: a coin-flip separator would otherwise publish a
    /// number that is wrong by an order of magnitude and looks perfectly
    /// stable. A policy threshold, not a measured one.
    static let decimalVetoThreshold: Float = 0.5

    /// Fuses the per-source signals for one candidate reading into a final
    /// `Measurement`.
    ///
    /// - Parameters:
    ///   - ocrConfidence: raw engine confidence, 0...1.
    ///   - formatValid: whether `FormatValidator` accepted the text.
    ///   - physicalRejection: `PhysicalValidator`'s verdict (`nil` = plausible).
    ///   - temporalConsistency: `TemporalFilter` agreement score, 0...1.
    ///   - temporalRejected: whether the temporal window flagged the reading.
    ///   - crossCheck: an independent reader's verdict (default `.notAvailable`).
    ///     Applied ONLY when every prior gate passed; corroborate-or-veto.
    ///   - decimal: `FormatValidator`'s separator verdict for this reading
    ///     (spec §11A). `nil` on paths that never analysed one — neutral.
    ///   - formatRejection: the specific reason the format gate failed, when the
    ///     parser named one (e.g. `.ambiguousDecimal`). Defaults to
    ///     `.invalidFormat`, preserving the previous behaviour.
    ///   - displayText: the reading as written, trailing zeros preserved.
    ///
    /// Rejection precedence (first failing gate names the reason): format →
    /// low OCR → decimal → physical (range/rate) → temporal → cross-check. The
    /// decimal and cross-check factors can only DEPRESS the fused confidence —
    /// so `final ≤ ocrConfidence` still holds always.
    func fuse(timestamp: TimeInterval,
              value: Double,
              unit: String?,
              rawText: String?,
              ocrConfidence: Float,
              formatValid: Bool,
              physicalRejection: RejectionReason?,
              temporalConsistency: Float,
              temporalRejected: Bool,
              crossCheck: CrossCheckOutcome = .notAvailable,
              digitConfidences: [Float]? = nil,
              decimal: DecimalAnalysis? = nil,
              formatRejection: RejectionReason? = nil,
              displayText: String? = nil) -> Measurement {
        let formatFactor: Float = formatValid ? 1 : 0
        let physicalFactor: Float = physicalRejection == nil ? 1 : 0
        let temporalFactor = max(0, min(1, temporalConsistency))
        let ocr = max(0, min(1, ocrConfidence))
        // Corroborate-or-veto, like the cross-check: a directly read separator
        // scores 1 and is neutral; an inferred one depresses. Absent analysis is
        // neutral so untouched call sites keep their previous confidences.
        let decimalFactor = decimal.map { max(0, min(1, $0.confidence)) } ?? 1
        var finalConfidence = ocr * formatFactor * physicalFactor * temporalFactor * decimalFactor

        var reason: RejectionReason?
        if !formatValid {
            reason = formatRejection ?? .invalidFormat
        } else if ocr < Self.lowOCRConfidenceThreshold {
            reason = .lowOCRConfidence
        } else if decimal != nil, decimalFactor < Self.decimalVetoThreshold {
            reason = .ambiguousDecimal
        } else if let physicalRejection {
            reason = physicalRejection
        } else if temporalRejected {
            reason = .temporalInconsistency
        } else {
            reason = nil
        }

        // Cross-check gate — only when every prior gate passed. Agreement and
        // absence are neutral (the corroboration already shows in the reading
        // surviving; do not multiply above the OCR-derived value). A
        // disagreement multiplies in `(1 − samplerConfidence)`, and a confident
        // one (≥ veto threshold) rejects as `.ambiguousDigit`.
        if reason == nil, case .disagrees(let samplerConfidence, _) = crossCheck {
            let c = max(0, min(1, samplerConfidence))
            finalConfidence *= (1 - c)
            if c >= Self.crossCheckVetoThreshold {
                reason = .ambiguousDigit
            }
        }

        return Measurement(timestamp: timestamp,
                           value: value,
                           unit: unit,
                           confidence: finalConfidence,
                           accepted: reason == nil,
                           rejectionReason: reason,
                           rawText: rawText,
                           digitConfidences: digitConfidences,
                           decimal: decimal,
                           displayText: displayText)
    }
}
