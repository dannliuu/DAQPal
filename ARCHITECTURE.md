# DAQPal — Architecture, Performance, and the Intelligent Screen-Locking Pipeline

Companion to `IMPLEMENTATION_NOTES.md` (chronological build log) and `OCR_RESEARCH.md`
(recognition-engine research). This document is the **structural** reference required by
`intelligent_screen_selection_tracking_ocr_spec.md` Phase 18 / Build Gate 16.

Scope note on honesty: every number in this document is either measured and labeled as such,
or explicitly marked as unmeasured/heuristic. Nothing here is an accuracy or latency claim
derived from anything other than a real run.

---

## 1. Baseline data flow (Phase 0 / Build Gate 0)

```
AVCaptureSession ──> LiveCameraFrameSource ─┐
SyntheticFrameSource (Simulator) ───────────┼──> AsyncStream<TimestampedFrame>
AVAssetReader (VideoImport) ────────────────┘              │
                                                           ▼
                                                   FrameProcessor
                                          (serial drain = backpressure)
                                                           │
                                                           ▼
                                            actor MeasurementProcessor
                              crop/ROI → OCR → FormatValidator → PhysicalValidator
                                    → TemporalFilter → ConfidenceEngine
                                                           │
                                                    FrameResult
                                                           │
                                                  await MainActor.run
                                                           ▼
                                        @MainActor @Observable AppState
                                                           │
                                                           ▼
                                                SwiftUI capture screen
```

Where each stage runs:

| Stage | Isolation | Notes |
|---|---|---|
| Frame production | AVFoundation capture queue / detached Task | `alwaysDiscardsLateVideoFrames = true` |
| Recognition + validation | `actor MeasurementProcessor` | per-device recognition fans out concurrently inside one frame |
| State publication | MainActor (`AppState.apply`) | the only main-thread work in the pipeline |
| Rendering | MainActor | SwiftUI |

Backpressure is structural rather than configured: `FrameProcessor` `await`s each
`process(frame:)` before pulling the next frame, so while the pipeline is busy no frame is
consumed, and the source's own drop-late policy discards the backlog. There is no queue to
grow — which is why "unbounded processing queue" was never a live risk in this codebase.

---

## 2. Root-cause analysis of the selection lag (Phase 1 / Build Gate 1)

**Symptom.** Moving or resizing an ROI selection window felt laggy and imprecise.

**What it was not.** The obvious suspect — committing ROI changes to app state on every
gesture tick — had already been fixed in an earlier round: `ROISelectionOverlay` drives a
view-local `@State` rect during a gesture and calls `appState.updateDevice` exactly once, in
`.onEnded`. OCR was never invoked from the gesture path either. So the gesture code itself was
already clean, and the remaining lag had a different source.

**Actual root cause: frame-rate invalidation of the entire capture screen.**

`CameraCaptureScreen.body` transitively read three properties that `AppState.apply()` wrote on
*every processed frame*:

1. `appState.liveReadings` — read by the "drag a window onto a display" alignment hint.
2. `appState.debugText` — read by the debug caption, and written every frame even when the
   OCR overlay was switched off.
3. `captureStack.simulatedPreviewImage` — an `@Observable UIImage?` reassigned per frame in
   the Simulator, which additionally forced a fresh `Image(uiImage:)` of a 1080×1920 bitmap
   into the view tree.

Under the Observation framework, a write to any observed property invalidates every view whose
body read it. Because those reads happened in the *root* screen body rather than in leaves,
each processed frame invalidated the whole capture hierarchy — header, viewport, ROI overlay,
readings panel, and footer — at 12–30 Hz. Gesture handling and that re-render contend for the
same main thread, so drag updates landed late and unevenly.

Two smaller contributors on the same path:

4. `processedFPS` was republished every frame from a rolling estimate that jitters continuously
   (11.98, 12.02, 11.99 …), invalidating the footer while displaying an identical rounded
   string.
5. `LiveReading` values were re-assigned into the `liveReadings` dictionary every frame even
   when byte-identical, so a perfectly steady reading still invalidated the panel.

**Method and its limits.** The mechanism was identified by reading the observation graph —
tracing which properties each view body reads against which properties the frame path writes —
and confirmed with a deterministic instrumentation test rather than a sampling profiler. The
project has no Instruments trace and therefore makes **no before/after FPS claim**; see §3 for
what is actually measured. A device-side Instruments run remains outstanding and is listed in
§9 Known limitations.

---

## 3. The performance fix (Phase 2 / Build Gate 2)

| Change | File | Effect |
|---|---|---|
| Preview frames bypass SwiftUI entirely | `CaptureStack.swift`, `CameraCaptureScreen.swift` | `PreviewFrameRelay` hands each `CGImage` to a `CALayer.contents` inside a `UIViewRepresentable`. No observable property changes per frame; a one-shot `hasPreviewFrame` Bool only flips the placeholder→preview switch once. |
| Per-frame reads pushed into leaf views | `CameraCaptureScreen.swift` | `DebugCaptionView` and `AlignmentHintView` own the `debugText` / `liveReadings` reads, so invalidation is scoped to two small views instead of the root body. |
| Every observable write change-gated | `AppState.swift` | `LiveReading` written only when `!=` the previous value; `debugText` written only while the overlay is visible *and* the text changed; `processedFPS` published only when its **rounded, displayed** integer changes (raw value kept in an `@ObservationIgnored` var). |
| Dead per-frame field removed from observable UI state | `Device.swift`, `AppState.swift` | `LiveReading.lastTimestamp` was written every frame and read by nothing. Because it advanced monotonically, every reading compared as "changed" and the equality gate above **silently did nothing** — the readings panel was still invalidating at full frame rate. Caught by `testApply_manyIdenticalFrames_produceNoInvalidations`, not by inspection. Timestamp bookkeeping belongs in the non-observable `AppState.lastAcceptedAt`. |
| Gesture-time render cost reduced | `ROISelectionOverlay.swift` | The locked-glow `.shadow` (a blur pass re-rendered on every `onChanged` tick) is suppressed while a gesture is active. |

