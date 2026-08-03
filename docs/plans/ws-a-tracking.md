# WS-A — Tracking: Trust the Lock

Read `docs/plans/MASTER_PLAN.md` first (protocol §2, ownership §7, decisions §3). Status is reported ONLY to the master ledger (§5) — never restated here.

**Mission**: the lock is trustworthy under motion. A LOCKED overlay means the tracker is verifiably attached to the intended physical display; degradation is detected honestly; reacquisition returns to the *same* display; taps hit what they visually target.

## Invariants (every session, non-negotiable)

- **False-healthy-lock = 0.** ⚠️ **There is currently NO test for this.** Audit 2026-08-03: no symbol computing a false-healthy / LOCKED-while-unverified count exists anywhere in the repo — the "81-pass trace" is an `os_log` stream, not a runnable gate. **Task A0 must land before any other WS-A work** and must expose the count as an XCTest assertion. Until A0 exists this invariant is advisory and no WS-A task can be graded.
  Two further cautions recorded by the audit: (a) only 8 of 81 bounce passes reach LOCKED, so "0 of 81" is really "0 of 8 locked passes" — report it as a rate over stated exposure, per §1's yield floor; (b) this stack is **off by default** (`ScreenLockPipeline.swift:126 isEnabled = false`, `AppState.swift:96 screenLockEnabled = false`), so the result currently guards a code path users never run. Flipping that default is ship criterion S1.
- Full suite green at session end — the current baseline is in MASTER_PLAN §5, never a hardcoded number.
- Tracking step stays within its ≤10ms/frame budget conceptually — no new per-frame heavy work without a WS-C measurement plan.
- Do not weaken `TrackVerifier` thresholds to improve hold rate; hold rate must improve by tracking/reacquiring better, not by verifying less (D2).

## Owned files

Per master §7: `DAQPal/Tracking/*`, `DisplayPose3D.swift`, `PoseTrajectory.swift`, `ROISelectionOverlay.swift`, `FieldSelectionOverlay.swift`, `PanGestureCatcher.swift`, `CoordinateDebugOverlay.swift`, and their test files. Shared files (`AppState`, `CameraCaptureScreen`, `FrameProcessor`, test `Support/`) only at gates.

## Tasks (in order; A1 first — it is the top-priority defect in the implementation report §K)

### A1–A3 — audit-verified as ALREADY FIXED (2026-08-03): confirm and close
The read-only pre-flight audit found all three defects fixed in the current tree, with tests. ARCHITECTURE.md §9's defect table is stale on them — do **not** re-implement:
- **A1** re-seed gating: `TrackedQuadGate.admit()` routes recovery re-seeds through `QuadSanity.isOrientationContinuous` + `isPlausibleReseed` (bbox-IoU / size-scaled center distance) — `VisionScreenTracker.swift:506-553`; tests `QuadTrackerTests.swift:582,646,668`.
- **A2** anchor freeze: shape-derived `uprightLabeling(of:)` + continuity relabeling replaced the position-based anchor — `ScreenCandidateDetector.swift:487-578`, `ScreenQuad.swift:170-183`.
- **A3** release/grace: dedicated `detectorID` suppression channel + `nil`-vs-`[]` handling — `MagneticSnapEngine.swift:149-162, 216-253, 259-276`; tests `MagneticSnapEngineTests.swift:823,907`.

Close procedure (one short session): run the named tests plus the bounce trace; confirm each fix covers the *original* failure narrative — especially A1's second half (a re-seeded track must not report verified-level confidence before `TrackVerifier` corroborates; verify, don't assume); then mark closed in the master ledger. Any uncovered half reopens as a real task.

### A-triage — `DragLatencyUITests` failure
`DAQPalUITests/DragLatencyUITests.swift:82` currently fails in the audited suite run (5 gesture callbacks where >10 expected for a 0.4s drag). This matches the documented **simulator-only** gesture-starvation pattern. Reproduce; if simulator-environmental, quarantine with a written justification + device-day verification item; if real, it becomes a full task.

