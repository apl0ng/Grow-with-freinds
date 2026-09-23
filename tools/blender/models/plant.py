"""plant: the cannabis plant across its growth stages (PLAN 8.7, the dedicated plant pass).

Real-world morphology, chunky cartoon output. kind "part" (front = Blender -Y -> Godot +Z, like the plot), floor
mount: the origin is where the stem enters the soil (scenes/stations/grow_plot.tscn puts PlantVisual at the soil
top, y 0.49). Instanced by scenes/stations/plant_visual.tscn (driven by scripts/stations/plant_visual.gd):

  plant_seedling (+ _dry)    ~0.25 m. Hypocotyl, two round smooth cotyledons, the first pair of single-blade
                             serrated true leaves, the second pair with three fingers (decussate: each pair turned
                             90 degrees), a tiny tuft of new growth on top. Bright soft green (lime).
  plant_vegetative (+ _dry)  ~0.65 m. Main stem with swollen nodes, opposite decussate leaf pairs, palmate fan
                             leaves (3 fingers low, 5-7 serrated fingers above, middle finger longest, lower
                             fingers swept back), side shoots from the lower axils, apical dominance (the central
                             shoot stays tallest), a new-growth tuft on top. Deeper green (leaf).
  plant_flowering (+ _dry)   ~0.9 m. The stretch: long upper internodes, big fan leaves kept low, branches reaching
                             up to bud sites, calyx clusters (TINT) at the apex, the branch tips and the upper
                             axils, cream pistil hairs, small 1-3 finger sugar leaves around the buds.
  plant_ready                ~1.1 m. Harvest: a fat main cola and heavy branch colas (TINT, frosty lighter calyx
                             tips), pistils gone orange-brown (rust), sugar leaves poking out, lower fan leaves
                             yellowing and hanging, branches bowed and the whole plant leaning under the weight.

Nodes (MODELING.md section 8 names):
  Leaves   one mesh: stems, petioles, fan leaves, sugar leaves (library greens, never TINT) and, on the flowering
           stage, nothing strain coloured.
  Buds     flowering: one mesh with the calyx clusters (TINT_bud) + pistils.
           ready: an empty whose children are the colas, ONE MESH PER COLA with its origin at the cola's base
           (ColaTop = main cola + the small colas along the upper stem, Cola1..Cola5 = branch colas), so
           PlantVisual can pulse each cola in place without tearing it off its branch.
The _dry models are the same plants wilted (same seeds): petioles sag, fingers fold and hang, the fan closes,
the soft top of the stem nods over, leaves in leaf_dry. PlantVisual swaps them in while the plot is dry (READY
never dries: it does not drink).

Strain colour: every calyx is TINT_bud (glow finish like toon_bud), the frosty tips of the ready colas
TINT_frost (a lighter shade of the same tint); Toonify recolours them with Toon.grade(seed.color).

Chunky rules: leaflets are closed lens-shaped blades (a raised midrib, rounded edges, never paper thin) with
3-5 big serration teeth per side; stems are tapered tubes with node bulges; colas are one lumpy blob each (calyx
bumps on a golden-angle spiral). Every leaflet of a fan leaf and its petiole meet in ONE vertex position, so
Toonify's outline treats the whole fan leaf as one part (a thin ink line around the palm instead of none).
Budget: 6000 tris per stage (export budget raised from the part default 3000: the plant is the game's
centrepiece and palmate serrated leaves need their vertices; still one draw call per material).
"""
import random

import bmesh
import bpy

from gwf import *

UP = Vector((0.0, 0.0, 1.0))
BUDGET = 6000

# Leaflet outlines: (position along the midrib 0..1, half-width factor).
LANCE = [(0.0, 0.07), (0.1, 0.36), (0.25, 0.8), (0.42, 1.0), (0.58, 0.93), (0.74, 0.68), (0.87, 0.38),
         (0.95, 0.15), (1.0, 0.0)]
OVAL = [(0.0, 0.16), (0.12, 0.58), (0.3, 0.9), (0.52, 1.0), (0.72, 0.95), (0.86, 0.75), (0.95, 0.44), (1.0, 0.0)]

# Palmate fan leaves: (angle from the middle finger in degrees, length factor, teeth per side).
FINGERS = {
    7: [(0, 1.0, 4), (27, 0.86, 4), (-27, 0.86, 4), (56, 0.64, 3), (-56, 0.64, 3), (90, 0.36, 2), (-90, 0.36, 2)],
    5: [(0, 1.0, 4), (31, 0.82, 3), (-31, 0.82, 3), (64, 0.52, 2), (-64, 0.52, 2)],
    3: [(0, 1.0, 3), (36, 0.72, 2), (-36, 0.72, 2)],
    1: [(0, 1.0, 3)],
}


# ============================================================================================ small maths
def table(tab, x):
    """Linear interpolation in a [(x, y), ...] table (clamped)."""
    if x <= tab[0][0]:
        return tab[0][1]
    for (x0, y0), (x1, y1) in zip(tab, tab[1:]):
        if x <= x1:
            return y0 + (y1 - y0) * ((x - x0) / (x1 - x0) if x1 > x0 else 0.0)
    return tab[-1][1]


def horiz(yaw):
    a = math.radians(yaw)
    return Vector((math.cos(a), math.sin(a), 0.0))


