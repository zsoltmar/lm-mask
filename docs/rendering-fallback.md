# Rendering: the inflatable glove (in-code)

Round 5 rebuild. Nothing here has been compiled or run (no Xcode when written); see CHECKLIST.md "Round 5".

The mask is a white inflatable toy worn over the head, like an inflatable glove: the logo's four islands are four separate
puffy tubes ("fingers", fully round cross-section) lying on a puffy white palm. Glossy white vinyl, strong highlight. The blue
logo is PRINTED on the fingers. The two middle bars are transparent WINDOWS for the user's real eyes (blue tint, sharp edges);
the swoosh's horizontal run has a sharp window that shows the user's real mouth. The right bar and the swoosh are solid blue.
It is built in code; a bundled `lm-mark.usdz` is no longer loaded.

Files: `LMMask/Rendering/MaskStyle.swift` (all tunables), `LogoSilhouette.swift` (2D outlines + polygon offset),
`LogoMeshBuilder.swift` (geometry, windows, materials), `LogoFace.swift` (the scare demon stencil), `LogoAssetLoader.swift`,
`SVGPathParser.swift`. `LogoMouth.swift` is an empty comment (obsolete; delete it and re-run `xcodegen generate` when convenient).
Live tuning: the "Tune" inspector in `PreviewWindow` (`UI/TunePanel.swift`), persisted by `RenderPipeline.style`.

## Coordinate frame

- Origin: centre of the SVG viewBox (72.307 x 71.885), so SVG point (x, y) maps to (x - 36.1535, -(y - 35.9425)).
- +x right, +y up (SVG y is flipped), +z toward the viewer.
- 1 SVG unit = 1 cm. Child geometry and positions are in cm; the root `lmMark` node has `scale = 0.01`, so world space is metres.
- `MaskStyle` fields named `body*` / the collar rect / the anchors are given in SVG coordinates (y down); the builder converts.

## Node tree and names

