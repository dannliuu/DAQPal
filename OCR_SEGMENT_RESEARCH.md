# Segment-Aware Decimal & Format Recognition — Research Findings

**Date:** 2026-08-02
**Question:** what does the literature do about seven-segment decimal/format recognition, what lighting
conditions has it actually been evaluated under, which algorithmic and ML/hysteresis solutions exist,
and which of them can be integrated into iOS *performantly*.

**Target device (measured, not assumed).** User's IR thermometer, photographed 2026-08-02:
reflective seven-segment LCD, dark segments on light background, **Michelson contrast 0.20**
(segments ~77 luma, background ~117), dedicated decimal-point segment, two simultaneous readings
(main + `MAX`), plus `°F` / `SCAN` annunciators. Every threshold in DAQPal to date was tuned against
synthetic renders of substantially higher contrast, so this device is harder than anything the
project has tested.

---

## 1. The finding that matters most: don't use connected components

DAQPal's `DecimalRescue` labels connected components and calls a tall component a digit. On a true
segment face the segments **do not touch** — measured: 21 components for a clean `80.8`, none of
them a digit — so digit counting fails and the decimal's *position* cannot be derived. That is the
open limitation recorded in `ARCHITECTURE.md`.

**SSOCR** (Seven Segment Optical Character Recognition, Auerswald) solves this without ML and
without connected components:

- **Digit segmentation by column scanning.** Scan columns left→right; a column containing any
  foreground pixel starts a digit, a column of pure background ends it. Vertical segmentation
  works the same way but **explicitly permits interior gaps**, because "some seven-segment digits
  have unset middle segments."
- That single design choice is the fix for DAQPal's failure. A `0` on a DSEG7 face splits into two
  components under connected-component labeling (no middle segment) — and it was measured doing
  exactly that, producing a *wrong* decimal position. Column scanning never splits it, because
  every column of that glyph contains ink somewhere.
- **Decimal detection by size ratio, not by counting.** SSOCR classifies a blob as a decimal point
  when it is "significantly smaller in both width and height relative to the largest digit."
  Minus sign: height < ½ its width. A `1`: width < ¼ its height.
- Recognition itself is scanline segment sampling: a vertical scan at the digit's horizontal centre
  detects the three horizontal segments (thirds), two horizontal scanlines at ¼ and ¾ height detect
  the left/right verticals. **DAQPal already has this** — `SevenSegmentSampler`.
- SSOCR states plainly it uses "neither machine learning nor artificial intelligence."

**Stated limitations, which apply to us:** single row of digits only (our device has two rows —
main and `MAX`, so they must be split into rows first), and it degrades on skew, "particularly when
decimal points sit close to digits."

The critical inversion for DAQPal: **the dot was never the hard part.** On this display the decimal
is a dedicated segment — a chunky, well-separated square, one of the easiest blobs on the panel.
What fails is establishing the digit cells around it. SSOCR gets position from *ordering by column*
rather than from counting components, which is exactly the information that survives on a segment face.

---

## 2. Lighting: what has actually been evaluated

Lighting is the most-cited failure mode and the least-solved.

| Dataset / study | Lighting coverage |
|---|---|
| **YUVA EB** (energy meters) | 169 images, ~50 daylight + ~49 night; tilt and blur included |
| **7-Segment Industrial Digits** (Kaggle) | vibration, **reflections**, lighting variation, imperfect camera angles |
| Blood-glucose / BP monitor study | camera planar to device and **"lighting reflections were minimized"** — the hard case was deliberately excluded |
| Classical pipeline (numeral-recognition paper) | **79% recognition** across "wide variation in illumination and angular tilt" |

Two honest conclusions:

1. **Glare remains unsolved, including for deep learning.** The literature reports that models
   "perform well on 7-segment datasets but may struggle with glare conditions," and that "poor
   contrast and the abundance of specular highlights on the display surface degrade images in an
   unpredictable way as the camera is moved." That last clause describes a handheld phone
   against a reflective LCD exactly.
2. **A well-regarded medical study sidestepped it** by keeping the camera planar and minimizing
   reflections. Reported accuracy from such a setup does not transfer to handheld field use, and
   should not be quoted as if it does.

**Specular-highlight removal** research exists (e.g. tensor low-rank + sparse decomposition) but the
strongest methods use **polarimetric cues** — they need a polarization camera. Not available on
iPhone; excluded.

The practical mitigations that *are* available are capture-side, not algorithmic: shoot slightly
off-axis so the specular lobe misses the lens, and rely on multi-frame temporal fusion so a frame
ruined by a highlight is outvoted rather than trusted.

---

## 3. Binarization for low contrast — the targeted upgrade

This is where DAQPal's measured 0.20 contrast bites, and the literature is unusually concrete.

- **Sauvola > Niblack** for local thresholding generally, but Sauvola is "way slower than other
  methods" in naive form.
