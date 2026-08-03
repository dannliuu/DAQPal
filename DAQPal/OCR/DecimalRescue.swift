//
//  DecimalRescue.swift
//  DAQPal
//
//  Layer B of the §11A decimal-integrity work: a MODEL-INDEPENDENT recogniser
//  of the decimal separator itself.
//
//  WHY THIS EXISTS. A decimal point on an instrument display is a handful of
//  pixels. Every text recognizer — Vision, a CRNN, a commercial SDK — loses it
//  to the same three causes: a global threshold tuned for the (brighter, wider)
//  digit strokes erases a dimmer dot; resampling to the recognizer's input
//  height averages it into the background; minimum-text-height filtering drops
//  it as noise. A dot destroyed in preprocessing cannot be recovered by swapping
//  the model that runs afterwards. So this file does not read text at all: it
//  looks for the DOT, as a geometric object, on the canonical
//  (perspective-corrected) ROI, with its own binarization tuned for a small dim
//  blob rather than for strokes.
//
//  WHAT IT IS NOT. This is not a parser and not a decision-maker. It reports
//  what it saw and how sure it is; `FormatValidator` still owns grammar, and the
//  consensus layer above still owns whether a 10x change is believed. A LOW
//  confidence here is a legitimate, useful answer — the one thing this file must
//  never do is guess a position it cannot support, because a wrong position is
//  the same silent factor-of-ten error the whole effort exists to prevent.
//
//  DETERMINISM. Pure integer/floating arithmetic over pixels in raster order.
//  No ML, no randomness, no `Date()`. The same buffer always yields the same
//  `Finding`, including the rationale string.
//
//  DOCUMENTED ASSUMPTIONS / LIMITATIONS:
//  - Input is a 32BGRA buffer (the project-wide capture/canonical format).
//    Any other format is reported unreadable rather than mis-sampled.
//  - The buffer is the canonical, upright, perspective-corrected display region
//    (`PerspectiveNormalizer.canonicalImage`). Skew and rotation are NOT handled
//    here; the baseline test assumes an upright digit band.
//  - Polarity (dark-on-light LCD vs light-on-dark VFD/OLED) is detected from the
//    border, matching `SevenSegmentSampler`'s convention.
//  - MEASURED LIMITATION — TRUE SEGMENT FACES ARE NOT SEGMENTED. On a real
//    seven-segment display the segments do not touch, so connected-component
//    labeling finds SEGMENTS, not digits: `DecimalRescueTests`' component dump
//    for a clean DSEG7 render of "80.8" reports 21 components (17x76 verticals,
//    89x17 bars), and no component is a digit. This layer therefore does not
//    recover the separator on segment faces — across every DSEG7 preset measured
//    it reported either an absence or a presence with NO position, and never a
//    wrong position, which is the required failure mode but is still a recall
//    gap. It works as intended on raster/proportional faces (LCD/OLED/graphical),
//    where a glyph is one component. Closing the segment-face gap needs
//    component→digit-cell grouping by x-pitch (the job `DigitSegmenter` and
//    `SevenSegmentSampler` already do) feeding this analysis; that is deliberately
//    NOT attempted here rather than approximated.
//  - Digits are assumed to be one connected component each. Bloom can FUSE
//    neighbouring glyphs and a segment face with an open middle (DSEG7's `0`)
//    can SPLIT into halves; both break the count the position is derived from.
//    Three integrity signals detect that, and the response is to report the
//    separator's PRESENCE with no position rather than a position that counting
//    cannot support.
//

import CoreGraphics
import CoreVideo
import Foundation

/// Connected-component recogniser for the decimal separator on a canonical ROI.
struct DecimalRescue {

    /// What the analyzer saw. Scored INDEPENDENTLY of any digit confidence — its
    /// whole value is that it is a second, uncorrelated opinion.
    struct Finding: Equatable, Sendable {
        /// True when a separator-shaped component was found. Also true in the
        /// ambiguous case (something dot-like is there) — then `position` is nil
        /// and `confidence` is low, which is the honest report and is never
        /// usable as a position by a caller.
        var separatorPresent: Bool
        /// Digits BEFORE the separator, matching `DisplayFormat.decimalPosition`
        /// semantics. `nil` whenever the position is not supported by evidence.
        var position: Int?
        /// 0...1 confidence in THIS determination, independent of digit
        /// confidence. For `separatorPresent == false` it is confidence in the
        /// ABSENCE, so a suspicious gap in the digit band lowers it.
        var confidence: Float
        /// Why, for the debug overlay and the metrics log.
        var rationale: String

