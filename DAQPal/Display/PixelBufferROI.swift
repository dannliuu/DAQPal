//
//  PixelBufferROI.swift
//  DAQPal
//
//  CoreImage-based ROI crop (spec §40.5 step 16). One shared CIContext for
//  the process — CIContext creation is expensive and the context is
//  thread-safe, so all crops (any device, any frame) reuse it.
//

import CoreImage
import CoreVideo
import Foundation

enum PixelBufferROI {
    /// Software-renderer-free shared context. `cacheIntermediates` is off:
    /// every frame is new, so caching would only grow memory.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Crops an upright buffer to a normalized ROI (top-left origin) and
    /// returns a new upright 32BGRA buffer containing just that region.
    ///
    /// Returns nil when the ROI resolves to an empty pixel rect or the
    /// destination buffer cannot be allocated — callers treat that as
    /// `.displayLost`. Allocation note: one destination buffer per call; at
    /// MVP processing rates (≤ ~30 crops/s) this is cheap. A
    /// `CVPixelBufferPool` keyed by crop size is the follow-up if profiling
    /// ever says otherwise.
    static func cropped(_ buffer: CVPixelBuffer, to roi: NormalizedROI) -> CVPixelBuffer? {
        let imageSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                               height: CVPixelBufferGetHeight(buffer))
        let pixelRect = roi.clamped().pixelRect(in: imageSize)
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }

        // CIImage space has a bottom-left origin; `pixelRect` is top-left.
        // Flip y, then translate the crop back to the origin so the rendered
        // buffer starts at (0, 0).
        let ciRect = CGRect(x: pixelRect.minX,
                            y: imageSize.height - pixelRect.maxY,
                            width: pixelRect.width,
                            height: pixelRect.height)
        let image = CIImage(cvPixelBuffer: buffer)
            .cropped(to: ciRect)
            .transformed(by: CGAffineTransform(translationX: -ciRect.minX, y: -ciRect.minY))

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(pixelRect.width),
                                         Int(pixelRect.height),
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &output)
        guard status == kCVReturnSuccess, let output else { return nil }

        context.render(image, to: output)
        return output
    }
}
