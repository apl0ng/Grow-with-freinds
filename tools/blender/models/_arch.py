"""_arch: shared helpers for the room ARCHITECTURE families (environment modeler, architecture pass).

Not a model script (build.py skips files starting with "_"). The architecture scripts import it with
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); from _arch import *
  wall_panel.py     wall_panel, wall_panel_b, wall_panel_window, wall_panel_door, wall_panel_door_b
  floor_slab.py     floor_slab, floor_slab_b, floor_slab_drain
  ceiling_panel.py  ceiling_panel, ceiling_panel_b, ceiling_panel_hole
  ceiling_beam.py   ceiling_beam
  hole_rim.py       hole_rim

The room (scenes/world/room.tscn, Room.INTERIOR_SIZE) is 20 x 6 x 15 m inside: x -10..10, z -7.5..7.5 (Godot),
floor top y = 0, ceiling y = 6. Everything tiles on a 5 m grid: 4 + 3 + 4 + 3 wall panels, 4 x 3 floor slabs,
4 x 3 ceiling panels, beams along Godot Z at x = -5, 0, 5 (they hide the ceiling seams).

Geometry here is built face by face (MB below) with UNSHARED vertices, so every face is flat-shaded: big
architecture must never get pillowy vertex normals across a 5 m panel. Decals (paint drips, rust streaks,
stains, cracks) are flat single faces a few mm in front of the surface they sit on, clipped to that surface
(clip_rect / clip_convex) so nothing ever bridges a groove or floats over a hole.
"""
import bmesh
import bpy
import math
from mathutils import Vector
from gwf import lib, material

ROOM_W, ROOM_H, ROOM_D = 20.0, 6.0, 15.0   # Room.INTERIOR_SIZE (x, y, z)
PANEL = 5.0                                 # every architecture module is 5 m on the grid
DECK_RIB = 0.1                              # ceiling deck: crests at y 6.0 (the collider face), valleys 0.1 above

# Ceiling deck rib profile across a panel (Blender y; the ribs run along X): 16 trapezoidal ribs, crests (the
# low faces, z = -DECK_RIB below the valleys) centred on y = -2.5 + k * RIB_PITCH, so both panel edges along X
# sit in a crest's middle (seams invisible, symmetric when a panel is turned round).
N_RIBS = 16
RIB_PITCH = PANEL / N_RIBS                  # 0.3125
CREST_HALF = 0.055                          # crest flat 0.11
RIB_SLOPE = 0.045
RIB_VALLEY = RIB_PITCH - 2 * CREST_HALF - 2 * RIB_SLOPE   # 0.1125


def _deck_breaks():
    s, r = PANEL / 2, DECK_RIB
    pts = []
    for k in range(N_RIBS):
        c = -s + k * RIB_PITCH
        pts += [(c, -r), (c + CREST_HALF, -r), (c + CREST_HALF + RIB_SLOPE, 0.0),
                (c + CREST_HALF + RIB_SLOPE + RIB_VALLEY, 0.0), (c + RIB_PITCH - CREST_HALF, -r)]
    pts.append((s, -r))
    return pts


DECK_BREAKS = _deck_breaks()                # (y, z) corners of the profile, y ascending


def deck_z(y):
    """Height of the (undeformed) deck sheet at panel coord y (0 = valleys, -DECK_RIB = crests)."""
    for (y0, z0), (y1, z1) in zip(DECK_BREAKS, DECK_BREAKS[1:]):
        if y0 - 1e-9 <= y <= y1 + 1e-9:
            return z0 + (z1 - z0) * (y - y0) / (y1 - y0) if y1 > y0 else z0
    return -DECK_RIB

