# Deliverable K — Next Ultracode Session Prompt

Two prompts. **Run K0 first** (mechanical, unblocks everything). **K1 is the real work.**

Rationale for this order: K1's evidence gate requires a green suite, and the suite cannot go green until the 4 `SegmentCellScannerTests` failures are fixed. Running K1 first would force the agent to violate its own exit condition — the exact blocker (E1) this audit found in the existing plan.

---

## K0 — Unblock the plan set (mechanical, ~1 session)

```
ultracode

TASK: M0 — commit the baseline and make the plan set self-consistent. Workstream: none (this is the M0 milestone, which precedes all workstream fan-out).

PREREQUISITES: none. This is the first session.

CONTEXT: docs/plans/EXECUTABILITY_AUDIT.md is an audit of the plan set at commit e757219.
It found that no workstream session can currently satisfy its own exit invariant. This
session fixes that. Read the audit's Verdict and Deliverable I before doing anything.

ALLOWED FILES:
  - Everything in the working tree, for the commit step only (M0.1).
  - docs/plans/MASTER_PLAN.md, ws-a-tracking.md, ws-b-ocr-accuracy.md, ws-c-performance.md
  - DAQPal.xcodeproj/xcshareddata/  (to share the scheme)

FORBIDDEN FILES:
  - Any DAQPal/**.swift file. This session changes NO application code.
  - Any legacy markdown at repo root (D8 freeze).

IMPLEMENTATION TASKS, in order:

1. Commit the working tree. It is 23 modified files (+4,956 lines) and 58 untracked paths
   including TrackVerifier.swift, TemporalConsensus.swift, DecimalRescue.swift and
   AppearanceSentinel.swift — DoD-1's entire evidence base is currently unversioned.
   Split into reviewable commits (tracking / OCR / UI+instrumentation / tests) but do NOT
   gate on human review.
   BEFORE COMMITTING: ARCHITECTURE.md, IMPLEMENTATION_NOTES.md, PROGRESS.md and
   intelligent_screen_selection_tracking_ocr_spec.md have uncommitted edits, and D8
   declares them frozen read-only. Decide explicitly: commit them with a note in the
   ledger explaining that the edits predate D8, or revert them. Do not commit silently.

2. Share the Xcode scheme into version control. `xcodebuild -list` shows exactly one
   scheme ("DAQPal") and it is not tracked, so a fresh clone has no schemes at all.

3. Apply every markdown edit in EXECUTABILITY_AUDIT.md Deliverable I, verbatim.
   These fix: the ≥733/857 contradiction, the missing test command, the two Authority Map
   path errors, the CLAUDE.md misclassification, the unowned-file default rule, the
   milestone ordering, and the WS-A invariant that has no runnable procedure.

4. Do NOT fix any failing test in this session. That is K1.

TESTS: run the suite before and after to prove no code changed behaviour:
  xcodebuild test -scheme DAQPal \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -resultBundlePath /tmp/daqpal_m0.xcresult -parallel-testing-enabled NO
  Read counts via: xcrun xcresulttool get test-results tests --format json
  NEVER grep stdout for counts — serial and parallel runners print different formats and
  this project has miscounted before.

EVIDENCE REQUIRED:
  - Commit SHAs for each commit made.
  - Before/after test counts from xcresulttool (expected: identical, 857/5/2).
  - Confirmation that `git status --porcelain` is empty for DAQPal/ and DAQPalTests/.

LEDGER UPDATE (MASTER_PLAN.md §5 session log): one row with date, "M0 baseline commit",
what changed, and the test count with its [sim iPhone 16 Pro, Debug, serial] tag.

DEFINITION OF DONE:
  - Working tree clean.
  - Scheme in version control; the §2 command runs from a fresh clone.
  - All Deliverable I edits applied.
  - Test count unchanged and recorded in §5.

STOP AND REPORT rather than proceeding if:
  - Committing would overwrite work you cannot account for.
  - A Deliverable I edit contradicts something you find in the code — report the conflict,
    do not silently pick one.
  - You are tempted to fix a failing test. That is out of scope; report and stop.
```

---

## K1 — B0 + the confidence floor (the highest-value session in the plan)

