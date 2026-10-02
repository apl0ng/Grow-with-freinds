"""wall_opening family: wall panels with openings for the M14 annexes (level agent). Same 5 m x 6 m cinder-block
module as wall_panel.py (its Wall class does the work), same wall line, same tiling rules.

Walk-through openings have NO back face: two of these panels stand back to back, 2 x REVEAL (0.6 m) apart, and
their jambs and heads meet in the middle of the wall. Each variant is used on both sides of its wall:

  wall_panel_doorway    a 2.0 x 2.5 m doorway, centre 1.25 m to the viewer's LEFT of the panel centre (local x -1.25)
  wall_panel_doorway_b  the same doorway 1.25 m to the RIGHT (local x +1.25)
                        (the main room's east wall <-> the grow hall: world z -6.25 and +6.25; the main-room side
                        uses _doorway at the slot z -5 and _doorway_b at z +5, the hall side the other way round)
  wall_panel_pass       half of the 4.2 x 3.75 m passage to the loading dock, centred on the panel's LEFT edge
                        (local x -2.5: the opening covers local x -2.5..-0.4)
  wall_panel_pass_b     the other half, centred on the RIGHT edge (local x +2.5: 0.4..2.5)
                        (the main room's south wall <-> the dock, seam at world x -5: the main-room side uses _pass
                        at the slot x -7.5 and _pass_b at x -2.5, the dock side the other way round)
  wall_panel_door_c     the roller door's opening (dark back, like wall_panel_door) centred in ONE panel: the
                        dock's outer wall, props/roller_door.tscn at the panel centre
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401
from wall_panel import *              # noqa: E402,F401  (Wall, the module constants, paint_wear, scuff)

DOORWAY_HALF = 1.0                    # doorway half width
DOORWAY_TOP = 10 * CH_H               # 2.5 m: ten courses


class OpenWall(Wall):
    """A wall whose openings go right through: jambs and head run back REVEAL m, no back face."""

    def reveals(self):
        M, mb = self.M, self.mb
        for ox0, ox1, oz0, oz1 in self.openings:
            a, b = max(ox0, X0), min(ox1, X1)
            if ox0 > X0:
                mb.face([(ox0, 0, oz0), (ox0, REVEAL, oz0), (ox0, REVEAL, oz1), (ox0, 0, oz1)], M["concrete_dark"],
                        (1, 0, 0))
            if ox1 < X1:
                mb.face([(ox1, 0, oz0), (ox1, REVEAL, oz0), (ox1, REVEAL, oz1), (ox1, 0, oz1)], M["concrete_dark"],
                        (-1, 0, 0))
            mb.face([(a, 0, oz1), (b, 0, oz1), (b, REVEAL, oz1), (a, REVEAL, oz1)], M["concrete_dark"], (0, 0, -1))


def wall_doorway(name, door_x, seed):
    """A doorway near one end of the panel; door_x = its centre in this panel's coords."""
    reset()
    lintel = (door_x - 1.5, door_x + 1.5, 10, "block_light")          # precast, half a metre of bearing
    opening = (door_x - DOORWAY_HALF, door_x + DOORWAY_HALF, 0.0, DOORWAY_TOP)
    w = OpenWall(seed=seed, openings=[opening], lintels=[lintel],
                 skirt_gaps=[(door_x - DOORWAY_HALF, door_x + DOORWAY_HALF)])
    side = 1 if door_x < 0 else -1                    # the side of the doorway with most of the panel
    jamb = door_x + side * DOORWAY_HALF                 # that jamb
    if side > 0:
        w.chips = {(2, jamb + 0.3): ("bl", 0.09), (6, jamb + 0.15): ("tl", 0.07), (13, 1.5): ("tr", 0.06),
                   (18, -0.9): ("bl", 0.07), (21, 0.8): ("br", 0.06)}
        w.broken = {(7, jamb + 1.6)}
    else:
        w.chips = {(1, jamb - 0.2): ("tr", 0.08), (5, jamb - 0.35): ("br", 0.07), (12, -1.4): ("tl", 0.06),
                   (17, 1.1): ("br", 0.07), (22, -0.6): ("tl", 0.06)}
        w.broken = {(14, jamb - 1.3)}
    w.structure()
    lo, hi = sorted((jamb, jamb + side * 0.26))
    w.hazard(lo, hi, SK_H + 0.02, 1.55)               # trolleys clip this jamb
    w.band_edge(seed * 0.41)
    w.drips([x for x in (-2.1, -1.4, -0.7, 0.0, 0.7, 1.4, 2.1) if (x - jamb) * side > 0.5], seed)
    w.peel(jamb + side * 1.4, 0.7, 0.22, 0.13, seed * 0.1)
    w.crack(zigzag(door_x + side * 1.5, 2.78, door_x + side * 2.2, 3.7, 6, 0.05, seed * 0.07))   # from the lintel's end
    w.decal(streak(jamb + side * 1.9, TOP, 1.5, 0.4, 0.16, seed=seed * 0.13, wander=0.06), "block_dark", 0)
    w.decal(streak(door_x + side * 1.42, DOORWAY_TOP - 0.01, 0.7, 0.06, 0.02, seed=seed), "rust", 1)
    w.skirting(notches=[(jamb + side * 0.22, 0.16)],
               scuffs=[scuff(jamb + side * 0.6, 0.12, 0.4, 0.035),
                       scuff(jamb + side * 1.5, 0.09, 0.3, 0.03, "concrete"),
                       scuff(jamb + side * 2.3, 0.14, 0.3, 0.035)])
    export(join([w.mb.obj("wall_blocks", smooth=30.0)], "Wall"), name, kind="prop", mount="floor", budget=4500)


