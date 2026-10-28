# Rendering (LMMask/Rendering, LMMask/Pipeline)

Round 5: the look layer was rebuilt as an inflatable glove with live-video windows; see docs/rendering-fallback.md for the model.

Nothing here has been compiled or run (no Xcode available when written); see CHECKLIST.md Briefs D and E.

## Frame flow

```
CameraCapture.frames (newest-1)           sampleQueue never blocks
  -> detached task: `for await frame` + `await worker.process(frame)`     (one frame in flight)
     -> render queue  com.lawmatics.lmmask.render  (serial, userInteractive)
        1. FaceTracker.process               Vision, ~5 ms          -> FacePose?
        2. MaskRenderer.updateEnvironment    CPU 32x18 probe, <= 5 Hz
        3. MaskRenderer.update               screen-space placement, eyes, rest pose, mouth anchor px (needs FrameMapping)
        4. MaskRenderer.render               SCNRenderer -> RGBA mask MTLTexture (own command buffer, committed)
        5. MouthCutout.crop                  lips -> sharp crop (centre + half extent, camera px) fitted to the mouth window's aspect
        6. Compositor.composite              ONE render pass into a pooled CVPixelBuffer:
                                               camera (aspect-filled via FrameMapping UVs) -> mouth patch (into the mask's mouth window)
                                               -> mask (premultiplied; its windows are transparent holes with a blue tint) -> scare vignette / flash
                                             commit + waitUntilCompleted (render queue only)
        7. FrameOutput.send(buffer, at:)     FrameSink -> camera extension
        8. preview: FrameSlot (every frame) + CGImage (<= 15 Hz, only if previewEnabled)
```

Dropping: the stream keeps only the newest frame and the loop awaits each frame, so when a frame takes longer than
33 ms the older captured frames are overwritten (counted in `RenderStats.droppedFrames`), never queued. Latency stays
at one frame. `enabled = false` skips steps 1-5 and 7.

## Threading and isolation

- `RenderPipeline` is `@MainActor @Observable` (UI state only, settings, stats, preview).
- `RenderWorker` (private) owns all per-frame objects and touches them only on the render queue. Cross-thread data:
  `RenderSettings` snapshot (unfair lock, read once per frame), recalibrate flag, preview flag, `FrameSlot`.
- `MaskRenderer`, `ScareLook`, `Compositor`, `EnvironmentProbe` are `@unchecked Sendable` because of that
  confinement (SceneKit and Metal objects are not Sendable). `MaskRenderer.init` is `@MainActor` because
  `LogoAssetLoader` is.
- The render queue blocks on the GPU (`waitUntilCompleted`) so the output buffer is complete when sent and the CPU-written
  mouth texture can be reused. This is never the capture queue.
- Per-frame allocations: none in our code except the 32x18 `CGImage` every 200 ms, the preview `CGImage` (<= 15 Hz, only if
  shown), CVMetalTextures (cache-backed), plus whatever Vision/SceneKit do internally. Pixel buffers come from a
  `CVPixelBufferPool` (min 4, threshold 12; if downstream holds too many the frame is dropped).

## Scene and camera

- Camera at the origin looking down -z, `projectionDirection = .horizontal`, `fieldOfView = RenderConstants.horizontalFOV`
  (60 degrees). Any FOV works now: placement is derived from it in closed form (below), no metric depth is assumed.
- `headNode -> logoNode -> lmMark`. `headNode` sits at the anchor point on the fixed plane z = -`Placement.anchorDepth` (1 m) and
  carries the rotation; `logoNode` carries the uniform scale and the offset `-k * socketMid` so that the midpoint of
  `eye_L_socket`/`eye_R_socket` is exactly `headNode`'s origin (rotation pivot).
- Lights: one strong key directional 30 degrees up/left (1500), a rim directional from behind-upper-right (900), image-based lighting from the 32x18 probe.
- Output: `bgra8Unorm` mask, 4x MSAA resolved, cleared to (0,0,0,0).

## Frame -> output mapping (aspect-fill)

