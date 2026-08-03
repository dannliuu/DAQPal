# DAQPal — Screen Tracking Implementation Report

**Deliverable:** `DAQPal_SCREEN_TRACKING_REMEDIATION_PLAN.md` Phase 23 (§26), sections A–K.
**Date:** 2026-08-02.
**Sources:** `ARCHITECTURE.md` (§1–§11), `PROGRESS.md`, `IMPLEMENTATION_NOTES.md`,
`OCR_MODEL_COMPATIBILITY.md`, `OCR_DEVICE_BENCHMARK.md`, and the test files named inline.

**Provenance rule (applies to every number in this report).** Each figure is tagged with where
it came from: **[device]** = physical iPhone 12 Pro Max (`iPhone13,4`, iOS 26.5.2, Debug/`-Onone`
unless stated), **[sim]** = iOS Simulator on the development Mac, **[host]** = M1 Pro macOS
(never an iPhone number), **[trace]** = the DEBUG verdict trace emitted by
`ScreenLockPipeline` Stage 2b, **[test]** = a deterministic unit/integration test,
**[screenshot]** = a captured Simulator frame. Anything without a figure is written
**UNMEASURED** — no number in this report is estimated or extrapolated.

---

## A. Architecture

### Final pipeline

```
AVCaptureSession ──> LiveCameraFrameSource ─┐
SyntheticFrameSource (Simulator) ───────────┼──> AsyncStream<TimestampedFrame>
AVAssetReader (VideoImport) ────────────────┘              │
                                                           ▼
                                                   FrameProcessor
                                          (serial drain = backpressure)
                                                           │
      ┌────────────────────────────────────────────────────┤
      │  ScreenLockPipeline (actor), inline in the drain:  │
      │   stage 1   tracking        every frame while locked
      │   stage 2   detection       time-gated, adaptive
      │   stage 2b  INDEPENDENT VERIFICATION (TrackVerifier)
      │   stage 3   snap state machine
      │   stage 4   lock commit → start tracker, request analysis
      │   stage 5   field analysis   gated ≥ 1.0 s, never per-frame
      │   stage 6   field mapping → canonical regions projected to frame ROIs
      └────────────────────────────────────────────────────┤
                                                           ▼
                                            actor MeasurementProcessor
                              crop/ROI → OCR → FormatValidator → PhysicalValidator
                                → TemporalFilter → TemporalConsensus → ConfidenceEngine
                                                           │
                                                    FrameResult
                                                           │
                                                  await MainActor.run   (once per frame)
                                                           ▼
                                        @MainActor @Observable AppState → SwiftUI
```

Field ROIs flow to `MeasurementProcessor` only while `measurementsValid` is true — the single
gate that couples geometric verification to measurement validity (`ScreenLockPipeline.swift`).

### State machine

`SnapState` (`DAQPal/Tracking/TargetLock.swift`):
`manual → candidateDetected → magneticAttraction → snapPreview → locked`, with
`trackingDegraded` / `reacquisition` recovery paths. Forward gates (`enter*`) sit strictly
above release gates (`exit*`) in `SnapTuning`; the gap is the hysteresis that prevents state
flapping. UI states rendered distinctly: LOCKED / DEGRADED / REACQUIRING chips
(**[trace]** shows all three cycling under drift — see §F).

### Thread / queue architecture

| Stage | Isolation | Notes |
|---|---|---|
| Frame production | AVFoundation capture queue / detached Task | `alwaysDiscardsLateVideoFrames = true` |
| Screen lock + verification | `actor ScreenLockPipeline`, inline in `FrameProcessor`'s serial drain | inherits drain backpressure; no new queue |
| Recognition + validation | `actor MeasurementProcessor` | per-device recognition fans out concurrently within one frame |
| State publication | MainActor (`AppState.apply`) | the only main-thread work in the pipeline |
| Rendering | MainActor (SwiftUI); preview frames bypass SwiftUI via `CALayer.contents` | see §H |

Backpressure is structural, not configured: `FrameProcessor` `await`s each frame before
pulling the next, so no queue exists to grow; the source's drop-late policy discards the
backlog (`ARCHITECTURE.md` §1). `VNSequenceRequestHandler` is confined to the
`VisionScreenTracker` actor; `CVPixelBuffer` moves under a documented linear-ownership rule.