def perp(v):
    a = Vector((1.0, 0.0, 0.0)) if abs(v.x) < 0.9 else Vector((0.0, 1.0, 0.0))
    return v.cross(a).normalized()


def catmull(points, n=6):
    """Catmull-Rom curve through the points (n samples per span)."""
    pts = [Vector(p) for p in points]
    if len(pts) < 3:
        return [pts[0].lerp(pts[-1], i / n) for i in range(n + 1)]
    out = []
    for i in range(len(pts) - 1):
        p0 = pts[i - 1] if i > 0 else pts[i] * 2 - pts[i + 1]
        p1, p2 = pts[i], pts[i + 1]
        p3 = pts[i + 2] if i + 2 < len(pts) else pts[i + 1] * 2 - pts[i]
        for k in range(n):
            t = k / n
            out.append(0.5 * ((2 * p1) + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t * t
                              + (3 * p1 - p0 - 3 * p2 + p3) * t * t * t))
    out.append(pts[-1])
    return out


def bend_chain(points, z0, angle, toward):
    """Wilt: every segment above height z0 turns progressively (up to `angle` degrees at the top) so the soft top
    of a shoot nods over towards the horizontal direction `toward`."""
    pts = [Vector(p) for p in points]
    toward = Vector(toward).normalized()
    axis = UP.cross(toward).normalized()
    above = sum((b - a).length for a, b in zip(pts, pts[1:]) if a.z >= z0) or 1.0
    out = [pts[0]]
    acc = 0.0
    for a, b in zip(pts, pts[1:]):
        v = b - a
        if a.z >= z0:
            acc += v.length
            v = Matrix.Rotation(math.radians(angle) * acc / above, 3, axis) @ v
        out.append(out[-1] + v)
    return out


class Path:
    """A smooth shoot: Catmull-Rom through control points, queried by arc-length fraction."""

    def __init__(self, ctrl, r0, r1):
        self.pts = catmull(ctrl, 8)
        self.cum = [0.0]
        for a, b in zip(self.pts, self.pts[1:]):
            self.cum.append(self.cum[-1] + (b - a).length)
        self.length = self.cum[-1]
        self.r0, self.r1 = r0, r1

    def at(self, f):
        d = max(0.0, min(1.0, f)) * self.length
        for i in range(len(self.cum) - 1):
            if self.cum[i + 1] >= d or i == len(self.cum) - 2:
                span = max(self.cum[i + 1] - self.cum[i], 1e-9)
                k = max(0.0, min(1.0, (d - self.cum[i]) / span))
                return self.pts[i].lerp(self.pts[i + 1], k), (self.pts[i + 1] - self.pts[i]).normalized()
        return self.pts[-1], (self.pts[-1] - self.pts[-2]).normalized()

    def f_at_z(self, z):
        """Arc fraction where the shoot first reaches height z."""
        for i in range(len(self.pts) - 1):
            a, b = self.pts[i], self.pts[i + 1]
            if (a.z - z) * (b.z - z) <= 0 and abs(b.z - a.z) > 1e-9:
                k = (z - a.z) / (b.z - a.z)
                return (self.cum[i] + k * (self.cum[i + 1] - self.cum[i])) / self.length
        return 1.0

    def radius(self, f):
        return self.r0 + (self.r1 - self.r0) * f


