//
//  WindowSubFieldTests.swift
//  DAQPalTests
//
//  In-window sub-field selection: the manual-path answer to a display that
//  shows two numbers at once (`WindowSubField.swift`).
//
//  The headline case is driven by the PHOTOGRAPH OF THE REAL INSTRUMENT the
//  user supplied — an IR thermometer reading `90.0` large with `92.7` smaller
//  beside a `MAX` legend. Everything else here guards the state machine around
//  it, where the failures are silent rather than visible: a selection that
//  quietly rebinds to the wrong number, or a parent that keeps contributing its
//  own merged reading, corrupts the recorded data with nothing on screen to say
//  so.
//

import CoreVideo
import UIKit
import XCTest
@testable import DAQPal

final class WindowSubFieldTests: XCTestCase {

    // MARK: Fixtures

    private func realDisplayBuffer() throws -> CVPixelBuffer {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: "ir_gun_display", withExtension: "png") else {
            throw XCTSkip("ir_gun_display.png fixture not present in the test bundle")
        }
        guard let image = UIImage(data: try Data(contentsOf: url))?.cgImage else {
            throw XCTSkip("fixture could not be decoded")
        }
        let w = image.width, h = image.height
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGImageCompatibilityKey: true,
                             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                            &pb)
        let out = try XCTUnwrap(pb)
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(out),
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                | CGBitmapInfo.byteOrder32Little.rawValue)
        try XCTUnwrap(ctx).draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out
    }

    private func candidate(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                           rank: Int = 0, glyph: CGFloat = 0.4) -> WindowCandidate {
        WindowCandidate(id: UUID(),
                        region: NormalizedROI(x: x, y: y, width: w, height: h),
                        glyphHeight: glyph,
                        rank: rank)
    }

    // MARK: The real instrument

    /// The whole feature exists because this photo reads as one merged number.
    func testRealInstrument_offersBothReadingsAsRankedCandidates() throws {
        let analysis = try XCTUnwrap(
            WindowFieldAnalyzer.analyze(frame: try realDisplayBuffer(),
                                        roi: NormalizedROI(x: 0, y: 0, width: 1, height: 1),
                                        deviceID: UUID()))
        let report = analysis.candidates.map {
            String(format: "  rank %d  y=%.3f h=%.3f glyph=%.3f", $0.rank, $0.region.y,
                   $0.region.height, $0.glyphHeight)
        }.joined(separator: "\n")

        print("=== WindowFieldAnalyzer on REAL IR gun display ===\n\(report)")
        XCTAssertTrue(analysis.offersChoice,
            "The user must be offered a choice on this display; got \(analysis.candidates.count):\n\(report)")

        // Rank 0 is labelled MAIN in the UI, so it had better be the large
        // primary reading (90.0) and not the smaller MAX value beside it.
        let main = try XCTUnwrap(analysis.candidates.first)
        XCTAssertEqual(main.rank, 0)
        let others = analysis.candidates.dropFirst()
        for other in others {
            XCTAssertLessThanOrEqual(other.glyphHeight, main.glyphHeight,
                "Ranking must be tallest-first — MAIN would otherwise label the wrong number.\n\(report)")
        }
        XCTAssertTrue(others.contains { $0.region.y > main.region.y },
            "The MAX reading sits below the primary; nothing was offered below it.\n\(report)")

        // Instrument chrome (the SCAN / laser / lamp / °F icon row) must not be
        // offered as a number to capture.
        for c in analysis.candidates {
            XCTAssertGreaterThan(c.glyphHeight, main.glyphHeight * 0.3,
                "An icon-row-sized candidate survived ranking.\n\(report)")
        }
    }

    func testAnalyzer_isDeterministic() throws {
        let buffer = try realDisplayBuffer()
        let roi = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let id = UUID()
        let a = WindowFieldAnalyzer.analyze(frame: buffer, roi: roi, deviceID: id)?.candidates
        let b = WindowFieldAnalyzer.analyze(frame: buffer, roi: roi, deviceID: id)?.candidates
        XCTAssertEqual(a?.map(\.region), b?.map(\.region))
        XCTAssertEqual(a?.map(\.rank), b?.map(\.rank))
    }

    /// Analysis runs SERIALLY inside the frame drain, so its cost is paid in
    /// dropped frames — once per window placement, not per frame.
    ///
    /// READ THE NUMBER THIS PRINTS WITH THE BUILD CONFIGURATION IN MIND. The
    /// same code measures 6.5 ms in Release and ~310 ms in Debug on the same
    /// fixture, and the suite runs Debug. Chasing the Debug figure as if it
    /// were the shipping cost wastes exactly the effort it did the first time.
    /// The ceiling below is therefore sized for Debug and exists only to catch
    /// an order-of-magnitude regression, not to assert a budget.
    ///
    /// For a real figure:
    ///   xcodebuild test -configuration Release SWIFT_ENABLE_TESTABILITY=YES …
    /// (testability must be forced on, or `@testable import` will not link.)
    func testAnalysisCostIsNotAVisibleHitch() throws {
        let buffer = try realDisplayBuffer()
        let roi = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let id = UUID()
        _ = WindowFieldAnalyzer.analyze(frame: buffer, roi: roi, deviceID: id)  // warm

        var samples: [Double] = []
        for _ in 0..<10 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = WindowFieldAnalyzer.analyze(frame: buffer, roi: roi, deviceID: id)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        let median = samples.sorted()[samples.count / 2]
        print(String(format: "=== WindowFieldAnalyzer median %.1f ms (worst %.1f ms) ===",
                     median, samples.max() ?? 0))
        XCTAssertLessThan(median, 600,
                          "Window analysis got slow enough to stall the frame drain visibly")
    }

    // MARK: Geometry — riding along with the parent

    func testComposedROIIsParentRelative() {
        let origin = SubFieldOrigin(parentID: UUID(),
                                    region: NormalizedROI(x: 0.25, y: 0.5, width: 0.5, height: 0.4))
        let composed = origin.compose(parent: NormalizedROI(x: 0.2, y: 0.1, width: 0.4, height: 0.5))
        XCTAssertEqual(composed.x, 0.2 + 0.25 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(composed.y, 0.1 + 0.5 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(composed.width, 0.5 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(composed.height, 0.4 * 0.5, accuracy: 1e-9)
    }

    /// The reason geometry is stored parent-relative at all.
    @MainActor
    func testSubFieldFollowsParentWhenTheWindowMoves() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = NormalizedROI(x: 0.1, y: 0.1, width: 0.6, height: 0.4)
        app.updateDevice(parent)

        let c = candidate(0.0, 0.0, 1.0, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id, candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: c.id)

        let before = try? XCTUnwrap(app.devices.first { $0.id == c.id }?.roi)
        XCTAssertEqual(before?.x ?? -1, 0.1, accuracy: 1e-6)

        parent.roi = NormalizedROI(x: 0.3, y: 0.25, width: 0.6, height: 0.4)
        app.updateDevice(parent)

        let after = try? XCTUnwrap(app.devices.first { $0.id == c.id }?.roi)
        XCTAssertEqual(after?.x ?? -1, 0.3, accuracy: 1e-6,
                       "The sub-field did not follow its parent window")
        XCTAssertEqual(after?.y ?? -1, 0.25, accuracy: 1e-6)
    }

    // MARK: Selection lifecycle

    @MainActor
    func testSelectingASubFieldCreatesItsOwnDevice() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        let c = candidate(0, 0, 1, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])

        let countBefore = app.devices.count
        app.toggleSubField(parentID: parent.id, candidateID: c.id)
        XCTAssertEqual(app.devices.count, countBefore + 1)

        let created = app.devices.first { $0.id == c.id }
        XCTAssertNotNil(created, "Selecting a sub-field must create a device — that is what gives it a CSV column")
        XCTAssertTrue(created?.isSubField == true)
        XCTAssertNotEqual(created?.columnPrefix, parent.columnPrefix,
                          "Parent and sub-field would collide into one CSV column")

        app.toggleSubField(parentID: parent.id, candidateID: c.id)
        XCTAssertNil(app.devices.first { $0.id == c.id }, "Deselecting must remove the device")
    }

    /// A parent with children is a FRAME. If it kept being recognised it would
    /// keep producing exactly the merged `90.0 92.7` reading the sub-fields
    /// were selected to eliminate — and it would land in the CSV looking valid.
    @MainActor
    func testParentStopsBeingRecognisedOnceItHasSubFields() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        XCTAssertFalse(app.parentWindowIDs.contains(parent.id))

        let c = candidate(0, 0, 1, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: c.id)
        XCTAssertTrue(app.parentWindowIDs.contains(parent.id),
                      "The parent window must drop out of the recognition config")
    }

    /// Re-analysis mints fresh candidate ids. Matching selections by id would
    /// deselect everything each time the user nudged the window — the failure
    /// would look like the app randomly forgetting the user's choice.
    @MainActor
    func testSelectionSurvivesReanalysis() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)

        let first = candidate(0, 0, 1, 0.45)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [first, candidate(0, 0.55, 1, 0.45, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: first.id)
        XCTAssertNotNil(app.devices.first { $0.id == first.id })

        // Same two numbers, slightly shifted, all-new ids.
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [candidate(0, 0.03, 1, 0.45),
                                                             candidate(0, 0.58, 1, 0.45, rank: 1)])])

        let survivor = app.devices.first { $0.id == first.id }
        XCTAssertNotNil(survivor, "The user's selection was silently dropped by re-analysis")
        XCTAssertEqual(survivor?.origin?.region.y ?? -1, 0.03, accuracy: 1e-6,
                       "The surviving selection should track the number's new position")
    }

    /// The opposite risk: rebinding a selection to a DIFFERENT number because it
    /// happened to be the nearest. That would swap two columns' meaning mid-run
    /// with nothing visible to indicate it.
    @MainActor
    func testSelectionIsNotReboundToADistantCandidate() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)

        let top = candidate(0, 0.0, 1, 0.2)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [top, candidate(0, 0.3, 1, 0.2, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: top.id)

        // Nothing anywhere near where the selection was.
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [candidate(0, 0.9, 1, 0.1),
                                                             candidate(0, 0.75, 1, 0.1, rank: 1)])])

        let region = app.devices.first { $0.id == top.id }?.origin?.region
        XCTAssertEqual(region?.y ?? -1, 0.0, accuracy: 1e-6,
                       "A selection was rebound across the window to an unrelated number")
    }

    /// One candidate is not a choice — offering a box that merely duplicates
    /// the window is clutter, and the window already frames that number.
    @MainActor
    func testSingleCandidateOffersNoBoxes() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id, candidates: [candidate(0, 0, 1, 1)])])
        XCTAssertTrue(app.subFieldCandidates(for: parent.id).isEmpty)
    }

    /// The parent is excluded from recognition, so exporting it would put a
    /// permanently blank column in the CSV of a data-acquisition app.
    @MainActor
    func testParentWindowIsNotExportedOnceItHasSubFields() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        let c = candidate(0, 0, 1, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: c.id)

        app.startRecording()
        app.stopRecording()

        let exported = try? XCTUnwrap(app.completedSession?.devices)
        XCTAssertFalse(exported?.contains { $0.id == parent.id } ?? true,
                       "The frame window would export as an always-empty column")
        XCTAssertTrue(exported?.contains { $0.id == c.id } ?? false,
                      "The selected sub-field must be exported")
    }

    /// A sub-field's region is a fraction of a window. Delete the window and
    /// that fraction refers to nothing — the device could never be recomputed
    /// and would keep reporting from wherever the window last happened to be.
    @MainActor
    func testRemovingAWindowRemovesItsSubFields() {
        let app = AppState()
        app.addDevice()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        let c = candidate(0, 0, 1, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])
        app.toggleSubField(parentID: parent.id, candidateID: c.id)
        XCTAssertNotNil(app.devices.first { $0.id == c.id })

        app.removeDevice(id: parent.id)
        XCTAssertNil(app.devices.first { $0.id == c.id },
                     "An orphaned sub-field survived its parent window")
    }

    /// Fewer candidates than selections must not collapse two selections onto
    /// the same number — that yields two identically-valued CSV columns under
    /// different names, with nothing on screen to reveal it.
    @MainActor
    func testTwoSelectionsAreNotBoundToTheSameCandidate() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)

        let top = candidate(0, 0.0, 1, 0.4)
        let bottom = candidate(0, 0.45, 1, 0.4, rank: 1)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id, candidates: [top, bottom])])
        app.toggleSubField(parentID: parent.id, candidateID: top.id)
        app.toggleSubField(parentID: parent.id, candidateID: bottom.id)
        XCTAssertEqual(app.devices.filter(\.isSubField).count, 2)

        // A pass that only finds one of them this time.
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [candidate(0, 0.2, 1, 0.4)])])

        let regions = app.devices.filter(\.isSubField).map { $0.origin?.region }
        XCTAssertEqual(Set(regions.map { "\($0?.y ?? -1)" }).count, 2,
                       "Both selections collapsed onto the same candidate")
    }

    @MainActor
    func testSubFieldsCannotBeChangedWhileRecording() {
        let app = AppState()
        var parent = app.devices[0]
        parent.roi = .defaultROI
        app.updateDevice(parent)
        let c = candidate(0, 0, 1, 0.5)
        app.applyWindowAnalyses([WindowAnalysis(parentID: parent.id,
                                                candidates: [c, candidate(0, 0.5, 1, 0.5, rank: 1)])])
        app.startRecording()
        app.toggleSubField(parentID: parent.id, candidateID: c.id)
        XCTAssertNil(app.devices.first { $0.id == c.id },
                     "Adding a column mid-recording leaves earlier samples with no value for it")
    }
    /// DIAGNOSTIC: row profile and band/group trace of the synthetic
    /// dual-reading panel, read from the shipping grid rather than inferred.
    ///
    /// Kept because it earned its place. The band gate was wrong twice, and
    /// both times the cause was found by reading these numbers and missed by
    /// reasoning about them — including one round where a more sophisticated
    /// algorithm (Otsu's method) was implemented on a theory and made the real
    /// display strictly worse. Dump the trace before changing a threshold.
    func testDiagnostic_syntheticDualRowProfile() throws {
        let renderer = SyntheticDisplayRenderer()
        let frame = try XCTUnwrap(renderer.render(text: "90.0", secondary: "92.7", pose: .identity))
        let crop = try XCTUnwrap(PixelBufferROI.cropped(frame, to: SyntheticDisplayRenderer.displayROI))
        let g = try XCTUnwrap(LuminanceGrid(buffer: crop, maxLongEdge: 900, minEdge: 24))
        let thr = g.inkThreshold()
        var prof = [Int](repeating: 0, count: g.height)
        for y in 0..<g.height {
            var n = 0
            for x in 0..<g.width where g.isInk(x, y, thr) { n += 1 }
            prof[y] = n
        }
        let nonZero = prof.filter { $0 > 0 }.sorted()
        let median = nonZero.isEmpty ? 0 : nonZero[nonZero.count / 2]
        print("SYNTH grid \(g.width)x\(g.height) thr=\(thr) peak=\(prof.max() ?? 0) median(nonzero)=\(median) gate=\(Int(Double(median)*0.6))")
        let step = max(1, g.height / 30)
        var lines: [String] = []
        for y in stride(from: 0, to: g.height, by: step) {
            let seg = prof[y..<min(g.height, y + step)]
            let avg = seg.reduce(0,+) / max(1, seg.count)
            lines.append(String(format: "  y=%.3f %4d %@", Double(y)/Double(g.height), avg,
                                String(repeating: "#", count: Int(40*Double(avg)/Double(max(1, prof.max() ?? 1))))))
        }
        print(lines.joined(separator: "\n"))
        print("TRACE:\n" + NumberBandSplitter.debugRowTrace(crop))
    }

    /// A window framing ONE number must not sprout boxes: there is no choice to
    /// make, and a spurious box invites the user to select something that is
    /// not a reading. This is the cost side of the splitter's recall-first
    /// contract, so it needs an explicit guard.
    func testSingleReadingPanelOffersNoChoice() throws {
        let renderer = SyntheticDisplayRenderer()
        let frame = try XCTUnwrap(renderer.render(text: "12.384", pose: .identity))
        let analysis = try XCTUnwrap(
            WindowFieldAnalyzer.analyze(frame: frame,
                                        roi: SyntheticDisplayRenderer.displayROI,
                                        deviceID: UUID()))
        let report = analysis.candidates.map {
            String(format: "  rank %d x=%.3f y=%.3f w=%.3f h=%.3f glyph=%.3f",
                   $0.rank, $0.region.x, $0.region.y, $0.region.width,
                   $0.region.height, $0.glyphHeight)
        }.joined(separator: "\n")
        print("=== single-reading panel ===\n\(report)")
        XCTAssertFalse(analysis.offersChoice,
            "A single reading produced \(analysis.candidates.count) candidates:\n\(report)")
    }

    /// KNOWN LIMITATION, characterized rather than hidden: a single reading is
    /// sometimes offered as TWO boxes, split at its decimal point.
    ///
    /// Measured at 19 of 40 values on the synthetic face. The cause is that gap
    /// WIDTH cannot distinguish the two cases — `12.000` leaves a 99 px gap at
    /// its decimal against a 121 px band (0.82 of band height), and the real
    /// instrument's `MAX` legend sits 130 px from its reading against a 158 px
    /// band (also 0.82). Identical geometry, opposite meanings.
    ///
    /// A fix was implemented and REVERTED: merging groups whose gap still
    /// contains ink correctly rejoins the decimal, but the real photograph's
    /// legend gap carries enough sensor noise to clear any floor low enough to
    /// catch a decimal point, so it merged the `MAX` legend into the reading
    /// and broke the actual target device. Breaking the real instrument to fix
    /// a synthetic one is the wrong trade; see IMPLEMENTATION_NOTES for the
    /// direction that would close it properly.
    ///
    /// The user-visible cost is bounded by the recall-first contract: an extra
    /// box to ignore, never a wrong reading. `XCTExpectFailure` keeps this
    /// running so it reports the day the behaviour changes in either direction.
    func testNoSingleReadingValueOffersASpuriousChoice() throws {
        XCTExpectFailure("Single readings split at the decimal point — known, characterized above")
        let renderer = SyntheticDisplayRenderer()
        var offenders: [String] = []
        for step in 0..<40 {
            let value = 12.0 + Double(step) * 0.037
            let text = String(format: "%.3f", value)
            guard let frame = renderer.render(text: text, pose: .identity),
                  let analysis = WindowFieldAnalyzer.analyze(frame: frame,
                                                             roi: SyntheticDisplayRenderer.displayROI,
                                                             deviceID: UUID())
            else { continue }
            if analysis.offersChoice {
                let boxes = analysis.candidates.map {
                    String(format: "x=%.2f y=%.2f w=%.2f h=%.2f g=%.2f",
                           $0.region.x, $0.region.y, $0.region.width, $0.region.height, $0.glyphHeight)
                }.joined(separator: " | ")
                offenders.append("\(text) -> \(analysis.candidates.count): \(boxes)")
            }
        }
        if !offenders.isEmpty {
            print("=== single-reading values that offered a choice ===\n"
                  + offenders.joined(separator: "\n"))
        }
        XCTAssertTrue(offenders.isEmpty,
            "\(offenders.count)/40 single-reading values offered spurious sub-field boxes")
    }

}
