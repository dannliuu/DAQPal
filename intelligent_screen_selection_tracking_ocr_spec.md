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

**Tally: 164 done · 33 partial · 173 open.** The open count rose from 56 because this revision
adds four new gates (2A, 6A, 11A, 13A) and expands several existing ones. No previously-earned
`[x]` or `[~]` annotation was downgraded except where this revision's requirements directly
supersede it.

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

### Open campaign items added this revision

Four work items are added below and are tracked by new gates. They are listed here because
each one is either a first-class engineering objective or a reproduced defect, not a nicety:

| # | Item | Where | Severity |
|---|---|---|---|
| A | **Performance optimization campaign** — promoted to a standing, first-class objective with its own measurement discipline and regression gates | §2, §3, §16A, Gate 1 / 2 / 13A | Standing objective |
| B | **`DMM-1 - SEARCHING` drag jitter** — the selection box jitters while being dragged in the searching state | §3A, Gate 2A | Live interaction defect |
| C | **Pose-adaptive overlay geometry** — the yellow box must wrap the screen quadrilateral and track yaw / pitch / roll / distance instead of sitting axis-aligned in view space | §8A, Gate 6A | Correctness + trust signal |
| D | **Decimal recognition failures** — decimals are not reliably recovered; treat decimal placement as format-critical, not an OCR nicety | §11A, §14, Gate 11A | Data-integrity defect |

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
   Do not guess at the cause of lag. Every performance claim in this document must trace to a
   captured measurement; an unmeasured optimization is an untested change.

2. **Performance is a deliverable, not a side effect.**
   Latency, responsiveness, frame-drop behavior, queue bounding, and main-thread occupancy are
   *features* with their own budgets, instrumentation, gates, and regression tests — exactly
   like correctness. A change that makes the system correct but misses its latency budget has
   not met the bar. See §2 (measurement), §3 (budgets and policy), and §16A (standing
   regression discipline).

3. **Keep the UI responsive.**
   Expensive capture, CV, ML, and OCR work must not block interactive selection. Interaction
   latency takes priority over throughput: when the system cannot do both, drop work, not
   frames of user input.

4. **Separate concerns.**
   Detection, tracking, magnetic snapping, screen understanding, OCR, and UI rendering should be independently replaceable.

5. **Prefer lightweight high-frequency processing.**
   Use fast tracking between slower detection/reacquisition passes.

6. **Exploit structure.**
   Instrument displays often have fixed-format numbers. Use expected character sets, digit counts, decimal positions, units, and temporal consistency to improve OCR.

7. **The decimal point is part of the measurement, not decoration.**
   A dropped or misplaced decimal separator changes the value by a factor of ten or more while
   remaining a well-formed number, so it passes every check that only asks "is this numeric?".
   Decimal placement must be recovered, scored, validated, and regression-tested as a
   first-class field property. See §11A and §14.

8. **The overlay must tell the truth about the lock.**
   The on-screen geometry is the user's only evidence that the system has locked onto the right
   thing. It must be *screen-relative* — wrapping the detected quadrilateral and deforming with
   yaw, pitch, roll and distance — never a view-space rectangle that merely sits near the
   target. An overlay that looks locked while the tracker has drifted is a correctness defect,
   not a cosmetic one. See §8A.

9. **Use temporal information.**
   Consecutive frames should improve tracking and OCR reliability.

10. **Prefer the newest frame.**
   If processing cannot keep up, drop stale frames rather than building an unbounded queue.
   Queues must be explicitly bounded; "it has never grown in practice" is not a bound.

11. **Do not over-engineer prematurely.**
   Start with the simplest architecture that meets requirements, benchmark it, and introduce complexity only when measurements justify it.

12. **Preserve existing functionality.**
   Existing selection behavior must continue to work while intelligent capabilities are added.

13. **Manual selection is the fallback, not the primary intelligence.**

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

> **This phase is the entry point of the standing performance campaign (item A).** It is not a
> one-off diagnostic exercise that closes when the first bug is found. Every subsequent phase
> that adds work to the frame path re-enters this phase's measurement discipline: instrument
> the stage, capture a baseline, set a budget, gate the regression.

## Measurement discipline

Before any numbers are collected, fix the methodology, or the numbers will not be comparable
between runs:

- **Build configuration.** Profile a Release-configuration build for absolute figures. Debug
  builds carry assertions, un-inlined generics and instrumentation that can dominate the very
  costs being measured. Record which configuration produced every figure.
- **Device class.** Record the exact device and OS. Simulator figures measure the host machine,
  not the target, and must be labeled as such — they are useful only for *relative* before/after
  comparison of the same code path on the same host.
- **Thermal state.** Capture the thermal state alongside each run. A throttled device produces
  figures that look like a regression and are not.
- **Warm-up.** Discard the first N frames of any run; first-frame costs (shader compilation,
  lazy allocation, model load) are real but are not steady-state.
- **Percentiles, not means.** Report p50/p95/p99, not just the mean. Visible stutter is a
  tail-latency phenomenon and a mean hides it entirely. A pipeline with a 6 ms mean and a
  90 ms p99 stutters visibly once per second at 60 Hz.
- **Sample size.** State the number of frames each figure is computed from. A p99 over 40
  samples is not a p99.

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

## Where bottlenecks are actually likely — per-pipeline checklist

Profile each pipeline independently. A single end-to-end number tells you a frame was slow but
not which stage to fix.

