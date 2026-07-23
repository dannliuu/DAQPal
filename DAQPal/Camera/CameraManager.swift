//
//  CameraManager.swift
//  DAQPal
//

// AVCaptureSession/AVCaptureDevice predate Sendable auditing; the whole point
// of this type is to hop session configuration to a private queue, which is
// Apple's documented safe-usage pattern for these types.
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Observation

/// Owns the `AVCaptureSession` lifecycle (spec §40.5, Milestone 1): back
/// wide-angle camera at 1920×1080 into a BGRA video data output whose
/// connection is rotated to portrait, so every buffer that reaches the
/// pipeline is upright and normalized ROI space == buffer space.
///
/// All session mutation (configure/start/stop) happens on a private serial
/// queue — never on the main thread and never during SwiftUI view updates.
@MainActor @Observable
final class CameraManager {

    enum ConfigurationError: LocalizedError {
        case cameraUnavailable
        case inputRejected
        case outputRejected

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: "No back camera is available on this device."
            case .inputRejected: "The camera input could not be added to the capture session."
            case .outputRejected: "The video output could not be added to the capture session."
            }
        }
    }

    let session = AVCaptureSession()
    /// Delegate-backed frame source; `CaptureStack` wires it into the pipeline.
    let frameSource = LiveCameraFrameSource()

    /// Oriented (portrait) pixel dimensions of delegate buffers, e.g. 1080×1920.
    private(set) var videoDimensions: CGSize?
    /// Configured capture frame rate in frames/s.
    private(set) var frameRate: Double?

    private weak var appState: AppState?
    private var isConfigured = false

    private let sessionQueue = DispatchQueue(label: "DAQPal.CameraManager.session")
    private let sampleBufferQueue = DispatchQueue(label: "DAQPal.CameraManager.sampleBuffer")

    init(appState: AppState) {
        self.appState = appState
    }

    /// Configures the session on the session queue, then publishes the
    /// oriented dimensions and frame rate to `AppState` back on the MainActor.
    func configure() async throws {
        guard !isConfigured else { return }
        let session = self.session
        let delegate = self.frameSource
        let sampleBufferQueue = self.sampleBufferQueue
        let (dimensions, rate): (CGSize, Double) = try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    continuation.resume(returning: try Self.performConfiguration(
                        session: session,
                        delegate: delegate,
                        sampleBufferQueue: sampleBufferQueue))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        isConfigured = true
        videoDimensions = dimensions
        frameRate = rate
        appState?.videoDimensions = dimensions
        appState?.captureFrameRate = rate
    }

    func start() {
        let session = self.session
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        let session = self.session
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    // MARK: Configuration (session queue)

    /// Runs on `sessionQueue`; touches no MainActor state.
    private nonisolated static func performConfiguration(
        session: AVCaptureSession,
        delegate: LiveCameraFrameSource,
        sampleBufferQueue: DispatchQueue
    ) throws -> (dimensions: CGSize, frameRate: Double) {
        let (camera, rotatedToPortrait) = try configureSession(session: session,
                                                              delegate: delegate,
                                                              sampleBufferQueue: sampleBufferQueue)

        // Read the active format only after the configuration has been
        // committed, when the preset has been applied to the device.
        let native = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let dimensions = rotatedToPortrait
            ? CGSize(width: CGFloat(native.height), height: CGFloat(native.width))
            : CGSize(width: CGFloat(native.width), height: CGFloat(native.height))

        let minFrameDuration = camera.activeVideoMinFrameDuration
        let frameRate: Double
        if minFrameDuration.isValid, minFrameDuration.seconds > 0 {
            frameRate = (1.0 / minFrameDuration.seconds).rounded()
        } else {
            frameRate = camera.activeFormat.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
        }
        return (dimensions, frameRate)
    }

    private nonisolated static func configureSession(
        session: AVCaptureSession,
        delegate: LiveCameraFrameSource,
        sampleBufferQueue: DispatchQueue
    ) throws -> (camera: AVCaptureDevice, rotatedToPortrait: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Idempotent across retries after a failed attempt.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video,
                                                   position: .back) else {
            throw ConfigurationError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw ConfigurationError.inputRejected }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: sampleBufferQueue)
        guard session.canAddOutput(output) else { throw ConfigurationError.outputRejected }
        session.addOutput(output)

        // Portrait-upright buffers at the source: downstream, normalized ROI
        // space == buffer space (project-wide invariant).
        var rotatedToPortrait = false
        if let connection = output.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            rotatedToPortrait = true
        }
        return (camera, rotatedToPortrait)
    }
}
