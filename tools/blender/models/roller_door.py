"""roller_door: the factory's big rusty exit shutter, barred by one skinny plank (room decor).

scenes/world/props/roller_door.tscn instances this model AS `Visual` (MODELING section 5 pattern B), so the
placeholder's node paths stay valid. Floor mount with the back on the wall plane (Blender y = 0), body in front
(-Y = Godot +Z), 4.8 x 4.3 x 0.62 m:
  Shutter        curtain (18 corrugated slats in 4.0 x 3.6 m, rust eating up from the floor, blotches, drips from
                 the drum, a dent where someone kicked it, the bottom-left corner pried up, tally marks scratched
                 in at knee height), side rails, the coil drum, bottom bar with hazard stripes, beam brackets, hasp
  Beam           the skinny wooden bar across the brackets: the one thing keeping everyone in (origin: its centre)
  Chain          wrapped round the beam, running down to the hasp (origin: the wrap)
  PadlockBody    tarnished brass lock hanging on the hasp (origin: the hang point)
  PadlockShackle its shackle (origin: the hang point)
"""
import bpy
import bmesh
from gwf import *

X0, X1 = -2.04, 2.04        # curtain edges (hidden inside the rails)
Z_BOT = 0.12                # curtain bottom (top of the bottom bar)
SLAT = 0.2
N_SLATS = 18                # -> top at 3.72, tucked under the drum
# Slat profile (height in the slat, y): groove, lower shoulder, crest, top lip. Front = -y.
PROFILE = [(0.0, -0.022), (0.05, -0.062), (0.13, -0.073), (0.2, -0.036)]
BEAM_Y = -0.245             # beam centre depth
BRACKET_X = 2.3
ARM_Z = {-1: 1.23, 1: 1.28}  # top of each bracket's arm (the left one was bolted on 5 cm low)
DENT = (0.3, 0.8, 0.36, 0.03)        # x, z, radius, depth (pushed IN: somebody kicked it from in here)
PRY_X = -1.35                         # left of this the bottom slats are pried up towards the room


def mesh_obj(name, bm, mat, smooth=35.0):
    me = bpy.data.meshes.new(name)
    bm.normal_update()
    bm.to_mesh(me)
    bm.free()
    obj = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(obj)
    obj["gwf_smooth"] = float(smooth)
    if mat is not None:
        me.materials.append(lib(mat) if isinstance(mat, str) else mat)
    return obj


