//
//  MagneticSnapEngine.swift
//  DAQPal
//
//  The magnetic acquisition state machine (spec §5–§7): how a user's selection
//  window is drawn toward a detected display, and when that pull commits to a
//  lock.
//
//  Deliberately pure. No Vision, no pixel buffers, no async, no clock — every
//  input is an argument and every output is a return value. Acquisition policy
//  is where hysteresis, timeout and target-switching bugs hide, and none of
//  those are reachable from a test if the policy is entangled with a capture
//  session. All timing comes from the frame timestamp the caller passes in;
//  `Date()` would make the machine untestable and would drift from the frames
//  it is reasoning about.
//
//  The engine owns *policy* only. It never holds geometry the caller owns: once
//  locked, the quad it reports is the one it was handed (the tracker's), so
//  there is exactly one source of truth for a tracked target's outline.
//
//  The machine is driven at frame rate but detection is not: tracking is cheap
//  and runs often, detection is expensive and runs rarely (spec §9). Every
//  policy decision here therefore has to survive frames with no fresh detector
//  output, which is why `update` distinguishes "the detector did not run" from
//  "the detector found nothing" and why an engagement outlives a short absence.
//

import CoreGraphics
import Foundation

/// One frame's decision from `MagneticSnapEngine`.
struct SnapOutcome: Equatable, Sendable {
    /// State after this frame; always equal to the engine's `state`.
    var state: SnapState
    /// Where the selection window should be drawn this frame.
    var quad: ScreenQuad
    /// True on the single frame a lock commits — the caller's cue to start the
    /// tracker on `lockedCandidate`.
    var didLock: Bool
    /// True on the single frame the machine falls back to `.manual`.
    var didRelease: Bool
    /// The candidate that was locked; non-nil only on the committing frame.
    ///
    /// Its `id` is always `state.targetID`. That is not automatic on a
    /// detector-driven relock out of `.reacquisition`, where the detector
    /// proposes a *fresh* candidate with a new id: the engine re-stamps that
    /// proposal with the existing target id before returning it, so a caller
    /// keyed on `lockedCandidate.id` (a field catalog, say) keeps addressing the
    /// same target across a dropout instead of orphaning what it stored.
    var lockedCandidate: ScreenCandidate?
    /// The candidate currently in play, if any.
    var engagedCandidate: ScreenCandidate?
    /// Mean corner distance from the incoming selection to the candidate this
    /// outcome is about — `engagedCandidate`, or `lockedCandidate` on a
    /// committing frame. Nil whenever there is no such candidate, so it is
    /// always nil in `.manual`.
    var alignmentDistance: CGFloat?
    /// Consecutive qualifying frames accumulated toward a lock.
    var lockProgress: Int
}

/// Drives a selection window through `SnapState` from a stream of detector
/// candidates.
///
/// Usage is one `update` per processed frame; the returned `quad` is what the
/// UI draws. The caller keeps ownership of tracking: when `didLock` is set it
/// starts a `ScreenTracking` on `lockedCandidate`, and thereafter passes the
/// tracker's quad back in as `selection` with its confidence as
/// `trackingConfidence`.
struct MagneticSnapEngine: Sendable {

    // MARK: - Configuration

    /// Thresholds from the frozen contract.
    var tuning: SnapTuning

    /// Capture rate `SnapTuning.attractionGain` is authored against. The gain
    /// means "close this fraction of the remaining error per frame at this
    /// rate"; see `attractionStep(dt:)` for how other rates are matched.
    var referenceRate: CGFloat = 30

    /// Share of a candidate's score that comes from confidence; the remainder
    /// comes from proximity. Not in `SnapTuning` because it is a property of
    /// this scoring function, not of the acquisition thresholds.
    var confidenceWeight: CGFloat = 0.6

