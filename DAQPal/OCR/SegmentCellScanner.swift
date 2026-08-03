//
//  SegmentCellScanner.swift
//  DAQPal
//
//  PROTOTYPE — column-scan digit-cell segmentation for TRUE SEGMENT FACES.
//  See OCR_SEGMENT_RESEARCH.md §1 and §7.1-7.3 for the research this implements.
//
//  WHY THIS EXISTS. Two existing components each fail on a seven-segment face,
//  for opposite reasons:
//
//    `DigitSegmenter` cuts `format.digitCount` equal-width cells. It cannot run
//        before the format is known, so it is useless for INFERRING a format and
//        useless when the declared digit count is wrong.
//    `DecimalRescue` labels connected components and calls a tall one a digit.
//        On a segment face the segments do not touch: its own component dump for
//        a clean DSEG7 "80.8" reports 21 components (17x76 verticals, 89x17
//        bars) and not one of them is a digit. Counting components stops being
//        counting digits, so the separator's POSITION cannot be derived.
//
//  This file segments by COLUMN SCANNING instead, which is what SSOCR does and
//  which is indifferent to connectivity. The property that makes it work is
//  specific to seven-segment geometry: every digit has at least one FULL-WIDTH
//  horizontal segment lit — `a` (top), `g` (middle) or `d` (bottom) — so every
//  column inside a digit's span contains ink no matter which segments are off.
//  The one exception, `1`, is a bare vertical stroke whose columns are inked
//  anyway. A `0` with no middle segment splits into two components but never
//  into two column runs, which is precisely the failure being fixed.
//
//  WHAT IT DOES NOT DO. It does not recognise digits — `SevenSegmentSampler`
//  already does that, and the cells this produces are shaped to feed it. It does
//  not decide anything: like `DecimalRescue` it reports what it saw and how well
//  segmented the band was, and refuses to report a position it cannot support.
//
//  DETERMINISM. Pure integer arithmetic over pixels in raster order; no ML, no
//  randomness, no `Date()`. Same buffer ⇒ same rows, cells and rationale.
//
//  DOCUMENTED ASSUMPTIONS / LIMITATIONS:
//  - Input is a 32BGRA buffer (project-wide capture format), ideally the
//    canonical perspective-corrected crop. Skew is NOT corrected here; a rotated
//    band smears the column projection and will under-segment.
//  - Binarization is LOCAL and lives in `InkGrid` below, deliberately not shared
//    with `LuminanceGrid` — see the measurement in that type's doc comment for
//    why a global threshold erases the separator outright.
//  - Digits are assumed upright and non-overlapping in x. Heavy bloom can fuse
//    adjacent digits into one column run; that is DETECTED (`.fused`) and
//    suppresses the separator position rather than shifting it.
//

import CoreGraphics
import CoreVideo
import Foundation

/// Column-scan segmentation of a display crop into rows of digit cells.
struct SegmentCellScanner {

