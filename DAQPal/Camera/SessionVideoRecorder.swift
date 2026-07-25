//
//  SessionVideoRecorder.swift
//  DAQPal
//
//  Optional session video tee (spec §30–31 fixture capture): while REC is
//  active AND the user's "SAVE VIDEO" toggle is on, every captured frame is
//  appended to an `AVAssetWriter`, producing an `.mov` that is exactly what
//  OCR saw — frame-for-frame, timestamps aligned to the CSV timeline.
//
//  Pipeline placement (why this is fed from the capture-queue tap, not the OCR
//  stream): the live OCR stream uses `.bufferingNewest(1)` and DROPS frames
//  under load by design. The recorder is fed from `LiveCameraFrameSource`'s
//  `frameTap`, which runs on the capture queue upstream of that drop, so the
//  movie gets every frame the camera delivered even when OCR runs behind real
//  time.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

/// Arm / append / finish lifecycle around a single `AVAssetWriter`.
///
/// Threading strategy (documented per project rules): `start()`, `finish()`
/// and `discard()` are driven from the MainActor (via `CaptureStack`);
/// `append(_:)` is driven from the capture queue (device) or the synthetic
/// frame task (Simulator). Every piece of mutable state lives in `State`
/// behind `lock`, and that single invariant — no mutable state is touched
/// except while holding `lock` — is what makes the `@unchecked Sendable`
/// conformance sound. Appends arrive from exactly one serial producer, so the
/// lock only ever mediates append-vs-main contention (never append-vs-append).
final class SessionVideoRecorder: @unchecked Sendable {

