//
//  CorpusManifest.swift
//  DAQPal
//
//  Declarative description of a validation corpus: the set of real-world
//  recordings the recognition pipeline is scored against. DEVELOPMENT ONLY —
//  nothing in `Corpus/` is reachable from a shipping capture path; it exists so
//  accuracy claims can be traced back to material with a known provenance.
//
//  WHY LICENCE IS NON-OPTIONAL AND `.unknown` IS FATAL. A corpus is only useful
//  if it can be redistributed, or at minimum re-derived by whoever audits a
//  number that came out of it. Once material with unclear reuse rights is in the
//  set, every measurement taken over that set inherits the ambiguity and the
//  only remedy is to re-run everything. Making `licence` non-optional stops an
//  entry from being written without the question being asked; making `.unknown`
//  a *blocking* validation issue stops "I'll fill it in later" from becoming a
//  permanent state. `.unknown` is deliberately representable — recording that
//  the rights are unclear is honest — it just cannot be ingested.
//
//  WHY ALMOST EVERYTHING ELSE IS OPTIONAL. Manufacturer, model, frame rate and
//  viewing angle are frequently unknowable for third-party footage. An Optional
//  left nil says "not established"; a plausible-looking default says "measured",
//  and the difference matters when the corpus is later sliced by device model to
//  explain a failure. There is no `.unknown` case on any enum other than the
//  licence: absence is spelled `nil`, exactly once, everywhere.
//

import CoreGraphics
import Foundation

// MARK: - Rights

/// Reuse rights for one corpus item. The only field in the manifest with no
/// Optional escape hatch.
enum CorpusLicence: String, Codable, CaseIterable, Sendable {
    /// No copyright subsists, or it has expired.
    case publicDomain
    /// Creative Commons CC0 1.0 — rights waived.
    case cc0
    /// Creative Commons Attribution.
    case ccBy
    /// Creative Commons Attribution-ShareAlike.
    case ccBySa
    /// Supplied by the operator of this project from their own equipment. The
    /// common case for DAQPal's own bench recordings.
    case userSupplied
    /// Rights not established. Representable so the state can be *recorded*,
    /// never ingested — see `permitsCorpusUse`.
    case unknown

    /// False only for `.unknown`. Named rather than written as `!= .unknown` at
    /// the validation and ingestion sites, which must agree.
    var permitsCorpusUse: Bool { self != .unknown }

    /// CC-BY family: the attribution string is part of the licence grant, so an
    /// entry that omits it is not actually licensed.
    var requiresAttribution: Bool { self == .ccBy || self == .ccBySa }

    /// ShareAlike propagates to derivatives — annotations and cropped frames
    /// derived from such an item carry the same terms.
    var propagatesToDerivatives: Bool { self == .ccBySa }
}

// MARK: - Provenance

/// Where an item came from. Recorded separately from the URL because the URL
/// may be a bare file path for material that was never on the network.
enum CorpusSourcePlatform: String, Codable, CaseIterable, Sendable {
    /// Already on this machine — the only platform `LocalFileProvider` and the
    /// operator's own bench recordings need.
    case localFile
    case ownCapture
    case wikimediaCommons
    case internetArchive
    /// A published research/benchmark dataset with its own licence terms.
    case openDataset
    /// Manufacturer-published imagery (datasheet, manual, product page).
    case manufacturerMaterial
    case other
}

// MARK: - Subject

enum CorpusDeviceCategory: String, Codable, CaseIterable, Sendable {
    case multimeter
    case clampMeter
    case irThermometer
    case contactThermometer
    case scale
    case oscilloscope
    case benchPowerSupply
    case pressureGauge
    case flowMeter
    case other
}

/// Display technology, which is what actually predicts recognition difficulty:
/// Apple Vision scores 14.6% on seven-segment glyphs against a far higher rate
/// on dot-matrix text, so a corpus that does not record this cannot explain its
/// own aggregate accuracy.
enum CorpusDisplayTechnology: String, Codable, CaseIterable, Sendable {
    case sevenSegmentLCD
    case sevenSegmentLED
    case fourteenSegment
    case dotMatrixLCD
    case graphicLCD
    case oled
    case vacuumFluorescent
    case eInk
    case other
}

