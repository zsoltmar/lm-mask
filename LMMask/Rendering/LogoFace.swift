// LogoFace.swift
// LM Mask - the SCARE face: an ORIGINAL jagged demon stencil, authored here as plain polygons (no existing artwork).
// (This file used to hold the googly eyes; those are gone. The file name stays so the Xcode project does not change.)
//
// All shapes are in the mark's SVG coordinates (y down) while they are authored, and converted to the centred y-up frame
// when the nodes are built. The eye slits are centred on the eye windows (SVG (27.5, 30) and (44, 30)), so the user's
// eyes are swallowed by black; the grin is centred on the mouth window (35.7, 66).
//
//  - two large slanted angry eye slits: sharp almonds, ~17 units wide, inner ends lower; 4 flame-like spikes rise from
//    the outer brow of each
//  - a small sharp inverted-triangle nose notch
//  - a wide grin, 44 units across, corners curled up; its black interior is bounded by a zigzag: 7 long sharp white
//    fangs hang from the top lip, 6 shorter ones rise from the bottom lip (they interleave); the vinyl shows through
//    as the fangs
//  - 6 thin jagged black cracks radiating across the fingers from the eye slits
//
// Everything is flat black (`SCNShape`, 0.3 thick, no chamfer, matte), 0.4 units in front of the fingers' surface.

import AppKit
import CoreGraphics
import SceneKit

enum LogoFace {

    struct Piece {
        let name: String
        /// Closed polygon, centred y-up frame, counter-clockwise.
        let polygon: [CGPoint]
    }

    static let nodeName = "scareFace"
    /// SVG x of the face's vertical axis: midway between the two eye anchors.
    static let axisX = (LogoMeshBuilder.eyeLeftSVG.x + LogoMeshBuilder.eyeRightSVG.x) / 2

    // MARK: Pieces

    static func pieces() -> [Piece] {
        var out: [Piece] = []
        func add(_ name: String, _ svg: [CGPoint]) {
            out.append(Piece(name: name, polygon: LogoSilhouette.counterClockwise(svg.map(SVGPathParser.centered))))
        }

        let left = eyeSlit(mirrored: false), right = eyeSlit(mirrored: true)
        add("eyeL", left.map { CGPoint(x: LogoMeshBuilder.eyeLeftSVG.x + $0.x, y: LogoMeshBuilder.eyeLeftSVG.y + $0.y) })
        add("eyeR", right.map { CGPoint(x: LogoMeshBuilder.eyeRightSVG.x + $0.x, y: LogoMeshBuilder.eyeRightSVG.y + $0.y) })

        // Nose notch: small, sharp, pointing down.
        add("nose", [CGPoint(x: axisX - 2.8, y: 41), CGPoint(x: axisX + 2.8, y: 41), CGPoint(x: axisX, y: 47.5)])

        add("grin", grin(centreX: axisX, centreY: LogoMeshBuilder.mouthSVG.y, half: 22))

        for (i, line) in crackLines.enumerated() { add("crack\(i)", ribbon(line, width: 0.9)) }
        return out
    }

    /// One eye slit relative to its eye anchor (SVG units, y down). Left eye: outer end to the left, inner end (nose side) to
    /// the right and LOWER, so the pair frowns. The four flame spikes rise from the outer half of the brow and lean outward.
    /// `mirrored` flips x for the right eye.
    static func eyeSlit(mirrored: Bool) -> [CGPoint] {
        let unit: [(Double, Double)] = [
            // brow, outer -> inner, with four spikes (tip, notch, tip, notch, ...)
            (-9.0, -2.2),
            (-10.6, -8.8), (-6.4, -4.2),
            (-7.6, -10.6), (-3.8, -3.4),
            (-4.8, -9.4), (-1.4, -3.2),
            (-0.9, -6.0), (1.8, -1.2),
            (8.4, 3.4),
            // lower lid, inner -> outer: a shallow almond
            (7.0, 4.6), (3.0, 4.8), (-2.0, 3.6), (-6.5, 1.2),
        ]
        return unit.map { CGPoint(x: (mirrored ? -$0.0 : $0.0), y: $0.1) }
    }

