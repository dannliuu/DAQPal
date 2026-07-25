//
//  RecordingControlsView.swift
//  DAQPal
//
//  Capture-screen footer (record button, elapsed time, rate meta) and the
//  recording strip (elapsed/sample counters + live sparkline), shown only
//  while `appState.activeRecording` is non-nil (design handoff "Capture"
//  screen).
//

import SwiftUI

// MARK: - Footer

/// Bottom bar on `Theme.chrome`: elapsed chip, primary record button, and
/// measured-rate meta. Always mounted (unlike the recording strip).
struct RecordingControlsView: View {
    @Environment(AppState.self) private var appState
    @State private var dotDimmed = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            elapsedChip
            saveVideoToggleChip
            recordButton
            Spacer(minLength: 6)
            metaColumn
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }

    private var elapsedChip: some View {
        Text(elapsedText)
            .font(Theme.mono(12, weight: .semibold))
            .foregroundStyle(appState.isRecording ? Theme.brandYellow : Theme.ink)
            .frame(minWidth: 64)
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(appState.isRecording ? Theme.ink : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(appState.isRecording ? Color.clear : Theme.heavyRule, lineWidth: 1)
            )
            .accessibilityLabel("Elapsed recording time \(elapsedText)")
    }

    private var elapsedText: String {
        formatElapsed(appState.activeRecording?.elapsed ?? 0)
    }

    /// Mirrors the header's "OCR" debug-toggle chip styling (outlined when
    /// off, dark fill + yellow text when on). Locked while recording — the
    /// tee is armed once at `startRecording()`, so changing the toggle
    /// mid-session wouldn't do anything until the next session anyway.
    private var saveVideoToggleChip: some View {
        Button {
            appState.saveVideoEnabled.toggle()
        } label: {
            Text("VIDEO")
                .font(Theme.ui(9, weight: .heavy))
                .tracking(0.54)
                .lineLimit(1)
                .fixedSize()
                // Dimming matches the header IMPORT chip's disabled pattern:
                // foreground opacity only, not the whole chip.
                .foregroundStyle((appState.saveVideoEnabled ? Theme.brandYellow : Theme.ink)
                    .opacity(appState.isRecording ? 0.35 : 1))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(appState.saveVideoEnabled ? Theme.ink : Color.clear)
                )
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.heavyRule, lineWidth: 1))
                // Chip stays visually compact; the negative inset expands the
                // tap area to the required ≥44 pt.
                .contentShape(Rectangle().inset(by: -13))
        }
        .buttonStyle(.plain)
        .disabled(appState.isRecording)
        .accessibilityLabel("Toggle save video")
        .accessibilityValue(appState.saveVideoEnabled ? "On" : "Off")
    }

    private var recordButton: some View {
        Button {
            if appState.isRecording {
                appState.stopRecording()
            } else {
                appState.startRecording()
            }
        } label: {
            HStack(spacing: 6) {
                // Only the leading glyph pulses, matching the design's "1s
                // opacity loop on the red dot" while recording.
                Text(appState.isRecording ? "■" : "●")
                    .opacity(appState.isRecording && dotDimmed ? 0.35 : 1)
                Text(appState.isRecording ? "STOP" : "REC")
            }
            .font(Theme.ui(13, weight: .heavy))
            .tracking(0.65)
            .lineLimit(1)
            // The label must never wrap into a vertical letter stack when the
            // footer row gets tight — it wins the space fight instead.
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(appState.isRecording ? Theme.recordActiveRed : Theme.recordRed)
            )
        }
        .buttonStyle(.plain)
        .layoutPriority(1)
        .accessibilityLabel("DAQPal record button")
        .accessibilityValue(appState.isRecording ? "Recording, tap to stop" : "Tap to start recording")
        .onAppear { syncPulse() }
        .onChange(of: appState.isRecording) { _, _ in syncPulse() }
    }

    private func syncPulse() {
        guard appState.isRecording else {
            dotDimmed = false
            return
        }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            dotDimmed = true
        }
    }

    private var metaColumn: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("CAM \(rateText(appState.captureFrameRate)) FPS")
            Text("OCR \(rateText(appState.processedFPS))/S")
        }
        .font(Theme.ui(9, weight: .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Theme.inkMuted)
        .accessibilityElement(children: .combine)
    }

    /// "—" when the rate is not yet known — the footer never hard-codes the
    /// prototype's fixed 240/30 values (project rule).
    private func rateText(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(Int(value.rounded()))
    }
}

