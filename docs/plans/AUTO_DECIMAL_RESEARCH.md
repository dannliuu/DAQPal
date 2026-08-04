# Zero-Config Decimal Determination — Research Findings

2026-08-03 · 8 agents, measure → research → adjudicate · Every headline claim below was **executed**, not argued.
Requirement driving this: *"I don't want to set the format. I want the auto format determination to be accurate from the get go."*

---

## The answer, in one paragraph

**On your instrument, determining the decimal from Vision's text output is impossible — measured, not inferred.** But **wrong-and-accepted can be driven to zero today, at zero configuration**, and that is a different and achievable goal. The gap between those two sentences is the whole plan.

---

## 1. Why it is impossible from text (three independent proofs)

**Vision destroys the dot before DAQPal runs.** On your own `Fixtures/ir_gun_display.png`, `VNRecognizeTextRequest` at `.accurate` returns exactly `SCAN`@1.000, `MAX`@1.000, **`900`**@0.300, **`927`**@0.300 — for a display showing **90.0** and **92.7**. No dot appears in *any* candidate, at revisions 1, 2 **and** 3, full-frame and under ROI. A human-viewable crop of that region shows a large square dot sitting on the baseline. The information is in the pixels; it is not in Vision's output.

**No number of frames can recover it.** Two 30-frame arms with ground truths `90.0` and `900` produced **byte-identical** pipeline streams (30/30 accepted, confidence 0.225, anchor `"900"`). Likelihood ratio exactly 1, for all N. Temporal voting cannot separate hypotheses that produce identical evidence.

**The hardware makes it impossible in principle.** On 3.5/4.5-digit panel meters the decimal point is placed by a **jumper**. The digit pattern does not encode it. No parser, prior, or model reading the digits can recover what the digits never carried.

Everything downstream of Vision's tokenizer — `FormatValidator`, `DecimalRescue`, `TemporalConsensus`, `DisplayFormatInference` — is structurally incapable of fixing this class.

---

## 2. The defect that explains your 9.7% silent errors

One constant comparison:

```
FormatValidator.undeclaredIntegerCertainty  = 0.75   ("I saw no separator")
TemporalConsensus.decimalRescueConfidence   = 0.70   (bar for "the separator corroborates")
```

**"I saw no separator" scores above the bar for "the separator corroborates."** Absence of evidence is counted as evidence. Measured: over 27 parseable readings the minimum decimal confidence was 0.750 and **0 of 27** fell below 0.700, so `guard corroboratedBySeparator || corroboratedByPrior` **can never fail** on the shipping path. The documented "a 10× change needs independent corroboration" rule does not exist at runtime.

Measured consequence — anchored on `80.8` for three frames, then a sustained `808` run: **migrates at frame 7 and publishes `808` as STABLE, permanently.** The anti-flip-flop guard buys ~100 ms and then concedes.

That same 0.75 is also precisely where "wrong readings carried 0.75 confidence" comes from: `1.0 OCR × 0.75`.

---

## 3. Two planned tasks are wrong, one is a no-op

**B2 is a provable zero-delta change.** Four sequences replayed with `formatPrior: nil` versus a live prior produced **identical outcome streams frame-for-frame**. The prior has exactly two effects and both are dead: its confidence multiplication at `TemporalConsensus.swift:566` feeds an `Outcome` confidence that `MeasurementProcessor.swift:472` discards via `case .stable(let v, let t, _)`, and its corroboration path is short-circuited by the `0.75 > 0.70` bug above. **Do not schedule B2 as a decimal-accuracy item.**

Worse: on the measured failure class the prior **certifies the error**. It is a majority vote over grammars derived from the OCR text, so it tracks the mode of the OCR distribution, not the display. With truth `.5` and systematic dropout it establishes grammar `#` at observation 4 with stability 1.000, scoring the wrong reading 1.000 and the truth 0.250. It filters minority noise; it is structurally blind to systematic bias — and systematic bias is exactly what your failure is.

**The plan has been chasing the wrong bug.** The U+2022 bullet-glyph class that B3 targets appears in **0** of the real fixture's readings and in only **6 of 48** seven-segment failures. And B3's wording is actively dangerous: *"a non-alphanumeric glyph in separator position is separator evidence, not junk"* **authors** a decimal position from a glyph the recognizer could not identify — a degree sign, a thousands comma, a colon lobe or a glare speck becomes a decimal point. It converts a class that today truncates into a class that silently invents magnitude. **Rewrite B3 as refusal, not rescue.**

