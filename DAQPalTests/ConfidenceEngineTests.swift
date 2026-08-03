//
//  ConfidenceEngineTests.swift
//  DAQPalTests
//
//  The FUSED-CONFIDENCE FLOOR (`ConfidenceEngine.minimumFusedConfidence`).
//
//  `ConfidenceEngine.fuse` gates every factor in ISOLATION — format, OCR,
//  decimal, physical, temporal, cross-check — and then multiplies them. Nothing
//  in that ladder ever looks at the PRODUCT, and the cross-check term is applied
//  after the last check runs, so the product can be driven arbitrarily low by a
//  factor that never had to answer to its own gate. The floor is the last word
//  on the product.
//
//  It is a POLICY THRESHOLD, deliberately CHOSEN — 0.15, the product of the OCR
//  gate minimum and one other gate minimum. Properties pinned below:
//
//    * It sits strictly ABOVE `gatePermittedInfimum` (T1). That is the
//      load-bearing property: a floor at or below the infimum refuses nothing,
//      because every gate-passing reading clears it by construction.
//    * It therefore DOES refuse gate-permitted readings, by design (T2, T8).
//    * It is strictly lowest priority — it never relabels an earlier, more
//      specific verdict (T6).
//
//  THIS HEADER PREVIOUSLY SAID THE OPPOSITE, and the correction is the point of
//  the exercise. The first implementation derived the floor as the product of
//  every gate's minimum (0.0375) and called it an invariant assertion. That was
//  internally rigorous and operationally useless: being the infimum of the
//  accepted region, it could not refuse anything in that region, and the case it
//  was written to stop — ocr 0.35 × decimal 0.5 × crossCheck 0.51 ≈ 0.089 —
//  sailed through. The old header even argued no constant could catch it. That
//  argument is wrong: it holds only for a floor CONSTRAINED to refuse nothing
//  legitimate, which is a tautology dressed as a proof. A floor is a policy
//  about how much compounded doubt is too much, and policies are allowed to cost
//  recall. T3 is now the regression guard for that exact leak.
//
//  The cost is measured, not assumed: T8 reports how many of the 360
//  gate-permitted combinations the floor refuses (22.8% at 0.15) rather than
//  asserting it refuses none. Re-check that number against real fixtures.
//

import XCTest
@testable import DAQPal

final class ConfidenceEngineTests: XCTestCase {

    private let engine = ConfidenceEngine()

    /// A fuse call with every gate satisfied, so each test varies only the one
    /// factor it is about. Defaults are deliberately comfortable: ocr 0.9,
    /// neutral temporal/decimal/cross-check.
    private func fuse(ocr: Float = 0.9,
                      formatValid: Bool = true,
                      physical: RejectionReason? = nil,
                      temporalConsistency: Float = 1,
                      temporalRejected: Bool = false,
                      decimal: Float? = nil,
                      crossCheck: CrossCheckOutcome = .notAvailable) -> DAQPal.Measurement {
        let analysis = decimal.map {
            DecimalAnalysis(separatorDetected: true,
                            separatorPosition: 2,
                            fractionDigitCount: 3,
                            confidence: $0)
        }
        return engine.fuse(timestamp: 0, value: 12.345, unit: nil, rawText: "12.345",
                           ocrConfidence: ocr,
                           formatValid: formatValid,
                           physicalRejection: physical,
                           temporalConsistency: temporalConsistency,
                           temporalRejected: temporalRejected,
                           crossCheck: crossCheck,
                           decimal: analysis)
    }

    // MARK: - T1/T2: the floor is a POLICY, and it is not a tautology