Cadence intervals are in frame-timestamp seconds, not frame counts (`ScreenLockPipeline.swift`):
acquiring detection 0.2 s · locked (independent revalidation) 0.5 s · degraded/reacquiring
0.1 s · stale-tracker timeout 0.75 s · field analysis ≥ 1.0 s apart. The locked interval was
tightened from the earlier 2.0 s because 2.0 s "left a drifted-but-LOCKED reading on screen for
up to two seconds" (comment in source; the 0.2/2.0/0.1 figures in `ARCHITECTURE.md` §9 predate
this change).

---

## B. Detection

**Method.** `ScreenCandidateDetector`: Apple Vision rectangle detection as the non-OCR primary
signal, plus text/numeric-density signals, fused by weight (`IMPLEMENTATION_NOTES.md`,
`ARCHITECTURE.md` §6).

**Candidate score.** Detection evidence is kept as named components (`ScreenSignals` /
`ScreenSignalWeights`), never a pre-blended number. Geometry + aspect + temporal stability
carry **0.65** of total weight, which structurally enforces the plan's rule that OCR
contributes but cannot dominate: a text-free but strongly rectangular, stable display still
clears the **0.60** detection threshold (`ARCHITECTURE.md` §6). Weights are the documented
initial values; they have **not** been validated against labeled data (plan §6's tuning
checklist remains open).

**False-positive performance: UNMEASURED.** No distractor corpus (laptops, phones, windows,
posters, reflections, bezels) has been run; no false-positive rate exists. One known detector
defect is open: corner labeling is continuous on the matched path but the anchor is frozen at
first detection, so a candidate first acquired past the anchor-flip angle keeps transposed
width/height and may never reach lock (`ARCHITECTURE.md` §9 defect table).

Live behavior observed **[screenshot]**: steady synthetic panel proposed at **94%** detector
confidence; under bounce, blurred re-proposals rendered at **40–42%** and genuine overlap
candidates at **71–74%** (`ARCHITECTURE.md` §11) — these figures are read off on-screen
overlays, not instrumented logs.

---

## C. Geometry

**Corner model.** `ScreenQuad` — four corners in normalized top-left space with *semantic*
corner names (which corner of the physical screen, not positional), which is what keeps
canonical-space field coordinates stable through rotation. `ScreenQuad(roi:)` losslessly
promotes any manual selection; `.boundingBox` converts back for existing consumers
(`ARCHITECTURE.md` §5).

**Corner refinement.** None beyond Vision's rectangle vertices. No sub-pixel or
gradient-based refinement is implemented; no corner-error benchmark exists (plan Build Gate 4's
"corner error benchmark" remains open).

**Homography.** Direct linear transform from exactly four correspondences, solved by Gaussian
elimination with partial pivoting; returns `nil` rather than garbage for singular systems, so
a degenerate quad degrades to "no geometry this frame" (`ARCHITECTURE.md` §5). Canonical space
is the unit square; field regions are stored *only* in canonical space and projected through
the live target homography — this single decision keeps fields glued to the same physical part
of the display without per-field tracking. Determinism and solve-count budgets are
regression-tested **[test]** (`PipelineBudgetTests`: `testHomographySolve_isDeterministicForAFixedQuad`,
`testHomographySolve_countScalesWithTargetsNotFields`). No RANSAC/feature-correspondence
homography path is implemented; reprojection-error logging does not exist.

---

## D. Tracking

**Tracker selected.** `VisionScreenTracker` (an actor wrapping `VNTrackRectangleRequest`) with
`DampedQuadTracker` smoothing/confidence. The tracker is deliberately **not** trusted: its
self-reported confidence is excluded from lock validity (see §E), because the measured failure
mode is a self-consistent tracker that never lowers its own confidence after detaching from
the display (§F).

**Cadences** (all from `ScreenLockPipeline.swift`, frame-timestamp seconds):

| Function | Interval |
|---|---|
| Frame-to-frame tracking | every frame while locked |
| Independent revalidation (detection feeding `TrackVerifier`) | 0.5 s while locked |
| Detection while acquiring | 0.2 s |
| Detection while degraded/reacquiring (recovery runs hot) | 0.1 s |
| Stale-tracker hard fail (`trackerHasNoFreshUpdate → FAIL_AFTER_TIMEOUT`) | 0.75 s |
| Field analysis | ≥ 1.0 s between passes |

