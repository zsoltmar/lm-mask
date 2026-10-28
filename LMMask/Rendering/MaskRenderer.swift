// MaskRenderer.swift
// LM Mask - SceneKit scene with the inflated logo on a head node, rendered offscreen into an RGBA texture.
//
// Apple docs:
//  - SCNRenderer.render(atTime:viewport:commandBuffer:passDescriptor:)
//      https://developer.apple.com/documentation/scenekit/scnrenderer/1522693-render
//  - SCNCamera.projectionDirection  https://developer.apple.com/documentation/scenekit/scncamera/1436738-projectiondirection
//  - SCNCamera.fieldOfView          https://developer.apple.com/documentation/scenekit/scncamera/1436634-fieldofview
//  - SCNLight                       https://developer.apple.com/documentation/scenekit/scnlight
//  - SCNScene.lightingEnvironment   https://developer.apple.com/documentation/scenekit/scnscene/1523481-lightingenvironment
//  - MTLRenderPassDescriptor        https://developer.apple.com/documentation/metal/mtlrenderpassdescriptor

import AppKit
import CoreMedia
import CoreVideo
import Metal
import SceneKit
import os
import simd

/// Constants shared with tracking so the virtual camera matches the real one.
enum RenderConstants {
    /// Horizontal FOV used by `FaceTracker` to back-project the face. Single source of truth.
    static let horizontalFOV: Float = HeadPoseGeometry.defaultHorizontalFOV
    /// Pinhole focal length in pixels for the 1280-wide frame.
    static let focalLengthPixels: Float = HeadPoseGeometry.focalLengthPixels(imageWidth: Float(FrameFormat.width))
    /// Mask target format. See QUESTIONS.md D1 (colour space / premultiplication of SceneKit's output).
    static let maskPixelFormat: MTLPixelFormat = .bgra8Unorm
    /// MSAA sample count for the offscreen pass (1 disables).
    static let msaaSamples = 4
}

/// User-facing knobs. Value type; the pipeline snapshots it once per frame.
struct RenderSettings: Sendable, Equatable {
    /// False = camera passes through un-masked (and is not sent to the virtual camera).
    var enabled = true
    /// Logo height as a multiple of the detected face height. 1.8...3.2.
    var maskScale: Float = 2.4
    /// Show the user's mouth in the mask's mouth window.
    var showMouth = true
    /// Whole-headpiece shift along the mask's own up vector, as a fraction of face height (positive = up). On top of
    /// the eye-socket-to-eye matching. See `MaskSettingsSpec.verticalOffsetDefault`.
    var verticalOffset: Float = Float(MaskSettingsSpec.verticalOffsetDefault)
    /// Holds scare mode on regardless of the face ("Test scare" button, 2 s).
    var forceScare = false

    static let maskScaleRange: ClosedRange<Float> = 1.8...3.2
}

/// Offscreen SceneKit renderer. Built on the main actor (the logo loader is main-actor), then confined to the
/// render queue: `update`, `updateEnvironment`, `render` are not thread-safe and must be called from one queue.
final class MaskRenderer: @unchecked Sendable {

    enum Tuning {
        /// One strong key light 30 degrees up and to the left of the camera axis, plus a rim light from behind-right.
        static let keyLightElevation: Float = 30
        static let keyLightAzimuth: Float = 30
        static let keyIntensity: CGFloat = 1500
        static let rimIntensity: CGFloat = 900
        static let rimElevation: Float = 25
        static let rimAzimuth: Float = 30
        static let environmentIntensity: CGFloat = 0.9
        /// Logo sits this far behind the eye plane (metres).
        static let logoDepthOffset: Float = 0.06
        /// Extra SCREEN-space vertical shift of the eye anchor, fraction of face height (positive = down). Keep 0: the
        /// user-facing shift is `RenderSettings.verticalOffset`, applied along the mask's own up vector.
        static let logoDropFractionOfFace: Float = 0
        /// Seconds without a confident pose before easing to the resting pose.
        static let restDelay: Double = 0.4
        static let restEaseTau: Float = 0.25
        static let environmentInterval: Double = 0.2  // 5 Hz
        static let fallbackFaceHeight: Float = 0.22
        static let fallbackDepth: Float = 0.6
    }

