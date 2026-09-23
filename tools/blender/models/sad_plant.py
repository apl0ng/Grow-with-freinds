"""sad_plant: a wilted office plant in a cracked terracotta pot, used as an ashtray (room decor).

Floor mount (it stands on a crate in the room), ~0.52 x 0.56 x 0.42 m, replaces the primitives of
scenes/world/props/sad_plant.tscn.
Build: a plastic saucer, a flared pot with a fat rolled rim (a chip knocked out of it, a crack running
down), dry cracked soil, three stems (one arches up and flops over the rim, one sags forward, one snapped
off short), limp dry leaves, two brown dead leaves (one still hanging on, one fallen next to the pot),
two cigarette butts stubbed out in the soil.
Nothing about it is alive enough to be cheerful.
"""
from gwf import *

POT_H = 0.27
RIM_Z = 0.25


def pot_r(z):
    """Outer radius of the pot wall at height z (flared: 0.115 at the foot, 0.15 under the rim)."""
    return 0.115 + 0.035 * max(0.0, min(1.0, z / RIM_Z))


def leaf(length, width, droop=0.03, fold=0.4, mat=None, name="leaf", seg=12, rings=6):
    """A leaf lying along +X from its base at the origin: pointed tip, midrib fold (edges down), tip droop."""
    lf = sphere(1.0, segments=seg, rings=rings, mat=mat, name=name)

    def shape(c):
        u = (c.x + 1) / 2                                  # 0 base .. 1 tip
        w = width / 2 * (1.1 - 0.75 * u ** 1.6) * min(1.0, 3.5 * u + 0.25)
        y = c.y * w
        z = c.z * 0.006 - fold * (y * y) / max(width / 2, 1e-3) - droop * u * u
        return Vector((u * length, y, z))
    move_verts(lf, shape)
    return lf


def put(obj, pos, yaw=0.0, pitch=0.0, roll=0.0):
    """Orient a part built along +X (pitch > 0 tips its far end down) and move its origin to pos."""
    obj.matrix_world = (Matrix.Translation(pos) @ Matrix.Rotation(math.radians(yaw), 4, 'Z')
                        @ Matrix.Rotation(math.radians(pitch), 4, 'Y') @ Matrix.Rotation(math.radians(roll), 4, 'X'))
    apply_transform(obj)
    return obj


