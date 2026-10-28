"""
inflate_logo.py -- Blender 4.x headless script.

Turns the 72x72 company mark (Assets/mark-light-color.svg) into an inflated
"pillow" 3D object, carves two eye sockets, applies a teal->blue gradient
material and exports USDZ (units: cm) plus a GLB preview.

Run from Assets/tools/:

    blender -b -P inflate_logo.py -- --svg ../mark-light-color.svg --out ../lm-mark.usdz

Options (after the `--`):
    --svg PATH        input SVG (required)
    --out PATH        output .usdz (required); a .glb is written next to it
    --pressure F      cloth uniform pressure force          (default 3.0)
    --frames N        cloth frames to simulate and apply     (default 40)
    --thickness F     slab thickness before inflation, cm    (default 0.6)
    --voxel F         remesh voxel size, cm                  (default 0.15)
    --fast            skip cloth; use a Bevel (width 2.4, segments 12,
                      profile 0.5) instead

Units: 1 SVG unit = 1 Blender unit = 1 cm. Scene scale_length is 0.01 so the
USD stage has metersPerUnit = 0.01. The mark is centred on the origin; the
base plane is z = 0.

Idempotent: the script starts from factory settings (empty scene), so running
it twice gives the same result.

NOTE: written without being able to run Blender. API names are for Blender
4.x; see the README for the list of things a reviewer should double-check.
"""

import argparse
import math
import sys
from pathlib import Path

import bpy
import numpy as np                     # bundled with Blender
from mathutils import Matrix, Vector, kdtree

# --- Geometry constants (SVG user units; viewBox "0 0 72.307 71.885") -------
SVG_W = 72.307
SVG_H = 71.885
SVG_CX = SVG_W / 2.0      # 36.1535  -> maps to Blender X = 0
SVG_CY = SVG_H / 2.0      # 35.9425  -> maps to Blender Y = 0 (Y is flipped)

# Dish (eye socket) parameters
DISH_RADIUS = 2.4         # cm
DISH_CENTRE_LIFT = 1.2    # sphere centre sits this far above the top surface,
                          # so the cut depth is DISH_RADIUS - lift = 1.2 cm
DISH_SITES = {            # SVG coords (y grows downward) -> empty name, island
    "bar_short": ((26.0, 26.0), "eye_L_socket"),
    "bar_tall": ((48.0, 15.0), "eye_R_socket"),
}

# Gradient from the SVG <linearGradient> (stops 0.0591 teal -> 1.0 blue)
GRAD_TEAL = (0x00, 0xB3, 0xC0)
GRAD_BLUE = (0x00, 0x9C, 0xE4)
GRAD_STOP0 = 0.0591
TEX_SIZE = 1024

RIM_GROUP = "rim"
RIM_RADIUS = 0.35         # cm: vertices closer than this to the outline are pinned
OUTLINE_STEP = 0.05       # cm: outline densification step for the rim test


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args():
    # Blender passes its own argv; everything after "--" is ours.
    argv = sys.argv
    argv = argv[argv.index("--") + 1:] if "--" in argv else []
    p = argparse.ArgumentParser(description="Inflate the mark SVG into a 3D pillow.")
    p.add_argument("--svg", required=True, help="input SVG path")
    p.add_argument("--out", required=True, help="output .usdz path")
    p.add_argument("--pressure", type=float, default=3.0, help="cloth pressure force")
    p.add_argument("--frames", type=int, default=40, help="cloth frames to bake")
    p.add_argument("--thickness", type=float, default=0.6, help="slab thickness (cm)")
    p.add_argument("--voxel", type=float, default=0.15, help="remesh voxel size (cm)")
    p.add_argument("--fast", action="store_true", help="use Bevel instead of cloth")
    return p.parse_args(argv)


