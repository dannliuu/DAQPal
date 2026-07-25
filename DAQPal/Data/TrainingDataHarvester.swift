//
//  TrainingDataHarvester.swift
//  DAQPal
//
//  Label-distillation harvester (OCR_RESEARCH.md Phase 1): turns "readings the
//  live pipeline already trusts" into a labeled training set with no separate
//  labeling pass. It rides on the SAME validation pipeline
//  (`MeasurementProcessor`) end users get — a crop only gets written once a
//  reading is accepted, confident, AND has repeated (within display
//  resolution) for `stabilityStreak` consecutive frames. That streak
//  requirement is what keeps digit-transition and motion-blur frames out of
//  the dataset; a naive "save every accepted frame" harvester would be full
//  of them. This is also the intended seam for a future in-app opt-in
//  "help improve recognition" data-collection feature: swap the fixture/
//  synthetic `FrameSource` for the live camera one and everything else holds.
//
//  labels.csv columns: `filename,value,raw_text,confidence,timestamp`
//  - filename:  PNG basename, relative to `Summary.cropsDirectoryURL`.
//  - value:     the accepted, parsed measurement value (`%.6f`, `.` decimal).
//  - raw_text:  the OCR text the value was parsed from (CSV-escaped).
//  - confidence: final fused confidence (spec §19), 0...1, 4dp.
//  - timestamp: the source frame's monotonic capture timestamp, seconds.
//
//  Portability: ImageIO/CoreGraphics/CoreImage only — no UIKit — so this file
//  stays usable outside the app target unchanged (e.g. an offline harvesting
//  tool) if that's ever needed.
//

