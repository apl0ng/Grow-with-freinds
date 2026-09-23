"""wall_panel family: the room's cinder-block walls as 5 m x 6 m panels (architecture, environment modeler).

Kind "prop", floor mount: the origin is on the floor ON THE WALL LINE (the inner face of the Walls collider),
block faces on Blender y = 0, mortar 3 cm behind, the front (-Y = Godot +Z) facing into the room. A 5.0 m module
(x -2.5..2.5; the mortar backing tucks 3.8 cm further behind each neighbour, see Wall.mortar) x 6.0 m (the top
lip meets the ceiling deck's crests), so the panels tile the 20 x 15 m room exactly, 4 + 3 + 4 + 3 of them
(scenes/world/room.tscn Walls/*: one scenes/world/props/segment_run.gd MultiMesh per variant and wall).

  Blocks      chunky 0.5 x 0.25 m cinder blocks in running bond, 2.4 cm chamfers down to 1.8 cm mortar joints
              (Kenney "brick": every edge catches a highlight). Odd courses start with a half block cut flat at
              the panel edge, so two panels side by side make a whole block and the seam disappears; even
              courses put a joint on the seam. A few blocks are a step darker or lighter (old / replaced).
  Skirting    a 0.26 m dark concrete kick, 5 cm proud, chamfered, chipped and scuffed.
  Paint       olive dado (courses 1-3) under a darker olive band at 1.0-1.25 m that drips down the dado and
              slops up onto the next course; paint peeled off in patches (bare block shows through).
  Wear        chipped corners (pale broken facets), a jagged hole knocked into one block, cracks, a damp streak
              from the ceiling, rust streaks under an old pipe stub / what is left of a pipe bracket.

Variants (one function each below):
  wall_panel         pipe stub + rust streak, damp streak, cracks, knocked-in block
  wall_panel_b       old pipe bracket + streaks, a patch of replaced blocks, a stair-step crack
  wall_panel_window  opening + precast lintel for props/barred_window.tscn (window centre 0.8 m to the viewer's
                     left of the panel centre, 4.1 m up: the west wall slot at z -5, window at z -4.2)
  wall_panel_door    the roller door's opening (props/roller_door.tscn at x -5.5 on the south wall straddles
  wall_panel_door_b  the panel seam at x -5): _door is the slot at x -7.5 (door centre 2.0 m to the viewer's
                     LEFT, i.e. local x -2.0), _door_b the slot at x -2.5 (door centre local x +3.0). Opening
                     4.2 x 3.75 m with a dark back, a 5 m precast lintel, hazard stripes beside the rail plates.
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                     # noqa: E402,F401
from _arch import *                   # noqa: E402,F401

X0, X1 = -2.5, 2.5
BW, CH_H = 0.5, 0.25                  # block width, course height
GAP = 0.018                           # mortar joint (at the mortar plane)
CH = 0.024                            # chamfer inset on the face
D = 0.03                              # mortar plane depth behind the block faces
TOP = 5.995                           # top of the blocks / mortar (the ceiling deck's crests are at 6.0)
CEIL = 6.0                            # the top edge's lip meets the deck at exactly the ceiling height
N_COURSES = 24
SK_H = CH_H + GAP / 2                 # skirting top (course 0 hides behind it)
SK_D = 0.05                           # skirting sticks out 5 cm
SK_BEV = 0.028
REVEAL = 0.3                          # depth of an opening (the wall thickness it shows)
TUCK = D + 0.008                      # the mortar plane runs this far past each end (see Wall.mortar)
DADO = (1, 2, 3)                      # olive courses
BAND = 4                              # the darker band, 1.0-1.25 m
LAYER = (-0.0025, -0.0045, -0.0065)   # decal offsets in front of the surface (y)

DOOR_HALF = 2.1                       # opening half width (the curtain is +-2.04, the rails +-2.09)
DOOR_TOP = 15 * CH_H                  # 3.75: opening height (curtain top 3.74, the drum hides the lintel)
DOOR_PLATE = 2.27                     # the door's rail wall-plates reach +-2.27: the skirting stops there
WIN_X, WIN_Z = -0.8, 4.1              # barred window centre (panel local)
WIN_HOLE = (WIN_X - 0.78, WIN_X + 0.78, 14 * CH_H, 19 * CH_H)   # 1.56 x 1.25 m, inside the 1.7 x 1.3 frame


class Wall:
    def __init__(self, seed, openings=(), lintels=(), skirt_gaps=()):
        self.mb = MB()
        self.M = arch_mats()
        self.seed = seed
        self.openings = list(openings)       # (x0, x1, z0, z1), z on course boundaries
        self.lintels = list(lintels)         # (x0, x1, course, material key)
        self.skirt_gaps = list(skirt_gaps)   # (x0, x1) with no skirting
        self.chips = {}                      # (course, x) -> (corner, size)
        self.broken = set()                  # (course, x)
        self.forced = {}                     # (course, x) -> material key (replaced blocks)
        self.faces = []                      # decal targets: (x0, x1, z0, z1)

    # ---------------------------------------------------------------------------------------- courses
    def pieces(self, k):
        """Blocks of course k as [x0, x1, left, right, kind] (joint positions; left/right 'joint' | 'flat')."""
        z0, z1 = k * CH_H, (k + 1) * CH_H
        off = 0.0 if k % 2 == 0 else BW / 2
        out = []
        for i in range(-1, 12):
            a, b = X0 + off + i * BW, X0 + off + (i + 1) * BW
            lo, hi = max(a, X0), min(b, X1)
            if hi - lo < 1e-6:
                continue
            out.append([lo, hi, "flat" if a < X0 - 1e-6 else "joint", "flat" if b > X1 + 1e-6 else "joint", "block"])
        for lx0, lx1, kk, _mat in self.lintels:
            if kk != k:
                continue
            kept = []
            for p in out:
                if p[1] <= lx0 + 1e-6 or p[0] >= lx1 - 1e-6:
                    kept.append(p)
                    continue
                if lx0 - p[0] > 0.06:
                    kept.append([p[0], lx0, p[2], "joint", p[4]])
                if p[1] - lx1 > 0.06:
                    kept.append([lx1, p[1], "joint", p[3], p[4]])
            lo, hi = max(lx0, X0), min(lx1, X1)
            kept.append([lo, hi, "flat" if lx0 < X0 - 1e-6 else "joint", "flat" if lx1 > X1 + 1e-6 else "joint",
                         "lintel"])
            out = sorted(kept)
        for ox0, ox1, oz0, oz1 in self.openings:
            if not (z0 >= oz0 - 1e-6 and z1 <= oz1 + 1e-6):
                continue
            kept = []
            for p in out:
                if p[1] <= ox0 + 1e-6 or p[0] >= ox1 - 1e-6:
                    kept.append(p)
                    continue
                if ox0 - p[0] > 0.05:
                    kept.append([p[0], ox0, p[2], "flat", p[4]])
                if p[1] - ox1 > 0.05:
                    kept.append([ox1, p[1], "flat", p[3], p[4]])
            out = kept
        return out

    def block_mat(self, k, x0, x1, kind):
        for (kk, x), m in self.forced.items():
            if kk == k and x0 <= x < x1:
                return m
        if kind == "lintel":
            return dict((l[2], l[3]) for l in self.lintels)[k]
        if k in DADO:
            return "olive"
        if k == BAND:
            return "olive_dark"
        h = random.Random(self.seed * 1000 + k * 37 + int((x0 + 3) * 20)).random()
        return "block_dark" if h < 0.11 else "block_light" if h > 0.95 else "concrete"

    # ------------------------------------------------------------------------------------------ block
    def block(self, bx0, bx1, bz0, bz1, lj, rj, mat, chip=None, cores=False, bottom_mat=None, top_mat=None):
        """One block shell: front face + 4 chamfers (or flat ends) down to the mortar plane. 10 tris."""
        M, mb = self.M, self.mb
        fx0, fx1 = bx0 + (CH if lj else 0.0), bx1 - (CH if rj else 0.0)
        fz0, fz1 = bz0 + CH, bz1 - CH
        F = [Vector((fx0, 0, fz0)), Vector((fx1, 0, fz0)), Vector((fx1, 0, fz1)), Vector((fx0, 0, fz1))]
        B = [Vector((bx0, D, bz0)), Vector((bx1, D, bz0)), Vector((bx1, D, bz1)), Vector((bx0, D, bz1))]
        # bottom, right, top, left. A flat (cut) end faces INTO the panel: at a room corner it closes the end of
        # the horizontal grooves against the other wall; at a seam it is sandwiched inside the whole block.
        side_hint = [(0, -1, -1), (1, -1, 0) if rj else (-1, 0, 0), (0, -1, 1), (-1, -1, 0) if lj else (1, 0, 0)]
        side_mat = [bottom_mat or mat, mat, top_mat or mat, mat]
        front = list(F)
        sides = [[F[i], F[(i + 1) % 4], B[(i + 1) % 4], B[i]] for i in range(4)]
        if chip is not None:
            corner, s = chip
            ci = ["bl", "br", "tr", "tl"].index(corner)
            prev, nxt = F[(ci - 1) % 4], F[(ci + 1) % 4]
            ea = F[ci] + (prev - F[ci]).normalized() * min(s, (prev - F[ci]).length * 0.6)
            eb = F[ci] + (nxt - F[ci]).normalized() * min(s * 1.3, (nxt - F[ci]).length * 0.6)
            cp = F[ci].lerp(B[ci], 0.8)
            front = []
            for i in range(4):
                front += [ea, eb] if i == ci else [F[i]]
            sp = (ci - 1) % 4
            sides[sp] = [F[sp], ea, cp, B[ci], B[sp]]
            sides[ci] = [cp, eb, F[(ci + 1) % 4], B[(ci + 1) % 4], B[ci]]
            hint = Vector(side_hint[sp]) + Vector(side_hint[ci]) + Vector((0, -1, 0))
            mb.face([ea, cp, eb], M["block_light"], hint)
        if cores:
            self.cored_front(fx0, fx1, fz0, fz1, M[mat])
        else:
            mb.face(front, M[mat], (0, -1, 0))
        for i in range(4):
            mb.face(sides[i], M[side_mat[i]], side_hint[i])
        if chip is None and not cores and fx1 - fx0 > 0.05:
            self.faces.append((fx0, fx1, fz0, fz1))

    def cored_front(self, fx0, fx1, fz0, fz1, mat):
        """A block whose face was knocked in: a jagged hole into the hollow core, a pale broken edge round it."""
        mb, M = self.mb, self.M
        cx, cz = (fx0 + fx1) / 2 + 0.02, (fz0 + fz1) / 2 - 0.005
        n = 12
        hole, rim = [], []
        for i in range(n):
            a = 2 * math.pi * i / n
            r = 1.0 + (0.22 if i % 2 else -0.12) + 0.08 * math.sin(3 * a + 1.3)
            hx, hz = 0.12 * r * math.cos(a), 0.055 * r * math.sin(a)
            hole.append(Vector((cx + hx, 0.0, cz + hz)))
            rim.append(Vector((cx + hx * 1.28, 0.0, cz + hz * 1.3)))
        rim = [Vector((min(max(p.x, fx0 + 0.004), fx1 - 0.004), 0.0, min(max(p.z, fz0 + 0.004), fz1 - 0.004)))
               for p in rim]
        # the face: a ring of quads from the face's border to the pale rim (a fan from the corners)
        border = []
        for i in range(n):
            a = 2 * math.pi * i / n
            ca, sa = math.cos(a), math.sin(a)
            tx = abs((fx1 - fx0) / 2 / ca) if abs(ca) > 1e-6 else 1e9
            tz = abs((fz1 - fz0) / 2 / sa) if abs(sa) > 1e-6 else 1e9
            t = min(tx, tz)
            border.append(Vector(((fx0 + fx1) / 2 + ca * t, 0.0, (fz0 + fz1) / 2 + sa * t)))
        corners = [Vector((fx1, 0, fz1)), Vector((fx0, 0, fz1)), Vector((fx0, 0, fz0)), Vector((fx1, 0, fz0))]
        for i in range(n):
            j = (i + 1) % n
            mb.face([border[i], border[j], rim[j], rim[i]], mat, (0, -1, 0))
            if i in (n // 4 - 1, n // 2 - 1, 3 * n // 4 - 1, n - 1):
                c = corners[[n // 4 - 1, n // 2 - 1, 3 * n // 4 - 1, n - 1].index(i)]
                mb.face([border[i], c, border[j]], mat, (0, -1, 0))
        # broken edge (pale, sloping into the hole), dark core behind it
        dd = D - 0.004
        for i in range(n):
            j = (i + 1) % n
            mb.face([rim[i], rim[j], hole[j], hole[i]], M["block_light"], (0, -1, 0))
            inner = [Vector((p.x, dd, p.z)) for p in (hole[i], hole[j])]
            mb.face([hole[i], hole[j], inner[1], inner[0]], M["concrete_dark"], Vector((cx, 0, cz)) - hole[i])
        mb.face([Vector((p.x, dd, p.z)) for p in hole], M["dark"], (0, -1, 0))
        # rubble chips knocked loose onto the joint below
        for dx in (-0.09, 0.1):
            x0 = cx + dx
            mb.face([(x0 - 0.028, -0.001, fz0 - 0.004), (x0 + 0.026, -0.001, fz0 - 0.004),
                     (x0 + 0.01, -0.001, fz0 + 0.026)],
                    M["block_light"], (0, -1, 0))

    def course_blocks(self, k):
        bz0 = k * CH_H + GAP / 2
        bz1 = min((k + 1) * CH_H - GAP / 2, TOP)
        for x0, x1, left, right, kind in self.pieces(k):
            lj, rj = left == "joint", right == "joint"
            bx0 = x0 + (GAP / 2 if lj else 0.0)
            bx1 = x1 - (GAP / 2 if rj else 0.0)
            if bx1 - bx0 < 0.04:
                continue
            mat = self.block_mat(k, x0, x1, kind)
            chip = next((v for (kk, x), v in self.chips.items() if kk == k and x0 <= x < x1), None)
            cores = any(kk == k and x0 <= x < x1 for kk, x in self.broken)
            # the band's paint runs into the joints above and below it (the drips start right at its edge)
            bottom = "olive_dark" if k == BAND + 1 and kind == "block" else None
            top = "olive_dark" if k == BAND - 1 and kind == "block" else None
            self.block(bx0, bx1, bz0, bz1, lj, rj, mat, chip, cores, bottom, top)

    # ------------------------------------------------------------------------------------------ mortar
    def mortar(self):
        """The mortar plane behind the blocks (minus openings). It tucks TUCK past both panel ends, 4 mm deeper:
        where two walls meet at a room corner the two tucks close the corner column behind the joints (no
        background shows through the grooves); on a seam the tuck hides behind the neighbour's mortar."""
        rects = [(X0 - TUCK, X1 + TUCK, 0.2, TOP)]
        for ox0, ox1, oz0, oz1 in self.openings:
            ox0, ox1 = max(ox0, X0 - TUCK), min(ox1, X1 + TUCK)
            if ox0 <= X0:
                ox0 = X0 - TUCK
            if ox1 >= X1:
                ox1 = X1 + TUCK
            nxt = []
            for x0, x1, z0, z1 in rects:
                if x1 <= ox0 or x0 >= ox1 or z1 <= oz0 or z0 >= oz1:
                    nxt.append((x0, x1, z0, z1))
                    continue
                if z0 < oz0:
                    nxt.append((x0, x1, z0, oz0))
                if z1 > oz1:
                    nxt.append((x0, x1, oz1, z1))
                if x0 < ox0:
                    nxt.append((x0, ox0, max(z0, oz0), min(z1, oz1)))
                if x1 > ox1:
                    nxt.append((ox1, x1, max(z0, oz0), min(z1, oz1)))
            rects = nxt
        split = (BAND + 1) * CH_H + GAP / 2
        for x0, x1, z0, z1 in rects:
            for a, b, y in ((x0, min(x1, X0), D + 0.004), (max(x0, X0), min(x1, X1), D), (max(x0, X1), x1, D + 0.004)):
                if b - a < 1e-5:
                    continue
                for za, zb, m in ((z0, min(z1, split), "olive_dark"), (max(z0, split), z1, "concrete_dark")):
                    if zb - za > 1e-4:
                        self.mb.face([(a, y, za), (b, y, za), (b, y, zb), (a, y, zb)], self.M[m], (0, -1, 0))

    def reveals(self):
        """Openings: jambs / head / sill running back REVEAL m to a dark back face."""
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
            if oz0 > 0:
                mb.face([(a, 0, oz0), (b, 0, oz0), (b, REVEAL, oz0), (a, REVEAL, oz0)], M["concrete"], (0, 0, 1))
            mb.face([(a, REVEAL, oz0), (b, REVEAL, oz0), (b, REVEAL, oz1), (a, REVEAL, oz1)], M["dark"], (0, -1, 0))

    # ---------------------------------------------------------------------------------------- skirting
    def skirting(self, notches=(), scuffs=()):
        """Dark concrete kick along the floor, cut round openings, chipped at `notches` [(x, width)]."""
        M, mb = self.M, self.mb
        segs = [(X0, X1)]
        for g0, g1 in self.skirt_gaps:
            nxt = []
            for a, b in segs:
                if b <= g0 or a >= g1:
                    nxt.append((a, b))
                    continue
                if g0 - a > 0.02:
                    nxt.append((a, g0))
                if b - g1 > 0.02:
                    nxt.append((g1, b))
            segs = nxt

        def profile(x):
            dz = dy = 0.0
            for nx, nw in notches:
                t = abs(x - nx) / (nw / 2)
                if t < 1:
                    k = 1 - t * t
                    dz, dy = max(dz, 0.055 * k), max(dy, 0.02 * k)
            return [Vector((x, -SK_D, 0.0)), Vector((x, -SK_D + dy * 0.3, SK_H - SK_BEV - dz)),
                    Vector((x, -SK_D + SK_BEV + dy, SK_H - dz * 0.6)), Vector((x, D, SK_H))]
        for a, b in segs:
            xs = {a, b}
            xs.update(x for x in (a + i * 0.5 for i in range(11)) if a < x < b)
            for nx, nw in notches:
                xs.update(x for x in (nx - nw / 2, nx - nw / 4, nx, nx + nw / 4, nx + nw / 2) if a < x < b)
            xs = sorted(xs)
            rows = [profile(x) for x in xs]
            for r0, r1 in zip(rows, rows[1:]):
                for j, hint, m in ((0, (0, -1, 0), "concrete_dark"), (1, (0, -1, 1), "concrete_dark"),
                                   (2, (0, 0, 1), "concrete_dark")):
                    nm = m
                    if j > 0 and any(abs((r0[0].x + r1[0].x) / 2 - nx) < nw / 2 for nx, nw in notches):
                        nm = "concrete"          # broken edge: fresh concrete
                    mb.face([r0[j], r1[j], r1[j + 1], r0[j + 1]], M[nm], hint)
            for x, sgn in ((a, -1), (b, 1)):     # end caps where a segment stops inside the panel
                if X0 + 1e-6 < x < X1 - 1e-6:
                    p = profile(x)
                    mb.face([p[0], p[1], p[2], p[3], Vector((x, D, 0.0))], M["concrete_dark"], (sgn, 0, 0))
        # scuffs: (x, z, length, height, material)
        for x, z, ln, ht, m in scuffs:
            if any(g0 - 0.05 < x < g1 + 0.05 for g0, g1 in self.skirt_gaps):
                continue
            poly = blob(x, z, ln / 2, ht / 2, x * 7.1, n=10, wob=0.22)
            mb.face([(u, -SK_D + LAYER[0], v) for u, v in poly], M[m], (0, -1, 0))

    # ------------------------------------------------------------------------------------------ decals
    def decal(self, poly, mat, layer=0):
        """A flat decal on the block faces (clipped to each face: nothing bridges a joint)."""
        us = [p[0] for p in poly]
        vs = [p[1] for p in poly]
        for fx0, fx1, fz0, fz1 in self.faces:
            if fx1 < min(us) or fx0 > max(us) or fz1 < min(vs) or fz0 > max(vs):
                continue
            c = clip_rect(poly, fx0, fx1, fz0, fz1)
            if c:
                self.mb.face([(u, LAYER[layer], v) for u, v in c], self.M[mat], (0, -1, 0))

    def band_edge(self, seed):
        """Paint slopped up from the band onto the next course (ragged top edge)."""
        z = (BAND + 1) * CH_H + GAP / 2 + CH
        pts = [(X0, z)]
        n = 100
        for i in range(n + 1):
            x = X0 + (X1 - X0) * i / n
            h = (0.004 + 0.034 * max(0.0, math.sin(6.1 * x + seed)) ** 2
                 + 0.02 * max(0.0, math.sin(15.7 * x + 2 * seed)) ** 3)
            pts.append((x, z + h))
        pts.append((X1, z))
        self.decal(pts, "olive_dark", 0)

    def drips(self, xs, seed):
        """Runs of the band's paint down the dado: short ones stop on the course below the band, long ones
        carry on over the next joint and end well inside the course under it (never right at a joint)."""
        z = BAND * CH_H
        r = random.Random(seed)
        for i, x in enumerate(xs):
            ln = r.uniform(0.08, 0.15) if i % 3 != 1 else r.uniform(0.33, 0.43)
            self.decal(drip(x, z + 0.01, ln, r.uniform(0.05, 0.068), r.uniform(0, 6), bulb=1.6), "olive_dark", 1)

    def peel(self, cx, cz, rx, rz, seed):
        """A patch where the paint has flaked off: dark rim, bare block inside."""
        self.decal(blob(cx, cz, rx + 0.022, rz + 0.018, seed, n=16, wob=0.2), "olive_dark", 0)
        self.decal(blob(cx, cz, rx, rz, seed, n=16, wob=0.2), "block_light", 1)

    def crack(self, pts, w=0.017):
        for q in crack_quads(pts, w):
            self.decal(q, "dark", 2)

    # --------------------------------------------------------------------------------------- features
    def pipe_stub(self, x, z):
        """An old pipe cut off at the wall: flange, stub, dark bore, rust. Returns its parts."""
        parts = [
            cyl(0.14, 0.022, verts=16, pos=(x, 0.002, z), rot=(90, 0, 0), bevel=0.006, mat="metal_dark",
                name="stub_flange", anchor="base"),
            cyl(0.085, 0.16, verts=16, pos=(x, 0.01, z), rot=(90, 0, 0), bevel=0.01, mat="metal_dark",
                name="stub", anchor="base"),
            cyl(0.062, 0.0105, verts=16, pos=(x, -0.141, z), rot=(90, 0, 0), bevel=0, mat="dark", name="bore",
                anchor="base"),
            arc_panel(0.086, 0.09, angle=150, thickness=0.004, pos=(0, 0, 0), segments=8, mat="rust",
                      name="stub_rust"),
        ]
        rust = parts[-1]                    # built round Z: lay it along the stub (Y), rust on the underside
        rust.rotation_euler = (math.radians(90), 0, 0)
        rust.location = (x, -0.035, z)
        for bx, bz in ((x - 0.1, z + 0.1), (x + 0.1, z - 0.1), (x + 0.1, z + 0.1)):
            parts.append(cyl(0.017, 0.016, verts=6, pos=(bx, -0.018, bz), rot=(90, 0, 0), bevel=0,
                             mat="metal_dark", name="stub_bolt", anchor="base"))
        return parts

    def bracket(self, x, z):
        """What is left of a pipe bracket: wall plate, bent arm, a half clamp, two bolts."""
        parts = [
            box((0.16, 0.014, 0.24), pos=(x, -0.007, z - 0.12), bevel=0.004, mat="metal_dark", name="bracket_plate"),
            box((0.05, 0.2, 0.05), pos=(x, -0.11, z - 0.02), rot=(-8, 0, 3), bevel=0.008, mat="metal_dark",
                name="bracket_arm"),
            torus(0.09, 0.014, pos=(x, -0.24, z + 0.055), rot=(0, 90, 0), major_segments=16, minor_segments=6,
                  mat="rust", name="bracket_clamp"),
        ]
        cut = box((0.3, 0.3, 0.3), pos=(x, -0.24, z + 0.07), bevel=0, name="half")   # only the lower half clamp
        boolean_cut(parts[2], cut)
        for bz in (z - 0.07, z + 0.07):
            parts.append(cyl(0.02, 0.018, verts=6, pos=(x, -0.012, bz), rot=(90, 0, 0), bevel=0,
                             mat="metal_dark", name="bracket_bolt", anchor="base"))
        return parts

    def hazard(self, x0, x1, z0, z1):
        """Diagonal caution / dark stripes painted on the blocks (next to the door)."""
        self.decal([(x0, z0), (x1, z0), (x1, z1), (x0, z1)], "dark", 0)
        step = 0.2
        k = -8
        while k * step < (x1 - x0) + (z1 - z0) + step:
            a = x0 + k * step
            stripe = [(a, z0), (a + step / 2, z0), (a + step / 2 + (z1 - z0), z1), (a + (z1 - z0), z1)]
            s = clip_rect(stripe, x0, x1, z0, z1)
            if s:
                self.decal(s, "caution", 1)
            k += 1

    def structure(self):
        """Blocks, mortar and reveals (call before decals: they need the block faces)."""
        for k in range(1, N_COURSES):
            self.course_blocks(k)
        self.mortar()
        self.reveals()
        # the top edge leans out from the mortar to the wall line at exactly 6.0 m, where the ceiling deck's
        # crests end: no slit between the wall top and the ceiling
        self.mb.face([(X0, D, TOP), (X1, D, TOP), (X1, -0.001, CEIL), (X0, -0.001, CEIL)], self.M["concrete_dark"],
                     (0, -1, -1))