These are configured values, honored by construction in an actor with time-gated stages;
achieved wall-clock rates on device are **UNMEASURED** (see §H).

**Known open tracker defects** (`ARCHITECTURE.md` §9): recovery re-seed has no proximity or
identity gate (after 5 consecutive rejections a lock can silently migrate to unrelated
geometry), and re-seed confidence blending can make the recovery frame report `.lost`.

---

## E. Confidence

**Components.** Lock validity is decided by `TrackVerifier` from independent evidence only —
the tracker's own confidence is deliberately excluded:

1. **Detector corroboration** — a fresh candidate overlapping the tracked quad
   (IoU ≥ 0.30, or center distance within 0.75 of quad scale for tighter crops of the
   same display).
2. **Motion coupling** — corroboration additionally requires the witness to move *with* the
   tracked quad (relative-motion tolerance 0.035 normalized units); decoupled overlap is a
   `transit` verdict, a hard veto (see §F for why this exists).
3. **Persistence testimony** — a persistently-seen weaker candidate elsewhere
   (confidence ≥ 0.40 with temporal stability ≥ 0.5) can testify to divergence even when it
   falls below the normal testimony bar.
4. **Stale-tracker timeout** — no tracker update for 0.75 s fails the lock outright.
5. **Strike accumulation** — 3 consecutive unsupported verification passes mark the lock
   unverified; any corroborated pass resets the count.

All thresholds from `TrackVerifier.Config` (`DAQPal/Tracking/TrackVerifier.swift`):
`corroborationIoU` 0.30 · `corroborationCenterFactor` 0.75 · `testimonyConfidence` 0.60 ·
`persistentTestimonyConfidence` 0.40 · `persistentTestimonyStability` 0.5 ·
`motionCouplingTolerance` 0.035 · `cornerAgreementFraction` 0.35 · `strikesToUnverified` 3 ·
`couplingMemoryMaxAge` 1.6 s.

**Weight derivation / calibration methodology — honest statement.** These thresholds were not
produced by a systematic calibration sweep. They were derived from measured live failures:
`testimonyConfidence` 0.60 sits above the 40–42% blurred re-proposals observed during bounce
(so blur cannot testify) and below the 71–74% genuine-overlap candidates;
`couplingMemoryMaxAge` 1.6 s exists so stale motion memories cannot misread slow travel. The
detection-side fusion weights (0.65 geometry/aspect/temporal) are documented initial values,
not tuned against labeled data. No confidence-weight calibration dataset exists.

**Hard vetoes.** `diverged` (confident candidate elsewhere, nothing corroborating nearby),
`transit` (overlapping witness whose motion is decoupled from the quad), and the stale-tracker
timeout. A veto forces lock validity to fail regardless of any aggregate score — no weighted
average can hide a catastrophic failure. Both `diverged` and `transit` are sticky until a
*coupled* corroborated pass clears them **[test]**
(`TrackVerifierTests.testDivergenceIsStickyUntilACorroboratedPassClearsIt`,
`testTransit_isStickyUntilCoupledCorroboration`).

**Verdict history** is logged by the DEBUG verdict trace in `ScreenLockPipeline` Stage 2b
(`subsystem == "daqpal"`); the trace — not screenshots — is the ground truth for whether the
veto engages, after screenshot sampling under-measured this state machine twice
(`ARCHITECTURE.md` §11).

---

## F. Fast-Motion Failure (the centerpiece)

### F.1 Original failure

Observed directly **[sim, screenshot]** under `-daqpal-demo-motion bounce`
(`ARCHITECTURE.md` §9): the Vision tracker lags the moving panel and then drifts off it
entirely **while continuing to report healthy confidence**. The UI stays LOCKED and keeps
displaying a value while the tracked quad sits over empty background; the detector meanwhile
correctly re-proposes the real panel at 94%. A data-integrity failure, not a performance one.

### F.2 Root cause

**Tracker self-consistency.** `VNTrackRectangleRequest` tracks whatever it is tracking —
including background — self-consistently, so its own confidence never falls after it detaches
from the physical display. Confidence defined as "the tracker says it is good" is therefore
structurally incapable of detecting this failure. The degraded/reacquisition thresholds were
never crossed because the only signal feeding them was the tracker itself. The fix has to be
*independent* geometric evidence with hard vetoes (plan Phase 7), which is what `TrackVerifier`
is.

