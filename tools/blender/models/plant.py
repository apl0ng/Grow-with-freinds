"""plant: the cannabis plant across its growth stages (PLAN 8.7, the dedicated plant pass).

Real-world morphology, chunky toon output. kind "part" (front = Blender -Y -> Godot +Z, like the plot), floor
mount: the origin is where the stem enters the soil (grow_plot.tscn puts PlantVisual at the soil top, y 0.49; the
soil mound there is ~2 cm higher, so hanging leaves are laid onto it, see on_soil()). Instanced by
scenes/stations/plant_visual.tscn and driven by scripts/stations/plant_visual.gd.

  plant_seedling (+ _dry)    0.32 x 0.31 m. Hypocotyl with a flared foot, two round smooth cotyledons, the first
                             pair of single-blade serrated true leaves, a second pair with three fingers (opposite
                             and decussate: each pair turned ~90 degrees), a tuft of new growth. Lime (bright soft
                             green). Built at ~20 cm and oversized x1.45 so it reads from 3 m in a 1.5 m tray.
  plant_vegetative (+ _dry)  0.96 x 0.66 m. Main stem with swollen nodes, five opposite decussate leaf pairs:
                             3 fingers at the oldest node, 5, then the big 7-finger fans (middle finger longest,
                             the lowest pair swept back), 5 near the top; side shoots from the two lower axils with
                             their own leaf pairs (apical dominance: the leader stays tallest); new growth on top.
  plant_flowering (+ _dry)   0.78 x 0.98 m. The stretch: long upper internodes, the big fans kept low, four branches
                             reaching up to young buds, bud sites in the upper axils, the apical bud forming. Buds
                             are young colas (TINT calyx bumps, no frost yet) with curly cream pistil hairs and a
                             few sugar leaves.
  plant_ready                0.91 x 1.07 m. Harvest: a heavy main cola on the leader, four bowed branches ending in
                             fat colas, small colas in the upper axils; calyx bumps frosted (lighter TINT shade),
                             pistils gone short, shrivelled and rust brown, sugar leaves poking out; the lower fans
                             yellow and hang onto the soil (one already dropped); the plant leans under the weight.

The _dry models are the same plants (same seeds) wilted: petioles sag, fingers fold and close up and hang, the soft
tops and branch tips arc over (bend_chain), leaves toon_leaf_dry, stems stay lime. PlantVisual swaps them in
while the plot is dry (READY never dries: it does not drink).

Nodes (MODELING.md section 8 names):
  Leaves   one mesh: stems, petioles, fan and sugar leaves (library greens, never TINT).
  Buds     flowering: one mesh, the TINT_bud buds + cream pistils.
           ready: an empty whose children are the colas, ONE MESH PER COLA with its origin at the cola's base
           (ColaTop = main cola + the axil colas on the leader, Cola1..Cola4 = branch colas), so PlantVisual can
           pulse each cola in place without tearing it off its branch.
Materials: toon_lime (stems, seedling), toon_leaf, toon_leaf_dry, toon_cream / toon_rust (pistils) and the strain
colour TINT_bud (glow finish like toon_bud) + TINT_frost (shade 1.18: a lighter shade of the same tint); Toonify
recolours both with Toon.grade(seed.color).

Construction (all bmesh, all closed so the outline hull and normals behave):
  leaflet()   a lens-shaped blade: raised midrib, rounded shared edges, umbrella fold, flat underside, midrib
              lifting at the base and drooping to the tip, 1-4 chunky serration teeth per side pointing at the tip
              (fewer on small leaflets: teeth_for()). Never paper thin.
  fan_leaf()  a tapered petiole, then 1/3/5/7 leaflets radiating from its tip (palmate). Every leaflet and the
              petiole end share ONE vertex position, so Toonify's outline sees the whole leaf as one part.
  stalk()     a tapered tube along a Catmull-Rom path with bulges at the nodes and a flared foot.
  cola()      a tapered core along a spine curve covered in small calyx bumps (golden-angle spiral), frosted
              bumps, pistils: curly blunt white hairs (young) or short pointed rust ones (ripe).
Budget: 6000 tris per stage (raised from the part default 3000: the plant is the game's centrepiece and palmate
serrated leaves need their vertices; one draw call per material per node). Horizontal SPREAD per stage makes the
plants own their tray without exceeding the stage heights of the brief. PRINT_TRIS = True prints every bucket.
"""
import random

import bmesh
import bpy

from gwf import *

UP = Vector((0.0, 0.0, 1.0))
BUDGET = 6000
PRINT_TRIS = False  # True: print the tris of every material bucket (budget tuning)
# Horizontal spread per stage: the plants are built at plausible proportions, then widened to own their 1.5 m tray
# (cartoon oversize) while keeping the stage heights of the brief (veg ~0.65, flowering ~0.95, ready ~1.05 m).
SPREAD = {"vegetative": 1.25, "flowering": 1.25, "ready": 1.2}
SEEDLING_SCALE = 1.45  # the seedling is modelled at ~real size (15-20 cm), then oversized to read from 3 m

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