    /// How much better a challenger must score before the magnet abandons the
    /// candidate it is already engaged with. Without this margin two similar
    /// displays side by side make the window ping-pong between them, which is
    /// far worse than staying on the slightly-worse-scoring one.
    var switchMargin: CGFloat = 0.10

    /// Multiplier applied to `attractionRadius` / `alignmentRadius` when
    /// deciding whether to *hold* a level, mirroring the confidence gates'
    /// enter/exit gap. `SnapTuning` gives exit thresholds for confidence but
    /// not for geometry, and a distance dithering across a single radius flaps
    /// the state just as readily as a dithering confidence does.
    var radiusHysteresis: CGFloat = 1.25

    /// How long a candidate keeps counting after the detector last reported it,
    /// measured across frames where the detector *ran*. A candidate missing
    /// from one detection is far more often a single missed detection than a
    /// display that ceased to exist, and dropping the engagement on that
    /// evidence discards the accumulated lock progress, the anti-switching
    /// margin and the user's suppression override all at once.
    ///
    /// Frames the detector skipped do not age anything: they carry no evidence
    /// either way, and the caller's detection interval may legitimately be
    /// longer than this window.
    ///
    /// An engine property rather than a `SnapTuning` field: it describes this
    /// engine's tolerance for its caller's detection cadence, not an
    /// acquisition threshold.
    var candidateGraceInterval: TimeInterval = 0.4

    /// How far above `SnapTuning.degradedTracking` a tracker must climb before
    /// a degraded lock is called healthy again. `SnapTuning` pairs every
    /// acquisition gate with a lower exit gate but gives the tracking gates no
    /// such gap, so a marginal tracker dithering across `degradedTracking`
    /// would flap `.locked`/`.trackingDegraded` every frame.
    var trackingRecoveryMargin: Float = 0.05

    /// Consecutive healthy frames required to leave `.trackingDegraded` or
    /// `.reacquisition`. One good frame from a dithering tracker is not
    /// recovery, and treating it as such also restarts the degradation clock,
    /// which is how `degradedTimeout` ends up never being reached.
    var framesToRecoverTracking: Int = 2

    // MARK: - State

    private(set) var state: SnapState = .manual

    /// Candidate the machine is engaged with (nil in `.manual`, and while
    /// locked — a locked target is identified by `state.targetID`).
    private var engagedID: UUID?
    /// Consecutive frames satisfying the lock gate.
    private var qualifyingFrames = 0
    /// Consecutive frames the tracker has been healthy while recovering.
    private var healthyFrames = 0
    private var lastTimestamp: TimeInterval?
    private var degradedSince: TimeInterval?
    private var reacquisitionSince: TimeInterval?
    /// Candidate the user explicitly rejected; excluded from scoring until
    /// re-armed (see `updateSuppression`). Always an id the *detector* uses,
    /// never an internal one — see `detectorID`.
    private var suppressedID: UUID?
    private var suppressedLeftRange = false

    /// The id the detector uses for whatever is currently locked.
    ///
    /// Normally identical to `state.targetID`, but not after a detector-driven
    /// relock out of `.reacquisition`: there the engine re-stamps a *fresh*
    /// proposal with the existing target id, so that callers keyed on the
    /// target id keep addressing the same target across a dropout. The detector
    /// knows nothing of that re-stamping and goes on proposing its own id.
    ///
    /// Suppression has to key off the id the detector will actually propose. If
    /// `release()` suppressed `state.targetID` after such a relock it would bar
    /// an id nothing ever offers, and the magnet would re-grab the display the
    /// user just rejected on the very next frame — the exact outcome the
    /// override exists to prevent.
    private var detectorID: UUID?

    /// Most recent detector report for a candidate, with the frame it came
    /// from. Only entries younger than `candidateGraceInterval` are kept.
    private struct Observation {
        var candidate: ScreenCandidate
        var timestamp: TimeInterval
    }
    private var lastObservations: [UUID: Observation] = [:]

    init(tuning: SnapTuning = .default) {
        self.tuning = tuning
    }