**Measured result.** `DAQPalTests/CapturePerformanceTests.swift` uses
`withObservationTracking` to register exactly the reads a capture-screen body performs, then
applies frames and asserts whether SwiftUI would have been told to re-render:

- A frame carrying an unchanged reading produces **zero** UI invalidations.
- 60 consecutive unchanged frames produce **zero** invalidations (previously: one per frame).
- A changed value, or a changed confidence, **does** invalidate — the gating is not so
  aggressive that the UI goes stale.
- Debug text is not published at all while the overlay is hidden.
- A steady capture cadence never republishes `processedFPS`.

This is a mechanism-level measurement, not a frame-rate measurement. It is deterministic, runs
in CI, and fails if anyone reintroduces an ungated per-frame write — which is precisely the
regression that caused the original symptom.

**Why the test matters more than the fix.** The change-gating above was written first and
*looked* correct, but did nothing: `LiveReading` carried a `lastTimestamp` field that advanced
every frame, so `reading != previous` was always true. The gate compiled, read plausibly, and
suppressed zero invalidations. Only the observation-level test caught it. Any future change to
`LiveReading` must keep it free of monotonically-changing fields, or the gate silently reverts
to a no-op — which is why that constraint is now documented on the struct itself.

---

## 4. Motion and stress test environment (Phase 3 / Build Gate 3)

`DAQPal/Camera/DemoMotion.swift` + `SyntheticFrameSource.swift`.

Motion is a **deterministic function of elapsed time** plus integrated translation state — no
randomness, no wall clock — so any scenario replays exactly in tests.