---

## 4. What actually works — ranked, all zero-config

| # | Change | Measured effect | Effort |
|---|---|---|---|
| **1** | **Separator ledger** — make "no separator seen" a refusal, not corroboration | 8 scenarios × 90 frames: **429 correct / 158 wrong / 133 refused → 375 / 0 / 345**. Excluding genuine integers it is strictly better on *both* axes | 1–2 d |
| **2** | **Tokenizer: unidentified glyph between digit runs ⇒ refuse** | Live corruption today: `80•8` → **80**, `12•345` → **345** (same for `·`, `'`, `:`, `°`, `-`) | 0.5 d |
| **3** | **Refuse when two OCR candidates disagree by a decade** | 21 of 48 wrong-accepted caught (43.8%), **0 of 16** correct readings lost | ~2 h |
| **4** | Fix `SegmentCellScanner`'s safety property *before* wiring | Today 18 wrong / 600 synthetic; **9 of 16 wrong on your real photo** | 2–3 d |
| **5** | Gate geometric decimals on a verified **rectified** lock | Correct position holds to 1.0° roll, lost from 1.25°; round-trip restores it to 35° | 1 d + WS-A |
| **6** | Wire the scanner as **corroborate-or-veto only** | Cannot inflate any reading; earns authoring rights later | 2 d |
| **7** | One binary confirmation, **only after** a refusal | The honest fallback for the provably unresolvable class | 1–2 d |
| **8** | Determinism: pin Vision revision, total candidate ordering | `900` and `927` both carry **exactly 0.3000** — which field exports is currently tie-break luck | ~2 h |

**Start with 1–3.** They are ~3 days total, need no pixels, no device, no fixtures, and no user input, and together they take wrong-and-accepted to zero.

---

## 5. Ideas measured and rejected (so they are not re-proposed)

- **n-best alternatives** — Vision returned exactly **one** candidate in **62/62** observations despite requesting 10. "Rank 0 missing a dot, rank 1 has it" = 0 occurrences.
- **Unit/range priors** — a ×10 error escapes a range check iff the true value ≤ hi/10, so an IR gun's blind zone is **everything ≤ 102.2 °F** — the entire operating region.
- **Digit count** — N glyphs admit N+1 decimal hypotheses spanning N decades and eliminate none.
- **`customWords`** — output **byte-identical** to baseline (ignored while `usesLanguageCorrection = false`).
- **`minimumTextHeight`** — at 0.10 it silently truncates `900` → `90`: it can *manufacture* the exact error we are preventing.
- **Naive image conditioning** — **0 of 12** configurations accepted a correct reading; contrast ×2 reduced Vision from 4 observations to **0**.
- **Device detection** — even perfect identification yields only a unit and a range, and the range prior is blind here.
- **Cross-field priors** ("MAX ≥ live") — both evaluate *satisfied* on the fixture's wrong pair (927 ≥ 900).
- **Per-character `boundingBox(for:)`** — decisive where it exists (`heightRatio < 0.5` separated 29/29 dots from 103/103 digits, zero config) but the dot is absent from the string on the target, so there is no range to query.

**D6 vindicated, sharply:** the strongest *synthetic* discriminator (provenance, Youden J = 0.804 over 306 candidates) has the **opposite sign** on the real instrument, where it would refuse the truth. Synthetic tuning actively misleads here.

**Conflict flagged:** `DAQPal_DEVICE_CONTEXT_RESEARCH.md` §3.5 recommends deleting `SegmentCellScanner` and `DecimalRescue` as dead code. **Do not execute that.** It was written when the decimal was framed as a code defect; the pixel route is now the only remaining path to genuine determination.

---

## 6. The honest ceiling

**Class A — the dot is destroyed inside Vision and the segmenter cannot resolve it either.** This is your instrument, today. Not recoverable by any parser, prior, or frame count. The system must **refuse**, with a legible reason, and recovery requires rectification + the pixel scanner (ranks 4–6), which is not shippable today.

**The unavoidable cost:** a genuine integer instrument goes from 82/90 correct to 0/90 refused. That is not a tuning miss — *"integer display"* and *"##.# display whose dot is never resolved"* are **the same observation**. No function of the recognized string separates them at any N.

That is what rank 7 is for: **one binary tap, offered only after the system has already refused** — not a format editor, not asked up front, and storing exactly one `Bool`. That is the nearest honest thing to "no configuration" for a class that is provably unresolvable without one bit of outside information.
