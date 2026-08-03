# DAQPal — Progress, Device Readiness, and What's Next

Written 2026-08-03, end of the audit + B0 + D9 session. Branch `segment-cell-scanner`, all work committed and pushed.

This is a **snapshot for revisiting**, not a plan. Plans live in `MASTER_PLAN.md` + the five `ws-*.md` files; status lives in `MASTER_PLAN.md` §5. This file exists so you can pick the thread back up cold.

---

## 1. Can you build and test on your iPhone?

**Verified today against `Daniphone` (iOS 26.5.2, `00008101-001E44EC1A88001E`) — the same phone as the July device benchmark.**

| Capability | Status | Evidence |
|---|---|---|
| Build the app for device | ✅ **YES** | `** BUILD SUCCEEDED **`, signed "Apple Development: hsiu.liu@uoit.net" |
| Install and run it | ✅ **YES** | Signed `.app` produced; team `56WA4P82Z5`; camera + photo-library usage strings present |
| Run the test suite on device | ❌ **NO** | `DAQPalTests` and `DAQPalUITests` have **no `DEVELOPMENT_TEAM`** → *"Signing for X requires a development team"* |
| Run tests in **Release** anywhere | ❌ **NO** | `ENABLE_TESTABILITY = YES` only in Debug (`pbxproj:308`); 54 files use `@testable import DAQPal` |

**So: you can put the app on your phone right now and use it. You cannot run a single automated test on the phone, in any configuration.**

That matters more than it sounds. **Device Day 1 (task C5) would have failed at step 1** — its whole premise is running `DecimalBenchmarkTests` and the budget tests on hardware in Release. Both blockers are one-line build-setting fixes:

```
DAQPalTests, DAQPalUITests:   DEVELOPMENT_TEAM = 56WA4P82Z5
Release configuration:        ENABLE_TESTABILITY = YES   ← see caveat
```

**Caveat on the second one, and it is not pedantic.** Turning testability on in Release disables cross-module optimization, so the numbers you measure are not the shipping configuration — which defeats the entire point of D5 ("performance claims require Release-config measurement"). The honest fix is a **third build configuration** (call it `Benchmark`: Release optimization + testability on) so `Release` stays pristine for what actually ships. Left undone deliberately: it is WS-C's call and it changes the project file.

### To use the app on your phone right now

```
xcodebuild build -scheme DAQPal -configuration Debug \
  -destination 'id=00008101-001E44EC1A88001E' -allowProvisioningUpdates
```
Or just open the project in Xcode, pick Daniphone, and hit Run. Expect the camera permission prompt on first launch.

**What you'll actually see, so the experience isn't a surprise:** the intelligent tracking path is **off by default** (`ScreenLockPipeline.swift:126`, `AppState.swift:96`). You get the manual workflow — draw an ROI, it OCRs inside it. `TrackVerifier`, `AppearanceSentinel` and the transit veto are all built and tested but not in the path you'll be using.

---

## 2. What actually happened this session

### Landed and pushed (11 commits, `e757219` → `df2b929`)

**The baseline got versioned.** ~23k lines were uncommitted, including `TrackVerifier`, `TemporalConsensus`, `DecimalRescue` and `AppearanceSentinel` — DoD-1's entire evidence base existed only on your disk. Now committed and on GitHub.

**The plan set became executable.** It was factually excellent and structurally unrunnable: only 2 of 22 tasks could be started as written. Fixed the suite-green invariant that no M1 session could satisfy, the "≥733" count that contradicted §5 two screens away, two Authority Map paths that would fail a `Read`, the milestone DAG that scheduled B4 after the gate requiring it, and the ownership matrix — **24 of 81 production files belonged to no workstream, and it was exactly the 30% a user touches.** Added WS-D (Experience) and WS-E (Recorded Path); the gap is now 0.

**B0: the 4 scanner failures are fixed.** Root cause was the row-band splitter cutting one digit line into two bands.

**D9: the confidence floor is a real policy** (0.15), replacing a derived value (0.0375) that was mathematically elegant and refused nothing.

### The three findings that mattered more than the tasks

1. **`SegmentCellScanner`'s safety property is false, and always was.** Measured over 600 both-version cases: **HEAD reports 38 wrong decimal positions; the current tree reports 13.** Including `sans/clean "1234"` — undegraded, no decimal point — reporting position 1 off a glyph serif. A wrong decimal position is a silent factor-of-ten error in exported data. The test guarding this covers 4 literals and structurally cannot see it. **This is bigger than B0 was.** (defect 10)

2. **There is no image-conditioning layer between the sensor and Vision.** `VisionOCR.swift:48-58` runs an axis-aligned ROI on the **raw camera frame** — no rectification, no binarization, no normalization. Of 29 real-world degradation classes, 12 are unhandled and 11 partial. Their combined effect surfaces as one confidence number that, until D9, nothing thresholded. **You cannot make OCR robust by improving OCR.**

