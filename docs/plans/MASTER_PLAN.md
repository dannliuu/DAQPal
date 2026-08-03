# DAQPal Master Plan — Correct + Fast, End to End

Created: 2026-08-03 · Branch baseline: `segment-cell-scanner` (top commit `4f9ca85`)
This is the **coordination hub** for all plan-executing agents. Read this file first, every session.

**The one rule that keeps plans from conflicting:** each kind of fact lives in exactly one place.

| Fact | Lives ONLY in |
|---|---|
| What is done / measured / broken | §5 Status Ledger (this file) |
| Settled technical decisions | §3 Decision Registry (this file) |
| Which legacy doc to trust for what | §6 Authority Map (this file) |
| Who may edit which files | §7 Ownership Matrix (this file) |
| Task definitions + evidence gates | The three `ws-*.md` files |

Workstream docs never restate status; legacy docs are **frozen read-only reference** (do not edit, do not delete). This rule exists because the legacy docs rotted exactly by duplicating status (three contradictory test counts inside PROGRESS.md; spec checkboxes open for shipped work).

---

## 1. Mission and Definition of Done

DAQPal points an iPhone camera at a lab instrument, locks onto its display, tracks it, OCRs the reading (including seven-segment faces), validates, and logs time-series CSV. "Works performantly" means all four gates below pass:

| # | Gate | Bar | Evidence required |
|---|---|---|---|
| DoD-1 | Trustworthy lock | False-healthy-lock count = 0 across synthetic motion matrix AND device trials | Trace-based verdict counts (extend the 81-pass methodology); device-day trials |
| DoD-2 | Correct readings | Accepted-measurement accuracy ≥99% on real recorded fixtures (system-level: rejection allowed, wrong-and-accepted is the failure); user's real IR gun readable end-to-end | `RecognitionPipelineTests` on real `dmm_NNN.mov` fixtures; IR-gun live session |
| DoD-3 | Fast on device | Spec budget table (§8 below) met at p95 in **Release** build on physical iPhone; UI 60fps with no visible stutter; cold-start masked by warm-up | `PipelineBudgetTests` (Release), Instruments capture, `PipelineMetrics` p95/p99 |
| DoD-4 | Standing regression net | Full suite green (≥733 baseline) + recorded `.baseline` sweeps + Release budget tests, all passing at every integration gate | CI/test runs logged in §5 |

Until DoD-2's fixtures exist, no synthetic accuracy number may be presented as instrument accuracy (see D6).

---

## 2. Agent Protocol

1. Read this file top to bottom (it is deliberately short enough to always re-read).
2. Claim ONE workstream; open its `ws-*.md`. Consult legacy docs only via §6's map, only for the sections it marks trustworthy.
3. Edit only files your workstream owns (§7). Shared files: only at integration gates (§9).
4. Run the full test suite before and after your session (`xcodebuild test` — Simulator, serial). The suite must be green at session end.
5. End of session: update §5 Status Ledger (what changed, new numbers WITH provenance tags, current test count). If you had to deviate from a decision, add a proposal row to §3 — never silently deviate.
6. Performance numbers: tag every figure `[device-release]`, `[device-debug]`, `[sim]`, or `[host]`. Untagged numbers are invalid. Debug per-pixel Swift is ~50× slower than Release; Simulator OCR is ~10–12× slower than device — neither may ever be quoted as shipping performance.

---

## 3. Decision Registry

Settled decisions. To change one: add a `PROPOSED:` row beneath it with your evidence; the user (or a session with user approval) flips it. Never silently deviate.

