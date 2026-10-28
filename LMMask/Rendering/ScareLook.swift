// ScareLook.swift
// LM Mask - the 3D half of SCARE MODE. Reads one `scareAmount` (0...1, see `ScareEnvelope`) per frame:
//  - binary swaps at amount >= 0.5 (sudden): the eye and mouth windows go PITCH BLACK (the occluders stop occluding and the
//    tint films turn opaque #000000, so black replaces the live video), the blue prints turn black (#0A0A0C), and the
//    black demon stencil (`LogoFace`: slanted flame-browed eye slits, nose notch, fanged grin, 6 cracks) appears over the
//    front of the mask. The white vinyl stays white: black on white is what reads scary;
//  - continuous: the key light dims to 25 % and turns cold, coming from below (low cold uplight); the rim light fades out.
// The stencil is our own node under the mark root (`LogoFace.nodeName`), rebuilt when the geometry is rebuilt;
// `styleChanged` re-applies the binary state after a style change reset the materials.
//
// Units: authored in centimetres under the mark root (scale 0.01), like everything else in the mark.
// Confinement: built on the main actor with the scene, then used from the render queue only.
//
// Apple docs:
//  - SCNLight                https://developer.apple.com/documentation/scenekit/scnlight
//  - SCNMaterial.transparency https://developer.apple.com/documentation/scenekit/scnmaterial/1462541-transparency

import AppKit
import SceneKit
import simd

final class ScareLook: @unchecked Sendable {

    enum Config {
        /// Amount at which the binary material / visibility swaps happen.
        static let swapAt: Float = 0.5
        /// Key light at full scare: fraction of its normal intensity, cold tint, pitch (rad; + = light travels up, so it
        /// shines from below).
        static let keyScale: Float = 0.25
        static let keyUpliftPitch: Float = 40 * .pi / 180
        /// Environment (IBL) intensity multiplier at full scare.
        static let environmentScale: Float = 0.4
        /// Vignette flicker rate, Hz.
        static let flickerHz = 9.0
    }

    private weak var mark: SCNNode?
    private let key: SCNNode
    private let rim: SCNNode
    private var style: MaskStyle
    private(set) var isApplied = false

    private let baseKeyIntensity: CGFloat
    private let baseKeyEuler: SIMD3<Float>
    private let baseRimIntensity: CGFloat
    private var lastAmount: Float = 0
    private var stencil: SCNNode?

    init(mark: SCNNode, key: SCNNode, rim: SCNNode, style: MaskStyle) {
        self.mark = mark
        self.key = key
        self.rim = rim
        self.style = style
        baseKeyIntensity = key.light?.intensity ?? 1500
        baseKeyEuler = key.simdEulerAngles
        baseRimIntensity = rim.light?.intensity ?? 900
        rebuildStencil()
    }

    // MARK: Per frame

    /// - Parameter amount: `scareAmount` 0...1.
    func update(amount a: Float) {
        let on = a >= Config.swapAt
        if on != isApplied { setApplied(on) }

        if a > 0 || lastAmount > 0 {
            // Continuous: the low cold uplight.
            if let l = key.light {
                l.intensity = baseKeyIntensity * CGFloat(1 - (1 - Config.keyScale) * a)
                l.color = NSColor(srgbRed: CGFloat(1 - 0.45 * a), green: CGFloat(1 - 0.30 * a), blue: 1, alpha: 1)
            }
            key.simdEulerAngles = simd_mix(baseKeyEuler, SIMD3(Config.keyUpliftPitch, 0, 0), SIMD3(repeating: a))
            rim.light?.intensity = baseRimIntensity * CGFloat(1 - a)
        }
        lastAmount = a
    }

    /// Call after the renderer changed materials / geometry for a new style (that reset what we changed).
    func styleChanged(_ new: MaskStyle, geometryChanged: Bool) {
        style = new
        if geometryChanged { rebuildStencil() }
        if isApplied { applyLook() }
    }

    /// 0...1 pseudo-noise: three incommensurate sines plus a little random jitter, around `hz` (modulates the vignette).
    static func flicker(time t: Double, hz: Double) -> Float {
        let w = 2 * Double.pi * hz
        let s = 0.5 * sin(w * t) + 0.3 * sin(w * 1.618 * t + 1.3) + 0.2 * sin(w * 2.71 * t + 4.1)
        let n = 0.5 + 0.5 * s + Double.random(in: -0.12...0.12)
        return Float(min(1, max(0, n)))
    }

    // MARK: Swap

    private func setApplied(_ on: Bool) {
        guard let mark else { return }
        isApplied = on
        if on {
            applyLook()
        } else {
            // Back to the normal look: vinyl, gradient prints, tint films, occluders, mouth window visibility.
            LogoMeshBuilder.updateMaterials(in: mark, style: style)
            stencil?.isHidden = true
        }
    }

    /// Idempotent: pushes every binary scare state. Called on swap-on and after each style change while applied.
    private func applyLook() {
        guard let mark else { return }

        // Prints: black.
        for name in LogoMeshBuilder.NodeName.printed {
            guard let m = mark.childNode(withName: name, recursively: true)?.geometry?.firstMaterial else { continue }
            m.diffuse.contentsTransform = SCNMatrix4Identity
            m.diffuse.contents = style.scare.printColor.nsColor
        }
        // Windows: stop occluding, show opaque black instead of the video.
        for name in LogoMeshBuilder.NodeName.windows {
            guard let w = mark.childNode(withName: name, recursively: true) else { continue }
            w.childNode(withName: LogoMeshBuilder.NodeName.occluder, recursively: false)?.isHidden = true
            if let m = w.childNode(withName: LogoMeshBuilder.NodeName.tint, recursively: false)?.geometry?.firstMaterial {
                m.diffuse.contents = NSColor.black
                m.transparency = 1
                m.blendMode = .alpha
                m.writesToDepthBuffer = true
            }
        }
        stencil?.isHidden = false
    }

    // MARK: Stencil

    private func rebuildStencil() {
        guard let mark else { return }
        stencil?.removeFromParentNode()
        let node = LogoFace.makeNode(fingerFront: LogoMeshBuilder.fingerFrontZ(in: mark))
        node.isHidden = !isApplied
        mark.addChildNode(node)
        stencil = node
    }
}
