extends SceneTree
## World/level test (owner: world/level agent). Headless, exits 0 on success, 1 on failure:
##   godot --headless --path . -s res://tools/tests/world_test.gd [-- --room=res://path/to/variant.tscn]
##
## Room: contract nodes (Spawn1..4, the 9 stations as instances of the station scenes) and helpers;
## physics (floor under every spawn, closed shell: walls/ceiling/floor on layer 1); layout rules (inside bounds,
## >= 1.2 m from walls, >= 1.8 m between stations, fronts face the centre, spawns spaced/clear/facing the shop);
## reserved station footprints free of props (colliders AND visuals); every station reachable on foot from the
## spawn (grid flood fill with a player-sized cylinder); lighting setup.
## Shopkeeper NPC: pure visual, feet at the origin, faces -Z, ~1.9 m tall, null-safe head tracking + wave.

const ROOM_SCENE := "res://scenes/world/room.tscn"
const NPC_SCENE := "res://scenes/world/shopkeeper_npc.tscn"
const STATION_SCENES := {
	"ShopCounter": "res://scenes/stations/shop_counter.tscn",
	"Well": "res://scenes/stations/well.tscn",
	"TurnInStation": "res://scenes/stations/turn_in_station.tscn",
	"GrowPlot1": "res://scenes/stations/grow_plot.tscn",
	"GrowPlot2": "res://scenes/stations/grow_plot.tscn",
	"GrowPlot3": "res://scenes/stations/grow_plot.tscn",
	"GrowPlot4": "res://scenes/stations/grow_plot.tscn",
	"GrowPlot5": "res://scenes/stations/grow_plot.tscn",
	"GrowPlot6": "res://scenes/stations/grow_plot.tscn",
}
## Reserved floor footprint per station kind (x = local width, y = local depth along the front axis).
const FOOTPRINTS := {
	"ShopCounter": Vector2(3.4, 1.2),
	"Well": Vector2(2.0, 2.0),
	"TurnInStation": Vector2(1.6, 1.6),
	"GrowPlot": Vector2(1.4, 1.4),
}
const EXPECTED_INTERIOR := Vector3(16.0, 4.0, 12.0)
const MIN_WALL_CLEARANCE := 1.2
const MIN_STATION_SPACING := 1.8
const MIN_SPAWN_SPACING := 1.5
const MIN_SPAWN_TO_STATION := 1.0
const PLAYER_RADIUS := 0.4
const GRID_STEP := 0.2
## A station counts as reachable when a walkable cell lies in front of it, at most this far from its footprint.
const FRONT_REACH := 1.2
## Depth of the strip in front of each station's footprint that must stay free of colliders.
const APPROACH_DEPTH := 0.9
## Visual props may not overlap a reserved footprint between these heights (floor decals and ceiling fixtures
## such as the grow lights over the plots are allowed).
const FOOTPRINT_VISUAL_MIN_Y := 0.06
const FOOTPRINT_VISUAL_MAX_Y := 2.5

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	print("== world_test")
	var room_path := ROOM_SCENE
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--room="):
			room_path = arg.trim_prefix("--room=")  # test a variant of the room (e.g. while iterating on the layout)
	var packed := load(room_path) as PackedScene
	if not _check(packed != null and packed.can_instantiate(), "room.tscn loads"):
		_finish()
		return
	var room := packed.instantiate() as Room
	if not _check(room != null, "room.tscn root is a Room (class_name Room)"):
		_finish()
		return
	_test_contract_offtree(room)
	root.add_child(room)
	await physics_frame
	await physics_frame
	await physics_frame
	var space := room.get_world_3d().direct_space_state
	_test_contract_intree(room)
	_test_shell(room, space)
	_test_layout(room)
	_test_footprints(room, space)
	_test_walkability(room, space)
	_test_lighting(room)
	_test_node_budget(room)
	room.queue_free()
	await process_frame
	await _test_npc()
	_finish()


# --- room contract ----------------------------------------------------------------------------------

