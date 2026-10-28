import CoreMedia
import CoreVideo
import Foundation
import Vision
import os
import simd

// VNDetectFaceLandmarksRequest: https://developer.apple.com/documentation/vision/vndetectfacelandmarksrequest
// Constellation76Points:        https://developer.apple.com/documentation/vision/vnrequestfacelandmarksconstellation/constellation76points
// VNSequenceRequestHandler:     https://developer.apple.com/documentation/vision/vnsequencerequesthandler
// VNFaceLandmarkRegion2D:       https://developer.apple.com/documentation/vision/vnfacelandmarkregion2d/pointsinimage(imagesize:)
// VNFaceObservation roll/yaw/pitch: https://developer.apple.com/documentation/vision/vnfaceobservation

struct FaceTrackerConfiguration: Sendable {
    var horizontalFOV: Float = HeadPoseGeometry.defaultHorizontalFOV
    var interPupillaryDistance: Float = HeadPoseGeometry.defaultInterPupillaryDistance

    /// Frames (with a face) used to learn the user's open-eye EAR.
    var calibrationFrames = 90
    var calibrationPercentile: Float = 0.95
    /// closed EAR = closedRatio * open EAR.
    var closedRatio: Float = 0.4
    /// Sanity bounds on learned open EAR; outside this we keep `fallbackOpenEAR`.
    var openEARRange: ClosedRange<Float> = 0.08...0.8
    var fallbackOpenEAR: Float = 0.3

    /// Below this, `process` returns nil.
    var minConfidence: Float = 0.3
    /// After this long without a face, filters are reset so stale state doesn't smear.
    var lostResetSeconds: Double = 0.5

    /// Pose filter (translation, rotation, euler). Spec defaults.
    var poseFilter = OneEuroParameters(minCutoff: 1.0, beta: 0.02, dCutoff: 1.0)
    /// Openness filter. Blinks last ~100-150 ms, so this needs a much higher cutoff than the pose.
    var opennessFilter = OneEuroParameters(minCutoff: 5.0, beta: 0.5, dCutoff: 1.0)

    /// Mouth openness / smile filter (a little calmer than blinks).
    var mouthFilter = OneEuroParameters(minCutoff: 3.0, beta: 0.4, dCutoff: 1.0)
    /// Window (frames) over which the closed-mouth level (5th percentile) is learned: about 10 s at 30 fps.
    var mouthWindow = 300
    /// Smile ratio (corner height above lip centre / mouth width) that counts as a full smile / frown.
    var smileFullScale: Float = 0.12

    /// Sign / eye-assignment fixes pending on-device verification (QUESTIONS.md Q2, Q3).
    var rollSign: Float = 1
    var yawSign: Float = 1
    var pitchSign: Float = 1
    var swapEyes = false

    /// Fills `FacePose.allLandmarks` (debug only; allocates).
    var includeAllLandmarks = false
}

// MARK: - Eye geometry

enum EyeGeometry {
    struct Measurement: Equatable {
        var ear: Float
        var center: SIMD2<Float>
        var width: Float
    }

    /// Eye aspect ratio from a closed contour of eye points (Soukupova & Cech 2016 generalised).
    ///
    /// Vision does not document the point order of its eye contour, so this is order-independent:
    /// the eye corners are the two points farthest apart (width w); the height h is the extent of
    /// all points perpendicular to that axis; EAR = h / w. For the classic 6-point formula
    /// (|p2-p6|+|p3-p5|) / (2|p1-p4|) this is the same quantity but uses all 8 points and is
    /// robust to ordering and eye roll.
    static func measure(_ pts: [SIMD2<Float>]) -> Measurement? {
        guard pts.count >= 4 else { return nil }
        var best: Float = 0
        var a = 0, b = 1
        for i in 0..<pts.count {
            for j in (i + 1)..<pts.count {
                let d = simd_distance_squared(pts[i], pts[j])
                if d > best { best = d; a = i; b = j }
            }
        }
        let w = best.squareRoot()
        guard w > 1e-3 else { return nil }
        let axis = (pts[b] - pts[a]) / w
        let n = SIMD2<Float>(-axis.y, axis.x)
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for p in pts {
            let s = simd_dot(p - pts[a], n)
            lo = min(lo, s); hi = max(hi, s)
        }
        return Measurement(ear: (hi - lo) / w, center: (pts[a] + pts[b]) / 2, width: w)
    }

