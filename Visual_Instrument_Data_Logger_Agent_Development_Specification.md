# Visual Instrument Data Logger — Agent Development Specification

## 1. Project Overview

Build a cross-platform mobile application that uses smartphone cameras, computer vision, OCR, and instrument-specific constraints to convert physical instrument displays into structured, timestamped measurement data.

### Core Concept

> Point a smartphone at a digital measuring instrument, identify or configure its display format, record the display, and automatically convert visual measurements into a trustworthy, high-frequency data stream and CSV file.

Primary initial target:

- Digital multimeters (DMMs)
- Seven-segment displays
- Numeric LCD displays

Future targets:

- Bench power supplies
- Oscilloscopes
- Thermometers
- Scales
- Pressure gauges
- Scientific instruments
- Industrial equipment
- Legacy equipment without USB/Bluetooth/serial data output

---

# 2. Product Vision

The product should function as a **visual data acquisition system**.

Instead of requiring an instrument to expose:

- USB
- Bluetooth
- Wi-Fi
- Serial
- SCPI
- Proprietary APIs

the app acquires measurement data visually.

Example physical instrument:

```text
┌─────────────────┐
│                 │
│     12.347 V    │
│                 │
└─────────────────┘
```

The app should produce:

```csv
timestamp,value,unit,confidence
0.000,12.341,V,0.998
0.033,12.342,V,0.997
0.067,12.342,V,0.999
0.100,12.347,V,0.998
```

The system must distinguish between:

1. Camera capture rate
2. OCR/inference processing rate
3. Instrument display refresh rate
4. Actual measurement change rate

A 240 FPS camera does **not** imply 240 independent electrical measurements per second.

The application must explicitly model these as separate concepts.

---

# 3. Core Architectural Principle: Format-Aware OCR

The application should **not rely exclusively on general-purpose OCR**.

Whenever the display format is known or can be inferred, OCR should become a **constrained recognition problem**.

General OCR asks:

> "What text is in this image?"

The proposed system should instead ask:

> "Given that this display contains five numeric digits, with a fixed decimal position, what digit appears in each known position?"

For example, if the expected format is:

```text
XX.XXX V
```

the system knows:

```text
Number of digits: 5
Decimal position: 2
Allowed characters: 0–9
Sign: Optional
Unit: V
```

The OCR system then only needs to recognize:

```text
Position 1 → 1
Position 2 → 2
Position 3 → 3
Position 4 → 4
Position 5 → 7
```

and reconstruct:

```text
12.347 V
```

This approach should be preferred whenever sufficient structural information is available.

Benefits:

- Higher accuracy
- Lower inference cost
- Faster processing
- Fewer false positives
- Better temporal consistency
- Better Neural Engine/NPU efficiency
- Easier validation
- More deterministic output

---

# 4. OCR Recognition Hierarchy

Implement a hierarchical recognition architecture.

```text
                         Camera
                            │
                            ▼
                    Display Detection
                            │
                            ▼
                     ROI / Tracking
                            │
                            ▼
                  Format Identification
                            │
               ┌────────────┴────────────┐
               │                         │
          Known Format             Unknown Format
               │                         │
               ▼                         ▼
      Constrained Recognition       General OCR
               │                         │
               └────────────┬────────────┘
                            │
                            ▼
                   Format Validation
                            │
                            ▼
                  Temporal Validation
                            │
                            ▼
                   Physical Validation
                            │
                            ▼
                 Measurement Confidence
                            │
                            ▼
                   Accepted Measurement
                            │
                            ▼
                          CSV
```

The system should support three primary recognition modes.

## Mode 1 — Known Instrument Profile

The user selects a specific instrument model.

Example:

```text
Instrument:
Fluke 87V
```

The application loads an instrument profile containing:

- Display geometry
- Number of digit positions
- Decimal locations
- Sign position
- Unit indicators
- Range indicators
- Overrange indicators
- Low battery indicator
- Display type
- Seven-segment/LCD characteristics
- Expected numeric formats
- Valid measurement ranges

The recognition engine can then use a specialized pipeline.

```text
Fluke 87V Profile
       │
       ▼
Known Display Geometry
       │
       ▼
Known Digit Positions
       │
       ▼
Digit Recognition
       │
       ▼
Format Validation
       │
       ▼
Physical Validation
```

