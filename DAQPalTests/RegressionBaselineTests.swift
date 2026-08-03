//
//  RegressionBaselineTests.swift
//  DAQPalTests
//
//  Tests for the regression checker itself. Everything here is built from
//  hand-written `ValidationOutcome` values rather than by running a sweep: the
//  question is whether the checker fires when it should and stays quiet when it
//  should not, and answering that with real OCR would make the answer depend on
//  the thing being guarded.
//
//  The properties that matter, and why:
//    - a baseline must re-serialize byte-identically, or committed files churn
//      and stop being read;
//    - an improvement must not fail, or people learn to re-record reflexively;
//    - a drop inside tolerance must not fail, for the same reason;
//    - a drop past tolerance must fail and must NAME the metric, because
//      "regression detected" without a metric sends someone reading diffs;
//    - latency must be graded far more loosely than accuracy, because it is
//      measured in Debug on a shared machine.
//

// The checker and the harness both live in the test target, so nothing here
// reaches into the app module.

import CoreGraphics
import XCTest

final class RegressionBaselineTests: XCTestCase {

    // MARK: - Fixtures

    private func outcome(_ verdict: ReadingVerdict,
                         index: Int,
                         iou: CGFloat?,
                         durationMS: Double) -> ValidationOutcome {
        ValidationOutcome(
            id: "unit/\(index)",
            sweep: "unit",
            parameters: ["case": "\(index)"],
            truth: "80.8",
            predicted: verdict == .notDetected ? nil : "80.8",
            verdict: verdict,
            geometry: iou.map { GeometryError(iou: $0, meanCornerError: 0, maxCornerError: 0, centerError: 0) },
            confidence: 0.9,
            durationMS: durationMS)
    }

    /// Builds a report with an exact verdict census, so every metric the
    /// baseline derives has a value computable by hand.
    private func report(_ census: [(ReadingVerdict, Int)],
                        iou: CGFloat? = nil,
                        durationMS: Double = 10) -> ValidationReport {
        var outcomes: [ValidationOutcome] = []
        for (verdict, count) in census {
            for _ in 0..<count {
                outcomes.append(outcome(verdict, index: outcomes.count, iou: iou, durationMS: durationMS))
            }
        }
        return ValidationReport(sweep: "unit", outcomes: outcomes)
    }

    private func baseline(name: String = "unit",
                          cases: Int = 200,
                          exact: Double = 0.987,
                          digits: Double = 0.994,
                          decimals: Double = 0.968,
                          detection: Double = 1.0,
                          iou: Double? = 0.912,
                          latencyMS: Double = 41.2) -> RegressionBaseline {
        RegressionBaseline(name: name,
                           caseCount: cases,
                           exactRate: exact,
                           digitAccuracy: digits,
                           decimalAccuracy: decimals,
                           detectionRate: detection,
                           meanIoU: iou,
                           p95LatencyMS: latencyMS)
    }

    private func temporaryStore(_ testName: String = #function) throws -> BaselineStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DAQPalBaselineTests", isDirectory: true)
            .appendingPathComponent(testName.replacingOccurrences(of: "()", with: ""), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return BaselineStore(directory: directory)
    }

    // MARK: - Serialization

    func testBaselineRoundTripsByteIdentically() throws {
        let original = baseline(name: "pose-sweep")
        let text = original.serialized()
        let parsed = try RegressionBaseline(serialized: text)
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.serialized(), text)
    }

    func testRoundTripSurvivesValuesThatDoNotPrintExactly() throws {
        // 1/3 and 1/7 have no finite decimal form; the file must still be a
        // fixed point of parse-then-serialize.
        let original = baseline(exact: 1.0 / 3.0,
                                digits: 1.0 / 7.0,
                                decimals: 2.0 / 3.0,
                                iou: 1.0 / 9.0,
                                latencyMS: 100.0 / 3.0)
        let text = original.serialized()
        let parsed = try RegressionBaseline(serialized: text)
        XCTAssertEqual(parsed.serialized(), text)
        XCTAssertEqual(parsed.exactRate, 1.0 / 3.0, accuracy: 1e-6)
    }

    func testAbsentIoURoundTripsAsNoneRatherThanZero() throws {
        let original = baseline(iou: nil)
        let text = original.serialized()
        XCTAssertTrue(text.contains("meanIoU: none"), text)
        let parsed = try RegressionBaseline(serialized: text)
        XCTAssertNil(parsed.meanIoU)
        XCTAssertEqual(parsed.serialized(), text)
    }