# ---------------------------------------------------------------------------------------------- variants
def paint_wear(w, seed, drips_x, peels, band_seed):
    """The dado's sloppy band edge, drips at drips_x, peeled patches [(x, z, rx, rz, seed)]."""
    w.band_edge(band_seed)
    w.drips(drips_x, seed)
    for p in peels:
        w.peel(*p)


def scuff(x, z, length, height, mat="dark"):
    return (x, z, length, height, mat)


def wall_a():
    reset()
    w = Wall(seed=11)
    w.chips = {(7, 0.62): ("tr", 0.07), (12, -0.32): ("bl", 0.06), (2, 1.85): ("tl", 0.08),
               (17, -2.0): ("br", 0.06), (21, 1.6): ("tl", 0.07)}
    w.broken = {(9, -1.55)}
    stub = w.pipe_stub(1.35, 4.65)
    w.structure()                             # blocks first: the decals need their faces
    paint_wear(w, 11, (-2.05, -1.2, -0.62, 0.35, 1.02, 1.95),
               [(-0.9, 0.62, 0.2, 0.13, 1.3), (1.55, 1.05, 0.14, 0.1, 2.2)], 0.7)
    w.decal(streak(1.35, 4.52, 1.55, 0.13, 0.035, seed=1.0), "rust", 1)
    w.decal(streak(1.28, 4.5, 0.95, 0.05, 0.02, seed=2.2, wander=0.02), "rust", 2)
    w.decal(streak(-0.35, TOP, 1.9, 0.62, 0.22, seed=3.1, wander=0.08), "block_dark", 0)
    w.crack(zigzag(-2.1, 2.05, -1.25, 3.2, 7, 0.05, 1.0))
    w.crack(zigzag(-1.55, 2.62, -1.95, 2.95, 3, 0.03, 2.0), 0.013)
    w.crack(zigzag(0.3, 5.45, 0.95, 5.95, 5, 0.04, 4.0))
    w.skirting(notches=[(-1.3, 0.22), (2.05, 0.14)],
               scuffs=[scuff(-2.0, 0.12, 0.3, 0.03), scuff(-0.4, 0.09, 0.45, 0.035),
                       scuff(0.9, 0.16, 0.25, 0.03, "concrete"), scuff(1.6, 0.07, 0.35, 0.03)])
    wall = w.mb.obj("wall_blocks", smooth=30.0)
    export(join([wall] + stub, "Wall"), "wall_panel", kind="prop", mount="floor", budget=4500)


