"""hole_rim: the torn edge of the hole in the roof deck (architecture, environment modeler).

Kind "part", mount "ceiling": the origin is the hole's centre at the deck's top (valley) level, like
ceiling_panel, so scenes/world/room.tscn puts it at (-3.5, 6.1, 3.2): right over Ceiling/HoleVoid (the black
inside-out box), Lights/HoleDustLight and Decor/HoleDust, which all stay Godot nodes. The hole's outline is
_arch.HOLE_OUTLINE, the same polygon ceiling_panel_hole is cut with, so the lip hangs exactly off the cut edge
(following the deck ribs and the sheet's bend round the hole, _arch.hole_warp).

  Lip         a jagged lip of torn sheet all round, bent down 20-60 degrees into the hole, deck grey underneath,
              rusty on top (the side nobody ever painted). Its north side runs along a panel seam: the lip
              there hides the straight edge.
  Flaps       two big torn pieces of corrugated sheet hanging off the south and east edges, and a slab of olive
              insulation board dangling off the west edge by a corner.
  Junk        a snapped steel angle sticking out into the hole, bent down; two cables hanging out of the dark
              (one taped off with caution tape, one frayed).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401

OX, OY = HOLE_OFFSET                  # hole-local -> hole panel coords (x + OX, y + OY)


def sheet_z(x, y):
    """Deck sheet height (hole-local coords) at the torn edge: the rib profile, bent down round the hole."""
    return deck_z(y + OY) - hole_warp(x + OX, y + OY)


def densify(outline):
    """The outline with extra points where it crosses the deck profile's corners (so the lip follows the ribs
    exactly like the cut deck edge does) and every <= 0.12 m along the edges (teeth)."""
    breaks = [y - OY for y, _ in DECK_BREAKS]
    out = []
    for p, q in zip(outline, outline[1:] + outline[:1]):
        ts = {0.0}
        if abs(q[1] - p[1]) > 1e-9:
            for yb in breaks:
                t = (yb - p[1]) / (q[1] - p[1])
                if 1e-6 < t < 1 - 1e-6:
                    ts.add(t)
        ln = math.hypot(q[0] - p[0], q[1] - p[1])
        n = int(ln / 0.12)
        ts.update(i / (n + 1) for i in range(1, n + 1))
        for t in sorted(ts):
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def lip(mb, M, pts, rng):
    """A band hanging off the edge into the hole with a saw-tooth free edge; both sides."""
    n = len(pts)
    cx = sum(p[0] for p in pts) / n
    cy = sum(p[1] for p in pts) / n
    outer, inner = [], []
    for i, (x, y) in enumerate(pts):
        a, b = pts[i - 1], pts[(i + 1) % n]
        tx, ty = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(tx, ty) or 1.0
        nx, ny = -ty / ln, tx / ln                     # left normal: inwards for a CCW outline
        if nx * (cx - x) + ny * (cy - y) < 0:
            nx, ny = -nx, -ny
        z = sheet_z(x, y)
        tooth = 1.0 if i % 3 == 0 else (0.45 if i % 3 == 1 else 0.7)
        w = (0.05 + 0.13 * rng.random()) * tooth + 0.02
        drop = w * (0.35 + 0.9 * rng.random())
        outer.append(Vector((x, y, z)))
        inner.append(Vector((x + nx * w, y + ny * w, z - drop)))
    for i in range(n):
        j = (i + 1) % n
        quad = [outer[i], outer[j], inner[j], inner[i]]
        mb.face(quad, M["concrete_dark"], (0, 0, -1))
        mb.face(list(reversed(quad)), M["rust"], (0, 0, 1))


def flap(mb, M, a, b, inward, length, bends, ribs=0, mat_under="concrete_dark", mat_top="rust", twist=0.0,
         jag=0.08, seed=0.0, nu=6):
    """A torn piece of sheet hinged on the edge a-b, hanging into the hole. bends: list of (fraction of the
    length, angle down in degrees) along its length; ribs: corrugations across it; twist: extra drop (m) at
    the b end. Double-sided (grey under, rusty on top), jagged free end."""
    a, b, inward = Vector(a), Vector(b), Vector(inward).normalized()
    down = Vector((0, 0, -1))
    along = (b - a)
    rows = []
    nv = len(bends)
    for i in range(nu + 1):
        u = i / nu
        base = a + along * u
        p = base.copy()
        row = [p.copy()]
        for k, (frac, ang) in enumerate(bends):
            seg = length * frac
            if k == nv - 1:
                seg *= 1.0 + jag * math.sin(seed + 7.3 * u) + jag * (0.8 if i % 2 else -0.6)
            r = math.radians(ang)
            p = p + (inward * math.cos(r) + down * math.sin(r)) * seg + down * twist * u * frac
            if ribs:
                p = p + down * 0.035 * math.sin(math.pi * 2 * ribs * u) * (k + 1) / nv
            row.append(p.copy())
        rows.append(row)
    for i in range(nu):
        for k in range(nv):
            quad = [rows[i][k], rows[i + 1][k], rows[i + 1][k + 1], rows[i][k + 1]]
            mb.face(quad, M[mat_under], (0, 0, -1))
            mb.face(list(reversed(quad)), M[mat_top], (0, 0, 1))


def edge_point(outline, t):
    """Point at fraction t along the outline's perimeter."""
    segs = list(zip(outline, outline[1:] + outline[:1]))
    lens = [math.hypot(q[0] - p[0], q[1] - p[1]) for p, q in segs]
    s = t * sum(lens)
    for (p, q), ln in zip(segs, lens):
        if s <= ln:
            u = s / ln
            return (p[0] + (q[0] - p[0]) * u, p[1] + (q[1] - p[1]) * u)
        s -= ln
    return outline[0]


