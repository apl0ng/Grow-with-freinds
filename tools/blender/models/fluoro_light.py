"""fluoro_light family: cheap hanging fluorescent fixtures (room decor, environment modeler).

scenes/world/props/fluoro_light.tscn (+ fluoro_light_broken.tscn) instance these AS `Visual`, so the flicker
script's `Visual/Tubes` path stays valid (flicker_light.gd toggles its visibility). The OmniLight stays in the
scene just under the tubes (y -1.98). Ceiling mount: origin = ceiling, everything below.
  fluoro_light         1.52 x 1.88 x 0.35 m: two ceiling hooks, two chains, a channel body with angled
                       reflector wings (faintly lit inside), end plates, lamp holders, a sagging power cord.
  fluoro_light_broken  same fixture hanging crooked (right chain longer), the front tube has dropped out of
                       its right holder and dangles 40 degrees down from the left one; a torn wire hangs from
                       the empty holder. Use it for the flickering one.
Nodes in Godot:  <root, Toonify> / Fixture (hooks + chains + housing: one mesh)
                                 / Tubes   (both tubes, toon_neon_green: the part that flickers)
"""
import bpy
import bmesh
from gwf import *

L = 1.46            # housing length
TOP = -1.70         # housing top (chain attach)
TUBE_Z = -1.832     # tube axis
TUBE_Y = 0.066      # tubes at y +-0.066
TUBE_R = 0.03
CHAIN_X = 0.55


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


def chain(points, pitch=0.095, width=0.058, r=0.009, name="chain", mat="metal_dark", n0=(0, -1, 0), sides=3):
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


