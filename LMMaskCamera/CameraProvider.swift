import CoreMediaIO
import Foundation
import os

// Structure follows Apple's "Creating a camera extension with Core Media I/O":
// https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
// Protocols: https://developer.apple.com/documentation/coremediaio/cmioextensionprovidersource
//
// File layout: CameraProvider (this file) -> CameraDevice -> SourceStream + SinkStream (+ TestPattern).

private let log = Logger.lm("camera")

final class CameraProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    // Immutable after init.
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(localizedName: Identity.deviceName)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            log.error("addDevice failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // https://developer.apple.com/documentation/coremediaio/cmioextensionclient
    func connect(to client: CMIOExtensionClient) throws {
        log.info("client connected pid=\(client.pid) signingID=\(client.signingID ?? "?", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        log.info("client disconnected pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = Identity.manufacturer }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
