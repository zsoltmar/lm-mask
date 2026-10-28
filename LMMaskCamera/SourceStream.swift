import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

// https://developer.apple.com/documentation/coremediaio/cmioextensionstreamsource
// https://developer.apple.com/documentation/coremediaio/cmioextensionstream/send(_:discontinuity:hosttimeinnanoseconds:)

private let log = Logger.lm("camera.source")

/// The stream Zoom reads. State machine (deliberately tiny):
///
///   idle --first startStream--> running --last stopStream--> idle
///
/// While running, every frame is either
///  - a sink frame forwarded immediately by `SinkStreamSource` via `forward(_:)`, or
///  - a test-pattern frame from the 30 fps timer, emitted only if no sink frame arrived for 1 s.
///
/// Thread-safety: `state` is an unfair lock; the timer handler runs on `frameQueue` and touches only
/// the pool/pattern (immutable after init) and `frameIndex` (frameQueue-only).
final class SourceStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    static let sinkTimeoutNanos: UInt64 = 1_000_000_000

    private(set) var stream: CMIOExtensionStream!
    let formatDescription: CMVideoFormatDescription
    private let streamFormat: CMIOExtensionStreamFormat
    private let pool: CVPixelBufferPool
    private let pattern: TestPattern?
    private let frameQueue = DispatchQueue(label: "com.lawmatics.lmmask.camera.frames", qos: .userInteractive)

    private struct State {
        var clientCount = 0
        var timer: DispatchSourceTimer?
        var lastSinkFrameNanos: UInt64 = 0   // 0 = never
    }
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private var frameIndex = 0 // frameQueue only

    init(localizedName: String, device: CMIOExtensionDevice) {
        var desc: CMFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                       codecType: FrameFormat.pixelFormat,
                                       width: FrameFormat.width, height: FrameFormat.height,
                                       extensions: nil, formatDescriptionOut: &desc)
        formatDescription = desc!
        let frameDuration = CMTime(value: 1, timescale: FrameFormat.fps)
        streamFormat = CMIOExtensionStreamFormat(formatDescription: formatDescription,
                                                 maxFrameDuration: frameDuration,
                                                 minFrameDuration: frameDuration,
                                                 validFrameDurations: nil)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: FrameFormat.pixelFormat,
            kCVPixelBufferWidthKey: Int(FrameFormat.width),
            kCVPixelBufferHeightKey: Int(FrameFormat.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &p)
        pool = p!
        pattern = TestPattern()
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: Identity.streamID,
                                     direction: .source, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }
    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: FrameFormat.fps)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        state.withLockUnchecked { s in
            s.clientCount += 1
            guard s.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: frameQueue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1_000_000_000 / Int(FrameFormat.fps))),
                       leeway: .milliseconds(1))
            t.setEventHandler { [self] in tick() }
            s.timer = t
            t.resume()
            log.info("source stream started (idle -> running)")
        }
    }

    func stopStream() throws {
        state.withLockUnchecked { s in
            s.clientCount = max(0, s.clientCount - 1)
            guard s.clientCount == 0 else { return }
            s.timer?.cancel()
            s.timer = nil
            log.info("source stream stopped (running -> idle)")
        }
    }

    // MARK: Frame output

    private var isRunning: Bool { state.withLockUnchecked { $0.timer != nil } }

    /// Called by the sink on arrival of a host frame. Fresh host-time timestamps; reuses the incoming
    /// IOSurface-backed buffer (no pixel copy). Drops frames whose size does not match the format.
    func forward(_ image: CVPixelBuffer) {
        guard isRunning,
              CVPixelBufferGetWidth(image) == Int(FrameFormat.width),
              CVPixelBufferGetHeight(image) == Int(FrameFormat.height) else { return }
        let nanos = Self.hostNanos()
        state.withLockUnchecked { $0.lastSinkFrameNanos = nanos }
        send(image, nanos: nanos)
    }

    /// frameQueue. Never blocks; emits the pattern only after 1 s without a sink frame.
    private func tick() {
        let now = Self.hostNanos()
        let last = state.withLockUnchecked { $0.lastSinkFrameNanos }
        if last != 0, now &- last < Self.sinkTimeoutNanos { return } // sink is live
        guard let pattern else { return }
        var pb: CVPixelBuffer?
        let auxAttrs = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, auxAttrs, &pb) == kCVReturnSuccess, let pixelBuffer = pb else {
            return // pool exhausted: drop frame rather than block
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        pattern.copyFrame(offset: frameIndex, into: pixelBuffer)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        frameIndex = (frameIndex + 6) % Int(FrameFormat.height) // 6 px/frame = 180 px/s
        send(pixelBuffer, nanos: now)
    }

    private func send(_ image: CVPixelBuffer, nanos: UInt64) {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: FrameFormat.fps),
            presentationTimeStamp: CMTime(value: CMTimeValue(nanos), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: image, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample)
        if status == noErr, let sample {
            stream.send(sample, discontinuity: [], hostTimeInNanoseconds: nanos)
        }
    }

    /// Host-clock nanoseconds (same clock as `.hostTime` clockType).
    static func hostNanos() -> UInt64 {
        let t = CMClockGetTime(CMClockGetHostTimeClock())
        return UInt64(t.seconds * Double(NSEC_PER_SEC)) // as in Apple's sample
    }
}
