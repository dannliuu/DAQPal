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
| Task definitions + evidence gates | The five `ws-*.md` files |

Workstream docs never restate status; legacy docs are **frozen read-only reference** (do not edit, do not delete). This rule exists because the legacy docs rotted exactly by duplicating status (three contradictory test counts inside PROGRESS.md; spec checkboxes open for shipped work).

---

## 1. Mission and Definition of Done

DAQPal points an iPhone camera at a lab instrument, locks onto its display, tracks it, OCRs the reading (including seven-segment faces), validates, and logs time-series CSV. "Works performantly" means all five gates below pass:

| # | Gate | Bar | Evidence required |
|---|---|---|---|
| DoD-1 | Trustworthy lock | False-healthy-lock count = 0 across synthetic motion matrix AND device trials | Trace-based verdict counts (extend the 81-pass methodology); device-day trials |
| DoD-2 | Correct readings | Accepted-measurement accuracy ≥99% on real recorded fixtures (system-level: rejection allowed, wrong-and-accepted is the failure); user's real IR gun readable end-to-end | `RecognitionPipelineTests` on real `dmm_NNN.mov` fixtures; IR-gun live session |
| DoD-3 | Fast on device | Spec budget table (§8 below) met at p95 in **Release** build on physical iPhone; UI 60fps with no visible stutter; cold-start masked by warm-up | `PipelineBudgetTests` (Release), Instruments capture, `PipelineMetrics` p95/p99 |
| DoD-4 | Standing regression net | Full suite green (**872 baseline — see §5, never a hardcoded number**) + recorded `.baseline` sweeps + Release budget tests, all passing at every integration gate | CI/test runs logged in §5 |
| DoD-5 | Honest to the user | Wrong-and-accepted rate = 0 on every recorded fixture, AND every refusal is legible in-app at the moment it happens | `wrongAcceptedRate` in `ValidationHarness`; UI test asserting a refusal is visible during live aiming |

Until DoD-2's fixtures exist, no synthetic accuracy number may be presented as instrument accuracy (see D6).

**Yield floor — DoD-1 and DoD-2 are both trivially satisfied by a system that never locks and never accepts.** Today only 8 of 81 bounce passes reach LOCKED, so "0 false-healthy-locks of 81" is really "0 of 8 locked passes" — statistically empty. Neither gate passes unless reported together with a yield figure: locked-fraction ≥ X% of trial duration, and accepted-fraction ≥ Y% of legible frames. Record X and Y in §5 before optimizing either gate. Restate DoD-1 as a *rate with a confidence bound over a stated exposure*, not a count.

---

## 2. Agent Protocol

1. Read this file top to bottom (it is deliberately short enough to always re-read).
2. Claim ONE workstream; open its `ws-*.md`. Consult legacy docs only via §6's map, only for the sections it marks trustworthy.
3. Edit only files your workstream owns (§7). Shared files: only at integration gates (§9).
4. Run the full test suite before and after your session, **serially**, with exactly:
   ```
   xcodebuild test -scheme DAQPal \
     -destination 'platform=iOS Simulator,name=iPhone 16e,OS=18.4' \
     -resultBundlePath /tmp/daqpal_run.xcresult -parallel-testing-enabled NO
   xcrun xcresulttool get test-results tests --format json --path /tmp/daqpal_run.xcresult
   ```
   Read counts **only** from `xcresulttool`, never by grepping stdout — the serial and parallel runners print different formats and this project has miscounted before. Note also that xcodebuild's summary line counts *assertion* failures while the per-case lines count *test* failures; they legitimately differ (the 2026-08-03 run: 5 cases, 7 assertions). The suite must be green at session end.
   The scheme is shared at `DAQPal.xcodeproj/xcshareddata/xcschemes/DAQPal.xcscheme` (added 2026-08-03) — do not rely on Xcode autocreation. **The iPhone 16 Pro simulator named in the 2026-08-03 baseline no longer exists on the dev machine; iPhone 16e / iOS 18.4 is the current equivalent.**
