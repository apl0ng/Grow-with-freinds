"""cot: a rusty folding camp cot with a thin stained mattress, a flat pillow and a rumpled blanket.

Room decor (the workers sleep at the factory). Floor mount, ~1.94 x 0.64 x 0.86 m, inside the
2.0 x 0.6 x 0.8 box collider of scenes/world/props/cot.tscn (the blanket flap hangs a few cm past the
frame at the back). Long axis = X, the pillow at the -X end; the front (Blender -Y) is a long side.
Build: two side rails + end bars (steel tube), three folding X-legs with rubber feet, a sagging
mattress, a pillow squashed flat, a blanket kicked into a heap at the foot end with a flap hanging
over the back rail.
Sad: rust patches on the tubes and legs, a mattress that sags in the middle, damp/grime stains, a
yellowed pillow stain, one leg splayed a little, the whole thing a bit crooked.
"""
from gwf import *
import bmesh
import bpy

L = 1.94            # rail length (x)
RAIL_Y = 0.35       # side rails at y = +-RAIL_Y
RAIL_Z = 0.36       # rail centre height
TUBE = 0.026        # tube radius (5 cm: reads at 6 m)
LEGS_X = (-0.8, 0.02, 0.8)
M_L, M_W, M_T = 1.84, 0.72, 0.085     # mattress
SAG = 0.045
MZ = RAIL_Z + TUBE * 0.4      # mattress bottom


