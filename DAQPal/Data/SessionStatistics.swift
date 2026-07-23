//
//  SessionStatistics.swift
//  DAQPal
//
//  Accepted-only summary statistics for the results screen's stats cards.
//

import Foundation

/// Min / mean / max of one device's **accepted** readings in a completed
/// session. Rejected readings are stored for traceability (spec §17/§25) but
/// never contribute to statistics.
struct SessionStatistics: Equatable, Sendable {
    let minimum: Double
    let mean: Double
    let maximum: Double

    /// Fails (returns nil) when the session contains no accepted, finite
    /// readings for the device — the UI shows placeholders instead.
    init?(session: CompletedSession, deviceID: UUID) {
        let values = session.acceptedPoints(for: deviceID).map(\.value)
        guard let first = values.first else { return nil }
        var minValue = first
        var maxValue = first
        var sum = 0.0
        for value in values {
            minValue = Swift.min(minValue, value)
            maxValue = Swift.max(maxValue, value)
            sum += value
        }
        self.minimum = minValue
        self.maximum = maxValue
        self.mean = sum / Double(values.count)
    }
}
