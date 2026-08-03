# Intelligent Screen Selection, Tracking, and Multi-Field OCR
## Engineering Specification and Buildable Checkpoint Plan for Claude Code / Codex

> **Purpose:** Transform the existing window-selection tool into a high-performance, intelligent screen-locking and data-acquisition system. The system should diagnose and eliminate selection UI lag, detect likely instrument/device screens, magnetically snap to them, lock and track them through motion and perspective changes, understand screen structure, detect multiple numeric fields, allow user selection of fields, and continuously extract structured time-series data through modular OCR.

---

## Status annotations — last updated 2026-07-27

The checkboxes below are annotated with actual build state. Three markers are used:

| Marker | Meaning |
|---|---|
| `[x]` | Done and verified. |
| `[~]` | **Partial** — the qualification is stated in a parenthetical on the line. Most now read "holds while steady, blocked under motion" or "unit-tested but not observed live". |
| `[ ]` | Not started, or not verifiable yet. |

**Tally: 126 done · 48 partial · 79 open.**

### Gate 14 is wired, and the pipeline runs live

`ScreenLockPipeline` now runs inline in the capture drain, before recognition. A live Simulator
run (`-daqpal-screen-lock`) was driven end to end and screenshotted at each stage:

> AUTO on → detector proposes candidates with fused confidence (94% / 81% / 54%) → magnet
> attracts → **LOCKED** → tracker holds geometry → display warped to canonical space → fields
> analyzed → field selected → mirrored to a recordable device → **value read through tracked
> geometry** (FIELD 1 = 12.574 @ 68.1%, LOCKED).

So Gates 4–10 are no longer "components with no caller" — they are invoked on every frame at
their intended cadences, and Gate 12's four integration boxes are checked.

### The blocker that keeps most tracking boxes open

**Under fast motion the tracker drifts off the target while continuing to report healthy
confidence.** Observed directly under `-daqpal-demo-motion bounce`: the tracked quad lags the
panel, then leaves it entirely, while the UI still shows `LOCKED` with a value — even though
the quad sits over empty background and the detector is correctly re-proposing the real panel
at 94%.

This is a **correctness** failure, not a performance one: silently presenting a stale value as
locked is worse than presenting nothing. Every "tracking survives …" box, and Gate 15 entirely,
stays open because of it. Steady-state capture is correct and is what the live run above shows.

### Three bugs that only the live run found

All three compiled and unit-tested clean, and were invisible to code review:
1. Attraction never accumulated across frames — the machine could reach `ATTRACTING` but **no
   lock was ever reachable**.
2. Field-backed devices were filtered out of the processor config by a `roi != nil` test — so
   selecting a field was a **no-op end to end**.
3. `AppState.apply` discarded field-backed readings *after* the processor computed them, via the
   same faulty `roi != nil` proxy.

### Deliberate deviations, recorded rather than checked off

- **Gate 1** asks for FPS/CPU/GPU/memory profiling. The lag was diagnosed by observation-graph
  analysis and is regression-tested at the invalidation level instead. No profiler numbers
  exist, so those boxes stay open and **no performance figure is claimed anywhere**.
- **Gate 2**'s "feels fluid" items are `[~]`: the mechanism is fixed and locked down by tests,
  but subjective fluidity cannot be verified without a physical device.
- **Gate 12**'s end-to-end latency is unmeasured; `PipelineMetrics` records the stages but no
  figure has been captured from a run.

Supporting documents: `ARCHITECTURE.md` (structure, root-cause analysis, integration status,
open defects) · `PROGRESS.md` (gate scorecard) · `IMPLEMENTATION_NOTES.md` (chronology).

---

# 0. Mission and Engineering Principles

The immediate problem is that the current window-selection tool feels rough and lags when the user moves or resizes the selection window.

The ultimate objective is to evolve the application from a basic rectangular crop/selection tool into an intelligent **screen-locking and multi-field data-acquisition system**.

The ideal workflow is:

```text
Manual Selection
      ↓
Candidate Screen Detection
      ↓
Magnetic Attraction
      ↓
Automatic Alignment
      ↓
Target Lock
      ↓
Persistent Tracking
      ↓
Perspective Normalization
      ↓
Screen Understanding
      ↓
Multi-Field Detection
      ↓
User Field Selection
      ↓
Field Locking
      ↓
Format-Aware OCR
      ↓
Temporal Validation
      ↓
Structured Time-Series Data
      ↓
Export
```

## Core engineering principles

1. **Profile before optimizing.**
   Do not guess at the cause of lag.

2. **Keep the UI responsive.**
   Expensive capture, CV, ML, and OCR work must not block interactive selection.

3. **Separate concerns.**
   Detection, tracking, magnetic snapping, screen understanding, OCR, and UI rendering should be independently replaceable.

4. **Prefer lightweight high-frequency processing.**
   Use fast tracking between slower detection/reacquisition passes.

5. **Exploit structure.**
   Instrument displays often have fixed-format numbers. Use expected character sets, digit counts, decimal positions, units, and temporal consistency to improve OCR.

6. **Use temporal information.**
   Consecutive frames should improve tracking and OCR reliability.

7. **Prefer the newest frame.**
   If processing cannot keep up, drop stale frames rather than building an unbounded queue.

8. **Do not over-engineer prematurely.**
   Start with the simplest architecture that meets requirements, benchmark it, and introduce complexity only when measurements justify it.

