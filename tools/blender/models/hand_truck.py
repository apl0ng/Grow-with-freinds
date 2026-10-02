"""hand_truck: the dock's hand truck (M17 cart agent). One model, one mesh, no rig.

A two-wheeled sack truck that has moved too many sacks: a steel frame in faded red paint, bent out of true (the
left upright bowed where it met a door frame, the middle cross bar kinked back, the handle bar sagging left of
centre), a toe plate dished in the middle with its nose scuffed down to rust and one corner bent down, two solid
rubber wheels (one sagged flat where it stood), a handle bar wound in grubby tape with the loose end hanging.

kind "item": the plate side (Blender -Y) lands on Godot -Z, away from whoever pushes it; the wheels and the handle
are on the pusher's side (Godot +Z). Floor mount: standing upright, the plate and both wheels are on the floor and
the origin is on the floor under the heel of the plate. Godot space: x = -Blender x, y = Blender z, z = Blender y.
Instanced as `Visual/Model` in scenes/items/hand_truck.tscn; scripts/items/hand_truck.gd stacks the loaded bundles
on the plate (`Visual/Load`), leaning on the frame, and tips the truck about its axle while it is pushed, so these
numbers are mirrored there (Godot y, z):
  PLATE_TOP 0.018                        the plate's top face
  PLATE_FRONT / PLATE_BACK -0.38 / -0.03 the plate's nose and heel
  AXLE 0.13, 0.17                        the truck tips back about it when somebody pushes it
  LEAN 0.1 over 1.05 m                   the uprights lean back (towards the pusher), about 5.5 degrees
  GRIP 1.245, 0.18                       the middle of the taped handle bar
Every part is placed and then has its transform baked (apply_transform) before it is painted or bent, so the
lambdas below see model coordinates.
"""
from gwf import *

PLATE_W = 0.46       # toe plate width (x)
PLATE_FRONT = -0.38  # nose (y)
PLATE_BACK = -0.03   # heel (y)
PLATE_T = 0.018
UPRIGHT_X = 0.2      # half the distance between the uprights
UPRIGHT_R = 0.022
LEAN = 0.1           # how far back (+y) the uprights are at TOP_Z
TOP_Z = 1.05         # where the uprights bend in towards the handle
BAR_Y = 0.18         # the handle bar
BAR_Z = 1.25
BAR_HALF = 0.115
AXLE_Y = 0.17
AXLE_Z = 0.13
WHEEL_R = 0.13
WHEEL_W = 0.075
WHEEL_X = 0.26
PAINT = "#8f4a3f"    # the oil drums' faded red (MODELING.md, factory palette)


def upright_y(z):
    """The uprights' y at height z (they lean back towards the pusher)."""
    return LEAN * max(0.0, min(1.0, z / TOP_Z))


def baked(obj):
    """Bake the object's placement into its mesh: from here on its vertex and face coordinates are model space."""
    apply_transform(obj)
    return obj


