import CoreMedia
import CoreVideo
import Foundation
import Metal
import os
import simd

// CVMetalTextureCache:        https://developer.apple.com/documentation/corevideo/cvmetaltexturecache
// CVPixelBufferPool:          https://developer.apple.com/documentation/corevideo/cvpixelbufferpool
// MTLRenderPassDescriptor:    https://developer.apple.com/documentation/metal/mtlrenderpassdescriptor
// Blending (premultiplied):   https://developer.apple.com/documentation/metal/mtlblendfactor/one
// setVertexBytes (no alloc):  https://developer.apple.com/documentation/metal/mtlrendercommandencoder/1515846-setvertexbytes

/// Where the user's mouth goes this frame: into the mask's mouth window. Value type, Sendable.
struct MouthPlacement: Sendable {
    /// The window's four corners projected to output pixels (top-left origin), in the order top-left, top-right,
    /// bottom-right, bottom-left of the WINDOW (so they follow the mask's roll / yaw / pitch).
    var corners: [SIMD2<Float>]
    /// Crop rectangle centre and half-extent in CAMERA pixels (top-left origin), already fitted to the window's aspect.
    var cropCenter: SIMD2<Float>
    var cropHalf: SIMD2<Float>
    /// Visual clockwise roll of the user's face, radians: the crop is sampled rotated by it, so the mouth stays upright in
    /// the (equally rolled) window.
    var rotation: Float
    /// Window width / height, and its corner radius as a fraction of the height.
    var aspect: Float
    var cornerRadius: Float
}

/// Mirrors `MouthUniforms` in Compositor.metal. Keep field order and types identical (11 x float2, no padding).
private struct MouthUniforms {
    var c0: SIMD2<Float>
    var c1: SIMD2<Float>
    var c2: SIMD2<Float>
    var c3: SIMD2<Float>
    var cropCenter: SIMD2<Float>
    var cropHalf: SIMD2<Float>
    var camSize: SIMD2<Float>
    var outSize: SIMD2<Float>
    var shape: SIMD2<Float>  // aspect, corner radius fraction
    var rot: SIMD2<Float>    // cos, sin
}

/// Mirrors `ScareUniforms` in Compositor.metal. Keep field order and types identical.
private struct ScareUniforms {
    var amount: Float
    var flash: Float
    var vignette: Float
    var flicker: Float
}

/// Draws camera frame + 3D mask + mouth cut-out into a pooled `CVPixelBuffer` with one Metal render pass.
///
/// Threading: not thread-safe; used only from the render queue. Blocks that queue (not the capture
/// queue) until the GPU finishes so the returned buffer is complete and per-frame CPU-written textures
/// (mouth mask) can be reused without a ring.
final class Compositor: @unchecked Sendable {
    enum Failure: Error { case noLibrary, noFunction(String), textureCache, pool }

    let width: Int
    let height: Int
    /// 1 if the 3D pass produced straight alpha (premultiply in shader), 0 if premultiplied.
    var maskIsStraightAlpha = false

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache!
    private var pool: CVPixelBufferPool!
    private let cameraPSO: MTLRenderPipelineState
    private let maskPSO: MTLRenderPipelineState
    private let mouthPSO: MTLRenderPipelineState
    private let scarePSO: MTLRenderPipelineState
    private let pass = MTLRenderPassDescriptor()
    private var frameCounter = 0
    private let log = Logger.lm("compositor")

    nonisolated(unsafe) private static let textureAttributes: CFDictionary = [
        kCVMetalTextureUsage as String: (MTLTextureUsage.shaderRead.union(.renderTarget)).rawValue
    ] as CFDictionary

