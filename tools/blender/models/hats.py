"""hats: issued kit (M16 hats agent; FRIENDSLOP 10.2, CONTRACTS "M16 / Hats"). Seven hats and the locker they are in.

Every hat is ONE mesh, kind "item" (front on Godot -Z, like the worker), mount "free", authored in the HEAD SOCKET's
space: the origin is the seat of the stock hard hat on the worker's head (player.py `hat_matrix()`, exported there
as the empty `HatSocket`), +Z runs up the hat's own axis (the socket already leans with the slump and is knocked
crooked), the front is -Y. scripts/player/player.gd hides the stock hat (`Visual/Model/Hat`) and instances the
issued one under `Visual/Model/HatSocket` (Hats.make, scripts/core/hats.gd).

What a hat has to cover: under the stock hat the head is "tucked" 3.5 cm inside the hat's dome (player.py
`tuck_head`), and the body's 2.5 cm ink hull follows it. So every hat here encloses the stock dome less 1 cm
(`check_cover` casts rays out of that surface and prints what gets through), and is at least RIM_R wide at the seat,
where the untucked head (radius 0.29) and its hull come up from below.

hat_hairnet       a disposable bouffant cap, washed-out blue, slumped to the back, stained (one shift worked)
hat_paper_cap     a tall folded paper cap with a faded stripe, one end crushed, taped (ten shifts)
hat_hard_hat      a yellow hard hat that fits, a dead torch taped to the front (best shift 3)
hat_cone          a traffic cone, the tip bent, one corner of the base curled, a tyre mark (back room x3)
hat_bucket        a tin bucket upside down, bitten at the rim, the handle hanging behind (bitten x5)
hat_welding_mask  a leather cap, a headband and the mask swung up over the forehead, sooty (five plants burnt)
hat_bandage       a head wrapped in gauze, one old stain, a loose end (shot x3)
locker            the alley's steel locker (prop, floor, origin under the centre of the footprint, front +Z in Godot):
                  `Body` (static) + `Door` (the right-hand door, pivot on its hinge edge, rest = shut;
                  scripts/world/locker.gd holds it ajar and swings it). TINT_paint + TINT_trim (give the root a tint).
"""
import os
import sys

import bmesh
import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
import player as P                    # noqa: E402  (the stock hard hat's profile; nothing is built on import)

HS = P.HAT_SCALE                      # the stock hat is the 0.33 m profile at 0.88
SEAT_R = P.HAT_PROF[0][0] * HS        # 0.29: the head's radius at the seat
TOP = P.HAT_PROF[-1][1] * HS          # 0.255: the stock dome's top above the seat
RIM_R = 0.322                         # every hat is at least this wide at the seat
BUDGET = 2500                         # round shapes at 24-28 segments; the default item budget is for held things


def stock_r(z):
    """Radius of the stock hat's dome at height z above the seat."""
    return P.dome_r(max(0.0, z) / HS) * HS


def crown_profile(grow, z0=-0.02):
    """The stock dome `grow` metres fatter, as a lathe profile from z0 below the seat to the pole: the least a
    liner (a leather cap, a wrap of gauze) has to be to hide the tucked head."""
    prof = [(SEAT_R + grow, z0)]
    for r, z in P.HAT_PROF[:-1]:
        zz = z * HS
        prof.append((r * HS + grow, zz + grow * zz / TOP))
    prof.append((0.0, TOP + grow))
    return prof


def on_ring(radius, deg, z):
    """A point `radius` out from the hat's axis, `deg` degrees round from the front (-Y) towards +X."""
    a = math.radians(deg)
    return Vector((radius * math.sin(a), -radius * math.cos(a), z))


def patch(radius, deg, z, size, mat, squash=(1.25, 0.18, 1.0), name="patch"):
    """A flat blob lying on a round body: stains, soot, scuffs."""
    s = sphere(size, scale=squash, segments=8, rings=4, mat=mat, name=name)
    s.location = on_ring(radius, deg, z)
    s.rotation_euler = (0, 0, math.radians(deg))
    apply_transform(s)
    return s


