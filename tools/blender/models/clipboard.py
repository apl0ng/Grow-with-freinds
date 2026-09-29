"""clipboard: the Boss's inspection clipboard (held item, kind "item": front -> Godot -Z). M10 events: parented
to the Boss's right hand (Visual/Torso/ArmRight/Hand) during inspections by the events agent's scene.

Floor mount: the board stands upright on its bottom edge, origin at the bottom centre, the sheets facing the
front. 0.25 x 0.36 x 0.07 m (W x H x D, Godot), budget 1500. Held palm-down, rotate it -90 deg about X so
it lies flat in the hand with the sheets up (see the M10 rows in MODELING.md section 8).
Build: a dark masonite board, a steel clip with its spring lever on top, three cream sheets slightly
fanned (the lower ones peeking out crooked), the top sheet's corner curling up, a pen tucked under the clip,
ink lines and a strike-out scribble on the top sheet, a coffee ring. Nobody signs off on anything here.
"""
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gwf import *                       # noqa: E402
from _stencil import *                  # noqa: E402,F401

BW, BH, BT = 0.24, 0.34, 0.012          # board
YF = -BT / 2                             # board front face


def build():
    board_mat = material("board", mix(pal("COCOA"), pal("INK"), 0.55), "matte")
    paper = lib("cream")
    steel = lib("metal_dark")
    ink = material("ink", pal("INK"), "flat")
    pen_mat = lib("white")              # a cheap grubby-white biro
    cap_mat = lib("dark")
    coffee = material("coffee", mix(pal("COCOA"), pal("INK"), 0.3), "matte")

    parts = [box((BW, BT, BH), pos=(0, 0, 0), bevel=0.005, segments=2, mat=board_mat, name="board")]
    # Sheets: two crooked ones peeking out from under the top one, then the top sheet (flat, corner curled).
    y = YF
    for dx, rz, name in ((0.006, 2.8, "sheet_b"), (-0.004, -1.7, "sheet_m")):
        y -= 0.0022
        parts.append(box((0.21, 0.0016, 0.3), pos=(dx, y, 0.015), rot=(0, rz, 0), bevel=0, mat=paper, name=name))
    y -= 0.0022
    top = box((0.21, 0.0016, 0.3), pos=(0, y, 0.015), bevel=0, mat=paper, name="sheet_top")
    subdivide(top, 5)

    def curl(co):  # the bottom-right corner lifts off the board
        k = max(0.0, (co.x - 0.04) / 0.065) * max(0.0, (0.07 - co.z) / 0.07)
        return Vector((co.x, co.y - 0.028 * k ** 1.6, co.z))
    move_verts(top, curl)
    parts.append(top)
    ys = y - 0.0008 - 0.0006            # the top sheet's face, a hair in front
    # Writing: five ruled lines of "notes" (uneven), the lower three struck through.
    for i, (x0, ln) in enumerate(((-0.075, 0.13), (-0.075, 0.1), (-0.075, 0.145), (-0.075, 0.09), (-0.075, 0.12))):
        z = 0.275 - i * 0.026
        parts.append(box((ln, 0.0012, 0.007), pos=(x0 + ln / 2, ys, z), bevel=0, mat=ink, name="line"))
    parts.append(box((0.16, 0.0012, 0.007), pos=(-0.005, ys, 0.19), rot=(0, 0, 14), bevel=0, mat=ink, name="strike"))
    parts.append(box((0.16, 0.0012, 0.007), pos=(-0.005, ys, 0.19), rot=(0, 0, -14), bevel=0, mat=ink, name="strike"))
    # A coffee ring on the sheet.
    parts.append(torus(0.026, 0.0035, pos=(0.045, ys, 0.105), rot=(90, 0, 0), major_segments=18, minor_segments=4,
                       mat=coffee, name="ring", scale=(1, 1, 0.3)))
    # Clip: a steel jaw over the board top and the sheets, a spring lever loop on the front.
    parts.append(box((0.1, 0.03, 0.045), pos=(0, -0.006, 0.312), bevel=0.006, segments=2, mat=steel, name="clip"))
    parts.append(pipe([(-0.032, -0.02, 0.33), (-0.032, -0.05, 0.342), (0.032, -0.05, 0.342), (0.032, -0.02, 0.33)],
                      0.005, verts=8, bend=0.012, mat=steel, name="clip_lever"))
    parts.append(box((0.024, 0.008, 0.01), pos=(0, 0.007, 0.352), bevel=0.002, segments=1, mat=steel, name="hanger"))
    # Pen under the clip, lying across the sheets.
    a, b = Vector((-0.045, -0.021, 0.2)), Vector((0.05, -0.021, 0.33))
    d = (b - a).normalized()
    pen = cyl(0.0065, (b - a).length, verts=10, pos=a, bevel=0.002, segments=1, mat=pen_mat, name="pen")
    pen.rotation_euler = Vector((0, 0, 1)).rotation_difference(d).to_euler()
    parts.append(pen)
    cap = cyl(0.0072, 0.035, verts=10, pos=b - d * 0.035, bevel=0.002, segments=1, mat=cap_mat, name="cap")
    cap.rotation_euler = pen.rotation_euler.copy()
    parts.append(cap)
    clipboard = join(parts, "clipboard")
    export(clipboard, "clipboard", kind="item", mount="floor")
