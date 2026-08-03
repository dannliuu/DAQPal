//
//  PipelineBudgetTests.swift
//  DAQPalTests
//
//  Deterministic performance-REGRESSION coverage for the frame path
//  (spec §2 "measurement", §3 "explicit budgets", §16A "standing performance
//  regression discipline").
//
//  Deliberately NOT wall-clock tests. A `measure {}` block or a "must complete
//  in < 5 ms" assertion on a shared CI runner is noise: it fails for reasons
//  unrelated to the change under test, and a suite people learn to re-run until
//  green stops protecting anything. Everything here asserts a MECHANISM that
//  determines cost — how many times an O(n³)-ish solve runs per frame, whether
//  the cheap branch is taken, whether the recorder's own bookkeeping is bounded
//  — so a regression fails for exactly one reason and the failure names the
//  cause.
//
//  What this file does NOT do is claim any stage meets its §3 budget. No stage
//  latency is measured here, and the honest inventory of which stages are
//  instrumented at all is in `testInventory_stagesWithProductionInstrumentation`
//  below.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class PipelineBudgetTests: XCTestCase {

    // MARK: - Fixtures

    private func roi(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NormalizedROI {
        NormalizedROI(x: x, y: y, width: w, height: h)
    }

    /// A convex, perspective-distorted quad — the realistic locked-display case
    /// (an axis-aligned quad would let a degenerate homography pass unnoticed).
    private var tiltedQuad: ScreenQuad {
        ScreenQuad(topLeft: CGPoint(x: 0.18, y: 0.22),
                   topRight: CGPoint(x: 0.79, y: 0.16),
                   bottomRight: CGPoint(x: 0.84, y: 0.61),
                   bottomLeft: CGPoint(x: 0.13, y: 0.55))
    }

    private func makeTarget() -> TrackedTarget {
        TrackedTarget(quad: tiltedQuad, detectionConfidence: 0.95, lastUpdated: 1.0)
    }

    /// `count` non-overlapping canonical-space field regions laid out in rows.
    private func makeFields(count: Int) -> [ScreenField] {
        (0..<count).map { i in
            let column = CGFloat(i % 4), row = CGFloat(i / 4)
            return ScreenField(region: roi(0.02 + column * 0.24,
                                           0.02 + row * 0.12,
                                           0.20, 0.09),
                               kind: .numeric,
                               label: "F\(i)",
                               isSelected: true)
        }
    }

    private func makeFrame(timestamp: TimeInterval) throws -> TimestampedFrame {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 160, 120,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: timestamp)
    }

    /// A private recorder instance — never `PipelineMetrics.shared`, so these
    /// tests neither observe nor perturb whatever the rest of the suite records.
    private func makeMetrics() -> PipelineMetrics {
        let metrics = PipelineMetrics()
        metrics.isEnabled = true
        metrics.reset()
        return metrics
    }

    // MARK: - 1. Homography solves are O(targets), not O(fields)

    /// `TrackedTarget` stores NO homography.
    ///
    /// This is the structural half of the O(fields) proof. `canonicalToFrame` is
    /// a computed property whose body is `Homography.solve(from:to:)`; if the
    /// type held a memoized transform it would appear here as a stored property.
    /// It does not — so every read of `canonicalToFrame` runs a full 8×9
    /// Gaussian elimination (allocating an `[[CGFloat]]` of 8 nine-element rows
    /// each time), and `ScreenField.frameRegion(in:)` reads it exactly once per
    /// call.
    func testTrackedTarget_hasNoMemoizedHomography_soEveryAccessResolves() {
        let mirror = Mirror(reflecting: makeTarget())
        let stored = mirror.children.compactMap(\.label)

        XCTAssertFalse(stored.contains("canonicalToFrame"),
                       "canonicalToFrame became a stored property — update the O(fields) tests below, the cost model changed.")
        XCTAssertFalse(stored.contains("frameToCanonical"))
        for child in mirror.children {
            XCTAssertFalse(child.value is Homography,
                           "TrackedTarget gained a stored Homography (\(child.label ?? "?")) — the per-access solve model no longer holds.")
        }
        XCTAssertEqual(Set(stored),
                       ["id", "quad", "referenceQuad", "detectionConfidence",
                        "trackingConfidence", "health", "lastUpdated", "degradedSince"],
                       "TrackedTarget's stored shape changed; re-derive the solve cost model before trusting these tests.")
    }

    /// FINDING, asserted as current behaviour: projecting N fields for ONE frame
    /// solves the canonical→frame homography N times, not once.
    ///
    /// `ScreenLockPipeline` stage 6 is `for field in selectedFields { field.frameRegion(in: target) }`,
    /// and `frameRegion` opens with `guard let h = target.canonicalToFrame`. With
    /// no memoization (proved above) that is one DLT solve per selected field per
    /// frame, for a transform that is invariant across the whole loop — exactly
    /// the O(fields) growth §2 warns about. `FieldSelectionOverlay` repeats the
    /// same pattern on the main thread, once per field per SwiftUI body pass.
    ///
    /// The counter below models that loop rather than intercepting
    /// `Homography.solve` (a static on a struct: not interceptable, and this file
    /// may not edit `TargetLock.swift`/`ScreenQuad.swift`). The model is sound
    /// because the two facts it depends on are proved by the tests either side of
    /// it: (a) no memoization exists, and (b) the per-field results are
    /// bit-identical to hoisting a single solve.
    ///
    /// WHEN THIS IS FIXED — by caching the transform on the target or by hoisting
    /// the solve out of stage 6 — this test must be inverted to assert 1.
    func testFieldProjection_currentlySolvesOneHomographyPerField() {
        let metrics = makeMetrics()
        let target = makeTarget()
        let fields = makeFields(count: 12)

        metrics.beginFrame()
        // Current shape: `frameRegion(in:)` per field, each reading
        // `target.canonicalToFrame` once.
        for field in fields {
            metrics.countWorkUnit(.homographySolve)   // the canonicalToFrame read
            metrics.countWorkUnit(.fieldProjection)
            XCTAssertNotNil(field.frameRegion(in: target))
        }

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.work(.fieldProjection).currentFrame, fields.count)
        XCTAssertEqual(snapshot.work(.homographySolve).currentFrame, fields.count,
                       "Documented O(fields) behaviour: \(fields.count) fields cost \(fields.count) homography solves in one frame. If this now fails with a lower count the hoist landed — invert this assertion to expect 1.")
        XCTAssertGreaterThan(snapshot.work(.homographySolve).currentFrame, 1,
                             "Solves per frame should be O(targets) — one per tracked target — not O(fields).")
    }

    /// The solve is loop-INVARIANT: hoisting it changes nothing observable.
    ///
    /// This is what makes the finding above actionable rather than a complaint.
    /// One solve, reused for every field, reproduces `frameRegion(in:)` exactly —
    /// so the N−1 redundant solves are pure waste, and removing them is
    /// behaviour-preserving.
    func testFieldProjection_hoistedSolveIsBitIdenticalToPerFieldSolve() throws {
        let target = makeTarget()
        let fields = makeFields(count: 12)

        let hoisted = try XCTUnwrap(target.canonicalToFrame,
                                    "A convex tracked quad must have a solvable canonical→frame transform.")
        for field in fields {
            let perField = try XCTUnwrap(field.frameRegion(in: target))
            let viaHoisted = try XCTUnwrap(hoisted.apply(ScreenQuad(roi: field.region)))
            XCTAssertEqual(perField,
                           ScreenField.unitSquareClamped(viaHoisted.boundingBox),
                           "Hoisting the canonical→frame solve out of the per-field loop changed a projected region; the redundant solves are NOT redundant.")
        }
    }

    /// `Homography.solve` is a pure function of its two quads — the precondition
    /// for caching it per target per frame.
    func testHomographySolve_isDeterministicForAFixedQuad() throws {
        let target = makeTarget()
        let first = try XCTUnwrap(target.canonicalToFrame)
        for _ in 0..<8 {
            XCTAssertEqual(try XCTUnwrap(target.canonicalToFrame), first,
                           "Repeated solves of the same quad differed — the transform is not cacheable and the O(fields) cost is unavoidable.")
        }
    }

    /// Cost must scale with TARGETS. One target's transform serves every one of
    /// its fields; two targets genuinely need two solves.
    func testHomographySolve_countScalesWithTargetsNotFields() throws {
        let a = makeTarget()
        var b = makeTarget()
        b.quad = ScreenQuad(roi: roi(0.05, 0.62, 0.4, 0.2))

        let ha = try XCTUnwrap(a.canonicalToFrame)
        let hb = try XCTUnwrap(b.canonicalToFrame)
        XCTAssertNotEqual(ha, hb, "Two differently-posed targets must not share a transform.")

        // Field count is irrelevant to how many DISTINCT transforms exist: two
        // targets need two, whether they carry 1 field each or 100.
        for count in [1, 20] {
            for field in makeFields(count: count) {
                XCTAssertEqual(field.frameRegion(in: a),
                               ScreenField.unitSquareClamped(try XCTUnwrap(ha.apply(ScreenQuad(roi: field.region))).boundingBox))
                XCTAssertEqual(field.frameRegion(in: b),
                               ScreenField.unitSquareClamped(try XCTUnwrap(hb.apply(ScreenQuad(roi: field.region))).boundingBox))
            }
        }
    }

    // MARK: - 2. Override-map construction is bounded

    /// With no overrides and nothing requiring one, every configured device is
    /// processed — the branch that reuses `configs` wholesale instead of
    /// rebuilding a job per device.
    func testProcess_emptyOverrideMap_processesEveryConfiguredDevice() async throws {
        let processor = MeasurementProcessor()
        let ids = (0..<3).map { _ in UUID() }
        await processor.update(devices: ids.map {
            DeviceRecognitionConfig(id: $0, roi: roi(0.2, 0.4, 0.5, 0.15), format: .unconstrained)
        })

        let result = await processor.process(frame: try makeFrame(timestamp: 1.0))

        XCTAssertEqual(Set(result.readings.keys), Set(ids),
                       "The empty-override path must process every configured device and no others.")
    }

    /// Work is O(configured devices), never O(override entries). An override for
    /// an id the processor has never seen must not manufacture a job.
    func testProcess_overridesForUnknownDevices_doNotCreateWork() async throws {
        let processor = MeasurementProcessor()
        let known = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: known, roi: roi(0.2, 0.4, 0.5, 0.15), format: .unconstrained)
        ])

        var overrides: [UUID: NormalizedROI] = [:]
        for _ in 0..<50 { overrides[UUID()] = roi(0.1, 0.1, 0.2, 0.1) }

        let result = await processor.process(frame: try makeFrame(timestamp: 1.0),
                                             roiOverrides: overrides)

        XCTAssertEqual(Set(result.readings.keys), [known],
                       "A 50-entry override map for unknown devices produced \(result.readings.count) readings; job count must be bounded by the device set.")
    }

    /// No configured devices means no frame work at all, regardless of how large
    /// the override map is — the earliest possible exit.
    func testProcess_noConfiguredDevices_doesNoWorkEvenWithOverrides() async throws {
        let processor = MeasurementProcessor()
        var overrides: [UUID: NormalizedROI] = [:]
        var requiring: Set<UUID> = []
        for _ in 0..<32 {
            let id = UUID()
            overrides[id] = roi(0.1, 0.1, 0.2, 0.1)
            requiring.insert(id)
        }

        let result = await processor.process(frame: try makeFrame(timestamp: 2.0),
                                             roiOverrides: overrides,
                                             requiringOverride: requiring)

        XCTAssertTrue(result.readings.isEmpty)
        XCTAssertNil(result.debugText)
    }

    /// The expensive branch exists for exactly one reason: a field-backed device
    /// with no override this frame must be SKIPPED, not read at its placeholder
    /// ROI. Skipping is what keeps the work bounded when tracking drops out.
    func testProcess_fieldBackedDeviceWithoutOverride_isSkipped() async throws {
        let processor = MeasurementProcessor()
        let manual = UUID(), fieldBacked = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: manual, roi: roi(0.2, 0.4, 0.5, 0.15), format: .unconstrained),
            DeviceRecognitionConfig(id: fieldBacked, roi: roi(0.2, 0.6, 0.5, 0.15), format: .unconstrained)
        ])

        let skipped = await processor.process(frame: try makeFrame(timestamp: 1.0),
                                              roiOverrides: [:],
                                              requiringOverride: [fieldBacked])
        XCTAssertEqual(Set(skipped.readings.keys), [manual],
                       "A field-backed device with no override must be skipped, not read at its placeholder ROI.")

        let supplied = await processor.process(frame: try makeFrame(timestamp: 1.1),
                                               roiOverrides: [fieldBacked: roi(0.3, 0.3, 0.3, 0.1)],
                                               requiringOverride: [fieldBacked])
        XCTAssertEqual(Set(supplied.readings.keys), [manual, fieldBacked],
                       "Supplying the override must reinstate the device.")
    }

    /// The manual workflow's guarantee, restated as a cost property: a device
    /// that is not field-backed is never affected by the override machinery.
    func testProcess_manualDeviceUnaffectedByOverrideMachinery() async throws {
        let processor = MeasurementProcessor()
        let manual = UUID(), other = UUID()
        await processor.update(devices: [
            DeviceRecognitionConfig(id: manual, roi: roi(0.2, 0.4, 0.5, 0.15), format: .unconstrained),
            DeviceRecognitionConfig(id: other, roi: roi(0.2, 0.6, 0.5, 0.15), format: .unconstrained)
        ])

        let result = await processor.process(frame: try makeFrame(timestamp: 3.0),
                                             roiOverrides: [other: roi(0.1, 0.1, 0.3, 0.1)],
                                             requiringOverride: [other])

        XCTAssertNotNil(result.readings[manual],
                        "The manual (fallback) device must be processed whether or not anything else is field-backed.")
    }

    // MARK: - 3. Metrics recording is cheap and correct

    /// Recording is bounded: N ≫ capacity samples retain at most `capacity`.
    /// A recorder whose memory grows with uptime is itself a leak in the frame
    /// path, which is the failure this pins.
    func testMetrics_recordingIsBoundedByCapacity() {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0
        let total = PipelineMetrics.capacity * 3

        for i in 0..<total {
            metrics.record(.tracking, durationMS: Double(i % 7) + 1, at: base)
        }

        let stats = metrics.snapshot().stats(.tracking)
        XCTAssertEqual(stats.sampleCount, PipelineMetrics.capacity,
                       "\(total) samples retained \(stats.sampleCount); the ring must cap at \(PipelineMetrics.capacity).")
    }

    /// Percentiles against a fully known distribution: 1…100 ms, one sample per
    /// integer. Nearest-rank means p50 = 50, p95 = 95, p99 = 99 — the 95th
    /// smallest of 100, not the 96th.
    func testMetrics_percentilesAgainstAKnownDistribution() {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0
        for ms in 1...100 {
            metrics.record(.ocr, durationMS: Double(ms), at: base)
        }

        let stats = metrics.snapshot().stats(.ocr)
        XCTAssertEqual(stats.sampleCount, 100)
        XCTAssertEqual(stats.meanLatencyMS, 50.5, accuracy: 1e-9)
        XCTAssertEqual(stats.p50LatencyMS, 50, accuracy: 1e-9)
        XCTAssertEqual(stats.p95LatencyMS, 95, accuracy: 1e-9)
        XCTAssertEqual(stats.p99LatencyMS, 99, accuracy: 1e-9)
    }

    /// p99 must be the tail, not a rounded p95. 98 samples at 5 ms plus one at
    /// 500 ms is the stutter case §2 describes: the mean barely moves, p95 does
    /// not see it at all, p99 must.
    ///
    /// n = 99 is chosen so nearest-rank puts the single outlier inside the top
    /// 1% (`ceil(99 × 0.99) − 1 = 98`, the last index) and outside the top 5%
    /// (`ceil(99 × 0.95) − 1 = 94`). With n = 100 a lone outlier is the 100th of
    /// 100 and correctly falls OUTSIDE the p99 — which is a property of the
    /// definition, not a bug, and is why the sample size is stated.
    func testMetrics_p99ExposesATailThatP95AndMeanHide() {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0
        for _ in 0..<98 { metrics.record(.endToEnd, durationMS: 5, at: base) }
        metrics.record(.endToEnd, durationMS: 500, at: base)

        let stats = metrics.snapshot().stats(.endToEnd)
        XCTAssertEqual(stats.sampleCount, 99)
        XCTAssertEqual(stats.p50LatencyMS, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.p95LatencyMS, 5, accuracy: 1e-9, "p95 must not see a 1-in-99 outlier.")
        XCTAssertEqual(stats.meanLatencyMS, 10, accuracy: 1e-9, "The mean barely moves — that is the point.")
        XCTAssertEqual(stats.p99LatencyMS, 500, accuracy: 1e-9,
                       "p99 must surface the tail sample that the mean and p95 hide.")
    }

    /// Percentiles must be well-defined at tiny sample counts too (a single
    /// sample is its own p50/p95/p99).
    func testMetrics_percentilesAreWellDefinedForOneSample() {
        let metrics = makeMetrics()
        metrics.record(.detection, durationMS: 42, at: PipelineMetrics.now() + 1.0)

        let stats = metrics.snapshot().stats(.detection)
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.p50LatencyMS, 42, accuracy: 1e-9)
        XCTAssertEqual(stats.p95LatencyMS, 42, accuracy: 1e-9)
        XCTAssertEqual(stats.p99LatencyMS, 42, accuracy: 1e-9)
    }

    /// Stages are independent: recording one must not appear under another, and
    /// an untouched stage must report `.empty` rather than zeros that read like
    /// a measurement.
    func testMetrics_untouchedStagesAreAbsentNotZero() {
        let metrics = makeMetrics()
        metrics.record(.tracking, durationMS: 7, at: PipelineMetrics.now() + 1.0)

        let snapshot = metrics.snapshot()
        XCTAssertNotNil(snapshot.stages[.tracking])
        XCTAssertNil(snapshot.stages[.ocr],
                     "An unmeasured stage must be ABSENT, not reported as 0 ms — absence is the honest claim.")
        XCTAssertEqual(snapshot.stats(.ocr), .empty)
    }

    /// Disabled metrics record nothing at all — the release-build contract.
    func testMetrics_disabledRecordsNothing() {
        let metrics = makeMetrics()
        metrics.isEnabled = false

        let base = PipelineMetrics.now() + 1.0
        for i in 0..<50 { metrics.record(.tracking, durationMS: Double(i), at: base) }
        metrics.recordDroppedFrame()
        metrics.recordProcessedFrame()
        metrics.recordQueueDepth(.captureToProcessing, depth: 9)
        metrics.recordQueueOverflow(.captureToProcessing, count: 4)
        metrics.beginFrame()
        metrics.countWorkUnit(.homographySolve, 17)

        XCTAssertEqual(metrics.snapshot(), .empty,
                       "A disabled recorder must be completely inert.")
    }

    /// Re-enabling after a disabled stretch must not resurrect anything that was
    /// dropped while off.
    func testMetrics_reEnablingDoesNotResurrectDroppedSamples() {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0

        metrics.isEnabled = false
        for _ in 0..<10 { metrics.record(.analysis, durationMS: 99, at: base) }
        metrics.isEnabled = true
        metrics.record(.analysis, durationMS: 1, at: base)

        let stats = metrics.snapshot().stats(.analysis)
        XCTAssertEqual(stats.sampleCount, 1)
        XCTAssertEqual(stats.p99LatencyMS, 1, accuracy: 1e-9)
    }

    // MARK: - 3b. Queue and work-unit facilities

    /// Queue depth tracks the latest value and remembers the high-water mark;
    /// overflow accumulates. Both are what a `.bufferingNewest(1)` boundary needs
    /// to prove it is bounded rather than merely believed to be.
    func testMetrics_queueDepthAndOverflowAccounting() {
        let metrics = makeMetrics()
        metrics.recordQueueDepth(.captureToProcessing, depth: 1)
        metrics.recordQueueDepth(.captureToProcessing, depth: 3)
        metrics.recordQueueDepth(.captureToProcessing, depth: 0)
        metrics.recordQueueOverflow(.captureToProcessing)
        metrics.recordQueueOverflow(.captureToProcessing, count: 5)

        let queue = metrics.snapshot().queue(.captureToProcessing)
        XCTAssertEqual(queue.currentDepth, 0)
        XCTAssertEqual(queue.maxDepth, 3, "maxDepth must be a high-water mark, not the latest depth.")
        XCTAssertEqual(queue.overflowCount, 6)

        XCTAssertNil(metrics.snapshot().queues[.processingToUI],
                     "An unreported boundary must be absent, not a fabricated zero-depth queue.")
    }

    /// Per-frame work accounting: `beginFrame()` closes the previous frame into
    /// `maxPerFrame` and clears the running count, so "solves per frame" is a
    /// real per-frame figure rather than a lifetime total.
    func testMetrics_workUnitsPerFrameAreAttributedToTheirFrame() throws {
        let metrics = makeMetrics()

        metrics.beginFrame()
        for _ in 0..<3 { metrics.countWorkUnit(.homographySolve) }
        metrics.recordProcessedFrame()

        metrics.beginFrame()
        for _ in 0..<11 { metrics.countWorkUnit(.homographySolve) }
        metrics.recordProcessedFrame()

        metrics.beginFrame()
        metrics.countWorkUnit(.homographySolve, 2)
        metrics.recordProcessedFrame()

        let snapshot = metrics.snapshot()
        let work = snapshot.work(.homographySolve)
        XCTAssertEqual(work.total, 16)
        XCTAssertEqual(work.currentFrame, 2, "The in-flight frame's count must be the current frame's alone.")
        XCTAssertEqual(work.maxPerFrame, 11, "The worst frame is the one that determines the budget.")
        XCTAssertEqual(try XCTUnwrap(snapshot.workPerFrame(.homographySolve)), 16.0 / 3.0, accuracy: 1e-9)
    }

    /// An uncounted work unit reports nil per-frame, not 0. "We did not count
    /// OCR requests" and "we issued zero OCR requests" are different claims and
    /// the API must not conflate them.
    func testMetrics_uncountedWorkUnitReportsNilNotZero() {
        let metrics = makeMetrics()
        metrics.recordProcessedFrame()
        metrics.countWorkUnit(.fieldProjection, 4)

        let snapshot = metrics.snapshot()
        XCTAssertEqual(snapshot.workPerFrame(.fieldProjection), 4)
        XCTAssertNil(snapshot.workPerFrame(.ocrRequest),
                     "An uncounted work unit must report nil, never a fabricated 0.")
        XCTAssertNil(snapshot.workUnits[.ocrRequest])
    }

    /// `reset()` clears everything, so a test or a profiling run can start from a
    /// known state without allocating a new recorder.
    func testMetrics_resetClearsAllFacilities() {
        let metrics = makeMetrics()
        metrics.record(.tracking, durationMS: 3, at: PipelineMetrics.now() + 1.0)
        metrics.recordProcessedFrame()
        metrics.recordDroppedFrame()
        metrics.recordQueueDepth(.processingToUI, depth: 2)
        metrics.countWorkUnit(.ocrRequest, 5)

        metrics.reset()

        XCTAssertEqual(metrics.snapshot(), .empty)
    }

    // MARK: - 4. Concurrency safety

    /// `PipelineMetrics` is `@unchecked Sendable`: the compiler is being told to
    /// trust the lock. This asserts the lock actually holds under concurrent
    /// recorders — no lost updates, no torn samples.
    ///
    /// Every recorder writes a duration unique to it, and the total is chosen to
    /// fit inside `capacity` so nothing is legitimately evicted: any missing or
    /// unexpected value is corruption, not policy.
    func testMetrics_concurrentRecordingLosesNoSamples() async {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0
        let recorders = 8
        let perRecorder = 20            // 160 total < capacity (240)

        await withTaskGroup(of: Void.self) { group in
            for r in 0..<recorders {
                group.addTask {
                    for i in 0..<perRecorder {
                        // Distinct per (recorder, i): 1.0…8.19, no collisions.
                        metrics.record(.tracking,
                                       durationMS: Double(r + 1) + Double(i) / 100.0,
                                       at: base)
                    }
                }
            }
        }

        let stats = metrics.snapshot().stats(.tracking)
        XCTAssertEqual(stats.sampleCount, recorders * perRecorder,
                       "Concurrent recorders lost samples: expected \(recorders * perRecorder), got \(stats.sampleCount).")
        // Every recorded value must lie in the emitted set — a torn write would
        // land outside it.
        XCTAssertGreaterThanOrEqual(stats.p50LatencyMS, 1.0)
        XCTAssertLessThanOrEqual(stats.p99LatencyMS, Double(recorders) + 0.2)
        XCTAssertEqual(stats.meanLatencyMS,
                       (1.0 + Double(recorders)) / 2.0 + Double(perRecorder - 1) / 200.0,
                       accuracy: 1e-9,
                       "The mean of all emitted samples is fixed regardless of interleaving; a mismatch means a lost or duplicated write.")
    }

    /// Counters must not lose increments under contention either.
    func testMetrics_concurrentCountersAreExact() async {
        let metrics = makeMetrics()
        let writers = 8, perWriter = 250

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<writers {
                group.addTask {
                    for _ in 0..<perWriter {
                        metrics.countWorkUnit(.ocrRequest)
                        metrics.recordProcessedFrame()
                        metrics.recordDroppedFrame()
                        metrics.recordQueueOverflow(.captureToProcessing)
                    }
                }
            }
        }

        let snapshot = metrics.snapshot()
        let expected = writers * perWriter
        XCTAssertEqual(snapshot.work(.ocrRequest).total, expected)
        XCTAssertEqual(snapshot.processedFrames, expected)
        XCTAssertEqual(snapshot.droppedFrames, expected)
        XCTAssertEqual(snapshot.queue(.captureToProcessing).overflowCount, expected)
        XCTAssertEqual(snapshot.dropRate, 0.5, accuracy: 1e-9)
    }

    /// Snapshotting concurrently with recording must never crash or observe a
    /// half-written sample. Sample counts are not asserted here (they race by
    /// design); what is asserted is that every observed statistic is internally
    /// consistent.
    func testMetrics_snapshotConcurrentWithRecordingStaysConsistent() async {
        let metrics = makeMetrics()
        let base = PipelineMetrics.now() + 1.0

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for i in 0..<600 {
                    metrics.record(.detection, durationMS: Double(i % 50) + 1, at: base)
                }
            }
            group.addTask {
                for _ in 0..<200 {
                    let stats = metrics.snapshot().stats(.detection)
                    XCTAssertLessThanOrEqual(stats.sampleCount, PipelineMetrics.capacity)
                    if stats.sampleCount > 0 {
                        XCTAssertGreaterThanOrEqual(stats.p50LatencyMS, 1)
                        XCTAssertLessThanOrEqual(stats.p50LatencyMS, stats.p95LatencyMS)
                        XCTAssertLessThanOrEqual(stats.p95LatencyMS, stats.p99LatencyMS)
                        XCTAssertLessThanOrEqual(stats.p99LatencyMS, 50)
                        XCTAssertGreaterThanOrEqual(stats.meanLatencyMS, 1)
                        XCTAssertLessThanOrEqual(stats.meanLatencyMS, 50)
                    }
                }
            }
        }
    }

    // MARK: - Honest instrumentation inventory (spec §3 / §16)

    /// The §3 budget table names ten frame-path stages. `PipelineStage` covers
    /// six of them, and only THREE have a production call site today
    /// (`.tracking` in `VisionScreenTracker`, `.detection` in
    /// `ScreenCandidateDetector`, `.analysis` in `ScreenFieldAnalyzer` and
    /// `PerspectiveNormalizer`). `.capture`, `.ocr` and `.endToEnd` are declared
    /// but never recorded, so no snapshot can report them.
    ///
    /// The property this pins is that an uninstrumented stage is INDISTINGUISHABLE
    /// from absent — it can never surface as "0 ms", which would read to anyone
    /// looking at the overlay as a measured, excellent result. Recording one
    /// stage must not conjure entries for the others.
    func testInventory_uninstrumentedStagesCannotBeReportedAsNumbers() {
        let metrics = makeMetrics()
        // Only the three stages that have production call sites today.
        let base = PipelineMetrics.now() + 1.0
        metrics.record(.tracking, durationMS: 4, at: base)
        metrics.record(.detection, durationMS: 30, at: base)
        metrics.record(.analysis, durationMS: 120, at: base)

        let snapshot = metrics.snapshot()
        XCTAssertEqual(Set(snapshot.stages.keys), [.tracking, .detection, .analysis])

        for stage in [PipelineStage.capture, .ocr, .endToEnd] {
            XCTAssertNil(snapshot.stages[stage],
                         "\(stage.rawValue) has no production `PipelineMetrics.measure` call site; it must report ABSENT, never a number a reader could mistake for a measurement.")
            XCTAssertEqual(snapshot.stats(stage).sampleCount, 0,
                           "\(stage.rawValue) must report a zero SAMPLE COUNT, which is how a reader tells 'unmeasured' from 'fast'.")
        }
        XCTAssertNil(snapshot.workPerFrame(.homographySolve),
                     "Homography solves per frame are not counted in production yet — the facility exists, the call sites do not.")
        XCTAssertTrue(snapshot.queues.isEmpty,
                      "No production code reports queue depth yet; the boundaries must stay absent until it does.")
    }
}
