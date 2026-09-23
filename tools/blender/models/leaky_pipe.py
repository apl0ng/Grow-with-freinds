"""leaky_pipe: a rusty floor-to-ceiling wall pipe with a leaking flange joint, its drop and its puddle.

Room decor on the west wall. Wall mount, origin on the wall at FLOOR level (the scene root of
scenes/world/props/leaky_pipe.tscn), 0.36 x 5.99 x 0.9 m: the pipe runs from a ceiling flange at 5.99 m
down the wall (0.16 m out), through a leaking flange joint at 2.2 m and a sound one at 4.3 m, and turns
into the wall through an elbow at 0.3 m. Instanced AS `Visual`, three nodes (drip.gd uses the last two):
  Pipe    pipe, flanges + bolts, wall clamps, rust, the wet run down the pipe, damp/rust streak on the wall
  Drop    a water drop hanging under the leaking flange; origin = the drip point (its TOP), so drip.gd
          swells it from the joint (scale) and drops it straight down (position.y) to the puddle
  Puddle  the puddle on the floor under the leak (+ its dark wet rim); origin on the floor at its centre:
          its position.y is the height where drip.gd lets the drop vanish, and it scales it for the splash
Sad: rust creeping up from the elbow and weeping from the joint, a crooked clamp, a missing bolt, the
wall stained dark where the water runs.
"""
from gwf import *

PY = -0.16            # pipe axis, distance out from the wall (Blender -Y): the flanges just clear the wall
PR = 0.09             # pipe radius (the room's pipes are ~0.2 m)
TOP = 5.99            # ceiling (the room is 6 m; the export limit is 6 m)
JOINT = 2.2           # the leaking flange joint
JOINT2 = 4.3          # a sound flange joint
ELBOW_Z = 0.3         # where it turns into the wall
FL_R = 0.15           # flange radius
DRIP = Vector((0.0, PY - (FL_R + 0.005), JOINT - 0.035))   # the drop hangs off the lower flange's front lip
PUDDLE = Vector((0.0, -0.42, 0.0))


def flange_pair(z, metal, bolt_mat, missing=(), gasket=-0.002):
    """Two bolted flanges meeting at height z with the gasket between them (`gasket` = how far it sticks out
    past the flange rim: a leaking joint squeezes it out), 6 hex bolts; `missing` = bolt indices gone."""
    out = []
    for z0 in (z - 0.035, z):
        out.append(cyl(FL_R, 0.035, verts=24, pos=(0, PY, z0), bevel=0.01, segments=1, mat=metal, name="flange"))
    out.append(cyl(FL_R + gasket, 0.012, verts=24, pos=(0, PY, z - 0.006), bevel=0, mat=lib("dark"),
                   name="gasket"))
    for k in range(6):
        if k in missing:
            continue
        a = math.radians(30 + 60 * k)
        x, y = 0.118 * math.sin(a), PY - 0.118 * math.cos(a)
        out.append(cyl(0.021, 0.1, verts=6, pos=(x, y, z - 0.05), bevel=0, mat=bolt_mat, name="bolt"))
    return out


def blob(cx, cy, rx, ry, seed, n=16, wob=0.18):
    pts = []
    for k in range(n):
        a = 2 * math.pi * k / n
        r = 1.0 + wob * math.sin(3 * a + seed) + wob * 0.55 * math.sin(5 * a + 2 * seed)
        pts.append((cx + rx * r * math.cos(a), cy + ry * r * math.sin(a)))
    return pts


