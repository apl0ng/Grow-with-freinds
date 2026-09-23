"""sign_board: the backing frame + board of every wall sign, poster and the DEBT BOARD (room decor).

Wall mount, origin = the board centre on the wall. Both parts are UNIT meshes (1 x 1 m, centred on the
origin): scenes/world/props/sign_board.gd stretches `Visual/Board` to `board_size` and `Visual/Frame` to
`board_size + 2 * frame_width` and swaps their materials (`board_material` / `frame_material`: dark
chalkboard + wood frame for "PAY UP", rust or caution boards on steel for the posters), so the model
carries the SHAPE and the scene/instance carries the colours; the text stays the scene's `Text` Label3D
(at 7.5 cm in front of the wall, so everything here stays behind 7.2 cm). Instanced AS `Visual`.
  Frame  a chunky backing slab, 5 cm deep, rounded front edges, one knocked-in corner, a ledge along the
         bottom (the chalk tray)
  Board  a 3 cm plate standing 1 cm proud of the frame, bowed a little, its bottom-right corner curling off
Bevels are small (they stretch with the board). Default colours (no override): caution board on a
metal_dark frame, like the placeholder.
"""
from gwf import *
import bmesh
import bpy


def grid_plate(name, n, thick, mat, y_back):
    """A 1 x 1 m plate in the XZ plane (x right, z up) from y_back towards -Y by `thick`, with an n x n
    grid on the front and back faces (so it can bow and curl) and single strips round its edges."""
    verts, faces = [], []

    def vid(i, j, k):
        return (k * (n + 1) + j) * (n + 1) + i
    for yv in (y_back - thick, y_back):          # k = 0: front face, k = 1: back face
        for j in range(n + 1):
            for i in range(n + 1):
                verts.append((-0.5 + i / n, yv, -0.5 + j / n))
    for j in range(n):
        for i in range(n):
            faces.append((vid(i, j, 0), vid(i + 1, j, 0), vid(i + 1, j + 1, 0), vid(i, j + 1, 0)))
            faces.append((vid(i, j, 1), vid(i, j + 1, 1), vid(i + 1, j + 1, 1), vid(i + 1, j, 1)))
    for i in range(n):
        faces.append((vid(i, 0, 0), vid(i, 0, 1), vid(i + 1, 0, 1), vid(i + 1, 0, 0)))
        faces.append((vid(i, n, 0), vid(i + 1, n, 0), vid(i + 1, n, 1), vid(i, n, 1)))
        faces.append((vid(0, i, 0), vid(0, i + 1, 0), vid(0, i + 1, 1), vid(0, i, 1)))
        faces.append((vid(n, i, 0), vid(n, i, 1), vid(n, i + 1, 1), vid(n, i + 1, 0)))
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.update()
    bm = bmesh.new()
    bm.from_mesh(me)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    me.materials.append(mat)
    set_smooth(obj, 35)
    return obj


def build():
    # Frame: backing slab, back on the wall; a corner knocked in at the top left (pushed back + down).
    frame = box((1.0, 0.05, 1.0), pos=(0, -0.025, 0), anchor="center", bevel=0, mat=lib("metal_dark"),
                name="Frame")
    set_origin(frame, (0, 0, 0))                     # scaled about the wall centre (the script's pivot)
    subdivide(frame, 3)
    dent(frame, (-0.5, -0.05, 0.5), radius=0.22, depth=0.012, direction=(0.3, 1.0, -0.3))
    move_verts(frame, lambda c: Vector((c.x, min(0.0, c.y), c.z)))   # never through the wall
    bevel(frame, 0.012, segments=2)
    # A ledge along the bottom rail (a chalk tray on the chalkboard, a fat bottom rail on the posters): it
    # stretches with the board's width; its height scales with the board, 3-6 cm on the room's signs.
    ledge = box((1.0, 0.07, 0.035), pos=(0, -0.035, -0.5), bevel=0.01, segments=2, mat=lib("metal_dark"),
                name="ledge")
    frame = join([frame, ledge], "Frame")

    # Board: proud of the frame (y -0.03 .. -0.06), bowed ~4 mm, the bottom-right corner curling out 12 mm
    # (everything stays behind the Text label at 7.5 cm).
    board = grid_plate("Board", 8, 0.03, lib("caution"), -0.03)

    def warp(c):
        bow = 0.004 * (1 - (2 * c.x) ** 2) * (1 - (2 * c.z) ** 2)
        d = math.hypot(c.x - 0.5, c.z + 0.5)            # distance from the bottom-right corner
        curl = 0.012 * max(0.0, 1 - d / 0.22) ** 2
        return Vector((c.x, c.y - bow - curl, c.z))
    move_verts(board, warp)
    bevel(board, 0.006, segments=1)
    export([frame, board], "sign_board", kind="prop", mount="wall")
