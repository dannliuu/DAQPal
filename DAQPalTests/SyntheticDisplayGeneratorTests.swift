//
//  SyntheticDisplayGeneratorTests.swift
//  DAQPalTests
//
//  Verifies the OCR_RESEARCH.md Phase 1 synthetic generator: that its bundled
//  DSEG fonts register, that geometry (buffer sizes, textROI) is sane, that
//  every style x preset renders without throwing, that dot-matrix glyphs are
//  visually distinct, and — the load-bearing property for reproducible datasets
//  — that the same recipe renders byte-identical pixels.
//
//  These tests assert only structural/geometric facts about SYNTHETIC output.
//  They make no claim about recognition accuracy on real instruments.
//

import CoreVideo
import XCTest
@testable import DAQPal

final class SyntheticDisplayGeneratorTests: XCTestCase {

    // MARK: Helpers

    /// Snapshots a locked 32BGRA buffer's active pixel region as `Data`
    /// (row-by-row, ignoring any trailing row padding so the comparison is over
    /// real pixels only).
    private func pixelData(_ buffer: CVPixelBuffer) -> Data {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return Data() }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var data = Data(capacity: width * height * 4)
        for y in 0..<height {
            data.append(contentsOf: UnsafeBufferPointer(start: ptr + y * bytesPerRow, count: width * 4))
        }
        return data
    }

    /// Counts "ink" pixels — for a clean, non-inverted (dark-on-light) render
    /// the glyphs are the dark pixels, so luminance below mid-scale is ink.
    private func darkPixelCount(_ buffer: CVPixelBuffer, threshold: Double = 128) -> Int {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var count = 0
        for y in 0..<height {
            let row = ptr + y * bytesPerRow
            for x in 0..<width {
                let p = row + x * 4 // B, G, R, A
                let lum = 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                if lum < threshold { count += 1 }
            }
        }
        return count
    }

    // MARK: Fonts

    func testInitRegistersFontsWithoutThrowing() throws {
        // init throws only if the bundled DSEG resources are missing; success
        // proves registration + resolver setup for both segment fonts.
        XCTAssertNoThrow(try SyntheticDisplayGenerator())
    }

    func testInitIsIdempotent() throws {
        // A second generator must not fail on "font already registered".
        _ = try SyntheticDisplayGenerator()
        XCTAssertNoThrow(try SyntheticDisplayGenerator())
    }

    // MARK: Sizes

    func testLineSampleHasRequestedSize() throws {
        let generator = try SyntheticDisplayGenerator()
        let sample = try generator.lineSample(text: "12.347", style: .sevenSegment,
                                              augmentation: .clean, augmentationName: "clean")
        XCTAssertEqual(CVPixelBufferGetWidth(sample.pixelBuffer), 640)
        XCTAssertEqual(CVPixelBufferGetHeight(sample.pixelBuffer), 280)
        XCTAssertEqual(sample.text, "12.347")
        XCTAssertEqual(sample.style, .sevenSegment)
        XCTAssertEqual(sample.augmentationName, "clean")
    }

    func testDigitTileHasDefaultTileSize() throws {
        let generator = try SyntheticDisplayGenerator()
        let tile = try generator.digitTile(character: "7", style: .sevenSegment, augmentation: .clean)
        XCTAssertEqual(CVPixelBufferGetWidth(tile), 32)
        XCTAssertEqual(CVPixelBufferGetHeight(tile), 48)
    }

    func testCustomSizeIsHonored() throws {
        let generator = try SyntheticDisplayGenerator()
        let sample = try generator.lineSample(text: "88888", style: .sans,
                                              augmentation: .clean, augmentationName: "clean",
                                              size: CGSize(width: 400, height: 160))
        XCTAssertEqual(CVPixelBufferGetWidth(sample.pixelBuffer), 400)
        XCTAssertEqual(CVPixelBufferGetHeight(sample.pixelBuffer), 160)
    }

    // MARK: textROI

    func testTextROIIsSaneAndRoughlyCentered() throws {
        let generator = try SyntheticDisplayGenerator()
        for style in DisplayGlyphStyle.allCases {
            let sample = try generator.lineSample(text: "12.347", style: style,
                                                  augmentation: .clean, augmentationName: "clean")
            let roi = sample.textROI
            XCTAssertGreaterThanOrEqual(roi.x, 0, "\(style) roi.x")
            XCTAssertGreaterThanOrEqual(roi.y, 0, "\(style) roi.y")
            XCTAssertGreaterThan(roi.width, 0, "\(style) roi.width")
            XCTAssertGreaterThan(roi.height, 0, "\(style) roi.height")
            XCTAssertLessThanOrEqual(roi.x + roi.width, 1.0001, "\(style) roi right edge")
            XCTAssertLessThanOrEqual(roi.y + roi.height, 1.0001, "\(style) roi bottom edge")
            // Centered layout: the ROI midpoint should sit near the buffer center.
            XCTAssertEqual(roi.x + roi.width / 2, 0.5, accuracy: 0.2, "\(style) roi horizontally centered")
            XCTAssertEqual(roi.y + roi.height / 2, 0.5, accuracy: 0.25, "\(style) roi vertically centered")
        }
    }

    // MARK: Determinism

    func testCleanRenderIsByteIdentical() throws {
        let generator = try SyntheticDisplayGenerator()
        let a = try generator.lineSample(text: "12.347", style: .sevenSegment,
                                        augmentation: .clean, augmentationName: "clean")
        let b = try generator.lineSample(text: "12.347", style: .sevenSegment,
                                        augmentation: .clean, augmentationName: "clean")
        XCTAssertEqual(pixelData(a.pixelBuffer), pixelData(b.pixelBuffer),
                       "identical clean recipes must render byte-identical pixels")
    }

    func testAugmentedRenderIsByteIdentical() throws {
        // The full optical + noise pipeline must also be reproducible: this is
        // what lets datasets be regenerated exactly.
        let generator = try SyntheticDisplayGenerator()
        let a = try generator.lineSample(text: "-0.05", style: .fourteenSegment,
                                        augmentation: .hard, augmentationName: "hard")
        let b = try generator.lineSample(text: "-0.05", style: .fourteenSegment,
                                        augmentation: .hard, augmentationName: "hard")
        XCTAssertEqual(pixelData(a.pixelBuffer), pixelData(b.pixelBuffer),
                       "identical augmented recipes must render byte-identical pixels")
    }

    func testDifferentAugmentationNamesDiffer() throws {
        // The augmentationName is part of the seed, so noise-bearing recipes
        // with different names must not collide.
        let generator = try SyntheticDisplayGenerator()
        let a = try generator.lineSample(text: "199.9", style: .sans,
                                        augmentation: .moderate, augmentationName: "moderate-a")
        let b = try generator.lineSample(text: "199.9", style: .sans,
                                        augmentation: .moderate, augmentationName: "moderate-b")
        XCTAssertNotEqual(pixelData(a.pixelBuffer), pixelData(b.pixelBuffer),
                          "different augmentation names should seed different noise")
    }

    // MARK: Dot-matrix distinctness

    func testDotMatrixGlyphsAreVisuallyDistinct() throws {
        let generator = try SyntheticDisplayGenerator()
        let eight = try generator.digitTile(character: "8", style: .dotMatrix, augmentation: .clean)
        let one = try generator.digitTile(character: "1", style: .dotMatrix, augmentation: .clean)
        let blank = try generator.digitTile(character: " ", style: .dotMatrix, augmentation: .clean)

        let eightInk = darkPixelCount(eight)
        let oneInk = darkPixelCount(one)
        let blankInk = darkPixelCount(blank)

        XCTAssertGreaterThan(eightInk, 0, "'8' should render lit dots")
        XCTAssertGreaterThan(oneInk, 0, "'1' should render lit dots")
        XCTAssertEqual(blankInk, 0, "a blank cell should have no lit dots")
        // '8' lights 17 dots vs '1's 10 (~1.7x); require a clear margin without
        // over-claiming the exact ratio.
        XCTAssertGreaterThan(Double(eightInk), Double(oneInk) * 1.25,
                             "'8' should light substantially more dots than '1'")

        // Byte-diff between the two tiles should be large, not a near-copy. The
        // two glyphs share only ~5 dot positions, so most lit dots differ.
        let diff = zip(pixelData(eight), pixelData(one)).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        XCTAssertGreaterThan(diff, 50, "'8' and '1' dot-matrix tiles should differ substantially")
    }

    func testDotMatrixGlyphTableCoversDigitsAndSeparators() {
        for ch in "0123456789" {
            let rows = SyntheticDisplayGenerator.dotMatrixGlyph(ch)
            XCTAssertEqual(rows.count, 7, "'\(ch)' must have 7 rows")
            XCTAssertTrue(rows.contains { $0 != 0 }, "'\(ch)' must have lit dots")
        }
        XCTAssertTrue(SyntheticDisplayGenerator.dotMatrixGlyph("-").contains { $0 != 0 })
        XCTAssertTrue(SyntheticDisplayGenerator.dotMatrixGlyph(".").contains { $0 != 0 })
        XCTAssertFalse(SyntheticDisplayGenerator.dotMatrixGlyph(" ").contains { $0 != 0 })
    }

    // MARK: Smoke — every style x preset

    func testSmokeAllStylesAndPresetsRender() throws {
        let generator = try SyntheticDisplayGenerator()
        for style in DisplayGlyphStyle.allCases {
            for preset in DisplayAugmentation.presets {
                let sample = try generator.lineSample(text: "12.347", style: style,
                                                      augmentation: preset.augmentation,
                                                      augmentationName: preset.name)
                XCTAssertEqual(CVPixelBufferGetWidth(sample.pixelBuffer), 640,
                               "\(style)/\(preset.name) width")
                XCTAssertEqual(CVPixelBufferGetHeight(sample.pixelBuffer), 280,
                               "\(style)/\(preset.name) height")
            }
        }
    }

    func testDatasetFansOutOverTextStylePreset() throws {
        let generator = try SyntheticDisplayGenerator()
        let texts = ["12.347", "-0.05"]
        let styles = DisplayGlyphStyle.allCases
        let presets = DisplayAugmentation.presets
        let dataset = try generator.dataset(texts: texts, styles: styles, presets: presets)
        XCTAssertEqual(dataset.count, texts.count * styles.count * presets.count)
        // Labels must be preserved for every sample.
        XCTAssertTrue(dataset.allSatisfy { texts.contains($0.text) })
        XCTAssertTrue(dataset.allSatisfy { presets.map(\.name).contains($0.augmentationName) })
    }

    func testDatasetIsDeterministic() throws {
        let generator = try SyntheticDisplayGenerator()
        let first = try generator.dataset(texts: ["1.5"], styles: [.sevenSegment],
                                          presets: [("moderate", .moderate)])
        let second = try generator.dataset(texts: ["1.5"], styles: [.sevenSegment],
                                           presets: [("moderate", .moderate)])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(pixelData(first[0].pixelBuffer), pixelData(second[0].pixelBuffer))
    }

    // MARK: Tiles

    func testDigitTileAcceptsAllSupportedCharacters() throws {
        let generator = try SyntheticDisplayGenerator()
        for ch in "0123456789.- " {
            for style in DisplayGlyphStyle.allCases {
                XCTAssertNoThrow(try generator.digitTile(character: ch, style: style, augmentation: .clean),
                                 "tile '\(ch)' / \(style)")
            }
        }
    }

    func testDigitTileRejectsUnsupportedCharacter() throws {
        let generator = try SyntheticDisplayGenerator()
        XCTAssertThrowsError(try generator.digitTile(character: "A", style: .sevenSegment, augmentation: .clean)) { error in
            guard case SyntheticDisplayError.unsupportedTileCharacter(let c) = error else {
                return XCTFail("expected unsupportedTileCharacter, got \(error)")
            }
            XCTAssertEqual(c, "A")
        }
    }

    // MARK: Polarity

    func testInvertedTileIsLightOnDarkVersusCleanDarkOnLight() throws {
        // Sampler agent relies on polarity being distinguishable from border/
        // center statistics; verify a clean tile is dark-on-light while its
        // inverted variant is light-on-dark by comparing corner (background)
        // luminance.
        let generator = try SyntheticDisplayGenerator()
        var inverted = DisplayAugmentation.clean
        inverted.polarityInverted = true

        let normal = try generator.digitTile(character: "8", style: .sevenSegment, augmentation: .clean)
        let flipped = try generator.digitTile(character: "8", style: .sevenSegment, augmentation: inverted)

        XCTAssertGreaterThan(cornerLuminance(normal), 150, "clean LCD tile background should be light")
        XCTAssertLessThan(cornerLuminance(flipped), 80, "inverted tile background should be dark")
    }

    /// Mean luminance of the top-left 4x4 corner (assumed background).
    private func cornerLuminance(_ buffer: CVPixelBuffer, span: Int = 4) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        var n = 0
        for y in 0..<span {
            let row = ptr + y * bytesPerRow
            for x in 0..<span {
                let p = row + x * 4
                sum += 0.114 * Double(p[0]) + 0.587 * Double(p[1]) + 0.299 * Double(p[2])
                n += 1
            }
        }
        return n == 0 ? 0 : sum / Double(n)
    }
}
