import CoreVideo
import Foundation

/// Pre-rendered idle pattern: logo gradient (#00B3C0 -> #009CE4, left to right) with a lighter
/// horizontal bar that moves down the frame.
///
/// Trick: the gradient depends only on x, so every row outside the bar is identical. A master image
/// of 2 x frameHeight rows that repeats with period `frameHeight` is drawn ONCE; "animating" is
/// then just copying 720 rows starting at row `offset` (a single memcpy when strides match).
/// No per-frame drawing.
final class TestPattern: @unchecked Sendable {
    private let master: CVPixelBuffer
    private let masterStride: Int
    private let masterBase: UnsafeMutableRawPointer
    private let width = Int(FrameFormat.width)
    private let height = Int(FrameFormat.height)
    private let barHeight = 96

    init?() {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]]
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(FrameFormat.width), Int(FrameFormat.height) * 2,
                                  FrameFormat.pixelFormat, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        // Locked for the object's lifetime: the master is never written after init and never
        // handed to clients, so a permanent lock avoids a lock/unlock per frame.
        guard CVPixelBufferLockBaseAddress(pb, []) == kCVReturnSuccess,
              let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        master = pb
        masterBase = base
        masterStride = CVPixelBufferGetBytesPerRow(pb)
        draw()
    }

    deinit { CVPixelBufferUnlockBaseAddress(master, []) }

    private func draw() {
        // Build one gradient row (BGRA), then a lighter bar variant.
        func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
        var plain = [UInt8](repeating: 0, count: width * 4)
        var bar = plain
        for x in 0..<width {
            let t = Double(x) / Double(width - 1)
            let r = lerp(0x00, 0x00, t), g = lerp(0xB3, 0x9C, t), b = lerp(0xC0, 0xE4, t)
            plain[x * 4 + 0] = UInt8(b); plain[x * 4 + 1] = UInt8(g)
            plain[x * 4 + 2] = UInt8(r); plain[x * 4 + 3] = 0xFF
            let k = 0.55 // blend toward white
            bar[x * 4 + 0] = UInt8(lerp(b, 255, k)); bar[x * 4 + 1] = UInt8(lerp(g, 255, k))
            bar[x * 4 + 2] = UInt8(lerp(r, 255, k)); bar[x * 4 + 3] = 0xFF
        }
        for y in 0..<(height * 2) {
            let inBar = (y % height) < barHeight
            let dst = masterBase.advanced(by: y * masterStride)
            (inBar ? bar : plain).withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: width * 4) }
        }
    }

    /// Copies one frame into `dst` (must be locked for writing, same width/format). `offset` in 0..<height.
    func copyFrame(offset: Int, into dst: CVPixelBuffer) {
        guard let dstBase = CVPixelBufferGetBaseAddress(dst) else { return }
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        let src = masterBase.advanced(by: (offset % height) * masterStride)
        if dstStride == masterStride {
            dstBase.copyMemory(from: src, byteCount: height * masterStride)
        } else {
            for y in 0..<height {
                dstBase.advanced(by: y * dstStride)
                    .copyMemory(from: src.advanced(by: y * masterStride), byteCount: width * 4)
            }
        }
    }
}
