// MaskStyle.swift
// LM Mask - every tunable of the inflatable "glove" headpiece in one Codable value.
//
// Units: lengths are SVG units (1 unit = 1 cm in the app, y down in the *_ SVG-coordinate fields), fractions are 0...1.
// Persisted as JSON in UserDefaults by `RenderPipeline`, edited live from the "Tune" inspector in `PreviewWindow`,
// and copy/pasteable as JSON so a tuned look can be sent back and baked into the defaults below.
//
// Sections (match the Tune panel): Inflatable, Vinyl, Print, Windows, Placement, Scare.
//
// Decoding is lenient: any missing key falls back to its default and every value is clamped to `Limits`, so a
// stored or pasted style from an older/newer build never fails to load.

import AppKit
import Foundation

/// "#RRGGBB" colour, encoded as a plain string in JSON.
struct HexColor: Codable, Equatable, Sendable {
    var hex: String

    init(_ hex: String) { self.hex = hex }

    init(from decoder: Decoder) throws {
        hex = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(hex)
    }

    /// sRGB components 0...1. Falls back to mid grey on a malformed string.
    var rgb: (r: Double, g: Double, b: Double) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return (0.5, 0.5, 0.5) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    var nsColor: NSColor {
        let c = rgb
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        hex = String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }
}

struct MaskStyle: Codable, Equatable, Sendable {

    // MARK: Inflatable (geometry: rebuilt after a ~150 ms pause, cheap)

    /// How far each island's outline is pushed outward to make its pillow ("finger"), SVG units.
    var fingerPad: Double = 2.0
    /// Thickness of a finger. The chamfer is half of it with a quarter-circle profile, so the cross-section is a tube.
    /// Default = the logo bars' own width (9.28: the swoosh run is 61.486...70.769).
    var fingerDepth: Double = 9.3
    /// Thickness of the palm (the body behind the fingers), SVG units. Its chamfer is half of it.
    var bodyDepth: Double = 16
    /// The palm's rounded rectangle in SVG coordinates (y down): x from `bodyLeft` to `bodyRight`, y from `bodyTop` to `bodyBottom`.
    var bodyLeft: Double = 2
    var bodyRight: Double = 70
    var bodyTop: Double = 34
    var bodyBottom: Double = 86
    /// Corner radius of the palm, SVG units.
    var cornerRadius: Double = 14
    /// Neck / collar pillow below the palm (y 80...100, wider).
    var showCollar = true

    // MARK: Vinyl (live)

    var bodyColor = HexColor("#F7F8FA")
    var roughness: Double = 0.22
    var clearcoat: Double = 0.8
    var clearcoatRoughness: Double = 0.15

    // MARK: Print (the blue logo printed on the fingers)

    /// Teal -> blue gradient on the prints; off = flat blue #009CE4.
    var printGradient = true
    /// How far the printed shape (and the windows) are pulled in from the finger's outline, SVG units.
    var printInset: Double = 0.6

    // MARK: Windows (live; the mouth window size needs a geometry rebuild)

    /// Blue tint over the live video seen through the eye and mouth windows.
    var tintColor = HexColor("#009CE4")
    var tintOpacity: Double = 0.42
    /// The swoosh's mouth window, SVG units.
    var mouthWindowWidth: Double = 22
    var mouthWindowHeight: Double = 8

    enum MouthMode: String, Codable, CaseIterable, Sendable {
        /// A sharp window in the swoosh showing the user's real mouth (compositor mouth pass).
        case window
        /// No mouth window: the swoosh is solid printed blue.
        case off
    }

    var mouthMode: MouthMode = .window

    // MARK: Placement (live)

    /// Sideways shift of the whole headpiece as a fraction of face height (positive = toward image right), applied
    /// along the mask's own right vector. The vertical shift is a pipeline setting (`verticalOffset`).
    var horizontalOffset: Double = 0

    // MARK: Scare mode (Halloween)

    /// Trigger, colours and strength of SCARE MODE (see `ScareDetector`, `ScareLook`, docs/rendering.md "Scare").
    var scare = Scare()

    // MARK: Limits

