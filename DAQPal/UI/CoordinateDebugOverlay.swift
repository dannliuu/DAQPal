//
//  CoordinateDebugOverlay.swift
//  DAQPal
//
//  Developer HUD for the COORDINATE CHAIN, built for validating the app against
//  a physical instrument (HARDWARE_VALIDATION.md). `PipelineDebugOverlay`
//  answers "how fast is each stage"; this answers "where does the app think
//  everything is", which is the question that matters when a digit box on the
//  screen does not sit on the digit in front of the lens.
//
//  The chain it makes visible, in the order a touch travels it:
//
//      buffer pixels  →  normalized (0...1, top-left)  →  container points
//         1080×1920         NormalizedROI space            AspectFillMapper
//
//  and, once a display is locked, the branch that hangs off the middle stage:
//
//      canonical unit square  --canonicalToFrame-->  normalized frame  →  view
//
//  DEBUG ONLY. The whole file is compiled out of Release, so nothing here can
//  ship, and no shipping code may reference it.
//
//  PERF. `lockedTarget` and `liveReadings` are rewritten on every processed
//  frame, so any body that reads them is invalidated at frame rate — the
//  drag-lag regression in ARCHITECTURE.md §2. Every such read here is pushed
//  into the smallest leaf that needs it (`TrackedQuadRows`, `HomographyRows`,
//  `ProjectedFieldRow`, `ConfidenceRows`), exactly as `ROISelectionOverlay` and
//  `FieldSelectionOverlay` do. `CoordinateDebugOverlay.body` and
//  `CoordinateReadoutPanel.body` read no per-frame state at all, and the frame
//  counter is PULLED from `PipelineMetrics` on a `TimelineView` tick rather than
//  pushed, so mounting this overlay cannot add a frame-rate invalidation to any
//  view that did not already have one.
//
//  HIT TESTING. The overlay is `allowsHitTesting(false)` in its entirety. The
//  touch readout does not work by taking touches — it observes them through a
//  gesture recognizer installed on the WINDOW that never leaves `.possible`
//  state and never cancels or delays delivery, so ROI windows keep every touch
//  they would otherwise get. A debug overlay that stole taps would break the
//  very interaction it exists to measure.
//

#if DEBUG

import CoreGraphics
import SwiftUI
import UIKit

// MARK: - Pure coordinate math

/// Every conversion this overlay displays, as free functions of value types.
///
/// Kept out of the view bodies so the coordinate chain can be asserted on
/// without rendering SwiftUI or owning a camera — a HUD that claims a touch
/// lands at (0.42, 0.67) is only evidence if that arithmetic is itself tested
/// (`CoordinateDebugOverlayTests`).
///
/// The view↔normalized step is delegated to `AspectFillMapper` rather than
/// re-derived: the preview layer's `resizeAspectFill` gravity is modelled in
/// exactly one place, and a debug overlay carrying a second copy could agree
/// with itself while disagreeing with what the user sees.
enum CoordinateProbe {

    /// One touch, expressed at every stage of the chain at once.
    struct TouchSample: Equatable, Sendable {
        /// Where the finger landed, in container (view) points.
        var viewPoint: CGPoint
        /// Same touch in normalized oriented-image space (0...1, top-left).
        /// NOT clamped — a touch outside the frame must read as outside.
        var normalized: CGPoint
        /// Same touch in oriented buffer pixels, which is what the crop path
        /// and Vision's `regionOfInterest` ultimately index.
        var bufferPoint: CGPoint
        /// False when the touch fell outside the viewport itself.
        var isInsideContainer: Bool
        /// False when the touch maps outside the captured frame. Distinct from
        /// `isInsideContainer` because aspect-fill crops: see
        /// `visibleFrameRegion`.
        var isInsideFrame: Bool
    }

    static func sample(viewPoint: CGPoint, mapper: AspectFillMapper) -> TouchSample {
        let normalized = mapper.normalizedPoint(fromViewPoint: viewPoint)
        return TouchSample(
            viewPoint: viewPoint,
            normalized: normalized,
            bufferPoint: CGPoint(x: normalized.x * mapper.contentSize.width,
                                 y: normalized.y * mapper.contentSize.height),
            isInsideContainer: isInsideContainer(viewPoint, containerSize: mapper.containerSize),
            isInsideFrame: isInsideFrame(normalized))
    }