        /// Unreadable input — never an error, never a guess.
        static func unreadable(_ why: String) -> Finding {
            Finding(separatorPresent: false, position: nil, confidence: 0, rationale: why)
        }
    }

    // MARK: - Tunables
    //
    // These are POLICY/geometry constants, not measurements. They describe the
    // shape of a decimal point relative to the digit band it sits in, which is a
    // property of how numerals are drawn, not of any particular instrument. Each
    // one is named and justified; none was fitted to a dataset, and none should
    // be presented as a measured accuracy figure.

    /// Long-edge cap before the luminance grid is decimated by an integer
    /// stride. A decimal dot is roughly `bandHeight/8` across, so at 1024 px of
    /// canonical long edge it is still several pixels wide — decimating below
    /// this would start destroying exactly the evidence being looked for.
    private static let maxLongEdge = 1024.0
    /// Below this either dimension carries no usable digit band.
    private static let minEdge = 12

    /// **Adaptive threshold window.** Half the image height, forced odd.
    ///
    /// Rationale: the window must be much larger than a stroke (so a stroke does
    /// not raise its own local mean and threshold itself away) and comparable to
    /// the digit band (so the mean tracks illumination gradients across the
    /// display). Half the band height satisfies both: for a dot, the window is
    /// dominated by background plus a little digit ink, so the local mean stays
    /// near background and a dot that is dimmer than the strokes still falls
    /// below it. A global Otsu-style threshold is exactly what erases the dot,
    /// which is why this is local.
    private static let windowFraction = 0.5
    private static let minWindow = 9

    /// Foreground when `localMean - value > max(k * localMean, minDelta)`.
    /// The RELATIVE term is what survives a dimmed display (both terms scale);
    /// the ABSOLUTE floor is what keeps flat, noisy background from labelling
    /// itself foreground.
    private static let relativeDelta = 0.10
    private static let absoluteDelta = 8.0

    /// A component is digit-like at or above this fraction of the tallest
    /// component's height. Digits on one display line share a height; a dot, a
    /// minus sign, a decimal comma and sensor speckle do not come close.
    private static let digitHeightFraction = 0.55
    /// …and must be at least this wide relative to that height, which rejects a
    /// tall thin scratch or a column of noise.
    private static let digitMinAspect = 0.08

    /// **Merge guard.** Above this width/height ratio a "digit" component is
    /// really two or more digits fused together, and COUNTING components no
    /// longer counts digits — which is fatal, because the position is derived by
    /// counting.
    ///
    /// Measured digit aspects on the project's clean sans renders are 0.67-0.72
    /// and on DSEG7 0.62-0.64; a fused pair is roughly double that. No numeral is
    /// wider than it is tall, so 1.1 sits in open space between the two. This is
    /// a precautionary gate — the DSEG7 failure that motivated the guards was a
    /// SPLIT, not a fusion (see `unexplainedInkFraction`) — so it is not, on its
    /// own, evidence-backed against an observed fusion.
    private static let digitMaxAspect = 1.1

    /// **Merge guard, second signal.** Instrument displays are monospaced — every
    /// numeral occupies the same cell. So the widest digit component being much
    /// wider than the narrowest is itself evidence of a fused pair, and unlike
    /// the aspect test it does not depend on knowing the face's proportions.
    ///
    /// Three independent integrity signals are used (this, `digitMaxAspect`, and
    /// `unexplainedInkFraction`) because each has a blind spot the others cover.
    ///
    /// A proportional face (narrow `1`, wide `0`) can trip this and lose the
    /// position. That is the SAFE direction — a missing position costs recall, a
    /// wrong position is the factor-of-ten error.
    private static let digitWidthRatioMax = 1.6

    /// **Band-integrity guard.** Digits can also SPLIT, which is the mirror of
    /// fusing and just as fatal to counting.
    ///
    /// MEASURED, not assumed: `testTrueOpticalDegradationThresholds` caught a
    /// wrong position (1 instead of 2 for `"80.8"`) on DSEG7 + bloom that neither
    /// aspect nor width-ratio explained. The component dump showed why — the
    /// DSEG7 `0` has no middle segment, so bloom broke it into an upper half
    /// (100x81) and a lower half (103x82). Both fell under the digit-height
    /// threshold, the middle digit disappeared from the count entirely, and the
    /// dot ended up "between" the two `8`s.
    ///
    /// The rule that covers this without special-casing segment fonts: inside the
    /// digit span, every component must be either a digit or small enough to be a
    /// separator. Anything in between is ink the segmentation failed to explain,
    /// and a count taken over an unexplained band is not a count. Restricting it
    /// to INSIDE the span keeps a unit glyph or annunciator sitting past the last
    /// digit from tripping it.
    private static let unexplainedInkFraction = dotMaxHeightFraction