    enum Limits {
        static let fingerPad = 0.0...5.0
        static let fingerDepth = 4.0...16.0
        static let bodyDepth = 6.0...28.0
        static let bodyLeft = -10.0...30.0
        static let bodyRight = 45.0...85.0
        static let bodyTop = 20.0...60.0
        static let bodyBottom = 65.0...110.0
        static let cornerRadius = 2.0...30.0
        static let roughness = 0.05...1.0
        static let clearcoat = 0.0...1.0
        static let printInset = 0.0...2.0
        static let tintOpacity = 0.0...1.0
        static let mouthWindowWidth = 10.0...30.0
        static let mouthWindowHeight = 4.0...9.0
        static let horizontalOffset = -0.5...0.5
        static let scareMouthThreshold = 0.3...1.0
        static let scareEyeThreshold = 0.5...1.0
        static let scareHoldMs = 0.0...600.0
        static let scareReleaseHoldMs = 100.0...1000.0
        static let scareMinActive = 0.3...3.0
        static let scareVignette = 0.0...1.0
    }

    // MARK: Derived

    /// True when `other` differs in anything that changes geometry (not materials).
    func geometryDiffers(from o: MaskStyle) -> Bool {
        fingerPad != o.fingerPad || fingerDepth != o.fingerDepth || bodyDepth != o.bodyDepth
            || bodyLeft != o.bodyLeft || bodyRight != o.bodyRight || bodyTop != o.bodyTop || bodyBottom != o.bodyBottom
            || cornerRadius != o.cornerRadius || showCollar != o.showCollar || printInset != o.printInset
            || mouthWindowWidth != o.mouthWindowWidth || mouthWindowHeight != o.mouthWindowHeight
            || mouthMode != o.mouthMode
    }

    /// The palm rectangle in SVG coordinates (y down).
    var bodyRect: CGRect {
        CGRect(x: bodyLeft, y: bodyTop, width: bodyRight - bodyLeft, height: bodyBottom - bodyTop)
    }

    // MARK: Persistence and JSON

    static let defaultsKey = "lm.maskStyle.v3"  // v3: inflatable-glove rebuild; v2 styles describe a different model

    func clamped() -> MaskStyle {
        var s = self
        func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        s.fingerPad = c(fingerPad, Limits.fingerPad)
        s.fingerDepth = c(fingerDepth, Limits.fingerDepth)
        s.bodyDepth = c(bodyDepth, Limits.bodyDepth)
        s.bodyLeft = c(bodyLeft, Limits.bodyLeft)
        s.bodyRight = c(bodyRight, Limits.bodyRight)
        s.bodyTop = c(bodyTop, Limits.bodyTop)
        s.bodyBottom = c(bodyBottom, Limits.bodyBottom)
        s.cornerRadius = c(cornerRadius, Limits.cornerRadius)
        s.roughness = c(roughness, Limits.roughness)
        s.clearcoat = c(clearcoat, Limits.clearcoat)
        s.clearcoatRoughness = c(clearcoatRoughness, Limits.roughness)
        s.printInset = c(printInset, Limits.printInset)
        s.tintOpacity = c(tintOpacity, Limits.tintOpacity)
        s.mouthWindowWidth = c(mouthWindowWidth, Limits.mouthWindowWidth)
        s.mouthWindowHeight = c(mouthWindowHeight, Limits.mouthWindowHeight)
        s.horizontalOffset = c(horizontalOffset, Limits.horizontalOffset)
        s.scare = scare.clamped()
        return s
    }

    var jsonString: String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func decode(json: String) -> MaskStyle? {
        guard let data = json.data(using: .utf8),
              let s = try? JSONDecoder().decode(MaskStyle.self, from: data) else { return nil }
        return s.clamped()
    }

