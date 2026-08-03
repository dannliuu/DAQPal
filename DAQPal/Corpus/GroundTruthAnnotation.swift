//
//  GroundTruthAnnotation.swift
//  DAQPal
//
//  The machine-readable label format for a corpus item: per frame, where the
//  display is, where each glyph is, where the decimal point is, and what the
//  instrument actually read. DEVELOPMENT ONLY.
//
//  EVERY COORDINATE IS NORMALIZED, TOP-LEFT ORIGIN — the same space as
//  `NormalizedROI` and `ScreenQuad`, which is what the crop path, the Vision
//  region-of-interest and the overlay all speak. Pixel coordinates would bind an
//  annotation to the resolution it was drawn at, and the first time a corpus
//  item is re-encoded, downscaled for speed, or replaced by a higher-resolution
//  capture of the same scene, every label silently becomes wrong while still
//  parsing. Normalized labels survive all three: the conversions live in
//  `pixelQuad(in:)` / `init(pixelBox:in:)` and nowhere else.
//
//  `ScreenQuad` IS THE QUAD TYPE. It already carries semantic corners
//  (`topLeft` is the display's physical top-left under any pose), is Codable and
//  normalized, and its `corners` are in TL→TR→BR→BL winding — which is the order
//  `GeometryError.between(predicted:truth:)` compares pairwise. A second quad
//  type here would be a second convention to keep in sync.
//
//  WHERE SCORING LIVES. The agreement helper is an extension in the test target
//  (`CorpusTests.swift`), because `ReadingVerdict`, `ReadingComparison` and
//  `GeometryError` are `ValidationHarness` types and the app target must not
//  depend on the test target. This file supplies the shapes those functions
//  consume — `truthCorners`, `predictedCorners`, `value`, `prediction.value` —
//  so the bridge is a few lines rather than a parallel metrics vocabulary.
//

import CoreGraphics
import Foundation

// MARK: - Points

/// A point in normalized, top-left-origin image space.
struct NormalizedPoint: Codable, Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    init(_ point: CGPoint) { self.init(x: point.x, y: point.y) }

    /// From a pixel coordinate in an image of `size`. The single place a raw
    /// annotation tool's output enters this format.
    init(pixelPoint: CGPoint, in size: CGSize) {
        self.init(x: size.width > 0 ? pixelPoint.x / size.width : 0,
                  y: size.height > 0 ? pixelPoint.y / size.height : 0)
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }

    func pixelPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }

    var isWithinUnitSquare: Bool { (0...1).contains(x) && (0...1).contains(y) }
}

// MARK: - Glyphs

/// One glyph of the reading and the box it occupies.
///
/// `character` is a `String` rather than a `Character` only because `Character`
/// has no useful Codable representation; it is validated to a single character.
/// Non-digits are legal and expected: the leading `-` of a negative reading and
/// a `1` rendered as a bare vertical bar are both glyphs a labeller must be able
/// to box.
struct DigitAnnotation: Codable, Equatable, Sendable {
    var character: String
    var box: NormalizedROI

    init(character: String, box: NormalizedROI) {
        self.character = character
        self.box = box
    }

    init(character: String, pixelBox: CGRect, in size: CGSize) {
        self.init(character: character, box: NormalizedROI(rect: Self.normalize(pixelBox, in: size)))
    }

    func pixelBox(in size: CGSize) -> CGRect { box.pixelRect(in: size) }

    private static func normalize(_ rect: CGRect, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGRect(x: rect.origin.x / size.width,
                      y: rect.origin.y / size.height,
                      width: rect.width / size.width,
                      height: rect.height / size.height)
    }

    var isWellFormed: Bool { character.count == 1 }
}

// MARK: - Prediction under comparison

/// What an OCR run produced for the same frame, stored alongside the truth so a
/// disagreement is inspectable long after the run that produced it.
struct AnnotationPrediction: Codable, Equatable, Sendable {
    /// Nil when the engine produced nothing — distinct from an empty string,
    /// and `ReadingComparison` treats both as `.notDetected`.
    var value: String?
    /// Nil when the run measured reading only and not geometry.
    var quad: ScreenQuad?
    var confidence: Float?
    /// Which engine produced it, e.g. "VisionOCR", "DualPassVisionOCR". Recorded
    /// because the two differ by nearly 3x on seven-segment glyphs, so an
    /// unlabelled prediction is not comparable to anything.
    var engine: String?

    init(value: String?,
         quad: ScreenQuad? = nil,
         confidence: Float? = nil,
         engine: String? = nil) {
        self.value = value
        self.quad = quad
        self.confidence = confidence
        self.engine = engine
    }
}

// MARK: - Frame annotation

/// Ways an annotation contradicts itself. Checked rather than assumed, because
/// hand-labelled ground truth that is wrong is worse than no ground truth: it
/// scores a correct pipeline as broken.
enum AnnotationIssue: String, Equatable, Sendable {
    case glyphNotSingleCharacter
    case glyphBoxOutsideUnitSquare
    case decimalPointOutsideUnitSquare
    case displayQuadNotConvex
    /// The glyph boxes, read left to right with the decimal point inserted at
    /// its horizontal position, do not spell `value`.
    case glyphsDoNotSpellValue
    case emptyValue
}

struct FrameAnnotation: Codable, Equatable, Sendable {

