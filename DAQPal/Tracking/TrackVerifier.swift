//
//  TrackVerifier.swift
//  DAQPal
//
//  Independent geometric verification of a tracked lock (remediation plan
//  Phases 7–8). This is the mechanism that closes the project's standing
//  data-integrity blocker:
//
//      Fast motion → tracker loses correspondence → tracked quad leaves the
//      display → tracker still reports healthy → UI stays LOCKED → OCR keeps
//      producing values from empty background.
//
//  The defect was observed live (ARCHITECTURE.md §9): under
//  `-daqpal-demo-motion bounce` the tracked quad sat over background with
//  healthy confidence while the detector was correctly re-proposing the real
//  panel at 94% elsewhere. The tracker's own confidence CANNOT detect this
//  failure class — it measures frame-to-frame consistency, and a tracker that
//  has drifted onto static background is perfectly consistent frame to frame.
//
//  The only independent evidence available is the DETECTOR, which periodically
//  re-finds displays from scratch. This type compares each detection pass
//  against the tracked geometry and issues one of three verdicts:
//
//    CORROBORATED — a candidate overlaps the tracked quad. The lock is
//                   attached to something the detector independently believes
//                   is a display. Strikes reset.
//    DIVERGED     — no candidate near the tracked quad, AND a confident
//                   candidate exists elsewhere. The detector can see a display;
//                   it is not where the tracker says. This is the drift
//                   signature and it is a HARD VETO: no aggregate confidence
//                   may override it (plan Phase 7, "do not allow a weighted
//                   average to hide a catastrophic failure").
//    UNSUPPORTED  — the detector found nothing near the tracked quad and
//                   nothing confident elsewhere (occlusion, glare, the display
//                   turned off). One pass is not proof — a single missed
//                   detection is common — so unsupported passes accumulate
//                   STRIKES, and only sustained absence degrades the lock.
//
//  Deliberately NOT part of the verdict: the tracker's own confidence. The
//  entire point is independence — feeding the tracker's self-assessment back
//  in would recreate the circularity this exists to break.
//
//  Pure value type, deterministic, no Date(): timestamps come from frames.
//

import CoreGraphics
import Foundation

/// Verdict of one independent verification pass, plus the sustained state the
/// caller acts on.
struct TrackVerifier: Sendable, Equatable {

    /// Feature toggles for the v2 hardening (the two mechanisms that close
    /// the §11 live failure, plus corner-level agreement). Each is
    /// independent so the benchmark can attribute reliability to individual
    /// mechanisms; `Config.v1` (all off) reproduces the original v1 verdict
    /// logic exactly and exists as the benchmark baseline and for the
    /// regression-documenting tests.
    struct Config: Sendable, Equatable {
        /// Corroboration requires corner-level geometric agreement with the
        /// tracked quad (mean corner distance ≤ `cornerAgreementFraction` of
        /// its mean edge length), not merely bbox-IoU/center overlap. A
        /// witness that overlaps but disagrees at the corners is AMBIGUOUS:
        /// it strikes (degrades), it never blesses, and it never vetoes.
        var cornerLevelAgreement: Bool
        /// Divergence needs less confidence than corroboration: a candidate
        /// the detector keeps re-proposing (temporal stability) may testify
        /// at `persistentTestimonyConfidence` instead of
        /// `testimonyConfidence` — the measured 40–42% blur-gap fix.
        var asymmetricTestimony: Bool
        /// Corroboration only counts when the witness moves WITH the tracked
        /// quad — overlap while moving independently is `.transit`, a hard
        /// veto (the sweep-through fix).
        var motionConsistentCorroboration: Bool

        init(cornerLevelAgreement: Bool = true,
             asymmetricTestimony: Bool = true,
             motionConsistentCorroboration: Bool = true) {
            self.cornerLevelAgreement = cornerLevelAgreement
            self.asymmetricTestimony = asymmetricTestimony
            self.motionConsistentCorroboration = motionConsistentCorroboration
        }