    static func isInsideFrame(_ normalized: CGPoint) -> Bool {
        (0...1).contains(normalized.x) && (0...1).contains(normalized.y)
    }

    static func isInsideContainer(_ point: CGPoint, containerSize: CGSize) -> Bool {
        (0...containerSize.width).contains(point.x) && (0...containerSize.height).contains(point.y)
    }

    /// The part of the captured frame the viewport actually shows.
    ///
    /// Aspect-fill scales the frame to COVER the container, so on one axis the
    /// frame overflows and the overflow is cropped away symmetrically. The
    /// result is a sub-rect of the unit square on that axis and the full 0...1
    /// on the other. Deliberately un-clamped by `NormalizedROI.clamped()`,
    /// which would impose minimum sizes and hide a degenerate container.
    ///
    /// This is what makes "the tester can see it, so the pipeline can read it"
    /// checkable: a display near the left or right edge of the preview can be
    /// fully visible and still be outside nothing, but a display the tester
    /// cannot see is definitively outside the region the pipeline searches.
    static func visibleFrameRegion(in mapper: AspectFillMapper) -> NormalizedROI {
        let topLeft = mapper.normalizedPoint(fromViewPoint: .zero)
        let bottomRight = mapper.normalizedPoint(
            fromViewPoint: CGPoint(x: mapper.containerSize.width, y: mapper.containerSize.height))
        return NormalizedROI(x: topLeft.x,
                             y: topLeft.y,
                             width: bottomRight.x - topLeft.x,
                             height: bottomRight.y - topLeft.y)
    }

    // MARK: Round trips
    //
    // Both directions are exposed because they fail differently: a broken
    // forward map puts the boxes in the wrong place (visible), a broken inverse
    // puts the user's taps in the wrong place (invisible until a reading is
    // wrong). The hardware procedure exercises both.

    /// Distance, in view points, between a point and itself after
    /// view → normalized → view.
    static func roundTripError(viewPoint: CGPoint, mapper: AspectFillMapper) -> CGFloat {
        let back = mapper.viewPoint(fromNormalized: mapper.normalizedPoint(fromViewPoint: viewPoint))
        return hypot(back.x - viewPoint.x, back.y - viewPoint.y)
    }

    /// Distance, in normalized units, after normalized → view → normalized.
    static func roundTripError(normalized: CGPoint, mapper: AspectFillMapper) -> CGFloat {
        let back = mapper.normalizedPoint(fromViewPoint: mapper.viewPoint(fromNormalized: normalized))
        return hypot(back.x - normalized.x, back.y - normalized.y)
    }

    // MARK: Regions

    /// The digit cells the recognizer would carve out of `device`'s window, in
    /// container points.
    ///
    /// These come from `DigitSegmenter`, which is a FIXED-PITCH stub: equal
    /// width cells spanning the ROI. That is the point of drawing them against
    /// a physical instrument — where the cells and the real glyphs disagree,
    /// the disagreement measures the stub's pitch assumption, not a coordinate
    /// bug. Empty for an unconstrained format, which declares no digit count.
    static func digitCellRects(for device: Device, mapper: AspectFillMapper) -> [CGRect] {
        guard let roi = device.roi else { return [] }
        return DigitSegmenter()
            .digitCells(in: roi, format: device.displayFormat)
            .map { mapper.viewRect(fromNormalized: $0) }
    }

    /// Centre-to-centre gaps between consecutive digit cells, in view points.
    ///
    /// The "digit spacing consistency" metric in HARDWARE_VALIDATION.md is the
    /// spread of these: a fixed-pitch model produces identical gaps, so any
    /// spread the tester sees against a real display is the model's error.
    static func digitCellPitches(_ rects: [CGRect]) -> [CGFloat] {
        guard rects.count >= 2 else { return [] }
        return zip(rects.dropFirst(), rects).map { $0.midX - $1.midX }
    }

