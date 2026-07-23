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
- ⏳ Module implementation (camera / pipeline / UI / results / tests) in progress — see
  status updates appended below.