### F.3 Three verifier versions — two live escapes

The corrective architecture was wrong twice, live, before it held. Each escape is encoded as a
permanent regression test.

**v1 — overlap corroboration + strikes.** A fresh detection overlapping the tracked quad
corroborates; a confident candidate elsewhere diverges; 3 unsupported passes unverify.
**Live escape 1 [screenshot, 2026-07-31]:** a quad drifted onto the panel's *bounce path* was
re-corroborated every ~1.5 s by the panel itself sweeping through it at 71–74% confidence,
while blurred re-proposals elsewhere (40–42%) sat below the 0.60 testimony bar — a dead lock
indefinitely re-blessed by its own victim passing by. The six-frame failure evidence
(`drift_evidence/bounce_t15/t19/t23/t27.png` at ~4 s spacing, `bounce_late_a/b.png` ~3 min in):
chip LOCKED in **all six frames**, quad pinned over empty background, FIELD 1 card live with a
LOCKED badge at 12.606/67.9% → 12.637/78.0% → 12.649/92.0% → 12.645/92.0% across t15–t27; in
`bounce_late_b.png` the card reads 11.973 while the panel shows 11.969 — OCR actively reading
the real panel through a geometrically false lock. DEGRADED/REACQUIRING never observed.
Lesson: **overlap is not attachment.**

**v2 — motion coupling, id-keyed.** Corroboration additionally requires the witness to move
with the quad; decoupled overlap becomes the `transit` hard veto. The transit check keyed on
the candidate id persisting across passes.
**Live escape 2:** detector id churn — fast motion gives the panel a fresh id nearly every
pass, so every sweep read as a first sighting and transit never fired; low
`temporalStability` also kept the persistence-testimony fallback dark.
Lesson: **detector id churn destroys id-keyed checks.**

**v3 — id-independent coupling (current).** Any witness overlapping the quad is claiming to be
our display, so its motion owes consistency with ours, whatever its id; a freshness bound
(`couplingMemoryMaxAge` 1.6 s) stops stale memories misreading slow travel.

### F.4 Regression tests

- `TrackVerifierTests` — 22 test methods (counted in file, 2026-08-02), including the two live
  escapes encoded directly: `testTransit_displaySweepingThroughParkedLock_isHardVeto`,
  `testCoupledMotion_lockRidingItsDisplay_staysCorroborated`,
  `testTransit_isStickyUntilCoupledCorroboration`,
  `testIDChurn_smallRelativeMotion_staysCorroborated`,
  `testIDChurn_sweepThroughStillTriggersTransit`, `testCouplingMemory_expiresAfterMaxAge`,
  plus determinism (`testSameSequenceTwiceYieldsSameVerdicts`) and testimony-threshold edges.
- `DriftRegressionTests` — 3 E2E tests on the real detector + tracker over rendered frames:
  `testFastMotionDriftInvalidatesMeasurementsThenRelocks` (lock → drift → invalidation on the
  **first drift frame** → organic relock at frame 95),
  `testSteadyLockKeepsMeasurementsValidForTenSeconds` (no over-aggressive veto),
  `testDetectorProposesTheSteadySyntheticPanel`.
- `CapturePerformanceTests` — 10 tests guarding the invalidation mechanism (§H).
  (`ARCHITECTURE.md` §11 cites "34 tests across" these three files; the per-file method counts
  above are what `grep -c "func test"` reports today.)

### F.5 Before / after evidence

| | Before (v1, live 2026-07-31) | After (v3, live 2026-08-01) |
|---|---|---|
| Evidence | six screenshots **[screenshot]** | 81-pass verdict trace **[trace]**, ~40 s continuous bounce |
| Chip while quad on background | LOCKED in 6/6 frames | LOCKED only during verified overlap windows |
| Verdicts | (not instrumented) | 58 corroborated / 23 transit |
| State at verification time | LOCKED (only) | LOCKED 8 · DEGRADED 6 · REACQUIRING 67 |
| **LOCKED-while-unverified** | every captured frame | **0 of 81 passes** |
| FIELD card | live values with LOCKED badge throughout | readings only in genuine overlap windows (read from the real panel) |