def bend_chain(points, z0, angle, toward, power=1.6):
    """Wilt: every segment above height z0 turns progressively (up to `angle` degrees at the top; `power` > 1 puts
    the bend towards the tip, like a limp shoot hanging from a stiffer base) so the soft top of a shoot nods over
    towards the horizontal direction `toward`."""
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
            v = Matrix.Rotation(math.radians(angle) * (acc / above) ** power, 3, axis) @ v
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


def stalk(bm, path, nodes=(), sides=8, step=0.035, bulge=0.3, flare=0.0, tip="round", end=1.0):
    """The mesh of a shoot: rings every `step` metres plus a few around each node (arc fractions) so the node
    bulges read; an optional flare at the base (where the stem enters the soil). `end` < 1 stops the mesh early
    (the rest of the shoot is hidden inside a cola)."""
    L = path.length
    fs = {0.0, end}
    n = max(2, int(round(L * end / step)))
    fs.update(end * i / n for i in range(n + 1))
    for fn in nodes:
        fs.update(max(0.0, min(end, fn + dd / L)) for dd in (-0.009, 0.0, 0.009))
    if flare:
        fs.update(dd / L for dd in (0.006, 0.014, 0.026) if dd < L)
    fs = sorted(fs)
    keep = [fs[0]]
    for f in fs[1:]:
        if (f - keep[-1]) * L > 0.003:
            keep.append(f)
    if keep[-1] < end:
        keep[-1] = end
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


def teeth_for(L):
    """Chunky serration: few big teeth, fewer on small leaflets (they would not read and cost 12 tris each)."""
    return 4 if L >= 0.27 else 3 if L >= 0.14 else 2 if L >= 0.075 else 1 if L >= 0.035 else 0


def soil_z(r):
    """Height of the plot's soil mound above the plant origin at distance r from the stem (grow_plot.tscn:
    SoilMound sphere r 0.6 x 0.2 at y 0.41, plant origin at y 0.49), plus a hair, never below the origin."""
    return max(0.0015, 0.41 + 0.1 * math.sqrt(max(0.0, 1.0 - (r / 0.6) ** 2)) - 0.49 + 0.004)


def on_soil(co):
    """Leaves that droop to the soil lie on it instead of sinking in."""
    zmin = soil_z(math.hypot(co.x, co.y))
    if co.z < zmin:
        co = Vector((co.x, co.y, zmin + (co.z - zmin) * 0.06))
    return co


def leaflet(bm, M, L, W, teeth=3, thick=0.008, fold=0.22, lift=0.15, droop=0.45, profile=LANCE, depth=0.28):
    """One leaflet blade lying along local +X from its base (the leaf hub, local origin), local +Z = the blade's
    upper side. A closed lens: raised midrib, umbrella fold (edges `fold` x half-width lower), flat underside,
    rounded tip; `teeth` chunky serrations per side pointing at the tip. The midrib rises by `lift` radians at
    the base and bends down to `droop` radians at the tip. W = full width. M: 4x4 placement."""
    teeth = min(teeth, teeth_for(L)) if profile is LANCE else teeth
    st = [(0.0, 0.0, 1.0)] + ([] if teeth >= 2 else [(0.1, 0.1, 1.0)])  # (s ridge, s edge, width factor)
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
        return on_soil(M @ Vector((X + z * math.sin(ph), v, Z + z * math.cos(ph))))

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


def fan_leaf(bm, start, yaw, fingers, size, petiole, pose, width=0.44, profile=LANCE, teeth=None, thick=None,
             pet_r=None, rnd=None, bm_petiole=None):
    """A palmate leaf: a petiole leaving the stem at `start` towards `yaw` (degrees, 0 = +X), then `fingers`
    leaflets radiating from its tip (the middle one `size` long). pose: rise / sag (petiole angle above the
    horizontal at the stem and how much it bends down by its tip, degrees), pitch (blade plane, degrees), cup
    (> 0 bowl, < 0 umbrella), droop / lift (leaflet midrib bend, radians), spread (finger fan factor), fold."""
    rnd = rnd or random.Random(1)
    d_h = horiz(yaw)
    seg = 3 if petiole > 0.04 else 2
    pts = [Vector(start)]
    for i in range(seg):
        a = math.radians(pose["rise"] - pose["sag"] * (i + 0.5) / seg)
        pts.append(pts[-1] + (d_h * math.cos(a) + UP * math.sin(a)) * (petiole / seg))
    hub = pts[-1].copy()
    pr = pet_r if pet_r is not None else max(0.0032, size * 0.03)
    if petiole > 0.004:
        tube(bm_petiole or bm, [on_soil(q) for q in pts[:-1]], [pr * (1.2 - 0.3 * i / seg) for i in range(seg)],
             sides=4, start="flat", end="point", end_point=on_soil(hub))
    hub = on_soil(hub)
    p_ang = math.radians(pose["pitch"])
    f = (d_h * math.cos(p_ang) + UP * math.sin(p_ang)).normalized()
    u = (-d_h * math.sin(p_ang) + UP * math.cos(p_ang)).normalized()
    side = u.cross(f)
    thick = thick if thick is not None else max(0.005, size * 0.038)
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


