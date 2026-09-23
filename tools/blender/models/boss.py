"""boss: the shady Boss behind the supply cage (kind "character": front -> Godot -Z). Rigged: instanced AS
`Visual` in scenes/world/shopkeeper_npc.tscn, so every path shopkeeper_npc.gd animates stays valid.

~1.2 x 1.92 x 1.1 m (W x H x D, Godot), floor mount, origin at the feet. Heavy-set in a cheap brown suit that
can't close over the belly (the stained shirt bursts out), a loosened maroon tie hanging crooked, a thick
tarnished gold chain, a dented charcoal fedora knocked crooked, low gold-rimmed shades with heavy-lidded,
scowling eyes glaring over them, bushy angry brows, a boozer's nose, stubble, a permanent frown with a cigar
clamped in the corner. Both hands rest on the counter: the right drums its fat fingers, the left lies palm up
("pay up"); the cash wad for cheer() appears in that palm.

Rig (Godot names; pivot = node origin; the script sets absolute rotations on the nodes marked *):
  <Visual, Toonify> / FootLeft, FootRight                         trousers + cheap shiny shoes (static)
                    / Torso *                                     suit, shirt, tie, chain (origin at the floor,
                                                                  the breathing bob moves its y)
                        / ArmLeft, ArmRight                       sleeves, pivot at the shoulder; REST rotation
                                                                  (72, -+12, 0) deg = reaching onto the counter
                                                                  (the script records it and beckons from it)
                            / Hand                                (Hand__L / Hand__R) rest (-72, 0, 0): level
                              ArmLeft/Hand / Cash / TopBill *     wad (hidden until cheer), top bill flips on z
                              ArmRight/Hand / Fingers / Finger1..4 *  knuckle pivots, tap on x (rest 0)
                        / HeadPivot *                             head (origin at the neck; yaw/pitch, rest 0)
                            / EyeLeft, EyeRight / Pupil           eye whites + pupils
                                              / LidLeft, LidRight *  heavy lids, REST (-12, 0, -+15) deg (a
                                                                  scowl; the script records it and blinks to x -88)
                            / Sunglasses, Hat, Cigar              static extras
Everything is authored in Godot coordinates (x = the Boss's right, y up, -z = his front) through g() / place().
"""
import bpy
import bmesh
from gwf import *

