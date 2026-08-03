# DAQPal Plan-Set Executability & Ship-Readiness Audit

Date: 2026-08-03 · Audited at commit `e757219` (plan set clean) · Branch `segment-cell-scanner`
Method: mechanical anchor verification + 22 independent review agents + adversarial refutation of every blocker/critical claim (8 confirmed, 2 refuted and rewritten).

**Status of this document:** it is an audit, not a plan edit. Nothing in `MASTER_PLAN.md` or the `ws-*.md` files was modified. Deliverable I contains paste-ready markdown for when you decide to apply it.

---

## Verdict

The plan set is **factually excellent and structurally unexecutable.**

Every `file:line` anchor spot-checked resolves exactly. The 857/5/2 test count reconciles against its own cited log. The orphan claims are true. This is real audit work, and the discipline it encodes — provenance tags, decision registry, synthetic≠real — is worth preserving verbatim.

But an agent that obeys the plan literally **cannot complete a single M1 session**, because three independent rules each block it. And the plan is aimed at a target that is no longer the project's biggest risk.

Three findings dominate everything else:

1. **The tracking stack is off by default.** `ScreenLockPipeline.swift:126` — `private var isEnabled = false`, commented "the manual workflow stays the shipping default until this is validated on hardware." `TrackVerifier`, `AppearanceSentinel`, the transit veto and `PerspectiveNormalizer` are not in the shipping path. WS-A's crown-jewel "0 false-healthy-locks of 81 passes" guards code the user never runs.

2. **The accept predicate has no confidence floor.** `ConfidenceEngine.swift:117` computes `finalConfidence` as a product of five factors, but the rejection ladder (`:119-145`) only gates the *first* factor (`ocr < 0.3`). Then `:141` multiplies `finalConfidence *= (1 - c)` **after** the last check, with nothing re-gating it. Worked example with the real constants: `ocr=0.35` × `decimalFactor=0.5` × cross-check `c=0.49` → `finalConfidence ≈ 0.089`, exported as `accepted: true`. This directly contradicts the product's core promise, and it is a ~5-line fix.

3. **30% of the codebase is unowned, and it is the 30% the user touches.** 24 of 81 production files match no `§7` row: `ResultsView`, `ResultsGraphView`, `VideoImportView`, `RecordingControlsView`, `LiveReadingBadge`, `CaptureHeaderView`, `CameraPermissionManager`, `DAQPalApp.swift`, all of `Display/` and `Import/`, plus all 4 `DAQPalUITests/` files. `§7` says editing a file you don't own is a plan violation, so the entire end-user surface is un-editable. The design doc (line 40) required "every Swift file → exactly one owning workstream." The matrix doesn't deliver it.

---

## Deliverable A — Current-State Executability Audit

### What the plan already gets right (preserve verbatim)

