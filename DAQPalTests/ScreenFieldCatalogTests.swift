//
//  ScreenFieldCatalogTests.swift
//  DAQPalTests
//
//  Covers the frozen field-catalog contract: reading order, user-intent
//  preservation across re-analysis, and the unit-square clamp that keeps a
//  field region from being inflated by the ROI editor's minimum-size rule.
//

import XCTest
@testable import DAQPal

final class ScreenFieldCatalogTests: XCTestCase {

    private func field(_ x: CGFloat, _ y: CGFloat,
                       w: CGFloat = 0.1, h: CGFloat = 0.05,
                       label: String = "",
                       selected: Bool = false,
                       userAdjusted: Bool = false) -> ScreenField {
        ScreenField(region: NormalizedROI(x: x, y: y, width: w, height: h),
                    kind: .numeric,
                    label: label,
                    isSelected: selected,
                    isUserAdjusted: userAdjusted)
    }

    // MARK: Reading order must be a real ordering

    /// The original comparator ("same row if |Δy| ≤ tol, else compare y") is not
    /// transitive: A~B and B~C can hold while A~C does not, so `sorted(by:)`
    /// returned an arbitrary permutation. This is the exact triple that exposed
    /// the cycle (A<B false, B<C false, A<C true).
    ///
    /// Rows are anchored on their first member rather than chained member-to-
    /// member, so the tie is broken deterministically: A and B are within
    /// tolerance of the anchor A and form row 1 (ordered by x → B, A); C is
    /// 0.030 from that anchor, past the 0.02 tolerance, so it starts row 2.
    /// Anchoring is what stops a long run of slightly-drifting fields from
    /// chaining into one arbitrarily tall "row".
    func testReadingOrder_nonTransitiveTriple_isOrderedDeterministically() {
        let a = field(0.90, 0.100, label: "A")
        let b = field(0.50, 0.115, label: "B")
        let c = field(0.10, 0.130, label: "C")

        let ordered = ScreenFieldCatalog.readingOrdered([a, b, c])
        XCTAssertEqual(ordered.map(\.label), ["B", "A", "C"])

        // The property that actually matters: the result does not depend on the
        // input permutation. The broken comparator failed exactly this.
        for permutation in [[a, c, b], [b, a, c], [b, c, a], [c, a, b], [c, b, a]] {
            XCTAssertEqual(ScreenFieldCatalog.readingOrdered(permutation).map(\.label),
                           ["B", "A", "C"],
                           "Reading order must not depend on input order.")
        }
    }

    /// 60 fields with monotonically increasing y and decreasing x previously
    /// came back scrambled (1,0,3,2,5,4,…). With rows anchored on their first
    /// member the result is exact and stable.
    func testReadingOrder_manyDriftingFields_isStableAndComplete() {
        let fields = (0..<60).map { i in
            field(1.0 - CGFloat(i) * 0.015, CGFloat(i) * 0.015, label: "F\(i)")
        }
        let ordered = ScreenFieldCatalog.readingOrdered(fields)

        XCTAssertEqual(ordered.count, 60, "Ordering must never drop or duplicate a field.")
        XCTAssertEqual(Set(ordered.map(\.label)).count, 60)
        // Sorting twice must be idempotent — the defining property the broken
        // comparator lacked.
        XCTAssertEqual(ScreenFieldCatalog.readingOrdered(ordered).map(\.label),
                       ordered.map(\.label),
                       "Reading order must be idempotent.")
    }

    func testReadingOrder_distinctRows_areTopToBottomThenLeftToRight() {
        let ordered = ScreenFieldCatalog.readingOrdered([
            field(0.7, 0.60, label: "R2C2"),
            field(0.1, 0.60, label: "R2C1"),
            field(0.7, 0.10, label: "R1C2"),
            field(0.1, 0.10, label: "R1C1")
        ])
        XCTAssertEqual(ordered.map(\.label), ["R1C1", "R1C2", "R2C1", "R2C2"])
    }

    func testReadingOrder_emptyAndSingle() {
        XCTAssertTrue(ScreenFieldCatalog.readingOrdered([]).isEmpty)
        XCTAssertEqual(ScreenFieldCatalog.readingOrdered([field(0.5, 0.5, label: "only")]).map(\.label), ["only"])
    }

    // MARK: Field regions must not inherit the ROI editor's minimum size

    /// `NormalizedROI.clamped()` inflates to a 0.05 × 0.03 minimum so a user
    /// cannot drag an ROI window to an untappable sliver. A single-glyph reading
    /// is legitimately narrower than that, and inflating it corrupts both the
    /// OCR crop and the geometry label/unit association is computed from.
    func testUnitSquareClamped_doesNotInflateANarrowRegion() {
        let narrow = NormalizedROI(x: 0.40, y: 0.50, width: 0.02, height: 0.01)
        let clamped = ScreenField.unitSquareClamped(narrow)

        XCTAssertEqual(clamped.width, 0.02, accuracy: 1e-9,
                       "A one-glyph field region was inflated to the ROI editor's minimum width.")
        XCTAssertEqual(clamped.height, 0.01, accuracy: 1e-9)
        XCTAssertEqual(clamped.x, 0.40, accuracy: 1e-9)

        // Contrast with the editor clamp, to document why they differ.
        XCTAssertEqual(narrow.clamped().width, NormalizedROI.minimumWidth, accuracy: 1e-9)
    }

