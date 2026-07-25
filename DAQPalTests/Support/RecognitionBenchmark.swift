//
//  RecognitionBenchmark.swift
//  DAQPalTests
//
//  OCR_RESEARCH.md Phase 1 / Milestone 9 — the recognition benchmark harness.
//  Runs any `OCREngine` over a deterministic set of labeled
//  `SyntheticDisplaySample`s and reports MEASURED exact-value-match rate and
//  latency, broken down by display style and augmentation.
//
//  HONESTY: every sample is SYNTHETIC (see `SyntheticDisplayGenerator`). These
//  numbers describe an engine's behavior on a synthetic distribution only —
//  they are NOT a real-instrument accuracy claim. The held-out human-labeled
//  eval set that would license such a claim does not exist yet. The harness
//  never asserts an accuracy threshold; it measures and reports what happened.
//
//  Value comparison (per contract): each recognized candidate is run through
//  `FormatValidator.value(from:format:)` with the lenient `.unconstrained`
//  format, and the parsed Double is compared to the sample's ground-truth value
//  within ±half of one least-significant-digit step (derived from the label's
//  fractional-digit count). Latency is measured with `ContinuousClock` around
//  the engine call only.
//

import Foundation
@testable import DAQPal

// MARK: - Per-case result

/// The outcome for one benchmark sample.
struct BenchmarkCaseResult {
    let text: String                 // ground-truth label the sample was rendered from
    let style: DisplayGlyphStyle
    let augmentationName: String
    /// Top (highest-confidence) hypothesis the engine returned, or nil when the
    /// engine returned nothing for this sample.
    let recognizedText: String?
    /// Numeric value the harness extracted: the matching candidate's value when
    /// a candidate hit ground truth, otherwise the top parseable candidate's
    /// value (nil when no candidate parsed to a number).
    let parsedValue: Double?
    /// True when ANY returned candidate parsed to a value within ±half-LSD of
    /// ground truth (lenient across candidates — an engine gets credit if any of
    /// its hypotheses is correct).
    let exactValueMatch: Bool
    /// Wall time of the engine call only, in seconds.
    let latencySeconds: Double
}

// MARK: - Report

/// Aggregated, printable results for one engine over one dataset.
struct BenchmarkReport {
    let engineName: String
    let results: [BenchmarkCaseResult]

    /// Fraction of cases whose value matched ground truth (0 when empty).
    var exactMatchRate: Double {
        guard !results.isEmpty else { return 0 }
        let matches = results.reduce(0) { $0 + ($1.exactValueMatch ? 1 : 0) }
        return Double(matches) / Double(results.count)
    }

    /// Mean per-case engine latency in milliseconds (0 when empty).
    var meanLatencyMS: Double {
        guard !results.isEmpty else { return 0 }
        let total = results.reduce(0.0) { $0 + $1.latencySeconds }
        return (total / Double(results.count)) * 1000
    }

    /// Exact-match rate restricted to one display style (0 when that style has
    /// no cases).
    func exactMatchRate(style: DisplayGlyphStyle) -> Double {
        let subset = results.filter { $0.style == style }
        guard !subset.isEmpty else { return 0 }
        let matches = subset.reduce(0) { $0 + ($1.exactValueMatch ? 1 : 0) }
        return Double(matches) / Double(subset.count)
    }

    /// A monospaced, log-friendly summary: overall line, per-style breakdown,
    /// and per-augmentation breakdown. Individual case rows are intentionally
    /// omitted — for ~200 cases the aggregates are what a reader needs.
    func formattedTable() -> String {
        var lines: [String] = []
        let total = results.count
        let matches = results.reduce(0) { $0 + ($1.exactValueMatch ? 1 : 0) }
        lines.append("ENGINE: \(engineName)")
        lines.append(String(format: "Cases: %d | Exact-match: %@ (%d/%d) | Mean latency: %.1f ms",
                            total, Self.percent(exactMatchRate), matches, total, meanLatencyMS))

        lines.append("")
        lines.append("By style:")
        lines.append(Self.headerRow(firstColumn: "STYLE"))
        for style in DisplayGlyphStyle.allCases {
            let subset = results.filter { $0.style == style }
            lines.append(Self.breakdownRow(label: style.rawValue, subset: subset))
        }

        lines.append("")
        lines.append("By augmentation:")
        lines.append(Self.headerRow(firstColumn: "AUGMENTATION"))
        for name in orderedAugmentationNames() {
            let subset = results.filter { $0.augmentationName == name }
            lines.append(Self.breakdownRow(label: name, subset: subset))
        }

        return lines.joined(separator: "\n")
    }

