"""grow_light_bar: one 3.7 m half of the grow area's 7.4 m grow-light bar (room decor, environment modeler).

scenes/world/props/grow_light.tscn hangs two of these back to back (the second turned 180 degrees about Y), so
the bar runs along Godot Z like the placeholder. Mount "free": the ORIGIN is the bar's centre (the coupler
end of this half) on the hood's axis, at the height the scene root sits (3.2 m in the room); the half runs
towards Blender -Y (Godot +Z) to its end cap at 3.7 m, and its chain rises 2.8 m to the ceiling at 3.0 m.
  Housing   dented sheet-metal hood (lit reflector inside), lamp holders, end cap with bolts, coupler plate,
            junction box and a lazy power cord up to the ceiling, eye bolt + chain + ceiling plate. The half
            hangs 1.5 degrees down towards the middle (the two halves sag into a shallow V).
  Tube      the two warm glowing tubes: its own node so a script / light can flicker or dim it.
"""
import bpy
import bmesh
from gwf import *

LEN = 3.7
CHAIN_Y = -3.0       # chain position along the bar (Godot z = 3.0 like the placeholder cables)
CEIL = 2.8           # ceiling above the bar axis
SAG = -1.5           # degrees about X through the chain's eye: the coupler end dips ~8 cm
HOOD_TOP = 0.085