    /// The two constants have different jobs and must not be confused again.
    ///
    /// `gatePermittedInfimum` is DERIVED — the product of the gate minima. A
    /// floor placed there refuses nothing, because every gate-passing reading is
    /// above it by construction. That was tried and rejected.
    ///
    /// `minimumFusedConfidence` is CHOSEN. The property that makes it real is the
    /// third assertion: it must sit strictly ABOVE the infimum, or the pipeline
    /// has a floor that can never fire.
    func testFloorIsAPolicyAboveTheDerivedInfimum() {
        let derived = ConfidenceEngine.lowOCRConfidenceThreshold
            * TemporalFilter.consistencyThreshold
            * ConfidenceEngine.decimalVetoThreshold
            * (1 - ConfidenceEngine.crossCheckVetoThreshold)
        XCTAssertEqual(ConfidenceEngine.gatePermittedInfimum, derived,
                       "the infimum must BE the product of the gate minima, not a literal that resembles it")
        XCTAssertEqual(ConfidenceEngine.gatePermittedInfimum, 0.0375, accuracy: 1e-7,
                       "0.3 × 0.5 × 0.5 × 0.5 — if this moved, a gate threshold moved")
        XCTAssertGreaterThan(ConfidenceEngine.minimumFusedConfidence,
                             ConfidenceEngine.gatePermittedInfimum,
                             "THE load-bearing property: a floor at or below the infimum is a no-op that "
                             + "refuses nothing. If this ever fails, the floor has stopped being a constraint.")
        XCTAssertEqual(ConfidenceEngine.minimumFusedConfidence, 0.15, accuracy: 1e-7,
                       "policy value — see the rationale on the constant; change deliberately, not incidentally")
    }

    /// The weakest corner every gate individually permits is now REFUSED, and
    /// that is the entire point of the policy floor.
    ///
    /// Each factor here sits at the weakest value its own gate allows, so every
    /// gate passes in isolation. Their product is `gatePermittedInfimum` —
    /// 0.0375, a reading held up by nothing. Before the policy floor this was
    /// accepted and exported as a measurement.
    func testWeakestGatePermittedCornerIsNowRefused() {
        let weakestDisagreement = ConfidenceEngine.crossCheckVetoThreshold.nextDown
        let m = fuse(ocr: ConfidenceEngine.lowOCRConfidenceThreshold,
                     temporalConsistency: TemporalFilter.consistencyThreshold,
                     decimal: ConfidenceEngine.decimalVetoThreshold,
                     crossCheck: .disagrees(samplerConfidence: weakestDisagreement,
                                            samplerValue: 88.888))
        XCTAssertFalse(m.accepted,
                       "every gate passed in isolation, but the product is \(m.confidence) — refuse it")
        XCTAssertEqual(m.rejectionReason, .lowFusedConfidence)
        XCTAssertLessThan(m.confidence, ConfidenceEngine.minimumFusedConfidence)
    }

    /// The exact case the 2026-08-03 audit published as a live violation of the
    /// product's core promise: ocr 0.35 × decimal 0.50 × cross-check 0.51 =
    /// 0.0892, accepted, because each factor cleared its own gate and nothing
    /// ever judged the product. Three simultaneous warnings, exported as a
    /// measurement. This test is the regression guard for that.
    func testTheDocumentedLeakIsRefused() {
        let m = fuse(ocr: 0.35,
                     decimal: 0.5,
                     crossCheck: .disagrees(samplerConfidence: 0.49, samplerValue: 88.888))
        XCTAssertLessThan(m.confidence, 0.1,
                          "precondition: this is the ~0.089 product the audit documented")
        XCTAssertFalse(m.accepted, "the documented leak must no longer be accepted")
        XCTAssertEqual(m.rejectionReason, .lowFusedConfidence)
    }

    /// The floor must not punish a reading that is merely marginal in ONE
    /// respect — that is what each individual gate is already for. A single
    /// factor at its minimum, with everything else clean, stays accepted.
    func testASingleMarginalFactorIsStillAccepted() {
        let barelyOCR = fuse(ocr: ConfidenceEngine.lowOCRConfidenceThreshold)
        XCTAssertTrue(barelyOCR.accepted,
                      "ocr at its gate minimum alone is 0.30, above the 0.15 floor — accept")

        let barelyDecimal = fuse(ocr: 1.0, decimal: ConfidenceEngine.decimalVetoThreshold)
        XCTAssertTrue(barelyDecimal.accepted,
                      "a marginal decimal alone is 0.50 — accept; the decimal gate already judged it")
    }

