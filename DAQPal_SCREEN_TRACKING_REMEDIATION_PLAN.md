# DAQPal — Production Screen Detection, Homography, Tracking & OCR Reliability Remediation
## Autonomous Implementation Specification for Claude Code / Codex

> **Mission:** Upgrade DAQPal from a functional intelligent screen-selection prototype into a production-grade, geometry-aware screen-locking and OCR acquisition system.
>
> **Primary correctness blocker:** Under fast motion, the current tracker can drift away from the actual display while continuing to report healthy confidence and produce OCR values. This is unacceptable. The system must never report a valid measurement from a screen geometry that it cannot independently verify is still attached to the intended physical display.
>
> **Implementation mode:** Execute this document as an engineering task list. Inspect the repository first, preserve working functionality, make incremental changes, run tests/builds after each phase, and do not mark a checkbox complete without evidence.

---

# 0. Mission

Implement and validate this pipeline:

```text
Camera / Video Frame
        │
        ▼
Latest-Frame Buffer
        │
        ▼
Candidate Screen Detection
        │
        ├── Classical CV
        ├── Geometry
        ├── Optional ML
        └── OCR Signal
        │
        ▼
Candidate Confidence Fusion
        │
        ▼
Quadrilateral / Screen Boundary Detection
        │
        ▼
Four-Corner Localization
        │
        ▼
Corner Ordering + Geometric Validation
        │
        ▼
Homography Estimation
        │
        ▼
RANSAC / Inlier Validation
        │
        ▼
Perspective Normalization
        │
        ▼
Canonical Screen Representation
        │
        ▼
Fast Frame-to-Frame Tracking
        │
        ├── Sparse Optical Flow
        ├── Feature Tracking
        ├── Homography Update
        └── Geometric Validation
        │
        ▼
Independent Tracking Confidence
        │
        ├── Healthy ────────────────┐
        │                           │
        ▼                           │
        │                           │
        │                   Continue Tracking
        │                           │
        ▼                           │
     Degraded                      │
        │                           │
        ▼                           │
  Local Reacquisition              │
        │                           │
        ├── Success ────────────────┘
        │
        ▼
  Global Reacquisition
        │
        ▼
  Candidate Detection
        │
        ▼
  Screen Re-lock
        │
        ▼
  Perspective-Normalized Screen
        │
        ▼
  Multi-Field Detection
        │
        ▼
  User Field Selection
        │
        ▼
  Field-Level Tracking
        │
        ▼
  Format-Aware OCR
        │
        ▼
  Decimal-Aware Validation
        │
        ▼
  Temporal Validation
        │
        ▼
  Structured Measurement
```

The existing DAQPal architecture already contains most of these conceptual stages, including candidate detection, magnetic snapping, target locking, four-point geometry, homography, perspective normalization, hierarchical tracking, reacquisition, screen-relative overlays, multi-field OCR, decimal-aware OCR, and temporal validation. The goal is to **harden and correct these systems**, not unnecessarily rebuild working components.

---

# 1. Non-Negotiable Engineering Principles

- [ ] **Correctness takes priority over apparent tracking stability.**
- [ ] Never display `LOCKED` when geometric evidence indicates that the target may have been lost.
- [ ] Never emit a measurement as valid solely because OCR returned a plausible number.
- [ ] Never trust a single tracking signal.
- [ ] Never use OCR as the sole mechanism for screen detection.
- [ ] Never use a static view-space rectangle as the representation of a tracked screen.
- [ ] Never allow stale frames to accumulate in an unbounded queue.
- [ ] Never block interactive UI rendering on OCR, CV, ML, or tracking.
- [ ] Prefer lightweight high-frequency tracking between slower detection/reacquisition passes.
- [ ] Use the newest available frame when processing cannot keep up.
- [ ] Preserve manual selection as a fallback.
- [ ] Preserve existing working functionality unless research or measured evidence justifies replacement.
- [ ] Profile before optimizing.
- [ ] Measure every performance claim.
- [ ] Add deterministic mechanism-level regression tests wherever possible.
- [ ] Distinguish clearly between:
  - `[RESEARCH]` Evidence directly supported by research or authoritative documentation.
  - `[EXISTING]` Behavior or requirement already present in DAQPal.
  - `[INFERENCE]` Engineering conclusion derived from research and system constraints.
  - `[HYPOTHESIS]` Behavior that must be experimentally validated.

---

# 2. Current Known Defect — Primary Blocker

The current live implementation has demonstrated:

```text
Fast camera/instrument motion
        ↓
Tracker loses correspondence
        ↓
Tracked quadrilateral lags or leaves actual screen
        ↓
Actual detector correctly finds the screen elsewhere
        ↓
Tracker continues reporting healthy confidence
        ↓
UI remains LOCKED
        ↓
OCR continues producing a value
```

This is a **data-integrity failure**.

The system must instead behave as:

```text
Fast motion
    ↓
Tracking residuals increase
    ↓
Independent geometry checks disagree
    ↓
Confidence decays
    ↓
LOCKED → DEGRADED
    ↓
Measurement validity suspended
    ↓
Local reacquisition
    ↓
If unsuccessful → global reacquisition
    ↓
Re-lock only after independent geometric confirmation
```

### Absolute acceptance rule

- [x] If the tracker is geometrically uncertain, the UI must communicate uncertainty.  *(DEGRADED/REACQUIRING chips render distinctly; measured trace shows states cycling under drift)*
- [x] If screen identity cannot be verified, OCR output must not be considered valid.  *(`measurementsValid` gates fieldROIs; 0 LOCKED-while-unverified passes in an 81-pass bounce trace)*
- [x] If the tracker drifts off the physical display, confidence must fall below the lock threshold.  *(transit/diverged hard vetoes force confidence to 0; E2E DriftRegressionTests invalidates on the first drift frame)*
- [x] If the detector sees the real screen at a location inconsistent with the tracked geometry, the tracked lock must be invalidated.  *(TrackVerifier diverged + id-independent transit; two live escapes found and closed — see ARCHITECTURE.md §11)*
- [ ] A stale last-known quadrilateral must never remain visually presented as a healthy lock after tracking updates stop.

---

# 3. Phase 0 — Repository Reconnaissance

Before modifying implementation:

- [ ] Inspect complete repository structure.
- [ ] Identify application framework and Swift/iOS version.
- [ ] Identify camera/video capture implementation.
- [ ] Identify frame delivery path.
- [ ] Identify selection UI.
- [ ] Identify rendering loop.
- [ ] Identify application state model.
- [ ] Identify candidate detector.
- [ ] Identify screen-lock pipeline.
- [ ] Identify geometry/homography implementation.
- [ ] Identify tracking implementation.
- [ ] Identify reacquisition implementation.
- [ ] Identify perspective normalization.
- [ ] Identify screen-understanding pipeline.
- [ ] Identify multi-field detector.
- [ ] Identify OCR engine(s).
- [ ] Identify decimal handling.
- [ ] Identify temporal validation.
- [ ] Identify existing performance instrumentation.
- [ ] Identify existing debug visualization.
- [ ] Identify test infrastructure.
- [ ] Identify motion-test/demo modes.
- [ ] Identify build/test commands.

Create:

```text
docs/ARCHITECTURE_CURRENT.md
```

Document:

```text
Capture
  ↓
Frame Buffer
  ↓
Detection
  ↓
Tracking
  ↓
Geometry
  ↓
Perspective Normalization
  ↓
Screen Understanding
  ↓
Field Detection
  ↓
OCR
  ↓
Validation
  ↓
Application State
  ↓
Rendering
```

For every stage document:

- Thread/queue.
- Input.
- Output.
- Frequency.
- Latency.
- Memory behavior.
- Current confidence metric.
- Current failure behavior.

### Build Gate 0

- [ ] Repository fully mapped.
- [ ] Baseline build passes.
- [ ] Baseline tests pass.
- [ ] Existing intelligent screen-lock workflow reproduced.
- [ ] Existing fast-motion drift failure reproduced.
- [ ] Baseline screenshots/video captured.
- [ ] Current implementation documented.
- [ ] No functional changes introduced yet.

