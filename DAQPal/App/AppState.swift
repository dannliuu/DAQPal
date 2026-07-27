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

/// Lifecycle of the optional session video recording (REC tee → Photos).
enum VideoSaveStatus: Equatable, Sendable {
    case idle
    /// Frames are being teed into the asset writer alongside live OCR.
    case recording
    /// Writer finishing / Photos save in flight after STOP.
    case saving
    case saved
    case failed(String)
    /// Video capture isn't available in the current capture mode.
    case unavailable
}

/// Implemented by the capture stack: owns the asset-writer tee on the capture
/// pipeline. `AppState` drives it from `startRecording`/`stopRecording` so the
/// single REC button controls both measurements and (optionally) video.
@MainActor
protocol VideoRecordingCoordinating: AnyObject {
    func beginVideoCapture()
    func endVideoCapture(saveToPhotos: Bool)
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

    // MARK: Intelligent screen locking (spec Gate 14)

    /// Master switch for the intelligent pipeline. OFF by default: manual ROI
    /// placement stays the shipping default until the tracked path is validated
    /// on physical hardware, and the spec's own principle 10 makes manual the
    /// fallback rather than the exception.
    var screenLockEnabled = false {
        didSet { pushScreenLockEnabled() }
    }
    /// Live acquisition state, published for the overlay.
    private(set) var snapState: SnapState = .manual
    private(set) var lockedTarget: TrackedTarget?
    private(set) var screenCandidates: [ScreenCandidate] = []
    /// Fields found on the locked display, plus the user's selections.
    private(set) var fieldCatalog: ScreenFieldCatalog?
    /// Set once by the capture stack at startup.
    @ObservationIgnored weak var lockPipeline: ScreenLockPipeline?

    /// Devices whose ROI comes from tracked geometry rather than a stored
    /// value. These MUST receive a per-frame override or be skipped — reading
    /// their placeholder ROI would report a value from whatever happens to be
    /// at that fixed location.
    var fieldBackedDeviceIDs: Set<UUID> {
        guard let catalog = fieldCatalog else { return [] }
        return Set(catalog.fields.filter { $0.isSelected && $0.kind == .numeric }.map(\.id))
    }

    /// Inputs the frame loop reads from the UI once per frame.
    struct ScreenLockInputs: Sendable {
        var selection: ScreenQuad?
        var isUserDragging: Bool
        var fieldBackedDeviceIDs: Set<UUID>
    }

    /// Snapshot of what the pipeline needs from the UI side. Cheap and
    /// allocation-free; called once per frame from the drain loop.
    func screenLockInputs() -> ScreenLockInputs {
        // The manual selection seed is the first device with a STORED roi — a
        // field-backed device has none and must never be offered as the
        // acquisition seed.
        let manualSeed = devices.first { $0.roi != nil }?.roi
        return ScreenLockInputs(selection: manualSeed.map { ScreenQuad(roi: $0) },
                                isUserDragging: isEditingROI,
                                fieldBackedDeviceIDs: fieldBackedDeviceIDs)
    }

    /// Publishes one frame of pipeline output. Every write is change-gated for
    /// the same reason `apply(_:)`'s are: this runs at frame rate, and an
    /// ungated write would invalidate the capture screen on every frame (see
    /// ARCHITECTURE.md §2).
    func applyScreenLock(_ update: ScreenLockUpdate) {
        guard !update.isIdle else {
            if snapState != .manual { snapState = .manual }
            if lockedTarget != nil { lockedTarget = nil }
            if !screenCandidates.isEmpty { screenCandidates = [] }
            return
        }

        if snapState != update.snapState { snapState = update.snapState }
        if lockedTarget != update.target { lockedTarget = update.target }
        if screenCandidates != update.candidates { screenCandidates = update.candidates }

        if let analyzed = update.analyzedFields, let target = update.target {
            var catalog = fieldCatalog?.targetID == target.id
                ? (fieldCatalog ?? ScreenFieldCatalog(targetID: target.id))
                : ScreenFieldCatalog(targetID: target.id)
            catalog.merge(analyzed, at: Date().timeIntervalSinceReferenceDate)
            fieldCatalog = catalog
            pushSelectedFields()
        }

        if update.didRelease {
            fieldCatalog = nil
            syncFieldDevices()
            pushSelectedFields()
        }
    }