| Mode | Motion |
|---|---|
| `steady` | static panel (identity pose) |
| `yaw` / `pitch` | ±55° tilt as horizontal / vertical foreshortening |
| `roll` | ±10° in-plane rotation (within Vision's practical text-rotation tolerance) |
| `tumble` | yaw + pitch + roll at incommensurate frequencies |
| `bounce` | bouncing-DVD constant velocity with elastic wall reflection |
| `scale` | apparent-size oscillation (~0.5×–1.4×) |
| `driftDiagonal` | slow sustained diagonal translation |
| `stress` | fast translation + yaw + pitch + roll + scale, plus optics degradation |

Separately, `RenderDegradation` layers **optics** effects the pose model deliberately does not
simulate: deterministic per-pixel noise (integer hash of x/y/frame index, never a random
source), motion blur (layered offset draws), occlusion (opaque bar over part of the panel), and
brightness scaling. All default to off, so every pre-existing call site renders exactly the
frames it did before.

Selection: tap the SYNTHETIC chip in the Simulator to cycle modes, or launch with
`-daqpal-demo-motion <mode>`.

**Honest framing.** This rig simulates geometry and a crude approximation of optics. It is
affine, not projective — CoreGraphics has no perspective transform, so yaw/pitch are rendered
as foreshortening rather than true keystoning. Passing these scenarios is **necessary but not
sufficient** evidence of real handheld robustness.

`SyntheticDisplayRenderer.panelROI(for:)` returns the ground-truth panel bounds for any pose,
which is what tracking tests compare against.

---

## 5. Geometry model for intelligent locking (Phases 7 & 9)

The existing app models a selection as `NormalizedROI` — an axis-aligned rect. That is
sufficient for a manually framed display held roughly square to the camera, and it remains the
app-wide type. It is **not** sufficient once a display is tracked through yaw/pitch, where its
outline in frame is a general convex quadrilateral.

`DAQPal/Tracking/ScreenQuad.swift` adds, strictly additively:

- **`ScreenQuad`** — four corners in normalized top-left space. Corner names are *semantic*
  (which corner of the physical screen), not positional, which is what keeps canonical-space
  field coordinates stable through rotation. `ScreenQuad(roi:)` losslessly promotes any
  existing manual selection, and `.boundingBox` converts back for every existing consumer
  (crop, Vision `regionOfInterest`, the ROI overlay).
- **`Homography`** — a 3×3 projective transform solved by direct linear transform from exactly
  four point correspondences, via Gaussian elimination with partial pivoting. Returns `nil`
  rather than garbage for singular systems, so a degenerate quad degrades to "no geometry this
  frame" instead of producing nonsense coordinates.

**Canonical space** is the unit square: the perspective-corrected view of the display.
Field regions are stored *only* in canonical space and projected into the frame on demand via
the live target homography. That single decision is what makes fields stay glued to the same
physical part of a display through translation, rotation, scale and perspective change —
without any per-field tracking.

---

## 6. Acquisition, tracking, and field contracts (Phases 4–6, 8, 10, 12)

`DAQPal/Tracking/TargetLock.swift` and `ScreenField.swift` define the frozen contracts:

- **`ScreenSignals` / `ScreenSignalWeights`** — detection evidence is kept as *named
  components*, not a pre-blended number, so the debug overlay can show why something scored
  well and weights are tunable without touching detectors. Geometry + aspect + temporal
  stability carry 0.65 of the total weight, which is how the spec's requirement that "OCR
  contributes but is not the sole mechanism" is structurally enforced: a text-free but strongly
  rectangular, stable display still clears the 0.60 detection threshold.
- **`SnapState`** — the explicit acquisition state machine
  (`manual → candidateDetected → magneticAttraction → snapPreview → locked`, with
  `trackingDegraded` / `reacquisition` recovery paths).
- **`SnapTuning`** — every threshold in one tunable struct. Proximity thresholds are in
  **normalized frame units**, so they are resolution- and display-density-independent by
  construction rather than by convention. Forward gates (`enter*`) are strictly above release
  gates (`exit*`); that gap is the hysteresis that prevents state flapping.
- **`TrackedTarget`** — live quad plus the reference quad captured at lock time, from which
  relative scale and roll are derived, and which supplies `canonicalToFrame` /
  `frameToCanonical`.
- **`ScreenField` / `ScreenFieldCatalog`** — a display is a *set* of independently recognized
  fields, never one OCR region. `merge` preserves user intent across re-analysis: user-adjusted
  regions are kept verbatim, and selection/label/format carry over to re-detected fields by
  region overlap, so re-analyzing can never silently discard configured work.

Two protocol seams keep the layers independently replaceable, matching the existing `OCREngine`
pattern: **`ScreenDetecting`** (proposal) and **`ScreenTracking`** (frame-to-frame geometry).
They are deliberately separate because they run at deliberately different cadences — detection
is expensive and rare, tracking is cheap and frequent.

---

## 7. Instrumentation (Phase 15)

`DAQPal/Instrumentation/PipelineMetrics.swift`.

Two properties this type exists to guarantee:

1. **Measuring must not perturb what it measures.** Recording a sample is a lock-protected
   append to a fixed-capacity ring buffer — no per-frame allocation, no main-actor hop, and no
   observation invalidation. The UI **pulls** a snapshot when it draws; metrics never push at
   frame rate. Pushing would recreate the exact defect described in §2.
2. **Percentiles, not just means.** `StageStats` reports p95 alongside the mean, because p95 is
   what correlates with visible stutter and a mean hides it.

Enabled in DEBUG, compiled to an early return in release.

---

## 8. Concurrency rules

- `CVPixelBuffer` is not `Sendable`. `TimestampedFrame` is `@unchecked Sendable` under a
  documented **linear ownership** rule: the producer hands a frame to exactly one consumer and
  never retains it; downstream code only ever *reads* it.
- `VNSequenceRequestHandler` is **not** safe for concurrent use and must be confined to a single
  actor. This is why `VisionScreenTracker` is an actor rather than a struct.
- `AppState` is `@MainActor`; the pipeline hops to main exactly once per frame.
- Per-device recognition fans out concurrently *within* one frame, but only across pure static
  functions that touch no actor state.

---

## 9. Integration status (Gate 14) — WIRED, and exercised live

`ScreenLockPipeline` is the keystone: it runs inline in `FrameProcessor`'s serial drain, before
recognition, so the geometry it produces is applied to the very frame it was measured from.

```
frame ──> AppState.screenLockInputs()          (MainActor, once per frame)
      ──> ScreenLockPipeline.process(...)
              stage 1  tracking      every frame while locked
              stage 2  detection     time-gated, adaptive (0.2s / 2.0s / 0.1s)
              stage 3  snap state machine
              stage 4  lock commit   -> start tracker, request analysis
              stage 5  field analysis  gated >= 1.0s, never per-frame
              stage 6  field mapping -> canonical-space regions projected to frame ROIs
      ──> MeasurementProcessor.process(frame:roiOverrides:requiringOverride:)
      ──> AppState.applyScreenLock(...) + AppState.apply(...)
```

Cadence intervals are in **frame-timestamp seconds**, not frame counts, so behavior does not
change between 12 fps synthetic and 30/60 fps camera. No queue is added: the pipeline inherits
`FrameProcessor`'s existing serial-drain backpressure.

**Verified in a live Simulator run** (`-daqpal-screen-lock`): AUTO on → detector proposes
candidates with fused confidence → magnet attracts → **LOCKED** → tracker holds geometry →
display warped to canonical → fields analyzed → field selected → mirrored to a device →
**value read through tracked geometry** (FIELD 1 = 12.574 @ 68.1%, LOCKED). Screenshots in the
build log.

### Three integration bugs that only the live run exposed

All three compiled, unit-tested clean, and were invisible to inspection:

1. **Attraction never accumulated.** `MagneticSnapEngine` moves the selection a *fraction* of
   the way toward the candidate each frame, but the pipeline re-derived the selection from the
   caller's stored ROI every frame, discarding that progress. The machine sat in
   `.magneticAttraction` forever and **no lock was ever reachable**. Fixed by retaining
   `attractedSelection` across frames.
2. **Field-backed devices were filtered out of the processor config.** `syncProcessorConfig`
   built configs with `devices.compactMap { device.roi.map { ... } }`, and a field-backed device
   has no *stored* ROI by design — so it never reached the processor, and the per-frame override
   had no config to apply to. Selecting a field was a **no-op end to end**.
3. **Readings were discarded after being computed.** `AppState.apply` gated on
   `device.roi != nil` and forced `.empty` for anything without a stored ROI, throwing away
   every field-backed reading the processor had already produced.

Bugs 2 and 3 are the same mistake in two places: using `roi != nil` as a proxy for "this device
is active", which stopped being true the moment geometry became per-frame. Both now test
membership in `fieldBackedDeviceIDs` explicitly.

### BLOCKING — tracking does not survive fast motion

Observed directly under `-daqpal-demo-motion bounce`: the Vision tracker **lags the moving
panel and then drifts off it entirely, while continuing to report healthy confidence**. The UI
stays `LOCKED` and keeps displaying a value even though the tracked quad sits over empty
background. The detector meanwhile correctly re-proposes the real panel at 94%.

This is the most serious open issue in the system, and it is a *correctness* failure rather
than a performance one: silently reporting a stale value as `LOCKED` is worse than reporting
nothing. Do not trust tracked-geometry capture under motion until this is resolved. Likely
contributors, in order of suspicion: the tracker's confidence is not sensitive to positional
lag; the degraded/reacquisition thresholds are never crossed because confidence stays high; and
the snap engine cannot detect that a healthy-looking track has diverged from the detector's own
proposals. A cross-check that compares the tracked quad against fresh detector candidates and
forces reacquisition on divergence is the obvious next step.

Steady-state (`-daqpal-demo-motion steady`) capture works correctly.

### Live-defect round (2026-07-27) — jitter, overlay, decimals

**Drag jitter in `DMM-1 - SEARCHING` — root cause measured.** Instrumented invalidation counts
against the unmodified code, 60 frames per scenario:

| Scenario | Overlay invalidations |
|---|---|
| SEARCHING, rejected, varying confidence | 60/60 |
| SEARCHING, rejected, constant confidence | 1/60 |
| LOCKED, steady value, varying confidence | 60/60 |
| LOCKED, steady value, constant confidence | 1/60 |

The driver is one field: `AppState.apply` wrote `reading.confidence` on rejected readings, and a
varying confidence defeats the `reading != previous` change gate. Note what the data *disproves*:
locked state is not intrinsically quiet — it churns identically when confidence varies. What
makes SEARCHING special is that the churn there is **pure waste**: nothing displays an unlocked
device's confidence (`DeviceReadingCard.confidence` returns 0 unless locked; the overlay's
SEARCHING label shows no percentage).

