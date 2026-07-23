//
//  CaptureHeaderView.swift
//  DAQPal
//
//  Capture-screen app bar: profile, device-count, OCR-debug, import and
//  add-device chips (design handoff header). The DAQPAL wordmark/subtitle
//  block was dropped here to give the chip row the full header width — the
//  brand still appears in the viewport's placeholder states
//  (`ViewportBrandMark`), so it isn't lost, just not duplicated. The OCR chip
//  is the Milestone 2 raw-text validation toggle.
//

import SwiftUI

struct CaptureHeaderView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Chips render at their natural width and the row scrolls when they
        // can't all fit — truncated labels ("MAN…") read as broken. No
        // longer capped to a trailing-aligned strip now that there's no
        // wordmark sharing the header: the row spans the full width.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                profileChip
                deviceCountChip
                debugToggleChip
                importChip
                if appState.devices.count < AppState.maxDevices {
                    addDeviceChip
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }

    /// First device's instrument model, or the MVP's manual-format fallback.
    private var profileChip: some View {
        let model = appState.devices.first?.model.trimmingCharacters(in: .whitespaces) ?? ""
        return chipText(model.isEmpty ? "MANUAL" : model.uppercased())
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

    /// Offline video import (normal or slow-motion) — disabled mid-recording
    /// because a finished import replaces the completed-session/results state.
    private var importChip: some View {
        Button {
            appState.showVideoImport = true
        } label: {
            chipText("IMPORT")
                .foregroundStyle(Theme.ink.opacity(appState.isRecording ? 0.35 : 1))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.heavyRule, lineWidth: 1))
                .contentShape(Rectangle().inset(by: -13))
        }
        .buttonStyle(.plain)
        .disabled(appState.isRecording)
        .accessibilityLabel("Import a recorded video of an instrument display")
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
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}
