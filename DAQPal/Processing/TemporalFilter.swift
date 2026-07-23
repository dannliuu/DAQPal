//
//  TemporalFilter.swift
//  DAQPal
//
//  Rolling-window temporal consistency (spec §16, Milestone 8 minimal form).
//  Digit-level agreement scoring: a reading that disagrees with a stable
//  recent window is suspect, but a genuine SUSTAINED change turns the window
//  over and is accepted (spec §16: the 12.000 → 13.001 transition must remain
//  detectable). This filter only SCORES and flags — it never rewrites the
//  reading's value (no averaging/smoothing that would destroy real
//  transitions, per spec §16).
//

import Foundation

/// One filter instance per device. Owned and mutated exclusively inside
/// `MeasurementProcessor` (an actor) or by a single-threaded test.
final class TemporalFilter {
    /// Number of recent readings compared against. ~5 per spec §16's example.
    static let windowSize = 5

    /// Digit-agreement below this (while the window is full) flags the reading
    /// as temporally inconsistent. Empirical default: on a 5-digit display, a
    /// single changed digit scores 0.8, a two-digit tick ~0.6, so 0.5 admits
    /// genuine multi-digit ticks while rejecting readings that share almost no
    /// digits with the stable window (OCR flicker / spurious numbers).
    static let consistencyThreshold: Float = 0.5

    /// Scoring result for one reading.
    struct Evaluation {
        /// Digit-position agreement with the current window, 0...1. Reported as
        /// the temporal factor of the fused confidence (spec §19). 1.0 while the
        /// window is too small to judge, so start-up readings aren't penalised.
        let consistency: Float
        /// True when the window is full and consistency is below threshold.
        let rejected: Bool
    }

    private let format: DisplayFormat
    /// Recent readings as decimal-aligned digit signatures (see `signature`).
    private var window: [[Character]] = []

    init(format: DisplayFormat) {
        self.format = format
    }

    /// Scores `value` against the current window, then admits it to the window.
    ///
    /// The reading is always admitted (even when flagged) so that a sustained
    /// change turns the window over within a few frames and stops being
    /// flagged — that is the mechanism by which real transitions survive.
    func evaluate(value: Double) -> Evaluation {
        let signature = Self.signature(of: value, format: format)
        let consistency = Self.consistency(of: signature, against: window)
        let windowFull = window.count >= Self.windowSize
        let rejected = windowFull && consistency < Self.consistencyThreshold

        if !signature.isEmpty {
            window.append(signature)
            if window.count > Self.windowSize { window.removeFirst() }
        }

        return Evaluation(consistency: consistency, rejected: rejected)
    }

    // MARK: - Scoring

    /// Average, over digit positions, of the fraction of window readings that
    /// agree with `signature` at that position. 1.0 when there is nothing to
    /// compare against yet.
    private static func consistency(of signature: [Character],
                                    against window: [[Character]]) -> Float {
        guard !signature.isEmpty, !window.isEmpty else { return 1.0 }
        var positionScoreSum: Float = 0
        for position in signature.indices {
            var agree = 0
            var counted = 0
            for past in window where position < past.count {
                counted += 1
                if past[position] == signature[position] { agree += 1 }
            }
            positionScoreSum += counted > 0 ? Float(agree) / Float(counted) : 1
        }
        return positionScoreSum / Float(signature.count)
    }

    /// Decimal-aligned, fixed-length digit signature for the device's format.
    ///
    /// The value is formatted to the display's fraction-digit count, digits are
    /// extracted, then left-padded / trimmed to exactly `digitCount` so every
    /// signature aligns by decimal place (position 0 = most significant digit).
    /// Sign is intentionally ignored — the digit-level temporal check concerns
    /// the magnitude digits (spec §16 shows only digit positions); sign flips
    /// are caught by `PhysicalValidator`'s rate/range checks.
    private static func signature(of value: Double, format: DisplayFormat) -> [Character] {
        guard value.isFinite else { return [] }
        let text = String(format: "%.\(format.fractionDigits)f", abs(value))
        var digits = text.filter { $0.isNumber }
        if digits.count < format.digitCount {
            digits = String(repeating: "0", count: format.digitCount - digits.count) + digits
        }
        return Array(digits.suffix(format.digitCount))
    }
}
