//
//  DualPassVisionOCR.swift
//  DAQPal
//
//  A training-free robustness lever justified by the Milestone 9 benchmark
//  (OCR_RESEARCH.md, "Measured results"): on the identical synthetic corpus,
//  Vision `.fast` *out-reads* `.accurate` on seven-segment glyphs (33.3% vs
//  14.6%) and fourteen-segment (12.5% vs 2.1%) — its character-level classifier
//  copes with disconnected segment strokes that the `.accurate` line reader
//  drops — while `.accurate` stays far ahead on raster/OLED sans text (93.8% vs
//  68.8%) and, crucially, reports CALIBRATED confidences.
//
//  This engine runs both levels CONCURRENTLY over the same buffer + ROI (so the
//  `.fast` pass, ~11 ms, hides inside the `.accurate` pass, ~382 ms — the added
//  wall-clock is ~0) and merges their candidate lists:
//
//    - `.accurate`'s candidates come FIRST, in their own confidence order.
//    - then `.fast`'s candidates that are not textual duplicates of an
//      already-present one (same trimmed text ⇒ keep the `.accurate` entry).
//
//  The lists are NOT re-sorted across engines. The downstream picker takes the
//  first candidate that parses, so ordering encodes preference: `.accurate`
//  always wins whenever it produced a parseable reading (preserving its honest
//  confidence — the earlier 32%-confidence UI regression must not return),
//  while `.fast` only ever RESCUES a segment glyph `.accurate` missed entirely.
//  A fast-only reading carries `.fast`'s raw confidence, which is honest for
//  what it is (a lower-confidence rescue), not an inflated value.
//

import CoreVideo
import Foundation
import Vision

/// Concurrent two-level Vision engine: `.accurate` preferred, `.fast` as a
/// rescue pass for segmented glyphs (see the file header for the measured
/// rationale).
struct DualPassVisionOCR: OCREngine {
    /// Preferred engine — its candidates lead the merged list. Defaults to
    /// Vision `.accurate`.
    private let primary: any OCREngine
    /// Rescue engine — supplies only candidates the primary did not already
    /// produce. Defaults to Vision `.fast`.
    private let rescue: any OCREngine

    /// Shipping configuration: Vision `.accurate` primary, `.fast` rescue.
    init() {
        self.init(primary: VisionOCR(recognitionLevel: .accurate),
                  rescue: VisionOCR(recognitionLevel: .fast))
    }

    /// Injection seam for testing the merge behavior with stub engines. Not
    /// used by the app, which relies on the two-Vision-level default above.
    init(primary: any OCREngine, rescue: any OCREngine) {
        self.primary = primary
        self.rescue = rescue
    }

    func recognize(in pixelBuffer: CVPixelBuffer,
                   regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
        // Both passes run concurrently; each failure is captured (not thrown)
        // so one engine erroring does not sink the other's usable candidates.
        async let primaryOutcome = Self.attempt(primary, pixelBuffer, regionOfInterest)
        async let rescueOutcome = Self.attempt(rescue, pixelBuffer, regionOfInterest)
        let primaryResult = await primaryOutcome
        let rescueResult = await rescueOutcome

        switch (primaryResult, rescueResult) {
        case let (.success(primaryCandidates), .success(rescueCandidates)):
            return Self.merge(primary: primaryCandidates, rescue: rescueCandidates)
        case let (.success(primaryCandidates), .failure):
            return primaryCandidates
        case let (.failure, .success(rescueCandidates)):
            return rescueCandidates
        case let (.failure(primaryError), .failure):
            // Both engines failed — surface the primary's error, matching a
            // single-engine failure's behavior.
            throw primaryError
        }
    }

    /// Runs one engine, folding a thrown error into a `Result` so callers can
    /// await both passes without one failure cancelling the other.
    private static func attempt(_ engine: any OCREngine,
                                _ pixelBuffer: CVPixelBuffer,
                                _ regionOfInterest: NormalizedROI?) async -> Result<[OCRCandidate], Error> {
        do {
            return .success(try await engine.recognize(in: pixelBuffer,
                                                       regionOfInterest: regionOfInterest))
        } catch {
            return .failure(error)
        }
    }

    /// Primary candidates in order, then rescue candidates whose trimmed text
    /// is not already present. De-duplication is by trimmed text only (the
    /// numeric content is what matters downstream); the first occurrence — a
    /// primary entry when there is a tie — is the one kept.
    private static func merge(primary: [OCRCandidate],
                              rescue: [OCRCandidate]) -> [OCRCandidate] {
        var merged = primary
        var seen = Set(primary.map { key(for: $0.text) })
        for candidate in rescue where seen.insert(key(for: candidate.text)).inserted {
            merged.append(candidate)
        }
        return merged
    }

    private static func key(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
