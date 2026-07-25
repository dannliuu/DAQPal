//
//  SyntheticDisplayGenerator.swift
//  DAQPalTests
//
//  OCR_RESEARCH.md Phase 1 — the offline synthetic display generator. Extends
//  the idea of the app-target `SyntheticDisplayRenderer` (which this file does
//  NOT modify) into a *deterministic, augmentable* source of labeled training
//  and benchmark imagery across the four display technologies DAQPal must read:
//  raster/proportional (OLED/graphical), 7-segment (DSEG7), 14-segment
//  (DSEG14), and dot-matrix (hand-coded 5x7).
//
//  HONESTY: everything this file produces is SYNTHETIC. It is a stand-in for
//  physical display optics, not a model of them, and must never be presented as
//  real-instrument data. Accuracy numbers derived from these images measure the
//  pipeline against a synthetic distribution only — the held-out human-labeled
//  eval set (which does not exist yet) is the sole source of real-instrument
//  accuracy claims.
//
//  DETERMINISM: no `Date()`, no unseeded RNG, and a software CoreImage renderer.
//  All pseudo-randomness (sensor noise, glare placement) comes from a fixed-seed
//  LCG keyed by (text, style, augmentationName), so the same recipe renders
//  byte-identical pixels on every run — a hard requirement for reproducible
//  datasets and the determinism test.
//
//  DEVIATION (documented): the contract lists "polarity" as the final pipeline
//  stage (a terminal invert). This implementation instead selects the base
//  glyph/background colors from `polarityInverted` up front, so `glow` (bloom of
//  the *lit* pixels) and `glare` operate on physically-correct polarity for
//  emissive displays. The observable result is equivalent — a clean inverted
//  tile is light-on-dark — while keeping the optical effects coherent; no other
//  agent depends on the internal stage order (only on the frozen API below).
//

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import CoreVideo
import Foundation
import UIKit
@testable import DAQPal

// MARK: - Frozen API

/// The four display technologies DAQPal must read. `.dotMatrix` is font-free
/// (hand-coded bitmaps) so the generator never depends on a proportional font
/// for the graphical-display case being distinct from the segment cases.
enum DisplayGlyphStyle: String, CaseIterable, Sendable {
    case sans            // raster/proportional (system font) — OLED/graphical displays
    case sevenSegment    // DSEG7 Classic
    case fourteenSegment // DSEG14 Classic
    case dotMatrix       // programmatic 5x7 dot matrix (no font dependency)
}

/// Deterministic augmentation recipe (seeded — same inputs produce identical
/// pixels). Each field is a normalized strength; see the per-field comments for
/// the physical effect each models.
struct DisplayAugmentation: Sendable {
    var polarityInverted: Bool   // light-on-dark (VFD/OLED) vs dark-on-light (LCD)
    var glow: CGFloat            // 0...1 bloom/glow strength (OLED/LED/VFD)
    var ghosting: CGFloat        // 0...1 faint "all segments on" residue (LCD)
    var glare: CGFloat           // 0...1 specular gradient blob strength
    var blur: CGFloat            // 0...1 gaussian blur radius scale
    var noise: CGFloat           // 0...1 sensor noise strength
    var perspectiveTilt: CGFloat // 0...1 keystone amount
    var contrast: CGFloat        // 0.3...1 contrast scale (1 = full)

    init(polarityInverted: Bool = false,
         glow: CGFloat = 0,
         ghosting: CGFloat = 0,
         glare: CGFloat = 0,
         blur: CGFloat = 0,
         noise: CGFloat = 0,
         perspectiveTilt: CGFloat = 0,
         contrast: CGFloat = 1) {
        self.polarityInverted = polarityInverted
        self.glow = glow
        self.ghosting = ghosting
        self.glare = glare
        self.blur = blur
        self.noise = noise
        self.perspectiveTilt = perspectiveTilt
        self.contrast = contrast
    }

    /// Crisp reference: no augmentation, full contrast, dark-on-light (LCD).
    static let clean = DisplayAugmentation()