    static func load(from defaults: UserDefaults = .standard) -> MaskStyle {
        guard let data = defaults.data(forKey: defaultsKey),
              let s = try? JSONDecoder().decode(MaskStyle.self, from: data) else { return MaskStyle() }
        return s.clamped()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Codable (lenient)

    init() {}

    enum CodingKeys: String, CodingKey {
        case fingerPad, fingerDepth, bodyDepth, bodyLeft, bodyRight, bodyTop, bodyBottom, cornerRadius, showCollar
        case bodyColor, roughness, clearcoat, clearcoatRoughness
        case printGradient, printInset
        case tintColor, tintOpacity, mouthWindowWidth, mouthWindowHeight, mouthMode
        case horizontalOffset
        case scare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MaskStyle()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
        fingerPad = v(.fingerPad, d.fingerPad)
        fingerDepth = v(.fingerDepth, d.fingerDepth)
        bodyDepth = v(.bodyDepth, d.bodyDepth)
        bodyLeft = v(.bodyLeft, d.bodyLeft)
        bodyRight = v(.bodyRight, d.bodyRight)
        bodyTop = v(.bodyTop, d.bodyTop)
        bodyBottom = v(.bodyBottom, d.bodyBottom)
        cornerRadius = v(.cornerRadius, d.cornerRadius)
        showCollar = v(.showCollar, d.showCollar)
        bodyColor = v(.bodyColor, d.bodyColor)
        roughness = v(.roughness, d.roughness)
        clearcoat = v(.clearcoat, d.clearcoat)
        clearcoatRoughness = v(.clearcoatRoughness, d.clearcoatRoughness)
        printGradient = v(.printGradient, d.printGradient)
        printInset = v(.printInset, d.printInset)
        tintColor = v(.tintColor, d.tintColor)
        tintOpacity = v(.tintOpacity, d.tintOpacity)
        mouthWindowWidth = v(.mouthWindowWidth, d.mouthWindowWidth)
        mouthWindowHeight = v(.mouthWindowHeight, d.mouthWindowHeight)
        mouthMode = v(.mouthMode, d.mouthMode)
        horizontalOffset = v(.horizontalOffset, d.horizontalOffset)
        scare = v(.scare, d.scare)
    }
}

// MARK: - Scare settings

extension MaskStyle {
    /// SCARE MODE: thresholds (0...1 of the user's calibrated range), timing, colours, strength. Decoded leniently like
    /// the rest of the style.
    struct Scare: Codable, Equatable, Sendable {
        var enabled = true
        /// Mouth openness that triggers (and eyes, both, as a fraction of calibrated fully-open).
        var mouthThreshold: Double = 0.7
        var eyeThreshold: Double = 0.92
        /// Both must hold this long before the scare fires.
        var holdMs: Double = 120
        /// Below the keep levels (mouth 0.45, eyes 0.6) for this long to release.
        var releaseHoldMs: Double = 300
        /// A scare never lasts shorter than this.
        var minActiveSeconds: Double = 1.2
        /// The blue prints turn this colour (the windows go #000000, the demon stencil is #000000).
        var printColor = HexColor("#0A0A0C")
        /// Dark edge vignette strength, 0...1.
        var vignette: Double = 0.8

        init() {}

        enum CodingKeys: String, CodingKey {
            case enabled, mouthThreshold, eyeThreshold, holdMs, releaseHoldMs, minActiveSeconds, printColor, vignette
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Scare()
            func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? fallback }
            enabled = v(.enabled, d.enabled)
            mouthThreshold = v(.mouthThreshold, d.mouthThreshold)
            eyeThreshold = v(.eyeThreshold, d.eyeThreshold)
            holdMs = v(.holdMs, d.holdMs)
            releaseHoldMs = v(.releaseHoldMs, d.releaseHoldMs)
            minActiveSeconds = v(.minActiveSeconds, d.minActiveSeconds)
            printColor = v(.printColor, d.printColor)
            vignette = v(.vignette, d.vignette)
        }

        func clamped() -> Scare {
            var s = self
            func c(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
            s.mouthThreshold = c(mouthThreshold, Limits.scareMouthThreshold)
            s.eyeThreshold = c(eyeThreshold, Limits.scareEyeThreshold)
            s.holdMs = c(holdMs, Limits.scareHoldMs)
            s.releaseHoldMs = c(releaseHoldMs, Limits.scareReleaseHoldMs)
            s.minActiveSeconds = c(minActiveSeconds, Limits.scareMinActive)
            s.vignette = c(vignette, Limits.scareVignette)
            return s
        }
    }
}