    /// Maps EAR to 0...1 given calibrated open EAR; closed = closedRatio * open.
    static func openness(ear: Float, open: Float, closedRatio: Float) -> Float {
        let closed = open * closedRatio
        let range = max(1e-4, open - closed)
        return min(1, max(0, (ear - closed) / range))
    }
}

// MARK: - Mouth geometry

enum MouthGeometry {
    struct Measurement: Equatable {
        /// Inner-lip vertical gap / outer mouth width (about 0 closed, 0.3-0.6 wide open).
        var openRatio: Float
        /// Lip-corner height above the lip centre / mouth width (positive = corners up).
        var smileRatio: Float
    }

    /// Order-independent like `EyeGeometry.measure`: the mouth corners are the two outer-lip points farthest apart
    /// (axis, left to right on screen); gap = extent of the inner lips perpendicular to it; smile = how far the corner
    /// midpoint sits above the middle of the outer lips' vertical extent. Points are in top-left-origin pixels (y down).
    static func measure(inner: [SIMD2<Float>], outer: [SIMD2<Float>]) -> Measurement? {
        guard outer.count >= 4, inner.count >= 3 else { return nil }
        var best: Float = 0
        var a = 0, b = 1
        for i in 0..<outer.count {
            for j in (i + 1)..<outer.count {
                let d = simd_distance_squared(outer[i], outer[j])
                if d > best { best = d; a = i; b = j }
            }
        }
        let w = best.squareRoot()
        guard w > 1e-3 else { return nil }
        var pa = outer[a], pb = outer[b]
        if pa.x > pb.x { swap(&pa, &pb) }
        let axis = (pb - pa) / w
        let up = SIMD2<Float>(axis.y, -axis.x)  // axis (1, 0) -> (0, -1) = up on screen

        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for p in inner {
            let s = simd_dot(p - pa, up)
            lo = min(lo, s); hi = max(hi, s)
        }
        var olo = Float.greatestFiniteMagnitude, ohi = -Float.greatestFiniteMagnitude
        for p in outer {
            let s = simd_dot(p - pa, up)
            olo = min(olo, s); ohi = max(ohi, s)
        }
        // Corners are at s = 0 by construction; the lip centre sits at the middle of the outer extent.
        let centre = (olo + ohi) / 2
        return Measurement(openRatio: (hi - lo) / w, smileRatio: (0 - centre) / w)
    }
}

/// Learns a user's closed / open mouth levels. closed = 5th percentile of a rolling window, open = largest value seen
/// (decays very slowly so one stray frame does not stick forever).
struct MouthCalibration {
    private var window: [Float] = []
    private var next = 0
    private let capacity: Int
    private(set) var closed: Float = 0
    private(set) var open: Float = 0.3
    private var frames = 0

    init(capacity: Int) { self.capacity = max(8, capacity) }

    /// Minimum span between closed and open so a mouth that barely moves does not get amplified into noise.
    static let minSpan: Float = 0.12

    mutating func add(_ ratio: Float) {
        if window.count < capacity { window.append(ratio) } else { window[next] = ratio; next = (next + 1) % capacity }
        frames += 1
        if frames % 6 == 1 || window.count < 30 {
            let sorted = window.sorted()
            closed = sorted[Int(Float(sorted.count - 1) * 0.05)]
        }
        open = max(open * 0.9998, ratio)
        open = max(open, closed + Self.minSpan)
    }

    func normalise(_ ratio: Float) -> Float {
        min(1, max(0, (ratio - closed) / max(Self.minSpan, open - closed)))
    }
}

// MARK: - Blink events (debug / logging)

struct BlinkEvent: Sendable, Equatable {
    enum Eye: Sendable { case left, right }
    var eye: Eye
    /// Seconds the eye stayed below the close threshold.
    var duration: Double
}

