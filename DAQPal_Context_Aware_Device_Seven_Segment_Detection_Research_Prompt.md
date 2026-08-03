# ULTRACODE RESEARCH & IMPLEMENTATION PROMPT

## DAQPal Context-Aware Device and Seven-Segment Display Detection Architecture

### ROLE

Act as a senior computer-vision researcher, iOS ML engineer, OCR systems architect, and performance engineer.

You are working on **DAQPal**, an iOS application that reads numerical information from physical measurement instruments using the iPhone camera.

The current application is capable of OCR processing and has an interactive capture-window system that allows the user to select individual numeric regions.

The next architectural question is:

> Should DAQPal evolve from a generic OCR system that detects numerical content into a context-aware visual recognition system that first identifies the physical measurement device, then identifies the device's associated display window, and only then performs OCR?

The goal is to prevent DAQPal from incorrectly locking onto unrelated numbers such as:

* Numbers printed on paper
* Textbook pages
* Labels
* Product packaging
* Signs
* Posters
* Computer screens
* Phone screens
* Other nearby devices
* Random seven-segment-like patterns
* Numbers elsewhere in the camera frame

Instead, DAQPal should preferentially identify:

> "This is a measurement device → this is the device's display → this is the numerical region belonging to that device → this is the value to OCR."

The objective of this task is NOT to immediately implement the solution.

The first objective is to conduct a rigorous research and architecture investigation to determine whether this approach is actually worthwhile, which methods are most appropriate, and how they can be integrated into DAQPal with minimal computational overhead.

---

# PART 1 — CURRENT DAQPAL ARCHITECTURE AUDIT

Before proposing a solution, inspect the entire DAQPal repository.

Determine:

* Current camera pipeline
* AVCaptureSession architecture
* Video frame processing rate
* Preview rendering pipeline
* OCR pipeline
* Vision framework usage
* Core ML usage
* Existing object detection
* Existing image classification
* Existing seven-segment detection
* Existing display detection
* Existing quadrilateral detection
* Existing homography/perspective correction
* Existing tracking
* Existing capture-window logic
* Existing coordinate transformations
* Existing digit selection
* Existing CSV data pipeline
* Existing test architecture
* Existing 733+ test baseline

Do not duplicate existing functionality.

Document:

1. What currently detects numbers.
2. What currently detects the display.
3. What currently tracks the display.
4. What currently determines the capture region.
5. Whether the existing architecture already has enough context to support device-aware detection.

Run the complete existing test suite before making modifications.

Record the actual baseline.

---

# PART 2 — DEFINE THE CORE COMPUTER-VISION PROBLEM

Formalize the problem as a hierarchical perception pipeline.

Investigate whether DAQPal should use:

```text
Camera Frame
    ↓
Scene Understanding
    ↓
Device / Instrument Detection
    ↓
Device Tracking
    ↓
Associated Display-Window Detection
    ↓
Display Geometry / Quadrilateral Detection
    ↓
Perspective Rectification
    ↓
Seven-Segment / Digit Region Detection
    ↓
OCR
    ↓
Semantic Validation
    ↓
Measurement Value
```

Compare this against simpler alternatives:

### Architecture A

```text
Camera
↓
OCR
```

### Architecture B

```text
Camera
↓
Generic Display Detection
↓
OCR
```

### Architecture C

```text
Camera
↓
Seven-Segment Detection
↓
OCR
```

### Architecture D

```text
Camera
↓
Device Detection
↓
Generic Display Detection
↓
OCR
```

### Architecture E

```text
Camera
↓
Device Detection
↓
Device-Specific Display Window
↓
Homography
↓
Seven-Segment Detection
↓
OCR
```

### Architecture F

```text
Camera
↓
Vision Classifier
↓
Device Class
↓
Expected Display Location
↓
Display Detection
↓
Tracking
↓
OCR
```

Determine which architecture provides the best balance of:

* Accuracy
* False-positive resistance
* Latency
* CPU usage
* GPU usage
* Neural Engine usage
* Battery consumption
* Model size
* Development complexity
* Generalization
* Maintainability

---

# PART 3 — RESEARCH FIRST: ARXIV AND COMPUTER-VISION LITERATURE

Before implementing anything, perform a structured literature review.

Search:

* arXiv
* IEEE Xplore where accessible
* ACM Digital Library where accessible
* CVPR publications
* ICCV publications
* ECCV publications
* OpenReview
* Papers With Code
* Google Scholar where accessible
* Apple machine-learning documentation
* Apple Vision framework documentation
* Core ML documentation
* Relevant GitHub repositories
* Open-source computer-vision projects

The research should specifically investigate:

## A. Object detection

Research modern lightweight object detectors suitable for iOS.

Investigate:

* YOLO-family models
* MobileNet-based detectors
* EfficientDet
* SSD
* RT-DETR variants
* Other mobile-friendly detectors

Determine which architectures are practical for:

* iPhone CPU
* GPU
* Neural Engine
* Core ML

---

## B. Image classification

Investigate whether a broad device classifier could identify:

* Digital multimeter
* Infrared thermometer
* Oscilloscope
* Bench power supply
* Clamp meter
* Scientific instrument
* Measurement equipment

Compare:

* Image classification
* Object detection
* Instance segmentation

Determine whether classification alone is sufficient to provide useful context.

---

## C. Device + display relationship detection

Investigate methods that explicitly model relationships between objects.

Research:

* Object detection with contextual reasoning
* Scene graphs
* Object-part detection
* Hierarchical object detection
* Compositional recognition
* Part-based models
* Keypoint detection
* Instance segmentation
* Affordance detection
* Region proposal methods

The key question is:

> Can DAQPal identify that a specific display region belongs to a specific physical device?

Determine whether a hierarchical detector is superior to independently detecting:

```text
Device
Display
```

---

## D. Display-window localization

Research methods for locating display windows on physical instruments.

Investigate:

* Object detection
* Semantic segmentation
* Instance segmentation
* Corner/keypoint detection
* Quadrilateral detection
* Homography estimation
* Perspective transformation
* Planar object detection
* Template matching
* Feature matching
* ORB
* SIFT where licensing/availability permits
* SuperPoint/SuperGlue-style methods
* Learned keypoint detectors

Determine which approach is best for:

> "Find the physical display window belonging to this device."

---

## E. Seven-segment display detection

Research:

* Seven-segment digit detection
* LCD digit recognition
* Seven-segment OCR
* Segment-level recognition
* Digit topology recognition
* Display-region segmentation
* Decimal-point detection
* Seven-segment display datasets

Investigate whether it is better to:

### Option 1

Detect the entire display and run OCR.

### Option 2

Detect individual digits.

### Option 3

Detect individual seven-segment components.

### Option 4

Use a specialized seven-segment recognition model.

### Option 5

Use a hybrid approach:

```text
Display Detector
↓
Digit Segmentation
↓
Seven-Segment Recognition
↓
OCR fallback
```

---

# PART 4 — RESEARCH DATASETS

Identify publicly available datasets relevant to:

* Digital displays
* Instrument recognition
* Meter reading
* Seven-segment displays
* LCD displays
* Industrial equipment
* Scientific instruments
* Scene text
* Object detection
* Display localization

For each dataset determine:

* License
* Number of images
* Device categories
* Annotation type
* Display annotations
* Digit annotations
* Perspective variation
* Lighting variation
* Suitability for DAQPal

Determine whether a custom DAQPal dataset will ultimately be required.

---

# PART 5 — INVESTIGATE THE "DEVICE CONTEXT" HYPOTHESIS

Test the hypothesis:

> A model that understands the physical device context will produce significantly fewer false OCR locks than a generic OCR/display detector.

Design an experiment comparing:

### Test Group A

Generic OCR.

### Test Group B

Generic seven-segment detector.

### Test Group C

Generic display detector + OCR.

### Test Group D

Device classifier + OCR.

### Test Group E

Device detector + display detector + OCR.

### Test Group F

Device detector + expected display-window localization + OCR.

### Test Group G

Device detection + display detection + geometric tracking + OCR + semantic validation.

Test against adversarial scenes containing:

* Textbooks
* Newspapers
* Printed numbers
* Handwritten numbers
* Labels
* Signs
* Packaging
* Multiple devices
* Multiple displays
* Phone screens
* Computer monitors
* Random seven-segment-like patterns

Measure:

* False lock rate
* Correct lock rate
* Time to first correct lock
* Lock stability
* Reacquisition time
* OCR accuracy
* Decimal accuracy
* Device classification accuracy

The key metric is:

> How often does DAQPal lock onto the correct physical instrument and its associated display instead of an unrelated numeric region?

---

# PART 6 — INVESTIGATE DEVICE-SPECIFIC DISPLAY PRIORS

Determine whether DAQPal can exploit prior knowledge.

For example:

```text
Device Class:
Digital Multimeter

Expected Display:
Large rectangular LCD
Typically near upper portion of device
High contrast
Seven-segment digits
Possible unit indicators

Device Class:
IR Temperature Gun

Expected Display:
Small rectangular LCD
Typically near rear/top housing
Seven-segment temperature digits
Potential decimal point
Temperature unit indicator

Device Class:
Bench Power Supply

Expected Display:
One or more rectangular display regions
Potentially multiple independent numeric values
Voltage/current/power labels
```

Investigate whether this information can be represented as:

* Bounding-box priors
* Relative coordinates
* Keypoints
* Templates
* Learned embeddings
* Device-specific models
* Device-specific segmentation heads

Determine whether this improves robustness enough to justify implementation complexity.

---

# PART 7 — INVESTIGATE A HYBRID MODEL

Evaluate the following architecture:

```text
                    Camera Frame
                         │
                         ▼
                Lightweight Device
                   Object Detector
                         │
                         ▼
                  Device Tracking
                         │
                         ▼
             Device-Specific ROI Prior
                         │
                         ▼
             Display Window Detector
                         │
                         ▼
           Quadrilateral / Keypoint Model
                         │
                         ▼
              Homography Rectification
                         │
                         ▼
            Seven-Segment Digit Detector
                         │
                         ▼
                OCR / Recognition
                         │
                         ▼
             Temporal Consistency Filter
                         │
                         ▼
             Semantic Validation Layer
```

Investigate whether all stages need neural networks.

Prefer a hybrid architecture if it is more performant.

For example:

```text
Neural Network:
Device detection

Classical CV:
Display geometry

Classical CV:
Homography

Neural Network:
Digit recognition

Temporal filtering:
OCR stabilization
```

Determine whether this can outperform a monolithic model.

---

# PART 8 — TEMPORAL CONTEXT

Investigate whether DAQPal should use multiple frames rather than independent frame-by-frame decisions.

Research:

* Temporal smoothing
* Kalman filtering
* Optical flow
* Object tracking
* SORT
* DeepSORT
* ByteTrack
* Vision framework tracking
* Core ML tracking architectures

The objective is:

> Once DAQPal has confidently identified a device and display, it should maintain that lock even if OCR temporarily fails.

Design a state machine:

```text
SEARCHING
    ↓
DEVICE_DETECTED
    ↓
DISPLAY_CANDIDATE_FOUND
    ↓
DISPLAY_CONFIRMED
    ↓
TRACKING
    ↓
OCR_ACTIVE
    ↓
TEMPORARY_OCR_FAILURE
    ↓
TRACKING_ONLY
    ↓
OCR_RECOVERED
```

Investigate confidence thresholds and hysteresis to prevent rapid lock/unlock behavior.

---

# PART 9 — FORMAL IOS PERFORMANCE INTEGRATION PLAN

After completing the research, create a formal implementation plan for iOS.

The architecture must consider:

* AVFoundation
* Vision
* Core ML
* Accelerate
* Metal
* Core Image
* Neural Engine

Determine:

* Which model runs at camera frame rate.
* Which model runs intermittently.
* Which processing can be skipped while tracking.
* Which processing runs only when confidence drops.
* Which operations run on CPU.
* Which operations run on GPU.
* Which operations can use Neural Engine.

Propose a pipeline similar to:

```text
Camera Capture
     │
     ▼
Frame Throttling
     │
     ├─────── Every N Frames ───────► Device Detector
     │                                  │
     │                                  ▼
     │                           Update Device ROI
     │
     └────── Every Frame ───────────► Lightweight Tracker
                                        │
                                        ▼
                                Display ROI Prediction
                                        │
                                        ▼
                              Display Validation
                                        │
                                        ▼
                               OCR Processing
```

Do not assume every frame needs full neural inference.

Measure the actual performance.

---

# PART 10 — ROI-BASED COMPUTATION

Investigate whether DAQPal can significantly reduce compute by restricting expensive processing to the detected device region.

Compare:

### Full-frame OCR

```text
1920 × 1080
↓
OCR entire frame
```

against:

### Device ROI

```text
1920 × 1080
↓
Detect device
↓
Crop device
↓
Detect display
↓
Crop display
↓
OCR only display
```

Measure expected savings in:

* CPU
* GPU
* Neural Engine
* Memory
* Latency
* Battery

---

# PART 11 — FALSE-POSITIVE RESISTANCE

Design adversarial test scenarios.

At minimum:

### Scenario 1

IR gun + textbook with large numbers.

### Scenario 2

Multimeter + paper containing numbers.

### Scenario 3

Multiple multimeters.

### Scenario 4

Multimeter + phone displaying numbers.

### Scenario 5

Multimeter + computer monitor.

### Scenario 6

Multiple seven-segment displays.

### Scenario 7

Seven-segment-style font printed on paper.

### Scenario 8

Partial device occlusion.

### Scenario 9

Device partially outside frame.

### Scenario 10

Two similar devices in the same frame.

### Scenario 11

Device moves while background numbers remain stationary.

### Scenario 12

Display temporarily becomes unreadable due to glare.

The system should prioritize the correct physical device rather than simply choosing the highest OCR confidence.

---

# PART 12 — TESTING FRAMEWORK EXPANSION

Extend the existing test framework to test three independent perception layers.

## Layer 1 — Device recognition