9. **Preserve existing functionality.**
   Existing selection behavior must continue to work while intelligent capabilities are added.

10. **Manual selection is the fallback, not the primary intelligence.**

---

# 1. Phase 0 — Repository Reconnaissance

Before changing code, inspect the entire relevant codebase.

Identify:

- Application framework and platform.
- UI/rendering architecture.
- Selection-window implementation.
- Screen/camera/video capture implementation.
- State-management architecture.
- Rendering loop.
- Image/bitmap conversion paths.
- OCR implementation.
- ML inference implementation.
- Computer-vision utilities.
- Tracking implementation.
- Background task architecture.
- Existing tests.
- Build and deployment configuration.

Map the current data flow:

```text
Capture
  ↓
Frame/Image
  ↓
Selection UI
  ↓
Processing
  ↓
OCR/CV/ML
  ↓
Application State
  ↓
Rendering
```

Document where each stage runs and whether it executes on the main/UI thread.

## Build Gate 0 — Repository Understanding

- [x] Repository structure inspected.
- [x] Relevant source files identified.
- [x] Rendering architecture documented.
- [x] Screen/camera/video capture path documented.
- [x] OCR/ML/CV components documented.
- [x] Existing selection workflow documented.
- [x] Existing tests identified.
- [x] Build and test commands verified.
- [x] Baseline application successfully builds.
- [x] Baseline application successfully runs.
- [x] Baseline behavior captured before modification.

**Do not proceed to major implementation until the baseline build and current selection workflow are verified.**

---

# 2. Phase 1 — Profile and Diagnose Window Selection Lag

The current selection tool lags noticeably when the user moves or resizes the selection window.

Determine the actual cause before making significant changes.

## Profile

Measure:

- UI FPS while idle.
- UI FPS while moving selection.
- UI FPS while resizing.
- Input-to-render latency.
- CPU utilization.
- GPU utilization.
- Memory usage.
- Allocation rate.
- Garbage-collection pressure where applicable.
- Screen-capture latency.
- Image conversion latency.
- Rendering latency.
- OCR latency.
- CV latency.
- ML inference latency.
- State-update latency.
- Number of UI/component re-renders.
- Number of frame/image copies.

Investigate:

- Excessive UI re-rendering.
- Synchronous work on the UI thread.
- Screen capture during every pointer event.
- Full-resolution image processing.
- OCR triggered during drag events.
- CV triggered during drag events.
- GPU↔CPU transfers.
- Bitmap/image copying.
- Inefficient state management.
- Missing throttling/debouncing.
- Rendering-loop synchronization.
- Memory pressure.
- Unnecessary layout passes.
- Any other discovered bottleneck.

## Required benchmark scenarios

Create reproducible tests for:

1. Idle.
2. Slow selection movement.
3. Fast selection movement.
4. Slow resize.
5. Fast resize.
6. Rapid repeated movement.
7. Rapid repeated resizing.

## Build Gate 1 — Performance Root Cause

- [ ] Baseline performance measurements captured.
- [x] Lag reproduced consistently.  *(reproduced deterministically at the invalidation level, not as an FPS measurement)*
- [ ] Main/UI thread activity profiled.
- [ ] Rendering loop profiled.
- [ ] Capture pipeline profiled.
- [ ] OCR/CV/ML pipeline profiled.
- [ ] Memory allocations profiled.
- [x] Primary bottleneck identified.
- [x] Secondary bottlenecks identified.
- [x] Root-cause report written.
- [x] Relevant code paths documented.

**Required deliverable:** A concise root-cause analysis explaining exactly why the selection UI lags.

---

# 3. Phase 2 — Fix Interactive Selection Performance

Refactor the system so that interactive selection remains responsive regardless of background processing.

The following must not block selection interaction:

- OCR.
- ML inference.
- Object detection.
- Screen classification.
- Feature extraction.
- Image enhancement.
- Tracking.
- Expensive CV.

Consider:

- Async tasks.
- Background workers.
- Dedicated processing queues.
- Frame dropping.
- Throttling.
- Debouncing.
- Double buffering.
- GPU acceleration.
- Latest-frame queues.

Recommended conceptual architecture:

```text
                Screen/Camera Capture
                         │
                         ▼
                 Latest-Frame Buffer
                    /          \
                   /            \
                  ▼              ▼
             UI Preview     Processing Pipeline
                                  │
                                  ▼
                              Tracking
                                  │
                                  ▼
                          Screen Geometry
                                  │
                                  ▼
                                OCR
                                  │
                                  ▼
                          Structured Data
```

The UI must not wait for OCR or ML inference.

The processing pipeline should prefer the newest frame.

## Performance targets

Where hardware permits:

- Selection interaction: approximately 60 FPS or better.
- No visible stutter during movement.
- No expensive OCR/CV on the UI thread.
- No unbounded processing queue.
- No progressive latency buildup.

If the platform supports higher-refresh-rate displays, do not unnecessarily cap the UI at 60 FPS.

## Build Gate 2 — Selection Performance

- [x] UI interaction is decoupled from expensive processing.
- [x] No OCR blocks drag/resize operations.
- [x] No ML inference blocks drag/resize operations.
- [x] No expensive CV blocks drag/resize operations.
- [x] Latest-frame processing strategy implemented where appropriate.
- [x] Frame dropping implemented where needed.
- [~] Selection movement feels fluid.  *(mechanism fixed + regression-tested; subjective fluidity unverified without a device)*
- [~] Selection resizing feels fluid.  *(same as above)*
- [x] No unbounded queue growth.
- [ ] Before/after FPS measured.
- [ ] Before/after latency measured.
- [ ] Before/after CPU/memory measured.
- [x] Performance regression test added.

