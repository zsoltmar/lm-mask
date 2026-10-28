// RenderPipeline.swift
// LM Mask - CameraCapture -> FaceTracker -> MaskRenderer -> Compositor -> FrameOutput.
//
// Apple docs:
//  - DispatchQueue (serial, QoS)   https://developer.apple.com/documentation/dispatch/dispatchqueue
//  - OSAllocatedUnfairLock         https://developer.apple.com/documentation/os/osallocatedunfairlock
//  - Observation (@Observable)     https://developer.apple.com/documentation/observation
//  - VTCreateCGImageFromCVPixelBuffer https://developer.apple.com/documentation/videotoolbox/1450028-vtcreatecgimagefromcvpixelbuffer

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import Observation
import VideoToolbox
import os

/// Per-second health numbers for a debug HUD. Value type, Sendable.
struct RenderStats: Sendable, Equatable {
    var fps: Double = 0
    /// Tracking (Vision) cost per frame, ms (exponential moving average).
    var trackingMilliseconds: Double = 0
    /// 3D pass + composite (CPU encode + GPU wait) per frame, ms.
    var renderMilliseconds: Double = 0
    /// Camera frames that never reached the renderer because it was still busy.
    var droppedFrames = 0
    var faceDetected = false
    /// 0...1; 1 once the per-user eye-open calibration is done.
    var calibrationProgress: Float = 0
    /// Scare mode trigger is active (published immediately on change, see `RenderWorker`).
    var scareActive = false
    /// Latest calibrated readings behind the scare trigger (0...1).
    var mouthOpenness: Float = 0
    var leftEyeOpenness: Float = 0
    var rightEyeOpenness: Float = 0
}

/// `@unchecked Sendable` wrapper for CF/Metal/SceneKit values that are immutable once handed over.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// Newest composited frame, readable from any thread (for Metal / layer previews).
final class FrameSlot: Sendable {
    private let state = OSAllocatedUnfairLock<(buffer: Unchecked<CVPixelBuffer>, time: CMTime)?>(initialState: nil)
    fileprivate func store(_ pb: CVPixelBuffer, _ t: CMTime) {
        let boxed = Unchecked(value: pb)  // CVPixelBuffer is not Sendable; do not capture it in the @Sendable lock body
        state.withLock { $0 = (boxed, t) }
    }
    func load() -> (pixelBuffer: CVPixelBuffer, time: CMTime)? {
        state.withLockUnchecked { $0.map { ($0.buffer.value, $0.time) } }
    }
}