    /// A tracked quad's four corners in container points, in semantic winding
    /// order. Nil when the quad cannot honestly be drawn.
    static func viewCorners(of quad: ScreenQuad, mapper: AspectFillMapper) -> [CGPoint]? {
        OverlayQuadGeometry.viewCorners(of: quad, mapper: mapper)
    }

    /// Container points back to normalized frame coordinates — the inverse of
    /// `viewCorners`, used to check the chain closes on itself.
    static func normalizedCorners(fromViewCorners corners: [CGPoint],
                                  mapper: AspectFillMapper) -> [CGPoint] {
        corners.map { mapper.normalizedPoint(fromViewPoint: $0) }
    }

    // MARK: Formatting
    //
    // Fixed-width, fixed-precision, and pure: the tester transcribes these
    // strings into the validation table, so they have to be stable enough to
    // compare across two runs by eye.

    static func format(_ point: CGPoint, decimals: Int = 4) -> String {
        String(format: "(%.\(decimals)f, %.\(decimals)f)", point.x, point.y)
    }

    static func format(_ size: CGSize, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f x %.\(decimals)f", size.width, size.height)
    }

    static func format(_ roi: NormalizedROI, decimals: Int = 4) -> String {
        String(format: "x %.\(decimals)f  y %.\(decimals)f  w %.\(decimals)f  h %.\(decimals)f",
               roi.x, roi.y, roi.width, roi.height)
    }

    /// Three rows, one per matrix row, row-major — the layout `Homography.m`
    /// stores and the one the DLT derivation in `ScreenQuad.swift` uses.
    static func matrixRows(_ h: Homography) -> [String] {
        (0..<3).map { row in
            (0..<3).map { column in String(format: "%+9.4f", h.m[row * 3 + column]) }
                .joined(separator: " ")
        }
    }
}

// MARK: - Passive touch capture

/// The last touch the app received, in container points.
///
/// Only the raw view point is stored; the normalized and buffer forms are
/// derived at render time through `CoordinateProbe.sample`, so the store cannot
/// hold a conversion that has drifted from the live mapper.
///
/// Writes happen on touch DOWN and touch UP only, never on `touchesMoved`. A
/// per-move write is an observable mutation at up to 120 Hz *while the finger
/// is on an ROI window*, which is precisely the contention ARCHITECTURE.md §2
/// documents; the overlay is meant to diagnose that class of defect, not add to
/// it. The cost is that a drag reports its endpoints rather than its path,
/// which is what the alignment checks need anyway.
@MainActor
@Observable
final class CoordinateTouchLog {
    static let shared = CoordinateTouchLog()

    enum Phase: String, Sendable {
        case began = "DOWN"
        case ended = "UP"
    }

    private(set) var lastViewPoint: CGPoint?
    private(set) var lastPhase: Phase?
    /// Monotonic count of recorded touches — lets the tester tell "the same tap
    /// still showing" from "a new tap that landed in the same place".
    private(set) var touchCount: Int = 0

    private init() {}

    func record(viewPoint: CGPoint, phase: Phase) {
        lastViewPoint = viewPoint
        lastPhase = phase
        if phase == .began { touchCount += 1 }
    }

    func reset() {
        lastViewPoint = nil
        lastPhase = nil
        touchCount = 0
    }
}

/// A recognizer that watches touches and never claims one.
///
/// It never advances past `.possible`, so it cannot recognize; with
/// `cancelsTouchesInView` and `delaysTouchesEnded` both off it also cannot
/// cancel or postpone delivery to the views underneath. That combination is
/// what lets the overlay report the ROI windows' own touches without competing
/// with `PanGestureCatcher` for them.
private final class PassiveTouchObserver: UIGestureRecognizer {
    var onTouch: (@MainActor (CGPoint, CoordinateTouchLog.Phase) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        report(touches, .began)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        report(touches, .ended)
    }

    private func report(_ touches: Set<UITouch>, _ phase: CoordinateTouchLog.Phase) {
        guard let touch = touches.first else { return }
        // `location(in: nil)` is window space; the probe view converts into its
        // own space, which is the viewport container's space.
        onTouch?(touch.location(in: nil), phase)
    }
}

