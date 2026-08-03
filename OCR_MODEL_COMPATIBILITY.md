# OCR Model → iPhone Compatibility Matrix

**Scope:** Phase 1 + 2 evaluation of candidate text recognizers as replacements for, or companions to,
Apple Vision behind the existing `OCREngine` seam (`DAQPal/OCR/OCRManager.swift`).

**Status of numbers in this document:** every byte size, conversion result and latency below was produced
by a command actually run on this machine. Anything not measured is written as **unmeasured**. No iPhone
latency was measured — see [What was NOT measured](#what-was-not-measured).

---

## Measurement environment

| Item | Value |
|---|---|
| Host | Apple **M1 Pro**, macOS 26.5.2 (build 25F84) |
| Python | 3.13.5 (venv under the scratchpad) |
| coremltools | **9.0** (`coremltools-9.0-cp313-none-macosx_11_0_arm64.whl`) |
| torch | 2.13.0 (coremltools warns: "Torch 2.7.0 is the most recent version that has been tested") |
| onnx / onnxsim / onnxruntime | installed in venv |
| python-doctr | 1.0.1 |
| transformers | 5.14.1 |
| Connected iPhone | `Daniphone`, **iPhone 12 Pro Max (iPhone13,4)**, A14 Bionic — `xcrun devicectl list devices` reports `connected` |
| Benchmark protocol | batch 1, 5 warm-up predictions, then 50 timed predictions; median and p90 reported |

> **Note on the device.** The task brief described the connected phone as iOS 26.5.2. `devicectl` identifies
> it as an **iPhone 12 Pro Max (A14 Bionic)**, consistent with the given ECID prefix `00008101`. A14's Neural
> Engine is materially slower than the A17/A18 class parts, which matters for any latency extrapolation.

**Environment finding (contradicts the brief's assumption):** `coremltools` **does** install cleanly on
Python 3.13.5 — version 9.0 ships a `cp313` arm64 wheel. The only install obstacle was PEP 668:

```
error: externally-managed-environment
```

`pip3 install coremltools` into the system Python is blocked by Homebrew; a venv resolves it completely.

---

## Compatibility matrix

Latency columns are **host M1 Pro macOS** numbers, *not* iPhone numbers. They are included because they are
real and they rank the candidates by relative cost; they are **not** a substitute for on-device measurement.

| Candidate | Downloadable | Format available | Size (real bytes) | Convertible to Core ML (attempted? result?) | Custom ops needed | Expected iPhone latency | Verdict | Evidence |
|---|---|---|---|---|---|---|---|---|
| **Apple Vision** (incumbent) | n/a — OS built-in | `VNRecognizeTextRequest` | 0 bytes shipped | n/a — already native | none | **unmeasured** in this task | **HOT PATH (keep)** | `DAQPal/OCR/VisionOCR.swift`, `DualPassVisionOCR.swift` |
| **PaddlePaddle/PP-OCRv5_mobile_rec_onnx** | ✅ HTTP 200 | **`.onnx`** (opset 7) + `inference.yml` | `inference.onnx` = **16,534,782**<br>`inference.yml` = **148,345** | ✅ **ATTEMPTED — SUCCEEDED.** Required opset 7→17 upgrade + `onnxsim` constant-folding first. Output `.mlpackage` = **8,368,881 bytes** (fp16) | **None.** Final MIL program uses only standard ops. Two *pre*-processing steps were required (see below) | **unmeasured.** Host M1 Pro: median **1.97 ms** (ALL) / 3.22 ms (CPU+GPU) / 5.41 ms (CPU) | **FALLBACK** (see caveats) | `convert_ppocr.py`, `bench.py` |
| **rrainn/doctr-crnn-vgg16-bn** | ✅ HTTP 200 | `.bin` (PyTorch) only | `pytorch_model.bin` = **63,303,144** | ✅ **ATTEMPTED — SUCCEEDED**, but only after replacing doctr's dynamic reshape with a static one and bypassing its postprocessor. `.mlpackage` = **31,629,085 bytes** (fp16) | **None** in the final program, but the stock `forward()` is **not convertible** as-is | **unmeasured.** Host M1 Pro: median **1.00 ms** (ALL) / 1.86 ms (CPU+GPU) / 1.97 ms (CPU) | **REJECT for decimals** (see §Resolution) | `convert_crnn2.py` |
| **rrainn/doctr-parseq** | ✅ HTTP 200 | `.bin` (PyTorch) only | `pytorch_model.bin` = **95,457,349** | ❌ **ATTEMPTED — FAILED.** Two routes tried (generic wrapper, and doctr's official `exportable=True` path). Both fail at the same coremltools op | Blocked on **`aten::Int`** lowering | **unmeasured** — no model produced | **REJECT** (conversion failed) | `convert_parseq2.py`, traceback below |
| **microsoft/trocr-small-printed** | ✅ HTTP 200 | `.safetensors` + `.bin` | `model.safetensors` = **245,839,136**<br>`pytorch_model.bin` = **245,933,041**<br>`sentencepiece.bpe.model` = **1,356,293** | ⚠️ **PARTIAL — encoder only.** Encoder (22.0 M params) converted: `.mlpackage` = **43,760,141 bytes**. **Decoder (39.6 M params) conversion NOT attempted** — it is autoregressive with a 64,044-token vocab and needs a hand-written KV-cache/greedy loop in Swift | none hit for the encoder; decoder **unassessed** | **unmeasured.** Host M1 Pro, **encoder alone, one forward pass**: median **12.26 ms** (ALL). Full model = encoder + *N* decoder steps, **unmeasured** | **REJECT** for hot path | `convert_trocr.py` |
| **baidu/Unlimited-OCR** | ✅ HTTP 200 | `.safetensors` (sharded index) | `model-00001-of-000001.safetensors` = **6,672,547,120** (6.67 GB)<br>`tokenizer.json` = **9,979,544** | ❌ **NOT ATTEMPTED — excluded on architecture.** Reasons are dispositive and listed below | Requires `trust_remote_code=True`; MoE routing; server runtimes | **unmeasured** — excluded | **REJECT — not an on-device candidate** | `config.json`, model card |

---

## Per-candidate detail

### PP-OCRv5 mobile rec (ONNX) — converted successfully

The shortest path, as predicted — but **not** a one-liner. Three real obstacles, all reproducible:

1. **coremltools has no ONNX front-end.** `ct.convert("inference.onnx")` fails:
   ```
   ValueError: Unable to determine the type of the model, i.e. the source framework.
   Please provide the value of argument "source", from one of ["tensorflow", "pytorch", "milinternal"].
   ```
   `ct.converters` exposes only `libsvm`, `sklearn`, `xgboost`, `mil` — the ONNX converter was removed in
   coremltools 6. **ONNX is therefore not a shorter path than PyTorch; it is a longer one**, requiring an
   `onnx2torch` bridge. This directly contradicts the brief's working assumption.

2. **Opset 7 is too old for `onnx2torch`:**
   ```
   NotImplementedError: Converter is not implemented
   (OperationDescription(domain='', operation_type='Constant', version=1))
   ```
   Fixed with `onnx.version_converter.convert_version(m, 17)` (upgrades to 13 and 17 both succeed).

3. **Paddle2ONNX emits weights as `Constant`→`Identity` chains, not initializers:**
   ```
   KeyError: 'conv2d_0.w_0'
   ```
   Fixed with `onnxsim.simplify(...)`, which folds constants and BatchNorm: **1019 nodes → 340 nodes,
   230 initializers**, `check_ok = True`.

After that the conversion is clean. **Numerical parity is excellent:**

| Compute unit | Load | Median | p90 | Max abs diff vs ONNX | Argmax agreement |
|---|---|---|---|---|---|
| ALL (ANE+GPU+CPU) | 2140.3 ms | **1.97 ms** | 2.41 ms | 0.12222 | **100.00 %** |
| CPU_AND_GPU | 234.7 ms | 3.22 ms | 3.38 ms | 0.01003 | **100.00 %** |
| CPU_ONLY | 197.4 ms | 5.41 ms | 5.81 ms | 0.04042 | **100.00 %** |

⚠️ **ANE compilation failure — this candidate only.** Loading with `ComputeUnit.ALL` reproducibly emits:
```
E5RT encountered an STL exception. msg = MILCompilerForANE error:
failed to compile ANE model using ANEF. Error=_ANECompiler : ANECCompile() FAILED.
```
The other two converted models (`CRNN_VGG16`, `TROCR_ENCODER`) load under `ALL` with **no** such message.
The model still runs and is still the ALL-fastest, so it is evidently falling back to GPU/CPU for at least
the failing subgraph. **Whether the same failure occurs on the A14's ANE is unmeasured** and must be checked
on device before this is trusted on a frame-rate path.

⚠️ **Vocabulary liability.** `inference.yml` `PostProcess.character_dict` has **18,383 entries**, and the
first entries are CJK (`一 乙 二 十 丁 …`). `'.'` sits at index **16160**, `','` at 16158, `'-'` at 16159.
For a 4-character numeric instrument display, the softmax spends essentially all of its capacity on
characters that can never appear. That is wasted compute and an added confusion surface — not obviously an
accuracy win over Vision for digits-and-a-dot.

### doctr CRNN VGG16-BN — converted, but the wrong shape for this problem

Stock `forward()` is **not convertible**. `ct.convert` dies with:
```
File ".../coremltools/converters/mil/frontend/torch/ops.py", line 3048, in _cast
  res = mb.const(val=dtype(x.val), name=node.name)
TypeError: only 0-dimensional arrays can be converted to Python scalars
```
Cause: doctr's `forward()` runs `self.postprocessor(logits)` whenever `target is None`, and reshapes using
`features.shape[1]` etc., producing `aten::Int` nodes over non-scalar tensors. Bypassing the postprocessor
and pinning the reshape to the (static) 1×3×32×128 feature shape makes it convert.

| Compute unit | Median | p90 | Max abs diff | Argmax agreement |
|---|---|---|---|---|
| ALL | **1.00 ms** | 1.06 ms | 0.09646 | **100.00 %** |
| CPU_AND_GPU | 1.86 ms | 1.92 ms | 0.09957 | **100.00 %** |
| CPU_ONLY | 1.97 ms | 2.45 ms | 0.12912 | **100.00 %** |

Fast and faithful — and still the wrong tool here, for the reason in [§Resolution](#resolution-the-actual-decimal-finding).

### doctr PARSeq — conversion failed, reproducibly

Both routes reach `torch.jit.trace` successfully (output shape `(1, 33, 127)`) and then fail identically:
```
File ".../coremltools/converters/mil/frontend/torch/ops.py", line 3066, in _int
  _cast(context, node, int, "int32")
File ".../coremltools/converters/mil/frontend/torch/ops.py", line 3048, in _cast
  res = mb.const(val=dtype(x.val), name=node.name)
TypeError: only 0-dimensional arrays can be converted to Python scalars
```
Unlike CRNN, setting doctr's official `model.exportable = True` (which returns raw `logits` and skips
postprocessing) **does not** fix it — the `aten::Int` nodes are inside PARSeq's autoregressive permuted
decode loop, not the postprocessor. Making this convert would require rewriting the decode loop with static
shapes. **Time-boxed and stopped here.** No Core ML model was produced; latency is **unmeasured**.

### TrOCR small printed — encoder alone already exceeds the budget

Encoder converts cleanly (22.0 M params, 384×384 DeiT, output `(1, 578, 384)`).

| Compute unit | Median (encoder only) | p90 | Max abs diff |
|---|---|---|---|
| ALL | **12.26 ms** | 13.13 ms | 5.18506 |
| CPU_AND_GPU | 14.42 ms | 14.58 ms | 0.13654 |
| CPU_ONLY | 22.39 ms | 23.36 ms | 2.33566 |

Two disqualifiers:
- **12.26 ms on an M1 Pro is the encoder only.** The 39.6 M-param decoder runs **once per generated token**,
  and was not converted or measured. On an A14, the total will be substantially worse than 12 ms.
- **The fp16 max-abs-diff of 5.19 on the ANE path** is large. There is no argmax to compare on raw hidden
  states, so this is not by itself proof of a wrong answer — but it flags fp16 numerics as a real risk for
  this architecture and would need checking end-to-end.

Also note `use_cache: false` in the shipped decoder config, and `preprocessor_config.json` resizes input to
**384×384** — for a wide, short digit band that is mostly padding.

### baidu/Unlimited-OCR — excluded from the on-device path

Excluded on four independent grounds, each sufficient:

1. **Remote code execution is mandatory.** `config.json` declares
   `"auto_map": {"AutoConfig": "modeling_unlimitedocr.UnlimitedOCRConfig", "AutoModel": "modeling_unlimitedocr.UnlimitedOCRForCausalLM"}`,
   the repo is tagged `custom_code`, and the model card's only `transformers` example passes
   `trust_remote_code=True`. The repo ships `modeling_unlimitedocr.py` (53,431 B),
   `modeling_deepseekv2.py` (90,162 B), `deepencoder.py` (38,008 B). None of this is convertible Python —
   it is a runtime dependency.
2. **VLM-scale MoE decoder.** `language_config` is a **DeepSeek-V2** causal LM: `n_routed_experts: 64`,
   `num_experts_per_tok: 6`, `vocab_size: 129280`, `max_position_embeddings: 32768`.
3. **Weights are 6,672,547,120 bytes (6.67 GB)** in bf16 — larger than total RAM on an iPhone 12 Pro Max (6 GB).
4. **Server runtime by design.** The card documents CUDA 12.9 / NVIDIA GPUs, `vllm/vllm-openai:unlimited-ocr`
   Docker images, and SGLang. The API is `model.infer(..., prompt='<image>document parsing.', max_length=32768)` —
   a long-horizon *document parsing* model, not a text-line recognizer.

It is also the wrong **task shape**: it generates a document transcription autoregressively. Asking it for
one 4-character reading at frame rate is a category error, quite apart from feasibility.

---

## Resolution: the actual decimal finding

This is the most decision-relevant thing the investigation turned up, and it is measured, not argued.

**Every candidate has `'.'` in its vocabulary.** doctr's vocab string contains `!"#$%&'()*+,-./`;
PP-OCRv5 has `'.'` at dict index 16160. **So decimal loss is not a vocabulary or model-capability problem.**
It is a *resolution* problem, and the candidates differ sharply in how much resolution they destroy before
the recognizer ever runs:

| Model | Fixed input | Horizontal timesteps | Pixels per timestep | Vertical resolution at the classifier |
|---|---|---|---|---|
| doctr CRNN / PARSeq | **32 × 128** (`input_shape: [3, 32, 128]`) | 32 (measured output `(1, 32, 127)`) | **4 px** | feature map measured **`(1, 512, 1, 32)`** — height collapsed to **1** |
| PP-OCRv5 mobile rec | **48 × 320** (`RecResizeImg: image_shape: [3, 48, 320]`) | 40 (measured output `(1, 40, 18385)`) | **8 px** | 48 px input height |
| Apple Vision | no fixed pre-resize exposed to the caller | n/a | n/a | operates on the supplied buffer |

The doctr family forcibly resamples the display band to **32 px tall and 128 px wide**, then collapses the
feature map to a **single row** with 4 px per output timestep. A decimal point that is 2–3 px wide is
sub-timestep. **These are the worst possible candidates for this specific failure**, which is why CRNN is
marked *reject for decimals* despite being the fastest and cleanest conversion in the table.

PP-OCRv5 is the best of the challengers on this axis — 1.5× the vertical resolution and 2× the horizontal
budget per timestep — which is the only real argument for keeping it around at all.

---

## Why the incumbent may already be the right hot path

Argued in both directions, because the honest answer is not unanimous.

### The case for keeping Apple Vision

- **The measured weakness is upstream of the recognizer.** The project's own diagnosis — encoded in
  `DAQPal/OCR/DecimalRescue.swift` — is that a decimal point is lost to thresholding, resampling and
  minimum-text-height filtering. The resolution table above **confirms this with numbers** rather than
  assuming it: two of the four challengers guarantee the loss by construction (32 px, 4 px/timestep,
  H collapsed to 1), and the third still hard-resizes to 48×320. **Swapping the recognizer does not
  recover a dot destroyed in preprocessing** — and the two doctr candidates would actively make it worse.
- **The vocabulary evidence closes the "maybe another model just reads dots better" hypothesis.** All
  candidates can emit `'.'`. None of them is failing for lack of the character. That removes the most
  plausible reason to expect a different model to fix this.
- **Vision costs zero bytes, zero conversion risk and zero maintenance.** The challengers cost 8.4 MB / 31.6 MB /
  43.8 MB of app binary, plus a conversion pipeline (opset upgrade → simplify → onnx2torch → trace → convert)
  that must be re-run and re-validated on every model or toolchain update. Two of five candidates failed to
  convert at all, and a third only converted after its stock forward pass was rewritten. That is the real,
  measured maintenance surface.
- **Vision is already tuned for this problem.** `DualPassVisionOCR` runs `.accurate` and `.fast` concurrently
  and merges, specifically because `.fast` rescues segment glyphs `.accurate` misses. A replacement engine
  starts from behind that.
- **The fix already exists and is model-independent.** `DecimalRescue` finds the dot geometrically on the
  canonical perspective-corrected ROI with binarization tuned for a small dim blob, and reports LOW
  confidence rather than guessing. `FormatValidator` owns grammar; the consensus layer refuses a 10× jump.
  That stack works identically no matter which recognizer produces the digits — which is precisely why
  recognizer choice is the *low*-leverage variable here.

### The case against — where Vision genuinely might be losing

- **Vision is a black box.** We cannot inspect or tune its internal resampling, its binarization, or its
  effective minimum stroke size. If Vision's internal pre-resize is the thing killing the dot, we have no
  lever. A converted model we own is fully inspectable and its input resolution is ours to choose — we could
  feed PP-OCRv5 a 48×320 crop of *just* the digit band at native sensor resolution.
- **`minimumTextHeight` is left at its default.** Neither `VisionOCR.swift` nor `ScreenFieldAnalyzer.swift`
  sets `request.minimumTextHeight` (verified by grep — the symbol appears nowhere in `DAQPal/`). Vision's
  default is a fraction of image height. On a small ROI this is probably benign, but it is an untested
  assumption sitting directly on top of the suspected failure mode, and it is **free to test**.
- **Vision has no format prior.** It cannot be told "this display is 3 digits with 1 decimal place". A model
  we own can be constrained at the decode step — CTC decoding restricted to `[0-9.\-]` would eliminate whole
  classes of error, and would make PP-OCRv5's 18,383-way softmax collapse to something far better matched.
- **A second, independent recognizer has value even if it is not better.** Two engines that disagree is
  itself a strong ambiguity signal — exactly the signal `.ambiguousDecimal` wants. That argues for
  PP-OCRv5 as an *arbiter*, not as a replacement.

### What evidence would settle it

Concrete, cheap, and none of it requires committing to a model:

1. **Instrument the existing pipeline first.** Log, on real captured frames, how often Vision returns
   `808` vs `80.8` vs nothing, alongside what `DecimalRescue` independently found. If `DecimalRescue`
   already finds the dot when Vision misses it, **the problem is solved and no model swap is justified.**
   This is the single highest-value measurement and it needs no new model at all.
2. **Ablate Vision's own inputs before blaming Vision.** Vary canonical ROI output size and
   `minimumTextHeight`, and re-run 1. If decimal recall moves with ROI scale, the loss is in *our*
   preprocessing, not in Vision.
3. **Only then, A/B PP-OCRv5 against Vision on the same canonical crops**, scoring *decimal-position
   accuracy*, not string accuracy. A model that is better at digits but no better at dots is not a fix.
4. **Measure both on the A14 device**, including whether the ANE compile failure reproduces there.

Steps 1 and 2 are strictly cheaper than step 3 and can make step 3 unnecessary. **Do them first.**

---

## Recommended deployment path

**1. Keep Apple Vision as the hot path. Do not replace it.**
Nothing measured here justifies displacing it. The two candidates that convert cleanly are either worse for
decimals by construction (doctr CRNN: 32 px, 4 px/timestep, H→1) or carry an 18,383-class CJK vocabulary and
a reproducible ANE compile failure (PP-OCRv5). The two remaining candidates do not convert or do not fit.

**2. Spend the next effort on measurement, not models.**
Run evidence step 1 above. The decisive unknown is not "which recognizer is best" but "does `DecimalRescue`
already catch what Vision drops?" — and that is answerable today with code that already exists.

**3. Retain PP-OCRv5 as a converted, on-disk *fallback / arbiter*, not as the hot path.**
It is the only challenger worth keeping: 8.37 MB fp16, converts reproducibly, **100 % argmax agreement**
with the ONNX reference on all three compute units, and it preserves the most resolution of any challenger.
Wire it behind the existing `OCREngine` protocol as a second opinion invoked **only** on
`.ambiguousDecimal` — never per-frame. Disagreement between two independent engines is a legitimate input
to the consensus layer, and this use costs nothing on the 99 % of frames that are unambiguous. Before
trusting it at all, resolve the ANE compile failure on device.

**4. Reject doctr CRNN, doctr PARSeq, TrOCR and Unlimited-OCR** for the reasons in the matrix.

**5. If a custom model is ever justified, the evidence points at training one, not adopting one.**
The real requirement is a *tiny* recognizer over a ~12-symbol alphabet (`0-9`, `.`, `-`) at high vertical
resolution, with the decimal as a first-class output. Every candidate evaluated here is a
general-purpose scene-text model carrying enormous irrelevant vocabulary — PP-OCRv5 spends 18,383 output
classes where ~12 are needed. That mismatch, not model quality, is the strongest argument that adoption is
the wrong move.

---

## What was NOT measured

Stated plainly, per the project's rule that a fabricated number is worse than no number.

- **All iPhone latency is unmeasured.** Every timing here is macOS on an M1 Pro. No Core ML model was run on
  `Daniphone`. Doing so requires adding a benchmark harness to the app target, and this task's scope
  explicitly forbids modifying app source or tests. **Do not treat the M1 Pro numbers as iPhone numbers** —
  the A14 Bionic is a materially slower part, and the ANE behaviour differs.
- **Apple Vision's own latency was not measured** in this task, on host or device. The incumbent row has no
  latency number for the same reason.
- **No accuracy comparison on real display images was performed.** Every parity number above is against a
  *random-tensor* reference and confirms only that conversion preserved the computation — it says **nothing**
  about which model reads a temperature gun better, and nothing at all about decimal recall.
- **TrOCR's decoder was never converted or benchmarked.** The 12.26 ms figure is the encoder, one pass.
- **PARSeq has no latency number** because no Core ML model was produced.
- **Whether the PP-OCRv5 ANE compile failure reproduces on A14 is unmeasured.**
- **Int8/palettized quantization was not attempted** for any candidate. All sizes are fp16.

---

## Reproducing this

Scratch artifacts (venv, scripts, converted `.mlpackage`s) are under:
`/private/tmp/claude-501/-Users-danielliu-Documents-DAQPal/ecf53ea7-939c-460d-99c5-fccf85028f1a/scratchpad/models/`

```bash
python3 -m venv venv                      # PEP 668: system pip is blocked, venv is required
./venv/bin/pip install coremltools onnx onnxsim onnxruntime torch onnx2torch python-doctr transformers

./venv/bin/python convert_ppocr.py        # PP-OCRv5: ONNX -> opset17 -> simplify -> torch -> Core ML
./venv/bin/python bench.py                # PP-OCRv5 parity + latency across compute units
./venv/bin/python convert_crnn2.py        # doctr CRNN, static-reshape wrapper
./venv/bin/python convert_parseq2.py      # doctr PARSeq — expected to FAIL at aten::Int
./venv/bin/python convert_trocr.py        # TrOCR encoder only
```

Model facts were taken from the live HuggingFace API (all five returned HTTP 200):

```bash
curl -sS "https://huggingface.co/api/models/<id>"
curl -sS "https://huggingface.co/api/models/<id>/tree/main"
```