def strap(yaw_deg, width, lift, mat, name, span=(-1.0, 1.0), thick=0.012, grow=0.0, steps=14):
    """A flat strip lying over the crown from one side of the seat to the other, across the top (a meridian
    turned `yaw_deg` round the axis). span: -1 = the seat on one side, 0 = the pole, +1 = the seat opposite."""
    yaw = math.radians(yaw_deg)
    along = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    side = Vector((-math.sin(yaw), math.cos(yaw), 0.0))
    centre = Vector((0.0, 0.0, 0.02))

    def fn(u, v):
        s = span[0] + (span[1] - span[0]) * u
        z = TOP * math.cos(min(1.0, abs(s)) * math.pi / 2)
        r = (stock_r(z) + grow) * (1 if s >= 0 else -1)
        p = along * r + Vector((0.0, 0.0, z + grow * z / TOP)) + side * ((v - 0.5) * width)
        n = (p - centre).normalized()
        return p + n * (lift + thick), p + n * (lift - 0.004)
    return P.shell(fn, steps, 1, name, mat, smooth=60.0)


def check_cover(obj, name):
    """Casts rays out of the tucked head's ink hull (the stock dome less 1 cm): one that leaves without meeting
    the hat is a spot where the head would show through."""
    from mathutils.bvhtree import BVHTree
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.transform(obj.matrix_world)
    tree = BVHTree.FromBMesh(bm)
    total = miss = 0
    for k in range(13):
        z = (TOP - 0.012) * k / 12
        r = stock_r(z) - 0.01
        for i in range(24):
            a = 2 * math.pi * i / 24
            p = Vector((r * math.cos(a), r * math.sin(a), z))
            d = Vector((math.cos(a), math.sin(a), 0.3 + 1.6 * z / TOP)).normalized()
            total += 1
            if tree.ray_cast(p, d)[0] is None:
                miss += 1
    bm.free()
    print("  %s: covers the head at %d of %d points%s" % (
        name, total - miss, total, "" if miss == 0 else "   WARN: the head shows through"))
    return miss


def finish(parts, name):
    hat = join(parts, "Hat")
    check_cover(hat, name)
    export(hat, name, kind="item", mount="free", budget=BUDGET)


def grime_mat():
    return material("grime", P.mix(P.OLIVE, pal("INK"), 0.42), "matte")


# ======================================================================================================== hats
def make_hairnet():
    net = material("hairnet", P.mix(pal("SKY"), pal("WHITE"), 0.62), "matte")
    prof = [(0.300, -0.035), (0.326, -0.02), (0.340, 0.02), (0.352, 0.08), (0.346, 0.15), (0.318, 0.21),
            (0.262, 0.262), (0.18, 0.295), (0.09, 0.31), (0.0, 0.314)]
    cap = lathe(prof, verts=28, mat=net, name="cap", smooth=180)

    def slump(co):
        # A bag of thin cloth with nothing in it: the top falls to the back, the puff is uneven.
        t = max(0.0, co.z) / 0.314
        a = math.atan2(co.y, co.x)
        k = 1.0 + 0.035 * math.sin(3 * a + 0.7) * t
        return Vector((co.x * k, co.y * k + 0.05 * t * t, co.z - 0.012 * t * t * (1 + math.sin(2 * a))))
    move_verts(cap, slump)
    dent(cap, (0.27, -0.2, 0.2), radius=0.13, depth=0.022)
    dent(cap, (-0.31, 0.1, 0.13), radius=0.12, depth=0.02)
    elastic = torus(0.318, 0.02, pos=(0, 0, -0.014), major_segments=28, minor_segments=6, mat="white",
                    name="elastic")
    gather = sphere(0.034, pos=on_ring(0.335, 172, -0.01), scale=(1.2, 0.8, 0.9), segments=8, rings=5,
                    mat="white", name="gather")
    stains = [patch(0.343, -38, 0.1, 0.05, grime_mat(), name="stain"),
              patch(0.335, 105, 0.17, 0.034, grime_mat(), squash=(1.0, 0.2, 1.3), name="stain")]
    return [cap, elastic, gather] + stains