        /// All hardening on — the shipping default.
        static let v2 = Config()
        /// All hardening off — the v1 verdict logic, byte for byte.
        static let v1 = Config(cornerLevelAgreement: false,
                               asymmetricTestimony: false,
                               motionConsistentCorroboration: false)
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    enum Verdict: Equatable, Sendable {
        /// The detector independently sees a display where the tracker says,
        /// AND its motion is coupled to the tracked geometry.
        case corroborated
        /// The detector sees a display, but NOT where the tracker says —
        /// the drift signature. Hard veto.
        case diverged(strongestElsewhere: CGFloat)
        /// A display OVERLAPS the tracked quad but is moving independently of
        /// it — a moving display sweeping THROUGH a parked, drifted lock.
        /// `relativeMotion` is a RATE in normalized units per second.
        /// Observed live: a quad drifted onto the bounce path was
        /// re-corroborated every ~1.5 s by the panel itself passing through,
        /// which kept a dead lock alive indefinitely. Transit is evidence of
        /// drift, not of attachment, and is a hard veto like `diverged`.
        case transit(relativeMotion: CGFloat)
        /// The detector sees nothing conclusive anywhere; strike accumulated.
        case unsupported(consecutiveStrikes: Int)
    }

    // MARK: Tunables

    /// A candidate whose bounding box IoU with the tracked quad is at or above
    /// this corroborates the lock. Low bar deliberately: the detector and
    /// tracker legitimately disagree about exact corners, and this check asks
    /// "same physical display?", not "same pixels?".
    var corroborationIoU: CGFloat = 0.30
    /// A candidate may also corroborate by center distance, scaled by the
    /// tracked quad's SHORTER dimension — catches the case where IoU collapses
    /// because the detector proposes a tighter crop of the same display, whose
    /// center barely moves.
    ///
    /// Scaled by the SHORTER side deliberately. Scaling by the longer side is
    /// a veto escape: an instrument panel is wide and short (the synthetic rig
    /// is 0.76 x 0.13 normalized), so `0.75 x max(...)` allowed a corroborating
    /// center up to 0.57 normalized units away — more than half the frame. A
    /// quad could sit completely off the display and still be "corroborated"
    /// by it. Against the shorter side the same factor allows ~0.10, which is
    /// the scale at which two boxes are plausibly the same physical display.
    var corroborationCenterFactor: CGFloat = 0.75
    /// Only candidates at or above this fused confidence can testify — in
    /// EITHER direction. A weak far-away candidate cannot veto a lock, and a
    /// weak nearby one cannot corroborate it.
    var testimonyConfidence: Float = 0.60
    /// A candidate the detector has re-proposed persistently may testify at a
    /// lower confidence bar. Measured live: a display under fast motion
    /// re-proposes at 40–42% fused confidence (motion blur drags the score),
    /// which sat below `testimonyConfidence` and left DIVERGED unable to fire
    /// while the lock was demonstrably on background. Temporal persistence is
    /// exactly the evidence that separates a real-but-blurred display from a
    /// one-frame phantom, so persistence buys back what blur took away.
    var persistentTestimonyConfidence: Float = 0.40
    /// Temporal stability a candidate needs for the reduced bar to apply.
    var persistentTestimonyStability: Float = 0.5
    /// Corroboration is only attachment if the candidate and the tracked quad
    /// MOVE TOGETHER. Expressed as a RATE (normalized units per second) of
    /// relative motion, not a raw per-pass displacement.
    ///
    /// Rate, not displacement, because detection passes are NOT uniformly
    /// spaced: the nominal revalidation interval is 0.5 s but a delayed pass
    /// can be up to `couplingMemoryMaxAge` (1.6 s) old and is still used. A
    /// fixed displacement bound therefore scales the effective strictness with
    /// scheduling jitter — the same physical speed reads as 3x the motion
    /// after a 1.5 s gap, false-vetoing a legitimately tracked display. That
    /// would be a worse defect than the drift it guards against.
    ///
    /// Sized against the rig: bounce translates ~0.11 normalized/s while a
    /// drifted quad is static, so a sweep-through shows ~0.11/s relative;
    /// detector corner jitter on an attached lock measures well under 0.03/s.
    var motionCouplingRate: CGFloat = 0.07
    /// Corner-level agreement (`config.cornerLevelAgreement`): a witness only
    /// corroborates when its mean corner distance to the tracked quad is at
    /// most this fraction of the tracked quad's mean edge length. Overlap
    /// with corner disagreement beyond it is ambiguous — strike, never veto.
    var cornerAgreementFraction: CGFloat = 0.35
    /// Consecutive unsupported passes before the lock is considered
    /// unverified. One missed detection is noise; several in a row on a
    /// detector that runs every revalidation interval is a real absence.
    var strikesToUnverified: Int = 3

