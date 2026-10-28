// LogoMeshBuilder.swift
// LM Mask - in-code inflatable "glove": a white vinyl palm with the logo's four islands as four separate puffy tubes
// ("fingers") lying on it, the blue logo PRINTED on the fingers, and sharp transparent WINDOWS for the user's eyes and
// mouth.
//
// Units: 1 SVG unit = 1 cm. Child geometry is authored in SVG units and the root node "lmMark" carries scale 0.01 so that
// SceneKit world units (metres) come out right.
// Frame: origin = centre of the 72.307 x 71.885 viewBox, +x right, +y up, +z toward the viewer.
//
// Node tree (all created once by `makeMark`; `rebuildGeometry` only swaps geometries and positions, so materials and
// anything that references the nodes survive a style change):
//   lmMark
//    |- headpiece                  palm: rounded rect pillow, depth bodyDepth, centred on z = -2
//    |- collar                     optional neck pillow below it
//    |- logo
//    |   |- bar_short, bar_tall, swoosh, bar_right     the four finger pillows (island outline + fingerPad, full-round tubes)
//    |- prints
//    |   |- print_swoosh, print_bar_right              opaque blue prints 0.2 in front of the finger surface
//    |   |- window_bar_short, window_bar_tall, window_mouth
//    |       |- occluder           colour-less depth writer (renderingOrder -10): everything behind it in the mask texture
//    |       |                     stays alpha 0, so the live video shows through with a SHARP geometric edge
//    |       |- tint               coplanar blue film (alpha blended, renderingOrder 10): the tint seen through the window
//    |- eye_L_socket, eye_R_socket, mouthAnchor     empties on the window plane
//
// Apple docs:
//  - SCNShape                https://developer.apple.com/documentation/scenekit/scnshape
//  - chamferRadius/Profile   https://developer.apple.com/documentation/scenekit/scnshape/1523606-chamferradius
//  - colorBufferWriteMask    https://developer.apple.com/documentation/scenekit/scnmaterial/1462566-colorbufferwritemask
//  - writesToDepthBuffer     https://developer.apple.com/documentation/scenekit/scnmaterial/1462580-writestodepthbuffer
//  - renderingOrder          https://developer.apple.com/documentation/scenekit/scnnode/1408023-renderingorder
//  - clearCoat               https://developer.apple.com/documentation/scenekit/scnmaterial/1462528-clearcoat
//  - CGGradient              https://developer.apple.com/documentation/coregraphics/cggradient

import AppKit
import CoreGraphics
import SceneKit

enum LogoMeshBuilder {

    // MARK: Node names (shared contract with LogoAssetLoader / ScareLook / MaskRenderer)

    enum NodeName {
        static let root = "lmMark"
        static let headpiece = "headpiece"
        static let collar = "collar"
        static let logo = "logo"
        static let barShort = "bar_short"
        static let barTall = "bar_tall"
        static let swoosh = "swoosh"
        static let barRight = "bar_right"
        static let prints = "prints"
        static let printSwoosh = "print_swoosh"
        static let printBarRight = "print_bar_right"
        static let windowShort = "window_bar_short"
        static let windowTall = "window_bar_tall"
        static let windowMouth = "window_mouth"
        static let occluder = "occluder"
        static let tint = "tint"
        static let eyeLeftSocket = "eye_L_socket"
        static let eyeRightSocket = "eye_R_socket"
        static let mouthAnchor = "mouthAnchor"

        static let islands = [barShort, barTall, swoosh, barRight]
        static let printed = [printSwoosh, printBarRight]
        static let windows = [windowShort, windowTall, windowMouth]
    }

    // MARK: Fixed constants (everything tunable lives in MaskStyle)

    enum Style {
        /// SceneKit metres per SVG unit (1 unit = 1 cm).
        static let metresPerUnit: CGFloat = 0.01
        /// Set true to skip the gradient texture and use one lerped colour per print.
        static let useFlatColorFallback = false
        static let textureSize = 1024
        /// Flip the quarter-circle chamfer profile if the pillow edges look dented instead of puffy.
        static let flipChamfer = false
        /// Largest chamfer radius of a finger, so a deep finger never out-chamfers its own width.
        static let maxFingerChamfer = 6.0
    }

