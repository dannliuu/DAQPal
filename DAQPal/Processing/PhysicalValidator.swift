//
//  PhysicalValidator.swift
//  DAQPal
//
//  Physical plausibility gate (spec §17, Milestone 6). Per-device stateful:
//  a range check against the configured display bounds and a rate-of-change
//  check against the last ACCEPTED value. Range and rate rejections are the
//  system's "reject an uncertain reading over accepting an incorrect one"
//  policy (spec §17) applied to the physics of the measured signal.
//

import Foundation

/// One validator instance per device. Not thread-safe by itself; it is owned
/// and mutated exclusively inside `MeasurementProcessor` (an actor), or by a
/// test on a single thread.
final class PhysicalValidator {
    /// Rate limit as a multiple of the configured span, per second. Empirical
    /// default: a signal is allowed to traverse its whole configured range
    /// twice a second before a jump is treated as implausible. Only applied
    /// when both bounds are configured; otherwise rate checking is disabled.
    static let rateSpanMultiplier: Double = 2.0

    /// Consecutive rate rejections tolerated before a sustained new level is
    /// admitted as a real step change (spec §16: real transitions must
    /// survive). Prevents the validator from permanently latching onto a stale
    /// baseline when the instrument genuinely steps to a far value.
    static let maxConsecutiveRateRejections = 5

    private let format: DisplayFormat
    private var lastAcceptedValue: Double?
    private var lastAcceptedTimestamp: TimeInterval?
    private var consecutiveRateRejections = 0

    init(format: DisplayFormat) {
        self.format = format
    }

    /// Returns `nil` when the value is physically plausible, otherwise the
    /// reason to reject it. Has the side effect of advancing the consecutive
    /// rate-rejection counter used for latch-breaking; call once per frame.
    func validate(value: Double, timestamp: TimeInterval) -> RejectionReason? {
        guard value.isFinite else { return .outOfRange }

        // 1. Range check — independent of history. A value the display cannot
        //    physically show is rejected outright and never breaks the rate
        //    latch (only genuine in-range step changes should).
        if let minimum = format.minimumValue, value < minimum { return .outOfRange }
        if let maximum = format.maximumValue, value > maximum { return .outOfRange }

        // 2. Rate-of-change check vs the last accepted value.
        guard let last = lastAcceptedValue,
              let lastTimestamp = lastAcceptedTimestamp,
              let maxRate = maxRatePerSecond else {
            // No baseline yet, or rate checking disabled (range not fully
            // configured): nothing more to reject on.
            return nil
        }

        let dt = timestamp - lastTimestamp
        guard dt > 0 else { return nil } // can't derive a rate; treat as plausible

        let rate = abs(value - last) / dt
        if rate > maxRate {
            consecutiveRateRejections += 1
            if consecutiveRateRejections > Self.maxConsecutiveRateRejections {
                // Sustained implausible-rate readings: assume the instrument
                // really stepped. Admit this level and let it become the new
                // baseline once the reading is accepted downstream.
                consecutiveRateRejections = 0
                return nil
            }
            return .excessiveRateOfChange
        }

        // A within-limit reading breaks any run of rate rejections.
        consecutiveRateRejections = 0
        return nil
    }

    /// Records the new accepted baseline. Called by the pipeline only after a
    /// reading passes every gate, so the rate check always compares against the
    /// last value the system actually trusted.
    func recordAccepted(value: Double, timestamp: TimeInterval) {
        lastAcceptedValue = value
        lastAcceptedTimestamp = timestamp
        consecutiveRateRejections = 0
    }

    /// Maximum plausible |Δvalue| per second, or nil when rate checking is
    /// disabled (requires a finite, positive-span configured range).
    private var maxRatePerSecond: Double? {
        guard let minimum = format.minimumValue,
              let maximum = format.maximumValue,
              maximum > minimum else { return nil }
        return (maximum - minimum) * Self.rateSpanMultiplier
    }
}