| ID | Decision | Evidence | Reopen if |
|---|---|---|---|
| D1 | **Apple Vision (DualPassVisionOCR) is the OCR hot path.** No engine replacement. PP-OCRv5 CoreML conversion is retained on disk as a *potential* offline `.ambiguousDecimal` arbiter only — never per-frame. | PARSeq + doctr-CRNN + PP-OCRv5 Core ML conversions failed or were rejected (OCR_MODEL_COMPATIBILITY.md); decimal loss is a preprocessing-resolution problem, not a vocabulary problem; PP-OCRv5 never benchmarked on-device. | Real-fixture accuracy stays below DoD-2 after WS-B completes AND classical path is exhausted. |
| D2 | **Independent lock verification = `TrackVerifier` (detector corroboration + motion coupling + transit veto).** This is a *deliberate deviation* from the RANSAC/feature-matching architecture recommended by DAQPal_DEEP_RESEARCH_COMPUTER_VISION_ARCHITECTURE.md and remediation plan §5A. | 81-pass bounce trace: 0 LOCKED-while-unverified. No RANSAC/feature path exists in code. | Device validation shows false-healthy-locks, or hold-rate targets (WS-A) prove unreachable with corroboration alone. |
| D3 | **No ML model training for now.** Classical CV first. | User constraint: no datasets available. YOLOv8-class results (99%+) acknowledged but out of scope until a fixture corpus exists. | Fixture corpus + labeling pipeline exist (WS-B/device days create the preconditions). |
| D4 | **Seven-segment path = column-scan segmentation (`SegmentCellScanner`) + `SevenSegmentSampler` recognition + decimal-by-size-ratio**, per SSOCR literature (OCR_SEGMENT_RESEARCH.md). Connected-component labeling is dead for segment faces (21 components, 0 digits on a clean "80.8"). | Measured CC failure; SSOCR precedent; user's IR gun is the target device (Michelson contrast 0.20 — harder than any synthetic render tested). | — |
| D5 | **Performance claims require Release-config, on-device, provenance-tagged measurement.** | All existing device numbers are Debug/`-Onone`; no Instruments profile exists anywhere. | — (this is permanent discipline) |
| D6 | **Synthetic ≠ real.** Synthetic-corpus results may never be cited as real-instrument accuracy (DAQPalTests/Fixtures/README.md guardrail, verbatim). The ≥99% bar is a system property (accept/reject), not a raw OCR rate. | Vision seven-segment raw: 14.6% single-pass / 41.7% dual-pass `[sim, synthetic]` — nowhere near raw 99%; the architecture reaches the bar via rejection + temporal consensus, which only real fixtures can prove. | — |
| D7 | **Cadence values**: acquiring detection 0.2s · locked revalidation 0.5s · degraded/reacquiring 0.1s · stale-tracker timeout 0.75s · field analysis ≥1.0s apart. | SCREEN_TRACKING_IMPLEMENTATION_REPORT.md (2026-08-02) — supersedes ARCHITECTURE.md §9 (2.0s locked) and remediation plan §16's illustrative 1–5Hz. | WS-C cadence tuning (task C4) with before/after device measurements. |
| D8 | **Doc governance**: legacy markdowns frozen read-only; status only in §5; decisions only here; plan files under `docs/plans/` are the only living planning docs. | The staleness post-mortem across 21 docs (see §10). | — |

---

## 4. Workstreams

| WS | File | Mission | Runs in parallel with |
|---|---|---|---|
| A | `ws-a-tracking.md` | Trust the lock: defects, hit-testing, motion matrix, hold rate | B, C |
| B | `ws-b-ocr-accuracy.md` | Read it right: wire the orphaned modules, decimal integrity, segment faces, real baselines | A, C |
| C | `ws-c-performance.md` | Prove it fast, then make it fast: metrics, budgets, Instruments, gated optimization | A, B |

---

## 5. Status Ledger — single source of truth

*(Every agent session appends/edits here. Last reconciled: 2026-08-03, from the four-reader doc synthesis.)*

**Test suite baseline: 733 passed / 0 failed / 2 skipped** `[sim, Debug, serial]` (VALIDATION_FRAMEWORK.md run). PROGRESS.md's 113/116/616 counts are historical snapshots — do not cite.

### Built and wired (trust it)
- Full capture→OCR→validation→CSV pipeline; `ScreenLockPipeline` actor wired inline in `FrameProcessor` drain (6 stages incl. `AppearanceSentinel` 1b, `TrackVerifier` 2b).
- Transit veto: 0 LOCKED-while-unverified across 81-pass bounce trace `[sim rig]`.
- Invalidation storm fixed: 60 unchanged frames → 0 UI invalidations (`CapturePerformanceTests` 10/10).
- Sub-field selection (`NumberBandSplitter` → `WindowFieldAnalyzer` → `WindowSubFieldLayer`); analyzer 6.5ms/analysis `[host? Release]`.
- `SegmentCellScanner` landed (`4f9ca85`) — integration state vs D4 checklist **unverified** (WS-B task B4).

