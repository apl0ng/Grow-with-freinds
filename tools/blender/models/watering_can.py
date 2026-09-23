"""watering_can: the factory's tired watering can (held item). Owner: item modeler.

kind "item": the spout (Blender -Y) points along Godot -Z, away from the holder, so the sight-glass gauge
on the back (Blender +Y -> Godot +Z) faces the player holding it. Floor mount, origin at the centre of the
base. ~0.37 x 0.41 x 0.53 m (W x H x nose-to-gauge).
Look: galvanized tin under chipped olive paint; rolled base rim gone to rust with rust creeping up the wall;
a long tapered spout with a braced rose head; a top carry handle with a rubber grip; a side pouring handle
(Blender -X, the holder's outer side); a peeling hazard sticker on the +X side (faces the screen centre in
first person); a filler neck on top; two dents. Nothing shiny, nothing new.

Instanced AS `Visual` in scenes/items/watering_can.tscn. Nodes watering_can.gd drives (keep the names):
  Can                one mesh: body, rims, handles, spout, rose, sticker, gauge frame
  WaterTop           water disc in the filler neck (shown while charges > 0; the dark neck shows when empty)
  Gauge / Fill       sight glass on the back. Gauge = bottom of the glass; Fill is centred on its own node
                     and GAUGE_HEIGHT (0.16 m) tall at scale 1: the script sets Fill.scale.y = charges /
                     capacity and Fill.position.y = 0.16 * fill / 2, so the water bar grows from the bottom.
"""
import bmesh
import bpy
from mathutils import Euler

from gwf import *

R0 = 0.15       # wall radius at the base
RT = 0.138      # wall radius at the shoulder seam
H = 0.25        # shoulder seam height
V = 24          # radial segments of the body (STYLE: 24+ for anything >= 0.3 m)
NECK = (0.0, 0.04)                                  # filler neck centre on the top (a little towards the back)
SPOUT_S = Vector((0.0, -0.1, 0.05))                 # spout axis start (inside the body, low at the front)
SPOUT_D = Vector((0.0, -0.64, 0.77)).normalized()   # up and forwards (-Y)
SPOUT_L = 0.27
SPOUT_ROT = (math.degrees(math.asin(-SPOUT_D.y)), 0.0, 0.0)  # rotates local +Z onto SPOUT_D
GAUGE_H = 0.16  # == WateringCan.GAUGE_HEIGHT
GAUGE_Z = 0.05  # bottom of the glass


def wall_r(z):
    t = max(0.0, min(1.0, z / H))
    return R0 + (RT - R0) * t + 0.006 * math.sin(math.pi * t)


def on_wall(deg, z, extra=0.0):
    """A point on the wall, `deg` degrees around from the front (-Y) towards +X."""
    a = math.radians(deg)
    r = wall_r(z) + extra
    return Vector((r * math.sin(a), -r * math.cos(a), z))


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


def wall_patch(name, deg, width_deg, z0, z1, nu, nv, thick, mat, lift=None):
    """A thin closed shell hugging the wall (stickers): centred `deg` around from the front, u across
    (towards +deg), v up. lift(u, v) -> extra outward offset (peeling corners)."""
    outer, inner = [], []
    for j in range(nv + 1):
        for i in range(nu + 1):
            u, v = i / nu, j / nv
            z = z0 + (z1 - z0) * v
            a = deg - width_deg / 2 + width_deg * u
            base = on_wall(a, z)
            n = Vector((base.x, base.y, 0.0)).normalized()
            k = lift(u, v) if lift else 0.0
            inner.append(base + n * (k - 0.001))
            outer.append(base + n * (k + thick))
    count = (nu + 1) * (nv + 1)
    idx = lambda i, j: j * (nu + 1) + i  # noqa: E731
    faces = []
    for j in range(nv):
        for i in range(nu):
            a, b, c, d = idx(i, j), idx(i + 1, j), idx(i + 1, j + 1), idx(i, j + 1)
            faces.append((a, b, c, d))
            faces.append((d + count, c + count, b + count, a + count))
    ring = [idx(i, 0) for i in range(nu)] + [idx(nu, j) for j in range(nv)] + \
        [idx(i, nv) for i in range(nu, 0, -1)] + [idx(0, j) for j in range(nv, 0, -1)]
    for k in range(len(ring)):
        p, q = ring[k], ring[(k + 1) % len(ring)]
        faces.append((q, p, p + count, q + count))
    return mesh_obj(name, outer + inner, faces, mat, smooth=50.0)


def spout_point(t):
    return SPOUT_S + SPOUT_D * t


def on_axis(local, origin):
    """Local coords of a part built along +Z, turned onto the spout axis and moved to `origin`."""
    rot = Matrix.Rotation(math.radians(SPOUT_ROT[0]), 3, 'X')
    return Vector(origin) + rot @ Vector(local)


