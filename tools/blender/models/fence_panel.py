"""fence_panel family: the grow area's tired chain-link fence (room decor, environment modeler).

  fence_panel      2.5 x 2.3 x 0.2 m, floor. One galvanised post at its LEFT end (-X) only; the rails end in
                   clamp collars at +X that wrap the NEXT panel's post, so a run of panels (or a panel meeting a
                   gate post) never has two posts in the same spot (no z-fighting). Chain-link as a low-tri
                   diamond lattice of square wires, bellied a little, rust creeping up from the floor, the
                   bottom-right corner torn loose and curling out. Collider stays the scene's 2.5 x 2.2 x 0.1 box.
                   scenes/world/props/fence_panel.tscn (the model is instanced AS `Visual`).
  fence_gate       5.15 x 3.3 x 0.3 m, floor. The room's 5 m gate frame: two fat posts (they swallow the
                   neighbouring panels' posts), a top bar, hinge knuckles and the "GROW AREA / AUTHORIZED
                   WORKERS ONLY" caution plate sitting on the bar (the words are a Label3D in the scene).
                   scenes/world/props/fence_gate.tscn.
  fence_gate_leaf  2.5 x 2.1 x 0.1 m, kind "part", origin ON THE HINGE AXIS at floor level (rotate the node about
                   Y to swing it). Pipe frame + lattice + brace, sagging towards its drag wheel. The gate scene
                   hangs two of them, folded back open against the fence.
Front = Blender -Y (Godot +Z) like every room prop.
"""
import bpy
import bmesh
from gwf import *

POST_R = 0.05          # fence post radius (Godot placeholder: 0.1 m posts)
GATE_POST_R = 0.075    # gate posts swallow a fence post + its rail collars (r 0.062)
TOP_Z = 2.18           # top rail axis
BOT_Z = 0.1            # bottom rail axis
HALF = 1.25            # half panel width
WIRE = 0.018           # chain-link wire (square section)


# ------------------------------------------------------------------------------------------------ helpers
def mesh_obj(name, bm, mat, smooth=35.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    if mat is not None:
        me.materials.append(lib(mat) if isinstance(mat, str) else mat)
    return obj


def strut(bm, points, w):
    """Square-section wire through `points` into bmesh `bm`, one flat face towards the front (-Y)."""
    pts = [Vector(p) for p in points]
    h = w / 2
    front = Vector((0, -1, 0))
    rings = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        n1 = (front - t * front.dot(t)).normalized()
        n2 = t.cross(n1)
        rings.append([bm.verts.new(p + n1 * a + n2 * b) for a, b in ((h, h), (h, -h), (-h, -h), (-h, h))])
    for a, b in zip(rings, rings[1:]):
        for k in range(4):
            bm.faces.new((a[k], a[(k + 1) % 4], b[(k + 1) % 4], b[k]))
    bm.faces.new(rings[0])
    bm.faces.new(list(reversed(rings[-1])))


def lattice(x0, x1, z0, z1, pitch=0.2, slope=1.25, segs=3, name="wires", mat="chainlink", phase=0.0, split=None):
    """Chain-link diamonds: two families of straight wires z = +-slope * x + c clipped to the rectangle,
    each split into `segs` pieces so it can belly / tear. Diamonds are `pitch` wide, slope * pitch tall.
    `split(x)` -> z: every wire also gets a vertex where it crosses that line (clean paint() boundaries)."""
    bm = bmesh.new()
    for s in (slope, -slope):
        corners = [(x, z) for x in (x0, x1) for z in (z0, z1)]
        cs = [z - s * x for x, z in corners]
        step = pitch * abs(s)       # c spacing so neighbouring wires are `pitch` apart horizontally
        k0 = math.ceil((min(cs) - phase * step) / step)
        k1 = math.floor((max(cs) - phase * step) / step)
        for k in range(k0, k1 + 1):
            c = k * step + phase * step
            # x range where z0 <= s*x + c <= z1, inside [x0, x1]
            xa, xb = (z0 - c) / s, (z1 - c) / s
            lo, hi = max(x0, min(xa, xb)), min(x1, max(xa, xb))
            if hi - lo < 0.03:
                continue
            n = segs if hi - lo > 0.4 else 1
            xs = [lo + (hi - lo) * i / n for i in range(n + 1)]
            if split is not None:
                g = lambda x: s * x + c - split(x)
                m = 48
                for i in range(m):
                    a, b = lo + (hi - lo) * i / m, lo + (hi - lo) * (i + 1) / m
                    if g(a) * g(b) < 0:
                        for _ in range(30):
                            mid = (a + b) / 2
                            a, b = (a, mid) if g(a) * g(mid) <= 0 else (mid, b)
                        xm = (a + b) / 2
                        if min(abs(xm - x) for x in xs) > 0.02:
                            xs.append(xm)
                xs.sort()
            strut(bm, [(x, 0.0, s * x + c) for x in xs], WIRE)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth=30.0)


