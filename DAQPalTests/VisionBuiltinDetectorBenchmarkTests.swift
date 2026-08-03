//
//  VisionBuiltinDetectorBenchmarkTests.swift
//  DAQPalTests
//
//  MEASUREMENT HARNESS for the "zero-model detector" question:
//  can Apple's BUILT-IN Vision requests answer "is there a handheld
//  measurement instrument in this frame, and where?" at a few Hz — with no
//  custom Core ML model shipped at all?
//
//  What this measures
//  ------------------
//  Wall-clock latency of a single `VNImageRequestHandler.perform([request])`
//  for each candidate built-in, plus what each request actually RETURNS on the
//  one real-instrument photo this repo owns (`Fixtures/ir_gun_display.png`).
//
//  Honesty
//  -------
//  * Latency is whatever it measures on whatever device the test runs on. The
//    test PRINTS the device model, OS, core count and thermal state so no
//    number can be quoted without its hardware.
//  * A Simulator run measures the Mac, not an iPhone. The test prints which it
//    is; Simulator numbers must never be quoted as iPhone latency.
//  * NOTHING is asserted about speed. The only assertions are structural (the
//    request ran, time was measurable).
//  * The image corpus is ONE real photo plus scaled variants of it. That is a
//    latency corpus, not an accuracy corpus. No detection-accuracy claim can
//    be derived from this test.
//
//  Run it deliberately:
//      -only-testing:DAQPalTests/VisionBuiltinDetectorBenchmarkTests
//

import CoreVideo
import Foundation
import UIKit
import Vision
import XCTest

final class VisionBuiltinDetectorBenchmarkTests: XCTestCase {

    // MARK: - Configuration

    /// Iterations timed per (request, image) pair, after warmup.
    private static let iterations = 20
    /// Warmup passes, discarded. Vision loads models lazily and process-wide;
    /// the first call is dominated by that load, not by inference.
    private static let warmups = 3

    private struct Frame {
        let name: String
        let buffer: CVPixelBuffer
        let pixels: Int
    }

    override func setUp() {
        super.setUp()
        executionTimeAllowance = 900
    }

    // MARK: - The benchmark