This should provide the highest possible reliability.

## Mode 2 — User-Configured Display Format

The user manually configures the display.

Example:

```text
Digits: 5
Decimal: After digit 2
Sign: Optional
Unit: V
Range: -20 to +20 V
```

The application generates a recognition grammar:

```text
[sign?][digit][digit].[digit][digit][digit]
```

Valid examples:

```text
12.347
-1.234
19.999
```

Invalid examples:

```text
1A.34B
12..34
123.4567
12.34.7
```

The recognition engine should reject or flag impossible outputs.

## Mode 3 — Unknown Instrument

For an unknown instrument:

```text
Camera
   ↓
Display Detection
   ↓
General OCR
   ↓
Format Inference
   ↓
Proposed Format
   ↓
User Confirmation
   ↓
Constrained Recognition
```

Example:

```text
Detected format:

[sign] XX.XXX [unit]

Confidence: 98%

[ Confirm ] [ Edit ]
```

Once confirmed, the application should switch from general OCR to the constrained recognition pipeline.

---

# 5. MVP

Build the smallest useful product first.

## MVP Workflow

```text
User opens app
      ↓
Camera preview
      ↓
User points camera at instrument
      ↓
User selects display region (ROI)
      ↓
User configures or confirms display format
      ↓
App recognizes displayed value
      ↓
Live numeric value shown
      ↓
User starts recording
      ↓
Measurements captured with timestamps
      ↓
Temporal + format + physical validation
      ↓
User stops recording
      ↓
Results displayed as graph/table
      ↓
CSV exported
```

### MVP Scope

Implement:

- iOS first
- Swift
- SwiftUI
- AVFoundation
- Apple Vision OCR initially
- Manual display ROI selection
- User-configurable numeric format
- Numeric value extraction
- Timestamped measurement records
- Confidence scoring
- Temporal filtering
- Basic physical/range validation
- CSV export
- Basic graphing

Do NOT initially implement:

- Android
- Cloud processing
- User accounts
- Authentication
- Backend
- Payments
- Automatic instrument classification
- Full universal OCR
- 240 FPS OCR processing

---

# 6. Initial iOS Development Strategy

Start natively in Xcode.

Technology:

- Xcode
- Swift
- SwiftUI
- AVFoundation

The first architecture:

```text
SwiftUI
    │
    ├── Camera UI
    ├── ROI selection
    ├── Format configuration
    ├── Live reading
    ├── Graph
    ├── Results
    └── CSV export
          │
          ▼
Native Processing
    │
    ├── AVFoundation
    ├── Vision
    ├── Core ML / ONNX Runtime
    ├── Metal
    └── Temporal Processing
```

Do not begin with Flutter or React Native.

The initial goal is to validate the vision and data acquisition pipeline on real iPhone hardware.

---

# 7. Phase 1 — iOS Camera Prototype

Implement:

```text
AVCaptureSession
      ↓
Camera
      ↓
CMSampleBuffer
      ↓
CVPixelBuffer
```

Verify:

- Camera permissions
- Camera initialization
- Correct orientation
- Camera resolution
- Frame capture
- Frame timestamps
- Exposure behavior
- Focus behavior

The first success criterion is:

> A live iPhone camera preview displaying a physical DMM or scientific instrument.

---

# 8. Phase 2 — Basic OCR

Initially use:

- Apple Vision
- VNRecognizeTextRequest

Pipeline:

```text
AVFoundation
      ↓
CMSampleBuffer
      ↓
CVPixelBuffer
      ↓
Vision OCR
      ↓
Recognized Text
```

Goal:

```text
Detected: 12.347 V
```

The purpose of this phase is validation, not optimization.

Test:

- Lighting
- Distance
- Viewing angle
- Display size
- Glare
- Reflections
- Motion
- Focus

---

# 9. Phase 3 — Region of Interest

Allow the user to define the instrument display.

```text
┌─────────────────────────────┐
│       Instrument            │
│                             │
│     ╔═══════════════╗       │
│     ║   12.347 V    ║       │
│     ╚═══════════════╝       │
│                             │
└─────────────────────────────┘
```

Only process the selected ROI.

The ROI should be stored using normalized coordinates so that it adapts to:

- Camera resolution
- Device orientation
- Cropping
- Video stabilization

Benefits:

- Faster inference
- Fewer false positives
- Lower CPU/GPU/ANE usage
- Easier OCR
- Better accuracy

---

# 10. Phase 4 — Display Format Configuration

After selecting the ROI, allow the user to specify:

```text
Display Type:
[ Seven Segment ▼ ]

Number of Digits:
[ 5 ]

Decimal Position:
[ After digit 2 ]

Sign:
[ Optional ]

Unit:
[ V ]

Minimum:
[ -20 ]

Maximum:
[ +20 ]
```

The app should construct a formal display grammar.

Example:

```text
[sign?][digit][digit].[digit][digit][digit]
```

Represent this internally as a structured format rather than a plain string.

Example:

```swift
struct DisplayFormat {
    let digitCount: Int
    let decimalPosition: Int?
    let signAllowed: Bool
    let unit: String?
    let minimumValue: Double?
    let maximumValue: Double?
}
```

The format configuration should be reusable and saveable as an instrument profile.

---

# 11. Phase 5 — Digit-by-Digit Recognition

Whenever possible, recognize digits independently.

Instead of:

```text
Image
   ↓
"12.347"
```

prefer:

```text
Image
   ↓
Digit Segmentation
   ↓
┌────┬────┬────┬────┬────┐
│ 1  │ 2  │ 3  │ 4  │ 7  │
└────┴────┴────┴────┴────┘
```

Then reconstruct:

```text
12.347
```

This allows confidence to be tracked per digit.

Example:

```text
Digit 1: 1 — 99.9%
Digit 2: 2 — 99.8%
Digit 3: 3 — 99.7%
Digit 4: 4 — 98.2%
Digit 5: 7 — 99.9%
```

If one digit is uncertain, temporal information from surrounding frames can resolve it.

---

# 12. Seven-Segment Display Recognition

For seven-segment displays, investigate replacing general OCR with segment recognition.

Seven-segment structure:

```text
  ─── a ───
 │         │
 f         b
 │         │
  ─── g ───
 │         │
 e         c
 │         │
  ─── d ───
```

Each digit maps to a known segment pattern.

Example conceptual mapping:

```text
0 → a b c d e f
1 → b c
2 → a b d e g
3 → a b c d g
...
```

Potential pipeline:

```text
Camera
   ↓
Display ROI
   ↓
Perspective Correction
   ↓
Fixed Digit Locations
   ↓
Segment Detection
   ↓
7-bit Segment Pattern
   ↓
Digit Lookup
   ↓
Numeric Reconstruction
```

A tiny classifier could potentially process each digit:

```text
Input:
32 × 48 pixels

Output:
0–9
```

This may be substantially faster and more deterministic than general OCR.

---

# 13. Specialized OCR Model

Investigate training a specialized digit recognition model.

Possible architecture:

```text
Camera
   ↓
Display ROI
   ↓
Digit Segmentation
   ↓
Tiny Digit Classifier
   ↓
Numeric Reconstruction
   ↓
Temporal Validation
```

Allowed characters may be restricted to:

```text
0 1 2 3 4 5 6 7 8 9
-
.
```

Benefits:

- Faster
- Lower power
- More deterministic
- Better for compressed video
- Easier to validate
- Potentially better Neural Engine performance

Use general-purpose OCR as a fallback for unknown displays.

---

# 14. OCR Engine Evaluation

Evaluate OCR engines in stages.

## Stage 1

Apple Vision OCR.

Purpose:

- Rapid prototype
- Validate concept
- Establish baseline

## Stage 2

PP-OCRv6.

Evaluate:

- PP-OCRv6 Tiny
- PP-OCRv6 Small

Potential deployment:

```text
PP-OCRv6
    ↓
ONNX
    ↓
ONNX Runtime
    ↓
iOS: Core ML Execution Provider
Android: NNAPI / GPU acceleration
```

Important:

Do not assume that using Core ML or ONNX Runtime automatically means all operations execute on Apple's Neural Engine.

Benchmark actual execution and fallback behavior.

Measure:

- FPS
- Latency
- CPU usage
- GPU usage
- Memory
- Battery
- Thermal behavior
- ANE utilization where measurable

---

# 15. Recommended Recognition Architecture

The final recognition system should ideally support:

