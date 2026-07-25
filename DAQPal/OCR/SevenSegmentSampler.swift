//
//  SevenSegmentSampler.swift
//  DAQPal
//
//  OCR_RESEARCH.md Phase 4 (fusion) — a deterministic, ML-free seven-segment
//  reader. It classifies a single upright digit inside a normalized cell by
//  sampling the seven canonical segment regions (a top bar, f/b upper
//  verticals, g middle bar, e/c lower verticals, d bottom bar), thresholding
//  each on/off from the cell's own luminance statistics, and decoding the
//  resulting 7-bit pattern through a lookup table (the "ssocr" approach —
//  imitated, not ported; ssocr itself is GPL).
//
//  ROLE: this is a *cross-check*, not the primary recognizer. The intent (per
//  the research doc) is to fuse its verdict as an extra multiplicative factor in
//  `ConfidenceEngine` on segmented displays — corroborate or veto a reading,
//  never inflate it. Two independent readers agreeing is a stronger signal than
//  either alone. It is standalone and pipeline-inert until that wiring lands.
//
//  DETERMINISM: pure arithmetic over pixels — no ML, no randomness, no Date().
//  The same buffer + cell always yields the same reading.
//
//  DOCUMENTED ASSUMPTIONS / LIMITATIONS:
//  - Input buffers are 32BGRA (the project-wide capture format). Luminance is
//    read from the B,G,R bytes; a non-BGRA buffer would be mis-sampled.
//  - One upright digit per cell, filling most of the cell (mirrors
//    `DigitSegmenter`'s fixed-pitch stub assumption). No skew/rotation handling.
//  - '.' (decimal point) is intentionally NOT decoded: a lone dot collapses to a
//    tiny bounding box and reads as blank. Decimal position comes from
//    `DisplayFormat`, not from this sampler. '.' -> digit nil.
//  - Polarity is auto-detected per cell (dark-on-light LCD vs light-on-dark
//    VFD/OLED) from border-vs-threshold statistics, so inverted displays decode
//    without configuration.
//
//  DEVIATION FROM THE PROSE CONTRACT (documented): the contract describes patch
//  geometry "as fractions of the cell". This implementation instead places the
//  seven patches as fractions of the digit's *detected ink bounding box* within
//  the cell. When the digit fills the cell the two are equivalent, but the
//  bbox-relative placement is robust to the centering/margin that both the
//  synthetic generator (which centers a ~0.6-height glyph) and real ROI crops
//  introduce — without it, edge patches sample background and every digit fails.
//  Two geometric special-cases fall out of using a tight bbox and are handled
//  before general sampling:
//    * "1": segments b,c only produce a very narrow, full-height box (aspect
//      << other digits) — decoded directly by aspect ratio.
//    * "-": the middle segment alone produces a wide, short, vertically-centred
//      box (short relative to the CELL height) — decoded directly.
//  The 7-bit patterns, bit order (bit0=a … bit6=g), and public API are exactly
//  as specified.
//
//  The segment-region fractions, thresholds, and the DSEG7 "7" alternate
//  (DSEG7 Classic renders '7' WITH the top-left segment f, pattern 0x27) were
//  calibrated by rendering the bundled DSEG7 glyphs and measuring per-segment
//  coverage; they are empirical constants, named below.
//

import CoreGraphics
import CoreVideo
import Foundation

/// A deterministic seven-segment digit reader (see file header).
struct SevenSegmentSampler {

    /// One decoded digit cell.
    struct DigitReading {
        /// The decoded character ('0'…'9' or '-'), or nil when the cell is blank
        /// or the segment pattern is unrecognized.
        let digit: Character?
        /// 0…1. For a decoded digit: the normalized margin of the *worst* segment
        /// on/off decision (how far the least-confident segment sits from the
        /// threshold). For a blank cell: high (clearly nothing lit). For an
        /// unrecognized pattern: low.
        let confidence: Float
        /// The sampled segment pattern. bit0=a, bit1=b, bit2=c, bit3=d, bit4=e,
        /// bit5=f, bit6=g. Zero for a blank cell.
        let segmentPattern: UInt8
    }

    // MARK: Segment bits (contract order: bit0=a … bit6=g)

    private static let segA: UInt8 = 1 << 0
    private static let segB: UInt8 = 1 << 1
    private static let segC: UInt8 = 1 << 2
    private static let segD: UInt8 = 1 << 3
    private static let segE: UInt8 = 1 << 4
    private static let segF: UInt8 = 1 << 5
    private static let segG: UInt8 = 1 << 6

    // MARK: Empirical tunables (calibrated against bundled DSEG7 glyphs)

