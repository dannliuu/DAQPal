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

// MARK: - Screen-relative overlay geometry (spec §8A / Gate 6A)

/// Pure geometry shared by every overlay that draws a *screen-relative* outline
/// (`TargetGeometryOverlay`, `FieldSelectionOverlay`).
///
/// Why it is its own type rather than methods on the views: the whole point of
/// this layer is that the outline must wrap the tracked quadrilateral rather
/// than its axis-aligned bounding box, and that claim is only credible if it is
/// testable without rendering SwiftUI. Everything here is `static` and free of
/// view state so `OverlayGeometryTests` can assert on the vertices directly.
///
/// Coordinate contract, unchanged from the rest of the app: inputs are
/// normalized 0...1 with a TOP-LEFT origin, outputs are container (view) points
/// via `AspectFillMapper` — the *same* mapper instance shape `ROISelectionOverlay`
/// builds, so all overlays agree in both live and simulated capture modes.
enum OverlayQuadGeometry {

    /// Below this normalized area a quad carries no usable shape information —
    /// projecting it produces a sliver whose stroke is pure noise. Smaller than
    /// any real field region (a single glyph is ~0.02 × 0.02 = 4e-4).
    static let minimumDrawableArea: CGFloat = 1e-7

    /// Fraction of each edge covered by the corner bracket. Brackets are drawn
    /// *along the projected edges*, so they keystone and rotate with the quad
    /// instead of reading as axis-aligned tick marks.
    static let bracketFraction: CGFloat = 0.18

    /// Whether a quad can be honestly drawn: finite, non-degenerate, convex.
    ///
    /// Non-convex (self-intersecting, "bowtie") projections are REJECTED rather
    /// than stroked. Drawing one would show the user a shape that no display
    /// can have while the state chip still says LOCKED — exactly the kind of
    /// false confidence this overlay exists to prevent.
    static func isDrawable(_ quad: ScreenQuad) -> Bool {
        guard quad.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        guard quad.area > minimumDrawableArea else { return false }
        return quad.isConvex
    }