### Selection UI and rendering loop

Likely causes, in the order they are usually found:

- **Frame-rate-driven view invalidation.** State written on every processed frame that is read
  by a *parent* view rather than a leaf causes the whole subtree to re-evaluate at capture
  rate, competing with gesture handling for the main thread. This is the highest-yield thing to
  look for and it is invisible to a sampling profiler that only shows "layout is expensive".
- **Ungated state writes.** Writing an observable property with an unchanged value still
  invalidates. Every per-frame write must compare before assigning.
- **Monotonic values in observable UI state.** A timestamp or frame counter stored alongside
  displayed state defeats change-gating entirely: the value differs every frame, so the gate
  never suppresses. Keep bookkeeping out of observable UI models.
- **Whole-image rebuilds per frame.** Reconstructing a full-resolution image view per frame
  rather than updating a layer's contents.
- **Per-tick expensive effects.** Blur, shadow, and mask passes re-rendered on every gesture
  callback.
- **Layout thrash.** Geometry reads that force a synchronous layout inside a gesture handler.

Measure: view-body evaluations per second, gesture-callback duration, and the count of
invalidations per processed frame. **Invalidations-per-frame is the primary metric for this
pipeline** — target zero for a frame that changes nothing the user can see.

### Capture pipeline

- Pixel-format conversion on delivery (e.g. biplanar→BGRA) when the consumer could accept the
  native format.
- Buffer copies that could be zero-copy or IOSurface-backed.
- Capture delivered on the main queue instead of a dedicated queue.
- Allocation per frame rather than a pool.

Measure: delivery interval and jitter, conversion cost per frame, allocations per frame,
peak resident buffers.

### Tracking pipeline

- Running the tracker on every frame at full resolution when a downscaled pyramid level would
  suffice.
- Re-seeding the tracker unnecessarily; a seed is typically far more expensive than a step.
- Sequence-handler contention when tracking is invoked from more than one task.

Measure: per-step latency, per-seed latency, steps/second, rejection rate.

### Geometry pipeline

- Solving a homography per field per frame instead of once per target per frame and reusing it.
- Repeated matrix inversion where a cached inverse would serve.
- Degenerate-input handling that throws and is caught in a hot loop.

Measure: solve/apply latency, solves per frame (**should be O(targets), not O(fields)**).

### OCR pipeline

- Running recognition on every frame when the value changes far more slowly than the frame rate.
- Recognizing the whole frame and cropping afterward, rather than passing a region of interest.
- Re-running a second engine pass unconditionally where it is only useful as a rescue.
- Upscaling small ROIs beyond the resolution the recognizer actually benefits from.

Measure: per-request latency split by engine and pass, requests/second, and the fraction of
requests whose result was ultimately discarded (pure waste).

## Required benchmark scenarios

Create reproducible tests for:

1. Idle.
2. Slow selection movement.
3. Fast selection movement.
4. Slow resize.
5. Fast resize.
6. Rapid repeated movement.
7. Rapid repeated resizing.
8. **Drag while `SEARCHING`** — the exact state in which the jitter defect of §3A reproduces.
9. **Drag while `LOCKED` and tracking a moving target** — worst case for main-thread contention,
   since gesture handling, tracking, and overlay geometry updates all compete.
10. **Sustained capture with all overlays and the debug HUD enabled** — the heaviest realistic
    rendering configuration.

Each scenario must record: interaction latency p50/p95/p99, invalidations per frame, dropped
frames, and main-thread occupancy.

## Regression detection

A performance fix that is not gated will regress. For each scenario, record a baseline and fail
the build (or the test) when a metric crosses its threshold:

- **Mechanism-level assertions are preferred to wall-clock assertions** in CI. Wall-clock
  numbers on shared runners are noisy enough to produce false failures, which trains everyone to
  ignore them. Assert on the *cause* instead: invalidations per frame, allocations per frame,
  number of homography solves, number of OCR requests. These are deterministic, and they fail
  for exactly the reason you care about.
- Keep wall-clock benchmarks as an on-demand suite for local/device runs, reported but not
  gating.
- Any metric that cannot be asserted deterministically must be recorded in the engineering
  report as measured-but-ungated, so its absence from CI is explicit.

## Build Gate 1 — Performance Root Cause

- [ ] Measurement methodology fixed and recorded (build config, device, thermal state, warm-up, percentile policy, sample size).
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
- [ ] Per-pipeline profiling completed (selection/render, capture, tracking, geometry, OCR) with each stage measured independently.
- [ ] Tail latency (p95/p99) captured, not just means.
- [ ] Invalidations-per-frame measured for the selection UI.
- [ ] Regression thresholds defined per benchmark scenario.
- [ ] Metrics that cannot be gated deterministically are explicitly recorded as measured-but-ungated.

**Required deliverable:** A concise root-cause analysis explaining exactly why the selection UI
lags, naming the responsible code paths, the measurement that proved it, and the metric that
will detect its return.

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

### Explicit budgets

State a budget per stage so "fast enough" is falsifiable. These are starting values to be tuned
against captured measurements — but a stage without *some* budget cannot regress detectably.