# ---------------------------------------------------------------------------
# Scene setup
# ---------------------------------------------------------------------------
def reset_scene():
    """Start from factory settings so repeated runs are identical."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    try:
        import addon_utils
        addon_utils.enable("io_curve_svg", default_set=True, persistent=True)
    except Exception as exc:  # already enabled / built-in in some builds
        print(f"[inflate] io_curve_svg enable skipped: {exc}")

    scene = bpy.context.scene
    scene.unit_settings.system = "METRIC"
    scene.unit_settings.length_unit = "CENTIMETERS"
    scene.unit_settings.scale_length = 0.01   # 1 BU = 1 cm
    scene.frame_start = 1
    return scene


# ---------------------------------------------------------------------------
# Import and normalise
# ---------------------------------------------------------------------------
def import_mark(svg_path):
    """Import the SVG and return (mark_object, sx, sy, k, rect_cx, rect_cy).

    The SVG importer creates one curve per path. The "bounding" path is the
    full viewBox rectangle; we use it as the reference frame. Its first point
    is the SVG point (72.307, 71.885), i.e. bottom-right in SVG space. That
    tells us the importer's axis directions (sx, sy) and the scale factor k.
    """
    before = set(bpy.data.objects)
    bpy.ops.import_curve.svg(filepath=str(svg_path))
    new = [o for o in bpy.data.objects if o not in before]

    curves = [o for o in new if o.type == "CURVE"]
    bounding = [o for o in curves if "bounding" in o.name.lower()]
    marks = [o for o in curves if "bounding" not in o.name.lower()]
    if len(bounding) != 1 or not marks:
        raise RuntimeError(f"unexpected SVG import objects: {[o.name for o in new]}")

    # Reference rectangle: world-space points of its first spline.
    rect = bounding[0]
    rect_pts = []
    for sp in rect.data.splines:
        src = sp.bezier_points if sp.type == "BEZIER" else sp.points
        for p in src:
            rect_pts.append(rect.matrix_world @ Vector(p.co[:3]))
    xs = [p.x for p in rect_pts]
    ys = [p.y for p in rect_pts]
    rect_cx = 0.5 * (min(xs) + max(xs))
    rect_cy = 0.5 * (min(ys) + max(ys))
    rect_w = max(xs) - min(xs)
    k = SVG_W / rect_w                      # imported units -> cm
    p0 = rect_pts[0]                        # SVG (72.307, 71.885) = bottom-right
    sx = 1.0 if p0.x > rect_cx else -1.0    # is imported +X the SVG +X?
    sy = 1.0 if p0.y < rect_cy else -1.0    # SVG y grows down -> Blender Y flips

    # Keep the mark only; drop the reference rectangle and any group empties.
    mark = marks[0]
    world = mark.matrix_world.copy()
    mark.parent = None
    mark.matrix_world = world
    for o in new:
        if o is not mark:
            bpy.data.objects.remove(o, do_unlink=True)
    return mark, sx, sy, k, rect_cx, rect_cy


def to_mesh_normalised(mark, sx, sy, k, rect_cx, rect_cy):
    """Convert the curve to a single-sided filled mesh, bake transforms,
    and map it into cm with the SVG centre at the origin, Y up."""
    mark.data.dimensions = "2D"
    mark.data.fill_mode = "FRONT"   # single cap; BOTH would make doubled faces
    bpy.context.view_layer.objects.active = mark
    mark.select_set(True)
    bpy.ops.object.convert(target="MESH")
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    me = mark.data
    for v in me.vertices:
        v.co.x = sx * k * (v.co.x - rect_cx)
        v.co.y = sy * k * (v.co.y - rect_cy)
        v.co.z = 0.0                        # flat, base plane z = 0

    # Clean up: remove duplicate verts, and make the cap face +Z.
    bpy.context.view_layer.objects.active = mark
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=1e-4)
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    if sum(p.normal.z for p in mark.data.polygons) < 0:
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.flip_normals()
        bpy.ops.object.mode_set(mode="OBJECT")
    return mark


def split_islands(mark):
    """Separate by loose parts and name the four islands by bounding box."""
    before = set(bpy.data.objects)
    bpy.context.view_layer.objects.active = mark
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.separate(type="LOOSE")
    bpy.ops.object.mode_set(mode="OBJECT")
    islands = [mark] + [o for o in bpy.data.objects
                        if o not in before and o.type == "MESH"]
    if len(islands) != 4:
        raise RuntimeError(f"expected 4 islands, got {len(islands)}")

    w = {o: bbox(o)[2] for o in islands}   # width
    h = {o: bbox(o)[3] for o in islands}   # height
    swoosh = max(islands, key=lambda o: w[o])            # largest width
    rest = [o for o in islands if o is not swoosh]
    bar_right = max(rest, key=lambda o: h[o])            # largest height
    rest = [o for o in rest if o is not bar_right]
    bar_short = min(rest, key=lambda o: h[o])            # shortest bar
    bar_tall = [o for o in rest if o is not bar_short][0]

    named = {"swoosh": swoosh, "bar_right": bar_right,
             "bar_short": bar_short, "bar_tall": bar_tall}
    for name, obj in named.items():
        obj.name = name
        obj.data.name = name
    return named


def bbox(obj):
    """Return (minx, miny, width, height) of an object's mesh in local space."""
    xs = [v.co.x for v in obj.data.vertices]
    ys = [v.co.y for v in obj.data.vertices]
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