/// Hosts the observer and provides the coordinate space it converts into.
///
/// The recognizer goes on the WINDOW, not on this view: a recognizer only sees
/// touches that hit-test into its own view, and this view is deliberately
/// non-interactive so it can never take one. The view's only jobs are to be
/// laid out exactly over the viewport (so `convert(_:from: nil)` yields
/// container points) and to own the recognizer's lifetime.
private final class TouchProbeView: UIView {
    var onTouch: (@MainActor (CGPoint, CoordinateTouchLog.Phase) -> Void)?
    private var observer: PassiveTouchObserver?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Detaching on the way out matters as much as attaching: the overlay is
        // toggled at runtime, and a leaked observer would keep reporting from a
        // view that is no longer on screen.
        if let observer {
            observer.view?.removeGestureRecognizer(observer)
            self.observer = nil
        }
        guard let window else { return }
        let recognizer = PassiveTouchObserver()
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.onTouch = { [weak self] windowPoint, phase in
            guard let self else { return }
            self.onTouch?(self.convert(windowPoint, from: nil), phase)
        }
        window.addGestureRecognizer(recognizer)
        observer = recognizer
    }
}

private struct CoordinateTouchProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = TouchProbeView(frame: .zero)
        view.onTouch = { point, phase in
            CoordinateTouchLog.shared.record(viewPoint: point, phase: phase)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Overlay

/// Full coordinate-chain HUD, for use with a physical instrument.
///
/// Mount it over the camera viewport *inside* `#if DEBUG`, above the ROI
/// overlay — it takes no touches, so stacking order affects nothing but what
/// the readout draws on top of.
struct CoordinateDebugOverlay: View {
    @Environment(AppState.self) private var appState

    /// Matches `ROISelectionOverlay`/`FieldSelectionOverlay` so all three agree
    /// on the aspect ratio before the first frame publishes `videoDimensions`.
    /// A different fallback here would make the HUD contradict the overlay it
    /// is supposed to explain.
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        GeometryReader { geo in
            let mapper = AspectFillMapper(contentSize: appState.videoDimensions ?? Self.fallbackContentSize,
                                          containerSize: geo.size)
            ZStack(alignment: .topLeading) {
                // Every layer below draws in ABSOLUTE container coordinates, so
                // each is pinned to the container's exact size and origin. A
                // layer left to size itself would place its own origin at its
                // content's bounding box and offset everything it draws — and
                // the probe in particular converts window points through its own
                // frame, so a mis-sized probe would report the wrong touch
                // position rather than merely drawing in the wrong place.
                CoordinateTouchProbe()
                    .frame(width: geo.size.width, height: geo.size.height)
                DigitCellLayer(mapper: mapper)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                TouchMarkerLayer()
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                CoordinateReadoutPanel(mapper: mapper)
                    .padding(6)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        // Non-negotiable: the ROI windows' pan recognizer and the field chips'
        // tap gestures must keep every touch.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Drawn layers

/// The recognizer's digit cells, drawn where it believes they are.
///
/// Reads `devices`, which changes on commit and on ROI auto-tracking, never at
/// frame rate.
private struct DigitCellLayer: View {
    @Environment(AppState.self) private var appState
    let mapper: AspectFillMapper

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(appState.devices) { device in
                let rects = CoordinateProbe.digitCellRects(for: device, mapper: mapper)
                ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                    Rectangle()
                        .strokeBorder(Theme.brandYellow.opacity(0.75), lineWidth: 0.5)
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

/// Crosshair at the last touch. Its own leaf so a tap re-renders 22 pt of
/// crosshair and nothing else.
private struct TouchMarkerLayer: View {
    var body: some View {
        if let point = CoordinateTouchLog.shared.lastViewPoint {
            TouchCrosshairShape(center: point)
                .stroke(Theme.roiSearching, lineWidth: 1)
        }
    }
}

/// Crosshair drawn in the CONTAINER's coordinate space: `path(in:)` ignores the
/// proposed rect and uses the absolute view point it was handed, the same
/// contract `ProjectedQuadShape` uses. A `Path` view would instead be laid out
/// at its own bounding box and offset the mark by the touch position.
private struct TouchCrosshairShape: Shape {
    var center: CGPoint
    var armLength: CGFloat = 11

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x - armLength, y: center.y))
        path.addLine(to: CGPoint(x: center.x + armLength, y: center.y))
        path.move(to: CGPoint(x: center.x, y: center.y - armLength))
        path.addLine(to: CGPoint(x: center.x, y: center.y + armLength))
        return path
    }
}

// MARK: Readout

/// The text panel. Reads nothing observable itself — every live value is read
/// by one of the leaves below.
private struct CoordinateReadoutPanel: View {
    let mapper: AspectFillMapper

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Group {
                CoordinateSectionHeader("FRAME")
                FrameGeometryRows(mapper: mapper)
            }
            Group {
                CoordinateSectionHeader("TOUCH")
                TouchRows(mapper: mapper)
            }
            Group {
                CoordinateSectionHeader("TARGET")
                TrackedQuadRows(mapper: mapper)
            }
            Group {
                CoordinateSectionHeader("H canonical->frame")
                HomographyRows()
            }
            Group {
                CoordinateSectionHeader("REGIONS")
                RegionRows(mapper: mapper)
            }
            Group {
                CoordinateSectionHeader("CONFIDENCE")
                ConfidenceRows()
            }
        }
        .font(Theme.mono(8))
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.72)))
        .fixedSize()
    }
}