---

# 4. Phase 1 — Establish Measurement and Performance Baseline

Follow the existing DAQPal performance principle:

> Profile before optimizing.

For every benchmark record:

- [ ] Device.
- [ ] iOS version.
- [ ] Build configuration.
- [ ] Thermal state.
- [ ] Camera resolution.
- [ ] Processing resolution.
- [ ] Capture FPS.
- [ ] Detection FPS.
- [ ] Tracking FPS.
- [ ] OCR FPS.
- [ ] UI FPS.
- [ ] p50 latency.
- [ ] p95 latency.
- [ ] p99 latency.
- [ ] Main-thread occupancy.
- [ ] Queue depth.
- [ ] Dropped frames.
- [ ] CPU utilization.
- [ ] GPU utilization where measurable.
- [ ] Memory usage.
- [ ] Allocations per frame.
- [ ] Homography solves per second.
- [ ] OCR requests per second.
- [ ] UI invalidations per frame.

### Required mechanism-level regression metrics

- [ ] Invalidations/frame.
- [ ] Allocations/frame.
- [ ] Homography solves/frame.
- [ ] Feature extraction requests/frame.
- [ ] OCR requests/frame.
- [ ] Queue overflow count.
- [ ] Dropped stale-frame count.

### Build Gate 1

- [ ] Baseline performance captured.
- [ ] Fast-motion failure captured.
- [ ] Main-thread behavior measured.
- [ ] Processing queue behavior measured.
- [ ] p95/p99 latency available.
- [ ] Performance budgets defined.
- [ ] Deterministic regression metrics defined.

---

# 5. Phase 2 — Correct Frame Pipeline Architecture

Implement or verify:

```text
Camera
   ↓
LatestFrameBuffer(capacity = 1 or bounded small N)
   ↓
Processing Worker
   ↓
Tracking / Detection
   ↓
Geometry
   ↓
OCR
```

The UI must receive results asynchronously.

### Requirements

- [ ] UI never waits for OCR.
- [ ] UI never waits for ML inference.
- [ ] UI never waits for expensive CV.
- [ ] UI never waits for feature extraction.
- [ ] UI never waits for homography estimation.
- [ ] Queue is explicitly bounded.
- [ ] Old frames are discarded.
- [ ] Newest frame wins.
- [ ] Frame processing cannot create unbounded latency.
- [ ] Capture remains responsive when processing is overloaded.

### Build Gate 2

- [ ] No unbounded queue.
- [ ] No processing-induced input lag.
- [ ] No main-thread OCR/CV.
- [ ] Newest-frame policy verified.
- [ ] Queue overflow behavior tested.
- [ ] Existing UI selection behavior preserved.

---

# 6. Phase 3 — Screen Candidate Detection

The system must detect the **physical display region**, not merely the entire device.

Potential candidates:

- LCD.
- LED.
- E-ink.
- Seven-segment display.
- Digital gauge.
- Instrument display.
- Embedded display.

Do not require readable text.

Implement candidate generation using the simplest reliable combination of:

- [ ] Contours.
- [ ] Edge detection.
- [ ] Line segments.
- [ ] Quadrilateral fitting.
- [ ] Aspect-ratio constraints.
- [ ] Convexity.
- [ ] Area constraints.
- [ ] Temporal stability.
- [ ] Optional OCR signal.
- [ ] Optional ML signal.

Potential CV pipeline:

```text
Input Frame
    ↓
Downsample
    ↓
Grayscale
    ↓
Contrast / Gradient
    ↓
Edge Detection
    ↓
Morphological Cleanup
    ↓
Line / Contour Extraction
    ↓
Quadrilateral Candidate Generation
    ↓
Geometric Filtering
    ↓
Candidate Scoring
```

### Candidate score

Implement a normalized score composed of measurable signals:

```text
CandidateScore =
    GeometryScore
  + EdgeScore
  + AspectRatioScore
  + AreaScore
  + TemporalStabilityScore
  + OptionalOCRScore
  + OptionalMLScore
```

Do not arbitrarily assign permanent weights.

- [ ] Start with documented initial weights.
- [ ] Log each component independently.
- [ ] Validate weights against labeled test data.
- [ ] Tune empirically.
- [ ] Document final weights.
- [ ] Consider learned fusion only if simpler fusion is insufficient.

### Build Gate 3

- [ ] Screen detection works without OCR.
- [ ] OCR may contribute but cannot dominate.
- [ ] Multiple candidates supported.
- [ ] Candidate geometry stored.
- [ ] Candidate confidence stored.
- [ ] Candidate temporal stability measured.
- [ ] False positives tested against:
  - [ ] Laptop screens.
  - [ ] Phones.
  - [ ] Windows.
  - [ ] Posters.
  - [ ] Picture frames.
  - [ ] Random rectangles.
  - [ ] Reflections.
  - [ ] Instrument bezels.

---

# 7. Phase 4 — Four-Corner Localization

For every candidate quadrilateral:

- [ ] Detect four physical screen corners.
- [ ] Preserve corner identity.
- [ ] Order corners consistently:
  - Top-left.
  - Top-right.
  - Bottom-right.
  - Bottom-left.
- [ ] Reject self-intersecting quadrilaterals.
- [ ] Reject concave quadrilaterals.
- [ ] Reject degenerate quadrilaterals.
- [ ] Reject extremely small areas.
- [ ] Reject extreme projective distortion beyond configured limits.
- [ ] Validate edge lengths.
- [ ] Validate opposing-edge relationships.
- [ ] Validate screen aspect ratio.

Candidate refinement may use:

- [ ] Contour approximation.
- [ ] Line-segment detection.
- [ ] Hough lines.
- [ ] Edge profiles.
- [ ] Corner detectors.
- [ ] Local gradient optimization.
- [ ] Feature points.

Use the **simplest method that meets measured accuracy requirements**.

### Corner identity requirement

Corner identity must remain stable through:

- [ ] Translation.
- [ ] Scale.
- [ ] Roll.
- [ ] Yaw.
- [ ] Pitch.
- [ ] Combined motion.

Do not reassign corners solely by nearest distance to image origin.

### Build Gate 4

- [ ] Four corners detected.
- [ ] Corner ordering deterministic.
- [ ] Corner identity stable.
- [ ] Degenerate quads rejected.
- [ ] Perspective distortion validated.
- [ ] Corner error benchmark created.

---

# 8. Phase 5 — Homography Estimation

For a planar screen, implement:

```text
Canonical Screen Coordinates
        ↓
Four Corresponding Screen Corners
        ↓
Homography H
        ↓
Frame Coordinates
```

Use normalized coordinates.

Implement:

- [ ] Four-point homography.
- [ ] Normalized DLT where appropriate.
- [ ] RANSAC for feature-correspondence-based homography.
- [ ] Reprojection-error calculation.
- [ ] Degeneracy checks.
- [ ] Homography validity checks.

### Homography validation

Reject a homography if:

- [ ] Reprojection error exceeds threshold.
- [ ] Inlier count is insufficient.
- [ ] Inlier ratio is insufficient.
- [ ] Projected quadrilateral becomes invalid.
- [ ] Projected area changes beyond plausible bounds.
- [ ] Aspect ratio becomes implausible.
- [ ] Perspective distortion exceeds configured limits.
- [ ] Corner displacement exceeds motion model.
- [ ] Homography update conflicts with independent tracking signals.

### Build Gate 5

- [ ] Homography computed successfully.
- [ ] Homography validated.
- [ ] Reprojection error logged.
- [ ] RANSAC metrics logged.
- [ ] Invalid homographies rejected.
- [ ] Homography test vectors created.

---
# 5A. Research-Backed Computer Vision Implementation Matrix

> **Purpose:** Ground DAQPal's screen detection, four-corner localization, homography, tracking, and reacquisition architecture in established computer-vision research and native iOS capabilities.
>
> **Implementation principle:** Research methods must be treated as candidates to benchmark, not automatically adopted. The production implementation must be selected based on measured accuracy, robustness, latency, memory, energy consumption, and iOS deployment feasibility.

---