def post(x, r, height, cap_r, plate, name, rust_top=0.28, seed=0.0):
    """A galvanised pipe post on a bolted base plate, dome cap, rust creeping up from the floor."""
    parts = [
        box((plate, plate, 0.022 if r < 0.06 else 0.034), pos=(x, 0, 0), bevel=0.005, mat="metal_dark",
            name=name + "_plate"),
        cyl(r, height, verts=16 if r < 0.06 else 20, pos=(x, 0, 0.01), bevel=0.006, mat="chainlink", name=name),
        lathe([(0.0, height - 0.005), (cap_r, height - 0.005), (cap_r, height + 0.03), (cap_r * 0.85, height + 0.06),
               (cap_r * 0.45, height + 0.08), (0.0, height + 0.085)], verts=16, pos=(x, 0, 0), mat="metal_dark",
              name=name + "_cap"),
        band(r, 0.03, rust_top, thickness=0.003, verts=16, rows=1, pos=(x, 0, 0), mat="rust", name=name + "_rust",
             top=lambda a: 0.07 * math.sin(2 * a + seed) + 0.03 * math.sin(5 * a + 1.7 + seed)),
    ]
    d = plate / 2 - 0.028
    top = 0.022 if r < 0.06 else 0.034
    for sx in (-1, 1):
        for sy in (-1, 1):
            if sx == sy:   # 2 bolts on the diagonal
                continue
            parts.append(cyl(0.017, 0.022, verts=6, pos=(x + sx * d, sy * d, top), bevel=0, mat="metal_dark",
                             name=name + "_bolt"))
    return parts


def collar(x, z, r, name):
    """Rail clamp band around a post (a short fat ring)."""
    return cyl(r, 0.05, verts=12, pos=(x, 0, z - 0.025), bevel=0.005, mat="metal_dark", name=name)


# ------------------------------------------------------------------------------------------------- models
def fence_panel():
    reset()
    parts = post(-HALF, POST_R, 2.24, 0.06, 0.2, "post", seed=0.4)
    # Rails: the top one sags a touch between the posts, the bottom one is a plain tension rail.
    top = pipe(sag_points((-HALF, 0, TOP_Z), (HALF, 0, TOP_Z), sag=0.018, n=6), 0.028, verts=8, mat="chainlink",
               name="top_rail")
    bot = pipe([(-HALF, 0, BOT_Z), (HALF, 0, BOT_Z)], 0.022, verts=8, mat="chainlink", name="bottom_rail")
    collars = [collar(sx * HALF, z, 0.062, "collar") for sx in (-1, 1) for z in (TOP_Z, BOT_Z)]
    # Chain-link diamonds between the posts.
    rust_line = lambda x: 0.32 + 0.1 * math.sin(6.0 * x + 0.7) + 0.05 * math.sin(15.0 * x)
    wires = lattice(-HALF + 0.05, HALF - 0.055, BOT_Z + 0.015, TOP_Z - 0.02, pitch=0.2, slope=1.25, segs=3,
                    split=rust_line)
    x0, x1, z0, z1 = -HALF, HALF, BOT_Z, TOP_Z
    tear = Vector((HALF - 0.06, BOT_Z))          # bottom-right corner, torn off the rail and curling out

    def sag(co):
        u = (co.x - x0) / (x1 - x0)
        v = (co.z - z0) / (z1 - z0)
        y = co.y - 0.035 * math.sin(math.pi * max(0, min(1, u))) * math.sin(math.pi * max(0, min(1, v)))
        z = co.z
        d = (Vector((co.x, co.z)) - tear).length
        if d < 0.62:
            k = (1 - d / 0.62) ** 2
            y -= 0.34 * k          # peeled towards the front
            z += 0.16 * k          # and curled up off the bottom rail
        return Vector((co.x, y, z))
    move_verts(wires, sag)
    # Rust creeping up the wire from the floor (a wavy line), everything else galvanised.
    paint(wires, "rust", lambda c, n: c.z < rust_line(c.x))
    fence = join(parts + [top, bot, wires] + collars, "Fence")
    export(fence, "fence_panel", kind="prop", mount="floor")


