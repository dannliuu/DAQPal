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
    /// When true, readings must match the exact digit grammar above (spec
    /// Mode 2 — user-configured format). When false, recognition is lenient:
    /// any numeric token (digits, decimal point, optional sign) is extracted
    /// from the OCR text (spec Mode 3 — unknown format). New devices start
    /// unconstrained and dimensionless; constraining is an explicit user
    /// action in the format sheet.
    var constrainToFormat: Bool = true

    /// Digit-count bound for the format sheet's stepper ONLY — a UI input
    /// limit, not a model or validator constraint. `DisplayFormat` itself, the
    /// `FormatValidator` strict parse, `DigitSegmenter`, and seven-segment
    /// reconstruction all handle any positive count; nothing here clamps them.
    /// 12 covers real bench instruments, including 8–10 digit counters and
    /// frequency meters.
    static let digitCountRange: ClosedRange<Int> = 1...12

    /// Starting state for a new device: dimensionless, no range, lenient
    /// numeric extraction. The digit fields only seed the format sheet.
    static let unconstrained = DisplayFormat(digitCount: 5,
                                             decimalPosition: 2,
                                             signAllowed: true,
                                             unit: nil,
                                             minimumValue: nil,
                                             maximumValue: nil,
                                             constrainToFormat: false)

    /// The spec's canonical strict DMM example (`±XX.XXX V`, −20…+20 V) —
    /// used by tests and as the sheet's example configuration.
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

    /// Placeholder shown when no reading is locked. Constrained formats mirror
    /// the digit grammar (e.g. `——.———`); an unconstrained (Mode 3) device has
    /// no fixed digit layout, so it shows a neutral `———` rather than a fake
    /// decimal pattern that would imply a precision the app isn't enforcing.
    var placeholder: String {
        guard constrainToFormat else { return "———" }
        if let decimalPosition {
            return String(repeating: "—", count: max(1, decimalPosition)) + "."
                + String(repeating: "—", count: max(0, digitCount - decimalPosition))
        }
        return String(repeating: "—", count: max(1, digitCount))
    }

    /// Formats an accepted value for display.
    ///
    /// Constrained (Mode 2) devices render through the fixed digit grammar
    /// (`fractionDigits` decimal places, always shown). Unconstrained (Mode 3)
    /// devices have no declared precision, so the raw value is rendered
    /// *naturally* via `naturalString` — trailing zeros trimmed, integers with
    /// no decimal point — rather than padded to the seed format's digit count
    /// (which made "230" read as "230.000"). Both the live card and the results
    /// screen call this, so the two stay consistent.
    func formatted(_ value: Double) -> String {
        guard value.isFinite else { return placeholder }
        guard constrainToFormat else { return Self.naturalString(value) }
        return String(format: "%.\(fractionDigits)f", value)
    }

    /// Natural, format-agnostic rendering of `value` for unconstrained (Mode 3)
    /// devices and their CSV rows: a locale-independent `.` decimal separator,
    /// no digit grouping, trailing zeros trimmed, up to 6 fraction digits, and
    /// integers rendered without a decimal point. Small magnitudes stay plain
    /// decimal (`0.000123`, never scientific notation) because the fixed
    /// `%.6f` conversion never switches to exponent form. Non-finite input
    /// yields the neutral `———` placeholder.
    static func naturalString(_ value: Double) -> String {
        guard value.isFinite else { return "———" }
        // %f (unlike NumberFormatter) is locale-independent and never uses
        // scientific notation; 6 places is the retained-precision ceiling.
        var text = String(format: "%.6f", value)
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        // A tiny negative that rounds to zero would render as "-0"; normalize.
        return text == "-0" ? "0" : text
    }
}
