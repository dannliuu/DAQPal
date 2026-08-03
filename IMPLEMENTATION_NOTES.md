# DAQPal — Implementation Notes

Product name: **DAQPal** (definitive). Source documents:

- `Design_notes/design_handoff_daqpal_ios/Visual_Instrument_Data_Logger_Agent_Development_Specification.md` — technical/architecture authority.
- `Design_notes/design_handoff_daqpal_ios/README.md` — UI/UX authority (Fluke-yellow design handoff; the interactive prototype is `DAQPal App.dc.html`).
- Root `README.md` — product overview (no UI spec).

## Repository state found (2026-07-22, before implementation)

- Fresh Xcode 26.6 SwiftUI + SwiftData template: `DAQPal.xcodeproj`, app target `DAQPal`,
  test targets `DAQPalTests` / `DAQPalUITests`. Template `Item.swift` / `ContentView.swift`
  boilerplate only — no product code, no tests, no UI. Uses filesystem-synchronized groups
  (files on disk are picked up automatically; no pbxproj editing needed per file).
- Deployment target was iOS **26.5**; bundle id `danieliu.DAQPal`.
- No CLAUDE.md, no CI.

## Legacy naming audit

- **No `InstruLog` identifiers exist anywhere in code or project files.** The scaffold was
  already named DAQPal.
- The Development Specification's §26/§37/§40 examples use `InstrumentLogger` as project and
  module name. That is legacy **documentation-only** naming; the implementation maps it 1:1 to
  `DAQPal` (e.g. `InstrumentLoggerApp.swift` → `DAQPalApp.swift`, `InstrumentLoggerTests` →
  `DAQPalTests`). The historical documents themselves are intentionally left unmodified.
- CSV export filename is `daqpal_session.csv` (never `instrulog_session.csv`).

## Project-level decisions (and why)

1. **Deployment target lowered 26.5 → 17.0** per the iOS 17+ requirement. Built with the
   iOS 26 SDK; all APIs used are ≤ iOS 17.
2. **`SWIFT_DEFAULT_ACTOR_ISOLATION` changed `MainActor` → `nonisolated`** (Swift 5 language
   mode, approachable-concurrency flags kept). The spec's concurrency design (§40.2) uses
   explicit `@MainActor` on UI state plus a background `actor` pipeline; the traditional
   default keeps that model exactly as specified.
3. **Concurrency strategy** (spec §40.3 caveat): `TimestampedFrame` is `@unchecked Sendable`
   with a documented linear-ownership argument — each `CVPixelBuffer` is handed from producer
   to exactly one pipeline consumer and never mutated/shared after handoff. Nothing off-main
   touches `AppState`; the pipeline returns `FrameResult` values and hops to `MainActor`.
   Backpressure = `alwaysDiscardsLateVideoFrames` + serial `await` consumption (busy pipeline
   ⇒ frames dropped, never queued).
4. **Portrait-only (iPhone) + rotated capture buffers.** The video data output connection is
   set to `videoRotationAngle = 90` so buffers arrive upright. Consequence: normalized ROI
   space == buffer space == preview space (modulo aspect-fill, handled by the pure-math
   `AspectFillMapper`, which is unit-tested). This removes the classic
   buffer-vs-preview-coordinate bug class for the MVP; free-rotation support is future work.
5. **Camera usage description** added via `INFOPLIST_KEY_NSCameraUsageDescription`
   (generated Info.plist).

## Scope decisions within the MVP

- **Recognition path**: whole-ROI Vision OCR (`VNRecognizeTextRequest`) is the primary value
  source. The digit-level path (`DigitSegmenter` fixed-pitch cells + per-cell Vision digit
  recognition with per-digit confidence) is implemented as the architecture stub the spec
  requires, unit-tested, and switchable on the processor — but it is *not* claimed to be
  seven-segment recognition. Real display geometry / segment recognition is Milestone 11+.
- **DigitSegmenter assumption (documented per spec)**: fixed-width digit positions, equal
  pitch across the ROI. Real display geometry and seven-segment segmentation come later.
- **"Locked" semantics**: the handoff defines lock as ROI∩display ≥ 60%, which requires
  display *detection* (post-MVP). MVP substitute: a device is **locked while the pipeline is
  producing format-valid accepted readings** (last accepted ≤ 1 s ago). Same UI states
  (yellow solid vs orange dashed "SEARCHING"), honest semantics for what the MVP can know.
- **CSV schema (both authorities preserved)**: single-device sessions use the spec §25 schema
  `timestamp,value,unit,confidence,accepted,rejection_reason`; multi-device sessions use the
  handoff's one-column-set-per-device schema
  `timestamp_s,dmm1_value_V,dmm1_confidence,dmm1_valid,…`. Rejected samples are always
  logged (`valid=0` / `accepted=false`), never silently deleted.
- **Sampling model**: one processed frame → one sample row (all devices read on the same
  frame), i.e. OCR-rate-driven sampling per the handoff. Camera FPS ≠ OCR rate ≠ measurement
  rate is preserved and surfaced in the footer meta (measured rates, not the prototype's
  hard-coded "CAM 240 FPS").
- **Format sheet UI vs model**: the sheet exposes the handoff's controls (digits 4/5/6,
  decimal position clamped 1…digits−1, sign, unit V/A/Ω/°C/Hz, ±range). The underlying
  `DisplayFormat` model is more general (`decimalPosition: Int?`, nil = integer display) per
  the spec; the UI simply doesn't expose integer displays yet.
- **Typography**: Archivo is not bundled; the handoff explicitly allows substituting a close
  grotesque — the MVP uses the system font (SF Pro) + SF Mono for numerics. Bundling Archivo
  is a cosmetic follow-up.
- **Simulator/testing honesty**: the Simulator has no camera. `SyntheticFrameSource` renders
  clearly-synthetic DMM-style frames so the full pipeline is exercisable end-to-end in the
  Simulator and in automated tests; fixture-driven tests (`dmm_001.mov` + ground-truth CSV)
  are scaffolded and **skip** when no real fixture is present. No fabricated accuracy claims:
  real-DMM accuracy validation requires a physical iPhone pointed at a physical instrument.
- Deferred (per spec §37): instrument profiles, PP-OCRv6/ONNX, seven-segment models,
  automatic format inference ("Detect from OCR" prefill), display detection/ROI tracking,
  high-speed capture, Android, backend.

## Architecture (as built)

```
CaptureStack (owns lifecycle)
  ├─ CameraPermissionManager → CameraManager (AVCaptureSession, portrait buffers)
  │      └─ LiveCameraFrameSource : FrameSource      (device)
  │         SyntheticFrameSource  : FrameSource      (Simulator demo)
  │         FixtureFrameSource    : FrameSource      (tests, .mov via AVAssetReader)
  └─ FrameProcessor — consumes frames serially
         └─ MeasurementProcessor (actor)
              per device: ROI crop → OCRManager(VisionOCR) [digit path stub available]
                          → FormatValidator → PhysicalValidator → TemporalFilter
                          → ConfidenceEngine → Measurement
         → FrameResult → MainActor → AppState.apply → SwiftUI
Recording: AppState.startRecording → RecordingSession (append-only, keeps rejected)
         → stop → CompletedSession → ResultsView (Swift Charts) → CSVExporter → ShareLink
```

