import Foundation
import Observation
import SystemExtensions
import os

/// Submits activation/deactivation requests for the embedded camera extension.
/// API: https://developer.apple.com/documentation/systemextensions/ossystemextensionrequest
/// Flow follows "Creating a camera extension with Core Media I/O":
/// https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
@MainActor
@Observable
final class ExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    /// What the UI shows. `ExtensionState` is declared in UI/PipelineContract.swift.
    private(set) var state: ExtensionState = .notInstalled
    /// Free-form detail for logs/debugging.
    private(set) var status = "not requested"
    @ObservationIgnored private let log = Logger.lm("installer")
    /// Requests that are deactivations, so a finished one maps to `.notInstalled` instead of `.active`.
    @ObservationIgnored private var deactivations = Set<ObjectIdentifier>()

    func activate() {
        submit(OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Identity.extensionBundleID, queue: .main))
    }

    func deactivate() {
        let request = OSSystemExtensionRequest.deactivationRequest(
            forExtensionWithIdentifier: Identity.extensionBundleID, queue: .main)
        deactivations.insert(ObjectIdentifier(request))
        submit(request)
    }

    private func submit(_ request: OSSystemExtensionRequest) {
        request.delegate = self
        status = "request submitted"
        state = .requesting
        log.info("submitting request for \(Identity.extensionBundleID, privacy: .public)")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: OSSystemExtensionRequestDelegate (called on the main queue we passed in)

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.update("needs approval: System Settings > Privacy & Security", state: .needsApproval)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let text = result == .completed ? "finished" : "finished (reboot required)"
        let id = ObjectIdentifier(request)
        Task { @MainActor in
            let wasDeactivation = self.deactivations.remove(id) != nil
            self.update(text, state: wasDeactivation ? .notInstalled : .active)
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let message = error.localizedDescription
        let text = "failed: \(message)"
        let id = ObjectIdentifier(request)
        Task { @MainActor in
            _ = self.deactivations.remove(id)
            self.update(text, state: .failed(message))
        }
    }

    private func update(_ text: String, state newState: ExtensionState) {
        status = text
        state = newState
        log.info("extension status: \(text, privacy: .public)")
    }
}
