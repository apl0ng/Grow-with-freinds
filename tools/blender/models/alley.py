"""alley: what there is to do in the alley between shifts (M15 alley agent). Two models.

ball        a scuffed, half-flat rubber ball, 0.24 m across (held item, kind "item": front on Godot -Z, floor
            mount, origin at the centre of the flat it rests on). One mesh. Faded orange rubber, two dark seams,
            a cream patch stuck over a puncture, a caved-in shoulder. Instanced as `Visual` in
            scenes/items/ball.tscn (the collider there is a sphere r 0.12 at y 0.11).
alley_hoop  a ring off a barrel bolted to a scrap of board (wall mount: the back of the board is on the wall,
            the ring stands out towards the front; origin = the centre of the board on the wall). The ring's
            centre is 0.47 m out of the wall at the origin's height, 0.34 m in radius, bent: it droops towards
            the front and is a little oval. Three tired ends of a net still hang off it. Instanced as
            `Hoop/Model` in scenes/world/lobby.tscn; scripts/world/alley_hoop.gd counts a ball that falls through
            the ring (its RING_OUT / RING_RADIUS mirror RING_OUT / RING_R here).
"""
from gwf import *

# --- ball ---------------------------------------------------------------------------------------------------------
BALL_R = 0.12
FLAT_Z = -0.05      # sphere space: everything below sags onto the floor
SEG = 24
RINGS = 12

# --- hoop ---------------------------------------------------------------------------------------------------------
RING_R = 0.34       # ring radius (centre of the tube)
RING_TUBE = 0.026
RING_OUT = 0.47     # ring centre, metres out of the wall
BOARD = (0.95, 0.7)  # width, height of the backing board
BOARD_T = 0.03


def build_ball():
    reset()
    rubber = lib("orange")
    seam = lib("dark")
    patch = lib("cream")
    ball = sphere(BALL_R, rot=(28, 17, 40), segments=SEG, rings=RINGS, mat=rubber, name="ball")
    # Seams (painted on the round ball, before it is turned and sags): one meridian circle and the ring of faces
    # above the equator. A face is 3 cm wide at the equator: chunky enough to read across the alley.
    step = math.tau / SEG

    def on_seam(c, n):
        col = int((math.atan2(c.y, c.x) % math.tau) / step)
        if col == 0 or col == SEG // 2:
            return True
        return 0.0 < c.z < BALL_R * math.sin(math.pi / RINGS) * 1.02
    paint(ball, seam, on_seam)
    # A patch over a puncture on one shoulder (about 6 cm across).
    spot = Vector((0.55, -0.62, 0.56)).normalized()
    paint(ball, patch, lambda c, n: n.dot(spot) > 0.94)
    # Turn it so no seam is square to anything, then let the air out: the bottom lies flat, the sides bulge over
    # it, one shoulder has caved in.
    apply_transform(ball)

    def sag(co):
        t = max(0.0, min(1.0, (0.03 - co.z) / 0.15))        # 0 above the belly, 1 at the bottom
        k = 1.0 + 0.13 * t * t * (3 - 2 * t)
        z = co.z if co.z >= FLAT_Z else FLAT_Z - (FLAT_Z - co.z) * 0.1
        return Vector((co.x * k, co.y * k, z * 0.94))
    move_verts(ball, sag)
    dent(ball, (0.03, -0.085, 0.07), radius=0.075, depth=0.024, direction=(-0.2, 0.75, -0.6))
    dent(ball, (-0.09, 0.03, 0.03), radius=0.05, depth=0.01, direction=(1.0, -0.3, 0.0))
    low = min(v.co.z for v in ball.data.vertices)
    move_verts(ball, lambda co: Vector((co.x, co.y, co.z - low)))
    export(join([ball], "Ball"), "ball", kind="item", mount="floor")


def ring_z(x, y_local):
    """Height of the bent ring at a point of its circle (ring space: +y is the wall side, -y the front)."""
    out = max(0.0, min(1.0, (RING_R - y_local) / (2 * RING_R)))
    return -0.07 * out * out - 0.012 * math.sin(3.0 * math.atan2(y_local, x))