/// Everything that runs per frame. All mutable state is touched only on `queue`; the only things shared with other
/// threads are the lock-protected settings/flags.
private final class RenderWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.lawmatics.lmmask.render", qos: .userInteractive)

    private let tracker = FaceTracker()
    private let renderer: MaskRenderer
    private let compositor: Compositor
    private let cutout = MouthCutout()
    private let output: FrameOutput

    let settings = OSAllocatedUnfairLock(initialState: RenderSettings())
    let previewWanted = OSAllocatedUnfairLock(initialState: false)
    let recalibrateFlag = OSAllocatedUnfairLock(initialState: false)
    let slot: FrameSlot

    private let onStats: @Sendable (RenderStats) -> Void
    private let onPreview: @Sendable (CGImage) -> Void

    // queue-confined
    private var stats = RenderStats()
    private var lastFrameTime: Double?
    private var lastStatsPublish = 0.0
    private var publishedScare = false
    private var lastPreview = 0.0
    private var lastMapping: FrameMapping?
    private let log = Logger.lm("pipeline")
    private let signposter = OSSignposter(subsystem: Identity.logSubsystem, category: "pipeline")

    init(renderer: MaskRenderer, compositor: Compositor, output: FrameOutput, slot: FrameSlot,
         onStats: @escaping @Sendable (RenderStats) -> Void,
         onPreview: @escaping @Sendable (CGImage) -> Void) {
        self.renderer = renderer
        self.compositor = compositor
        self.output = output
        self.slot = slot
        self.onStats = onStats
        self.onPreview = onPreview
    }

    /// Queues a look change for the renderer (applied at the start of its next frame). Any thread.
    func submit(style update: StyleUpdate) { renderer.submit(update) }

    /// Hops onto the render queue for one frame. The caller awaits, so at most one frame is in flight and
    /// the capture stream (newest-1) drops everything older: we never queue behind ourselves.
    func process(_ frame: CaptureFrame) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.processSync(frame)
                c.resume()
            }
        }
    }

    private func processSync(_ frame: CaptureFrame) {
        let sp = signposter.beginInterval("frame")
        defer { signposter.endInterval("frame", sp) }

        let s = settings.withLock { $0 }
        let time = frame.presentationTime
        let t = time.seconds
        let wall0 = DispatchTime.now().uptimeNanoseconds

        if let last = lastFrameTime {
            let gap = t - last
            if gap > 0 {
                stats.fps += (1 / gap - stats.fps) * 0.1
                stats.droppedFrames += max(0, Int((gap * Double(FrameFormat.fps)).rounded()) - 1)
            }
        }
        lastFrameTime = t

        // Tracking is skipped entirely when the mask is off.
        var pose: FacePose?
        if s.enabled {
            if recalibrateFlag.withLock({ let v = $0; $0 = false; return v }) { tracker.recalibrate() }
            pose = tracker.process(pixelBuffer: frame.pixelBuffer, time: time)
            let trackMs = Double(DispatchTime.now().uptimeNanoseconds - wall0) / 1e6
            stats.trackingMilliseconds += (trackMs - stats.trackingMilliseconds) * 0.1
            stats.faceDetected = pose != nil
            stats.calibrationProgress = tracker.calibrationProgress
        }
        let renderStart = DispatchTime.now().uptimeNanoseconds

        // Vision results are in source-frame pixels; everything drawn is in output pixels. One mapping per frame.
        let mapping = FrameMapping(sourceWidth: CVPixelBufferGetWidth(frame.pixelBuffer),
                                   sourceHeight: CVPixelBufferGetHeight(frame.pixelBuffer),
                                   outputWidth: compositor.width, outputHeight: compositor.height)
        if mapping != lastMapping {
            lastMapping = mapping
            log.info("source \(Int(mapping.sourceSize.x))x\(Int(mapping.sourceSize.y)) -> output \(Int(mapping.outputSize.x))x\(Int(mapping.outputSize.y)), fill scale \(mapping.scale)")
        }

        var mouth: MouthPlacement?
        if s.enabled {
            renderer.updateEnvironment(from: frame.pixelBuffer, time: t)
            renderer.update(pose: pose, mapping: mapping, time: t, settings: s)
            renderer.render(time: t)
            // The user's real mouth, relocated into the mask's mouth window: a SHARP rounded-rect crop around the outer lips
            // (source px -> camera texture px; the camera buffer IS the source frame), scaled to fill the window quad the
            // renderer projected this frame. Hidden in scare mode (the window is black then) and when the window is off.
            if s.showMouth, renderer.mouthWindowActive, let pose, renderer.mouthWindowCorners.count == 4,
               let crop = cutout.crop(lips: pose.outerLips, aspect: renderer.mouthWindowAspect) {
                mouth = MouthPlacement(corners: renderer.mouthWindowCorners, cropCenter: crop.center, cropHalf: crop.half,
                                       rotation: renderer.faceRoll, aspect: renderer.mouthWindowAspect,
                                       cornerRadius: cutout.cornerRadius)
            }
        }
        let scare = renderer.scareReadout
        stats.scareActive = s.enabled && scare.active
        stats.mouthOpenness = scare.mouth
        stats.leftEyeOpenness = scare.leftEye
        stats.rightEyeOpenness = scare.rightEye

        if let out = compositor.composite(camera: frame.pixelBuffer, mapping: mapping, mask: s.enabled ? renderer.maskTexture : nil,
                                          mouth: mouth, scare: s.enabled ? renderer.scareFrame : .none) {
            if s.enabled { output.send(out, at: time) }
            slot.store(out, time)
            publishPreview(out, now: t, pose: pose, mapping: mapping)
        }

        let renderMs = Double(DispatchTime.now().uptimeNanoseconds - renderStart) / 1e6
        stats.renderMilliseconds += (renderMs - stats.renderMilliseconds) * 0.1
        // Once a second normally; 5 Hz while the preview is on screen (live trigger readings), and immediately when the
        // scare state flips (status pill).
        let interval = previewWanted.withLock { $0 } ? 0.2 : 1.0
        if t - lastStatsPublish >= interval || stats.scareActive != publishedScare {
            lastStatsPublish = t
            publishedScare = stats.scareActive
            onStats(stats)
        }
    }

    private func publishPreview(_ pb: CVPixelBuffer, now t: Double, pose: FacePose?, mapping: FrameMapping) {
        guard t - lastPreview >= 1.0 / 15, previewWanted.withLock({ $0 }) else { return }
        lastPreview = t
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
        guard let image else { return }
        onPreview(image)
        // Alignment overlay: image and geometry are stored together so they always belong to the same frame.
        let hub = PlacementDebugHub.shared
        if hub.wanted {
            hub.store(image: image, info: renderer.makeDebugInfo(pose: renderer.isTracking ? pose : nil, mapping: mapping))
        }
    }
}

