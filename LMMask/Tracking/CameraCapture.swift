import AVFoundation
import CoreMedia
import CoreVideo
import os

// AVCaptureSession overview: https://developer.apple.com/documentation/avfoundation/avcapturesession
// AVCaptureVideoDataOutput:  https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput
// Device notifications:      https://developer.apple.com/documentation/avfoundation/avcapturedevice/1390075-wasdisconnectednotification

/// One captured frame. CVPixelBuffer is not annotated Sendable; the buffer is immutable
/// after delivery and we never write to it, so crossing isolation domains is safe.
struct CaptureFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let presentationTime: CMTime
}

enum CaptureEvent: Sendable, Equatable {
    case started(deviceName: String)
    case stopped
    case deviceDisconnected(name: String)
    case deviceReconnected(name: String)
    case failed(message: String)
}

enum CaptureError: Error, Sendable {
    case accessDenied
    case noCamera
    case cannotAddInput
    case cannotAddOutput
}

/// Captures BGRA @ 30 fps from the built-in (or best available) camera, preferring a 16:9 format (1280x720, else 1920x1080).
/// The delivered frame size can differ from `width`x`height`; `FrameMapping` handles that downstream.
///
/// Threading:
/// - `sessionQueue` serialises all session configuration (never the main thread:
///   `startRunning()` blocks).
/// - `sampleQueue` is the dedicated serial queue for sample-buffer callbacks. The callback
///   only wraps the buffer and does a non-blocking `yield` into a newest-1 AsyncStream, so
///   it can never stall capture. Slow consumers simply miss frames.
/// - Mutable state is only touched on `sessionQueue`; hence `@unchecked Sendable`.
final class CameraCapture: NSObject, @unchecked Sendable {
    static let width = 1280
    static let height = 720
    static let framesPerSecond = 30

    /// Newest-frame-wins stream. Single consumer.
    let frames: AsyncStream<CaptureFrame>
    /// Lifecycle / hot-plug events.
    let events: AsyncStream<CaptureEvent>
    /// Exposed for `AVCaptureVideoPreviewLayer` in the debug view.
    let session = AVCaptureSession()

    /// Devices whose localizedName starts with this are never selected (our own virtual camera, `Identity.deviceName`).
    private let excludedNamePrefix: String

    private let frameContinuation: AsyncStream<CaptureFrame>.Continuation
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private let sessionQueue = DispatchQueue(label: "com.lawmatics.lmmask.capture.session", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.lawmatics.lmmask.capture.samples", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let log = Logger(subsystem: "com.lawmatics.lmmask", category: "capture")

    // sessionQueue-only state
    private var currentInput: AVCaptureDeviceInput?
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    init(excludedNamePrefix: String = Identity.deviceName) {
        self.excludedNamePrefix = excludedNamePrefix
        let f = AsyncStream.makeStream(of: CaptureFrame.self, bufferingPolicy: .bufferingNewest(1))
        let e = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(16))
        frames = f.stream
        frameContinuation = f.continuation
        events = e.stream
        eventContinuation = e.continuation
        super.init()
        installObservers()
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        frameContinuation.finish()
        eventContinuation.finish()
    }

    // MARK: Public API

    /// Requests camera permission if needed, then starts capture. If no camera is present the
    /// call throws `.noCamera`, but capture will still auto-start when one is connected.
    func start() async throws {
        guard await Self.ensureAccess() else { throw CaptureError.accessDenied }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                self.wantsRunning = true
                do {
                    try self.configureAndRun()
                    c.resume()
                } catch {
                    c.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            self.eventContinuation.yield(.stopped)
        }
    }

    // MARK: Permission

    // https://developer.apple.com/documentation/avfoundation/avcapturedevice/requestaccess(for:)
    private static func ensureAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    // MARK: Configuration (sessionQueue only)

