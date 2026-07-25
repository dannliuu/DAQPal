//
//  OCRBenchmarkTests.swift
//  DAQPalTests
//
//  OCR_RESEARCH.md Phase 1 / Milestone 9 — the first MEASURED recognition
//  numbers for DAQPal. Builds a deterministic synthetic dataset (labeled digit
//  strings × all four display styles × a spread of augmentations) and runs it
//  through `RecognitionBenchmark` for three engines: Vision `.accurate`
//  (`VisionOCR`), Vision `.fast` (`VisionOCR(recognitionLevel: .fast)`), and
//  the shipping `DualPassVisionOCR` (both levels concurrently, merged).
//
//  HONESTY (paramount this round):
//  - Every sample is SYNTHETIC. These tables measure engine behavior on a
//    synthetic distribution; they are NOT real-instrument accuracy. No held-out
//    human-labeled eval set exists yet.
//  - The test asserts ONLY structural facts (result count matches the dataset;
//    each case has a positive engine latency). It never asserts an accuracy
//    threshold — the numbers are whatever they measure.
//  - When neither engine reads any text at all in this environment (Vision on
//    synthetic renders varies by OS/Simulator build), the test SKIPS with a
//    clear message rather than pretending to have measured something.
//
//  The measured tables are printed (and attached via XCTContext) so the
//  orchestrator can record the real numbers; nothing here is a fabricated value.
//

import CoreGraphics
import CoreVideo
import Vision
import XCTest
@testable import DAQPal

final class OCRBenchmarkTests: XCTestCase {

    // MARK: Dataset definition

    /// ~12 labels: signs, leading blanks, integer-only, and varied precision.
    private static let texts = [
        "12.347", "-0.05", "199.9", "0.001", "88888", "1.5",
        "0.000", "-1.234", "100.0", "9.99", "-88.8", "0.50"
    ]

    /// clean / moderate / hard + one polarity-inverted preset (per contract).
    private static let benchmarkPresets: [(name: String, augmentation: DisplayAugmentation)] =
        DisplayAugmentation.presets.filter {
            ["clean", "moderate", "hard", "clean-inverted"].contains($0.name)
        }

    override func setUp() {
        super.setUp()
        // Expected wall-clock (192 cases): `.accurate` dominates at ~0.4 s/case,
        // so the accurate pass and the dual pass (which runs `.fast` CONCURRENTLY
        // inside each `.accurate` call — adding ~0 wall-clock) are each ~75 s,
        // and the standalone `.fast` pass is ~2 s: ~150 s total plus generation.
        // The allowance is generous headroom for Simulator variance. No-op unless
        // test-timeouts are enabled for the run, but documents the intended budget.
        executionTimeAllowance = 480 // seconds (rounded up to whole minutes)
    }

    // MARK: The benchmark

