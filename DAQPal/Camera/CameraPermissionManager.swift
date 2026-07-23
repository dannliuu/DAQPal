//
//  CameraPermissionManager.swift
//  DAQPal
//

import AVFoundation
import Observation

/// Wraps camera authorization (spec §40.5, Milestone 1) so `CaptureStack` can
/// drive the `.requestingPermission` → `.denied`/`.configuring` transitions
/// from one place.
@MainActor @Observable
final class CameraPermissionManager {
    private(set) var status: AVAuthorizationStatus

    init() {
        status = AVCaptureDevice.authorizationStatus(for: .video)
    }

    var isAuthorized: Bool { status == .authorized }

    /// Prompts when authorization is undetermined; otherwise resolves from the
    /// current status. Returns whether capture may proceed.
    func requestAccess() async -> Bool {
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .authorized
    }
}