# ============================================================================================ mesh builders
def tube(bm, pts, radii, sides=6, start="flat", end="round", end_point=None):
    """Tapered tube along a polyline (parallel-transport frames). Caps: "flat" (a fan, flat), "round" (a short
    dome), "point" (a cone to end_point / a little past the last ring), None (open)."""
    n = len(pts)
    tang = [(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized() for i in range(n)]
    normal = perp(tang[0])
    rings = []
    for i in range(n):
        if i > 0:
            axis = tang[i - 1].cross(tang[i])
            if axis.length > 1e-7:
                normal = Matrix.Rotation(tang[i - 1].angle(tang[i]), 3, axis.normalized()) @ normal
        bi = tang[i].cross(normal)
        rings.append([bm.verts.new(pts[i] + radii[i] * (math.cos(2 * math.pi * k / sides) * normal
                                                        + math.sin(2 * math.pi * k / sides) * bi))
                      for k in range(sides)])
    for i in range(n - 1):
        for k in range(sides):
            k2 = (k + 1) % sides
            bm.faces.new((rings[i][k], rings[i][k2], rings[i + 1][k2], rings[i + 1][k]))
    if start is not None:
        pole = bm.verts.new(pts[0] - tang[0] * (radii[0] * 0.7 if start == "round" else 0.0))
        for k in range(sides):
            bm.faces.new((rings[0][(k + 1) % sides], rings[0][k], pole))
    if end is not None:
        if end_point is not None:
            tip = Vector(end_point)
        else:
            tip = pts[-1] + tang[-1] * radii[-1] * (0.8 if end == "round" else 2.5 if end == "point" else 0.0)
        pole = bm.verts.new(tip)
        for k in range(sides):
            bm.faces.new((rings[-1][k], rings[-1][(k + 1) % sides], pole))


def stalk(bm, path, nodes=(), sides=8, step=0.035, bulge=0.3, flare=0.0, tip="round"):
    """The mesh of a shoot: rings every `step` metres plus a few around each node (arc fractions) so the node
    bulges read; an optional flare at the base (where the stem enters the soil)."""
    L = path.length
    fs = {0.0, 1.0}
    n = max(2, int(round(L / step)))
    fs.update(i / n for i in range(n + 1))
    for fn in nodes:
        fs.update(max(0.0, min(1.0, fn + dd / L)) for dd in (-0.012, -0.005, 0.0, 0.005, 0.012))
    if flare:
        fs.update(dd / L for dd in (0.006, 0.014, 0.026) if dd < L)
    fs = sorted(fs)
    keep = [fs[0]]
    for f in fs[1:]:
        if (f - keep[-1]) * L > 0.003:
            keep.append(f)
    if keep[-1] < 1.0:
        keep[-1] = 1.0
    pts, radii = [], []
    for f in keep:
        pts.append(path.at(f)[0])
        r = path.radius(f)
        for fn in nodes:
            r *= 1.0 + bulge * math.exp(-((f - fn) * L / 0.008) ** 2)
        if flare:
            r *= 1.0 + flare * math.exp(-f * L / 0.01)
        radii.append(r)
    tube(bm, pts, radii, sides, start="flat", end=tip)


def leaflet(bm, M, L, W, teeth=3, thick=0.008, fold=0.22, lift=0.15, droop=0.45, profile=LANCE, depth=0.32):
    """One leaflet blade lying along local +X from its base (the leaf hub, local origin), local +Z = the blade's
    upper side. A closed lens: raised midrib, umbrella fold (edges `fold` x half-width lower), flat underside,
    rounded tip; `teeth` chunky serrations per side pointing at the tip. The midrib rises by `lift` radians at
    the base and bends down to `droop` radians at the tip. W = full width. M: 4x4 placement."""
    st = [(0.0, 0.0, 1.0), (0.1, 0.1, 1.0)]  # (s ridge, s edge, width factor)
    if teeth > 0:
        a, b = 0.2, 0.9
        per = (b - a) / teeth
        for k in range(teeth):
            s = a + per * k
            st.append((s, s, 1.0 - depth))
            s = a + per * (k + 0.55)
            st.append((s, min(0.97, s + per * 0.32), 1.0))
    else:
        st += [(s, s, 1.0) for s, _ in profile[1:-1] if s > 0.1]

    def phi(u):
        return -lift + (lift + droop) * min(u / L, 1.2) ** 1.6

    def place(u, v, z):
        steps = 8
        du = u / steps
        X = Z = 0.0
        for i in range(steps):
            ph = phi((i + 0.5) * du)
            X += math.cos(ph) * du
            Z -= math.sin(ph) * du
        ph = phi(u)
        return M @ Vector((X + z * math.sin(ph), v, Z + z * math.cos(ph)))

    ridge, left, right = [], [], []
    for s, se, wf in st:
        w = W * 0.5 * table(profile, se) * wf
        t = thick * min(1.0, table(profile, s) * 1.6) if s > 0 else 0.0
        ridge.append(bm.verts.new(place(s * L, 0.0, t * 0.5)))
        left.append(bm.verts.new(place(se * L, w, -fold * w)))
        right.append(bm.verts.new(place(se * L, -w, -fold * w)))
    apex = bm.verts.new(place(L, 0.0, 0.0))
    for i in range(len(st) - 1):
        bm.faces.new((ridge[i], ridge[i + 1], left[i + 1], left[i]))
        bm.faces.new((ridge[i], right[i], right[i + 1], ridge[i + 1]))
        bm.faces.new((left[i], left[i + 1], right[i + 1], right[i]))
    bm.faces.new((ridge[-1], apex, left[-1]))
    bm.faces.new((ridge[-1], right[-1], apex))
    bm.faces.new((left[-1], apex, right[-1]))
    bm.faces.new((left[0], right[0], ridge[0]))


def fan_leaf(bm, start, yaw, fingers, size, petiole, pose, width=0.21, profile=LANCE, teeth=None, thick=None,
             pet_r=None, rnd=None, bm_petiole=None):
    """A palmate leaf: a petiole leaving the stem at `start` towards `yaw` (degrees, 0 = +X), then `fingers`
    leaflets radiating from its tip (the middle one `size` long). pose: rise / sag (petiole angle above the
    horizontal at the stem and how much it bends down by its tip, degrees), pitch (blade plane, degrees), cup
    (> 0 bowl, < 0 umbrella), droop / lift (leaflet midrib bend, radians), spread (finger fan factor), fold."""
    rnd = rnd or random.Random(1)
    d_h = horiz(yaw)
    seg = 4 if petiole > 0.04 else 2
    pts = [Vector(start)]
    for i in range(seg):
        a = math.radians(pose["rise"] - pose["sag"] * (i + 0.5) / seg)
        pts.append(pts[-1] + (d_h * math.cos(a) + UP * math.sin(a)) * (petiole / seg))
    hub = pts[-1].copy()
    pr = pet_r if pet_r is not None else max(0.0032, size * 0.03)
    if petiole > 0.004:
        tube(bm_petiole or bm, pts[:-1], [pr * (1.2 - 0.3 * i / seg) for i in range(seg)], sides=5, start="flat",
             end="point", end_point=hub)
    p_ang = math.radians(pose["pitch"])
    f = (d_h * math.cos(p_ang) + UP * math.sin(p_ang)).normalized()
    u = (-d_h * math.sin(p_ang) + UP * math.cos(p_ang)).normalized()
    side = u.cross(f)
    thick = thick if thick is not None else max(0.006, size * 0.055)
    for ang, lf, nt in FINGERS[fingers]:
        ang = ang * pose.get("spread", 1.0) + rnd.uniform(-4.0, 4.0)
        a = math.radians(ang)
        x = f * math.cos(a) + side * math.sin(a)
        z = Matrix.Rotation(math.radians(pose.get("cup", 0.1) * ang), 3, x) @ u
        y = z.cross(x)
        M = Matrix((x, y, z)).transposed().to_4x4()
        M.translation = hub
        L = size * lf * rnd.uniform(0.94, 1.06)
        outer = abs(ang) / 90.0
        leaflet(bm, M, L, L * width, teeth=nt if teeth is None else min(nt, teeth), thick=thick,
                fold=pose.get("fold", 0.2), lift=pose.get("lift", 0.12) * (1.0 - 0.6 * outer),
                droop=pose.get("droop", 0.45) * (1.0 + 0.45 * outer), profile=profile)
    return hub


def cola(bm_bud, base, axis, length, radius, rnd, segs=14, rings=10, lumps=14, bump=0.24, frost_bm=None,
         frost_at=0.62, pistil_bm=None, pistils=6, pistil_len=0.035, pistil_r=0.0045):
    """A bud / cola: one lumpy blob of calyx bumps (golden-angle spiral) around `axis` from `base`, fat low,
    rounded tip. Faces on the bump tips go to frost_bm (a lighter shade: trichome frost) when given. Pistil
    hairs curl out of some bumps into pistil_bm. Returns the tip position."""
    axis = Vector(axis).normalized()
    n1 = perp(axis)
    n2 = axis.cross(n1)
    prof = [(0.0, 0.0), (0.05, 0.6), (0.16, 0.9), (0.36, 1.0), (0.6, 0.92), (0.8, 0.72), (0.92, 0.48),
            (0.98, 0.22), (1.0, 0.0)]
    phase = rnd.uniform(0.0, math.tau)
    bumps = []
    for k in range(lumps):
        t = 0.1 + 0.82 * (k + 0.5) / lumps
        th = phase + k * 2.39996
        bumps.append((t, th, rnd.uniform(0.85, 1.2)))
    tmp = bmesh.new()
    bmesh.ops.create_uvsphere(tmp, u_segments=segs, v_segments=rings, radius=1.0)
    height = {}
    for v in tmp.verts:
        x, y, zc = v.co
        t = math.acos(max(-1.0, min(1.0, -zc))) / math.pi  # 0 at the bottom pole, 1 at the top
        rl = math.hypot(x, y)
        R = radius * table(prof, t)
        th = math.atan2(y, x)
        h = 0.0
        for (tb, thb, sb) in bumps:
            dth = (th - thb + math.pi) % math.tau - math.pi
            d2 = ((t - tb) * length) ** 2 + (max(R, radius * 0.3) * dth) ** 2
            rho = radius * 0.46 * sb
            if d2 < rho * rho:
                h += (1.0 - d2 / (rho * rho)) ** 2
        h = min(h, 1.25)
        height[v] = h
        radial = (n1 * x + n2 * y) / rl if rl > 1e-6 else Vector((0.0, 0.0, 0.0))
        v.co = base + axis * (t * length) + radial * (R + radius * bump * h * table(prof, t) ** 0.5)
    # copy into the target bmesh(es)
    remap = {}
    for v in tmp.verts:
        remap[v] = bm_bud.verts.new(v.co)
    frost_map = {}
    for fc in tmp.faces:
        mean = sum(height[v] for v in fc.verts) / len(fc.verts)
        if frost_bm is not None and mean > frost_at:
            vs = []
            for v in fc.verts:
                if v not in frost_map:
                    frost_map[v] = frost_bm.verts.new(v.co)
                vs.append(frost_map[v])
            frost_bm.faces.new(vs)
        else:
            bm_bud.faces.new([remap[v] for v in fc.verts])
    tmp.free()
    # pistils: curled hairs out of the bump tips
    if pistil_bm is not None and pistils > 0:
        chosen = sorted(range(lumps), key=lambda i: rnd.random())[:pistils]
        for i in chosen:
            t, th, sb = bumps[i]
            radial = n1 * math.cos(th) + n2 * math.sin(th)
            R = radius * table(prof, t) * (1.0 + bump * table(prof, t) ** 0.5)
            p0 = base + axis * (t * length) + radial * (R * 0.8)
            side = axis.cross(radial) * rnd.uniform(-0.5, 0.5)
            ln = pistil_len * rnd.uniform(0.8, 1.2)
            p1 = p0 + (radial * 0.9 + axis * 0.35 + side * 0.3).normalized() * ln * 0.5
            p2 = p1 + (radial * 0.35 + axis * 0.8 + side).normalized() * ln * 0.5
            tube(pistil_bm, [p0, p1], [pistil_r, pistil_r * 0.8], sides=3, start="flat", end="point", end_point=p2)
    return base + axis * length


# ============================================================================================ poses
def pose(w, **healthy):
    """Leaf pose for wilt w (0 healthy .. 1 wilted). Healthy values can be overridden per leaf."""
    h = dict(rise=36.0, sag=16.0, pitch=4.0, cup=0.14, droop=0.45, lift=0.14, spread=1.0, fold=0.2)
    h.update(healthy)
    d = dict(rise=h["rise"] * 0.35, sag=h["sag"] + 62.0, pitch=-58.0, cup=-0.35, droop=1.25, lift=0.0,
             spread=0.62, fold=0.42)
    return {k: h[k] + (d[k] - h[k]) * w for k in h}


# ============================================================================================ assembly
class Kit:
    """Per-model bmesh buckets keyed by material name."""

    def __init__(self, seed):
        self.rnd = random.Random(seed)
        self.bms = {}
        self.mats = {}

    def bm(self, key, mat):
        if key not in self.bms:
            self.bms[key] = bmesh.new()
            self.mats[key] = mat
        return self.bms[key]

    def objects(self, prefix, keys=None):
        objs = []
        for key in sorted(self.bms):
            if keys is not None and key not in keys:
                continue
            bm = self.bms[key]
            if not bm.faces:
                continue
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
            me = bpy.data.meshes.new("%s_%s" % (prefix, key))
            bm.normal_update()
            bm.to_mesh(me)
            bm.free()
            ob = bpy.data.objects.new("%s_%s" % (prefix, key), me)
            bpy.context.scene.collection.objects.link(ob)
            ob["gwf_smooth"] = 180.0
            me.materials.append(self.mats[key])
            objs.append(ob)
        for key in [k for k in self.bms if keys is None or k in keys]:
            del self.bms[key]
        return objs


def mats():
    return {
        "lime": lib("lime"), "leaf": lib("leaf"), "dry": lib("leaf_dry"), "olive": lib("olive"),
        "cream": lib("cream"), "rust": lib("rust"),
        "bud": tint_material("TINT_bud", finish="glow"),
        "frost": tint_material("TINT_frost", shade=1.18, finish="glow"),
    }


def ready_node(path, f):
    p, t = path.at(f)
    return p, t, path.radius(f)


# ============================================================================================ seedling
def seedling(w, name):
    reset()
    m = mats()
    kit = Kit(11)
    rnd = kit.rnd
    green = m["dry"] if w else m["lime"]
    stem_bm = kit.bm("stem", m["lime"])
    leaf_bm = kit.bm("leaf", green)
    ctrl = [(0, 0, 0), (0, 0, 0.03), (0.003, 0.002, 0.075), (0.007, 0.0, 0.12), (0.006, -0.002, 0.165),
            (0.004, 0.0, 0.2), (0.003, 0.001, 0.222)]
    if w:
        ctrl = bend_chain(ctrl, 0.04, 105.0, (0.75, -0.55, 0.0))
    path = Path(ctrl, 0.0095, 0.0062)
    f_cot, f_n1, f_n2 = path.f_at_z(0.115), path.f_at_z(0.165), path.f_at_z(0.205)
    if w:
        f_cot, f_n1, f_n2 = 0.52, 0.74, 0.92
    stalk(stem_bm, path, nodes=(f_cot, f_n1, f_n2), sides=8, step=0.02, bulge=0.28, flare=0.35)
    yaw0 = 28.0
    # cotyledons: round, smooth, short-stalked, nearly level
    p, _ = path.at(f_cot)
    for k in (0, 180):
        fan_leaf(leaf_bm, p, yaw0 + k + rnd.uniform(-6, 6), 1, 0.07, 0.016,
                 pose(w, rise=24, sag=18, pitch=6, droop=0.3, lift=0.1, fold=0.1),
                 width=0.64, profile=OVAL, teeth=0, thick=0.011, pet_r=0.0045, rnd=rnd)
    # first true leaves: one serrated blade each, turned 90 degrees
    p, _ = path.at(f_n1)
    for k in (90, 270):
        fan_leaf(leaf_bm, p, yaw0 + k + rnd.uniform(-8, 8), 1, 0.088, 0.024,
                 pose(w, rise=40, sag=14, pitch=10, droop=0.5), width=0.34, thick=0.009, pet_r=0.004, rnd=rnd)
    # second pair: three fingers
    p, _ = path.at(f_n2)
    for k in (0, 180):
        fan_leaf(leaf_bm, p, yaw0 + k + 12 + rnd.uniform(-8, 8), 3, 0.09, 0.03,
                 pose(w, rise=46, sag=16, pitch=14, droop=0.5), width=0.3, thick=0.009, pet_r=0.004, rnd=rnd)
    # new growth: a tiny tuft on top
    p, t = path.at(1.0)
    for k in (90, 270):
        fan_leaf(leaf_bm, p - t * 0.004, yaw0 + k, 1, 0.034, 0.004,
                 pose(w, rise=70, sag=6, pitch=58, droop=0.2, lift=0.2), width=0.36, teeth=1, thick=0.007,
                 pet_r=0.003, rnd=rnd)
    leaves = join(kit.objects("seedling"), "Leaves")
    export(leaves, name, kind="part", mount="floor", budget=BUDGET)


# ============================================================================================ vegetative
def vegetative(w, name):
    reset()
    m = mats()
    kit = Kit(23)
    rnd = kit.rnd
    green = m["dry"] if w else m["leaf"]
    stem_bm = kit.bm("stem", m["lime"])
    leaf_bm = kit.bm("leaf", green)
    base_ctrl = [(0, 0, 0), (0, 0, 0.05), (0.004, 0.002, 0.15), (0.0, 0.006, 0.27), (-0.006, 0.002, 0.39),
                 (-0.004, -0.004, 0.49), (0.0, -0.002, 0.57), (0.002, 0.0, 0.62)]
    ctrl = bend_chain(base_ctrl, 0.36, 70.0, (-0.6, -0.8, 0.0)) if w else base_ctrl
    path = Path(ctrl, 0.021, 0.0085)
    ref = Path(base_ctrl, 1, 1)  # node positions from the upright plant, so the wilted one keeps its nodes
    node_z = [0.075, 0.155, 0.245, 0.335, 0.415, 0.485, 0.545]
    fs = [ref.f_at_z(z) for z in node_z]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.04, bulge=0.3, flare=0.3)
    #        fingers, size, petiole, rise, sag
    spec = [(3, 0.085, 0.05, 22, 34), (5, 0.13, 0.085, 30, 24), (7, 0.18, 0.12, 36, 20), (7, 0.176, 0.11, 38, 18),
            (7, 0.145, 0.082, 42, 16), (5, 0.105, 0.05, 48, 14), (5, 0.075, 0.03, 56, 12)]
    yaw = 15.0
    for i, (f, (nf, size, pet, rise, sag)) in enumerate(zip(fs, spec)):
        p, t = path.at(f)
        r = path.radius(f)
        for k in (0, 180):
            y = yaw + k + rnd.uniform(-10, 10)
            fan_leaf(leaf_bm, p + horiz(y) * r * 0.4, y, nf, size, pet, pose(w, rise=rise, sag=sag), rnd=rnd)
            if i in (1, 2):  # side shoots from the lower axils (apical dominance keeps them shorter)
                branch(kit, m, p, y + 18 * (1 if k else -1), w, stem_bm, leaf_bm, rnd, big=(i == 2))
        yaw += 90.0 + rnd.uniform(-12, 12)
    # new growth on top
    p, t = path.at(1.0)
    for k in (0, 120, 240):
        fan_leaf(leaf_bm, p - t * 0.006, yaw + k, 3, 0.05, 0.008, pose(w, rise=62, sag=8, pitch=40, droop=0.3),
                 teeth=2, rnd=rnd)
    leaves = join(kit.objects("veg"), "Leaves")
    export(leaves, name, kind="part", mount="floor", budget=BUDGET)


