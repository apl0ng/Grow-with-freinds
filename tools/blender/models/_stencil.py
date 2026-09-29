"""_stencil.py: shared bits for the M10 props (fuse_box, backroom_door, clipboard): chunky stencil lettering
for plates and tags, rounded rectangles, colour mixing, matrix placement. Not a model script (build.py skips
files starting with "_"); model scripts do `from _stencil import *` after `from gwf import *`.

Letters are unions of a few fat bars, like an industrial spray stencil: every bar is one extruded quad
(12 tris, no bevel), so a word costs ~20-35 bars. Cell = 1 x 1; a letter of `height` metres is
height * WIDTH wide, letters are GAP cells apart. Readable at 6 m from ~7 cm tall.
"""
from gwf import *

T = 0.26        # stroke thickness (cell units)
WIDTH = 0.72    # cell width / height
GAP = 0.3       # space between letters (cells)
SPACE = 0.55    # width of a blank (cells)


def _bar(x0, y0, x1, y1):
    return [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]


def _diag(ax, ay, bx, by, t=T):
    """A stroke of thickness t from (ax, ay) to (bx, by): a parallelogram with square ends."""
    dx, dy = bx - ax, by - ay
    n = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / n * t / 2, dx / n * t / 2
    return [(ax + nx, ay + ny), (bx + nx, by + ny), (bx - nx, by - ny), (ax - nx, ay - ny)]


H = T / 2
FONT = {
    "A": [_diag(H, 0.0, 0.5, 1 - H), _diag(1 - H, 0.0, 0.5, 1 - H), _bar(0.22, 0.28, 0.78, 0.28 + T)],
    "B": [_bar(0, 0, T, 1), _bar(0, 1 - T, 0.82, 1), _bar(0.82 - T, 0.5, 0.82, 1), _bar(0, 0.5 - H, 0.9, 0.5 + H),
          _bar(1 - T, 0, 1, 0.5), _bar(0, 0, 1, T)],
    "C": [_bar(0, 0, T, 1), _bar(0, 1 - T, 1, 1), _bar(0, 0, 1, T)],
    "D": [_bar(0, 0, T, 1), _bar(0, 1 - T, 0.8, 1), _bar(0, 0, 0.8, T), _bar(1 - T, 0.15, 1, 0.85),
          _diag(0.8 - H, 1 - H, 1 - H, 0.85), _diag(0.8 - H, H, 1 - H, 0.15)],
    "E": [_bar(0, 0, T, 1), _bar(0, 1 - T, 1, 1), _bar(0, 0.5 - H, 0.85, 0.5 + H), _bar(0, 0, 1, T)],
    "F": [_bar(0, 0, T, 1), _bar(0, 1 - T, 1, 1), _bar(0, 0.5 - H, 0.85, 0.5 + H)],
    "I": [_bar(0.5 - H, 0, 0.5 + H, 1), _bar(0.15, 1 - T, 0.85, 1), _bar(0.15, 0, 0.85, T)],
    "K": [_bar(0, 0, T, 1), _diag(H, 0.5, 1 - H, 1 - H), _diag(H, 0.5, 1 - H, H)],
    "L": [_bar(0, 0, T, 1), _bar(0, 0, 1, T)],
    "N": [_bar(0, 0, T, 1), _bar(1 - T, 0, 1, 1), _diag(H, 1 - H, 1 - H, H)],
    "O": [_bar(0, 0, T, 1), _bar(1 - T, 0, 1, 1), _bar(0, 1 - T, 1, 1), _bar(0, 0, 1, T)],
    "P": [_bar(0, 0, T, 1), _bar(0, 1 - T, 1, 1), _bar(1 - T, 0.45, 1, 1), _bar(0, 0.45, 1, 0.45 + T)],
    "R": [_bar(0, 0, T, 1), _bar(0, 1 - T, 0.9, 1), _bar(0.9 - T, 0.5, 0.9, 1), _bar(0, 0.5 - H, 0.9, 0.5 + H),
          _diag(0.55, 0.5, 1 - H, H)],
    "S": [_bar(0, 1 - T, 1, 1), _bar(0, 0.5, T, 1), _bar(0, 0.5 - H, 1, 0.5 + H), _bar(1 - T, 0, 1, 0.5),
          _bar(0, 0, 1, T)],
    "T": [_bar(0, 1 - T, 1, 1), _bar(0.5 - H, 0, 0.5 + H, 1)],
    "U": [_bar(0, 0, T, 1), _bar(1 - T, 0, 1, 1), _bar(0, 0, 1, T)],
    "Y": [_diag(H, 1 - H, 0.5, 0.5), _diag(1 - H, 1 - H, 0.5, 0.5), _bar(0.5 - H, 0, 0.5 + H, 0.55)],
    "0": [_bar(0, 0, T, 1), _bar(1 - T, 0, 1, 1), _bar(0, 1 - T, 1, 1), _bar(0, 0, 1, T), _diag(H, H, 1 - H, 1 - H)],
    "-": [_bar(0.1, 0.5 - H, 0.9, 0.5 + H)],
    " ": [],
}


