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
- ⬜ Remaining: import-flow Simulator walkthrough (file picker is hard to script);
  physical-device validation (camera, real-DMM OCR, real iPhone slo-mo footage) — the
  gates the Simulator cannot cover.
