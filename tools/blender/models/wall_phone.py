"""wall_phone: the old wall set in the main room that rings for EVENT_PHONE (M17 mayhem3; CONTRACTS "M17",
"Mayhem 3"). scenes/world/props/wall_phone.tscn instances it AS `Visual`; wall_phone.gd rattles `Handset`
while it rings.

Wall mount: back on the wall plane, origin = the bottom centre of the housing ON the wall. Hang the scene node
~1.15 m up the wall (the earpiece then sits at ~1.55 m, the note above it at ~1.65 m).
About 0.37 x 0.60 x 0.15 m (W x H x D, Godot; the note above and the slack of the cord below included).
  <Visual, Toonify> / Body      the yellowed housing with its hooded top, the cradle hook, the keypad plate and
                                buttons, the speaker slots, the crack, the taped note above it, the grease on
                                the wall where hands go, the coiled cord (static)
                    / Handset   on the hook, left of the housing: pivot = the hook (node origin, Godot
                                (-0.105, 0.40, 0.06)); rest = hanging straight down. `Handset.rotation.z` a few
                                degrees either way rattles it in the cradle.
Sad: the housing is cracked from the top corner down to the keypad, the handset is held together with tape,
the cord has lost its coil in the middle, the note above it hangs by one piece of tape and curls, the paint
is grey where hands have been.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

W, D, H = 0.22, 0.085, 0.42             # the housing
BX = 0.03                               # the housing's centre is right of the origin: the handset hangs left of it
YF = -D                                 # the housing's front face
HX, HY = -0.105, -0.06                  # where the handset hangs (its axis), left of the housing
HOOK_Z = 0.40                           # the hook: the handset's pivot
HS_R, HS_LEN = 0.027, 0.26              # the handset's grip radius and length (hook to the mouthpiece)
P = Vector((HX, HY, HOOK_Z))            # the Handset pivot


def build():
    plastic = material("phone_plastic", "#bdb08f", "soft")      # institutional beige, yellowed
    dark = lib("dark")                                            # the handset, the keypad plate
    steel = lib("metal_dark")                                     # the hook, the screws
    void = lib("void")                                            # the slots, the crack
    paper = lib("cream")                                          # the note, the buttons
    tape = material("phone_tape", "#8f8a7c", "matte")            # old tape, gone grey
    grease = material("phone_grease", "#6a6454", "matte")        # where hands go

    body = []
    # ---- Housing: a fat rounded box on the wall, a hood on top that overhangs, the top edge dipping one way.
    housing = box((W, D, H), pos=(BX, -D / 2, 0), bevel=0.018, segments=2, mat=plastic, name="housing")
    subdivide(housing, 4)
    dent(housing, local(housing, (BX + 0.07, YF, 0.12)), radius=0.07, depth=0.008, direction=(0, 1, 0))
    body.append(housing)
    body.append(box((W + 0.04, D + 0.025, 0.035), pos=(BX, -(D + 0.025) / 2, H - 0.012), bevel=0.01, segments=2,
                    mat=plastic, name="hood"))
    # The speaker: three dark slots low on the face, a dark grille recess behind them.
    for z in (0.06, 0.08, 0.10):
        body.append(box((0.1, 0.004, 0.009), pos=(BX, YF - 0.001, z), bevel=0, mat=void, name="slot"))
    # ---- Keypad: a dark plate on the right of the face, twelve pale buttons in a 3 x 4 grid, the bottom row worn.
    kx, kz = BX + 0.035, 0.26
    body.append(extrude_profile(rounded_rect(0.095, 0.125, 0.01, cx=kx, cy=kz), 0.006, pos=(0, YF + 0.002, 0),
                                bevel=0.003, mat=dark, name="keypad"))
    for row in range(4):
        for col in range(3):
            bx = kx - 0.028 + col * 0.028
            bz = kz + 0.042 - row * 0.028
            body.append(box((0.018, 0.006, 0.014), pos=(bx, YF - 0.004, bz - 0.007), bevel=0,
                            mat=paper if row < 3 or col != 1 else grease, name="button"))
    # ---- The crack: a jagged line from the top right corner down towards the keypad, sunk into the face.
    crack = [(BX + 0.1, 0.405), (BX + 0.074, 0.372), (BX + 0.082, 0.345), (BX + 0.056, 0.33), (BX + 0.064, 0.318),
             (BX + 0.062, 0.322), (BX + 0.052, 0.334), (BX + 0.079, 0.348), (BX + 0.071, 0.374), (BX + 0.098, 0.407)]
    body.append(extrude_profile(crack, 0.003, pos=(0, YF + 0.0015, 0), bevel=0, mat=void, name="crack"))
    # ---- Hook: a steel finger out of the housing's left side that the handset hangs on, and a lip at its end.
    body.append(box((0.05, 0.02, 0.014), pos=(HX + 0.01, HY + 0.005, HOOK_Z - 0.005), bevel=0.004, segments=1,
                    mat=steel, name="hook"))
    body.append(box((0.014, 0.02, 0.03), pos=(HX - 0.022, HY + 0.005, HOOK_Z - 0.005), bevel=0.004, segments=1,
                    mat=steel, name="hook_lip"))
    for z in (0.03, H - 0.05):                                    # two screws through the face, the lower one rusted round
        body.append(cyl(0.012, 0.006, verts=12, pos=(BX + 0.085, YF + 0.001, z), rot=(90, 0, 0), bevel=0.003,
                        segments=1, mat=steel, name="screw"))
    # ---- The note above it: a sheet of paper taped by one corner, curling; three lines nobody reads.
    note = (Matrix.Translation((BX + 0.01, -0.012, H + 0.055)) @ Matrix.Rotation(math.radians(-7.0), 4, 'Y')
            @ Matrix.Rotation(math.radians(9.0), 4, 'X'))
    sheet = box((0.15, 0.004, 0.105), pos=(0, 0, 0), bevel=0.001, mat=paper, name="note", anchor="center")
    lines = [box((0.1 - 0.02 * k, 0.005, 0.009), pos=(-0.012 + 0.01 * k, 0.0, 0.03 - 0.025 * k), bevel=0,
                 mat=dark, name="note_line", anchor="center") for k in range(3)]
    for o in [sheet] + lines:
        body.append(placed(o, note @ o.matrix_basis))
    body.append(box((0.045, 0.004, 0.028), pos=(BX - 0.05, -0.014, H + 0.095), rot=(0, 0, 28), bevel=0.001,
                    mat=tape, name="note_tape"))
    # ---- Grease on the wall where the handset is grabbed and where the housing's edge is pushed off.
    smudge = [(HX - 0.07, 0.16), (HX - 0.045, 0.21), (HX - 0.06, 0.3), (HX - 0.035, 0.37), (HX - 0.05, 0.43),
              (HX - 0.01, 0.46), (HX - 0.025, 0.4), (HX - 0.02, 0.3), (HX - 0.04, 0.24), (HX - 0.03, 0.17)]
    body.append(extrude_profile(smudge, 0.002, pos=(0, 0.0, 0), bevel=0, mat=grease, name="grease_wall"))
    face_wear = [(BX + 0.06, 0.14), (BX + 0.105, 0.15), (BX + 0.108, 0.23), (BX + 0.09, 0.26), (BX + 0.07, 0.22)]
    body.append(extrude_profile(face_wear, 0.0015, pos=(0, YF + 0.0005, 0), bevel=0, mat=grease, name="grease_face"))
    # ---- The cord: coiled from the mouthpiece down into the housing's bottom, the coil pulled straight in the middle.
    a = Vector((HX, HY, HOOK_Z - HS_LEN + 0.01))
    b = Vector((BX - 0.06, -0.03, 0.015))
    pts = []
    n = 56
    for i in range(n + 1):
        t = i / n
        base = a.lerp(b, t) - Vector((0, 0, 0.11 * 4 * t * (1 - t)))          # it hangs below both ends
        r = 0.014 * (1.0 - 0.7 * math.sin(math.pi * t) ** 2)                 # the coil is stretched out mid-way
        th = math.tau * 7.0 * t
        pts.append(base + Vector((r * math.cos(th), r * math.sin(th), 0)))
    body.append(pipe(pts, 0.0055, verts=6, bend=0.0, mat=dark, name="cord"))
    body_mesh = join(body, "Body")

    # ---- Handset (rigged): hanging from the hook, a grip between two round ends, tape round the middle.
    hs = []
    top = HOOK_Z - 0.012
    hs.append(capsule(HS_R, HS_LEN, pos=(HX, HY, top - HS_LEN), verts=14, rings=6, mat=dark, name="grip",
                      scale=(1.0, 0.8, 1.0)))
    for z, r in ((top - 0.035, 0.038), (top - HS_LEN + 0.03, 0.036)):      # earpiece up, mouthpiece down
        hs.append(cyl(r, 0.034, verts=18, pos=(HX, HY + 0.008, z), rot=(90, 0, 0), bevel=0.008, segments=2,
                      mat=dark, name="cup", anchor="center"))
    hs.append(box((0.062, 0.052, 0.045), pos=(HX, HY, top - 0.15), rot=(0, 4, 0), bevel=0.012, segments=1, mat=tape,
                  name="tape", anchor="center"))                              # the tape holding the grip together
    hs.append(box((0.062, 0.052, 0.012), pos=(HX, HY, top - 0.117), rot=(0, -6, 0), bevel=0.004, segments=1,
                  mat=tape, name="tape_end", anchor="center"))
    hs.append(cyl(0.008, 0.02, verts=10, pos=(HX, HY, top - 0.005), bevel=0.002, segments=1, mat=steel,
                  name="loop"))                                                # the ring the hook holds
    handset = join(hs, "Handset", origin=P)

    export([body_mesh, handset], "wall_phone", kind="prop", mount="wall")