# Godot <-> Blender for kind="character": Blender (x, y, z) -> Godot (-x, z, y) (the export's 180 degree turn
# + glTF's y-up), and back: it is its own inverse.
M4 = Matrix(((-1, 0, 0, 0), (0, 0, 1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
V = 28   # radial segments for the big round parts

# Factory palette (STYLE.md section 12): not Toon constants.
METAL_DARK = "#4e585e"


def g(x, y, z):
    """A Godot-space point/vector as a Blender Vector."""
    return Vector((-x, z, y))


def gmat(pos=(0, 0, 0), rot=(0, 0, 0)):
    """Godot local transform: translation + rotation in degrees with Godot's YXZ Euler order."""
    rx, ry, rz = (math.radians(a) for a in rot)
    basis = Matrix.Rotation(ry, 4, 'Y') @ Matrix.Rotation(rx, 4, 'X') @ Matrix.Rotation(rz, 4, 'Z')
    return Matrix.Translation(Vector(pos)) @ basis


def mix(a, b, t):
    ca = [int(a.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    cb = [int(b.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join("%02x" % round(x + (y - x) * t) for x, y in zip(ca, cb))


def place(obj, world_g):
    """Give `obj` (geometry authored in its node's local frame, Blender axes) the Godot world transform."""
    obj.matrix_world = M4 @ world_g @ M4
    return obj


def scale_about(objs, pivot_g, k):
    """Uniformly scale a node subtree (objs parents-first) about a Godot point, baked: meshes are scaled in
    place and node positions spread out, rotations stay as they are, no node gets a scale."""
    bpy.context.view_layer.update()
    pivot = g(*pivot_g)
    worlds = [o.matrix_world.copy() for o in objs]
    for o in objs:
        if o.type == 'MESH':
            o.data.transform(Matrix.Scale(k, 4))
            o.data.update()
    for o, mw in zip(objs, worlds):
        new = mw.copy()
        new.translation = pivot + (mw.translation - pivot) * k
        o.matrix_world = new
        bpy.context.view_layer.update()


def place_baked(obj, parent_g, pos, rot):
    """A static extra: bake its local rotation `rot` (Godot degrees) into the mesh, so the node itself only
    has a translation (tight bounds; nothing animates it)."""
    obj.data.transform(M4 @ gmat((0, 0, 0), rot) @ M4)
    obj.data.update()
    return place(obj, parent_g @ gmat(pos))


def mesh_obj(name, bm, mat=None, smooth=40.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    if mat is not None:
        me.materials.append(mat)
    return obj


def shell(fn, nu, nv, name, mat, smooth=50.0, solid=True):
    """Thin solid from a parametric patch: fn(u, v) -> (outer, inner) Godot points, u, v in 0..1.
    solid=False: only the outer surface (for patches lying flat on the body: the rest is never seen)."""
    bm = bmesh.new()
    out = [[bm.verts.new(g(*fn(i / nu, j / nv)[0])) for j in range(nv + 1)] for i in range(nu + 1)]
    if not solid:
        for i in range(nu):
            for j in range(nv):
                bm.faces.new((out[i][j], out[i + 1][j], out[i + 1][j + 1], out[i][j + 1]))
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        obj = mesh_obj(name, bm, mat, smooth)
        return obj
    inn = [[bm.verts.new(g(*fn(i / nu, j / nv)[1])) for j in range(nv + 1)] for i in range(nu + 1)]
    for i in range(nu):
        for j in range(nv):
            bm.faces.new((out[i][j], out[i + 1][j], out[i + 1][j + 1], out[i][j + 1]))
            bm.faces.new((inn[i][j + 1], inn[i + 1][j + 1], inn[i + 1][j], inn[i][j]))
    for i in range(nu):
        for j in (0, nv):
            bm.faces.new((out[i][j], inn[i][j], inn[i + 1][j], out[i + 1][j]))
    for j in range(nv):
        for i in (0, nu):
            bm.faces.new((out[i][j], out[i][j + 1], inn[i][j + 1], inn[i][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth)


def along(obj, d):
    """Rotate a builder part (made along Blender +Z) so its axis points along the Godot direction d."""
    obj.rotation_euler = Vector((0, 0, 1)).rotation_difference(g(*d).normalized()).to_euler()
    return obj


def gsphere(r, pos, scale=(1, 1, 1), segments=16, rings=8, mat=None, name="sphere"):
    """Sphere at a Godot position, scaled along Godot axes."""
    return sphere(r, pos=g(*pos), scale=(scale[0], scale[2], scale[1]), segments=segments, rings=rings, mat=mat,
                  name=name)


def lerp(a, b, t):
    return a + (b - a) * t


def smooth01(t):
    t = max(0.0, min(1.0, t))
    return t * t * (3 - 2 * t)


# ============================================================================================== torso
DEPTH = 0.86     # the round body is a little flatter front-to-back
JACKET = [(0.40, 0.30), (0.47, 0.335), (0.53, 0.41), (0.56, 0.52), (0.565, 0.64), (0.55, 0.76), (0.515, 0.88),
          (0.485, 0.97), (0.475, 1.04), (0.45, 1.1), (0.38, 1.16), (0.27, 1.21), (0.15, 1.235), (0.0, 1.245)]


def jacket_r(y):
    for (r0, y0), (r1, y1) in zip(JACKET, JACKET[1:]):
        if y0 <= y <= y1:
            return lerp(r0, r1, (y - y0) / (y1 - y0))
    return 0.0


def jacket_point(a, y, off=0.0):
    """Godot point on the jacket surface, a radians round from the front (-Z) towards +X (his right)."""
    r = jacket_r(y) + off
    return (r * math.sin(a), y, -r * math.cos(a) * DEPTH)


BELLY_C = (0.0, 0.62, -0.12)          # the gut the suit can't close over
BELLY_R = (0.42, 0.36, 0.44)
# Half width (Godot x) of the jacket's opening, by height: a V down to the button point, then the belly bursts
# the jacket open down to the hem.
OPENING = [(0.3, 0.2), (0.4, 0.23), (0.55, 0.25), (0.72, 0.17), (0.86, 0.07), (0.95, 0.07), (1.08, 0.1),
           (1.21, 0.14)]


def opening_half(y):
    for (y0, h0), (y1, h1) in zip(OPENING, OPENING[1:]):
        if y0 <= y <= y1:
            return lerp(h0, h1, smooth01((y - y0) / (y1 - y0)))
    return OPENING[0][1] if y < OPENING[0][0] else OPENING[-1][1]


def belly_front(x, y):
    """z of the belly bulge's front surface (None outside it)."""
    k = 1 - (x / BELLY_R[0]) ** 2 - ((y - BELLY_C[1]) / BELLY_R[1]) ** 2
    return None if k <= 0 else BELLY_C[2] - BELLY_R[2] * math.sqrt(k)


def front_z(x, y):
    """The forward-most surface of the torso (jacket or belly) at (x, y)."""
    r = jacket_r(y)
    zj = -DEPTH * math.sqrt(max(0.0, r * r - x * x)) if abs(x) < r else 0.0
    zb = belly_front(x, y)
    return min(zj, zb) if zb is not None else zj


def torso(mats):
    parts = []
    body = lathe([(r, y) for r, y in JACKET], verts=24, mat=mats["suit"], name="jacket", smooth=180)
    body.scale = (1.0, DEPTH, 1.0)                       # Blender y = Godot z (depth)
    apply_transform(body)
    parts.append(body)
    parts.append(gsphere(1.0, BELLY_C, scale=BELLY_R, segments=20, rings=10, mat=mats["suit"], name="belly"))

    # The shirt in the opening, from the collar to the hem, lying on the jacket / gut.
    y_lo, y_hi = 0.31, 1.21

    def shirt(u, v):
        y = lerp(y_lo, y_hi, v)
        h = opening_half(y) + 0.012
        x = lerp(-h, h, u)
        z = front_z(x, y)
        return (x, y, z - 0.006), (x, y, z + 0.03)
    parts.append(shell(shirt, 6, 12, "shirt", mats["shirt"], solid=False))
    # Jacket edges: wide lapels folded back above the button point, a narrow edge below it.
    for side in (-1, 1):
        def edge(u, v, s=side):
            y = lerp(y_lo, y_hi, v)
            lap = smooth01((y - 0.86) / 0.12) * (1 - smooth01((y - 1.15) / 0.07))
            w = 0.028 + 0.1 * lap
            x = s * (opening_half(y) + w * u)
            lift = 0.012 + 0.012 * lap + 0.006 * math.sin(math.pi * u)
            z = front_z(x, y)
            return (x, y, z - lift), (x, y, z + 0.02)
        parts.append(shell(edge, 2, 12, "lapel", mats["lapel"]))
    for y in (0.8, 0.63, 0.46):                          # strained shirt buttons
        z = front_z(0.0, y)
        parts.append(gsphere(0.022, (0.035, y, z - 0.01), scale=(1.0, 1.0, 0.45), segments=8, rings=4,
                             mat=mats["ink"], name="button"))
    # Loosened collar ring + two splayed collar points (top buttons undone).
    col = torus(0.2, 0.034, pos=g(0.0, 1.2, -0.03), major_segments=16, minor_segments=4, mat=mats["shirt"],
                name="collar", scale=(1.0, 0.9, 1.0))
    col.rotation_euler = (math.radians(14), 0, 0)             # dips at the front (loosened)
    parts.append(col)
    for side in (-1, 1):
        tip = extrude_profile([(0.0, 0.0), (0.11, -0.02), (0.02, -0.1)], 0.02, bevel=0.005, segments=1,
                              mat=mats["shirt"], name="collar_tip")
        tip.scale = (-side, 1, 1)                        # Blender x = -Godot x
        apply_transform(tip)
        bmesh_fix_normals(tip)
        tip.location = g(0.035 * side, 1.2, -0.215)
        tip.rotation_euler = (math.radians(-35), 0, math.radians(-12 * side))
        parts.append(tip)
    parts += tie(mats)
    parts.append(chain(mats["gold"]))
    return parts


def bmesh_fix_normals(obj):
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()


def tie(mats):
    """Loosened tie: a knot hanging below the open collar, the blade lying on the chest and belly, swung to
    his left and flipped up a little at the tip."""
    knot = gsphere(0.05, (0.0, 1.09, front_z(0.0, 1.09) - 0.035), scale=(1.0, 1.05, 0.7), segments=12, rings=6,
                   mat=mats["tie"], name="knot")
    top, bot = 1.06, 0.5

    def blade(u, v):
        y = lerp(top, bot, v)
        swing = -0.1 * v ** 1.6                                      # drifts to his left
        half = lerp(0.04, 0.075, v) * (1.0 if v < 0.9 else lerp(1.0, 0.1, (v - 0.9) / 0.1))
        x = swing + lerp(-half, half, u)
        yy = y - (0.035 * (1 - abs(2 * u - 1)) if v >= 0.999 else 0.0)  # pointed tip
        z = front_z(x, yy) - 0.02 - 0.02 * v ** 3                     # lifts off the belly at the tip
        return (x, yy, z - 0.01), (x, yy, z + 0.006)
    return [knot, shell(blade, 4, 10, "tie", mats["tie"])]


def chain(gold):
    """Thick tarnished gold chain round the neck, draped on the collar/chest: a ring of fat links (bumps)."""
    bm = bmesh.new()
    nu, nv = 28, 5
    major = 0.33
    rows = []
    for i in range(nu):
        u = 2 * math.pi * i / nu
        rmin = 0.02 * (0.82 + 0.45 * abs(math.sin(9 * u)))           # 18 chunky links
        row = []
        for j in range(nv):
            w = 2 * math.pi * j / nv
            rr = major + rmin * math.cos(w)
            p = Vector((rr * math.sin(u), rmin * math.sin(w), -rr * math.cos(u)))     # Godot, ring in XZ
            # Drape: tilt forward 30 deg about x, sitting on the collar.
            t = math.radians(-36)
            y = p.y * math.cos(t) - p.z * math.sin(t)
            z = p.y * math.sin(t) + p.z * math.cos(t)
            droop = 0.07 * max(0.0, math.cos(u)) ** 3                  # the front hangs lower on the chest
            row.append(bm.verts.new(g(p.x, 1.19 + y - droop, -0.175 + z - 0.25 * droop)))
        rows.append(row)
    for i in range(nu):
        for j in range(nv):
            a, b = rows[i][j], rows[(i + 1) % nu][j]
            c, d = rows[(i + 1) % nu][(j + 1) % nv], rows[i][(j + 1) % nv]
            bm.faces.new((a, b, c, d))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj("chain", bm, gold, smooth=180)


# ============================================================================================== legs
def foot(side, mats):
    """Trouser leg + a cheap shiny shoe; local frame at the foot (Godot local coords via g())."""
    s = side
    leg = lathe([(0.14, 0.075), (0.15, 0.12), (0.135, 0.2), (0.125, 0.3), (0.125, 0.44)],
                verts=12, mat=mats["trousers"], name="trouser", smooth=60)
    shoe = gsphere(0.13, (0.0, 0.074, -0.07), scale=(0.95, 0.56, 1.5), segments=12, rings=6, mat=mats["shoe"],
                   name="shoe")
    heel = box((0.2, 0.14, 0.05), pos=g(0.0, 0.0, 0.07), bevel=0.02, segments=1, mat=mats["shoe"], name="heel")
    part = join([leg, shoe, heel], "FootLeft" if s < 0 else "FootRight")
    return part


# ============================================================================================== head
HEAD = [(0.0, -0.04), (0.2, -0.03), (0.3, 0.02), (0.352, 0.08), (0.366, 0.155), (0.362, 0.23), (0.35, 0.3),
        (0.33, 0.38), (0.3, 0.45), (0.264, 0.5), (0.2, 0.555), (0.1, 0.6), (0.0, 0.612)]
HEAD_DEPTH = 0.92
HEAD_SCALE = 1.12        # the finished head subtree is scaled up around the neck (see build())
STUBBLE_TOP = 0.155


def head_r(y):
    for (r0, y0), (r1, y1) in zip(HEAD, HEAD[1:]):
        if y0 <= y <= y1:
            return lerp(r0, r1, (y - y0) / (y1 - y0))
    return 0.0


def face_z0(x, y):
    r = head_r(y)
    return -HEAD_DEPTH * math.sqrt(max(0.0, r * r - x * x))


CHIN_C = (0.0, 0.03, -0.3)      # the double chin: the lower face is pushed forward and down around here
CHIN_DIR = Vector((0.0, -0.3, -1.0)).normalized()


def chin(p):
    """Godot point -> the same point after the double-chin bulge (same falloff as gwf.dent)."""
    d = (Vector(p) - Vector(CHIN_C)).length
    if d >= 0.2:
        return Vector(p)
    return Vector(p) + CHIN_DIR * 0.045 * (1 - (d / 0.2) ** 2) ** 2


def face_z(x, y):
    """z of the head's front surface at (x, y), double chin included (the bulge also moves points down, so
    find the unbulged height that lands on y with a few fixed-point steps)."""
    y0 = y
    for _ in range(4):
        p = chin((x, y0, face_z0(x, y0)))
        y0 += y - p.y
    return chin((x, y0, face_z0(x, y0))).z


def head(mats):
    prof = sorted(HEAD + [(head_r(STUBBLE_TOP), STUBBLE_TOP)], key=lambda p: p[1])
    skull = lathe(prof, verts=24, mat=mats["skin"], name="skull", smooth=180)
    skull.scale = (1.0, HEAD_DEPTH, 1.0)
    apply_transform(skull)
    # A heavy double chin pushed forward, then stubble on everything below the nose line (front half).
    move_verts(skull, lambda co: g(*chin((-co.x, co.z, co.y))))
    # (Blender: z up, -y front) below the nose at the front, sloping down to the jaw at the sides
    paint(skull, mats["stubble"], lambda c, n: c.y < 0.1 and
          c.z < STUBBLE_TOP - (STUBBLE_TOP - 0.02) * smooth01((abs(c.x) - 0.14) / 0.2))
    nose = gsphere(0.082, nose_c(), scale=(1.05, 0.95, 0.9), segments=14, rings=7, mat=mats["nose"],
                   name="nose")
    ears = [gsphere(0.075, (s * 0.35, 0.29, 0.03), scale=(0.45, 1.0, 0.75), segments=10, rings=5, mat=mats["skin"],
                    name="ear") for s in (-1, 1)]
    # Brows: bushy, inner ends pulled down hard (the scowl).
    brows = []
    for s in (-1, 1):
        pts = []
        for k in range(5):
            t = k / 4
            x = s * lerp(0.05, 0.225, t)
            y = lerp(0.415, 0.462, t) - 0.018 * math.sin(math.pi * t)
            pts.append(g(x, y, face_z(x, y) - 0.01))
        brows.append(pipe(pts, 0.032, verts=6, bend=0.0, mat=mats["brow"], name="brow"))
    # The permanent frown: a dark groove bending down at both ends, a sulky lower lip under it.
    pts = []
    for k in range(7):
        t = k / 6
        x = lerp(-0.105, 0.105, t)
        y = 0.1 - 0.045 * (2 * t - 1) ** 2 + 0.012
        pts.append(g(x, y, face_z(x, y) - 0.006))
    mouth = pipe(pts, 0.015, verts=6, bend=0.0, mat=mats["ink"], name="mouth")
    lip = gsphere(0.05, (0.0, 0.07, face_z(0.0, 0.07) + 0.004), scale=(1.3, 0.42, 0.55), segments=12, rings=6,
                  mat=mats["skin"], name="lip")
    return [skull, nose, lip, mouth] + ears + brows


def eye(side, mats):
    """EyeLeft/EyeRight (+ Pupil, Lid*) in the eye's local frame (centre at the origin)."""
    white = gsphere(0.088, (0, 0, 0), scale=(1.1, 1.0, 0.72), segments=12, rings=6, mat=mats["eye_white"],
                    name="EyeLeft" if side < 0 else "EyeRight")
    white = join([white], white.name)
    pupil = gsphere(0.036, (0, 0, 0), scale=(1.0, 1.1, 0.5), segments=10, rings=5, mat=mats["eye_black"],
                    name="Pupil__L" if side < 0 else "Pupil__R")
    pupil = join([pupil], pupil.name)
    # The lid: the upper half of a slightly bigger dome, with a dark lash roll on its cut edge.
    dome = lathe([(0.0, 0.098), (0.06, 0.082), (0.09, 0.045), (0.1, 0.0)], verts=12,
                 mat=mats["lid"], name="lid_dome", smooth=180)
    dome.scale = (1.1, 0.8, 1.0)
    apply_transform(dome)
    lash = torus(0.1, 0.014, major_segments=12, minor_segments=3, mat=mats["ink"], name="lash",
                 scale=(1.1, 0.8, 1.0))
    lid = join([dome, lash], "LidLeft" if side < 0 else "LidRight")
    return white, pupil, lid


NOSE_Y = 0.215


def nose_c():
    return (0.0, NOSE_Y, face_z(0.0, NOSE_Y) - 0.045)


def sunglasses(mats):
    """Low, wide shades riding down the boozer's nose (node origin = the lens centre line, on the cheeks):
    two flat-topped glossy ink lenses in tarnished gold frames, the bridge arching over the nose."""
    parts = []
    shape = [(-0.088, 0.036), (0.0, 0.042), (0.086, 0.04), (0.094, 0.004), (0.078, -0.034), (0.03, -0.05),
             (-0.035, -0.047), (-0.078, -0.028), (-0.094, 0.006)]     # outer side at +u
    for s_ in (-1, 1):
        pts = [(u * s_ * -1, v) for u, v in shape]                    # Blender u = -Godot x
        if s_ < 0:
            pts.reverse()
        lens = extrude_profile(pts, 0.018, bevel=0.007, segments=1, mat=mats["lens"], name="lens")
        frame = extrude_profile([(u * 1.13, v * 1.2) for u, v in pts], 0.012, pos=(0, 0.006, 0), bevel=0.0,
                                mat=mats["frame"], name="frame")
        lp = join([lens, frame], "lens_%d" % (s_ + 1))
        lp.rotation_euler = (0, 0, math.radians(-14 * s_))            # follow the face round
        lp.location = g(0.118 * s_, 0.0, 0.0)
        parts.append(lp)
        parts.append(pipe([g(s_ * 0.205, 0.022, 0.012), g(s_ * 0.255, 0.035, 0.1), g(s_ * 0.32, 0.06, 0.3)],
                          0.009, verts=4, bend=0.03, mat=mats["frame"], name="temple"))
    nc = nose_c()
    pts = []
    for x in (-0.05, -0.03, -0.012, 0.012, 0.03, 0.05):              # hugging the nose's upper front
        y = nc[1] + 0.046 - 0.35 * abs(x)
        k = 0.082 ** 2 - (x / 1.05) ** 2 - ((y - nc[1]) / 0.95) ** 2
        z = nc[2] - 0.9 * math.sqrt(max(0.0, k)) - 0.012
        pts.append(g(x, y - NOSE_BRIDGE_Y, z - GLASSES_Z))
    pts = [g(-0.03, 0.036, -0.012)] + pts + [g(0.03, 0.036, -0.012)]
    parts.append(pipe(pts, 0.01, verts=4, bend=0.0, mat=mats["frame"], name="bridge"))
    return join(parts, "Sunglasses")


NOSE_BRIDGE_Y = 0.2        # the lenses' centre line (HeadPivot local y): the shades ride low on the nose
GLASSES_Z = -0.35          # the lens plane (HeadPivot local z), just in front of the cheeks


def fedora(mats):
    """Charcoal fedora (node origin = the crown's base centre): tall pinched crown with the centre crease and a
    band, a dent, snap brim down at the front and curled up at the sides."""
    crown_prof = [(0.278, 0.0), (0.273, 0.07), (0.262, 0.14), (0.243, 0.2), (0.215, 0.24), (0.15, 0.262),
                  (0.07, 0.262), (0.0, 0.258)]
    crown = lathe(crown_prof, verts=20, mat=mats["hat"], name="crown", smooth=180)
    crown.scale = (1.0, 1.12, 1.0)                                    # oval: longer front to back

    def shape(co):
        k_top = smooth01((co.z - 0.14) / 0.12)
        crease = 0.07 * math.exp(-(co.x / 0.085) ** 2) * k_top        # the long centre dent, front to back
        front = max(0.0, -co.y) / 0.32
        pinch = smooth01((co.z - 0.1) / 0.14) * front ** 2           # pinched at the front
        return Vector((co.x * (1 - 0.3 * pinch), co.y, co.z - crease - 0.02 * pinch))
    apply_transform(crown)
    move_verts(crown, shape)
    dent(crown, (0.2, 0.12, 0.15), radius=0.12, depth=0.035)         # knocked in on his left-back
    band_ = band(lambda z: 0.28 - 0.06 * z, 0.0, 0.06, thickness=0.006, verts=18, rows=1, mat=mats["band"],
                 name="hat_band")
    band_.scale = (1.0, 1.12, 1.0)
    apply_transform(band_)
    brim = lathe([(0.24, 0.012), (0.38, 0.004), (0.43, -0.004), (0.436, -0.017), (0.38, -0.012), (0.24, -0.008)],
                 verts=20, closed=True, mat=mats["hat"], name="brim", smooth=70)
    brim.scale = (1.0, 1.08, 1.0)
    apply_transform(brim)

    def snap(co):
        r = math.hypot(co.x, co.y)
        a = math.atan2(co.x, -co.y)                                   # 0 = front
        k = max(0.0, (r - 0.26) / 0.18)
        up = 0.06 * math.sin(a) ** 2 * k ** 1.5                      # sides curl up
        down = 0.035 * max(0.0, math.cos(a)) ** 2 * k ** 1.3          # the front snaps down over the eyes
        return Vector((co.x, co.y, co.z + up - down))
    move_verts(brim, snap)
    return join([crown, band_, brim], "Hat")


def cigar(mats):
    """Fat cigar (node origin = the mouth corner), pointing out, forward and down; ash + ember at the tip."""
    d = Vector((0.55, -0.28, -0.79)).normalized()                     # Godot direction
    body = cyl(0.027, 0.2, verts=10, bevel=0.008, segments=1, mat=mats["cigar"], name="cigar_body")
    ring = torus(0.028, 0.008, pos=(0, 0, 0.045), major_segments=10, minor_segments=3, mat=mats["gold"],
                 name="cigar_band")
    ember = cyl(0.026, 0.012, verts=10, pos=(0, 0, 0.2), bevel=0.0, mat=mats["ember"], name="ember")
    ash = cyl(0.025, 0.035, verts=10, pos=(0, 0, 0.212), bevel=0.008, segments=1, mat=mats["ash"], name="ash")
    c = join([body, ring, ember, ash], "Cigar")
    c.rotation_euler = Vector((0, 0, 1)).rotation_difference(g(*d)).to_euler()
    c.location = g(*(d * -0.03))
    apply_transform(c)
    return c


# ============================================================================================== arms + hands
def sleeve(side, mats):
    s = side
    prof = [(0.0, -0.52), (0.08, -0.516), (0.1, -0.5), (0.108, -0.34), (0.118, -0.16), (0.124, -0.02),
            (0.112, 0.06), (0.07, 0.105), (0.0, 0.115)]
    arm = lathe([(r, y) for r, y in prof], verts=12, mat=mats["suit"], name="sleeve", smooth=180)
    cuff = cyl(0.086, 0.05, verts=14, pos=g(0, -0.555, 0), bevel=0.012, segments=1, mat=mats["shirt"], name="cuff")
    return join([arm, cuff], "ArmLeft" if s < 0 else "ArmRight")


def finger(name, mats, length=0.105, r=0.027, curl=-22.0, ring=None):
    """A fat finger from its knuckle (origin) along -Z, bent down by `curl` degrees."""
    f = capsule(r, length + r, verts=8, rings=4, mat=mats["skin"], name=name, anchor="base")
    along(f, (0.0, math.sin(math.radians(curl)), -math.cos(math.radians(curl))))
    f.location = g(0, 0, 0.0) + g(0.0, 0.0, 0.0)
    parts = [f]
    if ring is not None:
        d = Vector((0.0, math.sin(math.radians(curl)), -math.cos(math.radians(curl))))
        rg = torus(r + 0.004, 0.009, major_segments=10, minor_segments=3, mat=ring, name="ring")
        along(rg, d)
        rg.location = g(*(d * 0.035))
        parts.append(rg)
    return join(parts, name)


def hand_right(mats):
    """Palm down on the counter; Fingers/Finger1..4 are knuckle pivots (index -> pinky = inner -> outer)."""
    back = gsphere(0.1, (0.0, 0.0, 0.0), scale=(1.12, 0.52, 1.0), segments=10, rings=6, mat=mats["skin"],
                   name="palm")
    thumb = capsule(0.032, 0.11, verts=8, rings=4, mat=mats["skin"], name="thumb")
    along(thumb, (-0.55, -0.1, -0.83))                                 # inner side (towards his belly)
    thumb.location = g(-0.085, -0.01, -0.01)
    hand = join([back, thumb], "Hand__R")
    fingers = empty("Fingers")
    tips = []
    for i, x in enumerate((-0.062, -0.021, 0.021, 0.062)):
        f = finger("Finger%d" % (i + 1), mats, length=0.1 if i in (0, 3) else 0.11,
                   ring=mats["gold"] if i == 3 else None)
        tips.append((f, (x, -0.006, -0.07)))
    return hand, fingers, tips


def hand_left(mats):
    """Palm UP on the counter ("pay up"): fingers curled up a little, thumb along the side; Cash sits in it."""
    palm = gsphere(0.1, (0.0, 0.0, 0.0), scale=(1.12, 0.5, 1.0), segments=10, rings=6, mat=mats["skin"],
                   name="palm")
    parts = [palm]
    for i, x in enumerate((0.062, 0.021, -0.021, -0.062)):
        d = Vector((0.0, math.sin(math.radians(28)), -math.cos(math.radians(28))))
        f = capsule(0.027, 0.12, verts=8, rings=4, mat=mats["skin"], name="lfinger")
        f.rotation_euler = Vector((0, 0, 1)).rotation_difference(g(*d)).to_euler()
        f.location = g(x, 0.004, -0.07)
        parts.append(f)
        if i == 3:
            rg = torus(0.031, 0.009, major_segments=10, minor_segments=3, mat=mats["gold"], name="ring")
            rg.rotation_euler = f.rotation_euler.copy()
            rg.location = g(x, 0.004, -0.07) + g(*(d * 0.035))
            parts.append(rg)
    thumb = capsule(0.032, 0.11, verts=8, rings=4, mat=mats["skin"], name="thumb")
    along(thumb, (0.35, 0.5, -0.8))                                    # inner side, lifted
    thumb.location = g(0.085, 0.0, -0.01)
    parts.append(thumb)
    return join(parts, "Hand__L")


def cash(mats):
    """Cash (wad + paper strap) with TopBill (pivot on the wad's left edge, the bill lies along +x)."""
    wad = box((0.2, 0.105, 0.065), bevel=0.012, segments=1, mat=mats["cash"], name="wad")   # Blender x, y=depth, z
    strap = box((0.05, 0.112, 0.071), pos=(0.0, 0.0, -0.003), bevel=0.008, segments=1, mat=mats["strap"],
                name="strap")
    w = join([wad, strap], "Cash")
    bill = box((0.2, 0.1, 0.008), pos=g(0.1, 0.0, 0.0), bevel=0.003, mat=mats["cash"], name="TopBill")
    set_origin(bill, (0, 0, 0))
    return w, bill


# ============================================================================================== build
def build():
    skin_hex = pal("SKIN")
    mats = {
        "suit": lib("brown"),
        "lapel": material("lapel", mix(pal("COCOA"), pal("INK"), 0.22), "soft"),
        "trousers": material("trousers", mix(pal("COCOA"), pal("INK"), 0.35), "soft"),
        "shirt": lib("cream"),
        "tie": material("tie", mix(pal("TOMATO"), pal("INK"), 0.42), "soft"),
        "gold": lib("gold"),
        "ink": lib("dark"),
        "shoe": material("shoe", mix(pal("INK"), pal("COCOA"), 0.15), "glossy"),
        "skin": lib("skin"),
        "stubble": material("stubble", mix(skin_hex, pal("COOL_GRAY"), 0.42), "matte"),
        "nose": material("nose", mix(skin_hex, pal("TOMATO"), 0.2), "soft"),
        "brow": material("brow", mix(pal("INK"), pal("COCOA"), 0.3), "matte"),
        "lid": material("boss_lid", mix(skin_hex, pal("INK"), 0.12), "soft"),
        "eye_white": lib("eye_white"),
        "eye_black": lib("eye_black"),
        "lens": material("lens", pal("INK"), "glossy"),
        "frame": lib("gold"),
        "hat": lib("metal_dark"),
        "band": lib("dark"),
        "cigar": material("cigar", mix(pal("COCOA"), pal("INK"), 0.45), "matte"),
        "ember": material("ember", pal("TANGERINE"), "glow", emission=0.9),
        "ash": lib("gray"),
        "cash": lib("olive"),
        "strap": lib("cream"),
    }

    # --- Torso (origin at the floor, rest identity)
    torso_obj = join(torso(mats), "Torso")
    place(torso_obj, gmat())

    # --- Feet (static, under the root)
    feet = []
    for s, nm in ((-1, "FootLeft"), (1, "FootRight")):
        f = foot(s, mats)
        place(f, gmat((0.2 * s, 0.0, -0.05), (0, -9 * s, 0)))    # toes turned out a little
        feet.append(f)

    # --- Head (origin at the neck)
    head_w = gmat((0.0, 1.2, 0.0))
    head_obj = join(head(mats), "HeadPivot")
    place(head_obj, head_w)
    set_parent(head_obj, torso_obj)
    for s in (-1, 1):
        white, pupil, lid = eye(s, mats)
        ew = head_w @ gmat((0.13 * s, 0.338, face_z(0.13, 0.338) + 0.012))
        place(white, ew)
        set_parent(white, head_obj)
        place(pupil, ew @ gmat((-0.014 * s, -0.022, -0.056)))
        set_parent(pupil, white)
        place(lid, ew @ gmat((0, 0, 0), (-4, 0, -17 * -s)))      # LidLeft (s=-1) z -17: inner corner down
        set_parent(lid, white)
    glasses = sunglasses(mats)
    place_baked(glasses, head_w, (0.0, NOSE_BRIDGE_Y, GLASSES_Z), (0, 0, -3))
    set_parent(glasses, head_obj)
    hat = fedora(mats)
    place_baked(hat, head_w, (0.0, 0.505, 0.02), (-4, 4, 7))
    set_parent(hat, head_obj)
    cig = cigar(mats)
    place(cig, head_w @ gmat((0.088, 0.078, face_z(0.088, 0.078) + 0.005)))
    set_parent(cig, head_obj)
    # A big head reads through the bars at the counter: the whole head subtree 12 % up, around the neck.
    subtree = [head_obj]
    for o in subtree:
        subtree += [c for c in o.children if c not in subtree]
    scale_about(subtree, (0.0, 1.2, 0.0), HEAD_SCALE)

    # --- Arms (rest pose reaching onto the counter; the script records it)
    for s, nm in ((-1, "ArmLeft"), (1, "ArmRight")):
        arm_w = gmat((0.47 * s, 1.02, -0.05), (72, 12 * s, 0))
        a = sleeve(s, mats)
        place(a, arm_w)
        set_parent(a, torso_obj)
        hand_w = arm_w @ gmat((0.0, -0.56, 0.0), (-72, 0, 0))
        if s > 0:
            hand, fingers, tips = hand_right(mats)
            place(hand, hand_w)
            set_parent(hand, a)
            fw = hand_w @ gmat((0.0, 0.0, 0.0))
            place(fingers, fw)
            set_parent(fingers, hand)
            for f, pos in tips:
                place(f, fw @ gmat(pos))
                set_parent(f, fingers)
        else:
            hand = hand_left(mats)
            place(hand, hand_w)
            set_parent(hand, a)
            wad, bill = cash(mats)
            cw = hand_w @ gmat((0.0, 0.058, -0.01), (0, 8, 0))
            place(wad, cw)
            set_parent(wad, hand)
            place(bill, cw @ gmat((-0.1, 0.066, 0.0)))
            set_parent(bill, wad)

    export([torso_obj] + feet, "boss", kind="character", mount="floor")
