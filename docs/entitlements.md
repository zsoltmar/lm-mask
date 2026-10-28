# Entitlements and Info.plist keys

## App (`LMMask/LMMask.entitlements`)

| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | Mac App Sandbox; required baseline and expected for a camera extension host. |
| `com.apple.security.device.camera` | The app reads the physical camera (later briefs) under the sandbox. |
| `com.apple.developer.system-extension.install` | Allows `OSSystemExtensionRequest` to activate the embedded camera extension. Needs a provisioning profile that carries the capability (Xcode Automatic signing creates it for dev builds; Developer ID needs the capability enabled on the App ID). |
| `com.apple.security.application-groups` = `$(TeamIdentifierPrefix)group.com.lawmatics.lmmask` | Shared container/IPC namespace between app and extension. |

## Extension (`LMMaskCamera/LMMaskCamera.entitlements`)

| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | Camera extensions run sandboxed. |
| `com.apple.security.application-groups` (same value) | Lets the extension use the group and the mach service name below. |

## Info.plist

App: `NSCameraUsageDescription` (TCC prompt text), `NSSystemExtensionUsageDescription` (shown in the approval dialog), `LSUIElement` (menu bar only, no Dock icon).

Extension: `CFBundlePackageType = SYSX`, and
`CMIOExtension > CMIOExtensionMachServiceName = $(TeamIdentifierPrefix)group.com.lawmatics.lmmask`.

### TeamID placeholder

The mach service name must be `<TeamID>.group.com.lawmatics.lmmask`, and must be prefixed with an app group the extension is entitled to. `$(TeamIdentifierPrefix)` expands to `<TeamID>.` (with the dot) from `DEVELOPMENT_TEAM`, which comes from the gitignored `Config/Local.xcconfig`. Nothing needs hand-editing. The same expansion is used in the app group entitlement so the two always match. See QUESTIONS.md Q1.

References:
- https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o
- https://developer.apple.com/documentation/systemextensions
- https://developer.apple.com/documentation/xcode/configuring-app-groups
