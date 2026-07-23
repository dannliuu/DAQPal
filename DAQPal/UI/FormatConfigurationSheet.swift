//
//  FormatConfigurationSheet.swift
//  DAQPal
//
//  Display-format bottom sheet (design handoff §2, spec §10). Devices start
//  unconstrained (Mode 3 — free numeric extraction, spec §10) so a real
//  display isn't rejected for not matching an assumed grammar; the CONSTRAIN
//  row is how a user opts back into Mode 2 — user-configured exact format.
//  Edits write straight through to `AppState` so the live readings panel and
//  pattern preview update together; there is no local draft state to
//  discard/commit.
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
        let constrained = device.displayFormat.constrainToFormat
        return VStack(alignment: .leading, spacing: 14) {
            header(device)
            patternPreview(device)
            formatRow(label: "CONSTRAIN") { constrainToggle(device) }
            // Digit/decimal/sign only shape the strict grammar, so they read
            // as secondary while unconstrained instead of disappearing —
            // the user may be pre-configuring a format to switch back to.
            formatRow(label: "DIGITS") { digitsControl(device) }
                .opacity(constrained ? 1 : 0.45)
            formatRow(label: "DECIMAL AFTER DIGIT") { decimalStepper(device) }
                .opacity(constrained ? 1 : 0.45)
            formatRow(label: "SIGN (±)") { signToggle(device) }
                .opacity(constrained ? 1 : 0.45)
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
                Text("\(modelLabel(device)) · \(modeLabel(device.displayFormat))")
                    .font(Theme.ui(10, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
            }
            Spacer(minLength: 8)
            closeButton
        }
    }

    private func modeLabel(_ format: DisplayFormat) -> String {
        format.constrainToFormat ? "Mode 2 — user-configured format" : "Mode 3 — free numeric"
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
        let constrained = device.displayFormat.constrainToFormat
        return Group {
            if constrained {
                Text(device.displayFormat.patternPreview)
                    .font(Theme.mono(24, weight: .semibold))
                    .tracking(2)
            } else {
                // No grammar to preview once unconstrained — show what IS
                // still recognized (digits, sign, decimal point) instead of
                // a stale digit-count pattern the OCR path no longer enforces.
                VStack(spacing: 5) {
                    Text("0-9 · ± · .")
                        .font(Theme.mono(22, weight: .semibold))
                        .tracking(2)
                    Text("ANY NUMBER")
                        .font(Theme.ui(9, weight: .heavy))
                        .tracking(0.9)
                }
            }
        }
        .foregroundStyle(Theme.brandYellow)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink))
        .accessibilityLabel(constrained
            ? "Pattern preview \(device.displayFormat.patternPreview)"
            : "Pattern preview: any number, digits, sign, and decimal point")
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

    /// Same toggle-chip styling as `signToggle` below — ON (constrained)
    /// reads like "ALLOWED" (ink-filled, yellow text), OFF (free numeric)
    /// reads like the disabled state (outlined only).
    private func constrainToggle(_ device: Device) -> some View {
        let constrained = device.displayFormat.constrainToFormat
        return Button {
            adjust(device) { $0.constrainToFormat.toggle() }
        } label: {
            Text(constrained ? "EXACT FORMAT" : "ANY NUMBER")
                .font(Theme.ui(10, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(constrained ? Theme.brandYellow : Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 5).fill(constrained ? Theme.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -8))
        .accessibilityLabel("Recognition constraint")
        .accessibilityValue(constrained ? "Exact format" : "Any number")
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

    /// Leading "—" (none) segment maps to `unit = nil` — dimensionless is the
    /// default for a new device now (field report: assuming a unit was part
    /// of what made the strict default reject real displays).
    private static let noUnitToken = "—"

    private func unitControl(_ device: Device) -> some View {
        let options = [Self.noUnitToken, "V", "A", "Ω", "°C", "Hz"]
        let selection = device.displayFormat.unit ?? Self.noUnitToken
        return SegmentedChoice(options: options, selection: selection, label: { $0 }) { newUnit in
            adjust(device) { $0.unit = newUnit == Self.noUnitToken ? nil : newUnit }
        }
    }

    /// Min/max steppers, ±5 per tap. Outward moves (min↓, max↑) are always
    /// allowed; inward moves (min↑, max↓) are clamped to keep `min < max`
    /// with at least a 5-unit gap (mirrors the design prototype's logic).
    /// Either bound may be `nil` ("—", no range check on that side) — a
    /// stepper with no configured bound starts from 0, not the spec
    /// example's ±20, since range checking is opt-in per device now rather
    /// than assumed by the default format.
    private func rangeStepper(_ device: Device) -> some View {
        let format = device.displayFormat
        let unit = format.unit ?? ""
        let minValue = format.minimumValue
        let maxValue = format.maximumValue
        return HStack(spacing: 6) {
            stepButton("−") { adjust(device) { $0.minimumValue = (minValue ?? 0) - 5 } }
            Text(minValue.map { rangeValueString($0, unit: unit) } ?? "—")
            stepButton("+") {
                adjust(device) {
                    let raised = (minValue ?? 0) + 5
                    $0.minimumValue = maxValue.map { min($0 - 5, raised) } ?? raised
                }
            }
            Text("to").foregroundStyle(Theme.inkMuted)
            stepButton("−") {
                adjust(device) {
                    let lowered = (maxValue ?? 0) - 5
                    $0.maximumValue = minValue.map { max($0 + 5, lowered) } ?? lowered
                }
            }
            Text(maxValue.map { rangeValueString($0, unit: unit) } ?? "—")
            stepButton("+") { adjust(device) { $0.maximumValue = (maxValue ?? 0) + 5 } }
            rangeResetButton(device)
        }
        .font(Theme.mono(11, weight: .semibold))
    }

    /// Resets both bounds to `nil` ("—", range checking off) in one tap.
    private func rangeResetButton(_ device: Device) -> some View {
        Button {
            adjust(device) {
                $0.minimumValue = nil
                $0.maximumValue = nil
            }
        } label: {
            Text(Self.noUnitToken)
                .font(Theme.ui(13, weight: .heavy))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -15))
        .accessibilityLabel("Clear valid range")
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
        // Visual chip stays small; grow the tap target to the required
        // ≥44 pt without affecting layout (matches closeButton above).
        .contentShape(Rectangle().inset(by: -15))
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
