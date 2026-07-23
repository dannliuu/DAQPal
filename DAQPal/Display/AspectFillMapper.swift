//
//  AspectFillMapper.swift
//  DAQPal
//

import CoreGraphics

/// Maps between container (view) coordinates and normalized oriented-image
/// coordinates when the content is rendered aspect-fill inside the container.
///
/// The camera preview uses `AVLayerVideoGravity.resizeAspectFill`, which scales
/// the oriented video to cover the view and crops the overflow symmetrically.
/// A point on screen therefore does NOT correspond 1:1 to a normalized image
/// point — this type is the single place that conversion lives, and it is pure
/// math so it can be unit-tested without any camera.
struct AspectFillMapper: Equatable, Sendable {
    /// Size of the oriented content (e.g. 1080×1920 for a portrait buffer).
    let contentSize: CGSize
    /// Size of the container view in points.
    let containerSize: CGSize

    /// Scale applied to the content so it fills the container.
    var scale: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return max(containerSize.width / contentSize.width,
                   containerSize.height / contentSize.height)
    }

    /// Origin of the scaled content in container coordinates (components are
    /// ≤ 0 whenever the content overflows the container on that axis).
    var contentOrigin: CGPoint {
        CGPoint(x: (containerSize.width - contentSize.width * scale) / 2,
                y: (containerSize.height - contentSize.height * scale) / 2)
    }

    // MARK: Normalized (0...1, top-left origin) → view points

    func viewPoint(fromNormalized p: CGPoint) -> CGPoint {
        let origin = contentOrigin
        return CGPoint(x: p.x * contentSize.width * scale + origin.x,
                       y: p.y * contentSize.height * scale + origin.y)
    }

    func viewRect(fromNormalized roi: NormalizedROI) -> CGRect {
        let topLeft = viewPoint(fromNormalized: CGPoint(x: roi.x, y: roi.y))
        return CGRect(x: topLeft.x,
                      y: topLeft.y,
                      width: roi.width * contentSize.width * scale,
                      height: roi.height * contentSize.height * scale)
    }

    // MARK: View points → normalized

    func normalizedPoint(fromViewPoint p: CGPoint) -> CGPoint {
        let origin = contentOrigin
        let s = scale
        guard s > 0 else { return .zero }
        return CGPoint(x: (p.x - origin.x) / (contentSize.width * s),
                       y: (p.y - origin.y) / (contentSize.height * s))
    }

    /// Result is NOT clamped; callers clamp via `NormalizedROI.clamped()` so
    /// drag gestures can decide their own clamping behavior.
    func normalizedRect(fromViewRect rect: CGRect) -> NormalizedROI {
        let topLeft = normalizedPoint(fromViewPoint: rect.origin)
        let s = scale
        guard s > 0 else { return NormalizedROI(rect: .zero) }
        return NormalizedROI(x: topLeft.x,
                             y: topLeft.y,
                             width: rect.width / (contentSize.width * s),
                             height: rect.height / (contentSize.height * s))
    }
}