| Stage | Budget (p95) | Cadence | Rationale |
|---|---|---|---|
| Gesture handler (per callback) | ≤ 2 ms | per touch event | Must fit many times inside one display refresh |
| Overlay geometry update | ≤ 1 ms | per frame | Pure math; projection of ≤ 4 corners per target |
| UI frame (total main-thread work) | ≤ 8 ms @ 120 Hz, ≤ 16 ms @ 60 Hz | per refresh | Leaves headroom for the compositor |
| Capture delivery → available | ≤ 5 ms | per frame | Conversion + handoff only |
| Tracking step | ≤ 10 ms | per frame while locked | Must not become the frame-rate limiter |
| Detection pass | ≤ 60 ms | adaptive, 0.1–2 s | Expensive by design; runs rarely |
| Canonical warp | ≤ 15 ms | on analysis only | Never per frame |
| Field analysis | ≤ 200 ms | ≥ 1 s apart | Most expensive stage; explicitly gated |
| OCR per field | ≤ 30 ms | adaptive | Scales with selected field count |
| End-to-end (capture → structured value) | ≤ 150 ms p95 | — | The number the user perceives as "live" |

**Main-thread rule.** The only work permitted on the main thread is: reading UI inputs,
publishing already-computed results, and rendering. Recognition, tracking, geometry solving,
warping, and image conversion are all off-main. Any main-thread hop must be a *single* hop per
frame carrying a finished result — never a per-item hop.

### Frame-dropping policy

Dropping is the intended behavior under load, not a failure. Make it explicit and observable:

- **Newest-frame wins.** When the pipeline is busy, the frame that arrives during processing
  replaces any previously queued frame rather than being appended.
- **Depth-1 queue.** At most one frame may be pending behind the one being processed. This is
  the bound; it must be structural (a serial consumer that awaits, or an explicit
  latest-value buffer), not a convention.
- **Drops are counted and surfaced.** A silent drop is indistinguishable from a hang. The drop
  count and drop rate must appear in the instrumentation of §16.
- **Never drop user input.** Gesture events are not frames; they are never coalesced away in a
  manner that loses the final position of a drag.
- **Degrade by cadence, not by correctness.** Under sustained load, reduce detection and OCR
  frequency first. Never skip validation to save time — an unvalidated reading is worse than a
  missing one.

### Queue bounding

Every producer/consumer boundary in the system must state its bound and its overflow policy:

| Boundary | Bound | Overflow policy |
|---|---|---|
| Capture → processing | 1 frame | Drop oldest (newest wins) |
| Processing → UI publish | 1 result | Replace |
| Analysis requests | 1 pending | Coalesce |
| Config pushes | 1 in flight | Cancel superseded |

A boundary whose bound is "unbounded in principle but small in practice" fails this gate.

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
- [ ] Per-stage budgets defined and recorded.
- [ ] Every queue boundary has a declared bound and overflow policy.
- [ ] Frame drops are counted and surfaced in instrumentation.
- [ ] Main-thread rule audited: no recognition, tracking, geometry, warping or conversion on main.
- [ ] Exactly one main-thread hop per processed frame.
- [ ] Interaction latency measured under the drag-while-`SEARCHING` and drag-while-`LOCKED` scenarios.

**Gate condition:** The original selection lag must be demonstrably improved before moving to intelligent tracking features.

---

# 3A. Phase 2A — Live Interaction Defect: Drag Jitter in `SEARCHING`

## Reproduction

1. Place a device window so it is present but not locked. The window's label reads exactly:

   ```text
   DMM-1 - SEARCHING
   ```

2. Drag the window with a continuous gesture.

**Observed:** the selection box jitters. The rectangle does not follow the finger smoothly — it
oscillates, stutters, or snaps back a small distance before catching up, giving the drag a loose,
rubbery feel. The jitter is specific to the `SEARCHING` state; the same drag in other states is
reported as noticeably smoother.

**Expected:** the box tracks the finger exactly, monotonically, with no oscillation, for the
entire gesture, independent of what the recognition pipeline is doing behind it.

## Classification

This is a **live interaction defect**, not a cosmetic one. Treat it as tied to state
transitions, rendering invalidation, or competing frame updates — the same class of problem as
the original selection lag, and likely sharing machinery with it. `SEARCHING` is precisely the
state in which the pipeline is *most* active: it is repeatedly attempting and failing to
acquire, which is a plausible source of both per-frame state churn and competing writes to the
very geometry the gesture owns.

## Required investigation

Do not fix by adding smoothing to the gesture. Smoothing would mask the oscillation and add
input latency. Identify which of the following is actually occurring, and rule each in or out
with evidence:

- **Competing geometry writers.** Is anything other than the gesture writing the window's
  geometry during the drag? Candidates: ROI auto-tracking nudging the window toward an observed
  text box; magnetic attraction moving the selection toward a candidate; a tracker publishing a
  quad. Any of these fighting the finger produces exactly this oscillation. Determine whether
  the "pause while the user is dragging" guard is (a) present, (b) actually set for the whole
  gesture, and (c) observed by *every* writer — not just the one it was written for.
- **Repeated geometry writes per tick.** Is the gesture handler writing state on every
  `onChanged` callback, and does that write feed back into the value the next callback reads?
  A read-modify-write against a value that the pipeline is also mutating drifts and snaps.
- **Anchor drift.** Does each callback apply the gesture's cumulative translation to a *frozen
  anchor* captured at gesture start, or to the current (possibly already-mutated) rect? The
  latter accumulates error.
- **State churn.** Does the `SEARCHING` state itself change at frame rate — a confidence value,
  a timestamp, a retry counter — invalidating the view that renders the box?
