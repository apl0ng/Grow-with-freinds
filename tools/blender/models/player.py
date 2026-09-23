"""player: the body OTHER players see, a slumped, tired worker bean (kind "character": front -> Godot -Z).

scenes/player/player.tscn instances this model as `Visual/Model` (the local player hides it, like every mesh
under Visual). ~0.93 x 1.78 x 0.76 m (W x H x D, Godot), floor mount, origin between the boots.
Design: a 0.78 m wide bean on stubby legs and chunky work boots, hunched forward (head pushed 10 cm forward
and down), tiny arms hanging in scuffed leather work gloves, a grimy olive canvas bib apron (stains, a sagging
pocket with a wrench, cross-back straps, waist tie), a dented grubby hard hat with a crooked peak, a scuffed
caution sticker and a wilted sprout (the farm's mark) flopping out of a crack. No face in the mesh: the scene keeps the art agent's ToonFace (art/props/face.tscn, sad mood:
heavy lids, eye bags, frown) on the head front, so blinks / moods / look() keep working.

Nodes (Godot):  <Model, Toonify> / Body       bean + apron + legs + boots + hard hat (one mesh)
                                 / ArmL, ArmR  arm + glove, origin at the shoulder, rest rotation 0 (free to swing)
                                 / FacePivot   empty at the head centre: player.tscn's Visual/Face (the node
                                               player.gd tilts with the look pitch) sits exactly here
Colours: TINT_body = the player colour (player.gd: Toonify.tint = Toon.grade(player_color)), legs TINT shade
0.8; apron toon_olive, gloves + boots toon_brown, hat toon_white; grime from palette mixes.
"""
import bpy
import bmesh
from mathutils import Euler
from gwf import *

# Factory palette (STYLE.md section 12; not Toon constants, so pal() can't read them).
OLIVE = "#7c8665"
BROWN = pal("COCOA")

R_BELLY = 0.395     # widest body radius (belly, z = Z_BELLY): a pear, heavy at the bottom
Z_BOTTOM = 0.25     # bean bottom (sits on the stubby legs)
Z_BELLY = 0.54
Z_HEAD = 1.365       # start of the head dome
R_HEAD = 0.318      # radius where the head dome starts
Z_TOP = 1.79        # bean top (before the slump)
BEND = math.radians(21)   # the tired hunch: the spine bends forward this much at the head top ...
BEND_P = 1.5              # ... growing with height ** BEND_P (a rounded back, the head tips forward)
SPINE = 0.56              # the bend starts above this height
FACE_Z = 1.295      # face.tscn origin height on the unslumped bean (eyes ~3 cm above it)
HAT_SCALE = 0.88    # hard hat base radius 0.29 m (perched on the head dome)
HAT_R = 0.29        # the hard hat's inner radius at its base
V = 32              # radial segments of the big bean


