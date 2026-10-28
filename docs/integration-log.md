# Integration log

Integration pass over the six parallel briefs. Nothing was compiled (no Xcode available). Line numbers are as of the end of the pass.

## Wiring

| File:line | Change | Why |
|---|---|---|
| LMMask/Camera/FrameSink.swift:290 | `extension FrameSink: FrameOutput {}` | Brief D9; FrameSink already has the matching `send`/`start`/`stop`. |
| LMMask/LMMaskApp.swift:8-19 | Added `init()` that builds one `ExtensionInstaller` and passes it to `makePipeline(installer:)`, which now returns `RenderPipeline(output: FrameSink(), installer:)` | Real pipeline instead of MockPipeline (kept in PipelineContract.swift for previews). A `@State` default value cannot reference the sibling installer, hence the explicit init. |
| LMMask/Pipeline/RenderPipeline.swift:186, 204, 216-219 | `extensionState` is now computed from an optional `installer` passed to `init` | QUESTIONS F1: pipeline forwards the installer's state. Observable, because `ExtensionInstaller` is `@Observable`. |
| LMMask/ExtensionInstaller.swift:14-19, 29, 56-80 | New stored `state: ExtensionState`; tracks deactivation requests by `ObjectIdentifier` so a finished deactivation gives `.notInstalled`; failures carry the message | QUESTIONS F1. `status` string kept for logs. |
| LMMask/UI/ExtensionState+Installer.swift | Emptied (comment only) | The string-parsing `state` computed property would clash with the stored one. The sandbox refused `rm`; delete the file by hand if wanted. |
| LMMask/Tracking/CameraCapture.swift:68, 126-147 | Default exclusion prefix is `Identity.deviceName` (was "LM Mask"); `pickDevice()` also skips "LM Mask", and honours `AppPreferences.preferredCameraID` when that camera is present | QUESTIONS A2.2, B6, F3. |
| LMMask/Pipeline/RenderPipeline.swift:176-180, 219-228, 318-323 | maskScale / mouthScale / blinkSensitivity loaded from UserDefaults in `init` (clamped to `MaskSettingsSpec` ranges) and written in `didSet` | QUESTIONS F4. |
| LMMask/UI/AppPreferences.swift (keys + `resetAll`) | New keys `maskScale`, `mouthScale`, `blinkSensitivity`, removed by `resetAll()` | Shared key names between the pipeline and Reset. |
| LMMask/UI/PipelineContract.swift:58, 86 | Protocol gained `previewEnabled { get set }`; MockPipeline has it | `RenderPipeline` only produces `previewImage` while `previewEnabled` is true and nothing ever set it, so the preview would stay on "Waiting for camera". |
| LMMask/UI/PreviewWindow.swift:47, 51 | `onAppear` sets `previewEnabled = true`, `onDisappear` false | Same. |

## Bugs / coherence fixes

| File:line | Change | Why |
|---|---|---|
| LMMask/Pipeline/RenderPipeline.swift:257-275, `stop()` | Frame/event consumer tasks are created once and no longer cancelled in `stop()` | `CameraCapture.frames/events` are single-consumer `AsyncStream`s; a cancelled `for await` finishes the stream for good, so Settings' stop()/start() on camera change (and the failure path) would have left the pipeline dead. |
| LMMask/Pipeline/RenderPipeline.swift:309-316 | `pushSettings()` builds the `RenderSettings` value first, then `withLock { $0 = snapshot }` | The old closure read main-actor properties (`enabled`, ...) inside an `@Sendable` lock body: Swift 6 error. |
| LMMask/Pipeline/RenderPipeline.swift:38-44 | `FrameSlot.store` boxes the buffer before the lock body; `load` uses `withLockUnchecked` | `CVPixelBuffer` is not Sendable (capture in `@Sendable` body, non-Sendable result). |
| LMMask/Camera/FrameSink.swift:64 and all `conn.withLock` | `OSAllocatedUnfairLock(uncheckedState:)` and `withLockUnchecked` | State and results hold `CMSimpleQueue` / `CMVideoFormatDescription`. |
| LMMask/Camera/FrameSink.swift:164, 227 | `[weak self]` then `guard let self` before hopping queues | Avoid capturing the weak var in a nested `@Sendable` closure. |
| LMMask/Tracking/CameraCapture.swift (3 observers) | Same `guard let self` pattern | Same. |
| LMMaskCamera/SinkStream.swift (whole file, bottom half) | Typed `CMIOExtensionStreamProperties` setters instead of `[CMIOExtensionProperty: CMIOExtensionPropertyState<NSObject>]`; dropped `streamSinkBufferUnderrunCount` / `streamSinkEndOfData` | The dictionary's generic argument is `AnyObject`, not `NSObject`, and `CMTime as NSValue` does not bridge. The brief flagged this as a likely failure. |
| LMMaskCamera/SinkStream.swift `consume(generation:)` | Client is read from `state` instead of captured by the escaping completion handler; unchecked lock | `CMIOExtensionClient` is not known to be Sendable. |
| LMMaskCamera/SourceStream.swift | Unchecked lock | State holds a `DispatchSourceTimer`; avoids depending on its Sendable status. |
| LMMask/Tracking/FaceTracker.swift:310 | `Calibration.add` sorts local copies | `resolve(&left)` on a method of `self` while `left` is inout is an overlapping-access error. |
| LMMask/Rendering/Compositor.swift:60, LogoFace.swift:54 | `nonisolated(unsafe)` on static lets of `CFDictionary` / `NSColor` | Swift 6 "static property is not concurrency-safe". |

## Build configuration

| File | Change | Why |
|---|---|---|
| project.yml (LMMask settings) | `PRODUCT_MODULE_NAME: LMMask` | `PRODUCT_NAME` is "LM Mask", which gives module `LM_Mask`; the tests use `@testable import LMMask`. |
| project.yml (new target) | `LMMaskTests` (`bundle.unit-test`, hosted by the app, explicit `TEST_HOST`/`BUNDLE_LOADER`), plus a `LMMask` scheme that builds both targets and runs the tests | The test target did not exist at all. |

## Checked, no change needed

- Bundle IDs: app `com.lawmatics.lmmask`, extension `com.lawmatics.lmmask.camera` match `Identity` and the installer request.
- App group / mach service: both entitlements and the extension's `CMIOExtensionMachServiceName` use `$(TeamIdentifierPrefix)group.com.lawmatics.lmmask`.
- Embed: `LMMaskCamera` is a `system-extension` target embedded by the app (`embed: true`, `codeSign: true`). Extension product name is the bundle id, matching README-dev.
- `Shared/` compiled into both targets; it only imports CoreMedia, CoreVideo, Foundation, os (no AppKit/SwiftUI). `Compositor.metal` is picked up from `LMMask/`.
- Constants: FOV 60 degrees is defined once (`HeadPoseGeometry.defaultHorizontalFOV`) and used by tracker and SceneKit camera; 1280x720@30 in `FrameFormat`, `CameraCapture`, `Compositor`; device name/UID from `Identity` everywhere. No duplicate type names (two private `State` structs are in different files).
- `MaskPipelineControlling` members all exist on `RenderPipeline` with matching types.