def smooth01(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


def handle_sag(co):
    """The handle bar sags a little left of centre where it took the weight of a fall (frame and grip alike)."""
    if co.z < BAR_Z - 0.08:
        return co
    k = smooth01(1.0 - abs(co.x + 0.03) / 0.1)
    return Vector((co.x, co.y, co.z - 0.016 * k))


def bow_upright(co):
    """The left upright bows outwards and back in the middle (somebody drove it into a door frame)."""
    if co.x > -0.1 or co.z > TOP_Z:
        return co
    t = max(0.0, min(1.0, co.z / TOP_Z))
    s = math.sin(math.pi * t)
    return Vector((co.x - 0.028 * s * s, co.y + 0.012 * s, co.z))


def dish_plate(co):
    """Loads dropped on the plate dished its middle; the right front corner is bent down. Only the top face moves:
    the bottom stays on the floor."""
    if co.z < PLATE_T * 0.5:
        return co
    d_mid = (Vector((co.x, co.y)) - Vector((-0.02, -0.2))).length
    d_corner = (Vector((co.x, co.y)) - Vector((0.23, PLATE_FRONT))).length
    z = co.z - 0.006 * max(0.0, 1.0 - d_mid / 0.2) - 0.011 * max(0.0, 1.0 - d_corner / 0.14) ** 2
    return Vector((co.x, co.y, max(z, 0.004)))


def build():
    reset()
    paint_red = material("truck_paint", PAINT, "soft")
    rust = lib("rust")
    steel = lib("metal_dark")
    bright = lib("metal")
    rubber = lib("dark")
    tape = lib("cream")
    sx = UPRIGHT_X

    # --- the frame: one bent pipe from the left foot, up, across the handle and down the right side -------------------
    path = [(-sx, 0.0, 0.03), (-sx, upright_y(TOP_Z), TOP_Z), (-BAR_HALF, BAR_Y, BAR_Z), (BAR_HALF, BAR_Y, BAR_Z),
            (sx, upright_y(TOP_Z), TOP_Z), (sx, 0.0, 0.03)]
    frame = baked(pipe(path, UPRIGHT_R, verts=8, bend=0.07, mat=paint_red, name="frame"))
    move_verts(frame, bow_upright)
    move_verts(frame, handle_sag)
    # Cross bars between the uprights; the middle one is kinked backwards.
    bars = []
    for z, kink in ((0.32, 0.0), (0.64, 0.026), (0.94, 0.0)):
        y = upright_y(z)
        bar = baked(pipe([(-sx + 0.01, y, z), (sx - 0.01, y, z)], 0.016, verts=8, bend=0.0, mat=paint_red, name="bar"))
        if kink:
            move_verts(bar, lambda co, k=kink: Vector((co.x, co.y + k * smooth01(1.0 - abs(co.x + 0.04) / 0.15), co.z)))
        move_verts(bar, bow_upright)
        bars.append(bar)
    # Wheel struts: from the uprights at the lower bar back and down to the axle ends.
    struts = []
    for s in (-1.0, 1.0):
        strut = baked(pipe([(s * sx, upright_y(0.34), 0.34), (s * (WHEEL_X - WHEEL_W / 2 - 0.016), AXLE_Y, AXLE_Z)],
                           0.016, verts=8, bend=0.0, mat=paint_red, name="strut"))
        struts.append(strut)
    # Where the paint is gone: the feet, the welds at the lower bar, the right-hand handle corner, a scrape down the
    # outside of the bowed upright.
    for part in [frame] + bars + struts:
        paint(part, rust, lambda c, n: c.z < 0.13 or (0.27 < c.z < 0.37 and abs(c.x) > 0.13)
              or (c.z > BAR_Z - 0.12 and c.x > 0.09))
        paint(part, steel, lambda c, n: 0.6 < c.z < 0.82 and c.x < -0.19 and n.x < -0.3)

    # --- the toe plate: a slab on the floor, dished, its nose scuffed to rust ----------------------------------------
    depth = PLATE_BACK - PLATE_FRONT
    plate = baked(subdivide(box((PLATE_W, depth, PLATE_T), pos=(0.0, (PLATE_FRONT + PLATE_BACK) / 2, 0.0), bevel=0.005,
                                mat=steel, name="plate"), 3))
    move_verts(plate, dish_plate)
    paint(plate, rust, lambda c, n: c.y < PLATE_FRONT + 0.06 or (n.z > 0.5 and c.y < -0.22 and (c.x > 0.12 or c.x < -0.17)))
    # The heel: an angle welded across the uprights' feet, holding the plate.
    heel = baked(box((PLATE_W - 0.02, 0.035, 0.05), pos=(0.0, PLATE_BACK + 0.005, 0.0), bevel=0.006, mat=steel,
                     name="heel"))
    paint(heel, rust, lambda c, n: c.z < 0.02 or c.x < -0.16)
    # Gussets from the heel up the inside of each upright.
    gussets = [baked(box((0.012, 0.05, 0.12), pos=(s * (sx - 0.022), -0.004, 0.0), bevel=0.003, mat=steel,
                         name="gusset")) for s in (-1.0, 1.0)]

    # --- the axle and two solid wheels; the right one has sagged flat where it stood -------------------------------
    axle = baked(cyl(0.012, 2 * WHEEL_X + WHEEL_W + 0.02, verts=10, pos=(0.0, AXLE_Y, AXLE_Z), rot=(0, 90, 0), bevel=0.0,
                     mat=bright, name="axle", anchor="center"))
    wheels = []
    for s in (-1.0, 1.0):
        tyre = baked(cyl(WHEEL_R, WHEEL_W, verts=24, pos=(s * WHEEL_X, AXLE_Y, AXLE_Z), rot=(0, 90, 0), bevel=0.02,
                         mat=rubber, name="tyre", anchor="center"))
        hub = baked(cyl(0.055, WHEEL_W + 0.012, verts=14, pos=(s * WHEEL_X, AXLE_Y, AXLE_Z), rot=(0, 90, 0),
                        bevel=0.006, mat=bright, name="hub", anchor="center"))
        paint(hub, rust, lambda c, n: c.z < AXLE_Z - 0.015)
        wheels += [tyre, hub]

    def flat_spot(co):
        # The bottom of the right tyre (Blender +x) pushed up and out; its lowest point stays on the floor.
        if co.z > AXLE_Z - 0.06:
            return co
        k = max(0.0, 1.0 - abs(co.y - AXLE_Y) / 0.1) ** 2
        side = 1.0 if co.x > WHEEL_X else -1.0
        return Vector((co.x + 0.006 * k * side, co.y, max(co.z + 0.014 * k, 0.0)))
    move_verts(wheels[2], flat_spot)

    # --- the grip: tape wound round the handle bar, a loose end hanging off the back ----------------------------------
    grip = baked(cyl(0.026, 0.2, verts=12, pos=(0.0, BAR_Y, BAR_Z), rot=(0, 90, 0), bevel=0.005, mat=tape, name="grip",
                     anchor="center"))
    jitter(grip, 0.0015, seed=3)
    move_verts(grip, handle_sag)
    paint(grip, steel, lambda c, n: n.z < -0.6 and abs(c.x) < 0.06)   # grubby where the hands go
    tail = baked(box((0.026, 0.004, 0.075), pos=(0.06, BAR_Y + 0.024, BAR_Z - 0.095), rot=(14, 0, 9), bevel=0.0,
                     mat=tape, name="tape_end"))

    truck = join([frame, plate, heel, axle, grip, tail] + bars + struts + gussets + wheels, "HandTruck")
    low = min(v.co.z for v in truck.data.vertices)
    if abs(low) > 0.0005:
        move_verts(truck, lambda co: Vector((co.x, co.y, co.z - low)))
    export(truck, "hand_truck", kind="item", mount="floor", budget=3000)
