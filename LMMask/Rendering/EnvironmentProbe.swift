import CoreGraphics
import CoreVideo
import Foundation

/// Turns the camera frame into a tiny 32x18 blurred image used as SceneKit's image-based lighting source,
/// so the logo picks up the colour and brightness of the user's room.
///
/// CPU only: samples 5x5 points per 40x40 cell (about 11k reads), blurs 3x3 over the 32x18 grid. Called at about
/// 5 Hz by `MaskRenderer`. The scratch arrays and bitmap are allocated once; only the final 2 KB `CGImage` is new.
/// Not thread-safe (render queue only).
///
/// SCNScene.lightingEnvironment: https://developer.apple.com/documentation/scenekit/scnscene/1523481-lightingenvironment
final class EnvironmentProbe: @unchecked Sendable {
    static let width = 32
    static let height = 18
    private static let samplesPerAxis = 5

    private var cells = [Float](repeating: 0, count: width * height * 3)
    private var blurred = [Float](repeating: 0, count: width * height * 3)
    private let bitmap: UnsafeMutablePointer<UInt8>
    private let ctx: CGContext

    init?() {
        let n = Self.width * Self.height * 4
        bitmap = .allocate(capacity: n)
        bitmap.initialize(repeating: 255, count: n)
        guard let c = CGContext(data: bitmap, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx = c
    }

    deinit { bitmap.deallocate() }

    /// - Returns: a 32x18 sRGB image, or nil if the buffer is not 32BGRA.
    func update(from pb: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let W = CVPixelBufferGetWidth(pb), H = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let px = base.assumingMemoryBound(to: UInt8.self)
        let gw = Self.width, gh = Self.height, n = Self.samplesPerAxis
        let cw = Float(W) / Float(gw), chh = Float(H) / Float(gh)

        for gy in 0..<gh {
            for gx in 0..<gw {
                var r: Float = 0, g: Float = 0, b: Float = 0
                for sy in 0..<n {
                    let y = min(H - 1, Int((Float(gy) + (Float(sy) + 0.5) / Float(n)) * chh))
                    for sx in 0..<n {
                        let x = min(W - 1, Int((Float(gx) + (Float(sx) + 0.5) / Float(n)) * cw))
                        let o = y * stride + x * 4
                        b += Float(px[o]); g += Float(px[o + 1]); r += Float(px[o + 2])
                    }
                }
                let k = 1 / (Float(n * n) * 255)
                let i = (gy * gw + gx) * 3
                cells[i] = r * k; cells[i + 1] = g * k; cells[i + 2] = b * k
            }
        }

        // 3x3 blur: wraps horizontally (equirectangular), clamps vertically.
        for gy in 0..<gh {
            for gx in 0..<gw {
                var acc = SIMD3<Float>(repeating: 0)
                for dy in -1...1 {
                    let y = min(gh - 1, max(0, gy + dy))
                    for dx in -1...1 {
                        let x = (gx + dx + gw) % gw
                        let i = (y * gw + x) * 3
                        acc += SIMD3(cells[i], cells[i + 1], cells[i + 2])
                    }
                }
                acc /= 9
                let i = (gy * gw + gx) * 3
                blurred[i] = acc.x; blurred[i + 1] = acc.y; blurred[i + 2] = acc.z
                let o = (gy * gw + gx) * 4  // BGRA, premultiplied, alpha 255
                bitmap[o] = UInt8(max(0, min(1, acc.z)) * 255)
                bitmap[o + 1] = UInt8(max(0, min(1, acc.y)) * 255)
                bitmap[o + 2] = UInt8(max(0, min(1, acc.x)) * 255)
            }
        }
        return ctx.makeImage()
    }
}
