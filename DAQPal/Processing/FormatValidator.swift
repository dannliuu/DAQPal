//
//  FormatValidator.swift
//  DAQPal
//
//  Constrained-format parsing (spec §10 Mode 2, Milestone 4): OCR text either
//  matches the configured display grammar exactly or the reading is rejected.
//

import Foundation

enum FormatParseResult: Equatable, Sendable {
    case valid(Double)
    case invalid(RejectionReason)
}

/// Pure text → value parser against a `DisplayFormat` grammar
/// `[sign?][digits][.][digits]`.
///
/// Parsing steps, in order:
/// 1. Remove ALL whitespace (OCR inserts stray spaces, e.g. "12.347 V").
/// 2. Strip one trailing unit token — tolerated only when it equals the
///    configured unit or is a suffix of it (case-insensitive), e.g. "V" or
///    "°C"→"C". Kept deliberately simple; no unit inference happens here.
/// 3. Normalize the common OCR digit confusables BEFORE validation:
///    O→0, I/l→1, S→5, B→8 (plus lowercase o/s). Letters outside this set are
///    never coerced — "1A.34B" stays invalid.
/// 4. Grammar check (spec Mode 2 examples are the authority):
///    - Optional single leading `-`/`+`, only when `signAllowed`.
///    - `decimalPosition == nil` ⇒ no separator allowed at all.
///    - Otherwise exactly one ".", and the FRACTION digit count must equal
///      `digitCount - decimalPosition` exactly.
///    - Integer digit count: at most `decimalPosition`, at least 1
///      (exactly 0 when `decimalPosition == 0`). FEWER leading digits are
///      accepted — documented choice: real instruments blank leading zeros
///      and show the sign in the leading position, which is what makes the
///      spec's own "-1.234" example valid for the 5-digit/decimal-2 format
///      while "123.4567" (too many digits) stays invalid. The same
///      leading-blanking allowance applies to integer displays
///      (1...digitCount digits when `decimalPosition == nil`).
///
/// Range checking is NOT done here — that is `PhysicalValidator`'s job.
struct FormatValidator {
    /// Documented OCR confusable set (contract): applied before validation.
    private static let confusables: [Character: Character] = [
        "O": "0", "o": "0",
        "I": "1", "l": "1",
        "S": "5", "s": "5",
        "B": "8",
    ]

    static func normalizeConfusables(_ text: String) -> String {
        String(text.map { confusables[$0] ?? $0 })
    }

    static func parse(_ text: String, format: DisplayFormat) -> FormatParseResult {
        var body = String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
        body = strippingTrailingUnit(from: body, unit: format.unit)
        body = normalizeConfusables(body)
        guard !body.isEmpty else { return .invalid(.invalidFormat) }

        var negative = false
        if let first = body.first, first == "-" || first == "+" {
            guard format.signAllowed else { return .invalid(.invalidFormat) }
            negative = (first == "-")
            body.removeFirst()
        }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart: Substring
        let fractionPart: Substring

        if let decimalPosition = format.decimalPosition {
            guard parts.count == 2 else { return .invalid(.invalidFormat) }
            integerPart = parts[0]
            fractionPart = parts[1]
            guard fractionPart.count == format.digitCount - decimalPosition else {
                return .invalid(.invalidFormat)
            }
            if decimalPosition == 0 {
                guard integerPart.isEmpty else { return .invalid(.invalidFormat) }
            } else {
                guard (1...decimalPosition).contains(integerPart.count) else {
                    return .invalid(.invalidFormat)
                }
            }
        } else {
            guard parts.count == 1 else { return .invalid(.invalidFormat) }
            integerPart = parts[0]
            fractionPart = ""
            guard (1...max(1, format.digitCount)).contains(integerPart.count) else {
                return .invalid(.invalidFormat)
            }
        }

        guard integerPart.allSatisfy(isASCIIDigit), fractionPart.allSatisfy(isASCIIDigit) else {
            return .invalid(.invalidFormat)
        }

        // "." always the separator here, so Double parsing is
        // locale-independent by construction.
        let numeric = (negative ? "-" : "")
            + (integerPart.isEmpty ? "0" : String(integerPart))
            + (fractionPart.isEmpty ? "" : "." + fractionPart)
        guard let value = Double(numeric), value.isFinite else {
            return .invalid(.invalidFormat)
        }
        return .valid(value)
    }

    /// Instance forwarding for callers holding a validator value; the logic
    /// itself is pure and static.
    func parse(_ text: String, format: DisplayFormat) -> FormatParseResult {
        Self.parse(text, format: format)
    }

    // MARK: - Lenient extraction (spec Mode 3 — unknown format)

