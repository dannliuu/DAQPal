//
//  DisplayFormatInference.swift
//  DAQPal
//
//  Spec §11A, decimal-integrity part 1 — a FORMAT PRIOR learned from history.
//
//  ─────────────────────────────────────────────────────────────────────────
//  PRIOR, NOT CONSTRAINT. READ THIS BEFORE USING THIS TYPE.
//  ─────────────────────────────────────────────────────────────────────────
//  An `InferredFormat` describes what this display has been SHOWING, inferred
//  from readings the pipeline already accepted. It is evidence about the
//  grammar, not a declaration of it. `DisplayFormat` (user-configured, spec
//  Mode 2) is the only thing in this codebase allowed to REJECT a reading for
//  its shape; this type is only allowed to raise or lower a reading's
//  plausibility.
//
//  Concretely, this type MUST NOT:
//    - rewrite a reading's text or value (it has no API that returns a
//      corrected reading — that is deliberate);
//    - be handed to `FormatValidator` as a `DisplayFormat`;
//    - veto a reading on its own.
//
//  An earlier round of this project asserted an inferred grammar eagerly and
//  caused mass rejections: the instrument changed range, the learned grammar
//  did not, and every subsequent frame was thrown away. Two things follow from
//  that, and both are encoded below:
//
//    1. `plausibility(of:)` returns a MULTIPLIER in 0...1 that is blended
//       toward the neutral 1 by the prior's own `stability`. A weak prior is
//       almost neutral; only a prior that has actually repeated gets to push.
//       Even a total mismatch bottoms out at `separatorMismatchPlausibility`,
//       never 0 — a prior can depress confidence, never zero it.
//    2. The format MIGRATES. Establishing a grammar takes
//       `establishSupport` observations; REPLACING an established one takes
//       `migrateSupport` (strictly more). A temp gun going 80.8 → 120.5
//       changes its integer digit count legitimately, and the prior follows it
//       after sustained evidence instead of fighting it forever.
//
//  Deterministic and pure: no `Date()`, no randomness, no I/O. Every decision
//  is a function of the observation sequence alone.
//

import Foundation

/// The observable *shape* of one formatted reading — the part of a reading
/// that a format prior can be about, with the digit VALUES thrown away.
///
/// Digit counts follow `DisplayFormat`'s convention: `integerDigits` is the
/// number of digits BEFORE the separator (`0` for `.5`), `fractionDigits` the
/// number after (`0` when no separator is present).
struct ReadingGrammar: Hashable, Sendable {
    let integerDigits: Int
    let fractionDigits: Int
    let separatorPresent: Bool

    init(integerDigits: Int, fractionDigits: Int, separatorPresent: Bool) {
        self.integerDigits = max(0, integerDigits)
        self.fractionDigits = separatorPresent ? max(0, fractionDigits) : 0
        self.separatorPresent = separatorPresent
    }

    /// Derives the grammar of a reading as WRITTEN — `NumericReading.text` or
    /// `DisplayFormat.formatted(_:)` output. Trailing zeros count, because the
    /// whole point of the prior is the digit LAYOUT: `"1.000"` is `#.###`.
    ///
    /// Returns `nil` for anything that is not a plain signed decimal number;
    /// this type never guesses at junk. Grouping commas are not accepted here
    /// — `FormatValidator` resolves those upstream and hands down a
    /// canonicalized text.
    init?(text: String) {
        var integerDigits = 0
        var fractionDigits = 0
        var separatorPresent = false
        var sawDigit = false
        var index = text.startIndex

        if index < text.endIndex, text[index] == "-" || text[index] == "+" {
            index = text.index(after: index)
        }
        while index < text.endIndex {
            let character = text[index]
            if character.isASCII, ("0"..."9").contains(character) {
                sawDigit = true
                if separatorPresent { fractionDigits += 1 } else { integerDigits += 1 }
            } else if character == "." {
                // A second separator is not a grammar this type will guess at.
                if separatorPresent { return nil }
                separatorPresent = true
            } else {
                return nil
            }
            index = text.index(after: index)
        }
        guard sawDigit else { return nil }
        // "12." has no fraction to describe; that is a malformed reading, not a
        // grammar. `FormatValidator` already rejects it.
        if separatorPresent && fractionDigits == 0 { return nil }
        self.init(integerDigits: integerDigits,
                  fractionDigits: fractionDigits,
                  separatorPresent: separatorPresent)
    }