```text
                    Camera
                       │
                       ▼
               Display Detection
                       │
                       ▼
                 ROI Tracking
                       │
                       ▼
             Instrument Identification
                       │
          ┌────────────┴────────────┐
          │                         │
    Known Instrument          Unknown Instrument
          │                         │
          ▼                         ▼
    Load Profile               General OCR
          │                         │
          ▼                         ▼
    Known Format              Format Inference
          │                         │
          └────────────┬────────────┘
                       │
                       ▼
              Constrained Recognition
                       │
                       ▼
               Digit-Level Confidence
                       │
                       ▼
                Format Validation
                       │
                       ▼
               Temporal Validation
                       │
                       ▼
                Physical Validation
                       │
                       ▼
              Final Confidence Score
                       │
                       ▼
              Accepted Measurement
```

---

# 16. Temporal Processing

Do not treat each OCR frame as independent ground truth.

Example:

```text
Frame 1 → 12.347
Frame 2 → 12.347
Frame 3 → 12.34?
Frame 4 → 12.347
Frame 5 → 12.347
```

Expected output:

```text
12.347
Confidence: Very High
```

Perform temporal analysis at the **digit level** whenever possible.

Example:

```text
Position 1:
1 1 1 1 1 → 1

Position 2:
2 2 2 2 2 → 2

Position 3:
3 3 3 ? 3 → 3

Position 4:
4 4 4 4 4 → 4

Position 5:
7 7 ? 7 7 → 7
```

Result:

```text
12.347
```

Potential methods:

- Majority voting
- Confidence-weighted voting
- Median filtering
- Kalman filtering
- Change-point detection
- Temporal consistency scoring
- Display refresh detection

Do not smooth data in a way that destroys real measurement transitions.

Example:

```text
12.000
12.001
12.002
13.000
13.001
```

The transition from 12 V to 13 V must remain detectable.

---

# 17. Physical Validation

The system should use known physical constraints to reject implausible readings.

Example:

```text
Previous reading: 12.347 V
New OCR result:   82.347 V
Configured range: -20 V to +20 V
```

Result:

```text
⚠️ Invalid reading
```

Another example:

```text
Previous: 12.347
New:      12.348
```

This is likely plausible.

Implement a validation pipeline:

```text
Raw Image
    ↓
Digit Recognition
    ↓
Format Validation
    ↓
Range Validation
    ↓
Temporal Consistency
    ↓
Rate-of-Change Validation
    ↓
Confidence Score
    ↓
Accepted / Rejected
```

The system should prioritize:

> **Rejecting an uncertain reading over accepting an incorrect reading.**

---

# 18. Measurement Data Model

Use a measurement structure similar to:

```swift
struct Measurement {
    let timestamp: TimeInterval
    let value: Double
    let unit: String?
    let confidence: Float
    let accepted: Bool
    let rejectionReason: String?
}
```

Prefer monotonic capture timestamps for sequencing.

Wall-clock timestamps can be stored separately for experiment metadata.

Potential rejection reasons:

```text
LOW_OCR_CONFIDENCE
INVALID_FORMAT
OUT_OF_RANGE
TEMPORAL_INCONSISTENCY
EXCESSIVE_RATE_OF_CHANGE
AMBIGUOUS_DIGIT
DISPLAY_LOST
```

---

# 19. Confidence Architecture

Calculate confidence from multiple independent sources.

Example:

```text
OCR Confidence:       99.2%
Format Validity:      100%
Range Validity:       100%
Temporal Consistency: 98.7%
Rate-of-Change:       100%

Final Confidence:     99.8%
```

The final confidence should not simply be the raw OCR model confidence.

Investigate a weighted confidence model:

```text
FinalConfidence =
    OCRConfidence
    × FormatValidity
    × PhysicalValidity
    × TemporalConsistency
```

The exact formula should be empirically validated.

---

# 20. Camera Frame Rate vs Measurement Rate

The application should explicitly distinguish:

```text
Camera Capture Rate
        ≠
OCR Processing Rate
        ≠
Display Refresh Rate
        ≠
Measurement Change Rate
```

Support high-frame-rate camera modes where hardware permits:

- 60 FPS
- 120 FPS
- 240 FPS

But do not assume OCR must execute at the camera's full frame rate.

Possible architecture:

```text
Camera Capture
      │
      ├── 240 FPS
      │
      ├── Process selected frames
      │
      └── Temporal reconstruction
```