    /// Mild everything — a "good phone photo of an LCD" operating point.
    static let moderate = DisplayAugmentation(polarityInverted: false,
                                              glow: 0.20,
                                              ghosting: 0.18,
                                              glare: 0.22,
                                              blur: 0.18,
                                              noise: 0.10,
                                              perspectiveTilt: 0.15,
                                              contrast: 0.82)

    /// Stress operating point — glare + blur + tilt + low contrast dominate.
    static let hard = DisplayAugmentation(polarityInverted: false,
                                          glow: 0.30,
                                          ghosting: 0.25,
                                          glare: 0.60,
                                          blur: 0.55,
                                          noise: 0.16,
                                          perspectiveTilt: 0.55,
                                          contrast: 0.42)

    /// The three base recipes plus polarity-inverted variants of clean/moderate
    /// (VFD/OLED emissive look). `dataset(...)` fans out over exactly these, and
    /// the benchmark harness selects by `name`.
    static let presets: [(name: String, augmentation: DisplayAugmentation)] = {
        var cleanInverted = DisplayAugmentation.clean
        cleanInverted.polarityInverted = true
        var moderateInverted = DisplayAugmentation.moderate
        moderateInverted.polarityInverted = true
        return [
            (name: "clean", augmentation: .clean),
            (name: "moderate", augmentation: .moderate),
            (name: "hard", augmentation: .hard),
            (name: "clean-inverted", augmentation: cleanInverted),
            (name: "moderate-inverted", augmentation: moderateInverted)
        ]
    }()
}

/// A rendered sample plus the labels a training/benchmark consumer needs.
struct SyntheticDisplaySample {
    let pixelBuffer: CVPixelBuffer
    let text: String
    let style: DisplayGlyphStyle
    let augmentationName: String
    /// Where the text sits within the buffer (top-left normalized). The
    /// generator knows this exactly; benchmark/sampler consumers rely on it.
    let textROI: NormalizedROI
}

/// Errors surfaced by the generator. Font problems fail at `init` (fonts are a
/// bundled prerequisite); allocation/render problems fail per call.
enum SyntheticDisplayError: Error, CustomStringConvertible {
    case fontResourceMissing(String)
    case fontRegistrationFailed(String)
    case unsupportedTileCharacter(Character)
    case bufferAllocationFailed
    case contextCreationFailed
    case renderFailed

    var description: String {
        switch self {
        case .fontResourceMissing(let name):
            return "DSEG font resource '\(name)' not found in the test bundle. It must be bundled at DAQPalTests/Fonts/ as a test-target resource."
        case .fontRegistrationFailed(let detail):
            return "CTFontManager failed to register a DSEG font: \(detail)"
        case .unsupportedTileCharacter(let c):
            return "digitTile character '\(c)' is not one of \"0123456789.-\" or a space"
        case .bufferAllocationFailed:
            return "CVPixelBufferCreate failed"
        case .contextCreationFailed:
            return "CGContext creation failed"
        case .renderFailed:
            return "CoreImage/CoreGraphics render produced no image"
        }
    }
}

// MARK: - Generator

final class SyntheticDisplayGenerator {

    static let defaultLineSize = CGSize(width: 640, height: 280)
    static let defaultTileSize = CGSize(width: 32, height: 48)

    /// Software renderer for byte-reproducible output regardless of the host's
    /// GPU; intermediates uncached because every frame is unique.
    private let ciContext = CIContext(options: [.useSoftwareRenderer: true,
                                                .cacheIntermediates: false])

    /// `(size) -> UIFont` resolvers for the two segment fonts. They prefer the
    /// registered PostScript name and fall back to a direct CGFont bridge, so
    /// rendering never depends on name-lookup succeeding.
    private let sevenFontMaker: (CGFloat) -> UIFont
    private let fourteenFontMaker: (CGFloat) -> UIFont

    /// Registers the bundled DSEG fonts once (idempotent) and prepares font
    /// resolvers. Throws `SyntheticDisplayError` if the fonts are missing.
    init() throws {
        let bundle = Bundle(for: SyntheticDisplayGenerator.self)
        let (seven, fourteen) = try SyntheticDisplayGenerator.prepareFonts(bundle: bundle)
        self.sevenFontMaker = SyntheticDisplayGenerator.makeFontMaker(cgFont: seven)
        self.fourteenFontMaker = SyntheticDisplayGenerator.makeFontMaker(cgFont: fourteen)
    }