    /// Extracts the most plausible numeric token from arbitrary OCR text,
    /// making NO assumption about digit count, decimal position, sign, or unit.
    /// This is the Mode 3 path used when a device's format is unconstrained —
    /// real meters whose exact grammar the user has not configured.
    ///
    /// Steps:
    /// 1. Apply the same OCR confusable normalization as strict parsing
    ///    (O→0, I/l→1, S→5, B→8) so misread glyphs still yield digits.
    /// 2. Find every token matching `[-+]?(\d+\.\d*|\.\d+|\d+)` — a sign counts
    ///    only when directly attached to the digits.
    /// 3. Discard tokens whose ORIGINAL text contained no real digit —
    ///    otherwise pure-letter words mint fake numbers ("HOLD"→"H0LD"→0).
    ///    A token must be anchored by at least one true digit; confusables
    ///    only repair characters around real digits.
    /// 4. Return the token with the most digits (ties resolve to the leftmost).
    ///    Text with no digit at all yields `nil`.
    ///
    /// Deliberately tolerant of trailing junk: `"12.34.7"` yields the richest
    /// token `12.34` rather than rejecting — leniency is the point of this
    /// path. Range checking still happens downstream in `PhysicalValidator`.
    static func extractNumber(from text: String) -> (value: Double, matched: String)? {
        let normalized = normalizeConfusables(text)
        let source = text as NSString
        let range = NSRange(normalized.startIndex..., in: normalized)
        var best: (value: Double, matched: String, digits: Int)?
        for match in numberPattern.matches(in: normalized, range: range) {
            guard let r = Range(match.range, in: normalized) else { continue }
            let token = String(normalized[r])
            let digits = token.filter { isASCIIDigit($0) }.count
            // The confusable map is 1:1 ASCII→ASCII, so UTF-16 offsets align
            // with the original text: anchor every token to ≥1 REAL digit.
            let original = source.substring(with: match.range)
            guard original.contains(where: { isASCIIDigit($0) }) else { continue }
            guard digits > 0, let value = numericValue(of: token) else { continue }
            // Strictly-greater keeps the leftmost token on a digit-count tie.
            if best == nil || digits > best!.digits {
                best = (value, token, digits)
            }
        }
        guard let best else { return nil }
        return (best.value, best.matched)
    }

    /// Format-aware entry point for the recognition pipeline: strict grammar
    /// when `format.constrainToFormat`, lenient numeric extraction otherwise. A
    /// lenient text with no numeric token is reported as `.invalidFormat`, so
    /// the confidence engine treats "no number here" the same as a strict
    /// grammar failure.
    static func value(from text: String, format: DisplayFormat) -> FormatParseResult {
        if format.constrainToFormat {
            return parse(text, format: format)
        }
        guard let extracted = extractNumber(from: text) else {
            return .invalid(.invalidFormat)
        }
        return .valid(extracted.value)
    }

    /// Instance forwarding, mirroring `parse`; the logic is pure and static.
    func value(from text: String, format: DisplayFormat) -> FormatParseResult {
        Self.value(from: text, format: format)
    }

    // MARK: - Private

    /// Numeric-token grammar for lenient extraction (see `extractNumber`).
    /// Compiled once; the pattern is a compile-time constant, so the `try!`
    /// can never fail at runtime.
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"[-+]?(?:\d+\.\d*|\.\d+|\d+)"#)

    /// Converts one regex-matched numeric token into a Double via a canonical
    /// `.`-decimal string, so parsing is locale-independent and tolerates the
    /// bare-/trailing-dot forms the grammar can emit (`.5`, `12.`).
    private static func numericValue(of token: String) -> Double? {
        var body = token
        var negative = false
        if let first = body.first, first == "-" || first == "+" {
            negative = (first == "-")
            body.removeFirst()
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let integerPart = parts.first.map(String.init) ?? ""
        let fractionPart = parts.count > 1 ? String(parts[1]) : ""
        let numeric = (negative ? "-" : "")
            + (integerPart.isEmpty ? "0" : integerPart)
            + (fractionPart.isEmpty ? "" : "." + fractionPart)
        guard let value = Double(numeric), value.isFinite else { return nil }
        return value
    }

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && ("0"..."9").contains(c)
    }

    /// Strips one trailing unit token equal to (or a suffix of) the
    /// configured unit, longest match first, case-insensitively.
    private static func strippingTrailingUnit(from text: String, unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return text }
        let lowered = text.lowercased()
        for length in stride(from: unit.count, through: 1, by: -1) {
            let token = String(unit.suffix(length)).lowercased()
            if lowered.hasSuffix(token), text.count > token.count {
                return String(text.dropLast(token.count))
            }
        }
        return text
    }
}
