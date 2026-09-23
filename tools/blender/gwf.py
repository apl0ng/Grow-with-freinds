"""gwf.py - Grow With Friends Blender helper library (bpy 4.2, no GUI). Owner: pipeline agent.

Every model script in tools/blender/models/ does `from gwf import *` and defines `build()`, which builds
one model (or a family) and calls `export(...)`. Run scripts through tools/blender/build.py, never directly.
Workflow, conventions and the review checklist: MODELING.md (repo root).

Conventions (enforced or checked by export()):
  * 1 Blender unit = 1 m. Blender Z is up.
  * FRONT = Blender -Y, ALWAYS (what Blender's Front view shows; +X is to your right when you look at
    it). glTF export (+Y up) maps Blender (x, y, z) -> Godot (x, z, -y), so the front lands on Godot +Z:
    the convention of the game's stations and room props ("front = +Z faces the room centre / out of the
    wall"). Characters and held items face Godot -Z (cameras, look_at, face.tscn on -Z): declare them
    with export(kind="character" | "item") and the export bakes a 180 degree turn (into the mesh data and
    node positions, never into node rotations). Author everything the same way.
  * Origin = the contact point: floor props at the centre of their footprint on z = 0 (mount="floor"),
    ceiling props at their mount point with everything below z = 0 (mount="ceiling"), wall props with
    their back on y = 0 and the body towards the front, -y (mount="wall").
  * Flat colours only (no textures, no UVs). Materials come from lib("rust") (the Godot library material
    art/materials/toon_rust.tres, swapped in at runtime) or material("name", "#hex", finish).
  * TINT materials (tint_material()) are recoloured at runtime (strain / player / paint colour).

Builders return a new mesh object placed at `pos` (metres) rotated by `rot` (degrees XYZ). Anchors:
box/cyl/cone/capsule/plank/lathe sit ON `pos` (pos = centre of the bottom); sphere/torus are centred on
`pos`. `mat` takes a material or a string (a library name for lib()). Modifiers (bevel, subdiv, mirror,
array) stay live until join()/export() apply them; smoothing by angle is applied after the modifiers.
"""

import bpy
import bmesh
import math
import os
import re
import sys
import tempfile
import time
import contextlib
from mathutils import Vector, Matrix, Euler

__all__ = [
    # scene + materials
    "reset", "srgb", "material", "lib", "tint_material", "pal", "PALETTE", "FINISH_ROUGHNESS",
    # builders
    "box", "plank", "cyl", "cone", "sphere", "capsule", "torus", "lathe", "pipe", "extrude_profile",
    "arc_panel", "band", "sag_points", "empty",
    # modifiers / ops
    "bevel", "subdiv", "mirror", "array", "boolean_cut", "set_smooth", "join", "duplicate",
    "set_material", "paint", "set_origin", "set_origin_to_floor", "set_parent", "apply_transform", "apply_modifiers",
    "move_verts", "taper", "jitter", "dent", "subdivide",
    # output
    "report", "export", "EXPORTS", "OPTIONS", "FRONT", "KINDS", "REPO", "MODELS_DIR",
    # re-exports for model scripts
    "Vector", "Matrix", "math",
]

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
MODELS_DIR = os.path.join(REPO, "art", "models")
LIB_DIR = os.path.join(REPO, "art", "materials")
TOON_GD = os.path.join(REPO, "scripts", "art", "toon.gd")
FRONT = (0.0, -1.0, 0.0)  # Blender -Y == Godot +Z (stations/props); kind="character"/"item" -> Godot -Z

# export(kind=...): Godot facing + default tri budget. See MODELING.md "Conventions".
KINDS = {
    "prop": ("+z", 3000),       # room decor, furniture, lamps, signs (front = +Z like scenes/world/props)
    "station": ("+z", 5000),    # interactables the players stand in front of (front = +Z to the room)
    "character": ("-z", 8000),  # player body, Boss: face on Godot -Z (face.tscn, look_at)
    "item": ("-z", 1500),       # held items: point along the camera's -Z when held
    "part": ("+z", 3000),       # pieces other scenes assemble (plant stages, doors, hands)
}

# Finish -> Principled roughness. Toonify maps roughness back to the same Toon.Finish (>= 0.65 MATTE,
# <= 0.3 GLOSSY, else SOFT), so these numbers must stay inside those bands.
FINISH_ROUGHNESS = {"soft": 0.45, "matte": 0.8, "glossy": 0.22, "glow": 0.45, "flat": 0.5}
TINT_NEUTRAL = "#d9d9d9"  # Toonify: this grey == exactly the tint colour

# Build options, set by build.py (--preview / --preview-dir).
OPTIONS = {"preview": False, "preview_dir": os.path.join(tempfile.gettempdir(), "gwf_previews"), "verbose": False}
# One record per export() call since the process started: dicts with name, path, tris, size, ... (build.py)
EXPORTS = []

_MATS = {}


# ================================================================================================ scene
def reset():
    """Empty scene, metric units, material cache cleared. build.py calls it before every model script."""
    bpy.ops.wm.read_factory_settings(use_empty=True)
    _MATS.clear()
    s = bpy.context.scene
    s.unit_settings.system = 'METRIC'
    s.unit_settings.scale_length = 1.0


@contextlib.contextmanager
def _quiet():
    """Silences C-level stdout/stderr (glTF exporter INFO spam, Draco warning, Cycles progress)."""
    if OPTIONS.get("verbose"):
        yield
        return
    sys.stdout.flush()
    sys.stderr.flush()
    saved = os.dup(1), os.dup(2)
    with tempfile.TemporaryFile(mode="w+b") as sink:
        os.dup2(sink.fileno(), 1)
        os.dup2(sink.fileno(), 2)
        try:
            yield
        except Exception:
            os.dup2(saved[0], 1)
            os.dup2(saved[1], 2)
            sink.seek(0)
            sys.stderr.write(sink.read().decode("utf-8", "replace")[-4000:])
            raise
        finally:
            sys.stdout.flush()
            os.dup2(saved[0], 1)
            os.dup2(saved[1], 2)
            os.close(saved[0])
            os.close(saved[1])


# ============================================================================================= materials
def _to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def srgb(color, alpha=None):
    """'#rrggbb' / 'rrggbb' / '#rrggbbaa' / (r, g, b[, a]) sRGB 0..1  ->  linear RGBA tuple for Blender.
    Blender's Base Color is linear; Godot shows the sRGB value again, so the game colour == the hex."""
    if isinstance(color, str):
        h = color.strip().lstrip("#")
        if len(h) not in (6, 8) or not re.fullmatch(r"[0-9a-fA-F]+", h):
            raise ValueError("bad hex colour %r" % color)
        vals = [int(h[i:i + 2], 16) / 255.0 for i in range(0, len(h), 2)]
    else:
        vals = [float(v) for v in color]
    r, g, b = (_to_linear(v) for v in vals[:3])
    a = vals[3] if len(vals) > 3 else 1.0
    if alpha is not None:
        a = alpha
    return (r, g, b, a)