Two fixes: unlocked readings no longer publish a varying confidence, and `ROISelectionOverlay`
no longer reads `liveReadings` in any body that attaches a gesture — lock-dependent visuals moved
to leaf views. A latent bug surfaced en route: both `.onEnded` handlers cleared `isEditingROI`
*inside* `if let anchor`, so a gesture ending without an anchor left ROI auto-tracking paused for
the rest of the session.

**Decimal integrity — the feature existed but was not shipping.** Two real parser defects were
fixed (max-digits token selection returned `345` for `"12 345"`; no comma handling existed at
all). But the decimal confidence was computed and then **discarded**: `MeasurementProcessor`
never passed `decimal:` to `ConfidenceEngine.fuse`, and `finalizeOutcome` hardcoded
`.invalidFormat`, making `.ambiguousDecimal` unreachable by the user. Now wired: recognition uses
`FormatValidator.reading(from:)` instead of `value(from:)`, carries the analysis and the
validator's own rejection reason through `RecognitionOutcome`, and both reach fusion.

**A recall regression was introduced and fixed in the same round.** The split-reading detector
rejected *any* two whitespace-separated numbers — `"12.3 45.6"`, even `"12.345 12.345"`. That
leaks past value reading into `ScreenCandidateDetector.numericScore`, which uses the same entry
point as a display-detection heuristic, so it made real multi-value panels *harder to detect as
screens*. The rule now additionally requires that neither token retained a separator, which is
the actual signature of a dropped one.

**Three tests were wrong.** Two pre-existing tests encoded the defect (coercing `12.34.7` to
`12.34`), which spec §11A forbids; updated with justification rather than reverting the fix. One
was mine: I asserted `.ambiguousDecimal` where `.invalidFormat` is correct — `12.34.7` is
structurally malformed, whereas `.ambiguousDecimal` means the digits are fine but the separator's
position cannot be determined. Conflating them would make the ambiguity signal useless for
diagnosing real decimal loss.

**Suite: 572 passed, 0 real failures, 2 fixture-skips** (the one red test was the documented
AVAssetWriter parallel-clone flake; passed on serial retry).

### Still open after this round

| Area | Gap |
|---|---|
| Drag jitter | The gesture-isolation fix has **zero test coverage** — reverting it leaves all 13 drag tests green. The churn is measured; that churn causes the *jitter* is argued, not proven. |
| Overlay | Geometry verified as a real quad by construction and by hand at 30° roll, but **never seen running**. Hit-testing still uses the bounding box (~1.9× the quad's area at 30° roll), so taps land outside the drawn outline. |
| `FieldSelectionOverlay` | Retains the exact anti-pattern just removed from `ROISelectionOverlay`: reads `lockedTarget` (per-frame) *and* attaches `.onTapGesture`. |
| Token grammar | `ScreenFieldAnalyzer.numberPattern` still holds the old regex, so it and `FormatValidator` now disagree about what a numeric token is. |
| Performance | No wall-clock figure has been captured anywhere. Every performance claim in this project remains mechanism-level only. |

### SEARCHING drag jitter — RESOLVED, and the four wrong diagnoses (2026-07-28)

**Resolution: SwiftUI `DragGesture` was replaced with a UIKit
`UIPanGestureRecognizer` (`PanGestureCatcher`). User-confirmed smooth.**

The cause was **latency, not cadence**. That distinction is the whole lesson of
this defect, and it cost four wrong diagnoses to reach.

#### What the device actually measured

On an iPhone 12 Pro Max (60 Hz native), instrumented mid-drag with the capture
pipeline running:

```
touch  : ticks 46 · p50 16.7ms · p95 17.7ms · max 17.9ms · stalls 0
render : frames 63 · exp 16.7ms · p50 16.7ms · p95 16.7ms · max 16.7ms · dropped 0
```

Touch events arrived exactly once per display frame. **Not one frame was
dropped.** Identical with the pipeline idle. Both cadences were already perfect
while the drag still felt sluggish and jittery — which is not a contradiction:

> A box rendered three frames behind the finger has flawless cadence and still
> feels detached. **Constant latency is invisible to a cadence probe by
> construction.**

SwiftUI's gesture path costs several frames end to end (recognition → `@State`
write → `body` → layout → composite), and recognition in a deep hierarchy is the
largest part. `UIPanGestureRecognizer` reports on the UIKit touch path directly.
A second, separate hitch was removed with it: `DragGesture(minimumDistance: 2)`
held the window still until the finger had travelled 2 pt and then **jumped**,
because `translation` is measured from touch-down rather than from the threshold
crossing — a visible catch-up at the start of every drag.