def text_width(text, height):
    """Width in metres of `text` set at `height` (for sizing plates)."""
    cell = height * WIDTH
    w = 0.0
    for i, ch in enumerate(text):
        w += cell * (SPACE if ch == " " else 1.0)
        if i < len(text) - 1:
            w += cell * GAP
    return w


def stencil(text, height, pos=(0, 0, 0), depth=0.004, mat=None, name="stencil"):
    """Bars of `text` on the front (-Y) side: back face on the plane y = pos.y, front at pos.y - depth,
    centred on pos.x, baseline at pos.z, `height` metres tall. Returns the list of bar objects (join them
    into the plate). Unknown characters raise."""
    cell = height * WIDTH
    x = pos[0] - text_width(text, height) / 2
    out = []
    for ch in text.upper():
        if ch not in FONT:
            raise ValueError("stencil: no glyph for %r" % ch)
        for poly in FONT[ch]:
            pts = [(x + u * cell, pos[2] + v * height) for u, v in poly]
            out.append(extrude_profile(pts, depth, pos=(0, pos[1], 0), bevel=0, mat=mat, name=name))
        x += cell * ((SPACE if ch == " " else 1.0) + GAP)
    return out


def rounded_rect(w, h, r, n=4, cx=0.0, cy=0.0):
    """Corner-rounded rectangle (w x h, corner radius r) centred on (cx, cy), for extrude_profile()."""
    pts = []
    for qx, qy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180),
                       (w / 2 - r, -h / 2 + r, 270)):
        for k in range(n + 1):
            a = math.radians(a0 + 90 * k / n)
            pts.append((cx + qx + r * math.cos(a), cy + qy + r * math.sin(a)))
    return pts


def mix(a, b, t):
    """Hex colour between a and b (t = 0 -> a, 1 -> b)."""
    ca = [int(a.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    cb = [int(b.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join("%02x" % round(x + (y - x) * t) for x, y in zip(ca, cb))


def placed(obj, m):
    """Bake the world matrix `m` into obj (built around the world origin) and return it. To keep the
    builder's own `pos`/`rot`, pass `m @ obj.matrix_basis` (never matrix_world: stale on fresh objects)."""
    obj.matrix_basis = m
    apply_transform(obj)
    return obj


def roll(objs, pivot, deg, axis='Y'):
    """Turn already-placed (unparented) objects about a world-space axis through `pivot` (degrees), baked.
    A crooked hang: axis 'Y' = about the wall normal for wall props. Uses matrix_basis: a fresh object's
    matrix_world is stale (identity) until the depsgraph runs."""
    p = Vector(pivot)
    m = Matrix.Translation(p) @ Matrix.Rotation(math.radians(deg), 4, axis) @ Matrix.Translation(-p)
    for o in objs:
        o.matrix_basis = m @ o.matrix_basis
        apply_transform(o)
    return objs


def local(obj, world):
    """A world-space point in obj's local coordinates (for dent()/paint() on builder parts, whose mesh is
    centred on their `pos`)."""
    return obj.matrix_world.inverted() @ Vector(world)