    /// The four projected vertices in view points, in the quad's SEMANTIC
    /// winding order (topLeft → topRight → bottomRight → bottomLeft).
    ///
    /// Corner identity is carried straight through from `ScreenQuad`'s semantic
    /// labels; this deliberately does NOT re-derive labels from position (as
    /// `ScreenQuad.normalizedCornerOrder()` does for raw detector output). A
    /// nearest-to-frame-origin rule relabels the moment the display rolls past
    /// ~45°, which would make the corner markers swap places mid-rotation.
    ///
    /// Nil when the quad is not drawable — callers render nothing.
    static func viewCorners(of quad: ScreenQuad, mapper: AspectFillMapper) -> [CGPoint]? {
        guard isDrawable(quad) else { return nil }
        let points = quad.corners.map { mapper.viewPoint(fromNormalized: $0) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        return points
    }

    /// Closed straight-edge path through `corners`. Edges are lines between
    /// projected vertices, which is what makes the outline keystone under yaw
    /// and pitch and rotate under roll rather than staying axis-aligned.
    static func closedPath(_ corners: [CGPoint]) -> Path {
        var path = Path()
        guard let first = corners.first else { return path }
        path.move(to: first)
        for p in corners.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        return path
    }

    /// Two short segments per corner, running along that corner's two adjacent
    /// edges. Returned as flat point pairs so the shape and the tests share one
    /// definition.
    static func bracketSegments(_ corners: [CGPoint], fraction: CGFloat = bracketFraction) -> [(CGPoint, CGPoint)] {
        guard corners.count == 4 else { return [] }
        let f = min(max(fraction, 0), 0.5)
        var segments: [(CGPoint, CGPoint)] = []
        for i in 0..<4 {
            let corner = corners[i]
            let next = corners[(i + 1) % 4]
            let previous = corners[(i + 3) % 4]
            segments.append((corner, lerp(corner, next, f)))
            segments.append((corner, lerp(corner, previous, f)))
        }
        return segments
    }

    /// Axis-aligned bounds of the projected vertices, in view points.
    ///
    /// Used ONLY for chrome placement and hit testing — never for the outline
    /// itself. Under rotation this box is visibly larger than the quad, which
    /// is the whole defect this file fixes.
    static func boundingRect(_ corners: [CGPoint]) -> CGRect {
        guard let first = corners.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in corners.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A canonical-space field rect projected into frame space through the
    /// target's live homography — a QUAD, not a rect.
    ///
    /// `ScreenField.frameRegion(in:)` returns the projected quad's bounding box
    /// because Vision's `regionOfInterest` and the crop path are axis-aligned.
    /// That is correct for OCR and wrong for drawing: under roll or keystone the
    /// box does not wrap the field. Rendering uses this instead.
    static func projectedFieldQuad(_ region: NormalizedROI, in target: TrackedTarget) -> ScreenQuad? {
        guard let h = target.canonicalToFrame,
              let projected = h.apply(ScreenQuad(roi: region)),
              isDrawable(projected) else { return nil }
        return projected
    }

    /// True when every edge lies within `toleranceDegrees` of horizontal or
    /// vertical, i.e. the quad is (near enough) an axis-aligned rectangle.
    ///
    /// Exists for the tests: an overlay that had regressed to drawing bounding
    /// boxes would report `true` for a rolled or keystoned target.
    static func isAxisAligned(_ quad: ScreenQuad, toleranceDegrees: CGFloat = 0.5) -> Bool {
        edgeAnglesDegrees(quad).allSatisfy { angle in
            let folded = abs(angle.truncatingRemainder(dividingBy: 90))
            return min(folded, 90 - folded) <= toleranceDegrees
        }
    }

    /// Direction of each edge in degrees, TL→TR, TR→BR, BR→BL, BL→TL.
    static func edgeAnglesDegrees(_ quad: ScreenQuad) -> [CGFloat] {
        let p = quad.corners
        return (0..<4).map { i in
            let a = p[i], b = p[(i + 1) % 4]
            return atan2(b.y - a.y, b.x - a.x) * 180 / .pi
        }
    }

    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
}

/// Stroke of an arbitrary projected quadrilateral, drawn in the CONTAINER's
/// coordinate space: `path(in:)` ignores the proposed rect and uses the
/// absolute view points it was handed, so the shape is not confined to (or
/// stretched by) an axis-aligned frame.
struct ProjectedQuadShape: Shape {
    var corners: [CGPoint]

    func path(in rect: CGRect) -> Path {
        OverlayQuadGeometry.closedPath(corners)
    }
}

/// Corner brackets, drawn along the projected edges (see
/// `OverlayQuadGeometry.bracketSegments`).
struct ProjectedCornerBracketsShape: Shape {
    var corners: [CGPoint]
    var fraction: CGFloat = OverlayQuadGeometry.bracketFraction

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in OverlayQuadGeometry.bracketSegments(corners, fraction: fraction) {
            path.move(to: segment.0)
            path.addLine(to: segment.1)
        }
        return path
    }
}

/// How much visual authority the lock outline is allowed to claim.
///
/// The overlay is the user's only evidence that the lock is real, and the
/// tracker can drift off-target while still reporting a usable confidence. A
/// degraded or reacquiring lock therefore must NOT render like a healthy one —
/// weight, dash, opacity and marker fill all change together, so the difference
/// survives a glance, a screenshot, and colour-blind vision.
enum LockRenderStyle: Equatable, Sendable {
    /// Tracking healthy — solid, heavy, glowing, filled corner markers.
    case healthy
    /// `.trackingDegraded` — geometry is coasting. Thinner, dashed, dimmed.
    case degraded
    /// `.reacquisition` — the lock is lost and being hunted. Searching palette,
    /// finely dashed, dimmest.
    case reacquiring
    /// A quad exists but nothing is locked (candidate preview / manual).
    case provisional

    static func forSnapState(_ state: SnapState) -> LockRenderStyle {
        switch state {
        case .locked: .healthy
        case .trackingDegraded: .degraded
        case .reacquisition: .reacquiring
        default: .provisional
        }
    }

    var color: Color {
        switch self {
        case .healthy, .degraded: Theme.brandYellow
        case .reacquiring: Theme.roiSearching
        case .provisional: .white
        }
    }

    var lineWidth: CGFloat {
        switch self {
        case .healthy: 2.5
        case .degraded: 1.5
        case .reacquiring: 1.5
        case .provisional: 1
        }
    }

    var dash: [CGFloat] {
        switch self {
        case .healthy: []
        case .degraded: [7, 4]
        case .reacquiring: [2, 5]
        case .provisional: [3, 3]
        }
    }

    var opacity: Double {
        switch self {
        case .healthy: 1
        case .degraded: 0.75
        case .reacquiring: 0.55
        case .provisional: 0.45
        }
    }

    /// Filled markers read as "these vertices are known"; hollow ones as
    /// "this is where they were last seen".
    var markerIsFilled: Bool { self == .healthy }

    var markerDiameter: CGFloat {
        switch self {
        case .healthy: 7
        case .degraded, .reacquiring: 6
        case .provisional: 4
        }
    }

    /// Only a healthy lock earns a glow.
    var showsGlow: Bool { self == .healthy }

