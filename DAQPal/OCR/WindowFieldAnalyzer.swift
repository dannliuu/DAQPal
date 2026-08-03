//
//  WindowFieldAnalyzer.swift
//  DAQPal
//
//  Runs `NumberBandSplitter` inside a placed window and turns what it finds
//  into rankable, tappable candidates (see `WindowSubField.swift` for why).
//
//  ON-DEMAND, NOT PER-FRAME. Analysis is a response to the user finishing a
//  window placement, not something the drain loop should carry: the splitter
//  builds a luminance grid and two projection profiles over the crop, which is
//  cheap next to OCR but is pure waste on the 99% of frames where the window
//  has not moved. The main actor leaves a request here; the drain loop services
//  it on the next frame it already has in hand and hands the result back. No
//  extra frame is captured and no per-frame cost is added when no request is
//  outstanding — `take()` is a nil check.
//

import CoreVideo
import Foundation

/// Serialises analysis requests from the UI against frames from the drain loop.
actor WindowFieldAnalyzer {

    /// Windows awaiting analysis, keyed by device. A second request for the
    /// same device before the first is serviced simply replaces it — the user
    /// dragged again and the older window is no longer what they mean.
    private var pending: [UUID: NormalizedROI] = [:]

    // MARK: Ranking policy

    /// A candidate must reach this fraction of the tallest candidate's glyph
    /// height to be offered. Measured on the target IR thermometer: the icon
    /// row (SCAN / laser / lamp / °F) sits at glyph height 0.066 against the
    /// primary reading's 0.370 — a ratio of 0.18 — so this cleanly separates
    /// instrument chrome from readings without needing to recognise either.
    private static let minimumRelativeGlyphHeight: CGFloat = 0.35

    /// Candidates taller than this multiple of their own width, IN PIXELS, are
    /// edge artefacts rather than digit runs. A bezel sliver on the same crop
    /// measured 42×303 px (ratio 7.2) while every genuine reading came in below
    /// 2.0. Evaluated in pixels, not normalized units, because the window is
    /// rarely square and normalized aspect would be anisotropic.
    private static let maximumAspectRatio: CGFloat = 4.0

    /// More boxes than this in one window stops being a choice and starts being
    /// clutter. Ranked by glyph height, so the ones dropped are the smallest.
    private static let maximumCandidates = 4

    // MARK: Requests

    /// Queues `roi` for analysis. Called from the main actor when the user
    /// finishes placing or moving a window.
    func request(deviceID: UUID, roi: NormalizedROI) {
        pending[deviceID] = roi
    }

    func cancel(deviceID: UUID) {
        pending.removeValue(forKey: deviceID)
    }

    /// Services every outstanding request against `frame`. Returns an empty
    /// array — allocating nothing and touching the frame not at all — when
    /// there is no pending work, which is the common case.
    func analyze(frame: CVPixelBuffer) -> [WindowAnalysis] {
        guard !pending.isEmpty else { return [] }
        let work = pending
        pending.removeAll()
        return work.compactMap { deviceID, roi in
            Self.analyze(frame: frame, roi: roi, deviceID: deviceID)
        }
    }

    /// Crops to the window, splits it, and ranks what came back.
    ///
    /// `nonisolated static` so it is directly testable without an actor hop and
    /// without a live pipeline.
    nonisolated static func analyze(frame: CVPixelBuffer,
                                    roi: NormalizedROI,
                                    deviceID: UUID) -> WindowAnalysis? {
        guard let crop = PixelBufferROI.cropped(frame, to: roi) else { return nil }
        let cropWidth = CGFloat(CVPixelBufferGetWidth(crop))
        let cropHeight = CGFloat(CVPixelBufferGetHeight(crop))
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        let raw = NumberBandSplitter.candidates(in: crop)
        guard let tallest = raw.map(\.glyphHeight).max(), tallest > 0 else {
            return WindowAnalysis(parentID: deviceID, candidates: [])
        }

        let kept = raw.filter { candidate in
            guard candidate.glyphHeight >= tallest * minimumRelativeGlyphHeight else { return false }
            let widthPx = candidate.region.width * cropWidth
            let heightPx = candidate.region.height * cropHeight
            guard widthPx > 0 else { return false }
            return heightPx / widthPx <= maximumAspectRatio
        }

        // Ranked tallest-first: rank 0 is what the UI labels MAIN, and on an
        // instrument face the largest element is the primary reading. Ties
        // break on horizontal position so the ordering is stable rather than
        // dependent on the splitter's traversal — two readings of equal height
        // side by side must not swap labels between passes.
        let ranked = kept
            .sorted {
                $0.glyphHeight != $1.glyphHeight
                    ? $0.glyphHeight > $1.glyphHeight
                    : $0.region.x < $1.region.x
            }
            .prefix(maximumCandidates)
            .enumerated()
            .map { index, candidate in
                WindowCandidate(id: UUID(),
                                region: candidate.region,
                                glyphHeight: candidate.glyphHeight,
                                rank: index)
            }

        return WindowAnalysis(parentID: deviceID, candidates: Array(ranked))
    }
}
