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
/// queue): the only mutable state is `streams`, and every access goes through
/// the `OSAllocatedUnfairLock`. Yielded frames follow the linear-ownership
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
        let continuation = streams.withLock { $0.continuation }
        continuation?.yield(TimestampedFrame(pixelBuffer: pixelBuffer, timestamp: timestamp))
    }
}