def branch(kit, m, start, yaw, w, stem_bm, leaf_bm, rnd, big=False):
    """A vegetative side shoot: out at ~45 degrees from its axil, curving up, one leaf pair and a tip tuft."""
    d = horiz(yaw)
    L = 0.24 if big else 0.2
    ctrl = [start, start + d * 0.03 + UP * 0.03, start + d * 0.08 + UP * L * 0.45, start + d * 0.11 + UP * L * 0.8,
            start + d * 0.12 + UP * L]
    if w:
        ctrl = bend_chain(ctrl, start.z + 0.02, 55.0, d)
    path = Path(ctrl, 0.009, 0.0055)
    fn = 0.55
    stalk(stem_bm, path, nodes=(fn,), sides=6, step=0.05, bulge=0.3)
    p, t = path.at(fn)
    for k in (90, 270):
        fan_leaf(leaf_bm, p, yaw + k + rnd.uniform(-10, 10), 5, 0.1 if big else 0.085, 0.04,
                 pose(w, rise=40, sag=18), teeth=3, rnd=rnd)
    p, t = path.at(1.0)
    for k in (0, 180):
        fan_leaf(leaf_bm, p - t * 0.004, yaw + 90 + k, 3, 0.05, 0.008, pose(w, rise=60, sag=8, pitch=38, droop=0.3),
                 teeth=2, rnd=rnd)


