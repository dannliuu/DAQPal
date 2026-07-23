//
//  Experiment.swift
//  DAQPal
//
//  Immutable record of a finished recording session (the MVP "experiment").
//

import Foundation

struct CompletedSession: Identifiable, Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    /// Device configuration snapshot at stop time (defines CSV column sets,
    /// graph series and stats cards).
    let devices: [Device]
    let samples: [RecordingSample]
    let firstTimestamp: TimeInterval?
    let lastTimestamp: TimeInterval?

    var duration: TimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return max(0, lastTimestamp - firstTimestamp)
    }

    var sampleCount: Int { samples.count }

    var acceptedCount: Int {
        samples.reduce(0) { $0 + $1.readings.values.filter(\.accepted).count }
    }

    var rejectedCount: Int {
        samples.reduce(0) { $0 + $1.readings.values.filter { !$0.accepted }.count }
    }

    var samplesPerSecond: Double {
        guard duration > 0 else { return 0 }
        return Double(sampleCount) / duration
    }

    /// Seconds since the first sample, used for graph x-axis and CSV
    /// `timestamp_s`.
    func relativeTime(_ timestamp: TimeInterval) -> TimeInterval {
        guard let firstTimestamp else { return 0 }
        return timestamp - firstTimestamp
    }

    /// Accepted (relativeTime, value) points for one device, for graphing.
    func acceptedPoints(for deviceID: UUID) -> [(time: TimeInterval, value: Double)] {
        samples.compactMap { sample in
            guard let m = sample.readings[deviceID], m.accepted, m.value.isFinite else { return nil }
            return (relativeTime(sample.timestamp), m.value)
        }
    }
}
