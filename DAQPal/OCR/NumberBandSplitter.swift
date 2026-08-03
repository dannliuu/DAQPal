//
//  NumberBandSplitter.swift
//  DAQPal
//
//  Finds the candidate numeric regions inside a manually placed ROI, so the
//  user can be offered sub-boxes to pick from ("this window contains two
//  numbers — which do you want to record?").
//
//  WHY NOT VISION. The obvious way to locate numbers is `VNRecognizeTextRequest`
//  and take its bounding boxes — and that is what `ScreenFieldAnalyzer` does.
//  But this project has MEASURED Vision at 14.6% on seven-segment glyphs (41.7%
//  with the dual-pass engine), and the target instrument is a seven-segment IR
//  thermometer. A localizer that inherits that weakness fails on exactly the
//  hardware this feature exists for.
//
//  So this uses ink projection instead, which is indifferent to glyph shape:
//  a row projection separates stacked readings (they occupy different bands of
//  the display), and a column projection within a band separates a reading from
//  an adjacent legend such as `MAX`. Nothing here recognises characters — it
//  only answers "where is there ink, and how is it grouped".
//
//  RECALL OVER PRECISION, deliberately. The user picks the box they want, so
//  offering a spurious candidate costs one ignored rectangle, while missing the
//  real reading costs the feature. Candidates are therefore returned generously
//  and ranked, not filtered hard.
//
//  DETERMINISM. Pure integer arithmetic over pixels in raster order; no ML, no
//  randomness, no `Date()`. Same buffer ⇒ same candidates, same order.
//

import CoreGraphics
import CoreVideo
import Foundation

/// Locates candidate numeric regions inside an ROI crop by ink projection.
enum NumberBandSplitter {

    /// One candidate region the user may select.
    struct Candidate: Equatable, Sendable {
        /// Region in the CROP's normalized space (0...1, top-left origin), i.e.
        /// relative to the window the user placed — which is what lets it ride
        /// along when that window is dragged or resized.
        var region: NormalizedROI
        /// Tallest ink run in the band, in crop-normalized units. The primary
        /// reading on an instrument is conventionally the largest element, so
        /// this is the ranking signal — and it is measured on the TALLEST glyph,
        /// never the mean, because a fractional digit is often rendered shorter
        /// than the integer digits beside it (observed on the target device:
        /// the trailing `0` of `90.0` is visibly shorter than the `90`).
        var glyphHeight: CGFloat
        /// Ink coverage within the region, 0...1. Icon clusters and legends run
        /// lower than digit runs; exposed for ranking rather than filtering.
        var inkDensity: CGFloat
    }

    // MARK: Tunables (geometry policy, not measurements)

    /// Long-edge cap before the luminance grid is decimated.
    ///
    /// A band is a whole reading, so this needs far less resolution than
    /// recognition does. Reducing it is nevertheless NOT free: dropping to 400
    /// (step 2 on the measured 673×760 fixture) aliases the seven-segment
    /// strokes enough to erase the inter-band gaps entirely, and the real
    /// display collapsed from three candidates back to one. Resolution stays
    /// here: at 6.5 ms per pass in Release there is nothing to buy.
    private static let maxLongEdge = 900.0
    private static let minEdge = 24
    /// Row gate for "this row is part of a reading", as a fraction of the row
    /// profile's own PEAK.
    ///
    /// The basis matters more than the number, and two earlier bases were
    /// wrong for instructive reasons:
    ///
    /// - A fraction of the image WIDTH (4%) sat below the real instrument's
    ///   inter-band gaps, which hold 47–76 ink pixels of bezel shadow and noise
    ///   rather than zero. Every row read as content; the crop came back as one
    ///   band.
    /// - A fraction of the profile's MEDIAN (60%) fixed that display but moves
    ///   with the CONTENT rather than with the gap floor. A large primary drags
    ///   the median up, so a smaller secondary reading falls below the gate and
    ///   fragments into runs too short to survive `minBandHeightFraction` — the
    ///   band then disappears silently. Measured on the synthetic dual panel:
    ///   secondary rows carry 14–57 ink against a median-derived gate of 42, so
    ///   only two rows in the whole reading qualified.
    ///
    /// Scaling off the peak instead brackets both cases at once. Measured
    /// constraints, which is what fixes the value:
    ///
    /// | display | peak | must exceed | must not exceed | admissible fraction |
    /// |---|---|---|---|---|
    /// | real IR gun | 534 | gaps at 76 | content at 106 | 0.143 – 0.198 |
    /// | synthetic dual | 137 | gaps at 0 | secondary at 28 | 0 – 0.204 |
    ///
    /// 0.17 sits inside both. Note this makes the gate sensitive to a single
    /// very bright row; structural-row exclusion above is what keeps a bezel
    /// edge from becoming that row.
    private static let profileGateFraction = 0.17
    /// Column gate WITHIN a band stays on the median basis: a band already
    /// contains one line of similar-sized glyphs, so there is no large/small
    /// population for the median to be dragged between. Measured column gates
    /// group both readings and separate the `MAX` legend correctly as-is.
    private static let columnGateFraction = 0.50
    /// Bands thinner than this fraction of the crop are noise (a bezel edge, a
    /// glare line), not readings.
    private static let minBandHeightFraction = 0.06
    /// Column groups narrower than this fraction of the crop cannot hold a
    /// multi-digit reading.
    private static let minGroupWidthFraction = 0.05
    /// A gap at least this wide (relative to the band's height) separates two
    /// groups on one row — e.g. the `MAX` legend from the reading beside it.
    /// Scaled by band height because inter-digit gaps scale with glyph size.
    private static let groupGapFraction = 0.45
    /// Padding added around each candidate so a crop for recognition does not
    /// clip glyph edges.
    private static let padFraction = 0.04