    // MARK: Public rendering

    /// A full display line, e.g. "12.347" / "-0.05". `size` defaults to 640x280.
    func lineSample(text: String,
                    style: DisplayGlyphStyle,
                    augmentation: DisplayAugmentation,
                    augmentationName: String,
                    size: CGSize = SyntheticDisplayGenerator.defaultLineSize) throws -> SyntheticDisplaySample {
        let seedKey = "\(text)|\(style.rawValue)|\(augmentationName)"
        let (buffer, roi) = try render(text: text, style: style,
                                       augmentation: augmentation, seedKey: seedKey, size: size)
        return SyntheticDisplaySample(pixelBuffer: buffer, text: text, style: style,
                                      augmentationName: augmentationName, textROI: roi)
    }

    /// A single-glyph tile (default 32x48) for slot-classifier training/tests.
    /// `character` must be in "0123456789.-" or " " (blank cell).
    func digitTile(character: Character,
                   style: DisplayGlyphStyle,
                   augmentation: DisplayAugmentation,
                   size: CGSize = SyntheticDisplayGenerator.defaultTileSize) throws -> CVPixelBuffer {
        guard "0123456789.- ".contains(character) else {
            throw SyntheticDisplayError.unsupportedTileCharacter(character)
        }
        // Tiles take no augmentationName; key on polarity so inverted vs normal
        // tiles get independent noise/glare streams.
        let seedKey = "tile|\(character)|\(style.rawValue)|\(augmentation.polarityInverted ? "inv" : "norm")"
        let (buffer, _) = try render(text: String(character), style: style,
                                     augmentation: augmentation, seedKey: seedKey, size: size)
        return buffer
    }

    /// Deterministic dataset: for each (text x style x preset) one sample, in
    /// texts-major, styles-next, presets-inner order.
    func dataset(texts: [String],
                 styles: [DisplayGlyphStyle],
                 presets: [(name: String, augmentation: DisplayAugmentation)]) throws -> [SyntheticDisplaySample] {
        var out: [SyntheticDisplaySample] = []
        out.reserveCapacity(texts.count * styles.count * presets.count)
        for text in texts {
            for style in styles {
                for preset in presets {
                    out.append(try lineSample(text: text, style: style,
                                              augmentation: preset.augmentation,
                                              augmentationName: preset.name))
                }
            }
        }
        return out
    }

    // MARK: - Core render

    private func render(text: String,
                        style: DisplayGlyphStyle,
                        augmentation aug: DisplayAugmentation,
                        seedKey: String,
                        size: CGSize) throws -> (CVPixelBuffer, NormalizedROI) {
        let palette = Palette(inverted: aug.polarityInverted)

        // 1. Base render (glyphs + ghosting) into an upright RGBA CGImage.
        let (baseImage, roi) = try renderBase(text: text, style: style,
                                              augmentation: aug, palette: palette, size: size)

        // 2. Optical effects (bloom -> perspective -> glare -> blur) via CoreImage.
        let needsCI = aug.glow > 0 || aug.perspectiveTilt > 0 || aug.glare > 0 || aug.blur > 0
        let finalImage: CGImage
        if needsCI {
            var glareRNG = LCG(seed: seed64(seedKey + "|glare"))
            finalImage = applyOpticalEffects(to: baseImage, augmentation: aug,
                                             palette: palette, glareRNG: &glareRNG) ?? baseImage
        } else {
            finalImage = baseImage
        }

        // 3. Draw into the destination 32BGRA buffer, then apply the per-pixel
        //    noise + contrast pass in place (byte-deterministic).
        let buffer = try makeBuffer(size: size)
        try drawImage(finalImage, into: buffer, size: size)
        if aug.noise > 0 || aug.contrast != 1 {
            var noiseRNG = LCG(seed: seed64(seedKey + "|noise"))
            applyNoiseAndContrast(buffer, noise: aug.noise, contrast: aug.contrast, rng: &noiseRNG)
        }
        return (buffer, roi)
    }

