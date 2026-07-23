//
//  NormalizedROI.swift
//  DAQPal
//

import CoreGraphics
import Foundation

/// A region of interest in normalized, oriented (upright) image space.
///
/// Coordinate convention (project-wide):
/// - All components are in 0...1.
/// - Origin is the **top-left** of the upright image, matching SwiftUI view space.
/// - "Oriented image space" means the image as the user sees it. The camera
///   pipeline rotates capture buffers to portrait before they reach the
///   processing pipeline (see `CameraManager`), so buffer space == oriented
///   space everywhere downstream of capture.
struct NormalizedROI: Codable, Equatable, Hashable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    static let minimumWidth: CGFloat = 0.05
    static let minimumHeight: CGFloat = 0.03

    /// A sensible starting window for a newly added device.
    static let defaultROI = NormalizedROI(x: 0.25, y: 0.42, width: 0.5, height: 0.16)

    init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    /// Clamped to the unit square while enforcing a minimum size.
    func clamped() -> NormalizedROI {
        var w = min(max(width, Self.minimumWidth), 1)
        var h = min(max(height, Self.minimumHeight), 1)
        let cx = min(max(x, 0), 1 - w)
        let cy = min(max(y, 0), 1 - h)
        w = min(w, 1 - cx)
        h = min(h, 1 - cy)
        return NormalizedROI(x: cx, y: cy, width: w, height: h)
    }

    /// Pixel-space rect within an upright image of the given size, integral and
    /// clamped to the image bounds.
    func pixelRect(in imageSize: CGSize) -> CGRect {
        let raw = CGRect(x: x * imageSize.width,
                         y: y * imageSize.height,
                         width: width * imageSize.width,
                         height: height * imageSize.height)
        return raw.integral.intersection(CGRect(origin: .zero, size: imageSize))
    }
}
