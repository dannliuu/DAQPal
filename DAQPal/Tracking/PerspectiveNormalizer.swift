//
//  PerspectiveNormalizer.swift
//  DAQPal
//
//  Warps a tracked display quad into a canonical, axis-aligned,
//  perspective-corrected image (spec §10 "Canonical Perspective
//  Normalization", Phase 9) — the shared upstream step for both field
//  analysis and OCR, so both consumers see the same upright, undistorted
//  view of the display regardless of viewing angle.
//
//  Coordinate handling is the entire risk surface here. `ScreenQuad` corners
//  are normalized, TOP-LEFT origin (buffer/frame space, project-wide — see
//  `NormalizedROI` doc). Core Image's coordinate space is BOTTOM-LEFT
//  origin, y-up — the same space `PixelBufferROI` flips into for cropping.
//  Converting a normalized top-left point to a CI pixel point is
//  `(x * width, (1 - y) * height)`: a point near the visual top of the
//  frame (small normalized y) lands at a *large* CI y, because CI counts up
//  from the bottom, so "near the top" is "far from the CI origin". That is
//  a pure coordinate re-basing, not a corner relabeling — the corner the
//  project calls `topLeft` is, after conversion, still the point nearest
//  the visual top-left of the image, just expressed in CI's frame. It is
//  therefore passed straight through as `CIPerspectiveCorrection`'s
//  `inputTopLeft`, `topRight` → `inputTopRight`, and so on — no diagonal
//  swap. Getting this wrong silently flips the canonical image upside
//  down, which corrupts every field coordinate and OCR read downstream;
//  `PerspectiveNormalizerTests` asserts the orientation directly rather
//  than trusting this reasoning alone.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Foundation

enum PerspectiveNormalizer {
    /// One shared context for the process — CIContext creation is expensive
    /// and the context is thread-safe. `cacheIntermediates` is off: every
    /// frame is new, so caching would only grow memory.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Long-edge cap on a derived (caller did not request a specific size)
    /// output — keeps a large or very close display from producing an
    /// oversized canonical buffer.
    private static let maxOutputEdge: CGFloat = 2048
    /// Below this either dimension is not a usable image (and likely means
    /// the quad's apparent size collapsed to noise).
    private static let minOutputEdge: CGFloat = 8

    /// Warps the region bounded by `quad` (frame/buffer space, normalized,
    /// top-left origin) into an upright, perspective-corrected image sized
    /// `outputSize`, or a size derived from the quad's apparent resolution
    /// when nil (see `derivedOutputSize`).
    ///
    /// Never throws. Returns nil for a non-convex/degenerate quad, a
    /// degenerate output size, or a Core Image / allocation failure —
    /// callers treat that as "no canonical image this frame", same as a
    /// lost target.
    static func canonicalImage(from buffer: CVPixelBuffer,
                               quad: ScreenQuad,
                               outputSize: CGSize? = nil) -> CVPixelBuffer? {
        guard quad.isConvex else { return nil }

        let imageSize = CGSize(width: CVPixelBufferGetWidth(buffer),
                               height: CVPixelBufferGetHeight(buffer))
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        let size = outputSize ?? derivedOutputSize(for: quad, imageSize: imageSize)
        guard size.width >= minOutputEdge, size.height >= minOutputEdge else { return nil }

        return PipelineMetrics.shared.measure(.analysis) {
            render(buffer: buffer, quad: quad, imageSize: imageSize, outputSize: size)
        }
    }

    /// Maps a region in canonical (perspective-corrected, unit-square)
    /// space back to a frame-space axis-aligned box via `quad`'s
    /// canonical→frame homography — for callers that want to crop straight
    /// from the original frame rather than warp. Standalone counterpart of
    /// `ScreenField.frameRegion(in:)`, for callers that have a quad but not
    /// a `TrackedTarget`.
    ///
    /// Nil when the quad is non-convex/degenerate or the region's corners
    /// are unmappable (behind the camera plane). `Homography.solve` alone
    /// would not catch a non-convex quad — the DLT system it solves is only
    /// singular for degenerate (collinear/duplicate) corners, not for a
    /// self-intersecting one — so convexity is checked explicitly here, same
    /// precondition as `canonicalImage`.
    static func canonicalRegion(_ region: NormalizedROI, ofQuad quad: ScreenQuad) -> NormalizedROI? {
        guard quad.isConvex,
              let canonicalToFrame = Homography.solve(from: .canonical, to: quad),
              let projected = canonicalToFrame.apply(ScreenQuad(roi: region)) else { return nil }
        return projected.boundingBox.clamped()
    }

    /// A sensible default output size: the quad's apparent pixel resolution
    /// (mean edge lengths, which are normalized, scaled by the source
    /// buffer size), so the canonical image preserves the display's real
    /// resolution without upscaling noise from an undersized target. Capped
    /// on the long edge so a display that fills the frame doesn't produce
    /// an unbounded buffer.
    private static func derivedOutputSize(for quad: ScreenQuad, imageSize: CGSize) -> CGSize {
        let rawWidth = quad.meanWidth * imageSize.width
        let rawHeight = quad.meanHeight * imageSize.height
        guard rawWidth > 0, rawHeight > 0 else { return .zero }

        let longEdge = max(rawWidth, rawHeight)
        let scale = longEdge > maxOutputEdge ? maxOutputEdge / longEdge : 1
        return CGSize(width: (rawWidth * scale).rounded(), height: (rawHeight * scale).rounded())
    }

    private static func render(buffer: CVPixelBuffer,
                               quad: ScreenQuad,
                               imageSize: CGSize,
                               outputSize: CGSize) -> CVPixelBuffer? {
        // Top-left-normalized → CI bottom-left pixel space; see file header.
        func ciPoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * imageSize.width, y: (1 - p.y) * imageSize.height)
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = CIImage(cvPixelBuffer: buffer)
        filter.topLeft = ciPoint(quad.topLeft)
        filter.topRight = ciPoint(quad.topRight)
        filter.bottomRight = ciPoint(quad.bottomRight)
        filter.bottomLeft = ciPoint(quad.bottomLeft)

        guard let corrected = filter.outputImage else { return nil }
        let extent = corrected.extent
        guard extent.width > 0, extent.height > 0, extent.isEmpty == false else { return nil }

        // The filter's output extent is exactly the corrected quad's own
        // bounding size (no built-in output-size knob); normalize origin to
        // zero, then scale to the requested canonical size.
        let scaled = corrected
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: outputSize.width / extent.width,
                                               y: outputSize.height / extent.height))

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(outputSize.width),
                                         Int(outputSize.height),
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &output)
        guard status == kCVReturnSuccess, let output else { return nil }

        context.render(scaled, to: output, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: nil)
        return output
    }
}