## 5A.1 Research and Technology Candidates

The implementation team must investigate and benchmark the following approaches.

### A. Native iOS Rectangle Detection — Apple Vision

**Primary use:**

```text
Camera Frame
    ↓
Vision Rectangle Detection
    ↓
Four Detected Vertices
    ↓
Geometric Validation
    ↓
Candidate Screen
```

Use Apple's native rectangle-detection capability as the first baseline for physical screen detection.

Evaluate:

* [ ] Four-vertex accuracy.
* [ ] Detection confidence.
* [ ] Minimum rectangle size.
* [ ] Aspect-ratio constraints.
* [ ] Quadrature tolerance.
* [ ] Performance on-device.
* [ ] Performance under perspective distortion.
* [ ] Performance under motion blur.
* [ ] Performance under glare.
* [ ] Performance with low-texture LCD surfaces.
* [ ] False positives from non-display rectangles.

The system should determine experimentally whether Vision rectangle detection can serve as:

1. Primary screen detector.
2. Periodic independent tracking validator.
3. Reacquisition detector.
4. Global fallback detector.

**Required benchmark:**

Compare Vision rectangle detection against the existing DAQPal candidate detector.

Record:

```text
Detection rate
False-positive rate
Corner error
Detection latency
CPU utilization
Memory
Energy impact
```

**Decision gate:**

* [ ] If Vision performs adequately, prefer the native implementation over custom CV.
* [ ] If Vision is insufficient, retain it as an independent validation signal if useful.
* [ ] If Vision fails consistently on the target display class, document the failure modes before replacing it.

---

### B. Vision Rectangle Tracking — Native iOS Tracking Baseline

Evaluate native rectangle tracking as a lightweight baseline for frame-to-frame tracking.

Candidate architecture:

```text
Initial Rectangle Detection
        ↓
Four Screen Corners
        ↓
Native Rectangle Tracking
        ↓
Tracked Corners
        ↓
Independent Geometric Validation
```

The tracker must not be treated as authoritative.

Use it as:

```text
Fast Tracker
      +
Independent Validator
```

Evaluate:

* [ ] Tracking success rate.
* [ ] Tracking drift rate.
* [ ] Corner accuracy.
* [ ] Fast-motion behavior.
* [ ] Motion-blur behavior.
* [ ] Partial occlusion behavior.
* [ ] Perspective-change behavior.
* [ ] Recovery behavior.

### Critical requirement

A native tracking result must not automatically imply:

```text
LOCKED_HEALTHY
```

It must pass the independent geometry-validation layer.

---

### C. Deep Image Homography Estimation — DeTone et al.

Investigate:

> **Deep Image Homography Estimation**

This research formulates homography estimation through a four-point parameterization and predicts the projective transformation between image regions.

DAQPal relevance:

```text
Reference Screen
      ↓
Four-Point Representation
      ↓
Predicted Homography
      ↓
Projected Screen Corners
      ↓
Geometric Validation
```

Evaluate whether a learned homography model could improve:

* [ ] Recovery from difficult perspective changes.
* [ ] Tracking when sparse feature matching fails.
* [ ] Low-texture screen tracking.
* [ ] Motion-blurred frame alignment.
* [ ] Screen re-localization.

Do **not** place a deep homography model into the critical path until the following are measured:

* [ ] Accuracy improvement over classical homography.
* [ ] Latency.
* [ ] Memory.
* [ ] CPU/GPU/Neural Engine utilization.
* [ ] Core ML conversion feasibility.
* [ ] Model size.
* [ ] Energy consumption.
* [ ] Performance on representative DAQPal devices.

### Recommended role

Initially classify as:

```text
OPTIONAL RESEARCH FALLBACK
```

Potential architecture:

```text
Classical CV
    ↓
Tracking Failure
    ↓
Deep Homography Fallback
    ↓
Independent Geometry Validation
    ↓
Re-lock
```

Never allow the deep model to directly establish measurement validity without geometric validation.

---

### D. Unsupervised / Content-Aware Deep Homography

Investigate research addressing homography estimation without requiring fully supervised correspondence labels, including content-aware approaches.

The primary DAQPal question is:

> Can learned homography estimation remain reliable when the display contains weak texture, repeated digit patterns, reflections, or large uniform regions?

Benchmark against:

```text
Classical Feature Matching
+
RANSAC
```

and:

```text
Optical Flow
+
Homography
```

Evaluate:

* [ ] Low-texture display performance.
* [ ] Repeated digit-pattern performance.
* [ ] Glare robustness.
* [ ] Illumination changes.
* [ ] Motion blur.
* [ ] Perspective distortion.
* [ ] Inlier/outlier robustness.

Do not assume research results on natural-image datasets transfer directly to LCD/equipment displays.

DAQPal must create its own representative benchmark.

---

### E. Classical Feature Matching + RANSAC

Implement a classical independent geometric verification path.

Candidate pipeline:

```text
Reference / Canonical Screen
        ↓
Feature Detection
        ↓
Feature Description
        ↓
Feature Matching
        ↓
Outlier Rejection
        ↓
RANSAC
        ↓
Homography
        ↓
Reprojection Error
        ↓
Screen Geometry
```

Evaluate suitable feature methods available to the project.

Potential candidates include:

* [ ] ORB.
* [ ] AKAZE.
* [ ] SIFT where deployment/licensing/performance constraints permit.
* [ ] Other native or OpenCV-compatible feature methods.

Use RANSAC to reject incorrect correspondences.

Record:

```text
Number of matches
Number of inliers
Inlier ratio
Reprojection error
Homography stability
Corner error
Processing latency
```

### Recommended production role

This should be strongly considered as an **independent validator** rather than necessarily the primary tracker.

For example:

```text
Fast Tracker
      ↓
Tracked Quadrilateral
      ↓
Feature Matching + RANSAC
      ↓
Does independent geometry agree?
      │
      ├── YES → Continue LOCKED_HEALTHY
      │
      └── NO  → DEGRADED / REACQUIRE
```

This architecture directly addresses the known DAQPal failure mode where a tracker can remain "healthy" after losing physical correspondence.

---

### F. Sparse Optical Flow

Evaluate sparse optical-flow tracking for high-frequency corner/feature propagation.

Candidate:

```text
Frame N
    ↓
Tracked Feature Points
    ↓
Optical Flow
    ↓
Frame N+1
    ↓
Updated Feature Positions
    ↓
Homography Update
```

Use optical flow for:

* [ ] High-frequency tracking.
* [ ] Corner propagation.
* [ ] Low-latency motion estimation.
* [ ] Fast camera movement.

Do not rely solely on optical flow.

Evaluate:

* [ ] Forward-backward flow consistency.
* [ ] Flow residual.
* [ ] Number of valid points.
* [ ] Spatial distribution of tracked points.
* [ ] Corner consistency.

A tracker with many points concentrated in one small region should not automatically be considered reliable.

### Required failure condition

If:

```text
Forward-backward error > threshold
```

or:

```text
Valid tracked points < minimum
```

or:

```text
Tracked points become spatially degenerate
```

then:

```text
Tracking confidence decreases
```

---

### G. Edge and Line-Based Screen Detection

Because LCD screens are often planar rectangles with strong physical boundaries, investigate a geometry-first approach:

```text
Grayscale
    ↓
Gradient / Edge Detection
    ↓
Line Segment Detection
    ↓
Line Intersection
    ↓
Quadrilateral
    ↓
Four Corners
```

Evaluate:

* [ ] Canny edges.
* [ ] Hough lines.
* [ ] Line segment detection.
* [ ] Contour extraction.
* [ ] Polygon approximation.

This approach may be particularly useful when:

* Text features are unavailable.
* The display is low texture.
* OCR is unreliable.
* The display is visible but characters are unreadable.

### Recommended role

Use as a complementary candidate detector or validation signal.

Do not assume edge detection alone is sufficient because:

* Bezels can create false rectangles.
* Reflections can create edges.
* Device housings can resemble screens.
* Window frames can resemble displays.

Combine geometric evidence with temporal and appearance information.

---

# 5A.2 Recommended DAQPal Hybrid Architecture

