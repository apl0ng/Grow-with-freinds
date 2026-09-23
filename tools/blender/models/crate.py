"""crate: a cheap slatted wooden shipping crate, knocked about (room decor).

Floor mount, 0.9 x 0.9 x 0.9 m: fills the 0.9 m box collider of scenes/world/props/crate.tscn, and the
room stands a sad plant on one (lid top at z = 0.9, flat in the middle) and one on two pallets.
Build: a dark inner box (shows through the slat gaps), 4 corner posts, 4 slats per side, a diagonal
brace on each side face, a 5-plank lid, steel caps on the post ends.
TINT: the third slat all round is a painted band (TINT_band) with "THIS SIDE UP" arrows stencilled on
the front, so every instance can get its own paint colour (Toonify `tint`, see crate.tscn).
Sad: one side slat snapped with its end hanging, a splintered post top, a lid plank lifted at one end,
crooked slats, damp dark bottom boards, a stencil half worn off.
"""
from gwf import *

S = 0.9            # outer size
POST = 0.1         # corner post section
SLAT_T = 0.03      # slat thickness
LID_T = 0.03
Z_LID = S - LID_T  # posts + slats end here, the lid sits on top
SLATS = ((0.03, 0.2), (0.235, 0.405), (0.44, 0.61), (0.645, 0.825))   # (bottom, top) of the 4 slats per side


def side_slat(face, z0, z1, x0=-0.36, x1=0.36, yaw=0.0, roll=0.0, mat=None, name="slat", jag0=None, jag1=None):
    """A slat on one face. face: 0 front (-Y), 1 right (+X), 2 back (+Y), 3 left (-X). x0..x1 run along the
    face (left to right as seen from outside). jag0/jag1: z offsets per point for splintered ends."""
    h = z1 - z0
    pts = []
    if jag0:
        n = len(jag0)
        pts += [(x0 + dx, z0 + h * i / (n - 1)) for i, dx in enumerate(jag0)]
        pts = list(reversed(pts))                  # top -> bottom at the left end
    else:
        pts += [(x0, z1), (x0, z0)]
    if jag1:
        n = len(jag1)
        pts += [(x1 + dx, z0 + h * i / (n - 1)) for i, dx in enumerate(jag1)]
    else:
        pts += [(x1, z0), (x1, z1)]
    # Drawn as seen from the front, back face on y = 0, extruded towards -Y by the slat thickness.
    s = extrude_profile(pts, SLAT_T, pos=(0, 0, 0), bevel=0.008, segments=1, mat=mat, name=name)
    apply_transform(s)
    cz = (z0 + z1) / 2
    # Crooked by a degree or two (roll about the face normal), a hint of yaw.
    s.matrix_world = (Matrix.Translation((0, 0, cz)) @ Matrix.Rotation(math.radians(roll), 4, 'Y')
                      @ Matrix.Rotation(math.radians(yaw), 4, 'Z') @ Matrix.Translation((0, 0, -cz)))
    apply_transform(s)
    # Move onto the face: front 22 mm inside the posts' faces (the braces sit flush with the posts on top).
    out = S / 2 - 0.022
    s.matrix_world = Matrix.Rotation(math.radians(90 * face), 4, 'Z') @ Matrix.Translation((0, -(out - SLAT_T), 0))
    apply_transform(s)
    return s


