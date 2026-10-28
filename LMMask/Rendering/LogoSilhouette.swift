// LogoSilhouette.swift
// LM Mask - the 2D outlines the inflatable is extruded from. Pure value types and plain polygon maths, safe on any thread,
// well under a millisecond (no rasterising, no Vision, no Core Image).
//
//  - the four logo islands (short bar, tall bar, swoosh, right bar), flattened from the SVG path data
//  - each island pushed OUTWARD by `fingerPad` (the finger's pillow outline) and INWARD by `printInset` (the printed shape)
//  - rounded rectangles for the palm and the collar
//
// Offsetting moves every vertex along the mitred normal of its two edges. That is exact for the logo's smooth, convex-ish
// islands (the swoosh's inner corner has a radius of ~10 units, far more than the 2 unit pad) and needs no clipping.
//
// Frame: centred, y up, SVG units (see `SVGPathParser.centered`). Every polygon is closed (last point connects to the first)
// and counter-clockwise, which is what `SCNShape` wants for an outward-facing front.

import CoreGraphics
import Foundation

enum LogoSilhouette {

    /// One logo island in the three outlines the builder needs.
    struct Island: Sendable, Equatable {
        /// `LogoMeshBuilder.NodeName.barShort` ... `.barRight`.
        var name: String
        /// The island exactly as drawn in the SVG.
        var outline: [CGPoint]
        /// `outline` grown by `fingerPad`: the pillow.
        var padded: [CGPoint]
        /// `outline` shrunk by `printInset`: the printed shape / window.
        var inset: [CGPoint]
    }

    struct Outline: Sendable, Equatable {
        var islands: [Island]
        var pad: Double
        var inset: Double

        func island(_ name: String) -> Island? { islands.first { $0.name == name } }

        /// One-line description for the log.
        var summary: String {
            islands.map { i in
                let b = LogoSilhouette.bounds(of: i.padded)
                return String(format: "%@ %.1fx%.1f", i.name, Double(b.width), Double(b.height))
            }.joined(separator: ", ")
        }
    }

    enum BuildError: Error { case unexpectedIslandCount(Int) }

    /// Step of the flattening of straight edges, so vertex normals (and the chamfer) behave along long lines.
    private static let maxEdge: CGFloat = 1.5

    // MARK: Build

    /// The four islands with their padded and inset outlines. Throws only if the embedded path data is malformed.
    static func build(pad: Double, inset: Double) throws -> Outline {
        let subpaths = try SVGPathParser.parse(LogoMeshBuilder.markPathData)
        guard subpaths.count == 4 else { throw BuildError.unexpectedIslandCount(subpaths.count) }
        let polygons = subpaths.map { counterClockwise(flatten($0).map(SVGPathParser.centered)) }
        let named = classify(polygons)
        let islands = named.map { (name, poly) in
            Island(name: name, outline: poly,
                   padded: offset(poly, by: CGFloat(pad)),
                   inset: offset(poly, by: -CGFloat(inset)))
        }
        return Outline(islands: islands, pad: pad, inset: inset)
    }

    /// bar_right = tallest; swoosh = widest of the rest; bar_short = shortest of the rest; bar_tall = remaining.
    static func classify(_ polys: [[CGPoint]]) -> [(String, [CGPoint])] {
        var rest = polys
        let right = rest.remove(at: rest.indices.max { bounds(of: rest[$0]).height < bounds(of: rest[$1]).height }!)
        let swoosh = rest.remove(at: rest.indices.max { bounds(of: rest[$0]).width < bounds(of: rest[$1]).width }!)
        let short = rest.remove(at: rest.indices.min { bounds(of: rest[$0]).height < bounds(of: rest[$1]).height }!)
        let tall = rest[0]
        return [(LogoMeshBuilder.NodeName.barShort, short), (LogoMeshBuilder.NodeName.barTall, tall),
                (LogoMeshBuilder.NodeName.swoosh, swoosh), (LogoMeshBuilder.NodeName.barRight, right)]
    }

    // MARK: Shapes

