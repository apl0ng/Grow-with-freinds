"""seed_packet: a crumpled paper seed packet (held item). Owner: item modeler.

kind "item": the model's front (Blender -Y) lands on Godot -Z, away from the holder. The PRINTED face (label
window, strain badge) is therefore modelled on Blender +Y, which lands on Godot +Z: the side the holder reads
(and the side scenes/items/seed_packet.tscn puts the NameLabel on). The back (Godot -Z, what other players see)
carries a riveted tin plate; its text is a Label3D in the scene ("PROPERTY OF THE BOSS").
Floor mount (stands on its bottom seam), origin under the centre. ~0.25 x 0.33 x 0.07 m.
Look: a puffy pouch of cheap paper, wrinkled and creased, one corner curling, the top folded into a crooked
serrated crimp held by two staples. Strain colour = TINT (the paper), set at runtime (Toon.grade(seed.color)).

Nodes (instanced AS `Visual/Packet` in the scene; seed_packet.gd drives them):
  Body        the paper pouch, ONE material (TINT_paper, matte): the script gives it a per-instance
              material_override in the graded strain colour
  Print       crimp (TINT shade 0.72), staples, label window, badge, fan-leaf pictogram, back plate, rivets
  Icon / Bud  the strain bud on the badge (TINT shade 0.8): Toonify tints it with the model's tint
"""
import bmesh
import bpy
from mathutils.bvhtree import BVHTree

from gwf import *

W = 0.232          # pouch width (x)
HB = 0.292         # pouch height (z), bottom seam on the floor
ZC = HB / 2
T_FRONT = 0.03     # half-thickness of the puff, printed side (+Y)
T_BACK = 0.024     # plain side (-Y)
LEAN = 0.018       # the top sits this much further along +X than the bottom (a tired shear, ~3.5 deg)
# Grid samples: dense near the seams so the pouch rounds off into a crisp paper edge.
US = [-1.0, -0.965, -0.88, -0.7, -0.42, -0.14, 0.14, 0.42, 0.7, 0.88, 0.965, 1.0]
VS = [-1.0, -0.965, -0.88, -0.7, -0.45, -0.2, 0.05, 0.3, 0.52, 0.7, 0.82, 0.92, 1.0]
BADGE = (0.0, 0.2)       # (u, v) of the badge centre
BADGE_R = 0.047
LABEL_UV = (-0.84, 0.84, -0.87, -0.26)   # label window u0, u1, v0, v1


def puff(u, v):
    """0..1 puffiness: flat plateau in the middle, round fall-off to the seams, pinched flat under the crimp."""
    f = max(0.0, 1.0 - abs(u) ** 2.6) ** 0.5
    g = max(0.0, 1.0 - abs(v) ** 4) ** 0.5
    if v > 0.55:  # the folded top is pressed flat
        s = min(1.0, (v - 0.55) / 0.27)
        g *= 1.0 - 0.9 * (s * s * (3 - 2 * s))
    return f * g


def crumple(u, v, side):
    """Wrinkles + a diagonal crease (metres, added to the half-thickness)."""
    w = 0.0035 * math.sin(5.3 * u + 2.1 * v + side) * math.sin(4.1 * v - 1.3 * u + 0.7 * side)
    d = (0.55 * u + 0.83 * v - 0.35)          # distance-ish to a fold line running down-left to up-right
    crease = -0.009 * math.exp(-(d / 0.11) ** 2)
    d2 = (0.9 * u - 0.43 * v + 0.62)          # a second, shorter crease near the -u edge
    crease += -0.006 * math.exp(-(d2 / 0.09) ** 2) * max(0.0, min(1.0, (0.3 - v) / 0.3))
    return (w + crease) * puff(u, v) ** 0.5


def sheet(u, v):
    """Offset of the whole sheet along y (both faces): a gentle cup and a wave, plus the curling corner."""
    y = 0.008 * u * u - 0.004 + 0.004 * math.sin(2.2 * v + 0.5)
    k = max(0.0, (u - 0.5) / 0.5 + (-v - 0.62) / 0.38 - 1.0)   # bottom corner at +u (the holder's left)
    return y + 0.05 * k * k, 0.012 * k * k


def surf(u, v, side):
    """A point on the printed (+1) or plain (-1) face."""
    t = (T_FRONT if side > 0 else T_BACK) * puff(u, v) + crumple(u, v, side)
    t = max(t, 0.0) if abs(u) < 1.0 and abs(v) < 1.0 else 0.0
    dy, dz = sheet(u, v)
    x = u * W / 2 + 0.0045 * math.sin(8.3 * v + 1.0) * abs(u) ** 3 + LEAN * (v + 1) / 2
    z = ZC + v * HB / 2 + dz + 0.0035 * math.sin(10.7 * u + 0.4) * abs(v) ** 3
    if v < 0:  # the bottom seam bows up in the middle: the packet stands on its two corners
        z += 0.007 * (1 - u * u) * (-v) ** 6
    return Vector((x, dy + side * t, z))