Test:

* Device classification accuracy
* Device detection accuracy
* Device bounding-box accuracy
* Device tracking accuracy

## Layer 2 — Display recognition

Test:

* Display detection accuracy
* Display/device association accuracy
* Display quadrilateral accuracy
* Homography accuracy

## Layer 3 — Numeric recognition

Test:

* Digit detection
* Seven-segment recognition
* OCR
* Decimal-point detection
* Unit recognition

Calculate:

```text
End-to-End Success =
Device Correct
AND
Display Correct
AND
Display Associated With Correct Device
AND
Digit Correct
AND
Decimal Correct
```

This is more meaningful than OCR accuracy alone.

---

# PART 13 — FORMAL RESEARCH DECISION MATRIX

After research, create a decision matrix.

Evaluate candidate approaches on a 1–10 scale:

| Method                                 | Accuracy | False Lock Resistance | iOS Performance | Model Size | Development Complexity | Generalization |
| -------------------------------------- | -------: | --------------------: | --------------: | ---------: | ---------------------: | -------------: |
| Generic OCR                            |          |                       |                 |            |                        |                |
| Seven-Segment Detector                 |          |                       |                 |            |                        |                |
| Device Classifier                      |          |                       |                 |            |                        |                |
| Device Detector                        |          |                       |                 |            |                        |                |
| Device + Display Detector              |          |                       |                 |            |                        |                |
| Device + Display + Tracking            |          |                       |                 |            |                        |                |
| Device + Display + Seven-Segment Model |          |                       |                 |            |                        |                |
| Hybrid CV + ML                         |          |                       |                 |            |                        |                |

Provide evidence and citations for every major recommendation.

---

# PART 14 — RESEARCH OUTPUT

The first deliverable must be a research report.

It must answer:

1. Is device-aware detection actually worth implementing?
2. How much can it reduce false OCR locks?
3. Should DAQPal use classification, detection, segmentation, or a hybrid?
4. Should the device and display be detected jointly?
5. Should the display be treated as a known part of the device?
6. Is a custom dataset necessary?
7. Which models are best suited to Core ML?
8. Which models can use the Neural Engine?
9. What is the expected latency?
10. What is the expected memory footprint?
11. What is the best architecture for iPhone hardware?
12. What is the simplest architecture that achieves the required reliability?

Do not recommend a solution merely because it is technically sophisticated.

Prefer the simplest architecture that produces a measurable improvement.

---

# PART 15 — IMPLEMENTATION GATES

Do NOT immediately implement the entire architecture.

Use staged gates.

## Gate 1 — Research

Complete literature review.

PASS if:

* Relevant research identified.
* Candidate architectures compared.
* Evidence collected.

## Gate 2 — Baseline

Measure current DAQPal performance.

PASS if:

* Current false lock rate measured.
* Current OCR accuracy measured.
* Current latency measured.

## Gate 3 — Prototype

Implement the smallest viable device-aware prototype.

PASS if:

* Device detection works.
* Display association works.
* No significant UI regression.

## Gate 4 — Benchmark

Compare against baseline.

PASS only if measurable improvement is demonstrated.

## Gate 5 — Performance

Profile on physical iPhone hardware.

Measure:

* FPS
* CPU
* GPU
* Neural Engine utilization where measurable
* Memory
* Battery impact
* Thermal behavior

## Gate 6 — Regression

Run all existing tests.

Expected result:

```text
Existing tests:
733+ passing

New perception tests:
N passing

Regression:
NONE
```

Only report actual results.

## Gate 7 — Production Decision

Make an explicit recommendation:

```text
IMPLEMENT
```

or

```text
DO NOT IMPLEMENT
```

or

```text
IMPLEMENT PARTIAL HYBRID
```

Explain why.

---

# FINAL ARCHITECTURAL QUESTION

The ultimate question to answer is:

> Can DAQPal become significantly more reliable by understanding "what physical device am I looking at?" before asking "what numbers can I read?"

Investigate whether the optimal production architecture is:

```text
WHAT IS IT?
    ↓
WHERE IS IT?
    ↓
WHICH DISPLAY BELONGS TO IT?
    ↓
WHAT IS THE DISPLAY GEOMETRY?
    ↓
WHERE ARE THE DIGITS?
    ↓
WHAT DO THE DIGITS SAY?
    ↓
DOES THE RESULT MAKE SENSE?
```

rather than:

```text
WHAT NUMBERS CAN I FIND?
```

The final recommendation must be evidence-based, benchmarked, and justified specifically for **real-time iOS execution**.

Do not optimize for the most complex computer-vision architecture.

Optimize for:

> Highest correct-device lock reliability × lowest false-lock rate × lowest latency × lowest power consumption × maintainable iOS implementation.