    /// Z layout, all relative to the front-most point of the finger pillows (`fingerFront`), SVG units.
    enum Layer {
        /// Palm centre z (spec: -2, so the fingers sit on it).
        static let bodyZ: CGFloat = -2
        static let collarZ: CGFloat = -4
        /// Printed shape: back face 0.2 in front of the finger surface, 0.3 thick.
        static let printBack: CGFloat = 0.2
        static let printDepth: CGFloat = 0.3
        /// Window occluder: just in front of the print.
        static let occluderBack: CGFloat = printBack + printDepth + 0.02
        static let occluderDepth: CGFloat = 0.1
        /// Window tint: 0.05 in front of the occluder.
        static let tintBack: CGFloat = occluderBack + occluderDepth + 0.05
        static let tintDepth: CGFloat = 0.02
        /// Plane of the eye / mouth anchors (the front of the tint).
        static let windowFront: CGFloat = tintBack + tintDepth
        /// Scare stencil: back face 0.4 in front of the finger surface, 0.3 thick.
        static let stencilBack: CGFloat = 0.4
        static let stencilDepth: CGFloat = 0.3
        static let occluderRenderingOrder = -10
        static let tintRenderingOrder = 10
    }

    /// Window shape of the mouth: corner radius as a fraction of the window height. Shared with the compositor, whose
    /// mouth patch is clipped to the same rounded rectangle.
    static let mouthWindowCornerFraction: Double = 0.25

    /// Neck / collar pillow, SVG coordinates (y down): wider than the palm, below it.
    static let collarRect = CGRect(x: -4, y: 80, width: 80, height: 20)
    static let collarRadius = 10.0
    static let collarDepth: CGFloat = 14

    // MARK: Source data (copied verbatim from Assets/mark-light-color.svg, id="mark")

    static let markPathData =
        "M20.307 54.885 C22.837 55.563 25.37 54.033 26.032 51.546 L32.091 29.633 C32.758 27.114 31.376 24.238 28.882 23.563 C26.387 22.886 23.728 24.668 23.061 27.188 L17.002 49.102 C16.335 51.622 17.813 54.211 20.307 54.885 Z "
        + "M36.678 54.828 C39.218 55.508 41.756 53.968 42.417 51.484 L51.52 18.394 C52.188 15.87 50.707 13.277 48.206 12.601 C45.705 11.926 43.136 13.421 42.467 15.945 L33.365 49.034 C32.695 51.559 34.177 54.153 36.678 54.828 Z "
        + "M49.893 61.486 L21.52 61.486 C14.219 61.486 8.908 54.509 10.777 47.452 L12.534 41.01 C13.197 38.533 11.729 35.987 9.252 35.325 C6.775 34.662 4.231 36.129 3.567 38.606 L1.804 45.074 C-1.608 57.95 8.1 70.769 21.52 70.769 L49.893 70.769 C52.458 70.769 54.534 68.688 54.534 66.126 C54.534 63.564 52.457 61.486 49.893 61.486 Z "
        + "M67.799 1.294 C65.328 0.586 62.762 2.056 62.069 4.575 L49.81 48.919 C49.117 51.438 50.555 54.053 53.027 54.758 C55.519 55.463 58.064 53.974 58.757 51.477 L71.016 7.133 C71.709 4.614 70.271 1.999 67.799 1.294 Z"

    /// Gradient geometry from the SVG: userSpaceOnUse x1=1.116, x2=71.19, first stop offset 0.0591.
    private static let gradientX1: CGFloat = 1.116
    private static let gradientX2: CGFloat = 71.19
    private static let gradientStop0: CGFloat = 0.0591
    private static let teal = (r: CGFloat(0), g: CGFloat(179) / 255, b: CGFloat(192) / 255)
    private static let blue = (r: CGFloat(0), g: CGFloat(156) / 255, b: CGFloat(228) / 255)

    /// SVG coordinates (y down) of the anchors. The user's level eyes land inside the two middle bars; the mouth anchor is
    /// the centre of the swoosh's horizontal run.
    static let eyeLeftSVG = CGPoint(x: 27.5, y: 30)
    static let eyeRightSVG = CGPoint(x: 44, y: 30)
    static let mouthSVG = CGPoint(x: 35.7, y: 66)
    /// The same in the centred, y-up mark frame (x, y only; z comes from the layout).
    static let eyeLeftPosition = SVGPathParser.centered(eyeLeftSVG)
    static let eyeRightPosition = SVGPathParser.centered(eyeRightSVG)
    static let mouthPosition = SVGPathParser.centered(mouthSVG)