# ---------------------------------------------------------------------------
# Rim (outline) pinning
# ---------------------------------------------------------------------------
def outline_kdtree(obj):
    """Densified 2D outline of the flat island (edges with exactly one face)."""
    me = obj.data
    pts = []
    for e in me.edges:
        if len(e.link_faces) != 1:
            continue
        a = me.vertices[e.vertices[0]].co
        b = me.vertices[e.vertices[1]].co
        n = max(1, math.ceil((b - a).length / OUTLINE_STEP))
        for i in range(n):
            pts.append(a.lerp(b, i / n))
    kd = kdtree.KDTree(len(pts))
    for i, p in enumerate(pts):
        kd.insert(Vector((p.x, p.y, 0.0)), i)
    kd.balance()
    return kd


def make_rim_group(obj, outline):
    """Vertex group 'rim' = all vertices within RIM_RADIUS of the outline."""
    idx = []
    for v in obj.data.vertices:
        _, _, dist = outline.find(Vector((v.co.x, v.co.y, 0.0)))
        if dist is not None and dist < RIM_RADIUS:
            idx.append(v.index)
    vg = obj.vertex_groups.new(name=RIM_GROUP)
    vg.add(idx, 1.0, "REPLACE")
    return len(idx)


# ---------------------------------------------------------------------------
# Modifier helper
# ---------------------------------------------------------------------------
def apply_modifier(obj, mod):
    """Apply a modifier on obj (obj must be active)."""
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=mod.name)


# ---------------------------------------------------------------------------
# Per-island inflation
# ---------------------------------------------------------------------------
def inflate_island(obj, args):
    print(f"[inflate] {obj.name}: start")
    outline = outline_kdtree(obj)   # outline of the flat sheet, before solidify

    # 1. Give the flat sheet a thickness so it is a closed volume.
    sol = obj.modifiers.new("Solidify", "SOLIDIFY")
    sol.thickness = args.thickness
    sol.offset = 1.0                 # extrude along +normal (+Z) -> z in [0, t]
    apply_modifier(obj, sol)

    # 2. Voxel remesh to a clean, watertight, uniform mesh.
    rem = obj.modifiers.new("Remesh", "REMESH")
    rem.mode = "VOXEL"
    rem.voxel_size = args.voxel
    apply_modifier(obj, rem)

    # 3. Rim vertex group (pinned during the cloth sim).
    n_rim = make_rim_group(obj, outline)
    print(f"[inflate] {obj.name}: {len(obj.data.vertices)} verts, {n_rim} rim")

    # 4. Inflate: cloth pressure (default) or Bevel (--fast).
    if args.fast:
        bev = obj.modifiers.new("Bevel", "BEVEL")
        bev.width = 2.4
        bev.segments = 12
        bev.profile = 0.5
        bev.limit_method = "NONE"
        apply_modifier(obj, bev)
    else:
        run_cloth(obj, args)

    # 5. Mirror across the base plane (z = 0) with merge, so the bottom
    #    face is also rounded. See README: check for doubled geometry.
    mir = obj.modifiers.new("Mirror", "MIRROR")
    mir.use_axis = (False, False, True)
    mir.use_mirror_merge = True
    mir.merge_threshold = 0.001
    apply_modifier(obj, mir)

    # 6. Smooth shading.
    for poly in obj.data.polygons:
        poly.use_smooth = True
    print(f"[inflate] {obj.name}: done, {len(obj.data.vertices)} verts")


