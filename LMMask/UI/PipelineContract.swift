import CoreGraphics
import Foundation
import Observation

// The UI codes against this file only. RenderPipeline conforms to `MaskPipelineControlling`
// (add `extension RenderPipeline: MaskPipelineControlling {}` once its members match), and
// `LMMaskApp.makePipeline()` is the single place that picks the real implementation.

/// State of the camera system extension as the UI shows it.
/// `ExtensionInstaller.state` publishes this type directly; `RenderPipeline.extensionState` forwards it.
enum ExtensionState: Equatable, Sendable {
    case notInstalled
    case requesting
    case needsApproval
    case active
    case failed(String)

    var isActive: Bool { self == .active }

    /// Short label for menus and settings ("Camera Extension: <title>").
    var title: String {
        switch self {
        case .notInstalled: "Not enabled"
        case .requesting: "Enabling…"
        case .needsApproval: "Waiting for approval"
        case .active: "Active"
        case .failed: "Error"
        }
    }
}

/// Ranges and defaults for the user-facing settings. Single source of truth for sliders and Reset.
enum MaskSettingsSpec {
    static let maskScaleRange: ClosedRange<Double> = 1.8...3.2
    static let maskScaleDefault = 2.4
    /// Whole-headpiece shift as a fraction of face height, positive = up. Default 0: the eye windows sit exactly on the user's eyes.
    static let verticalOffsetRange: ClosedRange<Double> = -0.5...1.0
    static let verticalOffsetDefault = 0.0
}

/// What the app shell needs from the render pipeline. Main-actor isolated so SwiftUI can read and write directly.
@MainActor
protocol MaskPipelineControlling: AnyObject, Observable {
    /// Master switch. Off = the extension shows its idle frame (solid logo blue) instead of the mask.
    var enabled: Bool { get set }
    /// Logo size relative to the face. 1.8...3.2, default 2.4.
    var maskScale: Double { get set }
    /// Vertical position of the whole headpiece, fraction of face height, positive = up. -0.5...1.0, default 0.
    /// On top of the eye-socket-to-eye matching; follows head roll.
    var verticalOffset: Double { get set }
    /// Look of the headpiece (all the "Tune" panel sliders). Persisted by the pipeline.
    var style: MaskStyle { get set }
    /// Latest composited 1280x720 frame (the same pixels the extension receives), nil until the first frame.
    var previewImage: CGImage? { get }
    /// True while capture + render are running.
    var isRunning: Bool { get }
    /// The preview window sets this while it is on screen; `previewImage` is only produced while true.
    var previewEnabled: Bool { get set }
    /// Current state of the camera extension.
    var extensionState: ExtensionState { get }

    func start()
    func stop()
    /// Restart eye-open calibration (keep eyes open for about three seconds).
    func recalibrate()
    /// True while scare mode (mouth + eyes wide, or a test scare) is on. Drives the "SCARE" pill.
    var scareActive: Bool { get }
    /// Holds scare mode on for 2 s ("Test scare" button, menu item).
    func testScare()
}

extension MaskPipelineControlling {
    func resetSettingsToDefaults() {
        maskScale = MaskSettingsSpec.maskScaleDefault
        verticalOffset = MaskSettingsSpec.verticalOffsetDefault
    }

    func resetStyle() { style = MaskStyle() }
}

/// In-memory stand-in used by previews and until the real pipeline lands.
@MainActor
@Observable
final class MockPipeline: MaskPipelineControlling {
    var enabled = true
    var maskScale = MaskSettingsSpec.maskScaleDefault
    var verticalOffset = MaskSettingsSpec.verticalOffsetDefault
    var style = MaskStyle()
    private(set) var previewImage: CGImage?
    private(set) var isRunning = false
    var previewEnabled = false
    var extensionState: ExtensionState

    init(extensionState: ExtensionState = .active) {
        self.extensionState = extensionState
    }

    func start() { isRunning = true }
    func stop() { isRunning = false }
    func recalibrate() {}

    private(set) var scareActive = false
    func testScare() {
        scareActive = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.scareActive = false
        }
    }
}