    typealias BuildError = LogoSilhouette.BuildError

    // MARK: Build

    /// Builds the "lmMark" node tree. Throws only if the embedded path data is malformed.
    static func makeMark(style: MaskStyle = MaskStyle()) throws -> SCNNode {
        let root = SCNNode()
        root.name = NodeName.root
        root.scale = SCNVector3(Style.metresPerUnit, Style.metresPerUnit, Style.metresPerUnit)

        func child(_ name: String, of parent: SCNNode) -> SCNNode {
            let n = SCNNode()
            n.name = name
            parent.addChildNode(n)
            return n
        }
        _ = child(NodeName.headpiece, of: root)
        _ = child(NodeName.collar, of: root)
        let logo = child(NodeName.logo, of: root)
        for name in NodeName.islands { _ = child(name, of: logo) }
        let prints = child(NodeName.prints, of: root)
        for name in NodeName.printed { _ = child(name, of: prints) }
        for name in NodeName.windows {
            let w = child(name, of: prints)
            let occluder = child(NodeName.occluder, of: w)
            occluder.renderingOrder = Layer.occluderRenderingOrder
            let tint = child(NodeName.tint, of: w)
            tint.renderingOrder = Layer.tintRenderingOrder
        }
        for name in [NodeName.eyeLeftSocket, NodeName.eyeRightSocket, NodeName.mouthAnchor] { _ = child(name, of: root) }

        try rebuildGeometry(in: root, style: style)
        updateMaterials(in: root, style: style)
        return root
    }

    /// Replaces the geometry of an existing mark built by `makeMark` (materials are kept) and repositions the anchors.
    /// Returns the z of the fingers' front surface. Cheap enough to run on the render queue between frames.
    @discardableResult
    static func rebuildGeometry(in root: SCNNode, style: MaskStyle) throws -> CGFloat {
        let outline = try LogoSilhouette.build(pad: style.fingerPad, inset: style.printInset)
        func node(_ name: String) -> SCNNode? { root.childNode(withName: name, recursively: true) }

        // The shared white vinyl: the palm owns the instance, everything else reuses it.
        let vinyl = node(NodeName.headpiece)?.geometry?.firstMaterial ?? makeVinylMaterial(style: style)

        // Palm.
        var bodyFront = Layer.bodyZ + CGFloat(style.bodyDepth) / 2
        if let n = node(NodeName.headpiece) {
            let poly = LogoSilhouette.roundedRect(svg: style.bodyRect, radius: style.cornerRadius)
            bodyFront = Layer.bodyZ + pillow(n, polygon: poly, depth: style.bodyDepth, maxRadius: .infinity,
                                             centreZ: Layer.bodyZ, material: vinyl)
        }

        // Collar.
        if let n = node(NodeName.collar) {
            let poly = LogoSilhouette.roundedRect(svg: collarRect, radius: collarRadius)
            pillow(n, polygon: poly, depth: Double(collarDepth), maxRadius: .infinity, centreZ: Layer.collarZ, material: vinyl)
            n.isHidden = !style.showCollar
        }

        // Fingers: centred on the palm's front plane, so half of each tube is sunk into the palm.
        var fingerFront = bodyFront + CGFloat(style.fingerDepth) / 2
        for island in outline.islands {
            guard let n = node(island.name) else { continue }
            let half = pillow(n, polygon: island.padded, depth: style.fingerDepth, maxRadius: Style.maxFingerChamfer,
                              centreZ: bodyFront, material: vinyl)
            fingerFront = bodyFront + half
        }

        // Prints: opaque blue shapes 0.2 in front of the finger surface.
        for (name, islandName) in [(NodeName.printSwoosh, NodeName.swoosh), (NodeName.printBarRight, NodeName.barRight)] {
            guard let n = node(name), let island = outline.island(islandName) else { continue }
            flat(n, polygon: island.inset, depth: Layer.printDepth, backZ: fingerFront + Layer.printBack,
                 material: n.geometry?.firstMaterial ?? makePrintMaterial(style: style))
        }

        // Windows: the eye windows are the printed shapes of the two middle bars; the mouth window is a rounded rectangle
        // inside the swoosh's horizontal run.
        let mouthPoly: [CGPoint] = {
            let w = style.mouthWindowWidth, h = style.mouthWindowHeight
            let rect = CGRect(x: mouthSVG.x - w / 2, y: mouthSVG.y - h / 2, width: w, height: h)
            return LogoSilhouette.roundedRect(svg: rect, radius: h * mouthWindowCornerFraction)
        }()
        let windowShapes: [(String, [CGPoint])] = [
            (NodeName.windowShort, outline.island(NodeName.barShort)?.inset ?? []),
            (NodeName.windowTall, outline.island(NodeName.barTall)?.inset ?? []),
            (NodeName.windowMouth, mouthPoly),
        ]
        for (name, poly) in windowShapes where poly.count >= 3 {
            guard let w = node(name),
                  let occluder = w.childNode(withName: NodeName.occluder, recursively: false),
                  let tint = w.childNode(withName: NodeName.tint, recursively: false) else { continue }
            flat(occluder, polygon: poly, depth: Layer.occluderDepth, backZ: fingerFront + Layer.occluderBack,
                 material: occluder.geometry?.firstMaterial ?? makeOccluderMaterial())
            flat(tint, polygon: poly, depth: Layer.tintDepth, backZ: fingerFront + Layer.tintBack,
                 material: tint.geometry?.firstMaterial ?? makeTintMaterial(style: style))
        }

        // Anchors on the window plane.
        let z = fingerFront + Layer.windowFront
        for (name, p) in [(NodeName.eyeLeftSocket, eyeLeftPosition), (NodeName.eyeRightSocket, eyeRightPosition),
                          (NodeName.mouthAnchor, mouthPosition)] {
            node(name)?.position = SCNVector3(p.x, p.y, z)
        }
        return fingerFront
    }

