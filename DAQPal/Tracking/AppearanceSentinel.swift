//
//  AppearanceSentinel.swift
//  DAQPal
//
//  The between-detection-passes defense against the false healthy-lock
//  (ARCHITECTURE.md §11). `TrackVerifier` can only testify on frames where the
//  detector ran (every 0.5 s while locked); between passes, a tracked quad
//  that has drifted onto background is invisible to every existing check —
//  the tracker's own confidence is self-referential (jump magnitude), so a
//  parked quad reports healthy forever.
//
//  This type watches the one signal that needs no detector: WHAT THE LOCKED
//  QUAD LOOKS LIKE. At lock commit it samples a small reference luma patch
//  from inside the locked quad (bilinear reads straight off the BGRA buffer
//  through the quad's canonical→frame homography — no CoreImage, no Vision;
//  ~640 samples, far under a millisecond). Every frame while locked it
//  samples the current tracked quad and compares:
//
//  - **Zero-mean NCC** against the reference. A quad still attached to its
//    display correlates highly with what it looked like at lock; a quad
//    parked on background correlates with nothing.
//  - **Variance collapse.** A display panel is *structured* (bezel edges,
//    segment digits, label text); flat background is not. A current patch
//    whose variance has collapsed to a small fraction of the reference's is
//    an instant failure regardless of NCC (NCC is undefined/meaningless on a
//    flat patch).
//
//  `consecutiveFailuresToVeto` consecutive failing frames — not one, because
//  a single frame can be ruined by autofocus hunting or a hand crossing the
//  lens — are a HARD VETO, handled by the pipeline exactly like a DIVERGED
//  detection verdict: tracking confidence forced to zero, same-frame
//  reacquisition, `measurementsValid` false.
//
//  **Why legitimate digit changes never decay similarity:** the reference is
//  refreshed on every CORROBORATED detection pass, so it is never older than
//  the last time the detector independently blessed the geometry (≤ ~0.5 s
//  while healthy). Digits are also a small fraction of the patch — panel
//  structure dominates the correlation — so even between refreshes a value
//  change moves NCC by little.
//
//  Failure posture, stated plainly: when the sentinel CANNOT judge — no
//  reference, unsampleable pixel format, degenerate quad — it abstains. An
//  abstaining sentinel never vetoes and never blesses; the verifier and snap
//  hysteresis remain the only authorities. It is an added tripwire, not a
//  replacement gate.
//
//  Pure value type, deterministic, no Date(). Not a claim of measured device
//  latency: the ~sub-millisecond budget is arithmetic (640 bilinear taps),
//  not an Instruments figure.
//

import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Luma patch

/// A small grid of luma samples taken from inside a quad via its
/// canonical→frame homography. The appearance fingerprint the sentinel
/// compares.
struct LumaPatch: Equatable, Sendable {
    let width: Int
    let height: Int
    /// Row-major luma values, 0...255 scale.
    let values: [Float]
    let mean: Float
    /// Population variance, 0...255² scale.
    let variance: Float

    /// Samples a `width`×`height` luma grid from `quad`'s interior.
    ///
    /// - The grid covers the quad inset by `inset` on every canonical side,
    ///   so bezel-boundary antialiasing and background bleed at the exact
    ///   edge do not enter the fingerprint.
    /// - Coordinates outside the frame clamp to the frame edge (a quad
    ///   partially off-screen — §11's was pinned at the bottom — samples
    ///   replicated edge pixels, which reads as the flat background it is).
    /// - Returns nil when the buffer is not 32BGRA, the base address is
    ///   unavailable, or the quad has no solvable homography. Callers treat
    ///   nil as "cannot judge", never as failure evidence.
    static func sample(from pixelBuffer: CVPixelBuffer,
                       quad: ScreenQuad,
                       width: Int = 32,
                       height: Int = 20,
                       inset: CGFloat = 0.08) -> LumaPatch? {
        guard width > 0, height > 0 else { return nil }
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        guard let homography = Homography.solve(from: .canonical, to: quad) else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
        let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard bufferWidth > 0, bufferHeight > 0 else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)

        let clampedInset = min(max(inset, 0), 0.45)
        let span = 1 - 2 * clampedInset

        var values = [Float]()
        values.reserveCapacity(width * height)
        var sum: Float = 0
        var sumSquares: Float = 0

