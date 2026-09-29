"""fuse_box: the breaker cabinet the workers find in the dark and reset after a power cut (station visual,
rigged). M10 events: scenes/stations/fuse_box.tscn (events agent) instances it under `Visual`; the lead swaps
the placeholder primitives for it and fuse_box.gd flips the `Lever`.

Wall mount: back on the wall plane, origin = the bottom centre of the cabinet ON the wall. Place the
scene's model node at the mounting height (~1.1 m up the wall), so the lever sits at ~1.45 m.
0.51 x 0.85 x 0.32 m (W x H x D, Godot; the conduit stubs on top, the lever sticking out and the rust
drips 5 cm below the cabinet included).
  <Visual, Toonify> / Cabinet   steel body + hood, the ajar door (crooked 3 deg), the caution "FUSES" plate,
                                two conduit stubs (one bent), a sagging cable, rust drips (static)
                    / Lever     the big breaker handle on the right of the door: pivot = its axle (node
                                origin, Godot (0.175, 0.34, 0.225)), rest = pointing UP (Godot +Y) and 12 deg
                                out of the wall, red grip. `Lever.rotation.x = deg_to_rad(130)` throws it
                                down and out of the wall (tripped); tween it back to 0 on reset.
Sad: the door hangs open on one good hinge, crooked; rust runs down from the bottom corners; the paint is
scuffed to bare steel round the lever; one conduit is bent and its cable sags loose down the wall.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

W, D, H = 0.46, 0.18, 0.64             # cabinet body
YF = -D                                 # the body's front face
DOOR_W, DOOR_H, DOOR_T = 0.3, 0.44, 0.03
DOOR_X, DOOR_Z = -0.2, 0.06            # hinge edge (left) / bottom
AJAR, TILT = -11.0, 3.0                 # open about the hinge (deg about Z) / crooked (deg about the wall normal)
P = Vector((0.175, YF - 0.045, 0.34))  # lever axle (pivot), on the right of the door, clear of the plate


def build():
    steel = lib("metal_dark")
    bare = lib("metal")                 # bare steel: hinges, axle, scuffs
    caution = lib("caution")
    ink = material("stencil", pal("INK"), "flat")
    void = lib("void")
    rust = lib("rust")
    grip_mat = lib("red")               # the one bright signal: the breaker

    cab = []
    # ---- Body: fat rounded box on the wall, a hooded top that overhangs, a dark slot behind the door.
    cab.append(box((W, D, H), pos=(0, -D / 2, 0), bevel=0.02, segments=2, mat=steel, name="body"))
    cab.append(box((W + 0.05, D + 0.03, 0.045), pos=(0, -(D + 0.03) / 2, H - 0.012), bevel=0.012, segments=2,
                   mat=steel, name="hood"))
    cab.append(box((DOOR_W - 0.02, 0.02, DOOR_H - 0.02), pos=(DOOR_X + DOOR_W / 2, YF + 0.006, DOOR_Z + 0.01), bevel=0,
                   mat=void, name="slot"))                    # the dark inside, seen through the open gap
    # ---- Door: built with its hinge line on the world origin, then swung open + hung crooked.
    door = box((DOOR_W, DOOR_T, DOOR_H), pos=(DOOR_W / 2, -DOOR_T / 2, 0), bevel=0.012, segments=2, mat=steel,
               name="door")
    subdivide(door, 4)
    dent(door, local(door, (0.21, -DOOR_T, 0.16)), radius=0.09, depth=0.012, direction=(0, 1, 0))
    vents = [box((0.15, 0.004, 0.012), pos=(0.12, -DOOR_T - 0.001, z), bevel=0, mat=void, name="vent")
             for z in (0.33, 0.36, 0.39)]
    handle = box((0.026, 0.024, 0.07), pos=(0.262, -DOOR_T - 0.012, 0.2), bevel=0.006, segments=1, mat=bare,
                 name="handle")
    scuff = extrude_profile([(0.2, 0.05), (0.27, 0.06), (0.285, 0.1), (0.26, 0.14), (0.22, 0.12), (0.19, 0.08)],
                            0.002, pos=(0, -DOOR_T + 0.0005, 0), bevel=0, mat=bare, name="door_scuff")
    hang = (Matrix.Translation((DOOR_X, YF - 0.004, DOOR_Z)) @ Matrix.Rotation(math.radians(AJAR), 4, 'Z')
            @ Matrix.Rotation(math.radians(TILT), 4, 'Y'))
    for o in [door, handle, scuff] + vents:
        placed(o, hang @ o.matrix_basis)
        cab.append(o)
    for z in (DOOR_Z + 0.06, DOOR_Z + DOOR_H - 0.1):          # hinges on the frame edge (the top one holds)
        cab.append(box((0.018, 0.022, 0.05), pos=(DOOR_X - 0.004, YF - 0.012, z), bevel=0.004, segments=1,
                       mat=bare, name="hinge"))
    # ---- "FUSES": caution plate above the door, stencil letters sunk 1 mm into it.
    pz, px = 0.565, -0.045                                   # left of the lever's swing
    cab.append(extrude_profile(rounded_rect(0.34, 0.11, 0.014, cx=px), 0.01, pos=(0, YF + 0.004, pz), bevel=0.004,
                               mat=caution, name="plate"))
    cab += stencil("FUSES", 0.066, pos=(px, YF - 0.005, pz - 0.033), depth=0.004, mat=ink, name="letter")
    # ---- Lever mount: two bracket ears + the axle (static); a scuff ring of bare steel round them.
    for sx in (-1, 1):
        cab.append(box((0.014, 0.065, 0.1), pos=(P.x + sx * 0.03, YF - 0.0325 + 0.001, P.z - 0.05), bevel=0.004,
                       segments=1, mat=steel, name="ear"))
    cab.append(cyl(0.012, 0.09, verts=12, pos=P, rot=(0, 90, 0), bevel=0.003, segments=1, mat=bare, anchor="center",
                   name="axle"))
    cab.append(extrude_profile([(0.12, 0.25), (0.2, 0.23), (0.228, 0.29), (0.226, 0.42), (0.2, 0.46), (0.13, 0.44),
                                (0.115, 0.36)], 0.002, pos=(0, YF + 0.0005, 0), bevel=0, mat=bare, name="scuff"))
    # ---- Conduit stubs on top (the right one knocked crooked), a loose cable sagging out of it.
    for x, tilt in ((-0.12, 0.0), (0.1, -7.0)):
        cab.append(cyl(0.028, 0.11, verts=14, pos=(x, -0.09, H + 0.02), rot=(0, tilt, 0), bevel=0.006, segments=1,
                       mat=steel, name="conduit"))
        cab.append(cyl(0.038, 0.03, verts=14, pos=(x, -0.09, H + 0.02), rot=(0, tilt, 0), bevel=0.006, segments=1,
                       mat=steel, name="collar"))
    cab.append(pipe([(0.115, -0.1, H + 0.12), (0.14, -0.12, H + 0.16), (0.235, -0.07, H + 0.02),
                     (0.245, -0.03, 0.28), (0.24, -0.02, 0.1)], 0.009, verts=8, bend=0.05, mat=void, name="cable"))
    # ---- Rust: drips running down from the two bottom corners of the front, over the bevel onto the wall.
    for sx in (-1, 1):
        pts = [(0.21, 0.02), (0.21, 0.12), (0.19, 0.16), (0.175, 0.1), (0.15, 0.13), (0.135, 0.07), (0.105, 0.09),
               (0.09, 0.03), (0.08, 0.02)]
        cab.append(extrude_profile([(sx * u, v) for u, v in (pts if sx > 0 else pts[::-1])], 0.002,
                                   pos=(0, YF + 0.0005, 0), bevel=0, mat=rust, name="rust_drip"))
        wall = [(0.155, 0.0), (0.225, 0.0), (0.22, -0.02), (0.205, -0.05), (0.195, -0.025), (0.18, -0.035), (0.165, -0.015)]
        cab.append(extrude_profile([(sx * u, v) for u, v in (wall if sx > 0 else wall[::-1])], 0.003,
                                   pos=(0, 0.0, 0), bevel=0, mat=rust, name="rust_wall"))   # on the wall itself
    cabinet = join(cab, "Cabinet")

    # ---- Lever (rigged): arm from the axle up and a little out of the wall, a fat red grip, a knuckle on the axle.
    along = Vector((0, -math.sin(math.radians(12)), math.cos(math.radians(12))))   # up and a little out
    arm = box((0.04, 0.034, 0.21), pos=P, rot=(12, 0, 0), bevel=0.01, segments=1, mat=steel, name="arm")
    grip = capsule(0.036, 0.14, pos=P + along * 0.18, rot=(12, 0, 0), verts=14, rings=6, mat=grip_mat, name="grip")
    knuckle = cyl(0.03, 0.056, verts=14, pos=P, rot=(0, 90, 0), bevel=0.006, segments=1, mat=steel, anchor="center",
                  name="knuckle")
    lever = join([arm, grip, knuckle], "Lever", origin=P)

    export([cabinet, lever], "fuse_box", kind="prop", mount="wall")
