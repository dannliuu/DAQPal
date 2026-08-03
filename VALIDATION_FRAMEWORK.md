# DAQPal — Validation & Stress-Testing Framework

Answers one question quantitatively:

> Under what combinations of viewing angle, perspective, contrast, lighting,
> motion, display type and image quality does DAQPal's display detection, digit
> localization, tracking and OCR remain reliable — and exactly where does it fail?

---

## Phase 0 — Repository audit

### Baseline, actually measured

Run immediately before any change in this effort, Debug, iPhone 17 Pro Simulator,
serial (`-parallel-testing-enabled NO`):

```
733 passed   0 failed   2 skipped
```

This is the regression baseline. Two skips are pre-existing.

### What already existed (and is therefore REUSED, not rebuilt)

The brief asked for a great deal that this repository already has. Building it
again would have produced competing architectures, which is explicitly out of
scope. Audit result:

| Capability the brief asks for | Already exists | Decision |
|---|---|---|
| Yaw / pitch / roll geometry | `DisplayPose3D` — true 3-D pose, `R = Rz(roll)·Ry(yaw)·Rx(pitch)`, genuine trapezoids, `projectedQuad(panelSize:)` gives ground truth | Reuse as the sweep's ground-truth source |
| Motion trajectories | `DemoMotion` (steady, yaw, pitch, roll, tumble, bounce, scale, driftDiagonal, stress) + `PoseTrajectory` | Reuse |
| Image degradation | `RenderDegradation` — occlusion, motion blur, per-pixel noise, brightness; all deterministic hashes, no random source | **Extend** with contrast, gamma, glare, illumination gradient, colour temperature, salt-and-pepper, defocus |
| OCR benchmark + report | `RecognitionBenchmark`, `BenchmarkReport`, `BenchmarkCaseResult`, `formattedTable()` | Reuse; add a failure taxonomy it lacks |
| Synthetic display corpus | `SyntheticDisplayGenerator`, DSEG7 segment font fixtures, `SyntheticDisplayRenderer` | Reuse |
| Per-stage instrumentation | `PipelineMetrics` — ring-buffered, pull-based, p95/p99, stages `.capture .tracking .detection .analysis .ocr .endToEnd` | Reuse for the performance report |
| Video → frames | `FixtureFrameSource` (AVAssetReader), `VideoImportModel` | Reuse for corpus ingestion |
| Perspective rectification | `Homography` (DLT, partial pivoting, nil on singular), `PerspectiveNormalizer` | Reuse |
| Display detection / tracking | `ScreenCandidateDetector`, `QuadTracker`, `ScreenLockPipeline`, `TrackVerifier`, `MagneticSnapEngine` | Reuse; measure, do not modify |
| Digit selection + CSV columns | `NumberBandSplitter`, `WindowFieldAnalyzer`, `SubFieldOrigin`, `WindowSubFieldLayer` | **Untouched** — complete and verified |
| Debug overlay | `PipelineDebugOverlay` (stage rates/latency/drop) | Extend pattern for the coordinate chain |

### What was genuinely missing

1. **A failure taxonomy that separates decimal errors from digit errors.**
   `BenchmarkReport` scores exact-match, which is the right top-line number but
   hides the distinction this project keeps getting bitten by: reading `808` when
   the display shows `80.8` has every digit correct and is off by a factor of ten,
   while reading `809` is a character error. Different causes, different fixes,
   very different consequences for recorded data — the first still looks
   plausible in a CSV.
2. A shared measurement vocabulary so sweeps are comparable to each other and to
   future OCR engines.
3. Geometry scoring against ground truth (IoU, corner error, centre error).
4. Contrast / gamma / glare / illumination / colour degradation axes.
5. A licence-gated corpus manifest and ingestion path.
6. Automated regression detection against a stored baseline.
7. Coordinate-chain instrumentation for physical-hardware validation.

### What was added

- `DAQPalTests/Support/ValidationHarness.swift` — the shared contract:
  `ReadingVerdict`, `ReadingComparison`, `GeometryError`, `ValidationOutcome`,
  `ValidationReport`, `SeededGenerator`.
- Sweeps, corpus, regression checker and debug overlay — see the results section.

### What was deliberately left untouched

