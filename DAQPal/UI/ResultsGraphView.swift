//
//  ResultsGraphView.swift
//  DAQPal
//
//  "MEASUREMENT vs TIME" chart on the results screen (design handoff §3).
//  Dual-scale: each device's accepted readings are normalized to that
//  device's own min/max so unrelated units (V vs A) share one plot area —
//  the y-axis therefore carries no numeric meaning and its labels are
//  hidden; only the 3 reference gridlines remain. Rejected readings are
//  never hidden — they are pinned as red "✕" markers at the bottom of the
//  plot at their timestamp.
//

import Charts
import SwiftUI

/// Per-device line/marker color, shared between the graph and its legend
/// (`ResultsView`). Devices 1 and 2 use the handoff's dedicated series
/// colors; further devices (up to `AppState.maxDevices`) fall back to
/// distinguishable ink-toned colors.
enum ResultsSeriesPalette {
    static func color(at index: Int) -> Color {
        switch index {
        case 0: return Theme.graphSeries1
        case 1: return Theme.graphSeries2
        default:
            let tones: [Color] = [Color(hex: 0x8A6B00), Color(hex: 0x4A5A3D), Color(hex: 0x5C4632)]
            return tones[(index - 2) % tones.count]
        }
    }

    static func lineWidth(at index: Int) -> CGFloat {
        switch index {
        case 0: return 2
        case 1: return 1.6
        default: return 1.3
        }
    }
}

struct ResultsGraphView: View {
    let session: CompletedSession

    init(session: CompletedSession) {
        self.session = session
    }

    var body: some View {
        Chart {
            ForEach(Array(session.devices.enumerated()), id: \.element.id) { index, device in
                let normalized = normalizedPoints(for: device)
                ForEach(Array(normalized.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value(device.name, point.value)
                    )
                    .foregroundStyle(ResultsSeriesPalette.color(at: index))
                    .lineStyle(StrokeStyle(lineWidth: ResultsSeriesPalette.lineWidth(at: index)))
                    .interpolationMethod(.linear)
                }

                let rejections = rejectedTimes(for: device)
                ForEach(Array(rejections.enumerated()), id: \.offset) { _, time in
                    PointMark(x: .value("Time", time), y: .value("Rejected", 0))
                        .symbol {
                            Text("✕")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Theme.recordRed)
                        }
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 0.5, 1]) { _ in
                AxisGridLine()
            }
        }
        .chartXScale(domain: 0...max(session.duration, 0.001))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(String(format: "%.1fs", seconds))
                    }
                }
            }
        }
        .accessibilityLabel("Measurement versus time. Each device's line is scaled to its own value range; rejected readings are marked with a cross at the bottom of the plot.")
    }

    /// Accepted-only points for one device, value mapped into 0...1 against
    /// that device's own min/max (dual-scale plotting, design handoff §3).
    private func normalizedPoints(for device: Device) -> [(time: Double, value: Double)] {
        let points = session.acceptedPoints(for: device.id)
        guard !points.isEmpty else { return [] }
        let values = points.map(\.value)
        var minValue = values.min() ?? 0
        var maxValue = values.max() ?? 0
        if maxValue - minValue < 1e-6 {
            // A flat/near-flat series would otherwise divide by ~0; widen the
            // window slightly so it renders as a flat mid-plot line.
            minValue -= 0.01
            maxValue += 0.01
        }
        return points.map { point in
            (time: point.time, value: (point.value - minValue) / (maxValue - minValue))
        }
    }

    /// Relative timestamps of every rejected reading for one device — plotted
    /// regardless of whether that device has any accepted points at all.
    private func rejectedTimes(for device: Device) -> [Double] {
        session.samples.compactMap { sample in
            guard let reading = sample.readings[device.id], !reading.accepted else { return nil }
            return session.relativeTime(sample.timestamp)
        }
    }
}
