//
//  DecimalBenchmarkTests.swift
//  DAQPalTests
//
//  Phase 3 — the DECIMAL benchmark for the incumbent engine (Apple Vision via
//  `OCRManager` → `DualPassVisionOCR`).
//
//  WHY THIS EXISTS, separately from `OCRBenchmarkTests`
//  ---------------------------------------------------
//  `OCRBenchmarkTests` measures "did the engine read the right number". That
//  metric is blind to the failure this project actually cares about (spec §11A):
//  a temperature gun showing `80.8` read as `808` is a WELL-FORMED number that
//  is wrong by 10x. It parses, it passes range checks, and a consistently
//  shifted series looks perfectly stable to the temporal filter. So this class
//  scores the SEPARATOR as a first-class quantity:
//
//    * decimal-preservation rate — a separator was recovered AND placed at the
//      correct position (digits-before-separator, `DisplayFormat`'s convention);
//    * power-of-ten error rate — how often the value the pipeline would ACCEPT
//      is 10^k off ground truth for some k ≠ 0. THIS IS THE HEADLINE METRIC:
//      it counts silent 10x errors, the only failure mode that is both
//      undetectable downstream and materially wrong.
//
//  A refusal is NOT a power-of-ten error. `FormatValidator` raising
//  `.ambiguousDecimal` (or returning no reading at all) is counted in its own
//  bucket, because refusing to guess is the correct behavior — never coerce.
//
//  IMAGERY / HONESTY
//  -----------------
//  Every frame is rendered by the app-target `SyntheticDisplayRenderer`: an
//  LCD-ish panel with monospaced digits on a near-black body. It is a stand-in
//  for a physical display, NOT a model of one (no segment gaps, no glare, no
//  viewing-angle response). Degradation comes from `RenderDegradation`
//  (brightness / motion blur / sensor noise / occlusion) and geometry from
//  `DisplayPose` (yaw + pitch foreshortening, roll, apparent scale). Every one
//  of those is a deterministic pure function of its inputs — no `Date()`, no
//  RNG — so the corpus replays byte-identically.
//
//  Therefore: these numbers describe the incumbent engine on a SYNTHETIC
//  distribution. They are not a real-instrument accuracy claim, and no held-out
//  human-labeled eval set exists yet that would license one.
//
//  ASSERTIONS
//  ----------
//  Structural only (every case produced a result; every engine call took
//  measurable time; ground truth for every label is parseable). No accuracy or
//  latency threshold is asserted — the numbers are whatever they measure. If
//  Vision reads no text at all in this environment the test SKIPS rather than
//  reporting a fabricated 0%.
//
//  CI
//  --
//  SLOW (a full Vision `.accurate` pass per case). Like `OCRBenchmarkTests`,
//  this class is excluded from the default sweep at the invocation level:
//
//      xcodebuild test ... -skip-testing:DAQPalTests/DecimalBenchmarkTests
//
//  Run it deliberately with `-only-testing:DAQPalTests/DecimalBenchmarkTests`.
//

import CoreGraphics
import CoreVideo
import Foundation
import UIKit
import XCTest
@testable import DAQPal

final class DecimalBenchmarkTests: XCTestCase {

    // MARK: - Corpus definition

    /// The labels. `80.8` / `808` are the spec's motivating pair; the rest
    /// spread the separator across every position it can occupy: leading-none
    /// (`.5`), one/two/three integer digits, one/two/three fraction digits,
    /// significant trailing zeros (`100.0`, `1.000`), a magnitude far below 1
    /// (`0.001`), and a signed value (`-1.25`).
    private static let labels = ["80.8", "808", "12.345", "0.001", "99.9",
                                 "-1.25", ".5", "100.0", "1.000"]

    /// Render size = `SyntheticFrameSource`'s shipping default, so the measured
    /// per-frame latency is representative of what the app hands Vision.
    private static let renderSize = CGSize(width: 1080, height: 1920)

    private enum VariantGroup: String, CaseIterable {
        case clean
        case degraded
        case posed
    }

    private struct Variant {
        let name: String
        let group: VariantGroup
        let pose: DisplayPose
        let degradation: RenderDegradation
    }

