"""deposit_chute: the turn-in. A rusty steel deposit box (1.6 x 1.4 m footprint) with a wide slot on top fed
by three rollers, a padlocked orange collection hatch with a dull "$" roundel, a hazard stripe under the
lip, a drop duct into the floor at the back and a "DEPOSIT PRODUCT / NO REFUNDS" plate on two posts with a
dull steel coin spinning above it (kind "station", floor mount).

Replaces the primitives of scenes/stations/turn_in_station.tscn, instanced AS `Visual` (MODELING.md 5B):
turn_in_station.gd bounces `Visual` on a sale and spins `Visual/Sign/Coin` about its local Y, so
  Sign        empty at the plate centre (Godot (0, 1.86, -0.42)); the scene hangs the "DEPOSIT PRODUCT"
              Label3D on it. Its rotation stays identity (the coin spins in its space).
  Sign/Coin   the coin (separate mesh, origin at its centre, rest rotation identity), FrontMark/BackMark
              "$" Label3Ds sit on its faces (+-0.027 Godot z)
  Emblem      empty on the hatch roundel (the scene's "$" Label3D)
SoldLabel and the collider (1.6 x 1.08 x 1.4 box) stay in the scene.
Wear: rust everywhere it is not painted, rust creeping up the orange hatch, a dent in the front, a kicked-in
corner post, a crooked sign plate, a dented coin, a padlock nobody has the key to.
"""
from gwf import *

BODY_W, BODY_D = 1.44, 1.24     # box body (plinth 1.6 x 1.4 fills the collider)
TOP = 0.9                       # top plate surface
FY = -BODY_D / 2                # body front face
SLOT_Y = 0.13                   # slot centre (behind the rollers)
ROLLER_Y = (-0.1, -0.27, -0.44)
SIGN = (0.0, 0.42, 1.86)        # sign plate centre (Godot (0, 1.86, -0.42))
COIN_UP = 0.58                  # coin centre above the sign centre
EMBLEM_Z = 0.44
SIGN_TILT = 2.0                 # degrees about Blender +Y (Godot -2 about +Z): hung a bit crooked


def rust_edge(width, height, x, y_face, z0, seed, mat, n=10, name="rust"):
    """Rust creeping up a flat face: flat bottom at z0, soft wavy top, 6 mm thick, facing -Y."""
    pts = [(-width / 2, 0.0), (width / 2, 0.0)]
    for i in range(n, -1, -1):
        t = i / n
        v = height * (0.66 + 0.2 * math.sin(t * 6.0 + seed) + 0.08 * math.sin(t * 11.0 + seed * 2))
        v *= 0.35 + 0.65 * math.sin(math.pi * t) ** 0.5
        pts.append((-width / 2 + width * t, v))
    return extrude_profile(pts, 0.006, pos=(x, y_face, z0), bevel=0.0, mat=mat, name=name)


