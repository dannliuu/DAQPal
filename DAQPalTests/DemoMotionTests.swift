//
//  DemoMotionTests.swift
//  DAQPalTests
//
//  Coverage for the synthetic-display motion rig (`DemoMotion`,
//  `DisplayPose`, `DemoMotionModel`) and the geometry it drives in
//  `SyntheticDisplayRenderer`/`AppState` ROI tracking.
//
//  All tests are deterministic (synthetic `t = Double(i)/fps`, no `Date()` or
//  randomness) and pure-geometry — no OCR/Vision calls — so they stay fast
//  and reproducible.
//

import CoreGraphics
import CoreVideo
import XCTest
@testable import DAQPal

final class DemoMotionTests: XCTestCase {

    private let fps: Double = 12
    private var dt: TimeInterval { 1.0 / fps }

    // MARK: - DemoMotion.next

    func testDemoMotion_next_cyclesThroughAllCasesAndWraps() {
        var visited: [DemoMotion] = []
        var current = DemoMotion.steady
        for _ in 0..<DemoMotion.allCases.count {
            visited.append(current)
            current = current.next
        }
        XCTAssertEqual(current, .steady, "after allCases.count .next steps, the cycle must wrap back to .steady")
        XCTAssertEqual(Set(visited), Set(DemoMotion.allCases), "every case must be visited")
        XCTAssertEqual(visited.count, DemoMotion.allCases.count, "each case must be visited exactly once")
    }

    // MARK: - Steady

    func testMotionModel_steady_staysAtIdentityPose() {
        var model = DemoMotionModel()
        model.mode = .steady
        for i in 0..<Int(5 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            XCTAssertEqual(pose, DisplayPose.identity, "frame \(i) at t=\(t)")
        }
    }

    // MARK: - Bounce

    func testMotionModel_bounce_staysInsideBounds() {
        var model = DemoMotionModel()
        model.mode = .bounce
        let minX = DemoMotionModel.bounceInsetX - 1e-9
        let maxX = 1 - DemoMotionModel.bounceInsetX + 1e-9
        let minY = DemoMotionModel.bounceInsetY - 1e-9
        let maxY = 1 - DemoMotionModel.bounceInsetY + 1e-9
        for i in 0..<Int(120 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            XCTAssertGreaterThanOrEqual(pose.center.x, minX, "frame \(i) x below bounds")
            XCTAssertLessThanOrEqual(pose.center.x, maxX, "frame \(i) x above bounds")
            XCTAssertGreaterThanOrEqual(pose.center.y, minY, "frame \(i) y below bounds")
            XCTAssertLessThanOrEqual(pose.center.y, maxY, "frame \(i) y above bounds")
            XCTAssertEqual(pose.roll, 0, "frame \(i) roll")
            XCTAssertEqual(pose.yawScale, 1, "frame \(i) yawScale")
            XCTAssertEqual(pose.pitchScale, 1, "frame \(i) pitchScale")
        }
    }

    func testMotionModel_bounce_reflectsOffBothAxes() {
        var model = DemoMotionModel()
        model.mode = .bounce
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for i in 0..<Int(120 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            minX = min(minX, pose.center.x); maxX = max(maxX, pose.center.x)
            minY = min(minY, pose.center.y); maxY = max(maxY, pose.center.y)
        }
        let wallMinX = DemoMotionModel.bounceInsetX
        let wallMaxX = 1 - DemoMotionModel.bounceInsetX
        let wallMinY = DemoMotionModel.bounceInsetY
        let wallMaxY = 1 - DemoMotionModel.bounceInsetY
        // Reaching (within tolerance) both walls on both axes proves the
        // panel actually reflects rather than sticking to one side.
        XCTAssertEqual(minX, wallMinX, accuracy: 0.02, "should reach the left wall")
        XCTAssertEqual(maxX, wallMaxX, accuracy: 0.02, "should reach the right wall")
        XCTAssertEqual(minY, wallMinY, accuracy: 0.02, "should reach the top wall")
        XCTAssertEqual(maxY, wallMaxY, accuracy: 0.02, "should reach the bottom wall")
    }

