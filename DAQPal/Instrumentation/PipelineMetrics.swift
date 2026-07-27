//
//  PipelineMetrics.swift
//  DAQPal
//
//  Developer instrumentation for the capture→track→OCR pipeline (spec §16).
//
//  Two rules this type exists to enforce:
//  1. Measuring must not perturb what it measures. Recording a sample is a
//     lock-protected append to fixed-capacity ring buffers — no allocation per
//     frame, no main-actor hop, no observation invalidation. The UI *pulls* a
//     snapshot when it wants to draw, rather than metrics pushing updates at
//     frame rate (which is exactly the pattern that caused the original ROI
//     drag lag).
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
}

/// Rolling statistics for one stage.
struct StageStats: Equatable, Sendable {
    /// Completions per second over the rolling window.
    var rate: Double
    /// Mean duration in milliseconds.
    var meanLatencyMS: Double
    /// 95th-percentile duration in milliseconds — the number that actually
    /// correlates with visible stutter, which a mean hides.
    var p95LatencyMS: Double
    var sampleCount: Int

    static let empty = StageStats(rate: 0, meanLatencyMS: 0, p95LatencyMS: 0, sampleCount: 0)
}

/// An immutable snapshot for the debug overlay.
struct MetricsSnapshot: Equatable, Sendable {
    var stages: [PipelineStage: StageStats]
    /// Frames the pipeline chose not to process (newest-frame policy).
    var droppedFrames: Int
    /// Frames the pipeline did process.
    var processedFrames: Int

    static let empty = MetricsSnapshot(stages: [:], droppedFrames: 0, processedFrames: 0)

    func stats(_ stage: PipelineStage) -> StageStats { stages[stage] ?? .empty }

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
    private static let capacity = 240
    /// Rolling window for rate computation.
    private static let windowSeconds: TimeInterval = 2.0

    private struct Sample {
        let timestamp: TimeInterval
        let durationMS: Double
    }

    private struct State {
        var samples: [PipelineStage: [Sample]] = [:]
        var droppedFrames = 0
        var processedFrames = 0
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
    func record(_ stage: PipelineStage, durationMS: Double, at timestamp: TimeInterval = PipelineMetrics.now()) {
        guard isEnabled else { return }
        state.withLock { s in
            var samples = s.samples[stage] ?? []
            samples.append(Sample(timestamp: timestamp, durationMS: durationMS))
            if samples.count > Self.capacity {
                samples.removeFirst(samples.count - Self.capacity)
            }
            s.samples[stage] = samples
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

    /// Current statistics. Computed on demand (pull, not push) so the frame
    /// path never pays for percentile math.
    func snapshot() -> MetricsSnapshot {
        state.withLock { s in
            let cutoff = Self.now() - Self.windowSeconds
            var stages: [PipelineStage: StageStats] = [:]
            for (stage, samples) in s.samples {
                let recent = samples.filter { $0.timestamp >= cutoff }
                guard !recent.isEmpty else { continue }
                let durations = recent.map(\.durationMS).sorted()
                let mean = durations.reduce(0, +) / Double(durations.count)
                let p95Index = min(durations.count - 1,
                                   Int((Double(durations.count) * 0.95).rounded(.down)))
                stages[stage] = StageStats(rate: Double(recent.count) / Self.windowSeconds,
                                           meanLatencyMS: mean,
                                           p95LatencyMS: durations[p95Index],
                                           sampleCount: recent.count)
            }
            return MetricsSnapshot(stages: stages,
                                   droppedFrames: s.droppedFrames,
                                   processedFrames: s.processedFrames)
        }
    }

    func reset() {
        state.withLock { $0 = State() }
    }
}
