"""pipe_run family: modular ceiling/wall pipework, 0.2 m bore (room decor, environment modeler).

Long runs are tiled from these modules (the size limit is 6 m): scenes/world/props/pipe_segment.tscn tiles
`pipe_straight_2m` N times in ONE node (segment_run.gd, a MultiMesh), pipe_elbow/valve/hanger.tscn place one.
All are mount "free" with the ORIGIN ON THE PIPE AXIS; the run goes along Blender X (Godot X). The pipe paint is
TINT (the scene picks steel / olive / rust); flanges, bolts and valve bodies are metal_dark, rust is rust.
  pipe_straight_2m  x -1..1: pipe with a flanged joint at each end (two segments meet flange to flange,
                    bolts facing their own pipe), rust bleeding from the joints (more underneath), a drip, a dent
  pipe_straight_1m  the same, x -0.5..0.5 (short runs: the well's feed pipe)
  pipe_elbow        90 degree long-radius bend, legs along +X and +Z (Godot +X / +Y), origin at the corner
                    where the two axes meet, flange faces 0.4 m out; rust on the belly of the bend
  pipe_valve        inline gate valve, flange faces at x +-0.25: cast body, bonnet, stem, red handwheel on top
  pipe_hanger       clevis clamp round the pipe + a 1.1 m threaded rod up to the ceiling (disappears into it)
"""
from gwf import *

R = 0.1          # pipe radius
FR = 0.155       # flange radius
FT = 0.05        # flange thickness
V = 20           # radial segments


def paint_mat():
    return tint_material("TINT_paint")


def flange_z(z_face, up=True, name="flange"):
    """Weld-neck flange around the Z axis whose joint face is at z_face (facing +Z if up), with 6 nuts."""
    s = 1 if up else -1
    prof = [(R + 0.002, z_face - s * 0.09), (R + 0.024, z_face - s * FT), (FR, z_face - s * FT), (FR, z_face),
            (0.0, z_face)]
    if not up:
        prof = [(0.0, z_face), (FR, z_face), (FR, z_face + FT), (R + 0.024, z_face + FT), (R + 0.002, z_face + 0.09)]
    parts = [lathe(prof, verts=V, mat="metal_dark", name=name, smooth=30)]
    for i in range(6):
        a = math.radians(30 + 60 * i)
        z0 = z_face - s * FT - (0.022 if up else 0.0)
        parts.append(cyl(0.019, 0.022, verts=6, pos=(0.127 * math.cos(a), 0.127 * math.sin(a), z0), bevel=0,
                         mat="metal_dark", name="nut"))
    return parts


def lay_on_x(objs):
    """Turn parts built round the Z axis onto the X axis (local +X = world down afterwards)."""
    for o in objs:
        apply_transform(o)
        o.data.transform(Matrix.Rotation(math.radians(90), 4, 'Y'))


def pipe_straight(name, half):
    reset()
    h = half - 0.045
    zs = sorted({-h, h} | {round(z * 0.3, 4) for z in range(-int(h / 0.3), int(h / 0.3) + 1)})
    body = lathe([(R, z) for z in zs], verts=V, mat=paint_mat(), name="pipe")
    dent(body, (R * math.cos(math.radians(-110)), R * math.sin(math.radians(-110)), -0.32 * half),
         radius=0.16, depth=0.018)
    parts = [body] + flange_z(half, True) + flange_z(-half, False)
    # Rust bleeding out of both joints, creeping further along the underside (local +X = down).
    under = lambda a: max(0.0, math.cos(a - math.pi / 2))
    parts.append(band(R, half - 0.28, half - 0.05, thickness=0.003, verts=V, rows=2, mat="rust", name="rust",
                      bottom=lambda a: -0.22 * under(a) * min(1.0, half) + 0.035 * math.sin(5 * a + 1)))
    parts.append(band(R, -half + 0.05, -half + 0.2, thickness=0.003, verts=V, rows=2, mat="rust", name="rust",
                      top=lambda a: 0.16 * under(a) * min(1.0, half) + 0.03 * math.sin(4 * a)))
    parts.append(arc_panel(R + 0.004, 0.09, angle=46, thickness=0.004, pos=(0, 0, 0.32 * half), rot=(0, 0, 90),
                           segments=4, mat="rust", name="drip"))
    lay_on_x(parts)
    export(join(parts, "Pipe"), name, kind="prop", mount="free")


