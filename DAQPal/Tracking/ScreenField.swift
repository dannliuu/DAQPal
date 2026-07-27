//
//  ScreenField.swift
//  DAQPal
//
//  Multi-field screen understanding (spec §11–§13): a locked display is not one
//  OCR region but a set of independently recognized numeric fields, each with
//  its own label, unit, format and confidence.
//
//  The defining property: a field's region is stored in CANONICAL screen space
//  (0...1 over the perspective-corrected display), never in frame space. Frame
//  coordinates are derived on demand from the target's live homography, so
//  fields stay glued to the same physical part of the display through
//  translation, rotation, scale and perspective change — with no per-field
//  tracking of their own.
//

import CoreGraphics
import CoreVideo
import Foundation

/// What kind of content a detected region holds. Only `.numeric` fields are
/// capturable; labels and units are detected so they can be *attached* to the
/// numeric field beside them, which is what turns a bare number into
/// "VOLTAGE = 12.345 V".
enum FieldContentKind: String, Codable, Equatable, Hashable, Sendable {
    case numeric
    case label
    case unit
    case unknown
}

/// One recognized region on a locked display.
///
/// Fields are proposed by analysis, then curated by the user (select, adjust,
/// rename, set format) before capture — the spec's explicit workflow. Nothing
/// is recorded until `isSelected` is set, so an automatic analysis pass can be
/// generous without polluting the dataset.
struct ScreenField: Identifiable, Codable, Equatable, Hashable, Sendable {
    /// Mutable so a re-analysis pass can *inherit* the previous pass's identity
    /// for the same physical region (see `ScreenFieldCatalog.merge`) — keeping
    /// SwiftUI row identity and user selection stable instead of recreating
    /// every overlay each time the display is re-analyzed.
    var id: UUID
    /// Region in CANONICAL screen space (see type doc). Axis-aligned because
    /// the canonical view is already perspective-corrected.
    var region: NormalizedROI
    var kind: FieldContentKind
    /// Human label, from a detected adjacent text run or user-entered.
    var label: String
    /// Recognition/format configuration — reuses the app's existing model, so
    /// per-field OCR runs through the same validated path as a whole device.
    var format: DisplayFormat
    /// True once the user has chosen to capture this field.
    var isSelected: Bool
    /// Detector confidence that this region is what `kind` says it is.
    var detectionConfidence: Float
    /// True when the region was drawn or adjusted by the user — protects it
    /// from being overwritten by a subsequent re-analysis pass.
    var isUserAdjusted: Bool

    init(id: UUID = UUID(),
         region: NormalizedROI,
         kind: FieldContentKind = .numeric,
         label: String = "",
         format: DisplayFormat = .unconstrained,
         isSelected: Bool = false,
         detectionConfidence: Float = 0,
         isUserAdjusted: Bool = false) {
        self.id = id
        self.region = region
        self.kind = kind
        self.label = label
        self.format = format
        self.isSelected = isSelected
        self.detectionConfidence = detectionConfidence
        self.isUserAdjusted = isUserAdjusted
    }

    /// Display name, falling back to a positional name when unlabeled.
    func displayName(index: Int) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "FIELD \(index + 1)" : trimmed.uppercased()
    }

    /// This field's region projected into frame space via the target's live
    /// geometry, as the axis-aligned box that Vision/crop consume. Nil when the
    /// target has no solvable homography this frame.
    ///
    /// The bounding box of the projected quad is deliberately used rather than
    /// the quad itself: Vision's `regionOfInterest` and the app's crop path are
    /// both axis-aligned. Under strong perspective this box is looser than the
    /// true field outline, which is precisely why OCR should prefer the
    /// perspective-corrected canonical image when one is available.
    func frameRegion(in target: TrackedTarget) -> NormalizedROI? {
        guard let h = target.canonicalToFrame,
              let projected = h.apply(ScreenQuad(roi: region)) else { return nil }
        return Self.unitSquareClamped(projected.boundingBox)
    }

    /// Clamps to the unit square WITHOUT `NormalizedROI.clamped()`'s
    /// minimum-size inflation.
    ///
    /// That minimum (`minimumWidth` 0.05 / `minimumHeight` 0.03) exists so a
    /// user cannot drag a device's ROI window down to an untappable sliver — it
    /// is an *editor* constraint. A field region is a recognized text box, not a
    /// draggable window: a single-glyph reading is legitimately ~0.02 wide, and
    /// inflating it silently widens the crop handed to OCR and corrupts the
    /// geometry that label/unit association is computed from.
    static func unitSquareClamped(_ roi: NormalizedROI) -> NormalizedROI {
        let x = min(max(roi.x, 0), 1)
        let y = min(max(roi.y, 0), 1)
        return NormalizedROI(x: x,
                             y: y,
                             width: min(max(roi.width, 0), 1 - x),
                             height: min(max(roi.height, 0), 1 - y))
    }
}

