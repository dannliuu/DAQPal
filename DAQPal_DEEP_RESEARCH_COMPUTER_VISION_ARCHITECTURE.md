# DAQPal — Deep-Research Computer Vision Architecture for Screen Detection, Homography, Tracking & OCR

## Executive Summary

The strongest research-backed architecture for DAQPal is **not a single homography algorithm**. It should be a **hybrid planar-object tracking system** with:

- Fast frame-to-frame tracking.
- Explicit four-corner screen geometry.
- Homography-based canonical screen coordinates.
- Independent geometric verification.
- Periodic fresh detection to detect tracker drift.
- Hierarchical local/global reacquisition.
- OCR and measurement validity gates.
- Optional learned homography as a fallback only after classical CV is benchmarked.

The central reliability principle is:

> **The tracker proposes where the screen is. Independent geometry validation determines whether the tracker is still attached to the intended physical display. Only validated geometry may feed OCR and produce a valid measurement.**

---

## Recommended DAQPal Architecture

```text
                    CAMERA FRAME
                         │
                         ▼
              ┌─────────────────────┐
              │ Screen Candidate     │
              │ Detection            │
              │                     │
              │ Apple Vision         │
              │ + Existing CV        │
              │ + Edge/Contour CV    │
              └──────────┬──────────┘
                         │
                         ▼
                 FOUR SCREEN CORNERS
                         │
                         ▼
                 GEOMETRIC VALIDATION
                         │
                         ▼
                     HOMOGRAPHY
                         │
                         ▼
              CANONICAL SCREEN SPACE
                         │
                         ▼
              ┌─────────────────────┐
              │ FAST TRACKING       │
              │                     │
              │ Optical Flow        │
              │ Feature Tracking    │
              │ Vision Tracking     │
              └──────────┬──────────┘
                         │
                         ▼
              TRACKED QUADRILATERAL
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
       FAST TRACKER            INDEPENDENT
       RESULT                  VALIDATION
                                    │
                     ┌──────────────┼──────────────┐
                     │              │              │
                     ▼              ▼              ▼
                  RANSAC       Edge/Line       Fresh Vision
                  Features     Alignment       Detection
                     │              │              │
                     └──────────────┼──────────────┘
                                    │
                                    ▼
                         GEOMETRIC CONSENSUS
                                    │
                          ┌─────────┴─────────┐
                          │                   │
                        VALID              INVALID
                          │                   │
                          ▼                   ▼
                   LOCKED_HEALTHY        DEGRADED
                          │                   │
                          ▼                   ▼
                         OCR            LOCAL SEARCH
                                              │
                                              ▼
                                         GLOBAL SEARCH
                                              │
                                              ▼
                                  OPTIONAL DEEP HOMOGRAPHY
                                              │
                                              ▼
                                   INDEPENDENT VALIDATION
                                              │
                                              ▼
                                            RELOCK
```

---

# 1. Native Apple Vision Should Be the First Baseline

Apple's rectangle detector is closely aligned with DAQPal's need to identify planar rectangular displays.

`VNDetectRectanglesRequest` is designed to find projected rectangular regions and produces `VNRectangleObservation` results representing four vertices. It exposes constraints including aspect ratio, quadrature tolerance, minimum size, minimum confidence, and maximum observations.

Conceptually:

```text
Camera Frame
    ↓
VNDetectRectanglesRequest
    ↓
VNRectangleObservation
    ↓
topLeft
topRight
bottomRight
bottomLeft
```

This should be the first implementation benchmark rather than immediately training a custom neural network.

### Important Caveat

Vision detects **rectangular regions**, not necessarily "LCD screens."

Potential false positives include:

- Laptop screens.
- Windows.
- Picture frames.
- Instrument bezels.
- Posters.
- Other rectangular objects.

Therefore:

> **Treat Vision as a geometric candidate generator, not a screen-identity classifier.**

The next stage should determine whether the candidate is actually the intended display.

---

