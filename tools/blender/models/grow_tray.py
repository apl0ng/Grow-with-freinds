"""grow_tray: the plot tray only (the plant is a separate model/scene). A cheap charcoal plastic grow tub with
a fat rolled lip, on a low rusty steel frame, a drip line clipped to the lip with a spaghetti feeder to the
middle, and the housing of the water gauge on the front (kind "station", floor mount, ~1.47 x 0.52 x 1.47 m).

Replaces the primitives under scenes/stations/grow_plot.tscn `Visual` (instanced there as `Visual/Model`).
grow_plot.gd drives Godot nodes that stay in the scene, so this model leaves room for them:
  %SoilBed (box, top y 0.45) + %SoilMound (squashed sphere, top y 0.51): the soil, recoloured dry/wet by the
      script; it fills the tub inside the lip (x/z +-0.65), the plant stands at y 0.49
  WaterGauge/%FillPivot/%Fill: the water bar (x -0.4..0.4, y 0.24, z 0.705) lies in the model's dark slot
  %Tag/%Card: the strain-tinted plant tag (front left corner), shown once planted
Collider (1.46 x 0.52 x 1.46 box) and the plant hitbox stay in the scene.
Wear: a crack in the front corner, soil smeared down the walls, rust on the frame feet.
"""
from gwf import *

HALF = 0.69        # tub half width (walls)
LIP = 0.69         # rolled lip centre line (half width)
LIP_R = 0.045
LIP_Z = 0.46
BODY_Z0, BODY_Z1 = 0.13, 0.43
GAUGE_Z = 0.24     # water bar height (scene: WaterGauge y)
GAUGE_Y = -0.705   # water bar centre depth (scene: Godot z +0.705)


def ring(half, z, r, mat, name, bend=0.12, verts=10):
    """A rounded-square loop of pipe at height z (a rolled lip / frame rail)."""
    pts = [(0.0, -half, z), (half, -half, z), (half, half, z), (-half, half, z), (-half, -half, z), (0.02, -half, z)]
    return pipe(pts, r, verts=verts, bend=bend, mat=mat, name=name)


def stadium(half_len, rad, n=6):
    """Outline of a flat stadium (u along X, v up) centred on 0, for extrude_profile()."""
    pts = []
    for i in range(n + 1):
        a = -math.pi / 2 + math.pi * i / n
        pts.append((half_len + rad * math.cos(a), rad * math.sin(a)))
    for i in range(n + 1):
        a = math.pi / 2 + math.pi * i / n
        pts.append((-half_len + rad * math.cos(a), rad * math.sin(a)))
    return pts