**Gate condition:** The original selection lag must be demonstrably improved before moving to intelligent tracking features.

---

# 4. Phase 3 — Dynamic Motion Demo and Tracking Stress Environment

The current demo screen is too static to validate tracking.

Create a configurable test environment that simulates:

## Motion types

### Translation

- Horizontal.
- Vertical.
- Diagonal.

### Rotation

- Yaw.
- Pitch.
- Roll.

### Combined 3D motion

Support:

- Translation.
- Yaw.
- Pitch.
- Roll.
- Scale changes.
- Perspective distortion.

### Bouncing DVD Logo

Implement a classic bouncing-DVD-style test:

- Continuous movement.
- Reflection from boundaries.
- Optional rotation.
- Optional perspective distortion.
- Optional scaling.

### Stress-test mode

Combine:

- Fast movement.
- Rotation.
- Perspective distortion.
- Scale changes.
- Partial occlusion.
- Motion blur.
- Variable lighting.
- Noise.
- Compression artifacts.

Make parameters configurable.

## Build Gate 3 — Motion Test Environment

- [x] Translation test implemented.
- [x] Yaw test implemented.
- [x] Pitch test implemented.
- [x] Roll test implemented.
- [x] Combined transformation test implemented.
- [x] Bouncing DVD test implemented.
- [x] Stress-test mode implemented.
- [x] Motion parameters configurable.
- [x] Tracking test scenarios reproducible.
- [x] Demo does not degrade UI responsiveness.

---

# 5. Phase 4 — Screen Candidate Detection

Detect potential screens and device displays.

Potential methods:

- ML object detection.
- OCR text detection.
- OCR recognition.
- Screen boundary detection.
- Rectangle/quadrilateral detection.
- Edge detection.
- Contour detection.
- Feature matching.
- Template matching.
- Device classification.
- Visual similarity.
- Known device templates.
- Previously detected geometry.

Potential targets:

- Multimeters.
- Oscilloscopes.
- Laboratory instruments.
- Bench power supplies.
- Digital thermometers.
- Industrial control panels.
- LCD displays.
- LED displays.
- E-ink displays.
- Digital gauges.
- Computer monitors.
- Embedded instrument displays.

Do not require readable text for candidate detection.

A candidate should combine multiple signals.

Example:

```text
ML object confidence      0.85
OCR text confidence       0.92
Rectangular geometry      0.97
Aspect ratio              0.89
Temporal stability        0.91
Tracking consistency      0.94
--------------------------------
Combined confidence       0.92
```

Use a weighted confidence model or another justified fusion strategy.

OCR should contribute to detection, but should not be the sole mechanism.

## Build Gate 4 — Candidate Detection

- [x] Candidate screen detector implemented.  *(wired and exercised live)*
- [x] At least one non-OCR detection mechanism implemented.  *(wired and exercised live)*
- [x] OCR can contribute confidence.  *(wired and exercised live)*
- [x] Candidate confidence score implemented.  *(wired and exercised live)*
- [x] Candidate geometry represented.  *(wired and exercised live)*
- [x] Candidate stability measured over time.  *(wired and exercised live)*
- [~] False-positive behavior tested.  *(synthetic scenes only; no laptop screens/posters)*
- [x] Multiple candidates supported.  *(live run showed 3 concurrent scored candidates)*

---

# 6. Phase 5 — Intelligent Magnetic Snapping

Implement a magnetic acquisition system that helps the user select a detected display.

Desired interaction:

```text
User moves selection window
          ↓
Candidate screen detected
          ↓
Candidate approaches selection
          ↓
Proximity + confidence evaluated
          ↓
Magnetic attraction begins
          ↓
Selection smoothly aligns
          ↓
Target boundaries snap into place
          ↓
Target becomes locked
          ↓
Persistent tracking begins
```

The user should not need pixel-perfect manual alignment.

## Magnetic snap zone

Calculate proximity using:

- Selection center ↔ target center.
- Selection edges ↔ target edges.
- Selection corners ↔ target corners.
- Aspect-ratio similarity.
- Geometry overlap.
- User movement trajectory where useful.

Use configurable thresholds.

Example:

```text
Far:
    No attraction

Near:
    Weak attraction

Closer:
    Moderate attraction

Very close:
    Strong attraction

Aligned + high confidence:
    Lock
```

Do not hard-code arbitrary pixel thresholds without testing. Normalize thresholds based on:

- Resolution.
- Camera resolution.
- Video resolution.
- Display density.
- Zoom level.

## Smooth attraction

Do not teleport the selection.

Use:

- Interpolation.
- Spring-damper behavior.
- Damped convergence.

Avoid:

- Jitter.
- Oscillation.
- Sudden jumps.
- Excessive latency.
- Unwanted overshoot.

The user must remain in control.

If the user intentionally drags away, magnetic attraction should release.

---

# 7. Phase 6 — Magnetic Snap State Machine

Implement explicit states:

```text
MANUAL
   │
   │ Candidate detected
   ▼
CANDIDATE_DETECTED
   │
   │ Proximity threshold reached
   ▼
MAGNETIC_ATTRACTION
   │
   │ Alignment threshold reached
   ▼
SNAP_PREVIEW
   │
   │ Confidence + geometry threshold met
   ▼
LOCKED
   │
   │ Confidence drops
   ▼
TRACKING_DEGRADED
   │
   ├───────────────┐
   │               │
 Recovery        Timeout
   │               │
   ▼               ▼
LOCKED        REACQUISITION
                   │
                   ▼
             CANDIDATE_DETECTED
```

Use hysteresis to prevent rapid state flipping.

Example illustrative thresholds:

```text
Detection:
    > 0.60

Magnetic attraction:
    > 0.70

Snap preview:
    > 0.80

Locked:
    > 0.90
```

Tune these experimentally.

## Build Gate 5 — Magnetic Acquisition

- [x] Magnetic snap zone implemented.  *(wired and exercised live)*
- [x] Proximity metric implemented.  *(wired and exercised live)*
- [x] Confidence metric integrated.  *(wired and exercised live)*
- [x] Smooth attraction implemented.  *(incremental and carried across frames — no teleport)*
- [x] Snap state machine implemented.  *(wired and exercised live)*
- [x] Hysteresis implemented.  *(wired and exercised live)*
- [x] Lock state implemented.  *(LOCKED reached in a live run)*
- [~] Tracking-degraded state implemented.  *(implemented; NOT entered during the motion failure — see blocker)*
- [~] Reacquisition state implemented.  *(implemented; not observed live)*
- [ ] False-positive snap tests added.
- [~] Multiple-target tests added.  *(unit tests only; no live multi-target scene)*
- [x] Target-switching tests added.
- [x] User override implemented.  *(RELEASE chip)*
- [x] Manual fallback preserved.  *(the manual ROI flow is untouched and remains the primary path)*

---

# 8. Phase 7 — Screen-Aware Target Locking

The system should distinguish:

```text
Physical Device
      │
      ▼
Device Bounding Box
      │
      ▼
Screen Quadrilateral
      │
      ▼
Numeric Field Regions
```

Prefer snapping to the actual screen/display region rather than the entire device when possible.

For example, if a multimeter is detected:

```text
Device:
┌─────────────────────────────┐
│                             │
│       ┌─────────────┐       │
│       │  12.345 V   │       │
│       └─────────────┘       │
│                             │
└─────────────────────────────┘
```

The magnetic target should ideally be the display:

```text
┌─────────────┐
│  12.345 V   │
└─────────────┘
```

Store:

```text
Target ID
Target Type
Screen Geometry
Four Corners
Bounding Box
Perspective Transform
Feature Descriptors
Tracking Model
Detection Confidence
Tracking Confidence
Last Position
Last Scale
Last Rotation
```

The logical selection should become a viewport into the tracked target rather than a fixed screen-space rectangle.

## Build Gate 6 — Target Lock