private struct CoordinateSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(Theme.ui(7, weight: .heavy))
            .tracking(0.8)
            .foregroundStyle(Theme.brandYellow)
            .padding(.top, 2)
    }
}

private struct CoordinateRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            // `minWidth`, not `width`: the label column lines up for the fixed
            // row names and still grows for a user-named field, which would
            // otherwise truncate to something ambiguous.
            Text(label)
                .foregroundStyle(.white.opacity(0.5))
                .frame(minWidth: 52, alignment: .leading)
            Text(value)
        }
        .lineLimit(1)
    }
}

/// Buffer size, container size, the aspect-fill mapping itself, device
/// orientation and the frame counter.
///
/// The frame counter is PULLED from `PipelineMetrics` on a timer, the same
/// contract `PipelineDebugOverlay` uses. Pushing a frame index into observable
/// state to display it here would invalidate a view on every frame — for a
/// number nobody can read at 30 Hz anyway. `processedFPS` is safe to read
/// alongside it: `AppState` republishes it only when its rounded integer
/// changes, so it is not a per-frame write.
private struct FrameGeometryRows: View {
    @Environment(AppState.self) private var appState
    let mapper: AspectFillMapper

    private static let refreshInterval: TimeInterval = 0.25

    @State private var orientation = UIDevice.current.orientation

    var body: some View {
        let visible = CoordinateProbe.visibleFrameRegion(in: mapper)
        CoordinateRow(label: "buffer", value: CoordinateProbe.format(mapper.contentSize, decimals: 0) + " px")
        CoordinateRow(label: "view", value: CoordinateProbe.format(mapper.containerSize) + " pt")
        CoordinateRow(label: "fill", value: String(format: "scale %.5f  origin %@",
                                                   mapper.scale,
                                                   CoordinateProbe.format(mapper.contentOrigin, decimals: 1)))
        CoordinateRow(label: "visible", value: CoordinateProbe.format(visible))
        CoordinateRow(label: "orient", value: Self.label(for: orientation))
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            let snapshot = PipelineMetrics.shared.snapshot()
            CoordinateRow(label: "frame",
                          value: "#\(snapshot.processedFrames)  drop \(snapshot.droppedFrames)"
                                 + String(format: "  %.1f fps", appState.processedFPS))
        }
        .onAppear { UIDevice.current.beginGeneratingDeviceOrientationNotifications() }
        .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            orientation = UIDevice.current.orientation
        }
    }

    /// `faceUp`/`faceDown`/`unknown` are reported verbatim rather than folded
    /// into "portrait": lying the gun flat on a bench is a normal way to
    /// photograph it, and the tester needs to see that the device orientation
    /// went ambiguous rather than have it silently reported as upright.
    private static func label(for orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .portrait: "portrait"
        case .portraitUpsideDown: "portraitUpsideDown"
        case .landscapeLeft: "landscapeLeft"
        case .landscapeRight: "landscapeRight"
        case .faceUp: "faceUp"
        case .faceDown: "faceDown"
        default: "unknown"
        }
    }
}