def run_cloth(obj, args):
    """Cloth sim with uniform pressure, rim pinned, baked for args.frames."""
    scene = bpy.context.scene
    cloth = obj.modifiers.new("Cloth", "CLOTH")
    s = cloth.settings
    s.use_pressure = True
    s.uniform_pressure_force = args.pressure
    s.vertex_group_mass = RIM_GROUP   # pinned vertices
    s.pin_stiffness = 1.0
    cloth.collision_settings.use_collision = False
    cloth.point_cache.frame_start = 1
    cloth.point_cache.frame_end = args.frames

    scene.frame_end = max(scene.frame_end, args.frames)
    # Step frames so the cloth cache fills in order, then apply at the last one.
    scene.frame_set(1)
    for f in range(2, args.frames + 1):
        scene.frame_set(f)
        bpy.context.evaluated_depsgraph_get().update()
    scene.frame_set(args.frames)
    apply_modifier(obj, cloth)
    scene.frame_set(1)


# ---------------------------------------------------------------------------
# Eye sockets
# ---------------------------------------------------------------------------
def svg_to_cm(x, y):
    """SVG (y down) -> Blender cm (Y up), centred on the mark origin."""
    return x - SVG_CX, -(y - SVG_CY)


def carve_dish(obj, cx, cy):
    """Boolean-subtract a sphere from the top cap of obj at (cx, cy)."""
    # Height of the top surface near the dish site.
    near = [v.co.z for v in obj.data.vertices
            if (v.co.x - cx) ** 2 + (v.co.y - cy) ** 2 < 1.5 ** 2]
    z_top = max(near) if near else max(v.co.z for v in obj.data.vertices)

    bpy.ops.mesh.primitive_uv_sphere_add(
        radius=DISH_RADIUS, segments=48, ring_count=24,
        location=(cx, cy, z_top + DISH_CENTRE_LIFT))
    sphere = bpy.context.active_object

    bool_mod = obj.modifiers.new("Dish", "BOOLEAN")
    bool_mod.operation = "DIFFERENCE"
    bool_mod.object = sphere
    bool_mod.solver = "EXACT"
    apply_modifier(obj, bool_mod)

    mesh = sphere.data
    bpy.data.objects.remove(sphere, do_unlink=True)
    bpy.data.meshes.remove(mesh)
    return z_top


def add_socket_empty(name, cx, cy, z):
    empty = bpy.data.objects.new(name, None)
    empty.empty_display_type = "PLAIN_AXES"
    empty.empty_display_size = 0.5
    empty.location = (cx, cy, z)
    bpy.context.scene.collection.objects.link(empty)
    return empty


# ---------------------------------------------------------------------------
# Material and UVs
# ---------------------------------------------------------------------------
def gradient_array(size):
    """RGBA float array: teal until the 0.0591 stop, then linear to blue."""
    t = np.linspace(0.0, 1.0, size)
    k = np.clip((t - GRAD_STOP0) / (1.0 - GRAD_STOP0), 0.0, 1.0)
    teal = np.array(GRAD_TEAL, dtype=np.float32) / 255.0
    blue = np.array(GRAD_BLUE, dtype=np.float32) / 255.0
    row = teal[None, :] + (blue - teal)[None, :] * k[:, None]    # (size, 3)
    arr = np.empty((size, size, 4), dtype=np.float32)
    arr[:, :, :3] = row[None, :, :]   # gradient runs along U (x) only
    arr[:, :, 3] = 1.0
    return arr