def extrude_x(name, profile, x0, x1, mat, cuts=0):
    """A closed (y, z) polygon extruded along X from x0 to x1 (with `cuts` loop cuts), capped."""
    bm = bmesh.new()
    n = cuts + 2
    rings = [[bm.verts.new((x0 + (x1 - x0) * i / (n - 1), y, z)) for y, z in profile] for i in range(n)]
    m = len(profile)
    for a, b in zip(rings, rings[1:]):
        for j in range(m):
            bm.faces.new((a[j], a[(j + 1) % m], b[(j + 1) % m], b[j]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth=30.0)


def housing(reflector):
    """Channel body on top + reflector wings flaring down and out (y, z profile, one closed shell)."""
    prof = [(-0.07, TOP), (0.07, TOP), (0.07, TOP - 0.062), (0.176, TOP - 0.14), (0.168, TOP - 0.152),
            (0.056, TOP - 0.078), (-0.056, TOP - 0.078), (-0.168, TOP - 0.152), (-0.176, TOP - 0.14),
            (-0.07, TOP - 0.062)]
    body = extrude_x("housing", prof, -L / 2, L / 2, "metal_dark", cuts=3)
    bevel(body, 0.008, segments=1)
    # The inside of the wings and the underside of the channel catch the tubes' light.
    paint(body, reflector, lambda c, n: n.z < -0.3 and abs(c.x) < L / 2 - 0.001 and c.z < TOP - 0.06)
    dent(body, (0.3, -0.13, TOP - 0.11), radius=0.16, depth=0.02, direction=(0.0, 0.5, 0.6))
    parts = [body]
    for sx in (-1, 1):
        # lamp holders ("tombstones") under the channel at each end, with the tube pins
        for sy in (-1, 1):
            parts.append(box((0.04, 0.05, 0.08), pos=(sx * (L / 2 - 0.035), sy * TUBE_Y, TOP - 0.078 - 0.075),
                             bevel=0.005, mat="white", name="holder"))
        # eye bolt on the top for the chain
        parts.append(torus(0.022, 0.007, pos=(sx * CHAIN_X, 0, TOP + 0.022), rot=(90, 0, 0), major_segments=8,
                           minor_segments=4, mat="metal_dark", name="eye"))
    return parts


def tube(x0, x1, name="tube"):
    """One fluorescent tube along X (glass capsule) with its end caps."""
    glass = capsule(TUBE_R, x1 - x0, pos=(x0, TUBE_Y, TUBE_Z), rot=(0, 90, 0), verts=12, rings=4, mat="neon_green",
                    name=name)
    return glass


def ceiling_bits(xs):
    out = []
    for x in xs:
        out.append(cyl(0.055, 0.016, verts=12, pos=(x, 0, -0.016), bevel=0.004, mat="metal_dark", name="rose"))
        out.append(torus(0.02, 0.006, pos=(x, 0, -0.038), rot=(90, 0, 0), major_segments=8, minor_segments=4,
                         mat="metal_dark", name="hook"))
    return out


def fixture(name, broken):
    reset()
    reflector = material("reflector", "#cbd3c9", "glow", emission=0.3)
    parts = housing(reflector)
    # Power cord: out of the right end of the channel, a lazy loop up to the ceiling.
    parts.append(pipe([(L / 2 - 0.06, 0.03, TOP + 0.01), (L / 2 + 0.05, 0.04, TOP - 0.02), (L / 2 + 0.16, 0.05, TOP - 0.14),
                       (L / 2 + 0.26, 0.05, TOP - 0.06), (L / 2 + 0.24, 0.05, TOP + 0.4), (CHAIN_X + 0.2, 0.05, -0.6),
                       (CHAIN_X + 0.18, 0.04, -0.03)], 0.01, verts=6, bend=0.09, mat="dark", name="cord"))
    tubes = [tube(-L / 2 + 0.05, L / 2 - 0.05, "tube_a"), tube(-L / 2 + 0.05, L / 2 - 0.05, "tube_b")]
    tubes[0].location.y = -TUBE_Y          # tube_a moves to the front row (y = -0.066); tube_b stays at the back
    tilt, pivot = 0.0, Vector((-CHAIN_X, 0, TOP))
    if broken:
        tilt = math.radians(2.6)           # right end hangs lower: the right chain was re-hung a link too long
        # The front tube dropped out of its right holder: it hangs from the left pins, swung 40 deg down.
        drop = Matrix.Translation((-L / 2 + 0.05, 0, TUBE_Z)) @ Matrix.Rotation(math.radians(-7), 4, 'Z') \
            @ Matrix.Rotation(math.radians(40), 4, 'Y') @ Matrix.Translation((L / 2 - 0.05, 0, -TUBE_Z))
        apply_transform(tubes[0])
        tubes[0].data.transform(drop)
        # A torn wire from the empty right holder.
        parts.append(pipe([(L / 2 - 0.035, -TUBE_Y, TOP - 0.2), (L / 2 - 0.05, -TUBE_Y - 0.01, TOP - 0.28),
                           (L / 2 - 0.09, -TUBE_Y - 0.025, TOP - 0.33)], 0.006, verts=6, bend=0.03, mat="dark",
                          name="wire"))
    body_parts = parts
    rot = Matrix.Translation(pivot) @ Matrix.Rotation(tilt, 4, 'Y') @ Matrix.Translation(-pivot)
    for o in body_parts + tubes:
        apply_transform(o)
        o.data.transform(rot)
    # Chains from the ceiling hooks to the (possibly tilted) eye bolts.
    chains = []
    for sx in (-1, 1):
        eye = rot @ Vector((sx * CHAIN_X, 0, TOP + 0.03))
        chains.append(chain([(sx * CHAIN_X, 0, -0.045), (eye.x, 0, eye.z)], name="chain"))
    body = join(body_parts + chains + ceiling_bits((-CHAIN_X, CHAIN_X)), "Fixture")
    t = join(tubes, "Tubes", origin=tuple(rot @ Vector((0, 0, TUBE_Z))))
    export([body, t], name, kind="prop", mount="ceiling")


def build():
    fixture("fluoro_light", broken=False)
    fixture("fluoro_light_broken", broken=True)
