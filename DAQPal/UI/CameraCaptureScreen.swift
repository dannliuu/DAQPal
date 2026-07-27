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
        .fullScreenCover(isPresented: $appState.showVideoImport, onDismiss: {
            // A finished import requests results while its own cover is still
            // presented; SwiftUI drops that present. Re-assert it once this
            // cover has fully dismissed so the results screen appears.
            if appState.showResults {
                appState.showResults = false
                Task { @MainActor in appState.showResults = true }
            }
        }) {
            VideoImportView()
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
                // Acquisition geometry and field curation draw *under* the
                // manual ROI overlay: the user's own windows stay the topmost,
                // directly manipulable layer regardless of what the tracker is
                // doing. Both are mounted unconditionally (rather than gated on
                // `screenLockEnabled`/`lockedTarget` here) so this body never
                // reads the frame-rate `lockedTarget` — each renders nothing on
                // its own when the intelligent path is off or unlocked.
                ScreenGeometryLayer()
                FieldSelectionOverlay()
                ROISelectionOverlay()
            }
        }
        .clipped()
        .overlay(alignment: .top) {
            if captureStack.status == .simulated {
                syntheticSourceChip
            }
        }
        // Top-leading and top-trailing, so neither collides with the
        // top-centered SYNTHETIC chip or the bottom captions.
        .overlay(alignment: .topLeading) { ScreenLockStatusStrip() }
        .overlay(alignment: .topTrailing) { debugHUD }
        .overlay(alignment: .bottom) { bottomCaptions }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pipeline metrics HUD, behind the existing OCR/debug toggle.
    private var debugHUD: some View {
        DebugHUDContainer()
            .padding(.top, 8)
            .padding(.trailing, 8)
    }

    @ViewBuilder
    private var viewportContent: some View {
        switch captureStack.status {
        case .running:
            CameraPreviewView(session: captureStack.cameraManager.session)
        case .simulated:
            if captureStack.hasPreviewFrame {
                // Layer-backed, aspect-fill to match the live preview's
                // gravity so the AspectFillMapper-driven ROI overlay lines up
                // in both modes. Frames arrive via `previewRelay` directly
                // into the CALayer — no SwiftUI invalidation per frame.
                SimulatedPreviewView(relay: captureStack.previewRelay)
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

    /// Tapping cycles the synthetic display's motion pattern (steady → yaw →
    /// pitch → roll → tumble → bounce) — a stress-test rig for ROI tracking.
    private var syntheticSourceChip: some View {
        Button {
            captureStack.cycleDemoMotion()
        } label: {
            Text("SYNTHETIC — MOTION: \(captureStack.demoMotion.displayLabel)")
                .font(Theme.ui(8, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(Theme.brandYellow)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
                // Compact chip; negative inset expands the tap area toward
                // the required ≥44 pt (header-chip pattern).
                .contentShape(Rectangle().inset(by: -12))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel("Synthetic source, Simulator preview, not a real camera. Motion pattern \(captureStack.demoMotion.displayLabel).")
        .accessibilityHint("Tap to cycle the display motion pattern")
    }

    /// The two per-frame-updating captions live in their own leaf views so
    /// their observable reads (`debugText`, `liveReadings`) invalidate only
    /// those small views — putting the reads here would re-evaluate the whole
    /// screen's body at frame rate (the ROI drag-lag root cause).
    private var bottomCaptions: some View {
        VStack(spacing: 6) {
            DebugCaptionView()
            if isCapturing {
                AlignmentHintView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
        .allowsHitTesting(false)
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

/// Mounts `TargetGeometryOverlay` with the live tracked quad and candidate
/// proposals. Isolated for the same reason the captions are: `lockedTarget` and
/// `screenCandidates` are rewritten on every processed frame, so reading them
/// in the capture screen's body would invalidate the whole screen at frame rate
/// (ARCHITECTURE.md §2). Renders nothing while the intelligent path is off.
private struct ScreenGeometryLayer: View {
    @Environment(AppState.self) private var appState

    /// Same fallback as the ROI/field overlays so all three agree on the aspect
    /// ratio before the first frame publishes `videoDimensions`.
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        if appState.screenLockEnabled {
            GeometryReader { geo in
                TargetGeometryOverlay(quad: appState.lockedTarget?.quad,
                                      candidates: appState.screenCandidates,
                                      snapState: appState.snapState,
                                      mapper: AspectFillMapper(contentSize: appState.videoDimensions ?? Self.fallbackContentSize,
                                                               containerSize: geo.size))
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

/// Acquisition-state strip (MANUAL → CANDIDATE → ATTRACTING → SNAP PREVIEW →
/// LOCKED → DEGRADED → REACQUIRING). Isolated so a state transition re-renders
/// only this chip. `snapState` is change-gated in `AppState.applyScreenLock`,
/// so this does not churn per frame.
private struct ScreenLockStatusStrip: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.screenLockEnabled {
            let state = appState.snapState
            Text(state.displayLabel)
                .font(Theme.ui(8, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(state.isLockedOrTracking ? Theme.brandYellow : .white.opacity(0.7))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
                .padding(.top, 8)
                .padding(.leading, 8)
                .allowsHitTesting(false)
                .accessibilityLabel("Screen lock state")
                .accessibilityValue(state.displayLabel)
        }
    }
}

/// Gates `PipelineDebugOverlay` behind the existing debug toggle without the
/// capture screen's body reading `showDebugOverlay`.
private struct DebugHUDContainer: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.showDebugOverlay {
            PipelineDebugOverlay()
        }
    }
}

/// Raw-OCR debug caption. Isolated so its per-frame `debugText` read
/// invalidates only this view, never the capture screen's body.
private struct DebugCaptionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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
    }
}

/// "Drag a window…" hint. Isolated for the same reason: its `liveReadings`
/// read updates every processed frame.
private struct AlignmentHintView: View {
    @Environment(AppState.self) private var appState

    private var needsAlignmentHint: Bool {
        appState.devices.contains { appState.liveReadings[$0.id]?.locked != true }
    }

    var body: some View {
        if needsAlignmentHint {
            Text("DRAG A WINDOW ONTO A DISPLAY TO LOCK OCR")
                .font(Theme.ui(9, weight: .semibold))
                .tracking(1.1)
                .foregroundStyle(.white.opacity(0.45))
        }
    }
}

/// Layer-backed Simulator preview: frames arrive through `PreviewFrameRelay`
/// straight into `layer.contents`, bypassing SwiftUI diffing entirely. This
/// replaced a per-frame `Image(uiImage:)` rebuild of a 1080×1920 bitmap that
/// competed with gesture handling on the main thread.
private struct SimulatedPreviewView: UIViewRepresentable {
    let relay: PreviewFrameRelay

    func makeUIView(context: Context) -> PreviewContentUIView {
        let view = PreviewContentUIView()
        view.attach(relay)
        return view
    }

    func updateUIView(_ uiView: PreviewContentUIView, context: Context) {
        uiView.attach(relay)
    }
}

final class PreviewContentUIView: UIView {
    private weak var relay: PreviewFrameRelay?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Idempotent — `updateUIView` calls this on every SwiftUI update pass.
    func attach(_ relay: PreviewFrameRelay) {
        guard self.relay !== relay else { return }
        self.relay = relay
        relay.sink = { [weak self] image in
            self?.layer.contents = image
        }
        if let latest = relay.latest {
            layer.contents = latest
        }
    }
}

/// Branded DAQPAL mark shown by the non-preview viewport states.
struct ViewportBrandMark: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("DAQPAL")
                .font(Theme.ui(15, weight: .heavy))
                .tracking(Theme.wordmarkTracking)
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