/// Hysteresis detector: closes below `closeBelow`, reopens above `openAbove`.
/// Emits the event when the eye reopens.
struct BlinkDetector: Sendable {
    var closeBelow: Float = 0.3
    var openAbove: Float = 0.6
    private var leftClosedAt: Double?
    private var rightClosedAt: Double?

    mutating func update(left: Float, right: Float, time: Double) -> (left: BlinkEvent?, right: BlinkEvent?) {
        (Self.step(left, time, closeBelow, openAbove, &leftClosedAt, .left),
         Self.step(right, time, closeBelow, openAbove, &rightClosedAt, .right))
    }

    private static func step(_ v: Float, _ t: Double, _ lo: Float, _ hi: Float,
                             _ closedAt: inout Double?, _ eye: BlinkEvent.Eye) -> BlinkEvent? {
        if let c = closedAt {
            if v > hi { closedAt = nil; return BlinkEvent(eye: eye, duration: t - c) }
        } else if v < lo {
            closedAt = t
        }
        return nil
    }
}

// MARK: - Tracker

/// Per-frame face tracker. NOT thread-safe: use from one serial context (see `FaceTrackingPipeline`).
/// The Vision call is synchronous (~5 ms on M1, target < 8 ms total) so it must never run on the
/// capture queue.
final class FaceTracker {
    let configuration: FaceTrackerConfiguration

    private let handler = VNSequenceRequestHandler()
    private let request: VNDetectFaceLandmarksRequest
    private let requests: [VNRequest]  // preallocated; avoids an array per frame

    private var poseFilter: TransformOneEuroFilter
    private var rollFilter, yawFilter, pitchFilter: OneEuroFilter
    private var leftOpenFilter, rightOpenFilter: OneEuroFilter
    private var mouthOpenFilter, smileFilter: OneEuroFilter
    private var mouthCalibration: MouthCalibration

    private var calibration: Calibration
    private var lastSeen: Double?

    private let log = Logger(subsystem: "com.lawmatics.lmmask", category: "tracker")
    private let signposter = OSSignposter(subsystem: "com.lawmatics.lmmask", category: "tracker")

    /// 0...1 while learning the user's open-eye EAR; 1 when done.
    var calibrationProgress: Float { calibration.progress }
    var isCalibrated: Bool { calibration.isComplete }

    init(configuration: FaceTrackerConfiguration = .init()) {
        self.configuration = configuration
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        r.constellation = .constellation76Points
        request = r
        requests = [r]

        poseFilter = TransformOneEuroFilter(translation: configuration.poseFilter,
                                            rotation: configuration.poseFilter)
        let angleFilter = OneEuroFilter(parameters: configuration.poseFilter)
        rollFilter = angleFilter
        yawFilter = angleFilter
        pitchFilter = angleFilter
        let openFilter = OneEuroFilter(parameters: configuration.opennessFilter)
        leftOpenFilter = openFilter
        rightOpenFilter = openFilter
        calibration = Calibration(configuration: configuration)
        mouthOpenFilter = OneEuroFilter(parameters: configuration.mouthFilter)
        smileFilter = OneEuroFilter(parameters: configuration.mouthFilter)
        mouthCalibration = MouthCalibration(capacity: configuration.mouthWindow)
    }

    /// Restart the per-user EAR calibration (e.g. user changed glasses / lighting).
    func recalibrate() {
        calibration = Calibration(configuration: configuration)
        mouthCalibration = MouthCalibration(capacity: configuration.mouthWindow)
    }