def build():
    rust, steel, tin = lib("rust"), lib("metal_dark"), lib("metal")
    orange, caution, dark, void = lib("orange"), lib("caution"), lib("dark"), lib("void")

    p = []
    # --- box ------------------------------------------------------------------------------------------------
    p.append(box((1.6, 1.4, 0.08), pos=(0, 0, 0), bevel=0.03, segments=1, mat=steel, name="plinth"))
    body = box((BODY_W, BODY_D, TOP - 0.06 - 0.06), pos=(0, 0, 0.06), bevel=0.05, segments=2, mat=rust, name="body")
    subdivide(body, 4)
    dent(body, (0.6, FY, 0.08), radius=0.24, depth=0.045, direction=(0, 1, 0))     # kicked, below the hatch
    dent(body, (-BODY_W / 2, 0.3, 0.5), radius=0.28, depth=0.04, direction=(1, 0, 0))
    p.append(body)
    # heavy top plate with a rolled lip (overhangs the body like a lid)
    p.append(box((BODY_W + 0.1, BODY_D + 0.1, 0.07), pos=(0, 0, TOP - 0.07), bevel=0.03, segments=2, mat=steel,
                  name="top"))
    # corner posts, capped; the front right one knocked crooked
    for sx in (-1, 1):
        for sy in (-1, 1):
            bent = (sx, sy) == (1, -1)   # pulled outwards by a trolley
            h = TOP + 0.04
            p.append(cyl(0.075, h, verts=12, pos=(sx * 0.7, sy * 0.6, 0.0), rot=(4.0, 3.0, 0) if bent else (0, 0, 0),
                         bevel=0.02, segments=1, mat=steel, name="post"))
            tip = Matrix.Rotation(math.radians(3.0), 3, 'Y') @ Matrix.Rotation(math.radians(4.0), 3, 'X') @ Vector((0, 0, h)) \
                if bent else Vector((0, 0, h))
            p.append(sphere(0.085, pos=(sx * 0.7 + tip.x, sy * 0.6 + tip.y, tip.z + 0.01), segments=10, rings=5,
                            mat=steel, name="post_cap"))

    # --- front: hazard band, padlocked orange hatch with the "$" roundel ------------------------------------
    p.append(box((BODY_W - 0.1, 0.02, 0.12), pos=(0, FY - 0.004, TOP - 0.2), bevel=0.006, segments=1, mat=caution,
                  name="hazard"))
    for i in range(7):
        u = -0.57 + 0.19 * i
        p.append(extrude_profile([(u - 0.05, TOP - 0.2), (u + 0.02, TOP - 0.2), (u + 0.09, TOP - 0.08),
                                  (u + 0.02, TOP - 0.08)], 0.004, pos=(0, FY - 0.014, 0), bevel=0.0, mat=dark,
                                 name="hazard_stripe"))
    hatch = box((1.0, 0.03, 0.46), pos=(0, FY - 0.01, 0.2), bevel=0.02, segments=1, mat=orange, name="hatch")
    p.append(hatch)
    hy = FY - 0.025   # hatch front face
    for z in (0.28, 0.58):   # hinges (left)
        p.append(cyl(0.028, 0.1, verts=8, pos=(-0.52, hy, z - 0.05), bevel=0, mat=steel, name="hinge"))
    p.append(pipe([(0.36, hy + 0.01, 0.52), (0.4, hy - 0.05, 0.52), (0.4, hy - 0.05, 0.34), (0.36, hy + 0.01, 0.34)],
                  0.016, verts=6, bend=0.03, mat=steel, name="handle"))
    # padlock hanging from a hasp on the right edge
    p.append(box((0.05, 0.03, 0.1), pos=(0.5, hy - 0.01, 0.4), bevel=0.01, segments=1, mat=steel, name="hasp"))
    p.append(torus(0.028, 0.009, pos=(0.5, hy - 0.035, 0.405), rot=(90, 0, 0), major_segments=10, minor_segments=5,
                   mat=tin, name="shackle"))
    p.append(box((0.09, 0.04, 0.08), pos=(0.5, hy - 0.035, 0.31), bevel=0.015, segments=1, mat=tin, name="lock"))
    p.append(cyl(0.01, 0.01, verts=6, pos=(0.5, hy - 0.055, 0.345), rot=(90, 0, 0), bevel=0, mat=dark, name="keyhole"))
    # the "$" roundel: tin ring, dark steel face (the scene writes the gold "$")
    p.append(cyl(0.2, 0.025, verts=24, pos=(0, hy, EMBLEM_Z), rot=(90, 0, 0), bevel=0.01, segments=1, mat=tin,
                 name="emblem_ring"))
    p.append(cyl(0.165, 0.02, verts=24, pos=(0, hy - 0.02, EMBLEM_Z), rot=(90, 0, 0), bevel=0.008, segments=1,
                 mat=steel, name="emblem_face"))
    for a in range(0, 360, 90):   # four rivets on the ring
        r = math.radians(a + 45)
        p.append(cyl(0.016, 0.012, verts=6, pos=(0.182 * math.cos(r), hy - 0.024, EMBLEM_Z + 0.182 * math.sin(r)),
                     rot=(90, 0, 0), bevel=0, mat=steel, name="rivet"))
    # rust creeping up the hatch from the bottom, and chipped paint up top
    p.append(rust_edge(0.96, 0.16, 0.0, hy - 0.001, 0.2, seed=0.7, mat=rust, name="hatch_rust"))
    p.append(extrude_profile([(-0.36, 0.62), (-0.22, 0.64), (-0.18, 0.6), (-0.26, 0.57), (-0.34, 0.58)], 0.004,
                             pos=(0, hy - 0.001, 0), bevel=0.0, mat=rust, name="chip"))

    # --- top: rollers feeding a wide slot -----------------------------------------------------------------
    p.append(box((1.22, 0.3, 0.02), pos=(0, SLOT_Y, TOP), bevel=0.0, mat=void, name="slot"))
    p.append(pipe([(0.0, SLOT_Y - 0.16, TOP + 0.03), (0.62, SLOT_Y - 0.16, TOP + 0.03), (0.62, SLOT_Y + 0.16, TOP + 0.03),
                   (-0.62, SLOT_Y + 0.16, TOP + 0.03), (-0.62, SLOT_Y - 0.16, TOP + 0.03), (0.02, SLOT_Y - 0.16, TOP + 0.03)],
                  0.03, verts=8, bend=0.05, mat=steel, name="slot_lip"))
    for sx in (-1, 1):   # roller side rails
        p.append(box((0.06, 0.5, 0.09), pos=(sx * 0.62, -0.27, TOP), bevel=0.02, segments=1, mat=steel, name="rail"))
    for i, y in enumerate(ROLLER_Y):
        p.append(cyl(0.05, 1.18, verts=12, pos=(-0.59, y, TOP + 0.05), rot=(0, 90, 0), bevel=0.01, segments=1,
                     mat=rust if i == 1 else tin, name="roller"))   # the middle one rusted solid
    # a hazard strip on the lip in front of the rollers
    p.append(box((1.1, 0.06, 0.012), pos=(0, -0.58, TOP), bevel=0.0, mat=caution, name="lip_strip"))

    # --- back: drop duct into the floor ------------------------------------------------------------------
    p.append(pipe([(0.0, 0.5, 0.5), (0.0, 0.66, 0.5), (0.0, 0.66, 0.0)], 0.13, verts=12, bend=0.12, caps=False,
                  mat=steel, name="duct"))
    p.append(cyl(0.17, 0.04, verts=16, pos=(0, 0.66, 0.0), bevel=0.012, segments=1, mat=rust, name="duct_flange"))
    p.append(cyl(0.17, 0.04, verts=16, pos=(0, 0.66, 0.5), rot=(90, 0, 0), bevel=0.012, segments=1, mat=steel,
                 name="duct_collar"))

    # --- sign posts + plate (the plate hangs a little crooked; the Sign node itself stays straight) -----------
    sx0, sy0, sz0 = SIGN
    for sx in (-1, 1):
        p.append(cyl(0.045, sz0 + 0.3 - TOP, verts=10, pos=(sx * 0.62, sy0, TOP), bevel=0, mat=steel, name="sign_post"))
        p.append(sphere(0.06, pos=(sx * 0.62, sy0, sz0 + 0.31), segments=10, rings=5, mat=rust, name="sign_knob"))
        p.append(box((0.08, 0.06, 0.06), pos=(sx * 0.62, sy0 - 0.01, sz0 + 0.14), bevel=0.015, segments=1, mat=steel,
                     name="sign_clamp"))
    plate = [
        box((1.14, 0.05, 0.46), pos=(0, 0, -0.23), bevel=0.02, segments=1, mat=steel, name="plate"),
        pipe([(0.0, -0.03, -0.21), (0.55, -0.03, -0.21), (0.55, -0.03, 0.21), (-0.55, -0.03, 0.21), (-0.55, -0.03, -0.21),
              (0.02, -0.03, -0.21)], 0.018, verts=6, bend=0.04, mat=caution, name="plate_frame"),
    ]
    for u, v in ((-0.5, 0.17), (0.5, 0.17), (-0.5, -0.17), (0.5, -0.17)):
        plate.append(cyl(0.018, 0.012, verts=6, pos=(u, -0.03, v), rot=(90, 0, 0), bevel=0, mat=tin, name="plate_bolt"))
    pl = join(plate, "plate_mesh")
    pl.location = (sx0, sy0, sz0)
    pl.rotation_euler = (0, math.radians(SIGN_TILT), 0)
    p.append(pl)
    # the spindle the coin turns on
    p.append(cyl(0.016, COIN_UP - 0.18 - 0.23, verts=6, pos=(sx0, sy0, sz0 + 0.23), bevel=0, mat=steel,
                 name="spindle"))
    p.append(cyl(0.035, 0.03, verts=8, pos=(sx0, sy0, sz0 + COIN_UP - 0.2), bevel=0.008, segments=1, mat=steel,
                 name="spindle_cup"))

    chute = join(p, "Chute")

    # --- coin: a fat, dull steel coin with a rolled rim and a dent (spins in the scene) ----------------------
    prof = [(0.0, -0.018), (0.13, -0.018), (0.142, -0.026), (0.168, -0.024), (0.175, -0.012), (0.175, 0.012),
            (0.168, 0.024), (0.142, 0.026), (0.13, 0.018), (0.0, 0.018)]
    coin = lathe(prof, verts=28, mat=lib("gray"), name="coin", smooth=55)   # dull steel, not a shiny bonus
    paint(coin, steel, lambda c, n: math.hypot(c.x, c.y) > 0.137)   # dark rim
    dent(coin, (0.09, 0.08, 0.02), radius=0.07, depth=0.012, direction=(0, 0, -1))
    coin.rotation_euler = (math.radians(90), 0, 0)   # face the front (-Y), spin axis = Z (Godot Y)
    coin_obj = join([coin], "Coin")
    sign_node = empty("Sign", SIGN)
    coin_obj.location = (sx0, sy0, sz0 + COIN_UP)
    set_parent(coin_obj, sign_node)
    emblem = empty("Emblem", (0.0, hy - 0.04, EMBLEM_Z))
    export([chute, sign_node, emblem], "deposit_chute", kind="station", mount="floor")
