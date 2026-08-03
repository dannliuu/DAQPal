//
//  CorpusTests.swift
//  DAQPalTests
//
//  Coverage for the development-only validation-corpus system:
//    1. Manifest JSON round-trip, and that an absent key stays `nil` instead of
//       acquiring a plausible default.
//    2. The licence rule — an `.unknown`-licence entry is rejected by
//       validation AND refused by ingestion even when its file is right there.
//    3. Annotation resolution-independence: the same scene labelled at two
//       resolutions produces byte-identical normalized annotations.
//    4. Frame sampling against a real encoded `.mov`.
//    5. The agreement bridge from an annotation to `ValidationHarness`.
//
//  The sampling fixture is `SyntheticDisplayRenderer` output encoded with
//  `AVAssetWriter` — clearly synthetic, and used only to prove the sampler's
//  timing arithmetic against a real container. No recognition is asserted over
//  it, so nothing here depends on Vision's behaviour.
//

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import DAQPal

// MARK: - Corpus ⇄ ValidationHarness bridge

/// Agreement between one annotated frame and a prediction for it.
///
/// Lives in the test target because `ReadingVerdict`/`GeometryError` are
/// `ValidationHarness` types: the app target cannot see them, and duplicating
/// the vocabulary on the app side would defeat the point of having one.
struct AnnotationAgreement: Equatable, Sendable {
    let verdict: ReadingVerdict
    /// Nil when the prediction carried no quad — reading-only runs are normal.
    let geometry: GeometryError?
}

extension FrameAnnotation {

    func agreement(with prediction: AnnotationPrediction) -> AnnotationAgreement {
        AnnotationAgreement(
            verdict: ReadingComparison.verdict(truth: value, predicted: prediction.value),
            geometry: prediction.quad.flatMap {
                GeometryError.between(predicted: $0.corners, truth: truthCorners)
            })
    }

    /// Agreement against the prediction stored on the annotation itself.
    var storedAgreement: AnnotationAgreement? {
        prediction.map { agreement(with: $0) }
    }

    /// Reports the frame through the shared measurement vocabulary so a corpus
    /// run aggregates in `ValidationReport` alongside every synthetic sweep.
    func validationOutcome(sweep: String,
                           entryID: String,
                           parameters: [String: String] = [:],
                           durationMS: Double = 0) -> ValidationOutcome? {
        guard let prediction else { return nil }
        let result = agreement(with: prediction)
        return ValidationOutcome(id: "\(entryID)/frame=\(frameIndex)",
                                 sweep: sweep,
                                 parameters: parameters.merging(["entry": entryID]) { a, _ in a },
                                 truth: value,
                                 predicted: prediction.value,
                                 verdict: result.verdict,
                                 geometry: result.geometry,
                                 confidence: prediction.confidence ?? 0,
                                 durationMS: durationMS)
    }
}

// MARK: - Tests

final class CorpusTests: XCTestCase {

    /// 24 frames at 12 fps == exactly 2.0 s, small enough to encode in-test.
    private static let fixtureFrameCount = 24
    private static let fixtureFPS: Int32 = 12
    private static let fixtureText = "90.0"

    /// Whole seconds: `.iso8601` has no sub-second component, so a fractional
    /// date would fail round-trip for a reason that has nothing to do with the
    /// manifest. Acquisition dates are day-resolution provenance anyway.
    private static let acquisition = Date(timeIntervalSince1970: 1_753_574_400)