    let width: Int
    let height: Int
    /// The RGBA mask (transparent where no logo). Valid after `render`.
    let maskTexture: MTLTexture
    /// The mouth window's four corners in output pixels (top-left origin; order: window top-left, top-right, bottom-right,
    /// bottom-left) after the last `update`. The compositor draws the user's mouth into this quad.
    private(set) var mouthWindowCorners: [SIMD2<Float>] = []
    /// Window width / height and corner radius (fraction of height) for the compositor's clip.
    private(set) var mouthWindowAspect: Float = 22.0 / 8.0
    private(set) var mouthWindowCornerRadius = Float(LogoMeshBuilder.mouthWindowCornerFraction)
    /// Clockwise visual roll of the face, radians (the mouth crop is sampled rotated by it).
    private(set) var faceRoll: Float = 0
    /// True when the last `update` had a live pose (the mouth should only show then).
    private(set) var isTracking = false

    private let queue: MTLCommandQueue
    private let scene = SCNScene()
    private let renderer: SCNRenderer
    private let headNode = SCNNode()
    private let logoNode = SCNNode()
    private let cameraNode = SCNNode()
    private let mouthAnchor: SCNNode
    private let probe = EnvironmentProbe()
    private let pass: MTLRenderPassDescriptor
    private let nativeMarkHeight: Float
    private let log = Logger.lm("mask")

    // Look (MaskStyle). `style` drives materials and geometry. Changes arrive from any thread via `submit(_:)` and are
    // applied on the render queue in `render`.
    private var style: MaskStyle
    private let markNode: SCNNode
    private let supportsStyle: Bool
    private let pendingStyle = OSAllocatedUnfairLock<[StyleUpdate]>(initialState: [])

    // Pose state
    private var lastTime: Double?
    private var lastSeen = -Double.infinity
    // Screen-space placement state (output pixels, top-left origin). See `Placement` below and docs/rendering.md.
    private var lastAnchor = SIMD2<Float>(640, 290)  // where the logo's socket midpoint sits
    private var lastSpan: Float = 160                // frontal inter-eye distance in output px
    private var lastRoll: Float = 0
    private var lastPitch: Float = 0
    private var lastFaceHeight: Float = 220          // face-rect height in output px
    private var faceHeightFilter = OneEuroFilter(parameters: Placement.pixelFilter)
    private var anchorXFilter = OneEuroFilter(parameters: Placement.pixelFilter)
    private var anchorYFilter = OneEuroFilter(parameters: Placement.pixelFilter)
    private var spanFilter = OneEuroFilter(parameters: Placement.pixelFilter)
    private var rollFilter = OneEuroFilter(parameters: Placement.rollFilter)
    private var sockets: (l: SCNNode, r: SCNNode)?
    private var socketMid = SIMD3<Float>(0, 0, 0)  // logoNode-local units
    private var socketSpan: Float = 0.2            // logoNode-local units
    private var socketsResolved = false
    private var blend: Float = 0
    private var heldYaw: Float = 0
    private var lastEnvironment = -Double.infinity

    // Scare mode (docs/rendering.md "Scare"). `scareEnvelope.amount` is the one value every piece reads.
    private var scare: ScareLook?
    private var scareConfig: MaskStyle.Scare
    private var scareDetector = ScareDetector()
    private var scareEnvelope = ScareEnvelope()
    private var scareOnset = -Double.infinity
    private var scareFramesSinceOnset = 1000
    private var scarePopHeld: Float = 1
    private var scarePop: Float = 1
    /// Compositor input for the current frame. Valid after `update`.
    private(set) var scareFrame = ScareFrame()
    /// True while the trigger is active (the envelope may still be easing out after it turns false).
    private(set) var scareActive = false
    /// Latest trigger readings for the debug HUD / stats. Valid after `update`.
    private(set) var scareReadout = ScareReadout()
    /// True while the scare materials / plates are swapped in (amount >= 0.5): the video mouth patch must stay hidden.
    var scareApplied: Bool { scare?.isApplied ?? false }