    /// Dot geometry, all relative to the digit band height.
    private static let dotMaxHeightFraction = 0.35
    private static let dotMaxWidthFraction = 0.40
    private static let dotMinAspect = 0.45
    private static let dotMaxAspect = 2.2
    /// A decimal point is SOLID. A rounded panel corner, a glyph fragment or a
    /// noise cluster is not.
    private static let dotMinFill = 0.50
    /// Area/bbox of a disc inscribed in its bounding box — the fill a rendered
    /// round dot converges to (measured at 0.78 on the project's synthetic
    /// renders, which matches pi/4 = 0.785).
    private static let roundDotFill = 0.785
    /// Plateau of dot heights, as a fraction of the digit band height, that score
    /// a full size match; the score ramps to 0 at `dotSizeFloor` and at
    /// `dotMaxHeightFraction`.
    ///
    /// MEASURED, not assumed: rendering `"80.8"` through the project's synthetic
    /// renderer at an 820x250 canonical crop puts the period at 34 px in a 116 px
    /// digit band — 0.29. An earlier single-point "ideal" of 0.13 (a typographic
    /// guess) scored that genuine decimal point 0.00 on size, which is exactly
    /// the kind of constant that quietly costs recall. The plateau spans the
    /// range real periods actually occupy across faces and rasterizations.
    private static let dotSizeFloor = 0.04
    private static let dotSizePlateau = 0.08...0.30

    /// **Baseline adjacency.** The dot's BOTTOM edge must sit within this
    /// fraction of the band height of the digit baseline. This is the single
    /// discriminator between a decimal point and a mid-height dot or a colon's
    /// lower lobe, so it is deliberately tight.
    private static let baselineTolerance = 0.18

    /// **Colon rejection.** A colon's lower lobe IS baseline-ish in many faces,
    /// so baseline adjacency alone cannot reject it. A second small round
    /// component vertically stacked above the candidate (same column, clearly
    /// higher) means the pair is a colon or a division sign, not a separator.
    private static let colonColumnTolerance = 0.30
    private static let colonMinRise = 0.25

    /// Two candidates whose scores are within this are "equally plausible" and
    /// the position is NOT reported.
    private static let ambiguityMargin = 0.15
    /// Confidence ceiling for an ambiguous finding.
    private static let ambiguousConfidenceCap: Float = 0.25
    /// Nothing here ever claims certainty.
    private static let confidenceCeiling: Float = 0.98

    /// A gap between consecutive digits wider than this multiple of the median
    /// gap is "a plausible place a separator used to be", which turns a
    /// confident absence into an unconfident one.
    private static let suspiciousGapRatio = 1.6
    private static let confidentAbsence: Float = 0.82
    private static let suspiciousAbsence: Float = 0.25
    /// Ceiling on any ABSENCE verdict. Detection only ever inspects the gaps
    /// between adjacent digits, so it structurally cannot observe a leading
    /// separator; no absence may be reported as more than "probably".
    private static let betweenDigitsOnlyCeiling: Float = 0.5

    /// Digit-count disagreement never invalidates a finding; it discounts it.
    private static let digitCountMismatchFactor: Float = 0.55

    // MARK: - Public API

    /// Looks for a decimal separator in `canonicalImage`.
    ///
    /// `digitCount`, when known from `DisplayFormat`, is used ONLY as a
    /// cross-check: a mismatch between the digit components found and the digits
    /// expected discounts the confidence and is named in the rationale. It never
    /// changes which component is chosen, and it never manufactures a position.
    ///
    /// Never throws. Unreadable input yields
    /// `Finding(separatorPresent: false, position: nil, confidence: 0, ...)`.
    static func analyze(canonicalImage: CVPixelBuffer,
                        digitCount: Int?) -> Finding {
        PipelineMetrics.shared.measure(.analysis) {
            evaluate(canonicalImage: canonicalImage, digitCount: digitCount)
        }
    }