    // MARK: - T3: the case the floor exists to catch

    /// An UNGATED factor. `temporalRejected` is false — nothing in the ladder
    /// names a reason — yet the temporal factor drags the product to zero. Before
    /// the floor this was an ACCEPTED reading carrying confidence 0.0000: a
    /// published number with no evidence behind it.
    ///
    /// The confidence must SURVIVE the refusal. It is the evidence for the
    /// refusal, and this project logs rejected readings rather than dropping
    /// them; zeroing it here would also destroy the only signal a developer has
    /// that a factor escaped its gate.
    func testTemporalFactorApproachingZeroWithoutTemporalRejectedIsRefused() {
        let collapsed = fuse(temporalConsistency: 0)
        XCTAssertFalse(collapsed.accepted)
        XCTAssertEqual(collapsed.rejectionReason, .lowFusedConfidence)
        XCTAssertNotEqual(collapsed.rejectionReason, .lowOCRConfidence,
                          "the OCR gate demonstrably passed — naming it would be a false record")
        XCTAssertEqual(collapsed.confidence, 0, accuracy: 1e-7,
                       "the fused confidence is the evidence for the refusal and must survive")

        let nearlyCollapsed = fuse(temporalConsistency: 0.01)
        XCTAssertFalse(nearlyCollapsed.accepted)
        XCTAssertEqual(nearlyCollapsed.rejectionReason, .lowFusedConfidence)
        XCTAssertEqual(nearlyCollapsed.confidence, Float(0.9 * 0.01), accuracy: 1e-6)
    }

    // MARK: - T4: the producer-side contract the floor rests on

    /// The floor is only an invariant because `TemporalFilter` reports a NEUTRAL
    /// 1.0 while its window is too small to judge — i.e. because the score's
    /// domain of validity equals the domain in which `rejected` can fire.
    ///
    /// Without this, start-up frames score ~0 on any genuine step while
    /// `rejected` stays false, and the floor would refuse CORRECT readings at the
    /// beginning of every recording. This test is what stops T3's production path
    /// from silently reopening.
    func testTemporalFilterReportsNeutralUntilItsWindowIsFull() {
        let filter = TemporalFilter(format: .unconstrained)   // fractionDigits 3
        // Deliberate churn: a step of ~43 display units, ~850× the allowance
        // floor (0.001 × stepAllowance 50). If the score were live, these would
        // read 0.0.
        for call in 0..<TemporalFilter.windowSize {
            let evaluation = filter.evaluate(value: call == 0 ? 12.347 : 55.123)
            XCTAssertEqual(evaluation.consistency, 1.0, accuracy: 1e-6,
                           "call \(call): an unjudged window must not depress the fused product")
            XCTAssertFalse(evaluation.rejected, "call \(call)")
        }

        // ...and the filter still judges once the window IS full: neutrality is a
        // domain restriction, not a disabled gate.
        let settled = TemporalFilter(format: .unconstrained)
        for _ in 0..<TemporalFilter.windowSize {
            _ = settled.evaluate(value: 12.347)
        }
        let outlier = settled.evaluate(value: 99.999)
        XCTAssertLessThan(outlier.consistency, TemporalFilter.consistencyThreshold)
        XCTAssertTrue(outlier.rejected)
    }

    // MARK: - T5/T7: placement and boundary