def _hex(color):
    if isinstance(color, str):
        return "#" + color.strip().lstrip("#").lower()
    return "#" + "".join("%02x" % round(max(0, min(1, v)) * 255) for v in color[:3])


def _principled(name, lin_rgba, roughness, emission=0.0, double_sided=False):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = lin_rgba
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Roughness"].default_value = roughness
    if emission and emission > 0:
        bsdf.inputs["Emission Color"].default_value = lin_rgba
        bsdf.inputs["Emission Strength"].default_value = emission
    if lin_rgba[3] < 1.0:
        bsdf.inputs["Alpha"].default_value = lin_rgba[3]
        m.blend_method = 'BLEND'
        m.surface_render_method = 'BLENDED'
    m.use_backface_culling = not double_sided  # glTF doubleSided=false -> Godot cull back faces
    m.diffuse_color = lin_rgba  # viewport colour
    return m


def material(name, color, finish="soft", emission=None, alpha=1.0, roughness=None, double_sided=False):
    """A custom flat-colour material (cached by name; the same name with other settings is an error).
    finish: soft (props, default) | matte (big surfaces, rubber, fabric, concrete) | glossy (metal, glass,
    wet) | glow (soft + faint emission 0.12) | flat (unshaded sticker: name gets a FLAT_ prefix).
    Prefer lib() when a library colour fits: it follows the art agent's retunes automatically."""
    if finish not in FINISH_ROUGHNESS:
        raise ValueError("finish must be one of %s" % ", ".join(FINISH_ROUGHNESS))
    if finish == "flat" and not name.startswith("FLAT"):
        name = "FLAT_" + name
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
        raise ValueError("material name %r: use letters, digits and _ only" % name)
    if emission is None:
        emission = 0.12 if finish == "glow" else 0.0
    rough = FINISH_ROUGHNESS[finish] if roughness is None else roughness
    key = (_hex(color), finish, round(emission, 4), round(alpha, 4), round(rough, 4), double_sided)
    if name in _MATS:
        if _MATS[name][1] != key:
            raise ValueError("material %r already defined with other settings %s" % (name, _MATS[name][1]))
        return _MATS[name][0]
    m = _principled(name, srgb(color, alpha), rough, emission, double_sided)
    _MATS[name] = (m, key)
    return m


def tint_material(name="TINT", shade=1.0, finish="soft", emission=None):
    """A runtime-tinted material (strain colour, paint colour...). Painted neutral grey; `shade` < 1 makes a
    darker shade of the tint (0.7 = 70 %), > 1 a lighter one. Toonify: albedo = tint * shade."""
    if not name.startswith("TINT"):
        name = "TINT_" + name
    v = max(0.0, min(1.0, 0.851 * shade))  # 0.851 = #d9d9d9
    return material(name, (v, v, v), finish=finish, emission=emission)


_LIB = None


def _parse_color(s):
    return [float(x) for x in s.split(",")]


def _library():
    global _LIB
    if _LIB is None:
        _LIB = {}
        if os.path.isdir(LIB_DIR):
            for f in sorted(os.listdir(LIB_DIR)):
                if not (f.startswith("toon_") and f.endswith(".tres")):
                    continue
                txt = open(os.path.join(LIB_DIR, f), encoding="utf-8").read()
                if "StandardMaterial3D" not in txt.split("\n", 1)[0]:
                    continue
                props = dict(re.findall(r"^(\w+) = (.+)$", txt, re.M))
                col = re.search(r"Color\(([^)]*)\)", props.get("albedo_color", "Color(1, 1, 1, 1)"))
                rgba = _parse_color(col.group(1)) if col else [1, 1, 1, 1]
                _LIB[f[5:-5]] = {
                    "rgba": rgba,
                    "roughness": float(props.get("roughness", "1.0")),
                    "emission": float(props.get("emission_energy_multiplier", "1.0"))
                    if props.get("emission_enabled") == "true" else 0.0,
                    "unshaded": props.get("shading_mode") == "0",
                    "alpha": props.get("transparency", "0") != "0",
                    "grow": props.get("grow") == "true",
                }
    return _LIB


def lib(name):
    """The library material art/materials/toon_<name>.tres as a Blender material named 'toon_<name>'.
    Colour/finish are read from the .tres; in Godot, Toonify swaps in the real library material.
    Examples: lib("rust"), lib("metal_dark"), lib("caution"), lib("leaf"), lib("dark"), lib("eye_white")."""
    name = name[5:] if name.startswith("toon_") else name
    table = _library()
    if name not in table or table[name]["grow"]:
        raise ValueError("no library material toon_%s.tres; have: %s" % (name, ", ".join(
            k for k, v in table.items() if not v["grow"])))
    full = "toon_" + name
    if full in _MATS:
        return _MATS[full][0]
    d = table[name]
    lin = srgb(d["rgba"][:3], d["rgba"][3] if len(d["rgba"]) > 3 and d["alpha"] else 1.0)
    rough = min(d["roughness"], 0.9)
    m = _principled(full, lin, rough, d["emission"], double_sided=d["alpha"])
    _MATS[full] = (m, ("lib", name))
    return m


def _read_palette():
    pal = {}
    try:
        txt = open(TOON_GD, encoding="utf-8").read()
        for k, v in re.findall(r'^const (\w+) := Color\("#?([0-9a-fA-F]{6,8})"\)', txt, re.M):
            pal[k] = "#" + v.lower()
    except OSError:
        pass
    return pal


PALETTE = _read_palette()  # Toon constants from scripts/art/toon.gd: PALETTE["INK"] == "#2e2a3d"


def pal(const_name):
    """Hex of a Toon palette constant (read from scripts/art/toon.gd), e.g. pal("INK"), pal("COCOA")."""
    if const_name not in PALETTE:
        raise ValueError("no Toon.%s; have %s" % (const_name, ", ".join(sorted(PALETTE))))
    return PALETTE[const_name]


def _resolve_mat(mat):
    if mat is None or isinstance(mat, bpy.types.Material):
        return mat
    if isinstance(mat, str):
        return lib(mat)
    raise TypeError("mat must be a bpy Material or a library name string")


# ============================================================================================== objects
def _rad(rot):
    return Euler(tuple(math.radians(a) for a in rot), 'XYZ')