def build():
    wood = lib("wood")                                     # honey slats + lid
    damp = lib("brown")                                    # bottom slats: damp, darker
    inside = material("crate_inside", "#3a2d26", "matte")  # the dark gaps between slats
    steel = lib("metal_dark")
    band = tint_material("TINT_band")                      # painted band: per-instance colour
    ink = lib("dark")                                      # stencil paint
    parts = []

    # Inner box: only ever seen through the gaps.
    parts.append(box((S - 0.1, S - 0.1, Z_LID - 0.04), pos=(0, 0, 0.02), bevel=0, mat=inside, name="core"))

    # Corner posts. The front-left one lost a splinter off its top corner.
    for i, (sx, sy) in enumerate(((-1, -1), (1, -1), (1, 1), (-1, 1))):
        cx, cy = sx * (S / 2 - POST / 2), sy * (S / 2 - POST / 2)
        if i == 0:
            prof = [(-POST / 2, 0), (POST / 2, 0), (POST / 2, Z_LID - 0.07), (0.02, Z_LID - 0.04),
                    (0.028, Z_LID - 0.015), (-0.005, Z_LID - 0.03), (-POST / 2, Z_LID)]
            p = extrude_profile(prof, POST, pos=(cx, cy + POST / 2, 0), bevel=0.012, segments=2, mat=wood,
                                name="post")
        else:
            p = box((POST, POST, Z_LID), pos=(cx, cy, 0), bevel=0.014, segments=2, mat=wood, name="post")
        parts.append(p)
        # Steel caps on both post ends (corner protectors); the broken post has lost its top one.
        for z0 in ((0.0,) if i == 0 else (0.0, Z_LID - 0.085)):
            parts.append(box((POST + 0.012, POST + 0.012, 0.085), pos=(cx, cy, z0), bevel=0.008, segments=1,
                             mat=steel, name="cap"))

    # Slats: 4 per face. Bottom = damp wood, third = the painted TINT band, the rest plain wood.
    crooked = {(0, 1): (0.0, 1.2), (1, 3): (0.8, -1.0), (2, 0): (0.0, -0.8), (3, 2): (-0.6, 1.5),
               (0, 3): (0.0, -0.6)}
    for face in range(4):
        for k, (z0, z1) in enumerate(SLATS):
            mat = damp if k == 0 else band if k == 2 else wood
            yaw, roll = crooked.get((face, k), (0.0, 0.0))
            if face == 1 and k == 1:
                # Snapped slat on the right face: the front half still nailed, the back half hanging off
                # its back nail, swung down ~16 deg (shows the dark inside).
                parts.append(side_slat(face, z0, z1, x0=-0.36, x1=-0.05, mat=mat, name="slat_a",
                                       jag1=[0.0, 0.035, -0.01, 0.045, 0.015]))
                piece = side_slat(1, z0, z1, x0=0.01, x1=0.36, mat=mat, name="slat_b",
                                  jag0=[0.02, -0.02, 0.03, -0.005, 0.025])
                # Hinge at its back nail (the right face's +x runs towards +Y); it swings about the face normal.
                hinge = Vector((S / 2 - 0.03, 0.33, (z0 + z1) / 2))
                piece.matrix_world = (Matrix.Translation(hinge) @ Matrix.Rotation(math.radians(16), 4, 'X')
                                      @ Matrix.Translation(-hinge))
                apply_transform(piece)
                parts.append(piece)
                continue
            parts.append(side_slat(face, z0, z1, yaw=yaw, roll=roll, mat=mat, name="slat"))

    # Diagonal braces over the slats on the two side faces (flush with the posts).
    for face, flip in ((1, 1), (3, -1)):
        length = math.hypot(S - 2 * POST + 0.02, SLATS[3][1] - SLATS[0][0]) - 0.03
        ang = math.degrees(math.atan2(SLATS[3][1] - SLATS[0][0], S - 2 * POST + 0.02)) * flip
        b = box((length, 0.022, 0.1), pos=(0, 0, -0.05), bevel=0.008, segments=1, mat=wood, name="brace")
        b.matrix_world = Matrix.Translation((0, 0, (SLATS[0][0] + SLATS[3][1]) / 2)) @ Matrix.Rotation(
            math.radians(ang), 4, 'Y')
        apply_transform(b)
        b.matrix_world = Matrix.Rotation(math.radians(90 * face), 4, 'Z') @ Matrix.Translation((0, -(S / 2 - 0.011), 0))
        apply_transform(b)
        parts.append(b)

    # Lid: 5 planks along X. The back plank has sprung its nails at the right end (lifted ~2.5 cm).
    w, gap = 0.17, (S - 5 * 0.17) / 4
    for k in range(5):
        y = -S / 2 + w / 2 + k * (w + gap)
        p = box((S, w, LID_T), pos=(0, y, Z_LID), bevel=0.012, segments=2, mat=wood, name="lid")
        if k == 4:
            hinge = Vector((-0.1, y, Z_LID))
            p.matrix_world = (Matrix.Translation(hinge) @ Matrix.Rotation(math.radians(-2.6), 4, 'Y')
                              @ Matrix.Translation(-hinge) @ Matrix.Translation((0, y, Z_LID)))
            apply_transform(p)
        elif k == 1:
            p.rotation_euler = (0, 0, math.radians(0.8))
        parts.append(p)

    # "THIS SIDE UP": two chunky stencil arrows on the front band (ink, the left one half worn off).
    zb = (SLATS[2][0] + SLATS[2][1]) / 2
    yf = -(S / 2 - 0.022)                             # front face of the front slats
    for i, x in enumerate((-0.14, 0.14)):
        h = 0.12
        arrow = [(0.0, h / 2), (0.05, h / 2 - 0.05), (0.018, h / 2 - 0.05), (0.018, -h / 2),
                 (-0.018, -h / 2), (-0.018, h / 2 - 0.05), (-0.05, h / 2 - 0.05)]
        if i == 0:   # worn: the stem stops short and the head has lost a corner
            arrow = [(0.0, h / 2), (0.05, h / 2 - 0.05), (0.018, h / 2 - 0.05), (0.018, -0.005),
                     (-0.018, 0.012), (-0.018, h / 2 - 0.05), (-0.035, h / 2 - 0.05)]
        a = extrude_profile(arrow, 0.004, pos=(x, yf + 0.001, zb), bevel=0, mat=ink, name="arrow")
        parts.append(a)
    # A stencilled lot number "13" on the top front slat (stencil bars with the usual gaps).
    zc = (SLATS[3][0] + SLATS[3][1]) / 2
    bars = [(-0.1, -0.055, -0.078, 0.055), (-0.122, 0.03, -0.1, 0.055),                  # 1 + its flag
            (-0.03, 0.043, 0.035, 0.065), (-0.012, -0.011, 0.035, 0.011), (-0.03, -0.065, 0.035, -0.043),
            (0.045, 0.004, 0.067, 0.058), (0.045, -0.058, 0.067, -0.004)]                 # 3: bars + split spine
    for x0, z0, x1, z1 in bars:
        parts.append(extrude_profile([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], 0.004,
                                     pos=(0.05, yf + 0.001, zc), bevel=0, mat=ink, name="stencil"))

    crate = join(parts, "crate")
    export(crate, "crate", kind="prop", mount="floor")
