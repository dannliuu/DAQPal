# Deliverable K — Next Ultracode Session Prompt

**Run K1. K0 is already done — do not run it.** (Status updated 2026-08-03 after K0 was executed.)

## Why K0 is not required

K0 was executed in the same session that authored it. Every item in its own Definition of Done was verified mechanically against the repo, not assumed:

| K0 DoD item | State | Evidence |
|---|---|---|
| Working tree clean | PASS | `git status --porcelain` → 0 lines |
| Scheme in version control | PASS | `DAQPal.xcodeproj/xcshareddata/xcschemes/DAQPal.xcscheme` is tracked; verified to build both test bundles |
| All Deliverable I edits applied | PASS | 12/12 spot-checks pass (DoD-5, yield floor, exact test command, §2 rules 7–9, WS-D, WS-E, spec path, `CLAUDE.md` reclass, ws-a invariant, ws-b floor invariant) |
| Test count recorded in §5 | PASS | `855 passed / 5 failed / 2 skipped / 1 expected failure = 863 cases` `[sim iPhone 16e iOS 18.4, Debug, serial]` |
| Commits made | PASS | 7 commits `3156d4f · c07315c · c5c81a9 · 67e68cd · 372e3da · 60b5a61 · a7a48e6`, all pushed to `origin/segment-cell-scanner` (0 unpushed) |

K0's stated purpose was to make it possible for any workstream session to satisfy its exit invariant. That is now true, so re-running it would be a no-op at best and would re-litigate settled commits at worst.

### Three errors in K0 as originally written, recorded so they are not repeated

1. **Wrong simulator.** K0 specified `-destination 'platform=iOS Simulator,name=iPhone 16 Pro'`. That simulator does not exist on this machine (available: iPhone 16e / 18.4, iPhone 17 family / 26.5). The command would have failed immediately.
2. **Wrong expected count.** K0 expected `857/5/2`. The real measured baseline is `855/5/2 + 1 expected failure`. The 857 figure came from grepping stdout on a log that **double-prints its per-case lines** — the precise failure mode `§2` rule 4 now forbids.
3. **Self-contradiction.** K0's task 1 said "commit the working tree" while its FORBIDDEN list said "any `DAQPal/**.swift`". Committing pre-existing untracked Swift is not *editing* it, but the prompt should have said so. It resolved correctly in practice (no application code was authored in K0), but a stricter agent would have deadlocked.

---

## K0 — Unblock the plan set — ✅ COMPLETE 2026-08-03, DO NOT RUN

*Retained verbatim for provenance. Superseded by the commits listed above.*

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

PREREQUISITES: SATISFIED. K0 completed 2026-08-03 (commits 3156d4f..a7a48e6, pushed).
Working tree is clean, the plan set is self-consistent, the scheme is shared. Start here.

MEASURED STARTING STATE (do not re-measure before you begin; this is from the §2 command):
  855 passed / 5 failed / 2 skipped / 1 expected failure = 863 cases
  [sim iPhone 16e iOS 18.4, Debug, serial]

SCOPE CORRECTION — read this before trusting the DoD below. Of the 5 failures, only 4 are
yours. The 5th, DAQPalUITests/DragLatencyUITests.testDragLatencyWhileSearching, lives in
DAQPalUITests/ which §7 assigns to WS-D, not WS-B. K1 therefore CANNOT reach a
zero-failure suite, and any prompt claiming otherwise is wrong. Your target is:
  - 0 failures in DAQPalTests (the 4 SegmentCellScannerTests fixed)
  - DragLatencyUITests still failing, untouched, and explicitly reported as out of scope
Do NOT quarantine or edit that UI test to make a number look green. Its measured signature
(5 callbacks, p50 134.6ms, 4 stalls, 4 dropped frames) is simulator gesture starvation and
belongs to a separate WS-D/WS-A triage.

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
  - DAQPalTests/ConfidenceEngineTests.swift (CONFIRMED ABSENT — you must create it)
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
  - Test counts before and after, via xcresulttool. Expected after: 4 scanner failures gone
    (>=859 passed), plus however many NEW tests you add. Only DragLatencyUITests may still
    fail. Report the exact numbers, never a rounded claim.
  - For the confidence floor: the count of readings in DecimalBenchmarkTests that flip from
    accepted to refused, and confirmation that ZERO correct readings were refused.
  - BLAST RADIUS: 20 test files reference `accepted` and there are 17 direct acceptance
    assertions. Enumerate every one the floor changes, and justify each individually.
  - Provenance tag [sim iPhone 16e, Debug, serial] on every number.

COMMANDS:
  xcodebuild test -scheme DAQPal \
    -destination 'platform=iOS Simulator,name=iPhone 16e,OS=18.4' \
    -resultBundlePath /tmp/daqpal_b0.xcresult -parallel-testing-enabled NO
  xcrun xcresulttool get test-results tests --format json --path /tmp/daqpal_b0.xcresult

LEDGER UPDATE (MASTER_PLAN.md §5):
  - Move the 4 SegmentCellScannerTests failures out of "Known defects" into a closed entry.
  - New test count with provenance tag.
  - A new decision-registry proposal row (§3) recording minimumFusedConfidence, its value,
    and the evidence that justified it. This is a settled decision and must be registered.
  - Session log row per §2 rule 8.

DEFINITION OF DONE:
  - 0 failures in DAQPalTests. DragLatencyUITests may still fail (out of scope, see above).
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