## Validation environments

- **Simulator**: UI, ROI interaction, format sheet, recording flow, results, CSV export,
  synthetic + fixture pipeline tests, unit tests.
- **Physical iPhone (required, not yet performed)**: camera permission prompt, live preview
  orientation, real-DMM OCR quality, lighting/glare/motion behavior. Camera capture cannot
  be validated in the Simulator.

## Status log

- ✅ Phase 1 (inspection) — this document.
- ✅ Project settings corrected; SwiftData template removed; shared contract layer
  (models, `AppState`, `FrameSource`, `AspectFillMapper`, `Theme`) written.
- ✅ Module implementation complete (camera / pipeline / capture UI / results UI / tests):
  40 source files + 10 test files, written by parallel agents against the frozen contracts.
- ✅ Integration build green on first attempt (2026-07-23); unit tests 113 passed / 0
  failed / 2 fixture-skips (see PROGRESS.md gates).
- ✅ Adversarial review round (architecture/scalability · correctness · UI fidelity, each
  finding independently verified): 7 confirmed findings fixed —
  (1) results chart now renders a decimated, cached `ResultsSessionModel` (min/max
  binning, ≤300 bins/device) built off-main once per session instead of one mark per raw
  sample; summary counts and per-device stats come from the same single pass;
  (2) CSV export builds detached off the MainActor;
  (3) `MeasurementProcessor.process` fans per-device recognition out concurrently
  (pure/static stage) and keeps validator mutation in the synchronous actor stretch; the
  whole-ROI path now passes the ROI as Vision's `regionOfInterest` over the shared frame
  instead of physically cropping per device;
  (4) `addDevice()` names monotonically past the highest existing DMM-n so removals can't
  produce duplicate CSV column prefixes;
  (5) `syncProcessorConfig()` coalesces bursts (skip no-op pushes, cancel-and-replace) so
  ROI drags don't queue a config push per gesture tick;
  (6) format-sheet stepper hit targets raised to ≥44 pt;
  (7) "DC" suffix only for V/A units + SEARCHING devices show zero confidence everywhere.
  Suite re-passes 113 / 0 / 2 after the fixes; the synthetic end-to-end tests now exercise
  the concurrent stage and the `regionOfInterest` path.
  Noted for the roadmap (not fixed): unbounded in-memory `RecordingSession` growth with no
  incremental persistence (crash loses the session) — pairs with the fixture/persistence
  roadmap items in PROGRESS.md.
- ✅ Field-report fix round (2026-07-23), reproduced via new DEBUG launch hooks
  (`DebugDemo.swift`: `-daqpal-auto-roi`, `-daqpal-auto-record N`, `-daqpal-demo-results`)
  and Simulator screenshots:
  (1) `TemporalFilter` redesigned from per-digit agreement to **value-distance scoring**
  (deviation from window median vs. display-resolution floor and window volatility) —
  digit agreement rejected good readings at decade rollovers (12.498 → 12.503 changes 3
  digit positions); regression test added, ramp now passes with 0 rejections;
  (2) `VisionOCR` switched `.fast` → `.accurate` — `.fast` reports ~0.3 quantized
  confidence on clean digits, which dominated the fused score (UI showed 32% while
  LOCKED); `.accurate` yields calibrated 0.6–0.9 values at MVP rates;
  (3) header chips no longer truncate (natural-width chips in a scrollable row).
- ✅ Video import (Milestone 12 first slice, 2026-07-23): `Import/VideoImportModel.swift`
  (`TimeScalingFrameSource` normalizes slow-motion playback timestamps to real capture
  time by a user-chosen factor — 1×, ¼×/120 fps, ⅛×/240 fps; files with nominal fps ≥ 100
  flagged as already real-time), `UI/VideoImportView.swift` (file picker → first-frame ROI
  placement → speed selection → progress → results), header IMPORT chip (disabled while
  recording; results cover re-asserted after the import cover dismisses since SwiftUI
  drops a present-while-presenting). Import runs a **fresh** `MeasurementProcessor` and
  never touches the live camera pipeline. `VideoImportTests` proves the chain end-to-end
  with an in-test H.264 fixture (½× → value accepted, timeline halved). Suite: 116/0/2.
- ✅ Reliability round from real-device field testing (2026-07-23). Root cause of
  "rejects everything": the default format asserted the spec's example grammar
  (±XX.XXX V, −20…+20) against arbitrary real displays. Changes:
  (1) **Lenient dimensionless default** — `DisplayFormat.unconstrained` (unit nil, no
  range, `constrainToFormat=false`) is the new-device default; recognition extracts any
  numeric token (digits/decimal/attached sign, confusable-repaired, anchored to ≥1 real
  pre-normalization digit so "HOLD"→"H0LD" can't mint a fake 0). Strict grammar (Mode 2)
  is opt-in via a CONSTRAIN toggle in the format sheet; unit row gained a "—" none
  option; range steppers support nil bounds.
  (2) **Header wordmark removed** per user request — chips get the full width.
  (3) **ROI drag lag fixed** — gestures update view-local state only, committing to
  AppState once on gesture end.
  (4) **ROI auto-tracking** (spec §15 minimal form) — accepted readings report their
  text's full-frame bounding box (`FrameResult.observedROIs`, from Vision observation
  boxes converted out of ROI-relative bottom-left space); `AppState` nudges the window
  toward the observed center — damped (gain 0.3), dead-banded (0.004), step-clamped
  (0.02/frame), size-preserving, paused while `isEditingROI`. Keeps lock under handheld
  shake; cannot re-acquire a fully lost display (needs display detection, post-MVP).
  Suite: 129 / 0 / 2. Known tradeoffs: unconstrained mode has no range ⇒ physical
  gates inactive until configured; `isEditingROI` is global, so dragging one window
  pauses tracking for all devices during the gesture.
