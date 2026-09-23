"""ceiling_panel family: the room's corrugated steel roof deck as 5 x 5 m panels (architecture, environment modeler).

Kind "part", mount "ceiling": the origin is on the panel centre at the deck's TOP (the valleys); everything hangs
below z = 0. The ribs' crests (the lowest surface, what you see from the floor) are at z = -0.1, so the room
puts the panels at Godot y = 6.1 and the crests sit exactly on the Ceiling collider's face (y = 6.0), on top
of the steel beams (ceiling_beam, top at y = 6.0). 5.0 x 5.0 m, tiled 4 x 3 (scenes/world/room.tscn,
Ceiling/*, runs via scenes/world/props/segment_run.gd, every other panel turned 180 degrees).

  Deck        16 trapezoidal ribs running along X (they span from beam to beam; the beams run along Godot Z at
              x = -5, 0, 5 and hide the panel seams there). Panel edges along X sit on a crest's middle, so
              the seams at z = +-2.5 are invisible and the wall tops (5.995) tuck under the crests; closure
              plates fill the rib ends at the X edges (they seal the deck against the east / west walls).
  Fixings     a fastener under every crest along both X edges (over the beams' top flanges): a few missing.
  Wear        ceiling_panel: a sagging, dented patch and rust weeping along the ribs;
              ceiling_panel_b: a side-lap seam come loose (one sheet dropped a few cm, dark gap), a damp stain;
              ceiling_panel_hole: the torn hole over Decor/HoleDust (outline shared with hole_rim via _arch.py).
Dark on purpose (STYLE 12: the ceiling stays dim, nothing lights it directly): toon_concrete_dark sheet.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401

S = PANEL / 2
R = DECK_RIB
P = RIB_PITCH
DOWN = (0, 0, -1)
BREAKS = DECK_BREAKS
z_at = deck_z


def crest_centres():
    return [-S + k * P for k in range(N_RIBS + 1)]


class Deck:
    def __init__(self, hole=None, deform=None, cut=None, xs=None, fine=None):
        """hole: polygon (x, y) cut out of the deck; deform(x, y, z, side) -> z; cut: (y, x0, x1): the deck is
        split along the line y (a loose side lap: deform gets side 0 / 1 for the two sides); xs: x stations the
        sheet is cut at (so it can bend); fine: (y0, y1, xs) denser stations for the bands between y0 and y1."""
        self.mb = MB()
        self.M = arch_mats()
        self.hole = hole
        self.deform = deform or (lambda x, y, z, side=0: z)
        self.cut = cut
        self.xs = sorted(xs or [])
        self.fine = fine
        self.flats = []                      # (plan quad, z, side) of the flat crest / valley faces (decals)

    def intervals(self, ya, yb):
        """Deck x-intervals at ya and yb inside the band (the hole's complement), as [(xa0, xa1, xb0, xb1)]."""
        if not self.hole:
            return [(-S, S, -S, S)]
        ym = (ya + yb) / 2
        hits = []
        pts = self.hole
        for p, q in zip(pts, pts[1:] + pts[:1]):
            lo, hi = min(p[1], q[1]), max(p[1], q[1])
            if lo < ym < hi:
                def x_at(y, p=p, q=q):
                    return p[0] + (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1])
                hits.append((x_at(ym), x_at(ya), x_at(yb)))
        hits.sort()
        out = []
        prev = (-S, -S)
        for i in range(0, len(hits) - 1, 2):
            a, b = hits[i], hits[i + 1]
            out.append((prev[0], a[1], prev[1], a[2]))
            prev = (b[1], b[2])
        out.append((prev[0], S, prev[1], S))
        return [iv for iv in out if iv[1] - iv[0] > 1e-5 or iv[3] - iv[2] > 1e-5]

    def sheet(self):
        ys = {y for y, _ in BREAKS}
        if self.hole:
            ys.update(p[1] for p in self.hole if -S < p[1] < S)
        if self.cut:
            ys.add(self.cut[0])
        ys = sorted(ys)
        mat = self.M["concrete_dark"]
        for ya, yb in zip(ys, ys[1:]):
            if yb - ya < 1e-6:
                continue
            za, zb = z_at(ya), z_at(yb)
            side = 0
            if self.cut and ya >= self.cut[0] - 1e-9:
                side = 1
            for xa0, xa1, xb0, xb1 in self.intervals(ya, yb):
                xs = self.xs
                if self.fine and yb > self.fine[0] and ya < self.fine[1]:
                    xs = sorted(set(xs) | set(self.fine[2]))
                inner = [x for x in xs if max(xa0, xb0) + 0.02 < x < min(xa1, xb1) - 0.02]
                col_a = [xa0] + inner + [xa1]
                col_b = [xb0] + inner + [xb1]
                for i in range(len(col_a) - 1):
                    q = [(col_a[i], ya, za), (col_a[i + 1], ya, za), (col_b[i + 1], yb, zb), (col_b[i], yb, zb)]
                    if abs(za - zb) < 1e-9:
                        self.flats.append(([(x, y) for x, y, _ in q], za, side))
                    q = [(x, y, self.deform(x, y, z, side)) for x, y, z in q]
                    self.mb.face(q, mat, DOWN)

    def closures(self):
        """Plates filling the rib ends at the X edges, facing into the panel (seal the deck at the walls)."""
        for x, sgn in ((-S, 1), (S, -1)):
            for (ya, za), (yb, zb) in zip(BREAKS, BREAKS[1:]):
                if za <= -R + 1e-6 and zb <= -R + 1e-6:
                    continue
                self.mb.face([(x, ya, -R), (x, yb, -R), (x, yb, zb), (x, ya, za)], self.M["concrete_dark"], (sgn, 0, 0))

    def decal_on_ribs(self, poly, mat, off=0.003):
        """A stain following the ribs: clipped to every flat crest / valley face of the sheet (not the slopes),
        so it hugs the hole's torn edge and never floats over a gap."""
        us = [p[0] for p in poly]
        vs = [p[1] for p in poly]
        for quad, z, side in self.flats:
            if max(p[0] for p in quad) < min(us) or min(p[0] for p in quad) > max(us) \
                    or max(p[1] for p in quad) < min(vs) or min(p[1] for p in quad) > max(vs):
                continue
            c = clip_convex(poly, quad)
            if c:
                self.mb.face([(u, v, self.deform(u, v, z, side) - off) for u, v in c], self.M[mat], DOWN)

    def obj(self, name):
        return self.mb.obj(name, smooth=30.0)


