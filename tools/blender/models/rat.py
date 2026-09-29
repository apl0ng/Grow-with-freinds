"""rat: the thin, sad rat that eats a growing plant until a worker comes near (M10 events, stretch; kind
"character": front -> Godot -Z). Goes into scenes/world/props/rat.tscn (events agent) instanced AS `Visual`,
so the script can swish `Visual/Tail`.

Floor mount, origin under the body between the feet. 0.13 x 0.07 x 0.35 m (W x H x D, Godot; nose to
tail tip along Z, the nose at -Z), budget 2000.
  <Visual, Toonify> / Body    body, head, ears, eyes + lids, whiskers, legs, feet, nose (static)
                    / Tail    long thin tail: pivot at the rump (node origin, Godot (0, 0.046, 0.06)), rest
                              rotation identity; it drags on the floor. `Tail.rotation.y` swishes it.
Sad: ribs showing (a waist), the head hangs low, heavy lids over tiny ink eyes, ears folded out, whiskers
drooping, a patchy bald spot on the rump and another on the flank, the tail dragging, a low splayed
slink. Body, head and legs are boolean-unioned into ONE connected part 12 cm wide, so Toonify gives the
rat its thin ink outline (parts under 10 cm get none; a dark rat on a dark floor needs it).
"""
import sys
import os

import bpy
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402


def union(base, others):
    """Boolean-union `others` into `base` (applied now, operands removed): one connected part."""
    for o in others:
        mod = base.modifiers.new("gwf_union", 'BOOLEAN')
        mod.operation = 'UNION'
        mod.solver = 'EXACT'
        mod.object = o
    apply_modifiers(base)
    for o in others:
        bpy.data.objects.remove(o, do_unlink=True)
    return base

RUMP_Y, RUMP_Z = 0.07, 0.046           # rump end of the body (the tail root is just inside it)
BODY_L = 0.15                           # rump -> neck
HEAD_L = 0.075
NOSE_DOWN = 24.0                        # the head hangs (deg)


def fwd(pitch_deg):
    """Unit vector pointing forward (-Y) and down by pitch."""
    a = math.radians(pitch_deg)
    return Vector((0.0, -math.cos(a), -math.sin(a)))


