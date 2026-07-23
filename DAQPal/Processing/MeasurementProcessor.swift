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
    func process(frame: TimestampedFrame) async -> FrameResult {
        guard !configs.isEmpty else {
            return FrameResult(timestamp: frame.timestamp, readings: [:], debugText: nil)
        }

        var readings: [UUID: Measurement] = [:]
        var debugText: String?
        for (index, config) in configs.enumerated() {
            let (measurement, debug) = await processDevice(config, frame: frame)
            readings[config.id] = measurement
            if index == 0 { debugText = debug }
        }
        return FrameResult(timestamp: frame.timestamp, readings: readings, debugText: debugText)
    }

    // MARK: - Per-device

    private func processDevice(_ config: DeviceRecognitionConfig,
                               frame: TimestampedFrame) async -> (Measurement, String?) {
        let format = config.format
        let timestamp = frame.timestamp

        guard let crop = PixelBufferROI.cropped(frame.pixelBuffer, to: config.roi) else {
            return (.rejected(timestamp: timestamp, reason: .displayLost, unit: format.unit),
                    "Detected: —")
        }

        if useDigitLevelRecognition {
            return await processDigitLevel(config, crop: crop, timestamp: timestamp)
        }
        return await processWholeROI(config, crop: crop, timestamp: timestamp)
    }

    /// Whole-ROI path (default): the best OCR candidate that satisfies the
    /// format grammar wins — the essence of format-aware OCR (spec §3).
    private func processWholeROI(_ config: DeviceRecognitionConfig,
                                 crop: CVPixelBuffer,
                                 timestamp: TimeInterval) async -> (Measurement, String?) {
        let format = config.format
        let candidates = (try? await ocr.recognize(in: crop, regionOfInterest: nil)) ?? []
        // --- no more awaits below: validator mutation is a single sync stretch ---
        guard let top = candidates.first else {
            return (.rejected(timestamp: timestamp, reason: .displayLost, unit: format.unit),
                    "Detected: —")
        }

        // Candidates are confidence-sorted; take the highest-confidence one that
        // parses under the configured grammar.
        var chosen: (candidate: OCRCandidate, value: Double)?
        for candidate in candidates {
            if case .valid(let value) = FormatValidator.parse(candidate.text, format: format) {
                chosen = (candidate, value)
                break
            }
        }

        let display = chosen?.candidate ?? top
        let debug = debugString(text: display.text, unit: format.unit, confidence: display.confidence)

        guard let chosen else {
            return (.rejected(timestamp: timestamp, reason: .invalidFormat,
                              unit: format.unit, rawText: top.text),
                    debug)
        }

        let measurement = finalize(value: chosen.value,
                                   ocrConfidence: chosen.candidate.confidence,
                                   rawText: chosen.candidate.text,
                                   format: format,
                                   deviceID: config.id,
                                   timestamp: timestamp,
                                   digitConfidences: nil)
        return (measurement, debug)
    }

    /// Digit-cell path (opt-in): reconstruct the value from per-cell 0–9
    /// recognition, carrying per-position confidences. Sign is not detected on
    /// this path (see `DigitSegmenter`); unresolved cells reject as
    /// `.ambiguousDigit`.
    private func processDigitLevel(_ config: DeviceRecognitionConfig,
                                   crop: CVPixelBuffer,
                                   timestamp: TimeInterval) async -> (Measurement, String?) {
        let format = config.format
        let cropSpace = NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        let cells = segmenter.digitCells(in: cropSpace, format: format)
        let digitResults = await digitRecognizer.recognizeDigits(in: crop, cells: cells)
        // --- no more awaits below ---
        let confidences = digitResults.map(\.confidence)
        let meanConfidence = confidences.isEmpty ? 0
            : confidences.reduce(0, +) / Float(confidences.count)

        if digitResults.isEmpty || digitResults.contains(where: { $0.digit == nil }) {
            let partial = String(digitResults.map { $0.digit ?? "?" })
            return (.rejected(timestamp: timestamp, reason: .ambiguousDigit,
                              unit: format.unit, rawText: partial, digitConfidences: confidences),
                    "Detected: \(partial.isEmpty ? "—" : partial) (ambiguous)")
        }

        let digits = String(digitResults.compactMap(\.digit))
        let text = reconstruct(digits: digits, format: format)
        let debug = debugString(text: text, unit: format.unit, confidence: meanConfidence)

        guard case .valid(let value) = FormatValidator.parse(text, format: format) else {
            return (.rejected(timestamp: timestamp, reason: .invalidFormat,
                              unit: format.unit, rawText: text, digitConfidences: confidences),
                    debug)
        }

        let measurement = finalize(value: value,
                                   ocrConfidence: meanConfidence,
                                   rawText: text,
                                   format: format,
                                   deviceID: config.id,
                                   timestamp: timestamp,
                                   digitConfidences: confidences)
        return (measurement, debug)
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
    private func reconstruct(digits: String, format: DisplayFormat) -> String {
        guard let decimalPosition = format.decimalPosition else { return digits }
        if decimalPosition <= 0 { return "." + digits }
        if decimalPosition >= digits.count { return digits }
        let splitIndex = digits.index(digits.startIndex, offsetBy: decimalPosition)
        return String(digits[..<splitIndex]) + "." + String(digits[splitIndex...])
    }

    /// Debug-overlay line, e.g. `Detected: 12.347 V (0.91)`.
    private func debugString(text: String, unit: String?, confidence: Float) -> String {
        let unitPart = (unit?.isEmpty == false) ? " \(unit!)" : ""
        return "Detected: \(text)\(unitPart) (\(String(format: "%.2f", confidence)))"
    }
}
