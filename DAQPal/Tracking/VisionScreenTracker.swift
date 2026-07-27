//
//  VisionScreenTracker.swift
//  DAQPal
//
//  Stage 2 of hierarchical acquisition (spec §8/§9): the cheap frame-to-frame
//  geometry tracker that runs every frame between the expensive detection
//  passes. Detection proposes a quad once; this keeps it glued to the display.
//
//  The file is split three ways so that the policy the app ships is the policy
//  the tests exercise:
//
//  - `QuadSanity` — the pure geometric gates (winding continuity, area rate,
//    frame overlap). No state, no Vision.
//  - `DampedQuadTracker` — smoothing and jump-based confidence over externally
//    supplied observations.
//  - `TrackedQuadGate` — the composition of the two: what a tracker does with
//    one observation, including the rejection/recovery policy.
//  - `VisionScreenTracker` — a thin actor that turns `VNTrackRectangleRequest`
//    output into an observation and hands it to a `TrackedQuadGate`. It owns no
//    policy of its own, so exercising the gate exercises the shipped path.
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

// MARK: - Pure geometric gates

/// Stateless plausibility checks shared by every tracker in this file.
///
/// The thresholds are heuristics, not measured values. They exist to stop one
/// bad observation from propagating garbage geometry into the homography (which
/// would drag every field region with it); they are deliberately loose enough
/// that normal hand-held motion never trips them. Expected to move once there is
/// real device data.
enum QuadSanity {

    /// Largest area growth accepted over one reference interval. A display
    /// cannot triple its apparent area in one frame at capture rate.
    static let maxAreaGrowth: CGFloat = 3.0

    /// Upper bound, in reference intervals, on how far the area gate is relaxed
    /// for a long inter-frame gap. The pipeline drops frames under load, so a
    /// large delta across a gap is legitimate and a strictly per-frame gate
    /// would reject normal motion; without a cap, though, a long stall would
    /// disable the gate entirely.
    static let maxRelaxedIntervals: CGFloat = 4

    /// Frame bounds in normalized space. A tracked quad whose bounding box no
    /// longer intersects this at all has left the field of view.
    static let frameBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// How much better a rotated corner labeling has to fit before the identity
    /// labeling is treated as a relabel rather than as motion.
    static let relabelMargin: CGFloat = 2.0

    /// Bounding-box overlap that on its own identifies a re-seed candidate as
    /// the same display the tracker was following. Low deliberately: recovery
    /// exists precisely for the cases where the geometry changed a lot, so this
    /// is an identity check, not a similarity check.
    static let reseedMinimumIoU: CGFloat = 0.1

    /// Largest centre displacement accepted for a re-seed that does not overlap
    /// the previous quad at all, in multiples of the larger of the two quads'
    /// mean apparent size. Scaling by the target's own size is what makes the
    /// gate independent of how far away the display is: a screen filling the
    /// frame may legitimately have moved much further, in normalized units,
    /// than a small distant one. A heuristic, like the rest of `QuadSanity`.
    static let reseedMaxCentreOffset: CGFloat = 1.0