class Spine:
    """An arc-length parametrised curve with parallel-transport frames (a cola following its branch)."""

    def __init__(self, pts):
        pts = [Vector(p) for p in pts]
        pts = catmull(pts, 4) if len(pts) > 2 else [pts[0].lerp(pts[1], i / 6) for i in range(7)]
        self.pts = pts
        self.cum = [0.0]
        for a, b in zip(pts, pts[1:]):
            self.cum.append(self.cum[-1] + (b - a).length)
        n = len(pts)
        self.T = [(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)]).normalized() for i in range(n)]
        self.N = [perp(self.T[0])]
        for i in range(1, n):
            axis = self.T[i - 1].cross(self.T[i])
            nn = self.N[-1]
            if axis.length > 1e-7:
                nn = Matrix.Rotation(self.T[i - 1].angle(self.T[i]), 3, axis.normalized()) @ nn
            self.N.append(nn)

    def frame(self, t):
        d = max(0.0, min(1.0, t)) * self.cum[-1]
        i = 0
        while i < len(self.cum) - 2 and self.cum[i + 1] < d:
            i += 1
        k = max(0.0, min(1.0, (d - self.cum[i]) / max(self.cum[i + 1] - self.cum[i], 1e-9)))
        c = self.pts[i].lerp(self.pts[i + 1], k)
        tt = self.T[i].lerp(self.T[i + 1], k).normalized()
        nn = self.N[i].lerp(self.N[i + 1], k)
        nn = (nn - tt * nn.dot(tt)).normalized()
        return c, tt, nn, tt.cross(nn)


CORE = [(0.0, 0.3), (0.1, 0.78), (0.28, 1.0), (0.6, 0.9), (0.84, 0.62), (1.0, 0.22)]  # a cola's core along its spine


def cola(bm, spine, radius, rnd, bumps=20, sides=10, rings=8, bump=0.58, pistil_bm=None, pistils=0,
         pistil_len=0.04, pistil_r=0.005, frost=True, curl=False):
    """A bud / cola along a spine curve (it follows its branch): a smooth tapered core (fat low, rounded tip)
    covered in small calyx bumps (squashed low-poly spheres half sunk into the core, golden-angle spiral) plus a
    bump on the very tip. frost: about half the upward-facing bumps use material index 1 (TINT_frost, a lighter
    shade of the strain colour), speckling the cola like trichome frost (the bm then needs two materials).
    Pistils come out of random bumps into pistil_bm: curl=True fresh curly hairs with a blunt tip (flowering),
    else short, shrivelled, pointed ones (ripe). Returns [(centre, size, T, radial)] of the bumps."""
    sp = Spine(spine)
    pts, radii = [], []
    for i in range(rings + 1):
        t = i / rings
        c, tt, nn, bb = sp.frame(t)
        pts.append(c)
        radii.append(radius * table(CORE, t))
    tube(bm, pts, radii, sides=sides, start="round", end="round")
    phase = rnd.uniform(0.0, math.tau)
    placed = []
    for k in range(bumps + 1):
        tip = k == bumps
        t = 1.0 if tip else 0.05 + 0.9 * (k + 0.5) / bumps
        c0, tt, nn, bb = sp.frame(t)
        th = phase + k * 2.39996
        radial = tt if tip else nn * math.cos(th) + bb * math.sin(th)
        R = radius * table(CORE, t)
        size = radius * bump * (table(CORE, t) ** 0.5) * rnd.uniform(0.82, 1.15) * (1.15 if tip else 1.0)
        c = c0 + radial * (R * (1.0 if not tip else 0.9))
        x = perp(radial)
        y = radial.cross(x)
        M = Matrix((x, y, radial)).transposed()
        tmp = bmesh.new()
        bmesh.ops.create_uvsphere(tmp, u_segments=6, v_segments=3, radius=1.0)
        for v in tmp.verts:
            v.co = c + M @ Vector((v.co.x * size, v.co.y * size, v.co.z * size * 0.8))
        vmap = {v: bm.verts.new(v.co) for v in tmp.verts}
        frosty = frost and (tip or (radial + tt * 0.5).normalized().z > 0.1 and rnd.random() < 0.55)
        for fc in tmp.faces:
            nf = bm.faces.new([vmap[v] for v in fc.verts])
            if frosty:
                nf.material_index = 1
        tmp.free()
        placed.append((c, size, tt, radial))
    if pistil_bm is not None and pistils > 0:
        order = sorted(range(len(placed)), key=lambda i: rnd.random())
        for j in range(pistils):
            c, size, tt, radial = placed[order[j % len(order)]]
            side = tt.cross(radial)
            a = rnd.uniform(-1.0, 1.0)
            out = (radial * 0.85 + side * a * 0.6 + tt * rnd.uniform(0.1, 0.6)).normalized()
            p0 = c + out * size * 0.6
            ln = pistil_len * rnd.uniform(0.8, 1.2)
            # a hair, not a thorn: it leaves the calyx at a slant, then curls up along the bud and to one side
            p1 = p0 + (out * 0.55 + tt * 0.7 + side * a * 0.3).normalized() * ln * 0.55
            p2 = p1 + (tt * 0.45 - out * 0.25 + side * a * 0.9).normalized() * ln * 0.45
            if curl:  # fresh white hair: curls over, blunt tip
                p2 = p1 + (tt * 0.3 - out * 0.45 + side * a * 0.8).normalized() * ln * 0.5
                tube(pistil_bm, [p0, p1, p2], [pistil_r, pistil_r * 0.92, pistil_r * 0.8], sides=3, start=None,
                     end="round")
            else:  # ripe: short, shrivelled, pointed
                tube(pistil_bm, [p0, p1], [pistil_r, pistil_r * 0.8], sides=3, start=None, end="point", end_point=p2)
    return placed


