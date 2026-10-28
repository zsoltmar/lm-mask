import AVFoundation
import ServiceManagement
import SwiftUI
import os

struct SettingsView: View {
    let pipeline: any MaskPipelineControlling

    @AppStorage(AppPreferences.preferredCameraID) private var preferredCameraID = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var cameras = AppPreferences.availableCameras()
    @State private var confirmReset = false
    private let log = Logger.lm("settings")

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in setLaunchAtLogin(wanted) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                Picker("Camera", selection: $preferredCameraID) {
                    Text("Automatic").tag("")
                    if !preferredCameraID.isEmpty, !cameras.contains(where: { $0.uniqueID == preferredCameraID }) {
                        Text("Unavailable camera").tag(preferredCameraID)
                    }
                    Divider()
                    ForEach(cameras, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }
                .onChange(of: preferredCameraID) { _, _ in
                    // Capture picks the device at start; restart so the change applies immediately.
                    if pipeline.isRunning { pipeline.stop(); pipeline.start() }
                }
            } footer: {
                Text("The camera LM Mask reads from. Zoom still uses “LM Halloween Cam”.")
            }

            Section {
                Button("Reset…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Restores mask size, mouth size and blink sensitivity, forgets the camera choice, and shows the setup guide again.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            cameras = AppPreferences.availableCameras()
        }
        .confirmationDialog("Reset LM Mask?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                pipeline.resetSettingsToDefaults()
                AppPreferences.resetAll()
                preferredCameraID = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can’t be undone.")
        }
    }

    private func setLaunchAtLogin(_ wanted: Bool) {
        do {
            if wanted { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            log.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            launchError = "Couldn’t change this setting: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

#Preview("Settings") {
    SettingsView(pipeline: MockPipeline())
}