    /// Frames accumulated toward a lock, for the debug overlay.
    var lockProgress: Int { qualifyingFrames }

    /// Candidate currently barred from attracting, if any.
    var suppressedCandidateID: UUID? { suppressedID }

    // MARK: - Step

    /// Advances the machine by one processed frame.
    ///
    /// - Parameters:
    ///   - selection: the window's current outline — the user's geometry while
    ///     acquiring, the tracker's geometry once locked.
    ///   - candidates: this frame's detector proposals, in any order. The
    ///     distinction between `nil` and `[]` is load-bearing and is the single
    ///     most important semantic of this type:
    ///
    ///     - `nil` means **the detector did not run this frame**. Detection is
    ///       expensive and runs on a fraction of frames, so this is the common
    ///       case, not an error case. The machine carries its existing
    ///       engagement forward and keeps attracting and counting toward a lock
    ///       against the last geometry the detector reported for that
    ///       candidate. Reading `nil` as "there is nothing here" would zero the
    ///       lock counter on every frame between detections, so
    ///       `framesToLock` consecutive qualifying frames could never
    ///       accumulate and no lock would ever be reachable. Carry-forward is
    ///       unconditional: a run of `nil` frames of any length leaves the
    ///       engagement exactly as it was, because nothing about it is
    ///       evidence that anything changed.
    ///     - `[]` means **the detector ran and found nothing**. Even then an
    ///       engagement is not dropped immediately: one missed detection is not
    ///       a vanished display, so the engaged candidate — and the user's
    ///       suppression override — survive `candidateGraceInterval` of absence
    ///       before the engine lets go. That interval is measured from the last
    ///       frame the detector reported the candidate, and only frames where
    ///       the detector ran can expire it.
    ///   - trackingConfidence: the tracker's confidence; nil means the tracker
    ///     produced nothing this frame. Ignored unless locked.
    ///   - isUserDragging: true while the user's finger owns the window.
    ///   - timestamp: the frame's timestamp; the only clock this type has.
    mutating func update(selection: ScreenQuad,
                         candidates: [ScreenCandidate]?,
                         trackingConfidence: Float?,
                         isUserDragging: Bool,
                         timestamp: TimeInterval) -> SnapOutcome {
        let dt = frameInterval(to: timestamp)
        lastTimestamp = timestamp

        let fresh = candidates ?? []
        // Retained observations age on the DETECTOR's clock, not the frame
        // clock: expiry is evaluated only on frames where the detector actually
        // ran. That is what makes `nil` an unconditional carry-forward, as the
        // doc above promises. Ageing on every frame instead tied the grace
        // window to wall time, so any detection interval longer than
        // `candidateGraceInterval` — the pipeline's locked cadence is five
        // times it — evaporated the engagement, and with it the accumulated
        // lock progress, the anti-switching margin and the user's suppression
        // override, purely because detection had not run recently.
        if candidates != nil {
            pruneObservations(at: timestamp)
            for candidate in fresh {
                lastObservations[candidate.id] = Observation(candidate: candidate,
                                                             timestamp: timestamp)
            }
        }
        let effective = fresh + carriedForwardCandidates(fresh: fresh)

        if state.isLockedOrTracking {
            return updateTracked(selection: selection,
                                 candidates: effective,
                                 trackingConfidence: trackingConfidence,
                                 timestamp: timestamp)
        }
        return updateAcquisition(selection: selection,
                                 candidates: effective,
                                 isUserDragging: isUserDragging,
                                 dt: dt)
    }

