//
//  InteractionState.swift
//  DAQPal
//
//  A lock-free mirror of "the user's finger is currently on a selection
//  window", readable from the frame loop WITHOUT hopping to the main actor.
//
//  Why this exists (Gate 2A, measured). The capture drain needs to know whether
//  a gesture is in progress so it can stand down. `AppState.isEditingROI` is
//  MainActor-isolated, so reading it per frame costs a main-actor hop — and the
//  main actor is exactly the resource a drag is competing for. Asking "is the
//  user busy?" by queueing work behind the user is self-defeating.
//
//  Writes happen twice per gesture (down, up). Reads happen once per frame.
//  `OSAllocatedUnfairLock` matches the pattern already used for live motion
//  switching in `SyntheticFrameSource`.
//

import Foundation
import os

/// Process-wide interaction flag shared between the UI and the capture drain.
final class InteractionState: @unchecked Sendable {
    static let shared = InteractionState()

    private let dragging = OSAllocatedUnfairLock(initialState: false)

    /// True while the user is actively dragging or resizing a selection window.
    var isUserInteracting: Bool {
        get { dragging.withLock { $0 } }
        set { dragging.withLock { $0 = newValue } }
    }
}
