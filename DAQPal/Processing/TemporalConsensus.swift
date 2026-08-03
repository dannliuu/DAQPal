//
//  TemporalConsensus.swift
//  DAQPal
//
//  Spec §11A, decimal-integrity part 2 — the anti-flip-flop rule.
//
//  THE PROBLEM THIS EXISTS FOR
//  A temperature gun display alternates between `80.8` and `808` because the
//  decimal point is a few pixels and survives preprocessing only sometimes.
//  Both readings are numerically valid; accepting the wrong one is a silent
//  10× error. No recognizer choice fixes this — a dot destroyed by
//  thresholding or resampling cannot be recovered by a different model — so
//  the fix is model-independent: refuse to change the published reading by an
//  order of magnitude on ONE frame's evidence.
//
//  ─────────────────────────────────────────────────────────────────────────
//  HOW THIS RELATES TO `TemporalFilter` — BOTH EXIST, DELIBERATELY
//  ─────────────────────────────────────────────────────────────────────────
//  `TemporalFilter` scores VALUE DISTANCE: how far a number sits from the
//  recent window relative to display resolution and recent volatility. It
//  produces a continuous 0...1 consistency that `ConfidenceEngine` multiplies
//  into the fused confidence. It is deliberately blind to how a number was
//  WRITTEN, and — as `FormatValidator`'s header notes — it actively HIDES a
//  consistently shifted series, because a series that is uniformly 10× wrong
//  is perfectly self-consistent. That blindness is correct for its job and
//  fatal for this one.
//
//  `TemporalConsensus` scores FORM: which written reading the window agrees
//  on, and specifically whether a proposed change is a measurement change or a
//  separator event. It answers "what should be published?" and can say
//  "nothing — the window disagrees". It does not smooth, average, or rewrite
//  values, and it does not duplicate distance scoring: value-distance
//  outlier rejection stays entirely in `TemporalFilter` and
//  `PhysicalValidator`. The only value-magnitude comparison here is the coarse
//  gradual-vs-sudden split needed to tell rule 4 from rule 3, and it is
//  deliberately crude for that reason.
//
//  Run both. `TemporalFilter` feeds the confidence product; `TemporalConsensus`
//  gates the published reading.
//
//  Nothing here throws, allocates unboundedly, or reads the clock: timestamps
//  are supplied by the caller (frame presentation time) and used only to expire
//  a stale window. Every outcome is a pure function of the observation
//  sequence, so tests are exactly reproducible.
//

import Foundation

/// Rolling-window consensus over recent FORMATTED readings.
///
/// One instance per device. A value type: copying it snapshots the window,
/// which is what makes the determinism test trivial to write.
struct TemporalConsensus: Equatable, Sendable {

    /// What the window currently supports.
    enum Outcome: Equatable, Sendable {
        /// The window agrees on a reading that is not moving.
        case stable(value: Double, text: String, confidence: Float)
        /// The window agrees the reading is genuinely moving; `value`/`text`
        /// are the newest reading, not a smoothed one.
        case changing(value: Double, text: String, confidence: Float)
        /// The window cannot agree. A first-class result, never a fallback to
        /// one side: `candidates` carries the contenders (ascending) so a
        /// caller can surface the disagreement instead of publishing a coin
        /// flip. Spec's "reject uncertain over accept incorrect".
        case ambiguous(reason: String, candidates: [Double])

        var value: Double? {
            switch self {
            case .stable(let value, _, _), .changing(let value, _, _): value
            case .ambiguous: nil
            }
        }

        var text: String? {
            switch self {
            case .stable(_, let text, _), .changing(_, let text, _): text
            case .ambiguous: nil
            }
        }

        var confidence: Float? {
            switch self {
            case .stable(_, _, let confidence), .changing(_, _, let confidence): confidence
            case .ambiguous: nil
            }
        }

        var isAmbiguous: Bool {
            if case .ambiguous = self { return true }
            return false
        }
    }

    // MARK: - Policy constants
    //
    // These are POLICY, not measurements. Ordering and the establish/migrate
    // asymmetry are the load-bearing parts; the exact numbers are a starting
    // calibration for a ~30 fps frame loop and are documented as such.

    /// Observations retained. ~0.25 s at 30 fps — long enough for a decimal
    /// event to prove itself, short enough that a real change is not held back
    /// for a noticeable time.
    static let windowSize = 7

    /// Observations older than this (relative to the newest timestamp) are
    /// dropped. A gap longer than this means the display may be a different
    /// display; the anchor is released rather than defended.
    static let windowHorizon: TimeInterval = 2.0

