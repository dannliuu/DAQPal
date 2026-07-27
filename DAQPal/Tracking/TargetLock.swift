//
//  TargetLock.swift
//  DAQPal
//
//  Contracts for intelligent screen acquisition: what a detector proposes, how
//  the magnetic snap state machine progresses, and what a locked+tracked target
//  carries (spec §5–§9).
//
//  Design rule for this whole layer: it is ADDITIVE. A device with a manually
//  placed `NormalizedROI` and no lock keeps working exactly as before —
//  intelligence is an opt-in overlay, never a required path (spec principle 9,
//  "manual selection is the fallback, not the primary intelligence").
//

import CoreGraphics
import Foundation

// MARK: - Detection

/// Independent evidence that a region is an instrument display. Kept as named
/// components (not a pre-blended number) so the debug overlay can show *why*
/// something scored well and weights stay tunable without touching detectors.
struct ScreenSignals: Equatable, Sendable {
    /// Rectangularity/edge strength from geometric detection (Vision rectangles).
    var geometry: Float = 0
    /// How display-like the aspect ratio is.
    var aspectRatio: Float = 0
    /// Density and confidence of recognized text inside the region.
    var text: Float = 0
    /// Numeric-looking content specifically (digits, decimal points, signs).
    var numeric: Float = 0
    /// How steady this candidate's geometry has been across recent frames.
    var temporalStability: Float = 0

    static let zero = ScreenSignals()
}

/// Relative weight of each signal in the fused candidate confidence.
///
/// Deliberately expressed as data, not constants buried in the detector: the
/// spec requires OCR to *contribute* to detection without being the sole
/// mechanism, and these weights are where that balance is enforced and tuned.
/// Geometry + aspect + stability sum to 0.65, so a text-free but strongly
/// rectangular, stable display still clears the 0.60 detection threshold.
struct ScreenSignalWeights: Equatable, Sendable {
    var geometry: Float = 0.35
    var aspectRatio: Float = 0.10
    var text: Float = 0.20
    var numeric: Float = 0.15
    var temporalStability: Float = 0.20

    static let `default` = ScreenSignalWeights()

    var total: Float { geometry + aspectRatio + text + numeric + temporalStability }

    /// Weighted mean of the signals, normalized to 0...1.
    func fuse(_ s: ScreenSignals) -> Float {
        guard total > 0 else { return 0 }
        let sum = s.geometry * geometry
            + s.aspectRatio * aspectRatio
            + s.text * text
            + s.numeric * numeric
            + s.temporalStability * temporalStability
        return min(max(sum / total, 0), 1)
    }
}

/// One proposed display region for a single frame.
struct ScreenCandidate: Identifiable, Equatable, Sendable {
    /// Stable across frames while the detector keeps matching this candidate to
    /// the same physical region — lets stability accumulate and lets the UI
    /// avoid flickering overlays.
    let id: UUID
    var quad: ScreenQuad
    var signals: ScreenSignals
    /// Fused 0...1 confidence (see `ScreenSignalWeights`).
    var confidence: Float
    /// Consecutive frames this candidate has been matched.
    var observationCount: Int
    /// Frame timestamp of the most recent observation.
    var lastSeen: TimeInterval

    init(id: UUID = UUID(),
         quad: ScreenQuad,
         signals: ScreenSignals,
         confidence: Float,
         observationCount: Int = 1,
         lastSeen: TimeInterval = 0) {
        self.id = id
        self.quad = quad
        self.signals = signals
        self.confidence = confidence
        self.observationCount = observationCount
        self.lastSeen = lastSeen
    }
}

/// Detects candidate display regions in a frame. The seam that lets the
/// geometric detector be replaced or augmented (ML object detection, template
/// matching) without touching the snap or tracking layers.
protocol ScreenDetecting: Sendable {
    /// Proposals for one frame, best-first. Never throws — a detection failure
    /// is an empty result, matching the pipeline's "never break the frame loop"
    /// rule.
    func detect(in frame: TimestampedFrame) async -> [ScreenCandidate]
}