func _test_contract_offtree(room: Room) -> void:
	var pts := room.get_spawn_points()
	_check(pts.size() == 4, "get_spawn_points() returns 4 markers (got %d)" % pts.size())
	for i in 4:
		var m := room.get_node_or_null("Spawns/Spawn%d" % (i + 1))
		_check(m is Marker3D, "$Spawns/Spawn%d exists and is a Marker3D" % (i + 1))
		if i < pts.size():
			_check(pts[i] == m, "get_spawn_points()[%d] is Spawn%d" % [i, i + 1])
	_check(room.get_bounds().is_equal_approx(AABB(-EXPECTED_INTERIOR * Vector3(0.5, 0.0, 0.5), EXPECTED_INTERIOR)),
			"get_bounds() off-tree == interior %s (got %s)" % [EXPECTED_INTERIOR, room.get_bounds()])


func _test_contract_intree(room: Room) -> void:
	var stations_root := room.get_node_or_null("Stations")
	_check(stations_root != null, "$Stations exists")
	var names: Array = STATION_SCENES.keys()
	for n: String in names:
		var s := room.get_node_or_null(NodePath("Stations/" + n)) as Node3D
		if not _check(s != null, "$Stations/%s exists (Node3D)" % n):
			continue
		_check(s.scene_file_path == STATION_SCENES[n], "%s is an instance of %s (got '%s')" % [n, STATION_SCENES[n], s.scene_file_path])
		_check(room.get_station(n) == s, "get_station(\"%s\") returns it" % n)
	_check(room.get_station("NoSuchStation") == null and room.get_station("") == null, "get_station() is null-safe for unknown names")
	_check(room.get_stations().size() == names.size(), "get_stations() returns all %d stations" % names.size())
	var pts := room.get_spawn_points()
	for i in pts.size():
		_check(room.get_spawn_transform(i).is_equal_approx(pts[i].global_transform),
				"get_spawn_transform(%d) == Spawn%d.global_transform" % [i, i + 1])
	if pts.size() == 4:
		var wrapped := room.get_spawn_transform(4)
		var base := pts[0].global_transform
		_check(wrapped.basis.is_equal_approx(base.basis) and wrapped.origin.distance_to(base.origin) > 0.5,
				"get_spawn_transform(4) wraps to Spawn1's facing with a side offset (no stacking)")
		_check(room.get_spawn_transform(-1).is_equal_approx(pts[3].global_transform), "get_spawn_transform(-1) is safe (wraps to Spawn4)")
	var b := room.get_bounds()
	_check(b.is_equal_approx(AABB(-EXPECTED_INTERIOR * Vector3(0.5, 0.0, 0.5), EXPECTED_INTERIOR)),
			"get_bounds() == %s (got %s)" % [AABB(-EXPECTED_INTERIOR * Vector3(0.5, 0.0, 0.5), EXPECTED_INTERIOR), b])
	var ap := room.get_station_access_point("Well")
	_check(ap != Vector3.INF and b.grow(0.001).has_point(ap) and absf(ap.y) < 0.001, "get_station_access_point(\"Well\") is on the floor inside the room (%s)" % ap)
	_check(room.get_station_access_point("Nope") == Vector3.INF, "get_station_access_point() is null-safe")


# --- shell / physics --------------------------------------------------------------------------------

