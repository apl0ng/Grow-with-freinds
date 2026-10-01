"""trouble: the three M12 models for the things that go wrong on purpose (strains agent; FRIENDSLOP.md section 7,
CONTRACTS.md "M12 / Strains"). One family, three GLBs. Build only this family:
  blender --background --python tools/blender/build.py -- trouble

hostile_plant      kind "character" (the mouth faces Godot -Z), floor mount, origin under the body between the root
                   legs. About 0.9 x 1.1 x 0.9 m (W x H x D, Godot). The lead swaps it into the hostile agent's
                   scenes/npcs/hostile_plant.tscn: instance the glb AS `Visual` (outline_width ~0.02) and set
                   `tint = Toon.grade(seed.color)` on the root: the bud is TINT_bud, its underside and lips
                   TINT_bud_dark (shade 0.7).
                     <Visual, Toonify> / Body   the uprooted bud (TINT), four dry collar leaves, two heavy-lidded
                                               ink eyes, the upper lip and teeth, five gnarled root legs on flat
                                               root pads, soil clods and root hairs (static)
                                       / Jaw    lower lip + chin + three lower teeth: pivot on the mouth hinge (node
                                               origin, Godot about (0, 0.60, -0.25), printed by the build), rest =
                                               mouth closed; `Jaw.rotation.x = deg_to_rad(-35)` drops it open (a bite).
emergency_cabinet  kind "prop" (front -> Godot +Z), wall mount: back on the wall plane, origin at the BACK CENTRE of
                   the box (the body spans Godot y -0.3..0.3, z 0..0.2; the rust runs 5 cm further down the wall).
                   0.45 x 0.6 x 0.2 m (+ the chain: ~0.49 wide).
                     <Visual, Toonify> / Box    red steel box, dark interior, steel frame with a hinge, a latch and
                                               three of four screws, "FIRE" caution plate, "DEPOSIT" stencilled below
                                               the glass, a hook with an empty chain where the hammer was, rust (static)
                                       / Glass  the pane over the opening (its own mesh: hide it while `broken`)
                                       / Stock  empty socket at the interior centre (Godot (0, 0, 0.10)) for whatever
                                               the scene shows behind the glass
flamethrower       kind "item" (nozzle -> Godot -Z), mount "free": the origin is INSIDE THE GRIP (the hand) and the
                   model hangs around it: nozzle tip at Godot z -0.33, tank valve at z +0.31, tank bottom at y -0.066,
                   grip bottom at y -0.08, hose top at y +0.18. About 0.14 x 0.26 x 0.64 m, budget 2500.
                     <Visual, Toonify> / Gun     grip, trigger + guard, receiver tube, flared nozzle (sooted), the red
                                                tank slung under the receiver behind the grip, its strap, hose, dial,
                                                peeling label (static)
                                       / Gauge   empty at the bottom of the fuel sight glass on the tank's rear cap
                                                (the holder's side) / Fill  the fuel bar, centred on its own node,
                                                GAUGE_H (0.08 m) tall at scale 1: like the watering can, set
                                                Fill.scale.y = fuel / max and Fill.position.y = 0.08 * frac / 2.
Sad: the plant hangs its head, its leaves are dry and droop, soil still clings to the roots, one leg is shorter and
a patch of it has rotted; the cabinet has lost its hammer (the chain hangs empty), a screw and some paint, and has
been kicked; the flamethrower's tank is chipped to bare metal, the nozzle is sooted and the label peels.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401


def godot_char(p):
    """A Blender point of a `character` / `item` model in Godot coordinates (the 180 deg turn included)."""
    return (-p.x, p.z, p.y)


# ============================================================================================ hostile plant
TILT = 8.0                                   # the bud hangs its head forward (deg about X)
_R = Matrix.Rotation(math.radians(TILT), 3, 'X')


def on_bud(p):
    """A point given in the upright bud's frame, placed on the tilted bud."""
    return _R @ Vector(p)