    @MainActor
    init(device: MTLDevice, queue: MTLCommandQueue, style: MaskStyle = MaskStyle(),
         width: Int = Int(FrameFormat.width), height: Int = Int(FrameFormat.height)) throws {
        self.width = width
        self.height = height
        self.queue = queue

        let loaded = try LogoAssetLoader.load(style: style)
        let mark = loaded.node
        Logger.lm("mask").info("logo source: \(String(describing: loaded.source), privacy: .public)")
        self.style = style
        scareConfig = style.scare
        markNode = mark
        supportsStyle = loaded.source == .fallback
        nativeMarkHeight = Self.measureHeight(mark)
        guard let anchor = mark.childNode(withName: LogoMeshBuilder.NodeName.mouthAnchor, recursively: true)
        else { throw LogoMeshBuilder.BuildError.unexpectedIslandCount(-1) }
        mouthAnchor = anchor

        // Textures
        let pass = MTLRenderPassDescriptor()
        let samples = RenderConstants.msaaSamples
        func desc(_ f: MTLPixelFormat, _ usage: MTLTextureUsage, ms: Bool) -> MTLTextureDescriptor {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: width, height: height, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if ms { d.textureType = .type2DMultisample; d.sampleCount = samples }
            return d
        }
        let maskDesc = desc(RenderConstants.maskPixelFormat, [.renderTarget, .shaderRead], ms: false)
        guard let mask = device.makeTexture(descriptor: maskDesc),
              let depth = device.makeTexture(descriptor: desc(.depth32Float_stencil8, .renderTarget, ms: samples > 1))
        else { throw Compositor.Failure.textureCache }
        maskTexture = mask

        let c0 = pass.colorAttachments[0]!
        c0.loadAction = .clear
        c0.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)  // transparent
        if samples > 1, let msaa = device.makeTexture(descriptor: desc(RenderConstants.maskPixelFormat, .renderTarget, ms: true)) {
            c0.texture = msaa
            c0.resolveTexture = mask
            c0.storeAction = .multisampleResolve
        } else {
            c0.texture = mask
            c0.storeAction = .store
        }
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        pass.stencilAttachment.texture = depth
        pass.stencilAttachment.loadAction = .clear
        pass.stencilAttachment.storeAction = .dontCare
        self.pass = pass

        // All stored properties are set after this line, so `self` is usable below.
        renderer = SCNRenderer(device: device, options: nil)

        // Scene graph: root -> camera, lights, head -> logoNode -> mark
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.intensity = Tuning.environmentIntensity

        let camera = SCNCamera()
        camera.projectionDirection = .horizontal
        camera.fieldOfView = CGFloat(RenderConstants.horizontalFOV * 180 / .pi)
        camera.zNear = 0.05
        camera.zFar = 8
        camera.wantsHDR = false
        cameraNode.camera = camera  // at the origin looking down -z, same as FacePose camera space
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = Tuning.keyIntensity
        key.color = NSColor(white: 1, alpha: 1)
        let keyNode = SCNNode()
        keyNode.light = key
        // Default light direction is -z. Pitch down 30 deg and yaw toward +x (light travels right) so it
        // arrives from the upper left. Positive rotation about y turns -z toward -x, hence the minus.
        keyNode.simdEulerAngles = SIMD3(-Tuning.keyLightElevation * .pi / 180, -Tuning.keyLightAzimuth * .pi / 180, 0)
        scene.rootNode.addChildNode(keyNode)

        // Rim light from behind, upper right: it travels toward the camera (+z), down and a little to the left, so it
        // grazes the tubes' edges and gives the vinyl its bright outline. Euler order is z, y, x: yaw (pi - azimuth) turns
        // the default -z direction around to +z with a -x component, pitch tips it down.
        let rimLight = SCNLight()
        rimLight.type = .directional
        rimLight.intensity = Tuning.rimIntensity
        rimLight.color = NSColor(srgbRed: 0.92, green: 0.96, blue: 1, alpha: 1)
        let rimNode = SCNNode()
        rimNode.light = rimLight
        rimNode.simdEulerAngles = SIMD3(Tuning.rimElevation * .pi / 180, .pi - Tuning.rimAzimuth * .pi / 180, 0)
        scene.rootNode.addChildNode(rimNode)

