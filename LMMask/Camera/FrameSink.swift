import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import os

// CoreMediaIO C API notes (the easy-to-get-wrong part). Header reference:
// https://developer.apple.com/documentation/coremediaio/core-media-io-c-functions  (CMIOHardware.h family)
//
// 1. Enumerate devices
//    CMIOObjectGetPropertyDataSize / CMIOObjectGetPropertyData on kCMIOObjectSystemObject with
//    {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain}.
//    Returns an array of CMIODeviceID (UInt32). Size is in BYTES; count = size / 4.
//    https://developer.apple.com/documentation/coremediaio/kcmiohardwarepropertydevices
//    https://developer.apple.com/documentation/coremediaio/1475776-cmioobjectgetpropertydata
// 2. Device UID: kCMIODevicePropertyDeviceUID returns a CFString that the caller owns ("Copy" rule), so
//    read into Unmanaged<CFString>? and takeRetainedValue(). Compared case-insensitively with Identity.deviceUID.
//    https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertydeviceuid
// 3. Streams: kCMIODevicePropertyStreams (global scope) on the device returns [CMIOStreamID].
//    Direction: kCMIOStreamPropertyDirection (UInt32): 0 = source/output (frames come OUT of the device),
//    1 = sink/input (we push frames IN). Easy to invert; the sink is direction == 1.
//    https://developer.apple.com/documentation/coremediaio/kcmiodevicepropertystreams
//    https://developer.apple.com/documentation/coremediaio/kcmiostreampropertydirection
// 4. Queue: CMIOStreamCopyBufferQueue(stream, alteredProc, refCon, &queue) gives a +1 CMSimpleQueue.
//    For a sink we only enqueue, so alteredProc is nil. MUST be called BEFORE CMIODeviceStartStream.
//    https://developer.apple.com/documentation/coremediaio/1474779-cmiostreamcopybufferqueue
// 5. Start: CMIODeviceStartStream(device, stream). Stop: CMIODeviceStopStream.
//    https://developer.apple.com/documentation/coremediaio/1474802-cmiodevicestartstream
// 6. Enqueue: CMSimpleQueueEnqueue(queue, element:) with Unmanaged.passRetained(sampleBuffer).toOpaque();
//    the queue (consumer) releases it. If the call fails (queue full) WE must release, else it leaks.
//    https://developer.apple.com/documentation/coremedia/1489496-cmsimplequeueenqueue
// 7. Hot-plug: CMIOObjectAddPropertyListenerBlock(system object, kCMIOHardwarePropertyDevices, queue, block);
//    remove with the SAME block value via CMIOObjectRemovePropertyListenerBlock.
//    https://developer.apple.com/documentation/coremediaio/1475757-cmioobjectaddpropertylistenerblock
// Sample (Swift, sink app): https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o

/// Writes frames into the camera extension's sink stream.
///
/// Threading: `send` may be called from any thread (render/capture queue); it takes an unfair lock for a
/// pointer-sized read, builds one CMSampleBuffer wrapper (the pixel data is NOT copied) and enqueues. It never
/// blocks or waits: if the queue is full the frame is dropped. All (re)connection work runs on `controlQueue`.
final class FrameSink: @unchecked Sendable {
    enum State: Sendable, Equatable {
        case stopped
        case searching          // started, device/sink stream not found or not yet startable
        case connected
    }

    /// State changes (newest 8 buffered). Single consumer.
    let states: AsyncStream<State>

    var isConnected: Bool { conn.withLockUnchecked { $0.queue != nil } }

    private struct Connection {
        var queue: CMSimpleQueue?
        var formatDescription: CMVideoFormatDescription?
        var lastPTS: CMTime = .invalid
    }

    private let deviceUID: String
    private let log = Logger.lm("framesink")
    private let controlQueue = DispatchQueue(label: "com.lawmatics.lmmask.framesink.control")
    // CMSimpleQueue / CMVideoFormatDescription are not Sendable: use the unchecked lock variants.
    private let conn = OSAllocatedUnfairLock(uncheckedState: Connection())
    private let stateContinuation: AsyncStream<State>.Continuation

    // controlQueue-only
    private var wantsRunning = false
    private var openDevice: CMIODeviceID?
    private var openStream: CMIOStreamID?
    private var listener: CMIOObjectPropertyListenerBlock?
    private var retry: DispatchWorkItem?

    init(deviceUID: String = Identity.deviceUID) {
        self.deviceUID = deviceUID
        let s = AsyncStream.makeStream(of: State.self, bufferingPolicy: .bufferingNewest(8))
        states = s.stream
        stateContinuation = s.continuation
    }

    deinit { stateContinuation.finish() }

    // MARK: Public API

    /// Begins looking for the device and keeps the connection alive across device removal/re-adding.
    func start() {
        controlQueue.async { [self] in
            guard !wantsRunning else { return }
            wantsRunning = true
            installListener()
            stateContinuation.yield(.searching)
            reconnect()
        }
    }

    func stop() {
        controlQueue.async { [self] in
            wantsRunning = false
            retry?.cancel()
            removeListener()
            closeStream()
            stateContinuation.yield(.stopped)
        }
    }