    init(device: MTLDevice, queue: MTLCommandQueue,
         width: Int = Int(FrameFormat.width), height: Int = Int(FrameFormat.height)) throws {
        self.device = device
        self.queue = queue
        self.width = width
        self.height = height

        guard let library = device.makeDefaultLibrary() else { throw Failure.noLibrary }
        func pso(_ v: String, _ f: String, blend: Bool) throws -> MTLRenderPipelineState {
            guard let vf = library.makeFunction(name: v) else { throw Failure.noFunction(v) }
            guard let ff = library.makeFunction(name: f) else { throw Failure.noFunction(f) }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            if blend {
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one  // premultiplied alpha
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        cameraPSO = try pso("fullscreenVertex", "cameraFragment", blend: false)
        maskPSO = try pso("fullscreenVertex", "maskFragment", blend: true)
        mouthPSO = try pso("mouthVertex", "mouthFragment", blend: true)
        scarePSO = try pso("fullscreenVertex", "scareFragment", blend: true)

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache
        else { throw Failure.textureCache }
        textureCache = cache

        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: FrameFormat.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &p) == kCVReturnSuccess,
              let p else { throw Failure.pool }
        pool = p

        pass.colorAttachments[0].loadAction = .dontCare  // the camera draw covers every pixel
        pass.colorAttachments[0].storeAction = .store
    }

    /// Composites one frame. Returns nil if the pool is exhausted (downstream holds too many buffers)
    /// or GPU resources could not be created; the caller then simply drops the frame.
    /// - Parameters:
    ///   - mask: RGBA mask from `MaskRenderer`, nil to skip (pass-through / disabled).
    ///   - mouth: where the user's mouth goes (the mask's mouth window), nil to skip. Drawn BEFORE the mask, so the mask's
    ///     tint film covers it and everything of the patch outside the window's hole is hidden by the opaque mask.
    ///   - mapping: source-frame -> output mapping (aspect-fill crop of the camera).
    ///   - scare: scare-mode screen shake, vignette and flash for this frame (`.none` = nothing).
    func composite(camera: CVPixelBuffer, mapping: FrameMapping, mask: MTLTexture?,
                   mouth: MouthPlacement?,
                   scare: ScareFrame = .none) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        let aux = [kCVPixelBufferPoolAllocationThresholdKey as String: 12] as CFDictionary
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, aux, &out)
        guard status == kCVReturnSuccess, let out else {
            if status == kCVReturnWouldExceedAllocationThreshold { log.notice("pool exhausted; dropping frame") }
            return nil
        }
        guard let (camTex, camRef) = makeTexture(camera), let (outTex, outRef) = makeTexture(out),
              let cb = queue.makeCommandBuffer() else { return nil }
        cb.label = "Compositor"

        pass.colorAttachments[0].texture = outTex
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        enc.label = "Composite"
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(width), height: Double(height),
                                    znear: 0, zfar: 1))
        enc.setCullMode(.none)

        enc.setRenderPipelineState(cameraPSO)
        enc.setFragmentTexture(camTex, index: 0)
        var cropUV = SIMD4<Float>(mapping.uvOrigin.x, mapping.uvOrigin.y, mapping.uvSize.x, mapping.uvSize.y)
        enc.setFragmentBytes(&cropUV, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        // Scare shake: the whole frame (camera, mask, mouth) moves by `scare.shake` output pixels.
        var shiftUV = SIMD2<Float>(scare.shake.x / Float(width), scare.shake.y / Float(height))
        enc.setFragmentBytes(&shiftUV, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // The user's mouth, relocated into the mask's mouth window. Under the mask: the mask's window hole is the sharp edge.
        if let p = mouth, p.corners.count == 4 {
            let cw = Float(CVPixelBufferGetWidth(camera)), ch = Float(CVPixelBufferGetHeight(camera))
            var u = MouthUniforms(
                c0: p.corners[0] + scare.shake, c1: p.corners[1] + scare.shake,
                c2: p.corners[2] + scare.shake, c3: p.corners[3] + scare.shake,
                cropCenter: p.cropCenter, cropHalf: p.cropHalf,
                camSize: SIMD2(cw, ch), outSize: SIMD2(Float(width), Float(height)),
                shape: SIMD2(p.aspect, p.cornerRadius),
                rot: SIMD2(cos(p.rotation), sin(p.rotation)))
            enc.setRenderPipelineState(mouthPSO)
            enc.setVertexBytes(&u, length: MemoryLayout<MouthUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<MouthUniforms>.stride, index: 0)
            enc.setFragmentTexture(camTex, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 12 * 6 * 6)
        }

        if let mask {
            enc.setRenderPipelineState(maskPSO)
            enc.setFragmentTexture(mask, index: 0)
            var premultiply: Float = maskIsStraightAlpha ? 1 : 0
            enc.setFragmentBytes(&premultiply, length: MemoryLayout<Float>.size, index: 0)
            enc.setFragmentBytes(&shiftUV, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Scare vignette + flash on top of everything (premultiplied blend).
        if scare.amount > 0.001 || scare.flash > 0 {
            var su = ScareUniforms(amount: scare.amount, flash: scare.flash, vignette: scare.vignette, flicker: scare.flicker)
            enc.setRenderPipelineState(scarePSO)
            enc.setFragmentBytes(&su, length: MemoryLayout<ScareUniforms>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        withExtendedLifetime((camRef, outRef)) {}  // CVMetalTextures must outlive GPU work

        frameCounter += 1
        if frameCounter % 120 == 0 { CVMetalTextureCacheFlush(textureCache, 0) }
        if cb.status == .error {
            log.error("composite failed: \(cb.error?.localizedDescription ?? "?", privacy: .public)")
            return nil
        }
        return out
    }

    private func makeTexture(_ pb: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var ref: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pb, Self.textureAttributes, .bgra8Unorm,
            CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &ref)
        guard r == kCVReturnSuccess, let ref, let tex = CVMetalTextureGetTexture(ref) else { return nil }
        return (tex, ref)
    }
}