# The ceiling hole (room.tscn: Ceiling/HoleVoid is a 2.6 x 1.6 x 2 inside-out black box centred on
# (-3.5, 6.75, 3.2); Lights/HoleDustLight and Decor/HoleDust sit on the same x/z). The hole lives in the ceiling
# panel whose cell is x -5..0, z 2.5..7.5 (centre (-2.5, 5.0)); its north edge runs along the panel seam at
# z 2.5, where the beam-less seam is hidden by the torn flaps of hole_rim.
HOLE_CENTER = (-3.5, 3.2)                   # Godot x, z
HOLE_PANEL_CENTER = (-2.5, 5.0)             # Godot x, z of the ceiling panel cell holding the hole
# Outline of the hole in HOLE-LOCAL Blender coords (x = Godot x, y = -Godot z, origin on the hole centre),
# counter-clockwise seen from below. Godot: x -4.72..-2.28, z 2.5..4.12 (inside the void box x -4.8..-2.2,
# z 2.2..4.2). The straight stretch at y = 0.7 is the panel seam (Godot z 2.5).
HOLE_OUTLINE = [
    (-1.22, 0.70), (-0.95, 0.70), (-0.55, 0.70), (-0.1, 0.70), (0.35, 0.70), (0.8, 0.70), (1.2, 0.70),
    (1.16, 0.52), (1.22, 0.33), (1.13, 0.12), (1.18, -0.08), (1.08, -0.3), (1.12, -0.52), (0.95, -0.62),
    (0.8, -0.8), (0.55, -0.72), (0.33, -0.92), (0.1, -0.84), (-0.14, -0.9), (-0.38, -0.8), (-0.6, -0.87),
    (-0.82, -0.72), (-1.02, -0.78), (-1.1, -0.55), (-1.2, -0.36), (-1.14, -0.12), (-1.22, 0.1), (-1.16, 0.3),
    (-1.23, 0.5),
]


HOLE_OFFSET = (HOLE_CENTER[0] - HOLE_PANEL_CENTER[0], -(HOLE_CENTER[1] - HOLE_PANEL_CENTER[1]))  # (-1.0, 1.8)


def hole_outline_in_panel():
    """HOLE_OUTLINE in the hole panel's Blender coords (its origin on the panel cell centre)."""
    return [(x + HOLE_OFFSET[0], y + HOLE_OFFSET[1]) for x, y in HOLE_OUTLINE]


def hole_warp(x, y):
    """How far (m, >= 0) the deck sheet round the hole is bent down at panel coords (x, y): most at the
    torn edge (4 cm), fading out over 0.6 m and to nothing at the panel edges (the seams stay level). ceiling_panel
    bends the sheet with it, hole_rim hangs its torn lip from it."""
    pts = hole_outline_in_panel()
    d = min(_seg_dist(x, y, p, q) for p, q in zip(pts, pts[1:] + pts[:1]))
    fade = max(0.0, min(1.0, (PANEL / 2 - abs(x)) / 0.35, (PANEL / 2 - abs(y)) / 0.35))
    return 0.04 * max(0.0, 1 - d / 0.6) ** 2 * fade


def _seg_dist(x, y, p, q):
    dx, dy = q[0] - p[0], q[1] - p[1]
    ln2 = dx * dx + dy * dy
    t = 0.0 if ln2 < 1e-12 else max(0.0, min(1.0, ((x - p[0]) * dx + (y - p[1]) * dy) / ln2))
    return math.hypot(x - p[0] - t * dx, y - p[1] - t * dy)


# ------------------------------------------------------------------------------------------ mesh builder
class MB:
    """Face-by-face mesh builder. Every face gets its own vertices (flat shading, no welding); `hint` is the
    direction the face must look at (its winding is flipped to match)."""

    def __init__(self):
        self.bm = bmesh.new()
        self.mats = []

    def mi(self, mat):
        m = lib(mat) if isinstance(mat, str) else mat
        if m not in self.mats:
            self.mats.append(m)
        return self.mats.index(m)

    def face(self, pts, mat, hint=None):
        pts = [Vector(p) for p in pts]
        # drop consecutive duplicates (clipping leaves some)
        clean = []
        for p in pts:
            if not clean or (p - clean[-1]).length > 1e-6:
                clean.append(p)
        if len(clean) > 2 and (clean[0] - clean[-1]).length < 1e-6:
            clean.pop()
        if len(clean) < 3 or _area3(clean) < 1e-7:
            return None
        f = self.bm.faces.new([self.bm.verts.new(p) for p in clean])
        f.material_index = self.mi(mat)
        if hint is not None:
            f.normal_update()
            if f.normal.dot(Vector(hint)) < 0:
                f.normal_flip()
        return f

    def quad_strip(self, rows, mat, hint=None):
        """Faces between consecutive point rows (lists of equal length): lofted sheets, sweeps."""
        for a, b in zip(rows, rows[1:]):
            for i in range(len(a) - 1):
                self.face((a[i], a[i + 1], b[i + 1], b[i]), mat, hint)

    def obj(self, name, smooth=30.0):
        me = bpy.data.meshes.new(name)
        self.bm.normal_update()
        self.bm.to_mesh(me)
        self.bm.free()
        for m in self.mats:
            me.materials.append(m)
        o = bpy.data.objects.new(name, me)
        bpy.context.scene.collection.objects.link(o)
        o["gwf_smooth"] = float(smooth)
        return o


