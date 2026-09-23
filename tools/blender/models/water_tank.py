"""water_tank family: the well. A dented, faded-blue horizontal water tank on two steel posts over a rusty catch
basin, with a red valve wheel, a spigot, a sight gauge showing it is nearly empty, a vent, a manhole and a
hose coiled on the right post (kind "station", floor mount), plus the tin pail that hangs under the spigot.

  water_tank         ~2.5 x 2.8 x 1.8 m. Replaces the primitives under scenes/stations/well.tscn `Visual`
                     (instanced there as `Visual/Model`). Fits the scene's colliders: basin inside the ring
                     cylinder (r 1.0, h 0.76), posts at x +-0.98 (h 2.05), tank inside the roof box
                     (2.6 x 0.5 x 1.6 at y 2.0-2.5; its lower half hangs over the basin).
                     `%Water` (the water disc in the basin, y 0.4, r 0.83) and `%Bucket` stay Godot nodes, and so
                     do the `%CanSpots` on the floor in front.
  water_tank_bucket  0.36 x 0.39 x 0.35 m tin pail, origin at its bottom centre, handle apex 0.37 m up
                     (kind "part"): instanced under `%Bucket`, which hangs it on the spigot hook at y 1.12
                     (the well script bounces `%Bucket` on every refill).

Wear: dents on the tank front and end, rust on its belly and runs under the straps, a rust tide line on the
basin, a rusted post foot, a hose that has seen things, the gauge reading low.
"""
from gwf import *

TANK_Z = 2.0       # tank axis height
TANK_R = 0.56
TANK_L = 1.02      # half length of the straight part (domes add 0.24)
POST_X = 0.98
POST_TOP = 1.36   # saddle top = tank bottom (TANK_Z - TANK_R + 0.08 overlap for the cradle)
BASIN_R = 0.86
WATER_Z = 0.4      # %Water disc height (scene)
NOZZLE = (0.0, -0.64)       # spigot nozzle (x, y), pointing down into the basin
HOOK = (0.25, -0.55, 1.12)  # where the bucket handle hangs, beside the nozzle (scene: %Bucket at y = 1.12 - 0.37)
LABEL = (-0.45, 18.0)       # front label plate centre (world x, elevation deg); the scene's Label3Ds sit on it


def on_tank(xw, elev, r=TANK_R):
    """World point on the tank surface at world x `xw`, `elev` degrees up from the front (-Y)."""
    a = math.radians(elev)
    return Vector((xw, -r * math.cos(a), TANK_Z + r * math.sin(a)))


def to_tank_local(p):
    """World point -> tank-local (the tank is lathed along local Z, then turned +90 deg about Y)."""
    return Vector((-(p.z - TANK_Z), p.y, p.x))


def tank_body(paint_mat, rust):
    prof = [(0.0, -TANK_L - 0.24), (0.22, -TANK_L - 0.225), (0.38, -TANK_L - 0.18), (0.48, -TANK_L - 0.12),
            (0.54, -TANK_L - 0.05), (TANK_R, -TANK_L)]
    prof += [(TANK_R, z) for z in (-0.8, -0.6, -0.35, -0.1, 0.1, 0.35, 0.6, 0.8)]
    prof += [(r, -z) for r, z in reversed(prof[:6])]
    body = lathe(prof, verts=24, mat=paint_mat, name="tank", smooth=40)
    # dents (tank-local; dent() pushes towards the local Z axis = the tank axis)
    dent(body, to_tank_local(on_tank(0.3, 30)), radius=0.3, depth=0.07)
    dent(body, to_tank_local(on_tank(-0.9, -18)), radius=0.2, depth=0.04)
    dent(body, to_tank_local(Vector((TANK_L + 0.2, -0.15, TANK_Z + 0.12))), radius=0.16, depth=0.03,
         direction=(0, 0, -1))
    # rust on the belly (where the condensation drips) and runs down the front under the straps
    parts = [body,
             arc_panel(TANK_R + 0.003, 2 * TANK_L - 0.1, angle=70, thickness=0.004, pos=(0, 0, -TANK_L + 0.05),
                       rot=(0, 0, 90), segments=8, mat=rust, name="belly_rust")]
    for xw, elev, w in ((POST_X - 0.11, 22, 0.08), (-POST_X + 0.13, 16, 0.1), (0.05, -6, 0.06)):
        run = arc_panel(TANK_R + 0.003, w, angle=46, thickness=0.004, pos=(0, 0, xw - w / 2), rot=(0, 0, -elev),
                        segments=6, mat=rust, name="rust_run")
        # taper into a drip (panel-local, before its rotation: angle -23..23 deg, +X side = world down),
        # full width at the upper end, a thin tail at the lower end
        def drip(co, w=w):
            t = max(0.0, min(1.0, (math.atan2(co.x, -co.y) + math.radians(23)) / math.radians(46)))
            return Vector((co.x, co.y, w / 2 + (co.z - w / 2) * (1.0 - 0.75 * t)))
        move_verts(run, drip)
        parts.append(run)
    # straps over the posts (flat bands, darker steel)
    for xw in (-POST_X, POST_X):
        parts.append(band(TANK_R + 0.006, xw - 0.05, xw + 0.05, thickness=0.01, verts=24, mat=lib("metal_dark"),
                          name="strap"))
    tank = join(parts, "tank_mesh")
    tank.rotation_euler = (0, math.radians(90), 0)
    tank.location = (0, 0, TANK_Z)
    return tank


