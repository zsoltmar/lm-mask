# LM Mask: developer setup

Requirements: macOS 14+, Xcode 16, an Apple Developer team, XcodeGen (`brew install xcodegen`).

## Build
1. `cp Config/Local.xcconfig.example Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your 10-character Team ID.
2. `xcodegen generate` (creates `LMMask.xcodeproj`, which is gitignored).
3. `open LMMask.xcodeproj`. In Signing & Capabilities for both targets confirm Team is set and "Automatically manage signing" is on. Xcode will create profiles for the app group and System Extension capability.
4. Select scheme `LMMask`, destination My Mac, Product > Build (Cmd-B). Check `LMMask.app/Contents/Library/SystemExtensions/com.lawmatics.lmmask.camera.systemextension` exists in the build products.

## Run and activate the extension
System extensions only activate from an app in `/Applications`.
1. Product > Show Build Folder in Finder, copy `LM Mask.app` to `/Applications` (replace the old one).
2. (Dev machines, optional) `systemextensionsctl developer on` lets you test outside /Applications; it needs SIP-permitting setup, so prefer /Applications.
3. Launch `/Applications/LM Mask.app`. Click the mask icon in the menu bar, then "Activate camera extension".
4. Approve in System Settings > Privacy & Security (scroll to the blocked system software message, Allow). Enter your password.
5. Verify: `systemextensionsctl list` shows `com.lawmatics.lmmask.camera` as `[activated enabled]`.
6. Open Photo Booth, QuickTime (New Movie Recording) or Zoom, pick "LM Halloween Cam": you should see solid blue (#009CE4).

Logs: `log stream --predicate 'subsystem == "com.lawmatics.lmmask"' --level debug`

Removing: use "Deactivate camera extension", or `systemextensionsctl uninstall <TEAMID> com.lawmatics.lmmask.camera`.
After rebuilding with changed extension code, bump `CURRENT_PROJECT_VERSION` or accept the replace prompt; the app replaces the old version automatically.

## Fallback if XcodeGen does not embed the extension
Target LMMask > Build Phases > add Copy Files: Destination "Products Directory", Subpath `$(SYSTEM_EXTENSIONS_FOLDER_PATH)`, add `com.lawmatics.lmmask.camera.systemextension` with Code Sign On Copy.