/// How the media is stored relative to upright. Nil until read off the file —
/// guessing this silently transposes every annotation on the item.
enum CorpusMediaOrientation: String, Codable, CaseIterable, Sendable {
    case upright
    case rotatedLeft
    case rotatedRight
    case upsideDown
}

struct CorpusResolution: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }
    var isPositive: Bool { width > 0 && height > 0 }
}

/// Coarse operator estimate of where the camera sat relative to the display.
///
/// Degrees, not radians: this is hand-entered from looking at the footage, and
/// nobody estimates 0.52 rad by eye. `DisplayPose3D` works in radians, so
/// `poseRadians` does the one conversion rather than leaving it to call sites.
struct ViewingAngleEstimate: Codable, Equatable, Sendable {
    /// Positive = the display's right edge recedes from the camera, matching
    /// `DisplayPose3D.yaw`.
    var yawDegrees: CGFloat
    /// Positive = the display's top edge recedes, matching `DisplayPose3D.pitch`.
    var pitchDegrees: CGFloat
    /// In-plane rotation, positive clockwise on screen. Nil when the footage is
    /// level enough that no estimate was made.
    var rollDegrees: CGFloat?

    init(yawDegrees: CGFloat, pitchDegrees: CGFloat, rollDegrees: CGFloat? = nil) {
        self.yawDegrees = yawDegrees
        self.pitchDegrees = pitchDegrees
        self.rollDegrees = rollDegrees
    }

    var poseRadians: (yaw: CGFloat, pitch: CGFloat, roll: CGFloat) {
        let toRadians = CGFloat.pi / 180
        return (yawDegrees * toRadians, pitchDegrees * toRadians, (rollDegrees ?? 0) * toRadians)
    }

    /// The envelope `DisplayPose3D` documents as valid: |yaw|, |pitch| ≤ 60°,
    /// |roll| ≤ 45°. Outside it the projection's semantic-corner contract stops
    /// holding, so a corpus item beyond it is measuring something the geometry
    /// stack does not claim to support.
    var isWithinPoseEnvelope: Bool {
        abs(yawDegrees) <= 60 && abs(pitchDegrees) <= 60 && abs(rollDegrees ?? 0) <= 45
    }
}

// MARK: - Entry

/// One recording (or still) in the corpus.
///
/// Codable with the synthesized conformance on purpose: a key absent from the
/// JSON decodes to `nil` for every Optional, which is precisely the "unstated
/// means unestablished" rule this type is built around. Do not add a custom
/// `init(from:)` that substitutes defaults.
struct CorpusEntry: Codable, Equatable, Sendable, Identifiable {

    // Required — an entry cannot exist without these.

    /// Stable, human-readable, unique within a manifest. Used as the join key
    /// to `GroundTruthAnnotationSet.manifestEntryID`.
    var id: String
    var sourceURL: URL
    var platform: CorpusSourcePlatform
    /// When the item was obtained, not when it was recorded — provenance, not
    /// subject metadata. Day resolution is enough; encoded as ISO-8601.
    var acquisitionDate: Date
    var licence: CorpusLicence

    // Optional — nil means "not established", never "none" or "zero".

    /// Required in practice for the CC-BY family; see `licence.requiresAttribution`.
    var attribution: String?
    var deviceCategory: CorpusDeviceCategory?
    var manufacturer: String?
    var model: String?
    var displayType: CorpusDisplayTechnology?
    var resolution: CorpusResolution?
    var frameRate: Double?
    var durationSeconds: Double?
    var orientation: CorpusMediaOrientation?
    var estimatedViewingAngle: ViewingAngleEstimate?
    var lightingNotes: String?