    /// Applies the live (material and visibility) part of the style to a mark built by `makeMark`. Resets everything a
    /// scare changed (`ScareLook` re-applies its look afterwards while a scare is on).
    static func updateMaterials(in root: SCNNode, style: MaskStyle) {
        func node(_ name: String) -> SCNNode? { root.childNode(withName: name, recursively: true) }

        if let m = node(NodeName.headpiece)?.geometry?.firstMaterial { configureVinyl(m, style: style) }
        node(NodeName.collar)?.isHidden = !style.showCollar

        for name in NodeName.printed {
            guard let n = node(name), let m = n.geometry?.firstMaterial else { continue }
            configurePrint(m, bounds: xBounds(of: n), style: style)
        }
        for name in NodeName.windows {
            guard let w = node(name) else { continue }
            let mouthOff = name == NodeName.windowMouth && style.mouthMode == .off
            w.isHidden = mouthOff
            w.childNode(withName: NodeName.occluder, recursively: false)?.isHidden = false
            if let m = w.childNode(withName: NodeName.tint, recursively: false)?.geometry?.firstMaterial {
                configureTint(m, style: style)
            }
        }
        // With the mouth window off the swoosh print stays solid; nothing else to do (the window group is hidden).
    }

    /// Creates an empty node in mark-local (cm) units.
    static func empty(_ name: String, at p: CGPoint, z: CGFloat) -> SCNNode {
        let n = SCNNode()
        n.name = name
        n.position = SCNVector3(p.x, p.y, z)
        return n
    }

    /// z of the fingers' front surface, recovered from the mouth anchor (set by `rebuildGeometry`).
    static func fingerFrontZ(in root: SCNNode) -> CGFloat {
        (root.childNode(withName: NodeName.mouthAnchor, recursively: true)?.position.z ?? 0) - Layer.windowFront
    }

    // MARK: Shapes