# 2. Benchmark Apple's Rectangle Tracker Immediately

Evaluate `VNTrackRectangleRequest` as a low-cost native baseline for frame-to-frame tracking.

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

Benchmark:

- Tracking success rate.
- Tracking drift rate.
- Corner accuracy.
- Fast-motion behavior.
- Motion-blur behavior.
- Partial occlusion behavior.
- Perspective-change behavior.
- Recovery behavior.

Compare it directly against the current DAQPal tracker.

The key conceptual distinction is:

```text
Tracker proposes:
    "The screen is here."

Validator asks:
    "Is there independent evidence that it is still here?"
```

A tracking result must not automatically imply:

```text
LOCKED_HEALTHY
```

It must pass independent geometry validation.

---

# 3. WOFT — Weighted Optical Flow for Planar Object Tracking

One of the most directly relevant research directions is:

**Planar Object Tracking via Weighted Optical Flow — Serych & Matas.**

WOFT addresses planar-object tracking and estimates a full 8-DOF homography using dense optical flow while learning weights to suppress incorrect optical-flow correspondences.

This maps well to DAQPal's problem:

```text
Track a planar object
+
Estimate its projective transformation
+
Reject bad correspondences
```

### Recommended DAQPal Use

Do not immediately port the entire research implementation to Core ML.

Instead, use its architectural principles:

```text
Optical Flow
    ↓
Correspondence Quality
    ↓
Reject Outliers
    ↓
Homography
    ↓
Four Corners
```

A practical implementation can approximate the same idea:

```text
Tracked Features
       ↓
Optical Flow
       ↓
Forward-Backward Consistency
       ↓
Remove Bad Points
       ↓
RANSAC
       ↓
Homography
       ↓
Reprojection Error
```

This provides measurable tracking quality signals.

---

# 4. Deep Image Homography — DeTone et al.

**Deep Image Homography Estimation — DeTone, Malisiewicz, Rabinovich**

This research uses a CNN to estimate an 8-DOF homography between image regions using a four-point parameterization.

The conceptual mapping to DAQPal is:

```text
Reference Screen
       ↓
Current Camera Frame
       ↓
Deep Homography Network
       ↓
8-DOF Homography
       ↓
Four Projected Corners
```

This is attractive because DAQPal explicitly needs four screen corners and a projective transformation.

However, do not initially put a neural homography model into the primary tracking loop.

The core problem is not merely:

> "Can we estimate a homography?"

It is:

> "Can we know that the estimated homography still corresponds to the correct physical screen?"

A neural network can produce a plausible but incorrect homography.

Therefore:

```text
Deep Homography
      ↓
Candidate Geometry
      ↓
Independent Validation
      ↓
Accept / Reject
```

Recommended role:

> **Optional research fallback / difficult reacquisition path.**

---

# 5. Content-Aware Unsupervised Deep Homography

**Content-Aware Unsupervised Deep Homography Estimation**

This research is particularly interesting for DAQPal because sparse feature matching can become unreliable in low-light and low-texture imagery. The approach investigates learned outlier selection to identify more reliable regions for homography estimation.

Potentially relevant targets include:

- LCD screens.
- Seven-segment displays.
- E-ink displays.
- Low-contrast instrumentation.
- Screens with large uniform backgrounds.

Conceptual pipeline:

```text
Screen Surface
    ↓
Reliable Region Selection
    ↓
Homography
```

rather than:

```text
Entire Screen
    ↓
Every Pixel / Feature Is Trusted
```

Classify this initially as:

> **Research fallback / experimental branch.**

The research results should not be assumed to transfer directly to DAQPal's target displays. Build a DAQPal-specific benchmark.

---

# 6. Feature Matching + RANSAC as Independent Geometric Verification

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

Evaluate feature methods appropriate to the deployment constraints, potentially including:

- ORB.
- AKAZE.
- SIFT where permitted and practical.
- Other native or OpenCV-compatible feature methods.

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

Recommended role:

> **Independent validator, not necessarily the primary tracker.**

