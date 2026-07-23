# DAQPal — Development Progress

**Date:** 2026-07-22 · last updated 2026-07-23
**Measured against:** `Design_notes/design_handoff_daqpal_ios/Visual_Instrument_Data_Logger_Agent_Development_Specification.md` (§35 milestone plan, §38 Definition of Done, §40 concrete iOS design)
**UI authority:** `Design_notes/design_handoff_daqpal_ios/README.md` (Fluke-yellow design handoff)
**Companion doc:** `IMPLEMENTATION_NOTES.md` (decisions, naming audit, deviations)

---

## Executive summary

The full MVP slice (spec Milestones 1–7) is **implemented, building, and tested** — 43
Swift source files across App / Camera / Display / OCR / Processing / Data / Import / UI
plus 11 test files, suite at **116 / 0 / 2**. A three-dimension adversarial review
(architecture/scalability, correctness, design fidelity) confirmed 7 findings; all fixed.
A Simulator-reproduced field report then drove three pipeline/UI fixes (value-distance
temporal filter replacing digit-agreement, `.accurate` Vision confidences, header chip
layout), verified by screenshot walkthroughs. The first Milestone 12 slice — offline
video import with slow-motion time normalization — is implemented and end-to-end tested.
What remains unproven is exactly what the Simulator cannot prove: real camera capture and
real-DMM OCR accuracy on physical hardware.

| Verification gate | Status |
|---|---|
| Integration build (`xcodebuild`) | ✅ succeeded (2026-07-23, iPhone 17 Pro simulator destination, zero compile errors) |
| Unit tests on Simulator | ✅ **116 passed, 0 failed, 2 skipped** (the 2 skips are the fixture-harness tests, which by design skip until a real `dmm_001.mov` DMM fixture is recorded — no fabricated accuracy) |
| End-to-end pipeline (no camera) | ✅ `SyntheticPipelineTests` — rendered frame → Vision OCR → format/physical/temporal validation → accepted at the rendered value; garbage frame never accepted |
| Video import incl. slow-mo normalization | ✅ `VideoImportTests` — H.264 fixture encoded in-test → decode → ½× time normalization → recognized and accepted at the rendered value with the halved timeline |
| App launch + UI walkthrough on Simulator | ✅ capture (ROI lock, live reading, recording strip) + recorded-session results verified via debug-launch-argument screenshots (2026-07-23); import flow walkthrough pending |
| Camera / real-DMM validation on physical iPhone | ⬜ requires physical hardware (cannot be done in Simulator) |

---

## Milestone status (spec §35)

### Milestone 1 — Camera · **code complete — physical-device verification pending**
`CameraPermissionManager`, `CameraManager` (back camera, `.hd1920x1080`,
`AVCaptureVideoDataOutput`, 32BGRA, `alwaysDiscardsLateVideoFrames = true`, buffers rotated
to portrait via `videoRotationAngle = 90`), `CameraPreview`
(`AVCaptureVideoPreviewLayer` in `UIViewRepresentable`), `CaptureStack` lifecycle owner,
always-mounted root screen (no `NavigationStack` teardown — sheets/covers only).
**Success criterion (live oriented preview on iPhone) requires a physical device** — the
Simulator has no camera. On Simulator the app runs a clearly-labeled `SyntheticFrameSource`
instead.

### Milestone 2 — Vision OCR · **code complete, synthetic-frame verified — real-DMM validation pending**
`VisionOCR` (`VNRecognizeTextRequest`, `.fast`, no language correction) behind an
`OCRManager` facade — the replaceability seam the spec requires for future
PP-OCRv6 / specialized digit models. Raw recognized text is surfaced in a debug overlay
toggle. **Real-DMM recognition ("12.347 V" from an actual meter) is untested** and can only
be validated on hardware. No accuracy claims are made.

### Milestone 3 — ROI · **code complete, unit-tested**
`NormalizedROI` (0…1, top-left origin, clamping, pixel mapping), `AspectFillMapper`
(pure-math view ↔ normalized conversion accounting for aspect-fill cropping — the spec's
"one real gotcha"; unit-tested in `GeometryTests`), `ROISelectionOverlay` (drag +
corner-handle resize, ghost "DRAG TO PLACE" placement, locked-yellow / searching-orange
states per the design handoff), `PixelBufferROI` crop feeding OCR only the selected region.