def make_paper_cap():
    paper = lib("cream")
    tape = material("tape", P.mix(pal("HONEY_WOOD"), pal("CREAM"), 0.45), "matte")
    r0, z0, eave, ridge, half = RIM_R, -0.03, 0.13, 0.375, 0.2
    n = 28
    bm = bmesh.new()
    rows = []
    for z, t in ((z0, None), (eave * 0.5, None), (eave, 0.0), (None, 0.25), (None, 0.5), (None, 0.75), (None, 1.0)):
        ring = []
        for i in range(n):
            a = 2 * math.pi * i / n
            x0, y0 = r0 * math.cos(a), r0 * math.sin(a)
            if t is None or t == 0.0:
                ring.append(bm.verts.new((x0, y0, z)))
            else:
                # From the round band up to a fold running front to back: a ruled surface, the fold left a
                # finger wide so the top is a strip, not a knife edge.
                yr = max(-half, min(half, y0))
                keep = max(1.0 - t, 0.035)
                ring.append(bm.verts.new((x0 * keep, y0 * (1 - t) + yr * t, eave + (ridge - eave) * t)))
        rows.append(ring)
    for a, b in zip(rows, rows[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    bm.faces.new(rows[-1])
    bm.faces.new(list(reversed(rows[0])))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    cap = P.mesh_obj("cap", bm, paper, smooth=40.0)

    def tired(co):
        # The fold sags in the middle and leans; the front end has been sat on.
        if co.z <= eave:
            return co
        t = (co.z - eave) / (ridge - eave)
        sag = 0.03 * t * math.cos(co.y / half * math.pi / 2) ** 2
        crush = 0.075 * t * max(0.0, (-co.y - 0.05) / 0.15) ** 1.5
        return Vector((co.x + 0.03 * t * t, co.y, co.z - sag - min(crush, 0.085)))
    move_verts(cap, tired)
    stripe = band(r0 + 0.001, 0.02, 0.075, thickness=0.004, verts=n, mat="blue", name="stripe")
    strip = arc_panel(r0 + 0.003, 0.15, angle=9, thickness=0.004, pos=(0, 0, -0.02), rot=(0, 0, 148),
                      segments=3, mat=tape, name="tape")
    cross = arc_panel(r0 + 0.006, 0.04, angle=24, thickness=0.004, pos=(0, 0, 0.045), rot=(0, 0, 149),
                      segments=5, mat=tape, name="tape")
    stains = [patch(r0 + 0.003, -52, 0.085, 0.05, grime_mat(), squash=(1.3, 0.14, 0.8), name="stain"),
              patch(r0 + 0.003, 60, 0.03, 0.03, grime_mat(), squash=(1.0, 0.2, 1.2), name="stain")]
    return [cap, stripe, strip, cross] + stains


def make_hard_hat():
    shell_mat = lib("caution")
    tape = material("tape", P.mix(pal("HONEY_WOOD"), pal("CREAM"), 0.45), "matte")
    s = 0.97                                               # this one fits (the stock one is the profile at 0.88)
    dome = lathe([(r * s, z * s) for r, z in P.HAT_PROF], verts=24, mat=shell_mat, name="dome", smooth=60)
    dent(dome, (-0.21, -0.15, 0.2), radius=0.11, depth=0.022)
    dent(dome, (0.25, 0.15, 0.13), radius=0.09, depth=0.02)
    ridge = []
    for k in range(15):                                    # front -> over the top -> back
        t = -1.0 + 2.0 * k / 14
        z = 0.085 + (0.29 - 0.085) * (1 - abs(t)) ** 0.45 if abs(t) < 1 else 0.085
        ridge.append(Vector((0.0, (P.dome_r(z) + 0.006) * (1 if t > 0 else -1) * s, z * s)))
    ridge[7] = Vector((0.0, 0.0, 0.296 * s))
    ridge = pipe(ridge, 0.024 * s, verts=6, bend=0.0, mat=shell_mat, name="ridge")
    brim = lathe([(r * s, z * s) for r, z in ((0.3, 0.012), (0.37, 0.0), (0.382, -0.012), (0.37, -0.02),
                                              (0.3, -0.01))], verts=24, mat=shell_mat, name="brim", smooth=70,
                 closed=True)

    def peak(co):
        a = math.atan2(co.x, -co.y)                        # 0 = front
        k = max(0.0, math.cos(a)) ** 2.2
        r = math.hypot(co.x, co.y)
        grow = 0.07 * k * max(0.0, (r - 0.3 * s) / 0.08)
        f = (r + grow) / r if r > 1e-6 else 1.0
        return Vector((co.x * f, co.y * f, co.z - 0.04 * k * max(0.0, (r - 0.3 * s) / 0.1)))
    move_verts(brim, peak)
    # A torch that died long ago, held on with tape: once round the dome, once over the torch.
    zl = 0.118
    rl = P.dome_r(zl / s) * s
    wrap = band(lambda z: P.dome_r(z / s) * s + 0.001, 0.088, 0.132, thickness=0.004, verts=24, rows=2, mat=tape,
                name="wrap")
    torch = cyl(0.046, 0.135, verts=12, pos=(0.012, -(rl - 0.045), zl + 0.03), rot=(84, 0, 5), bevel=0.008,
                mat="metal_dark", name="torch")
    lens = cyl(0.037, 0.012, verts=12, pos=(0.0, 0.0, 0.133), bevel=0.0, mat="gray", name="lens")
    collar = torus(0.046, 0.012, pos=(0.0, 0.0, 0.126), major_segments=12, minor_segments=5, mat="metal_dark",
                   name="collar")
    for o in (lens, collar):                               # built on the torch's own axis, then laid along it
        o.rotation_euler = torch.rotation_euler
        o.location = torch.location + torch.rotation_euler.to_matrix() @ Vector(o.location)
    over = box((0.15, 0.06, 0.012), pos=(0.012, -(rl + 0.01), zl + 0.073), rot=(-6, 3, 5), bevel=0.004, mat=tape,
               name="over")
    scuffs = [patch(P.dome_r(0.17 / s) * s, 118, 0.17, 0.045, grime_mat(), squash=(1.5, 0.12, 0.6), name="scuff"),
              patch(P.dome_r(0.08 / s) * s, -100, 0.08, 0.03, grime_mat(), squash=(1.2, 0.15, 1.2), name="scuff")]
    return [dome, ridge, brim, wrap, torch, lens, collar, over] + scuffs


def make_cone():
    orange = lib("orange")
    z_lo, z_hi, r_lo, r_hi, rows = 0.015, 0.56, 0.325, 0.07, 8
    prof = [(0.345, -0.012)]
    prof += [(r_lo + (r_hi - r_lo) * k / rows, z_lo + (z_hi - z_lo) * k / rows) for k in range(rows + 1)]
    prof += [(0.052, 0.577), (0.0, 0.582)]
    body = lathe(prof, verts=24, mat=orange, name="cone", smooth=50)
    step = (z_hi - z_lo) / rows
    # The reflective collar (two rows of faces) and what a tyre left lower down, painted before anything bends.
    paint(body, lib("cream"), lambda c, n: z_lo + 4 * step < c.z < z_lo + 6 * step)
    paint(body, lib("dark"), lambda c, n: z_lo + step < c.z < z_lo + 2 * step and c.x > 0.05 and c.y < 0.12)

    def bent(co):
        t = max(0.0, (co.z - 0.3) / 0.28)
        return Vector((co.x + 0.075 * t * t, co.y + 0.03 * t * t, co.z - 0.02 * t * t))
    move_verts(body, bent)
    dent(body, (-0.14, -0.13, 0.4), radius=0.16, depth=0.035)
    base = subdivide(box((0.7, 0.7, 0.045), pos=(0, 0, -0.033), bevel=0.018, mat=orange, name="base"), 4)

    def curled(co):
        d = max(0.0, co.x + co.y - 0.42)                   # the back right corner has been driven over
        e = max(0.0, -co.x - co.y - 0.5)
        return Vector((co.x, co.y, co.z + 0.3 * d + 0.12 * e))
    move_verts(base, curled)
    base.rotation_euler = (0, 0, math.radians(9))
    return [body, base]


def make_bucket():
    tin = lib("metal")
    z_lo, z_hi, r_lo, r_hi, rows = -0.012, 0.3, 0.333, 0.272, 6

    def wall(z):
        return r_lo + (r_hi - r_lo) * (z - z_lo) / (z_hi - z_lo)
    prof = [(0.33, -0.032)]
    prof += [(wall(z_lo + (z_hi - z_lo) * k / rows), z_lo + (z_hi - z_lo) * k / rows) for k in range(rows + 1)]
    prof += [(0.266, 0.312), (0.25, 0.312), (0.244, 0.298), (0.0, 0.298)]     # its bottom, now on top, set in
    body = lathe(prof, verts=28, mat=tin, name="bucket", smooth=50)
    rim = torus(0.334, 0.017, pos=(0, 0, -0.03), major_segments=28, minor_segments=6, mat=tin, name="rim")
    apply_transform(rim)
    ribs = [band(wall, z, z + 0.022, thickness=0.006, verts=28, mat=tin, name="rib") for z in (0.085, 0.2)]
    rust = band(wall, -0.03, 0.035, thickness=0.004, verts=28, rows=1, mat="rust", name="rust",
                top=lambda a: 0.03 * math.sin(5 * a + 0.6) + 0.018 * math.sin(11 * a))
    # Something got its teeth into the rim (front left as the others see it) and something heavy hit the side.
    bite = on_ring(0.333, 34, -0.03)
    for o in (body, rim, rust):
        dent(o, bite, radius=0.1, depth=0.055, direction=(-0.25, 0.45, 1.0))
        dent(o, (-0.27, 0.12, 0.17), radius=0.15, depth=0.035)
    for o in ribs:
        dent(o, (-0.27, 0.12, 0.17), radius=0.15, depth=0.035)
    teeth = [patch(wall(z) + 0.001, deg, z, 0.015, lib("dark"), squash=(1.0, 0.3, 1.25), name="tooth")
             for deg, z in ((16, 0.05), (25, 0.068), (34, 0.076), (43, 0.068), (52, 0.05))]
    lugs = [box((0.03, 0.06, 0.05), pos=(sx * 0.335, 0, -0.015), bevel=0.008, mat="metal_dark", name="lug")
            for sx in (-1, 1)]
    handle = pipe([(0.35, 0.0, 0.0), (0.37, 0.14, -0.1), (0.27, 0.34, -0.19), (0.0, 0.42, -0.215),
                   (-0.27, 0.34, -0.19), (-0.37, 0.14, -0.1), (-0.35, 0.0, 0.0)], 0.011, verts=6, bend=0.12,
                  mat="metal_dark", name="handle")
    return [body, rim, rust] + ribs + teeth + lugs + [handle]


def make_welding_mask():
    shell_mat = material("mask", P.mix(pal("STONE"), pal("INK"), 0.3), "soft")
    soot = material("soot", P.mix(pal("INK"), pal("STONE"), 0.12), "matte")
    cap = lathe(crown_profile(0.012), verts=24, mat="brown", name="cap", smooth=180)
    dent(cap, (0.16, 0.14, 0.22), radius=0.1, depth=0.012)
    headband = band(0.312, -0.03, 0.04, thickness=0.011, verts=28, mat="dark", name="headband")
    over = strap(0, 0.05, 0.012, lib("dark"), "over", thick=0.01)
    knobs = [cyl(0.045, 0.035, verts=10, pos=(sx * 0.314, 0, 0.005), rot=(0, sx * 90, 0), bevel=0.008,
                 mat="metal_dark", name="knob") for sx in (-1, 1)]
    # The mask is built hanging in front of the face, then swung up on its knobs: worn up, the way it is carried
    # between two fires. A plain curved shield, a framed window, soot from the last five plants.
    shield = arc_panel(0.352, 0.37, angle=118, thickness=0.018, pos=(0, 0, -0.39), segments=12, mat=shell_mat,
                       name="shield")
    brow = arc_panel(0.36, 0.035, angle=122, thickness=0.02, pos=(0, 0, -0.045), segments=12, mat="metal_dark",
                     name="brow")
    frame = arc_panel(0.37, 0.12, angle=48, thickness=0.012, pos=(0, 0, -0.275), segments=6, mat="metal_dark",
                      name="frame")
    window = arc_panel(0.382, 0.075, angle=38, thickness=0.004, pos=(0, 0, -0.2525), segments=6, mat="dark",
                       name="window")
    streaks = [arc_panel(0.37, h, angle=w, thickness=0.003, pos=(0, 0, z), rot=(0, 0, deg), segments=3, mat=soot,
                         name="soot") for deg, w, h, z in ((-36, 15, 0.21, -0.39), (33, 11, 0.13, -0.39),
                                                           (44, 9, 0.11, -0.2))]
    mask = join([shield, brow, frame, window] + streaks, "mask")
    mask.rotation_euler = (math.radians(-66), math.radians(3), math.radians(4))
    apply_transform(mask)
    return [cap, headband, over] + knobs + [mask]


def make_bandage():
    gauze = lib("cream")
    old = material("gauze_old", P.mix(pal("CREAM"), pal("HONEY_WOOD"), 0.3), "matte")
    wrap = lathe(crown_profile(0.008, z0=-0.03), verts=24, mat=gauze, name="wrap", smooth=180)
    brow = band(0.312, -0.035, 0.055, thickness=0.011, verts=28, rows=1, mat=gauze, name="brow",
                top=lambda a: 0.014 * math.sin(3 * a + 0.4))
    turns = [strap(24, 0.085, 0.004, old, "turn"),
             strap(-58, 0.075, 0.012, gauze, "turn", span=(-1.0, 0.85)),
             strap(100, 0.07, 0.018, old, "turn", span=(-0.7, 1.0))]
    # One old stain over the left temple, gone the colour of rust, and the end nobody tucked in.
    stain = [patch(stock_r(0.14) + 0.022, -62, 0.14, 0.062, lib("rust"), squash=(1.2, 0.2, 1.0), name="stain"),
             patch(stock_r(0.085) + 0.024, -47, 0.085, 0.03, lib("rust"), squash=(1.0, 0.25, 1.3), name="stain")]
    back = on_ring(0.325, 168, 0.0)
    knot = sphere(0.036, pos=back, scale=(1.2, 0.8, 1.0), segments=8, rings=5, mat=gauze, name="knot")
    ends = [pipe([back + Vector((dx * 0.01, 0.01, 0.0)), back + Vector((dx * 0.04, 0.035, -0.08)),
                  back + Vector((dx * 0.05, 0.03, -0.17 - 0.03 * dx))], 0.013, verts=5, mat=gauze, name="end")
            for dx in (-1, 1)]
    return [wrap, brow] + turns + stain + [knot] + ends


# ====================================================================================================== locker
def build_locker():
    reset()
    paint_mat = tint_material("TINT_paint")
    trim = tint_material("TINT_trim", shade=0.72)
    steel = lib("metal_dark")
    w, d, h, foot = 0.86, 0.5, 1.88, 0.07
    front = -d / 2
    body = subdivide(box((w, d, h - foot), pos=(0, 0, foot), bevel=0.018, mat=paint_mat, name="body"), 5)
    dent(body, (-w / 2, 0.05, 1.15), radius=0.3, depth=0.03, direction=(1, 0, 0))      # box-local: z from its base
    dent(body, (0.1, 0.0, h - foot), radius=0.3, depth=0.025, direction=(0, 0, -1))
    plinth = box((w - 0.05, d - 0.05, foot + 0.02), bevel=0.01, mat=steel, name="plinth")
    rust = [box((w + 0.006, d + 0.006, hh), pos=(0, 0, foot), rot=(0, 0, 0), bevel=0.004, mat="rust", name="rust")
            for hh in (0.11,)]
    rust.append(box((0.3, 0.012, 0.16), pos=(-0.2, front - 0.004, foot + 0.1), rot=(0, 7, 0), bevel=0.004,
                    mat="rust", name="rust"))
    # The left-hand door is shut for good: a panel, three vents, a hasp and a padlock.
    dw, dh, dz = w / 2 - 0.035, h - foot - 0.12, foot + 0.06
    left = box((dw, 0.02, dh), pos=(-w / 4, front - 0.008, dz), bevel=0.008, mat=trim, name="left")
    parts = [left]
    for k in range(3):
        parts.append(box((dw * 0.6, 0.012, 0.022), pos=(-w / 4, front - 0.02, dz + dh - 0.12 - 0.05 * k), bevel=0.004,
                         mat="dark", name="vent"))
    parts.append(box((0.07, 0.016, 0.05), pos=(-0.045, front - 0.022, 0.98), bevel=0.006, mat=steel, name="hasp"))
    parts.append(box((0.06, 0.035, 0.065), pos=(-0.045, front - 0.045, 0.9), rot=(0, 9, 0), bevel=0.012, mat=steel,
                     name="padlock"))
    parts.append(torus(0.022, 0.007, pos=(-0.043, front - 0.045, 0.975), rot=(90, 0, 0), major_segments=10,
                       minor_segments=4, mat=steel, name="shackle"))
    # Behind the right-hand door: the dark of the inside, so it reads as open when the door swings.
    parts.append(box((dw - 0.02, 0.012, dh - 0.03), pos=(w / 4, front - 0.002, dz + 0.015), bevel=0.0, mat="dark",
                     name="inside"))
    # A strip of tape where a name was, and what somebody stuck on top.
    tape = material("tape", P.mix(pal("HONEY_WOOD"), pal("CREAM"), 0.45), "matte")
    parts.append(box((0.2, 0.006, 0.05), pos=(-w / 4 + 0.01, front - 0.02, 1.42), rot=(0, -5, 0), bevel=0.002,
                     mat=tape, name="tag"))
    shell = join([body, plinth] + rust + parts, "Body")

    # The right-hand door: its own node, pivot on the hinge edge (the outer right corner of the front).
    hinge = Vector((w / 2 - 0.02, front - 0.008, 0.0))
    leaf = subdivide(box((dw, 0.02, dh), pos=(w / 4, front - 0.022, dz), bevel=0.008, mat=trim, name="leaf"), 4)
    dent(leaf, (-0.05, -0.01, 0.5), radius=0.22, depth=0.022, direction=(0, 1, 0))             # box-local
    door_parts = [leaf]
    for k in range(3):
        door_parts.append(box((dw * 0.6, 0.012, 0.022), pos=(w / 4, front - 0.036, dz + dh - 0.12 - 0.05 * k),
                              bevel=0.004, mat="dark", name="vent"))
    door_parts.append(box((0.035, 0.03, 0.16), pos=(0.06, front - 0.045, 0.9), bevel=0.01, mat=steel, name="handle"))
    door_parts.append(box((0.19, 0.006, 0.05), pos=(w / 4, front - 0.035, 1.42), rot=(0, 4, 0), bevel=0.002,
                          mat=tape, name="tag"))
    for z in (0.35, 1.0, 1.6):
        door_parts.append(cyl(0.014, 0.09, verts=8, pos=(hinge.x + 0.004, front - 0.03, z), bevel=0.003, mat=steel,
                              name="hinge"))
    door = join(door_parts, "Door", origin=hinge)
    export([shell, door], "locker", kind="prop", mount="floor")


HATS = (("hairnet", make_hairnet), ("paper_cap", make_paper_cap), ("hard_hat", make_hard_hat), ("cone", make_cone),
        ("bucket", make_bucket), ("welding_mask", make_welding_mask), ("bandage", make_bandage))


def build():
    for name, make in HATS:
        reset()
        finish(make(), "hat_" + name)
    build_locker()