func _test_shell(room: Room, space: PhysicsDirectSpaceState3D) -> void:
	for body_name in ["Floor", "Walls", "Ceiling"]:
		var body := room.get_node_or_null(body_name) as StaticBody3D
		if not _check(body != null, "$%s is a StaticBody3D" % body_name):
			continue
		_check(body.collision_layer == Const.LAYER_WORLD and body.collision_mask == 0,
				"%s collision layer 1 / mask 0 (got %d / %d)" % [body_name, body.collision_layer, body.collision_mask])
		var shapes := 0
		for c in body.get_children():
			if c is CollisionShape3D and (c as CollisionShape3D).shape != null and not (c as CollisionShape3D).disabled:
				shapes += 1
		var need := 4 if body_name == "Walls" else 1
		_check(shapes >= need, "%s has >= %d collision shapes (got %d)" % [body_name, need, shapes])
		for gi in body.find_children("*", "GeometryInstance3D", true, false):
			if (gi as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				_check(false, "%s mesh %s must not cast shadows (it would block the sun)" % [body_name, body.get_path_to(gi)])
	var floor_body := room.get_node_or_null("Floor")
	var walls := room.get_node_or_null("Walls")
	var ceiling := room.get_node_or_null("Ceiling")
	# Downward ray from each spawn hits the floor at y = 0.
	for m in room.get_spawn_points():
		var p := m.global_position
		var hit := _ray(space, p + Vector3.UP * 0.5, p + Vector3.DOWN * 3.0, Const.LAYER_WORLD, [])
		_check(not hit.is_empty() and hit["collider"] == floor_body and absf((hit["position"] as Vector3).y) < 0.01,
				"ray down from %s hits the Floor at y=0 (%s)" % [m.name, _hit_str(hit)])
		_check(p.y > 0.0 and p.y < 1.0, "%s is just above the floor (y=%.2f)" % [m.name, p.y])
		var up := _ray(space, p + Vector3.UP * 0.5, p + Vector3.UP * 10.0, Const.LAYER_WORLD, _non_shell_rids(room))
		_check(not up.is_empty() and up["collider"] == ceiling and absf((up["position"] as Vector3).y - EXPECTED_INTERIOR.y) < 0.01,
				"ray up from %s hits the Ceiling at y=%.1f (%s)" % [m.name, EXPECTED_INTERIOR.y, _hit_str(up)])
	# Closed shell: horizontal rays from the centre at several heights all hit the walls, never escape.
	var escaped := 0
	var total := 0
	var exclude := _non_shell_rids(room)
	for h: float in [0.3, 1.0, 2.0, 3.5]:
		for i in 32:
			var a := TAU * float(i) / 32.0
			var dir := Vector3(cos(a), 0.0, sin(a))
			var from := Vector3(0.0, h, 0.0)
			var hit := _ray(space, from, from + dir * 40.0, Const.LAYER_WORLD, exclude)
			total += 1
			if hit.is_empty() or hit["collider"] != walls:
				escaped += 1
	_check(escaped == 0, "closed shell: %d/%d horizontal rays from the centre hit the Walls" % [total - escaped, total])
	# Diagonal rays up/down also stay inside.
	var diag_escaped := 0
	for i in 16:
		var a := TAU * float(i) / 16.0
		for vy: float in [-0.6, 0.6]:
			var dir := Vector3(cos(a), vy, sin(a)).normalized()
			var hit := _ray(space, Vector3(0, 2, 0), Vector3(0, 2, 0) + dir * 40.0, Const.LAYER_WORLD, exclude)
			if hit.is_empty() or not (hit["collider"] in [walls, floor_body, ceiling]):
				diag_escaped += 1
	_check(diag_escaped == 0, "closed shell: all diagonal rays hit floor/walls/ceiling (%d escaped)" % diag_escaped)


# --- layout -----------------------------------------------------------------------------------------

func _test_layout(room: Room) -> void:
	var b := room.get_bounds()
	var centre := b.get_center()
	var stations := room.get_stations()
	for s in stations:
		var p := s.global_position
		_check(absf(p.y - b.position.y) < 0.001, "%s origin is at floor level (y=%.3f)" % [s.name, p.y])
		_check(s.global_basis.y.normalized().dot(Vector3.UP) > 0.999, "%s is upright" % s.name)
		var clear := minf(minf(p.x - b.position.x, b.end.x - p.x), minf(p.z - b.position.z, b.end.z - p.z))
		_check(clear >= MIN_WALL_CLEARANCE, "%s is inside the room, %.2f m from the nearest wall (>= %.1f)" % [s.name, clear, MIN_WALL_CLEARANCE])
		var front := _flat(s.global_basis.z)
		var to_centre := _flat(centre - p)
		_check(front.dot(to_centre) > 0.5, "%s front (+Z) faces the room centre (dot %.2f)" % [s.name, front.dot(to_centre)])
	var min_pair := INF
	var min_pair_name := ""
	for i in stations.size():
		for j in range(i + 1, stations.size()):
			var d := _flat_dist(stations[i].global_position, stations[j].global_position)
			if d < min_pair:
				min_pair = d
				min_pair_name = "%s-%s" % [stations[i].name, stations[j].name]
	_check(min_pair >= MIN_STATION_SPACING, "stations >= %.1f m apart (closest %s: %.2f m)" % [MIN_STATION_SPACING, min_pair_name, min_pair])
	# Spawns.
	var pts := room.get_spawn_points()
	var shop := room.get_station("ShopCounter")
	for i in pts.size():
		var p := pts[i].global_position
		for j in range(i + 1, pts.size()):
			var d := _flat_dist(p, pts[j].global_position)
			_check(d >= MIN_SPAWN_SPACING, "%s-%s are %.2f m apart (>= %.1f)" % [pts[i].name, pts[j].name, d, MIN_SPAWN_SPACING])
		var nearest := INF
		for s in stations:
			nearest = minf(nearest, _flat_dist(p, s.global_position))
		_check(nearest >= MIN_SPAWN_TO_STATION, "%s is %.2f m from the nearest station (>= %.1f)" % [pts[i].name, nearest, MIN_SPAWN_TO_STATION])
		_check(b.grow(-1.0).has_point(Vector3(p.x, 1.0, p.z)), "%s is well inside the room" % pts[i].name)
		if shop != null:
			var facing := _flat(-pts[i].global_basis.z)
			var to_shop := _flat(shop.global_position - p)
			_check(facing.dot(to_shop) > 0.95, "%s faces the shop (dot %.3f)" % [pts[i].name, facing.dot(to_shop)])
		_check(pts[i].global_basis.y.normalized().dot(Vector3.UP) > 0.999, "%s is upright (yaw only)" % pts[i].name)


# --- footprints -------------------------------------------------------------------------------------

func _footprint_of(station: Node3D) -> Vector2:
	var key := "GrowPlot" if String(station.name).begins_with("GrowPlot") else String(station.name)
	return FOOTPRINTS.get(key, Vector2.ONE)


func _test_footprints(room: Room, space: PhysicsDirectSpaceState3D) -> void:
	var stations := room.get_stations()
	var stations_root := room.get_node("Stations")
	# (a) Colliders: nothing but the station itself inside its reserved footprint (above the floor).
	for s in stations:
		var fp := _footprint_of(s)
		var box := BoxShape3D.new()
		box.size = Vector3(fp.x - 0.02, FOOTPRINT_VISUAL_MAX_Y - 0.1, fp.y - 0.02)
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = box
		q.collision_mask = Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM
		q.transform = Transform3D(s.global_basis.orthonormalized(), s.global_position + Vector3.UP * (0.1 + box.size.y * 0.5))
		q.exclude = _rids_under(s)
		var hits := space.intersect_shape(q, 8)
		var names: PackedStringArray = []
		for h in hits:
			names.append(str(room.get_path_to(h["collider"] as Node)))
		_check(hits.is_empty(), "%s reserved footprint %.1fx%.1f has no foreign colliders %s" % [s.name, fp.x, fp.y, names])
		# The approach strip right in front of the station must be clear too (no crate parked at the counter).
		var strip := BoxShape3D.new()
		strip.size = Vector3(fp.x - 0.02, box.size.y, APPROACH_DEPTH)
		q.shape = strip
		q.transform = Transform3D(s.global_basis.orthonormalized(),
				s.global_transform * Vector3(0.0, 0.1 + strip.size.y * 0.5, fp.y * 0.5 + APPROACH_DEPTH * 0.5 + 0.01))
		var blockers: PackedStringArray = []
		for h in space.intersect_shape(q, 8):
			blockers.append(str(room.get_path_to(h["collider"] as Node)))
		_check(blockers.is_empty(), "%s approach strip (%.1f m in front) is clear %s" % [s.name, APPROACH_DEPTH, blockers])
	# (b) Visuals: no room decor mesh pokes into a reserved footprint.
	var bad: PackedStringArray = []
	for gi in room.find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		if stations_root.is_ancestor_of(g) or not g.is_visible_in_tree():
			continue
		var a: AABB = g.global_transform * g.get_aabb()
		if a.end.y <= FOOTPRINT_VISUAL_MIN_Y or a.position.y >= FOOTPRINT_VISUAL_MAX_Y:
			continue
		for s in stations:
			if _footprint_aabb(s).intersects(a):
				bad.append("%s in %s" % [room.get_path_to(g), s.name])
	_check(bad.is_empty(), "no decor mesh overlaps a reserved station footprint %s" % [bad])
	# (c) Decor never overlaps a station's actual collision (e.g. the well roof vs a lamp).
	var clash: PackedStringArray = []
	for gi in room.find_children("*", "GeometryInstance3D", true, false):
		var g := gi as GeometryInstance3D
		if stations_root.is_ancestor_of(g) or not g.is_visible_in_tree():
			continue
		var a: AABB = (g.global_transform * g.get_aabb()).grow(-0.005)
		if a.end.y <= FOOTPRINT_VISUAL_MIN_Y:
			continue
		for s in stations:
			for cs in s.find_children("*", "CollisionShape3D", true, false):
				var c := cs as CollisionShape3D
				if c.shape == null or c.disabled:
					continue
				if (c.global_transform * c.shape.get_debug_mesh().get_aabb()).intersects(a):
					clash.append("%s vs %s" % [room.get_path_to(g), room.get_path_to(c)])
	_check(clash.is_empty(), "no decor mesh intersects a station's collision %s" % [clash])


func _footprint_aabb(s: Node3D) -> AABB:
	var fp := _footprint_of(s)
	var t := s.global_transform
	var out := AABB()
	var first := true
	for sx: float in [-0.5, 0.5]:
		for sz: float in [-0.5, 0.5]:
			for y: float in [FOOTPRINT_VISUAL_MIN_Y, FOOTPRINT_VISUAL_MAX_Y]:
				var p := t * Vector3(sx * fp.x, 0.0, sz * fp.y)
				p.y = y
				if first:
					out = AABB(p, Vector3.ZERO)
					first = false
				else:
					out = out.expand(p)
	return out.grow(-0.01)


# --- walkability ------------------------------------------------------------------------------------

func _test_walkability(room: Room, space: PhysicsDirectSpaceState3D) -> void:
	var b := room.get_bounds()
	var x0 := b.position.x + PLAYER_RADIUS
	var z0 := b.position.z + PLAYER_RADIUS
	var nx := int(floor((b.size.x - 2.0 * PLAYER_RADIUS) / GRID_STEP)) + 1
	var nz := int(floor((b.size.z - 2.0 * PLAYER_RADIUS) / GRID_STEP)) + 1
	var cyl := CylinderShape3D.new()
	cyl.radius = PLAYER_RADIUS
	cyl.height = 1.5
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cyl
	q.collision_mask = Const.LAYER_WORLD
	var free := PackedByteArray()
	free.resize(nx * nz)
	for iz in nz:
		for ix in nx:
			q.transform = Transform3D(Basis.IDENTITY, Vector3(x0 + ix * GRID_STEP, b.position.y + 1.0, z0 + iz * GRID_STEP))
			free[iz * nx + ix] = 1 if space.intersect_shape(q, 1).is_empty() else 0
	# Flood fill (8-neighbour, no corner cutting) from Spawn1.
	var pts := room.get_spawn_points()
	if pts.is_empty():
		_check(false, "walkability: no spawn points")
		return
	var start := _cell_of(pts[0].global_position, x0, z0, nx, nz)
	var reach := PackedByteArray()
	reach.resize(nx * nz)
	if not _check(free[start] == 1, "walkability: Spawn1 is not inside any collider"):
		return
	var queue: Array[int] = [start]
	reach[start] = 1
	var head := 0
	while head < queue.size():
		var c: int = queue[head]
		head += 1
		var cx := c % nx
		var cz := floori(float(c) / float(nx))
		for dz in [-1, 0, 1]:
			for dx in [-1, 0, 1]:
				if dx == 0 and dz == 0:
					continue
				var tx: int = cx + dx
				var tz: int = cz + dz
				if tx < 0 or tz < 0 or tx >= nx or tz >= nz:
					continue
				var t := tz * nx + tx
				if free[t] == 0 or reach[t] == 1:
					continue
				if dx != 0 and dz != 0 and (free[cz * nx + tx] == 0 or free[tz * nx + cx] == 0):
					continue
				reach[t] = 1
				queue.append(t)
	var reachable_cells := 0
	for v in reach:
		reachable_cells += v
	print("   info: walk grid %dx%d @ %.1f m, %d reachable cells (%.0f m2)" % [nx, nz, GRID_STEP, reachable_cells, reachable_cells * GRID_STEP * GRID_STEP])
	var all_ok := true
	for m in pts:
		var c := _cell_of(m.global_position, x0, z0, nx, nz)
		all_ok = _check(reach[c] == 1, "walkability: %s is reachable from Spawn1" % m.name) and all_ok
	for s in room.get_stations():
		var fp := _footprint_of(s)
		var inv := s.global_transform.affine_inverse()
		var found := false
		for iz in nz:
			if found:
				break
			for ix in nx:
				if reach[iz * nx + ix] == 0:
					continue
				var local := inv * Vector3(x0 + ix * GRID_STEP, s.global_position.y, z0 + iz * GRID_STEP)
				if local.z > fp.y * 0.5 and local.z - fp.y * 0.5 <= FRONT_REACH and absf(local.x) <= fp.x * 0.5:
					found = true
					break
		all_ok = _check(found, "walkability: %s front is reachable on foot (within %.1f m of its footprint)" % [s.name, FRONT_REACH]) and all_ok
	if not all_ok:
		_print_grid(free, reach, nx, nz)


func _cell_of(p: Vector3, x0: float, z0: float, nx: int, nz: int) -> int:
	var ix := clampi(roundi((p.x - x0) / GRID_STEP), 0, nx - 1)
	var iz := clampi(roundi((p.z - z0) / GRID_STEP), 0, nz - 1)
	return iz * nx + ix


func _print_grid(free: PackedByteArray, reach: PackedByteArray, nx: int, nz: int) -> void:
	print("   walk grid (# blocked, . reachable, o free but unreachable), north at the top:")
	for iz in range(0, nz, 2):
		var row := "   "
		for ix in range(0, nx, 2):
			var i := iz * nx + ix
			row += "#" if free[i] == 0 else ("." if reach[i] == 1 else "o")
		print(row)


# --- lighting / budget ------------------------------------------------------------------------------

func _test_lighting(room: Room) -> void:
	var stations_root := room.get_node("Stations")
	var env := room.get_node_or_null("WorldEnvironment") as WorldEnvironment
	_check(env != null and env.environment != null, "WorldEnvironment with an Environment")
	var dirs := 0
	var dir_shadow := 0
	var omnis := 0
	var omni_shadow := 0
	for l in room.find_children("*", "Light3D", true, false):
		if stations_root.is_ancestor_of(l):
			continue
		if l is DirectionalLight3D:
			dirs += 1
			dir_shadow += 1 if (l as Light3D).shadow_enabled else 0
		elif l is OmniLight3D:
			omnis += 1
			omni_shadow += 1 if (l as Light3D).shadow_enabled else 0
	_check(dirs == 1 and dir_shadow == 1, "one DirectionalLight3D with shadows (got %d, %d with shadows)" % [dirs, dir_shadow])
	_check(omnis >= 2 and omnis <= 4 and omni_shadow == 0, "2-4 OmniLight3D without shadows (got %d, %d with shadows)" % [omnis, omni_shadow])


func _test_node_budget(room: Room) -> void:
	var stations_root := room.get_node("Stations")
	var count := 1
	var meshes := 0
	for n in room.find_children("*", "", true, false):
		if stations_root.is_ancestor_of(n):
			continue
		count += 1
		if n is MeshInstance3D:
			meshes += 1
	print("   info: room nodes (excluding station internals) = %d, of which MeshInstance3D = %d" % [count, meshes])
	_check(count <= 180, "room node count stays reasonable (%d <= 180)" % count)


# --- shopkeeper NPC ---------------------------------------------------------------------------------

func _test_npc() -> void:
	var packed := load(NPC_SCENE) as PackedScene
	if not _check(packed != null and packed.can_instantiate(), "shopkeeper_npc.tscn loads"):
		return
	var npc := packed.instantiate() as Node3D
	_check(npc is ShopkeeperNPC, "shopkeeper root has the ShopkeeperNPC script")
	_check(npc.find_children("*", "CollisionObject3D", true, false).is_empty(), "shopkeeper is pure visual (no collision objects)")
	root.add_child(npc)
	await process_frame
	# Size / orientation.
	var box := AABB()
	var first := true
	for vi in npc.find_children("*", "VisualInstance3D", true, false):
		var a: AABB = (vi as VisualInstance3D).global_transform * (vi as VisualInstance3D).get_aabb()
		box = a if first else box.merge(a)
		first = false
	_check(absf(box.position.y) < 0.06, "shopkeeper feet at the origin (min y %.3f)" % box.position.y)
	_check(box.end.y > 1.75 and box.end.y < 2.15, "shopkeeper is ~1.9 m tall (top %.2f m)" % box.end.y)
	var eye_l := npc.get_node_or_null("Visual/Torso/HeadPivot/EyeLeft") as Node3D
	var eye_r := npc.get_node_or_null("Visual/Torso/HeadPivot/EyeRight") as Node3D
	_check(eye_l != null and eye_r != null and eye_l.global_position.z < -0.2 and eye_r.global_position.z < -0.2,
			"shopkeeper faces -Z (eyes on the -Z side)")
	var head := npc.get_node_or_null("Visual/Torso/HeadPivot") as Node3D
	var arm := npc.get_node_or_null("Visual/Torso/ArmRight") as Node3D
	var visual := npc.get_node_or_null("Visual") as Node3D
	if not _check(head != null and arm != null and visual != null, "shopkeeper rig nodes exist (Visual, HeadPivot, ArmRight)"):
		npc.queue_free()
		return
	# Null-safe idle with no players in the tree.
	var min_sy := 10.0
	var max_sy := 0.0
	for i in 12:
		await create_timer(0.1).timeout
		min_sy = minf(min_sy, visual.scale.y)
		max_sy = maxf(max_sy, visual.scale.y)
	_check(max_sy - min_sy > 0.02, "idle squash-and-stretch animates (scale.y %.3f..%.3f)" % [min_sy, max_sy])
	_check(absf(head.rotation.y) < deg_to_rad(20.0), "no players: head only glances around (yaw %.1f deg)" % rad_to_deg(head.rotation.y))
	# A fake player to the NPC's front-right (+X, -Z) within wave range: head turns toward it and it waves.
	var dummy := Node3D.new()
	dummy.name = "FakePlayer"
	root.add_child(dummy)
	dummy.global_position = Vector3(2.0, 0.0, -1.8)
	dummy.add_to_group(Const.GROUP_PLAYERS)
	var max_arm := arm.rotation.z
	for i in 10:
		await create_timer(0.1).timeout
		max_arm = maxf(max_arm, arm.rotation.z)
	var expected_yaw := atan2(-2.0, 1.8)
	_check(absf(angle_difference(head.rotation.y, expected_yaw)) < deg_to_rad(12.0),
			"head turns toward the nearest player (yaw %.1f deg, expected ~%.1f)" % [rad_to_deg(head.rotation.y), rad_to_deg(expected_yaw)])
	_check(max_arm > deg_to_rad(90.0), "waves when a player walks up (arm peak %.0f deg)" % rad_to_deg(max_arm))
	# Player leaves (freed): stays null-safe.
	dummy.queue_free()
	for i in 6:
		await create_timer(0.1).timeout
	_check(is_instance_valid(npc) and npc.is_inside_tree(), "shopkeeper survives its target being freed")
	npc.queue_free()
	await process_frame


# --- helpers ----------------------------------------------------------------------------------------

func _ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, mask: int, exclude: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, mask, exclude)
	return space.intersect_ray(q)