        scene.rootNode.addChildNode(headNode)
        headNode.addChildNode(logoNode)
        logoNode.addChildNode(mark)
        scare = ScareLook(mark: mark, key: keyNode, rim: rimNode, style: style)

        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        applyPlacement(anchor: lastAnchor, span: lastSpan, faceHeight: lastFaceHeight,
                       rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1), settings: RenderSettings())
    }

    // MARK: Per-frame

    /// Updates mask placement, the scare look and the mouth window quad. Call once per frame before `render`.
    ///
    /// Placement is SCREEN-SPACE: the face's eye midpoint / eye distance (source px -> output px via `mapping`) decide
    /// where the logo's two eye sockets must project; the mask is then put on a fixed depth plane (`Placement.anchorDepth`)
    /// so that it does. No metric depth is involved.
    /// - Parameters:
    ///   - pose: tracker output (source-frame pixels), nil when there is no usable face.
    ///   - mapping: source frame -> output pixel mapping of this frame.
    ///   - time: frame presentation time in seconds (monotonic).
    func update(pose: FacePose?, mapping: FrameMapping, time t: Double, settings s: RenderSettings) {
        let dt = Float(min(0.25, max(0.001, t - (lastTime ?? t - 1.0 / 30))))
        lastTime = t

        if let p = pose {
            if t - lastSeen > Tuning.restDelay { resetPlacementFilters() }  // re-seed after a gap
            lastSeen = t
            let target = Self.placementTarget(for: p, mapping: mapping)
            lastAnchor = SIMD2(anchorXFilter.filter(target.anchor.x, timestamp: t),
                               anchorYFilter.filter(target.anchor.y, timestamp: t))
            lastSpan = max(1, spanFilter.filter(target.span, timestamp: t))
            lastRoll = rollFilter.filter(target.roll, timestamp: t)
            lastPitch = p.pitch
            lastFaceHeight = max(1, faceHeightFilter.filter(target.faceHeight, timestamp: t))
            heldYaw = p.yaw
        }
        isTracking = pose != nil
        updateScareState(pose: pose, time: t, dt: dt, settings: s)
        let lost = pose == nil && (t - lastSeen) > Tuning.restDelay

        // Ease toward / away from the resting pose (centred, facing the camera, same size as last seen).
        blend += ((lost ? 0 : 1) - blend) * (1 - exp(-dt / Tuning.restEaseTau))
        let restAnchor = SIMD2(Float(width) / 2, Float(height) * Placement.restAnchorY)
        let anchor = simd_mix(restAnchor, lastAnchor, SIMD2(repeating: blend))
        let trackedRot = HeadPoseGeometry.rotation(roll: lastRoll, yaw: heldYaw, pitch: lastPitch)
        let rot = simd_slerp(Self.restRotation(time: t), trackedRot, blend)
        applyPlacement(anchor: anchor, span: lastSpan, faceHeight: lastFaceHeight, rotation: rot, settings: s)

        scare?.update(amount: scareFrame.amount)
        scene.lightingEnvironment.intensity = Tuning.environmentIntensity
            * CGFloat(1 - (1 - ScareLook.Config.environmentScale) * scareFrame.amount)

        // Mouth window -> output pixels (same pinhole model as the placement). The anchor sits on the window plane.
        let hw = Float(style.mouthWindowWidth) / 2, hh = Float(style.mouthWindowHeight) / 2
        let windowCorners: [SIMD3<Float>] = [SIMD3(-hw, hh, 0), SIMD3(hw, hh, 0), SIMD3(hw, -hh, 0), SIMD3(-hw, -hh, 0)]
        mouthWindowCorners = windowCorners.map { project(mouthAnchor.simdConvertPosition($0, to: nil)) }
        mouthWindowAspect = max(0.1, Float(style.mouthWindowWidth / max(0.1, style.mouthWindowHeight)))
        faceRoll = -lastRoll  // lastRoll is SceneKit's counter-clockwise sense; the shader wants clockwise-visual
    }

    /// Trigger -> `scareEnvelope` -> `scareFrame` (compositor input), pop scale and HUD readout. Runs before placement so
    /// the pop scale of this frame is used.
    private func updateScareState(pose: FacePose?, time t: Double, dt: Float, settings s: RenderSettings) {
        let cfg = scareConfig
        let m = pose?.mouthOpenness ?? 0
        let l = pose?.leftOpenness ?? 0
        let r = pose?.rightOpenness ?? 0

        let wasActive = scareDetector.isActive
        var active = false
        if cfg.enabled {
            scareDetector.config = ScareDetector.Config(cfg)
            scareDetector.forceScare = s.forceScare
            active = scareDetector.update(mouth: m, leftEye: l, rightEye: r, time: t)
        } else {
            scareDetector.forceScare = false
            scareDetector.reset()
        }
        scareActive = active
        if active && !wasActive {
            scareOnset = t - Double(dt)  // one frame of pre-roll, same as the envelope
            scareFramesSinceOnset = 0
        } else {
            scareFramesSinceOnset = min(scareFramesSinceOnset + 1, 1000)
        }

        let amount = scareEnvelope.update(active: active, time: t, preroll: Double(dt))
        var frame = ScareFrame()
        frame.amount = amount
        frame.vignette = Float(cfg.vignette)
        frame.flicker = 1 + 0.16 * (ScareLook.flicker(time: t, hz: ScareLook.Config.flickerHz) - 0.5)
        if scareFramesSinceOnset < 2 {  // onset only: 2 frames of white flash and +-6 px shake
            frame.flash = 0.6
            frame.shake = scareFramesSinceOnset == 0 ? SIMD2(6, 2) : SIMD2(-6, -2)
        }
        scareFrame = frame

        if active {
            scarePopHeld = ScareEnvelope.pop(sinceOnset: t - scareOnset)
            scarePop = scarePopHeld
        } else {
            scarePop = 1 + (scarePopHeld - 1) * amount
        }

        scareReadout = ScareReadout(active: active, forced: scareDetector.forceScare, enabled: cfg.enabled, amount: amount,
                                    mouth: m, leftEye: l, rightEye: r,
                                    mouthThreshold: Float(cfg.mouthThreshold), eyeThreshold: Float(cfg.eyeThreshold),
                                    holdProgress: scareDetector.holdProgress)
    }

    /// Geometry for the alignment overlay (output pixels). Valid after `update`.
    func makeDebugInfo(pose: FacePose?, mapping: FrameMapping) -> PlacementDebugInfo {
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        if let mark = logoNode.childNodes.first {
            let (mn, mx) = mark.boundingBox
            for i in 0..<8 {
                let c = SIMD3<Float>(Float(i & 1 == 0 ? mn.x : mx.x), Float(i & 2 == 0 ? mn.y : mx.y),
                                     Float(i & 4 == 0 ? mn.z : mx.z))
                let px = project(mark.simdConvertPosition(c, to: nil))
                lo = simd_min(lo, px); hi = simd_max(hi, px)
            }
        }
        if lo.x > hi.x { lo = .zero; hi = .zero }
        var face: PlacementDebugInfo.Face?
        if let p = pose {
            face = .init(rect: mapping.toOutput(p.faceRect),
                         leftEye: mapping.toOutput(p.leftEyeCenter), rightEye: mapping.toOutput(p.rightEyeCenter),
                         lips: p.outerLips.map { mapping.toOutput($0) },
                         yaw: p.yaw, pitch: p.pitch, roll: p.roll)
        }
        return PlacementDebugInfo(
            sourceSize: mapping.sourceSize, cropScale: mapping.scale, face: face,
            maskBounds: CGRect(x: CGFloat(lo.x), y: CGFloat(lo.y), width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y)),
            socketL: sockets.map { project($0.l.simdWorldPosition) } ?? .zero,
            socketR: sockets.map { project($0.r.simdWorldPosition) } ?? .zero,
            scare: scareReadout)
    }

    /// True when the compositor should draw the user's mouth into the mask's mouth window: window mode on, tracking, and
    /// not in a scare (the window is black then). Render queue only.
    var mouthWindowActive: Bool { style.mouthMode == .window && isTracking && !scareApplied }

    /// Refreshes image-based lighting from the camera frame, at most every 200 ms.
    func updateEnvironment(from camera: CVPixelBuffer, time t: Double) {
        guard t - lastEnvironment >= Tuning.environmentInterval, let probe else { return }
        lastEnvironment = t
        if let image = probe.update(from: camera) { scene.lightingEnvironment.contents = image }
    }

    /// Encodes the 3D pass into `maskTexture` and commits it. A later command buffer on the same queue
    /// (the compositor's) is ordered after it by Metal's per-queue ordering and resource tracking.
    func render(time t: Double) {
        applyPendingStyle()
        guard let cb = queue.makeCommandBuffer() else { return }
        cb.label = "MaskRenderer"
        renderer.render(atTime: t, viewport: CGRect(x: 0, y: 0, width: width, height: height),
                        commandBuffer: cb, passDescriptor: pass)
        cb.commit()
    }

    // MARK: Helpers

    /// Pinhole focal length in output pixels for the SceneKit camera (horizontal FOV, square pixels).
    private var focalPixels: Float { Float(width) / 2 / tan(RenderConstants.horizontalFOV / 2) }

    /// Camera-space point -> output pixel (top-left origin).
    private func project(_ w: SIMD3<Float>) -> SIMD2<Float> {
        let f = focalPixels, z = max(0.05, -w.z)
        return SIMD2(Float(width) / 2 + f * w.x / z, Float(height) / 2 - f * w.y / z)
    }

    /// Finds the eye sockets once and measures them in `logoNode`-local units (independent of logoNode's scale).
    private func resolveSockets() {
        guard !socketsResolved else { return }
        socketsResolved = true
        guard let l = logoNode.childNode(withName: LogoMeshBuilder.NodeName.eyeLeftSocket, recursively: true),
              let r = logoNode.childNode(withName: LogoMeshBuilder.NodeName.eyeRightSocket, recursively: true) else {
            log.error("eye sockets not found; falling back to a guessed eye span")
            socketMid = SIMD3(0, 0.3 * nativeMarkHeight, 0)
            socketSpan = 0.3 * nativeMarkHeight
            return
        }
        let pl = logoNode.simdConvertPosition(.zero, from: l), pr = logoNode.simdConvertPosition(.zero, from: r)
        sockets = (l, r)
        socketMid = (pl + pr) / 2
        socketSpan = max(1e-4, simd_distance(pl, pr))
    }

    /// Puts the socket midpoint at the camera-space point that projects to `anchor` on the `anchorDepth` plane,
    /// scales the logo so the socket distance projects to `span` x factor, and rotates about that anchor.
    /// The vertical / horizontal offsets are fractions of `faceHeight` (output px) applied in `headNode`'s rotated frame,
    /// i.e. along the mask's own up / right vectors, so they follow head roll (and yaw / pitch).
    private func applyPlacement(anchor: SIMD2<Float>, span: Float, faceHeight: Float, rotation: simd_quatf,
                                settings s: RenderSettings) {
        resolveSockets()
        let d = Placement.anchorDepth, f = focalPixels
        // maskScale (default 2.4) now scales the eye span: 1.0x at the default, so the sockets cover the eyes there.
        let scaleSetting = min(max(s.maskScale, RenderSettings.maskScaleRange.lowerBound),
                               RenderSettings.maskScaleRange.upperBound)
        let factor = Placement.eyeSpanFactor * scaleSetting / Float(MaskSettingsSpec.maskScaleDefault)
        let k = span * factor * d / (f * socketSpan) * scarePop  // scare pop scales about the socket midpoint
        headNode.simdPosition = SIMD3((anchor.x - Float(width) / 2) * d / f,
                                      -(anchor.y - Float(height) / 2) * d / f,
                                      -d)
        headNode.simdOrientation = rotation
        logoNode.simdScale = SIMD3(repeating: k)
        // Socket midpoint sits on headNode's origin (the pivot); the offset then slides the whole mask along its own axes.
        let metresPerPixel = d / f
        let shift = SIMD3(Float(style.horizontalOffset), min(max(s.verticalOffset, -0.5), 1.0), 0) * (faceHeight * metresPerPixel)
        logoNode.simdPosition = -k * socketMid + shift
    }

    private func resetPlacementFilters() {
        anchorXFilter.reset(); anchorYFilter.reset(); spanFilter.reset(); rollFilter.reset(); faceHeightFilter.reset()
    }

    static func restTransform(depth: Float) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(0, 0, -depth, 1)
        return m
    }

    /// Facing the camera with a slow, tiny sway so the idle logo does not look frozen.
    private static func restRotation(time t: Double) -> simd_quatf {
        let yaw = 0.06 * Float(sin(t * 0.7)), pitch = 0.025 * Float(sin(t * 0.5 + 1))
        return HeadPoseGeometry.rotation(roll: 0, yaw: yaw, pitch: pitch)
    }

    /// Mark height in metres. `boundingBox` is in the node's local space; the fallback root carries a 0.01
    /// scale so the box is in cm, and a metre-scale USDZ needs no factor. Whichever interpretation lands in a
    /// plausible range wins; otherwise the SVG's 71.885 cm.
    @MainActor
    private static func measureHeight(_ mark: SCNNode) -> Float {
        let (mn, mx) = mark.boundingBox
        let raw = Float(mx.y - mn.y)
        for candidate in [raw * Float(mark.scale.y), raw] where (0.3...1.5).contains(candidate) { return candidate }
        return 0.71885
    }
}

