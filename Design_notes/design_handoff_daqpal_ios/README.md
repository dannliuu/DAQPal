# Handoff: DAQPal — Visual Instrument Data Logger (iOS MVP)

## Overview
DAQPal turns a phone camera into a data-acquisition front end for instruments with no data port: point the camera at one or more digital multimeters, drag an ROI (region-of-interest) window over each display, confirm the display format, record, and export a timestamped CSV with one column set per device. This handoff covers the full MVP flow: capture, ROI alignment, format configuration, recording with live validation, results, and CSV export.

The authoritative product/algorithm specification is `Visual_Instrument_Data_Logger_Agent_Development_Specification.md` (included). This README covers the **UI design**; the spec covers the recognition pipeline (format-aware OCR, validation hierarchy, confidence model). Read both.

## About the Design Files
The files in this bundle are **design references created in HTML** — interactive prototypes showing intended look and behavior, not production code. The task is to **recreate these designs natively in SwiftUI** (per the spec: Xcode, Swift, SwiftUI, AVFoundation, Apple Vision), using the patterns below. Open `DAQPal App.dc.html` in a browser to interact with the working prototype (drag ROIs, configure formats, record, export CSV).

## Fidelity
**High-fidelity.** Colors, typography, spacing, and interactions are intentional; recreate pixel-close. The camera scene inside the prototype (the two drawn multimeters) is a stand-in for the live AVFoundation preview — do not recreate the meters.

## Design Tokens (Fluke-yellow theme)
Colors:
- Chrome / light surfaces: `#F7E9BC` (app bars, panels), cards `#FDF6DE`, results background `#FAF6EA`, results cards `#FFFFFF`, table header `#F3EBD2`
- Ink: `#2B2820`; muted ink: `rgba(43,40,32,0.55)`; hairline borders: `rgba(43,40,32,0.2)`; heavy rules: `2px solid rgba(43,40,32,0.4)`
- Brand yellow (accent, ROI-locked, primary buttons, confidence bars): `#FFC20E`; graph series 1: `#E8A400`; dark chip: `#2B2820` with `#FFC20E` text
- Status: locked chip `#FFE9A8`/`#6B4E00`; searching/rejected `#FFD9CE`/`#8A2A12`, rejected row bg `#FDEBE7`; accepted chip `#EAF3E2`/`#3D5B27`
- Record button: `#D0342C` (idle "● REC"), `#B02318` (recording "■ STOP"); ROI searching border: `#FF6B4A` dashed
- Camera area: `#0B0C0F`; recording strip: `#2B2820` bg, spark lines `#FFC20E` (device 1) and `#E5DFC9` (device 2)

Typography:
- UI: **Archivo** (400/500/600/800). Numeric readouts, timers, table values: **monospace** (SF Mono on iOS)
- Scale (at 402 pt phone width): wordmark 15/800; section labels 10/800, letter-spacing 0.1em, uppercase; live reading value 24 mono; meter/format preview 22–28 mono; body/meta 9–12; chips 8–10/800

Shape & spacing: radius 4–5 (chips), 8 (cards, buttons), 10 (results cards), 18 (sheet top corners); panel padding 16; card padding 9–12; gaps 6–12. Hit targets ≥ 44 pt in the native build (prototype buttons are visually smaller; pad tap areas).

## Screens / Views

### 1. Capture (dark camera, light-yellow chrome)
- **Header**: wordmark "DAQPAL" + subtitle "VISUAL DATA ACQUISITION"; right: profile chip ("FLUKE 87V", outlined) and device-count chip ("2 DEVICES", dark bg, yellow text).
- **Camera viewport** (fills remaining height): live AVFoundation preview. Overlaid per device: a **draggable ROI window** — 2 px border, radius 6, four 8 px corner handles, floating label above ("⠿ DMM-1 · 99.8%"). States: **locked** (solid `#FFC20E`, soft yellow glow, label shows live confidence) when ROI overlaps a detected display ≥ ~60%; **searching** (dashed `#FF6B4A`, white label text "SEARCHING") otherwise. Bottom hint caption: "DRAG A WINDOW ONTO A DISPLAY TO LOCK OCR".
- **Recording strip** (only while recording, dark `#2B2820`): pulsing red ● REC, elapsed mm:ss.s, sample count, rejected count, and a 2-series live sparkline of the last ~80 samples. When a reading fails validation, flash a chip "✕ REJECTED — FORMAT MISMATCH" for ~1.2 s.
- **Live readings panel**: one card per device in a 2-column grid (1 column if one device). Card: device label ("DMM-1 · V DC"), a format button ("⚙ ±XX.XXX") opening the format sheet, big mono value (em-dash placeholder "—.———" when not locked), confidence bar (yellow fill = confidence %), confidence % text, LOCKED/SEARCHING chip.
- **Footer**: elapsed-time chip (mono), primary record button (red, "● REC" / "■ STOP"), right-aligned meta "CAM 240 FPS / OCR 30/S".