    /// Rounded rectangle given in SVG coordinates (y down), returned centred / y up / counter-clockwise.
    /// The radius is clamped to half the shorter side.
    static func roundedRect(svg rect: CGRect, radius: Double) -> [CGPoint] {
        let r = CGFloat(max(0.01, min(radius, Double(min(rect.width, rect.height)) / 2)))
        let steps = 12
        // Corner centres and the start angle of each quarter arc, walking clockwise on screen (SVG, y down).
        let corners: [(c: CGPoint, a0: CGFloat)] = [
            (CGPoint(x: rect.minX + r, y: rect.minY + r), .pi),            // top-left
            (CGPoint(x: rect.maxX - r, y: rect.minY + r), 1.5 * .pi),      // top-right
            (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 0),              // bottom-right
            (CGPoint(x: rect.minX + r, y: rect.maxY - r), 0.5 * .pi),      // bottom-left
        ]
        var pts: [CGPoint] = []
        for corner in corners {
            for i in 0...steps {
                let a = corner.a0 + (.pi / 2) * CGFloat(i) / CGFloat(steps)
                pts.append(CGPoint(x: corner.c.x + r * cos(a), y: corner.c.y + r * sin(a)))
            }
        }
        return counterClockwise(pts.map(SVGPathParser.centered))
    }

    // MARK: Polygon maths

    static func bounds(of p: [CGPoint]) -> CGRect {
        guard let f = p.first else { return .zero }
        var lo = f, hi = f
        for q in p { lo.x = min(lo.x, q.x); lo.y = min(lo.y, q.y); hi.x = max(hi.x, q.x); hi.y = max(hi.y, q.y) }
        return CGRect(x: lo.x, y: lo.y, width: hi.x - lo.x, height: hi.y - lo.y)
    }

    /// Signed area in a y-up frame: positive = counter-clockwise.
    static func signedArea(_ p: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        for i in 0..<p.count {
            let u = p[i], v = p[(i + 1) % p.count]
            a += u.x * v.y - v.x * u.y
        }
        return a / 2
    }

    static func counterClockwise(_ p: [CGPoint]) -> [CGPoint] { signedArea(p) < 0 ? Array(p.reversed()) : p }

    /// Moves a counter-clockwise polygon's edges outward by `d` (negative = inward). Vertices follow the mitred normal; the
    /// miter is limited to 2 x `d` so sharp corners cannot spike.
    static func offset(_ p: [CGPoint], by d: CGFloat) -> [CGPoint] {
        let n = p.count
        guard n >= 3, abs(d) > 1e-6 else { return p }
        func normal(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1e-9)
            return CGPoint(x: dy / len, y: -dx / len)  // right of the travel direction = outside of a CCW polygon
        }
        var out: [CGPoint] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let prev = p[(i + n - 1) % n], cur = p[i], next = p[(i + 1) % n]
            let n1 = normal(prev, cur), n2 = normal(cur, next)
            var m = CGPoint(x: n1.x + n2.x, y: n1.y + n2.y)
            let ml = hypot(m.x, m.y)
            guard ml > 1e-6 else { out.append(CGPoint(x: cur.x + n1.x * d, y: cur.y + n1.y * d)); continue }
            m = CGPoint(x: m.x / ml, y: m.y / ml)
            let cosHalf = max(m.x * n1.x + m.y * n1.y, 0.5)
            out.append(CGPoint(x: cur.x + m.x * d / cosHalf, y: cur.y + m.y * d / cosHalf))
        }
        return out
    }

    /// Flattens one closed SVG subpath (raw SVG coordinates) to a polygon: cubics in 0.8-unit steps (at least 8), long lines
    /// cut to at most `maxEdge`. The duplicate closing point is dropped.
    static func flatten(_ sub: SVGPathParser.Subpath) -> [CGPoint] {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero
        func add(_ q: CGPoint) {
            if let l = pts.last, hypot(q.x - l.x, q.y - l.y) < 1e-4 { return }
            pts.append(q)
        }
        func line(to q: CGPoint) {
            let len = hypot(q.x - cur.x, q.y - cur.y)
            let k = max(1, Int((len / maxEdge).rounded(.up)))
            for i in 1...k {
                let t = CGFloat(i) / CGFloat(k)
                add(CGPoint(x: cur.x + (q.x - cur.x) * t, y: cur.y + (q.y - cur.y) * t))
            }
            cur = q
        }
        for s in sub.segments {
            switch s {
            case .move(let a):
                add(a); cur = a
            case .line(let a):
                line(to: a)
            case .cubic(let c1, let c2, let e):
                let approx = hypot(c1.x - cur.x, c1.y - cur.y) + hypot(c2.x - c1.x, c2.y - c1.y) + hypot(e.x - c2.x, e.y - c2.y)
                let k = max(8, Int((approx / 0.8).rounded(.up)))
                let p0 = cur
                for i in 1...k {
                    let t = CGFloat(i) / CGFloat(k), u = 1 - t
                    let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x
                    let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y
                    add(CGPoint(x: x, y: y))
                }
                cur = e
            case .close:
                break
            }
        }
        if pts.count > 1, let f = pts.first, let l = pts.last, hypot(f.x - l.x, f.y - l.y) < 1e-3 { pts.removeLast() }
        return pts
    }
}