    /// Explicit user override: drop any candidate or lock and hand the window
    /// back to the user. The abandoned region is suppressed so it cannot
    /// immediately re-grab — the user has to move away and come back before the
    /// magnet offers it again.
    mutating func release() {
        // Ordered by how close each is to "the id the detector will propose for
        // the thing on screen right now": the engaged candidate came straight
        // from the detector, `detectorID` is what the locked target was
        // proposed as, and `state.targetID` is the last resort for a lock whose
        // provenance was not recorded.
        if let id = state.candidateID ?? engagedID ?? detectorID ?? state.targetID {
            suppressedID = id
            suppressedLeftRange = false
        }
        detectorID = nil
        engagedID = nil
        qualifyingFrames = 0
        healthyFrames = 0
        degradedSince = nil
        reacquisitionSince = nil
        state = .manual
    }

    /// Returns to the initial state, forgetting suppression and timing.
    mutating func reset() {
        state = .manual
        engagedID = nil
        qualifyingFrames = 0
        healthyFrames = 0
        lastTimestamp = nil
        degradedSince = nil
        reacquisitionSince = nil
        suppressedID = nil
        suppressedLeftRange = false
        detectorID = nil
        lastObservations.removeAll()
    }

    // MARK: - Detector cadence

    /// Elapsed seconds, or nil when the clock did not advance monotonically.
    ///
    /// Frame timestamps come from whichever source is running — a camera's host
    /// clock reads in the tens of thousands of seconds, a synthetic source
    /// starts at zero — so switching sources moves the clock backwards by a
    /// large amount. Every interval this type measures has to treat that as
    /// "restart the interval" rather than silently comparing a negative (or
    /// NaN) elapsed time against a timeout, which never fires and wedges the
    /// state machine permanently.
    private func elapsed(from start: TimeInterval, to now: TimeInterval) -> TimeInterval? {
        let dt = now - start
        guard dt.isFinite, dt >= 0 else { return nil }
        return dt
    }

    /// Drops detector observations older than the grace interval.
    ///
    /// Called only from frames where the detector ran, so "older" is measured
    /// in detector evidence rather than in elapsed frames. A clock regression
    /// re-stamps rather than expires: the observation is no less valid because
    /// the frame source changed.
    private mutating func pruneObservations(at timestamp: TimeInterval) {
        for (id, observation) in lastObservations {
            guard let age = elapsed(from: observation.timestamp, to: timestamp) else {
                lastObservations[id]?.timestamp = timestamp
                continue
            }
            if age > candidateGraceInterval { lastObservations[id] = nil }
        }
    }

    /// Retained observations that stand in for candidates missing from this
    /// frame's proposals. Only continuity matters here — the candidate the
    /// machine is engaged with and the one the user rejected — so a candidate
    /// the detector genuinely stopped proposing cannot win scoring off stale
    /// geometry; it can only keep holding what it already held.
    private func carriedForwardCandidates(fresh: [ScreenCandidate]) -> [ScreenCandidate] {
        let freshIDs = Set(fresh.map(\.id))
        var carried: [ScreenCandidate] = []
        for id in [engagedID, suppressedID].compactMap({ $0 })
        where !freshIDs.contains(id) && !carried.contains(where: { $0.id == id }) {
            if let observation = lastObservations[id] { carried.append(observation.candidate) }
        }
        return carried
    }

    // MARK: - Acquisition (manual → candidate → attraction → preview → lock)

