//
//  LiveCameraFrameSource.swift
//  DAQPal
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os

/// Bridges the `AVCaptureVideoDataOutput` sample-buffer delegate into an
/// `AsyncStream<TimestampedFrame>` (spec §40.3, Milestone 2).
///
/// Backpressure: the stream buffers with `.bufferingNewest(1)`, so when the
/// pipeline is still busy with frame N, frame N+1 replaces any waiting frame
/// instead of queueing — combined with `alwaysDiscardsLateVideoFrames` on the
/// output, the app degrades to a lower effective processing rate under load
/// (spec §20), never falling behind real time.
///
/// `@unchecked Sendable` justification (required — the instance is shared
/// between the MainActor-owned `CameraManager` and the capture delegate
/// queue): the mutable state is `streams` and `frameTapStore`, each guarded by
/// its own `OSAllocatedUnfairLock`. Yielded frames follow the linear-ownership
/// rule documented on `TimestampedFrame`.
final class LiveCameraFrameSource: NSObject, FrameSource,
                                   AVCaptureVideoDataOutputSampleBufferDelegate,
                                   @unchecked Sendable {

    private struct StreamState {
        var continuation: AsyncStream<TimestampedFrame>.Continuation?
        /// Distinguishes streams so a stale stream's termination handler never
        /// clears a newer stream's continuation.
        var generation: UInt64 = 0
    }

    private let streams = OSAllocatedUnfairLock(initialState: StreamState())

    /// The session-video tee, kept behind its own lock. Separate from `streams`
    /// so the (trivially `Sendable`) stream state keeps using the checked
    /// `withLock`; the tap holds a non-`Sendable` closure, so it needs the
    /// unchecked variant — isolating it avoids infecting the stream state.
    /// (`uncheckedState:` is required because the stored closure isn't Sendable;
    /// safety comes from the lock, per the class's `@unchecked Sendable` note.)
    private let frameTapStore = OSAllocatedUnfairLock<((TimestampedFrame) -> Void)?>(uncheckedState: nil)

    /// Invoked synchronously on the capture queue for EVERY delegate frame,
    /// upstream of the drop-prone stream yield — the session video recorder
    /// hooks this so its `.mov` captures every frame, not the OCR-throttled
    /// subset. Keep the closure cheap (a bare `AVAssetWriterInput.append`).
    /// Thread-safe: backed by `frameTapStore`, so it can be set from the
    /// MainActor while the capture queue reads it.
    var frameTap: ((TimestampedFrame) -> Void)? {
        get { frameTapStore.withLockUnchecked { $0 } }
        set { frameTapStore.withLockUnchecked { $0 = newValue } }
    }

    // MARK: FrameSource

    /// Single-consumer: starting a new stream finishes any previous one.
    func frames() -> AsyncStream<TimestampedFrame> {
        let (stream, continuation) = AsyncStream.makeStream(of: TimestampedFrame.self,
                                                            bufferingPolicy: .bufferingNewest(1))
        let (previous, generation) = streams.withLock { state -> (AsyncStream<TimestampedFrame>.Continuation?, UInt64) in
            let old = state.continuation
            state.generation &+= 1
            state.continuation = continuation
            return (old, state.generation)
        }
        previous?.finish()
        continuation.onTermination = { [weak self] _ in
            self?.streams.withLock { state in
                if state.generation == generation { state.continuation = nil }
            }
        }
        return stream
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    /// Called on the capture output's dedicated serial queue (never main).
    /// Buffers arrive portrait-upright because `CameraManager` sets
    /// `videoRotationAngle = 90` on the output connection.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let frame = TimestampedFrame(pixelBuffer: pixelBuffer, timestamp: timestamp)

        // Tee to the recorder BEFORE the drop-prone `.bufferingNewest(1)` yield,
        // so the movie gets every captured frame even when OCR runs behind.
        // The same frame now fans out to two consumers (recorder + OCR stream);
        // this stays within `TimestampedFrame`'s ownership rule because both
        // only READ the buffer (H.264 encode / Vision) — the producer never
        // mutates it after handoff and concurrent `CVPixelBuffer` reads are safe.
        let tap = frameTapStore.withLockUnchecked { $0 }
        tap?(frame)

        let continuation = streams.withLock { $0.continuation }
        continuation?.yield(frame)
    }
}
