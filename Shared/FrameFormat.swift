import CoreVideo
import Foundation
import os

/// Frame format shared by the app and the camera extension. Never change one side only.
enum FrameFormat {
    static let width: Int32 = 1280
    static let height: Int32 = 720
    static let fps: Int32 = 30
    static let pixelFormat: OSType = kCVPixelFormatType_32BGRA
    static let bytesPerPixel = 4
    /// Logo blue #009CE4 as little-endian BGRA UInt32 (B=E4 G=9C R=00 A=FF).
    static let logoBlueBGRA: UInt32 = 0xFF00_9CE4
}

enum Identity {
    static let logSubsystem = "com.lawmatics.lmmask"
    static let appBundleID = "com.lawmatics.lmmask"
    static let extensionBundleID = "com.lawmatics.lmmask.camera"
    /// Logical app group name. The entitlement/mach-service value carries the Team ID prefix
    /// ("<TeamID>.group.com.lawmatics.lmmask"); see docs/entitlements.md.
    static let appGroup = "group.com.lawmatics.lmmask"

    static let deviceName = "LM Halloween Cam"
    static let manufacturer = "Lawmatics"
    /// Fixed UUIDs so the device is stable across launches (apps remember the selected camera).
    static let deviceID = UUID(uuidString: "C328CBF0-C961-48B1-A0C4-8BADD9F2A5E4")!
    static let streamID = UUID(uuidString: "F84B0C18-80EE-43FB-BF6D-3FC2ADA37BC7")!
    /// Sink stream (host app writes frames here). Fixed so the host can be sure which stream it opened.
    static let sinkStreamID = UUID(uuidString: "5B1D7A52-3C0E-4F7E-9A3B-0E6C2D8F41A9")!
    /// CMIO device UID (kCMIODevicePropertyDeviceUID) the host searches for. For a CMIOExtension device
    /// this is the `deviceID` UUID string. See docs in LMMask/Camera/FrameSink.swift and QUESTIONS.md A2.1.
    static let deviceUID = deviceID.uuidString
}

extension Logger {
    static func lm(_ category: String) -> Logger {
        Logger(subsystem: Identity.logSubsystem, category: category)
    }
}

/// Maps pixels of the captured camera frame ("source") into pixels of the fixed 1280x720 output frame.
///
/// The output is never stretched: when the source aspect differs from the output aspect the source is
/// scaled uniformly until it covers the output (aspect-FILL) and the overflow is cropped, centred.
/// Everything that works in pixels (compositor UVs, mouth cut-out size/crop, mask placement, debug overlay)
/// goes through this one struct. Vision results are in SOURCE pixels (top-left origin, see docs/tracking.md);
/// the SceneKit mask and the mouth patch live in OUTPUT pixels (also top-left origin).
struct FrameMapping: Sendable, Equatable {
    var sourceSize: SIMD2<Float>
    var outputSize: SIMD2<Float>
    /// Uniform scale, source px -> output px (= max of the two axis ratios).
    var scale: Float
    /// Top-left of the visible part of the source, in source pixels.
    var visibleOrigin: SIMD2<Float>
    /// Extent of the visible part of the source, in source pixels.
    var visibleSize: SIMD2<Float>

    init(sourceWidth: Int, sourceHeight: Int,
         outputWidth: Int = Int(FrameFormat.width), outputHeight: Int = Int(FrameFormat.height)) {
        let s = SIMD2(Float(max(1, sourceWidth)), Float(max(1, sourceHeight)))
        let o = SIMD2(Float(outputWidth), Float(outputHeight))
        sourceSize = s
        outputSize = o
        scale = max(o.x / s.x, o.y / s.y)
        visibleSize = o / scale
        visibleOrigin = (s - visibleSize) / 2
    }

    /// Normalised (0...1) source coordinates of the visible region: what the camera shader samples.
    var uvOrigin: SIMD2<Float> { visibleOrigin / sourceSize }
    var uvSize: SIMD2<Float> { visibleSize / sourceSize }

    func toOutput(_ p: SIMD2<Float>) -> SIMD2<Float> { (p - visibleOrigin) * scale }
    func toSource(_ p: SIMD2<Float>) -> SIMD2<Float> { p / scale + visibleOrigin }
    /// Lengths (no origin shift).
    func toOutput(length: Float) -> Float { length * scale }

    func toOutput(_ r: CGRect) -> CGRect {
        let o = toOutput(SIMD2(Float(r.minX), Float(r.minY)))
        return CGRect(x: CGFloat(o.x), y: CGFloat(o.y),
                      width: r.width * CGFloat(scale), height: r.height * CGFloat(scale))
    }
}