    /// Augmentation names in first-seen order (preserves the dataset's ordering
    /// rather than sorting alphabetically).
    private func orderedAugmentationNames() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for result in results where !seen.contains(result.augmentationName) {
            seen.insert(result.augmentationName)
            ordered.append(result.augmentationName)
        }
        return ordered
    }

    // MARK: Formatting helpers

    private static let labelWidth = 18

    private static func headerRow(firstColumn: String) -> String {
        "  " + pad(firstColumn, labelWidth)
            + rightPad("N", 5) + rightPad("MATCH", 7) + rightPad("RATE", 8) + rightPad("ms", 9)
    }

    private static func breakdownRow(label: String, subset: [BenchmarkCaseResult]) -> String {
        let n = subset.count
        let matches = subset.reduce(0) { $0 + ($1.exactValueMatch ? 1 : 0) }
        let rate = n == 0 ? 0 : Double(matches) / Double(n)
        let meanMS: Double = n == 0 ? 0 : (subset.reduce(0.0) { $0 + $1.latencySeconds } / Double(n)) * 1000
        return "  " + pad(label, labelWidth)
            + rightPad("\(n)", 5)
            + rightPad("\(matches)", 7)
            + rightPad(percent(rate), 8)
            + rightPad(String(format: "%.1f", meanMS), 9)
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    /// Left-justified pad to `width` (truncates longer strings).
    private static func pad(_ string: String, _ width: Int) -> String {
        if string.count >= width { return String(string.prefix(width)) }
        return string + String(repeating: " ", count: width - string.count)
    }

    /// Right-justified value with a trailing space, in a field of `width`.
    private static func rightPad(_ string: String, _ width: Int) -> String {
        let content = string.count >= width - 1 ? String(string.prefix(width - 1)) : string
        return String(repeating: " ", count: width - 1 - content.count) + content + " "
    }
}

// MARK: - Benchmark runner

/// Runs an `OCREngine` over a fixed set of labeled synthetic samples.
///
/// Each sample is a full display-line tile whose entire buffer is the display,
/// so the engine reads the whole buffer (`regionOfInterest: nil`); the sample's
/// `textROI` is a loose over-estimate and is not needed to localize a line that
/// already fills the tile.
final class RecognitionBenchmark {
    private let cases: [SyntheticDisplaySample]

    init(cases: [SyntheticDisplaySample]) {
        self.cases = cases
    }

    func run(engineName: String, engine: any OCREngine) async -> BenchmarkReport {
        var results: [BenchmarkCaseResult] = []
        results.reserveCapacity(cases.count)
        let clock = ContinuousClock()

        for sample in cases {
            let start = clock.now
            let candidates = (try? await engine.recognize(in: sample.pixelBuffer,
                                                          regionOfInterest: nil)) ?? []
            let latency = Self.seconds(clock.now - start)

            results.append(Self.evaluate(sample: sample, candidates: candidates, latency: latency))
        }

        return BenchmarkReport(engineName: engineName, results: results)
    }

    /// Scores one sample's candidate list against ground truth. `candidates` are
    /// assumed in engine-preferred (confidence-descending) order.
    private static func evaluate(sample: SyntheticDisplaySample,
                                 candidates: [OCRCandidate],
                                 latency: Double) -> BenchmarkCaseResult {
        // Lenient parse of every candidate, preserving confidence order.
        let parsed: [Double] = candidates.compactMap { candidate in
            if case .valid(let value) = FormatValidator.value(from: candidate.text,
                                                              format: .unconstrained) {
                return value
            }
            return nil
        }

        let recognizedText = candidates.first?.text
        var reportedValue = parsed.first
        var exactMatch = false

        if let truth = groundTruth(of: sample.text),
           let hit = parsed.first(where: { abs($0 - truth.value) <= truth.tolerance }) {
            exactMatch = true
            reportedValue = hit
        }

        return BenchmarkCaseResult(text: sample.text,
                                   style: sample.style,
                                   augmentationName: sample.augmentationName,
                                   recognizedText: recognizedText,
                                   parsedValue: reportedValue,
                                   exactValueMatch: exactMatch,
                                   latencySeconds: latency)
    }

    /// Ground-truth value and match tolerance for a label. The tolerance is half
    /// of one least-significant-digit step, derived from the label's fractional
    /// digits: "12.347" ⇒ 0.0005, "88888" ⇒ 0.5, "-0.05" ⇒ 0.005. Returns nil
    /// for labels that are not plain decimal numbers (none are, in the dataset).
    static func groundTruth(of label: String) -> (value: Double, tolerance: Double)? {
        guard let value = Double(label) else { return nil }
        let fractionDigits: Int
        if let dot = label.firstIndex(of: ".") {
            fractionDigits = label.distance(from: label.index(after: dot), to: label.endIndex)
        } else {
            fractionDigits = 0
        }
        let step = pow(10.0, Double(-fractionDigits))
        return (value, step / 2)
    }

    /// Converts a `Duration` to seconds as a Double (seconds + attoseconds).
    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