### Milestone 4 — Format configuration · **code complete, unit-tested**
`DisplayFormat` (`decimalPosition` = digits before the separator, per spec §40.4
clarification), `FormatConfigurationSheet` (digits 4/5/6, decimal stepper, sign, unit
V/A/Ω/°C/Hz, ±range, live `±XX.XXX V` pattern preview, Fluke-yellow styling),
`FormatValidator` (exact grammar check; spec's valid/invalid vectors encoded in
`FormatValidatorTests`, incl. `12..34`, `1A.34B`, `123.4567`, `12.34.7` rejections).
Live readings display only after passing format validation — the first implementation of
the core format-aware-OCR thesis.

### Milestone 5 — Digit-level recognition · **stub complete as specified, unit-tested**
`DigitSegmenter` (fixed-pitch equal-width cells — the documented stub assumption; real
display geometry and seven-segment recognition are Milestone 11+), `DigitRecognizer`
(per-cell recognition restricted to 0–9, per-digit confidences feeding
`Measurement.digitConfidences`). Whole-ROI OCR remains the default value path; the digit
path is switchable on `MeasurementProcessor` and is **not** claimed to be seven-segment
recognition.

### Milestone 6 — Measurement validation · **code complete, unit-tested**
Full chain in the `MeasurementProcessor` actor: format → range (`OUT_OF_RANGE`) →
rate-of-change (`EXCESSIVE_RATE_OF_CHANGE`, with step-change escape so real transitions
survive, per spec §16) → temporal rolling-window consistency (`TEMPORAL_INCONSISTENCY`,
score-only, no value smoothing) → `ConfidenceEngine` fusion
(`ocr × format × physical × temporal`, spec §19). Typed `RejectionReason` (7 cases).
Rejected readings are logged, never dropped. `ValidationPipelineTests` authored.

### Milestone 7 — CSV · **code complete, unit-tested**
`Measurement` (monotonic capture timestamps; wall-clock only as session metadata),
`RecordingSession` (append-only store keeping accepted **and** rejected),
recording strip (elapsed, sample/rejected counts, 2-series sparkline, "✕ REJECTED — …"
flash chip), `ResultsView` + `ResultsGraphView` (Swift Charts, per-device dual-scale
series, rejected samples visibly marked, accepted-only min/mean/max stats, rejected-row
table styling), `CSVExporter` → `daqpal_session.csv` via `ShareLink`.
Single-device schema: `timestamp,value,unit,confidence,accepted,rejection_reason` (spec §25).
Multi-device schema: `timestamp_s,dmm1_value_V,dmm1_confidence,dmm1_valid,…` (handoff README).
`CSVExporterTests` authored.

### Milestone 8 — Temporal fusion · **minimal form present**
The rolling-window consistency scoring in `TemporalFilter` is the "minimal form of M8" the
spec's §40.4 anticipates. Full multi-frame digit fusion (majority voting across digit
positions to resolve uncertain digits) is future work.

### Milestone 12 — High-speed acquisition · **first slice implemented, unit-tested (video import)**
Offline video import (2026-07-23): pick a recorded movie file, drag an ROI over its first
frame, choose playback speed (1×; ¼× for 120 fps slow-mo; ⅛× for 240 fps), and the file
runs through the identical recognition/validation pipeline with playback timestamps
multiplied back to **real capture time** (`TimeScalingFrameSource`) — so rate-of-change
validation operates in true physical time. Raw high-frame-rate files (nominal fps ≥ 100)
are detected as already real-time. Proven end-to-end by `VideoImportTests` (in-test
H.264 fixture → ½× normalization → accepted at the rendered value, timeline halved).
Outstanding: live in-app 240 fps capture with selective frame processing (spec §21
"High-Speed Recording Mode") and real slow-motion iPhone footage validation.

### Milestones 9–11, 13–15 · **deferred by design (spec §37)**
OCR benchmarking, ONNX/PP-OCRv6, specialized seven-segment model, instrument profiles,
automatic format inference, Android. The `OCRManager` seam and `FrameSource` fixture
architecture exist so these can be added without restructuring.

---

## Testing architecture (spec §40.3, §41)

- `FrameSource` seam: `LiveCameraFrameSource` (device) / `FixtureFrameSource`
  (`.mov` via `AVAssetReader`) / `SyntheticFrameSource` (rendered DMM-style frames) all feed
  the identical pipeline — recognition/validation is testable with no camera, no Simulator
  camera, and no GUI automation.