    /// Shoelace area *with* its sign. `ScreenQuad.area` takes the absolute
    /// value, which is exactly the information a winding check needs.
    static func signedArea(_ quad: ScreenQuad) -> CGFloat {
        let p = quad.corners
        var sum: CGFloat = 0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            sum += a.x * b.y - b.x * a.y
        }
        return sum / 2
    }

    /// Mean apparent edge length — the quad's own scale, used to make distance
    /// comparisons resolution- and distance-independent.
    static func meanSize(_ quad: ScreenQuad) -> CGFloat {
        (quad.meanWidth + quad.meanHeight) / 2
    }

    /// Accepted area-ratio band for an observation `dt` after the reference
    /// geometry. `maxAreaGrowth` is defined per reference interval and
    /// compounded over the elapsed time, so the gate is a *rate* limit rather
    /// than a per-frame limit — at the nominal frame interval it is exactly the
    /// ±3× band, and a gap of several dropped frames widens it accordingly.
    static func areaRatioBounds(dt: TimeInterval,
                                referenceInterval: TimeInterval) -> (min: CGFloat, max: CGFloat) {
        let interval = referenceInterval > 0 ? referenceInterval : 1.0 / 30.0
        let elapsed = dt.isFinite && dt > 0 ? dt : interval
        let intervals = CGFloat(elapsed / interval)
        let exponent = min(max(intervals, 1), maxRelaxedIntervals)
        let growth = pow(maxAreaGrowth, exponent)
        return (1 / growth, growth)
    }

    /// True when any part of the quad's bounding box is still on screen.
    static func intersectsFrame(_ quad: ScreenQuad) -> Bool {
        let visible = quad.boundingBox.cgRect.intersection(frameBounds)
        return !visible.isNull && visible.width > 0 && visible.height > 0
    }

    /// True when `observed` can be read as the same physical screen, in the same
    /// corner labeling, as `previous`.
    ///
    /// `ScreenQuad`'s corner names are semantic, and every `ScreenField` region
    /// is authored in the canonical space those names define. A detector that
    /// hands the same four points back in different slots therefore does not
    /// produce a wrong-looking quad — it produces a *correct-looking* quad whose
    /// canonical→frame homography is mirrored or rotated, and every field reads
    /// the wrong part of the display. Convexity, area and frame-overlap all pass
    /// on such a frame, so relabelling has to be caught on its own terms:
    ///
    /// - A reflection (e.g. top and bottom corners swapped) reverses the
    ///   winding, which shows up as a sign flip of the signed area.
    /// - A cyclic relabel preserves the winding, so it is caught by comparing
    ///   fits: if some rotation of the labels matches `previous` far better than
    ///   the identity labeling does, the identity labeling is not motion.
    static func isOrientationContinuous(previous: ScreenQuad, observed: ScreenQuad) -> Bool {
        let before = signedArea(previous), after = signedArea(observed)
        guard abs(before) > 1e-9, abs(after) > 1e-9 else { return false }
        guard (before > 0) == (after > 0) else { return false }

        let identity = previous.meanCornerDistance(to: observed)
        // Only worth asking when the identity fit is already poor: for small
        // frame-to-frame motion every rotated labeling is worse anyway, and
        // running the comparison on noise would reject healthy frames.
        let scale = max(meanSize(previous), meanSize(observed))
        guard identity > 0.5 * scale else { return true }

        let p = previous.corners, o = observed.corners
        var best = CGFloat.greatestFiniteMagnitude
        for shift in 1...3 {
            var sum: CGFloat = 0
            for i in 0..<4 {
                sum += ScreenQuad.distance(p[i], o[(i + shift) % 4])
            }
            best = min(best, sum / 4)
        }
        return best * relabelMargin >= identity
    }

    /// True when `observed` is close enough to `previous` to be believable as
    /// the *same* display after a run of failed frames.
    ///
    /// This is the identity half of recovery. Re-seeding deliberately skips the
    /// area-rate gate — that gate is exactly what a legitimate large change
    /// trips — but skipping proximity as well would let the tracker adopt any
    /// plausible quad that happened to arrive next. Every `ScreenField` region
    /// is a canonical-space projection of the tracked quad, so a lock that
    /// migrates to unrelated geometry does not fail loudly: it keeps reporting
    /// a healthy tracked target while every value is read off the wrong
    /// display. Staying rejected is strictly better than that.
    ///
    /// Two ways to pass, because the two failure modes differ in shape:
    /// bounding-box overlap catches a target that grew, shrank or was
    /// re-detected slightly offset, and a size-scaled centre distance catches a
    /// target that translated bodily while the boxes stopped overlapping.
    static func isPlausibleReseed(previous: ScreenQuad, observed: ScreenQuad) -> Bool {
        if previous.boundingBoxIoU(with: observed) >= reseedMinimumIoU { return true }
        let scale = max(meanSize(previous), meanSize(observed))
        guard scale.isFinite, scale > 1e-9 else { return false }
        let offset = ScreenQuad.distance(previous.center, observed.center)
        return offset <= reseedMaxCentreOffset * scale
    }
}

// MARK: - Vision tracker

