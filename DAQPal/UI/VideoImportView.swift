//
//  VideoImportView.swift
//  DAQPal
//
//  Offline video-import flow (Milestone 12): pick a recorded instrument
//  video, place an ROI on its first frame, choose a slow-motion speed
//  factor, then run it through a *fresh* `VideoImportModel` (its own
//  `MeasurementProcessor`, its own device snapshot) so the live camera
//  pipeline in `CameraCaptureScreen` is never touched. On success the model
//  itself publishes `appState.completedSession` / `showResults`; this view's
//  only job on `.finished` is to dismiss itself.
//
//  Styling mirrors the capture/format-sheet screens (Fluke-yellow chrome,
//  dark viewport card, ink-filled segmented chips) rather than introducing
//  a new visual language.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct VideoImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model: VideoImportModel?
    @State private var isPickerPresented = false

    private static let movieTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            content
        }
        .background(Theme.chrome.ignoresSafeArea())
        .onAppear {
            // No model yet ⇒ this is a fresh presentation of the flow;
            // go straight to the system picker (contract step 1).
            if model == nil { isPickerPresented = true }
        }
        .fileImporter(isPresented: $isPickerPresented,
                     allowedContentTypes: Self.movieTypes,
                     onCompletion: handlePicked)
        .onChange(of: model?.phase) { _, newPhase in
            // The model presents results itself (appState.completedSession /
            // showResults); this view's only remaining job is to get out of
            // the way once processing has handed off.
            if newPhase == .finished { dismiss() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("DAQPAL")
                    .font(Theme.ui(15, weight: .heavy))
                    .tracking(-0.15)
                    .foregroundStyle(Theme.ink)
                SectionLabel(text: "IMPORT VIDEO", size: 8)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 6)
            closeButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Theme.chrome)
    }

    private var closeButton: some View {
        Button {
            model?.cancel()
            dismiss()
        } label: {
            Text("✕")
                .font(Theme.ui(13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.heavyRule, lineWidth: 1))
                // Visual chip stays small; grow the tap target to the
                // required ≥44 pt without affecting layout.
                .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close video import")
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.heavyRule)
            .frame(height: 2)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let model {
            switch model.phase {
            case .loading:
                loadingState
            case .configuring:
                ScrollView {
                    configureContent(model)
                        .padding(16)
                }
            case .processing(let framesProcessed, let estimatedTotal):
                processingState(model, framesProcessed: framesProcessed, estimatedTotal: estimatedTotal)
            case .finished:
                finishedState
            case .failed(let message):
                failedState(model, message: message)
            }
        } else {
            pickerState
        }
    }

    private var pickerState: some View {
        VStack(spacing: 14) {
            SectionLabel(text: "SELECT A VIDEO", size: 12, color: Theme.ink)
            Text("Pick a recorded instrument video — normal speed or slow-motion — to process offline.")
                .font(Theme.ui(11))
                .foregroundStyle(Theme.inkMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                isPickerPresented = true
            } label: {
                Text("CHOOSE FILE")
                    .font(Theme.ui(12, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)
            .accessibilityLabel("Choose a video file")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(Theme.ink)
            SectionLabel(text: "READING VIDEO METADATA", color: Theme.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var finishedState: some View {
        // Transitional only — `onChange` above dismisses as soon as `phase`
        // flips to `.finished`; this covers the brief frame before that.
        VStack(spacing: 10) {
            SectionLabel(text: "DONE", size: 12, color: Theme.ink)
            ProgressView()
                .tint(Theme.ink)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Configure

    @ViewBuilder
    private func configureContent(_ model: VideoImportModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ImportViewportCard(model: model)
            speedSection(model)
            formatSection(model)
            processButton(model)
        }
    }

    private func speedSection(_ model: VideoImportModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "SPEED")
            HStack(spacing: 6) {
                ForEach(Array(VideoImportModel.speedPresets.enumerated()), id: \.offset) { _, preset in
                    speedChip(preset, model: model)
                }
            }
            Text(speedCaption(model))
                .font(Theme.mono(10, weight: .medium))
                .foregroundStyle(Theme.inkMuted)
            if model.suggestsRealTime {
                Text("HIGH-FRAME-RATE FILE — TIMESTAMPS ARE ALREADY REAL TIME, USE 1×")
                    .font(Theme.ui(9, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(Theme.roiSearching)
            }
        }
    }

    private func speedChip(_ preset: (label: String, factor: Double), model: VideoImportModel) -> some View {
        let isSelected = model.speedFactor == preset.factor
        return Button {
            model.speedFactor = preset.factor
        } label: {
            Text(preset.label)
                .font(Theme.ui(11, weight: .heavy))
                .foregroundStyle(isSelected ? Theme.brandYellow : Theme.ink)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 5).fill(isSelected ? Theme.ink : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.heavyRule, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle().inset(by: -8))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel("Speed \(preset.label)")
    }

    /// "24 fps · 2.0s captured → 8.0s real-time" — file fps/duration plus the
    /// normalized (real capture time) duration at the current speed factor.
    private func speedCaption(_ model: VideoImportModel) -> String {
        let fps = model.nominalFrameRate.map { String(format: "%.0f fps", Double($0)) } ?? "— fps"
        let duration = model.assetDuration.map { String(format: "%.1fs", $0) } ?? "—s"
        let normalized = model.assetDuration.map { String(format: "%.1fs", $0 * model.speedFactor) } ?? "—s"
        return "\(fps) · \(duration) captured  →  \(normalized) real-time"
    }

    private func formatSection(_ model: VideoImportModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "FORMAT")
            Text(model.device.displayFormat.patternPreview)
                .font(Theme.mono(15, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.brandYellow)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink))
                .accessibilityLabel("Display format \(model.device.displayFormat.patternPreview)")
            Text("Format is edited on the capture screen.")
                .font(Theme.ui(9))
                .foregroundStyle(Theme.inkMuted)
        }
    }

    private func processButton(_ model: VideoImportModel) -> some View {
        let enabled = model.roi != nil
        return Button {
            model.startProcessing(appState: appState)
        } label: {
            Text("PROCESS VIDEO")
                .font(Theme.ui(13, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.ink.opacity(enabled ? 1 : 0.4))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow.opacity(enabled ? 1 : 0.4)))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("Process video")
    }

    // MARK: Processing

    private func processingState(_ model: VideoImportModel, framesProcessed: Int, estimatedTotal: Int?) -> some View {
        VStack(spacing: 18) {
            SectionLabel(text: "PROCESSING VIDEO", size: 12, color: Theme.ink)
            VStack(spacing: 10) {
                if let estimatedTotal, estimatedTotal > 0 {
                    ProgressView(value: Double(framesProcessed), total: Double(estimatedTotal))
                        .tint(Theme.brandYellow)
                        .frame(maxWidth: 260)
                } else {
                    ProgressView()
                        .tint(Theme.brandYellow)
                }
                Text(progressText(framesProcessed, estimatedTotal))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Button {
                model.cancel()
            } label: {
                Text("CANCEL")
                    .font(Theme.ui(12, weight: .heavy))
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 24)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.heavyRule, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel video processing")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }

    private func progressText(_ processed: Int, _ total: Int?) -> String {
        if let total {
            return "FRAMES \(processed) / ~\(total)"
        }
        return "FRAMES \(processed)"
    }

    // MARK: Failed

    private func failedState(_ model: VideoImportModel, message: String) -> some View {
        VStack(spacing: 16) {
            errorChip(message)
            HStack(spacing: 10) {
                Button {
                    self.model = nil
                    isPickerPresented = true
                } label: {
                    Text("TRY ANOTHER FILE")
                        .font(Theme.ui(12, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.brandYellow))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Try another file")

                Button {
                    dismiss()
                } label: {
                    Text("CLOSE")
                        .font(Theme.ui(12, weight: .heavy))
                        .tracking(0.5)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.heavyRule, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close video import")
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorChip(_ message: String) -> some View {
        Text("✕ " + message)
            .font(Theme.ui(10, weight: .semibold))
            .foregroundStyle(Theme.searchingChipForeground)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.rejectedRowBackground))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.searchingChipForeground.opacity(0.25), lineWidth: 1))
    }

    // MARK: Picking / import

    private func handlePicked(_ result: Result<URL, Error>) {
        switch result {
        case .failure:
            // User cancelled the picker, or the system reported a failure —
            // contract: cancel/failure at this stage dismisses the flow.
            dismiss()
        case .success(let url):
            Task { await beginImport(from: url) }
        }
    }

    /// Copies the picked file out of the picker's security-scoped location
    /// into a private temp file, then loads the fresh `VideoImportModel`'s
    /// metadata. The temp copy outlives the security scope so processing
    /// (which can run far longer than the picker handoff) can keep reading it.
    private func beginImport(from url: URL) async {
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let device = appState.devices.first else {
            dismiss()
            return
        }
        do {
            let copiedURL = try Self.copyToTemporaryLocation(url)
            let importModel = VideoImportModel(videoURL: copiedURL, device: device)
            model = importModel
            await importModel.loadMetadata()
        } catch {
            dismiss()
        }
    }

    private static func copyToTemporaryLocation(_ sourceURL: URL) throws -> URL {
        let ext = sourceURL.pathExtension.isEmpty ? "mov" : sourceURL.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }
}

// MARK: - Viewport card

/// Fixed-height dark card showing the video's first frame aspect-FILL (not
/// aspect-fit — the design convention everywhere else in the app), with the
/// import ROI window overlaid via the same `AspectFillMapper` math the live
/// capture screen uses, so ROI coordinates line up exactly with what
/// `MeasurementProcessor` will crop during processing.
private struct ImportViewportCard: View {
    let model: VideoImportModel

    private static let cardHeight: CGFloat = 260
    /// Matches the project-wide portrait fallback used before real
    /// dimensions are known (mirrors `ROISelectionOverlay`'s fallback).
    private static let fallbackContentSize = CGSize(width: 1080, height: 1920)

    var body: some View {
        GeometryReader { geo in
            let mapper = AspectFillMapper(contentSize: model.videoDimensions ?? Self.fallbackContentSize,
                                          containerSize: geo.size)
            ZStack {
                if let image = model.firstFrame {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                ImportROIWindow(model: model, mapper: mapper)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: Self.cardHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.cameraArea)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A slim, single-window ROI editor bound directly to `model.roi` — the
/// import flow has exactly one device and no live lock/search state, so this
/// intentionally does not reuse `ROISelectionOverlay` (which is per the
/// live multi-device capture screen and reads `AppState`/`liveReadings`).
/// Drag/resize interaction mirrors that screen's window styling (yellow
/// border, 4 corner handles, ≥44 pt hit areas, clamped via
/// `NormalizedROI.clamped()`), but writes straight to `model.roi`.
private struct ImportROIWindow: View {
    let model: VideoImportModel
    let mapper: AspectFillMapper

    private enum Handle: CaseIterable, Hashable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    @State private var windowDragAnchor: CGRect?
    @State private var resizeAnchor: CGRect?

    private static let handleVisualSize: CGFloat = 8
    private static let handleHitSize: CGFloat = 44
    private static let minimumViewSize: CGFloat = 32

    private var isPlaced: Bool { model.roi != nil }
    private var containerSize: CGSize { mapper.containerSize }

    /// A centered starting window shown before the user has placed one,
    /// sized like the live capture screen's default ROI.
    private var ghostNormalizedROI: NormalizedROI {
        let w = NormalizedROI.defaultROI.width
        let h = NormalizedROI.defaultROI.height
        return NormalizedROI(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    private var currentRect: CGRect {
        mapper.viewRect(fromNormalized: model.roi ?? ghostNormalizedROI)
    }

    var body: some View {
        let rect = currentRect
        window(in: rect)
            .position(x: rect.midX, y: rect.midY)
            .opacity(isPlaced ? 1 : 0.6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(isPlaced
                ? "Import region of interest placed"
                : "Import region of interest, not placed. Drag to place over the display.")
    }

    @ViewBuilder
    private func window(in rect: CGRect) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.brandYellow, lineWidth: 2)
                .shadow(color: isPlaced ? Theme.brandYellow.opacity(0.45) : .clear, radius: isPlaced ? 8 : 0)
                .contentShape(Rectangle())
                .gesture(windowDragGesture)

            if isPlaced {
                ForEach(Handle.allCases, id: \.self) { h in
                    handle(h)
                        .position(handleCorner(h, in: rect.size))
                }
            }
        }
        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
        .overlay(alignment: .topLeading) {
            label.offset(x: -2, y: -24)
        }
    }

    private var label: some View {
        Text(isPlaced ? "⠿ IMPORT ROI" : "DRAG TO PLACE")
            .font(Theme.ui(10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.brandYellow))
    }

    private func handle(_ h: Handle) -> some View {
        ZStack {
            Color.clear.frame(width: Self.handleHitSize, height: Self.handleHitSize)
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.brandYellow)
                .frame(width: Self.handleVisualSize, height: Self.handleVisualSize)
        }
        .contentShape(Rectangle())
        .gesture(resizeGesture(for: h))
        .accessibilityHidden(true)
    }

    private func handleCorner(_ h: Handle, in size: CGSize) -> CGPoint {
        switch h {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: size.width, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: size.height)
        case .bottomRight: CGPoint(x: size.width, y: size.height)
        }
    }

    // MARK: Gestures

    private var windowDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let anchor = windowDragAnchor ?? currentRect
                windowDragAnchor = anchor
                var moved = anchor.offsetBy(dx: value.translation.width, dy: value.translation.height)
                moved.origin.x = min(max(moved.origin.x, 0), max(0, containerSize.width - moved.width))
                moved.origin.y = min(max(moved.origin.y, 0), max(0, containerSize.height - moved.height))
                commit(moved)
            }
            .onEnded { _ in windowDragAnchor = nil }
    }

    private func resizeGesture(for h: Handle) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let anchor = resizeAnchor ?? currentRect
                resizeAnchor = anchor
                var left = anchor.minX, right = anchor.maxX
                var top = anchor.minY, bottom = anchor.maxY
                switch h {
                case .topLeft:
                    left += value.translation.width
                    top += value.translation.height
                case .topRight:
                    right += value.translation.width
                    top += value.translation.height
                case .bottomLeft:
                    left += value.translation.width
                    bottom += value.translation.height
                case .bottomRight:
                    right += value.translation.width
                    bottom += value.translation.height
                }
                left = max(0, left)
                top = max(0, top)
                right = min(containerSize.width, right)
                bottom = min(containerSize.height, bottom)
                if right - left < Self.minimumViewSize {
                    switch h {
                    case .topLeft, .bottomLeft: left = right - Self.minimumViewSize
                    default: right = left + Self.minimumViewSize
                    }
                }
                if bottom - top < Self.minimumViewSize {
                    switch h {
                    case .topLeft, .topRight: top = bottom - Self.minimumViewSize
                    default: bottom = top + Self.minimumViewSize
                    }
                }
                commit(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            }
            .onEnded { _ in resizeAnchor = nil }
    }

    /// Converts a view-space rect back to normalized ROI space and writes it
    /// straight to `model.roi` — no `AppState` involved, per the import
    /// flow's isolation rule.
    private func commit(_ viewRect: CGRect) {
        model.roi = mapper.normalizedRect(fromViewRect: viewRect).clamped()
    }
}
