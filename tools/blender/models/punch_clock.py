"""punch_clock: the "CLOCK IN" time clock by the roller door, with its card rack (room decor).

Wall mount, origin on the wall at FLOOR level (like the scene root of scenes/world/props/punch_clock.tscn):
the cabinet hangs at chest height (1.22-1.86 m), so the model is ~0.95 x 1.9 x 0.3 m with its power cord
running down to a wall socket. The "CLOCK IN" Label3D stays in the scene above it.
Build: an olive steel cabinet with a hooded top, a small dark display (7-segment "LATE", faint neon
green), the card slot in a steel bezel with a card stuck half-way in, a brass-less lever, a steel card
rack on the right with a stack of time cards (a few crooked, one fallen on the floor), the cord + socket.
Sad: the cabinet hangs crooked (3 deg), the paint is worn dark round the slot, a rust run from a bolt,
the display only knows one word.
"""
from gwf import *

BOX_W, BOX_H, BOX_D = 0.48, 0.66, 0.24
BOX_Z = 1.2                       # bottom of the cabinet
TILT = -3.0                       # crooked (degrees about the wall normal)
RACK_X = 0.56                     # card rack centre


def rounded_rect(w, h, r, n=4, cx=0.0, cy=0.0):
    pts = []
    for qx, qy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180),
                       (w / 2 - r, -h / 2 + r, 270)):
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((cx + qx + r * math.cos(a), cy + qy + r * math.sin(a)))
    return pts


# 7-segment layout: segment -> (x0, y0, x1, y1) in a 1 x 2 cell (y up), bars ~0.22 thick.
SEG = {"a": (0.1, 1.78, 0.9, 2.0), "b": (0.78, 1.05, 1.0, 1.9), "c": (0.78, 0.1, 1.0, 0.95),
       "d": (0.1, 0.0, 0.9, 0.22), "e": (0.0, 0.1, 0.22, 0.95), "f": (0.0, 1.05, 0.22, 1.9),
       "g": (0.1, 0.89, 0.9, 1.11)}
GLYPH = {"L": "def", "A": "abcefg", "T": "defg", "E": "adefg"}


def placed(obj, m):
    """Bake the matrix `m` into obj (built around the world origin) and return it."""
    obj.matrix_world = m
    apply_transform(obj)
    return obj


