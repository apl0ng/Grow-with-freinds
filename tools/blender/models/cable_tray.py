"""cable_tray: a 2 m module of the ceiling cable tray (room decor, environment modeler).

  cable_tray_2m  2.0 x 1.0 x 0.66 m, CEILING mount (origin on the ceiling above the segment's centre; the tray
                 bottom hangs 0.9 m below it, like the room's placeholder tray at y 5.1 under a 6 m ceiling).
                 Ladder tray: TINT side rails (the scene tints it olive / galvanised), metal_dark rungs every
                 0.25 m, three cables lying in it that line up end to end when segments are tiled along X, one
                 thin cable slopping out over the side in a sagging loop, a trapeze hanger (two threaded rods +
                 strut) in the middle, rust at the rail joints. scenes/world/props/cable_tray.tscn tiles it N times
                 in one node (segment_run.gd, flip_alternate so the loops swap sides).
"""
from gwf import *

HALF = 1.0
W = 0.25          # half width (rail centre)
BOT = -0.9        # tray bottom (rungs' top)
RAIL_H = 0.12


def build():
    paint = tint_material("TINT_paint")
    iron = lib("metal_dark")
    parts = []
    # Side rails: web + bottom flange + rolled top edge.
    for sy in (-1, 1):
        y = sy * W
        parts.append(box((2 * HALF, 0.014, RAIL_H), pos=(0, y, BOT - 0.02), bevel=0.004, mat=paint, name="web"))
        parts.append(box((2 * HALF, 0.045, 0.012), pos=(0, y - sy * 0.018, BOT - 0.02), bevel=0.004, mat=paint,
                         name="flange"))
        parts.append(capsule(0.014, 2 * HALF, pos=(-HALF, y, BOT - 0.02 + RAIL_H), rot=(0, 90, 0), verts=8, rings=2,
                             mat=paint, name="lip"))
        # splice plates at the segment ends (half on each segment) with bolts; rust bleeding from them
        for sx in (-1, 1):
            parts.append(box((0.08, 0.01, 0.09), pos=(sx * (HALF - 0.04), y + sy * 0.012, BOT - 0.005), bevel=0,
                             mat=iron, name="splice"))
            dec = extrude_profile([(sx * HALF, BOT - 0.02), (sx * (HALF - 0.16), BOT - 0.02),
                                   (sx * (HALF - 0.12), BOT + 0.025), (sx * (HALF - 0.07), BOT + 0.06),
                                   (sx * HALF, BOT + 0.07)], 0.003, bevel=0, mat="rust", name="rail_rust")
            move_verts(dec, lambda co: co + Vector((0, -(W + 0.0072), 0)))
            if sy > 0:                      # the far rail's decal faces +Y: turn it round the tray axis
                dec.rotation_euler = (0, 0, math.pi)
            parts.append(dec)
    # Rungs every 0.25 m (the tiled run keeps the spacing across joints).
    for i in range(8):
        x = -HALF + 0.125 + i * 0.25
        parts.append(box((0.045, 2 * W, 0.022), pos=(x, 0, BOT - 0.022), bevel=0.004, mat=iron, name="rung"))
    # Cables lying on the rungs: wavy in y, but every one ends where the next segment's starts.
    for y0, r, mat, ph in ((-0.13, 0.024, "dark", 0.0), (0.0, 0.019, "brown", 1.3), (0.12, 0.028, "dark", 2.4)):
        pts = [(x, y0 + 0.025 * math.sin(math.pi * x) * math.cos(ph), BOT + r) for x in
               (-HALF + i * 0.25 for i in range(9))]
        parts.append(pipe(pts, r, verts=8, bend=0, mat=mat, name="cable"))
    # One thin cable slops out over the +Y rail and sags in a loop below the tray.
    loop = [(-0.62, 0.17, BOT + 0.015), (-0.45, 0.24, BOT + RAIL_H + 0.01), (-0.3, 0.3, BOT - 0.05),
            (0.0, 0.32, BOT - 0.2), (0.28, 0.3, BOT - 0.06), (0.42, 0.24, BOT + RAIL_H + 0.01), (0.6, 0.17, BOT + 0.015)]
    parts.append(pipe(loop, 0.013, verts=6, bend=0.1, mat="dark", name="loop"))
    # Trapeze hanger in the middle: strut under the tray, two threaded rods, nuts, ceiling plates.
    parts.append(box((0.05, 2 * W + 0.16, 0.045), pos=(0, 0, BOT - 0.022 - 0.045), bevel=0.006, mat=iron,
                     name="strut"))
    for sy in (-1, 1):
        y = sy * (W + 0.05)
        parts.append(cyl(0.012, -BOT + 0.07, verts=6, pos=(0, y, BOT - 0.08), bevel=0, mat=iron, name="rod"))
        parts.append(cyl(0.022, 0.02, verts=6, pos=(0, y, BOT - 0.087), bevel=0, mat=iron, name="nut"))
        parts.append(box((0.1, 0.1, 0.012), pos=(0, y, -0.012), bevel=0.003, mat=iron, name="anchor"))
    tray = join(parts, "Tray")
    export(tray, "cable_tray_2m", kind="prop", mount="ceiling")