    /// Rungs of the acquisition ladder. Ordered so hysteresis is a comparison.
    private enum Level: Int, Comparable {
        case none = 0
        case detected
        case attracting
        case preview

        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    private mutating func updateAcquisition(selection: ScreenQuad,
                                            candidates: [ScreenCandidate],
                                            isUserDragging: Bool,
                                            dt: CGFloat) -> SnapOutcome {
        let previous = state

        // Explicit override: the user dragging the window clear of the engaged
        // candidate breaks the magnet (spec §6). Checked before scoring so a
        // rejected candidate cannot be re-chosen on the same frame.
        if isUserDragging,
           let engaged = engagedID,
           let candidate = candidates.first(where: { $0.id == engaged }),
           selection.meanCornerDistance(to: candidate.quad) > tuning.releaseRadius {
            suppressedID = candidate.id
            suppressedLeftRange = true
            engagedID = nil
            qualifyingFrames = 0
            state = .manual
            return SnapOutcome(state: .manual,
                               quad: selection,
                               didLock: false,
                               didRelease: previous != .manual,
                               lockedCandidate: nil,
                               engagedCandidate: nil,
                               alignmentDistance: nil,
                               lockProgress: 0)
        }

        updateSuppression(selection: selection,
                          candidates: candidates,
                          isUserDragging: isUserDragging)

        guard let chosen = chooseCandidate(selection: selection, candidates: candidates) else {
            engagedID = nil
            qualifyingFrames = 0
            state = .manual
            return SnapOutcome(state: .manual,
                               quad: selection,
                               didLock: false,
                               didRelease: previous != .manual,
                               lockedCandidate: nil,
                               engagedCandidate: nil,
                               alignmentDistance: nil,
                               lockProgress: 0)
        }

        let distance = selection.meanCornerDistance(to: chosen.quad)
        // A different candidate starts from scratch: it inherits neither the
        // incumbent's rung (which would let a weak candidate hijack a preview)
        // nor its progress toward a lock.
        if chosen.id != engagedID { qualifyingFrames = 0 }
        let current: Level = chosen.id == engagedID ? level(of: state) : .none
        let resolved = resolveLevel(current: current,
                                    confidence: chosen.confidence,
                                    distance: distance)

        var quad = selection
        var locked: ScreenCandidate?

        switch resolved {
        case .none:
            engagedID = nil
            qualifyingFrames = 0
            state = .manual

        case .detected:
            engagedID = chosen.id
            qualifyingFrames = 0
            state = .candidateDetected(candidateID: chosen.id)

        case .attracting, .preview:
            engagedID = chosen.id
            // The window never moves under the user's finger; the magnet may
            // still preview the outline it would snap to.
            if !isUserDragging {
                quad = selection.interpolated(toward: chosen.quad, t: attractionStep(dt: dt))
            }
            let qualifies = !isUserDragging
                && chosen.confidence >= tuning.enterLock
                && distance <= tuning.alignmentRadius
            qualifyingFrames = qualifies ? qualifyingFrames + 1 : 0
            if qualifies && qualifyingFrames >= max(1, tuning.framesToLock) {
                // Commit snaps exactly to the candidate: leaving the window a
                // lerp-step short of the target would make the lock's first
                // tracked frame jump.
                quad = chosen.quad
                locked = chosen
                engagedID = nil
                // Acquisition locks onto the detector's own candidate, so the
                // two ids coincide here; recording it anyway keeps `release()`
                // reading one field instead of branching on how the lock came
                // about.
                detectorID = chosen.id
                qualifyingFrames = 0
                healthyFrames = 0
                degradedSince = nil
                reacquisitionSince = nil
                state = .locked(targetID: chosen.id)
            } else {
                state = resolved == .preview
                    ? .snapPreview(candidateID: chosen.id)
                    : .magneticAttraction(candidateID: chosen.id)
            }
        }

        let engaged = state.candidateID == nil ? nil : chosen
        return SnapOutcome(state: state,
                           quad: quad,
                           didLock: locked != nil,
                           didRelease: state == .manual && previous != .manual,
                           lockedCandidate: locked,
                           engagedCandidate: engaged,
                           alignmentDistance: engaged == nil && locked == nil ? nil : distance,
                           lockProgress: qualifyingFrames)
    }

    private func level(of state: SnapState) -> Level {
        switch state {
        case .candidateDetected: .detected
        case .magneticAttraction: .attracting
        case .snapPreview: .preview
        default: .none
        }
    }

