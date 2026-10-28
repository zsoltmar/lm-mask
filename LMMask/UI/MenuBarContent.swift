import AppKit
import SwiftUI

/// Window identifiers used with `openWindow`.
enum WindowID {
    static let preview = "preview"
}

/// Menu bar icon. Uses the template image "MenuBarIcon" from the asset catalog when present
/// (see docs/ui.md), otherwise the SF Symbol placeholder.
struct MenuBarIcon: View {
    var body: some View {
        if let image = NSImage(named: "MenuBarIcon") {
            let _ = image.isTemplate = true
            Image(nsImage: image)
        } else {
            Image(systemName: "theatermasks")
        }
    }
}

/// Menu bar label. Always loaded, so it also performs the first-launch work
/// (a menu-style MenuBarExtra does not build its content until clicked).
struct MenuBarLabel: View {
    let installer: ExtensionInstaller
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppPreferences.onboardingCompleted) private var onboardingCompleted = false

    var body: some View {
        MenuBarIcon()
            .task {
                if onboardingCompleted {
                    // Re-submitting an activation request is how the app learns the extension is active.
                    installer.activate()
                } else {
                    openWindow(id: WindowID.preview)
                    NSApp.activate()
                }
            }
    }
}

struct MenuBarContent: View {
    let pipeline: any MaskPipelineControlling
    let installer: ExtensionInstaller

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("LM Mask", isOn: Binding(get: { pipeline.enabled }, set: { pipeline.enabled = $0 }))

        Button("Open Preview…") {
            openWindow(id: WindowID.preview)
            NSApp.activate()
        }

        Button("Test Scare") { pipeline.testScare() }

        Divider()

        let state = installer.state
        Text("Camera Extension: \(state.title)")
        if !state.isActive {
            Button(state == .needsApproval ? "Open System Settings…" : "Enable Camera Extension") {
                if state == .needsApproval {
                    SystemSettingsLink.open(SystemSettingsLink.loginItemsAndExtensions)
                } else {
                    installer.activate()
                }
            }
        }

        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")

        Button("Quit LM Mask") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