    // MARK: Base glyph rendering

    private func renderBase(text: String,
                            style: DisplayGlyphStyle,
                            augmentation aug: DisplayAugmentation,
                            palette: Palette,
                            size: CGSize) throws -> (CGImage, NormalizedROI) {
        let width = Int(size.width)
        let height = Int(size.height)
        guard width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SyntheticDisplayError.contextCreationFailed
        }

        // Flip to top-left / y-down so drawing agrees with NormalizedROI.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)

        ctx.setFillColor(palette.background)
        ctx.fill(CGRect(origin: .zero, size: size))

        let roi: NormalizedROI
        switch style {
        case .dotMatrix:
            roi = drawDotMatrix(text: text, in: ctx, size: size, palette: palette)
        case .sans, .sevenSegment, .fourteenSegment:
            roi = drawFontText(text: text, style: style, in: ctx,
                               size: size, augmentation: aug, palette: palette)
        }

        guard let image = ctx.makeImage() else { throw SyntheticDisplayError.renderFailed }
        return (image, roi)
    }

    /// Draws proportional/segment text with a resolved UIFont, returning the
    /// normalized bounding box of the drawn line.
    private func drawFontText(text: String,
                              style: DisplayGlyphStyle,
                              in ctx: CGContext,
                              size: CGSize,
                              augmentation aug: DisplayAugmentation,
                              palette: Palette) -> NormalizedROI {
        let maker: (CGFloat) -> UIFont
        switch style {
        case .sevenSegment: maker = sevenFontMaker
        case .fourteenSegment: maker = fourteenFontMaker
        default: maker = { UIFont.monospacedSystemFont(ofSize: $0, weight: .semibold) }
        }

        let (font, textSize) = fittedFont(maker: maker, text: text, size: size)
        let originX = (size.width - textSize.width) / 2
        let originY = (size.height - textSize.height) / 2

        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }

        // Ghosting underlay (segment styles only): a faint "all segments on"
        // residue behind the real glyphs, using '8' per character position.
        if aug.ghosting > 0, style == .sevenSegment || style == .fourteenSegment {
            let ghost = String(repeating: "8", count: max(1, text.count))
            let ghostAttr = attributed(ghost, font: font,
                                       color: palette.litColor(alpha: min(1, aug.ghosting * 0.5)))
            let ghostSize = ghostAttr.size()
            ghostAttr.draw(in: CGRect(x: (size.width - ghostSize.width) / 2,
                                      y: (size.height - ghostSize.height) / 2,
                                      width: ghostSize.width, height: ghostSize.height))
        }

        let attr = attributed(text, font: font, color: palette.litColor(alpha: 1))
        attr.draw(in: CGRect(x: originX, y: originY, width: textSize.width, height: textSize.height))

        return normalizedROI(x: originX, y: originY,
                             width: textSize.width, height: textSize.height, in: size)
    }

    /// Draws a 5x7 dot-matrix line of lit dots, returning the grid's normalized
    /// bounding box. Only lit dots are drawn (unlit cells stay background) so the
    /// glyphs are cleanly separable for the distinctness test.
    private func drawDotMatrix(text: String,
                               in ctx: CGContext,
                               size: CGSize,
                               palette: Palette) -> NormalizedROI {
        let chars = Array(text)
        let rows = 7
        let colsPerChar = 5
        let gap = 1
        let totalCols = chars.count * colsPerChar + max(0, chars.count - 1) * gap
        guard totalCols > 0 else {
            return NormalizedROI(x: 0.5, y: 0.5, width: 0, height: 0)
        }

        let marginX = size.width * 0.06
        let marginY = size.height * 0.14
        let availW = size.width - 2 * marginX
        let availH = size.height - 2 * marginY
        let pitch = min(availW / CGFloat(totalCols), availH / CGFloat(rows))
        let gridW = pitch * CGFloat(totalCols)
        let gridH = pitch * CGFloat(rows)
        let originX = (size.width - gridW) / 2
        let originY = (size.height - gridH) / 2
        let dotR = pitch * 0.42

        ctx.setFillColor(palette.litColor(alpha: 1))
        for (index, ch) in chars.enumerated() {
            let pattern = Self.dotMatrixGlyph(ch)
            let colOffset = index * (colsPerChar + gap)
            for r in 0..<rows {
                let bits = pattern[r]
                for c in 0..<colsPerChar where (bits >> (colsPerChar - 1 - c)) & 1 == 1 {
                    let cx = originX + (CGFloat(colOffset + c) + 0.5) * pitch
                    let cy = originY + (CGFloat(r) + 0.5) * pitch
                    ctx.fillEllipse(in: CGRect(x: cx - dotR, y: cy - dotR,
                                               width: 2 * dotR, height: 2 * dotR))
                }
            }
        }

        return normalizedROI(x: originX, y: originY, width: gridW, height: gridH, in: size)
    }

    // MARK: Optical effects (CoreImage)

    private func applyOpticalEffects(to base: CGImage,
                                     augmentation aug: DisplayAugmentation,
                                     palette: Palette,
                                     glareRNG: inout LCG) -> CGImage? {
        let ci = CIImage(cgImage: base)
        let extent = ci.extent
        var img = ci

        if aug.glow > 0 {
            let bloom = CIFilter.bloom()
            bloom.inputImage = img
            bloom.radius = Float(aug.glow * 12)
            bloom.intensity = Float(aug.glow * 1.4)
            if let out = bloom.outputImage { img = out.cropped(to: extent) }
        }

        if aug.perspectiveTilt > 0 {
            let dx = extent.width * 0.18 * aug.perspectiveTilt
            let dy = extent.height * 0.06 * aug.perspectiveTilt
            let p = CIFilter.perspectiveTransform()
            p.inputImage = img
            // CI space is bottom-left origin; "top" is maxY. Narrow the top edge
            // for a keystone tilt. Exact direction is unimportant (augmentation).
            p.topLeft = CGPoint(x: extent.minX + dx, y: extent.maxY - dy)
            p.topRight = CGPoint(x: extent.maxX - dx, y: extent.maxY - dy)
            p.bottomLeft = CGPoint(x: extent.minX, y: extent.minY)
            p.bottomRight = CGPoint(x: extent.maxX, y: extent.minY)
            if let out = p.outputImage {
                let bg = CIImage(color: palette.ciBackground).cropped(to: extent)
                img = out.composited(over: bg).cropped(to: extent)
            }
        }

        if aug.glare > 0 {
            let cx = extent.minX + extent.width * CGFloat(0.30 + 0.40 * glareRNG.nextUnitDouble())
            let cy = extent.minY + extent.height * CGFloat(0.35 + 0.45 * glareRNG.nextUnitDouble())
            let grad = CIFilter.radialGradient()
            grad.center = CGPoint(x: cx, y: cy)
            grad.radius0 = Float(extent.width * 0.04)
            grad.radius1 = Float(extent.width * (0.22 + 0.25 * aug.glare))
            grad.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(min(1, aug.glare)))
            grad.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
            if let blob = grad.outputImage?.cropped(to: extent) {
                img = blob.composited(over: img).cropped(to: extent)
            }
        }

        if aug.blur > 0 {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = img.clampedToExtent()
            blur.radius = Float(aug.blur * min(extent.width, extent.height) * 0.04)
            if let out = blur.outputImage { img = out.cropped(to: extent) }
        }

        return ciContext.createCGImage(img, from: extent)
    }

    // MARK: Destination buffer

    private func makeBuffer(size: CGSize) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width), Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw SyntheticDisplayError.bufferAllocationFailed
        }
        return buffer
    }

    private func drawImage(_ image: CGImage, into buffer: CVPixelBuffer, size: CGSize) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw SyntheticDisplayError.renderFailed
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let ctx = CGContext(data: base, width: Int(size.width), height: Int(size.height),
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw SyntheticDisplayError.contextCreationFailed
        }
        // `image` is upright (top-left, memory row 0 = top). CGContext.draw of
        // an upright CGImage into a bitmap context is orientation-preserving —
        // adding a flip here double-flips (the base render context already
        // flipped) and inverts every buffer, which the seven-segment sampler
        // caught: '2' decoded as '5' (verified by raw-row ASCII dump).
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
    }

    /// In-place per-pixel sensor noise then contrast, on a locked 32BGRA buffer
    /// (memory bytes are B, G, R, A). Deterministic given `rng`.
    private func applyNoiseAndContrast(_ buffer: CVPixelBuffer,
                                       noise: CGFloat,
                                       contrast: CGFloat,
                                       rng: inout LCG) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let amplitude = Double(noise) * 70.0
        let c = Double(contrast)
        let applyNoise = noise > 0
        let applyContrast = contrast != 1

        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4
                for ch in 0..<3 {
                    var v = Double(p[ch])
                    if applyNoise {
                        v += (rng.nextUnitDouble() * 2 - 1) * amplitude
                    }
                    if applyContrast {
                        v = (v / 255.0 - 0.5) * c * 255.0 + 127.5
                    }
                    p[ch] = UInt8(max(0, min(255, v.rounded())))
                }
                p[3] = 255
            }
        }
    }

    // MARK: Text helpers

    private func attributed(_ text: String, font: UIFont, color: CGColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: UIColor(cgColor: color),
            .paragraphStyle: paragraph
        ])
    }

    /// Chooses a font size that fits `text` within ~60% of the height and 92%
    /// of the width. For monospaced/segment fonts width scales linearly, so one
    /// correction pass suffices.
    private func fittedFont(maker: (CGFloat) -> UIFont, text: String, size: CGSize) -> (UIFont, CGSize) {
        var fontSize = size.height * 0.60
        var font = maker(fontSize)
        var measured = attributed(text, font: font, color: UIColor.black.cgColor).size()
        let maxWidth = size.width * 0.92
        if measured.width > maxWidth, measured.width > 0 {
            fontSize *= maxWidth / measured.width
            font = maker(fontSize)
            measured = attributed(text, font: font, color: UIColor.black.cgColor).size()
        }
        return (font, measured)
    }

    private func normalizedROI(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat,
                               in size: CGSize) -> NormalizedROI {
        let nx = min(max(x / size.width, 0), 1)
        let ny = min(max(y / size.height, 0), 1)
        let nw = min(max(width / size.width, 0), 1 - nx)
        let nh = min(max(height / size.height, 0), 1 - ny)
        return NormalizedROI(x: nx, y: ny, width: nw, height: nh)
    }

    // MARK: - Font preparation (static, idempotent)

    private static let fontLock = NSLock()
    private static var didRegister = false
    private static var cachedSeven: CGFont?
    private static var cachedFourteen: CGFont?

    private static func prepareFonts(bundle: Bundle) throws -> (CGFont, CGFont) {
        fontLock.lock()
        defer { fontLock.unlock() }
        if let seven = cachedSeven, let fourteen = cachedFourteen {
            return (seven, fourteen)
        }
        let sevenURL = try locateFont(named: "DSEG7Classic-Regular", in: bundle)
        let fourteenURL = try locateFont(named: "DSEG14Classic-Regular", in: bundle)
        if !didRegister {
            try register(sevenURL)
            try register(fourteenURL)
            didRegister = true
        }
        let seven = try loadCGFont(sevenURL)
        let fourteen = try loadCGFont(fourteenURL)
        cachedSeven = seven
        cachedFourteen = fourteen
        return (seven, fourteen)
    }

    private static func locateFont(named name: String, in bundle: Bundle) throws -> URL {
        if let url = bundle.url(forResource: name, withExtension: "ttf") { return url }
        if let url = bundle.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts") { return url }
        throw SyntheticDisplayError.fontResourceMissing(name)
    }

    private static func register(_ url: URL) throws {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { return }
        if let cfError = error?.takeRetainedValue() {
            // Already-registered is success for an idempotent init.
            if CFErrorGetCode(cfError) == CTFontManagerError.alreadyRegistered.rawValue { return }
            throw SyntheticDisplayError.fontRegistrationFailed(String(describing: cfError))
        }
        throw SyntheticDisplayError.fontRegistrationFailed(url.lastPathComponent)
    }

    private static func loadCGFont(_ url: URL) throws -> CGFont {
        guard let data = try? Data(contentsOf: url),
              let provider = CGDataProvider(data: data as CFData),
              let font = CGFont(provider) else {
            throw SyntheticDisplayError.fontResourceMissing(url.lastPathComponent)
        }
        return font
    }

    /// Prefers the registered PostScript name; falls back to bridging the CGFont
    /// directly (name-independent), so a resolver always yields a usable font.
    private static func makeFontMaker(cgFont: CGFont) -> (CGFloat) -> UIFont {
        let postScriptName = cgFont.postScriptName as String?
        return { size in
            if let postScriptName, let font = UIFont(name: postScriptName, size: size) {
                return font
            }
            let ctFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            return unsafeBitCast(ctFont, to: UIFont.self)
        }
    }

    // MARK: - Dot-matrix glyphs (5 cols x 7 rows, MSB = leftmost column)

    /// Returns 7 rows of 5-bit masks for a supported character; unknown/space
    /// characters render blank (all rows zero).
    static func dotMatrixGlyph(_ ch: Character) -> [UInt8] {
        Self.dotMatrixFont[ch] ?? [0, 0, 0, 0, 0, 0, 0]
    }

    private static let dotMatrixFont: [Character: [UInt8]] = [
        "0": [0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110],
        "1": [0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110],
        "2": [0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111],
        "3": [0b11111, 0b00010, 0b00100, 0b00010, 0b00001, 0b10001, 0b01110],
        "4": [0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010],
        "5": [0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110],
        "6": [0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110],
        "7": [0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000],
        "8": [0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110],
        "9": [0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100],
        "-": [0b00000, 0b00000, 0b00000, 0b11111, 0b00000, 0b00000, 0b00000],
        // '.' as a 2x2 block bottom-aligned (contract's 1x2 sub-grid suggestion,
        // widened one column so it survives circle rendering).
        ".": [0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100],
        " ": [0, 0, 0, 0, 0, 0, 0]
    ]

    // MARK: - Palette

    /// Base colors for the chosen polarity. `litColor` is the glyph color;
    /// `background` is the display field.
    private struct Palette {
        let inverted: Bool
        let background: CGColor
        let ciBackground: CIColor
        private let lit: (r: CGFloat, g: CGFloat, b: CGFloat)

        init(inverted: Bool) {
            self.inverted = inverted
            if inverted {
                // Emissive (VFD/OLED): bright glyphs on near-black.
                self.background = CGColor(red: 0x08 / 255, green: 0x0A / 255, blue: 0x0C / 255, alpha: 1)
                self.ciBackground = CIColor(red: 0x08 / 255, green: 0x0A / 255, blue: 0x0C / 255)
                self.lit = (0xCF / 255, 0xFF / 255, 0xE0 / 255)
            } else {
                // LCD: dark glyphs on a light gray-green field.
                self.background = CGColor(red: 0xC9 / 255, green: 0xD6 / 255, blue: 0xC2 / 255, alpha: 1)
                self.ciBackground = CIColor(red: 0xC9 / 255, green: 0xD6 / 255, blue: 0xC2 / 255)
                self.lit = (0x14 / 255, 0x1A / 255, 0x12 / 255)
            }
        }

        func litColor(alpha: CGFloat) -> CGColor {
            CGColor(red: lit.r, green: lit.g, blue: lit.b, alpha: alpha)
        }
    }

    // MARK: - Deterministic RNG

    /// A small splitmix/PCG-style generator: fully deterministic from its seed,
    /// no global state. Used only for augmentation jitter (noise, glare).
    private struct LCG {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            var x = state
            x ^= x >> 33
            x = x &* 0xFF51AFD7ED558CCD
            x ^= x >> 33
            return x
        }
        /// Uniform in [0, 1).
        mutating func nextUnitDouble() -> Double {
            Double(next() >> 11) * (1.0 / 9007199254740992.0) // 2^-53
        }
    }
}

/// FNV-1a 64-bit hash of a key string — a stable, portable seed for `LCG`.
private func seed64(_ string: String) -> UInt64 {
    var hash: UInt64 = 0xCBF29CE484222325
    for byte in string.utf8 {
        hash = (hash ^ UInt64(byte)) &* 0x100000001B3
    }
    return hash
}