### 2. Display Format sheet (bottom sheet over capture)
Scrim `rgba(24,21,12,0.45)`; sheet `#F7E9BC`, top radius 18. Contents, top to bottom:
- Title "Display format — DMM-1", subtitle "<model> · Mode 2 — user-configured format", ✕ close.
- **Pattern preview**: dark panel, yellow mono text, e.g. "±XX.XXX V" — live-updates as options change.
- Rows (label left, control right): DIGITS (segmented 4/5/6), DECIMAL AFTER DIGIT (− n +stepper, clamped 1..digits−1), SIGN (toggle ALLOWED/OFF), UNIT (segmented V/A/Ω/°C/Hz), VALID RANGE (min/max steppers, ±5, min < max).
- Primary button "DONE — RESUME CONSTRAINED OCR" (yellow). Selected segments: dark bg `#2B2820` + yellow text.

### 3. Results (light)
Scrollable, bg `#FAF6EA`:
- Header row: "‹ Camera" back link, centered "SESSION RESULTS", row-count chip.
- Summary chips: duration, samples/s, "✓ n accepted" (green), "✕ n rejected" (red).
- **Graph card**: white, "MEASUREMENT vs TIME", legend per device, 2 polyline series (device 1 `#E8A400` 2 px, device 2 `#3A3730` 1.6 px), 3 horizontal gridlines, x-axis 0.00s → duration. Each series is normalized to its own min/max (dual-scale).
- **Stats cards**: per device — min / mean / max (mono), computed from **accepted** samples only.
- **Table card**: columns TIME | DMM-1 (V) | CONF | DMM-2 (A) | CONF; rejected rows get bg `#FDEBE7` and "✕ rej" in the value cell; footer note "+ n earlier rows — full data in CSV".
- Buttons: "⬇ EXPORT CSV" (yellow, primary) and "NEW SESSION" (outlined).

## Interactions & Behavior
- **ROI drag**: pointer-down on the ROI window begins drag (whole window moves; the prototype does not implement resize — native app should also support corner-handle resize). Clamp inside the viewport. Lock state = ROI∩display / display area > 0.6, re-evaluated continuously. Unlocked device ⇒ confidence 0, value placeholder, SEARCHING styling everywhere.
- **Recording**: REC resets clock and buffer, starts sampling (prototype: 8.3 samples/s; native: per spec, OCR-rate-driven ~30/s). STOP navigates to Results. Recording continues while dragging ROIs or with the sheet open.
- **Validation (per sample, per device)**: sample marked invalid if device unlocked or reading fails format/temporal/physical checks (spec §4, §8). Invalid ⇒ rejected count increments, flash chip, row flagged in table, `valid=0` in CSV; the value is still logged.
- **CSV export**: file `daqpal_session.csv`, one column set per device: `timestamp_s, dmm1_value_V, dmm1_confidence, dmm1_valid, dmm2_value_A, dmm2_confidence, dmm2_valid`. Native: share sheet / Files export.
- **Format sheet**: edits apply immediately (pattern preview updates live); DONE/✕/scrim-tap close.
- Transitions: sheet slides up ~250 ms ease-out; screen changes are instant in the prototype (native: default push/modal is fine). Record button pulse: 1 s opacity loop on the red dot.

## State Management
- `screen: capture | results`; `recording: Bool`; `sheetFor: deviceIndex?`
- `devices: [Device]` — id, model, unit, digits, decimalPosition, signAllowed, min, max, roi rect. **The device list is dynamic**: design assumes 1–n devices (prototype shows 1–2); each device contributes an ROI window, a reading card, a graph series, table columns, and a CSV column set.
- `live: [reading]` per device — value, confidence, locked (updated at OCR rate)
- `samples: [{t, per-device {value, confidence, valid}}]` — append while recording
- Derived: elapsed, sample/rejected counts, stats (accepted only), graph geometry.

## Assets
No image assets. Archivo via Google Fonts (native: bundle Archivo or substitute a similar grotesque; readouts use SF Mono). All icons are text glyphs (⠿ ⚙ ● ■ ✕ ✓ ⬇).

## Files
- `DAQPal App.dc.html` — interactive hi-fi prototype (all screens, behaviors, simulated data). Requires `ios-frame.jsx` beside it.
- `ios-frame.jsx` — iPhone frame used for presentation only; not part of the design.
- `Capture Directions.dc.html` — earlier visual-direction exploration (4 themes); superseded by the Fluke-yellow theme but kept for reference.
- `Visual_Instrument_Data_Logger_Agent_Development_Specification.md` — full product & recognition-pipeline spec (source of truth for OCR modes, validation, CSV semantics, roadmap).