// MARK: - Recording strip

/// Dark strip shown only while recording: pulsing REC indicator, elapsed
/// time, sample/rejected counters, a rejection flash chip, and a 2-series
/// sparkline of the most recently accepted values.
struct RecordingStripView: View {
    @Environment(AppState.self) private var appState
    let session: RecordingSession

    @State private var dotDimmed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // TimelineView keeps the elapsed readout and rejection-flash
            // window ticking smoothly between pipeline-driven sample
            // updates, independent of the OCR processing rate.
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                statusRow
            }
            sparkline
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.recordingStrip)
        .onAppear {
            withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                dotDimmed = true
            }
        }
    }

    private var devices: [Device] { appState.devices }

    private var statusRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle()
                    .fill(Theme.roiSearching)
                    .frame(width: 8, height: 8)
                    .opacity(dotDimmed ? 0.3 : 1)
                Text("REC")
                    .foregroundStyle(Theme.roiSearching)
            }
            Text(formatElapsed(session.elapsed))
                .foregroundStyle(Theme.chrome)
            Text("\(session.sampleCount) SAMPLES")
                .foregroundStyle(Theme.chrome.opacity(0.6))
            Text("\(session.rejectedCount) REJ")
                .foregroundStyle(Theme.rejectedCountText)
            if appState.videoSaveStatus == .recording {
                Text("● VIDEO")
                    .foregroundStyle(Theme.spark2)
            }
            Spacer(minLength: 6)
            if showRejectionFlash {
                rejectionFlashChip
            }
        }
        .font(Theme.mono(10, weight: .semibold))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var showRejectionFlash: Bool {
        guard let rejection = session.lastRejection else { return false }
        let now = session.lastTimestamp ?? rejection.timestamp
        return now - rejection.timestamp < 1.2
    }

    private var rejectionFlashChip: some View {
        Text("✕ REJECTED — \(session.lastRejection?.reason.displayLabel ?? "")")
            .font(Theme.ui(9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            // Reuses the design's rejected-red (#8A2A12) as a solid fill,
            // matching the flash chip's background in the handoff.
            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.searchingChipForeground))
            .lineLimit(1)
            .transition(.opacity)
    }

    private var sparkline: some View {
        Canvas { context, size in
            let seriesDevices = Array(devices.prefix(2))
            let colors: [Color] = [Theme.spark1, Theme.spark2]
            let widths: [CGFloat] = [1.5, 1.2]
            for (index, device) in seriesDevices.enumerated() {
                drawSpark(in: &context,
                         size: size,
                         values: session.recentAcceptedValues(for: device.id, limit: 80),
                         color: colors[index],
                         lineWidth: widths[index])
            }
        }
        .frame(height: 34)
        .accessibilityHidden(true)
    }

    private func drawSpark(in context: inout GraphicsContext, size: CGSize, values: [Double], color: Color, lineWidth: CGFloat) {
        guard values.count >= 2 else { return }
        let pad: CGFloat = 4
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 0
        let range = max(maxValue - minValue, 1e-6)
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
            let normalized = (value - minValue) / range
            let y = size.height - pad - CGFloat(normalized) * (size.height - 2 * pad)
            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }
}

// MARK: - Shared formatting

private func formatElapsed(_ interval: TimeInterval) -> String {
    let clamped = max(0, interval)
    let minutes = Int(clamped) / 60
    let seconds = clamped - Double(minutes * 60)
    return String(format: "%02d:%04.1f", minutes, seconds)
}