def build():
    paint_mat = lib("olive")                 # institutional olive
    steel = lib("metal_dark")
    card = lib("cream")
    ink = lib("dark")
    lcd = lib("neon_green")                   # glowing segments (the only light on it)
    void = lib("void")
    rust = lib("rust")
    parts = []

    cz = BOX_Z + BOX_H / 2
    cab = []
    # Cabinet: a fat rounded box, a hooded top (overhang), a darker back plate on the wall.
    cab.append(box((BOX_W, BOX_D, BOX_H), pos=(0, -BOX_D / 2 - 0.01, BOX_Z), bevel=0.04, segments=3,
                   mat=paint_mat, name="cabinet"))
    cab.append(box((BOX_W + 0.05, BOX_D + 0.04, 0.05), pos=(0, -BOX_D / 2 - 0.03, BOX_Z + BOX_H - 0.01),
                   bevel=0.02, segments=2, mat=paint_mat, name="hood"))
    cab.append(box((BOX_W - 0.02, 0.012, BOX_H + 0.04), pos=(0, -0.006, BOX_Z - 0.02), bevel=0.005, mat=steel,
                   name="backplate"))
    yf = -BOX_D - 0.01                         # cabinet front face
    # Display window: steel bezel, dark screen, "LATE" in chunky 7-segment bars.
    dz = cz + 0.17
    cab.append(extrude_profile(rounded_rect(0.34, 0.15, 0.028, cy=0), 0.012, pos=(0, yf + 0.004, dz), bevel=0.005,
                               mat=steel, name="bezel"))
    cab.append(extrude_profile(rounded_rect(0.3, 0.112, 0.016), 0.006, pos=(0, yf - 0.006, dz), bevel=0,
                               mat=ink, name="screen"))
    cell_w, gap = 0.05, 0.02
    x0 = -(4 * cell_w + 3 * gap) / 2
    for i, ch in enumerate("LATE"):
        for sname in GLYPH[ch]:
            a, b, c, d = SEG[sname]
            ox = x0 + i * (cell_w + gap)
            s = cell_w
            cab.append(extrude_profile([(ox + a * s, dz - s + b * s), (ox + c * s, dz - s + b * s),
                                        (ox + c * s, dz - s + d * s), (ox + a * s, dz - s + d * s)], 0.003,
                                       pos=(0, yf - 0.011, 0), bevel=0, mat=lcd, name="seg"))
    # Card slot: a raised steel mouth with a void slot, worn dark paint around it, a card stuck in it.
    sz = cz - 0.06
    cab.append(extrude_profile(rounded_rect(0.36, 0.11, 0.032), 0.02, pos=(0, yf + 0.004, sz), bevel=0.008,
                               mat=steel, name="slot_mouth"))
    cab.append(extrude_profile(rounded_rect(0.27, 0.024, 0.008), 0.004, pos=(0, yf - 0.0165, sz), bevel=0,
                               mat=void, name="slot"))
    cab.append(extrude_profile([(-0.16, 0.0), (-0.09, 0.02), (0.07, 0.012), (0.17, -0.004), (0.16, -0.08),
                                (0.02, -0.095), (-0.15, -0.075)], 0.003, pos=(0, yf + 0.0015, sz - 0.045),
                               bevel=0, mat=steel, name="wear"))       # paint worn down to bare steel
    # The stuck card: pokes out of the slot, drooping (a card lying in the slit, bent down ~16 deg).
    at_slot = (Matrix.Translation((0.01, yf - 0.018, sz)) @ Matrix.Rotation(math.radians(16), 4, 'X')
               @ Matrix.Rotation(math.radians(3), 4, 'Z'))
    cab.append(placed(box((0.19, 0.13, 0.004), pos=(0, -0.055, -0.002), bevel=0.002, mat=card,
                          name="stuck_card"), at_slot))
    cab.append(placed(box((0.19, 0.012, 0.0055), pos=(0, -0.09, -0.00275), bevel=0, mat=ink,
                          name="stuck_line"), at_slot))
    # A pull lever on the right side and two bolts on the front (a rust run from the lower one).
    cab.append(pipe([(BOX_W / 2 - 0.01, -0.12, cz - 0.02), (BOX_W / 2 + 0.05, -0.13, cz - 0.02),
                     (BOX_W / 2 + 0.07, -0.13, cz - 0.12)], 0.014, verts=12, bend=0.03, mat=steel, name="lever"))
    cab.append(sphere(0.03, pos=(BOX_W / 2 + 0.072, -0.13, cz - 0.13), segments=12, rings=6, mat=ink, name="knob"))
    for bx, bz in ((-0.17, BOX_Z + 0.06), (0.17, BOX_Z + 0.06)):
        cab.append(cyl(0.016, 0.01, verts=12, pos=(bx, yf + 0.002, bz), rot=(90, 0, 0), bevel=0.004, segments=1,
                       mat=steel, name="bolt"))
    cab.append(extrude_profile([(-0.012, 0.0), (0.012, 0.0), (0.01, -0.05), (0.004, -0.09), (-0.004, -0.07),
                                (-0.01, -0.03)], 0.002, pos=(0.17, yf + 0.0012, BOX_Z + 0.045), bevel=0,
                               mat=rust, name="rust_run"))
    cabinet = join(cab, "cab")
    # Hangs crooked: turn the whole cabinet about its wall normal (through its centre).
    cabinet.matrix_world = (Matrix.Translation((0, 0, cz)) @ Matrix.Rotation(math.radians(TILT), 4, 'Y')
                            @ Matrix.Translation((0, 0, -cz)))
    apply_transform(cabinet)
    parts.append(cabinet)

    # Card rack: a steel back with 3 slanted pockets, cards sticking out of them, crooked.
    rack_z0, rack_h, rack_w = BOX_Z - 0.02, 0.62, 0.28
    parts.append(box((rack_w, 0.016, rack_h), pos=(RACK_X, -0.008, rack_z0), bevel=0.006, mat=steel, name="rack"))
    for k in range(3):
        pz = rack_z0 + 0.04 + k * 0.2
        pocket = box((rack_w - 0.02, 0.05, 0.1), pos=(RACK_X, -0.04, pz), bevel=0.008, segments=1, mat=steel,
                     name="pocket")
        parts.append(pocket)
        # Cards in this pocket: overlapping, leaning out, uneven heights.
        for j in range(4 if k != 1 else 3):
            cx = RACK_X - 0.085 + j * 0.055 + (0.01 if k == 2 else 0.0)
            h = 0.19 + 0.02 * math.sin(j * 2.3 + k)
            lean = (Matrix.Translation((cx, -0.044, pz + 0.02)) @ Matrix.Rotation(math.radians(-9 - 2 * (j % 2)), 4, 'X')
                    @ Matrix.Rotation(math.radians(6 * math.sin(j * 1.7 + k * 2.1)), 4, 'Y'))
            parts.append(placed(box((0.07, 0.004, h), bevel=0.001, mat=card, name="card"), lean))
            # A printed stripe near each card's top.
            parts.append(placed(box((0.056, 0.005, 0.012), pos=(0, 0, h - 0.04), bevel=0, mat=ink,
                                    name="card_line"), lean))
    # One card fell on the floor under the rack.
    fallen = box((0.07, 0.19, 0.004), pos=(RACK_X + 0.03, -0.22, 0.0), rot=(0, 0, 23), bevel=0.001, mat=card,
                 name="fallen_card")
    parts.append(fallen)

    # Power cord: out of the cabinet bottom, a sagging loop down the wall into a socket at 0.3 m.
    parts.append(pipe([(-0.12, -0.06, BOX_Z + 0.01), (-0.13, -0.045, BOX_Z - 0.3), (-0.2, -0.035, 0.55),
                       (-0.24, -0.03, 0.32)], 0.012, verts=12, bend=0.08, mat=ink, name="cord"))
    parts.append(extrude_profile(rounded_rect(0.1, 0.13, 0.02), 0.03, pos=(-0.24, 0.0, 0.3), bevel=0.008,
                                 mat=steel, name="socket"))
    parts.append(box((0.05, 0.03, 0.05), pos=(-0.24, -0.04, 0.29), bevel=0.01, mat=ink, name="plug"))

    clock = join(parts, "punch_clock")
    export(clock, "punch_clock", kind="prop", mount="wall")
