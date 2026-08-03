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
    /// The intelligent screen-locking stage. Runs BEFORE recognition so the
    /// tracked geometry it produces is applied to the very frame it was
    /// measured from. Idle (and effectively free) until enabled, which is what
    /// keeps the manual workflow the untouched default.
    private let lockPipeline: ScreenLockPipeline
    /// Services on-demand sub-field analysis of manually placed windows. Costs
    /// nothing per frame while no request is outstanding (`analyze` is a
    /// dictionary-empty check), which is the overwhelmingly common case.
    private let windowAnalyzer: WindowFieldAnalyzer
    /// Held weakly so a running `FrameProcessor` never keeps `AppState` alive
    /// past its owner; results simply stop being applied once it is gone.
    private weak var appState: AppState?
    private var task: Task<Void, Never>?

    init(source: any FrameSource,
         processor: MeasurementProcessor,
         appState: AppState,
         lockPipeline: ScreenLockPipeline,
         windowAnalyzer: WindowFieldAnalyzer) {
        self.source = source
        self.processor = processor
        self.appState = appState
        self.lockPipeline = lockPipeline
        self.windowAnalyzer = windowAnalyzer
    }

    func start() {
        guard task == nil else { return }
        let source = self.source
        let processor = self.processor
        let lockPipeline = self.lockPipeline
        let windowAnalyzer = self.windowAnalyzer
        // Captured weakly (not via `self`) so the consuming Task never keeps
        // either this object or `AppState` alive beyond `stop()`.
        weak let appState = self.appState
        task = Task {
            for await frame in source.frames() {
                if Task.isCancelled { break }

                // STAND DOWN WHILE THE USER IS DRAGGING (Gate 2A, measured).
                //
                // This is a correctness fix before it is a performance one: the
                // ROI is in motion under the finger, so anything recognised
                // from it is read from a region the user is still choosing. The
                // result is meaningless and would be rejected anyway.
                //
                // It is also where the "sluggish" half of the reported defect
                // comes from. While SEARCHING nothing is ever accepted, so the
                // pipeline never short-circuits and `DualPassVisionOCR` runs its
                // `.accurate` pass — documented at ~382 ms — on every single
                // frame, continuously, for the whole gesture. Skipping the
                // expensive stages frees both the drain and the two main-actor
                // hops below, which otherwise queue against touch handling.
                //
                // Read lock-free: asking the MAIN ACTOR whether the main actor
                // is busy would defeat the purpose.
                if InteractionState.shared.isUserInteracting {
                    PipelineMetrics.shared.recordDroppedFrame()
                    continue
                }

                // Only pay the main-actor hop for acquisition inputs when the
                // intelligent path is actually enabled. It is OFF by default,
                // so this hop was pure per-frame waste in the shipping
                // configuration.
                var inputs: AppState.ScreenLockInputs?
                if await lockPipeline.enabled {
                    inputs = await MainActor.run { appState?.screenLockInputs() }
                }
                let lock = await lockPipeline.process(frame: frame,
                                                      selection: inputs?.selection,
                                                      isUserDragging: false)
                if Task.isCancelled { break }

                // `measurementsValid` is what makes tracking-invalidity
                // observable downstream: with it false, every field-backed
                // device yields a REJECTED `.trackingInvalid` measurement
                // instead of silently vanishing from the record. Idle (manual
                // mode) passes `true` — there are no field-backed devices to
                // gate, and manual ROIs are ungated by design.
                let result = await processor.process(frame: frame,
                                                     roiOverrides: lock.fieldROIs,
                                                     requiringOverride: inputs?.fieldBackedDeviceIDs ?? [],
                                                     trackingValid: lock.isIdle || lock.measurementsValid)
                if Task.isCancelled { break }

                // Sub-field analysis of manually placed windows. Serviced here
                // so it reuses the frame already in hand rather than capturing
                // one of its own, and AFTER recognition so a pending request
                // can never delay the reading for the current frame.
                let windows = await windowAnalyzer.analyze(frame: frame.pixelBuffer)
                if Task.isCancelled { break }

                await MainActor.run {
                    appState?.applyScreenLock(lock)
                    appState?.apply(result)
                    appState?.applyWindowAnalyses(windows)
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
