//
//  CaptureHeaderView.swift
//  DAQPal
//
//  Capture-screen app bar: DAQPAL wordmark + subtitle on the left; profile,
//  device-count, OCR-debug and add-device chips on the right (design handoff
//  header; the OCR chip is the Milestone 2 raw-text validation toggle).
//

import SwiftUI

struct CaptureHeaderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DAQPAL")
                    .font(Theme.ui(15, weight: .heavy))
                    .tracking(-0.15)
                    .foregroundStyle(Theme.ink)
                SectionLabel(text: "VISUAL DATA ACQUISITION", size: 8)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                profileChip
                deviceCountChip
                debugToggleChip
                if appState.devices.count < AppState.maxDevices {
                    addDeviceChip
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }

    /// First device's instrument model, or the MVP's manual-format fallback.
    private var profileChip: some View {
        let model = appState.devices.first?.model.trimmingCharacters(in: .whitespaces) ?? ""
        return chipText(model.isEmpty ? "MANUAL FORMAT" : model.uppercased())
            .foregroundStyle(Theme.ink)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.heavyRule, lineWidth: 1))
            .accessibilityLabel(model.isEmpty ? "Instrument profile: manual format" : "Instrument profile: \(model)")
    }

    private var deviceCountChip: some View {
        let count = appState.devices.count
        return chipText(count == 1 ? "1 DEVICE" : "\(count) DEVICES")
            .foregroundStyle(Theme.brandYellow)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
            .accessibilityLabel("\(count) configured \(count == 1 ? "device" : "devices")")
    }

    private var debugToggleChip: some View {
        Button {
            appState.showDebugOverlay.toggle()
        } label: {
            chipText("OCR")
                .foregroundStyle(appState.showDebugOverlay ? Theme.brandYellow : Theme.ink)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(appState.showDebugOverlay ? Theme.ink : Color.clear)
                )
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.heavyRule, lineWidth: 1))
                // Chip stays visually compact; the negative inset expands the
                // tap area to the required ≥44 pt.
                .contentShape(Rectangle().inset(by: -13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle raw OCR debug overlay")
        .accessibilityValue(appState.showDebugOverlay ? "On" : "Off")
    }

    private var addDeviceChip: some View {
        Button {
            appState.addDevice()
        } label: {
            chipText("+ ADD")
                .foregroundStyle(Theme.ink)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.heavyRule, lineWidth: 1))
                .contentShape(Rectangle().inset(by: -13))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add device")
    }

    private func chipText(_ text: String) -> some View {
        Text(text)
            .font(Theme.ui(9, weight: .heavy))
            .tracking(0.54)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}