# ============================================================================================ flowering
def flowering(w, name):
    reset()
    m = mats()
    kit = Kit(37)
    rnd = kit.rnd
    green = m["dry"] if w else m["leaf"]
    stem_bm = kit.bm("stem", m["olive"])
    leaf_bm = kit.bm("leaf", green)
    bud_bm = kit.bm("bud", m["bud"])
    pis_bm = kit.bm("pistil", m["cream"])
    base_ctrl = [(0, 0, 0), (0, 0, 0.06), (0.004, 0.003, 0.2), (0.0, 0.006, 0.38), (-0.006, 0.0, 0.55),
                 (-0.004, -0.006, 0.68), (0.0, -0.004, 0.78)]
    ctrl = bend_chain(base_ctrl, 0.5, 50.0, (0.6, -0.8, 0.0)) if w else base_ctrl
    path = Path(ctrl, 0.024, 0.0105)
    ref = Path(base_ctrl, 1, 1)
    node_z = [0.07, 0.15, 0.25, 0.36, 0.47, 0.57, 0.655, 0.725]
    fs = [ref.f_at_z(z) for z in node_z]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.05, bulge=0.26, flare=0.3, tip="round")
    #        fingers, size, petiole, rise, sag, bud-site at the axils
    spec = [(7, 0.165, 0.12, 22, 34, 0), (7, 0.19, 0.13, 28, 26, 0), (7, 0.17, 0.11, 32, 22, 0),
            (5, 0.14, 0.09, 36, 18, 0), (5, 0.11, 0.06, 40, 16, 1), (3, 0.085, 0.04, 46, 14, 1),
            (3, 0.065, 0.02, 52, 12, 1), (1, 0.05, 0.01, 58, 10, 0)]
    yaw = 35.0
    for i, (f, (nf, size, pet, rise, sag, site)) in enumerate(zip(fs, spec)):
        p, t = path.at(f)
        r = path.radius(f)
        for k in (0, 180):
            y = yaw + k + rnd.uniform(-10, 10)
            fan_leaf(leaf_bm, p + horiz(y) * r * 0.4, y, nf, size, pet, pose(w, rise=rise, sag=sag), rnd=rnd)
            if i in (2, 3):
                flower_branch(kit, m, p, y + 20 * (1 if k else -1), w, stem_bm, leaf_bm, bud_bm, pis_bm, rnd,
                              long=(i == 2))
            elif site:
                # a bud site in the axil: a small calyx cluster hugging the stem, a hair or two
                d = horiz(y + 25)
                cola(bud_bm, p + d * r * 1.1, (d * 0.55 + t).normalized(), 0.045 - 0.004 * (i - 4), 0.019, rnd,
                     segs=10, rings=7, lumps=6, pistil_bm=pis_bm, pistils=3, pistil_len=0.026, pistil_r=0.004)
        yaw += 90.0 + rnd.uniform(-12, 12)
    # the apical bud forming: a short fat cluster on the leader, pistils, sugar leaves
    p, t = path.at(1.0)
    ax = (t + UP * 0.6).normalized() if not w else t
    top = cola(bud_bm, p - ax * 0.02, ax, 0.14, 0.042, rnd, segs=14, rings=10, lumps=14, pistil_bm=pis_bm,
               pistils=8, pistil_len=0.034)
    sugar(leaf_bm, p - ax * 0.005, ax, 0.042, w, rnd, n=3, size=0.06)
    buds = join(kit.objects("flower", keys=("bud", "pistil")), "Buds")
    leaves = join(kit.objects("flower"), "Leaves")
    export([leaves, buds], name, kind="part", mount="floor", budget=BUDGET)