def slice_x(obj, xs):
    """Loop cuts across X only (bisect planes) so a long box can bend without subdividing everything."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    for x in xs:
        geom = bm.verts[:] + bm.edges[:] + bm.faces[:]
        bmesh.ops.bisect_plane(bm, geom=geom, plane_co=(x, 0, 0), plane_no=(1, 0, 0))
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()
    return obj


def grid(name, x0, x1, z0, z1, y, nx, nz, mat):
    """A flat sheet facing the front (-Y), nx x nz quads."""
    bm = bmesh.new()
    vs = [[bm.verts.new((x0 + (x1 - x0) * i / nx, y, z0 + (z1 - z0) * j / nz)) for j in range(nz + 1)]
          for i in range(nx + 1)]
    for i in range(nx):
        for j in range(nz):
            bm.faces.new((vs[i][j], vs[i + 1][j], vs[i + 1][j + 1], vs[i][j + 1]))
    for f in bm.faces:
        f.normal_update()
        if f.normal.y > 0:
            f.normal_flip()
    return mesh_obj(name, bm, mat, smooth=40.0)


def chain(points, pitch=0.095, width=0.066, r=0.012, name="chain", mat="metal_dark", n0=(0, -1, 0), sides=3):
    """Interlocking links (6-sided stadium rings, `sides`-sided wire) resampled along a polyline."""
    pts = [Vector(p) for p in points]
    seg = [(a, b, (b - a).length) for a, b in zip(pts, pts[1:])]
    total = sum(l for _, _, l in seg)
    n = max(1, int(total / pitch))
    step = total / n

    def at(s):
        for a, b, l in seg:
            if s <= l or (a, b, l) == seg[-1]:
                return a.lerp(b, min(1.0, s / l) if l > 0 else 0.0)
            s -= l
    bm = bmesh.new()
    a_end = width / 2 - r
    s_half = max(0.0, step / 2 + r - a_end)
    ref = Vector(n0)
    for k in range(n):
        p, q = at(k * step), at((k + 1) * step)
        c, t = (p + q) / 2, (q - p).normalized()
        nn = (ref - t * ref.dot(t))
        nn = nn.normalized() if nn.length > 1e-4 else t.orthogonal().normalized()
        if k % 2:
            nn = t.cross(nn).normalized()
        b = nn.cross(t)
        # centreline of the link: 3 points round each end
        cl = [(s_half, -a_end), (s_half + a_end, 0), (s_half, a_end), (-s_half, a_end), (-s_half - a_end, 0),
              (-s_half, -a_end)]
        cl = [c + t * u + b * v for u, v in cl]
        rings = []
        for i, pnt in enumerate(cl):
            tan = (cl[(i + 1) % 6] - cl[i - 1]).normalized()
            out = tan.cross(nn).normalized()
            if out.dot(pnt - c) < 0:
                out = -out
            rings.append([bm.verts.new(pnt + out * r * math.cos(j * 2 * math.pi / sides)
                                       + nn * r * math.sin(j * 2 * math.pi / sides)) for j in range(sides)])
        for i in range(6):
            ra, rb = rings[i], rings[(i + 1) % 6]
            for j in range(sides):
                bm.faces.new((ra[j], rb[j], rb[(j + 1) % sides], ra[(j + 1) % sides]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return mesh_obj(name, bm, mat, smooth=60.0)


# ------------------------------------------------------------------------------------------ rust pattern
def band_top(x):
    """Rust eating up from the floor: height of its ragged top edge."""
    return 0.62 + 0.28 * math.sin(1.9 * x + 0.4) + 0.14 * math.sin(4.7 * x + 2.1) + (0.35 if x < PRY_X else 0.0)


BLOTCHES = [(-0.95, 2.1, 0.42, 0.38), (1.3, 1.45, 0.3, 0.3), (0.15, 2.95, 0.2, 0.22), (-1.75, 3.1, 0.18, 0.3)]
DRIPS = [(-1.2, 2.45, 0.13), (0.45, 3.0, 0.1), (1.72, 2.15, 0.15), (-0.3, 3.3, 0.08), (0.95, 3.35, 0.07)]
TOP = Z_BOT + N_SLATS * SLAT


def rust_spans(zc, k):
    spans = []
    xs = [X0 + i * 0.04 for i in range(int((X1 - X0) / 0.04) + 1)]
    run = None
    for x in xs:
        if zc < band_top(x):
            run = [x, x] if run is None else [run[0], x]
        elif run is not None:
            spans.append(run)
            run = None
    if run is not None:
        spans.append(run)
    for cx, cz, rx, rz in BLOTCHES:
        d = (zc - cz) / rz
        if abs(d) < 1:
            h = rx * math.sqrt(1 - d * d) * (0.85 + 0.3 * math.sin(k * 2.3 + cx))
            spans.append([cx - h, cx + h * (0.9 + 0.2 * math.sin(k * 1.7))])
    for cx, z_end, w in DRIPS:
        if zc > z_end:
            h = w * (0.35 + 0.65 * (zc - z_end) / (TOP - z_end)) / 2
            spans.append([cx - h, cx + h])
    spans = sorted([max(X0, round(a / 0.02) * 0.02), min(X1, round(b / 0.02) * 0.02)] for a, b in spans)
    merged = []
    for a, b in spans:
        if b - a < 0.03:
            continue
        if merged and a <= merged[-1][1] + 0.03:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return merged


def deform(co):
    """Kick dent (pushed in) + the pried-up bottom-left corner, on (x, z)."""
    x, y, z = co
    dx, dz, rad, depth = DENT
    d = math.hypot(x - dx, (z - dz) * 1.2)
    if d < rad:
        y += depth * (1 - (d / rad) ** 2) ** 2
    if x < PRY_X and z < Z_BOT + 2.2 * SLAT:
        u = (PRY_X - x) / (PRY_X - X0)
        v = 1 - max(0.0, z - Z_BOT) / (2.2 * SLAT)
        y -= 0.13 * u * u * v
        z += 0.06 * u * u * v
    return Vector((x, y, z))


def curtain():
    bm = bmesh.new()
    rust_faces, groove_faces = [], []
    for k in range(N_SLATS):
        z0 = Z_BOT + k * SLAT
        zc = z0 + 0.1
        spans = rust_spans(zc, k)
        xs = {round(X0 + i * (X1 - X0) / 5, 4) for i in range(6)}
        for a, b in spans:
            xs.update((round(a, 4), round(b, 4)))
        if abs(zc - DENT[1]) < DENT[2]:
            xs.update(round(DENT[0] + o, 4) for o in (-0.36, -0.24, -0.12, 0.0, 0.12, 0.24, 0.36))
        if z0 < Z_BOT + 2 * SLAT:
            xs.update(round(PRY_X - o, 4) for o in (0.2, 0.4))
        xs = sorted(x for x in xs if X0 <= x <= X1)
        cols = [[bm.verts.new(deform((x, y, z0 + t))) for t, y in PROFILE] for x in xs]
        for i in range(len(xs) - 1):
            xm = (xs[i] + xs[i + 1]) / 2
            rusty = any(a <= xm <= b for a, b in spans)
            for j in range(len(PROFILE) - 1):
                f = bm.faces.new((cols[i][j], cols[i + 1][j], cols[i + 1][j + 1], cols[i][j + 1]))
                if rusty:
                    rust_faces.append(f)
                elif j == 0:
                    groove_faces.append(f)
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    for f in bm.faces:           # every face must look at the room (-Y)
        if f.normal.y > 0:
            f.normal_flip()
    rust_set, groove_set = set(rust_faces), set(groove_faces)
    for f in bm.faces:
        f.material_index = 1 if f in rust_set else (2 if f in groove_set else 0)
    obj = mesh_obj("curtain", bm, "metal_dark", smooth=40.0)
    obj.data.materials.append(lib("rust"))
    obj.data.materials.append(lib("dark"))
    return obj


def backing():
    """Dark sheet just behind the slats' grooves: the gaps between slats read black."""
    b = grid("backing", X0, X1, Z_BOT - 0.03, TOP + 0.02, -0.017, 10, 8, "dark")
    # Follows the pried corner; under the kick dent it stays on the wall plane (the pushed-in grooves behind
    # it are dark too, so nothing changes to the eye).
    move_verts(b, lambda co: (lambda d: Vector((d.x, min(d.y, -0.002), d.z)))(deform(co)))
    return b


