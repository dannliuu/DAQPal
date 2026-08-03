//
//  PipelineMetrics.swift
//  DAQPal
//
//  Developer instrumentation for the capture→track→OCR pipeline (spec §16).
//
//  Two rules this type exists to enforce:
//  1. Measuring must not perturb what it measures. Recording a sample is a
//     lock-protected store into a PREALLOCATED fixed-capacity ring — no
//     allocation per frame, no main-actor hop, no observation invalidation. The
//     UI *pulls* a snapshot when it wants to draw, rather than metrics pushing
//     updates at frame rate (which is exactly the pattern that caused the
//     original ROI drag lag).
//  2. Nothing is claimed that isn't measured. Every value here comes from a
//     real timing; absent stages report nil, not zero.
//

import Foundation
import os

/// The pipeline stages that are timed independently.
enum PipelineStage: String, CaseIterable, Sendable {
    case capture
    case tracking
    case detection
    case analysis
    case ocr
    case endToEnd

    var displayLabel: String {
        switch self {
        case .capture: "CAP"
        case .tracking: "TRK"
        case .detection: "DET"
        case .analysis: "ANL"
        case .ocr: "OCR"
        case .endToEnd: "E2E"
        }
    }

    /// Dense index into the preallocated ring storage. A `switch` rather than
    /// `allCases.firstIndex(of:)` so the record path performs no array scan and
    /// no `allCases` materialization.
    var storageIndex: Int {
        switch self {
        case .capture: 0
        case .tracking: 1
        case .detection: 2
        case .analysis: 3
        case .ocr: 4
        case .endToEnd: 5
        }
    }

    static let storageCount = 6
}

/// A place where one pipeline stage hands work to the next. Queue depth and
/// overflow are properties of the BOUNDARY, not of either stage, which is why
/// they are counted separately from stage latency (spec §16, "queue depth and
/// overflow counts exposed per boundary").
enum PipelineBoundary: String, CaseIterable, Sendable {
    /// `FrameSource.frames()` → `FrameProcessor`. Backed by an `AsyncStream`
    /// with `.bufferingNewest(1)`, so its depth is 0 or 1 and every displaced
    /// frame is an overflow.
    case captureToProcessing
    /// `FrameProcessor` → `AppState` (the `MainActor.run` hop).
    case processingToUI

    var storageIndex: Int {
        switch self {
        case .captureToProcessing: 0
        case .processingToUI: 1
        }
    }

    static let storageCount = 2
}

/// A repeated unit of work whose COUNT per frame is the thing worth bounding.
///
/// Latency alone cannot distinguish "one expensive solve" from "N cheap solves"
/// — but the second is the one that turns into an O(fields) blowup as the user
/// selects more fields. Counting the units directly makes that assertable
/// without a stopwatch (spec §2: measure the mechanism, not the wall clock).
enum PipelineWorkUnit: String, CaseIterable, Sendable {
    /// `Homography.solve` calls — each is a fresh 8×9 Gaussian elimination.
    case homographySolve
    /// Field regions projected from canonical space into frame space.
    case fieldProjection
    /// Vision recognition requests issued.
    case ocrRequest

    var storageIndex: Int {
        switch self {
        case .homographySolve: 0
        case .fieldProjection: 1
        case .ocrRequest: 2
        }
    }

    static let storageCount = 3
}

/// Rolling statistics for one stage.
struct StageStats: Equatable, Sendable {
    /// Completions per second over the rolling window.
    var rate: Double
    /// Mean duration in milliseconds.
    var meanLatencyMS: Double
    /// Median duration in milliseconds.
    var p50LatencyMS: Double
    /// 95th-percentile duration in milliseconds — the number that actually
    /// correlates with visible stutter, which a mean hides.
    var p95LatencyMS: Double
    /// 99th-percentile duration in milliseconds. At 60 Hz a p99 is roughly
    /// "once a second", which is squarely in the range a user perceives as a
    /// hitch, so it is reported alongside p95 rather than instead of it.
    var p99LatencyMS: Double
    var sampleCount: Int