`FrameMapping` (Shared/FrameFormat.swift) is built once per frame from the captured buffer size and the 1280x720 output:
`scale = max(outW/srcW, outH/srcH)`, visible source region = output / scale, centred. A 16:9 source gives scale 1.0 (or 1.5 for 1080p)
and no crop; a 4:3 source is cropped top/bottom, never stretched. Users of it:

- `Compositor` camera pass samples `uvOrigin + uv * uvSize` (a `float4` buffer(0) on `cameraFragment`).
- Mask placement (`MaskRenderer.placementTarget`): Vision eye centres / face rect are source px -> `toOutput`.
- Mouth window: `MouthCutout` works in source px (lip bounds -> crop centre / half extent); the patch is drawn into the mouth window's
  four projected corners (already output px, `MaskRenderer.mouthWindowCorners`).
- Alignment overlay (`LandmarkDebugView`).

## Placement (screen-space anchoring)

Goal: the logo's two eyes sit over the user's two eyes. Per frame, from `FacePose` (source px, top-left origin; Vision's
bottom-left flip happened once in `FaceTracker`):

1. Map both eye centres to output px (`FrameMapping`): midpoint `M`, distance `D`. Fallback if `D < 8 px`: `M` = face-rect centre x,
   40 % down the rect; `D` = 0.45 x rect width.
2. `M.y += logoDropFractionOfFace x faceHeight` (kept at 0). `D /= max(0.6, cos(yaw))` (the rotated logo foreshortens itself).
3. One-Euro smoothing (px params `Placement.pixelFilter`) of `M.x`, `M.y`, `D`; roll = -atan2 of the eye line (x-sorted), One-Euro in radians.
4. With focal length `f = (W/2)/tan(hfov/2)` in output px and plane depth `d`:
   `headNode.position = ((M.x - W/2) d/f, -(M.y - H/2) d/f, -d)` and
   `k = D x eyeSpanFactor x (maskScale / 2.4) x d / (f x socketSpan)` where `socketSpan` = distance of the two sockets in `logoNode`-local units.
   So the socket midpoint projects to `M` and the socket distance to `D x factor`. `maskScale` (slider, default 2.4) now scales the eye span:
   1.0x at the default; the vertical/horizontal anchor stays on the user's eyes at any slider value.
5. Rotation (yaw, pitch from the tracker, roll from the eye line) is applied on `headNode`, i.e. about the anchor.
   **Offsets (round 3):** after matching the sockets to the eyes, the whole mask is slid inside `headNode`'s rotated frame:
   `logoNode.position = -k * socketMid + (horizontalOffset, verticalOffset, 0) x faceHeight x d / f`, where `faceHeight` is the
   One-Euro filtered face-rect height in output px. Because it is applied in the rotated frame it follows head roll (the
   mask moves along its own up vector), and pitch / yaw swing it about the eyes. `verticalOffset` is a pipeline setting
   (`RenderSettings.verticalOffset`, persisted under `verticalOffset.v5`, main-window slider "Vertical position", -0.5...+1.0, default 0 since round 5: the eyes must land in the eye windows, positive = up);
   `horizontalOffset` is `MaskStyle.horizontalOffset` (Tune > Placement, default 0, positive = toward image right).
6. `mouthAnchorPixel` = projection of the mouth anchor's world position with the same pinhole model.

Debug: Settings/preview "Show tracking overlay" (`LandmarkDebugView`) shows the composited output with the face rect (yellow), the
user's eye centres (cyan), lips (pink), the mask's projected bounding box (orange) and projected eye sockets (magenta rings, white
lines to the eye each should cover). Magenta ring on cyan ring = correct. Mirror preview toggle mirrors that preview only.

## Eyes and mouth: windows (round 5)

There are no 3D eyes or lips any more (googly eyes, lids and cartoon lips were deleted). The user's real eyes and mouth show through
sharp transparent windows in the mask (geometry and the occluder trick: docs/rendering-fallback.md).