    /// The grin's black interior as a polygon in SVG coordinates (y down), centred on (`centreX`, `centreY`), `2 * half` wide.
    ///
    /// Lips: the top lip is `yTop(u)`, the bottom lip `yBot(u)` (u = -1...1 across the width); both meet at the corners, which
    /// curl up. The top boundary of the black is a zigzag with 7 tips (the long white fangs hanging down, tip at 62 % of the
    /// local mouth height); the bottom boundary a zigzag with 6 tips rising to 40 % of the local height, placed between the
    /// top tips so they interleave. The zigzags never cross (checked at every vertex: the gap is >= 38 % of the local height).
    static func grin(centreX cx: Double, centreY cy: Double, half: Double) -> [CGPoint] {
        func yTop(_ u: Double) -> Double { cy - 7 - 2 * u * u }
        func yBot(_ u: Double) -> Double { cy + 7 - 16 * u * u }
        func pt(_ u: Double, _ y: Double) -> CGPoint { CGPoint(x: cx + half * u, y: y) }
        let topFangs = 7
        func peak(_ j: Int) -> Double { -1 + 2 * Double(j) / Double(topFangs) }  // j = 0...7, on the top lip

        var pts: [CGPoint] = []
        // Top boundary, left corner -> right corner.
        for j in 0..<topFangs {
            let u = peak(j)
            pts.append(pt(u, yTop(u)))
            let m = (peak(j) + peak(j + 1)) / 2
            pts.append(pt(m, yTop(m) + 0.62 * (yBot(m) - yTop(m))))  // fang tip
        }
        pts.append(pt(1, yTop(1)))  // right corner
        // Bottom boundary, right corner -> left corner: lip points at the top-fang tips, rising fangs at the interior peaks.
        for j in stride(from: topFangs - 1, through: 0, by: -1) {
            let m = (peak(j) + peak(j + 1)) / 2
            pts.append(pt(m, yBot(m)))
            if j > 0 {
                let u = peak(j)
                pts.append(pt(u, yBot(u) - 0.40 * (yBot(u) - yTop(u))))  // rising fang tip
            }
        }
        return pts
    }

    /// Six jagged cracks, polylines in SVG coordinates, radiating from the eye slits across the fingers.
    static var crackLines: [[CGPoint]] { crackData.map { $0.map { CGPoint(x: $0.0, y: $0.1) } } }

    private static let crackData: [[(Double, Double)]] = [
        // short bar, down from the left eye
        [(27.5, 34), (25.9, 38), (27.2, 42), (24.4, 46), (25.1, 50), (22.2, 54)],
        // tall bar, down from the right eye
        [(44, 34), (42.2, 38), (43.6, 43), (40.6, 47), (41.8, 51)],
        // tall bar, up from the right eye
        [(45, 26), (47, 22), (45.5, 18), (47.2, 14.5)],
        // left, out across the swoosh's arm and the palm
        [(19.5, 34), (14, 38), (15, 43), (9, 46), (8.5, 52)],
        // right, toward the right bar
        [(51.5, 31), (56, 33), (55, 38), (60, 41), (59, 47)],
        // from the nose notch down toward the mouth
        [(35.75, 46), (34.4, 52), (36.5, 56), (35, 60)],
    ]

    /// A thin ribbon around a polyline, tapering to 25 % of `width` at the far end. Closed polygon (left side out, right
    /// side back).
    static func ribbon(_ line: [CGPoint], width: CGFloat) -> [CGPoint] {
        let n = line.count
        guard n >= 2 else { return line }
        var left: [CGPoint] = [], right: [CGPoint] = []
        for i in 0..<n {
            let a = line[max(i - 1, 0)], b = line[min(i + 1, n - 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1e-6)
            let nx = -dy / len, ny = dx / len
            let w = width * (1 - 0.75 * CGFloat(i) / CGFloat(n - 1)) / 2
            left.append(CGPoint(x: line[i].x + nx * w, y: line[i].y + ny * w))
            right.append(CGPoint(x: line[i].x - nx * w, y: line[i].y - ny * w))
        }
        return left + right.reversed()
    }

    // MARK: Nodes

    /// The stencil as one node ("scareFace", hidden), children = one flat black `SCNShape` per piece, back faces 0.4 units
    /// in front of the fingers' surface (`fingerFront`).
    static func makeNode(fingerFront: CGFloat) -> SCNNode {
        let root = SCNNode()
        root.name = nodeName
        root.isHidden = true
        let black = SCNMaterial()
        black.lightingModel = .lambert  // no specular at all
        black.diffuse.contents = NSColor.black
        black.roughness.contents = NSNumber(value: 0.9)
        black.isDoubleSided = true
        for piece in pieces() {
            let path = NSBezierPath()
            for (i, p) in piece.polygon.enumerated() {
                if i == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: LogoMeshBuilder.Layer.stencilDepth)
            shape.chamferRadius = 0
            shape.materials = [black]
            let node = SCNNode(geometry: shape)
            node.name = piece.name
            LogoMeshBuilder.placeBack(node, at: fingerFront + LogoMeshBuilder.Layer.stencilBack)
            root.addChildNode(node)
        }
        return root
    }
}
