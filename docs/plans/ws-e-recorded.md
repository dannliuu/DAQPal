# WS-E — Recorded Path: Repair, Measure, Then Decide

Read `docs/plans/MASTER_PLAN.md` first (protocol §2, ownership §7, decisions §3). Status is reported ONLY to the master ledger (§5) — never restated here.

Created 2026-08-03 by `EXECUTABILITY_AUDIT.md` Deliverable E.

**Mission**: use *additional temporal information, when it is available*, to reduce wrong-and-accepted measurements. Not to increase throughput, and not to accept more readings.

**The offline path already ships and the original plan set was blind to it.** `VideoImportModel.swift`, `VideoImportView.swift` (616 lines), `SessionVideoRecorder.swift` and `FixtureFrameSource.swift` already drive the same recognition path from a file. This workstream repairs and extends that, rather than designing something new.

## Four premise corrections the audit established (read before planning any work)

1. **"Recording" today means measurement rows, not video.** `AppState.startRecording()` creates a `RecordingSession` row buffer; video is an opt-in tee (`saveVideoEnabled = false` by default, `AppState.swift:294`). The default REC path writes zero bytes of video.
2. **The "⅛× · 240 FPS" control is a timestamp multiplier, not a capture rate.** `VideoImportModel.swift:207-209` scales `frame.timestamp * factor`; its own doc says "Frame count is unaffected." It de-slow-mos an existing slow-motion file. This code has never seen a 240 fps container.
3. **240 FPS does not reduce motion blur.** Blur extent = exposure duration × image-plane velocity; frame rate does not appear in that expression. High frame rate only forces a shorter *maximum* exposure. If blur is the problem, the lever is **exposure control** — and no `setExposureModeCustom` call exists anywhere in the repo. The design spec's 240 FPS request (§21) is about **temporal resolution of fast-changing readings**, which is a legitimate and different goal; hold it to that goal.
4. **High-frame-rate capture is 100% net-new.** Repo-wide there are exactly three `activeFormat`-family references, all read-only, all in `CameraManager.swift`. There is **no `lockForConfiguration` call in the entire codebase**.

## Invariants

- **Repair before capability.** E1 lands before any frame-selection or capture work. The current import path will OOM on a long or high-rate file; adding frames to a broken pipe makes it worse.
- **Shared recognition, never forked.** WS-E calls WS-B's recognition modules; it never edits them. A recognition change needed by the recorded path is a hook request to WS-B at a gate.
- The recorded path may use **stronger preprocessing** than live (it is not latency-bound), but it may not use a *different* accept/reject rule. One `ConfidenceEngine`, one promise.
- Every claim about frame rate, blur, or throughput carries a provenance tag and a measurement. No capability is added on the strength of a plausible story.
- Full suite green at session end (baseline in master §5).

## Owned files

Per master §7: `DAQPal/Import/*` · `DAQPal/Camera/SessionVideoRecorder.swift`, `PhotoLibrarySaver.swift`, `FixtureFrameSource.swift`, `CameraManager.swift`, `CameraPreview.swift`, `FrameSource.swift`, `LiveCameraFrameSource.swift`, `DemoMotion.swift` · `DAQPal/UI/VideoImportView.swift`.

## Tasks

### E1 — Repair the recorded path (blocking; do this first)

**E1a — Bounded buffering.** `FixtureFrameSource.swift:39` and `VideoImportModel.swift:54` both create `AsyncStream` with the default `.unbounded` policy, and the producer loop (`FixtureFrameSource.swift:67-80`, driven with `realTimePacing: false` from `:208`) has no suspension point. Decode runs flat out while OCR plods. 10 s of 1080p at 240 fps ≈ 2400 frames × ~8.3 MB ≈ **19.9 GB retained**. It will OOM. The live path already gets this right (`.bufferingNewest(1)`, `LiveCameraFrameSource.swift:63`).
Compounding it: `FixtureFrameSource.swift:61` sets `alwaysCopiesSampleData = false`, so buffers come from the reader's recycled pool — retaining thousands exhausts the pool and the reader stalls or errors, and the `catch` at `:81-85` swallows it, surfacing as a **silently truncated import**.
- Give both streams an explicit bounded `bufferingPolicy` or a demand signal; set `alwaysCopiesSampleData = true` for the import path (or copy into an app-owned pool); make truncation loud instead of silent.
- **Evidence gate**: a long import completes with a measured, bounded memory ceiling; a forced reader error surfaces to the user rather than ending the stream quietly.