    func testSerializedKeyOrderIsFixed() {
        let text = baseline().serialized()
        let keys = text.split(separator: "\n")
            .filter { !$0.hasPrefix("#") }
            .compactMap { $0.split(separator: ":").first.map(String.init) }
        XCTAssertEqual(keys, ["format", "name", "cases"] + BaselineMetric.allCases.map(\.rawValue))
    }

    func testRateFieldsCarrySixDecimalsAndLatencyThree() {
        let text = baseline(exact: 0.5, latencyMS: 12.5).serialized()
        XCTAssertTrue(text.contains("exactRate: 0.500000"), text)
        XCTAssertTrue(text.contains("p95LatencyMS: 12.500"), text)
    }

    func testUnsupportedFormatVersionThrows() {
        let text = baseline().serialized().replacingOccurrences(of: "format: 1", with: "format: 99")
        XCTAssertThrowsError(try RegressionBaseline(serialized: text)) { error in
            XCTAssertEqual(error as? BaselineFormatError, .unsupportedVersion(99))
        }
    }

    func testMissingFieldThrows() {
        let text = baseline().serialized()
            .split(separator: "\n")
            .filter { !$0.hasPrefix("detectionRate") }
            .joined(separator: "\n")
        XCTAssertThrowsError(try RegressionBaseline(serialized: text)) { error in
            XCTAssertEqual(error as? BaselineFormatError, .missingField("detectionRate"))
        }
    }

    func testNonNumericValueThrows() {
        let text = baseline().serialized()
            .replacingOccurrences(of: "exactRate: 0.987000", with: "exactRate: pretty good")
        XCTAssertThrowsError(try RegressionBaseline(serialized: text)) { error in
            XCTAssertEqual(error as? BaselineFormatError, .malformedLine("exactRate: pretty good"))
        }
    }

    // MARK: - Derivation from a report

    func testMetricsDerivedFromReportCensus() {
        // 10 cases: 6 exact, 1 missing decimal, 1 misplaced decimal,
        // 1 digit error, 1 not detected.
        let snapshot = RegressionBaseline(name: "unit", report: report([
            (.exact, 6), (.decimalMissing, 1), (.decimalMisplaced, 1),
            (.digitError, 1), (.notDetected, 1),
        ], iou: 0.8))
        XCTAssertEqual(snapshot.caseCount, 10)
        XCTAssertEqual(snapshot.exactRate, 0.6, accuracy: 1e-9)
        XCTAssertEqual(snapshot.detectionRate, 0.9, accuracy: 1e-9)
        // 8 of the 9 detected readings had every digit right.
        XCTAssertEqual(snapshot.digitAccuracy, 8.0 / 9.0, accuracy: 1e-9)
        // Of those 8 digit-correct readings, 6 also placed the point.
        XCTAssertEqual(snapshot.decimalAccuracy, 6.0 / 8.0, accuracy: 1e-9)
        XCTAssertEqual(snapshot.meanIoU ?? -1, 0.8, accuracy: 1e-9)
    }

    func testDecimalAccuracyIsIndependentOfDigitErrors() {
        // Same decimal behaviour, wildly different digit accuracy. If decimal
        // accuracy were measured over all cases, the second snapshot would look
        // like a decimal regression when only glyph recognition moved.
        let clean = RegressionBaseline(name: "unit", report: report([
            (.exact, 8), (.decimalMissing, 2),
        ]))
        let digitsBroken = RegressionBaseline(name: "unit", report: report([
            (.exact, 8), (.decimalMissing, 2), (.digitError, 10),
        ]))
        XCTAssertEqual(clean.decimalAccuracy, 0.8, accuracy: 1e-9)
        XCTAssertEqual(digitsBroken.decimalAccuracy, 0.8, accuracy: 1e-9)
        XCTAssertLessThan(digitsBroken.digitAccuracy, clean.digitAccuracy)
    }

    func testGeometryFreeSweepRecordsNoIoURatherThanZero() {
        let snapshot = RegressionBaseline(name: "unit", report: report([(.exact, 4)], iou: nil))
        XCTAssertNil(snapshot.meanIoU)
    }

    // MARK: - Comparison

    func testImprovementIsNotARegression() {
        let recorded = baseline()
        let improved = baseline(exact: 0.996, digits: 0.999, decimals: 0.991,
                                detection: 1.0, iou: 0.94, latencyMS: 30)
        let verdict = RegressionCheck.run(baseline: recorded, current: improved)
        XCTAssertFalse(verdict.hasRegression, verdict.report())
        XCTAssertTrue(verdict.report().contains("NO REGRESSION"))
    }

