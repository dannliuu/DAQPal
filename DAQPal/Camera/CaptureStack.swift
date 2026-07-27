//
//  CaptureStack.swift
//  DAQPal
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Observation
import UIKit

/// Coarse capture lifecycle state surfaced to the UI (README capture screen:
/// permission gate, configuring spinner, live viewport, Simulator synthetic
/// banner, failure message).
enum CaptureStatus: Equatable {
    case idle
    case requestingPermission
    case denied
    case configuring
    case running
    case simulated
    case failed(String)
}

/// Owns the whole capture pipeline lifecycle end to end (spec §40.1,
/// Milestone 1–2): permission → camera configuration → frame pump →
/// recognition pipeline. Created once by `RootView` and never torn down.
///
/// On the Simulator (no camera hardware), `start()` substitutes
/// `SyntheticFrameSource` for the live camera so the full pipeline —
/// recognition, validation, recording, results, CSV — is exercisable without
/// a device. The synthetic frames also drive `simulatedPreviewImage` so the
/// viewport shows exactly what the pipeline is processing; the capture UI is
/// responsible for labeling this clearly as synthetic, never real-DMM data.
@MainActor @Observable
final class CaptureStack: VideoRecordingCoordinating {
    private(set) var status: CaptureStatus = .idle
    let cameraManager: CameraManager
    let processor: MeasurementProcessor
    /// Simulator only: flips true once the first synthetic frame has rendered,
    /// switching the viewport from the "starting" placeholder to the preview.
    /// Deliberately a one-shot Bool — the frames themselves flow through
    /// `previewRelay` straight into a `CALayer`, *outside* SwiftUI observation,
    /// so a 1080×1920 image update no longer invalidates any view body at
    /// frame rate (the main source of ROI drag lag in the Simulator).
    private(set) var hasPreviewFrame = false
    /// Frame conduit for the Simulator preview layer (`let` of reference type
    /// — not observation-tracked, by design).
    let previewRelay = PreviewFrameRelay()
    /// Motion pattern applied to the Simulator's synthetic display — a
    /// stress-test rig for ROI tracking (yaw/pitch/roll/bounce).
    private(set) var demoMotion: DemoMotion = .steady

    /// The intelligent screen-locking stage, created once and shared by every
    /// capture mode (live, synthetic). Idle until `AppState.screenLockEnabled`.
    let lockPipeline = ScreenLockPipeline()

    private let appState: AppState
    private let permissionManager = CameraPermissionManager()
    private var frameProcessor: FrameProcessor?
    @ObservationIgnored private var syntheticSource: SyntheticFrameSource?
    /// Optional session video tee, armed by `beginVideoCapture()`.
    private let recorder = SessionVideoRecorder()

    init(appState: AppState) {
        let processor = MeasurementProcessor()
        self.processor = processor
        self.cameraManager = CameraManager(appState: appState)
        self.appState = appState
        appState.processor = processor
        appState.videoRecordingCoordinator = self
        appState.lockPipeline = lockPipeline
    }

    /// Permission → configure → run on device; synthetic pipeline in the
    /// Simulator (no camera hardware to request permission for).
    func start() async {
#if targetEnvironment(simulator)
        startSimulated()
#else
        await startLive()
#endif
    }

    func stop() {
        frameProcessor?.stop()
        frameProcessor = nil
        cameraManager.stop()
    }

    // MARK: Demo motion (Simulator stress rig)

    /// Applies a synthetic-display motion pattern. Safe to call before
    /// `start()` — the pending value seeds the frame source when it's built —
    /// and live mid-stream (the source reads it per frame). No-op wiring on
    /// device builds, where there is no synthetic source.
    func setDemoMotion(_ motion: DemoMotion) {
        demoMotion = motion
        syntheticSource?.setMotion(motion)
    }

    /// Cycles to the next motion pattern (tap target: the SYNTHETIC chip).
    func cycleDemoMotion() {
        setDemoMotion(demoMotion.next)
    }

    // MARK: VideoRecordingCoordinating

    /// Arms the recorder and starts teeing capture frames into it. Called by
    /// `AppState.startRecording()` only when the "SAVE VIDEO" toggle is on.
    func beginVideoCapture() {
        recorder.start()
#if targetEnvironment(simulator)
        // The synthetic frame pump already tees frames into `recorder` (see
        // `startSimulated`); those appends were no-ops until `start()` armed
        // the recorder just now, so there is nothing else to install here.
#else
        // Hook the capture-queue tap so every delivered frame reaches the
        // recorder upstream of the OCR stream's `.bufferingNewest(1)` drop.
        cameraManager.frameSource.frameTap = { [recorder] frame in
            recorder.append(frame)
        }
#endif
        appState.videoSaveStatus = .recording
    }