### Built but NOT wired (the orphan list — highest-leverage fixes)
- `DecimalRescue`: zero call sites in `DAQPal/` (grep-verified 2026-08-02). → WS-B B1
- `DisplayFormatInference` → `TemporalConsensus` format prior: `nil` at `MeasurementProcessor.swift:454`. → WS-B B2
- `PipelineMetrics` stage latencies: struct exists, stages unpopulated. → WS-C C1

### Known defects (open)
1. `VisionScreenTracker` recovery re-seed: no proximity/identity gate — lock can migrate to a different object after 5 rejections; re-seed confidence blended with Vision's score. **Top priority** (report §K). → A1
2. `ScreenCandidateDetector` corner-anchor freeze: aspect ratio → ~0, can permanently block lock. → A2
3. `MagneticSnapEngine.release()` suppression bug (can re-grab a user-rejected display); `nil`/`[]` grace-period conflation. → A3
4. `ScreenFieldAnalyzer.numericIsDominant` misclassifies "230 VAC" / "12 PSI" as label; its `numberPattern` regex disagrees with `FormatValidator`. → A4 (+ G1 shared-grammar agenda)
5. Overlay hit-testing uses bounding box (~1.9× quad area at 30° roll — taps miss); `FieldSelectionOverlay` still has the per-frame-read+gesture anti-pattern fixed in `ROISelectionOverlay`. → A5
6. `.5` → `5.0` power-of-ten bug: 7/72 (9.7%) on device benchmark, ALL the `.5` label; leading `•`-glyph discarded by tokenizer; ambiguous-decimal veto fired 0 times (zero-refusal is itself the defect). → B3
7. `TemporalConsensus`: anchor forms from only 2 uncorroborated frames; `.ambiguous` can deadlock indefinitely; European decimal-comma unhandled. → B6

### Measured performance (only real numbers that exist)
- OCR engine call: mean 41.8–52.2ms, p90 ≤64ms `[device-debug]`; cold first call 223–555ms; Simulator mean 510ms.
- Dual-pass `.accurate` pass: ~382–397ms `[sim]` (≈2.5fps if run back-to-back — see conflict ruling R8).
- Touch/render probes: p50 16.7ms, p95 17.7ms, 0 stalls/drops `[device-debug, 60Hz]`.
- Vision accuracy `[sim, synthetic, 192 cases]`: sans 93.8% · seven-seg 41.7% (dual-pass) · fourteen-seg 14.6% · dot-matrix 0%.
- Decimal preservation 90.3%, power-of-ten errors 9.7% `[device-debug, synthetic 72 cases]`.
- **Everything else is UNMEASURED**: capture/tracking/detection/OCR/UI FPS, e2e latency p50/p95/p99, CPU/GPU/memory/allocations, thermal, energy, ALL Release-build behavior. No Instruments profile exists.

### Real-world validation status
**None exists.** HARDWARE_VALIDATION.md: never run (all result cells blank). Real DMM/IR fixtures: zero (`RecognitionPipelineTests` skips). Recorded `.baseline` sweeps: zero (only the self-test fixture). This is the single biggest credibility gap in the project.

### Session log
| Date | Agent/WS | What changed | Suite |
|---|---|---|---|
| 2026-08-03 | (plan creation) | Plan set created; no code changes | 733/0/2 baseline carried |

---

## 6. Authority Map — how to read the legacy docs

Trust levels: **CURRENT** (still authoritative for its column) · **PARTIAL** (use only flagged sections) · **HISTORICAL** (background only — never cite for status).

