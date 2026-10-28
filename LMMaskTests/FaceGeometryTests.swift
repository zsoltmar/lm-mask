import XCTest
import simd
@testable import LMMask

final class FaceGeometryTests: XCTestCase {
    private func ellipse(a: Float, b: Float, rotation: Float = 0, n: Int = 8) -> [SIMD2<Float>] {
        (0..<n).map { k in
            let t = Float(k) * 2 * .pi / Float(n)
            let p = SIMD2(a * cos(t), b * sin(t))
            return SIMD2(p.x * cos(rotation) - p.y * sin(rotation), p.x * sin(rotation) + p.y * cos(rotation))
        }
    }

    func testEARForSyntheticEye() throws {
        // corners at (+-1, 0); highest/lowest points at +-0.25 -> h = 0.5, w = 2 -> 0.25
        let m = try XCTUnwrap(EyeGeometry.measure(ellipse(a: 1, b: 0.25)))
        XCTAssertEqual(m.ear, 0.25, accuracy: 1e-4)
        XCTAssertEqual(m.width, 2, accuracy: 1e-4)
        XCTAssertEqual(m.center.x, 0, accuracy: 1e-4)
    }

    func testEARIsRotationAndOrderInvariant() throws {
        let base = ellipse(a: 1, b: 0.25)
        let rotated = ellipse(a: 1, b: 0.25, rotation: 0.6).reversed() as [SIMD2<Float>]
        let a = try XCTUnwrap(EyeGeometry.measure(base)).ear
        let b = try XCTUnwrap(EyeGeometry.measure(rotated)).ear
        XCTAssertEqual(a, b, accuracy: 1e-4)
    }

    func testClosedEyeHasSmallEAR() throws {
        let open = try XCTUnwrap(EyeGeometry.measure(ellipse(a: 1, b: 0.3))).ear
        let closed = try XCTUnwrap(EyeGeometry.measure(ellipse(a: 1, b: 0.05))).ear
        XCTAssertLessThan(closed, 0.4 * open)
    }

    func testOpennessMapping() {
        XCTAssertEqual(EyeGeometry.openness(ear: 0.30, open: 0.30, closedRatio: 0.4), 1, accuracy: 1e-5)
        XCTAssertEqual(EyeGeometry.openness(ear: 0.12, open: 0.30, closedRatio: 0.4), 0, accuracy: 1e-5)
        XCTAssertEqual(EyeGeometry.openness(ear: 0.21, open: 0.30, closedRatio: 0.4), 0.5, accuracy: 1e-5)
        XCTAssertEqual(EyeGeometry.openness(ear: 0.9, open: 0.30, closedRatio: 0.4), 1)  // clamp
    }

    func testDepthFromIPD() {
        let f = HeadPoseGeometry.focalLengthPixels(imageWidth: 1280)
        XCTAssertEqual(f, 1108.5125, accuracy: 0.01)
        // At 1 m, 63 mm IPD projects to f * 0.063 px.
        XCTAssertEqual(HeadPoseGeometry.depth(interPupillaryPixels: f * 0.063, yaw: 0, focalLengthPixels: f),
                       1.0, accuracy: 1e-3)
        // Turned 45 deg, projected IPD is cos(45) as large; depth must still come out 1 m.
        XCTAssertEqual(HeadPoseGeometry.depth(interPupillaryPixels: f * 0.063 * cos(.pi / 4), yaw: .pi / 4,
                                              focalLengthPixels: f), 1.0, accuracy: 1e-3)
    }

    func testBackProjection() {
        let f: Float = 1000
        let p = HeadPoseGeometry.cameraSpacePosition(pixel: SIMD2(640 + 100, 360 - 50), depth: 2,
                                                     focalLengthPixels: f, imageSize: SIMD2(1280, 720))
        XCTAssertEqual(p.x, 0.2, accuracy: 1e-5)   // right of center -> +x
        XCTAssertEqual(p.y, 0.1, accuracy: 1e-5)   // above center (smaller pixel y) -> +y
        XCTAssertEqual(p.z, -2, accuracy: 1e-5)    // in front of camera -> -z
    }

    func testIdentityPoseFacesCamera() {
        let m = HeadPoseGeometry.transform(position: SIMD3(0, 0, -1), roll: 0, yaw: 0, pitch: 0)
        XCTAssertEqual(m.columns.2.z, 1, accuracy: 1e-6)  // head +z (forward out of face) = camera +z
        XCTAssertEqual(m.columns.3.z, -1, accuracy: 1e-6)
    }

    func testBlinkDetectorHysteresis() {
        var d = BlinkDetector()
        XCTAssertNil(d.update(left: 1, right: 1, time: 0).left)
        XCTAssertNil(d.update(left: 0.1, right: 1, time: 0.1).left)   // closes
        XCTAssertNil(d.update(left: 0.45, right: 1, time: 0.15).left) // in hysteresis band, still closed
        let ev = d.update(left: 0.9, right: 1, time: 0.2).left        // reopens
        XCTAssertEqual(ev?.eye, .left)
        XCTAssertEqual(ev?.duration ?? 0, 0.1, accuracy: 1e-6)
    }
}
