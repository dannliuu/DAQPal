# Hardware validation — physical IR temperature gun

**Status: NOT RUN. No physical device has been tested.**

Everything in this document is a *procedure*. Every table below is empty on purpose.
No number in this repository describes a measurement taken against a real instrument,
and none may be added here except by a person who actually performed the run and
recorded what they saw.

This is a **manual procedure**. It cannot be automated, it cannot run in CI, and it
cannot run in the Simulator:

* it needs an **iPhone** (the Simulator has no camera; the synthetic frame source is a
  rendered display, so it validates the pipeline, never the optics);
* it needs the **physical IR thermometer** — the one photographed in
  `DAQPalTests/Fixtures/ir_gun_display.png` (673×760, upright, large `90.0` with a
  secondary `92.7` and a `MAX` legend);
* it needs a **human** to hold, aim, occlude, tap, and read numbers off a screenshot.

The synthetic sweeps answer "does the maths hold". This answers the only question they
cannot: **does the box on the screen sit on the digit in front of the lens.**

---

## 1. What is being validated

The app converts coordinates through a chain, and every stage is a place the boxes can
end up in the wrong place:

```
camera buffer (px)  →  normalized 0…1, top-left  →  container points  →  the glass
     1080×1920            NormalizedROI space         AspectFillMapper
                                  ↑
                    canonical unit square --canonicalToFrame--> normalized frame
```

A tap travels the same chain backwards. The two directions are separately breakable:
a broken forward map puts the boxes in the wrong place and is *visible*; a broken
inverse map puts the user's taps in the wrong place and is *invisible* until a reading
comes back wrong.

`CoordinateDebugOverlay` prints both directions, for the current frame, on the device.
This procedure is how a human checks that what it prints matches physical reality.

---

## 2. Prerequisites

| Item | Requirement |
| --- | --- |
| Phone | iPhone, iOS 17 or later |
| Build | **DEBUG**, run from Xcode. `CoordinateDebugOverlay` is inside `#if DEBUG` and does not exist in a Release build — a TestFlight or App Store build cannot run this procedure |
| Instrument | The physical IR temperature gun, powered on, showing a stable reading |
| Mount | Tripod or clamp for the phone, and something to hold the gun still. Hand-holding both makes the jitter metric meaningless |
| Measuring | Tape measure or ruler for the phone-to-display distance; a protractor or printed angle guide for yaw |
| Lighting | Controllable — you need at least a bright, a dim, and a glare condition |
| Recording | Screenshots (side button + volume up) and, for the jitter and reacquisition metrics, a screen recording at a known frame rate |

Record the build so a later run can be compared to this one:

| Field | Value |
| --- | --- |
| Date | |
| Tester | |
| Phone model / iOS version | |
| Git commit (`git rev-parse --short HEAD`) | |
| Build configuration | Debug |
| Instrument model / serial | |

---

## 3. Enabling the overlay

**The overlay is not mounted by default.** It is a debug instrument, so it is not wired
into the shipping view tree; making it visible is a deliberate, local edit that must be
reverted before the branch merges.

In `DAQPal/UI/CameraCaptureScreen.swift`, inside the `viewport` ZStack's
`if isCapturing { … }` block, after `ROISelectionOverlay()`:

```swift
#if DEBUG
CoordinateDebugOverlay()
#endif
```

That is the whole change. The overlay is `allowsHitTesting(false)` in its entirety and
its touch readout works by *observing* touches rather than taking them, so mounting it
above the ROI overlay does not steal a single tap from the ROI windows or the field
chips. If dragging a window feels different with the overlay mounted than without,
**stop and report that** — it means the isolation described in the file header has been
broken, and it invalidates every measurement below.

Separately, turn on the existing **OCR/debug toggle** in the app to get
`PipelineDebugOverlay` (stage latencies and drop rate) at the top-right. The two
overlays do not overlap: the coordinate panel is top-leading.

### What you will see

* A **text panel**, top-left, with sections `FRAME`, `TOUCH`, `TARGET`,
  `H canonical->frame`, `REGIONS`, `CONFIDENCE`.
* **Thin yellow rectangles**: the digit cells the recognizer believes it is reading —
  one per digit of the device's configured format.
* An **orange crosshair** at the last place you touched the preview.

### Reading the panel

