"""oil_drum: a battered 200 l steel drum (worked example of the gwf pipeline).

Room decor / cover prop (kind "prop": its front, Blender -Y, lands on Godot +Z like every room prop).
Floor mount, ~0.7 x 0.93 x 0.7 m. The front carries the hazard label. The paint is TINT (neutral grey in Blender), recoloured per instance in Godot with
`tint = Color(...)` on the instanced model, so one model gives faded blue / olive / red drums; the
painted middle stripe is a darker shade of the same tint (TINT_stripe, shade 0.7).
Style: chunky rolled rims, fat ribs, a cartoon belly, dents, rust creeping up from the floor.
"""
from gwf import *

R = 0.31       # wall radius at the rims
H = 0.93       # overall height (top of the top rim)
BELLY = 0.018  # extra radius at mid height
RIBS = (0.31, 0.62)
V = 24         # radial segments (STYLE: 24+ for anything >= 0.3 m)


def wall_r(z):
    return R + BELLY * math.sin(math.pi * max(0.0, min(1.0, z / H)))


def on_wall(deg, z):
    """A point on the drum wall, `deg` degrees around from the front (-Y) towards +X."""
    a = math.radians(deg)
    return (wall_r(z) * math.sin(a), -wall_r(z) * math.cos(a), z)


def build():
    paint_mat = tint_material("TINT_paint")
    stripe_mat = tint_material("TINT_stripe", shade=0.7)
    metal = lib("metal_dark")
    rust = lib("rust")

    # Body: one lathe with two fat rolling ribs and a recessed lid built into the profile.
    prof = [(0.0, 0.02), (R - 0.03, 0.02), (wall_r(0.05), 0.05), (wall_r(0.13), 0.13), (wall_r(0.21), 0.21)]
    for zr in RIBS:
        r, w, h = wall_r(zr), 0.036, 0.026
        prof += [(r, zr - w), (r + h * 0.75, zr - w * 0.45), (r + h, zr), (r + h * 0.75, zr + w * 0.45), (r, zr + w)]
        if zr == RIBS[0]:
            prof += [(wall_r(z), z) for z in (0.42, 0.51)]
    prof += [(wall_r(z), z) for z in (0.72, 0.8, H - 0.05)]
    prof += [(R - 0.038, H - 0.036), (0.0, H - 0.036)]
    body = lathe(prof, verts=V, mat=paint_mat, name="body", smooth=48)

    # Rust creeping up from the floor: a thin shell with a wavy top edge (smooth, unlike face painting).
    rust_band = band(wall_r, 0.035, 0.12, thickness=0.003, verts=32, rows=2, mat=rust, name="rust_band",
                     top=lambda a: 0.05 * math.sin(3 * a + 1.0) + 0.02 * math.sin(5 * a + 0.3))
    # Tired steel: a big dent on the shoulder (front, towards +X), a small one low at the back (through the rust).
    dent(body, on_wall(58, 0.77), radius=0.14, depth=0.045)
    low = on_wall(240, 0.12)
    dent(body, low, radius=0.1, depth=0.03)
    dent(rust_band, low, radius=0.1, depth=0.03)

    # Painted stripe between the ribs, a darker shade of the tint.
    stripe = band(wall_r, RIBS[0] + 0.05, RIBS[1] - 0.05, thickness=0.003, verts=V, rows=2, mat=stripe_mat,
                  name="stripe")

    # A rust drip running down from the top rim at the back (V-shaped bottom edge).
    drip = arc_panel(wall_r(0.8) + 0.002, 0.2, angle=16, thickness=0.004, pos=(0, 0, H - 0.26),
                     rot=(0, 0, 145), segments=4, mat=rust, name="drip")
    move_verts(drip, lambda co: Vector((co.x, co.y, co.z + 0.9 * abs(co.x) if co.z < 0.05 else co.z)))

    # Rolled rims (chimes): fat and dark.
    rim_top = torus(R - 0.004, 0.034, pos=(0, 0, H - 0.034), major_segments=V, minor_segments=7, mat=metal,
                    name="rim_top")
    rim_bot = torus(R - 0.006, 0.03, pos=(0, 0, 0.03), major_segments=V, minor_segments=6, mat=metal,
                    name="rim_bottom")

    # Bung caps on the lid: one big with a hex nut, one small vent.
    lid = H - 0.036
    bung = cyl(0.055, 0.03, verts=14, pos=(0.14, 0.08, lid - 0.006), bevel=0.012, mat=metal, name="bung")
    nut = cyl(0.03, 0.026, verts=6, pos=(0.14, 0.08, lid + 0.02), bevel=0.005, mat=metal, name="nut")
    vent = cyl(0.036, 0.028, verts=12, pos=(-0.15, -0.07, lid - 0.006), bevel=0.01, mat=metal, name="vent")

    # Hazard label on the front: cream plate + caution diamond + ink "!" (chunky, readable at 6 m).
    zl = RIBS[0] + 0.06
    r_label = wall_r(zl + 0.1) + 0.006
    label = arc_panel(r_label, 0.2, angle=58, thickness=0.006, pos=(0, 0, zl), segments=8, mat=lib("cream"),
                      name="label")
    yf = -(r_label + 0.006)  # the label's front surface (the front is -Y)
    # The flat diamond is sunk 14 mm so its corners still touch the curved label; it sticks out 10 mm.
    diamond = extrude_profile([(0, -0.08), (0.08, 0), (0, 0.08), (-0.08, 0)], 0.024,
                              pos=(0, yf + 0.014, zl + 0.1), bevel=0.006, mat=lib("caution"), name="diamond")
    bang = box((0.022, 0.012, 0.058), pos=(0, yf - 0.008, zl + 0.108), bevel=0.005, mat=lib("dark"),
               name="bang")
    dot = box((0.022, 0.012, 0.02), pos=(0, yf - 0.008, zl + 0.074), bevel=0.005, mat=lib("dark"),
              name="dot")

    drum = join([body, rust_band, stripe, drip, rim_top, rim_bot, bung, nut, vent, label, diamond, bang, dot],
                "oil_drum")
    export(drum, "oil_drum", kind="prop", mount="floor")