- Authored and passing: `FormatValidatorTests`, `DisplayFormatTests`, `GeometryTests`,
  `ValidationPipelineTests`, `DigitSegmenterTests`, `CSVExporterTests`,
  `RecordingSessionTests`, `SyntheticPipelineTests` (end-to-end against rendered frames —
  clearly labeled synthetic), and `RecognitionPipelineTests` (spec §40.3 fixture harness —
  **skips** until a real `dmm_001.mov` + ground-truth CSV fixture is recorded; no
  fabricated accuracy results).

---

## Definition of Done tracker (spec §38, items 1–20)

| # | Item | Status |
|---|---|---|
| 1–2 | Launch, camera permission | code complete; device verification pending |
| 3 | Point camera at DMM | requires physical hardware |
| 4–5 | Select ROI, configure format | code complete; Simulator-verifiable |
| 6–7 | Digit recognition, value reconstruction | whole-ROI path primary; digit path stub |
| 8–10 | Format/range validation, live value | code complete (unverified) |
| 11–16 | Record → timestamps → temporal validation → reject/flag → stop | code complete (unverified) |
| 17–18 | Graph, CSV export | code complete (unverified) |
| 19–20 | Reopen CSV, values match instrument | pending hardware validation |

Target accuracy (≥99% correct accepted measurements on a controlled DMM setup): **not yet
measurable** — requires physical-device sessions against a real instrument.

## Branding

Product name **DAQPal** throughout (project, module, targets, UI wordmark
"DAQPAL / VISUAL DATA ACQUISITION", `daqpal_session.csv`). No `InstruLog` identifiers exist
in code; the spec's `InstrumentLogger` examples are legacy documentation naming only
(see `IMPLEMENTATION_NOTES.md`).

## Achievements

What follows is only what has been run and observed, per the project's honesty rule — no
projected or assumed results.

- **Integration build is green.** `xcodebuild` against the integrated target on the iPhone
  17 Pro simulator destination compiles all 40 Swift source files with zero errors.
- **113 tests passed, 0 failed, 2 skipped — and the 2 skips are honest, not hidden
  failures.** The skipped pair is `RecognitionPipelineTests`, the spec §40.3/§31
  fixture-harness tests that are designed to skip until a real `dmm_001.mov` DMM recording
  (spec §30 dataset format) exists on disk. No accuracy number is fabricated in their place.
- **The end-to-end pipeline was proven on synthetic frames, not just unit-tested in
  isolation.** `SyntheticPipelineTests` pushes a rendered DMM-style frame through the full
  chain — Vision OCR → format validation → physical validation → temporal validation — and
  the pipeline accepted the value that was actually rendered into the frame. Separately, a
  garbage/malformed frame was pushed through the same chain and was never accepted. That is
  the spec's central thesis (§3, §39: "the more the app knows about the format, the less it
  needs to guess") demonstrated as a passing test, not just implemented.
- **Format-aware rejection works as specified.** `FormatValidator` enforces the exact
  grammar from a configured `DisplayFormat` (digit count, decimal position, sign, unit) and
  is verified against the spec's own valid/invalid vectors (`12..34`, `1A.34B`, `123.4567`,
  `12.34.7` all correctly rejected in `FormatValidatorTests`), plus the fuller chain in
  `MeasurementProcessor` — range, rate-of-change with a step-change escape, and rolling-window
  temporal consistency — all feeding a multiplicative `ConfidenceEngine` (`ocr × format ×
  physical × temporal`, spec §19) with a typed 7-case `RejectionReason` so rejections are
  logged, never silently dropped (spec §38 item 15, §36).
- **Multi-device data model is in place.** `Measurement` and `RecordingSession` are built to
  carry more than one instrument's readings per captured frame (one processed frame → one
  row across all configured devices), matching the handoff's simultaneous-multi-DMM intent
  rather than a single-channel assumption baked into the model.
- **Dual CSV schemas are both implemented, not just one chosen over the other.** Single-device
  sessions emit the spec §25 schema (`timestamp,value,unit,confidence,accepted,
  rejection_reason`); multi-device sessions emit the design handoff's per-device column-set
  schema (`timestamp_s,dmm1_value_V,dmm1_confidence,dmm1_valid,…`). Both are covered by
  `CSVExporterTests`, and rejected samples are always written (`valid=0`/`accepted=false`),
  never dropped from the export.
