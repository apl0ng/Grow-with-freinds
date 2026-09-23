"""ceiling_beam: a 5 m segment of the steel I-beams that carry the roof deck (architecture, environment modeler).

Kind "part", mount "ceiling": the origin is the centre of the top flange's top face (the deck's crests rest on
it), everything hangs below z = 0. 5.0 m long along X, 0.4 m deep, 0.22 m flanges. scenes/world/room.tscn tiles
it 3 times along Godot Z at x = -5, 0, 5 (Ceiling/Beam*, one scenes/world/props/segment_run.gd run each, every
other copy turned round): they hide the ceiling panels' seams and the grow lights / lamps hang under them.

  Section     rolled I-section extruded along X (flat faces, chamfered flange tips and web fillets), no bevel
              on the cut ends, so segments butt together without a notch.
  Splices     each end carries half of a bolted splice: web plates both sides + a plate under the bottom
              flange with hex bolt heads; two segments make one splice (at the walls they read as bearings).
  Wear        a web stiffener mid-span, rust weeping from the splice bolts, rust blooms on the bottom flange,
              an old cable tie left hanging with a cut-off stub of cable.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401

L = PANEL / 2                         # half length 2.5
H = 0.4                               # depth
B = 0.11                              # half flange width
T = 0.035                             # flange thickness
W = 0.013                             # half web thickness
C = 0.008                             # flange tip chamfer
F = 0.014                             # web fillet (chamfer)
SPLICE = 0.24                         # half splice plate length (each end)

# The section, counter-clockwise in (y, z) (y to the right = Blender Y, z up).
SECTION = [
    (-B + C, -H), (B - C, -H), (B, -H + C), (B, -H + T - C), (B - C, -H + T), (W + F, -H + T), (W, -H + T + F),
    (W, -T - F), (W + F, -T), (B - C, -T), (B, -T + C), (B, 0.0), (-B, 0.0), (-B, -T + C), (-B + C, -T),
    (-W - F, -T), (-W, -T - F), (-W, -H + T + F), (-W - F, -H + T), (-B + C, -H + T), (-B, -H + T - C), (-B, -H + C),
]


def build():
    M = arch_mats()
    mb = MB()
    metal = M["metal_dark"]
    # the rolled section: one quad per profile edge along the whole 5 m
    n = len(SECTION)
    for i in range(n):
        (y0, z0), (y1, z1) = SECTION[i], SECTION[(i + 1) % n]
        if z0 == 0.0 and z1 == 0.0:
            continue                                  # top face: against the deck, never seen
        hint = (0, z1 - z0, -(y1 - y0))               # outward (right-hand) normal of a CCW edge
        mb.face([(-L, y0, z0), (L, y0, z0), (L, y1, z1), (-L, y1, z1)], metal, hint)

    # rust: blooms on the bottom flange (underside + tips), weeping from the splice bolts down the web
    def under(poly, mat, off=0.002):
        c = clip_rect(poly, -L, L, -B + C, B - C)
        if c:
            mb.face([(u, v, -H - off) for u, v in c], M[mat], (0, 0, -1))

    def web(poly, side, mat, off=0.0015):
        c = clip_rect(poly, -L, L, -H + T + F, -T - F)
        if c:
            mb.face([(u, side * (W + off), v) for u, v in c], M[mat], (0, side, 0))

    def tip(poly, side, mat, off=0.0015):
        c = clip_rect(poly, -L, L, -H + C, -H + T - C)
        if c:
            mb.face([(u, side * (B + off), v) for u, v in c], M[mat], (0, side, 0))
    under(blob(-0.9, 0.02, 0.45, 0.07, 1.2, n=16, wob=0.25), "rust")
    under(blob(1.5, -0.03, 0.3, 0.06, 3.1, n=14, wob=0.25), "rust")
    under(blob(0.35, 0.04, 0.16, 0.04, 5.0, n=12, wob=0.3), "rust")
    for side, seed in ((-1, 0.4), (1, 2.9)):
        tip(blob(-0.85 + 0.1 * side, -H + T / 2, 0.38, 0.03, seed, n=14, wob=0.3), side, "rust")
        for ex in (-1, 1):                       # streaks running down from under the splice plates
            x0 = ex * (L - SPLICE - 0.04)
            web(streak(x0, -T - F - 0.02, 0.22, 0.05, 0.015, seed=seed + ex), side, "rust")
        web(blob(0.6 * side, -0.2, 0.25, 0.08, seed + 1.0, n=14, wob=0.3), side, "grime")
    beam = mb.obj("beam_section", smooth=30.0)

    parts = [beam]
    # splice plates (bevel 0 on purpose: the two halves meet flush at the seam) + bolts
    zc = -H / 2
    ph = H - 2 * T - 2 * F - 0.03                  # web plate height
    for ex in (-1, 1):
        x0 = ex * (L - SPLICE / 2)
        for side in (-1, 1):
            parts.append(box((SPLICE, 0.014, ph), pos=(x0, side * (W + 0.007), zc - ph / 2), bevel=0,
                             mat="metal_dark", name="web_plate"))
            for bx in (x0 - SPLICE / 4, x0 + SPLICE / 4):
                for bz in (zc - ph / 4, zc + ph / 4):
                    parts.append(cyl(0.02, 0.013, verts=6, pos=(bx, side * (W + 0.014), bz),
                                     rot=(-90 * side, 0, 0), bevel=0, mat="metal_dark", name="splice_bolt"))
        parts.append(box((SPLICE, 2 * B - 0.03, 0.014), pos=(x0, 0, -H - 0.014), bevel=0, mat="metal_dark",
                         name="flange_plate"))
        for bx in (x0 - SPLICE / 4, x0 + SPLICE / 4):
            for by in (-B / 2, B / 2):
                parts.append(cyl(0.02, 0.013, verts=6, pos=(bx, by, -H - 0.014), rot=(180, 0, 0), bevel=0,
                                 mat="metal_dark", name="flange_bolt"))
    # mid-span stiffeners, both sides of the web
    for side in (-1, 1):
        parts.append(box((0.016, B - W - 0.012, H - 2 * T), pos=(0.0, side * (W + (B - W - 0.012) / 2), -H + T),
                         bevel=0.003, mat="metal_dark", name="stiffener"))
    # an old cable tie on the bottom flange, a cut cable stub hanging out of it
    tie = torus(0.125, 0.008, pos=(1.35, 0.0, -H + T / 2), rot=(0, 90, 0), major_segments=12, minor_segments=4,
                scale=(0.26, 0.95, 1.0), mat="dark", name="tie")
    stub = pipe(sag_points((1.34, 0.02, -H - 0.03), (1.31, 0.06, -H - 0.36), sag=-0.05, n=5), 0.011, verts=6,
                mat="dark", name="cable_stub")
    tape = cyl(0.015, 0.05, verts=8, pos=(1.31, 0.06, -H - 0.39), bevel=0.003, mat="caution", name="cable_tape")
    parts += [tie, stub, tape]
    export(join(parts, "Beam"), "ceiling_beam", kind="part", mount="ceiling", budget=1500)
