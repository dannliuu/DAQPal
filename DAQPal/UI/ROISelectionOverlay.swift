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

import SwiftUI

struct ROISelectionOverlay: View {
    @Environment(AppState.self) private var appState

    /// Matches the Simulator's synthetic frame size so the overlay has a
    /// sane aspect ratio even before the first frame publishes real
    /// `videoDimensions`.
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        GeometryReader { geo in
            let mapper = AspectFillMapper(contentSize: appState.videoDimensions ?? Self.fallbackContentSize,
                                          containerSize: geo.size)
            ZStack {
                ForEach(appState.devices) { device in
                    ROIWindowView(device: device,
                                 mapper: mapper,
                                 liveReading: appState.liveReadings[device.id] ?? .empty)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// One device's draggable/resizable ROI window, or its "not yet placed"
/// ghost. Reads `AppState` directly (rather than via a binding/callback)
/// since it needs `appState.updateDevice` for both drag and resize commits.
private struct ROIWindowView: View {
    @Environment(AppState.self) private var appState
    let device: Device
    let mapper: AspectFillMapper
    let liveReading: LiveReading

    private enum Handle: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

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
    private var isLocked: Bool { isPlaced && liveReading.locked }
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

    private var borderColor: Color { isLocked ? Theme.brandYellow : Theme.roiSearching }

    private var strokeStyle: StrokeStyle {
        isLocked ? StrokeStyle(lineWidth: 2)
                 : StrokeStyle(lineWidth: 2, dash: [5, 4])
    }

    private var labelText: String {
        guard isPlaced else { return "DRAG TO PLACE" }
        if isLocked {
            let pct = String(format: "%.1f", liveReading.confidence * 100)
            return "⠿ \(device.name) · \(pct)%"
        }
        return "⠿ \(device.name) · SEARCHING"
    }

    var body: some View {
        let rect = currentRect
        window(in: rect)
            .position(x: rect.midX, y: rect.midY)
            // Ghost windows read as visually lighter than an active,
            // placed-but-searching ROI (same searching palette otherwise).
            .opacity(isPlaced ? 1 : 0.6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        guard isPlaced else {
            return "\(device.name) region of interest, not placed. Drag to place over the display."
        }
        if isLocked {
            let pct = String(format: "%.1f", liveReading.confidence * 100)
            return "\(device.name) region of interest, locked, \(pct) percent confidence"
        }
        return "\(device.name) region of interest, searching"
    }

    @ViewBuilder
    private func window(in rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, style: strokeStyle)
                .shadow(color: isLocked ? Theme.brandYellow.opacity(0.45) : .clear,
                       radius: isLocked ? 8 : 0)
                .contentShape(Rectangle())
                .gesture(windowDragGesture)

            if isPlaced {
                ForEach(Handle.allCases, id: \.self) { h in
                    handle(h)
                        .position(handleCorner(h, in: rect.size))
                }
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .overlay(alignment: .topLeading) {
            label.offset(x: -2, y: -24)
        }
    }

    private var label: some View {
        Text(labelText)
            .font(Theme.ui(10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(isLocked ? Theme.ink : .white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(borderColor))
    }

    private func handle(_ h: Handle) -> some View {
        ZStack {
            Color.clear.frame(width: Self.handleHitSize, height: Self.handleHitSize)
            RoundedRectangle(cornerRadius: 2)
                .fill(borderColor)
                .frame(width: Self.handleVisualSize, height: Self.handleVisualSize)
        }
        .contentShape(Rectangle())
        .gesture(resizeGesture(for: h))
        .accessibilityHidden(true)
    }

    private func handleCorner(_ h: Handle, in size: CGSize) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: size.width, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: size.height)
        case .bottomRight: CGPoint(x: size.width, y: size.height)
        }
    }

    // MARK: Gestures

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                // First tick of this gesture: freeze the anchor and pause
                // auto-tracking so it can't fight the finger. `isEditingROI`
                // is set only here (not every tick) — repeated writes would
                // reintroduce the same per-tick `AppState` mutation this fix
                // removes.
                if windowDragAnchor == nil { appState.isEditingROI = true }
                let anchor = windowDragAnchor ?? currentRect
                windowDragAnchor = anchor
                liveDragRect = clampedMove(from: anchor, translation: value.translation)
            }
            .onEnded { value in
                if let anchor = windowDragAnchor {
                    commit(clampedMove(from: anchor, translation: value.translation))
                    appState.isEditingROI = false
                }
                windowDragAnchor = nil
                liveDragRect = nil
            }
    }

    private func clampedMove(from anchor: CGRect, translation: CGSize) -> CGRect {
        var moved = anchor.offsetBy(dx: translation.width, dy: translation.height)
        moved.origin.x = min(max(moved.origin.x, 0), max(0, containerSize.width - moved.width))
        moved.origin.y = min(max(moved.origin.y, 0), max(0, containerSize.height - moved.height))
        return moved
    }

    private func resizeGesture(for h: Handle) -> some Gesture {
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
                    appState.isEditingROI = false
                }
                resizeAnchor = nil
                liveDragRect = nil
            }
    }

    private func resizedRect(handle h: Handle, anchor: CGRect, translation: CGSize) -> CGRect {
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
        if right - left < Self.minimumViewSize {
            switch h {
            case .topLeft, .bottomLeft: left = right - Self.minimumViewSize
            default: right = left + Self.minimumViewSize
            }
        }
        if bottom - top < Self.minimumViewSize {
            switch h {
            case .topLeft, .topRight: top = bottom - Self.minimumViewSize
            default: bottom = top + Self.minimumViewSize
            }
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// Converts a view-space rect back to normalized ROI space and writes it
    /// through `appState.updateDevice` — called once, from `.onEnded`.
    private func commit(_ viewRect: CGRect) {
        let normalized = mapper.normalizedRect(fromViewRect: viewRect).clamped()
        var updated = device
        updated.roi = normalized
        appState.updateDevice(updated)
    }
}
