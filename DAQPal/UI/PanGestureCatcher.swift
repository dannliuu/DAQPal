//
//  PanGestureCatcher.swift
//  DAQPal
//
//  A UIKit `UIPanGestureRecognizer` exposed to SwiftUI, used for the ROI window
//  drag in place of SwiftUI's `DragGesture`.
//
//  WHY, and what the measurements said. On device (iPhone 12 Pro Max, 60 Hz
//  native) an instrumented drag reports:
//
//      touch  : ticks 46 · p50 16.7ms · p95 17.7ms · stalls 0
//      render : frames 63 · exp 16.7ms · p50 16.7ms · max 16.7ms · dropped 0
//
//  Touch events arrive exactly once per display frame and NOT ONE FRAME IS
//  DROPPED, with the capture pipeline running. Both cadences are perfect, yet
//  the drag still reads as sluggish and jittery. Cadence was therefore never
//  the problem — LATENCY is, and a constant lag is invisible to both probes by
//  construction: a box rendered three frames behind the finger has flawless
//  cadence and still feels detached.
//
//  SwiftUI's gesture path costs several frames end to end (recognition →
//  `@State` write → `body` → layout → composite), and gesture recognition in a
//  deep hierarchy is the largest and least avoidable part. `UIPanGestureRecognizer`
//  delivers its first update on touch-down rather than after a disambiguation
//  window, and reports on the UIKit touch path directly.
//
//  `minimumDistance` note: the SwiftUI gesture used `minimumDistance: 2`, so
//  the window stayed still until the finger had moved 2 pt and then jumped,
//  because `DragGesture.translation` is measured from touch-down rather than
//  from the threshold crossing. That is a visible hitch at the start of every
//  drag. This recognizer begins immediately and reports translation from
//  touch-down, so there is nothing to catch up.
//
//  This changes ONLY how the drag is recognised. Rendering stays SwiftUI. If
//  latency remains after this, the next step is driving the window's position
//  through `CALayer` directly, which removes the remaining `body`/layout hops.
//

import SwiftUI
import UIKit

/// Reports pan translation in the coordinate space of the view it is attached
/// to. Phases mirror the `DragGesture` callbacks it replaces.
struct PanGestureCatcher: UIViewRepresentable {
    /// Fired on every movement update, with the cumulative translation since
    /// touch-down — the same semantics as `DragGesture.Value.translation`.
    var onChanged: (CGSize) -> Void
    /// Fired once when the finger lifts (or the gesture is cancelled), with the
    /// final cumulative translation.
    var onEnded: (CGSize) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = PassthroughView()
        let recognizer = UIPanGestureRecognizer(target: context.coordinator,
                                                action: #selector(Coordinator.handle(_:)))
        // One finger, no disambiguation delay.
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        // The overlay sits above a camera preview with no competing pan, so the
        // recognizer never needs to wait for another to fail. Waiting is where
        // the start-of-drag hitch comes from.
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.cancelsTouchesInView = false
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onChanged = onChanged
        context.coordinator.onEnded = onEnded
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChanged: onChanged, onEnded: onEnded)
    }

    final class Coordinator: NSObject {
        var onChanged: (CGSize) -> Void
        var onEnded: (CGSize) -> Void

        init(onChanged: @escaping (CGSize) -> Void, onEnded: @escaping (CGSize) -> Void) {
            self.onChanged = onChanged
            self.onEnded = onEnded
        }

        @objc func handle(_ recognizer: UIPanGestureRecognizer) {
            let t = recognizer.translation(in: recognizer.view)
            let translation = CGSize(width: t.x, height: t.y)
            switch recognizer.state {
            case .began, .changed:
                onChanged(translation)
            case .ended, .cancelled, .failed:
                onEnded(translation)
            default:
                break
            }
        }
    }

    /// Hosts the recognizer without swallowing touches meant for views behind
    /// it — the recognizer itself decides what it handles.
    private final class PassthroughView: UIView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            // Claim the point only when it is inside this view's own bounds, so
            // the ROI window's hit area behaves exactly as the `contentShape`
            // it replaces.
            bounds.contains(point) ? self : nil
        }
    }
}