- [ ] Device and screen concepts separated.
- [x] Screen geometry stored independently.  *(wired and exercised live)*
- [x] Four-point geometry supported.  *(wired and exercised live)*
- [x] Perspective transform supported.  *(wired and exercised live)*
- [~] Target metadata persisted.  *(held in TrackedTarget; not persisted across launches)*
- [x] Selection becomes target-relative after lock.  *(wired and exercised live)*
- [~] Target remains usable while moving in frame.  *(holds while steady; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*

---

# 9. Phase 8 — Hierarchical Tracking

Use a hierarchical tracking strategy.

## Stage 1 — Detection

Run periodically or when confidence drops.

Potential detectors:

- ML.
- OCR.
- Screen geometry.
- Feature-based detection.

## Stage 2 — Fast Tracking

Run at high frequency.

Potential methods:

- Optical flow.
- Feature tracking.
- Template tracking.
- Correlation tracking.
- Keypoint tracking.
- Hardware-accelerated tracking.

## Stage 3 — Geometry Estimation

Estimate:

- Translation.
- Scale.
- Rotation.
- Perspective.
- Four-point screen geometry.

## Stage 4 — Reacquisition

If tracking confidence falls:

```text
Fast Tracker
    ↓
Confidence Below Threshold
    ↓
Local Reacquisition
    ├── Success → Resume
    └── Failure → Global Detection
                       ↓
                  Best Candidate
                       ↓
                 Reinitialize
```

Avoid running expensive global detection on every frame.

## Build Gate 7 — Tracking

- [x] Fast tracker implemented.  *(wired and exercised live)*
- [x] Tracking confidence implemented.  *(reported live — but insensitive to positional lag, which is the blocker)*
- [x] Geometry updated frame-by-frame.  *(wired and exercised live)*
- [~] Perspective changes handled.  *(affine synthetic only; real keystoning unverified)*
- [x] Reacquisition implemented.  *(implemented and wired; does not trigger on the motion drift)*
- [~] Tracking-loss recovery tested.  *(unit-tested; live recovery from motion drift does NOT occur)*
- [ ] Tracking survives translation.
- [ ] Tracking survives yaw.
- [ ] Tracking survives pitch.
- [ ] Tracking survives roll.
- [ ] Tracking survives scale changes.
- [ ] Tracking survives moderate perspective distortion.
- [ ] Tracking survives temporary occlusion.
- [ ] Tracking survives motion blur where feasible.
- [ ] Tracking success rate measured.
- [ ] Recovery time measured.

---

# 10. Phase 9 — Canonical Perspective Normalization

Normalize the locked screen before OCR.

```text
Original Frame
      ↓
Detect Screen Corners
      ↓
Estimate Homography
      ↓
Perspective Warp
      ↓
Canonical Screen
      ↓
Field Detection
      ↓
OCR
```

Represent field regions in normalized coordinates:

```text
x = 0.25
y = 0.40
width = 0.30
height = 0.10
```

This keeps fields stable as the physical screen moves.

## Build Gate 8 — Perspective Normalization

- [x] Four-point screen geometry supported.  *(wired and exercised live)*
- [x] Homography implemented.  *(wired and exercised live)*
- [x] Canonical screen representation implemented.  *(wired and exercised live)*
- [~] Perspective correction tested under yaw.  *(synthetic affine only)*
- [~] Perspective correction tested under pitch.  *(synthetic affine only)*
- [~] Roll correction tested.  *(synthetic affine only)*
- [x] Field coordinates are target-relative.  *(wired and exercised live)*
- [x] OCR receives normalized regions.  *(canonical-space field regions projected per frame)*

---

# 11. Phase 10 — Screen Understanding and OCR

Analyze the screen structure.

Potential content:

- Labels.
- Numeric values.
- Units.
- Decimal positions.
- Fixed-width digits.
- Signs.
- Scientific notation.
- SI prefixes.
- Multiple fields.

Example:

```text
┌─────────────────────────────┐
│ VOLTAGE      12.345 V       │
│ CURRENT       1.234 A       │
│ POWER        15.20 W        │
│ FREQUENCY   60.000 Hz       │
└─────────────────────────────┘
```

Do not treat the entire display as one OCR region.

Detect:

- Screen boundary.
- Text regions.
- Numeric regions.
- Labels.
- Units.
- Relationships between fields.

---

# 12. Phase 11 — Modular OCR Architecture

Create an OCR abstraction.

Conceptually:

```text
OCR Engine Interface
       │
       ├── Apple Vision
       ├── PaddleOCR / PP-OCR
       ├── PP-OCRv6
       ├── Unlimited OCR
       ├── Custom digit model
       └── Future engines
```

Investigate actual platform viability before committing.

Benchmark:

- Accuracy.
- Latency.
- CPU.
- GPU.
- Memory.
- Energy.
- Small ROI performance.
- Rotated ROI performance.
- Perspective-corrected ROI performance.

Where available, investigate:

- Core ML.
- Apple Neural Engine.
- Metal.
- GPU inference.
- Platform-specific acceleration.

Do not assume general-purpose OCR is best for fixed-format instrument displays.

## Build Gate 9 — OCR Abstraction

- [x] OCR interface defined.
- [x] At least one engine integrated.
- [x] Engine can be replaced without rewriting application logic.
- [x] OCR latency measured.
- [x] OCR accuracy benchmark created.
- [x] Numeric ROI performance measured.
- [~] Hardware acceleration evaluated.  *(Vision/Core ML surveyed in OCR_RESEARCH.md; no Metal/ANE benchmarking)*
- [x] Additional engine integration path documented.

---

# 13. Phase 12 — Multi-Field Numeric Detection

For each candidate field, maintain:

```text
Field ID
Label
Bounding Box / Quadrilateral
Expected Data Type
Character Set
Expected Digit Count
Decimal Position
Unit
Confidence
Tracking Status
OCR Engine
```

Example:

```json
{
  "fieldId": "voltage",
  "label": "VOLTAGE",
  "expectedFormat": "000.000",
  "allowedCharacters": "0123456789.-",
  "unit": "V"
}
```

User workflow:

1. Select or snap to screen.
2. Analyze screen.
3. Detect candidate fields.
4. Display overlays.
5. Select/deselect fields.
6. Manually adjust regions.
7. Correct labels.
8. Configure expected format.
9. Lock selected fields.
10. Begin capture.

## Build Gate 10 — Multi-Field Detection

- [x] Multiple numeric fields detected.  *(wired and exercised live)*
- [x] Fields represented independently.  *(wired and exercised live)*
- [x] Field overlays rendered.  *(FieldSelectionOverlay, live)*
- [x] User can select fields.  *(wired and exercised live)*
- [x] User can deselect fields.  *(wired and exercised live)*
- [ ] User can manually adjust field ROI.
- [ ] Labels editable.
- [ ] Units editable.
- [~] Expected format configurable.  *(per-device sheet ships; per-field editing not built)*
- [~] Selected fields persist through target motion.  *(canonical-space by construction; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*
- [x] Field-level confidence tracked.  *(wired and exercised live)*

---

# 14. Phase 13 — Format-Aware OCR

Use known format constraints.

Example:

```text
Expected:
    000.000

Allowed:
    0-9 and .

Decimal:
    Fixed after third digit
```

Implement:

- Character-set restrictions.
- Digit-only recognition.
- Decimal-position constraints.
- Fixed-length validation.
- Regex validation.
- Confidence scoring.
- Temporal consistency.
- Outlier rejection.
- Majority voting.

Example:

```text
12.345
12.345
12.345
12.34S
12.345
```

Treat `12.34S` as likely erroneous if temporal evidence supports `12.345`.

For slowly changing measurements, use temporal filtering.

For rapidly changing measurements, adapt filtering to avoid suppressing real changes.

## Build Gate 11 — Format-Aware OCR

- [x] Character constraints implemented.
- [x] Length constraints implemented.
- [x] Decimal constraints implemented.
- [x] Regex/format validation implemented.
- [x] OCR confidence exposed.
- [x] Temporal validation implemented.
- [x] Outlier rejection implemented.
- [x] Real changes are not incorrectly filtered.
- [x] OCR error cases tested.

---

# 15. Phase 14 — End-to-End Tracking and OCR Pipeline

Implement:

```text
Camera / Video / Screen Capture
            ↓
Frame Acquisition
            ↓
Target Detection
            ↓
Target Tracking
            ↓
Screen Geometry
            ↓
Perspective Normalization
            ↓
Field Mapping
            ↓
ROI Preprocessing
            ↓
OCR
            ↓
Format Validation
            ↓
Temporal Filtering
            ↓
Confidence Evaluation
            ↓
Structured Numeric Output
```

Tracking should run faster than OCR where possible.

Example:

```text
Tracking: 30–60+ FPS
OCR:       5–30 FPS
UI:       60+ FPS
Detection: 5–15 FPS adaptive
```

Do not let OCR create an ever-growing queue.

Use newest-frame processing.

Adapt processing rate:

```text
High tracking confidence:
    Reduce detector frequency.

Low tracking confidence:
    Increase detector frequency.

Static numeric value:
    Reduce OCR frequency.

Rapidly changing value:
    Increase OCR frequency.

Active UI interaction:
    Prioritize UI rendering.
```

## Build Gate 12 — End-to-End Pipeline

- [x] Capture pipeline implemented.
- [x] Detection integrated.  *(wired and exercised live)*
- [x] Tracking integrated.  *(wired and exercised live)*
- [x] Perspective correction integrated.  *(wired and exercised live)*
- [x] Field mapping integrated.  *(wired and exercised live)*
- [x] OCR integrated.
- [x] Format validation integrated.
- [x] Temporal filtering integrated.
- [x] Structured output produced.
- [x] Latest-frame strategy verified.
- [x] Processing queues remain bounded.
- [ ] End-to-end latency measured.

---

# 16. Phase 15 — Performance Instrumentation

Add developer instrumentation for:

```text
Capture FPS
Tracking FPS
OCR FPS
Detection FPS
UI FPS
Capture latency
Tracking latency
Detection latency
OCR latency
End-to-end latency
CPU usage
GPU usage
Memory usage
Dropped frames
Tracking confidence
Detection confidence
OCR confidence
```

Debug overlay:

- Target bounding box.
- Target corners.
- Tracking points.
- Current transform.
- Detected field regions.
- OCR results.
- OCR confidence.
- Tracking confidence.
- Candidate confidence.
- Magnetic snap state.
- Current FPS.

Disable or minimize instrumentation in production.

## Build Gate 13 — Instrumentation

- [x] FPS metrics implemented.
- [x] Latency metrics implemented.
- [~] Confidence metrics implemented.  *(recognition confidence is surfaced in the UI; not in PipelineMetrics)*
- [x] Dropped-frame metrics implemented.
- [x] Debug overlay implemented.  *(mounted behind the existing debug toggle)*
- [x] Metrics can be disabled.
- [~] Performance logs exportable or inspectable.  *(snapshot() is inspectable; no export)*

---

# 17. Phase 16 — Automated Testing

## Selection UI

- [ ] Move selection.
- [ ] Resize selection.
- [ ] Rapid movement.
- [ ] Rapid resizing.
- [ ] Repeated selection.

## Tracking

- [~] Static target.  *(verified in the live steady-state run; not automated)*
- [ ] Horizontal movement.
- [ ] Vertical movement.
- [ ] Diagonal movement.
- [ ] Yaw.
- [ ] Pitch.
- [ ] Roll.
- [ ] Combined transformations.
- [ ] Bouncing DVD.
- [ ] Temporary occlusion.
- [ ] Motion blur.
- [ ] Scale changes.
- [ ] Perspective changes.

## Magnetic acquisition

- [~] Slow approach.  *(synthetic approach sequences in unit tests)*
- [~] Fast approach.  *(synthetic approach sequences in unit tests)*
- [ ] Diagonal approach.
- [ ] Approach from multiple directions.
- [x] Multiple targets.
- [ ] False positives.
- [x] Target switching.
- [x] User override.
- [x] Manual fallback.
- [x] Lock hysteresis.

## OCR

- [x] Static numeric display.
- [~] Multiple fields.  *(analyzer unit tests only)*
- [x] Different decimal precision.
- [x] Negative values.
- [x] Units.
- [~] Rapidly changing values.  *(temporal filter covers it; not re-tested this round)*
- [x] Slowly changing values.
- [x] OCR noise.
- [ ] Partial occlusion.

## End-to-end

```text
Select
  ↓
Lock
  ↓
Track
  ↓
Normalize
  ↓
Detect Fields
  ↓
Select Fields
  ↓
OCR
  ↓
Validate
  ↓
Export
```

Measure:

- Tracking success rate.
- Tracking-loss frequency.
- Recovery time.
- OCR accuracy.
- OCR latency.
- End-to-end latency.
- Magnetic snap success rate.
- False snap rate.
- Target-switching rate.

## Build Gate 14 — Automated Testing

- [x] Unit tests added.
- [~] Integration tests added.  *(ScreenLockPipelineTests covers the wired path; no capture→export test)*
- [x] Motion tests added.
- [x] Magnetic snap tests added.
- [x] Tracking-loss tests added.
- [x] OCR tests added.
- [~] End-to-end tests added.  *(live Simulator walkthrough performed + screenshotted; not automated)*
- [x] Regression suite passes.
- [x] Performance regression tests pass.

---

# 18. Phase 17 — Magnetic Snapping Stress Tests

## Target approach

Test:

- Slow approach.
- Fast approach.
- Diagonal approach.
- Approach from every direction.

## Multiple targets

Example:

```text
┌─────────────┐       ┌─────────────┐
│ Device A    │       │ Device B    │
│ 12.345 V    │       │ 24.123 V    │
└─────────────┘       └─────────────┘
```

Selection should use:

- Proximity.
- Confidence.
- User trajectory.
- Existing lock state.

## False positives

Test:

- Laptop screens.
- Phones.
- Reflections.
- Windows.
- Posters.
- Text-heavy surfaces.
- Arbitrary rectangles.

## Target switching

Prevent rapid switching between valid nearby candidates.

Use:

- Hysteresis.
- Lock preference.
- Candidate stability.
- User intent.

## Tracking loss

Test:

- Temporary occlusion.
- Motion blur.
- Rapid movement.
- Target leaving frame.
- Lighting changes.

Verify graceful recovery.

## Build Gate 15 — Stress Validation

- [ ] Magnetic snap success rate measured.
- [ ] False snap rate measured.
- [ ] Multi-target behavior validated.
- [ ] Target switching controlled.
- [ ] Recovery behavior validated.
- [ ] Performance remains acceptable under stress.
- [ ] No UI lag introduced.

---

# 19. Phase 18 — Documentation

Document:

- Overall architecture.
- Data flow.
- Rendering architecture.
- Performance bottleneck and root cause.
- Performance fix.
- Magnetic snapping algorithm.
- Confidence fusion.
- State machine.
- Tracking approach.
- Reacquisition approach.
- Perspective normalization.
- OCR architecture.
- OCR engine selection.
- Multi-field detection.
- Format-aware OCR.
- Temporal filtering.
- Performance metrics.
- Test methodology.
- How to run motion tests.
- How to add OCR engines.
- How to add tracking algorithms.
- Known limitations.
- Recommended future work.

## Build Gate 16 — Documentation

- [x] Architecture documented.
- [x] Performance findings documented.
- [x] Magnetic snapping documented.
- [x] Tracking documented.
- [x] OCR documented.
- [x] Testing documented.
- [x] Extension points documented.
- [x] Known limitations documented.
- [x] Build/run instructions verified.

---

# 20. Final Acceptance Gate

The project is complete only when all critical gates pass.

## Required acceptance checklist

### Baseline and performance

- [x] Application builds successfully.
- [x] Application runs successfully.
- [x] Original selection workflow still works.  *(manual ROI path untouched; AUTO is off by default)*
- [x] Original selection lag root cause identified.
- [x] Original selection lag fixed.  *(regression-tested at the invalidation level — CapturePerformanceTests)*
- [x] UI remains responsive during background processing.  *(per-frame observable writes are change-gated; enforced by test)*

### Dynamic motion

- [x] Yaw works.
- [x] Pitch works.
- [x] Roll works.
- [x] Translation works.
- [x] Combined motion works.
- [x] Bouncing DVD test works.  *(demo rig; tracking under it is the open blocker)*
- [x] Stress test works.

### Intelligent acquisition

- [x] Candidate screens can be detected.  *(wired and exercised live)*
- [x] Screen confidence is calculated.  *(wired and exercised live)*
- [x] Magnetic snap works.  *(wired and exercised live)*
- [~] Magnetic attraction is smooth.  *(smooth in the steady live run; not measured)*
- [~] Snap does not jitter.  *(no jitter observed steady; not measured)*
- [x] Snap does not unexpectedly teleport.  *(attraction is incremental across frames)*
- [x] User can override snapping.  *(RELEASE chip)*
- [~] Multiple targets are handled.  *(multiple candidates scored live; switching not exercised)*
- [~] False positives are controlled.  *(suppression + margin implemented; untested on real scenes)*

### Tracking

- [x] Target can be locked.  *(wired and exercised live)*
- [~] Target can be tracked.  *(holds while steady; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*
- [x] Target geometry updates.  *(wired and exercised live)*
- [~] Perspective correction works.  *(synthetic affine only)*
- [~] Tracking survives normal movement.  *(holds while steady; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*
- [ ] Tracking degradation is detected.
- [ ] Reacquisition works.

### OCR and screen understanding

- [x] Screen structure can be analyzed.  *(wired and exercised live)*
- [x] Multiple numeric fields can be detected.  *(wired and exercised live)*
- [x] Fields can be individually selected.  *(wired and exercised live)*
- [x] Fields remain anchored to target coordinates.  *(canonical-space by construction)*
- [x] OCR is modular.
- [x] Format constraints work.
- [x] Temporal filtering works.
- [x] OCR confidence is available.

### Data acquisition

- [~] Values are captured continuously.  *(live through tracked geometry while steady; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*
- [x] Values are validated.
- [x] Data is structured.
- [x] Data can be exported.
- [ ] End-to-end latency is measured.

### Quality

- [x] Automated tests pass.
- [x] Performance regression tests pass.
- [x] Documentation is complete.
- [x] No major regressions identified.

---

# 21. Recommended Implementation Order

Execute the work in this exact order unless profiling demonstrates a better dependency:

```text
1. Inspect repository
       ↓
2. Verify baseline build
       ↓
3. Reproduce selection lag
       ↓
4. Profile rendering/event loop
       ↓
5. Profile capture pipeline
       ↓
6. Profile OCR/CV/ML
       ↓
7. Identify root cause
       ↓
8. Fix selection UI performance
       ↓
9. Add performance benchmarks
       ↓
10. Add dynamic motion demo
       ↓
11. Implement candidate screen detection
       ↓
12. Implement magnetic snapping
       ↓
13. Implement target lock
       ↓
14. Implement fast tracking
       ↓
15. Implement reacquisition
       ↓
16. Implement perspective normalization
       ↓
17. Implement modular OCR
       ↓
18. Implement multi-field detection
       ↓
19. Implement user field selection
       ↓
20. Implement format-aware OCR
       ↓
21. Implement temporal filtering
       ↓
22. Implement performance instrumentation
       ↓
23. Add automated tests
       ↓
24. Run stress tests
       ↓
25. Document architecture
       ↓
26. Run final acceptance gate
```

---

# 22. Required Final Engineering Report

At completion, provide a concise but technically detailed report containing:

## A. Root-cause analysis

- What caused the original lag?
- Which files/components were responsible?
- What profiling data proved the cause?

## B. Performance changes

- What was changed?
- Before/after FPS.
- Before/after latency.
- Before/after CPU.
- Before/after memory.

## C. Magnetic acquisition

- How candidates are detected.
- How confidence is calculated.
- How proximity is calculated.
- How attraction is interpolated.
- How locking occurs.
- How user override works.

## D. Tracking

- Tracker selected.
- Why it was selected.
- Tracking frequency.
- Reacquisition frequency.
- Tracking confidence methodology.

## E. Screen understanding

- How screen boundaries are detected.
- How perspective is normalized.
- How numeric fields are detected.

## F. OCR

- OCR engines evaluated.
- Selected engine.
- Accuracy.
- Latency.
- Hardware acceleration.
- Format-aware processing.

## G. Reliability

- Tracking success rate.
- Magnetic snap success rate.
- False snap rate.
- OCR accuracy.
- Recovery time.

## H. Known limitations

Clearly identify anything that remains imperfect.

## I. Recommended next steps

Prioritize future work by:

1. Impact.
2. Reliability.
3. Performance.
4. Implementation complexity.

---

# 23. Critical Architectural Recommendation

Do **not** make a single OCR or ML model responsible for the entire system.

Use a hierarchical pipeline:

```text
                    FRAME
                      │
                      ▼
             Candidate Detection
                      │
             ┌────────┴────────┐
             ▼                 ▼
        ML Detection          OCR
             │                 │
             └────────┬────────┘
                      ▼
               Confidence Fusion
                      │
                      ▼
                Magnetic Snap
                      │
                      ▼
                 Target Lock
                      │
                      ▼
               Fast Tracking
                      │
                      ▼
             Geometry Estimation
                      │
                      ▼
          Perspective Normalization
                      │
                      ▼
              Screen Understanding
                      │
                      ▼
             Multi-Field Detection
                      │
                      ▼
               User Confirmation
                      │
                      ▼
              Field-Level Tracking
                      │
                      ▼
             Format-Aware OCR
                      │
                      ▼
             Temporal Validation
                      │
                      ▼
              Structured Data
```

The reasoning is:

- **Detection** answers: "What might be a target?"
- **Confidence fusion** answers: "How likely is this a useful screen?"
- **Magnetic snapping** answers: "Is the user intentionally approaching this target?"
- **Tracking** answers: "Where did the target move?"
- **Geometry estimation** answers: "How did its shape and perspective change?"
- **Perspective normalization** answers: "How do we make the screen easy to analyze?"
- **Screen understanding** answers: "What is the structure of this display?"
- **Field detection** answers: "Where are the values?"
- **OCR** answers: "What values are displayed?"
- **Format validation** answers: "Is this a valid value?"
- **Temporal filtering** answers: "Is this result consistent with the measurement over time?"

This architecture should produce a smoother, more reliable system than attempting to run a heavyweight OCR/ML model continuously on every frame.

---

# 24. Final Product Vision

The final user experience should feel like an intelligent, camera-aware data acquisition system rather than a conventional rectangular crop tool.

Ideal interaction:

```text
1. Open camera or video.

2. Point camera at an instrument.

3. Move selection tool toward the instrument display.

4. Application recognizes a likely screen.

5. Selection tool magnetically snaps to the display.

6. Display boundaries align automatically.

7. Screen locks.

8. Camera or instrument moves.

9. Screen remains smoothly tracked.

10. Perspective is continuously corrected.

11. OCR/ML analyzes screen structure.

12. Multiple numeric fields appear as interactive overlays.

13. User selects desired values.

14. Selected fields become independently tracked ROIs.

15. OCR continuously extracts values.

16. Format constraints reject invalid OCR results.

17. Temporal filtering reduces transient OCR errors.

18. Values are stored as structured time-series data.

19. User exports the captured data.
```

The overarching objective is:

> **Build a responsive, intelligent, and extensible screen-locking data acquisition pipeline that combines manual user intent with computer vision, ML, tracking, OCR, and format-aware validation—while maintaining a consistently smooth interactive experience.**