- **Re-render loops.** Does the box's own geometry update trigger an invalidation that causes a
  layout pass that recomputes the geometry?
- **Capture-frame updates.** Are preview frames invalidating the view hierarchy that hosts the
  overlay, so the box is re-rendered from stale geometry between gesture callbacks?
- **Drag-event handling.** Are gesture events being coalesced, throttled, or delivered on a
  queue that reorders them relative to frame updates? Is the final position of the gesture
  guaranteed to be applied last?
- **Mixed coordinate spaces.** Is any part of the path converting through a different space
  (view ↔ normalized ↔ buffer) with rounding at each hop, so the round-trip is not the identity?

## Implementation notes

- The gesture must own the geometry for the duration of the drag. The cleanest structure is a
  view-local geometry value that the gesture writes and the view renders, committed to shared
  state exactly once at gesture end.
- The "user is interacting" flag must be set on the first callback of the gesture and cleared on
  the last, and must be honored by every automatic writer.
- Prefer suppressing automatic geometry updates during a drag over trying to blend them with
  user input. Blending is where oscillation comes from.

## Failure modes to watch for after the fix

- The box is smooth but *lags* the finger — over-correction; smoothing was added instead of
  removing the competing writer.
- The box is smooth during the drag but *jumps* on release — the committed value differs from
  the rendered value.
- The box is smooth in `SEARCHING` but jitters in another state — the guard was applied to one
  writer only.

## Build Gate 2A — Drag Stability

- [ ] Jitter reproduced deterministically in `DMM-1 - SEARCHING`.
- [ ] Every writer of window geometry during a drag enumerated.
- [ ] Competing-writer hypothesis ruled in or out with evidence.
- [ ] State-churn hypothesis ruled in or out with evidence.
- [ ] Re-render-loop hypothesis ruled in or out with evidence.
- [ ] Capture-frame-update hypothesis ruled in or out with evidence.
- [ ] Drag-event-handling hypothesis ruled in or out with evidence.
- [ ] Root cause identified and documented.
- [ ] Fix removes the cause rather than smoothing the symptom.
- [ ] **Automated test: the box remains stable while the user drags during `SEARCHING`.**
      Drive a synthetic drag while the pipeline is actively searching and assert the rendered
      geometry equals the expected geometry for every step — monotonic along the drag path, with
      no reversal between consecutive samples and no deviation beyond a tight tolerance.
- [ ] Automated test: no automatic writer mutates window geometry while the interaction flag is set.
- [ ] Automated test: the geometry committed at gesture end equals the last rendered geometry.
- [ ] Drag stability verified in every acquisition state (`MANUAL`, `CANDIDATE`, `ATTRACTING`, `SNAP PREVIEW`, `LOCKED`, `DEGRADED`, `REACQUIRING`), not only `SEARCHING`.
- [ ] Interaction latency during the drag measured and within the §3 gesture budget.

**Gate condition:** A drag in any state must be visually indistinguishable from a drag with the
recognition pipeline disabled entirely.

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

# 8A. Phase 7A — Pose-Adaptive Lock Overlay Geometry

## Problem

The lock overlay — the yellow box — currently reads as a static, axis-aligned rectangle that
sits near the target rather than *on* it. It does not visibly deform with the screen's pose, so
it looks detached: the user cannot tell from it whether the system has genuinely locked onto the
display or is merely hovering a rectangle in roughly the right place.

This matters beyond aesthetics. The overlay is the **only evidence the user has** that the lock
is real. A box that looks identical whether the tracker is centered on the display or has
drifted off it hides exactly the failure documented as the standing tracking blocker.

## Requirement

The overlay must be **screen-relative, not view-relative**. It is a projection of the tracked
screen quadrilateral into view space, and it must:

- **Wrap the screen quadrilateral.** Its four vertices coincide with the four detected corners
  of the display. The rendered shape is the quad itself — four straight edges between projected
  corners — not the axis-aligned bounding box of that quad.
- **Deform under yaw.** As the display rotates about its vertical axis, the left and right edges
  converge/diverge and the vertical edges change relative length. The overlay must keystone with
  it.
- **Deform under pitch.** As the display rotates about its horizontal axis, the top and bottom
  edges converge/diverge correspondingly.
- **Rotate under roll.** In-plane rotation must rotate the overlay with the display; the edges
  stay parallel to the physical bezel at all times.
- **Scale with distance.** As the target approaches or recedes, the overlay grows and shrinks
  continuously, preserving the target's apparent aspect ratio.
- **Update continuously.** Geometry is refreshed every frame the tracker produces an update, at
  tracking cadence — never at detection cadence, and never interpolated so heavily that it
  visibly trails the display.
- **Maintain corner fidelity.** Corner *identity* is preserved across frames: the vertex drawn
  at the display's top-left stays at the display's top-left through rotation, including past the
  angles at which a naive nearest-to-origin rule would relabel them. Corner markers must not
  swap places as the target rotates.

## Explicitly not acceptable

- An axis-aligned rectangle derived from the quad's bounding box.
- A rectangle that translates and scales but never shears or keystones.
- Geometry that updates only when detection re-runs, so it snaps at the detection interval
  rather than flowing at tracking rate.
- Corner handles that jump between physical corners as the target rotates through a threshold.
- An overlay that continues to render confidently in its last-known pose after the tracker has
  stopped producing updates.

