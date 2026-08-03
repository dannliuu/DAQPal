//
//  WindowSubField.swift
//  DAQPal
//
//  Sub-field selection for the MANUAL window path.
//
//  The intelligent path already lets a user pick individual numbers off a
//  display: `ScreenFieldCatalog` + `FieldSelectionOverlay` propose fields on a
//  LOCKED target and each selection becomes its own device, hence its own CSV
//  column. That path needs a homography, so it only exists once screen locking
//  has acquired and verified a target.
//
//  Plenty of real instruments never get there. The motivating one is a handheld
//  IR thermometer: its LCD shows a large live reading and a smaller MAX reading
//  in the same window, the user holds it by hand, and the whole display is
//  routinely too small or too transient in frame for lock acquisition. Framing
//  it manually and reading the window as a single region merges both numbers,
//  which is how `90.0` over `92.7` becomes nonsense.
//
//  So: run `NumberBandSplitter` inside the placed window, offer what it finds as
//  tappable sub-boxes, and turn each selection into a device. From `Device`
//  onward NOTHING else changes — recording, CSV export and the results screen
//  already work per device, and a sub-field device is just a device.
//
//  GEOMETRY IS STORED PARENT-RELATIVE, WHICH IS THE WHOLE POINT.
//  Storing the composed absolute ROI would go stale the moment the user nudged
//  the window; storing the fraction means the sub-box rides along on every drag
//  and resize, and the absolute ROI is recomputed from it (`SubFieldOrigin
//  .compose`) whenever the parent moves. That recomputation is driven by user
//  gestures, not by frames, so it is nowhere near the hot path.
//

import CoreGraphics
import Foundation

/// One candidate number the splitter found inside a placed window, offered to
/// the user as a tappable box. Transient UI state: candidates are re-proposed
/// by analysis and are not persisted.
struct WindowCandidate: Identifiable, Equatable, Sendable {
    /// Identity of this box for the UI's purposes: it becomes the device id
    /// when selected, which is what lets `Device.id` keep working as the join
    /// key across recording, CSV and results.
    ///
    /// Mutable because re-analysis mints fresh ids, and a selected candidate
    /// must ADOPT its device's id rather than keep the new one — otherwise the
    /// chip and the device it created drift apart, the box stops reading as
    /// selected, and tapping it again adds a second device instead of removing
    /// the first (`AppState.applyWindowAnalyses`).
    var id: UUID
    /// Region WITHIN the parent window (0...1, top-left origin).
    var region: NormalizedROI
    /// Tallest glyph in the band, parent-relative. The ranking signal: on an
    /// instrument the primary reading is conventionally the largest element.
    var glyphHeight: CGFloat
    /// 0 for the largest glyph run, ascending. Drives the default label
    /// ("VALUE 1", "VALUE 2") and the ordering of the boxes.
    var rank: Int

    /// Suggested label before the user renames it. Rank 0 reads as the primary
    /// because that is what the largest element means on an instrument face.
    var suggestedName: String { rank == 0 ? "MAIN" : "AUX \(rank)" }
}

/// Ties a sub-field device back to the window it was carved from.
struct SubFieldOrigin: Codable, Equatable, Hashable, Sendable {
    /// The device whose window contains this sub-field.
    let parentID: UUID
    /// Region within that window (0...1, top-left origin).
    var region: NormalizedROI

    /// Absolute ROI in normalized frame space, given where the parent window
    /// currently sits.
    ///
    /// Clamped afterwards, which also applies `NormalizedROI`'s minimum size.
    /// That minimum is deliberate here: a sub-field of a small window can
    /// compose to a few dozen pixels, and handing Vision a sliver that thin
    /// produces nothing useful. Growing it slightly is strictly better than
    /// recognising an empty crop — the sub-box exists to EXCLUDE the neighbour,
    /// and a little padding does not reintroduce it.
    func compose(parent: NormalizedROI) -> NormalizedROI {
        NormalizedROI(x: parent.x + region.x * parent.width,
                      y: parent.y + region.y * parent.height,
                      width: region.width * parent.width,
                      height: region.height * parent.height).clamped()
    }
}

/// What one analysis pass over one window produced.
struct WindowAnalysis: Equatable, Sendable {
    let parentID: UUID
    var candidates: [WindowCandidate]

    /// Sub-boxes are only worth showing when there is a genuine choice to make.
    /// A single candidate means the window already frames one number, and
    /// offering one box that duplicates the window would be noise.
    var offersChoice: Bool { candidates.count >= 2 }
}