    private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
    }

    // MARK: Fixtures

    private func fullyDescribedEntry(id: String = "bench-fluke-87v-001") -> CorpusEntry {
        CorpusEntry(id: id,
                    sourceURL: URL(fileURLWithPath: "/corpus/\(id).mov"),
                    platform: .ownCapture,
                    acquisitionDate: Self.acquisition,
                    licence: .userSupplied,
                    attribution: "DAQPal bench recording",
                    deviceCategory: .multimeter,
                    manufacturer: "Fluke",
                    model: "87V",
                    displayType: .sevenSegmentLCD,
                    resolution: CorpusResolution(width: 1920, height: 1080),
                    frameRate: 29.97,
                    durationSeconds: 12.5,
                    orientation: .upright,
                    estimatedViewingAngle: ViewingAngleEstimate(yawDegrees: 15,
                                                                pitchDegrees: -8,
                                                                rollDegrees: 3),
                    lightingNotes: "overhead fluorescent, no direct glare on the LCD")
    }

    /// Only the five required fields; every optional deliberately unset.
    private func minimalEntry(id: String = "unknown-provenance-001",
                              licence: CorpusLicence = .publicDomain) -> CorpusEntry {
        CorpusEntry(id: id,
                    sourceURL: URL(string: "https://example.org/\(id).mp4")!,
                    platform: .internetArchive,
                    acquisitionDate: Self.acquisition,
                    licence: licence)
    }

    // MARK: Manifest round-trip

    func testManifest_roundTripsThroughJSON() throws {
        let manifest = CorpusManifest(name: "daqpal-validation-v1",
                                      entries: [fullyDescribedEntry(), minimalEntry()])

        let data = try manifest.jsonData()
        let decoded = try CorpusManifest(jsonData: data)

        XCTAssertEqual(decoded, manifest, "manifest must survive an encode/decode cycle unchanged")
        XCTAssertEqual(decoded.schemaVersion, CorpusManifest.currentSchemaVersion)
        XCTAssertEqual(decoded[id: "bench-fluke-87v-001"]?.model, "87V")
        XCTAssertEqual(decoded[id: "bench-fluke-87v-001"]?.estimatedViewingAngle?.yawDegrees, 15)

        // Encoding twice must be byte-identical, or manifests do not diff.
        XCTAssertEqual(try decoded.jsonData(), data)
    }

    func testManifest_absentMetadataDecodesAsNilRatherThanADefault() throws {
        // Hand-written JSON with ONLY the required keys — the shape a curator
        // produces when they genuinely do not know the rest.
        let json = """
        {
          "name": "sparse",
          "schemaVersion": 1,
          "entries": [
            {
              "id": "sparse-001",
              "sourceURL": "https://example.org/sparse-001.mp4",
              "platform": "internetArchive",
              "acquisitionDate": "2025-07-27T00:00:00Z",
              "licence": "publicDomain"
            }
          ]
        }
        """
        let manifest = try CorpusManifest(jsonData: Data(json.utf8))
        let entry = try XCTUnwrap(manifest[id: "sparse-001"])

        XCTAssertNil(entry.manufacturer)
        XCTAssertNil(entry.model)
        XCTAssertNil(entry.deviceCategory)
        XCTAssertNil(entry.displayType)
        XCTAssertNil(entry.resolution)
        XCTAssertNil(entry.frameRate)
        XCTAssertNil(entry.durationSeconds)
        XCTAssertNil(entry.orientation)
        XCTAssertNil(entry.estimatedViewingAngle)
        XCTAssertNil(entry.lightingNotes)
        XCTAssertNil(entry.attribution)
        XCTAssertNil(entry.expectedFrameCount, "no rate and no duration must not yield a frame count")

        // And the unknowns stay unknown on the way back out.
        let reencoded = try CorpusManifest(jsonData: try manifest.jsonData())
        XCTAssertEqual(reencoded, manifest)
    }

    func testEntry_expectedFrameCountRequiresBothRateAndDuration() {
        var entry = minimalEntry()
        XCTAssertNil(entry.expectedFrameCount)
        entry.frameRate = 30
        XCTAssertNil(entry.expectedFrameCount, "rate alone is not a frame count")
        entry.durationSeconds = 2
        XCTAssertEqual(entry.expectedFrameCount, 60)
    }

    // MARK: The licence rule

    func testManifest_unknownLicenceEntryIsRejectedByValidation() throws {
        let manifest = CorpusManifest(name: "mixed-rights",
                                      entries: [fullyDescribedEntry(),
                                                minimalEntry(id: "murky-001", licence: .unknown)])

        XCTAssertThrowsError(try manifest.validated()) { error in
            let validation = error as? CorpusValidationError
            XCTAssertEqual(validation?.issues.count, 1)
            XCTAssertEqual(validation?.issues.first?.kind, .unknownLicence)
            XCTAssertEqual(validation?.issues.first?.entryID, "murky-001")
        }

        XCTAssertEqual(manifest.ingestibleEntries.map(\.id), ["bench-fluke-87v-001"],
                       "an unknown-licence entry must not reach an ingestion run")
        XCTAssertEqual(manifest.entries.count, 2,
                       "rejection must not delete the record that the item was considered")
    }

    func testIngestor_refusesUnknownLicenceEvenWhenTheFileIsPresent() async throws {
        // The file genuinely exists, so the only thing that can stop ingestion
        // is the licence check — which is the point of the assertion.
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("murky.mov")
        try Data("not really a movie".utf8).write(to: file)

        var entry = minimalEntry(id: "murky-001", licence: .unknown)
        entry.platform = .localFile
        entry.sourceURL = file

        let ingestor = CorpusIngestor(searchRoots: [directory])
        do {
            _ = try await ingestor.localURL(for: entry)
            XCTFail("ingestion must refuse an entry whose reuse rights are unknown")
        } catch let error as CorpusIngestionError {
            guard case let .entryRejected(id, issues) = error else {
                return XCTFail("expected .entryRejected, got \(error)")
            }
            XCTAssertEqual(id, "murky-001")
            XCTAssertEqual(issues.map(\.kind), [.unknownLicence])
        }

        // Same entry, rights established: now it resolves.
        entry.licence = .userSupplied
        let resolved = try await ingestor.localURL(for: entry)
        XCTAssertEqual(resolved.standardizedFileURL, file.standardizedFileURL)
    }

    func testEntry_ccByWithoutAttributionIsBlocking() {
        var entry = minimalEntry(id: "cc-001", licence: .ccBy)
        XCTAssertEqual(entry.blockingValidationIssues.map(\.kind), [.missingAttribution])
        XCTAssertFalse(entry.isIngestible)

        entry.attribution = "A. Curator, CC BY 4.0"
        XCTAssertTrue(entry.isIngestible)
        XCTAssertTrue(entry.licence.requiresAttribution)
        XCTAssertFalse(CorpusLicence.publicDomain.requiresAttribution)
    }

    func testEntry_outOfEnvelopeViewingAngleIsAdvisoryNotBlocking() {
        var entry = fullyDescribedEntry()
        // Beyond the |yaw| ≤ 60° envelope `DisplayPose3D` documents.
        entry.estimatedViewingAngle = ViewingAngleEstimate(yawDegrees: 72, pitchDegrees: 0)

        let issues = entry.validationIssues()
        XCTAssertEqual(issues.map(\.kind), [.viewingAngleOutsidePoseEnvelope])
        XCTAssertTrue(entry.blockingValidationIssues.isEmpty,
                      "hard material belongs in the corpus; it just has to be labelled as hard")
        XCTAssertTrue(entry.isIngestible)
    }

    func testManifest_duplicateIdentifiersAreRejected() {
        let manifest = CorpusManifest(name: "dupes",
                                      entries: [fullyDescribedEntry(id: "same"),
                                                fullyDescribedEntry(id: "same")])
        XCTAssertThrowsError(try manifest.validated())
        XCTAssertTrue(manifest.ingestibleEntries.isEmpty,
                      "an ambiguous identifier makes both entries unusable as a join key")
    }

    // MARK: Providers

    func testLocalFileProvider_resolvesRelativePathAgainstSearchRoot() async throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("clips", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("dmm.mov")
        try Data("x".utf8).write(to: file)

        var entry = fullyDescribedEntry(id: "relative-001")
        entry.platform = .localFile
        // Scheme-less: the portable form a checked-in manifest stores.
        entry.sourceURL = try XCTUnwrap(URL(string: "clips/dmm.mov"))
        XCTAssertTrue(entry.isIngestible, "a relative path is a valid local reference")

        let provider = LocalFileProvider(searchRoots: [root])
        let resolved = try await provider.localURL(for: entry)
        XCTAssertEqual(resolved.standardizedFileURL, file.standardizedFileURL)
    }

    func testIngestor_reportsMissingFileAndUnsupportedPlatformPerEntry() async throws {
        let root = try makeTemporaryDirectory()
        var missing = fullyDescribedEntry(id: "missing-001")
        missing.platform = .localFile
        missing.sourceURL = root.appendingPathComponent("nope.mov")

        let remote = minimalEntry(id: "remote-001")   // .internetArchive: no provider ships
        let manifest = CorpusManifest(name: "resolution", entries: [missing, remote])

        let results = await CorpusIngestor(searchRoots: [root]).localURLs(for: manifest)
        XCTAssertEqual(results.count, 2)

        guard case .failure(let missingError) = try XCTUnwrap(results["missing-001"]),
              case .fileNotFound = missingError else {
            return XCTFail("expected .fileNotFound for the absent file")
        }
        guard case .failure(let remoteError) = try XCTUnwrap(results["remote-001"]),
              case .noProviderRegistered = remoteError else {
            return XCTFail("expected .noProviderRegistered for a platform with no shipped provider")
        }
    }

    // MARK: Annotations

    func testAnnotation_isIndependentOfSourceResolution() throws {
        // The same physical scene: the display occupies the same fraction of
        // the frame in both, so the pixel coordinates differ by exactly 2x.
        let small = CGSize(width: 640, height: 480)
        let large = CGSize(width: 1280, height: 960)

        let smallAnnotation = Self.annotation(scaledTo: small)
        let largeAnnotation = Self.annotation(scaledTo: large)

        XCTAssertEqual(smallAnnotation, largeAnnotation,
                       "normalized annotations must not change when the source resolution does")
        XCTAssertEqual(smallAnnotation.displayQuad.topLeft.x, 0.1, accuracy: 1e-9)
        XCTAssertEqual(smallAnnotation.decimalPoint?.x ?? -1, 0.5, accuracy: 1e-9)

        // And projecting back scales exactly with the target size.
        let projectedSmall = smallAnnotation.pixelQuad(in: small)
        let projectedLarge = smallAnnotation.pixelQuad(in: large)
        for (a, b) in zip(projectedSmall, projectedLarge) {
            XCTAssertEqual(b.x, a.x * 2, accuracy: 1e-6)
            XCTAssertEqual(b.y, a.y * 2, accuracy: 1e-6)
        }
        XCTAssertEqual(projectedSmall[0], CGPoint(x: 64, y: 144))
    }

    func testAnnotation_glyphBoxesMustSpellTheLabelledValue() throws {
        let good = Self.annotation(scaledTo: CGSize(width: 640, height: 480))
        XCTAssertEqual(good.reconstructedValue, "90.0")
        XCTAssertTrue(good.isWellFormed, "unexpected issues: \(good.issues)")

        var mislabelled = good
        mislabelled.value = "9.00"
        XCTAssertEqual(mislabelled.issues, [.glyphsDoNotSpellValue],
                       "a label that contradicts its own boxes must be caught before it scores anything")

        var badGlyph = good
        badGlyph.digits[0].character = "90"
        XCTAssertTrue(badGlyph.issues.contains(.glyphNotSingleCharacter))
    }

    func testAnnotationSet_roundTripsThroughJSONAndReportsMalformedFrames() throws {
        let frame = Self.annotation(scaledTo: CGSize(width: 640, height: 480))
        var broken = frame
        broken.frameIndex = 1
        broken.value = "9.00"

        let set = GroundTruthAnnotationSet(manifestEntryID: "bench-fluke-87v-001",
                                           frames: [frame, broken],
                                           annotatedAtResolution: CorpusResolution(width: 640, height: 480))
        let decoded = try GroundTruthAnnotationSet(jsonData: try set.jsonData())
        XCTAssertEqual(decoded, set)
        XCTAssertEqual(decoded[frameIndex: 0]?.value, "90.0")

        let malformed = decoded.malformedFrames
        XCTAssertEqual(malformed.map(\.frameIndex), [1])
        XCTAssertEqual(malformed.first?.issues, [.glyphsDoNotSpellValue])
    }

    // MARK: Agreement

    func testAgreement_classifiesADroppedDecimalAsDecimalMissing() throws {
        var annotation = Self.annotation(scaledTo: CGSize(width: 640, height: 480))
        // Every digit right, the point lost — the failure mode that corrupts a
        // recorded value by a factor of ten while still looking plausible.
        let shifted = ScreenQuad(topLeft: CGPoint(x: 0.12, y: 0.30),
                                 topRight: CGPoint(x: 0.90, y: 0.30),
                                 bottomRight: CGPoint(x: 0.90, y: 0.70),
                                 bottomLeft: CGPoint(x: 0.12, y: 0.70))
        annotation.prediction = AnnotationPrediction(value: "900",
                                                     quad: shifted,
                                                     confidence: 0.61,
                                                     engine: "DualPassVisionOCR")

        let agreement = try XCTUnwrap(annotation.storedAgreement)
        XCTAssertEqual(agreement.verdict, .decimalMissing)
        XCTAssertFalse(agreement.verdict.isCorrect)
        XCTAssertTrue(agreement.verdict.isDecimalOnlyFailure)

        let geometry = try XCTUnwrap(agreement.geometry)
        XCTAssertGreaterThan(geometry.iou, 0.8, "the quads overlap heavily; only the reading is wrong")
        // Two of the four corners moved by 0.02; the mean is over all four.
        XCTAssertEqual(geometry.meanCornerError, 0.01, accuracy: 1e-6)
        XCTAssertEqual(geometry.maxCornerError, 0.02, accuracy: 1e-6)

        // An exact prediction with no quad scores exact, with no geometry.
        let exact = annotation.agreement(with: AnnotationPrediction(value: "90.0"))
        XCTAssertEqual(exact.verdict, .exact)
        XCTAssertNil(exact.geometry)

        // Nothing produced is `.notDetected`, not `.digitError`.
        XCTAssertEqual(annotation.agreement(with: AnnotationPrediction(value: nil)).verdict, .notDetected)
    }

    func testAgreement_feedsTheSharedValidationReport() throws {
        var annotation = Self.annotation(scaledTo: CGSize(width: 640, height: 480))
        annotation.prediction = AnnotationPrediction(value: "900", confidence: 0.5, engine: "VisionOCR")

        let outcome = try XCTUnwrap(annotation.validationOutcome(sweep: "corpus",
                                                                 entryID: "bench-fluke-87v-001",
                                                                 durationMS: 4.2))
        let report = ValidationReport(sweep: "corpus", outcomes: [outcome])
        XCTAssertEqual(report.total, 1)
        XCTAssertEqual(report.exactRate, 0)
        XCTAssertEqual(report.decimalOnlyFailureRate, 1)
        XCTAssertEqual(report.detectionRate, 1)
        XCTAssertTrue(report.summary(groupedBy: "entry").contains("decimalMissing=1"))
    }

    // MARK: Sampling

    func testSampler_returnsTheRequestedNumberOfFramesFromARealVideo() async throws {
        let url = try await writeSyntheticFixture()

        // 2.0 s of source at 4 samples/s: instants 0, 0.25 … 1.75 → 8 samples.
        // 2.0 s itself is past the last frame (23/12 ≈ 1.917 s) so it yields
        // nothing, which is the correct behaviour and not an off-by-one.
        let sampler = CorpusFrameSampler(configuration: .init(samplesPerSecond: 4))
        let samples = await sampler.sample(videoURL: url)

        XCTAssertEqual(samples.count, 8)
        XCTAssertEqual(samples.map(\.sampleIndex), Array(0..<8))
        for (index, sample) in samples.enumerated() {
            XCTAssertEqual(sample.sourceTimestamp, Double(index) * 0.25, accuracy: 1.0 / 24.0)
            XCTAssertEqual(CVPixelBufferGetWidth(sample.pixelBuffer), 320)
            XCTAssertEqual(CVPixelBufferGetHeight(sample.pixelBuffer), 568)
        }
    }

    func testSampler_honoursTheMaximumAndTheStartOffset() async throws {
        let url = try await writeSyntheticFixture()

        let capped = await CorpusFrameSampler(configuration: .init(samplesPerSecond: 12,
                                                                   maximumSamples: 3))
            .sample(videoURL: url)
        XCTAssertEqual(capped.count, 3, "the cap must stop the read, not just trim the result")

        let offset = await CorpusFrameSampler(configuration: .init(samplesPerSecond: 2,
                                                                   startSeconds: 1.0))
            .sample(videoURL: url)
        XCTAssertEqual(offset.count, 2, "instants 1.0 and 1.5 fall inside a 2.0 s clip")
        XCTAssertEqual(offset.first?.sourceTimestamp ?? 0, 1.0, accuracy: 1.0 / 24.0)

        let none = await CorpusFrameSampler(configuration: .init(samplesPerSecond: 0)).sample(videoURL: url)
        XCTAssertTrue(none.isEmpty, "a non-positive rate samples nothing rather than everything")
    }

    func testSampler_returnsNoFramesForAFileThatIsNotAVideo() async throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("not-a-movie.mov")
        try Data("plain text".utf8).write(to: url)

        let samples = await CorpusFrameSampler(configuration: .init(samplesPerSecond: 4))
            .sample(videoURL: url)
        XCTAssertTrue(samples.isEmpty, "an unreadable file yields no data, never fabricated frames")
    }

    // MARK: - Helpers

    /// Builds the SAME annotation from pixel coordinates measured in an image of
    /// `size`. Every input is a fixed fraction of the size, so any dependence of
    /// the output on resolution shows up as an inequality.
    private static func annotation(scaledTo size: CGSize) -> FrameAnnotation {
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: fx * size.width, y: fy * size.height)
        }
        func box(_ fx: CGFloat, _ fy: CGFloat, _ fw: CGFloat, _ fh: CGFloat) -> CGRect {
            CGRect(x: fx * size.width, y: fy * size.height,
                   width: fw * size.width, height: fh * size.height)
        }

        let quad = ScreenQuad(topLeft: NormalizedPoint(pixelPoint: point(0.1, 0.3), in: size).cgPoint,
                              topRight: NormalizedPoint(pixelPoint: point(0.9, 0.3), in: size).cgPoint,
                              bottomRight: NormalizedPoint(pixelPoint: point(0.9, 0.7), in: size).cgPoint,
                              bottomLeft: NormalizedPoint(pixelPoint: point(0.1, 0.7), in: size).cgPoint)

        // "90.0": three glyphs with the separator between the second and third.
        let digits = [
            DigitAnnotation(character: "9", pixelBox: box(0.15, 0.35, 0.15, 0.30), in: size),
            DigitAnnotation(character: "0", pixelBox: box(0.32, 0.35, 0.15, 0.30), in: size),
            DigitAnnotation(character: "0", pixelBox: box(0.60, 0.35, 0.15, 0.30), in: size)
        ]

        return FrameAnnotation(frameIndex: 0,
                               timestamp: 0.25,
                               displayQuad: quad,
                               digits: digits,
                               decimalPoint: NormalizedPoint(pixelPoint: point(0.5, 0.62), in: size),
                               value: "90.0")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daqpal-corpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporaryURLs.append(url)
        return url
    }

    /// Encodes `fixtureFrameCount` renderer frames into a real `.mov`.
    ///
    /// Small (320×568) on purpose: the sampler is being measured on timing
    /// arithmetic, not on pixels, and a 1080×1920 encode would dominate the
    /// runtime of this class for no added coverage.
    private func writeSyntheticFixture() async throws -> URL {
        let size = CGSize(width: 320, height: 568)
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("corpus-fixture.mov")

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height)
            ])

        guard writer.canAdd(input) else {
            throw XCTSkip("AVAssetWriter would not accept the H.264 video input in this environment")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? XCTSkip("AVAssetWriter failed to start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let renderer = SyntheticDisplayRenderer(size: size)
        for index in 0..<Self.fixtureFrameCount {
            var waited = 0
            while !input.isReadyForMoreMediaData && waited < 1000 {
                try? await Task.sleep(nanoseconds: 2_000_000)
                waited += 1
            }
            guard let rendered = renderer.render(text: Self.fixtureText) else {
                throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
            }
            let buffer = encoderBuffer(for: rendered, pool: adaptor.pixelBufferPool)
            let pts = CMTime(value: CMTimeValue(index), timescale: Self.fixtureFPS)
            guard adaptor.append(buffer, withPresentationTime: pts) else {
                throw writer.error ?? XCTSkip("AVAssetWriter rejected a frame in this environment")
            }
        }

        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? XCTSkip("AVAssetWriter did not finish in this environment")
        }
        return url
    }

    /// Copies into a pool-vended (IOSurface-backed) buffer, which is what the
    /// H.264 encoder prefers; falls back to the rendered buffer with no pool.
    private func encoderBuffer(for rendered: CVPixelBuffer, pool: CVPixelBufferPool?) -> CVPixelBuffer {
        guard let pool else { return rendered }
        var vended: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &vended) == kCVReturnSuccess,
              let destination = vended else { return rendered }

        CVPixelBufferLockBaseAddress(rendered, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(rendered, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(rendered),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return rendered }
        let sourceStride = CVPixelBufferGetBytesPerRow(rendered)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(sourceStride, destinationStride)
        for row in 0..<min(CVPixelBufferGetHeight(rendered), CVPixelBufferGetHeight(destination)) {
            memcpy(dst + row * destinationStride, src + row * sourceStride, rowBytes)
        }
        return destination
    }
}
