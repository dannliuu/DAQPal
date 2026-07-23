//
//  CSVExporter.swift
//  DAQPal
//
//  CSV export for a completed session (spec §25, design handoff CSV section).
//  Two schemas are both "authoritative" per IMPLEMENTATION_NOTES.md and are
//  selected by device count: a single-device session uses the spec's flat
//  schema; a multi-device session uses the handoff's one-column-set-per-device
//  schema. Rejected readings are always retained (never dropped) for
//  scientific traceability.
//

import Foundation

enum CSVExporter {
    /// Product-mandated export filename (never legacy "instrulog_session.csv").
    static let fileName = "daqpal_session.csv"

    /// Builds the full CSV text for a completed session. Pure function — no I/O.
    static func csvString(for session: CompletedSession) -> String {
        if session.devices.count == 1 {
            return singleDeviceCSV(session: session, device: session.devices[0])
        }
        return multiDeviceCSV(session: session)
    }

    /// Writes the CSV to `daqpal_session.csv` in the temporary directory,
    /// overwriting any previous export, and returns its URL for `ShareLink`.
    static func exportFile(for session: CompletedSession) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try csvString(for: session).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Single-device schema — `timestamp,value,unit,confidence,accepted,rejection_reason`

    private static func singleDeviceCSV(session: CompletedSession, device: Device) -> String {
        var lines = ["timestamp,value,unit,confidence,accepted,rejection_reason"]
        let fractionDigits = device.displayFormat.fractionDigits
        for sample in session.samples {
            let time = formatSeconds(session.relativeTime(sample.timestamp))
            guard let reading = sample.readings[device.id] else {
                // No candidate produced for this device on this frame (e.g. ROI
                // was cleared mid-recording) — log the row as unaccepted rather
                // than silently dropping it.
                lines.append("\(time),,,,false,")
                continue
            }
            let value = formatValue(reading.value, fractionDigits: fractionDigits)
            let unit = reading.unit ?? device.unit ?? ""
            let confidence = formatConfidence(reading.confidence)
            let accepted = reading.accepted ? "true" : "false"
            let reason = reading.rejectionReason?.rawValue ?? ""
            lines.append("\(time),\(value),\(unit),\(confidence),\(accepted),\(reason)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Multi-device schema — one `<prefix>_value_<unit>,<prefix>_confidence,<prefix>_valid` set per device

    private static func multiDeviceCSV(session: CompletedSession) -> String {
        var header = ["timestamp_s"]
        for device in session.devices {
            let prefix = device.columnPrefix
            let unit = sanitizedUnitToken(device.displayFormat.unit)
            // Dimensionless device: drop the unit suffix entirely (`dmm1_value`)
            // rather than emit a dangling separator (`dmm1_value_`).
            header.append(unit.isEmpty ? "\(prefix)_value" : "\(prefix)_value_\(unit)")
            header.append("\(prefix)_confidence")
            header.append("\(prefix)_valid")
        }
        var lines = [header.joined(separator: ",")]
        for sample in session.samples {
            var fields = [formatSeconds(session.relativeTime(sample.timestamp))]
            for device in session.devices {
                if let reading = sample.readings[device.id] {
                    // Value is logged even when rejected (traceability); only a
                    // non-finite value (unparseable OCR) leaves the cell empty.
                    fields.append(formatValue(reading.value, fractionDigits: device.displayFormat.fractionDigits))
                    fields.append(formatConfidence(reading.confidence))
                    fields.append(reading.accepted ? "1" : "0")
                } else {
                    fields.append("")
                    fields.append("")
                    fields.append("0")
                }
            }
            lines.append(fields.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Formatting helpers — always `.`-decimal, never locale-dependent

    private static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    private static func formatConfidence(_ confidence: Float) -> String {
        String(format: "%.3f", confidence)
    }

    private static func formatValue(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "" }
        return String(format: "%.\(fractionDigits)f", value)
    }

    /// Header-safe unit token, e.g. `Ω` → `ohm`, `°C` → `degC`.
    private static func sanitizedUnitToken(_ unit: String?) -> String {
        guard let unit, !unit.isEmpty else { return "" }
        let mapped = unit
            .replacingOccurrences(of: "Ω", with: "ohm")
            .replacingOccurrences(of: "°C", with: "degC")
        return mapped.filter { $0.isLetter || $0.isNumber }
    }
}