Based on the research candidates above, implement the following architecture as the initial production benchmark:

```text
                         CAMERA FRAME
                              │
                              ▼
                  ┌──────────────────────┐
                  │ Candidate Detection  │
                  └──────────┬───────────┘
                             │
               ┌─────────────┼─────────────┐
               │             │             │
               ▼             ▼             ▼
         Vision Rect.   Edge/Contour   Existing DAQPal
          Detection      Detection       Detector
               │             │             │
               └─────────────┼─────────────┘
                             ▼
                    Candidate Fusion
                             │
                             ▼
                    Four-Corner Geometry
                             │
                             ▼
                     Homography H₀
                             │
                             ▼
                 Perspective Normalization
                             │
                             ▼
                    CANONICAL SCREEN
                             │
                             ▼
               ┌─────────────────────────┐
               │ Fast Frame-to-Frame    │
               │ Tracking                │
               │                         │
               │ Optical Flow            │
               │ +                       │
               │ Feature Tracking        │
               │ +                       │
               │ Native Rectangle Track  │
               └────────────┬────────────┘
                            │
                            ▼
                  Tracked Quadrilateral
                            │
             ┌──────────────┼──────────────┐
             │              │              │
             ▼              ▼              ▼
       RANSAC/Feature   Edge Alignment   Fresh Vision
       Verification                     Rectangle Detection
             │              │              │
             └──────────────┼──────────────┘
                            ▼
                  Independent Validation
                            │
                 ┌──────────┴──────────┐
                 │                     │
               VALID                 INVALID
                 │                     │
                 ▼                     ▼
          LOCKED_HEALTHY           DEGRADED
                 │                     │
                 ▼                     ▼
              OCR               Local Reacquisition
                 │                     │
                 ▼                     ▼
        Valid Measurement       Global Reacquisition
                                       │
                                       ▼
                              Optional Deep Homography
                                       │
                                       ▼
                             Geometric Revalidation
                                       │
                                       ▼
                                     RELOCK
```

---

# 5A.3 Research Method Selection Matrix

Claude Code / Codex must implement a benchmark harness comparing at minimum:

| Method                        | Detection | Tracking | Homography | Reacquisition |        Low Texture | Fast Motion |          iOS |
| ----------------------------- | --------: | -------: | ---------: | ------------: | -----------------: | ----------: | -----------: |
| Vision Rectangle Detection    |         ✓ |          |            |             ✓ |               Test |        Test |            ✓ |
| Vision Rectangle Tracking     |           |        ✓ |            |               |               Test |        Test |            ✓ |
| Edge/Contour Geometry         |         ✓ |          |          ✓ |             ✓ | Potentially strong |        Test |            ✓ |
| Optical Flow                  |           |        ✓ |          ✓ |               |               Test |        Test |            ✓ |
| Feature Matching + RANSAC     |           |        ✓ |          ✓ |             ✓ |               Test |        Test |     ✓/OpenCV |
| Deep Homography               |           |        ✓ |          ✓ |             ✓ |           Research |    Research | Core ML test |
| Content-Aware Deep Homography |           |        ✓ |          ✓ |             ✓ |           Research |    Research | Core ML test |

Do not select the final production architecture by theoretical superiority.

Select it based on measured DAQPal-specific performance.

---

# 5A.4 Required Benchmark Dataset

Create a representative dataset containing actual DAQPal target displays.

Include:

### Display Types

* [ ] LCD.
* [ ] Seven-segment display.
* [ ] E-ink.
* [ ] OLED.
* [ ] Digital multimeter.
* [ ] Temperature gun.
* [ ] Laboratory instrumentation.
* [ ] Industrial instrumentation.

### Motion

* [ ] Slow movement.
* [ ] Fast movement.
* [ ] Sudden movement.
* [ ] Rotation.
* [ ] Yaw.
* [ ] Pitch.
* [ ] Combined motion.

### Visual Conditions

* [ ] Bright light.
* [ ] Low light.
* [ ] Glare.
* [ ] Reflection.
* [ ] Motion blur.
* [ ] Partial occlusion.
* [ ] Low contrast.
* [ ] Dirty/scratched display.
* [ ] Display bezel partially visible.

### Ground Truth

For every frame or sampled frame:

```text
Screen identity
Top-left corner
Top-right corner
Bottom-right corner
Bottom-left corner
Screen visibility
Tracking validity
Measurement validity
```

---

# 5A.5 Quantitative Evaluation

For every candidate method, measure:

```text
Detection Precision
Detection Recall

Corner Pixel Error
Mean Corner Error
95th Percentile Corner Error

Homography Reprojection Error

Screen IoU

Tracking Success Rate

False Lock Rate

False Healthy-Lock Rate

Tracking Drift Rate

Reacquisition Success Rate

Reacquisition Latency

OCR Accuracy

Decimal Accuracy

End-to-End Measurement Accuracy

p50 Latency
p95 Latency
p99 Latency

CPU
GPU
Neural Engine
Memory
Energy
```

The most important DAQPal-specific metric is:

> **False Healthy-Lock Rate**

Definition:

```text
The percentage of frames in which the system reports
LOCKED_HEALTHY while the tracked quadrilateral is no longer
geometrically attached to the intended physical display.
```

This metric must approach zero.

A system with slightly lower tracking recall but near-zero false healthy-lock rate may be preferable to a system that tracks more aggressively but silently reports incorrect measurements.

---

# 5A.6 Deep Learning Integration Decision Gate

Do not immediately implement a neural homography model.

First complete:

```text
Vision Rectangle Detection
        +
Optical Flow
        +
Feature Matching
        +
RANSAC
        +
Geometric Validation
        +
Reacquisition
```

Then benchmark.

Only add deep homography if:

```text
Classical pipeline
    ↓
Fails representative DAQPal cases
    ↓
Deep model demonstrably improves results
    ↓
Latency acceptable
    ↓
Memory acceptable
    ↓
Energy acceptable
    ↓
iOS deployment feasible
```

If the deep model is adopted:

```text
Deep Homography
    ↓
Candidate Geometry
    ↓
Independent Geometric Validation
    ↓
Temporal Validation
    ↓
LOCK
```

Never:

```text
Deep Model Confidence
    ↓
Automatically Valid Measurement
```

---

# 5A.7 Research Implementation Order

Implement and benchmark in this order:

### Priority 1 — Native Baseline

* [ ] Apple Vision rectangle detection.
* [ ] Apple Vision rectangle tracking.
* [ ] Four-corner extraction.
* [ ] Homography.
* [ ] Perspective normalization.

### Priority 2 — Classical Geometric Verification

* [ ] Edge/line detection.
* [ ] Feature matching.
* [ ] RANSAC homography.
* [ ] Reprojection-error validation.

### Priority 3 — High-Frequency Tracking

* [ ] Sparse optical flow.
* [ ] Forward-backward validation.
* [ ] Feature-point tracking.
* [ ] Motion prediction.

### Priority 4 — Hybrid Anti-Drift System

* [ ] Fast tracker.
* [ ] Independent detector.
* [ ] Periodic geometric revalidation.
* [ ] Hard confidence vetoes.
* [ ] Local reacquisition.
* [ ] Global reacquisition.

### Priority 5 — Research Fallback

* [ ] Deep Image Homography benchmark.
* [ ] Content-aware homography benchmark.
* [ ] Core ML conversion feasibility.
* [ ] iOS performance benchmark.

---

# 5A.8 Required Research Evidence

For every research method actually adopted, create a record:

```text
Method:
Paper / Source:
Authors:
Publication / Year:
URL / DOI / arXiv:
Repository:
License:
Algorithm:
Input:
Output:
Training Requirements:
Inference Requirements:
iOS Compatibility:
Core ML Compatibility:
Neural Engine Compatibility:
Latency:
Memory:
Accuracy:
Known Failure Modes:
DAQPal Benchmark Result:
Production Decision:
```

Classify each method:

```text
[ADOPTED]
[VALIDATION ONLY]
[RESEARCH FALLBACK]
[REJECTED]
```

Explain the decision with measured evidence.

