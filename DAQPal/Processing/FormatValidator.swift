//
//  FormatValidator.swift
//  DAQPal
//
//  Constrained-format parsing (spec §10 Mode 2, Milestone 4): OCR text either
//  matches the configured display grammar exactly or the reading is rejected.
//
//  Spec §11A — DECIMAL INTEGRITY. The decimal separator is treated as a
//  data-integrity property, not as one more character to be lenient about. A
//  lost or misplaced separator produces a WELL-FORMED number that is wrong by a
//  factor of ten or more: `12.345` read as `12345` has the right digits in the
//  right order and passes every check that only asks "does this parse?". Range
//  validation catches it only by luck and temporal filtering actively HIDES it,
//  because a consistently shifted series is perfectly self-consistent. So the
//  parser never emits digits as an integer when a separator was expected, and
//  where the separator cannot be resolved confidently it raises
//  `.ambiguousDecimal` instead of guessing.
//

import Foundation

enum FormatParseResult: Equatable, Sendable {
    case valid(Double)
    case invalid(RejectionReason)
}

/// A parsed number together with everything needed to reproduce it faithfully.
struct NumericReading: Equatable, Sendable {
    let value: Double
    /// The number as WRITTEN, separator canonicalized to "." and trailing zeros
    /// preserved (`1.000` stays `"1.000"`), for display fidelity in structured
    /// output — `Double` cannot carry significant trailing zeros.
    let text: String
    /// The separator verdict, scored independently of the digits.
    let decimal: DecimalAnalysis
}

/// Result of a format-aware parse that also reports the separator verdict.
enum FormatReadingResult: Equatable, Sendable {
    case valid(NumericReading)
    case invalid(RejectionReason)
}

