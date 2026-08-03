//
//  ROISelectionOverlay.swift
//  DAQPal
//
//  Per-device ROI window drawn over the camera viewport (design handoff
//  "Capture" screen). Unplaced devices show a centered "DRAG TO PLACE" ghost
//  window; placed devices support whole-window drag and 4-corner resize.
//
//  Coordinate conversion goes entirely through `AspectFillMapper` — per
//  project rule, normalized ROI space == buffer space == oriented preview
//  space, so the only view-space conversion needed is aspect-fill.
//
//  Drag latency: gestures used to call `appState.updateDevice` on every
//  `.onChanged` tick, which mutates the observed `devices` array and forces a
//  full view-tree diff (plus a processor-config push) per pixel of finger
//  movement — on device this reads as laggy dragging. Gestures now drive a
//  view-local `@State` rect while active and commit to `AppState` once, in
//  `.onEnded`.
//
//  Drag JITTER (Gate 2A) is a separate defect with a separate fix. This
//  overlay used to read `appState.liveReadings` in its own body and hand each
//  reading down to `ROIWindowView` as an init parameter. `liveReadings` is
//  rewritten at capture rate, so the overlay's body — and with it every
//  `ROIWindowView` and the `DragGesture` its body attaches — was rebuilt on
//  every processed frame, including while the user's finger was down.
//  The lock-dependent visuals therefore now live in LEAF views
//  (`ROIWindowBorder`, `ROIWindowHandle`, `ROIWindowLabel`) which read
//  `liveReadings` themselves. Neither this overlay's body nor `ROIWindowView`'s
//  reads any per-frame state, so a new reading re-renders only the small
//  leaves and never reconstructs a gesture mid-drag.
//

import SwiftUI

struct ROISelectionOverlay: View {
    @Environment(AppState.self) private var appState

    /// Matches the Simulator's synthetic frame size so the overlay has a
    /// sane aspect ratio even before the first frame publishes real
    /// `videoDimensions`.
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    private var fieldBacked: Set<UUID> { appState.fieldBackedDeviceIDs }