    /// A patch counts as "lit" when this fraction of its pixels are foreground.
    /// Patches are sized generously (~box/5) so a fully-lit segment fills only
    /// ~0.55 of its patch; the threshold sits well below that and well above the
    /// ~0.0 of an unlit patch, giving a wide on/off margin.
    private static let onThreshold = 0.28
    /// Distance used to normalize the per-segment decision margin into 0…1.
    private static let marginScale = 0.28
    /// A digit whose bounding-box aspect (w/h) is below this is decoded as "1".
    private static let oneAspectThreshold = 0.42
    /// Below this fraction of cell area of foreground, the cell is blank.
    private static let blankAreaFraction = 0.01
    /// Bounding box built from rows/cols holding at least this fraction of the
    /// peak projection count — trims stray single-pixel noise from the extent.
    private static let projectionFraction = 0.12
    /// "-" detection: ink band shorter than this fraction of the CELL height…
    private static let dashMaxHeightFraction = 0.35
    /// …and wider than this fraction of the cell width, centred vertically.
    private static let dashMinWidthFraction = 0.30

    /// Segment patches as (x, y, width, height) fractions of the ink bounding
    /// box (top-left origin). Order: a, b, c, d, e, f, g.
    private static let patches: [(bit: UInt8, rect: CGRect)] = [
        (segA, CGRect(x: 0.26, y: 0.00, width: 0.48, height: 0.18)), // top bar
        (segB, CGRect(x: 0.74, y: 0.12, width: 0.24, height: 0.32)), // upper right
        (segC, CGRect(x: 0.74, y: 0.56, width: 0.24, height: 0.32)), // lower right
        (segD, CGRect(x: 0.26, y: 0.82, width: 0.48, height: 0.18)), // bottom bar
        (segE, CGRect(x: 0.02, y: 0.56, width: 0.24, height: 0.32)), // lower left
        (segF, CGRect(x: 0.02, y: 0.12, width: 0.24, height: 0.32)), // upper left
        (segG, CGRect(x: 0.26, y: 0.41, width: 0.48, height: 0.18)), // middle bar
    ]

    /// 7-segment pattern → digit. Includes common alternates so the reader is
    /// not overfit to one font: DSEG7 Classic '7' carries segment f (0x27); some
    /// displays draw '6' without the top bar (0x7C) and '9' without the bottom
    /// bar (0x67).
    private static let decodeTable: [UInt8: Character] = [
        0x3F: "0",             // a b c d e f
        0x06: "1",             // b c
        0x5B: "2",             // a b d e g
        0x4F: "3",             // a b c d g
        0x66: "4",             // b c f g
        0x6D: "5",             // a c d f g
        0x7D: "6", 0x7C: "6",  // a c d e f g  (+ no-top variant)
        0x07: "7", 0x27: "7",  // a b c        (+ DSEG7 f-tail variant)
        0x7F: "8",             // all
        0x6F: "9", 0x67: "9",  // a b c d f g  (+ no-bottom variant)
        0x40: "-",             // g
    ]

    // MARK: Public API

    /// Reads a single upright digit from `cell` (top-left normalized within the
    /// buffer). `cell` is assumed to bound one digit that fills most of it.
    func readDigit(in buffer: CVPixelBuffer, cell: NormalizedROI) -> DigitReading {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                               height: CVPixelBufferGetHeight(buffer))
        let rect = cell.clamped().pixelRect(in: imageSize)
        let width = Int(rect.width)
        let height = Int(rect.height)
        // Need at least a few pixels each way for the seven patches to be distinct.
        guard width >= 3, height >= 3 else {
            return DigitReading(digit: nil, confidence: 0, segmentPattern: 0)
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return DigitReading(digit: nil, confidence: 0, segmentPattern: 0)
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let originX = Int(rect.origin.x)
        let originY = Int(rect.origin.y)

        // Luminance grid over the cell (32BGRA: bytes are B, G, R, A).
        var luminance = [Double](repeating: 0, count: width * height)
        for row in 0..<height {
            let srcRow = ptr + (originY + row) * bytesPerRow
            for col in 0..<width {
                let p = srcRow + (originX + col) * 4
                luminance[row * width + col] =
                    0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
            }
        }

        return Self.decode(luminance: luminance, width: width, height: height)
    }

    /// Reads one digit per cell, left to right in the order given (typically the
    /// cells from `DigitSegmenter.digitCells`).
    func readDigits(in buffer: CVPixelBuffer, cells: [NormalizedROI]) -> [DigitReading] {
        cells.map { readDigit(in: buffer, cell: $0) }
    }

    // MARK: Decode

