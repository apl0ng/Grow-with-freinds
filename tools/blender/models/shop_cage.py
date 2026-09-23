"""shop_cage: the Boss's SUPPLY window. A dented olive steel cashier counter with a rusty barred cage on
top, a pay slot under the window, a "SUPPLY" sign box, a crooked chalk price board, three seed jars, a
service bell, a grimy cash register and the step the Boss stands on (kind "station", floor mount).

Replaces the primitives of scenes/stations/shop_counter.tscn, instanced AS `Visual` (MODELING.md 5B)
because shop_counter.gd addresses parts by path:
  Visual/Jars/Jar1..3/Fill        TINT seed pile: the script sets material_override = the seed colour
  Visual/Badges/Badge1..3/Face    TINT roundels on the counter front (seed colours, same way)
  Visual/Sign, Visual/PriceBoard, Visual/Register, Visual/PayPlate, Visual/Jars/JarN
                                  empties the scene hangs its Label3Ds on ("SUPPLY", chalk prices, the
                                  register "$", "PAY HERE", the "$20" price tags)
Colliders stay in the scene: counter box 3.4 x 1.04 x 1.2 (centre y 0.52), Boss cylinder r 0.45 at z -0.9.
The Boss (ShopkeeperAnchor, scene) stands on the step behind the counter (Godot z -0.9, y 0.2).

Layout (Blender, front = -Y = Godot +Z = the customers): counter top at z 1.02, the cage's bar line at
y = CAGE_Y (a 0.32 m customer ledge in front of it), jars inside the cage on the left, the register
inside on the right, the pay tray straddling the bar line under the window, the bell on the ledge.
Wear: rust creeping up the counter and the bar feet, a rusty replacement bar, a bent bar, a sagging
bumper, a crooked sign and board, grime where hands rest, the $90 jar nearly empty.
"""
from gwf import *

W = 3.4          # counter width (collider)
D = 1.2          # counter depth (collider)
TOP = 1.02       # counter top surface
CAGE_Y = -0.28   # bar line (Godot z +0.28)
CAGE_TOP = 2.42  # top rail height
POST_X = 1.64    # cage end posts
BACK_Y = 0.56    # back posts of the side cages
WINDOW = 0.6     # half width of the pay window (the bars inside it stop at WINDOW_Z)
WINDOW_Z = 1.5
BAR_STEP = 0.3   # front bars at x = -1.5 + i * BAR_STEP; the jars stand between them
JAR_X = (-1.35, -1.05, -0.75)
JAR_Y = -0.07
JAR_FILL = (0.19, 0.13, 0.05)   # seed pile heights: the $90 jar is nearly empty
BADGE_X = (-0.85, 0.0, 0.85)
BADGE_Z = 0.56
REG = (1.1, 0.04)               # register centre on the counter top
SIGN_TILT = -2.5                # degrees about Blender +Y (Godot: +2.5 about +Z)
BOARD_TILT = 3.0


def hpipe(p0, p1, r, mat, name, verts=12):
    return pipe([p0, p1], r, verts=verts, mat=mat, name=name)


def bar(x, y, z0, z1, r, mat, name, verts=6):
    return cyl(r, z1 - z0, verts=verts, pos=(x, y, z0), bevel=0, mat=mat, name=name)


def rust_patch(width, height, x, y_face, z0=0.0, rot_z=0.0, seed=0.0, mat=None, name="rust"):
    """Rust creeping up a flat face: flat bottom at z0, wavy top edge (u along the face, v up), 6 mm thick,
    back on the face plane (y_face), facing -Y (rot_z = +-90 puts it on a side face)."""
    n = 12
    pts = [(-width / 2, 0.0), (width / 2, 0.0)]
    for i in range(n, -1, -1):
        t = i / n
        u = -width / 2 + width * t
        v = height * (0.66 + 0.2 * math.sin(t * 6.0 + seed) + 0.08 * math.sin(t * 11.0 + seed * 2))
        v *= 0.35 + 0.65 * math.sin(math.pi * t) ** 0.5    # soft shoulders at the ends
        pts.append((u, v))
    return extrude_profile(pts, 0.006, pos=(x, y_face, z0), rot=(0, 0, rot_z), bevel=0.0, mat=mat, name=name)


