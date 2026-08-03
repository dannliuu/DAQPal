# WS-B — OCR Accuracy: Read It Right

Read `docs/plans/MASTER_PLAN.md` first (protocol §2, ownership §7, decisions §3). Status is reported ONLY to the master ledger (§5) — never restated here.

**Mission**: every displayed number becomes either the correct structured value or an honest rejection. "Rejected" is acceptable; "wrong and accepted" is the failure (spec principle; DoD-2).

## Invariants

- **Zero-refusal is a defect, not a success.** The device benchmark's `refusedAmbiguousDecimal = 0%` while 9.7% of values were silently wrong by 10× is the exact anti-pattern; every fix must prefer refusal over guessing.
- Synthetic results are labeled synthetic, always (D6). Never quote them as instrument accuracy.
- Full suite green at session end (baseline in MASTER_PLAN §5, never a hardcoded number); `DecimalRescueTests` (23), `DecimalBenchmarkTests`, corpus tests all stay green.
- **A fused-confidence floor is mandatory.** Audit 2026-08-03: `ConfidenceEngine.swift:117` multiplies five factors into `finalConfidence`, but the rejection ladder (`:119-145`) gates only the raw `ocr` term, and `:141` multiplies again *after* the last check. A reading can export `accepted: true` at ≈0.089 confidence. No WS-B change may ship that widens this hole; closing it is task B0.
- Engine decisions are settled (D1: Vision hot path; D3: no training) — work within them.

## Owned files

Per master §7: `DAQPal/OCR/*`, `DAQPal/Processing/*`, `DAQPal/Corpus/*`, `DAQPal/Data/*`, `DAQPalTests/Fixtures/`, `DAQPalTests/Baselines/`, matching tests. Shared files only at gates.

## Tasks

### B1 — Wire `DecimalRescue` into `MeasurementProcessor`
The module is written, unit-tested (23/23), measured working (`"80.8"` → position 2 @ 0.97 confidence) — and has **zero call sites** (grep-verified 2026-08-02; re-confirmed by the 2026-08-03 audit: every non-self grep hit is a comment). The +506-line FormatValidator rewrite shipped alongside it changed the device benchmark by exactly nothing (byte-identical re-run).
- Insertion point: post-OCR, pre-acceptance — rescue runs when (a) OCR found no separator, (b) separator confidence is low, or (c) the format prior expects a decimal the text lacks.
- Fusion contract (per ARCHITECTURE's design intent): rescue **corroborates or vetoes** via `ConfidenceEngine` — it never solely authors a value. Its `confidentAbsence` ceiling discipline (0.5 between-digits cap) carries over.
- **Evidence gate**: integration tests (rescue fires on the designed triggers, never on clean reads); 65/72 currently-correct benchmark cases unchanged; suite green.

### B2 — Feed `DisplayFormatInference` into `TemporalConsensus`
The format prior is passed as literally `formatPrior: nil,` at `MeasurementProcessor.swift:454` (audit-confirmed verbatim 2026-08-03; `DisplayFormatInference` has zero live-path references).
- Wire the inferred format as the consensus prior; prior resolves ambiguous decimal position; a *conflicting* prior forces refusal, never a silent override.
- **Evidence gate**: unit tests — ambiguous stream + correct prior → resolved; ambiguous stream + wrong prior → refused; no prior → current behavior.

### B3 — Leading-separator (`.5`) fix + refusal path
All 7 device-benchmark failures are one class: leading decimal, no integer digit. Vision transcribes the dot as a bullet-like glyph; the tokenizer only knows `.`/`,`, discards it, parses bare `5`, format-fills to `5.0` — silent 10× error at 0.75 confidence.
- Tokenizer: a non-alphanumeric glyph in separator position is separator *evidence*, not junk.
- Add the ambiguous-decimal trigger for the bare-integer-after-discarded-glyph pattern → refusal when unresolved (B1/B2 may then resolve it).
- **Evidence gate**: `DecimalBenchmarkTests` re-run `[sim]`: power-of-ten errors 7/72 → 0 wrong (refusals permitted, counted separately); device re-run at next device day. Leading-separator cases added to `DecimalIntegrityTests`.

### B4 — Fix, then wire, `SegmentCellScanner` (audit-resolved 2026-08-03: it IS a second orphan, with failing tests)
The pre-flight audit answered B4's open questions. Checklist state: gap-tolerant column scan **implemented** (`SegmentCellScanner.swift:288-313` — column ink accumulated over the full band height, interior gaps don't split digits); decimal-by-size **implemented** (`:316` tallest-cell reference, `:398-427` classification, `:494-499`); row-splitting **partial** (`:216-264` — bands→rows mechanism exists; two-row "MAX"-legend case not fully validated); wiring **MISSING** — all 6 production grep hits are self-references; nothing calls it.