def project_uvs_from_front(objs):
    """UV = front-view (X, Y) normalised over the whole mark."""
    xs, ys = [], []
    for o in objs:
        xs += [v.co.x for v in o.data.vertices]
        ys += [v.co.y for v in o.data.vertices]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = x1 - x0, y1 - y0
    for o in objs:
        me = o.data
        uv = me.uv_layers.new(name="UVMap")
        for loop in me.loops:
            co = me.vertices[loop.vertex_index].co
            uv.data[loop.index].uv = ((co.x - x0) / w, (co.y - y0) / h)


def build_material(objs, out_dir):
    img = bpy.data.images.new("lm_gradient", TEX_SIZE, TEX_SIZE, alpha=True)
    img.colorspace_settings.name = "sRGB"
    img.pixels.foreach_set(gradient_array(TEX_SIZE).ravel())
    tex_path = out_dir / "lm_gradient.png"
    img.filepath_raw = str(tex_path)
    img.file_format = "PNG"
    img.save()

    mat = bpy.data.materials.new("lm_mark")
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get("Principled BSDF")
    bsdf.inputs["Roughness"].default_value = 0.35

    uv_node = nt.nodes.new("ShaderNodeUVMap")
    uv_node.uv_map = "UVMap"
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = img
    nt.links.new(uv_node.outputs["UV"], tex.inputs["Vector"])
    nt.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])

    for o in objs:
        o.data.materials.clear()
        o.data.materials.append(mat)
    return tex_path


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------
def export_usdz(out_path):
    bpy.ops.wm.usd_export(
        filepath=str(out_path),
        selected_objects_only=False,
        export_materials=True,
        export_uvmaps=True,
    )


def export_glb_preview(glb_path, objs, empties):
    """GLB in metres for preview. Works on scaled copies so the exporter
    needs no unit handling; the copies are removed afterwards."""
    scale = Matrix.Scale(0.01, 4)
    copies = []
    for o in objs:
        c = o.copy()
        c.data = o.data.copy()
        c.data.transform(scale)
        c.location = o.location * 0.01
        bpy.context.scene.collection.objects.link(c)
        copies.append(c)
    for e in empties:
        c = e.copy()
        c.location = e.location * 0.01
        bpy.context.scene.collection.objects.link(c)
        copies.append(c)

    bpy.ops.object.select_all(action="DESELECT")
    for c in copies:
        c.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=str(glb_path),
        export_format="GLB",
        use_selection=True,
        export_yup=True,
    )
    for c in copies:
        data = c.data
        bpy.data.objects.remove(c, do_unlink=True)
        if data is not None:
            bpy.data.meshes.remove(data)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    args = parse_args()
    svg_path = Path(args.svg).resolve()
    out_path = Path(args.out).resolve()
    out_dir = out_path.parent
    out_dir.mkdir(parents=True, exist_ok=True)

    scene = reset_scene()
    scene.frame_end = args.frames

    mark, sx, sy, k, rcx, rcy = import_mark(svg_path)
    mark = to_mesh_normalised(mark, sx, sy, k, rcx, rcy)
    islands = split_islands(mark)
    print("[inflate] islands:", {n: round(bbox(o)[2], 2) for n, o in islands.items()})

    objs = [islands["bar_short"], islands["bar_tall"],
            islands["swoosh"], islands["bar_right"]]
    for o in objs:
        inflate_island(o, args)

    # Eye sockets on the two bars (dish carved into the top cap).
    empties = []
    for bar, ((sx_svg, sy_svg), empty_name) in DISH_SITES.items():
        cx, cy = svg_to_cm(sx_svg, sy_svg)
        z_top = carve_dish(islands[bar], cx, cy)
        empties.append(add_socket_empty(empty_name, cx, cy, z_top))

    project_uvs_from_front(objs)
    tex_path = build_material(objs, out_dir)

    export_usdz(out_path)
    glb_path = out_path.with_suffix(".glb")
    export_glb_preview(glb_path, objs, empties)
    print(f"[inflate] wrote {out_path}, {glb_path}, {tex_path}")


if __name__ == "__main__":
    main()