    // MARK: State

    private(set) var consecutiveUnsupported = 0
    /// Timestamp of the last pass that corroborated the lock.
    private(set) var lastCorroboratedAt: TimeInterval?
    /// True once a divergence (or transit) has been seen and not yet cleared
    /// by a coupled, corroborated relock. Sticky by design: a dead lock stays
    /// invalid until independent evidence says otherwise, not until the
    /// tracker feels better.
    private(set) var isDiverged = false

    /// The previous pass's corroborating observation, for motion coupling.
    ///
    /// Deliberately carries NO candidate id. The first coupling implementation
    /// required the same id on consecutive passes, and live evidence showed
    /// fast motion destroys id stability — the detector's IoU matching fails
    /// between passes on a fast mover, so the panel arrives with a fresh id
    /// almost every pass, every sweep-through registered as a first sighting,
    /// and the transit veto never engaged. Any witness overlapping the tracked
    /// quad is claiming to BE our display; its motion owes consistency with
    /// ours no matter what id the detector minted for it this pass.
    private struct CorroborationMemory: Equatable {
        var witnessCenter: CGPoint
        var trackedCenter: CGPoint
        var timestamp: TimeInterval
    }
    private var lastCorroboration: CorroborationMemory?
    /// Coupling is only evaluated against a sufficiently RECENT memory —
    /// comparing against a witness from long ago would measure legitimate
    /// slow travel as transit. ~3 revalidation passes at the 0.5 s cadence.
    var couplingMemoryMaxAge: TimeInterval = 1.6

    /// Evaluates one detection pass against the tracked geometry.
    ///
    /// Call ONLY on frames where the detector actually ran — feeding it
    /// carried-forward candidates would double-count a single observation.
    mutating func evaluate(tracked: ScreenQuad,
                           candidates: [ScreenCandidate],
                           timestamp: TimeInterval) -> Verdict {
        // Persistence buys back the confidence that motion blur takes away:
        // a candidate the detector keeps re-proposing may testify at the
        // reduced bar. Measured live, a fast-moving display re-proposes at
        // 40–42% — real, just blurred — while one-frame phantoms do not
        // accumulate stability.
        let testimony = candidates.filter {
            $0.confidence >= testimonyConfidence
                || (config.asymmetricTestimony
                    && $0.confidence >= persistentTestimonyConfidence
                    && $0.signals.temporalStability >= persistentTestimonyStability)
        }

        if let witness = testimony.first(where: { corroborates($0.quad, tracked: tracked) }) {
            // Overlap alone is NOT attachment. If the same candidate overlapped
            // on the previous pass too, compare how far IT moved against how
            // far the TRACKED quad moved: an attached lock moves with its
            // display; a parked, drifted lock being swept through by a moving
            // display shows large relative motion. This is the exact live
            // failure the first verifier version missed — the bouncing panel
            // re-corroborated a dead lock every time it passed through it.
            defer {
                lastCorroboration = CorroborationMemory(witnessCenter: witness.quad.center,
                                                        trackedCenter: tracked.center,
                                                        timestamp: timestamp)
            }
            if config.motionConsistentCorroboration,
               let previous = lastCorroboration,
               timestamp - previous.timestamp <= couplingMemoryMaxAge,
               timestamp > previous.timestamp {
                let witnessMotion = CGVector(dx: witness.quad.center.x - previous.witnessCenter.x,
                                             dy: witness.quad.center.y - previous.witnessCenter.y)
                let trackedMotion = CGVector(dx: tracked.center.x - previous.trackedCenter.x,
                                             dy: tracked.center.y - previous.trackedCenter.y)
                let relative = hypot(witnessMotion.dx - trackedMotion.dx,
                                     witnessMotion.dy - trackedMotion.dy)
                // Per-second rate, so scheduling jitter cannot masquerade as
                // motion. `dt` is guaranteed positive by the guard above.
                let dt = timestamp - previous.timestamp
                let rate = relative / CGFloat(dt)
                if rate > motionCouplingRate {
                    consecutiveUnsupported = 0
                    isDiverged = true
                    return .transit(relativeMotion: rate)
                }
            }
            // Corner-level agreement: overlap is necessary but not
            // sufficient. A witness whose corners disagree with the tracked
            // corners (a much tighter/looser crop, or the early edge of a
            // drift) is ambiguous evidence — it neither blesses the lock nor
            // vetoes it, it strikes. Sustained ambiguity degrades through the
            // normal strike path; a single pass of it is noise.
            if config.cornerLevelAgreement, !cornersAgree(witness.quad, tracked: tracked) {
                consecutiveUnsupported += 1
                return .unsupported(consecutiveStrikes: consecutiveUnsupported)
            }
            consecutiveUnsupported = 0
            isDiverged = false
            lastCorroboratedAt = timestamp
            return .corroborated
        }

        if let strongest = testimony.max(by: { $0.confidence < $1.confidence }) {
            // The detector CAN see a display right now — just not where the
            // tracker claims one is. That asymmetry is what distinguishes
            // drift from occlusion.
            consecutiveUnsupported = 0
            isDiverged = true
            return .diverged(strongestElsewhere: CGFloat(strongest.confidence))
        }

        consecutiveUnsupported += 1
        return .unsupported(consecutiveStrikes: consecutiveUnsupported)
    }