- **Integral images remove the cost.** With an integral image, computing local mean/standard
  deviation over a window becomes **independent of window size**; implementations "achieve speed
  close to Otsu's" while computing identical Sauvola thresholds. Box filtering reduces to three
  additions per pixel.
- **A low-contrast Sauvola variant exists and is precisely on point:** replace the local mean with a
  **"maximum mean"**, because "when the contrast in the local neighborhood is quite low, the Sauvola
  threshold goes below the mean value," which is what lets it strip relatively dark background.
- **ISauvola** auto-tunes its parameters from local image contrast rather than fixed constants.
- SSOCR's practical equivalents: `dynamic_threshold W H` (local adaptive) and `gray_stretch T1 T2`
  (project luminance interval [T1,T2] onto [0,255]) — a contrast-stretch *before* thresholding.

**DAQPal already ships the cheap half of this.** `DecimalRescue` uses a Bradley-style local-mean
threshold over an integral image, which is the same family. The upgrade path is narrow and
well-defined: add Sauvola's standard-deviation term (already affordable — the same integral-image
trick gives variance via a second integral of squares), and evaluate the maximum-mean variant
against the 0.20-contrast case specifically.

---

## 4. Machine learning: strong accuracy, wrong shape for our hot path

Recent results are genuinely good:

| Approach | Reported result |
|---|---|
| YOLOv8 (seven-segment detection+recognition) | **99.28%** accuracy, **641 ms** inference, 11 MB model |
| YOLOv8n @320 | **129.79 FPS**; YOLOv8l @640 best precision 0.979 mAP@50 |
| INT8-quantized YOLOv8-small (PTQ) | called optimal for **mobile** health deployment |
| Inception-V3-inspired CNN | 99.49% train / 99.13% val |
| Pipeline comparison | **DBNet** best for detection; **PARSeq** best for seven-segment *recognition* |

Three observations before anyone reaches for these:

1. **PARSeq appearing as best-in-class is notable and awkward** — DAQPal already evaluated
   `rrainn/doctr-parseq` and **rejected it**, with a reproduced Core ML conversion failure
   (`TypeError` at `coremltools/.../ops.py:3048`, two independent routes). The literature's best
   recognizer is the one we measured as unshippable. That is a real tension to revisit if the
   classical path stalls, not a reason to re-attempt conversion blindly.
2. **Training data is the blocker, and it is a stated project constraint.** The user's position
   stands: *"I want to avoid training for now as I don't have the data sets to do so."* Published
   datasets are small (169 images; 2,147 expanded to 3,649) and none of them contain *this*
   thermometer under *this* lighting.
3. **The reported accuracies are digit accuracies, not decimal-position accuracies.** None of the
   surveyed work isolates decimal-point placement as its own metric, which is the failure mode that
   matters here. A 99% digit model that drops the separator still yields `808` for `80.8`.

**Where ML is genuinely attractive:** a *tiny* per-cell classifier (10 classes + blank, ~20×32 input)
once cells are already segmented. That is a Core ML model of a few hundred KB, ANE-friendly, and its
training set is generatable from our own `SyntheticDisplayGenerator` plus harvested field crops —
`TrainingDataHarvester` already exists for exactly this. It is a Phase-2 option, not a hot-path
dependency.

---

## 5. Temporal / hysteresis

Direct literature on multi-frame voting for meter reading is thin — the search surfaced mostly video
fusion and stabilization work, not digit-specific voting. The transferable ideas:

- Short-range temporal consistency to stabilize predictions across frames.
- Explicitly modelled **"time hysteresis"** — networks that control the influence of historical
  quality on the current estimate rather than treating each frame independently.

**DAQPal is ahead of the surveyed literature here**, which is worth saying plainly. `TemporalConsensus`
already implements a power-of-ten guard that treats a 10× jump explainable by a separator moving as a
*decimal event* requiring corroboration, plus format-prior migration and an explicit ambiguous state.
Nothing found in the survey does decimal-aware temporal validation. The gap is not the algorithm —
it is that the consensus layer is currently fed by a rescue stage that cannot read segment faces.

---

## 6. iOS integration assessment

| Technique | iOS path | Verdict |
|---|---|---|
| Integral image + local-mean threshold | `vImage` / Accelerate (SIMD); already implemented in `DecimalRescue` | **Hot path.** Window-size-independent cost |
| Sauvola (mean + std-dev) | Second integral image of squares; same Accelerate primitives | **Hot path.** Adds one pass, no per-pixel multiply in the window |
| Contrast stretch (`gray_stretch`) | `vImage` histogram / `CIColorControls` | **Hot path.** Trivial cost |
| Column-scan digit segmentation | Plain Swift over a decimated luma grid | **Hot path.** O(W·H) once, on an already-cropped canonical ROI |
| Scanline segment sampling | Already shipping (`SevenSegmentSampler`) | **Hot path** |
| Global threshold on GPU | `MPSImageThresholdBinary` (`src > t ? max : 0`) | **Not useful** — global only; our problem is *local* illumination |
| Specular removal via polarimetry | — | **Reject.** Requires polarization hardware |
| YOLOv8 detector | Core ML, INT8 PTQ | **Fallback at best.** 641 ms reported; 11 MB; and detection is not our weak stage |
| Tiny per-cell CNN | Core ML, ANE | **Phase 2**, gated on the user's dataset constraint |
| PARSeq recognizer | — | **Rejected**, measured conversion failure (see §4) |