**Honest characterization.** The system does not *track* the bouncing panel —
`VisionScreenTracker` cannot follow super-frame-rate motion — it now *refuses to lie about
it*: mostly REACQUIRING, transient verified relocks during genuine overlap, transit vetoes as
the panel moves on. The plan's "tracking survives fast translation" boxes remain **open**;
what is closed is the false-healthy-lock data-integrity failure. Residual: the FIELD card may
display its last value up to `lockTimeout` (1 s) after invalidation — `measurementsValid`
stops new readings immediately; the staleness is cosmetic and bounded (`ARCHITECTURE.md` §11).

---

## G. OCR

**Engine.** Apple Vision, as `DualPassVisionOCR` (`.accurate` preferred + concurrent `.fast`
rescue) behind the `OCREngine` seam — kept as the hot path after a real conversion campaign
(`OCR_MODEL_COMPATIBILITY.md`, all attempts actually run): PARSeq → Core ML **failed**
(`aten::Int`, reproduced two ways); doctr CRNN converts only by bypassing its own `forward()`
and is rejected for decimals by construction (32 px input height, 4 px/timestep, feature height
collapsed to 1); PP-OCRv5 mobile converts (opset 7→17 + `onnxsim`, 1019→340 nodes; 8.37 MB
fp16, 100% argmax parity **[host]**) and is retained as an *ambiguity arbiter only* — never
per-frame — pending its reproducible ANE compile failure being checked on device; TrOCR and
Unlimited-OCR rejected. Structural finding: coremltools 9.0 has no ONNX front-end. All
challenger latencies are **[host M1 Pro]** figures and must not be read as iPhone numbers.

Dual-pass accuracy on the synthetic M9 benchmark **[sim/synthetic]**: seven-segment
14.6% → 41.7%, fourteen-segment 2.1% → 14.6%, overall 27.6% → 37.5%, sans unchanged 93.8%,
latency +12 ms (`PROGRESS.md`/`IMPLEMENTATION_NOTES.md`). Dot-matrix: 0% for every engine.

**Format-aware logic.** `FormatValidator` enforces the exact grammar of a configured
`DisplayFormat` (digit count, decimal position, sign, unit), with the spec's own valid/invalid
vectors encoded in `FormatValidatorTests` (`12..34`, `1A.34B`, `123.4567`, `12.34.7` rejected).
`.unconstrained` mode extracts any numeric token, anchored to ≥ 1 real pre-normalization digit.
`reading(from:)` carries a `DecimalAnalysis` (separator presence/position/certainty) and the
validator's own rejection reason through to confidence fusion.

**Decimal handling.**
- *Parser layer (wired):* separator structure validation, grouping-vs-decimal
  disambiguation, declared-position checks, `.ambiguousDecimal` veto —
  `DecimalIntegrityTests`, 25 tests, incl.
  `testDroppingTheSeparatorNeverPublishesTheShiftedValue` and
  `testVeryLowDecimalConfidenceVetoesAsAmbiguousDecimal`.
- *Image layer (`DecimalRescue`, built and tested, NOT wired):* model-independent separator
  detection on the canonical ROI (adaptive binarization, deterministic connected components,
  geometric classification). Measured on raster faces **[test]**: `"80.8"` → present,
  position 2, confidence 0.97; `"808"` → absent; survives blur to the top of the sweep,
  brightness to 0.1, noise to 0.7. A safety defect that shipped confident-absence at 0.82 by
  default (three reproduced silent-coercion cases: `.808`, `9.9`/`0.5`, any segment face) was
  fixed — confident absence must now be earned, and absence confidence is capped at 0.5
  because leading separators are structurally never examined. `DecimalRescueTests` 23/23.
  **Verified by grep on 2026-08-02: `DecimalRescue` still has zero call sites in the app
  target** — no live frame ever reaches it.
- *Device-measured failure mode* **[device]** (`OCR_DEVICE_BENCHMARK.md`, 72-case synthetic
  corpus, identical across 3 device runs + 1 Simulator run): decimal-preservation **90.3%**
  (65/72), power-of-ten errors **9.7%** (7/72), refusals **0**. All 7 failures are the label
  `.5` (7/8 variants): Vision transcribes the leading dot as a bullet-like glyph (`• 5`), the
  parser discards it, and `0.5` is emitted as `5` — silently. The load-bearing reading is
  "the leading-decimal case fails 87.5% of the time", not the headline 9.7%. The corpus is
  synthetic and easy; 90.3% must not be quoted as instrument accuracy.

