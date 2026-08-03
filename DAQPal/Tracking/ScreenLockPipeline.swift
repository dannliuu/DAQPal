//
//  ScreenLockPipeline.swift
//  DAQPal
//
//  The keystone that turns the screen-locking components into a workflow
//  (spec Gate 14): capture → detection → snap → lock → tracking → perspective
//  normalization → field mapping, feeding tracked-geometry ROIs to the existing
//  recognition pipeline.
//
//  ## Cadence
//
//  The whole point of this type is that its stages run at DIFFERENT rates:
//
//    tracking    every frame while locked  — cheap, and geometry must not lag
//    detection   time-gated, adaptive      — expensive; rare when healthy
//    analysis    on lock / on request      — very expensive; never per-frame
//
//  Rates are expressed as intervals in FRAME-TIMESTAMP seconds, not as frame
//  counts, so behavior does not change with capture rate (12 fps synthetic vs
//  30/60 fps camera).
//
//  ## Backpressure
//
//  This adds no queue. It runs inline inside `FrameProcessor`'s serial drain,
//  which `await`s each frame's processing before pulling the next, so a slow
//  pipeline degrades to a lower effective rate while the source's own
//  drop-late policy discards the backlog. Newest-frame preference is inherited
//  from that existing structure rather than reimplemented here — see
//  `FrameProcessor`'s doc comment.
//
//  ## Manual fallback
//
//  A device with a hand-placed ROI and no lock is untouched by all of this. The
//  pipeline only ever *adds* per-frame ROI overrides for fields belonging to a
//  locked target; when nothing is locked it returns an empty override map and
//  the app behaves exactly as it did before this type existed.
//

import CoreVideo
import Foundation
import os

/// One frame's output from the intelligent pipeline.
struct ScreenLockUpdate: Sendable {
    var snapState: SnapState = .manual
    /// Where the selection window should be drawn this frame — the user's own
    /// geometry while acquiring, the tracked target's once locked.
    var selectionQuad: ScreenQuad?
    var target: TrackedTarget?
    /// Most recent detector proposals, for the debug/candidate overlay. Carried
    /// forward on frames where detection did not run so the overlay does not
    /// strobe at the detection cadence.
    var candidates: [ScreenCandidate] = []
    var didLock = false
    var didRelease = false
    /// Frame-space ROI for each SELECTED field, derived from the live target
    /// geometry. Empty whenever nothing is locked — the manual path.
    var fieldROIs: [UUID: NormalizedROI] = [:]
    /// True only while the lock is BOTH healthy and independently verified
    /// (remediation plan Phase 14: `TrackingHealthy = false ⇒ MeasurementValid
    /// = false`, even at 99% OCR confidence). When false, `fieldROIs` is empty
    /// by construction, so no field-backed reading can be produced from
    /// geometry the detector has not corroborated.
    var measurementsValid = false
    /// Fields produced by an analysis pass that ran on this frame, if any.
    /// Nil means "no new analysis" — distinct from an empty array, which means
    /// analysis ran and found nothing.
    var analyzedFields: [ScreenField]?
    /// Appearance-sentinel NCC for this frame, exposed for telemetry/debug
    /// overlays. Nil when the sentinel did not evaluate (not locked, sentinel
    /// disabled, unsampleable frame, or a too-flat patch pair).
    var sentinelNCC: Float?
    /// True while the appearance sentinel's hard veto is standing — the
    /// tracked quad no longer looks like what was locked.
    var sentinelVetoed = false
    /// True while the pipeline is disabled — the caller should behave exactly
    /// as it did before this type existed.
    var isIdle = true
}

