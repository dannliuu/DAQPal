//
//  AppearanceSentinelTests.swift
//  DAQPalTests
//
//  Unit coverage for `AppearanceSentinel` and `LumaPatch` — the per-frame
//  appearance defense against the false healthy-lock (ARCHITECTURE.md §11).
//  Pure logic over hand-built BGRA buffers: pixel bytes are written directly,
//  no Vision, no CoreImage, no Date(), no randomness.
//
//  The scenarios encoded here are the §11 failure and its inverse:
//    * Reference sampled on a structured panel, tracked quad now parked on
//      flat background → hard veto within K frames (via variance collapse
//      and/or NCC), even though the tracker reports healthy.
//    * Digits changing on the SAME panel → never a veto: panel structure
//      dominates the patch and the reference refreshes on corroboration.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class AppearanceSentinelTests: XCTestCase {

    // MARK: - Synthetic scene
    //
    // A 320×240 BGRA frame: uniform mid-gray background with a "panel" — a
    // high-contrast striped region standing in for bezel/segment structure —
    // and an optional small "digit" block whose value can change between
    // frames. Everything is byte-exact and deterministic.

    private let frameWidth = 320
    private let frameHeight = 240

    /// Panel pixel region (matches `panelQuad` below).
    private let panelRect = CGRect(x: 32, y: 24, width: 128, height: 72)

    /// Normalized quads for the panel and for an empty background region of
    /// the same shape — the "parked" geometry of §11.
    private var panelQuad: ScreenQuad {
        ScreenQuad(roi: NormalizedROI(x: 0.1, y: 0.1, width: 0.4, height: 0.3))
    }
    private var backgroundQuad: ScreenQuad {
        ScreenQuad(roi: NormalizedROI(x: 0.55, y: 0.60, width: 0.4, height: 0.3))
    }

    /// Builds a BGRA buffer: gray background, striped panel, and a digit
    /// block drawn as a solid square whose luma encodes `digitValue`. The
    /// digit block is deliberately a small fraction of the panel (16×16 px of
    /// 128×72 ≈ 2.8%) — the "digits are a small fraction of the patch"
    /// premise under test.
    private func makeFrame(digitValue: UInt8 = 0, includePanel: Bool = true) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, frameWidth, frameHeight,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("could not allocate a BGRA pixel buffer in this environment")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let digitRect = CGRect(x: panelRect.minX + 90, y: panelRect.minY + 30,
                               width: 16, height: 16)

        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let point = CGPoint(x: x, y: y)
                let luma: UInt8
                if includePanel, panelRect.contains(point) {
                    if digitRect.contains(point) {
                        luma = digitValue
                    } else {
                        // Vertical stripes, period 16 px: strong structure.
                        luma = ((x / 8) % 2 == 0) ? 220 : 30
                    }
                } else {
                    luma = 128 // flat background
                }
                let p = y * bytesPerRow + x * 4
                base[p] = luma       // B
                base[p + 1] = luma   // G
                base[p + 2] = luma   // R
                base[p + 3] = 255    // A
            }
        }
        return buffer
    }

    /// `makeFrame` plus an opaque bar covering `coverFraction` of the panel's
    /// HEIGHT from its top edge — a hand, probe or cable resting on the display.
    private func makeOccludedFrame(digitValue: UInt8 = 0, coverFraction: CGFloat) throws -> CVPixelBuffer {
        let buffer = try makeFrame(digitValue: digitValue)
        guard coverFraction > 0 else { return buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let coverRows = Int((panelRect.height * min(coverFraction, 1)).rounded())
        let y0 = Int(panelRect.minY)
        for y in y0..<(y0 + coverRows) where y < frameHeight {
            for x in Int(panelRect.minX)..<Int(panelRect.maxX) where x < frameWidth {
                let p = y * bytesPerRow + x * 4
                base[p] = 70; base[p + 1] = 70; base[p + 2] = 70; base[p + 3] = 255
            }
        }
        return buffer
    }

    private func makeNonBGRABuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64,
                                         kCVPixelFormatType_OneComponent8, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("could not allocate a OneComponent8 buffer in this environment")
        }
        return buffer
    }

    // MARK: - LumaPatch

    func testPatchOnStructuredPanelHasHighVariance_flatBackgroundNearZero() throws {
        let frame = try makeFrame()
        guard let panel = LumaPatch.sample(from: frame, quad: panelQuad),
              let flat = LumaPatch.sample(from: frame, quad: backgroundQuad) else {
            return XCTFail("sampling failed on a valid BGRA buffer")
        }
        XCTAssertGreaterThan(panel.variance, 1000,
                             "striped panel must read as strongly structured")
        XCTAssertLessThan(flat.variance, 1,
                          "uniform background must read as near-zero variance")
        XCTAssertEqual(flat.mean, 128, accuracy: 1.0)
    }

    func testNCCOfAPatchWithItselfIsOne_andFlatPatchesDoNotCorrelate() throws {
        let frame = try makeFrame()
        guard let panel = LumaPatch.sample(from: frame, quad: panelQuad),
              let flat = LumaPatch.sample(from: frame, quad: backgroundQuad) else {
            return XCTFail("sampling failed on a valid BGRA buffer")
        }
        guard let selfNCC = LumaPatch.ncc(panel, panel) else {
            return XCTFail("NCC of a structured patch with itself must be defined")
        }
        XCTAssertEqual(selfNCC, 1.0, accuracy: 1e-3)
        XCTAssertNil(LumaPatch.ncc(panel, flat),
                     "correlation against a flat patch is meaningless and must be nil "
                     + "(variance collapse owns that regime)")
    }

    func testUnsupportedPixelFormatSamplesNil() throws {
        let buffer = try makeNonBGRABuffer()
        XCTAssertNil(LumaPatch.sample(from: buffer, quad: panelQuad),
                     "non-BGRA buffers must be unsampleable, never garbage")
    }

    // MARK: - The §11 scenario: parked on background ⇒ veto within K frames

    func testQuadParkedOnFlatBackgroundVetoesWithinKFrames() throws {
        let frame = try makeFrame()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
        XCTAssertNotNil(sentinel.reference, "lock commit on a valid frame must capture a reference")

        let k = sentinel.config.consecutiveFailuresToVeto
        for i in 1..<k {
            let verdict = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
            XCTAssertEqual(verdict, .suspect(ncc: nil, consecutiveFailures: i),
                           "frame \(i) on flat background must count a failure without vetoing yet "
                           + "(NCC is nil against a zero-variance patch; variance collapse is the "
                           + "failing signal)")
            XCTAssertTrue(sentinel.isHealthy, "vetoed before \(k) consecutive failures")
        }

        let final = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        XCTAssertEqual(final, .vetoed(ncc: nil))
        XCTAssertFalse(sentinel.isHealthy,
                       "\(k) consecutive frames on background must be a hard veto")
    }

    /// The veto is sticky: one frame that happens to correlate again must not
    /// heal a vetoed lock — only refreshed independent evidence does.
    func testVetoIsStickyUntilRefreshed() throws {
        let frame = try makeFrame()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
        for _ in 0..<sentinel.config.consecutiveFailuresToVeto {
            _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        }
        XCTAssertFalse(sentinel.isHealthy)

        let backOnPanel = sentinel.evaluate(pixelBuffer: frame, quad: panelQuad)
        guard case .vetoed = backOnPanel else {
            return XCTFail("a vetoed sentinel healed itself from one matching frame: \(backOnPanel)")
        }

        sentinel.refreshReference(pixelBuffer: frame, quad: panelQuad)
        XCTAssertTrue(sentinel.isHealthy,
                      "corroborated refresh must clear the veto — fresh independent "
                      + "evidence outranks stale appearance memory")
        XCTAssertEqual(sentinel.consecutiveFailures, 0)
    }

    // MARK: - Legitimate digit changes never veto

    func testDigitChangeOnSamePanelStaysHealthy() throws {
        let reading1 = try makeFrame(digitValue: 30)   // digit block dark
        let reading2 = try makeFrame(digitValue: 220)  // digit block bright
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: reading1, quad: panelQuad)

        // Twice K frames of the changed reading with NO reference refresh —
        // strictly harsher than live, where corroboration refreshes every
        // ~0.5 s. Panel structure must dominate the correlation.
        for i in 0..<(2 * sentinel.config.consecutiveFailuresToVeto) {
            let verdict = sentinel.evaluate(pixelBuffer: reading2, quad: panelQuad)
            guard case .healthy(let ncc) = verdict else {
                return XCTFail("digit change read as appearance failure on frame \(i): \(verdict)")
            }
            XCTAssertNotNil(ncc)
            if let ncc {
                XCTAssertGreaterThan(ncc, sentinel.config.nccVetoThreshold,
                                     "digit change dragged NCC to \(ncc) — the "
                                     + "structure-dominates premise failed")
            }
        }
        XCTAssertTrue(sentinel.isHealthy)
    }

    // MARK: - Refresh semantics

    func testRefreshResetsTheConsecutiveFailureCount() throws {
        let frame = try makeFrame()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
        let k = sentinel.config.consecutiveFailuresToVeto

        for _ in 0..<(k - 1) {
            _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        }
        XCTAssertEqual(sentinel.consecutiveFailures, k - 1)

        // A corroborated pass refreshes the reference mid-streak.
        sentinel.refreshReference(pixelBuffer: frame, quad: panelQuad)
        XCTAssertEqual(sentinel.consecutiveFailures, 0)

        // k-1 further failures must not veto: the streak restarted.
        for _ in 0..<(k - 1) {
            _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        }
        XCTAssertTrue(sentinel.isHealthy,
                      "failures across a refresh were counted as one streak")

        // One more completes a genuine streak.
        _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        XCTAssertFalse(sentinel.isHealthy)
    }

    /// Refreshing with an unsampleable frame must keep the previous reference
    /// rather than discarding it.
    func testRefreshWithUnsampleableFrameKeepsThePreviousReference() throws {
        let frame = try makeFrame()
        let bad = try makeNonBGRABuffer()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
        let before = sentinel.reference
        XCTAssertNotNil(before)

        sentinel.refreshReference(pixelBuffer: bad, quad: panelQuad)
        XCTAssertEqual(sentinel.reference, before,
                       "a failed refresh sample must not destroy the working reference")
    }

    // MARK: - Abstention (the cannot-judge posture)

    func testNoReferenceAbstains_neverVetoes() throws {
        let frame = try makeFrame()
        var sentinel = AppearanceSentinel()
        for _ in 0..<10 {
            XCTAssertEqual(sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad),
                           .abstained)
        }
        XCTAssertTrue(sentinel.isHealthy)
        XCTAssertEqual(sentinel.consecutiveFailures, 0)
    }

    func testUnsampleableLockFrameLeavesSentinelAbstaining() throws {
        let bad = try makeNonBGRABuffer()
        let good = try makeFrame()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: bad, quad: panelQuad)
        XCTAssertNil(sentinel.reference)
        XCTAssertEqual(sentinel.evaluate(pixelBuffer: good, quad: backgroundQuad), .abstained,
                       "a sentinel that could not fingerprint the lock must abstain, not guess")
        XCTAssertTrue(sentinel.isHealthy)
    }

    /// An unsampleable frame mid-lock is not evidence: it must neither
    /// advance nor clear the failure streak.
    func testUnsampleableFrameDoesNotAdvanceOrClearTheStreak() throws {
        let frame = try makeFrame()
        let bad = try makeNonBGRABuffer()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)

        _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        _ = sentinel.evaluate(pixelBuffer: frame, quad: backgroundQuad)
        XCTAssertEqual(sentinel.consecutiveFailures, 2)

        XCTAssertEqual(sentinel.evaluate(pixelBuffer: bad, quad: backgroundQuad), .abstained)
        XCTAssertEqual(sentinel.consecutiveFailures, 2,
                       "an unsampleable frame changed the failure streak")
    }

    // MARK: - Telemetry

    func testNCCIsExposedForTelemetry() throws {
        let frame = try makeFrame()
        var sentinel = AppearanceSentinel()
        sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
        XCTAssertNil(sentinel.lastNCC, "no evaluation yet — no NCC to report")

        _ = sentinel.evaluate(pixelBuffer: frame, quad: panelQuad)
        guard let ncc = sentinel.lastNCC else {
            return XCTFail("NCC must be exposed after evaluating a structured patch")
        }
        XCTAssertGreaterThan(ncc, 0.95,
                             "same panel, same frame: NCC must be near 1 (got \(ncc))")
    }

    // MARK: - Determinism

    func testSameFramesYieldIdenticalVerdictSequences() throws {
        let frame = try makeFrame()
        func run() throws -> [AppearanceSentinel.Verdict] {
            var sentinel = AppearanceSentinel()
            sentinel.beginLock(pixelBuffer: frame, quad: panelQuad)
            var verdicts: [AppearanceSentinel.Verdict] = []
            for quad in [panelQuad, backgroundQuad, backgroundQuad, panelQuad,
                         backgroundQuad, backgroundQuad, backgroundQuad, backgroundQuad] {
                verdicts.append(sentinel.evaluate(pixelBuffer: frame, quad: quad))
            }
            return verdicts
        }
        XCTAssertEqual(try run(), try run())
    }
    // MARK: - Occlusion vs drift (finding ported from a redundant experiment)

    /// A parallel content-descriptor experiment (since removed as redundant
    /// with this NCC path) measured that a luma descriptor CANNOT distinguish
    /// a partly occluded panel from a quad parked on background: past ~10%
    /// cover its similarity fell *below* the background case. The two demands
    /// are in tension for any such descriptor — the evidence that rejects
    /// background lives in the minority of cells containing ink, so ignoring a
    /// corrupted minority also discards the only signal that separates a
    /// display from a wall.
    ///
    /// This measures whether the SHIPPED sentinel inherits that behaviour,
    /// because the consequence is concrete: `consecutiveFailuresToVeto` is 4
    /// at PER-FRAME cadence (~0.33 s at 12 fps), so if occlusion reads as a
    /// failure, a hand resting briefly on the panel vetoes a healthy lock.
    ///
    /// It CHARACTERIZES rather than prescribes: the recorded numbers are the
    /// deliverable, and the only hard assertion is the one that must hold for
    /// the sentinel to be usable at all — an unoccluded digit change stays
    /// healthy.
    func testOcclusionVersusBackground_characterized() throws {
        var sentinel = AppearanceSentinel()
        let reference = try makeFrame(digitValue: 0)
        sentinel.beginLock(pixelBuffer: reference, quad: panelQuad)

        func ncc(_ buffer: CVPixelBuffer, quad: ScreenQuad) -> Float? {
            var probe = sentinel
            switch probe.evaluate(pixelBuffer: buffer, quad: quad) {
            case .healthy(let n), .suspect(let n, _), .vetoed(let n): return n
            case .abstained: return nil
            }
        }

        var report: [String] = []
        let digitChange = ncc(try makeFrame(digitValue: 255), quad: panelQuad)
        report.append(String(format: "digit change (no occlusion): %.3f", digitChange ?? -1))

        for cover in [0.10, 0.25, 0.50] as [CGFloat] {
            let value = ncc(try makeOccludedFrame(digitValue: 0, coverFraction: cover), quad: panelQuad)
            report.append(String(format: "occlusion %.0f%%: %.3f", cover * 100, value ?? -1))
        }
        let background = ncc(try makeFrame(digitValue: 0), quad: backgroundQuad)
        report.append(String(format: "parked on background: %.3f", background ?? -1))

        print("=== AppearanceSentinel NCC characterization ===\n" + report.joined(separator: "\n"))

        // The one property that must hold: a digit change on the real panel is
        // not mistaken for a lost lock. Everything else is recorded for the
        // record rather than asserted, because the tension above is a genuine
        // property of luma descriptors, not a bug to assert away.
        XCTAssertNotNil(digitChange)
        XCTAssertGreaterThan(digitChange ?? -1, AppearanceSentinel.Config().nccVetoThreshold,
                             "A digit change must never read as a lost lock. Report:\n" + report.joined(separator: "\n"))
    }

}
