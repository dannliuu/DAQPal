//
//  CameraCaptureScreen.swift
//  DAQPal
//
//  Root capture screen (design handoff §"Capture"): header, camera viewport
//  with per-device ROI overlay, recording strip, live readings panel, footer.
//  Always mounted — results and format configuration present *over* this
//  screen so the capture session is never torn down by navigation (spec §40.1).
//

import AVFoundation
import SwiftUI
import UIKit

struct CameraCaptureScreen: View {
    @Environment(AppState.self) private var appState
    let captureStack: CaptureStack

    init(captureStack: CaptureStack) {
        self.captureStack = captureStack
    }

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 0) {
            CaptureHeaderView()
            rule
            viewport
            if let session = appState.activeRecording {
                RecordingStripView(session: session)
            }
            rule
            LiveReadingsPanel()
            RecordingControlsView()
        }
        .background(Theme.chrome.ignoresSafeArea())
        .sheet(item: formatSheetTarget) { target in
            FormatConfigurationSheet(deviceID: target.id)
        }
        .fullScreenCover(isPresented: $appState.showResults) {
            ResultsView()
        }
    }

    // MARK: Viewport

    private var isCapturing: Bool {
        captureStack.status == .running || captureStack.status == .simulated
    }

    private var viewport: some View {
        ZStack {
            Theme.cameraArea
            viewportContent
            if isCapturing {
                ROISelectionOverlay()
            }
        }
        .clipped()
        .overlay(alignment: .top) {
            if captureStack.status == .simulated {
                syntheticSourceChip
            }
        }
        .overlay(alignment: .bottom) { bottomCaptions }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var viewportContent: some View {
        switch captureStack.status {
        case .running:
            CameraPreviewView(session: captureStack.cameraManager.session)
        case .simulated:
            if let image = captureStack.simulatedPreviewImage {
                // Aspect-fill to match the live preview's gravity, so the
                // AspectFillMapper-driven ROI overlay lines up in both modes.
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
            } else {
                startingIndicator
            }
        case .denied:
            CameraPermissionDeniedView()
        case .failed(let message):
            CaptureFailureView(message: message)
        case .idle, .requestingPermission, .configuring:
            startingIndicator
        }
    }

    private var startingIndicator: some View {
        VStack(spacing: 14) {
            ViewportBrandMark()
            ProgressView()
                .tint(.white.opacity(0.7))
            SectionLabel(text: "STARTING CAMERA", color: .white.opacity(0.45))
        }
    }

    private var syntheticSourceChip: some View {
        Text("SYNTHETIC SOURCE — SIMULATOR")
            .font(Theme.ui(8, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(Theme.brandYellow)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityLabel("Synthetic source. Simulator preview, not a real camera.")
    }

    private var bottomCaptions: some View {
        VStack(spacing: 6) {
            if appState.showDebugOverlay {
                Text(appState.debugText ?? "—")
                    .font(Theme.mono(10))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.55)))
                    .accessibilityLabel("Raw OCR debug output")
            }
            if isCapturing && needsAlignmentHint {
                Text("DRAG A WINDOW ONTO A DISPLAY TO LOCK OCR")
                    .font(Theme.ui(9, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .allowsHitTesting(false)
    }

    private var needsAlignmentHint: Bool {
        appState.devices.contains { appState.liveReadings[$0.id]?.locked != true }
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.heavyRule)
            .frame(height: 2)
    }

    // MARK: Format sheet presentation

    private var formatSheetTarget: Binding<FormatSheetTarget?> {
        Binding(
            get: { appState.formatSheetDeviceID.map { FormatSheetTarget(id: $0) } },
            set: { appState.formatSheetDeviceID = $0?.id }
        )
    }
}

/// `sheet(item:)` needs `Identifiable`; `UUID` is not, so the presented device
/// id is wrapped in this trivial box.
private struct FormatSheetTarget: Identifiable {
    let id: UUID
}

/// Branded DAQPAL mark shown by the non-preview viewport states.
struct ViewportBrandMark: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("DAQPAL")
                .font(Theme.ui(15, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Theme.brandYellow)
            SectionLabel(text: "VISUAL DATA ACQUISITION", size: 8, color: .white.opacity(0.55))
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CameraPermissionDeniedView: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 16) {
            ViewportBrandMark()
            Text("DAQPal reads instrument displays through the camera.\nCamera access is currently denied — enable it in Settings to capture measurements.")
                .font(Theme.ui(12))
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            } label: {
                Text("OPEN SETTINGS")
                    .font(Theme.ui(13, weight: .heavy))
                    .tracking(0.65)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 30)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Settings to grant DAQPal camera access")
        }
    }
}

private struct CaptureFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ViewportBrandMark()
            SectionLabel(text: "CAMERA UNAVAILABLE", color: Theme.roiSearching)
            Text(message)
                .font(Theme.mono(11))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}