| Row | Meaning |
| --- | --- |
| `buffer` | Oriented capture-buffer size, pixels. Buffers are rotated to portrait before the pipeline sees them, so this is already upright |
| `view` | Viewport size, points |
| `fill` | The aspect-fill `scale` and content origin. A negative origin component is the axis that overflows and gets cropped |
| `visible` | The fraction of the captured frame the viewport actually shows. Anything you cannot see is cropped away and the pipeline never searches it |
| `orient` | Device orientation. `faceUp`/`faceDown` are reported verbatim — lying the gun flat on a bench is a normal way to shoot it, and you need to see when orientation went ambiguous |
| `frame` | Processed frame count, dropped frame count, processed FPS |
| `view pt` / `norm` / `buffer pt` | Your last touch, at all three stages of the chain, plus `DOWN`/`UP` and a touch counter |
| `inside` | `view Y/N` = inside the viewport; `frame Y/N` = inside the captured frame. **These are different**: aspect-fill crops one axis, so a point just outside the viewport on the cropped axis is still on the frame |
| `roundtrip` | View → normalized → view error, points. Must read `0.000000 pt` |
| `TL/TR/BR/BL` | Tracked display quad, normalized then view points |
| `H` | Live canonical→frame homography, row-major. `no lock` and `singular (degenerate quad)` are different failures |
| `digits` | Number of modelled digit cells, their mean pitch in points, and the spread across them |
| `track` / per-device rows | Tracking confidence and health; OCR confidence, lock state and last value per device |

Touch positions are logged on touch **down** and touch **up** only, never during the
move. That is deliberate — writing observable state at 120 Hz while a finger is on an
ROI window is the exact contention documented in `ARCHITECTURE.md` §2, and a debug
overlay must not cause the defect it exists to find. A drag therefore reports its two
endpoints, which is what the alignment checks need.

---

## 4. Procedure

Do these in order. Steps 4.1–4.3 are correctness gates: if any of them fails, the
metrics in §5 are not worth collecting, because the chain is broken upstream of them.

### 4.1 Zero the round trip (2 minutes)

1. Launch the app on the phone with the overlay mounted. Point it at anything.
2. Tap the very centre of the preview. Read `roundtrip`.
3. Tap each of the four corners of the preview, and once well outside it (on the header
   or the readings panel below — the crosshair will show clamped at the edge).

**Expected:** `roundtrip` reads `0.000000 pt` for every tap. `inside` reads `view Y` for
the four in-preview taps and `view N` for the one outside.

If `roundtrip` is anything but zero, stop. Nothing else in this document means anything
while the mapping does not invert.

### 4.2 Confirm the crop (2 minutes)

1. Read the `visible` row.
2. Note which axis is not full-width: `w` < 1 means the left and right edges of the
   frame are cropped away; `h` < 1 means top and bottom are.
3. Tap just *inside* the cropped edge, then just *outside* the preview on that same
   edge.

**Expected:** the second tap reads `view N` but `frame Y` — it is off the viewport and
still on the frame. This is not a bug; it is what aspect-fill does, and it is why the
overlay reports the two separately. Record it so a later tester does not report it as
one.

### 4.3 Place a window on the gun (5 minutes)

1. Mount the phone and the gun so both are still, gun display filling roughly a third of
   the preview, at 30 cm, square on (0° yaw, 0° pitch, 0° roll).
2. Drag an ROI window over the large primary reading (`90.0` in the fixture photo).
3. Open the format sheet and set the digit count to match the physical display
   (4 for `90.0`), with the decimal in the right place.
4. The yellow digit-cell rectangles now appear inside the window.

**Expected:** dragging feels exactly as it does without the overlay. If it does not,
see §3.

---

## 5. Metrics

For each condition in the matrix (§6), take one screenshot with the overlay visible and
record every metric below from it. Screenshot pixels convert to points by dividing by
the device's scale factor (3 for most iPhone Pro models — confirm yours).

### 5.1 Bounding-box centre error

The distance between the centre of the drawn digit-group box and the centre of the real
digit group on the instrument, as it appears in the same screenshot.

* Measure both centres in screenshot pixels, subtract, convert to points.
* Record the magnitude **and** as a percentage of the box width, so the number stays
  comparable across distances.

### 5.2 Edge error

Signed distance from each drawn box edge to the corresponding edge of the real digit
group, points. Positive = the box is outside the glyphs, negative = it is cutting them.

Record all four (left, right, top, bottom). A uniform positive set is a padding
question; a mixed set is a mapping error.

