class_name Lobby
extends Node3D
## The back alley where workers wait for the van (scenes/world/lobby.tscn, one instance in world.tscn at (0, 0, 80)).
## M14 lobby agent; FRIENDSLOP 8.1, CONTRACTS "Lobby + van". A waiting room, not a level: one street lamp, bins, brick
## on every side, the van with its rear doors open. Nobody leaves: the walls' colliders are 14 m tall.
##
## Layout (Lobby-local metres, floor top at y = 0, interior x -5..5, z -7.5..7.5, open to a black sky):
##   north (z-) : the Van, nose to the wall, rear doors open towards the alley; "EVERYONE IN THE VAN" on the wall
##   west  (x-) : the street lamp (the only real light), bins
##   east  (x+) : a pallet, a crate, an oil drum
##   south (z+) : $Spawns/Spawn1..4 (feet + 0.2 m, facing the van), the steel door the workers came out of
## Solid geometry is on collision layer 1, mask 0 (like the room). The bricks, the skyline and the moon are built in
## _ready from the Toon palette (MultiMeshes: a few draw calls, no nodes per brick), the same on every peer (seeded).
##
## Cosmetic rules (every peer on its own):
##   - the alley is only drawn while it is in use: phase MENU / WAITING with the lobby on (`Config.lobby_enabled`
##     here, or the host says so through the van's synced head count). With the lobby off it is never drawn.
##   - the room's mains hum (a 2D loop owned by Room) is silenced while the local worker stands in the alley.

## Interior size in metres (x = width, y = wall height, z = length), centred on the Lobby origin.
const INTERIOR_SIZE := Vector3(10.0, 6.0, 15.0)
## Sideways offset per wrap-around when more workers than spawn markers wait here (the Room's rule).
const SPAWN_WRAP_OFFSET: float = 0.75
const VAN_PATH := ^"Van"
const SPAWNS_PATH := ^"Spawns"
const BRICKS_PATH := ^"Walls/Bricks"
const SKYLINE_PATH := ^"Sky"

## A brick: length, height, how far it stands out of the mortar; the joint between two.
const BRICK := Vector3(0.56, 0.2, 0.05)
const MORTAR: float = 0.025
const BRICK_SEED: int = 1407
## Seconds between checks of "is the local worker standing in the alley" (the hum).
const AMBIENCE_POLL_SEC: float = 0.25

var _poll_accum: float = 0.0
var _hum_muted: bool = false


func _ready() -> void:
	_build_bricks()
	_build_sky()
	GameState.phase_changed.connect(_on_phase_changed)
	var van := get_van()
	if van != null:
		van.changed.connect(_refresh_visibility)
	_refresh_visibility()


func _process(delta: float) -> void:
	_poll_accum += delta
	if _poll_accum < AMBIENCE_POLL_SEC:
		return
	_poll_accum = 0.0
	var me: Player = Game.local_player
	_set_room_hum_muted(me != null and is_instance_valid(me) and me.is_inside_tree() and contains_point(me.global_position))


# --- contract ---------------------------------------------------------------------------------------------------------

## Spawn markers in order (Spawn1..Spawn4).
func get_spawn_points() -> Array[Marker3D]:
	var out: Array[Marker3D] = []
	var spawns := get_node_or_null(SPAWNS_PATH)
	if spawns == null:
		return out
	for c in spawns.get_children():
		if c is Marker3D:
			out.append(c)
	return out


## Global transform for the index-th worker in the alley (wraps around the markers; negative indices are safe).
func get_spawn_transform(index: int) -> Transform3D:
	var pts := get_spawn_points()
	if pts.is_empty():
		return _to_global(Transform3D(Basis.IDENTITY, Vector3(0.0, 0.2, 4.5)))
	var i := posmod(index, pts.size())
	var wraps := floori(float(absi(index)) / float(pts.size()))
	var t := _to_global(_local_transform_of(pts[i]))
	if wraps > 0:
		# One step back per wrap as well: the alley is narrow, the row behind is free.
		var side := 1.0 if wraps % 2 == 1 else -1.0
		t.origin += t.basis.x.normalized() * SPAWN_WRAP_OFFSET * 0.5 * side + t.basis.z.normalized() * 1.0 * float(wraps)
	return t


## The van (null if the scene lost it).
func get_van() -> Van:
	return get_node_or_null(VAN_PATH) as Van