Only the gesture *recognition* changed; rendering remains SwiftUI.

#### The four wrong diagnoses, and why each survived

| # | Diagnosis | Fate |
|---|---|---|
| 1 | `liveReadings` churn rebuilding the gesture mid-drag | Churn was real (60/60 frames) and gating it was correct, but reverting the isolation fix leaves every drag test green — the causal claim was never established |
| 2 | Gesture reconstruction from parent re-evaluation | Argued from code, never measured; symptom survived |
| 3 | Pipeline cost — `.accurate` Vision pass (~382 ms) never short-circuiting in SEARCHING | Real cost, and standing down during a gesture is right on correctness grounds, but the symptom survived |
| 4 | 60 Hz cap / missing ProMotion opt-in | Killed by fact: iPhone 12 Pro Max has no ProMotion, so 16.7 ms IS native |

Every one of the first three was argued from reading code rather than from a
measurement, and each produced a defensible improvement that did not fix the
reported symptom. **The project's own principle 1 — profile before optimizing —
was violated four times in a row on the same defect.**

#### Instrumentation kept (DEBUG-only)

- `GestureLatencyProbe` — inter-callback intervals (rules out event starvation).
- `RenderCadenceProbe` — `CADisplayLink` intervals, i.e. genuinely composited
  frames, with "dropped" measured against the display's own reported frame
  duration rather than an assumed 60 Hz.
- `DragLatencyUITests` — drives a real drag on device and asserts both, plus a
  control run with the frame pump never started, which is what proved the
  Simulator's 6–7 ticks at 115–180 ms was genuine starvation there and not an
  XCUITest event-rate floor.

**Both probes measure cadence. Neither measures latency.** If a drag ever feels
wrong again while both read clean, that is the signature of lag, and the next
step is driving the window position through `CALayer` to remove the remaining
`body`/layout hops.

#### Simulator-only finding, still open

The Simulator starves the gesture badly (6–7 callbacks at 115–180 ms, worst
301 ms) because its preview path converts each 1080×1920 frame to a `CGImage`
and publishes it to a `CALayer` on the main actor every frame. The device uses
`AVCaptureVideoPreviewLayer` and never pays this. That path sits UPSTREAM of the
`FrameProcessor` stand-down, so the stand-down does not gate it. Not a shipping
bug; it does make the Simulator misleading for interaction work.

### Superseded: the corrected diagnosis (kept for the record)

The user reported the drag was STILL jittery and sluggish after the
confidence-normalization and leaf-isolation fixes. Measurement showed **the
invalidation hypothesis was wrong** — or rather, real but no longer the cause.

`DragChurnDiagnosticTests` probes each observable property individually across
60 frames, in the reported conditions (placed device, never locking, rejected
readings at capture rate, `isEditingROI == true`). Result: **no gesture-hosting
property churns at all**, and whole-screen invalidations are ≤ 2 / 60, including
while recording. The state layer is quiet. Two rounds of invalidation work were
genuine improvements that did not fix the reported symptom.

**The actual cause is pipeline cost, and the word "sluggish" was the clue.**
`SEARCHING` is structurally the most expensive state the app can occupy:
nothing is ever accepted, so recognition never short-circuits, and
`DualPassVisionOCR` runs its `.accurate` pass — documented in that file at
**~382 ms** — on every frame for the entire duration of the gesture. On top of
that the drain took **two main-actor hops per frame**, one of which
(`screenLockInputs`) ran even though the intelligent path is OFF by default.
Those hops queue against touch handling. No amount of re-render gating addresses
this.

**Fix 1 — the drain stands down while a gesture is active.** A correctness fix
before a performance one: the ROI is moving under the finger, so anything
recognised from it is read from a region the user is still choosing. Such
readings are meaningless and are rejected anyway. Skipping them frees the drain
and both main-actor hops for the whole gesture.

**Fix 2 — the acquisition-inputs hop is paid only when screen-lock is enabled**,
rather than every frame in the shipping default.

**Mechanism.** The drain reads the gesture flag through a new lock-free
`InteractionState.shared` rather than `AppState.isEditingROI`. Asking the MAIN
ACTOR whether the main actor is busy would defeat the purpose entirely.

**New failure mode this introduces, and its guard.** A stuck interaction flag
now suspends recognition *permanently* rather than merely pausing ROI tracking —
a strictly worse consequence for the same bug class already found once (both
`.onEnded` handlers previously cleared `isEditingROI` inside `if let anchor`).
`testGestureEndAlwaysReleasesTheDrain` covers it.

Tests: 28/28 green across `DragChurnDiagnosticTests`, `DragStabilityTests` and
`CapturePerformanceTests` (10/10, no regression).

**Still unverified:** whether this actually resolves the felt symptom on device.
The measurement establishes the cost and that it is now skipped; only a physical
drag confirms the fix. If sluggishness persists when NOT dragging, the next
suspect is the `.accurate` pass running at full frame rate in `SEARCHING`
generally, which would call for cadence-limiting recognition rather than
running it on every frame.

### Appearance verification: a redundant layer commissioned, measured, and removed (2026-08-02)