/// Owns capture, tracking, rendering and output. UI binds to the `MaskPipelineControlling` members.
///
/// Threading: this object is main-actor (UI state only). Per-frame work runs on a dedicated serial render queue
/// (`com.lawmatics.lmmask.render`) inside `RenderWorker`; a detached task feeds it from `CameraCapture.frames`
/// (newest-1 stream), awaiting each frame, so a slow frame makes the next ones get dropped, never queued.
@MainActor
@Observable
final class RenderPipeline: MaskPipelineControlling {

    // MARK: Settings (MaskPipelineControlling)

    var enabled = true { didSet { pushSettings() } }
    /// 1.8...3.2
    var maskScale = MaskSettingsSpec.maskScaleDefault { didSet { pushSettings(); persistSettings() } }
    /// Headpiece height offset, fraction of face height, positive = up.
    var verticalOffset = MaskSettingsSpec.verticalOffsetDefault { didSet { pushSettings(); persistSettings() } }
    /// Extra knobs beyond the contract.
    var showMouth = true { didSet { pushSettings() } }
    /// Scare mode held on regardless of the face (the "Test scare" button; see `testScare()`).
    var forceScare = false { didSet { pushSettings() } }
    /// Look of the headpiece. Persisted as JSON in UserDefaults. Material changes reach the renderer on the next frame;
    /// geometry changes (finger pad / depth, palm, collar, windows) are debounced ~150 ms, then rebuilt on the render queue.
    var style = MaskStyle() { didSet { styleDidChange(from: oldValue) } }

    /// Forwarded from the installer (observable: `ExtensionInstaller` is `@Observable`).
    var extensionState: ExtensionState { installer?.state ?? .notInstalled }

    // MARK: Published state

    /// Latest composited frame (same pixels the extension gets), at most 15 Hz, only while `previewEnabled`.
    private(set) var previewImage: CGImage?
    private(set) var isRunning = false
    private(set) var stats = RenderStats()
    /// Human-readable camera/setup problem, nil when fine.
    private(set) var statusMessage: String?
    /// True while scare mode is triggered (live, from the render queue's stats).
    var scareActive: Bool { stats.scareActive }
    /// Turn off when no preview is on screen to save the CGImage conversion.
    var previewEnabled = false { didSet { worker?.previewWanted.withLock { [previewEnabled] in $0 = previewEnabled } } }

    // MARK: Private

    private nonisolated let slot = FrameSlot()
    private let capture: CameraCapture
    private let output: FrameOutput
    private let installer: ExtensionInstaller?
    @ObservationIgnored private var worker: RenderWorker?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var scareTestTask: Task<Void, Never>?
    private let log = Logger.lm("pipeline")

