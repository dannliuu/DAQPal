//
//  PoseSweepTests.swift
//  DAQPalTests
//
//  The viewing-angle stress sweep: at what yaw / pitch / roll does DAQPal stop
//  working, measured rather than asserted. `DisplayPose3D` supplies both the
//  pose and — through `projectedQuad` — the ground-truth display quadrilateral,
//  and the perspective render path draws the panel onto exactly that quad, so
//  every case has a geometry truth and a reading truth from the same source.
//
//  WHAT EACH CASE MEASURES. Two independent things, deliberately not chained:
//  - GEOMETRY: `ScreenCandidateDetector` runs on the frame and its best-first
//    proposal is scored against the projected quad with `GeometryError`. A
//    fresh detector per case — the detector fuses temporal dwell into its
//    ranking, and a shared one would rank this pose's proposals by stability
//    accumulated on the PREVIOUS pose's panel.
//  - READING: OCR runs over the GROUND-TRUTH quad's bounding box, i.e. with
//    localization handed to it for free. That is what isolates "the glyphs
//    became unreadable at this angle" from "the detector lost the panel at this
//    angle"; chaining them would report one number for two failures.
//
//  HONESTY. The synthetic panel draws a monospaced system font, not seven-
//  segment faces — Apple Vision measures 14.6% on segment glyphs (41.7% dual
//  pass) and near-perfect on this font. The reading curve below therefore
//  bounds the cost of VIEWING ANGLE ALONE on an easy glyph set; it is not a
//  claim about the real instrument, where the glyph face is the dominant term.
//
//  Angles at or beyond the documented envelope (|yaw|, |pitch| ≤ 60°,
//  |roll| ≤ 45°) are swept on purpose. Nothing here asserts a pass rate at the
//  extremes: the deliverable is the curve, printed per axis, plus the machine-
//  readable dump whose path each test logs.
//
//  MEASURED, iOS 26.5 Simulator, DEBUG, `DualPassVisionOCR`, 4 readings/angle:
//  in-envelope every axis reads 100% exactly (yaw ±50°, pitch ±40°, roll ±45°),
//  and the detector proposes a quad on every frame (mean box IoU 0.98 yaw,
//  0.94 pitch, 0.99 roll). The reading only gives out past the envelope —
//  yaw 100% to 70°, 75% at 75°, 0% at 80°; pitch 100% to 65°, 25% at 70°; roll
//  100% all the way to 90°, where the reading is vertical. The detector gives
//  out FIRST and on a different axis: it proposes nothing at all from pitch 65°
//  up, while OCR handed the truth ROI still reads those frames.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class PoseSweepTests: XCTestCase {

    /// One pose to render, in DEGREES — the unit the sweep is specified,
    /// grouped and reported in. Radians appear only inside `pose3D`.
    private struct PoseCase {
        let axis: String
        let yaw: Double
        let pitch: Double
        let roll: Double

        var pose3D: DisplayPose3D {
            var pose = DisplayPose3D.identity
            pose.yaw = CGFloat(yaw) * .pi / 180
            pose.pitch = CGFloat(pitch) * .pi / 180
            pose.roll = CGFloat(roll) * .pi / 180
            return pose
        }
    }

    /// Four readings rather than one, because they fail differently:
    /// `12.345` is the widest, so it foreshortens furthest at a given yaw;
    /// `-20.5` opens with a non-digit glyph; `1250` is the only one for which
    /// `decimalSpurious` is even reachable; `80.8` is the short baseline the
    /// other three are compared against.
    private static let readings = ["80.8", "12.345", "-20.5", "1250"]

    private let renderer = SyntheticDisplayRenderer()
    private let panelSize = CGSize(width: SyntheticDisplayRenderer.displayROI.width,
                                   height: SyntheticDisplayRenderer.displayROI.height)
    private let frameAspect: CGFloat = 1080.0 / 1920.0

    // MARK: - Single-axis sweeps

    func testYawSweep() async throws {
        let angles: [Double] = [-50, -40, -30, -20, -15, -10, -5, 0, 5, 10, 15, 20, 30, 40, 50]
        let cases = angles.map { PoseCase(axis: "yaw", yaw: $0, pitch: 0, roll: 0) }
        let report = await run(sweep: "pose-yaw", cases: cases)
        print(report.summary(groupedBy: "yaw"))
        try emit(report, named: "yaw")

        XCTAssertEqual(report.total, angles.count * Self.readings.count,
                       "the sweep must run to completion, not stop at the first bad angle")
        assertReferencePoseIsAccurate(report)
    }

    func testPitchSweep() async throws {
        let angles: [Double] = [-40, -30, -20, -15, -10, -5, 0, 5, 10, 15, 20, 30, 40]
        let cases = angles.map { PoseCase(axis: "pitch", yaw: 0, pitch: $0, roll: 0) }
        let report = await run(sweep: "pose-pitch", cases: cases)
        print(report.summary(groupedBy: "pitch"))
        try emit(report, named: "pitch")

        XCTAssertEqual(report.total, angles.count * Self.readings.count)
        assertReferencePoseIsAccurate(report)
    }

    func testRollSweep() async throws {
        let angles: [Double] = [-45, -30, -15, -10, -5, 0, 5, 10, 15, 30, 45]
        let cases = angles.map { PoseCase(axis: "roll", yaw: 0, pitch: 0, roll: $0) }
        let report = await run(sweep: "pose-roll", cases: cases)
        print(report.summary(groupedBy: "roll"))
        try emit(report, named: "roll")

        XCTAssertEqual(report.total, angles.count * Self.readings.count)
        assertReferencePoseIsAccurate(report)
    }

    // MARK: - Combined poses

    /// Sampled, not exhaustive: the full cross product of the three axis lists
    /// is 2145 poses, and the axis sweeps above already answer where each axis
    /// alone gives out. What the combinations answer is whether the axes
    /// COMPOUND, which a sample of six per family settles.
    ///
    /// Seed recorded here, in the source, so any failing case replays from its
    /// id alone: `combinedSeed`.
    func testCombinedPoseSweep() async throws {
        var generator = SeededGenerator(seed: Self.combinedSeed)
        var cases: [PoseCase] = []
        for family in ["yaw+pitch", "yaw+roll", "pitch+roll", "yaw+pitch+roll"] {
            for _ in 0..<6 {
                // Drawn inside the documented envelope with margin, so a
                // combined failure is attributable to compounding rather than
                // to one axis already being past its own limit.
                let yaw = family.contains("yaw") ? Double(Int.random(in: -40...40, using: &generator)) : 0
                let pitch = family.contains("pitch") ? Double(Int.random(in: -35...35, using: &generator)) : 0
                let roll = family.contains("roll") ? Double(Int.random(in: -40...40, using: &generator)) : 0
                cases.append(PoseCase(axis: family, yaw: yaw, pitch: pitch, roll: roll))
            }
        }
        let report = await run(sweep: "pose-combined", cases: cases)
        print(report.summary(groupedBy: "axis"))
        try emit(report, named: "combined")

        XCTAssertEqual(report.total, cases.count * Self.readings.count)
    }

    // MARK: - Past the documented envelope

    /// Where the cliff actually is.
    ///
    /// The three sweeps above stay inside (or on the edge of) the documented
    /// envelope and, on this panel, never degrade — every one of their 156
    /// cases reads exactly. A sweep that only ever reports 100% has not found
    /// the limit, so this continues each axis past its documented bound until
    /// the reading collapses, which is the number "at what angle does DAQPal
    /// stop working" actually wants.
    ///
    /// One sign per axis: the in-envelope sweeps measured both, and their rates
    /// were symmetric to the case, so spending the frames on reach rather than
    /// on re-confirming the mirror is the better trade.
    func testBeyondEnvelopeProbe() async throws {
        let axes: [(name: String, angles: [Double], make: (Double) -> PoseCase)] = [
            ("yaw", [55, 60, 65, 70, 75, 80], { PoseCase(axis: "yaw", yaw: $0, pitch: 0, roll: 0) }),
            ("pitch", [45, 50, 55, 60, 65, 70], { PoseCase(axis: "pitch", yaw: 0, pitch: $0, roll: 0) }),
            // Roll runs all the way to 90°, where the reading is fully vertical
            // — the only end-stop on this axis, since a rolled panel loses no
            // resolution the way a foreshortened one does.
            ("roll", [55, 65, 75, 85, 90], { PoseCase(axis: "roll", yaw: 0, pitch: 0, roll: $0) })
        ]
        for axis in axes {
            let report = await run(sweep: "pose-beyond-\(axis.name)", cases: axis.angles.map(axis.make))
            print(report.summary(groupedBy: axis.name))
            try emit(report, named: "beyond-\(axis.name)")
            XCTAssertEqual(report.total, axis.angles.count * Self.readings.count,
                           "the probe must run every out-of-envelope angle, however badly they read")
        }
    }

    /// splitmix64 seed for the combined sample. Fixed forever: changing it
    /// changes which poses are measured and silently invalidates any recorded
    /// comparison against an earlier run.
    private static let combinedSeed: UInt64 = 0xD1CE_5EED_C0_5E3D

    // MARK: - Sweep runner

    private func run(sweep: String, cases: [PoseCase]) async -> ValidationReport {
        let ocr = OCRManager()
        let clock = ContinuousClock()
        var outcomes: [ValidationOutcome] = []
        outcomes.reserveCapacity(cases.count * Self.readings.count)

        for poseCase in cases {
            let pose = poseCase.pose3D
            let truthQuad = pose.projectedQuad(panelSize: panelSize, frameAspect: frameAspect)
            for text in Self.readings {
                guard let buffer = renderer.render(text: text, pose3D: pose) else {
                    XCTFail("perspective render failed for \(poseCase) / \(text)")
                    continue
                }

                let start = clock.now
                // Every pose gets its own detector: see the file header.
                let detector = ScreenCandidateDetector()
                let proposals = await detector.detect(in: TimestampedFrame(pixelBuffer: buffer,
                                                                           timestamp: 0))
                let candidates = (try? await ocr.recognize(in: buffer,
                                                           regionOfInterest: Self.readROI(truthQuad))) ?? []
                // Detection + recognition, excluding the render. A DEBUG
                // number and never a shipping cost — it is here to expose a
                // pose that makes Vision work orders of magnitude harder, and
                // that comparison holds within a run.
                let durationMS = Self.milliseconds(clock.now - start)

                let geometry = proposals.first.flatMap {
                    GeometryError.between(predicted: $0.quad.corners, truth: truthQuad.corners)
                }
                let best = Self.bestReading(candidates)
                let predicted = best.map { Self.normalized($0.text) }
                let angles = "yaw=\(Self.degreeKey(poseCase.yaw)),pitch=\(Self.degreeKey(poseCase.pitch))"
                    + ",roll=\(Self.degreeKey(poseCase.roll))"
                outcomes.append(ValidationOutcome(
                    id: "\(sweep)/\(angles)/\(text)",
                    sweep: sweep,
                    parameters: ["axis": poseCase.axis,
                                 "yaw": Self.degreeKey(poseCase.yaw),
                                 "pitch": Self.degreeKey(poseCase.pitch),
                                 "roll": Self.degreeKey(poseCase.roll),
                                 "text": text],
                    truth: text,
                    predicted: predicted,
                    verdict: ReadingComparison.verdict(truth: text, predicted: predicted),
                    geometry: geometry,
                    confidence: best?.confidence ?? 0,
                    durationMS: durationMS))
            }
        }

        let report = ValidationReport(sweep: sweep, outcomes: outcomes)
        // Not part of `ValidationReport` because it is a detector-liveness
        // count, not a reading metric: `meanIoU` averages only over the cases
        // where a proposal existed at all, so it alone cannot say how often the
        // detector proposed nothing.
        let proposed = report.outcomes.filter { $0.geometry != nil }.count
        print("  quad proposed    \(proposed)/\(report.total)")
        return report
    }

    // MARK: - Case plumbing

    /// The ROI recognition is given: the truth quad's bounding box with a
    /// one-percent margin. Vision's `regionOfInterest` crops hard, and a box
    /// that ends exactly on the panel edge shaves the outer glyph's stroke on
    /// the near side of a keystone — an artifact of the measurement, not of the
    /// pose.
    private static func readROI(_ quad: ScreenQuad) -> NormalizedROI {
        let box = quad.boundingBox
        return NormalizedROI(x: box.x - 0.01, y: box.y - 0.01,
                             width: box.width + 0.02, height: box.height + 0.02).clamped()
    }

    /// Highest-confidence hypothesis that contains a digit, falling back to the
    /// plain highest-confidence one. Without the digit preference a stray
    /// observation of the instrument body would be scored as the reading and
    /// charged to the pose.
    private static func bestReading(_ candidates: [OCRCandidate]) -> OCRCandidate? {
        let numeric = candidates.filter { $0.text.contains(where: \.isNumber) }
        let pool = numeric.isEmpty ? candidates : numeric
        return pool.max { $0.confidence < $1.confidence }
    }

    /// Strips ALL whitespace and folds the Unicode dashes Vision returns for a
    /// minus sign onto ASCII `-`.
    ///
    /// Whitespace goes because `FormatValidator` already removes it as step 1
    /// of parsing ("OCR inserts stray spaces") — measured here at pitch 60–65°,
    /// where Vision returns `80. 8`. Scoring that as a digit error would charge
    /// the pose for a defect the pipeline never sees. Nothing else is touched:
    /// in particular `FormatValidator.normalizeConfusables` is NOT applied, so
    /// an `O`-for-`0` substitution stays a digit error here — the value of a
    /// repair stage belongs to a sweep of that stage, not to this one.
    private static func normalized(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar -> Character? in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            switch scalar {
            case "\u{2212}", "\u{2013}", "\u{2014}": return "-"
            default: return Character(scalar)
            }
        })
    }

    /// Grouping key for an angle. Every swept angle is a whole degree, so the
    /// key is the rounded integer: `-0` and `0` cannot become separate rows,
    /// and the report's numeric sort orders the curve from −50 to +50.
    private static func degreeKey(_ degrees: Double) -> String {
        "\(Int(degrees.rounded()))"
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) * 1e-15
    }

    // MARK: - Assertions and output

    /// The only accuracy claim any of these tests makes: the head-on reference
    /// pose reads correctly. Every off-axis rate is measured and printed, never
    /// asserted — an assertion there would either be trivially true or would
    /// have to be weakened the moment the curve moved, and the curve is the
    /// point.
    private func assertReferencePoseIsAccurate(_ report: ValidationReport,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) {
        let zero = report.outcomes.filter {
            $0.parameters["yaw"] == "0" && $0.parameters["pitch"] == "0" && $0.parameters["roll"] == "0"
        }
        XCTAssertFalse(zero.isEmpty, "every axis sweep must include the 0° reference pose",
                       file: file, line: line)
        // 4/4 measured on all three axes; the floor sits one reading below
        // that, because a suite that fails on a single Vision revision's
        // handling of one string reports a toolchain change as a regression.
        let exact = Double(zero.filter { $0.verdict.isCorrect }.count) / Double(max(zero.count, 1))
        XCTAssertGreaterThanOrEqual(exact, 0.75,
                                    "head-on, undegraded panel must read: \(zero.map { "\($0.truth)->\($0.predicted ?? "nil")" })",
                                    file: file, line: line)
    }

    private func emit(_ report: ValidationReport, named name: String) throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("daqpal-pose-sweep-\(name).jsonl")
        try report.jsonLines().write(to: url, atomically: true, encoding: .utf8)
        print("  jsonl           \(url.path)")
    }
}
