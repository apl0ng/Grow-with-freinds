"""product_bundle: the harvest, bagged (held item). Owner: item modeler.

kind "item": the front (Blender -Y) lands on Godot -Z, away from the holder; the torn, taped side is on the
back (Blender +Y -> Godot +Z) so the holder sees product poking out of the hole. Floor mount, origin at
the centre of the base. ~0.42 x 0.35 x 0.35 m at amount 1 (product.gd scales the whole model with amount).
Look: a lumpy bundle of cheap slate plastic, slumped to one side, gathered into a twisted neck with a tin
twist tie, a crooked band of cream packing tape round the belly, a torn hole taped over badly; strain-coloured
buds (TINT) push out of the neck and the tear, with a few dried sugar leaves. Grim, not appetizing.

Nodes (instanced AS `Visual/Cluster` in scenes/items/product.tscn; product.gd drives them):
  Cluster (root)  product.gd scales it by amount (1 + 0.15 per extra unit, max 1.6): origin on the floor
  Bag             plastic, tape, tear, tie, dry leaves (Toonify materials)
  Buds / Bud0     every bud in ONE mesh, one material (TINT_bud): product.gd gives it a per-instance
                  material_override in Toon.grade(seed.color)
"""
import bmesh
import bpy
from mathutils.bvhtree import BVHTree

from gwf import *

# Bag profile (r, z) before the deformation: flat base, belly, gathered neck, a twisted knot of plastic on top.
PROF = [(0.0, 0.0), (0.11, 0.003), (0.158, 0.02), (0.178, 0.052), (0.182, 0.095), (0.172, 0.138), (0.146, 0.178),
        (0.108, 0.21), (0.072, 0.235), (0.05, 0.255), (0.046, 0.268), (0.062, 0.288), (0.063, 0.31),
        (0.05, 0.334), (0.028, 0.352), (0.0, 0.357)]
NECK_Z = 0.262
# Lumps: product pressing against the plastic (angle deg from the front towards +X, z, outward amount, radius).
LUMPS = [(20, 0.115, 0.028, 0.07), (95, 0.07, 0.022, 0.065), (168, 0.135, 0.03, 0.075), (248, 0.1, 0.024, 0.07),
         (318, 0.16, 0.022, 0.06), (62, 0.18, 0.02, 0.055), (205, 0.05, 0.02, 0.06), (130, 0.2, 0.016, 0.05),
         (285, 0.045, 0.018, 0.06), (345, 0.07, 0.02, 0.06)]
TEAR = (150.0, 0.19)   # the big torn hole (angle, z): upper back shoulder, the side the holder looks at
TEAR2 = (-4.0, 0.165)  # a small one on the front shoulder (what other players see)


def prof_r(z):
    """Profile radius at height z on the outer (lower) part of the profile."""
    pts = PROF[:12]
    for (r0, z0), (r1, z1) in zip(pts, pts[1:]):
        if z0 <= z <= z1:
            t = (z - z0) / max(z1 - z0, 1e-6)
            return r0 + (r1 - r0) * t
    return pts[-1][0]


def _lump_points():
    out = []
    for deg, z, amt, rad in LUMPS:
        a = math.radians(deg)
        r = prof_r(z)
        out.append((Vector((r * math.sin(a), -r * math.cos(a), z)), amt, rad))
    return out


LUMP_PTS = _lump_points()


def deform(co):
    """Undeformed lathe space -> the tired bundle. Used for every part that hugs the bag."""
    x, y, z = co.x, co.y, co.z
    r = math.hypot(x, y)
    a = math.atan2(x, -y)  # 0 = front (-Y), +pi/2 = +X
    # Lumps push outwards (horizontally).
    push = 0.0
    for p, amt, rad in LUMP_PTS:
        d = (Vector((x, y, z)) - p).length
        if d < rad * 2.0:
            push += amt * math.exp(-(d / rad) ** 2)
    # Folds of plastic converging on the gathered neck, a twist and a ruffled mouth above it.
    s = max(0.0, min(1.0, (z - 0.05) / 0.2))
    wp = s * s * (3 - 2 * s)
    fold = math.sin(7 * a + 0.9 * math.sin(3 * a + 0.4))
    w = max(0.0, min(1.0, (z - 0.2) / 0.06))
    if z <= NECK_Z:
        dr = 0.028 * wp * fold * (1.0 - 0.4 * w)
    else:
        dr = 0.3 * r * fold
    twist = 1.7 * max(0.0, (z - NECK_Z) / 0.09)
    a2 = a + twist
    r2 = (r + dr + push * (1.0 - w)) if r > 1e-6 else 0.0
    nx, ny = r2 * math.sin(a2), -r2 * math.cos(a2)
    # Oval, slumped towards -X (Godot +X: the holder's outer side, away from the crosshair), the neck and the
    # knot flopping further.
    nx *= 1.1
    ny *= 0.88
    nx -= 0.016 * (z / 0.3) ** 2 + 0.022 * max(0.0, (z - 0.2) / 0.1) ** 2 + 0.03 * max(0.0, (z - 0.255) / 0.08) ** 2
    return Vector((nx, ny, z))


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