    func testMotionModel_bounceThenSteady_glidesHome() {
        var model = DemoMotionModel()
        model.mode = .bounce
        var t = 0.0
        for i in 0..<Int(10 * fps) {
            t = Double(i) * dt
            _ = model.pose(at: t, dt: dt)
        }

        model.mode = .steady
        var previousCenter: CGPoint?
        var finalPose = DisplayPose.identity
        for i in 0..<Int(5 * fps) {
            t += dt
            let pose = model.pose(at: t, dt: dt)
            if let previous = previousCenter {
                let stepDx = pose.center.x - previous.x
                let stepDy = pose.center.y - previous.y
                let stepDistance = (stepDx * stepDx + stepDy * stepDy).squareRoot()
                XCTAssertLessThanOrEqual(stepDistance, DemoMotionModel.homingSpeed * CGFloat(dt) + 1e-6,
                                         "frame \(i) moved more than the homing speed allows in one step (teleport)")
            }
            previousCenter = pose.center
            finalPose = pose
        }

        XCTAssertEqual(finalPose.center.x, DemoMotionModel.homeCenter.x, accuracy: 1e-6)
        XCTAssertEqual(finalPose.center.y, DemoMotionModel.homeCenter.y, accuracy: 1e-6)
    }

    // MARK: - Roll / yaw bounds

    func testMotionModel_roll_boundedByMaxRollAngle() {
        var model = DemoMotionModel()
        model.mode = .roll
        var distinctRolls: Set<CGFloat> = []
        for i in 0..<Int(20 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            XCTAssertLessThanOrEqual(abs(pose.roll), DemoMotionModel.maxRollAngle + 1e-9, "frame \(i)")
            XCTAssertEqual(pose.yawScale, 1, "frame \(i) yawScale should be untouched by .roll")
            XCTAssertEqual(pose.pitchScale, 1, "frame \(i) pitchScale should be untouched by .roll")
            distinctRolls.insert(pose.roll)
        }
        XCTAssertGreaterThanOrEqual(distinctRolls.count, 2, "roll should actually oscillate, not sit constant")
    }

    func testMotionModel_yaw_scaleBounded() {
        var model = DemoMotionModel()
        model.mode = .yaw
        var distinctScales: Set<CGFloat> = []
        for i in 0..<Int(20 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            XCTAssertGreaterThanOrEqual(pose.yawScale, 0.15 - 1e-9, "frame \(i)")
            XCTAssertLessThanOrEqual(pose.yawScale, 1 + 1e-9, "frame \(i)")
            XCTAssertEqual(pose.roll, 0, "frame \(i) roll should be untouched by .yaw")
            distinctScales.insert(pose.yawScale)
        }
        XCTAssertGreaterThanOrEqual(distinctScales.count, 2, "yawScale should actually oscillate, not sit constant")
    }

    // MARK: - Determinism

    func testMotionModel_isDeterministic() {
        var modelA = DemoMotionModel()
        var modelB = DemoMotionModel()
        modelA.mode = .tumble
        modelB.mode = .tumble
        for i in 0..<Int(20 * fps) {
            let t = Double(i) * dt
            let poseA = modelA.pose(at: t, dt: dt)
            let poseB = modelB.pose(at: t, dt: dt)
            XCTAssertEqual(poseA, poseB, "frame \(i) diverged between two identically-stepped models")
        }
    }

    // MARK: - Renderer geometry

    func testRenderer_panelROI_identityEqualsDisplayROI() {
        let renderer = SyntheticDisplayRenderer()
        XCTAssertEqual(renderer.panelROI(for: .identity), SyntheticDisplayRenderer.displayROI)
    }

    func testRenderer_panelROI_rolledPoseGrowsBoundsAndTracksCenter() {
        let renderer = SyntheticDisplayRenderer()
        // Center offset from home but safely inside the frame — chosen so the
        // rotated axis-aligned bounds (computed below) stay unclamped.
        let center = CGPoint(x: 0.4, y: 0.6)
        let pose = DisplayPose(center: center, roll: DemoMotionModel.maxRollAngle,
                               yawScale: 1, pitchScale: 1)
        let roi = renderer.panelROI(for: pose)

        XCTAssertGreaterThan(roi.height, SyntheticDisplayRenderer.displayROI.height,
                             "rotating the panel should grow its axis-aligned bounding height")

        // Sanity: this case must exercise the unclamped path, or the center
        // round-trip below wouldn't hold.
        XCTAssertGreaterThanOrEqual(roi.x, 0)
        XCTAssertGreaterThanOrEqual(roi.y, 0)
        XCTAssertLessThanOrEqual(roi.x + roi.width, 1.0)
        XCTAssertLessThanOrEqual(roi.y + roi.height, 1.0)

        XCTAssertEqual(roi.x + roi.width / 2, center.x, accuracy: 1e-6)
        XCTAssertEqual(roi.y + roi.height / 2, center.y, accuracy: 1e-6)
    }