    /// Human-readable pattern, e.g. `##.#`, `###`, `.##`.
    var pattern: String {
        let lead = String(repeating: "#", count: integerDigits)
        guard separatorPresent else { return lead.isEmpty ? "#" : lead }
        return lead + "." + String(repeating: "#", count: fractionDigits)
    }

    /// Total digit count, ignoring sign and separator.
    var digitCount: Int { integerDigits + fractionDigits }
}

/// A display grammar inferred from history, with a measure of how consistently
/// it has repeated. See the file header: this is a PRIOR.
struct InferredFormat: Equatable, Sendable {
    /// The grammar the recent history agrees on.
    let grammar: ReadingGrammar
    /// Fraction of the current window that matches `grammar`, 0...1. Drives how
    /// hard the prior is allowed to push in `plausibility(of:)`.
    let stability: Float
    /// How many observations in the current window match `grammar`.
    let supportingObservations: Int

    var pattern: String { grammar.pattern }

    // MARK: - Plausibility weights
    //
    // POLICY weights, not measurements. Only the ORDERING is load-bearing:
    // an exact match must outrank a range change, which must outrank a
    // precision change, which must outrank a separator mismatch. The specific
    // values are a starting calibration and are documented as such.

    /// The candidate has exactly the grammar the prior expects. Neutral.
    static let agreementPlausibility: Float = 1

    /// Same separator layout and same fraction width, different integer digit
    /// count — i.e. `80.8` → `120.5`. This is what a RANGE CHANGE looks like on
    /// a real instrument, so it is only mildly depressed. Depressing it hard is
    /// exactly the mistake that caused the earlier mass-rejection round.
    static let rangeChangePlausibility: Float = 0.75

    /// Same separator presence, different fraction width — `80.8` → `80.85`.
    /// Real (auto-ranging instruments do this) but rarer than a range change.
    static let precisionChangePlausibility: Float = 0.5

    /// The candidate disagrees with the prior about whether a separator is
    /// there at all — `80.8` vs `808`. THIS is the §11A factor-of-ten failure
    /// mode, so it is the most depressed case. It is still not 0: the prior is
    /// evidence, and a display really can switch to an integer format.
    static let separatorMismatchPlausibility: Float = 0.25

    /// How plausible `candidate` is, given this prior — a 0...1 MULTIPLIER for
    /// a confidence, never a verdict.
    ///
    /// The raw weight is blended toward neutral by `stability`, so a
    /// barely-established prior barely moves anything:
    ///
    ///     effective = 1 − stability × (1 − weight)
    ///
    /// At `stability == 0` every candidate scores 1 (the prior abstains); at
    /// `stability == 1` the raw weight applies.
    func plausibility(of candidate: ReadingGrammar) -> Float {
        let weight: Float
        if candidate == grammar {
            weight = Self.agreementPlausibility
        } else if candidate.separatorPresent != grammar.separatorPresent {
            weight = Self.separatorMismatchPlausibility
        } else if candidate.fractionDigits == grammar.fractionDigits {
            weight = Self.rangeChangePlausibility
        } else {
            weight = Self.precisionChangePlausibility
        }
        let s = max(0, min(1, stability))
        return max(0, min(1, 1 - s * (1 - weight)))
    }

    /// Convenience overload for a reading as written. Unparseable text gets the
    /// neutral 1 — the prior has nothing to say about junk, and must not
    /// penalise a reading merely because this type could not read its shape.
    func plausibility(ofText text: String) -> Float {
        guard let candidate = ReadingGrammar(text: text) else { return 1 }
        return plausibility(of: candidate)
    }

    /// Exact grammar agreement. Used by `TemporalConsensus` as ONE of the
    /// corroborating signals for accepting a decimal event — never on its own.
    func agrees(with candidate: ReadingGrammar) -> Bool { candidate == grammar }

    /// Exact grammar agreement for a reading as written.
    func agrees(withText text: String) -> Bool {
        guard let candidate = ReadingGrammar(text: text) else { return false }
        return agrees(with: candidate)
    }
}

/// Accumulates reading grammars and emits an `InferredFormat` once one repeats
/// consistently. Pure value type — copy it and the copy has its own history.
///
/// One instance per device, mutated on the frame loop by whoever owns the
/// recognition state. Nothing here allocates per frame beyond the bounded
/// window, and nothing throws.
struct DisplayFormatInference: Equatable, Sendable {