// MARK: - Style (look)

/// A look change on its way to the render queue. Value type, Sendable.
struct StyleUpdate: Sendable {
    var style: MaskStyle
    /// True = rebuild the extruded geometry (a millisecond or so of polygon work plus SceneKit tessellation). False = materials only.
    var rebuildGeometry: Bool
}

extension MaskRenderer {
    /// Queues a style change; callable from any thread. It is applied at the start of the next `render(time:)`.
    func submit(_ update: StyleUpdate) {
        pendingStyle.withLock { $0.append(update) }
    }

    /// Render queue only. Coalesces everything queued since the last frame into one apply.
    fileprivate func applyPendingStyle() {
        let batch = pendingStyle.withLock { (queued: inout [StyleUpdate]) -> [StyleUpdate] in
            let b = queued
            queued.removeAll()
            return b
        }
        guard !batch.isEmpty else { return }
        if let last = batch.last { scareConfig = last.style.scare }  // thresholds apply even for a USDZ mark
        guard supportsStyle else { return }
        var rebuild = false
        for u in batch {
            style = u.style
            if u.rebuildGeometry { rebuild = true }
        }
        if rebuild {
            do {
                try LogoMeshBuilder.rebuildGeometry(in: markNode, style: style)
                socketsResolved = false  // socket z moved with the depths; re-measure on the next placement
            } catch {
                log.error("headpiece rebuild failed: \(String(describing: error), privacy: .public)")
            }
        }
        LogoMeshBuilder.updateMaterials(in: markNode, style: style)
        scare?.styleChanged(style, geometryChanged: rebuild)  // materials were just reset: re-apply the scare look if it is on
    }
}

