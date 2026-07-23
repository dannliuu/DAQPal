//
//  FrameProcessor.swift
//  DAQPal
//

import Foundation

/// Serially drains a `FrameSource` through the `MeasurementProcessor` actor
/// and publishes each result to `AppState` on the main actor (spec §40.2/§40.3).
///
/// Backpressure is entirely a consequence of serial `await` consumption:
/// while `processor.process(frame:)` is running, no new frame is pulled from
/// the stream, so — combined with each `FrameSource`'s own drop-late policy —
/// a slow pipeline degrades to a lower effective rate instead of building an
/// internal queue.
final class FrameProcessor {
    private let source: any FrameSource
    private let processor: MeasurementProcessor
    /// Held weakly so a running `FrameProcessor` never keeps `AppState` alive
    /// past its owner; results simply stop being applied once it is gone.
    private weak var appState: AppState?
    private var task: Task<Void, Never>?

    init(source: any FrameSource, processor: MeasurementProcessor, appState: AppState) {
        self.source = source
        self.processor = processor
        self.appState = appState
    }

    func start() {
        guard task == nil else { return }
        let source = self.source
        let processor = self.processor
        // Captured weakly (not via `self`) so the consuming Task never keeps
        // either this object or `AppState` alive beyond `stop()`.
        weak let appState = self.appState
        task = Task {
            for await frame in source.frames() {
                if Task.isCancelled { break }
                let result = await processor.process(frame: frame)
                if Task.isCancelled { break }
                await MainActor.run {
                    appState?.apply(result)
                }
            }
        }
    }

    /// Cancels the consuming task. Note: if the underlying stream is
    /// currently suspended awaiting the *next* frame (source idle, e.g.
    /// camera already stopped), cancellation is observed on the following
    /// loop iteration rather than interrupting the suspended `await`
    /// immediately — callers that stop the frame producer (e.g.
    /// `CameraManager.stop()`) alongside this get prompt, clean shutdown.
    func stop() {
        task?.cancel()
        task = nil
    }
}
