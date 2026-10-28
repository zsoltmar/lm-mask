import CoreMediaIO
import Foundation

// Entry point, same shape as Apple's sample:
// https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