    static let empty = StageStats(rate: 0, meanLatencyMS: 0, p50LatencyMS: 0,
                                  p95LatencyMS: 0, p99LatencyMS: 0, sampleCount: 0)
}

/// Depth/overflow accounting for one hand-off boundary.
struct QueueStats: Equatable, Sendable {
    /// Most recently reported depth.
    var currentDepth: Int
    /// Highest depth ever reported since the last `reset()`.
    var maxDepth: Int
    /// Items the boundary discarded because it was full. For a
    /// `.bufferingNewest(1)` stream this is the dropped-frame count for that
    /// boundary specifically.
    var overflowCount: Int

    static let empty = QueueStats(currentDepth: 0, maxDepth: 0, overflowCount: 0)
}

/// Counted work for one unit kind.
struct WorkUnitStats: Equatable, Sendable {
    /// Units counted since the last `reset()`.
    var total: Int
    /// Highest count attributed to a single frame.
    var maxPerFrame: Int
    /// Count attributed to the frame currently in flight (cleared by
    /// `beginFrame()`).
    var currentFrame: Int

    static let empty = WorkUnitStats(total: 0, maxPerFrame: 0, currentFrame: 0)
}

/// An immutable snapshot for the debug overlay.
struct MetricsSnapshot: Equatable, Sendable {
    var stages: [PipelineStage: StageStats]
    /// Frames the pipeline chose not to process (newest-frame policy).
    var droppedFrames: Int
    /// Frames the pipeline did process.
    var processedFrames: Int
    /// Per-boundary queue accounting. Absent boundaries were never reported.
    var queues: [PipelineBoundary: QueueStats]
    /// Per-kind counted work. Absent kinds were never counted.
    var workUnits: [PipelineWorkUnit: WorkUnitStats]

    static let empty = MetricsSnapshot(stages: [:], droppedFrames: 0, processedFrames: 0,
                                       queues: [:], workUnits: [:])

    init(stages: [PipelineStage: StageStats],
         droppedFrames: Int,
         processedFrames: Int,
         queues: [PipelineBoundary: QueueStats] = [:],
         workUnits: [PipelineWorkUnit: WorkUnitStats] = [:]) {
        self.stages = stages
        self.droppedFrames = droppedFrames
        self.processedFrames = processedFrames
        self.queues = queues
        self.workUnits = workUnits
    }

    func stats(_ stage: PipelineStage) -> StageStats { stages[stage] ?? .empty }
    func queue(_ boundary: PipelineBoundary) -> QueueStats { queues[boundary] ?? .empty }
    func work(_ unit: PipelineWorkUnit) -> WorkUnitStats { workUnits[unit] ?? .empty }

    /// Mean units of `unit` per processed frame, or nil when no frame has been
    /// counted (never 0 — "not measured" and "zero work" are different claims).
    func workPerFrame(_ unit: PipelineWorkUnit) -> Double? {
        guard processedFrames > 0, let stats = workUnits[unit] else { return nil }
        return Double(stats.total) / Double(processedFrames)
    }

    /// Fraction of delivered frames that were dropped, 0...1.
    var dropRate: Double {
        let total = droppedFrames + processedFrames
        return total > 0 ? Double(droppedFrames) / Double(total) : 0
    }
}

/// Process-wide metrics recorder.
///
/// Thread-safe and callable from any isolation domain. Enabled by default only
/// in DEBUG: in release the record path compiles to a cheap early return so
/// instrumentation costs nothing in shipping builds (spec: "disable or minimize
/// instrumentation in production").
final class PipelineMetrics: @unchecked Sendable {
    static let shared = PipelineMetrics()

    /// Samples retained per stage. At 60 fps this is ~4 s of history — enough
    /// for a stable p95, small enough to stay cache-friendly.
    static let capacity = 240
    /// Rolling window for rate computation.
    private static let windowSeconds: TimeInterval = 2.0

    private struct Sample {
        var timestamp: TimeInterval
        var durationMS: Double

        static let zero = Sample(timestamp: 0, durationMS: 0)
    }

