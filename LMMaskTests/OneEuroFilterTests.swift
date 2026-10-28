import XCTest
import simd
@testable import LMMask

final class OneEuroFilterTests: XCTestCase {
    private let dt = 1.0 / 30.0

    func testSmoothingFactorMatchesFormula() {
        // tau = 1/(2*pi*1) = 0.159155; tau/dt = 4.77465; alpha = 1/5.77465 = 0.173173
        XCTAssertEqual(OneEuroFilter.smoothingFactor(cutoff: 1, dt: 1.0 / 30), 0.173173, accuracy: 1e-4)
        // Higher cutoff -> larger alpha (less smoothing).
        XCTAssertGreaterThan(OneEuroFilter.smoothingFactor(cutoff: 10, dt: 1.0 / 30),
                             OneEuroFilter.smoothingFactor(cutoff: 1, dt: 1.0 / 30))
    }

    func testFirstSamplePassesThrough() {
        var f = OneEuroFilter()
        XCTAssertEqual(f.filter(3.5, timestamp: 0), 3.5)
    }

    func testStepResponseWithZeroBetaIsPlainEMA() {
        var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: 0, dCutoff: 1))
        _ = f.filter(0, timestamp: 0)
        let y1 = f.filter(1, timestamp: dt)
        XCTAssertEqual(y1, 0.173173, accuracy: 1e-4)
        let y2 = f.filter(1, timestamp: 2 * dt)
        XCTAssertEqual(y2, y1 + 0.173173 * (1 - y1), accuracy: 1e-4)
    }

    func testConstantInputConverges() {
        var f = OneEuroFilter()
        _ = f.filter(0, timestamp: 0)
        var y: Float = 0
        for i in 1...300 { y = f.filter(1, timestamp: Double(i) * dt) }
        XCTAssertEqual(y, 1, accuracy: 1e-3)
    }

    func testHigherBetaReducesLagOnRamp() {
        func finalLag(beta: Float) -> Float {
            var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: beta, dCutoff: 1))
            var y: Float = 0, x: Float = 0
            for i in 0..<90 {
                x = 10 * Float(Double(i) * dt)
                y = f.filter(x, timestamp: Double(i) * dt)
            }
            return x - y
        }
        XCTAssertLessThan(finalLag(beta: 0.5), finalLag(beta: 0))
    }

    func testRepeatedTimestampHoldsAndBackwardsTimeReseeds() {
        var f = OneEuroFilter()
        _ = f.filter(0, timestamp: 1)
        let a = f.filter(1, timestamp: 1 + dt)
        XCTAssertEqual(f.filter(100, timestamp: 1 + dt), a)
        XCTAssertEqual(f.filter(7, timestamp: 0.5), 7)  // backwards -> re-seed
    }

    func testResetReseeds() {
        var f = OneEuroFilter()
        _ = f.filter(0, timestamp: 0)
        f.reset()
        XCTAssertEqual(f.filter(5, timestamp: dt), 5)
    }

    // MARK: Quaternion

    func testQuaternionIdentityStaysIdentity() {
        var f = QuaternionOneEuroFilter()
        let q = simd_quatf(angle: 0.4, axis: SIMD3(0, 1, 0))
        for i in 0..<20 {
            let out = f.filter(q, timestamp: Double(i) * dt)
            XCTAssertEqual(abs(simd_dot(out.vector, q.vector)), 1, accuracy: 1e-5)
        }
    }

    func testQuaternionConvergesAndStaysUnit() {
        var f = QuaternionOneEuroFilter()
        _ = f.filter(simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)), timestamp: 0)
        let target = simd_quatf(angle: 1.0, axis: SIMD3(0, 0, 1))
        var out = target
        for i in 1...300 {
            out = f.filter(target, timestamp: Double(i) * dt)
            XCTAssertEqual(simd_length(out.vector), 1, accuracy: 1e-4)
        }
        XCTAssertEqual(abs(simd_dot(out.vector, target.vector)), 1, accuracy: 1e-4)
    }

    func testQuaternionAntipodalSampleDoesNotFlip() {
        var f = QuaternionOneEuroFilter()
        let q = simd_quatf(angle: 0.3, axis: SIMD3(1, 0, 0))
        _ = f.filter(q, timestamp: 0)
        let out = f.filter(simd_quatf(vector: -q.vector), timestamp: dt)  // same rotation
        XCTAssertEqual(abs(simd_dot(out.vector, q.vector)), 1, accuracy: 1e-5)
    }

    func testQuaternionStepMovesPartWay() {
        var f = QuaternionOneEuroFilter(parameters: .init(minCutoff: 1, beta: 0, dCutoff: 1))
        _ = f.filter(simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)), timestamp: 0)
        let out = f.filter(simd_quatf(angle: 1, axis: SIMD3(0, 1, 0)), timestamp: dt)
        // slerp by alpha=0.173 => rotation angle = 0.173 rad
        XCTAssertEqual(out.angle, 0.173173, accuracy: 1e-3)
    }

    // MARK: Transform

    func testTransformFirstSampleExactAndTranslationConverges() {
        var f = TransformOneEuroFilter()
        let rot = simd_quatf(angle: 0.5, axis: simd_normalize(SIMD3(1, 1, 0)))
        var m0 = simd_matrix4x4(rot); m0.columns.3 = SIMD4(0.1, 0.2, -0.6, 1)
        let first = f.filter(m0, timestamp: 0)
        for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(first[c][r], m0[c][r], accuracy: 1e-5) } }

        var m1 = m0; m1.columns.3 = SIMD4(0.3, -0.1, -0.8, 1)
        var out = first
        for i in 1...400 { out = f.filter(m1, timestamp: Double(i) * dt) }
        XCTAssertEqual(out.columns.3.x, 0.3, accuracy: 1e-3)
        XCTAssertEqual(out.columns.3.y, -0.1, accuracy: 1e-3)
        XCTAssertEqual(out.columns.3.z, -0.8, accuracy: 1e-3)
        XCTAssertEqual(out.columns.3.w, 1)
    }
}