    /// Highest rung the candidate *earns* this frame from the forward gates.
    private func enterLevel(confidence: Float, distance: CGFloat) -> Level {
        if confidence >= tuning.enterSnapPreview && distance <= tuning.alignmentRadius {
            return .preview
        }
        if confidence >= tuning.enterAttraction && distance <= tuning.attractionRadius {
            return .attracting
        }
        // Detection is still scoped geometrically: a confident display on the
        // far side of the frame is not "a candidate for this window".
        if confidence >= tuning.enterDetection && distance <= tuning.releaseRadius {
            return .detected
        }
        return .none
    }

    /// Whether an already-held rung survives this frame. Uses the `exit*`
    /// thresholds (strictly below their forward counterparts) and the padded
    /// radii, so a value dithering across a single boundary cannot flap.
    private func holds(_ level: Level, confidence: Float, distance: CGFloat) -> Bool {
        switch level {
        case .none:
            true
        case .detected:
            confidence >= tuning.exitDetection
                && distance <= tuning.releaseRadius * radiusHysteresis
        case .attracting:
            confidence >= tuning.exitAttraction
                && distance <= tuning.attractionRadius * radiusHysteresis
        case .preview:
            confidence >= tuning.exitSnapPreview
                && distance <= tuning.alignmentRadius * radiusHysteresis
        }
    }

    /// Forward transitions use the enter gates; falling back walks down one
    /// rung at a time and only past rungs whose hold conditions have failed.
    private func resolveLevel(current: Level, confidence: Float, distance: CGFloat) -> Level {
        let earned = enterLevel(confidence: confidence, distance: distance)
        var level = max(current, earned)
        while level > earned, !holds(level, confidence: confidence, distance: distance) {
            level = Level(rawValue: level.rawValue - 1) ?? .none
        }
        return level
    }

    // MARK: - Candidate choice

    /// Confidence blended with proximity. Proximity is normalized by
    /// `releaseRadius` — the outermost radius in play — so the two terms are
    /// comparable and a candidate beyond it contributes no proximity at all.
    private func score(_ candidate: ScreenCandidate, selection: ScreenQuad) -> CGFloat {
        let distance = selection.meanCornerDistance(to: candidate.quad)
        let proximity = max(0, 1 - distance / max(tuning.releaseRadius, 1e-6))
        return confidenceWeight * CGFloat(candidate.confidence)
            + (1 - confidenceWeight) * proximity
    }

    private func chooseCandidate(selection: ScreenQuad,
                                 candidates: [ScreenCandidate]) -> ScreenCandidate? {
        let scored = candidates
            .filter { $0.id != suppressedID && $0.confidence >= tuning.exitDetection }
            .map { (candidate: $0, score: score($0, selection: selection)) }
        guard let best = scored.max(by: { $0.score < $1.score }) else { return nil }
        // An incumbent missing from this frame is still represented here by its
        // retained observation while it is inside the grace window, so a frame
        // that happens to report only the challenger cannot hand the window
        // over with no margin at all.
        guard let engaged = engagedID,
              let incumbent = scored.first(where: { $0.candidate.id == engaged }) else {
            return best.candidate
        }
        // Anti-target-switching: the incumbent keeps the window unless a
        // challenger is meaningfully better, not merely better.
        return best.score > incumbent.score + switchMargin ? best.candidate : incumbent.candidate
    }

    /// Re-arms a candidate the user rejected. Two conditions, both required:
    /// the window has been out of range since the rejection, and the user's
    /// finger is off it — a magnet that grabs back mid-gesture reads as the app
    /// fighting the user, which is exactly what the override exists to prevent.
    ///
    /// The candidate disappearing satisfies the first condition but not the
    /// second: a rejection is a user decision, and a detector dropout is not
    /// the user changing their mind.
    private mutating func updateSuppression(selection: ScreenQuad,
                                            candidates: [ScreenCandidate],
                                            isUserDragging: Bool) {
        guard let id = suppressedID else { return }
        guard let candidate = candidates.first(where: { $0.id == id }) else {
            suppressedLeftRange = true
            return
        }
        let distance = selection.meanCornerDistance(to: candidate.quad)
        if distance > tuning.releaseRadius { suppressedLeftRange = true }
        if suppressedLeftRange && !isUserDragging && distance <= tuning.attractionRadius {
            suppressedID = nil
            suppressedLeftRange = false
        }
    }

