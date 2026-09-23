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


def build():
    steel = lib("metal_dark")
    rust = lib("rust")
    ticking = lib("olive")                                    # army-surplus mattress
    grime = lib("concrete_dark")                              # damp stains, rubber feet
    pillow_mat = lib("cream")
    stain = material("stain_yellow", pal("LEAF_DRY"), "matte")  # the old yellowed pillow stain
    wool = material("blanket", pal("COOL_GRAY"), "matte")      # thin grey wool blanket
    parts = []

    # Frame: two side rails bent into end bars at the head end (one U tube) + a straight foot bar.
    hx = L / 2
    frame = pipe([(hx, -RAIL_Y, RAIL_Z), (-hx, -RAIL_Y, RAIL_Z), (-hx, RAIL_Y, RAIL_Z), (hx, RAIL_Y, RAIL_Z)],
                 TUBE, verts=12, bend=0.07, mat=steel, name="rails")
    foot = pipe([(hx - 0.01, -RAIL_Y - 0.02, RAIL_Z), (hx - 0.01, RAIL_Y + 0.02, RAIL_Z)], TUBE * 0.9, verts=12,
                mat=steel, name="foot_bar")
    parts += [frame, foot]
    # End caps on the open rail ends (rubber plugs).
    for sy in (-1, 1):
        parts.append(sphere(TUBE * 1.15, pos=(hx + 0.004, sy * RAIL_Y, RAIL_Z), segments=12, rings=6, mat=grime,
                            name="plug"))

    # Folding X-legs: two crossing tubes per leg (side by side in x), pinned where they cross, rubber feet.
    for i, lx in enumerate(LEGS_X):
        splay = (0.0, 0.03, -0.02)[i]   # the middle leg is bent a little
        for sy in (-1, 1):
            ox = sy * TUBE * 1.05
            top = Vector((lx + ox, sy * RAIL_Y, RAIL_Z - 0.01))
            foot_p = Vector((lx + ox + splay, -sy * RAIL_Y, TUBE * 0.9))
            parts.append(pipe([top, foot_p], TUBE * 0.85, verts=10, mat=steel, name="leg"))
            parts.append(sphere(0.042, pos=(foot_p.x, foot_p.y, 0.028), scale=(1, 1, 0.66), segments=12, rings=6,
                                mat=grime, name="foot"))
            # Rust creeping up from the foot (a sleeve on the lowest part of the leg).
            d = (top - foot_p).normalized()
            parts.append(pipe([foot_p + d * 0.03, foot_p + d * 0.16], TUBE * 0.85 + 0.004, verts=10, mat=rust,
                              name="leg_rust"))
        # Pivot bolt through both tubes where they cross.
        parts.append(cyl(0.03, 0.13, verts=10, pos=(lx + splay * 0.5 - 0.065, 0.0, RAIL_Z * 0.5), rot=(0, 90, 0),
                         bevel=0.008, mat=steel, name="pin"))
    # Rust patches on the rails (sleeves slightly fatter than the tube, uneven lengths).
    for x0, x1, sy in ((-0.62, -0.38, -1), (0.28, 0.4, -1), (0.55, 0.9, 1), (-0.9, -0.7, 1)):
        parts.append(pipe([(x0, sy * RAIL_Y, RAIL_Z), (x1, sy * RAIL_Y, RAIL_Z)], TUBE + 0.004, verts=12,
                          mat=rust, name="rail_rust"))

    # Mattress: a soft slab that sags between the rails (subdivided box bent along x), grime stains.
    mz = RAIL_Z + TUBE * 0.4
    matt = box((M_L, M_W, M_T), pos=(0, 0, 0), bevel=0, mat=ticking, name="mattress")
    subdivide_axis(matt, 0, 7)
    subdivide_axis(matt, 1, 2)
    move_verts(matt, lambda c: Vector((c.x, c.y * (1.0 - 0.03 * (c.z / M_T)), c.z + sag_z(c.x)
                                       - 0.012 * (1 - (2 * c.y / M_W) ** 2) * (c.z / M_T))))
    bevel(matt, 0.03, segments=2)
    matt.location = (0.0, 0.0, mz)
    parts.append(matt)
    # Stains: thin blotches lying on the mattress top, following the sag.
    def blotch(cx, cy, rx, ry, seed, mat, lift=0.0):
        pts = []
        for k in range(14):
            a = 2 * math.pi * k / 14
            r = 1.0 + 0.2 * math.sin(3 * a + seed) + 0.1 * math.sin(5 * a + 2 * seed)
            pts.append((cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)))
        b = extrude_profile(pts, 0.003, rot=(-90, 0, 0), bevel=0, mat=mat, name="stain")
        apply_transform(b)
        subdivide(b, 2)
        move_verts(b, lambda c: Vector((c.x, c.y, c.z + mz + M_T - 0.0005 + sag_z(c.x) + lift
                                        - 0.012 * (1 - min(1.0, (2 * c.y / M_W) ** 2)))))
        return b
    parts.append(blotch(0.12, 0.08, 0.2, 0.13, 0.5, grime))
    parts.append(blotch(0.42, -0.2, 0.09, 0.06, 2.1, grime))

    # Pillow: squashed flat and dented where the head goes, a yellowed stain, a little crooked.
    px, pz = -0.68, mz + M_T + sag_z(-0.68) - 0.012
    pillow = sphere(0.3, segments=20, rings=10, mat=pillow_mat, name="pillow")
    move_verts(pillow, lambda c: Vector((c.x * 0.58, c.y * 0.98, max(-0.3, min(0.3, c.z)) * 0.16)))
    dent(pillow, (0.03, 0.02, 0.05), radius=0.16, depth=0.025, direction=(0, 0, -1))
    # The old yellowed stain, painted on the top faces off to one side.
    paint(pillow, stain, lambda c, n: n.z > 0.2 and ((c.x - 0.07) / 0.09) ** 2 + ((c.y + 0.1) / 0.13) ** 2 < 1.0)
    pillow.matrix_world = Matrix.Translation((px, 0.01, pz + 0.042)) @ Matrix.Rotation(math.radians(-7), 4, 'Z') \
        @ Matrix.Rotation(math.radians(3), 4, 'X')
    apply_transform(pillow)
    parts.append(pillow)

    # Blanket: kicked into a heap at the foot end (3 squashed, jittered lumps) + a flap hanging over the
    # back rail, draped down the side.
    bx = 0.58
    top_z = mz + M_T + sag_z(bx)
    for (dx, dy, rx, ry, rz, yaw) in ((0.0, 0.02, 0.26, 0.3, 0.075, 12), (0.14, -0.12, 0.2, 0.2, 0.065, -20),
                                      (-0.12, 0.14, 0.18, 0.22, 0.055, 30)):
        lump = sphere(1.0, segments=16, rings=8, mat=wool, name="lump")
        move_verts(lump, lambda c, rx=rx, ry=ry, rz=rz: Vector((c.x * rx, c.y * ry, c.z * rz
                                                                  + 0.25 * rz * math.sin(c.x * 5 + c.y * 3))))
        jitter(lump, 0.008, seed=int(abs(dx * 100)) + 3)
        lump.matrix_world = Matrix.Translation((bx + dx, dy, top_z + rz * 0.55)) @ Matrix.Rotation(
            math.radians(yaw), 4, 'Z')
        apply_transform(lump)
        parts.append(lump)
    # Flap: a thin sheet that lies on the mattress edge, rolls over the back rail and hangs down.
    fx0, fx1, n = 0.35, 0.78, 8
    thick = 0.014
    flap = grid_slab("flap", 6, 16, fx1 - fx0, 0.5, thick, wool)

    def drape(c):
        # Sheet coords: u along x, s along the sheet (0..0.12 on the mattress, a quarter roll of radius R over
        # the mattress edge, then hanging down outside the rail); t = offset through the thickness.
        u = c.x
        s = c.y + 0.25
        t = c.z
        wave = 0.008 * math.sin(u * 22 + s * 9)
        edge_y, R = M_W / 2, 0.045
        z0 = top_z + 0.004
        xc = u + (fx0 + fx1) / 2
        if s < 0.12:
            return Vector((xc, edge_y - 0.12 + s, z0 + t + wave * (s / 0.12)))
        arc = R * math.pi / 2
        if s < 0.12 + arc:
            a = (s - 0.12) / R
            return Vector((xc, edge_y + (R + t) * math.sin(a), z0 - R + (R + t) * math.cos(a) + wave))
        down = s - 0.12 - arc
        return Vector((xc + 0.04 * down, edge_y + R + t + 0.03 * down + wave * 0.6, z0 - R - down + wave))
    move_verts(flap, drape)
    set_smooth(flap, 60)
    parts.append(flap)

    cot = join(parts, "cot")
    # A little crooked on the floor (the whole cot turned 1.5 deg).
    cot.matrix_world = Matrix.Rotation(math.radians(1.5), 4, 'Z')
    apply_transform(cot)
    export(cot, "cot", kind="prop", mount="floor")
