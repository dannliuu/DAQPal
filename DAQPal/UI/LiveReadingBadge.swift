//
//  LiveReadingBadge.swift
//  DAQPal
//
//  Capture-screen "LIVE READINGS" panel: a responsive grid of per-device
//  reading cards (design handoff "Capture" screen, live readings panel).
//

import SwiftUI

/// One-or-two-column grid of `DeviceReadingCard`s on `Theme.chrome`.
struct LiveReadingsPanel: View {
    @Environment(AppState.self) private var appState

    private var columns: [GridItem] {
        let count = appState.devices.count > 1 ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 10), count: count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "LIVE READINGS")
                Spacer(minLength: 8)
                Text("Apple Vision OCR · constrained")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(appState.devices) { device in
                    DeviceReadingCard(device: device,
                                      liveReading: appState.liveReadings[device.id] ?? .empty)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .background(Theme.chrome)
    }
}

/// A single device's card: label + format button, big mono value, confidence
/// bar, and a LOCKED/SEARCHING status chip.
private struct DeviceReadingCard: View {
    @Environment(AppState.self) private var appState
    let device: Device
    let liveReading: LiveReading

    private var format: DisplayFormat { device.displayFormat }
    private var isLocked: Bool { liveReading.locked }
    private var confidence: Float { max(0, min(1, liveReading.confidence)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(subtitle)
                    .font(Theme.ui(9, weight: .heavy))
                    .tracking(0.7)
                    .foregroundStyle(Theme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                formatButton
            }
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(valueText)
                    .font(Theme.mono(24, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit = format.unit, !unit.isEmpty {
                    Text(unit)
                        .font(Theme.ui(12, weight: .heavy))
                        .foregroundStyle(Theme.ink)
                }
            }
            HStack(spacing: 6) {
                confidenceBar
                Text(confidenceText)
                    .font(Theme.ui(9, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                statusChip
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
        .contextMenu {
            Button(role: .destructive) {
                appState.removeDevice(id: device.id)
            } label: {
                Label("Remove \(device.name)", systemImage: "trash")
            }
            .disabled(appState.devices.count <= 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var subtitle: String {
        let unit = format.unit ?? ""
        return unit.isEmpty ? device.name : "\(device.name) · \(unit) DC"
    }

    /// `patternPreview` with the trailing " <unit>" suffix stripped
    /// (contract: "shows displayFormat.patternPreview sans unit is fine").
    private var patternSansUnit: String {
        var pattern = format.patternPreview
        if let unit = format.unit, !unit.isEmpty, pattern.hasSuffix(" \(unit)") {
            pattern.removeLast(unit.count + 1)
        }
        return pattern
    }

    private var formatButton: some View {
        Button {
            appState.formatSheetDeviceID = device.id
        } label: {
            Text("⚙ \(patternSansUnit)")
                .font(Theme.ui(10, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.ink.opacity(0.3), lineWidth: 1))
                // Expands the tap target toward 44pt without growing the
                // visually compact chip (matches the header chip pattern).
                .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open display format settings for \(device.name)")
    }

    private var valueText: String {
        guard isLocked, let value = liveReading.value else { return format.placeholder }
        return format.formatted(value)
    }

    private var confidenceText: String {
        String(format: "%.1f%%", confidence * 100)
    }

    private var confidenceBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.hairline)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.brandYellow)
                    .frame(width: geo.size.width * CGFloat(confidence))
            }
        }
        .frame(height: 3)
    }

    private var statusChip: some View {
        Text(isLocked ? "LOCKED" : "SEARCHING")
            .font(Theme.ui(8, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(isLocked ? Theme.lockedChipForeground : Theme.searchingChipForeground)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(isLocked ? Theme.lockedChipBackground : Theme.searchingChipBackground)
            )
    }

    private var accessibilitySummary: String {
        let statusWord = isLocked ? "locked" : "searching"
        let pct = String(format: "%.1f", confidence * 100)
        let valuePart = isLocked ? "reading \(valueText) \(format.unit ?? "")" : "no reading yet"
        return "\(device.name), \(statusWord), \(pct) percent confidence, \(valuePart)"
    }
}