    /// Index within the SAMPLED sequence the annotation was made over, so an
    /// annotation is replayable from `CorpusFrameSampler.Configuration` alone.
    var frameIndex: Int
    /// Source presentation time, seconds.
    var timestamp: TimeInterval
    var displayQuad: ScreenQuad
    var digits: [DigitAnnotation]
    /// Centre of the decimal point glyph. Nil when the reading has none —
    /// which is itself ground truth, and the case `.decimalSpurious` scores
    /// against.
    var decimalPoint: NormalizedPoint?
    /// The reading as written on the display, separator included: "90.0", not
    /// 90.0. Compared as a string for the reasons `ReadingComparison` documents.
    var value: String
    var prediction: AnnotationPrediction?

    init(frameIndex: Int,
         timestamp: TimeInterval,
         displayQuad: ScreenQuad,
         digits: [DigitAnnotation],
         decimalPoint: NormalizedPoint? = nil,
         value: String,
         prediction: AnnotationPrediction? = nil) {
        self.frameIndex = frameIndex
        self.timestamp = timestamp
        self.displayQuad = displayQuad
        self.digits = digits
        self.decimalPoint = decimalPoint
        self.value = value
        self.prediction = prediction
    }

    // MARK: Geometry accessors

    /// Truth corners in TL→TR→BR→BL order — the argument
    /// `GeometryError.between(predicted:truth:)` expects.
    var truthCorners: [CGPoint] { displayQuad.corners }

    var predictedCorners: [CGPoint]? { prediction?.quad?.corners }

    /// The quad in pixels for an image of `size`. The only supported way to get
    /// back to pixel space; annotations themselves never store one.
    func pixelQuad(in size: CGSize) -> [CGPoint] {
        displayQuad.corners.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }

    // MARK: Self-consistency

    /// `value` as implied by the glyph boxes: glyphs sorted left to right, with
    /// the separator inserted where the decimal point falls horizontally.
    /// Compared against `value` by `issues` so a mislabelled box is caught at
    /// annotation time rather than showing up as a pipeline regression.
    var reconstructedValue: String {
        let ordered = digits.sorted { $0.box.cgRect.midX < $1.box.cgRect.midX }
        guard let decimalPoint else { return ordered.map(\.character).joined() }
        var text = ""
        var inserted = false
        for glyph in ordered {
            if !inserted, glyph.box.cgRect.midX > decimalPoint.x {
                text += "."
                inserted = true
            }
            text += glyph.character
        }
        if !inserted { text += "." }
        return text
    }

    var issues: [AnnotationIssue] {
        var found: [AnnotationIssue] = []
        if value.isEmpty { found.append(.emptyValue) }
        if digits.contains(where: { !$0.isWellFormed }) { found.append(.glyphNotSingleCharacter) }
        if digits.contains(where: { !Self.isWithinUnitSquare($0.box) }) {
            found.append(.glyphBoxOutsideUnitSquare)
        }
        if let decimalPoint, !decimalPoint.isWithinUnitSquare {
            found.append(.decimalPointOutsideUnitSquare)
        }
        if !displayQuad.isConvex { found.append(.displayQuadNotConvex) }
        if !digits.isEmpty, reconstructedValue != value { found.append(.glyphsDoNotSpellValue) }
        return found
    }

    var isWellFormed: Bool { issues.isEmpty }

    private static func isWithinUnitSquare(_ roi: NormalizedROI) -> Bool {
        let r = roi.cgRect
        return r.minX >= 0 && r.minY >= 0 && r.maxX <= 1 && r.maxY <= 1
    }
}

// MARK: - Annotation set

/// Every annotated frame for one manifest entry.
struct GroundTruthAnnotationSet: Codable, Equatable, Sendable {

    static let currentSchemaVersion = 1

    /// Joins to `CorpusEntry.id`.
    var manifestEntryID: String
    var schemaVersion: Int
    /// The resolution the labelling was performed at. Recorded for provenance
    /// only — nothing here reads it, which is the point: changing it must not
    /// change a single coordinate.
    var annotatedAtResolution: CorpusResolution?
    var frames: [FrameAnnotation]

    init(manifestEntryID: String,
         frames: [FrameAnnotation],
         annotatedAtResolution: CorpusResolution? = nil,
         schemaVersion: Int = GroundTruthAnnotationSet.currentSchemaVersion) {
        self.manifestEntryID = manifestEntryID
        self.schemaVersion = schemaVersion
        self.annotatedAtResolution = annotatedAtResolution
        self.frames = frames
    }

    subscript(frameIndex index: Int) -> FrameAnnotation? {
        frames.first { $0.frameIndex == index }
    }

    /// Frames whose labels contradict themselves, with their issues. A corpus
    /// item with any entry here is not fit to score against.
    var malformedFrames: [(frameIndex: Int, issues: [AnnotationIssue])] {
        frames.compactMap { frame in
            let issues = frame.issues
            return issues.isEmpty ? nil : (frame.frameIndex, issues)
        }
    }

    // MARK: JSON

    func jsonData() throws -> Data { try CorpusManifest.jsonEncoder().encode(self) }

    init(jsonData: Data) throws {
        self = try CorpusManifest.jsonDecoder().decode(GroundTruthAnnotationSet.self, from: jsonData)
    }
}