        for row in 0..<height {
            let v = clampedInset + span * (CGFloat(row) + 0.5) / CGFloat(height)
            for col in 0..<width {
                let u = clampedInset + span * (CGFloat(col) + 0.5) / CGFloat(width)
                guard let mapped = homography.apply(CGPoint(x: u, y: v)) else { return nil }
                // Normalized top-left-origin frame space → continuous pixel
                // coordinates, clamped to the addressable range.
                let px = min(max(mapped.x, 0), 1) * CGFloat(bufferWidth - 1)
                let py = min(max(mapped.y, 0), 1) * CGFloat(bufferHeight - 1)

                let x0 = Int(px), y0 = Int(py)
                let x1 = min(x0 + 1, bufferWidth - 1)
                let y1 = min(y0 + 1, bufferHeight - 1)
                let fx = Float(px - CGFloat(x0))
                let fy = Float(py - CGFloat(y0))

                @inline(__always)
                func luma(_ x: Int, _ y: Int) -> Float {
                    let p = y * bytesPerRow + x * 4
                    // BGRA byte order; BT.601 weights.
                    let b = Float(bytes[p])
                    let g = Float(bytes[p + 1])
                    let r = Float(bytes[p + 2])
                    return 0.114 * b + 0.587 * g + 0.299 * r
                }

                let top = luma(x0, y0) * (1 - fx) + luma(x1, y0) * fx
                let bottom = luma(x0, y1) * (1 - fx) + luma(x1, y1) * fx
                let value = top * (1 - fy) + bottom * fy
                values.append(value)
                sum += value
                sumSquares += value * value
            }
        }

        let count = Float(values.count)
        let mean = sum / count
        let variance = max(sumSquares / count - mean * mean, 0)
        return LumaPatch(width: width, height: height,
                         values: values, mean: mean, variance: variance)
    }

    /// Zero-mean normalized cross-correlation of two same-shape patches,
    /// in -1...1. Nil when the shapes differ or either patch is too flat for
    /// the correlation to mean anything (near-zero variance — the variance
    /// collapse check owns that regime).
    static func ncc(_ a: LumaPatch, _ b: LumaPatch) -> Float? {
        guard a.width == b.width, a.height == b.height,
              a.values.count == b.values.count, !a.values.isEmpty else { return nil }
        let epsilon: Float = 1e-3
        guard a.variance > epsilon, b.variance > epsilon else { return nil }
        var cross: Float = 0
        for i in 0..<a.values.count {
            cross += (a.values[i] - a.mean) * (b.values[i] - b.mean)
        }
        let n = Float(a.values.count)
        let denominator = n * (a.variance * b.variance).squareRoot()
        guard denominator > 0 else { return nil }
        return min(max(cross / denominator, -1), 1)
    }
}

// MARK: - Sentinel

/// Per-frame appearance verification of a locked quad. See the file header
/// for the mechanism and failure posture.
struct AppearanceSentinel: Sendable, Equatable {

    struct Config: Sendable, Equatable {
        /// Patch grid size. 32×20 ≈ the display's own aspect, 640 taps.
        var patchWidth: Int
        var patchHeight: Int
        /// Canonical-space inset before sampling (see `LumaPatch.sample`).
        var inset: CGFloat
        /// NCC below this is a failing frame. Heuristic: an attached quad on
        /// the same panel correlates near 1 even with digits changing;
        /// background correlates near 0.
        var nccVetoThreshold: Float
        /// Current-patch variance below this fraction of the reference's is
        /// variance collapse — the parked-on-flat-background signature.
        var varianceCollapseFraction: Float
        /// The reference must itself be at least this structured (variance,
        /// 0...255² scale — 25 ≈ a σ of 5 luma levels) for the collapse check
        /// to run; judging collapse against an unstructured reference would
        /// veto real flat-faced displays.
        var minimumReferenceVariance: Float
        /// Consecutive failing frames before the hard veto. One bad frame is
        /// noise (autofocus hunt, hand over lens); K in a row while the
        /// tracker claims health is a dead lock.
        var consecutiveFailuresToVeto: Int

        init(patchWidth: Int = 32,
             patchHeight: Int = 20,
             inset: CGFloat = 0.08,
             nccVetoThreshold: Float = 0.35,
             varianceCollapseFraction: Float = 0.05,
             minimumReferenceVariance: Float = 25,
             consecutiveFailuresToVeto: Int = 4) {
            self.patchWidth = patchWidth
            self.patchHeight = patchHeight
            self.inset = inset
            self.nccVetoThreshold = nccVetoThreshold
            self.varianceCollapseFraction = varianceCollapseFraction
            self.minimumReferenceVariance = minimumReferenceVariance
            self.consecutiveFailuresToVeto = consecutiveFailuresToVeto
        }
    }