| Node | Content |
| --- | --- |
| `lmMark` | root |
| `headpiece` | the palm: rounded-rect pillow, SVG x 2...70, y 34...86, corner radius 14, depth `bodyDepth` 16, chamfer = depth / 2, centred on z = -2 |
| `collar` | optional neck pillow (`showCollar`): SVG x -4...76, y 80...100, radius 10, depth 14, z centre -4 |
| `logo` > `bar_short`, `bar_tall`, `swoosh`, `bar_right` | the four finger pillows: island outline + `fingerPad` (2), extruded `fingerDepth` (9.3 = the bars' own width), chamfer = depth / 2 (capped at 6) with the quarter-circle profile, centred on the palm's FRONT plane (so half of each tube is sunk into the palm) |
| `prints` > `print_swoosh`, `print_bar_right` | opaque blue prints: island outline shrunk by `printInset` (0.6), `SCNShape` 0.3 thick, no chamfer, back face 0.2 in front of the finger surface, PBR roughness 0.3, teal to blue gradient (or flat #009CE4) |
| `prints` > `window_bar_short`, `window_bar_tall` | eye windows (same shape as the print would have) |
| `prints` > `window_mouth` | mouth window: 22 x 8 rounded rect (`mouthWindowWidth/Height`, corner radius 25 % of the height) centred on SVG (35.7, 66) |
| window > `occluder` | colour-less depth writer: `transparency 0`, `colorBufferWriteMask = []`, `writesToDepthBuffer`, node `renderingOrder -10` |
| window > `tint` | coplanar film 0.05 in front: diffuse `tintColor` #009CE4, `transparency = tintOpacity` (0.42), `blendMode .alpha`, `writesToDepthBuffer false`, `renderingOrder 10`, unlit |
| `eye_L_socket` | empty at SVG (27.5, 30), inside the short bar, on the window plane |
| `eye_R_socket` | empty at SVG (44, 30), inside the tall bar (same height: level eyes land in both windows) |
| `mouthAnchor` | empty at SVG (35.7, 66), the swoosh run's centre; also the centre of the mouth window |
| `scareFace` (added by `ScareLook`) | the black demon stencil, hidden until a scare (see docs/rendering.md "Scare") |

Z layout (relative to `fingerFront`, the front-most point of the finger pillows): print back +0.2 (0.3 thick), occluder back +0.52
(0.1 thick), tint back +0.67 (0.02 thick), anchors / window plane +0.69, scare stencil back +0.4 (0.3 thick).

## Geometry

1. **Island outlines** (`LogoSilhouette.build`, instant: no raster, no Vision): the four SVG subpaths are flattened (cubics in 0.8
   unit steps, long lines cut to 1.5), centred, forced counter-clockwise, classified by bounding box (tallest = right bar, widest of
   the rest = swoosh, shortest = short bar). The pillow outline is the polygon pushed OUTWARD by `fingerPad`, the print / window
   outline INWARD by `printInset`, both by moving every vertex along the mitred normal of its two edges (miter limited to 2x).
   That is exact for these smooth, convex-ish islands (the swoosh's concave corner has a radius of ~10, far above the 2 unit pad)
   and needs no clipping. The raster / dilation / chin-blob union of rounds 2-4 is gone.
2. **Pillows** (`LogoMeshBuilder.pillow`): `SCNShape(path:extrusionDepth:)`, `chamferMode = .both`, `chamferRadius = depth / 2`
   (quarter-circle profile), so the cross-section is a rounded tube. Each node is moved so the MEASURED middle of the geometry
   sits where it should (SceneKit does not document where it puts the extrusion on z). The palm is the same function on a rounded
   rectangle (`LogoSilhouette.roundedRect`).
3. **Fingers on the palm**: finger centre z = palm front z, so the tubes are half sunk into the palm and their fronts stand half a
   finger depth (4.65) proud of it. The seams between pillows are simply where two inflated shapes meet.
4. **Prints / windows** (`flat`): thin `SCNShape`s at fixed offsets in front of the finger front (z layout above). The printed
   shape and the window are flat while the tube is round, so their edges float up to ~1 unit above the curving flanks: that reads as
   a printed patch standing off the vinyl. Raise `printInset` to pull the edges onto the flat top.
5. **Occluder trick** (windows): the mask texture is cleared to alpha 0. The occluder writes depth but no colour, so the
   pillows and the palm behind it fail the depth test and leave alpha 0 there: the compositor's camera frame shows through with a
   SHARP geometric edge (no feathering). The tint film (alpha 0.42 blue) is drawn after it, so the video is tinted blue through the
   window.
6. **Materials**: vinyl is ONE shared PBR instance on the palm, collar and fingers: diffuse #F7F8FA, roughness 0.22, metalness 0, clear
   coat 0.8, clear coat roughness 0.15. Lights (`MaskRenderer.Tuning`): one strong key directional 30 degrees up / 30 degrees left
   (1500), a rim directional from behind and above on the right (900), and the camera-probe image-based lighting.

Trade-offs to know about:

- The mask is bigger than the face. Placement matches the SOCKET distance (16.5 units) to the user's eye distance, so 1 unit is about
  0.38 cm: the palm is ~26 cm wide, the mouth window is ~14 cm below the eyes (the real mouth is ~7 cm). That is why the mouth is
  relocated into its window. `Mask size` still scales everything about the eye midpoint.
- Vertical position now defaults to 0 (was +0.35): the eyes must land inside the eye windows. The stored key was renamed so an old
  value does not linger.
- `fingerDepth` default is 9.3, the bars' real width (the brief said "about 7"). The tube is 13.3 wide (bar + 2 x pad) and 9.3 deep, so
  it is a soft oval rather than a perfect circle; set depth = 13.3 for a true circle.

## Mouth window

`MaskStyle.mouthMode` = `window` | `off`. `RenderWorker` only runs the compositor's mouth pass for `.window` (`MaskRenderer.mouthWindowActive`:
window mode, tracking, no scare). Off hides the window group, so the swoosh stays solid blue.

Per frame: `MaskRenderer.update` projects the window's four corners (anchor-local (+-w/2, +-h/2) -> world -> pinhole -> output px). `MouthCutout.crop`
takes the outer-lip bounding box from `FacePose`, grows it by 30 % about its centre and widens / heightens it to the window's aspect (so
the mouth is never stretched). The compositor draws that crop, rotated by the face's roll, as a 12x6 grid over the projected quad,
clipped to the window's rounded rectangle with a hard edge (one pixel of anti-aliasing), BEFORE the mask: so the mask's tint film
covers it and the opaque mask hides anything outside the hole. No mask texture, no blur, no feather.

## Style plumbing

`MaskStyle` (Codable, JSON in UserDefaults key `lm.maskStyle.v3`, lenient decode, clamped to `MaskStyle.Limits`) -> `RenderPipeline.style` ->
`RenderWorker.submit` -> `MaskRenderer.submit(StyleUpdate)` -> applied at the start of the next `render(time:)`: materials and visibility
always (`LogoMeshBuilder.updateMaterials`); geometry only when a geometry field changed (`MaskStyle.geometryDiffers`, debounced 150 ms in
the pipeline, rebuilt synchronously on the render queue: no off-thread silhouette any more). "Copy as JSON" / "Paste" in the Tune panel
exchange the same JSON.

## Known uncertainties (could not compile or run when written)

1. The occluder: `transparency = 0` together with `colorBufferWriteMask = []` and depth writes. If SceneKit culls fully transparent geometry
   the windows will stay opaque white: set `LogoMeshBuilder.Layer.occluderTransparency = 1` (the colour mask alone hides it).
2. Alpha of the blended tint in the mask texture: `.alpha` blending may write alpha = 0.42 x 0.42 (not 0.42) into the cleared texture, which
   would make the tint look weaker than `tintOpacity`. `Compositor.maskIsStraightAlpha` / QUESTIONS D1 cover the same family of doubts.
3. `SCNShape` UVs (per-shape 0...1 across its bounding box) and the gradient remap: unchanged assumption. Toggle "Teal to blue gradient"
   off (flat blue) if the gradient looks wrong.
4. Where SceneKit puts the extrusion on z, and whether the chamfer adds to or eats into `extrusionDepth`: the builder measures the bounding
   box and places by it, so layout survives either, but the finger thickness would then differ from `fingerDepth`.
5. Chamfer profile orientation (`LogoMeshBuilder.Style.flipChamfer`): if the pillow edges look dented instead of puffy, flip it.
6. Contour winding: all polygons are forced counter-clockwise; if a pillow renders inside-out (dark or invisible), reverse the points in
   `LogoSilhouette.counterClockwise`.

References: https://developer.apple.com/documentation/scenekit/scnshape,
https://developer.apple.com/documentation/scenekit/scnmaterial,
https://developer.apple.com/documentation/scenekit/scnnode/1408023-renderingorder