/// Frame-to-frame screen tracking backed by `VNTrackRectangleRequest`.
///
/// **Why this is an `actor`.** `VNSequenceRequestHandler` carries mutable
/// per-sequence state and is explicitly *not* safe for concurrent use: two
/// overlapping `perform` calls on one handler corrupt the sequence. Actor
/// isolation is the enforcement mechanism — the handler is stored as isolated
/// state and never escapes (no closure captures it, it is never returned, and
/// nothing hands it to another isolation domain), so `perform` is serialized by
/// construction rather than by convention. The same rule covers the request
/// object, whose `inputObservation` is mutated once per frame.
///
/// **Where the policy lives.** Vision contributes a raw quad and its own
/// confidence score; every decision made about them — smoothing, the sanity
/// gates, the confidence actually reported, recovery after repeated failure —
/// is `TrackedQuadGate`'s. That split is deliberate: `VNTrackRectangleRequest`
/// needs a real image sequence and cannot be driven by synthetic single frames,
/// so keeping this type free of policy is what makes the shipped decision path
/// testable at all.
///
/// Per the pipeline's "never break the frame loop" rule, nothing here throws:
/// a Vision failure, an implausible result, or a lost target all surface as
/// `nil` and the caller decides whether that is degradation or loss.
actor VisionScreenTracker: ScreenTracking {

    // MARK: - Isolated state

    private var sequenceHandler: VNSequenceRequestHandler?
    private var request: VNTrackRectangleRequest?
    /// The observation fed to the next frame. `VNTrackRectangleRequest` chains:
    /// each frame's result becomes the next frame's input.
    private var lastObservation: VNRectangleObservation?
    /// All smoothing, gating and confidence policy for the shipped path.
    private var gate: TrackedQuadGate

    init(damping: DampedQuadTracker = DampedQuadTracker()) {
        self.gate = TrackedQuadGate(damping: damping)
    }

    // MARK: - ScreenTracking

    func startTracking(quad: ScreenQuad, in frame: TimestampedFrame) async {
        // Retire the outgoing sequence before building a new one, both to return
        // its tracker to Vision's pool and because a fresh handler per target is
        // required for correctness: a reused handler carries the previous
        // sequence's appearance model, and nothing in the API lets a caller
        // clear it, so the new target would be matched against the old one's
        // model with no way to tell that it happened.
        releaseTracker(finalFrame: frame)

        gate.reset()
        guard gate.seed(quad: quad, at: frame.timestamp) else { return }

        let handler = VNSequenceRequestHandler()
        let seed = Self.visionObservation(from: quad)
        let trackRequest = VNTrackRectangleRequest(rectangleObservation: seed)
        trackRequest.trackingLevel = .accurate

        sequenceHandler = handler
        request = trackRequest
        lastObservation = seed

        // Performing once on the seed frame is what actually initializes
        // Vision's appearance model from the image the quad was measured in.
        // Its refined observation, when there is one, becomes the chain's head;
        // otherwise the constructed seed stands and tracking starts on the next
        // frame instead. This costs a full Vision pass, so it is timed like one.
        let refined = PipelineMetrics.shared.measure(.tracking) { () -> VNRectangleObservation? in
            perform(trackRequest, on: frame, using: handler)
        }
        if let refined {
            lastObservation = refined
        }
    }

    func track(frame: TimestampedFrame) async -> TrackingUpdate? {
        guard let handler = sequenceHandler,
              let trackRequest = request,
              let input = lastObservation else { return nil }

        trackRequest.inputObservation = input

        let observation = PipelineMetrics.shared.measure(.tracking) { () -> VNRectangleObservation? in
            perform(trackRequest, on: frame, using: handler)
        }
        guard let observation else { return nil }

        let observed = Self.quad(from: observation)
        let outcome = gate.admit(observed,
                                 visionConfidence: observation.confidence,
                                 at: frame.timestamp)

        switch outcome {
        case .accepted(let update), .reseeded(let update):
            // Only a result the gate kept is chained forward; a rejected frame
            // leaves the last good observation as the input, so the tracker
            // coasts rather than locking onto whatever the bad frame found.
            lastObservation = observation
            return update
        case .rejected:
            return nil
        }
    }

    func reset() {
        releaseTracker(finalFrame: nil)
        gate.reset()
    }

    // MARK: - Vision plumbing

    /// Retires the current tracking sequence.
    ///
    /// `VNTrackingRequest.isLastFrame` is documented as the signal that returns a
    /// tracker to Vision's pool, and that pool is finite —
    /// `supportedNumberOfTrackersAndReturnError` reports its size. Dropping the
    /// request without setting it strands one tracker per lock cycle, so both
    /// the re-seed path and `reset()` come through here. When a frame is
    /// available the final request is also performed, which is what lets Vision
    /// act on the flag rather than merely observe it.
    private func releaseTracker(finalFrame: TimestampedFrame?) {
        defer {
            request = nil
            sequenceHandler = nil
            lastObservation = nil
        }
        guard let trackRequest = request else { return }
        trackRequest.isLastFrame = true
        guard let handler = sequenceHandler, let frame = finalFrame else { return }
        if let input = lastObservation {
            trackRequest.inputObservation = input
        }
        _ = PipelineMetrics.shared.measure(.tracking) { () -> VNRectangleObservation? in
            perform(trackRequest, on: frame, using: handler)
        }
    }

    /// The one place `perform` is called. Kept `private` and non-escaping so the
    /// handler stays inside the actor (see the type doc).
    private func perform(_ trackRequest: VNTrackRectangleRequest,
                         on frame: TimestampedFrame,
                         using handler: VNSequenceRequestHandler) -> VNRectangleObservation? {
        // Buffers reach this layer already portrait-upright, so `.up` is right —
        // same assumption as VisionOCR.
        do {
            try handler.perform([trackRequest], on: frame.pixelBuffer)
        } catch {
            return nil
        }
        return trackRequest.results?.first as? VNRectangleObservation
    }

    // MARK: - Coordinate conversion
    //
    // The project convention is normalized 0...1 with a TOP-LEFT origin; Vision
    // is normalized 0...1 with a BOTTOM-LEFT origin. Flipping y is the whole
    // transform (`VisionOCR` does the same for `regionOfInterest`).
    //
    // The flip is its own inverse, and it maps a corner onto the corner with the
    // same *visual* position — the upper-left of the image is `topLeft` in both
    // conventions — so corners are assigned by name, never by array index. What
    // the flip does change is winding: TL→TR→BR→BL is clockwise in top-left
    // space and counter-clockwise in Vision's, which is exactly why an
    // index-order copy would silently mis-label two corners.
    //
    // Caveat worth stating: `ScreenQuad`'s names are *semantic* (which corner of
    // the physical screen), while Vision's are positional in its own space. A
    // display rolled far enough can therefore come back with its corners in
    // different slots; that is a relabel, not motion, and `QuadSanity`'s
    // orientation-continuity check is what rejects the frame instead of letting
    // the mirrored homography through.

    private static func flipY(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: 1 - p.y)
    }

    static func visionObservation(from quad: ScreenQuad) -> VNRectangleObservation {
        VNRectangleObservation(requestRevision: VNDetectRectanglesRequestRevision1,
                               topLeft: flipY(quad.topLeft),
                               topRight: flipY(quad.topRight),
                               bottomRight: flipY(quad.bottomRight),
                               bottomLeft: flipY(quad.bottomLeft))
    }

    static func quad(from observation: VNRectangleObservation) -> ScreenQuad {
        ScreenQuad(topLeft: flipY(observation.topLeft),
                   topRight: flipY(observation.topRight),
                   bottomRight: flipY(observation.bottomRight),
                   bottomLeft: flipY(observation.bottomLeft))
    }
}