# ============================================================================================ poses
def pose(w, **healthy):
    """Leaf pose for wilt w (0 healthy .. 1 wilted). Healthy values can be overridden per leaf."""
    h = dict(rise=36.0, sag=16.0, pitch=32.0, cup=0.14, droop=0.5, lift=0.2, spread=1.0, fold=0.15)
    h.update(healthy)
    d = dict(rise=h["rise"] * 0.35, sag=h["sag"] + 62.0, pitch=-58.0, cup=-0.35, droop=1.25, lift=0.0,
             spread=0.62, fold=0.42)
    return {k: h[k] + (d[k] - h[k]) * w for k in h}


# ============================================================================================ assembly
class Kit:
    """Per-model bmesh buckets: key -> (bmesh, [materials]); faces pick a material with material_index."""

    def __init__(self, seed):
        self.rnd = random.Random(seed)
        self.parts = {}

    def bm(self, key, *materials):
        if key not in self.parts:
            self.parts[key] = (bmesh.new(), list(materials))
        return self.parts[key][0]

    def objects(self, prefix, keys=None, spread=1.0):
        """One Blender object per non-empty bucket (closed meshes: face normals recalculated outwards).
        spread: horizontal scale about the stem (fills the 1.5 m tray without making the plant taller)."""
        objs = []
        for key in sorted(k for k in self.parts if keys is None or k in keys):
            bm, materials = self.parts.pop(key)
            if not bm.faces:
                bm.free()
                continue
            if spread != 1.0:
                for v in bm.verts:
                    v.co.x *= spread
                    v.co.y *= spread
            bmesh.ops.recalc_face_normals(bm, faces=bm.faces[:])
            if OPTIONS.get("verbose") or PRINT_TRIS:
                print("    %-16s %-8s %5d tris" % (prefix, key, sum(len(f.verts) - 2 for f in bm.faces)))
            me = bpy.data.meshes.new("%s_%s" % (prefix, key))
            bm.normal_update()
            bm.to_mesh(me)
            bm.free()
            ob = bpy.data.objects.new("%s_%s" % (prefix, key), me)
            bpy.context.scene.collection.objects.link(ob)
            ob["gwf_smooth"] = 180.0
            for m in materials:
                me.materials.append(m)
            objs.append(ob)
        return objs


def mats():
    return {
        "lime": lib("lime"), "leaf": lib("leaf"), "dry": lib("leaf_dry"),
        "cream": lib("cream"), "rust": lib("rust"),
        "bud": tint_material("TINT_bud", finish="glow"),
        "frost": tint_material("TINT_frost", shade=1.18, finish="glow"),
    }


def pair(leaf_bm, path, f, yaw, spec, w, rnd):
    """An opposite pair of fan leaves at node f of a shoot (cannabis: opposite, decussate in veg)."""
    nf, size, pet, rise, sag = spec
    p, t = path.at(f)
    r = path.radius(f)
    out = []
    for k in (0, 180):
        y = yaw + k + rnd.uniform(-10, 10)
        fan_leaf(leaf_bm, p + horiz(y) * r * 0.4, y, nf, size, pet, pose(w, rise=rise, sag=sag), rnd=rnd)
        out.append(y)
    return p, t, r, out


def tuft(bm, p, t, yaw, w, rnd, n=2, size=0.05):
    """New growth at a shoot tip: small leaves pointing up, folded like a closed hand."""
    for k in range(n):
        fan_leaf(bm, p - t * 0.006, yaw + k * 360.0 / n + rnd.uniform(-15, 15), 3 if k < 2 else 1, size, 0.008,
                 pose(w, rise=64, sag=8, pitch=44, droop=0.3, spread=0.8, cup=0.3), rnd=rnd)