def flower_branch(kit, m, start, yaw, w, stem_bm, leaf_bm, bud_bm, pis_bm, rnd, long=True):
    """A flowering branch: stretched, reaching up, one fan leaf on the way, a bud site at the tip."""
    d = horiz(yaw)
    L = 0.36 if long else 0.3
    ctrl = [start, start + d * 0.035 + UP * 0.03, start + d * 0.1 + UP * L * 0.4, start + d * 0.14 + UP * L * 0.78,
            start + d * 0.15 + UP * L]
    if w:
        ctrl = bend_chain(ctrl, start.z + 0.03, 45.0, d)
    path = Path(ctrl, 0.0105, 0.006)
    fn = 0.45
    stalk(stem_bm, path, nodes=(fn,), sides=6, step=0.06, bulge=0.3, tip=None)
    p, t = path.at(fn)
    fan_leaf(leaf_bm, p, yaw + 80 + rnd.uniform(-10, 10), 5, 0.1, 0.045, pose(w, rise=38, sag=20), teeth=3, rnd=rnd)
    p, t = path.at(1.0)
    ax = (t + UP * 0.4).normalized() if not w else t
    cola(bud_bm, p - ax * 0.012, ax, 0.075, 0.027, rnd, segs=12, rings=8, lumps=9, pistil_bm=pis_bm, pistils=4,
         pistil_len=0.03)
    sugar(leaf_bm, p, ax, 0.027, w, rnd, n=2, size=0.05)