// MARK: - Magnetic snap state machine

/// Acquisition state for one device's selection window (spec §7).
///
/// Hysteresis rule: forward transitions use the `enter*` thresholds below;
/// falling back requires dropping under the corresponding `exit*` threshold,
/// which is strictly lower. Without that gap a candidate hovering at a
/// boundary makes the window oscillate between attracting and releasing.
enum SnapState: Equatable, Sendable {
    /// No candidate in play; the window is purely user-driven.
    case manual
    /// A candidate exists nearby but is not close enough to pull the window.
    case candidateDetected(candidateID: UUID)
    /// The window is being drawn toward the candidate.
    case magneticAttraction(candidateID: UUID)
    /// Aligned and awaiting the confidence needed to lock; the UI previews the
    /// snap outline so the user can see what is about to happen.
    case snapPreview(candidateID: UUID)
    /// Committed: the window is now a viewport onto a tracked target.
    case locked(targetID: UUID)
    /// Locked but tracking quality has fallen; geometry is coasting.
    case trackingDegraded(targetID: UUID)
    /// Lock lost; the detector is running hot to find the target again.
    case reacquisition(targetID: UUID)

    /// True while the target's geometry (not the user's finger) drives the
    /// window — the states in which OCR should read from tracked geometry.
    var isLockedOrTracking: Bool {
        switch self {
        case .locked, .trackingDegraded, .reacquisition: true
        default: false
        }
    }

    /// Candidate under consideration, if any.
    var candidateID: UUID? {
        switch self {
        case .candidateDetected(let id), .magneticAttraction(let id), .snapPreview(let id): id
        default: nil
        }
    }

    var targetID: UUID? {
        switch self {
        case .locked(let id), .trackingDegraded(let id), .reacquisition(let id): id
        default: nil
        }
    }

    /// Short label for the debug overlay / accessibility.
    var displayLabel: String {
        switch self {
        case .manual: "MANUAL"
        case .candidateDetected: "CANDIDATE"
        case .magneticAttraction: "ATTRACTING"
        case .snapPreview: "SNAP PREVIEW"
        case .locked: "LOCKED"
        case .trackingDegraded: "DEGRADED"
        case .reacquisition: "REACQUIRING"
        }
    }
}

/// Tunable thresholds for acquisition. Values are the spec's illustrative
/// starting points (§7); every one is expected to move under measurement, which
/// is exactly why they live in one tunable struct rather than scattered
/// literals.
///
/// Proximity is measured in normalized frame units, so it is resolution- and
/// density-independent by construction (spec's "do not hard-code pixel
/// thresholds" requirement) — 0.18 is ~18% of the frame's smaller dimension.
struct SnapTuning: Equatable, Sendable {
    // Confidence gates (forward).
    var enterDetection: Float = 0.60
    var enterAttraction: Float = 0.70
    var enterSnapPreview: Float = 0.80
    var enterLock: Float = 0.90
    // Confidence gates (release) — strictly below their forward counterparts.
    var exitDetection: Float = 0.50
    var exitAttraction: Float = 0.60
    var exitSnapPreview: Float = 0.70
    /// Below this, a locked target is considered degraded.
    var degradedTracking: Float = 0.55
    /// Below this, tracking is lost outright and reacquisition begins.
    var lostTracking: Float = 0.30