---

# 5A.9 Final Research Acceptance Gate

The research phase is complete only when the implementation team can answer:

* [ ] Which method detects the physical screen most reliably?
* [ ] Which method produces the most accurate four corners?
* [ ] Which method performs best under fast motion?
* [ ] Which method performs best under low texture?
* [ ] Which method detects tracker drift earliest?
* [ ] Which method is fastest on the target iPhone?
* [ ] Which method consumes the least energy?
* [ ] Which method is best for continuous tracking?
* [ ] Which method is best for reacquisition?
* [ ] Which method is best for independent validation?
* [ ] Is a deep-learning homography model actually necessary?
* [ ] Can the final system achieve near-zero false healthy-lock events?
* [ ] Can the final system guarantee that a valid OCR measurement corresponds to the intended physical display?

The final architecture must be selected from **measured DAQPal-specific evidence**, not from paper benchmarks alone.

---

# 5A.10 Research-Backed Definition of Done

The computer-vision subsystem is considered production-ready when:

```text
Physical Display
    ↓
Four-Corner Detection
    ↓
Validated Homography
    ↓
Canonical Screen
    ↓
High-Frequency Tracking
    ↓
Independent Geometric Verification
    ↓
Drift Detection
    ↓
Reacquisition
    ↓
Revalidation
    ↓
Field-Level OCR
    ↓
Decimal Validation
    ↓
Temporal Validation
    ↓
Valid Measurement
```

The system must demonstrate that:

> **No single tracker, OCR engine, ML model, or confidence score is trusted as the sole source of truth.**

The physical display geometry must be continuously supported by independent evidence.

If independent evidence disagrees with the tracked geometry:

```text
Do not trust the tracker.
Do not trust the OCR result.
Do not trust the measurement.
Invalidate and reacquire.
```

This requirement is the fundamental computer-vision reliability principle for DAQPal.

# 9. Phase 6 — Perspective Normalization

Convert the tracked screen into a canonical coordinate system:

```text
Tracked Screen
      ↓
Homography
      ↓
Canonical Rectangle
      ↓
Normalized Display
```

The canonical representation must remain stable as the physical display:

- [ ] Moves.
- [ ] Rotates.
- [ ] Changes scale.
- [ ] Changes perspective.

Use this canonical representation as the primary input to:

- [ ] Screen understanding.
- [ ] Field detection.
- [ ] ROI generation.
- [ ] OCR.
- [ ] Decimal validation.

### Build Gate 6

- [ ] Perspective warp stable.
- [ ] Display remains correctly oriented.
- [ ] Field ROIs remain screen-relative.
- [ ] Canonical coordinates remain stable under camera motion.
- [ ] Warp quality measured.

---

# 10. Phase 7 — Replace "Single Tracker Confidence" With Independent Geometric Verification

This phase directly addresses the fast-motion drift defect.

Do **not** define:

```text
Confidence = tracker says it is good
```

Instead evaluate independent signals.

Minimum signals:

```text
1. Feature inlier ratio
2. Homography reprojection error
3. Corner displacement consistency
4. Edge alignment
5. Optical-flow residual
6. Aspect-ratio consistency
7. Quadrilateral validity
8. Area-change consistency
9. Temporal motion consistency
10. Appearance/template similarity
11. OCR consistency
12. Screen-content consistency
```

Conceptual confidence:

```text
C =
    w1 * FeatureInlierScore
  + w2 * ReprojectionScore
  + w3 * CornerConsistency
  + w4 * EdgeAlignment
  + w5 * OpticalFlowConsistency
  + w6 * AspectRatioConsistency
  + w7 * QuadrilateralValidity
  + w8 * TemporalConsistency
  + w9 * AppearanceConsistency
  + w10 * OCRConsistency
```

However:

> **Do not allow a weighted average to hide a catastrophic failure.**

Implement **hard veto conditions**.

For example:

```text
if quadrilateralInvalid:
    FAIL

if homographyReprojectionError > HARD_LIMIT:
    FAIL

if edgeAlignment < HARD_LIMIT:
    FAIL

if detectorFindsTargetFarFromTrackedTarget:
    FAIL

if trackedQuadOutsidePlausibleMotionEnvelope:
    FAIL

if trackerHasNoFreshUpdate:
    FAIL_AFTER_TIMEOUT
```

A catastrophic failure must override a high aggregate score.

### Confidence states

```text
HEALTHY
DEGRADED
LOST
```

Suggested behavior:

```text
HEALTHY
  → continue tracking
  → OCR valid

DEGRADED
  → continue short-term tracking
  → reduce OCR confidence
  → initiate local reacquisition
  → do not silently present stale geometry

LOST
  → invalidate geometry
  → invalidate measurement
  → stop claiming LOCKED
  → local/global reacquisition
```

### Build Gate 7

- [x] Independent confidence signals implemented.  *(detector corroboration, motion coupling, persistence testimony, stale-tracker timeout — tracker self-confidence deliberately excluded)*
- [x] Hard veto conditions implemented.  *(diverged, transit, stale-tracker FAIL_AFTER_TIMEOUT; no aggregate can override)*
- [x] Confidence history logged.  *(DEBUG verdict trace in ScreenLockPipeline Stage 2b — the 81-pass bounce trace is read from it, not from screenshots)*
- [x] Fast-motion drift causes confidence failure.  *(measured: 23 transit vetoes in 81 passes under bounce)*
- [x] Stale tracker updates cause confidence failure.  *(staleTrackerTimeout 0.75 s)*
- [x] False healthy-lock scenario reproduced and eliminated.  *(reproduced live twice against interim fixes; final trace: 0 LOCKED-while-unverified)*

---

# 11. Phase 8 — Fast-Motion Drift Prevention

Implement a dedicated anti-drift architecture.

Recommended:

```text
                    LOCKED
                       │
                       ▼
              Fast Local Tracker
                       │
             ┌─────────┴─────────┐
             │                   │
          Healthy             Degraded
             │                   │
             ▼                   ▼
        Continue             Local Search
                                 │
                         ┌───────┴───────┐
                         │               │
                       Found           Failed
                         │               │
                         ▼               ▼
                      Relock        Global Search
                                         │
                                         ▼
                                     Candidate
                                         │
                                         ▼
                                       Relock
```

### Independent revalidation

At a slower cadence than frame-to-frame tracking:

- [ ] Re-run screen candidate detection.
- [ ] Compare detected screen location to tracked screen.
- [ ] Compare detected geometry to tracked geometry.
- [ ] Reject tracker if discrepancy exceeds threshold.
- [ ] Do not let tracker operate indefinitely without independent revalidation.

### Motion model

Track:

- [ ] Position.
- [ ] Velocity.
- [ ] Acceleration.
- [ ] Scale.
- [ ] Rotation.
- [ ] Perspective deformation.

Reject implausible jumps.

### Build Gate 8

Run:

- [ ] Horizontal translation.
- [ ] Vertical translation.
- [ ] Diagonal translation.
- [ ] Yaw.
- [ ] Pitch.
- [ ] Roll.
- [ ] Zoom in.
- [ ] Zoom out.
- [ ] Combined rotation.
- [ ] Combined scale + rotation.
- [ ] Fast motion.
- [ ] Motion blur.
- [ ] Temporary occlusion.
- [ ] Glare.
- [ ] Reflection.

For each:

- [ ] Tracker remains on target.
- [ ] Confidence reflects quality.
- [ ] No false healthy lock.
- [ ] Reacquisition occurs when necessary.
- [ ] Measurement validity is suspended during loss.

---

# 12. Phase 9 — Tracking Architecture

Use a hierarchical tracking system.

Recommended:

```text
INITIAL DETECTION
       ↓
HIGH-QUALITY GEOMETRY
       ↓
HOMOGRAPHY
       ↓
FAST TRACKING
       ↓
PERIODIC VALIDATION
       ↓
LOCAL REACQUISITION
       ↓
GLOBAL REACQUISITION
```

Possible frame-to-frame methods:

- [ ] Sparse Lucas-Kanade optical flow.
- [ ] Feature tracking.
- [ ] Homography update.
- [ ] Edge alignment.
- [ ] Template correlation.