    init(id: String,
         sourceURL: URL,
         platform: CorpusSourcePlatform,
         acquisitionDate: Date,
         licence: CorpusLicence,
         attribution: String? = nil,
         deviceCategory: CorpusDeviceCategory? = nil,
         manufacturer: String? = nil,
         model: String? = nil,
         displayType: CorpusDisplayTechnology? = nil,
         resolution: CorpusResolution? = nil,
         frameRate: Double? = nil,
         durationSeconds: Double? = nil,
         orientation: CorpusMediaOrientation? = nil,
         estimatedViewingAngle: ViewingAngleEstimate? = nil,
         lightingNotes: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.platform = platform
        self.acquisitionDate = acquisitionDate
        self.licence = licence
        self.attribution = attribution
        self.deviceCategory = deviceCategory
        self.manufacturer = manufacturer
        self.model = model
        self.displayType = displayType
        self.resolution = resolution
        self.frameRate = frameRate
        self.durationSeconds = durationSeconds
        self.orientation = orientation
        self.estimatedViewingAngle = estimatedViewingAngle
        self.lightingNotes = lightingNotes
    }

    /// Expected frame count when both rate and duration are established. Nil
    /// rather than a guess when either is missing — the sampler needs a real
    /// number or none.
    var expectedFrameCount: Int? {
        guard let frameRate, let durationSeconds, frameRate > 0, durationSeconds > 0 else { return nil }
        return Int((frameRate * durationSeconds).rounded())
    }
}

// MARK: - Validation

/// One reason an entry (or the manifest as a whole) is not fit to ingest.
struct CorpusValidationIssue: Equatable, Sendable, CustomStringConvertible {

    enum Kind: String, Equatable, Sendable {
        /// The rights are not established. Fatal by design — see file header.
        case unknownLicence
        /// CC-BY family without the attribution the licence grant requires.
        case missingAttribution
        case emptyIdentifier
        case duplicateIdentifier
        /// A `.localFile` entry whose URL is not a file URL, or a remote entry
        /// with no usable scheme.
        case unusableSourceURL
        case nonPositiveResolution
        case nonPositiveFrameRate
        case nonPositiveDuration
        /// Advisory: the item is outside the pose envelope the geometry stack
        /// claims. Such material is worth keeping — it is where the pipeline is
        /// expected to fail — but a run that includes it must say so rather
        /// than folding it into an aggregate accuracy figure.
        case viewingAngleOutsidePoseEnvelope

        /// Blocking issues stop ingestion; the rest annotate it.
        var isBlocking: Bool { self != .viewingAngleOutsidePoseEnvelope }
    }

    let kind: Kind
    let entryID: String
    let detail: String

    var description: String { "[\(kind.rawValue)] \(entryID): \(detail)" }
}

/// Thrown by `CorpusManifest.validated()`; carries every issue rather than the
/// first, so a manifest is fixed in one pass.
struct CorpusValidationError: Error, Equatable, CustomStringConvertible {
    let issues: [CorpusValidationIssue]
    var description: String {
        "corpus manifest rejected:\n" + issues.map { "  " + $0.description }.joined(separator: "\n")
    }
}

