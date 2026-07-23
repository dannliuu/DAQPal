//
//  ResultsModel.swift
//  DAQPal
//
//  Precomputed, render-ready results data. Built ONCE per completed session on
//  a background task; view bodies only read it. This bounds the chart's mark
//  count and removes per-body full-session scans so the results screen stays
//  responsive for multi-thousand-sample recordings (a 20-minute session at
//  ~10 processed fps is ~12k samples — far past what Swift Charts renders
//  interactively without decimation).
//

import Foundation

struct ResultsSessionModel: Sendable {
    struct ChartPoint: Sendable, Equatable {
        let time: Double
        let value: Double
    }

    struct DeviceSeries: Sendable, Identifiable {
        /// Device id.
        let id: UUID
        let name: String
        let unit: String?
        /// Index into `ResultsSeriesPalette`.
        let paletteIndex: Int
        /// Accepted readings normalized to this device's own min/max
        /// (dual-scale plotting), min/max-decimated to a bounded count.
        let points: [ChartPoint]
        /// Rejection timestamps (relative seconds), binned to a bounded count.
        let rejectionTimes: [Double]
    }

    struct DeviceStats: Sendable {
        let minimum: Double
        let mean: Double
        let maximum: Double
    }

    let sessionID: UUID
    let acceptedCount: Int
    let rejectedCount: Int
    let series: [DeviceSeries]
    /// Accepted-only stats per device, computed from the FULL (undecimated)
    /// value set; absent when a device has no accepted readings.
    let stats: [UUID: DeviceStats]

    /// Time bins per line series; each bin contributes at most its min and max
    /// point, so extremes (spikes/steps) survive decimation.
    static let maxLineBins = 300
    static let maxRejectionMarks = 160

    static func build(from session: CompletedSession) -> ResultsSessionModel {
        var acceptedCount = 0
        var rejectedCount = 0
        // Samples are appended chronologically, so per-device arrays come out
        // time-ordered without sorting.
        var acceptedByDevice: [UUID: [ChartPoint]] = [:]
        var rejectionsByDevice: [UUID: [Double]] = [:]

        for sample in session.samples {
            let time = session.relativeTime(sample.timestamp)
            for (deviceID, reading) in sample.readings {
                if reading.accepted {
                    acceptedCount += 1
                    if reading.value.isFinite {
                        acceptedByDevice[deviceID, default: []]
                            .append(ChartPoint(time: time, value: reading.value))
                    }
                } else {
                    rejectedCount += 1
                    rejectionsByDevice[deviceID, default: []].append(time)
                }
            }
        }

        let duration = max(session.duration, 0.001)
        var series: [DeviceSeries] = []
        var stats: [UUID: DeviceStats] = [:]
        for (index, device) in session.devices.enumerated() {
            let accepted = acceptedByDevice[device.id] ?? []
            if let stat = deviceStats(accepted) {
                stats[device.id] = stat
            }
            series.append(DeviceSeries(
                id: device.id,
                name: device.name,
                unit: device.unit,
                paletteIndex: index,
                points: normalizedDecimated(accepted, duration: duration),
                rejectionTimes: binnedRejectionTimes(rejectionsByDevice[device.id] ?? [],
                                                     duration: duration)))
        }

        return ResultsSessionModel(sessionID: session.id,
                                   acceptedCount: acceptedCount,
                                   rejectedCount: rejectedCount,
                                   series: series,
                                   stats: stats)
    }

    // MARK: - Private

    private static func deviceStats(_ points: [ChartPoint]) -> DeviceStats? {
        guard !points.isEmpty else { return nil }
        var minimum = points[0].value
        var maximum = points[0].value
        var sum = 0.0
        for point in points {
            minimum = min(minimum, point.value)
            maximum = max(maximum, point.value)
            sum += point.value
        }
        return DeviceStats(minimum: minimum, mean: sum / Double(points.count), maximum: maximum)
    }

    /// Maps values into 0...1 against the device's own min/max (a near-flat
    /// series is widened slightly so it renders mid-plot instead of dividing
    /// by ~0), then min/max-bins by time when the series exceeds the mark
    /// budget.
    private static func normalizedDecimated(_ points: [ChartPoint],
                                            duration: Double) -> [ChartPoint] {
        guard !points.isEmpty else { return [] }
        var minValue = points[0].value
        var maxValue = points[0].value
        for point in points {
            minValue = min(minValue, point.value)
            maxValue = max(maxValue, point.value)
        }
        if maxValue - minValue < 1e-6 {
            minValue -= 0.01
            maxValue += 0.01
        }
        let range = maxValue - minValue
        let normalized = points.map {
            ChartPoint(time: $0.time, value: ($0.value - minValue) / range)
        }

        guard normalized.count > maxLineBins * 2 else { return normalized }

        let binWidth = duration / Double(maxLineBins)
        var result: [ChartPoint] = []
        result.reserveCapacity(maxLineBins * 2)
        var currentBin = -1
        var binMin: ChartPoint?
        var binMax: ChartPoint?

        func flush() {
            guard let low = binMin, let high = binMax else { return }
            if low == high {
                result.append(low)
            } else {
                result.append(contentsOf: low.time <= high.time ? [low, high] : [high, low])
            }
        }

        for point in normalized {
            let bin = min(Int(point.time / binWidth), maxLineBins - 1)
            if bin != currentBin {
                flush()
                currentBin = bin
                binMin = point
                binMax = point
                continue
            }
            if point.value < (binMin?.value ?? .infinity) { binMin = point }
            if point.value > (binMax?.value ?? -.infinity) { binMax = point }
        }
        flush()
        return result
    }

    /// Keeps the first rejection per time bin once the raw count exceeds the
    /// marker budget — rejections stay visible at every time region they
    /// occurred without drawing thousands of overlapping "✕" marks.
    private static func binnedRejectionTimes(_ times: [Double],
                                             duration: Double) -> [Double] {
        guard times.count > maxRejectionMarks else { return times }
        let binWidth = duration / Double(maxRejectionMarks)
        var seen = Set<Int>()
        var result: [Double] = []
        for time in times {
            let bin = min(Int(time / binWidth), maxRejectionMarks - 1)
            if seen.insert(bin).inserted { result.append(time) }
        }
        return result
    }
}