    /// Repeats of the same written reading needed to first anchor a stable
    /// value. > 1 so a single frame never becomes the thing everything else is
    /// measured against.
    static let anchorSupport = 2

    /// Frames supporting the NEW form before a decimal event may be accepted.
    /// Strictly greater than `anchorSupport`: rule 1 — a 10× change costs more
    /// evidence than an ordinary one.
    static let decimalEventSupport = 3

    /// Decimal-rescue confidence at or above which the separator verdict counts
    /// as corroboration for a decimal event. Mirrors
    /// `ConfidenceEngine.decimalVetoThreshold`'s spirit at a stricter setting:
    /// accepting a 10× change deserves more than "not vetoed".
    static let decimalRescueConfidence: Float = 0.7

    /// A format prior must be at least this stable before its agreement counts
    /// as corroboration for a decimal event.
    static let priorCorroborationStability: Float = 0.6

    /// Support each side of a decimal disagreement needs before the window is
    /// declared ambiguous rather than merely noisy.
    static let contestedMinimumSupport = 2

    /// How close the two sides' support must be for the window to be called
    /// ambiguous. At margin 1, 3-vs-2 is contested and 4-vs-2 is not.
    static let contestedMargin = 1

    /// Relative step at or below which a NON-decimal change reads as real
    /// movement (rule 4) rather than a jump needing corroboration (rule 3).
    /// 80.8 → 81.2 is 0.5 %; 80.8 → 12.3 is 85 %.
    static let gradualRelativeStep = 0.05

    /// Absolute floor for the above, so readings near zero are not judged by a
    /// percentage of almost nothing.
    static let gradualAbsoluteFloor = 0.05

    /// Repeats a large non-decimal jump needs before it replaces the anchor.
    static let jumpSupport = 2

    /// Multiplier applied to the published confidence on a frame where the
    /// anchor was HELD against contradicting evidence. The reading is still the
    /// best supported one, but the caller should see that it was contested.
    static let heldPenalty: Float = 0.9

    /// Confidence multiplier while no anchor exists yet (start-up frames are
    /// published, but as provisional `.changing`).
    static let provisionalPenalty: Float = 0.8

    // MARK: - State

    private struct Observation: Equatable {
        let value: Double
        let text: String
        let decimalConfidence: Float
        let digitConfidence: Float
        let timestamp: TimeInterval
    }

    private struct Anchor: Equatable {
        var value: Double
        var text: String
        var digitConfidence: Float
        var decimalConfidence: Float
    }

    private var window: [Observation] = []
    private var anchor: Anchor?

    init() {}

    // MARK: - API