### 5.3 Digit spacing consistency

* From the panel: the `digits` row already prints the modelled mean pitch and its
  spread. The digit model is **fixed pitch** (`DigitSegmenter` divides the ROI into
  equal-width cells), so its own spread is zero by construction — the tests pin that.
* From the screenshot: measure the centre-to-centre distance between each pair of
  adjacent *real* glyphs.
* Record the modelled pitch, the measured pitches, and the largest deviation.

A non-zero deviation here measures the fixed-pitch assumption against a real display —
it is a *model* limitation, not a coordinate bug. Both are worth knowing and they must
not be conflated.

### 5.4 Frame-to-frame jitter

With the phone and gun both clamped and nothing moving:

* Take 10 samples of the `TL` corner's normalized coordinates, at least 1 s apart
  (screenshots, or step through a screen recording).
* Record the peak-to-peak range on each axis, in normalized units and converted to
  buffer pixels (× 1080 and × 1920).

### 5.5 Tracking loss rate

Hold the condition for 60 s of continuous capture.

* Count the number of samples in which `TARGET` reads `no lock`, or the acquisition
  strip reads `DEGRADED` or `REACQUIRING`.
* Record as a percentage of samples, and state your sampling method (a screen recording
  stepped at a fixed interval is reproducible; glancing at the screen is not).

### 5.6 Reacquisition time

* With a healthy lock, fully occlude the gun display with a card for 2 s, then remove it
  cleanly.
* Time from the card leaving the frame to the acquisition strip reading `LOCKED` again.
* Use the screen recording and count frames at the recording's known frame rate.
  Stopwatch-by-hand is worth ±0.2 s at best; if that is all you have, say so in the row.
* Repeat 5 times per condition and record every trial, not just the mean — the tail is
  the number that matters to a user.

### 5.7 OCR confidence

Read `ocr` from the per-device row in `CONFIDENCE`. Record the value seen at the moment
of the screenshot and the approximate range observed over the 60 s hold.

Note what this number is *not*: Apple Vision scores **14.6%** exact on seven-segment
glyphs (**41.7%** with the dual-pass engine) in this project's own synthetic
measurements. A high Vision confidence on a seven-segment face is not evidence the
digits were read correctly, and this column must never be treated as accuracy.

### 5.8 Decimal accuracy

Collect **at least 50** accepted readings per condition, with the true value known
(read it off the instrument yourself). Classify each using the project's existing
taxonomy from `DAQPalTests/Support/ValidationHarness.swift`:

| Verdict | Meaning |
| --- | --- |
| `exact` | Digits and decimal both correct |
| `decimalMissing` | Every digit right, decimal dropped — `90.0` read as `900` |
| `decimalSpurious` | Every digit right, decimal invented — `900` read as `90.0` |
| `decimalMisplaced` | Every digit right, decimal in the wrong slot |
| `digitError` | At least one digit wrong |
| `notDetected` | Nothing produced for a frame that had a reading |

Record counts for all six. Do **not** collapse them into a single accuracy percentage:
the whole reason this taxonomy exists is that a missing decimal is off by a factor of
ten and still looks plausible in a CSV, while a digit error usually does not.

### 5.9 Tap-region check

For each condition, tap the visual centre of each digit cell in turn and record, from
the `TOUCH` section:

* `norm` — must fall inside the device's ROI as printed in the `REGIONS` section;
* `inside` — must read `view Y  frame Y`;
* `roundtrip` — must read `0.000000 pt`.

This is the inverse direction of the chain, and it is the one that fails silently.

---

## 6. Condition matrix

Run every metric at each of these. The angles are within the pose envelope the geometry
model claims to support (|yaw|, |pitch| ≤ 60°, |roll| ≤ 45°), so a failure inside it is
a real defect rather than an out-of-spec input.

| # | Distance | Yaw | Pitch | Roll | Lighting |
| --- | --- | --- | --- | --- | --- |
| C1 | 30 cm | 0° | 0° | 0° | Bright, diffuse |
| C2 | 20 cm | 0° | 0° | 0° | Bright, diffuse |
| C3 | 50 cm | 0° | 0° | 0° | Bright, diffuse |
| C4 | 30 cm | 20° | 0° | 0° | Bright, diffuse |
| C5 | 30 cm | 40° | 0° | 0° | Bright, diffuse |
| C6 | 30 cm | 0° | 20° | 0° | Bright, diffuse |
| C7 | 30 cm | 0° | 0° | 20° | Bright, diffuse |
| C8 | 30 cm | 0° | 0° | 0° | Dim |
| C9 | 30 cm | 0° | 0° | 0° | Direct glare on the display |
| C10 | 30 cm | 0° | 0° | 0° | Bright, phone hand-held (not clamped) |

