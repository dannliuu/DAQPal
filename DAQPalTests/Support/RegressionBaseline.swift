//
//  RegressionBaseline.swift
//  DAQPalTests
//
//  Turns a `ValidationReport` into a committed, diffable snapshot and compares
//  a fresh run against it. The point is that an OCR change stops being an
//  opinion: the sweep runs, the numbers land next to the recorded ones, and the
//  suite says which metric moved and by how much.
//
//  WHY A HAND-ROLLED TEXT FORMAT. These files live in git and are read in pull
//  requests. `JSONEncoder` gives no key-order guarantee across releases and
//  prints doubles at full precision, so an unchanged sweep can still produce a
//  diff — and a baseline that diffs spuriously is one people stop reading.
//  Fixed key order, fixed decimal places, one metric per line.
//
//  WHY RE-RECORDING IS DELIBERATELY AWKWARD. A regression checker only works
//  while updating it is more expensive than fixing the code. `record` refuses
//  to write unless the process environment names the exact baseline being
//  replaced, so no test run, no `--fix` flag and no accidental save can rewrite
//  a number that someone chose on purpose. See `BaselineRecording`.
//

import CoreGraphics
import Foundation

// MARK: - Metrics

/// The metrics a baseline pins. Declaration order is the serialization order,
/// so adding a metric appends a line rather than reshuffling every file.
enum BaselineMetric: String, CaseIterable, Sendable {
    case exactRate
    case digitAccuracy
    case decimalAccuracy
    case detectionRate
    case meanIoU
    case p95LatencyMS

    /// Wording used in the failure report. "OCR accuracy" rather than
    /// "exactRate" because the report is read by whoever broke the build, not
    /// by whoever wrote this file.
    var label: String {
        switch self {
        case .exactRate: return "OCR accuracy"
        case .digitAccuracy: return "Digit accuracy"
        case .decimalAccuracy: return "Decimal accuracy"
        case .detectionRate: return "Detection rate"
        case .meanIoU: return "Mean IoU"
        case .p95LatencyMS: return "p95 latency"
        }
    }

    /// Latency is compared by ratio and printed in milliseconds; every other
    /// metric is a 0...1 rate compared by absolute drop and printed as a
    /// percentage. IoU is a ratio too, but it is an accuracy, so it is graded
    /// with the accuracy rules.
    var isLatency: Bool { self == .p95LatencyMS }

    /// Higher is better for every metric except latency. Encoded here so the
    /// comparison never has to special-case direction at the call site.
    var higherIsBetter: Bool { !isLatency }
}

// MARK: - Baseline

/// A named snapshot of one sweep's numbers.
struct RegressionBaseline: Equatable, Sendable {
    /// Also the file stem. Restricted to a slug so a name can never walk out of
    /// the baselines directory.
    let name: String
    /// Number of cases behind the rates. Carried because the right tolerance
    /// depends on it: one case flipping in a 40-case sweep is 2.5%, in a
    /// 200-case sweep 0.5%.
    let caseCount: Int
    let exactRate: Double
    let digitAccuracy: Double
    let decimalAccuracy: Double
    let detectionRate: Double
    /// nil for sweeps that do not measure geometry — a missing measurement is
    /// not the same as an IoU of zero, and recording it as zero would make
    /// every geometry-free sweep look like a total detector failure.
    let meanIoU: Double?
    let p95LatencyMS: Double

    init(name: String,
         caseCount: Int,
         exactRate: Double,
         digitAccuracy: Double,
         decimalAccuracy: Double,
         detectionRate: Double,
         meanIoU: Double?,
         p95LatencyMS: Double) {
        self.name = name
        self.caseCount = caseCount
        self.exactRate = exactRate
        self.digitAccuracy = digitAccuracy
        self.decimalAccuracy = decimalAccuracy
        self.detectionRate = detectionRate
        self.meanIoU = meanIoU
        self.p95LatencyMS = p95LatencyMS
    }