**Process error, recorded because the lesson is the deliverable.** A content-consistency
signal was commissioned to close a gap I reasoned out — motion coupling is structurally blind
to a STATIC distractor (a poster or bezel under a drifted quad never moves relative to it, so
`transit` cannot fire), and to drift slower than the coupling tolerance. I did not first check
whether an appearance mechanism already existed. `AppearanceSentinel` did, already wired into
`ScreenLockPipeline` Stage 1b at per-frame cadence. The implementing agent found the collision
and made its work additive rather than overwriting a type the pipeline consumes — the correct
call, and better judgement than the instruction it was given.

**Why the new layer was removed rather than kept.** The candidate advantage was
pose-normalization: a canonical-space descriptor compares correctly when the display is seen
at a new angle, where a frame-space patch would decorrelate. That advantage does not exist —
`LumaPatch.sample` solves `Homography.solve(from: .canonical, to: quad)` and samples a
canonical grid warped into the frame, so the shipped NCC **is already pose-normalized**. With
that gone the two mechanisms answer the same question, and the shipped one answers it better:
per-frame rather than 2 Hz, digit-invariance measured, plus a variance-collapse check aimed at
precisely the flat-background distractor case. Two overlapping mechanisms with two threshold
sets — one wired, one dead — is the complexity the remediation plan's own rule forbids without
measured justification.

**The finding was worth more than the code, and it did not transfer.** The removed descriptor
measured that a luma layout CANNOT separate a partly occluded panel from a quad parked on
background: past ~10% cover its similarity fell *below* the background case (0.164 at 30%
cover vs 0.191 for background). If the shipped NCC shared that property it would be a live
defect, because `consecutiveFailuresToVeto` is 4 at PER-FRAME cadence — roughly 0.33 s at
12 fps — so a hand resting on the panel would veto a healthy lock. Ported as
`testOcclusionVersusBackground_characterized` and measured against the shipped path:

| Scenario | NCC | vs veto threshold 0.35 |
|---|---|---|
| Digit change, no occlusion | 0.879 | healthy |
| Occlusion 10% | 1.000 | healthy |
| Occlusion 25% | 0.866 | healthy |
| Occlusion 50% | 0.658 | healthy |
| Parked on background | abstains (flat patch, no correlation) | variance-collapse vetoes it instead |

**The shipped NCC does not inherit the flaw.** It holds 0.658 at 50% cover where the removed
descriptor sat below background, and it rejects background through a *separate* path
(variance collapse) rather than through similarity — which is exactly why it escapes the
tension that made the other descriptor unusable. The test is a characterization: it records
the numbers and asserts only the property that must hold for the sentinel to work at all (a
digit change never reads as a lost lock).

**Still open from this line of work.** Polarity is not invariant for either descriptor — an
emissive panel whose backlight toggles mid-lock will veto rather than adapt. And the original
motivating gap is only partly closed: variance collapse catches a quad parked on FLAT
background, but a *structured* static distractor (a poster with panel-like layout) would
correlate against its own reference once refreshed. Reference refresh is gated on detector
corroboration, which bounds but does not eliminate that path.

### Decimal-safe OCR round (2026-07-28) — iPhone-first

**First real on-device measurement in this project.** `DecimalBenchmarkTests` ran on the
connected iPhone three times (`** TEST SUCCEEDED **`, 11.4 s / 12.3 s / ~12 s). Engine load
measured 554.7 → 266.4 → 223.0 ms across consecutive runs — a 3.3x spread decreasing
monotonically, consistent with OS caching, so **true cold-boot cost remains unmeasured**.
All candidate-model latency is **unmeasured on iPhone**; every figure in
`OCR_MODEL_COMPATIBILITY.md` is an M1 Pro Mac and must not be read as phone latency.

**Model verdict: keep Apple Vision as the hot path.** Real conversion attempts, real failures:
PARSeq → Core ML dies with `TypeError` at `coremltools/.../ops.py:3048` (reproduced two ways);
doctr CRNN converts only by bypassing its own `forward()`; PP-OCRv5 needs opset 7→17 plus
`onnxsim` (1019→340 nodes) to survive `KeyError: 'conv2d_0.w_0'`. Structural finding:
**coremltools 9.0 removed the ONNX front-end**, so ONNX→Core ML is no longer a direct path.
None of this displaces an ANE-accelerated recognizer already behind the `OCREngine` seam —
especially since the measured failure is decimal LOSS, which happens in preprocessing before
any recognizer runs.

#### `DecimalRescue` — what it does and does not cover

Model-independent separator detection on the canonical ROI: adaptive (Bradley-style local-mean)
binarization, deterministic 8-connected flood-fill labeling, then classification by size,
aspect, fill, baseline adjacency and horizontal position between digits.

Measured on raster/proportional faces: `"80.8"` → present, position 2, confidence 0.97;
`"808"` → absent. Survives blur to the top of the sweep, brightness to 0.1, noise to 0.7.

**MEASURED LIMITATION — true seven-segment faces are not covered.** Segments do not touch, so
connected-component labeling finds SEGMENTS, not digits: a clean DSEG7 `"80.8"` yields 21
components (17×76 verticals, 89×17 bars) and none is a digit. Across every DSEG7 preset it
reported an absence or a presence with NO position — never a wrong position, which is the
required failure mode, but it is a real recall gap. Closing it needs component→digit-cell
grouping by x-pitch (the job `DigitSegmenter` / `SevenSegmentSampler` already do) feeding this
analysis. Deliberately not approximated.

#### The safety defect that inverted the module's purpose

`absence()` shipped defaulting to `confidentAbsence = 0.82`, downgrading only when its
inter-digit gap test both APPLIED and FIRED. That test needs ≥3 digit components, so three
reproduced cases returned a CONFIDENT "there is no decimal":

| Case | Why the test could not see it |
|---|---|
| `.808` | Leading-zero suppression (universal on multimeters) — the dot precedes every digit, so no inter-digit gap holds it |
| `9.9`, `0.5` | Two digits give one gap; `gaps.count >= 2` is false and the test never runs |
| Any segment face | Components are segments, so gap statistics are meaningless — observed NEGATIVE ("−16px typical") |

