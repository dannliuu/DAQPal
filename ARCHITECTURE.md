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
