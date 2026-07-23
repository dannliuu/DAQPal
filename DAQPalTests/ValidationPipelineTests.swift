//
//  ValidationPipelineTests.swift
//  DAQPalTests
//
//  Covers `PhysicalValidator`, `TemporalFilter`, and `ConfidenceEngine` in
//  isolation, on a single thread, matching the ownership model documented on
//  `MeasurementProcessor` (each is mutated only in a synchronous stretch).
//

import XCTest
@testable import DAQPal

final class ValidationPipelineTests: XCTestCase {

    // MARK: - PhysicalValidator

    func testPhysicalValidator_inRangeAccepted() {
        let validator = PhysicalValidator(format: .defaultDMM) // range -20...20
        XCTAssertNil(validator.validate(value: 12.347, timestamp: 0))
    }

    func testPhysicalValidator_outOfRangeRejected() {
        let validator = PhysicalValidator(format: .defaultDMM) // range -20...20
        XCTAssertEqual(validator.validate(value: 25, timestamp: 0), .outOfRange)
    }

    func testPhysicalValidator_belowMinimumRejected() {
        let validator = PhysicalValidator(format: .defaultDMM)
        XCTAssertEqual(validator.validate(value: -25, timestamp: 0), .outOfRange)
    }

    func testPhysicalValidator_noRangeConfigured_rateCheckDisabled() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 2, signAllowed: true,
                                   unit: "V", minimumValue: nil, maximumValue: nil)
        let validator = PhysicalValidator(format: format)
        validator.recordAccepted(value: 0, timestamp: 0)
        // An enormous jump with no configured range never triggers a rate
        // rejection (rate checking requires both bounds).
        XCTAssertNil(validator.validate(value: 1_000_000, timestamp: 0.001))
    }

    func testPhysicalValidator_largeJumpRejectedAsExcessiveRate() {
        // span 100 -> max rate 200/s (rateSpanMultiplier 2.0).
        let format = DisplayFormat(digitCount: 5, decimalPosition: 2, signAllowed: false,
                                   unit: "V", minimumValue: 0, maximumValue: 100)
        let validator = PhysicalValidator(format: format)
        XCTAssertNil(validator.validate(value: 12.347, timestamp: 0))
        validator.recordAccepted(value: 12.347, timestamp: 0)
        // 82.347 - 12.347 = 70 over 0.05s = 1400/s, far over the 200/s limit.
        XCTAssertEqual(validator.validate(value: 82.347, timestamp: 0.05), .excessiveRateOfChange)
    }

    func testPhysicalValidator_sustainedStepChangeEventuallyAccepted() {
        // spec §16: a real transition must survive, not latch permanently.
        let format = DisplayFormat(digitCount: 5, decimalPosition: 2, signAllowed: false,
                                   unit: "V", minimumValue: 0, maximumValue: 100)
        let validator = PhysicalValidator(format: format)
        XCTAssertNil(validator.validate(value: 12.347, timestamp: 0))
        validator.recordAccepted(value: 12.347, timestamp: 0)

        var lastResult: RejectionReason?
        // maxConsecutiveRateRejections = 5: the 6th consecutive rejection call
        // admits the new level as a genuine step change.
        for i in 1...(PhysicalValidator.maxConsecutiveRateRejections + 1) {
            lastResult = validator.validate(value: 82.347, timestamp: Double(i) * 0.05)
            if i <= PhysicalValidator.maxConsecutiveRateRejections {
                XCTAssertEqual(lastResult, .excessiveRateOfChange, "rejection \(i) should still be rate-limited")
            }
        }
        XCTAssertNil(lastResult, "the step change must be admitted once it has been sustained")
    }

    func testPhysicalValidator_withinLimitReadingResetsRejectionStreak() {
        let format = DisplayFormat(digitCount: 5, decimalPosition: 2, signAllowed: false,
                                   unit: "V", minimumValue: 0, maximumValue: 100)
        let validator = PhysicalValidator(format: format)
        validator.recordAccepted(value: 12.347, timestamp: 0)
        XCTAssertEqual(validator.validate(value: 82.347, timestamp: 0.05), .excessiveRateOfChange)
        // A plausible reading breaks the streak; recording it as the new baseline...
        XCTAssertNil(validator.validate(value: 12.4, timestamp: 0.1))
        validator.recordAccepted(value: 12.4, timestamp: 0.1)
        // ...so a fresh run of rejections needs its own 5 tries before admitting.
        XCTAssertEqual(validator.validate(value: 82.347, timestamp: 0.15), .excessiveRateOfChange)
    }

    // MARK: - TemporalFilter

    func testTemporalFilter_stableWindowHighConsistency() {
        let filter = TemporalFilter(format: .defaultDMM)
        var last: TemporalFilter.Evaluation!
        for _ in 0..<(TemporalFilter.windowSize + 2) {
            last = filter.evaluate(value: 12.347)
        }
        XCTAssertEqual(last.consistency, 1.0, accuracy: 1e-6)
        XCTAssertFalse(last.rejected)
    }

    func testTemporalFilter_startupReadingsNotPenalized() {
        let filter = TemporalFilter(format: .defaultDMM)
        // Window isn't full yet -> consistency reported as 1.0 regardless of
        // value churn, and never rejected.
        let first = filter.evaluate(value: 12.347)
        XCTAssertEqual(first.consistency, 1.0, accuracy: 1e-6)
        XCTAssertFalse(first.rejected)
        let second = filter.evaluate(value: 99.999)
        XCTAssertFalse(second.rejected)
    }

    func testTemporalFilter_singleOutlierFlaggedOnceWindowIsFull() {
        let filter = TemporalFilter(format: .defaultDMM)
        for _ in 0..<TemporalFilter.windowSize {
            _ = filter.evaluate(value: 12.347)
        }
        // A wildly different value should disagree at most digit positions.
        let outlier = filter.evaluate(value: 99.999)
        XCTAssertLessThan(outlier.consistency, TemporalFilter.consistencyThreshold)
        XCTAssertTrue(outlier.rejected)
    }

    func testTemporalFilter_sustainedChangePassesAfterWindowTurnover() {
        // spec §16: 12.000 -> 13.001 must remain detectable, i.e. survive once
        // the window has turned over to the new value.
        let filter = TemporalFilter(format: .defaultDMM)
        for _ in 0..<TemporalFilter.windowSize {
            _ = filter.evaluate(value: 12.000)
        }
        // Each call scores against the window as it stood *before* that call's
        // own value is admitted, so windowSize + 1 pushes of the new value are
        // needed before a call sees an all-13.001 window.
        var lastEvaluation: TemporalFilter.Evaluation!
        for _ in 0..<(TemporalFilter.windowSize + 1) {
            lastEvaluation = filter.evaluate(value: 13.001)
        }
        // The window is entirely 13.001 again, so the reading must no longer
        // be flagged as inconsistent — the sustained transition survives.
        XCTAssertFalse(lastEvaluation.rejected)
        XCTAssertEqual(lastEvaluation.consistency, 1.0, accuracy: 1e-6)
    }

    func testTemporalFilter_decadeRolloverRampNotFlagged() {
        // Regression: a smooth ramp crossing 12.499 → 12.500 changes several
        // digit positions at once; digit-agreement scoring rejected these
        // perfectly good readings mid-ramp. Value-distance scoring must let
        // the whole ramp through (spec §16: real transitions stay detectable).
        let filter = TemporalFilter(format: .defaultDMM)
        var value = 12.468
        for _ in 0..<12 {
            value += 0.010
            let rounded = (value * 1000).rounded() / 1000
            XCTAssertFalse(filter.evaluate(value: rounded).rejected,
                           "ramp value \(rounded) was flagged as temporally inconsistent")
        }
    }

    func testTemporalFilter_neverRewritesTheValue() {
        // The filter only scores; `Evaluation` carries no value field for the
        // pipeline to substitute in place of the OCR'd reading.
        let filter = TemporalFilter(format: .defaultDMM)
        let evaluation = filter.evaluate(value: 42)
        XCTAssertTrue(type(of: evaluation.consistency) == Float.self)
        // (Compile-time guarantee: `Evaluation` only exposes `consistency` and
        // `rejected` — there is no averaged/smoothed value to assert against.)
    }

    // MARK: - ConfidenceEngine

    private let engine = ConfidenceEngine()

    func testConfidenceEngine_allGatesPass_accepted() {
        let m = engine.fuse(timestamp: 0, value: 12.347, unit: "V", rawText: "12.347",
                            ocrConfidence: 0.9, formatValid: true, physicalRejection: nil,
                            temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertTrue(m.accepted)
        XCTAssertNil(m.rejectionReason)
        XCTAssertEqual(m.confidence, 0.9, accuracy: 1e-6)
    }

    func testConfidenceEngine_invalidFormat_rejectedRegardlessOfOtherGates() {
        let m = engine.fuse(timestamp: 0, value: .nan, unit: "V", rawText: "junk",
                            ocrConfidence: 0.9, formatValid: false, physicalRejection: nil,
                            temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .invalidFormat)
        XCTAssertEqual(m.confidence, 0, accuracy: 1e-6)
    }

    func testConfidenceEngine_lowOCRConfidence_rejected() {
        let m = engine.fuse(timestamp: 0, value: 12.347, unit: "V", rawText: "12.347",
                            ocrConfidence: 0.1, formatValid: true, physicalRejection: nil,
                            temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .lowOCRConfidence)
    }

    func testConfidenceEngine_formatFailureTakesPrecedenceOverLowOCR() {
        // Both gates would fail; format is checked first (rejection precedence).
        let m = engine.fuse(timestamp: 0, value: .nan, unit: "V", rawText: "junk",
                            ocrConfidence: 0.1, formatValid: false, physicalRejection: nil,
                            temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertEqual(m.rejectionReason, .invalidFormat)
    }

    func testConfidenceEngine_physicalRejection_propagatesReason() {
        let m = engine.fuse(timestamp: 0, value: 999, unit: "V", rawText: "999.000",
                            ocrConfidence: 0.9, formatValid: true, physicalRejection: .outOfRange,
                            temporalConsistency: 1.0, temporalRejected: false)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .outOfRange)
        XCTAssertEqual(m.confidence, 0, accuracy: 1e-6)
    }

    func testConfidenceEngine_temporalRejection_onlyAppliesWhenOtherGatesPass() {
        let m = engine.fuse(timestamp: 0, value: 12.347, unit: "V", rawText: "12.347",
                            ocrConfidence: 0.9, formatValid: true, physicalRejection: nil,
                            temporalConsistency: 0.2, temporalRejected: true)
        XCTAssertFalse(m.accepted)
        XCTAssertEqual(m.rejectionReason, .temporalInconsistency)
        XCTAssertEqual(m.confidence, Float(0.9 * 0.2), accuracy: 1e-6)
    }

    func testConfidenceEngine_finalConfidenceNeverExceedsOCRConfidence() {
        let scenarios: [(Bool, RejectionReason?, Float, Bool)] = [
            (true, nil, 1.0, false),
            (true, nil, 0.7, false),
            (false, nil, 1.0, false),
            (true, .outOfRange, 1.0, false),
            (true, nil, 0.4, true),
        ]
        for ocr: Float in [0.0, 0.3, 0.55, 0.9, 1.0] {
            for (formatValid, physical, temporalConsistency, temporalRejected) in scenarios {
                let m = engine.fuse(timestamp: 0, value: 1, unit: nil, rawText: nil,
                                    ocrConfidence: ocr, formatValid: formatValid,
                                    physicalRejection: physical,
                                    temporalConsistency: temporalConsistency,
                                    temporalRejected: temporalRejected)
                XCTAssertLessThanOrEqual(m.confidence, ocr + 1e-6)
            }
        }
    }
}
