//
//  MotionStressSweepTests.swift
//  DAQPalTests
//
//  Motion and tracking stress sweep: where does the lock survive, where does it
//  lose the display, and how long does it take to get it back.
//
//  This is the same rig `DriftRegressionTests` proves the drift fix on — a real
//  `ScreenLockPipeline` with a real `ScreenCandidateDetector` and a real
//  `VisionScreenTracker` over real rendered frames — driven across a table of
//  motion scenarios instead of one hand-built drift. Nothing here re-implements
//  tracking: poses come from `DemoMotionModel` and `PoseTrajectory`, ground
//  truth from `panelROI(for:)` and `DisplayPose3D.projectedQuad`, and reading
//  accuracy from the shared `ValidationHarness` vocabulary.
//
//  WHAT THE NUMBERS MEAN
//
//  * "Loss" is `measurementsValid == false`, not "the tracker returned nil". A
//    frame whose geometry the pipeline refuses to vouch for produces no reading
//    and is the honest definition of losing the display; a tracker that keeps
//    emitting a quad it cannot corroborate has not kept the display, it has
//    kept a rectangle.
//  * "Stale-valid" is the inverse and the one that matters for data integrity:
//    `measurementsValid == true` while the tracked quad overlaps ground truth by
//    less than `staleValidIoU`. Those frames are readings taken off the wrong
//    part of the frame, and the architecture deliberately does not re-run
//    detection every frame (`lockedDetectionInterval` = 0.5 s), so bounding how
//    long they can persist is the whole point of measuring here.
//  * "Jitter" is the frame-to-frame change in the tracking ERROR vector, not in
//    the tracked quad itself: subtracting ground truth removes the commanded
//    motion, so one number is comparable between a parked panel and a bouncing
//    one. For a stationary display it degenerates to raw wobble.
//
//  DETERMINISM. Frame timestamps are synthetic (`Double(i) / fps`), every pose
//  is a closed-form or integrated function of the frame index, and the handheld
//  scenario draws from `SeededGenerator` with a fixed seed. No `Date()`, no
//  sleeps, no system randomness. Vision is the only nondeterministic part, which
//  is why the violent scenarios REPORT rather than assert.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class MotionStressSweepTests: XCTestCase {

    // MARK: - Rig

    private let renderer = SyntheticDisplayRenderer()
    /// The synthetic source's native rate; `DriftRegressionTests` drives the
    /// same pipeline at it, so cadence numbers are directly comparable.
    private let fps = 12.0
    private var dt: TimeInterval { 1.0 / fps }
    /// Rendered on every panel in this file. Six characters with a decimal
    /// point, so a misplaced point is visible in the verdict breakdown.
    private let reading = "12.347"

    /// Default motion frames per scenario after the lock is established — 4 s
    /// of synthetic time, which spans eight `lockedDetectionInterval` periods so
    /// every scenario gets several independent verification passes.
    private let motionFrames = 48
    /// Used by the two scenarios that lose the lock without losing the display
    /// (see `knownFalseNegativeScenarios`): 8 s covers the snap engine's 5 s
    /// `reacquisitionTimeout` with margin, so "did it ever come back" has an
    /// answer rather than an open run at the end of the window.
    private let extendedMotionFrames = 96
    /// Frames allowed to reach the initial lock. `DriftRegressionTests` uses
    /// the same bound for the same acquisition.
    private let lockBound = 72
    /// Overlap below which a "valid" measurement is being read off geometry
    /// that is not the display. 0.5 matches the threshold `DriftRegressionTests`
    /// treats as recovered-onto-the-real-panel.
    private let staleValidIoU: CGFloat = 0.5

    /// Single-pass Vision at the shipping recognition level. The panel is drawn
    /// in a monospaced system font, not segment glyphs, so this reads it well
    /// when it is pointed at the display — which is exactly what makes a
    /// disappearing reading evidence that the geometry moved, not that the
    /// recognizer is weak.
    private let ocr = VisionOCR()

    // MARK: - Scenario model

    /// One rendered frame's worth of scenario input.
    private struct Step {
        var pose: PoseKind
        var degradation: RenderDegradation = .none
        /// False while the panel is deliberately outside the frame. Ground-truth
        /// geometry is undefined there — `panelROI(for:)` clamps into the frame
        /// and would report a panel that is not on screen — so those frames are
        /// scored for loss but excluded from geometry error.
        var panelVisible = true
    }

    /// Which render path a step uses. Both are existing rigs: the affine
    /// `DisplayPose` path with `panelROI(for:)` ground truth, and the true
    /// perspective `DisplayPose3D` path with `projectedQuad` ground truth.
    private enum PoseKind {
        case affine(DisplayPose)
        case perspective(DisplayPose3D)
    }

    private struct Scenario {
        let name: String
        /// Precomputed rather than a closure so stateful pose sources
        /// (`DemoMotionModel` integrates bounce/drift/homing) can be advanced
        /// exactly once, in order, with no hidden replay hazard.
        let steps: [Step]
    }

    /// Per-scenario tracking aggregate.
    ///
    /// Deliberately NOT a second reading-accuracy type — every reading is
    /// reported through `ValidationOutcome`. Loss rate, jitter and reacquisition
    /// latency have no representation in that vocabulary, and inventing verdicts
    /// for them would be worse than carrying them alongside.
    private struct TrackingSummary {
        var scenario = ""
        var frames = 0
        /// Frames with the panel on screen and no valid geometry.
        var lostFrames = 0
        var visibleFrames = 0
        /// Frames the pipeline vouched for while the quad was off the panel.
        var staleValidFrames = 0
        var longestStaleValidRun = 0
        /// The opposite error: no valid measurement even though the tracked quad
        /// was still on the display. Costs availability, never correctness — and
        /// it is the failure this sweep actually found.
        var falseNegativeFrames = 0
        /// Frames on which the appearance sentinel's veto was standing, which is
        /// how a false negative is attributed to appearance rather than to the
        /// detector's geometric verdict.
        var sentinelVetoFrames = 0
        var meanSentinelNCC: Float?
        var meanJitter: CGFloat = 0
        var maxJitter: CGFloat = 0
        var meanIoU: CGFloat = 0
        var meanCornerError: CGFloat = 0
        /// Frames from the start of each loss run to the first valid frame after
        /// it. A run still open at the end of the scenario is counted in
        /// `unrecoveredTailFrames` instead.
        var reacquisitionLatencies: [Int] = []
        var unrecoveredTailFrames = 0
        /// Frames from the panel becoming visible again to the first valid
        /// frame, for scenarios that take the display off screen.
        var reentryLatency: Int?
        var stateHistogram: [String: Int] = [:]
        /// Pulled from `PipelineMetrics.shared` after the motion phase. Nil
        /// where the stage has no production call site (`.ocr`) or recorded
        /// nothing inside the snapshot's rolling window.
        var trackingP95MS: Double?
        var detectionP95MS: Double?
        var ocrP95MS: Double?
        /// This sweep's own stopwatch around the recognition call. Reported
        /// separately from the three stage figures above and never folded into
        /// them: `.ocr` has no production `PipelineMetrics.measure` call site,
        /// so presenting this as an instrumented stage would invent a
        /// measurement the app does not take.
        var ocrMeanMS: Double?

        var lossRate: Double {
            visibleFrames > 0 ? Double(lostFrames) / Double(visibleFrames) : 0
        }
        var worstReacquisition: Int? { reacquisitionLatencies.max() }
    }

    // MARK: - Rendering

    private func render(_ step: Step, frameIndex: Int, at t: TimeInterval) throws
        -> (frame: TimestampedFrame, truth: ScreenQuad) {
        switch step.pose {
        case .affine(let pose):
            guard let buffer = renderer.render(text: reading, pose: pose,
                                               degradation: step.degradation,
                                               frameIndex: frameIndex) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            return (TimestampedFrame(pixelBuffer: buffer, timestamp: t),
                    ScreenQuad(roi: renderer.panelROI(for: pose)))
        case .perspective(let pose):
            guard let buffer = renderer.render(text: reading, pose3D: pose,
                                               degradation: step.degradation,
                                               frameIndex: frameIndex) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            return (TimestampedFrame(pixelBuffer: buffer, timestamp: t),
                    pose.projectedQuad(panelSize: PoseTrajectory.defaultPanelSize,
                                       frameAspect: PoseTrajectory.defaultFrameAspect))
        }
    }

    /// The numeric field whose value is read off tracked geometry. Canonical
    /// target space, so it rides the display through every pose.
    private var selectedNumericField: ScreenField {
        ScreenField(region: NormalizedROI(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
                    kind: .numeric, label: "READING", format: .unconstrained,
                    isSelected: true, detectionConfidence: 0.9)
    }

    // MARK: - Driver

    /// Runs one scenario end to end and returns its outcomes plus its tracking
    /// aggregate. Returns nil (having failed) when the pipeline never locked, so
    /// the caller reports an honest "no premise" rather than a zeroed row.
    private func run(_ scenario: Scenario) async throws
        -> (outcomes: [ValidationOutcome], summary: TrackingSummary)? {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)

        var frameIndex = 0
        // Acquisition happens on the scenario's opening POSE with clean optics:
        // the operator points the camera at a legible display and locks, and
        // only then does the scenario's blur/noise/occlusion begin. Carrying
        // frame 0's degradation through the whole acquisition instead would
        // make `stress` a test of locking onto a permanently occluded panel,
        // which it is not.
        let acquisitionStep = Step(pose: scenario.steps[0].pose)
        // A fixed user window over the panel's starting position: the operator
        // placed it once and never moved it. Constant by construction, so
        // reacquisition is never handed live ground truth.
        let (_, homeTruth) = try render(acquisitionStep, frameIndex: 0, at: 0)
        let userSelection = homeTruth

        // --- Phase A: steady at the scenario's opening pose until locked -----
        var locked = false
        var bestConfidence: Float = 0
        while frameIndex < lockBound {
            let (frame, _) = try render(acquisitionStep, frameIndex: frameIndex,
                                        at: Double(frameIndex) * dt)
            let update = await pipeline.process(frame: frame, selection: userSelection,
                                                isUserDragging: false)
            frameIndex += 1
            bestConfidence = max(bestConfidence, update.candidates.map(\.confidence).max() ?? 0)
            if update.didLock {
                await pipeline.setSelectedFields([selectedNumericField])
                locked = true
                break
            }
        }
        guard locked else {
            XCTFail("\(scenario.name): no lock within \(lockBound) steady frames; best fused "
                    + "candidate confidence was \(bestConfidence) (enterLock is "
                    + "\(SnapTuning.default.enterLock)) — the scenario has no premise")
            return nil
        }

        // --- Phase B: the motion ---------------------------------------------
        // The metrics ring is process-wide and windowed, so it is cleared here
        // and read immediately after the loop; no other suite asserts on the
        // shared recorder (`PipelineBudgetTests` uses a private instance).
        PipelineMetrics.shared.reset()

        var outcomes: [ValidationOutcome] = []
        var summary = TrackingSummary(scenario: scenario.name)
        var previousError: [CGPoint]?
        var jitterSamples: [CGFloat] = []
        var iouSamples: [CGFloat] = []
        var cornerSamples: [CGFloat] = []
        var lossRunStart: Int?
        var staleRun = 0
        var reentryFrame: Int?
        var nccSamples: [Float] = []
        var ocrSamples: [Double] = []

        for i in 0..<scenario.steps.count {
            let step = scenario.steps[i]
            let t = Double(frameIndex) * dt
            let (frame, truth) = try render(step, frameIndex: frameIndex, at: t)

            let started = PipelineMetrics.now()
            let update = await pipeline.process(frame: frame,
                                                selection: userSelection,
                                                isUserDragging: false)
            if update.didLock { await pipeline.setSelectedFields([selectedNumericField]) }

            let geometry = step.panelVisible
                ? update.target.flatMap { GeometryError.between(predicted: $0.quad.corners,
                                                                truth: truth.corners) }
                : nil
            let iou = step.panelVisible
                ? (update.target.map { $0.quad.boundingBoxIoU(with: truth) } ?? 0)
                : 0

            // Only frames the pipeline vouches for can produce a reading; that
            // gate is the thing under test, so OCR is run exactly where the
            // shipping pipeline would run it and nowhere else.
            let durationMS = (PipelineMetrics.now() - started) * 1000
            var predicted: String?
            if update.measurementsValid, let roi = update.fieldROIs.values.first {
                let ocrStarted = PipelineMetrics.now()
                predicted = try? await bestReading(in: frame.pixelBuffer, roi: roi)
                ocrSamples.append((PipelineMetrics.now() - ocrStarted) * 1000)
            }

            // --- accounting ---
            // Polled every frame, not once at the end: the snapshot only
            // reports samples from the last 2 s of WALL CLOCK, and a frame here
            // costs far more than a real one (Debug + a full recognition pass),
            // so a single trailing read can miss the 0.5 s-cadence detector
            // entirely and report it as never having run.
            let snapshot = PipelineMetrics.shared.snapshot()
            summary.trackingP95MS = snapshot.stages[.tracking]?.p95LatencyMS ?? summary.trackingP95MS
            summary.detectionP95MS = snapshot.stages[.detection]?.p95LatencyMS ?? summary.detectionP95MS
            summary.ocrP95MS = snapshot.stages[.ocr]?.p95LatencyMS ?? summary.ocrP95MS

            summary.frames += 1
            summary.stateHistogram[update.snapState.displayLabel, default: 0] += 1
            if update.sentinelVetoed { summary.sentinelVetoFrames += 1 }
            if let ncc = update.sentinelNCC { nccSamples.append(ncc) }
            if step.panelVisible {
                summary.visibleFrames += 1
                if !update.measurementsValid {
                    summary.lostFrames += 1
                    if iou >= staleValidIoU { summary.falseNegativeFrames += 1 }
                }
                if let geometry {
                    iouSamples.append(geometry.iou)
                    cornerSamples.append(geometry.meanCornerError)
                }
            }
            if update.measurementsValid, !step.panelVisible || iou < staleValidIoU {
                summary.staleValidFrames += 1
                staleRun += 1
                summary.longestStaleValidRun = max(summary.longestStaleValidRun, staleRun)
            } else {
                staleRun = 0
            }

            if update.measurementsValid {
                if let start = lossRunStart {
                    summary.reacquisitionLatencies.append(i - start)
                    lossRunStart = nil
                }
                if let entry = reentryFrame, summary.reentryLatency == nil {
                    summary.reentryLatency = i - entry
                }
            } else if lossRunStart == nil {
                lossRunStart = i
            }
            // First frame on which a departed panel is back on screen.
            if step.panelVisible, i > 0, !scenario.steps[i - 1].panelVisible, reentryFrame == nil {
                reentryFrame = i
            }

            if let target = update.target, step.panelVisible {
                let error = zip(target.quad.corners, truth.corners)
                    .map { CGPoint(x: $0.x - $1.x, y: $0.y - $1.y) }
                if let previousError {
                    let delta = zip(error, previousError)
                        .map { hypot($0.x - $1.x, $0.y - $1.y) }
                        .reduce(0, +) / 4
                    jitterSamples.append(delta)
                }
                previousError = error
            } else {
                previousError = nil
            }

            outcomes.append(ValidationOutcome(
                id: "motion/\(scenario.name)/f\(i)",
                sweep: "motion",
                parameters: ["scenario": scenario.name,
                             "panel": step.panelVisible ? "visible" : "offFrame",
                             "state": update.snapState.displayLabel],
                truth: reading,
                predicted: predicted,
                verdict: ReadingComparison.verdict(truth: reading, predicted: predicted),
                geometry: geometry,
                confidence: update.target?.trackingConfidence ?? 0,
                durationMS: durationMS))

            frameIndex += 1
        }

        if let start = lossRunStart {
            summary.unrecoveredTailFrames = summary.frames - start
        }
        summary.meanJitter = mean(jitterSamples)
        summary.maxJitter = jitterSamples.max() ?? 0
        summary.meanIoU = mean(iouSamples)
        summary.meanCornerError = mean(cornerSamples)
        summary.meanSentinelNCC = nccSamples.isEmpty
            ? nil : nccSamples.reduce(0, +) / Float(nccSamples.count)
        summary.ocrMeanMS = ocrSamples.isEmpty
            ? nil : ocrSamples.reduce(0, +) / Double(ocrSamples.count)

        return (outcomes, summary)
    }

    private func mean(_ values: [CGFloat]) -> CGFloat {
        values.isEmpty ? 0 : values.reduce(0, +) / CGFloat(values.count)
    }

    /// Highest-confidence Vision hypothesis for `roi`, or nil when the region
    /// contains nothing readable — which is what an ROI parked on background
    /// produces, and therefore the signal a drifted lock leaves behind.
    private func bestReading(in buffer: CVPixelBuffer, roi: NormalizedROI) async throws -> String? {
        let candidates = try await ocr.recognize(in: buffer, regionOfInterest: roi)
        return candidates.max { $0.confidence < $1.confidence }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Scenario builders

    private static let home = DemoMotionModel.homeCenter

    private func affineSteps(count: Int,
                             degradation: @escaping (Int) -> RenderDegradation = { _ in .none },
                             visible: @escaping (Int) -> Bool = { _ in true },
                             pose: (TimeInterval, Int) -> DisplayPose) -> [Step] {
        (0..<count).map { i in
            Step(pose: .affine(pose(Double(i) * dt, i)),
                 degradation: degradation(i),
                 panelVisible: visible(i))
        }
    }

    /// Steps produced by the shipped `DemoMotionModel`, advanced once per frame
    /// exactly as the Simulator's frame loop advances it.
    private func demoMotionSteps(_ mode: DemoMotion, count: Int,
                                 degradation: @escaping (Int) -> RenderDegradation = { _ in .none }) -> [Step] {
        var model = DemoMotionModel()
        model.mode = mode
        return (0..<count).map { i in
            Step(pose: .affine(model.pose(at: Double(i) * dt, dt: dt)),
                 degradation: degradation(i))
        }
    }

    private func trajectorySteps(_ trajectory: PoseTrajectory, count: Int) -> [Step] {
        (0..<count).map { i in Step(pose: .perspective(trajectory.pose(at: Double(i) * dt))) }
    }

    /// Mirrors the moderate optics `SyntheticFrameSource` applies automatically
    /// in `.stress` mode — blur and noise throughout, a brief opaque bar every
    /// three seconds — so the scenario named `stress` here is the one a tester
    /// gets by tapping the SYNTHETIC chip.
    private func stressOptics(frameIndex: Int) -> RenderDegradation {
        RenderDegradation(occlusion: frameIndex % 36 < 6 ? 0.22 : 0,
                          blurRadius: 6, noiseAmount: 0.05, brightness: 1)
    }

    // MARK: Slow and steady

    private var steadyScenario: Scenario {
        Scenario(name: "steady", steps: demoMotionSteps(.steady, count: motionFrames))
    }

    /// 0.05 u/s laterally — a hand tracking along a bench, comfortably inside
    /// what the damped tracker can follow. Run long because it is one of the
    /// two scenarios that lose the lock while keeping the display.
    private var slowHorizontalScenario: Scenario {
        Scenario(name: "slowHorizontal", steps: affineSteps(count: extendedMotionFrames) { t, _ in
            DisplayPose(center: CGPoint(x: Self.home.x + 0.05 * CGFloat(t), y: Self.home.y),
                        roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        })
    }

    private var slowVerticalScenario: Scenario {
        Scenario(name: "slowVertical", steps: affineSteps(count: motionFrames) { t, _ in
            DisplayPose(center: CGPoint(x: Self.home.x, y: Self.home.y + 0.05 * CGFloat(t)),
                        roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        })
    }

    /// `DemoMotion.roll` — ±10° at 0.12 Hz, inside Vision's text tolerance.
    private var slowRotationScenario: Scenario {
        Scenario(name: "slowRotation", steps: demoMotionSteps(.roll, count: motionFrames))
    }

    /// ±0.01 u at 2 Hz: the residual sway of a braced arm. Small enough that a
    /// tracker should absorb it entirely, which makes it the sharpest test of
    /// whether the reported box wobbles more than the display does.
    private var smallOscillationScenario: Scenario {
        Scenario(name: "smallOscillation", steps: affineSteps(count: extendedMotionFrames) { t, _ in
            DisplayPose(center: CGPoint(x: Self.home.x + 0.01 * sin(2 * .pi * 2 * CGFloat(t)),
                                        y: Self.home.y + 0.006 * sin(2 * .pi * 2.7 * CGFloat(t) + 0.6)),
                        roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        })
    }

    // MARK: Violent

    /// 1.1 Hz through the full ±55° tilt the demo rig sweeps at 0.16 Hz — the
    /// same amplitude, seven times the rate, so the pose changes by most of its
    /// range between adjacent frames at 12 fps.
    private var rapidYawScenario: Scenario {
        Scenario(name: "rapidYaw", steps: affineSteps(count: motionFrames) { t, _ in
            DisplayPose(center: Self.home, roll: 0,
                        yawScale: Self.foreshortening(1.1, t), pitchScale: 1, scale: 1)
        })
    }

    private var rapidPitchScenario: Scenario {
        Scenario(name: "rapidPitch", steps: affineSteps(count: motionFrames) { t, _ in
            DisplayPose(center: Self.home, roll: 0,
                        yawScale: 1, pitchScale: Self.foreshortening(1.1, t), scale: 1)
        })
    }

    private var rapidRollScenario: Scenario {
        Scenario(name: "rapidRoll", steps: affineSteps(count: motionFrames) { t, _ in
            DisplayPose(center: Self.home,
                        roll: DemoMotionModel.maxRollAngle * sin(2 * .pi * 1.1 * CGFloat(t)),
                        yawScale: 1, pitchScale: 1, scale: 1)
        })
    }

    private static func foreshortening(_ frequency: CGFloat, _ t: TimeInterval) -> CGFloat {
        max(0.15, cos(DemoMotionModel.maxTiltAngle * sin(2 * .pi * frequency * CGFloat(t))))
    }

    private var bounceScenario: Scenario {
        Scenario(name: "bounce", steps: demoMotionSteps(.bounce, count: motionFrames))
    }

    private var stressScenario: Scenario {
        Scenario(name: "stress", steps: demoMotionSteps(.stress, count: motionFrames,
                                                        degradation: stressOptics))
    }

    /// True 3-D tumble — yaw, pitch, roll, translation and depth at once, with
    /// the projected quad as ground truth rather than an affine approximation.
    private var tumble3DScenario: Scenario {
        Scenario(name: "tumble3D", steps: trajectorySteps(.tumble3D, count: motionFrames))
    }

    /// Peak speed ≥ 0.75 u/s, above what the ROI tracker can follow by
    /// construction (`PoseTrajectory.fastTranslationPeakSpeed`).
    private var fastTranslationScenario: Scenario {
        Scenario(name: "fastTranslation", steps: trajectorySteps(.fastTranslation, count: motionFrames))
    }

    // MARK: Loss and recovery

    /// Deterministic handheld tremor: ±0.006 u of translation and ±1.5° of roll
    /// redrawn every frame from a seeded generator, so a failure replays from
    /// the seed alone.
    private var handheldJitterScenario: Scenario {
        var generator = SeededGenerator(seed: 0x4A17_7E12)
        let poses: [DisplayPose] = (0..<motionFrames).map { _ in
            let dx = CGFloat.random(in: -0.006...0.006, using: &generator)
            let dy = CGFloat.random(in: -0.006...0.006, using: &generator)
            let roll = CGFloat.random(in: -0.026...0.026, using: &generator)
            return DisplayPose(center: CGPoint(x: Self.home.x + dx, y: Self.home.y + dy),
                               roll: roll, yawScale: 1, pitchScale: 1, scale: 1)
        }
        return Scenario(name: "handheldJitter", steps: poses.map { Step(pose: .affine($0)) })
    }

    /// Sudden movement: parked, then a 0.3 u teleport between two adjacent
    /// frames — faster than any tracker can follow by definition. Run long
    /// because the interesting number is how long recovery takes, and the snap
    /// engine's `reacquisitionTimeout` alone is 5 s.
    private var stepJumpScenario: Scenario {
        Scenario(name: "stepJump", steps: affineSteps(count: extendedMotionFrames) { _, i in
            DisplayPose(center: i < 12 ? Self.home
                            : CGPoint(x: Self.home.x, y: Self.home.y - 0.3),
                        roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        })
    }

    /// A hand or probe covering most of the display for 1 s, then clearing.
    /// The panel never moves, so anything the tracker loses here it lost to
    /// appearance, not to geometry.
    private var occlusionBurstScenario: Scenario {
        Scenario(name: "occlusionBurst",
                 steps: affineSteps(count: motionFrames,
                                    degradation: { i in
                                        RenderDegradation(occlusion: (12..<24).contains(i) ? 0.9 : 0)
                                    }) { _, _ in DisplayPose.identity })
    }

    /// The display leaves the frame entirely for 1 s and comes back to where it
    /// started. Frames 16..<28 carry no panel at all, so ground-truth geometry
    /// does not exist for them.
    private var exitAndReenterScenario: Scenario {
        Scenario(name: "exitReenter",
                 steps: affineSteps(count: motionFrames,
                                    visible: { !(16..<28).contains($0) }) { _, i in
                     switch i {
                     case ..<16, 28...:
                         DisplayPose.identity
                     default:
                         // Well past the frame edge: nothing of the panel is
                         // rendered, so the pipeline is looking at empty body.
                         DisplayPose(center: CGPoint(x: 0.5, y: 1.8), roll: 0,
                                     yawScale: 1, pitchScale: 1, scale: 1)
                     }
                 })
    }

    // MARK: - Reporting

    private func report(_ summaries: [TrackingSummary]) -> String {
        var lines = ["=== TRACKING (loss / jitter / reacquisition) ==="]
        lines.append("  scenario         frames  loss%  stale(n/run)  falseNeg  sentinelVeto  "
                     + "jitter(mean/max)   IoU   corner  reacq(frames)")
        for s in summaries {
            let reacq = s.reacquisitionLatencies.isEmpty
                ? (s.unrecoveredTailFrames > 0 ? "none in \(s.unrecoveredTailFrames)" : "-")
                : s.reacquisitionLatencies.map(String.init).joined(separator: ",")
                    + (s.unrecoveredTailFrames > 0 ? " +open(\(s.unrecoveredTailFrames))" : "")
            lines.append(String(format: "  %-16@ %5d  %5.1f  %4d/%-4d %8d %12d  %.5f/%.5f  %.3f %.4f  %@",
                                s.scenario as NSString, s.frames, s.lossRate * 100,
                                s.staleValidFrames, s.longestStaleValidRun,
                                s.falseNegativeFrames, s.sentinelVetoFrames,
                                s.meanJitter, s.maxJitter, s.meanIoU, s.meanCornerError,
                                reacq as NSString))
        }
        lines.append("  states / appearance:")
        for s in summaries {
            let states = s.stateHistogram.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            let ncc = s.meanSentinelNCC.map { String(format: " meanNCC=%.3f", $0) } ?? " meanNCC=n/a"
            lines.append("    \(s.scenario): \(states)\(ncc)"
                         + (s.reentryLatency.map { "  reentry=+\($0)f" } ?? ""))
        }
        // DEBUG timings. Per-pixel Swift and Vision both run far slower here
        // than in a Release build, so these bound relative cost between stages,
        // not the shipping frame budget.
        lines.append("  stage p95 (ms, DEBUG, pulled from PipelineMetrics.shared after each scenario):")
        for s in summaries {
            func show(_ value: Double?) -> String {
                value.map { String(format: "%.1f", $0) } ?? "ABSENT"
            }
            lines.append("    \(s.scenario): TRK=\(show(s.trackingP95MS)) "
                         + "DET=\(show(s.detectionP95MS)) OCR(stage)=\(show(s.ocrP95MS)) "
                         + "OCR(sweep stopwatch, mean)=\(show(s.ocrMeanMS))")
        }
        return lines.joined(separator: "\n")
    }

    private func emit(_ sweep: String, outcomes: [ValidationOutcome], summaries: [TrackingSummary]) {
        print(ValidationReport(sweep: sweep, outcomes: outcomes).summary(groupedBy: "scenario"))
        print(report(summaries))
    }

    // MARK: - Slow motion: the case that must hold
    //
    // Everything here moves at or below what a braced hand does.

    /// Slow scenarios that hold the lock on every single frame. Measured, not
    /// assumed: steady, 0.05 u/s VERTICAL translation, and ±10° roll at 0.12 Hz
    /// each ran 48/48 frames locked and valid.
    ///
    /// `slowHorizontal` and `smallOscillation` are deliberately absent — see
    /// `testSlowLateralMotionLosesTheLockWithoutLosingTheDisplay`, which
    /// characterizes them instead of pretending they pass.
    private let lossFreeSlowScenarios: Set<String> = ["steady", "slowVertical", "slowRotation"]

    func testSlowMotionHoldsTheLockWithoutWobbleOrStaleGeometry() async throws {
        var outcomes: [ValidationOutcome] = []
        var summaries: [TrackingSummary] = []
        for scenario in [steadyScenario, slowVerticalScenario, slowRotationScenario] {
            guard let result = try await run(scenario) else { return }
            outcomes += result.outcomes
            summaries.append(result.summary)
        }
        emit("motion-slow", outcomes: outcomes, summaries: summaries)

        for s in summaries {
            XCTAssertTrue(lossFreeSlowScenarios.contains(s.scenario),
                          "\(s.scenario) is not in the measured loss-free set; either add its "
                          + "measurement or move it to the characterization test")
            XCTAssertEqual(s.lossRate, 0, accuracy: 0.001,
                           "\(s.scenario): lost the display on \(s.lostFrames) of "
                           + "\(s.visibleFrames) frames of slow motion")
            XCTAssertEqual(s.staleValidFrames, 0,
                           "\(s.scenario): the pipeline vouched for geometry off the panel on "
                           + "\(s.staleValidFrames) frames (longest run \(s.longestStaleValidRun)) "
                           + "— readings taken from the wrong part of the frame")
            XCTAssertGreaterThan(s.meanIoU, 0.9,
                                 "\(s.scenario): tracked geometry only overlaps the panel by "
                                 + "\(s.meanIoU) on average")
        }

        // A parked display is the one case where every unit of reported motion
        // is invented. Anything the tracker adds here it would also add on top
        // of real motion, so this bounds the noise floor for all the rest.
        // Measured max frame-to-frame wobble on a parked panel: 1.0e-5 units.
        let steady = try XCTUnwrap(summaries.first { $0.scenario == "steady" })
        XCTAssertLessThan(steady.maxJitter, 0.001,
                          "a stationary panel's tracked box moved \(steady.maxJitter) normalized "
                          + "units between adjacent frames — that is wobble, not motion")
    }

    // MARK: - The defect this sweep found
    //
    // KNOWN LIMITATION, characterized rather than asserted away.
    //
    // Three benign motions cost the lock repeatedly while the tracked quad
    // stayed ON the display the whole time (measured over 96 / 96 / 48 frames):
    //
    //   slowHorizontal    0.05 u/s lateral      65.6% of frames invalid, mean IoU 0.937
    //   smallOscillation  ±0.01 u at 2 Hz       51.0% invalid,           mean IoU 0.954
    //   handheldJitter    ±0.006 u tremor       35.4% invalid,           mean IoU 0.960
    //
    // Every lost frame is a FALSE NEGATIVE: the geometry was right and the
    // reading was thrown away. The SAME 0.05 u/s applied vertically costs
    // nothing at all (0/48 frames lost), and 0.05 u/s vertically is the faster
    // motion in pixels — the panel is 820×250 px, so vertical translation moves
    // it ~8 px per frame against horizontal's ~4.5. Speed therefore does not
    // explain the split; direction does. The panel's ink varies almost entirely
    // along x (digits side by side), so a few pixels of horizontal tracking lag
    // decorrelates the sampled appearance where the same lag along y slides
    // along nearly constant rows. Measured mean sentinel NCC bears that out:
    // 0.996 for slowVertical against 0.571 for slowHorizontal.
    //
    // This is an availability defect, not a data-integrity one, and the
    // assertions below are what make that claim falsifiable: if a loss here ever
    // coincides with geometry that has actually left the panel, the defect has
    // changed character and this test fails.

    func testBenignMotionLosesTheLockWithoutLosingTheDisplay() async throws {
        var outcomes: [ValidationOutcome] = []
        var summaries: [TrackingSummary] = []
        for scenario in [slowHorizontalScenario, smallOscillationScenario,
                         handheldJitterScenario] {
            guard let result = try await run(scenario) else { return }
            outcomes += result.outcomes
            summaries.append(result.summary)
        }
        emit("motion-benign-false-negative", outcomes: outcomes, summaries: summaries)

        for s in summaries {
            XCTAssertGreaterThan(s.lostFrames, 0,
                                 "\(s.scenario) no longer loses the lock — the characterization is "
                                 + "stale and this scenario belongs in the loss-free set")
            XCTAssertEqual(s.falseNegativeFrames, s.lostFrames,
                           "\(s.scenario): \(s.lostFrames - s.falseNegativeFrames) of "
                           + "\(s.lostFrames) lost frames had geometry off the panel — this is no "
                           + "longer a pure false negative, the tracker is genuinely drifting")
            XCTAssertEqual(s.staleValidFrames, 0,
                           "\(s.scenario): vouched for off-panel geometry on "
                           + "\(s.staleValidFrames) frames")
            XCTAssertGreaterThan(s.meanIoU, 0.9,
                                 "\(s.scenario): mean tracked/truth IoU fell to \(s.meanIoU); the "
                                 + "loss is no longer explainable as a false negative")
        }
    }

    // MARK: - Violent motion: characterized, not asserted
    //
    // These are deliberately at or beyond what the tracker can follow. The only
    // thing asserted is the data-integrity invariant that must hold at ANY
    // speed: the pipeline must not keep vouching for geometry that has left the
    // display. Everything else is reported.

    func testViolentMotionIsCharacterizedAndNeverVouchesForStaleGeometryForLong() async throws {
        var outcomes: [ValidationOutcome] = []
        var summaries: [TrackingSummary] = []
        for scenario in [rapidYawScenario, rapidPitchScenario, rapidRollScenario,
                         bounceScenario, stressScenario, tumble3DScenario,
                         fastTranslationScenario] {
            guard let result = try await run(scenario) else { return }
            outcomes += result.outcomes
            summaries.append(result.summary)
        }
        emit("motion-violent", outcomes: outcomes, summaries: summaries)

        // The bound, not the count: detection revalidates every 0.5 s (6 frames
        // at 12 fps) and the stale-tracker timeout is 0.75 s (9 frames), so a
        // drifted lock has a bounded life. 15 frames is the same margin
        // `DriftRegressionTests` allows for the same two paths.
        for s in summaries {
            XCTAssertLessThanOrEqual(s.longestStaleValidRun, 15,
                                     "\(s.scenario): measurements stayed valid for "
                                     + "\(s.longestStaleValidRun) consecutive frames while the "
                                     + "tracked quad was off the panel — stale geometry presented "
                                     + "as truth")
        }
    }

    // MARK: - Loss and recovery
    //
    // Three ways to take the display away: a teleport past what any tracker can
    // follow, an occluding hand, and leaving the frame entirely. The pipeline
    // must notice all three without ever vouching for what it no longer sees;
    // how fast it comes back is measured, and asserted only where a bound was
    // actually observed.

    func testDisplayLossIsDetectedAndReacquired() async throws {
        var outcomes: [ValidationOutcome] = []
        var summaries: [TrackingSummary] = []
        for scenario in [stepJumpScenario, occlusionBurstScenario, exitAndReenterScenario] {
            guard let result = try await run(scenario) else { return }
            outcomes += result.outcomes
            summaries.append(result.summary)
        }
        emit("motion-recovery", outcomes: outcomes, summaries: summaries)

        // The invariant that holds in all three, and the one that matters: a
        // display the pipeline cannot see is a display it does not report on.
        for s in summaries {
            XCTAssertEqual(s.staleValidFrames, 0,
                           "\(s.scenario): vouched for off-panel geometry on "
                           + "\(s.staleValidFrames) frames (longest run "
                           + "\(s.longestStaleValidRun)) — readings from the wrong geometry")
        }

        // A 0.3 u teleport is unfollowable by construction, so the tracked quad
        // does leave the panel. What must not happen is the lock surviving it:
        // measured, the pipeline invalidates and stays invalid.
        let jump = try XCTUnwrap(summaries.first { $0.scenario == "stepJump" })
        XCTAssertGreaterThan(jump.lostFrames, 0,
                             "a 0.3 u teleport did not cost the lock a single frame — the "
                             + "geometry check is not engaging")

        // A hand over 90% of the panel for 1 s: measured 2 frames of loss and a
        // 2-frame reacquisition, so the lock survives an occlusion burst almost
        // untouched. 12 frames (1 s) is a generous bound around that.
        let occluded = try XCTUnwrap(summaries.first { $0.scenario == "occlusionBurst" })
        XCTAssertLessThanOrEqual(occluded.worstReacquisition ?? 0, 12,
                                 "a 1 s occlusion burst took \(occluded.worstReacquisition ?? -1) "
                                 + "frames to recover from")
        XCTAssertEqual(occluded.unrecoveredTailFrames, 0,
                       "the lock never came back after the occlusion cleared")

        // The display leaves the frame for 1 s and returns to exactly where it
        // was. Measured re-entry latency: 7 frames (~0.6 s).
        let reentered = try XCTUnwrap(summaries.first { $0.scenario == "exitReenter" })
        let latency = try XCTUnwrap(reentered.reentryLatency,
                                    "the pipeline never produced a valid measurement again after "
                                    + "the display came back into frame")
        XCTAssertLessThanOrEqual(latency, 24,
                                 "re-entry took \(latency) frames (\(Double(latency) / fps) s) to "
                                 + "produce a valid reading again")
    }
}
