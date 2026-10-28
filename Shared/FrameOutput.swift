import CoreMedia
import CoreVideo

/// Where finished 1280x720 BGRA frames go (in the app: `FrameSink`, which feeds the camera extension).
///
/// Contract:
/// - `send` is called on the render queue, once per frame, and must NOT block (enqueue and return).
/// - The buffer comes from a pool owned by the compositor. The callee may retain it (it is then not
///   reused until released) but must never write to it.
/// - `FrameSink.send(_:at:)` returns `Bool` (dropped or not); the requirement is `@discardableResult`
///   so `extension FrameSink: FrameOutput {}` is all that is needed.
protocol FrameOutput: AnyObject {
    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool
    /// Called by `RenderPipeline.start()/stop()`. Default: no-op.
    func start()
    func stop()
}

extension FrameOutput {
    func start() {}
    func stop() {}
}

/// Discards frames. Useful for previews/tests.
final class NullFrameOutput: FrameOutput {
    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool { true }
}
