//
//  ValidationHarness.swift
//  DAQPalTests
//
//  Shared measurement vocabulary for the validation sweeps (pose, perspective,
//  degradation, segment ambiguity, motion). Every sweep reports through these
//  types so results are comparable across sweeps and across OCR engines, and so
//  the regression checker has one shape to read.
//
//  WHY A SEPARATE FAILURE TAXONOMY. `BenchmarkReport` already scores exact-match
//  rate, which is the right top-line number but hides the distinction this
//  project keeps getting bitten by: reading `808` when the display shows `80.8`
//  is NOT the same defect as reading `809`. The first is a decimal-detection
//  failure with every digit correct; the second is a character error. They have
//  different causes, different fixes, and different consequences for recorded
//  data — a missed decimal is off by a factor of ten and still looks plausible.
//  `ReadingVerdict` separates them at the point of measurement rather than
//  leaving it to be inferred from a pass rate.
//
//  DETERMINISM. Nothing here samples a random source. Sweeps that need
//  pseudo-randomness take an explicit seed and use `SeededGenerator`, so a
//  failing case can always be replayed from its test id alone.
//

import CoreGraphics
import Foundation

// MARK: - Reading accuracy

/// How a predicted reading differs from ground truth. Ordered roughly by
/// severity of the consequence, not by how wrong the string looks.
enum ReadingVerdict: String, Equatable, Sendable {
    /// Digits and decimal placement both correct.
    case exact
    /// Every digit correct, decimal point MISSING — `80.8` read as `808`.
    /// Silently multiplies the recorded value by a power of ten.
    case decimalMissing
    /// Every digit correct, decimal point INVENTED — `808` read as `80.8`.
    case decimalSpurious
    /// Every digit correct, decimal in the wrong position — `8.08` for `80.8`.
    case decimalMisplaced
    /// At least one digit wrong, decimal placement aside.
    case digitError
    /// Nothing was produced for a frame that contains a reading.
    case notDetected

    /// Only `exact` counts as correct; the rest are all defects. Named rather
    /// than written as `== .exact` at 20 call sites.
    var isCorrect: Bool { self == .exact }

    /// True when every digit was right and only the decimal was wrong. These
    /// are tracked as their own rate because they are the failure mode that
    /// corrupts data without looking corrupt.
    var isDecimalOnlyFailure: Bool {
        self == .decimalMissing || self == .decimalSpurious || self == .decimalMisplaced
    }
}

enum ReadingComparison {
    /// Classifies `predicted` against `truth`.
    ///
    /// Both are compared as written strings, not as parsed doubles: `08` and
    /// `8` parse identically but are different recognitions, and leading-zero
    /// handling is one of the cases the segment tests exercise.
    static func verdict(truth: String, predicted: String?) -> ReadingVerdict {
        guard let predicted, !predicted.isEmpty else { return .notDetected }
        if predicted == truth { return .exact }

        let truthDigits = truth.filter(\.isNumber)
        let predictedDigits = predicted.filter(\.isNumber)
        guard truthDigits == predictedDigits else { return .digitError }

        // Digits agree, so whatever differs is the separator. Position is
        // counted in digits-from-the-left so it is independent of how many
        // digits precede it.
        let truthPoint = decimalIndex(in: truth)
        let predictedPoint = decimalIndex(in: predicted)
        switch (truthPoint, predictedPoint) {
        case (nil, nil): return .digitError   // digits equal, no points: sign or unit differs
        case (_?, nil): return .decimalMissing
        case (nil, _?): return .decimalSpurious
        case let (t?, p?): return t == p ? .digitError : .decimalMisplaced
        }
    }

    /// Index of the decimal separator counted in DIGITS from the left, or nil
    /// when there is none.
    private static func decimalIndex(in text: String) -> Int? {
        var digits = 0
        for character in text {
            if character.isNumber { digits += 1 }
            else if character == "." || character == "," { return digits }
        }
        return nil
    }
}

// MARK: - Geometry accuracy