/// The curated set of fields for one locked target, plus what analysis found.
struct ScreenFieldCatalog: Codable, Equatable, Sendable {
    /// Target these fields were authored against.
    var targetID: UUID
    var fields: [ScreenField]
    /// Frame timestamp of the analysis pass that produced them.
    var analyzedAt: TimeInterval

    init(targetID: UUID, fields: [ScreenField] = [], analyzedAt: TimeInterval = 0) {
        self.targetID = targetID
        self.fields = fields
        self.analyzedAt = analyzedAt
    }

    var selectedFields: [ScreenField] { fields.filter(\.isSelected) }
    var numericFields: [ScreenField] { fields.filter { $0.kind == .numeric } }

    /// Merges a fresh analysis pass into the catalog, preserving user intent:
    /// user-adjusted fields are kept verbatim, selection state carries over to
    /// re-detected fields by region overlap, and genuinely new fields are
    /// appended unselected. Re-analyzing must never silently discard a field
    /// the user configured.
    mutating func merge(_ detected: [ScreenField], at timestamp: TimeInterval) {
        analyzedAt = timestamp
        let preserved = fields.filter(\.isUserAdjusted)
        var merged = preserved
        for var candidate in detected {
            // Match against the previous pass by region overlap so selection,
            // label and format survive re-analysis.
            if let previous = fields.first(where: {
                !$0.isUserAdjusted &&
                ScreenQuad(roi: $0.region).boundingBoxIoU(with: ScreenQuad(roi: candidate.region)) > 0.5
            }) {
                candidate.id = previous.id
                candidate.isSelected = previous.isSelected
                if !previous.label.isEmpty { candidate.label = previous.label }
                candidate.format = previous.format
            }
            // Skip anything already covered by a user-adjusted field.
            let overlapsUserField = preserved.contains {
                ScreenQuad(roi: $0.region).boundingBoxIoU(with: ScreenQuad(roi: candidate.region)) > 0.5
            }
            if !overlapsUserField { merged.append(candidate) }
        }
        fields = Self.readingOrdered(merged)
    }

    /// Reading order: rows top-to-bottom, left-to-right within a row.
    ///
    /// Deliberately NOT a single `sorted(by:)` with a y-tolerance predicate.
    /// That predicate ("same row if |Δy| ≤ tol, then compare x") is not a strict
    /// weak ordering — it is non-transitive, since A and B can be same-row and
    /// B and C same-row while A and C are not. `sorted(by:)` requires a strict
    /// weak ordering and gives an arbitrary (not merely approximate) permutation
    /// otherwise, which for a field list means the capture columns silently
    /// reshuffle. Bucketing into rows first makes the comparison transitive
    /// within each stage.
    static func readingOrdered(_ input: [ScreenField], rowTolerance: CGFloat = 0.02) -> [ScreenField] {
        // Total order by y first, so row grouping is deterministic.
        let byY = input.enumerated().sorted { a, b in
            a.element.region.y != b.element.region.y
                ? a.element.region.y < b.element.region.y
                : a.offset < b.offset
        }
        var rows: [[(offset: Int, element: ScreenField)]] = []
        for item in byY {
            // A field joins the current row when it is within tolerance of that
            // row's FIRST member — a fixed anchor, so a run of slightly-drifting
            // fields cannot chain into one arbitrarily tall row.
            if let anchor = rows.last?.first, item.element.region.y - anchor.element.region.y <= rowTolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.flatMap { row in
            row.sorted { a, b in
                a.element.region.x != b.element.region.x
                    ? a.element.region.x < b.element.region.x
                    : a.offset < b.offset
            }.map(\.element)
        }
    }
}

/// Analyzes a perspective-corrected display image into candidate fields.
/// A seam, like `OCREngine`: the first implementation groups Vision text
/// observations, but a layout model could replace it without touching the UI
/// or capture path.
protocol ScreenAnalyzing: Sendable {
    /// `canonicalImage` is the warped, axis-aligned display; returned regions
    /// are in that image's normalized space. Never throws — analysis failure is
    /// an empty result.
    func analyze(canonicalImage: CVPixelBuffer) async -> [ScreenField]
}