Test OCR rates:

- 10 FPS
- 15 FPS
- 30 FPS
- 60 FPS
- 120 FPS

Determine whether additional frames provide meaningful information.

---

# 21. High-Speed / Slow-Motion Video

The application should support two acquisition modes.

## Live Mode

```text
Camera
   ↓
Real-time OCR
   ↓
Temporal Validation
   ↓
Live Measurement Stream
```

## High-Speed Recording Mode

```text
240 FPS Camera
      ↓
High-Speed Recording
      ↓
Frame-by-Frame / Selective Processing
      ↓
Temporal Reconstruction
      ↓
High-Resolution Measurement Timeline
```

High-speed recordings should preserve original frame timestamps where possible.

The system should be able to determine whether a visual change represents:

- A true display update
- Camera motion
- Blur
- Compression artifact
- OCR error
- Partial LCD refresh

---

# 22. Highly Compressed Video

Test against:

- H.264
- HEVC/H.265
- High compression
- Low bitrate
- Motion blur
- Chroma subsampling
- Block artifacts
- Ringing
- Glare
- Reflections

Investigate preprocessing:

- ROI cropping
- Sharpening
- Contrast enhancement
- Denoising
- Upscaling
- Super-resolution
- Multi-frame fusion

Temporal redundancy may be more valuable than processing every frame independently.

Example:

```text
Frame 100 → 12.347
Frame 101 → 12.347
Frame 102 → 12.34?
Frame 103 → 12.347
Frame 104 → 12.347
```

Expected reconstruction:

```text
12.347
Confidence: Very High
```

---

# 23. Instrument Profiles

Create a reusable instrument profile system.

Example conceptual profile:

```json
{
  "manufacturer": "Example",
  "model": "Example DMM",
  "displayType": "seven_segment",
  "digitCount": 5,
  "decimalPositions": [2],
  "signAllowed": true,
  "units": ["V", "A", "Ω"],
  "range": {
    "min": -20,
    "max": 20
  }
}
```

Profiles should eventually include:

- Display geometry
- Digit positions
- Decimal positions
- Sign position
- Unit locations
- Range indicator locations
- Battery indicator
- Overrange indicator
- Display refresh characteristics
- Expected digit font
- Segment geometry
- Instrument-specific quirks

Profiles should be versioned and extensible.

---

# 24. Automatic Format Inference

For unknown instruments:

```text
Camera
   ↓
General OCR
   ↓
Recognized text samples
   ↓
Repeated pattern analysis
   ↓
Infer fixed digit count
   ↓
Infer decimal position
   ↓
Infer optional sign
   ↓
Infer unit
   ↓
Propose format
```

Example:

```text
Observed:

12.347 V
12.348 V
12.349 V
12.350 V

Inferred:

Digits: 5
Decimal: After digit 2
Unit: V
Sign: Unknown
```

Ask the user to confirm.

Once confirmed:

```text
General OCR
      ↓
Format-Aware Recognition
```

---

# 25. CSV Export

Support:

- CSV
- JSON

Initial CSV:

```csv
timestamp,value,unit,confidence,accepted
0.000,12.341,V,0.998,true
0.033,12.342,V,0.997,true
0.067,12.342,V,0.999,true
```

Optionally export rejected readings separately:

```csv
timestamp,raw_value,confidence,rejection_reason
0.100,82.347,0.82,out_of_range
```

This is valuable for scientific traceability.

Future formats:

- Excel-compatible CSV
- JSON
- MATLAB
- Python/pandas-compatible output

---

# 26. iOS Project Structure

Suggested project structure:

```text
InstrumentLogger/
│
├── App/
│   └── InstrumentLoggerApp.swift
│
├── Camera/
│   ├── CameraManager.swift
│   ├── CameraPreview.swift
│   ├── FrameProcessor.swift
│   └── HighSpeedCapture.swift
│
├── Display/
│   ├── DisplayDetector.swift
│   ├── ROITracker.swift
│   ├── PerspectiveCorrection.swift
│   └── DigitSegmenter.swift
│
├── OCR/
│   ├── OCRManager.swift
│   ├── VisionOCR.swift
│   ├── PaddleOCR.swift
│   ├── DigitRecognizer.swift
│   └── SevenSegmentRecognizer.swift
│
├── Instruments/
│   ├── InstrumentProfile.swift
│   ├── InstrumentProfileStore.swift
│   └── FormatInference.swift
│
├── Processing/
│   ├── TemporalFilter.swift
│   ├── ConfidenceEngine.swift
│   ├── FormatValidator.swift
│   ├── PhysicalValidator.swift
│   └── MeasurementProcessor.swift
│
├── Data/
│   ├── Measurement.swift
│   ├── Experiment.swift
│   ├── MeasurementStore.swift
│   └── CSVExporter.swift
│
└── UI/
    ├── CameraView.swift
    ├── ROISelectionView.swift
    ├── FormatConfigurationView.swift
    ├── ExperimentView.swift
    └── ResultsView.swift
```