This is exactly the silent coercion the module exists to prevent, carrying the rescue layer's
endorsement. Fixed: a confident absence must now be *earned* (clean segmentation, usable gap
statistics, gap test passed). Fixing it exposed a deeper structural limit — candidate detection
requires the dot to sit BETWEEN adjacent digits, so a **leading separator is never examined at
all**. Absence confidence is therefore capped at `betweenDigitsOnlyCeiling = 0.5` and the
rationale says so. Raising that cap requires extending detection to the region left of the
first digit; until then the format prior and temporal consensus resolve that case.
`DecimalRescueTests` 23/23 green, including three regressions for the above.

#### Still open in this area

- Segment-face recall gap (above) — the likely shape of a real temperature gun.
- Leading separators structurally unexamined by rescue.
- `TemporalConsensus` anchor CREATION needs only 2 uncorroborated frames, so the coercion can
  still occur at startup; `.ambiguous` can deadlock indefinitely.
- Decimal comma (`80,8`, European instruments) unhandled by rescue — safe direction (low
  confidence), but undisclosed until now.
- No iPhone latency for any candidate model.

### Other known open defects

Found by adversarial review and not yet closed. Listed so they are not rediscovered as
surprises:

| Component | Defect | Consequence |
|---|---|---|
| `ScreenCandidateDetector` | Corner labeling is continuous on the matched path, but the anchor is frozen at first detection | A candidate first acquired past the anchor-flip angle keeps transposed width/height, so `aspectRatio` scores ~0 and it may never reach lock |
| `ScreenFieldAnalyzer` | `numericIsDominant` rejects a short reading followed by an unknown unit word | "230 VAC", "12 PSI" classify as `.label` and produce no numeric field |
| `VisionScreenTracker` | Recovery re-seed has no proximity or identity gate | After 5 consecutive rejections of any kind, a lock can silently migrate to unrelated geometry |
| `VisionScreenTracker` | Re-seed confidence is blended with Vision's score | The recovery frame can report `.lost`, which is worse than the rejection it replaces |
| `MagneticSnapEngine` | `release()` after a detector-driven relock suppresses an id no detector will propose | The magnet can re-grab a display the user just rejected |
| `MagneticSnapEngine` | `nil` (detector idle) expires on the same 0.4 s grace as `[]` (detector found nothing) | Contradicts the documented unconditional carry-forward for `nil` |

## 10. Known limitations

- **No Instruments profile.** The lag root cause was established by observation-graph analysis
  and is regression-tested at the mechanism level (§3). No before/after FPS, CPU, GPU or memory
  figures exist, and none are claimed.
- **Affine, not projective, motion simulation.** The synthetic rig approximates yaw/pitch as
  foreshortening; true keystone distortion is not simulated. Perspective normalization is
  therefore validated against synthetic affine geometry, not real camera perspective.
- **Physical-device validation outstanding.** Real camera behavior, real instrument OCR
  accuracy, real slow-motion footage, and thermal behavior during video recording remain
  unverified — the gates the Simulator structurally cannot cover.
- **Dot-matrix displays** are not readable by any engine currently integrated (measured: 0% in
  the OCR benchmark; see `OCR_RESEARCH.md`).
- Two accuracy-harness tests skip pending a real recorded `dmm_001.mov` fixture.
- Two AVAssetWriter video tests are flaky under parallel simulator clones (VideoToolbox
  contention); they pass serially. Retry-first policy.

## 11. Drift remediation — live evidence (2026-07-31)

Live Simulator re-run of the §9 drift scenario against the build containing `TrackVerifier`
(Stage 2b hard veto / strike degradation). iPhone 17 Pro simulator, bundle `danieliu.DAQPal`,
screenshots in the session scratchpad under `drift_evidence/`.

**Steady control** (`-daqpal-screen-lock -daqpal-demo-motion steady -daqpal-auto-select-fields 2`,
~15 s): chip LOCKED, tracked quad on the panel (94% detector corroboration visible), FIELD 1
card live at 12.595 / 67.2% LOCKED. The verifier does not break the working path — no
over-aggressive veto. Screenshot: `steady_control.png`.

**Bounce scenario** (`-daqpal-demo-motion bounce`, same flags): the original failure signature
is STILL PRESENT. In all six captured frames (`bounce_t15/t19/t23/t27.png` at ~4 s spacing,
`bounce_late_a/b.png` ~3 min into the run) the tracked quad sits pinned near the bottom of the
frame over empty background while the synthetic panel is visibly elsewhere (mid/top of frame).
The state chip reads LOCKED in every frame — DEGRADED or REACQUIRING was never observed — and
the FIELD 1 card shows live, fresh values with a LOCKED badge: 12.606/67.9% → 12.637/78.0% →
12.649/92.0% → 12.645/92.0% across t15–t27, and in `bounce_late_b.png` the card reads 11.973
while the panel shows 11.969, proving OCR is actively reading the real panel digits (simulator
logs confirm continuous live TextRecognition passes during the drifted state). This meets the
task's explicit "fix is NOT working" criterion: quad on background + chip LOCKED + fresh value.

**Interpretation (inference from on-screen overlays, not instrumented verdicts):** the drifted
quad lies on the bouncing panel's travel path. Between sweeps, detector re-proposals render at
40–42% — below `testimonyConfidence` (0.60) — so no candidate can testify and DIVERGED never
fires. When the panel periodically sweeps through the drifted quad's region, a detection pass
finds a ≥60% candidate overlapping the tracked quad (71–74% candidates visible near the quad in
the late frames), which CORROBORATES the lock and resets the unsupported strikes before they
reach 3. The verifier therefore never sustains `isUnverified`, `measurementsValid` stays true,
and field ROIs keep flowing to OCR. The same sweep explains the fresh card values: digits enter
the drifted ROI once per bounce period.