// MARK: - Observation policy

/// What a tracker does with one observation: gate it, smooth it, score it, and
/// decide when repeated failure means the target has genuinely moved rather than
/// that the observation is bad.
///
/// This is the shipped decision path. `VisionScreenTracker` owns the Vision
/// plumbing and nothing else; the synthetic/Simulator path, where the
/// "observation" comes from the renderer's own pose, goes through the same type.
struct TrackedQuadGate: Sendable {

    /// Consecutive rejections after which the next otherwise-plausible
    /// observation is taken as a re-seed instead of being rejected again.
    ///
    /// Without this a single legitimate large geometry change — the user walking
    /// up to the instrument, or a burst of dropped frames — would put the
    /// tracker in a state where the reference geometry never advances and every
    /// subsequent frame fails the same gate, permanently.
    static let rejectionsBeforeReseed = 5

    /// Confidence reported for a re-seeded frame.
    ///
    /// Chosen to sit strictly between `SnapTuning.lostTracking` (0.30) and
    /// `SnapTuning.degradedTracking` (0.55), and reported as-is rather than
    /// attenuated by Vision's score. A re-seed is a statement about the
    /// *tracker's* state — the lock was just re-established on geometry that
    /// passed every identity gate — so it must surface as degraded tracking
    /// that has to re-earn its confidence, and never as `.lost`.
    ///
    /// Blending Vision's uncalibrated score in here made the recovery frame
    /// strictly worse than the rejection it replaces: a rejection returns nil
    /// and leaves the snap engine's hysteresis in charge, whereas a confidence
    /// under `lostTracking` forces reacquisition on the very frame the tracker
    /// recovered.
    static let reseedConfidence: Float = 0.5