    /// Toggles a field's capture selection and pushes the change to the
    /// pipeline. Selected fields also become recordable devices so the whole
    /// existing recording/CSV/results stack applies unchanged.
    func toggleFieldSelection(_ fieldID: UUID) {
        // Deselecting mid-recording would remove that field's device, and its
        // already-captured samples would vanish from the finished session —
        // the same data-loss guard `removeDevice` carries.
        guard !isRecording else { return }
        guard var catalog = fieldCatalog,
              let index = catalog.fields.firstIndex(where: { $0.id == fieldID }) else { return }
        let willSelect = !catalog.fields[index].isSelected
        // Respect the device cap: selected fields become devices, so selecting
        // past the cap would silently exceed the limit the "+ ADD" chip enforces.
        if willSelect, devices.count >= Self.maxDevices { return }
        catalog.fields[index].isSelected.toggle()
        fieldCatalog = catalog
        syncFieldDevices()
        pushSelectedFields()
    }

    /// True when selecting one more field would exceed the device cap — lets
    /// the overlay dim unselected fields rather than silently ignoring taps.
    var canSelectAnotherField: Bool { devices.count < Self.maxDevices }

    /// Requests a fresh analysis pass of the locked display.
    func reanalyzeLockedScreen() {
        guard let pipeline = lockPipeline else { return }
        Task { await pipeline.requestAnalysis() }
    }

    /// Drops the lock and returns to manual acquisition.
    func releaseScreenLock() {
        guard let pipeline = lockPipeline else { return }
        fieldCatalog = nil
        lockedTarget = nil
        snapState = .manual
        syncFieldDevices()
        pushSelectedFields()
        Task { await pipeline.release() }
    }

    /// Mirrors selected fields into `devices` so recording, CSV export and the
    /// results screen work on them with no changes at all: a field's UUID is
    /// its device id, and its per-frame ROI arrives as a pipeline override.
    ///
    /// Field-backed devices carry a nil `roi` deliberately — their geometry is
    /// not a stored property but a per-frame projection of the tracked target,
    /// so storing one would go stale the instant the display moved.
    private func syncFieldDevices() {
        // A nil catalog means the lock is gone, which must still REMOVE the
        // devices its fields created — early-returning here orphaned them,
        // leaving phantom cards that could never produce a reading again.
        guard let catalog = fieldCatalog else {
            devices.removeAll { knownFieldDeviceIDs.contains($0.id) }
            knownFieldDeviceIDs = []
            return
        }
        let selected = catalog.fields.filter { $0.isSelected && $0.kind == .numeric }
        let selectedIDs = Set(selected.map(\.id))

        // Drop devices for fields that are no longer selected. Tracked by the
        // ids this method actually created, so a re-analysis that changes the
        // catalog can never strand a device it no longer knows about.
        devices.removeAll { knownFieldDeviceIDs.contains($0.id) && !selectedIDs.contains($0.id) }
        knownFieldDeviceIDs = selectedIDs

        for (index, field) in selected.enumerated() where !devices.contains(where: { $0.id == field.id }) {
            devices.append(Device(id: field.id,
                                  name: field.displayName(index: index),
                                  model: "",
                                  displayFormat: field.format,
                                  roi: nil))
        }
    }

    private func pushSelectedFields() {
        guard let pipeline = lockPipeline else { return }
        let fields = fieldCatalog?.fields ?? []
        Task { await pipeline.setSelectedFields(fields) }
    }

    private func pushScreenLockEnabled() {
        guard let pipeline = lockPipeline else { return }
        let enabled = screenLockEnabled
        if !enabled {
            fieldCatalog = nil
            lockedTarget = nil
            snapState = .manual
            screenCandidates = []
            syncFieldDevices()
        }
        Task { await pipeline.setEnabled(enabled) }
    }

    // MARK: Session video recording

