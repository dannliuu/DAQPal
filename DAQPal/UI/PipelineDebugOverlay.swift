//
//  PipelineDebugOverlay.swift
//  DAQPal
//
//  Developer HUD for the capture→track→OCR pipeline (spec §16 "Debug overlay").
//
//  Deliberately a PULL consumer of `PipelineMetrics`: a `TimelineView` ticks a
//  few times a second and reads a snapshot, rather than metrics pushing updates
//  into observable state at frame rate. Pushing would recreate the exact defect
//  this project already fixed once — per-frame observable writes invalidating
//  the capture screen and starving gesture handling (see ARCHITECTURE.md §2).
//
//  Every value shown is measured. Stages that have not run report "—" rather
//  than 0, so an idle stage is never mistaken for a fast one.
//

import SwiftUI

/// Compact metrics HUD. Shown only when the user enables the OCR/debug toggle,
/// and only in builds where `PipelineMetrics` is enabled (DEBUG by default).
struct PipelineDebugOverlay: View {
    /// Refresh cadence. Fast enough to feel live, slow enough that the HUD
    /// itself is not a meaningful load — it is a diagnostic, not a gauge.
    private static let refreshInterval: TimeInterval = 0.25

    /// Stages worth surfacing, in pipeline order.
    private static let shownStages: [PipelineStage] = [.capture, .tracking, .detection, .analysis, .ocr, .endToEnd]

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            content(snapshot: PipelineMetrics.shared.snapshot())
        }
    }

    private func content(snapshot: MetricsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.shownStages, id: \.self) { stage in
                let stats = snapshot.stats(stage)
                HStack(spacing: 6) {
                    Text(stage.displayLabel)
                        .foregroundStyle(Theme.brandYellow)
                        .frame(width: 30, alignment: .leading)
                    if stats.sampleCount == 0 {
                        Text("—").foregroundStyle(.white.opacity(0.35))
                    } else {
                        Text(rateText(stats.rate))
                            .frame(width: 46, alignment: .trailing)
                        Text(msText(stats.meanLatencyMS))
                            .frame(width: 52, alignment: .trailing)
                        Text("p95 \(msText(stats.p95LatencyMS))")
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            if snapshot.processedFrames + snapshot.droppedFrames > 0 {
                Divider().background(.white.opacity(0.2))
                HStack(spacing: 6) {
                    Text("DROP").foregroundStyle(Theme.brandYellow)
                        .frame(width: 30, alignment: .leading)
                    Text("\(snapshot.droppedFrames)/\(snapshot.droppedFrames + snapshot.processedFrames)")
                    Text(String(format: "%.0f%%", snapshot.dropRate * 100))
                        .foregroundStyle(snapshot.dropRate > 0.5 ? Theme.roiSearching : .white.opacity(0.6))
                }
            }
        }
        .font(Theme.mono(9))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.68)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func rateText(_ rate: Double) -> String {
        rate >= 10 ? String(format: "%.0f/s", rate) : String(format: "%.1f/s", rate)
    }

    private func msText(_ ms: Double) -> String {
        ms >= 100 ? String(format: "%.0fms", ms) : String(format: "%.1fms", ms)
    }
}

/// Draws the live acquisition geometry over the viewport: the tracked screen
/// quad, its corners, and the current snap state. Distinct from
/// `ROISelectionOverlay`, which draws the user's *selection*; this draws what
/// the system currently believes about the target.
struct TargetGeometryOverlay: View {
    let quad: ScreenQuad?
    let candidates: [ScreenCandidate]
    let snapState: SnapState
    let mapper: AspectFillMapper

    var body: some View {
        ZStack {
            // Candidates first, so the committed target draws on top of them.
            ForEach(candidates) { candidate in
                quadPath(candidate.quad)
                    .stroke(Theme.roiSearching.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .overlay(alignment: .topLeading) {
                        confidenceTag(candidate.confidence, at: candidate.quad)
                    }
            }
            if let quad {
                quadPath(quad)
                    .stroke(Theme.brandYellow, lineWidth: 2)
                ForEach(Array(quad.corners.enumerated()), id: \.offset) { _, corner in
                    let p = mapper.viewPoint(fromNormalized: corner)
                    Circle()
                        .fill(Theme.brandYellow)
                        .frame(width: 6, height: 6)
                        .position(x: p.x, y: p.y)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func quadPath(_ quad: ScreenQuad) -> Path {
        var path = Path()
        let points = quad.corners.map { mapper.viewPoint(fromNormalized: $0) }
        guard let first = points.first else { return path }
        path.move(to: first)
        for p in points.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    private func confidenceTag(_ confidence: Float, at quad: ScreenQuad) -> some View {
        let p = mapper.viewPoint(fromNormalized: quad.corners[0])
        return Text(String(format: "%.0f%%", confidence * 100))
            .font(Theme.mono(8, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 3)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6)))
            .position(x: p.x + 16, y: p.y - 7)
    }
}