# ============================================================================================ seedling
def seedling(w, name):
    reset()
    m = mats()
    kit = Kit(11)
    rnd = kit.rnd
    green = m["dry"] if w else m["lime"]
    stem_bm = kit.bm("stem", m["lime"])
    leaf_bm = kit.bm("leaf", green)
    base_ctrl = [(0, 0, 0), (0, 0, 0.025), (0.003, 0.002, 0.055), (0.006, 0.0, 0.085), (0.005, -0.002, 0.12),
                 (0.003, 0.0, 0.15), (0.002, 0.001, 0.168)]
    # wilted: the soft hypocotyl gives way and the whole top flops over to the side
    ctrl = bend_chain(base_ctrl, 0.06, 80.0, (0.8, -0.6, 0.0), power=1.1) if w else base_ctrl
    path = Path(ctrl, 0.0072, 0.005)
    ref = Path(base_ctrl, 1, 1)
    f_cot, f_n1, f_n2 = ref.f_at_z(0.08), ref.f_at_z(0.118), ref.f_at_z(0.152)
    stalk(stem_bm, path, nodes=(f_cot, f_n1, f_n2), sides=8, step=0.02, bulge=0.28, flare=0.35)
    yaw0 = 20.0  # every pair turned 90 degrees from the last (decussate); none of them points at the camera
    # cotyledons: round, smooth, short-stalked, nearly level
    p, _ = path.at(f_cot)
    for k in (0, 180):
        fan_leaf(leaf_bm, p, yaw0 + k + rnd.uniform(-6, 6), 1, 0.068, 0.014,
                 pose(w, rise=24, sag=18, pitch=14, droop=0.3, lift=0.1, fold=0.1),
                 width=0.66, profile=OVAL, teeth=0, thick=0.012, pet_r=0.0042, rnd=rnd)
    # first true leaves: one serrated blade each
    p, _ = path.at(f_n1)
    for k in (90, 270):
        fan_leaf(leaf_bm, p, yaw0 + k + 25 + rnd.uniform(-8, 8), 1, 0.1, 0.022,
                 pose(w, rise=44, sag=14, pitch=32, droop=0.55), width=0.4, thick=0.01, pet_r=0.0038, rnd=rnd)
    # second pair: three fingers
    p, _ = path.at(f_n2)
    for k in (0, 180):
        fan_leaf(leaf_bm, p, yaw0 + k + 12 + rnd.uniform(-8, 8), 3, 0.115, 0.028,
                 pose(w, rise=46, sag=16, pitch=26, droop=0.55), width=0.36, thick=0.01, pet_r=0.0038, rnd=rnd)
    # new growth: a tiny tuft on top
    p, t = path.at(1.0)
    for k in (90, 270):
        fan_leaf(leaf_bm, p - t * 0.004, yaw0 + k + 25, 1, 0.042, 0.004,
                 pose(w, rise=70, sag=6, pitch=58, droop=0.2, lift=0.2), width=0.42, teeth=1, thick=0.008,
                 pet_r=0.003, rnd=rnd)
    leaves = join(kit.objects("seedling"), "Leaves")
    leaves.data.transform(Matrix.Scale(SEEDLING_SCALE, 4))
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
    base_ctrl = [(0, 0, 0), (0, 0, 0.05), (0.004, 0.002, 0.16), (0.0, 0.006, 0.3), (-0.006, 0.002, 0.43),
                 (-0.003, -0.003, 0.53), (0.001, 0.0, 0.6)]
    ctrl = bend_chain(base_ctrl, 0.34, 75.0, (-0.6, -0.8, 0.0)) if w else base_ctrl
    path = Path(ctrl, 0.017, 0.0075)
    ref = Path(base_ctrl, 1, 1)  # node positions from the upright plant, so the wilted one keeps its nodes
    fs = [ref.f_at_z(z) for z in (0.08, 0.18, 0.29, 0.4, 0.49)]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.05, bulge=0.3, flare=0.3)
    #        fingers, size, petiole, rise, sag  (old 3-finger leaves low, the biggest fans in the middle)
    spec = [(3, 0.15, 0.065, 18, 38), (5, 0.24, 0.1, 28, 26), (7, 0.32, 0.13, 34, 20), (7, 0.28, 0.11, 38, 16),
            (5, 0.19, 0.06, 46, 14)]
    yaw = 15.0
    for i, (f, sp) in enumerate(zip(fs, spec)):
        p, t, r, yaws = pair(leaf_bm, path, f, yaw, sp, w, rnd)
        if i in (1, 2):  # side shoots from the lower axils (apical dominance keeps them below the leader)
            for k, y in enumerate(yaws):
                branch(p, y + (24 if k else -24), w, stem_bm, leaf_bm, rnd, low=(i == 1))
        yaw += 90.0 + rnd.uniform(-12, 12)
    p, t = path.at(1.0)
    tuft(leaf_bm, p, t, yaw, w, rnd, n=3, size=0.09)
    leaves = join(kit.objects("veg", spread=SPREAD["vegetative"]), "Leaves")
    export(leaves, name, kind="part", mount="floor", budget=BUDGET)


