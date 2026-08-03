# WS-C — Performance: Prove It Fast, Then Make It Fast

Read `docs/plans/MASTER_PLAN.md` first (protocol §2, ownership §7, decisions §3). Status is reported ONLY to the master ledger (§5) — never restated here.

**Mission**: create the performance ground truth that does not exist today (no Instruments profile anywhere; every device number Debug/`-Onone`; capture/tracking/detection/OCR/UI FPS and e2e latency all unmeasured), gate the codebase against the spec budget table (master §8), then optimize strictly on evidence.

## Invariants

- **No optimization before the DD1 baseline exists.** Hard rule. C6 is locked until C5 delivers.
- Every figure is provenance-tagged (`[device-release]` / `[device-debug]` / `[sim]` / `[host]`); Debug ≈50× slower on per-pixel Swift and Simulator OCR ≈10–12× slower than device — neither is ever quoted as shipping performance (D5).
- One change per measurement cycle in C6; a regression reverts.
- WS-C does not edit A/B-owned pipeline files: instrumentation lands via **hook requests** (listed per task) that the owning workstream applies at integration gates.

## Owned files

Per master §7: `DAQPal/Instrumentation/*`, `GestureLatencyProbe.swift`, `RenderCadenceProbe.swift`, `PipelineBudgetTests.swift`, `CapturePerformanceTests.swift`, `PipelineDebugOverlay.swift`. Shared files only at gates.

## Tasks

### C0 — Budget-test audit — **DONE (pre-flight audit, 2026-08-03)**
Result: `PipelineBudgetTests` asserts **0 of the 10** §8 wall-clock figures — deliberately mechanism-level (its own header disclaims wall-clock budgets). What it DOES pin (keep these green, they're valuable): homography solves scale O(targets) not O(fields) per frame; `MeasurementProcessor` per-frame jobs O(configured devices), never O(override-map); metrics ring-buffer cap exactly 240; disabled instrumentation completely inert; percentile arithmetic correctness (incl. the p99-exposes-tail case). BASELINES.md's claim that shipping performance "is asserted in `PipelineBudgetTests` against a Release build" is **false** — no wall-clock budget assertion exists anywhere. Consequence: C2 is green-field; detail lives in the master ledger + §8 note.

### C1 — Complete `PipelineMetrics` (audit-corrected 2026-08-03: it's HALF-wired, not unpopulated)
Already recording real spans `[Debug only]`: `.tracking` (`VisionScreenTracker.swift:244,259,309`), `.detection` (`ScreenCandidateDetector.swift:199`), `.analysis` (`ScreenFieldAnalyzer.swift:101`, `PerspectiveNormalizer.swift:70`, `NumberBandSplitter.swift:120`, `SegmentCellScanner.swift:217`). Never recorded anywhere: `.capture`, `.ocr`, `.endToEnd` (absence proven at `PipelineBudgetTests.swift:610-611, 628-633`).
- **Critical gotcha**: `PipelineMetrics.isEnabled` defaults **false outside DEBUG** (`PipelineMetrics.swift:269-278`). C1 must add an explicit Release-measurement enablement path (env var / benchmark scheme flag) or every DD1 Release number will silently be empty.
- C implements: the enablement path, test-accessible export, and a verification pass over the existing snapshot/display path (`PipelineDebugOverlay.swift:27`); aggregation + 240-sample ring already exist and are test-pinned.
- **Hook requests** (owners land at G1) — now only for the missing stages: `FrameProcessor` drain `.capture` timestamps (shared file — gate edit); `MeasurementProcessor` `.ocr` + `.endToEnd` spans (WS-B). Tracking/detection/analysis hooks already exist — verify, don't duplicate.
- **Evidence gate**: metrics visibly populate in a synthetic-source run; unit tests for aggregation math; overhead of the instrumentation itself measured and negligible (`[sim]` first, device at DD1).

### C2 — Mechanism gates runnable without the device
Day-to-day CI guard while the iPhone is unavailable — mechanism-level assertions, not wall-clock:
- Invalidation counting (extend the `CapturePerformanceTests` pattern: unchanged frames → 0 invalidations stays true as A/B land changes).
- Queue-bound conformance: 1-frame latest-wins capture handoff, single pending analysis, coalesced config pushes (spec §3 queue contract).
- Cadence conformance: D7 intervals respected under synthetic load (locked revalidation 0.5s, degraded 0.1s, field analysis ≥1.0s).
- **Evidence gate**: new tests in the suite, green, documented in the ledger as the standing sim-side net.

### C3 — Cold-start warm-up
First OCR call costs 217–508ms `[device-debug]` (engine load), then ~47ms steady-state.
- Warm the engine at app launch (low-priority dummy recognize) so the first real frame never pays it.
- **Evidence gate**: first-frame-to-first-reading delta, before/after, `[device]` at DD1 (sim proxy check earlier).

### C4 — Cadence policy + the "OCR 30/S" reconciliation (master R8)
The UI footer promises "OCR 30/S"; the measured `.accurate` pass is ~382–397ms `[sim]` (≈2.5fps naive). These cannot both be true naively.
- Define the honest policy: `.fast`-pass rate (10.9ms `[sim]` — device number needed) for live readout vs `.accurate` revalidation cadence; what the user-facing rate claim should actually say.
- Fix whichever is wrong: the cadence, the footer copy, or both. Depends on C1 metrics + DD1 device numbers for both passes.
- **Evidence gate**: policy recorded as a new D-entry in the master registry; UI copy matches measured reality.

### C5 — Device Day 1: the baseline (C owns DD execution, master §9 protocol)
- Prep before plugging in: Release scheme builds clean; benchmarks runnable via `xcodebuild test` on device; Instruments templates chosen.
- Capture: Time Profiler + Allocations + Core Animation FPS during a live tracking+OCR session; Release runs of `DecimalBenchmarkTests` + budget tests; cold-start (C3 verification); 10-minute sustained-tracking thermal soak with thermal-state logging.
- **Evidence gate**: master §8 table gets a measured `[device-release]` column; every gap between measurement and budget becomes a ranked C6 backlog item; Instruments trace files archived; ledger updated.

### C6 — Optimization backlog (LOCKED until C5 delivers)
Ranked by measured cost once the baseline exists. Known candidates from the doc synthesis, to be re-ranked by data:
- `.accurate` pass scheduling (the single largest known cost, ~382–397ms `[sim]`).
- OCR input sizing: ROI crop dimensions + `minimumTextHeight` (grep-confirmed unset in `VisionOCR.swift` and `ScreenFieldAnalyzer.swift` — cheap, potentially large win).
- Detection-pass cost vs its ≤60ms budget; canonical-warp path vs ≤15ms.
- Main-thread work at 120Hz (≤8ms budget) — invalidation audit beyond the fixed storm.
- Allocations/frame + memory growth (from DD1 Allocations capture).
- Rule per item: before-number → change → after-number `[device-release]`, one at a time; ledger row each.

## Device-day requests

C runs the device day itself (C5); A and B submit their trial/fixture requests into the same session (master §9 checklist).

## Non-goals

Speculative optimization (locked by invariant), pipeline-file edits (hook requests only), accuracy changes (WS-B), tracking behavior changes (WS-A).
