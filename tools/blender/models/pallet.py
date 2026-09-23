"""pallet: a worn wooden block pallet with broken and missing deck boards (room decor).

Floor mount, 1.2 x 0.15 x 1.0 m (the ISO 1200 x 1000 block pallet): fills the collider of
scenes/world/props/pallet.tscn exactly, and the room stacks two of them (the second at y 0.15) with a
0.9 m crate on top, so the height stays 0.15 and the deck stays flat enough to carry the crate.
Build: 3 bottom boards, 9 blocks, 3 stringer boards, 5 deck boards (x along the 1.2 m length).
Sad: one deck board snapped between two stringers with its loose end sagging, one ripped off (a short
stub is still nailed down), a chipped corner, one board replaced with fresher wood, an oil stain,
a knocked block. Front (Blender -Y) is one of the 1.2 m sides; the pallet reads the same all round.
"""
from gwf import *

L, D, H = 1.2, 1.0, 0.15          # length (x), depth (y), height (z)
BOT_T, BLOCK_H, STR_T = 0.022, 0.078, 0.022
DECK_T = H - BOT_T - BLOCK_H - STR_T   # 0.028
Z_BLOCK = BOT_T
Z_STR = BOT_T + BLOCK_H
Z_DECK = Z_STR + STR_T
XS = (-0.535, 0.0, 0.535)          # block / stringer columns
YS = (-0.435, 0.0, 0.435)          # block / bottom-board rows
DECK_W = 0.15
DECK_Y = (-0.425, -0.2125, 0.0, 0.2125, 0.425)


def plan_board(x0, x1, y, w, z, t, jag0=None, jag1=None, mat=None, name="board", bevel=0.007):
    """A flat board seen from above: x0..x1 along X, centred on y, width w, bottom at z, thickness t.
    jag0/jag1: lists of x offsets for a splintered end (instead of a square cut) at x0 / x1."""
    pts = []
    if jag0:
        n = len(jag0)
        for i, dx in enumerate(jag0):           # from +y side down to -y side at the x0 end
            pts.append((x0 + dx, w / 2 - w * i / (n - 1)))
    else:
        pts += [(x0, w / 2), (x0, -w / 2)]
    if jag1:
        n = len(jag1)
        for i, dx in enumerate(jag1):           # from -y side up to +y side at the x1 end
            pts.append((x1 + dx, -w / 2 + w * i / (n - 1)))
    else:
        pts += [(x1, -w / 2), (x1, w / 2)]
    # extrude_profile draws (u, v) in the XZ plane and extrudes to -Y; turned -90 deg about X the (u, v)
    # plane becomes the floor plan (x, y) and the extrusion goes up +Z by `t`.
    b = extrude_profile(pts, t, pos=(0, 0, 0), rot=(-90, 0, 0), bevel=bevel, segments=1, mat=mat, name=name)
    apply_transform(b)
    b.location = (0, y, z)
    return b