Work, in order:
1. **Fix the 4 failing tests first** (failing in the audited suite run): `SegmentCellScannerTests.swift:87` (nil decimal positions for DSEG7 "0.001"/"99.9"/"100.0"), `:131` (wrong position on moderate-inverted preset "12.345"/"100.0"), `:173` (DSEG7 "99.9" reconstructed as "000" through `SevenSegmentSampler`), `:200` (proportional face, wrong position). These are decimal-position/reconstruction logic bugs in the newest commit — the suite cannot go green without them.
2. Complete row-splitting validation for the two-row (main + "MAX") layout.
3. Wire it into the recognition path for segment faces (`SevenSegmentSampler` handoff; audit points at the `MeasurementProcessor.swift:515-521` vicinity) — a *third* orphan outcome is unacceptable.
- **Evidence gate**: all `SegmentCellScannerTests` green; the "80.8" CC-failure fixture yields 3 digit cells + decimal end-to-end; a segment-face read flows through the live pipeline in a corpus test.

### B5 — Low-contrast binarization + real-photo fixture
Every threshold to date was tuned on synthetic renders of much higher contrast than the real target (IR gun: Michelson 0.20 — segments ~77 luma on ~117 background).
- Build a fixture set from the real IR-gun photo at native contrast; add contrast-0.20 rows to the degradation corpus.
- Upgrade binarization: add the Sauvola std-dev term to the existing Bradley-style adaptive pass (integral-images so window-size stays cheap); evaluate the "maximum mean" low-contrast variant against the new fixture.
- **Evidence gate**: `DegradationRenderTests`/corpus sweep at 0.20 contrast passing for scanner+rescue; before/after comparison recorded.

### B6 — `TemporalConsensus` hardening
- Anchor currently forms from only 2 uncorroborated frames — raise the corroboration requirement (design the exact rule; record it).
- `.ambiguous` can deadlock indefinitely — add an escape: bounded window → refusal + re-inference request.
- European decimal-comma: handle per the G1 shared grammar (joint with WS-A's A4).
- **Evidence gate**: `TemporalConsensusTests` cover anchor-formation, deadlock-escape, comma cases.

### B7 — Real fixtures + first recorded baselines
The baselines directory holds only a self-test fixture; `RecognitionPipelineTests` skips for lack of real footage; VALIDATION_FRAMEWORK's "RESULTS" section is empty promise (R9).
- Pre-device-day: record synthetic corpus sweeps as explicitly-synthetic `.baseline` files (single-name re-record mechanism per BASELINES.md — blanket re-record is rejected by design).
- At device day: record `dmm_NNN.mov` + ground-truth CSV per `DAQPalTests/Fixtures/README.md` (10–30s, ≥1 decimal change, ideally a step change: "12.000→13.001 must survive"); IR-gun set at multiple angles/lighting including worst-case contrast.
- After: unskip `RecognitionPipelineTests`; report `ReadingVerdict` taxonomy rates (exact/decimalMissing/decimalSpurious/decimalMisplaced/digitError/notDetected — never collapsed into one number) to the master ledger.
- **Evidence gate**: DoD-2's evidence base exists; first real accepted-measurement accuracy number, provenance-tagged.

## Device-day requests

- Fixture recording session (B7 shot list).
- `DecimalBenchmarkTests` re-run on device in **Release** after B1–B3.
- Live IR-gun end-to-end session (the actual DoD-2 user scenario).

## Non-goals

OCR engine replacement or PP-OCRv5 device benchmarking (D1 governs), model training (D3), tracking changes (WS-A), cadence/performance tuning (WS-C).
