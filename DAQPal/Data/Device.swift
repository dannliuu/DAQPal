//
//  Device.swift
//  DAQPal
//

import Foundation
import CoreGraphics

/// One measurement source: a physical instrument display the user has framed
/// with an ROI window. The device list is dynamic (1...n devices).
struct Device: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    /// Short label shown on the ROI window and reading card, e.g. "DMM-1".
    var name: String
    /// Free-form instrument model shown in the header profile chip,
    /// e.g. "FLUKE 87V". Empty when unspecified.
    var model: String
    var displayFormat: DisplayFormat
    /// Confirmed ROI in normalized oriented-image space; nil until the user
    /// places the window.
    var roi: NormalizedROI?

    var unit: String? { displayFormat.unit }

    /// CSV column prefix, e.g. "DMM-1" → "dmm1" (README CSV schema).
    var columnPrefix: String {
        let sanitized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return sanitized.isEmpty ? "dev\(id.uuidString.prefix(4).lowercased())" : sanitized
    }

    static func makeDefault(index: Int) -> Device {
        Device(id: UUID(),
               name: "DMM-\(index)",
               model: "",
               displayFormat: .defaultDMM,
               roi: nil)
    }
}

/// Live, per-device recognition state driving the capture UI
/// (reading card value, confidence bar, LOCKED/SEARCHING chip).
struct LiveReading: Equatable, Sendable {
    /// Last accepted value (kept while locked so the readout doesn't flicker
    /// on single rejected frames); nil when nothing has been accepted yet.
    var value: Double?
    var unit: String?
    /// Confidence of the most recent reading (accepted or not).
    var confidence: Float
    /// True while the pipeline is currently producing valid readings for this
    /// device (an accepted reading within `AppState.lockTimeout`).
    var locked: Bool
    /// Whether the most recent reading was accepted.
    var accepted: Bool
    /// Timestamp of the most recent reading.
    var lastTimestamp: TimeInterval?

    static let empty = LiveReading(value: nil, unit: nil, confidence: 0,
                                   locked: false, accepted: false, lastTimestamp: nil)
}

/// Immutable snapshot of what the processing pipeline needs to know about one
/// device. `AppState` pushes these into `MeasurementProcessor` whenever the
/// device list changes; only devices with a confirmed ROI are included.
struct DeviceRecognitionConfig: Equatable, Sendable {
    let id: UUID
    let roi: NormalizedROI
    let format: DisplayFormat
}
