//
//  CorpusIngestion.swift
//  DAQPal
//
//  Turns a `CorpusManifest` entry into a local file, and a local video into a
//  handful of representative frames. DEVELOPMENT ONLY.
//
//  ACQUISITION IS PLUGGABLE AND DELIBERATELY DECOUPLED FROM RECOGNITION.
//  `CorpusSourceProvider` knows how to get bytes onto disk and nothing else: no
//  provider sees a `CVPixelBuffer`, an ROI, or an OCR type. That seam is what
//  lets a new source be added without touching the pipeline, and equally lets
//  the pipeline change without invalidating how material was obtained.
//
//  WHY ONLY `LocalFileProvider` SHIPS. Every large video platform's terms
//  prohibit automated downloading, and several enforce it with access controls
//  that a provider would have to defeat. Writing that provider would make the
//  corpus itself unusable — material obtained in breach of the terms it was
//  published under cannot carry a defensible `CorpusLicence`, which is the one
//  field this system refuses to leave vague. The conformance point below is the
//  extension point for sources that *do* permit it (an open dataset mirror, an
//  archive with a documented API); material from a platform that does not is
//  brought in by hand through that platform's own export affordance and
//  registered as `.userSupplied` against a local file.
//

import CoreVideo
import Foundation

// MARK: - Provider protocol

/// Resolves a manifest entry to a readable local file.
///
/// Conformances must be side-effect-free with respect to the manifest: a
/// provider never edits metadata, because a provider is exactly the layer with
/// the least information about what the item actually contains.
protocol CorpusSourceProvider: Sendable {
    /// Platforms this provider claims. `CorpusIngestor` dispatches on it.
    var supportedPlatforms: Set<CorpusSourcePlatform> { get }

    /// - Returns: a file URL that exists and is readable at the moment of return.
    /// - Throws: `CorpusIngestionError` for anything that leaves no local file.
    func localURL(for entry: CorpusEntry) async throws -> URL
}

enum CorpusIngestionError: Error, Equatable, CustomStringConvertible {
    /// Blocked before any I/O — includes the `.unknown` licence case.
    case entryRejected(entryID: String, issues: [CorpusValidationIssue])
    case noProviderRegistered(entryID: String, platform: CorpusSourcePlatform)
    case notAFileURL(entryID: String, url: URL)
    case fileNotFound(entryID: String, url: URL)
    case fileNotReadable(entryID: String, url: URL)

    var description: String {
        switch self {
        case let .entryRejected(id, issues):
            return "\(id) rejected: " + issues.map(\.description).joined(separator: "; ")
        case let .noProviderRegistered(id, platform):
            return "\(id): no provider registered for platform .\(platform.rawValue)"
        case let .notAFileURL(id, url):
            return "\(id): \(url) is not a file URL"
        case let .fileNotFound(id, url):
            return "\(id): no file at \(url.path)"
        case let .fileNotReadable(id, url):
            return "\(id): file at \(url.path) is not readable"
        }
    }
}

// MARK: - Local files

/// The only provider supplied. Handles material the operator already has: their
/// own bench recordings, and anything obtained by hand.
///
/// A manifest travels between machines, so a local entry's URL is either an
/// absolute `file:` URL (this machine only) or a bare scheme-less relative path
/// resolved against `searchRoots` (portable — the form a checked-in manifest
/// uses, since an absolute path baked into it is wrong everywhere else).
struct LocalFileProvider: CorpusSourceProvider {

    /// Searched in order for a relative reference. Empty means only absolute
    /// file URLs resolve.
    let searchRoots: [URL]
    private let fileManager: FileManager

    init(searchRoots: [URL] = [], fileManager: FileManager = .default) {
        self.searchRoots = searchRoots
        self.fileManager = fileManager
    }

    var supportedPlatforms: Set<CorpusSourcePlatform> { [.localFile, .ownCapture] }

