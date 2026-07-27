//
//  ScreenFieldAnalyzer.swift
//  DAQPal
//
//  Screen understanding (spec §10/§12): the default `ScreenAnalyzing`
//  implementation. A locked display is NOT one OCR region — it is a small
//  layout of labels, numbers and units, and the whole point of this pass is to
//  recover that layout so a bare "12.345" becomes "VOLTAGE = 12.345 V".
//
//  Three deliberate positions, each of which has a failure mode behind it:
//
//  1. ANALYSIS IS GENEROUS, SELECTION IS NOT. Everything found is returned
//     unselected (`ScreenField.isSelected == false`). Nothing this file emits
//     can reach the dataset without a user act, so recall is worth more than
//     precision here — a spurious candidate costs one glance, a missed field
//     costs a re-analysis.
//
//  2. FORMAT INFERENCE IS A SUGGESTION, NEVER A CONSTRAINT. Inferred formats
//     always carry `constrainToFormat = false`. One frame cannot prove a
//     display's digit grammar: a meter parked at "0.00" would mint a
//     3-digit/2-decimal rule that then rejects "12.345" forever. This project
//     already shipped a mass-rejection bug of exactly that shape once; the
//     inferred format seeds the format sheet, and only the user's confirmation
//     there may turn constraining on.
//
//  3. UNIT MATCHING IS EXACT-TOKEN, NEVER SUBSTRING. "A" is a unit; "ALARM"
//     is not. Substring matching would classify practically every word on a
//     panel as a unit, so a token must match a known unit in full after
//     trimming whitespace and framing punctuation.
//
//  4. THE UNIT VOCABULARY IS NOT A GATE ON RECALL. `unitTokens` can never be
//     complete — instrument panels print VAC, PSI, CFM, kPa, lux, pH, ppm and
//     hundreds more — so whether a trailing word is RECOGNIZED must not decide
//     whether the number in front of it is a reading at all. Dominance
//     (`numericIsDominant`) therefore detaches any unit-SHAPED trailing token,
//     recognized or not, and the recognized-ness only decides how much the
//     resulting unit is trusted afterwards: a recognized token is direct
//     evidence and outranks neighbouring geometry, an unrecognized one is a
//     guess kept for recall that a real neighbouring unit run may replace.
//
//  Coordinate space: input is the perspective-corrected canonical image and all
//  returned regions are normalized in that image's space, TOP-LEFT origin.
//  Vision's bottom-left boxes are flipped at this boundary and nowhere else,
//  matching `VisionOCR`.
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct ScreenFieldAnalyzer: ScreenAnalyzing {

    // MARK: - Configuration

    /// Recognition level. `.accurate` is the default for the same reason
    /// `VisionOCR` defaults to it: `.fast` reports ~0.3 confidence even on
    /// clean glyphs for the CANDIDATE it returns, and this file surfaces that
    /// candidate confidence as `detectionConfidence`.
    private let recognitionLevel: VNRequestTextRecognitionLevel

    /// Candidates below this confidence are discarded before classification.
    /// Zero by default — analysis is generous (see the file header) and the
    /// per-field confidence is shown, so the user can judge.
    private let minimumConfidence: Float

    init(recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
         minimumConfidence: Float = 0) {
        self.recognitionLevel = recognitionLevel
        self.minimumConfidence = minimumConfidence
    }

    // MARK: - Tuning

    /// Padding added around a numeric region, as a fraction of that region's
    /// own size, applied on every side. Vision's boxes hug the recognized glyph
    /// run; a subsequent per-field crop that used them verbatim would shave
    /// antialiased glyph edges (and, on segment displays, the outermost
    /// segment) before OCR ever saw them. Relative rather than absolute so a
    /// small field gets a proportionally small pad instead of being doubled.
    static let numericRegionPadding: CGFloat = 0.04

    /// Two regions are "on the same line" when their vertical centers differ by
    /// at most this fraction of the numeric field's height.
    static let sameLineTolerance: CGFloat = 0.5

    /// Largest horizontal gap, in canonical width fractions, across which a
    /// label or unit may be attached to a number. Beyond this the neighbour is
    /// more likely to belong to a different column.
    static let maximumHorizontalGap: CGFloat = 0.40

    /// Largest vertical gap for a label sitting ABOVE its number, expressed as
    /// a multiple of the number's height with an absolute floor so a physically
    /// small readout can still reach its caption.
    static let maximumVerticalGapFactor: CGFloat = 1.5
    static let minimumVerticalGap: CGFloat = 0.08

    // MARK: - ScreenAnalyzing

    func analyze(canonicalImage: CVPixelBuffer) async -> [ScreenField] {
        PipelineMetrics.shared.measure(.analysis) {
            recognize(canonicalImage)
        }
    }

    /// Whole pass, synchronous and non-throwing: any Vision failure degrades to
    /// an empty result rather than propagating into the frame loop.
    private func recognize(_ image: CVPixelBuffer) -> [ScreenField] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        // Digit strings, not prose: correction would "fix" readings into words,
        // and language detection has nothing useful to detect here.
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]

        // The canonical image is already upright, so `.up` (the default) holds.
        let handler = VNImageRequestHandler(cvPixelBuffer: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        var fields: [ScreenField] = []
        for observation in request.results ?? [] {
            // The candidate's confidence, not the observation's: the latter is
            // a detection-level score that sits near 1.0 for almost anything
            // Vision decides is text, so filtering or displaying it would be
            // meaningless. `VisionOCR` surfaces the candidate value too.
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= minimumConfidence else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Vision normalizes boxes with a BOTTOM-LEFT origin; the project
            // convention is top-left. Flip y only (no regionOfInterest is set,
            // so the box is already in full-image coordinates).
            let box = observation.boundingBox
            guard box.width > 0, box.height > 0 else { continue }
            let raw = NormalizedROI(x: box.minX,
                                    y: 1 - box.maxY,
                                    width: box.width,
                                    height: box.height)

            let kind = Self.classify(text)
            let region = Self.finalRegion(raw, kind: kind)
            guard region.width > 0, region.height > 0 else { continue }

            var format = DisplayFormat.unconstrained
            var label = text
            if kind == .numeric {
                if let inferred = Self.inferredFormat(from: text) { format = inferred }
                // Candidate, not recognized-only: the vocabulary is incomplete
                // by construction, so "12 PSI" must still report "PSI".
                format.unit = Self.trailingUnitCandidate(in: text)
                // A caption fused into the reading's own run is the common
                // case, not the rare one — Vision groups a whole line, so
                // "VOLTAGE 12.345 mV" arrives as ONE observation. Recovering
                // it here is what keeps two rows of a stacked panel apart.
                label = Self.leadingLabel(in: text) ?? ""
            }
            if kind == .unit { format.unit = Self.unitToken(in: text) }

            fields.append(ScreenField(region: region,
                                      kind: kind,
                                      label: label,
                                      format: format,
                                      isSelected: false,
                                      detectionConfidence: candidate.confidence,
                                      isUserAdjusted: false))
        }

        return Self.ordered(Self.associating(fields))
    }

    // MARK: - Region shaping

    /// Numeric regions are padded; every region is then clipped to the unit
    /// square.
    ///
    /// `NormalizedROI.clamped()` is deliberately NOT used. Its 5% × 3% floor is
    /// an ROI-EDITOR minimum (a target a finger can grab), meaningless for a
    /// text region and actively harmful here: a single-glyph reading is 2% wide
    /// and would be inflated 2.5×, after which every association cost — maxX,
    /// midY, width, height — is computed against geometry the display does not
    /// have.
    static func finalRegion(_ region: NormalizedROI, kind: FieldContentKind) -> NormalizedROI {
        guard kind == .numeric else { return unitSquareClamped(region) }
        let padX = region.width * numericRegionPadding
        let padY = region.height * numericRegionPadding
        return unitSquareClamped(NormalizedROI(x: region.x - padX,
                                               y: region.y - padY,
                                               width: region.width + 2 * padX,
                                               height: region.height + 2 * padY))
    }

    /// Clips into 0...1 with none of `clamped()`'s minimum-size inflation.
    ///
    /// Clips rather than shifts: the canonical warp is fitted to the bezel, so
    /// a reading flush against the image's left edge is ordinary. Sliding such
    /// a box right to preserve its width would move it off the glyphs it was
    /// measured from — losing padding on the side that overflowed and
    /// over-extending on the opposite one.
    static func unitSquareClamped(_ region: NormalizedROI) -> NormalizedROI {
        let minX = min(max(region.x, 0), 1)
        let maxX = min(max(region.x + region.width, 0), 1)
        let minY = min(max(region.y, 0), 1)
        let maxY = min(max(region.y + region.height, 0), 1)
        return NormalizedROI(x: minX,
                             y: minY,
                             width: max(0, maxX - minX),
                             height: max(0, maxY - minY))
    }

    // MARK: - Classification

    /// Known unit tokens, lowercased. Exact-token matching only (file header,
    /// position 3). Both the micro sign U+00B5 and the Greek mu U+03BC are
    /// listed because OCR emits either, as are the ASCII spellings ("u", "ohm")
    /// that Vision produces when it cannot resolve the symbol.
    static let unitTokens: Set<String> = [
        // Voltage
        "v", "mv", "kv", "uv", "µv", "μv",
        // Current
        "a", "ma", "ua", "µa", "μa", "na", "pa", "ka",
        // Resistance
        "ω", "Ω", "ohm", "ohms", "kω", "mω", "kohm", "mohm",
        // Power / energy
        "w", "kw", "mw", "va", "wh", "kwh", "mwh", "kj", "j",
        // Frequency
        "hz", "khz", "mhz", "ghz", "rpm",
        // Temperature
        "°c", "°f", "c", "f", "k",
        // Capacitance / inductance (F and H double as farad/henry)
        "uf", "µf", "μf", "nf", "pf", "mf", "h", "mh", "uh", "µh", "μh",
        // Misc electrical
        "s", "db", "dbm", "%", "ppm",
        // Time. The word forms ("min", "sec", "hr") are deliberately absent:
        // "MIN" on a bench instrument means minimum far more often than
        // minutes, and mislabeling an annunciator as a unit is worse than
        // missing a unit the user can type in.
        "ms", "us", "µs", "μs", "ns"
    ]

    /// Characters stripped from both ends before a unit is matched — OCR often
    /// glues a colon, comma or bracket onto the token.
    private static let framingPunctuation = CharacterSet(charactersIn: "[](){}<>:;,.\"'“”‘’ \t\n")

    /// Longest run accepted as unit-SHAPED (see `unitLikeToken`). Six covers
    /// the spellings instruments actually print — "PSI", "VAC", "kPa", "mbar",
    /// "mmHg", "µS/cm" — without stretching to sentence fragments.
    static let maximumUnitLikeLength = 6

    /// Non-letter characters a unit-shaped token may contain. Deliberately
    /// tiny: digits are excluded so "2ND" and "CH1" can never be read as a
    /// number plus a unit, and whitespace is excluded so a multi-word run
    /// ("VOLTS DC READY") is not unit-shaped either.
    static let unitLikeSymbols: Set<Character> = ["°", "%", "/", "·", "^"]

    /// The unit token contained in `text`, or nil when `text` is not a unit.
    ///
    /// Returns the ORIGINAL trimmed spelling rather than a canonicalized one:
    /// matching is case-insensitive (OCR case on a segment display is not
    /// trustworthy) but rewriting case would silently change meaning — "MV"
    /// into "mV" turns megavolts into millivolts. The recognized spelling is
    /// what the instrument actually shows, so that is what is kept.
    static func unitToken(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: framingPunctuation)
        guard !trimmed.isEmpty else { return nil }
        return unitTokens.contains(trimmed.lowercased()) ? trimmed : nil
    }

    /// The token in `text` if it has the SHAPE of a unit, whether or not
    /// `unitTokens` knows it — one short word of letters (plus a few unit
    /// symbols) and nothing else.
    ///
    /// This is the recall half of position 4 in the file header. It is never
    /// used to classify a run on its own: a bare "MAX" or "HOLD" is unit-shaped
    /// too, and calling those units would be exactly the substring-matching
    /// mistake position 3 forbids. Its only job is to answer "could the word
    /// AFTER this number be its unit?", where the number is what carries the
    /// evidence that a unit is what belongs there.
    ///
    /// Returns the original trimmed spelling, for the same reason `unitToken`
    /// does: rewriting case changes meaning.
    static func unitLikeToken(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: framingPunctuation)
        guard !trimmed.isEmpty, trimmed.count <= maximumUnitLikeLength else { return nil }
        // At least one letter, so punctuation runs ("---", "...") and framing
        // leftovers cannot pass as units.
        guard trimmed.contains(where: \.isLetter) else { return nil }
        guard trimmed.allSatisfy({ $0.isLetter || unitLikeSymbols.contains($0) }) else { return nil }
        return trimmed
    }

    /// The unit that `trailing` — the text a numeric token was followed by —
    /// contributes to that number, or nil when it is not the number's unit.
    ///
    /// A RECOGNIZED unit attaches with or without a separator: "1.5mA" and
    /// "1.5 mA" are the same reading, and "5A" is a reading rather than a
    /// caption precisely because "A" is a known unit.
    ///
    /// An UNRECOGNIZED unit-shaped word must be preceded by a separator. That
    /// asymmetry is the whole defence of "2ND": letters glued straight onto a
    /// digit are an annunciator, not a reading with a unit, and without the
    /// separator requirement "2ND" would split into the number 2 and the unit
    /// "ND". It mirrors the rule `numericIsDominant` already applies on the
    /// leading side for "CH1".
    static func detachableUnit(in trailing: String) -> String? {
        if let recognized = unitToken(in: trailing) { return recognized }
        guard let first = trailing.first, !(first.isLetter || first.isNumber) else { return nil }
        return unitLikeToken(in: trailing)
    }

    /// Splits `text` around the numeric token `FormatValidator` would extract
    /// from it, into the text before that token, the token, and the text after.
    /// Nil when the run holds no numeric token at all.
    ///
    /// This is the shared basis for reading a fused line: Vision groups a whole
    /// line before returning it, so "VOLTAGE 12.345 mV" is one observation with
    /// a caption on one side of the number and a unit on the other.
    ///
    /// Token selection matches `FormatValidator.extractNumber` exactly (same
    /// grammar, most digits wins, leftmost on a tie, every token anchored to a
    /// real digit) so the recovered label and unit describe the same token the
    /// inferred format was measured from. The confusable map is 1:1
    /// ASCII→ASCII, so offsets into the normalized string index the original.
    static func numericSplit(in text: String) -> (leading: String, token: String, trailing: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let source = trimmed as NSString
        let normalized = FormatValidator.normalizeConfusables(trimmed) as NSString
        let full = NSRange(location: 0, length: normalized.length)

        var best: (range: NSRange, digits: Int)?
        for match in numberPattern.matches(in: normalized as String, range: full) {
            let digits = normalized.substring(with: match.range).filter(isASCIIDigit).count
            guard digits > 0 else { continue }
            guard source.substring(with: match.range).contains(where: isASCIIDigit) else { continue }
            if best == nil || digits > best!.digits { best = (match.range, digits) }
        }
        guard let best else { return nil }
        let end = best.range.location + best.range.length
        return (source.substring(to: best.range.location),
                source.substring(with: best.range),
                source.substring(from: end))
    }

    /// Numeric-token grammar, identical to `FormatValidator.extractNumber`'s.
    /// The pattern is a compile-time constant, so the `try!` cannot fail.
    private static let numberPattern = try! NSRegularExpression(
        pattern: #"[-+]?(?:\d+\.\d*|\.\d+|\d+)"#)

    /// ASCII-only, matching `FormatValidator`: a Devanagari digit is not a
    /// reading this pipeline can parse, so it must not be counted as one.
    private static func isASCIIDigit(_ c: Character) -> Bool {
        c.isASCII && ("0"..."9").contains(c)
    }

    /// The unit written INSIDE a reading, e.g. the "V" of "12.345 V" or the
    /// "mA" of "1.5mA".
    ///
    /// A unit printed close to its number very often arrives fused into the
    /// same observation instead of as a neighbour to associate with — and a
    /// unit small enough to be a single glyph is frequently not returned as its
    /// own observation at all. Reading the suffix recovers the unit in both
    /// cases; geometric association then only has to handle units that really
    /// are separate runs.
    static func trailingUnit(in text: String) -> String? {
        guard let split = numericSplit(in: text) else { return nil }
        return unitToken(in: split.trailing)
    }

    /// The unit a reading carries in its own text, RECOGNIZED OR NOT: "V" from
    /// "12.345 V", "PSI" from "12 PSI", "VAC" from "230 VAC".
    ///
    /// This is what `recognize` stores, rather than `trailingUnit`. Dropping an
    /// unrecognized token would throw away the one place the instrument states
    /// its own unit, and `unitTokens` is by construction incomplete — the guess
    /// is worth strictly more than the blank, because an inferred format never
    /// constrains (file header, position 2) so nothing downstream can reject a
    /// reading over it, and `associating` still lets a real neighbouring unit
    /// run replace it.
    static func trailingUnitCandidate(in text: String) -> String? {
        guard let split = numericSplit(in: text) else { return nil }
        return detachableUnit(in: split.trailing)
    }

    /// The caption written INSIDE a reading, e.g. the "VOLTAGE" of
    /// "VOLTAGE 12.345 mV". Symmetric to `trailingUnit`, and for the same
    /// reason: on a real instrument the caption and its number are one line.
    ///
    /// A letter is required so that stray framing ("(12.345)") or a thousands
    /// group ("12,345") cannot mint a caption out of punctuation or digits.
    static func leadingLabel(in text: String) -> String? {
        guard let split = numericSplit(in: text) else { return nil }
        let leading = split.leading.trimmingCharacters(in: framingPunctuation)
        guard leading.contains(where: \.isLetter) else { return nil }
        return leading
    }

    /// True when digits are the STRICT majority of the non-whitespace text —
    /// the recall half of numeric classification, catching readings whose
    /// separators or exponent markers the strict extractor cannot place.
    ///
    /// Strict, because a tie is the shape of an annunciator, not a reading:
    /// "T1" and "A1" are half digits and are captions, not measurements.
    static func isMostlyDigits(_ text: String) -> Bool {
        let meaningful = text.filter { !$0.isWhitespace }
        guard !meaningful.isEmpty else { return false }
        let digits = meaningful.filter(\.isNumber).count
        guard digits > 0 else { return false }
        return digits * 2 > meaningful.count
    }

    /// True when the numeric token is what the run is ABOUT rather than merely
    /// present in it.
    ///
    /// Mere presence is not enough: "CH1" contains a digit, and treating it as
    /// a reading both mints a spurious field and removes the only caption the
    /// real reading on that row could have used. Dominance is measured over the
    /// RESIDUAL — the run with a detachable caption and a fused unit removed —
    /// because those two are exactly the parts of a line that belong to the
    /// number rather than competing with it.
    ///
    /// A caption only detaches when a separator ends it. "VOLTAGE 12.345" is a
    /// caption beside a number; "CH1" is a caption with a digit glued on, and
    /// detaching "CH" there is what would mint the spurious field.
    ///
    /// The unit detaches under `detachableUnit`, which does NOT require the
    /// word to be in `unitTokens`. Requiring recognition here was a recall bug:
    /// "230 VAC", "12 PSI" and "0.5 PSI" each yielded NO numeric field at all,
    /// because the unrecognized word stayed in the residual and outweighed the
    /// digits. Whether the vocabulary happens to list a unit says nothing about
    /// whether the display in front of the camera is showing a number.
    static func numericIsDominant(leading: String, token: String, trailing: String) -> Bool {
        var residual = token
        if let last = leading.last, last.isLetter || last.isNumber {
            residual = leading + residual
        }
        if detachableUnit(in: trailing) == nil { residual += trailing }

        let meaningful = residual.filter { !$0.isWhitespace }.count
        guard meaningful > 0 else { return false }
        return token.count * 2 > meaningful || isMostlyDigits(residual)
    }

    /// Classifies one recognized run.
    ///
    /// Order matters: unit first, so a bare "F" is a farad rather than a label,
    /// and numeric before label, so "12.345" is never treated as prose.
    static func classify(_ text: String) -> FieldContentKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        if unitToken(in: trimmed) != nil { return .unit }

        if let split = numericSplit(in: trimmed),
           numericIsDominant(leading: split.leading,
                             token: split.token,
                             trailing: split.trailing) {
            return .numeric
        }

        // Alphabetic and not a dominant number: a caption. Interior separators
        // and digits are allowed ("DC VOLTS", "PEAK-HOLD", "CH1") — a caption
        // that carries a channel number is still a caption, and it must stay
        // available to the number it captions.
        if trimmed.contains(where: \.isLetter) { return .label }

        return .unknown
    }

    // MARK: - Format inference

    /// Infers a `DisplayFormat` from one recognized reading.
    ///
    /// `digitCount` is every digit in the token and `decimalPosition` the count
    /// of digits BEFORE the separator (nil for an integer display, per
    /// `DisplayFormat`'s own convention).
    ///
    /// `signAllowed` is ALWAYS true, and `constrainToFormat` ALWAYS false — see
    /// the file header. Inferring `signAllowed` from one frame reproduces the
    /// mass-rejection bug in a second place: a DMM parked at a positive reading
    /// would mint `signAllowed = false`, and every reading after it went
    /// negative would be rejected. Seeing a sign proves signs occur; not seeing
    /// one proves nothing, so the permissive value is the only sound one — it
    /// is also what `DisplayFormat.unconstrained` already seeds. Returns nil
    /// when the text holds no numeric token at all.
    static func inferredFormat(from text: String) -> DisplayFormat? {
        guard let extracted = FormatValidator.extractNumber(from: text) else { return nil }

        var body = extracted.matched
        if let first = body.first, first == "-" || first == "+" {
            body.removeFirst()
        }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        let integerDigits = parts.first?.filter(\.isNumber).count ?? 0
        let fractionDigits = parts.count > 1 ? parts[1].filter(\.isNumber).count : 0
        let digitCount = max(1, integerDigits + fractionDigits)

        return DisplayFormat(digitCount: digitCount,
                             decimalPosition: body.contains(".") ? integerDigits : nil,
                             signAllowed: true,
                             unit: nil,
                             minimumValue: nil,
                             maximumValue: nil,
                             constrainToFormat: false)
    }

    // MARK: - Label / unit association

    /// Attaches each numeric field's nearest caption and unit.
    ///
    /// This is the component's reason to exist: without it the UI can only
    /// offer anonymous numbers. Instrument panels put the caption to the LEFT
    /// of the number or directly ABOVE it, and the unit to the RIGHT on the
    /// same line, so those are the only directions searched — a unit found
    /// below a number belongs to the row underneath, not to this one.
    ///
    /// Assignment is greedy over globally sorted costs and EXCLUSIVE: one
    /// caption serves one number. On a stacked panel the alternative (each
    /// number independently grabbing its nearest caption) lets a single
    /// "VOLTAGE" caption be claimed by two rows, which reads as a labeling bug
    /// to the user.
    ///
    /// Pure and geometric — no Vision types — so it is directly testable.
    static func associating(_ fields: [ScreenField]) -> [ScreenField] {
        var result = fields
        let numericIndices = fields.indices.filter { fields[$0].kind == .numeric }
        guard !numericIndices.isEmpty else { return result }

        let labelIndices = fields.indices.filter { fields[$0].kind == .label }
        let unitIndices = fields.indices.filter { fields[$0].kind == .unit }

        // A caption read out of the number's own text is direct evidence and
        // outranks any neighbour geometry could offer, so those numbers are
        // excluded here — which also frees the neighbouring caption to be
        // claimed by a number that has none yet.
        let unlabeled = numericIndices.filter { fields[$0].label.isEmpty }
        for (numeric, label) in bestPairs(unlabeled, labelIndices, in: fields, cost: labelCost) {
            result[numeric].label = fields[label].label
                .trimmingCharacters(in: framingPunctuation)
        }
        // Units are assigned in two passes, weakest evidence last.
        //
        // A RECOGNIZED unit read out of the number's own text is direct
        // evidence and outranks any neighbour geometry could offer, so those
        // numbers never compete — which also frees the neighbouring token to be
        // claimed by a number that has no unit yet.
        //
        // An UNRECOGNIZED unit-shaped token ("AC", "PSI") is only a guess kept
        // for recall, so a number holding one does compete: a real unit run
        // beside it is better evidence and replaces it. It competes SECOND,
        // though, because a number with nothing at all has more to gain from
        // the same token — otherwise a nearer already-guessed number would win
        // it and leave the empty one dimensionless.
        var claimed: Set<Int> = []
        let noUnit = numericIndices.filter { fields[$0].format.unit == nil }
        let guessedUnit = numericIndices.filter {
            guard let unit = fields[$0].format.unit else { return false }
            return unitToken(in: unit) == nil
        }
        for tier in [noUnit, guessedUnit] where !tier.isEmpty {
            let available = unitIndices.filter { !claimed.contains($0) }
            for (numeric, unit) in bestPairs(tier, available, in: fields, cost: unitCost) {
                claimed.insert(unit)
                // Guarded: a neighbour that does not re-derive a unit must not
                // erase the candidate the number read out of its own text.
                if let recognized = unitToken(in: fields[unit].label) {
                    result[numeric].format.unit = recognized
                }
            }
        }
        return result
    }

    /// Greedy exclusive matching: every admissible (numeric, neighbour) pair is
    /// scored, sorted by cost, and consumed cheapest-first while both ends are
    /// still free. Index tie-breaking keeps the result deterministic when two
    /// pairs score identically.
    private static func bestPairs(_ numericIndices: [Int],
                                  _ neighbourIndices: [Int],
                                  in fields: [ScreenField],
                                  cost: (_ neighbour: NormalizedROI, _ numeric: NormalizedROI) -> CGFloat?) -> [(Int, Int)] {
        var scored: [(numeric: Int, neighbour: Int, cost: CGFloat)] = []
        for n in numericIndices {
            for m in neighbourIndices {
                guard let c = cost(fields[m].region, fields[n].region) else { continue }
                scored.append((n, m, c))
            }
        }
        scored.sort {
            $0.cost != $1.cost ? $0.cost < $1.cost
                : ($0.numeric != $1.numeric ? $0.numeric < $1.numeric : $0.neighbour < $1.neighbour)
        }

        var usedNumeric: Set<Int> = []
        var usedNeighbour: Set<Int> = []
        var pairs: [(Int, Int)] = []
        for entry in scored {
            guard !usedNumeric.contains(entry.numeric),
                  !usedNeighbour.contains(entry.neighbour) else { continue }
            usedNumeric.insert(entry.numeric)
            usedNeighbour.insert(entry.neighbour)
            pairs.append((entry.numeric, entry.neighbour))
        }
        return pairs
    }

    /// Cost of attaching `label` to `numeric`, or nil when the geometry makes
    /// it inadmissible. Same-line-left is scored by the horizontal gap; above
    /// is scored by the vertical gap plus a half-weighted horizontal centre
    /// offset, so a caption drifting sideways loses to one sitting squarely on
    /// top. The cheaper direction wins.
    ///
    /// EVERY term is expressed in multiples of the number's OWN box — x
    /// distances over its width, y distances over its height — which is what
    /// puts the two directions on one comparable scale. Raw normalized units
    /// would not: normalized x and y are the same number only on a square
    /// canonical image, and a 720×480 warp makes a normalized vertical unit 1.5×
    /// the physical distance of a horizontal one, so the "above" cost would be
    /// silently inflated against the "left" cost by the image's aspect ratio.
    ///
    /// Admissibility limits stay in absolute canonical fractions: they express
    /// how far across the PANEL a caption may live, which is a property of the
    /// panel, not of the number.
    static func labelCost(_ label: NormalizedROI, _ numeric: NormalizedROI) -> CGFloat? {
        let l = label.cgRect, n = numeric.cgRect
        let w = max(n.width, .ulpOfOne), h = max(n.height, .ulpOfOne)
        var best: CGFloat?

        if abs(l.midY - n.midY) <= sameLineTolerance * n.height,
           l.maxX <= n.minX + 0.1 * n.width {
            let gap = max(0, n.minX - l.maxX)
            if gap <= maximumHorizontalGap { best = gap / w }
        }

        if l.maxY <= n.minY + 0.25 * n.height {
            let dy = max(0, n.minY - l.maxY)
            let dx = abs(l.midX - n.midX)
            let overlaps = l.maxX > n.minX && l.minX < n.maxX
            let verticalLimit = max(minimumVerticalGap, maximumVerticalGapFactor * n.height)
            if dy <= verticalLimit, overlaps || dx <= 0.5 * n.width {
                let c = dy / h + 0.5 * (dx / w)
                best = best.map { min($0, c) } ?? c
            }
        }
        return best
    }

    /// Cost of attaching `unit` to `numeric`: same line, starting at or after
    /// the number's right edge (a small overlap is tolerated because Vision
    /// boxes for adjacent runs can abut).
    static func unitCost(_ unit: NormalizedROI, _ numeric: NormalizedROI) -> CGFloat? {
        let u = unit.cgRect, n = numeric.cgRect
        guard abs(u.midY - n.midY) <= sameLineTolerance * n.height,
              u.minX >= n.maxX - 0.1 * n.width else { return nil }
        let gap = max(0, u.minX - n.maxX)
        return gap <= maximumHorizontalGap ? gap : nil
    }

    // MARK: - Ordering

    /// Vertical slack, in canonical height fractions, within which two regions
    /// count as the same row.
    static let rowTolerance: CGFloat = 0.02

    /// Numeric fields first so the UI can present capturable things before
    /// decoration; within each group, natural reading order (top-to-bottom,
    /// then left-to-right) with a row tolerance so a slightly uneven row does
    /// not scramble.
    ///
    /// Rows are BUILT before anything is sorted by x. The obvious alternative —
    /// one comparator that falls back to x when |Δy| is within tolerance — is
    /// not a strict weak ordering: with y = 0.00 / 0.015 / 0.030 the middle
    /// element ties with both ends while the ends compare by y, so the relation
    /// is not transitive. `sorted(by:)` requires one and produces arbitrary
    /// output (not merely an odd order) when it does not get one.
    static func ordered(_ fields: [ScreenField]) -> [ScreenField] {
        func readingOrder(_ group: [ScreenField]) -> [ScreenField] {
            // Index carried alongside so every tie breaks deterministically:
            // Swift's sort is not documented as stable.
            let byY = group.enumerated().sorted {
                $0.element.region.y != $1.element.region.y
                    ? $0.element.region.y < $1.element.region.y
                    : $0.offset < $1.offset
            }
            // Each row is anchored on its topmost member, so a long column of
            // slightly-drifting regions cannot chain into one giant row.
            var rows: [[(offset: Int, element: ScreenField)]] = []
            for item in byY {
                if let anchor = rows.last?.first,
                   item.element.region.y - anchor.element.region.y <= rowTolerance {
                    rows[rows.count - 1].append(item)
                } else {
                    rows.append([item])
                }
            }
            return rows.flatMap { row in
                row.sorted {
                    $0.element.region.x != $1.element.region.x
                        ? $0.element.region.x < $1.element.region.x
                        : $0.offset < $1.offset
                }.map(\.element)
            }
        }
        let numeric = readingOrder(fields.filter { $0.kind == .numeric })
        let described = readingOrder(fields.filter { $0.kind == .label || $0.kind == .unit })
        let rest = readingOrder(fields.filter { $0.kind == .unknown })
        return numeric + described + rest
    }
}