| Doc | Trust | Authoritative for | Traps |
|---|---|---|---|
| `docs/SCREEN_TRACKING_IMPLEMENTATION_REPORT.md` (2026-08-02) | CURRENT | Tracking subsystem state, TrackVerifier config, cadences, provenance discipline (§J is the model to copy) | §F.3 v1-failure numbers were inferred from overlays (self-flagged §J.15) |
| `ARCHITECTURE.md` | CURRENT | Pipeline structure, root-cause narratives, defect table §9/§10 | §9 "BLOCKING" framing superseded by later 08-01 transit-veto entry in the same section; locked-revalidation 2.0s superseded (D7) |
| `IMPLEMENTATION_NOTES.md` | PARTIAL | Sub-field/InstrumentProfile design decisions (last sections); dated round history | 07-27→08-02 gap: the entire TrackVerifier arc is missing here; early "deferred" claims superseded in-file |
| `intelligent_screen_selection_tracking_ocr_spec.md` | PARTIAL | Performance budget tables (§2–3, §15–16A — the *targets*); pipeline concepts; §25 sub-field record | **All phase checkboxes stale.** Never mentions TrackVerifier. Gate 2A marked open but drag-jitter resolved 07-28. OCR-engine framing (§12) superseded by D1 |
| `DAQPal_SCREEN_TRACKING_REMEDIATION_PLAN.md` | PARTIAL | Gate methodology, §5A research matrix (as the record of what D2 deviated from) | Checkbox state unreliable in BOTH directions (done-but-unchecked and vice versa); §16 cadences superseded (D7) |
| `PROGRESS.md` | HISTORICAL | Build-order narrative | Internally contradicts itself (Gate 14 wired vs not; 113/116/616 counts); "OCR benchmarking deferred" false |
| `OCR_RESEARCH.md` (07-23) | CURRENT | Vision API limits (closed-vocab impossible), benchmark method, training-data strategy | All numbers `[sim, synthetic]`; "PP-OCRv6" naming here/PROGRESS is wrong — only PP-OCRv5 exists in this repo (R7) |
| `OCR_MODEL_COMPATIBILITY.md` | CURRENT | Model conversion outcomes, resolution root-cause | ALL latencies are M1 Mac `[host]`, not phone |
| `OCR_DEVICE_BENCHMARK.md` | CURRENT | The only real device OCR numbers; `.5` failure anatomy | Parser-layer-only scoring; `DualPassVisionOCR.swift` header's ~382ms is `[sim]`, don't cite as device |
| `OCR_SEGMENT_RESEARCH.md` (08-02) | CURRENT | Segment-face plan (D4), contrast-0.20 target-device facts | Whether `SegmentCellScanner` implements all of it: unverified (B4) |
| `DAQPal_DEEP_RESEARCH_COMPUTER_VISION_ARCHITECTURE.md` | HISTORICAL | The False-Healthy-Lock metric definition; the RANSAC road-not-taken (D2) | Undated, no code grounding |
| `DAQPal_Context_Aware_Device_Seven_Segment_Detection_Research_Prompt.md` | HISTORICAL | Possible future device-classification layer | Unexecuted charter; out of scope for this plan |
| `HARDWARE_VALIDATION.md` | CURRENT | The manual device-day procedure (§4 gates before §5 metrics) | Never run; `DigitSegmenter` description predates `SegmentCellScanner` |
| `VALIDATION_FRAMEWORK.md` | PARTIAL | Harness design (`ReadingVerdict` taxonomy, seeded determinism, license-gated corpus) | Claims "RESULTS appended" + "complete and verified" — **no sweep baselines exist on disk**; treat those claims as aspiration |
| `DAQPalTests/Fixtures/README.md` | CURRENT | Fixture naming/recording protocol; the synthetic≠real guardrail (D6) | — |
| `DAQPalTests/Baselines/BASELINES.md` | CURRENT | Baseline format + re-record mechanism | Example numbers are illustrative, NOT recorded results |
| `Visual_Instrument_Data_Logger_Agent_Development_Specification.md` | PARTIAL | Product requirements, ≥99% system bar, MVP exclusions, M1–7 design | Roadmap positions long since passed |
| `Design_notes/design_handoff_daqpal_ios/README.md` | PARTIAL | UI tokens/layout | "OCR 30/S" footer contradicts measured OCR latency (R8); 0.6 lock threshold unverified vs code |
| `README.md` (root) | CURRENT | Pitch + license (PolyForm Noncommercial 1.0.0) | Future-work list stale |
| `Design_notes/README.md` | HISTORICAL | — | Drifted duplicate of root README, missing the License section. Do not use (do not delete either) |
| `LICENSE.md` | CURRENT | License terms | — |