The whole classical chain — stretch → adaptive threshold → column-scan segmentation → scanline
sampling → size-ratio decimal detection — is Accelerate-friendly integer/float work on a small
canonical crop, not a full frame. It belongs in the existing `.analysis` metrics stage, at
revalidation cadence rather than per frame.

---

## 7. Recommendation for DAQPal

**Do the classical path first, and expect it to be sufficient.** Specifically:

1. **Replace connected-component digit detection with column-scan cell segmentation** in the
   segment-face path, permitting interior gaps. This is the single change that unblocks the user's
   thermometer, and it needs no training data.
2. **Split rows before segmenting** — the target device shows main + `MAX` simultaneously, and SSOCR's
   documented limitation is that its segmentation "works for a single row of digits only."
3. **Take decimal position from column ORDER, not component counting**, and classify the dot by
   size ratio against the largest cell (SSOCR's rule). Keep the existing behaviour of reporting a
   presence with *no* position rather than a guessed one when cells are untrustworthy.
4. **Add Sauvola's std-dev term and evaluate the low-contrast "maximum mean" variant** against a
   0.20-Michelson fixture built from the user's own photo.
5. **Feed the result into the existing `TemporalConsensus`**, which is already stronger than anything
   surveyed.
6. **Keep ML as Phase 2**, scoped to a tiny per-cell classifier trained on harvested field crops —
   not a detector, and not a sequence model.

**Honest caveat on all of the above.** Every accuracy figure in this document comes from someone
else's dataset and someone else's device. The one number measured on the actual target is the 0.20
contrast. Nothing here should be treated as a prediction of how DAQPal will perform on this
thermometer until a real recording exists to test against.

---

## Sources

- [SSOCR — Seven Segment Optical Character Recognition](https://www.unix-ag.uni-kl.de/~auerswal/ssocr/)
- [Detecting and recognizing seven segment digits using a deep learning approach (ITM Web Conf. 2024)](https://www.itm-conferences.org/articles/itmconf/pdf/2024/06/itmconf_amict2023_01007.pdf)
- [Automated Detection and Recognition of Seven-Segment Digits from Electric Meters (VFAST VTSE)](https://vfast.org/journals/index.php/VTSE/article/view/1923)
- [Optical character recognition system for seven segment display images of measuring instruments](https://www.researchgate.net/publication/261501154_Optical_character_recognition_system_for_seven_segment_display_images_of_measuring_instruments)
- [Optical numeral recognition algorithm for seven segment display](https://www.researchgate.net/publication/310501237_Optical_numeral_recognition_algorithm_for_seven_segment_display)
- [Real-Time Seven Segment Display Detection and Recognition Online System Using CNN](https://link.springer.com/chapter/10.1007/978-3-030-57115-3_5)
- [Text detection and recognition in raw image dataset of seven segment digital energy meter display (YUVA EB)](https://www.sciencedirect.com/science/article/pii/S235248471930174X)
- [7-Segment Industrial Digits Dataset (Kaggle)](https://www.kaggle.com/datasets/thearshiya/7-segment-industrial-digits-dataset)
- [Automated method for detecting and reading seven-segment digits from blood glucose metres and blood pressure monitors](https://www.tandfonline.com/doi/full/10.1080/03091902.2019.1673844)
- [Efficient implementation of local adaptive thresholding techniques using integral images](https://www.researchgate.net/publication/221253734_Efficient_implementation_of_local_adaptive_thresholding_techniques_using_integral_images)
- [Modified Sauvola binarization for degraded document images](https://www.sciencedirect.com/science/article/abs/pii/S0952197620301159)
- [Robust Combined Binarization of Non-Uniformly Illuminated Document Images (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC7287981/)
- [A New Local Adaptive Thresholding Technique in Binarization (arXiv)](https://arxiv.org/pdf/1201.5227)
- [Highlight Specular Reflection Separation using Polarimetric Cues (arXiv)](https://arxiv.org/pdf/2207.03543)
- [Metal Performance Shaders — Apple Developer Documentation](https://developer.apple.com/documentation/metalperformanceshaders)
- [iOS Image Processing with the Accelerate Framework](https://www.invasivecode.com/weblog/ios-image-processing-with-the-accelerate/)
</content>
