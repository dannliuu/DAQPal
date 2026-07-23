//
//  AppState.swift
//  DAQPal
//
//  Single source of truth for UI-visible state (spec §40.2).
//  Only ever touched on the MainActor — the background pipeline produces
//  `FrameResult` values and hops to main to call `apply(_:)`.
//

import Foundation
import CoreGraphics
import Observation

enum UIMode: Equatable, Sendable {
    case selectingROI
    case live
    case recording
    case reviewingResults
}

@MainActor @Observable
final class AppState {
    /// How long after the last accepted reading a device stays "locked".
    static let lockTimeout: TimeInterval = 1.0
    /// Maximum devices in the MVP UI.
    static let maxDevices = 4

    // MARK: Devices & live state

    var devices: [Device] {
        didSet { syncProcessorConfig() }
    }
    private(set) var liveReadings: [UUID: LiveReading] = [:]
    private(set) var debugText: String?
    /// Raw-OCR debug overlay toggle (Milestone 2 validation aid).
    var showDebugOverlay = false

    // MARK: Session / navigation

    private(set) var uiMode: UIMode = .selectingROI
    private(set) var activeRecording: RecordingSession?
    var completedSession: CompletedSession?
    /// Device whose format sheet is open (README `sheetFor`).
    var formatSheetDeviceID: UUID?
    var showResults = false

    // MARK: Capture metadata

    /// Oriented content size of the incoming frames (e.g. 1080×1920); feeds
    /// `AspectFillMapper` for ROI ↔ screen conversion.
    var videoDimensions: CGSize?
    /// Configured camera capture frame rate, for the footer meta line.
    var captureFrameRate: Double?
    /// Measured pipeline processing rate (readings/s), rolling estimate.
    private(set) var processedFPS: Double = 0

    /// Set once at startup by the capture stack; device-config changes are
    /// pushed into it so the pipeline never reads UI state directly.
    var processor: MeasurementProcessor? {
        didSet { syncProcessorConfig() }
    }

    private var recentFrameTimestamps: [TimeInterval] = []
    private var lastAcceptedAt: [UUID: TimeInterval] = [:]

    init(devices: [Device] = [.makeDefault(index: 1)]) {
        self.devices = devices
        syncProcessorConfig()
    }

    var isRecording: Bool { activeRecording != nil }

    func device(withID id: UUID) -> Device? {
        devices.first { $0.id == id }
    }

    // MARK: Pipeline output

    /// Publishes one processed frame's results to the UI and, when recording,
    /// appends it to the active session. MainActor-only by construction.
    func apply(_ result: FrameResult) {
        debugText = result.debugText

        for device in devices {
            guard device.roi != nil else {
                liveReadings[device.id] = .empty
                continue
            }
            var reading = liveReadings[device.id] ?? .empty
            if let m = result.readings[device.id] {
                if m.accepted {
                    lastAcceptedAt[device.id] = m.timestamp
                    if m.value.isFinite { reading.value = m.value }
                }
                reading.unit = m.unit ?? device.unit
                reading.confidence = m.confidence
                reading.accepted = m.accepted
                reading.lastTimestamp = m.timestamp
            }
            let lastAccepted = lastAcceptedAt[device.id]
            reading.locked = lastAccepted.map { result.timestamp - $0 <= Self.lockTimeout } ?? false
            if !reading.locked { reading.value = nil }
            liveReadings[device.id] = reading
        }

        activeRecording?.append(result)

        // Rolling processing-rate estimate over the last 2 s of frames.
        recentFrameTimestamps.append(result.timestamp)
        recentFrameTimestamps.removeAll { result.timestamp - $0 > 2.0 }
        if recentFrameTimestamps.count >= 2,
           let first = recentFrameTimestamps.first,
           result.timestamp > first {
            processedFPS = Double(recentFrameTimestamps.count - 1) / (result.timestamp - first)
        }

        if uiMode == .selectingROI, devices.contains(where: { $0.roi != nil }) {
            uiMode = .live
        }
    }

    // MARK: Recording

    func startRecording() {
        guard activeRecording == nil else { return }
        completedSession = nil
        activeRecording = RecordingSession()
        uiMode = .recording
    }

    func stopRecording() {
        guard let session = activeRecording else { return }
        completedSession = session.finish(devices: devices)
        activeRecording = nil
        uiMode = .reviewingResults
        showResults = true
    }

    /// "NEW SESSION" on the results screen: back to live capture, keeping
    /// devices, ROIs and formats.
    func newSession() {
        completedSession = nil
        showResults = false
        uiMode = devices.contains(where: { $0.roi != nil }) ? .live : .selectingROI
    }

    // MARK: Device management

    @discardableResult
    func addDevice() -> Device? {
        guard devices.count < Self.maxDevices else { return nil }
        let device = Device.makeDefault(index: devices.count + 1)
        devices.append(device)
        return device
    }

    func removeDevice(id: UUID) {
        guard devices.count > 1 else { return }
        devices.removeAll { $0.id == id }
        liveReadings[id] = nil
        lastAcceptedAt[id] = nil
    }

    func updateDevice(_ device: Device) {
        guard let idx = devices.firstIndex(where: { $0.id == device.id }) else { return }
        devices[idx] = device
    }

    // MARK: Private

    /// Pushes the current device configuration into the pipeline actor.
    private func syncProcessorConfig() {
        guard let processor else { return }
        let configs = devices.compactMap { device in
            device.roi.map {
                DeviceRecognitionConfig(id: device.id, roi: $0, format: device.displayFormat)
            }
        }
        Task { await processor.update(devices: configs) }
    }
}