extension CorpusEntry {
    /// Everything checkable without reference to the rest of the manifest.
    /// Duplicate-identifier detection is manifest-level and lives there.
    func validationIssues() -> [CorpusValidationIssue] {
        var issues: [CorpusValidationIssue] = []
        func add(_ kind: CorpusValidationIssue.Kind, _ detail: String) {
            issues.append(CorpusValidationIssue(kind: kind, entryID: id, detail: detail))
        }

        if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.emptyIdentifier, "entry identifier is empty")
        }
        if !licence.permitsCorpusUse {
            add(.unknownLicence, "licence is .unknown; establish the rights before ingesting")
        }
        if licence.requiresAttribution,
           (attribution?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            add(.missingAttribution, "\(licence.rawValue) requires an attribution string")
        }

        switch platform {
        case .localFile, .ownCapture:
            // Scheme-less means a portable path relative to an ingestion search
            // root — the form a checked-in manifest uses.
            if !sourceURL.isFileURL && sourceURL.scheme != nil {
                add(.unusableSourceURL,
                    "\(platform.rawValue) entry needs a file URL or a relative path, got \(sourceURL)")
            }
        default:
            let scheme = sourceURL.scheme?.lowercased()
            if scheme != "http" && scheme != "https" && !sourceURL.isFileURL {
                add(.unusableSourceURL, "unsupported URL scheme \(sourceURL.scheme ?? "(none)")")
            }
        }

        if let resolution, !resolution.isPositive {
            add(.nonPositiveResolution, "resolution \(resolution.width)x\(resolution.height)")
        }
        if let frameRate, !(frameRate > 0) {
            add(.nonPositiveFrameRate, "frame rate \(frameRate)")
        }
        if let durationSeconds, !(durationSeconds > 0) {
            add(.nonPositiveDuration, "duration \(durationSeconds) s")
        }
        if let angle = estimatedViewingAngle, !angle.isWithinPoseEnvelope {
            add(.viewingAngleOutsidePoseEnvelope,
                "yaw \(angle.yawDegrees)°, pitch \(angle.pitchDegrees)°, roll \(angle.rollDegrees ?? 0)°")
        }
        return issues
    }

    var blockingValidationIssues: [CorpusValidationIssue] {
        validationIssues().filter { $0.kind.isBlocking }
    }

    var isIngestible: Bool { blockingValidationIssues.isEmpty }
}

// MARK: - Manifest

struct CorpusManifest: Codable, Equatable, Sendable {

    /// Bumped when the on-disk shape changes incompatibly. Stored so an old
    /// manifest is recognisable as old instead of silently half-decoding.
    static let currentSchemaVersion = 1

    var name: String
    var schemaVersion: Int
    var entries: [CorpusEntry]

    init(name: String, entries: [CorpusEntry], schemaVersion: Int = CorpusManifest.currentSchemaVersion) {
        self.name = name
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    subscript(id id: String) -> CorpusEntry? { entries.first { $0.id == id } }

    /// Every issue across every entry, plus manifest-level duplicate ids.
    func validationIssues() -> [CorpusValidationIssue] {
        var issues = entries.flatMap { $0.validationIssues() }
        var seen = Set<String>()
        for entry in entries where !seen.insert(entry.id).inserted {
            issues.append(CorpusValidationIssue(kind: .duplicateIdentifier,
                                                entryID: entry.id,
                                                detail: "identifier appears more than once"))
        }
        return issues
    }

    /// The entries an ingestion run may touch. An `.unknown`-licence entry is
    /// absent from this list; it is not silently repaired and not thrown away
    /// from `entries`, so the manifest still records that the item was seen.
    var ingestibleEntries: [CorpusEntry] {
        let duplicated = Set(Dictionary(grouping: entries, by: \.id).filter { $0.value.count > 1 }.keys)
        return entries.filter { $0.isIngestible && !duplicated.contains($0.id) }
    }

    /// Returns self when nothing blocking is wrong, otherwise throws with the
    /// full issue list. Advisory issues never block.
    @discardableResult
    func validated() throws -> CorpusManifest {
        let issues = validationIssues()
        let blocking = issues.filter { $0.kind.isBlocking }
        guard blocking.isEmpty else { throw CorpusValidationError(issues: blocking) }
        return self
    }

    // MARK: JSON

    /// Fixed key order and ISO-8601 dates so two revisions of a manifest diff
    /// cleanly in git, for the same reason `ValidationReport.jsonLines()` fixes
    /// its key order.
    static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func jsonData() throws -> Data { try Self.jsonEncoder().encode(self) }

    init(jsonData: Data) throws {
        self = try Self.jsonDecoder().decode(CorpusManifest.self, from: jsonData)
    }

    func write(to url: URL) throws { try jsonData().write(to: url, options: .atomic) }

    init(contentsOf url: URL) throws { try self.init(jsonData: Data(contentsOf: url)) }
}
