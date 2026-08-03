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

    /// The infimum of the product the gates above can legitimately yield.
    ///
    /// Derived, never chosen. Every accepted reading satisfies, per gate:
    ///
    ///     format, physical  == 1                                  (hard {0,1} gates)
    ///     ocr               >= lowOCRConfidenceThreshold    0.30
    ///     temporal          >= TemporalFilter.consistencyThreshold 0.50
    ///     decimal           >= decimalVetoThreshold          0.50
    ///     crossCheck         > 1 − crossCheckVetoThreshold   0.50  (strict)
    ///
    /// The temporal line holds only because `TemporalFilter` reports 1.0 while
    /// its window is not yet full (`TemporalFilter.consistency(of:)`); the
    /// reference below is written against `TemporalFilter.consistencyThreshold`
    /// rather than a local copy so that contract cannot silently decouple.
    ///
    /// THIS IS NOT THE ACCEPT/REJECT FLOOR. Because it is the infimum of the
    /// gate-permitted region, every gate-passing reading is >= it BY
    /// CONSTRUCTION, so gating on it would be a tautology that refuses nothing.
    /// It is kept only to prove, in `minimumFusedConfidence` below, that the
    /// shipped floor is a real constraint and not a no-op.
    static let gatePermittedInfimum: Float =
        lowOCRConfidenceThreshold
        * TemporalFilter.consistencyThreshold
        * decimalVetoThreshold
        * (1 - crossCheckVetoThreshold)          // == 0.0375

    /// A reading must retain at least this share of its nominal confidence after
    /// every quality factor has been applied, or it is refused as
    /// `.lowFusedConfidence`.
    ///
    /// A POLICY THRESHOLD, NOT A DERIVED ONE — the same kind of decision as
    /// `lowOCRConfidenceThreshold` and `decimalVetoThreshold` above, and it is
    /// stated here rather than computed because nothing in the arithmetic
    /// implies it. Deriving a floor was tried and rejected: the derived value is
    /// `gatePermittedInfimum`, which by construction cannot refuse anything.
    ///
    /// WHY 0.15 — it is the product of the OCR gate minimum and ONE other gate
    /// minimum (0.30 × 0.50), so the rule it expresses is:
    ///
    ///     two gates sitting at their minimum is the BOUNDARY and is accepted;
    ///     anything degraded further than that is refused, because the reading
    ///     is then being held up by nothing.
    ///
    /// The documented leak this closes: ocr 0.35 × decimal 0.50 × cross-check
    /// 0.51 = 0.0892 — three simultaneous warnings, previously ACCEPTED because
    /// each factor passed its own gate in isolation and nothing ever judged the
    /// product. Refused now, with ~1.7× margin. Ties go to acceptance (`<`, not
    /// `<=`), matching the convention of every other gate in this file.
    ///
    /// WHY NOT HIGHER. 0.25 was tried first ("no two gates simultaneously at
    /// minimum"). Measured over the 360-combination gate-permitted sweep in
    /// `ConfidenceEngineTests`, it refuses 49.7% versus 22.8% here — and it cuts
    /// into a mid-range for which NO real-instrument data exists. The two errors
    /// are not symmetric in the way a first pass suggests: every exported row
    /// carries its `confidence` column, so a floor set slightly LOW stays
    /// recoverable — an analyst can filter — whereas a floor set too HIGH
    /// destroys data that was never captured at all. The usual "over-refusal is
    /// loud and self-correcting" argument also does not apply yet, because with
    /// no recorded fixtures nobody would notice over-refusal until a device day.
    /// So: close the pathological case with margin, leave the undermeasured
    /// middle alone, and revise UPWARD once DoD-2's fixtures exist. Up is the
    /// safe direction to defer.
    ///
    /// WHAT IT DOES NOT DO. This is not the main defence against
    /// wrong-and-accepted, and must not be described as one. The measured `.5`
    /// power-of-ten failures on the device benchmark carried 0.75 confidence —
    /// far above any sane floor. Wrong readings can be confident. A floor only
    /// catches readings whose own signals already admit doubt; B3 addresses the
    /// confident-and-wrong class, and it is the more important task.
    ///
    /// PROVISIONAL. Re-tune against DoD-2's real fixtures when they exist, and
    /// record the refusal rate alongside accuracy — never accuracy alone, or a
    /// floor that quietly refuses everything will read as an accuracy win.
    static let minimumFusedConfidence: Float = 0.15

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
    /// low OCR → decimal → physical (range/rate) → temporal → cross-check →
    /// fused floor. The decimal and cross-check factors can only DEPRESS the
    /// fused confidence — so `final ≤ ocrConfidence` still holds always. The
    /// fused floor is last and lowest-priority by design: it judges the PRODUCT
    /// once every factor has been applied, and only when no earlier gate named
    /// a reason (see `minimumFusedConfidence`).
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

        // The fused floor: the LAST word on the product, after every factor has
        // been applied. The ladder above judges each factor in ISOLATION, and the
        // cross-check then multiplies the product a second time with nothing
        // re-gating it — nothing before this point ever looks at
        // `finalConfidence` itself. This does.
        //
        // It is an invariant assertion, not a policy knob: by construction it can
        // only fire when a factor escaped its own gate, so a firing is a BUG
        // REPORT about the fusion inputs, not a marginal reading. Placement after
        // the cross-check block is the whole point; moved above it, the last
        // multiply would again go unchecked.
        //
        // `reason == nil` preserves rejection precedence — the floor never
        // relabels a more specific verdict. It sets the verdict ONLY:
        // `finalConfidence` is left exactly as computed, because the confidence
        // is the evidence for the refusal and must survive into the exported row
        // (rejected readings are logged, never dropped).
        if reason == nil, finalConfidence < Self.minimumFusedConfidence {
            reason = .lowFusedConfidence
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