def _area3(pts):
    n = Vector((0, 0, 0))
    for a, b in zip(pts, pts[1:] + pts[:1]):
        n += a.cross(b)
    return n.length / 2


def area2(poly):
    return abs(sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(poly, poly[1:] + poly[:1]))) / 2


# ------------------------------------------------------------------------------------------------ clipping
def clip_rect(poly, x0, x1, y0, y1):
    """Sutherland-Hodgman: a polygon [(u, v), ...] clipped to the rectangle [x0, x1] x [y0, y1]. Exact for
    convex polygons and for orthogonally convex ones (drips, streaks: every horizontal / vertical line meets
    them once), which is all the decals here are."""
    def clip(pts, inside, cut):
        out = []
        for i, p in enumerate(pts):
            q = pts[i - 1]
            pin, qin = inside(p), inside(q)
            if pin:
                if not qin:
                    out.append(cut(q, p))
                out.append(p)
            elif qin:
                out.append(cut(q, p))
        return out

    def cx(x):
        return lambda a, b: (x, a[1] + (b[1] - a[1]) * (x - a[0]) / (b[0] - a[0]))

    def cy(y):
        return lambda a, b: (a[0] + (b[0] - a[0]) * (y - a[1]) / (b[1] - a[1]), y)
    pts = list(poly)
    for inside, cut in ((lambda p: p[0] >= x0, cx(x0)), (lambda p: p[0] <= x1, cx(x1)),
                        (lambda p: p[1] >= y0, cy(y0)), (lambda p: p[1] <= y1, cy(y1))):
        if not pts:
            return []
        pts = clip(pts, inside, cut)
    return pts if len(pts) >= 3 and area2(pts) > 1e-6 else []


def clip_convex(poly, convex):
    """Sutherland-Hodgman against a convex polygon (any winding)."""
    cw = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(convex, convex[1:] + convex[:1])) < 0
    pts = list(poly)
    for a, b in zip(convex, convex[1:] + convex[:1]):
        if not pts:
            return []

        def side(p, a=a, b=b):
            c = (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0])
            return -c if cw else c

        out = []
        for i, p in enumerate(pts):
            q = pts[i - 1]
            sp, sq = side(p), side(q)
            if sp >= 0:
                if sq < 0:
                    t = sq / (sq - sp)
                    out.append((q[0] + (p[0] - q[0]) * t, q[1] + (p[1] - q[1]) * t))
                out.append(p)
            elif sq >= 0:
                t = sq / (sq - sp)
                out.append((q[0] + (p[0] - q[0]) * t, q[1] + (p[1] - q[1]) * t))
        pts = out
    return pts if len(pts) >= 3 and area2(pts) > 1e-6 else []


def blob(cx, cy, rx, ry, seed, n=14, wob=0.16):
    """A wobbly ellipse (stain, peel patch, splash) as a polygon, counter-clockwise."""
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        r = 1.0 + wob * math.sin(3 * a + seed) + wob * 0.6 * math.sin(5 * a + 2.3 * seed) \
            + wob * 0.35 * math.sin(7 * a + 0.7 * seed)
        pts.append((cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)))
    return pts