    /// Snapshots a sweep.
    ///
    /// `decimalAccuracy` is deliberately conditioned on the digits being right:
    /// it is the share of digit-correct readings whose decimal point also
    /// landed correctly. Measured over all outcomes instead, it would fall
    /// whenever digit recognition got worse, and a decimal regression would be
    /// indistinguishable from a glyph regression — which is the exact
    /// conflation `ReadingVerdict` exists to prevent.
    init(name: String, report: ValidationReport) {
        let counts = report.verdictCounts
        let exact = counts[.exact] ?? 0
        let decimalOnly = (counts[.decimalMissing] ?? 0)
            + (counts[.decimalSpurious] ?? 0)
            + (counts[.decimalMisplaced] ?? 0)
        let digitCorrect = exact + decimalOnly
        self.init(name: name,
                  caseCount: report.total,
                  exactRate: report.exactRate,
                  digitAccuracy: report.digitAccuracyWhenDetected,
                  decimalAccuracy: digitCorrect > 0 ? Double(exact) / Double(digitCorrect) : 1,
                  detectionRate: report.detectionRate,
                  meanIoU: report.meanIoU.map(Double.init),
                  p95LatencyMS: report.p95DurationMS)
    }

    func value(for metric: BaselineMetric) -> Double? {
        switch metric {
        case .exactRate: return exactRate
        case .digitAccuracy: return digitAccuracy
        case .decimalAccuracy: return decimalAccuracy
        case .detectionRate: return detectionRate
        case .meanIoU: return meanIoU
        case .p95LatencyMS: return p95LatencyMS
        }
    }
}

// MARK: - Serialization

extension RegressionBaseline {
    /// Bumped only when the on-disk shape changes incompatibly, so a stale file
    /// fails loudly instead of being read with the wrong meaning.
    static let formatVersion = 1

    /// Rates carry six decimals: enough to represent 1/N exactly enough for any
    /// corpus this suite will run, few enough that float noise in the last bit
    /// never reaches the file.
    private static let rateDecimals = 6
    /// Latency at microsecond resolution. Anything finer is Debug-run jitter.
    private static let latencyDecimals = 3

    private static let header =
        "# DAQPal regression baseline. Generated — do not hand-edit.\n"
        + "# Re-record with: DAQPAL_RECORD_BASELINE=<name> (see BaselineRecording)."