// MARK: - Screen-space placement

extension MaskRenderer {
    /// Tunables for screen-space placement (docs/rendering.md "Placement").
    enum Placement {
        /// Fixed distance (m) of the plane the logo's eye midpoint sits on. Any value works; it only sets the
        /// scene's numeric range (the scale is derived from it).
        static let anchorDepth: Float = 1.0
        /// Projected socket distance / user's inter-eye distance, at maskScale = default (2.4).
        static let eyeSpanFactor: Float = 1.0
        /// Resting anchor height as a fraction of the output height (no face).
        static let restAnchorY: Float = 0.4
        /// One-Euro parameters: pixels (anchor, span) and radians (roll).
        static let pixelFilter = OneEuroParameters(minCutoff: 1.5, beta: 0.05, dCutoff: 1.0)
        static let rollFilter = OneEuroParameters(minCutoff: 1.5, beta: 1.0, dCutoff: 1.0)
        /// Below this inter-eye distance (output px) the eye landmarks are not trusted; use the face rect.
        static let minEyeDistance: Float = 8
    }

    struct PlacementTarget {
        /// Output px: where the logo's socket midpoint must project.
        var anchor: SIMD2<Float>
        /// Output px: frontal (yaw-corrected) inter-eye distance.
        var span: Float
        /// Radians, SceneKit sense (counter-clockwise on screen positive), from the eye line.
        var roll: Float
        /// Output px: height of the face rect (basis of the offset settings).
        var faceHeight: Float
    }