**E1b — Close the record → re-import loop.** `CaptureStack.swift:141-156` saves the recorded movie to **Photos** via `PhotoLibrarySaver`, but `VideoImportView.swift:46-48` uses `.fileImporter` — **Files only**. The app cannot re-import what it just recorded. The project declares only `NSPhotoLibraryAddUsageDescription`.
- Add a Photos read path (`PHPickerViewController`) alongside the existing file picker, with the matching usage description.
- **Evidence gate**: record → stop → import the just-recorded movie, entirely in-app.

### E2 — Frame-quality selection
No selector exists anywhere: repo-wide there is no sharpness, blur, or frame-scoring code. Today the import path OCRs **every** decoded frame, which is both slow and no more trustworthy.
- Score candidate frames (sharpness / exposure / contrast / tracking confidence / geometric quality), then recognize only the ranked survivors.
- Do **not** invent thresholds. Rank first, measure the accuracy-vs-frames-processed curve on a real fixture, then choose a policy and record it as a D-entry.
- **Evidence gate**: on a recorded fixture, wrong-and-accepted at N selected frames ≤ wrong-and-accepted at all frames, with N and the curve recorded. If selection does not improve the metric, **say so and stop** — that is a valid outcome.

### E3 — Multi-frame consensus for the recorded path
The strongest argument for a recorded path: several independent looks at the same unchanging reading should resolve ambiguity that one frame cannot, especially decimal position and weak segments.
- Feed selected frames through the existing `TemporalConsensus` rather than a parallel mechanism.
- **Evidence gate**: a fixture whose live single-frame result is `.ambiguousDecimal` resolves correctly offline — or is still refused. Never resolved *incorrectly*.

### E4 — High-frame-rate capture (GATED — do not start until E1–E3 have measured)
Only justified if E2/E3 show that temporal resolution, not image quality, is the binding constraint.
- Requires: enumerate `camera.formats`, filter `videoSupportedFrameRateRanges` for the target rate, then inside `lockForConfiguration()/unlockForConfiguration()` set `activeFormat` **and both** `activeVideoMinFrameDuration` and `activeVideoMaxFrameDuration`.
- **Known trap, state it in the code**: `CameraManager.swift:142` sets `sessionPreset = .hd1920x1080`. `sessionPreset` and manual `activeFormat` are mutually exclusive on iOS — a naive `activeFormat` assignment is silently reverted, `performConfiguration` then reports 30 fps at `:120-126`, and the bug presents as "the device doesn't support 240." Switch to `.inputPriority` when a manual format is selected.
- If blur (not temporal resolution) turns out to be the constraint, the correct task is **exposure control**, not frame rate. Write the D-entry proposal rather than building HFR.
- **Evidence gate**: measured improvement in wrong-and-accepted on a real fixture, `[device-release]`. No improvement ⇒ do not ship it.

## Device-day requests

- Record the same instrument at 30 fps and at the highest supported rate; compare wrong-and-accepted, not frame counts.
- Capture a fast-changing reading (a settling thermocouple or a ramping supply) — the only scenario where temporal resolution is genuinely the binding constraint.

## Non-goals

Recognition changes (WS-B), tracking changes (WS-A), live-path performance (WS-C), review/export UI (WS-D), and building HFR capture before E1–E3 produce evidence.
