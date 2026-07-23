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
final class CaptureStack {
    private(set) var status: CaptureStatus = .idle
    let cameraManager: CameraManager
    let processor: MeasurementProcessor
    /// Simulator only: latest synthetic frame rendered for the viewport.
    private(set) var simulatedPreviewImage: UIImage?

    private let appState: AppState
    private let permissionManager = CameraPermissionManager()
    private var frameProcessor: FrameProcessor?

    init(appState: AppState) {
        let processor = MeasurementProcessor()
        self.processor = processor
        self.cameraManager = CameraManager(appState: appState)
        self.appState = appState
        appState.processor = processor
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
                                            appState: appState)
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

        let synthetic = SyntheticFrameSource(fps: 12)
        let previewTapped = SimulatorPreviewFrameSource(base: synthetic) { [weak self] frame in
            let image = Self.previewImage(from: frame.pixelBuffer)
            await MainActor.run {
                self?.simulatedPreviewImage = image
            }
        }

        let frameProcessor = FrameProcessor(source: previewTapped, processor: processor, appState: appState)
        self.frameProcessor = frameProcessor
        frameProcessor.start()
        status = .simulated
    }

    /// Off-main-safe conversion; `CIContext` is documented thread-safe for
    /// concurrent use, so this can run on the frame-consuming background task
    /// without hopping to the main actor first.
    nonisolated private static func previewImage(from pixelBuffer: CVPixelBuffer) -> UIImage? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = simulatorPreviewContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
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
