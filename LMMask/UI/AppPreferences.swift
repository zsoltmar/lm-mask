import AVFoundation
import AppKit
import Foundation

/// UserDefaults keys and small helpers shared by the app shell.
enum AppPreferences {
    static let onboardingCompleted = "onboardingCompleted"
    static let onboardingStep = "onboardingStep"
    /// `AVCaptureDevice.uniqueID` of the preferred input; empty = automatic.
    /// The capture layer (CameraCapture.pickDevice) must read this key; see QUESTIONS.md F3.
    static let preferredCameraID = "preferredCameraID"

    /// Persisted by `RenderPipeline` (QUESTIONS.md F4).
    static let maskScale = "maskScale"
    /// Round 5 moved the default from +0.35 to 0 (the eyes must land inside the eye windows), so the key changed: an old
    /// stored value would silently pin the mask 0.35 face-heights too high.
    static let verticalOffset = "verticalOffset.v5"
    private static let legacyKeys = ["mouthScale", "blinkSensitivity", "verticalOffset"]

    static func resetAll() {
        let d = UserDefaults.standard
        d.removeObject(forKey: onboardingCompleted)
        d.removeObject(forKey: onboardingStep)
        d.removeObject(forKey: preferredCameraID)
        d.removeObject(forKey: maskScale)
        d.removeObject(forKey: verticalOffset)
        for k in legacyKeys { d.removeObject(forKey: k) }
    }

    /// Cameras the user can choose as input. Our own virtual camera is excluded.
    static func availableCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified
        ).devices.filter { !$0.localizedName.hasPrefix(Identity.deviceName) && !$0.localizedName.hasPrefix("LM Mask") }
    }
}

/// System Settings deep links. Documented in docs/ui.md.
enum SystemSettingsLink {
    /// General > Login Items & Extensions (macOS 13+). Camera Extensions live under "Extensions" on macOS 15+.
    static let loginItemsAndExtensions = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
    /// Privacy & Security, where macOS 14 shows the "System software was blocked" Allow button.
    static let privacyAndSecurity = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
    static let cameraPrivacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!

    @MainActor static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