/// The last touch at every stage of the chain, plus its round-trip error.
///
/// The round trip is shown, not asserted away: it is the on-device evidence
/// that the inverse mapping the tap path uses agrees with the forward mapping
/// the boxes are drawn with. `CoordinateDebugOverlayTests` pins it to zero in
/// pure math; this row is what proves the live mapper is the same one.
private struct TouchRows: View {
    let mapper: AspectFillMapper

    var body: some View {
        let log = CoordinateTouchLog.shared
        if let viewPoint = log.lastViewPoint {
            let sample = CoordinateProbe.sample(viewPoint: viewPoint, mapper: mapper)
            CoordinateRow(label: "view pt",
                          value: CoordinateProbe.format(sample.viewPoint, decimals: 1)
                                 + "  \(log.lastPhase?.rawValue ?? "—") #\(log.touchCount)")
            CoordinateRow(label: "norm", value: CoordinateProbe.format(sample.normalized))
            CoordinateRow(label: "buffer pt", value: CoordinateProbe.format(sample.bufferPoint, decimals: 1))
            CoordinateRow(label: "inside",
                          value: "view \(sample.isInsideContainer ? "Y" : "N")"
                                 + "  frame \(sample.isInsideFrame ? "Y" : "N")")
            CoordinateRow(label: "roundtrip",
                          value: String(format: "%.6f pt",
                                        CoordinateProbe.roundTripError(viewPoint: viewPoint, mapper: mapper)))
        } else {
            CoordinateRow(label: "view pt", value: "— tap the preview —")
        }
    }
}

/// The tracked display quad in both normalized and view coordinates.
///
/// Frame-rate leaf: `lockedTarget.quad` is rewritten on every tracked frame.
private struct TrackedQuadRows: View {
    @Environment(AppState.self) private var appState
    let mapper: AspectFillMapper

    private static let cornerNames = ["TL", "TR", "BR", "BL"]

    var body: some View {
        if let target = appState.lockedTarget {
            let corners = target.quad.corners
            let viewCorners = CoordinateProbe.viewCorners(of: target.quad, mapper: mapper)
            ForEach(Array(corners.enumerated()), id: \.offset) { index, corner in
                CoordinateRow(label: Self.cornerNames[index],
                              value: CoordinateProbe.format(corner)
                                     + "  " + (viewCorners.map { CoordinateProbe.format($0[index], decimals: 1) }
                                               ?? "not drawable"))
            }
            CoordinateRow(label: "scale/roll",
                          value: String(format: "%.3f  %+.1f deg",
                                        target.relativeScale,
                                        target.relativeRoll * 180 / .pi))
        } else {
            CoordinateRow(label: "quad", value: "no lock")
        }
    }
}

/// The live canonical→frame homography, or an explicit reason there is none.
///
/// Frame-rate leaf: the matrix is re-solved from `lockedTarget.quad`.
private struct HomographyRows: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let target = appState.lockedTarget {
            if let h = target.canonicalToFrame {
                let rows = CoordinateProbe.matrixRows(h)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    CoordinateRow(label: index == 0 ? "H" : "", value: row)
                }
            } else {
                // A singular solve means the quad is degenerate or non-convex,
                // which is a different failure from "nothing is locked" and has
                // to read differently.
                CoordinateRow(label: "H", value: "singular (degenerate quad)")
            }
        } else {
            CoordinateRow(label: "H", value: "no lock")
        }
    }
}

/// Manual ROI windows, their digit cells, their sub-field candidates, and the
/// analysed field catalog — the four kinds of region the app can point at.
///
/// Reads `devices`, `windowCandidates` and `fieldCatalog`, none of which change
/// at frame rate. The one frame-rate value a field needs — its projection
/// through the live homography — is read by `ProjectedFieldRow`.
private struct RegionRows: View {
    @Environment(AppState.self) private var appState
    let mapper: AspectFillMapper

