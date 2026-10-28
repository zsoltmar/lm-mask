import CoreMedia
import CoreMediaIO
import Foundation
import os

// Sink stream: https://developer.apple.com/documentation/coremediaio/cmioextensionstream/direction
// consume: https://developer.apple.com/documentation/coremediaio/cmioextensionstream/consumesamplebuffer(from:completionhandler:)
// notify:  https://developer.apple.com/documentation/coremediaio/cmioextensionstream/notifyscheduledoutputchanged(_:)

private let log = Logger.lm("camera.sink")

/// The stream the host app (FrameSink) writes into.
///
///   idle --startStream--> consuming --stopStream--> idle
///
/// `authorizedToStartStream(for:)` is the only place the writing `CMIOExtensionClient` is handed to us,
/// so we keep it. After `startStream` we run a self-rearming `consumeSampleBuffer` loop; each completion
/// forwards the frame to the source stream and re-arms. `consumeSampleBuffer` itself is async
/// (completion-based) so nothing here blocks a capture queue.
final class SinkStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormat: CMIOExtensionStreamFormat
    private let source: SourceStreamSource

    private struct State {
        var client: CMIOExtensionClient?
        var consuming = false
        var generation = 0 // invalidates stale loops after stop/start
    }
    // CMIOExtensionClient is not Sendable: unchecked lock variants.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    init(localizedName: String, device: CMIOExtensionDevice, source: SourceStreamSource) {
        self.source = source
        let d = CMTime(value: 1, timescale: FrameFormat.fps)
        streamFormat = CMIOExtensionStreamFormat(formatDescription: source.formatDescription,
                                                 maxFrameDuration: d, minFrameDuration: d,
                                                 validFrameDurations: nil)
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: Identity.sinkStreamID,
                                     direction: .sink, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [streamFormat] }

    // Sink-specific properties (CMIOExtensionProperty.streamSink*), see
    // https://developer.apple.com/documentation/coremediaio/cmioextensionproperty
    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration,
         .streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties {
        // Typed setters (as in Apple's sink sample); the generic dictionary form needs CMIOExtensionPropertyState<AnyObject>.
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: FrameFormat.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        log.info("sink: client authorized pid=\(client.pid)")
        state.withLockUnchecked { $0.client = client }
        return true
    }

    func startStream() throws {
        let (hasClient, gen): (Bool, Int) = state.withLockUnchecked { s in
            guard !s.consuming else { return (false, s.generation) }
            s.consuming = true
            s.generation += 1
            return (s.client != nil, s.generation)
        }
        guard hasClient else { return }
        log.info("sink stream started")
        consume(generation: gen)
    }

    func stopStream() throws {
        state.withLockUnchecked { s in
            s.consuming = false
            s.generation += 1
        }
        log.info("sink stream stopped")
    }

    /// The client is re-read from `state` (not captured) so the escaping completion handlers stay Sendable-clean.
    private func consume(generation: Int) {
        guard let client = state.withLockUnchecked({ $0.consuming && $0.generation == generation ? $0.client : nil })
        else { return }
        stream.consumeSampleBuffer(from: client) { [self] sample, sequenceNumber, _, _, error in
            let live = state.withLockUnchecked { $0.consuming && $0.generation == generation }
            guard live else { return }
            if let sample, let image = CMSampleBufferGetImageBuffer(sample) {
                source.forward(image)
                // Tell the client when this buffer is scheduled to be output so it can pace itself.
                let out = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber,
                                                       hostTimeInNanoseconds: SourceStreamSource.hostNanos())
                stream.notifyScheduledOutputChanged(out)
            } else if let error {
                log.error("sink consume error: \(error.localizedDescription, privacy: .public)")
                // Back off briefly so a persistent error cannot spin.
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.1) { [self] in
                    consume(generation: generation)
                }
                return
            }
            consume(generation: generation)
        }
    }
}