    /// Removes the tap and finalizes the recording. Always called by
    /// `AppState.stopRecording()`; a no-op when the recorder was never armed
    /// (the toggle was off at REC time).
    func endVideoCapture(saveToPhotos: Bool) {
#if !targetEnvironment(simulator)
        cameraManager.frameSource.frameTap = nil
#endif
        guard recorder.isArmed else { return }

        appState.videoSaveStatus = .saving
        Task { @MainActor [appState, recorder] in
            switch await recorder.finish() {
            case .success(let url):
                if saveToPhotos {
                    do {
                        try await PhotoLibrarySaver.save(videoURL: url)
                        appState.videoSaveStatus = .saved
                    } catch {
                        appState.videoSaveStatus = .failed(error.localizedDescription)
                    }
                } else {
                    appState.videoSaveStatus = .idle
                }
                // Temp file has served its purpose (copied to Photos, or the
                // user didn't want it kept) — remove it either way.
                try? FileManager.default.removeItem(at: url)
            case .failure(let error):
                // finish() already removed any partial temp file.
                appState.videoSaveStatus = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Device capture

    private func startLive() async {
        status = .requestingPermission
        let granted = await permissionManager.requestAccess()
        guard granted else {
            status = .denied
            return
        }

        status = .configuring
        do {
            try await cameraManager.configure()
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let frameProcessor = FrameProcessor(source: cameraManager.frameSource,
                                            processor: processor,
                                            appState: appState,
                                            lockPipeline: lockPipeline)
        self.frameProcessor = frameProcessor
        // Subscribe before starting the session so no early frame is missed.
        frameProcessor.start()
        cameraManager.start()
        status = .running
    }

    // MARK: Simulator

    private func startSimulated() {
        appState.videoDimensions = CGSize(width: 1080, height: 1920)
        appState.captureFrameRate = 12

        let synthetic = SyntheticFrameSource(fps: 12, motion: demoMotion)
        syntheticSource = synthetic
        let previewTapped = SimulatorPreviewFrameSource(base: synthetic) { [weak self] frame in
            // Tee synthetic frames into the recorder too (a no-op until REC
            // arms it) so the video-save feature is exercisable end to end in
            // the Simulator without camera hardware. `recorder` is a Sendable
            // `let`, so this off-main access needs no MainActor hop.
            self?.recorder.append(frame)
            let image = Self.previewImage(from: frame.pixelBuffer)
            await MainActor.run {
                guard let self, let image else { return }
                if !self.hasPreviewFrame { self.hasPreviewFrame = true }
                self.previewRelay.publish(image)
            }
        }

        let frameProcessor = FrameProcessor(source: previewTapped,
                                            processor: processor,
                                            appState: appState,
                                            lockPipeline: lockPipeline)
        self.frameProcessor = frameProcessor
        frameProcessor.start()
        status = .simulated
    }

    /// Off-main-safe conversion; `CIContext` is documented thread-safe for
    /// concurrent use, so this can run on the frame-consuming background task
    /// without hopping to the main actor first.
    nonisolated private static func previewImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return simulatorPreviewContext.createCGImage(ciImage, from: ciImage.extent)
    }
}

/// Hands preview frames from the capture stack to whatever layer-backed view
/// is currently showing them, entirely outside SwiftUI observation — updating
/// a `CALayer.contents` is a cheap Core Animation commit, vs. the previous
/// design where an `@Observable UIImage?` invalidated the whole capture
/// screen's body on every frame.
@MainActor
final class PreviewFrameRelay {
    /// Most recent frame, so a view attaching mid-stream paints immediately.
    private(set) var latest: CGImage?
    /// The currently-attached view's consumer. At most one; reassigning
    /// replaces the previous consumer (only one preview view exists at a time).
    var sink: ((CGImage) -> Void)?

    func publish(_ image: CGImage) {
        latest = image
        sink?(image)
    }
}

/// Shared render context for the Simulator's `CVPixelBuffer` → `UIImage`
/// preview conversion. Not actor-isolated: `CIContext` is safe for concurrent
/// use per Apple's documentation, and this is only ever touched off-main.
private let simulatorPreviewContext = CIContext()

/// Wraps a `FrameSource`, invoking `onFrame` for every frame before
/// forwarding it downstream unchanged. Lets `CaptureStack` drive
/// `simulatedPreviewImage` from the exact frames the recognition pipeline
/// processes, rather than running a second, independently-timed renderer.
private final class SimulatorPreviewFrameSource: FrameSource {
    private let base: any FrameSource
    private let onFrame: (TimestampedFrame) async -> Void

    init(base: any FrameSource, onFrame: @escaping (TimestampedFrame) async -> Void) {
        self.base = base
        self.onFrame = onFrame
    }

    func frames() -> AsyncStream<TimestampedFrame> {
        let base = self.base
        let onFrame = self.onFrame
        return AsyncStream { continuation in
            let task = Task {
                for await frame in base.frames() {
                    await onFrame(frame)
                    continuation.yield(frame)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