| Principle | Enforced? | Evidence |
|---|---|---|
| Master plan is the hub | Yes | Short enough to re-read; §2 protocol is clear |
| Status lives only in §5 | Yes | Workstream files genuinely never restate status |
| Decisions only in §3 | Yes | D1–D8 each carry evidence + reopen-if |
| Authority Map governs legacy docs | Mostly | 2 path errors (below); otherwise accurate and useful |
| Provenance tags on numbers | Yes | `[device-debug]`/`[sim]`/`[host]` used consistently |
| Synthetic ≠ real (D6) | Yes | Strongest rule in the set. Keep exactly as written |
| Wrong-and-accepted > rejection | **In doctrine only** | The plan states it; the code has no confidence floor (see Verdict #2) |
| Ownership prevents collisions | **No** | 30% unowned; two tasks require cross-owner edits |
| Full regression mandatory | **Self-contradicting** | See blocker E1 |

### The five hard blockers

**E1 — The suite-green invariant is unsatisfiable during M1.**
All three workstreams require "full suite green (≥733 baseline) at session end." The suite has 5 failures; 4 are `SegmentCellScannerTests`, fixed by B4, which `§9` schedules in **M2**. Every WS-A and WS-C session in M1 therefore fails its own exit condition, and G1's "full suite green" gate is unreachable because the task that makes it green is scheduled after it. *Fix: promote B4 step 1 to a new **B0** in M0.*

**E2 — "≥733 baseline" contradicts §5 in the same document.**
`§5` line 77: historical counts "are superseded; do not cite." DoD-4 and all three workstream invariants then cite "≥733 baseline." *Fix: replace with `857 passed / 0 failed / 2 skipped` and reference `§5` as the single source.*

**E3 — WS-A's non-negotiable invariant has no runnable procedure.**
`ws-a-tracking.md:9` requires re-running the "81-pass bounce verification trace" after every tracking change. No symbol computing false-healthy-lock / LOCKED-while-unverified exists anywhere in the repo. It is an `os_log` stream, not a test. The invariant gates A1–A3, A6, A7 and A8 — five of eight tasks — and cannot be mechanically checked. *Fix: add task **A0** that promotes the trace to an XCTest before any other WS-A work.*

**E4 — Two tasks require editing files their workstream doesn't own.**
`OverlayQuadGeometry` is declared at `PipelineDebugOverlay.swift:99` (**WS-C**). A5 is **WS-A** and must replace its `boundingRect` hit-testing. C3 (cold-start warm-up) targets `DAQPalApp.swift`, which nobody owns. `§7` provides no exception mechanism.

**E5 — Milestone ordering is contradictory.**
`§9` sequences "G1, then DD1" then "M2: … C4–C6". But **C5 *is* DD1**, so DD1 is both before and inside M2. Within M2, C6 is "LOCKED until C5" and C4 needs DD1 numbers, so WS-C's M2 is strictly serial, not "(parallel)" as labelled.

### Per-task executability

`EXEC` = executable as written · `ASSUME` = executable only by inventing something · `BLOCKED` = cannot start.

| Task | Verdict | The single most damaging forced assumption |
|---|---|---|
| A1–A3 | ASSUME | Close criterion is a narrative, not a predicate. A1's genuinely-open half (re-seeded track must not report verified confidence pre-corroboration) is buried in prose |
| A-triage | BLOCKED | `DAQPalUITests/` is unowned; both outcomes (quarantine or fix) require editing it |
| A4 | **BLOCKED — premise false** | `numericIsDominant` already handles "230 VAC"/"12 PSI"; a green test pins it. A4 repeats exactly the staleness disease A1–A3 exists to correct. Only the grammar-parity half is real |
| A5 | ASSUME | The bbox hit-shape is a **documented deliberate decision** (`FieldSelectionOverlay.swift:146-151`), and strict point-in-quad conflicts with the ≥44pt tap-target rule. Plan doesn't acknowledge either |
| A6 | ASSUME | ~60KB of pose/motion sweeps **already exist** (`PoseSweepTests.swift`, `MotionStressSweepTests.swift`); the "only bounce + steady" premise is stale. The `.baseline` schema cannot record any of A6's four metrics |
| A7 | BLOCKED | Deliberately has no success condition, and its two knobs are D7-governed constants needing human approval. No agent can start, finish, or self-grade it |
| A8 | ASSUME | The "not regressed" occlusion gate cites four NCC numbers that no test asserts and nothing records |
| B1 | ASSUME | No insertion-point anchor, no coordinate-space contract, no machine-checkable trigger thresholds |
| B2 | **ASSUME — spec is a no-op** | `DisplayFormatInference` has no live producer, so wiring it as specified changes nothing. Its refusal rule contradicts two existing green tests |
| B3 | ASSUME | Success condition not machine-checkable; the `[sim]` baseline it compares against doesn't exist |
| B4 | ASSUME | Wiring step spans an unspecified coordinate transform, row-selection policy, and handoff contract |
| B5 | ASSUME | "contrast 0.20" has three incompatible meanings in this repo; "the existing Bradley-style pass" names two different implementations; the fixture it asks for already exists (`Fixtures/ir_gun_display.png`) |
| B6 | ASSUME | The "re-inference request" escape mechanism does not exist |
| B7 | BLOCKED | Asks the agent to record sweep baselines through a harness that isn't wired, in a format with no field for the "explicitly-synthetic" label it mandates |
| C0 | DONE | — |
| C1 | ASSUME | `.capture`/`.endToEnd` hook requests name the wrong files and would mix two incompatible clocks |
| C2 | EXEC | Best-specified task in the set |
| C3 | BLOCKED | Targets `DAQPalApp.swift` — unowned |
| C4 | **BLOCKED — premise false** | The footer already shows a *measured* rate; the only "OCR 30/S" string lives in a frozen design doc |
| C5 | BLOCKED | `xcodebuild test -configuration Release` cannot compile the test bundle, and the only scheme isn't in version control |
| C6 | BLOCKED | WS-C owns none of the files every ranked candidate lives in |

**2 of 22 tasks are executable as written.**

### Other executability defects

- **No runnable test command.** `§2` says "`xcodebuild test` — Simulator, serial" with no scheme, destination, or flags. One scheme exists (`DAQPal`), and it is **not in version control** — a fresh clone has no schemes at all. Serial vs parallel changes the result format and therefore how an agent counts passes, a documented past failure in this project.
- **The "5 failures" trap.** The plan says 5; its own log's summary says **7** (5 test *cases*, 7 *assertions* — `testDecimalPositionAcrossFormatBattery` fails 3×). An agent re-running and seeing 7 concludes it caused a regression.
- **Two Authority Map paths fail a `Read`.** `PerspectiveNormalizer.swift` is in `Tracking/` (WS-A-owned), not `Camera/`. The spec backing DoD-2's ≥99% bar is at `Design_notes/design_handoff_daqpal_ios/`, not repo root.
- **`CLAUDE.md` is misclassified UNTRUSTED.** It is 12 lines of gstack skill routing that the owner actively uses. An agent obeying `§6` would refuse the owner's own tooling.
- **AC4 already violated.** `ARCHITECTURE.md`, `IMPLEMENTATION_NOTES.md`, `PROGRESS.md` and the spec have uncommitted edits; D8 declares them frozen; M0 would commit them.
- **No stopping condition, scope limit, or ledger template** anywhere in `§2`.

---

## Deliverable B — Workstream Gap Analysis

**WS-A.** Complete: the verification architecture itself (`TrackVerifier`, `AppearanceSentinel`, transit veto) and defects 1–3, genuinely fixed with tests. Blocked: A-triage, A7. Wrong: A4's dominance half (already fixed), A6's "only bounce" premise (sweeps exist). Missing: **A0**, the automated false-healthy-lock harness — without it every other WS-A task's exit gate is unverifiable. Also missing: any acknowledgement that the pipeline it protects is off by default.

**WS-B.** Complete: the rejection architecture end-to-end (9 `RejectionReason` cases, single chokepoint, CSV columns, UI chip). Incomplete: three orphans (`DecimalRescue`, `SegmentCellScanner`, `DisplayFormatInference`) and the `.5` tokenizer bug. Missing entirely: **the confidence floor** (Verdict #2) — the highest-value fix in the whole plan set and not a task anywhere. Also missing: `wrongAcceptedRate` as a measured quantity; `ValidationHarness.ValidationOutcome` has no acceptance concept at all, so DoD-2's metric cannot be computed even in principle.

**WS-C.** Complete: C0. Correctly scoped: C1, C2. Blocked: C3, C5, C6 on ownership or build config. Wrong: C4's premise. The invariant "no optimization before DD1" is right and should stay. The real gap: WS-C owns none of the files it must optimize, and the "hook request" mechanism has no named landing owner or gate procedure.

---

## Deliverable C — OCR Robustness

**B1–B7 are necessary but not sufficient, and they are not the highest-value work.**

The product promise — "when DAQPal is not confident it refuses" — is currently violated by a bug none of B1–B7 addresses. Ordered by value per unit effort:

| Rank | Work | Why it beats B1–B7 |
|---|---|---|
| 1 | **Confidence floor in `ConfidenceEngine.fuse`** | ~5 lines. Closes the accepted-at-9%-confidence hole. Nothing else in the plan touches it |
| 2 | **`wrongAcceptedRate` in `ValidationHarness`** | Adds `accepted`/`rejectionReason` to `ValidationOutcome`. Until this exists DoD-2 is unmeasurable and no OCR work can be graded |
| 3 | **B3** (`.5` tokenizer) | The one measured silent-10× path: 7/72 on device, 0 refusals |
| 4 | **Multi-device CSV parity** | `CSVExporter.swift:81-111` drops `rejection_reason` and `raw_text`. Multi-device sessions have no audit trail — the promise silently degrades with device count |
| 5 | B1, B2, B4 | Orphan wiring. Real, but graded by #2 |

**On robustness breadth:** most of your §6 list does not belong to OCR. Glare, shadows, low light, motion blur, rolling shutter, autofocus and exposure belong to **capture configuration**, which does not exist (no `lockForConfiguration` anywhere). Perspective, rotation, tilt and oblique angle belong to **perspective normalization** — which has exactly one production call site (`ScreenLockPipeline.swift:481`), and it is layout analysis at ~1 Hz, not recognition, so *the recognizer never sees a rectified image*. Occlusion and hands belong to **tracking/appearance**, which is off by default. Only segment geometry, digit spacing, decimal placement, negatives and leading separators are genuinely WS-B's.

### The single largest architectural gap

**There is no image-conditioning layer between the sensor and Vision.** `VisionOCR.swift:48-58` sets an axis-aligned `regionOfInterest` on the **raw camera frame** — no perspective correction, no binarization, no local contrast normalization, no denoising. Of the 29 degradation classes in your §6 list, 12 are handled **not at all** and 11 only partially, and the partial ones mostly live inside the tracking stack that is off by default.

Their combined effect surfaces as exactly one thing: a depressed `finalConfidence` number that **nothing downstream ever thresholds** (Verdict #2). That is the whole failure mode in one sentence — degradation is silently absorbed into a confidence value that is then ignored.

Worse, the fusion is even leakier than the earlier worked example suggests: `temporalFactor` can approach 0 *without* setting `temporalRejected`, because rejection needs a full 5-sample window (`TemporalFilter.swift:64-65`) while the factor applies immediately. So a reading in the first four frames after a change can be multiplied toward zero and still export `accepted: true`.

**Only 5 of 9 rejection reasons can fire out of the box.** `.outOfRange` and `.excessiveRateOfChange` need user-set min/max (both `nil` by default, `PhysicalValidator.swift:48-49`); `.ambiguousDigit` needs `constrainToFormat == true` (`MeasurementProcessor.swift:307`); `.trackingInvalid` needs `screenLockEnabled` (`AppState.swift:96`, default false). The default device is `DisplayFormat.unconstrained` (`Device.swift:47`), so **the cross-check veto — the mechanism that would catch a misread digit — is unreachable for a user who never opens the format sheet.**

The honest conclusion: **you cannot make OCR robust by improving OCR.** Four of the layers that should absorb degradation are absent, unwired, disabled, or config-gated off.

---

## Deliverable D — Seven-Segment Strategy

**Root cause of all 4 failures, found and adversarially confirmed:** the row-band splitter. `SegmentCellScanner.swift:247-264` builds a horizontal ink projection, gates it at 0.60 × non-zero median, and emits each surviving span as a **separate Row**. On "99.9" the intra-glyph trough (55 rows at 48 ink) is indistinguishable from a genuine inter-line gap (48–76 rows), so one digit line is cut into two bands and the column scanner only ever sees a horizontal slice of the glyphs.

This **disproves** my earlier hypothesis that the `:173` "99.9"→"000" failure was a cell-geometry/polarity mismatch with `SevenSegmentSampler`. It isn't; the sampler's polarity detection is correct. Recording that here because the wrong theory would have sent a session down a dead end.

**Fix:** delete the row-projection band pass. Run the column scan over the whole crop first, then cluster runs into rows by y-extent overlap. This is the file's own stated thesis (`:20-27`) — a column run spans the full glyph height regardless of which segments are lit. Parameter tuning cannot fix it; both obvious knobs were swept and neither separates the cases.

**Technique triage** (only what a demonstrated failure justifies):

| Technique | Verdict | Where |
|---|---|---|
| Row-clustering rewrite | **NECESSARY NOW** | `SegmentCellScanner` — the actual bug |
| Confidence floor | **NECESSARY NOW** | `ConfidenceEngine` — product promise |
| Adaptive thresholding | Already present (Bradley in `InkGrid`) | — |
| Sauvola σ-term | NEEDED LATER — gate on the 0.20-contrast fixture failing first | B5 |
| Polarity-invariant processing | NEEDED LATER — measured failure exists (moderate-inverted preset) | B4/B5 |
| Segment-level confidence | NEEDED LATER — feeds the cross-check | B4 |
| Perspective-aware sampling | NEEDED LATER — blocked on normalization reaching the recognizer at all | WS-A |
| Temporal frame fusion | NEEDED LATER — the recorded path's whole point | E |
| Morphology, multi-scale, geometry templates, local contrast norm, quality scoring | **SPECULATIVE — refuse** | No demonstrated failure mode. Adding them now is complexity without evidence |

---

## Deliverable E — Live + Recorded Architecture

**Verdict: yes, but it is a wiring-and-repair job, not a new architecture — and 240 FPS is the wrong headline.**

What already exists: `VideoImportModel.swift` (offline import), `VideoImportView.swift` (616 lines), `SessionVideoRecorder.swift`, `FixtureFrameSource` (drives the same recognition path from a file). The dual-path skeleton is **already shipping** and the plan set is blind to it.

Four corrections to the premise:

1. **The "⅛× · 240 FPS" option is a timestamp multiplier, not a capture rate.** `VideoImportModel.swift:207-209` scales `frame.timestamp * factor`; its own doc says "Frame count is unaffected." It de-slow-mos a phone slow-mo file so CSV timestamps reflect real time. It has never seen a 240 fps container.

2. **240 FPS does not reduce motion blur.** Blur extent = exposure duration × image-plane velocity; frame rate doesn't appear. HFR only forces a shorter *maximum* exposure. If you want less blur, control **exposure**, not frame rate — and no `setExposureModeCustom` call exists anywhere. (The design spec §21 does ask for 240 FPS, for temporal resolution of fast-changing readings, which is a legitimate and different goal.)

3. **HFR capture is 100% net-new.** Repo-wide there are exactly 3 `activeFormat`-family references, all read-only. There is **no `lockForConfiguration` call in the entire codebase.** And `CameraManager.swift:142` sets `sessionPreset = .hd1920x1080`, which is mutually exclusive with manual `activeFormat` — the highest-probability silent failure in this feature.

4. **Two blockers make the recorded path unusable today, independent of frame rate:**
   - **Unbounded buffering.** `FixtureFrameSource.swift:39` and `VideoImportModel.swift:54` both create `AsyncStream` with default `.unbounded`, and the producer never suspends. 10s of 1080p at 240fps ≈ 19.9 GB retained. It will OOM. The live path gets this right (`.bufferingNewest(1)`); the import path doesn't.
   - **The record→re-import loop is broken.** The app saves video to **Photos** (`PhotoLibrarySaver`), but the importer uses `.fileImporter` — **Files only**. You cannot re-import what the app just recorded.

**Recommendation:** treat this as **WS-E**, and sequence it as *repair → measure → then decide on HFR*. Fix buffering and the Photos/Files gap first; add frame-quality ranking second; only pursue HFR capture once a measurement shows temporal resolution is the binding constraint. Do not start with the 240 FPS work.

---

## Deliverable F — Validation Strategy

| Level | Proves | State |
|---|---|---|
| L1 clean synthetic | Logic correctness on known geometry | Healthy |
| L2 degraded synthetic | Robustness against *controlled* perturbation only | Exists but **asserts nothing** — every sweep checks `report.total == expected`, not accuracy |
| L3 real fixtures | Real-instrument accuracy on replayable input | **Zero.** `RecognitionPipelineTests` has never once executed |
| L4 uncontrolled device | Behaviour under real motion/lighting | **Zero.** 0 files, 0 infrastructure |
| L5 end-user workflow | The product actually works | **Zero** |

Two structural problems beneath the emptiness:

- **Two disjoint synthetic rigs.** `DAQPalTests/Support/SyntheticDisplayGenerator.swift` (test target) owns the glyph styles including DSEG7. `DAQPal/Camera/SyntheticFrameSource.swift` (app target, 1053 lines) owns 3D pose and optics but draws exactly one proportional typeface on one fixed palette. **Segment faces can never receive the pose/optics axes.** Merge them before adding a single new axis.
- **The baseline machinery is complete and connected to nothing.** `RegressionBaseline.swift` (555 lines, self-tested) has zero recorded sweeps. 42 regression-checker tests guard nothing.

**Highest-leverage single gate, and it needs no device day:** assert `wrongAcceptedRate == 0` against `Fixtures/ir_gun_display.png` — a photo of your actual IR gun showing `90.0` and `92.7` that is *already in the repo*. Every piece exists except the assertion.

---

## Deliverable G — Workstream & Ownership Recommendation

**Keep A/B/C. Add two. Close the ownership gap.**

| WS | Change |
|---|---|
| A, B, C | Keep missions and task IDs. Fix blockers E1–E5 |
| **WS-D — Experience** | New. Owns `DAQPal/UI/*` (except the two debug overlays), `DAQPal/App/DAQPalApp.swift`, `CameraPermissionManager.swift`, `DAQPal/Data/CSVExporter.swift`, `DAQPalUITests/*`. **Why A/B/C can't own it:** it is 24 files spanning three existing owners, and its work (refusal legibility, review/correction, persistence) is a product concern none of the three missions covers. Runs parallel with everything |
| **WS-E — Recorded Path** | New. Owns `DAQPal/Import/*`, `SessionVideoRecorder.swift`, `PhotoLibrarySaver.swift`, `FixtureFrameSource.swift`, `CameraManager.swift`. **Why not WS-B:** WS-B owns recognition, and this is capture/ingest/selection — different files, different failure modes. Shares recognition modules with B by calling them, never editing them |
| **Rule to add** | "Any file not listed in §7 is SHARED by default and may be edited only at a gate. A workstream discovering an unowned file must add it to §7 in the same session." Closes the gap permanently |

This is +2 workstreams for +24 files and two product-critical capabilities. It does not increase coordination complexity meaningfully because D and E have almost no file overlap with A/B/C.

---

## Deliverable H — Execution DAG

```
M0  COMMIT + UNBLOCK  (serial, ~1 session, no device)
    ├─ M0.1  Commit the working tree. 23k lines, incl. TrackVerifier/TemporalConsensus
    │        (untracked). Do NOT gate on review — a solo builder reviewing 23k lines
    │        is the bottleneck, and the evidence base is currently unversioned.
    ├─ M0.2  B0: fix the 4 SegmentCellScannerTests (row-clustering rewrite, Del. D)
    ├─ M0.3  Triage DragLatencyUITests → quarantine w/ justification or fix
    ├─ M0.4  Share the DAQPal scheme into version control; add the exact test command to §2
    └─ M0.5  Apply Deliverable I edits to the plan set
         ↓  GATE: suite 861/0/2 green, plan self-consistent
M1  TRUST THE PROMISE  (parallel, no device)
    ├─ B-1  Confidence floor in ConfidenceEngine.fuse          ← highest value in the plan
    ├─ B-2  wrongAcceptedRate in ValidationHarness             ← makes DoD-2 measurable
    ├─ B-3  Assert wrongAccepted==0 on ir_gun_display.png      ← first real-instrument gate
    ├─ A-0  Automate the false-healthy-lock trace as XCTest    ← makes WS-A gradeable
    ├─ D-1  Surface rejectionReason on the live card
    ├─ D-2  Multi-device CSV parity (rejection_reason, raw_text)
    └─ C-1/C-2  PipelineMetrics enablement + mechanism gates
         ↓  G1: shared-file edits land A→B→C→D→E; ledger reconciled
M2  WIRE + REPAIR  (parallel, no device)
    ├─ B1, B2, B3, B4-wire      ├─ A4-grammar, A5, A8
    ├─ D-3 persistence/interruption  ├─ D-4 review & correction surface
    └─ E-1 bounded buffering + Photos/Files repair
         ↓  G2
DD1 DEVICE DAY  (device access is ROUTINE — see note)
    └─ Release build repair first, then Instruments, then fixture recording
         ↓
M3  EVIDENCE  ── B5, B7, A6, A7, C5 ── then C6 optimization unlocks
         ↓
M4  SHIP QUALIFICATION  (Deliverable J)
```

**Note on device access:** the plan's premise that Device Day has never happened is **false**. `OCR_DEVICE_BENCHMARK.md` §0 documents three physical iPhone runs on 2026-07-28 with the working `xcodebuild` invocation and device ID `00008101-001E44EC1A88001E`. What has never happened is a *structured* session. This removes the plan's single largest scheduling dependency — device work can start much earlier than M3.

**Runs concurrently:** everything inside a milestone bracket. WS-D and WS-E never block A/B/C.

---

## Deliverable I — Master Plan Modifications

Paste-ready. Apply after M0.1.

**§1 — replace the DoD-4 row and add DoD-5:**
```markdown
| DoD-4 | Standing regression net | Full suite green (**857 baseline, see §5**) + recorded `.baseline` sweeps + Release budget tests | CI/test runs logged in §5 |
| DoD-5 | Honest to the user | Wrong-and-accepted rate = 0 on every recorded fixture, AND every refusal is legible in-app at the moment it happens | `wrongAcceptedRate` in `ValidationHarness`; UI test asserting a refusal is visible during live aiming |
```

**§1 — add beneath the table (closes the "do nothing" loophole):**
```markdown
**Yield floor.** DoD-1 and DoD-2 are both trivially satisfied by a system that never locks and never accepts. Neither gate passes unless accompanied by a yield figure: locked-fraction ≥ X% of trial duration, and accepted-fraction ≥ Y% of legible frames. Record X and Y in §5 before optimizing either gate.
```

**§2 — replace rule 4:**
```markdown
4. Run the full suite before and after your session, serially, with exactly:
   `xcodebuild test -scheme DAQPal -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -resultBundlePath /tmp/daqpal_run.xcresult -parallel-testing-enabled NO`
   Read counts from `xcrun xcresulttool get test-results tests --format json`, never by grepping stdout — the parallel and serial runners print different formats and this project has miscounted before. Baseline: **857 passed / 0 failed / 2 skipped** after M0.
```

**§2 — add rules 7–9:**
```markdown
7. **Stopping conditions.** Stop and report rather than continue if: (a) a fix would require editing a file your workstream does not own, (b) the code contradicts the plan, (c) you have made three failed attempts at the same defect, or (d) the task's success predicate is not machine-checkable. Never silently widen scope.
8. **Session report.** Every session ends with: changed files · tests run + exact counts · new defects found · evidence generated (with provenance tag) · known limitations · follow-up tasks. Append to §5's session log.
9. **Unowned files.** Any file not listed in §7 is SHARED by default and editable only at a gate. If you discover one, add it to §7 in the same session.
```

**§6 — replace two rows and delete one:**
```markdown
| `Design_notes/design_handoff_daqpal_ios/Visual_Instrument_Data_Logger_Agent_Development_Specification.md` | PARTIAL | Product requirements, ≥99% system bar (line 2087), MVP exclusions, M1–7 design, 240 FPS rationale (§21) | Roadmap positions long since passed |
```
Correct `PerspectiveNormalizer.swift` to `DAQPal/Tracking/` everywhere it appears (§5, ws-c C1). **Delete the `CLAUDE.md` UNTRUSTED row** — it is 12 lines of gstack skill routing the owner actively uses; the row would make agents refuse the owner's own tooling.

**§7 — add two rows and the default rule:**
```markdown
| **WS-D** | `DAQPal/UI/*` except `PipelineDebugOverlay.swift`/`CoordinateDebugOverlay.swift` · `DAQPal/App/DAQPalApp.swift` · `DAQPal/Camera/CameraPermissionManager.swift` · `DAQPal/Data/CSVExporter.swift` · `DAQPalUITests/*` |
| **WS-E** | `DAQPal/Import/*` · `DAQPal/Camera/{SessionVideoRecorder,PhotoLibrarySaver,FixtureFrameSource,CameraManager}.swift` |

Any file not listed above is SHARED by default (gate-only edits).
```

**§9 — replace the milestone list** with Deliverable H's DAG, and move C5 out of M2 so DD1 has exactly one home.

**ws-a §Invariants — replace bullet 1:**
```markdown
- **False-healthy-lock = 0.** There is currently NO test for this; the "81-pass trace" is an `os_log` stream, not a runnable gate. **Task A0 must land before any other WS-A work** and must expose the count as an XCTest assertion. Until A0 exists, no WS-A task can be graded, and this invariant is advisory.
```

---

## Deliverable J — Ship-Readiness Definition of Done

Evidence-backed. "Tests pass" appears nowhere as a sufficient condition.

| # | Criterion | Evidence required |
|---|---|---|
| S1 | Tracking is actually on | `ScreenLockPipeline.isEnabled` defaults **true**, with the device trial that justified flipping it recorded in §5 |
| S2 | Trustworthy lock | False-healthy-lock **rate** with a 95% upper bound over ≥N locked-seconds — not a count over 8 locked passes. Plus a locked-fraction yield figure |
| S3 | Wrong-and-accepted | `wrongAcceptedRate == 0` across ≥3 real recorded fixtures, reported alongside refusal rate and accepted-fraction |
| S4 | Confidence floor | No reading exports with `accepted=true` below the documented floor; unit test pins it |
| S4b | Rejection reachable by default | All 9 `RejectionReason` cases reachable without the user opening the format sheet, or documented as deliberately config-gated in §3 |
| S5 | Decimal integrity | 0 power-of-ten errors on the device benchmark; refusals counted separately and non-zero when ambiguity exists |
| S6 | Seven-segment | The IR gun reads end-to-end at Michelson 0.20, on device, in Release |
| S7 | Refusal is legible | UI test proving a refusal is visible **during live aiming**, not only in the post-session summary |
| S8 | Review & correction | User can reach, understand, and confirm/correct every flagged row before export |
| S9 | Export integrity | Single- and multi-device CSV both carry `accepted` + `rejection_reason`; round-trip test |
| S10 | Durability | Recording survives backgrounding, a phone call, and camera interruption; interrupted sessions recover or warn |
| S11 | Live performance | §8 budget table met at p95, Release, on device, with Instruments traces archived |
| S12 | Recorded performance | Bounded memory across a full-length import (explicit ceiling, measured) |
| S13 | Thermal & battery | 10-min sustained session with thermal-state logging; no throttle-induced accuracy cliff |
| S14 | Release build | `xcodebuild test -configuration Release` compiles and runs on device; scheme in version control |
| S15 | Regression net | 857+ green, recorded baselines committed, sweeps assert accuracy not just structure |
| S16 | TestFlight | Crash-free session on a second physical device; permission-denied and low-storage paths exercised |

**S1, S3, S4, S7 are the ones that make it a measurement instrument rather than a demo.** None of them is in the current plan.

---

## Deliverable K — Next Ultracode Prompt

See `docs/plans/NEXT_SESSION_PROMPT.md`.

---

## Appendix — Audit provenance

- Anchor verification: mechanical, by the orchestrator, against the working tree at `e757219`.
- 22 independent review agents (6 ground-truth probes, 3 executability scorecards, 4 role voices, 9 adversarial verifiers). One probe (`recognition-path`) failed its schema cap and was re-run separately.
- Every blocker/critical claim was adversarially refuted before inclusion: **8 confirmed, 2 refuted and rewritten**. The two refuted claims (a 240-FPS physics argument that attacked a goal no document states, and a "no uncertain tier exists" claim contradicted by `Measurement.decimal`) are excluded from the findings above except where noted.
- One of the orchestrator's own prior hypotheses — that the `:173` reconstruction failure was a cell-geometry/polarity mismatch — was **disproved** during this audit and is recorded as such in Deliverable D.