func _hit_str(hit: Dictionary) -> String:
	if hit.is_empty():
		return "no hit"
	return "hit %s at %s" % [(hit["collider"] as Node).name, hit["position"]]


func _rids_under(n: Node) -> Array[RID]:
	var out: Array[RID] = []
	if n is CollisionObject3D:
		out.append((n as CollisionObject3D).get_rid())
	for c in n.find_children("*", "CollisionObject3D", true, false):
		out.append((c as CollisionObject3D).get_rid())
	return out


## Every collision object in the room except the floor/walls/ceiling (props, stations).
func _non_shell_rids(room: Room) -> Array[RID]:
	var out: Array[RID] = []
	for c in room.find_children("*", "CollisionObject3D", true, false):
		if c.name in ["Floor", "Walls", "Ceiling"] and c.get_parent() == room:
			continue
		out.append((c as CollisionObject3D).get_rid())
	return out


func _flat(v: Vector3) -> Vector3:
	v.y = 0.0
	return v.normalized() if v.length_squared() > 0.000001 else Vector3.ZERO


func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func _check(ok: bool, what: String) -> bool:
	if ok:
		_passed += 1
		print("PASS: " + what)
	else:
		_failed += 1
		print("FAIL: " + what)
	return ok


func _finish() -> void:
	print("world_test: %d passed, %d failed" % [_passed, _failed])
	print("WORLD TEST: " + ("PASS" if _failed == 0 else "FAIL"))
	quit(0 if _failed == 0 else 1)
