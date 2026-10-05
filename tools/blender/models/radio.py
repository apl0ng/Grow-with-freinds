"""radio: a walkie-talkie (M18 radio agent; CONTRACTS "M18", "Radio"). Two nodes: Body (static) and Led.

A site handset that has been dropped off every ladder in the building: a fat case in dark olive plastic rubbed grey at
the corners and along the bottom, one top corner dented in and cracked, a speaker grille of five slats, a peeling
channel sticker somebody wrote on, a stubby rubber antenna bent over to one side, a channel knob and a volume knob, a
push-to-talk bar on the side, and the battery door on the back held shut with grey tape wound round the case twice
(one turn crooked, one loose end hanging).

kind "item": the face (grille, sticker, lamp) is Blender -Y and lands on Godot -Z. scenes/items/radio.tscn turns it
towards the holder in the hand (hold_rotation_degrees y 165); the shelf marker (Room `Decor/RadioShelf/Spot`) is
turned so the face looks into the room. Floor mount: standing on its base, origin under the middle of the base.
About 0.17 x 0.41 x 0.10 m (Godot W x H x D, the antenna included): twice a real handset, like every held item.
  <Visual, Toonify> / Body   everything above (static)
                    / Led    the small lamp above the grille, origin at its centre. scripts/items/radio.gd lights it
                             while the radio sends or receives (a material_override; Toonify leaves those alone)
Godot space: x = -Blender x, y = Blender z, z = -Blender y (kind "item" turns the model round).
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

W, D, H = 0.15, 0.08, 0.27              # the case
YF = -D / 2                             # its face
YB = D / 2                              # its back
LED = (0.046, YF, 0.236)                # the lamp, top right of the face
ANT = (-0.04, 0.01)                     # the antenna's foot on the top (x, y)


def build():
    reset()
    case = material("radio_case", "#474c40", "soft")      # dark olive plastic
    worn = material("radio_worn", "#6e7064", "matte")     # where hands and floors rubbed it grey
    tape = material("radio_tape", "#8f8a7c", "matte")     # old tape, gone grey
    lamp = material("radio_lamp", "#5a2c2a", "soft")      # the lamp, unlit (dull red glass)
    rubber = lib("dark")
    void = lib("void")
    paper = lib("cream")

    body = []
    # ---- The case: a fat rounded box, the top right front corner knocked in.
    shell = subdivide(box((W, D, H), bevel=0.022, mat=case, name="case"), 1)
    dent(shell, (W / 2, YF, H - 0.015), radius=0.06, depth=0.009, direction=(-0.6, 0.6, -0.5))
    jitter(shell, 0.0015, seed=11)
    paint(shell, worn, lambda c, n: c.z < 0.02 or (abs(c.x) > W / 2 - 0.012 and (c.z < 0.07 or c.z > H - 0.025))
          or (n.z > 0.5 and abs(c.x) > W / 2 - 0.02))
    body.append(shell)
    # A crack running off the dent.
    body.append(box((0.04, 0.003, 0.0025), pos=(0.052, YF - 0.0008, 0.244), rot=(0, 34, 0), bevel=0, mat=void,
                    name="crack"))

    # ---- The face: a dark grille recess with five slats across it.
    body.append(extrude_profile(rounded_rect(0.112, 0.088, 0.012, n=3, cx=0.0, cy=0.168), 0.003,
                                pos=(0, YF + 0.001, 0), bevel=0, mat=void, name="grille"))
    for i in range(5):
        z = 0.136 + i * 0.016
        body.append(box((0.104, 0.005, 0.007), pos=(0.0, YF - 0.002, z), bevel=0, mat=case, name="slat"))
    # The channel sticker, written on, its top right corner peeling off the case.
    sticker = extrude_profile(rounded_rect(0.086, 0.042, 0.006, n=2, cx=-0.006, cy=0.083), 0.0015,
                              pos=(0, YF + 0.0005, 0), bevel=0, mat=paper, name="sticker")
    move_verts(sticker, lambda co: Vector((co.x, co.y - 0.012 * max(0.0, (co.x - 0.01) / 0.027) * max(0.0, (co.z - 0.09) / 0.014), co.z)))
    body.append(sticker)
    for x0, x1, z in ((-0.04, 0.0, 0.088), (-0.04, 0.02, 0.076)):
        body.append(box((x1 - x0, 0.002, 0.004), pos=((x0 + x1) / 2, YF - 0.0012, z), bevel=0, mat=void, name="pen"))

    # ---- The top: the antenna (stubby rubber, bent over), its collar, the channel and volume knobs.
    body.append(cyl(0.019, 0.016, verts=10, pos=(ANT[0], ANT[1], H - 0.006), bevel=0.004, mat=rubber, name="collar"))
    antenna = cyl(0.015, 0.13, verts=8, pos=(ANT[0], ANT[1], H + 0.008), radius_top=0.011, bevel=0.007, mat=rubber,
                  name="antenna")
    apply_transform(antenna)
    move_verts(antenna, lambda co: Vector((co.x - 0.22 * max(0.0, co.z - H - 0.03) ** 2 * 10.0, co.y + 0.006 * max(0.0, co.z - H) / 0.13, co.z)))
    body.append(antenna)
    for x, y, r, h in ((0.038, -0.004, 0.017, 0.026), (0.006, 0.016, 0.012, 0.02)):
        body.append(cyl(r, h, verts=8, pos=(x, y, H - 0.004), bevel=0.004, mat=rubber, name="knob"))
    body.append(box((0.003, 0.012, 0.004), pos=(0.038, -0.012, H + 0.021), rot=(0, 0, 25), bevel=0, mat=paper,
                    name="tick"))

    # ---- The side: the push-to-talk bar (Blender -X, the holder's left as he looks at the face).
    body.append(box((0.012, 0.042, 0.078), pos=(-W / 2 - 0.004, 0.0, 0.122), bevel=0.005, mat=rubber, name="ptt"))

    # ---- The back: the battery door and its latch, and the tape that holds it shut, wound round the case.
    body.append(box((0.122, 0.006, 0.13), pos=(0.0, YB + 0.001, 0.018), bevel=0, mat=case, name="door"))
    body.append(box((0.03, 0.006, 0.012), pos=(0.0, YB + 0.004, 0.152), bevel=0, mat=worn, name="latch"))
    body.append(box((W + 0.008, D + 0.014, 0.03), pos=(0.0, 0.002, 0.034), bevel=0, mat=tape, name="tape"))
    turn = box((W + 0.01, D + 0.016, 0.026), pos=(0.0, 0.002, 0.07), rot=(0, 9, 0), bevel=0, mat=tape,
               name="tape_turn")
    body.append(turn)
    body.append(box((0.024, 0.003, 0.05), pos=(0.05, YB + 0.012, 0.032), rot=(12, 0, -8), bevel=0, mat=tape,
                    name="tape_end"))

    radio = join(body, "Body")
    low = min(v.co.z for v in radio.data.vertices)
    if abs(low) > 0.0005:
        move_verts(radio, lambda co: Vector((co.x, co.y, co.z - low)))

    # ---- The lamp: its own node (radio.gd lights it).
    bulb = cyl(0.009, 0.01, verts=10, pos=LED, rot=(90, 0, 0), bevel=0.003, mat=lamp, name="led", anchor="center")
    led = join([bulb], "Led", origin=LED)
    export([radio, led], "radio", kind="item", mount="floor")