---

## 7. File-Ownership Matrix

Exclusive write ownership. Reading is unrestricted. Editing another workstream's files or a shared file outside a gate is a plan violation.

| Owner | Paths |
|---|---|
| **WS-A** | `DAQPal/Tracking/*` (ScreenLockPipeline, VisionScreenTracker, TrackVerifier, AppearanceSentinel, MagneticSnapEngine, ScreenCandidateDetector, ScreenFieldAnalyzer, QuadTracker…) · `DAQPal/Camera/DisplayPose3D.swift`, `PoseTrajectory.swift` · `DAQPal/UI/ROISelectionOverlay.swift`, `FieldSelectionOverlay.swift`, `PanGestureCatcher.swift`, `CoordinateDebugOverlay.swift` · matching test files |
| **WS-B** | `DAQPal/OCR/*` (DecimalRescue, SegmentCellScanner, NumberBandSplitter, WindowFieldAnalyzer, VisionOCR/DualPass, OCRManager…) · `DAQPal/Processing/*` (MeasurementProcessor, FormatValidator, TemporalConsensus, DisplayFormatInference, ConfidenceEngine…) · `DAQPal/Corpus/*` · `DAQPal/Data/*` · `DAQPalTests/Fixtures/`, `DAQPalTests/Baselines/` · matching test files |
| **WS-C** | `DAQPal/Instrumentation/*` · `DAQPal/App/GestureLatencyProbe.swift`, `RenderCadenceProbe.swift` · `DAQPalTests/PipelineBudgetTests.swift`, `CapturePerformanceTests.swift` · `DAQPal/UI/PipelineDebugOverlay.swift` |
| **SHARED** (gate-only edits) | `DAQPal/App/AppState.swift`, `InteractionState.swift`, `DebugDemo.swift` · `DAQPal/Camera/CaptureStack.swift`, `FrameProcessor.swift`, `SyntheticFrameSource.swift` · `DAQPal/UI/CameraCaptureScreen.swift` · `DAQPalTests/Support/*` (shared rig) · Xcode project file |

WS-C never edits A/B-owned pipeline files directly: it specifies instrumentation hooks ("hook requests" listed in `ws-c-performance.md`), and the owning workstream lands them at the next gate.

`ScreenFieldAnalyzer` (A-owned) and `FormatValidator` (B-owned) must converge on ONE numeric-token grammar — G1 agenda item, decided jointly, recorded here as a D-entry when settled.

---

## 8. Performance Budget Table (the targets — from spec §2–3, unchanged)

p95, Release, on device. These are DoD-3's bar; WS-C task C2 turns them into automated gates.

| Stage | Budget |
|---|---|
| Gesture callback | ≤2ms/touch event |
| Overlay geometry update | ≤1ms/frame |
| UI main-thread total | ≤8ms @120Hz · ≤16ms @60Hz |
| Capture delivery→available | ≤5ms/frame |
| Tracking step (locked) | ≤10ms/frame |
| Detection pass | ≤60ms (adaptive 0.1–2s cadence) |
| Canonical warp | ≤15ms (analysis-only, never per-frame) |
| Field analysis | ≤200ms (≥1s apart) |
| OCR per field | ≤30ms (adaptive 5–30fps) |
| End-to-end capture→structured value | ≤150ms |
| Cadence targets | tracking 30–60+ · OCR 5–30 · UI 60+ · detection 5–15 fps |

Note: the ≤30ms OCR budget vs the measured ~42–52ms `[device-debug]` engine call is expected to close partly via Release config — measure before optimizing (C5 before C6).

---

## 9. Integration Gates & Device Days

**Gate protocol (G1, G2, …):** all workstreams pause fan-out; full suite green; shared-file edits + hook requests land sequentially (A → B → C); ledger reconciled; grammar/decision agenda items settled; then fan back out.

