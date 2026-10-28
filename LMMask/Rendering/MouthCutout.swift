import CoreGraphics
import simd

/// Decides which part of the camera frame is shown in the mouth window: a SHARP rounded-rectangle crop around the outer
/// lips (no feather, no blur, no CPU raster, no mask texture), scaled to fill the window.
///
/// - The lip bounding box is grown by `margin` (30 % of its half-extent) around its centre.
/// - The crop is then widened or heightened to the window's aspect ratio, so the mouth is never stretched.
/// - The crop's corner radius is `cornerRadius` (25 % of its height) = the window's own rounded rectangle
///   (`LogoMeshBuilder.mouthWindowCornerFraction`). The compositor clips the patch to that shape with a hard (1 px
///   anti-aliased) edge, so the edge of the visible mouth is the window's geometric edge.
///
/// Pure value type (no GPU resources); safe from any thread.
struct MouthCutout: Sendable {
    /// Margin around the lips as a fraction of their half-extent.
    var margin: Float = 0.30
    /// Corner radius as a fraction of the crop's height.
    var cornerRadius: Float = Float(LogoMeshBuilder.mouthWindowCornerFraction)
    /// Always 0: the edge is hard. (Kept as a named constant so nobody adds a blur back by accident.)
    static let feather: Float = 0

    struct Crop: Sendable {
        /// Centre and half-extent in CAMERA pixels (top-left origin).
        var center: SIMD2<Float>
        var half: SIMD2<Float>
    }

    /// - Parameters:
    ///   - lips: `FacePose.outerLips`, camera pixels.
    ///   - aspect: window width / height.
    /// - Returns: nil if the lips are unusable.
    func crop(lips: [SIMD2<Float>], aspect: Float) -> Crop? {
        guard lips.count >= 6, aspect > 0.1 else { return nil }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for p in lips { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let center = (lo + hi) / 2
        var half = (hi - lo) / 2 * (1 + margin)
        guard half.x > 1 else { return nil }
        half.y = max(half.y, 0.5)
        // Fit the window's aspect by growing the short side.
        if half.x / half.y > aspect { half.y = half.x / aspect } else { half.x = half.y * aspect }
        return Crop(center: center, half: half)
    }
}
