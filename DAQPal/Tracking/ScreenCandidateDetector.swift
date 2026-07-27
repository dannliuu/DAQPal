//
//  ScreenCandidateDetector.swift
//  DAQPal
//
//  Geometric screen-candidate detection (spec §5/§6, Phase 4).
//
//  The primary mechanism is deliberately NOT OCR: `VNDetectRectanglesRequest`
//  proposes quadrilaterals from edge structure alone, so a blanked or
//  unreadable display is still detectable. Text is a *secondary* signal that
//  discriminates an instrument readout from an arbitrary rectangle (a window, a
//  book, a monitor bezel) — which is exactly the balance `ScreenSignalWeights`
//  encodes.
//
//  Two costs shape the design:
//  1. Recognition runs ONCE over the whole frame, never per candidate. Per-
//     candidate recognition would multiply the most expensive Vision pass by
//     the number of proposals; instead each proposal is scored by which of the
//     frame's text observations fall inside it.
//  2. Both requests share a single `VNImageRequestHandler`, so the frame is
//     prepared once per detection pass.
//
//  Statefulness is why this is an actor: candidate identity and temporal
//  stability are accumulated across frames, and Vision request objects must not
//  be driven from two isolation domains at once.
//
//  Everything accumulated across frames is keyed on FRAME TIME, never on frame
//  count: capture rate varies with exposure and thermal state, and a detector
//  whose lock latency moves with it is not tunable.
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