def branch(start, yaw, w, stem_bm, leaf_bm, rnd, low=True):
    """A vegetative side shoot: out at ~50 degrees from its axil, curving up, one leaf pair and a tip tuft."""
    d = horiz(yaw)
    k = 1.0 if low else 0.8
    ctrl = [start, start + d * 0.05 * k + UP * 0.03, start + d * 0.13 * k + UP * 0.08 * k,
            start + d * 0.18 * k + UP * 0.14 * k, start + d * 0.2 * k + UP * 0.17 * k]
    if w:  # limp: the shoot arcs over and hangs
        ctrl = bend_chain(ctrl, start.z + 0.02, 100.0, d, power=1.4)
    path = Path(ctrl, 0.0075, 0.005)
    nodes = (0.42, 0.78) if low else (0.5,)
    stalk(stem_bm, path, nodes=nodes, sides=6, step=0.06, bulge=0.3)
    for j, fn in enumerate(nodes):  # decussate pairs along the shoot too
        p, t = path.at(fn)
        for k in (90, 270):
            fan_leaf(leaf_bm, p, yaw + k + 90 * j + rnd.uniform(-10, 10), 5, 0.17 - 0.04 * j, 0.05 - 0.015 * j,
                     pose(w, rise=34 + 8 * j, sag=20), rnd=rnd)
    p, t = path.at(1.0)
    tuft(leaf_bm, p, t, yaw + 90, w, rnd, n=1, size=0.07)


# ============================================================================================ flowering
def flowering(w, name):
    reset()
    m = mats()
    kit = Kit(37)
    rnd = kit.rnd
    green = m["dry"] if w else m["leaf"]
    stem_bm = kit.bm("stem", m["lime"])
    leaf_bm = kit.bm("leaf", green)
    bud_bm = kit.bm("bud", m["bud"])
    pis_bm = kit.bm("pistil", m["cream"])
    base_ctrl = [(0, 0, 0), (0, 0, 0.06), (0.004, 0.003, 0.22), (0.0, 0.006, 0.42), (-0.006, 0.0, 0.6),
                 (-0.003, -0.005, 0.7), (0.0, -0.003, 0.76)]
    ctrl = bend_chain(base_ctrl, 0.5, 50.0, (0.6, -0.8, 0.0)) if w else base_ctrl
    path = Path(ctrl, 0.022, 0.0095)
    ref = Path(base_ctrl, 1, 1)
    fs = [ref.f_at_z(z) for z in (0.07, 0.17, 0.29, 0.42, 0.55, 0.66)]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.09, bulge=0.26, flare=0.3, tip=None, end=0.97)
    #        fingers, size, petiole, rise, sag, kind (fan leaves stay big and low, the top is all bud sites)
    spec = [(5, 0.26, 0.13, 16, 42, None), (7, 0.3, 0.14, 24, 30, "branch"), (7, 0.26, 0.12, 28, 26, "branch"),
            (5, 0.19, 0.08, 34, 20, None), (1, 0.11, 0.04, 40, 14, "site")]
    yaw = 35.0
    for i, (f, sp) in enumerate(zip(fs, spec)):
        p, t, r, yaws = pair(leaf_bm, path, f, yaw, sp[:5], w, rnd)
        for k, y in enumerate(yaws):
            if sp[5] == "branch":
                flower_branch(p, y + (20 if k else -20), w, stem_bm, leaf_bm, bud_bm, pis_bm, rnd, long=(i == 1))
            elif sp[5] == "site":
                # a bud site in the axil: a small calyx cluster pushing up beside the stem, white hairs
                d = horiz(y + 25)
                q = p + d * r * 1.3
                cola(bud_bm, [q, q + (d * 0.3 + t).normalized() * 0.065], 0.022, rnd, bumps=4, sides=6, rings=3,
                          bump=0.62, frost=False, curl=True, pistil_bm=pis_bm, pistils=3, pistil_len=0.042,
                          pistil_r=0.0048)
        yaw += 90.0 + rnd.uniform(-12, 12)
    # the apical bud forming: a spear of calyx clusters on the leader, white pistils, sugar leaves
    p, t = path.at(1.0)
    ax = (t + UP * 0.6).normalized() if not w else t
    q = p - t * 0.06
    cola(bud_bm, [q, p + ax * 0.07, p + ax * 0.18], 0.044, rnd, bumps=11, sides=8, rings=6, bump=0.6,
              frost=False, curl=True, pistil_bm=pis_bm, pistils=12, pistil_len=0.052, pistil_r=0.0052)
    sugar(leaf_bm, q, ax, 0.044, w, rnd, n=2, size=0.085, fingers=1, depth=0.8)
    buds = join(kit.objects("flower", keys=("bud", "pistil"), spread=SPREAD["flowering"]), "Buds")
    leaves = join(kit.objects("flower", spread=SPREAD["flowering"]), "Leaves")
    export([leaves, buds], name, kind="part", mount="floor", budget=BUDGET)