    // MARK: - Attraction

    /// Frame interval in seconds, from consecutive frame timestamps.
    ///
    /// Clamped because a dropped or reordered frame must not produce a step of
    /// a whole second (a visible teleport) or of zero.
    private func frameInterval(to timestamp: TimeInterval) -> CGFloat {
        let nominal = 1 / referenceRate
        guard let last = lastTimestamp else { return nominal }
        let dt = CGFloat(timestamp - last)
        guard dt > 0 else { return nominal }
        return min(max(dt, 1 / 240), 0.5)
    }

    /// Interpolation factor for one frame of attraction.
    ///
    /// Closing `gain` of the remaining error per reference frame means
    /// *retaining* `(1 - gain)` of it, and retention compounds: over
    /// `dt * referenceRate` reference frames the retained fraction is
    /// `(1 - gain)^(dt * referenceRate)`. Taking the complement gives a step
    /// that produces the same trajectory in wall-clock time at any capture
    /// rate, instead of the naive constant `gain` which converges twice as fast
    /// at 60 fps as at 30. The result is in 0...1, so a corner-wise lerp is
    /// exponential decay toward the target: monotonic, never overshooting.
    private func attractionStep(dt: CGFloat) -> CGFloat {
        let gain = min(max(tuning.attractionGain, 0), 1)
        guard gain > 0 else { return 0 }
        guard gain < 1 else { return 1 }
        let retained = pow(Double(1 - gain), Double(dt * referenceRate))
        return min(max(1 - CGFloat(retained), 0), 1)
    }

    // MARK: - Locked / degraded / reacquisition

    /// Health of the tracker this frame.
    ///
    /// `recovering` raises the healthy threshold by `trackingRecoveryMargin`:
    /// the gate to climb back out of degradation is higher than the gate to
    /// fall into it, so a tracker dithering around `degradedTracking` stays
    /// degraded instead of flapping.
    private func trackingHealth(_ confidence: Float?, recovering: Bool) -> TrackingHealth {
        // A tracker that produced nothing this frame counts as degraded, not
        // lost: geometry coasts and `degradedTimeout` decides, rather than one
        // failed frame demoting a good lock.
        guard let confidence else { return .degraded }
        if confidence < tuning.lostTracking { return .lost }
        let healthyThreshold = recovering
            ? tuning.degradedTracking + trackingRecoveryMargin
            : tuning.degradedTracking
        if confidence < healthyThreshold { return .degraded }
        return .healthy
    }

    private mutating func beginReacquisition(targetID: UUID, at timestamp: TimeInterval) {
        degradedSince = nil
        reacquisitionSince = timestamp
        qualifyingFrames = 0
        healthyFrames = 0
        engagedID = nil
        state = .reacquisition(targetID: targetID)
    }