def wall_pass(name, door_x, seed):
    """Half of the wide passage: its centre sits on this panel's edge (door_x = -2.5 or +2.5)."""
    reset()
    lintel = (door_x - 2.5, door_x + 2.5, 15, "block_light")
    opening = (door_x - DOOR_HALF, door_x + DOOR_HALF, 0.0, DOOR_TOP)
    w = OpenWall(seed=seed, openings=[opening], lintels=[lintel],
                 skirt_gaps=[(door_x - DOOR_HALF, door_x + DOOR_HALF)])
    side = 1 if door_x < 0 else -1                    # the side of the passage that is inside this panel
    jamb = door_x + side * DOOR_HALF
    if side > 0:
        w.chips = {(2, jamb + 0.3): ("bl", 0.09), (5, jamb + 0.15): ("tl", 0.07), (11, 1.4): ("tr", 0.06),
                   (18, 0.6): ("bl", 0.07), (22, 1.9): ("br", 0.06)}
        w.broken = {(3, jamb + 0.9)}
    else:
        w.chips = {(1, jamb - 0.2): ("tr", 0.08), (9, -0.6): ("bl", 0.07), (20, -1.9): ("tr", 0.06),
                   (13, -1.1): ("tl", 0.06)}
        w.broken = {(12, -1.2)}
    w.structure()
    lo, hi = sorted((jamb, jamb + side * 0.26))
    w.hazard(lo, hi, SK_H + 0.02, 1.55)
    w.band_edge(seed * 0.37)
    w.drips([x for x in (-2.2, -1.5, -0.8, -0.1, 0.6, 1.3, 2.0) if (x - jamb) * side > 0.45], seed)
    w.peel(jamb + side * 1.3, 0.75, 0.24, 0.14, seed * 0.05)
    w.crack(zigzag(jamb + side * 0.5, 4.02, jamb + side * 1.2, 4.9, 6, 0.05, seed * 0.03))
    w.decal(streak(jamb + side * 1.7, TOP, 1.6, 0.45, 0.18, seed=seed * 0.11, wander=0.06), "block_dark", 0)
    w.decal(streak(jamb + side * 0.32, DOOR_TOP - 0.01, 0.85, 0.07, 0.02, seed=seed), "rust", 1)
    w.skirting(notches=[(jamb + side * 0.25, 0.16)],
               scuffs=[scuff(jamb + side * 0.6, 0.12, 0.4, 0.035),
                       scuff(jamb + side * 1.4, 0.09, 0.3, 0.03, "concrete"),
                       scuff(jamb + side * 2.0, 0.14, 0.35, 0.035)])
    export(join([w.mb.obj("wall_blocks", smooth=30.0)], "Wall"), name, kind="prop", mount="floor", budget=4500)


def wall_door_centred(name, seed):
    """The roller door's opening in the middle of one panel (dark back: the shutter stands in it)."""
    reset()
    lintel = (-2.5, 2.5, 15, "block_light")
    opening = (-DOOR_HALF, DOOR_HALF, 0.0, DOOR_TOP)
    w = Wall(seed=seed, openings=[opening], lintels=[lintel], skirt_gaps=[(-DOOR_PLATE, DOOR_PLATE)])
    w.chips = {(18, -1.6): ("bl", 0.07), (22, 1.0): ("br", 0.06), (20, -0.4): ("tr", 0.06), (17, 2.0): ("tl", 0.07)}
    w.broken = {(19, 0.9)}
    w.structure()
    for side in (-1, 1):
        lo, hi = sorted((side * DOOR_PLATE, side * (DOOR_PLATE + 0.22)))
        w.hazard(lo, hi, SK_H + 0.02, 1.55)
    w.crack(zigzag(-1.9, 4.02, -1.2, 4.95, 6, 0.05, 1.3))
    w.crack(zigzag(1.2, 5.3, 2.1, 5.9, 5, 0.04, 2.6), 0.014)
    w.decal(streak(0.6, TOP, 1.7, 0.5, 0.2, seed=3.7, wander=0.07), "block_dark", 0)
    w.decal(streak(-2.42, DOOR_TOP - 0.01, 0.85, 0.07, 0.02, seed=seed), "rust", 1)
    w.skirting()
    export(join([w.mb.obj("wall_blocks", smooth=30.0)], "Wall"), name, kind="prop", mount="floor", budget=4500)


def build():
    wall_doorway("wall_panel_doorway", -1.25, 61)
    wall_doorway("wall_panel_doorway_b", 1.25, 67)
    wall_pass("wall_panel_pass", -2.5, 71)
    wall_pass("wall_panel_pass_b", 2.5, 79)
    wall_door_centred("wall_panel_door_c", 83)