def wall_b():
    reset()
    w = Wall(seed=23)
    w.chips = {(6, -0.9): ("tl", 0.08), (14, 1.3): ("br", 0.06), (3, -2.2): ("tr", 0.07), (19, 0.1): ("bl", 0.07),
               (10, 2.3): ("tl", 0.06)}
    w.broken = {(16, 1.85)}
    for k, x in ((13, 0.6), (13, 1.1), (14, 0.35), (14, 0.85), (15, 0.6), (15, 1.1)):
        w.forced[(k, x)] = "block_light"          # a patch of replaced blocks (a hole someone filled in)
    bracket = w.bracket(-1.35, 4.1)
    w.structure()
    paint_wear(w, 23, (-1.7, -0.95, -0.1, 0.72, 1.45, 2.2),
               [(0.4, 0.45, 0.24, 0.12, 0.4), (-1.9, 0.85, 0.12, 0.14, 3.3), (1.8, 0.4, 0.1, 0.08, 5.0)], 2.9)
    w.decal(streak(-1.35, 3.95, 1.25, 0.1, 0.03, seed=0.4), "rust", 1)
    w.decal(streak(-1.2, 3.9, 0.7, 0.05, 0.02, seed=1.9, wander=0.02), "rust", 2)
    w.decal(streak(1.9, TOP, 1.4, 0.4, 0.15, seed=5.2, wander=0.06), "block_dark", 0)
    w.crack(zigzag(1.45, 3.95, 2.3, 5.1, 8, 0.06, 3.0))          # running up from the filled-in patch
    w.crack(zigzag(-0.6, 1.6, 0.25, 2.3, 5, 0.04, 6.0), 0.014)
    w.skirting(notches=[(0.55, 0.3)],
               scuffs=[scuff(-1.5, 0.1, 0.5, 0.035), scuff(0.0, 0.15, 0.2, 0.03, "concrete"),
                       scuff(1.4, 0.1, 0.4, 0.03),
                       scuff(2.2, 0.17, 0.2, 0.03, "concrete")])
    wall = w.mb.obj("wall_blocks", smooth=30.0)
    export(join([wall] + bracket, "Wall"), "wall_panel_b", kind="prop", mount="floor", budget=4500)