Do not assume one method is sufficient.

Use independent signals where computationally justified.

### Preferred strategy

```text
Every frame:
    Lightweight tracking

Every N frames:
    Geometry validation

Every M frames:
    Candidate revalidation

On confidence degradation:
    Local reacquisition

On failure:
    Global reacquisition
```

Choose N/M empirically.

### Build Gate 9

- [ ] Tracking runs independently of detection.
- [ ] Tracking runs faster than global detection.
- [ ] Tracking cadence measured.
- [ ] Revalidation cadence measured.
- [ ] Reacquisition latency measured.
- [ ] Tracking cannot remain indefinitely without validation.

---

# 13. Phase 10 — Reacquisition

Implement two levels.

## Local reacquisition

Search:

```text
Previous target location
+
Motion-predicted search region
+
Expanded ROI
```

Use:

- [ ] Edge detection.
- [ ] Quadrilateral search.
- [ ] Feature matching.
- [ ] Optical flow recovery.
- [ ] Template correlation.

## Global reacquisition

Search entire frame.

Use:

- [ ] Candidate detector.
- [ ] Geometry.
- [ ] Optional ML.
- [ ] Optional OCR.

### Re-lock requirements

A target may not transition back to `LOCKED` solely because tracking resumes.

Require:

- [ ] Valid quadrilateral.
- [ ] Valid corner ordering.
- [ ] Valid homography.
- [ ] Acceptable reprojection error.
- [ ] Acceptable geometry.
- [ ] Independent screen evidence.
- [ ] Temporal stability over multiple frames.

### Build Gate 10

- [ ] Local reacquisition works.
- [ ] Global reacquisition works.
- [ ] Re-lock requires validation.
- [ ] Reacquisition recovery time measured.
- [ ] False re-lock tested.

---

# 14. Phase 11 — Pose-Adaptive Screen-Relative Overlay

The overlay is a correctness signal.

It must be generated from the actual tracked screen quadrilateral.

Requirements:

- [ ] Four vertices correspond to physical screen corners.
- [ ] Overlay follows yaw.
- [ ] Overlay follows pitch.
- [ ] Overlay follows roll.
- [ ] Overlay scales with distance.
- [ ] Overlay updates at tracking cadence.
- [ ] Corner identity is stable.
- [ ] Overlay uses the same frame→view coordinate mapping as the capture system.
- [ ] No axis-aligned bounding-box replacement.

### Visual states

```text
HEALTHY LOCK
    Solid quad
    Corner markers

DEGRADED
    Visually distinct
    Reduced authority
    No false certainty

REACQUIRING
    Clearly different
    Not presented as confirmed lock

LOST
    Remove or invalidate lock geometry
```

### Build Gate 11

- [ ] Quad wraps actual display.
- [ ] Quad deforms under yaw.
- [ ] Quad deforms under pitch.
- [ ] Quad rotates under roll.
- [ ] Quad scales with distance.
- [ ] Quad updates continuously.
- [ ] Corners never swap identity.
- [ ] Stale geometry is not presented as healthy.

---

# 15. Phase 12 — Screen Understanding and Multi-Field OCR

Once the screen geometry is validated:

```text
Canonical Screen
      ↓
Screen Layout Analysis
      ↓
Field Detection
      ↓
Field ROI
      ↓
Field Tracking
      ↓
Format-Aware OCR
```

The screen should be treated as a structured measurement surface.

For each field store:

```text
Field ID
Field Type
Canonical ROI
Expected Character Set
Expected Digit Count
Expected Decimal Positions
Expected Units
Expected Range
OCR Confidence
Decimal Confidence
Temporal Confidence
```

### Build Gate 12

- [ ] Screen understanding operates in canonical coordinates.
- [ ] Multiple fields supported.
- [ ] Field ROIs remain stable under camera movement.
- [ ] User field selection preserved.
- [ ] Field-level tracking implemented.
- [ ] OCR consumes canonical field ROIs.

---

# 16. Phase 13 — Decimal Integrity

Decimal placement is measurement-critical.

A result of:

```text
80.8
```

must not silently become:

```text
808
```

or vice versa.

Implement:

- [ ] Decimal detection independent of digit recognition where practical.
- [ ] Decimal candidate localization.
- [ ] Decimal confidence.
- [ ] Expected decimal-position model.
- [ ] Format-aware validation.
- [ ] Temporal validation.
- [ ] Magnitude/range validation.
- [ ] Cross-frame consistency.

### Build Gate 13

- [x] Decimal failures reproduced.  *(device benchmark: 7/72 silent power-of-ten errors, all label `.5` → accepted as `5`, iPhone 12 Pro Max — OCR_DEVICE_BENCHMARK.md)*
- [x] Decimal detection implemented.  *(text-path `DecimalAnalysis` wired through fusion; image-path `DecimalRescue` built and 23/23 tested — "80.8" → position 2 @ 0.97 — but still has zero app-target call sites)*
- [x] Decimal confidence exposed.  *(DecimalIntegrityTests: `testLowDecimalConfidenceDepressesTheFusedConfidence`, `testVeryLowDecimalConfidenceVetoesAsAmbiguousDecimal`)*
- [x] Decimal position validated.  *(DecimalIntegrityTests: `testSeparatorAwayFromTheDeclaredPositionIsAFormatViolation`, `testDeclaredPositionResolvesAnAmbiguousComma`)*
- [x] Positive vectors pass.  *(DecimalIntegrityTests.testPositiveVectorsParseToExactValues + separator presence/position vectors)*
- [x] Negative vectors pass.  *(DecimalIntegrityTests: `testMalformedSeparatorStructuresAreRejected`, `testMalformedStructuresDoNotSalvageAPrefixOrSuffix`)*
- [ ] Exported values preserve precision.
- [x] `808` vs `80.8` regression test exists.  *(DecimalRescueTests.testHeadlineCase_80point8 / testIntegerHasNoSeparator_808; DecimalIntegrityTests.testDroppingTheSeparatorNeverPublishesTheShiftedValue; GatingTests.testFlipFlop_neverPublishesBothOrdersOfMagnitude)*

---

# 17. Phase 14 — Temporal Measurement Validation

Never trust one OCR frame.

Evaluate multiple consecutive frames.

Evaluate:

- [ ] OCR confidence.
- [ ] Decimal confidence.
- [ ] Value continuity.
- [ ] Expected physical range.
- [ ] Field identity.
- [ ] Screen-lock confidence.
- [ ] Geometry confidence.

Measurement validity should be approximately:

```text
MeasurementValid =
    ScreenLockValid
    AND
    GeometryValid
    AND
    TrackingHealthy
    AND
    FieldValid
    AND
    OCRValid
    AND
    DecimalValid
```

### Critical rule

If:

```text
TrackingHealthy = false
```

then:

```text
MeasurementValid = false
```

even if OCR itself has 99% confidence.

### Build Gate 14

- [ ] Temporal smoothing implemented.
- [x] Outlier rejection implemented.  *(TemporalConsensusTests: `testSingleNonDecimalOutlierDoesNotOverwriteStableReading`, `testSingleDroppedSeparatorDoesNotFlipStableReading`)*
- [x] Invalid geometry invalidates measurements.  *(`measurementsValid` gates field ROIs; GatingTests.testFieldBackedCardLock_dropsTheMomentTrackingIsInvalidated)*
- [x] Tracking loss invalidates measurements.  *(DriftRegressionTests.testFastMotionDriftInvalidatesMeasurementsThenRelocks — invalidation on the first drift frame; GatingTests tracking-invalid rejections)*
- [x] Decimal uncertainty invalidates or flags measurements.  *(DecimalIntegrityTests.testVeryLowDecimalConfidenceVetoesAsAmbiguousDecimal)*
- [x] Structured output distinguishes valid vs uncertain values.  *(typed `RejectionReason` incl. `.ambiguousDecimal`; DecimalIntegrityTests.testAmbiguousDecimalHasARejectionLabelInTheExistingStyle; rejected samples exported with `valid=0`, never dropped)*

