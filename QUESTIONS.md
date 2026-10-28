# Open questions for Zsolt

## Brief 0 (Scaffold)

1. **App-group prefix.** The CMIO mach service name must be prefixed by an app group the extension holds, so the
   entitlement is `$(TeamIdentifierPrefix)group.com.lawmatics.lmmask` rather than the bare `group.com.lawmatics.lmmask`.
   Confirm.
2. **Distribution.** Developer ID + notarization assumed (system extensions cannot ship via the Mac App Store).
3. **Product name.** Currently "LM Mask" (with a space). Say if you prefer `LMMask.app`.

## Brief B (FaceTracker)

1. **Test target and module name.** `OneEuroFilterTests.swift` / `FaceGeometryTests.swift` use `@testable import LMMask`.
   Needs an `LMMaskTests` unit-test target hosted by the app, with `LMMask/Tracking/*` in the app target. If the camera
   extension must also use these types, they should move to `Shared/`; say if you want that.
2. **Vision `leftEye` vs subject's left.** I could not verify on device which side Vision's `leftEye` lands on in an
   un-mirrored frame. `FacePose.leftOpenness` means "Vision's leftEye". If the logo's left eye should follow the user's
   left eye, flip `FaceTrackerConfiguration.swapEyes` after checking the debug view (wink one eye).
3. **Yaw/pitch/roll signs.** Vision's sign conventions for yaw/pitch/roll are not documented clearly; defaults assume
   +yaw = nose toward image right, +pitch = looking down, +roll as the right-handed rotation about +z. Verify with the
   debug view and flip `yawSign`/`pitchSign`/`rollSign` as needed.
4. **Filter parameters on angles.** Spec'd One-Euro (1.0 Hz, beta 0.02) on radians/meters gives very little speed
   adaptation (cutoff ~1.0-1.1 Hz), so expect ~100-150 ms head lag. Fine for jitter, maybe noticeable on quick turns.
   Want a higher beta (e.g. 0.3-1.0) for the pose? Openness uses a separate, faster filter (5 Hz, beta 0.5).
5. **Allocations.** `FacePose.outerLips` is `[SIMD2<Float>]` per the brief, which allocates per frame (as do Vision's own
   point arrays). If the "allocation-free" rule must hold strictly on the render path, I would switch to a fixed
   inline storage type (e.g. 16 points + count). Decide before the renderer depends on the array.