    /// Candidate numeric regions inside `buffer`, best-first (tallest glyphs
    /// first). Never throws; unreadable input yields an empty array.
    static func candidates(in buffer: CVPixelBuffer) -> [Candidate] {
        PipelineMetrics.shared.measure(.analysis) {
            guard let grid = LuminanceGrid(buffer: buffer,
                                           maxLongEdge: maxLongEdge,
                                           minEdge: minEdge) else { return [] }
            return split(grid)
        }
    }

    /// Columns/rows that are ink across most of their extent are STRUCTURE — a
    /// bezel edge, a shadow, a case seam — not glyphs. A digit never occupies
    /// most of the crop's height in a single column, but a bezel sliver does.
    ///
    /// This matters because a user's window will rarely be cropped exactly to
    /// the glass. Measured on the real instrument photo: a dark bezel strip
    /// down the left edge put ink in every row, so the row projection found no
    /// gap and returned the whole crop as one band. Excluding structural
    /// columns before projecting is what makes the splitter tolerant of a
    /// hand-placed window.
    private static let structuralFraction = 0.80

#if DEBUG
    /// Exposes the intermediate row projection so a band-splitting failure can
    /// be read from the shipping code path rather than reconstructed from a
    /// side-channel. Every previous attempt to infer this from outside was
    /// wrong, twice in ways that cost hours.
    static func debugRowTrace(_ buffer: CVPixelBuffer) -> String {
        guard let g = LuminanceGrid(buffer: buffer, maxLongEdge: maxLongEdge, minEdge: minEdge)
        else { return "grid failed" }
        let thr = g.inkThreshold()
        var colTotals = [Int](repeating: 0, count: g.width)
        var rowTotals = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height {
            for x in 0..<g.width where g.isInk(x, y, thr) { colTotals[x] += 1; rowTotals[y] += 1 }
        }
        let colStructural = colTotals.map { Double($0) >= structuralFraction * Double(g.height) }
        let rowStructural = rowTotals.map { Double($0) >= structuralFraction * Double(g.width) }
        var rowInk = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height where !rowStructural[y] {
            var n = 0
            for x in 0..<g.width where !colStructural[x] && g.isInk(x, y, thr) { n += 1 }
            rowInk[y] = n
        }
        let gate = peakGate(rowInk, fraction: profileGateFraction)
        let minLen = max(2, Int(Double(g.height) * minBandHeightFraction))
        let bridge = max(2, Int(Double(g.height) * bandBridgeFraction))
        let bands = runs(in: rowInk, gate: gate, minLength: minLen, mergeGapsUpTo: bridge)
        var groupLines: [String] = []
        for band in bands {
            var colInk = [Int](repeating: 0, count: g.width)
            for x in 0..<g.width where !colStructural[x] {
                var n = 0
                for y in band.lowerBound..<band.upperBound
                where !rowStructural[y] && g.isInk(x, y, thr) { n += 1 }
                colInk[x] = n
            }
            let bandHeight = band.upperBound - band.lowerBound
            let cg = adaptiveGate(colInk, fraction: columnGateFraction)
            let minW = max(2, Int(Double(g.width) * minGroupWidthFraction))
            let bridgeW = max(2, Int(Double(bandHeight) * groupGapFraction))
            let groups = runs(in: colInk, gate: cg, minLength: minW, mergeGapsUpTo: bridgeW)
            groupLines.append("  band \(band.lowerBound)..<\(band.upperBound) h=\(bandHeight) colGate=\(cg) minW=\(minW) bridgeW=\(bridgeW) colMax=\(colInk.max() ?? 0) nonzeroCols=\(colInk.filter { $0 > 0 }.count) groups=\(groups.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " "))")
        }
        let structuralRows = rowStructural.filter { $0 }.count
        let structuralCols = colStructural.filter { $0 }.count
        return """
        grid \(g.width)x\(g.height) thr=\(thr) gate=\(gate) minLen=\(minLen) bridge=\(bridge)
        structural rows=\(structuralRows) cols=\(structuralCols)
        rowInk max=\(rowInk.max() ?? 0) nonzero=\(rowInk.filter { $0 > 0 }.count)
        bands=\(bands.map { "\($0.lowerBound)..<\($0.upperBound)" }.joined(separator: " "))
        \(groupLines.joined(separator: "\n"))
        """
    }
#endif