import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class TrainingDataHarvester {
    struct Config {
        var outputDirectory: URL
        var minimumConfidence: Float
        /// Consecutive identical (within display resolution) accepted values
        /// required before a frame is harvested.
        var stabilityStreak: Int
        var maxSamples: Int

        init(outputDirectory: URL,
            minimumConfidence: Float = 0.8,
            stabilityStreak: Int = 3,
            maxSamples: Int = 5_000) {
            self.outputDirectory = outputDirectory
            self.minimumConfidence = minimumConfidence
            self.stabilityStreak = max(1, stabilityStreak)
            self.maxSamples = max(0, maxSamples)
        }
    }

    struct Summary {
        let framesSeen: Int
        let samplesWritten: Int
        let labelsFileURL: URL
        let cropsDirectoryURL: URL
    }

    enum HarvestError: Error {
        case cannotCreateOutputDirectory(URL)
        case cannotOpenLabelsFile(URL)
    }

    private let config: Config
    /// Not shared with `PixelBufferROI`'s context — this one only ever
    /// renders a crop to a still `CGImage` for PNG encoding, a different
    /// access pattern worth keeping separate.
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    init(config: Config) {
        self.config = config
    }

    /// Drives every frame from `source` through `processor` for `device`.
    /// Frames that end up as an ACCEPTED, ≥ `minimumConfidence`, value-stable
    /// (for `stabilityStreak` consecutive frames) reading get their ROI crop
    /// written as a PNG plus a `labels.csv` row; everything else is skipped
    /// without error. Never throws for a single bad frame — only for
    /// filesystem setup failures that would make the whole run pointless.
    ///
    /// `processor`'s device set is replaced with just `[device]` for the
    /// duration of the call. Callers driving multiple harvest sessions off
    /// one long-lived `MeasurementProcessor` should call
    /// `resetTemporalState()` themselves between sessions if a clean temporal
    /// window is wanted — this method does not reset it implicitly, so a
    /// harvest that immediately follows live use of the same processor can
    /// inherit its recent history.
    func harvest(source: any FrameSource,
                device: DeviceRecognitionConfig,
                processor: MeasurementProcessor) async throws -> Summary {
        let cropsDirectoryURL = config.outputDirectory.appendingPathComponent("crops", isDirectory: true)
        let labelsFileURL = config.outputDirectory.appendingPathComponent("labels.csv")

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: cropsDirectoryURL, withIntermediateDirectories: true)
        } catch {
            throw HarvestError.cannotCreateOutputDirectory(cropsDirectoryURL)
        }

        let handle = try Self.openLabelsFileForAppending(at: labelsFileURL, fileManager: fileManager)
        defer { try? handle.close() }

        await processor.update(devices: [device])

        var framesSeen = 0
        var samplesWritten = 0
        var streakValue: Double?
        var streakCount = 0
        let matchTolerance = Self.stabilityTolerance(for: device.format)

        for await frame in source.frames() {
            guard samplesWritten < config.maxSamples else { break }
            framesSeen += 1

            let result = await processor.process(frame: frame)
            guard let measurement = result.readings[device.id],
                  measurement.accepted,
                  measurement.value.isFinite else {
                streakValue = nil
                streakCount = 0
                continue
            }

            if let streakValue, abs(measurement.value - streakValue) <= matchTolerance {
                streakCount += 1
            } else {
                streakValue = measurement.value
                streakCount = 1
            }

            // Stability gate first (cheap, no I/O), then confidence, then the
            // actual crop/encode work — avoids paying for a PNG encode on
            // frames the confidence gate would reject anyway.
            guard streakCount >= config.stabilityStreak,
                  measurement.confidence >= config.minimumConfidence else { continue }

            guard let crop = PixelBufferROI.cropped(frame.pixelBuffer, to: device.roi),
                  let pngData = pngData(from: crop) else { continue }

            let filename = Self.filename(index: samplesWritten, timestamp: frame.timestamp)
            let fileURL = cropsDirectoryURL.appendingPathComponent(filename)
            do {
                try pngData.write(to: fileURL, options: .atomic)
            } catch {
                continue
            }

            let row = Self.csvRow(filename: filename, measurement: measurement, timestamp: frame.timestamp)
            guard let rowData = row.data(using: .utf8) else { continue }
            do {
                try handle.write(contentsOf: rowData)
            } catch {
                continue
            }
            samplesWritten += 1
        }

        return Summary(framesSeen: framesSeen,
                       samplesWritten: samplesWritten,
                       labelsFileURL: labelsFileURL,
                       cropsDirectoryURL: cropsDirectoryURL)
    }

    // MARK: - labels.csv lifecycle

    private static let header = "filename,value,raw_text,confidence,timestamp\n"

    /// Opens `labels.csv` for appending. A missing or empty file gets the
    /// header row; an existing NON-EMPTY file is left exactly as-is and a
    /// session-separator comment line is appended before any new rows, so
    /// repeated harvest runs accumulate labeled data instead of clobbering it.
    private static func openLabelsFileForAppending(at url: URL, fileManager: FileManager) throws -> FileHandle {
        let fileExists = fileManager.fileExists(atPath: url.path)
        var existingSize: UInt64 = 0
        if fileExists, let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let sizeNumber = attributes[.size] as? NSNumber {
            existingSize = sizeNumber.uint64Value
        }
        let hadPriorContent = fileExists && existingSize > 0

        if !hadPriorContent {
            guard fileManager.createFile(atPath: url.path, contents: Data(header.utf8)) else {
                throw HarvestError.cannotOpenLabelsFile(url)
            }
        }

        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw HarvestError.cannotOpenLabelsFile(url)
        }
        handle.seekToEndOfFile()

        if hadPriorContent {
            let separator = "# --- session \(ISO8601DateFormatter().string(from: Date())) appended ---\n"
            try? handle.write(contentsOf: Data(separator.utf8))
        }
        return handle
    }

    // MARK: - Encoding

    /// Crop → CGImage → PNG, per the contract's ImageIO requirement.
    private func pngData(from buffer: CVPixelBuffer) -> Data? {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(mutableData,
                                                                  UTType.png.identifier as CFString,
                                                                  1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    // MARK: - Helpers

    /// Half of one least-significant-digit step for the device's format —
    /// two readings within this tolerance are the "same" displayed value.
    /// Falls back to a small absolute epsilon when the format carries no
    /// meaningful digit layout.
    private static func stabilityTolerance(for format: DisplayFormat) -> Double {
        let step = pow(10, -Double(format.fractionDigits))
        return step > 0 ? step / 2 : 0.0005
    }

    private static func filename(index: Int, timestamp: TimeInterval) -> String {
        let milliseconds = Int((timestamp * 1000).rounded())
        return String(format: "sample_%06d_%dms.png", index, milliseconds)
    }

    private static func csvRow(filename: String, measurement: Measurement, timestamp: TimeInterval) -> String {
        let value = String(format: "%.6f", measurement.value)
        let rawText = csvField(measurement.rawText ?? "")
        let confidence = String(format: "%.4f", measurement.confidence)
        let timestampField = String(format: "%.6f", timestamp)
        return "\(csvField(filename)),\(value),\(rawText),\(confidence),\(timestampField)\n"
    }

    /// RFC4182-style quoting, only applied when actually needed — the values
    /// this harvester writes (digits/decimal/sign) never require it in
    /// practice, but OCR raw text is untrusted input.
    private static func csvField(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