    /// Smallest multiplier Vision's own confidence can apply. See `admit`.
    static let visionConfidenceFloor: Float = 0.5

    /// Smoothing and jump-based confidence.
    private(set) var damping: DampedQuadTracker
    /// Last geometry published, and the reference for the continuity gates.
    private(set) var lastAccepted: ScreenQuad?
    private(set) var consecutiveRejections: Int

    init(damping: DampedQuadTracker = DampedQuadTracker()) {
        self.damping = damping
        self.lastAccepted = nil
        self.consecutiveRejections = 0
    }

    /// Why a frame was not used. Carried out of `admit` so the reason is
    /// assertable rather than collapsed into `nil`.
    enum Rejection: Equatable, Sendable {
        case nonConvex
        case offFrame
        case orientation
        case areaRate
        /// Recovery only: the observation was plausible in itself but was not
        /// near the last known good geometry, so adopting it would have
        /// migrated the lock to a different display.
        case proximity
        case smoothingFailed
    }

    enum Outcome: Equatable, Sendable {
        /// Normal tracked frame.
        case accepted(TrackingUpdate)
        /// Recovery: the gates had been failing long enough that this
        /// observation was taken as the new reference geometry.
        case reseeded(TrackingUpdate)
        case rejected(Rejection)

        var update: TrackingUpdate? {
            switch self {
            case .accepted(let u), .reseeded(let u): u
            case .rejected: nil
            }
        }

        var rejection: Rejection? {
            if case .rejected(let r) = self { return r }
            return nil
        }
    }

    /// Establishes the reference geometry, discarding any previous target.
    /// Returns false for a seed that has no solvable geometry — accepting one
    /// would poison every subsequent frame with no failure signal.
    @discardableResult
    mutating func seed(quad: ScreenQuad, at timestamp: TimeInterval) -> Bool {
        guard damping.start(quad: quad, at: timestamp) else {
            lastAccepted = nil
            consecutiveRejections = 0
            return false
        }
        lastAccepted = quad
        consecutiveRejections = 0
        return true
    }

    mutating func reset() {
        damping.reset()
        lastAccepted = nil
        consecutiveRejections = 0
    }

    /// Folds one observation into the tracked estimate.
    ///
    /// **Confidence rule.** `visionConfidence` and the damped tracker's
    /// jump-based confidence measure different things: Vision's is an
    /// uncalibrated appearance score, the damped one is a geometric
    /// plausibility score expressed in the units this app's thresholds
    /// (`SnapTuning.degradedTracking`, `SnapTuning.lostTracking`) were written
    /// against. Feeding Vision's number straight into those thresholds compares
    /// two different scales. So Vision *attenuates* rather than decides: the
    /// reported confidence is
    ///
    ///     damped × (floor + (1 - floor) × vision)
    ///
    /// with `floor = visionConfidenceFloor`. Vision at 1 leaves the geometric
    /// score untouched; Vision at 0 halves it, which can push a marginal frame
    /// under the degraded threshold but cannot on its own declare a steady,
    /// geometrically consistent target lost. Neither term is calibrated against
    /// device data.
    ///
    /// A re-seeded frame is the one exception: it reports `reseedConfidence`
    /// flat, because what it is describing is the tracker's own state and not a
    /// measurement of this observation's quality.
    ///
    /// **Recovery rule.** After `rejectionsBeforeReseed` consecutive rejections
    /// — of any kind — the next observation is taken as the new reference
    /// geometry rather than rejected again, which is what stops one legitimate
    /// large change from wedging the tracker forever. Recovery relaxes the
    /// area-rate gate only. Convexity, frame overlap, orientation continuity
    /// and `QuadSanity.isPlausibleReseed` all still apply, so a re-seed can
    /// change the target's size but not its identity.
    mutating func admit(_ observed: ScreenQuad,
                        visionConfidence: Float,
                        at timestamp: TimeInterval) -> Outcome {
        guard observed.isConvex else { return reject(.nonConvex) }
        guard QuadSanity.intersectsFrame(observed) else { return reject(.offFrame) }

        let recovering = consecutiveRejections >= Self.rejectionsBeforeReseed

        if let previous = lastAccepted {
            // A relabel is never acceptable, recovering or not: re-seeding onto
            // a mirrored labeling would silently mirror canonical space instead
            // of recovering from it.
            guard QuadSanity.isOrientationContinuous(previous: previous, observed: observed) else {
                return reject(.orientation)
            }
            if recovering {
                // Recovery relaxes the area-rate gate but not identity: a
                // re-seed has to be the same display, or the lock silently
                // migrates and every field is read off the wrong screen.
                guard QuadSanity.isPlausibleReseed(previous: previous, observed: observed) else {
                    return reject(.proximity)
                }
            } else if previous.area > 1e-9 {
                let dt = damping.lastTimestamp.map { timestamp - $0 } ?? damping.referenceInterval
                let bounds = QuadSanity.areaRatioBounds(dt: dt,
                                                        referenceInterval: damping.referenceInterval)
                let ratio = observed.area / previous.area
                guard ratio >= bounds.min, ratio <= bounds.max else { return reject(.areaRate) }
            }
        }

        if recovering {
            guard seed(quad: observed, at: timestamp) else { return reject(.smoothingFailed) }
            return .reseeded(TrackingUpdate(quad: observed,
                                            confidence: Self.reseedConfidence,
                                            timestamp: timestamp))
        }

        guard let update = damping.update(observed: observed, at: timestamp) else {
            return reject(.smoothingFailed)
        }
        consecutiveRejections = 0
        lastAccepted = update.quad
        return .accepted(TrackingUpdate(quad: update.quad,
                                        confidence: Self.blend(damped: update.confidence,
                                                               vision: visionConfidence),
                                        timestamp: update.timestamp))
    }