def build():
    plastic = material("tray_plastic", "#4e585e", "soft")   # cheap charcoal plastic (metal_dark's hue, not glossy)
    lip_mat = lib("gray")                                     # the rolled lip, two value steps lighter
    steel, rust, dark, water = lib("metal_dark"), lib("rust"), lib("dark"), lib("water")
    soil_smear = lib("soil")

    p = []
    # --- frame: four stubby legs on rusty pads, a rail loop under the tub --------------------------------------
    for sx in (-1, 1):
        for sy in (-1, 1):
            p.append(cyl(0.05, 0.13, verts=10, pos=(sx * 0.6, sy * 0.6, 0.02), bevel=0, mat=steel, name="leg"))
            p.append(cyl(0.08, 0.025, verts=10, pos=(sx * 0.6, sy * 0.6, 0.0), bevel=0.008, segments=1, mat=rust,
                         name="pad"))
    p.append(ring(0.6, 0.1, 0.03, steel, "rail", bend=0.1, verts=8))
    for sy in (-1, 1):   # two cross bars
        p.append(pipe([(-0.6, sy * 0.25, 0.1), (0.6, sy * 0.25, 0.1)], 0.025, verts=6, mat=steel, name="cross"))

    # --- tub: straight walls, a moulded ledge, rolled lip ----------------------------------------------------------
    body = box((2 * HALF, 2 * HALF, BODY_Z1 - BODY_Z0), pos=(0, 0, BODY_Z0), bevel=0.07, segments=2, mat=plastic,
               name="tub")
    p.append(body)
    p.append(box((2 * HALF + 0.03, 2 * HALF + 0.03, 0.05), pos=(0, 0, BODY_Z0 + 0.03), bevel=0.02, segments=1,
                  mat=plastic, name="ledge"))
    lip = ring(LIP, LIP_Z, LIP_R, lip_mat, "lip", bend=0.14, verts=10)
    p.append(lip)

    # --- water gauge housing on the front: dark slot, steel bezel, a water-drop icon -----------------------------
    fy = -HALF
    p.append(extrude_profile(stadium(0.42, 0.065), 0.012, pos=(0, fy, GAUGE_Z), bevel=0.0, mat=dark, name="slot"))
    p.append(pipe([(0.0, fy - 0.012, GAUGE_Z - 0.085)] +
                  [(u, fy - 0.012, v + GAUGE_Z) for u, v in ((0.46, -0.085), (0.52, 0.0), (0.46, 0.085), (-0.46, 0.085),
                                                             (-0.52, 0.0), (-0.46, -0.085))] +
                  [(0.02, fy - 0.012, GAUGE_Z - 0.085)], 0.018, verts=6, bend=0.04, mat=lip_mat, name="bezel"))
    drop = [(0.0, 0.07), (0.028, 0.02), (0.042, -0.02), (0.036, -0.045), (0.018, -0.06), (0.0, -0.064),
            (-0.018, -0.06), (-0.036, -0.045), (-0.042, -0.02), (-0.028, 0.02)]
    p.append(extrude_profile(drop, 0.02, pos=(-0.585, fy, GAUGE_Z), bevel=0.006, segments=1, mat=water, name="drop"))

    # --- drip line: clipped along the back and left lip, a feeder down the back, a spaghetti line to the middle --
    top = LIP_Z + LIP_R + 0.012
    line = [(-0.6, -LIP + 0.02, top), (-LIP + 0.01, -0.58, top), (-LIP + 0.01, LIP - 0.12, top),
            (-0.58, LIP - 0.01, top), (0.5, LIP - 0.01, top), (0.6, LIP + 0.02, top - 0.03),
            (0.62, LIP + 0.06, 0.3), (0.62, LIP + 0.06, 0.06), (0.7, LIP + 0.03, 0.017)]
    p.append(pipe(line, 0.017, verts=6, bend=0.06, mat=dark, name="drip_line"))
    for pt in ((-LIP + 0.01, -0.2), (-LIP + 0.01, 0.25), (-0.2, LIP - 0.01), (0.25, LIP - 0.01)):   # emitters
        p.append(cyl(0.012, 0.05, verts=6, pos=(pt[0] * 0.93, pt[1] * 0.93, top - 0.045), bevel=0, mat=dark,
                     name="emitter"))
    # spaghetti feeder: off the back line, over the soil to a little stake next to the plant
    stake = (0.2, 0.14)
    p.append(pipe([(0.1, LIP - 0.03, top), (0.14, 0.45, 0.53), (0.18, 0.25, 0.54), (stake[0], stake[1], 0.56)],
                  0.008, verts=4, bend=0.06, mat=dark, name="spaghetti"))
    p.append(cyl(0.012, 0.16, verts=6, pos=(stake[0], stake[1], 0.42), bevel=0, mat=dark, name="drip_stake"))

    # --- wear: a crack in the front right corner, soil smeared down the walls ----------------------------------
    crack = [(0.52, 0.42), (0.55, 0.36), (0.53, 0.33), (0.57, 0.27), (0.565, 0.265), (0.525, 0.325), (0.545, 0.355),
             (0.512, 0.42)]
    p.append(extrude_profile(crack, 0.004, pos=(0, fy - 0.001, 0), bevel=0.0, mat=dark, name="crack"))
    for (u, w, h, side) in ((-0.3, 0.2, 0.09, 0), (0.28, 0.14, 0.06, 1), (0.1, 0.24, 0.08, 2), (-0.2, 0.16, 0.07, 3)):
        smear = [(u - w / 2, 0.0), (u + w / 2, 0.0), (u + w * 0.35, -h * 0.7), (u + w * 0.1, -h),
                 (u - w * 0.2, -h * 0.6), (u - w * 0.42, -h * 0.9)]
        o = extrude_profile(smear, 0.004, bevel=0.0, mat=soil_smear, name="smear")   # at the origin, facing -Y
        move_verts(o, lambda co: Vector((co.x, co.y - HALF - 0.001, co.z + BODY_Z1 - 0.012)))
        o.rotation_euler = (0, 0, math.radians(90 * side))   # onto the front / right / back / left wall
        p.append(o)

    tray = join(p, "Tray")
    export(tray, "grow_tray", kind="station", mount="floor")