- ✅ Session video recording (2026-07-23): REC now optionally tees every capture frame
  into an `AVAssetWriter` (`SessionVideoRecorder`, H.264 `.mov`, lazy writer sized from
  the first frame, session started at its timestamp so the movie timeline aligns with the
  CSV clock) via a `frameTap` on `LiveCameraFrameSource`'s delegate path — **upstream of
  the OCR stream's drop-late backpressure**, so the movie gets every captured frame even
  when recognition falls behind. Off by default behind the footer "🎥 SAVE" toggle
  (storage/battery cost is an explicit choice). On STOP the file saves to Photos under
  **add-only** authorization and the temp file is deleted; results screen shows
  saving/saved/failed status. The Simulator synthetic path is teed too, so the feature is
  end-to-end verifiable without hardware (proven: recorded synthetic session →
  "🎥 IN PHOTOS" chip with `simctl privacy grant photos-add`).
  **TCC lesson (crash found & fixed in Simulator verification):** the planned "DAQPal"
  album targeting was removed — fetching/creating a named album is a library READ
  requiring full `NSPhotoLibraryUsageDescription`/`.readWrite`; attempting it under
  add-only aborts the app with a TCC privacy violation. Videos land in Recents; an album
  needs the heavier permission and is deliberately deferred. Also fixed: footer layout
  squeeze (STOP button wrapped into a vertical letter stack once the toggle chip joined
  the row — record button now has `fixedSize` + layout priority). Saved sessions double
  as re-processable IMPORT fixtures and future `dmm_001.mov` ground-truth material
  (spec §30–31). Suite: 132 / 0 / 2.
- ✅ OCR enhancement Phases 0–1 (2026-07-23, per OCR_RESEARCH.md): DSEG 7/14-segment
  fonts bundled (OFL-1.1 + license); `SyntheticDisplayGenerator` (test target: 4 glyph
  styles incl. programmatic 5×7 dot-matrix, deterministic seeded augmentation per display
  tech); `RecognitionBenchmark` + `OCRBenchmarkTests` (Milestone 9 harness — first
  MEASURED numbers recorded in OCR_RESEARCH.md: Vision .accurate 93.8% sans vs 14.6%
  seven-seg vs 0% dot-matrix; .fast beats .accurate on segment glyphs at 1/35th latency);
  `TrainingDataHarvester` (validation-gated pseudo-label crops + labels.csv);
  `SevenSegmentSampler` (deterministic classical reader, 10/10 clean digits both
  polarities — Phase 4 fusion pending). Phase 0 spike ran for real (rapidocr/PP-OCRv3):
  ~12% on DSEG vs 38% sans control ⇒ the stock-model bridge is dead; go straight to
  trained models. Bug found & fixed during integration: the generator double-flipped its
  buffers (base context flip + a second flip in the buffer blit) — caught because the
  segment sampler decoded '2' as '5' (exact vertical-mirror patterns), confirmed by a
  raw-row ASCII dump, fixed by removing the second flip. Note: the two AVAssetWriter
  video tests can flake under parallel test clones (VideoToolbox contention) — they pass
  serially; treat parallel-run failures of exactly those two as retry-first.
  Suite: 162 / 0 / 2 (+ the 89 s benchmark suite, run on demand).
