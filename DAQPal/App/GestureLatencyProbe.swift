//
//  GestureLatencyProbe.swift
//  DAQPal
//
//  Ground truth for "does the drag feel smooth", replacing inference with
//  measurement.
//
//  Three successive diagnoses of the SEARCHING drag defect (observable churn,
//  gesture reconstruction, pipeline cost) were each argued from reading code,
//  and the symptom survived all three. What was never measured is the only
//  thing the user can actually perceive: the interval between consecutive
//  `onChanged` callbacks while their finger is moving.
//
//  A drag delivered smoothly produces evenly spaced ticks at the display's
//  refresh interval (~8.3 ms at 120 Hz, ~16.7 ms at 60 Hz). Starvation shows up
//  as a long tail — the mean can look fine while a 200 ms stall is exactly what
//  reads as "jittery and sluggish". So this records EVERY tick and reports the
//  distribution, not an average.
//
//  DEBUG-only. Recording is an append to a preallocated ring buffer on the main
//  actor (where the gesture already runs), so it cannot itself perturb the
//  thing it measures.
//

#if DEBUG
import Foundation
import QuartzCore

/// Records inter-callback intervals for an in-progress gesture.
@MainActor
final class GestureLatencyProbe {
    static let shared = GestureLatencyProbe()

    /// ~8 s of ticks at 120 Hz; far more than any single drag.
    private static let capacity = 1024

    private var intervalsMS: [Double] = []
    private var lastTick: CFTimeInterval?
    private(set) var isRecording = false

    private init() {
        intervalsMS.reserveCapacity(Self.capacity)
    }

    func begin() {
        intervalsMS.removeAll(keepingCapacity: true)
        lastTick = nil
        isRecording = true
    }

    /// Call once per gesture `onChanged`.
    func tick() {
        guard isRecording else { return }
        let now = CACurrentMediaTime()
        defer { lastTick = now }
        guard let previous = lastTick else { return }
        guard intervalsMS.count < Self.capacity else { return }
        intervalsMS.append((now - previous) * 1000)
    }

    func end() {
        isRecording = false
        lastTick = nil
    }

    /// Distribution of inter-tick intervals, in milliseconds.
    struct Summary: Equatable {
        var tickCount: Int
        var p50: Double
        var p95: Double
        var worst: Double
        /// Ticks separated by more than ~3 display frames at 60 Hz. These are
        /// the stalls a user perceives; a smooth drag has none.
        var stalls: Int

        var debugLine: String {
            String(format: "ticks %d · p50 %.1fms · p95 %.1fms · max %.1fms · stalls %d",
                   tickCount, p50, p95, worst, stalls)
        }
    }

    var summary: Summary {
        guard !intervalsMS.isEmpty else {
            return Summary(tickCount: 0, p50: 0, p95: 0, worst: 0, stalls: 0)
        }
        let sorted = intervalsMS.sorted()
        func percentile(_ q: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.down))))
            return sorted[index]
        }
        return Summary(tickCount: sorted.count,
                       p50: percentile(0.50),
                       p95: percentile(0.95),
                       worst: sorted[sorted.count - 1],
                       stalls: sorted.filter { $0 > 50 }.count)
    }
}
#endif