The digit-selection and CSV-column features, the OCR engines themselves, the
tracking pipeline's cadence design, and the ROI gesture path. The brief forbids
duplicating the first two; the last two are measured by this framework rather
than changed by it. In particular `ScreenLockPipeline`'s deliberate choice not to
re-run detection every frame is left alone — the sweeps measure it.

---

## The measurement contract

Everything reports through `ValidationHarness.swift`.

### `ReadingVerdict` — why the taxonomy matters

| verdict | meaning | consequence |
|---|---|---|
| `exact` | digits and decimal both right | — |
| `decimalMissing` | all digits right, point absent (`80.8` → `808`) | **silent 10× error** |
| `decimalSpurious` | all digits right, point invented (`808` → `80.8`) | silent 10× error |
| `decimalMisplaced` | all digits right, point in wrong position | silent 10× error |
| `digitError` | at least one digit wrong | usually visible as implausible |
| `notDetected` | nothing produced | visible |

The three decimal verdicts are reported as their own rate. A framework that
collapsed them into one accuracy number would hide the exact failure that
motivated this work.

Comparison is on the written string, not a parsed `Double`: `08` and `8` parse
identically but are different recognitions, and leading-zero handling is itself
under test.

### `GeometryError`

IoU is computed on the **axis-aligned bounding boxes**, not the quads. That is a
deliberate choice: exact polygon intersection is what a detector's own scoring
would use, but the consumers here are Vision's `regionOfInterest` and the crop
path, both axis-aligned — so box IoU is what actually predicts whether
recognition sees the glyphs. Corner error is recorded alongside it, and that
does capture keystone disagreement.

### Determinism

No sweep touches `Date()`, `Double.random` or `arc4random`. Randomized sampling
uses `SeededGenerator` (splitmix64) with the seed recorded in the test, so any
failing case replays from its id alone. `ValidationOutcome.id` fully determines
its input.

---

## Phase 1 — Physical IR-gun validation

**No physical hardware was tested. Nothing in this document claims otherwise.**

Validating that digit boxes align with a real display requires the instrument in
hand and a person aiming it. What is delivered is the instrumentation and the
procedure: a DEBUG-only coordinate-chain overlay and `HARDWARE_VALIDATION.md`,
a manual protocol with a table of metrics for the tester to fill in
(bounding-box centre and edge error, digit spacing consistency, frame-to-frame
jitter, tracking loss rate, reacquisition time, OCR and decimal accuracy).

The overlay is built under the constraint that `AppState.lockedTarget` and
`liveReadings` are rewritten at frame rate, so every read of them is pushed into
the smallest leaf view — the same isolation `FieldSelectionOverlay` and
`ROISelectionOverlay` already use. This project has a documented drag-latency
regression caused by exactly that mistake (ARCHITECTURE.md §2), and an
instrumentation overlay that reintroduced it would corrupt the measurements it
exists to take.

---

## Phase 7 — Real-world video corpus, and what is not built

**No scraper was built, and none will be.** The brief's own constraints 8–10
rule out bypassing platform protections, and YouTube's terms prohibit automated
downloading. Building one would also be pointless for a validation corpus:
material with unclear reuse rights cannot be committed as a regression fixture.

What is built instead:

- **A licence-gated manifest.** Licence is a required, non-optional field with an
  explicit enum. An entry whose licence is `unknown` is **rejected by validation
  rather than ingested**, enforced by test. The corpus cannot silently accumulate
  material with unclear rights.
- **A pluggable provider protocol** so acquisition sources can be added without
  coupling to the OCR pipeline. One provider ships: local files the user already
  has. The conformance point exists for others; no implementation is supplied for
  any platform that prohibits automated download.
- **Frame sampling** over `FixtureFrameSource`, configurable rate, so corpus
  construction does not decode every frame.
- **Normalized ground-truth annotations** (display quad, digit boxes, decimal
  location, truth value) that survive a resolution change.

Acceptable sources, in the order the manifest prefers them: public-domain and
openly-licensed datasets; explicitly redistributable video; official APIs where
one exists and permits it; and files you supply yourself. Practical starting
points are Wikimedia Commons and openly-licensed teardown/repair footage, both of
which carry machine-readable licence metadata.

Unverifiable metadata stays `nil`. Nothing is guessed.

---

## Results

See RESULTS section appended after the sweeps ran. Every number there was
measured, not estimated.