def _dir(azimuth_deg):
    """Horizontal unit vector `azimuth_deg` degrees around from the front (-Y) towards +X."""
    a = math.radians(azimuth_deg)
    return Vector((math.sin(a), -math.cos(a), 0.0))


def hostile_plant():
    reset()
    bud = tint_material("TINT_bud")
    bud_dark = tint_material("TINT_bud_dark", shade=0.7)
    root = material("root", mix(pal("COCOA"), pal("SOIL"), 0.5), "matte")
    leaf = lib("leaf_dry")
    void = lib("void")
    tooth = lib("cream")
    eye, lid = lib("eye_black"), lib("eyelid")

    parts = []
    # ---- The bud: a fat ribbed cola from z 0.40 to 1.10, poles at both ends, hanging forward.
    prof = [(0.0, 0.40), (0.10, 0.42), (0.17, 0.47), (0.215, 0.53), (0.232, 0.60), (0.24, 0.67), (0.236, 0.74),
            (0.222, 0.81), (0.195, 0.88), (0.155, 0.95), (0.105, 1.01), (0.05, 1.065), (0.0, 1.10)]
    prof = [(r + (0.008 * math.sin(i * 2.4) if 0 < i < len(prof) - 1 else 0.0), z) for i, (r, z) in enumerate(prof)]
    body = lathe(prof, verts=28, rot=(TILT, 0, 0), mat=bud, name="bud", smooth=70)
    paint(body, bud_dark, lambda c, n: n.z < -0.35)                       # the shaded underside
    rot_spot = Vector((0.15, 0.15, 0.80))                                  # a rotten patch, back right: sunken, ragged
    dent(body, rot_spot, radius=0.13, depth=0.022)
    paint(body, root, lambda c, n: ((c - rot_spot) * Vector((1.0, 1.0, 0.6))).length
          < 0.075 + 0.02 * math.sin(c.z * 55.0) * math.cos(c.x * 40.0 + c.y * 30.0))
    # ---- Mouth: a wide gash carved out of the front, dark inside; a thick upper lip; teeth hanging from the gum.
    mc = on_bud((0.0, -0.19, 0.655))
    cutter = sphere(0.12, pos=mc, rot=(TILT, 0, 0), scale=(1.45, 0.6, 0.5), segments=16, rings=8, mat=void,
                    name="cutter")
    boolean_cut(body, cutter)
    parts.append(body)
    parts.append(sphere(0.115, pos=on_bud((0.0, -0.176, 0.655)), rot=(TILT, 0, 0), scale=(1.4, 0.55, 0.45),
                        segments=16, rings=8, mat=void, name="maw"))
    parts.append(sphere(0.12, pos=on_bud((0.0, -0.205, 0.718)), rot=(TILT, 0, 0), scale=(1.5, 0.5, 0.3),
                        segments=20, rings=8, mat=bud_dark, name="lip"))
    for x, h in ((-0.125, 0.034), (-0.075, 0.046), (-0.025, 0.038), (0.03, 0.05), (0.08, 0.04), (0.128, 0.032)):
        parts.append(cone(0.016, h, verts=8, pos=on_bud((x, -0.205, 0.705)), rot=(180.0 + TILT, 0, 0), mat=tooth,
                          name="tooth"))
    # ---- Eyes: two ink balls sunk into the front above the mouth, heavy lids over their upper half (tired).
    for sx in (-1, 1):
        c = (sx * 0.085, -0.19, 0.85)
        parts.append(sphere(0.036, pos=on_bud(c), rot=(TILT, 0, 0), segments=14, rings=7, mat=eye, name="eye"))
        parts.append(sphere(0.043, pos=on_bud((c[0], c[1] + 0.004, c[2] + 0.02)), rot=(TILT + 10, 0, 0),
                            scale=(1.1, 1.0, 0.62), segments=14, rings=7, mat=lid, name="lid"))
    # ---- Collar leaves: four dry leaves hanging off the base of the bud, each drooping differently.
    for a, droop, length in ((35, 58, 0.30), (140, 50, 0.26), (215, 64, 0.32), (320, 46, 0.28)):
        d = _dir(a)
        base = Vector((0, 0, 0.48)) + d * 0.16
        tip_dir = d * math.cos(math.radians(droop)) - Vector((0, 0, math.sin(math.radians(droop))))
        parts.append(sphere(length / 2, pos=base + tip_dir * (length / 2), rot=(droop, 0, a), scale=(0.42, 1.0, 0.13),
                            segments=14, rings=7, mat=leaf, name="leaf"))
    # ---- Root legs: five gnarled roots out of the base, a knuckle at the knee, flat root pads on the floor.
    for i, (a, reach) in enumerate(((15, 0.40), (88, 0.44), (160, 0.36), (235, 0.42), (305, 0.45))):
        d = _dir(a)
        p0 = Vector((0, 0, 0.46)) + d * 0.10
        p1 = Vector((0, 0, 0.31 + 0.02 * (i % 2))) + d * (reach * 0.72)
        p2 = Vector((0, 0, 0.11)) + d * (reach * 0.92)
        p3 = Vector((0, 0, 0.035)) + d * reach
        parts.append(pipe([p0, p1, p2, p3], 0.036, verts=12, bend=0.05, mat=root, name="leg"))
        parts.append(sphere(0.046, pos=p1, segments=12, rings=6, mat=root, name="knee"))
        parts.append(cyl(0.058, 0.04, verts=14, pos=(p3.x, p3.y, 0.0), bevel=0.012, segments=2, mat=root, name="pad"))
    # ---- Soil still clinging to the roots, a few root hairs dangling.
    for p, r in (((0.12, 0.08, 0.43), 0.045), ((-0.10, -0.10, 0.40), 0.038), ((0.02, 0.14, 0.385), 0.034)):
        parts.append(sphere(r, pos=p, scale=(1.0, 1.0, 0.75), segments=12, rings=6, mat=lib("soil"), name="clod"))
    for pts in (((0.06, 0.05, 0.44), (0.09, 0.07, 0.33), (0.08, 0.10, 0.22)),
                ((-0.08, 0.02, 0.43), (-0.11, 0.0, 0.34), (-0.10, -0.03, 0.26)),
                ((0.0, 0.13, 0.42), (0.02, 0.17, 0.33), (0.05, 0.18, 0.27))):
        parts.append(pipe([Vector(p) for p in pts], 0.007, verts=8, bend=0.02, mat=root, name="hair"))
    body_node = join(parts, "Body")

    # ---- Jaw (rigged): the chin / lower lip with three teeth standing up; pivot on the mouth hinge.
    pivot = on_bud((0.0, -0.17, 0.625))
    chin = sphere(0.12, pos=on_bud((0.0, -0.205, 0.595)), rot=(TILT, 0, 0), scale=(1.45, 0.55, 0.38), segments=20,
                  rings=8, mat=bud_dark, name="chin")
    lower = [cone(0.015, h, verts=8, pos=on_bud((x, -0.205, 0.606)), rot=(TILT, 0, 0), mat=tooth, name="tooth")
             for x, h in ((-0.1, 0.036), (-0.045, 0.044), (0.01, 0.04), (0.06, 0.046), (0.11, 0.034))]
    jaw = join([chin] + lower, "Jaw", origin=pivot)
    print("  hostile_plant: Jaw pivot (Godot) = (%.3f, %.3f, %.3f)" % godot_char(pivot))

    export([body_node, jaw], "hostile_plant", kind="character", mount="floor")