    /// - Returns: nil when there is no face or confidence is below `minConfidence`.
    func process(pixelBuffer: CVPixelBuffer, time: CMTime) -> FacePose? {
        let sp = signposter.beginInterval("process")
        defer { signposter.endInterval("process", sp) }

        let t = time.seconds
        let w = Float(CVPixelBufferGetWidth(pixelBuffer))
        let h = Float(CVPixelBufferGetHeight(pixelBuffer))

        do {
            // Camera frames are delivered upright; mirroring is a presentation concern.
            try handler.perform(requests, on: pixelBuffer, orientation: .up)
        } catch {
            log.error("Vision failed: \(error.localizedDescription, privacy: .public)")
            return lost(at: t)
        }

        guard let face = request.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }),
              let lm = face.landmarks,
              let leftRegion = lm.leftEye, let rightRegion = lm.rightEye
        else { return lost(at: t) }

        let confidence = min(face.confidence, lm.confidence)
        guard confidence >= configuration.minConfidence else { return lost(at: t) }

        let imageSize = CGSize(width: CGFloat(w), height: CGFloat(h))
        // pointsInImage is bottom-left origin; flip to top-left.
        var lPts = flipped(leftRegion.pointsInImage(imageSize: imageSize), height: h)
        var rPts = flipped(rightRegion.pointsInImage(imageSize: imageSize), height: h)
        if configuration.swapEyes { swap(&lPts, &rPts) }
        guard let lEye = EyeGeometry.measure(lPts), let rEye = EyeGeometry.measure(rPts) else { return lost(at: t) }

        lastSeen = t

        // Openness
        calibration.add(left: lEye.ear, right: rEye.ear)
        var lOpen: Float = 1, rOpen: Float = 1
        if let open = calibration.openEAR {
            lOpen = EyeGeometry.openness(ear: lEye.ear, open: open.0, closedRatio: configuration.closedRatio)
            rOpen = EyeGeometry.openness(ear: rEye.ear, open: open.1, closedRatio: configuration.closedRatio)
        }  // while calibrating we assume eyes open
        lOpen = min(1, max(0, leftOpenFilter.filter(lOpen, timestamp: t)))
        rOpen = min(1, max(0, rightOpenFilter.filter(rOpen, timestamp: t)))

        // Pose
        let roll = (face.roll?.floatValue ?? 0) * configuration.rollSign
        let yaw = (face.yaw?.floatValue ?? 0) * configuration.yawSign
        let pitch = (face.pitch?.floatValue ?? 0) * configuration.pitchSign

        let f = HeadPoseGeometry.focalLengthPixels(imageWidth: w, horizontalFOV: configuration.horizontalFOV)
        let ipdPx = simd_distance(lEye.center, rEye.center)
        let depth = HeadPoseGeometry.depth(interPupillaryPixels: ipdPx, yaw: yaw, focalLengthPixels: f,
                                           interPupillaryDistance: configuration.interPupillaryDistance)
        let mid = (lEye.center + rEye.center) / 2
        let position = HeadPoseGeometry.cameraSpacePosition(pixel: mid, depth: depth, focalLengthPixels: f,
                                                            imageSize: SIMD2(w, h))
        let raw = HeadPoseGeometry.transform(position: position, roll: roll, yaw: yaw, pitch: pitch)
        let transform = poseFilter.filter(raw, timestamp: t)

        // Lips
        var lips: [SIMD2<Float>] = []
        if let outer = lm.outerLips { lips = flipped(outer.pointsInImage(imageSize: imageSize), height: h) }

        // Mouth openness / smile from the inner and outer lip contours.
        var mouthOpen: Float = 0, smile: Float = 0
        if let inner = lm.innerLips,
           let m = MouthGeometry.measure(inner: flipped(inner.pointsInImage(imageSize: imageSize), height: h), outer: lips) {
            mouthCalibration.add(m.openRatio)
            mouthOpen = min(1, max(0, mouthOpenFilter.filter(mouthCalibration.normalise(m.openRatio), timestamp: t)))
            let rawSmile = min(1, max(-1, m.smileRatio / configuration.smileFullScale))
            smile = min(1, max(-1, smileFilter.filter(rawSmile, timestamp: t)))
        }

        var all: [SIMD2<Float>] = []
        if configuration.includeAllLandmarks, let r = lm.allPoints {
            all = flipped(r.pointsInImage(imageSize: imageSize), height: h)
        }

        let bb = face.boundingBox  // normalized, bottom-left origin
        let rect = CGRect(x: bb.minX * CGFloat(w), y: (1 - bb.maxY) * CGFloat(h),
                          width: bb.width * CGFloat(w), height: bb.height * CGFloat(h))

        return FacePose(
            faceRect: rect,
            roll: rollFilter.filter(roll, timestamp: t),
            yaw: yawFilter.filter(yaw, timestamp: t),
            pitch: pitchFilter.filter(pitch, timestamp: t),
            headTransform: transform,
            leftOpenness: lOpen, rightOpenness: rOpen,
            leftEyeCenter: lEye.center, rightEyeCenter: rEye.center,
            outerLips: lips, mouthOpenness: mouthOpen, smile: smile, allLandmarks: all,
            confidence: confidence, timestamp: time)
    }

    // MARK: Helpers

    private func lost(at t: Double) -> FacePose? {
        if let seen = lastSeen, t - seen > configuration.lostResetSeconds {
            poseFilter.reset(); rollFilter.reset(); yawFilter.reset(); pitchFilter.reset()
            leftOpenFilter.reset(); rightOpenFilter.reset()
            mouthOpenFilter.reset(); smileFilter.reset()
            lastSeen = nil
        }
        return nil
    }

    private func area(_ r: CGRect) -> CGFloat { r.width * r.height }

    private func flipped(_ pts: [CGPoint], height: Float) -> [SIMD2<Float>] {
        pts.map { SIMD2(Float($0.x), height - Float($0.y)) }
    }

    // MARK: Calibration

    /// Learns per-eye open EAR as the 95th percentile over the first N frames with a face.
    private struct Calibration {
        let capacity: Int
        let percentile: Float
        let range: ClosedRange<Float>
        let fallback: Float
        var left: [Float]
        var right: [Float]
        var count = 0
        var openEAR: (Float, Float)?

        init(configuration c: FaceTrackerConfiguration) {
            capacity = max(1, c.calibrationFrames)
            percentile = c.calibrationPercentile
            range = c.openEARRange
            fallback = c.fallbackOpenEAR
            left = Array(repeating: 0, count: capacity)
            right = Array(repeating: 0, count: capacity)
        }

        var isComplete: Bool { openEAR != nil }
        var progress: Float { openEAR != nil ? 1 : Float(count) / Float(capacity) }

        mutating func add(left l: Float, right r: Float) {
            guard openEAR == nil else { return }
            left[count] = l
            right[count] = r
            count += 1
            if count == capacity {
                // Sort local copies: passing `&left` while calling a method on `self` is an overlapping access.
                var ls = left, rs = right
                openEAR = (resolve(&ls), resolve(&rs))
            }
        }

        private func resolve(_ a: inout [Float]) -> Float {
            a.sort()
            let v = a[Int((percentile * Float(capacity - 1)).rounded())]
            return range.contains(v) ? v : fallback
        }
    }
}

