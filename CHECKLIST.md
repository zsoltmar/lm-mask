# Checklist

Nothing in this repo has been compiled or run yet; every item below is proven in Xcode on a Mac.

## Brief 0 — Scaffold

- [ ] `brew install xcodegen`, then `xcodegen generate` at the repo root produces `LMMask.xcodeproj`.
- [ ] Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` (Gate 0).
- [ ] Both targets build (`LMMask` app, `LMMaskCamera` extension) with no signing errors.
- [ ] Built app embeds the extension at `Contents/Library/SystemExtensions/` (check with Finder; if XcodeGen did not embed, follow the Copy Files fallback in `README-dev.md`).
- [ ] Copy the app to `/Applications`, launch, click **Activate**: System Settings prompts for approval; state enum shows `activated`.
- [ ] Quit and reopen Zoom: "LM Halloween Cam" is listed and shows solid logo blue (#009CE4). → Gate 1 half-passed (test pattern).
- [ ] Confirm `transportType` literal `0x76697274` compiles as the expected Swift type (`CameraProvider.swift`).
- [ ] Decide QUESTIONS.md 0.1–0.3 (app-group prefix, Developer ID, product name).

## Brief B — FaceTracker

- [ ] Add `LMMask/Tracking/*.swift` to the app target; add `LMMaskTests` unit-test target with `OneEuroFilterTests.swift` and `FaceGeometryTests.swift`; run tests (QUESTIONS.md B1).
- [ ] Fix any Swift 6 strict-concurrency diagnostics (likely spots: `CameraCapture` notification closures, `FaceTrackingPipeline` detached task, `CaptureFrame` `@unchecked Sendable`).
- [ ] App `Info.plist` has `NSCameraUsageDescription`; sandbox entitlement `com.apple.security.device.camera` is set.
- [ ] Show `LandmarkDebugView` in a debug window; confirm camera starts at 1280x720 / 30 fps (log subsystem `com.lawmatics.lmmask`, category `capture`).
- [ ] Unplug/replug an external camera (or sleep/wake): capture resumes, `.deviceDisconnected` / `.deviceReconnected` events fire.
- [ ] Wink left, then right: confirm which bar moves and set `swapEyes` if needed (B2).
- [ ] Turn head left/right, nod, tilt: confirm yaw/pitch/roll signs; set `yawSign`/`pitchSign`/`rollSign` (B3).
- [ ] Blink normally during/after the 90-frame calibration: bars reach ~0 on closed, ~1 on open; "blink" lines appear in the log. Check with glasses.
- [ ] Measure per-frame cost in the debug view and Instruments signpost "process": < 8 ms on M1. Record the number in docs/tracking.md.
- [ ] Sanity check depth: head at ~0.6 m reads z ~ -0.6 (+-15 %).
- [ ] Cover the camera / leave frame: `pose` becomes nil and recovers; filters reset after 0.5 s.
- [ ] Decide QUESTIONS.md B4 to B8 (filter beta, `outerLips` storage, virtual camera name, pivot, mirroring).

## Brief C — Blender inflate script

- [ ] Install Blender 4.x; run the command in `Assets/tools/README.md` with `--fast` first, then the cloth version.
- [ ] Output `Assets/lm-mark.usdz` opens in Preview/Quick Look as a closed pillow, right way up, not mirrored (check `sx`/`sy` in `import_mark` if wrong).
- [ ] Mirror step did not double the shell (README uncertainty 1); drop it if so.
- [ ] Eye dishes visible at the top caps of the short and tall bars; empties `eye_L_socket`, `eye_R_socket` present.
- [ ] Gradient runs teal → blue left → right on the front face.

## Brief C2 — SCNShape fallback

- [ ] `LMMask/Rendering/*.swift` compile; `LogoAssetLoader.load()` returns `.builder` when no USDZ is bundled.
- [ ] Render `LogoMeshBuilder.makeMark()` in a scratch `SCNView`: four islands, pillow edges; if the chamfer dents inward set `Style.flipChamferProfile = true`.
- [ ] Gradient continuous across islands; if UVs are wrong set `Style.useFlatColorFallback = true`.
- [ ] `eye_L_socket`, `eye_R_socket`, `mouthAnchor` sit on the front surface (adjust `frontZ` if they sink or float).
- [ ] Loader prefers `lm-mark.usdz` when bundled and still exposes the same node names.

## Brief A — Extension sink + source + test pattern

- [ ] `LMMaskCamera/{CameraProvider,CameraDevice,SourceStream,SinkStream,TestPattern}.swift` compile (Swift 6 strict concurrency). Likely spots: `SinkStreamSource.streamProperties` (`CMIOExtensionPropertyState<NSObject>` dictionary; fall back to typed setters), `.streamSink*` property names, `client.signingID`/`pid` in the provider log.
- [ ] `Shared/FrameFormat.swift` now has `Identity.sinkStreamID` and `Identity.deviceUID`; both targets still build.
- [ ] Bump `CURRENT_PROJECT_VERSION`, rebuild, reinstall: `systemextensionsctl list` shows the new version `[activated enabled]`.
- [ ] Idle: open "LM Halloween Cam" in Photo Booth/Zoom with the host app NOT sending: teal-to-blue horizontal gradient with a light bar scrolling down (~4 s per loop). Smooth at 30 fps, no tearing.
- [ ] `log stream --predicate 'subsystem == "com.lawmatics.lmmask"'` shows: client connected (pid, signingID), "source stream started (idle -> running)", and on closing the camera "stopped (running -> idle)". Close all clients: timer stops (CPU ~0 in Activity Monitor).
- [ ] Two clients at once (Photo Booth + Zoom): both see frames; closing one does not stop the other (start/stop counter).
- [ ] With the host sending (Brief A2): sink frames appear within a frame or two; stop the sender and the test pattern returns after ~1 s.
- [ ] Sink stream shows up: `system_profiler SPCameraDataType` lists one device; the sink is not a selectable camera in Zoom (if a second entry appears, tell me).
- [ ] Confirm `consumeSampleBuffer` does not spin when the sink has no data (CPU of the extension while the host is connected but silent).

## Brief A2 — Host FrameSink + Gate 1 passthrough

- [ ] `LMMask/Camera/FrameSink.swift`, `PassthroughPipeline.swift` compile (`CMIOObjectPropertyListenerBlock` typealias, `CMIOStreamCopyBufferQueue` out-param type `Unmanaged<CMSimpleQueue>?`, `CMSimpleQueueEnqueue` element type).
- [ ] Confirm the CMIO device UID reported by `kCMIODevicePropertyDeviceUID` equals `Identity.deviceID.uuidString` (log the UID list once; QUESTIONS A2.1). If not, update `Identity.deviceUID`.
- [ ] `kCMIOStreamPropertyDirection` of our sink stream is 1 and the source is 0 (log shows "sink open: device N stream M").
- [ ] **Gate 1**: call `PassthroughPipeline().start()` from a debug button/`.task`; in Zoom pick "LM Halloween Cam": you see your own camera video, 1280x720, ~30 fps, not mirrored/rotated, colours correct (BGRA).
- [ ] Quit the host app mid-call: Zoom falls back to the test pattern in about 1 s without freezing.
- [ ] Deactivate then re-activate the extension (or `systemextensionsctl` replace) while the host runs: `FrameSink.states` goes `.searching` then `.connected` and video resumes without restarting the app.
- [ ] Start the host before the extension is installed: stays `.searching`, connects after activation.
- [ ] Camera permission: check whether the sandboxed host needs TCC camera approval for CMIO sink access (it should already have it from `CameraCapture`).
- [ ] Instruments: `send` cost per frame (expect well under 0.1 ms) and no growth in allocations over 5 minutes.

## Brief F — App shell

- [ ] `LMMask/UI/*.swift` and the new `LMMaskApp.swift` compile (Swift 6). Likely spots: `@State var pipeline: any MaskPipelineControlling` default value, `let _ = image.isTemplate = true` inside the `MenuBarIcon` view builder, `NSApp.activate()` (macOS 14 API).
- [ ] Menu bar shows the `theatermasks` symbol; menu has: LM Mask toggle, Open Preview…, Camera Extension: <state> (+ Enable button when not Active), Settings… (Cmd-,), Quit (Cmd-Q).
- [ ] First launch (`defaults delete com.lawmatics.lmmask` first): the preview window opens by itself with the onboarding sheet. If the Window scene ALSO auto-opens on every later launch, add `.defaultLaunchBehavior(.suppressed)` (macOS 15+) or an app-delegate workaround (QUESTIONS F5).
- [ ] Onboarding: camera step reflects Allow/Deny and refreshes when returning from System Settings; extension step shows the state through requesting, waiting for approval, active; quitting mid-way resumes at the same step; Done never shows the sheet again.
- [ ] "Open System Settings" opens Login Items & Extensions; verify where Camera Extensions appears on macOS 14, 15 and 26 and fix the wording in the sheet and README.md.
- [ ] Preview window: 16:9 stage, sliders move live (values update beside them), Recalibrate works, "Show tracking overlay" swaps in `LandmarkDebugView` and back without leaving the camera stuck on.
- [ ] Closing the preview window does not stop the feed in Zoom.
- [ ] Settings: Open at login toggles `SMAppService.mainApp` (check System Settings > Login Items); camera picker lists physical cameras only; Reset restores defaults and re-shows onboarding.
- [ ] Relaunch with the extension already active: menu shows "Camera Extension: Active" within a second or two (activation re-submit).
- [ ] `scripts/make_dmg.sh "<export>/LM Mask.app"` produces a DMG with an Applications link; with a background PNG the Finder layout is applied. Mount it and drag-install.
- [ ] Add the real `Assets.xcassets/MenuBarIcon.imageset` (see docs/ui.md) and confirm template tinting in light and dark menu bars.

## Brief D — MaskRenderer / Compositor / RenderPipeline

- [ ] Add `Compositor.metal` to the app target (XcodeGen picks it up from `LMMask/`); app launches without `Failure.noLibrary` / `noFunction`.
- [ ] `MaskRenderer` builds on the main actor; log line "logo source: usdz|fallback" appears (category `mask`).
- [ ] Swift 6 strict-concurrency diagnostics: `MaskRenderer`/`LogoFace`/`Compositor` are `@unchecked Sendable` (render-queue confined); check `LogoMeshBuilder.NodeName` access from non-isolated `LogoFace` methods (QUESTIONS.md D6).
- [ ] Wire `extension FrameSink: FrameOutput {}`; `RenderPipeline(output: FrameSink())` in `LMMaskApp.makePipeline()`; add `extension RenderPipeline: MaskPipelineControlling {}` only if the explicit conformance is missing (it is declared on the class).
- [ ] Preview shows the logo over the user's head, mark height about 2.4x face height; moving closer/farther keeps the ratio.
- [ ] Mask scale slider 1.8...3.2 visibly changes size; mouth scale slider changes the patch.
- [ ] Logo alpha edges are clean (no dark halo). If dark fringes: set `Compositor.maskIsStraightAlpha = true` (D1). Colours too dark/washed: try `RenderConstants.maskPixelFormat = .bgra8Unorm_srgb` (D1).
- [ ] MSAA 4x works with SCNRenderer's pass descriptor (no Metal validation error); if not set `RenderConstants.msaaSamples = 1` (D2).
- [ ] Head roll/yaw/pitch drive the logo in the correct directions (depends on tracker signs, QUESTIONS.md B3).
- [ ] Lighting: key light visibly from upper left; environment tint changes when you switch a lamp on/off (updates ~5 Hz); no flicker.
- [ ] Cover the camera: after 0.4 s the logo eases to the centre facing front and blinks every 3-5 s; uncover: it eases back to the face.
- [ ] Frame budget: Instruments signpost `frame` (category `pipeline`) under 20 ms on M1 at 1280x720; `RenderStats.renderMilliseconds` and `trackingMilliseconds` in the HUD. No frames queue up (drop counter rises instead of latency).
- [ ] `enabled = false`: preview shows the plain camera, nothing is sent to the extension (Zoom shows the idle frame).
- [ ] No Metal API validation errors with `MTL_DEBUG_LAYER=1`; pool exhaustion log ("pool exhausted") never appears in normal use.

## Brief E — LogoFace / mouth cut-out

- [ ] Both eyes show: white ball, #009CE4 iris, black pupil, sitting on the top caps of the two bars (not sunk / floating; adjust `LogoFace.Style.eyeProudness`).
- [ ] Gradient lid matches the surrounding bar colour (UV assumption, docs/rendering-fallback.md uncertainty 1).
- [ ] Open eyes: the lid forms a hood above the ball (no half-covered eyes); closing sweeps down and fully covers the iris at openness 0.
- [ ] Wink left: the logo's left eye (screen-left) closes while the right stays open; if it is the wrong eye flip `RenderPipeline.swapLogoEyes` or tracker `swapEyes` (E1).
- [ ] Pupils move up to 0.4 cm toward head yaw, in the right direction.
- [ ] Mouth cut-out: real mouth appears on the swoosh at 2.5x, feathered edge with no hard rectangle, follows the swoosh as the head turns, hidden when no face.
- [ ] Mouth patch looks slightly curved/bulged, not distorted: tune `Compositor.mouthCurvature`.
- [ ] Mouth mask covers lips plus a ring of skin (35 % dilation) with a soft 12 px edge; check with teeth showing and with mouth closed (thin lips).
- [ ] Resting pose: blink timer fires every 3-5 s with the face absent for > 400 ms.

## Integration (cross-brief pass, see docs/integration-log.md)

Things the integration pass could not settle without a compiler or a Mac, most likely to break first:

- [ ] `xcodegen generate` accepts the new `schemes:` and `LMMaskTests` blocks in `project.yml`, and the generated test target resolves `TEST_HOST` ("LM Mask.app/Contents/MacOS/LM Mask"). If tests fail to load, check `PRODUCT_MODULE_NAME: LMMask` took effect.
- [ ] `OSAllocatedUnfairLock(uncheckedState:)` / `withLockUnchecked` exist with those names (used in FrameSink, SinkStream, SourceStream, RenderPipeline). If not, fall back to `OSAllocatedUnfairLock` with a Sendable wrapper struct.
- [ ] `CMIOExtensionStreamProperties` typed setters in `SinkStream.streamProperties`: `activeFormatIndex`, `frameDuration`, `sinkBufferQueueSize`, `sinkBuffersRequiredForStartup` (integer literal types) compile.
- [ ] `@Observable` keeps the `didSet` observers on `RenderPipeline.maskScale/mouthScale/blinkSensitivity/enabled/showMouth/swapLogoEyes/previewEnabled`. If sliders do nothing, the observers were dropped: move the push into explicit setters.
- [ ] Settings change of camera (stop()/start()) really restarts capture now that the consumer tasks survive stop(); and the frame flow resumes after a second `start()`.
- [ ] Swift 6 diagnostics still expected: `Canvas` renderer closure in `LandmarkDebugView` (touches main-actor model), `AVCapture`/`CMIO` completion closures that capture non-Sendable CF types, `SCNNode` use from the render queue (`MaskRenderer` is `@unchecked Sendable`).
- [ ] `ExtensionState+Installer.swift` is now a comment-only file; delete it.
- [ ] `PreviewWindow.onDisappear` fires when the preview window closes (so `previewEnabled` goes false and the CGImage conversion stops).
- [ ] Two capture sessions on the same camera while "Show tracking overlay" is on (LandmarkDebugView owns its own `CameraCapture`): confirm the main pipeline keeps running and that the debug session does not change the active format.
- [ ] Launch: the app now starts `RenderPipeline` immediately (macOS camera permission prompt appears at first launch, before onboarding reaches the camera step). If that is unwanted, start the pipeline from onboarding completion instead.
- [ ] Tests (`OneEuroFilterTests`, `FaceGeometryTests`) run under the hosted app target.

## Round 2 — placement/aspect

Not compiled. New code lives in existing files (no new files, so no `xcodegen generate` needed): `FrameMapping` in Shared/FrameFormat.swift, `PlacementDebugInfo`/`PlacementDebugHub` in Tracking/LandmarkDebugView.swift.

- [ ] Builds. Likely nits: tuple `<` in `CameraCapture.applyFormat` key, `OneEuroFilter` used as `private var` initialisers in `MaskRenderer`, `Placement` nested in a class extension referenced from property initialisers.
- [ ] Log (category `capture`): "Capture format on <cam>: 1280x720 @ 30 fps (16:9)" for the built-in cam AND the external HD cam. If it says "NOT 16:9", the camera offers nothing else; the picture must then be cropped, not stretched.
- [ ] Log (category `pipeline`): "source WxH -> output 1280x720, fill scale S" once per source change. 1280x720 -> 1.0, 1920x1080 -> 0.667, 4:3 -> crop.
- [ ] External HD cam: a circle held in front of the camera is round in the preview and in Zoom (no stretch). Switching camera in Settings re-logs the mapping.
- [ ] Preview is letterboxed (black bars) at any window shape; never stretched.
- [ ] Output in Zoom is NOT mirrored (text held up reads correctly in the raw feed; Zoom's self-view mirrors). Preview matches the output by default.
- [ ] Mirror preview toggle (in the overlay view) flips only the preview; Zoom is unaffected. NOT yet wired into the plain preview in `PreviewWindow` (UI is another agent's area): add `@AppStorage(PlacementDebugHub.mirrorPreviewKey) var mirrorPreview = false`, `.scaleEffect(x: mirrorPreview ? -1 : 1, y: 1)` on the `Image`, and a `Toggle("Mirror preview", ...)`.
- [ ] Turn on "Show tracking overlay": magenta socket rings sit on the cyan eye rings; orange box surrounds the logo; white lines are near zero length. If they are offset by a constant, tweak `Tuning.logoDropFractionOfFace`; if the logo eyes are too far apart/close, `Placement.eyeSpanFactor`.
- [ ] Logo eyes land on the real eyes at the default Mask size (2.4x) at 0.4 m, 0.8 m, and at the screen edge; mask size slider scales the logo about the eyes midpoint.
- [ ] Head roll: the logo tilts with the head in the right direction (roll is taken from the eye line). Yaw and pitch directions still pending (`FaceTrackerConfiguration.yawSign/pitchSign`, QUESTIONS.md Q3).
- [ ] Mouth patch is centred on the logo's mouth anchor and has the real mouth's size x mouthScale with the external cam (1080p) as well as the built-in.
- [ ] Face lost: logo eases to centre/upright, returns to the face without a jump (filters re-seed).
- [ ] Overlay view no longer opens a second capture session (it shows the pipeline's composited frame).

## Round 2 — look

Not compiled. New files (run `xcodegen generate`): `Rendering/MaskStyle.swift`, `Rendering/LogoSilhouette.swift`, `UI/TunePanel.swift`. Design: docs/rendering-fallback.md.

- [ ] Builds. Likeliest nits: `LogoSilhouette` (Vision `VNContour.normalizedPath`, `request.results?.first` type, `CIFilter(name:)` keys), `SCNMaterial.clearCoat` / `clearCoatRoughness`, `.inspector` + `inspectorColumnWidth`, `Binding` closures capturing a key path, Swift 6 Sendable diagnostics on `StyleUpdate` / `OSAllocatedUnfairLock<[StyleUpdate]>`.
- [ ] Launch log has no "silhouette: Vision found no contour" error. If it does the body is a convex hull blob: check the contour request (`detectsDarkOnLight`, image orientation).
- [ ] Shape: one white inflatable in the logo's outline, bars as separate puffy fingers at the top (gaps open), one solid body below that covers the whole face. Edges roll over fully (no flat rim, no dented edge; if dented tick "Flip edge profile").
- [ ] Body is white on the sides/back and blue only where the logo is; the blue logo stands slightly proud with blue sides and keeps the teal to blue gradient across the islands (if the gradient is wrong set `LogoMeshBuilder.Style.useFlatColorFallback`).
- [ ] Body is not inside-out (dark or invisible): if so reverse the outline winding (`LogoSilhouette.smoothAndResample`) or set the body material double sided.
- [ ] Vinyl look: soft broad highlight / clear-coat hotspot on the fingers, no metal look. Tune roughness 0.32, clear coat 0.6.
- [ ] Eyes sit on the top of the short and tall bars, big (R 4.2 cm), 60 % bulging, white with a blue iris ring, large black pupil, crisp white glint up-left. Both eyes visible at the default Mask size.
- [ ] Blink: puffy white lids sweep down over each eye independently; the ball squashes about 12 %; lower lid rises when the eye is mostly closed; wink works.
- [ ] Googly: turn the head quickly and the pupils slosh and settle (spring); slow turns just follow. Tune wobble / stiffness / damping. Pitch is not fed yet: pass `pitch:` in `MaskRenderer.update`'s `face.setGaze` call.
- [ ] Tune button in the toolbar opens the right-hand inspector; the window grows instead of squashing the preview. Every slider changes the picture live; silhouette / depth sliders rebuild after a short pause without a frame hitch (watch `RenderStats.renderMilliseconds`).
- [ ] Reset style, Copy as JSON (valid, pretty-printed), Paste round-trips; quitting and relaunching restores the tuned look.
- [ ] Send the owner's tuned JSON back and bake it into the `MaskStyle` defaults.

## Round 3 — bulk / offset / mouth

Not compiled. NEW file (run `xcodegen generate`): `Rendering/LogoMouth.swift`. Design: docs/rendering.md (Placement offsets, Cartoon mouth) and docs/rendering-fallback.md (Bulk).

- [ ] Builds. Likeliest nits: `MouthGeometry` / `MouthCalibration` in `FaceTracker.swift` (`lm.innerLips`), `LogoMouth.lipGeometry` (SIMD generics, `pow` on Float), `String(format:)` with `%@` in `Outline.summary`, `PlacementDebugInfo` memberwise init with the defaulted `silhouette`, `Picker` over `MaskStyle.MouthMode.allCases`.
- [ ] Stored style key bumped to `lm.maskStyle.v2` (an old v1 style would pin dilation 7 / depth 14): first launch shows the new bulky defaults. "Reset style" restores them.
- [ ] Vertical position slider (main window, -0.5...+1.0, default +0.35): mask sits clearly higher than before, eyes still read as the logo's eyes above the user's. Tilt the head: the offset follows the tilt (shifts along the mask's up, not screen up). Value survives relaunch. Tune > Placement > Horizontal position nudges sideways.
- [ ] Coverage: tick Tune > Silhouette > "Show silhouette outline", then "Show tracking overlay": green outline. The whole face (forehead to chin, ears) is inside it at 0.4 m and 0.8 m with default Mask size and offset. If chin/jaw shows, raise "Chin extension" / "Dilation"; Log (category `mask`): "silhouette bounds x ... y ... (W x H cm)".
- [ ] Body is bulky: default dilation 11, depth 18, chin blob (14), lower body +4 per side; fingers still separate at the top (finger width vs chamfer: chamferFraction default lowered to 0.36 to keep fingers from self-intersecting; if they do, raise `fingerDilation`). Silhouette rebuild still < ~0.6 s (bitmap domain is now 136 units).
- [ ] Eye sockets and mouth anchor did not move relative to the logo when dilation / chin sliders change (they are SVG coordinates).
- [ ] Mouth mode defaults to Cartoon 3D: coral glossy lips at the swoosh, closed when the user's mouth is closed. Open the mouth: lower lip drops, upper rises a bit, dark interior and white teeth appear, tongue rises when wide open (> 60 %); bouncy overshoot, no jitter when the mouth is still. Smile: lips widen and corners curve up; frown: down.
- [ ] Mouth calibration: openness uses the 5th percentile of the last ~10 s as "closed" and the largest opening seen as "open"; "Recalibrate" resets it. A lazily moving mouth can need a few seconds to settle. Smile has a fixed scale (`FaceTrackerConfiguration.smileFullScale` 0.12): if a neutral mouth reads smiling/frowning, tune it or add a neutral baseline.
- [ ] Mouth mode Video: the old camera patch is back, exactly as before (Mouth size slider). Mode Off: no mouth at all. In Cartoon / Off the compositor's mouth pass is skipped (`RenderWorker`, `renderer.mouthMode`).
- [ ] Tune > Mouth: width, lip thickness, open travel, lip colour, teeth / tongue toggles update live.

## Round 4 — scare

Not compiled. NEW files (run `xcodegen generate`): `Rendering/ScareDetector.swift`, `Rendering/ScareLook.swift`, `LMMaskTests/ScareDetectorTests.swift`. Changed: `MaskStyle`, `MaskRenderer`, `Compositor.swift` + `.metal`, `RenderPipeline`, `PipelineContract`, `TunePanel`, `PreviewWindow`, `MenuBarContent`, `LMMaskApp`, `LandmarkDebugView`. Design: docs/rendering.md "Scare mode".

- [ ] Builds, and `ScareDetectorTests` pass. Likeliest nits: `ScareLook` (`SCNShape` / `pivot` / `SCNMatrix4MakeTranslation`, `[CGColor] as CFArray` gradient, tuple-array cast in `rebuildPlates`), `LMMaskApp.commands` button calling the main-actor `pipeline.testScare()`, nested key paths `\.scare.mouthThreshold` in `TunePanel.row`, the `.metal` buffer indices (camera / mask fragments now take `buffer(1)` shift).
- [ ] Trigger: with the overlay on, the HUD line shows live mouth and eye readings; open mouth wide + eyes wide for ~0.12 s: state flips to ACTIVE and the pill lights. If it never fires, the HUD shows which reading is short (eyes reach 0.92 only if your calibrated open is at least that wide: lower "Eyes open at" or Recalibrate).
- [ ] Snap: the look changes within ~2 frames (not a fade): logo black, body pumpkin orange with vertical dark ribs, eyes are glowing jagged triangles, mouth a glowing zigzag grin, 2-frame white flash and a small shake, scene dark with cold uplight, headpiece pops to ~1.12x then 1.05x. Nothing white or blue left on the headpiece.
- [ ] Body texture orientation: ribs must run vertically. If they run horizontal / skewed, SCNShape's UV mapping differs from the assumption (see `ScareLook.makePumpkinImage`, rotate the contents with `contentsTransform`).
- [ ] Glow: eyes and grin flicker (about 9 Hz, orange to pale yellow); the orange omni lights the body around them. If the body looks unlit/flat or blown out, tune `ScareLook.Config.omniIntensity` / `omniStandoff`.
- [ ] Grin gapes with mouth openness (y scale 0.45 to 1.35); eyes plates sit in the sockets and are not buried (adjust depth/position in `ScareLook.rebuildPlates`).
- [ ] Release: keep the face relaxed: stays at least 1.2 s, then eases back over ~0.6 s (lights and vignette ease; materials swap back at the halfway point). Googly eyes, lips and the blue gradient come back unchanged.
- [ ] Test scare: Tune > Scare button, menu bar "Test Scare" and Mask > Test Scare (Option-Command-S) all hold the scare for 2 s. Toggling "Scare mode" off disables the trigger and the button.
- [ ] Changing any Tune slider during a scare keeps the scare look (eyes stay hidden, pumpkin stays). Video mouth mode: the camera mouth patch is hidden while scared.
- [ ] Cost: `RenderStats.renderMilliseconds` does not rise noticeably during a scare (one extra fullscreen draw, one more light).

## Round 5 — inflatable rebuild

Not compiled. NO new or removed files in the Xcode project (so no `xcodegen` needed): `LogoFace.swift` now holds the demon stencil, `LogoMouth.swift` is emptied to a comment (delete it and run `xcodegen generate` whenever you like). Rewritten: `MaskStyle` (key `lm.maskStyle.v3`), `LogoSilhouette`, `LogoMeshBuilder`, `LogoFace`, `ScareLook`, `MouthCutout` (now a pure value type), `LogoAssetLoader`, `MaskRenderer`, `Compositor.swift` + `.metal`, `RenderPipeline`, `TunePanel`. Trimmed: `PipelineContract`, `PreviewWindow`, `AppPreferences` (Mouth size / Blink sensitivity sliders removed; vertical position default 0, key `verticalOffset.v5`). Design: docs/rendering-fallback.md, docs/rendering.md.

- [ ] Builds. Likeliest nits: `LogoMeshBuilder` (`colorBufferWriteMask = []`, `SCNColorMask.all`, `nonisolated(unsafe) static let`, tuple param `bounds: (min:max:)`), `LogoSilhouette.build` (`named.map { (name, poly) in ... }`), `Compositor.metal` (`fwidth`, the 88-byte `MouthUniforms` mirror), `LogoFace` (`[[(Double, Double)]]` static data), `MaskRenderer` rim-light euler angles, `TunePanel` key paths.
- [ ] Shape: a white glossy palm with FOUR separate round fingers (bars) on it, seams visible between pillows; strong highlight upper-left plus a bright rim. If pillow edges look dented, flip `LogoMeshBuilder.Style.flipChamfer`. If a pillow is dark/invisible, reverse the polygon winding (`LogoSilhouette.counterClockwise`).
- [ ] Print: the right bar and the swoosh carry the blue (teal to blue gradient; toggle Tune > Print). Edges of the print may float a little above the tube's flank (intended patch look); raise "Print inset" if it bothers you.
- [ ] Eye windows: with the face centred and level, BOTH real eyes are visible inside the short bar and the tall bar, tinted blue, with a hard edge (no feathering). Tilt the head: the windows follow. If the windows are opaque white, set `LogoMeshBuilder.Layer.occluderTransparency = 1`. If the tint looks weaker than the opacity slider, see rendering-fallback.md "Known uncertainties" 2.
- [ ] Mouth window: the user's real mouth appears in the 22 x 8 swoosh window, sharp edge, scaled to fill (not stretched), upright when the head rolls; open the mouth wide: the crop gets taller, no distortion. Tune > Windows > Mouth = Off: no window, swoosh solid blue.
- [ ] Size: the mask is ~1.5x bigger relative to the face than before (the eye sockets are now 16.5 apart, level). Check "Mask size" 2.4 reads right; vertical position 0 puts the eyes in the windows.
- [ ] Scare: windows snap pitch black (no video), blue prints go black, the black demon face appears on the white vinyl (flame-browed slanted slits over the eyes, nose notch, 44-wide fanged grin over the mouth window, 6 cracks across the fingers); white vinyl stays white; low cold uplight; 1.12x pop, flash, shake, vignette as before. All binary at amount 0.5, gone on release (windows see-through again, prints blue). Stencil floats ~0.4 in front of the fingers (and ~5 in front of the palm): check it does not look detached at 30 degrees of yaw.
- [ ] Tune panel: Inflatable / Vinyl / Print / Windows / Placement / Scare; Reset style; Copy/Paste JSON. An old v2 style is ignored (new key).