    /// Converts a pose (source px) to output-pixel placement. This is the single place where frame -> output happens
    /// for the mask. Vision's bottom-left -> top-left flip already happened in `FaceTracker`.
    static func placementTarget(for p: FacePose, mapping: FrameMapping) -> PlacementTarget {
        let l = mapping.toOutput(p.leftEyeCenter), r = mapping.toOutput(p.rightEyeCenter)
        let rect = mapping.toOutput(p.faceRect)
        let ipd = simd_distance(l, r)
        var mid: SIMD2<Float>, span: Float, roll: Float = 0
        if ipd >= Placement.minEyeDistance {
            mid = (l + r) / 2
            span = ipd
            var v = r - l
            if v.x < 0 { v = -v }  // eye order from Vision does not matter
            roll = -atan2(v.y, v.x)  // screen y is down, SceneKit +z rotation is counter-clockwise
        } else {
            mid = SIMD2(Float(rect.midX), Float(rect.minY) + 0.4 * Float(rect.height))
            span = 0.45 * Float(rect.width)
        }
        mid.y += Tuning.logoDropFractionOfFace * Float(rect.height)
        span /= max(0.6, cos(p.yaw))  // undo foreshortening; the rotated logo foreshortens by itself
        return PlacementTarget(anchor: mid, span: span, roll: roll, faceHeight: Float(rect.height))
    }
}