    /// The cross-check multiplies the product AFTER the last gate in the ladder
    /// has run, with nothing re-gating the result. These two calls differ only in
    /// that term, and the verdict flips — which is only possible if the floor is
    /// evaluated after it. Move the guard above the cross-check block and this
    /// fails.
    func testFloorAppliesAfterTheCrossCheckMultiply() {
        // 0.6 × 0.6 × 0.5 = 0.18, above the 0.15 floor.
        let withoutCrossCheck = fuse(ocr: 0.6, temporalConsistency: 0.6, decimal: 0.5)
        XCTAssertTrue(withoutCrossCheck.accepted)
        XCTAssertGreaterThan(withoutCrossCheck.confidence, ConfidenceEngine.minimumFusedConfidence)

        // ...× 0.51 = 0.0918, below it. The disagreement is BELOW the veto
        // threshold, so it does not reject on its own — only the product does.
        // The verdict flips on that term alone, which is possible only if the
        // floor is evaluated AFTER the cross-check block. Move the guard above
        // it and this fails.
        let withWeakDisagreement = fuse(ocr: 0.6, temporalConsistency: 0.6, decimal: 0.5,
                                        crossCheck: .disagrees(samplerConfidence: 0.49,
                                                               samplerValue: 88.888))
        XCTAssertFalse(withWeakDisagreement.accepted)
        XCTAssertEqual(withWeakDisagreement.rejectionReason, .lowFusedConfidence)
        XCTAssertNotEqual(withWeakDisagreement.rejectionReason, .ambiguousDigit,
                          "0.49 is below the veto threshold — the cross-check did not reject, the product did")
    }

    /// Exactly ON the floor is ACCEPTED: the comparison is `<`, not `<=`, which
    /// matches the convention of every other gate in `ConfidenceEngine`. The
    /// arithmetic is exact in Float — 0.5 × 0.5 is a scaling by 2⁻², so this
    /// lands on 0.25 bit-for-bit rather than near it, asserted here rather than
    /// assumed.
    func testFloorIsExclusiveAtTheBoundary() {
        let onTheFloor: Float = ConfidenceEngine.lowOCRConfidenceThreshold
            * ConfidenceEngine.decimalVetoThreshold
        XCTAssertEqual(onTheFloor, ConfidenceEngine.minimumFusedConfidence,
                       "test premise: this product must land exactly on the floor, not near it")

        let m = fuse(ocr: ConfidenceEngine.lowOCRConfidenceThreshold,
                     temporalConsistency: ConfidenceEngine.decimalVetoThreshold)
        XCTAssertEqual(m.confidence, ConfidenceEngine.minimumFusedConfidence)
        XCTAssertTrue(m.accepted, "the guard is `<`: a reading exactly at the floor is not below it")
        XCTAssertNil(m.rejectionReason)
    }

    // MARK: - T6: precedence

    /// The floor is the LOWEST-priority verdict. Every sub-case here drives the
    /// product to zero (temporal factor 0) so the floor would fire — and in every
    /// one, the earlier, more specific reason must win. A record that says
    /// LOW_FUSED_CONFIDENCE when the real answer is OUT_OF_RANGE is a worse
    /// record than one with no floor at all.
    func testFloorNeverOutranksAnEarlierGate() {
        let cases: [(String, DAQPal.Measurement, RejectionReason)] = [
            ("format", fuse(formatValid: false, temporalConsistency: 0), .invalidFormat),
            ("ocr", fuse(ocr: 0.1, temporalConsistency: 0), .lowOCRConfidence),
            ("decimal", fuse(temporalConsistency: 0, decimal: 0.4), .ambiguousDecimal),
            ("physical", fuse(physical: .outOfRange, temporalConsistency: 0), .outOfRange),
            ("temporal", fuse(temporalConsistency: 0, temporalRejected: true), .temporalInconsistency),
            ("crossCheck", fuse(temporalConsistency: 0,
                                crossCheck: .disagrees(samplerConfidence: 0.9,
                                                       samplerValue: 88.888)), .ambiguousDigit),
        ]
        for (label, m, expected) in cases {
            XCTAssertFalse(m.accepted, "\(label)")
            XCTAssertEqual(m.rejectionReason, expected,
                           "\(label): the floor must never relabel a more specific verdict")
        }
    }

    // MARK: - T8: the no-op proof