def flower_branch(start, yaw, w, stem_bm, leaf_bm, bud_bm, pis_bm, rnd, long=True):
    """A flowering branch: stretched, reaching up, one fan leaf on the way, a bud forming at the tip."""
    d = horiz(yaw)
    L = 0.42 if long else 0.34
    ctrl = [start, start + d * 0.05 + UP * 0.03, start + d * 0.15 + UP * L * 0.4, start + d * 0.21 + UP * L * 0.78,
            start + d * 0.23 + UP * L]
    if w:  # limp: the branch arcs over and its bud hangs
        ctrl = bend_chain(ctrl, start.z + 0.03, 105.0, d, power=1.4)
    path = Path(ctrl, 0.0095, 0.006)
    fn = 0.42
    stalk(stem_bm, path, nodes=(fn,), sides=5, step=0.08, bulge=0.3, tip=None, end=0.85)
    p, t = path.at(fn)
    fan_leaf(leaf_bm, p, yaw + 80 + rnd.uniform(-10, 10), 5 if long else 3, 0.19 if long else 0.16, 0.06,
             pose(w, rise=34, sag=22), rnd=rnd)
    spine = [path.at(0.8)[0], path.at(1.0)[0]]
    p, t = path.at(1.0)
    spine.append(p + ((t + UP * 0.5).normalized() if not w else t) * 0.05)
    cola(bud_bm, spine, 0.031, rnd, bumps=6, sides=6, rings=4, bump=0.62, frost=False, curl=True,
              pistil_bm=pis_bm, pistils=6, pistil_len=0.048, pistil_r=0.005)
    if long:
        sugar(leaf_bm, spine[0], t, 0.031, w, rnd, n=1, size=0.075, fingers=1, depth=0.8)


def sugar(bm, base, axis, radius, w, rnd, n=3, size=0.06, fingers=None, depth=0.4):
    """Small 1-3 finger sugar leaves poking out of a bud (rooted `depth` x radius out from its axis), pointing out
    and up."""
    axis = Vector(axis).normalized()
    ph = rnd.uniform(0, 360)
    for k in range(n):
        a = ph + k * 360.0 / n + rnd.uniform(-20, 20)
        d = horiz(a)
        start = base + axis * (radius * rnd.uniform(0.3, 1.2)) + d * radius * depth
        nf = fingers or rnd.choice((1, 3, 3))
        fan_leaf(bm, start, a, nf, size * rnd.uniform(0.85, 1.1), 0.006,
                 pose(w, rise=50, sag=6, pitch=42, droop=0.6, lift=0.05, cup=0.25), width=0.28,
                 thick=0.007, pet_r=0.003, rnd=rnd)


