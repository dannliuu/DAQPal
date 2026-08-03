# Design: DAQPal Performance Master-Plan Document Set

Date: 2026-08-03
Status: Approved in brainstorming session (goal, doc model, conflict mechanisms, device access, and sequencing strategy each confirmed by Daniel; sections 1–3 presented conversationally)

## Problem

DAQPal has ~21 markdown documents (specs, remediation plans, research, progress logs) totaling ~570KB. They contradict each other because status was duplicated across files and went stale (three different test counts in one file; spec checkboxes marked open for work that shipped; a "BLOCKING" framing superseded 5 sections later but never rewritten). An agent picking any single doc as ground truth will do wrong or duplicate work. Meanwhile the app itself has two kinds of debt:

- **Correctness**: seven-segment OCR ~41.7% (synthetic, dual-pass), `DecimalRescue` written but zero call sites, `DisplayFormatInference` never fed to `TemporalConsensus`, 6 open tracking defects, overlay hit-testing uses bounding box (~1.9× quad area at 30° roll), a measured `.5`→`5.0` power-of-ten bug (9.7% of device benchmark).
- **Performance ground truth**: none. No Instruments profile exists. Every on-device number is Debug/`-Onone`. Capture/tracking/detection/OCR/UI FPS and end-to-end latency are all unmeasured. Zero real-hardware validation of any kind (no fixtures, no recorded baselines, HARDWARE_VALIDATION.md all blank).

## Requirements (confirmed with Daniel)

1. **Goal**: correct + fast, end to end — robustness and performance both in scope.
2. **Doc model**: new plan set + master index. Existing markdowns untouched (never deleted, never edited) as read-only reference/history.
3. **Conflict protection**: both mechanisms — a decision registry (no contradictory technical decisions) and per-workstream file ownership (no parallel-agent collisions).
4. **Device access**: occasional. Device-dependent validation batched into periodic "device days"; day-to-day gates run on simulator + synthetic corpus.
5. **Sequencing**: parallel workstreams + measurement spine (chosen over measure-first-sequential and correctness-first-sequential).

## Design

Four new files, all under `docs/plans/`:

```
docs/plans/MASTER_PLAN.md        coordination hub — the one file every agent reads first
docs/plans/ws-a-tracking.md      workstream A: trust the lock
docs/plans/ws-b-ocr-accuracy.md  workstream B: read it right
docs/plans/ws-c-performance.md   workstream C: prove it fast, then make it fast
```

### MASTER_PLAN.md anatomy

1. **Mission + definition of done** — acceptance gates: zero false-healthy-locks on device; accepted-measurement accuracy on real fixtures (the spec's ≥99% system-level bar, gated on fixtures existing); spec per-stage budget table met at p95 in a Release build on the physical iPhone; standing regression net green.
2. **Agent protocol** — how an executing agent uses the plan set (read master → claim workstream → obey ownership → update ledger at session end).
3. **Decision registry** — settled decisions D1–D8 with evidence and reopen-if conditions (Vision stays hot path; TrackVerifier over RANSAC as deliberate deviation; no training data yet; classical segment path; Release-only perf claims; synthetic ≠ real; cadence values; doc governance).
4. **Status ledger** — the ONLY place status lives. Workstream docs define tasks and gates but never restate status. This single-writer-for-status rule is the direct fix for the staleness disease in the legacy docs.
5. **Authority map** — all legacy markdowns with trust level and known staleness traps.
6. **Conflict rulings** — explicit reconciliation of the ~14 contradictions found across the legacy docs (test counts, Gate-14 wired-vs-not, cadence values, PP-OCRv5-vs-v6 naming, "OCR 30/S" UI copy vs measured 382–397ms accurate pass, etc.).
7. **File-ownership matrix** — every Swift file → exactly one owning workstream; shared files editable only at integration gates.
8. **Device-day protocol** — batched checklist for the occasional physical-iPhone sessions.
9. **Milestones** — M0 baseline snapshot → M1 wiring/defect burn-down (parallel) → Gate G1 → Device Day 1 → M2 depth work (parallel) → Gate G2 → Device Day 2 → acceptance.

### Workstream docs

Each is written for an executing agent: mission, invariants, owned files, ordered tasks with per-task evidence gates, device-day requests, explicit non-goals.

- **WS-A tracking**: 6 open defects (recovery re-seed proximity gate first), overlay quad hit-testing, FieldSelectionOverlay anti-pattern, motion-matrix extension beyond bounce, hold-rate improvement (67/81 REACQUIRING today), structured-distractor robustness. Standing invariant: false-healthy-lock stays 0.
- **WS-B OCR accuracy**: wire DecimalRescue, feed format prior to TemporalConsensus, fix `.5` tokenizer bug + zero-refusal defect, verify SegmentCellScanner against the SSOCR research checklist (row-split, decimal-by-size, Sauvola σ-term), low-contrast fixture (0.20 Michelson) from the real IR-gun photo, TemporalConsensus hardening, first real regression baselines.
- **WS-C performance**: populate PipelineMetrics stages, extend PipelineBudgetTests to the spec budget table, cold-start warm-up, cadence policy reconciliation, Device Day 1 Instruments + Release baseline, then a strictly gated optimization backlog (no optimization before baseline; every change needs before/after device numbers).

## Alternatives considered

- **Measure-first sequential**: safest against wasted optimization but front-loads exactly the device time that's only occasionally available, and delays fixes already justified without profiling. Rejected.
- **Correctness-first sequential**: reliability soonest but correctness lands with no perf baseline underneath — cost creep invisible until later. Rejected.
- **One master doc only / coordinate legacy docs in place**: rejected by Daniel in favor of new plan set + master index.

## Acceptance criteria for this deliverable

- The four plan files exist, are internally consistent, and contain no unresolved placeholders.
- Every number cited carries provenance (measured value + where it was measured) or is explicitly labeled a target.
- An agent reading only MASTER_PLAN.md + its claimed workstream file can start work without reading any legacy doc end-to-end.
- Legacy markdowns are untouched.
