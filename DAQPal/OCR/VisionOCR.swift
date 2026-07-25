//
//  VisionOCR.swift
//  DAQPal
//
//  VNRecognizeTextRequest wrapper (spec §8, Milestone 2). Language correction is
//  always off: DMM readouts are short digit strings, and correction would "fix"
//  them into words.
//
//  The recognition level is a constructor parameter (default `.accurate`, so the
//  shipping default is unchanged). `.accurate` costs ~35× more per frame but
//  returns calibrated confidences — `.fast` reports ~0.3 even on clean digits,
//  which once dominated the fused measurement confidence and read as a broken
//  32% in the UI, so `.fast` output must never be preferred where `.accurate`
//  produces a reading. The Milestone 9 benchmark (OCR_RESEARCH.md) found `.fast`
//  nonetheless *recalls* segmented glyphs `.accurate` misses; `DualPassVisionOCR`
//  exploits that by running a `.fast` instance as a concurrent rescue pass while
//  keeping `.accurate` preferred for its honest confidences.
//

import CoreGraphics
import CoreVideo
import Foundation
import Vision

struct VisionOCR: OCREngine {
    /// Candidate hypotheses requested per observation. `.fast` typically
    /// yields one; asking for a few is harmless and lets the pipeline see
    /// near-miss readings.
    private static let candidatesPerObservation = 3

    /// The `VNRecognizeTextRequest` recognition level. `.accurate` is the
    /// shipping default (calibrated confidences); `.fast` trades those for
    /// latency and segment-glyph recall (see the file header).
    private let recognitionLevel: VNRequestTextRecognitionLevel

    init(recognitionLevel: VNRequestTextRecognitionLevel = .accurate) {
        self.recognitionLevel = recognitionLevel
    }

    func recognize(in pixelBuffer: CVPixelBuffer,
                   regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        request.recognitionLanguages = ["en-US"]

        if let roi = regionOfInterest {
            // Vision's regionOfInterest is normalized with a BOTTOM-LEFT
            // origin; the project convention is top-left (buffers reach the
            // pipeline already portrait-upright, see NormalizedROI docs).
            // Flip the y component only.
            let r = roi.clamped()
            request.regionOfInterest = CGRect(x: r.x,
                                              y: 1 - r.y - r.height,
                                              width: r.width,
                                              height: r.height)
        }

        // Buffers are already upright, so the default `.up` orientation is
        // correct. `perform` is synchronous CPU work; running it inline is
        // intentional — serial consumption is the pipeline's backpressure
        // (spec §40.2), so there is nothing useful to do concurrently.
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try handler.perform([request])

        // Vision reports observation boxes bottom-left-normalized RELATIVE TO
        // the regionOfInterest; convert to the project's top-left convention
        // in the full buffer's space so downstream ROI tracking can use them.
        let region = regionOfInterest?.clamped() ?? NormalizedROI(x: 0, y: 0, width: 1, height: 1)
        var candidates: [OCRCandidate] = []
        for observation in request.results ?? [] {
            let box = observation.boundingBox
            let frameBox = NormalizedROI(
                x: region.x + box.minX * region.width,
                y: region.y + (1 - box.maxY) * region.height,
                width: box.width * region.width,
                height: box.height * region.height).clamped()
            for candidate in observation.topCandidates(Self.candidatesPerObservation) {
                candidates.append(OCRCandidate(text: candidate.string,
                                               confidence: candidate.confidence,
                                               boundingBox: frameBox))
            }
        }
        return candidates.sorted { $0.confidence > $1.confidence }
    }
}
