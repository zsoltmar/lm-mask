import CoreMedia
import Foundation
import os

/// Gate 1 debug mode: physical camera -> FrameSink -> extension -> Zoom, with no tracking or rendering.
/// If Zoom shows your own video via "LM Halloween Cam", the whole host/extension path works.
final class PassthroughPipeline: @unchecked Sendable {
    let capture: CameraCapture
    let sink: FrameSink
    private let log = Logger.lm("passthrough")
    private let lock = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    /// `excludedNamePrefix` is our own camera name so capture can never pick the virtual camera
    /// (CameraCapture's default prefix "LM Mask" does not match "LM Halloween Cam").
    init(capture: CameraCapture = CameraCapture(excludedNamePrefix: Identity.deviceName),
         sink: FrameSink = FrameSink()) {
        self.capture = capture
        self.sink = sink
    }

    func start() async throws {
        sink.start()
        let task = Task.detached(priority: .userInitiated) { [capture, sink] in
            // frames is newest-1 / non-blocking; send() never blocks either.
            for await frame in capture.frames {
                sink.send(frame.pixelBuffer, at: frame.presentationTime)
            }
        }
        lock.withLock { $0?.cancel(); $0 = task }
        try await capture.start()
        log.info("passthrough running")
    }

    func stop() {
        lock.withLock { $0?.cancel(); $0 = nil }
        capture.stop()
        sink.stop()
    }
}