    enum RecorderError: LocalizedError {
        /// `finish()` requested but nothing was ever appended — a toggle-on
        /// recording with an instant STOP, or every frame dropped. No movie.
        case noFramesAppended
        /// The writer could not be created/started for the first frame.
        case writerSetupFailed(String)
        /// `finishWriting` completed in a non-`.completed` state.
        case writerFinishFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFramesAppended:
                "No frames were captured, so there is no video to save."
            case .writerSetupFailed(let detail):
                "The video recorder could not start: \(detail)"
            case .writerFinishFailed(let detail):
                "The video file could not be finalized: \(detail)"
            }
        }
    }

    /// All mutable state; only ever touched while holding `lock`.
    private struct State {
        var armed = false
        var writer: AVAssetWriter?
        var input: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        var url: URL?
        var startTime: CMTime?
        var dimensions: CGSize?
        /// Set if the lazy first-frame writer creation threw; subsequent
        /// appends no-op and `finish()` surfaces this error.
        var setupError: Error?
        var appendedFrameCount = 0
        var droppedFrameCount = 0
    }

    /// Transient result of building the writer for the first frame.
    private struct WriterBundle {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let url: URL
        let startTime: CMTime
        let dimensions: CGSize
    }

    // `uncheckedState` because `State` holds non-Sendable AVFoundation objects;
    // the lock is the synchronization that makes accessing them across the
    // MainActor / capture-queue boundary safe.
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    // MARK: Introspection (honest frame accounting)

    var isArmed: Bool { lock.withLockUnchecked { $0.armed } }
    /// Frames handed to the writer. `appended + dropped` == frames offered.
    var appendedFrameCount: Int { lock.withLockUnchecked { $0.appendedFrameCount } }
    /// Frames the writer wasn't ready for (reported, never silently swallowed).
    var droppedFrameCount: Int { lock.withLockUnchecked { $0.droppedFrameCount } }

    // MARK: Lifecycle

    /// Arms the recorder for a fresh session. Idempotent while already armed;
    /// calling after a previous `finish()`/`discard()` begins a clean cycle
    /// (counters and writer refs reset).
    func start() {
        lock.withLockUnchecked { state in
            guard !state.armed else { return }
            state = State(armed: true)
        }
    }

    /// Called on the capture queue for every captured frame. Lazily builds the
    /// writer from the FIRST frame's pixel buffer, starts the session at that
    /// frame's timestamp, then appends. Non-blocking: if the input isn't ready
    /// the frame is dropped and counted rather than stalling the capture queue.
    /// Ignored entirely when not armed.
    func append(_ frame: TimestampedFrame) {
        lock.withLockUnchecked { state in
            guard state.armed, state.setupError == nil else { return }

            if state.writer == nil {
                // First frame: build the writer. Runs while holding `lock`, but
                // only once per session; it never re-enters this lock and the
                // AV objects don't call back into us, so there's no deadlock.
                do {
                    let bundle = try Self.makeWriter(firstFrame: frame)
                    state.writer = bundle.writer
                    state.input = bundle.input
                    state.adaptor = bundle.adaptor
                    state.url = bundle.url
                    state.startTime = bundle.startTime
                    state.dimensions = bundle.dimensions
                } catch {
                    state.setupError = error
                    return
                }
            }

            guard let writer = state.writer,
                  let input = state.input,
                  let adaptor = state.adaptor,
                  writer.status == .writing else {
                state.droppedFrameCount += 1
                return
            }
            // Never block the capture queue on writer readiness — drop instead.
            guard input.isReadyForMoreMediaData else {
                state.droppedFrameCount += 1
                return
            }

            // Absolute frame time. `startSession(atSourceTime:)` used the first
            // frame's time, so the movie timeline starts at ~0 here. The CSV's
            // `timestamp_s == 0` is the first PROCESSED frame — the same frame,
            // or within one capture interval of it — so the two timelines align.
            let time = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
            if adaptor.append(frame.pixelBuffer, withPresentationTime: time) {
                state.appendedFrameCount += 1
            } else {
                state.droppedFrameCount += 1
            }
        }
    }

    /// Ends the session and finalizes the file, returning the temp `.mov` URL
    /// on success. Disarms synchronously so no further frame is appended, then
    /// awaits `finishWriting` outside the lock. Zero appended frames (or a
    /// setup failure) is a descriptive failure with the temp file cleaned up.
    func finish() async -> Result<URL, Error> {
        let snapshot: (writer: AVAssetWriter?, input: AVAssetWriterInput?,
                       url: URL?, appended: Int, setupError: Error?) = lock.withLockUnchecked { state in
            state.armed = false   // stop accepting appends immediately
            return (state.writer, state.input, state.url,
                    state.appendedFrameCount, state.setupError)
        }

        if let setupError = snapshot.setupError {
            snapshot.writer?.cancelWriting()
            removeFile(snapshot.url)
            clearWriterRefs()
            return .failure(setupError)
        }

        guard let writer = snapshot.writer,
              let input = snapshot.input,
              let url = snapshot.url,
              snapshot.appended > 0 else {
            snapshot.writer?.cancelWriting()
            removeFile(snapshot.url)
            clearWriterRefs()
            return .failure(RecorderError.noFramesAppended)
        }

        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        let status = writer.status
        let writerError = writer.error
        clearWriterRefs()

        if status == .completed {
            return .success(url)
        }
        removeFile(url)
        return .failure(RecorderError.writerFinishFailed(
            writerError?.localizedDescription ?? "writer ended in status \(status.rawValue)"))
    }

    /// Cancels the in-flight writer and deletes the temp file without saving.
    func discard() {
        let (writer, url): (AVAssetWriter?, URL?) = lock.withLockUnchecked { state in
            state.armed = false
            let refs = (state.writer, state.url)
            state.writer = nil
            state.input = nil
            state.adaptor = nil
            state.url = nil
            state.startTime = nil
            state.setupError = nil
            return refs
        }
        if let writer, writer.status == .writing { writer.cancelWriting() }
        removeFile(url)
    }

    // MARK: Private

    private func clearWriterRefs() {
        lock.withLockUnchecked { state in
            state.writer = nil
            state.input = nil
            state.adaptor = nil
            state.url = nil
            state.startTime = nil
            state.setupError = nil
        }
    }

    private func removeFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Builds the writer/input/adaptor for the first frame: H.264 into a `.mov`
    /// sized to the pixel buffer, `expectsMediaDataInRealTime = true` because
    /// frames arrive live off the capture queue, and a pixel-buffer adaptor
    /// matching the source format. The session is started at the first frame's
    /// timestamp so the movie timeline runs from t=0.
    private static func makeWriter(firstFrame frame: TimestampedFrame) throws -> WriterBundle {
        let width = CVPixelBufferGetWidth(frame.pixelBuffer)
        let height = CVPixelBufferGetHeight(frame.pixelBuffer)
        guard width > 0, height > 0 else {
            throw RecorderError.writerSetupFailed("invalid frame dimensions \(width)×\(height)")
        }

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("daqpal_rec_\(UUID().uuidString).mov")

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw RecorderError.writerSetupFailed(error.localizedDescription)
        }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            ])

        guard writer.canAdd(input) else {
            throw RecorderError.writerSetupFailed("writer cannot add the video input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw RecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }
        let startTime = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
        writer.startSession(atSourceTime: startTime)

        return WriterBundle(writer: writer, input: input, adaptor: adaptor,
                            url: url, startTime: startTime,
                            dimensions: CGSize(width: width, height: height))
    }
}