```
ultracode

TASK: B0 — make the suite green and close the accepted-at-low-confidence hole.
Workstream: WS-B (OCR accuracy).

PREREQUISITES: K0 complete (working tree committed, plan set self-consistent, scheme shared).

WHY THIS TASK EXISTS: two independent problems, both blocking.
 (a) 4 SegmentCellScannerTests fail, so no workstream can satisfy "full suite green at
     session end". Every other session is blocked until this is fixed.
 (b) DAQPal's core promise is "when it is not confident, it refuses". The accept predicate
     currently has no floor on fused confidence, so it exports wrong readings as accepted.
     This is a live violation of the product's central claim.

READ FIRST (do not skip):
  - docs/plans/EXECUTABILITY_AUDIT.md — Verdict, Deliverable C, Deliverable D
  - DAQPal/OCR/SegmentCellScanner.swift (whole file; the row-band logic is :216-264)
  - DAQPal/Processing/ConfidenceEngine.swift:110-156
  - DAQPalTests/SegmentCellScannerTests.swift

ALLOWED FILES (WS-B-owned):
  - DAQPal/OCR/SegmentCellScanner.swift
  - DAQPal/Processing/ConfidenceEngine.swift
  - DAQPalTests/SegmentCellScannerTests.swift
  - DAQPalTests/ConfidenceEngineTests.swift (create if absent)
  - DAQPalTests/Support/ValidationHarness.swift

FORBIDDEN FILES:
  - DAQPal/Tracking/*  (WS-A)
  - DAQPal/Instrumentation/*, DAQPal/UI/PipelineDebugOverlay.swift  (WS-C)
  - DAQPal/App/AppState.swift, DAQPal/Camera/FrameProcessor.swift  (SHARED — gate only)
  - DAQPal/OCR/SevenSegmentSampler.swift — do NOT modify. The audit disproved the theory
    that its polarity detection is at fault. If you believe it is, STOP AND REPORT.

ARCHITECTURE THAT MUST BE PRESERVED:
  - D1: Apple Vision stays the OCR hot path. No engine replacement.
  - D3: no model training.
  - D4: column-scan segmentation + decimal-by-size-ratio. Connected-component labeling is
    dead for segment faces — do not reintroduce it.
  - Rejection stays a single chokepoint at ConfidenceEngine.fuse. Do not add a second
    accept/reject site.
  - Refusal is always preferable to guessing. No change may increase accepted readings at
    the cost of correctness.

IMPLEMENTATION TASK 1 — fix the 4 failures (root cause is known; do not re-diagnose):
  SegmentCellScanner.swift:247-264 builds a horizontal ink projection, gates it at
  0.60 × non-zero median (rowGateFraction), and emits each surviving span as a SEPARATE
  Row. On "99.9" the intra-glyph trough (55 rows @ 48 ink) is indistinguishable from a
  genuine inter-line gap (48-76 rows), so ONE digit line is split into TWO bands and the
  column scanner then sees only a horizontal slice of each glyph. This is why "99.9"
  reconstructs as "000" and why decimal positions come back nil.
  Parameter tuning cannot fix this — both obvious knobs were swept and neither separates
  the cases.
  FIX: delete the row-projection band pass. Run the column scan over the WHOLE crop first,
  then cluster the resulting runs into rows by y-extent overlap. This is the file's own
  stated thesis at :20-27 — a column run spans the full glyph height regardless of which
  segments are lit.
  The two-row (main + "MAX") layout must still split correctly; add a test for it.

IMPLEMENTATION TASK 2 — add the fused-confidence floor:
  ConfidenceEngine.swift:117 computes
    finalConfidence = ocr * formatFactor * physicalFactor * temporalFactor * decimalFactor
  but the rejection ladder (:119-145) gates only `ocr` (against lowOCRConfidenceThreshold
  = 0.3). Then :141 does `finalConfidence *= (1 - c)` AFTER the last check, and nothing
  re-gates it. Worked example with the real constants: ocr=0.35, decimalFactor=0.5,
  crossCheck c=0.49 -> finalConfidence ~= 0.089, exported as accepted: true.
  It leaks further: temporalFactor can approach 0 WITHOUT setting temporalRejected,
  because rejection needs a full 5-sample window (TemporalFilter.swift:64-65) while the
  factor applies immediately.
  FIX: after the cross-check block and before constructing the Measurement, add a floor:
    if reason == nil, finalConfidence < Self.minimumFusedConfidence {
        reason = .lowOCRConfidence   // or add a .lowConfidence case
    }
  Choose minimumFusedConfidence deliberately and JUSTIFY IT IN THE LEDGER. Do not pick a
  round number silently. Report how many previously-accepted readings the chosen value
  would now refuse, measured against DecimalBenchmarkTests.

TESTS REQUIRED:
  - All 4 named SegmentCellScannerTests failures pass.
  - A new test for the two-row (main + MAX) layout.
  - A new ConfidenceEngine test proving a reading whose factors multiply below the floor is
    refused, with the reason set — including the temporalFactor-without-temporalRejected path.
  - A test proving a clean high-confidence reading is still accepted (no over-refusal).

MUST STAY GREEN: the entire suite. Specifically DecimalRescueTests (23),
DecimalBenchmarkTests, DecimalIntegrityTests, SevenSegmentSamplerTests, CorpusTests.

EVIDENCE REQUIRED:
  - Test counts before and after, via xcresulttool (expected after: 861+/0/2).
  - For the confidence floor: the count of readings in DecimalBenchmarkTests that flip from
    accepted to refused, and confirmation that ZERO correct readings were refused.
  - Provenance tag [sim iPhone 16 Pro, Debug, serial] on every number.

COMMANDS:
  xcodebuild test -scheme DAQPal \
    -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
    -resultBundlePath /tmp/daqpal_b0.xcresult -parallel-testing-enabled NO
  xcrun xcresulttool get test-results tests --format json --path /tmp/daqpal_b0.xcresult

LEDGER UPDATE (MASTER_PLAN.md §5):
  - Move the 4 SegmentCellScannerTests failures out of "Known defects" into a closed entry.
  - New test count with provenance tag.
  - A new decision-registry proposal row (§3) recording minimumFusedConfidence, its value,
    and the evidence that justified it. This is a settled decision and must be registered.
  - Session log row per §2 rule 8.

DEFINITION OF DONE:
  - Suite green: 0 failures.
  - No reading can export accepted: true below the documented fused-confidence floor.
  - The floor's value is justified with measured numbers, not asserted.
  - SegmentCellScanner still has zero production call sites — wiring it is B4, NOT this
    session. Do not wire it.

STOP AND REPORT rather than silently changing architecture if:
  - The row-clustering rewrite would require modifying SevenSegmentSampler.
  - Fixing the 4 tests appears to require reintroducing connected-component labeling (D4).
  - The confidence floor refuses correct readings at any value you try — that is a real
    finding about the fusion model and needs a decision, not a tuned constant.
  - You find that a test asserts something the audit says is false. Report the conflict.
  - Three attempts at either task have failed.

DO NOT:
  - Wire SegmentCellScanner, DecimalRescue, or DisplayFormatInference (B1/B2/B4).
  - Touch tracking, UI, or performance code.
  - Change any D1-D8 decision. Propose, never deviate.
```