# ============================================================================================ ready
def ready(name):
    reset()
    m = mats()
    kit = Kit(53)
    rnd = kit.rnd
    stem_bm = kit.bm("stem", m["lime"])
    leaf_bm = kit.bm("leaf", m["leaf"])
    dry_bm = kit.bm("yellow", m["dry"])
    lean = Vector((1.0, -0.35, 0.0)).normalized()
    base_ctrl = [(0, 0, 0), (0, 0, 0.06), (0.004, 0.003, 0.2), (0.0, 0.006, 0.38), (-0.006, 0.0, 0.54),
                 (-0.004, -0.006, 0.66), (0.0, -0.004, 0.76)]
    # the whole plant leans under the weight of its colas (more towards the top)
    ctrl = [Vector(q) + lean * 0.07 * (Vector(q).z / 0.76) ** 1.8 for q in base_ctrl]
    path = Path(ctrl, 0.026, 0.012)
    fs = [path.f_at_z(z) for z in (0.075, 0.16, 0.27, 0.39, 0.5)]
    stalk(stem_bm, path, nodes=fs, sides=8, step=0.08, bulge=0.24, flare=0.3, tip=None, end=path.f_at_z(0.6))
    colas = []

    def new_cola(label):
        part = Kit(0)
        part.bm("bud", m["bud"], m["frost"])
        part.bm("pistil", m["rust"])
        colas.append((label, part))
        return part

    # the main cola: a long heavy spear on the leader (which ends inside it), leaning with the plant
    top = new_cola("ColaTop")
    f0 = path.f_at_z(0.55)
    spine = [path.at(f)[0] for f in (f0, (f0 + 1.0) / 2, 1.0)]
    p, t = path.at(1.0)
    ax = (t * 0.75 + UP * 0.25 + lean * 0.1).normalized()
    spine += [p + ax * 0.13, p + ax * 0.25 + lean * 0.03]
    top.base_point = spine[0]
    cola(top.bm("bud"), spine, 0.074, rnd, bumps=21, sides=8, rings=8, pistil_bm=top.bm("pistil"),
              pistils=12, pistil_len=0.042, pistil_r=0.0052)
    sugar(leaf_bm, spine[1], ax, 0.07, 0.0, rnd, n=3, size=0.1, fingers=1, depth=0.85)
    sugar(leaf_bm, spine[2], ax, 0.07, 0.0, rnd, n=2, size=0.1, fingers=1, depth=0.8)
    sugar(leaf_bm, spine[3], ax, 0.05, 0.0, rnd, n=1, size=0.08, fingers=1, depth=0.8)
    #        fingers, size, petiole, rise, sag, kind: "yellow" lower fans, "branch"
    spec = [(3, 0.25, 0.13, 10, 66, "yellow"), (7, 0.3, 0.14, 16, 52, "yellow"), (7, 0.27, 0.12, 26, 36, "branch"),
            (5, 0.21, 0.08, 32, 28, "branch"), (0, 0.0, 0.0, 0, 0, "side")]
    yaw = 20.0
    n_branch = 0
    for i, (f, (nf, size, pet, rise, sag, kind)) in enumerate(zip(fs, spec)):
        p, t = path.at(f)
        r = path.radius(f)
        for k in (0, 180):
            y = yaw + k + rnd.uniform(-10, 10)
            if nf and not (i == 0 and k == 180):  # one old fan leaf has already dropped
                sick = kind == "yellow"
                fingers = 5 if k == 180 and i in (1, 2) else nf  # the plant is running out of big leaves
                fan_leaf(dry_bm if sick or (i == 2 and k == 180) else leaf_bm, p + horiz(y) * r * 0.4, y, fingers,
                         size, pet, pose(0.5 if sick else 0.12, rise=rise, sag=sag), rnd=rnd)
            if kind == "branch":
                n_branch += 1
                heavy_branch(new_cola("Cola%d" % n_branch), p, y + (22 if k else -22), stem_bm, leaf_bm, rnd,
                             long=(i == 2), leaf=(k == 0))
            elif kind == "side":
                d = horiz(y + 25)
                q = p + d * r
                cola(top.bm("bud"), [q, q + (d * 0.45 + t).normalized() * 0.11], 0.032, rnd, bumps=3, sides=6,
                          rings=4, pistil_bm=top.bm("pistil"), pistils=2, pistil_len=0.03)
        yaw += 90.0 + rnd.uniform(-12, 12)

    sp = SPREAD["ready"]
    leaves = join(kit.objects("ready", spread=sp), "Leaves")
    buds = empty("Buds")
    for label, part in colas:
        o = part.base_point
        c = join(part.objects(label, spread=sp), label, origin=(o.x * sp, o.y * sp, o.z))
        set_parent(c, buds)
    export([leaves, buds], name, kind="part", mount="floor", budget=BUDGET)


def heavy_branch(part, start, yaw, stem_bm, leaf_bm, rnd, long=True, leaf=True):
    """A ready branch: out and up, then bowed over by the cola along its upper half."""
    dh = horiz(yaw)
    L = 0.42 if long else 0.34
    ctrl = [start, start + dh * 0.06 + UP * 0.035, start + dh * 0.17 + UP * L * 0.45,
            start + dh * 0.26 + UP * L * 0.8, start + dh * 0.32 + UP * L * 0.88]
    path = Path(ctrl, 0.011, 0.007)
    fn = 0.36
    stalk(stem_bm, path, nodes=(fn,), sides=5, step=0.08, bulge=0.3, tip=None, end=0.6)
    if leaf:
        p, t = path.at(fn)
        fan_leaf(leaf_bm, p, yaw + 75 + rnd.uniform(-10, 10), 5, 0.2, 0.06, pose(0.15, rise=32, sag=26), rnd=rnd)
    spine = [path.at(f)[0] for f in (0.52, 0.76, 1.0)]
    p, t = path.at(1.0)
    spine.append(p + (t * 0.6 + dh * 0.35 + UP * 0.05).normalized() * 0.07)
    part.base_point = spine[0]
    cola(part.bm("bud"), spine, 0.052, rnd, bumps=10, sides=7, rings=6, pistil_bm=part.bm("pistil"),
              pistils=6, pistil_len=0.036)
    sugar(leaf_bm, spine[1], t, 0.05, 0.0, rnd, n=2, size=0.085, fingers=1, depth=0.85)


# ============================================================================================ build
def build():
    seedling(0.0, "plant_seedling")
    seedling(1.0, "plant_seedling_dry")
    vegetative(0.0, "plant_vegetative")
    vegetative(1.0, "plant_vegetative_dry")
    flowering(0.0, "plant_flowering")
    flowering(1.0, "plant_flowering_dry")
    ready("plant_ready")