def rust_decal(x0, x1, y, zmax_fn, name, z0=0.0, n=8):
    """Flat rust patch with a wavy top on a flat front face at depth y (extruded 4 mm towards the front)."""
    pts = [(x0, z0), (x1, z0)] + [(x1 - (x1 - x0) * i / n, zmax_fn(x1 - (x1 - x0) * i / n)) for i in range(n + 1)]
    return extrude_profile(pts, 0.004, pos=(0, y, 0), bevel=0, mat="rust", name=name)


def build():
    metal, rust = lib("metal_dark"), lib("rust")
    parts = [curtain(), backing()]

    # Bottom bar (bent up with the pried corner) + hazard stripes + lift handles.
    bar = box((X1 - X0 + 0.04, 0.1, 0.12), pos=(0, -0.062, 0), bevel=0.018, mat="dark", name="bottom_bar")
    slice_x(bar, [PRY_X + 0.1, PRY_X - 0.15, PRY_X - 0.35, PRY_X - 0.55])
    move_verts(bar, deform)
    parts.append(bar)
    for i in range(18):
        x = X0 + 0.06 + i * 0.23
        if x > X1 - 0.2:
            break
        s = extrude_profile([(x, 0.012), (x + 0.1, 0.012), (x + 0.18, 0.108), (x + 0.08, 0.108)], 0.006,
                            pos=(0, -0.11, 0), bevel=0, mat="caution", name="stripe")
        move_verts(s, deform)
        parts.append(s)
    for hx in (-0.9, 0.9):
        parts.append(pipe([(hx - 0.12, -0.11, 0.05), (hx - 0.12, -0.17, 0.05), (hx + 0.12, -0.17, 0.05),
                           (hx + 0.12, -0.11, 0.05)], 0.016, verts=6, bend=0, mat="metal_dark", name="handle"))
    # The gap under the pried corner: a sliver of nothing.
    parts.append(extrude_profile([(X0 + 0.02, 0.0), (PRY_X, 0.0), (X0 + 0.02, 0.05)], 0.02, pos=(0, -0.02, 0.001),
                                 bevel=0, mat="void", name="gap"))

    # Side rails (channels the curtain runs in) on wall plates, bolted; rust at their feet.
    for sx in (-1, 1):
        parts.append(box((0.14, 0.15, 3.78), pos=(sx * 2.09, -0.075, 0), bevel=0.016, mat="metal_dark", name="rail"))
        parts.append(box((0.3, 0.02, 3.78), pos=(sx * 2.12, -0.01, 0), bevel=0.005, mat="metal_dark", name="plate"))
        for z in (0.4, 1.8, 3.2):
            parts.append(cyl(0.022, 0.025, verts=6, pos=(sx * 2.235, -0.02, z), rot=(90, 0, 0), bevel=0,
                             mat="metal_dark", name="bolt"))
        parts.append(rust_decal(sx * 2.09 - 0.07, sx * 2.09 + 0.07, -0.151,
                                lambda x, s=sx: 0.36 + 0.09 * math.sin(20 * x + s), "rail_rust"))

    # The coil drum (axis along X) with end plates, hubs and wall gussets; rust on its belly and a drip.
    dz, dy, dr = 3.98, -0.315, 0.3
    parts.append(cyl(dr, 4.3, verts=24, pos=(0, dy, dz), rot=(0, 90, 0), bevel=0.018, mat="metal_dark", name="drum",
                     anchor="center"))
    for sx in (-1, 1):
        parts.append(cyl(dr + 0.04, 0.05, verts=24, pos=(sx * 2.175, dy, dz), rot=(0, 90, 0), bevel=0,
                         mat="metal_dark", name="end_plate", anchor="center"))
        parts.append(cyl(0.075, 0.08, verts=12, pos=(sx * 2.22, dy, dz), rot=(0, 90, 0), bevel=0,
                         mat="dark", name="hub", anchor="center"))
        parts.append(extrude_profile([(sx * 2.15, 3.62), (sx * 2.28, 3.62), (sx * 2.28, 4.3), (sx * 2.15, 4.3)],
                                     0.02, pos=(0, 0, 0), rot=(0, 0, 0), bevel=0.005, mat="metal_dark", name="gusset"))
        g = box((0.04, 0.34, 0.08), pos=(sx * 2.19, -0.17, 3.6), bevel=0.005, mat="metal_dark", name="strut")
        parts.append(g)
    # Rust on the drum: an underside patch + a drip, built round a Z axis and turned onto the drum's X axis.
    belly = arc_panel(dr + 0.002, 3.2, angle=110, thickness=0.004, pos=(0, 0, -1.6), rot=(0, 0, 70), segments=10,
                      mat="rust", name="drum_rust")
    move_verts(belly, lambda co: Vector((co.x, co.y, co.z * (1.0 + 0.06 * math.sin(3 * math.atan2(co.x, -co.y))))))
    drip = arc_panel(dr + 0.004, 0.16, angle=70, thickness=0.004, pos=(0, 0, -1.28), rot=(0, 0, 30), segments=6,
                     mat="rust", name="drum_drip")
    for o in (belly, drip):
        apply_transform(o)                       # keep the turn round the drum, then lay it on the X axis
        o.rotation_euler = (0, math.radians(90), 0)
        o.location = (0, dy, dz)
        parts.append(o)

    # Beam brackets: wall plate, arm, front lip, a diagonal brace; the left one 5 cm low.
    for sx in (-1, 1):
        az = ARM_Z[sx]
        x = sx * BRACKET_X
        parts.append(box((0.14, 0.022, 0.38), pos=(x, -0.011, az - 0.1), bevel=0.005, mat="metal_dark",
                         name="bracket_plate"))
        parts.append(box((0.12, 0.34, 0.04), pos=(x, -0.18, az - 0.04), bevel=0.005, mat="metal_dark",
                         name="bracket_arm"))
        parts.append(box((0.12, 0.035, 0.16), pos=(x, -0.335, az - 0.04), bevel=0.005, mat="metal_dark",
                         name="bracket_lip"))
        parts.append(box((0.05, 0.03, 0.4), pos=(x, -0.02, az - 0.33), rot=(45, 0, 0), bevel=0.005,
                         mat="metal_dark", name="bracket_brace"))
        for bz in (az - 0.06, az + 0.2):
            parts.append(cyl(0.022, 0.025, verts=6, pos=(x, -0.02, bz), rot=(90, 0, 0), bevel=0, mat="metal_dark",
                             name="bracket_bolt"))

    # Hasp on the second slat: plate + a staple sticking out for the padlock.
    hx, hz = 1.45, 0.43
    parts.append(box((0.1, 0.012, 0.16), pos=(hx, -0.078, hz - 0.1), bevel=0.003, mat="metal_dark", name="hasp"))
    parts.append(pipe([(hx, -0.08, hz - 0.03), (hx, -0.13, hz - 0.03), (hx, -0.13, hz + 0.03), (hx, -0.08, hz + 0.03)],
                      0.011, verts=6, bend=0, mat="metal_dark", name="staple"))

    # Tally marks scratched in at knee height (somebody has been counting).
    tally = []
    for gx, n, slat in ((-1.62, 5, 4), (-1.18, 5, 4), (-0.8, 3, 4)):
        z0 = Z_BOT + slat * SLAT + 0.035
        for i in range(min(n, 4)):
            tally.append(box((0.024, 0.014, 0.135), pos=(gx + i * 0.055, -0.071, z0), rot=(0, 3 * (i - 1.5), 0),
                             bevel=0, mat="white", name="tally"))
        if n == 5:
            tally.append(box((0.024, 0.014, 0.25), pos=(gx + 0.083, -0.078, z0 + 0.005), rot=(0, 62, 0), bevel=0,
                             mat="white", name="tally"))
    parts += tally
    shutter = join(parts, "Shutter")

    # --- Beam: skinny, warped, cracked, dirty ends. Rests on both bracket arms.
    lx, rx = -BRACKET_X, BRACKET_X
    zl, zr = ARM_Z[-1], ARM_Z[1]
    def warp(co):   # an old board: bowed towards the wall and sagging a little in the middle
        k = math.sin(math.pi * (co.x / 4.8 + 0.5))
        return Vector((co.x, co.y + 0.012 * k, co.z - 0.02 * k))
    beam = box((4.8, 0.07, 0.14), pos=(0, BEAM_Y, 0), bevel=0.012, mat="wood", name="beam_body")
    slice_x(beam, [-1.8, -1.2, -0.6, 0.0, 0.6, 1.2, 1.8])
    paint(beam, "brown", lambda c, n: abs(n.x) > 0.7)
    crack = extrude_profile([(-0.95, 0.045), (-0.55, 0.075), (-0.95, 0.062)], 0.006, pos=(0, BEAM_Y - 0.035, 0),
                            bevel=0, mat="dark", name="crack")
    nail = [cyl(0.012, 0.012, verts=6, pos=(sx * (BRACKET_X - 0.03), BEAM_Y - 0.035, 0.1), rot=(90, 0, 0), bevel=0,
                mat="metal_dark", name="nail") for sx in (-1, 1)]
    for o in [beam, crack] + nail:
        apply_transform(o)
        move_verts(o, warp)
    beam = join([beam, crack] + nail, "Beam")
    ang = math.atan2(zr - zl, rx - lx)
    beam.rotation_euler = (0, -ang, 0)
    zc = (zl + zr) / 2
    beam.location = (0, 0, zc)
    apply_transform(beam)
    set_origin(beam, (0, BEAM_Y, zc + 0.07))

    # --- Chain: once round the beam near the right bracket, then down to the hasp.
    def beam_z(x):
        return zl + (zr - zl) * (x - lx) / (rx - lx) - 0.02 * math.sin(math.pi * (x / 4.8 + 0.5))
    cx = 1.93
    bz = beam_z(cx)
    wrap = [(cx - 0.05, -0.305, bz - 0.02), (cx - 0.04, -0.305, bz + 0.165), (cx - 0.01, -0.185, bz + 0.165),
            (cx + 0.02, -0.185, bz - 0.02), (cx + 0.04, -0.305, bz - 0.025)]
    down = sag_points(wrap[-1], (hx + 0.012, -0.108, hz + 0.012), sag=0.05, n=6)[1:]
    chain_obj = chain(wrap + down, pitch=0.11, width=0.078, r=0.015, name="Chain")
    set_origin(chain_obj, (cx, BEAM_Y, bz + 0.07))

    # --- Padlock: brass body (hangs on the hasp staple + last link), keyhole, steel shackle.
    # The shackle's top bar runs through the staple loop; the body hangs just clear of the slats.
    hang = Vector((hx, -0.105, hz))
    body = box((0.17, 0.06, 0.19), pos=(hx, -0.125, hz - 0.28), bevel=0.019, mat="gold", name="lock_case")
    key = box((0.026, 0.01, 0.055), pos=(hx, -0.157, hz - 0.23), bevel=0, mat="dark", name="keyhole")
    keyd = cyl(0.02, 0.01, verts=12, pos=(hx, -0.153, hz - 0.165), rot=(90, 0, 0), bevel=0, mat="dark",
               name="keydot")
    lock = join([body, key, keyd], "PadlockBody", origin=tuple(hang))
    shackle = pipe([(hx - 0.045, -0.12, hz - 0.1), (hx - 0.045, -0.108, hz), (hx + 0.045, -0.108, hz),
                    (hx + 0.045, -0.12, hz - 0.1)], 0.014, verts=8, bend=0.045, mat="metal", name="PadlockShackle")
    set_origin(shackle, tuple(hang))
    export([shutter, beam, chain_obj, lock, shackle], "roller_door", kind="prop", mount="floor", budget=5200)