def wall_window():
    reset()
    lintel = (WIN_X - 1.2, WIN_X + 1.2, 19, "block_light")        # precast, over the frame (top at 4.75)
    w = Wall(seed=37, openings=[WIN_HOLE], lintels=[lintel])
    w.chips = {(8, 1.3): ("br", 0.07), (13, -1.9): ("tr", 0.06), (2, 0.9): ("bl", 0.08), (20, 1.9): ("tl", 0.06)}
    w.broken = {(5, 2.1)}
    w.structure()
    paint_wear(w, 37, (-2.2, -1.35, -0.55, 0.5, 1.4), [(1.0, 0.75, 0.22, 0.12, 0.9), (-1.6, 1.08, 0.13, 0.1, 4.1)], 1.6)
    # the window leaks: a damp streak from under the sill down to the band, rust from the lintel's bearing
    w.decal(streak(WIN_X + 0.35, 3.3, 1.9, 0.5, 0.18, seed=0.8, wander=0.05), "block_dark", 0)
    w.decal(streak(WIN_X + 1.02, 4.72, 0.7, 0.06, 0.02, seed=2.5), "rust", 1)
    w.crack(zigzag(WIN_X + 1.2, 5.02, WIN_X + 1.9, 5.8, 6, 0.05, 1.7))     # from the lintel's end
    w.crack(zigzag(WIN_X - 1.2, 3.45, WIN_X - 1.7, 2.7, 5, 0.04, 0.3), 0.014)
    w.skirting(notches=[(1.7, 0.2)],
               scuffs=[scuff(-1.0, 0.12, 0.4, 0.035), scuff(0.6, 0.08, 0.3, 0.03),
                       scuff(2.1, 0.16, 0.2, 0.03, "concrete")])
    export(join([w.mb.obj("wall_blocks", smooth=30.0)], "Wall"), "wall_panel_window", kind="prop", mount="floor",
           budget=4500)


