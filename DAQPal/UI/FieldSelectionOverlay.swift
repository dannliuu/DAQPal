//
//  FieldSelectionOverlay.swift
//  DAQPal
//
//  The curation step of the intelligent path (spec §11–§13): once a display is
//  locked, analysis proposes fields and the user taps the ones worth recording.
//  This overlay is that tap surface.
//
//  Coordinates travel canonical → frame → view:
//    * `ScreenField.region` is in CANONICAL display space,
//    * `field.frameRegion(in:)` projects it through the target's live
//      homography into normalized frame space (0...1, TOP-LEFT origin),
//    * `AspectFillMapper` converts that to view points, exactly as
//      `ROISelectionOverlay` does.
//  Nothing here touches Vision's bottom-left space; the conversion happens at
//  the Vision boundary, not in the UI.
//
//  PERF: `lockedTarget` is rewritten on every processed frame while a display
//  is locked, so any view that reads it is invalidated at frame rate. The read
//  is therefore pushed into `FieldRegionView` — the smallest leaf — following
//  the same isolation `DebugCaptionView`/`AlignmentHintView` use on the capture
//  screen. Putting it in a parent body would re-render everything that body
//  contains 12–30×/s, which is the drag-lag regression ARCHITECTURE.md §2
//  documents.
//

import SwiftUI

/// Draws every field in the current catalog over the viewport and lets the user
/// select the numeric ones for capture. Renders nothing at all when there is no
/// catalog or no locked target.
struct FieldSelectionOverlay: View {
    @Environment(AppState.self) private var appState

    /// Matches `ROISelectionOverlay`'s fallback so both overlays agree on the
    /// aspect ratio before the first frame publishes `videoDimensions`.
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        GeometryReader { geo in
            let mapper = AspectFillMapper(contentSize: appState.videoDimensions ?? Self.fallbackContentSize,
                                          containerSize: geo.size)
            FieldCatalogLayer(mapper: mapper)
                .frame(width: geo.size.width, height: geo.size.height)
        }
    }
}

/// Reads the catalog — which changes only when analysis completes or the user
/// toggles a selection, never at frame rate — and fans out to one leaf per
/// field. The target is deliberately NOT read here.
private struct FieldCatalogLayer: View {
    @Environment(AppState.self) private var appState
    let mapper: AspectFillMapper

    var body: some View {
        if let catalog = appState.fieldCatalog {
            ZStack {
                ForEach(Array(catalog.fields.enumerated()), id: \.element.id) { index, field in
                    FieldRegionView(field: field,
                                    index: index,
                                    targetID: catalog.targetID,
                                    mapper: mapper)
                }
            }
        }
    }
}

/// One field's outline, label chip and (for numeric fields) tap target.
///
/// This is the only view in the overlay that reads `lockedTarget`.
private struct FieldRegionView: View {
    @Environment(AppState.self) private var appState
    let field: ScreenField
    let index: Int
    /// Target the catalog was authored against; a field is not drawn against a
    /// different target, whose homography would put it somewhere meaningless.
    let targetID: UUID
    let mapper: AspectFillMapper

    /// Minimum tap target (project rule). Small fields are expanded outward to
    /// reach it via a negative `contentShape` inset — the established pattern.
    private static let minimumHitSize: CGFloat = 44

    /// Only numeric fields are capturable; labels and units are drawn as
    /// context so the user can see what a number belongs to.
    private var isInteractive: Bool { field.kind == .numeric }

    private var borderColor: Color {
        if !isInteractive { return .white.opacity(0.3) }
        return field.isSelected ? Theme.brandYellow : Theme.roiSearching
    }

    private var strokeStyle: StrokeStyle {
        if !isInteractive { return StrokeStyle(lineWidth: 1, dash: [2, 3]) }
        return field.isSelected ? StrokeStyle(lineWidth: 2)
                                : StrokeStyle(lineWidth: 2, dash: [5, 4])
    }

    private var captionText: String {
        let name = field.displayName(index: index)
        if let unit = field.format.unit?.trimmingCharacters(in: .whitespaces), !unit.isEmpty {
            return "\(name) · \(unit)"
        }
        return name
    }

    var body: some View {
        if let target = appState.lockedTarget,
           target.id == targetID,
           let frameROI = field.frameRegion(in: target) {
            let rect = mapper.viewRect(fromNormalized: frameROI)
            content(in: rect)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder
    private func content(in rect: CGRect) -> some View {
        if isInteractive {
            outline
                .contentShape(Rectangle().inset(by: hitInset(for: rect)))
                .onTapGesture { appState.toggleFieldSelection(field.id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("\(field.displayName(index: index)) numeric field")
                .accessibilityValue(field.isSelected ? "Selected for capture" : "Not selected")
                .accessibilityHint("Tap to \(field.isSelected ? "stop capturing" : "capture") this field")
        } else {
            outline
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var outline: some View {
        RoundedRectangle(cornerRadius: 4)
            .strokeBorder(borderColor, style: strokeStyle)
            .overlay(alignment: .topLeading) {
                caption.offset(x: -2, y: -16)
            }
    }

    @ViewBuilder
    private var caption: some View {
        if isInteractive {
            Text(captionText)
                .font(Theme.ui(9, weight: .heavy))
                .tracking(0.3)
                .foregroundStyle(field.isSelected ? Theme.ink : borderColor)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background {
                    if field.isSelected {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.brandYellow)
                    } else {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.black.opacity(0.55))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(borderColor, lineWidth: 1))
                    }
                }
        } else {
            Text(captionText)
                .font(Theme.ui(8, weight: .semibold))
                .foregroundStyle(borderColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    /// Negative inset that grows the hit shape to at least 44 pt on the
    /// smaller axis; 0 when the field is already large enough.
    private func hitInset(for rect: CGRect) -> CGFloat {
        let smallest = min(rect.width, rect.height)
        guard smallest < Self.minimumHitSize else { return 0 }
        return -(Self.minimumHitSize - smallest) / 2
    }
}