// MARK: - Async pipeline

struct TrackingResult: Sendable {
    var pose: FacePose?
    var time: CMTime
    /// Wall-clock cost of `FaceTracker.process` for this frame.
    var processingMilliseconds: Double
    var calibrationProgress: Float
}

/// Consumes `CameraCapture.frames` on a dedicated detached task and publishes results.
/// Owns its `FaceTracker`, so no locking is needed around tracker state. Vision's synchronous
/// call blocks one cooperative-pool thread for a few ms per frame, never the capture queue.
final class FaceTrackingPipeline: Sendable {
    let results: AsyncStream<TrackingResult>
    private let recalibrateFlag = OSAllocatedUnfairLock(initialState: false)
    private let task: Task<Void, Never>

    init(frames: AsyncStream<CaptureFrame>, configuration: FaceTrackerConfiguration = .init()) {
        let (stream, continuation) = AsyncStream.makeStream(of: TrackingResult.self,
                                                            bufferingPolicy: .bufferingNewest(2))
        results = stream
        let flag = recalibrateFlag
        task = Task.detached(priority: .userInitiated) {
            let tracker = FaceTracker(configuration: configuration)
            for await frame in frames {
                if Task.isCancelled { break }
                if flag.withLock({ let v = $0; $0 = false; return v }) { tracker.recalibrate() }
                let t0 = DispatchTime.now().uptimeNanoseconds
                let pose = tracker.process(pixelBuffer: frame.pixelBuffer, time: frame.presentationTime)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
                continuation.yield(TrackingResult(pose: pose, time: frame.presentationTime,
                                                  processingMilliseconds: ms,
                                                  calibrationProgress: tracker.calibrationProgress))
            }
            continuation.finish()
        }
    }

    func recalibrate() { recalibrateFlag.withLock { $0 = true } }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}