def mix(a, b, t):
    """Palette mix: '#hex' a -> b by t (sRGB, like Color.lerp)."""
    ca = [int(a.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    cb = [int(b.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4)]
    return "#" + "".join("%02x" % round(x + (y - x) * t) for x, y in zip(ca, cb))


def body_r(z):
    """Radius of the (unslumped) bean at height z: round bottom, a belly, a slightly narrower head dome."""
    if z <= Z_BELLY:
        k = max(0.0, min(1.0, (Z_BELLY - z) / (Z_BELLY - Z_BOTTOM)))
        return R_BELLY * math.sqrt(max(0.0, 1 - k * k))
    if z <= Z_HEAD:
        k = (z - Z_BELLY) / (Z_HEAD - Z_BELLY)
        k = k * k * (3 - 2 * k) * 0.55 + k * 0.45          # eased: a soft belly, a soft neckless shoulder
        return R_BELLY - (R_BELLY - R_HEAD) * k
    k = max(0.0, min(1.0, (z - Z_HEAD) / (Z_TOP - Z_HEAD)))
    return R_HEAD * math.sqrt(max(0.0, 1 - k * k))


def bend_theta(z):
    """Forward bend (radians) of the spine at height z."""
    t = max(0.0, (z - SPINE) / (Z_TOP - SPINE))
    return BEND * min(t, 1.0) ** BEND_P


def spine(z, steps=40):
    """(y, z) of the bent spine at unbent height z (arc length is kept: the bean bends, it doesn't stretch)."""
    if z <= SPINE:
        return 0.0, z
    h = (z - SPINE) / steps
    y, zz = 0.0, SPINE
    for i in range(steps):
        th = bend_theta(SPINE + (i + 0.5) * h)
        y -= math.sin(th) * h
        zz += math.cos(th) * h
    return y, zz


def slump(co):
    """The tired hunch: every slice of the bean above SPINE turns forward by bend_theta around the bent spine,
    so the back rounds, the front folds in and the head tips forward and down."""
    if co.z <= SPINE:
        return co.copy()
    th = bend_theta(co.z)
    y, z = spine(co.z)
    return Vector((co.x, y + co.y * math.cos(th), z + co.y * math.sin(th)))


def on_body(a, z, off=0.0):
    """Point on the unslumped bean surface, `a` radians around from the front (-Y) towards +X."""
    r = body_r(z) + off
    return Vector((r * math.sin(a), -r * math.cos(a), z))


def mesh_obj(name, bm, mat=None, smooth=40.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    if mat is not None:
        me.materials.append(mat if isinstance(mat, bpy.types.Material) else lib(mat))
    return obj


def shell(fn, nu, nv, name, mat, smooth=50.0):
    """A thin solid from a parametric patch: fn(u, v) -> (outer point, inner point), u, v in 0..1."""
    bm = bmesh.new()
    out = [[bm.verts.new(fn(i / nu, j / nv)[0]) for j in range(nv + 1)] for i in range(nu + 1)]
    inn = [[bm.verts.new(fn(i / nu, j / nv)[1]) for j in range(nv + 1)] for i in range(nu + 1)]
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


# ============================================================================================== parts
def bean(tint):
    prof = [(0.0, Z_BOTTOM)]
    for k in range(1, 7):                        # round bottom
        ang = math.pi / 2 * (1 - k / 6)
        z = Z_BELLY - (Z_BELLY - Z_BOTTOM) * math.sin(ang)
        prof.append((body_r(z), z))
    for k in range(1, 8):                        # belly -> head
        z = Z_BELLY + (Z_HEAD - Z_BELLY) * k / 7
        prof.append((body_r(z), z))
    for k in range(1, 7):                        # head dome
        ang = math.pi / 2 * k / 7
        z = Z_HEAD + (Z_TOP - Z_HEAD) * math.sin(ang)
        prof.append((body_r(z), z))
    prof.append((0.0, Z_TOP))
    return lathe(prof, verts=V, mat=tint, name="bean", smooth=180)


def apron_r(z):
    """The apron hugs the belly and chest, and hangs straight (a little flared) below the belly."""
    if z < Z_BELLY:
        return R_BELLY + 0.012 + 0.03 * (Z_BELLY - z) / (Z_BELLY - Z_BOTTOM)
    return body_r(z) + 0.012


APRON_TOP = 1.04
BIB_HALF = 0.165     # half width of the bib (m)
SKIRT_HALF = 0.345   # half width of the skirt


def apron_half_angle(z):
    t = max(0.0, min(1.0, (z - 0.78) / 0.14))
    t = t * t * (3 - 2 * t)
    half = SKIRT_HALF + (BIB_HALF - SKIRT_HALF) * t
    return math.asin(min(0.95, half / apron_r(z)))


def apron_bottom(a):
    return 0.38 + 0.018 * math.sin(7.0 * a + 1.3) + 0.01 * math.sin(13.0 * a)   # ragged hem


def apron_point(a, z, off=0.0):
    r = apron_r(z) + off
    return Vector((r * math.sin(a), -r * math.cos(a), z))


def apron(canvas):
    def fn(u, v):
        z0 = apron_bottom(0.0)
        z = z0 + (APRON_TOP - z0) * v
        w = apron_half_angle(z)
        a = -w + 2 * w * u
        if v == 0.0:
            z = apron_bottom(a)
        return apron_point(a, z, 0.006), apron_point(a, z, -0.006)
    return shell(fn, 12, 9, "apron", canvas)


def pocket(canvas):
    def fn(u, v):
        a = -0.36 + 0.72 * u
        z = 0.59 + 0.17 * v + (0.012 * math.sin(math.pi * u) if v == 1.0 else 0.0)
        sag = 0.012 * math.sin(math.pi * u) * (1 - v)   # the full pocket bulges out at the bottom
        return apron_point(a, z, 0.017 + sag), apron_point(a, z, 0.004)
    return shell(fn, 8, 3, "pocket", canvas)


def wrench(metal):
    """A wrench poking out of the pocket (right side as the others see it: Blender -X)."""
    a, z = -0.24, 0.70
    base = apron_point(a, z, 0.03)
    shaft = box((0.034, 0.016, 0.2), bevel=0.006, segments=1, mat=metal, name="wrench_shaft")
    head = torus(0.034, 0.013, major_segments=10, minor_segments=4, rot=(90, 0, 0), pos=(0, 0, 0.215),
                 mat=metal, name="wrench_head")
    w = join([shaft, head], "wrench")
    w.location = base
    w.rotation_euler = (math.radians(-8), math.radians(-14), a)
    apply_transform(w)
    return w


def stains(grime):
    out = []
    for a, z, r, sx in ((0.2, 0.88, 0.036, 1.4), (-0.1, 0.48, 0.034, 1.1), (0.28, 0.45, 0.024, 0.8)):
        s = sphere(r, scale=(sx, 0.16, 1.0), segments=8, rings=4, mat=grime, name="stain")
        s.location = apron_point(a, z, 0.005)
        s.rotation_euler = (0, 0, a)
        apply_transform(s)
        out.append(s)
    return out


def straps(canvas):
    """Cross-back straps: from the bib corners up over the shoulders, crossing on the back down to the waist tie
    (reads as an apron from behind), plus the waist tie with a sad knot."""
    a0 = apron_half_angle(APRON_TOP - 0.01)
    cross = []
    for side, off in ((1, 0.012), (-1, 0.022)):                  # one strap lies on the other where they cross
        pts = []
        n = 14
        for k in range(n + 1):
            t = k / n
            a = side * (a0 + (math.pi + 0.95 - a0) * t)
            if t < 0.3:
                z = APRON_TOP - 0.01 + 0.25 * math.sin(t / 0.3 * math.pi / 2)
            else:
                z = APRON_TOP + 0.24 - (APRON_TOP + 0.24 - 0.83) * ((t - 0.3) / 0.7) ** 1.1
            pts.append(on_body(a, z, off))
        cross.append(pipe(pts, 0.017, verts=6, bend=0.0, mat=canvas, name="strap"))
    waist = band(lambda z: body_r(z) + 0.003, 0.805, 0.84, thickness=0.009, verts=24, rows=1, mat=canvas,
                 name="waist_tie")
    back = on_body(math.pi, 0.822, 0.012)
    knot = sphere(0.034, pos=back, scale=(1.2, 0.8, 1.0), segments=8, rings=5, mat=canvas, name="knot")
    ends = [pipe([back + Vector((dx * 0.02, 0.01, 0)), back + Vector((dx * 0.05, 0.03, -0.1)),
                  back + Vector((dx * 0.055, 0.02, -0.2))], 0.014, verts=4, mat=canvas, name="tie_end")
            for dx in (-1, 1)]
    return cross + [waist, knot] + ends


def legs_and_boots(leg_mat, leather, rubber):
    parts = []
    for side in (-1, 1):
        x = 0.155 * side
        parts.append(capsule(0.1, 0.4, pos=(x, 0.0, 0.03), verts=12, rings=4, mat=leg_mat, name="leg"))
        yaw = 11 * side                                   # toes turned out: a tired stance
        upper = box((0.2, 0.27, 0.135), pos=(0, 0.035, 0.03), bevel=0.06, segments=2, mat=leather, name="boot")
        toe = sphere(0.1, pos=(0, -0.095, 0.078), scale=(0.98, 0.95, 0.62), segments=14, rings=6, mat=leather,
                     name="toe")
        sole = box((0.2, 0.33, 0.04), pos=(0, -0.018, 0.0), bevel=0.016, segments=2, mat=rubber, name="sole")
        cuff = torus(0.1, 0.022, pos=(0, 0.035, 0.165), major_segments=12, minor_segments=5, mat=leather,
                     name="cuff")
        boot = join([upper, toe, sole, cuff], "boot")
        boot.location = (0.17 * side, -0.02, 0.0)
        boot.rotation_euler = (0, 0, math.radians(yaw))
        apply_transform(boot)
        parts.append(boot)
    return parts


HAT_PROF = [(0.33, 0.0), (0.334, 0.03), (0.33, 0.08), (0.312, 0.14), (0.276, 0.195), (0.22, 0.24),
            (0.15, 0.27), (0.075, 0.285), (0.0, 0.29)]     # authored at 0.33 m, scaled by HAT_SCALE


def dome_r(z):
    for (r0, z0), (r1, z1) in zip(HAT_PROF, HAT_PROF[1:]):
        if z0 <= z <= z1:
            return r0 + (r1 - r0) * (z - z0) / (z1 - z0)
    return 0.0


def hard_hat(shell_mat, sticker, ink):
    """Grubby hard hat: dome + front-to-back ridge + a brim with a longer, drooping front peak. Base at z=0."""
    prof = HAT_PROF
    dome = lathe(prof, verts=24, mat=shell_mat, name="dome", smooth=60)
    dent(dome, (0.2, -0.16, 0.19), radius=0.12, depth=0.03)           # knocked on the front-left
    dent(dome, (-0.26, 0.12, 0.13), radius=0.08, depth=0.018)
    ridge = []
    for k in range(15):                                                   # front -> over the top -> back
        t = -1.0 + 2.0 * k / 14
        z = 0.085 + (0.29 - 0.085) * (1 - abs(t)) ** 0.45 if abs(t) < 1 else 0.085
        ridge.append(Vector((0.0, (dome_r(z) + 0.006) * (1 if t > 0 else -1), z)))
    ridge[7] = Vector((0.0, 0.0, 0.296))
    ridge = pipe(ridge, 0.024, verts=6, bend=0.0, mat=shell_mat, name="ridge")

    brim_prof = [(0.3, 0.012), (0.37, 0.0), (0.382, -0.012), (0.37, -0.02), (0.3, -0.01)]
    brim = lathe(brim_prof, verts=24, mat=shell_mat, name="brim", smooth=70, closed=True)

    def peak(co):
        a = math.atan2(co.x, -co.y)                                       # 0 = front
        k = max(0.0, math.cos(a)) ** 2.2
        r = math.hypot(co.x, co.y)
        grow = 0.085 * k * max(0.0, (r - 0.3) / 0.08)
        s = (r + grow) / r if r > 1e-6 else 1.0
        return Vector((co.x * s, co.y * s, co.z - 0.05 * k * max(0.0, (r - 0.3) / 0.1)))
    move_verts(brim, peak)
    # A scuffed caution sticker on the front of the dome.
    sa = math.radians(-18)
    zc, rr = 0.12, 0.33
    dia = extrude_profile([(0, -0.045), (0.045, 0), (0, 0.045), (-0.045, 0)], 0.012, bevel=0.004, mat=sticker,
                          name="sticker")
    bang = box((0.012, 0.01, 0.034), pos=(0, -0.012, -0.004), bevel=0.003, mat=ink, name="bang")
    dot = box((0.012, 0.01, 0.011), pos=(0, -0.012, -0.024), bevel=0.003, mat=ink, name="dot")
    st = join([dia, bang, dot], "sticker")
    st.location = (rr * math.sin(sa) * 0.985, -rr * math.cos(sa) * 0.985 + 0.004, zc)
    st.rotation_euler = (math.radians(-22), 0, sa)
    apply_transform(st)
    # A wilted sprout (the farm's mark) poking out of a crack in the dome, flopped over to one side.
    base = Vector((0.085, 0.07, dome_r(0.2) * 0 + 0.262))
    stem = pipe([base + Vector((0, 0, -0.03)), base + Vector((0.006, 0.0, 0.07)), base + Vector((0.04, -0.01, 0.125)),
                 base + Vector((0.1, -0.02, 0.125))], 0.017, verts=6, bend=0.03, mat="leaf", name="stem")
    tip = base + Vector((0.1, -0.02, 0.125))
    leaves = []
    for side, yaw in ((1, 25), (-1, -30)):
        leaf = sphere(0.055, scale=(1.5, 0.8, 0.3), segments=10, rings=5, mat="leaf_dry", name="leaf")
        leaf.location = tip + Vector((0.055, side * 0.035, -0.03))
        leaf.rotation_euler = (math.radians(side * 25), math.radians(40), math.radians(yaw))
        leaves.append(leaf)
    hat = join([dome, ridge, brim, st, stem] + leaves, "hat")
    hat.scale = (HAT_SCALE,) * 3                 # authored at 0.33 m; worn a size too small
    apply_transform(hat)
    return hat


def arm(side, tint, leather):
    """Tiny arm hanging along the body, glove at the end. side +1 = Blender +X (the character's LEFT)."""
    s = side
    shoulder = slump(on_body(math.radians(80) * s, 1.04, -0.03))
    elbow = on_body(math.radians(78) * s, 0.84, 0.045)
    wrist = on_body(math.radians(62) * s, 0.68, 0.05)
    limb = pipe([shoulder, elbow, wrist], 0.062, verts=12, bend=0.09, mat=tint, name="arm")
    ball = sphere(0.066, pos=shoulder, segments=10, rings=5, mat=tint, name="shoulder")
    down = (wrist - elbow).normalized()
    cuff = torus(0.062, 0.02, pos=wrist + down * 0.01, major_segments=12, minor_segments=4, mat=leather,
                 name="glove_cuff")
    cuff.rotation_euler = Vector((0, 0, 1)).rotation_difference(down).to_euler()
    mitt_c = wrist + down * 0.075 + Vector((0, -0.01, 0))
    mitt = sphere(0.078, pos=mitt_c, scale=(0.82, 1.0, 1.18), segments=12, rings=7, mat=leather, name="mitt")
    mitt.rotation_euler = Vector((0, 0, -1)).rotation_difference(down).to_euler()
    thumb = sphere(0.034, pos=mitt_c + Vector((-0.045 * s, -0.045, 0.02)), scale=(1, 1, 1.3), segments=8,
                   rings=5, mat=leather, name="thumb")
    a = join([limb, ball, cuff, mitt, thumb], "ArmL" if s > 0 else "ArmR", origin=shoulder)
    return a


def hat_matrix():
    """World matrix of the hard hat: seated on the slumped head where the dome is HAT_R wide, leaning with the
    slump, pushed back a little and knocked crooked."""
    zb = Z_HEAD + (Z_TOP - Z_HEAD) * math.sqrt(1 - (HAT_R / R_HEAD) ** 2)
    base = slump(Vector((0.0, 0.0, zb))) + Vector((0.01, 0.012, 0.0))
    rot = Euler((bend_theta(zb) - math.radians(9), math.radians(8), math.radians(-6)), 'XYZ')
    return Matrix.Translation(base) @ rot.to_matrix().to_4x4()


def tuck_head(head, m, margin=0.035):
    """Pull the (hidden) head top inside the hat dome, `margin` inside its shell, so neither the head nor its
    2.5 cm ink hull pokes through the hat."""
    inv = m.inverted()
    zmax = HAT_PROF[-1][1] * HAT_SCALE - margin
    moved = 0
    for v in head.data.vertices:
        p = inv @ v.co
        if p.z <= -0.01:
            continue
        z = min(p.z, zmax)
        allowed = max(0.02, dome_r(max(0.0, z) / HAT_SCALE) * HAT_SCALE - margin)
        r = math.hypot(p.x, p.y)
        if r > allowed or p.z > zmax:
            k = min(1.0, allowed / r) if r > 1e-6 else 1.0
            v.co = m @ Vector((p.x * k, p.y * k, z))
            moved += 1
    head.data.update()
    return moved


# ============================================================================================== build
def build():
    tint = tint_material("TINT_body")
    leg_mat = tint_material("TINT_legs", shade=0.8)
    canvas = lib("olive")
    leather = lib("brown")
    rubber = lib("dark")
    grime = material("grime", mix(OLIVE, pal("INK"), 0.42), "matte")
    hat_mat = lib("white")

    body = bean(tint)
    apr = apron(canvas)
    pk = pocket(canvas)
    wr = wrench(lib("metal_dark"))
    st = stains(grime)
    sp = straps(canvas)
    upper = [body, apr, pk, wr] + st + sp
    for o in upper:
        apply_modifiers(o)
        apply_transform(o)
        move_verts(o, slump)

    # Hard hat: sits low on the slumped head, tilted forward with the slump and knocked crooked.
    hat = hard_hat(hat_mat, lib("caution"), lib("dark"))
    hm = hat_matrix()
    hat.matrix_world = hm
    apply_transform(hat)
    tuck_head(body, hm)

    low = legs_and_boots(leg_mat, leather, rubber)
    body = join(upper + [hat] + low, "Body")

    arm_l = arm(+1, tint, leather)
    arm_r = arm(-1, tint, leather)

    # Face placement for player.tscn (printed; the scene hard-codes it, models_char_test checks it).
    zc = FACE_Z
    centre = slump(Vector((0.0, 0.0, zc)))
    # (the pivot is on the slumped axis at face height, so a pitch tilt slides the face over the head)
    front = slump(on_body(0.0, zc))
    e = 0.01
    tangent = (slump(on_body(0.0, zc + e)) - slump(on_body(0.0, zc - e))).normalized()   # up along the face
    tilt_face = math.degrees(math.atan2(-tangent.y, tangent.z))                          # + = faces down
    pivot = empty("FacePivot", pos=centre)
    print("  player: FacePivot (Godot) = (0, %.3f, %.3f); face offset = (0, %.3f, %.3f); face tilt %.1f deg down"
          % (centre.z, centre.y, front.z - centre.z, front.y - centre.y, tilt_face))
    for nm, o in (("ArmL", arm_l), ("ArmR", arm_r)):
        print("  player: %s shoulder (Godot) = (%.3f, %.3f, %.3f)" % (nm, -o.location.x, o.location.z, o.location.y))

    export([body, arm_l, arm_r, pivot], "player", kind="character", mount="floor")