---

# 18. Phase 15 — iOS Implementation Mapping

Prefer native iOS technologies where they provide equivalent functionality.

| Function | Preferred Technology |
|---|---|
| Camera capture | AVFoundation |
| Frame transport | Core Video |
| Image processing | Accelerate / vImage |
| Basic image operations | Core Image |
| Feature/vision primitives | Vision where applicable |
| Custom GPU processing | Metal |
| ML inference | Core ML |
| Neural Engine | Core ML-supported models |
| Complex CV | OpenCV only where justified |
| Homography | Swift/OpenCV/custom optimized implementation based on benchmark |

Do not assume Neural Engine acceleration applies to classical CV.

### Requirements

- [ ] Measure CPU/GPU/ANE usage.
- [ ] Avoid unnecessary frame copies.
- [ ] Avoid unnecessary pixel-format conversion.
- [ ] Reuse buffers.
- [ ] Use low-resolution images for candidate detection where possible.
- [ ] Use higher-resolution crops for geometry refinement.
- [ ] Use canonical ROI for OCR.
- [ ] Keep expensive processing off main thread.

### Build Gate 15

- [ ] iOS implementation selected based on measurement.
- [ ] CPU/GPU/ANE path documented.
- [ ] Memory copies minimized.
- [ ] Frame pipeline profiled.
- [ ] Energy impact measured where practical.

---

# 19. Phase 16 — Processing Cadence

Implement independent cadences.

Starting policy:

```text
UI:
    Native display refresh rate

Camera:
    Native capture rate

Lightweight tracking:
    Every available frame

Geometry validation:
    5–15 Hz initially

Candidate detection:
    1–5 Hz initially

Global reacquisition:
    Only when needed

OCR:
    As required by field sampling rate
```

Do not treat these as permanent numbers.

- [ ] Measure.
- [ ] Tune.
- [ ] Document.
- [ ] Regression-test.

### Build Gate 16

- [ ] Tracking is higher frequency than detection.
- [ ] OCR does not run unnecessarily.
- [ ] Detection does not block tracking.
- [ ] Stale work is dropped.
- [ ] End-to-end latency bounded.

---

# 20. Phase 17 — Debug Telemetry

Add a developer-only overlay containing:

```text
State:
    SEARCHING / ATTRACTING / LOCKED / DEGRADED / REACQUIRING / LOST

Candidate Confidence:
Tracking Confidence:
Geometry Confidence:
Homography Error:
RANSAC Inliers:
Optical Flow Residual:
Edge Alignment:
Aspect Ratio:
Area Ratio:
Motion Prediction Error:
OCR Confidence:
Decimal Confidence:

Capture FPS:
Tracking FPS:
Detection FPS:
OCR FPS:
UI FPS:

Dropped Frames:
Queue Depth:
Processing Latency:
```

Visualize:

- [ ] Candidate quadrilaterals.
- [ ] Selected target.
- [ ] Tracked corners.
- [ ] Feature points.
- [ ] Inliers/outliers.
- [ ] Optical flow vectors.
- [ ] Homography.
- [ ] Canonical screen.
- [ ] Field ROIs.
- [ ] OCR results.
- [ ] Confidence components.
- [ ] Reacquisition region.

### Build Gate 17

- [ ] All confidence components inspectable.
- [ ] Tracking failure visually diagnosable.
- [ ] Fast-motion drift reproducible with telemetry.
- [ ] Instrumentation can be disabled.
- [ ] Instrumentation overhead measured.

---

# 21. Phase 18 — Automated Test Harness

Build an offline test corpus containing:

### Geometry

- [ ] Frontal screen.
- [ ] Mild perspective.
- [ ] Severe perspective.
- [ ] Roll.
- [ ] Yaw.
- [ ] Pitch.
- [ ] Scale changes.

### Motion

- [ ] Slow translation.
- [ ] Fast translation.
- [ ] Sudden movement.
- [ ] Combined motion.
- [ ] Bouncing DVD-style movement.

### Environment

- [ ] Low contrast.
- [ ] Glare.
- [ ] Reflection.
- [ ] Motion blur.
- [ ] Partial occlusion.
- [ ] Variable lighting.

### Distractors

- [ ] Laptop display.
- [ ] Phone.
- [ ] Window.
- [ ] Poster.
- [ ] Picture frame.
- [ ] Random rectangular object.

### Ground truth

For every test sequence:

```text
Frame
Ground-truth corners
Ground-truth screen identity
Ground-truth lock state
Ground-truth measurement validity
```

Measure:

```text
Corner error
Homography reprojection error
Screen IoU
Tracking success rate
False lock rate
False healthy-lock rate
Reacquisition time
Measurement validity
OCR accuracy
Decimal accuracy
```

---

# 22. Phase 19 — Critical Regression Test: Fast-Motion Drift

Create a permanent regression test for the exact known failure:

```text
1. Lock onto display.
2. Move display/camera rapidly.
3. Cause tracker to lose correspondence.
4. Ensure real detector finds display at new position.
5. Ensure old tracker position diverges.
```

Expected:

```text
Old behavior:
    LOCKED
    Healthy confidence
    Wrong geometry
    Wrong measurement validity

Required behavior:
    LOCKED
      ↓
    DEGRADED
      ↓
    Measurement invalidated
      ↓
    Reacquisition
      ↓
    Validated relock
```

### Build Gate 18

- [x] Regression sequence exists.  *(DriftRegressionTests: lock → drift → invalidate → organic relock, real detector+tracker on rendered frames)*
- [x] Old failure reproduced before fix.  *(observed live in the §9 bounce run and re-reproduced twice against interim verifiers — six-frame screenshot evidence, ARCHITECTURE.md §11)*
- [x] New implementation detects failure.  *(invalidation on the first drift frame)*
- [x] Confidence falls.  *(hard veto → 0)*
- [x] Lock state changes.  *(leaves .locked same frame; trace shows DEGRADED/REACQUIRING)*
- [x] Measurement invalidated.  *(fieldROIs empty while unverified — asserted E2E)*
- [x] Reacquisition occurs.  *(organic relock at frame 95 in E2E; live relocks during overlap windows)*
- [x] Validated relock succeeds.  *(E2E organic relock at frame 95; trace: 8 LOCKED passes across 81, every one verified — 0 LOCKED-while-unverified)*
- [x] No false healthy lock remains.  *(0 LOCKED-while-unverified across the 81-pass bounce trace — synthetic rig only; ARCHITECTURE.md §11)*

---

# 23. Phase 20 — State Machine

Implement explicit state transitions:

```text
SEARCHING
    ↓
CANDIDATE_FOUND
    ↓
ATTRACTING
    ↓
LOCK_VALIDATING
    ↓
LOCKED_HEALTHY
    ↓
LOCKED_DEGRADED
    ↓
LOCAL_REACQUIRING
    ↓
GLOBAL_REACQUIRING
    ↓
LOCK_VALIDATING
```

Allowed transitions:

```text
SEARCHING
→ CANDIDATE_FOUND

CANDIDATE_FOUND
→ ATTRACTING
→ SEARCHING

ATTRACTING
→ LOCK_VALIDATING
→ SEARCHING

LOCK_VALIDATING
→ LOCKED_HEALTHY
→ SEARCHING

LOCKED_HEALTHY
→ LOCKED_DEGRADED
→ LOST

LOCKED_DEGRADED
→ LOCKED_HEALTHY
→ LOCAL_REACQUIRING

LOCAL_REACQUIRING
→ LOCK_VALIDATING
→ GLOBAL_REACQUIRING

GLOBAL_REACQUIRING
→ CANDIDATE_FOUND
→ SEARCHING
```

### Build Gate 19

- [ ] All states explicit.
- [ ] Invalid transitions rejected.
- [ ] State transitions logged.
- [ ] Lock cannot persist indefinitely without validation.
- [ ] Lost tracking cannot produce valid measurements.

---

# 24. Phase 21 — Existing Architecture Integration

## KEEP