    /// clean + 4 degradations + 3 poses = 8 variants per label.
    private static let variants: [Variant] = {
        func radians(_ degrees: CGFloat) -> CGFloat { degrees * .pi / 180 }
        let home = DisplayPose.identity
        return [
            Variant(name: "clean", group: .clean, pose: home, degradation: .none),

            // Panel luminance halved: the glyph/background separation collapses
            // toward the noise floor — the classic dim-LCD case.
            Variant(name: "low-contrast", group: .degraded, pose: home,
                    degradation: RenderDegradation(brightness: 0.5)),
            // Motion blur: the separator is the first thing a blur kernel eats.
            Variant(name: "blur", group: .degraded, pose: home,
                    degradation: RenderDegradation(blurRadius: 10)),
            // Sensor noise at a level where a lone decimal dot and a hot pixel
            // become hard to tell apart.
            Variant(name: "noise", group: .degraded, pose: home,
                    degradation: RenderDegradation(noiseAmount: 0.35)),
            // A hand/probe across the bottom 30% of the panel — where the
            // decimal point sits on a baseline-aligned display.
            Variant(name: "occlusion", group: .degraded, pose: home,
                    degradation: RenderDegradation(occlusion: 0.30)),

            // Perspective: horizontal foreshortening squeezes inter-glyph gaps,
            // which is exactly the space a decimal point occupies.
            Variant(name: "yaw-35deg", group: .posed,
                    pose: DisplayPose(center: DemoMotionModel.homeCenter, roll: 0,
                                      yawScale: cos(radians(35)), pitchScale: 1, scale: 1),
                    degradation: .none),
            Variant(name: "yaw-55deg", group: .posed,
                    pose: DisplayPose(center: DemoMotionModel.homeCenter, roll: 0,
                                      yawScale: cos(radians(55)), pitchScale: 1, scale: 1),
                    degradation: .none),
            // Roll + pitch + shrink: fewer pixels per glyph, so the separator
            // approaches the resampling floor.
            Variant(name: "roll8-pitch35-scale0.6", group: .posed,
                    pose: DisplayPose(center: DemoMotionModel.homeCenter, roll: radians(8),
                                      yawScale: 1, pitchScale: cos(radians(35)), scale: 0.6),
                    degradation: .none)
        ]
    }()

    // MARK: - Scoring types

    /// What the pipeline would have DONE with this frame.
    private enum Outcome: String {
        /// A reading was accepted and its value matches ground truth.
        case correct
        /// A reading was accepted whose magnitude is 10^k off, k ≠ 0. The
        /// silent-10x failure — the metric that matters most.
        case powerOfTenError
        /// A reading was accepted and is wrong in some other way (digit errors).
        case otherWrong
        /// The separator could not be resolved; `.ambiguousDecimal` was raised.
        /// Correct behavior — a refusal, not an error.
        case refusedAmbiguousDecimal
        /// The engine returned candidates but none parsed to a number.
        case noParseableReading
        /// The engine returned nothing at all for this frame.
        case noCandidates
    }

    private struct CaseResult {
        let label: String
        let variant: String
        let group: VariantGroup
        let topText: String?
        let candidateCount: Int
        let acceptedValue: Double?
        let acceptedText: String?
        let outcome: Outcome
        /// Separator present-or-absent AND positioned as ground truth requires.
        /// False whenever nothing was accepted (a refusal preserves nothing —
        /// it just does no harm).
        let decimalPreserved: Bool
        /// Wall time of the `OCRManager.recognize` call only.
        let latencySeconds: Double
        let renderSeconds: Double
    }

    // MARK: - The benchmark

    override func setUp() {
        super.setUp()
        // 72 cases × one Vision `.accurate` pass (the `.fast` rescue runs
        // concurrently inside it, adding ~0 wall clock) plus a 1080×1920
        // render per case. Generous headroom for a Debug build on device.
        executionTimeAllowance = 900
    }