    static func blend(damped: Float, vision: Float) -> Float {
        let v = min(max(vision.isFinite ? vision : 0, 0), 1)
        let weight = visionConfidenceFloor + (1 - visionConfidenceFloor) * v
        return min(max(damped * weight, 0), 1)
    }

    private mutating func reject(_ reason: Rejection) -> Outcome {
        consecutiveRejections += 1
        return .rejected(reason)
    }
}

// MARK: - Damped tracker

/// Corner-wise damped tracker over externally supplied observations.
///
/// Policy, in two parts:
/// - **Damping.** Each update closes a fraction of the remaining corner error
///   toward the observation. The fraction is frame-rate scaled — `responsiveness`
///   is defined per `referenceInterval`, and the per-update factor is
///   `1 - (1 - responsiveness)^(dt / referenceInterval)` — so the tracker feels
///   the same at 12 fps and 60 fps instead of getting sluggish when capture
///   slows down.
/// - **Confidence.** Derived from how far the observation jumped, normalized
///   two ways. By the *smaller* of the tracked and observed apparent sizes, so
///   it is scale-free and so an implausibly large observation cannot buy itself
///   a better score than a small one by inflating its own denominator. And by
///   the elapsed time, expressed per `referenceInterval`, so identical physical
///   motion yields the same confidence at any capture rate — without that, a
///   frame drop under CPU load would look like a tracking failure.
///
/// Corner-wise interpolation of two convex quads with the same winding is
/// convex, so smoothing cannot manufacture unsolvable geometry; the result is
/// checked anyway and a non-convex outcome is reported as a failed frame rather
/// than propagated.
struct DampedQuadTracker: Equatable, Sendable {

    // Tuning is stored privately and validated on every write. These are public
    // knobs, and the values that break the filter break it silently: a
    // non-positive `referenceInterval` freezes damping, and a zero
    // `jumpTolerance` makes every confidence NaN, which compares false against
    // every threshold and so defeats the degraded/lost logic entirely.
    private var storedResponsiveness: CGFloat
    private var storedReferenceInterval: TimeInterval
    private var storedJumpTolerance: CGFloat

    /// Fraction of the remaining corner error closed in one `referenceInterval`.
    /// 1 disables smoothing (follow the observation exactly). Clamped to 0...1.
    var responsiveness: CGFloat {
        get { storedResponsiveness }
        set { storedResponsiveness = Self.validResponsiveness(newValue) }
    }

    /// The frame interval `responsiveness` is expressed against. Must be
    /// positive; anything else falls back to 1/30 s.
    var referenceInterval: TimeInterval {
        get { storedReferenceInterval }
        set { storedReferenceInterval = Self.validInterval(newValue) }
    }