_BVH = []  # the Body's exact triangles (set by pouch()): printed parts are projected onto them


def surf_normal(u, v, side):
    """(normal, point) on the Body mesh itself (its triangles, not the smooth function), so thin printed
    patches never sink under a triangle that bridges a crease."""
    p0 = surf(u, v, side)
    hit = _BVH[0].ray_cast(Vector((p0.x, side * 0.3, p0.z)), Vector((0.0, -side, 0.0))) if _BVH else None
    if hit is None or hit[0] is None:
        return Vector((0.0, side, 0.0)), p0
    n = hit[1].normalized()
    return (n if n.y * side > 0 else -n), hit[0]


def mesh_obj(name, verts, faces, mat, smooth=40.0):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    me.update()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    me.materials.append(mat)
    return obj


def pouch(mat):
    """Two height fields sharing their border (the sealed seam)."""
    nu, nv = len(US), len(VS)
    verts, index = [], {}

    def vid(i, j, side):
        border = i in (0, nu - 1) or j in (0, nv - 1)
        key = (i, j, 0 if border else side)
        if key not in index:
            index[key] = len(verts)
            verts.append(surf(US[i], VS[j], side))
        return index[key]
    faces = []
    for side in (1, -1):
        for j in range(nv - 1):
            for i in range(nu - 1):
                a, b, c, d = vid(i, j, side), vid(i + 1, j, side), vid(i + 1, j + 1, side), vid(i, j + 1, side)
                # Explicit triangles (alternating diagonals): the export keeps them, the BVH matches them.
                tris = [(a, b, c), (a, c, d)] if (i + j) % 2 == 0 else [(a, b, d), (b, c, d)]
                faces += tris if side > 0 else [tuple(reversed(t)) for t in tris]
    _BVH[:] = [BVHTree.FromPolygons([tuple(v) for v in verts], faces)]
    return mesh_obj("Body", verts, faces, mat, smooth=38.0)


