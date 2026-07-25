//
//  DualPassVisionOCRTests.swift
//  DAQPalTests
//
//  Unit coverage for `DualPassVisionOCR`'s MERGE behavior (OCR_RESEARCH.md
//  Phase 1 / Milestone 9 dual-pass lever). The engine composes two `VisionOCR`
//  levels directly, so these tests drive its `init(primary:rescue:)` injection
//  seam with deterministic stub engines — no Vision, no rendering — to pin down
//  the contract the downstream picker depends on:
//
//    - primary candidates come FIRST, in their own order (never re-sorted);
//    - a rescue candidate whose trimmed text duplicates a primary one is
//      dropped (the primary entry, with its calibrated confidence, is kept);
//    - rescue-only (non-duplicate) candidates pass through, after the primary;
//    - if one engine throws, the other's candidates are still returned;
//    - if BOTH throw, the primary's error is re-thrown.
//
//  A final synthetic smoke test runs the real `DualPassVisionOCR()` over a
//  generator-rendered sans line and asserts it yields a candidate parsing to
//  the truth — skip-guarded (standard pattern) when Vision is silent in this
//  environment, so it never fabricates a pass.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class DualPassVisionOCRTests: XCTestCase {

    // MARK: Stubs

    private enum StubError: Error, Equatable {
        case primaryFailed
        case rescueFailed
    }

    /// A deterministic `OCREngine` that returns a fixed candidate list, or
    /// throws a fixed error. Ignores the buffer/ROI — the merge logic under
    /// test never inspects them.
    private struct StubEngine: OCREngine {
        let candidates: [OCRCandidate]
        let error: Error?

        init(_ candidates: [OCRCandidate]) {
            self.candidates = candidates
            self.error = nil
        }

        init(throwing error: Error) {
            self.candidates = []
            self.error = error
        }

        func recognize(in pixelBuffer: CVPixelBuffer,
                       regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
            if let error { throw error }
            return candidates
        }
    }

    private static func candidate(_ text: String, _ confidence: Float) -> OCRCandidate {
        OCRCandidate(text: text, confidence: confidence)
    }

    /// A minimal valid buffer to satisfy the `recognize` signature; the stub
    /// engines ignore it. Skips (environment limitation) if allocation fails.
    private func makeBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
                                         kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw XCTSkip("CVPixelBufferCreate failed in this environment")
        }
        return buffer
    }

    // MARK: Ordering

    func testPrimaryCandidatesLeadInTheirOwnOrder_notReSortedAcrossEngines() async throws {
        // Rescue's lone candidate has the HIGHEST confidence of all — if the
        // merge re-sorted by confidence it would jump to the front. It must not:
        // ordering encodes preference, and `.accurate` (primary) always leads.
        let primary = StubEngine([Self.candidate("A", 0.90), Self.candidate("B", 0.50)])
        let rescue = StubEngine([Self.candidate("C", 0.99)])
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.map(\.text), ["A", "B", "C"],
                       "primary candidates first in their own order, then rescue's — never re-sorted by confidence")
        XCTAssertEqual(merged.map(\.confidence), [0.90, 0.50, 0.99],
                       "confidences pass through untouched")
    }

    // MARK: Textual de-duplication

    func testTextualDuplicate_keepsPrimaryCandidateAndItsConfidence() async throws {
        // Primary reads "12.347" at a calibrated 0.92; rescue also reads
        // "12.347" but at its raw 0.30, plus a genuinely new "12.4". The dup
        // must resolve to the PRIMARY entry (0.92, not 0.30) — the earlier
        // 32%-confidence UI regression must not return — and the new "12.4"
        // passes through after it.
        let primary = StubEngine([Self.candidate("12.347", 0.92)])
        let rescue = StubEngine([Self.candidate("12.347", 0.30), Self.candidate("12.4", 0.28)])
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.map(\.text), ["12.347", "12.4"],
                       "the rescue duplicate is dropped; its new candidate is appended")
        XCTAssertEqual(merged.first?.confidence, 0.92,
                       "the surviving \"12.347\" carries the PRIMARY confidence, not the rescue's")
    }

    func testDeDuplicationIsByTrimmedText() async throws {
        // Rescue's "  12.347 " differs only by surrounding whitespace and must
        // still be treated as a duplicate of the primary's "12.347".
        let primary = StubEngine([Self.candidate("12.347", 0.90)])
        let rescue = StubEngine([Self.candidate("  12.347 ", 0.30)])
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.count, 1, "trimmed-text duplicate must not be appended")
        XCTAssertEqual(merged.first?.text, "12.347")
        XCTAssertEqual(merged.first?.confidence, 0.90)
    }

    func testRescueOnlyCandidatesPassThrough_whenPrimaryProducesNone() async throws {
        // Primary succeeds but reads nothing (an empty list is success, not a
        // failure); every rescue candidate then survives, in rescue order.
        let primary = StubEngine([])
        let rescue = StubEngine([Self.candidate("33.3", 0.33), Self.candidate("7", 0.15)])
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.map(\.text), ["33.3", "7"])
        XCTAssertEqual(merged.map(\.confidence), [0.33, 0.15])
    }

    // MARK: One-engine-failure resilience

    func testPrimaryThrows_rescueCandidatesStillReturned() async throws {
        let primary = StubEngine(throwing: StubError.primaryFailed)
        let rescue = StubEngine([Self.candidate("42", 0.31)])
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.map(\.text), ["42"],
                       "a primary failure must not sink the rescue pass's usable candidates")
    }

    func testRescueThrows_primaryCandidatesStillReturned() async throws {
        let primary = StubEngine([Self.candidate("9.99", 0.88)])
        let rescue = StubEngine(throwing: StubError.rescueFailed)
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)

        let merged = try await engine.recognize(in: try makeBuffer(), regionOfInterest: nil)

        XCTAssertEqual(merged.map(\.text), ["9.99"],
                       "a rescue failure must not sink the primary pass's candidates")
    }

    func testBothEnginesThrow_rethrowsPrimaryError() async throws {
        let primary = StubEngine(throwing: StubError.primaryFailed)
        let rescue = StubEngine(throwing: StubError.rescueFailed)
        let engine = DualPassVisionOCR(primary: primary, rescue: rescue)
        let buffer = try makeBuffer()

        do {
            _ = try await engine.recognize(in: buffer, regionOfInterest: nil)
            XCTFail("both engines failing must propagate an error")
        } catch let error as StubError {
            XCTAssertEqual(error, .primaryFailed,
                           "the primary's error is surfaced, matching single-engine failure behavior")
        }
    }

    // MARK: Synthetic smoke (real Vision, skip-guarded)

    func testSyntheticSansLine_dualPassReadsTheTruth() async throws {
        // The real shipping engine (both Vision levels concurrently) over a
        // clean sans "12.347" — the raster/OLED case where `.accurate` is
        // strong. Assert at least one merged candidate parses to the truth.
        // Skip when Vision is silent here (standard guard) rather than fake a
        // pass — Vision on synthetic renders varies by OS/Simulator build.
        let generator: SyntheticDisplayGenerator
        do {
            generator = try SyntheticDisplayGenerator()
        } catch {
            throw XCTSkip("SyntheticDisplayGenerator unavailable (DSEG fonts missing from test bundle?): \(error)")
        }

        let truthLabel = "12.347"
        let sample = try generator.lineSample(text: truthLabel,
                                              style: .sans,
                                              augmentation: .clean,
                                              augmentationName: "clean")
        let engine = DualPassVisionOCR()
        let candidates = try await engine.recognize(in: sample.pixelBuffer, regionOfInterest: nil)

        guard !candidates.isEmpty else {
            throw XCTSkip("DualPass (Vision) produced no candidates on a synthetic sans line in this environment")
        }
        guard let truth = RecognitionBenchmark.groundTruth(of: truthLabel) else {
            return XCTFail("ground truth for \(truthLabel) should be a plain decimal")
        }

        let parsedToTruth = candidates.contains { candidate in
            if case .valid(let value) = FormatValidator.value(from: candidate.text,
                                                              format: .unconstrained) {
                return abs(value - truth.value) <= truth.tolerance
            }
            return false
        }
        XCTAssertTrue(parsedToTruth,
                      "at least one merged candidate should parse to \(truthLabel); got \(candidates.map(\.text))")
    }
}