Example:

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

This directly addresses the known failure mode in which a tracker remains apparently healthy after losing physical correspondence.

---

# 7. Sparse Optical Flow

Evaluate sparse optical-flow tracking for high-frequency corner and feature propagation.

Candidate pipeline:

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

- High-frequency tracking.
- Corner propagation.
- Low-latency motion estimation.
- Fast camera movement.

Do not rely solely on optical flow.

Evaluate:

- Forward-backward flow consistency.
- Flow residual.
- Number of valid points.
- Spatial distribution of tracked points.
- Corner consistency.

A tracker with many points concentrated in one small region should not automatically be considered reliable.

Required failure conditions should include cases such as:

```text
Forward-backward error > threshold
        OR
Valid tracked points < minimum
        OR
Tracked points become spatially degenerate
```

Then:

```text
Tracking confidence decreases
```

---

# 8. Edge and Line-Based Screen Detection

LCD screens are planar rectangles with potentially strong physical boundaries. Investigate a geometry-first approach:

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

- Canny edges.
- Hough lines.
- Line segment detection.
- Contour extraction.
- Polygon approximation.

This can be useful when:

- Text features are unavailable.
- The display is low texture.
- OCR is unreliable.
- The display is visible but characters are unreadable.

However, edge detection alone can produce false positives from:

- Device housings.
- Bezels.
- Reflections.
- Window frames.
- Other rectangular structures.

Use edge/line geometry as a complementary candidate detector or validation signal.

---

# 9. RANSAC Should Be Core to Geometry Validation

The geometry path should not simply be:

```text
Feature Matches
    ↓
Homography
```

It should be:

```text
Feature Matches
    ↓
Candidate Correspondences
    ↓
RANSAC
    ↓
Inliers / Outliers
    ↓
Homography
    ↓
Reprojection Error
```

This provides independent telemetry:

```text
Inliers
Outliers
Inlier Ratio
Reprojection Error
Corner Error
```

Example failure:

```text
Tracker:
    Confidence = 0.95

RANSAC:
    Inlier ratio = 0.18

Homography:
    Reprojection error = 25 px

Fresh detector:
    Screen is 300 px away
```

Correct result:

```text
TRACKING_LOST
```

Incorrect result:

```text
TRACKING_CONFIDENCE = 0.95
```

---

# 10. RANSAC-Flow and Coarse-to-Fine Alignment

The RANSAC-Flow research suggests a useful two-stage alignment strategy:

```text
Coarse Parametric Alignment
        ↓
Homography
        ↓
Fine Non-Parametric Alignment
        ↓
Dense Alignment
```

For DAQPal:

```text
Stage 1
Fast Homography
    ↓
Approximate Screen Position

Stage 2
Optical Flow / Fine Alignment
    ↓
Precise Screen Position
```

This may be preferable to forcing a single algorithm to handle all tracking requirements.

---

# 11. Recommended DAQPal Research Architecture

```text
                    INITIAL DETECTION
                           │
              ┌────────────┼────────────┐
              │            │            │
              ▼            ▼            ▼
         Apple Vision   Edge/Lines   Existing DAQPal
         Rectangle      Contours     Detector
              │            │            │
              └────────────┼────────────┘
                           ▼
                     Candidate Fusion
                           │
                           ▼
                   Four-Corner Geometry
                           │
                           ▼
                      Homography
                           │
                           ▼
                  Canonical Screen ROI
                           │
                           ▼
                  ┌─────────────────┐
                  │ FAST TRACK LOOP │
                  │                 │
                  │ Optical Flow    │
                  │ Feature Track   │
                  │ Vision Track    │
                  └────────┬────────┘
                           │
                           ▼
                  Candidate Homography
                           │
                           ▼
                 INDEPENDENT VALIDATION
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
        RANSAC        Edge Alignment    Fresh Vision
        Features                        Detection
           │               │               │
           └───────────────┼───────────────┘
                           ▼
                   Geometric Consensus
                           │
                 ┌─────────┴─────────┐
                 │                   │
               PASS                FAIL
                 │                   │
                 ▼                   ▼
             TRACKING            DEGRADED
             HEALTHY                 │
                 │                   ▼
                 │             LOCAL REACQUISITION
                 │                   │
                 │                   ▼
                 │             GLOBAL REACQUISITION
                 │                   │
                 │                   ▼
                 │          Optional Deep Homography
                 │                   │
                 │                   ▼
                 │          Independent Validation
                 │                   │
                 └───────────┬───────┘
                             ▼
                          RELOCK
                             │
                             ▼
                     Perspective Warp
                             │
                             ▼
                       Screen Fields
                             │
                             ▼
                            OCR
                             │
                             ▼
                      Decimal Validation
                             │
                             ▼
                    Temporal Validation
                             │
                             ▼
                     Valid Measurement
```

