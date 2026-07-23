//
//  DisplayFormat.swift
//  DAQPal
//

import Foundation

/// User-configured description of an instrument's numeric display
/// (spec §10, Mode 2 — user-configured format).
///
/// `decimalPosition` is the **number of digits before the decimal separator**:
/// - `digitCount: 5, decimalPosition: 2` → `12.347`
/// - `decimalPosition: 0`                → `.12347`
/// - `decimalPosition: nil`              → `12347` (integer display)
struct DisplayFormat: Codable, Equatable, Hashable, Sendable {
    var digitCount: Int
    var decimalPosition: Int?
    var signAllowed: Bool
    var unit: String?
    var minimumValue: Double?
    var maximumValue: Double?

    /// Default configuration matching the spec's canonical DMM example
    /// (`±XX.XXX V`, −20…+20 V).
    static let defaultDMM = DisplayFormat(digitCount: 5,
                                          decimalPosition: 2,
                                          signAllowed: true,
                                          unit: "V",
                                          minimumValue: -20,
                                          maximumValue: 20)

    /// Digits after the decimal separator (0 when the display is integer).
    var fractionDigits: Int {
        guard let decimalPosition else { return 0 }
        return max(0, digitCount - decimalPosition)
    }

    /// Live pattern preview, e.g. `±XX.XXX V` (README format sheet).
    var patternPreview: String {
        var pattern = ""
        if signAllowed { pattern += "±" }
        if let decimalPosition {
            pattern += String(repeating: "X", count: max(0, decimalPosition))
            pattern += "."
            pattern += String(repeating: "X", count: max(0, digitCount - decimalPosition))
        } else {
            pattern += String(repeating: "X", count: max(0, digitCount))
        }
        if let unit, !unit.isEmpty { pattern += " \(unit)" }
        return pattern
    }

    /// Placeholder shown when no reading is locked, e.g. `—.———`.
    var placeholder: String {
        if let decimalPosition {
            return String(repeating: "—", count: max(1, decimalPosition)) + "."
                + String(repeating: "—", count: max(0, digitCount - decimalPosition))
        }
        return String(repeating: "—", count: max(1, digitCount))
    }

    /// Formats an accepted value with the display's digit layout.
    func formatted(_ value: Double) -> String {
        guard value.isFinite else { return placeholder }
        return String(format: "%.\(fractionDigits)f", value)
    }
}