6. **Excluding our own virtual camera.** `CameraCapture` skips devices whose name starts with "LM Mask" so the app never
   captures its own extension. Confirm the final camera name (or give me the extension's uniqueID).
7. **Camera pivot.** `headTransform` origin is the eye midpoint, not the skull center. Does the renderer (Brief A) want
   the tracker to apply a fixed offset (~0.09 m behind/below) or will it handle the pivot?
8. **Mirroring.** Poses are in the un-mirrored frame. Should the virtual camera output be mirrored (Zoom mirrors its own
   self-view by default, so probably not)?

## Brief A / A2 (extension sink + host FrameSink)

A.1. **Idle pattern details.** I chose a left-to-right gradient #00B3C0 -> #009CE4 with a 96 px light bar scrolling down at 180 px/s. Want a different bar/motion or a logo glyph instead?
A.2. **1 s sink timeout** is hard-coded (`SourceStreamSource.sinkTimeoutNanos`). Fine, or should it be shorter so a stalled host is noticed sooner?
A.3. **Retiming.** The extension re-stamps forwarded frames with host time at arrival (no jitter buffer), so host-side hiccups show as hiccups. Want a small (1-2 frame) pacing buffer instead?
A2.1. **Device UID.** I assume `kCMIODevicePropertyDeviceUID` equals the `CMIOExtensionDevice` `deviceID` UUID string (`Identity.deviceUID`). I could not verify without a Mac; please confirm from the logs/CHECKLIST item. Fallback would be matching by name "LM Halloween Cam".
A2.2. **Self-capture.** `CameraCapture`'s default exclusion prefix "LM Mask" does not match the extension's name "LM Halloween Cam" (see B6); `PassthroughPipeline` passes `Identity.deviceName`, but the real pipeline must do the same.
A2.3. **Sink visibility.** Some apps may list a sink stream as a second camera. If Zoom does, I will move the sink to a separate device.

## Brief F (App shell)

F1. **Extension state enum.** `ExtensionInstaller` only has a `status` string, so `ExtensionInstaller.state` (UI/ExtensionState+Installer.swift) parses string prefixes, and a finished deactivation reads as "finished" = Active. Okay to give `ExtensionInstaller` a real `ExtensionState` property (and `.notInstalled` on deactivation)? I was not allowed to edit it. `MaskPipelineControlling.extensionState` exists per the brief but the UI reads the installer; the pipeline can just forward it.
F2. **Camera Extension approval location.** I wrote: macOS 15/26 = General > Login Items & Extensions > Extensions > Camera Extensions; macOS 14 = Privacy & Security > Allow. Unverified on device, and no documented deep link goes straight to Camera Extensions. Please check on 14, 15 and 26 and correct README.md / OnboardingSheet.
F3. **Preferred camera.** Settings stores `AppPreferences.preferredCameraID` (an `AVCaptureDevice.uniqueID`, empty = automatic) in UserDefaults. `CameraCapture.pickDevice()` does not read it yet; someone owning Tracking/ (or the pipeline) must honor it. Settings stops/starts the pipeline on change.
F4. **Settings persistence.** The UI does not persist mask/mouth/blink values. Should `RenderPipeline` persist them in UserDefaults itself (my assumption), or should the shell?
F5. **Launch behavior.** The `Window` scene may auto-open at launch on macOS 14 even after onboarding. If so, preferred fix is `.defaultLaunchBehavior(.suppressed)` on 15+, with a small app delegate for 14. Do you want to bump the deployment target to 15 to simplify?
F6. **Blink sensitivity scale.** I assumed 0...1, default 0.5, shown as a percentage. Tell me the real range/semantics from the pipeline.
F7. **Pipeline lifetime.** The app starts the pipeline at launch and never from the preview window, so Zoom keeps working with the window closed. Should it idle (stop capture) when the toggle is Off, or keep the camera light on? Suggest stopping capture when Off.
F8. **Menu bar icon.** Placeholder SF Symbol; need a single-color template version of the mark (docs/ui.md has the spec).

## Brief D (MaskRenderer / Compositor / RenderPipeline)

1. **D1 SceneKit output colour space and alpha.** Not verifiable without running. The offscreen target is `bgra8Unorm`
   and the compositor assumes premultiplied alpha. If edges are dark-fringed use `Compositor.maskIsStraightAlpha = true`;
   if colours look too dark/light try `.bgra8Unorm_srgb` in `RenderConstants.maskPixelFormat` (then blending is linear).
2. **D2 MSAA through `SCNRenderer` pass descriptors.** I resolve a 4x multisample colour+depth/stencil target into the mask
   texture. Apple's docs do not say SceneKit builds its pipelines for the descriptor's sample count; if validation
   complains, set `RenderConstants.msaaSamples = 1` (then consider rendering at 2x and downsampling).
3. **D3 Mouth cut-out is drawn in the Compositor, not as a SceneKit quad.** Brief E asked for a curved quad at
   `mouthAnchor`, brief D for the compositor to draw the mouth quad. I did the latter: the anchor is projected to pixels
   with the shared pinhole model and a 12x6 grid in the shader gives the curvature. Consequence: the mouth is always on
   top of the logo (no depth test, no logo lighting on it). Say if you want it inside the 3D scene instead.
4. **D4 Disabled behaviour.** `enabled = false` skips tracking and does not send frames at all (the extension then shows
   its idle blue frame, per `PipelineContract.swift`); the preview still shows the raw camera. Prefer sending the raw
   camera instead?
5. **D5 Logo pivot.** Mark centre is placed 8 % of face height below the eye midpoint and 6 cm behind the eye plane; there is
   no skull-centre offset (answers B7: the renderer owns the pivot). Tune `MaskRenderer.Tuning.logoDropFractionOfFace`.
6. **D6 Actor isolation of the logo types.** `LogoMeshBuilder` is `@MainActor`; `LogoFace` reads
   `LogoMeshBuilder.NodeName` constants in its main-actor setup only, but if the compiler treats the nested enum as
   isolated and complains in nonisolated code, mark `NodeName` `nonisolated`.
7. **D7 Environment map is 32x18 (16:9) not 2:1.** SceneKit expects equirectangular 2:1; a 16:9 image is stretched over the
   sphere. Harmless for a tint/gradient. Also the whole camera frame (60 deg wide) maps onto the full sphere, so it is a
   colour/brightness hint, not a physical reflection.
8. **D8 Mask scale reference.** "Face height" is Vision's face bounding box (chin to about the hairline, usually shorter
   than the real head), so 2.4x of it covers the head with a margin. If the head peeks out, raise the default.
9. **D9 `FrameOutput` shape.** The protocol returns `Bool` and has defaulted `start()/stop()` so `FrameSink` conforms
   unchanged (`extension FrameSink: FrameOutput {}`). Shared/ is also compiled into the camera extension, where it is unused.

## Brief E (LogoFace)

1. **E1 Eye mapping.** User-left (Vision `leftEye` via `FacePose.leftOpenness`) drives `eye_L_socket` (screen-left on the
   logo). In an un-mirrored frame the user's left eye is on screen-right, so on the wire this is "anatomically crossed",
   while the user's mirrored self-view looks right. Viewers in Zoom see the un-mirrored stream. If you want logo-left to
   follow the eye that is on screen-left, set `RenderPipeline.swapLogoEyes = true` (separate from the tracker's
   `swapEyes`, which fixes Vision's own assignment, Q2). Pick one after the wink test.
2. **E2 Lid geometry vs the 95 degree rule.** A hemisphere hinged at the eye centre needs 180 degrees to go from hidden to
   covering, and at 0 degrees it would hide the upper half of an open eye. I keep the specified rotation
   (1 - openness) x 95 degrees about the socket's horizontal axis and additionally slide the lid up by 0.95 eyeball radii
   as the eye opens, so it forms a hood. Tune `LogoFace.Style.lidOpenLiftRadii`.
3. **E3 Mouth dilation.** "Dilated 35 %" is implemented as scaling the lip polygon about its centre by 1.35; a closed
   mouth is thin so the margin is small there. Use a pixel-radius dilation instead?
4. **E4 Pupil direction.** Pupils follow head yaw only (not pitch), using the tracker's yaw sign (+ = nose toward image
   right, Q3).
