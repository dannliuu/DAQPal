//
//  TemporalFilter.swift
//  DAQPal
//
//  Rolling-window temporal consistency (spec §16, Milestone 8 minimal form).
//  VALUE-distance scoring, not per-digit agreement: naive digit agreement
//  flags decade rollovers (a smooth ramp crossing 12.499 → 12.500 changes
//  three digit positions at once and got rejected mid-ramp), while numeric
//  distance sees it as a one-step move. A reading far from the recent window
//  — relative to the display's resolution and the window's own recent
//  movement — is suspect; a genuine SUSTAINED change turns the window over
//  and is accepted (spec §16: the 12.000 → 13.001 transition must remain
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

    /// Consistency below this (while the window is full) flags the reading as
    /// temporally inconsistent.
    static let consistencyThreshold: Float = 0.5

    /// Deviation allowance floor, in display least-significant-digit steps —
    /// readings within ~50 counts of the recent median are "the same reading
    /// modulo flicker". Empirical default.
    static let stepAllowance = 50.0

    /// Deviation allowance as a multiple of the window's recent frame-to-frame
    /// movement, so a legitimately ramping signal widens its own allowance.
    /// Empirical default.
    static let volatilityAllowance = 8.0

    /// Scoring result for one reading.
    struct Evaluation {
        /// Distance-based agreement with the current window, 0...1. Reported as
        /// the temporal factor of the fused confidence (spec §19). 1.0 while the
        /// window is too small to judge, so start-up readings aren't penalised.
        let consistency: Float
        /// True when the window is full and consistency is below threshold.
        let rejected: Bool
    }

    private let format: DisplayFormat
    private var window: [Double] = []

    init(format: DisplayFormat) {
        self.format = format
    }

    /// Scores `value` against the current window, then admits it to the window.
    ///
    /// The reading is always admitted (even when flagged) so that a sustained
    /// change turns the window over within a few frames and stops being
    /// flagged — that is the mechanism by which real transitions survive.
    func evaluate(value: Double) -> Evaluation {
        let consistency = consistency(of: value)
        let windowFull = window.count >= Self.windowSize
        let rejected = windowFull && consistency < Self.consistencyThreshold

        if value.isFinite {
            window.append(value)
            if window.count > Self.windowSize { window.removeFirst() }
        }

        return Evaluation(consistency: consistency, rejected: rejected)
    }

    // MARK: - Scoring

    /// 1 − deviation/allowance (clamped to 0...1), where deviation is the
    /// distance from the window median and allowance is the larger of the
    /// display-resolution floor and the window's own recent volatility. Sign
    /// flips and range jumps beyond the allowance score ~0 and are additionally
    /// caught by `PhysicalValidator`'s rate/range checks.
    private func consistency(of value: Double) -> Float {
        guard value.isFinite, !window.isEmpty else { return 1.0 }
        let median = window.sorted()[window.count / 2]
        let step = pow(10.0, -Double(format.fractionDigits))
        var volatility = 0.0
        for i in 1..<window.count {
            volatility = max(volatility, abs(window[i] - window[i - 1]))
        }
        let allowance = max(step * Self.stepAllowance, volatility * Self.volatilityAllowance)
        guard allowance > 0 else { return value == median ? 1 : 0 }
        return Float(max(0, 1 - abs(value - median) / allowance))
    }
}