    private static func split(_ g: LuminanceGrid) -> [Candidate] {
        let thr = g.inkThreshold()

        // Identify structural columns/rows first, and exclude them from the
        // projections below.
        var colTotals = [Int](repeating: 0, count: g.width)
        var rowTotals = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height {
            for x in 0..<g.width where g.isInk(x, y, thr) {
                colTotals[x] += 1
                rowTotals[y] += 1
            }
        }
        let colStructural = colTotals.map { Double($0) >= structuralFraction * Double(g.height) }
        let rowStructural = rowTotals.map { Double($0) >= structuralFraction * Double(g.width) }

        // Usability is MATERIALIZED into a mask rather than recomputed per
        // lookup: the band, group and density passes below each sweep the grid
        // again, so as a function it was evaluated several million times on a
        // full-window crop.
        //
        // Sizing this honestly, because the first measurement was misleading.
        // Analysis of the 673×760 fixture measures 6.5 ms in RELEASE, which is
        // nothing — it runs once per window placement, not per frame. The same
        // code measures ~310 ms in DEBUG, and an early Debug reading of 934 ms
        // looked like a serious frame-drain stall. Most of that gap is Debug
        // overhead (bounds checks, no inlining), not algorithmic cost.
        let width = g.width
        var usableMask = [Bool](repeating: false, count: width * g.height)
        var rowInk = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height where !rowStructural[y] {
            var n = 0
            let row = y * width
            for x in 0..<width where !colStructural[x] && g.isInk(x, y, thr) {
                usableMask[row + x] = true
                n += 1
            }
            rowInk[y] = n
        }
        @inline(__always) func usable(_ x: Int, _ y: Int) -> Bool {
            usableMask[y * width + x]
        }
        let rowGate = peakGate(rowInk, fraction: profileGateFraction)
        let bands = runs(in: rowInk, gate: rowGate,
                         minLength: max(2, Int(Double(g.height) * minBandHeightFraction)),
                         mergeGapsUpTo: max(2, Int(Double(g.height) * bandBridgeFraction)))

        var out: [Candidate] = []
        for band in bands {
            // --- columns within the band: separate reading from legend ----
            var colInk = [Int](repeating: 0, count: g.width)
            for x in 0..<g.width {
                var n = 0
                for y in band.lowerBound..<band.upperBound where usable(x, y) { n += 1 }
                colInk[x] = n
            }
            let bandHeight = band.upperBound - band.lowerBound
            let colGate = adaptiveGate(colInk, fraction: columnGateFraction)
            let gap = max(2, Int(Double(bandHeight) * groupGapFraction))
            let groups = runs(in: colInk, gate: colGate,
                              minLength: max(2, Int(Double(g.width) * minGroupWidthFraction)),
                              mergeGapsUpTo: gap)

            for group in groups {
                // Trim the band vertically to THIS group's own ink, so a short
                // legend beside a tall reading does not inherit the reading's
                // height (which would defeat the ranking signal).
                var top = band.upperBound, bottom = band.lowerBound
                for y in band.lowerBound..<band.upperBound {
                    var any = false
                    for x in group.lowerBound..<group.upperBound where usable(x, y) { any = true; break }
                    if any { top = min(top, y); bottom = max(bottom, y + 1) }
                }
                guard bottom > top else { continue }

                var inkPixels = 0
                for y in top..<bottom {
                    for x in group.lowerBound..<group.upperBound where usable(x, y) { inkPixels += 1 }
                }
                let area = (bottom - top) * (group.upperBound - group.lowerBound)
                guard area > 0 else { continue }

                let region = g.normalized(x0: group.lowerBound, x1: group.upperBound,
                                          y0: top, y1: bottom, pad: padFraction)
                out.append(Candidate(region: region,
                                     glyphHeight: CGFloat(bottom - top) / CGFloat(g.height),
                                     inkDensity: CGFloat(inkPixels) / CGFloat(area)))
            }
        }
        // Tallest first: the primary reading is conventionally the largest
        // element. Ties broken by reading order so the result is stable.
        return out.sorted { a, b in
            if a.glyphHeight != b.glyphHeight { return a.glyphHeight > b.glyphHeight }
            if a.region.y != b.region.y { return a.region.y < b.region.y }
            return a.region.x < b.region.x
        }
    }

