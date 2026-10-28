import SwiftUI

@main
struct LMMaskApp: App {
    @State private var installer: ExtensionInstaller
    @State private var pipeline: any MaskPipelineControlling

    init() {
        // The pipeline forwards the installer's state, so both must be built together.
        let installer = ExtensionInstaller()
        _installer = State(initialValue: installer)
        _pipeline = State(initialValue: LMMaskApp.makePipeline(installer: installer))
    }

    /// The one place that chooses the pipeline implementation. `MockPipeline` stays for previews/tests.
    @MainActor static func makePipeline(installer: ExtensionInstaller) -> any MaskPipelineControlling {
        let p = RenderPipeline(output: FrameSink(), installer: installer)
        p.start()
        return p
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(pipeline: pipeline, installer: installer)
        } label: {
            MenuBarLabel(installer: installer)
        }
        .menuBarExtraStyle(.menu)

        Window("LM Mask", id: WindowID.preview) {
            PreviewWindow(pipeline: pipeline, installer: installer)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("Mask") {
                Button("Test Scare") { pipeline.testScare() }
                    .keyboardShortcut("s", modifiers: [.option, .command])
            }
        }

        Settings {
            SettingsView(pipeline: pipeline)
        }
    }
}
