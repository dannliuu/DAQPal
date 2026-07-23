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
//    PhysicalValidator → TemporalFilter → ConfidenceEngine → Measurement.
//  Any crop/text failure becomes a rejected Measurement (never a throw).
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
        formatByID = formatByID.filter { ids.contains($0.key) }

        for device in devices where formatByID[device.id] != device.format {
            physicalValidators[device.id] = PhysicalValidator(format: device.format)
            temporalFilters[device.id] = TemporalFilter(format: device.format)
            formatByID[device.id] = device.format
        }
        configs = devices
    }

    /// Clears all temporal/rate history (e.g. at the start of a recording) while
    /// keeping the device set and formats.
    func resetTemporalState() {
        physicalValidators.removeAll()
        temporalFilters.removeAll()
        for device in configs {
            physicalValidators[device.id] = PhysicalValidator(format: device.format)
            temporalFilters[device.id] = TemporalFilter(format: device.format)
        }
    }

    /// Processes one frame across all configured devices. Never throws.
    ///
    /// Two stages: recognition fans out concurrently (it is pure — Vision and
    /// CoreImage only READ the shared frame and touch no actor state), then
    /// validation runs as one synchronous stretch in stable config order. This
    /// keeps the sample rate from dividing by device count while preserving
    /// the no-await validator-mutation rule above.
    func process(frame: TimestampedFrame) async -> FrameResult {
        guard !configs.isEmpty else {
            return FrameResult(timestamp: frame.timestamp, readings: [:], debugText: nil)
        }

        let jobs = configs
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
        var readings: [UUID: Measurement] = [:]
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

    /// What recognition produced for one device, before any validator state is
    /// consulted — lets the concurrent stage stay free of actor-state access.
    private enum RecognitionOutcome {
        case lost(debug: String?)
        case ambiguous(rawText: String?, digitConfidences: [Float], debug: String?)
        case invalidFormat(rawText: String?, digitConfidences: [Float]?, debug: String?)
        case parsed(value: Double, ocrConfidence: Float, rawText: String,
                    digitConfidences: [Float]?, boundingBox: NormalizedROI?, debug: String?)
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
        var chosen: (candidate: OCRCandidate, value: Double)?
        for candidate in candidates {
            if case .valid(let value) = FormatValidator.value(from: candidate.text, format: format) {
                chosen = (candidate, value)
                break
            }
        }

        let display = chosen?.candidate ?? top
        let debug = debugString(text: display.text, unit: format.unit, confidence: display.confidence)

        guard let chosen else {
            return .invalidFormat(rawText: top.text, digitConfidences: nil, debug: debug)
        }
        return .parsed(value: chosen.value,
                       ocrConfidence: chosen.candidate.confidence,
                       rawText: chosen.candidate.text,
                       digitConfidences: nil,
                       boundingBox: chosen.candidate.boundingBox,
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
        guard case .valid(let value) = FormatValidator.value(from: text, format: format) else {
            return .invalidFormat(rawText: text, digitConfidences: confidences, debug: debug)
        }
        return .parsed(value: value,
                       ocrConfidence: meanConfidence,
                       rawText: text,
                       digitConfidences: confidences,
                       boundingBox: nil,
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
        case .invalidFormat(let rawText, let digitConfidences, let debug):
            return (.rejected(timestamp: timestamp, reason: .invalidFormat,
                              unit: format.unit, rawText: rawText,
                              digitConfidences: digitConfidences),
                    debug, nil)
        case .parsed(let value, let ocrConfidence, let rawText, let digitConfidences, let boundingBox, let debug):
            let measurement = finalize(value: value,
                                       ocrConfidence: ocrConfidence,
                                       rawText: rawText,
                                       format: format,
                                       deviceID: config.id,
                                       timestamp: timestamp,
                                       digitConfidences: digitConfidences)
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
                          digitConfidences: [Float]?) -> Measurement {
        let physicalRejection = physicalValidators[deviceID]?.validate(value: value, timestamp: timestamp)
        let temporal = temporalFilters[deviceID]?.evaluate(value: value)
            ?? TemporalFilter.Evaluation(consistency: 1, rejected: false)

        let measurement = confidenceEngine.fuse(timestamp: timestamp,
                                                value: value,
                                                unit: format.unit,
                                                rawText: rawText,
                                                ocrConfidence: ocrConfidence,
                                                formatValid: true,
                                                physicalRejection: physicalRejection,
                                                temporalConsistency: temporal.consistency,
                                                temporalRejected: temporal.rejected,
                                                digitConfidences: digitConfidences)

        if measurement.accepted {
            physicalValidators[deviceID]?.recordAccepted(value: value, timestamp: timestamp)
        }
        return measurement
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
