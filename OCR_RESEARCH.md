# DAQPal — Digit-Only OCR Enhancement Research

**Date:** 2026-07-23 · Research conducted by a 4-agent verification workflow (Apple Vision
capabilities, PaddleOCR route, specialized/classical landscape, architecture strategy),
synthesized against DAQPal's actual code seams. Sources cited inline; uncertainties listed
at the end. Feeds spec Milestones 9 (OCR benchmark) and 11 (specialized model).

---

## Executive summary

1. **Apple Vision cannot be made closed-vocabulary — confirmed, not folklore.** The full
   API surface of both `VNRecognizeTextRequest` and the iOS 18+ `RecognizeTextRequest`
   contains no character-allowlist. `customWords` is a bias mechanism that is *ignored*
   when `usesLanguageCorrection = false` — and enabling correction is exactly what turns
   digits into dictionary words (the catch-22). iOS 18/26 added API ergonomics and
   document parsing, not new constraint knobs; `DataScannerViewController` has no numeric
   content type. An Apple Frameworks engineer has stated on the developer forums that
   **segmented (LCD/LED) digits are unsupported** by Vision text recognition, recommending
   a custom Core ML model. Vision stays what it is today in DAQPal: the bootstrap engine
   made trustworthy by lenient extraction + validation — and the auto-labeler for training
   data.
2. **Nothing to buy or download.** No public, ready-to-use, closed-vocabulary
   instrument-display recognizer exists (HuggingFace, GitHub, or commercial). The popular
   meter-reading projects that solved this (jomjol's AI-on-the-edge-device, 8.5k stars)
   use exactly the architecture our spec proposes — tiny per-digit-crop CNNs — but their
   code/weights are commercially unusable (dual/non-commercial licenses). Their
   *architecture pattern* is free to imitate. **Build, don't buy** — and the build is
   small.
3. **Recommended end state: a hybrid, sequenced deliberately.**
   - **General engine (the one that meets the multi-display requirement):** a compact,
     fully-convolutional **CTC line reader with a hard 13-class vocabulary**
     (0–9, `.`, `-`, CTC-blank) — "CRNN without the RNN" / SVTR-LCNet-lite style. It
     assumes no glyph geometry, so it reads fixed-pitch seven-segment *and*
     proportional/raster digits on OLED/graphical displays with one model. Conv-only ⇒
     maps to the Neural Engine (LSTMs fall off it). Expected ~3–7 MB fp16 (~1.5–3 MB
     int8), low-tens-of-ms per line — faster than today's `.accurate` Vision pass.
   - **Specialist:** the spec's 32×48 **per-slot CNN, 11 classes** (0–9 + blank/unlit) for
     user-configured fixed-pitch displays — sub-millisecond per digit, real per-digit
     confidences for `Measurement.digitConfidences`, trainable in **Create ML with zero
     PyTorch**. Honest blocker: it inherits `DigitSegmenter`, which is still the
     fixed-pitch stub; slot-path quality is capped by segmenter geometry work.
   - **Cross-check:** classical **segment-sampling** (ssocr-style: threshold 7/14 regions
     per cell, LUT decode) on segmented displays only, fused as an extra multiplicative
     factor in `ConfidenceEngine` — corroborate or veto, never inflate. Two independent
     readers agreeing is a stronger signal than either alone.
   - **Interim bridge (optional):** a stock PP-OCR mobile rec model converted to Core ML
     with **inference-time logit masking** to the digit subset — closed *output alphabet*
     without training anything. Kills letter hallucination outright but does not fix the
     model's segment-glyph confusions (stock scene-text models score ~57% on seven-segment
     without adaptation), so it's a bridge, not a destination.