def _link(name, bm, mat=None, pos=(0, 0, 0), rot=(0, 0, 0), smooth=35.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = Vector(pos)
    obj.rotation_euler = _rad(rot)
    obj["gwf_smooth"] = float(smooth)
    m = _resolve_mat(mat)
    if m is not None:
        me.materials.append(m)
    return obj


def empty(name="pivot", pos=(0, 0, 0), rot=(0, 0, 0)):
    """An empty (exports as a plain Node3D): a pivot / socket / marker for Godot code."""
    obj = bpy.data.objects.new(name, None)
    bpy.context.scene.collection.objects.link(obj)
    obj.location = Vector(pos)
    obj.rotation_euler = _rad(rot)
    return obj


def box(size, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.02, segments=None, mat=None, name="box", anchor="base"):
    """Box of size (x, y, z) standing on pos (anchor="center" to centre it). bevel = radius in metres
    (0 = sharp; segments None = auto by size)."""
    sx, sy, sz = size
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(sx, sy, sz), verts=bm.verts)
    if anchor == "base":
        bmesh.ops.translate(bm, vec=(0, 0, sz / 2), verts=bm.verts)
    obj = _link(name, bm, mat, pos, rot)
    if bevel and bevel > 0:
        globals()["bevel"](obj, min(bevel, min(size) * 0.49), segments)
    return obj


def plank(length, width=0.14, thickness=0.035, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.01, mat="wood",
          name="plank", anchor="base"):
    """A board along X (length) x Y (width) x Z (thickness), small bevel. Rotate for walls/pallets."""
    return box((length, width, thickness), pos, rot, bevel, None, mat, name, anchor)


def cyl(radius, depth, verts=24, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.015, segments=None, mat=None,
        name="cyl", anchor="base", radius_top=None):
    """Cylinder along Z standing on pos (radius_top for a tapered/flared one). 24+ verts for anything
    >= 0.3 m, 12-16 for small bits. bevel rounds the cap edges."""
    rt = radius if radius_top is None else radius_top
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=verts, radius1=radius, radius2=rt,
                          depth=depth)
    if anchor == "base":
        bmesh.ops.translate(bm, vec=(0, 0, depth / 2), verts=bm.verts)
    obj = _link(name, bm, mat, pos, rot, smooth=40.0)
    if bevel and bevel > 0:
        globals()["bevel"](obj, min(bevel, depth * 0.49, min(radius, rt) * 0.9), segments)
    return obj


def cone(radius, depth, verts=24, pos=(0, 0, 0), rot=(0, 0, 0), radius_top=0.0, bevel=0.0, mat=None,
         name="cone", anchor="base"):
    return cyl(radius, depth, verts, pos, rot, bevel, None, mat, name, anchor, radius_top=radius_top)


def sphere(radius, pos=(0, 0, 0), rot=(0, 0, 0), scale=(1, 1, 1), segments=24, rings=12, mat=None,
           name="sphere"):
    """UV sphere centred on pos; scale squashes it (baked into the mesh). 24/12 for >= 0.3 m."""
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=rings, radius=radius)
    bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    return _link(name, bm, mat, pos, rot, smooth=180.0)


