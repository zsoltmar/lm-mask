// SVGPathParser.swift
// LM Mask - minimal SVG path-data parser used by the in-code logo fallback.
//
// Supports M/m, L/l, H/h, V/v, C/c, S/s, Q/q, Z/z (absolute and relative, with implicit
// command repetition). Elliptical arcs (A/a) are NOT supported and throw.
//
// SVG path grammar: https://www.w3.org/TR/SVG11/paths.html#PathData
// NSBezierPath:     https://developer.apple.com/documentation/appkit/nsbezierpath
// CGPath:           https://developer.apple.com/documentation/coregraphics/cgpath

import AppKit
import CoreGraphics
import Foundation

/// Pure value-type parser; safe to call from any thread.
struct SVGPathParser {

    // MARK: Types

    enum Segment: Sendable, Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint) // control1, control2, end
        case close
    }

    /// One closed subpath ("island"). Always begins with `.move` and ends with `.close`.
    struct Subpath: Sendable, Equatable {
        var segments: [Segment] = []

        /// Builds an `NSBezierPath`, applying `transform` to every point.
        func bezierPath(transform: (CGPoint) -> CGPoint = { $0 }) -> NSBezierPath {
            let p = NSBezierPath()
            for s in segments {
                switch s {
                case .move(let a): p.move(to: transform(a))
                case .line(let a): p.line(to: transform(a))
                case .cubic(let c1, let c2, let a):
                    p.curve(to: transform(a), controlPoint1: transform(c1), controlPoint2: transform(c2))
                case .close: p.close()
                }
            }
            return p
        }

        /// Builds a `CGPath`, applying `transform` to every point.
        func cgPath(transform: (CGPoint) -> CGPoint = { $0 }) -> CGPath {
            let p = CGMutablePath()
            for s in segments {
                switch s {
                case .move(let a): p.move(to: transform(a))
                case .line(let a): p.addLine(to: transform(a))
                case .cubic(let c1, let c2, let a):
                    p.addCurve(to: transform(a), control1: transform(c1), control2: transform(c2))
                case .close: p.closeSubpath()
                }
            }
            return p
        }
    }

    enum ParseError: Error, Equatable {
        case unexpectedCharacter(Character)
        case missingNumber(command: Character)
        case unsupportedCommand(Character)
        case noCurrentPoint
    }

    // MARK: Mark frame

    /// The mark's SVG viewBox size (`viewBox="0 0 72.307 71.885"`).
    static let viewBoxSize = CGSize(width: 72.307, height: 71.885)

    /// Maps an SVG point (origin top-left, +y down) to the centred frame (origin at the
    /// viewBox centre, +y up). 1 unit is still 1 SVG unit (= 1 cm in the app).
    static func centered(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - viewBoxSize.width / 2, y: -(p.y - viewBoxSize.height / 2))
    }

    // MARK: Convenience

    /// Parses `d` and returns closed `NSBezierPath`s in the centred, y-up frame.
    static func centeredBezierPaths(from d: String) throws -> [NSBezierPath] {
        try parse(d).map { $0.bezierPath(transform: centered) }
    }

    /// Parses `d` and returns closed `CGPath`s in the centred, y-up frame.
    static func centeredCGPaths(from d: String) throws -> [CGPath] {
        try parse(d).map { $0.cgPath(transform: centered) }
    }

    // MARK: Parser

    /// Parses SVG path data into closed subpaths in raw SVG coordinates (y down).
    static func parse(_ d: String) throws -> [Subpath] {
        var parser = Impl(chars: Array(d))
        return try parser.run()
    }

    private struct Impl {
        let chars: [Character]
        var i = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var hasCurrent = false
        var needsMove = false
        var lastCubicControl: CGPoint? // for S
        var lastQuadControl: CGPoint?  // for T (unused) / Q bookkeeping
        var open = Subpath()
        var done: [Subpath] = []

        init(chars: [Character]) { self.chars = chars }

        mutating func run() throws -> [Subpath] {
            var cmd: Character?
            while true {
                skipSeparators()
                if i >= chars.count { break }
                let c = chars[i]
                if c.isLetter {
                    cmd = c
                    i += 1
                    if c == "Z" || c == "z" {
                        close()
                        continue
                    }
                } else if cmd == nil || cmd == "Z" || cmd == "z" {
                    throw ParseError.unexpectedCharacter(c)
                }
                guard let active = cmd else { throw ParseError.unexpectedCharacter(c) }
                try execute(active)
                // Extra coordinate pairs after M/m are implicit L/l.
                if active == "M" { cmd = "L" } else if active == "m" { cmd = "l" }
            }
            flush()
            return done
        }

        // MARK: Lexing

        mutating func skipSeparators() {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
        }

        mutating func number(_ cmd: Character) throws -> CGFloat {
            skipSeparators()
            let begin = i
            if i < chars.count, chars[i] == "+" || chars[i] == "-" { i += 1 }
            var digits = 0
            while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
            if i < chars.count, chars[i] == "." {
                i += 1
                while i < chars.count, chars[i].isASCII, chars[i].isNumber { i += 1; digits += 1 }
            }
            guard digits > 0 else { i = begin; throw ParseError.missingNumber(command: cmd) }
            if i < chars.count, chars[i] == "e" || chars[i] == "E" {
                var j = i + 1
                if j < chars.count, chars[j] == "+" || chars[j] == "-" { j += 1 }
                if j < chars.count, chars[j].isASCII, chars[j].isNumber {
                    while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
                    i = j
                }
            }
            guard let v = Double(String(chars[begin..<i])) else { throw ParseError.missingNumber(command: cmd) }
            return CGFloat(v)
        }

        mutating func point(_ cmd: Character, relative: Bool, base: CGPoint) throws -> CGPoint {
            let x = try number(cmd)
            let y = try number(cmd)
            return relative ? CGPoint(x: base.x + x, y: base.y + y) : CGPoint(x: x, y: y)
        }

        // MARK: Emit

        mutating func flush() {
            if !open.segments.isEmpty {
                if open.segments.last != .close { open.segments.append(.close) }
                done.append(open)
            }
            open = Subpath()
        }

        mutating func close() {
            guard hasCurrent else { return }
            if !open.segments.isEmpty {
                open.segments.append(.close)
                done.append(open)
            }
            open = Subpath()
            current = start
            needsMove = true
            lastCubicControl = nil
        }

        /// Ensures a `.move` begins the open subpath (needed after Z without a new M).
        mutating func ensureMove() throws {
            guard hasCurrent else { throw ParseError.noCurrentPoint }
            if needsMove || open.segments.isEmpty {
                open.segments.append(.move(current))
                start = current
                needsMove = false
            }
        }

        // MARK: Commands

        mutating func execute(_ cmd: Character) throws {
            let rel = cmd.isLowercase
            let base = current
            switch cmd {
            case "M", "m":
                let p = try point(cmd, relative: rel, base: hasCurrent ? base : .zero)
                flush()
                open.segments.append(.move(p))
                current = p; start = p; hasCurrent = true; needsMove = false
                lastCubicControl = nil
            case "L", "l":
                let p = try point(cmd, relative: rel, base: base)
                try ensureMove()
                open.segments.append(.line(p))
                current = p; lastCubicControl = nil
            case "H", "h":
                let x = try number(cmd)
                let p = CGPoint(x: rel ? base.x + x : x, y: base.y)
                try ensureMove()
                open.segments.append(.line(p))
                current = p; lastCubicControl = nil
            case "V", "v":
                let y = try number(cmd)
                let p = CGPoint(x: base.x, y: rel ? base.y + y : y)
                try ensureMove()
                open.segments.append(.line(p))
                current = p; lastCubicControl = nil
            case "C", "c":
                let c1 = try point(cmd, relative: rel, base: base)
                let c2 = try point(cmd, relative: rel, base: base)
                let p = try point(cmd, relative: rel, base: base)
                try ensureMove()
                open.segments.append(.cubic(c1, c2, p))
                current = p; lastCubicControl = c2
            case "S", "s":
                let c2 = try point(cmd, relative: rel, base: base)
                let p = try point(cmd, relative: rel, base: base)
                let c1 = lastCubicControl.map { CGPoint(x: 2 * base.x - $0.x, y: 2 * base.y - $0.y) } ?? base
                try ensureMove()
                open.segments.append(.cubic(c1, c2, p))
                current = p; lastCubicControl = c2
            case "Q", "q":
                let q = try point(cmd, relative: rel, base: base)
                let p = try point(cmd, relative: rel, base: base)
                // Quadratic -> cubic: https://en.wikipedia.org/wiki/B%C3%A9zier_curve#Degree_elevation
                let c1 = CGPoint(x: base.x + 2.0 / 3.0 * (q.x - base.x), y: base.y + 2.0 / 3.0 * (q.y - base.y))
                let c2 = CGPoint(x: p.x + 2.0 / 3.0 * (q.x - p.x), y: p.y + 2.0 / 3.0 * (q.y - p.y))
                try ensureMove()
                open.segments.append(.cubic(c1, c2, p))
                current = p; lastCubicControl = nil
            default:
                if cmd == "A" || cmd == "a" || cmd == "T" || cmd == "t" { throw ParseError.unsupportedCommand(cmd) }
                throw ParseError.unexpectedCharacter(cmd)
            }
        }
    }
}
