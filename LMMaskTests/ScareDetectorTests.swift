import XCTest
@testable import LMMask

final class ScareDetectorTests: XCTestCase {
    private let dt = 1.0 / 30.0

    /// Feeds constant readings every frame from `from` (inclusive) for `seconds`; returns the first time the detector
    /// was active, if any.
    @discardableResult
    private func feed(_ d: inout ScareDetector, from: Double, seconds: Double, mouth: Float, eyes: Float) -> Double? {
        var first: Double?
        var t = from
        while t < from + seconds - 1e-9 {
            if d.update(mouth: mouth, leftEye: eyes, rightEye: eyes, time: t), first == nil { first = t }
            t += dt
        }
        return first
    }

    func testNoTriggerBelowThresholds() {
        var d = ScareDetector()
        XCTAssertNil(feed(&d, from: 0, seconds: 2, mouth: 0.69, eyes: 0.99))  // mouth just short
        XCTAssertNil(feed(&d, from: 2, seconds: 2, mouth: 1.0, eyes: 0.91))   // eyes just short
        XCTAssertFalse(d.isActive)
    }

    func testBothEyesRequired() {
        var d = ScareDetector()
        var t = 0.0
        while t < 2 {
            d.update(mouth: 1, leftEye: 1, rightEye: 0.5, time: t)
            t += dt
        }
        XCTAssertFalse(d.isActive)
    }

    func testTriggersOnlyAfterHold() {
        var d = ScareDetector()
        // Frames at 0, 33, 66, 100 ms are inside the 120 ms hold, the one at 133 ms fires.
        let first = feed(&d, from: 0, seconds: 1, mouth: 0.8, eyes: 0.95)
        XCTAssertNotNil(first)
        XCTAssertEqual(first ?? -1, 0.12, accuracy: dt)
        XCTAssertGreaterThanOrEqual(first ?? 0, 0.12)
    }

    func testHoldRestartsWhenConditionDrops() {
        var d = ScareDetector()
        feed(&d, from: 0, seconds: 0.1, mouth: 0.8, eyes: 0.95)       // 3 frames: not yet
        XCTAssertFalse(d.isActive)
        d.update(mouth: 0.5, leftEye: 0.95, rightEye: 0.95, time: 0.1)  // dip resets the clock
        feed(&d, from: 0.1 + dt, seconds: 0.1, mouth: 0.8, eyes: 0.95)
        XCTAssertFalse(d.isActive)
    }

    func testHysteresisKeepsActiveBetweenThresholds() {
        var d = ScareDetector()
        let onset = feed(&d, from: 0, seconds: 0.5, mouth: 0.8, eyes: 0.95)
        XCTAssertNotNil(onset)
        // Mouth 0.5 / eyes 0.7: below the trigger levels but above the keep levels. Still active for seconds.
        feed(&d, from: 0.5, seconds: 5, mouth: 0.5, eyes: 0.7)
        XCTAssertTrue(d.isActive)
    }

    func testReleasesAfterReleaseHold() {
        var d = ScareDetector()
        feed(&d, from: 0, seconds: 3, mouth: 0.9, eyes: 1)  // well past the minimum
        XCTAssertTrue(d.isActive)
        let tDrop = 3.0
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: tDrop)
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: tDrop + 0.2)
        XCTAssertTrue(d.isActive, "200 ms below the keep level is shorter than the 300 ms release hold")
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: tDrop + 0.31)
        XCTAssertFalse(d.isActive)
    }

    func testShortDipDoesNotRelease() {
        var d = ScareDetector()
        feed(&d, from: 0, seconds: 3, mouth: 0.9, eyes: 1)
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: 3.0)
        d.update(mouth: 0.9, leftEye: 1, rightEye: 1, time: 3.2)  // recovered: clock cleared
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: 3.4)
        d.update(mouth: 0.1, leftEye: 1, rightEye: 1, time: 3.6)  // only 200 ms since the second dip
        XCTAssertTrue(d.isActive)
    }

    func testMinimumActiveDuration() {
        var d = ScareDetector()
        let onset = feed(&d, from: 0, seconds: 0.2, mouth: 0.9, eyes: 1)
        let t0 = try! XCTUnwrap(onset)
        // The user closes up right after onset.
        var t = 0.2
        var releasedAt: Double?
        while t < 4, releasedAt == nil {
            if !d.update(mouth: 0, leftEye: 1, rightEye: 1, time: t) { releasedAt = t }
            t += dt
        }
        let r = try! XCTUnwrap(releasedAt)
        XCTAssertGreaterThanOrEqual(r - t0, 1.2, "a quick boo stays on for the minimum time")
        XCTAssertLessThanOrEqual(r - t0, 1.2 + 2 * dt)
    }

    func testForceScare() {
        var d = ScareDetector()
        d.forceScare = true
        XCTAssertTrue(d.update(mouth: 0, leftEye: 0, rightEye: 0, time: 0), "forced scare is immediate, no hold")
        feed(&d, from: dt, seconds: 3, mouth: 0, eyes: 0)
        XCTAssertTrue(d.isActive, "stays on while forced")
        d.forceScare = false
        feed(&d, from: 3, seconds: 1, mouth: 0, eyes: 0)
        XCTAssertFalse(d.isActive)
    }

    func testResetAndCustomThresholds() {
        var d = ScareDetector()
        d.config.mouthThreshold = 0.3
        d.config.eyeThreshold = 0.5
        d.config.holdSeconds = 0
        XCTAssertTrue(d.update(mouth: 0.35, leftEye: 0.6, rightEye: 0.6, time: 0))
        d.reset()
        XCTAssertFalse(d.isActive)
    }

    // MARK: Envelope

    func testEnvelopeSnapsOnAndEasesOff() {
        var e = ScareEnvelope()
        XCTAssertEqual(e.update(active: false, time: 0), 0)
        // Onset with one frame of pre-roll: already > 0.7 on the first frame, 1.0 within 80 ms.
        let first = e.update(active: true, time: 1.0, preroll: dt)
        XCTAssertGreaterThan(first, 0.7)
        XCTAssertEqual(e.update(active: true, time: 1.0 + 0.08, preroll: dt), 1, accuracy: 1e-5)
        // Release: monotonic decrease over 600 ms, 0 at the end, still ~1 right after release starts.
        let r0 = e.update(active: false, time: 2.0)
        XCTAssertEqual(r0, 1, accuracy: 1e-5)
        var last = r0
        var t = 2.0
        while t < 2.6 {
            t += dt
            let a = e.update(active: false, time: t)
            XCTAssertLessThanOrEqual(a, last + 1e-6)
            last = a
        }
        XCTAssertEqual(e.update(active: false, time: 2.7), 0, accuracy: 1e-5)
    }

    func testPopCurve() {
        XCTAssertEqual(ScareEnvelope.pop(sinceOnset: 0), 1, accuracy: 1e-5)
        XCTAssertEqual(ScareEnvelope.pop(sinceOnset: ScareEnvelope.onsetSeconds), 1.12, accuracy: 1e-4)
        XCTAssertEqual(ScareEnvelope.pop(sinceOnset: 2), 1.05, accuracy: 1e-3)
    }
}