def drip(x, top, length, w, seed=0.0, bulb=1.5):
    """A paint / rust drip hanging from `top` down by `length`: a tapering run with a round bulb at its end.
    Orthogonally convex (clips cleanly)."""
    pts = []
    n = 5
    for i in range(n + 1):                      # left side going down
        t = i / n
        hw = w / 2 * (1.0 - 0.45 * t) * (1 + 0.1 * math.sin(seed + 3 * t))
        pts.append((x - hw, top - length * t))
    bw = w / 2 * 0.55 * bulb
    base = top - length
    for k in range(1, 6):                       # the bulb
        a = math.pi + math.pi * k / 6
        pts.append((x + bw * math.cos(a), base + bw * 0.9 * math.sin(a)))
    for i in range(n, -1, -1):                  # right side going up
        t = i / n
        hw = w / 2 * (1.0 - 0.45 * t) * (1 + 0.1 * math.sin(seed + 1.7 + 3 * t))
        pts.append((x + hw, top - length * t))
    return pts


def streak(x, top, length, w_top, w_bot, seed=0.0, n=8, wander=0.03):
    """A long wavy stain running down a wall (rust, water): wide at the source, thin at the bottom."""
    left, right = [], []
    for i in range(n + 1):
        t = i / n
        c = x + wander * math.sin(seed + 2.6 * t) * t
        hw = (w_top + (w_bot - w_top) * t) / 2 * (1 + 0.15 * math.sin(seed * 1.3 + 7 * t))
        z = top - length * t
        left.append((c - hw, z))
        right.append((c + hw, z))
    return left + right[::-1]


def crack_quads(points, w):
    """A crack along a polyline as small quads of width w (each convex, clips cleanly)."""
    out = []
    for a, b in zip(points, points[1:]):
        d = Vector((b[0] - a[0], b[1] - a[1]))
        if d.length < 1e-6:
            continue
        n = Vector((-d.y, d.x)).normalized() * (w / 2)
        ext = d.normalized() * (w * 0.4)       # overlap a little so the joints close
        a2 = (a[0] - ext.x, a[1] - ext.y)
        b2 = (b[0] + ext.x, b[1] + ext.y)
        out.append([(a2[0] - n.x, a2[1] - n.y), (b2[0] - n.x, b2[1] - n.y), (b2[0] + n.x, b2[1] + n.y),
                    (a2[0] + n.x, a2[1] + n.y)])
    return out


def zigzag(x0, y0, x1, y1, n, amp, seed):
    """Points of a jagged line from (x0, y0) to (x1, y1)."""
    pts = []
    for i in range(n + 1):
        t = i / n
        off = 0.0 if i in (0, n) else amp * math.sin(seed + i * 2.39) * (1 if i % 2 else -1)
        dx, dy = x1 - x0, y1 - y0
        ln = math.hypot(dx, dy) or 1.0
        pts.append((x0 + dx * t - dy / ln * off, y0 + dy * t + dx / ln * off))
    return pts


# ------------------------------------------------------------------------------------------- materials
def arch_mats():
    """The architecture palette: library first (STYLE 12 factory palette), a few value steps as customs."""
    return {
        "concrete": lib("concrete"),                                # blocks, floor slab
        "concrete_dark": lib("concrete_dark"),                      # mortar, joints, skirting, deck
        "olive": lib("olive"),                                      # painted dado
        "metal_dark": lib("metal_dark"),                            # beams, grates, bolts, brackets
        "rust": lib("rust"),
        "dark": lib("dark"),                                        # cracks
        "void": lib("void"),                                        # holes
        "caution": lib("caution"),
        # value steps (explicit, not gradients: MODELING 7)
        "block_dark": material("block_dark", "#8c897f", "matte"),   # older / damp blocks
        "block_light": material("block_light", "#a8a598", "matte"),  # replaced blocks, bare patches
        "olive_dark": material("olive_dark", "#5b6447", "matte"),   # the painted band + dado mortar + drips
        "stain": material("stain", "#8a877c", "matte"),             # water / grime stains on concrete
        "stain_deep": material("stain_deep", "#7b786e", "matte"),   # the damp core of a stain
        "oil": material("oil", "#6c6961", "matte"),                 # oil stains on the floor
        "grime": material("grime", "#56544e", "matte"),             # scuffs on the dark skirting, soot on the deck
        "rust_dim": material("rust_dim", "#7a5038", "matte"),       # rust on the dim ceiling (toned down)
    }
