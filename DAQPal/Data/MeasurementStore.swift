//
//  MeasurementStore.swift
//  DAQPal
//
//  Append-only storage for an in-progress recording session.
//

import Foundation
import Observation

/// One recorded row: everything the pipeline produced for one processed frame.
/// One frame → one sample → one CSV row (per-device column sets).
struct RecordingSample: Sendable {
    /// Monotonic frame timestamp (same clock as `Measurement.timestamp`).
    let timestamp: TimeInterval
    /// Keyed by `Device.id`.
    let readings: [UUID: Measurement]
}

/// A live recording in progress. Rejected readings are stored alongside
/// accepted ones — they are never silently deleted (spec §17/§25).
@MainActor @Observable
final class RecordingSession {
    let id = UUID()
    /// Wall-clock start, for session metadata only (sequencing uses the
    /// monotonic sample timestamps).
    let startedAt = Date()

    private(set) var samples: [RecordingSample] = []
    private(set) var firstTimestamp: TimeInterval?
    private(set) var lastTimestamp: TimeInterval?
    /// Count of accepted individual readings across all devices.
    private(set) var acceptedCount = 0
    /// Count of rejected individual readings across all devices.
    private(set) var rejectedCount = 0
    /// Most recent rejection, used to drive the "✕ REJECTED — …" flash chip.
    private(set) var lastRejection: (timestamp: TimeInterval, reason: RejectionReason)?

    var sampleCount: Int { samples.count }

    /// Elapsed recording time derived from monotonic frame timestamps.
    var elapsed: TimeInterval {
        guard let firstTimestamp, let lastTimestamp else { return 0 }
        return max(0, lastTimestamp - firstTimestamp)
    }

    func append(_ result: FrameResult) {
        if firstTimestamp == nil { firstTimestamp = result.timestamp }
        lastTimestamp = result.timestamp
        samples.append(RecordingSample(timestamp: result.timestamp, readings: result.readings))
        for reading in result.readings.values {
            if reading.accepted {
                acceptedCount += 1
            } else {
                rejectedCount += 1
                if let reason = reading.rejectionReason {
                    lastRejection = (result.timestamp, reason)
                }
            }
        }
    }

    /// Values of recently accepted readings for one device, oldest→newest —
    /// drives the live sparkline in the recording strip.
    func recentAcceptedValues(for deviceID: UUID, limit: Int = 80) -> [Double] {
        var values: [Double] = []
        for sample in samples.suffix(limit * 2) {
            if let m = sample.readings[deviceID], m.accepted, m.value.isFinite {
                values.append(m.value)
            }
        }
        return Array(values.suffix(limit))
    }

    /// Immutable snapshot handed to the results screen and CSV exporter.
    func finish(devices: [Device]) -> CompletedSession {
        CompletedSession(id: id,
                         startedAt: startedAt,
                         endedAt: Date(),
                         devices: devices,
                         samples: samples,
                         firstTimestamp: firstTimestamp,
                         lastTimestamp: lastTimestamp)
    }
}