    /// Human-readable name for this quality.
    ///
    /// NOT spoken by this overlay — the outline is decorative and
    /// `accessibilityHidden`; `ScreenLockStatusStrip` is what VoiceOver reads,
    /// and duplicating it here would announce every lock twice. This exists so
    /// the three qualities are nameable and so `OverlayGeometryTests` can pin
    /// that they stay distinguishable by something other than colour.
    var qualityDescription: String {
        switch self {
        case .healthy: "Locked, tracking healthy"
        case .degraded: "Locked, tracking degraded"
        case .reacquiring: "Lock lost, reacquiring"
        case .provisional: "Candidate outline"
        }
    }
}

/// Draws the live acquisition geometry over the viewport: the tracked screen
/// quad, its corners, and the current snap state. Distinct from
/// `ROISelectionOverlay`, which draws the user's *selection*; this draws what
/// the system currently believes about the target.
///
/// The outline is SCREEN-relative: vertices coincide with the four tracked
/// corners and edges are straight lines between them, so it keystones under
/// yaw/pitch, rotates under roll and scales with distance. It updates at
/// TRACKING cadence — `ScreenLockPipeline` rewrites `target.quad` on every
/// frame while locked, and the value arrives here as a plain parameter.
///
/// PERF: this view performs no observable reads at all. `lockedTarget`,
/// `screenCandidates` and `snapState` are read by `ScreenGeometryLayer`, the
/// smallest leaf that can hold them (ARCHITECTURE.md §2).
struct TargetGeometryOverlay: View {
    let quad: ScreenQuad?
    let candidates: [ScreenCandidate]
    let snapState: SnapState
    let mapper: AspectFillMapper

    private var style: LockRenderStyle { LockRenderStyle.forSnapState(snapState) }

    var body: some View {
        ZStack {
            // Candidates first, so the committed target draws on top of them.
            ForEach(candidates) { candidate in
                CandidateOutline(candidate: candidate, mapper: mapper)
            }
            // Degenerate/non-convex geometry yields nil and draws nothing.
            if let quad, let corners = OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper) {
                lockOutline(corners: corners, style: style)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func lockOutline(corners: [CGPoint], style: LockRenderStyle) -> some View {
        ProjectedQuadShape(corners: corners)
            .stroke(style.color,
                    style: StrokeStyle(lineWidth: style.lineWidth, lineJoin: .round, dash: style.dash))
            .opacity(style.opacity)
            .shadow(color: style.showsGlow ? style.color.opacity(0.45) : .clear,
                    radius: style.showsGlow ? 7 : 0)

        ProjectedCornerBracketsShape(corners: corners)
            .stroke(style.color,
                    style: StrokeStyle(lineWidth: style.lineWidth + 1.5, lineCap: .round, lineJoin: .round))
            .opacity(style.opacity)

        // Index-keyed, so marker n always belongs to semantic corner n. The
        // top-left marker is deliberately larger: if corner identity ever did
        // swap mid-rotation, the big marker would visibly jump to another
        // vertex instead of the swap being invisible.
        ForEach(Array(corners.enumerated()), id: \.offset) { index, point in
            cornerMarker(isPrimary: index == 0, style: style)
                .position(x: point.x, y: point.y)
        }
    }

    @ViewBuilder
    private func cornerMarker(isPrimary: Bool, style: LockRenderStyle) -> some View {
        let diameter = style.markerDiameter * (isPrimary ? 1.6 : 1)
        if style.markerIsFilled {
            Circle()
                .fill(style.color)
                .frame(width: diameter, height: diameter)
        } else {
            Circle()
                .strokeBorder(style.color, lineWidth: 1.5)
                .frame(width: diameter, height: diameter)
                .opacity(style.opacity)
        }
    }
}

/// One detector proposal: the same projected-quad treatment, in the searching
/// palette, with its fused confidence tagged near the top-left vertex.
private struct CandidateOutline: View {
    let candidate: ScreenCandidate
    let mapper: AspectFillMapper

    var body: some View {
        if let corners = OverlayQuadGeometry.viewCorners(of: candidate.quad, mapper: mapper) {
            ZStack {
                ProjectedQuadShape(corners: corners)
                    .stroke(Theme.roiSearching.opacity(0.5),
                            style: StrokeStyle(lineWidth: 1, lineJoin: .round, dash: [3, 3]))
                Text(String(format: "%.0f%%", candidate.confidence * 100))
                    .font(Theme.mono(8, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .background(RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.6)))
                    .fixedSize()
                    // Anchored to the projected top-left VERTEX, so the tag
                    // travels with the corner through rotation.
                    .position(x: corners[0].x + 16, y: corners[0].y - 7)
            }
        }
    }
}