---

# 27. Android Architecture

After the iOS prototype is validated:

```text
Android
    │
    ├── Kotlin
    ├── Jetpack Compose
    ├── CameraX
    ├── ONNX Runtime
    ├── NNAPI
    └── GPU acceleration
```

Use the same ONNX model where possible.

Conceptually:

```text
                 Shared ONNX Model
                        │
               ┌────────┴────────┐
               │                 │
              iOS             Android
               │                 │
       ONNX Runtime          ONNX Runtime
       Core ML EP             NNAPI / GPU
               │                 │
             iPhone          Android device
```

Share where practical:

- OCR model
- Image preprocessing
- Temporal processing
- Format validation
- Physical validation
- Measurement reconstruction
- Confidence logic
- Data schema
- CSV format
- Instrument profile schema

Camera implementations will remain platform-specific.

---

# 28. Cross-Platform Framework Strategy

Do not immediately build the entire application in Flutter or React Native.

The computational core should be native or shared.

Recommended eventual architecture:

```text
Flutter / Native UI
        │
        ▼
Platform Bridge
        │
 ┌──────┴──────┐
 │             │
iOS          Android
 │             │
Swift       Kotlin
 │             │
 └──────┬──────┘
        │
Shared OCR/Data Core
        │
  C++ / Rust / ONNX
```

For the initial proof-of-concept:

> Use native Swift + SwiftUI in Xcode.

Once the iOS pipeline works, determine whether the UI should remain native or move to Flutter.

---

# 29. Benchmarking

Create a formal benchmark suite.

## Devices

Initial target:

- iPhone 13 Pro or newer

Later:

- Multiple iPhone generations
- Multiple Android SoCs

## Camera Modes

- 30 FPS
- 60 FPS
- 120 FPS
- 240 FPS

## Recognition Modes

- Apple Vision
- PP-OCRv6 Tiny
- PP-OCRv6 Small
- Specialized digit model
- Seven-segment recognition

## Metrics

Measure:

- Measurement accuracy
- Accepted-reading accuracy
- False reading rate
- Rejected-reading rate
- Digit-level accuracy
- Format recognition accuracy
- Frame processing rate
- End-to-end latency
- CPU usage
- GPU usage
- ANE/NPU utilization
- RAM
- Battery consumption
- Thermal throttling

The most important metric is:

> **Incorrect measurement rate.**

A system that produces 100 readings/sec but occasionally produces a completely incorrect value may be worse than one producing 20 highly reliable readings/sec.

Track:

- True Positive
- False Positive
- True Rejection
- False Rejection

---

# 30. Dataset Creation

Create a dataset using real instruments.

Initial target:

- 10+ digital multimeters
- Multiple display types
- Different fonts
- Different seven-segment implementations
- Different LCDs

Record:

- Stable values
- Rapidly changing values
- Negative values
- Decimal changes
- Auto-ranging
- Overrange
- Low battery indicators
- Different display brightness levels
- Different viewing angles
- Glare
- Reflections
- Motion
- Compression

Dataset structure:

```text
dataset/
├── videos/
│   ├── dmm_001.mov
│   ├── dmm_002.mov
│   └── dmm_003.mov
│
└── labels/
    ├── dmm_001.csv
    ├── dmm_002.csv
    └── dmm_003.csv
```

Create ground truth manually or by connecting the instrument to a trusted digital interface when available.

---

# 31. Ground Truth and Validation

For serious testing, use a trusted reference source.

Example:

```text
Instrument
   │
   ├── Physical Display → Smartphone OCR
   │
   └── Digital Interface → Ground Truth
```