---

# 12. Separate "Tracking" From "Truth"

This is the most important research insight for DAQPal.

The system should have three distinct concepts.

## Tracker

> "Where do I think the screen moved?"

## Validator

> "Does independent evidence agree with that location?"

## Measurement Gate

> "Is there enough evidence to allow this OCR value to become a valid measurement?"

These must not be the same thing.

Recommended architecture:

```text
Tracker
    ↓
Proposed Geometry
    ↓
Validator
    ↓
Validated Geometry
    ↓
OCR
    ↓
Measurement Gate
```

This architecture also strengthens the decimal-validation problem.

For example, if OCR reports:

```text
808
```

the system should ask:

```text
Is screen geometry valid?
Is field geometry valid?
Is field identity valid?
Is decimal position valid?
Is value temporally consistent?
```

Only then:

```text
VALID MEASUREMENT
```

---

# 13. Recommended Implementation Order

## Phase A — Immediate

- [ ] Benchmark `VNDetectRectanglesRequest`.
- [ ] Benchmark `VNTrackRectangleRequest`.
- [ ] Compare against current DAQPal detector/tracker.
- [ ] Extract and maintain four explicit screen corners.
- [ ] Build homography from four corners.
- [ ] Implement robust quadrilateral validation.

## Phase B — Core Reliability

- [ ] Add optical-flow tracking.
- [ ] Add forward/backward flow consistency.
- [ ] Add feature tracking.
- [ ] Add RANSAC homography validation.
- [ ] Add reprojection error.
- [ ] Add independent periodic screen detection.
- [ ] Add hard failure vetoes.

## Phase C — Anti-Drift

- [ ] Create `LOCKED_HEALTHY`.
- [ ] Create `LOCKED_DEGRADED`.
- [ ] Create `REACQUIRING`.
- [ ] Invalidate measurement immediately on geometric failure.
- [ ] Implement local reacquisition.
- [ ] Implement global reacquisition.

## Phase D — Advanced Research

- [ ] Benchmark deep homography.
- [ ] Benchmark content-aware deep homography.
- [ ] Investigate Core ML conversion.
- [ ] Benchmark Neural Engine / CPU / GPU execution.
- [ ] Adopt only if classical methods fail the DAQPal benchmark.

---

# 14. Research Ranking

| Rank | Method | DAQPal Role | Priority |
|---|---|---|---|
| 1 | Apple Vision Rectangle Detection | Initial detection / revalidation | Implement now |
| 2 | Homography + geometric validation | Core screen geometry | Implement now |
| 3 | Optical flow | High-frequency tracking | Implement now |
| 4 | Feature matching + RANSAC | Independent validation | Implement now |
| 5 | Vision rectangle tracking | Tracker benchmark | Test now |
| 6 | Edge/line geometry | Low-texture fallback | Benchmark |
| 7 | WOFT concepts | Advanced planar tracking research | Study/benchmark |
| 8 | Deep Image Homography | Reacquisition fallback | Research |
| 9 | Content-Aware Deep Homography | Low-texture fallback | Research |
| 10 | RANSAC-Flow concepts | Coarse-to-fine alignment | Architectural inspiration |