def build():
    rng = random.Random(7)
    M = arch_mats()
    mb = MB()
    pts = densify(HOLE_OUTLINE)
    lip(mb, M, pts, rng)

    def at(x, y):
        return (x, y, sheet_z(x, y) - 0.005)
    # big torn flaps: south edge (a corrugated piece hanging steeply), east edge (smaller, twisted)
    flap(mb, M, at(-0.35, -0.82), at(0.3, -0.86), (0.1, 1, 0), 0.62, [(0.35, 30), (0.65, 68)], ribs=1.5,
         twist=0.08, seed=1.0)
    flap(mb, M, at(1.12, -0.25), at(1.14, 0.3), (-1, 0.05, 0), 0.42, [(0.5, 40), (0.5, 75)], ribs=1, twist=-0.1,
         seed=2.2, nu=5)
    flap(mb, M, at(-0.9, 0.7), at(-0.35, 0.7), (0, -1, 0), 0.3, [(0.5, 25), (0.5, 55)], ribs=0, seed=3.3, nu=5)
    rim = mb.obj("Rim", smooth=30.0)
    parts = [rim]

    # olive insulation board hanging off the west edge by one corner (the old FlapC)
    board = box((0.62, 0.42, 0.05), pos=(0, 0, 0), bevel=0.012, mat="olive", name="insulation")
    subdivide(board, 3)
    jitter(board, 0.01, seed=4)
    board.location = (0, 0, 0)
    apply_transform(board)
    board.rotation_euler = (math.radians(58), math.radians(-18), math.radians(12))
    board.location = (-0.98, 0.05, sheet_z(-1.15, 0.05) - 0.3)
    parts.append(board)
    # frayed foam edge of the board: a few cream tufts
    for i, (dx, dy) in enumerate(((-0.25, 0.1), (0.05, 0.14), (0.22, 0.06))):
        tuft = sphere(0.045, pos=(0, 0, 0), scale=(1.3, 1.0, 0.7), segments=8, rings=4, mat="cream", name="tuft")
        tuft.location = (-0.98 + dx * 0.9, 0.05 + dy * 0.5, sheet_z(-1.15, 0.05) - 0.05 - 0.1 * i)
        parts.append(tuft)

    # snapped steel angle (a purlin) sticking out of the west edge, bent down
    ang = []
    base = Vector((-1.35, -0.35, sheet_z(-1.2, -0.35) - 0.03))
    path = [base, base + Vector((0.45, 0.02, -0.03)), base + Vector((0.75, 0.05, -0.2))]
    for p, q in zip(path, path[1:]):
        d = q - p
        ln = d.length
        leg1 = box((ln, 0.06, 0.008), pos=(0, 0, 0), bevel=0.002, mat="metal_dark", name="angle")
        leg2 = box((ln, 0.008, 0.06), pos=(0, -0.026, 0), bevel=0.002, mat="metal_dark", name="angle")
        for o in (leg1, leg2):
            o.location = (0, 0, 0)
        piece = join([leg1, leg2], "angle_piece")
        yaw = math.atan2(d.y, d.x)
        pitch = -math.asin(d.z / ln)
        piece.rotation_euler = (0, pitch, yaw)
        piece.location = (p + q) / 2 - Vector((0, 0, 0.03))
        ang.append(piece)
    set_material(ang[-1], "rust")                     # the bent-off end is all rust
    parts += ang

    # cables hanging out of the dark: one looped and taped off, one frayed
    c1 = [(0.25, -0.2, 0.0), (0.22, -0.25, -0.5), (0.05, -0.32, -1.05), (-0.15, -0.3, -1.3), (-0.2, -0.22, -1.1),
          (-0.12, -0.18, -0.85), (-0.3, -0.25, -1.55), (-0.38, -0.3, -1.8)]
    parts.append(pipe(c1, 0.02, verts=8, bend=0.12, mat="dark", name="cable"))
    parts.append(cyl(0.028, 0.09, verts=10, pos=(-0.39, -0.3, -1.9), rot=(8, 0, 0), bevel=0.006, mat="caution",
                     name="cable_tape"))
    c2 = sag_points((0.62, 0.18, 0.0), (0.7, 0.05, -0.95), sag=-0.12, n=7)
    parts.append(pipe(c2, 0.013, verts=6, bend=0.08, mat="dark", name="cable_thin"))
    for i, (dx, dz) in enumerate(((0.03, -0.06), (-0.025, -0.05), (0.0, -0.08))):
        parts.append(pipe([(0.7, 0.05, -0.94), (0.7 + dx, 0.05 + dx * 0.5, -0.94 + dz)], 0.004, verts=4,
                          mat="gold", name="strand"))
    export(join(parts, "Rim"), "hole_rim", kind="part", mount="ceiling", budget=3000)