def fence_gate():
    reset()
    H = 2.62
    parts = []
    for sx, nm in ((-1, "post_l"), (1, "post_r")):
        parts += post(sx * 2.5, GATE_POST_R, H, 0.086, 0.28, nm, rust_top=0.34, seed=1.1 + sx)
        # Hinge knuckles on the front of each post (the leaves hang here), strapped round the post.
        for z in (0.36, 1.86):
            parts.append(cyl(0.03, 0.12, verts=12, pos=(sx * 2.5, -0.115, z - 0.01), bevel=0.005, mat="metal_dark",
                             name="knuckle"))
            parts.append(box((0.07, 0.07, 0.07), pos=(sx * 2.5, -0.075, z + 0.015), bevel=0.005,
                             mat="metal_dark", name="hinge_strap"))
        parts.append(collar(sx * 2.5, 2.52, 0.09, "tee"))
    bar = pipe([(-2.5, 0, 2.52), (2.5, 0, 2.52)], 0.05, verts=12, mat="chainlink", name="bar")
    # The caution plate sits on the bar on two U-brackets, a little crooked (cheap job).
    tilt = math.radians(-1.6)
    board = box((2.62, 0.04, 0.64), pos=(0, 0, 2.63), bevel=0.006, mat="caution", name="board")
    frame = box((2.74, 0.07, 0.76), pos=(0, 0, 2.57), bevel=0, mat="metal_dark", name="sign_frame")
    boolean_cut(frame, box((2.6, 0.2, 0.62), pos=(0, 0, 2.64), bevel=0, name="cut"))
    bevel(frame, 0.016, segments=2)
    frame = [frame]
    bolts = [cyl(0.022, 0.02, verts=6, pos=(sx * 1.22, -0.02, z), rot=(90, 0, 0), bevel=0, mat="metal_dark",
                 name="sign_bolt") for sx in (-1, 1) for z in (2.7, 3.18)]
    # Rust bleeding from the lower left bolt down the plate.
    drip = extrude_profile([(-1.245, 2.685), (-1.195, 2.685), (-1.205, 2.655), (-1.22, 2.642), (-1.235, 2.655)], 0.004,
                           pos=(0, -0.021, 0), bevel=0, mat="rust", name="sign_drip")
    sign = join([board, drip] + frame + bolts, "sign", origin=(0, 0, 2.58))
    sign.rotation_euler = (0, tilt, 0)
    brackets = []
    for sx in (-0.75, 0.75):
        brackets.append(box((0.1, 0.13, 0.05), pos=(sx, 0.0, 2.445), bevel=0.005, mat="metal_dark", name="clamp"))
        brackets.append(box((0.08, 0.05, 0.36), pos=(sx, 0.045, 2.47), bevel=0.005, mat="metal_dark", name="strut"))
    gate = join(parts + [bar, sign] + brackets, "Gate")
    export(gate, "fence_gate", kind="prop", mount="floor")


def fence_gate_leaf():
    reset()
    W, Z0, Z1 = 2.42, 0.13, 2.02
    droop = 0.045                      # the free end hangs lower than the hinge side (tired hinges)

    def sag(co):
        return Vector((co.x, co.y, co.z - droop * max(0.0, co.x) / W))
    frame = pipe([(0.07, 0, Z0), (W, 0, Z0), (W, 0, Z1), (0.07, 0, Z1)], 0.03, verts=8, bend=0.09,
                 mat="chainlink", name="frame", caps=True)
    stile = pipe([(0.07, 0, Z0 - 0.02), (0.07, 0, Z1 + 0.02)], 0.032, verts=8, mat="chainlink", name="stile")
    brace = pipe([(0.12, 0, Z0 + 0.05), (W - 0.06, 0, Z1 - 0.06)], 0.02, verts=6, mat="chainlink", name="brace")
    rust_line = lambda x: 0.3 + 0.08 * math.sin(5.0 * x + 2.0)
    wires = lattice(0.1, W - 0.03, Z0 + 0.02, Z1 - 0.02, pitch=0.2, slope=1.25, segs=2, phase=0.5, split=rust_line)
    move_verts(wires, lambda co: Vector((co.x, co.y - 0.02 * math.sin(math.pi * co.x / W), co.z)))
    paint(wires, "rust", lambda c, n: c.z < rust_line(c.x))
    # Hinge sleeves round the hinge axis (x = 0), strapped to the stile.
    hinge = []
    for z in (0.36, 1.86):
        for dz in (-0.075, 0.125):
            hinge.append(cyl(0.031, 0.07, verts=12, pos=(0, 0, z + dz), bevel=0.005, mat="metal_dark", name="sleeve"))
            hinge.append(box((0.1, 0.03, 0.05), pos=(0.045, 0, z + dz + 0.01), bevel=0.005, mat="metal_dark",
                             name="leaf_strap"))
    # A drag wheel under the free end (the droop has it scraping the floor).
    fork = box((0.05, 0.1, 0.1), pos=(W - 0.08, 0, 0.07), bevel=0.005, mat="metal_dark", name="fork")
    wheel = cyl(0.055, 0.035, verts=12, pos=(W - 0.08, 0.0, 0.055), rot=(90, 0, 0),
                bevel=0.01, mat="dark", name="wheel", anchor="center")
    for o in (frame, stile, brace, wires, fork):
        move_verts(o, sag)
    leaf = join([frame, stile, brace, wires, fork, wheel] + hinge, "Leaf")
    # Lift so the wheel stands on the floor.
    lo = min((leaf.matrix_world @ v.co).z for v in leaf.data.vertices)
    for v in leaf.data.vertices:
        v.co.z -= lo
    export(leaf, "fence_gate_leaf", kind="part", mount="free")


def build():
    fence_panel()
    fence_gate()
    fence_gate_leaf()