4. **Training data is the actual project.** Synthetic-first: DSEG 7/14-segment fonts
   (OFL-1.1, commercial-safe), VFDigit for VFD (OFL), Adafruit 5×7 glyph bitmaps for
   dot-matrix, common sans fonts for raster displays — augmented per display *technology*
   (polarity, OLED bloom, LCD ghosting, glare, perspective, e-ink texture). Then
   **pseudo-label real footage through DAQPal's own validation stack**: frames whose
   readings pass format+temporal+physical gates with high fused confidence become (crop,
   label) pairs for free — the SAVE VIDEO feature is the collection mechanism, and a
   held-out *human-labeled* eval set is load-bearing (no accuracy claims without it).
   Licensing traps verified: avoid Digital-7 (freeware/personal-only), SVHN
   (non-commercial), jomjol/nliaudat weights (non-commercial/dual license). MIT-licensed
   `MiXaiLL76/7SEG_OCR` (3,333 synthetic images) is safe seed data.

---

## The landscape, verified (2026)

| Option | Closed vocab? | iOS on-device | Verdict |
|---|---|---|---|
| Apple Vision (`RecognizeTextRequest`, iOS 18/26 incl.) | ❌ impossible (no allowlist; logits hidden; `customWords` bias-only and dead when correction is off) | ✅ native | Bootstrap + auto-labeler; segmented digits officially unsupported |
| `DataScannerViewController` / Live Text | ❌ 8 content types, none numeric | ✅ | Strictly less control than raw Vision; not viable |
| Google ML Kit | ❌ | ✅ | No gain over Vision |
| PP-OCR v4/v5/**v6** rec (SVTR-CTC family) | ✅ via dict retrain, or DIY ~10-line logit mask (none built in — verified in `rec_postprocess.py`) | via conversion | The credible middle tier; Apache-2.0; v6 Tiny is 1.5M params |
| docTR / OnnxTR | ✅ native `add_whitelist()` at inference | ❌ Python-only | Proof the masking pattern is standard; not deployable to iOS |
| RapidOCR | same as PP-OCR (same weights, pre-ONNX'd) | via conversion | Convenience repack; same work |
| Tesseract + `tessdata_ssd` (7-seg traineddata, Apache-2.0) | ✅ | poor | 2019-era; a working *precedent* (0.19% char error on synthetic), not a component |
| ssocr / classical segment sampling | ✅ by construction | ✅ reimplement (~few hundred lines; ssocr itself is GPL — imitate, don't port) | Deterministic, microseconds; glare/threshold-sensitive; single-row only |
| MMOCR | — | — | Unmaintained since 2023; skip |
| TrOCR-small / PARSeq-tiny | ❌ general vocab | heavy | PARSeq stock: ~57% on seven-segment — transformers don't transfer without fine-tuning |
| Tiny custom CNN / conv-CTC (spec M11) | ✅ by construction | ✅ Core ML, sub-ms–tens of ms | **The right end state** |

Key deployment facts (verified):
- **coremltools' ONNX importer is frozen** (since ~2022) — the working conversion path is
  Paddle → PyTorch (`PaddleOCR2Pytorch`, actively maintained, supports through PP-OCRv6)
  → coremltools → `.mlpackage`, or train your own in PyTorch from the start.
- **ONNX Runtime's CoreML EP silently falls back to CPU on any dynamic-axis subgraph** —
  variable-width OCR inputs lose ANE acceleration exactly where it matters. Mitigation:
  fixed input-width buckets (or per-cell fixed crops, which `DigitSegmenter` already
  provides).
- Quantization: fp16 halves, int8 quarters model size; A17-Pro-and-later ANEs do int8
  activation compute (throughput, not just disk).
- **PaddleOCR's own team published the near-exact recipe** ("optical-power-meter
  seven-segment digital-tube recognition"): digit+units dict, **~155 real labeled images**
  + `text_renderer` synthetic data → PP-OCRv3 rec 52%→72%, SVTR-Tiny 78.9%. Read both
  ways: tiny real datasets go far with a restricted dict — and even then, production-grade
  accuracy needs more data/iteration than a weekend.

Reference accuracy expectations from prior art: specialized 7-seg pipelines reach 93–99%
(93% on realistic glare/skew phone photos; 98%+ only on clean captures). Generic engines
without adaptation: ~57%. DAQPal's validation stack sits on top of whatever the recognizer
does — the spec's "≥99% correct *accepted* measurements" is a system property (recognize +
reject), not a raw model property.

---

## Recommendation mapped to DAQPal's seams

No pipeline surgery required — `OCRManager`'s `OCREngine` protocol, `DigitRecognizer`,
`DisplayFormat`, and the multiplicative `ConfidenceEngine` were built for exactly this.

**Phase 0 — spike (S, ~a day):** pull `en_PP-OCRv4_mobile_rec` (6.8 MB, Apache-2.0) or
PP-OCRv6 Tiny, run it offline over real bench photos/videos with a digit post-filter.
Measures the domain gap directly and decides whether the interim logit-masked bridge is
worth shipping or whether to go straight to Phase 3.

**Phase 1 — data + eval substrate (M):** extend `SyntheticDisplayRenderer` into an offline
generator (DSEG/VFDigit/5×7/sans, per-tech augmentation) emitting digit tiles *and*
labeled line crops; build the pseudo-label harvester on the accepted-`Measurement` stream
(SAVE VIDEO sessions + fixtures); create the held-out human-labeled eval set. This phase
also produces the Milestone 9 benchmark harness (Vision vs candidates on identical
fixtures).

**Phase 2 — slot CNN specialist (M; the model itself S via Create ML):** 32×48, 11-class,
swapped into `DigitRecognizer` behind its existing signature; enabled for configured
fixed-pitch formats. Real per-digit confidences light up the digit-level temporal design.
Depends on hardening `DigitSegmenter` geometry (perspective, decimal handling) — itself M
and the least-bounded item.

**Phase 3 — the general engine (L):** digit-vocabulary conv-CTC line reader as a new
`OCREngine`, routed by `DisplayFormat` (or default). This is the deliverable that makes
recognition closed-vocabulary and multi-display in one model. Train on Phase 1 data;
quantize; benchmark against Vision on the Phase 1 harness before switching the default.

**Phase 4 — fusion (M):** segment-sampling cross-check on segmented displays; slot↔CTC
agreement where both run; extra multiplicative factor in `ConfidenceEngine`
(corroborate/veto only).

**Phase 5 — continuous improvement (S–M):** opt-in pseudo-label harvesting from real
sessions; periodic retrain/re-eval.

Phases 1+3 alone satisfy "numbers only, performant, robust, all display types."
Phases 2+4 add the precision/confidence upside on the DMM-majority case.

---

## Measured results (Phases 0–1 executed 2026-07-23)

**Phase 1 is built and running**: `SyntheticDisplayGenerator` (4 glyph styles × deterministic
per-tech augmentations, DSEG fonts bundled under OFL), `RecognitionBenchmark` + Milestone 9
harness, `TrainingDataHarvester` (validation-gated pseudo-labeling), and the Phase 4
`SevenSegmentSampler` (classical, deterministic — decodes 10/10 clean digits in both
polarities). One real bug found by the sampler and fixed: the generator double-flipped its
output buffers (verified by raw-row ASCII dump; '2' rendered as '5' upside-down).

**Milestone 9 — first measured Vision numbers** (192 synthetic cases/engine: 12 values ×
4 styles × clean/moderate/hard/inverted, iPhone 17 Pro simulator; synthetic ≠ real-world,
but identical across engines):

| Style | Vision `.accurate` | Vision `.fast` |
|---|---|---|
| sans (raster/OLED-graphical) | **93.8%** | 68.8% |
| seven-segment (DSEG7) | 14.6% | **33.3%** |
| fourteen-segment (DSEG14) | 2.1% | 12.5% |
| dot-matrix (5×7) | **0.0%** | **0.0%** |
| overall | 27.6% | 28.6% |

Mean latency: `.accurate` 382.5 ms vs `.fast` **10.9 ms** (~35×).

**Phase 0 spike — stock PP-OCRv3 (rapidocr) on PIL-rendered DSEG, 63 cases** (measured,
single run; caveats in `scratchpad` spike_report): DSEG7+14 combined **11.9%** exact vs
38.1% on its sans control; polarity-inverted segment displays: **0%**. Mean 136 ms/case
(CPU, Mac).

**What the numbers decide:**
1. The research thesis is now quantified, not asserted: general OCR collapses on exactly
   the displays DMMs use (segmented: 2–33%; dot-matrix: zero) while being fine on raster
   text. The custom digit model (Phases 2–3) is *necessary*, not an optimization.
2. **The logit-masked stock-PP-OCR bridge is dead** — stock PP-OCR (≈12%) is no better
   than Vision on segment glyphs, so shipping it buys nothing. Skip to trained models.
3. Surprise worth exploiting: `.fast` *beats* `.accurate` on seven-segment (33% vs 15%)
   at 1/35th the latency — its character-level classifier handles disconnected glyphs
   better than the line-reader. Worth a follow-up: try `.fast` as the live-path engine for
   segment-format devices while the custom model is built (validation still gates).
4. The classical `SevenSegmentSampler` already reads clean segment tiles deterministically
   where Vision manages 15% — strong evidence the Phase 4 fusion (and possibly promoting
   the sampler to a first-class engine for configured 7-seg devices) is high-value.

**Training-free round (2026-07-23, user deferred model training — no datasets yet):**
the two no-training levers shipped and were measured on the identical benchmark:

| Style | `.accurate` | `.fast` | **dual-pass (shipping)** |
|---|---|---|---|
| sans | 93.8% | 68.8% | **93.8%** |
| seven-segment | 14.6% | 33.3% | **41.7%** |
| fourteen-segment | 2.1% | 12.5% | **14.6%** |
| dot-matrix | 0.0% | 0.0% | 0.0% |
| overall | 27.6% | 28.6% | **37.5%** |

Latency: 384 ms → 397 ms (the `.fast` rescue hides inside the `.accurate` pass). The
merge beats *either* engine alone on segment glyphs (some cases only one engine reads).
`OCRManager` now defaults to `DualPassVisionOCR`. The `SevenSegmentSampler` is fused into
`ConfidenceEngine` as a corroborate-or-veto cross-check on constrained formats (confident
disagreement ⇒ `AMBIGUOUS_DIGIT`; abstains on unconstrained/non-segment displays and — a
documented fixed-pitch-segmenter limit — on negative readings). Dot-matrix remains
unreadable by any engine: that column moves only when a trained model lands.

**Phase status:** 0 ✅ · 1 ✅ · **interim training-free levers ✅ (dual-pass +10pt overall,
~3× on seven-segment; sampler fusion live)** · 2/3 deferred by user until datasets exist
(the harvester + SAVE VIDEO accumulate them passively) · 4 core ✅ (fusion shipped;
segment-sampler-as-primary-engine still open) · 5 pending.

## What stays true regardless

- Vision remains the *labeling machine* and the fallback engine — its output already can't
  reach a reading without surviving digit-anchored lenient extraction plus the validation
  chain, so letters cannot enter the data today; the new engine removes upstream misreads
  rather than adding a filter.
- Every phase's accuracy claim must come from the held-out eval set; synthetic→real domain
  gap is the single most consistent failure across all surveyed prior art.
- Real recorded bench sessions (SAVE VIDEO) are simultaneously: training data, benchmark
  fixtures (`dmm_001.mov`), and the Milestone 9 comparison corpus.

## Key uncertainties (flagged by the researchers)

- No hands-on conversion/benchmark was performed — conversion-time op snags
  (SVTR attention ops through coremltools) and true ANE latencies are estimated from
  adjacent evidence, not measured; Phase 0/1 exist to measure them.
- The PARSeq-beats-PP-OCR seven-segment benchmark claim comes from a search snippet (PDF
  unparseable) — treat as a pointer.
- PaddleOCR's 2.6-era vertical tutorials may have moved in the 3.x docs restructure; the
  recipe (dict swap + `text_renderer` + PPOCRLabel) is unchanged in current docs.
- Per-dataset Kaggle licenses unverified; UFPR meter datasets show no license assertion —
  research-use assumption until confirmed.