    /// - Parameters:
    ///   - capture: defaults to a capture that never selects our own virtual camera.
    ///   - output: where finished frames go (`FrameSink` in the app).
    ///   - installer: source of `extensionState`; nil in tests.
    init(capture: CameraCapture = CameraCapture(excludedNamePrefix: Identity.deviceName),
         output: FrameOutput,
         installer: ExtensionInstaller? = nil) {
        self.capture = capture
        self.output = output
        self.installer = installer
        // Persisted settings (QUESTIONS.md F4). Assignments in init do not fire the didSet observers.
        let d = UserDefaults.standard
        func stored(_ key: String, _ range: ClosedRange<Double>) -> Double? {
            (d.object(forKey: key) as? Double).map { min(max($0, range.lowerBound), range.upperBound) }
        }
        if let v = stored(AppPreferences.maskScale, MaskSettingsSpec.maskScaleRange) { maskScale = v }
        if let v = stored(AppPreferences.verticalOffset, MaskSettingsSpec.verticalOffsetRange) { verticalOffset = v }
        let savedStyle = MaskStyle.load()
        style = savedStyle
        do {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
            else { throw Compositor.Failure.noLibrary }
            let renderer = try MaskRenderer(device: device, queue: queue, style: savedStyle)
            let compositor = try Compositor(device: device, queue: queue)
            worker = RenderWorker(
                renderer: renderer, compositor: compositor, output: output, slot: slot,
                onStats: { [weak self] s in Task { @MainActor in self?.stats = s } },
                onPreview: { [weak self] image in
                    let box = Unchecked(value: image)
                    Task { @MainActor in self?.previewImage = box.value }
                })
        } catch {
            statusMessage = "Renderer setup failed: \(error)"
            Logger.lm("pipeline").error("setup failed: \(String(describing: error), privacy: .public)")
        }
        pushSettings()
    }

    // MARK: Control

    func start() {
        guard !isRunning, let worker else { return }
        isRunning = true
        statusMessage = nil
        output.start()
        // The capture streams are single-consumer and finish for good once an iterating task is cancelled, so the
        // consumer tasks are created once and survive stop()/start() (Settings restarts the pipeline on camera change).
        if frameTask == nil {
            let frames = capture.frames
            frameTask = Task.detached(priority: .userInteractive) {
                for await frame in frames {
                    if Task.isCancelled { break }
                    await worker.process(frame)
                }
            }
        }
        let events = capture.events
        if eventTask == nil {
            eventTask = Task { [weak self] in
                for await e in events {
                    guard let self else { return }
                    switch e {
                    case .started: self.statusMessage = nil
                    case .stopped: break
                    case .deviceDisconnected(let n): self.statusMessage = "Camera disconnected: \(n)"
                    case .deviceReconnected: self.statusMessage = nil
                    case .failed(let m): self.statusMessage = "Camera error: \(m)"
                    }
                }
            }
        }
        Task { [weak self] in
            do { try await self?.capture.start() } catch {
                guard let self else { return }
                self.statusMessage = switch error as? CaptureError {
                case .accessDenied: "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
                case .noCamera: "No camera found; waiting for one to be connected."
                default: "Could not start the camera: \(error.localizedDescription)"
                }
                if case .noCamera? = error as? CaptureError {} else { self.stop() }
            }
        }
    }

    func stop() {
        // frameTask/eventTask are kept on purpose (see start()); with capture stopped they just wait on their streams.
        capture.stop()
        output.stop()
        isRunning = false
    }

    func recalibrate() { worker?.recalibrateFlag.withLock { $0 = true } }

    /// Holds scare mode on for 2 s (then the normal release rules apply). Pressing again restarts the 2 s.
    func testScare() {
        scareTestTask?.cancel()
        forceScare = true
        scareTestTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.forceScare = false
        }
    }

    /// Newest composited frame for a Metal/AVSampleBufferDisplayLayer preview (no CGImage conversion).
    /// The buffer is immutable; hold it as long as needed (the pool grows rather than reusing it).
    nonisolated func latestFrame() -> (pixelBuffer: CVPixelBuffer, time: CMTime)? { slot.load() }

    private func pushSettings() {
        // Build the value on the main actor; the @Sendable lock body must not touch `self`.
        let snapshot = RenderSettings(enabled: enabled,
                                      maskScale: Float(maskScale),
                                      showMouth: showMouth,
                                      verticalOffset: Float(verticalOffset),
                                      forceScare: forceScare)
        worker?.settings.withLock { $0 = snapshot }
    }

    private func styleDidChange(from old: MaskStyle) {
        guard style != old else { return }
        style.save()
        guard let worker else { return }
        worker.submit(style: StyleUpdate(style: style, rebuildGeometry: false))
        guard style.geometryDiffers(from: old) else { return }

        geometryTask?.cancel()
        geometryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.worker?.submit(style: StyleUpdate(style: self.style, rebuildGeometry: true))
        }
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(maskScale, forKey: AppPreferences.maskScale)
        d.set(verticalOffset, forKey: AppPreferences.verticalOffset)
    }
}