def fasteners(deform, missing=()):
    """Hex-headed fasteners under the crests along both X edges (over the beams). `missing`: (side, k): an
    empty hole instead (and the sheet round it rusting)."""
    parts = []
    mb = MB()
    M = arch_mats()
    for sx in (-1, 1):
        x = sx * (S - 0.06)
        for k in range(1, N_RIBS, 2):          # every other crest
            y = -S + k * P
            z = deform(x, y, -R, 0)
            if (sx, k) in missing:
                mb.face([(u, v, z - 0.004) for u, v in blob(x, y, 0.045, 0.04, k, n=10, wob=0.2)], M["rust_dim"], DOWN)
                mb.face([(u, v, z - 0.006) for u, v in blob(x, y, 0.016, 0.016, k, n=8, wob=0.05)], M["dark"], DOWN)
                continue
            parts.append(cyl(0.02, 0.014, verts=6, pos=(x, y, z - 0.014), bevel=0, mat="metal_dark", name="fastener"))
    parts.append(mb.obj("fastener_holes"))
    return parts


def sag_a(x, y, z, side=0):
    """A dented, sagging patch between the beams (somebody stored something heavy up there once)."""
    d = math.hypot((x - 0.7) / 1.5, (y + 0.8) / 1.1)
    k = max(0.0, 1 - d * d)
    return z - 0.075 * k * k