**Device Day protocol (DD1, DD2, …)** — batched for occasional device access, ~2–3h each:
1. Prep (before the device is plugged in): Release scheme builds; benchmark targets runnable via `xcodebuild`; fixture shot-list ready.
2. `HARDWARE_VALIDATION.md` §4 coordinate gates first (they gate all §5 metrics).
3. Release-build benchmark suite: `DecimalBenchmarkTests`, budget tests, cold-start.
4. First-ever Instruments captures: Time Profiler + Allocations + Core Animation FPS during live tracking.
5. Record fixtures: `dmm_NNN.mov` + ground-truth CSV per `DAQPalTests/Fixtures/README.md`; IR-gun low-contrast set for D4.
6. Live tracking trials (WS-A motion scenarios) + IR-gun end-to-end session.
7. Debrief: every number → §5 with `[device-release]` tags; baselines recorded and committed; DD report appended below §5.

**Milestones:**
- **M0 — snapshot**: commit the current working tree on `segment-cell-scanner` (needs Daniel's go-ahead — large uncommitted surface), record suite count. Nothing else starts until the baseline is committed.
- **M1 — wiring + defect burn-down** (parallel): A1–A5 · B1–B3 · C0–C3.
- **G1**, then **DD1** (Instruments baseline, fixtures, hardware-validation run).
- **M2 — depth** (parallel): A6–A8 · B4–B7 · C4–C6 (optimization now unlocked by DD1 baseline).
- **G2**, then **DD2** (acceptance measurement vs §8 + real-fixture accuracy vs DoD-2).
- **Acceptance**: all four DoD gates evidenced in §5.

---

## 10. Conflict Rulings (legacy contradictions, resolved)

| # | Contradiction | Ruling |
|---|---|---|
| R1 | Gate 14 "wired and exercised live" (PROGRESS exec summary) vs "not built" (same file's gate table) | **Wired.** Report §A + ARCHITECTURE §9 confirm; PROGRESS gate table stale |
| R2 | Test counts 113 / 116 / 616 / 733+ | **733/0/2** is the baseline (latest, VALIDATION_FRAMEWORK run) |
| R3 | Spec Gate 2A drag-jitter open | **Resolved 2026-07-28** (ARCHITECTURE §2–3); spec checkbox stale |
| R4 | Decimal work "done" (files landed) vs benchmark unchanged | Both true: code landed, **bug remains** — rescue never wired (orphan list). The +506-line FormatValidator rewrite measurably changed nothing (byte-identical re-run) |
| R5 | RANSAC/feature-matching recommended vs TrackVerifier built | Deliberate deviation → **D2** |
| R6 | Cadences: 2.0s vs 0.5s locked revalidation; plan §16's 1–5Hz | **D7** (report values) |
| R7 | "PP-OCRv6" (PROGRESS/spec) vs PP-OCRv5 (everything measured) | **PP-OCRv5** is what exists; "v6" was aspiration/typo — never cite v6 |
| R8 | UI footer "OCR 30/S" vs measured ~382–397ms `.accurate` pass | Physically incompatible if naive. Resolution path = WS-C C4: honest cadence policy (fast-pass rate vs accurate-pass revalidation), then fix either the pipeline or the footer copy |
| R9 | VALIDATION_FRAMEWORK "RESULTS appended… every number measured" | **No sweep results exist on disk** (only self-test baseline). Claims are aspirational; B7 makes them real |
| R10 | Sub-field components "complete and verified" (VALIDATION_FRAMEWORK) | Code exists + unit-tested, but files are untracked/uncommitted — "verified" overstated until M0 commit + review |
| R11 | Snap thresholds 0.70/0.80/0.90 in spec | Unverified against `SnapTuning` source (only 0.60 detection confirmed). Verify in A-audit before citing |
| R12 | Design_notes/README vs root README | Root wins (has License). Drifted copy noted in §6; left in place per no-delete rule |
| R13 | ≥99% target vs 41.7% seven-segment | Not a contradiction: different metrics (system accept/reject vs raw OCR) — but the bridge is **unproven until real fixtures exist** (D6, DoD-2) |
| R14 | HARDWARE_VALIDATION describes fixed-pitch `DigitSegmenter` | Predates `SegmentCellScanner` (`4f9ca85`); procedure still valid, component description stale |