    /// Human-readable dump of the labelled components, for the debug overlay and
    /// for calibrating the geometry constants above. Not used by `analyze`.
    static func componentReport(canonicalImage: CVPixelBuffer) -> String {
        guard let grid = loadLuminance(canonicalImage) else { return "unreadable" }
        let mask = binarize(grid)
        let components = label(mask: mask.foreground, width: grid.width, height: grid.height, grid: grid)
        var lines = ["size \(grid.width)x\(grid.height) darkOnLight=\(mask.darkOnLight) components=\(components.count)"]
        for c in components.sorted(by: { $0.minX < $1.minX }) {
            lines.append(String(format: "  x=%d..%d y=%d..%d w=%d h=%d area=%d fill=%.2f aspect=%.2f lum=%.0f",
                                c.minX, c.maxX, c.minY, c.maxY, c.width, c.height,
                                c.area, c.fill, c.aspect, c.meanLum))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Pipeline

    private static func evaluate(canonicalImage: CVPixelBuffer, digitCount: Int?) -> Finding {
        guard let grid = loadLuminance(canonicalImage) else {
            return .unreadable("unreadable: buffer is empty, too small, or not 32BGRA")
        }
        let mask = binarize(grid)
        let components = label(mask: mask.foreground, width: grid.width, height: grid.height, grid: grid)
        guard !components.isEmpty else {
            return .unreadable("no foreground components after adaptive threshold")
        }

        // --- Digit band -----------------------------------------------------
        let tallest = components.reduce(0) { max($0, $1.height) }
        guard tallest >= 4 else {
            return .unreadable("tallest component \(tallest)px — no digit band")
        }
        let digits = components
            .filter { Double($0.height) >= digitHeightFraction * Double(tallest)
                      && Double($0.width) >= digitMinAspect * Double($0.height) }
            .sorted { $0.centerX < $1.centerX }
        guard digits.count >= 2 else {
            // One digit (or none) cannot bracket a separator; a separator with
            // nothing on one side of it is not a decimal point.
            return Finding(separatorPresent: false, position: nil, confidence: 0,
                           rationale: "only \(digits.count) digit-like component(s) — no band to place a separator in")
        }

        let baseline = median(digits.map { Double($0.maxY) })
        let bandTop = median(digits.map { Double($0.minY) })
        let bandHeight = baseline - bandTop + 1
        guard bandHeight >= 6 else {
            return .unreadable(String(format: "digit band %.0fpx tall — too small to resolve a dot", bandHeight))
        }

        // Reference luminances for the contrast score.
        let digitLum = weightedMeanLuminance(digits)
        let backgroundLum = mask.backgroundMean
        let inkContrast = max(1.0, abs(digitLum - backgroundLum))

        // --- Dot candidates -------------------------------------------------
        let small = components.filter { c in
            !digits.contains(where: { $0.id == c.id })
        }
        var scored: [(component: Component, score: Double, position: Int, detail: String)] = []
        for candidate in small {
            guard let evaluation = scoreCandidate(candidate,
                                                  digits: digits,
                                                  others: small,
                                                  baseline: baseline,
                                                  bandHeight: bandHeight,
                                                  backgroundLum: backgroundLum,
                                                  inkContrast: inkContrast) else { continue }
            scored.append((candidate, evaluation.score, evaluation.position, evaluation.detail))
        }
        scored.sort {
            // Deterministic total order: score, then left-to-right.
            $0.score == $1.score ? $0.component.minX < $1.component.minX : $0.score > $1.score
        }

        // A fused digit pair makes the component count stop being a digit count.
        // Presence can still be reported; POSITION cannot, because it is derived
        // by counting the very components that are known to be wrong.
        let widths = digits.map { Double($0.width) }
        let widthRatio = (widths.max() ?? 1) / max(1, widths.min() ?? 1)
        let fusedByAspect = digits.filter { $0.aspect > digitMaxAspect }.count
        let spanStart = digits[0].minX
        let spanEnd = digits[digits.count - 1].maxX
        let unexplained = small.filter {
            Double($0.height) > unexplainedInkFraction * bandHeight
                && $0.centerX > Double(spanStart) && $0.centerX < Double(spanEnd)
        }.count
        let integrityNote: String?
        if fusedByAspect > 0 || widthRatio > digitWidthRatioMax || unexplained > 0 {
            integrityNote = String(format: "%d over-wide, %d unexplained, width ratio %.2f",
                                   fusedByAspect, unexplained, widthRatio)
        } else {
            integrityNote = nil
        }

        let countNote: String
        let countFactor: Float
        if let digitCount, digitCount != digits.count {
            countNote = "; digit count \(digits.count) != declared \(digitCount)"
            countFactor = digitCountMismatchFactor
        } else {
            countNote = ""
            countFactor = 1
        }

        // --- Verdict --------------------------------------------------------
        guard let best = scored.first else {
            return absence(digits: digits, bandHeight: bandHeight,
                           integrityNote: integrityNote,
                           countNote: countNote, countFactor: countFactor)
        }

        if scored.count >= 2, scored[0].score - scored[1].score < ambiguityMargin {
            // Two things equally dot-like. Something is there; WHERE is not
            // supported by the evidence, so no position is reported.
            let confidence = min(ambiguousConfidenceCap,
                                 Float(scored[0].score) * countFactor)
            return Finding(separatorPresent: true, position: nil,
                           confidence: max(0, min(confidenceCeiling, confidence)),
                           rationale: String(format: "%d equally plausible dot candidates (%.2f vs %.2f) — position not reported",
                                             scored.count, scored[0].score, scored[1].score) + countNote)
        }

        var confidence = Float(best.score) * countFactor
        if scored.count >= 2 {
            // A clear winner, but a runner-up existed: shade it down.
            confidence *= 0.85
        }

        if let integrityNote {
            return Finding(separatorPresent: true, position: nil,
                           confidence: max(0, min(ambiguousConfidenceCap, confidence)),
                           rationale: "separator found, but the digit band is not cleanly segmented (" + integrityNote
                               + ") — position not countable: " + best.detail + countNote)
        }

        confidence = max(0, min(confidenceCeiling, confidence))
        return Finding(separatorPresent: true,
                       position: best.position,
                       confidence: confidence,
                       rationale: "separator after \(best.position) digit(s): " + best.detail + countNote)
    }

    /// No dot-like component survived. Distinguishes "the band is clean, there
    /// really is no separator" from "there is a suspicious hole where one would
    /// have been" — the second is the case a dropped dot produces, and it must
    /// NOT be reported as a confident absence.
    private static func absence(digits: [Component],
                                bandHeight: Double,
                                integrityNote: String?,
                                countNote: String,
                                countFactor: Float) -> Finding {
        var gaps: [Double] = []
        for index in 1..<digits.count {
            gaps.append(Double(digits[index].minX - digits[index - 1].maxX))
        }
        let widest = gaps.max() ?? 0
        let typical = median(gaps)
        let suspicious = gaps.count >= 2
            && typical > 0
            && widest > suspiciousGapRatio * typical
            && widest > 0.10 * bandHeight

        // A CONFIDENT ABSENCE MUST BE EARNED, NEVER ASSUMED.
        //
        // This defaulted to `confidentAbsence` and only downgraded when the
        // gap test both applied AND fired. That inverted the whole point of
        // this layer: every case where the test is inapplicable reported a
        // confident "there is no decimal here", which is precisely the silent
        // coercion the module exists to prevent. Three reproduced cases:
        //
        //   ".808"  leading-zero-suppressed (universal on multimeters) — the
        //           dot precedes every digit, so no INTER-digit gap holds it
        //           and the test cannot see it.
        //   "9.9"   any two-digit reading — one gap, so `gaps.count >= 2` is
        //           false and the test never runs.
        //   segment faces — components are SEGMENTS, not digits, so the gap
        //           statistics are meaningless (and can even be negative).
        //
        // A negative or zero median gap is itself proof the band was not
        // segmented into digits, so it can never support a confident negative.
        let gapStatisticsUsable = gaps.count >= 2 && typical > 0
        let earnedConfidentAbsence = integrityNote == nil && gapStatisticsUsable && !suspicious
        var confidence = (earnedConfidentAbsence ? confidentAbsence : suspiciousAbsence) * countFactor

        // SCOPE LIMIT, and it is a real one: candidate detection requires the
        // dot to sit BETWEEN two adjacent digits with clear air either side, so
        // a LEADING separator (".808", ".5" — leading-zero suppression is
        // universal on multimeters) is never examined at all. This verdict can
        // therefore only ever mean "no separator BETWEEN digits"; it cannot
        // mean "no separator". Capping the absence keeps that distinction
        // honest, because a caller reading 0.82 would reasonably treat it as
        // "confirmed integer" and turn .808 into 808 — the exact coercion this
        // module exists to prevent.
        //
        // Raising this cap requires first extending detection to the region
        // left of the first digit; until then the format prior and temporal
        // consensus are what resolve the leading-separator case.
        confidence = min(confidence, betweenDigitsOnlyCeiling)

        var why: String
        if suspicious {
            why = String(format: "no dot component, but a %.0fpx gap vs %.0fpx typical — a separator may have been lost",
                          widest, typical)
        } else if !gapStatisticsUsable {
            why = "no dot-like component, and too few cleanly separated digits to tell whether one was lost — absence is NOT confident"
        } else {
            why = String(format: "no separator between digits; gaps uniform (%.0fpx typical) — a LEADING separator was not evaluated", typical)
        }
        if let integrityNote {
            // Fused or split glyphs can swallow a dot outright. An absence
            // measured on a demonstrably mis-segmented band is not a confident one.
            confidence = min(confidence, suspiciousAbsence)
            why += "; band not cleanly segmented (" + integrityNote + ") so it is unreliable"
        }
        return Finding(separatorPresent: false, position: nil,
                       confidence: max(0, min(confidenceCeiling, confidence)),
                       rationale: why + countNote)
    }

    // MARK: - Candidate scoring

    private struct Evaluation {
        var score: Double
        var position: Int
        var detail: String
    }

    /// Applies the hard gates (shape, baseline adjacency, betweenness, colon
    /// rejection) and, for survivors, scores the profile match. Returns nil for
    /// anything that fails a gate — a gate failure is a rejection, never a
    /// low score, because a colon scored at 0.3 would still win an otherwise
    /// empty field.
    private static func scoreCandidate(_ c: Component,
                                       digits: [Component],
                                       others: [Component],
                                       baseline: Double,
                                       bandHeight: Double,
                                       backgroundLum: Double,
                                       inkContrast: Double) -> Evaluation? {
        // 1. Size and shape: small, roughly square, solid.
        let heightFraction = Double(c.height) / bandHeight
        guard heightFraction <= dotMaxHeightFraction,
              Double(c.width) / bandHeight <= dotMaxWidthFraction,
              c.aspect >= dotMinAspect, c.aspect <= dotMaxAspect,
              c.fill >= dotMinFill,
              c.area >= minDotArea(bandHeight: bandHeight) else { return nil }

        // 2. Baseline adjacency — the dot's bottom sits at the digit baseline.
        let baselineOffset = abs(Double(c.maxY) - baseline) / bandHeight
        guard baselineOffset <= baselineTolerance else { return nil }

        // 3. Horizontally BETWEEN two digits, with clear air on both sides.
        guard let leftIndex = digits.lastIndex(where: { $0.maxX < c.minX }),
              let rightIndex = digits.firstIndex(where: { $0.minX > c.maxX }),
              rightIndex == leftIndex + 1 else { return nil }

        // 4. Not the lower lobe of a colon (or of a division sign).
        for other in others where other.id != c.id {
            let sameColumn = abs(other.centerX - c.centerX) <= colonColumnTolerance * bandHeight
            let rise = (c.centerY - other.centerY) / bandHeight
            let similarSize = Double(other.height) <= dotMaxHeightFraction * bandHeight
                && other.fill >= dotMinFill
            if sameColumn && similarSize && rise >= colonMinRise { return nil }
        }

        // --- Scores (each 0...1) --------------------------------------------
        let baselineScore = 1 - min(1, baselineOffset / baselineTolerance)
        let aspectScore = 1 - min(1, abs(c.aspect - 1) / 1.0)
        // A round dot fills pi/4 of its bounding box. Deviating in EITHER
        // direction is evidence against: much less is a hollow fragment or a
        // panel corner, much more is a filled rectangle (a truncated stroke).
        let fillScore = 1 - min(1, abs(c.fill - roundDotFill) / (roundDotFill - dotMinFill))
        let sizeScore = trapezoid(heightFraction,
                                  rampStart: dotSizeFloor,
                                  plateau: dotSizePlateau,
                                  rampEnd: dotMaxHeightFraction)
        let leftGap = Double(c.minX - digits[leftIndex].maxX)
        let rightGap = Double(digits[rightIndex].minX - c.maxX)
        let separationScore = min(1, min(leftGap, rightGap) / (0.06 * bandHeight))
        let contrastScore = min(1, abs(c.meanLum - backgroundLum) / inkContrast)

        let score = 0.24 * baselineScore
            + 0.16 * aspectScore
            + 0.12 * fillScore
            + 0.16 * sizeScore
            + 0.16 * separationScore
            + 0.16 * contrastScore

        let detail = String(format: "base %.2f, aspect %.2f, fill %.2f, size %.2f, sep %.2f, contrast %.2f",
                            baselineScore, aspectScore, fillScore, sizeScore, separationScore, contrastScore)
        return Evaluation(score: score, position: leftIndex + 1, detail: detail)
    }

    /// 0 below `rampStart`, rising to 1 across `plateau`, falling back to 0 at
    /// `rampEnd`. A plateau rather than a single ideal point: within the plateau
    /// there is no evidence that one size is more dot-like than another, and
    /// pretending otherwise is a fitted constant masquerading as a measurement.
    private static func trapezoid(_ value: Double,
                                  rampStart: Double,
                                  plateau: ClosedRange<Double>,
                                  rampEnd: Double) -> Double {
        if value >= plateau.lowerBound && value <= plateau.upperBound { return 1 }
        if value < plateau.lowerBound {
            guard plateau.lowerBound > rampStart else { return value >= rampStart ? 1 : 0 }
            return max(0, (value - rampStart) / (plateau.lowerBound - rampStart))
        }
        guard rampEnd > plateau.upperBound else { return value <= rampEnd ? 1 : 0 }
        return max(0, (rampEnd - value) / (rampEnd - plateau.upperBound))
    }

    /// Minimum dot area, scaled so the rule means the same thing at any
    /// resolution: below this a "dot" is indistinguishable from speckle.
    private static func minDotArea(bandHeight: Double) -> Int {
        max(2, Int((0.0006 * bandHeight * bandHeight).rounded()))
    }

    // MARK: - Luminance grid

    private struct Grid {
        var lum: [Double]
        var width: Int
        var height: Int
    }

    private static func loadLuminance(_ buffer: CVPixelBuffer) -> Grid? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth >= minEdge, sourceHeight >= minEdge else { return nil }

        let longEdge = Double(max(sourceWidth, sourceHeight))
        let stride = max(1, Int((longEdge / maxLongEdge).rounded(.up)))
        let width = sourceWidth / stride
        let height = sourceHeight / stride
        guard width >= minEdge, height >= minEdge else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var lum = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = ptr + (y * stride) * bytesPerRow
            let out = y * width
            for x in 0..<width {
                // 32BGRA: memory bytes are B, G, R, A.
                let p = row + (x * stride) * 4
                lum[out + x] = 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
            }
        }
        // A 3x3 box smooth before thresholding. Sensor noise is the one thing
        // that can mint dot-sized components out of nothing; a dot survives a
        // 3x3 average (it is several pixels across at the resolutions this runs
        // at), isolated speckle does not.
        return Grid(lum: boxSmooth(lum, width: width, height: height), width: width, height: height)
    }