    /// Fixed-capacity ring over a buffer allocated ONCE.
    ///
    /// The previous implementation kept `[PipelineStage: [Sample]]` and did
    /// `var a = dict[stage] ?? []; a.append(...); dict[stage] = a`. Lifting the
    /// array out of the dictionary makes it non-uniquely referenced, so the
    /// `append` copied the entire 240-element buffer — a heap allocation and an
    /// O(capacity) copy on every single frame, in the very type whose contract
    /// is "no allocation per frame". Writing into a preallocated slot through
    /// `inout` access keeps the buffer uniquely referenced, so `store` is a
    /// bounds-checked store and an integer increment: no allocation, no copy,
    /// no `removeFirst` memmove.
    private struct Ring {
        var storage: ContiguousArray<Sample>
        /// Next slot to write.
        var cursor: Int = 0
        /// Slots that hold a real sample (saturates at `capacity`).
        var filled: Int = 0

        init(capacity: Int) {
            storage = ContiguousArray(repeating: .zero, count: capacity)
        }

        mutating func store(_ sample: Sample) {
            storage[cursor] = sample
            cursor = (cursor + 1) % storage.count
            if filled < storage.count { filled += 1 }
        }
    }

    private struct State {
        var rings: [Ring]
        var droppedFrames = 0
        var processedFrames = 0
        var queues: [QueueStats]
        var queuesTouched: [Bool]
        var work: [WorkUnitStats]
        var workTouched: [Bool]