    /// `NSBezierPath` polygon (straight edges: the outlines are already finely flattened).
    private static func bezierPath(_ poly: [CGPoint]) -> NSBezierPath {
        let p = NSBezierPath()
        for (i, q) in poly.enumerated() {
            if i == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        return p
    }

    /// Fully rounded pillow: `SCNShape` extruded `depth` with a chamfer of `depth / 2` (capped at `maxRadius`) in a
    /// quarter-circle profile. The node is moved so the measured middle of the result sits at `centreZ`.
    /// Returns the measured half depth (SceneKit does not document where the extrusion sits along z).
    @discardableResult
    private static func pillow(_ node: SCNNode, polygon: [CGPoint], depth: Double, maxRadius: Double, centreZ: CGFloat,
                               material: SCNMaterial) -> CGFloat {
        let shape = SCNShape(path: bezierPath(polygon), extrusionDepth: CGFloat(depth))
        shape.chamferMode = .both
        shape.chamferRadius = CGFloat(min(depth / 2, maxRadius))
        shape.chamferProfile = quarterCircleProfile(flipped: Style.flipChamfer)
        shape.materials = [material]
        node.geometry = shape
        node.position = SCNVector3(0, 0, 0)
        let (mn, mx) = node.boundingBox
        node.position = SCNVector3(0, 0, centreZ - (mn.z + mx.z) / 2)
        return (mx.z - mn.z) / 2
    }

    /// Thin flat shape (no chamfer) whose back face sits at `backZ`.
    private static func flat(_ node: SCNNode, polygon: [CGPoint], depth: CGFloat, backZ: CGFloat, material: SCNMaterial) {
        let shape = SCNShape(path: bezierPath(polygon), extrusionDepth: depth)
        shape.chamferRadius = 0
        shape.materials = [material]
        node.geometry = shape
        placeBack(node, at: backZ)
    }

    /// Moves `node` along z so the back face of its geometry (the smaller z of its bounding box) is at `z`.
    static func placeBack(_ node: SCNNode, at z: CGFloat) {
        node.position = SCNVector3(0, 0, 0)
        let (mn, _) = node.boundingBox
        node.position = SCNVector3(0, 0, z - mn.z)
    }

    /// Quarter-circle chamfer profile in the unit square, from (0,1) to (1,0).
    /// SceneKit reads x as inward offset and y as depth along the extrusion (Apple's docs are terse here, so
    /// `flipped` lets you swap to the opposite bulge without re-deriving anything).
    static func quarterCircleProfile(flipped: Bool) -> NSBezierPath {
        let k: CGFloat = 0.5522847498 // 4/3 * (sqrt(2) - 1): cubic approximation of a quarter circle
        let p = NSBezierPath()
        p.move(to: CGPoint(x: 0, y: 1))
        if flipped {
            // Centre (1,1): bulges toward (0,0).
            p.curve(to: CGPoint(x: 1, y: 0),
                    controlPoint1: CGPoint(x: 0, y: 1 - k),
                    controlPoint2: CGPoint(x: 1 - k, y: 0))
        } else {
            // Centre (0,0): bulges toward (1,1).
            p.curve(to: CGPoint(x: 1, y: 0),
                    controlPoint1: CGPoint(x: k, y: 1),
                    controlPoint2: CGPoint(x: 1, y: k))
        }
        return p
    }

    /// x extent of a node's geometry in the centred frame (the print nodes sit at x = 0).
    private static func xBounds(of node: SCNNode) -> (min: CGFloat, max: CGFloat) {
        let (mn, mx) = node.boundingBox
        return (mn.x, mx.x)
    }

    // MARK: Materials

    /// White PBR vinyl: near-white diffuse, glossy clear coat. One instance shared by the palm, the collar and the fingers.
    static func makeVinylMaterial(style: MaskStyle) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.isDoubleSided = false
        configureVinyl(m, style: style)
        return m
    }

    static func configureVinyl(_ m: SCNMaterial, style: MaskStyle) {
        m.diffuse.contents = style.bodyColor.nsColor
        m.roughness.contents = NSNumber(value: style.roughness)
        m.metalness.contents = NSNumber(value: 0)
        // Clear coat gives the wet, taut-vinyl hotspot. Both properties exist on SCNMaterial since macOS 10.12.
        m.clearCoat.contents = NSNumber(value: style.clearcoat)
        m.clearCoatRoughness.contents = NSNumber(value: style.clearcoatRoughness)
    }

