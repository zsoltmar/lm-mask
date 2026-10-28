import AVFoundation
import SwiftUI

/// First-run flow: camera permission, enable the extension, pick the camera in Zoom.
/// Progress persists in UserDefaults (`onboardingStep`), so quitting mid-way resumes at the same step.
struct OnboardingSheet: View {
    let installer: ExtensionInstaller
    var onFinish: () -> Void

    @AppStorage(AppPreferences.onboardingStep) private var stepIndex = 0
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)

    private enum Step: Int, CaseIterable { case camera, extensionApproval, zoom }
    private var step: Step { Step(rawValue: min(max(stepIndex, 0), Step.allCases.count - 1)) ?? .camera }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(height: 44)
                Text(title).font(.title2.weight(.semibold))
                content
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                statusLine
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 20)

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            .padding(.bottom, 14)

            Divider()
            HStack {
                if step != .camera {
                    Button("Back") { stepIndex = step.rawValue - 1 }
                }
                Spacer()
                secondaryAction
                primaryAction
            }
            .padding(16)
        }
        .frame(width: 460, height: 400)
        .interactiveDismissDisabled()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    // MARK: Content per step

    private var symbol: String {
        switch step {
        case .camera: "camera"
        case .extensionApproval: "puzzlepiece.extension"
        case .zoom: "video"
        }
    }

    private var title: String {
        switch step {
        case .camera: "Allow camera access"
        case .extensionApproval: "Enable the camera extension"
        case .zoom: "Choose LM Halloween Cam in Zoom"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .camera:
            Text("LM Mask needs your camera to follow your face. Video stays on this Mac.")
        case .extensionApproval:
            Text("macOS needs your approval once. Open System Settings, go to General, Login Items & Extensions, then Camera Extensions, and turn on LM Mask. On macOS 14, click Allow in Privacy & Security instead.")
        case .zoom:
            Text("In Zoom, open Settings, then Video, and choose “LM Halloween Cam” as your camera. If it isn’t listed, quit and reopen Zoom.")
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch step {
        case .camera:
            switch cameraStatus {
            case .authorized: statusLabel("Camera access granted", ok: true)
            case .denied, .restricted: statusLabel("Camera access is off. Turn it on in Privacy & Security.", ok: false)
            default: EmptyView()
            }
        case .extensionApproval:
            let state = installer.state
            switch state {
            case .active: statusLabel("Camera extension is active", ok: true)
            case .needsApproval: statusLabel("Waiting for your approval in System Settings", ok: false)
            case .requesting: statusLabel("Enabling…", ok: false)
            case .failed(let message): statusLabel(message, ok: false)
            case .notInstalled: EmptyView()
            }
        case .zoom:
            EmptyView()
        }
    }

    private func statusLabel(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(ok ? Color.green : Color.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: Actions

    @ViewBuilder private var secondaryAction: some View {
        switch step {
        case .camera where cameraStatus == .denied || cameraStatus == .restricted:
            Button("Open Privacy Settings") { SystemSettingsLink.open(SystemSettingsLink.cameraPrivacy) }
        case .extensionApproval where installer.state == .needsApproval:
            Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.loginItemsAndExtensions) }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryAction: some View {
        switch step {
        case .camera:
            if cameraStatus == .authorized {
                Button("Continue") { stepIndex = Step.extensionApproval.rawValue }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Allow Camera Access") {
                    if cameraStatus == .notDetermined {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .video)
                            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                    } else {
                        SystemSettingsLink.open(SystemSettingsLink.cameraPrivacy)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        case .extensionApproval:
            if installer.state.isActive {
                Button("Continue") { stepIndex = Step.zoom.rawValue }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(installer.state == .requesting ? "Enabling…" : "Enable Extension") { installer.activate() }
                    .disabled(installer.state == .requesting)
                    .keyboardShortcut(.defaultAction)
            }
        case .zoom:
            Button("Done") {
                stepIndex = 0
                onFinish()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("Onboarding") {
    OnboardingSheet(installer: ExtensionInstaller()) {}
}