    enum Verdict: Equatable, Sendable {
        /// The current patch matches the reference.
        case healthy(ncc: Float?)
        /// This frame failed, but fewer than `consecutiveFailuresToVeto` in a
        /// row have — no action yet.
        case suspect(ncc: Float?, consecutiveFailures: Int)
        /// Hard veto: the quad no longer looks like what was locked. Sticky
        /// until the reference is refreshed by independent (detector)
        /// corroboration or the lock is torn down.
        case vetoed(ncc: Float?)
        /// The sentinel cannot judge (no reference, unsampleable frame).
        /// Never counts for or against the lock.
        case abstained
    }

    var config: Config

    private(set) var reference: LumaPatch?
    private(set) var consecutiveFailures = 0
    private(set) var isVetoed = false
    /// Most recent NCC, exposed for telemetry/debug overlays. Nil when the
    /// last frame was unsampleable or either patch was too flat to correlate.
    private(set) var lastNCC: Float?

    init(config: Config = Config()) {
        self.config = config
    }

    /// A vetoed sentinel is the only unhealthy state; abstention is healthy
    /// by design (see failure posture in the header).
    var isHealthy: Bool { !isVetoed }

    // MARK: Lifecycle

    /// Captures the reference fingerprint at lock commit. Failing to sample
    /// (wrong format, degenerate quad) leaves the sentinel abstaining for the
    /// life of the lock rather than guessing.
    mutating func beginLock(pixelBuffer: CVPixelBuffer, quad: ScreenQuad) {
        reference = samplePatch(pixelBuffer: pixelBuffer, quad: quad)
        consecutiveFailures = 0
        isVetoed = false
        lastNCC = nil
    }

    /// Re-captures the reference. Call on every CORROBORATED detection pass:
    /// the detector just independently blessed this geometry, so what it
    /// looks like right now IS the lock's appearance — this is what keeps
    /// legitimate digit changes from ever decaying similarity. Clears any
    /// standing veto for the same reason a corroborated pass clears a
    /// verifier divergence: fresh independent evidence outranks stale
    /// appearance memory.
    mutating func refreshReference(pixelBuffer: CVPixelBuffer, quad: ScreenQuad) {
        guard let fresh = samplePatch(pixelBuffer: pixelBuffer, quad: quad) else { return }
        reference = fresh
        consecutiveFailures = 0
        isVetoed = false
    }

    /// Clears BOTH signals: the per-frame NCC path and the content-consistency
    /// path. A lock teardown must not leave a stale structural reference behind.
    mutating func reset() {
        reference = nil
        consecutiveFailures = 0
        isVetoed = false
        lastNCC = nil
    }

    // MARK: Per-frame evaluation

    /// Compares the current tracked quad's appearance against the reference.
    /// Call once per frame while locked.
    mutating func evaluate(pixelBuffer: CVPixelBuffer, quad: ScreenQuad) -> Verdict {
        guard let reference else {
            lastNCC = nil
            return .abstained
        }
        guard let current = samplePatch(pixelBuffer: pixelBuffer, quad: quad) else {
            // An unsampleable FRAME is not evidence about the lock; it does
            // not advance the failure count and does not clear it either.
            lastNCC = nil
            return isVetoed ? .vetoed(ncc: nil) : .abstained
        }

        let ncc = LumaPatch.ncc(reference, current)
        lastNCC = ncc

        let collapsed = reference.variance >= config.minimumReferenceVariance
            && current.variance < config.varianceCollapseFraction * reference.variance
        let nccFailed = ncc.map { $0 < config.nccVetoThreshold } ?? false
        let failed = collapsed || nccFailed

        if isVetoed {
            // Sticky until refreshed by corroboration or reset by teardown —
            // a vetoed lock does not heal because one frame correlated.
            return .vetoed(ncc: ncc)
        }

        if failed {
            consecutiveFailures += 1
            if consecutiveFailures >= config.consecutiveFailuresToVeto {
                isVetoed = true
                return .vetoed(ncc: ncc)
            }
            return .suspect(ncc: ncc, consecutiveFailures: consecutiveFailures)
        }

        consecutiveFailures = 0
        return .healthy(ncc: ncc)
    }

    private func samplePatch(pixelBuffer: CVPixelBuffer, quad: ScreenQuad) -> LumaPatch? {
        LumaPatch.sample(from: pixelBuffer,
                         quad: quad,
                         width: config.patchWidth,
                         height: config.patchHeight,
                         inset: config.inset)
    }
}