def build_tank():
    reset()
    steel, rust, tin, dark = lib("metal_dark"), lib("rust"), lib("metal"), lib("dark")
    paint_mat = material("tank_paint", "#4f6d8f", "soft")       # faded factory blue (the oil drums' paint)
    grime = lib("concrete_dark")
    hose_mat = lib("olive")
    wheel_mat = lib("red")
    water = lib("water")
    cream = lib("cream")

    p = []
    # --- catch basin: steel tub, grimy inside, rust tide line outside, fat rolled rim -------------------------
    basin = lathe([(0.0, 0.0), (BASIN_R - 0.03, 0.0), (BASIN_R, 0.03), (BASIN_R + 0.03, 0.5), (BASIN_R - 0.02, 0.52),
                   (BASIN_R - 0.04, 0.12), (0.0, 0.12)], verts=24, mat=steel, name="basin", smooth=40)
    paint(basin, grime, lambda c, n: (n.x * c.x + n.y * c.y) < -1e-4 or (n.z > 0.5 and c.z < 0.2))
    p.append(basin)
    p.append(torus(BASIN_R + 0.005, 0.045, pos=(0, 0, 0.53), major_segments=24, minor_segments=5, mat=steel,
                   name="basin_rim"))
    p.append(band(lambda z: BASIN_R + 0.004 + 0.06 * z, 0.03, 0.15, thickness=0.004, verts=24, rows=1, mat=rust,
                  top=lambda a: 0.035 * math.sin(3 * a + 0.8) + 0.015 * math.sin(7 * a), name="basin_rust"))

    # --- posts: steel pipes on foot plates with knee braces, a saddle on top --------------------------------------
    for sx in (-1, 1):
        x = sx * POST_X
        p.append(cyl(0.07, POST_TOP, verts=12, pos=(x, 0, 0), bevel=0, mat=steel, name="post"))
        p.append(box((0.24, 0.52, 0.045), pos=(x, 0, 0), bevel=0.015, segments=1, mat=steel, name="foot"))
        for sy in (-1, 1):
            p.append(pipe([(x, sy * 0.22, 0.04), (x, sy * 0.02, 0.5)], 0.03, verts=6, mat=steel, name="brace"))
        # saddle cradling the tank: a block under it and two cheeks hugging its sides (36 deg off the bottom)
        p.append(box((0.16, 0.5, 0.1), pos=(x, 0, POST_TOP - 0.02), bevel=0.02, segments=1, mat=steel, name="saddle"))
        for sy in (-1, 1):
            a = math.radians(36)
            c = (x, sy * (TANK_R + 0.03) * math.sin(a), TANK_Z - (TANK_R + 0.03) * math.cos(a))
            p.append(box((0.14, 0.07, 0.26), pos=c, rot=(-54 * sy, 0, 0), bevel=0.02, segments=1, mat=steel,
                         name="cheek", anchor="center"))
    # the left foot rusted through
    p.append(cyl(0.076, 0.22, verts=12, pos=(-POST_X, 0, 0.04), bevel=0, mat=rust, name="post_rust"))

    # --- tank ----------------------------------------------------------------------------------------------------
    p.append(tank_body(paint_mat, rust))
    # label plate on the front (the scene writes "WATER" / "NOT DRINKABLE" on it)
    # (modelled in tank-local space: height = along the tank = world X, rot about the axis = elevation)
    label = arc_panel(TANK_R + 0.004, 0.66, angle=36, thickness=0.006, pos=(0, 0, LABEL[0] - 0.33),
                      rot=(0, 0, -LABEL[1]), segments=6, mat=cream, name="label")
    label_t = join([label], "label_mesh")
    label_t.rotation_euler = (0, math.radians(90), 0)
    label_t.location = (0, 0, TANK_Z)
    p.append(label_t)
    # manhole on top, gooseneck vent, sight gauge on the front (water column low)
    top = on_tank(-0.45, 90)
    p.append(cyl(0.2, 0.06, verts=16, pos=(top.x, top.y, top.z - 0.02), bevel=0.015, segments=1, mat=steel,
                 name="manhole"))
    p.append(cyl(0.12, 0.03, verts=12, pos=(top.x, top.y, top.z + 0.04), bevel=0.01, segments=1, mat=steel,
                 name="manhole_lid"))
    for a in range(45, 360, 90):
        r = math.radians(a)
        p.append(cyl(0.018, 0.025, verts=6, pos=(top.x + 0.165 * math.cos(r), top.y + 0.165 * math.sin(r),
                                                  top.z + 0.03), bevel=0, mat=rust, name="manhole_bolt"))
    vt = on_tank(0.62, 90)
    p.append(pipe([(vt.x, vt.y, vt.z - 0.05), (vt.x, vt.y, vt.z + 0.24), (vt.x - 0.02, vt.y - 0.16, vt.z + 0.24),
                   (vt.x - 0.02, vt.y - 0.2, vt.z + 0.12)], 0.045, verts=10, bend=0.08, mat=steel, name="vent"))
    gx = 0.55
    g_hi, g_lo = on_tank(gx, 40), on_tank(gx, -40)
    p.append(pipe([(gx, g_hi.y + 0.05, g_hi.z), (gx, -TANK_R - 0.1, g_hi.z), (gx, -TANK_R - 0.1, g_lo.z),
                   (gx, g_lo.y + 0.05, g_lo.z)], 0.028, verts=8, bend=0.05, mat=steel, name="gauge"))
    p.append(cyl(0.036, 0.16, verts=10, pos=(gx, -TANK_R - 0.1, g_lo.z + 0.06), bevel=0, mat=water, name="gauge_water"))
    p.append(cyl(0.034, g_hi.z - g_lo.z - 0.34, verts=10, pos=(gx, -TANK_R - 0.1, g_lo.z + 0.22), bevel=0,
                 mat=lib("glass"), name="gauge_glass"))

    # --- spigot: downpipe, red valve wheel, elbow forward, nozzle with the bucket hook ------------------------------
    sp_top = on_tank(0.0, -68)
    nx, ny = NOZZLE
    run_z = 1.2          # the elbowed run forward to the nozzle
    valve_z = 1.42
    p.append(pipe([(0.0, sp_top.y, sp_top.z + 0.05), (0.0, sp_top.y, run_z), (nx, ny, run_z), (nx, ny, run_z - 0.06)],
                  0.05, verts=10, bend=0.09, mat=steel, name="spigot"))
    p.append(cyl(0.07, 0.12, verts=12, pos=(0, sp_top.y, valve_z - 0.06), bevel=0.02, segments=1, mat=steel,
                 name="valve_body"))
    wy = sp_top.y - 0.16
    p.append(cyl(0.02, 0.16, verts=6, pos=(0, sp_top.y, valve_z), rot=(90, 0, 0), bevel=0, mat=steel, name="valve_stem"))
    p.append(torus(0.11, 0.022, pos=(0, wy, valve_z), rot=(90, 0, 0), major_segments=18, minor_segments=5,
                   mat=wheel_mat, name="wheel"))
    for a in (90, 210, 330):
        r = math.radians(a)
        p.append(pipe([(0, wy, valve_z), (0.11 * math.cos(r), wy, valve_z + 0.11 * math.sin(r))], 0.014, verts=4,
                      mat=wheel_mat, name="spoke"))
    p.append(cyl(0.03, 0.03, verts=8, pos=(0, wy + 0.015, valve_z), rot=(90, 0, 0), bevel=0, mat=wheel_mat, name="hub"))
    p.append(cyl(0.058, 0.06, verts=10, pos=(nx, ny, run_z - 0.1), bevel=0.012, segments=1, mat=tin, name="nozzle"))
    # the hook the bucket hangs on: an arm off the run, bent into a J (its foot runs front-back under the handle)
    hx, hy, hz = HOOK
    p.append(pipe([(0.02, hy, run_z), (hx, hy, run_z), (hx, hy + 0.04, hz - 0.012), (hx, hy - 0.05, hz - 0.012),
                   (hx, hy - 0.05, hz + 0.03)], 0.012, verts=6, bend=0.015, mat=steel, name="hook"))

    # --- hose: out of the right end cap, sagging down to a coil hung on the right post -------------------------------
    end = Vector((TANK_L + 0.18, -0.22, TANK_Z - 0.26))
    p.append(cyl(0.05, 0.1, verts=10, pos=end, rot=(0, 90, 0), bevel=0.01, segments=1, mat=rust, name="hose_fitting"))
    coil_c = Vector((POST_X + 0.05, -0.16, 1.0))   # hung on the front of the right post, facing the room
    pts = sag_points(end + Vector((0.1, 0, 0)), coil_c + Vector((0.14, -0.02, 0.1)), sag=0.14, n=6)
    p.append(pipe(pts, 0.03, verts=6, mat=hose_mat, name="hose"))
    for i in range(2):
        p.append(torus(0.18 - 0.02 * i, 0.03, pos=(coil_c.x + 0.012 * i, coil_c.y - 0.05 * i, coil_c.z - 0.015 * i),
                       rot=(90, 6 * i - 4, 0), major_segments=16, minor_segments=5, mat=hose_mat, name="coil"))
    p.append(pipe([(POST_X, 0.0, coil_c.z + 0.17), (POST_X, coil_c.y - 0.1, coil_c.z + 0.17),
                   (POST_X, coil_c.y - 0.1, coil_c.z + 0.22)], 0.016, verts=6, bend=0.02, mat=steel, name="coil_hook"))

    tank = join(p, "Tank")
    export(tank, "water_tank", kind="station", mount="floor")
    print("  water_tank label centre (Godot): %s" % (tuple(round(v, 3) for v in (
        on_tank(LABEL[0], LABEL[1], TANK_R + 0.012).x, on_tank(LABEL[0], LABEL[1], TANK_R + 0.012).z,
        -on_tank(LABEL[0], LABEL[1], TANK_R + 0.012).y)),))


