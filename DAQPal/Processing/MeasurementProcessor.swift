//
//  MeasurementProcessor.swift
//  DAQPal
//
//  The pure recognition/validation pipeline (spec §40.3). An actor so it
//  naturally serialises frames — while one frame is being recognised, the next
//  is dropped upstream (AVFoundation `alwaysDiscardsLateVideoFrames`), which is
//  the backpressure mechanism (spec §20 / §40.2). Reentrancy note: correctness
//  of per-device validator state relies on the single-serial-consumer contract
//  (`FrameProcessor` awaits each `process` before the next); all mutable
//  validator work happens in a synchronous stretch AFTER the only `await`
//  (recognition), so no state is torn across a suspension point.
//
//  Within ONE `process` call, per-device recognition fans out concurrently —
//  the child tasks are static/pure (no actor state) and only READ the shared
//  `CVPixelBuffer` (Vision and CoreImage do their own internal locking for
//  reads), which stays inside the frame's linear-ownership rule: one consumer
//  (this actor) owns the frame for the duration of the call.
//
//  Per frame, per configured device:
//    crop → OCR (whole-ROI) → best numeric candidate → FormatValidator →
//    [classical seven-segment cross-check] → PhysicalValidator →
//    TemporalFilter → ConfidenceEngine → Measurement.
//  Any crop/text failure becomes a rejected Measurement (never a throw).
//
//  The cross-check (OCR_RESEARCH.md Phase 4) runs in the concurrent recognition
//  stage on CONSTRAINED devices only: a deterministic `SevenSegmentSampler`
//  reads the same ROI independently and its verdict is fused as a
//  corroborate-or-veto factor (never inflating) in `ConfidenceEngine`. It
//  abstains (neutral) whenever it cannot cleanly read every digit cell — so on
//  non-segment glyphs (raster/OLED) it never manufactures a disagreement.
//

import CoreVideo
import Foundation