    private static func boxSmooth(_ source: [Double], width: Int, height: Int) -> [Double] {
        var horizontal = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let a = source[row + max(0, x - 1)]
                let b = source[row + x]
                let c = source[row + min(width - 1, x + 1)]
                horizontal[row + x] = (a + b + c) / 3
            }
        }
        var output = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            let up = max(0, y - 1) * width
            let mid = y * width
            let down = min(height - 1, y + 1) * width
            for x in 0..<width {
                output[mid + x] = (horizontal[up + x] + horizontal[mid + x] + horizontal[down + x]) / 3
            }
        }
        return output
    }

    // MARK: - Adaptive binarization

    private struct Mask {
        var foreground: [Bool]
        var darkOnLight: Bool
        var backgroundMean: Double
    }

    /// Local-mean (Bradley-style) adaptive threshold over an integral image, so
    /// the window size costs nothing. See `windowFraction` for the window
    /// rationale. Polarity is decided from the border, which is background by
    /// construction on a canonical display crop.
    private static func binarize(_ grid: Grid) -> Mask {
        let width = grid.width, height = grid.height
        let count = width * height

        var minLum = Double.greatestFiniteMagnitude
        var maxLum = -Double.greatestFiniteMagnitude
        for value in grid.lum {
            if value < minLum { minLum = value }
            if value > maxLum { maxLum = value }
        }
        let mid = (minLum + maxLum) / 2

        var borderSum = 0.0
        var borderCount = 0
        for x in 0..<width {
            borderSum += grid.lum[x] + grid.lum[(height - 1) * width + x]
            borderCount += 2
        }
        if height > 2 {
            for y in 1..<(height - 1) {
                borderSum += grid.lum[y * width] + grid.lum[y * width + width - 1]
                borderCount += 2
            }
        }
        let borderMean = borderCount > 0 ? borderSum / Double(borderCount) : mid
        let darkOnLight = borderMean > mid

        // Integral image (width+1) x (height+1).
        var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            let src = y * width
            let dst = (y + 1) * (width + 1)
            let prev = y * (width + 1)
            for x in 0..<width {
                rowSum += grid.lum[src + x]
                integral[dst + x + 1] = integral[prev + x + 1] + rowSum
            }
        }

        var window = max(minWindow, Int(Double(height) * windowFraction))
        if window % 2 == 0 { window += 1 }
        let radius = window / 2

        var foreground = [Bool](repeating: false, count: count)
        var backgroundSum = 0.0
        var backgroundCount = 0
        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let sum = integral[(y1 + 1) * (width + 1) + (x1 + 1)]
                    - integral[y0 * (width + 1) + (x1 + 1)]
                    - integral[(y1 + 1) * (width + 1) + x0]
                    + integral[y0 * (width + 1) + x0]
                let localMean = sum / area
                let value = grid.lum[y * width + x]
                let delta = darkOnLight ? (localMean - value) : (value - localMean)
                let lit = delta > max(relativeDelta * localMean, absoluteDelta)
                foreground[y * width + x] = lit
                if !lit {
                    backgroundSum += value
                    backgroundCount += 1
                }
            }
        }
        let backgroundMean = backgroundCount > 0 ? backgroundSum / Double(backgroundCount) : mid
        return Mask(foreground: foreground, darkOnLight: darkOnLight, backgroundMean: backgroundMean)
    }

    // MARK: - Connected components

    private struct Component {
        var id = 0
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
        var area = 0
        var sumLum = 0.0

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var centerX: Double { Double(minX + maxX) / 2 }
        var centerY: Double { Double(minY + maxY) / 2 }
        var fill: Double { Double(area) / Double(max(1, width * height)) }
        var aspect: Double { Double(width) / Double(max(1, height)) }
        var meanLum: Double { area > 0 ? sumLum / Double(area) : 0 }
    }

    /// Deterministic 8-connected flood-fill labeler over an explicit stack — no
    /// recursion (a full-frame component would blow the stack) and no third-party
    /// dependency. Raster-order seeding makes the component IDs reproducible.
    ///
    /// Components smaller than `minComponentArea` are discarded here: at the
    /// resolutions this runs at, a 1-2 pixel blob cannot be a decimal point and
    /// keeping them only slows the later passes.
    private static let minComponentArea = 2

    private static func label(mask: [Bool], width: Int, height: Int, grid: Grid) -> [Component] {
        var visited = [Bool](repeating: false, count: width * height)
        var components: [Component] = []
        var stack: [Int] = []
        stack.reserveCapacity(1024)

        for seed in 0..<(width * height) where mask[seed] && !visited[seed] {
            visited[seed] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(seed)
            var component = Component(id: components.count)
            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                component.area += 1
                component.sumLum += grid.lum[index]
                if x < component.minX { component.minX = x }
                if x > component.maxX { component.maxX = x }
                if y < component.minY { component.minY = y }
                if y > component.maxY { component.maxY = y }
                let x0 = max(0, x - 1), x1 = min(width - 1, x + 1)
                let y0 = max(0, y - 1), y1 = min(height - 1, y + 1)
                for ny in y0...y1 {
                    let row = ny * width
                    for nx in x0...x1 {
                        let neighbour = row + nx
                        if mask[neighbour] && !visited[neighbour] {
                            visited[neighbour] = true
                            stack.append(neighbour)
                        }
                    }
                }
            }
            if component.area >= minComponentArea {
                component.id = components.count
                components.append(component)
            }
        }
        return components
    }

    // MARK: - Small helpers

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func weightedMeanLuminance(_ components: [Component]) -> Double {
        var sum = 0.0
        var area = 0
        for component in components {
            sum += component.sumLum
            area += component.area
        }
        return area > 0 ? sum / Double(area) : 0
    }
}
