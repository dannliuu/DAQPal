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

    // ROI auto-tracking (spec §15 "ROI Tracking", minimal form): each accepted
    // reading reports where its text actually sat in the frame; the window is
    // nudged toward that center so small camera/display shake doesn't lose the
    // lock. Damped and dead-banded so OCR bounding-box jitter can't make the
    // window wander; the window's size is never changed, only its position.
    /// Fraction of the center error corrected per processed frame.
    static let trackingGain: CGFloat = 0.3
    /// Center errors below this (normalized units) are ignored as jitter.
    static let trackingDeadband: CGFloat = 0.004
    /// Maximum normalized movement per axis per processed frame.
    static let trackingMaxStep: CGFloat = 0.02

    // MARK: Devices & live state

    var devices: [Device] {
        didSet { syncProcessorConfig() }
    }
    private(set) var liveReadings: [UUID: LiveReading] = [:]
    private(set) var debugText: String?
    /// Raw-OCR debug overlay toggle (Milestone 2 validation aid).
    var showDebugOverlay = false
    /// ROI auto-tracking on accepted readings (see tracking constants above).
    var roiTrackingEnabled = true
    /// True while the user is actively dragging/resizing an ROI window —
    /// auto-tracking pauses so it never fights the gesture.
    var isEditingROI = false

    // MARK: Session / navigation

    private(set) var uiMode: UIMode = .selectingROI
    private(set) var activeRecording: RecordingSession?
    var completedSession: CompletedSession?
    /// Device whose format sheet is open (README `sheetFor`).
    var formatSheetDeviceID: UUID?
    var showResults = false
    /// Presents the offline video-import flow (spec §21, Milestone 12 slice).
    var showVideoImport = false

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
    private var configSyncTask: Task<Void, Never>?
    private var lastPushedConfigs: [DeviceRecognitionConfig]?

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

        if roiTrackingEnabled && !isEditingROI {
            applyROITracking(result)
        }

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
        // Names must stay unique across removals — they drive CSV column
        // prefixes — so continue past the highest existing DMM-n rather than
        // deriving the index from the current count (remove DMM-1, add ⇒
        // a second "DMM-2" and duplicate CSV columns).
        let usedIndices = devices.compactMap { device -> Int? in
            device.name.split(separator: "-").last.flatMap { Int($0) }
        }
        let index = max(usedIndices.max() ?? 0, devices.count) + 1
        let device = Device.makeDefault(index: index)
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

    /// Nudges each locked device's window toward where its accepted reading's
    /// text was actually observed this frame. Single `devices` assignment so
    /// the config push and UI update happen once per frame at most.
    private func applyROITracking(_ result: FrameResult) {
        var updated = devices
        var changed = false
        for index in updated.indices {
            let device = updated[index]
            guard let roi = device.roi,
                  result.readings[device.id]?.accepted == true,
                  let observed = result.observedROIs[device.id] else { continue }
            let errorX = (observed.x + observed.width / 2) - (roi.x + roi.width / 2)
            let errorY = (observed.y + observed.height / 2) - (roi.y + roi.height / 2)
            var dx = errorX * Self.trackingGain
            var dy = errorY * Self.trackingGain
            guard abs(dx) > Self.trackingDeadband || abs(dy) > Self.trackingDeadband else { continue }
            dx = max(-Self.trackingMaxStep, min(Self.trackingMaxStep, dx))
            dy = max(-Self.trackingMaxStep, min(Self.trackingMaxStep, dy))
            var moved = roi
            moved.x += dx
            moved.y += dy
            updated[index].roi = moved.clamped()
            changed = true
        }
        if changed { devices = updated }
    }

    /// Pushes the current device configuration into the pipeline actor.
    ///
    /// Coalesced: ROI drags call this per gesture tick, so no-op pushes are
    /// skipped and a superseded in-flight push is cancelled — at most one push
    /// is pending, and the final state always wins because `update` replaces
    /// the whole device set.
    private func syncProcessorConfig() {
        guard let processor else { return }
        let configs = devices.compactMap { device in
            device.roi.map {
                DeviceRecognitionConfig(id: device.id, roi: $0, format: device.displayFormat)
            }
        }
        guard configs != lastPushedConfigs else { return }
        lastPushedConfigs = configs
        configSyncTask?.cancel()
        configSyncTask = Task {
            guard !Task.isCancelled else { return }
            await processor.update(devices: configs)
        }
    }
}