def build():
    fur = material("rat_fur", "#6e6259", "matte")
    belly = material("rat_belly", "#8b8377", "matte")
    skin = material("rat_skin", "#8c7570", "matte")   # ears, tail, feet, nose, bald skin
    eye = lib("eye_black")
    lid = lib("eyelid")
    whisker = lib("cream")

    # ---- Body: a lathe along -Y (rump at +Y), thin through the middle, squashed a little, nose-end lower.
    prof = [(0, 0), (0.017, 0.006), (0.03, 0.024), (0.036, 0.05), (0.031, 0.075), (0.028, 0.095), (0.033, 0.115),
            (0.03, 0.135), (0.02, 0.146), (0, 0.15)]
    body = lathe(prof, verts=16, pos=(0, RUMP_Y, RUMP_Z), rot=(94, 0, 0), mat=fur, name="body", smooth=180)
    body.scale = (1.0, 0.82, 1.0)                                  # local y = up after the turn
    paint(body, belly, lambda c, n: n.y < -0.45)                    # lighter belly (local -y = down)
    for p, r in (((0.012, 0.031, 0.035), 0.021), ((-0.024, 0.02, 0.1), 0.014)):   # bald patches
        paint(body, skin, lambda c, n, p=Vector(p), r=r: (c - p).length < r)
    parts = [body]
    # ---- Head: a small tapered lathe hanging off the neck, nose down.
    neck = Vector((0, RUMP_Y - BODY_L, RUMP_Z - 0.004))
    d = fwd(NOSE_DOWN)
    hprof = [(0, -0.014), (0.019, 0.006), (0.027, 0.022), (0.026, 0.042), (0.018, 0.06), (0.009, 0.071), (0, HEAD_L)]
    head = lathe(hprof, verts=14, pos=neck, rot=(90 + NOSE_DOWN, 0, 0), mat=fur, name="head", smooth=180)
    head.scale = (1.0, 0.9, 1.0)                                    # starts 14 mm inside the body (union)
    up = Vector((0, -math.sin(math.radians(NOSE_DOWN)), math.cos(math.radians(NOSE_DOWN))))  # the head's up
    nose = neck + d * HEAD_L
    parts.append(sphere(0.0075, pos=nose - d * 0.002, segments=10, rings=5, mat=skin, name="nose"))
    # Ears: thin round discs folded outwards, on top of the head behind the eyes.
    for sx in (-1, 1):
        c = neck + d * 0.018 + up * 0.024 + Vector((sx * 0.02, 0, 0))
        parts.append(sphere(0.018, pos=c, rot=(NOSE_DOWN * 0.5, sx * 32, 0), scale=(1, 0.32, 1), segments=12, rings=6,
                            mat=skin, name="ear"))
    # Eyes: tiny ink dots on the head's sides, heavy lids over their upper half.
    for sx in (-1, 1):
        e = neck + d * 0.04 + up * 0.012 + Vector((sx * 0.021, 0, 0))
        parts.append(sphere(0.0055, pos=e, segments=8, rings=4, mat=eye, name="eye"))
        parts.append(sphere(0.0072, pos=e + up * 0.0045 - Vector((sx * 0.0015, 0, 0)), rot=(NOSE_DOWN, 0, 0),
                            scale=(1.1, 1.0, 0.55), segments=8, rings=4, mat=lid, name="lid"))
    # Whiskers: three thin drooping sticks per side at the snout.
    for sx in (-1, 1):
        for k, (yaw, droop) in enumerate(((-8, -22), (2, -14), (12, -6))):
            root = neck + d * 0.06 + up * 0.002 + Vector((sx * 0.008, 0, 0))
            parts.append(box((0.055, 0.0022, 0.0022), pos=root + Vector((sx * 0.026, 0, 0)), rot=(0, sx * droop, yaw),
                             bevel=0, mat=whisker, name="whisker", anchor="center"))
    # Legs: four stubby capsules splayed out low (a slink), paws as flat pink blobs.
    legs = []
    for x, y in ((-0.05, -0.05), (0.05, -0.05), (-0.05, 0.036), (0.05, 0.036)):
        sx = 1 if x > 0 else -1
        legs.append(capsule(0.0095, 0.058, pos=(x, y, 0.003), rot=(0, -sx * 22, 0), verts=8, rings=4, mat=fur,
                            name="leg"))
        parts.append(sphere(0.011, pos=(x + sx * 0.003, y - 0.006, 0.0075), scale=(1.0, 1.5, 0.55), segments=8, rings=4,
                            mat=skin, name="paw"))
    union(body, legs + [head])
    body_node = join(parts, "Body")

    # ---- Tail (rigged): a tapering lathe along +Y from the rump, bent down to drag on the floor, wiggling.
    L = 0.135
    tprof = [(0.009, 0), (0.0085, 0.02), (0.0065, 0.05), (0.0048, 0.08), (0.0032, 0.11), (0.0016, 0.128), (0, L)]
    tail = lathe(tprof, verts=8, pos=(0, RUMP_Y - 0.01, RUMP_Z), rot=(-90, 0, 0), mat=skin, name="tail", smooth=180)

    def bend(co):  # local z = along the tail; local +y = down (world -z) after the turn
        t = co.z / L
        return Vector((co.x + 0.02 * math.sin(math.pi * t) * t, co.y + 0.0455 * t ** 1.5, co.z))
    move_verts(tail, bend)
    tail = join([tail], "Tail", origin=(0, RUMP_Y - 0.01, RUMP_Z))

    export([body_node, tail], "rat", kind="character", mount="floor", budget=2000)
