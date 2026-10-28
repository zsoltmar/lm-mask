import CoreMedia
import CoreMediaIO
import Foundation
import os

// https://developer.apple.com/documentation/coremediaio/cmioextensiondevicesource
// One device, two streams: a source stream (what Zoom reads) and a sink stream (what the host app writes).
// Sink/source pattern: WWDC22 "Create camera extensions with Core Media IO",
// https://developer.apple.com/videos/play/wwdc2022/10022/

private let log = Logger.lm("camera")

final class CameraDeviceSource: NSObject, CMIOExtensionDeviceSource, @unchecked Sendable {
    private(set) var device: CMIOExtensionDevice!
    private var sourceStream: SourceStreamSource!
    private var sinkStream: SinkStreamSource!

    init(localizedName: String) {
        super.init()
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: Identity.deviceID,
                                     legacyDeviceID: nil, source: self)
        sourceStream = SourceStreamSource(localizedName: "\(localizedName) Video", device: device)
        sinkStream = SinkStreamSource(localizedName: "\(localizedName) Sink", device: device,
                                      source: sourceStream)
        do {
            try device.addStream(sourceStream.stream)
            try device.addStream(sinkStream.stream)
        } catch {
            log.error("addStream failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        // 'virt' == kIOAudioDeviceTransportTypeVirtual (IOKit/audio/IOAudioTypes.h), inlined
        // to avoid importing IOKit.audio. TODO(verify in Xcode): property type is Int.
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 }
        if properties.contains(.deviceModel) { p.model = "LM Mask Virtual Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}
}