    // MARK: - Policy constants (documented, not measured)

    /// Observations retained. Must be ≥ `migrateSupport`, and large enough that
    /// establishing and migrating are distinguishable.
    static let windowSize = 12

    /// Matching observations in the window required to FIRST establish a
    /// grammar. Greater than 1 by construction: a single high-confidence frame
    /// must never mint a prior, because a single frame is exactly what a
    /// dropped separator looks like.
    static let establishSupport = 4

    /// Matching observations required to REPLACE an established grammar.
    /// Strictly greater than `establishSupport`: migration is a bigger claim
    /// than first belief, and the cost of migrating wrongly (adopting `###` as
    /// the prior for a `##.#` display) is a systematic 10× error.
    static let migrateSupport = 7

    /// The established prior, or `nil` while history is too short or too mixed.
    private(set) var current: InferredFormat?

    private var window: [ReadingGrammar] = []

    init() {}

    /// Admits one observed grammar and returns the (possibly updated) prior.
    ///
    /// The return value is the same as `current`; it is returned for the
    /// convenience of frame-loop call sites that want the prior without a
    /// second property read.
    @discardableResult
    mutating func observe(grammar: ReadingGrammar) -> InferredFormat? {
        window.append(grammar)
        if window.count > Self.windowSize { window.removeFirst(window.count - Self.windowSize) }
        recompute()
        return current
    }

    /// Admits one reading as WRITTEN. Text whose shape cannot be read is not
    /// evidence and is silently ignored — it must not disturb the prior.
    @discardableResult
    mutating func observe(text: String) -> InferredFormat? {
        guard let grammar = ReadingGrammar(text: text) else { return current }
        return observe(grammar: grammar)
    }

    mutating func reset() {
        window.removeAll(keepingCapacity: true)
        current = nil
    }

    /// Support for `grammar` in the current window (exposed for tests and
    /// debug surfaces; the prior itself is the supported API).
    func support(for grammar: ReadingGrammar) -> Int {
        window.reduce(0) { $1 == grammar ? $0 + 1 : $0 }
    }

    var observationCount: Int { window.count }

    // MARK: - Private

    private mutating func recompute() {
        guard let (dominant, count) = dominantGrammar() else { return }
        let stability = Float(count) / Float(max(1, window.count))

        guard let established = current else {
            // First belief.
            if count >= Self.establishSupport {
                current = InferredFormat(grammar: dominant,
                                         stability: stability,
                                         supportingObservations: count)
            }
            return
        }

        if dominant == established.grammar {
            // Same grammar — just refresh how strongly it is held.
            current = InferredFormat(grammar: dominant,
                                     stability: stability,
                                     supportingObservations: count)
            return
        }

        // A DIFFERENT grammar leads the window. Migration needs sustained
        // evidence, strictly more than first establishment took. Until then the
        // established prior stands, but its stability is recomputed against its
        // own (now shrinking) support so it stops pushing as hard — a prior
        // losing its evidence should fade, not snap.
        if count >= Self.migrateSupport {
            current = InferredFormat(grammar: dominant,
                                     stability: stability,
                                     supportingObservations: count)
        } else {
            let held = support(for: established.grammar)
            current = InferredFormat(grammar: established.grammar,
                                     stability: Float(held) / Float(max(1, window.count)),
                                     supportingObservations: held)
        }
    }

    /// Most frequent grammar in the window. Ties are broken by the LATER last
    /// occurrence, which is deterministic and biases (weakly) toward the more
    /// recent shape; migration thresholds, not this tie-break, decide whether
    /// that shape actually takes over.
    private func dominantGrammar() -> (ReadingGrammar, Int)? {
        guard !window.isEmpty else { return nil }
        var counts: [ReadingGrammar: Int] = [:]
        var lastIndex: [ReadingGrammar: Int] = [:]
        for (index, grammar) in window.enumerated() {
            counts[grammar, default: 0] += 1
            lastIndex[grammar] = index
        }
        var best: (grammar: ReadingGrammar, count: Int, last: Int)?
        for (grammar, count) in counts {
            let last = lastIndex[grammar] ?? 0
            guard let currentBest = best else {
                best = (grammar, count, last)
                continue
            }
            if count > currentBest.count || (count == currentBest.count && last > currentBest.last) {
                best = (grammar, count, last)
            }
        }
        guard let best else { return nil }
        return (best.grammar, best.count)
    }
}