    /// Admits one reading and returns what the window now supports.
    ///
    /// - Parameters:
    ///   - value: the parsed value.
    ///   - text: the reading as WRITTEN, separator canonicalized to "." and
    ///     trailing zeros preserved (`NumericReading.text`). This is the
    ///     grouping key: `"80.80"` and `"80.8"` are different forms on purpose,
    ///     because form fidelity is the property being defended.
    ///   - decimalConfidence: confidence in the SEPARATOR determination
    ///     (`DecimalAnalysis.confidence`), not in the digits.
    ///   - digitConfidence: confidence in the glyphs.
    ///   - formatPrior: the learned grammar prior, or `nil`. Used only to
    ///     weight confidence and to corroborate a decimal event — it never
    ///     rewrites or rejects a reading here.
    ///   - timestamp: monotonic frame presentation time, seconds.
    @discardableResult
    mutating func observe(value: Double,
                          text: String,
                          decimalConfidence: Float,
                          digitConfidence: Float,
                          formatPrior: InferredFormat?,
                          timestamp: TimeInterval) -> Outcome {
        // Rule: nothing throws out of the frame loop. A non-finite reading is
        // simply not evidence — the window is left exactly as it was.
        guard value.isFinite else { return holdingOutcome(prior: formatPrior) }

        expire(before: timestamp)
        window.append(Observation(value: value,
                                  text: text,
                                  decimalConfidence: clamp(decimalConfidence),
                                  digitConfidence: clamp(digitConfidence),
                                  timestamp: timestamp))
        if window.count > Self.windowSize {
            window.removeFirst(window.count - Self.windowSize)
        }

        guard let established = anchor else {
            return resolveWithoutAnchor(value: value, text: text, prior: formatPrior)
        }

        if text == established.text {
            return corroborate(established, prior: formatPrior)
        }
        if decimalShiftExponent(from: established.value,
                                text: established.text,
                                to: value,
                                text: text) != nil {
            return resolveDecimalEvent(newValue: value,
                                       newText: text,
                                       against: established,
                                       prior: formatPrior)
        }
        return resolveValueChange(newValue: value,
                                  newText: text,
                                  against: established,
                                  prior: formatPrior)
    }

    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        anchor = nil
    }

    /// The currently anchored reading as written, or `nil` if none is held.
    var anchoredText: String? { anchor?.text }

    /// The currently anchored value, or `nil` if none is held.
    var anchoredValue: Double? { anchor?.value }

    // MARK: - Resolution paths

    /// No anchor yet. Publish provisionally, but refuse to anchor while two
    /// decimal-related forms are both present with comparable support — that is
    /// exactly the flip-flop, and anchoring one side of it would make the other
    /// side look like a change to be resisted.
    private mutating func resolveWithoutAnchor(value: Double,
                                               text: String,
                                               prior: InferredFormat?) -> Outcome {
        let support = support(for: text)
        if let contest = decimalContest(around: text, minimumSupport: 1) {
            return .ambiguous(reason: "decimal disagreement with no established reading "
                              + "(\(text) vs \(contest.text))",
                              candidates: candidateValues(text, contest.text))
        }
        if support >= Self.anchorSupport {
            let established = Anchor(value: value,
                                     text: text,
                                     digitConfidence: lastDigitConfidence(for: text),
                                     decimalConfidence: lastDecimalConfidence(for: text))
            anchor = established
            return .stable(value: value,
                           text: text,
                           confidence: confidence(for: established, support: support, prior: prior))
        }
        // Provisional: published so start-up is not blank, marked `.changing`
        // because nothing has corroborated it yet.
        let provisional = Anchor(value: value,
                                 text: text,
                                 digitConfidence: lastDigitConfidence(for: text),
                                 decimalConfidence: lastDecimalConfidence(for: text))
        return .changing(value: value,
                         text: text,
                         confidence: confidence(for: provisional,
                                                support: support,
                                                prior: prior,
                                                penalty: Self.provisionalPenalty))
    }

    /// The new reading matches the anchor. Normally `.stable` — but if a
    /// decimal-related rival is holding comparable support in the window, the
    /// window is genuinely split and says so rather than quietly siding with
    /// the anchor.
    private mutating func corroborate(_ established: Anchor,
                                      prior: InferredFormat?) -> Outcome {
        var refreshed = established
        refreshed.digitConfidence = lastDigitConfidence(for: established.text)
        refreshed.decimalConfidence = lastDecimalConfidence(for: established.text)
        anchor = refreshed

        let support = support(for: established.text)
        if let contest = decimalContest(around: established.text,
                                        minimumSupport: Self.contestedMinimumSupport) {
            return .ambiguous(reason: "window split between \(established.text) and \(contest.text)",
                              candidates: candidateValues(established.text, contest.text))
        }
        return .stable(value: refreshed.value,
                       text: refreshed.text,
                       confidence: confidence(for: refreshed, support: support, prior: prior))
    }

    /// Rule 1 — the power-of-ten guard. The new reading is the anchor with a
    /// separator added or dropped at a digit boundary, so this is a DECIMAL
    /// EVENT, not a measurement change, and it is held to a higher standard:
    /// sustained support AND independent corroboration (a confident separator
    /// verdict, or agreement from the format prior).
    private mutating func resolveDecimalEvent(newValue: Double,
                                              newText: String,
                                              against established: Anchor,
                                              prior: InferredFormat?) -> Outcome {
        let newSupport = support(for: newText)
        let anchorSupport = support(for: established.text)

        let corroboratedBySeparator =
            averageDecimalConfidence(for: newText) >= Self.decimalRescueConfidence
        let corroboratedByPrior = prior.map {
            $0.stability >= Self.priorCorroborationStability && $0.agrees(withText: newText)
        } ?? false

        if newSupport >= Self.decimalEventSupport, newSupport > anchorSupport {
            guard corroboratedBySeparator || corroboratedByPrior else {
                // Sustained contradicting evidence, but nothing independent
                // vouches for the separator verdict. Publishing either side
                // would be a coin flip on an order of magnitude, and holding
                // the anchor forever would be a deadlock that quietly outlives
                // its own evidence — so this is exactly what `.ambiguous` is
                // for. The anchor is NOT moved.
                return .ambiguous(reason: "\(established.text) → \(newText) is a "
                                  + "power-of-ten separator change with no corroboration",
                                  candidates: candidateValues(established.text, newText))
            }
            let migrated = Anchor(value: newValue,
                                  text: newText,
                                  digitConfidence: lastDigitConfidence(for: newText),
                                  decimalConfidence: lastDecimalConfidence(for: newText))
            anchor = migrated
            return .stable(value: newValue,
                           text: newText,
                           confidence: confidence(for: migrated, support: newSupport, prior: prior))
        }

        if newSupport >= Self.contestedMinimumSupport,
           anchorSupport >= Self.contestedMinimumSupport,
           abs(newSupport - anchorSupport) <= Self.contestedMargin {
            return .ambiguous(reason: "decimal event \(established.text) vs \(newText) "
                              + "unresolved (\(anchorSupport) vs \(newSupport) frames)",
                              candidates: candidateValues(established.text, newText))
        }

        // Rules 1 and 3: one frame, or a still-outnumbered minority, never
        // overwrites a stable formatted reading with a 10× neighbour.
        return .stable(value: established.value,
                       text: established.text,
                       confidence: confidence(for: established,
                                              support: anchorSupport,
                                              prior: prior,
                                              penalty: Self.heldPenalty))
    }

    /// Not a decimal event — the digits themselves differ. Rule 4: gradual real
    /// movement passes straight through as `.changing`. Rule 3: a sudden large
    /// jump waits for a second frame before it is allowed to take over.
    ///
    /// This is the ONLY value-magnitude comparison in this type, and it is
    /// coarse on purpose: judging how far a value may plausibly move belongs to
    /// `TemporalFilter` (distance vs resolution and volatility) and
    /// `PhysicalValidator` (range and rate limits), not here.
    private mutating func resolveValueChange(newValue: Double,
                                             newText: String,
                                             against established: Anchor,
                                             prior: InferredFormat?) -> Outcome {
        let allowance = max(Self.gradualAbsoluteFloor,
                            abs(established.value) * Self.gradualRelativeStep)
        let gradual = abs(newValue - established.value) <= allowance

        if !gradual, support(for: newText) < Self.jumpSupport {
            return .stable(value: established.value,
                           text: established.text,
                           confidence: confidence(for: established,
                                                  support: support(for: established.text),
                                                  prior: prior,
                                                  penalty: Self.heldPenalty))
        }

        let moved = Anchor(value: newValue,
                           text: newText,
                           digitConfidence: lastDigitConfidence(for: newText),
                           decimalConfidence: lastDecimalConfidence(for: newText))
        anchor = moved
        return .changing(value: newValue,
                         text: newText,
                         confidence: confidence(for: moved,
                                                support: support(for: newText),
                                                prior: prior))
    }

    /// What to report when a frame carried no usable reading.
    private func holdingOutcome(prior: InferredFormat?) -> Outcome {
        guard let established = anchor else {
            return .ambiguous(reason: "no reading", candidates: [])
        }
        return .stable(value: established.value,
                       text: established.text,
                       confidence: confidence(for: established,
                                              support: support(for: established.text),
                                              prior: prior,
                                              penalty: Self.heldPenalty))
    }

    // MARK: - Decimal-event detection

    /// The power-of-ten relationship between two readings, if the difference is
    /// explainable by a separator moving WITHIN the same digits.
    ///
    /// Returns the exponent (`+1` when `candidate` is ten times `reference`),
    /// or `nil` when this is an ordinary value change.
    ///
    /// Three conditions, all required:
    /// 1. **Same digit count.** A separator moving inside `808` cannot change
    ///    how many digits there are. `80.8 → 808` is 3 digits either way and
    ///    qualifies; `80.8 → 8080` is a new digit and does not.
    /// 2. **Same sign, both non-zero.** Zero has no ratio.
    /// 3. **Exact power-of-ten ratio** (10, 100 or 1000, either direction)
    ///    within floating-point tolerance. `1...3` covers every separator
    ///    position a real display has; anything larger is not a display flicker.
    ///
    /// Static and pure so it can be unit-tested directly.
    static func decimalShiftExponent(from reference: Double,
                                     text referenceText: String,
                                     to candidate: Double,
                                     text candidateText: String) -> Int? {
        guard reference.isFinite, candidate.isFinite,
              reference != 0, candidate != 0,
              reference.sign == candidate.sign else { return nil }
        guard let referenceGrammar = ReadingGrammar(text: referenceText),
              let candidateGrammar = ReadingGrammar(text: candidateText),
              referenceGrammar.digitCount == candidateGrammar.digitCount else { return nil }

        for exponent in [-3, -2, -1, 1, 2, 3] {
            let scaled = reference * pow(10, Double(exponent))
            let tolerance = max(abs(scaled), abs(candidate)) * 1e-9
            if abs(scaled - candidate) <= tolerance { return exponent }
        }
        return nil
    }

    private func decimalShiftExponent(from reference: Double,
                                      text referenceText: String,
                                      to candidate: Double,
                                      text candidateText: String) -> Int? {
        Self.decimalShiftExponent(from: reference, text: referenceText,
                                  to: candidate, text: candidateText)
    }

    // MARK: - Window queries

    private mutating func expire(before timestamp: TimeInterval) {
        var removedAny = false
        while let oldest = window.first, timestamp - oldest.timestamp > Self.windowHorizon {
            window.removeFirst()
            removedAny = true
        }
        // A gap longer than the horizon emptied the window: the anchor has no
        // evidence left, so it is released rather than defended against
        // whatever the camera is looking at now.
        if removedAny, window.isEmpty { anchor = nil }
    }

    private func support(for text: String) -> Int {
        window.reduce(0) { $1.text == text ? $0 + 1 : $0 }
    }

    /// The best-supported reading in the window that is a decimal shift of
    /// `text` and has at least `minimumSupport` frames behind it, when its
    /// support is within `contestedMargin` of `text`'s own.
    ///
    /// Ties between rivals are broken by ascending text so the result is
    /// deterministic regardless of dictionary ordering.
    private func decimalContest(around text: String,
                                minimumSupport: Int) -> (text: String, support: Int)? {
        guard let reference = window.last(where: { $0.text == text }) else { return nil }
        let ownSupport = support(for: text)
        guard ownSupport >= minimumSupport else { return nil }

        var best: (text: String, support: Int)?
        var seen: Set<String> = [text]
        for observation in window where !seen.contains(observation.text) {
            seen.insert(observation.text)
            guard Self.decimalShiftExponent(from: reference.value,
                                            text: reference.text,
                                            to: observation.value,
                                            text: observation.text) != nil else { continue }
            let rivalSupport = support(for: observation.text)
            guard rivalSupport >= minimumSupport,
                  abs(rivalSupport - ownSupport) <= Self.contestedMargin else { continue }
            if let currentBest = best {
                if rivalSupport > currentBest.support
                    || (rivalSupport == currentBest.support && observation.text < currentBest.text) {
                    best = (observation.text, rivalSupport)
                }
            } else {
                best = (observation.text, rivalSupport)
            }
        }
        return best
    }

    private func averageDecimalConfidence(for text: String) -> Float {
        var total: Float = 0
        var count = 0
        for observation in window where observation.text == text {
            total += observation.decimalConfidence
            count += 1
        }
        guard count > 0 else { return 0 }
        return total / Float(count)
    }

    private func lastDigitConfidence(for text: String) -> Float {
        window.last(where: { $0.text == text })?.digitConfidence ?? 0
    }

    private func lastDecimalConfidence(for text: String) -> Float {
        window.last(where: { $0.text == text })?.decimalConfidence ?? 0
    }

    private func candidateValues(_ a: String, _ b: String) -> [Double] {
        var values: [Double] = []
        for text in [a, b] {
            if let observation = window.last(where: { $0.text == text }) {
                values.append(observation.value)
            }
        }
        return values.sorted()
    }

    // MARK: - Confidence

    /// Published confidence for one outcome.
    ///
    /// `digit × decimal` keeps the §11A separation (a confident set of glyphs
    /// must not inherit trust the separator has not earned), `supportFactor`
    /// rewards a reading the window actually agrees on, and the format prior
    /// contributes its own 0...1 multiplier. Every factor is ≤ 1, so this can
    /// only depress — consensus never inflates a reading's confidence above
    /// what the recognizer supplied.
    private func confidence(for anchor: Anchor,
                            support: Int,
                            prior: InferredFormat?,
                            penalty: Float = 1) -> Float {
        let base = clamp(anchor.digitConfidence) * clamp(anchor.decimalConfidence)
        let fraction = Float(max(0, support)) / Float(max(1, window.count))
        let supportFactor = 0.5 + 0.5 * min(1, fraction)
        let priorFactor = prior?.plausibility(ofText: anchor.text) ?? 1
        return clamp(base * supportFactor * priorFactor * clamp(penalty))
    }

    private func clamp(_ value: Float) -> Float { max(0, min(1, value)) }
}