    func localURL(for entry: CorpusEntry) async throws -> URL {
        let url = entry.sourceURL
        let candidates: [URL]
        if url.isFileURL {
            candidates = [url]
        } else if url.scheme == nil {
            // `URL` would resolve a relative reference against the process's
            // working directory, which for a test bundle means nothing; the
            // search roots are the only meaningful interpretation.
            candidates = searchRoots.map { $0.appendingPathComponent(url.relativePath) }
        } else {
            throw CorpusIngestionError.notAFileURL(entryID: entry.id, url: url)
        }

        guard let found = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) else {
            throw CorpusIngestionError.fileNotFound(entryID: entry.id, url: candidates.first ?? url)
        }
        guard fileManager.isReadableFile(atPath: found.path) else {
            throw CorpusIngestionError.fileNotReadable(entryID: entry.id, url: found)
        }
        return found
    }
}

// MARK: - Ingestor

/// Dispatches entries to providers, refusing anything the manifest rules
/// disallow *before* any I/O happens.
///
/// The licence check is repeated here rather than trusted from validation: an
/// entry can reach this call without the manifest having been validated (a
/// single-entry ad-hoc run, a manifest built in code), and "the corpus never
/// silently accumulates material with unclear reuse rights" has to hold at the
/// point material is actually fetched.
struct CorpusIngestor: Sendable {

    private let providers: [any CorpusSourceProvider]

    init(providers: [any CorpusSourceProvider]) {
        self.providers = providers
    }

    /// Local-files-only ingestor, the default development configuration.
    init(searchRoots: [URL] = []) {
        self.init(providers: [LocalFileProvider(searchRoots: searchRoots)])
    }

    func provider(for platform: CorpusSourcePlatform) -> (any CorpusSourceProvider)? {
        providers.first { $0.supportedPlatforms.contains(platform) }
    }

    func localURL(for entry: CorpusEntry) async throws -> URL {
        let blocking = entry.blockingValidationIssues
        guard blocking.isEmpty else {
            throw CorpusIngestionError.entryRejected(entryID: entry.id, issues: blocking)
        }
        guard let provider = provider(for: entry.platform) else {
            throw CorpusIngestionError.noProviderRegistered(entryID: entry.id, platform: entry.platform)
        }
        return try await provider.localURL(for: entry)
    }

    /// Resolves every ingestible entry, keeping per-entry failures instead of
    /// aborting the run: one missing file must not hide the other forty.
    /// Non-ingestible entries are not attempted and are reported as rejected.
    func localURLs(for manifest: CorpusManifest) async -> [String: Result<URL, CorpusIngestionError>] {
        var results: [String: Result<URL, CorpusIngestionError>] = [:]
        for entry in manifest.entries {
            do {
                results[entry.id] = .success(try await localURL(for: entry))
            } catch let error as CorpusIngestionError {
                results[entry.id] = .failure(error)
            } catch {
                results[entry.id] = .failure(.fileNotFound(entryID: entry.id, url: entry.sourceURL))
            }
        }
        return results
    }
}

// MARK: - Frame sampling

/// One frame kept by the sampler.
///
/// `@unchecked Sendable` on the same grounds as `TimestampedFrame`: the buffer
/// is a private copy owned solely by this value (see `CorpusFrameSampler`'s
/// copy step) and is only ever read downstream.
struct CorpusFrameSample: @unchecked Sendable {
    /// Index within the SAMPLED sequence, not within the source video.
    let sampleIndex: Int
    /// Presentation time in the source's own timeline, seconds.
    let sourceTimestamp: TimeInterval
    let pixelBuffer: CVPixelBuffer
}

/// Reduces a video to representative frames at a configurable rate.
///
/// Built on `FixtureFrameSource` rather than a second `AVAssetReader`: there is
/// one place in this project that knows how to turn a file into
/// `TimestampedFrame`s, and a corpus that decoded differently from the fixture
/// harness would not be measuring the same pipeline.
///
/// COST. `AVAssetReader` reads sequentially, so intermediate frames are still
/// decoded — there is no free seek within a GOP. What the sampler avoids is the
/// expensive part: only frames at the requested interval are copied and
/// retained, so memory is O(samples) rather than O(frames), and the iteration
/// stops the moment `maximumSamples` is reached, which cancels the reader and
/// leaves the rest of the file undecoded.
struct CorpusFrameSampler: Sendable {

