//
//  SyntheticFrameSource.swift
//  DAQPal
//

import CoreGraphics
import CoreVideo
import Foundation
import UIKit

/// Renders a clearly-synthetic DMM-style display into a `CVPixelBuffer`:
/// a near-black instrument body with a lighter LCD panel showing large
/// monospaced digits. Used by `SyntheticFrameSource` (Simulator demo) and
/// directly by tests that need frames for arbitrary strings.
///
/// Honesty note: this is a stand-in for a physical display, not a model of
/// real DMM optics (segment gaps, glare, viewing angle). It exists so the
/// full recognition pipeline is exercisable without camera hardware — it
/// must never be presented as real-instrument data (see `CaptureStatus.simulated`
/// and the "SYNTHETIC SOURCE" UI labeling).
struct SyntheticDisplayRenderer {
    let size: CGSize

    /// Normalized location of the rendered LCD panel, top-left origin —
    /// matches project-wide ROI space. Lets a Simulator user drag a device
    /// window onto the panel, and lets tests build a `DeviceRecognitionConfig`
    /// that points at exactly where digits are drawn.
    static let displayROI = NormalizedROI(x: 0.12, y: 0.44, width: 0.76, height: 0.13)

    init(size: CGSize = CGSize(width: 1080, height: 1920)) {
        self.size = size
    }

    /// Draws `text` centered in the LCD panel over a `#0B0C0F` body.
    /// Returns `nil` if the pixel buffer or bitmap context cannot be created.
    func render(text: String) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        // premultipliedFirst + byteOrder32Little is the standard recipe for a
        // bitmap context whose memory layout matches kCVPixelFormatType_32BGRA.
        guard let context = CGContext(data: base,
                                      width: Int(size.width),
                                      height: Int(size.height),
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: Self.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }

        // CGContext's native origin is bottom-left; flip to top-left/y-down
        // so this drawing code and `NormalizedROI.pixelRect(in:)` agree.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(Self.backgroundColor)
        context.fill(CGRect(origin: .zero, size: size))

        let panelRect = Self.displayROI.pixelRect(in: size)
        context.setFillColor(Self.panelColor)
        context.addPath(CGPath(roundedRect: panelRect, cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.fillPath()

        UIGraphicsPushContext(context)
        let fontSize = panelRect.height * 0.62
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: UIColor(red: 0x14 / 255, green: 0x1A / 255, blue: 0x12 / 255, alpha: 1),
            .paragraphStyle: paragraph
        ])
        let textSize = attributed.size()
        let textRect = CGRect(x: panelRect.minX,
                              y: panelRect.midY - textSize.height / 2,
                              width: panelRect.width,
                              height: textSize.height)
        attributed.draw(in: textRect)
        UIGraphicsPopContext()

        return buffer
    }

    private static let colorSpace = CGColorSpaceCreateDeviceRGB()
    private static let backgroundColor = CGColor(red: 0x0B / 255, green: 0x0C / 255, blue: 0x0F / 255, alpha: 1)
    private static let panelColor = CGColor(red: 0xC9 / 255, green: 0xD6 / 255, blue: 0xC2 / 255, alpha: 1)
}

/// Programmatically-rendered DMM frames for the Simulator (no camera
/// hardware) and for pipeline tests (spec §40.3). Never a stand-in for
/// real-DMM accuracy — see `SyntheticDisplayRenderer` doc comment.
///
/// The value drifts slowly (`12.3 + 0.35·sin(0.4t)`) so the capture UI,
/// validators, and temporal filter all have something changing to react to.
final class SyntheticFrameSource: FrameSource {
    /// Forwards `SyntheticDisplayRenderer.displayROI` for convenience.
    static let displayROI = SyntheticDisplayRenderer.displayROI

    private let renderer: SyntheticDisplayRenderer
    private let frameInterval: TimeInterval

    init(fps: Double = 12, size: CGSize = CGSize(width: 1080, height: 1920)) {
        self.renderer = SyntheticDisplayRenderer(size: size)
        self.frameInterval = 1.0 / fps
    }

    func frames() -> AsyncStream<TimestampedFrame> {
        let renderer = self.renderer
        let frameInterval = self.frameInterval
        return AsyncStream { continuation in
            let task = Task {
                // Monotonic pacing clock — never wall-clock `Date`, so
                // timestamps stay correct regardless of system clock changes.
                let clock = ContinuousClock()
                let start = clock.now
                var frameIndex = 0
                while !Task.isCancelled {
                    let elapsed = Double(frameIndex) * frameInterval
                    let value = 12.3 + 0.35 * sin(0.4 * elapsed)
                    let text = String(format: "%.3f", value)
                    if let buffer = renderer.render(text: text) {
                        continuation.yield(TimestampedFrame(pixelBuffer: buffer, timestamp: elapsed))
                    }
                    frameIndex += 1
                    let nextElapsed = Double(frameIndex) * frameInterval
                    do {
                        try await clock.sleep(until: start.advanced(by: .seconds(nextElapsed)))
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