    /// Brief dips below the gate INSIDE one reading are bridged, so a band is
    /// broken only by a sustained run of background.
    ///
    /// Row ink is not smooth across a reading: it peaks through digit bodies
    /// and dips through the horizontal gaps inside glyphs. On the measured
    /// synthetic panel the smaller secondary reading averages 63–119 ink per
    /// row against a gate of 57 — above it on average, but oscillating across
    /// it row by row. Without bridging, that reading shattered into runs each
    /// shorter than `minBandHeightFraction` and every fragment was discarded,
    /// so the band vanished entirely and only the larger primary was offered.
    ///
    /// Sized well below a genuine inter-band gap so the two cannot be confused:
    /// the measured gaps are 48 rows (synthetic) and 76 rows (real instrument),
    /// while this bridges at most 3% of the crop — 7 and 22 rows respectively.
    private static let bandBridgeFraction = 0.03

    /// Gate scaled to the profile's peak (see `profileGateFraction`).
    private static func peakGate(_ profile: [Int], fraction: Double) -> Int {
        guard let peak = profile.max(), peak > 0 else { return 1 }
        return max(1, Int(Double(peak) * fraction))
    }

    /// Gate scaled to the profile's own median of its NON-ZERO entries.
    private static func adaptiveGate(_ profile: [Int], fraction: Double) -> Int {
        let nonZero = profile.filter { $0 > 0 }.sorted()
        guard !nonZero.isEmpty else { return 1 }
        let median = nonZero[nonZero.count / 2]
        return max(1, Int(Double(median) * fraction))
    }

    /// Contiguous runs where `values` clears `gate`, discarding runs shorter
    /// than `minLength` and bridging gaps up to `mergeGapsUpTo`.
    private static func runs(in values: [Int], gate: Int, minLength: Int,
                             mergeGapsUpTo bridge: Int = 0) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var start: Int?
        for (i, v) in values.enumerated() {
            if v >= gate {
                if start == nil { start = i }
            } else if let s = start {
                spans.append(s..<i)
                start = nil
            }
        }
        if let s = start { spans.append(s..<values.count) }
        guard bridge > 0 else { return spans.filter { $0.count >= minLength } }

        var merged: [Range<Int>] = []
        for span in spans {
            if let last = merged.last, span.lowerBound - last.upperBound <= bridge {
                merged[merged.count - 1] = last.lowerBound..<span.upperBound
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.count >= minLength }
    }
}