**Temporal validation.** `TemporalFilter` (value-distance rolling-window scoring, score-only,
no value smoothing) plus `TemporalConsensus`, which gates the *published* reading: a single
dropped separator cannot flip a stable reading; migration requires sustained corroborated
evidence; alternating forms yield `.ambiguous` rather than an arbitrary pick; consensus never
synthesizes a reading — `TemporalConsensusTests`, 22 tests. Wired in `MeasurementProcessor`;
**the format prior is currently passed as `nil`** at the call site
(`MeasurementProcessor.swift:454`) — `DisplayFormatInference` is implemented and tested but
not fed live. End-to-end order-of-magnitude protection is asserted in
`GatingTests.testFlipFlop_neverPublishesBothOrdersOfMagnitude` **[test]**.

---

## H. Performance

Per the plan's rule, what exists is reported with provenance and everything else is stated as
UNMEASURED, without softening.

### Measured

**Mechanism-level regression tests [test, sim].**
- `CapturePerformanceTests` (10/10): a frame carrying an unchanged reading produces **zero**
  UI invalidations; **60 consecutive unchanged frames → zero invalidations** (previously one
  per frame); changed values still invalidate; debug text unpublished while hidden; steady
  cadence never republishes `processedFPS`. This is the deterministic guard against the root
  cause of the original selection lag (whole-screen invalidation at 12–30 Hz,
  `ARCHITECTURE.md` §2–§3).
- Measured invalidation counts against the unmodified code (60 frames/scenario): SEARCHING
  with varying confidence 60/60 → 1/60 after the fix; LOCKED identical (§9 table).
- `PipelineBudgetTests`: deliberately not wall-clock — asserts cost *mechanisms* (homography
  solves scale with targets not fields, override machinery creates no work for unknown
  devices, metrics recording is bounded). Its own header states no stage latency is measured
  there.

**Device drag cadence [device, DEBUG, iPhone 12 Pro Max @ 60 Hz native, mid-drag with the
capture pipeline running]** (`ARCHITECTURE.md` §9):

```
touch  : ticks 46 · p50 16.7 ms · p95 17.7 ms · max 17.9 ms · stalls 0
render : frames 63 · exp 16.7 ms · p50 16.7 ms · p95 16.7 ms · max 16.7 ms · dropped 0
```

Touch events arrive exactly once per display frame; **zero dropped frames**; identical with
the pipeline idle. Both probes measure cadence, not latency — the felt lag was latency, fixed
by replacing SwiftUI `DragGesture` with `UIPanGestureRecognizer` (user-confirmed smooth).

**Device OCR engine cost [device, DEBUG]** (`OCR_DEVICE_BENCHMARK.md`, engine call only,
n = 72/run): mean 41.8 / 52.2 / 47.5 ms across runs A/B/C (p50 41.5–56.7, p90 49.8–64.0,
max 64.7–71.5 ms). First `recognize()` in the process (engine load): **554.7 / 266.4 /
223.0 ms** — a 3.3× spread decreasing monotonically, consistent with OS caching; true
cold-boot cost **UNMEASURED**. The Simulator is ~10–12× slower for identical work
(mean 510.1 ms) and must never be quoted as phone latency.

### UNMEASURED — explicitly

- **Capture FPS: UNMEASURED.**
- **Tracking FPS: UNMEASURED** (cadence is configured per §D; achieved rate never measured).
- **Detection FPS: UNMEASURED.**
- **OCR FPS: UNMEASURED** (per-call engine latency above is not a pipeline rate).
- **UI FPS: UNMEASURED** as a before/after figure — no Instruments trace exists anywhere in
  the project; the only rendering-rate numbers are the drag-cadence probe above.
- **p95/p99 end-to-end pipeline latency: UNMEASURED.**
- **CPU utilization: UNMEASURED.**
- **GPU utilization: UNMEASURED.**
- **Memory usage / allocations per frame: UNMEASURED.**
- **Dropped-frame counts in the capture pipeline: UNMEASURED** (drop-late is enabled by
  construction; nothing counts the drops).