def sugar(bm, base, axis, radius, w, rnd, n=3, size=0.06, fingers=None):
    """Small 1-3 finger sugar leaves poking out from the lower half of a bud, pointing out and up."""
    axis = Vector(axis).normalized()
    ph = rnd.uniform(0, 360)
    for k in range(n):
        a = ph + k * 360.0 / n + rnd.uniform(-20, 20)
        d = horiz(a)
        # horizontal component away from the bud; lean the leaf up along the bud
        start = base + axis * (radius * rnd.uniform(0.3, 0.9)) + d * radius * 0.5
        nf = fingers or rnd.choice((1, 3, 3))
        fan_leaf(bm, start, a, nf, size * rnd.uniform(0.85, 1.1), 0.006,
                 pose(w, rise=52, sag=6, pitch=46, droop=0.55, lift=0.05, cup=0.25), width=0.24, teeth=2,
                 thick=0.006, pet_r=0.003, rnd=rnd)


# ============================================================================================ ready
def ready(name):
    reset()
    m = mats()
    kit = Kit(53)
    rnd = kit.rnd
    stem_bm = kit.bm("stem", m["olive"])
    leaf_bm = kit.bm("leaf", m["leaf"])
    dry_bm = kit.bm("yellow", m["dry"])
    lean = Vector((1.0, -0.35, 0.0)).normalized()

    def leaned(pts, amount=0.07, top=1.0):
        return [Vector(p) + lean * amount * (max(0.0, Vector(p).z) / top) ** 1.8 for p in pts]

    ctrl = leaned([(0, 0, 0), (0, 0, 0.06), (0.004, 0.003, 0.2), (0.0, 0.006, 0.38), (-0.006, 0.0, 0.55),
                   (-0.004, -0.006, 0.66), (0.0, -0.004, 0.72)])
    path = Path(ctrl, 0.028, 0.014)
    node_z = [0.075, 0.16, 0.26, 0.37, 0.48, 0.58, 0.66]
    fs = [path.f_at_z(z) for z in node_z]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.05, bulge=0.24, flare=0.3, tip=None)
    colas = []  # (name, Kit-like dict of bmeshes, base point)

    def new_cola(label):
        d = {"bud": bmesh.new(), "frost": bmesh.new(), "pistil": bmesh.new()}
        colas.append((label, d))
        return d

    # the main cola crowns the leader; the small colas along the upper stem pulse with it (ColaTop)
    top = new_cola("ColaTop")
    p, t = path.at(1.0)
    ax = (t * 0.7 + UP * 0.3 + lean * 0.08).normalized()
    top_base = p - ax * 0.03
    top["base_point"] = top_base
    cola(top["bud"], top_base, ax, 0.38, 0.078, rnd, segs=16, rings=14, lumps=26, bump=0.26, frost_bm=top["frost"],
         pistil_bm=top["pistil"], pistils=10, pistil_len=0.04, pistil_r=0.005)
    sugar(leaf_bm, top_base + ax * 0.02, ax, 0.07, 0.0, rnd, n=4, size=0.075)
    #        fingers, size, petiole, rise, sag, kind: "yellow" lower fans, "branch", "side" (colas at the axils)
    spec = [(7, 0.17, 0.12, 14, 60, "yellow"), (7, 0.19, 0.13, 20, 46, "yellow"), (7, 0.16, 0.11, 30, 30, "branch"),
            (5, 0.13, 0.08, 34, 24, "branch"), (5, 0.1, 0.05, 40, 18, "side"), (3, 0.08, 0.03, 46, 14, "side"),
            (1, 0.06, 0.01, 52, 10, "side")]
    yaw = 20.0
    n_branch = 0
    for i, (f, (nf, size, pet, rise, sag, kind)) in enumerate(zip(fs, spec)):
        p, t = path.at(f)
        r = path.radius(f)
        for k in (0, 180):
            y = yaw + k + rnd.uniform(-10, 10)
            target = dry_bm if kind == "yellow" else leaf_bm
            wilt = 0.55 if kind == "yellow" else 0.0
            if not (i == 0 and k == 180):  # one old fan leaf already dropped
                fan_leaf(target, p + horiz(y) * r * 0.4, y, nf, size, pet, pose(wilt, rise=rise, sag=sag), rnd=rnd)
            if kind == "branch":
                n_branch += 1
                heavy_branch(new_cola("Cola%d" % n_branch), p, y + 22 * (1 if k else -1), stem_bm, leaf_bm, rnd,
                             long=(i == 2))
            elif kind == "side":
                d = horiz(y + 25)
                cola(top["bud"], p + d * r * 1.0, (d * 0.5 + t).normalized(), 0.08 - 0.012 * (i - 4), 0.036, rnd,
                     segs=12, rings=8, lumps=9, frost_bm=top["frost"], pistil_bm=top["pistil"], pistils=3,
                     pistil_len=0.03)
        yaw += 90.0 + rnd.uniform(-12, 12)
    # a fifth branch from the lowest green node (asymmetric, heavy, bowed)
    p, t = path.at(fs[1])
    n_branch += 1
    heavy_branch(new_cola("Cola%d" % n_branch), p, yaw + 45, stem_bm, leaf_bm, rnd, long=True, low=True)

    leaves = join(kit.objects("ready"), "Leaves")
    buds = empty("Buds")
    for label, d in colas:
        objs = []
        for key, mat in (("bud", m["bud"]), ("frost", m["frost"]), ("pistil", m["rust"])):
            k2 = Kit(0)
            k2.bms[key] = d[key]
            k2.mats[key] = mat
            objs += k2.objects(label)
        c = join(objs, label, origin=d["base_point"])
        set_parent(c, buds)
    export([leaves, buds], name, kind="part", mount="floor", budget=BUDGET)