        init() {
            rings = (0..<PipelineStage.storageCount).map { _ in Ring(capacity: PipelineMetrics.capacity) }
            queues = Array(repeating: .empty, count: PipelineBoundary.storageCount)
            queuesTouched = Array(repeating: false, count: PipelineBoundary.storageCount)
            work = Array(repeating: .empty, count: PipelineWorkUnit.storageCount)
            workTouched = Array(repeating: false, count: PipelineWorkUnit.storageCount)
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Master switch. DEBUG-on / release-off by default; settable either way so
    /// a release build can be profiled deliberately.
    private let enabledFlag: OSAllocatedUnfairLock<Bool>

    init() {
#if DEBUG
        enabledFlag = OSAllocatedUnfairLock(initialState: true)
#else
        enabledFlag = OSAllocatedUnfairLock(initialState: false)
#endif
    }

    var isEnabled: Bool {
        get { enabledFlag.withLock { $0 } }
        set { enabledFlag.withLock { $0 = newValue } }
    }

    /// Monotonic clock shared by all timing here. Never wall-clock.
    static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Records one completed stage execution.
    ///
    /// Allocation-free by inspection: `Sample` is a trivial struct held inline,
    /// `s.rings[index].store(...)` reaches the preallocated buffer through
    /// `inout` accessors only (no copy is ever lifted out), and neither the
    /// rings array nor its storage is resized.
    func record(_ stage: PipelineStage, durationMS: Double, at timestamp: TimeInterval = PipelineMetrics.now()) {
        guard isEnabled else { return }
        let sample = Sample(timestamp: timestamp, durationMS: durationMS)
        let index = stage.storageIndex
        state.withLock { s in
            s.rings[index].store(sample)
        }
    }

    /// Times `body`, records it under `stage`, and returns its value.
    func measure<T>(_ stage: PipelineStage, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = Self.now()
        let value = try body()
        record(stage, durationMS: (Self.now() - start) * 1000)
        return value
    }

    /// Async variant of `measure`.
    func measure<T>(_ stage: PipelineStage, _ body: () async throws -> T) async rethrows -> T {
        guard isEnabled else { return try await body() }
        let start = Self.now()
        let value = try await body()
        record(stage, durationMS: (Self.now() - start) * 1000)
        return value
    }

    func recordDroppedFrame() {
        guard isEnabled else { return }
        state.withLock { $0.droppedFrames += 1 }
    }

    func recordProcessedFrame() {
        guard isEnabled else { return }
        state.withLock { $0.processedFrames += 1 }
    }

    // MARK: - Queue accounting

    /// Reports the depth of a hand-off boundary. Integer stores only.
    func recordQueueDepth(_ boundary: PipelineBoundary, depth: Int) {
        guard isEnabled else { return }
        let index = boundary.storageIndex
        state.withLock { s in
            s.queuesTouched[index] = true
            s.queues[index].currentDepth = depth
            if depth > s.queues[index].maxDepth { s.queues[index].maxDepth = depth }
        }
    }

    /// Reports items a boundary discarded because it was full.
    func recordQueueOverflow(_ boundary: PipelineBoundary, count: Int = 1) {
        guard isEnabled else { return }
        let index = boundary.storageIndex
        state.withLock { s in
            s.queuesTouched[index] = true
            s.queues[index].overflowCount += count
        }
    }

    // MARK: - Work-unit counting

    /// Starts a new frame's work accounting: folds the frame just finished into
    /// `maxPerFrame` and clears the per-frame counters.
    ///
    /// Deliberately separate from `recordProcessedFrame()` — a frame can be
    /// *delivered* to a stage that counts work without being a fully processed
    /// pipeline frame, and conflating the two would silently mis-divide
    /// work-per-frame.
    func beginFrame() {
        guard isEnabled else { return }
        state.withLock { s in
            for i in 0..<PipelineWorkUnit.storageCount {
                if s.work[i].currentFrame > s.work[i].maxPerFrame {
                    s.work[i].maxPerFrame = s.work[i].currentFrame
                }
                s.work[i].currentFrame = 0
            }
        }
    }

    /// Counts `count` units of repeated work. Integer increments into a
    /// preallocated fixed-size array — no allocation, no hashing.
    func countWorkUnit(_ unit: PipelineWorkUnit, _ count: Int = 1) {
        guard isEnabled else { return }
        let index = unit.storageIndex
        state.withLock { s in
            s.workTouched[index] = true
            s.work[index].total += count
            s.work[index].currentFrame += count
            if s.work[index].currentFrame > s.work[index].maxPerFrame {
                s.work[index].maxPerFrame = s.work[index].currentFrame
            }
        }
    }

    // MARK: - Snapshot

    /// Current statistics. Computed on demand (pull, not push) so the frame
    /// path never pays for percentile math.
    func snapshot() -> MetricsSnapshot {
        state.withLock { s in
            let cutoff = Self.now() - Self.windowSeconds
            var stages: [PipelineStage: StageStats] = [:]
            for stage in PipelineStage.allCases {
                let ring = s.rings[stage.storageIndex]
                guard ring.filled > 0 else { continue }
                var durations: [Double] = []
                durations.reserveCapacity(ring.filled)
                for i in 0..<ring.filled {
                    let sample = ring.storage[i]
                    if sample.timestamp >= cutoff { durations.append(sample.durationMS) }
                }
                guard !durations.isEmpty else { continue }
                durations.sort()
                let mean = durations.reduce(0, +) / Double(durations.count)
                stages[stage] = StageStats(rate: Double(durations.count) / Self.windowSeconds,
                                           meanLatencyMS: mean,
                                           p50LatencyMS: Self.percentile(durations, 0.50),
                                           p95LatencyMS: Self.percentile(durations, 0.95),
                                           p99LatencyMS: Self.percentile(durations, 0.99),
                                           sampleCount: durations.count)
            }

            var queues: [PipelineBoundary: QueueStats] = [:]
            for boundary in PipelineBoundary.allCases where s.queuesTouched[boundary.storageIndex] {
                queues[boundary] = s.queues[boundary.storageIndex]
            }

            var work: [PipelineWorkUnit: WorkUnitStats] = [:]
            for unit in PipelineWorkUnit.allCases where s.workTouched[unit.storageIndex] {
                work[unit] = s.work[unit.storageIndex]
            }

            return MetricsSnapshot(stages: stages,
                                   droppedFrames: s.droppedFrames,
                                   processedFrames: s.processedFrames,
                                   queues: queues,
                                   workUnits: work)
        }
    }

    /// Nearest-rank percentile over an ASCENDING-sorted array.
    ///
    /// `index = ceil(p · n) − 1`, the standard nearest-rank definition: for
    /// n = 100 the p95 is the 95th smallest sample, not the 96th. (The previous
    /// `floor(n · p)` form returned the 96th, i.e. it was one rank optimistic —
    /// wrong in the direction that under-reports tail latency.)
    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((Double(sorted.count) * p).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