    // Geometric gates, normalized frame units.
    /// Attraction begins inside this mean-corner distance.
    var attractionRadius: CGFloat = 0.18
    /// Snap preview requires this alignment or better.
    var alignmentRadius: CGFloat = 0.06
    /// Fraction of the remaining error closed per frame while attracting —
    /// critically damped in feel, no overshoot, and frame-rate scaled by the
    /// engine so behavior doesn't change with capture rate.
    var attractionGain: CGFloat = 0.25
    /// The user dragging farther than this from the candidate releases the
    /// magnet — explicit user override (spec §6).
    var releaseRadius: CGFloat = 0.30
    /// Consecutive qualifying frames required before locking; stops a
    /// single lucky frame from committing a lock.
    var framesToLock: Int = 3
    /// Seconds of degraded tracking before dropping to reacquisition.
    var degradedTimeout: TimeInterval = 1.0
    /// Seconds of failed reacquisition before returning to manual control.
    var reacquisitionTimeout: TimeInterval = 5.0

    static let `default` = SnapTuning()
}

// MARK: - Tracking

/// Health of the fast tracker for one target.
enum TrackingHealth: Equatable, Sendable {
    case healthy
    case degraded
    case lost
}

/// A committed target: the display the user locked onto, plus everything
/// needed to keep reading it as it moves (spec §8 "Store:").
struct TrackedTarget: Identifiable, Equatable, Sendable {
    let id: UUID
    /// Current screen geometry in frame space.
    var quad: ScreenQuad
    /// Geometry at lock time — the reference for scale/rotation deltas and the
    /// shape field coordinates were authored against.
    var referenceQuad: ScreenQuad
    /// Confidence from the detector at lock time.
    var detectionConfidence: Float
    /// Live confidence from the fast tracker.
    var trackingConfidence: Float
    var health: TrackingHealth
    /// Frame timestamp of the last successful geometry update.
    var lastUpdated: TimeInterval
    /// Frame timestamp when tracking last became degraded (drives the timeout).
    var degradedSince: TimeInterval?

    /// Apparent scale relative to lock time (1 = unchanged).
    var relativeScale: CGFloat {
        guard referenceQuad.area > 1e-9 else { return 1 }
        return (quad.area / referenceQuad.area).squareRoot()
    }

    /// In-plane rotation relative to lock time, radians.
    var relativeRoll: CGFloat { quad.rollAngle - referenceQuad.rollAngle }

    /// Maps canonical (target-relative) coordinates into the current frame.
    /// This is what keeps field regions glued to the display as it moves.
    var canonicalToFrame: Homography? {
        Homography.solve(from: .canonical, to: quad)
    }

    /// Maps frame coordinates into canonical screen space.
    var frameToCanonical: Homography? {
        Homography.toCanonical(from: quad)
    }

    init(id: UUID = UUID(),
         quad: ScreenQuad,
         referenceQuad: ScreenQuad? = nil,
         detectionConfidence: Float,
         trackingConfidence: Float = 1,
         health: TrackingHealth = .healthy,
         lastUpdated: TimeInterval = 0,
         degradedSince: TimeInterval? = nil) {
        self.id = id
        self.quad = quad
        self.referenceQuad = referenceQuad ?? quad
        self.detectionConfidence = detectionConfidence
        self.trackingConfidence = trackingConfidence
        self.health = health
        self.lastUpdated = lastUpdated
        self.degradedSince = degradedSince
    }
}

/// One frame's tracking update.
struct TrackingUpdate: Equatable, Sendable {
    var quad: ScreenQuad
    var confidence: Float
    var timestamp: TimeInterval
}

/// A frame-to-frame geometry tracker. Separate from `ScreenDetecting` because
/// the two run at deliberately different cadences: tracking is cheap and runs
/// often, detection is expensive and runs rarely (spec §9 hierarchical
/// tracking).
protocol ScreenTracking: Sendable {
    /// Begins tracking `quad` in `frame`. Any previous target is discarded.
    func startTracking(quad: ScreenQuad, in frame: TimestampedFrame) async

    /// Advances the tracker by one frame. Nil means the tracker failed on this
    /// frame — the caller decides whether that is degradation or loss.
    func track(frame: TimestampedFrame) async -> TrackingUpdate?

    /// Releases tracker resources.
    func reset() async
}
