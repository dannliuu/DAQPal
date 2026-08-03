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

### C0 — Budget-test audit
`DAQPalTests/PipelineBudgetTests.swift` (639 lines) is the only Release-build budget assertion in the repo and is documented in **no** markdown (BASELINES.md points at it as the sole source of shipping-latency truth).
- Read it; inventory which of master §8's budgets it actually asserts, in which build config, against which harness.
- **Evidence gate**: coverage table (budget → asserted? config? gap?) reported to the master ledger. This is the map for C2.

### C1 — Populate `PipelineMetrics`
The stage enum exists (`.capture .tracking .detection .analysis .ocr .endToEnd`, p95/p99) with stages unpopulated.
- C implements: aggregation, ring-buffer storage, test-accessible export, `PipelineDebugOverlay` live display.
- **Hook requests** (owners land at G1): `FrameProcessor` drain timestamps (shared file — gate edit); `ScreenLockPipeline` per-stage spans (WS-A); `MeasurementProcessor` OCR/validation spans (WS-B).
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
