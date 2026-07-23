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
//  The chart renders the precomputed, decimated `ResultsSessionModel`
//  series (built off-main, once per session) — never raw samples — so mark
//  count stays bounded regardless of recording length.
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
    let series: [ResultsSessionModel.DeviceSeries]
    let duration: TimeInterval

    init(series: [ResultsSessionModel.DeviceSeries], duration: TimeInterval) {
        self.series = series
        self.duration = duration
    }

    var body: some View {
        Chart {
            ForEach(series) { device in
                ForEach(Array(device.points.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Value", point.value),
                        series: .value("Device", device.name)
                    )
                    .foregroundStyle(ResultsSeriesPalette.color(at: device.paletteIndex))
                    .lineStyle(StrokeStyle(lineWidth: ResultsSeriesPalette.lineWidth(at: device.paletteIndex)))
                    .interpolationMethod(.linear)
                }

                ForEach(Array(device.rejectionTimes.enumerated()), id: \.offset) { _, time in
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
        .chartXScale(domain: 0...max(duration, 0.001))
        .chartXAxis {
            // Gridlines only: the surrounding card renders the handoff's
            // "0.00s → duration" endpoint labels, so in-chart labels would
            // duplicate them in a second format.
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine()
            }
        }
        .accessibilityLabel("Measurement versus time. Each device's line is scaled to its own value range; rejected readings are marked with a cross at the bottom of the plot.")
    }
}