    private func pickDevice() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified)
        func rank(_ d: AVCaptureDevice) -> Int {
            var r = 0
            if d.deviceType != .builtInWideAngleCamera { r += 10 }
            if d.position != .front && d.position != .unspecified { r += 5 }
            if d.position != .front { r += 1 }
            return r
        }
        let candidates = discovery.devices.filter {
            !$0.localizedName.hasPrefix(excludedNamePrefix) && !$0.localizedName.hasPrefix("LM Mask")
        }
        // User's choice from Settings (AppPreferences.preferredCameraID); empty or unplugged = automatic.
        if let id = UserDefaults.standard.string(forKey: AppPreferences.preferredCameraID), !id.isEmpty,
           let preferred = candidates.first(where: { $0.uniqueID == id }) {
            return preferred
        }
        return candidates.min { rank($0) < rank($1) }
    }

    private func configureAndRun() throws {
        guard let device = pickDevice() else {
            log.error("No camera available; waiting for hot-plug")
            throw CaptureError.noCamera
        }

        session.beginConfiguration()
        do {
            if let old = currentInput {
                session.removeInput(old)
                currentInput = nil
            }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
            session.addInput(input)
            currentInput = input

            if !session.outputs.contains(output) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                output.alwaysDiscardsLateVideoFrames = true  // never queue behind a slow consumer
                output.setSampleBufferDelegate(self, queue: sampleQueue)
                guard session.canAddOutput(output) else { throw CaptureError.cannotAddOutput }
                session.addOutput(output)
            }
            applyFormat(to: device)
        } catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()

        // Frames are delivered un-mirrored; mirroring is a presentation concern (docs/tracking.md).
        if let c = output.connection(with: .video), c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = false
        }

        // startRunning() blocks; we are on sessionQueue, never the main thread or sample queue.
        if !session.isRunning { session.startRunning() }
        log.info("Capture running on \(device.localizedName, privacy: .public)")
        eventContinuation.yield(.started(deviceName: device.localizedName))
    }

    /// Picks a 16:9 device format (never a 4:3 one if any 16:9 exists) and pins 30 fps.
    ///
    /// Preference: 16:9, supports 30 fps, then 1280x720, then the smallest width above 1280 (1920x1080), then the
    /// closest below. Session presets are NOT used (they can resolve to 4:3 on external cameras); setting
    /// `activeFormat` switches the session to `.inputPriority`. If no 16:9 format exists the closest aspect wins
    /// and the Compositor aspect-fills (crops) it, never stretches.
    private func applyFormat(to device: AVCaptureDevice) {
        let fps = Double(Self.framesPerSecond)
        let target = CMTime(value: 1, timescale: CMTimeScale(Self.framesPerSecond))
        let wide = 16.0 / 9.0
        struct Candidate { let format: AVCaptureDevice.Format; let w: Int; let h: Int }
        let candidates: [Candidate] = device.formats.compactMap { f in
            guard f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && $0.maxFrameRate >= fps })
            else { return nil }
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Candidate(format: f, w: Int(d.width), h: Int(d.height))
        }
        func aspectError(_ c: Candidate) -> Double { abs(Double(c.w) / Double(max(1, c.h)) - wide) }
        // Lower key = better. 16:9 (error < 0.01) first, then width: exactly 1280, above 1280 ascending, below descending.
        func key(_ c: Candidate) -> (Int, Double, Int, Int) {
            let isWide = aspectError(c) < 0.01
            let widthRank = c.w == 1280 ? 0 : (c.w > 1280 ? 1 : 2)
            return (isWide ? 0 : 1, isWide ? 0 : aspectError(c), widthRank, widthRank == 2 ? -c.w : c.w)
        }
        guard let best = candidates.min(by: { key($0) < key($1) }) else {
            log.warning("No format supports \(Self.framesPerSecond) fps on \(device.localizedName, privacy: .public); leaving the device default")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best.format  // switches session to inputPriority
            device.activeVideoMinFrameDuration = target
            device.activeVideoMaxFrameDuration = target
            device.unlockForConfiguration()
        } catch {
            log.error("lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
        }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        log.info("Capture format on \(device.localizedName, privacy: .public): \(d.width)x\(d.height) @ \(Self.framesPerSecond) fps (\(aspectError(best) < 0.01 ? "16:9" : "NOT 16:9; compositor will crop", privacy: .public))")
    }

    // MARK: Hot-plug and errors

    private func installObservers() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                        object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            let uid = (note.object as? AVCaptureDevice)?.uniqueID
            let name = (note.object as? AVCaptureDevice)?.localizedName ?? "camera"
            self.sessionQueue.async { self.handleDisconnect(uniqueID: uid, name: name) }
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
                                        object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async { self.handleConnect() }
        })
        // https://developer.apple.com/documentation/avfoundation/avcapturesession/1387290-runtimeerrornotification
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                        object: session, queue: nil) { [weak self] note in
            let msg = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "unknown"
            guard let self else { return }
            self.sessionQueue.async { self.handleRuntimeError(msg) }
        })
    }

    private func handleDisconnect(uniqueID: String?, name: String) {
        guard let input = currentInput, input.device.uniqueID == uniqueID else { return }
        log.notice("Camera disconnected: \(name, privacy: .public)")
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
        currentInput = nil
        eventContinuation.yield(.deviceDisconnected(name: name))
    }

    private func handleConnect() {
        guard wantsRunning, currentInput == nil else { return }
        do {
            try configureAndRun()
            if let name = currentInput?.device.localizedName {
                eventContinuation.yield(.deviceReconnected(name: name))
            }
        } catch {
            log.error("Reconnect failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func handleRuntimeError(_ message: String) {
        log.error("Capture runtime error: \(message, privacy: .public)")
        eventContinuation.yield(.failed(message: message))
        guard wantsRunning else { return }
        // Retry once after a short delay; a persistent failure surfaces through `.failed` again.
        sessionQueue.asyncAfter(deadline: .now() + 1) {
            guard self.wantsRunning, !self.session.isRunning else { return }
            do { try self.configureAndRun() } catch {
                self.log.error("Restart failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - Sample buffer delegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Runs on `sampleQueue`. Must stay non-blocking.
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameContinuation.yield(CaptureFrame(pixelBuffer: pb,
                                             presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
}