    func testDropWithinToleranceIsNotARegression() {
        // Two cases out of 200 flipping is 1.0%, inside the 2% accuracy band.
        let recorded = baseline(exact: 0.987)
        let wobbled = baseline(exact: 0.977)
        XCTAssertFalse(RegressionCheck.run(baseline: recorded, current: wobbled).hasRegression)
    }

    func testSingleCaseFlipInA200CaseSweepIsNotARegression() {
        let recorded = RegressionBaseline(name: "unit", report: report([(.exact, 200)]))
        let flipped = RegressionBaseline(name: "unit", report: report([(.exact, 199), (.digitError, 1)]))
        let verdict = RegressionCheck.run(baseline: recorded, current: flipped)
        XCTAssertFalse(verdict.hasRegression, verdict.report())
    }

    func testDropBeyondToleranceIsARegression() {
        let recorded = baseline(exact: 0.987)
        let broken = baseline(exact: 0.940)
        let verdict = RegressionCheck.run(baseline: recorded, current: broken)
        XCTAssertTrue(verdict.hasRegression)
        XCTAssertTrue(verdict.regressed(.exactRate))
    }

    func testToleranceBoundaryIsInclusive() {
        // Exactly at the tolerance passes; a hair below fails. Pinned so the
        // comparison cannot be quietly loosened to `<=`.
        let recorded = baseline(exact: 0.900)
        XCTAssertFalse(RegressionCheck.run(baseline: recorded, current: baseline(exact: 0.880)).hasRegression)
        XCTAssertTrue(RegressionCheck.run(baseline: recorded, current: baseline(exact: 0.8799)).hasRegression)
    }

    func testDetectionIsHeldTighterThanRecognition() {
        let thresholds = RegressionThresholds.default
        XCTAssertLessThan(thresholds.detectionDrop, thresholds.accuracyDrop)
        // A 1.5% drop clears the accuracy band but not the detection band.
        let recorded = baseline(exact: 0.95, detection: 0.95)
        let current = baseline(exact: 0.935, detection: 0.935)
        let verdict = RegressionCheck.run(baseline: recorded, current: current)
        XCTAssertFalse(verdict.regressed(.exactRate))
        XCTAssertTrue(verdict.regressed(.detectionRate))
    }

    func testEveryRegressedMetricIsListedNotJustTheFirst() {
        let recorded = baseline(exact: 0.99, digits: 0.99, decimals: 0.99, detection: 0.99, iou: 0.9)
        let current = baseline(exact: 0.90, digits: 0.90, decimals: 0.90, detection: 0.90, iou: 0.80)
        let verdict = RegressionCheck.run(baseline: recorded, current: current)
        XCTAssertEqual(verdict.regressions.map(\.metric),
                       [.exactRate, .digitAccuracy, .decimalAccuracy, .detectionRate, .meanIoU])
    }

    func testDroppingAMetricTheBaselinePinnedIsARegression() {
        let recorded = baseline(iou: 0.912)
        let current = baseline(iou: nil)
        let verdict = RegressionCheck.run(baseline: recorded, current: current)
        XCTAssertTrue(verdict.regressed(.meanIoU))
        XCTAssertTrue(verdict.report().contains("Mean IoU: baseline 91.2% -> current not measured"),
                      verdict.report())
    }

    func testMetricAbsentFromBaselineIsNotChecked() {
        let verdict = RegressionCheck.run(baseline: baseline(iou: nil), current: baseline(iou: 0.4))
        XCTAssertFalse(verdict.regressed(.meanIoU))
    }

    // MARK: - Latency

    func testLatencyToleranceIsLooserThanAccuracyTolerance() {
        let thresholds = RegressionThresholds.default
        let accuracySlack = thresholds.relativeTolerance(for: .exactRate, baseline: 0.90)
        let latencySlack = thresholds.relativeTolerance(for: .p95LatencyMS, baseline: 40)
        XCTAssertGreaterThan(latencySlack, accuracySlack * 10,
                             "latency runs in Debug on a shared machine; its band must dwarf accuracy's")
    }