def heavy_branch(d, start, yaw, stem_bm, leaf_bm, rnd, long=True, low=False):
    """A ready branch: out and up, then bowed over by the cola hanging at its tip."""
    dh = horiz(yaw)
    L = 0.42 if long else 0.34
    if low:
        L = 0.46
    ctrl = [start, start + dh * 0.04 + UP * 0.035, start + dh * 0.12 + UP * L * 0.45,
            start + dh * 0.19 + UP * L * 0.8, start + dh * 0.23 + UP * L * 0.92]
    path = Path(ctrl, 0.012, 0.0075)
    fn = 0.42
    stalk(stem_bm, path, nodes=(fn,), sides=6, step=0.06, bulge=0.3, tip=None)
    p, t = path.at(fn)
    fan_leaf(leaf_bm, p, yaw + 75 + rnd.uniform(-10, 10), 5, 0.1, 0.045, pose(0.15, rise=34, sag=24), teeth=3,
             rnd=rnd)
    p, t = path.at(1.0)
    ax = (t * 0.6 + UP * 0.25 + dh * 0.3).normalized()
    base = p - ax * 0.025
    d["base_point"] = base
    cola(d["bud"], base, ax, 0.2 if long else 0.17, 0.055, rnd, segs=14, rings=11, lumps=15, bump=0.26,
         frost_bm=d["frost"], pistil_bm=d["pistil"], pistils=6, pistil_len=0.036)
    sugar(leaf_bm, base + ax * 0.015, ax, 0.05, 0.0, rnd, n=2, size=0.06)


# ============================================================================================ build
def build():
    seedling(0.0, "plant_seedling")
    seedling(1.0, "plant_seedling_dry")
    vegetative(0.0, "plant_vegetative")
    vegetative(1.0, "plant_vegetative_dry")
    flowering(0.0, "plant_flowering")
    flowering(1.0, "plant_flowering_dry")
    ready("plant_ready")