C10 exists to separate *tracker* jitter from *hand* jitter. Its numbers are not
comparable to C1's and must not be averaged with them.

---

## 7. Results table — fill this in

One row per condition. Leave a cell blank if you did not measure it; **do not estimate,
and do not carry a number over from another row.**

| # | Centre err (pt / % box) | Edge err L/R/T/B (pt) | Modelled pitch (pt) | Max real-glyph pitch dev (pt) | Jitter TL p-p (norm x, y) | Jitter TL p-p (px) | Track loss (%) | Reacq. trials (s) | Reacq. median (s) | OCR conf (at shot / range) | exact | decMissing | decSpurious | decMisplaced | digitErr | notDetected | Tap check pass? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| C1 | | | | | | | | | | | | | | | | | |
| C2 | | | | | | | | | | | | | | | | | |
| C3 | | | | | | | | | | | | | | | | | |
| C4 | | | | | | | | | | | | | | | | | |
| C5 | | | | | | | | | | | | | | | | | |
| C6 | | | | | | | | | | | | | | | | | |
| C7 | | | | | | | | | | | | | | | | | |
| C8 | | | | | | | | | | | | | | | | | |
| C9 | | | | | | | | | | | | | | | | | |
| C10 | | | | | | | | | | | | | | | | | |

### Gates (§4) — pass/fail

| Gate | C1 | Notes |
| --- | --- | --- |
| 4.1 round trip reads `0.000000 pt` | | |
| 4.1 outside-viewport tap reads `view N` | | |
| 4.2 crop asymmetry observed as described | | |
| 4.3 ROI drag feels unchanged with the overlay mounted | | |

### Free-text observations

Anything the table cannot hold: where the boxes drifted, what the glare did, whether the
decimal failures clustered on a particular digit, whether reacquisition ever failed
outright rather than being slow.

```
(observations)
```

---

## 8. Thresholds

**There are none yet, and inventing them here would be dishonest.** No hardware run has
happened, so there is no basis for saying what "good" looks like on this instrument.

The first completed run sets the baseline. Only after that, and with the numbers written
into §7, should a follow-up commit propose pass/fail thresholds — and it should state
which measured row each threshold came from.

What can be said now, because it follows from the code rather than from a measurement:

* `roundtrip` must be exactly zero. It is pinned to zero in pure math by
  `CoordinateDebugOverlayTests`, so a non-zero reading on device means the live mapper
  is not the mapper the tests exercise.
* Modelled digit-cell spread must be exactly zero, for the same reason.
* Everything else — centre error, edge error, jitter, loss rate, reacquisition,
  confidence, decimal rates — is unknown until someone measures it.

---

## 9. Known limitations of this procedure

* **It is manual.** Every number depends on a human measuring pixels in a screenshot.
  Expect ±1–2 px of reading error, which is ±0.3–0.7 pt at 3× scale. Record your own
  measurement method so a second tester can match it.
* **Digit cells come from a fixed-pitch stub.** `DigitSegmenter` divides the ROI into
  equal-width, full-height cells. Real seven-segment displays are not perfectly
  fixed-pitch (the `1` glyph in particular), and none of this is perspective-corrected
  per cell. §5.3 measures that gap deliberately; do not report it as a coordinate bug.
* **Vision is not an oracle on seven-segment faces** (14.6% / 41.7% measured). §5.8 needs
  the true value read by the tester, not cross-checked against another OCR pass.
* **Timings are Debug timings.** The overlay only exists in Debug, so any latency you see
  alongside it is a Debug latency. Per-pixel Swift runs up to ~50× slower in Debug than
  in Release; do not quote a stage latency from this run as a shipping cost.
* **The overlay itself is a load.** It is small and takes no touches, but it does draw
  and it does read tracking state per frame. If you need a clean latency number, take it
  with the overlay unmounted.
* **One instrument.** Results describe this IR gun's display — its glyph shape, contrast,
  refresh and backlight. They do not generalise to a DMM or a bench meter without a
  separate run.
