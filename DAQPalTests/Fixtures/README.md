# DAQPalTests/Fixtures

Real-DMM video fixtures for `RecognitionPipelineTests`, per the spec's §30 dataset
layout and §40.3 testability boundary. This directory ships **empty** — no fixture
is committed yet, and `RecognitionPipelineTests` `XCTSkip`s cleanly until one lands.

## Honesty note

**No fixture-based accuracy is claimed anywhere in this codebase until a real
fixture exists.** `SyntheticPipelineTests` exercises the pipeline end-to-end with
programmatically-rendered digits (`SyntheticDisplayRenderer`) so the wiring is
testable without hardware, but synthetic renders are not a model of real display
optics (segment gaps, glare, viewing angle, motion, compression) and must never be
cited as evidence of real-DMM recognition accuracy. Only a fixture recorded from an
actual instrument, checked in here, and run through `RecognitionPipelineTests`
establishes a real accuracy number — and even then, only for that instrument/
lighting/format combination.

## File naming

One matched pair per recording, numbered sequentially:

```text
DAQPalTests/Fixtures/
├── dmm_001.mov
├── dmm_001.csv
├── dmm_002.mov
├── dmm_002.csv
└── ...
```

- `dmm_NNN.mov` — the recorded video, portrait orientation, matching what the
  camera pipeline actually delivers (see `CameraManager`: `.hd1920x1080` preset,
  buffers rotated upright). Any container/codec `AVAssetReader` can decode is fine
  (H.264 `.mov` is simplest from an iPhone).
- `dmm_NNN.csv` — ground truth for that video: relative timestamp in seconds
  (matching the video's own presentation timestamps, i.e. seconds since the first
  frame) and the value actually shown on the display at that moment.

  ```csv
  timestamp,value
  0.000,12.347
  0.033,12.347
  0.066,12.350
  ...
  ```

  A header line is optional — `RecognitionPipelineTests` parses `timestamp,value`
  rows and simply skips any line whose first column isn't a number (which a
  `timestamp,value` header naturally satisfies). Extra columns are fine; only the
  first two are read.

- Optional: `dmm_NNN_garbage.mov` — a short clip with an injected out-of-range or
  unreadable frame (finger over the display, display off, wrong object in frame),
  used by `testGarbageFrameIsRejected` to confirm the pipeline rejects rather than
  fabricates a value. No matching CSV is needed for this one — the test only
  checks that *some* reading in the clip is rejected.

## How to record one

1. Mount or hand-hold an iPhone (or use `dmm_001.mov` from any device — the reader
   only needs a decodable video track) framing a real digital multimeter display,
   matching the MVP's expected framing (display fills a meaningful fraction of
   the frame, roughly centered — see `NormalizedROI.defaultROI` for the region
   `RecognitionPipelineTests` currently assumes; update it once your fixture's
   actual display location is known).
2. Record 10–30 seconds covering the scenarios spec §30 asks for: a stable
   reading, at least one decimal-digit change, and ideally a real step change
   (spec §16's "12.000 → 13.001 must survive" scenario) if the instrument/source
   under test can produce one.
3. Simultaneously log ground truth. Best case: read the value off a trusted
   digital interface / reference meter and timestamp it against the video's own
   clock (start the recording and the log together, or use a shared visible time
   reference). Manual labeling by scrubbing the video and hand-transcribing values
   at known timestamps is acceptable for the MVP dataset — mark it as such in your
   PR description so accuracy numbers derived from it are read with the correct
   confidence.
4. Transcode/copy the file in as `dmm_NNN.mov`, write `dmm_NNN.csv` next to it.
   Filesystem-synchronized groups mean nothing else needs updating — Xcode picks
   up new files under `DAQPalTests/Fixtures/` automatically as test bundle
   resources.
5. Run `RecognitionPipelineTests` — it will stop skipping and start asserting
   acceptance rate and value accuracy against your ground truth automatically.