def wall_door(name, door_x, seed):
    """One of the two panels the roller door straddles; door_x = the door centre in this panel's coords."""
    reset()
    lintel = (door_x - 2.5, door_x + 2.5, 15, "block_light")
    opening = (door_x - DOOR_HALF, door_x + DOOR_HALF, 0.0, DOOR_TOP)
    w = Wall(seed=seed, openings=[opening], lintels=[lintel], skirt_gaps=[(door_x - DOOR_PLATE, door_x + DOOR_PLATE)])
    side = 1 if door_x < 0 else -1                    # the side of the door that is inside this panel
    jamb = door_x + side * DOOR_PLATE                   # the visible jamb edge (just outside the rail plate)
    # wear where forklifts and trolleys hit the jambs, cracks running up from the lintel's ends
    if name == "wall_panel_door":
        w.chips = {(2, jamb + side * 0.3): ("bl" if side > 0 else "br", 0.09),
                   (5, jamb + side * 0.15): ("tl" if side > 0 else "tr", 0.07),
                   (11, 1.4): ("tr", 0.06), (18, -1.6): ("bl", 0.07), (22, 1.0): ("br", 0.06)}
        w.broken = {(3, jamb + side * 0.7)}
    else:
        w.chips = {(1, jamb + side * 0.2): ("tr" if side < 0 else "tl", 0.08), (9, -0.6): ("bl", 0.07),
                   (20, -1.9): ("tr", 0.06), (13, 1.0): ("tl", 0.06)}
        w.broken = {(12, -1.2)}
    w.structure()
    lo, hi = sorted((jamb, jamb + side * 0.26))
    w.hazard(lo, hi, SK_H + 0.02, 1.55)
    w.band_edge(seed * 0.37)
    w.drips([x for x in (-2.2, -1.5, -0.8, -0.1, 0.6, 1.3, 2.0) if (x - jamb) * side > 0.45], seed)
    if name == "wall_panel_door":
        w.peel(jamb + side * 1.3, 0.75, 0.24, 0.14, 1.1)
        w.crack(zigzag(door_x + 2.5, 4.02, door_x + 3.1, 4.9, 6, 0.05, 0.9))
        w.decal(streak(jamb + side * 0.85, TOP, 1.6, 0.45, 0.18, seed=2.0, wander=0.06), "block_dark", 0)
    else:
        w.peel(jamb + side * 1.1, 0.5, 0.2, 0.12, 2.7)
        w.crack(zigzag(door_x - 2.5, 4.02, door_x - 3.05, 4.85, 6, 0.05, 2.2))
        w.decal(streak(-1.6, TOP, 1.3, 0.35, 0.12, seed=4.4, wander=0.05), "block_dark", 0)
    # rust bleeding down the wall from the lintel's bearing, beside the rail plate
    w.decal(streak(door_x + side * 2.42, DOOR_TOP - 0.01, 0.85, 0.07, 0.02, seed=seed), "rust", 1)
    w.skirting(notches=[(jamb + side * 0.25, 0.16)],
               scuffs=[scuff(jamb + side * 0.6, 0.12, 0.4, 0.035),
                       scuff(jamb + side * 1.4, 0.09, 0.3, 0.03, "concrete"),
                       scuff(jamb + side * 2.0, 0.14, 0.35, 0.035)])
    export(join([w.mb.obj("wall_blocks", smooth=30.0)], "Wall"), name, kind="prop", mount="floor", budget=4500)


def build():
    wall_a()
    wall_b()
    wall_window()
    wall_door("wall_panel_door", -2.0, 41)
    wall_door("wall_panel_door_b", 3.0, 53)