    /// One segmented element of a display row, left to right.
    struct Cell: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// A digit-height run — feed to `SevenSegmentSampler.readDigit`.
            case digit
            /// A small, baseline-adjacent run: the decimal separator.
            case separator
            /// A short, wide, vertically-centred run: a minus sign.
            case minus
        }
        var kind: Kind
        /// Region in the BUFFER's normalized space (0...1, top-left origin), so
        /// it can be handed straight to `SevenSegmentSampler.readDigit(in:cell:)`.
        var region: NormalizedROI
    }

    /// How well the band segmented. A position is only reported when `.clean`.
    enum Integrity: Equatable, Sendable {
        case clean
        /// `count` runs are wide enough to be two fused digits. Counting runs is
        /// no longer counting digits, so no position may be derived.
        case fused(count: Int)
        /// `count` digit runs sit closer together than the display's own pitch,
        /// so at least one glyph has SPLIT into fragments. The mirror of
        /// `fused`, and just as fatal to counting.
        case fragmented(count: Int)
        /// Fewer than two digit-height runs — nothing to place a separator in.
        case tooFewDigits
    }

    /// One horizontal band of the display (the target IR thermometer shows two:
    /// the main reading and the smaller `MAX`).
    struct Row: Equatable, Sendable {
        /// The band's extent in buffer-normalized space.
        var band: NormalizedROI
        /// Cells left to right, including the separator and any minus sign.
        var cells: [Cell]
        /// Digit cells only.
        var digitCount: Int
        /// Digits BEFORE the separator — same semantics as
        /// `DisplayFormat.decimalPosition` and `DecimalRescue.Finding.position`.
        /// `nil` when no separator was found OR when integrity is not `.clean`.
        var separatorPosition: Int?
        var integrity: Integrity
        /// Why, for the debug overlay and the metrics log.
        var rationale: String
    }

    // MARK: - Tunables
    //
    // Geometry policy relative to the band's own digit height, not measurements
    // of any instrument. Every one is a ratio so it means the same thing at any
    // resolution and any display size.

    /// Long-edge cap before decimation. Cell BOUNDARIES need less resolution
    /// than recognition does, but the separator is the smallest object on the
    /// panel, so this stays generous. Matches `DecimalRescue.maxLongEdge`.
    private static let maxLongEdge = 1024.0
    private static let minEdge = 16

    /// Row projection gate, as a fraction of the profile's own non-zero median.
    /// Scaling off the median rather than the image width is what makes this
    /// survive a hand-placed window that includes bezel — see the measurement
    /// recorded in `NumberBandSplitter.profileGateFraction`.
    private static let rowGateFraction = 0.60
    /// Bands thinner than this fraction of the crop are glare lines or seams.
    private static let minBandHeightFraction = 0.06

    /// **Column noise floor**, as a fraction of the BAND height.
    ///
    /// Deliberately tiny: the whole point of column scanning is that ANY ink in
    /// a column continues the current digit, so this is a sensor-speckle floor,
    /// not a content gate. It must stay well below the ink a DECIMAL POINT puts
    /// in its own columns — a dot roughly `bandHeight/6` across contributes only
    /// that many pixels per column, so a gate scaled for digit strokes erases
    /// the separator entirely and the position silently disappears.
    private static let columnNoiseFloorFraction = 0.012
    private static let columnNoiseFloorMinimum = 2

    /// **Background margin added around each digit cell.**
    ///
    /// A column run is a TIGHT box around the glyph, and a tight box breaks the
    /// consumer. `SevenSegmentSampler` decides display polarity by comparing the
    /// cell's BORDER pixels against its midpoint luminance, assuming the border
    /// is background — so a cell whose edges are the glyph's own top bar and
    /// side verticals inverts the polarity and decodes the complement of the
    /// pattern. Measured: DSEG7 "80.8" reconstructed as "88.8" and "99.9" as
    /// "???" from tight cells, with segmentation itself perfectly correct.
    /// A margin restores the assumption the sampler documents.
    private static let digitCellPadFraction = 0.10

    /// A run at or above this fraction of the tallest run in the band is a
    /// digit. Digits on one display line share a height; a separator, a minus
    /// and speckle do not come close.
    private static let digitHeightFraction = 0.55
    /// A run at or below this is small enough to be a separator or a minus.
    ///
    /// The gap between this and `digitHeightFraction` is a deliberate DEAD ZONE:
    /// a run that is neither clearly a digit nor clearly a mark is unexplained
    /// ink, and is reported rather than forced into a category.
    private static let smallHeightFraction = 0.45

    /// Separator shape, relative to the band's digit height.
    private static let separatorMaxWidthFraction = 0.40
    /// **Minimum separator size**, as a fraction of the tallest run.
    ///
    /// MEASURED, not assumed: without a floor, the `moderate` preset on DSEG7
    /// "99.9" scored a one-pixel speck (h=0.04, w=0.01) as the separator and
    /// reported position 0 instead of 2 — a WRONG position, the one failure mode
    /// this component may never have. A decimal point is a substantial mark:
    /// `DecimalRescue` measured a real period at 0.29 of the digit band. Anything
    /// an order of magnitude below that is sensor speckle or an antialiasing
    /// sliver, never a separator.
    private static let separatorMinHeightFraction = 0.08
    private static let separatorMinWidthFraction = 0.04
    /// Aspect (w/h) bounds for a separator. A decimal point is roughly square;
    /// after decimation it skews narrow, but not to a hairline. The sliver
    /// population rejected above ran 0.05-0.25, real dots 0.4+.
    private static let separatorMinAspect = 0.35
    private static let separatorMaxAspect = 2.5
    /// The separator's BOTTOM edge must sit within this fraction of the digit
    /// baseline. This is the discriminator between a decimal point and a colon
    /// lobe or a mid-height annunciator dot, so it is deliberately tight.
    private static let baselineTolerance = 0.20

    /// Minus shape: wide, short, vertically centred in the band.
    private static let minusMinWidthFraction = 0.30
    private static let minusCenterTolerance = 0.25

    /// A digit run wider than this multiple of the MEDIAN digit width is two
    /// fused glyphs. Instrument faces are monospaced, so the median is a
    /// reliable reference and a fused pair is roughly double it. Sitting at 1.6
    /// leaves room for the legitimate width spread between `1` and `8` while
    /// staying well under a genuine fusion.
    private static let fusedWidthRatio = 1.6

    /// A gap between digit-run centres below this multiple of the median pitch
    /// means a glyph fragmented. Sits well below 1.0 so the natural pitch
    /// variation between a `1` cell and an `8` cell never trips it, and well
    /// above the ~0.3 a genuine fragment pair produces.
    private static let fragmentPitchRatio = 0.6

    /// **Trailing-separator split.** On the target instrument the decimal is a
    /// dedicated segment sitting at the bottom-right of a digit cell, close
    /// enough that bloom can bridge it into that digit's column run — the exact
    /// case SSOCR documents as its weak point ("particularly when decimal points
    /// sit close to digits").
    ///
    /// It is recoverable without connectivity: in the trailing columns of such a
    /// run, ink exists ONLY near the baseline, whereas a real digit puts ink
    /// across the full band height in those columns. Both constants describe
    /// that test — inspect the last `tailFraction` of a suspiciously wide run,
    /// and call it a separator when its ink hugs the baseline.
    private static let tailFraction = 0.35
    private static let tailMaxHeightFraction = 0.45

    // MARK: - Public API

    /// Segments `buffer` into display rows of cells. Never throws; unreadable
    /// input yields an empty array.
    static func scan(_ buffer: CVPixelBuffer) -> [Row] {
        PipelineMetrics.shared.measure(.analysis) {
            guard let grid = InkGrid(buffer: buffer) else { return [] }
            return scan(grid)
        }
    }

    /// Human-readable dump for the debug overlay and for calibrating the
    /// constants above. Not used by `scan`.
    static func report(_ buffer: CVPixelBuffer) -> String {
        let rows = scan(buffer)
        guard !rows.isEmpty else { return "no rows" }
        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            lines.append(String(format: "row %d y=%.3f..%.3f digits=%d sep=%@ integrity=%@",
                                index, row.band.y, row.band.y + row.band.height,
                                row.digitCount,
                                row.separatorPosition.map(String.init) ?? "nil",
                                String(describing: row.integrity)))
            for cell in row.cells {
                lines.append(String(format: "    %@ x=%.3f..%.3f",
                                    String(describing: cell.kind),
                                    cell.region.x, cell.region.x + cell.region.width))
            }
            lines.append("    " + row.rationale)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Row split (horizontal projection)

    private static func scan(_ grid: InkGrid) -> [Row] {
        let ink = grid.ink
        var rowInk = [Int](repeating: 0, count: grid.height)
        for y in 0..<grid.height {
            let base = y * grid.width
            var count = 0
            for x in 0..<grid.width where ink[base + x] { count += 1 }
            rowInk[y] = count
        }

        let bands = runs(in: rowInk,
                         gate: adaptiveGate(rowInk, fraction: rowGateFraction),
                         minLength: max(2, Int(Double(grid.height) * minBandHeightFraction)))

        return bands.compactMap { band in
            scanBand(band, ink: ink, grid: grid)
        }
    }

    // MARK: - Column scan within one band

    /// A contiguous span of inked columns, with the vertical extent of its ink.
    private struct Run {
        var x0: Int
        var x1: Int   // inclusive
        var y0: Int
        var y1: Int   // inclusive
        var width: Int { x1 - x0 + 1 }
        var height: Int { y1 - y0 + 1 }
        var aspect: Double { Double(width) / Double(max(1, height)) }
    }

    private static func scanBand(_ band: Range<Int>,
                                 ink: [Bool],
                                 grid: InkGrid) -> Row? {
        let bandHeight = band.count
        let bandROI = grid.normalized(x0: 0, x1: grid.width,
                                      y0: band.lowerBound, y1: band.upperBound, pad: 0)

        // --- Column runs ----------------------------------------------------
        //
        // THE CORE OF THIS FILE. A column with any ink continues the current
        // run; a column with none ends it. Interior gaps (a `0`'s missing middle
        // segment, the corner gaps DSEG7 draws between segments) are invisible
        // to this test, because the question asked of each column is "is there
        // ink ANYWHERE in it", not "is this pixel connected to that one".
        let noiseFloor = max(columnNoiseFloorMinimum,
                             Int(Double(bandHeight) * columnNoiseFloorFraction))
        var columnInk = [Int](repeating: 0, count: grid.width)
        for y in band {
            let base = y * grid.width
            for x in 0..<grid.width where ink[base + x] { columnInk[x] += 1 }
        }

        var runs: [Run] = []
        var start: Int?
        for x in 0...grid.width {
            let inked = x < grid.width && columnInk[x] >= noiseFloor
            if inked {
                if start == nil { start = x }
            } else if let s = start {
                if let run = makeRun(x0: s, x1: x - 1, band: band, ink: ink, grid: grid) {
                    runs.append(run)
                }
                start = nil
            }
        }
        guard !runs.isEmpty else { return nil }

        let tallest = runs.reduce(0) { max($0, $1.height) }
        guard tallest >= 4 else { return nil }

        // --- Recover separators fused into a digit's column run --------------
        runs = runs.flatMap { splitFusedSeparator($0, tallest: tallest, ink: ink, grid: grid) }

        // --- Classify -------------------------------------------------------
        var digitRuns: [Run] = []
        var cells: [Cell] = []
        var separatorIndex: Int?      // digit count to the LEFT of the separator
        var separatorCount = 0
        // Runs that matched no category, with the measurements that rejected
        // them. Silently dropping these is how a lost separator becomes an
        // invisible failure, so they are always named in the rationale.
        var rejected: [String] = []
        /// Accepted separator candidates, so a multi-candidate suppression can
        /// be told apart from a no-candidate one in the log.
        var accepted: [String] = []

        // Baseline needs the digit runs, so classify in two passes.
        //
        // A run touching the crop's left or right EDGE is discarded rather than
        // counted. On an inverted (light-on-dark) panel the frame border itself
        // binarizes as ink and forms a full-height run — measured: the
        // `moderate-inverted` preset yielded 6 digit runs for "12.345" and 5 for
        // "100.0", which shifted the separator one place right and produced a
        // WRONG position in both. A digit is never flush against the edge of a
        // display crop; a bezel or border artifact always is. `NumberBandSplitter`
        // guards the same failure with its structural-column test.
        for run in runs where Double(run.height) >= digitHeightFraction * Double(tallest) {
            guard run.x0 > 0, run.x1 < grid.width - 1 else { continue }
            digitRuns.append(run)
        }
        guard !digitRuns.isEmpty else {
            return Row(band: bandROI, cells: [], digitCount: 0, separatorPosition: nil,
                       integrity: .tooFewDigits,
                       rationale: "no digit-height column runs in band (tallest \(tallest)px)")
        }
        let baseline = median(digitRuns.map { Double($0.y1) })
        let digitHeight = median(digitRuns.map { Double($0.height) })

        for run in runs {
            if Double(run.height) >= digitHeightFraction * Double(tallest) {
                // Same edge rule as the digit-run pass above, so `cells` and
                // `digitCount` can never disagree about what a digit is.
                guard run.x0 > 0, run.x1 < grid.width - 1 else { continue }
                // Digit cells take the BAND's full height, not the run's own ink
                // extent, so `SevenSegmentSampler`'s aspect test for `1` stays
                // meaningful (a bare vertical stroke is narrow relative to the
                // band; it is not narrow relative to its own tight bbox).
                cells.append(Cell(kind: .digit,
                                  region: grid.normalized(x0: run.x0, x1: run.x1 + 1,
                                                          y0: band.lowerBound, y1: band.upperBound,
                                                          pad: digitCellPadFraction)))
                continue
            }

            let heightFraction = Double(run.height) / Double(tallest)
            let widthFraction = Double(run.width) / digitHeight
            let baselineOffset = abs(Double(run.y1) - baseline) / digitHeight
            let measured = String(format: "x%d-%d h=%.2f w=%.2f aspect=%.2f base=%.2f",
                                  run.x0, run.x1, heightFraction, widthFraction,
                                  run.aspect, baselineOffset)

            guard heightFraction <= smallHeightFraction else {
                rejected.append("too tall for a mark, too short for a digit (" + measured + ")")
                continue
            }

            let region = grid.normalized(x0: run.x0, x1: run.x1 + 1,
                                         y0: run.y0, y1: run.y1 + 1, pad: 0)

            // Minus: wide, short, vertically centred in the band.
            let verticalCenter = (Double(run.y0) + Double(run.y1)) / 2
            let centeredness = abs(verticalCenter - (Double(band.lowerBound) + Double(bandHeight) / 2))
                / Double(bandHeight)
            if widthFraction >= minusMinWidthFraction, centeredness <= minusCenterTolerance {
                cells.append(Cell(kind: .minus, region: region))
                continue
            }

            // Separator: small, sitting ON the baseline.
            guard heightFraction >= separatorMinHeightFraction,
                  widthFraction >= separatorMinWidthFraction,
                  widthFraction <= separatorMaxWidthFraction,
                  run.aspect >= separatorMinAspect,
                  run.aspect <= separatorMaxAspect,
                  baselineOffset <= baselineTolerance else {
                rejected.append("not separator-shaped (" + measured + ")")
                continue
            }

            // A DECIMAL SEPARATOR MUST HAVE A DIGIT AFTER IT. Without this the
            // safety property fails outright: on the `hard` preset a speck past
            // the last digit of "100.0" was scored as the separator and reported
            // position 4 instead of 3 — a wrong position, which is exactly the
            // silent factor-of-ten error this component exists to avoid. A
            // trailing mark with nothing to its right is a period, a smudge or
            // an annunciator; it is never a decimal point.
            let digitsBefore = digitRuns.filter { $0.x1 < run.x0 }.count
            guard digitsBefore < digitRuns.count else {
                rejected.append("no digit to its right, so not a decimal separator (" + measured + ")")
                continue
            }

            separatorCount += 1
            // POSITION FROM COLUMN ORDER, not from counting components — this is
            // the whole reason column scanning was adopted. Everything to the
            // left of the dot that is digit-height is a digit, whatever its
            // connectivity looks like.
            if separatorIndex == nil { separatorIndex = digitsBefore }
            accepted.append("separator@\(digitsBefore) (" + measured + ")")
            cells.append(Cell(kind: .separator, region: region))
        }

        // --- Integrity ------------------------------------------------------
        let widths = digitRuns.map { Double($0.width) }
        let medianWidth = median(widths)
        let fused = medianWidth > 0
            ? digitRuns.filter { Double($0.width) > fusedWidthRatio * medianWidth }.count
            : 0

        // PITCH REGULARITY. Instrument faces are monospaced, so digit centres sit
        // at a constant pitch. A run pair much closer than that pitch means one
        // glyph broke into fragments and the run count has stopped being a digit
        // count — the mirror of `fused`.
        //
        // MEASURED, not assumed: the `moderate-inverted` preset split a glyph in
        // DSEG7 "12.345" into 6 runs and in "100.0" into 5, and the separator was
        // then reported one place too far right in both — WRONG positions, the
        // one outcome this component may never produce. Width alone cannot catch
        // this because a legitimate `1` is genuinely narrow (17px against a
        // 105px median); pitch can, because a `1` still occupies a full cell.
        let centres = digitRuns.map { Double($0.x0 + $0.x1) / 2 }
        var pitchGaps: [Double] = []
        for index in 1..<max(1, centres.count) { pitchGaps.append(centres[index] - centres[index - 1]) }
        let medianPitch = median(pitchGaps)
        // Needs at least two gaps for a median to carry information.
        let fragmented = pitchGaps.count >= 2 && medianPitch > 0
            ? pitchGaps.filter { $0 < fragmentPitchRatio * medianPitch }.count
            : 0

        let integrity: Integrity
        var rationale: String
        if digitRuns.count < 2 {
            integrity = .tooFewDigits
            rationale = "only \(digitRuns.count) digit run(s) — no band to place a separator in"
        } else if fragmented > 0 {
            integrity = .fragmented(count: fragmented)
            rationale = String(format: "%d digit-run gap(s) below %.1fx the %.0fpx pitch — split glyphs, position not countable",
                               fragmented, fragmentPitchRatio, medianPitch)
        } else if fused > 0 {
            integrity = .fused(count: fused)
            rationale = String(format: "%d run(s) wider than %.1fx the median digit width (%.0fpx) — fused glyphs, position not countable",
                               fused, fusedWidthRatio, medianWidth)
        } else {
            integrity = .clean
            rationale = "\(digitRuns.count) digit runs, \(separatorCount) separator(s), median width \(Int(medianWidth))px"
        }
        if separatorCount > 1 {
            rationale += "; \(separatorCount) separator candidates — position not reported"
        }
        if !accepted.isEmpty {
            rationale += "; accepted: " + accepted.joined(separator: ", ")
        }
        if !rejected.isEmpty {
            rationale += "; rejected: " + rejected.joined(separator: ", ")
        }
        // When NOTHING was even a candidate, the interesting question is what
        // the column scan actually produced — a separator absorbed into a digit
        // run leaves no trace anywhere else. Attached only in that case, so the
        // rationale stays short on the common path.
        if separatorCount == 0 {
            rationale += "; runs " + runs.map {
                String(format: "[%d-%d h%.2f]", $0.x0, $0.x1, Double($0.height) / Double(tallest))
            }.joined(separator: " ")
        }

        // A position is reported ONLY from a cleanly segmented band with exactly
        // one separator. A wrong position is the silent factor-of-ten error the
        // whole decimal-integrity effort exists to prevent; a missing one merely
        // costs recall and is resolved upstream by the format prior and
        // `TemporalConsensus`.
        let position = (integrity == .clean && separatorCount == 1) ? separatorIndex : nil

        return Row(band: bandROI,
                   cells: cells,
                   digitCount: digitRuns.count,
                   separatorPosition: position,
                   integrity: integrity,
                   rationale: rationale)
    }

    /// Vertical extent of the ink inside a column span, within the band.
    private static func makeRun(x0: Int, x1: Int, band: Range<Int>,
                                ink: [Bool], grid: InkGrid) -> Run? {
        var y0 = Int.max
        var y1 = Int.min
        for y in band {
            let base = y * grid.width
            for x in x0...x1 where ink[base + x] {
                if y < y0 { y0 = y }
                if y > y1 { y1 = y }
                break
            }
        }
        guard y0 <= y1 else { return nil }
        return Run(x0: x0, x1: x1, y0: y0, y1: y1)
    }

    /// Peels a decimal separator out of a digit run that antialiasing or bloom
    /// has bridged into it, from EITHER side.
    ///
    /// Both directions are needed, and that was established by measurement, not
    /// symmetry: a trailing-only version recovered the separator in DSEG7
    /// "80.8" and "12.345" but not in "99.9", "0.001" or "100.0", because in
    /// those renders the dot bridges into the digit that FOLLOWS it rather than
    /// the one before. Handling one side only looks like it works and silently
    /// loses the separator on the other half of the corpus.
    private static func splitFusedSeparator(_ run: Run, tallest: Int,
                                            ink: [Bool], grid: InkGrid) -> [Run] {
        let afterTrailing = peel(run, fromRight: true, tallest: tallest, ink: ink, grid: grid)
        // The digit part is whichever piece is still digit-height; try the other
        // side on it. A run can legitimately carry a dot at both ends (".5.").
        guard let digitPart = afterTrailing.first,
              Double(digitPart.height) >= digitHeightFraction * Double(tallest) else {
            return afterTrailing
        }
        let leading = peel(digitPart, fromRight: false, tallest: tallest, ink: ink, grid: grid)
        return leading + afterTrailing.dropFirst()
    }

    /// Walks in from one edge of `run` while the columns hold only
    /// baseline-hugging ink. The moment a column reaches up into the digit body
    /// the mark is over, and everything beyond that point is the separator.
    /// Returns the pieces in left-to-right order, or `[run]` unchanged.
    private static func peel(_ run: Run, fromRight: Bool, tallest: Int,
                             ink: [Bool], grid: InkGrid) -> [Run] {
        // Only digit-height runs can be hiding a separator, and only ones wide
        // enough that a dot's worth of columns could have been absorbed.
        guard Double(run.height) >= digitHeightFraction * Double(tallest),
              run.width >= 6 else { return [run] }

        let markWidth = max(1, Int(Double(run.width) * tailFraction))
        // A separator sits ON the baseline whichever side it bridged from, so
        // the body test is the same in both directions.
        let bodyLimit = run.y1 - Int(Double(run.height) * tailMaxHeightFraction)

        @inline(__always) func reachesBody(_ x: Int) -> Bool {
            for y in run.y0...run.y1 where ink[y * grid.width + x] {
                if y <= bodyLimit { return true }
            }
            return false
        }

        var split: Int?
        if fromRight {
            let limit = run.x1 - markWidth + 1
            guard limit > run.x0 else { return [run] }
            var x = run.x1
            while x >= limit, !reachesBody(x) { split = x; x -= 1 }
        } else {
            let limit = run.x0 + markWidth - 1
            guard limit < run.x1 else { return [run] }
            var x = run.x0
            while x <= limit, !reachesBody(x) { split = x; x += 1 }
        }
        guard let boundary = split else { return [run] }

        let markRange = fromRight ? (boundary, run.x1) : (run.x0, boundary)
        let digitRange = fromRight ? (run.x0, boundary - 1) : (boundary + 1, run.x1)
        guard digitRange.0 <= digitRange.1 else { return [run] }

        // Both halves must be real: a digit-height body and a dot-sized mark.
        let span = run.y0..<(run.y1 + 1)
        guard let digit = makeRun(x0: digitRange.0, x1: digitRange.1, band: span, ink: ink, grid: grid),
              let mark = makeRun(x0: markRange.0, x1: markRange.1, band: span, ink: ink, grid: grid),
              Double(digit.height) >= digitHeightFraction * Double(tallest),
              Double(mark.height) <= smallHeightFraction * Double(tallest)
        else { return [run] }

        return fromRight ? [digit, mark] : [mark, digit]
    }

    // MARK: - Small helpers

    /// Gate scaled to the profile's own non-zero median, so it adapts to
    /// exposure and to how much background the crop included.
    private static func adaptiveGate(_ profile: [Int], fraction: Double) -> Int {
        let nonZero = profile.filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 1 }
        return max(1, Int(Double(nonZero[nonZero.count / 2]) * fraction))
    }

    private static func runs(in values: [Int], gate: Int, minLength: Int) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start: Int?
        for (index, value) in values.enumerated() {
            if value >= gate {
                if start == nil { start = index }
            } else if let s = start {
                spans.append(s..<index)
                start = nil
            }
        }
        if let s = start { spans.append(s..<values.count) }
        return spans.filter { $0.count >= minLength }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    // MARK: - Ink grid (decimated luminance + LOCAL adaptive binarization)

    /// Decimated luminance view of a pixel buffer, binarized with a LOCAL
    /// adaptive threshold.
    ///
    /// WHY NOT `LuminanceGrid`. This started out using the shared
    /// `LuminanceGrid`, whose threshold is a single GLOBAL value derived from
    /// the luminance histogram. That works for locating digit bands, which is
    /// what it was built for, and it fails for separators — which was MEASURED
    /// here, not assumed. Under a global threshold the column scan produced,
    /// for clean DSEG7 renders:
    ///
    ///     "80.8"   runs for 3 digits + a square 20px dot  → position 2 ✓
    ///     "12.345" runs for 5 digits + a square 18px dot  → position 2 ✓
    ///     "99.9"   runs for 3 digits and NO DOT AT ALL    → no position ✗
    ///     "0.001"  runs for 4 digits and NO DOT AT ALL    → no position ✗
    ///
    /// The dot was not misclassified in the failing cases; it produced no
    /// foreground pixels whatsoever. That is exactly the failure `DecimalRescue`
    /// documents in its own header — "a global threshold tuned for the
    /// (brighter, wider) digit strokes erases a dimmer dot" — and exactly what
    /// OCR_SEGMENT_RESEARCH.md §3 predicts. A separator is the smallest, dimmest
    /// mark on the panel, so the layer that hunts for it cannot share a
    /// threshold with the layer that hunts for strokes.
    ///
    /// The local-mean (Bradley-style) threshold over an integral image costs
    /// nothing extra per window size and is the same family `DecimalRescue`
    /// already uses successfully on raster faces.
    struct InkGrid {
        let width: Int
        let height: Int
        /// Foreground mask, row-major.
        let ink: [Bool]

        /// Adaptive-threshold window as a fraction of image height, forced odd.
        /// Must be much larger than a stroke (so a stroke does not raise its own
        /// local mean and threshold itself away) and comparable to the digit
        /// band (so the mean tracks illumination across the display). Mirrors
        /// `DecimalRescue.windowFraction`.
        private static let windowFraction = 0.5
        private static let minWindow = 9
        /// Foreground when the local mean exceeds the pixel by more than this.
        /// The RELATIVE term survives a dimmed display (both terms scale); the
        /// ABSOLUTE floor stops flat, noisy background labelling itself ink.
        private static let relativeDelta = 0.10
        private static let absoluteDelta = 8.0

        init?(buffer: CVPixelBuffer) {
            guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
            let sourceWidth = CVPixelBufferGetWidth(buffer)
            let sourceHeight = CVPixelBufferGetHeight(buffer)
            guard sourceWidth >= SegmentCellScanner.minEdge,
                  sourceHeight >= SegmentCellScanner.minEdge else { return nil }

            let longEdge = Double(max(sourceWidth, sourceHeight))
            let step = max(1, Int((longEdge / SegmentCellScanner.maxLongEdge).rounded(.up)))
            let w = sourceWidth / step
            let h = sourceHeight / step
            guard w >= SegmentCellScanner.minEdge, h >= SegmentCellScanner.minEdge else { return nil }

            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let ptr = base.assumingMemoryBound(to: UInt8.self)

            var lum = [Double](repeating: 0, count: w * h)
            for y in 0..<h {
                let row = ptr + (y * step) * bytesPerRow
                let out = y * w
                for x in 0..<w {
                    // 32BGRA: memory bytes are B, G, R, A.
                    let p = row + (x * step) * 4
                    lum[out + x] = 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                }
            }

            // Polarity from the MAJORITY CLASS, not the border. A display is
            // overwhelmingly background with a minority of ink, so the median is
            // background by construction whatever the polarity — and unlike a
            // border sample it is not fooled by a crop that includes bezel.
            var histogram = [Int](repeating: 0, count: 256)
            for value in lum { histogram[min(255, max(0, Int(value)))] += 1 }
            func percentile(_ fraction: Double) -> Int {
                let target = Int(Double(lum.count) * fraction)
                var seen = 0
                for bin in 0..<256 {
                    seen += histogram[bin]
                    if seen > target { return bin }
                }
                return 255
            }
            let background = Double(percentile(0.5))
            let darkDistance = background - Double(percentile(0.02))
            let brightDistance = Double(percentile(0.98)) - background
            let inkIsBright = brightDistance > darkDistance

            // Integral image, (w+1) x (h+1).
            var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
            for y in 0..<h {
                var rowSum = 0.0
                let src = y * w
                let dst = (y + 1) * (w + 1)
                let prev = y * (w + 1)
                for x in 0..<w {
                    rowSum += lum[src + x]
                    integral[dst + x + 1] = integral[prev + x + 1] + rowSum
                }
            }

            var window = max(Self.minWindow, Int(Double(h) * Self.windowFraction))
            if window % 2 == 0 { window += 1 }
            let radius = window / 2

            var mask = [Bool](repeating: false, count: w * h)
            for y in 0..<h {
                let y0 = max(0, y - radius)
                let y1 = min(h - 1, y + radius)
                for x in 0..<w {
                    let x0 = max(0, x - radius)
                    let x1 = min(w - 1, x + radius)
                    let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                    let sum = integral[(y1 + 1) * (w + 1) + (x1 + 1)]
                        - integral[y0 * (w + 1) + (x1 + 1)]
                        - integral[(y1 + 1) * (w + 1) + x0]
                        + integral[y0 * (w + 1) + x0]
                    let localMean = sum / area
                    let value = lum[y * w + x]
                    let delta = inkIsBright ? (value - localMean) : (localMean - value)
                    mask[y * w + x] = delta > max(Self.relativeDelta * localMean, Self.absoluteDelta)
                }
            }

            self.width = w
            self.height = h
            self.ink = mask
        }

        /// Grid rect → normalized buffer space, padded and clamped to the unit
        /// square. Same convention as `LuminanceGrid.normalized`.
        func normalized(x0: Int, x1: Int, y0: Int, y1: Int, pad: Double) -> NormalizedROI {
            let w = Double(x1 - x0) / Double(width)
            let h = Double(y1 - y0) / Double(height)
            let px = w * pad
            let py = h * pad
            let nx = max(0, Double(x0) / Double(width) - px)
            let ny = max(0, Double(y0) / Double(height) - py)
            return NormalizedROI(x: CGFloat(nx), y: CGFloat(ny),
                                 width: CGFloat(min(1 - nx, w + 2 * px)),
                                 height: CGFloat(min(1 - ny, h + 2 * py)))
        }
    }
}
