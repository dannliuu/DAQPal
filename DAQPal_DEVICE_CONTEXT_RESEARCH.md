# DAQPal Device-Aware Detection — Research Report (PART 13 + PART 14)

**Date:** 2026-08-03 (final, post-adversarial-review)
**Repo:** `/Users/danielliu/Documents/DAQPal`, branch `main`, dirty working tree (~40 uncommitted/untracked files)
**Source prompt:** `DAQPal_Context_Aware_Device_Seven_Segment_Detection_Research_Prompt.md`
**Status:** third revision. Three adversarial critiques (over-engineering, evidence-integrity, iOS-feasibility) were applied. See **Critique log** at the end for exactly what changed and what was rejected.

---

## EVIDENCE LEGEND (used throughout, no exceptions)

| Tag | Meaning |
|---|---|
| **MEASURED** | Executed in this workflow session. Hardware and dataset named. |
| **REPO-RECORDED** | A number recorded in this repository by an *earlier* session's run. Not re-run here. |
| **READ** | Verified by reading source / grepping the working tree. No execution. |
| **SURVEYED** | A bounded web/catalogue browse performed this session. Landing pages read; **archives not downloaded**. Weaker than READ, and *not* a measurement. Cannot support universal negatives. |
| **CITED** | A paper, dataset page, or vendor doc reports it, on *their* hardware and *their* dataset. |
| **INFERRED** | My reasoning. Not a measurement by anyone. |

**What I personally did:** read the source prompt and repository files, and ran targeted greps. I ran no build, no benchmark, and no model. MEASURED items were produced by the audit and literature agents in this session and are attributed to the machine they ran on. **No number here is a DAQPal on-device latency figure except where marked REPO-RECORDED, and that figure is from a Debug/`-Onone` build on an iPhone 12 Pro Max in a ~12-second burst.**

**Citation-pinning caveat (applies globally).** Several load-bearing citations below — ContextShift (2026), Yu et al., the "2025 systematic review of 265+ context papers", the 28.16% ICDAR-2015 bigram result, Finnegan et al., POT-210, PlanarTrack, Copel-AMR's legibility head — are quoted from the literature agent **without author/year/venue or DOI pinned in this document**. They are used as directional evidence only. Divvala, Bergboer 2006, Laroca, and the verbatim Apple header quotes are locatable from the text. **No decision below should be reversed on an unpinned citation alone; the decisive arguments are the repo-fact and cost arguments.**

---

# 0. HEADLINE FINDINGS (read these; the rest is support)

**H1. Gate 4 is unreachable by construction, and this is the report's central result — not a caveat.**
PART 15 Gate 4 says "PASS only if measurable improvement is demonstrated." **DAQPal's false-lock rate has never been measured, no metric for it is defined anywhere in the repo, no ground-truth corpus exists, and (SURVEYED negative result) no published study measures the equivalent quantity for anything resembling DAQPal's case.** There is no baseline to improve *against*. Any device-detection programme would therefore be committing multi-month cost to a gate it cannot pass. **Until a false-lock number exists, the correct architectural decision for every proposed new stage is "do not build."**

**H2. The measured weakness is decimal integrity and self-observability, not device identity.**
MEASURED: 4 failing tests in `SegmentCellScannerTests`, one of which reports a **wrong** decimal position (a silent factor-of-ten export error). READ: 1,932 lines of decimal/segment code with **zero production call sites**. READ: the metrics HUD renders "100% dropped" in alarm colour as a lie. Nobody has ever observed DAQPal locking onto a textbook.

**H3. The app has been silently running at roughly half its nominal frame rate, and nobody noticed.**
READ + INFERRED (feasibility critique, verified): `FrameProcessor` is a **single serial `Task`** draining `AsyncStream(.bufferingNewest(1))`. The pipeline therefore **cannot exceed its frame budget — it self-throttles by dropping frames.** With REPO-RECORDED OCR at 41.8–52.2 ms plus tracking, analysis, and two `MainActor` hops, effective throughput is plausibly **~15–21 fps against a 30 fps capture**. This is INFERRED, not measured, precisely because `.capture`, `.endToEnd`, and `recordProcessedFrame()` have **zero production call sites**. The earlier framing of "already over budget" was mechanically wrong; the true situation is a silent, unmeasured rate halving.

**H4. The shipping default already implements the strongest available form of device-aware selection — a human drawing a box.**
READ: `AppState.screenLockEnabled = false`, `ScreenLockPipeline.isEnabled = false`. The default product is Vision OCR inside a user-drawn ROI. The user's finger supplies localization, scale, and device identity simultaneously, with perfect semantics, at zero compute and zero model bytes. The false-lock exposure the prompt describes exists **only in the opt-in path, which is off, and which has never been measured.**

**H5. The cheapest defensible action is: fix what is provably broken, delete what does not run, measure the thing you claim is wrong, and change nothing else.** See §10.

---

# 1. BASELINE

## 1.1 The measured test baseline

**MEASURED** (this session, `xcodebuild test -only-testing:DAQPalTests`, destination iPhone 16 Pro Simulator `9864C090`, parsed from `/tmp/daqpal_baseline.xcresult` via `xcrun xcresulttool --format json`, counting `nodeType == "Test Case"` nodes — *not* by grepping log text):

| Result | Count |
|---|---:|
| Passed | 812 |
| Failed | 4 |
| Skipped | 2 |
| Expected Failure | 1 |
| **Total test cases** | **819** |

`xcresulttool` independently reports `totalTestCount 819`, and 812 + 4 + 2 + 1 = 819. **Correction (evidence critique M1):** an earlier draft claimed this was corroborated by a static count of "819 `func test…` declarations across 49 files." That is false. **MEASURED this session:** `DAQPalTests/` contains **856** zero-argument `func test…()` declarations across **54** files. The 37-case gap is **unexplained** and I am not going to invent an explanation for it. The headline counts stand on the result bundle alone; **the "nothing was dropped or double-counted" claim is withdrawn.**

**Build health (MEASURED):** build **SUCCEEDED**, zero compile errors, 16 warnings. `xcodebuild` exited `** TEST FAILED **` solely because of the 4 test failures.

## 1.2 The prompt's "733+ tests" claim — **REFUTED as a current figure**

The prompt (line 66: *"Existing 733+ test baseline"*) traces to `VALIDATION_FRAMEWORK.md:19`, asserting `733 passed 0 failed 2 skipped`.

**MEASURED refutation:** passed is **812**, not 733. **`0 failed` is no longer true** — there are 4. The claimed run was serial on an *iPhone 17 Pro* Simulator; this run was parallel on an *iPhone 16 Pro*. **Only the skip count of 2 reproduced.**

**READ:** `VALIDATION_FRAMEWORK.md` is untracked (`git ls-files` returns nothing). The 733 figure has **no commit provenance**. **Replace it everywhere with: 819 executed cases / 812 passing, iPhone 16 Pro Simulator, parallel.**

## 1.3 The 4 failures are pre-existing and documented

**MEASURED:** all 4 are in `DAQPalTests/SegmentCellScannerTests.swift` (7 tests in that suite), matching commit `4f9ca85`'s "KNOWN FAILURES — 4 of 7 tests fail":

- `testCellsReconstructTheReadingThroughSevenSegmentSampler`
- `testDecimalPositionAcrossFormatBattery`
- `testNeverReportsAWrongPositionAcrossPresets`
- `testProportionalFaceAlsoSegments`

Assertion text (MEASURED, verbatim from the bundle) matches three documented defects: no ink run for the separator on `99.9`/`0.001`/`100.0`; moderate-inverted preset reports decimal position `Optional(3)` where `Optional(2)` is correct; `SevenSegmentSampler` decodes `99.9` as `"000"`.

**Counting trap avoided:** `xcodebuild`'s trailing "Failing tests:" block lists **7 lines for 4 distinct tests**.

