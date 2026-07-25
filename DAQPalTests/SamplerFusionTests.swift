//
//  SamplerFusionTests.swift
//  DAQPalTests
//
//  OCR_RESEARCH.md Phase 4 fusion — coverage for the classical
//  `SevenSegmentSampler` cross-check wired into `ConfidenceEngine.fuse` and
//  `MeasurementProcessor`. Two layers:
//
//  1. Pure `ConfidenceEngine` unit tests over every `CrossCheckOutcome` branch
//     (no Vision, deterministic): agreement never inflates, a confident
//     disagreement vetoes as `.ambiguousDigit` while depressing confidence, a
//     weak disagreement only depresses (no auto-reject), `.notAvailable` matches
//     a plain fuse call, and the cross-check never overrides an earlier gate.
//
//  2. End-to-end synthetic (skip-guarded on Vision silence, like the other
//     synthetic suites): on a SANS-rendered panel the seven-segment sampler must
//     ABSTAIN or AGREE — it must NEVER manufacture a cross-check rejection of a
//     valid reading. These validate WIRING, not real-instrument accuracy;
//     synthetic ≠ real optics (see `SyntheticDisplayGenerator`).
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class SamplerFusionTests: XCTestCase {

    private let engine = ConfidenceEngine()

    // A constrained 5-digit / decimal-after-2 format with NO unit — matches the
    // spec's DMM resolution while sidestepping unit-stripping concerns. Range is
    // wide so the physical validator never interferes with the cross-check gate.
    private static let constrained5x2 = DisplayFormat(digitCount: 5,
                                                      decimalPosition: 2,
                                                      signAllowed: true,
                                                      unit: nil,
                                                      minimumValue: -100,
                                                      maximumValue: 100,
                                                      constrainToFormat: true)

    /// A baseline "all gates pass" fuse call, overriding only the cross-check.
    /// (`DAQPal.Measurement`, not `Foundation.Measurement`.)
    private func fuse(ocr: Float = 0.9,
                      crossCheck: CrossCheckOutcome) -> DAQPal.Measurement {
        engine.fuse(timestamp: 0, value: 12.347, unit: nil, rawText: "12.347",
                    ocrConfidence: ocr, formatValid: true, physicalRejection: nil,
                    temporalConsistency: 1.0, temporalRejected: false,
                    crossCheck: crossCheck)
    }

    // MARK: - ConfidenceEngine: every CrossCheckOutcome branch

    func testNotAvailable_matchesBaselineFuse() {
        // `.notAvailable` must be identical to a fuse call that omits the
        // parameter entirely (the default) — the cross-check is purely additive.
        let explicit = fuse(crossCheck: .notAvailable)
        let implicit = engine.fuse(timestamp: 0, value: 12.347, unit: nil, rawText: "12.347",
                                   ocrConfidence: 0.9, formatValid: true, physicalRejection: nil,
                                   temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertTrue(explicit.accepted)
        XCTAssertNil(explicit.rejectionReason)
        XCTAssertEqual(explicit.confidence, implicit.confidence, accuracy: 1e-6)
        XCTAssertEqual(explicit.confidence, 0.9, accuracy: 1e-6)
    }

    func testAgrees_doesNotInflateConfidence() {
        // Corroboration is already reflected in the reading surviving; a strong
        // agreement must NOT push the fused product above the OCR-derived value.
        let m = fuse(crossCheck: .agrees(samplerConfidence: 0.99))
        XCTAssertTrue(m.accepted)
        XCTAssertNil(m.rejectionReason)
        XCTAssertEqual(m.confidence, 0.9, accuracy: 1e-6,
                       "agreement must not inflate above the OCR-derived confidence")
    }

    func testStrongDisagreement_vetoesAsAmbiguousDigit_andDepresses() {
        let c: Float = 0.8
        let m = fuse(crossCheck: .disagrees(samplerConfidence: c, samplerValue: 88.888))
        XCTAssertFalse(m.accepted, "a confident disagreement must reject the reading")
        XCTAssertEqual(m.rejectionReason, .ambiguousDigit)
        XCTAssertEqual(m.confidence, Float(0.9 * (1 - 0.8)), accuracy: 1e-6)
    }

    func testDisagreementAtVetoThreshold_vetoes() {
        // The threshold is inclusive: exactly `crossCheckVetoThreshold` vetoes.
        let c = ConfidenceEngine.crossCheckVetoThreshold
        let m = fuse(crossCheck: .disagrees(samplerConfidence: c, samplerValue: 0))
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .ambiguousDigit)
    }

    func testWeakDisagreement_depressesButDoesNotAutoReject() {
        let c: Float = 0.3 // below the 0.5 veto threshold
        let m = fuse(crossCheck: .disagrees(samplerConfidence: c, samplerValue: 88.888))
        XCTAssertTrue(m.accepted, "a weak disagreement (< veto threshold) must not veto on its own")
        XCTAssertNil(m.rejectionReason)
        XCTAssertEqual(m.confidence, Float(0.9 * (1 - 0.3)), accuracy: 1e-6,
                       "a weak disagreement should still depress the fused confidence")
    }

    func testCrossCheckNeverOverridesAnEarlierGate() {
        // Rejection precedence: a physical rejection already names the reason, so
        // even a confident disagreement must not relabel it `.ambiguousDigit`.
        let m = engine.fuse(timestamp: 0, value: 999, unit: nil, rawText: "999.000",
                            ocrConfidence: 0.9, formatValid: true, physicalRejection: .outOfRange,
                            temporalConsistency: 1.0, temporalRejected: false,
                            crossCheck: .disagrees(samplerConfidence: 0.9, samplerValue: 12.347))
        XCTAssertEqual(m.rejectionReason, .outOfRange,
                       "the cross-check applies only after every prior gate passes")
    }

    func testCrossCheckDoesNotApplyWhenFormatInvalid() {
        let m = engine.fuse(timestamp: 0, value: .nan, unit: nil, rawText: "junk",
                            ocrConfidence: 0.9, formatValid: false, physicalRejection: nil,
                            temporalConsistency: 1.0, temporalRejected: false,
                            crossCheck: .disagrees(samplerConfidence: 0.9, samplerValue: 1))
        XCTAssertEqual(m.rejectionReason, .invalidFormat)
    }

    func testDisagreementNeverExceedsOCRConfidence() {
        // The cross-check can only DEPRESS, so `final ≤ ocr` must still hold.
        for ocr: Float in [0.3, 0.55, 0.9, 1.0] {
            for c: Float in [0.1, 0.49, 0.5, 0.9] {
                let m = fuse(ocr: ocr, crossCheck: .disagrees(samplerConfidence: c, samplerValue: 0))
                XCTAssertLessThanOrEqual(m.confidence, ocr + 1e-6)
            }
        }
    }

    // MARK: - End-to-end: sampler never vetoes a valid SANS reading

    /// Renders `text` via the app-target `SyntheticDisplayRenderer`; skips (not
    /// fails) if the environment can't allocate a buffer.
    private func makeFrame(text: String, timestamp: TimeInterval,
                           renderer: SyntheticDisplayRenderer) throws -> TimestampedFrame {
        guard let buffer = renderer.render(text: text) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        return TimestampedFrame(pixelBuffer: buffer, timestamp: timestamp)
    }

    func testConstrainedDevice_samplerNeverVetoesRenderedSansReading() async throws {
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: Self.constrained5x2)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var everAccepted = false
        var crossCheckRejections = 0
        for i in 0..<8 {
            let frame = try makeFrame(text: "12.347", timestamp: Double(i) / 12.0, renderer: renderer)
            let result = await processor.process(frame: frame)
            guard let m = result.readings[config.id] else { continue }
            if m.rawText != nil { sawAnyOCRText = true }
            if m.accepted { everAccepted = true }
            if m.rejectionReason == .ambiguousDigit { crossCheckRejections += 1 }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        // The load-bearing invariant on a SANS fixture: the seven-segment
        // cross-check abstains (or agrees) — it must NEVER veto a valid reading.
        XCTAssertEqual(crossCheckRejections, 0,
                       "the classical sampler must not veto a valid sans reading (abstain-not-veto)")
        XCTAssertTrue(everAccepted,
                      "a valid rendered \"12.347\" must still be accepted with the cross-check wired in")
    }

    /// The direct veto path, proven without Vision: a confident disagreement fed
    /// straight into `fuse` rejects. (Complements the end-to-end test, which can
    /// only ever observe the ABSENCE of a veto on a sans fixture.)
    func testVetoPathIsReachableViaFuseDirectly() {
        let m = fuse(crossCheck: .disagrees(samplerConfidence: 0.9, samplerValue: 88.888))
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .ambiguousDigit)
    }

    // MARK: - Sampler abstains on non-segment (sans) glyphs

    func testSansGlyphs_produceNoAmbiguousDigitRejection() async throws {
        // Build a sans line via the test generator (deterministic) and drive the
        // processor with a constrained format. The seven-seg sampler cannot form
        // a clean digit pattern out of proportional glyphs, so it must abstain —
        // never a `.ambiguousDigit` veto.
        let generator = try SyntheticDisplayGenerator()
        let sample = try generator.lineSample(text: "12.347", style: .sans,
                                              augmentation: .clean, augmentationName: "clean")
        let processor = MeasurementProcessor()
        // The generator centers the line; the whole buffer is the display so the
        // fixed-pitch digit cells overlap the glyphs.
        let roi = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let config = DeviceRecognitionConfig(id: UUID(), roi: roi, format: Self.constrained5x2)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var ambiguousRejections = 0
        for i in 0..<6 {
            let frame = TimestampedFrame(pixelBuffer: sample.pixelBuffer, timestamp: Double(i) / 12.0)
            let result = await processor.process(frame: frame)
            guard let m = result.readings[config.id] else { continue }
            if m.rawText != nil { sawAnyOCRText = true }
            if m.rejectionReason == .ambiguousDigit { ambiguousRejections += 1 }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic sans frames in this environment")
        }
        XCTAssertEqual(ambiguousRejections, 0,
                       "the seven-segment sampler must abstain on non-segment sans glyphs, not veto")
    }
}
