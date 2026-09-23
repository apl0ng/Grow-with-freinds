"""pendant_lamp family: cheap enamel factory pendants on a cord (worked example of the gwf pipeline).

Replaces the primitives of scenes/world/props/pendant_lamp.tscn (6 m ceiling). CEILING mount: the origin is
the ceiling rose and everything hangs below z = 0. One script, two models (a "family"):
  pendant_lamp        2.5 m cord, 0.92 m shade (the room's lamps; shade top at -2.5 like the old Cap)
  pendant_lamp_short  0.6 m cord, 0.6 m shade (low ceilings, booths)
Nodes in Godot:  <root, Toonify> / Lamp  (rose + cord + socket + crooked, dented shade: one mesh)
                                 / Bulb  (separate: a scene can flicker it or hide it when "off")
Lights stay in the scene (SpotLight3D/OmniLight3D just under the bulb). Swing the whole instance.
"""
from gwf import *

TILT = 4.0  # the shade hangs a little crooked (degrees)


def lamp(name, drop, s):
    """drop = cord length (m), s = head scale (1.0 = 0.58 m shade)."""
    reset()  # families: every model starts from an empty scene (else names collide: "Lamp.001")
    metal = lib("metal_dark")
    enamel = material("enamel", "#51705f", "glossy")                    # tired green enamel
    inner = material("shade_inner", "#d9cfb8", "glow", emission=0.35)   # lit inside of the shade
    bulb_mat = material("bulb", "#efe0bd", "flat")                      # tired tungsten, unshaded

    rose = cyl(0.08, 0.04, verts=20, pos=(0, 0, -0.04), bevel=0.014, mat=metal, name="rose")
    grip = cyl(0.026, 0.035, verts=10, pos=(0, 0, -0.07), bevel=0.008, mat=metal, name="grip")
    # Old cord: not quite straight, a little wobble halfway down.
    cord = pipe([(0, 0, -0.05), (0.006, 0.0, -drop * 0.35), (0.016, 0.006, -drop * 0.7), (0.0, 0.0, -drop)],
                0.022, verts=8, bend=0.08, mat=lib("dark"), name="cord")  # 4.4 cm: reads from 6 m

    top = -drop - 0.03 * s          # shade crown
    pivot = (0.0, 0.0, -drop)       # the head hangs crooked around the cord end
    socket = cyl(0.042 * s, 0.075 * s, verts=16, pos=(0, 0, top - 0.035 * s), bevel=0.012 * s, mat=metal,
                 name="socket")
    collar = torus(0.047 * s, 0.015 * s, pos=(0, 0, top + 0.035 * s), major_segments=16, minor_segments=6,
                   mat=metal, name="collar")
    # Shade: a closed shell (inner dome -> rolled lip -> outer dome), ~1.5 % of its width thick.
    outer = [(0.045, 0.0), (0.11, -0.008), (0.18, -0.035), (0.235, -0.08), (0.268, -0.14), (0.285, -0.2)]
    inner_prof = [(0.272, -0.2), (0.256, -0.142), (0.224, -0.086), (0.172, -0.045), (0.105, -0.02), (0.045, -0.013)]
    prof = [(r * s, top + z * s) for r, z in list(reversed(inner_prof)) + list(reversed(outer))]
    shade = lathe(prof, verts=32, closed=True, mat=enamel, name="shade", smooth=50)
    paint(shade, inner, lambda c, n: (n.x * c.x + n.y * c.y) < -1e-4 or (n.z < -0.2 and math.hypot(c.x, c.y) < 0.26 * s))
    # A knock on the front-right of the shade (front = -Y), pushed in and down.
    dent(shade, (0.2 * s * math.sin(math.radians(40)), -0.2 * s * math.cos(math.radians(40)), top - 0.06 * s),
         radius=0.09 * s, depth=0.022 * s, direction=(-0.4, 0.5, -0.75))
    lip = torus(0.279 * s, 0.014 * s, pos=(0, 0, top - 0.2 * s), major_segments=32, minor_segments=6, mat=metal,
                name="lip")
    thread = cyl(0.034 * s, 0.07 * s, verts=14, pos=(0, 0, top - 0.1 * s), bevel=0.008 * s, mat=metal,
                 name="thread")

    head = join([socket, collar, shade, lip, thread], "head", origin=pivot)
    head.rotation_euler = (math.radians(TILT), math.radians(-TILT * 0.4), 0)
    body = join([rose, grip, cord, head], "Lamp")

    # The bulb hangs from the same crooked head: transform its centre with the head's tilt.
    tilt = Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(TILT), 4, 'X') \
        @ Matrix.Rotation(math.radians(-TILT * 0.4), 4, 'Y') @ Matrix.Translation(-Vector(pivot))
    centre = tilt @ Vector((0, 0, top - 0.19 * s))
    bulb = sphere(0.075 * s, scale=(1, 1, 1.18), segments=16, rings=10, mat=bulb_mat, name="Bulb")
    bulb.matrix_world = Matrix.Translation(centre) @ tilt.to_3x3().to_4x4()
    apply_transform(bulb)
    set_origin(bulb, centre)

    export([body, bulb], name, kind="prop", mount="ceiling")


def build():
    lamp("pendant_lamp", drop=2.45, s=1.6)
    lamp("pendant_lamp_short", drop=0.6, s=1.05)