def print_patch(name, cells, uv_at, side, lift, thick, mat):
    """A thin closed shell printed on a face: uv_at(a, b) with a, b in 0..1 -> (u, v)."""
    na, nb = cells
    outer, inner = [], []
    for j in range(nb + 1):
        for i in range(na + 1):
            u, v = uv_at(i / na, j / nb)
            n, p = surf_normal(u, v, side)
            inner.append(p + n * (lift - 0.001))
            outer.append(p + n * (lift + thick))
    count = (na + 1) * (nb + 1)
    idx = lambda i, j: j * (na + 1) + i  # noqa: E731
    faces = []
    for j in range(nb):
        for i in range(na):
            a, b, c, d = idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1)
            faces.append((a, b, c, d))
            faces.append((d + count, c + count, b + count, a + count))
    ring = [idx(i, 0) for i in range(na)] + [idx(na, j) for j in range(nb)] + \
        [idx(i, nb) for i in range(na, 0, -1)] + [idx(0, j) for j in range(nb, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        faces.append((q, p, p + count, q + count))
    return mesh_obj(name, outer + inner, faces, mat, smooth=45.0)


def print_disc(name, centre, radius, segments, rings, side, thick, mat):
    """A round thin shell printed on a face (badges): a wrapped polar grid with a centre vertex."""
    cu, cv = centre
    ru, rv = radius / (W / 2), radius / (HB / 2)
    outer, inner = [], []

    def add(u, v):
        n, p = surf_normal(u, v, side)
        inner.append(p - n * 0.001)
        outer.append(p + n * thick)
    add(cu, cv)
    for j in range(1, rings + 1):
        for i in range(segments):
            a = math.tau * i / segments
            add(cu + ru * j / rings * math.cos(a), cv + rv * j / rings * math.sin(a))
    count = len(outer)
    ring = lambda j, i: 1 + (j - 1) * segments + i % segments  # noqa: E731
    faces = []
    for i in range(segments):
        faces.append((0, ring(1, i), ring(1, i + 1)))
        faces.append((ring(1, i + 1) + count, ring(1, i) + count, count))
        for j in range(1, rings):
            q = (ring(j, i), ring(j + 1, i), ring(j + 1, i + 1), ring(j, i + 1))
            faces.append(q)
            faces.append(tuple(x + count for x in reversed(q)))
        p, q = ring(rings, i), ring(rings, i + 1)
        faces.append((p, p + count, q + count, q))
    return mesh_obj(name, outer + inner, faces, mat, smooth=45.0)


def fan_leaf(size):
    """Outline of a five-finger fan leaf pictogram (u right, v up), stem at the bottom."""
    fingers = [(-66, 0.5), (-33, 0.78), (0, 1.0), (33, 0.78), (66, 0.5)]
    pts = []
    for k, (deg, ln) in enumerate(fingers):
        a = math.radians(deg)
        d = Vector((math.sin(a), math.cos(a)))
        p = Vector((math.cos(a), -math.sin(a)))
        L = size * ln
        pts += [tuple(d * 0.1 * L - p * 0.07 * L), tuple(d * 0.5 * L - p * 0.2 * L), tuple(d * L),
                tuple(d * 0.5 * L + p * 0.2 * L), tuple(d * 0.1 * L + p * 0.07 * L)]
    pts += [(0.012 * size, -0.12 * size), (0.03 * size, -0.42 * size), (-0.03 * size, -0.42 * size),
            (-0.012 * size, -0.12 * size)]
    return pts


def build():
    paper = tint_material("TINT_paper", finish="matte")
    crimp_mat = tint_material("TINT_crimp", shade=0.72, finish="matte")
    bud_mat = tint_material("TINT_bud", shade=0.8)
    cream = lib("cream")
    tin = lib("metal")

    body = pouch(paper)

    # --- Folded top: a crooked serrated crimp band pinching the flat top, two staples through it.
    teeth = 13
    z0, z1 = HB - 0.048, HB + 0.012
    outline = [(-0.124, 0.0), (0.124, 0.0)]
    for k in range(teeth * 2 + 1):
        x = 0.124 - 0.248 * k / (teeth * 2)
        outline.append((x, (z1 - z0) - (0.0 if k % 2 == 0 else 0.009)))
    crimp = extrude_profile(outline, 0.022, pos=(LEAN, 0.011, z0), rot=(0, -3.0, 0), bevel=0.004, mat=crimp_mat,
                            name="crimp")
    staples = []
    for x, tilt in ((0.072, 8.0), (-0.068, -4.0)):
        zs = z0 + 0.024 + x * math.sin(math.radians(3.0))  # follows the crimp's 3 degree tilt
        staples.append(capsule(0.0036, 0.036, pos=(x + LEAN, 0.0135, zs), rot=(0, 90 + tilt, 0), verts=8, rings=4,
                               mat=tin, name="staple", anchor="center"))

    # --- Printed face (+Y): cream label window (the NameLabel sits on it) and a round strain badge.
    lu0, lu1, lv0, lv1 = LABEL_UV
    window = print_patch("window", (12, 5), lambda a, b: (lu0 + (lu1 - lu0) * a, lv0 + (lv1 - lv0) * b), 1, 0.0012,
                         0.0022, cream)
    bu, bv = BADGE
    badge = print_disc("badge", BADGE, BADGE_R, 16, 2, 1, 0.0025, cream)
    n, c = surf_normal(bu, bv, 1)
    # Fan-leaf pictogram on the badge (flat print, raised 3 mm), built facing -Y and turned to face +Y.
    leaf = extrude_profile(fan_leaf(0.04), 0.003, pos=(c.x, c.y + 0.0012, c.z + 0.004), rot=(0, 0, 180), bevel=0,
                           mat=lib("leaf"), name="leaf_print")

    # --- Plain face (-Y): a tin plate riveted on crooked (its "PROPERTY OF THE BOSS" is a Label3D).
    pn, pc = surf_normal(0.0, 0.18, -1)
    plate_z = pc.z
    plate = box((0.17, 0.012, 0.062), pos=(pc.x, pc.y + 0.001, plate_z), rot=(0, 5.0, 0), bevel=0.006, mat=tin,
                name="plate", anchor="center")
    rivets = []
    for sx in (-1, 1):
        a = math.radians(5.0)
        x, z = pc.x + sx * 0.07 * math.cos(a), plate_z - sx * 0.07 * math.sin(a)
        rivets.append(sphere(0.0075, pos=(x, pc.y - 0.0055, z), scale=(1, 0.6, 1), segments=8, rings=4,
                             mat=lib("metal_dark"), name="rivet"))

    detail = join([crimp] + staples + [window, badge, leaf, plate] + rivets, "Print")

    icon = empty("Icon", pos=(c.x, c.y, c.z))
    bud = sphere(0.017, pos=(c.x, c.y + 0.006, c.z - 0.012), scale=(1.0, 0.55, 1.05), segments=12, rings=6,
                 mat=bud_mat, name="Bud")
    bud = join([bud], "Bud", origin=(c.x, c.y + 0.006, c.z - 0.012))
    set_parent(bud, icon)

    body = join([body], "Body")
    export([body, detail, icon], "seed_packet", kind="item", mount="floor", budget=3000)
    # Hook-up numbers for the scene (Godot coordinates: x = -x, y = z, z = y for kind "item").
    lab = surf(0.0, (lv0 + lv1) / 2, 1)
    top = max(surf(lu0 + (lu1 - lu0) * i / 8, lv0 + (lv1 - lv0) * j / 4, 1).y for i in range(9) for j in range(5))
    print("  seed_packet hookup: NameLabel at Godot (%.4f, %.4f, %.4f) (window surface max y %.4f); window %.3f x "
          "%.3f m; plate centre Godot (%.4f, %.4f, %.4f)" % (-lab.x, lab.z, top + 0.0055, top, (lu1 - lu0) * W / 2,
                                                             (lv1 - lv0) * HB / 2, -pc.x, plate_z, pc.y - 0.0055))