    private static func decode(luminance: [Double], width: Int, height: Int) -> DigitReading {
        // Threshold from the cell's own luminance range (midpoint), and decide
        // polarity from the border (which is background by assumption): a bright
        // border means dark-on-light, so foreground is the dark pixels.
        var minLum = Double.greatestFiniteMagnitude
        var maxLum = -Double.greatestFiniteMagnitude
        for value in luminance {
            if value < minLum { minLum = value }
            if value > maxLum { maxLum = value }
        }
        let mid = (minLum + maxLum) / 2

        var borderSum = 0.0
        var borderCount = 0
        for col in 0..<width {
            borderSum += luminance[col]
            borderSum += luminance[(height - 1) * width + col]
            borderCount += 2
        }
        if height > 2 {
            for row in 1..<(height - 1) {
                borderSum += luminance[row * width]
                borderSum += luminance[row * width + (width - 1)]
                borderCount += 2
            }
        }
        let borderMean = borderCount > 0 ? borderSum / Double(borderCount) : mid
        let darkOnLight = borderMean > mid

        // Foreground mask.
        var foreground = [Bool](repeating: false, count: width * height)
        var foregroundCount = 0
        for index in 0..<(width * height) {
            let lit = darkOnLight ? (luminance[index] < mid) : (luminance[index] > mid)
            foreground[index] = lit
            if lit { foregroundCount += 1 }
        }

        // Blank cell — nothing (meaningfully) lit.
        if Double(foregroundCount) < blankAreaFraction * Double(width * height) {
            return DigitReading(digit: nil, confidence: 0.9, segmentPattern: 0)
        }

        // Ink bounding box from row/column projections, trimming stray noise.
        var rowCount = [Int](repeating: 0, count: height)
        var colCount = [Int](repeating: 0, count: width)
        for row in 0..<height {
            let rowBase = row * width
            for col in 0..<width where foreground[rowBase + col] {
                rowCount[row] += 1
                colCount[col] += 1
            }
        }
        let rowThreshold = max(1, Int(projectionFraction * Double(rowCount.max() ?? 0)))
        let colThreshold = max(1, Int(projectionFraction * Double(colCount.max() ?? 0)))
        var y0 = 0
        while y0 < height && rowCount[y0] < rowThreshold { y0 += 1 }
        var y1 = height - 1
        while y1 > y0 && rowCount[y1] < rowThreshold { y1 -= 1 }
        var x0 = 0
        while x0 < width && colCount[x0] < colThreshold { x0 += 1 }
        var x1 = width - 1
        while x1 > x0 && colCount[x1] < colThreshold { x1 -= 1 }

        let boxWidth = Double(x1 - x0 + 1)
        let boxHeight = Double(y1 - y0 + 1)
        guard boxWidth >= 1, boxHeight >= 1 else {
            return DigitReading(digit: nil, confidence: 0.9, segmentPattern: 0)
        }

        // "-": wide, short (relative to the whole cell), vertically centred band.
        let heightFraction = boxHeight / Double(height)
        let widthFraction = boxWidth / Double(width)
        let verticalCenter = (Double(y0) + Double(y1)) / 2 / Double(height)
        if heightFraction < dashMaxHeightFraction,
           widthFraction > dashMinWidthFraction,
           abs(verticalCenter - 0.5) < 0.25 {
            return DigitReading(digit: "-", confidence: 0.7, segmentPattern: segG)
        }

        // "1": narrow, full-height box (segments b,c only).
        let aspect = boxWidth / boxHeight
        if aspect < oneAspectThreshold {
            let confidence = min(0.95, max(0.3, 0.5 + (oneAspectThreshold - aspect)))
            return DigitReading(digit: "1", confidence: Float(confidence),
                                segmentPattern: segB | segC)
        }

        // General case: sample the seven patches relative to the ink bbox.
        var pattern: UInt8 = 0
        var worstMargin = 1.0
        for patch in patches {
            let px0 = Double(x0) + patch.rect.origin.x * boxWidth
            let py0 = Double(y0) + patch.rect.origin.y * boxHeight
            let pw = patch.rect.width * boxWidth
            let ph = patch.rect.height * boxHeight
            let ix0 = max(0, Int(px0))
            let ix1 = min(width, max(Int(px0) + 1, Int(px0 + pw)))
            let iy0 = max(0, Int(py0))
            let iy1 = min(height, max(Int(py0) + 1, Int(py0 + ph)))
            var on = 0
            var total = 0
            for row in iy0..<iy1 {
                let rowBase = row * width
                for col in ix0..<ix1 {
                    total += 1
                    if foreground[rowBase + col] { on += 1 }
                }
            }
            let fraction = total > 0 ? Double(on) / Double(total) : 0
            if fraction >= onThreshold { pattern |= patch.bit }
            let margin = min(1.0, abs(fraction - onThreshold) / marginScale)
            if margin < worstMargin { worstMargin = margin }
        }

        if let digit = decodeTable[pattern] {
            return DigitReading(digit: digit, confidence: Float(worstMargin), segmentPattern: pattern)
        }
        // Unrecognized pattern — report low confidence (contract).
        return DigitReading(digit: nil, confidence: Float(min(0.2, worstMargin)), segmentPattern: pattern)
    }
}