    /// THE OVER-REFUSAL COST, MEASURED RATHER THAN ASSUMED.
    ///
    /// This test previously asserted the floor refuses NOTHING in the
    /// gate-permitted region. That assertion held only because the floor was the
    /// region's infimum — i.e. it was the executable form of the tautology, and
    /// it passed for the same reason the floor was useless.
    ///
    /// A policy floor MUST refuse some gate-permitted readings; that is what
    /// makes it a policy. So the honest test is not "refuses nothing" but "the
    /// price is known, and readings held up by a genuinely strong signal are
    /// never refused". The printed rate is the number to re-check against DoD-2's
    /// real fixtures when they exist — over-refusal is the risk this value
    /// deliberately accepts (see the constant's rationale).
    func testFloorOverRefusalCostIsBoundedAndReported() {
        let ocrValues: [Float] = [ConfidenceEngine.lowOCRConfidenceThreshold, 0.3001, 0.5, 0.9, 1.0]
        let temporalValues: [Float] = [TemporalFilter.consistencyThreshold, 0.75, 1.0]
        let decimalValues: [Float?] = [nil, ConfidenceEngine.decimalVetoThreshold, 0.75, 0.8, 0.9, 1.0]
        let crossChecks: [CrossCheckOutcome] = [
            .notAvailable,
            .agrees(samplerConfidence: 0.99),
            .disagrees(samplerConfidence: 0.1, samplerValue: 88.888),
            .disagrees(samplerConfidence: 0.49, samplerValue: 88.888),
        ]

        var examined = 0
        var refusedByFloor = 0
        for ocr in ocrValues {
            for temporal in temporalValues {
                for decimal in decimalValues {
                    for crossCheck in crossChecks {
                        let m = fuse(ocr: ocr, temporalConsistency: temporal,
                                     decimal: decimal, crossCheck: crossCheck)
                        let context = "ocr \(ocr) temporal \(temporal) "
                            + "decimal \(decimal.map { "\($0)" } ?? "nil") crossCheck \(crossCheck)"
                        if m.rejectionReason == .lowFusedConfidence {
                            refusedByFloor += 1
                            // NOT asserted: "perfect OCR is never floor-refused".
                            // That guarantee was written here, measured, and found
                            // WRONG — ocr 1.0 with temporal 0.5 and decimal 0.5 is
                            // exactly the dangerous shape (digits certain, magnitude
                            // a coin flip), which is the `.5` power-of-ten class.
                            // The floor SHOULD refuse it. What must hold instead is
                            // that no factor was strong enough to carry the reading
                            // alone: the product is below the floor by definition.
                            XCTAssertLessThan(m.confidence,
                                              ConfidenceEngine.minimumFusedConfidence, context)
                        }
                        examined += 1
                    }
                }
            }
        }
        XCTAssertEqual(examined, 360, "the sweep must actually cover the region it claims to")
        XCTAssertGreaterThan(refusedByFloor, 0,
                             "a floor that refuses nothing in this region is a tautology, not a policy — "
                             + "that was the defect this constant was changed to fix")
        // Reported, not asserted as a threshold: the acceptable rate is a
        // question about REAL optics, and no real fixture exists yet.
        print("ConfidenceEngine floor sweep: \(refusedByFloor)/\(examined) gate-permitted "
              + "combinations refused by minimumFusedConfidence \(ConfidenceEngine.minimumFusedConfidence)")
    }

    // MARK: - T9: the blast-radius table, pinned

    /// Every accepted confidence the rest of the suite asserts, in one place, so
    /// that a future change to the floor breaks HERE — loudly, with its reason
    /// written down — instead of in five unrelated files.
    func testTheSuitesExistingAcceptedConfidencesClearTheFloor() {
        let assertedElsewhere: [(Float, String)] = [
            (0.900, "ValidationPipelineTests:175, SamplerFusionTests:64/:73 — all gates pass"),
            (0.630, "SamplerFusionTests:98 — weak disagreement, the deepest legitimate fuse-level dip"),
            (0.950, "DecimalIntegrityTests:315 — certain separator"),
            (0.570, "DecimalIntegrityTests:316 — 0.95 × 0.6; the suite MINIMUM"),
            (1.000, "SyntheticPipelineTests / GatingTests / SamplerFusionTests via MeasurementProcessor"),
        ]
        for (confidence, origin) in assertedElsewhere {
            XCTAssertGreaterThan(confidence, ConfidenceEngine.minimumFusedConfidence,
                                 "raising the floor past \(confidence) would break: \(origin)")
        }
    }

