# Face tracking (LMMask/Tracking)

Pipeline: `CameraCapture` (AVCaptureSession, BGRA @30, 16:9 device format chosen explicitly, no session presets) -> `AsyncStream<CaptureFrame>` (newest-1) ->
`FaceTrackingPipeline` (detached task owning a `FaceTracker`) -> `AsyncStream<TrackingResult>` -> renderer.

The capture queue only wraps the pixel buffer and yields into the stream (non-blocking). Vision runs on the
pipeline task, never on the capture queue. Late frames are dropped, not queued.

## Coordinate conventions

| Space | Origin | y | Used for |
|---|---|---|---|
| Vision normalized | bottom-left | up | `VNFaceObservation.boundingBox`, `landmarks.*.normalizedPoints` (relative to the face box) |
| Vision image points | bottom-left | up | `pointsInImage(imageSize:)` (what we call) |
| Pixel (ours) | top-left | down | `FacePose.faceRect`, `outerLips`, eye centers, `allLandmarks` |
| Camera (metric) | camera center | up | `FacePose.headTransform` |

All 2D values (`faceRect`, lips, eye centres) are in pixels of the CAPTURED frame ("source"), which is not always 1280x720
(an external cam may deliver 1920x1080, or 4:3 if it offers nothing else). Consumers map them to output pixels with
`FrameMapping` (Shared/FrameFormat.swift): aspect-fill, centred crop, `out = (src - visibleOrigin) * scale`.

Conversion, done once in `FaceTracker`: `y_px = H - y_vision_px`; for rects `y = (1 - box.maxY) * H`.

Camera space: meters, right-handed, +x right, +y up, camera looks down -z (a face 0.6 m away has z = -0.6; same as
SceneKit/RealityKit/Metal convention). Frames are un-mirrored (`isVideoMirrored = false` is set explicitly on the capture connection); the virtual camera output is
never mirrored (Zoom mirrors the self-view), and the app preview is un-mirrored unless "Mirror preview" is on (preview only).

Head frame: identity rotation = head facing the camera (head +z points out of the face toward the camera). Origin is the
midpoint between the eyes (not the head center; the renderer applies its own pivot offset).

## Head transform derivation

NOTE (round 2): the metric `headTransform` (assumed 60 degree FOV, IPD depth) is no longer used to place the mask; placement is
screen-space from eye centres / face rect (docs/rendering.md "Placement"). The transform is still computed and filtered.
The renderer uses only `yaw`/`pitch` from `FacePose`; roll comes from the eye line in pixels (independent of Vision's roll sign).

1. Eye centers: for each eye, the two farthest-apart landmark points are the corners; center = their midpoint.
2. Focal length: `f = (W/2) / tan(60deg/2)` = 1108.5 px for W=1280 (assumed horizontal FOV, square pixels, principal
   point at image center).
3. Depth: interocular distance in pixels `d_px` (eye center to eye center) is divided by `cos(yaw)` (clamped >= 0.5) to
   undo foreshortening, then `Z = f * 0.063 m / d_px`. A 63 mm IPD at 1 m gives ~70 px. Error is roughly +-10 % across
   the population (IPD varies 54-74 mm), so absolute depth is approximate; relative motion is good.
4. Position: back-project the eye midpoint pixel `(u,v)`: `X = (u-cx) Z/f`, `Y = -(v-cy) Z/f`, `z = -Z`.
5. Rotation: Vision `yaw`, `pitch`, `roll` (radians, revision 3) composed intrinsically `R = Ry(yaw) * Rx(pitch) * Rz(roll)`.
   Sign factors live in `FaceTrackerConfiguration` (`yawSign`, `pitchSign`, `rollSign`) pending on-device verification.
6. The raw 4x4 is smoothed by `TransformOneEuroFilter` (translation per axis; rotation via quaternion slerp).
   `roll/yaw/pitch` in `FacePose` are separately One-Euro filtered scalars; `faceRect`, lips and eye centers are raw.

## Capture format

`CameraCapture.applyFormat` ranks device formats that support 30 fps: 16:9 first (|w/h - 16/9| < 0.01), then exactly 1280 wide,
then the smallest width above 1280 (1920x1080), then the largest below; non-16:9 is only chosen if no 16:9 format exists. Setting
`activeFormat` implies `.inputPriority`. The chosen dimensions are logged (`category capture`, "Capture format on ...").

## Eye openness

EAR = height / width of the eye contour, computed order-independently from all 8 points (Vision does not document the
contour order). Calibration: during the first 90 frames with a face, collect each eye's EAR; open = 95th percentile
(blinks in that window are ignored), closed = 0.4 * open. `openness = clamp((EAR - closed) / (open - closed))`, then a
One-Euro filter with a high cutoff (5 Hz, beta 0.5) so a 100 ms blink isn't smeared. While calibrating, openness reports 1.
`recalibrate()` restarts it. Head pitch changes EAR (looking down narrows the eye); recalibrate if the user changes posture a lot.

## Filters

`OneEuroFilter` / `QuaternionOneEuroFilter` / `TransformOneEuroFilter` (min cutoff 1.0 Hz, beta 0.02, d cutoff 1.0 Hz).
Quaternion speed is angular speed in rad/s; samples are hemisphere-aligned. Non-monotonic timestamps re-seed. After 0.5 s
without a face all filters reset. Math tests: `LMMaskTests/OneEuroFilterTests.swift`, `FaceGeometryTests.swift`.

## Performance

Budget < 8 ms/frame on M1. Vision's landmark request dominates (typically 4-6 ms on the ANE/GPU). Everything else is a few
microseconds of float math. `TrackingResult.processingMilliseconds` reports per-frame cost and the debug view shows a
moving average; `OSSignposter` interval "process" (subsystem `com.lawmatics.lmmask`, category `tracker`) is visible in
Instruments. Known per-frame allocations are inside Vision and in the `[SIMD2<Float>]` arrays in `FacePose`
(see QUESTIONS.md Q5). This has NOT been measured yet (no Xcode available when written).