5. End of session: update §5 Status Ledger (what changed, new numbers WITH provenance tags, current test count). If you had to deviate from a decision, add a proposal row to §3 — never silently deviate.
6. Performance numbers: tag every figure `[device-release]`, `[device-debug]`, `[sim]`, or `[host]`. Untagged numbers are invalid. Debug per-pixel Swift is ~50× slower than Release; Simulator OCR is ~10–12× slower than device — neither may ever be quoted as shipping performance.
7. **Stopping conditions.** Stop and report rather than continue if: (a) a fix would require editing a file your workstream does not own, (b) the code contradicts the plan, (c) you have made three failed attempts at the same defect, or (d) the task's success predicate is not machine-checkable. Never silently widen scope.
8. **Session report.** Every session ends with: changed files · tests run + exact counts · new defects found · evidence generated (with provenance tag) · known limitations · follow-up tasks. Append to §5's session log.
9. **Unowned files.** Any file not listed in §7 is SHARED by default and editable only at a gate. If you discover one, add it to §7 in the same session.

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
| D9 | **`ConfidenceEngine.minimumFusedConfidence` = 0.15** — a POLICY floor on the fused product, refusing as `.lowFusedConfidence`. It is `lowOCRConfidenceThreshold × decimalVetoThreshold`, i.e. the OCR gate minimum degraded by one further gate minimum: **two gates at their minimum is the boundary and passes; anything worse is refused.** `gatePermittedInfimum` (0.0375) is retained separately, and a test asserts the floor sits strictly above it — a floor at or below the infimum refuses nothing. | Chosen, not derived: deriving was tried first (0.0375) and is a tautology — every gate-passing reading clears the infimum by construction, so the documented leak (ocr 0.35 × decimal 0.50 × cross-check 0.51 = **0.0892**) sailed through. Measured refusal rate over the 360-combination gate-permitted sweep: **0% at 0.0375 · 22.8% at 0.15 · 49.7% at 0.25**. 0.25 was tried and rejected — it cuts into a mid-range with no real-instrument data behind it, and the errors are asymmetric the other way than first assumed: every CSV row carries `confidence`, so a low floor stays recoverable by filtering while a high floor destroys data never captured. | **Re-tune UP against DoD-2's real fixtures.** Up is the safe direction to defer. Report the refusal rate alongside accuracy, never accuracy alone, or a floor that quietly refuses everything reads as an accuracy win. NOTE: this is NOT the main defence against wrong-and-accepted — the measured `.5` power-of-ten failures carried 0.75 confidence, far above any sane floor. B3 owns that class. |

---

## 4. Workstreams

| WS | File | Mission | Runs in parallel with |
|---|---|---|---|
| A | `ws-a-tracking.md` | Trust the lock: defects, hit-testing, motion matrix, hold rate | B, C, D, E |
| B | `ws-b-ocr-accuracy.md` | Read it right: wire the orphaned modules, decimal integrity, segment faces, real baselines | A, C, D, E |
| C | `ws-c-performance.md` | Prove it fast, then make it fast: metrics, budgets, Instruments, gated optimization | A, B, D, E |
| D | `ws-d-experience.md` | Make the promise legible: refusal visible during live aiming, review/correction surface, persistence and interruption, export integrity | A, B, C, E |
| E | `ws-e-recorded.md` | The recorded high-accuracy path: repair import buffering + the Photos/Files gap, frame-quality selection, then decide on high-frame-rate capture on evidence | A, B, C, D |