    func testSameRelativeDegradationFailsAccuracyButNotLatency() {
        // 20% worse on both axes. Accuracy at 20% relative is a real defect;
        // latency at 20% is a busy build machine.
        let recorded = baseline(exact: 0.90, latencyMS: 40)
        let degraded = baseline(exact: 0.90 * 0.8, latencyMS: 40 * 1.2)
        let verdict = RegressionCheck.run(baseline: recorded, current: degraded)
        XCTAssertTrue(verdict.regressed(.exactRate))
        XCTAssertFalse(verdict.regressed(.p95LatencyMS), verdict.report())
    }

    func testLatencyBeyondGrowthFactorIsARegression() {
        let verdict = RegressionCheck.run(baseline: baseline(latencyMS: 40),
                                          current: baseline(latencyMS: 61))
        XCTAssertTrue(verdict.regressed(.p95LatencyMS))
        XCTAssertTrue(verdict.report().contains("p95 latency: baseline 40.0 ms -> current 61.0 ms"),
                      verdict.report())
    }

    func testSubMillisecondLatencyIsNotJudgedByRatioAlone() {
        // 0.4 ms -> 0.7 ms is 1.75x and is timer granularity, not a change.
        let verdict = RegressionCheck.run(baseline: baseline(latencyMS: 0.4),
                                          current: baseline(latencyMS: 0.7))
        XCTAssertFalse(verdict.regressed(.p95LatencyMS))
    }

    func testFasterIsNeverALatencyRegression() {
        let verdict = RegressionCheck.run(baseline: baseline(latencyMS: 40),
                                          current: baseline(latencyMS: 4))
        XCTAssertFalse(verdict.hasRegression)
    }

    // MARK: - Threshold configuration

    func testThresholdsAreConfigurablePerMetric() {
        var strict = RegressionThresholds.default
        strict.accuracyDrop = 0.001
        let recorded = baseline(exact: 0.987)
        let wobbled = baseline(exact: 0.982)
        XCTAssertFalse(RegressionCheck.run(baseline: recorded, current: wobbled).hasRegression)
        XCTAssertTrue(RegressionCheck.run(baseline: recorded, current: wobbled, thresholds: strict).hasRegression)
    }

    func testCorpusScaledToleranceWidensForSmallSweeps() {
        let small = RegressionThresholds.forCorpus(size: 40)
        XCTAssertEqual(small.accuracyDrop, 0.1, accuracy: 1e-9)   // 4 cases in 40
        // A large corpus keeps the documented floor rather than demanding
        // stability finer than the tie-break noise the floor exists to absorb.
        let large = RegressionThresholds.forCorpus(size: 1000)
        XCTAssertEqual(large.accuracyDrop, RegressionThresholds.default.accuracyDrop, accuracy: 1e-9)
    }

    func testDefaultAccuracyToleranceExceedsSingleCaseResolutionAt200() {
        XCTAssertGreaterThan(RegressionThresholds.default.accuracyDrop, 1.0 / 200.0)
    }

    // MARK: - Report text

    func testReportNamesTheSpecificMetricThatRegressed() {
        let recorded = baseline(exact: 0.987, decimals: 0.968)
        let current = baseline(exact: 0.971, decimals: 0.882)
        let text = RegressionCheck.run(baseline: recorded, current: current).report()
        XCTAssertTrue(text.contains("Baseline OCR accuracy: 98.7%"), text)
        XCTAssertTrue(text.contains("Current  OCR accuracy: 97.1%"), text)
        XCTAssertTrue(text.contains("REGRESSION DETECTED"), text)
        XCTAssertTrue(text.contains("Decimal accuracy: baseline 96.8% -> current 88.2%"), text)
        // The headline accuracy moved 1.6%, inside tolerance, so it must NOT be
        // listed as a regression even though it is printed at the top.
        XCTAssertFalse(text.contains("OCR accuracy: baseline"), text)
    }

    func testReportPointsAtTheUpdatePath() {
        let text = RegressionCheck.run(baseline: baseline(name: "pose-sweep", exact: 0.99),
                                       current: baseline(name: "pose-sweep", exact: 0.5)).report()
        XCTAssertTrue(text.contains("DAQPAL_RECORD_BASELINE=pose-sweep"), text)
    }

    func testReportCallsOutAChangedCorpusSize() {
        let text = RegressionCheck.run(baseline: baseline(cases: 200, exact: 0.99),
                                       current: baseline(cases: 120, exact: 0.5)).report()
        XCTAssertTrue(text.contains("Corpus size changed: 200 -> 120 cases"), text)
    }