actor ScreenCandidateDetector: ScreenDetecting {

    /// Detector knobs. Data rather than literals for the same reason
    /// `SnapTuning` is: every one of these is expected to move under
    /// measurement, and tests need to drive them directly.
    struct Tuning: Equatable, Sendable {
        var maximumAspectRatio: Float = 1.0
        /// Fraction of the smaller image dimension a proposal must span.
        var minimumSize: Float = 0.08
        var maximumObservations: Int = 12
        var minimumConfidence: VNConfidence = 0.4
        /// Degrees of deviation from 90° corners tolerated — a hand-held device
        /// almost never views a panel head-on.
        var quadratureTolerance: Float = 35

        /// Bounding-box IoU above which a new proposal is considered the same
        /// physical region as a previous one.
        var matchIoU: CGFloat = 0.5
        /// Frame-time seconds a previously seen candidate survives without a
        /// match before its identity is discarded.
        var historyTimeout: TimeInterval = 1.5
        /// Frame-time seconds of continuous observation at which temporal
        /// stability reaches 1. Frame time, not frame count: the same physical
        /// dwell must produce the same confidence at 12 fps and at 60 fps.
        /// 0.42 s reproduces the previous 5-observation default at the 12 fps
        /// the synthetic pipeline runs at.
        var stabilityRiseTime: TimeInterval = 0.42
        /// Frame-time seconds of continuous absence at which stability returns
        /// to 0. Symmetric with the rise by default, matching the one-step-up /
        /// one-step-down behaviour this replaced.
        var stabilityDecayTime: TimeInterval = 0.42
        /// Text observations inside a candidate at which text density saturates.
        var textSaturation: Int = 3
        /// Hard cap on remembered identities. Without it, panning across a
        /// cluttered bench accumulates `maximumObservations × fps ×
        /// historyTimeout` entries and the match loop grows with the mess in
        /// the room rather than with the number of proposals.
        var maximumHistory: Int = 48

        /// Lower edge of the "display-like" aspect band (width/height).
        var displayAspectLow: CGFloat = 1.5
        /// Upper edge of the "display-like" aspect band. Also fixes what the
        /// rectangle request is allowed to propose — see `minimumAspectRatio`.
        var displayAspectHigh: CGFloat = 6.0

        /// Vision defines rectangle aspect as short/long, so the request's
        /// LOWER bound is the reciprocal of the band's upper edge. Derived
        /// rather than stored: a hard-coded 0.2 here made Vision reject
        /// anything longer than 5:1 while `aspectRatioScore` still advertised a
        /// flat 1.0 out to 6:1, so the top of the band was unreachable and
        /// genuine multi-line / bar-graph readouts were dropped before scoring.
        /// Widening the request (rather than narrowing the band) is the choice
        /// that keeps real instrument geometry in play; the slivers it admits
        /// still have to clear `minimumSize`, `minimumConfidence` and
        /// `quadratureTolerance`.
        var minimumAspectRatio: Float {
            Float(1 / max(displayAspectHigh, 1))
        }

        static let `default` = Tuning()
    }

    /// One frame's recognized text run, reduced to what scoring needs.
    private struct TextRun {
        let center: CGPoint
        let confidence: Float
        let string: String
    }

    /// Axis-aligned extent of a quad, kept as four scalars so candidate
    /// matching — which is O(proposals × history) — does no allocation per
    /// comparison. `ScreenQuad.boundingBoxIoU` builds two corner arrays per
    /// call, which is fine once and wasteful in this loop.
    private struct Extent {
        let minX: CGFloat, minY: CGFloat, maxX: CGFloat, maxY: CGFloat

        init(_ quad: ScreenQuad) {
            let a = quad.topLeft, b = quad.topRight, c = quad.bottomRight, d = quad.bottomLeft
            minX = min(min(a.x, b.x), min(c.x, d.x))
            minY = min(min(a.y, b.y), min(c.y, d.y))
            maxX = max(max(a.x, b.x), max(c.x, d.x))
            maxY = max(max(a.y, b.y), max(c.y, d.y))
        }

        var area: CGFloat { max(0, maxX - minX) * max(0, maxY - minY) }

        func iou(_ other: Extent) -> CGFloat {
            let w = min(maxX, other.maxX) - max(minX, other.minX)
            let h = min(maxY, other.maxY) - max(minY, other.minY)
            guard w > 0, h > 0 else { return 0 }
            let intersection = w * h
            let union = area + other.area - intersection
            return union > 0 ? intersection / union : 0
        }
    }

    /// A candidate the detector has emitted before, kept only so identity,
    /// corner labeling and stability survive to the next pass.
    private struct Remembered {
        let id: UUID
        var quad: ScreenQuad
        var extent: Extent
        var observationCount: Int
        /// Accumulated dwell, 0...1, integrated over frame time.
        var stability: Float
        /// Frame time of the last MATCH — drives the identity timeout.
        var lastSeen: TimeInterval
        /// Frame time this entry was last advanced — drives rise/decay, which
        /// must integrate elapsed time exactly once regardless of how many
        /// passes the entry survives unmatched.
        var lastAdvanced: TimeInterval
    }

    /// One proposal's resolved identity, staged so history is written in a
    /// single step after the whole frame is scored.
    private struct Resolved {
        let id: UUID
        let quad: ScreenQuad
        let extent: Extent
        let observationCount: Int
        let stability: Float
    }

    private let weights: ScreenSignalWeights
    private let tuning: Tuning
    private let textRecognitionLevel: VNRequestTextRecognitionLevel
    private var history: [Remembered] = []
    /// Newest frame time whose result was written into `history`. Detection
    /// is reentrant (see `detect`), so a late frame can arrive after a newer
    /// one; applying it would push `lastSeen` backwards and leave entries with
    /// a negative age, which no timeout can ever prune.
    private var newestAppliedTimestamp: TimeInterval = -.infinity

    /// - Parameters:
    ///   - weights: signal fusion weights; injectable so tuning is testable.
    ///   - tuning: detector thresholds.
    ///   - textRecognitionLevel: `.fast` by default because this pass covers the
    ///     WHOLE frame and only needs to know where text is and roughly what it
    ///     says. Its confidences are systematically lower and far less spread
    ///     than `.accurate`'s (see `VisionOCR`), which is why nothing here
    ///     thresholds on an absolute confidence. Field-level reading is a
    ///     separate, ROI-scoped pass.
    init(weights: ScreenSignalWeights = .default,
         tuning: Tuning = .default,
         textRecognitionLevel: VNRequestTextRecognitionLevel = .fast) {
        self.weights = weights
        self.tuning = tuning
        self.textRecognitionLevel = textRecognitionLevel
    }

    // MARK: - ScreenDetecting

    /// Proposals for one frame, best-first.
    ///
    /// Intended for a single sequential caller (the capture pipeline drives one
    /// frame at a time). Actor entry is not FIFO, so overlapping calls can
    /// arrive in any order; rather than rely on the caller, a pass whose
    /// timestamp predates the newest applied one is scored normally but does
    /// NOT write history. Out-of-order frames therefore lose identity
    /// continuity for that frame instead of corrupting it for all later ones.
    func detect(in frame: TimestampedFrame) async -> [ScreenCandidate] {
        // Synchronous `measure`: the pass is synchronous Vision work, and the
        // async overload's suspension point was itself a reentrancy window.
        PipelineMetrics.shared.measure(.detection) {
            self.detectPass(frame)
        }
    }

    /// Forgets all candidate identities. Callers use this when the frame source
    /// changes, so stability cannot carry across an unrelated stream.
    func reset() {
        history.removeAll()
        newestAppliedTimestamp = -.infinity
    }

    // MARK: - Detection pass

    private func detectPass(_ frame: TimestampedFrame) -> [ScreenCandidate] {
        let timestamp = frame.timestamp
        let inOrder = timestamp >= newestAppliedTimestamp

        let rectangleRequest = VNDetectRectanglesRequest()
        rectangleRequest.minimumAspectRatio = tuning.minimumAspectRatio
        rectangleRequest.maximumAspectRatio = tuning.maximumAspectRatio
        rectangleRequest.minimumSize = tuning.minimumSize
        rectangleRequest.maximumObservations = tuning.maximumObservations
        rectangleRequest.minimumConfidence = tuning.minimumConfidence
        rectangleRequest.quadratureTolerance = tuning.quadratureTolerance

        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = textRecognitionLevel
        textRequest.usesLanguageCorrection = false
        textRequest.automaticallyDetectsLanguage = false
        textRequest.recognitionLanguages = ["en-US"]

        // Buffers reach this layer already upright, so the default `.up`
        // orientation is correct (same assumption as `VisionOCR`).
        let handler = VNImageRequestHandler(cvPixelBuffer: frame.pixelBuffer, options: [:])
        do {
            try handler.perform([rectangleRequest, textRequest])
        } catch {
            // Never break the frame loop: a Vision failure is "nothing found".
            if inOrder { applyHistory([], matched: [], at: timestamp) }
            return []
        }

        let rectangles = rectangleRequest.results ?? []
        let runs = Self.textRuns(from: textRequest.results ?? [])
        let totalTextConfidence = runs.reduce(Float(0)) { $0 + $1.confidence }

        var matched = [Bool](repeating: false, count: history.count)
        var resolved: [Resolved] = []
        resolved.reserveCapacity(rectangles.count)
        var candidates: [ScreenCandidate] = []
        candidates.reserveCapacity(rectangles.count)

        for observation in rectangles {
            let proposal = Self.quad(from: observation)
            guard proposal.isConvex else { continue }
            let extent = Extent(proposal)

            // Matching is bounding-box based, so it is independent of how the
            // corners happen to be labeled — which is what lets the labeling
            // be decided AFTER the match, from the matched entry.
            let matchIndex = bestMatchIndex(for: extent, matched: matched)

            let quad: ScreenQuad
            let id: UUID
            let observationCount: Int
            let stability: Float
            if let matchIndex {
                let previous = history[matchIndex]
                matched[matchIndex] = true
                quad = Self.continuousLabeling(of: proposal, matching: previous.quad)
                id = previous.id
                observationCount = previous.observationCount + 1
                stability = Self.risenStability(previous.stability,
                                                elapsed: min(timestamp - previous.lastAdvanced,
                                                             tuning.historyTimeout),
                                                riseTime: tuning.stabilityRiseTime)
            } else {
                // No history to be continuous with, so labeling is decided from
                // the quad's own SHAPE — never from where it sits in the frame.
                quad = Self.uprightLabeling(of: proposal)
                id = UUID()
                observationCount = 1
                stability = 0
            }

            var signals = ScreenSignals.zero
            signals.geometry = min(max(observation.confidence, 0), 1)
            signals.aspectRatio = Self.aspectRatioScore(quad.aspectRatio,
                                                        low: tuning.displayAspectLow,
                                                        high: tuning.displayAspectHigh)
            let textual = Self.textSignals(for: quad,
                                           runs: runs,
                                           totalConfidence: totalTextConfidence,
                                           saturation: tuning.textSaturation)
            signals.text = textual.text
            signals.numeric = textual.numeric
            signals.temporalStability = stability

            resolved.append(Resolved(id: id,
                                     quad: quad,
                                     extent: extent,
                                     observationCount: observationCount,
                                     stability: stability))
            candidates.append(ScreenCandidate(id: id,
                                              quad: quad,
                                              signals: signals,
                                              confidence: weights.fuse(signals),
                                              observationCount: observationCount,
                                              lastSeen: timestamp))
        }

        candidates.sort { $0.confidence > $1.confidence }
        if inOrder { applyHistory(resolved, matched: matched, at: timestamp) }
        return candidates
    }

    // MARK: - Candidate identity

    /// Index of the best unclaimed history entry overlapping `extent`, or nil.
    /// Scalar arithmetic only — no allocation per comparison.
    private func bestMatchIndex(for extent: Extent, matched: [Bool]) -> Int? {
        var best: Int?
        var bestIoU = tuning.matchIoU
        for index in history.indices where !matched[index] {
            let iou = extent.iou(history[index].extent)
            if iou > bestIoU {
                bestIoU = iou
                best = index
            }
        }
        return best
    }

    private func applyHistory(_ resolved: [Resolved], matched: [Bool], at timestamp: TimeInterval) {
        var next: [Remembered] = []
        next.reserveCapacity(history.count + resolved.count)
        // Unmatched entries decay rather than vanishing: a candidate that
        // flickers out for a frame should not restart its stability from zero,
        // but it must not keep the stability it earned either.
        for (index, entry) in history.enumerated() where index >= matched.count || !matched[index] {
            guard timestamp - entry.lastSeen <= tuning.historyTimeout else { continue }
            var decayed = entry
            decayed.stability = Self.decayedStability(entry.stability,
                                                      elapsed: min(timestamp - entry.lastAdvanced,
                                                                   tuning.historyTimeout),
                                                      decayTime: tuning.stabilityDecayTime)
            decayed.observationCount = max(1, entry.observationCount - 1)
            decayed.lastAdvanced = timestamp
            next.append(decayed)
        }
        for entry in resolved {
            next.append(Remembered(id: entry.id,
                                   quad: entry.quad,
                                   extent: entry.extent,
                                   observationCount: entry.observationCount,
                                   stability: entry.stability,
                                   lastSeen: timestamp,
                                   lastAdvanced: timestamp))
        }
        let cap = max(1, tuning.maximumHistory)
        if next.count > cap {
            // Least-recently-seen first: this frame's own proposals all carry
            // `timestamp`, so they are never the ones dropped.
            next.sort { $0.lastSeen > $1.lastSeen }
            next.removeLast(next.count - cap)
        }
        history = next
        newestAppliedTimestamp = timestamp
    }

    // MARK: - Pure scoring helpers

    /// How display-like an aspect ratio (width/height) is: 1 inside the band
    /// instrument readouts typically occupy, falling off linearly outside it.
    /// The band edges are a starting point from the spec, not a measured
    /// distribution.
    nonisolated static func aspectRatioScore(_ aspectRatio: CGFloat,
                                             low: CGFloat = Tuning.default.displayAspectLow,
                                             high: CGFloat = Tuning.default.displayAspectHigh) -> Float {
        guard aspectRatio.isFinite, aspectRatio > 0, low > 0, high >= low else { return 0 }
        if aspectRatio >= low && aspectRatio <= high { return 1 }
        if aspectRatio < low {
            // Reaches 0 at a third of the band's lower edge (a tall portrait
            // region is not a readout).
            let floorValue = low / 3
            guard aspectRatio > floorValue else { return 0 }
            return Float((aspectRatio - floorValue) / (low - floorValue))
        }
        // Reaches 0 at twice the band's upper edge (a letterbox sliver is not a
        // readout either).
        let ceilingValue = high * 2
        guard aspectRatio < ceilingValue else { return 0 }
        return Float((ceilingValue - aspectRatio) / (ceilingValue - high))
    }

    /// Fraction of `strings` that parse as a number under the unconstrained
    /// (Mode 3) grammar, blended with the digit density of their characters.
    /// Both halves matter: "12.345" and "V" both parse-or-not cleanly, but
    /// "CH1 12.345 V" is more numeric-looking than "HOLD AUTO".
    nonisolated static func numericScore(for strings: [String]) -> Float {
        guard !strings.isEmpty else { return 0 }
        var parsed = 0
        var digits = 0
        var characters = 0
        for string in strings {
            if case .valid = FormatValidator.value(from: string, format: .unconstrained) {
                parsed += 1
            }
            for character in string where !character.isWhitespace {
                characters += 1
                if character.isNumber { digits += 1 }
            }
        }
        let parseFraction = Float(parsed) / Float(strings.count)
        let digitFraction = characters > 0 ? Float(digits) / Float(characters) : 0
        return min(max(0.6 * parseFraction + 0.4 * digitFraction, 0), 1)
    }

    /// Temporal stability after `elapsed` seconds of continued observation.
    ///
    /// Integrated over FRAME TIME, never over frame count: capture rate moves
    /// with exposure and thermal state, and a stability that counted frames
    /// would hand the same physical dwell a different confidence — and so a
    /// different lock latency — at 12 fps than at 60 fps. Negative elapsed
    /// (an out-of-order frame) contributes nothing rather than unwinding
    /// stability already earned.
    nonisolated static func risenStability(_ previous: Float,
                                           elapsed: TimeInterval,
                                           riseTime: TimeInterval = Tuning.default.stabilityRiseTime) -> Float {
        guard riseTime > 0, elapsed.isFinite else { return min(max(previous, 0), 1) }
        let gain = Float(max(elapsed, 0) / riseTime)
        return min(1, max(0, previous) + gain)
    }

    /// Temporal stability after `elapsed` seconds without a match. The mirror
    /// of `risenStability`: a candidate that flickers out for a frame should
    /// not restart from zero, but must not keep what it earned either.
    nonisolated static func decayedStability(_ previous: Float,
                                             elapsed: TimeInterval,
                                             decayTime: TimeInterval = Tuning.default.stabilityDecayTime) -> Float {
        guard decayTime > 0, elapsed.isFinite else { return min(max(previous, 0), 1) }
        let loss = Float(max(elapsed, 0) / decayTime)
        return max(0, min(1, previous) - loss)
    }

    /// Convex point-in-quad test by consistent edge sign; winding-agnostic, so
    /// it does not care which order the corners arrived in.
    ///
    /// Non-finite input is rejected outright: every comparison against NaN is
    /// false, so a NaN point would set neither sign and fall through as
    /// "inside every candidate".
    nonisolated static func quadContains(_ quad: ScreenQuad, _ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let a = quad.topLeft, b = quad.topRight, c = quad.bottomRight, d = quad.bottomLeft
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite,
              c.x.isFinite, c.y.isFinite, d.x.isFinite, d.y.isFinite else { return false }

        var positive = false
        var negative = false
        func straddles(_ u: CGPoint, _ v: CGPoint) -> Bool {
            let cross = (v.x - u.x) * (point.y - u.y) - (v.y - u.y) * (point.x - u.x)
            if cross > 1e-12 { positive = true }
            if cross < -1e-12 { negative = true }
            return positive && negative
        }
        if straddles(a, b) { return false }
        if straddles(b, c) { return false }
        if straddles(c, d) { return false }
        if straddles(d, a) { return false }
        return true
    }

    /// Relabels `proposal` to the cyclic corner rotation closest to `previous`.
    ///
    /// Corner names in `ScreenQuad` are semantic, not positional, and canonical
    /// field coordinates depend on a given label staying glued to the same
    /// physical corner. Re-deriving labels from frame position every frame
    /// (`normalizedCornerOrder`) cannot do that: its anchor is
    /// `argmin(x² + y²)`, which for an off-centre or wide panel switches
    /// corners under sub-degree roll jitter and rotates every label a quarter
    /// turn on alternating frames. Continuity is the property that actually
    /// matters, so once a candidate has a history the labeling is chosen to
    /// minimise mean corner distance to its previous quad instead.
    ///
    /// Only the four cyclic rotations are considered — they are the relabelings
    /// that preserve winding, so a convex quad stays convex and the homography
    /// stays orientation-preserving.
    nonisolated static func continuousLabeling(of proposal: ScreenQuad,
                                               matching previous: ScreenQuad) -> ScreenQuad {
        let p = proposal.corners
        let q = previous.corners
        var bestShift = 0
        var bestCost = CGFloat.infinity
        for shift in 0..<4 {
            var cost: CGFloat = 0
            for i in 0..<4 {
                cost += ScreenQuad.distance(p[(i + shift) % 4], q[i])
            }
            if cost < bestCost {
                bestCost = cost
                bestShift = shift
            }
        }
        return Self.rotatedLabels(of: proposal, by: bestShift)
    }

    /// Labels a quad that has NO history, from the quad's own shape alone.
    ///
    /// This is the first observation of a candidate; `continuousLabeling` takes
    /// over from the second onwards. Getting it wrong is not a transient
    /// cosmetic problem, because the labeling chosen here is what every later
    /// frame is made continuous *with*: a first frame labeled a quarter turn off
    /// stays a quarter turn off for the candidate's whole life.
    ///
    /// `ScreenQuad.aspectRatio` is `meanWidth / meanHeight` over the LABELED
    /// edges, so a quarter-turn-off labeling reports a 4:1 readout as 1:4,
    /// `aspectRatioScore` returns ~0 for it permanently, and fused confidence
    /// can never reach `enterLock`. That is the whole reason this is
    /// shape-derived: the previous anchor (`normalizedCornerOrder`, which picks
    /// the corner minimising x² + y²) depends on where the display sits in the
    /// frame and at what roll it was first seen, so whether a given display was
    /// ever lockable depended on the angle it happened to be caught at.
    ///
    /// Two shape properties decide it, in order:
    /// 1. The longer pair of opposite edges becomes the top/bottom pair. Since
    ///    `meanWidth` averages exactly that pair and `meanHeight` the other,
    ///    this makes the reported aspect ratio the quad's true long:short ratio
    ///    at every roll — a 4:1 panel reads 4:1 upright, on its side, or upside
    ///    down.
    /// 2. Of the two rotations satisfying (1) — they differ by a half turn —
    ///    the one whose top edge points closest to frame-right wins, so an
    ///    upright display is also labeled upright rather than inverted.
    ///
    /// Ties (a square, or a panel rolled exactly 90°) are broken deterministically
    /// rather than left to floating-point noise: the edge pointing more towards
    /// the top of the frame first, then the lower rotation index. Both branches
    /// of a tie describe the same physical quad with the same aspect ratio; only
    /// reproducibility is at stake.
    ///
    /// Only the four cyclic rotations are considered, for the same reason as in
    /// `continuousLabeling`: they preserve winding, so a convex quad stays
    /// convex and the homography stays orientation-preserving.
    nonisolated static func uprightLabeling(of proposal: ScreenQuad) -> ScreenQuad {
        let p = proposal.corners
        for corner in p where !corner.x.isFinite || !corner.y.isFinite { return proposal }

        // Edge `i` runs from corner `i` to corner `i + 1`; rotating labels by
        // `i` makes it the top edge.
        var dx = [CGFloat](repeating: 0, count: 4)
        var dy = [CGFloat](repeating: 0, count: 4)
        var length = [CGFloat](repeating: 0, count: 4)
        for i in 0..<4 {
            let next = p[(i + 1) % 4]
            dx[i] = next.x - p[i].x
            dy[i] = next.y - p[i].y
            length[i] = (dx[i] * dx[i] + dy[i] * dy[i]).squareRoot()
        }

        // Step 1: the longer opposite pair. `meanWidth` is the mean of edges
        // 0 and 2 under a given labeling, `meanHeight` the mean of 1 and 3, so
        // comparing the sums is exactly comparing the two candidate aspect
        // ratios' numerator and denominator.
        let shifts = (length[1] + length[3]) > (length[0] + length[2]) ? [1, 3] : [0, 2]

        // Step 2: of those two, the top edge closest to pointing frame-right.
        var bestShift = shifts[0]
        var bestAngle = CGFloat.infinity
        var bestDy = CGFloat.infinity
        for shift in shifts {
            let angle = abs(atan2(dy[shift], dx[shift]))
            let tied = abs(angle - bestAngle) <= 1e-12
            if angle < bestAngle - 1e-12 || (tied && dy[shift] < bestDy - 1e-12) {
                bestAngle = angle
                bestDy = dy[shift]
                bestShift = shift
            }
        }
        return rotatedLabels(of: proposal, by: bestShift)
    }

    /// Cyclically rotates a quad's corner labels by `shift` positions.
    private nonisolated static func rotatedLabels(of quad: ScreenQuad, by shift: Int) -> ScreenQuad {
        guard shift % 4 != 0 else { return quad }
        let p = quad.corners
        return ScreenQuad(topLeft: p[shift % 4],
                          topRight: p[(shift + 1) % 4],
                          bottomRight: p[(shift + 2) % 4],
                          bottomLeft: p[(shift + 3) % 4])
    }

    /// Vision reports rectangle corners in BOTTOM-LEFT normalized space; the
    /// project convention is TOP-LEFT (see `NormalizedROI`). Flipping y is the
    /// whole conversion — the corner *labels* stay semantically correct because
    /// Vision names them in its own origin's terms, so its `topLeft` is still
    /// the visually upper-left corner. The flip does reverse the winding
    /// direction, which is harmless: every `ScreenQuad` consumer is
    /// winding-agnostic, and both sides of a `continuousLabeling` comparison
    /// have been through the same flip.
    nonisolated static func quad(from observation: VNRectangleObservation) -> ScreenQuad {
        func convert(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        return ScreenQuad(topLeft: convert(observation.topLeft),
                          topRight: convert(observation.topRight),
                          bottomRight: convert(observation.bottomRight),
                          bottomLeft: convert(observation.bottomLeft))
    }

    // MARK: - Text scoring

    private nonisolated static func textRuns(from observations: [VNRecognizedTextObservation]) -> [TextRun] {
        observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Same bottom-left → top-left conversion as the corner mapping.
            let center = CGPoint(x: box.midX, y: 1 - box.midY)
            return TextRun(center: center,
                           confidence: min(max(candidate.confidence, 0), 1),
                           string: candidate.string)
        }
    }

    /// Text evidence for one candidate.
    ///
    /// `text` blends two differently normalized counts, NOT two independent
    /// kinds of evidence:
    /// - `share` — this region's slice of the frame's total recognition
    ///   confidence, i.e. how much of the frame's text it captures relative to
    ///   everything else on screen.
    /// - `density` — how many runs it holds in absolute terms, so a display is
    ///   not rewarded for holding the only stray word in an otherwise empty
    ///   frame.
    ///
    /// The confidence weighting in `share` only carries information at
    /// `.accurate`. At the default `.fast` level, per-run confidences are
    /// clustered tightly enough that `share` reduces in practice to the
    /// region's fraction of the frame's text RUNS — still a competitive
    /// measure, and still distinct from `density`'s absolute count, but not a
    /// confidence signal. Nothing downstream should read it as one.
    private nonisolated static func textSignals(for quad: ScreenQuad,
                                                runs: [TextRun],
                                                totalConfidence: Float,
                                                saturation: Int) -> (text: Float, numeric: Float) {
        guard !runs.isEmpty else { return (0, 0) }
        var insideConfidence: Float = 0
        var insideStrings: [String] = []
        for run in runs where quadContains(quad, run.center) {
            insideConfidence += run.confidence
            insideStrings.append(run.string)
        }
        guard !insideStrings.isEmpty else { return (0, 0) }

        let share = totalConfidence > 0 ? insideConfidence / totalConfidence : 0
        let density = min(1, Float(insideStrings.count) / Float(max(1, saturation)))
        let text = min(max(0.6 * share + 0.4 * density, 0), 1)
        return (text, numericScore(for: insideStrings))
    }
}