def build():
    deck = lib("brown")                                  # tired cocoa boards
    frame = material("wood_dark", pal("SOIL"), "matte")  # blocks + stringers: darker than the deck, damp
    fresh = lib("wood")                                  # one replaced board (a cheap patch job)
    grime = lib("concrete_dark")
    parts = []

    # Bottom boards (along x) and the 3 x 3 blocks; one block knocked askew, one a bit squashed.
    for i, y in enumerate(YS):
        parts.append(box((L - 0.004, 0.13, BOT_T), pos=(0.0, y, 0.0), rot=(0, 0, (-0.6, 0.4, 0.8)[i]),
                         bevel=0.006, segments=1, mat=frame, name="bottom"))
    for ix, x in enumerate(XS):
        for iy, y in enumerate(YS):
            yaw = 9.0 if (ix, iy) == (2, 0) else (ix * 3 + iy) % 3 - 1.0
            w = 0.13 if iy != 1 else 0.145
            parts.append(box((w, 0.13, BLOCK_H), pos=(x, y, Z_BLOCK), rot=(0, 0, yaw), bevel=0.012, segments=2,
                             mat=frame, name="block"))
    # Stringer boards (along y) on top of the blocks.
    for i, x in enumerate(XS):
        parts.append(box((0.13, D - 0.004, STR_T), pos=(x, 0.0, Z_STR), rot=(0, 0, (0.5, -0.7, 0.3)[i]),
                         bevel=0.006, segments=1, mat=frame, name="stringer"))

    # Deck boards. 0: front, full but with a chipped front-right corner.
    parts.append(plan_board(-0.6, 0.6, DECK_Y[0], DECK_W, Z_DECK, DECK_T, jag1=[-0.07, -0.035, -0.06, 0.0, 0.0],
                            mat=deck, name="deck0"))
    # 1: snapped between the middle and right stringers; the loose piece sags onto its nail at x 0.535.
    parts.append(plan_board(-0.6, 0.235, DECK_Y[1], DECK_W, Z_DECK, DECK_T,
                            jag1=[0.0, 0.03, -0.015, 0.035, 0.005], mat=deck, name="deck1a"))
    loose = plan_board(0.285, 0.6, 0.0, DECK_W, 0.0, DECK_T, jag0=[0.03, -0.01, 0.025, -0.015, 0.02],
                       mat=deck, name="deck1b")
    loose.location = (0, 0, 0)
    # Hinge at its far end (x 0.6, deck bottom): tip down ~5 deg, so the free end drops ~2.8 cm onto nothing
    # and the nailed end sinks a few mm into the stringer (hidden), keeping the deck top at 0.15.
    hinge = Vector((0.6, DECK_Y[1], Z_DECK))
    loose.matrix_world = (Matrix.Translation(hinge) @ Matrix.Rotation(math.radians(-5.0), 4, 'Y')
                          @ Matrix.Rotation(math.radians(3.0), 4, 'Z') @ Matrix.Translation(-hinge)
                          @ Matrix.Translation((0, DECK_Y[1], Z_DECK)))
    apply_transform(loose)
    parts.append(loose)
    # 2: the replaced board, fresher wood, a touch crooked.
    parts.append(plan_board(-0.59, 0.6, DECK_Y[2], DECK_W - 0.01, Z_DECK, DECK_T, mat=fresh, name="deck2"))
    parts[-1].rotation_euler = (0, 0, math.radians(1.2))
    # 3: ripped off; only a splintered stub on the left stringer is left.
    parts.append(plan_board(-0.6, -0.43, DECK_Y[3], DECK_W, Z_DECK, DECK_T, jag1=[0.0, 0.04, 0.01, 0.05, 0.02],
                            mat=deck, name="deck3"))
    # 4: back board, full, split at its left end.
    parts.append(plan_board(-0.6, 0.6, DECK_Y[4], DECK_W, Z_DECK, DECK_T, jag0=[0.0, 0.0, 0.05, 0.02, 0.06],
                            mat=deck, name="deck4"))

    # Oil stain: flat blotches lying on the deck boards (clipped to each board so nothing floats over a gap).
    def blotch(cx, y, rx, ry, seed):
        pts = []
        for k in range(12):
            a = 2 * math.pi * k / 12
            r = 1.0 + 0.18 * math.sin(3 * a + seed) + 0.1 * math.sin(5 * a + 2 * seed)
            pts.append((cx + rx * r * math.cos(a), max(-DECK_W / 2 + 0.012, min(DECK_W / 2 - 0.012, ry * r * math.sin(a)))))
        b = extrude_profile(pts, 0.002, rot=(-90, 0, 0), bevel=0, mat=grime, name="stain")
        apply_transform(b)
        b.location = (0, y, Z_DECK + DECK_T + 0.0005)
        return b
    parts.append(blotch(-0.18, DECK_Y[2], 0.2, 0.09, 0.4))
    parts.append(blotch(-0.1, DECK_Y[0], 0.13, 0.08, 1.7))
    parts.append(blotch(0.33, DECK_Y[4], 0.09, 0.07, 2.9))

    pallet = join(parts, "pallet")
    export(pallet, "pallet", kind="prop", mount="floor")
