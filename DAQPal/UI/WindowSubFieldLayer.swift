//
//  WindowSubFieldLayer.swift
//  DAQPal
//
//  Draws the sub-field candidates found inside a placed window and lets the
//  user pick which ones to capture (`WindowSubField.swift` for the model, and
//  why the manual path needs this at all).
//
//  WHY THE OUTLINE IS NOT THE TAP TARGET.
//  The window is dragged by a `UIPanGestureRecognizer` covering its whole area
//  (`PanGestureCatcher` — the fix for the drag latency the user reported three
//  times). A SwiftUI tap gesture layered on top of that would win the hit test
//  and the pan recognizer would never see the touch, so making the boxes
//  tappable would silently make the middle of the window undraggable. Since the
//  candidates cover most of the window, that trades one reported defect for a
//  worse one.
//
//  So the outline is inert and the tap target is a small labelled CHIP at each
//  box's top-left, sized to the project's 44 pt minimum. Dragging anywhere else
//  in the window keeps working exactly as before.
//
//  PERF: this reads `windowCandidates` and `devices`, which change only on
//  analysis or a tap — never at frame rate. It deliberately does NOT read
//  `liveReadings` or `lockedTarget`, so it does not re-evaluate per frame and
//  cannot reintroduce the ARCHITECTURE.md §2 drag regression.
//

import SwiftUI

/// Candidate boxes for one window, laid out in that window's local coordinate
/// space (origin at the window's top-left, sized to the window's view rect).
struct WindowSubFieldLayer: View {
    @Environment(AppState.self) private var appState
    let deviceID: UUID
    /// The window's size in view points; candidate regions are fractions of it.
    let windowSize: CGSize

    var body: some View {
        let candidates = appState.subFieldCandidates(for: deviceID)
        ZStack(alignment: .topLeading) {
            ForEach(candidates) { candidate in
                let rect = viewRect(for: candidate)
                SubFieldBox(parentID: deviceID,
                            candidate: candidate,
                            selected: appState.isSubFieldSelected(candidate.id),
                            rect: rect)
            }
        }
        .frame(width: max(windowSize.width, 1),
               height: max(windowSize.height, 1),
               alignment: .topLeading)
    }

    private func viewRect(for candidate: WindowCandidate) -> CGRect {
        CGRect(x: candidate.region.x * windowSize.width,
               y: candidate.region.y * windowSize.height,
               width: candidate.region.width * windowSize.width,
               height: candidate.region.height * windowSize.height)
    }
}

/// One candidate: an inert outline plus a tappable chip.
private struct SubFieldBox: View {
    @Environment(AppState.self) private var appState
    let parentID: UUID
    let candidate: WindowCandidate
    let selected: Bool
    let rect: CGRect

    private static let minimumHitSize: CGFloat = 44

    private var tint: Color { selected ? Theme.brandYellow : Theme.roiSearching }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(tint,
                              style: selected
                                  ? StrokeStyle(lineWidth: 2)
                                  : StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)

            chip
                // Sits just outside the box's top-left so it never covers the
                // digits the user is trying to identify.
                .offset(x: rect.minX, y: max(0, rect.minY - 18))
        }
    }

    private var chip: some View {
        Text(candidate.suggestedName)
            .font(Theme.ui(9, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(selected ? Theme.ink : tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.brandYellow)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.black.opacity(0.6))
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tint, lineWidth: 1))
                }
            }
            // Expanded to the 44 pt minimum without changing the drawn size,
            // matching how `FieldSelectionOverlay` reaches the same floor.
            .contentShape(Rectangle().inset(by: -Self.minimumHitSize / 4))
            .onTapGesture {
                appState.toggleSubField(parentID: parentID, candidateID: candidate.id)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(candidate.suggestedName) reading in this window")
            .accessibilityValue(selected ? "Selected for capture" : "Not selected")
            .accessibilityHint("Tap to \(selected ? "stop capturing" : "capture") this reading as its own column")
    }
}