    func testCleanReportDoesNotSayRegression() {
        let text = RegressionCheck.run(baseline: baseline(), current: baseline()).report()
        XCTAssertFalse(text.contains("REGRESSION DETECTED"), text)
    }

    // MARK: - Storage

    func testRecordedFixtureOnDiskParsesAndReSerializesByteIdentically() throws {
        let store = BaselineStore()
        let url = try store.fileURL(for: "selftest-fixture")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        let parsed = try store.load("selftest-fixture")
        XCTAssertEqual(parsed.caseCount, 200)
        XCTAssertEqual(parsed.exactRate, 0.987, accuracy: 1e-9)
        XCTAssertEqual(parsed.serialized(), onDisk,
                       "a committed baseline must be a fixed point of the writer, or every run diffs")
    }

    func testLoadingAnUnrecordedBaselineReportsItAsMissing() {
        let store = BaselineStore()
        XCTAssertThrowsError(try store.load("no-such-sweep")) { error in
            XCTAssertEqual(error as? BaselineFormatError, .notRecorded("no-such-sweep"))
        }
    }

    func testNamesThatWouldEscapeTheDirectoryAreRejected() {
        let store = BaselineStore()
        for name in ["../secrets", "a/b", "", "with space", "sweep.baseline"] {
            XCTAssertThrowsError(try store.fileURL(for: name), name) { error in
                XCTAssertEqual(error as? BaselineFormatError, .invalidName(name))
            }
        }
    }

    func testRecordWritesAFileThatLoadsBackIdentically() throws {
        let store = try temporaryStore()
        let snapshot = baseline(name: "pose-sweep")
        let authorization = try XCTUnwrap(BaselineRecording.authorization(
            for: "pose-sweep", environment: [BaselineRecording.environmentKey: "pose-sweep"]))
        let url = try store.record(snapshot, authorization: authorization)
        XCTAssertEqual(url.lastPathComponent, "pose-sweep.baseline")
        XCTAssertTrue(store.exists("pose-sweep"))
        XCTAssertEqual(try store.load("pose-sweep"), snapshot)
    }

    // MARK: - The update path

    func testRecordingIsRefusedWithoutTheEnvironmentVariable() {
        XCTAssertNil(BaselineRecording.authorization(for: "pose-sweep", environment: [:]))
    }

    func testRecordingIsRefusedForABlanketWildcard() {
        // A global switch would let one distracted run rewrite every recorded
        // number, so it must not be discoverable by trying the obvious values.
        for wildcard in ["1", "true", "yes", "all", "*", "ON"] {
            XCTAssertNil(BaselineRecording.authorization(
                for: "pose-sweep", environment: [BaselineRecording.environmentKey: wildcard]),
                         wildcard)
        }
    }

    func testRecordingIsRefusedForADifferentBaseline() {
        XCTAssertNil(BaselineRecording.authorization(
            for: "pose-sweep", environment: [BaselineRecording.environmentKey: "degradation-sweep"]))
    }

    func testAuthorizationDoesNotTransferToAnotherBaseline() throws {
        let store = try temporaryStore()
        let authorization = try XCTUnwrap(BaselineRecording.authorization(
            for: "pose-sweep", environment: [BaselineRecording.environmentKey: "pose-sweep"]))
        XCTAssertThrowsError(try store.record(baseline(name: "degradation-sweep"),
                                              authorization: authorization)) { error in
            XCTAssertEqual(error as? BaselineFormatError, .recordingNotAuthorized("degradation-sweep"))
        }
    }

    func testInstructionsNameTheFileToCommit() {
        let text = BaselineRecording.instructions(for: "pose-sweep")
        XCTAssertTrue(text.contains("DAQPAL_RECORD_BASELINE=pose-sweep"), text)
        XCTAssertTrue(text.contains("DAQPalTests/Baselines/pose-sweep.baseline"), text)
    }

    /// Recording is opt-in per run, so this is a no-op unless the environment
    /// names a baseline. It is the seam sweeps call once they have a corpus:
    /// with the variable set it rewrites the file, without it the run just
    /// checks. Kept honest by asserting the refusal, which is the branch that
    /// runs in CI.
    func testRecordingSeamIsInertInAnOrdinaryRun() {
        let requested = ProcessInfo.processInfo.environment[BaselineRecording.environmentKey]
        guard requested == "selftest-fixture" else {
            XCTAssertNil(BaselineRecording.authorization(for: "selftest-fixture"))
            return
        }
        XCTAssertNotNil(BaselineRecording.authorization(for: "selftest-fixture"))
    }
}
