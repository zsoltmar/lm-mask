import Foundation
import simd

// One-Euro filter: Casiez, Roussel, Vogel, "1 Euro Filter", CHI 2012.
// https://gery.casiez.net/1euro/
//
// All types are value types, Sendable and allocation-free per sample.

/// Tunable parameters shared by the scalar, quaternion and transform filters.
struct OneEuroParameters: Sendable, Equatable {
    /// Minimum cutoff frequency in Hz. Lower = smoother at rest, more lag.
    var minCutoff: Float = 1.0
    /// Speed coefficient. Higher = less lag during fast motion, more jitter.
    var beta: Float = 0.02
    /// Cutoff frequency (Hz) used to low-pass the derivative.
    var dCutoff: Float = 1.0

    static let `default` = OneEuroParameters()
}

/// Exponential smoothing factor for a given cutoff and timestep:
/// alpha = 1 / (1 + tau / dt), tau = 1 / (2 pi cutoff).
@inline(__always)
func oneEuroAlpha(cutoff: Float, dt: Float) -> Float {
    let tau = 1 / (2 * Float.pi * cutoff)
    return 1 / (1 + tau / dt)
}

// MARK: - Scalar

struct OneEuroFilter: Sendable {
    var parameters: OneEuroParameters

    private var hasValue = false
    private var prevRaw: Float = 0
    private var prevFiltered: Float = 0
    private var prevDerivative: Float = 0
    private var prevTime: Double = 0

    init(parameters: OneEuroParameters = .default) {
        self.parameters = parameters
    }

    /// Public for tests and tuning tools.
    static func smoothingFactor(cutoff: Float, dt: Float) -> Float {
        oneEuroAlpha(cutoff: cutoff, dt: dt)
    }

    mutating func reset() { hasValue = false }

    /// - Parameters:
    ///   - x: raw sample.
    ///   - timestamp: seconds, monotonic. A backwards jump re-seeds the filter;
    ///     a repeated timestamp returns the previous output.
    mutating func filter(_ x: Float, timestamp: Double) -> Float {
        guard hasValue else { return seed(x, timestamp) }
        let dt = Float(timestamp - prevTime)
        if dt < 0 { return seed(x, timestamp) }
        if dt < 1e-6 { return prevFiltered }

        let derivative = (x - prevRaw) / dt
        let dAlpha = oneEuroAlpha(cutoff: parameters.dCutoff, dt: dt)
        let dHat = prevDerivative + dAlpha * (derivative - prevDerivative)

        let cutoff = parameters.minCutoff + parameters.beta * abs(dHat)
        let alpha = oneEuroAlpha(cutoff: cutoff, dt: dt)
        let xHat = prevFiltered + alpha * (x - prevFiltered)

        prevRaw = x
        prevFiltered = xHat
        prevDerivative = dHat
        prevTime = timestamp
        return xHat
    }

    private mutating func seed(_ x: Float, _ t: Double) -> Float {
        hasValue = true
        prevRaw = x
        prevFiltered = x
        prevDerivative = 0
        prevTime = t
        return x
    }
}

// MARK: - Quaternion

/// One-Euro filter on unit quaternions. "Speed" is angular speed in rad/s;
/// smoothing is a slerp toward the new sample by alpha.
struct QuaternionOneEuroFilter: Sendable {
    var parameters: OneEuroParameters

    private var hasValue = false
    private var prevFiltered = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    private var prevRate: Float = 0
    private var prevTime: Double = 0

    init(parameters: OneEuroParameters = .default) {
        self.parameters = parameters
    }

    mutating func reset() { hasValue = false }

    mutating func filter(_ qIn: simd_quatf, timestamp: Double) -> simd_quatf {
        var q = simd_normalize(qIn)
        guard hasValue else { return seed(q, timestamp) }
        let dt = Float(timestamp - prevTime)
        if dt < 0 { return seed(q, timestamp) }
        if dt < 1e-6 { return prevFiltered }

        // q and -q are the same rotation; pick the hemisphere nearest the previous output.
        var d = simd_dot(prevFiltered.vector, q.vector)
        if d < 0 { q = simd_quatf(vector: -q.vector); d = -d }

        let angle = 2 * acos(min(1, d))  // radians between prev output and raw sample
        let rate = angle / dt
        let dAlpha = oneEuroAlpha(cutoff: parameters.dCutoff, dt: dt)
        let rateHat = prevRate + dAlpha * (rate - prevRate)

        let cutoff = parameters.minCutoff + parameters.beta * rateHat
        let alpha = oneEuroAlpha(cutoff: cutoff, dt: dt)
        let out = simd_normalize(simd_slerp(prevFiltered, q, alpha))

        prevFiltered = out
        prevRate = rateHat
        prevTime = timestamp
        return out
    }

    private mutating func seed(_ q: simd_quatf, _ t: Double) -> simd_quatf {
        hasValue = true
        prevFiltered = q
        prevRate = 0
        prevTime = t
        return q
    }
}

// MARK: - Rigid transform

/// Filters a rigid (rotation + translation, no scale) 4x4 transform:
/// translation per axis with scalar filters, rotation with the quaternion filter.
struct TransformOneEuroFilter: Sendable {
    private var tx: OneEuroFilter
    private var ty: OneEuroFilter
    private var tz: OneEuroFilter
    private var rotation: QuaternionOneEuroFilter

    init(translation: OneEuroParameters = .default, rotation: OneEuroParameters = .default) {
        tx = OneEuroFilter(parameters: translation)
        ty = OneEuroFilter(parameters: translation)
        tz = OneEuroFilter(parameters: translation)
        self.rotation = QuaternionOneEuroFilter(parameters: rotation)
    }

    mutating func reset() {
        tx.reset(); ty.reset(); tz.reset(); rotation.reset()
    }

    mutating func filter(_ m: simd_float4x4, timestamp: Double) -> simd_float4x4 {
        let r = simd_float3x3(
            SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
            SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
            SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let q = rotation.filter(simd_quatf(r), timestamp: timestamp)
        var out = simd_matrix4x4(q)
        out.columns.3 = SIMD4(
            tx.filter(m.columns.3.x, timestamp: timestamp),
            ty.filter(m.columns.3.y, timestamp: timestamp),
            tz.filter(m.columns.3.z, timestamp: timestamp),
            1)
        return out
    }
}