def bag_bvh(obj):
    me = obj.data
    return BVHTree.FromPolygons([tuple(v.co) for v in me.vertices], [tuple(p.vertices) for p in me.polygons])


def on_bag(bvh, deg, z):
    """(point, normal) where a horizontal ray from outside at angle `deg`, height z hits the bag."""
    a = math.radians(deg)
    d = Vector((math.sin(a), -math.cos(a), 0.0))
    hit = bvh.ray_cast(Vector((0.0, 0.0, z)) + d * 0.6 + Vector((0.03, 0, 0)), -d)
    if hit[0] is None:
        return Vector((0.0, 0.0, z)), d
    n = hit[1].normalized()
    return hit[0], (n if n.dot(d) > 0 else -n)


def bag_patch(name, bvh, deg0, deg1, z0, z1, na, nb, thick, mat, lift=0.0012, shape=None):
    """A thin shell stuck on the bag between angles deg0..deg1 and heights z0..z1 (tape, tears).
    shape(a, b) -> (a, b) remaps the unit square (skewed tape strips, jagged holes)."""
    outer, inner = [], []
    for j in range(nb + 1):
        for i in range(na + 1):
            a, b = i / na, j / nb
            if shape:
                a, b = shape(a, b)
            p, n = on_bag(bvh, deg0 + (deg1 - deg0) * a, z0 + (z1 - z0) * b)
            inner.append(p + n * (lift - 0.0015))
            outer.append(p + n * (lift + thick))
    count = (na + 1) * (nb + 1)
    idx = lambda i, j: j * (na + 1) + i  # noqa: E731
    faces = []
    for j in range(nb):
        for i in range(na):
            q = (idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1))
            faces.append(q)
            faces.append(tuple(x + count for x in reversed(q)))
    ring = [idx(i, 0) for i in range(na)] + [idx(na, j) for j in range(nb)] + \
        [idx(i, nb) for i in range(na, 0, -1)] + [idx(0, j) for j in range(nb, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        faces.append((q, p, p + count, q + count))
    return mesh_obj(name, outer + inner, faces, mat, smooth=50.0)


def cola(base, r, direction, seed=1, mat=None):
    """A chunky bud: a fat lumpy base and a smaller tip growing along `direction` (two smooth spheres)."""
    a = sphere(r, pos=base, scale=(1.0, 1.0, 1.15), segments=12, rings=7, mat=mat, name="bud")
    tip = Vector(base) + Vector(direction).normalized() * r
    b = sphere(r * 0.66, pos=tip, scale=(1.0, 1.0, 1.25), segments=10, rings=6, mat=mat, name="bud")
    for o, k in ((a, 0), (b, 1)):  # nodules: a soft bumpy pattern (object-local: the centre is the origin)
        rr = r if k == 0 else r * 0.66
        move_verts(o, lambda co, rr=rr, k=k: co + co.normalized() * rr * 0.1 *
                   math.sin(5.0 * math.atan2(co.y, co.x) + 3.0 * co.z / rr + seed + k) if co.length > 1e-6 else co)
    return [a, b]


def build():
    plastic = material("trash_plastic", "#4e585e", "glossy")   # factory metal_dark hex: cheap slate sheeting
    tape_mat = lib("cream")
    tin = lib("metal")
    dark = lib("dark")
    dry = lib("leaf_dry")
    bud_mat = tint_material("TINT_bud", finish="soft")

    bag = lathe(PROF, verts=28, mat=plastic, name="bag_shell", smooth=60)
    move_verts(bag, deform)
    bvh = bag_bvh(bag)

    # Packing tape round the belly, crooked, following the lumps (built on the lathe, then deformed alike).
    tape = band(prof_r, 0.085, 0.118, thickness=0.005, verts=28, rows=2, mat=tape_mat, name="tape",
                bottom=lambda a: 0.022 * math.sin(a + 0.6), top=lambda a: 0.022 * math.sin(a + 0.6) + 0.003 *
                math.sin(5 * a))
    move_verts(tape, deform)

    def jag(a, b):  # a jagged oval inside the unit square (torn plastic)
        ang = a * math.tau
        rr = b * (0.74 + 0.26 * math.sin(5 * ang + 1.0))
        return 0.5 + 0.5 * rr * math.cos(ang), 0.5 + 0.5 * rr * math.sin(ang)

    # Tears: dark holes the product pushes out of; a strip of tape slapped across the big one's lower edge.
    td, tz = TEAR
    hole = bag_patch("tear", bvh, td - 24, td + 24, tz - 0.045, tz + 0.04, 10, 1, 0.001, dark, shape=jag)
    td2, tz2 = TEAR2
    hole2 = bag_patch("tear", bvh, td2 - 13, td2 + 13, tz2 - 0.028, tz2 + 0.028, 8, 1, 0.001, dark, shape=jag)
    strip = bag_patch("tape_strip", bvh, td - 34, td + 22, tz - 0.058, tz - 0.03, 6, 1, 0.0035, tape_mat,
                      shape=lambda a, b: (a, b + 0.8 * (a - 0.5)))

    # Twist tie on the neck + its twisted ends.
    neck_c = deform(Vector((0.0, 0.0, NECK_Z)))
    tie = torus(0.054, 0.0075, pos=(neck_c.x, neck_c.y, NECK_Z), major_segments=16, minor_segments=4,
                mat=tin, name="tie", scale=(1.1, 0.9, 1.0))
    ends = pipe([(neck_c.x + 0.056, neck_c.y - 0.02, NECK_Z), (neck_c.x + 0.083, neck_c.y - 0.034, NECK_Z + 0.012),
                 (neck_c.x + 0.104, neck_c.y - 0.03, NECK_Z - 0.004)],
                0.006, verts=8, bend=0.01, mat=tin, name="tie_ends")

    # Buds pushing out of the tears (ONE mesh, ONE material), dried sugar leaves between them.
    up = Vector((0, 0, 1))
    b, leaves = [], []
    for k, (dd, dz, r) in enumerate(((0.0, 0.0, 0.044), (-15.0, -0.016, 0.035), (14.0, 0.014, 0.032))):
        p, n = on_bag(bvh, td + dd, tz + dz)
        b += cola(p + n * 0.004, r, n + up * 0.55, seed=k + 3, mat=bud_mat)
    p, n = on_bag(bvh, td2, tz2)
    b += cola(p + n * 0.002, 0.033, n + up * 0.3, seed=9, mat=bud_mat)
    for dd, dz, spin in ((-22.0, 0.012, 35.0), (20.0, -0.02, -40.0)):
        p, n = on_bag(bvh, td + dd, tz + dz)
        yaw = math.degrees(math.atan2(n.x, -n.y))
        leaves.append(sphere(0.03, pos=p + n * 0.02, rot=(spin, 0, yaw), scale=(1.5, 0.22, 0.5), segments=8,
                             rings=5, mat=dry, name="leaf"))
    p, n = on_bag(bvh, td2 + 12, tz2 + 0.01)
    leaves.append(sphere(0.024, pos=p + n * 0.016, rot=(-30, 0, math.degrees(math.atan2(n.x, -n.y))),
                         scale=(1.4, 0.22, 0.5), segments=8, rings=5, mat=dry, name="leaf"))

    bag_obj = join([bag, tape, hole, hole2, strip, tie, ends] + leaves, "Bag")
    buds_mesh = join(b, "Bud0")
    buds = empty("Buds", pos=(0, 0, 0))
    set_parent(buds_mesh, buds)

    export([bag_obj, buds], "product_bundle", kind="item", mount="floor", budget=3000)
