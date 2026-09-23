"""security_camera: the Boss's wall-mounted CCTV camera, always watching (room decor, rigged).

Wall mount (back on the wall plane, origin = the mount point on the wall), ~0.23 x 0.48 x 0.62 m.
Replaces the primitives of scenes/world/props/security_camera.tscn; the model is instanced AS `Visual`
so security_camera.gd keeps its paths (it pans `Visual/Pan` about Y and blinks `Visual/Pan/Tilt/Led`):
  Visual (Toonify) / Bracket          wall plate + arm + a sagging cable (static)
                   / Pan              swivel knuckle + yoke, pivot on the knuckle axis (pans about Godot Y)
                     / Tilt           housing + sun hood + lens, pivot on the yoke bolts (nose down ~22 deg,
                                      baked into the mesh: rest rotation stays identity)
                       / Led          flat red recording light (the script toggles its visibility)
Sad/grim: a grubby housing with a grime streak, a crooked roll (3 deg), a cable taped up in a sag, one
of the plate screws missing. The lens has a glint so it reads as an eye.
"""
from gwf import *

P = Vector((0.0, -0.3, -0.05))    # pan pivot (knuckle axis), Blender coords
T = Vector((0.0, -0.3, -0.215))   # tilt pivot (yoke bolts)
TILT = 22.0                        # nose down
ROLL = 3.0                         # a little crooked
BODY = (0.18, 0.38, 0.14)          # housing w x l x h (untilted: length along -Y)
BODY_C = Vector((0.0, -0.1, 0.0))  # housing centre relative to T (untilted)


def rounded_rect(w, h, r, n=4):
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180),
                       (w / 2 - r, -h / 2 + r, 270)):
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def build():
    steel = lib("metal_dark")
    housing = lib("white")                                    # grubby white
    grime = lib("concrete_dark")
    glass = lib("dark")
    glint = lib("eye_white")                                  # flat
    led_mat = material("led_red", pal("TOMATO"), "flat")      # the one bright signal: it is recording

    # ---- Bracket (static): wall plate, arm, screws, sagging cable.
    plate = extrude_profile(rounded_rect(0.15, 0.22, 0.035, n=3), 0.024, pos=(0, 0, 0.0), bevel=0.008, segments=1,
                            mat=steel, name="plate")
    screws = [cyl(0.016, 0.012, verts=12, pos=(0, -0.022, z), rot=(90, 0, 0), bevel=0.004, segments=1,
                  mat=housing, name="screw") for z in (0.075,)]           # the bottom screw is long gone
    hole = cyl(0.01, 0.004, verts=10, pos=(0, -0.0225, -0.075), rot=(90, 0, 0), bevel=0, mat=glass, name="hole")
    arm = pipe([(0, -0.02, 0.02), (0, -0.2, 0.02), (0, -0.3, -0.005)], 0.022, verts=16, bend=0.06, mat=steel,
               name="arm")
    collar = cyl(0.034, 0.03, verts=16, pos=(0, -0.018, 0.02), rot=(90, 0, 0), bevel=0.008, segments=1, mat=steel,
                 name="collar")
    # The cable leaves the plate, hangs in a loop close to the wall and is taped up to the arm.
    cable = pipe([(0.045, -0.02, -0.07), (0.07, -0.04, -0.2), (0.075, -0.08, -0.25), (0.06, -0.12, -0.18),
                  (0.02, -0.145, -0.005)], 0.011, verts=8, bend=0.05, mat=glass, name="cable")
    tape = cyl(0.029, 0.032, verts=14, pos=(0, -0.124, 0.02), rot=(90, 0, 0), bevel=0.005, segments=1,
               mat=grime, name="tape")
    bracket = join([plate, arm, collar, cable, tape, hole] + screws, "Bracket")

    # ---- Pan: knuckle under the arm end + a U yoke down to the tilt bolts.
    knuckle = cyl(0.04, 0.065, verts=16, pos=(P.x, P.y, P.z - 0.035), bevel=0.012, segments=2, mat=steel,
                  name="knuckle")
    bar = box((0.24, 0.05, 0.022), pos=(P.x, P.y, P.z - 0.055), bevel=0.008, mat=steel, name="yoke_bar")
    yoke = [bar, knuckle]
    for sx in (-1, 1):
        x = sx * (BODY[0] / 2 + 0.022)
        yoke.append(box((0.014, 0.05, P.z - 0.04 - T.z + 0.03), pos=(x, P.y, T.z - 0.03), bevel=0.006, segments=1,
                        mat=steel, name="yoke_plate"))
        yoke.append(cyl(0.024, 0.016, verts=14, pos=(x + sx * 0.006, T.y, T.z), rot=(0, 90 * sx, 0), bevel=0.005,
                        segments=1, mat=steel, name="bolt"))
    pan = join(yoke, "Pan", origin=P)

    # ---- Tilt: housing, hood, lens (built untilted around T, then the mesh is turned nose-down).
    bw, bl, bh = BODY
    c = T + BODY_C
    body = box((bw, bl, bh), pos=(c.x, c.y, c.z - bh / 2), bevel=0.03, segments=3, mat=housing, name="body")
    # A grime streak down the right side of the housing, from the hood's drip edge.
    streak = box((0.004, 0.16, 0.07), pos=(c.x + bw / 2 + 0.001, c.y - 0.05, c.z - 0.035), bevel=0, mat=grime,
                 name="streak")
    # Sun hood: overhangs the front, stops short of the yoke bar at the back (it must clear it when tilted).
    hood = box((bw + 0.04, 0.39, 0.02), pos=(c.x, c.y - 0.065, c.z + bh / 2 + 0.004), bevel=0.008, mat=steel,
               name="hood")
    front = c.y - bl / 2
    lx, lz = c.x - 0.022, c.z - 0.008
    ring = cyl(0.05, 0.035, verts=20, pos=(lx, front + 0.012, lz), rot=(90, 0, 0), bevel=0.01, segments=2,
               mat=steel, name="lens_ring")
    lens = sphere(0.04, pos=(lx, front - 0.022, lz), scale=(1, 0.45, 1), segments=16, rings=8, mat=glass,
                  name="lens")
    shine = sphere(0.011, pos=(lx - 0.016, front - 0.036, lz + 0.016), scale=(1, 0.5, 1), segments=10, rings=6,
                   mat=glint, name="glint")
    bezel = cyl(0.02, 0.008, verts=14, pos=(c.x + 0.056, front + 0.004, c.z + 0.026), rot=(90, 0, 0),
                bevel=0.003, segments=1, mat=glass, name="bezel")
    tilt = join([body, streak, hood, ring, lens, shine, bezel], "Tilt", origin=T)
    turn = Matrix.Rotation(math.radians(TILT), 4, 'X') @ Matrix.Rotation(math.radians(ROLL), 4, 'Y')
    tilt.data.transform(turn)
    tilt.data.update()

    # ---- Led: the recording light in the bezel (its own node, so the script can blink it).
    led_local = Vector((c.x + 0.056, front - 0.005, c.z + 0.026)) - T
    led_c = T + (turn @ led_local)
    led = sphere(0.016, pos=(0, 0, 0), scale=(1, 0.75, 1), segments=12, rings=6, mat=led_mat, name="Led")
    led.data.transform(turn)
    led.location = led_c
    apply_transform(led)
    set_origin(led, led_c)

    set_parent(tilt, pan)
    set_parent(led, tilt)
    export([bracket, pan], "security_camera", kind="prop", mount="wall")
