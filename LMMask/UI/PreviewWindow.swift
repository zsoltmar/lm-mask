import SwiftUI

/// The main window: composited output at 16:9, live controls, optional tracking overlay.
struct PreviewWindow: View {
    let pipeline: any MaskPipelineControlling
    let installer: ExtensionInstaller

    @AppStorage(AppPreferences.onboardingCompleted) private var onboardingCompleted = false
    @State private var showOverlay = false
    @State private var showOnboarding = false
    @State private var showTune = false
    /// Mirrors only the preview image (the stream sent to Zoom is never mirrored; Zoom mirrors self-view itself).
    @AppStorage(PlacementDebugHub.mirrorPreviewKey) private var mirrorPreview = false

    var body: some View {
        VStack(spacing: 0) {
            stage
                .padding([.horizontal, .top], 20)
                .padding(.bottom, 4)

            Form {
                Section {
                    SliderRow(title: "Mask size", value: maskScale,
                              range: MaskSettingsSpec.maskScaleRange) { String(format: "%.1f×", $0) }
                    SliderRow(title: "Vertical position", value: verticalOffset,
                              range: MaskSettingsSpec.verticalOffsetRange) { String(format: "%+.2f", $0) }
                    LabeledContent("Eye calibration") {
                        Button("Recalibrate") { pipeline.recalibrate() }
                    }
                }
                Section {
                    Toggle("Show tracking overlay", isOn: $showOverlay)
                    Toggle("Mirror preview", isOn: $mirrorPreview)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        // Right-hand inspector with the look parameters. The main column stays 560 pt; the window grows by the
        // inspector's width while it is open.
        .inspector(isPresented: $showTune) {
            TunePanel(pipeline: pipeline)
                .inspectorColumnWidth(min: 288, ideal: 320, max: 400)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Mask", isOn: Binding(get: { pipeline.enabled }, set: { pipeline.enabled = $0 }))
                    .toggleStyle(.switch)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showTune.toggle() } label: {
                    Label("Tune", systemImage: "slider.horizontal.3")
                }
                .help("Show or hide the look controls")
            }
        }
        .navigationTitle("LM Mask")
        .onAppear {
            pipeline.previewEnabled = true
            // The pipeline is owned by the app, not this window: closing the window must not stop the camera feed.
            if !onboardingCompleted { showOnboarding = true }
        }
        .onDisappear { pipeline.previewEnabled = false }
        .sheet(isPresented: $showOnboarding) {
            OnboardingSheet(installer: installer) {
                onboardingCompleted = true
                showOnboarding = false
            }
        }
    }

    @ViewBuilder private var stage: some View {
        ZStack {
            if showOverlay {
                // LandmarkDebugView runs its own capture session while visible.
                LandmarkDebugView()
            } else if let image = pipeline.previewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: mirrorPreview ? -1 : 1, y: 1)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: pipeline.enabled ? "camera" : "camera.slash")
                        .font(.system(size: 28, weight: .light))
                    Text(pipeline.enabled ? "Waiting for camera…" : "Mask is off")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
        .overlay(alignment: .topLeading) {
            if pipeline.style.scare.enabled {
                ScarePill(active: pipeline.scareActive)
                    .padding(8)
            }
        }
    }

    private var maskScale: Binding<Double> {
        Binding(get: { pipeline.maskScale }, set: { pipeline.maskScale = $0 })
    }
    private var verticalOffset: Binding<Double> {
        Binding(get: { pipeline.verticalOffset }, set: { pipeline.verticalOffset = $0 })
    }
}

/// Small "SCARE" status pill: a quiet grey capsule while armed, lit orange while scare mode is on.
private struct ScarePill: View {
    let active: Bool

    var body: some View {
        Text("SCARE")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(0.8)
            .foregroundStyle(active ? Color.black.opacity(0.85) : Color.white.opacity(0.7))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(active ? Color.orange : Color.black.opacity(0.35)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(active ? 0.0 : 0.15)))
            .shadow(color: active ? Color.orange.opacity(0.6) : .clear, radius: 6)
            .animation(.easeOut(duration: 0.15), value: active)
            .accessibilityLabel(active ? "Scare mode active" : "Scare mode armed")
    }
}

/// Label, slider and a fixed-width live value, aligned across rows.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range)
                    .frame(width: 220)
                    .labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Preview window") {
    PreviewWindow(pipeline: MockPipeline(), installer: ExtensionInstaller())
}