def subdivide_axis(obj, axis, cuts):
    """Split only the edges parallel to one axis (0 x, 1 y, 2 z) into cuts + 1: a box gets strips / grids
    where it bends, instead of a dense grid on every face."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    edges = []
    for e in bm.edges:
        d = e.verts[1].co - e.verts[0].co
        if abs(d[axis]) > 1e-6 and all(abs(d[k]) < 1e-6 for k in range(3) if k != axis):
            edges.append(e)
    bmesh.ops.subdivide_edges(bm, edges=edges, cuts=cuts, use_grid_fill=True)
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def grid_slab(name, nx, ny, sx, sy, thick, mat, smooth=60.0):
    """A thin closed slab (sx x sy x thick, centred on the origin) with an nx x ny grid on its two big
    faces and single strips round the edges: cloth, sheets, flaps to bend with move_verts()."""
    verts, faces = [], []

    def vid(i, j, k):
        return (k * (ny + 1) + j) * (nx + 1) + i
    for zt in (thick / 2, -thick / 2):
        for j in range(ny + 1):
            for i in range(nx + 1):
                verts.append((-sx / 2 + sx * i / nx, -sy / 2 + sy * j / ny, zt))
    for j in range(ny):
        for i in range(nx):
            faces.append((vid(i, j, 0), vid(i + 1, j, 0), vid(i + 1, j + 1, 0), vid(i, j + 1, 0)))
            faces.append((vid(i, j, 1), vid(i, j + 1, 1), vid(i + 1, j + 1, 1), vid(i + 1, j, 1)))
    for i in range(nx):
        faces.append((vid(i, 0, 0), vid(i, 0, 1), vid(i + 1, 0, 1), vid(i + 1, 0, 0)))
        faces.append((vid(i, ny, 0), vid(i + 1, ny, 0), vid(i + 1, ny, 1), vid(i, ny, 1)))
    for j in range(ny):
        faces.append((vid(0, j, 0), vid(0, j + 1, 0), vid(0, j + 1, 1), vid(0, j, 1)))
        faces.append((vid(nx, j, 0), vid(nx, j, 1), vid(nx, j + 1, 1), vid(nx, j + 1, 0)))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    me.materials.append(mat)
    set_smooth(obj, smooth)
    return obj


def sag_z(x):
    """Mattress/canvas dip along x: 0 at the ends, SAG in the middle."""
    u = max(-1.0, min(1.0, x / (M_L / 2)))
    return -SAG * (1 - u * u)


def mattress_top(x, y):
    """World z of the mattress top surface at (x, y) (before its bevel rounds the edges)."""
    return MZ + M_T + sag_z(x) - 0.012 * (1 - min(1.0, (2 * y / M_W) ** 2))


def build():
    steel = lib("metal_dark")
    rust = lib("rust")
    ticking = lib("olive")                                    # army-surplus mattress
    grime = lib("concrete_dark")                              # damp stains, rubber feet
    pillow_mat = lib("cream")
    stain = material("stain_yellow", pal("LEAF_DRY"), "matte")  # the old yellowed pillow stain
    wool = material("blanket", pal("COOL_GRAY"), "matte")      # thin grey wool blanket
    parts = []

    # Frame: the side rails bent into an end bar at the head (one U tube) + a straight foot bar.
    hx = L / 2
    parts.append(pipe([(hx, -RAIL_Y, RAIL_Z), (-hx, -RAIL_Y, RAIL_Z), (-hx, RAIL_Y, RAIL_Z), (hx, RAIL_Y, RAIL_Z)],
                      TUBE, verts=20, bend=0.07, mat=steel, name="rails"))
    parts.append(pipe([(hx - 0.012, -RAIL_Y - 0.015, RAIL_Z), (hx - 0.012, RAIL_Y + 0.015, RAIL_Z)], TUBE * 0.9,
                      verts=16, mat=steel, name="foot_bar"))
    for sy in (-1, 1):   # rubber plugs on the open rail ends
        parts.append(cyl(TUBE * 1.15, 0.03, verts=12, pos=(hx - 0.004, sy * RAIL_Y, RAIL_Z), rot=(0, 90, 0),
                         bevel=0, mat=grime, name="plug"))

    # Folding X-legs: two crossing tubes per leg (side by side in x), pinned where they cross, rubber feet.
    for i, lx in enumerate(LEGS_X):
        splay = (0.0, 0.035, -0.02)[i]   # the middle leg is bent a little
        for sy in (-1, 1):
            ox = sy * TUBE * 1.05
            top = Vector((lx + ox, sy * RAIL_Y, RAIL_Z - 0.01))
            foot_p = Vector((lx + ox + splay, -sy * RAIL_Y, TUBE * 0.9))
            parts.append(pipe([top, foot_p], TUBE * 0.85, verts=16, mat=steel, name="leg"))
            parts.append(cyl(0.04, 0.035, verts=12, pos=(foot_p.x, foot_p.y, 0.0), radius_top=0.03, bevel=0,
                             mat=grime, name="foot"))
            # Rust creeping up from the foot (a sleeve on the lowest part of the leg).
            d = (top - foot_p).normalized()
            parts.append(pipe([foot_p + d * 0.04, foot_p + d * (0.17 + 0.03 * sy)], TUBE * 0.85 + 0.004, verts=16,
                              mat=rust, name="leg_rust"))
        # Pivot bolt through both tubes where they cross.
        parts.append(cyl(0.026, 0.12, verts=12, pos=(lx + splay * 0.5 - 0.06, 0.0, RAIL_Z * 0.5), rot=(0, 90, 0),
                         bevel=0, mat=steel, name="pin"))
    # Rust patches on the rails (sleeves slightly fatter than the tube, uneven lengths).
    for x0, x1, sy in ((-0.62, -0.38, -1), (0.28, 0.4, -1), (0.55, 0.9, 1), (-0.9, -0.7, 1)):
        parts.append(pipe([(x0, sy * RAIL_Y, RAIL_Z), (x1, sy * RAIL_Y, RAIL_Z)], TUBE + 0.004, verts=20,
                          mat=rust, name="rail_rust"))

    # Mattress: a soft slab that sags between the rails (a box split into strips along x), grime stains.
    matt = box((M_L, M_W, M_T), pos=(0, 0, 0), bevel=0, mat=ticking, name="mattress")
    subdivide_axis(matt, 0, 7)
    subdivide_axis(matt, 1, 2)
    move_verts(matt, lambda c: Vector((c.x, c.y * (1.0 - 0.03 * (c.z / M_T)), c.z + sag_z(c.x)
                                       - 0.012 * (1 - (2 * c.y / M_W) ** 2) * (c.z / M_T))))
    bevel(matt, 0.03, segments=2)
    matt.location = (0.0, 0.0, MZ)
    parts.append(matt)

    def blotch(cx, cy, rx, ry, seed, mat):
        pts = []
        for k in range(14):
            a = 2 * math.pi * k / 14
            r = 1.0 + 0.2 * math.sin(3 * a + seed) + 0.1 * math.sin(5 * a + 2 * seed)
            pts.append((cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)))
        b = extrude_profile(pts, 0.003, rot=(-90, 0, 0), bevel=0, mat=mat, name="stain")
        apply_transform(b)
        move_verts(b, lambda c: Vector((c.x, c.y, c.z + mattress_top(c.x, c.y) - 0.0005)))
        return b
    parts.append(blotch(0.05, 0.1, 0.2, 0.13, 0.5, grime))
    parts.append(blotch(-0.28, -0.2, 0.09, 0.06, 2.1, grime))

    # Pillow: a rounded-square cushion (a sphere pushed out to a superellipse: thin seams, a soft middle),
    # squashed flat and dented where the head goes, the old yellowed stain, a little crooked.
    px = -0.66
    pz = mattress_top(px, 0.0) - 0.006
    pillow = sphere(1.0, segments=16, rings=8, mat=pillow_mat, name="pillow")

    def cushion(c):
        sx = math.copysign(abs(c.x) ** 0.45, c.x)
        sy = math.copysign(abs(c.y) ** 0.45, c.y)
        puff = (1 - 0.35 * (sx * sx + sy * sy))
        return Vector((sx * 0.2, sy * 0.3, c.z * 0.05 * puff))
    move_verts(pillow, cushion)
    dent(pillow, (0.02, 0.03, 0.05), radius=0.17, depth=0.022, direction=(0, 0, -1))
    paint(pillow, stain, lambda c, n: n.z > 0.2 and ((c.x - 0.08) / 0.075) ** 2 + ((c.y + 0.11) / 0.11) ** 2 < 1.0)
    pillow.matrix_world = Matrix.Translation((px, 0.01, pz + 0.03)) @ Matrix.Rotation(math.radians(-8), 4, 'Z') \
        @ Matrix.Rotation(math.radians(3), 4, 'X')
    apply_transform(pillow)
    parts.append(pillow)

    # Blanket: one thin wool sheet kicked down to the foot end: rumpled into folds on the mattress, its
    # front edge rolled up, the back part sliding over the mattress edge and hanging down outside the rail.
    bx0, bx1 = 0.26, 0.9
    thick = 0.016
    R = 0.045                                # roll over the mattress edge
    top_len = M_W - 0.08                     # sheet length lying on top (from the front edge to the back edge)
    arc = R * math.pi / 2
    total = top_len + arc + 0.2
    sheet = grid_slab("blanket", 9, 18, bx1 - bx0, total, thick, wool)

    def rumple(u, s):
        """Fold height (>= 0) on the mattress: ridges across the sheet, a heap towards the foot."""
        k = (u + 0.32) / 0.64                               # 0 at the head side of the sheet .. 1 at the foot
        ridge = math.sin(11 * u + 4.0 * s + 0.6) ** 2 * 0.045 + math.sin(19 * u - 7 * s) ** 2 * 0.015
        heap = 0.07 * math.exp(-((k - 0.72) / 0.25) ** 2) * math.exp(-((s - 0.3) / 0.28) ** 2)
        curl = 0.03 * math.exp(-s / 0.05)                   # front edge rolled up
        fade = min(1.0, (top_len - s) / 0.1)                 # flat where it slides over the edge
        return (ridge * min(1.0, k * 2.5) + heap) * max(0.0, fade) + curl

    def drape(c):
        u, s, t = c.x, c.y + total / 2, c.z
        x = u + (bx0 + bx1) / 2
        if s < top_len:
            y = -M_W / 2 + 0.04 + s
            return Vector((x, y, mattress_top(x, y) + 0.004 + thick / 2 + rumple(u, s) + t))
        edge_y = -M_W / 2 + 0.04 + top_len
        z0 = mattress_top(x, edge_y) + 0.004 + thick / 2
        if s < top_len + arc:
            a = (s - top_len) / R
            return Vector((x, edge_y + (R + t) * math.sin(a), z0 - R + (R + t) * math.cos(a)))
        down = s - top_len - arc
        wave = 0.01 * math.sin(u * 20 + down * 8)
        return Vector((x + 0.05 * down, edge_y + R + t + 0.05 * down + wave, z0 - R - down))
    move_verts(sheet, drape)
    parts.append(sheet)

    cot = join(parts, "cot")
    # A little crooked on the floor (the whole cot turned 1.5 deg).
    cot.matrix_world = Matrix.Rotation(math.radians(1.5), 4, 'Z')
    apply_transform(cot)
    export(cot, "cot", kind="prop", mount="floor")