    /// Enqueues one frame for the extension. `time` is the capture timestamp; it is forced to be strictly
    /// monotonic (the extension re-stamps with host time anyway). Returns false if the frame was dropped
    /// (not connected, queue full, or sample creation failed).
    /// https://developer.apple.com/documentation/coremedia/1489090-cmsamplebuffercreateforimagebuffer
    @discardableResult
    func send(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        // Hold the lock only to read/update small state; sample creation happens outside it.
        let snapshot = conn.withLockUnchecked { c -> (CMSimpleQueue, CMVideoFormatDescription?, CMTime)? in
            guard let q = c.queue else { return nil }
            var pts = time
            if c.lastPTS.isValid, pts <= c.lastPTS {
                pts = CMTimeAdd(c.lastPTS, CMTime(value: 1, timescale: 1_000_000)) // 1 us bump
            }
            c.lastPTS = pts
            return (q, c.formatDescription, pts)
        }
        guard let (queue, cachedDesc, pts) = snapshot else { return false }

        // Cached format description; recreate only if the buffer no longer matches (size/format change).
        var desc = cachedDesc
        if desc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(desc!, imageBuffer: pixelBuffer) {
            var d: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &d) == noErr,
                let d else { return false }
            desc = d
            conn.withLockUnchecked { $0.formatDescription = d }
        }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: FrameFormat.fps),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: desc!,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return false }

        let retained = Unmanaged.passRetained(sample)
        if CMSimpleQueueEnqueue(queue, element: retained.toOpaque()) != noErr {
            retained.release() // queue full: we still own the +1
            return false
        }
        return true
    }

    // MARK: Connection (controlQueue only)

    private static func systemAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func installListener() {
        guard listener == nil else { return }
        var addr = Self.systemAddress(kCMIOHardwarePropertyDevices)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            // Fires on controlQueue (we pass it below); hop explicitly anyway to keep a single path.
            guard let self else { return }
            self.controlQueue.async { self.deviceListChanged() }
        }
        let st = CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, controlQueue, block)
        if st == noErr { listener = block } else { log.error("add listener failed: \(st)") }
    }

    private func removeListener() {
        guard let block = listener else { return }
        var addr = Self.systemAddress(kCMIOHardwarePropertyDevices)
        CMIOObjectRemovePropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &addr, controlQueue, block)
        listener = nil
    }

    private func deviceListChanged() {
        guard wantsRunning else { return }
        // Device vanished? Our device ID no longer in the list -> drop the connection and search again.
        if let dev = openDevice, !Self.allDevices().contains(dev) {
            log.notice("camera device disappeared; closing sink")
            closeStream()
            stateContinuation.yield(.searching)
        }
        if openStream == nil { reconnect() }
    }

    private func reconnect() {
        guard wantsRunning, openStream == nil else { return }
        retry?.cancel()
        guard let (device, stream) = findSink() else {
            log.info("sink stream not found yet; waiting for device list change")
            scheduleRetry()
            return
        }
        // 4. queue first, then 5. start.
        var q: Unmanaged<CMSimpleQueue>?
        var st = CMIOStreamCopyBufferQueue(stream, nil, nil, &q)
        guard st == noErr, let q else {
            log.error("CMIOStreamCopyBufferQueue failed: \(st)")
            scheduleRetry(); return
        }
        let queue = q.takeRetainedValue()
        st = CMIODeviceStartStream(device, stream)
        guard st == noErr else {
            log.error("CMIODeviceStartStream failed: \(st)")
            scheduleRetry(); return
        }
        openDevice = device
        openStream = stream
        conn.withLockUnchecked { $0 = Connection(queue: queue, formatDescription: nil, lastPTS: .invalid) }
        log.info("sink open: device \(device) stream \(stream)")
        stateContinuation.yield(.connected)
    }

    private func closeStream() {
        conn.withLockUnchecked { $0.queue = nil }   // stop senders first
        if let d = openDevice, let s = openStream { CMIODeviceStopStream(d, s) }
        openDevice = nil
        openStream = nil
    }

    /// Safety net in addition to the listener (e.g. extension activated while we start).
    private func scheduleRetry() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.reconnect()
        }
        retry = item
        controlQueue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    // MARK: CMIO property helpers

    private func findSink() -> (CMIODeviceID, CMIOStreamID)? {
        for dev in Self.allDevices() {
            guard Self.deviceUID(dev)?.caseInsensitiveCompare(deviceUID) == .orderedSame else { continue }
            for s in Self.streams(of: dev) where Self.direction(of: s) == 1 {
                return (dev, s)
            }
            log.notice("device \(dev) found but has no sink stream (old extension version?)")
        }
        return nil
    }

    private static func allDevices() -> [CMIODeviceID] {
        var addr = systemAddress(kCMIOHardwarePropertyDevices)
        return objectArray(CMIOObjectID(kCMIOObjectSystemObject), &addr)
    }

    private static func streams(of device: CMIODeviceID) -> [CMIOStreamID] {
        var addr = systemAddress(kCMIODevicePropertyStreams)
        return objectArray(device, &addr)
    }

    private static func objectArray(_ obj: CMIOObjectID, _ addr: inout CMIOObjectPropertyAddress) -> [CMIOObjectID] {
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        let st = ids.withUnsafeMutableBytes {
            CMIOObjectGetPropertyData(obj, &addr, 0, nil, size, &used, $0.baseAddress!)
        }
        return st == noErr ? Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size)) : []
    }

    private static func deviceUID(_ device: CMIODeviceID) -> String? {
        var addr = systemAddress(kCMIODevicePropertyDeviceUID)
        var cf: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let st = withUnsafeMutablePointer(to: &cf) {
            CMIOObjectGetPropertyData(device, &addr, 0, nil, size, &used, $0)
        }
        guard st == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    private static func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = systemAddress(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let st = CMIOObjectGetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return st == noErr ? value : nil
    }
}

/// Integration: `FrameSink` already has the exact `send`/`start`/`stop` shape of `FrameOutput` (Shared/FrameOutput.swift).
extension FrameSink: FrameOutput {}
