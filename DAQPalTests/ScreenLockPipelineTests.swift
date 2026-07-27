//
//  ScreenLockPipelineTests.swift
//  DAQPalTests
//
//  Integration coverage for the WIRED intelligent path (spec Gate 14):
//  `ScreenLockPipeline` → `MeasurementProcessor.process(frame:roiOverrides:)` →
//  `AppState.applyScreenLock`. `FrameProcessor` itself is a three-line drain
//  loop over exactly those three calls, so driving them in the same order with
//  the same values is the same path without needing a live capture session.
//
//  What is real here and what is not, stated plainly:
//
//  * Frames are real pixel buffers from `SyntheticDisplayRenderer`, posed by the
//    same `DisplayPose`/`DemoMotionModel` rig the Simulator demo uses, and
//    `panelROI(for:)` gives the GROUND-TRUTH panel bounds for a pose. Recognition
//    runs through real Vision.
//  * `ScreenCandidateDetector` and `VisionScreenTracker` are concrete actors and
//    `ScreenLockPipeline`'s initializer takes those concrete types, so no
//    counting stub can be injected. Every claim about detector CADENCE here is
//    therefore made from an observable consequence (candidate arrays carried
//    forward unchanged between detections), never from a call count — see
//    `testDetectionDoesNotRunOnEveryFrame` for exactly what that does and does
//    not prove.
//  * Anything that requires an actual lock depends on Vision proposing the
//    synthetic panel at lock-grade confidence, which varies by OS/Simulator
//    version. Those tests SKIP with a clear message rather than assert a
//    fabricated pass — the same honesty rule `SyntheticPipelineTests` follows.
//
//  Timestamps are synthetic (`Double(i) / rate`). No `Date()`, no sleeps, no
//  randomness anywhere in this file.
//

import CoreGraphics
import CoreVideo
import Observation
import XCTest
@testable import DAQPal

final class ScreenLockPipelineTests: XCTestCase {

    // MARK: - Fixtures

    private let renderer = SyntheticDisplayRenderer()

    /// Frame timestamps at 30 fps — the rate the cadence tests reason about.
    private func time(_ index: Int, rate: Double = 30) -> TimeInterval { Double(index) / rate }