# ======================================================================================= emergency cabinet
CAB_W, CAB_H, CAB_D = 0.45, 0.60, 0.17        # the steel box (frame + glass bring the depth to ~0.20)
OPEN_W, OPEN_H = 0.33, 0.36                   # the glazed opening, centred on z = 0
YF = -CAB_D                                   # the box front face


def emergency_cabinet():
    reset()
    red = lib("red")
    steel = lib("metal_dark")
    void = lib("void")
    glass = lib("glass")
    caution = lib("caution")
    cream = lib("cream")
    rust = lib("rust")

    cab = []
    # ---- Body: a fat red box on the wall (back on y = 0), kicked low on the left.
    body_pos = Vector((0, -CAB_D / 2, 0))
    body = box((CAB_W, CAB_D, CAB_H), pos=body_pos, bevel=0.018, segments=2, mat=red, name="body", anchor="center")
    subdivide(body, 4)
    dent(body, Vector((-0.15, YF, -0.21)) - body_pos, radius=0.07, depth=0.009, direction=(0, 1, 0))
    cab.append(body)
    # ---- The dark inside, seen through the glass; a bracket on the back wall of it.
    cab.append(box((OPEN_W, 0.006, OPEN_H), pos=(0, YF - 0.004, 0), bevel=0, mat=void, name="inside", anchor="center"))
    cab.append(box((0.03, 0.006, 0.05), pos=(0, YF - 0.009, 0.10), bevel=0.002, mat=steel, name="bracket",
                   anchor="center"))
    # ---- Frame around the opening: four steel bars, a hinge on the left, a latch on the right, 3 of 4 screws.
    bar, depth = 0.035, 0.025
    for z in (OPEN_H / 2 + bar / 2, -(OPEN_H / 2 + bar / 2)):
        cab.append(box((OPEN_W + 2 * bar, depth, bar), pos=(0, YF - depth / 2, z), bevel=0.006, segments=2, mat=steel,
                       name="bar", anchor="center"))
    for x in (OPEN_W / 2 + bar / 2, -(OPEN_W / 2 + bar / 2)):
        cab.append(box((bar, depth, OPEN_H), pos=(x, YF - depth / 2, 0), bevel=0.006, segments=2, mat=steel, name="bar",
                       anchor="center"))
    for z in (0.12, -0.12):
        cab.append(box((0.016, 0.022, 0.05), pos=(-(OPEN_W / 2 + bar + 0.006), YF - 0.011, z), bevel=0.004,
                       segments=1, mat=steel, name="hinge", anchor="center"))
    cab.append(box((0.02, 0.02, 0.04), pos=(OPEN_W / 2 + bar + 0.008, YF - 0.01, 0.0), bevel=0.004, segments=1,
                   mat=steel, name="latch", anchor="center"))
    for x, z in ((-0.185, 0.21), (0.185, 0.21), (-0.185, -0.21)):      # the bottom-right screw is gone
        cab.append(cyl(0.007, 0.004, verts=8, pos=(x, YF - depth, z), rot=(90, 0, 0), bevel=0, mat=steel, name="screw"))
    # ---- Glass pane over the opening (its own node, so the scene can hide it when the glass is broken).
    pane = box((OPEN_W + 0.012, 0.004, OPEN_H + 0.012), pos=(0, YF - 0.013, 0), bevel=0, mat=glass, name="pane",
               anchor="center")
    glass_node = join([pane], "Glass")
    # ---- "FIRE" on a caution plate above the glass (red letters), "DEPOSIT" stencilled below it, crooked.
    pz = 0.255
    cab.append(extrude_profile(rounded_rect(0.30, 0.06, 0.012), 0.008, pos=(0, YF + 0.002, pz), bevel=0.003,
                               mat=caution, name="plate"))
    cab += stencil("FIRE", 0.04, pos=(0, YF - 0.0065, pz - 0.02), depth=0.004, mat=red, name="letter")
    letters = stencil("DEPOSIT", 0.03, pos=(0, YF + 0.0005, -0.272), depth=0.004, mat=cream, name="letter")
    cab += roll(letters, (0, YF, -0.257), -2.5, axis='Y')
    # ---- The hook on the right side where the hammer hung; only the chain is left.
    cab.append(pipe([(0.215, -0.09, -0.03), (0.252, -0.09, -0.03), (0.252, -0.09, -0.065)], 0.005, verts=8, bend=0.012,
                    mat=steel, name="hook"))
    cab.append(pipe([(0.252, -0.09, -0.06), (0.258, -0.10, -0.14), (0.25, -0.094, -0.22), (0.255, -0.10, -0.29)], 0.004,
                    verts=8, bend=0.02, mat=steel, name="chain"))
    cab.append(torus(0.012, 0.0035, pos=(0.255, -0.10, -0.305), rot=(0, 90, 0), major_segments=12, minor_segments=6,
                     mat=steel, name="ring"))
    # ---- Rust: drips from the frame's bottom corners down the front, and down the wall under the box.
    for sx in (-1, 1):
        pts = [(0.19, -0.212), (0.19, -0.24), (0.175, -0.276), (0.16, -0.25), (0.14, -0.264), (0.125, -0.232),
               (0.11, -0.212)]
        cab.append(extrude_profile([(sx * u, v) for u, v in (pts if sx > 0 else pts[::-1])], 0.002,
                                   pos=(0, YF + 0.0005, 0), bevel=0, mat=rust, name="rust_drip"))
        wall = [(0.12, -0.30), (0.20, -0.30), (0.19, -0.32), (0.17, -0.35), (0.155, -0.325), (0.14, -0.337),
                (0.125, -0.315)]
        cab.append(extrude_profile([(sx * u, v) for u, v in (wall if sx > 0 else wall[::-1])], 0.003,
                                   pos=(0, 0.0, 0), bevel=0, mat=rust, name="rust_wall"))
    box_node = join(cab, "Box")
    stock = empty("Stock", pos=(0, -0.10, 0))

    export([box_node, glass_node, stock], "emergency_cabinet", kind="prop", mount="wall")