    /// Corner jump, as a fraction of the target's mean apparent size per
    /// reference interval, at which confidence reaches zero. A heuristic: a jump
    /// the size of the display itself is not the same display any more. Must be
    /// positive.
    var jumpTolerance: CGFloat {
        get { storedJumpTolerance }
        set { storedJumpTolerance = Self.validTolerance(newValue) }
    }

    private(set) var quad: ScreenQuad?
    private(set) var confidence: Float
    private(set) var lastTimestamp: TimeInterval?

    init(responsiveness: CGFloat = 0.5,
         referenceInterval: TimeInterval = 1.0 / 30.0,
         jumpTolerance: CGFloat = 1.0) {
        self.storedResponsiveness = Self.validResponsiveness(responsiveness)
        self.storedReferenceInterval = Self.validInterval(referenceInterval)
        self.storedJumpTolerance = Self.validTolerance(jumpTolerance)
        self.quad = nil
        self.confidence = 0
        self.lastTimestamp = nil
    }

    private static func validResponsiveness(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0.5 }
        return min(max(value, 0), 1)
    }

    private static func validInterval(_ value: TimeInterval) -> TimeInterval {
        (value.isFinite && value > 0) ? value : 1.0 / 30.0
    }

    private static func validTolerance(_ value: CGFloat) -> CGFloat {
        (value.isFinite && value > 0) ? value : 1.0
    }

    /// Seeds the tracker, discarding any previous target. Returns false for a
    /// quad with no solvable geometry: adopting one would leave the tracker in a
    /// state where every later update smooths toward garbage, and the caller
    /// would have no signal that it happened.
    @discardableResult
    mutating func start(quad: ScreenQuad, at timestamp: TimeInterval = 0) -> Bool {
        guard quad.isConvex else {
            reset()
            return false
        }
        self.quad = quad
        self.confidence = 1
        self.lastTimestamp = timestamp
        return true
    }

    mutating func reset() {
        quad = nil
        confidence = 0
        lastTimestamp = nil
    }

    /// Folds one observation into the smoothed estimate.
    ///
    /// Returns nil for a frame that produced no usable geometry — a non-convex
    /// observation, an area change faster than `QuadSanity` allows, or a
    /// smoothed result that came out non-convex — leaving the previous estimate
    /// untouched so the caller can coast.
    @discardableResult
    mutating func update(observed: ScreenQuad, at timestamp: TimeInterval) -> TrackingUpdate? {
        guard observed.isConvex else { return nil }

        guard let current = quad else {
            guard start(quad: observed, at: timestamp) else { return nil }
            return TrackingUpdate(quad: observed, confidence: 1, timestamp: timestamp)
        }

        let elapsed = lastTimestamp.map { timestamp - $0 } ?? referenceInterval
        // A zero or backwards timestamp would freeze the tracker; fall back to
        // one reference frame's worth of motion rather than silently stalling.
        let dt = elapsed > 0 ? elapsed : referenceInterval

        if current.area > 1e-9 {
            let bounds = QuadSanity.areaRatioBounds(dt: dt, referenceInterval: referenceInterval)
            let ratio = observed.area / current.area
            guard ratio >= bounds.min, ratio <= bounds.max else { return nil }
        }

        let t = dampingFactor(dt: dt)
        let smoothed = current.interpolated(toward: observed, t: t)
        guard smoothed.isConvex else { return nil }

        let jumped = current.meanCornerDistance(to: observed)
        let scale = max(min(QuadSanity.meanSize(current), QuadSanity.meanSize(observed)), 1e-9)
        let perInterval = CGFloat(referenceInterval / dt)
        let normalizedJump = (jumped / scale) * perInterval
        let raw = 1 - normalizedJump / jumpTolerance

        quad = smoothed
        confidence = Float(min(max(raw.isFinite ? raw : 0, 0), 1))
        lastTimestamp = timestamp

        return TrackingUpdate(quad: smoothed, confidence: confidence, timestamp: timestamp)
    }

    /// Frame-rate-scaled interpolation fraction for an elapsed time of `dt`.
    func dampingFactor(dt: TimeInterval) -> CGFloat {
        guard responsiveness < 1 else { return 1 }
        guard responsiveness > 0 else { return 0 }
        let frames = CGFloat(dt / referenceInterval)
        return min(max(1 - pow(1 - responsiveness, frames), 0), 1)
    }
}