- **Release-build behavior: UNMEASURED** — every device figure above is Debug/`-Onone`.
- **Thermal behavior under sustained load: UNMEASURED** (benchmark sweeps are ~12 s).

`PipelineMetrics` (pull-based, ring-buffered, p95-reporting) exists precisely so measuring
does not perturb the measured, but no wall-clock stage figures have been captured with it and
published.

---

## I. Reliability

What the plan asks for versus what exists:

| Metric | Status |
|---|---|
| Tracking success rate | **UNMEASURED** |
| False-lock rate | **UNMEASURED** |
| **False healthy-lock rate** | **0 LOCKED-while-unverified in 81 verification passes** over ~40 s of continuous bounce **[trace, sim, synthetic rig only]** (`ARCHITECTURE.md` §11) |
| Reacquisition success rate | **UNMEASURED** (organic relock demonstrated once in E2E at frame 95 **[test]**, and transient live relocks observed during overlap windows — no rate exists) |
| Reacquisition latency | **UNMEASURED** |
| OCR accuracy (real instruments) | **UNMEASURED** — no real-DMM fixture exists; the two accuracy-harness tests skip by design rather than fabricate a number |
| OCR accuracy (synthetic) | 90.3% value accuracy on the 72-case synthetic corpus **[device]**; 93.8% sans / 41.7% seven-seg / 0% dot-matrix on the M9 benchmark **[sim/synthetic]** — synthetic corpora, not instrument accuracy |
| Decimal accuracy | 90.3% decimal preservation, 9.7% silent power-of-ten errors, 0 refusals, all failures the leading-decimal label **[device, synthetic corpus]** |

The single reliability claim this project can currently make with evidence is the one the
plan names most important: under the synthetic bounce scenario, the false-healthy-lock rate
measured **zero across the whole 81-pass trace**. That evidence comes from one scenario, one
rig (affine synthetic, Simulator), one run — it is the required failure mode holding where it
previously failed live, not a general reliability statistic. Everything else in this section
is honestly unmeasured until a ground-truth corpus and physical-device sessions exist.

---

## J. Known Limitations

From `ARCHITECTURE.md` §9/§10/§11, current as of this report:

**Tracking / geometry**
1. Fast motion is *survived truthfully*, not tracked: under continuous bounce the system spends
   most passes REACQUIRING (67/81 in the trace). The plan's fast-translation tracking boxes
   remain open.
2. Residual cosmetic staleness: the FIELD card can show its last value up to 1 s
   (`lockTimeout`) after invalidation; `measurementsValid` stops new readings immediately.
3. The synthetic rig is affine, not projective — yaw/pitch are foreshortening, not keystoning.
   Perspective normalization is validated against affine geometry only.
4. Six known open component defects (§9 table): detector anchor frozen at first detection;
   `ScreenFieldAnalyzer` rejects short readings with unknown unit words ("230 VAC" → no
   field); tracker recovery re-seed lacks proximity/identity gates; re-seed confidence
   blending can report `.lost`; magnet can re-grab a just-rejected display; detector-idle vs
   detector-empty grace conflation.
