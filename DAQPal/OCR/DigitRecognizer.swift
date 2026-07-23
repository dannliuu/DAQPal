//
//  DigitRecognizer.swift
//  DAQPal
//
//  Digit-level recognition STUB (spec §11, Milestone 5). This file is the
//  future home of the specialized per-digit classifier — seven-segment
//  pattern matching or a tiny 0–9 CNN (spec §12–§13). Today it approximates
//  that architecture by running general Vision OCR once per digit cell and
//  post-filtering the result to the characters 0–9, because Vision offers no
//  true character-set constraint. No accuracy claim is made for this path; it
//  exists so per-digit confidences (`Measurement.digitConfidences`) and the
//  digit-level temporal architecture (spec §16) have a working seam.
//

import CoreVideo
import Foundation

struct DigitRecognizer {
    private let engine: any OCREngine

    init(engine: any OCREngine = VisionOCR()) {
        self.engine = engine
    }

    /// Recognizes one digit per cell inside an ROI crop.
    ///
    /// - Parameters:
    ///   - roiCrop: The pixel buffer already cropped to the device's ROI
    ///     (see `PixelBufferROI`).
    ///   - cells: Digit cells normalized to the crop itself (unit square ==
    ///     the crop), as produced by
    ///     `DigitSegmenter.digitCells(in: .init(x: 0, y: 0, width: 1, height: 1), ...)`.
    /// - Returns: One entry per cell, in the same order. `digit` is nil when
    ///   the cell did not resolve to exactly one 0–9 character; the reported
    ///   confidence is then the (low) confidence of whatever was seen, or 0.
    func recognizeDigits(in roiCrop: CVPixelBuffer,
                         cells: [NormalizedROI]) async -> [(digit: Character?, confidence: Float)] {
        var results: [(digit: Character?, confidence: Float)] = []
        results.reserveCapacity(cells.count)
        for cell in cells {
            results.append(await recognizeCell(cell, in: roiCrop))
        }
        return results
    }

    private func recognizeCell(_ cell: NormalizedROI,
                               in roiCrop: CVPixelBuffer) async -> (digit: Character?, confidence: Float) {
        let candidates = (try? await engine.recognize(in: roiCrop, regionOfInterest: cell)) ?? []
        guard let best = candidates.first else { return (nil, 0) }

        // Post-hoc 0–9 restriction: normalize the usual OCR confusables
        // (O→0 etc.), then require exactly one digit in the cell. Anything
        // else (empty, multiple digits from cell bleed, stray glyphs) is an
        // ambiguous cell. The specialized classifier replacing this stub
        // will emit a 0–9 distribution directly.
        let normalized = FormatValidator.normalizeConfusables(best.text)
        let digits = normalized.filter { $0.isASCII && $0.isNumber }
        guard digits.count == 1, let digit = digits.first else {
            return (nil, min(best.confidence, 0.1))
        }
        return (digit, best.confidence)
    }
}
