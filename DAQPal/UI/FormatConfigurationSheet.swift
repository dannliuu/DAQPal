//
//  FormatConfigurationSheet.swift
//  DAQPal
//
//  Display-format bottom sheet (design handoff §2, spec §10 Mode 2 —
//  user-configured format). Edits write straight through to `AppState` so the
//  live readings panel and pattern preview update together; there is no local
//  draft state to discard/commit.
//

import SwiftUI

struct FormatConfigurationSheet: View {
    @Environment(AppState.self) private var appState
    let deviceID: UUID

    init(deviceID: UUID) {
        self.deviceID = deviceID
    }

    var body: some View {
        Group {
            if let device = appState.device(withID: deviceID) {
                sheetContent(device)
            } else {
                // The device was removed (e.g. context-menu delete) while its
                // sheet was open — nothing left to configure, close it.
                Color.clear
                    .onAppear { appState.formatSheetDeviceID = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(18)
        .presentationBackground(Theme.chrome)
    }

    // MARK: Layout

    private func sheetContent(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(device)
            patternPreview(device)
            formatRow(label: "DIGITS") { digitsControl(device) }
            formatRow(label: "DECIMAL AFTER DIGIT") { decimalStepper(device) }
            formatRow(label: "SIGN (±)") { signToggle(device) }
            formatRow(label: "UNIT") { unitControl(device) }
            formatRow(label: "VALID RANGE") { rangeStepper(device) }
            doneButton
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .background(Theme.chrome)
    }

    private func header(_ device: Device) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Display format — \(device.name)")
                    .font(Theme.ui(13, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                Text("\(modelLabel(device)) · Mode 2 — user-configured format")
                    .font(Theme.ui(10, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            closeButton
        }
    }

    private var closeButton: some View {
        Button {
            appState.formatSheetDeviceID = nil
        } label: {
            Text("✕")
                .font(Theme.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.heavyRule, lineWidth: 1))
                // Visual chip stays small (per handoff); grow the tap target
                // to the required ≥44 pt without affecting layout.
                .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close display format sheet")
    }

    private func patternPreview(_ device: Device) -> some View {
        Text(device.displayFormat.patternPreview)
            .font(Theme.mono(24, weight: .semibold))
            .tracking(2)
            .foregroundStyle(Theme.brandYellow)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
            .accessibilityLabel("Pattern preview \(device.displayFormat.patternPreview)")
    }

    private func formatRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            SectionLabel(text: label, color: Theme.ink)
            Spacer(minLength: 12)
            content()
        }
    }

    private var doneButton: some View {
        Button {
            appState.formatSheetDeviceID = nil
        } label: {
            Text("DONE — RESUME CONSTRAINED OCR")
                .font(Theme.ui(12, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Done, resume constrained OCR")
    }

    // MARK: Rows

    private func digitsControl(_ device: Device) -> some View {
        SegmentedChoice(options: [4, 5, 6], selection: device.displayFormat.digitCount, label: { String($0) }) { newCount in
            adjust(device) { format in
                format.digitCount = newCount
                let currentDecimal = format.decimalPosition ?? 1
                format.decimalPosition = min(currentDecimal, newCount - 1)
            }
        }
    }

    private func decimalStepper(_ device: Device) -> some View {
        let digits = device.displayFormat.digitCount
        let decimal = device.displayFormat.decimalPosition ?? 1
        return HStack(spacing: 10) {
            stepButton("−", enabled: decimal > 1) {
                adjust(device) { $0.decimalPosition = max(1, decimal - 1) }
            }
            Text("\(decimal)")
                .font(Theme.mono(14, weight: .semibold))
                .frame(minWidth: 16)
                .multilineTextAlignment(.center)
            stepButton("+", enabled: decimal < digits - 1) {
                adjust(device) { $0.decimalPosition = min(digits - 1, decimal + 1) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Decimal after digit \(decimal)")
    }

    private func signToggle(_ device: Device) -> some View {
        let allowed = device.displayFormat.signAllowed
        return Button {
            adjust(device) { $0.signAllowed.toggle() }
        } label: {
            Text(allowed ? "ALLOWED" : "OFF")
                .font(Theme.ui(10, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(allowed ? Theme.brandYellow : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 5).fill(allowed ? Theme.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -8))
        .accessibilityLabel("Sign")
        .accessibilityValue(allowed ? "Allowed" : "Off")
    }

    private func unitControl(_ device: Device) -> some View {
        SegmentedChoice(options: ["V", "A", "Ω", "°C", "Hz"], selection: device.displayFormat.unit ?? "V", label: { $0 }) { newUnit in
            adjust(device) { $0.unit = newUnit }
        }
    }

    /// Min/max steppers, ±5 per tap. Outward moves (min↓, max↑) are always
    /// allowed; inward moves (min↑, max↓) are clamped to keep `min < max`
    /// with at least a 5-unit gap (mirrors the design prototype's logic).
    private func rangeStepper(_ device: Device) -> some View {
        let format = device.displayFormat
        let unit = format.unit ?? ""
        let minValue = format.minimumValue ?? -20
        let maxValue = format.maximumValue ?? 20
        return HStack(spacing: 6) {
            stepButton("−") { adjust(device) { $0.minimumValue = minValue - 5 } }
            Text(rangeValueString(minValue, unit: unit))
            stepButton("+") { adjust(device) { $0.minimumValue = min(maxValue - 5, minValue + 5) } }
            Text("to").foregroundStyle(Theme.inkMuted)
            stepButton("−") { adjust(device) { $0.maximumValue = max(minValue + 5, maxValue - 5) } }
            Text(rangeValueString(maxValue, unit: unit))
            stepButton("+") { adjust(device) { $0.maximumValue = maxValue + 5 } }
        }
        .font(Theme.mono(11, weight: .semibold))
    }

    private func stepButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(Theme.ui(13, weight: .heavy))
                .foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.35))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .contentShape(Rectangle().inset(by: -9))
    }

    // MARK: Helpers

    private func modelLabel(_ device: Device) -> String {
        let trimmed = device.model.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Manual" : trimmed
    }

    private func rangeValueString(_ value: Double, unit: String) -> String {
        let numeric = value == value.rounded() ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return unit.isEmpty ? numeric : "\(numeric) \(unit)"
    }

    /// Writes an edited copy of `device.displayFormat` straight through to
    /// `AppState` — the sheet has no local draft, so `patternPreview` and the
    /// live readings panel stay in lockstep with every tap.
    private func adjust(_ device: Device, _ mutate: (inout DisplayFormat) -> Void) {
        var updated = device
        mutate(&updated.displayFormat)
        appState.updateDevice(updated)
    }
}

/// Custom segmented control (per handoff: not `UISegmentedControl`) — a row
/// of chips where the selected one is ink-filled with yellow text.
private struct SegmentedChoice<Value: Hashable>: View {
    let options: [Value]
    let selection: Value
    let label: (Value) -> String
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    select(option)
                } label: {
                    Text(label(option))
                        .font(Theme.ui(11, weight: .heavy))
                        .foregroundStyle(isSelected ? Theme.brandYellow : Theme.ink)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.ink : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle().inset(by: -8))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}