**Unmeasured:** the internal verdict sequence (no verifier logging is exposed), per-pass
detector confidences, and the actual value of `measurementsValid` in the captured frames (its
truth is inferred from the `.locked` chip plus continuing OCR, not read directly).

**Status:** steady path intact; bounce drift NOT remediated in live operation. The verifier
logic is sound for a quad parked off the target's path, but a quad parked ON the motion path is
periodically re-corroborated by the target itself passing through it.


### Verifier hardening — two escapes I shipped, found by arithmetic (2026-08-02)

Two defects in my own `TrackVerifier`, both found by checking the numbers rather
than re-reading the prose:

1. **Corroboration radius was a veto escape.** `corroborationCenterFactor *
   max(meanWidth, meanHeight)`. An instrument panel is wide and short — the
   synthetic rig is 0.76 x 0.13 normalized — so the allowed center distance was
   `0.75 x 0.76 = 0.57`, **more than half the frame**. A tracked quad could sit
   completely off the display and still be "corroborated" by it. Now scaled by
   the SHORTER side (~0.10 for the same panel), which is the scale at which two
   boxes are plausibly the same physical display.
2. **Coupling compared raw displacement, not rate.** Detection passes are not
   uniformly spaced: nominal 0.5 s, but a pass up to `couplingMemoryMaxAge`
   (1.6 s) old is still used. A fixed displacement bound therefore made
   strictness scale with scheduling jitter — the same physical speed reads as 3x
   after a 1.5 s gap, **false-vetoing a correctly tracked display**, which is a
   worse defect than the drift it guards. Now a per-second rate
   (`motionCouplingRate` 0.07/s); verified to veto a 0.11/s sweep at 0.4/0.5/1.0/1.5 s
   pass spacings and to leave an attached lock alone across a delayed pass.

**Corner agreement made scale-tolerant.** A `cornerLevelAgreement` gate compared
raw `meanCornerDistance`, which conflates a concentric tighter crop of the SAME
display (the detector proposes these routinely, and the center-distance path
exists to accept them) with a box genuinely elsewhere. It struck the former,
turning a healthy lock into accumulating strikes — a false veto. The candidate is
now normalized about the tracked centre to the tracked scale before comparing, so
size alone cannot fail the gate while skew/rotation/offset still do.

Tests: 29/29 (TrackVerifierTests + DriftRegressionTests), including new cases for
both escapes and the delayed-pass false-veto guard.

**Process note — concurrent-edit hazard.** A review agent briefed "report only,
do NOT edit files" nonetheless reworked `TrackVerifier.swift` (adding the `Config`
struct) while I was editing the same file. My fixes and its rework interleaved.
Nothing was lost — the result was reconciled and is green — but the orchestration
error was mine: a reviewer with write tools will sometimes write. Future review
agents should run against a read-only worktree, or the file should be frozen for
the duration of the review.

### Resolution: transit veto with id-independent motion coupling (2026-08-01)

The first `TrackVerifier` failed live twice, each time teaching a sharper rule:

1. **Overlap is not attachment.** A quad drifted onto the panel's bounce path was
   re-corroborated every ~1.5 s by the panel itself sweeping through it at 71–74%
   confidence, while blurred re-proposals elsewhere (40–42%) sat below the 0.60
   testimony bar — a dead lock indefinitely re-blessed by its own victim passing by.
   Fix: corroboration also requires **motion coupling** — the witness must move WITH
   the tracked quad; decoupled overlap is a new `transit` verdict, a hard veto.
2. **Detector id churn destroys id-keyed checks.** The transit check first required
   the same candidate id across passes; fast motion gives the panel a fresh id nearly
   every pass, so every sweep read as a first sighting, and low `temporalStability`
   also kept the persistence-testimony fallback dark. Fix: coupling is
   **id-independent** (any witness overlapping the quad is claiming to be our
   display, so its motion owes consistency with ours), with a freshness bound
   (`couplingMemoryMaxAge` 1.6 s) so stale memories cannot misread slow travel.

**Measured outcome** (verdict trace, `subsystem == "daqpal"`, 81 verification passes
over ~40 s of continuous bounce): 58 corroborated / 23 transit; state at
verification time LOCKED 8 · DEGRADED 6 · REACQUIRING 67; **LOCKED-while-unverified:
0 passes** — the absolute acceptance rule ("never a healthy lock on unverified
geometry") holds across the whole trace. Unit coverage: 34 tests across
TrackVerifierTests (incl. the two live escapes encoded directly), DriftRegressionTests
(E2E lock → drift → invalidate → relock), CapturePerformanceTests.

**Honest characterization of the current behavior under continuous bounce:** the
system does not *track* the bouncing panel — `VisionScreenTracker` cannot follow
super-frame-rate motion — it now *refuses to lie about it*. It spends most passes
REACQUIRING, transiently relocks during genuine overlap windows (readings taken in
those windows are read from the real panel), and transit-vetoes as the panel moves
on. The plan's "tracking survives fast translation" boxes therefore remain OPEN;
what is closed is the data-integrity failure (false healthy lock). The FIELD card
may display its last value for up to `lockTimeout` (1 s) after invalidation — the
underlying `measurementsValid` gate stops new readings immediately; the residual
display staleness is cosmetic and bounded.

**Kept instrumentation:** DEBUG verdict trace in `ScreenLockPipeline` Stage 2b —
screenshot sampling under-measured this state machine twice; the trace is the
ground truth for whether the veto engages.
