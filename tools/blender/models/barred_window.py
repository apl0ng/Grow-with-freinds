"""barred_window: the factory's one window, barred (room decor, environment modeler).

scenes/world/props/barred_window.tscn instances this model AS `Visual`; the scene keeps its flat night Sky,
Moon and Stars panels, now sitting BEHIND the glass inside the frame's opening (wall plane .. 0.045 m).
Wall mount: the origin is the window centre on the wall plane, back on Blender y = 0, body towards the front
(-Y = Godot +Z). 1.84 x 1.95 x 0.25 m (frame 1.7 x 1.3, sill below, rust streak down the wall).
  Window   steel frame with a real opening (the reveal runs back to the wall), a cross of mullions, four dark
           glass panes (one cracked with a shard missing), five bars on two straps (one bar bent outwards where
           somebody pulled on it), rust at the bars' feet, a chipped concrete sill, a rust streak under it.
"""
import bpy
import bmesh
from gwf import *

W, H = 1.7, 1.3          # frame outside
OW, OH = 1.42, 1.02      # opening
DEPTH = 0.13             # frame depth (Blender -y)
GLASS_Y = -0.05          # glass plane (Godot z 0.05): the scene's sky/moon/stars sit behind it
BAR_Y = -0.19
BARS_X = (-0.54, -0.27, 0.0, 0.27, 0.54)
BENT = 0.27              # the bar somebody pulled on


def build():
    metal = lib("metal_dark")
    glass = material("glass_dark", "#34404e", "glossy", alpha=0.42, double_sided=True)

    frame = box((W, DEPTH, H), pos=(0, -DEPTH / 2, -H / 2), bevel=0, mat=metal, name="frame")
    boolean_cut(frame, box((OW, 0.4, OH), pos=(0, 0, -OH / 2), bevel=0, name="opening"))
    bevel(frame, 0.024, segments=2)
    parts = [frame]
    # Mullions (a cross) just behind the glass line.
    parts.append(box((0.05, 0.05, OH + 0.02), pos=(0, GLASS_Y + 0.012, -OH / 2 - 0.01), bevel=0.01, mat=metal,
                     name="mullion_v"))
    parts.append(box((OW + 0.02, 0.05, 0.05), pos=(0, GLASS_Y + 0.012, -0.025), bevel=0.01, mat=metal,
                     name="mullion_h"))
    # Four panes; the lower right one has a shard missing and cracks running out from the hole.
    hx, hz = OW / 2, OH / 2
    panes = {
        (-1, 1): [(-hx, 0), (0, 0), (0, hz), (-hx, hz)],
        (1, 1): [(0, 0), (hx, 0), (hx, hz), (0, hz)],
        (-1, -1): [(-hx, -hz), (0, -hz), (0, 0), (-hx, 0)],
        (1, -1): [(0, -hz), (hx, -hz), (hx, 0), (0.42, 0.0), (0.33, -0.12), (0.46, -0.21), (0.24, -0.16),
                  (0.16, 0.0), (0, 0)],
    }
    for key in sorted(panes):
        parts.append(extrude_profile(panes[key], 0.006, pos=(0, GLASS_Y + 0.003, 0), bevel=0, mat=glass,
                                     name="pane"))
    for (x0, z0, x1, z1) in ((0.33, -0.12, 0.2, -0.36), (0.3, -0.18, 0.55, -0.4), (0.46, -0.21, 0.66, -0.12),
                             (0.24, -0.16, 0.08, -0.3)):
        L = math.hypot(x1 - x0, z1 - z0)
        ang = math.degrees(math.atan2(z1 - z0, x1 - x0))
        parts.append(box((L, 0.004, 0.012), pos=((x0 + x1) / 2, GLASS_Y - 0.004, (z0 + z1) / 2 - 0.006),
                         rot=(0, -ang, 0), bevel=0, mat="dark", name="crack"))
    # Straps across the top and bottom of the opening, standing off the frame front.
    for z in (-0.57, 0.5):
        parts.append(box((1.52, 0.022, 0.07), pos=(0, BAR_Y, z), bevel=0.006, mat=metal, name="strap"))
        for sx in (-0.74, 0.74):
            parts.append(box((0.07, -DEPTH - BAR_Y + 0.01, 0.07), pos=(sx, (BAR_Y - DEPTH) / 2, z),
                             bevel=0.005, mat=metal, name="standoff"))
            parts.append(cyl(0.02, 0.02, verts=6, pos=(sx, BAR_Y - 0.01, z + 0.035), rot=(90, 0, 0), bevel=0,
                             mat=metal, name="bolt"))
    # Bars: capsules through the straps; one bowed out towards the room.
    for i, x in enumerate(BARS_X):
        if x == BENT:
            pts = [(x, BAR_Y, -0.64), (x, BAR_Y, -0.52), (x - 0.01, BAR_Y - 0.05, -0.2), (x - 0.015, BAR_Y - 0.075, 0.02),
                   (x - 0.005, BAR_Y - 0.05, 0.28), (x, BAR_Y, 0.52), (x, BAR_Y, 0.64)]
            bar = pipe(pts, 0.028, verts=12, bend=0.1, mat=metal, name="bar")
        else:
            bar = capsule(0.028, 1.28, pos=(x, BAR_Y, -0.64), verts=12, rings=4, mat=metal, name="bar")
        parts.append(bar)
        if i in (0, 1, 3):
            parts.append(band(0.028, -0.6, -0.48 + 0.03 * i, thickness=0.002, verts=12, rows=1, pos=(x, BAR_Y, 0),
                              mat="rust", name="bar_rust", top=lambda a, i=i: 0.03 * math.sin(2 * a + i)))
    # Anchor bolts in the frame corners.
    for sx in (-1, 1):
        for sz in (-1, 1):
            parts.append(cyl(0.024, 0.02, verts=6, pos=(sx * (W / 2 - 0.07), -DEPTH, sz * (H / 2 - 0.07)),
                             rot=(90, 0, 0), bevel=0, mat=metal, name="anchor"))
    # Concrete sill, chipped at the front right corner.
    sill = box((1.84, 0.23, 0.1), pos=(0, -0.115, -0.75), bevel=0, mat="concrete_dark", name="sill")
    boolean_cut(sill, box((0.3, 0.2, 0.2), pos=(0.9, -0.24, -0.72), rot=(20, 0, 35), bevel=0, name="chip"))
    bevel(sill, 0.018, segments=2)
    parts.append(sill)
    # Rust running down from the bars over the sill lip and down the wall.
    parts.append(extrude_profile([(-0.31, -0.748), (-0.19, -0.748), (-0.2, -0.88), (-0.212, -1.02), (-0.218, -1.12),
                                  (-0.232, -1.165), (-0.25, -1.178), (-0.268, -1.165), (-0.282, -1.12), (-0.29, -1.0),
                                  (-0.3, -0.88)], 0.003, pos=(0, -0.001, 0), bevel=0, mat="rust", name="streak"))
    parts.append(extrude_profile([(-0.3, -0.748), (-0.2, -0.748), (-0.2, -0.702), (-0.3, -0.702)], 0.003,
                                 pos=(0, -0.231, 0), bevel=0, mat="rust", name="sill_rust"))
    parts.append(box((0.1, 0.23, 0.004), pos=(-0.25, -0.115, -0.651), bevel=0, mat="rust", name="sill_top_rust"))
    win = join(parts, "Window")
    export(win, "barred_window", kind="prop", mount="wall")
