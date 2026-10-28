# inflate_logo.py

Turns `Assets/mark-light-color.svg` into an inflated "pillow" 3D mark, with two
eye sockets, a teal-to-blue gradient texture, a USDZ export (units: cm) and a
GLB preview.

## Command

Run from `Assets/tools/`:

```sh
blender -b -P inflate_logo.py -- --svg ../mark-light-color.svg --out ../lm-mark.usdz
```

Outputs: `../lm-mark.usdz`, `../lm-mark.glb`, `../lm_gradient.png`.

Options after `--`:

| Flag | Default | Meaning |
|---|---|---|
| `--pressure` | 3.0 | Cloth uniform pressure force |
| `--frames` | 40 | Cloth frames simulated and applied |
| `--thickness` | 0.6 | Slab thickness before inflation (cm) |
| `--voxel` | 0.15 | Remesh voxel size (cm) |
| `--fast` | off | Skip cloth; use Bevel (width 2.4, segments 12, profile 0.5) |

Fast preview: add `--fast` to the command above.

## Blender version

Written for Blender 4.x. Not yet run: no Blender was available when the script
was written. Please record the exact version used on the first run
(`blender --version`) here.

## What to check visually

1. **Import and scale.** Four islands named `bar_short`, `bar_tall`, `swoosh`,
   `bar_right`, with the mark centred on the origin and upright (the tallest
   bar, `bar_right`, is on the right, pointing up). The overall width should be
   about 72 cm.
2. **Inflation.** Each island is a rounded pillow, with both faces domed and
   the outline staying in place (the rim is pinned). Check for:
   - no doubled or z-fighting faces at z = 0 (the Mirror step, see below);
   - no spikes or flat patches from the cloth solve;
   - the swoosh's thin L arm still reads as a swoosh.
3. **Eye sockets.** Spherical dishes (radius 2.4 cm) on the top of `bar_short`
   and `bar_tall`, with empties `eye_L_socket` and `eye_R_socket` at the dish
   centres.
4. **Colour.** A horizontal gradient from teal (`#00B3C0`) on the left to blue
   (`#009CE4`) on the right. Check that the texture is not mirrored or rotated
   in the USDZ viewer.
5. **Roughness.** The surface should look satin (roughness 0.35), not glossy.
6. **Units.** Open the USDZ in Reality Composer or Quick Look: the mark should
   be about 7 cm wide at the scale a viewer expects, with metres-per-unit 0.01.
   The GLB should be about 0.72 m wide.

## Uncertainties for review

These were written without running Blender. Check each before relying on it.

- **SVG import axes.** The script assumes the first point of the `bounding`
  rectangle in the imported curve is the SVG bottom-right corner, and uses it
  to set axis signs. If the mark appears mirrored or upside-down, check this
  first (`sx`, `sy` in `import_mark`).
- **Mirror step and cloth result.** The Mirror across z = 0 is applied after
  the cloth result. The cloth result already has both faces (solidify plus
  pressure), so mirroring may produce overlapping shells. If the bottom looks
  doubled, remove the Mirror block in `inflate_island`.
- **Rim pinning.** The rim is found by distance to the flat sheet's outline
  (`RIM_RADIUS` 0.35 cm), measured after the remesh. If the cloth moves the
  outline, the radius or the outline step may need changing.
- **Cloth bake.** The script steps frames with `scene.frame_set` rather than
  calling `ptcache.bake`, so the cache fills in order. It then applies the
  modifier at the last frame. Check the cloth cache is not empty after the run.
- **Cloth API names.** Used: `modifiers.new(type='CLOTH')`,
  `settings.use_pressure`, `settings.uniform_pressure_force`,
  `settings.vertex_group_mass`, `settings.pin_stiffness`,
  `collision_settings.use_collision`, `point_cache.frame_start/frame_end`.
- **Importer and factory reset.** `bpy.ops.wm.read_factory_settings(use_empty=True)`
  is used for idempotency. It also resets the scene units, which the script
  then sets.
- **USD export.** `bpy.ops.wm.usd_export` is called with
  `selected_objects_only`, `export_materials`, `export_uvmaps`. If the file is
  not written as a USDZ archive (only `.usdc`), package it with `usdzip`. Check
  that the textures are inside the archive. `export_textures` was left out
  because its name varies between 4.x releases.
- **GLB export.** The GLB is built from scaled copies (0.01x) so the glTF
  exporter does not need unit handling. The copies are removed afterwards.
- **Bevel in `--fast`.** The bevel width (2.4 cm) is larger than the default
  slab thickness (0.6 cm). With `limit_method='NONE'` the bevel may fold over
  itself. Check the edges.
- **Dish depth.** The sphere centre is 1.2 cm above the highest vertex near the
  site (within 1.5 cm). Adjust `DISH_CENTRE_LIFT` if the dish is too shallow or
  too deep.