    struct Configuration: Equatable, Sendable {
        /// Samples per second of SOURCE time. A rate at or above the source
        /// frame rate yields every frame.
        var samplesPerSecond: Double
        /// Hard cap; nil samples to the end of the asset.
        var maximumSamples: Int?
        /// Skips the head of the clip, where autofocus/exposure are still
        /// settling on most hand-held footage.
        var startSeconds: TimeInterval

        init(samplesPerSecond: Double, maximumSamples: Int? = nil, startSeconds: TimeInterval = 0) {
            self.samplesPerSecond = samplesPerSecond
            self.maximumSamples = maximumSamples
            self.startSeconds = startSeconds
        }
    }

    let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// - Returns: frames whose source timestamps are the first at or after each
    ///   scheduled instant. Empty when the rate is non-positive, when the cap is
    ///   zero, or when the file yields no frames — an unreadable file is not an
    ///   error here for the same reason `FixtureFrameSource` swallows one: the
    ///   caller distinguishes "no data" from "wrong data", and a fabricated
    ///   frame would corrupt the second.
    func sample(videoURL: URL) async -> [CorpusFrameSample] {
        guard configuration.samplesPerSecond > 0 else { return [] }
        if let cap = configuration.maximumSamples, cap <= 0 { return [] }

        let interval = 1.0 / configuration.samplesPerSecond
        var samples: [CorpusFrameSample] = []
        var dueIndex = 0

        for await frame in FixtureFrameSource(videoURL: videoURL).frames() {
            // Scheduled instants are recomputed from the index rather than
            // accumulated, so a long clip cannot drift off the grid.
            var due = configuration.startSeconds + Double(dueIndex) * interval
            guard frame.timestamp >= due - Self.timestampEpsilon else { continue }

            // A source slower than the requested rate (or a gap in the media)
            // can skip past several instants at once; advance to the next one
            // strictly after this frame so each yields at most one sample.
            while frame.timestamp >= due - Self.timestampEpsilon {
                dueIndex += 1
                due = configuration.startSeconds + Double(dueIndex) * interval
            }

            guard let copy = Self.copiedBuffer(frame.pixelBuffer) else { continue }
            samples.append(CorpusFrameSample(sampleIndex: samples.count,
                                             sourceTimestamp: frame.timestamp,
                                             pixelBuffer: copy))
            if let cap = configuration.maximumSamples, samples.count >= cap { break }
        }
        return samples
    }

    /// Presentation timestamps come back as `CMTime.seconds`, so an instant
    /// like 0.25 s is exact but 0.2 s is not; a tolerance well below one frame
    /// at any plausible rate keeps the grid from slipping a frame late.
    private static let timestampEpsilon: TimeInterval = 1e-6

    /// Deep copy of a sampled frame.
    ///
    /// Required, not defensive: `FixtureFrameSource` sets
    /// `alwaysCopiesSampleData = false`, so a retained buffer holds a block of
    /// the decoder's own finite pool. Holding a run of them starves the reader
    /// and stalls decoding of the very frames still being sampled.
    private static func copiedBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        // The reader is configured for 32BGRA, so the non-planar path is the
        // only one that can occur; a planar buffer would need per-plane copies.
        guard !CVPixelBufferIsPlanar(source) else { return nil }

        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        var destination: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  CVPixelBufferGetPixelFormatType(source),
                                  attrs as CFDictionary, &destination) == kCVReturnSuccess,
              let destination else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(destination, [])
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
        }
        guard let src = CVPixelBufferGetBaseAddress(source),
              let dst = CVPixelBufferGetBaseAddress(destination) else { return nil }

        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let destinationStride = CVPixelBufferGetBytesPerRow(destination)
        let rowBytes = min(sourceStride, destinationStride)
        for row in 0..<height {
            memcpy(dst + row * destinationStride, src + row * sourceStride, rowBytes)
        }
        return destination
    }
}