def build_bucket():
    reset()
    tin, steel, rust, water = lib("metal"), lib("metal_dark"), lib("rust"), lib("water")
    prof = [(0.0, 0.0), (0.125, 0.0), (0.13, 0.012), (0.145, 0.09), (0.152, 0.1), (0.148, 0.11), (0.162, 0.2),
            (0.17, 0.25), (0.162, 0.25), (0.152, 0.2), (0.14, 0.1), (0.118, 0.02), (0.0, 0.02)]
    pail = lathe(prof, verts=20, mat=tin, name="pail", smooth=45)
    dent(pail, (0.1, -0.1, 0.16), radius=0.08, depth=0.018)
    rim = torus(0.168, 0.013, pos=(0, 0, 0.25), major_segments=20, minor_segments=5, mat=tin, name="rim")
    rust_ring = band(lambda z: 0.13 + 0.15 * z + 0.003, 0.004, 0.05, thickness=0.003, verts=20, mat=rust,
                     top=lambda a: 0.018 * math.sin(3 * a + 1.0), name="pail_rust")
    water_disc = cyl(0.148, 0.01, verts=16, pos=(0, 0, 0.17), bevel=0, mat=water, name="bucket_water")
    lugs = [cyl(0.02, 0.02, verts=6, pos=(sx * 0.168, 0, 0.225), rot=(0, sx * 90, 0), bevel=0, mat=steel, name="lug")
            for sx in (-1, 1)]
    # wire handle: an arc over the top (a little crooked), apex 0.37 m up = the hook point
    arc = [(-0.172 * math.cos(math.radians(a)), 0.012 * math.sin(math.radians(a * 2)),
            0.225 + 0.145 * math.sin(math.radians(a))) for a in range(0, 181, 20)]
    handle = pipe(arc, 0.008, verts=6, bend=0.0, mat=steel, name="handle")
    bucket = join([pail, rim, rust_ring, water_disc, handle] + lugs, "Pail")
    export(bucket, "water_tank_bucket", kind="part", mount="floor", budget=1500)


def build():
    build_tank()
    build_bucket()
