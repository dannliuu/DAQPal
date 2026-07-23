//
//  DigitSegmenter.swift
//  DAQPal
//
//  Naive fixed-pitch digit segmentation STUB (spec §40.4, Milestone 5).
//

import CoreGraphics
import Foundation

/// Splits a display ROI into per-digit cells.
///
/// STUB ASSUMPTION (documented per spec §40.5 step 24): digits are laid out
/// at fixed pitch — `digitCount` equal-width, full-height cells spanning the
/// ROI horizontally. Real display geometry (variable pitch, perspective,
/// seven-segment glyph metrics) is Milestone 11+ work and replaces this.
///
/// Sign/decimal handling choice: cells cover DIGITS ONLY.
/// - The decimal separator is assumed to render between digit cells and gets
///   no cell of its own; it is reinserted from `DisplayFormat.decimalPosition`
///   during reconstruction.
/// - A leading sign gets no cell either; the digit-level stub therefore does
///   not detect negative readings — sign detection stays with the whole-ROI
///   OCR path until real display geometry lands.
struct DigitSegmenter {
    /// Returns `format.digitCount` equal-width cells, left to right, in the
    /// same normalized space as `roi` (sub-rects of it).
    func digitCells(in roi: NormalizedROI, format: DisplayFormat) -> [NormalizedROI] {
        guard format.digitCount > 0 else { return [] }
        let cellWidth = roi.width / CGFloat(format.digitCount)
        return (0..<format.digitCount).map { index in
            NormalizedROI(x: roi.x + CGFloat(index) * cellWidth,
                          y: roi.y,
                          width: cellWidth,
                          height: roi.height)
        }
    }
}