- [ ] Manual selection.
- [ ] Candidate detection architecture where functioning.
- [ ] Magnetic snapping.
- [ ] Target-relative selection.
- [ ] Four-point geometry.
- [ ] Homography concept.
- [ ] Perspective normalization.
- [ ] Hierarchical tracking concept.
- [ ] Multi-field detection.
- [ ] Format-aware OCR.
- [ ] Decimal-aware processing.
- [ ] Temporal validation.
- [ ] Bounded/latest-frame processing.
- [ ] Existing performance instrumentation.

## MODIFY

- [ ] Candidate confidence fusion.
- [ ] Four-corner refinement.
- [ ] Homography validation.
- [ ] Tracking confidence.
- [ ] Tracking failure detection.
- [ ] Reacquisition triggers.
- [ ] Overlay geometry.
- [ ] Measurement validity.
- [ ] Decimal confidence.
- [ ] Performance telemetry.

## REPLACE ONLY IF MEASURED EVIDENCE JUSTIFIES IT

- [ ] Existing tracker.
- [ ] Existing geometry estimator.
- [ ] Existing screen detector.
- [ ] Existing OCR engine.

## ADD

- [ ] Independent geometric confidence.
- [ ] Hard confidence vetoes.
- [ ] Fast-motion anti-drift validation.
- [ ] Periodic independent screen revalidation.
- [ ] Explicit degraded state.
- [ ] Measurement invalidation on tracking loss.
- [ ] Ground-truth tracking test corpus.
- [ ] Permanent fast-motion regression test.

---

# 25. Phase 22 — Acceptance Criteria

The implementation is not complete until all conditions below pass.

## Detection

- [ ] Physical display detected independently of OCR.
- [ ] False-positive detection rate measured.
- [ ] Multiple candidate displays supported.

## Geometry

- [ ] Four corners correctly identified.
- [ ] Corner ordering stable.
- [ ] Corner identity stable through rotation.
- [ ] Degenerate geometry rejected.

## Homography

- [ ] Homography robustly estimated.
- [ ] Reprojection error measured.
- [ ] Invalid homographies rejected.

## Tracking

- [ ] Stable tracking under translation.
- [ ] Stable tracking under scale.
- [ ] Stable tracking under roll.
- [ ] Stable tracking under yaw.
- [ ] Stable tracking under pitch.
- [ ] Stable tracking under combined motion.
- [x] Fast-motion drift detected.  *(23 transit vetoes in 81 passes under continuous bounce — DEBUG verdict trace, ARCHITECTURE.md §11)*
- [x] No false healthy lock.  *(0 LOCKED-while-unverified across the 81-pass trace; synthetic rig only)*

## Reacquisition

- [ ] Local reacquisition works.
- [ ] Global reacquisition works.
- [ ] Re-lock requires independent validation.

## Overlay

- [ ] Overlay wraps physical screen.
- [ ] Overlay deforms with perspective.
- [ ] Overlay follows distance.
- [ ] Overlay follows rotation.
- [ ] Overlay reflects confidence state.

## OCR

- [ ] Canonical screen feeds OCR.
- [ ] Multi-field OCR works.
- [ ] Field-level tracking works.
- [ ] Decimal recognition validated.
- [ ] Temporal validation works.

## Data Integrity

- [x] Invalid tracking invalidates measurement.  *(DriftRegressionTests E2E; GatingTests.testFieldBackedCardLock_dropsTheMomentTrackingIsInvalidated)*
- [x] Invalid geometry invalidates measurement.  *(`measurementsValid` gates field ROIs; asserted E2E in DriftRegressionTests and GatingTests)*
- [x] Low decimal confidence flags measurement.  *(DecimalIntegrityTests.testVeryLowDecimalConfidenceVetoesAsAmbiguousDecimal)*
- [ ] Stale OCR cannot masquerade as current valid data.

## Performance

- [ ] UI remains responsive.
- [ ] Processing queues bounded.
- [ ] No unbounded stale-frame accumulation.
- [ ] Main thread not blocked by OCR/CV/ML.
- [ ] Performance regressions have deterministic tests.

---

# 26. Phase 23 — Required Final Engineering Report

At completion, generate:

```text
docs/SCREEN_TRACKING_IMPLEMENTATION_REPORT.md
```

Include:

## A. Architecture

- [ ] Final pipeline diagram.
- [ ] State machine.
- [ ] Thread/queue architecture.

## B. Detection

- [ ] Detection method.
- [ ] Candidate score.
- [ ] False-positive performance.

## C. Geometry

- [ ] Corner detection.
- [ ] Corner refinement.
- [ ] Homography method.

## D. Tracking

- [ ] Tracker selected.
- [ ] Tracking cadence.
- [ ] Validation cadence.
- [ ] Reacquisition cadence.

## E. Confidence

- [ ] Every confidence component.
- [ ] Weight derivation.
- [ ] Hard vetoes.
- [ ] Calibration methodology.

## F. Fast-Motion Failure

- [ ] Original failure.
- [ ] Root cause.
- [ ] Corrective architecture.
- [ ] Regression test.
- [ ] Before/after evidence.

## G. OCR

- [ ] OCR engine.
- [ ] Format-aware logic.
- [ ] Decimal handling.
- [ ] Temporal validation.

## H. Performance

- [ ] Capture FPS.
- [ ] Tracking FPS.
- [ ] Detection FPS.
- [ ] OCR FPS.
- [ ] UI FPS.
- [ ] p95/p99 latency.
- [ ] CPU.
- [ ] GPU.
- [ ] Memory.
- [ ] Dropped frames.

## I. Reliability

- [ ] Tracking success rate.
- [ ] False-lock rate.
- [ ] False healthy-lock rate.
- [ ] Reacquisition success rate.
- [ ] Reacquisition latency.
- [ ] OCR accuracy.
- [ ] Decimal accuracy.

## J. Known Limitations

- [ ] Explicitly documented.

## K. Remaining Work

Prioritize:

1. Correctness.
2. Data integrity.
3. Reliability.
4. Performance.
5. Energy.
6. Complexity.

---

# 27. Final Autonomous Execution Rules

Claude Code / Codex must follow this workflow:

```text
READ
  ↓
UNDERSTAND
  ↓
BUILD BASELINE
  ↓
REPRODUCE FAILURE
  ↓
MEASURE
  ↓
IMPLEMENT ONE PHASE
  ↓
BUILD
  ↓
TEST
  ↓
PROFILE
  ↓
VERIFY
  ↓
CHECK GATE
  ↓
DOCUMENT
  ↓
NEXT PHASE
```

Do not:

- [ ] Rewrite the entire application without evidence.
- [ ] Replace working components without benchmarks.
- [ ] Claim tracking reliability from a single demo.
- [ ] Claim confidence is correct without testing drift.
- [ ] Use OCR confidence as a proxy for geometric correctness.
- [ ] Hide degraded tracking behind a stable-looking UI.
- [ ] Keep stale geometry on screen indefinitely.
- [ ] Mark a gate complete because code compiles.
- [ ] Mark a gate complete because unit tests pass if live behavior is unverified.

Every `[x]` must have evidence.

Evidence may be:

```text
Test name
Benchmark result
Screenshot
Video sequence
Log output
Metric
Unit test
Integration test
Device test
```

---

# FINAL DEFINITION OF DONE

DAQPal is considered successful when it can reliably establish:

> **"This exact four-sided planar region is the intended physical display surface. These are its four corners. This is its current projective geometry. The geometry is independently validated. The tracker remains attached to the same physical surface. If that claim becomes uncertain, the system detects the uncertainty, invalidates the lock and measurement, and reacquires the screen rather than silently reporting stale or incorrect data."**

The system must therefore demonstrate:

```text
DETECT
  ↓
LOCALIZE
  ↓
VALIDATE
  ↓
LOCK
  ↓
TRACK
  ↓
INDEPENDENTLY VERIFY
  ↓
DETECT DRIFT
  ↓
INVALIDATE
  ↓
REACQUIRE
  ↓
REVALIDATE
  ↓
RESUME MEASUREMENT
```

**The primary success metric is not "the overlay stays on screen."**

**The primary success metric is "the overlay and OCR measurement remain geometrically truthful."**
