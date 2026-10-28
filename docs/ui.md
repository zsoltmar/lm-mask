# App shell notes (Brief F)

## Structure (LMMask/UI/)
- `PipelineContract.swift`: `MaskPipelineControlling`, `ExtensionState`, `MaskSettingsSpec`, `MockPipeline`.
- `LMMaskApp.swift`: `MenuBarExtra` (menu style), `Window` id `preview`, `Settings` scene. `LMMaskApp.makePipeline()` is the single switch from mock to real pipeline.
- `MenuBarContent.swift`: menu items; `MenuBarLabel` also does first-launch work (opens the window when onboarding is incomplete, otherwise re-submits the extension activation request so state is known).
- `PreviewWindow.swift`, `OnboardingSheet.swift`, `SettingsView.swift`.
- `ExtensionState+Installer.swift`: maps `ExtensionInstaller.status` (string) to `ExtensionState`.
- `AppPreferences.swift`: UserDefaults keys (`onboardingCompleted`, `onboardingStep`, `preferredCameraID`) and System Settings URLs.

The pipeline is owned by the app, not the preview window: closing the window must not stop the camera feed Zoom is using.

## Menu bar icon
Placeholder: SF Symbol `theatermasks`. For the real mark add `Assets.xcassets/MenuBarIcon.imageset`:
- Single-color, transparent background, 18 x 18 pt canvas (36 px @2x, 54 px @3x is optional on macOS).
- `Contents.json` property `"template-rendering-intent": "template"`. Provide `MenuBarIcon.pdf` (vector, preserve vector data) or png at 1x/2x.
- The app loads `NSImage(named: "MenuBarIcon")` and forces `isTemplate = true`; if the image is missing it falls back to the symbol. Add an `Assets.xcassets` to the app target in project.yml (XcodeGen picks it up from the `LMMask` source path).

## System Settings deep links
- `x-apple.systempreferences:com.apple.LoginItems-Settings.extension`: General > Login Items & Extensions (macOS 13+). This is the best known URL for camera extensions on 15/26; it opens the pane, the user then scrolls to Extensions > Camera Extensions. There is no documented deep link to the Camera Extensions sub-list.
- `x-apple.systempreferences:com.apple.preference.security?Privacy`: Privacy & Security (macOS 14 approval prompt for blocked system software).
- `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera`: camera permission list.
These are unofficial and not verified on every release; see QUESTIONS.md F2.

## Tracking overlay
"Show tracking overlay" replaces the preview with `LandmarkDebugView`, which runs its own `CameraCapture` while visible. Two sessions on one camera is allowed by AVFoundation, but it doubles Vision work; the pipeline may want to pause tracking while the overlay is on.