    func testBuiltInDetectorLatencyAndOutputs() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "ir_gun_display", withExtension: "png")
                ?? bundle.url(forResource: "ir_gun_display", withExtension: "png",
                              subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            throw XCTSkip("ir_gun_display.png fixture not present in the test bundle")
        }

        Self.printEnvironment()
        print("FIXTURE native size: \(Int(image.size.width))x\(Int(image.size.height))")

        // Three frames: the fixture at native size, and the fixture composited
        // into the two buffer sizes the camera pipeline actually produces.
        // "Composited" = scaled to fit, centred on mid-grey — a stand-in for a
        // scene, NOT a real scene. Detector OUTPUT on these is therefore only
        // indicative; the LATENCY is the point (it is set by buffer size).
        var frames: [Frame] = []
        if let native = Self.pixelBuffer(from: image, canvas: image.size, fit: false) {
            frames.append(Frame(name: "fixture-native",
                                buffer: native,
                                pixels: Int(image.size.width * image.size.height)))
        }
        for canvas in [CGSize(width: 1080, height: 1920), CGSize(width: 1920, height: 1080)] {
            if let buffer = Self.pixelBuffer(from: image, canvas: canvas, fit: true) {
                frames.append(Frame(name: "composited-\(Int(canvas.width))x\(Int(canvas.height))",
                                    buffer: buffer,
                                    pixels: Int(canvas.width * canvas.height)))
            }
        }
        XCTAssertFalse(frames.isEmpty, "no pixel buffer could be built")

        // Each entry: label, factory (fresh request per call — matches how the
        // app builds them), and a describer that reports what came back.
        let cases: [(String, () -> VNImageBasedRequest, (VNRequest) -> String)] = [
            ("VNDetectRectanglesRequest(default)", {
                VNDetectRectanglesRequest()
            }, { req in
                let r = (req.results as? [VNRectangleObservation]) ?? []
                return "rects=\(r.count) topConf=\(Self.fmt(r.first?.confidence))"
            }),

            ("VNDetectRectanglesRequest(app-tuned)", {
                let r = VNDetectRectanglesRequest()
                // Mirrors ScreenCandidateDetector's shipping intent: a display
                // panel, permissive aspect, several observations.
                r.minimumAspectRatio = 0.3
                r.maximumAspectRatio = 1.0
                r.minimumSize = 0.1
                r.maximumObservations = 8
                r.minimumConfidence = 0.5
                r.quadratureTolerance = 30
                return r
            }, { req in
                let r = (req.results as? [VNRectangleObservation]) ?? []
                return "rects=\(r.count) topConf=\(Self.fmt(r.first?.confidence))"
            }),

            ("VNGenerateObjectnessBasedSaliencyImageRequest", {
                VNGenerateObjectnessBasedSaliencyImageRequest()
            }, { req in
                let obs = (req.results as? [VNSaliencyImageObservation]) ?? []
                let objects = obs.first?.salientObjects ?? []
                let boxes = objects.prefix(4).map { Self.box($0.boundingBox) }.joined(separator: " ")
                var heat = "heatmap=?"
                if let pb = obs.first?.pixelBuffer {
                    heat = "heatmap=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                }
                return "salientObjects=\(objects.count) \(heat) boxes[\(boxes)]"
            }),

            ("VNGenerateAttentionBasedSaliencyImageRequest", {
                VNGenerateAttentionBasedSaliencyImageRequest()
            }, { req in
                let obs = (req.results as? [VNSaliencyImageObservation]) ?? []
                let objects = obs.first?.salientObjects ?? []
                let boxes = objects.prefix(4).map { Self.box($0.boundingBox) }.joined(separator: " ")
                var heat = "heatmap=?"
                if let pb = obs.first?.pixelBuffer {
                    heat = "heatmap=\(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))"
                }
                return "salientObjects=\(objects.count) \(heat) boxes[\(boxes)]"
            }),

            ("VNRecognizeAnimalsRequest", {
                VNRecognizeAnimalsRequest()
            }, { req in
                let r = (req.results as? [VNRecognizedObjectObservation]) ?? []
                return "objects=\(r.count) top=\(r.first?.labels.first?.identifier ?? "-")"
            }),

            ("VNDetectContoursRequest", {
                VNDetectContoursRequest()
            }, { req in
                let r = (req.results as? [VNContoursObservation]) ?? []
                return "contourObs=\(r.count) contours=\(r.first?.contourCount ?? 0)"
            }),

            // Reference points: what the app ALREADY pays per frame.
            ("VNRecognizeTextRequest(.fast)", {
                let r = VNRecognizeTextRequest()
                r.recognitionLevel = .fast
                r.usesLanguageCorrection = false
                r.automaticallyDetectsLanguage = false
                r.recognitionLanguages = ["en-US"]
                return r
            }, { req in
                let r = (req.results as? [VNRecognizedTextObservation]) ?? []
                return "textRuns=\(r.count) top=\(r.first?.topCandidates(1).first?.string ?? "-")"
            }),

            ("VNRecognizeTextRequest(.accurate)", {
                let r = VNRecognizeTextRequest()
                r.recognitionLevel = .accurate
                r.usesLanguageCorrection = false
                r.automaticallyDetectsLanguage = false
                r.recognitionLanguages = ["en-US"]
                return r
            }, { req in
                let r = (req.results as? [VNRecognizedTextObservation]) ?? []
                return "textRuns=\(r.count) top=\(r.first?.topCandidates(1).first?.string ?? "-")"
            })
        ]

        print("")
        print("| request | frame | median ms | min ms | max ms | first-call ms | output on fixture |")
        print("|---|---|---:|---:|---:|---:|---|")

        for (label, make, describe) in cases {
            for frame in frames {
                var samples: [Double] = []
                var firstCallMS: Double = .nan
                var description = "(no run)"
                var failure: String?

                for i in 0..<(Self.warmups + Self.iterations) {
                    let request = make()
                    let handler = VNImageRequestHandler(cvPixelBuffer: frame.buffer, options: [:])
                    let start = DispatchTime.now().uptimeNanoseconds
                    do {
                        try handler.perform([request])
                    } catch {
                        failure = "\(error)"
                        break
                    }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if i == 0 { firstCallMS = ms }
                    if i >= Self.warmups { samples.append(ms) }
                    description = describe(request)
                }

                if let failure {
                    print("| \(label) | \(frame.name) | THREW | — | — | — | \(failure) |")
                    continue
                }
                guard !samples.isEmpty else { continue }
                let sorted = samples.sorted()
                let median = sorted[sorted.count / 2]
                XCTAssertGreaterThan(median, 0, "\(label) produced an unmeasurable time")
                print("| \(label) | \(frame.name) | \(Self.ms(median)) | \(Self.ms(sorted.first!)) | \(Self.ms(sorted.last!)) | \(Self.ms(firstCallMS)) | \(description) |")
            }
        }

        print("")
        print("THERMAL at end: \(Self.thermalStateName())")
    }

    /// Does the input buffer size actually buy anything? The cheapest possible
    /// "where is it" pass would run on a downscaled frame, so measure the
    /// latency/size curve rather than assuming it.
    func testResolutionScalingOfCheapestDetectors() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "ir_gun_display", withExtension: "png")
                ?? bundle.url(forResource: "ir_gun_display", withExtension: "png",
                              subdirectory: "Fixtures"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data) else {
            throw XCTSkip("ir_gun_display.png fixture not present in the test bundle")
        }
        Self.printEnvironment()

        let sizes = [CGSize(width: 192, height: 256),
                     CGSize(width: 320, height: 568),
                     CGSize(width: 480, height: 854),
                     CGSize(width: 720, height: 1280),
                     CGSize(width: 1080, height: 1920)]

        print("")
        print("| request | canvas | median ms | min ms | max ms | output |")
        print("|---|---|---:|---:|---:|---|")

        for canvas in sizes {
            guard let buffer = Self.pixelBuffer(from: image, canvas: canvas, fit: true) else { continue }
            let makers: [(String, () -> VNImageBasedRequest, (VNRequest) -> String)] = [
                ("objectness-saliency", { VNGenerateObjectnessBasedSaliencyImageRequest() }, { req in
                    let obs = (req.results as? [VNSaliencyImageObservation]) ?? []
                    let objects = obs.first?.salientObjects ?? []
                    return "salientObjects=\(objects.count) top=\(objects.first.map { Self.box($0.boundingBox) } ?? "-")"
                }),
                ("attention-saliency", { VNGenerateAttentionBasedSaliencyImageRequest() }, { req in
                    let obs = (req.results as? [VNSaliencyImageObservation]) ?? []
                    let objects = obs.first?.salientObjects ?? []
                    return "salientObjects=\(objects.count) top=\(objects.first.map { Self.box($0.boundingBox) } ?? "-")"
                }),
                ("rectangles-default", { VNDetectRectanglesRequest() }, { req in
                    let r = (req.results as? [VNRectangleObservation]) ?? []
                    return "rects=\(r.count) top=\(r.first.map { Self.box($0.boundingBox) } ?? "-")"
                })
            ]
            for (label, make, describe) in makers {
                var samples: [Double] = []
                var description = "(no run)"
                for i in 0..<(Self.warmups + Self.iterations) {
                    let request = make()
                    let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
                    let start = DispatchTime.now().uptimeNanoseconds
                    do { try handler.perform([request]) } catch {
                        description = "THREW \(error)"; break
                    }
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    if i >= Self.warmups { samples.append(ms) }
                    description = describe(request)
                }
                guard !samples.isEmpty else {
                    print("| \(label) | \(Int(canvas.width))x\(Int(canvas.height)) | — | — | — | \(description) |")
                    continue
                }
                let sorted = samples.sorted()
                print("| \(label) | \(Int(canvas.width))x\(Int(canvas.height)) | \(Self.ms(sorted[sorted.count / 2])) | \(Self.ms(sorted.first!)) | \(Self.ms(sorted.last!)) | \(description) |")
            }
        }
        print("THERMAL at end: \(Self.thermalStateName())")
    }

    /// What VNRecognizeAnimalsRequest can actually name. If the list is only
    /// cats and dogs it is useless for instrument detection, and that is worth
    /// establishing from the framework itself rather than from documentation.
    func testAnimalRequestSupportedIdentifiers() throws {
        let request = VNRecognizeAnimalsRequest()
        let identifiers = try request.supportedIdentifiers()
        print("VNRecognizeAnimalsRequest.supportedIdentifiers() = \(identifiers.map(\.rawValue))")
        for revision in [VNRecognizeAnimalsRequestRevision1, VNRecognizeAnimalsRequestRevision2] {
            let known = try? VNRecognizeAnimalsRequest.knownAnimalIdentifiers(forRevision: revision)
            print("  revision \(revision): \((known ?? []).map(\.rawValue))")
        }
        XCTAssertFalse(identifiers.isEmpty)
    }

    // MARK: - Helpers

    private static func printEnvironment() {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        #if targetEnvironment(simulator)
        let host = "SIMULATOR (this measures the Mac, NOT an iPhone)"
        #else
        let host = "PHYSICAL DEVICE"
        #endif
        print("=== VISION BUILT-IN DETECTOR BENCHMARK ===")
        print("HOST: \(host)")
        print("uname machine: \(machine)")
        print("device: \(UIDevice.current.model) — \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        print("activeProcessorCount: \(ProcessInfo.processInfo.activeProcessorCount)")
        print("thermal at start: \(thermalStateName())")
        print("iterations=\(iterations) warmups=\(warmups)")
    }

    private static func thermalStateName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func ms(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func fmt(_ value: Float?) -> String {
        guard let value else { return "-" }
        return String(format: "%.2f", value)
    }

    private static func box(_ rect: CGRect) -> String {
        String(format: "(%.2f,%.2f,%.2f,%.2f)",
               rect.origin.x, rect.origin.y, rect.width, rect.height)
    }

    /// Renders `image` into a BGRA pixel buffer of `canvas` size. When `fit`
    /// is true the image is aspect-fit and centred on mid-grey.
    private static func pixelBuffer(from image: UIImage, canvas: CGSize, fit: Bool) -> CVPixelBuffer? {
        let width = Int(canvas.width)
        let height = Int(canvas.height)
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue),
              let cgImage = image.cgImage else { return nil }

        context.setFillColor(UIColor(white: 0.45, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var target = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        if fit {
            let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            target = CGRect(x: (canvas.width - size.width) / 2,
                            y: (canvas.height - size.height) / 2,
                            width: size.width, height: size.height)
        }
        context.draw(cgImage, in: target)
        return pixelBuffer
    }
}