def tilted(objs, name, pivot, rot_deg):
    """Join `objs` (modelled around the origin) and place the result at `pivot`, rotated rot_deg (XYZ)."""
    o = join(objs, name)
    o.location = pivot
    o.rotation_euler = tuple(math.radians(a) for a in rot_deg)
    return o


def build():
    olive, steel, tin = lib("olive"), lib("metal_dark"), lib("metal")
    rust, caution, dark, cream = lib("rust"), lib("caution"), lib("dark"), lib("cream")
    glass, grime = lib("glass"), lib("concrete_dark")
    chalk = material("chalkboard", "#3a4a44", "matte")     # tired green-black slate
    wood = lib("brown")
    register_mat = lib("gray")
    seeds = tint_material("TINT_seeds")
    badge_mat = tint_material("TINT_badge")

    parts = []
    # --- counter ---------------------------------------------------------------------------------------------
    parts.append(box((W - 0.04, D - 0.04, 0.1), pos=(0, 0, 0), bevel=0.03, segments=1, mat=steel, name="plinth"))
    parts.append(box((W - 0.18, D - 0.16, 0.84), pos=(0, 0, 0.08), bevel=0.05, segments=2, mat=olive, name="body"))
    parts.append(box((W, D, 0.1), pos=(0, 0, TOP - 0.1), bevel=0.04, segments=2, mat=tin, name="slab"))
    # Fat rolled steel bumper along the customer edge, sagging a little in the middle (leaned on for years).
    parts.append(pipe([(-W / 2 + 0.04, -D / 2 + 0.01, TOP - 0.05), (-0.4, -D / 2 - 0.004, TOP - 0.054),
                       (0.3, -D / 2 - 0.012, TOP - 0.062), (W / 2 - 0.04, -D / 2 + 0.01, TOP - 0.05)],
                      0.05, verts=12, bend=0.3, mat=steel, name="bumper"))
    # Round corner guards (Kenney trims); the front right one took a forklift.
    for sx in (-1, 1):
        for sy in (-1, 1):
            p = (sx * (W / 2 - 0.1), sy * (D / 2 - 0.09), 0.08)
            lean = (-3.0, 2.5, 0) if (sx, sy) == (1, -1) else (0, 0, 0)   # knocked by a trolley
            parts.append(cyl(0.075, 0.84, verts=12, pos=p, rot=lean, bevel=0.02 if sy < 0 else 0, segments=1,
                             mat=steel, name="corner"))
    yf = -(D - 0.16) / 2   # body front face
    # Front: an olive panel framed in caution yellow, the three seed roundels on it.
    parts.append(box((2.84, 0.02, 0.5), pos=(0, yf - 0.005, BADGE_Z - 0.25), bevel=0.01, segments=1, mat=olive,
                     name="panel"))
    fr = [(1.44, BADGE_Z - 0.28), (1.44, BADGE_Z + 0.28), (-1.44, BADGE_Z + 0.28), (-1.44, BADGE_Z - 0.28)]
    parts.append(pipe([(0.0, yf - 0.015, fr[0][1])] + [(u, yf - 0.015, v) for u, v in fr] +
                      [(0.02, yf - 0.015, fr[0][1])], 0.032, verts=6, bend=0.07, mat=caution, name="border"))
    for u, v in fr:
        parts.append(cyl(0.028, 0.02, verts=6, pos=(u, yf - 0.04, v), rot=(90, 0, 0), bevel=0, mat=steel, name="bolt"))
    # Dark steel kick plate with hazard stripes along the bottom.
    parts.append(box((W - 0.34, 0.02, 0.16), pos=(0, yf - 0.006, 0.1), bevel=0.008, segments=1, mat=steel,
                     name="kick"))
    for i in range(9):
        u = -1.28 + 0.32 * i
        parts.append(extrude_profile([(u - 0.05, 0.12), (u + 0.03, 0.12), (u + 0.1, 0.24), (u + 0.02, 0.24)], 0.004,
                                     pos=(0, yf - 0.016, 0), bevel=0.0, mat=caution, name="stripe"))
    # Rust creeping up from the floor over the kick plate and the olive (front corners, sides).
    parts.append(rust_patch(0.66, 0.34, -1.12, yf - 0.02, z0=0.1, seed=0.4, mat=rust, name="rust_fl"))
    parts.append(rust_patch(0.5, 0.26, 1.2, yf - 0.02, z0=0.1, seed=2.1, mat=rust, name="rust_fr"))
    xs = (W - 0.18) / 2
    parts.append(rust_patch(0.72, 0.38, -xs, 0.05, z0=0.08, rot_z=-90, seed=1.3, mat=rust, name="rust_l"))
    parts.append(rust_patch(0.6, 0.3, xs, -0.1, z0=0.08, rot_z=90, seed=3.0, mat=rust, name="rust_r"))

    # --- the cage --------------------------------------------------------------------------------------------
    for sx in (-1, 1):  # bottom rail, open under the pay window
        parts.append(hpipe((sx * POST_X, CAGE_Y, TOP + 0.035), (sx * WINDOW, CAGE_Y, TOP + 0.035), 0.035, steel,
                           "rail_bottom"))
    parts.append(hpipe((-POST_X, CAGE_Y, CAGE_TOP), (POST_X, CAGE_Y, CAGE_TOP), 0.04, steel, "rail_top"))
    parts.append(hpipe((-WINDOW, CAGE_Y, WINDOW_Z), (WINDOW, CAGE_Y, WINDOW_Z), 0.032, steel, "header"))
    for sx in (-1, 1):
        x = sx * POST_X
        for y in (CAGE_Y, BACK_Y):
            parts.append(cyl(0.055, CAGE_TOP + 0.02 - TOP, verts=12, pos=(x, y, TOP), bevel=0, mat=steel, name="post"))
            if y == CAGE_Y:   # rusty ball caps on the front posts, plain caps at the back
                parts.append(sphere(0.07, pos=(x, y, CAGE_TOP + 0.05), segments=10, rings=5, mat=rust, name="knob"))
            else:
                parts.append(cyl(0.065, 0.03, verts=10, pos=(x, y, CAGE_TOP + 0.02), bevel=0, mat=rust, name="cap"))
        parts.append(hpipe((x, CAGE_Y, CAGE_TOP), (x, BACK_Y, CAGE_TOP), 0.035, steel, "side_top"))
        parts.append(hpipe((x, CAGE_Y, TOP + 0.03), (x, BACK_Y, TOP + 0.03), 0.03, steel, "side_bottom"))
        for y in (-0.05, 0.16, 0.37):
            parts.append(bar(x, y, TOP, CAGE_TOP, 0.022, steel, "side_bar", verts=6))
    # Front bars, BAR_STEP apart; the three in the pay window hang from the header. Rusted feet on most, one
    # rusty replacement, one bent outwards (someone pulled).
    for i in range(11):
        x = -1.5 + BAR_STEP * i
        z0 = WINDOW_Z if abs(x) < WINDOW - 0.01 else TOP
        if i == 0:
            parts.append(pipe([(x, CAGE_Y, z0), (x + 0.02, CAGE_Y - 0.09, 1.7), (x, CAGE_Y, CAGE_TOP)], 0.022,
                              verts=6, bend=0.25, mat=steel, name="bar_bent"))
        else:
            parts.append(bar(x, CAGE_Y, z0, CAGE_TOP, 0.022, rust if i == 2 else steel, "bar"))
        if z0 == TOP and i % 3 != 1:
            parts.append(cyl(0.027, 0.11 + 0.05 * (i % 2), verts=6, pos=(x, CAGE_Y, TOP), bevel=0, mat=rust,
                             name="bar_rust"))

    # --- pay slot: a dished steel tray passing under the window, "PAY HERE" plate above it ------------------
    parts.append(box((0.66, 0.46, 0.05), pos=(0, CAGE_Y - 0.05, TOP), bevel=0.02, segments=1, mat=steel, name="tray"))
    parts.append(box((0.54, 0.36, 0.012), pos=(0, CAGE_Y - 0.05, TOP + 0.045), bevel=0.0, mat=dark, name="tray_dish"))
    # cream "PAY HERE" plate riveted to the bumper right under the tray (the scene writes the text)
    parts.append(box((0.52, 0.02, 0.12), pos=(0, -D / 2 - 0.063, TOP - 0.145), bevel=0.008, segments=1, mat=cream,
                     name="pay_plate"))
    for u in (-0.22, 0.22):
        parts.append(cyl(0.016, 0.012, verts=6, pos=(u, -D / 2 - 0.072, TOP - 0.085), rot=(90, 0, 0), bevel=0,
                         mat=steel, name="pay_rivet"))

    # --- SUPPLY sign box on top of the cage, hung a bit crooked -----------------------------------------------
    sign_z = CAGE_TOP + 0.05
    sign_y = CAGE_Y + 0.02
    sign = [
        box((1.62, 0.26, 0.48), pos=(0, 0, 0), bevel=0.05, segments=2, mat=steel, name="sign_box"),
        box((1.48, 0.03, 0.36), pos=(0, -0.13, 0.06), bevel=0.012, segments=1, mat=caution, name="sign_face"),
        box((1.72, 0.32, 0.05), pos=(0, 0, 0.46), bevel=0.02, segments=1, mat=steel, name="sign_cap"),
    ]
    for u in (-0.66, 0.66):
        sign.append(cyl(0.022, 0.02, verts=6, pos=(u, -0.145, 0.37), rot=(90, 0, 0), bevel=0, mat=steel,
                        name="sign_bolt"))
    parts.append(tilted(sign, "sign_mesh", (0.0, sign_y, sign_z), (0, SIGN_TILT, 0)))
    for sx in (-1, 1):  # clamps holding it to the top rail
        parts.append(box((0.1, 0.12, 0.08), pos=(sx * 0.6, CAGE_Y, CAGE_TOP - 0.02), bevel=0.02, segments=1,
                         mat=steel, name="sign_clamp"))

    # --- chalk price board wired to the bars (right), crooked ---------------------------------------------------
    pb = (1.12, CAGE_Y - 0.045, 2.3)   # hang point (top edge centre)
    board = [
        box((0.8, 0.03, 0.62), pos=(0, 0, -0.62), bevel=0.014, segments=1, mat=wood, name="board_frame"),
        box((0.7, 0.012, 0.52), pos=(0, -0.018, -0.57), bevel=0.0, mat=chalk, name="board_slate"),
        box((0.14, 0.04, 0.03), pos=(0.24, -0.03, -0.62), bevel=0.01, segments=1, mat=cream, name="chalk_stub"),
    ]
    parts.append(tilted(board, "board_mesh", pb, (0, BOARD_TILT, 0)))
    parts.append(pipe([(pb[0] - 0.32, pb[1] + 0.01, pb[2] - 0.01), (pb[0] - 0.02, pb[1] + 0.012, CAGE_TOP - 0.03),
                       (pb[0] + 0.3, pb[1] + 0.01, pb[2] + 0.01)], 0.01, verts=4, bend=0.03, mat=dark, name="wire"))

    # --- service bell on the ledge -------------------------------------------------------------------------------
    bx, by = 0.66, -0.47
    parts.append(cyl(0.1, 0.03, verts=14, pos=(bx, by, TOP), bevel=0, mat=dark, name="bell_base"))
    dome = lathe([(0.0, 0.0), (0.09, 0.0), (0.086, 0.03), (0.07, 0.065), (0.04, 0.086), (0.0, 0.092)],
                 verts=14, pos=(bx, by, TOP + 0.028), mat=tin, name="bell_dome", smooth=60)
    dent(dome, (0.06, -0.045, 0.06), radius=0.045, depth=0.012)
    parts.append(dome)
    parts.append(cyl(0.012, 0.035, verts=6, pos=(bx, by, TOP + 0.11), bevel=0, mat=tin, name="bell_stem"))
    parts.append(sphere(0.024, pos=(bx, by, TOP + 0.15), segments=8, rings=4, mat=tin, name="bell_knob"))

    # --- grimy cash register (inside the cage, right) -------------------------------------------------------------
    rx, ry = REG
    # side profile drawn with u = depth (front -0.22, back 0.2), extruded 0.54 and turned to run along X
    reg_body = extrude_profile([(-0.22, 0.0), (0.2, 0.0), (0.2, 0.3), (0.06, 0.3), (-0.22, 0.15)], 0.54,
                               bevel=0.03, segments=1, mat=register_mat, name="reg_body")
    move_verts(reg_body, lambda co: Vector((rx - (co.y + 0.27), ry + co.x, TOP + co.z)))
    parts.append(reg_body)
    parts.append(box((0.5, 0.08, 0.1), pos=(rx, ry - 0.24, TOP + 0.01), bevel=0.015, segments=1, mat=steel,
                     name="drawer"))  # left a bit open
    parts.append(box((0.2, 0.03, 0.03), pos=(rx, ry - 0.29, TOP + 0.045), bevel=0.01, segments=1, mat=caution,
                     name="drawer_pull"))
    slope = math.degrees(math.atan2(0.15, 0.28))
    for i in range(2):          # two rows of chunky keys on the slope, one yellow key
        t = 0.3 + 0.36 * i
        parts.append(box((0.3, 0.06, 0.04), pos=(rx - 0.05, ry - 0.22 + 0.28 * t, TOP + 0.13 + 0.15 * t),
                         rot=(slope, 0, 0), bevel=0.015, segments=1, mat=cream, name="keys"))
    parts.append(box((0.09, 0.06, 0.04), pos=(rx + 0.17, ry - 0.22 + 0.28 * 0.3, TOP + 0.13 + 0.15 * 0.3),
                     rot=(slope, 0, 0), bevel=0.015, segments=1, mat=caution, name="key_total"))
    parts.append(box((0.12, 0.08, 0.14), pos=(rx, ry + 0.12, TOP + 0.29), bevel=0.02, segments=1, mat=register_mat,
                     name="stalk"))
    disp = [box((0.34, 0.1, 0.2), pos=(0, 0, 0), bevel=0.03, segments=1, mat=register_mat, name="display"),
            box((0.26, 0.02, 0.12), pos=(0, -0.05, 0.04), bevel=0.0, mat=dark, name="screen")]
    parts.append(tilted(disp, "display_mesh", (rx, ry + 0.13, TOP + 0.4), (-12, 0, 0)))
    parts.append(cyl(0.03, 0.08, verts=8, pos=(rx + 0.27, ry + 0.02, TOP + 0.14), rot=(0, 90, 0), bevel=0, mat=steel,
                     name="crank_hub"))
    parts.append(box((0.03, 0.03, 0.16), pos=(rx + 0.33, ry + 0.02, TOP + 0.06), bevel=0.01, segments=1, mat=steel,
                     name="crank_arm"))
    parts.append(sphere(0.035, pos=(rx + 0.36, ry + 0.02, TOP + 0.07), segments=8, rings=4, mat=rust,
                        name="crank_knob"))
    parts.append(box((0.22, 0.004, 0.07), pos=(rx - 0.1, ry - 0.224, TOP + 0.03), bevel=0.0, mat=grime,
                     name="reg_grime"))

    # --- the Boss's step (behind the counter) --------------------------------------------------------------------
    parts.append(box((1.0, 0.8, 0.2), pos=(0, 0.95, 0), bevel=0.03, segments=1, mat=steel, name="step"))

    counter = join(parts, "Counter")

    # --- jars: glass + lid + cream label (Glass), TINT seed pile (Fill) ---------------------------------------------
    jars_root = empty("Jars", (0, 0, 0))
    glass_prof = [(0.0, 0.0), (0.118, 0.0), (0.132, 0.025), (0.132, 0.235), (0.112, 0.285), (0.0, 0.29)]
    for i, (x, fill) in enumerate(zip(JAR_X, JAR_FILL), start=1):
        node = empty("Jar%d" % i, (x, JAR_Y, TOP))
        g = lathe(glass_prof, verts=12, mat=glass, name="glass", smooth=55)
        label = arc_panel(0.133, 0.08, angle=110, thickness=0.004, pos=(0, 0, 0.1), segments=5, mat=cream,
                          name="label")
        lid = cyl(0.13, 0.05, verts=12, pos=(0, 0, 0.29), bevel=0.012, segments=1, mat=steel, name="lid")
        knob = sphere(0.038, pos=(0, 0, 0.35), segments=8, rings=4, mat=rust, name="lid_knob")
        if i == 2:  # a crooked lid, the knob riding along
            lid.location = (0.0, 0.0, 0.292)
            lid.rotation_euler = (math.radians(5), math.radians(-6), 0)
            knob.location = (-0.006, -0.005, 0.348)
        shell = join([g, label, lid, knob], "Glass__%d" % i)
        top = fill + 0.02
        pile = lathe([(0.0, 0.01), (0.114, 0.01), (0.118, 0.03), (0.118, fill), (0.09, top + 0.004),
                      (0.045, top + 0.018), (0.0, top + 0.022)], verts=9, mat=seeds, name="pile", smooth=70)
        jitter(pile, 0.005, seed=11 + i)
        fill_obj = join([pile], "Fill__%d" % i)
        for o in (shell, fill_obj):
            o.location = (x, JAR_Y, TOP)
            set_parent(o, node)
        set_parent(node, jars_root)

    # --- seed roundels on the counter front: TINT face in a caution ring --------------------------------------------
    by_ = yf - 0.015
    badges_root = empty("Badges", (0, by_, BADGE_Z))
    for i, x in enumerate(BADGE_X, start=1):
        node = empty("Badge%d" % i, (x, by_, BADGE_Z))
        ring_ = join([cyl(0.19, 0.03, verts=20, pos=(0, 0, 0), rot=(90, 0, 0), bevel=0, mat=caution,
                          name="ring")], "Ring__%d" % i)
        face = join([cyl(0.145, 0.03, verts=18, pos=(0, -0.022, 0), rot=(90, 0, 0), bevel=0.014, segments=1,
                         mat=badge_mat, name="face")], "Face__%d" % i)
        for o in (ring_, face):
            o.location = (x, by_, BADGE_Z)
            set_parent(o, node)
        set_parent(node, badges_root)

    # --- label anchors (empties at the face centres; the scene hangs its Label3Ds on them) ----------------------
    t = math.radians(SIGN_TILT)
    anchors = [
        empty("Sign", (0.24 * math.sin(t), sign_y - 0.146, sign_z + 0.24 * math.cos(t))),
        empty("PriceBoard", (pb[0] - 0.31 * math.sin(math.radians(BOARD_TILT)), pb[1] - 0.026, pb[2] - 0.31)),
        empty("Register", (rx, ry, TOP)),
        empty("PayPlate", (0.0, -D / 2 - 0.074, TOP - 0.085)),
    ]
    # Budget 6000 (station default 5000): this station is four props in one (counter + cage, register, three
    # jars, bell) plus two signs; everything small is already at 6-12 segments.
    export([counter, jars_root, badges_root] + anchors, "shop_cage", kind="station", mount="floor", budget=6000)