- **Eye windows**: the whole short bar and tall bar. The sockets (`eye_L_socket` SVG (27.5, 30), `eye_R_socket` (44, 30)) are inside them at
  the same height, so placement (socket midpoint and distance matched to the user's eyes) lands level eyes in both windows. The video
  seen through is tinted blue (`tintColor` #009CE4, `tintOpacity` 0.42).
- **Mouth window**: 22 x 8 rounded rect in the swoosh run, centred on `mouthAnchor` (35.7, 66). The mask hole is made by the same occluder
  + tint trick. The compositor puts the user's real mouth into it (below).
- Left = Vision `leftEye` -> `eye_L_socket` (QUESTIONS.md E1); with level windows only the pair matters.

### Mouth patch (`MouthCutout`, `Compositor`)

`MaskStyle.mouthMode` is `window` (default) or `off` (no window: the swoosh stays solid blue; the compositor skips the patch).

1. `MaskRenderer.update` projects the window's four corners (anchor-local +-w/2, +-h/2) to output px each frame (`mouthWindowCorners`,
   order top-left, top-right, bottom-right, bottom-left of the window, so it follows roll / yaw / pitch).
2. `MouthCutout.crop`: the outer-lip bounding box (from `FacePose.outerLips`, source px) grown by 30 % about its centre, then
   widened or heightened to the window's aspect (22:8) so the mouth is scaled to FILL the window without stretching. When the mouth opens
   the crop grows taller (and wider with it).
3. `Compositor` draws the crop, sampled rotated by the face's roll (so the mouth stays upright in the equally rolled window), as a 12x6
   grid over the quad, clipped by a signed-distance rounded rectangle (corner radius 25 % of the height) with a HARD edge (one pixel
   of anti-aliasing, no feather, no blur, no CPU raster, no mask texture). It is drawn BEFORE the mask, so the tint film covers it and the
   opaque mask hides everything outside the hole. Hidden without a live pose, in `off`, and while a scare is applied.

## Scare mode (Halloween)

Open the mouth wide AND both eyes wide at once: the eye and mouth windows go pitch black, the blue prints go black, a jagged black
demon face appears on the white vinyl, the room goes dark and cold. The white vinyl stays white: black on white is what reads scary.
Files: `ScareDetector.swift` (pure logic, tested in `ScareDetectorTests`), `ScareLook.swift` (SceneKit side), `LogoFace.swift` (the stencil),
`Compositor.metal`/`.swift` (vignette, flash, shake), `MaskRenderer.updateScareState`.

**Trigger** (`ScareDetector`, per frame, on the render queue, fed with the raw calibrated `FacePose` values):
fires when `mouthOpenness >= 0.7` AND `min(leftOpenness, rightOpenness) >= 0.92` continuously for 120 ms. Hysteresis: once on,
it stays while mouth >= 0.45 and both eyes >= 0.6; it releases after those failed for 300 ms, but never sooner than 1.2 s after
onset (a quick "boo" still reads). `forceScare` (RenderSettings, set by the "Test scare" button / Mask > Test Scare, Option-Command-S,
menu bar item) turns it on immediately for 2 s, then the normal release applies. No face = zeros = no trigger. The thresholds, hold, release,
minimum time, print colour and vignette are in `MaskStyle.scare` (Tune > Scare; thresholds are fractions of the user's calibrated range).

**One value drives everything.** `ScareEnvelope` turns the on/off decision into `scareAmount` 0...1: onset ease-out cubic over
80 ms (started one frame early, so the first frame already reads ~0.8 at 30 fps), release ease-in-out over 600 ms. Every piece
reads that float each frame; everything binary swaps at amount 0.5 (so: suddenly), and swaps back on release:

| Piece | Binary (amount crosses 0.5) | Continuous |
|---|---|---|
| Windows | each window's occluder is hidden (stops occluding) and its tint film becomes opaque #000000 (transparency 1, writes depth): black replaces the live video; the video mouth patch is not drawn | - |
| Prints | the blue prints (right bar, swoosh) become #0A0A0C (`scare.printColor`) | - |
| Demon stencil | node `scareFace` shown: flat black `SCNShape`s (0.3 thick, no chamfer, lambert black, no specular), back face 0.4 in front of the finger surface (all on one plane, so it also covers the swoosh, which stands in front of the palm). Eye slits centred on the eye windows (so the user's eyes are swallowed by black): sharp almonds ~17 wide, slanted inward-down, 4 flame spikes rising from each outer brow. Nose notch: small sharp inverted triangle at SVG (35.75, 41...47.5). Grin: 44 wide centred on (35.75, 66), corners curled up, black interior bounded by two zigzags: 7 long white fangs hang from the top lip, 6 shorter ones rise from the bottom lip (interleaved; the vinyl shows through as the fangs). 6 black cracks (thin tapering zigzag ribbons) radiate from the slits across the fingers. All authored in code (`LogoFace.eyeSlit`, `.grin`, `.crackLines`): original artwork | - |
| Vinyl | stays white | - |
| Light | - | low cold uplight: key 100 % -> 25 %, white -> cold blue, pitched from below-front (+40 deg); rim -> 0; image-based lighting -> 40 % |
| Headpiece | - | pop scale about the eye midpoint: 1.0 -> 1.12 over 80 ms, damped spring to 1.05 (`ScareEnvelope.pop`); released with the amount |
| Compositor | - | one more fullscreen draw (premultiplied blend): dark-red vignette `0.10 + 0.8 x vignette x edge` (x flicker, 9 Hz) x amount |
| Onset only | first 2 frames: 60 % white-ish flash and whole-frame shake (+6,+2) then (-6,-2) px (camera, mask and mouth patch shifted by a UV offset) | |

`ScareLook` owns the stencil node, so a geometry rebuild only needs `styleChanged(_:geometryChanged:)` (rebuild the stencil at the new
front z); `MaskRenderer.applyPendingStyle` calls it after `updateMaterials` (which resets prints, tints and occluders) so the scare
look is re-applied while a scare is on.

**HUD / status.** `RenderStats.scareActive` + `mouthOpenness` / `leftEyeOpenness` / `rightEyeOpenness` (published at 5 Hz while the
preview is on screen, immediately on a scare flip). The preview window shows a "SCARE" pill (lit orange while active). The tracking
overlay (Show tracking overlay) has a live line: state (idle / arming n % / ACTIVE), mouth value vs threshold, both eyes vs threshold,
amount; a reading that meets its threshold turns orange, so you can see which one blocks the trigger.

## Resting pose

No pose for > 0.4 s: `blend` eases (tau 0.25 s) from the last tracked pose to a centred (x = W/2, y = 0.4 H), front-facing pose at the last size
with a tiny sway; mouth patch hidden. A returning face eases back in.

## Tuning

| What | Where |
|---|---|
| Mask size 1.8-3.2, vertical position, show mouth | `RenderPipeline` properties / `RenderSettings` |
| Light intensities/angles, rest delay/ease | `MaskRenderer.Tuning` |
| Vertical position (main window slider), horizontal position (Tune) | `RenderSettings.verticalOffset`, `MaskStyle.horizontalOffset` |
| Eye-span factor, plane depth, smoothing | `MaskRenderer.Placement` |
| Finger padding / thickness, palm size, corner radius, collar | `MaskStyle` (Tune > Inflatable) |
| Vinyl colour / roughness / clear coat | `MaskStyle` (Tune > Vinyl) |
| Gradient on/off, print inset | `MaskStyle` (Tune > Print) |
| Window tint colour / opacity, mouth mode, mouth window size | `MaskStyle` (Tune > Windows) |
| Z layout of prints, windows, stencil; occluder alpha | `LogoMeshBuilder.Layer` |
| Mouth crop margin / corner radius | `MouthCutout.margin`, `.cornerRadius` (and `LogoMeshBuilder.mouthWindowCornerFraction`) |
| Scare thresholds, hold, print colour, vignette | `MaskStyle.scare` (Tune > Scare); release / minimum time `MaskStyle.Scare.releaseHoldMs` / `.minActiveSeconds`; keep levels, envelope times `ScareDetector.Config`, `ScareEnvelope`; light scale `ScareLook.Config` |
| Demon face shapes | `LogoFace.eyeSlit`, `.grin`, `.crackLines`, nose in `LogoFace.pieces()` |
| Alpha / colour space / MSAA | `Compositor.maskIsStraightAlpha`, `RenderConstants.maskPixelFormat`, `.msaaSamples` |

## Profiling

Signpost `frame` (subsystem `com.lawmatics.lmmask`, category `pipeline`) plus tracker's `process`. `RenderStats`
(published once a second): fps, tracking ms, render ms (3D + composite, includes the GPU wait), dropped frames.