def _revolve(profile, segments, closed=False):
    """bmesh from a (r, z) profile revolved around Z. r == 0 points become single pole vertices."""
    bm = bmesh.new()
    rings = []
    for r, z in profile:
        if r <= 1e-6:
            rings.append([bm.verts.new((0.0, 0.0, z))])
        else:
            rings.append([bm.verts.new((r * math.cos(2 * math.pi * i / segments),
                                        r * math.sin(2 * math.pi * i / segments), z))
                          for i in range(segments)])
    pairs = list(zip(rings, rings[1:]))
    if closed:
        pairs.append((rings[-1], rings[0]))
    for a, b in pairs:
        for i in range(segments):
            j = (i + 1) % segments
            if len(a) == 1 and len(b) == 1:
                continue
            if len(a) == 1:
                bm.faces.new((a[0], b[i], b[j]))
            elif len(b) == 1:
                bm.faces.new((a[i], b[0], a[j]))
            else:
                bm.faces.new((a[i], b[i], b[j], a[j]))
    # Open ends (profile not touching the axis) get flat caps.
    if not closed:
        for ring, top in ((rings[0], False), (rings[-1], True)):
            if len(ring) > 2:
                bm.faces.new(ring if top else list(reversed(ring)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return bm


def lathe(profile, verts=24, pos=(0, 0, 0), rot=(0, 0, 0), mat=None, name="lathe", smooth=40.0, closed=False):
    """Revolve a (radius, z) profile around Z (bottom to top). Start/end at radius 0 for closed poles,
    otherwise the ends get flat caps. closed=True joins the last point back to the first (a shell with
    thickness: lamp shades, buckets, pipes' flanges; then no caps). Profile corners sharper than `smooth`
    degrees stay hard. Great for drums, jars, pots, lamp shades, bodies, bottles."""
    return _link(name, _revolve(profile, verts, closed), mat, pos, rot, smooth=smooth)


def capsule(radius, height, pos=(0, 0, 0), rot=(0, 0, 0), verts=24, rings=8, mat=None, name="capsule",
            anchor="base", scale=(1, 1, 1)):
    """Capsule along Z, total height like Godot's CapsuleMesh (>= 2 * radius), standing on pos."""
    height = max(height, 2 * radius)
    half = rings // 2
    prof = []
    for k in range(half + 1):  # bottom hemisphere: pole -> equator
        a = -math.pi / 2 + (math.pi / 2) * k / half
        prof.append((radius * math.cos(a), radius + radius * math.sin(a)))
    for k in range(half + 1):  # top hemisphere: equator -> pole
        a = (math.pi / 2) * k / half
        prof.append((radius * math.cos(a), height - radius + radius * math.sin(a)))
    prof[0] = (0.0, 0.0)
    prof[-1] = (0.0, height)
    bm = _revolve(prof, verts)
    if anchor == "center":
        bmesh.ops.translate(bm, vec=(0, 0, -height / 2), verts=bm.verts)
    bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    return _link(name, bm, mat, pos, rot, smooth=180.0)


def torus(major, minor, pos=(0, 0, 0), rot=(0, 0, 0), major_segments=32, minor_segments=12, mat=None,
          name="torus", scale=(1, 1, 1)):
    """Ring around Z centred on pos (major = ring radius, minor = tube radius). Rims, hoops, handles."""
    bm = bmesh.new()
    grid = []
    for i in range(major_segments):
        u = 2 * math.pi * i / major_segments
        row = []
        for j in range(minor_segments):
            v = 2 * math.pi * j / minor_segments
            r = major + minor * math.cos(v)
            row.append(bm.verts.new((r * math.cos(u), r * math.sin(u), minor * math.sin(v))))
        grid.append(row)
    for i in range(major_segments):
        for j in range(minor_segments):
            a, b = grid[i][j], grid[(i + 1) % major_segments][j]
            c, d = grid[(i + 1) % major_segments][(j + 1) % minor_segments], grid[i][(j + 1) % minor_segments]
            bm.faces.new((a, b, c, d))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bmesh.ops.scale(bm, vec=scale, verts=bm.verts)
    return _link(name, bm, mat, pos, rot, smooth=180.0)


def _fillet(points, bend, steps=4):
    if bend <= 0 or len(points) < 3:
        return [Vector(p) for p in points]
    pts = [Vector(p) for p in points]
    out = [pts[0]]
    for i in range(1, len(pts) - 1):
        p0, p, p1 = pts[i - 1], pts[i], pts[i + 1]
        din, dout = (p - p0), (p1 - p)
        if din.length < 1e-6 or dout.length < 1e-6 or din.normalized().dot(dout.normalized()) > 0.999:
            out.append(p)
            continue
        r = min(bend, din.length * 0.45, dout.length * 0.45)
        a, b = p - din.normalized() * r, p + dout.normalized() * r
        for s in range(steps + 1):
            t = s / steps
            out.append((1 - t) ** 2 * a + 2 * (1 - t) * t * p + t ** 2 * b)
    out.append(pts[-1])
    return out


def pipe(points, radius, pos=(0, 0, 0), rot=(0, 0, 0), verts=12, bend=None, caps=True, mat=None,
         name="pipe"):
    """Tube through 3D points (a poly path), corners rounded with radius `bend` (default 2.5 x radius).
    Pipes, cords, cables, handles, rails, chain-link frames. Use sag_points() for hanging cables."""
    bend = radius * 2.5 if bend is None else bend
    path = _fillet(points, bend)
    cu = bpy.data.curves.new(name + "_curve", 'CURVE')
    cu.dimensions = '3D'
    cu.resolution_u = 1
    cu.bevel_depth = radius
    cu.bevel_resolution = max(1, verts // 4 - 1)
    cu.use_fill_caps = caps
    sp = cu.splines.new('POLY')
    sp.points.add(len(path) - 1)
    for i, p in enumerate(path):
        sp.points[i].co = (p.x, p.y, p.z, 1.0)
    tmp = bpy.data.objects.new(name + "_tmp", cu)
    bpy.context.scene.collection.objects.link(tmp)
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(tmp.evaluated_get(dg))
    bpy.data.objects.remove(tmp)
    bpy.data.curves.remove(cu)
    bm = bmesh.new()
    bm.from_mesh(me)
    bpy.data.meshes.remove(me)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    return _link(name, bm, mat, pos, rot, smooth=50.0)


def sag_points(a, b, sag=0.1, n=10):
    """Points of a cable hanging between a and b, dipping `sag` metres in the middle (for pipe())."""
    a, b = Vector(a), Vector(b)
    return [a.lerp(b, t) - Vector((0, 0, sag * 4 * t * (1 - t))) for t in (i / n for i in range(n + 1))]


def extrude_profile(points, depth, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.01, segments=None, mat=None,
                    name="profile"):
    """A flat polygon given as (u, v) points the way you SEE it looking at the model's front (u to your
    right = +X, v up = +Z), extruded towards the front (-Y) by `depth`: back face at y = pos.y (put it on
    the surface), front face at pos.y - depth. Signs, brackets, arrows, door leaves, stencils."""
    bm = bmesh.new()
    vs = [bm.verts.new((u, 0.0, v)) for u, v in points]
    face = bm.faces.new(vs)
    bmesh.ops.recalc_face_normals(bm, faces=[face])
    ret = bmesh.ops.extrude_face_region(bm, geom=[face])
    moved = [e for e in ret["geom"] if isinstance(e, bmesh.types.BMVert)]
    bmesh.ops.translate(bm, vec=(0, -depth, 0), verts=moved)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    obj = _link(name, bm, mat, pos, rot, smooth=35.0)
    if bevel and bevel > 0:
        globals()["bevel"](obj, min(bevel, depth * 0.45), segments)
    return obj


def arc_panel(radius, height, angle=40.0, thickness=0.008, pos=(0, 0, 0), rot=(0, 0, 0), segments=8,
              mat=None, name="panel"):
    """A curved plate hugging a cylinder of `radius` around Z (inner face on the surface), `angle` degrees
    wide, centred on the FRONT (-Y) side, bottom at pos.z. Labels, rust patches, bands, hatches on drums,
    tanks, pipes. Use rot=(0, 0, a) to move it around the cylinder (a > 0 turns it towards +X)."""
    bm = bmesh.new()
    rows = []
    for rr in (radius, radius + thickness):
        ring = []
        for i in range(segments + 1):
            a = math.radians(-angle / 2 + angle * i / segments)
            ring.append((bm.verts.new((rr * math.sin(a), -rr * math.cos(a), 0.0)),
                         bm.verts.new((rr * math.sin(a), -rr * math.cos(a), height))))
        rows.append(ring)
    inner, outer = rows
    for i in range(segments):
        bm.faces.new((outer[i][0], outer[i + 1][0], outer[i + 1][1], outer[i][1]))
        bm.faces.new((inner[i][1], inner[i + 1][1], inner[i + 1][0], inner[i][0]))
        bm.faces.new((inner[i][0], inner[i + 1][0], outer[i + 1][0], outer[i][0]))
        bm.faces.new((outer[i][1], outer[i + 1][1], inner[i + 1][1], inner[i][1]))
    for i in (0, segments):
        bm.faces.new((inner[i][0], outer[i][0], outer[i][1], inner[i][1]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _link(name, bm, mat, pos, rot, smooth=40.0)


def band(radius, z0, z1, thickness=0.004, verts=24, rows=1, top=None, bottom=None, pos=(0, 0, 0),
         rot=(0, 0, 0), mat=None, name="band"):
    """A thin ring hugging a round body between heights z0..z1: paint stripes, rust creeping up from the
    floor, dirt/water lines. `radius` is a number or a function r(z) (pass the body's own profile so the
    band follows bellies/tapers). `top` / `bottom` are optional functions of the angle a (radians,
    0 = the front (-Y), pi/2 = +X) returning a z offset: wavy rust edges, drips. `rows` > 1 adds
    rows so the band can follow curvature or take a dent(). Smooth edges, unlike paint() on faces."""
    rf = radius if callable(radius) else (lambda z, _r=radius: _r)
    bm = bmesh.new()
    grid_out, grid_in = [], []
    for i in range(verts):
        a = 2 * math.pi * i / verts
        zb = z0 + (bottom(a) if bottom else 0.0)
        zt = z1 + (top(a) if top else 0.0)
        col_o, col_i = [], []
        for k in range(rows + 1):
            z = zb + (zt - zb) * k / rows
            r = rf(z)
            sx, sy = math.sin(a), -math.cos(a)
            col_o.append(bm.verts.new(((r + thickness) * sx, (r + thickness) * sy, z)))
            col_i.append(bm.verts.new(((r - thickness) * sx, (r - thickness) * sy, z)))
        grid_out.append(col_o)
        grid_in.append(col_i)
    for i in range(verts):
        j = (i + 1) % verts
        for k in range(rows):
            bm.faces.new((grid_out[i][k], grid_out[j][k], grid_out[j][k + 1], grid_out[i][k + 1]))
            bm.faces.new((grid_in[i][k + 1], grid_in[j][k + 1], grid_in[j][k], grid_in[i][k]))
        bm.faces.new((grid_in[i][rows], grid_out[i][rows], grid_out[j][rows], grid_in[j][rows]))
        bm.faces.new((grid_in[j][0], grid_out[j][0], grid_out[i][0], grid_in[i][0]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return _link(name, bm, mat, pos, rot, smooth=50.0)


# ==================================================================================== modifiers + edits
def _auto_segments(width):
    return 1 if width < 0.006 else 2 if width < 0.02 else 3


def bevel(obj, width=0.02, segments=None, angle=35.0):
    """Rounds edges sharper than `angle` degrees (live modifier; re-calling replaces it).
    segments=None picks by size: 1 below 6 mm, 2 below 2 cm, else 3 (small bevels don't need more)."""
    segments = _auto_segments(width) if segments is None else segments
    mod = obj.modifiers.get("gwf_bevel") or obj.modifiers.new("gwf_bevel", 'BEVEL')
    mod.width = width
    mod.segments = segments
    mod.limit_method = 'ANGLE'
    mod.angle_limit = math.radians(angle)
    mod.profile = 0.5
    mod.use_clamp_overlap = True
    mod.harden_normals = False
    return obj


def subdiv(obj, levels=2):
    """Catmull-Clark subdivision (live modifier) for pillowy, blobby shapes. Each level x4 the tris."""
    mod = obj.modifiers.get("gwf_subdiv") or obj.modifiers.new("gwf_subdiv", 'SUBSURF')
    mod.levels = levels
    mod.render_levels = levels
    mod.subdivision_type = 'CATMULL_CLARK'
    obj["gwf_smooth"] = 180.0
    return obj


def _to_top(obj, mod):
    idx = list(obj.modifiers).index(mod)
    if idx != 0:
        obj.modifiers.move(idx, 0)


def mirror(obj, axis="X", merge=0.001):
    """Mirror across the object's local axis plane (live modifier, applied BEFORE bevel/subdiv)."""
    mod = obj.modifiers.new("gwf_mirror", 'MIRROR')
    mod.use_axis = [a in axis.upper() for a in "XYZ"]
    mod.use_mirror_merge = True
    mod.merge_threshold = merge
    _to_top(obj, mod)
    return obj


def array(obj, count, offset=(1, 0, 0)):
    """`count` copies spaced by `offset` metres (live modifier, applied BEFORE bevel/subdiv)."""
    mod = obj.modifiers.new("gwf_array", 'ARRAY')
    mod.count = count
    mod.use_relative_offset = False
    mod.use_constant_offset = True
    mod.constant_offset_displace = offset
    mod.use_merge_vertices = False
    _to_top(obj, mod)
    return obj


def _apply_first(obj):
    """Apply only the first modifier of the stack (keeps the others live)."""
    others = list(obj.modifiers)[1:]
    states = [m.show_viewport for m in others]
    for m in others:
        m.show_viewport = False
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(obj.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
    for m, s in zip(others, states):
        m.show_viewport = s
    _swap_mesh(obj, me)
    obj.modifiers.remove(obj.modifiers[0])


def _swap_mesh(obj, me):
    """Give obj the mesh `me`, keeping the old mesh's name (no ".001": mesh names reach Godot)."""
    old = obj.data
    name = old.name
    obj.data = me
    if old.users == 0:
        bpy.data.meshes.remove(old)
    me.name = name


def boolean_cut(obj, cutter, keep_cutter=False):
    """Carve `cutter` out of `obj` (applied now, before obj's bevel so the cut edges get rounded too).
    Keep cutters simple and overlapping cleanly (no coplanar faces)."""
    mod = obj.modifiers.new("gwf_bool", 'BOOLEAN')
    mod.operation = 'DIFFERENCE'
    mod.solver = 'EXACT'
    mod.object = cutter
    _to_top(obj, mod)
    cutter.hide_viewport = False
    _apply_first(obj)
    if not keep_cutter:
        bpy.data.objects.remove(cutter, do_unlink=True)
    return obj


def apply_modifiers(obj):
    """Bake every live modifier into the mesh, then smooth by the object's angle (gwf_smooth)."""
    if obj.type != 'MESH':
        return obj
    if len(obj.modifiers):
        dg = bpy.context.evaluated_depsgraph_get()
        me = bpy.data.meshes.new_from_object(obj.evaluated_get(dg), preserve_all_data_layers=True, depsgraph=dg)
        obj.modifiers.clear()
        _swap_mesh(obj, me)
    set_smooth(obj, obj.get("gwf_smooth", 35.0))
    return obj


def set_smooth(obj, angle=35.0):
    """Smooth shading, with edges sharper than `angle` degrees kept hard (180 = everything smooth).
    Stored on the object and re-applied after modifiers by apply_modifiers()/join()/export()."""
    obj["gwf_smooth"] = float(angle)
    if obj.type != 'MESH' or len(obj.modifiers):
        return obj  # applied later, on the final mesh
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    lim = math.radians(angle)
    for f in bm.faces:
        f.smooth = True
    for e in bm.edges:
        e.smooth = e.is_manifold and (angle >= 180.0 or e.calc_face_angle(0.0) <= lim)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def set_material(obj, mat):
    """Replace every material of obj with `mat` (Material or library name)."""
    m = _resolve_mat(mat)
    obj.data.materials.clear()
    obj.data.materials.append(m)
    for p in obj.data.polygons:
        p.material_index = 0
    return obj


def paint(obj, mat, where):
    """Colour-block faces: every face whose centre/normal (object-local, base mesh before modifiers)
    satisfies where(center, normal) gets `mat`. Two-tone bodies, painted stripes, rust creeping up from
    the floor, the inside of a shade. Returns the number of faces painted."""
    m = _resolve_mat(mat)
    mats = obj.data.materials
    idx = next((i for i, x in enumerate(mats) if x == m), None)
    if idx is None:
        mats.append(m)
        idx = len(mats) - 1
    n = 0
    for p in obj.data.polygons:
        if where(p.center.copy(), p.normal.copy()):
            p.material_index = idx
            n += 1
    return n


def apply_transform(obj):
    """Bake location/rotation/scale into the mesh (origin -> world origin)."""
    if obj.type == 'MESH':
        obj.data.transform(obj.matrix_basis)
    for c in obj.children:
        c.matrix_parent_inverse = obj.matrix_basis @ c.matrix_parent_inverse
    obj.matrix_basis = Matrix.Identity(4)
    bpy.context.view_layer.update()  # matrix_world is stale until the depsgraph runs
    return obj


def join(objs, name="model", origin=(0, 0, 0)):
    """Apply modifiers + smoothing on each object and merge them into one mesh object named `name` whose
    origin is `origin` (world space; default = the world origin = the floor point). Material slots are
    merged, so the result is ONE MeshInstance3D with one surface per material in Godot."""
    objs = [o for o in (objs if isinstance(objs, (list, tuple)) else [objs]) if o is not None]
    for o in objs:
        apply_modifiers(o)
        apply_transform(o)
    target = objs[0]
    if len(objs) > 1:
        with bpy.context.temp_override(active_object=target, object=target, selected_objects=objs,
                                       selected_editable_objects=objs):
            bpy.ops.object.join()
    target.name = name
    target.data.name = name
    set_origin(target, origin)
    _dedupe_materials(target)
    return target


def _dedupe_materials(obj):
    mats = obj.data.materials
    first = {}
    remap = {}
    for i, m in enumerate(mats):
        key = m.name if m else None
        remap[i] = first.setdefault(key, i)
    if all(i == j for i, j in remap.items()):
        return
    for p in obj.data.polygons:
        p.material_index = remap.get(p.material_index, p.material_index)
    keep = sorted(set(remap.values()))
    new_index = {old: k for k, old in enumerate(keep)}
    for p in obj.data.polygons:
        p.material_index = new_index[p.material_index]
    for i in reversed(range(len(mats))):
        if i not in keep:
            mats.pop(index=i)


def duplicate(obj, pos=None, rot=None, name=None):
    """A full copy (own mesh data, same modifiers) optionally moved/rotated (degrees)."""
    new = obj.copy()
    if obj.data is not None:
        new.data = obj.data.copy()
    bpy.context.scene.collection.objects.link(new)
    if pos is not None:
        new.location = Vector(pos)
    if rot is not None:
        new.rotation_euler = _rad(rot)
    if name:
        new.name = name
        if new.data is not None:
            new.data.name = name
    return new


def set_origin(obj, point=(0, 0, 0)):
    """Move the origin to a world-space point without moving the geometry."""
    point = Vector(point)
    bpy.context.view_layer.update()
    if obj.type == 'MESH':
        local = obj.matrix_world.inverted() @ point
        obj.data.transform(Matrix.Translation(-local))
    obj.matrix_world = Matrix.Translation(point) @ Matrix.Translation(-obj.matrix_world.translation) @ obj.matrix_world
    bpy.context.view_layer.update()
    return obj


def set_origin_to_floor(obj):
    """Origin to the bottom centre of the object's bounds (floor props)."""
    lo, hi = _bounds([obj])
    return set_origin(obj, ((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, lo.z))


def set_parent(child, parent):
    """Parent keeping the child's world transform (exports as a Godot child node)."""
    bpy.context.view_layer.update()  # new objects have a stale matrix_world until the depsgraph runs
    mw = child.matrix_world.copy()
    child.parent = parent
    child.matrix_world = mw
    return child


def move_verts(obj, fn):
    """Custom deformation: fn(Vector world-less local co) -> Vector. Applied to the base mesh."""
    for v in obj.data.vertices:
        v.co = fn(v.co.copy())
    obj.data.update()
    return obj


def taper(obj, top_scale=0.85, axis_min=None, axis_max=None):
    """Scale XY linearly along Z from 1 at the bottom to top_scale at the top (flared/tapered bodies)."""
    zs = [v.co.z for v in obj.data.vertices]
    lo = min(zs) if axis_min is None else axis_min
    hi = max(zs) if axis_max is None else axis_max
    span = max(hi - lo, 1e-6)

    def f(co):
        k = 1 + (top_scale - 1) * max(0.0, min(1.0, (co.z - lo) / span))
        return Vector((co.x * k, co.y * k, co.z))
    return move_verts(obj, f)


def subdivide(obj, cuts=4):
    """Split every edge of the base mesh into `cuts` + 1 (grid-filled faces): gives dent(), jitter() and
    taper() vertices to move on boxes and flat panels. Bevels still only round the real edges."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.subdivide_edges(bm, edges=bm.edges[:], cuts=cuts, use_grid_fill=True)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def dent(obj, point, radius=0.12, depth=0.03, direction=None):
    """Push the surface in around `point` (object-local coords) by up to `depth` metres with a smooth
    falloff over `radius`: battered drums, crushed boxes, sagging shades. Direction defaults to towards
    the object's vertical axis. Needs vertices around the spot (lathes have them; subdivide() boxes
    first); works on the base mesh, before the bevel is applied."""
    point = Vector(point)
    if direction is None:
        direction = Vector((-point.x, -point.y, 0.0))
        direction = direction.normalized() if direction.length > 1e-6 else Vector((0, 0, -1))
    direction = Vector(direction).normalized()

    def f(co):
        d = (co - point).length
        if d >= radius:
            return co
        k = (1 - (d / radius) ** 2) ** 2
        return co + direction * depth * k
    return move_verts(obj, f)


def jitter(obj, amount=0.01, seed=1):
    """Deterministic hand-made wobble: nudges every vertex up to `amount` metres (same seed = same result).
    Use sparingly (tired, dented, cheap look) and BEFORE bevel is applied."""
    import random
    rnd = random.Random(seed)
    cache = {}
    for v in obj.data.vertices:
        k = (round(v.co.x, 4), round(v.co.y, 4), round(v.co.z, 4))  # keep welded seams welded
        if k not in cache:
            cache[k] = Vector((rnd.uniform(-1, 1), rnd.uniform(-1, 1), rnd.uniform(-1, 1))) * amount
        v.co += cache[k]
    obj.data.update()
    return obj


def _canonical(obj):
    """Deterministic vertex / edge / face order. Some bmesh ops (create_uvsphere, remove_doubles...) order
    their output differently from run to run, and the glTF exporter writes triangles in face order, so
    without this the same script would produce a different .glb (and a reimport + git churn) every time."""
    if obj.type != 'MESH':
        return
    bm = bmesh.new()
    bm.from_mesh(obj.data)

    def by(seq, key):  # BMesh sort() only takes numeric keys: rank by the tuple key first
        seq.index_update()
        rank = {e.index: i for i, e in enumerate(sorted(seq, key=key))}
        seq.sort(key=lambda e: rank[e.index])
        seq.index_update()
    def r3(c):
        return (round(c.x, 5), round(c.y, 5), round(c.z, 5))
    # Position first; coincident vertices (touching parts of a joined mesh) by their faces' centres.
    by(bm.verts, lambda v: (r3(v.co), tuple(sorted(r3(f.calc_center_median()) for f in v.link_faces))))
    by(bm.edges, lambda e: tuple(sorted(v.index for v in e.verts)))

    def fkey(f):
        return (f.material_index, r3(f.calc_center_median()), tuple(sorted(v.index for v in f.verts)))
    by(bm.faces, fkey)
    bm.to_mesh(obj.data)
    bm.free()
    # Every face starts at its lowest vertex (bevel & co. rotate loops at random; the start decides how a
    # quad is triangulated and the triangle order).
    import numpy as np
    me = obj.data
    vi = np.empty(len(me.loops), np.int32)
    ei = np.empty(len(me.loops), np.int32)
    me.loops.foreach_get("vertex_index", vi)
    me.loops.foreach_get("edge_index", ei)
    starts = np.empty(len(me.polygons), np.int32)
    totals = np.empty(len(me.polygons), np.int32)
    me.polygons.foreach_get("loop_start", starts)
    me.polygons.foreach_get("loop_total", totals)
    for st, tot in zip(starts.tolist(), totals.tolist()):
        k = int(np.argmin(vi[st:st + tot]))
        if k:
            vi[st:st + tot] = np.roll(vi[st:st + tot], -k)
            ei[st:st + tot] = np.roll(ei[st:st + tot], -k)
    me.loops.foreach_set("vertex_index", vi)
    me.loops.foreach_set("edge_index", ei)
    me.update()


# ============================================================================================== reports
def _walk(objs):
    seen = []
    stack = list(objs)
    while stack:
        o = stack.pop(0)
        if o in seen:
            continue
        seen.append(o)
        stack.extend(o.children)
    return seen


def _bounds(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    lo = Vector((1e9, 1e9, 1e9))
    hi = Vector((-1e9, -1e9, -1e9))
    for o in _walk(objs):
        if o.type != 'MESH':
            continue
        ev = o.evaluated_get(dg)
        for c in ev.bound_box:
            w = ev.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    return lo, hi


def _stats(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    tris = 0
    mats = []
    empty_slots = []
    for o in _walk(objs):
        if o.type != 'MESH':
            continue
        ev = o.evaluated_get(dg)
        me = ev.to_mesh()
        me.calc_loop_triangles()
        tris += len(me.loop_triangles)
        used = {p.material_index for p in me.polygons}
        for i in sorted(used):
            m = me.materials[i] if i < len(me.materials) else None
            if m is None:
                empty_slots.append(o.name)
            elif m.name not in mats:
                mats.append(m.name)
        ev.to_mesh_clear()
    lo, hi = _bounds(objs)
    return tris, mats, lo, hi, empty_slots


def report(objs, label=None):
    """Prints and returns bounds (Godot axes: W = x, H = up, D = depth), tri count and materials."""
    objs = objs if isinstance(objs, (list, tuple)) else [objs]
    tris, mats, lo, hi, empty_slots = _stats(objs)
    size = (hi.x - lo.x, hi.z - lo.z, hi.y - lo.y)
    info = {
        "name": label or objs[0].name, "tris": tris, "materials": mats,
        "size": size, "min_z": lo.z, "max_z": hi.z, "min_y": lo.y, "max_y": hi.y,
        "center_xy": ((lo.x + hi.x) / 2, (lo.y + hi.y) / 2), "empty_slots": empty_slots,
        "nodes": [o.name for o in _walk(objs)],
    }
    print("  [%s] %d tris | W %.3f x H %.3f x D %.3f m | z %.3f..%.3f | mats: %s" % (
        info["name"], tris, size[0], size[1], size[2], lo.z, hi.z, ", ".join(mats)))
    return info


# =============================================================================================== export
def _check(info, mount, budget):
    problems, warnings = [], []
    big = max(info["size"])
    if big < 0.05 or big > 6.0:
        problems.append("largest dimension %.2f m is outside 0.05-6 m" % big)
    if info["empty_slots"]:
        problems.append("faces without a material on %s" % ", ".join(sorted(set(info["empty_slots"]))))
    for m in info["materials"]:
        if m.startswith("Material") or m.startswith("Dots Stroke"):
            problems.append("default Blender material %r (use lib()/material())" % m)
    tol = 0.006
    if mount == "floor" and abs(info["min_z"]) > tol:
        problems.append("floor mount: lowest point is z=%.3f, must be 0 (origin at the floor)" % info["min_z"])
    if mount == "ceiling" and abs(info["max_z"]) > tol:
        problems.append("ceiling mount: highest point is z=%.3f, must be 0 (origin at the mount)" % info["max_z"])
    if mount == "wall" and abs(info["max_y"]) > tol:
        problems.append("wall mount: back is at y=%.3f, must be 0 (body towards the front, -y)" % info["max_y"])
    if mount == "floor":
        cx, cy = info["center_xy"]
        if math.hypot(cx, cy) > 0.25 * max(info["size"][0], info["size"][2]) + 0.02:
            warnings.append("footprint centre is off the origin (%.2f, %.2f)" % (cx, cy))
    if info["tris"] > budget:
        warnings.append("%d tris over the %d budget" % (info["tris"], budget))
    return problems, warnings


def _turn_around(objs):
    """Rotate a whole hierarchy 180 degrees about the vertical axis through the origin, baked into mesh data
    and node positions: every local matrix is conjugated (R M R^-1), so rotations stay as they were
    (identity stays identity) and only translations / vertices turn. Its own inverse."""
    r = Matrix.Rotation(math.pi, 4, 'Z')
    done = set()
    for o in objs:
        o.matrix_basis = r @ o.matrix_basis @ r
        o.matrix_parent_inverse = r @ o.matrix_parent_inverse @ r
        if o.type == 'MESH' and o.data.name not in done:  # linked duplicates share one mesh
            done.add(o.data.name)
            o.data.transform(r)
            o.data.update()
    bpy.context.view_layer.update()


def export(objs, name, kind="prop", mount="floor", budget=None, import_params=None):
    """Export objs (+ their children) to art/models/<name>.glb. The file is only rewritten when its bytes
    change, so re-running is idempotent and Godot only reimports what changed.
    kind: "prop" | "station" | "part" (front -> Godot +Z) or "character" | "item" (front -> Godot -Z);
    also picks the default tri budget (KINDS). Author every model with its front towards Blender -Y.
    mount: "floor" | "ceiling" | "wall" | "free" (origin check, in Blender space).
    import_params: extra Godot import params for this model (rare)."""
    objs = [o for o in (objs if isinstance(objs, (list, tuple)) else [objs]) if o is not None]
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        raise ValueError("model name %r must be snake_case" % name)
    if kind not in KINDS:
        raise ValueError("kind must be one of %s" % ", ".join(KINDS))
    front, default_budget = KINDS[kind]
    budget = default_budget if budget is None else budget
    t0 = time.time()
    all_objs = _walk(objs)
    for o in all_objs:
        apply_modifiers(o)
        _canonical(o)
    info = report(objs, name)
    problems, warnings = _check(info, mount, budget)
    os.makedirs(MODELS_DIR, exist_ok=True)
    path = os.path.join(MODELS_DIR, name + ".glb")
    changed = False
    if not problems:
        for o in bpy.context.scene.objects:
            o.select_set(False)
        for o in all_objs:
            o.hide_set(False)
            o.select_set(True)
        fd, tmp = tempfile.mkstemp(suffix=".glb")
        os.close(fd)
        turned = front == "-z"
        if turned:
            _turn_around(all_objs)
        try:
            with _quiet():
                bpy.ops.export_scene.gltf(
                    filepath=tmp, export_format='GLB', use_selection=True, export_apply=True, export_yup=True,
                    export_texcoords=False, export_normals=True, export_tangents=False,
                    export_materials='EXPORT', export_image_format='NONE', export_cameras=False,
                    export_lights=False, export_animations=False, export_skins=False, export_morph=False,
                    export_extras=False, will_save_settings=False)
            data = open(tmp, "rb").read()
        finally:
            os.remove(tmp)
            if turned:
                _turn_around(all_objs)  # back to the authoring orientation (front -Y)
        old = open(path, "rb").read() if os.path.exists(path) else None
        if old != data:
            with open(path, "wb") as f:
                f.write(data)
            changed = True
    rec = dict(info, path=path, kind=kind, front=front, mount=mount, budget=budget, problems=problems, warnings=warnings,
               changed=changed, import_params=dict(import_params or {}), seconds=time.time() - t0)
    EXPORTS.append(rec)
    for p in problems:
        print("  FAIL %s: %s" % (name, p))
    for w in warnings:
        print("  WARN %s: %s" % (name, w))
    if OPTIONS.get("preview") and not problems:
        rec["preview"] = _preview(objs, name)
    return rec


# ============================================================================================== preview
def _preview(objs, name, size=256, samples=12):
    """Cycles CPU turntable strip (4 views, front-right first) -> OPTIONS['preview_dir']/<name>.png.
    Measured ~0.15-0.9 s per view at 256 px / 12 samples (0.5-1.5 s per model, + ~4-5 s Cycles warm-up on
    the first preview of a run); if the first two views take > 10 s it stops there (budget 20 s).
    For the real in-game look use tools/tests/models_preview.gd."""
    t0 = time.time()
    scene = bpy.context.scene
    lo, hi = _bounds(objs)
    center = (lo + hi) / 2
    radius = max((hi - lo).length / 2, 0.05)
    added = []
    cam_data = bpy.data.cameras.new("gwf_cam")
    cam_data.angle = math.radians(30)
    cam = bpy.data.objects.new("gwf_cam", cam_data)
    scene.collection.objects.link(cam)
    added.append(cam)
    sun_data = bpy.data.lights.new("gwf_sun", 'SUN')
    sun_data.energy = 2.2
    sun_data.color = srgb("#d4deeb")[:3]
    sun_data.angle = math.radians(8)
    sun = bpy.data.objects.new("gwf_sun", sun_data)
    sun.rotation_euler = Euler((math.radians(55), 0, math.radians(-140)), 'XYZ')
    scene.collection.objects.link(sun)
    added.append(sun)
    world = bpy.data.worlds.new("gwf_world")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = srgb("#56606e")
    world.node_tree.nodes["Background"].inputs[1].default_value = 1.0
    old_world = scene.world
    scene.world = world
    scene.camera = cam
    scene.render.engine = 'CYCLES'
    scene.cycles.device = 'CPU'
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 3
    scene.render.resolution_x = size
    scene.render.resolution_y = size
    scene.render.resolution_percentage = 100
    scene.render.image_settings.file_format = 'PNG'
    scene.view_settings.view_transform = 'Standard'
    out_dir = OPTIONS["preview_dir"]
    os.makedirs(out_dir, exist_ok=True)
    tiles = []
    try:
        import numpy as np
        for i, yaw in enumerate((35, 125, 215, 305)):
            a = math.radians(yaw)
            d = Vector((math.sin(a) * math.cos(math.radians(22)), -math.cos(a) * math.cos(math.radians(22)),
                        math.sin(math.radians(22))))  # yaw 0 = in front (-Y side)
            dist = radius / math.sin(cam_data.angle / 2) * 1.1
            cam.location = center + d * dist
            cam.rotation_euler = (center - cam.location).to_track_quat('-Z', 'Y').to_euler()
            cam_data.clip_start = max(0.01, dist - radius * 3)
            cam_data.clip_end = dist + radius * 3
            tmp = os.path.join(out_dir, "_%s_%d.png" % (name, i))
            scene.render.filepath = tmp
            with _quiet():
                bpy.ops.render.render(write_still=True)
            img = bpy.data.images.load(tmp)
            px = np.empty(size * size * 4, dtype=np.float32)
            img.pixels.foreach_get(px)
            tiles.append(px.reshape(size, size, 4))
            bpy.data.images.remove(img)
            os.remove(tmp)
            if i == 1 and time.time() - t0 > 10.0:  # 4 views would pass 20 s: keep these two
                print("  preview %s: slow (%.1f s for 2 views), stopping" % (name, time.time() - t0))
                break
        strip = np.concatenate(tiles, axis=1)
        out = bpy.data.images.new("gwf_strip", width=size * len(tiles), height=size, alpha=True)
        out.pixels.foreach_set(strip.ravel())
        path = os.path.join(out_dir, name + ".png")
        out.filepath_raw = path
        out.file_format = 'PNG'
        out.save()
        bpy.data.images.remove(out)
    finally:
        for o in added:
            data = o.data
            bpy.data.objects.remove(o, do_unlink=True)
            if isinstance(data, bpy.types.Camera):
                bpy.data.cameras.remove(data)
            elif isinstance(data, bpy.types.Light):
                bpy.data.lights.remove(data)
        scene.world = old_world
        bpy.data.worlds.remove(world)
    print("  preview %s (%.1f s)" % (path, time.time() - t0))
    return path