    /// "SAVE VIDEO" toggle: when on, REC also tees capture frames into an
    /// `.mov` saved to Photos on STOP. Off by default — writing 1080p video
    /// during live OCR costs storage/battery, and a saved session doubles as a
    /// re-processable fixture (spec §30), so it's an explicit choice.
    var saveVideoEnabled = false
    /// Written by the capture stack as the recording/saving progresses.
    var videoSaveStatus: VideoSaveStatus = .idle
    /// Set once by the capture stack at startup.
    weak var videoRecordingCoordinator: (any VideoRecordingCoordinating)?

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
    /// Un-observed rolling rate; `processedFPS` is published from this only
    /// when its *displayed* (rounded) value changes, so the footer isn't
    /// re-rendered every frame by measurement jitter.
    @ObservationIgnored private var rawProcessedFPS: Double = 0
    /// Device ids created from selected fields. Tracked explicitly so removal
    /// never depends on a catalog that may already have been cleared.
    @ObservationIgnored private var knownFieldDeviceIDs: Set<UUID> = []

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
    ///
    /// Every observable write below is change-gated. This runs at frame rate,
    /// and each ungated assignment invalidates every view reading that
    /// property — the original per-frame writes re-rendered the whole capture
    /// screen 12–30×/s, which is what made ROI drags feel laggy (gesture
    /// handling shares the main thread with all that re-rendering).
    func apply(_ result: FrameResult) {
        // Only meaningful while the raw-OCR overlay is visible; skip the
        // per-frame write (and its view invalidation) otherwise.
        if showDebugOverlay, debugText != result.debugText {
            debugText = result.debugText
        }

        // A device is "active" when it has somewhere to read from. That is a
        // stored ROI for a manually placed device, OR field-backing for a
        // device whose ROI arrives per frame from tracked geometry. Testing
        // `roi != nil` alone silently discarded every field-backed reading
        // *after* the processor had already computed it.
        let fieldBacked = fieldBackedDeviceIDs
        for device in devices {
            let previous = liveReadings[device.id]
            var reading: LiveReading
            if device.roi == nil && !fieldBacked.contains(device.id) {
                reading = .empty
            } else {
                reading = previous ?? .empty
                if let m = result.readings[device.id] {
                    if m.accepted {
                        lastAcceptedAt[device.id] = m.timestamp
                        if m.value.isFinite { reading.value = m.value }
                    }
                    reading.unit = m.unit ?? device.unit
                    reading.confidence = m.confidence
                    reading.accepted = m.accepted
                }
                let lastAccepted = lastAcceptedAt[device.id]
                reading.locked = lastAccepted.map { result.timestamp - $0 <= Self.lockTimeout } ?? false
                if !reading.locked { reading.value = nil }
            }
            if reading != previous {
                liveReadings[device.id] = reading
            }
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
            rawProcessedFPS = Double(recentFrameTimestamps.count - 1) / (result.timestamp - first)
            // The footer shows this rounded to an integer — publish only when
            // that integer changes.
            if Int(rawProcessedFPS.rounded()) != Int(processedFPS.rounded()) {
                processedFPS = rawProcessedFPS
            }
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
        videoSaveStatus = .idle
        if saveVideoEnabled {
            videoRecordingCoordinator?.beginVideoCapture()
        }
    }

    func stopRecording() {
        guard let session = activeRecording else { return }
        completedSession = session.finish(devices: devices)
        activeRecording = nil
        uiMode = .reviewingResults
        showResults = true
        // Always end capture — a no-op when video wasn't being recorded.
        videoRecordingCoordinator?.endVideoCapture(saveToPhotos: saveVideoEnabled)
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
        // Samples for a removed device would vanish from the session — removal waits until STOP.
        guard !isRecording else { return }
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
        let fieldBacked = fieldBackedDeviceIDs
        let configs = devices.compactMap { device -> DeviceRecognitionConfig? in
            if let roi = device.roi {
                return DeviceRecognitionConfig(id: device.id, roi: roi, format: device.displayFormat)
            }
            // A field-backed device has no STORED roi — its geometry is a
            // per-frame projection of the tracked target. Filtering on
            // `roi != nil` would drop it from the processor's config set
            // entirely, so the per-frame override would have no config to apply
            // to and selecting a field would silently never produce a reading.
            // It is registered here with a placeholder that is never actually
            // recognized against: `process(frame:roiOverrides:requiringOverride:)`
            // skips any device in `requiringOverride` that has no override this
            // frame.
            guard fieldBacked.contains(device.id) else { return nil }
            return DeviceRecognitionConfig(id: device.id,
                                           roi: .defaultROI,
                                           format: device.displayFormat)
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
