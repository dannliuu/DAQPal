//
//  DisplayPose3D.swift
//  DAQPal
//
//  True 3-D pose ground truth for the synthetic display rig — the perspective
//  upgrade of the affine `DisplayPose`. Where `DisplayPose` approximates tilt
//  as cos-foreshortening scale factors (no keystone ever), `DisplayPose3D`
//  rotates the physical panel rectangle in camera space and pinhole-projects
//  it, so yaw/pitch produce genuine trapezoids — the geometry homography
//  prototyping actually needs. Strictly additive: nothing here touches the
//  existing affine render path.
//
//  Axis / sign conventions (relied on by `projectedQuad` and every test):
//  - Camera space: x right, y DOWN, z forward into the scene — the 3-D
//    extension of the project-wide normalized top-left-origin image space.
//  - "Metric" image units: fractions of frame HEIGHT. Normalized x is
//    converted via `frameAspect` (= width / height), so a physical square
//    projects to a metric square and rotations are angle-true.
//  - `yaw`: rotation about the panel's vertical axis. POSITIVE yaw turns the
//    panel's RIGHT edge away from the camera, so the LEFT (nearer) edge
//    renders taller. Matrix used: x' = x·cos − z·sin, z' = x·sin + z·cos.
//  - `pitch`: rotation about the panel's horizontal axis. POSITIVE pitch tips
//    the panel's TOP edge away from the camera (monitor leaning back).
//    Matrix used: y' = y·cos + z·sin, z' = −y·sin + z·cos.
//  - `roll`: in-plane rotation about the panel normal, positive = clockwise
//    on screen in y-down space — the same sign convention as
//    `DisplayPose.roll` and `ScreenQuad.rollAngle`.
//  - Composition: R = Rz(roll) · Ry(yaw) · Rx(pitch) — pitch applied first,
//    then yaw, then roll.
//  - `distance`: depth of the panel center along +z, metric units. At
//    `distance == focalLength` the projection scale is exactly 1, which is
//    why `.identity` reproduces the affine identity panel rect EXACTLY.
//    Larger distance = smaller panel.
//  - `focalLength`: pinhole focal length in frame-height units. The default
//    1.4 gives a vertical FOV of 2·atan(0.5/1.4) ≈ 39°, in the ballpark of a
//    phone main camera in portrait.
//  - `center`: the normalized (top-left-origin) image point where the panel
//    CENTER projects, at any distance — the panel center ray is aimed at
//    `center`, then rotation happens about the panel center, so the center's
//    projection is pose-rotation-invariant.
//
//  Semantic corners: `projectedQuad` labels corners by which physical corner
//  of the panel they are (`topLeft` = the panel's physical top-left), matching
//  `ScreenQuad`'s semantic-corner contract. Within the documented envelope
//  (|yaw|, |pitch| ≤ 60°, |roll| ≤ 45°, distance comfortably above the panel
//  half-diagonal) every corner stays strictly in front of the camera, the
//  projection is convex, and corner identity is preserved by construction.
//

import CoreGraphics
import Foundation

/// A true 3-D pose of the synthetic display panel: rotation (yaw/pitch/roll),
/// normalized image position of the panel center, depth, and pinhole focal
/// length. See the file header for the full axis/sign conventions.
struct DisplayPose3D: Equatable, Sendable {
    /// Rotation about the panel's vertical axis, radians. Positive = right
    /// edge recedes from the camera.
    var yaw: CGFloat = 0
    /// Rotation about the panel's horizontal axis, radians. Positive = top
    /// edge recedes from the camera.
    var pitch: CGFloat = 0
    /// In-plane rotation, radians, positive = clockwise on screen (y-down).
    var roll: CGFloat = 0
    /// Normalized top-left-origin image point where the panel center projects.
    var center: CGPoint = DisplayPose3D.homeCenter
    /// Panel-center depth in frame-height units. `defaultFocalLength` (the
    /// default) = projection scale exactly 1.
    var distance: CGFloat = DisplayPose3D.defaultFocalLength
    /// Pinhole focal length in frame-height units.
    var focalLength: CGFloat = DisplayPose3D.defaultFocalLength

    /// ≈ 39° vertical FOV — see file header.
    static let defaultFocalLength: CGFloat = 1.4

    /// The static panel's home position — derived from the renderer's
    /// `displayROI` (via `DemoMotionModel`), never duplicated.
    static var homeCenter: CGPoint { DemoMotionModel.homeCenter }

    /// The un-moved pose. Projecting it with the renderer's panel size and
    /// frame aspect yields EXACTLY the affine identity panel rect.
    static let identity = DisplayPose3D()

    /// Projects the panel's four corners into normalized top-left-origin
    /// image space: local corners → R = Rz(roll)·Ry(yaw)·Rx(pitch) →
    /// translate to (center ray · distance) → pinhole divide.
    ///
    /// - Parameters:
    ///   - panelSize: normalized (width, height) of the panel at identity —
    ///     e.g. `SyntheticDisplayRenderer.displayROI`'s size.
    ///   - frameAspect: frame width / height (0.5625 for 1080×1920).
    /// - Returns: the projected `ScreenQuad` with SEMANTIC corner labels
    ///   (`topLeft` = the panel's physical top-left under every pose).
    func projectedQuad(panelSize: CGSize, frameAspect: CGFloat) -> ScreenQuad {
        // Panel half-extents in metric (frame-height) units.
        let hw = panelSize.width * frameAspect / 2
        let hh = panelSize.height / 2
        // Local corners, y-down, panel plane z = 0. Order: TL, TR, BR, BL —
        // ScreenQuad's winding order.
        let local: [(x: CGFloat, y: CGFloat)] = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)]

        let cy = cos(yaw), sy = sin(yaw)
        let cp = cos(pitch), sp = sin(pitch)
        let cr = cos(roll), sr = sin(roll)
        let d = max(distance, 1e-6)
        let f = max(focalLength, 1e-6)
        // Translation aims the panel-center ray at `center` for ANY depth:
        // u = f·tx/d must equal the metric center offset.
        let tx = (center.x - 0.5) * frameAspect * d / f
        let ty = (center.y - 0.5) * d / f

        var projected = [CGPoint]()
        projected.reserveCapacity(4)
        for corner in local {
            // Rx(pitch): positive pitch sends the top edge (y < 0) to z > 0.
            let y1 = corner.y * cp // + z·sp, z = 0 on the panel plane
            let z1 = -corner.y * sp
            // Ry(yaw): positive yaw sends the right edge (x > 0) to z > 0.
            let x2 = corner.x * cy - z1 * sy
            let z2 = corner.x * sy + z1 * cy
            // Rz(roll): positive = clockwise in y-down space.
            let x3 = x2 * cr - y1 * sr
            let y3 = x2 * sr + y1 * cr

            let worldX = x3 + tx
            let worldY = y3 + ty
            // Clamped away from the camera plane so out-of-envelope poses
            // yield finite garbage rather than NaN/Inf; inside the documented
            // envelope z is always comfortably positive.
            let worldZ = max(z2 + d, 1e-3)

            let u = f * worldX / worldZ
            let v = f * worldY / worldZ
            projected.append(CGPoint(x: 0.5 + u / frameAspect, y: 0.5 + v))
        }
        return ScreenQuad(topLeft: projected[0], topRight: projected[1],
                          bottomRight: projected[2], bottomLeft: projected[3])
    }
}