### A4 — Numeric dominance + the shared grammar contract
`ScreenFieldAnalyzer.numericIsDominant` misclassifies "230 VAC" / "12 PSI" as labels; its `numberPattern` regex disagrees with `FormatValidator` (B-owned). Audit anchors: `ScreenFieldAnalyzer.swift:352-353` (regex omits `,`), `:324-328` (doc comment claiming exact parity with `FormatValidator` — currently false), `:437-447` (`numericIsDominant`); `FormatValidator.swift:542-543`.
- Fix unit-suffix-aware classification.
- **G1 agenda item (joint with WS-B)**: agree ONE numeric-token grammar (digits, separators incl. `,`, sign, unit suffixes, leading-separator forms like `.5`). A implements the analyzer side; B the validator side; the settled grammar is recorded in the master decision registry.
- **Evidence gate**: `ScreenFieldAnalyzerTests` cover the misclassified cases; grammar parity test (same token set accepted by both sides) added at G1.

### A5 — Overlay correctness
Hit-testing uses the bounding box (~1.9× the true quad area at 30° roll — taps visually outside the display still hit it); `FieldSelectionOverlay` retains the per-frame-published-value-read-inside-gesture anti-pattern already fixed in `ROISelectionOverlay`. Audit anchors: `FieldSelectionOverlay.swift:132` (`OverlayQuadGeometry.boundingRect`), `:144-159` (`Rectangle()` contentShape); the bbox helper lives at `PipelineDebugOverlay.swift:169-196`.
- Point-in-quad hit-testing; port the fixed gesture pattern (gesture state isolated from per-frame published geometry).
- **Evidence gate**: hit-test unit tests at 0°/15°/30° roll (inside-quad hits, outside-quad-inside-bbox misses); `OverlayGeometryTests` + `DragStabilityTests` green; no new per-frame invalidations (`CapturePerformanceTests` pattern).

### A6 — Motion matrix beyond bounce
Verification is only proven on bounce + steady. Build synthetic-rig sweeps over: fast translation (incl. super-frame-rate steps), yaw ±55°, pitch ±55°, roll ±10°, scale 0.5–1.4×, occlusion 10–50%, blur, plus combinations (rig envelope per ARCHITECTURE §4).
- Per scenario record: verdict counts, hold rate (non-REACQUIRING fraction), reacquisition latency (frames), false-healthy count (must be 0 everywhere).
- Land results as `tracking-*.baseline` sweeps via the BASELINES.md mechanism (Baselines/ is B-owned — these files land at an integration gate).
- **Evidence gate**: sweep table in master ledger with per-axis results; DoD-1 evidence base established.

### A7 — Hold-rate improvement (follow, don't just detect)
Baseline under bounce: only 8 LOCKED + 6 DEGRADED of 81 passes (67 REACQUIRING). The verifier stops lies; this task makes the tracker actually keep up.
- Do NOT invent a numeric target up front (project honesty rule): A6's sweeps first quantify the achievable envelope; the target is then recorded in the master ledger before optimization starts.
- Mechanisms to trial, each behind before/after sweep evidence: reacquisition seeding from last-verified quad + `PoseTrajectory` motion prediction; stale-tracker timeout (0.75s) and REACQUIRING detection cadence (0.1s) tuning within D7's change protocol; cheap local search before global re-detection.
- This is where D2's "reopen if" clause gets tested honestly — if corroboration-based tracking cannot reach the recorded target, write the D2 reopen proposal with the sweep data.

### A8 — Appearance robustness
Structured static distractors (patterned poster) are only *bounded* by reference-refresh gating; backlight-polarity toggling breaks appearance comparison.
- Polarity-tolerant comparison (e.g. sign-normalized NCC or dual-polarity reference) with the existing veto threshold discipline (0.35 NCC, 4-consecutive-failures).
- **Evidence gate**: `AppearanceSentinelTests` extended with polarity-flip and poster-distractor cases; occlusion series (NCC 0.879/1.000/0.866/0.658 at 0/10/25/50%) not regressed.

## Device-day requests (executed under master §9 protocol)

- Handheld real-motion trials (translation/yaw/pitch sweeps) with trace capture → real-world verdict counts.
- Slow-motion footage of fast motion past the instrument for offline replay through the rig.
- Backlight-polarity toggle on a real instrument vs A8.
- Live tap-accuracy check (HARDWARE_VALIDATION.md §5.9) after A5.

## Non-goals

RANSAC/feature-matching rewrite (D2 governs — proposal first), device-classification layer (out of scope), UI visual redesign, OCR changes (WS-B).