## Visual lock semantics

The overlay must communicate lock quality, not merely lock existence:

- **Locked and healthy:** solid quad edges, corner vertices marked, wrapping the display.
- **Degraded:** visually distinct treatment (e.g. dashed edges or reduced emphasis) so a
  drifting lock is not presented with the same authority as a good one.
- **Reacquiring:** clearly distinguished from locked; the user must not read a searching overlay
  as a confirmed lock.

This is the direct UI counterpart to the tracking blocker: the overlay must never look more
confident than the tracker actually is.

## Implementation notes

- Project the target's four corners through the live target→frame transform each frame, then map
  frame-normalized coordinates to view space through the same aspect-fill mapping the rest of the
  overlay layer uses. Do not compose a separate mapping path — a divergence between the ROI
  overlay's mapping and this one produces an overlay that is subtly offset in one capture mode
  only.
- Render the quad as a closed path over the four projected vertices. Draw corner markers *at the
  projected vertices*, not at the corners of a bounding rectangle.
- Read the tracked geometry in the smallest possible leaf view. This overlay updates at frame
  rate; a read in a parent body reintroduces the §2 invalidation problem directly.
- Reject non-convex or degenerate projections rather than rendering a self-intersecting shape.
- Corner-label continuity should be resolved by choosing, among the cyclic rotations of the
  labeling, the one that best matches the previous frame's labeling — the same continuity rule
  the tracker uses — so the overlay and the tracker never disagree about which corner is which.

## Build Gate 6A — Overlay Geometry Fidelity

- [ ] Overlay renders the screen quadrilateral, not its bounding box.
- [ ] Vertices coincide with the four detected screen corners.
- [ ] Overlay keystones correctly under yaw.
- [ ] Overlay keystones correctly under pitch.
- [ ] Overlay rotates correctly under roll.
- [ ] Overlay scales continuously with distance and preserves apparent aspect ratio.
- [ ] Overlay updates at tracking cadence, not detection cadence.
- [ ] Corner identity is stable through a full rotation sweep (no vertex swapping).
- [ ] Degenerate/non-convex projections are rejected rather than drawn.
- [ ] Degraded and reacquiring states are visually distinct from a healthy lock.
- [ ] Overlay geometry reads are isolated to leaf views (no frame-rate invalidation of parents).
- [ ] Overlay geometry update is within the §3 budget (≤ 1 ms p95).
- [ ] Automated test: projected vertices match expected corners within tolerance across a
      yaw/pitch/roll/scale sweep driven by the §4 motion rig.
- [ ] Automated test: rendered overlay is *not* axis-aligned when the target is rotated —
      asserting the shape actually shears rather than merely translating.
- [ ] Visual verification against the motion rig, captured as screenshots for each pose family.

**Gate condition:** With the target under combined motion, the overlay must remain visually
attached to the display — a user watching only the overlay should be able to tell the display's
orientation from it.

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

# 11A. Phase 10A — Decimal Recognition Investigation

## Problem

**The application does not reliably recognize decimals.** Values that should read `12.345` are
recovered without the separator, with it in the wrong position, or are rejected outright.

## Why this is format-critical, not an OCR detail

A lost decimal separator does not produce an obviously broken result — it produces a
*well-formed number that is wrong by a factor of ten or more*. `12.345` read as `12345` is:

- numeric,
- the correct digits in the correct order,
- accepted by any check that only asks whether the text parses,
- and off by 1000×.

Every downstream guard is weak against this failure. Range validation only catches it if the
range happens to exclude the shifted value. Temporal filtering *actively works against
detection*: if the separator is lost consistently, the shifted series is perfectly
self-consistent and looks stable. Confidence scoring is blind to it because the recognizer is
confident about the digits it did read.

This makes decimal placement a **data-integrity** concern of the same rank as reading the wrong
display. It must be recovered, scored, validated, and regression-tested explicitly.

## Required investigation

Determine which stage loses the separator. Instrument the value at each hop and compare —
do not infer from the final output.

- **Character-set constraints.** Is `.` present in every allowed-character set, allowlist, or
  recognizer vocabulary along the path? Check the recognition request configuration, any custom
  vocabulary, and every post-filter that strips characters. A filter that keeps `[0-9-]` deletes
  the separator silently.
- **Preprocessing.** Does any preprocessing step erase a small, low-contrast dot? Suspect:
  binarization/thresholding, denoising, morphological opening, downscaling, sharpening, and
  contrast normalization. The separator is by far the smallest glyph on the display and is the
  first thing to disappear.
- **Thresholding specifically.** On segment and dot-matrix displays the decimal point is often
  dimmer than the digit segments. A global threshold tuned for digit strokes can drop it. Test
  with a per-region adaptive threshold.
- **ROI cropping.** Is the separator being cropped out? A decimal point sits at the glyph
  baseline; a region computed from digit bounding boxes and then tightened can clip it. Check
  padding on the bottom edge specifically.
- **Resolution.** Is the ROI upscaled enough for the separator to survive resampling? A dot a
  couple of pixels across does not survive aggressive downscaling.
- **Normalization.** Does perspective normalization preserve the separator? Verify on the
  canonical image directly, not on the original frame.
- **Field-format inference.** Does inferred format assert a decimal position that contradicts
  what was read, causing a valid reading to be reformatted or rejected? Does inference default
  to integer when the separator is missing from the *first* observation, locking in the wrong
  grammar for the session?