    func serialized() -> String {
        var lines = [RegressionBaseline.header]
        lines.append("format: \(RegressionBaseline.formatVersion)")
        lines.append("name: \(name)")
        lines.append("cases: \(caseCount)")
        for metric in BaselineMetric.allCases {
            lines.append("\(metric.rawValue): \(RegressionBaseline.format(value(for: metric), metric: metric))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// An absent optional writes as `none` rather than being omitted: a line
    /// that vanishes reads in a diff like a deleted metric, a line that says
    /// `none` reads like what it is.
    private static func format(_ value: Double?, metric: BaselineMetric) -> String {
        guard let value else { return "none" }
        let decimals = metric.isLatency ? latencyDecimals : rateDecimals
        return String(format: "%.\(decimals)f", value)
    }

    init(serialized text: String) throws {
        var fields: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: ":") else {
                throw BaselineFormatError.malformedLine(String(line))
            }
            let key = String(line[line.startIndex..<separator])
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let versionText = fields["format"], let version = Int(versionText) else {
            throw BaselineFormatError.missingField("format")
        }
        guard version == RegressionBaseline.formatVersion else {
            throw BaselineFormatError.unsupportedVersion(version)
        }
        guard let name = fields["name"], !name.isEmpty else {
            throw BaselineFormatError.missingField("name")
        }
        guard let caseText = fields["cases"], let caseCount = Int(caseText) else {
            throw BaselineFormatError.missingField("cases")
        }

        func number(_ metric: BaselineMetric) throws -> Double {
            guard let text = fields[metric.rawValue] else {
                throw BaselineFormatError.missingField(metric.rawValue)
            }
            guard let value = Double(text) else {
                throw BaselineFormatError.malformedLine("\(metric.rawValue): \(text)")
            }
            return value
        }
        func optionalNumber(_ metric: BaselineMetric) throws -> Double? {
            guard let text = fields[metric.rawValue] else {
                throw BaselineFormatError.missingField(metric.rawValue)
            }
            if text == "none" { return nil }
            guard let value = Double(text) else {
                throw BaselineFormatError.malformedLine("\(metric.rawValue): \(text)")
            }
            return value
        }

        self.init(name: name,
                  caseCount: caseCount,
                  exactRate: try number(.exactRate),
                  digitAccuracy: try number(.digitAccuracy),
                  decimalAccuracy: try number(.decimalAccuracy),
                  detectionRate: try number(.detectionRate),
                  meanIoU: try optionalNumber(.meanIoU),
                  p95LatencyMS: try number(.p95LatencyMS))
    }
}

enum BaselineFormatError: Error, Equatable {
    case missingField(String)
    case malformedLine(String)
    case unsupportedVersion(Int)
    /// A name that is not a slug, which would let a caller write outside the
    /// baselines directory.
    case invalidName(String)
    case notRecorded(String)
    /// `record` was called without the environment naming this baseline.
    case recordingNotAuthorized(String)
}

// MARK: - Thresholds

/// Per-metric tolerance for the comparison. Every value has a documented
/// derivation; none of them is a round number picked to make a run pass.
struct RegressionThresholds: Sendable, Equatable {
    /// Absolute drop tolerated in `exactRate`, `digitAccuracy`,
    /// `decimalAccuracy` and `meanIoU`.
    ///
    /// DERIVATION. The sweeps in this repo run on the order of 200 synthetic
    /// cases, so one case changing verdict moves a rate by 1/200 = 0.5%. Cases
    /// sit right on tie-breaks — a glyph that scores 0.500 against two
    /// templates, a decimal blob one pixel from the rescue threshold — and an
    /// unrelated change can tip two or three of them without meaning anything.
    /// A tolerance at or below single-case resolution therefore fires on noise,
    /// and a checker that cries wolf gets re-recorded reflexively, which is the
    /// same as not having one. 2% is four cases in a 200-case sweep: too many
    /// to be tie-break churn, small enough that any change with a real cause
    /// clears it. Sweeps that are much smaller or much larger should call
    /// `forCorpus(size:)` instead of inheriting this number.
    var accuracyDrop: Double = 0.02

    /// Detection is held tighter than recognition. Failing to find the display
    /// at all costs the reading outright and cannot be recovered downstream by
    /// temporal consensus, whereas a single misread digit can. Two cases in
    /// 200.
    var detectionDrop: Double = 0.01

    /// Multiple of the baseline p95 tolerated before latency counts as a
    /// regression.
    ///
    /// DERIVATION. Latency here is measured in DEBUG on whatever machine runs
    /// the suite, where per-pixel Swift runs up to ~50x slower than Release, so
    /// these numbers are not shipping costs and their run-to-run spread is
    /// dominated by the host: other Xcode builds, Spotlight, simulator warm-up.
    /// Timings routinely move tens of percent between runs of unchanged code.
    /// The tolerance is therefore a factor, not the fraction-of-a-percent
    /// tolerance the accuracy metrics get: 1.5x catches an algorithmic change
    /// (an extra full-frame pass, a second Vision request) while ignoring the
    /// machine. Real performance budgets belong in `PipelineBudgetTests`
    /// against a Release build; this check only guards against order-of-
    /// magnitude drift in the sweeps.
    var latencyGrowthFactor: Double = 1.5

    /// Absolute slack added under the factor, so sub-millisecond baselines do
    /// not fail on timer granularity: 0.4 ms -> 0.7 ms is 1.75x and means
    /// nothing.
    var latencyFloorMS: Double = 5.0

    static let `default` = RegressionThresholds()

    /// Tolerance scaled to a corpus, for sweeps that are not ~200 cases.
    ///
    /// Keeps the rule that drives `accuracyDrop` — a handful of cases must flip
    /// before it counts — rather than the number that rule produced at N=200.
    /// The default floor stays in force so a tiny corpus cannot demand
    /// impossible stability.
    static func forCorpus(size: Int, allowedCaseFlips: Int = 4) -> RegressionThresholds {
        guard size > 0 else { return .default }
        var thresholds = RegressionThresholds()
        thresholds.accuracyDrop = max(RegressionThresholds.default.accuracyDrop,
                                      Double(allowedCaseFlips) / Double(size))
        thresholds.detectionDrop = max(RegressionThresholds.default.detectionDrop,
                                       Double(max(1, allowedCaseFlips / 2)) / Double(size))
        return thresholds
    }

    /// Worst value of `metric` that is still acceptable given the baseline.
    func acceptableValue(for metric: BaselineMetric, baseline: Double) -> Double {
        switch metric {
        case .p95LatencyMS:
            return max(baseline * latencyGrowthFactor, baseline + latencyFloorMS)
        case .detectionRate:
            return baseline - detectionDrop
        case .exactRate, .digitAccuracy, .decimalAccuracy, .meanIoU:
            return baseline - accuracyDrop
        }
    }

    /// Relative slack the metric gets at a given baseline value, which is what
    /// makes "latency is compared more loosely than accuracy" checkable rather
    /// than merely asserted in a comment.
    func relativeTolerance(for metric: BaselineMetric, baseline: Double) -> Double {
        guard baseline > 0 else { return .infinity }
        return abs(acceptableValue(for: metric, baseline: baseline) - baseline) / baseline
    }
}

// MARK: - Comparison

/// One metric that moved past its tolerance.
struct MetricRegression: Equatable, Sendable {
    let metric: BaselineMetric
    let baseline: Double
    /// nil when the current run did not measure the metric at all. Distinct
    /// from a measured zero.
    let current: Double?
    /// Worst value that would have been accepted, so the report can say how
    /// much room there was.
    let acceptable: Double

    var line: String {
        guard let current else {
            return "\(metric.label): baseline \(MetricRegression.text(baseline, metric)) -> current not measured"
        }
        return "\(metric.label): baseline \(MetricRegression.text(baseline, metric))"
            + " -> current \(MetricRegression.text(current, metric))"
            + " (tolerance \(MetricRegression.text(acceptable, metric)))"
    }

    static func text(_ value: Double, _ metric: BaselineMetric) -> String {
        metric.isLatency
            ? String(format: "%.1f ms", value)
            : String(format: "%.1f%%", value * 100)
    }
}

/// Result of checking a run against its baseline.
struct RegressionVerdict: Equatable, Sendable {
    let baselineName: String
    let baseline: RegressionBaseline
    let current: RegressionBaseline
    /// Ordered by `BaselineMetric.allCases`, so the report reads the same way
    /// every time.
    let regressions: [MetricRegression]

    var hasRegression: Bool { !regressions.isEmpty }
    func regressed(_ metric: BaselineMetric) -> Bool { regressions.contains { $0.metric == metric } }

    /// The message an engineer sees when the suite goes red. Leads with the
    /// top-line accuracy in both runs — that is the number anyone asks for
    /// first — then names every metric that actually moved.
    func report() -> String {
        var lines: [String] = []
        lines.append("Baseline \(BaselineMetric.exactRate.label): "
                     + MetricRegression.text(baseline.exactRate, .exactRate))
        lines.append("Current  \(BaselineMetric.exactRate.label): "
                     + MetricRegression.text(current.exactRate, .exactRate))
        guard hasRegression else {
            lines.append("NO REGRESSION (\(baselineName), \(current.caseCount) cases)")
            return lines.joined(separator: "\n")
        }
        lines.append("REGRESSION DETECTED")
        for regression in regressions { lines.append(regression.line) }
        if baseline.caseCount != current.caseCount {
            // A changed corpus makes every rate above incomparable, and that is
            // a far more likely explanation than a real regression.
            lines.append("Corpus size changed: \(baseline.caseCount) -> \(current.caseCount) cases;"
                         + " rates are not comparable across different corpora.")
        }
        lines.append("If this is a deliberate improvement, re-record the baseline:"
                     + " \(BaselineRecording.environmentKey)=\(baselineName)")
        return lines.joined(separator: "\n")
    }
}

enum RegressionCheck {
    /// Compares `current` against `baseline`. Improvements are silent by
    /// design: this gate exists to stop a change getting worse, and treating a
    /// gain as a failure would push people to re-record on every win, which is
    /// how a baseline drifts without anyone deciding to move it.
    static func run(baseline: RegressionBaseline,
                    current: RegressionBaseline,
                    thresholds: RegressionThresholds = .default) -> RegressionVerdict {
        var regressions: [MetricRegression] = []
        for metric in BaselineMetric.allCases {
            guard let baselineValue = baseline.value(for: metric) else { continue }
            let acceptable = thresholds.acceptableValue(for: metric, baseline: baselineValue)
            guard let currentValue = current.value(for: metric) else {
                // The baseline pinned it and the run stopped producing it. Not
                // silently ignorable: a sweep that quietly stopped measuring
                // geometry looks identical to one that never did.
                regressions.append(MetricRegression(metric: metric,
                                                    baseline: baselineValue,
                                                    current: nil,
                                                    acceptable: acceptable))
                continue
            }
            let regressed = metric.higherIsBetter ? currentValue < acceptable : currentValue > acceptable
            if regressed {
                regressions.append(MetricRegression(metric: metric,
                                                    baseline: baselineValue,
                                                    current: currentValue,
                                                    acceptable: acceptable))
            }
        }
        return RegressionVerdict(baselineName: baseline.name,
                                 baseline: baseline,
                                 current: current,
                                 regressions: regressions)
    }
}

// MARK: - Storage

/// Reads and writes baseline files.
///
/// Files live in the SOURCE tree, not the test bundle: they are reviewed in
/// pull requests alongside the change that moved them, so the path that matters
/// is the one git sees. `#filePath` locates it, which also means a baseline
/// written by a recording run lands where it can be committed instead of inside
/// a derived-data directory nobody looks in.
struct BaselineStore: Sendable {
    let directory: URL

    static let fileExtension = "baseline"

    static var repositoryDirectory: URL {
        URL(fileURLWithPath: #filePath)          // .../DAQPalTests/Support/RegressionBaseline.swift
            .deletingLastPathComponent()         // .../DAQPalTests/Support
            .deletingLastPathComponent()         // .../DAQPalTests
            .appendingPathComponent("Baselines", isDirectory: true)
    }

    init(directory: URL = BaselineStore.repositoryDirectory) {
        self.directory = directory
    }

    /// Names are slugs so `name` can never contain a path component. A baseline
    /// name arrives from a sweep's own identifier, and the recorder writes with
    /// whatever privileges the test process has.
    static func validate(name: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw BaselineFormatError.invalidName(name)
        }
    }

    func fileURL(for name: String) throws -> URL {
        try BaselineStore.validate(name: name)
        return directory.appendingPathComponent("\(name).\(BaselineStore.fileExtension)")
    }

    func exists(_ name: String) -> Bool {
        guard let url = try? fileURL(for: name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func load(_ name: String) throws -> RegressionBaseline {
        let url = try fileURL(for: name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw BaselineFormatError.notRecorded(name)
        }
        return try RegressionBaseline(serialized: text)
    }

    /// Writes a baseline. Requires an authorization token, which only
    /// `BaselineRecording` can mint and only when the environment names this
    /// exact baseline — see the file header for why this is not a flag.
    @discardableResult
    func record(_ baseline: RegressionBaseline, authorization: RecordAuthorization) throws -> URL {
        guard authorization.baselineName == baseline.name else {
            throw BaselineFormatError.recordingNotAuthorized(baseline.name)
        }
        let url = try fileURL(for: baseline.name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try baseline.serialized().write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Proof that a human asked for this specific baseline to be overwritten.
/// Unforgeable outside this file, so `record` cannot be reached by a helper
/// that "just" wants to keep the file fresh.
struct RecordAuthorization: Equatable, Sendable {
    let baselineName: String
    fileprivate init(baselineName: String) { self.baselineName = baselineName }
}

/// The update path.
///
/// To re-record a baseline after a deliberate improvement:
///
///     DAQPAL_RECORD_BASELINE=pose-sweep xcodebuild test ... \
///       -only-testing:DAQPalTests/RegressionBaselineTests
///
/// then commit the changed file in `DAQPalTests/Baselines/` in the SAME commit
/// as the change that moved it, so review sees the new numbers next to their
/// cause.
///
/// The variable must name one baseline exactly. `=1`, `=true` and `=all` are
/// rejected on purpose: a blanket switch would let one distracted run rewrite
/// every recorded number in the repo, which is precisely the failure this
/// system exists to prevent. Recording several baselines takes several runs.
enum BaselineRecording {
    static let environmentKey = "DAQPAL_RECORD_BASELINE"

    /// Values that look like a global "yes". Refused so nobody discovers that
    /// `=1` works and never learns the per-baseline form.
    private static let refusedWildcards: Set<String> = ["1", "true", "yes", "all", "*", "on"]

    static func authorization(
        for name: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> RecordAuthorization? {
        guard let requested = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !requested.isEmpty else { return nil }
        guard !refusedWildcards.contains(requested.lowercased()) else { return nil }
        guard requested == name, (try? BaselineStore.validate(name: name)) != nil else { return nil }
        return RecordAuthorization(baselineName: name)
    }

    /// Instructions printed next to a missing or regressed baseline, so the
    /// only documentation anyone needs is in the failure they are already
    /// reading.
    static func instructions(for name: String) -> String {
        "\(environmentKey)=\(name) xcodebuild test -only-testing:DAQPalTests/RegressionBaselineTests"
            + " — then commit DAQPalTests/Baselines/\(name).\(BaselineStore.fileExtension)"
            + " alongside the change that moved it."
    }
}
