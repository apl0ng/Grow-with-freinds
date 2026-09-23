"""wall_clock: the big institutional wall clock over the Boss's window, cracked (room decor, rigged).

Wall mount, origin = the clock centre on the wall, 0.93 x 0.93 x 0.13 m. Instanced AS `Visual` in
scenes/world/props/wall_clock.tscn; wall_clock.gd turns `Visual/SecondHand` and `Visual/MinuteHand`
(rotation.z, clockwise = negative), the scene sets the resting time on `HourHand` / `MinuteHand`.
  Visual (Toonify) / Body         case, fat steel bezel, cream face, hour ticks, domed glass with a crack
                                  star, the centre cap (static)
                   / HourHand     pivot at the centre, points at the clock's 12 at rotation 0
                   / MinuteHand   "
                   / SecondHand   " (rust-red, counterweight tail)
Sad: the clock hangs crooked (5 deg: the hands' zero follows the crooked 12, baked into their meshes so
the node rest rotation stays identity), the glass is cracked from a thrown something, the bezel is
dented, the 7 o'clock tick has fallen off, a damp stain creeps across the face.
"""
from gwf import *

CROOKED = -5.0          # degrees about the face normal (clockwise as seen from the front)
R = 0.465               # outer radius
FACE_Z = 0.066          # face height above the wall (local frame: face in XY, front +Z, 12 o'clock +Y)


def to_wall():
    """Local clock frame (face in XY, 12 at +Y, front +Z) -> Blender wall frame (front -Y), crooked."""
    return Matrix.Rotation(math.radians(90), 4, 'X') @ Matrix.Rotation(math.radians(CROOKED), 4, 'Z')


def placed(obj, m=None):
    """Move obj (built in the local clock frame; m = its local transform) onto the wall."""
    obj.matrix_world = to_wall() @ (m if m is not None else obj.matrix_basis)
    apply_transform(obj)
    return obj


def hand(name, pts, z, thick, mat):
    """A flat hand drawn pointing at 12 (+Y) in the local frame, pivot at the centre, lying at height z."""
    # extrude_profile draws in XZ and extrudes to -Y: turn it so (u, v) = local (x, y) and it extrudes up +Z.
    h = extrude_profile(pts, thick, pos=(0, 0, 0), rot=(-90, 0, 0), bevel=0.003, segments=1, mat=mat, name=name)
    apply_transform(h)
    h.location = (0, 0, z)
    apply_transform(h)
    return placed(h, Matrix.Identity(4))


