import CoreGraphics
import CoreMedia
import simd

/// One tracked face for one frame. Value type, Sendable.
///
/// Conventions (see docs/tracking.md):
/// - 2D quantities are in pixels of the CAPTURED frame (source; may not be 1280x720, see `FrameMapping`), origin TOP-left, y down.
/// - `headTransform` is in metric camera space: meters, right-handed,
///   +x right, +y up, camera looks down -z (so a face in front of the camera has z < 0).
///   Identity rotation = head facing the camera. Origin = midpoint between the eyes.
/// - "left"/"right" follow Vision's `leftEye`/`rightEye` regions (see QUESTIONS.md Q2).
struct FacePose: Sendable {
    /// Face bounding box in pixels, top-left origin.
    var faceRect: CGRect
    /// Radians. Euler angles, intrinsic yaw -> pitch -> roll (R = Ry * Rx * Rz).
    var roll: Float
    var yaw: Float
    var pitch: Float
    /// Smoothed head pose in metric camera space.
    var headTransform: simd_float4x4
    /// 0 = closed, 1 = fully open (calibrated per user, smoothed).
    var leftOpenness: Float
    var rightOpenness: Float
    /// Eye centers in pixels (midpoint of eye corners).
    var leftEyeCenter: SIMD2<Float>
    var rightEyeCenter: SIMD2<Float>
    /// Outer lip contour in pixels, top-left origin.
    var outerLips: [SIMD2<Float>]
    /// 0 = lips closed, 1 = widest this user opened their mouth (inner-lip gap / mouth width, calibrated, smoothed).
    var mouthOpenness: Float = 0
    /// -1 = corners pulled down (frown) ... +1 = corners pulled up (broad smile); 0 = neutral. Smoothed.
    var smile: Float = 0
    /// All 76 landmark points in pixels. Empty unless `FaceTrackerConfiguration.includeAllLandmarks`.
    var allLandmarks: [SIMD2<Float>]
    /// 0...1, min(face detection, landmark) confidence.
    var confidence: Float
    var timestamp: CMTime
}

/// Pure geometry used to build `FacePose.headTransform`. Separated for unit testing.
enum HeadPoseGeometry {
    static let defaultHorizontalFOV: Float = 60 * .pi / 180
    static let defaultInterPupillaryDistance: Float = 0.063  // meters

    /// Pinhole focal length in pixels: f = (W/2) / tan(hfov/2).
    static func focalLengthPixels(imageWidth: Float, horizontalFOV: Float = defaultHorizontalFOV) -> Float {
        (imageWidth / 2) / tan(horizontalFOV / 2)
    }

    /// Distance along the optical axis (meters) to the eye midpoint.
    /// Projected IPD shrinks by cos(yaw) when the head turns, so we divide it back out
    /// (clamped to avoid blow-up at extreme yaw).
    static func depth(interPupillaryPixels: Float,
                      yaw: Float,
                      focalLengthPixels f: Float,
                      interPupillaryDistance ipd: Float = defaultInterPupillaryDistance) -> Float {
        let c = max(0.5, cos(yaw))
        let ipdFrontal = max(1, interPupillaryPixels) / c
        return f * ipd / ipdFrontal
    }

    /// Back-projects a top-left-origin pixel at `depth` meters to camera space (+y up, -z forward).
    static func cameraSpacePosition(pixel: SIMD2<Float>, depth: Float, focalLengthPixels f: Float,
                                    imageSize: SIMD2<Float>) -> SIMD3<Float> {
        let cx = imageSize.x / 2, cy = imageSize.y / 2
        return SIMD3((pixel.x - cx) * depth / f,
                     -(pixel.y - cy) * depth / f,
                     -depth)
    }

    /// Intrinsic yaw (about +y) -> pitch (about +x) -> roll (about +z).
    static func rotation(roll: Float, yaw: Float, pitch: Float) -> simd_quatf {
        let qy = simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0))
        let qx = simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0))
        let qz = simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
        return simd_normalize(qy * qx * qz)
    }

    static func transform(position: SIMD3<Float>, roll: Float, yaw: Float, pitch: Float) -> simd_float4x4 {
        var m = simd_matrix4x4(rotation(roll: roll, yaw: yaw, pitch: pitch))
        m.columns.3 = SIMD4(position, 1)
        return m
    }
}