- **OCR engine behavior.** Does the engine report the separator at all? Compare engines and
  recognition levels on the same crop. Some recognizers merge `.` into an adjacent digit's
  bounding box or drop it as noise.
- **Locale and separator convention.** Is `,` used as the decimal separator on the display or by
  the parser? A comma-decimal display parsed with a period-decimal parser loses the value.
  Thousands separators must be distinguished from decimal separators.
- **Post-processing validation.** Does the parser accept a leading `.` (as in `.001`)? A trailing
  separator? Multiple separators? Does it reject the whole reading when it should recover the
  numeric portion?
- **Temporal filtering.** Is a correctly-read decimal value being rejected as an outlier because
  the *majority* of readings lost their separator, making the correct value look anomalous?
  This inverts the filter's purpose and must be checked explicitly.

## Decimal-aware format support

Extend field formats so decimal placement is expressed, enforced, and scored:

- **Fixed decimal position.** A field may declare the separator's position (digits before the
  point). When declared, recognition prefers hypotheses matching it, and a reading whose
  separator is elsewhere is rejected as a format violation rather than silently accepted.
- **Implied decimal position.** For displays where the separator is not reliably visible, allow a
  format to declare the position *implicitly* — the value is reconstructed by inserting the
  separator at the known position. This is the standard fallback for fixed-format instruments
  and must be an explicit, user-visible choice, never an inference applied silently.
- **Decimal confidence scoring.** Score the separator independently of the digits. Report:
  separator detected (yes/no), its position, and the confidence of that determination. A reading
  with high digit confidence and low separator confidence must **not** inherit the digits'
  confidence — fuse them so that an uncertain separator depresses the overall score.
- **Ambiguity is a rejection, not a guess.** If the separator's presence or position cannot be
  determined and the format does not declare one, reject with a distinct reason
  (`AMBIGUOUS_DECIMAL`) rather than emitting the digits as an integer.
- **Sign and separator interaction.** `-1.25` must survive: the sign must not consume the cell
  the separator occupies, nor vice versa.

## Required test vectors

Every one of these must survive the **full path** — detection → normalization → OCR →
validation → structured output — with the separator in the correct position:

```text
12.345      typical 5-digit reading with 3 decimals
0.001       leading zero, small magnitude, separator near the left edge
99.9        single decimal place
-1.25       negative with decimals (sign + separator together)
.5          leading separator with no integer digit
100.0       trailing zero after the separator must not be dropped
0.0         zero with a decimal place
-0.001      negative, small magnitude
1234.5      four integer digits, one decimal
12.3456     more decimals than a typical format declares
1.000       trailing zeros are significant for display fidelity
```

Negative cases that must be rejected rather than coerced:

```text
12..345     double separator
12.34.5     multiple separators
12.         trailing separator with no fraction digits
.           separator alone
```

## Failure modes to watch for after the fix

- Separator recovered but *position* wrong — worse than losing it, because it looks correct.
- Separator recovered on the canonical image but lost when reading from the original frame.
- Decimal confidence implemented but not fused, so it is reported and ignored.
- Implied decimal position applied silently, making every reading look right while being
  unverified.
- Trailing zeros normalized away (`1.000` → `1`), losing display fidelity in the export.

## Build Gate 11A — Decimal Integrity

- [ ] Value instrumented at every pipeline hop to localize where the separator is lost.
- [ ] Character-set/allowlist path audited for `.` (and `,` where applicable).
- [ ] Preprocessing/thresholding audited for separator erasure.
- [ ] ROI padding verified not to clip the separator at the baseline.
- [ ] Perspective-normalized image verified to preserve the separator.
- [ ] Format inference audited for integer-locking on a first observation.
- [ ] OCR engine behavior on the separator compared across engines/levels.
- [ ] Locale/thousands-separator handling verified.
- [ ] Temporal filter verified not to reject correct decimals as outliers.
- [ ] Fixed decimal position supported and enforced.
- [ ] Implied decimal position supported as an explicit, user-visible option.
- [ ] Decimal confidence scored separately from digit confidence.
- [ ] Decimal confidence fused into the overall reading confidence.
- [ ] `AMBIGUOUS_DECIMAL` rejection reason implemented and surfaced.
- [ ] All positive test vectors pass end to end with correct separator position.
- [ ] All negative test vectors are rejected, not coerced.
- [ ] **Regression test: decimals are preserved end to end through detection, normalization, OCR,
      validation, and structured output** — asserting the exported value, not just the recognized
      string.
- [ ] Exported CSV/structured output verified to carry the correct decimal value and precision.

**Gate condition:** No value may reach structured output with an unverified decimal position. A
reading whose separator could not be determined must be rejected, not shifted.

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

### Decimal handling is a first-class constraint

Decimal placement is not one of the character constraints above — it is a separate axis with its
own detection, scoring, and failure mode. See §11A for the full investigation and gate. The
requirements that belong to *this* phase:

- The allowed character set must include the decimal separator, and that inclusion must be
  asserted by test rather than assumed.
- A declared decimal position constrains recognition: hypotheses matching the declared position
  are preferred, and a separator elsewhere is a format violation.
- Majority voting must vote on the **fully-formed value including separator position**, never on
  the digit string alone. Voting on digits alone launders a systematically-lost separator into a
  confident consensus.