    func testUnitSquareClamped_clipsRatherThanShiftsAtTheBoundary() {
        let overhanging = NormalizedROI(x: 0.9, y: 0.1, width: 0.4, height: 0.2)
        let clamped = ScreenField.unitSquareClamped(overhanging)

        XCTAssertEqual(clamped.x, 0.9, accuracy: 1e-9, "Clamping must clip the width, not slide the origin.")
        XCTAssertEqual(clamped.width, 0.1, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(clamped.x + clamped.width, 1.0 + 1e-9)
    }

    func testUnitSquareClamped_negativeOriginIsClippedNotShifted() {
        let clamped = ScreenField.unitSquareClamped(NormalizedROI(x: -0.05, y: -0.02, width: 0.3, height: 0.1))
        XCTAssertEqual(clamped.x, 0, accuracy: 1e-9)
        XCTAssertEqual(clamped.y, 0, accuracy: 1e-9)
    }

    /// The projected frame region of a narrow field must survive the round trip
    /// through the target homography without being inflated.
    func testFrameRegion_narrowField_isNotInflated() {
        let target = TrackedTarget(quad: ScreenQuad(roi: NormalizedROI(x: 0.1, y: 0.1, width: 0.8, height: 0.4)),
                                   detectionConfidence: 0.9)
        let narrow = ScreenField(region: NormalizedROI(x: 0.40, y: 0.40, width: 0.02, height: 0.05))

        guard let projected = narrow.frameRegion(in: target) else {
            return XCTFail("Expected a solvable homography for an axis-aligned target.")
        }
        // 0.02 of a 0.8-wide target ≈ 0.016 in frame space — below the editor
        // minimum, and it must stay there.
        XCTAssertEqual(projected.width, 0.016, accuracy: 1e-6,
                       "The projected field region was inflated by the ROI editor's minimum-size rule.")
    }

    // MARK: Merge preserves user intent

    func testMerge_preservesUserAdjustedFieldsVerbatim() {
        var catalog = ScreenFieldCatalog(targetID: UUID())
        let userField = field(0.2, 0.2, label: "MY VOLTAGE", selected: true, userAdjusted: true)
        catalog.fields = [userField]

        // Re-analysis proposes a field covering the same region.
        catalog.merge([field(0.21, 0.21, label: "AUTO")], at: 1.0)

        XCTAssertTrue(catalog.fields.contains { $0.id == userField.id && $0.label == "MY VOLTAGE" },
                      "A user-adjusted field must survive re-analysis verbatim.")
        XCTAssertFalse(catalog.fields.contains { $0.label == "AUTO" },
                       "A proposal overlapping a user-adjusted field must not be added alongside it.")
    }

    func testMerge_carriesSelectionAndIdentityAcrossReanalysis() {
        var catalog = ScreenFieldCatalog(targetID: UUID())
        var original = field(0.2, 0.2, label: "VOLTAGE")
        original.isSelected = true
        catalog.fields = [original]

        catalog.merge([field(0.205, 0.205)], at: 2.0)

        XCTAssertEqual(catalog.fields.count, 1)
        XCTAssertEqual(catalog.fields[0].id, original.id, "Re-detected fields must inherit identity so UI rows are stable.")
        XCTAssertTrue(catalog.fields[0].isSelected, "Selection is a user act and must survive re-analysis.")
        XCTAssertEqual(catalog.fields[0].label, "VOLTAGE")
        XCTAssertEqual(catalog.analyzedAt, 2.0)
    }

    func testMerge_addsGenuinelyNewFieldsUnselected() {
        var catalog = ScreenFieldCatalog(targetID: UUID())
        catalog.fields = [field(0.1, 0.1, label: "FIRST")]

        catalog.merge([field(0.1, 0.1, label: "FIRST"), field(0.1, 0.8, label: "SECOND")], at: 3.0)

        XCTAssertEqual(catalog.fields.count, 2)
        XCTAssertFalse(catalog.fields.contains { $0.isSelected },
                       "A newly detected field must never arrive pre-selected.")
    }

    func testSelectedAndNumericFilters() {
        var catalog = ScreenFieldCatalog(targetID: UUID())
        var selected = field(0.1, 0.1)
        selected.isSelected = true
        var label = field(0.1, 0.5)
        label.kind = .label
        catalog.fields = [selected, label]

        XCTAssertEqual(catalog.selectedFields.count, 1)
        XCTAssertEqual(catalog.numericFields.count, 1)
    }
}