# ============================================================================================ flamethrower
GAUGE_H = 0.08          # the fuel sight glass (Fill is GAUGE_H tall at scale 1)
TANK_Y = 0.05           # front cap of the tank (the tank runs towards +Y, behind the grip)


def flamethrower():
    reset()
    metal = lib("metal")
    steel = lib("metal_dark")
    red = lib("red")
    rubber = lib("dark")
    void = lib("void")
    cream = lib("cream")
    fuel = lib("orange")

    gun = []
    # ---- Grip at the origin: a rubber pistol grip raked back 12 deg, steel butt plate, a neck up to the receiver.
    gun.append(cyl(0.021, 0.125, verts=14, pos=(0, 0.012, -0.075), rot=(12, 0, 0), bevel=0.008, segments=2, mat=rubber,
                   name="grip"))
    gun.append(cyl(0.024, 0.006, verts=14, pos=(0, 0.012, -0.075), rot=(12, 0, 0), bevel=0.002, segments=1, mat=steel,
                   name="butt"))
    gun.append(box((0.034, 0.05, 0.05), pos=(0, -0.01, 0.03), bevel=0.008, segments=2, mat=steel, name="neck",
                   anchor="center"))
    # ---- Trigger and guard.
    gun.append(box((0.012, 0.016, 0.045), pos=(0, -0.05, 0.035), rot=(-10, 0, 0), bevel=0.004, segments=1, mat=steel,
                   name="trigger", anchor="center"))
    gun.append(pipe([(0, -0.03, 0.055), (0, -0.085, 0.045), (0, -0.085, -0.005), (0, -0.04, -0.02)], 0.0045, verts=8,
                    bend=0.015, mat=steel, name="guard"))
    # ---- Receiver tube (the barrel) with a back cap, the flared nozzle sooted black at the mouth.
    gun.append(cyl(0.03, 0.38, verts=16, pos=(0, 0.12, 0.085), rot=(90, 0, 0), bevel=0.008, segments=2, mat=metal,
                   name="receiver"))
    gun.append(cyl(0.034, 0.03, verts=16, pos=(0, 0.125, 0.085), rot=(90, 0, 0), bevel=0.006, segments=2, mat=steel,
                   name="cap"))
    nozzle = cyl(0.02, 0.07, verts=16, pos=(0, -0.26, 0.085), rot=(90, 0, 0), radius_top=0.036, bevel=0.004, segments=2,
                 mat=metal, name="nozzle")
    paint(nozzle, void, lambda c, n: c.z > 0.052)                          # the last 2 cm and the mouth: soot
    gun.append(nozzle)
    # ---- Tank: a red cylinder slung under the receiver behind the grip, a valve neck at the back, a rubber strap,
    #      paint chipped to bare metal on the upper right.
    prof = [(0.0, 0.0), (0.04, 0.004), (0.058, 0.014), (0.066, 0.03), (0.066, 0.18), (0.06, 0.20), (0.045, 0.212),
            (0.02, 0.215), (0.02, 0.23), (0.03, 0.234), (0.03, 0.252), (0.012, 0.256), (0.0, 0.256)]
    tank = lathe(prof, verts=24, pos=(0, TANK_Y, 0.0), rot=(-90, 0, 0), mat=red, name="tank", smooth=46)
    chip = Vector((0.062, -0.02, 0.075))                                   # local: +x right, -y up, z along the tank
    paint(tank, metal, lambda c, n: (c - chip).length < 0.034)
    gun.append(tank)
    gun.append(torus(0.07, 0.007, pos=(0, TANK_Y + 0.12, 0.0), rot=(90, 0, 0), major_segments=24, minor_segments=6,
                     mat=rubber, name="strap"))
    # ---- Hose from the valve up and over into the receiver's back cap, sagging a little.
    gun.append(pipe([(0, TANK_Y + 0.24, 0.03), (0, TANK_Y + 0.275, 0.12), (0, TANK_Y + 0.21, 0.17),
                     (0, TANK_Y + 0.12, 0.135), (0, 0.13, 0.095)], 0.011, verts=10, bend=0.04, mat=rubber, name="hose"))
    # ---- On the tank's back cap (the holder's side): a pressure dial on the right, the fuel sight glass on the left.
    cap_y = TANK_Y + 0.20
    gun.append(cyl(0.022, 0.014, verts=14, pos=(0.035, cap_y - 0.004, 0.03), rot=(-90, 0, 0), bevel=0.003, segments=1,
                   mat=steel, name="dial"))
    gun.append(cyl(0.017, 0.002, verts=14, pos=(0.035, cap_y + 0.01, 0.03), rot=(-90, 0, 0), bevel=0, mat=cream,
                   name="dial_face"))
    gun.append(box((0.022, 0.014, 0.10), pos=(-0.035, cap_y + 0.002, 0.0), bevel=0.004, segments=1, mat=steel,
                   name="glass_frame", anchor="center"))
    gun.append(box((0.012, 0.004, 0.088), pos=(-0.035, cap_y + 0.0105, 0.0), bevel=0, mat=rubber, name="glass_channel",
                   anchor="center"))
    # ---- A cream label on the tank's right side, one corner peeling (two overlapping stickers).
    gun.append(box((0.003, 0.06, 0.045), pos=(0.066, TANK_Y + 0.075, 0.0), bevel=0, mat=cream, name="label",
                   anchor="center"))
    gun.append(box((0.003, 0.028, 0.024), pos=(0.069, TANK_Y + 0.055, 0.016), rot=(0, 14, 8), bevel=0, mat=cream,
                   name="label_peel", anchor="center"))
    gun_node = join(gun, "Gun")

    # ---- Fuel gauge (rigged like the watering can): Gauge at the glass bottom, Fill centred on its own node.
    fill_y = cap_y + 0.0135
    gauge = empty("Gauge", pos=(-0.035, fill_y, -GAUGE_H / 2))
    fill = box((0.009, 0.004, GAUGE_H), pos=(-0.035, fill_y, 0.0), bevel=0, mat=fuel, name="Fill", anchor="center")
    fill = join([fill], "Fill", origin=(-0.035, fill_y, 0.0))
    set_parent(fill, gauge)
    print("  flamethrower: Gauge (Godot) = (%.3f, %.3f, %.3f), Fill +%.3f up, GAUGE_H %.2f" % (
        godot_char(Vector((-0.035, fill_y, -GAUGE_H / 2))) + (GAUGE_H / 2, GAUGE_H)))

    export([gun_node, gauge], "flamethrower", kind="item", mount="free", budget=2500)


def build():
    hostile_plant()
    emergency_cabinet()
    flamethrower()