- ✅ Training-free OCR round + consistency round (2026-07-23, both recovered from a
  mid-run usage-limit interruption via workflow resume; the "unbuildable" state was one
  missing `import Vision`):
  (1) **Dual-pass engine shipped** — `OCRManager` defaults to `DualPassVisionOCR`
  (.accurate preferred + concurrent .fast rescue). MEASURED on the M9 benchmark:
  seven-segment 14.6%→41.7%, fourteen-segment 2.1%→14.6%, overall 27.6%→37.5%, sans
  unchanged 93.8%, latency +12 ms. (2) **Sampler fusion shipped** — classical
  seven-segment cross-check in `ConfidenceEngine` (`CrossCheckOutcome`): confident
  disagreement rejects as AMBIGUOUS_DIGIT, weak disagreement depresses confidence,
  abstains on unconstrained formats/non-segment glyphs/negative readings (fixed-pitch
  segmenter consumes the sign cell — documented limit). (3) **User-reported UX fixes** —
  visible per-card ✕ device removal (+ data-loss guard: removal now blocked mid-recording,
  since a removed device's captured samples vanished from the finished session);
  natural value formatting for unconstrained devices ("230", not "230.000" — UI and CSV);
  video import no longer auto-opens the picker (explicit CHOOSE VIDEO FILE landing;
  cancel returns there). (4) **Consistency audit** (3 scanners + adversarial verify:
  10 confirmed / 9 refuted): import-ROI drag-lag regression fixed (buffered gestures);
  emoji chips → monochrome text glyphs per the handoff's icon rule; single wordmark
  tracking token; unified hit-target insets (−15), outlined-chip borders (heavyRule),
  missing-unit convention (omit), disabled-chip dimming, toggle a11y grammar; one naming
  scheme for unconstrained mode ("Any number — unconstrained" / "ANY" — "Mode 3"/"free
  numeric" jargon removed from UI); DONE button no longer claims "CONSTRAINED" in ANY
  mode; "+ ADD" dims at the cap instead of vanishing. Suite: 190 effective passes / 0
  real failures / 2 fixture-skips (the two AVAssetWriter tests remain parallel-clone
  flaky — pass serially, retry-first policy stands). Benchmark suite: 3 engines, 165 s,
  run on demand.
- ✅ Arbitrary digit counts (2026-07-23): the format sheet's DIGITS control is now a
  −/+ stepper clamped to `DisplayFormat.digitCountRange` (1…12 — a UI bound only; the
  model/validator/segmenter are count-agnostic) instead of the handoff prototype's
  segmented 4/5/6. The DECIMAL AFTER DIGIT row now also exposes the model's
  integer-display mode (`decimalPosition = nil`) via the "—" convention ("−" below
  position 1 → integer; digits == 1 forces it). Pattern preview scales down for wide
  patterns. 14 new tests across 1-digit/10-4/12-11/integer layouts. Suite: 202 effective
  passes / 0 real failures / 2 fixture-skips.
- ✅ ROI drag-lag root cause + dynamic demo motion (2026-07-25):
  (1) **Drag/resize lag fixed at its actual source.** The gesture code already
  committed on `.onEnded` only — the lag was frame-rate view invalidation starving the
  main thread: `CameraCaptureScreen.body` read `liveReadings` (alignment hint),
  `debugText`, and the Simulator's `@Observable UIImage` preview, so the *whole screen*
  re-evaluated 12×/s while a 1080×1920 `Image(uiImage:)` was rebuilt every frame.
  Fixes: preview frames now flow through a non-observed `PreviewFrameRelay` straight
  into a `CALayer.contents` (UIViewRepresentable; zero SwiftUI diffing per frame; a
  one-shot `hasPreviewFrame` Bool handles the placeholder switch); the two per-frame
  captions moved into leaf views (`DebugCaptionView`, `AlignmentHintView`) so their
  reads invalidate only themselves; every observable write in `AppState.apply()` is now
  change-gated (`LiveReading` equality skip, `debugText` only while the overlay is
  shown, `processedFPS` published only when its rounded display value changes, raw rate
  kept in an `@ObservationIgnored` var); the locked-glow `.shadow` (a per-tick blur
  pass) is suppressed while a gesture is active.
  (2) **Demo motion rig** (`DemoMotion.swift`): the synthetic display now supports
  STEADY / YAW / PITCH / ROLL / TUMBLE / BOUNCE, cycled by tapping the SYNTHETIC chip
  or set at launch via `-daqpal-demo-motion <mode>`. Deterministic `DemoMotionModel`
  (pure function of elapsed time + integrated bounce state; no randomness): yaw/pitch
  are affine foreshortening (cos of a ±55° oscillation — CoreGraphics has no
  perspective), roll stays within ±10° (Vision's practical text-rotation tolerance),
  bounce is the classic DVD constant-velocity reflection kept just under the ROI
  tracker's max follow speed (0.24 norm/s), with glide-home on mode exit.
  `SyntheticDisplayRenderer.render(text:pose:)` — the identity pose is drawing-op
  identical to the old renderer (existing tests/fixtures unaffected);
  `panelROI(for:)` provides ground truth for tracking tests. Verified in Simulator:
  LOCKED holds through yaw (squeezed digits, 63.6%) and roll (65.6%); bounce
  demonstrates the honest tracking limit — when the panel fully exits the window, OCR
  stops accepting, so tracking stalls until the panel re-enters and is re-acquired
  (tracking only nudges on accepted readings, by design).
- ✅ Intelligent screen-locking layer, Round 1 — BUILT, NOT WIRED (2026-07-27, per
  `intelligent_screen_selection_tracking_ocr_spec.md`; see `ARCHITECTURE.md` for the full
  structural reference):
  (1) **Frozen contract layer** (authored directly, not delegated — it determines whether the
  rest scales): `ScreenQuad` + `Homography` (four-corner geometry, DLT solve with partial
  pivoting, returns nil rather than garbage on singular input), `SnapState`/`SnapTuning`
  (explicit hysteresis gaps, thresholds in normalized frame units so they are
  resolution-independent by construction), `TrackedTarget`, `ScreenField`/`ScreenFieldCatalog`,
  `PipelineMetrics` (pull-based, ring-buffered — metrics must never push at frame rate).
  The load-bearing decision: **field regions live only in canonical space** and are projected
  through the target's live homography, so they stay glued to the same physical part of a
  display through motion with no per-field tracking.
  (2) **Components delivered**: `ScreenCandidateDetector` (Vision rectangles as the non-OCR
  primary signal + text/numeric density, weighted fusion), `MagneticSnapEngine`,
  `VisionScreenTracker` + `DampedQuadTracker`, `PerspectiveNormalizer`, `ScreenFieldAnalyzer`,
  `PipelineDebugOverlay`/`TargetGeometryOverlay`.
  (3) **NOT WIRED.** Grep-verified: outside their own files and tests, the only references are
  the protocol declarations. None of this has run against a live frame stream, and no claim
  about its real-world reliability is made anywhere. Remaining: cadence scheduler, routing
  `MeasurementProcessor` through tracked geometry, field-selection UI. Six known open defects
  are tabulated in `ARCHITECTURE.md` §9.
  (4) **Process note.** Adversarial review found 37 defects (4 critical) — including two that
  would have made the feature non-functional: the snap engine treated "detector idle this
  frame" as "nothing here", making locks unreachable at any realistic detection cadence; and
  the tracker's entire smoothing/confidence policy lived in a class referenced by nothing but
  its own tests, while the shipped path forwarded raw Vision confidence into thresholds
  calibrated for a different scale. The fix round closed 35 but opened 22 new findings — that
  non-converging ratio is why Round 1 stopped there rather than running a third pass.
  Notably the coordinate-space conversions everyone suspected were all correct; one agent
  correctly rejected an instruction in my own brief that would have mirrored every field
  coordinate.
- ✅ Selection-lag root cause + fix, MEASURED (2026-07-27): cause was frame-rate invalidation of
  the whole capture screen (root `body` read `liveReadings`/`debugText`/the Simulator preview
  image, all written per frame). Fixes: preview → `CALayer` via a non-observed relay, per-frame
  reads pushed into leaf views, every observable write change-gated, glow shadow suppressed
  mid-gesture. **The first version of this fix was inert**: `LiveReading.lastTimestamp` was
  written every frame and read by nothing, so the equality gate suppressed zero invalidations —
  caught by `CapturePerformanceTests`, not by inspection. Field removed. 10 regression tests
  assert zero UI invalidations across 60 unchanged frames. No FPS/CPU claim is made: the
  diagnosis was observation-graph analysis, not an Instruments profile.
## ⬜ Generalizing beyond one display: ML survey and the recommended hybrid (2026-08-02)

**Challenge raised:** the instrument profile below only covers the display it was
calibrated on. Correct. This section is the research answer.

### The problem splits in two, and they need different tools

Conflating them is why "just use an ML model" is the wrong shape of answer:

| | Problem | Nature |
|---|---|---|
| **A** | Read the segment digits **and the decimal point** | Recognition |
| **B** | Know which number is the *main* reading and which is `MAX` | Semantics / role assignment |

### A — reading: ML is NOT clearly better than what is already built

Apple Vision is a documented weak reader of seven-segment glyphs (Apple's own
developer forums carry unresolved reports; this project measured it at 14.6%,
improved to 41.7% by the dual-pass engine). So a trained recognizer is
*plausible*:

- `MiXaiLL76/7SEG_OCR` (HF, MIT): **3,333 synthetic images, 202 MB**, labels
  2–6 chars. Verified via the HF API. **Synthetic-only, and decimal-point
  coverage is unconfirmed** — precisely the property that matters most here.
- Public real-world sets exist but are small and domain-specific (YUVA EB energy
  meters ≈119 images; glucose/BP-monitor sets).

Against that, the repo already contains `SevenSegmentSampler`: a deterministic,
ML-free seven-segment reader with per-segment margin confidence, calibrated
against bundled DSEG7 glyphs, handling polarity and ink-box registration. For a
*fixed glyph family* it is competitive with a small trained model, needs **zero
training data**, is fully deterministic (no fabricated confidence), and already
ships. The user has also explicitly deferred training for lack of datasets.

**Conclusion:** keep the classical reader for the hot path. The gap is the
decimal point, which is an *8th segment sample*, not a model problem.

### B — role assignment: ML is also not the best tool, and this is the surprise

Candidate VLMs, assessed against this project's deployment constraints:

| Model | Size | Verdict for DAQPal |
|---|---|---|
| Florence-2 | 0.23B / 0.77B | Genuinely capable at region+caption tasks. **No evidence of a working Core ML conversion**; this repo already measured that coremltools 9.0 removed the ONNX front-end, so every path routes through PyTorch tracing. |
| Moondream | 0.5B / 2B | Explicitly targets edge; int4/int8 quantization available. Same conversion risk; 0.5B is still ~100× the compute of the current hot path. |
| SmolVLM | ~0.25–2B | Designed for constrained/browser use. Same conversion question. |
| LayoutLM family | — | Built for *documents*: consumes text + bounding boxes, so it sits **on top of** OCR and cannot fix the reading problem. Also assumes document layout priors that instrument displays violate. |

Even in the best case a VLM is a **seconds-scale, occasional** pass, never a
per-frame reader. That is a real option for *semantic labelling* — but before
reaching for it, note that the role signal is available almost for free:

1. **Relative glyph height.** The primary reading is conventionally the largest
   element on an instrument display. Measured on the sample device: primary ≈2×
   the secondary's glyph height. Generalizes across instruments far better than
   any position rule. (Caveat found in the same photo: the *fractional* digit of
   the primary is rendered shorter than its integer digits, so rank fields by
   their **tallest** glyph, never their mean.)
2. **Annunciator text.** `MAX` is printed beside the secondary in a normal
   typeface — which Vision reads *well*, unlike the segment digits. The repo's
   `ScreenFieldAnalyzer` already performs label→field association. Same for
   `MIN`, `AVG`, `HOLD`, `°F`/`°C`.
3. **Temporal behaviour — the strongest signal, and it needs no ML at all.**
   A `MAX` field is **monotonic non-decreasing** while the trigger is held and
   resets between pulls; the live reading fluctuates in both directions. Over a
   few seconds these are trivially separable. This generalizes to `MIN`
   (monotonic non-increasing), `HOLD` (frozen while the live value moves), and
   `AVG` (variance strictly lower than the live field). No calibration, no
   training, no per-device work — it is a *behavioural fingerprint* of the role
   itself.

Signal 3 is the direct answer to "dynamically categorize and lock onto the
correct variables", and the app is already structured to exploit it: it has
per-field time series (`RecordingSession`), and `TemporalConsensus` already
reasons about value evolution.

### Recommended architecture: auto-calibration, not manual profiles

The profile is not wasted — it stops being a *manual input* and becomes a
*cached derivation*:

```text
DISCOVER  (seconds, once per new display)
    canonical warp -> field detection -> for each numeric field:
      glyph height rank | adjacent annunciator text | temporal behaviour
    -> assign roles (.primary / .max / .min / .hold)
    -> infer digit grammar + decimal position from stable history
         ↓
CACHE     InstrumentProfile keyed by display fingerprint
            (aspect ratio, field geometry, annunciator set)
         ↓
EXPLOIT   fixed-position sampling every frame
            SevenSegmentSampler per cell + DP patch  (fast, deterministic)
         ↓
RE-VERIFY periodically re-run DISCOVER cheaply; drift or mismatch
          invalidates the profile rather than silently mis-reading
```

This gives generality (works on an unseen instrument without user setup), speed
(steady state is fixed sampling, not per-frame inference), and the project's
existing safety posture (a mismatch invalidates rather than guesses).

**Where a VLM would still earn its place:** one-shot semantic bootstrap on an
unfamiliar display — "which of these regions is the primary temperature?" — run
once at DISCOVER time, off the hot path, with the classical pipeline as the
fallback when it is unavailable. That is an optional accelerator, not a
dependency, and it should not be attempted until the conversion question above
is settled with a real measurement.

### Honest limits of the non-ML route

- Temporal role inference needs the user to actually pull the trigger; on a
  static display the `MAX` and live fields may be indistinguishable until they
  diverge. Height + annunciator text carry it until then.
- Height ranking fails on displays where two readings share a size (some
  multi-channel meters). Annunciator text and temporal behaviour cover that.
- None of this is validated on hardware other than the one photographed.

---

## ⬜ NEXT: instrument profile for the target device — REVISED after seeing the hardware (2026-08-02)

**A photograph of the actual instrument (`IMG_6888.HEIC`, an IR temperature gun)
changes the recommendation.** The generic design below it was written blind; this
section supersedes its conclusion, though the component analysis in it remains
accurate.

### What the photograph settles

The display reads `90.0` large, with `92.7` smaller and lower-right beside a
`MAX` legend. Observed:

1. **It is a fixed-segment LCD** — seven-segment glyphs, dark on a grey-green
   background. Confirms segment-face handling is required, not optional.
2. **There are two numeric fields**, and the primary is roughly **twice the glyph
   height** of the secondary. They are at fixed, non-overlapping positions.
3. **The decimal point is a large square block at the baseline**, not a small
   dot — comparable in size to a segment. It is *not* being lost to thresholding
   or resampling; it is being lost by the text recognizer, which reads three
   digits and discards it (`900`).
4. **The fractional digit is rendered smaller than the integer digits** on the
   primary reading (the trailing `0` of `90.0` is visibly shorter than `90`).
   Any rule assuming uniform digit height across one reading is wrong here.
5. **Annunciators are fixed-position**: `SCAN`, `MAX`, `°F`, laser and lamp icons.
   The unit is readable as a segment, not as text.

### The realization: nothing here needs to be *inferred*

A fixed-segment LCD has every element etched at a fixed location in the glass.
The digits do not move, the decimal points do not move, the annunciators do not
move. Once the display's four corners are known — which the app **already
tracks**, via `TrackedTarget` + homography into canonical space — every cell and
every decimal point sits at a **known constant** in canonical coordinates.

So the correct approach is not better layout analysis. It is a **calibrate-once
instrument profile**:

```text
InstrumentProfile
  displayAspect
  fields:
    - role: .primary     cells: [4 rects]  decimalPoints: [rect@pos2]
    - role: .max         cells: [3 rects]  decimalPoints: [rect@pos2]
  annunciators:
    - .unitFahrenheit  rect
    - .unitCelsius     rect
    - .max             rect
    - .scan            rect
```

Reading a frame becomes: warp to canonical → for each cell, sample seven
segments (`SevenSegmentSampler`, already built and calibrated against DSEG7) →
for each decimal point, sample its fixed rect → for each annunciator, sample its
rect. No detection, no grouping, no inference.

### Why this solves all three reported problems at once

| Reported problem | How the profile resolves it |
|---|---|
| App cannot tell which number is the main reading | Roles are **assigned by the profile**, not inferred. Solved definitionally. |
| App reads `900` instead of `90.0` | The DP is a **fixed sample point**. It cannot be "missed" — it is either lit or not, with its own margin confidence. |
| Segment faces defeat `DecimalRescue` | Never invoked on a profiled device; `SevenSegmentSampler` is the reader, and it was built for exactly this glyph family. |

It also removes the fragility that has bitten this project repeatedly: the
smaller fractional digit (fact 4) breaks height-ratio heuristics, and the
annunciator `MAX` breaks label-association heuristics, but neither matters when
the geometry is declared rather than deduced.

### Calibration is a feature the app nearly has

The user already selects fields on a locked display (`FieldSelectionOverlay`,
`ScreenFieldCatalog`). **That selection *is* the calibration.** What is missing
is persistence and roles: save the canonical-space rects under a named profile,
tag one field `.primary`, and record DP rects. `ScreenFieldCatalog` already
stores canonical-space regions and survives re-analysis; it is most of the data
model already.

### Recommended order

1. **`InstrumentProfile` model + persistence** (canonical-space rects, roles,
   DP rects, annunciator rects). Small, pure, testable.
2. **DP sampling**: an 8th patch on `SevenSegmentSampler`, reported as a separate
   `decimalPointLit` + margin confidence — never folded into digit confidence
   (this project has already established decimals must be scored separately).
   With a profile the patch is sampled at a *declared* rect, not an inferred one,
   which removes the "prior about hardware" risk flagged yesterday.
3. **Profile-driven read path** in `MeasurementProcessor`: when the locked target
   has a profile, read cells+DP+annunciators directly and skip whole-ROI OCR.
4. **Calibration UI**: promote the existing field selection to "save as profile",
   with role assignment.
5. Generic path (projection profile + component analysis, described below) stays
   as the fallback for un-profiled instruments.

### What can be done TODAY, before any of that

Constraining the primary field's format to `##.#` (3 digits, decimalPosition 2)
**does not** currently reconstruct `90.0` from `900` — `FormatValidator.parse`
requires the separator to be present and rejects the reading outright. That is
still a strict improvement: it converts a **silent 10× error into a rejection**,
which is the project's stated priority (a wrong value is worse than no value).

To get the reading as well, add **format-declared reconstruction**: when the user
has explicitly declared `##.#` AND OCR returns exactly `digitCount` digits with
no separator, insert the separator at the declared position. `reconstruct(digits:
format:)` already exists in `MeasurementProcessor` — it is used on the digit-level
and sampler cross-check paths but **not** on the primary whole-ROI OCR path.
Gate it on the exact digit-count match so it stays deterministic: the only
assumption is that the user's declaration is correct, not a guess about where a
missing dot belongs. Flag such readings as reconstructed in the structured output
so the CSV distinguishes them from directly-observed decimals.

### Risk, restated honestly

A profile is only as good as its calibration, and it is device-model specific: a
different gun needs a different profile. The mitigation is that mis-calibration
fails *loudly* — sampling a cell that is not where a digit is returns blank or an
unrecognized segment pattern, which is a rejection, not a plausible wrong number.
That is the opposite of the current failure mode.

---

## Superseded: generic segment-aware decimal rescue — design decision (2026-08-02)

**Why this is the top functional priority.** The user's target instrument is a
temperature gun, i.e. almost certainly a seven-segment LCD. `DecimalRescue`
(Layer B) is the module that recovers a decimal point the text recognizer
dropped — and it is **measured not to work on segment faces at all**: a clean
DSEG7 render of `80.8` labels as **21 connected components** (17×76 verticals,
89×17 bars) and *none of them is a digit*, because segments do not touch. Across
every DSEG7 preset it returned an absence or a presence with no position.

So the decimal-integrity work shipped so far protects raster/OLED displays and
does essentially nothing for the hardware this app is aimed at. Everything else
open (overlay hit-testing, regex divergence, fast-motion tracking) is smaller in
user impact than this.

### The reframe that makes this tractable

The instinct is "connected components fail on segments, so we need a smarter
component algorithm." That is the wrong lesson. Two facts from the existing code
change the shape of the problem:

**1. The decimal point on segment hardware is not "between digits" — it is part
of a digit cell.** A seven-segment digit position is physically *seven segments
plus a DP*, and the DP sits at a fixed location: the baseline, just right of the
glyph. That is a far stronger prior than the geometric reasoning `DecimalRescue`
uses on raster faces (find a small blob, check it is baseline-adjacent, check it
is horizontally between two digit components). On segment hardware we do not
need to *find* the dot; we need to *sample where it must be*.

**2. `SevenSegmentSampler` already does exactly that kind of sampling, and has
already solved the hard parts.** It places seven patches as fractions of the
digit's **detected ink bounding box within the cell** (not of the raw cell —
a documented deviation made precisely because raw-cell fractions sampled
background and every digit failed), auto-detects polarity from border
statistics, and returns a per-decision **margin-based confidence**. Its file
header notes `'.'` is *intentionally* not decoded, because a lone dot collapses
to a degenerate ink box. That is a scoping decision, not a limitation of the
approach.

Putting those together: **adding an 8th "DP" patch to the sampler is a small,
natural extension that yields per-cell decimal detection with its own
confidence, on exactly the hardware where `DecimalRescue` fails.** It inherits
polarity handling, ink-box registration and margin scoring for free.

### The remaining gap: where do cells come from?

`DigitSegmenter` currently returns `format.digitCount` **equal-width** cells.
That is a stub with two problems for this job: it requires the digit count to be
known in advance, and equal-width division is wrong the moment a decimal point
consumes horizontal space (the DP column is narrower than a digit column, so
every cell after it is offset).

Options considered:

| Approach | Verdict |
|---|---|
| Smarter connected-component grouping (cluster segments into digits by x-overlap) | Workable but fragile: it still depends on connectivity, which is the property segment faces break. Bloom fuses neighbours; a DSEG7 `0` with an open middle splits into halves (already observed — it is what forced the band-integrity guards). |
| **Vertical projection profile** (sum ink per column; digits are broad peaks, inter-digit gutters are troughs) | **Recommended.** It is *connectivity-agnostic* — precisely the property whose absence broke `DecimalRescue`. One O(pixels) pass, deterministic, no dependencies. Works identically on raster faces (one component per digit) and segment faces (many), which means ONE cell-finding path instead of two. Also recovers digit count instead of requiring it. |
| Train a small segmenter/detector | Deferred: the user has explicitly stated there are no datasets to train on, and this must not become the blocker. |
| Perspective/template registration against a known instrument profile | Out of scope now; useful later for known devices, needs a profile library that does not exist. |

### Recommended integration

Smallest change that reaches the goal, reusing the most existing code:

1. **`DigitSegmenter` gains a projection-based `digitCells(in:image:)`** beside
   the existing fixed-pitch `digitCells(in:format:)`. Column-sum the binarized
   canonical ROI, find gutters, emit cells. Keep the fixed-pitch method — it is
   the fallback when the projection is ambiguous, and it is what the current
   cross-check path uses.
2. **`SevenSegmentSampler` gains an 8th DP patch** sampled at the ink box's
   bottom-right, reported as a separate `decimalPointLit: Bool` + its own margin
   confidence on `DigitReading` (NOT folded into the digit's confidence — the
   project already learned that a decimal's certainty must be scored separately
   from the digits').
3. **`DecimalRescue` gains a segment path**: when the component analysis finds no
   digit-like components but the projection finds plausible cells, defer to the
   sampler's DP readings and synthesize a `Finding` (position = index of the cell
   whose DP is lit; confidence = that cell's DP margin). The existing `Finding`
   contract, `AMBIGUOUS_DECIMAL` rejection, and `ConfidenceEngine` fusion all
   stay unchanged — this is a new *evidence source*, not a new pipeline.
4. **Route selection is evidence-based, not configured**: if component analysis
   yields digit-like components, use the raster path (measured working:
   `80.8` → position 2 @ 0.97); if it does not, use the segment path. Neither
   requires the user to declare their display type.

### Why this ordering

Step 2 is independently valuable and cheap: it makes the *existing*
seven-segment cross-check decimal-aware, which strengthens constrained-format
readings on segment hardware even before the rescue path is wired. Step 1 is the
only genuinely new algorithm. Step 3 is glue. If effort runs out after 1–2, the
app is still better off.

### Acceptance criteria before this is called done

- [ ] Projection cells match ground truth on DSEG7 renders of `80.8`, `808`,
      `12.345`, `0.001`, `-1.25` (cell count and boundaries).
- [ ] DP patch distinguishes `80.8` from `808` on DSEG7 at every degradation
      preset the raster path is measured against, with the failure threshold
      recorded rather than assumed.
- [ ] Leading-separator case (`.808`) — currently *structurally* invisible to
      the raster path (it only inspects gaps BETWEEN digits, so absence
      confidence is capped at 0.5). The DP-patch approach can see it, because
      cell 0's DP is a real sample. Assert it.
- [ ] No regression on raster faces: the existing `DecimalRescueTests` 23 cases
      stay green, and route selection provably picks the raster path for them.
- [ ] Ambiguity still rejects rather than guesses: a cell whose DP margin is low
      yields low confidence, never a coerced integer.

### Honest risk

The DP patch's position is a *prior* about seven-segment hardware, not a
measurement of the user's actual gun. If that instrument renders its decimal
somewhere else (some LCDs place it centred between cells rather than at the
digit's bottom-right), the patch samples background and the approach reports a
confident absence — the exact failure class this project has already been bitten
by twice. **Mitigation: validate against a photograph of the real instrument
before trusting it**, and keep the low-confidence-not-false-negative behaviour
that `absence()` now has.

- ⬜ Remaining: import-flow Simulator walkthrough (file picker is hard to script);
  physical-device validation (camera, real-DMM OCR, real iPhone slo-mo footage, real
  video-recording thermals) — the gates the Simulator cannot cover.

---

## ✅ BUILT: in-window sub-field selection (2026-08-02)

The user's ask, verbatim: *"I want it to be such that if two numbers are
intelligently determined to be within the same window, the user will get two
additional boxes within the window to select the numbers to lock onto."*

Built and verified against the photograph of the real IR thermometer.

### Why the existing field-selection path could not be reused

The intelligent path ALREADY does this — `ScreenFieldAnalyzer` proposes fields,
`FieldSelectionOverlay` makes them tappable, and each selection becomes its own
device and therefore its own CSV column. It was tempting to declare the feature
already present.

It is not, for the target instrument. That whole path is gated on a LOCKED
target: field regions live in canonical display space and are drawn by
projecting them through the target's live homography. No lock, no homography, no
fields. The motivating device is a hand-held IR gun whose LCD is small,
frequently tilted and never still, so it routinely never reaches a verified
lock — and the manual window, which is what the user actually places, had no
equivalent.

So the new work is a second producer feeding the SAME consumer. Everything from
`Device` onward is untouched: recording, CSV export and the results screen
already operate per device, and a sub-field device is just a device.

### Localization: projection profiles, not Vision, not connected components

`NumberBandSplitter` (already built and unit-tested) finds candidates by
horizontal and vertical ink projection inside the crop. Both alternatives were
rejected on measured evidence recorded earlier in this document:

- **Vision** scores 14.6% on seven-segment glyphs. It would fail on the digits
  and succeed on the legend, which is exactly backwards.
- **Connected components** find *segments*, not digits — seven-segment strokes
  do not touch. Measured: 21 components for DSEG7 `80.8`.

**The band gate was got wrong twice, and the pattern is worth keeping.** In both
cases the number was defensible and the BASIS was wrong.

| basis | fails because | symptom |
|---|---|---|
| 4% of image WIDTH | the real display's inter-band gaps hold 47–76 ink pixels of bezel shadow and noise, not zero — the gate sat *below* them | whole crop returns as one band |
| 60% of the profile's MEDIAN | the median tracks the CONTENT, not the gap floor; a large primary drags it up until a smaller secondary sits below the gate | the smaller reading fragments into sub-minimum runs and vanishes **silently** |
| **17% of the profile's PEAK** | — | both displays split correctly |

The peak basis was fixed by measurement, not taste. Each display gives a closed
interval of admissible fractions, and 0.17 is inside both:

| display | peak | must exceed | must not exceed | admissible |
|---|---|---|---|---|
| real IR gun | 534 | gaps at 76 | content at 106 | 0.143 – 0.198 |
| synthetic dual panel | 137 | gaps at 0 | secondary at 28 | 0 – 0.204 |

The second failure is the more dangerous one and is why the synthetic
dual-reading demo earns its keep: on the real photograph the two readings happen
to carry similar ink per row, so the median gate passed. A display whose
secondary is genuinely smaller — which is the normal case for a MAX or HOLD
value — silently lost that reading, and only a second fixture exposed it.

Two lessons, both already learned the hard way on this project and both
re-learned here:

1. **Measure inside the shipping code path.** An hour went into a Python
   diagnostic reading a `sips`-produced BMP that silently transposed the image
   (760×673 vs the PNG's 673×760), so the profile being studied was of a
   sideways display. Dumping the profile from the real `LuminanceGrid` inside a
   test found the actual bug in one run.

   This then repeated on the second gate bug, three times over. Three
   theories — Otsu's method on the profile (made it *worse*: zero candidates on
   the real display), row gap-bridging, and a mis-scaled gate — were each
   implemented and tested before the trace was read. `NumberBandSplitter
   .debugRowTrace` now exists precisely so the next person dumps the actual
   bands and column groups first; it identified the true cause immediately.
   **Reaching for a more sophisticated algorithm is not a substitute for
   reading the intermediate values.**
2. **A threshold expressed in absolute units is a latent bug** whenever the
   quantity it gates is exposure- or crop-dependent.

### Geometry is stored PARENT-RELATIVE, which is the whole design

`SubFieldOrigin { parentID, region }` holds the region as a fraction of the
parent window; the absolute ROI is recomputed by `compose(parent:)` whenever the
parent moves. Storing the composed absolute ROI instead would go stale the
instant the user nudged the window. Recomposition is driven by gestures, not
frames, so it is nowhere near the hot path.

Consequences that had to be handled explicitly:

- Sub-fields are excluded from ROI auto-tracking. Nudging one independently
  would be overwritten by the next recomposition, so it would fight rather than
  track. The parent tracks; children ride along.
- **A parent with children is dropped from the recognition config.** A window
  with sub-fields is a FRAME, not a reading. Left in, it would keep producing
  exactly the merged `90.0 92.7` value the sub-fields were selected to
  eliminate — and that value would land in the CSV looking perfectly valid.

### Selections survive re-analysis, but are not silently rebound

Each analysis pass mints fresh candidate ids, so matching selections by id would
deselect everything every time the user nudged the window. Selections are
matched **geometrically** by centre distance and their stored region updated in
place, which also lets a selection follow content that shifted inside the frame.

The opposite failure is worse and is guarded separately: a match further than
0.5 (normalized) is rejected rather than accepted as "the nearest". Rebinding a
selection across the window would swap two columns' meaning mid-run with nothing
visible on screen to indicate it — a data-integrity failure, not a UI glitch.

### The outline is not the tap target

The window is dragged by a `UIPanGestureRecognizer` covering its whole area —
the fix for the drag latency the user reported three times. A SwiftUI tap
gesture layered on top would win the hit test and the pan recognizer would never
see the touch, so making the boxes tappable would silently make the middle of
the window undraggable. Since candidates cover most of the window, that trades
one reported defect for a worse one.

The outline is therefore inert and the tap target is a small labelled chip at
each box's top-left, at the project's 44 pt minimum.

### Measured result on the real photograph

`WindowFieldAnalyzer` on the IR-gun fixture returns three ranked candidates:

| rank | y | glyph height | what it is |
|---|---|---|---|
| 0 | 0.262 | 0.370 | the large `90.0` — labelled MAIN |
| 1 | 0.738 | 0.208 | the `MAX` legend |
| 2 | 0.738 | 0.208 | the `92.7` reading |

The icon row (SCAN / laser / lamp / °F, glyph height 0.066) and a 42×303 px
bezel sliver are both filtered out — by relative glyph height and by pixel
aspect ratio respectively.

### Known limitation, accepted deliberately

**Rank 1 is the word `MAX`, not a number.** Nothing in this path can tell text
from digits without recognition, and recognition is precisely what cannot be
trusted here (Vision at 14.6% on seven-segment would drop the `92.7` and keep
the `MAX`, which is worse than doing nothing). The design is therefore
recall-first, matching the splitter's stated contract: a spurious candidate
costs one ignored rectangle, a missed reading costs the feature. The user sees
the boxes over their own display and taps the one around the number.

Closing this properly needs the per-instrument calibration described in the
"instrument profile" section above — once a display's layout is calibrated, role
assignment is a lookup rather than an inference.

### Cost, and a measurement trap worth remembering

Analysis runs serially inside the frame drain, so its cost is paid in dropped
frames. It runs once per window placement, not per frame.

| build | median, 673×760 crop |
|---|---|
| Release | **6.5 ms** |
| Debug | ~310 ms |

The first reading taken was 934 ms in Debug, which looked like a serious stall
and prompted two optimizations:

- percentiles from a 256-bin histogram instead of sorting one `Int` per sampled
  pixel (a 4 MB allocation and an O(n log n) pass for a statistic with 256
  possible values — the right shape regardless of timing);
- the usability predicate materialized into a mask instead of being recomputed
  per lookup across four grid sweeps.

Both are keeps. But the honest accounting is that **most of the 934 ms was Debug
overhead**, not algorithmic cost, and the Release figure was never a problem.
The lesson is narrow and practical: *`xcodebuild test` defaults to Debug, where
Swift keeps bounds checks and skips inlining, so per-pixel code can read 50×
slower than it ships.* Getting a real number needs

```
xcodebuild test -configuration Release SWIFT_ENABLE_TESTABILITY=YES …
```

(testability must be forced back on or `@testable import` will not link).

One optimization was tried and REVERTED: decimating the luminance grid harder
(`maxLongEdge` 900 → 400) aliased the seven-segment strokes enough to erase the
inter-band gaps, and the real display collapsed from three candidates to one.
Resolution is load-bearing here; at 6.5 ms there is nothing to buy anyway.

### Two defects only the running app could show

Both were invisible to unit tests and found on the first UI-test run.

**A selected sub-field drew its own draggable window on top of its parent.**
`ROISelectionOverlay` renders a window per device, and a selected sub-field IS a
device with an ROI — so it got a second frame stacked over the parent, whose pan
catcher then swallowed every tap meant for the chips underneath. The symptom was
that a box could be selected but never deselected. Sub-fields are now excluded
from that `ForEach` for the same reason field-backed devices already were:
something else draws them. The stacked window would also have let the user drag
a sub-field independently of the parent it is defined relative to, which the next
recomposition silently undoes.

**Candidate ids drift from the devices they create.** Re-analysis mints fresh
ids, so a selected candidate must ADOPT its device's id rather than keep the new
one, or the chip and its device become two different things. (This was fixed
before the stacked-window cause was found; it is a real latent bug, but it was
not the cause of the deselect symptom — worth recording, because fixing it and
seeing the test still fail is what forced the search to continue.)

### KNOWN LIMITATION: single readings can split at the decimal point

Measured at **19 of 40** values on the synthetic face: `12.000` is offered as two
boxes, cut at its decimal point.

Gap width cannot decide this. `12.000` leaves a 99 px gap at its decimal against
a 121 px band — 0.82 of band height — and the real instrument's `MAX` legend sits
130 px from its reading against a 158 px band, *also* 0.82. Identical geometry,
opposite meanings, so no threshold on `groupGapFraction` separates them.

A fix was implemented and **reverted**: merging groups whose gap still contains
ink correctly rejoins the decimal, because a decimal point is not background.
But the real photograph's legend gap carries enough sensor noise to clear any
occupancy floor low enough to catch a decimal point, so it merged `MAX` into the
reading and broke the actual target device. Breaking the real instrument to fix
a synthetic one is the wrong trade.

The direction that would close it properly is vertical, not horizontal: a decimal
point occupies only the BOTTOM of the band, while a legend spans the band's full
glyph height. Comparing the vertical extent of ink within the gap against the
band's glyph height should separate the two cases without depending on noise
level. Not attempted here.

User-visible cost is bounded by the recall-first contract: an extra box to
ignore, never a wrong reading.

### Verification

- `WindowSubFieldTests` — 10 tests, all passing. The headline case is driven by
  the real photograph; the rest guard the silent failures (selection rebinding,
  parent still contributing, mid-recording column changes).
- `NumberBandSplitterTests` — all passing, including the row-profile diagnostic
  that found both gate bugs.
- `DAQPalUITests/WindowSubFieldUITests` — end-to-end on the Simulator against
  the `-daqpal-dual-reading` synthetic display: boxes appear, tapping one adds a
  device, tapping again removes it.

### Not done

- Renaming a sub-field (it inherits `"<parent> MAIN"` / `"<parent> AUX n"`).
- Per-sub-field display format; a sub-field currently inherits the parent's.
- Distinguishing legend text from numbers (see limitation above).