3. **Only 5 of 9 rejection reasons can fire by default.** `.ambiguousDigit` — the cross-check veto that would catch a misread digit — needs `constrainToFormat`, so a user who never opens the format sheet has no misread protection.

### Where I was wrong, recorded so it isn't repeated

- **My prescribed scanner fix would have broken your IR gun.** I wrote "delete the row-projection pass, column-scan the whole crop." Measured on `ir_gun_display.png`, that collapses to one run covering the whole image, destroying the `90.0` reading that works today. Only prototyping caught it.
- **My first floor was a tautology.** I instructed "derive, never choose," which produced a value that by construction could not refuse anything. The leak needed a *policy*, not arithmetic.
- **I claimed "perfect OCR is never floor-refused."** Measurement disproved it: `ocr 1.0 × temporal 0.5 × decimal 0.5` is digits-certain/magnitude-unknown — exactly the `.5` class the floor should catch.
- **A peel-provenance filter I shipped turned 7 refusals into wrong answers.** Reverted, with the structural reason written into the source.

---

## 3. What's next, in priority order

The ordering follows your own stated priority: **Correctness → Trustworthiness → Evidence → Robustness → Performance → UX**.

### Now — no device, no fixtures needed

**N1 · Unblock device testing** *(WS-C, ~1 session)*
Add `DEVELOPMENT_TEAM` to both test targets. Add a `Benchmark` configuration rather than polluting `Release`. Without this, DD1 cannot happen at all. **This is the cheapest high-value task on the list.**

**N2 · Defect 10: the safety property** *(WS-B, 2–3 sessions)*
Extend the safety sweep beyond its 4 seven-segment literals to all 4 glyph styles × 5 presets, asserting correct-or-nil on **every row**, not just `.first`. Then fix the two known regressions (`333.3` crop-edge, `9.99` fourteenSegment merge). Gate on a both-version differential with bucket B empty. This directly protects DoD-2.

**N3 · B3: the `.5` leading-separator bug** *(WS-B, 1–2 sessions)*
The only *measured* silent 10× error: 7/72 on device, 0 refusals. The confidence floor does **not** catch this class — those failures carried 0.75 confidence. This is the real wrong-and-accepted path.

**N4 · `wrongAcceptedRate` in `ValidationHarness`** *(WS-B, 1 session)*
`ValidationOutcome` has no acceptance concept, so DoD-2's metric cannot be computed even in principle. Until this exists, no OCR work can be graded. Pair it with the first real assertion against `Fixtures/ir_gun_display.png` — the repo already owns that photo; only the assertion is missing.

### Next — needs your phone, not a "device day"

**N5 · Record 2–3 real fixtures.** `dmm_NNN.mov` + ground-truth CSV per `Fixtures/README.md`. This unskips `RecognitionPipelineTests`, which has **never once executed**, and creates DoD-2's evidence base. The stock Camera app is sufficient — this does not need a structured session.

Worth correcting a plan premise here: **device access was never the bottleneck.** `OCR_DEVICE_BENCHMARK.md` documents three physical iPhone runs on 2026-07-28 with working commands. What has never happened is a *structured* session.

### Then

**N6 · WS-D**: make refusal visible during live aiming (today it's invisible until you stop recording), multi-device CSV parity, persistence across interruption, a review/correction surface.
**N7 · Flip `ScreenLockPipeline.isEnabled`** once N5 validates it on real hardware — ship criterion S1. Until then, every piece of WS-A's verification work guards a path users never run.
**N8 · WS-E**: repair the import path (unbounded buffering will OOM; the app saves video to Photos but the importer only reads Files) *before* any high-frame-rate work.

---

## 4. Revisit checklist

Cold-start in five minutes:

```bash
git log --oneline -12                      # this session: e757219..df2b929
xcodebuild test -scheme DAQPal \
  -destination 'platform=iOS Simulator,name=iPhone 16e,OS=18.4' \
  -resultBundlePath /tmp/r.xcresult -parallel-testing-enabled NO
xcrun xcresulttool get test-results tests --format json --path /tmp/r.xcresult
```
Expect **872 passed / 1 failed / 2 skipped / 1 expected failure**. The one failure is `DragLatencyUITests` — simulator gesture starvation, WS-D triage, not a regression.

Then read, in order: `MASTER_PLAN.md` §5 (status) → §3 (decisions, incl. D9) → `EXECUTABILITY_AUDIT.md` Verdict → the `ws-*.md` for whatever you pick up.

**Open decisions waiting on you:** whether defect 10 gets promoted ahead of B1–B4; whether `Benchmark` is the right name for the third configuration; whether `ScreenLockPipeline` should default on before or after real-fixture validation.

**The standing caveat:** every accuracy number in this repo is synthetic. The only real-instrument asset is one photo. Until N5 lands, DoD-2 has no evidence base, and no synthetic result may be quoted as instrument accuracy (D6).