/// Agreement between a predicted display quadrilateral and ground truth.
struct GeometryError: Equatable, Sendable {
    /// Intersection-over-union of the two quads' axis-aligned bounding boxes.
    ///
    /// Deliberately IoU of the BOUNDING BOXES, not of the quads themselves.
    /// Exact polygon intersection is what a detector's own scoring would use,
    /// but here the consumers are Vision's `regionOfInterest` and the crop
    /// path, both of which are axis-aligned — so box IoU is what actually
    /// predicts whether recognition gets the glyphs. Recorded alongside corner
    /// error, which does capture keystone disagreement.
    var iou: CGFloat
    /// Mean distance between corresponding corners, normalized units.
    var meanCornerError: CGFloat
    /// Worst single corner, normalized units.
    var maxCornerError: CGFloat
    /// Distance between quad centres, normalized units.
    var centerError: CGFloat

    static func between(predicted: [CGPoint], truth: [CGPoint]) -> GeometryError? {
        guard predicted.count == 4, truth.count == 4 else { return nil }
        let errors = zip(predicted, truth).map { hypot($0.x - $1.x, $0.y - $1.y) }
        let predictedBox = boundingBox(predicted)
        let truthBox = boundingBox(truth)
        let intersection = predictedBox.intersection(truthBox)
        let intersectionArea = intersection.isNull ? 0 : intersection.width * intersection.height
        let unionArea = predictedBox.width * predictedBox.height
            + truthBox.width * truthBox.height - intersectionArea
        return GeometryError(
            iou: unionArea > 0 ? intersectionArea / unionArea : 0,
            meanCornerError: errors.reduce(0, +) / CGFloat(errors.count),
            maxCornerError: errors.max() ?? 0,
            centerError: hypot(predictedBox.midX - truthBox.midX, predictedBox.midY - truthBox.midY))
    }

    private static func boundingBox(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - One measured case

/// A single point in a sweep: what was rendered, what came back, how long.
struct ValidationOutcome: Sendable {
    /// Stable identifier that fully determines the input, so a failure can be
    /// replayed without the report. e.g. "pose/yaw=+30,pitch=0,roll=0/80.8".
    let id: String
    /// Sweep this belongs to ("pose", "degradation", "segment", "motion").
    let sweep: String
    /// Parameter values, for grouping in the report. Keep keys stable.
    let parameters: [String: String]
    let truth: String
    let predicted: String?
    let verdict: ReadingVerdict
    /// nil when the sweep does not measure geometry.
    let geometry: GeometryError?
    let confidence: Float
    let durationMS: Double
}

// MARK: - Report

/// Aggregates outcomes and renders both the human summary and the
/// machine-readable form the regression checker consumes.
struct ValidationReport: Sendable {
    let sweep: String
    let outcomes: [ValidationOutcome]

    var total: Int { outcomes.count }
    var exactRate: Double { rate { $0.verdict.isCorrect } }
    var decimalOnlyFailureRate: Double { rate { $0.verdict.isDecimalOnlyFailure } }
    var detectionRate: Double { rate { $0.verdict != .notDetected } }
    /// Of the readings that were detected at all, how many had every digit
    /// right — separates "could not read it" from "read it wrong".
    var digitAccuracyWhenDetected: Double {
        let detected = outcomes.filter { $0.verdict != .notDetected }
        guard !detected.isEmpty else { return 0 }
        let correctDigits = detected.filter { $0.verdict != .digitError }
        return Double(correctDigits.count) / Double(detected.count)
    }
    var meanIoU: CGFloat? {
        let values = outcomes.compactMap { $0.geometry?.iou }
        return values.isEmpty ? nil : values.reduce(0, +) / CGFloat(values.count)
    }
    var p95DurationMS: Double { percentileDuration(0.95) }
    var maxDurationMS: Double { outcomes.map(\.durationMS).max() ?? 0 }

    private func rate(_ predicate: (ValidationOutcome) -> Bool) -> Double {
        guard !outcomes.isEmpty else { return 0 }
        return Double(outcomes.filter(predicate).count) / Double(outcomes.count)
    }

    private func percentileDuration(_ fraction: Double) -> Double {
        let sorted = outcomes.map(\.durationMS).sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))
        return sorted[index]
    }