## Interior bounds: the floor (x / z) from y = 0 up to the top of the brick. Global when in the tree.
func get_bounds() -> AABB:
	var local := AABB(Vector3(-INTERIOR_SIZE.x * 0.5, 0.0, -INTERIOR_SIZE.z * 0.5), INTERIOR_SIZE)
	if is_inside_tree():
		return global_transform * local
	return local


## True when `point` (global) is in the alley: inside the walls, at any height a worker can reach.
func contains_point(point: Vector3) -> bool:
	if not point.is_finite():
		return false
	var p := global_transform.affine_inverse() * point if is_inside_tree() else point
	return absf(p.x) <= INTERIOR_SIZE.x * 0.5 + 0.5 and absf(p.z) <= INTERIOR_SIZE.z * 0.5 + 0.5 and p.y > -2.0 and p.y < 14.0


## True while the alley is the place to be on this peer: MENU / WAITING with the lobby on.
func is_in_use() -> bool:
	var phase: int = GameState.phase
	if phase != GameState.Phase.MENU and phase != GameState.Phase.WAITING:
		return false
	var van := get_van()
	return Config.lobby_enabled or (van != null and van.is_lobby_on())


# --- cosmetics --------------------------------------------------------------------------------------------------------

func _on_phase_changed(_phase: int) -> void:
	_refresh_visibility()


func _refresh_visibility() -> void:
	var show := is_in_use()
	if visible != show:
		visible = show


## The room's mains hum is a 2D loop: it would follow the worker into the alley. Room owns it (`_set_hum`); the call
## is guarded, so a renamed helper only means the hum plays on.
func _set_room_hum_muted(muted: bool) -> void:
	if muted == _hum_muted:
		return
	_hum_muted = muted
	var world: World = Game.world
	var room: Node = world.room if world != null and is_instance_valid(world) else null
	if room == null or not is_instance_valid(room) or not room.has_method(&"_set_hum"):
		return
	var power_on := bool(room.call(&"is_power_on")) if room.has_method(&"is_power_on") else true
	room.call(&"_set_hum", not muted and power_on)


## One MultiMesh of bricks over the four walls: running bond, clipped at the corners, three tired reds from the Toon
## palette and the odd sooty one. Seeded, so every peer builds the same wall.
func _build_bricks() -> void:
	var holder := get_node_or_null(BRICKS_PATH) as MultiMeshInstance3D
	if holder == null:
		return
	var hx := INTERIOR_SIZE.x * 0.5
	var hz := INTERIOR_SIZE.z * 0.5
	# [start corner on the floor, direction along the wall, normal into the alley, length]
	var walls: Array = [
		[Vector3(-hx, 0.0, -hz), Vector3.RIGHT, Vector3.BACK, INTERIOR_SIZE.x],
		[Vector3(hx, 0.0, hz), Vector3.LEFT, Vector3.FORWARD, INTERIOR_SIZE.x],
		[Vector3(-hx, 0.0, hz), Vector3.FORWARD, Vector3.RIGHT, INTERIOR_SIZE.z],
		[Vector3(hx, 0.0, -hz), Vector3.BACK, Vector3.LEFT, INTERIOR_SIZE.z],
	]
	var base := Toon.COCOA.lerp(Toon.TOMATO, 0.4)
	var tones: Array[Color] = [Toon.darker(base, 0.3), Toon.darker(base, 0.42), Toon.darker(base.lerp(Toon.TANGERINE, 0.25), 0.36)]
	var soot := Toon.darker(Toon.INK.lerp(base, 0.35), 0.2)
	var rng := RandomNumberGenerator.new()
	rng.seed = BRICK_SEED
	var xforms: Array[Transform3D] = []
	var colors := PackedColorArray()
	var pitch := BRICK.x + MORTAR
	var rows := int(INTERIOR_SIZE.y / (BRICK.y + MORTAR))
	for wall: Array in walls:
		var start: Vector3 = wall[0]
		var along: Vector3 = wall[1]
		var normal: Vector3 = wall[2]
		var length: float = wall[3]
		for r in rows:
			var x := -pitch * 0.5 if r % 2 == 1 else 0.0
			while x < length:
				var a := maxf(x, 0.0)
				var b := minf(x + BRICK.x, length)
				x += pitch
				if b - a < 0.1:
					continue
				var centre := start + along * ((a + b) * 0.5) + Vector3.UP * (MORTAR + (BRICK.y + MORTAR) * float(r) + BRICK.y * 0.5) \
						+ normal * (BRICK.z * 0.5)
				xforms.append(Transform3D(Basis(along * ((b - a) / BRICK.x), Vector3.UP, normal), centre))
				var roll := rng.randf()
				var tone: Color = soot if roll < 0.06 else tones[rng.randi() % tones.size()]
				# Damp at the foot of the wall: the bottom courses are darker.
				colors.append(Toon.darker(tone, 0.18) if r < 3 else tone)
	var mesh := BoxMesh.new()
	mesh.size = BRICK
	var mat := Toon.make(Color.WHITE, Toon.Finish.MATTE)
	mat.vertex_color_use_as_albedo = true
	mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		mm.set_instance_color(i, colors[i])
	holder.multimesh = mm