def mesh_obj(name, bm, mat, smooth=35.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    if mat is not None:
        me.materials.append(lib(mat) if isinstance(mat, str) else mat)
    return obj


def chain(points, pitch=0.1, width=0.064, r=0.011, name="chain", mat="metal_dark", n0=(1, 0, 0), sides=3):
    """Interlocking links (6-sided stadium rings, `sides`-sided wire) resampled along a polyline."""
    pts = [Vector(p) for p in points]
    seg = [(a, b, (b - a).length) for a, b in zip(pts, pts[1:])]
    total = sum(l for _, _, l in seg)
    n = max(1, int(total / pitch))
    step = total / n

    def at(s):
        for a, b, l in seg:
            if s <= l or (a, b, l) == seg[-1]:
                return a.lerp(b, min(1.0, s / l) if l > 0 else 0.0)
            s -= l
    bm = bmesh.new()
    a_end = width / 2 - r
    s_half = max(0.0, step / 2 + r - a_end)
    ref = Vector(n0)
    for k in range(n):
        p, q = at(k * step), at((k + 1) * step)
        c, t = (p + q) / 2, (q - p).normalized()
        nn = (ref - t * ref.dot(t))
        nn = nn.normalized() if nn.length > 1e-4 else t.orthogonal().normalized()
        if k % 2:
            nn = t.cross(nn).normalized()
        b = nn.cross(t)
        cl = [(s_half, -a_end), (s_half + a_end, 0), (s_half, a_end), (-s_half, a_end), (-s_half - a_end, 0),
              (-s_half, -a_end)]
        cl = [c + t * u + b * v for u, v in cl]
        rings = []
        for i, pnt in enumerate(cl):
            tan = (cl[(i + 1) % 6] - cl[i - 1]).normalized()
            out = tan.cross(nn).normalized()
            if out.dot(pnt - c) < 0:
                out = -out
            rings.append([bm.verts.new(pnt + out * r * math.cos(j * 2 * math.pi / sides)
                                       + nn * r * math.sin(j * 2 * math.pi / sides)) for j in range(sides)])
        for i in range(6):
            ra, rb = rings[i], rings[(i + 1) % 6]
            for j in range(sides):
                bm.faces.new((ra[j], rb[j], rb[(j + 1) % sides], ra[(j + 1) % sides]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth=60.0)


def extrude_y(name, profile, y0, y1, mat, cuts=0):
    """A closed (x, z) polygon extruded along Y from y0 to y1 (with `cuts` loop cuts), capped."""
    bm = bmesh.new()
    n = cuts + 2
    rings = [[bm.verts.new((x, y0 + (y1 - y0) * i / (n - 1), z)) for x, z in profile] for i in range(n)]
    m = len(profile)
    for a, b in zip(rings, rings[1:]):
        for j in range(m):
            bm.faces.new((a[j], a[(j + 1) % m], b[(j + 1) % m], b[j]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth=30.0)


OUTER = [(-0.185, -0.11), (-0.185, -0.02), (-0.15, 0.055), (-0.09, HOOD_TOP), (0.09, HOOD_TOP), (0.15, 0.055),
         (0.185, -0.02), (0.185, -0.11)]
INNER = [(0.171, -0.11), (0.171, -0.025), (0.138, 0.042), (0.083, 0.071), (-0.083, 0.071), (-0.138, 0.042),
         (-0.171, -0.025), (-0.171, -0.11)]


def plate(name, y0, depth, grow=0.012):
    """An end plate / coupler in the hood's outline (a little proud of it), `depth` towards -Y."""
    pts = [(x * (1 + grow / 0.185), z + (grow if z > 0 else -grow * 0.5)) for x, z in OUTER]
    p = extrude_y(name, pts, y0, y0 - depth, "metal_dark")
    bevel(p, 0.008, segments=1)
    return p


def build():
    reflector = material("grow_reflector", "#d9ccb0", "glow", emission=0.35)
    glow = material("grow_tube", "#f2c77f", "glow", emission=1.2)

    hood = extrude_y("hood", OUTER + INNER, -0.04, -LEN + 0.04, "metal_dark", cuts=6)
    paint(hood, reflector, lambda c, n: (n.x * c.x + n.z * (c.z - 0.0)) < -0.01 and c.z > -0.108)
    dent(hood, (0.16, -1.25, 0.03), radius=0.3, depth=0.03, direction=(-1, 0, -0.3))
    dent(hood, (-0.1, -2.55, HOOD_TOP), radius=0.26, depth=0.022, direction=(0, 0, -1))
    bevel(hood, 0.006, segments=1)
    parts = [hood, plate("coupler", 0.0, 0.04), plate("end_cap", -LEN + 0.04, 0.04, grow=0.016)]
    for sx in (-1, 1):
        parts.append(cyl(0.02, 0.02, verts=6, pos=(sx * 0.1, -LEN, 0.0), rot=(90, 0, 0), bevel=0, mat="metal_dark",
                         name="cap_bolt"))
    # Lamp holders at both tube ends.
    for y in (-0.06, -LEN + 0.06):
        for sx in (-1, 1):
            parts.append(box((0.05, 0.05, 0.07), pos=(sx * 0.06, y, -0.04), bevel=0.005, mat="white", name="holder"))
    # Junction box on the coupler, power cord looping up to the ceiling.
    parts.append(box((0.15, 0.12, 0.08), pos=(0.0, -0.075, HOOD_TOP - 0.01), bevel=0.012, mat="metal_dark",
                     name="junction"))
    parts.append(pipe([(0.05, -0.1, HOOD_TOP + 0.06), (0.06, -0.25, HOOD_TOP + 0.03), (0.07, -0.5, HOOD_TOP + 0.12),
                       (0.07, -0.62, 0.9), (0.06, -0.58, 1.9), (0.05, -0.5, CEIL - 0.02)], 0.013, verts=6, bend=0.14,
                      mat="dark", name="cord"))
    # Eye bolt on the hood top where the chain hangs.
    parts.append(torus(0.028, 0.009, pos=(0, CHAIN_Y, HOOD_TOP + 0.03), rot=(0, 90, 0), major_segments=8,
                       minor_segments=4, mat="metal_dark", name="eye"))
    parts.append(cyl(0.05, 0.015, verts=12, pos=(0, CHAIN_Y, HOOD_TOP - 0.004), bevel=0, mat="metal_dark",
                     name="eye_plate"))
    tubes = [capsule(0.028, LEN - 0.2, pos=(sx * 0.06, -0.1, -0.045), rot=(90, 0, 0), verts=12, rings=4, mat=glow,
                     name="tube") for sx in (-1, 1)]
    # The half hangs from its chain and dips towards the middle of the bar.
    pivot = Vector((0, CHAIN_Y, HOOD_TOP + 0.03))
    sag = Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(SAG), 4, 'X') @ Matrix.Translation(-pivot)
    for o in parts + tubes:
        apply_transform(o)
        o.data.transform(sag)
    # Chain (vertical, from the eye to the ceiling plate) + ceiling plate: not tilted.
    top = pivot + Vector((0, 0, 0.03))
    parts.append(chain([top, (0, CHAIN_Y, CEIL - 0.03)], name="chain"))
    parts.append(cyl(0.065, 0.02, verts=12, pos=(0, CHAIN_Y, CEIL - 0.02), bevel=0.005, mat="metal_dark",
                     name="ceiling_plate"))
    housing = join(parts, "Housing")
    tube = join(tubes, "Tube", origin=(0, -LEN / 2, -0.045))
    export([housing, tube], "grow_light_bar", kind="prop", mount="free")