---

# 15. Quantitative Benchmark Requirements

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

> The percentage of frames in which the system reports `LOCKED_HEALTHY` while the tracked quadrilateral is no longer geometrically attached to the intended physical display.

This metric should approach zero.

A system with slightly lower tracking recall but near-zero false healthy-lock rate may be preferable to a system that tracks more aggressively but silently reports incorrect measurements.

---

# 16. Required DAQPal Benchmark Dataset

Create a representative dataset containing actual DAQPal target displays.

## Display Types

- [ ] LCD.
- [ ] Seven-segment display.
- [ ] E-ink.
- [ ] OLED.
- [ ] Digital multimeter.
- [ ] Temperature gun.
- [ ] Laboratory instrumentation.
- [ ] Industrial instrumentation.

## Motion

- [ ] Slow movement.
- [ ] Fast movement.
- [ ] Sudden movement.
- [ ] Rotation.
- [ ] Yaw.
- [ ] Pitch.
- [ ] Combined motion.

## Visual Conditions

- [ ] Bright light.
- [ ] Low light.
- [ ] Glare.
- [ ] Reflection.
- [ ] Motion blur.
- [ ] Partial occlusion.
- [ ] Low contrast.
- [ ] Dirty/scratched display.
- [ ] Display bezel partially visible.

## Ground Truth

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

# 17. Deep Learning Integration Decision Gate

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

# 18. Research Evidence Record

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

# 19. Final Research Acceptance Gate

The research phase is complete only when the implementation team can answer:

- [ ] Which method detects the physical screen most reliably?
- [ ] Which method produces the most accurate four corners?
- [ ] Which method performs best under fast motion?
- [ ] Which method performs best under low texture?
- [ ] Which method detects tracker drift earliest?
- [ ] Which method is fastest on the target iPhone?
- [ ] Which method consumes the least energy?
- [ ] Which method is best for continuous tracking?
- [ ] Which method is best for reacquisition?
- [ ] Which method is best for independent validation?
- [ ] Is a deep-learning homography model actually necessary?
- [ ] Can the final system achieve near-zero false healthy-lock events?
- [ ] Can the final system guarantee that a valid OCR measurement corresponds to the intended physical display?

The final architecture must be selected from **measured DAQPal-specific evidence**, not from paper benchmarks alone.

---

# 20. Final Recommendation

The most defensible research-backed direction for DAQPal is:

> **Build a hybrid planar-object tracking architecture in which native rectangle detection establishes the initial four-corner geometry, homography defines the screen's projective coordinate system, optical flow and/or feature tracking provide high-frequency motion updates, and RANSAC-based geometric verification independently determines whether the tracker is still attached to the intended physical display. Use periodic fresh detection to detect tracker drift. Reserve deep homography models for difficult reacquisition cases only after the classical pipeline has been quantitatively benchmarked.**

The most important immediate experiment is a head-to-head benchmark of:

1. Current DAQPal tracker.
2. `VNTrackRectangleRequest`.
3. Optical-flow + RANSAC homography.

Use the exact fast-motion videos where DAQPal currently drifts.

That experiment will determine whether the problem can be solved primarily with native iOS and classical CV, or whether the particular display conditions justify a learned homography model.

---

# Research Sources

- Apple Developer Documentation — `VNDetectRectanglesRequest`
- Apple Developer Documentation — `VNTrackRectangleRequest`
- DeTone, Malisiewicz, Rabinovich — *Deep Image Homography Estimation*
- Serych & Matas — *Planar Object Tracking via Weighted Optical Flow (WOFT)*
- *Content-Aware Unsupervised Deep Homography Estimation*
- *RANSAC-Flow: Generalized Two-Stage Image Alignment*

> **Note:** Research methods should be validated against DAQPal-specific data. Results reported on general computer-vision datasets should not be assumed to transfer directly to LCD, seven-segment, E-ink, or scientific-instrument displays.
