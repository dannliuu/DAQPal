# WS-D — Experience: Make the Promise Legible

Read `docs/plans/MASTER_PLAN.md` first (protocol §2, ownership §7, decisions §3). Status is reported ONLY to the master ledger (§5) — never restated here.

Created 2026-08-03 by `EXECUTABILITY_AUDIT.md` Deliverable G. Before this workstream existed, 24 of 81 production files matched no ownership row, so under §7's rule the entire user-facing surface was un-editable.

**Mission**: the product's promise — *when DAQPal cannot establish that a reading is correct, it refuses or flags it rather than silently exporting a wrong number* — must be **visible to the user at the moment it matters**, and every flagged reading must be reachable, explainable, and correctable before export.

The recognition side of that promise is WS-B's. WS-D owns whether a human can *see* it.

## Invariants

- **Never make a refusal look like a reading.** No UI state may present a rejected value with the visual language of an accepted one.
- **Never lose data silently.** An interrupted session must warn or recover; it may never discard samples without telling the user.
- Every export path carries the same audit columns. Adding a device may never reduce the fidelity of the record.
- WS-D does not change accept/reject *logic* — that is `ConfidenceEngine`, WS-B-owned. WS-D surfaces what the logic already decided. If a needed signal is not carried through to the UI layer, that is a hook request to WS-B at a gate, not a local fix.
- Full suite green at session end (baseline in master §5).

## Owned files

Per master §7: `DAQPal/UI/*` **except** `PipelineDebugOverlay.swift`, `CoordinateDebugOverlay.swift`, `ROISelectionOverlay.swift`, `FieldSelectionOverlay.swift`, `PanGestureCatcher.swift`, `CameraCaptureScreen.swift`, `VideoImportView.swift` · `DAQPal/App/DAQPalApp.swift` · `DAQPal/Camera/CameraPermissionManager.swift` · `DAQPal/Data/CSVExporter.swift` · `DAQPalUITests/*`.

Shared files (`AppState.swift`, `CameraCaptureScreen.swift`) only at gates.

## Tasks

### D1 — Make refusal visible during live aiming (highest value in this workstream)
The pipeline genuinely refuses, and the CSV genuinely records it — but the user never sees it while aiming, which is the only phase where they could actually fix the problem.

Audit anchors: the reason-bearing chip (`RecordingControlsView.swift:227-238`) and the REJ counter (`:205-206`) both live in `RecordingStripView`, which is mounted **only while recording**. `AppState.apply(_:)` (`AppState.swift:380-388`) copies `m.accepted` but **discards `m.rejectionReason`**, so no live view can render a reason even if it wanted to. Worse, `reading.value` is only overwritten when `m.accepted` (`:382-384`) while `reading.confidence` is set unconditionally — so during a refusal the card shows the **last accepted value** under a green LOCKED chip with a live-moving confidence bar.

- Carry `rejectionReason: RejectionReason?` through `LiveReading` (`Device.swift:54-76`) and set it in `AppState.apply` (**hook request to SHARED — lands at a gate**).
- Add a third card state to `DeviceReadingCard.statusChip` (`LiveReadingBadge.swift:205-216`): LOCKED / SEARCHING / **REFUSED**, with the reason's `displayLabel`.
- A stale value must never sit under a healthy chip. Either blank the value or visibly mark it stale.
- **Evidence gate**: UI test that forces a refusal and asserts the reason is on screen **without recording being active**; test that the card never shows an accepted-looking value while `accepted == false`.

### D2 — Export parity across schemas
`CSVExporter.swift:81-111` (multi-device) omits **both** `rejection_reason` and `raw_text`, the two diagnostic columns the single-device schema carries (`:47`). There is no other durable export, so a 2+ device session has no audit trail at all — the promise silently degrades as soon as a second device is added.

- Bring the multi-device schema to parity: per-device `_rejection_reason` and `_raw_text`.
- **Evidence gate**: round-trip test asserting a rejected reading in a 2-device session is recoverable from the CSV with its reason intact.

### D3 — Persistence and interruption
Zero hits across `DAQPal/` for `scenePhase`, `didEnterBackground`, `willResignActive`, `AVCaptureSessionWasInterrupted`, `UserDefaults`, `SwiftData`. Samples live only in memory. A phone call, an OS jettison, or a crash mid-recording destroys the session with no warning and no recovery; camera preemption blacks out the app permanently.

- Handle `AVCaptureSessionWasInterrupted` / `InterruptionEnded` with a visible state and automatic resume.
- Persist the active recording incrementally so an interrupted session is recoverable, or — if incremental persistence is rejected on cost — warn the user explicitly at record time that the session is memory-only. Record the choice as a D-entry.
- **Evidence gate**: UI test backgrounding mid-recording and asserting either recovery or an explicit warning; test for camera-interruption recovery.

### D4 — Review and correction surface
`ResultsView.tableCard` (`ResultsView.swift:311-336`) shows only `session.samples.suffix(50)` (`:23`). Flagged rows are unreachable beyond that window, carry no reason, and cannot be corrected or confirmed. For a measurement product whose whole thesis is "some readings are uncertain," there is nowhere to resolve that uncertainty.

- Reachable full sample list; per-row reason; filter to flagged-only.
- Confirm-or-correct affordance for flagged rows, with the correction recorded as user-supplied provenance in the export (never silently indistinguishable from a machine reading).
- **Evidence gate**: a flagged row can be found, understood, and resolved; the export distinguishes machine-accepted from user-confirmed.

### D5 — State legibility
`"SEARCHING"` is one word for four different failures (`LiveReadingBadge.swift:205-216`, `ROISelectionOverlay.swift:4x`), and the on-screen hint can give the wrong remedy. Also unhandled: permission-denied recovery, low-light guidance, no-display-found, multiple-display disambiguation, and export success/failure.

- Distinguish no-display / display-not-verified / OCR-failing / tracking-lost, each with the correct remedy.
- **Evidence gate**: each state reachable in a UI test with its distinct copy asserted.

## Non-goals

Accept/reject logic (WS-B), tracking behaviour (WS-A), performance tuning (WS-C), video import (WS-E), visual redesign of the capture screen beyond what legibility requires.
