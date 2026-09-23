"""pendant_lamp: a cheap enamel factory pendant on a cord (worked example of the gwf pipeline).

Replaces scenes/world/props/hanging_lamp.tscn visuals. CEILING mount: the origin is the ceiling rose,
everything hangs below z = 0 (0.9 m drop, shade 0.58 m wide). Two nodes in Godot:
  pendant_lamp (root, Toonify) / Lamp (rose + cord + socket + crooked, dented shade)
                               / Bulb (separate so a scene can flicker it or hide it when "off")
Put the OmniLight3D in the scene at y = -0.8 (bulb centre). Swing the whole instance from its origin.
"""
from gwf import *

DROP = 0.60        # cord length below the ceiling rose
SHADE_TOP = -0.64  # where the shade's crown meets the socket
TILT = 5.0         # the shade hangs a little crooked (degrees)


def build():
    metal = lib("metal_dark")
    enamel = material("enamel", "#51705f", "glossy")                    # tired green enamel
    inner = material("shade_inner", "#d9cfb8", "glow", emission=0.35)   # lit inside of the shade
    bulb_mat = material("bulb", "#efe0bd", "flat")                      # tired tungsten, unshaded

    rose = cyl(0.075, 0.035, verts=20, pos=(0, 0, -0.035), bevel=0.012, mat=metal, name="rose")
    screw = cyl(0.022, 0.03, verts=10, pos=(0, 0, -0.06), bevel=0.006, mat=metal, name="grip")
    # Old cord: not quite straight.
    cord = pipe([(0, 0, -0.04), (0.004, 0.0, -0.22), (0.012, 0.004, -0.40), (0.0, 0.0, -DROP)], 0.014, verts=8,
                bend=0.05, mat=lib("dark"), name="cord")

    # Everything below the cord hangs crooked: build it straight around the pivot, then tilt.
    pivot = (0.0, 0.0, -DROP)
    socket = cyl(0.042, 0.07, verts=16, pos=(0, 0, SHADE_TOP - 0.03), bevel=0.012, mat=metal, name="socket")
    collar = torus(0.046, 0.014, pos=(0, 0, SHADE_TOP + 0.035), major_segments=16, minor_segments=6, mat=metal,
                   name="collar")

    # Shade: a closed shell (outer dome -> rolled lip -> inner dome), 1 cm thick.
    outer = [(0.045, SHADE_TOP), (0.11, SHADE_TOP - 0.008), (0.18, SHADE_TOP - 0.035), (0.235, SHADE_TOP - 0.08),
             (0.268, SHADE_TOP - 0.14), (0.285, SHADE_TOP - 0.2)]
    inner_prof = [(0.272, SHADE_TOP - 0.2), (0.256, SHADE_TOP - 0.142), (0.224, SHADE_TOP - 0.086),
                  (0.172, SHADE_TOP - 0.045), (0.105, SHADE_TOP - 0.02), (0.045, SHADE_TOP - 0.013)]
    shade = lathe(list(reversed(inner_prof)) + list(reversed(outer)), verts=32, closed=True, mat=enamel,
                  name="shade", smooth=50)
    paint(shade, inner, lambda c, n: (n.x * c.x + n.y * c.y) < -1e-4 or (n.z < -0.2 and math.hypot(c.x, c.y) < 0.26))
    dent(shade, (0.2 * math.sin(math.radians(40)), 0.2 * math.cos(math.radians(40)), SHADE_TOP - 0.06),
         radius=0.09, depth=0.022, direction=(-0.4, -0.5, -0.75))
    lip = torus(0.279, 0.013, pos=(0, 0, SHADE_TOP - 0.2), major_segments=32, minor_segments=6, mat=metal,
                name="lip")
    thread = cyl(0.034, 0.07, verts=14, pos=(0, 0, SHADE_TOP - 0.1), bevel=0.008, mat=metal, name="thread")

    head = join([socket, collar, shade, lip, thread], "head", origin=pivot)
    head.rotation_euler = (math.radians(TILT), math.radians(-TILT * 0.4), 0)
    lamp = join([rose, screw, cord, head], "Lamp")

    # Bulb hangs from the same crooked head: place it on the tilted axis.
    tilt = Matrix.Translation(pivot) @ Matrix.Rotation(math.radians(TILT), 4, 'X') \
        @ Matrix.Rotation(math.radians(-TILT * 0.4), 4, 'Y') @ Matrix.Translation(-Vector(pivot))
    bulb = sphere(0.078, pos=(0, 0, 0), scale=(1, 1, 1.18), segments=16, rings=10, mat=bulb_mat, name="Bulb")
    bulb.matrix_world = tilt @ Matrix.Translation((0, 0, SHADE_TOP - 0.19))
    apply_transform(bulb)
    set_origin(bulb, tilt @ Vector((0, 0, SHADE_TOP - 0.19)))

    export([lamp, bulb], "pendant_lamp", mount="ceiling", budget=3000)