def build():
    metal = lib("metal_dark")
    rust = lib("rust")
    damp = lib("concrete_dark")
    water = lib("water")
    parts = []

    # Pipe: straight runs between the flanges, the bottom run bending into the wall.
    parts.append(cyl(PR, TOP - (JOINT2 + 0.035), verts=24, pos=(0, PY, JOINT2 + 0.035), bevel=0, mat=metal,
                     name="run_top"))
    parts.append(cyl(PR, JOINT2 - 0.035 - (JOINT + 0.035), verts=24, pos=(0, PY, JOINT + 0.035), bevel=0,
                     mat=metal, name="run_mid"))
    parts.append(pipe([(0, PY, JOINT - 0.035), (0, PY, ELBOW_Z), (0, 0.0, ELBOW_Z)], PR, verts=24, bend=0.13,
                      caps=True, mat=metal, name="run_low"))
    # Ceiling flange + wall flange at the elbow.
    parts.append(cyl(0.15, 0.03, verts=24, pos=(0, PY, TOP - 0.03), bevel=0.008, segments=1, mat=metal,
                     name="ceiling_flange"))
    parts.append(cyl(0.16, 0.03, verts=24, pos=(0, 0.0, ELBOW_Z), rot=(90, 0, 0), bevel=0.008, segments=1,
                     mat=rust, name="wall_flange"))
    # Flanged joints: the leaking one is rusted over and lost a bolt; the upper one is just dirty.
    parts += flange_pair(JOINT, rust, rust, missing=(2,), gasket=0.005)
    parts += flange_pair(JOINT2, metal, metal)
    # Wall clamps: a strap round the pipe + a foot screwed to the wall (the lower one hangs crooked).
    for z, tilt in ((1.15, 7.0), (3.25, 0.0), (5.1, -3.0)):
        clamp = [torus(PR + 0.012, 0.014, pos=(0, PY, 0), major_segments=20, minor_segments=4, mat=metal,
                       name="strap"),
                 box((0.06, 0.042, 0.05), pos=(0, -0.031, -0.025), bevel=0.008, segments=1, mat=metal,
                     name="foot"),
                 box((0.14, 0.012, 0.08), pos=(0, -0.006, -0.04), bevel=0.005, mat=metal, name="plate")]
        for c in clamp:
            c.matrix_world = (Matrix.Translation((0, 0, z)) @ Matrix.Rotation(math.radians(tilt), 4, 'Y')
                              @ c.matrix_basis)
            apply_transform(c)
        parts += clamp

    # Rust: creeping up the low run from the elbow (wavy top), weeping down from the leaking joint.
    parts.append(band(PR, ELBOW_Z + 0.1, 0.75, thickness=0.004, verts=24, rows=1, pos=(0, PY, 0), mat=rust,
                      name="rust_low", top=lambda a: 0.12 * math.sin(2 * a + 0.5) + 0.05 * math.sin(5 * a)))
    parts.append(band(PR, JOINT - 0.3, JOINT - 0.035, thickness=0.004, verts=24, rows=1, pos=(0, PY, 0), mat=rust,
                      name="rust_weep", bottom=lambda a: -0.25 * max(0.0, math.cos(a)) ** 3
                      - 0.06 * math.sin(3 * a + 1.0)))
    # The wet run: a thin trickle down the front of the pipe from the joint, wobbling, thinning out.
    wet = arc_panel(PR + 0.005, 0.5, angle=12, thickness=0.003, pos=(0, PY, JOINT - 0.54), segments=2, mat=water,
                    name="wet")
    subdivide(wet, 5)

    def trickle(co):
        k = max(0.0, min(1.0, co.z / 0.5))          # 1 at the joint .. 0 at the bottom tip
        a = math.atan2(co.x, -(co.y - PY)) * (0.35 + 0.65 * k) + 0.12 * math.sin(co.z * 9.0)
        r = math.hypot(co.x, co.y - PY)
        return Vector((r * math.sin(a), PY - r * math.cos(a), co.z))
    move_verts(wet, trickle)
    parts.append(wet)

    # Wall stains behind the pipe: a damp dark tongue from the joint to the floor with a rust streak in it.
    # (They spread out wider than the pipe and drift to its left, so they show beside it, not just behind.)
    damp_pts = [(-0.24, JOINT + 0.08), (0.2, JOINT + 0.05), (0.26, 1.6), (0.2, 1.1), (0.3, 0.55), (0.42, 0.02),
                (-0.6, 0.02), (-0.5, 0.45), (-0.44, 1.0), (-0.36, 1.6)]
    parts.append(extrude_profile(damp_pts, 0.002, pos=(0, 0.0, 0.0), bevel=0, mat=damp, name="damp"))
    streak = [(-0.1, JOINT - 0.02), (0.02, JOINT - 0.04), (-0.08, 1.7), (-0.16, 1.2), (-0.22, 0.7),
              (-0.2, 0.3), (-0.3, 0.3), (-0.34, 0.75), (-0.3, 1.25), (-0.22, 1.75)]
    parts.append(extrude_profile(streak, 0.002, pos=(0.0, -0.0015, 0.0), bevel=0, mat=rust, name="streak"))
    pipe_obj = join(parts, "Pipe")

    # Drop: a chunky teardrop hanging from its top (origin = the drip point).
    drop = lathe([(0.0, 0.0), (0.008, -0.008), (0.022, -0.035), (0.034, -0.065), (0.036, -0.085), (0.028, -0.103),
                  (0.014, -0.112), (0.0, -0.114)], verts=16, mat=water, name="Drop", smooth=60)
    drop.location = DRIP
    apply_transform(drop)
    set_origin(drop, DRIP)

    # Puddle: an irregular flat blob of water with a darker wet rim of concrete round it.
    pud = extrude_profile(blob(0, 0, 0.3, 0.22, 0.8), 0.004, rot=(-90, 0, 0), bevel=0.002, segments=1, mat=water,
                          name="water")
    apply_transform(pud)
    pud.location = (0, 0, 0.004)
    rim = extrude_profile(blob(-0.02, 0.01, 0.46, 0.34, 2.2, wob=0.14), 0.003, rot=(-90, 0, 0), bevel=0, mat=damp,
                          name="wet_rim")
    apply_transform(rim)
    rim.location = (0, 0, 0.001)
    puddle = join([pud, rim], "Puddle")
    puddle.location = PUDDLE
    apply_transform(puddle)
    set_origin(puddle, PUDDLE)

    # A 6 m floor-to-ceiling run with two flanged joints and three clamps: a little over the 3k prop budget.
    export([pipe_obj, drop, puddle], "leaky_pipe", kind="prop", mount="wall", budget=3600)
