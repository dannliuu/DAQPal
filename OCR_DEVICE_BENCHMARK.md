# Decimal Benchmark — Phase 3 — REAL DEVICE RUN

**Harness:** `DAQPalTests/DecimalBenchmarkTests.swift` (new; the only file this round created).
**Engine under test:** `OCRManager()` → `DualPassVisionOCR` (Apple Vision `.accurate` + `.fast`, merged) — the shipping incumbent.
**Date of runs:** 2026‑07‑28.

Every number below was observed in a run I executed. Anything I could not observe is written **unmeasured**. No figure here is estimated, extrapolated, or carried over from an earlier round.

---

## 0. Provenance — read this before quoting any number

| | Device run A | Device run B | Simulator run | Device run C |
|---|---|---|---|---|
| Host | **PHYSICAL iPhone** | **PHYSICAL iPhone** | Simulator (measures the Mac) | **PHYSICAL iPhone** |
| `uname` machine | `iPhone13,4` (iPhone 12 Pro Max) | `iPhone13,4` | `arm64`, simulating `iPhone18,1` | `iPhone13,4` |
| OS | iOS 26.5.2 | iOS 26.5.2 | iOS 26.5 (simulated) | iOS 26.5.2 |
| `activeProcessorCount` | 6 | 6 | 10 (the Mac's) | 6 |
| Build configuration | **Debug**, `SWIFT_OPTIMIZATION_LEVEL = -Onone`, `GCC_OPTIMIZATION_LEVEL = 0` | same | same | same |
| Thermal state (start / end) | nominal / nominal | nominal / nominal | nominal / nominal | nominal / nominal |
| Cases | 72 | 72 | 72 | 72 |
| App-source state | **before** sibling decimal-rescue landing | before | before | **after** (see §2.5) |
| Raw log | `scratchpad/device_run3.log` | `scratchpad/device_run4.log` | `scratchpad/sim_run1.log` (+ `scratchpad/simatt/*.txt`) | `scratchpad/device_run5.log` |

Notes on provenance:

- The device is an **iPhone 12 Pro Max (`iPhone13,4`)**, not a current-generation phone. The task brief named the device `Daniphone` / id `00008101-001E44EC1A88001E`; that id resolved to this model. Latency on newer silicon is **unmeasured**.
- Build is **Debug / `-Onone`**. A Release build was **not** run. The engine call itself is Vision framework code (already optimized), so the effect of `-Onone` on the *engine* number is small in principle, but I did not measure it — treat the Release delta as **unmeasured**.
- The Simulator column exists **only** to show how misleading Simulator timing is. Simulator numbers measure the Mac and must never be quoted as iPhone latency.
- Only one thermal reading pair per run (start and end of the sweep). Sustained-load thermal behavior is **unmeasured** — the sweep is ~12 s, far too short to heat the phone.

### Command actually used (the brief's command does **not** work as written)

The command in the task brief fails. Exact error, verbatim from `scratchpad/device_run1.log`:

```
/Users/danielliu/Documents/DAQPal/DAQPal.xcodeproj: error: Signing for "DAQPalUITests" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'DAQPalUITests' from project 'DAQPal')
/Users/danielliu/Documents/DAQPal/DAQPal.xcodeproj: error: Signing for "DAQPalTests" requires a development team. Select a development team in the Signing & Capabilities editor. (in target 'DAQPalTests' from project 'DAQPal')
** TEST FAILED **
```

`DEVELOPMENT_TEAM 56WA4P82Z5` is set on the **app** target only; the two **test** targets have no team. Since the pbxproj must never be edited, the fix is a command-line build-setting override, which leaves the project file untouched. This worked on the first retry:

```
xcodebuild test -project DAQPal.xcodeproj -scheme DAQPal \
  -destination 'platform=iOS,id=00008101-001E44EC1A88001E' \
  -only-testing:DAQPalTests/DecimalBenchmarkTests \
  -derivedDataPath <scratchpad>/dd-dec-device \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=56WA4P82Z5 CODE_SIGN_STYLE=Automatic
```

No trust prompt, no device-lock failure, no provisioning-profile failure occurred. **`** TEST SUCCEEDED **`, exit 0.**

---

## 1. HEADLINE RESULTS — on device

Identical in **all four runs** (three device, one Simulator). 72 cases each.

| Metric | Value | Count |
|---|---|---|
| **POWER-OF-TEN ERROR RATE** | **9.7 %** | **7 / 72** |
| **DECIMAL-PRESERVATION ACCURACY** | **90.3 %** | 65 / 72 |
| Value accuracy (OCR accuracy on the display crop) | 90.3 % | 65 / 72 |

Outcome breakdown (device, both runs):

| Outcome | N | Rate |
|---|---|---|
| correct | 65 | 90.3 % |
| **powerOfTenError** (silently accepted, 10^k off) | **7** | **9.7 %** |
| otherWrong | 0 | 0.0 % |
| **refusedAmbiguousDecimal** | **0** | **0.0 %** |
| noParseableReading | 0 | 0.0 % |
| noCandidates | 0 | 0.0 % |

**The two numbers that matter most are `powerOfTenError = 7` and `refusedAmbiguousDecimal = 0`.**
Every single decimal failure in this corpus was **silently accepted**. The existing `.ambiguousDecimal` veto in `FormatValidator` fired **zero times**. The system had seven opportunities to say "I am not sure where the decimal point is" and took none of them.

### Definitions used (so the rates are auditable)

- **Accepted reading** = the first candidate, in the engine's own confidence order, that `FormatValidator.reading(from:format: .unconstrained)` resolves to a number. This is what the pipeline would actually take. `.unconstrained` is deliberate: a declared device format must not be allowed to *reconstruct* a separator the image did not contain.
- **Correct** = accepted value within ±half of one least-significant-digit step of ground truth (reusing `RecognitionBenchmark.groundTruth(of:)`, the existing convention).
- **Power-of-ten error** = accepted, not correct, and `log10(|value / truth|)` within 0.02 decades of a non-zero integer. **Magnitude-based on purpose**: `-8.08` for a true `80.8` still counts as a scale error; a pure sign flip does not.
- **Decimal preserved** = a reading was accepted **and** its `DecimalAnalysis.separatorDetected` matches ground truth **and**, when a separator is expected, `separatorPosition` (digits *before* the separator, `DisplayFormat`'s convention) matches exactly. A refusal preserves nothing — it just does no harm — so refusals score `false` here by construction.

---

## 2. Where the 7 failures are — all one label

Per-label, device (N = 8 variants each):

| Label | Correct | 10^k | Decimal preserved |
|---|---|---|---|
| `80.8` | 100.0 % | 0.0 % | 100.0 % |
| `808` | 100.0 % | 0.0 % | 100.0 % |
| `12.345` | 100.0 % | 0.0 % | 100.0 % |
| `0.001` | 100.0 % | 0.0 % | 100.0 % |
| `99.9` | 100.0 % | 0.0 % | 100.0 % |
| `-1.25` | 100.0 % | 0.0 % | 100.0 % |
| **`.5`** | **12.5 %** | **87.5 %** | **12.5 %** |
| `100.0` | 100.0 % | 0.0 % | 100.0 % |
| `1.000` | 100.0 % | 0.0 % | 100.0 % |

**All 7 power-of-ten errors are the label `.5` (leading decimal, no integer digit), 7 of its 8 variants.**

Audit trail, verbatim from the device run:

```
  .5       clean                   • 5                 5             powerOfTenError         --
  .5       low-contrast            • 5                 5             powerOfTenError         --
  .5       blur                    • 5                 5             powerOfTenError         --
  .5       noise                   • 5                 5             powerOfTenError         --
  .5       occlusion               .5                  .5            correct                 ok
  .5       yaw-35deg               •5                  5             powerOfTenError         --
  .5       yaw-55deg               5                   5             powerOfTenError         --
  .5       roll8-pitch35-scale0.6  • 5                 5             powerOfTenError         --
```

### Mechanism (observed, not inferred from theory)

1. Vision does **not** drop the leading dot. In 6 of 7 failures it *sees* something there and transcribes it as a **bullet-like glyph** — the recognized string is literally `• 5` / `•5`. (I read the rendered character in the test output; I did **not** verify its Unicode scalar. Exact codepoint: **unmeasured**.) In the 7th (`yaw-55deg`) the dot is gone entirely: `5`.
2. `FormatValidator.extractReading` treats only `.` and `,` as separator glyphs. A bullet is neither, so the regex tokenizer finds exactly one numeric token — `5` — and the bullet is discarded as surrounding junk.
3. One candidate, no separator, undeclared format ⇒ `Hypothesis(integerDigits: "5", separatorDetected: false, certainty: undeclaredIntegerCertainty = 0.75)`.
4. Result: **`0.5` is emitted as `5.0`**, a clean 10x error, with confidence merely *depressed* (0.75), never vetoed.

This is the exact `808` / `80.8` failure class from the problem statement, reproduced on real hardware with a different instance. The lead's judgement holds and is now **measured**: the dot survives to the recognizer often enough to be recoverable; it is the *parser's* glyph vocabulary and the absence of a format prior that lose it.

Note the one success: `occlusion` (a bar over the bottom 30 % of the panel) is the **only** `.5` variant read correctly. That is almost certainly luck in how the occlusion perturbed Vision's segmentation, not a robustness property — n = 1.

---

## 2.5 Re-run AFTER the sibling decimal-rescue landing — no change (device run C)

Between run B and run C, other agents landed substantial decimal work in the app target:

```
 M DAQPal/Processing/FormatValidator.swift      | 506 ++++++++++++++++++++++-----
 M DAQPal/Processing/ConfidenceEngine.swift     |  50 ++-
 M DAQPal/Processing/MeasurementProcessor.swift |  63 +++-
 ?? DAQPal/OCR/DecimalRescue.swift
 ?? DAQPal/Processing/DisplayFormatInference.swift
 ?? DAQPal/Processing/TemporalConsensus.swift
```

Snapshot hashes measured (`shasum`): `FormatValidator.swift` `a3af2d30…`, `DecimalRescue.swift` `02a637a1…`, `ConfidenceEngine.swift` `918093a3…`, `MeasurementProcessor.swift` `5c2b6912…`.

I re-ran the identical harness on the identical device against that state.

**Result: byte-identical. `correct = 65`, `powerOfTenError = 7`, `refusedAmbiguousDecimal = 0`, decimal-preservation 90.3 %. All seven `.5` rows still read `• 5` → accepted `5`.** Latency: mean 47.5 ms, min 23.1, p50 46.6, p90 62.2, max 64.7; cold first call 223.0 ms, second 67.0 ms.

**Scope of that statement — important, do not over-read it:**

- This harness scores the **parser layer**: it calls `FormatValidator.reading(from:format: .unconstrained)` on the engine's candidate text. So run C is evidence that the +506-line `FormatValidator` rewrite **did not change the outcome for a leading decimal point transcribed as a bullet-like glyph**. That is a genuine, reproducible gap.
- It is **not** evidence that `DecimalRescue` fails. `DecimalRescue.analyze(canonicalImage:digitCount:)` is **image**-based, and at this snapshot it has **zero call sites anywhere in `DAQPal/`** — verified by `grep -rn "DecimalRescue" --include="*.swift" .`, which matches only its own file and `DAQPalTests/DecimalRescueTests.swift`. It is written but **not wired into the pipeline**, so no harness could have exercised it through the normal path.
- Whether an end-to-end pipeline that *does* invoke `DecimalRescue` (plus the format prior and temporal consensus) recovers `.5` is **unmeasured**. This harness deliberately measures the recognizer + parser seam, not the full `MeasurementProcessor`.

The actionable read: **the rescue must actually be wired in, and the parser must stop discarding a non-digit, non-`.`/`,` glyph that sits exactly where a separator belongs.** Right now the OCR text carries the evidence (`• 5`) and the parser throws it away.

---

## 3. Robustness by degradation and pose (device)

| Variant | N | Correct | 10^k | Decimal | Refused | mean ms (run A) | mean ms (run B) |
|---|---|---|---|---|---|---|---|
| clean | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 46.5 | 55.6 |
| low-contrast (brightness 0.5) | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 44.2 | 56.0 |
| blur (`blurRadius` 10) | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 43.9 | 54.9 |
| noise (`noiseAmount` 0.35) | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 44.7 | 46.2 |
| occlusion (0.30 of panel) | 9 | 100.0 % | 0.0 % | 100.0 % | 0.0 % | 44.3 | 57.7 |
| yaw 35° | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 45.2 | 56.2 |
| yaw 55° | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 27.7 | 39.4 |
| roll 8° + pitch 35° + scale 0.6 | 9 | 88.9 % | 11.1 % | 88.9 % | 0.0 % | 37.8 | 51.6 |

**Degradation and pose changed nothing.** The `RenderDegradation` and `DisplayPose` axes had no measurable effect on decimal preservation on this corpus — the failure is label-driven (`.5`), not condition-driven. That is a real result about *this corpus*, and it is also a warning about the corpus: see §6.

---

## 4. Latency — REAL DEVICE

Engine call only (`OCRManager.recognize`), timed with `ContinuousClock` around the call. Excludes rendering.

| | Device run A | Device run B | Device run C | *Simulator (NOT a phone)* |
|---|---|---|---|---|
| mean | **41.8 ms** | **52.2 ms** | **47.5 ms** | *510.1 ms* |
| min | 15.7 ms | 23.8 ms | 23.1 ms | *141.2 ms* |
| p50 | 41.5 ms | 56.7 ms | 46.6 ms | *456.6 ms* |
| p90 | 49.8 ms | 64.0 ms | 62.2 ms | *769.4 ms* |
| max | 71.5 ms | 66.2 ms | 64.7 ms | *1092.3 ms* |

n = 72 engine calls per run. Device mean across the three runs spans **41.8–52.2 ms**.

**The Simulator is ~10–12× slower than the phone for identical work.** Any latency figure this project has ever quoted from a Simulator run — including the "~382 ms `.accurate` / ~11 ms `.fast`" numbers written into `DualPassVisionOCR.swift`'s header — describes the Mac, not the device. On real hardware the full dual-pass merge costs **~42–52 ms mean** on a 1080×1920 frame with the ROI restricted to the display panel. (Those header numbers were also measured on a different corpus at a different resolution, so this is not a like-for-like refutation of them — it is simply the first device number.)

Run-to-run spread between the two device runs is ~25 % of the mean. With only two runs I cannot characterize the distribution; **the confidence interval on device mean latency is unmeasured.**

### Engine load / first-call cost

| | Device run A | Device run B | Device run C | *Simulator* |
|---|---|---|---|---|
| `OCRManager()` construction | 0.002 ms | 0.002 ms | 0.002 ms | *0.002 ms* |
| **First `recognize()` in the process (cold)** | **554.7 ms** | **266.4 ms** | **223.0 ms** | *1358.6 ms* |
| Second `recognize()`, same buffer | 46.8 ms | 49.0 ms | 67.0 ms | *722.2 ms* |
| Cold overhead (first − second) | 507.9 ms | 217.4 ms | 155.9 ms | *636.4 ms* |

- Constructing the engine is free (`OCRManager` and `DualPassVisionOCR` are trivial value wrappers — no model is loaded at init).
- The cost is **entirely in the first `recognize()`**: Vision loads its text model lazily and keeps it process-resident. On device the cold penalty was **508 / 217 / 156 ms** across runs A / B / C — a 3.3× spread that decreases monotonically with each back-to-back run, consistent with OS-level caching. **All three are real observations; I cannot say which represents a cold-boot user.** The true first-launch-after-reboot cost is **unmeasured**.
- Practical implication: the first frame a user points at an instrument costs roughly a quarter to half a second more than every subsequent frame. A warm-up `recognize()` at capture-screen appearance would hide it. That is a recommendation, not a measurement.

### Harness render cost (not a pipeline number)

`SyntheticDisplayRenderer` at 1080×1920 in Debug: mean 108.4 ms / max 891.4 ms (device run A). This is test-fixture overhead — the app never pays it in the camera path. Recorded only so the 11–12 s test duration reconciles.

---

## 5. Repeatability / determinism

- **Accuracy metrics were bit-identical across all four runs** — device A, device B, Simulator, and device C (after a 500+ line `FormatValidator` rewrite landed) all produced `correct = 65`, `powerOfTenError = 7`, `decimalPreserved = 65`, and the same seven failing per-case rows. The corpus is deterministic (no `Date()`, no RNG; degradation and pose are pure functions), and Vision was deterministic on it.
- **Latency is not repeatable** and is reported per-run above rather than pooled.
- The Simulator producing identical *recognition* outcomes to the phone is worth noting: for accuracy work the Simulator appears to be a faithful proxy here (n = 1 comparison, one corpus — do not generalize). For timing it is not.

---

## 6. What these numbers do NOT say — limits, stated plainly

1. **The corpus is synthetic and easy.** `SyntheticDisplayRenderer` draws a monospaced *system font* on a flat panel. It has no segment gaps, no glare, no viewing-angle response, no real LCD contrast curve. At 1080×1920 the panel is ~820×250 px and glyphs are ~155 px tall — far larger and cleaner than a handheld photo of a temperature gun. **90.3 % here does not transfer to real instruments and must not be quoted as instrument accuracy.**
2. **The motivating case did not reproduce.** `80.8` and `808` were each read correctly in all 8 variants — 16/16. This corpus does **not** reproduce the field failure that started this work; it reproduced a *different instance of the same class*. Whether the fix that handles `.5` also handles a real gun's `80.8` is **unmeasured**.
3. **The degradation axes did not bite.** `blur`, `noise`, `low-contrast` and 55° yaw all left accuracy unchanged, which means they were not strong enough to stress this recognizer on this imagery. The degradation sweep therefore provides **no evidence** about robustness limits — it establishes only that the engine is comfortably above threshold at these settings.
4. **No held-out human-labeled eval set exists.** Nothing here licenses a real-instrument accuracy claim, and this report makes none.
5. **One phone, one OS, one configuration.** iPhone 12 Pro Max / iOS 26.5.2 / Debug. Other devices, other OS versions, Release builds: **unmeasured**.
6. **The seven failures are one label.** n = 7 concentrated on a single ground-truth string. The 9.7 % headline is therefore a property of *this label mix*; change the mix and the rate changes mechanically. Read it as "the leading-decimal case fails 87.5 % of the time", which is the load-bearing statement, rather than as a general 9.7 % error rate.

---

## 7. Actionable findings for the decimal-rescue work

Ranked by what the data supports.

1. **`FormatValidator`'s separator vocabulary is too narrow.** Vision transcribes a leading decimal point as a bullet-like glyph, and the parser discards it as junk instead of treating it as separator *evidence*. This is measured, reproducible (7/8 variants, 3/3 runs), and fixable in the parser without touching the recognizer — exactly the model-independent fix the lead called for.
2. **Zero refusals is the real defect.** The 10x errors are not the failure; the *silent acceptance* of them is. `undeclaredIntegerCertainty = 0.75` depresses confidence but never vetoes. A bare integer token that sits immediately after a discarded non-digit, non-separator glyph is a strong `.ambiguousDecimal` signal and is currently ignored.
3. **A format prior would have caught all 7.** Every failure changed the fraction-digit count from 1 to 0. Stable history plus a declared/learned `decimalPosition` refuses that on structure alone, no pixels required.
4. **Cold-start warm-up is worth doing.** 217–508 ms measured penalty on the first recognized frame.

---

## 8. Failures and gaps in this round's own work

- **`CapturePerformanceTests`: 10/10 PASSED** (Simulator iPhone 17 Pro, `** TEST SUCCEEDED **`, exit 0, log `scratchpad/capperf.log`). Measured *after* the sibling decimal-rescue landing, so this covers the current tree, not just my own change. The invariant holds.
  - A first attempt at this verification failed to compile, transiently and **not** because of this round's work: `DAQPalTests/DecimalRescueTests.swift:348:77: error: ambiguous use of 'init'`. That is a concurrently-authored sibling file; the tree self-consistently compiled minutes later and the run above is the valid one. Device benchmark runs A and B predate that file entirely.
  - This round created exactly one file, `DAQPalTests/DecimalBenchmarkTests.swift`, and modified **no** app source, so it cannot affect `AppState.apply`.
- **No Release-configuration run.** Debug only.
- **No second device model, no thermal-soak run, no sustained-load latency.**

---

## 9. Reproducing this

```bash
cd /Users/danielliu/Documents/DAQPal

# DEVICE (what this report is based on)
xcodebuild test -project DAQPal.xcodeproj -scheme DAQPal \
  -destination 'platform=iOS,id=00008101-001E44EC1A88001E' \
  -only-testing:DAQPalTests/DecimalBenchmarkTests \
  -derivedDataPath <scratch>/dd-dec-device \
  -allowProvisioningUpdates DEVELOPMENT_TEAM=56WA4P82Z5 CODE_SIGN_STYLE=Automatic
```

The full report is `print`ed to stdout **and** attached to the `.xcresult` as `decimal-benchmark.txt`. On device the print lands in the xcodebuild log; **on Simulator it does not** (the test host's stdout goes to the simulator's system log), so for a Simulator run pull the attachment instead:

```bash
xcrun xcresulttool export attachments \
  --path <scratch>/dd-dec-sim/Logs/Test/Test-DAQPal-*.xcresult \
  --output-path <scratch>/simatt \
  --test-id "DecimalBenchmarkTests/testDecimalPreservationAndPowerOfTenErrorRate()"
```

**CI:** the class is slow and is excluded at the invocation level, matching how `OCRBenchmarkTests` is handled — add `-skip-testing:DAQPalTests/DecimalBenchmarkTests` to the default sweep. This is documented in the file header; no project or scheme file was edited.