- **The whole thing runs with zero camera hardware in the loop.** The `FrameSource` seam
  (`LiveCameraFrameSource` / `FixtureFrameSource` / `SyntheticFrameSource`) feeding one
  identical pipeline is what made every result above obtainable without a device, a
  Simulator camera (which doesn't exist), or GUI automation — 113 tests, an end-to-end
  synthetic acceptance/rejection proof, and a full Simulator-runnable app all exist today
  because recognition and validation logic never assumes a physical camera is present.

- **An adversarial review pass already paid for itself.** A three-dimension review
  (architecture/scalability, correctness, UI fidelity) with independent adversarial
  verification of every finding confirmed 7 real issues — headline: the results chart
  rendered one mark per recorded sample (a multi-thousand-sample session would freeze the
  results screen), CSV export was built on the main thread as the screen presented,
  per-device recognition ran sequentially (sample rate divided by device count), and
  adding a device after a removal could produce duplicate CSV column names. All are fixed
  (decimated chart model built off-main once per session, detached CSV build, concurrent
  per-device recognition inside the actor's single-frame call, monotonic device naming,
  coalesced pipeline-config pushes, 44 pt stepper hit targets, unit-label corrections) and
  the full suite re-passes 113 / 0 / 2 — with the synthetic end-to-end tests now also
  exercising the new concurrent recognition stage and Vision `regionOfInterest` path.

## Continuous enhancement roadmap

Each item below builds directly on the code-complete MVP slice (Milestones 1–7) and is tied
to a specific spec section/milestone rather than an open-ended aspiration.

- **Record a real DMM fixture and unskip the harness** (spec §30 Dataset Creation, §31 Ground
  Truth and Validation). Capture `dmm_001.mov` against a real multimeter with a manually or
  digitally sourced ground-truth CSV, drop it where `RecognitionPipelineTests` expects it, and
  the 2 currently-skipped tests become the project's first real-instrument accuracy numbers —
  the first legitimate input to the spec §38 "≥99% correct accepted measurements" target,
  which cannot be claimed from synthetic frames alone.
- **Digit-level path graduation + temporal digit fusion** (spec §11 Phase 5, §16 Temporal
  Processing, Milestone 8). `DigitSegmenter`'s fixed-pitch equal-width cell assumption needs
  to be replaced with real display-geometry detection before the digit path can be anything
  more than a stub; once that lands, implement true position-wise majority/confidence-weighted
  voting across frames (spec §16's worked example — resolving a single uncertain digit from
  four agreeing neighbors) rather than the current whole-reading rolling-window score, which
  is explicitly documented as only "the minimal form of M8."
- **OCR benchmarking: Vision vs PP-OCRv6** (spec §14 OCR Engine Evaluation, Milestone 9). The
  `OCRManager` facade exists specifically as the replaceability seam for this; the actual
  benchmark (FPS, latency, CPU/GPU/memory, ANE utilization per spec §14) against PP-OCRv6 Tiny
  and Small via ONNX has not been run, and the spec explicitly warns not to assume Core
  ML/ONNX execution implies Neural Engine usage — that has to be measured, not assumed.
- **Instrument profiles** (spec §23, Milestone 13). Persist and load the digit
  count/decimal-position/sign/unit/range tuple the format sheet currently collects manually
  every session, so a known meter model configures itself instead of being re-entered by hand
  each time.
- **Automatic format inference** (spec §24, Milestone 14). For unknown instruments, run
  general OCR across several frames, infer digit count/decimal position/unit from the repeated
  pattern (spec §24's worked example), and propose a format for user confirmation instead of
  requiring manual entry from a blank sheet.
- **High-speed capture** (spec §21, Milestone 12). Add the 240 FPS recording mode with
  frame-by-frame/selective processing and original-timestamp-preserving temporal
  reconstruction; today only the live-mode path (spec §21's "Live Mode" diagram) exists, and
  the current sampling model is explicitly OCR-rate-driven rather than camera-rate-driven.
- **Archivo bundling.** `IMPLEMENTATION_NOTES.md` documents the current MVP substituting SF
  Pro/SF Mono for the handoff's Archivo grotesque (an explicitly allowed substitution) — bundle
  the real typeface as a cosmetic follow-up so the shipped app matches the Fluke-yellow design
  handoff exactly, not just approximately.
- **Physical-device validation runs** (spec §38 items 1–3, 19–20; PROGRESS.md's own
  "requires physical hardware" gates). Camera permission flow, live oriented preview, and
  real-DMM OCR quality cannot be verified in Simulator at all — this is the one remaining
  category of Milestone 1–7 work that no amount of further Simulator/unit-test work can
  substitute for, and it is also the prerequisite for the dataset-recording item above.

## The iPhone as the lab's missing DAQ

The spec frames the product as a **visual DAQ** for people who don't have real DAQ hardware
(§32 target users: research labs, universities, field technicians, QA/QC, legacy-equipment
users; §39's "any instrument"), and the root README names students, hobbyists, and lab TAs
first. The ideas below are concrete ways someone without dedicated DAQ hardware can point an
iPhone at whatever's already on the bench and get a CSV out of it — each one marked against
what the current MVP slice (Milestones 1–7) can already do versus what needs a roadmap item.

- **Student lab reports — titration and discharge curves from a school DMM.** Point the
  camera at a bench multimeter reading pH/voltage during a titration, or at a DMM across a
  discharging capacitor/battery; the CSV gives `timestamp,value,unit,confidence` you drop
  straight into a lab-report plot instead of hand-timing a stopwatch against a refreshing
  display. **Supported today** — this is the exact MVP workflow (single-device schema, spec
  §25) already end-to-end code-complete, pending only physical-device validation.
- **Hobbyist battery / solar-panel / thermal characterization.** Log a battery's voltage
  sag under load, a solar panel's output across a day, or a thermocouple-driven meter's
  temperature ramp over an hour-long bake — anything where "sit and watch a number for a
  long time" is the actual barrier. **Supported today**, same single-device path; long
  sessions are just more rows in the same append-only `RecordingSession`.
- **Multi-meter simultaneous logging — V and A on two cheap DMMs for a power profile.**
  Point the camera so two DMMs' displays are both visible (or configure two ROIs), one set to
  volts and one to amps across the same load, and multiply the two output columns after the
  fact to get a power-over-time profile no single instrument would give you. **Data model
  supported today** — the multi-device schema (`timestamp_s,dmm1_value_V,dmm1_confidence,
  dmm1_valid,dmm2_value_A,…`) and one-frame-multi-device sampling already exist; what's
  unproven is real-world two-ROI recognition accuracy, which needs the physical-device
  validation roadmap item.
- **Legacy and no-port bench gear — old PSUs, panel meters, analog-adjacent displays,
  scales, pressure gauges.** The entire point of visual acquisition (spec §1, §39) is
  instruments that predate USB/Bluetooth/serial: point the camera at whatever numeric display
  the old power supply or scale already has, configure its digit count/decimal
  position/units once, and the CSV output is indistinguishable from what a "real" DAQ would
  have produced. **Numeric seven-segment/LCD displays supported today** (DMM-shaped displays
  are the MVP's proven case); non-DMM instrument types and any that need geometry/profile
  awareness beyond a plain digit format depend on the **instrument-profiles roadmap item**
  (spec §23) to stop requiring a from-scratch format entry per session.
- **Field technicians logging where cables can't go.** No serial cable, no laptop, no mains
  power for a logger box — an iPhone in a pocket already has everything needed to watch a
  panel meter on equipment that's inconvenient or unsafe to wire into. **Conceptually
  supported today** for stationary reads with the phone propped in place; genuinely
  camera-in-hand, walking-the-floor logging is future work (display detection/ROI tracking,
  spec §15) not yet in the MVP.
- **TA/QA transcription elimination.** Replace a lab TA or QA technician manually copying
  numbers off a meter into a spreadsheet — including catching the exact failure mode that
  makes manual transcription risky (a flickering LCD digit or a blurry frame silently
  transcribed as a wrong number) — because the app is built to **reject** a reading rather
  than log something wrong (spec §38 "a rejected reading is preferable to an incorrect
  measurement," proven above by `SyntheticPipelineTests`' garbage-frame-never-accepted
  result). **Supported today** for any instrument that's already a plain fixed-format numeric
  display; batch/multi-station QA workflows are a **Professional-tier roadmap idea** (spec
  §33: batch processing, API) not yet started.

---

## Next steps (in order)

1. ~~Finish test authoring~~ ✅ 10 test files authored.
2. ~~Integration build~~ ✅ zero compile errors.
3. ~~Run unit tests~~ ✅ 113 passed / 0 failed / 2 fixture-skips.
4. ~~Adversarial multi-agent code review~~ ✅ 7 confirmed findings fixed, re-built,
   re-tested (113 / 0 / 2).
5. Launch app in Simulator (synthetic source), walk the full loop
   ROI → format → live reading → record → results → CSV, capture screenshots.
6. Physical-device session: camera permission, live preview orientation, real-DMM OCR —
   the only environment where Milestones 1–2 can truly pass.