    /// Renders `text` at `pose` into a real pixel buffer. Skips (rather than
    /// fails) if the renderer cannot allocate — an environment limitation, not a
    /// pipeline defect.
    private func makeFrame(text: String = "12.347",
                           pose: DisplayPose = .identity,
                           timestamp: TimeInterval) throws -> TimestampedFrame {
        guard let buffer = renderer.render(text: text, pose: pose) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: timestamp)
    }

    /// The quad a user's manually placed window would have over the panel's
    /// default location — the pipeline's `selection` input.
    private var panelSelection: ScreenQuad {
        ScreenQuad(roi: SyntheticDisplayRenderer.displayROI)
    }

    private func field(region: NormalizedROI,
                       kind: FieldContentKind = .numeric,
                       label: String = "",
                       format: DisplayFormat = .unconstrained,
                       isSelected: Bool = false) -> ScreenField {
        ScreenField(region: region, kind: kind, label: label, format: format,
                    isSelected: isSelected, detectionConfidence: 0.9)
    }

    private func lockedUpdate(target: TrackedTarget,
                              analyzedFields: [ScreenField]? = nil) -> ScreenLockUpdate {
        ScreenLockUpdate(snapState: .locked(targetID: target.id),
                         selectionQuad: target.quad,
                         target: target,
                         candidates: [],
                         didLock: false,
                         didRelease: false,
                         fieldROIs: [:],
                         analyzedFields: analyzedFields,
                         isIdle: false)
    }

    // MARK: - 1. Idle / manual fallback
    //
    // The single invariant that must never break: with the intelligent path
    // switched off (its shipping default) the app behaves exactly as it did
    // before `ScreenLockPipeline` existed.

    /// A disabled pipeline is inert on every frame — not merely on the first.
    func testDisabledPipelineIsIdleAndEmitsNoOverrides() async throws {
        let pipeline = ScreenLockPipeline()
        let enabled = await pipeline.enabled
        XCTAssertFalse(enabled, "the intelligent path must be opt-in, off by default")

        for i in 0..<10 {
            let frame = try makeFrame(timestamp: time(i))
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            XCTAssertTrue(update.isIdle, "frame \(i)")
            XCTAssertEqual(update.snapState, .manual, "frame \(i)")
            XCTAssertTrue(update.fieldROIs.isEmpty,
                          "a disabled pipeline emitted ROI overrides on frame \(i)")
            XCTAssertTrue(update.candidates.isEmpty, "frame \(i)")
            XCTAssertNil(update.target, "frame \(i)")
            XCTAssertNil(update.selectionQuad, "frame \(i)")
            XCTAssertNil(update.analyzedFields, "frame \(i)")
            XCTAssertFalse(update.didLock, "frame \(i)")
            XCTAssertFalse(update.didRelease, "frame \(i)")
        }
    }

    /// `AppState` must treat an idle update as "nothing intelligent is running".
    @MainActor
    func testIdleUpdateLeavesAppStateManual() {
        let appState = AppState()
        let manual = appState.devices[0]

        appState.applyScreenLock(ScreenLockUpdate())

        XCTAssertEqual(appState.snapState, .manual)
        XCTAssertNil(appState.lockedTarget)
        XCTAssertTrue(appState.screenCandidates.isEmpty)
        XCTAssertNil(appState.fieldCatalog)
        XCTAssertEqual(appState.devices.map(\.id), [manual.id],
                       "an idle update disturbed the manual device list")
    }

    /// Going idle after the pipeline had published state must clear it, or the
    /// overlay keeps drawing a target that no longer exists.
    @MainActor
    func testIdleUpdateClearsPreviouslyPublishedLockState() {
        let appState = AppState()
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        var live = lockedUpdate(target: target)
        live.candidates = [ScreenCandidate(id: UUID(), quad: target.quad,
                                           signals: .zero, confidence: 0.95)]
        appState.applyScreenLock(live)
        XCTAssertEqual(appState.lockedTarget, target)
        XCTAssertEqual(appState.screenCandidates.count, 1)

        appState.applyScreenLock(ScreenLockUpdate())

        XCTAssertEqual(appState.snapState, .manual)
        XCTAssertNil(appState.lockedTarget)
        XCTAssertTrue(appState.screenCandidates.isEmpty)
    }

    /// The transparency proof for the override parameter: with an EMPTY override
    /// map, `process(frame:roiOverrides:)` must produce byte-for-byte the same
    /// readings as the original `process(frame:)`. This is what guarantees the
    /// manual workflow is untouched by the new parameter.
    func testEmptyROIOverridesAreTransparentToRecognition() async throws {
        let deviceID = UUID()
        let config = DeviceRecognitionConfig(id: deviceID,
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .defaultDMM)
        // Separate processors so per-device temporal/physical validator history
        // advances identically for both rather than being shared.
        let plain = MeasurementProcessor()
        let overridden = MeasurementProcessor()
        await plain.update(devices: [config])
        await overridden.update(devices: [config])

        var sawAnyOCRText = false
        for i in 0..<6 {
            // The SAME frame goes into both calls, so any difference is the
            // override parameter and nothing else.
            let frame = try makeFrame(timestamp: Double(i) / 12.0)
            let a = await plain.process(frame: frame)
            let b = await overridden.process(frame: frame, roiOverrides: [:])

            guard let left = a.readings[deviceID], let right = b.readings[deviceID] else {
                XCTFail("both calls must produce a reading for a configured device (frame \(i))")
                continue
            }
            if left.rawText != nil { sawAnyOCRText = true }
            XCTAssertEqual(left.accepted, right.accepted, "acceptance diverged on frame \(i)")
            XCTAssertEqual(left.unit, right.unit, "unit diverged on frame \(i)")
            XCTAssertEqual(left.value, right.value, accuracy: 1e-12,
                           "value diverged on frame \(i)")
            XCTAssertEqual(left.rawText, right.rawText, "raw text diverged on frame \(i)")
            XCTAssertEqual(a.observedROIs[deviceID], b.observedROIs[deviceID],
                           "observed ROI diverged on frame \(i)")
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
    }

    // MARK: - 2. Tracked geometry genuinely reroutes recognition
    //
    // The most valuable assertions in this file: the override map is not
    // decorative — it decides which pixels OCR reads.

    /// Panel moved well clear of the device's stored ROI. Without an override
    /// the device reads background and can never accept; with the tracked
    /// geometry it reads the panel and accepts the rendered value.
    func testTrackedGeometryOverrideReroutesRecognitionToAMovedPanel() async throws {
        let pose = DisplayPose(center: CGPoint(x: 0.5, y: 0.18),
                               roll: 0, yawScale: 1, pitchScale: 1, scale: 1)
        let trackedROI = renderer.panelROI(for: pose)
        XCTAssertFalse(trackedROI.cgRect.intersects(SyntheticDisplayRenderer.displayROI.cgRect),
                       "precondition: the moved panel must not overlap the stored ROI, or the "
                       + "no-override side is not actually looking at background")

        let deviceID = UUID()
        // The device's CONFIGURED ROI still points at the default panel location
        // — where the panel is not.
        let stored = DeviceRecognitionConfig(id: deviceID,
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .defaultDMM)
        let staleProcessor = MeasurementProcessor()
        let trackedProcessor = MeasurementProcessor()
        await staleProcessor.update(devices: [stored])
        await trackedProcessor.update(devices: [stored])

        var trackedSawOCRText = false
        var trackedAccepted: Double?
        var staleEverAccepted = false

        for i in 0..<8 {
            let frame = try makeFrame(pose: pose, timestamp: Double(i) / 12.0)

            let stale = await staleProcessor.process(frame: frame)
            if stale.readings[deviceID]?.accepted == true { staleEverAccepted = true }

            let tracked = await trackedProcessor.process(frame: frame,
                                                         roiOverrides: [deviceID: trackedROI])
            if let measurement = tracked.readings[deviceID] {
                if measurement.rawText != nil { trackedSawOCRText = true }
                if measurement.accepted { trackedAccepted = measurement.value }
            }
        }

        guard trackedSawOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        guard let trackedAccepted else {
            return XCTFail("tracked-geometry ROI should have accepted the rendered \"12.347\"")
        }
        XCTAssertEqual(trackedAccepted, 12.347, accuracy: 0.001)
        XCTAssertFalse(staleEverAccepted,
                       "the stored ROI was pointed at background and must never accept a reading")
    }

    /// The same proof against a MOVING panel driven by the deterministic demo
    /// motion rig: the tracked ROI changes every frame and keeps reading, while
    /// the stored ROI stays put and never does.
    func testTrackedGeometryFollowsABouncingPanelWhileTheStoredROIDoesNot() async throws {
        var motion = DemoMotionModel()
        motion.mode = .bounce
        let dt = 1.0 / 12.0
        // Advance the rig (without rendering) until the panel is clear of its
        // home position. Fully deterministic: `DemoMotionModel` integrates a
        // fixed velocity with no randomness and no clock.
        var pose = DisplayPose.identity
        for i in 0..<24 { pose = motion.pose(at: Double(i) * dt, dt: dt) }

        let deviceID = UUID()
        let stored = DeviceRecognitionConfig(id: deviceID,
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .defaultDMM)
        let staleProcessor = MeasurementProcessor()
        let trackedProcessor = MeasurementProcessor()
        await staleProcessor.update(devices: [stored])
        await trackedProcessor.update(devices: [stored])

        var trackedSawOCRText = false
        var trackedAccepted: Double?
        var staleEverAccepted = false

        for i in 24..<34 {
            pose = motion.pose(at: Double(i) * dt, dt: dt)
            let trackedROI = renderer.panelROI(for: pose)
            XCTAssertFalse(trackedROI.cgRect.intersects(SyntheticDisplayRenderer.displayROI.cgRect),
                           "precondition: panel overlapped the stored ROI on frame \(i)")

            let frame = try makeFrame(pose: pose, timestamp: Double(i) * dt)

            let stale = await staleProcessor.process(frame: frame)
            if stale.readings[deviceID]?.accepted == true { staleEverAccepted = true }

            let tracked = await trackedProcessor.process(frame: frame,
                                                         roiOverrides: [deviceID: trackedROI])
            if let measurement = tracked.readings[deviceID] {
                if measurement.rawText != nil { trackedSawOCRText = true }
                if measurement.accepted { trackedAccepted = measurement.value }
            }
        }

        guard trackedSawOCRText else {
            throw XCTSkip("Vision produced no OCR text on moving synthetic frames in this environment")
        }
        guard let trackedAccepted else {
            return XCTFail("per-frame tracked geometry should have accepted the rendered \"12.347\"")
        }
        XCTAssertEqual(trackedAccepted, 12.347, accuracy: 0.001)
        XCTAssertFalse(staleEverAccepted,
                       "a stationary stored ROI must never read a panel that has moved away from it")
    }

    /// Stage 6's arithmetic in isolation: a canonical-space field region
    /// projected through a target's homography. Pure math, no Vision — this is
    /// what turns tracked geometry into the ROI the override map carries.
    func testFieldRegionProjectsThroughTargetGeometry() throws {
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.1,
                                                                       width: 0.6, height: 0.3)),
                                   detectionConfidence: 0.95)
        // Right-hand half of the canonical display.
        let rightHalf = field(region: NormalizedROI(x: 0.5, y: 0, width: 0.5, height: 1))
        let projected = try XCTUnwrap(rightHalf.frameRegion(in: target))

        XCTAssertEqual(projected.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(projected.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(projected.width, 0.3, accuracy: 1e-9)
        XCTAssertEqual(projected.height, 0.3, accuracy: 1e-9)

        // Moving the target moves the field with it, with no per-field tracking.
        var moved = target
        moved.quad = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.5, width: 0.6, height: 0.3))
        let after = try XCTUnwrap(rightHalf.frameRegion(in: moved))
        XCTAssertEqual(after.y, 0.5, accuracy: 1e-9)
        XCTAssertEqual(after.x, 0.5, accuracy: 1e-9)
    }

    // MARK: - 3. Cadence

    /// Detection must not run on every frame.
    ///
    /// WHAT THIS PROVES: `ScreenCandidateDetector` is a concrete actor and
    /// `ScreenLockPipeline.init` takes that concrete type, so a counting stub
    /// cannot be injected. Instead this asserts the observable consequence: on a
    /// frame where detection ran, the emitted `candidates` array carries that
    /// frame's `lastSeen` timestamp, so consecutive detections over strictly
    /// increasing timestamps can never produce equal arrays. Frames whose
    /// `candidates` equal the previous frame's therefore did NOT run detection.
    ///
    /// The strong form of that argument is the RUN LENGTH of consecutive frames
    /// carrying an identical NON-EMPTY candidate array. Every candidate stamps
    /// `lastSeen` with its frame's timestamp, and the timestamps here are
    /// strictly increasing, so a detector running on every frame could never
    /// produce two consecutive frames with equal non-empty arrays — a run of
    /// length n is n-1 frames on which detection provably did not run.
    ///
    /// WHAT IT DOES NOT PROVE: it cannot count detection passes, and it cannot
    /// distinguish "detection skipped" from "detection ran and found nothing
    /// twice" on empty frames. That is why the non-empty run length, not the
    /// change count, carries the assertion, and why the test skips outright if
    /// the detector never proposed anything.
    func testDetectionDoesNotRunOnEveryFrame() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)

        var previous: [ScreenCandidate]?
        var changedFrames = 0
        var sawAnyCandidate = false
        var currentRun = 0
        var longestNonEmptyRun = 0
        let frameCount = 30 // exactly 1 s at 30 fps

        for i in 0..<frameCount {
            let frame = try makeFrame(timestamp: time(i))
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            XCTAssertFalse(update.isIdle, "frame \(i)")
            XCTAssertTrue(update.fieldROIs.isEmpty,
                          "no field is selected, so no override may be emitted (frame \(i))")
            if !update.candidates.isEmpty { sawAnyCandidate = true }
            if let previous, previous == update.candidates, !update.candidates.isEmpty {
                currentRun += 1
                longestNonEmptyRun = max(longestNonEmptyRun, currentRun)
            } else {
                currentRun = update.candidates.isEmpty ? 0 : 1
                if previous != nil, previous != update.candidates { changedFrames += 1 }
            }
            previous = update.candidates
        }

        guard sawAnyCandidate else {
            throw XCTSkip("the detector proposed nothing on synthetic frames here, so carried-forward "
                          + "candidate arrays cannot show whether detection was skipped")
        }
        // `acquiringDetectionInterval` is 0.2 s, i.e. every 6th frame at 30 fps,
        // so a proposal that survives one detection gap is repeated ~6 times.
        // Requiring 3 leaves room for the gap straddling the run's start/end.
        XCTAssertGreaterThanOrEqual(longestNonEmptyRun, 3,
                                    "the longest run of identical non-empty candidate arrays was "
                                    + "\(longestNonEmptyRun) frames; a detector running every frame "
                                    + "would restamp `lastSeen` and make every run length 1")
        // `changedFrames` is a weaker, complementary bound: at most 6 detection
        // passes fit in 1 s at a 0.2 s cadence, so the array cannot change more
        // often than that.
        XCTAssertLessThanOrEqual(changedFrames, 6,
                                 "candidates changed on \(changedFrames) of \(frameCount) frames — "
                                 + "detection is running more often than its 0.2 s cadence allows")
    }

    /// Tracked-geometry overrides require an actual lock. Selecting a field
    /// while nothing is locked must still leave the manual path in charge.
    func testSelectedFieldsProduceNoOverridesWithoutALock() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)
        // Deliberately a SELECTED NUMERIC field — the kind that WOULD produce an
        // override once a target exists.
        await pipeline.setSelectedFields([
            field(region: NormalizedROI(x: 0.1, y: 0.2, width: 0.6, height: 0.4),
                  kind: .numeric, isSelected: true),
            field(region: NormalizedROI(x: 0.1, y: 0.7, width: 0.6, height: 0.2),
                  kind: .label, label: "DCV", isSelected: true),
            field(region: NormalizedROI(x: 0.7, y: 0.2, width: 0.2, height: 0.4),
                  kind: .numeric, isSelected: false)
        ])

        for i in 0..<8 {
            let frame = try makeFrame(timestamp: time(i))
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            guard update.target == nil else {
                // A lock is legitimate here; once it happens the override map is
                // expected to be non-empty and this test no longer applies.
                throw XCTSkip("the pipeline locked onto the synthetic panel, so the "
                              + "no-lock precondition of this test no longer holds")
            }
            XCTAssertTrue(update.fieldROIs.isEmpty,
                          "fields produced ROI overrides with no locked target (frame \(i))")
        }
    }

    // MARK: - 4. Enable / disable lifecycle

    func testEnableThenDisableReturnsEverythingToIdle() async throws {
        let pipeline = ScreenLockPipeline()

        await pipeline.setEnabled(true)
        var isEnabled = await pipeline.enabled
        XCTAssertTrue(isEnabled)

        // Run a few frames so the pipeline accumulates detector history and snap
        // state — a teardown that only works from a cold start proves nothing.
        for i in 0..<6 {
            let frame = try makeFrame(timestamp: time(i))
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            XCTAssertFalse(update.isIdle, "frame \(i)")
        }

        await pipeline.setEnabled(false)
        isEnabled = await pipeline.enabled
        XCTAssertFalse(isEnabled)

        for i in 6..<10 {
            let frame = try makeFrame(timestamp: time(i))
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            XCTAssertTrue(update.isIdle, "frame \(i)")
            XCTAssertEqual(update.snapState, .manual, "frame \(i)")
            XCTAssertNil(update.target, "frame \(i)")
            XCTAssertTrue(update.candidates.isEmpty, "frame \(i)")
            XCTAssertTrue(update.fieldROIs.isEmpty, "frame \(i)")
            XCTAssertNil(update.analyzedFields, "frame \(i)")
        }

        // Re-enabling works, and starts from acquisition rather than resuming a
        // stale lock.
        await pipeline.setEnabled(true)
        let frame = try makeFrame(timestamp: time(10))
        let update = await pipeline.process(frame: frame,
                                            selection: panelSelection,
                                            isUserDragging: false)
        XCTAssertFalse(update.isIdle)
        XCTAssertFalse(update.snapState.isLockedOrTracking,
                       "re-enabling resumed a lock that teardown should have dropped")
        XCTAssertTrue(update.fieldROIs.isEmpty,
                      "re-enabling restored field selections that teardown should have cleared")
    }

    /// `release()` must be safe at any time, including with nothing locked, and
    /// must leave the pipeline emitting the manual/no-override shape.
    func testReleaseWithNothingLockedIsSafeAndStaysOverrideFree() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)
        await pipeline.release()

        let frame = try makeFrame(timestamp: time(0))
        let update = await pipeline.process(frame: frame,
                                            selection: panelSelection,
                                            isUserDragging: false)
        XCTAssertFalse(update.isIdle)
        XCTAssertNil(update.target)
        XCTAssertTrue(update.fieldROIs.isEmpty)
    }

    /// The pipeline must never throw or wedge on a frame-source switch, where
    /// the clock jumps backwards by tens of thousands of seconds.
    func testBackwardsTimestampJumpDoesNotWedgeThePipeline() async throws {
        let pipeline = ScreenLockPipeline()
        await pipeline.setEnabled(true)

        for timestamp in [51_234.7, 51_234.9, 0.0, 0.1, 0.2] {
            let frame = try makeFrame(timestamp: timestamp)
            let update = await pipeline.process(frame: frame,
                                                selection: panelSelection,
                                                isUserDragging: false)
            XCTAssertFalse(update.isIdle, "timestamp \(timestamp)")
        }
    }

    // MARK: - 5. AppState field → device mirroring

    @MainActor
    func testSelectingANumericFieldMirrorsItIntoDevices() {
        let appState = AppState()
        let manual = appState.devices[0]
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        let numeric = field(region: NormalizedROI(x: 0.05, y: 0.1, width: 0.5, height: 0.5),
                            kind: .numeric, label: "VOLTS", format: .defaultDMM)
        let unitField = field(region: NormalizedROI(x: 0.6, y: 0.1, width: 0.3, height: 0.5),
                              kind: .unit, label: "V")

        appState.applyScreenLock(lockedUpdate(target: target, analyzedFields: [numeric, unitField]))

        XCTAssertEqual(appState.fieldCatalog?.targetID, target.id)
        XCTAssertEqual(appState.fieldCatalog?.fields.count, 2)
        XCTAssertEqual(appState.devices.map(\.id), [manual.id],
                       "analysis alone must not create devices — selection is the user's choice")

        appState.toggleFieldSelection(numeric.id)

        XCTAssertEqual(appState.devices.count, 2)
        guard let mirrored = appState.devices.first(where: { $0.id == numeric.id }) else {
            return XCTFail("a selected numeric field must be mirrored into `devices` under its own id")
        }
        XCTAssertNil(mirrored.roi,
                     "a field-backed device's geometry is a per-frame projection, never a stored ROI")
        XCTAssertEqual(mirrored.displayFormat, .defaultDMM)
        XCTAssertEqual(mirrored.name, "VOLTS")

        // Deselecting removes it again.
        appState.toggleFieldSelection(numeric.id)
        XCTAssertEqual(appState.devices.map(\.id), [manual.id])
    }

    /// Only numeric fields are capturable; selecting a label or unit must not
    /// manufacture a device that can never produce a reading.
    @MainActor
    func testSelectingANonNumericFieldCreatesNoDevice() {
        let appState = AppState()
        let manual = appState.devices[0]
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        let labelField = field(region: NormalizedROI(x: 0.05, y: 0.1, width: 0.4, height: 0.4),
                               kind: .label, label: "DCV")
        appState.applyScreenLock(lockedUpdate(target: target, analyzedFields: [labelField]))

        appState.toggleFieldSelection(labelField.id)

        XCTAssertEqual(appState.fieldCatalog?.fields.first?.isSelected, true)
        XCTAssertEqual(appState.devices.map(\.id), [manual.id],
                       "a label field became a recordable device")
    }

    /// The manual device is the fallback the spec mandates: nothing the
    /// intelligent path does may touch it.
    @MainActor
    func testManualDeviceSurvivesTheWholeScreenLockLifecycle() {
        let appState = AppState()
        var manual = appState.devices[0]
        manual.roi = .defaultROI
        appState.updateDevice(manual)
        let manualSnapshot = appState.devices[0]

        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        let numeric = field(region: NormalizedROI(x: 0.05, y: 0.1, width: 0.5, height: 0.5),
                            kind: .numeric, label: "VOLTS")

        var locking = lockedUpdate(target: target, analyzedFields: [numeric])
        locking.didLock = true
        appState.applyScreenLock(locking)
        appState.toggleFieldSelection(numeric.id)
        appState.applyScreenLock(lockedUpdate(target: target))

        var releasing = ScreenLockUpdate(snapState: .manual, isIdle: false)
        releasing.didRelease = true
        appState.applyScreenLock(releasing)
        appState.applyScreenLock(ScreenLockUpdate())

        XCTAssertNil(appState.fieldCatalog, "a release must drop the catalog")
        guard let survivor = appState.devices.first(where: { $0.id == manualSnapshot.id }) else {
            return XCTFail("the manual device was removed by the screen-lock path")
        }
        XCTAssertEqual(survivor, manualSnapshot,
                       "the manual device was modified by the screen-lock path")
    }

    /// `screenLockInputs()` is the once-per-frame read `FrameProcessor` performs
    /// on the main actor; it must reflect the manual window and the drag flag.
    @MainActor
    func testScreenLockInputsReflectTheManualWindowAndDragState() {
        let appState = AppState()
        XCTAssertNil(appState.screenLockInputs().selection,
                     "a device with no placed window contributes no selection geometry")

        var device = appState.devices[0]
        device.roi = SyntheticDisplayRenderer.displayROI
        appState.updateDevice(device)
        appState.isEditingROI = true

        let inputs = appState.screenLockInputs()
        XCTAssertEqual(inputs.selection, ScreenQuad(roi: SyntheticDisplayRenderer.displayROI))
        XCTAssertTrue(inputs.isUserDragging)
    }

    /// Invariant 3: `applyScreenLock` runs at frame rate, so an update that
    /// changes nothing must not invalidate the capture screen. This is the same
    /// mechanism `CapturePerformanceTests` pins for `apply(_:)`.
    @MainActor
    func testApplyScreenLockDoesNotInvalidateUIWhenNothingChanged() {
        let appState = AppState()
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        var update = lockedUpdate(target: target)
        update.candidates = [ScreenCandidate(id: UUID(), quad: target.quad,
                                             signals: .zero, confidence: 0.95)]
        appState.applyScreenLock(update)

        var invalidations = 0
        for _ in 0..<30 {
            var invalidated = false
            withObservationTracking {
                _ = appState.snapState
                _ = appState.lockedTarget
                _ = appState.screenCandidates
                _ = appState.fieldCatalog
                _ = appState.devices
                _ = appState.liveReadings
            } onChange: {
                invalidated = true
            }
            appState.applyScreenLock(update)
            if invalidated { invalidations += 1 }
        }

        XCTAssertEqual(invalidations, 0,
                       "30 identical screen-lock updates invalidated the capture UI \(invalidations) "
                       + "times — this is the ROI drag-lag regression (ARCHITECTURE.md §2)")
    }

    /// The gate must not be so tight that real changes stop reaching the UI.
    @MainActor
    func testApplyScreenLockPublishesAChangedTarget() {
        let appState = AppState()
        let target = TrackedTarget(id: UUID(),
                                   quad: ScreenQuad(roi: SyntheticDisplayRenderer.displayROI),
                                   detectionConfidence: 0.95)
        appState.applyScreenLock(lockedUpdate(target: target))

        var moved = target
        moved.quad = ScreenQuad(roi: NormalizedROI(x: 0.2, y: 0.2, width: 0.5, height: 0.2))
        var invalidated = false
        withObservationTracking {
            _ = appState.lockedTarget
        } onChange: {
            invalidated = true
        }
        appState.applyScreenLock(lockedUpdate(target: moved))

        XCTAssertTrue(invalidated, "a moved target must reach the overlay")
        XCTAssertEqual(appState.lockedTarget?.quad, moved.quad)
    }
}