    func testAccurateFastAndDualPassBenchmark() async throws {
        let generator: SyntheticDisplayGenerator
        do {
            generator = try SyntheticDisplayGenerator()
        } catch {
            throw XCTSkip("SyntheticDisplayGenerator unavailable (DSEG fonts missing from test bundle?): \(error)")
        }

        let dataset = try generator.dataset(texts: Self.texts,
                                            styles: DisplayGlyphStyle.allCases,
                                            presets: Self.benchmarkPresets)
        let expectedCount = Self.texts.count * DisplayGlyphStyle.allCases.count * Self.benchmarkPresets.count
        XCTAssertEqual(dataset.count, expectedCount, "dataset should fan out over text × style × preset")

        let benchmark = RecognitionBenchmark(cases: dataset)
        let accurate = await benchmark.run(engineName: "Vision .accurate",
                                           engine: VisionOCR())
        let fast = await benchmark.run(engineName: "Vision .fast",
                                       engine: VisionOCR(recognitionLevel: .fast))
        // The shipping engine: `.accurate` and `.fast` run concurrently over
        // each buffer and their candidates are merged (`.accurate` preferred).
        let dual = await benchmark.run(engineName: "DualPass (.accurate+.fast)",
                                       engine: DualPassVisionOCR())

        // Structural assertions (environment-independent facts about the harness).
        for report in [accurate, fast, dual] {
            XCTAssertEqual(report.results.count, dataset.count,
                           "\(report.engineName) report must cover every case")
            XCTAssertTrue(report.results.allSatisfy { $0.latencySeconds > 0 },
                          "\(report.engineName): every engine call must take measurable time")
        }

        // Emit the measured tables for the orchestrator to record.
        let comparison = Self.perStyleComparison(accurate: accurate, fast: fast, dual: dual)
        XCTContext.runActivity(named: "Vision .accurate benchmark") { _ in print("\n" + accurate.formattedTable()) }
        XCTContext.runActivity(named: "Vision .fast benchmark") { _ in print("\n" + fast.formattedTable()) }
        XCTContext.runActivity(named: "DualPass benchmark") { _ in print("\n" + dual.formattedTable()) }
        XCTContext.runActivity(named: "Per-style comparison") { _ in print("\n" + comparison) }

        // Honesty gate: only skip when there are NO measured recognition numbers
        // at all (every engine silent on every case). If at least one engine
        // reads text, its numbers are a genuine measured result and are kept —
        // an engine that reads NOTHING on segment displays is itself a real,
        // reportable finding, not a reason to discard the other's data.
        // (DualPass is the union of the two Vision passes, so it can only see
        // text when accurate or fast did; the gate keys on those two.)
        let accurateSawText = accurate.results.contains { $0.recognizedText != nil }
        let fastSawText = fast.results.contains { $0.recognizedText != nil }
        let dualSawText = dual.results.contains { $0.recognizedText != nil }
        if !accurateSawText && !fastSawText {
            throw XCTSkip("""
            Neither Vision .accurate nor .fast produced any text on the synthetic \
            displays in this environment — there are no measured recognition numbers \
            to report. (Structural harness checks above still passed.)
            """)
        }
        if !accurateSawText {
            print("\nNOTE: Vision .accurate produced NO text on any synthetic case in this environment.")
        }
        if !fastSawText {
            print("\nNOTE: Vision .fast produced NO text on any synthetic case in this environment.")
        }
        if !dualSawText {
            print("\nNOTE: DualPass produced NO text on any synthetic case in this environment.")
        }
    }

    // MARK: Comparison summary

    /// Side-by-side per-style exact-match rates for the three engines
    /// (`.accurate`, `.fast`, and the shipping dual-pass merge).
    private static func perStyleComparison(accurate: BenchmarkReport,
                                           fast: BenchmarkReport,
                                           dual: BenchmarkReport) -> String {
        var lines: [String] = []
        lines.append("PER-STYLE COMPARISON — exact-value-match rate (synthetic)")
        lines.append(row("STYLE", ".accurate", ".fast", "dual-pass"))
        for style in DisplayGlyphStyle.allCases {
            lines.append(row(style.rawValue,
                             percent(accurate.exactMatchRate(style: style)),
                             percent(fast.exactMatchRate(style: style)),
                             percent(dual.exactMatchRate(style: style))))
        }
        lines.append(row("OVERALL",
                         percent(accurate.exactMatchRate),
                         percent(fast.exactMatchRate),
                         percent(dual.exactMatchRate)))
        lines.append(String(format: "Mean latency — accurate: %.1f ms | fast: %.1f ms | dual-pass: %.1f ms",
                            accurate.meanLatencyMS, fast.meanLatencyMS, dual.meanLatencyMS))
        return lines.joined(separator: "\n")
    }

    private static func row(_ label: String, _ a: String, _ b: String, _ c: String) -> String {
        "  " + pad(label, 18) + pad(a, 12) + pad(b, 12) + pad(c, 12)
    }

    private static func pad(_ string: String, _ width: Int) -> String {
        string.count >= width ? String(string.prefix(width))
                              : string + String(repeating: " ", count: width - string.count)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }
}