/// Result of lenient (spec Mode 3) extraction from arbitrary OCR text.
enum LenientExtraction: Equatable, Sendable {
    /// No numeric token at all — "HOLD", "---", "".
    case none
    /// Numeric material was present but could not be resolved to ONE number
    /// with a determined separator.
    case rejected(RejectionReason)
    case number(NumericReading)
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
///    never coerced — "1A.34B" stays invalid. `,` is deliberately NOT in that
///    map: a comma is a real separator glyph whose ROLE (decimal mark vs
///    thousands group) is resolved structurally, never by substitution.
/// 4. Grammar check (spec Mode 2 examples are the authority):
///    - Optional single leading `-`/`+`, only when `signAllowed`.
///    - `decimalPosition == nil` ⇒ no separator allowed at all.
///    - Otherwise a separator is REQUIRED — its absence is `.ambiguousDecimal`,
///      never a silently-accepted integer — and the FRACTION digit count must
///      equal `digitCount - decimalPosition` exactly. A separator anywhere else
///      is a format violation.
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
        // Unicode dashes that a display's minus sign is transcribed as. The
        // numeric grammar's sign class is ASCII `[-+]?` only, so without these
        // a leading U+2212 MINUS SIGN is not a sign — it is a foreign glyph.
        //
        // This closes a measured SIGN INVERSION, which is the same class of
        // defect as a factor-of-ten error: a negative reading exported as
        // positive. It is PRE-EXISTING (the map has never carried these), but
        // the B0.5 tokenizer rule made it asymmetric and therefore easy to
        // mistake for intentional — "\u{2212}125" refused as a leading foreign
        // glyph while "\u{2212}12.5" was EXEMPTED (its run carries its own
        // separator, so no decimal position was at stake) and silently exported
        // +12.5. Normalizing here fixes both forms at the source rather than
        // teaching the exemption about signs.
        "\u{2212}": "-",   // MINUS SIGN
        "\u{2013}": "-",   // EN DASH
        "\u{2014}": "-",   // EM DASH
        "\u{2010}": "-",   // HYPHEN
        "\u{2011}": "-",   // NON-BREAKING HYPHEN
        "\u{2012}": "-",   // FIGURE DASH
        "\u{2015}": "-",   // HORIZONTAL BAR
    ]

    // MARK: - Separator-certainty policy
    //
    // These are POLICY weights, not measurements: they encode how much of the
    // separator determination came from the glyphs themselves versus from
    // inference. Ordering is what matters (an inferred separator must score
    // below a directly-read one); the exact values are a starting calibration
    // and are documented as such rather than claimed as measured.

    /// The separator was read directly and unambiguously — a single "." — or
    /// the display declares no separator and showed none. Neutral in fusion.
    static let readSeparatorCertainty: Float = 1

    /// The separator's ROLE was resolved by structure rather than read: digit
    /// grouping ("1,234.5", "1,234,567") or an exact match against a declared
    /// `decimalPosition`. Strong, but still an inference.
    static let structurallyResolvedCertainty: Float = 0.9

    /// A lone comma taken as a decimal mark because the grouping shape rules
    /// out a thousands separator (e.g. "12,34" — a group of 3 is required).
    /// Sound, but it rests on a locale assumption.
    static let commaDecimalCertainty: Float = 0.8

    /// No separator was seen and none was declared (lenient Mode 3 integer).
    /// The reading is self-consistent, but text alone cannot exclude a DROPPED
    /// separator, which is precisely the §11A failure — so this is deliberately
    /// below neutral and depresses the fused confidence.
    ///
    /// THIS IS AN ABSENCE CLAIM MADE FROM TEXT, AND IT HAS EXACTLY ONE JOB:
    /// depress the fused confidence (`ConfidenceEngine`'s decimal factor). It
    /// may NEVER be read as corroboration for a magnitude change. It used to
    /// be, by accident of ordering — it sat at 0.75 while
    /// `TemporalConsensus.decimalRescueConfidence` sat at 0.70, so "I saw no
    /// separator" outscored the bar for "the glyph corroborates" and the
    /// power-of-ten guard could never fire. `TemporalConsensus`
    /// `.resolveDecimalEvent` now enforces the rule STRUCTURALLY (a form with
    /// no separator cannot corroborate at any value) rather than by ordering,
    /// so this constant can no longer reopen that hole. Do not "harmonize" the
    /// two constants.
    ///
    /// Its pixel-level counterpart is `DecimalRescue.betweenDigitsOnlyCeiling`
    /// (0.5): the module that can actually SEE the image caps any absence
    /// verdict at 0.5. A text-only absence cannot honestly outrank it, so 0.75
    /// is on notice — it is the number to revisit at B1, with the Mode-3
    /// integer fixture that does not exist yet, and that revision is a decision
    /// about a whole device class (D10), not a knob. It is deliberately NOT
    /// changed here: lowering it changes global acceptance for every bare
    /// integer reading as a side effect of fixing an ordering inversion, and
    /// the current suite cannot measure that cost (every end-to-end fixture
    /// renders a text containing a separator), which would make it an H3
    /// violation by construction.
    static let undeclaredIntegerCertainty: Float = 0.75

    static func normalizeConfusables(_ text: String) -> String {
        String(text.map { confusables[$0] ?? $0 })
    }

    // MARK: - Strict grammar (spec Mode 2)

    static func parse(_ text: String, format: DisplayFormat) -> FormatParseResult {
        Self.flatten(strictReading(text, format: format))
    }

    /// Strict parse that also reports the separator verdict.
    static func strictReading(_ text: String, format: DisplayFormat) -> FormatReadingResult {
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
        guard !body.isEmpty else { return .invalid(.invalidFormat) }

        // The declared layout disambiguates a comma: prefer the hypothesis that
        // matches `decimalPosition` (spec §11A requirement 5).
        let expectedFraction = format.decimalPosition.map { format.digitCount - $0 }
        let h: Hypothesis
        switch decompose(body,
                         declared: true,
                         declaresSeparator: format.decimalPosition != nil,
                         expectedFractionDigits: expectedFraction) {
        case .rejected(let reason): return .invalid(reason)
        case .resolved(let resolved): h = resolved
        }

        if let decimalPosition = format.decimalPosition {
            // A separator was EXPECTED. Its absence must never be emitted as an
            // integer — that is the §11A factor-of-ten failure.
            guard h.separatorDetected else { return .invalid(.ambiguousDecimal) }
            guard h.fractionDigits.count == format.digitCount - decimalPosition else {
                return .invalid(.invalidFormat)
            }
            if decimalPosition == 0 {
                guard h.integerDigits.isEmpty else { return .invalid(.invalidFormat) }
            } else {
                guard (1...decimalPosition).contains(h.integerDigits.count) else {
                    return .invalid(.invalidFormat)
                }
            }
        } else {
            // Integer display: a separator anywhere is a format violation.
            guard !h.separatorDetected else { return .invalid(.invalidFormat) }
            guard (1...max(1, format.digitCount)).contains(h.integerDigits.count) else {
                return .invalid(.invalidFormat)
            }
        }

        guard let reading = h.reading(negative: negative) else {
            return .invalid(.invalidFormat)
        }
        return .valid(reading)
    }

    /// Instance forwarding for callers holding a validator value; the logic
    /// itself is pure and static.
    func parse(_ text: String, format: DisplayFormat) -> FormatParseResult {
        Self.parse(text, format: format)
    }

    // MARK: - Lenient extraction (spec Mode 3 — unknown format)

    /// Extracts the single plausible numeric token from arbitrary OCR text,
    /// making NO assumption about digit count, decimal position, sign, or unit.
    /// This is the Mode 3 path used when a device's format is unconstrained.
    ///
    /// Steps:
    /// 1. Apply the same OCR confusable normalization as strict parsing
    ///    (O→0, I/l→1, S→5, B→8) so misread glyphs still yield digits.
    /// 2. Find every token matching `[-+]?([0-9]+([.,][0-9]*)*|[.,][0-9]+)`.
    ///    Separators are matched INSIDE the token deliberately: "12,345" and
    ///    "12..345" must each be analysed as one (possibly malformed) number,
    ///    not silently split into a pair the caller can pick a winner from.
    ///    The pattern deliberately does NOT swallow foreign glyphs: widening it
    ///    would push the decision down into `decompose`, where the only two
    ///    outcomes are "this glyph is a separator" (which §11A forbids — see
    ///    `splitSuspected`) or "reject", and by then the fact that the glyph was
    ///    never CLASSIFIED as a separator has been thrown away. Classifying the
    ///    GAP instead keeps the refusal at the point where that fact still
    ///    exists.
    /// 3. Discard tokens whose ORIGINAL text contained no real digit —
    ///    otherwise pure-letter words mint fake numbers ("HOLD"→"H0LD"→0).
    /// 4. Drop CAPTION-GLUED tokens: a token with an ASCII letter immediately
    ///    before it is part of an annunciator, not a reading ("CH1", "T1",
    ///    "AUX2"). This is what keeps a caption's stray digit from looking like
    ///    half of a split number.
    /// 5. Choose among what is left, in this order:
    ///    a. exactly one candidate → that one;
    ///    b. two BARE consecutive candidates whose gap is not a field boundary
    ///       → a SPLIT reading → `.rejected(.ambiguousDecimal)`. The gap is
    ///       classified three ways (`GapKind`): WHITESPACE is a dropped point's
    ///       signature ("12 345" is 12.345, or 12345, or two numbers — defect 1,
    ///       where the old code picked the most digits and returned 345); a
    ///       FOREIGN GLYPH is the same failure with a mark still sitting in
    ///       separator position ("80•8" → 80, "12•345" → 345), and refuses; a
    ///       LETTER is an identified glyph that marks a genuine field boundary
    ///       ("12 V 345") and does not refuse;
    ///    c. exactly one candidate carries a separator → prefer it over
    ///       bare-digit tokens ("CH1 12.345 V");
    ///    d. otherwise the most digits wins, leftmost on a tie.
    ///    e. a bare CHOSEN token with an unclassifiable glyph GLUED to its front
    ///       ("•5" for ".5") → `.rejected(.ambiguousDecimal)`. This is the
    ///       single-token form of the same failure, which step (b) cannot see
    ///       because there is only one token to compare.
    /// 6. Analyse the chosen token's separators; malformed shapes ("12..345",
    ///    "12.34.5", "12.") are REJECTED rather than salvaged, and an
    ///    unresolvable comma raises `.ambiguousDecimal`.
    ///
    /// In neither (b) nor (e) is an unidentified glyph ever READ as a separator.
    /// It is only ever read as "this token cannot be trusted" — the opposite
    /// action from the same trigger (spec §11A / WS-B H2). Authoring a decimal
    /// position from a glyph the recognizer could not classify converts a class
    /// that truncates into a class that INVENTS magnitude.
    ///
    /// Leniency here is about surrounding junk (captions, units, annunciators),
    /// never about the number's own structure. Range checking still happens
    /// downstream in `PhysicalValidator`.
    static func extractReading(from text: String) -> LenientExtraction {
        let normalized = normalizeConfusables(text) as NSString
        let source = text as NSString
        let full = NSRange(location: 0, length: normalized.length)

        var candidates: [Token] = []
        var glued: [Token] = []
        for match in numberPattern.matches(in: normalized as String, range: full) {
            let body = normalized.substring(with: match.range)
            guard body.contains(where: isASCIIDigit) else { continue }
            // The confusable map is 1:1 ASCII→ASCII, so UTF-16 offsets align
            // with the original text: anchor every token to ≥1 REAL digit.
            guard source.substring(with: match.range).contains(where: isASCIIDigit) else { continue }
            let token = Token(text: body,
                              range: match.range,
                              digits: body.filter(isASCIIDigit).count,
                              hasSeparator: body.contains(where: isSeparator))
            if isCaptionGlued(token, in: normalized) { glued.append(token) } else { candidates.append(token) }
        }
        if candidates.isEmpty { candidates = glued }
        guard !candidates.isEmpty else { return .none }

        let chosen: Token
        if candidates.count == 1 {
            chosen = candidates[0]
        } else if splitSuspected(among: candidates, in: normalized) {
            return .rejected(.ambiguousDecimal)
        } else {
            let rich = candidates.filter(\.hasSeparator)
            if rich.count == 1 {
                chosen = rich[0]
            } else {
                // Strictly-greater keeps the leftmost token on a digit tie.
                var best = candidates[0]
                for token in candidates.dropFirst() where token.digits > best.digits { best = token }
                chosen = best
            }
        }

        // The leading-separator class ("•5"), which is a single token and so
        // never reaches the gap rule above.
        if !chosen.hasSeparator, leadingForeignGlyph(before: chosen, in: normalized) {
            return .rejected(.ambiguousDecimal)
        }

        var body = chosen.text
        var negative = false
        if let first = body.first, first == "-" || first == "+" {
            negative = (first == "-")
            body.removeFirst()
        }
        switch decompose(body, declared: false, declaresSeparator: false, expectedFractionDigits: nil) {
        case .rejected(let reason):
            return .rejected(reason)
        case .resolved(let h):
            guard let reading = h.reading(negative: negative) else {
                return .rejected(.invalidFormat)
            }
            return .number(reading)
        }
    }

    /// Back-compatible lenient entry point: the value and the token as written.
    /// `nil` covers both "no number here" and "the number could not be resolved
    /// safely" — callers on this path treat either as no reading, which is the
    /// correct conservative behaviour for an unresolvable separator.
    static func extractNumber(from text: String) -> (value: Double, matched: String)? {
        guard case .number(let reading) = extractReading(from: text) else { return nil }
        return (reading.value, reading.text)
    }

    /// Format-aware entry point for the recognition pipeline: strict grammar
    /// when `format.constrainToFormat`, lenient numeric extraction otherwise. A
    /// lenient text with no numeric token is reported as `.invalidFormat`, so
    /// the confidence engine treats "no number here" the same as a strict
    /// grammar failure; an unresolvable separator keeps its own
    /// `.ambiguousDecimal` reason.
    static func reading(from text: String, format: DisplayFormat) -> FormatReadingResult {
        if format.constrainToFormat {
            return strictReading(text, format: format)
        }
        // An unconstrained format's `decimalPosition` is only a sheet seed, not
        // a declaration, so it must NOT be used to resolve a separator here.
        switch extractReading(from: text) {
        case .none: return .invalid(.invalidFormat)
        case .rejected(let reason): return .invalid(reason)
        case .number(let reading): return .valid(reading)
        }
    }

    static func value(from text: String, format: DisplayFormat) -> FormatParseResult {
        flatten(reading(from: text, format: format))
    }

    /// Instance forwarding, mirroring `parse`; the logic is pure and static.
    func value(from text: String, format: DisplayFormat) -> FormatParseResult {
        Self.value(from: text, format: format)
    }

    // MARK: - Private

    private struct Token {
        let text: String
        let range: NSRange
        let digits: Int
        let hasSeparator: Bool
        /// UTF-16 length of the token's OWN sign, so an INFIX "-" glued to the
        /// preceding digit run ("80-8") is measured as gap rather than as this
        /// token's sign.
        var signLength: Int {
            guard let first = text.first, first == "-" || first == "+" else { return 0 }
            return 1
        }
    }

    /// One resolved interpretation of a token's separator structure.
    private struct Hypothesis {
        /// Digits before the separator; "" for ".5".
        var integerDigits: String
        /// Digits after the separator; "" when no separator was detected.
        var fractionDigits: String
        var separatorDetected: Bool
        var certainty: Float

        func reading(negative: Bool) -> NumericReading? {
            let sign = negative ? "-" : ""
            let written = sign + integerDigits
                + (separatorDetected ? "." + fractionDigits : "")
            let numeric = sign + (integerDigits.isEmpty ? "0" : integerDigits)
                + (separatorDetected && !fractionDigits.isEmpty ? "." + fractionDigits : "")
            guard let value = Double(numeric), value.isFinite else { return nil }
            let decimal = DecimalAnalysis(separatorDetected: separatorDetected,
                                          separatorPosition: separatorDetected ? integerDigits.count : nil,
                                          fractionDigitCount: separatorDetected ? fractionDigits.count : 0,
                                          confidence: certainty)
            return NumericReading(value: value, text: written, decimal: decimal)
        }
    }

    private enum Decomposition {
        case resolved(Hypothesis)
        case rejected(RejectionReason)
    }

    /// Resolves the separator structure of an UNSIGNED numeric body.
    ///
    /// - Parameters:
    ///   - declared: whether a `DisplayFormat` grammar is in force. Only a
    ///     declared format may resolve an otherwise-ambiguous comma.
    ///   - declaresSeparator: the declared format has a `decimalPosition`.
    ///   - expectedFractionDigits: digits the declared format expects after the
    ///     separator (`nil` for an integer display or an undeclared format).
    private static func decompose(_ body: String,
                                  declared: Bool,
                                  declaresSeparator: Bool,
                                  expectedFractionDigits: Int?) -> Decomposition {
        guard !body.isEmpty else { return .rejected(.invalidFormat) }
        // Only digits and separator glyphs may appear — "1A.34B" stays invalid.
        for character in body where !(isASCIIDigit(character) || isSeparator(character)) {
            return .rejected(.invalidFormat)
        }

        var groups: [String] = [""]
        var separators: [Character] = []
        for character in body {
            if isSeparator(character) {
                separators.append(character)
                groups.append("")
            } else {
                groups[groups.count - 1].append(character)
            }
        }
        guard groups.contains(where: { !$0.isEmpty }) else { return .rejected(.invalidFormat) }

        switch separators.count {
        case 0:
            // No separator anywhere.
            if declared && declaresSeparator {
                // Expected but absent — the §11A failure. Never an integer.
                return .rejected(.ambiguousDecimal)
            }
            return .resolved(Hypothesis(integerDigits: groups[0],
                                        fractionDigits: "",
                                        separatorDetected: false,
                                        certainty: declared ? readSeparatorCertainty
                                                            : undeclaredIntegerCertainty))

        case 1:
            let separator = separators[0]
            let lead = groups[0]
            let fraction = groups[1]
            // A trailing separator ("12.") has no fraction to place: the digits
            // after it are missing, not zero. Rejected, never rounded down.
            guard !fraction.isEmpty else { return .rejected(.invalidFormat) }

            if separator == "." {
                return .resolved(Hypothesis(integerDigits: lead,
                                            fractionDigits: fraction,
                                            separatorDetected: true,
                                            certainty: readSeparatorCertainty))
            }

            // Comma. Defect 2: there was previously no handling at all, so
            // "12,345" tokenized into 12 and 345 and returned 345.
            // A thousands group requires 1...3 digits before it and exactly 3
            // after; anything else can only be a decimal comma.
            let thousandsPossible = (1...3).contains(lead.count) && fraction.count == 3
            if !thousandsPossible {
                return .resolved(Hypothesis(integerDigits: lead,
                                            fractionDigits: fraction,
                                            separatorDetected: true,
                                            certainty: commaDecimalCertainty))
            }
            // Genuinely ambiguous: "12,345" is 12345 (grouped) or 12.345
            // (decimal comma). Only a declared format may break the tie.
            guard declared else { return .rejected(.ambiguousDecimal) }
            if declaresSeparator {
                guard expectedFractionDigits == fraction.count else {
                    return .rejected(.invalidFormat)
                }
                return .resolved(Hypothesis(integerDigits: lead,
                                            fractionDigits: fraction,
                                            separatorDetected: true,
                                            certainty: structurallyResolvedCertainty))
            }
            // Integer display declared ⇒ the comma groups thousands.
            return .resolved(Hypothesis(integerDigits: lead + fraction,
                                        fractionDigits: "",
                                        separatorDetected: false,
                                        certainty: structurallyResolvedCertainty))

        default:
            return decomposeGrouped(groups: groups, separators: separators)
        }
    }

    /// Two or more separators. The only well-formed shapes are digit grouping,
    /// optionally followed by one decimal mark of the OTHER glyph:
    /// "1,234,567", "1,234.5", "1.234,5". Repeated "." with no grouping role
    /// ("12..345", "12.34.5") is malformed and rejected — the old lenient path
    /// salvaged a prefix from these, which is how a split reading survived.
    private static func decomposeGrouped(groups: [String],
                                         separators: [Character]) -> Decomposition {
        let last = separators[separators.count - 1]
        let leading = separators.dropLast()
        guard let groupChar = leading.first, leading.allSatisfy({ $0 == groupChar }) else {
            return .rejected(.invalidFormat)
        }
        // Grouping is a comma convention here; repeated "." is not a shape this
        // parser will guess at.
        guard groupChar == "," else { return .rejected(.invalidFormat) }

        let hasDecimal = (last != groupChar)
        let integerGroups = hasDecimal ? Array(groups.dropLast()) : groups
        let fraction = hasDecimal ? groups[groups.count - 1] : ""
        guard integerGroups.count >= 2 else { return .rejected(.invalidFormat) }
        guard (1...3).contains(integerGroups[0].count) else { return .rejected(.invalidFormat) }
        for group in integerGroups.dropFirst() where group.count != 3 {
            return .rejected(.invalidFormat)
        }
        if hasDecimal {
            guard last == "." , !fraction.isEmpty else { return .rejected(.invalidFormat) }
        }
        return .resolved(Hypothesis(integerDigits: integerGroups.joined(),
                                    fractionDigits: fraction,
                                    separatorDetected: hasDecimal,
                                    certainty: structurallyResolvedCertainty))
    }

    /// True when an ASCII letter sits immediately before the token (past its
    /// sign), i.e. the digit belongs to an annunciator like "CH1", not to a
    /// reading. Only the LEADING side counts: a letter immediately AFTER a
    /// number is usually its unit ("1.5mA").
    private static func isCaptionGlued(_ token: Token, in normalized: NSString) -> Bool {
        let index = token.range.location - 1
        guard index >= 0 else { return false }
        let previous = normalized.substring(with: NSRange(location: index, length: 1))
        guard let character = previous.first else { return false }
        return character.isASCII && character.isLetter
    }

    /// What the text between two consecutive candidate tokens tells us about
    /// whether they are ONE number or TWO fields.
    private enum GapKind {
        /// Whitespace only. A legitimate field delimiter on a display — and
        /// also what a dropped separator leaves behind ("12 345").
        case whitespace
        /// Holds at least one LETTER. A letter is a glyph the recognizer
        /// positively IDENTIFIED, and a letter-scale mark cannot be a decimal
        /// point; it is a caption, unit or annunciator, so the runs either side
        /// are separate FIELDS ("12 V 345", "12°C 345").
        case fieldBoundary
        /// Holds a glyph that is neither whitespace, nor a letter, nor a
        /// recognized separator — a mark the recognizer could not classify,
        /// sitting exactly where a decimal separator would sit.
        case foreignGlyph
    }

    /// Letters are exempted UNICODE-WIDE, not ASCII-only, deliberately: "µ" and
    /// "Ω" are units, and the property that matters is "carries letter-scale
    /// ink, therefore cannot be a decimal point", which is script-independent.
    /// (`isCaptionGlued` and `isASCIIDigit` stay ASCII-only for the opposite
    /// reason — a Devanagari digit is not a reading this pipeline can parse.)
    private static func classify(gap: String) -> GapKind {
        var sawForeign = false
        for character in gap {
            if character.isWhitespace { continue }
            if character.isLetter { return .fieldBoundary }
            sawForeign = true
        }
        return sawForeign ? .foreignGlyph : .whitespace
    }

    /// True when two CONSECUTIVE candidate tokens look like ONE number broken in
    /// two, as opposed to two genuinely separate readings on the same line
    /// ("12.3 45.6").
    ///
    /// Two conditions are required, and the second matters as much as the first:
    ///
    /// 1. **The gap is not a field boundary.** Whitespace alone is a dropped
    ///    separator's signature ("12 345"); a gap holding a FOREIGN GLYPH is
    ///    worse, because the glyph occupies separator position and the token
    ///    grammar silently discarded it — measured on the shipping path,
    ///    "80•8" (true 80.8) parsed as 80 and "12•345" (true 12.345) parsed as
    ///    345, the most-digits picker returning a FRAGMENT with no trace that
    ///    anything was dropped. Both refuse. A gap holding a LETTER does not:
    ///    the letter is an identified glyph and marks a field boundary.
    ///
    ///    THE GLYPH IS NEVER READ AS A SEPARATOR (spec §11A / WS-B H2).
    ///    Authoring a decimal position from a mark the recognizer could not
    ///    classify turns a class that TRUNCATES into a class that INVENTS
    ///    magnitude: a degree sign, a thousands comma, a colon lobe or a glare
    ///    speck would become a decimal point. Refusal is the only sound action,
    ///    and the fragment we would otherwise return is a factor-of-ten error
    ///    either way.
    ///
    /// 2. **NEITHER token already carries a separator.** A dropped separator
    ///    leaves two bare digit runs; it cannot leave a token that still has its
    ///    own decimal point, and a second separator on a token that has one is
    ///    malformed and rejected by `decompose` anyway. So when either side is
    ///    already a well-formed decimal this is two readings, not one broken
    ///    one.
    ///
    /// Condition 2 was missing initially, which made the rule reject every line
    /// carrying two whitespace-separated numbers — including `"12.3 45.6"` and
    /// even `"12.345 12.345"`. That is a recall regression well beyond the
    /// defect being fixed, and it leaks past value reading into
    /// `ScreenCandidateDetector.numericScore`, which uses this same entry point
    /// as a display-detection heuristic: rejecting multi-number lines there
    /// makes real instrument panels *less* likely to be detected as screens.
    ///
    /// The gap is measured from the end of the previous token to the first
    /// DIGIT of the next, so a sign glued to a preceding digit run ("80-8") is
    /// counted as gap. A "-" that cannot be a sign is an infix glyph.
    private static func splitSuspected(among tokens: [Token], in normalized: NSString) -> Bool {
        for index in 1..<tokens.count {
            let previous = tokens[index - 1]
            let current = tokens[index]
            // A token that kept its separator is not a fragment of a split.
            if previous.hasSeparator || current.hasSeparator { continue }
            let start = previous.range.location + previous.range.length
            let end = current.range.location + current.signLength
            guard end > start else { continue }
            let gap = normalized.substring(with: NSRange(location: start, length: end - start))
            switch classify(gap: gap) {
            case .whitespace, .foreignGlyph: return true
            case .fieldBoundary: continue
            }
        }
        return false
    }

    /// True when a glyph the recognizer could not classify is GLUED to the front
    /// of a bare digit run — the leading-separator class ("•5"): the display
    /// shows ".5", Vision transcribes the dot as a bullet, the token grammar
    /// discards it and a bare 5 is parsed. A silent 10× error, and the class
    /// every failure in the device benchmark belongs to.
    ///
    /// It is NOT read as a separator (spec §11A / WS-B H2): "•5" is ".5", or it
    /// is "5" with a speck, and the text cannot say which. Authoring the dot
    /// would make a degree sign or a glare speck into a decimal point. Refuse.
    ///
    /// Three exemptions, each a case where the glyph provably is not in
    /// separator position:
    ///  - the run already carries its OWN separator ("•0.5", "(12.345)") — a
    ///    second separator there is malformed, so no decimal position is at
    ///    stake. Checked by the caller.
    ///  - the glyph is whitespace, a letter, a digit, or a recognized separator.
    ///  - the glyph is itself preceded by a letter or a digit ("T1:5",
    ///    "DC VOLTS:5"), which makes it a LABEL delimiter between two fields
    ///    rather than a mark inside one number.
    ///
    /// Mirrors `isCaptionGlued`'s leading/trailing asymmetry: the TRAILING side
    /// is deliberately not checked, because that is where units live — "90.0°"
    /// and "98.6 °F" must keep reading, and a trailing mark cannot shift a
    /// decimal position that has already been established to its left.
    private static func leadingForeignGlyph(before token: Token, in normalized: NSString) -> Bool {
        let index = token.range.location - 1
        guard index >= 0,
              let glyph = normalized.substring(with: NSRange(location: index, length: 1)).first
        else { return false }
        if glyph.isWhitespace || glyph.isLetter || isASCIIDigit(glyph) || isSeparator(glyph) {
            return false
        }
        if index - 1 >= 0,
           let preceding = normalized.substring(with: NSRange(location: index - 1, length: 1)).first,
           preceding.isLetter || isASCIIDigit(preceding) {
            return false
        }
        return true
    }

    private static func flatten(_ result: FormatReadingResult) -> FormatParseResult {
        switch result {
        case .valid(let reading): .valid(reading.value)
        case .invalid(let reason): .invalid(reason)
        }
    }

    /// Numeric-token grammar for lenient extraction (see `extractReading`).
    /// Separators are matched INSIDE the token so a comma or a doubled point
    /// cannot silently split one reading into two. Compiled once; the pattern
    /// is a compile-time constant, so the `try!` can never fail at runtime.
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"[-+]?(?:[0-9]+(?:[.,][0-9]*)*|[.,][0-9]+)"#)

    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && ("0"..."9").contains(c)
    }

    private static func isSeparator(_ c: Character) -> Bool {
        c == "." || c == ","
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
