//
//  CameraPreview.swift
//  DAQPal
//

import AVFoundation
import SwiftUI

/// Hosts an `AVCaptureVideoPreviewLayer` for the live camera feed. Purely
/// visual: no gestures, no callbacks. `CameraManager` owns the session
/// lifecycle; this view only ever observes it.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.orientPreviewToPortrait()
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        uiView.orientPreviewToPortrait()
    }
}

/// `UIView` whose backing `CALayer` is the preview layer itself
/// (`layerClass` override), so the layer's frame tracks the view's bounds
/// automatically with no manual layout code.
final class CameraPreviewUIView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            preconditionFailure("CameraPreviewUIView.layerClass must be AVCaptureVideoPreviewLayer")
        }
        return layer
    }

    /// Rotates the *preview* connection to match the portrait-upright
    /// convention buffers already use at the source (`CameraManager`).
    func orientPreviewToPortrait() {
        guard let connection = videoPreviewLayer.connection,
              connection.isVideoRotationAngleSupported(90) else { return }
        connection.videoRotationAngle = 90
    }
}