def build_hoop():
    reset()
    wood = lib("wood")
    rust = lib("rust")
    metal = lib("metal_dark")
    rope = lib("cream")
    bw, bh = BOARD
    front = -BOARD_T                                      # the board's face
    # The board: a scrap of ply hung 3 degrees off level, its edges chewed.
    board = subdivide(box((bw, BOARD_T, bh), pos=(0, -BOARD_T / 2, -bh / 2), rot=(0, 3, 0), bevel=0.008, mat=wood,
                          name="board"), 5)
    jitter(board, 0.004, seed=3)
    # Somebody painted a square on it once: four cream strokes, as crooked as the board; half of one has worn off.
    sw, sh, line = 0.5, 0.36, 0.045
    strokes = []
    for x, z, length, upright in ((0.0, 0.1 + sh / 2, sw, False), (-0.1, 0.1 - sh / 2, sw - 0.2, False),
                                  (-sw / 2, 0.1, sh, True), (sw / 2, 0.1, sh, True)):
        size = (line, 0.004, length) if upright else (length + line, 0.004, line)
        strokes.append(box(size, pos=(x, front - 0.001, z - size[2] / 2), rot=(0, 3, 0), bevel=0, mat=rope,
                           name="stroke"))
    # A steel flat bolted across it (what actually holds the bracket), and the bolts.
    rail = box((0.5, 0.022, 0.12), pos=(0.0, front - 0.011, -0.11), rot=(0, -2, 0), bevel=0.006, mat=metal,
               name="rail")
    bolts = [cyl(0.018, 0.012, verts=6, pos=(x, y, z), rot=(90, 0, 0), bevel=0.003, mat=rust, name="bolt")
             for x, y, z in ((-0.2, front - 0.022, -0.05), (0.2, front - 0.022, -0.05), (-0.37, front, 0.25),
                             (0.38, front, -0.26))]
    # The bracket: two rods from the rail out to the ring's near edge, and a strut from below.
    rods = []
    for sx in (-1.0, 1.0):
        x = sx * 0.1
        y_local = math.sqrt(RING_R * RING_R - x * x) * 0.97
        rods.append(pipe([(x, front - 0.02, -0.05), (x, -RING_OUT + y_local, ring_z(x, y_local) - 0.005)], 0.012,
                         verts=8, mat=metal, name="rod"))
    strut = pipe([(0.0, front - 0.01, -0.28), (0.0, -RING_OUT + RING_R * 0.97 - 0.03, ring_z(0.0, RING_R) - 0.02)],
                 0.011, verts=8, mat=metal, name="strut")
    # The ring: a hoop off a barrel, rusted and bent: it droops towards the front and is no longer round.
    ring = torus(RING_R, RING_TUBE, major_segments=32, minor_segments=8, mat=rust, name="ring",
                 scale=(1.04, 0.97, 1.0))
    move_verts(ring, lambda co: Vector((co.x, co.y, co.z + ring_z(co.x, co.y))))
    ring.location = Vector((0.0, -RING_OUT, 0.0))
    apply_transform(ring)
    # What is left of a net: three short ends of cord.
    cords = []
    for deg, length in ((205.0, 0.22), (300.0, 0.3), (352.0, 0.16)):
        a = math.radians(deg)
        lx, ly = RING_R * 1.04 * math.cos(a), RING_R * 0.97 * math.sin(a)
        x, y, z = lx, -RING_OUT + ly, ring_z(lx, ly) - 0.012
        cords.append(pipe([(x, y, z), (x * 0.96, y + 0.012, z - length * 0.6), (x * 0.9, y + 0.03, z - length)],
                          0.009, verts=6, bend=0.03, mat=rope, name="cord"))
    hoop = join([board, rail, strut, ring] + strokes + bolts + rods + cords, "Hoop")
    export(hoop, "alley_hoop", kind="prop", mount="wall")


def build():
    build_ball()
    build_hoop()
