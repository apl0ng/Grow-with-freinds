"""oil_drum: a battered 200 l steel drum (worked example of the gwf pipeline).

Room decor / cover prop. Floor mount, ~0.66 x 0.95 x 0.66 m. Front (+Y Blender = -Z Godot) carries the
hazard label. The paint is a TINT material: neutral grey in Blender, recoloured per instance in Godot
(`tint = Color(...)` on the instanced model) so one model gives faded blue / olive / red drums.
Style: chunky rolled rims, fat ribs, slight belly, a dent, rust creeping up from the floor.
"""
from gwf import *

R = 0.30      # wall radius at the rims
H = 0.95      # height to the top of the top rim
BELLY = 0.012 # extra radius at mid height (cartoon barrel belly)


def wall_r(z):
    return R + BELLY * math.sin(math.pi * max(0.0, min(1.0, z / H)))


def rib(z, profile, w=0.034, h=0.024):
    r = wall_r(z)
    profile += [(r, z - w * 0.75), (r + h * 0.8, z - w * 0.35), (r + h, z), (r + h * 0.8, z + w * 0.35),
                (r, z + w * 0.75)]


def build():
    paint_mat = tint_material("TINT_paint")
    metal = lib("metal_dark")
    rust = lib("rust")

    # Body: one lathe with the two rolling ribs and the recessed lid built into the profile.
    prof = [(0.0, 0.02), (R - 0.03, 0.02), (wall_r(0.05), 0.05)]
    for z in (0.12, 0.2):
        prof.append((wall_r(z), z))
    rib(0.31, prof)
    for z in (0.4, 0.48, 0.56):
        prof.append((wall_r(z), z))
    rib(0.64, prof)
    for z in (0.73, 0.82, H - 0.05):
        prof.append((wall_r(z), z))
    prof += [(R - 0.035, H - 0.035), (0.0, H - 0.035)]
    body = lathe(prof, verts=32, mat=paint_mat, name="body", smooth=48)
    # Tired steel: a dent on the front-right shoulder and a smaller one low on the left.
    dent(body, (wall_r(0.76) * math.sin(math.radians(62)), wall_r(0.76) * math.cos(math.radians(62)), 0.76),
         radius=0.13, depth=0.035)
    dent(body, (-wall_r(0.2) * 0.95, -wall_r(0.2) * 0.3, 0.2), radius=0.09, depth=0.02)
    # Rust creeping up from the floor (colour blocking on the body faces, wavy edge).
    paint(body, rust, lambda c, n: c.z < 0.10 + 0.05 * math.sin(3 * math.atan2(c.y, c.x) + 1.0)
          + 0.03 * math.sin(7 * math.atan2(c.y, c.x)))
    # ...and a rust streak running down from the top rim at the back-left.
    paint(body, rust, lambda c, n: c.z > 0.5 and abs(math.atan2(c.x, c.y) - math.radians(-140)) < 0.16
          + 0.1 * math.sin(c.z * 11))

    # Rolled rims (chimes), fat and dark.
    rim_top = torus(R - 0.004, 0.03, pos=(0, 0, H - 0.03), major_segments=32, minor_segments=8, mat=metal,
                    name="rim_top")
    rim_bot = torus(R - 0.006, 0.028, pos=(0, 0, 0.028), major_segments=32, minor_segments=8, mat=metal,
                    name="rim_bottom")

    # Bung caps on the lid (one big, one small), chunky and beveled.
    lid = H - 0.035
    bung = cyl(0.05, 0.03, verts=16, pos=(0.14, 0.07, lid - 0.005), bevel=0.01, mat=metal, name="bung")
    bung_nut = cyl(0.028, 0.025, verts=6, pos=(0.14, 0.07, lid + 0.02), bevel=0.006, mat=metal, name="nut")
    vent = cyl(0.032, 0.026, verts=14, pos=(-0.15, -0.06, lid - 0.005), bevel=0.008, mat=metal, name="vent")

    # Hazard label on the front: cream plate + caution diamond + ink "!" (all chunky, readable at 6 m).
    zl = 0.4
    label = arc_panel(wall_r(zl + 0.08) + 0.001, 0.17, angle=52, thickness=0.008, pos=(0, 0, zl), segments=8,
                      mat=lib("cream"), name="label")
    y_front = wall_r(zl + 0.08) + 0.009
    # The flat diamond is sunk 12 mm so its corners still touch the curved label.
    diamond = extrude_profile([(0, -0.07), (0.07, 0), (0, 0.07), (-0.07, 0)], 0.02,
                              pos=(0, y_front - 0.012, zl + 0.085), bevel=0.006, mat=lib("caution"),
                              name="diamond")
    bang = box((0.02, 0.012, 0.052), pos=(0, y_front + 0.006, zl + 0.093), bevel=0.005, mat=lib("dark"),
               name="bang")
    dot = box((0.02, 0.012, 0.018), pos=(0, y_front + 0.006, zl + 0.063), bevel=0.005, mat=lib("dark"),
              name="dot")

    drum = join([body, rim_top, rim_bot, bung, bung_nut, vent, label, diamond, bang, dot], "oil_drum")
    export(drum, "oil_drum", mount="floor", budget=3000)