Compare:

```text
OCR Result
vs
Actual Instrument Data
```

Calculate:

- Exact reading accuracy
- Digit error rate
- Timestamp error
- Detection latency
- Missed transitions
- False transitions

This should become the basis of automated regression tests.

---

# 32. Commercial Product Vision

Position the product as:

> **Visual Data Acquisition**

rather than simply:

> OCR for Multimeters

Potential tagline:

> **Turn any instrument display into a digital data stream.**

Target users:

- Electronics engineers
- Electrical engineers
- Research labs
- Universities
- Field technicians
- QA/QC
- Industrial maintenance
- Manufacturing
- Scientific research
- Legacy equipment users

Potential future instruments:

```text
Multimeter
   ↓
Bench Power Supply
   ↓
Oscilloscope
   ↓
Thermometer
   ↓
Pressure Gauge
   ↓
Scale
   ↓
Scientific Instrument
   ↓
Industrial Equipment
```

---

# 33. Potential Product Features

## Core

- Live OCR
- ROI selection
- Format configuration
- Instrument profiles
- Measurement recording
- CSV export
- JSON export
- Live graph
- Experiment history

## Advanced

- 240 FPS recording
- High-speed post-processing
- Temporal reconstruction
- Confidence scoring
- Automatic display detection
- Multiple displays
- Unit detection
- Auto-ranging detection
- Instrument templates
- Automatic format inference

## Professional

- Batch processing
- API
- MATLAB export
- Python export
- Custom OCR models
- Custom instrument templates
- Local/offline processing
- Enterprise deployment
- Ground-truth comparison

---

# 34. Privacy and Deployment Principle

Prefer on-device processing.

Ideal architecture:

```text
Camera
   ↓
On-device OCR
   ↓
On-device processing
   ↓
CSV
```

Optional:

```text
On-device real-time processing
          +
Optional desktop/cloud
high-accuracy post-processing
```

Cloud processing should never be mandatory for basic functionality.

Advantages:

- Laboratory use
- Industrial environments
- Sensitive environments
- Offline field work
- Privacy
- Lower latency

---

# 35. Immediate Development Plan

## Milestone 1 — Camera

Create Xcode project.

Implement:

```text
SwiftUI
+
AVFoundation
```

Goal:

> Live camera preview.

## Milestone 2 — Vision OCR

Implement:

```text
Vision OCR
```

Goal:

> Read a DMM display.

## Milestone 3 — ROI

Implement:

```text
Manual ROI selection
```

Goal:

> OCR only the instrument display.

## Milestone 4 — Format Configuration

Implement:

```text
Digit count
Decimal position
Sign
Unit
Range
```

Goal:

> Constrain recognition to a known format.

## Milestone 5 — Digit-Level Recognition

Implement:

```text
Digit segmentation
+
Digit classification
```

Goal:

> Recognize each digit independently.

## Milestone 6 — Measurement Validation

Implement:

```text
Format validation
+
Range validation
+
Temporal validation
+
Rate-of-change validation
```

Goal:

> Prevent incorrect measurements from entering the dataset.

## Milestone 7 — CSV

Implement:

```text
Measurement struct
+
Timestamp
+
Confidence
+
CSV export
```

Goal:

> Generate a valid measurement CSV.

## Milestone 8 — Temporal Fusion

Implement:

```text
Multi-frame digit fusion
```

Goal:

> Resolve uncertain OCR results using neighboring frames.

## Milestone 9 — OCR Benchmark

Benchmark:

```text
Vision
vs
PP-OCRv6 Tiny
vs
PP-OCRv6 Small
vs
Specialized Digit Model
vs
Seven-Segment Recognition
```

Goal:

> Determine the best recognition architecture.

## Milestone 10 — On-Device Acceleration

Implement:

```text
ONNX Runtime
+
Core ML Execution Provider
```

Goal:

> Evaluate on-device hardware acceleration.

Benchmark actual hardware execution.

## Milestone 11 — Specialized Model

Create:

```text
Seven-Segment / LCD Digit Model
```

Goal:

> Maximize speed and accuracy.

## Milestone 12 — High-Speed Acquisition

Implement:

```text
High-speed camera capture
+
Temporal reconstruction
```

Goal:

> Extract reliable measurement transitions from slow-motion recordings.

## Milestone 13 — Instrument Profiles