**WS-D and WS-E added 2026-08-03** by the executability audit (`EXECUTABILITY_AUDIT.md` Deliverable G). Rationale: 24 of 81 production files matched no ownership row, and every one of them is user-facing or capture/ingest. Neither concern fits A/B/C's missions, and under §7's rule the whole surface was un-editable. D and E share almost no files with A/B/C, so parallelism is unaffected. **WS-E calls recognition modules; it never edits them (those stay WS-B's).**

---

## 5. Status Ledger — single source of truth

*(Every agent session appends/edits here. Last reconciled: 2026-08-03, from the four-reader doc synthesis.)*

**Test suite (2026-08-03, after B0 + D9, via `xcresulttool`): 872 passed / 1 failed / 2 skipped / 1 expected failure = 876 cases** `[sim iPhone 16e iOS 18.4, Debug, serial]`.

*Supersedes the earlier "857 passed / 864 cases `[sim iPhone 16 Pro]`" figure, for two reasons and neither is a regression: (a) the iPhone 16 Pro simulator no longer exists on the dev machine, so the run moved to iPhone 16e; (b) the 857 figure was obtained by grepping stdout, and that log **double-prints** its per-case lines — which is precisely why §2 rule 4 now forbids stdout grepping and mandates `xcresulttool`. The failing set is byte-identical across both runs.* Failures: 4× `SegmentCellScannerTests` (`:87` nil decimal positions for DSEG7 "0.001"/"99.9"/"100.0"; `:131` wrong position on inverted preset; `:173` "99.9" reconstructed as "000"; `:200` proportional-face wrong position) → WS-B B4; 1× `DragLatencyUITests.swift:82` (5 gesture callbacks where >10 expected — matches the documented simulator-only starvation pattern) → WS-A triage. The 2 skips are the known `RecognitionPipelineTests` fixture skips. Historical counts — 733/0/2 (VALIDATION_FRAMEWORK.md), 113/116/616 (PROGRESS.md) — are superseded; do not cite.

### Built and wired (trust it)
- Full capture→OCR→validation→CSV pipeline; `ScreenLockPipeline` actor wired inline in `FrameProcessor` drain (6 stages incl. `AppearanceSentinel` 1b, `TrackVerifier` 2b).
- Transit veto: 0 LOCKED-while-unverified across 81-pass bounce trace `[sim rig]`.
- Invalidation storm fixed: 60 unchanged frames → 0 UI invalidations (`CapturePerformanceTests` 10/10).
- Sub-field selection (`NumberBandSplitter` → `WindowFieldAnalyzer` → `WindowSubFieldLayer`); analyzer 6.5ms/analysis `[host? Release]`.
- `SegmentCellScanner` landed (`4f9ca85`) — audit 2026-08-03: algorithm checklist mostly implemented (gap-tolerant column scan ✓ `SegmentCellScanner.swift:288-313`; decimal-by-size ✓ `:316,398-427,494-499`; row-splitting partial `:216-264`) but **orphaned and failing 4 of its own tests** — see orphan list and defects (WS-B B4).

### Built but NOT wired (the orphan list — highest-leverage fixes; all audit-confirmed 2026-08-03)
- `DecimalRescue`: zero production call sites (12 grep hits; every hit outside its own file is a comment). → WS-B B1
- `DisplayFormatInference` → `TemporalConsensus` format prior: still literally `formatPrior: nil,` at `MeasurementProcessor.swift:454`; `DisplayFormatInference` unused in the live path. → WS-B B2
- `SegmentCellScanner`: **zero production call sites** (all 6 grep hits are self-references) — the DecimalRescue disease repeating on the newest module, which also has 4 failing unit tests. → WS-B B4
- `PipelineMetrics`: **half-wired**, not unpopulated — real spans recorded for `.tracking` (`VisionScreenTracker.swift:244,259,309`), `.detection` (`ScreenCandidateDetector.swift:199`), `.analysis` (`ScreenFieldAnalyzer.swift:101`, `DAQPal/Tracking/PerspectiveNormalizer.swift:70` (WS-A-owned — verify, do not duplicate), `NumberBandSplitter.swift:120`, `SegmentCellScanner.swift:217`); `.capture`/`.ocr`/`.endToEnd` never recorded anywhere; and recording is **disabled by default outside DEBUG** (`PipelineMetrics.swift:269-278`), so Release measures nothing without an explicit enablement path. → WS-C C1

### Known defects — audit-corrected 2026-08-03

**Closed — already fixed in code, verified by read-only audit (ARCHITECTURE.md §9's defect table is stale on all three; A1–A3 are now confirm-and-close, not implement):**
1. ~~`VisionScreenTracker` recovery re-seed unguarded~~ — `TrackedQuadGate.admit()` gates re-seeds through `QuadSanity.isOrientationContinuous` + `isPlausibleReseed` (bbox-IoU / size-scaled center distance) — `VisionScreenTracker.swift:506-553`; tests `QuadTrackerTests.swift:582,646,668`.
2. ~~`ScreenCandidateDetector` corner-anchor freeze~~ — position-based anchor replaced by shape-derived `uprightLabeling(of:)` + continuity relabeling — `ScreenCandidateDetector.swift:487-578`, `ScreenQuad.swift:170-183`.
3. ~~`MagneticSnapEngine.release()` re-grab + `nil`/`[]` conflation~~ — dedicated `detectorID` suppression channel (`MagneticSnapEngine.swift:149-162, 259-276`); `nil`-vs-empty handled (`:216-253`); tests `MagneticSnapEngineTests.swift:823,907`.

**Open — audit-confirmed live, with anchors:**
4. Analyzer/validator grammar mismatch: `ScreenFieldAnalyzer.numberPattern` (`ScreenFieldAnalyzer.swift:352-353`) omits `,` while its doc comment (`:324-328`) claims exact parity with `FormatValidator` (`FormatValidator.swift:542-543`); `numericIsDominant` misclassifies "230 VAC" / "12 PSI". → A4 (+ G1 shared-grammar agenda)
5. Overlay bbox hit-testing: `FieldSelectionOverlay.swift:132,144-159` uses a `Rectangle()` contentShape over `OverlayQuadGeometry.boundingRect` (`PipelineDebugOverlay.swift:169-196`) — ~1.9× quad area at 30° roll; per-frame-read+gesture anti-pattern also still present. → A5
6. `.5` → `5.0` power-of-ten bug: `FormatValidator.isSeparator` accepts only `.`/`,` (`FormatValidator.swift:549-551`, regex `:542-543`), discarding bullet-like glyphs; 7/72 (9.7%) on device benchmark; zero refusals fired. → B3
7. ~~`SegmentCellScanner` decimal-position/reconstruction logic bugs — 4 failing tests~~ — **CLOSED 2026-08-03 (B0)**. Root cause was the row-band splitter (`:247-264`): an intra-glyph trough is indistinguishable from an inter-line gap, so one digit line was cut into two bands. Fixed by keeping the projection as a *seed-window* finder and merging over-split bands by run geometry. Note the audit's original prescription — "delete the row-projection pass, column-scan the whole crop" — was **measured to be wrong**: on `Fixtures/ir_gun_display.png` it collapses to one run covering the whole image, destroying the `90.0` reading that works today.

10. **NEW — `SegmentCellScanner`'s safety property is FALSE, and was already false at HEAD.** Measured 2026-08-03 by a 600-case both-version differential (30 literals × 4 glyph styles × 5 presets, both scanners on byte-identical buffers): **HEAD reports 38 wrong decimal positions out of 600**; the current tree reports 13. Not only under degradation — `sans/clean "1234"` (no decimal point, undegraded) reports position 1 because a glyph baseline serif scores as the separator. The guarding test (`testNeverReportsAWrongPositionAcrossPresets`) covers only 4 seven-segment literals and structurally cannot observe any of it. A wrong position is a silent factor-of-ten error in exported data. **This is larger than B0 and needs its own task.** Two specific regressions remain unfixed and report a position where HEAD refused: `333.3`/moderate-inverted (the crop-edge filter removes a border run, clearing `.fragmented` while a spurious run remains) and `9.99`/fourteenSegment/moderate-inverted (merge accepts against an already-inflated reference count). Evidence is synthetic only. → WS-B, new task

11. **REVERTED, do not re-attempt without a differential** — a peel-provenance filter (prefer native separator runs over peeled ones) recovered the proportional-face dot but converted **7 of HEAD's refusals into wrong positions**. Reproducible on `sevenSegment/hard "000"`: two candidates, filter drops the peeled one, `separatorCount` 2→1, phantom decimal on an integer reading. Structural, not tuning: provenance is evidence about *segmentation*, and whether the true dot fuses is a property of the optics, so nativeness systematically selects an impostor when any other baseline-hugging mark survives. Reasoning is recorded in the peel-policy comment in `SegmentCellScanner.swift`.
8. `TemporalConsensus`: anchor forms from only 2 uncorroborated frames; `.ambiguous` can deadlock indefinitely; decimal-comma unhandled. → B6
9. `DragLatencyUITests.swift:82` failing (5 gesture callbacks vs >10) — likely the documented simulator-only gesture starvation; verify on device at DD1 or quarantine with written justification. → A triage

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
| 2026-08-03 | (plan creation) | Plan set created; no code changes | 733/0/2 carried (superseded below) |
| 2026-08-03 | Pre-flight audit (read-only, 6 agents) | Verified plan vs code: R11 closed; defects 1–3 already fixed; `SegmentCellScanner` orphaned + 4 failing tests; `PipelineMetrics` half-wired and DEBUG-only by default; 0/10 budget figures asserted in `PipelineBudgetTests`; suite re-measured; new doc `DAQPal_DEVICE_CONTEXT_RESEARCH.md` discovered. No code changes | **857/5/2** `[sim iPhone 16 Pro, Debug]` |
| 2026-08-03 | Executability audit (22 agents + adversarial verification) | Produced `EXECUTABILITY_AUDIT.md` + `NEXT_SESSION_PROMPT.md`. Found only 2 of 22 tasks executable as written. **New blockers, all verified directly:** (1) tracking stack off by default (`ScreenLockPipeline.swift:126`), so DoD-1's evidence guards an unshipped path; (2) no fused-confidence floor — `accepted: true` possible at ≈0.089 (`ConfidenceEngine.swift:117,141`); (3) 24/81 files unowned; (4) no image-conditioning layer between sensor and Vision (`VisionOCR.swift:48-58` reads the raw frame); (5) only 5 of 9 `RejectionReason` cases reachable by default; (6) **Release test build fails** — `ENABLE_TESTABILITY = NO` in Release vs 54 `@testable` files, so DoD-3/C5 are hard-blocked; (7) the iPhone 16 Pro simulator no longer exists on the dev machine. Plan set updated: DoD-5 + yield floor, exact test command, §2 rules 7–9, WS-D/WS-E, ownership default rule, milestone DAG, two Authority Map path fixes, `CLAUDE.md` reclassified. Shared scheme added. **Disproved** the earlier theory that `SegmentCellScanner`'s `:173` failure was a sampler-polarity mismatch — root cause is the row-band splitter (`:247-264`) | **855/5/2 + 1xf** `[sim iPhone 16e, Debug, serial]` — same 5 failures, no regression |
| 2026-08-03 | B0 (K1) — WS-B | Fixed all 4 `SegmentCellScannerTests` (row-band splitter → seed-window + geometry merge). Added `ConfidenceEngine.minimumFusedConfidence` (D9, PROPOSED — does not close the leak, see registry) and `RejectionReason.lowFusedConfidence`. **Fixed a real pre-existing bug in `TemporalFilter.consistency`**: its documented contract said "1.0 while the window is too small to judge" but the code returned live scores from one sample onward, which is the temporalFactor leak. **Reverted** a peel-provenance filter after a 3,824-case adversarial sweep measured it converting 7 refusals into wrong positions (defect 11). Discovered defect 10: the safety property is already false at HEAD (38 wrong / 600). `SegmentCellScanner` still has ZERO production call sites — wiring remains B4 | **870 passed / 1 failed / 2 skipped / 1 xf = 874** `[sim iPhone 16e iOS 18.4, Debug, serial]`. Only failure is `DragLatencyUITests` (out of scope, WS-D). DAQPalTests: 0 failures |
| 2026-08-03 | D9 — WS-B | Set the fused-confidence floor to the POLICY value **0.15** (was the derived 0.0375, which refused nothing by construction). Split the constant in two: `gatePermittedInfimum` keeps the derivation, `minimumFusedConfidence` is the policy, and a test pins the floor strictly above the infimum. The documented leak (0.0892) is now refused and has a named regression guard. Measured over-refusal cost is **reported** by the suite (82/360 = 22.8%) rather than assumed. Corrected the test-file header, which had argued no constant could catch the marginal-conjunction case — true only for a floor constrained to refuse nothing, which is a tautology. Also removed a guarantee I had written that measurement disproved ("perfect OCR is never floor-refused": ocr 1.0 × temporal 0.5 × decimal 0.5 is the digits-certain/magnitude-unknown shape the floor SHOULD refuse) | **872 passed / 1 failed / 2 skipped / 1 xf = 876** `[sim iPhone 16e iOS 18.4, Debug, serial]`. DAQPalTests: 0 failures. **Blast radius discharged:** all 22 acceptance assertions outside `ConfidenceEngineTests` enumerated; only the 6 asserting `accepted == true` can be affected (a floor only turns accept→reject). Their fused products are 0.90 / 0.54 / 0.90 / 0.90 / 0.63 / 0.90 — tightest margin 0.54, i.e. **3.6× headroom** over the 0.15 floor. `DecimalBenchmarkTests` flips 0 readings at any floor value: it drives `FormatValidator` directly and has zero references to `ConfidenceEngine`/`MeasurementProcessor`/`.fuse(`, so the result is structural, not incidental |

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
| `Design_notes/design_handoff_daqpal_ios/Visual_Instrument_Data_Logger_Agent_Development_Specification.md` | PARTIAL | Product requirements, ≥99% system bar (**line 2087**), MVP exclusions, M1–7 design, 240 FPS rationale (§21 — temporal resolution, NOT blur reduction) | Roadmap positions long since passed. **Path corrected 2026-08-03: this is NOT at repo root** |
| `Design_notes/design_handoff_daqpal_ios/README.md` | PARTIAL | UI tokens/layout | "OCR 30/S" footer contradicts measured OCR latency (R8); 0.6 lock threshold unverified vs code |
| `README.md` (root) | CURRENT | Pitch + license (PolyForm Noncommercial 1.0.0) | Future-work list stale |
| `Design_notes/README.md` | HISTORICAL | — | Drifted duplicate of root README, missing the License section. Do not use (do not delete either) |
| `LICENSE.md` | CURRENT | License terms | — |
| `DAQPal_DEVICE_CONTEXT_RESEARCH.md` | UNREVIEWED | Discovered 2026-08-03 by the pre-flight audit — not part of the original 21-doc synthesis. Corroborates `SnapTuning` values (`:133-142`) | Needs an authority-review pass before citing it for anything beyond the threshold corroboration |
| `CLAUDE.md` | CURRENT | Skill routing for the gstack toolchain the owner actively uses | **Reclassified 2026-08-03** (was wrongly marked UNTRUSTED). It is 12 lines of gstack skill routing, authored by the owner's tooling. The prior classification would have made agents refuse the owner's own tools |

---

## 7. File-Ownership Matrix

Exclusive write ownership. Reading is unrestricted. Editing another workstream's files or a shared file outside a gate is a plan violation.

| Owner | Paths |
|---|---|
| **WS-A** | `DAQPal/Tracking/*` (ScreenLockPipeline, VisionScreenTracker, TrackVerifier, AppearanceSentinel, MagneticSnapEngine, ScreenCandidateDetector, ScreenFieldAnalyzer, QuadTracker…) · `DAQPal/Camera/DisplayPose3D.swift`, `PoseTrajectory.swift` · `DAQPal/UI/ROISelectionOverlay.swift`, `FieldSelectionOverlay.swift`, `PanGestureCatcher.swift`, `CoordinateDebugOverlay.swift` · matching test files |
| **WS-B** | `DAQPal/OCR/*` (DecimalRescue, SegmentCellScanner, NumberBandSplitter, WindowFieldAnalyzer, VisionOCR/DualPass, OCRManager…) · `DAQPal/Processing/*` (MeasurementProcessor, FormatValidator, TemporalConsensus, DisplayFormatInference, ConfidenceEngine…) · `DAQPal/Corpus/*` · `DAQPal/Data/*` · `DAQPalTests/Fixtures/`, `DAQPalTests/Baselines/` · matching test files |
| **WS-C** | `DAQPal/Instrumentation/*` · `DAQPal/App/GestureLatencyProbe.swift`, `RenderCadenceProbe.swift` · `DAQPalTests/PipelineBudgetTests.swift`, `CapturePerformanceTests.swift` · `DAQPal/UI/PipelineDebugOverlay.swift` |
| **WS-D** | `DAQPal/UI/*` **except** `PipelineDebugOverlay.swift`, `CoordinateDebugOverlay.swift`, `ROISelectionOverlay.swift`, `FieldSelectionOverlay.swift`, `PanGestureCatcher.swift`, `CameraCaptureScreen.swift` (i.e. `CaptureHeaderView`, `FormatConfigurationSheet`, `LiveReadingBadge`, `RecordingControlsView`, `ResultsGraphView`, `ResultsView`, `Theme`, `WindowSubFieldLayer`) · `DAQPal/App/DAQPalApp.swift` · `DAQPal/Camera/CameraPermissionManager.swift` · `DAQPal/Data/CSVExporter.swift` · `DAQPalUITests/*` |
| **WS-E** | `DAQPal/Import/*` · `DAQPal/Camera/SessionVideoRecorder.swift`, `PhotoLibrarySaver.swift`, `FixtureFrameSource.swift`, `CameraManager.swift`, `CameraPreview.swift`, `FrameSource.swift`, `LiveCameraFrameSource.swift`, `DemoMotion.swift` · `DAQPal/UI/VideoImportView.swift` |
| **SHARED** (gate-only edits) | `DAQPal/App/AppState.swift`, `InteractionState.swift`, `DebugDemo.swift` · `DAQPal/Camera/CaptureStack.swift`, `FrameProcessor.swift`, `SyntheticFrameSource.swift` · `DAQPal/UI/CameraCaptureScreen.swift` · `DAQPal/Display/*` · `DAQPalTests/Support/*` (shared rig) · Xcode project file |

**Any file not listed above is SHARED by default (gate-only edits).** A workstream that discovers an unowned file must add it to this table in the same session. This rule exists because the 2026-08-03 audit found 24 of 81 production files matched no row, which made the entire user-facing surface un-editable under the ownership rule.

`OverlayQuadGeometry` is declared inside `PipelineDebugOverlay.swift` (WS-C-owned) but is used by WS-A overlays. **Exception:** WS-A may add point-in-quad helpers to that enum for task A5; WS-C retains ownership of everything else in the file.

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

Audit 2026-08-03: `PipelineBudgetTests` asserts **0 of these 10** wall-clock figures — it is deliberately mechanism-level (its own header disclaims wall-clock budgets) and instead pins O(targets) homography solves, O(configured-devices) per-frame jobs, the 240-sample metrics ring cap, and disabled-instrumentation inertness. BASELINES.md's statement that shipping performance "is asserted in `PipelineBudgetTests` against a Release build" is **incorrect** — no wall-clock budget assertion exists anywhere yet; C2 creates them.

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

**Milestones** *(revised 2026-08-03 by the executability audit — the previous list scheduled B4 after the gate that required it, and placed DD1 both before and inside M2):*

- **M0 — commit + unblock** (serial, no device). Commit the working tree; share the Xcode scheme; apply the audit's plan-set fixes; **B0**: fix the 4 `SegmentCellScannerTests` failures and triage `DragLatencyUITests`. Nothing fans out until the suite is green — otherwise every M1 session violates its own exit invariant.
- **M1 — trust the promise** (parallel, no device): the confidence floor · `wrongAcceptedRate` in `ValidationHarness` · first real-instrument assertion on `Fixtures/ir_gun_display.png` · **A0** (automate the false-healthy-lock trace) · D1 refusal visible live · D2 multi-device CSV parity · C1–C2.
- **G1** — shared-file edits land A → B → C → D → E; ledger reconciled; grammar/decision agenda settled.
- **M2 — wire + repair** (parallel, no device): B1–B3, B4-wire · A4-grammar, A5, A8 · D3 persistence/interruption · D4 review-and-correction · E1 bounded buffering + Photos/Files repair.
- **G2**, then **DD1** — device day. **Fix the Release test build first** (`ENABLE_TESTABILITY = NO` in Release blocks all 54 `@testable` files; verified 2026-08-03), then Instruments, then fixture recording.
- **M3 — evidence**: B5, B7, A6, A7, C5. C6 optimization unlocks only after C5 delivers a baseline.
- **M4 — ship qualification**: the S1–S16 criteria in `EXECUTABILITY_AUDIT.md` Deliverable J.
- **Acceptance**: all five DoD gates evidenced in §5, with yield figures.

**Device access is NOT the bottleneck the original plan assumed.** `OCR_DEVICE_BENCHMARK.md` §0 records three physical-iPhone runs on 2026-07-28 with working commands and a device ID. What has never happened is a *structured* session — so device work may start earlier than M3 whenever convenient.

---

## 10. Conflict Rulings (legacy contradictions, resolved)

| # | Contradiction | Ruling |
|---|---|---|
| R1 | Gate 14 "wired and exercised live" (PROGRESS exec summary) vs "not built" (same file's gate table) | **Wired.** Report §A + ARCHITECTURE §9 confirm; PROGRESS gate table stale |
| R2 | Test counts 113 / 116 / 616 / 733+ | **Superseded 2026-08-03.** The baseline is whatever §5 currently records. Never cite 733 — it appears nowhere as a live number |
| R3 | Spec Gate 2A drag-jitter open | **Resolved 2026-07-28** (ARCHITECTURE §2–3); spec checkbox stale |
| R4 | Decimal work "done" (files landed) vs benchmark unchanged | Both true: code landed, **bug remains** — rescue never wired (orphan list). The +506-line FormatValidator rewrite measurably changed nothing (byte-identical re-run) |
| R5 | RANSAC/feature-matching recommended vs TrackVerifier built | Deliberate deviation → **D2** |
| R6 | Cadences: 2.0s vs 0.5s locked revalidation; plan §16's 1–5Hz | **D7** (report values) |
| R7 | "PP-OCRv6" (PROGRESS/spec) vs PP-OCRv5 (everything measured) | **PP-OCRv5** is what exists; "v6" was aspiration/typo — never cite v6 |
| R8 | UI footer "OCR 30/S" vs measured ~382–397ms `.accurate` pass | Physically incompatible if naive. Resolution path = WS-C C4: honest cadence policy (fast-pass rate vs accurate-pass revalidation), then fix either the pipeline or the footer copy |
| R9 | VALIDATION_FRAMEWORK "RESULTS appended… every number measured" | **No sweep results exist on disk** (only self-test baseline). Claims are aspirational; B7 makes them real |
| R10 | Sub-field components "complete and verified" (VALIDATION_FRAMEWORK) | Code exists + unit-tested, but files are untracked/uncommitted — "verified" overstated until M0 commit + review |
| R11 | Snap thresholds 0.70/0.80/0.90 in spec | **CLOSED 2026-08-03 (audit)**: all four confirmed exact in code — `enterDetection 0.60 / enterAttraction 0.70 / enterSnapPreview 0.80 / enterLock 0.90` at `TargetLock.swift:181-184` (`SnapTuning` lives in `TargetLock.swift`; single instantiation, no overrides). Exits 0.50/0.60/0.70; `degradedTracking 0.55`; `lostTracking 0.30`; no `exitLock` (one-way); `framesToLock 3` |
| R12 | Design_notes/README vs root README | Root wins (has License). Drifted copy noted in §6; left in place per no-delete rule |
| R13 | ≥99% target vs 41.7% seven-segment | Not a contradiction: different metrics (system accept/reject vs raw OCR) — but the bridge is **unproven until real fixtures exist** (D6, DoD-2) |
| R14 | HARDWARE_VALIDATION describes fixed-pitch `DigitSegmenter` | Predates `SegmentCellScanner` (`4f9ca85`); procedure still valid, component description stale |