/// Decimated luminance view of a pixel buffer with polarity detection, shared
/// by the projection splitter. Mirrors the sampling conventions already used by
/// `DecimalRescue` and `SevenSegmentSampler`.
struct LuminanceGrid {
    let width: Int
    let height: Int
    private let values: [UInt8]
    /// True when ink is BRIGHTER than background (VFD/OLED) rather than darker
    /// (LCD). Detected from the border, matching `SevenSegmentSampler`.
    private let inkIsBright: Bool

    init?(buffer: CVPixelBuffer, maxLongEdge: Double, minEdge: Int) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard w >= minEdge, h >= minEdge,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let step = max(1, Int((Double(max(w, h)) / maxLongEdge).rounded(.up)))
        let gw = w / step, gh = h / step
        guard gw >= minEdge, gh >= minEdge else { return nil }

        var v = [UInt8](repeating: 0, count: gw * gh)
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<gh {
            let row = (y * step) * stride
            for x in 0..<gw {
                let i = row + (x * step) * 4
                // BGRA; Rec.601 luma in integer arithmetic.
                let l = (Int(p[i + 2]) * 299 + Int(p[i + 1]) * 587 + Int(p[i]) * 114) / 1000
                v[y * gw + x] = UInt8(clamping: l)
            }
        }
        // Polarity from the MAJORITY CLASS, not from the border.
        //
        // Border sampling assumes the frame edge is background, which fails the
        // moment a user's window includes any bezel: measured on the real
        // instrument photo, a dark bezel edge made the heuristic conclude "ink
        // is bright" and classify the entire LCD as one 95%-density blob.
        //
        // A display is overwhelmingly background with a minority of ink, so the
        // MEDIAN is background by construction, whatever the polarity. Ink is
        // then whichever tail lies further from it — which is true for a dark
        // LCD, a bright VFD, and a window containing stray bezel alike.
        // Percentiles come from a 256-bin histogram rather than a sort.
        // Sorting meant allocating and ordering one Int per sampled pixel —
        // a 4 MB allocation and an O(n log n) pass for a statistic that has
        // only 256 possible values. The counting pass is exact, linear and
        // allocation-free, so it is simply the right shape regardless of how
        // much wall clock it happened to save.
        var histogram = [Int](repeating: 0, count: 256)
        for sample in v { histogram[Int(sample)] += 1 }
        func percentile(_ fraction: Double) -> Int {
            let target = Int(Double(v.count) * fraction)
            var seen = 0
            for bin in 0..<256 {
                seen += histogram[bin]
                if seen > target { return bin }
            }
            return 255
        }
        let background = percentile(0.5)
        let darkTail = percentile(0.02)
        let brightTail = percentile(0.98)
        let darkDistance = background - darkTail
        let brightDistance = brightTail - background
        self.width = gw
        self.height = gh
        self.values = v
        self.inkIsBright = brightDistance > darkDistance
        // Threshold sits a third of the way from background toward the ink
        // tail: clear of background noise, well inside the ink population.
        let travel = max(4, (self.inkIsBright ? brightDistance : darkDistance) / 3)
        self.threshold = self.inkIsBright ? background + travel : background - travel
    }

    /// Precomputed ink threshold (see `init`).
    let threshold: Int

    /// The threshold computed in `init` from the background/ink populations.
    func inkThreshold() -> Int { threshold }

    func isInk(_ x: Int, _ y: Int, _ threshold: Int) -> Bool {
        let l = Int(values[y * width + x])
        return inkIsBright ? l > threshold : l < threshold
    }

    /// Grid rect → normalized crop space, padded and clamped to the unit square.
    func normalized(x0: Int, x1: Int, y0: Int, y1: Int, pad: Double) -> NormalizedROI {
        let w = Double(x1 - x0) / Double(width)
        let h = Double(y1 - y0) / Double(height)
        let px: Double = w * pad
        let py: Double = h * pad
        let nx: Double = max(0, Double(x0) / Double(width) - px)
        let ny: Double = max(0, Double(y0) / Double(height) - py)
        let nw: Double = min(1 - nx, w + 2 * px)
        let nh: Double = min(1 - ny, h + 2 * py)
        return NormalizedROI(x: CGFloat(nx), y: CGFloat(ny),
                             width: CGFloat(nw), height: CGFloat(nh))
    }
}