- Temporal consistency must be evaluated on the parsed *value*. A series that silently shifts by
  a decade when the separator drops must register as a discontinuity, not as a new stable level.
- Outlier rejection must not discard the correctly-read minority when the majority lost the
  separator. Where the two populations differ by almost exactly a power of ten, treat that as a
  decimal-detection defect signal rather than as noise.

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
- [ ] Decimal separator present in every allowed character set (asserted by test).
- [ ] Declared decimal position constrains recognition hypotheses.
- [ ] Majority voting operates on the parsed value including separator position, not the digit string.
- [ ] Temporal consistency evaluated on the parsed value; decade shifts register as discontinuities.
- [ ] Outlier rejection does not discard correctly-read decimals when the majority lost the separator.
- [ ] Power-of-ten disagreement between reading populations is surfaced as a decimal-detection defect signal.

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
- [ ] Per-stage p95/p99 exposed, not only means.
- [ ] Invalidations-per-frame exposed for the selection UI.
- [ ] Main-thread occupancy exposed.
- [ ] Queue depth and overflow counts exposed per boundary.
- [ ] Overlay geometry update cost exposed.
- [ ] Decimal-confidence exposed per field.
- [ ] Instrumentation overhead itself measured and shown to be negligible when enabled.

---

# 16A. Phase 15A — Standing Performance Regression Discipline

Performance work does not end when Gate 2 passes. Every phase after it adds work to the frame
path, and each addition is an opportunity to regress the responsiveness that Gate 2 bought.

## Rules

1. **Every new frame-path stage declares a budget** before it is merged (§3 table). A stage with
   no budget cannot be said to have regressed.
2. **Every new observable write on the frame path is change-gated** and covered by a test that
   asserts zero invalidations for an unchanged frame.
3. **Every new queue boundary declares its bound and overflow policy.**
4. **Prefer mechanism-level regression tests** — invalidations per frame, allocations per frame,
   solves per frame, OCR requests per second. They are deterministic and fail for the right
   reason. Wall-clock benchmarks remain available on demand but do not gate CI.
5. **Re-run the §2 benchmark scenarios** after any change to the capture, tracking, geometry,
   overlay, or OCR path — including the drag-while-`SEARCHING` and drag-while-`LOCKED`
   scenarios.
6. **No performance figure is claimed without a captured measurement.** Where a figure is
   unmeasured, say so explicitly rather than omitting the caveat.

## Build Gate 13A — Performance Regression Discipline

- [ ] Budget table maintained and current for every frame-path stage.
- [ ] Mechanism-level regression tests exist for invalidations, allocations, and per-frame work counts.
- [ ] Benchmark scenarios re-runnable by a single documented command.
- [ ] CI gates on the deterministic metrics.
- [ ] Wall-clock benchmark suite documented as on-demand.
- [ ] Regression thresholds reviewed whenever a budget changes.
- [ ] Unmeasured figures explicitly labeled as such in the engineering report.

---

# 17. Phase 16 — Automated Testing

## Selection UI

- [ ] Move selection.
- [ ] Resize selection.
- [ ] Rapid movement.
- [ ] Rapid resizing.
- [ ] Repeated selection.
- [ ] **Drag stability in `DMM-1 - SEARCHING`** (see §3A) — no jitter, no reversal between
      consecutive samples, geometry monotonic along the drag path.
- [ ] Drag stability in every other acquisition state.
- [ ] No automatic writer mutates geometry while the interaction flag is set.
- [ ] Geometry committed at gesture end equals last rendered geometry.

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

### Overlay geometry (see §8A)

- [ ] Overlay vertices match detected screen corners across a yaw sweep.
- [ ] Overlay vertices match across a pitch sweep.
- [ ] Overlay vertices match across a roll sweep.
- [ ] Overlay scales correctly with distance.
- [ ] Overlay is demonstrably non-axis-aligned when the target is rotated.
- [ ] Corner identity stable through a full rotation (no vertex swapping).
- [ ] Degenerate/non-convex projections rejected rather than drawn.

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

### Decimal-specific (see §11A)

- [ ] `12.345` — separator preserved end to end.
- [ ] `0.001` — leading zero and small magnitude.
- [ ] `99.9` — single decimal place.
- [ ] `-1.25` — sign and separator together.
- [ ] `.5` — leading separator.
- [ ] `100.0` — trailing zero not dropped.
- [ ] `1.000` — trailing zeros preserved in export.
- [ ] `12..345`, `12.34.5`, `12.`, `.` — rejected, not coerced.
- [ ] Separator survives perspective normalization.
- [ ] Separator survives thresholding/preprocessing.
- [ ] Decimal confidence reported and fused.
- [ ] `AMBIGUOUS_DECIMAL` raised when position is indeterminate.
- [ ] Decade-shift regression: a systematically lost separator is detected, not smoothed.

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
- [ ] Per-stage performance budgets defined and met.
- [ ] Drag is stable in `DMM-1 - SEARCHING` and in every other acquisition state.
- [ ] Queue bounds and overflow policies declared for every boundary.
- [ ] Frame drops counted and surfaced.
- [ ] Performance regression discipline in place (Gate 13A).

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
- [ ] Lock overlay wraps the screen quadrilateral.
- [ ] Lock overlay adapts to yaw, pitch, roll and distance.
- [ ] Lock overlay corner identity is stable through rotation.
- [ ] Lock overlay never looks more confident than the tracker is.

### OCR and screen understanding