    var body: some View {
        ForEach(appState.devices) { device in
            if let roi = device.roi {
                CoordinateRow(label: device.name, value: CoordinateProbe.format(roi))
                let rects = CoordinateProbe.digitCellRects(for: device, mapper: mapper)
                if !rects.isEmpty {
                    CoordinateRow(label: "  digits",
                                  value: "\(rects.count) cells  pitch "
                                         + Self.pitchSummary(CoordinateProbe.digitCellPitches(rects)))
                }
                ForEach(Array(appState.subFieldCandidates(for: device.id).enumerated()), id: \.element.id) { index, candidate in
                    CoordinateRow(label: "  sub\(index)",
                                  value: CoordinateProbe.format(candidate.region))
                }
            } else {
                CoordinateRow(label: device.name, value: "unplaced")
            }
        }
        if let catalog = appState.fieldCatalog {
            ForEach(Array(catalog.fields.enumerated()), id: \.element.id) { index, field in
                ProjectedFieldRow(field: field,
                                  index: index,
                                  targetID: catalog.targetID,
                                  mapper: mapper)
            }
        }
    }

    /// Mean and spread rather than every gap: on a 4-digit display the spread
    /// is the number that says whether the fixed-pitch model fits, and the
    /// individual gaps are four numbers that say the same thing worse.
    private static func pitchSummary(_ pitches: [CGFloat]) -> String {
        guard let smallest = pitches.min(), let largest = pitches.max() else { return "—" }
        let mean = pitches.reduce(0, +) / CGFloat(pitches.count)
        return String(format: "%.1f pt  spread %.2f", mean, largest - smallest)
    }
}

/// One catalog field's canonical region and its bounding box in view points.
///
/// The only view in `RegionRows` that reads `lockedTarget`, for the same reason
/// `FieldRegionView` is the only one in `FieldSelectionOverlay`.
private struct ProjectedFieldRow: View {
    @Environment(AppState.self) private var appState
    let field: ScreenField
    let index: Int
    let targetID: UUID
    let mapper: AspectFillMapper

    var body: some View {
        let name = field.displayName(index: index)
        if let target = appState.lockedTarget,
           target.id == targetID,
           let quad = OverlayQuadGeometry.projectedFieldQuad(field.region, in: target),
           let corners = CoordinateProbe.viewCorners(of: quad, mapper: mapper) {
            let bounds = OverlayQuadGeometry.boundingRect(corners)
            CoordinateRow(label: name,
                          value: CoordinateProbe.format(field.region)
                                 + String(format: "  box %.0f,%.0f %.0fx%.0f",
                                          bounds.minX, bounds.minY, bounds.width, bounds.height))
        } else {
            CoordinateRow(label: name, value: CoordinateProbe.format(field.region) + "  unprojected")
        }
    }
}

/// Tracking and OCR confidence side by side.
///
/// They answer different questions and are routinely confused: tracking
/// confidence says the geometry is still on the display, OCR confidence says
/// the glyphs were read. A high tracker and a low reader is a focus or glare
/// problem; the reverse means the boxes have slid off the numbers.
///
/// Frame-rate leaf: reads both `lockedTarget` and `liveReadings`.
private struct ConfidenceRows: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let target = appState.lockedTarget {
            CoordinateRow(label: "track",
                          value: String(format: "%.3f  det %.3f  %@",
                                        target.trackingConfidence,
                                        target.detectionConfidence,
                                        Self.label(for: target.health)))
        } else {
            CoordinateRow(label: "track", value: "no lock")
        }
        ForEach(appState.devices) { device in
            let reading = appState.liveReadings[device.id] ?? .empty
            CoordinateRow(label: device.name,
                          value: String(format: "ocr %.3f  %@  %@",
                                        reading.confidence,
                                        reading.locked ? "LOCKED" : "SEARCHING",
                                        reading.value.map { String(format: "%g", $0) } ?? "—"))
        }
    }

    private static func label(for health: TrackingHealth) -> String {
        switch health {
        case .healthy: "healthy"
        case .degraded: "degraded"
        case .lost: "lost"
        }
    }
}

#endif