    var body: some View {
        GeometryReader { geo in
            let mapper = AspectFillMapper(contentSize: appState.videoDimensions ?? Self.fallbackContentSize,
                                          containerSize: geo.size)
            ZStack {
                // Field-backed devices are excluded: their geometry is a
                // per-frame projection of the tracked target, not a stored ROI,
                // so this overlay would draw each one as a centered "DRAG TO
                // PLACE" ghost. Those ghosts stack on top of each other AND sit
                // above `FieldSelectionOverlay`, swallowing the taps meant to
                // select a field. `FieldSelectionOverlay` draws these devices.
                //
                // Note what is NOT read here: `appState.liveReadings`. See the
                // file header — reading it would rebuild every window's gesture
                // at capture rate.
                // Sub-field devices are excluded for the same reason as
                // field-backed ones: something else already draws them. A
                // sub-field IS a box inside its parent's window
                // (`WindowSubFieldLayer`), so giving it a second window of its
                // own stacks a draggable frame on top of the parent — and that
                // window's pan catcher then swallows every tap meant for the
                // chips underneath it, which is how selecting a sub-field made
                // it impossible to deselect. It would also let the user drag a
                // sub-field independently of the parent it is defined relative
                // to, which the next recomposition would silently undo.
                ForEach(appState.devices.filter {
                    !fieldBacked.contains($0.id) && !$0.isSubField
                }) { device in
                    ROIWindowView(device: device, mapper: mapper)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Which corner a resize gesture is dragging. File-level (not nested in the
/// private view) so `ROIWindowGeometry` and its tests can name it.
enum ROIResizeHandle: CaseIterable, Hashable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Pure geometry for the ROI window gestures, extracted from the gesture
/// closures so the drag/resize math is testable without a UI harness.
///
/// Both entry points are total functions of `(anchor, translation)`: the
/// anchor is frozen at gesture start and every `onChanged` tick reapplies the
/// gesture's *cumulative* translation to it. That is what makes a drag
/// monotonic — the result never depends on the previous tick's output, so a
/// dropped or duplicated callback cannot accumulate error, and `onEnded`
/// recomputing from the same anchor and the same translation reproduces the
/// last rendered rect exactly.
enum ROIWindowGeometry {

    /// Whole-window move, clamped so the window stays inside the container.
    static func movedRect(anchor: CGRect, translation: CGSize, containerSize: CGSize) -> CGRect {
        var moved = anchor.offsetBy(dx: translation.width, dy: translation.height)
        moved.origin.x = min(max(moved.origin.x, 0), max(0, containerSize.width - moved.width))
        moved.origin.y = min(max(moved.origin.y, 0), max(0, containerSize.height - moved.height))
        return moved
    }

    /// Corner resize, clamped to the container and to `minimumSize` per axis.
    static func resizedRect(handle h: ROIResizeHandle,
                            anchor: CGRect,
                            translation: CGSize,
                            containerSize: CGSize,
                            minimumSize: CGFloat) -> CGRect {
        var left = anchor.minX, right = anchor.maxX
        var top = anchor.minY, bottom = anchor.maxY
        switch h {
        case .topLeft:
            left += translation.width
            top += translation.height
        case .topRight:
            right += translation.width
            top += translation.height
        case .bottomLeft:
            left += translation.width
            bottom += translation.height
        case .bottomRight:
            right += translation.width
            bottom += translation.height
        }
        left = max(0, left)
        top = max(0, top)
        right = min(containerSize.width, right)
        bottom = min(containerSize.height, bottom)
        if right - left < minimumSize {
            switch h {
            case .topLeft, .bottomLeft: left = right - minimumSize
            default: right = left + minimumSize
            }
        }
        if bottom - top < minimumSize {
            switch h {
            case .topLeft, .topRight: top = bottom - minimumSize
            default: bottom = top + minimumSize
            }
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// One device's draggable/resizable ROI window, or its "not yet placed"
/// ghost. Reads `AppState` directly (rather than via a binding/callback)
/// since it needs `appState.updateDevice` for both drag and resize commits.
///
/// This view's body must stay free of per-frame observable reads: it is the
/// view that attaches the drag and resize gestures, and re-evaluating it
/// rebuilds them. It reads `device` (changes only on commit or auto-tracking),
/// `mapper` (changes on rotation/first frame) and its own gesture `@State`.
private struct ROIWindowView: View {
    @Environment(AppState.self) private var appState
    let device: Device
    let mapper: AspectFillMapper

    /// Rect captured once at gesture start; each `onChanged` reapplies the
    /// gesture's cumulative translation to this anchor instead of the
    /// (possibly already-mutated) current rect, so live updates don't drift.
    @State private var windowDragAnchor: CGRect?
    @State private var resizeAnchor: CGRect?
    /// View-local rect while a move or resize gesture is active; `currentRect`
    /// renders from this instead of `device.roi` so the window tracks the
    /// finger with no round-trip through `AppState`. Only one gesture can be
    /// active on a given window at a time, so move and resize share it. Nil
    /// whenever neither gesture is active, at which point rendering falls
    /// back to `device.roi` — which is what makes ROI auto-tracking visible
    /// between gestures.
    @State private var liveDragRect: CGRect?

    private static let handleVisualSize: CGFloat = 8
    /// ≥44pt hit area around each visually-8pt corner handle (project rule).
    private static let handleHitSize: CGFloat = 44
    private static let minimumViewSize: CGFloat = 32

    private var isPlaced: Bool { device.roi != nil }
    private var containerSize: CGSize { mapper.containerSize }

    /// A centered starting window, sized like `NormalizedROI.defaultROI`,
    /// shown for devices that have not been placed yet.
    private var ghostNormalizedROI: NormalizedROI {
        let w = NormalizedROI.defaultROI.width
        let h = NormalizedROI.defaultROI.height
        return NormalizedROI(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private var currentRect: CGRect {
        if let liveDragRect { return liveDragRect }
        return mapper.viewRect(fromNormalized: device.roi ?? ghostNormalizedROI)
    }

    var body: some View {
        let rect = currentRect
        window(in: rect)
            .position(x: rect.midX, y: rect.midY)
            // Ghost windows read as visually lighter than an active,
            // placed-but-searching ROI (same searching palette otherwise).
            .opacity(isPlaced ? 1 : 0.6)
            // A window restored from a previous session is already placed and
            // will never be committed again, so without this its sub-fields
            // would never be offered at all — the feature would appear only to
            // users who happened to re-drag their window.
            .onAppear {
                if isPlaced { appState.requestWindowAnalysis(for: device.id) }
            }
    }

    @ViewBuilder
    private func window(in rect: CGRect) -> some View {
        ZStack {
            // The gesture is attached HERE, by this body, to a leaf that reads
            // the lock state on its own. When a reading changes, only
            // `ROIWindowBorder` re-evaluates — this body does not, so the
            // `DragGesture` below survives the frame untouched.
            ROIWindowBorder(deviceID: device.id,
                            isPlaced: isPlaced,
                            isGesturing: liveDragRect != nil)
                .accessibilityHidden(true)
                // UIKit recognizer instead of SwiftUI's `DragGesture`. Measured
                // on device: touch and render cadence are both flawless (16.7ms,
                // zero dropped frames) while the drag still feels sluggish, so
                // the defect is LATENCY, which neither cadence probe can see.
                // See `PanGestureCatcher` for the reasoning.
                .overlay(PanGestureCatcher(onChanged: { translation in
                    beginDragIfNeeded()
                    #if DEBUG
                    GestureLatencyProbe.shared.tick()
                    #endif
                    guard let anchor = windowDragAnchor else { return }
                    liveDragRect = ROIWindowGeometry.movedRect(anchor: anchor,
                                                               translation: translation,
                                                               containerSize: containerSize)
                }, onEnded: { translation in
                    if let anchor = windowDragAnchor {
                        commit(ROIWindowGeometry.movedRect(anchor: anchor,
                                                            translation: translation,
                                                            containerSize: containerSize))
                    }
                    endDrag()
                }))

            if isPlaced {
                ForEach(ROIResizeHandle.allCases, id: \.self) { h in
                    handle(h)
                        .position(handleCorner(h, in: rect.size))
                }
                // Above the pan catcher so its chips are tappable, but the
                // outlines are inert — see `WindowSubFieldLayer` for why the
                // boxes themselves must not take the touch. Hidden mid-drag:
                // the candidates describe where the window WAS, so drawing
                // them against a moving window shows them sliding off the
                // numbers they found.
                if liveDragRect == nil {
                    WindowSubFieldLayer(deviceID: device.id, windowSize: rect.size)
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                }
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .overlay(alignment: .topLeading) {
            // The label is the window's accessibility element: it is the only
            // part whose text depends on the live reading, and it is already a
            // leaf, so the dynamic LOCKED/SEARCHING wording stays correct
            // without this body ever reading `liveReadings`.
            ROIWindowLabel(deviceID: device.id,
                           deviceName: device.name,
                           isPlaced: isPlaced)
                .offset(x: -2, y: -24)
        }
    }

    private func handle(_ h: ROIResizeHandle) -> some View {
        ROIWindowHandle(deviceID: device.id,
                        isPlaced: isPlaced,
                        hitSize: Self.handleHitSize,
                        visualSize: Self.handleVisualSize)
            .contentShape(Rectangle())
            .gesture(resizeGesture(for: h))
            .accessibilityHidden(true)
    }

    private func handleCorner(_ h: ROIResizeHandle, in size: CGSize) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: size.width, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: size.height)
        case .bottomRight: CGPoint(x: size.width, y: size.height)
        }
    }

    // MARK: Gestures

    /// First movement of a drag: freeze the anchor and pause every automatic
    /// writer. Split out so the UIKit recognizer and the (retained) SwiftUI
    /// resize gesture share identical bookkeeping.
    private func beginDragIfNeeded() {
        guard windowDragAnchor == nil else { return }
        windowDragAnchor = currentRect
        appState.isEditingROI = true
        #if DEBUG
        GestureLatencyProbe.shared.begin()
        RenderCadenceProbe.shared.begin()
        #endif
    }

    private func endDrag() {
        windowDragAnchor = nil
        liveDragRect = nil
        appState.isEditingROI = false
        #if DEBUG
        GestureLatencyProbe.shared.end()
        RenderCadenceProbe.shared.end()
        appState.gestureLatencySummary =
            GestureLatencyProbe.shared.summary.debugLine
            + " || " + RenderCadenceProbe.shared.summary.debugLine
        #endif
    }

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // First tick of this gesture: freeze the anchor and pause
                // auto-tracking so it can't fight the finger. `isEditingROI`
                // is set only here (not every tick) — repeated writes would
                // reintroduce the same per-tick `AppState` mutation this fix
                // removes.
                if windowDragAnchor == nil {
                    appState.isEditingROI = true
                    #if DEBUG
                    GestureLatencyProbe.shared.begin()
                    RenderCadenceProbe.shared.begin()
                    #endif
                }
                #if DEBUG
                // Measures what the user actually perceives: the spacing of
                // callbacks while the finger moves. Three prior diagnoses of
                // the drag defect were argued from code and all survived the
                // symptom; this records the distribution instead.
                GestureLatencyProbe.shared.tick()
                #endif
                let anchor = windowDragAnchor ?? currentRect
                windowDragAnchor = anchor
                liveDragRect = clampedMove(from: anchor, translation: value.translation)
            }
            .onEnded { value in
                // Recomputed from the SAME frozen anchor with the same pure
                // function, so the committed rect is identical to the last one
                // rendered whenever the final translation matches.
                if let anchor = windowDragAnchor {
                    commit(clampedMove(from: anchor, translation: value.translation))
                }
                windowDragAnchor = nil
                liveDragRect = nil
                // Cleared unconditionally. Leaving it inside the `if` above
                // meant a gesture that ended without a usable anchor left
                // auto-tracking paused for the rest of the session.
                appState.isEditingROI = false
                #if DEBUG
                GestureLatencyProbe.shared.end()
                RenderCadenceProbe.shared.end()
                // Touch cadence AND render cadence. The first rules out event
                // starvation; only the second speaks to judder.
                appState.gestureLatencySummary =
                    GestureLatencyProbe.shared.summary.debugLine
                    + " || " + RenderCadenceProbe.shared.summary.debugLine
                #endif
            }
    }

    private func clampedMove(from anchor: CGRect, translation: CGSize) -> CGRect {
        ROIWindowGeometry.movedRect(anchor: anchor,
                                    translation: translation,
                                    containerSize: containerSize)
    }

    private func resizeGesture(for h: ROIResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if resizeAnchor == nil { appState.isEditingROI = true }
                let anchor = resizeAnchor ?? currentRect
                resizeAnchor = anchor
                liveDragRect = resizedRect(handle: h, anchor: anchor, translation: value.translation)
            }
            .onEnded { value in
                if let anchor = resizeAnchor {
                    commit(resizedRect(handle: h, anchor: anchor, translation: value.translation))
                }
                resizeAnchor = nil
                liveDragRect = nil
                appState.isEditingROI = false
            }
    }

    private func resizedRect(handle h: ROIResizeHandle, anchor: CGRect, translation: CGSize) -> CGRect {
        ROIWindowGeometry.resizedRect(handle: h,
                                      anchor: anchor,
                                      translation: translation,
                                      containerSize: containerSize,
                                      minimumSize: Self.minimumViewSize)
    }

    /// Converts a view-space rect back to normalized ROI space and writes it
    /// through `appState.updateDevice` — called once, from `.onEnded`.
    private func commit(_ viewRect: CGRect) {
        let normalized = mapper.normalizedRect(fromViewRect: viewRect).clamped()
        var updated = device
        updated.roi = normalized
        appState.updateDevice(updated)
        // The window now frames different content, so whatever sub-field
        // candidates it had no longer describe it. Re-analysis is queued for
        // the next frame; existing selections survive it (see
        // `AppState.applyWindowAnalyses`).
        appState.requestWindowAnalysis(for: device.id)
    }
}

// MARK: - Lock-state leaves
//
// Each of these reads `appState.liveReadings` itself. That read is what makes
// them re-evaluate at capture rate — which is fine, because none of them hosts
// a gesture. Keeping the read out of `ROIWindowView` is the whole point.

/// Shared lock lookup so the three leaves cannot drift apart on what "locked"
/// means. An unplaced device is never locked: it has no ROI to read from.
@MainActor
private func isDeviceLocked(_ appState: AppState, _ deviceID: UUID, isPlaced: Bool) -> Bool {
    guard isPlaced else { return false }
    return appState.liveReadings[deviceID]?.locked == true
}

private func roiBorderColor(locked: Bool) -> Color {
    locked ? Theme.brandYellow : Theme.roiSearching
}

/// The window outline. Also the drag gesture's hit target — `ROIWindowView`
/// applies `.contentShape`/`.gesture` to it from the outside.
private struct ROIWindowBorder: View {
    @Environment(AppState.self) private var appState
    let deviceID: UUID
    let isPlaced: Bool
    /// Passed down rather than read: it is `ROIWindowView`'s gesture `@State`.
    let isGesturing: Bool

    var body: some View {
        let locked = isDeviceLocked(appState, deviceID, isPlaced: isPlaced)
        // The locked-glow shadow is suppressed while a gesture is active: a
        // `.shadow` is a blur pass re-rendered on every `onChanged` tick
        // (60–120 Hz), and dropping it during the drag is imperceptible but
        // keeps the gesture's render cost to a plain stroke.
        let showsGlow = locked && !isGesturing
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(roiBorderColor(locked: locked),
                          style: locked ? StrokeStyle(lineWidth: 2)
                                        : StrokeStyle(lineWidth: 2, dash: [5, 4]))
            .shadow(color: showsGlow ? Theme.brandYellow.opacity(0.45) : .clear,
                    radius: showsGlow ? 8 : 0)
    }
}

/// One corner handle's visuals plus its ≥44pt hit area. `ROIWindowView`
/// attaches the resize gesture from the outside.
private struct ROIWindowHandle: View {
    @Environment(AppState.self) private var appState
    let deviceID: UUID
    let isPlaced: Bool
    let hitSize: CGFloat
    let visualSize: CGFloat

    var body: some View {
        let locked = isDeviceLocked(appState, deviceID, isPlaced: isPlaced)
        ZStack {
            Color.clear.frame(width: hitSize, height: hitSize)
            RoundedRectangle(cornerRadius: 2)
                .fill(roiBorderColor(locked: locked))
                .frame(width: visualSize, height: visualSize)
        }
    }
}

/// The "⠿ DMM-1 · 98.2%" / "· SEARCHING" chip, and the window's accessibility
/// element — it is the only piece whose content depends on the live reading.
private struct ROIWindowLabel: View {
    @Environment(AppState.self) private var appState
    let deviceID: UUID
    let deviceName: String
    let isPlaced: Bool

    private var isLocked: Bool { isDeviceLocked(appState, deviceID, isPlaced: isPlaced) }
    private var confidence: Float { appState.liveReadings[deviceID]?.confidence ?? 0 }

    private var labelText: String {
        guard isPlaced else { return "DRAG TO PLACE" }
        if isLocked {
            return "⠿ \(deviceName) · \(String(format: "%.1f", confidence * 100))%"
        }
        return "⠿ \(deviceName) · SEARCHING"
    }

    private var accessibilityText: String {
        guard isPlaced else {
            return "\(deviceName) region of interest, not placed. Drag to place over the display."
        }
        if isLocked {
            return "\(deviceName) region of interest, locked, \(String(format: "%.1f", confidence * 100)) percent confidence"
        }
        return "\(deviceName) region of interest, searching"
    }

    var body: some View {
        let locked = isLocked
        Text(labelText)
            .font(Theme.ui(10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(locked ? Theme.ink : .white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(roiBorderColor(locked: locked)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
    }
}