5. Overlay hit-testing uses the bounding box (~1.9× the quad's area at 30° roll), and the
   quad overlay has never been *seen running* live.

**OCR / decimals**
6. `DecimalRescue` has **zero call sites in the app target** (grep-verified 2026-08-02): the
   image-based rescue cannot affect any live reading yet.
7. Segment-face recall gap (measured): on true seven-segment faces connected components are
   segments, not digits — a clean DSEG7 `"80.8"` yields 21 components and no digit; rescue
   reports absence or presence-without-position, never a wrong position, but recall is real
   and this is the likely shape of a real temperature gun.
8. Leading separators are structurally never examined by rescue (absence confidence capped at
   0.5); the device benchmark shows the live pipeline emits `0.5` as `5` silently, 7/8
   variants, with zero `.ambiguousDecimal` refusals.
9. Decimal comma (`80,8`) unhandled by rescue; `TemporalConsensus` anchor creation needs only
   2 uncorroborated frames (startup coercion window) and `.ambiguous` can deadlock
   indefinitely; the format prior is not fed live (`formatPrior: nil`).
10. Dot-matrix displays: 0% with every integrated engine. Seven-segment: 41.7% (dual-pass,
    synthetic benchmark).

**Environment / validation**
11. Physical-device validation outstanding: real camera behavior, real-instrument OCR
    accuracy, thermals — the Simulator structurally cannot cover these; no real `dmm_001.mov`
    fixture exists.
12. The Simulator starves gestures (6–7 callbacks at 115–180 ms, worst 301 ms) via its
    preview-conversion path; the device never pays this. Not a shipping bug, but it makes the
    Simulator misleading for interaction work.
13. No Instruments profile exists; every performance claim is mechanism-level or from the
    specific device probes in §H.
14. Two AVAssetWriter video tests are parallel-clone flaky (pass serially; retry-first
    policy); two accuracy-harness tests skip pending a real fixture.
15. The 81-pass trace is the only verdict-level evidence; per-pass detector confidences and
    the runtime value of `measurementsValid` in the earlier failure screenshots were inferred
    from overlays, not read from instrumentation.

---

## K. Remaining Work

Ordered by the plan's priority ladder.

### 1. Correctness
- Close the six §9 component defects — the recovery re-seed identity gate first (a lock that
  can silently migrate to unrelated geometry is the same class of failure `TrackVerifier`
  exists to stop, one layer down).
- Physical-device tracking session: the verifier has only ever been proven against the affine
  synthetic rig; real perspective, glare, and handheld motion are unvalidated.
- Extend Build Gate 8's motion matrix (yaw/pitch/roll/zoom/occlusion/glare) with per-scenario
  trace evidence; only bounce and steady have traces today.
- Fix overlay hit-testing (bounding box vs drawn quad) and verify the quad overlay live.

### 2. Data integrity
- **Wire `DecimalRescue` into `MeasurementProcessor`** — it is the only layer that can catch
  a separator lost before the recognizer, and it currently runs never.
- Feed `DisplayFormatInference` output as `TemporalConsensus`'s format prior (currently
  `nil`); the device benchmark shows a prior would have caught all 7 `.5` failures.
- Widen the parser's separator-evidence vocabulary (bullet-like glyph in separator position →
  `.ambiguousDecimal`, not silent discard) — measured, reproducible, parser-only fix.
- Close the segment-face rescue gap via component→digit-cell grouping by x-pitch (the job
  `DigitSegmenter`/`SevenSegmentSampler` already do), then extend detection left of the first
  digit to lift the 0.5 absence-confidence cap.
- Harden `TemporalConsensus` anchor creation (2 uncorroborated frames) and the `.ambiguous`
  deadlock; handle decimal comma.

### 3. Reliability
- Record the real-instrument fixture (`dmm_001.mov` + ground-truth CSV) and unskip the
  harness — the prerequisite for every real accuracy and reliability number in §I.
- Build the ground-truth tracking corpus (plan §21) and measure tracking success rate,
  false-lock rate, reacquisition success/latency, and false-healthy-lock rate beyond the
  single bounce trace.
- Make the tracker actually survive fast translation (motion-predicted local reacquisition;
  the current system only refuses to lie about it).

### 4. Performance
- Instruments profile on device: FPS, CPU, GPU, memory — none exist. Replace §H's UNMEASURED
  list with figures, Release configuration included.
- Populate `PipelineMetrics` stage latencies (p50/p95) on device and set the plan §4 budgets
  from measurement.
- Warm-up `recognize()` at capture-screen appearance (measured 156–508 ms first-call penalty).

### 5. Energy
- Entirely unmeasured. Measure energy impact of the 0.5 s locked revalidation cadence and the
  0.1 s recovery cadence before tuning either; verify the PP-OCRv5 ANE compile failure on
  device before ever enabling it as an arbiter.

### 6. Complexity
- Retire the superseded diagnoses recorded in `ARCHITECTURE.md` §9 into a defect-history
  appendix once their regression tests are the only remaining artifact.
- Reconcile `ScreenFieldAnalyzer.numberPattern` with `FormatValidator`'s token grammar (two
  definitions of "numeric token" now disagree).
- Unify the §9 documented-but-stale cadence figures (0.2/2.0/0.1 s) with the shipped 0.5 s
  locked interval — the code comment is currently the only accurate record.