**Decision-relevant, with a correction (over-engineering critique #7).** A *wrong* decimal position is a silent factor-of-ten error — **in code that does not run.** READ: `SegmentCellScanner` is referenced by exactly two files, itself and its test. Calling this "the most dangerous known defect in the repo" (as an earlier draft did) was wrong: it is a defect in an *experiment*, not in the product. The honest options are **delete it, or quarantine it as explicitly dev-only** — either takes the suite to 812/812 green at zero product risk. "Fix the four tests" is the most expensive of the three options and is no longer recommended.

## 1.4 The 2 skips and the 1 hidden expected failure

- **Skips (MEASURED):** `RecognitionPipelineTests.testGarbageFrameIsRejected` and `testStableVoltageReading` — both `XCTSkip` because **no real-video ground-truth fixture ships** (`Fixtures/` contains exactly one PNG).
- **Expected Failure (MEASURED):** `WindowSubFieldTests.testNoSingleReadingValueOffersASpuriousChoice` (`WindowSubFieldTests.swift:445`) is the **only** `XCTExpectFailure` in the tree. It is a genuine false-positive test and is **currently unsatisfied**: single readings split at the decimal point. A real known defect held invisible under a green suite.

## 1.5 Gate 2 status: **FAIL** → therefore Gate 4 is unreachable (see H1)

| Gate 2 requirement | Status |
|---|---|
| False lock rate | **NOT MEASURED, and not measurable with what is in the repo.** No corpus with distractor numbers; no metric defined; no ground truth. |
| OCR accuracy | **NOT MEASURED on real devices.** The only real-video suite skips for missing fixtures. All accuracy figures in the repo are synthetic DSEG7/sans renders. |
| Latency | **PARTIAL, REPO-RECORDED only, burst-only.** See §7.1 for the full caveat set. |

**A further honesty note (READ):** the frequently-quoted "~382 ms `.accurate` / ~11 ms `.fast`" at `FrameProcessor.swift:68`, `DualPassVisionOCR.swift:14`, and `ARCHITECTURE.md:428/478` is flagged in `OCR_DEVICE_BENCHMARK.md:194` as a **Simulator** figure describing the Mac. It must never be cited as a DAQPal device latency. Those comment sites should be corrected.

---

# 2. WHAT ALREADY EXISTS

The prompt says *"Do not duplicate existing functionality."* Honoring that is the load-bearing part of this report, because **most of the proposed pipeline is already built, and one stage of it has no substrate at all.**

## 2.1 The PART 2 hierarchical pipeline, mapped stage by stage

All rows **READ**.

| Proposed stage | Exists? | Component | Notes |
|---|---|---|---|
| Camera Frame | **YES** | `CameraManager`, `LiveCameraFrameSource`, `FrameProcessor` | One `AVCaptureSession`, `.hd1920x1080` (fallback `.high`), back wide, one `AVCaptureVideoDataOutput`, 32BGRA, `alwaysDiscardsLateVideoFrames = true`, connection rotated 90°. Delegate → `AsyncStream(.bufferingNewest(1))` → **one serial drain `Task`** (see H3). |
| Scene Understanding | **NO** | — | Nothing classifies the scene. |
| **Device / Instrument Detection** | **NO — no substrate whatsoever** | — | §3.1. `Device.model` ("FLUKE 87V") is free text typed by the user. Consumers: `CaptureHeaderView.swift:46`, `FormatConfigurationSheet.swift:367`, and `AppState.swift:653` (propagating model to a child device). **No pipeline code reads it.** |
| Device Tracking | **N/A** | — | Screen tracking exists; device tracking does not. |
| Display-Window Detection | **YES** | `ScreenCandidateDetector` (actor) | `VNDetectRectanglesRequest` + a **whole-frame** `VNRecognizeTextRequest` (level injectable, `.fast` default, `ScreenCandidateDetector.swift:180`) batched into one handler. 5-signal fusion (`TargetLock.swift:46-50`): geometry 0.35, aspect 0.10, text 0.20, numeric 0.15, stability 0.20. Cross-frame identity by bbox IoU ≥ 0.5. |
| Display Geometry / Quad | **YES** | `ScreenQuad` | 4 normalized TL-origin points, semantic corners, area/aspect/roll/convexity/IoU/interpolation. |
| Perspective Rectification | **YES** | `ScreenQuad.Homography` + `PerspectiveNormalizer` | Hand-rolled 3×3 DLT, exact 4-point, Gaussian elimination w/ partial pivoting, nil on singular. Pixel warp via `CIPerspectiveCorrection`, capped at 2048 long edge. **Runs at ≤1 Hz, not per frame.** |
| Seven-Segment Detection | **PARTIAL, stubbed** | `DigitSegmenter`, `SevenSegmentSampler`, `NumberBandSplitter`, `WindowFieldAnalyzer` | `DigitSegmenter` is 38 lines of fixed-pitch arithmetic that never looks at a pixel. `SevenSegmentSampler` is a real segment decoder and **is wired**, but only on `constrainToFormat` devices, using the stub geometry. |
| OCR | **YES** | `VisionOCR`, `DualPassVisionOCR`, `OCRManager` | `VNRecognizeTextRequest`, language correction off, en-US, top-3 candidates, ROI passed as Vision `regionOfInterest` (**no buffer crop**). Dual-pass: `.accurate` first, `.fast` rescues. `OCREngine` is the single seam. |
| Semantic Validation | **YES, extensive** | `FormatValidator`, `PhysicalValidator`, `TemporalFilter`, `TemporalConsensus`, `ConfidenceEngine` | Strict grammar + lenient extraction; confusable normalization; **absent separator on a declared-decimal format is rejected as `.ambiguousDecimal`, never emitted as an integer**; range + rate gates; 7-observation written-form consensus against 808↔80.8 flips; multiplicative fusion where final ≤ ocrConfidence. |
| Value → CSV | **YES** | `MeasurementStore`, `CSVExporter` | Rejected readings exported alongside accepted ones with a `raw_text` column. |

## 2.2 The PART 8 state machine, mapped onto `SnapState`

**READ.** `SnapState` (`TargetLock.swift:116`) = `manual | candidateDetected | magneticAttraction | snapPreview | locked | trackingDegraded | reacquisition`.

| Proposed state | Existing counterpart | Verdict |
|---|---|---|
| `SEARCHING` | `.manual` (L118) | **Full match.** |
| `DEVICE_DETECTED` | — | **DOES NOT EXIST. No substrate.** |
| `DISPLAY_CANDIDATE_FOUND` | `.candidateDetected` (L120), enters at fused ≥ 0.60 within releaseRadius 0.30 | **Full match.** |
| `DISPLAY_CONFIRMED` | The commit transition: 3 consecutive frames at ≥ 0.90 **and** distance ≤ alignmentRadius 0.06 (`MagneticSnapEngine.swift:430-450`) | **Partial — the repo is *more* granular** (`.magneticAttraction`, `.snapPreview` are intermediate rungs the proposal lacks). |
| `TRACKING` | `.locked` (L127), `VNTrackRectangleRequest` every frame | **Full match.** |
| `OCR_ACTIVE` | Two booleans, not a state: `ScreenLockUpdate.measurementsValid`, per-device `LiveReading.locked` (1.0 s OCR recency) | **Not a state. Neither participates in any state machine.** |
| `TEMPORARY_OCR_FAILURE` | — | **DOES NOT EXIST.** Nearest artefact is `AppState.lockTimeout = 1.0 s`, UI-layer only, feeds nothing back. |
| `TRACKING_ONLY` | `.trackingDegraded` (L129) triggers **purely on tracker confidence < 0.55**, carrying zero OCR information | **DOES NOT EXIST with the proposed meaning.** |
| `OCR_RECOVERED` | — | **DOES NOT EXIST.** |
| *(existing, unproposed)* | `.reacquisition` (L131) — detector runs hot at 0.1 s; relock re-stamps the fresh candidate with the **original** target id so field authoring survives; 5 s timeout → `.manual` | **The repo has a state the proposal does not.** |

**Conclusion.** The **geometry half already exists in a strictly more detailed form** — 7 states, paired enter/exit hysteresis (0.60/0.50, 0.70/0.60, 0.80/0.70, `enterLock` 0.90 one-way, degraded 0.55, lost 0.30), radiusHysteresis 1.25×, switchMargin 0.10, candidateGrace 0.4 s on the *detector* clock, framesToLock 3, framesToRecover 2, user-rejection suppression — **plus two veto subsystems the proposal does not contain.** The **OCR half does not exist**, and coupling is **strictly one-directional**: tracking gates OCR (`MeasurementProcessor.trackingValid` emits an explicit `.trackingInvalid` rejection rather than silence), but **no OCR outcome ever reaches `MagneticSnapEngine` or `ScreenLockPipeline`.**

## 2.3 Two veto subsystems already exceed the proposal

**READ.**

- **`TrackVerifier`** — verifies a lock using **only detector evidence, never the tracker's own confidence**. Verdicts `corroborated / diverged / transit / unsupported(strikes)`; `diverged`/`transit` are hard vetoes (confidence forced to 0); 3 `unsupported` strikes caps confidence at 0.4. Motion coupling as a **rate** (0.07 normalized units/s), corner-level concentric agreement, asymmetric testimony bars (0.60 vs 0.40-with-stability). v1/v2 `Config` for ablation.
- **`AppearanceSentinel`** — per-frame 32×20 bilinear luma patch sampled through the canonical→frame homography, zero-mean NCC vs a reference captured at lock and refreshed on every corroborated detection. NCC < 0.35, or variance < 5% of reference, for 4 consecutive frames = hard veto. **Explicitly abstains when it cannot judge.**

**MEASURED (this session, macOS 26.5.2, Apple silicon, Xcode 26.6, synthetic 640×480 frames — NOT an iPhone; harness `scratchpad/drift.swift`, single run per scenario, values printed to 3 dp on a sparse frame schedule):** `VNTrackObjectRequest` rev2 in an occlusion scenario froze its box, reported confidence 0.218 during occlusion, then after the target reappeared elsewhere **reported 0.939 at frame 30 and 0.893 at frame 35 while its box was still frozen and wrong (IoU 0.484 and 0.349)**, genuinely re-acquiring only at frame 40. **Correction (evidence critique M6):** frames 31–34 and 36–39 were never printed, so the earlier claim of "10+ consecutive frames ≥ 0.88" is interpolation, not observation. The defensible statement is: **at two separately sampled frames spanning at least 10 frames of wall time, confidence was ≥ 0.89 while localization was badly wrong.** Apple's header concedes the general point: *"Confidence can always be returned as 1.0 if confidence is not supported or has no meaning."* **Vision's `confidence` is not a usable off-target detector.**

*Artifact caveat:* the macOS probe runs left **no retained raw output** — only the harness sources (`trk.swift`, `trk2.swift`, `trk3.swift`, `drift.swift`, `flow.swift`, `flow2.swift`) survive in the session scratchpad. Unlike the baseline (`/tmp/daqpal_baseline.xcresult`) and the OCR benchmark (checked in), these MEASURED claims have no inspectable artifact. Re-run before relying on them.

## 2.4 What actually ships by default (see H4)

**READ.** `AppState.screenLockEnabled = false` (`AppState.swift:96`), `ScreenLockPipeline.isEnabled = false` (`ScreenLockPipeline.swift:126`). The whole intelligent stack requires a header toggle.

**The shipping default is: Vision text OCR inside a rectangle the user drew with their finger**, plus `AppState.applyROITracking` (position-only OCR-feedback servo: gain 0.3, deadband 0.004, max step 0.02 normalized/frame; never resizes, never rotates, disabled during editing).

**INFERRED:** in the shipping default, *the human already performs device-aware detection*, and does so by **drawing** — which supplies localization, scale, and identity at once. **The prompt's motivating failure mode is a failure mode of systems that auto-select. DAQPal's default does not auto-select.**

---

# 3. THE REAL GAP

## 3.1 Device identity does not exist, at any level

**READ (exhaustive grep over the app target):**

- Zero occurrences of `MLModel`, `VNCoreMLRequest`, `MLFeatureProvider`, `import CoreML` in any Swift file.
- No `.mlmodel` / `.mlmodelc` / `.mlpackage` / `.onnx` / `.tflite` / `.pt` / `.weights` anywhere in the tree.
- No CoreML reference in `project.pbxproj`. `DAQPal/` contains exactly four non-Swift files: **three** asset-catalog JSON files and a `.DS_Store` (corrected per evidence critique m13).
- Exactly three Vision request types in the app: `VNRecognizeTextRequest`, `VNDetectRectanglesRequest`, `VNTrackRectangleRequest`.
- No device classifier, no instrument database, no logo/bezel/template matching, no display-technology detection (LCD vs VFD vs OLED is never determined; polarity is detected per-cell from border luminance — a pixel property, not a device identity), no per-model recognition profile.
- `CorpusManifest.swift` has the richest device vocabulary in the repo but its own header says *"DEVELOPMENT ONLY — nothing in Corpus/ is reachable from a shipping capture path."* Grep confirms.

**Every piece of instrument knowledge in DAQPal — digit count, decimal position, unit, range, sign — is user-entered via `DisplayFormat` or seeded as an unconstrained suggestion.**

## 3.2 The decisive gap: no measured false-lock rate, and the corpus that would produce one is not free either

- **READ:** no real-world footage corpus exists. `RecognitionPipelineTests` skips both its tests for missing fixtures.
- **MEASURED (this session, corrected per evidence critique M2):** **142 of 856** test declarations (**16.6%**) match negative/safety stems (`never|reject|does not|refus|veto|spurious|garbage|degenerate`); the narrower literal word list yields **110 (12.8%)**. An earlier draft's "203 of 819 (24.8%)" does not reproduce under any filter and is withdrawn. Adversarial testing remains a genuine strength — but these are **boolean assertions on hand-picked cases; nothing computes a false-positive rate over a labelled population.**
- The one test that *does* sweep a population (`WindowSubFieldTests.testNoSingleReadingValueOffersASpuriousChoice`, 40 values) is masked by `XCTExpectFailure` and currently fails.
- **SURVEYED, negative result:** the literature agent located no benchmark, dataset, or paper evaluating instrument-display reading in a cluttered scene containing distractor numbers. Every instrument-reading dataset found (UFPR-AMR 2,000; Copel-AMR 12,500; UFPR-ADMR 2,000; YUVA EB 169) consists of deliberately-framed photographs *of the meter*. Their enumerated challenges are dust, orientation, illumination, glare, rotating digits — **not competing numbers elsewhere in the frame.**

**Correction on the fix (over-engineering critique #1, accepted).** An earlier draft proposed closing this gap with a **synthetic** adversarial corpus and called the ground truth "free." That is the wrong primary instrument. A synthetic false-lock rate measures **the compositor's assumptions about what a distractor looks like**, and the same team would then tune against it — a fitted number, not a measured one. Ground truth being free is true and irrelevant; the **scene distribution** is the expensive part, and synthesizing it means inventing rather than sampling it.

**The corrected plan: 20–30 real bench recordings with real clutter, hand-labelled once, scored on a single binary question — did the published reading come from the instrument, yes or no.** That is single-digit hours of labelling and produces the exact number the decision needs. The synthetic harness is retained, but demoted to a **regression** vehicle (cheap, deterministic, catches re-breakage) rather than the **measurement** vehicle. INFERRED cost of building the synthetic harness honestly: **1–3 weeks of engineering** (compositing, truth-overlap metric, `FixtureFrameSource` buffering fix) — not zero.

## 3.3 The instrumentation cannot report the app's own behaviour

**READ.** `PipelineMetrics` is a well-built, allocation-free, pull-based ring recorder (240 samples/stage, 2 s window, p50/p95/p99, DEBUG-only, nearest-rank percentiles, absent stages report nil rather than 0). Production call sites:

| Facility | Production call sites |
|---|---|
| `.tracking` | 3 (`VisionScreenTracker`) |
| `.detection` | 1 (`ScreenCandidateDetector`) |
| `.analysis` | **3** — `NumberBandSplitter`, `ScreenFieldAnalyzer`, `PerspectiveNormalizer` |
| **`.capture`** | **0** |
| **`.ocr`** | **0 — the most expensive stage is the least instrumented** |
| **`.endToEnd`** | **0 — glass-to-glass latency is UNMEASURABLE with what is in the repo** |
| `recordProcessedFrame()` | **0** |
| `recordQueueDepth` / `recordQueueOverflow` | 0 |
| `beginFrame()` / `countWorkUnit(...)` | 0 |

**Correction (evidence critique M9, verified):** an earlier draft counted `.analysis` at 5, including `SegmentCellScanner.swift:217` and `DecimalRescue.swift:252`. Both of those `measure(.analysis)` calls sit **inside dead code** (§3.5), so effective production coverage is **3**. The table overstated coverage inside the section arguing coverage is thin.

All three instrumented stages live in the screen-lock path, **which is off by default** — so in the shipping configuration the HUD records essentially nothing.

**Real defect (READ):** because `recordProcessedFrame()` is never called in production, `dropRate = dropped / (dropped + processed)` always evaluates with `processed == 0`. The HUD renders **"N/N" and "100%" in the alarm colour the instant any frame is dropped** (`PipelineDebugOverlay.swift:55-62`, `PipelineMetrics.swift:192-195`). This is the one place where an unmeasured quantity is presented as a measured number. **Fix it or remove the row.** The dropped *count* is also partial: only the drag gate increments it; frames discarded by `alwaysDiscardsLateVideoFrames`, by `.bufferingNewest(1)` displacement, and by the recorder's not-ready path are invisible.

## 3.4 Free signals currently being discarded

**MEASURED (this session, macOS, synthetic frames — NOT iPhone; single run per scenario):** `VNTrackRectangleRequest` — the request DAQPal actually uses — **does not drift silently. It throws.** In all three disturbance scenarios the first disturbed frame raised Vision error Code=9:

```
Tracking of VNRectangleTracking_BottomRightTracker failed:
confidence = 0.000000; threshold = 0.650000
```

Apple's rectangle tracker applies a hard **internal confidence floor of 0.65 per corner sub-tracker** and fails the request rather than returning a degraded observation. Observed failing confidences: 0.000000 (vanish, occlude), 0.088986 (decoy swap). Control run (smooth motion, no disturbance) held IoU 0.967–0.991 across **the sampled frames of a 45-frame loop** (corrected from "all 44 frames" — the harness prints on a sparse schedule) — **no measurable drift under benign conditions.**

**READ:** `VisionScreenTracker.perform()` wraps `handler.perform` in `do/catch` and returns `nil` on any error (`VisionScreenTracker.swift:322-326`), collapsing *"Vision self-vetoed, and here is which corner died"* into the same `nil` as *"no result"*.

**INFERRED, with a required precondition (over-engineering critique #11, accepted):** surfacing that `NSError` as a distinct `TrackVerifier` verdict is cheap and names *which corner* lost lock, which plugs into corner-agreement logic that already exists. **But nobody checked whether the existing `nil` path already degrades in the same frame.** If it does, the win is zero and the change is unnecessary. **Verify before writing code.**

Secondary free signal (**MEASURED**): in the permanent-vanish scenario, `VNTrackObjectRequest` reported confidence 0.218 with a frozen box across every sampled frame of that phase. **Corrected phrasing (evidence critique M6):** the honest statement is *"confidence constant to 3 dp with no box motion across the sampled frames"* — not "exactly 0.218 for 25 consecutive frames with a bit-identical box," which overstates both the instrument's resolution and its sampling.

## 3.5 1,932 lines built, tested, and unreachable

**READ.** Three modules have **zero production call sites** (only `DAQPalTests` references them):

| Module | Lines | Consequence |
|---|---:|---|
| `DecimalRescue.swift` | 815 | The **pixel-level decimal-dot detector does not run.** Production decimal confidence comes entirely from `FormatValidator`'s four text-level POLICY constants (1.0 / 0.9 / 0.8 / 0.75), which the file itself labels *"POLICY weights, not measurements"* and *"a starting calibration."* |
| `SegmentCellScanner.swift` | 786 | 4 of its 7 tests fail (§1.3). |
| `DisplayFormatInference.swift` | 331 | `MeasurementProcessor.swift:454` passes `formatPrior: nil` **unconditionally**, so `corroboratedByPrior` is always false and `TemporalConsensus`'s prior-corroboration route is dead code. |

**Correction (over-engineering critique #8, accepted).** An earlier draft recommended **wiring `DecimalRescue`** on the grounds that "815 lines already exist." That is a sunk-cost argument. This code has never run on a camera frame; its tests are synthetic; and it would be inserted into the path that produces **exported measurements**. The cost is not the call site — it is owning a new pixel-level failure mode in the export path with **no real-world accuracy baseline to detect regressions against.**

The cheaper 80%: the user already declares the decimal position via `DisplayFormat`, and `FormatValidator` already rejects a missing separator as `.ambiguousDecimal` rather than emitting an integer — the correct conservative behaviour, shipping today. **If the four POLICY constants are the concern, measure whether they are wrong before replacing them with 815 lines.** The recommended action for all three modules is **delete or explicitly quarantine as dev-only**, not wire.

## 3.6 Smaller but real gaps

- **`isUserDragging` is dead-wired.** `AppState.screenLockInputs()` computes it (`AppState.swift:139`) but `FrameProcessor` passes the literal `false` (`FrameProcessor.swift:90`). Every drag-aware branch in `ScreenLockPipeline:353` and `MagneticSnapEngine:362/427/430/573` is unreachable. Masked, not symptomatic, because `FrameProcessor.swift:75` already drops every frame during interaction. **Fix the wiring or delete the branches.**
- **Per-frame OCR reads are not rectified.** `PerspectiveNormalizer.canonicalImage` has exactly one production caller — the ≥1 Hz field-discovery pass. Every per-frame read uses the **axis-aligned bounding box** of the projected field quad against the **unrectified** frame (`ScreenField.swift:94`, `MeasurementProcessor.swift:266`). The code flags this looseness under strong perspective (`ScreenField.swift:89-93`). See §7.2 for the corrected, *conditional* remedy.
- **`FixtureFrameSource` uses the DEFAULT unbounded `AsyncStream` buffering** (`FixtureFrameSource.swift:39`), unlike all three production sources. **Any replay test therefore does not reproduce production's newest-frame-wins drop behaviour.** Must be fixed before replay is used to measure anything.
- **No thermal awareness at all.** MEASURED grep: **zero** occurrences of `thermalState` or `lockForConfiguration` anywhere in `DAQPal/`. See §7.4 — the feasibility critique is right that this is not a footnote.
- **Stale docs:** `SevenSegmentSampler.swift:17` claims it is "pipeline-inert until that wiring lands" — the wiring landed (`MeasurementProcessor.swift:520`). `DecimalRescue`'s header reads as though it were live when it is not. Anyone auditing from file headers gets both backwards.

---

# 4. ARCHITECTURE COMPARISON (A–F)

### Architecture A — Camera → OCR
**Status: this is essentially what ships, with one critical addition the prompt's diagram omits — a human-drawn ROI.** Full-frame OCR would be genuinely bad. But DAQPal does not do full-frame OCR *in the default path*; it passes the user's ROI as Vision `regionOfInterest` over the shared buffer with no crop. **INFERRED:** "A + user ROI" is a far stronger baseline than the prompt credits. Its weakness is *ergonomics* (the user must draw and re-draw) and *decimal integrity* — not false locks.

### Architecture B — Camera → Generic Display Detection → OCR
**Status: fully built, off by default.** **The correct next move is not to build B — it is to measure B.**

**Corrected false-lock analysis (over-engineering critique #2, accepted).** An earlier draft claimed geometry+aspect+stability = 0.65 "is enough to clear the lock gate with no text at all." **That is wrong.** READ, verified: `TargetLock.swift:184` sets `enterLock = 0.90`. 0.65 < 0.90, so a text-free, numeric-free candidate is **structurally incapable of locking.** The 0.65 figure clears `enterDetection = 0.60` — the *candidate suggestion* gate — and the source comment says this is deliberate: *"Geometry + aspect + stability sum to 0.65, so a text-free but strongly rectangular, stable display still clears the 0.60 detection threshold."*

**Consequence: the `ScreenSignalWeights` re-weighting recommended in earlier drafts is struck.** Text/numeric evidence is already mandatory at the lock gate. The residual exposure is that a textbook page can be *suggested* as a candidate — a UI annoyance, not a false lock. If measurement later shows candidate suggestions are the problem, the 80% fix is **one constant** (`enterDetection`), not a re-weighting of a fusion whose behaviour has never been measured.

**Remaining CITED risk for B:** its primary signal is `VNDetectRectanglesRequest`, which will happily propose a monitor or a page. That is a candidate-stage exposure, tunable without any new model.

### Architecture C — Camera → Seven-Segment Detection → OCR
**Status: partially built, currently broken, and largely dead code.** `SevenSegmentSampler` is wired but only on `constrainToFormat` devices — false for every device by default — so on a default device the cross-check factor is `.notAvailable` (neutral). It inherits `DigitSegmenter`'s stub geometry. `SegmentCellScanner` has no production call site at all.
**CITED support for the *principle*:** the largest FP reduction found in the text domain — 28.16% on ICDAR 2015 (citation unpinned) — came from making the *text model* stricter (character bigrams), not from scene context. **But C alone does not generalize** — the repo's own synthetic-corpus notes record `.fast` at 33.3% vs `.accurate` 14.6% on seven-segment yet 68.8% vs 93.8% on raster/OLED. A segment-only architecture abandons non-segment displays.

### Architecture D — Camera → Device Detection → Generic Display Detection → OCR
**Status: blocked at the first stage.** No device detector, no dataset, no prior art (§6). **CITED, decisive:** Divvala's context ablation gives +3.8 mAP overall but only **+0.8 for man-made objects**, and `tvmonitor` — the closest analogue to an instrument display — moved 32.9 → 33.3. DPM context rescoring gives +2.31 mAP overall and `tvmonitor` .384 → .391. **The class most like DAQPal's target gains essentially nothing from scene context in two independent, properly-ablated studies.**
**CITED counter-evidence (unpinned):** ContextShift (2026) finds context-dependence in modern detectors manifests as **false negatives rising up to 227% and prediction volume falling to −44%, "while false positives remain relatively stable or decline."** A context-conditioned DAQPal would be at greater risk of *missing* a multimeter on an unusual bench than of usefully rejecting a number on a page. For a data-acquisition app, that trade is backwards.

### Architecture E — Device → Device-Specific Display Window → Homography → Seven-Segment → OCR
**Status: maximal proposal, worst cost/evidence ratio.** **CITED (unpinned):** Yu et al.'s oracle shows context is 70.68% informative *with ground-truth boxes and labels*, yet realized gain from real, noisy detector-derived context collapses to **+2.78 mAP**. DAQPal's proposed context *is* a noisy detector. **INFERRED:** the per-device-prior idea also fails a simpler test — "IR gun display is near the rear housing" only helps once you have localized and classified the housing, i.e. it multiplies the error of two stages that do not exist to save a stage (display localization) that already works.

### Architecture F — Camera → Vision Classifier → Device Class → Expected Display Location → …
**Status: worst generalization, silent failure mode.** A whole-frame classifier gives a label, not a localization. A closed-set classifier confidently mislabels an unseen instrument and applies the wrong spatial prior — *worse* than no prior.

### Ranking

| Rank | Architecture | One-line verdict |
|---:|---|---|
| **0** | **Do nothing to the lock path until it is measured** | **The actual recommendation. Not a placeholder — a real, defensible outcome.** |
| 1 | **A + user ROI (shipping)** | Highest false-lock resistance per unit complexity; a human supplies device context with perfect semantics. Weak on ergonomics and decimal integrity. |
| 2 | **B (already built, off)** | Should be *measured*, not rebuilt or blind-tuned. |
| 3 | **A/B + abstain + conditional rectification** | Best evidence-to-cost ratio *if* measurement shows a problem. No new model. |
| 4 | **C** | Right principle, dead/broken implementation, poor generalization alone. |
| 5 | **D** | Blocked on a dataset that does not exist; literature predicts near-zero gain for display-like classes. |
| 6 | **E** | Maximal cost, floor-level expected gain. |
| 7 | **F** | Silent confident failure on unseen devices. |

---

# 5. DECISION MATRIX (PART 13)

## 5.1 Calibration disclosure — read this before the table

PART 13 requires this matrix, so it is retained. **The over-engineering critique's objection — that an ordinal table makes guesses look like measurements — is correct in substance, so the table is demoted below the prose and every column is labelled by evidence class.** The arguments in §4, §9, and §10 do not depend on it.

- **Accuracy** / **False Lock Resistance**: **INFERRED judgement.** No measured false-lock rate for DAQPal exists, and no published study measures the equivalent quantity (§3.2). Anchored where possible to CITED effect sizes.
- **iOS Performance**: partially anchored. REPO-RECORDED OCR 41.8–52.2 ms (Debug, burst) on iPhone 12 Pro Max; MEASURED-on-macOS tracker numbers. **No iPhone measurement exists for any proposed new stage.**
- **Model Size**: the only objective column. 0 bytes for everything shipping is a fact.
- **Development Complexity**: anchored to READ built-vs-not-built and to the SURVEYED dataset absence.
- **Generalization**: INFERRED, anchored to CITED ContextShift and to the closed-set nature of any classifier.

10 = best. Ordinal within this table only.

## 5.2 The table

| Method | Accuracy | False Lock Resist. | iOS Perf. | Model Size | Dev Complexity | Generalization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Generic OCR (full-frame, as prompt defines) | 6 | 2 † | 6 | 10 | 10 | 8 |
| Seven-Segment Detector | 4 | 6 | 9 | 10 | 6 | 3 |
| Device Classifier | 3 | 3 | 7 ‡ | 7 | 4 | 2 |
| Device Detector | 4 | 5 | 5 ‡ | 6 | 2 | 2 |
| Device + Display Detector | 6 | 6 | 4 | 5 | 2 | 3 |
| Device + Display + Tracking | 6 | 7 | 4 | 5 | 2 | 3 |
| Device + Display + Seven-Segment Model | 7 | 7 | 3 | 4 | 1 | 3 |
| Hybrid CV + ML | 7 | 8 | 8 | 9 | 7 | 7 |

**† Critical footnote, corrected.** "Generic OCR" is scored as the prompt defines it: full-frame OCR with no region restriction. **DAQPal's default measurement path does not ship that** — it ships generic OCR *inside a user-drawn ROI*, which scores **FLR ≈ 7** and **iOS ≈ 7**. **However (feasibility critique #3, verified and accepted): DAQPal *does* run a full-frame `VNRecognizeTextRequest`** inside `ScreenCandidateDetector.detectPass` (`ScreenCandidateDetector.swift:217-236`), batched with `VNDetectRectanglesRequest` into one `VNImageRequestHandler(cvPixelBuffer:)` over the whole 1080×1920 buffer with **no `regionOfInterest`**. It is `.fast` by default and therefore cheap relative to `.accurate`, but it is a full-frame text pass — and it runs at 0.2 s acquiring / 0.5 s locked / **0.1 s (10 Hz) while recovering**. **So Architecture B — the one this report tells you to measure — contains the full-frame OCR that Architecture A's critique calls bad.** It has never been timed.

**‡ Corrected (feasibility critique #4).** Earlier iOS-performance scores for the two device rows were partly justified by "ANE-friendliness." That justification is withdrawn (§7.5): `MLComputeUnits.all` is a *request*, not a placement guarantee, and this repo already has a REPO-RECORDED instance of a model asking for ANE and silently not getting it.

## 5.3 Justification, one row at a time

- **Generic OCR** — Accuracy 6: reads legible displays reliably when framed. FLR 2 as specified; ~7 as shipped in the default path, because the human draws the box. Size 10 / Complexity 10: zero bytes, zero work, Vision is framework code. Generalization 8. *Accuracy and FLR are judgement; Size and Complexity are facts.*
- **Seven-Segment Detector** — Accuracy 4: `SevenSegmentSampler` mis-decodes `99.9` as `"000"` and `SegmentCellScanner` reports `Optional(3)` where `Optional(2)` is correct (both MEASURED, §1.3) — **in code with no production call site**. FLR 6 on the CITED bigram analogue. iOS 9: deterministic pixel arithmetic. Size 10. Complexity 6. Generalization 3: segment displays only.
- **Device Classifier** — Accuracy 3: a whole-frame label localizes nothing, so it cannot gate a region. FLR 3: CITED Divvala man-made +0.8 mAP is near-noise. iOS 7 (was 8; ANE justification withdrawn). Complexity 4: needs a dataset that does not exist. Generalization 2.
- **Device Detector** — Accuracy 4 / FLR 5: localizes, so it can gate — but CITED display-like evidence (`tvmonitor` .384→.391) predicts near-zero realized gain. iOS 5 (was 6): see §7.2 on p99 jitter inside a serial drain, and §7.6 on the pixel-buffer retention constraint. Size 6 (CITED EfficientDet-lite1 = 5.8 MB weights; §7.7 argues the *real* increment is 20–40 MB RSS). **Complexity 2: SURVEYED — the bounded survey found no public dataset annotating device bodies alongside their displays (§6).** Generalization 2.
- **Device + Display Detector** — two stages compound; CITED Yu et al. show noisy context collapses a 70.68%-informative oracle to +2.78 mAP realized. Complexity 2: two datasets, one nonexistent.
- **Device + Display + Tracking** — FLR 7, highest of the device-first rows, because tracking supplies temporal identity and **that half is already built and is more sophisticated than the proposal** (§2.2, §2.3).
- **Device + Display + Seven-Segment Model** — Accuracy 7 if it worked. **iOS 3: REPO-RECORDED OCR alone at 41.8–52.2 ms (Debug/`-Onone`, n=72, burst) already consumes more than one 33.3 ms frame period on an A14 — and because the drain is serial, the effect is a lower delivered frame rate, not a queue.** Complexity 1: three models, two datasets, one nonexistent.
- **Hybrid CV + ML** — defined as: existing classical geometry + existing tracking and veto layers + explicit abstention + *optionally* one small display-quad corner regressor. FLR 8, the highest, because abstention is the best-evidenced lever (**CITED Laroca +3.16 pp from confidence rejection**; see §5.5 for the caveat on comparing that against the +0.97 pp geometric-stage figure). iOS 8: nothing new runs per frame. Complexity 7.

## 5.4 The recommended row — corrected and shrunk

An earlier draft added a row scoring **9/10 on Development Complexity** for a bundle containing eight items, two of which were features (per-instance registration, negative-exemplar memory) and one a high-risk integration of never-executed pixel code (`DecimalRescue`). **The over-engineering critique is right that this was a bundling trick** — precisely the "veneer of precision over a judgement" §5.1 apologizes for. The bundle is dissolved and replaced with two honest rows:

| Method | Accuracy | FLR | iOS Perf. | Model Size | Dev Complexity | Generalization |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **Ship as-is; fix defects; measure** (§10 Phase 0–1) | **8** | *unmeasured* | **9** | **10** | **10** | **8** |
| **+ abstain path + conditional rectification** (§10 Phase 2, *only if Phase 0 shows a problem*) | **8** | *unmeasured, hypothesis 8* | **8** | **10** | **7** | **8** |

**FLR is left blank on purpose.** Scoring false-lock resistance for the recommended option would be inventing the number this whole report says does not exist. **Zero bytes of model. Zero new datasets.**

## 5.5 Citation caveat on the strongest number in the table

**Correction (evidence critique M10, accepted).** The Laroca figures are quoted off **different baselines**: rectification `+1.55 pp` from **95.43 → 96.98**, and confidence rejection `+3.16 pp` from **95.87 → 99.03** (with "an extra geometric stage" at `+0.97 pp` and 78 → 55 FPS). Differing baselines imply different configurations or different papers. **The "on the same system" head-to-head framing used in earlier drafts is withdrawn.** These remain the best-evidenced accuracy levers in the review, but the head-to-head ordering (abstention > extra geometry) must have its primary source and table pinned before Phase 2 is scheduled on it.

---

# 6. THE DATASET PROBLEM (PART 4)

## 6.1 Public dataset survey

**SURVEYED (dataset landing pages read in-browser this session; archives were NOT downloaded; Roboflow result counts are volatile and were not timestamped).** **Correction (evidence critique M3, accepted):** earlier drafts tagged this "MEASURED-BY-INSPECTION" and then silently upgraded it to bare "MEASURED" where the conclusion was drawn. Browsing is not measurement, and a **universal negative over all public datasets cannot be established by a bounded catalogue browse.** The claim below is a bounded survey result, not a proof of nonexistence.

| Dataset | Images | License | Display annot. | Digit annot. | Decimal class | **Device body** |
|---|---:|---|---|---|---|---|
| Copel-AMR | 12,500 | Registration + terms | 4 corners | per-digit bbox | no | **NO** |
| UFPR-AMR | 2,000 | **Non-commercial only** | counter bbox | per-digit | no | **NO** |
| YUVA EB | 169 | **CC0** | text region | 985 numerals | no | **NO** |
| Kaggle 7-Seg Industrial | 1,692 | **Unknown** | none | filename labels | decimals stripped | **NO** |
| Roboflow `labmonitor/7-segment-digit-number-display` | 698 | CC BY 4.0 | **`screen` class** | 0-9 | **`.` class** | **NO** |
| Roboflow `BRIN/DMM_Digit_Detection` | 5,064 | CC BY 4.0 | none | 0-9 | **`.` class** | **NO** |
| Roboflow `Bumv/More MMD` | 123 | CC BY 4.0 | **polygon** | none | no | **NO** |
| Roboflow `bhautik-pithadiya/7-segment-display` | 948 | Public Domain | none | 0-9 | **`.` class** | **NO** |
| Roboflow `rash-oak/thermometer-2` | 288 | CC BY 4.0 | **`Reading` box** | none | no | **YES — the only one** |

**The one exception does not rescue the situation.** `rash-oak/thermometer-2` annotates both a device polygon and a `Reading` box, but its filenames (`frame_000840.png`, `frame_000845.png`, …) show it is sampled frames from **a single video of a single device in a single scene** — which is also why its reported mAP@50, precision, and recall are all exactly 100.0%. A usable *schema template*; worthless as training data.

**SURVEYED:** Roboflow Universe returned ~167 projects with a `multimeter` class and ~180 with a `thermometer` class, but these are tool-inventory / e-waste / lab-equipment datasets. The conjunctive query `class:multimeter + class:display` returned **6 results, none of them display-reading datasets.** Within the bounds of this survey, **no supervision linking a housing to its own display was found.**

**Answer to PART 4: YES, a custom dataset is required for the device stage — but drop the device stage and the requirement largely disappears**, because the display/digit stages have CC BY 4.0 and Public Domain options.

## 6.2 True cost of a custom device-body dataset — revised upward (feasibility critique #10, accepted)

**INFERRED throughout. No one has labelled a DAQPal image yet.**

Required schema: device-body box, **display quadrilateral as 4 corners**, per-digit boxes, an explicit decimal class, and a legible/illegible flag. That is **11–13 annotation actions per image**, several of them precision keypoint placements.

Scale anchors, all **CITED (unpinned except Copel-AMR/UFPR-AMR):** 487 images across 4 devices → digit-localization F1 0.80–0.87 under favourable lighting (Finnegan et al.); 2,000 images, one device family, controlled indoor → strong results (UFPR-AMR); 12,500 images, one family, in the wild → 96.98% (Copel-AMR).

**Revised INFERRED estimate.** 8–15 instrument families at 400–800 images = **3,000–12,000 images**. Published throughput for polygon/keypoint tasks at this density is **3–8 min/image**, not the 1.5–3 min an earlier draft assumed. **Labelling alone: 150–1,600 person-hours.** Plus costs the earlier estimate omitted entirely:

- **Equipment acquisition.** 8–15 families means physically owning or borrowing 8–15 instrument families. A procurement problem no hourly rate dissolves.
- **Capture time**, distinct from labelling: many scenes, lighting conditions, angles per device.
- **Re-labelling churn** after the inevitable first schema revision: **1.3–1.6×** total.
- **QC with N=1 annotator.** A solo developer has **no inter-annotator agreement**, so there is no way to know corner labels are self-consistent — and corner-label consistency is exactly what CITED Laroca's +1.55 pp rectification gain depends on. **Single-annotator corner noise can eat the entire effect being bought.**
- A **separate held-out adversarial set** with distractor numbers, not reusable from training.

**Calendar for a solo developer at ~10 sustainable focused hours/week: 150–1,600 h ≈ 4 months to 3 years.**

**And a structural point that strengthens the rejection:** 8–15 families × 400–800 images produces a corpus with **no long tail**. The failure the app actually cares about is the instrument the user owns that the model has never seen — exactly where a closed-set device detector fails silently. **No solo-feasible dataset fixes this**, so the realized gain is below even the CITED +0.4–0.7 AP.

**INFERRED conclusion: not a defensible trade, by roughly an order of magnitude.**

## 6.3 The corpus DAQPal should build instead

**Corrected (over-engineering critique #1).** Primary: **20–30 real bench recordings with real clutter, hand-labelled once with a single binary per published reading** (did it come from the instrument?). Single-digit hours. This is the only instrument that can produce a *sampled* rather than *invented* scene distribution, and it is the only thing that makes Gate 4 reachable.

Secondary, for **regression only**: a synthetic adversarial harness on existing assets — `SyntheticFrameSource` (deterministic pure function of `frameIndex`, 12 fps, 1080×1920), `DisplayPose3D` (pinhole projection of a rotated panel producing genuine trapezoids), `PoseTrajectory` (8 deterministic trajectories), `DAQPalTests/Fonts/DSEG7` + `DSEG14`. Ground truth is rendered and costs no labelling hours — **but building the harness is honestly 1–3 weeks of engineering**, and its false-lock number is fitted, not measured. Do not gate Gate 4 on it.

---

# 7. iOS PERFORMANCE PLAN (PARTS 9 + 10)

## 7.1 What is actually measured

| Item | Value | Evidence | Hardware |
|---|---|---|---|
| Dual-pass Vision OCR, ROI-restricted, 1080×1920 | mean **41.8–52.2 ms**, p50 41.5–56.7, p90 49.8–64.0, max 71.5 | **REPO-RECORDED** | iPhone 12 Pro Max (iPhone13,4, A14), iOS 26.5.2, **Debug/`-Onone`**, n=72, ~12 s burst |
| First `recognize()` in-process (absolute) | **223.0 / 266.4 / 554.7 ms** across runs C/B/A → **223–555 ms** | REPO-RECORDED | same |
| Cold *overhead* (first − second) | **155.9 / 217.4 / 507.9 ms** → **156–508 ms** | REPO-RECORDED | same |
| `VNTrackRectangleRequest` `.accurate`, steady state | **2.9–11 ms/frame**; first frame 122–184 ms | **MEASURED** this session | **macOS**, synthetic 640×480, single run |
| `VNTrackObjectRequest` rev2, steady state | **1.2–4.0 ms/frame**; first-ever call **213–1027 ms** | MEASURED | macOS, synthetic |
| `VNTrackOpticalFlowRequest`, 1280×720 | **21.6 / 28.5 / 53.8 / 62.8 ms** (low / medium / high / veryHigh) | MEASURED | macOS, synthetic high-texture |
| `supportedNumberOfTrackers` | **32**, flat across revisions × levels | MEASURED | macOS |
| `VNTrackRectangleRequest` internal confidence floor | **0.65**, emitted verbatim in the error string | MEASURED | macOS |
| **DAQPal end-to-end latency** | **UNMEASURED — `.endToEnd` has 0 production call sites** | READ | — |
| **DAQPal capture latency / delivered fps / processed fps** | **UNMEASURED — `.capture` and `recordProcessedFrame()` have 0 call sites** | READ | — |
| **Full-frame detector pass cost (`ScreenCandidateDetector`)** | **UNMEASURED — instrumented as `.detection`, never run** | READ | — |
| **Sustained-load / thermal behaviour** | **UNMEASURED — every device number above is a ~12 s burst** | READ | — |
| **Any iPhone latency for any proposed new model** | **UNMEASURED — no model exists** | — | — |

**Corrections applied (evidence critique M4, M6, M7):** the composite "cold first call 156–555 ms" is replaced by the two separate measured ranges above — no measured quantity spans 156–555. The optical-flow headline "21.6–66.0 ms" is replaced by the enumerated 1280×720 values; the 66.0 upper bound was unreconciled and may have mixed resolutions.

## 7.2 The budget argument, corrected (feasibility critique #1, accepted)

**Earlier framing — "DAQPal is already over budget" — was mechanically wrong.** READ: `FrameProcessor` is a **single serial `Task`** draining `AsyncStream(.bufferingNewest(1))`; its own header states that while `process(frame:)` runs, no new frame is pulled, so *"a slow pipeline degrades to a lower effective rate instead of building an internal queue."* **The pipeline cannot exceed the frame budget; it self-throttles by dropping.**

**INFERRED, and this is H3:** with OCR at 41.8–52.2 ms plus tracking, analysis, and two `MainActor` hops, effective throughput is plausibly **~15–21 fps against a 30 fps capture** — *unmeasured*, precisely because the counters that would show it have zero call sites.

Three consequences:

1. **"Decimate OCR to 8–10 Hz" is not a compute saving.** It is a **drain-throughput and tracking-cadence fix**: freeing the serial drain raises tracker and detector frequency and improves tracking quality. Measure it as fps and tracking stability, not as milliseconds saved.
2. **Rate decimation inside a serial drain buys jitter, not amortization.** `ScreenLockPipeline.shouldDetect(at:)` (`ScreenLockPipeline.swift:450`) gates on frame timestamp **inside the same serial await chain**. One frame in ~6 pays the entire detection cost synchronously, on top of that frame's OCR. **For a magnetic-snap UI the user judges by smoothness, so p99 frame interval is the metric that matters — and this report previously reasoned only about means.** Any proposed "2 Hz detector at 25 ms" is a periodic 25 ms spike on a drain that already has ~50 ms frames.
3. **Rectification should be conditional, not per-frame** (over-engineering critique #9, accepted). CITED Laroca +1.55 pp is measured on 12,500 photographs of utility meters through a CRNN recognizer; DAQPal reads a user-framed ROI through Vision OCR, and `ScreenField.swift:89-93` notes the bbox looseness only bites **under strong perspective** — the minority case for someone deliberately pointing a phone at an instrument. **Rectify only when the tracked quad's roll or convexity exceeds a threshold.** `ScreenQuad` already computes both. One branch, not a per-frame GPU pass.

## 7.3 Stage / rate / compute-unit plan

| Stage | Rate | Compute unit | Evidence | Notes |
|---|---|---|---|---|
| Capture (AVFoundation) | 30 fps nominal, **never configured** | ISP | READ | No `lockForConfiguration` anywhere; `activeVideoMinFrameDuration` read-only at `CameraManager.swift:120`. |
| Drag gate | every frame | CPU, lock-free | READ | `InteractionState` mirror, ~free. |
| `VNTrackRectangleRequest` | every frame | Apple-internal (opaque) | MEASURED 2.9–11 ms **on macOS** | Cost is a non-issue on macOS. **The 122–184 ms first-frame → "visible hitch on iPhone" prediction is INFERRED from a macOS number and should be verified, not assumed** (evidence critique M8). |
| `AppearanceSentinel` NCC 32×20 | every frame | CPU / Accelerate | UNMEASURED | 640 bilinear samples + one NCC. Cheap by inspection. |
| **`ScreenCandidateDetector`** | 0.2 s acquiring / 0.5 s locked / **0.1 s (10 Hz) recovering** | Vision, CPU+GPU | **UNMEASURED** | **Runs `VNDetectRectanglesRequest` + a WHOLE-FRAME `VNRecognizeTextRequest` in one handler over the full 1080×1920 buffer.** At the recovering interval this is 10 Hz full-frame Vision text + rectangles, in the thermally-loaded, user-frustrated state. **Plausibly the most expensive thing in the app, and never timed. Time this before anything else.** |
| `PerspectiveNormalizer` | ≤1 Hz today; **conditional per-field, gated on roll/convexity** | GPU (Core Image) | UNMEASURED | See §7.2 item 3. |
| `ScreenFieldAnalyzer` | ≤1 Hz, on request | Vision | UNMEASURED | Fine as is. |
| **Dual-pass OCR** | currently every drained frame | Vision (opaque) | **REPO-RECORDED 41.8–52.2 ms** | **Decimate to 8–10 Hz or gate on ROI frame-change.** A display refreshes at 2–5 Hz. Measure the win as delivered fps + tracking stability. |
| `VNTrackOpticalFlowRequest` | **DO NOT USE** | — | **MEASURED 21.6–62.8 ms on macOS**; Apple's header: *"very resource intensive"* | Alone exceeds the frame budget. Use sparse Lucas-Kanade if forward-backward error is ever wanted. |
| *Proposed* device detector | **do not build** | — | CITED only | If ever built: low-rate gate only, and see §7.5–§7.7 for three constraints that were previously unstated. |

## 7.4 Thermal is the binding constraint (feasibility critique #6, accepted — promoted from footnote)

**Every device latency in this report comes from a ~12-second sweep.** `OCR_DEVICE_BENCHMARK.md` §0 says so explicitly: *"the sweep is ~12 s, far too short to heat the phone"* and *"Sustained-load thermal behavior is unmeasured."*

A data-acquisition app runs for **minutes to hours** of continuous capture, screen at full brightness, camera running, optionally `AVAssetWriter` H.264 encoding via `SessionVideoRecorder`. Under `.serious` / `.critical` thermal state iOS throttles GPU and ANE and AVFoundation reduces delivered frame rate. **None of the 41.8–52.2 ms figures survive that.**

**MEASURED grep: zero `thermalState` observers anywhere in `DAQPal/`.**

**Scoped remedy (balancing both critiques).** The feasibility critique wants a thermal governor in Phase 1; the over-engineering critique's rule is "don't build for an unmeasured problem." The resolution: **Phase 1 observes and logs `thermalStateDidChangeNotification` and records delivered/processed fps alongside it — a few lines that turn the burst-only caveat into a measurable quantity. The governor itself (degrade detector cadence → OCR cadence → capture fps, in that order) is deferred until sustained-load data exists.** Measure first, throttle second.

## 7.5 Neural Engine: the repo already contains the decisive counter-evidence (feasibility critique #4, accepted)

**REPO-RECORDED, `OCR_MODEL_COMPATIBILITY.md:92-101`** — omitted from earlier drafts and more decision-relevant to PART 9 Q8 than anything in the literature. PP-OCRv5 mobile rec converted cleanly, loaded under `ComputeUnits.ALL`, and **reproducibly failed ANE compilation**:

```
E5RT encountered an STL exception. msg = MILCompilerForANE error:
failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
```

It still ran, and was still the ALL-fastest row (1.97 ms median on an M1 Pro) — **because it silently fell back to GPU/CPU for the failing subgraph.** The repo's own note: *"Whether the same failure occurs on the A14's ANE is unmeasured."*

Consequences, all of which correct earlier drafts:

- **`MLComputeUnits.all` is a request, not a placement guarantee.** Placement is per-subgraph and can shift across OS minor versions. Verifying ANE residency needs the Core ML Instruments template **on device**; nobody has done this.
- **"ANE" is struck from the §7.3 proposed-detector row and from the §5.2 iOS scores that leaned on it** (‡ footnote).
- **Vision requests expose no compute-unit control at all.** Rows labelled "Vision (opaque)" are honest; any row implying you can *place* work is not.
- **Second ANE hazard, REPO-RECORDED:** fp16 max-abs-diff **5.19** on the ALL path (`OCR_MODEL_COMPATIBILITY.md:150-158`). ANE is fp16 with different accumulation order. A corner regressor emitting 8 coordinates feeds **directly into `ScreenQuad.Homography`'s DLT solve**, so fp16 corner error propagates through rectification into digit-cell sampling. **Any corner-regressor proposal needs a numeric-tolerance analysis, and this report previously had none. That matters more than model size.**

## 7.6 Two engineering constraints that outrank the CV literature

**A. Core ML conversion risk is understated by roughly an order of magnitude** (feasibility critique #5, accepted). REPO-RECORDED base rate on **this** toolchain (`coremltools 9.0` + `torch 2.13.0`, where coremltools itself warns *"Torch 2.7.0 is the most recent version that has been tested"*):

| Candidate | Outcome |
|---|---|
| doctr PARSeq | **FAILED** — `aten::Int` at `ops.py:3048`, two independent routes |
| baidu Unlimited-OCR | Excluded (6.67 GB, remote code) |
| doctr CRNN | Converted **only after rewriting `forward()`** |
| PP-OCRv5 | Converted after a 3-step ONNX repair chain, then **failed ANE compile** |
| TrOCR encoder | Converted; decoder never converted |

**One clean conversion out of five.** And `aten::Int` is a **torch-tracing-version** failure, not a model-complexity failure — **"small model" does not protect you.** Specific corrections: LDRNet's "10 MB / 8–10 ms on iPhone 11" is a **TNN** number, not Core ML, and citing it as Core ML feasibility evidence is a category error this report made twice; CDCC-NET has **no public checkpoint**, so its conversion risk is undefined, not low. The single highest-value mitigation, absent from earlier drafts: **pin torch ≤ 2.7 before attempting any conversion.**

**B. You cannot run a detector *off* the serial drain without breaking the buffer contract** (feasibility critique #8, accepted — **the strongest engineering argument against the device stage, and this report previously argued almost entirely from the CV literature**). `FrameSource.swift:16-25` documents that the consumer **"never retains it after"** the call, which is what makes concurrent `CVPixelBuffer` reads safe with `alwaysDiscardsLateVideoFrames = true`. A decoupled detector on its own cadence must therefore either **retain the buffer** — drawing down the capture device's fixed pool, and AVFoundation stalls delivery outright once the pool is exhausted — or **copy it** at 8.3 MB per 1080×1920 BGRA copy per detection, plus allocation churn. Running it *on* the drain avoids this and reintroduces the §7.2 jitter. **"Detector at 1–2 Hz" quietly assumes an execution model that was never specified, and specifying it is the hard part.**

**C. Blocking Vision calls are running on Swift's cooperative pool.** `handler.perform([...])` inside `ScreenCandidateDetector` is a **synchronous, blocking Vision call executing on a cooperative-pool thread**. The pool is sized to `activeProcessorCount` (**6** on iPhone13,4) and assumes threads do not block. Blocking one for tens of milliseconds per detection is a latent stall source for every other actor; because the drain is serial it manifests not as thread explosion but as the silent fps halving of H3. **The correct pattern for Vision/Core ML work is a dedicated `DispatchQueue` or custom `Executor`, not another `actor`.** This applies to existing code today, independent of the device-stage decision.

## 7.7 Memory: "+6–10 MB" was wrong

**READ:** zero additional bytes today — DAQPal ships no model. **INFERRED, if a ~6 MB corner regressor were added,** weights are the smallest term: Core ML working set (intermediates + compiled-model residency) typically 2–4× weights → **15–25 MB**; input preparation (the model wants 320–416 px, the buffer is 1080×1920 BGRA) needs a downscale pass that is neither free nor in the plan; and **REPO-RECORDED first-load cost of 2140 ms under `ALL` vs 197–235 ms CPU-only on an M1 Pro** (`OCR_MODEL_COMPATIBILITY.md:88-90`) lands on the user's first lock. **Call it ~20–40 MB RSS and a ~1–3 s one-time warm, not 6–10 MB and nothing.** Earlier drafts correctly said to warm `VNTrackRectangleRequest` (122–184 ms) off the critical path but said nothing about a model load an order of magnitude larger.

## 7.8 PART 10 — ROI-based computation: premise partly satisfied, partly false

PART 10 asks whether restricting expensive processing to a detected device region would significantly reduce compute versus full-frame OCR.

1. **For the measurement OCR: already satisfied.** READ — the ROI is passed as Vision `regionOfInterest` with **no buffer copy** (`MeasurementProcessor.swift:260-267`), and the REPO-RECORDED 41.8–52.2 ms **is** the ROI-restricted number.
2. **For the detector: NOT satisfied.** Corrected per feasibility critique #3 — `ScreenCandidateDetector` runs a **full-frame** text pass at up to 10 Hz (§5.2 footnote †). PART 10's premise applies here and nobody has measured the cost.
3. **The repo contains no full-frame-vs-ROI comparison**, so the *magnitude* of the existing saving is UNMEASURED.
4. **INFERRED, and important:** adding a device-detection stage in front does **not** reduce measurement-OCR cost, because that OCR is already ROI-restricted. It adds detector cost, a crop, jitter (§7.2), and a buffer-lifetime problem (§7.6B). **The compute-savings argument for device detection is void for DAQPal specifically.** Device detection would have to justify itself entirely on false-lock resistance — which is unmeasured, and which the literature does not support for display-like classes.

## 7.9 Instrumentation prerequisites — cut from five items to two, plus one deferred

**Over-engineering critique #10, partly accepted.**

**Do now (both are defects or near-free):**
1. **Call `recordProcessedFrame()` in `FrameProcessor`.** The HUD currently renders "100% dropped" in alarm colour as a **lie** (`PipelineMetrics.swift:192-195`). Hours of work.
2. **Wire `.ocr`.** Cheap, and it is the most expensive stage. Wire `.capture` at the same time if free; it is what makes H3 measurable.

**Deferred (real work, no listed decision depends on it):**
3. `.endToEnd` requires threading `CMSampleBuffer` PTS through to the `MainActor` apply **and inverting a test invariant that currently pins its absence** (`PipelineBudgetTests.testInventory_uninstrumentedStagesCannotBeReportedAsNumbers`, `PipelineBudgetTests.swift:617-638`). Defer.

**Struck:** running `VisionBuiltinDetectorBenchmarkTests` on device with three additional Apple requests (`VNDetectDocumentSegmentationRequest`, `VNTrackHomographicImageRegistrationRequest`, `VNGenerateImageFeaturePrintRequest`). READ: all three are available at DAQPal's `IPHONEOS_DEPLOYMENT_TARGET = 17.0` and are used nowhere. But this is **speculative exploration of stages this report concludes should not be built.** Keep it on the shelf; do not schedule it.

**Also do now, because it is a one-line correctness fix that gates any future replay work:** `FixtureFrameSource` → `.bufferingNewest(1)` (`FixtureFrameSource.swift:39`).

---

# 8. ADVERSARIAL TEST DESIGN (PART 11)

## 8.1 The metric that does not exist yet

**Proposed, and required before Gate 4 is meaningful:**

```
false_lock_rate = (published readings whose source region overlaps a
                   labelled distractor rather than the instrument display)
                / (published readings)
```

Reported alongside: correct-lock rate, time-to-first-correct-lock, lock stability (mean unbroken locked-frames run), reacquisition time, and — separately, because it is the repo's actual known weakness — decimal accuracy.

**Corrected instrument (over-engineering critique #1).** Compute this **first on 20–30 real bench recordings with real clutter, hand-labelled once, screen-lock path ON.** Days, not weeks. The synthetic scenarios below are a **regression** suite, not the measurement vehicle: a synthetic false-lock rate measures the compositor's assumptions, and tuning against a self-authored distractor set produces a fitted number, not a measurable improvement.

## 8.2 Existing harness assets

**READ:** `SyntheticFrameSource` (deterministic, pure function of `frameIndex`, 12 fps, 1080×1920, `.bufferingNewest(1)`); `DisplayPose3D` (pinhole projection, Rz·Ry·Rx, genuine trapezoids); `PoseTrajectory` (8 deterministic trajectories); `FixtureFrameSource` (`.mov` replay — **must first be changed to `.bufferingNewest(1)`**); `DAQPalTests/Support/{SyntheticDisplayGenerator, ValidationHarness, RegressionBaseline, RecognitionBenchmark}.swift`; `DAQPalTests/Fonts/DSEG7Classic-Regular.ttf` + `DSEG14Classic-Regular.ttf`.

## 8.3 The 12 scenarios

| # | Scenario | Vehicle | Notes |
|---:|---|---|---|
| 1 | IR gun + textbook with large numbers | Synthetic (regression) | Composite a DSEG7 panel via `DisplayPose3D` plus rendered proportional-font number blocks. Assert the published reading's region overlaps the panel truth rect. |
| 2 | Multimeter + paper containing numbers | Synthetic | Also the natural regression test for `FormatValidator`'s caption-glued and whitespace-gap rules. |
| 3 | Multiple multimeters | Synthetic | **Exposes a structural limit (READ): `ScreenLockPipeline.swift:127` holds `private var target: TrackedTarget?` — exactly one target is representable.** Correct assertion is "locks one, never oscillates," not "tracks both." |
| 4 | Multimeter + phone displaying numbers | **Real recording** | Synthesizable as a bright emissive panel, but refresh banding, backlight bloom, and moiré need physical footage. |
| 5 | Multimeter + computer monitor | **Real recording** | **Highest-risk scenario for Architecture B** — a monitor is a near-perfect rectangle with high text and numeric score. |
| 6 | Multiple seven-segment displays | Synthetic | Tests `switchMargin` 0.10 and user-rejection suppression directly. |
| 7 | Seven-segment font printed on paper | Synthetic | DSEG7 with inverted polarity and low contrast vs a real emissive panel. The cleanest test of whether *any* signal distinguishes a real display from a printed one — **honest expectation: today, none does.** Valuable precisely because it should fail. |
| 8 | Partial device occlusion | Synthetic | **Directly exercises the MEASURED false-recovery window (§2.3): confidence rebounds before localization does.** Assert no re-lock on confidence rebound alone. |
| 9 | Device partially outside frame | Synthetic | `PoseTrajectory.fastTranslation`. Exercises `QuadSanity`'s frame-overlap gate and the re-seed identity check. |
| 10 | Two similar devices in frame | Synthetic | `AppearanceSentinel` holds one *positive* reference and cannot distinguish the target from an equally-plausible twin. **See §10 for why the fix is "don't switch, let the user pick" rather than a discriminative appearance model.** |
| 11 | Device moves, background numbers static | Synthetic | **The most valuable synthetic scenario**: differential motion is a free, model-less discriminator, and `TrackVerifier` already computes motion coupling as a rate (0.07 normalized units/s). |
| 12 | Display unreadable due to glare | **Real recording** | **CITED, and it reframes the goal:** no public seven-segment dataset deliberately includes specular highlights (YUVA EB was captured explicitly "so that there is no flash or reflection"). The one study measuring glare found it the worst of four conditions (68.18% vs 79.55% ideal). Copel-AMR's answer is not to read through glare but to **classify the frame illegible and reject it** (98.9% of unreadable cases filtered, 99.82% of good ones accepted — citation unpinned). **The correct assertion is "abstains and holds the lock," not "reads correctly."** |

**Summary: 9 of 12 are synthesizable as regression tests (1, 2, 3, 6, 7, 8, 9, 10, 11); 3 need real recordings (4, 5, 12).** (Corrected from an earlier draft that wrote "8 of 12" and then parenthetically corrected itself to nine.) But per §8.1, **the real-recording set is the measurement instrument regardless** — and it covers scenarios 1–3 and 6–11 too, at lower fidelity and far lower cost than building the compositor.

**PART 12 note.** The prompt's three-layer test structure (device / display / numeric) collapses to **two** layers, because Layer 1 has no substrate. End-to-end success should read: *Display Correct AND Digits Correct AND Decimal Correct*. Adding a vacuously-true term would inflate the metric.

---

# 9. ANSWERS (PART 14)

### 1. Is device-aware detection actually worth implementing?
**No — not as specified, and not now.** (a) **CITED:** the two properly-ablated studies that measure context for display-like classes find near-nothing — Divvala's `tvmonitor` 32.9→33.3 AP, DPM's `tvmonitor` .384→.391, man-made subset +0.8 mAP overall. (b) **CITED (unpinned):** ContextShift finds context-dependence manifests as **false negatives up to +227% while false positives remain stable or decline** — a context-conditioned DAQPal is more likely to *miss* a multimeter than to reject a textbook. (c) **READ + INFERRED:** in the shipping default the user *draws* the ROI, supplying device context with perfect semantics; the exposure exists only in the opt-in path, which is off and **has never been measured.** (d) **INFERRED, revised upward:** the dataset alone is 150–1,600 person-hours plus equipment procurement, with no long tail and no inter-annotator QC. (e) **READ:** a decoupled detector cannot be run without either retaining capture buffers (stalling AVFoundation) or copying 8.3 MB per detection (§7.6B). **Committing that against an unmeasured baseline, for a literature-predicted gain under one AP point, is not defensible.**

### 2. How much can it reduce false OCR locks?
**Unknown, and not knowable from published work.** **SURVEYED negative result:** no benchmark, dataset, or paper evaluates instrument-display reading in a cluttered scene with distractor numbers. The 2025 systematic review of 265+ context papers (unpinned) reports **no aggregate effect size** for context reducing false positives. The frequently-cited 8.7× FP reduction (Bergboer 2006, COBA) is real but its baseline was a 2001-era Viola-Jones cascade at 0.296 FP/image — an order of magnitude worse than anything shipping today, so the headroom it exploited no longer exists. **The honest answer is a range with no credible upper bound and a well-supported lower bound near zero. DAQPal must measure its own baseline (§8) before this question is even askable.**

### 3. Classification, detection, segmentation, or hybrid?
**Hybrid, and the CV half should stay classical.** Classification is weakest — a label localizes nothing and fails silently on unseen instruments. Segmentation is heaviest. **CITED:** the meter-reading literature converged on detect region → regress 4 corners → rectify → recognize, and the corner regressor is tiny (CDCC-NET: 3 conv layers, 192×64 input, 8 float outputs + a legibility head). **DAQPal already has classical equivalents of the region, corner, and rectification stages.** The hybrid that fits DAQPal is: classical geometry (existing) + classical homography (existing) + Vision OCR (existing) + strict validators (existing) + **abstention (missing)**.

### 4. Should device and display be detected jointly?
**Moot — the device stage should not be built.** If it ever is: **jointly, never independently.** Independent detection requires a separate association step, and CITED Yu et al. show realized context gain collapses (70.68% oracle → +2.78 mAP) precisely because context extraction is noisy; a second independent stage adds a second noise source. **SURVEYED constraint:** no public dataset provides the joint annotation, so joint training requires the custom corpus of §6.2 regardless.

### 5. Should the display be treated as a known part of the device?
**No. Recommendation reversed from earlier drafts (over-engineering critique #4, accepted).**

The technical argument for registering the **bezel and body** rather than the glass remains correct: **INFERRED from CITED** — Apple's `ARReferenceImage` guidance calls for high texture, well-distributed histogram, and no repetitive structures, and a seven-segment readout behind glass violates those simultaneously while its content changes by design. (Retagged from "CITED, decisive": the "three of four requirements" framing was this report's own construction, not an Apple conformance test — evidence critique m12.)

**But the feature does not pay for itself.** Enumerate what per-instance registration actually costs: a registration UI, a canonical bezel↔display offset calibration step, persistent per-instance storage, a cross-session matching path, a re-detection scoring rule, a mismatch UX, and migration for users who registered under different lighting. That is a **feature**, and earlier drafts gave it one paragraph and a 9/10 simplicity score.

**And it is dominated by what already ships.** If the user is willing to answer "is this your instrument?", they are willing to draw a box — **which they already do, and which needs no storage, no template, no NCC, and no offset calibration.** Category-level priors ("IR gun display is near the rear housing") are rejected for the separate reason that they multiply the error of two nonexistent stages to save a stage that already works.

### 6. Is a custom dataset necessary?
**For the device stage: YES, unavoidably, and it is the dominant cost.** **SURVEYED:** of nine public datasets, exactly one annotates a device body alongside its display — 288 frames from a single video of a single device (hence 100% reported metrics). The `class:multimeter + class:display` query returned 6 unusable results. **INFERRED cost, revised:** 3,000–12,000 images, **150–1,600 person-hours** of labelling at 3–8 min/image, ×1.3–1.6 for schema churn, plus equipment procurement for 8–15 instrument families, plus capture time, plus a separate held-out adversarial set, with **no inter-annotator agreement** for a solo developer and **no long tail** in the result. **4 months to 3 years of calendar time.** **For the display and digit stages: NO** — CC BY 4.0 and Public Domain options exist. **What DAQPal genuinely needs is the real-bench adversarial recording set of §6.3, and that is single-digit hours.**

### 7. Which models are best suited to Core ML?
**Small, fixed-output, fully-convolutional corner regressors — with far more conversion risk than earlier drafts admitted.** **REPO-RECORDED base rate on this toolchain: one clean conversion in five** (§7.6A), and the failure that killed PARSeq (`aten::Int` at `coremltools ops.py:3048`) is a **torch-tracing-version** failure, so "small model" does not protect you. **Mandatory mitigation: pin torch ≤ 2.7.** Corrections: **LDRNet's 8–10 ms on iPhone 11 is a TNN number, not Core ML** — citing it as Core ML feasibility evidence is a category error this report previously made; **CDCC-NET has no public checkpoint**, so its conversion risk is undefined, not low. **Explicitly ruled out:** PARSeq and the sequence-recognizer family (CITED 56.97% word accuracy / 22.35% CER on seven-segment — the model hardest to ship is also the one that scores 57%); LoFTR/Efficient LoFTR (CITED 27–35 ms per 640×480 pair on an **RTX 3090**). **Licensing, decisive:** SuperPoint and SuperGlue are eliminated at the licensing stage — Magic Leap's licence is noncommercial-research-only, restricted to academic/non-profit organizations, and **assigns ownership of all derivatives to Magic Leap**, conflicting with `README.md:45`'s stated intent to keep commercialization open. Safe alternatives if ever needed: XFeat (Apache 2.0), LightGlue (Apache 2.0), DISK (Apache 2.0), ALIKED (BSD-3), LoFTR (Apache 2.0). SIFT is patent-free since March 2020; SURF's status is unresolved — avoid.

### 8. Which models can use the Neural Engine?
**None can be assumed to, and this repo already has a counter-example.** **REPO-RECORDED:** PP-OCRv5 converted cleanly, requested `ComputeUnits.ALL`, and **reproducibly failed ANE compilation with `ANECCompile() FAILED`**, silently falling back to GPU/CPU while still being the ALL-fastest row (`OCR_MODEL_COMPATIBILITY.md:94-101`). **`MLComputeUnits.all` is a request, not a placement guarantee**; placement is per-subgraph and can shift across OS minor versions; verifying residency requires the Core ML Instruments template **on device**, which nobody has run. Second hazard: **fp16 max-abs-diff 5.19** on the ALL path — and a corner regressor's 8 outputs feed straight into a DLT solve, so **any such proposal needs a numeric-tolerance analysis it currently lacks.** Vision requests expose no compute-unit control at all. **CITED** small detectors (YOLOv8n/v11n class, ~3M params) are routinely reported at low-double-digit ms on ANE, but **not one paper in the review measured anything on Apple silicon**, and the only iPhone number found (LDRNet 8–10 ms on iPhone 11) is **TNN, not Core ML**. Apple's own `VNDetectDocumentSegmentationRequest` / `VNTrackHomographicImageRegistrationRequest` / `VNGenerateImageFeaturePrintRequest` are available at the iOS 17.0 floor and used nowhere (READ), with no published latency — but benchmarking them is **struck from the plan** (§7.9) as exploration of stages that should not be built.

### 9. What is the expected latency?
**One stage has a device figure, and it is a Debug burst.** **REPO-RECORDED:** dual-pass OCR mean **41.8–52.2 ms** (p90 up to 64 ms) on iPhone 12 Pro Max, iOS 26.5.2, **Debug/`-Onone`**, n=72, ~12 s sweep, ROI-restricted; **absolute first `recognize()` 223–555 ms**, **cold overhead 156–508 ms** (two distinct quantities — see §7.1). **MEASURED on macOS (not iPhone), single runs:** `VNTrackRectangleRequest` 2.9–11 ms; `VNTrackObjectRequest` 1.2–4.0 ms with a 213–1027 ms first call; dense optical flow 21.6–62.8 ms at 1280×720. **UNMEASURED:** capture latency, delivered and processed fps, end-to-end latency, the full-frame detector pass, rectification, sustained/thermal behaviour, Release-build delta, and every proposed new stage. **INFERRED and load-bearing (H3):** because the drain is serial, a 41.8–52.2 ms OCR stage does not "blow the budget" — it **silently halves the frame rate**, plausibly to ~15–21 fps. Anyone quoting "~382 ms" from source comments is quoting a Simulator/Mac figure (`OCR_DEVICE_BENCHMARK.md:194`).

### 10. What is the expected memory footprint?
**Zero additional bytes today** (READ: no model files anywhere; no CoreML in `project.pbxproj`). **INFERRED, if a ~6 MB corner regressor were added: ~20–40 MB RSS and a ~1–3 s one-time warm**, not "+6–10 MB and nothing" — weights are the smallest term next to Core ML working set (2–4× weights), the 320–416 px input-preparation pass that no plan currently contains, and a **REPO-RECORDED 2140 ms `ALL` load vs 197–235 ms CPU-only on an M1 Pro**, which on an A14 lands on the user's first lock. **CITED as a warning:** DAM4SAM/SAM2-class trackers run at 1.78 GB — categorically out of reach. **I made no memory measurement of DAQPal.**

### 11. What is the best architecture for iPhone hardware?
**The one already in the repo, with the OCR stage decimated, the detector's full-frame text pass timed, and abstention added.** Concretely: AVFoundation 32BGRA portrait-rotated capture → per-frame `VNTrackRectangleRequest` + `AppearanceSentinel` NCC → `ScreenCandidateDetector` at its existing state-dependent cadence, **after its full-frame `VNRecognizeTextRequest` is timed** (§5.2 †) → classical DLT homography, **rectifying only when roll/convexity exceeds threshold** → **OCR decimated to 8–10 Hz or gated on ROI frame-change** → validators → **explicit abstain**. Dense optical flow is excluded (MEASURED 21.6–62.8 ms on macOS; Apple's header: "very resource intensive"). **Two structural corrections that apply today regardless of the device-stage decision:** move blocking Vision calls off cooperative-pool actors onto a dedicated executor (§7.6C), and reason about **p99 frame interval**, not means, because the drain is serial (§7.2). Nothing new runs per frame; nothing new ships.

**On the cadence citation (evidence critique M8):** earlier drafts said "2–5 Hz is well-supported" on the strength of Zhu et al.'s 60.2% mAP @ 25.6 fps at keyframe interval 10 on a Huawei Mate 8 CPU. That is different silicon, a different task (video object detection), a different model, and a different accuracy metric. **The correct statement is: DAQPal's existing state-dependent cadence is already reasonable and should be kept; the literature is directional support, not an endorsement of a specific rate on iPhone.**

### 12. What is the simplest architecture that achieves the required reliability?
**Nobody knows, because "required reliability" has never been measured — and that is the finding (H1).** Gate 2 is unmet, so Gate 4 is unreachable by construction. The simplest architecture worth trying first contains **no new model and, in its first phase, no new capability at all**:
1. **Fix what is provably broken** (`recordProcessedFrame()`, the HUD's 100%-drop lie, stale comments, dead-wired `isUserDragging`).
2. **Delete or quarantine what does not run** (1,932 lines, zero call sites; takes the suite to 812/812).
3. **Measure the false-lock rate on 20–30 real bench recordings**, screen-lock path ON, single binary label per published reading. Days.
4. **Only then**: an explicit abstain path (CITED Laroca +3.16 pp from confidence rejection — see §5.5 on the baseline caveat), and conditional rectification gated on roll/convexity.
5. **Struck from earlier drafts:** `ScreenSignalWeights` re-weighting (arithmetically unnecessary — §4/B), negative-exemplar memory (unmeasured scenario, new failure mode), per-instance bezel registration (a feature dominated by the ROI the user already draws), wiring `DecimalRescue` (sunk cost, new pixel failure mode in the export path).

---

# 10. GATE 7 RECOMMENDATION

## **DO NOT IMPLEMENT the device stage. FIX, DELETE, AND MEASURE FIRST.**

Formally, against PART 13's options: **IMPLEMENT PARTIAL HYBRID**, where "partial hybrid" **excludes the device-detection stage entirely, ships no new machine-learning model, and adds no new capability until a false-lock number exists.**

This is the boring answer. The evidence supports the boring answer, and the source prompt explicitly asks for the simplest architecture that produces a **measurable** improvement — which, per H1, currently means *no* architecture change can qualify.

### What is ruled out

**DO NOT IMPLEMENT** — device detection (D, E, F), device classification, device-specific display priors, any new Core ML model, any custom device-body dataset, per-instance bezel registration, negative-exemplar memory, `ScreenSignalWeights` re-weighting, and wiring `DecimalRescue`. Reasons in order of weight:

1. **MEASURED:** Gate 2 is unmet, so Gate 4 is unreachable by construction. Building against an unmeasured baseline cannot pass its own gate. *(H1)*
2. **CITED:** two properly-ablated studies measure context gain for display-like classes at essentially zero (`tvmonitor` 32.9→33.3 and .384→.391).
3. **CITED (unpinned):** ContextShift shows context-dependence produces **+227% false negatives**, not false-positive suppression — the wrong trade for a data-acquisition app.
4. **SURVEYED + INFERRED:** the required dataset was not found in a bounded survey; building it is **150–1,600 person-hours plus equipment procurement, 4 months to 3 years solo**, and produces a corpus with no long tail.
5. **READ:** a decoupled detector cannot run without retaining capture buffers (AVFoundation stalls) or copying 8.3 MB per detection; running it on the drain adds p99 jitter to a UI judged on smoothness. *(§7.6B, §7.2)*
6. **REPO-RECORDED:** one clean Core ML conversion in five on this toolchain, and a reproduced `ANECCompile() FAILED` with silent fallback — "small model on ANE" is not a safe assumption. *(§7.5, §7.6A)*
7. **READ + INFERRED:** DAQPal's shipping default already has a human performing device-aware selection, by drawing.

### What to do, in order

**Phase 0 — fix lies and delete dead code. Days. No new capability.**
- Call `recordProcessedFrame()` in `FrameProcessor`; wire `.ocr` (and `.capture` if free). Removes the HUD's **"100% dropped"** lie and makes H3 measurable.
- Correct the stale/wrong comments: Simulator "~382 ms" cited as device latency in three files; inverted headers in `SevenSegmentSampler.swift:17` and `DecimalRescue.swift`.
- Fix dead-wired `isUserDragging`, or delete the unreachable branches.
- **Delete or explicitly quarantine `SegmentCellScanner`, `DecimalRescue`, `DisplayFormatInference`** (1,932 lines, zero call sites). Deleting takes the suite to **812/812 green** at zero product risk and removes the report's loudest false alarm. If kept, mark dev-only so no future audit mistakes them for shipping code.
- Fix `FixtureFrameSource` to `.bufferingNewest(1)`.
- **Observe and log `thermalStateDidChangeNotification` alongside delivered/processed fps.** A few lines; turns the burst-only caveat into data. **No governor yet.**
- **Time `ScreenCandidateDetector.detectPass`** — the full-frame `VNRecognizeTextRequest` + rectangles pass, which runs at up to 10 Hz while recovering and has never been measured. It is plausibly the most expensive thing in the app.
- Move blocking Vision `handler.perform` calls off cooperative-pool actors onto a dedicated executor (§7.6C).

**Phase 1 — measure the thing this whole research question is about. Days.**
- **Record 20–30 real bench videos with real clutter. Hand-label once. Compute `false_lock_rate` with the screen-lock path ON.**
- This is the only thing that makes Gate 4 reachable and the only thing that can tell you whether Phase 2 is worth doing.
- **If the measured false-lock rate is already low — because `FormatValidator` + `PhysicalValidator` + `TemporalConsensus` + `ConfidenceEngine` are catching distractors — the entire research question is moot and Phase 2 should be cancelled. "Ship as-is and defer" is a real, listed, acceptable outcome, not a placeholder.**

**Phase 2 — only if Phase 1 shows a real problem. Weeks.**
- **Explicit abstain path** (CITED Laroca +3.16 pp from confidence rejection; §5.5 caveat on the baseline comparison applies). For glare specifically the correct behaviour is **abstain and hold the lock** — what the strongest published system does.
- **Conditional rectification**: rectify the field crop only when `ScreenQuad`'s roll or convexity exceeds a threshold. One branch, not a per-frame GPU pass.
- **Surface the `VNTrackRectangleRequest` throw** as a distinct `TrackVerifier` verdict — **but first verify that the existing `nil` path does not already degrade in the same frame.** It may be a zero-line change.
- **Frozen-box detector** (MEASURED: confidence constant to 3 dp with no box motion across sampled frames).
- **Never gate a re-lock on confidence recovery** (MEASURED: confidence rebounded to 0.939/0.893 while localization was still wrong). Require consecutive independent corroborations, mirroring CITED SORT's asymmetric `min_hits=3` vs `max_age=1`. `AppearanceSentinel` has the fast-to-distrust half; the slow-to-trust half is missing on exactly the dangerous side.
- If two similar instruments are on the bench (scenario 10), the correct product behaviour is **don't switch, and let the user pick** — which `switchMargin` 0.10 + user-rejection suppression + `.reacquisition` id re-stamping already implement at zero cost. **Do not build a discriminative appearance model for it.**
- **Thermal governor**, if and only if Phase 0's logging shows sustained-load degradation: degrade detector cadence → OCR cadence → capture fps, in that order.

**There is no Phase 3.** Per-instance registration is rejected (§9 answer 5).

### Answering the FINAL ARCHITECTURAL QUESTION directly

> *"Can DAQPal become significantly more reliable by understanding 'what physical device am I looking at?' before asking 'what numbers can I read?'"*

**On the available evidence: no — and the more useful question is one the prompt does not ask.**

DAQPal's measured weaknesses are not that it locks onto textbooks. **Nobody has ever measured it doing that.** They are: a seven-segment scanner that reports a wrong decimal position (4 failing tests, in code that does not run), single readings that split at the decimal point (1 masked expected failure), 1,932 lines of unreachable code, decimal confidence resting on four constants the source itself calls unmeasured policy, instrumentation that renders a 100%-drop rate as a lie, and a pipeline that has plausibly been running at half its nominal frame rate for its entire life without anyone noticing.

**The reliability problem is decimal integrity, dead code, and self-observability — not device identity.**

The prompt asks whether to add a "WHAT IS IT?" stage above the pipeline. The evidence-supported answer: **the pipeline already has a "WHICH DISPLAY?" stage more sophisticated than the proposal; it is off by default and has never been measured. Delete the dead code. Fix the instrumentation. Measure the false-lock rate on real footage. The device stage is the most expensive item on the list and the one with the least evidence behind it — and until the baseline exists, it is the one item that provably cannot pass Gate 4.**

Checking costs days. **Nobody has checked.**

---

# CRITIQUE LOG

Three adversarial reviews were applied: **over-engineering** (weighted highest, per the source prompt's demand for the simplest architecture producing a *measurable* improvement), **evidence-integrity**, and **iOS-feasibility**. Claims flagged by the critics were re-verified against the working tree before acceptance.

## Accepted — structural changes

| # | Critique | Change |
|---|---|---|
| 1 | Gate 4 unreachable is buried | **New §0 HEADLINE FINDINGS.** H1 states it as the report's central result. |
| 2 | Synthetic corpus is fitted, not measured | **Phase 0/1 rewritten.** Primary vehicle is now **20–30 real bench recordings, hand-labelled, single binary per reading**. Synthetic demoted to regression only, and its honest cost (1–3 weeks) stated. §3.2, §6.3, §8.1. |
| 3 | "Ship as-is, defer" was never a listed outcome | Added as **Rank 0** in §4 and as an explicit acceptable Phase 1 exit in §10. |
| 4 | `ScreenSignalWeights` 0.65-clears-the-lock-gate is an arithmetic error | **Verified: `enterLock = 0.90`, so 0.65 clears only the 0.60 *candidate* gate — by design, per the source's own comment.** The re-weighting recommendation is **struck** everywhere; residual fix, if ever needed, is one constant (`enterDetection`). §4/B, §9 Q12. |
| 5 | Per-instance bezel registration is a feature dominated by the user-drawn ROI | **Recommendation reversed.** §9 answer 5 now rejects it; **Phase 3 deleted**. |
| 6 | Negative-exemplar memory is over-engineering for an unobserved scenario | **Struck.** Replaced with the zero-cost behaviour already shipping (don't switch, let the user pick). §8.3 #10, §10. |
| 7 | "Fix the 4 `SegmentCellScanner` tests" is fixing an experiment, not the product | **Reversed to delete-or-quarantine.** §1.3, §3.5, §10 Phase 0. Takes the suite to 812/812. |
| 8 | Wiring `DecimalRescue` is a sunk-cost argument | **Struck.** §3.5 now argues measure-the-constants-first. |
| 9 | Per-frame rectification isn't transferable from Laroca | **Made conditional** on `ScreenQuad` roll/convexity. §7.2, §10 Phase 2. |
| 10 | §5.4's bundled 9/10-simplicity row is a bundling trick | **Bundle dissolved** into two honest rows; **FLR deliberately left blank** because scoring it would invent the missing number. |
| 11 | Instrumentation bundle too large | Cut to **`recordProcessedFrame()` + `.ocr`**; `.endToEnd` deferred; `VisionBuiltinDetectorBenchmarkTests` on-device run **struck** as exploration of stages that should not be built. §7.9. |
| 12 | Throw-surfacing win is asserted, not shown | Added an explicit **verify-first precondition**. §3.4, §10 Phase 2. |
| 13 | "Already over budget" is mechanically wrong; the drain self-throttles | **Rewritten as H3 and §7.2.** New finding: plausibly **~15–21 effective fps**, unmeasured. OCR decimation reframed as a cadence fix, not a compute saving. |
| 14 | Rate decimation in a serial drain buys jitter; p99 matters | Added §7.2 item 2. |
| 15 | §7.3 wrong — DAQPal *does* run full-frame OCR in the detector | **Verified at `ScreenCandidateDetector.swift:217-236`.** Corrected in §5.2 footnote †, §7.3 table, §7.8. Flagged as **the highest-priority missing measurement.** |
| 16 | Repo's own `ANECCompile() FAILED` record omitted | Added as **§7.5**; "ANE" struck from the proposed-detector row and the §5.2 iOS scores that leaned on it (‡). |
| 17 | Core ML conversion risk understated | **§7.6A:** one clean conversion in five; **pin torch ≤ 2.7**; LDRNet's 8–10 ms is **TNN not Core ML**; CDCC-NET has no checkpoint. fp16 tolerance analysis added as a requirement. |
| 18 | Thermal is binding, not a footnote | Promoted to **§7.4**, with a scoped Phase 0 remedy (observe + log) and the governor deferred — balancing the over-engineering rule against the real risk. |
| 19 | Memory "+6–10 MB" is wrong | **§7.7:** ~20–40 MB RSS + ~1–3 s warm, with the REPO-RECORDED 2140 ms `ALL` load. |
| 20 | Pixel-buffer retention is the strongest engineering argument against a detector, and was missing | Added as **§7.6B** and promoted into §9 Q1 and §10's reason list. |
| 21 | Blocking Vision on cooperative-pool actors | Added as **§7.6C**; moved into Phase 0 because it applies today. |
| 22 | Dataset cost too generous by 2–3× | **§6.2 revised: 150–1,600 person-hours**, plus equipment procurement, single-annotator QC, churn multiplier, and the no-long-tail argument. |

## Accepted — evidence-integrity corrections

| # | Claim | Correction |
|---|---|---|
| M1 | "819 = static count of `func test…` across 49 files" | **False. Verified: 856 declarations across 54 files.** Corroboration claim **withdrawn**; the 37-case gap is left unexplained. §1.1. |
| M2 | "203 of 819 (24.8%) negative test names" | **Does not reproduce. Verified: 142 of 856 (16.6%)** on stems, 110 (12.8%) on literals. §3.2. |
| M3 | "MEASURED-BY-INSPECTION" → bare "MEASURED" | Renamed to **SURVEYED**, added to the legend with an explicit prohibition on universal negatives. Dataset-nonexistence claims downgraded to bounded-survey results. §6.1, §5.3, §9 Q6, §10. |
| M4 | "cold first call 156–555 ms" | **Composite of two different metrics.** Split into **absolute first call 223–555 ms** and **cold overhead 156–508 ms**. §7.1, §9 Q9. |
| M5 | Debug caveat dropped where the conclusion is drawn | Debug/`-Onone`/n=72/12 s-burst caveat now attached at every use, plus the self-throttling correction. §5.3, §7.1, §9 Q9, §10. |
| M6 | macOS probe stated beyond what was printed | Restated to sampled frames, 3 dp, single run. **"bit-identical", "exactly", "25 consecutive", "10+ consecutive", "all 44 frames" all dropped.** Missing-artifact caveat added. §2.3, §3.4. |
| M7 | Optical flow "21.6–66.0 ms" | Replaced with the enumerated 1280×720 values **21.6 / 28.5 / 53.8 / 62.8**; the unreconciled 66.0 removed. |
| M9 | `.analysis` = 5 production sites | **Verified 3** — the `SegmentCellScanner` and `DecimalRescue` `measure(.analysis)` calls are inside dead code. §3.3. |
| M10 | Laroca "+3.16 vs +0.97 on the same system" | **"Same system" framing withdrawn** (baselines differ: 95.43 vs 95.87). New §5.5 requires the primary source pinned before Phase 2 is scheduled on it. |
| M8 | Zhu et al. cadence transferred across silicon/task | Conclusion sentence qualified; the existing state-dependent cadence is endorsed on its own merits, not on the citation. §9 Q11. |
| m11 | Unpinned load-bearing citations | Global caveat added under the legend, naming every unpinned source and stating no decision rests on one alone. |
| m12 | `ARReferenceImage` "CITED, decisive / three of four" | **Retagged INFERRED-from-CITED**; the four-requirement framing was this report's construction. §9 Q5. |
| m13 | Small overstatements | `DAQPal/` non-Swift files = 3 asset JSON + 1 `.DS_Store`; `Device.model` also read at `AppState.swift:653`; "8 of 12" corrected to **9 of 12** cleanly; `.fast` noted as an injectable default, not hard-coded. |

## Rejected — original text retained

- **"Delete the §5.2 decision matrix entirely."** PART 13 explicitly requires a decision matrix, so it cannot be removed without failing the deliverable. The objection is honored in substance instead: the table is demoted below the prose, every column is labelled by evidence class, and the recommended row's FLR cell is **left blank rather than invented**.
- **"Cut `.ocr` instrumentation along with `.endToEnd`."** `.ocr` is a few lines on the single most expensive stage and is what makes H3 falsifiable; the over-engineering critique itself concedes it is worth it. `.endToEnd` was cut.
- **"'The dataset does not exist' is fine as MEASURED because the survey was thorough."** Rejected in favour of the evidence critique: a bounded catalogue browse cannot establish a universal negative, so it is tagged SURVEYED throughout — even though this weakens a conclusion this report otherwise wants to make strongly.