    private mutating func updateTracked(selection: ScreenQuad,
                                        candidates: [ScreenCandidate],
                                        trackingConfidence: Float?,
                                        timestamp: TimeInterval) -> SnapOutcome {
        let previous = state
        guard let targetID = state.targetID else {
            state = .manual
            detectorID = nil
            return SnapOutcome(state: .manual, quad: selection, didLock: false,
                               didRelease: true, lockedCandidate: nil,
                               engagedCandidate: nil, alignmentDistance: nil,
                               lockProgress: 0)
        }

        var quad = selection
        var relocked: ScreenCandidate?
        let recovering = previous != .locked(targetID: targetID)
        let health = trackingHealth(trackingConfidence, recovering: recovering)
        healthyFrames = health == .healthy ? healthyFrames + 1 : 0
        // Sustained recovery, not one good frame: a single healthy frame from a
        // dithering tracker also restarts the degradation clock, which is how a
        // marginal tracker never reaches `degradedTimeout`.
        let recovered = health == .healthy && healthyFrames >= max(1, framesToRecoverTracking)

        switch state {
        case .locked:
            switch health {
            case .healthy:
                degradedSince = nil
            case .degraded:
                degradedSince = timestamp
                state = .trackingDegraded(targetID: targetID)
            case .lost:
                beginReacquisition(targetID: targetID, at: timestamp)
            }

        case .trackingDegraded:
            if health == .lost {
                beginReacquisition(targetID: targetID, at: timestamp)
            } else if recovered {
                degradedSince = nil
                state = .locked(targetID: targetID)
            } else {
                let since = degradedSince ?? timestamp
                if let elapsed = elapsed(from: since, to: timestamp) {
                    degradedSince = since
                    if elapsed >= tuning.degradedTimeout {
                        beginReacquisition(targetID: targetID, at: timestamp)
                    }
                } else {
                    degradedSince = timestamp
                }
            }

        case .reacquisition:
            if recovered {
                reacquisitionSince = nil
                qualifyingFrames = 0
                engagedID = nil
                state = .locked(targetID: targetID)
            } else if let candidate = reacquisitionCandidate(selection: selection,
                                                             candidates: candidates) {
                // Detector-driven recovery. The target id is carried over so a
                // dropout does not orphan the fields authored against it.
                if candidate.id != engagedID { qualifyingFrames = 0 }
                engagedID = candidate.id
                qualifyingFrames += 1
                if qualifyingFrames >= max(1, tuning.framesToLock) {
                    quad = candidate.quad
                    relocked = ScreenCandidate(id: targetID,
                                               quad: candidate.quad,
                                               signals: candidate.signals,
                                               confidence: candidate.confidence,
                                               observationCount: candidate.observationCount,
                                               lastSeen: candidate.lastSeen)
                    reacquisitionSince = nil
                    qualifyingFrames = 0
                    healthyFrames = 0
                    engagedID = nil
                    // The reported candidate wears the target id; the detector
                    // will keep proposing this one. Suppression has to follow
                    // the detector, so remember which is which.
                    detectorID = candidate.id
                    state = .locked(targetID: targetID)
                }
            } else {
                qualifyingFrames = 0
                engagedID = nil
            }

            // Only if neither recovery path fired this frame.
            if case .reacquisition = state {
                let since = reacquisitionSince ?? timestamp
                if let elapsed = elapsed(from: since, to: timestamp) {
                    reacquisitionSince = since
                    if elapsed >= tuning.reacquisitionTimeout {
                        reacquisitionSince = nil
                        qualifyingFrames = 0
                        healthyFrames = 0
                        engagedID = nil
                        detectorID = nil
                        state = .manual
                    }
                } else {
                    reacquisitionSince = timestamp
                }
            }

        default:
            break
        }

        let distance = relocked.map { selection.meanCornerDistance(to: $0.quad) }
        return SnapOutcome(state: state,
                           quad: quad,
                           didLock: relocked != nil,
                           didRelease: state == .manual && previous != .manual,
                           lockedCandidate: relocked,
                           engagedCandidate: nil,
                           alignmentDistance: distance,
                           lockProgress: qualifyingFrames)
    }

    /// Best candidate that could re-commit a lost target: lock-grade confidence
    /// and near where the target was last seen. `attractionRadius` rather than
    /// `alignmentRadius` because a target usually goes missing precisely
    /// because it moved.
    private func reacquisitionCandidate(selection: ScreenQuad,
                                        candidates: [ScreenCandidate]) -> ScreenCandidate? {
        candidates
            .filter {
                $0.confidence >= tuning.enterLock
                    && selection.meanCornerDistance(to: $0.quad) <= tuning.attractionRadius
            }
            .max { score($0, selection: selection) < score($1, selection: selection) }
    }
}