actor MeasurementProcessor {
    /// When true, value + `digitConfidences` come from the digit-cell path
    /// (`DigitSegmenter` + `DigitRecognizer`) instead of whole-ROI OCR. Default
    /// OFF: the fixed-pitch segmenter is a stub pending real display-geometry
    /// work (spec §11, Milestone 11+); whole-ROI Vision is the trustworthy path
    /// today. Kept as a seam so the digit-level architecture stays wired.
    var useDigitLevelRecognition = false

    private let ocr = OCRManager()
    private let segmenter = DigitSegmenter()
    private let digitRecognizer = DigitRecognizer()
    private let confidenceEngine = ConfidenceEngine()

    /// Devices with a confirmed ROI, in display order (index 0 drives debug).
    private var configs: [DeviceRecognitionConfig] = []
    private var physicalValidators: [UUID: PhysicalValidator] = [:]
    private var temporalFilters: [UUID: TemporalFilter] = [:]
    /// Anti flip-flop consensus per device (spec §11A part 2). Per its own
    /// header's contract: `TemporalFilter` feeds the confidence product above;
    /// `TemporalConsensus` gates the PUBLISHED reading — a fuse-accepted frame
    /// whose written form the window does not support is demoted to a rejected
    /// measurement rather than surfaced.
    private var consensus: [UUID: TemporalConsensus] = [:]
    /// Format each device's validators were built for; a change rebuilds them
    /// (signatures and rate limits are format-dependent).
    private var formatByID: [UUID: DisplayFormat] = [:]

    init() {}

    /// Replaces the active device set. Per-device validator state is preserved
    /// for devices whose format is unchanged (so adding/removing one device
    /// doesn't reset another's temporal/rate history) and rebuilt for new or
    /// re-formatted devices. State for removed devices is dropped.
    func update(devices: [DeviceRecognitionConfig]) {
        let ids = Set(devices.map(\.id))
        physicalValidators = physicalValidators.filter { ids.contains($0.key) }
        temporalFilters = temporalFilters.filter { ids.contains($0.key) }
        consensus = consensus.filter { ids.contains($0.key) }
        formatByID = formatByID.filter { ids.contains($0.key) }

        for device in devices where formatByID[device.id] != device.format {
            physicalValidators[device.id] = PhysicalValidator(format: device.format)
            temporalFilters[device.id] = TemporalFilter(format: device.format)
            consensus[device.id] = TemporalConsensus()
            formatByID[device.id] = device.format
        }
        configs = devices
    }

    /// Clears all temporal/rate history (e.g. at the start of a recording) while
    /// keeping the device set and formats.
    func resetTemporalState() {
        physicalValidators.removeAll()
        temporalFilters.removeAll()
        consensus.removeAll()
        for device in configs {
            physicalValidators[device.id] = PhysicalValidator(format: device.format)
            temporalFilters[device.id] = TemporalFilter(format: device.format)
            consensus[device.id] = TemporalConsensus()
        }
    }

    /// Processes one frame across all configured devices. Never throws.
    ///
    /// Two stages: recognition fans out concurrently (it is pure — Vision and
    /// CoreImage only READ the shared frame and touch no actor state), then
    /// validation runs as one synchronous stretch in stable config order. This
    /// keeps the sample rate from dividing by device count while preserving
    /// the no-await validator-mutation rule above.
    /// Per-frame ROI overrides, keyed by device/field id.
    ///
    /// The intelligent pipeline derives a field's frame-space region from the
    /// LIVE tracked geometry every frame, so its ROI is not a stored property
    /// of the device — it changes as the display moves. Pushing that through
    /// `update(devices:)` once per frame would mean an actor round-trip and a
    /// full config rebuild per frame, and would race the pushed value against
    /// the frame it was computed for. Passing it alongside the frame keeps the
    /// geometry and the pixels it was measured from together.
    ///
    /// Devices absent from the map keep their configured ROI — which is what
    /// preserves the manual workflow untouched.
    /// - Parameter requiringOverride: devices whose ROI is ONLY valid when
    ///   supplied per frame (field-backed devices, whose geometry is a
    ///   projection of a tracked target). Any such device without an override
    ///   this frame is skipped entirely rather than recognized against its
    ///   placeholder ROI — reading the placeholder would report whatever
    ///   happened to sit at a fixed location as if it were the tracked field.
    /// - Parameter trackingValid: `ScreenLockUpdate.measurementsValid` — true
    ///   only while the tracked geometry is both healthy and independently
    ///   verified. When false, every device in `requiringOverride` produces a
    ///   REJECTED measurement (`.trackingInvalid`) instead of silence, and any
    ///   override that somehow arrived alongside the invalid flag is ignored
    ///   (Phase 14 invariant: `TrackingHealthy = false ⇒ MeasurementValid =
    ///   false`, even at 99% OCR confidence). Rejected readings are logged,
    ///   never dropped. Defaults to true so manual-only call sites (video
    ///   import, harvester, tests) are untouched.
    func process(frame: TimestampedFrame,
                 roiOverrides: [UUID: NormalizedROI] = [:],
                 requiringOverride: Set<UUID> = [],
                 trackingValid: Bool = true) async -> FrameResult {
        guard !configs.isEmpty else {
            return FrameResult(timestamp: frame.timestamp, readings: [:], debugText: nil)
        }

        // Tracking-invalidity gate: a field-backed device under invalid
        // tracking is observable end to end as a rejected measurement, not a
        // hole in the record. Computed before job construction so the early
        // "no jobs" exit below still reports these rejections.
        var gatedReadings: [UUID: Measurement] = [:]
        if !trackingValid {
            for config in configs where requiringOverride.contains(config.id) {
                gatedReadings[config.id] = .rejected(timestamp: frame.timestamp,
                                                     reason: .trackingInvalid,
                                                     unit: config.format.unit)
            }
        }

        let jobs: [DeviceRecognitionConfig]
        if roiOverrides.isEmpty && requiringOverride.isEmpty {
            jobs = configs
        } else {
            jobs = configs.compactMap { config in
                guard gatedReadings[config.id] == nil else { return nil }
                if let override = roiOverrides[config.id] {
                    return DeviceRecognitionConfig(id: config.id, roi: override, format: config.format)
                }
                return requiringOverride.contains(config.id) ? nil : config
            }
        }
        guard !jobs.isEmpty else {
            return FrameResult(timestamp: frame.timestamp, readings: gatedReadings, debugText: nil)
        }
        let useDigits = useDigitLevelRecognition
        let ocr = self.ocr
        let segmenter = self.segmenter
        let digitRecognizer = self.digitRecognizer

        var outcomes: [UUID: RecognitionOutcome] = [:]
        await withTaskGroup(of: (UUID, RecognitionOutcome).self) { group in
            for config in jobs {
                group.addTask {
                    (config.id, await Self.recognize(config: config,
                                                     frame: frame,
                                                     useDigits: useDigits,
                                                     ocr: ocr,
                                                     segmenter: segmenter,
                                                     digitRecognizer: digitRecognizer))
                }
            }
            for await (id, outcome) in group { outcomes[id] = outcome }
        }

        // --- no awaits below: validator mutation is a single sync stretch ---
        var readings: [UUID: Measurement] = gatedReadings
        var observedROIs: [UUID: NormalizedROI] = [:]
        var debugText: String?
        for (index, config) in jobs.enumerated() {
            guard let outcome = outcomes[config.id] else { continue }
            let result = finalizeOutcome(outcome, config: config, timestamp: frame.timestamp)
            readings[config.id] = result.measurement
            // Publish the observed text box only for ACCEPTED readings — ROI
            // auto-tracking follows it, so a rejected/lost frame must never move
            // the window.
            if result.measurement.accepted, let observedROI = result.observedROI {
                observedROIs[config.id] = observedROI
            }
            if index == 0 { debugText = result.debug }
        }
        return FrameResult(timestamp: frame.timestamp,
                           readings: readings,
                           debugText: debugText,
                           observedROIs: observedROIs)
    }

    // MARK: - Recognition stage (concurrent, pure)

    /// The classical seven-segment cross-check for one whole-ROI reading,
    /// carried alongside the parsed value and resolved into a `CrossCheckOutcome`
    /// at finalize time (agreement needs the OCR value to compare against).
    /// `.abstained` whenever the sampler could not cleanly read every digit
    /// cell, the format is unconstrained, or the digit-level path was used —
    /// abstention is neutral, never a veto.
    private enum SamplerCrossCheck: Sendable {
        case abstained
        case read(value: Double, confidence: Float)
    }

    /// What recognition produced for one device, before any validator state is
    /// consulted — lets the concurrent stage stay free of actor-state access.
    private enum RecognitionOutcome {
        case lost(debug: String?)
        case ambiguous(rawText: String?, digitConfidences: [Float], debug: String?)
        /// `reason` carries the validator's OWN verdict rather than a hardcoded
        /// `.invalidFormat`. Without it a correctly-detected `.ambiguousDecimal`
        /// was flattened to a generic format mismatch on its way to the UI, so
        /// the user could never see that a decimal was the problem.
        case invalidFormat(rawText: String?, digitConfidences: [Float]?,
                           reason: RejectionReason, debug: String?)
        case parsed(value: Double, ocrConfidence: Float, rawText: String,
                    digitConfidences: [Float]?, boundingBox: NormalizedROI?,
                    samplerCrossCheck: SamplerCrossCheck,
                    decimal: DecimalAnalysis?, displayText: String?, debug: String?)
    }

    private static func recognize(config: DeviceRecognitionConfig,
                                  frame: TimestampedFrame,
                                  useDigits: Bool,
                                  ocr: OCRManager,
                                  segmenter: DigitSegmenter,
                                  digitRecognizer: DigitRecognizer) async -> RecognitionOutcome {
        if useDigits {
            guard let crop = PixelBufferROI.cropped(frame.pixelBuffer, to: config.roi) else {
                return .lost(debug: "Detected: —")
            }
            return await recognizeDigitLevel(config: config, crop: crop,
                                             segmenter: segmenter,
                                             digitRecognizer: digitRecognizer)
        }
        return await recognizeWholeROI(config: config, frame: frame, ocr: ocr)
    }

    /// Whole-ROI path (default): the best OCR candidate that satisfies the
    /// format grammar wins — the essence of format-aware OCR (spec §3). The ROI
    /// is passed as Vision's `regionOfInterest` over the shared frame — no
    /// per-device buffer crop/allocation.
    private static func recognizeWholeROI(config: DeviceRecognitionConfig,
                                          frame: TimestampedFrame,
                                          ocr: OCRManager) async -> RecognitionOutcome {
        let format = config.format
        let candidates = (try? await ocr.recognize(in: frame.pixelBuffer,
                                                   regionOfInterest: config.roi)) ?? []
        guard let top = candidates.first else {
            return .lost(debug: "Detected: —")
        }

        // Candidates are confidence-sorted; take the highest-confidence one that
        // satisfies the configured recognition mode — strict grammar when the
        // format is constrained, lenient numeric extraction when it is not
        // (spec Mode 2 vs Mode 3). `FormatValidator.value(from:format:)`
        // dispatches on `format.constrainToFormat`.
        // `reading(from:)` rather than `value(from:)`: the richer entry point
        // returns the decimal analysis alongside the value, which is what makes
        // decimal confidence fusible downstream. `value(from:)` discards it.
        var chosen: (candidate: OCRCandidate, reading: NumericReading)?
        var firstRejection: RejectionReason?
        for candidate in candidates {
            switch FormatValidator.reading(from: candidate.text, format: format) {
            case .valid(let reading):
                chosen = (candidate, reading)
            case .invalid(let reason):
                if firstRejection == nil { firstRejection = reason }
            }
            if chosen != nil { break }
        }

        let display = chosen?.candidate ?? top
        let debug = debugString(text: display.text, unit: format.unit, confidence: display.confidence)

        guard let chosen else {
            return .invalidFormat(rawText: top.text,
                                  digitConfidences: nil,
                                  reason: firstRejection ?? .invalidFormat,
                                  debug: debug)
        }

        // Classical seven-segment cross-check — an independent, ML-free reader of
        // the SAME frame, fused later as a corroborate-or-veto factor (never
        // inflating). Constrained formats only: an unconstrained device has no
        // digit grammar to segment against, so the sampler cannot be scored and
        // abstains (neutral).
        let crossCheck: SamplerCrossCheck = format.constrainToFormat
            ? samplerCrossCheck(config: config, frame: frame)
            : .abstained

        return .parsed(value: chosen.reading.value,
                       ocrConfidence: chosen.candidate.confidence,
                       rawText: chosen.candidate.text,
                       digitConfidences: nil,
                       boundingBox: chosen.candidate.boundingBox,
                       samplerCrossCheck: crossCheck,
                       decimal: chosen.reading.decimal,
                       displayText: chosen.reading.text,
                       debug: debug)
    }

    /// Digit-cell path (opt-in): reconstruct the value from per-cell 0–9
    /// recognition, carrying per-position confidences. Sign is not detected on
    /// this path (see `DigitSegmenter`); unresolved cells reject as
    /// `.ambiguousDigit`.
    private static func recognizeDigitLevel(config: DeviceRecognitionConfig,
                                            crop: CVPixelBuffer,
                                            segmenter: DigitSegmenter,
                                            digitRecognizer: DigitRecognizer) async -> RecognitionOutcome {
        let format = config.format
        let cropSpace = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let cells = segmenter.digitCells(in: cropSpace, format: format)
        let digitResults = await digitRecognizer.recognizeDigits(in: crop, cells: cells)
        let confidences = digitResults.map(\.confidence)
        let meanConfidence = confidences.isEmpty ? 0
            : confidences.reduce(0, +) / Float(confidences.count)

        if digitResults.isEmpty || digitResults.contains(where: { $0.digit == nil }) {
            let partial = String(digitResults.map { $0.digit ?? "?" })
            return .ambiguous(rawText: partial, digitConfidences: confidences,
                              debug: "Detected: \(partial.isEmpty ? "—" : partial) (ambiguous)")
        }

        let digits = String(digitResults.compactMap(\.digit))
        let text = reconstruct(digits: digits, format: format)
        let debug = debugString(text: text, unit: format.unit, confidence: meanConfidence)

        // Route the reconstructed string through the same mode dispatcher as the
        // whole-ROI path. The digit path is crop-based with no text localization,
        // so it carries no bounding box for ROI tracking.
        let digitReading = FormatValidator.reading(from: text, format: format)
        guard case .valid(let reading) = digitReading else {
            let reason: RejectionReason
            if case .invalid(let r) = digitReading { reason = r } else { reason = .invalidFormat }
            return .invalidFormat(rawText: text, digitConfidences: confidences,
                                  reason: reason, debug: debug)
        }
        let value = reading.value
        // This path already consumed the digit cells the sampler would read;
        // cross-checking it against itself would be circular, so it abstains.
        return .parsed(value: value,
                       ocrConfidence: meanConfidence,
                       rawText: text,
                       digitConfidences: confidences,
                       boundingBox: nil,
                       samplerCrossCheck: .abstained,
                       decimal: reading.decimal,
                       displayText: reading.text,
                       debug: debug)
    }

    // MARK: - Validation stage (actor-isolated, synchronous)

    private func finalizeOutcome(_ outcome: RecognitionOutcome,
                                 config: DeviceRecognitionConfig,
                                 timestamp: TimeInterval)
        -> (measurement: Measurement, debug: String?, observedROI: NormalizedROI?) {
        let format = config.format
        switch outcome {
        case .lost(let debug):
            return (.rejected(timestamp: timestamp, reason: .displayLost, unit: format.unit),
                    debug, nil)
        case .ambiguous(let rawText, let digitConfidences, let debug):
            return (.rejected(timestamp: timestamp, reason: .ambiguousDigit,
                              unit: format.unit, rawText: rawText,
                              digitConfidences: digitConfidences),
                    debug, nil)
        case .invalidFormat(let rawText, let digitConfidences, let reason, let debug):
            return (.rejected(timestamp: timestamp, reason: reason,
                              unit: format.unit, rawText: rawText,
                              digitConfidences: digitConfidences),
                    debug, nil)
        case .parsed(let value, let ocrConfidence, let rawText, let digitConfidences, let boundingBox, let samplerCrossCheck, let decimal, let displayText, let debug):
            let crossCheck = Self.crossCheckOutcome(samplerCrossCheck, ocrValue: value, format: format)
            let measurement = finalize(value: value,
                                       ocrConfidence: ocrConfidence,
                                       rawText: rawText,
                                       format: format,
                                       deviceID: config.id,
                                       timestamp: timestamp,
                                       digitConfidences: digitConfidences,
                                       crossCheck: crossCheck,
                                       decimal: decimal,
                                       displayText: displayText)
            return (measurement, debug, boundingBox)
        }
    }

    /// Runs the shared physical → temporal → confidence tail and updates the
    /// accepted baseline. Synchronous by design (no awaits) so validator state
    /// is never mutated across a suspension point.
    private func finalize(value: Double,
                          ocrConfidence: Float,
                          rawText: String?,
                          format: DisplayFormat,
                          deviceID: UUID,
                          timestamp: TimeInterval,
                          digitConfidences: [Float]?,
                          crossCheck: CrossCheckOutcome,
                          decimal: DecimalAnalysis?,
                          displayText: String?) -> Measurement {
        let physicalRejection = physicalValidators[deviceID]?.validate(value: value, timestamp: timestamp)
        let temporal = temporalFilters[deviceID]?.evaluate(value: value)
            ?? TemporalFilter.Evaluation(consistency: 1, rejected: false)

        var measurement = confidenceEngine.fuse(timestamp: timestamp,
                                                value: value,
                                                unit: format.unit,
                                                rawText: rawText,
                                                ocrConfidence: ocrConfidence,
                                                formatValid: true,
                                                physicalRejection: physicalRejection,
                                                temporalConsistency: temporal.consistency,
                                                temporalRejected: temporal.rejected,
                                                crossCheck: crossCheck,
                                                digitConfidences: digitConfidences,
                                                decimal: decimal,
                                                displayText: displayText)

        // TemporalConsensus gates the PUBLISHED reading (its header's own
        // contract; `TemporalFilter` already fed the confidence product above).
        // Only fuse-ACCEPTED readings are admitted as evidence — frames the
        // other gates rejected must not build support for a form — and a frame
        // the window does not support is demoted to a rejected measurement:
        // the anti 808↔80.8 flip-flop rule, where publishing this frame's form
        // would be a silent order-of-magnitude coin flip.
        if measurement.accepted {
            let text = displayText ?? rawText ?? DisplayFormat.naturalString(value)
            var deviceConsensus = consensus[deviceID] ?? TemporalConsensus()
            let outcome = deviceConsensus.observe(value: value,
                                                  text: text,
                                                  decimalConfidence: decimal?.confidence ?? 1,
                                                  digitConfidence: ocrConfidence,
                                                  formatPrior: nil,
                                                  timestamp: timestamp)
            consensus[deviceID] = deviceConsensus

            switch outcome {
            case .ambiguous:
                // The window is genuinely split (e.g. 808 vs 80.8 with
                // comparable support) — publishing either side would be a coin
                // flip on an order of magnitude.
                measurement = .rejected(timestamp: timestamp,
                                        reason: .ambiguousDecimal,
                                        value: value,
                                        unit: format.unit,
                                        confidence: measurement.confidence,
                                        rawText: rawText,
                                        digitConfidences: digitConfidences,
                                        decimal: decimal,
                                        displayText: displayText)
            case .stable(let anchorValue, let anchorText, _),
                 .changing(let anchorValue, let anchorText, _):
                if anchorText != text {
                    // The anchor was HELD against this frame: the window still
                    // supports a different written form, so this frame's form
                    // is not publishable yet. A power-of-ten neighbour is a
                    // decimal event; anything else is temporal disagreement.
                    let isDecimalEvent = TemporalConsensus.decimalShiftExponent(
                        from: anchorValue, text: anchorText,
                        to: value, text: text) != nil
                    measurement = .rejected(timestamp: timestamp,
                                            reason: isDecimalEvent ? .ambiguousDecimal
                                                                   : .temporalInconsistency,
                                            value: value,
                                            unit: format.unit,
                                            confidence: measurement.confidence,
                                            rawText: rawText,
                                            digitConfidences: digitConfidences,
                                            decimal: decimal,
                                            displayText: displayText)
                }
            }
        }

        if measurement.accepted {
            physicalValidators[deviceID]?.recordAccepted(value: value, timestamp: timestamp)
        }
        return measurement
    }

    // MARK: - Cross-check (classical seven-segment, pure)

    /// Classical seven-segment cross-check over the whole ROI (constrained
    /// formats only). Pure — reads the shared frame, touches no actor state.
    ///
    /// Splits the ROI into fixed-pitch cells (`DigitSegmenter`) and decodes each
    /// with the deterministic `SevenSegmentSampler`. A leading '-' cell is taken
    /// as the sign when the format allows it; every remaining cell must decode to
    /// a clean 0–9 digit — ANY blank/ambiguous/dash-in-body cell makes the
    /// sampler ABSTAIN rather than guess (so it can only corroborate or veto,
    /// never invent a disagreement). The assembled digits are decimal-inserted
    /// per the format and validated strictly; a parse failure also abstains.
    /// Confidence is the weakest per-cell decision that was consumed.
    private static func samplerCrossCheck(config: DeviceRecognitionConfig,
                                          frame: TimestampedFrame) -> SamplerCrossCheck {
        let format = config.format
        let cells = DigitSegmenter().digitCells(in: config.roi, format: format)
        guard !cells.isEmpty else { return .abstained }
        let readings = SevenSegmentSampler().readDigits(in: frame.pixelBuffer, cells: cells)
        guard readings.count == cells.count else { return .abstained }

        var body = readings[...]
        var negative = false
        var minConfidence: Float = 1
        if format.signAllowed, let first = body.first, first.digit == "-" {
            negative = true
            minConfidence = min(minConfidence, first.confidence)
            body = body.dropFirst()
        }

        var digits = ""
        for reading in body {
            guard let digit = reading.digit, ("0"..."9").contains(digit) else {
                return .abstained
            }
            digits.append(digit)
            minConfidence = min(minConfidence, reading.confidence)
        }
        guard !digits.isEmpty else { return .abstained }

        let reconstructed = reconstruct(digits: digits, format: format)
        let text = negative ? "-" + reconstructed : reconstructed
        guard case .valid(let value) = FormatValidator.parse(text, format: format) else {
            return .abstained
        }
        return .read(value: value, confidence: minConfidence)
    }

    /// Resolves a sampler cross-check against the OCR value into the
    /// `CrossCheckOutcome` the confidence engine consumes. "Agreement" is
    /// equality within half a least-significant-digit step of the display's
    /// resolution (`fractionDigits`); anything else is a disagreement carrying
    /// the sampler's own confidence.
    private static func crossCheckOutcome(_ sampler: SamplerCrossCheck,
                                          ocrValue: Double,
                                          format: DisplayFormat) -> CrossCheckOutcome {
        switch sampler {
        case .abstained:
            return .notAvailable
        case .read(let samplerValue, let confidence):
            let halfLSD = 0.5 * pow(10.0, Double(-format.fractionDigits))
            if abs(ocrValue - samplerValue) <= halfLSD {
                return .agrees(samplerConfidence: confidence)
            }
            return .disagrees(samplerConfidence: confidence, samplerValue: samplerValue)
        }
    }

    // MARK: - Helpers

    /// Reinserts the decimal separator into a raw digit string per the format
    /// (`decimalPosition` = digits before the separator; `nil` = integer).
    private static func reconstruct(digits: String, format: DisplayFormat) -> String {
        guard let decimalPosition = format.decimalPosition else { return digits }
        if decimalPosition <= 0 { return "." + digits }
        if decimalPosition >= digits.count { return digits }
        let splitIndex = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
    }

    /// Debug-overlay line, e.g. `Detected: 12.347 V (0.91)`.
    private static func debugString(text: String, unit: String?, confidence: Float) -> String {
        let unitPart = (unit?.isEmpty == false) ? " \(unit!)" : ""
        return "Detected: \(text)\(unitPart) (\(String(format: "%.2f", confidence)))"
    }
}