def ceiling_a():
    reset()
    deck = Deck(deform=sag_a, fine=(-1.95, 0.35, [-0.8 + i * 0.3 for i in range(11)]))
    deck.sheet()
    deck.closures()
    deck.decal_on_ribs(blob(0.6, -0.7, 0.9, 0.55, 1.3, n=18, wob=0.2), "rust_dim")
    deck.decal_on_ribs(blob(-1.6, 1.4, 0.5, 0.35, 4.0, n=14, wob=0.25), "rust_dim")
    deck.decal_on_ribs(blob(1.5, 1.2, 0.35, 0.9, 2.2, n=14, wob=0.2), "grime")
    parts = [deck.obj("Deck")] + fasteners(sag_a, missing={(1, 3), (1, 5), (-1, 11)})
    export(join(parts, "Deck"), "ceiling_panel", kind="part", mount="ceiling", budget=3500)


LAP_Y = -S + 9 * P + CREST_HALF + RIB_SLOPE + RIB_VALLEY / 2     # a valley line: the loose side lap


def sag_b(x, y, z, side=0):
    """The sheet beyond the side lap has come loose: it drops up to 6 cm towards its middle."""
    if side == 1 and y < LAP_Y + 1.6:
        u = max(0.0, 1 - abs(x + 0.4) / 2.1)
        v = max(0.0, 1 - (y - LAP_Y) / 1.6)
        return z - 0.06 * math.sin(math.pi / 2 * u) ** 1.5 * v
    return z


def ceiling_b():
    reset()
    deck = Deck(deform=sag_b, cut=(LAP_Y, -S, S), fine=(LAP_Y, LAP_Y + 1.6, [-2.5 + i * 0.3 for i in range(17)]))
    deck.sheet()
    deck.closures()
    # the gap under the dropped sheet shows the dark void above
    mb = deck.mb
    for i in range(20):
        x0, x1 = -S + 5.0 * i / 20, -S + 5.0 * (i + 1) / 20
        g0, g1 = sag_b(x0, LAP_Y, 0.0, 1), sag_b(x1, LAP_Y, 0.0, 1)
        if g0 > -0.002 and g1 > -0.002:
            continue
        mb.face([(x0, LAP_Y, 0.0), (x1, LAP_Y, 0.0), (x1, LAP_Y, g1), (x0, LAP_Y, g0)], deck.M["void"], (0, 1, 0))
        mb.face([(x0, LAP_Y, 0.0), (x1, LAP_Y, 0.0), (x1, LAP_Y, g1), (x0, LAP_Y, g0)], deck.M["concrete_dark"], (0, -1, 0))
    deck.decal_on_ribs(blob(-1.2, -1.3, 1.1, 0.8, 2.7, n=18, wob=0.22), "grime")
    deck.decal_on_ribs(blob(-1.1, -1.25, 0.6, 0.45, 5.5, n=16, wob=0.25), "rust_dim", off=0.005)
    deck.decal_on_ribs(blob(1.7, 0.4, 0.4, 0.3, 1.1, n=14, wob=0.25), "rust_dim")
    parts = [deck.obj("Deck")] + fasteners(sag_b, missing={(-1, 5), (-1, 7), (1, 9)})
    export(join(parts, "Deck"), "ceiling_panel_b", kind="part", mount="ceiling", budget=3500)


def ceiling_hole():
    reset()
    hole = hole_outline_in_panel()

    def warp(x, y, z, side=0):
        return z - hole_warp(x, y)          # the sheet round the hole is bent down where it tore (_arch)
    deck = Deck(hole=hole, deform=warp, fine=(0.25, S, [-2.45 + i * 0.25 for i in range(14)]))
    deck.sheet()
    deck.closures()
    # soot / water staining spreading from the hole along the ribs, rust at the torn edges
    deck.decal_on_ribs(blob(-0.95, 1.55, 1.8, 1.25, 0.6, n=20, wob=0.12), "grime")
    deck.decal_on_ribs(blob(-0.95, 1.55, 1.45, 0.98, 2.2, n=20, wob=0.14), "rust_dim", off=0.005)
    parts = [deck.obj("Deck")] + fasteners(warp, missing={(-1, 13), (1, 1), (1, 3)})
    export(join(parts, "Deck"), "ceiling_panel_hole", kind="part", mount="ceiling", budget=3500)


def build():
    ceiling_a()
    ceiling_b()
    ceiling_hole()