    func testDecimalPreservationAndPowerOfTenErrorRate() async throws {
        let renderer = SyntheticDisplayRenderer(size: Self.renderSize)
        let clock = ContinuousClock()

        // Ground truth must be well-formed before anything is measured.
        for label in Self.labels {
            XCTAssertNotNil(RecognitionBenchmark.groundTruth(of: label),
                            "label '\(label)' must parse as a plain decimal number")
        }

        let thermalAtStart = Self.thermalStateName()

        // ---- Cold-start cost -------------------------------------------------
        // Vision's text model is loaded lazily and stays resident PROCESS-WIDE,
        // so only the very first `recognize` in this process is genuinely cold.
        // It is measured here, before anything else touches Vision.
        guard let warmupBuffer = renderer.render(text: "12.345", pose: .identity) else {
            XCTFail("SyntheticDisplayRenderer returned no buffer")
            return
        }
        let warmupROI = renderer.panelROI(for: .identity)

        let constructionStart = clock.now
        let engine = OCRManager()
        let constructionSeconds = Self.seconds(clock.now - constructionStart)

        let coldStart = clock.now
        let coldCandidates = (try? await engine.recognize(in: warmupBuffer,
                                                          regionOfInterest: warmupROI)) ?? []
        let coldCallSeconds = Self.seconds(clock.now - coldStart)

        let secondStart = clock.now
        _ = try? await engine.recognize(in: warmupBuffer, regionOfInterest: warmupROI)
        let secondCallSeconds = Self.seconds(clock.now - secondStart)

        // ---- Main sweep ------------------------------------------------------
        var results: [CaseResult] = []
        results.reserveCapacity(Self.labels.count * Self.variants.count)

        for label in Self.labels {
            for variant in Self.variants {
                let renderStart = clock.now
                let buffer = renderer.render(text: label, pose: variant.pose,
                                             degradation: variant.degradation,
                                             frameIndex: 0)
                let renderSeconds = Self.seconds(clock.now - renderStart)
                guard let buffer else {
                    XCTFail("render failed for '\(label)' / \(variant.name)")
                    continue
                }
                // The engine reads the DISPLAY CROP: the panel's ground-truth
                // bounding box for this pose, which is what a locked ROI gives
                // the pipeline in the app.
                let roi = renderer.panelROI(for: variant.pose)

                let start = clock.now
                let candidates = (try? await engine.recognize(in: buffer,
                                                              regionOfInterest: roi)) ?? []
                let latency = Self.seconds(clock.now - start)

                results.append(Self.score(label: label,
                                          variant: variant,
                                          candidates: candidates,
                                          latencySeconds: latency,
                                          renderSeconds: renderSeconds))
            }
        }

        let thermalAtEnd = Self.thermalStateName()

        // ---- Structural assertions ------------------------------------------
        XCTAssertEqual(results.count, Self.labels.count * Self.variants.count,
                       "every (label × variant) case must produce a result")
        XCTAssertTrue(results.allSatisfy { $0.latencySeconds > 0 },
                      "every engine call must take measurable time")
        XCTAssertGreaterThan(coldCallSeconds, 0, "cold call must take measurable time")

        // ---- Report ----------------------------------------------------------
        let report = Self.formattedReport(results: results,
                                          constructionSeconds: constructionSeconds,
                                          coldCallSeconds: coldCallSeconds,
                                          secondCallSeconds: secondCallSeconds,
                                          coldCandidateCount: coldCandidates.count,
                                          thermalAtStart: thermalAtStart,
                                          thermalAtEnd: thermalAtEnd)
        print("\n" + report + "\n")
        XCTContext.runActivity(named: "Decimal benchmark (measured)") { activity in
            let attachment = XCTAttachment(string: report)
            attachment.name = "decimal-benchmark.txt"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        // ---- Honesty gate ----------------------------------------------------
        if !results.contains(where: { $0.topText != nil }) {
            throw XCTSkip("""
            Vision produced NO text on any synthetic display frame in this \
            environment — there are no measured decimal numbers to report. \
            (Structural harness checks above still passed.)
            """)
        }
    }

    // MARK: - Scoring

    private static func score(label: String,
                              variant: Variant,
                              candidates: [OCRCandidate],
                              latencySeconds: Double,
                              renderSeconds: Double) -> CaseResult {
        let truth = RecognitionBenchmark.groundTruth(of: label)
        let truthDecimal = decimalGroundTruth(of: label)

        // What the PIPELINE would accept: the first candidate, in the engine's
        // own preference order, that `FormatValidator` resolves to a number.
        // `.unconstrained` is deliberate — the device format must not be used to
        // reconstruct a separator the image did not contain.
        var accepted: NumericReading?
        var sawAmbiguousDecimal = false
        var sawAnyParseAttempt = false
        for candidate in candidates {
            sawAnyParseAttempt = true
            switch FormatValidator.reading(from: candidate.text, format: .unconstrained) {
            case .valid(let reading):
                accepted = reading
            case .invalid(let reason):
                if reason == .ambiguousDecimal { sawAmbiguousDecimal = true }
            }
            if accepted != nil { break }
        }

        let outcome: Outcome
        if let accepted, let truth {
            if abs(accepted.value - truth.value) <= truth.tolerance {
                outcome = .correct
            } else if isPowerOfTenOff(value: accepted.value, truth: truth.value) {
                outcome = .powerOfTenError
            } else {
                outcome = .otherWrong
            }
        } else if accepted != nil {
            outcome = .otherWrong          // unreachable: every label parses
        } else if sawAmbiguousDecimal {
            outcome = .refusedAmbiguousDecimal
        } else if sawAnyParseAttempt {
            outcome = .noParseableReading
        } else {
            outcome = .noCandidates
        }

        let decimalPreserved: Bool
        if let accepted {
            if truthDecimal.hasSeparator {
                decimalPreserved = accepted.decimal.separatorDetected
                    && accepted.decimal.separatorPosition == truthDecimal.position
            } else {
                decimalPreserved = !accepted.decimal.separatorDetected
            }
        } else {
            decimalPreserved = false
        }

        return CaseResult(label: label,
                          variant: variant.name,
                          group: variant.group,
                          topText: candidates.first?.text,
                          candidateCount: candidates.count,
                          acceptedValue: accepted?.value,
                          acceptedText: accepted?.text,
                          outcome: outcome,
                          decimalPreserved: decimalPreserved,
                          latencySeconds: latencySeconds,
                          renderSeconds: renderSeconds)
    }

    /// Ground-truth separator verdict for a label, in `DisplayFormat`'s
    /// convention: `position` counts DIGITS before the separator, so `".5"` is
    /// 0 and `"-1.25"` is 1 (the sign is not a digit).
    static func decimalGroundTruth(of label: String) -> (hasSeparator: Bool, position: Int) {
        guard let dot = label.firstIndex(of: ".") else { return (false, 0) }
        let leading = label[label.startIndex..<dot].filter { $0.isASCII && ("0"..."9").contains($0) }
        return (true, leading.count)
    }

    /// True when `value` is 10^k times `truth` in MAGNITUDE for some integer
    /// k ≠ 0 — i.e. the digits are right (or right enough) and the decimal
    /// point is in the wrong place. Magnitude-based on purpose: `-8.08` for a
    /// true `80.8` is still a 10x scale error and is counted as one; a pure
    /// sign flip (k = 0) is not.
    ///
    /// The 0.02-decade tolerance admits only near-exact decade ratios; an
    /// unrelated misread that happens to land within a few percent of a decade
    /// would be miscounted, which is why per-case rows are printed for audit.
    static func isPowerOfTenOff(value: Double, truth: Double) -> Bool {
        guard value.isFinite, truth.isFinite, value != 0, truth != 0 else { return false }
        let decades = log10(abs(value / truth))
        let k = decades.rounded()
        return k != 0 && abs(decades - k) < 0.02
    }

    // MARK: - Report formatting

    private static func formattedReport(results: [CaseResult],
                                        constructionSeconds: Double,
                                        coldCallSeconds: Double,
                                        secondCallSeconds: Double,
                                        coldCandidateCount: Int,
                                        thermalAtStart: String,
                                        thermalAtEnd: String) -> String {
        var lines: [String] = []
        lines.append("================ DECIMAL BENCHMARK — MEASURED ================")
        lines.append("ENGINE: OCRManager (default: DualPassVisionOCR = Vision .accurate + .fast)")
        lines.append("IMAGERY: SyntheticDisplayRenderer @ \(Int(renderSize.width))x\(Int(renderSize.height)) "
                     + "(SYNTHETIC — not a real-instrument claim)")
        lines.append("HOST: \(hostDescription())")
        lines.append("THERMAL: start=\(thermalAtStart) end=\(thermalAtEnd)")
        lines.append("CASES: \(results.count) = \(labels.count) labels x \(variants.count) variants")
        lines.append("")

        // Headline rates.
        let n = results.count
        let correct = results.filter { $0.outcome == .correct }.count
        let powerOfTen = results.filter { $0.outcome == .powerOfTenError }.count
        let otherWrong = results.filter { $0.outcome == .otherWrong }.count
        let refused = results.filter { $0.outcome == .refusedAmbiguousDecimal }.count
        let noParse = results.filter { $0.outcome == .noParseableReading }.count
        let noCand = results.filter { $0.outcome == .noCandidates }.count
        let preserved = results.filter(\.decimalPreserved).count
        let acceptedCount = results.filter { $0.acceptedValue != nil }.count

        lines.append("---- HEADLINE ----")
        lines.append(String(format: "  POWER-OF-TEN ERROR RATE : %@  (%d/%d of all cases)",
                            percent(rate(powerOfTen, n)), powerOfTen, n))
        if acceptedCount > 0 {
            lines.append(String(format: "  POWER-OF-TEN ERROR RATE : %@  (%d/%d of ACCEPTED readings)",
                                percent(rate(powerOfTen, acceptedCount)), powerOfTen, acceptedCount))
        }
        lines.append(String(format: "  DECIMAL-PRESERVATION    : %@  (%d/%d of all cases)",
                            percent(rate(preserved, n)), preserved, n))
        if acceptedCount > 0 {
            lines.append(String(format: "  DECIMAL-PRESERVATION    : %@  (%d/%d of ACCEPTED readings)",
                                percent(rate(preserved, acceptedCount)), preserved, acceptedCount))
        }
        lines.append(String(format: "  VALUE ACCURACY          : %@  (%d/%d of all cases)",
                            percent(rate(correct, n)), correct, n))
        lines.append("")

        lines.append("---- OUTCOME BREAKDOWN ----")
        lines.append(String(format: "  correct                 %4d  %@", correct, percent(rate(correct, n))))
        lines.append(String(format: "  powerOfTenError         %4d  %@", powerOfTen, percent(rate(powerOfTen, n))))
        lines.append(String(format: "  otherWrong              %4d  %@", otherWrong, percent(rate(otherWrong, n))))
        lines.append(String(format: "  refusedAmbiguousDecimal %4d  %@", refused, percent(rate(refused, n))))
        lines.append(String(format: "  noParseableReading      %4d  %@", noParse, percent(rate(noParse, n))))
        lines.append(String(format: "  noCandidates            %4d  %@", noCand, percent(rate(noCand, n))))
        lines.append("")

        lines.append("---- BY VARIANT ----")
        lines.append("  " + pad("VARIANT", 24) + rp("N", 5) + rp("CORRECT", 9) + rp("10^k", 7)
                     + rp("DECIMAL", 9) + rp("REFUSED", 9) + rp("ms", 9))
        for variant in variants {
            let subset = results.filter { $0.variant == variant.name }
            lines.append("  " + pad(variant.name, 24) + breakdown(subset))
        }
        lines.append("")

        lines.append("---- BY GROUP ----")
        lines.append("  " + pad("GROUP", 24) + rp("N", 5) + rp("CORRECT", 9) + rp("10^k", 7)
                     + rp("DECIMAL", 9) + rp("REFUSED", 9) + rp("ms", 9))
        for group in VariantGroup.allCases {
            let subset = results.filter { $0.group == group }
            lines.append("  " + pad(group.rawValue, 24) + breakdown(subset))
        }
        lines.append("")

        lines.append("---- BY LABEL ----")
        lines.append("  " + pad("LABEL", 24) + rp("N", 5) + rp("CORRECT", 9) + rp("10^k", 7)
                     + rp("DECIMAL", 9) + rp("REFUSED", 9) + rp("ms", 9))
        for label in labels {
            let subset = results.filter { $0.label == label }
            lines.append("  " + pad(label, 24) + breakdown(subset))
        }
        lines.append("")

        // Latency.
        let latencies = results.map(\.latencySeconds).sorted()
        lines.append("---- LATENCY (engine call only, ContinuousClock) ----")
        lines.append(String(format: "  mean   %.1f ms", mean(latencies) * 1000))
        lines.append(String(format: "  min    %.1f ms", (latencies.first ?? 0) * 1000))
        lines.append(String(format: "  p50    %.1f ms", quantile(latencies, 0.50) * 1000))
        lines.append(String(format: "  p90    %.1f ms", quantile(latencies, 0.90) * 1000))
        lines.append(String(format: "  max    %.1f ms", (latencies.last ?? 0) * 1000))
        lines.append("")
        lines.append("---- ENGINE LOAD / FIRST-CALL COST ----")
        lines.append(String(format: "  OCRManager() construction        %.3f ms", constructionSeconds * 1000))
        lines.append(String(format: "  FIRST recognize() in process     %.1f ms  (%d candidates)",
                            coldCallSeconds * 1000, coldCandidateCount))
        lines.append(String(format: "  SECOND recognize(), same buffer   %.1f ms", secondCallSeconds * 1000))
        lines.append(String(format: "  cold overhead (first - second)   %.1f ms",
                            (coldCallSeconds - secondCallSeconds) * 1000))
        lines.append("  NOTE: Vision's text model is process-resident, so only the first")
        lines.append("        recognize() in a process pays load cost; constructing another")
        lines.append("        OCRManager afterwards is already warm.")
        lines.append("")
        let renders = results.map(\.renderSeconds).sorted()
        lines.append(String(format: "  harness render cost (not pipeline): mean %.1f ms, max %.1f ms",
                            mean(renders) * 1000, (renders.last ?? 0) * 1000))
        lines.append("")

        lines.append("---- PER-CASE ROWS (audit trail) ----")
        lines.append("  " + pad("LABEL", 9) + pad("VARIANT", 24) + pad("TOP TEXT", 20)
                     + pad("ACCEPTED", 14) + pad("OUTCOME", 24) + "DEC")
        for result in results {
            let top = (result.topText ?? "<none>")
                .replacingOccurrences(of: "\n", with: "\\n")
            lines.append("  " + pad(result.label, 9)
                         + pad(result.variant, 24)
                         + pad(top, 20)
                         + pad(result.acceptedText ?? "-", 14)
                         + pad(result.outcome.rawValue, 24)
                         + (result.decimalPreserved ? "ok" : "--"))
        }
        lines.append("=============================================================")
        return lines.joined(separator: "\n")
    }

    private static func breakdown(_ subset: [CaseResult]) -> String {
        let n = subset.count
        let correct = subset.filter { $0.outcome == .correct }.count
        let pot = subset.filter { $0.outcome == .powerOfTenError }.count
        let dec = subset.filter(\.decimalPreserved).count
        let refused = subset.filter { $0.outcome == .refusedAmbiguousDecimal }.count
        let ms = n == 0 ? 0 : mean(subset.map(\.latencySeconds)) * 1000
        return rp("\(n)", 5)
            + rp(percent(rate(correct, n)), 9)
            + rp(percent(rate(pot, n)), 7)
            + rp(percent(rate(dec, n)), 9)
            + rp(percent(rate(refused, n)), 9)
            + rp(String(format: "%.1f", ms), 9)
    }

    // MARK: - Environment

    private static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// Device model identifier + OS + whether this is a Simulator. The
    /// Simulator flag matters: Simulator timings measure the Mac, never a phone.
    private static func hostDescription() -> String {
        var info = utsname()
        // Copy the C char tuple out of `info` BEFORE reading it: passing
        // `&info.machine` while `info` is also borrowed is an exclusivity
        // violation the compiler rejects.
        let machineTuple = uname(&info) == 0 ? info.machine : utsname().machine
        let machine = withUnsafeBytes(of: machineTuple) { raw -> String in
            guard let base = raw.baseAddress else { return "unknown" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        let environment = ProcessInfo.processInfo.environment
        let isSimulator = environment["SIMULATOR_DEVICE_NAME"] != nil
        let kind = isSimulator ? "SIMULATOR (timings measure the Mac, NOT a phone)" : "PHYSICAL DEVICE"
        let simulated = environment["SIMULATOR_MODEL_IDENTIFIER"].map { " simulating \($0)" } ?? ""
        return "\(kind) — machine=\(machine)\(simulated), "
            + "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion), "
            + "activeProcessorCount=\(ProcessInfo.processInfo.activeProcessorCount)"
    }

    // MARK: - Small numeric / formatting helpers

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }

    private static func rate(_ count: Int, _ total: Int) -> Double {
        total == 0 ? 0 : Double(count) / Double(total)
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Nearest-rank quantile of an ALREADY-SORTED array.
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        if string.count >= width { return String(string.prefix(width - 1)) + " " }
        return string + String(repeating: " ", count: width - string.count)
    }

    /// Right-justified in a field of `width` with one trailing space.
    private static func rp(_ string: String, _ width: Int) -> String {
        let content = string.count >= width - 1 ? String(string.prefix(width - 1)) : string
        return String(repeating: " ", count: width - 1 - content.count) + content + " "
    }
}