    /// True while the lock has no standing independent verification — either a
    /// divergence is unresolved, or the detector has failed to corroborate for
    /// `strikesToUnverified` consecutive passes.
    var isUnverified: Bool {
        isDiverged || consecutiveUnsupported >= strikesToUnverified
    }

    /// Resets for a new lock. A fresh lock starts VERIFIED — it was just
    /// created from a detector candidate, which is itself the independent
    /// evidence.
    mutating func beginLock(at timestamp: TimeInterval) {
        consecutiveUnsupported = 0
        isDiverged = false
        lastCorroboratedAt = timestamp
        lastCorroboration = nil
    }

    mutating func reset() {
        consecutiveUnsupported = 0
        isDiverged = false
        lastCorroboratedAt = nil
        lastCorroboration = nil
    }

    private func corroborates(_ candidate: ScreenQuad, tracked: ScreenQuad) -> Bool {
        if candidate.boundingBoxIoU(with: tracked) >= corroborationIoU { return true }
        let allowed = corroborationCenterFactor * min(tracked.meanWidth, tracked.meanHeight)
        return ScreenQuad.distance(candidate.center, tracked.center) <= allowed
    }

    /// Corner-level agreement gate (`config.cornerLevelAgreement`).
    /// Corner agreement, evaluated CONCENTRICALLY so that scale alone cannot
    /// fail it.
    ///
    /// Raw `meanCornerDistance` conflates two very different things: a
    /// concentric tighter crop of the SAME display (the detector routinely
    /// proposes one, and the center-distance corroboration path exists
    /// precisely to accept it) and a box whose corners are genuinely
    /// elsewhere. Measuring raw corner distance struck the former, which turns
    /// a healthy lock into accumulating strikes — a false veto, the worst
    /// regression class here, and it broke
    /// `testTighterCropOfSameDisplayCorroboratesByCenterDistance`.
    ///
    /// So: normalize the candidate about the tracked quad's centre to the
    /// tracked quad's scale, then compare corners. A concentric crop of any
    /// size but similar SHAPE agrees; a box that is skewed, rotated away, or
    /// offset does not — which is the discrimination the gate was added for.
    private func cornersAgree(_ candidate: ScreenQuad, tracked: ScreenQuad) -> Bool {
        let scale = (tracked.meanWidth + tracked.meanHeight) / 2
        let candidateScale = (candidate.meanWidth + candidate.meanHeight) / 2
        guard scale > 1e-9, candidateScale > 1e-9 else { return false }

        // Scale the candidate about the tracked centre so pure size
        // differences cancel; what remains is shape and orientation.
        let ratio = scale / candidateScale
        let c = tracked.center
        func normalize(_ p: CGPoint) -> CGPoint {
            CGPoint(x: c.x + (p.x - candidate.center.x) * ratio,
                    y: c.y + (p.y - candidate.center.y) * ratio)
        }
        let normalized = ScreenQuad(topLeft: normalize(candidate.topLeft),
                                    topRight: normalize(candidate.topRight),
                                    bottomRight: normalize(candidate.bottomRight),
                                    bottomLeft: normalize(candidate.bottomLeft))
        return tracked.meanCornerDistance(to: normalized) <= cornerAgreementFraction * scale
    }
}