def build():
    clay = lib("rust")                                    # terracotta
    saucer_mat = lib("concrete_dark")
    soil = lib("soil")
    stem_mat = lib("leaf_dry")
    dead = lib("brown")                                   # the two dead leaves
    crack = lib("dark")
    paper = lib("cream")                                  # cigarette butts
    parts = []

    # Saucer (a cheap dark plastic dish) and the pot.
    parts.append(lathe([(0.0, 0.0), (0.15, 0.0), (0.172, 0.012), (0.178, 0.026), (0.168, 0.028), (0.155, 0.012),
                        (0.0, 0.012)], verts=28, mat=saucer_mat, name="saucer", smooth=50))
    prof = [(0.0, 0.012), (0.108, 0.012), (pot_r(0.02), 0.02)]
    prof += [(pot_r(z), z) for z in (0.08, 0.15, 0.21)]
    prof += [(0.152, 0.222), (0.172, 0.228), (0.178, 0.25), (0.172, 0.268), (0.155, POT_H), (0.142, 0.262),
             (0.138, 0.236), (0.0, 0.236)]
    pot = lathe(prof, verts=28, mat=clay, name="pot", smooth=50)
    # A chip knocked out of the rim at the front right.
    chip = sphere(0.05, pos=(0.17 * math.sin(math.radians(35)), -0.17 * math.cos(math.radians(35)), 0.272),
                  scale=(1.3, 1, 0.8), segments=12, rings=6, name="chip_cutter")
    boolean_cut(pot, chip)
    paint(pot, soil, lambda c, n: n.z > 0.9 and c.z > 0.23 and math.hypot(c.x, c.y) < 0.138)   # soil floor
    parts.append(pot)
    # The crack: a jagged dark line running down from the chip.
    pts = []
    for z, da in ((0.225, 32.0), (0.19, 37.0), (0.16, 31.0), (0.12, 36.0), (0.085, 30.0), (0.06, 33.0)):
        a = math.radians(da)
        r = pot_r(z) + 0.001
        pts.append((r * math.sin(a), -r * math.cos(a), z))
    parts.append(pipe(pts, 0.0045, verts=8, bend=0.0, mat=crack, name="crack"))

    # Soil: dry, a low lumpy dome inside the rim.
    top = sphere(0.14, pos=(0, 0, 0.232), scale=(1, 1, 0.14), segments=20, rings=6, mat=soil, name="soil")
    jitter(top, 0.004, seed=5)
    parts.append(top)

    # Stems (dry green-brown). 1: arches up and flops over the right rim, hanging down outside the pot.
    s1 = [(0.01, 0.0, 0.24), (0.02, 0.0, 0.36), (0.07, -0.01, 0.44), (0.15, -0.02, 0.45), (0.21, -0.03, 0.39),
          (0.235, -0.035, 0.3)]
    parts.append(pipe(s1, 0.013, verts=12, bend=0.06, mat=stem_mat, name="stem"))
    # 2: sags forward over the front rim.
    s2 = [(-0.02, 0.01, 0.24), (-0.035, -0.01, 0.33), (-0.06, -0.08, 0.38), (-0.08, -0.16, 0.35),
          (-0.09, -0.21, 0.29)]
    parts.append(pipe(s2, 0.011, verts=12, bend=0.05, mat=stem_mat, name="stem"))
    # 3: snapped off short, the broken top bent over.
    parts.append(pipe([(0.02, 0.045, 0.24), (0.025, 0.05, 0.31), (0.06, 0.07, 0.29)], 0.011, verts=12, bend=0.012,
                      mat=stem_mat, name="stub"))
    # A side shoot off stem 1 with a limp leaf, and a limp leaf near the top of stem 1.
    parts.append(pipe([(0.02, 0.0, 0.34), (-0.03, 0.06, 0.4), (-0.08, 0.1, 0.39)], 0.009, verts=8, bend=0.04,
                      mat=stem_mat, name="shoot"))

    # Leaves. Limp dry ones hang off the stems; the two brown dead ones: one on stem 2, one fallen.
    parts.append(put(leaf(0.16, 0.085, droop=0.06, mat=stem_mat), (0.235, -0.035, 0.3), yaw=-60, pitch=62, roll=10))
    parts.append(put(leaf(0.13, 0.07, droop=0.04, mat=stem_mat), (0.1, -0.015, 0.45), yaw=100, pitch=48, roll=-20))
    parts.append(put(leaf(0.12, 0.065, droop=0.05, mat=stem_mat), (-0.08, 0.1, 0.39), yaw=150, pitch=55, roll=15))
    parts.append(put(leaf(0.14, 0.08, droop=0.05, fold=0.55, mat=dead, name="dead_leaf"), (-0.09, -0.21, 0.29),
                     yaw=-100, pitch=70, roll=25))
    fallen = leaf(0.15, 0.085, droop=-0.012, fold=-0.5, mat=dead, name="dead_leaf")  # dry: curled up, tip up
    parts.append(put(fallen, (0.12, -0.2, 0.0065), yaw=-20, pitch=0, roll=0))

    # Two cigarette butts stubbed out in the soil (cream paper, dark burnt end).
    for (x, y, yaw, pitch) in ((-0.06, 0.05, 30, -55), (0.07, 0.07, 160, -35)):
        butt = cyl(0.009, 0.06, verts=10, pos=(0, 0, 0), rot=(0, 90, 0), bevel=0, mat=paper, name="butt")
        ash = cyl(0.0095, 0.012, verts=10, pos=(0.06, 0, 0), rot=(0, 90, 0), bevel=0, mat=crack, name="ash")
        for o in (butt, ash):
            apply_transform(o)
            parts.append(put(o, (x, y, 0.23), yaw=yaw, pitch=pitch))

    plant = join(parts, "sad_plant")
    export(plant, "sad_plant", kind="prop", mount="floor")
