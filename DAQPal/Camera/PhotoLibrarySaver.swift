//
//  PhotoLibrarySaver.swift
//  DAQPal
//
//  Saves a finished session recording to the user's photo library. Add-only
//  authorization (`INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription`) — DAQPal
//  never reads the user's existing library, it only ever adds the video it
//  just wrote. `Photos` is imported nowhere else in the app.
//
//  Deliberately NO album targeting: fetching or creating a named album is a
//  library READ, which requires full `.readWrite` authorization and the
//  `NSPhotoLibraryUsageDescription` key — attempting it under add-only
//  terminates the app with a TCC privacy violation (observed in Simulator,
//  crash report 2026-07-23). The video lands in Recents; a "DAQPal" album
//  can come later only if the heavier permission is ever justified.
//

// Photos predates Sendable auditing (like AVFoundation elsewhere in this
// project); `PHAssetCollection`/`PHObjectPlaceholder` cross the
// `performChanges` closure boundary below, which is Apple's documented
// pattern for library writes.
@preconcurrency import Photos

enum PhotoLibrarySaver {

    enum SaveError: LocalizedError {
        case authorizationDenied

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                "DAQPal isn't allowed to save videos to Photos. Enable Photos access for DAQPal in Settings to save session recordings."
            }
        }
    }

    /// Requests add-only Photos authorization and adds `videoURL` to the
    /// library (Recents) as a new asset. The caller owns `videoURL`'s
    /// lifetime — this only reads the file, it never deletes it.
    static func save(videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        // `.limited` cannot actually occur for `.addOnly` (that case only
        // applies to `.readWrite`'s partial-library picker), but treating it
        // as sufficient here is harmless and future-proof.
        guard status == .authorized || status == .limited else {
            throw SaveError.authorizationDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
        }
    }
}