def pipe_elbow():
    reset()
    L, RB = 0.4, 0.26
    c = Vector((RB, 0, RB))
    pts = [(L - FT + 0.01, 0, 0), (RB + 0.02, 0, 0)]
    pts += [tuple(c + RB * Vector((-math.sin(t), 0, -math.cos(t)))) for t in (math.radians(d) for d in range(0, 91, 10))]
    pts += [(0, 0, RB + 0.02), (0, 0, L - FT + 0.01)]
    body = pipe(pts, R, verts=V, bend=0, mat=paint_mat(), name="bend")
    paint(body, "rust", lambda cc, n: n.z < -0.55 and cc.x > 0.02 and cc.z < RB * 0.8)
    up = flange_z(L, True, "flange_up")
    side = flange_z(L, True, "flange_side")
    for o in side:
        apply_transform(o)
        o.data.transform(Matrix.Rotation(math.radians(90), 4, 'Y'))   # +Z face -> +X face
    export(join([body] + up + side, "Elbow"), "pipe_elbow", kind="prop", mount="free")


def pipe_valve():
    reset()
    iron = lib("metal_dark")
    body = lathe([(R + 0.004, -0.2), (0.13, -0.16), (0.155, -0.09), (0.16, 0.0), (0.155, 0.09), (0.13, 0.16),
                  (R + 0.004, 0.2)], verts=V, mat=iron, name="body", smooth=40)
    parts = [body] + flange_z(0.25, True) + flange_z(-0.25, False)
    parts.append(arc_panel(0.162, 0.2, angle=80, thickness=0.004, pos=(0, 0, -0.1), rot=(0, 0, 90), segments=6,
                           mat="rust", name="rust"))
    lay_on_x(parts)
    # Bonnet, gland nut, stem and the handwheel, pointing up (+Z).
    parts.append(cyl(0.075, 0.2, verts=16, pos=(0, 0, 0.1), bevel=0.012, mat=iron, name="bonnet"))
    parts.append(cyl(0.1, 0.03, verts=16, pos=(0, 0, 0.28), bevel=0.006, mat=iron, name="bonnet_flange"))
    for i in range(4):
        a = math.radians(45 + 90 * i)
        parts.append(cyl(0.016, 0.02, verts=6, pos=(0.08 * math.cos(a), 0.08 * math.sin(a), 0.31), bevel=0, mat=iron,
                         name="bonnet_nut"))
    parts.append(cyl(0.05, 0.04, verts=6, pos=(0, 0, 0.31), bevel=0, mat=iron, name="gland"))
    parts.append(cyl(0.02, 0.14, verts=10, pos=(0, 0, 0.35), bevel=0, mat=lib("metal"), name="stem"))
    wheel_z = 0.45
    parts.append(torus(0.14, 0.022, pos=(0, 0, wheel_z), major_segments=24, minor_segments=6, mat="red",
                       name="wheel"))
    for i in range(3):
        parts.append(box((0.27, 0.024, 0.02), pos=(0, 0, wheel_z - 0.01), rot=(0, 0, 60 * i + 15), bevel=0,
                         mat="red", name="spoke", anchor="base"))
    parts.append(cyl(0.035, 0.05, verts=12, pos=(0, 0, wheel_z - 0.025), bevel=0.008, mat=iron, name="hub"))
    export(join(parts, "Valve"), "pipe_valve", kind="prop", mount="free")


def pipe_hanger():
    reset()
    iron = lib("metal_dark")
    ring = torus(R + 0.014, 0.014, pos=(0, 0, 0), rot=(0, 90, 0), major_segments=20, minor_segments=5, mat=iron,
                 name="clamp")
    ears = [box((0.03, 0.012, 0.07), pos=(0, sy * 0.013, R + 0.005), bevel=0, mat=iron, name="ear") for sy in (-1, 1)]
    bolt = cyl(0.012, 0.07, verts=6, pos=(0, -0.035, R + 0.045), rot=(-90, 0, 0), bevel=0, mat=iron, name="bolt")
    rod = cyl(0.011, 1.1, verts=6, pos=(0, 0, R + 0.07), bevel=0, mat=iron, name="rod")
    nuts = [cyl(0.02, 0.02, verts=6, pos=(0, 0, z), bevel=0, mat=iron, name="nut") for z in (R + 0.075, R + 0.25)]
    rust = arc_panel(R + 0.024, 0.032, angle=70, thickness=0.004, pos=(0, 0, -0.016), rot=(0, 0, 90), segments=5,
                     mat="rust", name="rust")
    lay_on_x([rust])
    export(join([ring, bolt, rod, rust] + ears + nuts, "Hanger"), "pipe_hanger", kind="prop", mount="free")


def build():
    pipe_straight("pipe_straight_2m", 1.0)
    pipe_straight("pipe_straight_1m", 0.5)
    pipe_elbow()
    pipe_valve()
    pipe_hanger()