    func testRenderer_render_withPose_producesDifferentPixelsThanIdentity() throws {
        let renderer = SyntheticDisplayRenderer()
        guard let identityBuffer = renderer.render(text: "12.345", pose: .identity) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }
        // Far from home but still inside the bounce bounds, so the panel
        // fully vacates the identity-panel-center region.
        let farPose = DisplayPose(center: CGPoint(x: DemoMotionModel.bounceInsetX, y: DemoMotionModel.bounceInsetY),
                                  roll: 0, yawScale: 1, pitchScale: 1)
        guard let movedBuffer = renderer.render(text: "12.345", pose: farPose) else {
            throw XCTSkip("SyntheticDisplayRenderer could not allocate a pixel buffer in this environment")
        }

        let panelRect = SyntheticDisplayRenderer.displayROI.pixelRect(in: renderer.size)
        let sampleRect = CGRect(x: panelRect.midX - 10, y: panelRect.midY - 10, width: 20, height: 20)

        let identitySample = samplePixels(identityBuffer, rect: sampleRect)
        let movedSample = samplePixels(movedBuffer, rect: sampleRect)
        XCTAssertFalse(identitySample.isEmpty)
        XCTAssertEqual(identitySample.count, movedSample.count)
        XCTAssertNotEqual(identitySample, movedSample,
                          "moving the panel away from home should change pixels at its old (identity) location")
    }

    /// Snapshots a small pixel-aligned region of a locked 32BGRA buffer as raw
    /// bytes, for direct byte comparison (mirrors the pattern in
    /// `SyntheticDisplayGeneratorTests`).
    private func samplePixels(_ buffer: CVPixelBuffer, rect: CGRect) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return [] }
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        let minX = Int(rect.minX), minY = Int(rect.minY)
        let width = Int(rect.width), height = Int(rect.height)
        for y in minY..<(minY + height) {
            let row = ptr + y * bytesPerRow
            for x in minX..<(minX + width) {
                let p = row + x * 4
                bytes.append(contentsOf: [p[0], p[1], p[2], p[3]])
            }
        }
        return bytes
    }

    // MARK: - AppState ROI tracking

    /// Pure-logic tracking test: no OCR, no rendering — feeds hand-built
    /// `FrameResult`s whose `observedROIs` come from `panelROI(for:)` ground
    /// truth for a bouncing pose, and checks the tracked device window keeps
    /// up.
    @MainActor
    func testAppState_roiTracking_followsBouncingPanel() {
        let device = Device.makeDefault(index: 1)
        let appState = AppState(devices: [device])
        var configured = device
        configured.roi = SyntheticDisplayRenderer.displayROI
        appState.updateDevice(configured)

        XCTAssertTrue(appState.roiTrackingEnabled)
        XCTAssertFalse(appState.isEditingROI)

        let renderer = SyntheticDisplayRenderer()
        var model = DemoMotionModel()
        model.mode = .bounce

        let initialROI = SyntheticDisplayRenderer.displayROI
        let initialCenter = CGPoint(x: initialROI.x + initialROI.width / 2,
                                    y: initialROI.y + initialROI.height / 2)
        var finalTruthCenter = initialCenter

        for i in 0..<Int(30 * fps) {
            let t = Double(i) * dt
            let pose = model.pose(at: t, dt: dt)
            let truth = renderer.panelROI(for: pose)
            finalTruthCenter = CGPoint(x: truth.x + truth.width / 2, y: truth.y + truth.height / 2)

            let measurement = DAQPal.Measurement(timestamp: t, value: 12.345, unit: nil,
                                                 confidence: 0.9, accepted: true)
            let result = FrameResult(timestamp: t,
                                     readings: [device.id: measurement],
                                     debugText: nil,
                                     observedROIs: [device.id: truth])
            appState.apply(result)
        }

        guard let finalDevice = appState.device(withID: device.id), let finalROI = finalDevice.roi else {
            return XCTFail("tracked device should retain a confirmed ROI")
        }
        let finalCenter = CGPoint(x: finalROI.x + finalROI.width / 2, y: finalROI.y + finalROI.height / 2)

        let errDx = finalCenter.x - finalTruthCenter.x
        let errDy = finalCenter.y - finalTruthCenter.y
        let error = (errDx * errDx + errDy * errDy).squareRoot()
        XCTAssertLessThanOrEqual(error, 0.06, "tracker should keep up with the bouncing panel")

        let movedDx = finalCenter.x - initialCenter.x
        let movedDy = finalCenter.y - initialCenter.y
        let moved = (movedDx * movedDx + movedDy * movedDy).squareRoot()
        XCTAssertGreaterThan(moved, 0.01, "tracker window should have moved from its initial position")
    }
}