    // MARK: - T10: end-to-end, both directions

    /// Through the real `MeasurementProcessor`, on the scenario that made all of
    /// the above necessary: a CHANGING value while the temporal window is not yet
    /// full. Two assertions, pointing in OPPOSITE directions, because the floor
    /// can fail in either.
    ///
    ///  1. UNDER-refusal — nothing accepted may carry a confidence the gates
    ///     cannot produce. This is the invariant the floor exists to enforce;
    ///     it also covers any future path that publishes an accepted reading
    ///     without going through `fuse`.
    ///  2. OVER-refusal — a frame whose OCR text IS the rendered text is a
    ///     CORRECT reading, and the floor must never be what refuses it.
    ///     Refusal-over-guessing does not license refusing a number that is
    ///     right.
    ///
    /// (2) is the load-bearing one, and it is not hypothetical. Measured on this
    /// exact script with the floor in place but `TemporalFilter.consistency(of:)`
    /// still scoring a partial window:
    ///
    ///     f0 12.347 -> read "12.347" acc=Y conf=1.0000
    ///     f1 55.123 -> read "55.123" acc=N conf=0.0000 LOW_FUSED_CONFIDENCE  <-- correct, refused
    ///     f2 55.123 -> read "55.123" acc=Y conf=1.0000
    ///
    /// i.e. the floor alone discards up to `windowSize − 1` correct frames at
    /// every value change on a fresh window — the start of every recording. With
    /// the window-domain contract restored, f1 reads acc=Y conf=1.0000, while a
    /// genuine outlier on a FULL window is still rejected as
    /// TEMPORAL_INCONSISTENCY (measured: 99.999 -> acc=N conf=0.3719), so the
    /// temporal gate is narrowed in domain, not weakened.
    ///
    /// Neither assertion demands that any PARTICULAR frame be accepted — Vision
    /// on synthetic renders varies — so the closing `sawAnyAccepted` check keeps
    /// the test from passing vacuously.
    func testCorrectStartupReadingsSurviveAndNothingAcceptedIsBelowTheFloor() async throws {
        let renderer = SyntheticDisplayRenderer()
        let processor = MeasurementProcessor()
        let config = DeviceRecognitionConfig(id: UUID(),
                                             roi: SyntheticDisplayRenderer.displayROI,
                                             format: .unconstrained)
        await processor.update(devices: [config])

        var sawAnyOCRText = false
        var sawAnyAccepted = false
        for (index, text) in ["12.347", "55.123", "55.123", "12.347"].enumerated() {
            guard let buffer = renderer.render(text: text) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer here")
            }
            let frame = TimestampedFrame(pixelBuffer: buffer, timestamp: Double(index) / 12.0)
            guard let m = await processor.process(frame: frame).readings[config.id] else { continue }
            if m.rawText != nil { sawAnyOCRText = true }

            // (2) over-refusal. Scoped to frames Vision read exactly right, so a
            // Vision miss can never masquerade as a floor defect.
            if m.rawText == text {
                XCTAssertNotEqual(m.rejectionReason, .lowFusedConfidence,
                                  "frame \(index) rendered \(text), was READ CORRECTLY as "
                                  + "\(m.rawText ?? "nil"), and was refused by the fused floor at "
                                  + "confidence \(m.confidence) — the floor is discarding correct data")
            }

            // (1) under-refusal.
            if m.accepted {
                sawAnyAccepted = true
                XCTAssertGreaterThanOrEqual(m.confidence, ConfidenceEngine.minimumFusedConfidence,
                                            "frame \(index) (\(text)) was ACCEPTED at confidence "
                                            + "\(m.confidence) — below what the gates can produce, "
                                            + "so some factor was applied without being gated")
            }
        }

        guard sawAnyOCRText else {
            throw XCTSkip("Vision produced no OCR text on synthetic frames in this environment")
        }
        XCTAssertTrue(sawAnyAccepted,
                      "expected at least one accepted reading across the 4-frame script")
    }
}