def build():
    olive = lib("olive")        # tired army-surplus paint over the tin
    tin = lib("metal")          # galvanized: rims, handles, spout, rose, gauge frame
    rust = lib("rust")
    dark = lib("dark")
    water = lib("water")

    # --- Body: one lathe, rounded shoulder into a low dome. The base corner hides under the rolled rim.
    prof = [(0.0, 0.014), (R0 - 0.012, 0.014)]
    prof += [(wall_r(z), z) for z in (0.03, 0.065, 0.1, 0.135, 0.17, 0.205, H)]
    prof += [(RT - 0.006, H + 0.012), (0.114, H + 0.027), (0.07, H + 0.039), (0.0, H + 0.044)]
    body = lathe(prof, verts=V, mat=olive, name="body", smooth=48)
    dent(body, on_wall(40, 0.19), radius=0.075, depth=0.02)        # knocked on the front-right shoulder
    low_dent = on_wall(-150, 0.07)
    dent(body, low_dent, radius=0.06, depth=0.013)                 # kicked, low at the back-left

    # Rust creeping up from the floor (wavy top), the rolled base rim rusted through.
    rust_band = band(wall_r, 0.026, 0.05, thickness=0.0025, verts=20, rows=1, mat=rust, name="rust_band",
                     top=lambda a: 0.03 * max(0.0, math.sin(3 * a + 0.8)) + 0.012 * math.sin(7 * a + 0.2))
    dent(rust_band, low_dent, radius=0.06, depth=0.013)
    rim_bot = torus(R0 - 0.003, 0.016, pos=(0, 0, 0.016), major_segments=20, minor_segments=4, mat=rust,
                    name="rim_bottom")
    rim_top = torus(RT + 0.001, 0.011, pos=(0, 0, H + 0.003), major_segments=V, minor_segments=4, mat=tin,
                    name="rim_top")

    # Chipped paint: two bare-tin flakes.
    chips = []
    for k, (deg, z, s) in enumerate(((118, 0.16, 1.0), (-62, 0.12, 0.8))):
        pts = [(s * (0.02 + 0.007 * math.sin(3.1 * i + k)) * math.cos(i * math.tau / 7),
                s * (0.016 + 0.006 * math.cos(2.3 * i + k)) * math.sin(i * math.tau / 7)) for i in range(7)]
        p = on_wall(deg, z)
        n = Vector((p.x, p.y, 0)).normalized()
        chips.append(extrude_profile(pts, 0.004, pos=p + n * 0.002, rot=(0, 0, deg), bevel=0, mat=tin,
                                     name="chip"))

    # --- Filler neck on top: rolled lip ring (closed lathe shell), dark inside; the water is its own node.
    nx, ny = NECK
    neck_prof = [(0.043, H + 0.02), (0.043, H + 0.06), (0.05, H + 0.069), (0.06, H + 0.066), (0.06, H + 0.055),
                 (0.054, H + 0.048), (0.056, H + 0.02)]
    neck = lathe(neck_prof, verts=14, closed=True, pos=(nx, ny, 0), mat=tin, name="neck", smooth=60)
    hole = cyl(0.045, 0.004, verts=12, pos=(nx, ny, H + 0.034), bevel=0, mat=dark, name="neck_dark")

    # --- Top carry handle over the neck, rubber grip on top, riveted feet.
    handle = pipe([(0, -0.112, H + 0.012), (0, -0.098, H + 0.142), (0, 0.078, H + 0.152), (0, 0.118, H + 0.012)],
                  0.016, verts=12, bend=0.06, mat=tin, name="handle")
    slope = math.degrees(math.atan2(0.01, 0.176))
    grip_prof = [(0.0, 0.0), (0.02, 0.004), (0.025, 0.022), (0.022, 0.052), (0.025, 0.082), (0.02, 0.1),
                 (0.0, 0.104)]
    grip = lathe(grip_prof, verts=12, pos=(0, -0.064, H + 0.1425), rot=(-90 + slope, 0, 0), mat=dark,
                 name="grip", smooth=60)
    feet = [sphere(0.024, pos=(0, y, H + 0.024), scale=(1.0, 1.25, 0.55), segments=10, rings=5, mat=tin,
                   name="foot") for y in (-0.108, 0.113)]

    # --- Side pouring handle on the -X side (the holder's outer side).
    r_hi, r_lo = wall_r(0.215), wall_r(0.075)
    side = pipe([(-r_hi + 0.012, 0, 0.217), (-r_hi - 0.058, 0, 0.206), (-r_lo - 0.062, 0, 0.098),
                 (-r_lo + 0.012, 0, 0.073)], 0.014, verts=12, bend=0.045, mat=tin, name="side_handle")

    # --- Spout: tapered tube low on the front, a collar where it enters, a brace, the rose head.
    spout = cyl(0.033, SPOUT_L, verts=16, pos=SPOUT_S, rot=SPOUT_ROT, radius_top=0.021, bevel=0.004, mat=tin,
                name="spout")
    collar = cyl(0.043, 0.05, verts=16, pos=spout_point(0.03), rot=SPOUT_ROT, radius_top=0.039, bevel=0.005,
                 mat=tin, name="collar")
    paint(collar, rust, lambda c, n: c.z > 0.04 and n.z > 0.5)  # the collar's lip has rusted
    brace = pipe([spout_point(0.15) + Vector((0, 0.004, -0.004)), on_wall(0, 0.222, -0.006)], 0.009, verts=8,
                 mat=tin, name="brace")
    # Rose: funnel, rolled rim, domed face with a few holes. Knocked 6 degrees off the spout axis.
    tip = spout_point(SPOUT_L - 0.008)
    rose_prof = [(0.02, 0.0), (0.03, 0.02), (0.047, 0.041), (0.056, 0.05), (0.06, 0.056),
                 (0.058, 0.062), (0.05, 0.064), (0.03, 0.068), (0.0, 0.07)]
    rose_rot = (SPOUT_ROT[0] + 6.0, 0.0, 4.0)
    rose = lathe(rose_prof, verts=16, pos=tip, rot=rose_rot, mat=tin, name="rose", smooth=55)
    rr = Euler(tuple(math.radians(a) for a in rose_rot), 'XYZ').to_matrix()
    holes = []
    for k in range(5):
        if k == 0:
            local = Vector((0.0, 0.0, 0.0682))
        else:
            a = math.radians(40 + 90 * (k - 1))
            local = Vector((0.03 * math.cos(a), 0.03 * math.sin(a), 0.0662))
        holes.append(cyl(0.0075, 0.004, verts=6, pos=tip + rr @ local, rot=rose_rot, bevel=0, mat=dark,
                         name="hole"))

    # --- Hazard sticker on the +X side, top corner peeling off: cream plate, caution diamond, ink "!".
    SD, SW, SZ0, SZ1 = 80.0, 46.0, 0.095, 0.205

    def peel(u, v):
        k = max(0.0, (u - 0.55) / 0.45 + (v - 0.5) / 0.5 - 1.0)
        return 0.028 * k * k

    sticker = wall_patch("sticker", SD, SW, SZ0, SZ1, 5, 3, 0.003, lib("cream"), lift=peel)
    zc = 0.5 * (SZ0 + SZ1) - 0.004
    c = on_wall(SD - 5, zc, 0.004)  # the diamond sits a little away from the peeling corner
    n = Vector((c.x, c.y, 0)).normalized()
    diamond = extrude_profile([(0, -0.036), (0.036, 0), (0, 0.036), (-0.036, 0)], 0.016, pos=c - n * 0.008,
                              rot=(0, 0, SD - 5), bevel=0.005, mat=lib("caution"), name="diamond")
    front = c + n * 0.009
    bang = box((0.012, 0.01, 0.03), pos=front + Vector((0, 0, -0.006)), rot=(0, 0, SD - 5), bevel=0, mat=dark,
               name="bang")
    dot = box((0.012, 0.01, 0.01), pos=front + Vector((0, 0, -0.021)), rot=(0, 0, SD - 5), bevel=0, mat=dark,
              name="dot")

    # --- Sight-glass gauge frame on the back (+Y). The glass channel is dark; Fill is a separate node.
    yb = wall_r(0.21) - 0.004
    frame = box((0.07, 0.03, 0.2), pos=(0, yb + 0.015, 0.032), bevel=0.012, mat=tin, name="gauge_frame")
    channel = box((0.048, 0.006, 0.174), pos=(0, yb + 0.03, 0.045), bevel=0, mat=dark, name="gauge_glass")
    y_fill = yb + 0.033

    can = join([body, rust_band, rim_bot, rim_top] + chips + [neck, hole, handle, grip] + feet + [side] +
               [spout, collar, brace, rose] + holes + [sticker, diamond, bang, dot, frame, channel],
               "Can")

    water_top = cyl(0.044, 0.004, verts=12, pos=(nx, ny, H + 0.047), bevel=0, mat=water, name="WaterTop")
    water_top = join([water_top], "WaterTop", origin=(nx, ny, H + 0.047))

    gauge = empty("Gauge", pos=(0, y_fill, GAUGE_Z))
    fill = box((0.034, 0.012, GAUGE_H), pos=(0, y_fill, GAUGE_Z + GAUGE_H / 2), bevel=0.005, mat=water, name="Fill",
               anchor="center")
    fill = join([fill], "Fill", origin=(0, y_fill, GAUGE_Z + GAUGE_H / 2))
    set_parent(fill, gauge)

    export([can, water_top, gauge], "watering_can", kind="item", mount="floor", budget=3000)
