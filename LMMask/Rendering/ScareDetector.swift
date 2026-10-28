// ScareDetector.swift
// LM Mask - SCARE MODE logic, no SceneKit / Metal: the trigger (mouth wide open AND both eyes wide, held briefly, with
// hysteresis and a minimum on-time), the 0...1 `scareAmount` envelope every visual piece reads, and the small value
// types that carry the result to the renderer, the compositor and the debug HUD. Unit-tested in ScareDetectorTests.
//
// Time is always seconds on one monotonic clock (frame presentation time).

import Foundation
import simd

/// Decides, per frame, whether the user is "screaming": mouth open AND both eyes wide.
struct ScareDetector {

    struct Config: Equatable, Sendable {
        /// Trigger: mouth openness at least this (0...1, calibrated)...
        var mouthThreshold: Float = 0.7
        /// ...and BOTH eyes at least this (1 = the user's calibrated fully-open eye)...
        var eyeThreshold: Float = 0.92
        /// ...continuously for this long.
        var holdSeconds: Double = 0.12
        /// Hysteresis: once active, stay while mouth >= `mouthKeep` and both eyes >= `eyeKeep`.
        var mouthKeep: Float = 0.45
        var eyeKeep: Float = 0.6
        /// Release only after the keep-condition failed this long...
        var releaseHoldSeconds: Double = 0.3
        /// ...and never before the scare has been on this long (so a quick "boo" still reads).
        var minActiveSeconds: Double = 1.2

        init() {}
    }

    var config = Config()
    /// Test-scare button / debug: active regardless of the face while true.
    var forceScare = false

    private(set) var isActive = false
    /// 0...1: how far through `holdSeconds` the trigger condition is (for the HUD).
    private(set) var holdProgress: Float = 0

    private var armedSince: Double?
    private var lowSince: Double?
    private var activeSince: Double = 0

    init() {}

    /// Feeds one frame. Pass zeros when there is no face. Returns `isActive`.
    @discardableResult
    mutating func update(mouth: Float, leftEye: Float, rightEye: Float, time t: Double) -> Bool {
        let c = config
        let eyes = min(leftEye, rightEye)
        let trigger = mouth >= c.mouthThreshold && eyes >= c.eyeThreshold
        let keep = mouth >= c.mouthKeep && eyes >= c.eyeKeep

        if !isActive {
            if forceScare {
                activate(at: t)
                return true
            }
            if trigger {
                let since = armedSince ?? t
                armedSince = since
                holdProgress = c.holdSeconds > 0 ? Float(min(1, max(0, (t - since) / c.holdSeconds))) : 1
                if t - since >= c.holdSeconds { activate(at: t) }
            } else {
                armedSince = nil
                holdProgress = 0
            }
            return isActive
        }

        holdProgress = 1
        if forceScare || keep {
            lowSince = nil
        } else if lowSince == nil {
            lowSince = t
        }
        if let low = lowSince, t - low >= c.releaseHoldSeconds, t - activeSince >= c.minActiveSeconds {
            deactivate()
        }
        return isActive
    }

    /// Back to idle (used when scare mode is switched off).
    mutating func reset() { deactivate() }

    private mutating func activate(at t: Double) {
        isActive = true
        activeSince = t
        armedSince = nil
        lowSince = nil
        holdProgress = 1
    }

    private mutating func deactivate() {
        isActive = false
        armedSince = nil
        lowSince = nil
        holdProgress = 0
    }
}

extension ScareDetector.Config {
    init(_ s: MaskStyle.Scare) {
        self.init()
        mouthThreshold = Float(s.mouthThreshold)
        eyeThreshold = Float(s.eyeThreshold)
        holdSeconds = s.holdMs / 1000
        releaseHoldSeconds = s.releaseHoldMs / 1000
        minActiveSeconds = s.minActiveSeconds
    }
}

// MARK: - Envelope

/// The single `scareAmount` (0...1) that lights, materials, vignette, scale and flicker all read.
/// Onset: ease-out cubic over 80 ms (sudden). Release: ease-in-out over 600 ms.
struct ScareEnvelope {
    static let onsetSeconds = 0.08
    static let releaseSeconds = 0.6

    private(set) var amount: Float = 0
    private var from: Float = 0
    private var target: Float = 0
    private var start: Double = 0
    private var duration: Double = ScareEnvelope.releaseSeconds

    init() {}

    /// `preroll`: on the onset edge the curve is started that long ago, so the very first frame already shows progress
    /// (pass one frame interval; at 30 fps the first frame is then ~0.8 instead of 0).
    @discardableResult
    mutating func update(active: Bool, time t: Double, preroll: Double = 0) -> Float {
        let goal: Float = active ? 1 : 0
        if goal != target {
            from = amount
            target = goal
            start = t - (active ? max(0, preroll) : 0)
            duration = active ? Self.onsetSeconds : Self.releaseSeconds
        }
        let p = Float(min(1, max(0, (t - start) / duration)))
        let k: Float
        if active {
            let q = 1 - p
            k = 1 - q * q * q
        } else if p < 0.5 {
            k = 2 * p * p
        } else {
            let q = -2 * p + 2
            k = 1 - q * q / 2
        }
        amount = from + (target - from) * k
        return amount
    }

    /// Headpiece scale while the scare is on, `e` seconds after onset: 1 -> 1.12 over 80 ms (ease-out), then a damped
    /// spring settling at 1.05.
    static func pop(sinceOnset e: Double) -> Float {
        let peak: Float = 1.12, rest: Float = 1.05
        if e <= 0 { return 1 }
        if e < onsetSeconds {
            let q = Float(1 - e / onsetSeconds)
            return 1 + (peak - 1) * (1 - q * q * q)
        }
        let x = Float(e - onsetSeconds)
        return rest + (peak - rest) * exp(-9 * x) * cos(22 * x)
    }
}

// MARK: - Value types handed to the compositor and the HUD

/// What the compositor needs for one frame.
struct ScareFrame: Sendable, Equatable {
    /// 0...1 `scareAmount`.
    var amount: Float = 0
    /// 0...1 white-ish flash alpha (first two frames after onset).
    var flash: Float = 0
    /// Whole-frame offset in output pixels (first two frames after onset).
    var shake = SIMD2<Float>(0, 0)
    /// `MaskStyle.Scare.vignette`.
    var vignette: Float = 0
    /// ~1 +- 0.08, modulates the vignette like a flickering candle.
    var flicker: Float = 1

    static let none = ScareFrame()
}

/// Why the scare did or did not fire: shown in the debug HUD.
struct ScareReadout: Sendable, Equatable {
    var active = false
    var forced = false
    var enabled = true
    var amount: Float = 0
    var mouth: Float = 0
    var leftEye: Float = 0
    var rightEye: Float = 0
    var mouthThreshold: Float = 0.7
    var eyeThreshold: Float = 0.92
    var holdProgress: Float = 0
}
