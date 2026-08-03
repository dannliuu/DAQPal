//
//  RenderCadenceProbe.swift
//  DAQPal
//
//  Measures RENDERED frames during a gesture, which is what the user actually
//  sees — as opposed to `GestureLatencyProbe`, which measures touch callbacks.
//
//  WHY BOTH EXIST. Measured on device, drag callbacks arrive every 16.7 ms with
//  zero stalls while the drag still feels sluggish and jittery. That is not a
//  contradiction: UIKit delivers touch events at display cadence regardless of
//  whether rendering keeps up. A frame that takes 40 ms to render drops frames
//  and judders visibly while the callback stream stays perfectly regular. So a
//  clean `GestureLatencyProbe` reading rules out event starvation and says
//  nothing about smoothness.
//
//  `CADisplayLink` fires once per frame the system actually composites, so a
//  missed frame shows up directly as a long interval. That is the quantity that
//  corresponds to "judder".
//
//  DEBUG-only. The callback does a single subtraction and an append into a
//  preallocated buffer, on the main thread where it already runs.
//

#if DEBUG
import Foundation
import QuartzCore

/// Records the interval between composited frames while a gesture is active.
@MainActor
final class RenderCadenceProbe {
    static let shared = RenderCadenceProbe()

    private static let capacity = 1024

    private var link: CADisplayLink?
    private var intervalsMS: [Double] = []
    private var lastFrame: CFTimeInterval?
    /// The display's own frame duration, so "dropped" is defined against the
    /// hardware rather than an assumed 60 Hz.
    private var expectedMS: Double = 1000.0 / 60.0

    private init() { intervalsMS.reserveCapacity(Self.capacity) }

    func begin() {
        stopLink()
        intervalsMS.removeAll(keepingCapacity: true)
        lastFrame = nil
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func end() { stopLink() }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        // `targetTimestamp - timestamp` is the display's real frame duration,
        // which differs between a 60 Hz and a 120 Hz ProMotion panel and can
        // change when the system throttles the refresh rate.
        let frameDuration = link.targetTimestamp - link.timestamp
        if frameDuration > 0 { expectedMS = frameDuration * 1000 }

        let now = link.timestamp
        defer { lastFrame = now }
        guard let previous = lastFrame else { return }
        guard intervalsMS.count < Self.capacity else { return }
        intervalsMS.append((now - previous) * 1000)
    }

    struct Summary: Equatable {
        var frameCount: Int
        var expectedMS: Double
        var p50: Double
        var p95: Double
        var worst: Double
        /// Intervals longer than 1.5x the display's frame duration — i.e. at
        /// least one composited frame was missed.
        var droppedFrames: Int

        var debugLine: String {
            String(format: "frames %d · exp %.1fms · p50 %.1fms · p95 %.1fms · max %.1fms · dropped %d",
                   frameCount, expectedMS, p50, p95, worst, droppedFrames)
        }
    }

    var summary: Summary {
        guard !intervalsMS.isEmpty else {
            return Summary(frameCount: 0, expectedMS: expectedMS, p50: 0, p95: 0, worst: 0, droppedFrames: 0)
        }
        let sorted = intervalsMS.sorted()
        func percentile(_ q: Double) -> Double {
            let index = min(sorted.count - 1, max(0, Int((Double(sorted.count) * q).rounded(.down))))
            return sorted[index]
        }
        let threshold = expectedMS * 1.5
        return Summary(frameCount: sorted.count,
                       expectedMS: expectedMS,
                       p50: percentile(0.50),
                       p95: percentile(0.95),
                       worst: sorted[sorted.count - 1],
                       droppedFrames: sorted.filter { $0 > threshold }.count)
    }
}
#endif