    /// Breaks the sweep down by one parameter, which is how a sweep answers
    /// "where does it start failing" rather than just "what is the average".
    func rates(by parameter: String) -> [(value: String, total: Int, exact: Double)] {
        let groups = Dictionary(grouping: outcomes.filter { $0.parameters[parameter] != nil }) {
            $0.parameters[parameter]!
        }
        return groups.map { value, group in
            let exact = Double(group.filter { $0.verdict.isCorrect }.count) / Double(group.count)
            return (value, group.count, exact)
        }
        .sorted { numericIfPossible($0.value, $1.value) }
    }

    /// Sorts "-30" before "-5" before "0" before "5" when the values are
    /// numeric, and alphabetically otherwise — an angle sweep printed in string
    /// order is unreadable.
    private func numericIfPossible(_ a: String, _ b: String) -> Bool {
        if let x = Double(a), let y = Double(b) { return x < y }
        return a < b
    }

    var verdictCounts: [ReadingVerdict: Int] {
        outcomes.reduce(into: [:]) { counts, outcome in
            counts[outcome.verdict, default: 0] += 1
        }
    }

    // MARK: Rendering

    func summary(groupedBy parameter: String? = nil) -> String {
        var lines: [String] = []
        lines.append("=== \(sweep.uppercased()) — \(total) cases ===")
        lines.append(String(format: "  exact           %6.1f%%", exactRate * 100))
        lines.append(String(format: "  detected        %6.1f%%", detectionRate * 100))
        lines.append(String(format: "  digits ok       %6.1f%%  (of detected)", digitAccuracyWhenDetected * 100))
        lines.append(String(format: "  decimal-only    %6.1f%%  <- correct digits, wrong point",
                            decimalOnlyFailureRate * 100))
        if let iou = meanIoU { lines.append(String(format: "  mean IoU        %6.3f", iou)) }
        lines.append(String(format: "  p95 / max       %6.1f ms / %.1f ms", p95DurationMS, maxDurationMS))

        let counts = verdictCounts
        let breakdown = [ReadingVerdict.exact, .decimalMissing, .decimalSpurious,
                         .decimalMisplaced, .digitError, .notDetected]
            .compactMap { verdict in counts[verdict].map { "\(verdict.rawValue)=\($0)" } }
            .joined(separator: "  ")
        lines.append("  verdicts        \(breakdown)")

        if let parameter {
            lines.append("  by \(parameter):")
            for row in rates(by: parameter) {
                let bar = String(repeating: "#", count: Int(row.exact * 30))
                lines.append(String(format: "    %-10@ %3d  %5.1f%% %@",
                                    row.value as NSString, row.total, row.exact * 100, bar as NSString))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Machine-readable form for the regression checker and for archiving a
    /// baseline. Deliberately hand-rolled rather than `Codable` + JSONEncoder:
    /// key order is fixed, so two baselines diff cleanly in git.
    func jsonLines() -> String {
        outcomes.map { outcome in
            let params = outcome.parameters.keys.sorted()
                .map { "\"\($0)\":\"\(outcome.parameters[$0]!)\"" }
                .joined(separator: ",")
            let predicted = outcome.predicted.map { "\"\($0)\"" } ?? "null"
            let iou = outcome.geometry.map { String(format: "%.4f", $0.iou) } ?? "null"
            return "{\"id\":\"\(outcome.id)\",\"sweep\":\"\(outcome.sweep)\",\"params\":{\(params)},"
                + "\"truth\":\"\(outcome.truth)\",\"predicted\":\(predicted),"
                + "\"verdict\":\"\(outcome.verdict.rawValue)\",\"iou\":\(iou),"
                + String(format: "\"confidence\":%.3f,\"ms\":%.2f}", outcome.confidence, outcome.durationMS)
        }.joined(separator: "\n")
    }
}

// MARK: - Deterministic sampling

/// Seeded PRNG so randomized sweeps replay exactly. `SystemRandomNumberGenerator`
/// cannot, and a sweep whose failures cannot be reproduced is not a test.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { self.state = seed &* 2862933555777941757 &+ 3037000493 }

    mutating func next() -> UInt64 {
        // splitmix64 — small, fast, well-distributed, and trivially portable so
        // a seed means the same sequence on any machine that runs the suite.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