- [x] Screen structure can be analyzed.  *(wired and exercised live)*
- [x] Multiple numeric fields can be detected.  *(wired and exercised live)*
- [x] Fields can be individually selected.  *(wired and exercised live)*
- [x] Fields remain anchored to target coordinates.  *(canonical-space by construction)*
- [x] OCR is modular.
- [x] Format constraints work.
- [x] Temporal filtering works.
- [x] OCR confidence is available.
- [ ] Decimals are recognized reliably.
- [ ] Decimal position is validated, not assumed.
- [ ] Decimal confidence is scored and fused.
- [ ] Indeterminate decimals are rejected rather than shifted.

### Data acquisition

- [~] Values are captured continuously.  *(live through tracked geometry while steady; BLOCKED: tracker drifts off-target under fast motion while still reporting healthy — ARCHITECTURE.md §9)*
- [x] Values are validated.
- [x] Data is structured.
- [x] Data can be exported.
- [ ] End-to-end latency is measured.
- [ ] Exported values carry correct decimal position and precision.

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
9a. Fix DMM-1 - SEARCHING drag jitter (§3A)
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
16a. Make the lock overlay pose-adaptive (§8A)
       ↓
17. Implement modular OCR
       ↓
18. Implement multi-field detection
       ↓
19. Implement user field selection
       ↓
20. Implement format-aware OCR
       ↓
20a. Investigate and fix decimal recognition (§11A)
       ↓
21. Implement temporal filtering
       ↓
22. Implement performance instrumentation
       ↓
22a. Establish standing performance regression discipline (§16A)
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
- Before/after latency (p50/p95/p99, not means).
- Before/after CPU.
- Before/after memory.
- Per-stage budgets and whether each is met.
- Frame-drop rate and queue-depth behavior under load.
- Main-thread occupancy before/after.
- Which metrics are gated in CI and which are measured-but-ungated.
- Measurement methodology: build configuration, device, thermal state, sample size.

## B2. Live interaction defects

- `DMM-1 - SEARCHING` drag jitter: root cause, which hypothesis it turned out to be, the fix,
  and the test that detects its return.
- Drag stability across all acquisition states.

## B3. Overlay geometry

- How the overlay projects the screen quadrilateral.
- How it behaves under yaw, pitch, roll and distance.
- How corner identity is kept stable through rotation.
- How lock quality is conveyed visually.

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

## F2. Decimal integrity

- Where the separator was being lost.
- Which stage(s) were responsible.
- How decimal position is now recovered and validated.
- How decimal confidence is scored and fused.
- Results for every test vector in §11A, positive and negative.
- Confirmation that exported values carry the correct decimal position and precision.

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

---

# 25. In-window sub-field selection — DELIVERED (2026-08-02)

Closes the gap between §11–§13 (field curation on a locked display) and what a
hand-held instrument actually allows.

## The gap this closes

§11–§13 already specify field proposal and user curation, and they are built:
`ScreenFieldAnalyzer` proposes, `FieldSelectionOverlay` curates, each selection
becomes a device and therefore a CSV column. That path is gated on a VERIFIED
LOCK, because field regions live in canonical display space and are drawn
through the target's homography.

The target instrument — a hand-held IR thermometer with a large live reading and
a smaller MAX reading on one LCD — routinely never reaches that lock. Its
display is small, tilted and moving. The user frames it manually, and the manual
window had no equivalent of §13: it read the whole window as one region, merging
`90.0` and `92.7`.

## What was added

A second producer for the same consumer. Nothing downstream of `Device` changed.

| piece | role |
|---|---|
| `NumberBandSplitter` | ink-projection localization inside the crop; no Vision, no connected components |
| `WindowFieldAnalyzer` | ranks candidates, filters chrome and edge artefacts, runs on demand |
| `SubFieldOrigin` | parent-relative geometry, recomposed whenever the window moves |
| `WindowSubFieldLayer` | inert outlines plus tappable chips inside the window |
| `AppState.toggleSubField` | selection ⇒ device ⇒ CSV column |

## Requirements met

- [x] Two numbers in one window are detected without recognising either
- [x] The user is offered a box per candidate and picks which to record
- [x] Each selection becomes its own device, series and CSV column
- [x] Sub-boxes ride along when the window is dragged or resized
- [x] Selections survive re-analysis without being rebound to a different number
- [x] The parent window stops contributing its own merged reading
- [x] Verified against a photograph of the real instrument, not a synthetic render

## Requirements NOT met — stated plainly

- [ ] **Telling a legend from a number.** On the real display the splitter offers
      three boxes: the primary reading, the `MAX` legend, and the MAX reading.
      Nothing in this path distinguishes text from digits, and recognition —
      the obvious discriminator — is exactly what cannot be trusted here
      (Vision measures 14.6% on seven-segment, so it would reject the `92.7`
      and accept the `MAX`). The design is recall-first: the user sees their own
      display and taps the box around the number. Closing this properly needs
      the per-instrument calibration in IMPLEMENTATION_NOTES.
- [ ] Renaming a sub-field, or giving it a display format independent of its
      parent.
- [ ] Sub-fields on a LOCKED target — that remains §11–§13's job.

## Cost

6.5 ms per analysis in Release (673×760 crop), once per window placement, run
inside the frame drain. See IMPLEMENTATION_NOTES for why the first measurement
read 934 ms and why that number was misleading.
