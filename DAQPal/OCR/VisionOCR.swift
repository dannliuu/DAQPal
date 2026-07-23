//
//  VisionOCR.swift
//  DAQPal
//
//  VNRecognizeTextRequest wrapper (spec §8, Milestone 2). Fast recognition
//  level with language correction off: DMM readouts are short digit strings,
//  and correction would "fix" them into words.
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

    func recognize(in pixelBuffer: CVPixelBuffer,
                   regionOfInterest: NormalizedROI?) async throws -> [OCRCandidate] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
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

        var candidates: [OCRCandidate] = []
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(Self.candidatesPerObservation) {
                candidates.append(OCRCandidate(text: candidate.string,
                                               confidence: candidate.confidence))
            }
        }
        return candidates.sorted { $0.confidence > $1.confidence }
    }
}
