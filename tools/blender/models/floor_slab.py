"""floor_slab family: the room's poured concrete floor as 5 x 5 m slabs (architecture, environment modeler).

Kind "part", mount "free": the origin is the slab centre ON THE FLOOR PLANE, the top surface is Blender z = 0
(Godot y = 0, the Floor collider's top face), the joints dip 2 cm below it and flat decals sit 2 mm above it
(stains, cracks: flat faces, never bridging a joint). 5.0 x 5.0 m, tiled 4 x 3 to cover the 20 x 15 m room
(scenes/world/room.tscn, Floor/*, runs via scenes/world/props/segment_run.gd; runs flip every other slab
180 degrees for variety, so the edges are symmetric).

  Joints      each slab edge is half an expansion joint: a 2 cm chamfer down to dark sealant; two slabs side by
              side make one 5 cm joint. A saw-cut control joint crosses the middle (2.5 m bays).
  Stains      oil (dark core, grey halo) and dried water tide marks: flat, a step darker than the concrete.
  Wear        cracks running in from the edges, spalled joint edges, forklift tyre scuffs (floor_slab_b).
  Drain       floor_slab_drain: a sunken steel grate over a black sump in the middle, a rust ring and a wet
              stain round it (the room puts it between the Well and the spawn).
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401

S = PANEL / 2                         # 2.5
JG = 0.012                            # half the sealant strip at the edge
JC = 0.02                             # edge chamfer (horizontal)
JD = 0.02                             # joint depth
T0 = S - JG - JC                      # the flat top runs -T0..T0
UP = (0, 0, 1)
L0, L1, L2 = 0.0015, 0.003, 0.0045    # decal layers above the top


class Slab:
    def __init__(self, seed, hole=None):
        self.mb = MB()
        self.M = arch_mats()
        self.rng = random.Random(seed)
        self.hole = hole                      # (x0, x1, y0, y1) opening in the top (drain)

    def top(self):
        """Flat top (minus the drain opening), edge chamfers, sealant strips."""
        mb, M = self.mb, self.M
        rects = [(-T0, T0, -T0, T0)]
        if self.hole:
            hx0, hx1, hy0, hy1 = self.hole
            rects = [(-T0, T0, -T0, hy0), (-T0, T0, hy1, T0), (-T0, hx0, hy0, hy1), (hx1, T0, hy0, hy1)]
        for x0, x1, y0, y1 in rects:
            mb.face([(x0, y0, 0), (x1, y0, 0), (x1, y1, 0), (x0, y1, 0)], M["concrete"], UP)
        # chamfers + sealant, 4 sides (corner mitres)
        for r in range(4):
            def rot(p, r=r):
                x, y, z = p
                for _ in range(r):
                    x, y = -y, x
                return (x, y, z)
            a = [(-T0, -T0, 0), (T0, -T0, 0), (S - JG, -(S - JG), -JD), (-(S - JG), -(S - JG), -JD)]
            mb.face([rot(p) for p in a], M["concrete"], rot((0, -1, 1)))
            b = [(-(S - JG), -(S - JG), -JD), (S - JG, -(S - JG), -JD), (S, -S, -JD), (-S, -S, -JD)]
            mb.face([rot(p) for p in b], M["concrete_dark"], UP)

    def decal(self, poly, mat, layer=L0, bounds=None):
        x0, x1, y0, y1 = bounds or (-T0, T0, -T0, T0)
        regions = [(x0, x1, y0, y1)]
        if self.hole:
            hx0, hx1, hy0, hy1 = self.hole
            regions = [(x0, x1, y0, hy0), (x0, x1, hy1, y1), (x0, hx0, hy0, hy1), (hx1, x1, hy0, hy1)]
        for r in regions:
            c = clip_rect(poly, *r)
            if c:
                self.mb.face([(u, v, layer) for u, v in c], self.M[mat], UP)

    def saw_cuts(self):
        w = 0.011
        for poly in ([(-T0, -w), (T0, -w), (T0, w), (-T0, w)], [(-w, -T0), (w, -T0), (w, T0), (-w, T0)]):
            self.decal(poly, "concrete_dark", L0)

    def oil(self, x, y, r, seed):
        self.decal(blob(x, y, r * 1.35, r * 1.1, seed, n=16, wob=0.18), "stain", L0)
        self.decal(blob(x + r * 0.1, y - r * 0.05, r, r * 0.8, seed + 1.3, n=16, wob=0.2), "oil", L1)
        # a drip-trail of smaller spots
        for i in range(3):
            a = seed * 1.7 + i * 0.9
            self.decal(blob(x + math.cos(a) * r * (1.5 + 0.4 * i), y + math.sin(a) * r * (1.4 + 0.3 * i),
                            r * (0.22 - 0.05 * i), r * (0.18 - 0.04 * i), seed + i, n=10), "oil", L1)

    def tide(self, x, y, rx, ry, seed):
        """A dried puddle: a faint patch with a darker tide-mark ring."""
        self.decal(blob(x, y, rx, ry, seed, n=18, wob=0.12), "stain", L0)
        self.decal(blob(x, y, rx * 0.86, ry * 0.84, seed, n=18, wob=0.12), "concrete", L1)

    def crack(self, pts, w=0.018):
        for q in crack_quads(pts, w):
            self.decal(q, "dark", L2)

    def spall(self, x, y, rx, ry, seed):
        """A chipped patch along a joint edge (clipped to the slab top)."""
        self.decal(blob(x, y, rx, ry, seed, n=12, wob=0.3), "concrete_dark", L1)

    def tyre(self, pts, w=0.13):
        """Forklift tyre scuff: a long faint band along a curve (two of them, 0.9 m apart)."""
        for off in (-0.45, 0.45):
            left, right = [], []
            for i, (x, y) in enumerate(pts):
                j = min(i + 1, len(pts) - 1)
                k = max(i - 1, 0)
                dx, dy = pts[j][0] - pts[k][0], pts[j][1] - pts[k][1]
                ln = math.hypot(dx, dy) or 1.0
                nx, ny = -dy / ln, dx / ln
                ww = w * (0.35 + 0.65 * math.sin(math.pi * i / (len(pts) - 1)))
                cx, cy = x + nx * off, y + ny * off
                left.append((cx - nx * ww / 2, cy - ny * ww / 2))
                right.append((cx + nx * ww / 2, cy + ny * ww / 2))
            for i in range(len(pts) - 1):
                self.decal([left[i], left[i + 1], right[i + 1], right[i]], "grime", L0)

    def obj(self, name):
        return self.mb.obj(name, smooth=30.0)


def floor_a():
    reset()
    s = Slab(seed=5)
    s.top()
    s.saw_cuts()
    s.oil(1.2, -0.9, 0.34, 0.8)
    s.oil(-1.6, 1.55, 0.2, 2.6)
    s.tide(-0.9, -1.3, 0.75, 0.5, 1.1)
    s.crack(zigzag(-T0, 0.62, -1.3, 1.02, 6, 0.05, 0.4))
    s.crack(zigzag(-1.3, 1.02, -0.75, 1.5, 4, 0.04, 2.0), 0.013)
    s.crack(zigzag(0.9, T0, 1.55, 1.7, 5, 0.05, 3.1))
    s.spall(T0 - 0.02, -1.95, 0.14, 0.07, 1.0)
    s.spall(-0.6, -T0 + 0.02, 0.1, 0.05, 2.0)
    export(s.obj("Slab"), "floor_slab", kind="part", mount="free", budget=2500)


def floor_b():
    reset()
    s = Slab(seed=9)
    s.top()
    s.saw_cuts()
    s.tyre([(-T0, -1.8), (-1.5, -1.2), (-0.4, -0.35), (0.7, 0.2), (1.8, 0.45), (T0, 0.5)])
    s.oil(-1.3, 1.1, 0.28, 4.2)
    s.tide(1.45, 1.35, 0.55, 0.7, 3.3)
    s.crack(zigzag(0.4, -T0, 0.05, -1.35, 5, 0.05, 1.3))
    s.crack(zigzag(0.05, -1.35, -0.6, -0.95, 4, 0.04, 5.0), 0.013)
    s.crack(zigzag(T0, -0.95, 1.7, -1.3, 4, 0.04, 2.6), 0.014)
    s.spall(-T0 + 0.02, 0.3, 0.12, 0.06, 3.0)
    s.spall(1.1, T0 - 0.02, 0.16, 0.06, 4.0)
    export(s.obj("Slab"), "floor_slab_b", kind="part", mount="free", budget=2500)


def floor_drain():
    reset()
    G = 0.34                               # half the grate opening
    s = Slab(seed=13, hole=(-G, G, -G, G))
    s.top()
    s.saw_cuts()
    # the floor is wet round the drain: dark stain, rust ring, a tide mark further out
    s.tide(0.25, -0.1, 1.45, 1.2, 0.9)
    s.decal(blob(0.05, 0.0, 0.8, 0.72, 2.2, n=18, wob=0.14), "stain", L1)
    s.decal(blob(0.0, 0.0, 0.52, 0.5, 5.1, n=16, wob=0.1), "oil", L2)
    s.oil(-1.7, 1.6, 0.22, 1.9)
    s.crack(zigzag(G + 0.02, -0.15, 1.35, -0.75, 5, 0.04, 0.6))
    s.crack(zigzag(-G - 0.02, 0.2, -1.2, 1.1, 6, 0.05, 2.4), 0.014)
    s.crack(zigzag(-1.2, -T0, -0.9, -1.6, 4, 0.04, 3.3))
    s.spall(T0 - 0.02, 1.2, 0.1, 0.05, 2.5)
    mb, M = s.mb, s.M
    # sump: dark walls, black bottom
    d = 0.16
    for r in range(4):
        def rot(p, r=r):
            x, y, z = p
            for _ in range(r):
                x, y = -y, x
            return (x, y, z)
        mb.face([rot(p) for p in [(-G, -G, 0), (G, -G, 0), (G, -G, -d), (-G, -G, -d)]], M["concrete_dark"],
                rot((0, 1, 0)))
    mb.face([(-G, -G, -d), (G, -G, -d), (G, G, -d), (-G, G, -d)], M["void"], UP)
    slab = s.obj("Slab")
    # grate: a steel frame sunk 1 cm, bars across (one bent down), rust bleeding round it
    parts = [slab]
    fw = 0.05
    for (sx, sy, cx, cy) in ((2 * G, fw, 0, -G + fw / 2), (2 * G, fw, 0, G - fw / 2), (fw, 2 * G - 2 * fw, -G + fw / 2, 0),
                             (fw, 2 * G - 2 * fw, G - fw / 2, 0)):
        parts.append(box((sx, sy, 0.03), pos=(cx, cy, -0.04), bevel=0.004, mat="metal_dark", name="grate_frame"))
    n = 7
    for i in range(n):
        x = -G + fw + (2 * G - 2 * fw) * (i + 0.5) / n
        bar = box((0.026, 2 * G - 2 * fw + 0.02, 0.04), pos=(x, 0, -0.052), bevel=0.004, mat="metal_dark",
                  name="grate_bar")
        if i == 4:                               # this one got stepped on once too often
            bar.rotation_euler = (math.radians(4), 0, 0)
            bar.location.z -= 0.012
        parts.append(bar)
    parts.append(box((2 * G - 2 * fw, 0.02, 0.03), pos=(0, 0, -0.06), bevel=0.003, mat="metal_dark", name="grate_tie"))
    # rust ring on the concrete round the frame
    ring = MB()
    poly = blob(0.0, 0.0, G + 0.13, G + 0.1, 1.4, n=20, wob=0.12)
    for c in (clip_rect(poly, -T0, T0, -T0, -G), clip_rect(poly, -T0, T0, G, T0), clip_rect(poly, -T0, -G, -G, G),
              clip_rect(poly, G, T0, -G, G)):
        if c:
            ring.face([(u, v, 0.006) for u, v in c], M["rust"], UP)
    parts.append(ring.obj("rust_ring"))
    drain = join(parts, "Slab")
    export(drain, "floor_slab_drain", kind="part", mount="free", budget=2500)


def build():
    floor_a()
    floor_b()
    floor_drain()