def build():
    steel = lib("metal_dark")
    face_mat = lib("cream")
    ink = lib("dark")
    red = lib("rust")
    glass = lib("glass")
    crack_mat = lib("concrete_dark")

    # Case + bezel + face as one lathe (the face is painted cream afterwards).
    prof = [(0.0, 0.0), (0.44, 0.0), (0.458, 0.018), (R, 0.055), (0.458, 0.098), (0.435, 0.122), (0.405, 0.126),
            (0.385, 0.114), (0.376, 0.088), (0.37, FACE_Z + 0.002), (0.3, FACE_Z), (0.0, FACE_Z + 0.002)]
    case = lathe(prof, verts=48, mat=steel, name="case", smooth=40)
    paint(case, face_mat, lambda c, n: n.z > 0.9 and math.hypot(c.x, c.y) < 0.372)
    # A knock on the bezel at about 4 o'clock.
    a4 = math.radians(90 - 4 * 30)
    dent(case, (0.46 * math.cos(a4), 0.46 * math.sin(a4), 0.1), radius=0.12, depth=0.018)
    parts = [case]

    # Damp stain creeping in from the top-left of the face (a thin flat blotch just above the face).
    pts = []
    for k in range(16):
        a = 2 * math.pi * k / 16
        r = 1.0 + 0.18 * math.sin(3 * a + 0.7) + 0.1 * math.sin(5 * a + 1.9)
        pts.append((-0.2 + 0.13 * r * math.cos(a), 0.2 + 0.1 * r * math.sin(a)))
    stain = extrude_profile(pts, 0.0015, rot=(-90, 0, 0), bevel=0,
                            mat=material("damp", "#a79c86", "matte"), name="stain")   # cream, 20 % darker
    apply_transform(stain)
    stain.location = (0, 0, FACE_Z + 0.0022)
    parts.append(stain)

    # Hour ticks: fat at 12/3/6/9, thin elsewhere; the 7 o'clock one is missing (a pale ghost left).
    for h in range(12):
        a = math.radians(90 - h * 30)
        fat = h % 3 == 0
        w, ln = (0.034, 0.075) if fat else (0.018, 0.05)
        r0 = 0.35 - ln
        if h == 7:
            continue
        t = box((ln, w, 0.006), pos=(0, 0, 0), bevel=0.002, segments=1, mat=ink, name="tick")
        t.matrix_world = (Matrix.Rotation(a, 4, 'Z') @ Matrix.Translation((r0 + ln / 2, 0, FACE_Z)))
        apply_transform(t)
        parts.append(t)

    # Glass dome (a closed thin shell) and the crack star on it.
    gprof = [(0.0, 0.106), (0.2, 0.103), (0.38, 0.09), (0.382, 0.087), (0.2, 0.1), (0.0, 0.103)]
    parts.append(lathe(gprof, verts=48, closed=True, mat=glass, name="glass", smooth=60))

    def glass_z(x, y):
        rr = math.hypot(x, y)
        return 0.1065 - 0.0165 * (rr / 0.38) ** 2 + 0.001

    hit = Vector((0.17, 0.19))
    rays = [((0.26, 0.31), (0.33, 0.27)), ((0.08, 0.3), (0.02, 0.35)), ((0.05, 0.12), (-0.08, 0.02), (-0.14, -0.05)),
            ((0.24, 0.1), (0.31, 0.0)), ((0.13, 0.08), (0.15, -0.04))]
    for ray in rays:
        prev = hit
        for pt in ray:
            pt = Vector(pt)
            d = pt - prev
            ln = d.length
            seg = box((ln + 0.006, 0.007, 0.0016), pos=(0, 0, 0), bevel=0, mat=crack_mat, name="crack")
            mid = (prev + pt) / 2
            seg.matrix_world = (Matrix.Translation((mid.x, mid.y, glass_z(mid.x, mid.y)))
                                @ Matrix.Rotation(math.atan2(d.y, d.x), 4, 'Z'))
            apply_transform(seg)
            parts.append(seg)
            prev = pt
    # A small starburst ring round the impact point.
    parts.append(torus(0.022, 0.003, pos=(hit.x, hit.y, glass_z(hit.x, hit.y)), major_segments=12,
                       minor_segments=4, mat=crack_mat, name="impact"))

    # Centre cap (static, sits on top of the hands' pivot).
    parts.append(cyl(0.028, 0.015, verts=16, pos=(0, 0, 0.084), bevel=0.006, mat=steel, name="cap"))
    body = join([placed(p) for p in parts], "Body")

    # Hands (built pointing at 12, pivot at the centre).
    hour = hand("HourHand", [(-0.022, -0.05), (0.022, -0.05), (0.02, 0.13), (0.045, 0.16), (0.0, 0.22),
                             (-0.045, 0.16), (-0.02, 0.13)], 0.069, 0.007, ink)
    minute = hand("MinuteHand", [(-0.018, -0.07), (0.018, -0.07), (0.013, 0.26), (0.0, 0.325), (-0.013, 0.26)],
                  0.0775, 0.006, ink)
    second = hand("SecondHand", [(-0.005, -0.1), (0.005, -0.1), (0.004, 0.335), (-0.004, 0.335)], 0.0845,
                  0.004, red)
    tail = placed(cyl(0.022, 0.004, verts=16, pos=(0, -0.085, 0.0845), bevel=0, mat=red, name="counterweight"))
    second = join([second, tail], "SecondHand")
    for h in (hour, minute, second):
        set_origin(h, (0, 0, 0))
    export([body, hour, minute, second], "wall_clock", kind="prop", mount="wall")