Implement:

```text
Instrument Profile System
```

Goal:

> Automatically configure recognition for known instrument models.

## Milestone 14 — Automatic Format Inference

Implement:

```text
Unknown Display
      ↓
General OCR
      ↓
Format Inference
      ↓
User Confirmation
      ↓
Constrained Recognition
```

Goal:

> Transition unknown instruments into a high-accuracy constrained mode.

## Milestone 15 — Android

Implement:

```text
CameraX
+
ONNX Runtime
+
NNAPI/GPU
```

Goal:

> Cross-platform feature parity.

---

# 36. Critical Engineering Principles

### Principle 1

Do not confuse camera FPS with measurement sampling rate.

### Principle 2

Do not trust a single OCR frame.

### Principle 3

Use known display structure whenever possible.

### Principle 4

Treat format knowledge as a core recognition input.

### Principle 5

Recognize digits independently when practical.

### Principle 6

Use temporal consistency to resolve uncertain digits.

### Principle 7

Use physical constraints to reject impossible measurements.

### Principle 8

Prefer rejecting uncertain data over accepting incorrect data.

### Principle 9

Optimize for measurement correctness, not OCR throughput.

### Principle 10

Use specialized digit recognition for structured displays.

### Principle 11

Use general OCR as a fallback for unknown instruments.

### Principle 12

Benchmark actual Neural Engine/NPU execution.

### Principle 13

Keep data acquisition on-device by default.

### Principle 14

Build the iOS proof-of-concept before investing in cross-platform infrastructure.

### Principle 15

Validate against independent ground truth.

### Principle 16

Do not assume every visual display update represents a new physical measurement.

---

# 37. First Development Task

Create an Xcode project called:

```text
InstrumentLogger
```

Target:

```text
iOS 17+
```

Implement:

```text
Camera
  ↓
Live Preview
  ↓
Vision OCR
  ↓
User-selected ROI
  ↓
User-configured numeric format
  ↓
Extract numeric measurement
  ↓
Format validation
  ↓
Live value display
```

Do not implement PP-OCRv6 yet.

Do not implement Android yet.

Do not implement a backend.

Do not implement authentication.

Do not implement payments.

The first success criterion is:

> **Point an iPhone at a physical digital multimeter, select the display, define or confirm its format, and reliably display the current measurement on the phone screen.**

After that succeeds, implement timestamped measurement recording and CSV export.

---

# 38. Definition of Done for MVP

The MVP is successful when the following workflow works end-to-end:

```text
1. Launch app
2. Grant camera permission
3. Point camera at DMM
4. Select display ROI
5. Configure or confirm display format
6. App recognizes individual digits
7. App reconstructs numeric value
8. Format validation passes
9. Physical/range validation passes
10. Live value appears on screen
11. Press Record
12. Measurement values are captured
13. Timestamp assigned to each accepted reading
14. Temporal validation removes obvious OCR errors
15. Uncertain readings are rejected or flagged
16. Stop recording
17. Display measurement graph
18. Export CSV
19. Reopen CSV in Excel/Python
20. Values correspond to actual instrument display
```

Target initial accuracy:

> **≥99% correct accepted measurements on a controlled DMM setup**

Track separately:

- Correct readings
- Rejected/uncertain readings
- Incorrect readings

A **rejected reading is preferable to an incorrect measurement**.

---

# 39. Long-Term Vision

The ultimate product should become:

> **A universal visual instrument data acquisition platform.**

Conceptually:

```text
Any Instrument
      │
      ▼
Smartphone Camera
      │
      ▼
Display Detection
      │
      ▼
Instrument / Format Identification
      │
      ▼
Format-Aware OCR
      │
      ▼
Digit-Level Recognition
      │
      ▼
Temporal Reconstruction
      │
      ▼
Physical Validation
      │
      ▼
Validated Measurement Stream
      │
      ├── CSV
      ├── JSON
      ├── Excel
      ├── Python
      ├── MATLAB
      └── API
```

The key product differentiation is not simply OCR.

It is:

> **Converting visual instrument displays into trustworthy, timestamped measurement data by combining computer vision, constrained OCR, instrument knowledge, temporal inference, and physical validation.**

The central technical thesis is:

> **The more the application knows about the instrument and display format, the less it needs to rely on general-purpose OCR.**
