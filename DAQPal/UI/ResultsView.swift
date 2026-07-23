//
//  ResultsView.swift
//  DAQPal
//
//  Session results screen (design handoff §3): summary chips, dual-scale
//  graph, per-device stats, sample table and CSV export. Presented as a
//  `.fullScreenCover` over the still-mounted capture screen (spec §40.1) —
//  "‹ Camera" only hides this cover, it never clears the session.
//

import SwiftUI

struct ResultsView: View {
    @Environment(AppState.self) private var appState
    /// Decimated series/stats/counts, built off-main once per session — view
    /// bodies never scan raw samples (multi-thousand-sample sessions).
    @State private var model: ResultsSessionModel?
    @State private var exportURL: URL?
    @State private var exportError: String?

    /// Newest rows shown in the table; the rest remain in the CSV export.
    private let tableRowLimit = 50
    private let timeColumnWidth: CGFloat = 46
    private let confColumnWidth: CGFloat = 40

    init() {}

    var body: some View {
        Group {
            if let session = appState.completedSession {
                content(session)
            } else {
                emptyState
            }
        }
        .background(Theme.resultsBackground.ignoresSafeArea())
    }

    // MARK: Content

    private func content(_ session: CompletedSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header(session)
                if let model, model.sessionID == session.id {
                    summaryChips(session, model: model)
                    graphCard(session, model: model)
                    statsGrid(session, model: model)
                    tableCard(session)
                    exportButtons(session)
                } else {
                    preparingPlaceholder
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .task(id: session.id) {
            if model?.sessionID != session.id {
                model = nil
                exportURL = nil
            }
            // CompletedSession is Sendable and both builders are pure, so the
            // heavy work (full-session scan + CSV string/file) runs detached —
            // the MainActor only receives the finished values.
            let built = await Task.detached(priority: .userInitiated) {
                ResultsSessionModel.build(from: session)
            }.value
            guard appState.completedSession?.id == session.id else { return }
            model = built
            await prepareExport(session)
        }
    }

    private var preparingPlaceholder: some View {
        HStack(spacing: 8) {
            ProgressView()
            SectionLabel(text: "PREPARING RESULTS")
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            SectionLabel(text: "SESSION RESULTS", color: Theme.ink)
            Text("No completed session yet.")
                .font(Theme.ui(12))
                .foregroundStyle(Theme.inkMuted)
            Button {
                appState.showResults = false
            } label: {
                Text("‹ Back to Camera")
                    .font(Theme.ui(12, weight: .heavy))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.heavyRule, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Header

    private func header(_ session: CompletedSession) -> some View {
        ZStack {
            SectionLabel(text: "SESSION RESULTS", size: 13, color: Theme.ink)
            HStack {
                backButton
                Spacer()
                rowCountChip(session)
            }
        }
        .frame(minHeight: 44)
    }

    private var backButton: some View {
        Button {
            // Contract: back returns to capture WITHOUT clearing the session
            // (unlike "NEW SESSION"), so the results stay available if the
            // user reopens them.
            appState.showResults = false
        } label: {
            Text("‹ Camera")
                .font(Theme.ui(12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x8A6B00))
                .contentShape(Rectangle().inset(by: -10))
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityLabel("Back to camera")
    }

    private func rowCountChip(_ session: CompletedSession) -> some View {
        Text("\(session.sampleCount) ROWS")
            .font(Theme.ui(10, weight: .heavy))
            .tracking(0.4)
            .foregroundStyle(Theme.brandYellow)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.ink))
    }

    // MARK: Summary chips

    private func summaryChips(_ session: CompletedSession, model: ResultsSessionModel) -> some View {
        HStack(spacing: 6) {
            chip("⏱ " + String(format: "%.1fs", session.duration),
                 background: .white, foreground: Theme.ink, border: Theme.hairline)
            chip(String(format: "%.1f", session.samplesPerSecond) + " samples/s",
                 background: .white, foreground: Theme.ink, border: Theme.hairline)
            chip("✓ \(model.acceptedCount) accepted",
                 background: Theme.acceptedChipBackground, foreground: Theme.acceptedChipForeground,
                 border: Theme.acceptedChipForeground.opacity(0.25))
            chip("✕ \(model.rejectedCount) rejected",
                 background: Theme.rejectedRowBackground, foreground: Theme.searchingChipForeground,
                 border: Theme.searchingChipForeground.opacity(0.25))
        }
    }

    private func chip(_ text: String, background: Color, foreground: Color, border: Color) -> some View {
        Text(text)
            .font(Theme.ui(10, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1))
    }

    // MARK: Graph card

    private func graphCard(_ session: CompletedSession, model: ResultsSessionModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(text: "MEASUREMENT vs TIME", color: Theme.inkMuted)
                Spacer()
                legend(session)
            }
            ResultsGraphView(series: model.series, duration: session.duration)
                .frame(height: 140)
            HStack {
                Text("0.00s")
                Spacer()
                Text(String(format: "%.2fs", session.duration))
            }
            .font(Theme.mono(9, weight: .medium))
            .foregroundStyle(Theme.inkMuted)
            Text("Each series is scaled to its own min/max range.")
                .font(Theme.ui(8))
                .foregroundStyle(Theme.inkMuted)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.resultsCard))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func legend(_ session: CompletedSession) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(session.devices.enumerated()), id: \.element.id) { index, device in
                HStack(spacing: 3) {
                    Rectangle()
                        .fill(ResultsSeriesPalette.color(at: index))
                        .frame(width: 10, height: 2)
                    Text("\(device.name) (\(device.unit ?? "—"))")
                        .font(Theme.ui(9, weight: .semibold))
                        .foregroundStyle(Theme.inkMuted)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: Stats cards

    private func statsGrid(_ session: CompletedSession, model: ResultsSessionModel) -> some View {
        let columns = session.devices.count > 1
            ? [GridItem(.flexible()), GridItem(.flexible())]
            : [GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 10) {
            ForEach(session.devices) { device in
                statsCard(device: device, stats: model.stats[device.id])
            }
        }
    }

    private func statsCard(device: Device, stats: ResultsSessionModel.DeviceStats?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(deviceSubtitle(device))
                .font(Theme.ui(9, weight: .heavy))
                .tracking(0.4)
                .foregroundStyle(Theme.inkMuted)
            VStack(alignment: .leading, spacing: 3) {
                Text("min " + statLine(stats?.minimum, device: device))
                Text("mean " + statLine(stats?.mean, device: device))
                Text("max " + statLine(stats?.maximum, device: device))
            }
            .font(Theme.mono(11, weight: .semibold))
            .foregroundStyle(Theme.ink)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.resultsCard))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    /// Accepted-only stat, formatted with the device's own digit layout;
    /// em-dash when the session has no accepted readings for this device.
    private func statLine(_ value: Double?, device: Device) -> String {
        guard let value else { return "—" }
        return device.displayFormat.formatted(value)
    }

    /// "DC" only applies to electrical units — "DMM-1 · V DC" but "DMM-2 · °C".
    private func deviceSubtitle(_ device: Device) -> String {
        let unit = device.unit ?? "—"
        let suffix = (unit == "V" || unit == "A") ? " DC" : ""
        return "\(device.name) · \(unit)\(suffix)"
    }

    // MARK: Table card

    private func tableCard(_ session: CompletedSession) -> some View {
        let rows = Array(session.samples.suffix(tableRowLimit))
        return VStack(alignment: .leading, spacing: 0) {
            tableHeaderRow(session.devices)
            if rows.isEmpty {
                Text("No samples recorded.")
                    .font(Theme.ui(9, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(12)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, sample in
                    tableDataRow(sample, session: session)
                }
            }
            if session.sampleCount > rows.count {
                Text("+ \(session.sampleCount - rows.count) earlier rows — full data in CSV")
                    .font(Theme.ui(9, weight: .medium))
                    .foregroundStyle(Theme.inkMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
            }
        }
        .background(Theme.resultsCard)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    private func tableHeaderRow(_ devices: [Device]) -> some View {
        HStack(spacing: 6) {
            Text("TIME").frame(width: timeColumnWidth, alignment: .leading)
            ForEach(devices) { device in
                Text("\(device.name) (\(device.unit ?? "—"))")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                Text("CONF").frame(width: confColumnWidth, alignment: .leading)
            }
        }
        .font(Theme.ui(8, weight: .heavy))
        .tracking(0.4)
        .foregroundStyle(Theme.inkMuted)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.tableHeader)
    }

    private func tableDataRow(_ sample: RecordingSample, session: CompletedSession) -> some View {
        let rowHasRejection = session.devices.contains { device in
            sample.readings[device.id].map { !$0.accepted } ?? false
        }
        return HStack(spacing: 6) {
            Text(String(format: "%.2f", session.relativeTime(sample.timestamp)))
                .frame(width: timeColumnWidth, alignment: .leading)
            ForEach(session.devices) { device in
                let reading = sample.readings[device.id]
                Text(valueCellText(reading, device: device))
                    .foregroundStyle(reading.map { $0.accepted ? Theme.ink : Theme.searchingChipForeground } ?? Theme.inkMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                Text(confCellText(reading))
                    .frame(width: confColumnWidth, alignment: .leading)
            }
        }
        .font(Theme.mono(10, weight: .medium))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(rowHasRejection ? Theme.rejectedRowBackground : Color.clear)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }

    private func valueCellText(_ reading: Measurement?, device: Device) -> String {
        guard let reading else { return "—" }
        guard reading.accepted else { return "✕ rej" }
        return device.displayFormat.formatted(reading.value)
    }

    private func confCellText(_ reading: Measurement?) -> String {
        guard let reading else { return "—" }
        return String(format: "%.2f", reading.confidence)
    }

    // MARK: Export / new session

    private func exportButtons(_ session: CompletedSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                exportButton(session)
                Button {
                    appState.newSession()
                } label: {
                    Text("NEW SESSION")
                        .font(Theme.ui(12, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.heavyRule, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Start a new session")
            }
            if let exportError {
                Text(exportError)
                    .font(Theme.ui(9))
                    .foregroundStyle(Theme.searchingChipForeground)
            }
        }
    }

    @ViewBuilder
    private func exportButton(_ session: CompletedSession) -> some View {
        if let exportURL {
            ShareLink(item: exportURL) {
                Text("⬇ EXPORT CSV")
                    .font(Theme.ui(12, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow))
            }
            .accessibilityLabel("Export CSV")
        } else {
            Button {
                Task { await prepareExport(session) }
            } label: {
                Text("⬇ EXPORT CSV")
                    .font(Theme.ui(12, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink.opacity(0.4))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow.opacity(0.4)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry preparing CSV export")
        }
    }

    /// Builds the CSV string + file off the MainActor — the build cost scales
    /// with session size and this runs exactly when the cover is presenting.
    private func prepareExport(_ session: CompletedSession) async {
        exportError = nil
        do {
            let url = try await Task.detached(priority: .utility) {
                try CSVExporter.exportFile(for: session)
            }.value
            guard appState.completedSession?.id == session.id else { return }
            exportURL = url
        } catch {
            exportURL = nil
            exportError = "Couldn't prepare CSV export: \(error.localizedDescription)"
        }
    }
}