    static func makePrintMaterial(style: MaskStyle) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.metalness.contents = NSNumber(value: 0)
        m.isDoubleSided = false
        m.diffuse.contents = style.tintColor.nsColor  // replaced by `configurePrint` right after the geometry is in place
        return m
    }

    /// Roughness 0.3, and the teal -> blue gradient (or flat blue) as diffuse. `bounds` = x extent of the print in the
    /// centred frame, to map the shared gradient texture onto it.
    static func configurePrint(_ m: SCNMaterial, bounds: (min: CGFloat, max: CGFloat), style: MaskStyle) {
        m.roughness.contents = NSNumber(value: 0.3)
        if style.printGradient, !Style.useFlatColorFallback, let image = gradientImage {
            // ASSUMPTION (unverifiable without running): SCNShape generates planar UVs normalised to *each shape's own*
            // bounding box (u: 0...1 across minX...maxX). Apple does not document this. To get one continuous gradient
            // across all prints each shape's u range is remapped into the global texture. If the on-screen gradient
            // looks wrong, switch the "Gradient" toggle off (or set Style.useFlatColorFallback = true).
            m.diffuse.contents = image
            let u0 = globalU(forCentredX: bounds.min), u1 = globalU(forCentredX: bounds.max)
            var t = SCNMatrix4Identity
            t.m11 = u1 - u0
            t.m41 = u0
            m.diffuse.contentsTransform = t
            m.diffuse.wrapS = .clamp
            m.diffuse.wrapT = .clamp
            m.diffuse.mipFilter = .linear
        } else {
            m.diffuse.contentsTransform = SCNMatrix4Identity
            m.diffuse.contents = flatBlue
        }
    }

    /// Occluder: draws no colour, only depth, so everything behind it stays transparent in the mask texture.
    static func makeOccluderMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.black
        m.transparency = Layer.occluderTransparency
        m.colorBufferWriteMask = []
        m.writesToDepthBuffer = true
        m.readsFromDepthBuffer = true
        m.isDoubleSided = true
        return m
    }

    static func makeTintMaterial(style: MaskStyle) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        configureTint(m, style: style)
        return m
    }

    /// Blue film over the video: unlit tint colour at `tintOpacity`, alpha blended, never writes depth.
    static func configureTint(_ m: SCNMaterial, style: MaskStyle) {
        m.diffuse.contents = style.tintColor.nsColor
        m.transparency = CGFloat(style.tintOpacity)
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        m.colorBufferWriteMask = .all
    }

    private static var flatBlue: NSColor { NSColor(srgbRed: blue.r, green: blue.g, blue: blue.b, alpha: 1) }
    /// Built once (1024^2); an immutable CGImage, so sharing it between threads is fine.
    nonisolated(unsafe) private static let gradientImage: CGImage? = makeGradientImage(size: Style.textureSize)

    /// u in the 1024^2 texture covers the whole viewBox width in the centred frame.
    private static func globalU(forCentredX x: CGFloat) -> CGFloat {
        (x + SVGPathParser.viewBoxSize.width / 2) / SVGPathParser.viewBoxSize.width
    }

    /// 1024x1024 sRGB image, teal -> blue left to right, matching the SVG gradient over the 72.307-wide viewBox.
    static func makeGradientImage(size: Int) -> CGImage? {
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let c0 = CGColor(colorSpace: cs, components: [teal.r, teal.g, teal.b, 1]),
              let c1 = CGColor(colorSpace: cs, components: [blue.r, blue.g, blue.b, 1]),
              let gradient = CGGradient(colorsSpace: cs, colors: [c0, c1] as CFArray, locations: [0, 1])
        else { return nil }

        let w = CGFloat(size)
        let vbW = SVGPathParser.viewBoxSize.width
        let startX = (gradientX1 + gradientStop0 * (gradientX2 - gradientX1)) / vbW * w
        let endX = gradientX2 / vbW * w
        ctx.drawLinearGradient(gradient, start: CGPoint(x: startX, y: 0), end: CGPoint(x: endX, y: 0),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        return ctx.makeImage()
    }
}

extension LogoMeshBuilder.Layer {
    /// Alpha of the occluder material. The occluder trick is `colorBufferWriteMask = []` + depth write; 0 is the
    /// documented spec value. If SceneKit turns out to cull fully transparent geometry (windows stay opaque), set this
    /// to 1: the colour mask alone already hides it.
    /// Keep the occluder OPAQUE (1): SceneKit skips fully transparent geometry, and with `colorBufferWriteMask = []`
    /// it writes depth only anyway, which is all the window trick needs.
    static let occluderTransparency: CGFloat = 1
}