/// Orchestrates detection, snapping, tracking and field mapping at their
/// respective cadences. An actor because it owns mutable cross-frame state and
/// two components (`ScreenCandidateDetector`, `VisionScreenTracker`) that are
/// themselves actors with strict single-sequence requirements.
actor ScreenLockPipeline {

    // MARK: Cadence configuration

    /// Detection interval while hunting for something to lock. Fast enough that
    /// acquisition feels immediate, slow enough that the expensive Vision
    /// rectangle+text pass is not on every frame.
    var acquiringDetectionInterval: TimeInterval = 0.2
    /// Detection interval while locked and tracking healthily. This is the
    /// INDEPENDENT REVALIDATION cadence, not an optimization knob: every pass
    /// feeds `TrackVerifier`, and it is the only mechanism that can catch a
    /// tracker that has drifted onto background while reporting healthy
    /// (that tracker is self-consistent, so its own confidence never falls).
    /// 0.5 s bounds how long a drifted lock can survive; the earlier 2.0 s
    /// left a drifted-but-LOCKED reading on screen for up to two seconds.
    var lockedDetectionInterval: TimeInterval = 0.5
    /// A locked tracker that produces NO update for this long fails the lock
    /// (plan Phase 7: `trackerHasNoFreshUpdate → FAIL_AFTER_TIMEOUT`). A stale
    /// quad rendered as a healthy lock is exactly the "stale geometry
    /// presented as truth" failure the plan forbids.
    var staleTrackerTimeout: TimeInterval = 0.75
    /// Detection interval while degraded or reacquiring: the detector is the
    /// recovery mechanism, so it runs hot.
    var recoveringDetectionInterval: TimeInterval = 0.1
    /// Minimum spacing between field-analysis passes. Analysis warps the
    /// display and runs a full text recognition over it; it is the most
    /// expensive thing here and must never be per-frame.
    var analysisMinimumInterval: TimeInterval = 1.0

    // MARK: Components

    private let detector: ScreenCandidateDetector
    private let tracker: VisionScreenTracker
    private let analyzer: ScreenFieldAnalyzer
    private var snap: MagneticSnapEngine

    // MARK: State

    /// Master switch. Off by default: the intelligent path is opt-in so the
    /// manual workflow stays the shipping default until this is validated on
    /// hardware.
    private var isEnabled = false
    private var target: TrackedTarget?
    private var lastCandidates: [ScreenCandidate] = []
    private var lastDetectionAt: TimeInterval?
    private var lastAnalysisAt: TimeInterval?
    /// Fields the user has chosen to capture, in canonical target space.
    private var selectedFields: [ScreenField] = []
    /// Set when the caller wants a fresh analysis pass on the next frame.
    private var analysisRequested = false
    /// Independent geometric verification of the current lock (Phase 7–8,
    /// hardened per §11). Configuration is fixed at init so the benchmark can
    /// instantiate feature variants.
    private var verifier: TrackVerifier
    /// Per-frame appearance verification of the locked quad (§11's
    /// between-detection-passes defense). Evaluated on every locked frame at
    /// Stage 1b; a veto is handled exactly like a DIVERGED detection verdict.
    private var sentinel: AppearanceSentinel
    /// Master switch for the sentinel, fixed at init for benchmark variants.
    private let sentinelEnabled: Bool
    /// Timestamp of the last frame the tracker produced geometry for.
    private var lastTrackerUpdateAt: TimeInterval?
    /// The window's geometry as the magnet has moved it, carried across frames.
    ///
    /// Load-bearing: magnetic attraction is *incremental* — each frame moves
    /// the selection a fraction of the way toward the candidate. Re-deriving
    /// the selection from the caller's stored ROI every frame would discard
    /// that progress, so the window would never actually close the distance,
    /// `alignmentRadius` would never be satisfied, and the machine would sit in
    /// `.magneticAttraction` forever without ever locking. (Observed exactly
    /// that in a Simulator run before this existed.)
    private var attractedSelection: ScreenQuad?

    init(detector: ScreenCandidateDetector = ScreenCandidateDetector(),
         tracker: VisionScreenTracker = VisionScreenTracker(),
         analyzer: ScreenFieldAnalyzer = ScreenFieldAnalyzer(),
         snap: MagneticSnapEngine = MagneticSnapEngine(),
         verifierConfig: TrackVerifier.Config = TrackVerifier.Config(),
         sentinelEnabled: Bool = true,
         sentinelConfig: AppearanceSentinel.Config = AppearanceSentinel.Config()) {
        self.detector = detector
        self.tracker = tracker
        self.analyzer = analyzer
        self.snap = snap
        self.verifier = TrackVerifier(config: verifierConfig)
        self.sentinel = AppearanceSentinel(config: sentinelConfig)
        self.sentinelEnabled = sentinelEnabled
    }

    // MARK: Control

    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { await teardown() }
    }

    var enabled: Bool { isEnabled }

    /// Drops the lock and returns to manual acquisition. The user's explicit
    /// override — `MagneticSnapEngine.release()` also suppresses the rejected
    /// candidate so the magnet does not immediately re-grab it.
    func release() async {
        snap.release()
        target = nil
        selectedFields = []
        attractedSelection = nil
        verifier.reset()
        sentinel.reset()
        lastTrackerUpdateAt = nil
        await tracker.reset()
    }

    func requestAnalysis() {
        analysisRequested = true
    }

    /// Replaces the set of fields whose values are captured. Regions are in
    /// canonical target space, so they survive target motion by construction.
    func setSelectedFields(_ fields: [ScreenField]) {
        selectedFields = fields.filter { $0.isSelected && $0.kind == .numeric }
    }

    private func teardown() async {
        snap.reset()
        target = nil
        selectedFields = []
        lastCandidates = []
        lastDetectionAt = nil
        lastAnalysisAt = nil
        analysisRequested = false
        attractedSelection = nil
        verifier.reset()
        sentinel.reset()
        lastTrackerUpdateAt = nil
        await detector.reset()
        await tracker.reset()
    }

    // MARK: Per-frame step

    /// Advances the pipeline by one frame.
    ///
    /// - Parameters:
    ///   - frame: the frame being processed.
    ///   - selection: the user's current selection outline, used while
    ///     acquiring. Nil means the user has placed nothing yet.
    ///   - isUserDragging: true while the finger owns the window; suspends
    ///     magnetic attraction so it never fights the gesture.
    func process(frame: TimestampedFrame,
                 selection: ScreenQuad?,
                 isUserDragging: Bool) async -> ScreenLockUpdate {
        guard isEnabled else { return ScreenLockUpdate() }

        let t = frame.timestamp
        var update = ScreenLockUpdate(isIdle: false)

        // --- Stage 1: tracking (every frame while locked) -------------------
        var trackingConfidence: Float?
        if target != nil, snap.state.isLockedOrTracking {
            if let tracked = await tracker.track(frame: frame) {
                trackingConfidence = tracked.confidence
                target?.quad = tracked.quad
                target?.trackingConfidence = tracked.confidence
                target?.lastUpdated = tracked.timestamp
                lastTrackerUpdateAt = tracked.timestamp
            } else {
                // A failed frame is not an immediate loss: the snap engine's
                // degraded/reacquisition timeouts decide that. Reporting nil
                // lets it apply its own hysteresis rather than this layer
                // second-guessing it — UNTIL the silence exceeds
                // `staleTrackerTimeout`, at which point a stale quad must not
                // keep masquerading as a live one (Phase 7 hard veto:
                // trackerHasNoFreshUpdate → FAIL_AFTER_TIMEOUT).
                trackingConfidence = nil
                if let last = lastTrackerUpdateAt {
                    let silence = t - last
                    if silence.isFinite, silence > staleTrackerTimeout {
                        trackingConfidence = 0
                    }
                }
            }
        }

        // --- Stage 1b: appearance sentinel (every frame while locked) --------
        // The between-detection-passes defense (§11). The verifier can only
        // testify on frames where the detector ran (every ~0.5 s while
        // locked); in between, a quad that has drifted onto background is
        // invisible to every geometric check — the tracker's own confidence is
        // self-referential and reports healthy forever. The sentinel compares
        // what the locked quad LOOKS like against the appearance captured at
        // lock (refreshed on every corroborated pass), on every frame. A veto
        // is handled exactly like a DIVERGED detection verdict: tracking
        // confidence forced to zero, which drives the snap engine's `.lost`
        // path into same-frame reacquisition, and `measurementsValid` goes
        // false with it below.
        if sentinelEnabled, let quad = target?.quad, snap.state.isLockedOrTracking {
            let verdict = sentinel.evaluate(pixelBuffer: frame.pixelBuffer, quad: quad)
            update.sentinelNCC = sentinel.lastNCC
            if case .vetoed = verdict {
                trackingConfidence = 0
            }
        }

        // --- Stage 2: detection (time-gated, adaptive) ----------------------
        var freshCandidates: [ScreenCandidate]?
        if shouldDetect(at: t) {
            let found = await detector.detect(in: frame)
            lastDetectionAt = t
            lastCandidates = found
            freshCandidates = found
        }

        // --- Stage 2b: INDEPENDENT VERIFICATION (Phases 7–8) ----------------
        // Every fresh detection pass while locked testifies for or against the
        // tracked geometry. The tracker's own confidence is deliberately not
        // consulted: a tracker that drifted onto static background is
        // self-consistent and reports healthy forever — the observed live
        // failure. A DIVERGED verdict is a hard veto that no aggregate score
        // can override: tracking confidence is forced to zero, which drives
        // the snap engine's `.lost` path into reacquisition on this same
        // frame, and `measurementsValid` below goes false with it.
        if let fresh = freshCandidates, let trackedQuad = target?.quad,
           snap.state.isLockedOrTracking {
            let verdict = verifier.evaluate(tracked: trackedQuad, candidates: fresh, timestamp: t)
#if DEBUG
            // Verdict trace for live-run analysis. Screenshot sampling proved
            // twice that it under-samples this state machine; the trace is the
            // ground truth for whether the veto engages.
            Self.verifyLog.log("verdict=\(String(describing: verdict), privacy: .public) state=\(self.snap.state.displayLabel, privacy: .public) unverified=\(self.verifier.isUnverified) t=\(t, format: .fixed(precision: 2))")
#endif
            switch verdict {
            case .corroborated:
                // The detector just independently blessed this geometry, so
                // what it looks like RIGHT NOW is the lock's appearance.
                // Refreshing here is what keeps legitimate digit changes from
                // ever decaying the sentinel's similarity — the reference is
                // never older than the last corroborated pass.
                if sentinelEnabled {
                    sentinel.refreshReference(pixelBuffer: frame.pixelBuffer, quad: trackedQuad)
                }
            case .diverged, .transit:
                // Both are hard vetoes. Transit — a display sweeping THROUGH a
                // parked lock — is drift wearing corroboration's clothes; it
                // kept the original live failure alive by re-blessing a dead
                // lock every time the bouncing panel crossed it.
                trackingConfidence = 0
            case .unsupported where verifier.isUnverified:
                // Sustained absence of corroboration is not the drift
                // signature (nothing confident was seen ANYWHERE — occlusion,
                // glare, display off), so it degrades rather than kills:
                // capped below the healthy band, the snap engine's own
                // degraded → timeout → reacquisition machinery takes over.
                trackingConfidence = min(trackingConfidence ?? 0, 0.4)
            default:
                break
            }
        }

        // --- Stage 3: snap state machine ------------------------------------
        // Selection precedence, highest first:
        //   1. the tracked target once locked — geometry comes from the tracker
        //   2. the user's own ROI while their finger is on it — they always win
        //   3. the carried-forward attracted quad — so attraction accumulates
        //   4. the user's stored ROI, or a centered seed if they have none
        let effectiveSelection: ScreenQuad
        if let quad = target?.quad, snap.state.isLockedOrTracking {
            effectiveSelection = quad
        } else if isUserDragging, let selection {
            effectiveSelection = selection
            attractedSelection = selection
        } else {
            effectiveSelection = attractedSelection ?? selection ?? Self.centeredSeed
        }

        // `nil` vs `[]` is load-bearing here: nil means the detector did not
        // run this frame, which is the common case by design.
        let outcome = snap.update(selection: effectiveSelection,
                                  candidates: freshCandidates,
                                  trackingConfidence: trackingConfidence,
                                  isUserDragging: isUserDragging,
                                  timestamp: t)
        // Carry the magnet's incremental progress into the next frame.
        if !snap.state.isLockedOrTracking {
            attractedSelection = outcome.quad
        }

        update.snapState = outcome.state
        update.selectionQuad = outcome.quad
        update.candidates = lastCandidates
        update.didLock = outcome.didLock
        update.didRelease = outcome.didRelease

        // --- Stage 4: lock commit -------------------------------------------
        if outcome.didLock, let locked = outcome.lockedCandidate {
            verifier.beginLock(at: t)
            if sentinelEnabled {
                // Fingerprint the locked appearance from the very frame the
                // lock was committed on. If this frame is unsampleable the
                // sentinel abstains for the life of the lock (never guesses).
                sentinel.beginLock(pixelBuffer: frame.pixelBuffer, quad: locked.quad)
            }
            lastTrackerUpdateAt = t
            let newTarget = TrackedTarget(id: locked.id,
                                          quad: locked.quad,
                                          detectionConfidence: locked.confidence,
                                          trackingConfidence: 1,
                                          lastUpdated: t)
            target = newTarget
            selectedFields = []
            await tracker.startTracking(quad: locked.quad, in: frame)
            analysisRequested = true
        }
        if outcome.didRelease {
            target = nil
            selectedFields = []
            attractedSelection = nil
            verifier.reset()
            sentinel.reset()
            lastTrackerUpdateAt = nil
            await tracker.reset()
        }
        if let target {
            update.target = target
        }

        // --- Stage 5: field analysis (rare, gated) --------------------------
        if let target, shouldAnalyze(at: t) {
            lastAnalysisAt = t
            analysisRequested = false
            update.analyzedFields = await analyze(frame: frame, target: target)
        }

        // --- Stage 6: field mapping → tracked-geometry ROIs -----------------
        // Gated on VERIFIED health, not on target existence. This is the
        // data-integrity fix: previously ROIs were produced whenever a target
        // existed, so a drifted-but-"healthy" tracker kept feeding OCR regions
        // of empty background and the readings sailed through validation.
        // `MeasurementValid = ScreenLockValid AND TrackingHealthy AND
        // independently verified` — a reading from unverified geometry is not
        // a low-quality reading, it is not a reading at all.
        // The standing (possibly refreshed-away) sentinel veto, surfaced after
        // Stage 2b so a corroborated refresh on this same frame reads healthy.
        update.sentinelVetoed = sentinelEnabled && !sentinel.isHealthy
        update.measurementsValid = {
            guard case .locked = outcome.state else { return false }
            return !verifier.isUnverified && sentinel.isHealthy
        }()
        if update.measurementsValid, let target, !selectedFields.isEmpty {
            var rois: [UUID: NormalizedROI] = [:]
            for field in selectedFields {
                if let roi = field.frameRegion(in: target) {
                    rois[field.id] = roi
                }
            }
            update.fieldROIs = rois
        }

        return update
    }

    // MARK: Cadence decisions

    /// Detection cadence adapts to how well tracking is doing — the spec's
    /// "high tracking confidence → reduce detector frequency" rule.
    private func shouldDetect(at t: TimeInterval) -> Bool {
        let interval: TimeInterval
        switch snap.state {
        case .locked:
            interval = lockedDetectionInterval
        case .trackingDegraded, .reacquisition:
            interval = recoveringDetectionInterval
        default:
            interval = acquiringDetectionInterval
        }
        guard let last = lastDetectionAt else { return true }
        let elapsed = t - last
        // A backwards or non-finite timestamp (frame-source switch) restarts
        // the cadence rather than wedging it, matching the snap engine's
        // treatment of the same hazard.
        guard elapsed.isFinite, elapsed >= 0 else { return true }
        return elapsed >= interval
    }

    private func shouldAnalyze(at t: TimeInterval) -> Bool {
        guard analysisRequested else { return false }
        guard let last = lastAnalysisAt else { return true }
        let elapsed = t - last
        guard elapsed.isFinite, elapsed >= 0 else { return true }
        return elapsed >= analysisMinimumInterval
    }

    /// Warps the locked display to canonical space and analyzes its structure.
    /// Returns nil when the warp fails, so the caller can distinguish "could
    /// not analyze" from "analyzed and found nothing".
    private func analyze(frame: TimestampedFrame, target: TrackedTarget) async -> [ScreenField]? {
        guard let canonical = PerspectiveNormalizer.canonicalImage(from: frame.pixelBuffer,
                                                                   quad: target.quad) else {
            return nil
        }
        return await analyzer.analyze(canonicalImage: canonical)
    }

#if DEBUG
    /// Verdict/state trace, readable via `log show --predicate 'subsystem == "daqpal"'`.
    private static let verifyLog = Logger(subsystem: "daqpal", category: "verify")
#endif

    /// Seed geometry when the user has placed nothing: a centered window the
    /// magnet can attract from.
    private static let centeredSeed = ScreenQuad(roi: NormalizedROI(x: 0.25, y: 0.42,
                                                                    width: 0.5, height: 0.16))
}
