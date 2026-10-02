"""van: the crew's beat-up panel van (M14 lobby). It waits in the alley with its rear doors open; the shift
starts when every worker stands in the back. The level agent parks a second one at the loading dock as decor.

Front of the MODEL = the REAR of the van (the open doors are what the workers look at), so in Godot the rear
opening faces +Z and the nose points at -Z. Floor mount.
ORIGIN: on the ground under the centre of the REAR AXLE. Godot metres from there:
  rear sill (where you step in)   z = +0.75          cargo floor top   y = 0.45
  bulkhead (end of the cargo bay) z = -2.05          cargo ceiling     y = 2.42
  cargo bay inside                x = -0.9 .. +0.9   (1.8 wide x 2.8 long x 1.97 high)
  bumper step                     z = +0.75 .. +1.07, top y = 0.25
  nose (front bumper)             z = -4.07          roof y = 2.52, body sides x = +-1.0 (wheels +-1.14)
  open door tips                  x = +-1.16, z = +1.65
Size about 2.4 x 2.52 x 5.75 m (W x H x D) with the doors open.

  <root, Toonify> / Body       everything that does not move (shell, cab, wheels, bumpers, step, lining)
                  / DoorLeft   the leaf on the viewer's left (Godot -X). Pivot on its hinge at the floor of the
                               opening (Godot (-0.93, 0.47, 0.78)). REST = OPEN (swung out 105 degrees);
                               `DoorLeft.rotation.y = deg_to_rad(105)` shuts it.
                  / DoorRight  the leaf on the right (Godot +X), pivot (0.93, 0.47, 0.78), rest = open;
                               `DoorRight.rotation.y = deg_to_rad(-105)` shuts it.
TINT: the paint (`TINT_paint`) and the faded side stripe (`TINT_stripe`, shade 0.62): give the root a `tint`
(a grubby off-white reads as "the white van"); without one it stays neutral grey.
Sad: a primer-grey replacement panel riveted onto the left side, rust creeping up from the sills and around the
arches, a dead headlight and a dead tail light, one hubcap gone, a boot dent in each door, a mirror hanging by
its stalk, the front bumper sagging, the plate on one screw, "FLORIST" on the side with two letters scraped off.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

W = 2.0                 # body width
HW = W / 2
YR = -0.75              # rear face (the origin is under the rear axle)
YN = YR + 4.65          # nose
Z0, ZT = 0.28, 2.52     # underside, roof
FLOOR = 0.45            # cargo floor top
CEIL = 2.42             # cargo ceiling
BAY = 2.8               # cargo bay length
IN = 0.9                # half the cargo bay width
AXLES = (0.0, 2.9)      # rear, front
WHEEL_R = 0.36
DOOR_OPEN = 105.0       # degrees each leaf is swung out at rest
HINGE_X = 0.93
HINGE_Y = YR - 0.03
DOOR_Z0 = FLOOR + 0.02


def side(points, depth, x, mat, name, bevel=0.0):
    """A shape drawn in the van's side view (u = towards the nose, v = up), extruded `depth` metres from the
    plane x towards +X."""
    o = extrude_profile(points, depth, pos=(x, 0, 0), rot=(0, 0, 90), bevel=bevel, mat=mat, name=name)
    apply_transform(o)
    return o


def both_sides(points, depth, proud, mat, name, bevel=0.0):
    """The same side-view shape stuck on both flanks, `proud` metres out of the paint."""
    return [side(points, depth, HW + proud - depth, mat, name, bevel), side(points, depth, -HW - proud, mat, name, bevel)]


def arc(cy, cz, r, a0, a1, n):
    return [(cy + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cz + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
            for i in range(n + 1)]


def door(sign, paint_mat, glass, bare, rust, dark):
    """One rear leaf, built SHUT (in the opening, outer face towards -Y), then swung open about its hinge.
    sign = -1: the left leaf (hinge at x = -HINGE_X), +1: the right one."""
    parts = []
    width, thick, height = 0.9, 0.05, CEIL - DOOR_Z0 - 0.02
    cx = sign * (HINGE_X - 0.015 - width / 2)
    leaf = box((width, thick, height), pos=(cx, HINGE_Y, DOOR_Z0), bevel=0.014, segments=2, mat=paint_mat, name="leaf")
    subdivide(leaf, 4)
    # A boot dent low on the leaf (pushed into the van).
    dent(leaf, (sign * 0.1, -thick / 2, 0.42), radius=0.2, depth=0.028, direction=(0, 1, 0))   # mesh-local point
    parts.append(leaf)
    # The window: one dark pane that shows on both faces.
    parts.append(box((0.52, thick + 0.012, 0.5), pos=(cx, HINGE_Y, DOOR_Z0 + 1.22), bevel=0.006, segments=1, mat=glass,
                     name="pane"))
    # Hinges on the outer edge, a rust streak under the lower one.
    for z in (DOOR_Z0 + 0.3, DOOR_Z0 + 1.6):
        parts.append(box((0.05, thick + 0.03, 0.12), pos=(sign * (HINGE_X - 0.02), HINGE_Y, z), bevel=0.006, segments=1,
                         mat=bare, name="hinge"))
    yo = HINGE_Y - thick / 2      # outer face
    rx = [(-0.4, 0.0), (-0.4, 0.07), (-0.3, 0.05), (-0.22, 0.12), (-0.1, 0.06), (0.02, 0.1), (0.16, 0.04), (0.3, 0.09),
          (0.4, 0.05), (0.4, 0.0)]
    parts.append(extrude_profile([(cx + u, DOOR_Z0 + 0.012 + v) for u, v in rx], 0.003, pos=(0, yo + 0.001, 0), bevel=0,
                                 mat=rust, name="door_rust"))
    if sign > 0:
        # The right leaf carries the handle and the lock bar.
        hx = cx - 0.36
        parts.append(box((0.035, 0.03, 1.5), pos=(hx, yo - 0.015, DOOR_Z0 + 0.2), bevel=0.008, segments=1, mat=bare,
                         name="lock_bar"))
        parts.append(box((0.16, 0.04, 0.05), pos=(hx + 0.06, yo - 0.035, DOOR_Z0 + 0.9), rot=(0, 9, 0), bevel=0.01,
                         segments=1, mat=dark, name="handle"))
    hinge = (sign * HINGE_X, HINGE_Y, DOOR_Z0)
    leaf_obj = join(parts, "DoorLeft" if sign < 0 else "DoorRight", origin=hinge)
    # Rest pose = open: the left leaf swings clockwise seen from above, the right one the other way.
    leaf_obj.data.transform(Matrix.Rotation(math.radians(sign * DOOR_OPEN), 4, 'Z'))
    leaf_obj.data.update()
    return leaf_obj


def build():
    paint_mat = tint_material("TINT_paint")
    stripe = tint_material("TINT_stripe", shade=0.62)
    primer = lib("gray")
    steel = lib("metal_dark")
    bare = lib("metal")
    rust = lib("rust")
    dark = lib("dark")
    wood = lib("wood")
    damp = lib("brown")
    glass = material("van_glass", "#232a35", "glossy")
    lamp = material("van_lamp", pal("CREAM"), "flat")
    lamp_dead = material("van_lamp_dead", "#4a4d55", "soft")
    tail = material("van_tail", pal("TOMATO"), "flat")
    ink = material("van_letter", pal("INK"), "soft")
    plate = lib("cream")

    b = []

    # ---- Shell: the side silhouette pushed across the whole width, then the cargo bay carved out of it.
    hood_y, shield_top_y, roof_front_y = YN - 0.72, YN - 1.42, YN - 1.64
    prof = [(YR, Z0), (YN - 0.06, Z0), (YN, Z0 + 0.2), (YN, 1.02), (YN - 0.1, 1.2), (hood_y, 1.36),
            (shield_top_y, 2.4), (roof_front_y, ZT), (YR + 0.03, ZT), (YR, ZT - 0.04)]
    shell = side(prof, W, -HW, paint_mat, "shell")
    boolean_cut(shell, box((2 * IN, BAY + 0.3, CEIL - (FLOOR - 0.02)), pos=(0, YR + BAY / 2 - 0.15, FLOOR - 0.02), bevel=0,
                           name="bay"))
    # Inside the bay: bare dark steel.
    paint(shell, steel, lambda c, n: abs(c.x) <= IN + 0.005 and YR + 0.01 < c.y <= YR + BAY + 0.005
          and FLOOR - 0.03 <= c.z <= CEIL + 0.005)
    bevel(shell, 0.05, 2)
    b.append(shell)

    # ---- Cargo bay: a plywood floor sheet (top = FLOOR), a damp end by the doors, plywood lining on the walls.
    b.append(box((2 * IN - 0.02, BAY - 0.5, 0.02), pos=(0, YR + 0.5 + (BAY - 0.5) / 2 - 0.01, FLOOR - 0.02), bevel=0.004,
                 segments=1, mat=wood, name="floor"))
    b.append(box((2 * IN - 0.02, 0.5, 0.02), pos=(0, YR + 0.25, FLOOR - 0.02), bevel=0.004, segments=1, mat=damp,
                 name="floor_damp"))
    for sx in (-1, 1):
        b.append(box((0.02, BAY - 0.3, 1.1), pos=(sx * (IN - 0.01), YR + BAY / 2 + 0.05, FLOOR + 0.05), bevel=0.004,
                     segments=1, mat=wood, name="lining"))
    # Two roof ribs.
    for y in (YR + 0.9, YR + 1.9):
        b.append(box((2 * IN, 0.06, 0.04), pos=(0, y, CEIL - 0.04), bevel=0.008, segments=1, mat=steel, name="rib"))

    # ---- Cab glass: the windscreen on the rake, a window on each flank.
    slope = math.atan2(hood_y - shield_top_y, 2.4 - 1.36)          # lean of the screen from vertical
    my, mz = (hood_y + shield_top_y) / 2, (1.36 + 2.4) / 2
    ny, nz = math.cos(slope), math.sin(slope)                      # outward normal (towards the nose, up)
    b.append(box((W - 0.3, 0.02, 0.98), pos=(0, my + ny * 0.0, mz + nz * 0.0), rot=(math.degrees(slope), 0, 0), bevel=0.008,
                 segments=1, mat=glass, name="windscreen", anchor="center"))
    win = [(YR + BAY + 0.2, 1.42), (hood_y - 0.14, 1.42), (shield_top_y - 0.03, 2.2), (YR + BAY + 0.2, 2.2)]
    b += both_sides(win, 0.014, 0.006, glass, "cab_window")
    # A wiper, stuck half way.
    b.append(box((0.62, 0.02, 0.025), pos=(-0.25, my + ny * 0.02 + 0.12, mz + nz * 0.02 - 0.2), rot=(math.degrees(slope), 24, 0),
                 bevel=0.004, segments=1, mat=dark, name="wiper", anchor="center"))

    # ---- Nose: grille, headlights (the right one dead), a sagging bumper, the plate on one screw.
    b.append(box((1.1, 0.03, 0.3), pos=(0, YN + 0.012, 0.62), bevel=0.01, segments=1, mat=dark, name="grille"))
    for i in range(4):
        b.append(box((1.0, 0.02, 0.025), pos=(0, YN + 0.03, 0.66 + i * 0.065), bevel=0.004, segments=1, mat=steel,
                     name="grille_bar"))
    for sx, m in ((-1, lamp), (1, lamp_dead)):
        b.append(cyl(0.13, 0.04, verts=20, pos=(sx * 0.74, YN + 0.035, 0.78), rot=(90, 0, 0), bevel=0.008, segments=1,
                     mat=bare, name="lamp_rim"))
        b.append(cyl(0.1, 0.02, verts=20, pos=(sx * 0.74, YN + 0.05, 0.78), rot=(90, 0, 0), bevel=0.004, segments=1, mat=m,
                     name="lamp"))
    b.append(box((W + 0.12, 0.16, 0.2), pos=(0, YN + 0.07, 0.25), rot=(0, 2.2, 0), bevel=0.04, segments=2, mat=steel,
                 name="bumper_front"))
    b.append(box((0.42, 0.012, 0.14), pos=(0.12, YN + 0.156, 0.3), rot=(0, -11, 0), bevel=0.004, segments=1, mat=plate,
                 name="plate_front"))

    # ---- Wheels (outside the cargo walls, so nothing pokes into the bay), hubcaps (rear left lost its one),
    # an eyebrow over each arch.
    for k, ay in enumerate(AXLES):
        for sx in (-1, 1):
            x0 = HW - 0.06 if sx > 0 else -HW - 0.14
            b.append(cyl(WHEEL_R, 0.2, verts=20, pos=(x0, ay, WHEEL_R), rot=(0, 90, 0), bevel=0.05, segments=1, mat=dark,
                         name="tyre"))
            lost = k == 0 and sx < 0
            hub_x = x0 + (0.2 if sx > 0 else -0.02)
            b.append(cyl(0.12 if lost else 0.21, 0.02, verts=16, pos=(hub_x, ay, WHEEL_R), rot=(0, 90, 0), bevel=0.006,
                         segments=1, mat=rust if lost else bare, name="hub"))
        brow = arc(ay, WHEEL_R, 0.5, 8, 172, 8) + arc(ay, WHEEL_R, 0.41, 172, 8, 8)
        b += both_sides(brow, 0.07, 0.07, steel, "arch", bevel=0.012)

    # ---- Flanks: rust creeping up from the sills, the faded stripe, FLORIST (two letters scraped off).
    sill = [(YR + 0.5, Z0 + 0.03), (YR + 0.5, 0.44), (YR + 0.72, 0.52), (YR + 0.95, 0.4), (YR + 1.3, 0.47), (YR + 1.7, 0.38),
            (YR + 2.1, 0.5), (YR + 2.35, 0.4), (YR + 2.35, Z0 + 0.03)]
    b += both_sides(sill, 0.004, 0.004, rust, "sill_rust")
    cab_rust = [(YN - 1.5, Z0 + 0.03), (YN - 1.5, 0.42), (YN - 1.25, 0.5), (YN - 1.0, 0.4), (YN - 0.75, 0.46),
                (YN - 0.75, Z0 + 0.03)]
    b += both_sides(cab_rust, 0.004, 0.004, rust, "cab_rust")
    band = [(YR + 0.12, 1.02), (hood_y - 0.2, 1.02), (hood_y - 0.2, 1.2), (YR + 0.12, 1.2)]
    b += both_sides(band, 0.004, 0.003, stripe, "stripe")
    for sx in (-1, 1):
        letters = stencil("FL RI T" if sx > 0 else "F ORIS", 0.3, pos=(0, 0, 1.52), depth=0.004, mat=ink, name="letter")
        # Written towards -Y; turn the word onto the flank (reading from outside) and slide it along the bay.
        turn = Matrix.Rotation(math.radians(90 * sx), 4, 'Z')
        m = Matrix.Translation((sx * (HW + 0.002), YR + 1.35, 0)) @ turn
        for o in letters:
            b.append(placed(o, m @ o.matrix_basis))
    # The left flank's replacement panel: primer grey, riveted, never painted.
    patch = [(YR + 1.45, 0.62), (YR + 2.55, 0.6), (YR + 2.57, 1.0), (YR + 1.44, 0.98)]
    b.append(side(patch, 0.012, -HW - 0.012, primer, "patch", bevel=0.004))
    for (py, pz) in ((YR + 1.5, 0.67), (YR + 2.5, 0.65), (YR + 2.51, 0.94), (YR + 1.5, 0.93), (YR + 2.0, 0.64), (YR + 2.0, 0.95)):
        b.append(cyl(0.016, 0.012, verts=8, pos=(-HW - 0.012, py, pz), rot=(0, -90, 0), bevel=0, mat=bare, name="rivet"))
    # Mirrors: the left one hangs by its stalk.
    for sx, droop in ((-1, 62.0), (1, 0.0)):
        root = Vector((sx * HW, hood_y - 0.05, 1.5))
        stalk = box((0.22, 0.03, 0.03), pos=(sx * 0.11, 0, 0), bevel=0.008, segments=1, mat=steel, name="stalk",
                    anchor="center")
        head = box((0.06, 0.05, 0.26), pos=(sx * 0.22, 0, 0), bevel=0.012, segments=1, mat=dark, name="mirror",
                   anchor="center")
        m = Matrix.Translation(root) @ Matrix.Rotation(math.radians(sx * droop), 4, 'Y')
        for o in (stalk, head):
            b.append(placed(o, m @ o.matrix_basis))

    # ---- Rear: the bumper step, tail lights on the posts (the left one dead), the plate.
    b.append(box((1.84, 0.32, 0.13), pos=(0, YR - 0.16, 0.12), bevel=0.03, segments=2, mat=steel, name="step"))
    for sx in (-1, 1):
        b.append(box((0.08, 0.1, 0.14), pos=(sx * 0.6, YR - 0.03, 0.14), bevel=0.01, segments=1, mat=steel, name="step_arm"))
    b.append(box((1.5, 0.02, 0.03), pos=(0, YR - 0.31, 0.235), bevel=0.004, segments=1, mat=lib("caution"), name="step_edge"))
    for sx, m in ((-1, lamp_dead), (1, tail)):
        b.append(box((0.07, 0.02, 0.26), pos=(sx * (IN + 0.05), YR - 0.008, 1.02), bevel=0.006, segments=1, mat=m,
                     name="tail_light"))
    b.append(box((0.42, 0.012, 0.14), pos=(-0.3, YR - 0.326, 0.1), rot=(0, 7, 0), bevel=0.004, segments=1, mat=plate,
                 name="plate_rear"))
    # The underside between the wheels: a dark slab so nobody sees through the van from a crouch.
    b.append(box((W - 0.5, 4.1, 0.1), pos=(0, YR + 2.25, Z0 - 0.1), bevel=0.02, segments=1, mat=dark, name="chassis"))
    b.append(pipe([(0.55, YR + 0.2, Z0 - 0.04), (0.55, YR - 0.02, Z0 - 0.04), (0.6, YR - 0.2, Z0 - 0.07)], 0.035, verts=8,
                  mat=rust, name="exhaust"))

    body = join(b, "Body")
    left = door(-1, paint_mat, glass, bare, rust, dark)
    right = door(1, paint_mat, glass, bare, rust, dark)
    export([body, left, right], "van", kind="prop", mount="floor", budget=7000)
