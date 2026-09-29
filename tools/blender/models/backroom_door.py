"""backroom_door: the steel door to the back room, where written-up workers sit out 30 s (room decor,
rigged). M10 events: goes into the room's booth partition (`Decor/BackRoomDoor`, events agent); the lead
instances the model AS `Visual` so the door script finds `Visual/Door`.

Wall mount: back on the wall plane, origin = the bottom centre of the frame at FLOOR level (the frame's
feet stand on z = 0). ~1.1 x 2.2 x 0.17 m (W x H x D, Godot).
  <Visual, Toonify> / Frame     jambs + head, three hinges, rust at the feet (static)
                    / Backing   a void-black slab filling the opening on the wall plane (the dark room
                                behind); hide it if the doorway must be see-through
                    / Door      the leaf: pivot on the HINGE edge at the floor (Godot x = -0.46, z = 0.07),
                                rest rotation identity. `Door.rotation.y = deg_to_rad(80)` swings it away
                                from the viewer (into the back room), -80 towards the viewer.
                                Kick plate, wired window (dark inset + a cross of bars), the caution
                                "STAFF ONLY" plate, a lever handle, a crooked "NO BREAKS" tag.
Sad: two boot dents in the leaf, the kick plate hung askew, a rust streak along its foot and up the jamb
feet, the tag on one tack.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

FW, FH, JW, FD = 1.1, 2.2, 0.08, 0.14   # frame: width, height, jamb width, depth (y from -FD to 0)
DW, DT, DH = 0.92, 0.045, 2.09          # leaf
HINGE_X = -0.46                         # the leaf's hinge edge (1 cm off the jamb face at -0.47)
DY = -0.07                              # leaf centre plane
YF = DY - DT / 2                        # leaf front face


def build():
    steel = lib("metal_dark")
    bare = lib("metal")
    caution = lib("caution")
    ink = material("stencil", pal("INK"), "flat")
    void = lib("void")
    rust = lib("rust")
    card = lib("cream")

    # ---- Frame (static): jambs, head, hinges on the left jamb, rust at both feet.
    fr = []
    for sx in (-1, 1):
        fr.append(box((JW, FD, FH - JW), pos=(sx * (FW / 2 - JW / 2), -FD / 2, 0), bevel=0.012, segments=2, mat=steel,
                      name="jamb"))
        pts = [(0.015, 0.012), (0.015, 0.2), (0.03, 0.16), (0.045, 0.24), (0.06, 0.13), (0.07, 0.18), (0.075, 0.012)]
        fr.append(extrude_profile([(sx * (FW / 2 - u) * 1.0, v) for u, v in (pts if sx < 0 else pts[::-1])], 0.002,
                                  pos=(0, -FD + 0.0005, 0), bevel=0, mat=rust, name="jamb_rust"))
    fr.append(box((FW, FD, JW), pos=(0, -FD / 2, FH - JW), bevel=0.012, segments=2, mat=steel, name="head"))
    for z in (0.32, 1.06, 1.8):
        fr.append(box((0.024, 0.05, 0.11), pos=(HINGE_X - 0.008, DY, z), bevel=0.004, segments=1, mat=bare,
                      name="hinge"))
    frame = join(fr, "Frame")
    backing = box((FW - 2 * JW, 0.012, FH - JW), pos=(0, -0.006, 0), bevel=0, mat=void, name="Backing")
    backing = join([backing], "Backing")

    # ---- Door leaf: dented steel, a kick plate hung askew with rust along its foot.
    dr = []
    leaf = box((DW, DT, DH), pos=(0, DY, 0.02), bevel=0.012, segments=2, mat=steel, name="leaf")
    subdivide(leaf, 5)
    dent(leaf, local(leaf, (0.24, YF, 0.5)), radius=0.17, depth=0.022, direction=(0, 1, 0))
    dent(leaf, local(leaf, (-0.12, YF, 0.92)), radius=0.12, depth=0.012, direction=(0, 1, 0))
    dr.append(leaf)
    kick = box((DW - 0.06, 0.008, 0.24), pos=(0.0, YF - 0.003, 0.05), rot=(0, 1.3, 0), bevel=0.003, segments=1,
               mat=bare, name="kick_plate")
    dr.append(kick)
    dr.append(extrude_profile([(-0.42, 0.055), (-0.42, 0.11), (-0.3, 0.085), (-0.18, 0.13), (-0.02, 0.075), (0.12, 0.115),
                               (0.27, 0.07), (0.41, 0.1), (0.41, 0.055)], 0.002, pos=(0, YF - 0.0075, 0), bevel=0,
                              mat=rust, name="kick_rust"))
    # Wired window: a dark inset with a bare-steel bezel and a cross of bars.
    wz, ww, wh = 1.68, 0.26, 0.36
    dr.append(box((ww, 0.012, wh), pos=(0, YF + 0.004, wz - wh / 2), bevel=0, mat=lib("dark"), name="window"))
    for (bx, bw, bz, bh) in ((-ww / 2 - 0.01, 0.024, wz - wh / 2 - 0.012, wh + 0.024),
                             (ww / 2 + 0.01, 0.024, wz - wh / 2 - 0.012, wh + 0.024),
                             (0.0, ww + 0.044, wz - wh / 2 - 0.012, 0.024), (0.0, ww + 0.044, wz + wh / 2 - 0.012, 0.024)):
        dr.append(box((bw, 0.01, bh), pos=(bx, YF - 0.003, bz), bevel=0.002, segments=1, mat=bare, name="bezel"))
    dr.append(box((0.012, 0.006, wh), pos=(0, YF - 0.001, wz - wh / 2), bevel=0, mat=bare, name="bar_v"))
    dr.append(box((ww, 0.006, 0.012), pos=(0, YF - 0.001, wz - 0.006), bevel=0, mat=bare, name="bar_h"))
    # "STAFF ONLY": caution plate, two stencil lines, hung a touch crooked.
    pz = 1.2
    plate = [extrude_profile(rounded_rect(0.44, 0.27, 0.02), 0.01, pos=(0, YF + 0.004, pz), bevel=0.004, mat=caution,
                             name="plate")]
    plate += stencil("STAFF", 0.085, pos=(0, YF - 0.005, pz + 0.025), depth=0.004, mat=ink, name="letter")
    plate += stencil("ONLY", 0.085, pos=(0, YF - 0.005, pz - 0.11), depth=0.004, mat=ink, name="letter")
    dr += roll(plate, (0, YF, pz), -1.5)
    # Handle side: a lever handle, its rose, a keyhole plate.
    hz = 1.04
    dr.append(cyl(0.032, 0.008, verts=16, pos=(0.36, YF + 0.001, hz), rot=(90, 0, 0), bevel=0.002, segments=1, mat=bare,
                  name="rose"))
    dr.append(pipe([(0.36, YF, hz), (0.36, YF - 0.065, hz), (0.2, YF - 0.065, hz)], 0.013, verts=8, bend=0.03,
                   mat=bare, name="handle"))
    dr.append(box((0.04, 0.006, 0.09), pos=(0.36, YF - 0.002, hz - 0.14), bevel=0.002, segments=1, mat=bare,
                  name="keyplate"))
    dr.append(box((0.014, 0.004, 0.03), pos=(0.36, YF - 0.005, hz - 0.11), bevel=0, mat=void, name="keyhole"))
    # "NO BREAKS" tag under the window, hanging off one tack, crooked.
    tz = 0.86
    tag = [extrude_profile(rounded_rect(0.24, 0.12, 0.01), 0.004, pos=(0.14, YF + 0.001, tz), bevel=0, mat=card,
                           name="tag")]
    tag += stencil("NO", 0.04, pos=(0.14, YF - 0.003, tz + 0.012), depth=0.002, mat=ink, name="tag_letter")
    tag += stencil("BREAKS", 0.04, pos=(0.14, YF - 0.003, tz - 0.046), depth=0.002, mat=ink, name="tag_letter")
    tag.append(cyl(0.008, 0.006, verts=8, pos=(0.14 - 0.1, YF - 0.004, tz + 0.045), rot=(90, 0, 0), bevel=0, mat=bare,
                   name="tack"))
    dr += roll(tag, (0.04, YF, tz + 0.045), -8.0)
    door = join(dr, "Door", origin=(HINGE_X, DY, 0.0))

    export([frame, backing, door], "backroom_door", kind="prop", mount="wall")