## What is beyond the walls: three dark blocks of buildings with a few lit windows, and a low moon. All unlit shapes
## far outside the walls (no collision, no light).
func _build_sky() -> void:
	var holder := get_node_or_null(SKYLINE_PATH) as Node3D
	if holder == null:
		return
	var dark := Toon.make(Toon.darker(Toon.INK, 0.45), Toon.Finish.FLAT)
	var lit := Toon.make(Toon.darker(Toon.SUNSHINE.lerp(Toon.CREAM, 0.35), 0.25), Toon.Finish.FLAT)
	# [centre, size]: beyond the north, east and west walls.
	var blocks: Array = [
		[Vector3(-4.0, 9.0, -17.0), Vector3(15.0, 18.0, 8.0)],
		[Vector3(11.0, 6.5, -15.0), Vector3(9.0, 13.0, 7.0)],
		[Vector3(15.0, 8.0, 3.0), Vector3(8.0, 16.0, 16.0)],
		[Vector3(-15.0, 7.0, 1.0), Vector3(8.0, 14.0, 20.0)],
		[Vector3(1.0, 7.5, 18.0), Vector3(22.0, 15.0, 8.0)],
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = BRICK_SEED + 1
	var windows: Array[Transform3D] = []
	for block: Array in blocks:
		var centre: Vector3 = block[0]
		var size: Vector3 = block[1]
		var body := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = size
		mesh.material = dark
		body.mesh = mesh
		body.position = centre
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(body)
		# Windows on the face that looks at the alley (the face nearest the origin), above the wall line.
		var towards := Vector3(-signf(centre.x), 0.0, 0.0) if absf(centre.x) > absf(centre.z) else Vector3(0.0, 0.0, -signf(centre.z))
		var across := Vector3.UP.cross(towards)
		var half_w := (size.z if towards.x != 0.0 else size.x) * 0.5
		var depth := (size.x if towards.x != 0.0 else size.z) * 0.5
		var y := INTERIOR_SIZE.y + 1.5
		while y < centre.y + size.y * 0.5 - 1.0:
			var u := -half_w + 1.2
			while u < half_w - 1.0:
				if rng.randf() < 0.16:
					var at := centre + towards * (depth + 0.03) + across * u
					at.y = y
					windows.append(Transform3D(Basis(across, Vector3.UP, towards), at))
				u += 1.9
			y += 2.4
	var pane := BoxMesh.new()
	pane.size = Vector3(0.9, 1.2, 0.04)
	pane.material = lit
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = pane
	mm.instance_count = windows.size()
	for i in windows.size():
		mm.set_instance_transform(i, windows[i])
	var panes := MultiMeshInstance3D.new()
	panes.name = "Windows"
	panes.multimesh = mm
	panes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(panes)
	var moon := MeshInstance3D.new()
	moon.name = "Moon"
	var disc := SphereMesh.new()
	disc.radius = 3.2
	disc.height = 6.4
	disc.radial_segments = 24
	disc.rings = 12
	disc.material = Toon.make(Toon.CREAM, Toon.Finish.FLAT)
	moon.mesh = disc
	moon.position = Vector3(-26.0, 46.0, -52.0)
	moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(moon)


# --- helpers ----------------------------------------------------------------------------------------------------------

## Transform of a descendant relative to this node (works in and out of the tree).
func _local_transform_of(node: Node3D) -> Transform3D:
	var t := node.transform
	var p := node.get_parent()
	while p != null and p != self:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


func _to_global(local: Transform3D) -> Transform3D:
	if is_inside_tree():
		return global_transform * local
	return local
