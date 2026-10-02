extends "res://tools/tests/qa_base.gd"
## M14 level suite (level agent): the bigger floor on a single headless host with fake workers (Net.players +
## World.server_spawn_player, no owning peer). The grow hall east of the main room and the loading dock south of it:
##   the three play areas and their union, contains_point; every station, spawn and marker of the old room is where it
##   was and the chute still pays; the doorways are walkable for a worker and for the 2x hostile plant; the four new
##   trays plant, grow and harvest; the arrivals; thrown items come to rest in the hall, on the dock and in a doorway
##   (not recovered as out of bounds), and still stop at the outer walls; the gunfire lanes (count, both ends, a crate
##   stack in the way, a clear one into the main room); Room.get_route between the pen, the hall and the dock; the
##   hostile plant walks from the pen through the pen door to a hall tray and eats it, does not sense a worker through
##   the wall, walks from the dock through the passage and the gate to a pen tray; the Boss's inspection route and the
##   head count (a worker in the hall is absent).
## Time for the plant is advanced with Hostiles.tick().
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/level_body.gd --port=7968
## Every engine/script error fails the run unless announced (qa_base.gd).

const PARK_A := Vector3(-8.5, 0.0, -6.5)   # the main room's north-west corner: out of every plant's reach below
const PARK_B := Vector3(-8.5, 0.0, -5.0)
const PARK_C := Vector3(-7.0, 0.0, -6.5)
const WORKER_RADIUS := 0.4
const PLANT_RADIUS := 0.64
## Stations, spawns and markers of the main room as they were before M14 (Room-local == global).
const OLD_PLACES := {
	"Stations/ShopCounter": Vector3(0, 0, -5), "Stations/Well": Vector3(-6.8, 0, 0), "Stations/TurnInStation": Vector3(0, 0, 5.8),
	"Stations/GrowPlot1": Vector3(5, 0, -3), "Stations/GrowPlot2": Vector3(7.6, 0, -3), "Stations/GrowPlot3": Vector3(5, 0, 0),
	"Stations/GrowPlot4": Vector3(7.6, 0, 0), "Stations/GrowPlot5": Vector3(5, 0, 3), "Stations/GrowPlot6": Vector3(7.6, 0, 3),
	"Stations/FuseBox": Vector3(-9.98, 1.2, -4), "Stations/EmergencyCabinet": Vector3(-9.98, 1.35, -2.5),
	"Spawns/Spawn1": Vector3(-1, 0.2, 0.9), "Spawns/Spawn2": Vector3(1, 0.2, 0.9), "Spawns/Spawn3": Vector3(-1.9, 0.2, 2.4),
	"Spawns/Spawn4": Vector3(1.9, 0.2, 2.4),
	"Decor/HeadcountSpot": Vector3(0, 0, -3.2), "Decor/BackRoomSpot": Vector3(1.2, 0.2, -6.7), "Decor/BackRoomDoor": Vector3(-2.06, 0, -7.35),
	"Decor/Booth/ShapeWest": Vector3(-2.06, 1.5, -5.975), "Decor/Booth/ShapeEast": Vector3(2.06, 1.5, -6.5),
	"Decor/FenceGate": Vector3(3, 0, 0), "Decor/Fence1": Vector3(4.25, 0, -5), "Decor/Fence2": Vector3(6.75, 0, -5),
	"Decor/Fence3": Vector3(9.25, 0, -5), "Decor/Fence4": Vector3(4.25, 0, 5), "Decor/Fence5": Vector3(6.75, 0, 5),
	"Decor/Fence6": Vector3(9.25, 0, 5), "Decor/Fence7": Vector3(3, 0, -3.75), "Decor/Fence8": Vector3(3, 0, 3.75),
	"Decor/InspectionRoute/P1": Vector3(-1.2, 0, -6.9), "Decor/InspectionRoute/P6": Vector3(3.9, 0, 0),
	"Decor/InspectionRoute/P12": Vector3(-1.2, 0, 4.1), "Decor/InspectionRoute/P16": Vector3(-1.2, 0, -6.9),
}
const NEW_TRAYS := {7: Vector3(16, 0, -1.5), 8: Vector3(18.6, 0, -1.5), 9: Vector3(16, 0, 1.5), 10: Vector3(18.6, 0, 1.5)}

var _world: World
var _room: Room
var _items: ItemManager
var _space: PhysicsDirectSpaceState3D
var _boss: ShopkeeperNPC
var _strain: SeedDef
var _chance0: float = 0.0
var _written: Array = []   # [peer, reason, count]
var _ate: Array = []       # [id, plot]


func _run() -> void:
	_label = "level"
	await get_tree().process_frame
	GameState.worker_written_up.connect(func(p: int, r: String, c: int) -> void: _written.append([p, r, c]))
	Hostiles.hostile_ate.connect(func(id: int, plot_index: int) -> void: _ate.append([id, plot_index]))
	var b: BalanceConfig = Config.balance

	step("hosting")
	Game.start_host("Tester", port_arg(7968))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	_items = _world.items
	_space = _world.get_world_3d().direct_space_state
	_boss = _room.get_station("ShopCounter").get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
	for id in [2, 3]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 3, "host + 2 fake workers spawned")
	_strain = b.seeds[0]
	_chance0 = _strain.mutation_chance
	_strain.mutation_chance = 0.0

	_test_areas()
	_test_old_room()
	_test_doorways()
	await _test_arrivals()
	_park_everyone()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.time_left = 900.0 # this suite is not about the clock
	await _test_chute()
	await _test_trays(b)
	Config.growth_speed_override = 0.0 # from here a planted tray stays "growing" for as long as the plant needs it
	await _test_throws()
	_test_lanes()
	_test_routes()
	await _test_hostile(b)
	await _test_boss(b)
	_strain.mutation_chance = _chance0
	Config.growth_speed_override = 1.0
	finish()


# --- areas -------------------------------------------------------------------------------------------------------------

func _test_areas() -> void:
	step("play areas")
	var areas := _room.get_play_areas()
	check(areas.size() == 3, "get_play_areas(): main room, grow hall, loading dock (%d)" % areas.size())
	if areas.size() != 3:
		return
	check(Room.INTERIOR_SIZE == Vector3(20, 6, 15) and _room.get_bounds().is_equal_approx(AABB(Vector3(-10, 0, -7.5), Vector3(20, 6, 15))),
			"INTERIOR_SIZE / get_bounds() still describe the main room")
	check(areas[0].is_equal_approx(_room.get_bounds()), "area 0 == get_bounds()")
	check(areas[1].is_equal_approx(AABB(Vector3(10, 0, -7.5), Vector3(12, 6, 15))), "area 1: the grow hall, x 10..22, the main room's z range (%s)" % areas[1])
	check(areas[2].is_equal_approx(AABB(Vector3(-10, 0, 7.5), Vector3(15, 6, 8.1))), "area 2: the loading dock, x -10..5, z 7.5..15.6 (%s)" % areas[2])
	var union := _room.get_play_bounds()
	check(union.is_equal_approx(AABB(Vector3(-10, 0, -7.5), Vector3(32, 6, 23.1))), "get_play_bounds(): the union box (%s)" % union)
	for a in areas:
		check(union.encloses(a), "the union encloses %s" % a)
	check(_room.contains_point(Vector3(0, 1, 0)) and _room.get_area_index(Vector3(0, 1, 0)) == 0, "contains_point: the main room's middle (area 0)")
	check(_room.contains_point(Vector3(16, 0, 0)) and _room.get_area_index(Vector3(16, 0, 0)) == 1, "contains_point: the hall floor (area 1)")
	check(_room.contains_point(Vector3(-2, 0.2, 11)) and _room.get_area_index(Vector3(-2, 0.2, 11)) == 2, "contains_point: the dock (area 2)")
	check(not _room.contains_point(Vector3(8, 1, 12)) and union.has_point(Vector3(8, 1, 12)), "contains_point: the corner outside between hall and dock is not on the floor")
	check(not _room.contains_point(Vector3(23, 1, 0)) and not _room.contains_point(Vector3(0, 1, 16.5)) and not _room.contains_point(Vector3(-11, 1, 10))
			and not _room.contains_point(Vector3(0, 1, -8)) and not _room.contains_point(Vector3(0, 9, 0)) and not _room.contains_point(Vector3(NAN, 0, 0)),
			"contains_point: outside every wall, above the ceiling and a bad point are false")
	for d in _room.get_doorways():
		check(_room.contains_point(d["center"]) and _room.contains_point(d["center"], 0.1), "contains_point: the middle of doorway %s (with a margin too)" % d["name"])
	check(_room.contains_point(Vector3(21.95, 0, 0)) and not _room.contains_point(Vector3(21.95, 0, 0), 0.1), "contains_point(p, 0.1): not within 0.1 m of an outer wall")


# --- the old room is where it was ----------------------------------------------------------------------------------

func _test_old_room() -> void:
	step("the old room")
	var moved: PackedStringArray = []
	for path: String in OLD_PLACES:
		var n := _room.get_node_or_null(NodePath(path)) as Node3D
		if n == null or n.global_position.distance_to(OLD_PLACES[path]) > 0.001:
			moved.append("%s at %s" % [path, n.global_position if n != null else null])
	check(moved.is_empty(), "%d stations, spawns, markers, fences and booth walls are where they were %s" % [OLD_PLACES.size(), moved])
	var facing_ok := true
	for i in range(1, 7):
		var p := _room.get_station("GrowPlot%d" % i)
		if p == null or p.global_basis.z.dot(Vector3.LEFT) < 0.999:
			facing_ok = false
	var shop := _room.get_station("ShopCounter")
	var chute := _room.get_station("TurnInStation")
	var well := _room.get_station("Well")
	check(facing_ok and shop.global_basis.z.dot(Vector3.BACK) > 0.999 and chute.global_basis.z.dot(Vector3.FORWARD) > 0.999
			and well.global_basis.z.dot(Vector3.RIGHT) > 0.999, "and face the way they did (trays west, counter south, chute north, tank east)")
	for i in 4:
		check(_room.get_spawn_transform(i).origin.distance_to(OLD_PLACES["Spawns/Spawn%d" % (i + 1)]) < 0.001, "get_spawn_transform(%d) unchanged" % i)
	check(_room.is_in_booth(Vector3(0, 0, -6.5)) and not _room.is_in_booth(Vector3(0, 0, -3)) and not _room.is_in_booth(Vector3(16, 0, 0)), "is_in_booth() unchanged")
	check(_room.get_stations().size() == Room.STATION_NAMES.size() and Room.STATION_NAMES.size() == 14 and Room.GROW_PLOT_COUNT == 10,
			"get_stations(): the ten old stations and four new trays (%d)" % _room.get_stations().size())


# --- doorways ------------------------------------------------------------------------------------------------------------

func _test_doorways() -> void:
	step("doorways")
	var doors := _room.get_doorways()
	check(doors.size() == 3, "three openings: pen door, corridor door, dock passage (%d)" % doors.size())
	for d in doors:
		var c: Vector3 = d["center"]
		var axis: Vector3 = d["axis"]
		check(float(d["width"]) >= 2.0 and float(d["height"]) >= 2.5, "%s: %.1f m wide, %.2f m high" % [d["name"], float(d["width"]), float(d["height"])])
		for who: Array in [["a worker", WORKER_RADIUS], ["the 2x plant", PLANT_RADIUS]]:
			var cyl := CylinderShape3D.new()
			cyl.radius = float(who[1])
			cyl.height = 1.8
			var q := PhysicsShapeQueryParameters3D.new()
			q.shape = cyl
			q.collision_mask = Const.LAYER_WORLD
			q.exclude = _tray_rids() # the pen's trays stand beside the way to the pen door: the plant walks over them
			var blocked := 0
			for s in range(-16, 17):
				q.transform = Transform3D(Basis.IDENTITY, c + axis * (float(s) * 0.1) + Vector3.UP * 0.95)
				if not _space.intersect_shape(q, 1).is_empty():
					blocked += 1
			check(blocked == 0, "%s: %s (radius %.2f) walks through, 1.6 m either side (%d of 33 steps blocked)" % [d["name"], who[0], float(who[1]), blocked])
		var chest := _space.intersect_ray(PhysicsRayQueryParameters3D.create(c - axis * 1.6 + Vector3.UP * 1.3, c + axis * 1.6 + Vector3.UP * 1.3, Const.LAYER_WORLD))
		var probe := _space.intersect_ray(PhysicsRayQueryParameters3D.create(c - axis * 1.6 + Vector3.UP * HostilePlant.PROBE_HEIGHT, c + axis * 1.6 + Vector3.UP * HostilePlant.PROBE_HEIGHT, Const.LAYER_WORLD))
		check(chest.is_empty() and probe.is_empty(), "%s: a clear line at chest height and at the plant's probe height" % d["name"])
		check(_room.get_area_index(c - axis * 1.6) == 0 and _room.get_area_index(c + axis * 1.6) >= 1, "%s: from the main room into area %d" % [d["name"], _room.get_area_index(c + axis * 1.6)])
		check(not _room.is_wall_between(c - axis * 1.6, c + axis * 1.6), "%s: is_wall_between() is false straight through it" % d["name"])
	check(_room.is_wall_between(Vector3(8.8, 0, 2.5), Vector3(11.6, 0, 2.5)), "is_wall_between(): the pen and the hall, either side of the east wall")
	check(_room.is_wall_between(Vector3(0, 0, 6.8), Vector3(0, 0, 9)), "is_wall_between(): the chute's wall and the dock behind it")
	check(not _room.is_wall_between(Vector3(2.2, 0, -3.75), Vector3(3.8, 0, -3.75)), "is_wall_between(): the pen's fence is not a wall")
	check(not _room.is_wall_between(Vector3(-5, 0, 0), Vector3(5, 0, 3)), "is_wall_between(): across the main room is clear")


# --- arrivals ----------------------------------------------------------------------------------------------------------

func _test_arrivals() -> void:
	step("arrivals")
	var me: Player = Game.local_player
	var passage: Vector3 = _room.get_doorways()[2]["center"]
	check(_room.get_node_or_null(^"Arrivals") != null and _room.get_arrival_points().size() == 4, "Arrivals/Arrival0..3 exist")
	var seen: Array[Vector3] = []
	for i in 4:
		var t := _room.get_arrival_transform(i)
		var m := _room.get_node_or_null("Arrivals/Arrival%d" % i) as Marker3D
		check(m != null and t.is_equal_approx(m.global_transform), "get_arrival_transform(%d) is Arrival%d" % [i, i])
		check(_room.get_area_index(t.origin) == 2 and t.origin.y > 0.0 and t.origin.y < 0.5, "Arrival%d is on the loading dock (%s)" % [i, t.origin])
		var facing := -t.basis.z
		var inwards := Vector3(passage.x - t.origin.x, 0.0, passage.z - t.origin.z).normalized()
		check(facing.dot(inwards) > 0.9 and absf(facing.y) < 0.001, "Arrival%d faces into the building (the passage; dot %.2f)" % [i, facing.dot(inwards)])
		for other in seen:
			check(Vector2(other.x - t.origin.x, other.z - t.origin.z).length() >= 1.5, "Arrival%d is 1.5 m or more from the others" % i)
		seen.append(t.origin)
	check(_room.get_arrival_transform(5).origin.distance_to(_room.get_arrival_transform(1).origin) > 0.5 and _room.get_arrival_transform(-1).is_equal_approx(_room.get_arrival_transform(3)),
			"get_arrival_transform() wraps like the spawns (5 beside 1, -1 is 3)")
	var van := _room.get_node_or_null(^"Dock/DockVan") as StaticBody3D
	check(van != null and van.get_node_or_null(^"Visual") != null and van.collision_layer == Const.LAYER_WORLD, "Dock/DockVan/Visual exists, the van is solid")
	# A worker put on an arrival spot stands on the dock floor (nothing to fall through).
	me.place_at(_room.get_arrival_transform(0))
	for i in 20:
		await get_tree().physics_frame
	check(me.is_on_floor() and absf(me.global_position.y) < 0.05 and Vector2(me.global_position.x + 1.3, me.global_position.z - 9.4).length() < 0.1,
			"the host placed on Arrival0 stands on the dock floor (%s)" % me.global_position)


# --- the chute still pays ---------------------------------------------------------------------------------------------

func _test_chute() -> void:
	step("the chute")
	var chute := _room.get_station("TurnInStation") as TurnInStation
	var front := _room.get_station_access_point("TurnInStation", 1.3)
	var cap := CapsuleShape3D.new()
	cap.radius = WORKER_RADIUS
	cap.height = 1.8
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = cap
	q.collision_mask = Const.LAYER_WORLD
	q.transform = Transform3D(Basis.IDENTITY, front + Vector3.UP * 0.95)
	check(_space.intersect_shape(q, 1).is_empty(), "a worker fits in front of the chute (%s)" % front)
	var product := _items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": _strain.id, "amount": 1}, front)
	await wait_frames(1)
	var money0 := GameState.money
	check(product != null and chute.server_sell_item(product, 1) and GameState.money > money0, "a bundle sells at the chute (cash on hand %d -> %d)" % [money0, GameState.money])
	# A bundle thrown at the chute from the floor still counts (the wall behind it is 0.6 m thick now).
	var bundle := _items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": _strain.id, "amount": 1}, Vector3(0, 0, 2))
	await wait_frames(1)
	money0 = GameState.money
	check(_items.server_throw_item(bundle, Vector3(0, 1.3, 2.5), Vector3(0, 1.5, 6.0), 1), "a bundle thrown at the chute")
	await wait_until(func() -> bool: return GameState.money > money0, 3.0, "a chute shot still pays")
	await wait_frames(2)
	check(_items.get_items_of_type(Const.ITEM_PRODUCT).is_empty(), "the bundle is gone (%d -> %d)" % [money0, GameState.money])


# --- the four new trays -------------------------------------------------------------------------------------------------

func _test_trays(b: BalanceConfig) -> void:
	step("the grow hall's trays")
	Config.growth_speed_override = 1.0
	var in_group := get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS)
	check(in_group.size() == 10, "ten trays in group grow_plots (%d)" % in_group.size())
	for i: int in NEW_TRAYS:
		var plot := _room.get_station("GrowPlot%d" % i) as GrowPlot
		if not check(plot != null and plot.scene_file_path == "res://scenes/stations/grow_plot.tscn", "GrowPlot%d is an instance of the tray scene" % i):
			continue
		check(plot.global_position.distance_to(NEW_TRAYS[i]) < 0.001 and _room.get_area_index(plot.global_position) == 1, "GrowPlot%d stands in the hall at %s" % [i, plot.global_position])
		check(plot.is_in_group(Const.GROUP_GROW_PLOTS) and plot.is_in_group(Const.GROUP_INTERACTABLES) and HostilePlant.plot_index_of(plot) == i, "GrowPlot%d: groups, index %d" % [i, i])
		check(plot.is_empty() and plot.server_plant(_strain.id) and plot.stage == GrowPlot.Stage.SEEDLING, "GrowPlot%d: planted" % i)
		var guard := 0
		while plot.stage != GrowPlot.Stage.READY and guard < 6:
			plot.water = 0.0
			plot.server_water(1.0)
			plot.tick(plot.get_stage_duration(plot.stage) + 0.05)
			guard += 1
		check(plot.stage == GrowPlot.Stage.READY and guard == 3, "GrowPlot%d: watered and grown to READY in three stages (%d)" % [i, guard])
		Hostiles.tick(0.05)
		check(not plot.is_turning(), "GrowPlot%d: a strain that never turns stays put" % i)
	# Harvest: one into a worker's hands in front of the tray, the others onto the floor in front of them.
	var w2 := _world.get_player(2)
	var plot7 := _room.get_station("GrowPlot7") as GrowPlot
	var front7 := _room.get_station_access_point("GrowPlot7", 1.2)
	_put(w2, front7)
	await wait_frames(2)
	check(_room.get_area_index(front7) == 1 and plot7.can_interact(w2), "a worker in front of GrowPlot7 (%s) can use it" % front7)
	check(plot7.server_harvest(w2) and plot7.is_empty() and _items.get_held_by(2) != null and _items.get_held_by(2).item_type == Const.ITEM_PRODUCT, "GrowPlot7: harvested into his hands")
	_items.server_release_holder(2)
	await wait_frames(2)
	var dropped := _items.get_items_of_type(Const.ITEM_PRODUCT)
	check(dropped.size() == 1 and _room.get_area_index(dropped[0].global_position) == 1 and absf(dropped[0].global_position.y) < 0.05, "let go of: the bundle lies on the hall floor (%s)" % [dropped[0].global_position if dropped.size() == 1 else null])
	for i: int in [8, 9, 10]:
		var plot := _room.get_station("GrowPlot%d" % i) as GrowPlot
		var before := _items.get_items_of_type(Const.ITEM_PRODUCT).size()
		check(plot.server_harvest(null) and plot.is_empty() and plot.strain_id == &"", "GrowPlot%d: harvested, the tray is empty" % i)
		await wait_frames(1)
		var products := _items.get_items_of_type(Const.ITEM_PRODUCT)
		var newest: Item = products[products.size() - 1] if products.size() == before + 1 else null
		check(newest != null and _room.get_area_index(newest.global_position) == 1 and newest.global_position.distance_to(plot.global_position) < 2.0,
				"its bundle lies in the hall in front of it")
	for it in _items.get_items_of_type(Const.ITEM_PRODUCT):
		_items.server_despawn_item(it)
	_park_everyone()
	await wait_frames(2)


# --- thrown items stay where they land ------------------------------------------------------------------------------------

func _test_throws() -> void:
	step("throws into the hall, onto the dock, into a doorway, at the outer walls")
	var can := _items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, Vector3(-3, 0, 3)) as WateringCan
	await wait_frames(1)
	if not check(can != null, "a can to throw"):
		return
	var main := _room.get_bounds()
	# [what, origin, velocity, the area it must rest in, the straight-arc landing spot (INF = stopped by a wall)]
	var throws := [
		["from the main room through the corridor door into the hall", Vector3(8.0, 1.2, 6.25), Vector3(9.0, 2.0, 0.0), 1, true],
		["from the main room through the passage onto the dock", Vector3(-5.45, 1.2, 5.0), Vector3(0.0, 2.0, 9.0), 2, true],
		["from the pen through the pen door into the hall", Vector3(8.6, 1.2, -1.25), Vector3(8.0, 2.0, 0.0), 1, true],
		["from the hall back into the pen", Vector3(12.5, 1.2, -1.25), Vector3(-7.0, 2.0, 0.0), 0, true],
		["at the hall's east wall", Vector3(19.5, 1.2, 4.0), Vector3(9.0, 2.0, 0.0), 1, false],
		["at the dock's roller door", Vector3(-2.5, 1.2, 13.0), Vector3(0.0, 2.0, 9.0), 2, false],
		["on the dock at the parked van", Vector3(1.0, 1.2, 13.4), Vector3(0.0, 2.0, -9.0), 2, false],
		["at the main room's west wall", Vector3(-4.0, 1.2, 5.8), Vector3(-9.0, 1.5, 0.0), 0, false],
	]
	for t: Array in throws:
		var origin: Vector3 = t[1]
		var vel: Vector3 = t[2]
		check(_items.server_throw_item(can, origin, vel, 1), "thrown %s" % t[0])
		await wait_until(func() -> bool: return not can.is_flying(), 3.5, "the flight ended")
		var pos := can.global_position
		var landing := _items._probe_floor_below(pos + Vector3.UP * 0.02)
		check(_room.get_area_index(pos) == int(t[3]) and absf(pos.y) < 0.05 and _room.contains_point(pos, 0.1), "it rests in area %d at %s" % [int(t[3]), pos])
		check(_items._is_drop_spot_free(landing, null), "on a free spot (not in a wall, not on a station)")
		if int(t[3]) != 0:
			check(not main.grow(-0.1).has_point(pos + Vector3.UP * 0.5), "outside the main room's bounds: the old check would have sent it back")
		if bool(t[4]):
			var t_land := (vel.y + sqrt(vel.y * vel.y + 2.0 * 9.8 * origin.y)) / 9.8
			var predicted := Vector3(origin.x + vel.x * t_land, 0.0, origin.z + vel.z * t_land)
			check(Vector2(pos.x - predicted.x, pos.z - predicted.z).length() < 0.3, "where the arc comes down (%s), not recovered to the launch point" % predicted)
		else:
			check(Vector2(pos.x - origin.x, pos.z - origin.z).length() > 1.0, "it stopped at the wall, %.1f m from the launch point" % Vector2(pos.x - origin.x, pos.z - origin.z).length())
	# Into a doorway: the threshold between two areas is a fine place to rest.
	check(_items.server_throw_item(can, Vector3(8.0, 1.2, 6.25), Vector3(3.1, 2.0, 0.0), 1), "thrown short, into the corridor door")
	await wait_until(func() -> bool: return not can.is_flying(), 3.5, "the flight ended")
	check(can.global_position.x > 10.0 and can.global_position.x < 10.6 and absf(can.global_position.z - 6.25) < 0.2 and _room.contains_point(can.global_position, 0.1),
			"it rests on the threshold (%s)" % can.global_position)
	check(_items._inside_play(can.global_position, main) and not _items._inside_bounds(can.global_position, main), "inside the play areas, outside the main room's bounds")
	# The booth is still closed to thrown things (M13).
	check(_items.server_throw_item(can, Vector3(0.0, 1.5, -2.5), Vector3(0.0, 2.5, -7.0), 1), "thrown over the counter")
	await wait_until(func() -> bool: return not can.is_flying(), 3.5, "the flight ended")
	check(not _room.is_in_booth(can.global_position) and _room.get_area_index(can.global_position) == 0, "it does not rest in the booth (%s)" % can.global_position)
	# The alley (the lobby agent's World/Lobby with get_bounds()): what is thrown there may rest there. A stand-in node
	# does the job while the real one is not in world.tscn.
	var lobby := _world.get_node_or_null(^"Lobby")
	var stand_in: Node3D = null
	if lobby == null:
		var script := GDScript.new()
		script.source_code = "extends Node3D\nfunc get_bounds() -> AABB:\n\treturn AABB(Vector3(-6, 0, 74), Vector3(12, 6, 12))\n"
		script.reload()
		stand_in = Node3D.new()
		stand_in.set_script(script)
		stand_in.name = "Lobby"
		_world.add_child(stand_in)
		lobby = stand_in
	if lobby.has_method(&"get_bounds"):
		var alley: AABB = lobby.call(&"get_bounds")
		var mid := Vector3(alley.get_center().x, alley.position.y, alley.get_center().z)
		check(_items._inside_play(mid, main) and not _room.contains_point(mid), "the middle of the alley is a place to rest (it is not one of the room's play areas)")
		check(not _items._inside_play(Vector3(alley.end.x + 3.0, alley.position.y, mid.z), main), "3 m beside the alley is not")
	if stand_in != null:
		stand_in.queue_free()
	_items.server_despawn_item(can)
	await wait_frames(1)


# --- gunfire lanes -----------------------------------------------------------------------------------------------------

func _test_lanes() -> void:
	step("gunfire lanes")
	var lanes := _room.get_gunfire_lanes()
	check(lanes.size() >= 4, "at least four lanes (%d)" % lanes.size())
	var into_main := 0
	var clear_into_main := 0
	var by_crate := 0
	var from_dock := 0
	var from_west_window := 0
	var over_tray := 0
	var ends_ok := true
	for lane: Dictionary in lanes:
		var from: Vector3 = lane.get("from", Vector3.INF)
		var to: Vector3 = lane.get("to", Vector3.INF)
		if not (lane.size() == 2 and from.is_finite() and to.is_finite() and absf(from.y - 1.3) < 0.01 and absf(to.y - 1.3) < 0.01
				and _room.contains_point(from) and _room.contains_point(to) and not _room.contains_point(from, 0.6) and from.distance_to(to) > 5.0):
			ends_ok = false
		var q := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD)
		q.hit_from_inside = true
		var hit := _space.intersect_ray(q)
		var from_area := _room.get_area_index(from)
		var to_area := _room.get_area_index(to)
		if from_area == 2:
			from_dock += 1
		if from_area == 0 and from.x < -9.0:
			from_west_window += 1
		if from_area == 2 and to_area == 0:
			into_main += 1
			if hit.is_empty():
				clear_into_main += 1
		if not hit.is_empty() and String((hit["collider"] as Node).name).begins_with("Crate") and _room.get_node(^"Dock").is_ancestor_of(hit["collider"]):
			by_crate += 1
			check((hit["position"] as Vector3).distance_to(from) > 1.5 and _room.get_area_index(hit["position"]) == 2, "a crate stack on the dock stops a lane %.1f m in (%s)" % [(hit["position"] as Vector3).distance_to(from), (hit["collider"] as Node).name])
		if hit.is_empty():
			for i in range(1, Room.GROW_PLOT_COUNT + 1):
				var tray := _room.get_station("GrowPlot%d" % i)
				var flat_from := Vector2(from.x, from.z)
				var flat_to := Vector2(to.x, to.z)
				var p := Vector2(tray.global_position.x, tray.global_position.z)
				if Geometry2D.get_closest_point_to_segment(p, flat_from, flat_to).distance_to(p) < 0.6:
					over_tray += 1
	check(ends_ok, "every lane is {from, to} at chest height (1.3 m), from just inside an outer wall to a point on the floor plan")
	check(from_dock >= 3 and from_west_window >= 1, "%d lanes start at the dock's door and windows, %d at the main room's west window" % [from_dock, from_west_window])
	check(into_main >= 3, "%d lanes run across the dock and into the main room" % into_main)
	check(by_crate >= 1 and by_crate < lanes.size(), "the crates stand in %d of %d lanes" % [by_crate, lanes.size()])
	check(clear_into_main >= 1, "%d of them reach the main room with nothing in the way" % clear_into_main)
	check(over_tray >= 1, "an open lane passes within 0.6 m of %d trays" % over_tray)


# --- routes -----------------------------------------------------------------------------------------------------------------

func _test_routes() -> void:
	step("Room.get_route")
	var pen := Vector3(6.3, 0, -1.5)
	var hall := Vector3(14.7, 0, 1.5)
	var dock := Vector3(-2.0, 0, 11.5)
	var floor_spot := Vector3(-3.0, 0, 1.0)
	check(_room.get_route(floor_spot, Vector3(-6.0, 0, 4.0)).is_empty(), "across the open floor: empty (the straight line is clear)")
	check(_room.get_route(pen, Vector3(8.9, 0, 3.0)).is_empty(), "inside the pen: empty")
	check(_room.get_route(Vector3(12.0, 0, 6.0), hall).is_empty() and _room.get_route(dock, Vector3(-8, 0, 13)).is_empty(), "inside the hall, on the dock: empty")
	check(_room.get_route(floor_spot, Vector3(0, 0, -6.5)).is_empty(), "into the Boss's booth: empty (no route)")
	check(_room.get_route(floor_spot, Vector3(8, 0, 12)).is_empty() and _room.get_route(Vector3(30, 0, 0), floor_spot).is_empty() and _room.get_route(Vector3(NAN, 0, 0), floor_spot).is_empty(),
			"to or from a point off the floor plan: empty")
	var cases := [
		["the open floor -> a pen tray (round the fence, by the gate)", floor_spot + Vector3(0, 0, -4.5), Vector3(4.4, 0, -4.2), [0], [2]],
		["the pen -> the hall, far side (the pen door)", Vector3(4.2, 0, 3.6), hall, [0, 1], [3, 4]],
		["the hall -> the dock", hall, dock, [1, 0, 2], [5, 6, 8, 10]],
		["the dock -> the pen (the passage, then straight through the gate)", dock, pen, [2, 0], [10]],
		["the corridor south of the pen -> the tray behind the fence (round by the gate)", Vector3(6.0, 0, 6.0), Vector3(6.3, 0, 3.6), [0], [8, 0]],
		["the open floor -> the hall's south side (round the pen, the corridor door)", Vector3(1.0, 0, 4.0), Vector3(16.0, 0, 6.0), [0, 1], [8]],
		["the pen -> the hall's south-west corner", pen, Vector3(11.5, 0, 6.8), [0, 1], [4]],
		["the open floor -> the dock (the passage)", floor_spot, dock, [0, 2], [10]],
	]
	for c: Array in cases:
		var from: Vector3 = c[1]
		var to: Vector3 = c[2]
		var route := _room.get_route(from, to)
		if not check(route.size() >= 2 and route[route.size() - 1] == to, "%s: %d points, ending at the goal %s" % [c[0], route.size(), route]):
			continue
		# Every leg is walkable: nothing of the shell or the fence at the plant's probe height (trays do not count).
		var exclude := _tray_rids()
		var blocked: PackedStringArray = []
		var areas_seen: Array[int] = [_room.get_area_index(from)]
		var prev := from
		var length := 0.0
		for p in route:
			var a := Vector3(prev.x, HostilePlant.PROBE_HEIGHT, prev.z)
			var b3 := Vector3(p.x, HostilePlant.PROBE_HEIGHT, p.z)
			var hit := _space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b3, Const.LAYER_WORLD, exclude))
			if not hit.is_empty():
				blocked.append("%s -> %s hits %s" % [prev, p, _room.get_path_to(hit["collider"])])
			length += Vector2(p.x - prev.x, p.z - prev.z).length()
			var area := _room.get_area_index(p)
			if area != areas_seen[areas_seen.size() - 1]:
				areas_seen.append(area)
			prev = p
		check(blocked.is_empty(), "%s: every leg is clear on LAYER_WORLD at the plant's probe height %s" % [c[0], blocked])
		check(areas_seen == c[3], "%s: it goes through areas %s (%s)" % [c[0], c[3], areas_seen])
		var via_ok := true
		for index: int in c[4]:
			var want := Vector3(Room.ROUTE_POINTS[index].x, 0.0, Room.ROUTE_POINTS[index].y)
			var found := false
			for p in route:
				if p.distance_to(want) < 0.01:
					found = true
			via_ok = via_ok and found
		check(via_ok and length < from.distance_to(to) * 3.0 + 8.0, "%s: by way of route points %s, %.1f m for %.1f m as the crow flies" % [c[0], c[4], length, from.distance_to(to)])


# --- the hostile plant crosses rooms -----------------------------------------------------------------------------------

func _test_hostile(b: BalanceConfig) -> void:
	step("the plant: from the pen to a hall tray")
	_park_everyone()
	await wait_frames(2)
	var plot8 := _room.get_station("GrowPlot8") as GrowPlot
	check(plot8.server_plant(_strain.id) and plot8.server_water(1.0), "GrowPlot8 (hall) grows")
	plot8.stage_progress = 0.3
	var start: Vector3 = (_room.get_station("GrowPlot1") as Node3D).global_position
	var id := Hostiles.server_spawn(_strain.id, start)
	await wait_frames(1)
	var h := Hostiles.get_hostile(id) as HostilePlant
	if not check(h != null, "a plant uprooted in GrowPlot1 (pen)"):
		return
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.3)
	check(h.state == HostilePlant.State.ROAM and h.get_target_plot() == plot8, "it roams, heading for the only growing tray (%s)" % h.get_state_name())
	check(h.is_on_route() and h.get_route_points().size() >= 1, "the straight line is a wall: it walks a route %s" % [h.get_route_points()])
	var through_door := false
	var off_plan := 0
	var in_wall := 0
	var waited := 0.0
	while h.state != HostilePlant.State.EAT and waited < 20.0:
		Hostiles.tick(0.1)
		waited += 0.1
		var p := h.global_position
		if not _room.contains_point(p):
			off_plan += 1
		if p.x > 10.0 and p.x < 10.6:
			if p.z > -2.25 + 0.3 and p.z < -0.25 - 0.3:
				through_door = true
			else:
				in_wall += 1
	check(h.state == HostilePlant.State.EAT and h.get_target_plot() == plot8, "after %.1f s it eats GrowPlot8 (%s at %s)" % [waited, h.get_state_name(), h.global_position])
	check(through_door and in_wall == 0 and off_plan == 0, "it went through the pen door, never through the wall, never off the floor plan")
	check(_room.get_area_index(h.global_position) == 1 and Vector2(h.global_position.x - 18.6, h.global_position.z + 1.5).length() < HostilePlant.EAT_DISTANCE + 0.3 and not h.is_on_route(),
			"it stands at the tray in the hall, the route is done")
	_ate.clear()
	Hostiles.tick(HostilePlant.MIN_EAT_SEC + 1.5)
	await wait_frames(1)
	check(plot8.is_empty() and _ate == [[id, 8]], "the crop is lost: hostile_ate(id, 8) %s" % [_ate])
	# Nothing left to eat: it wanders, and stays in the hall.
	var strayed := 0
	for i in 150:
		Hostiles.tick(0.1)
		if _room.get_area_index(h.global_position) != 1:
			strayed += 1
	check(h.state == HostilePlant.State.ROAM and strayed == 0, "fifteen seconds of wandering: it stays in the hall")

	step("the plant: a wall is not a fence")
	Hostiles.server_despawn_all()
	await wait_frames(1)
	id = Hostiles.server_spawn(_strain.id, Vector3(11.7, 0.0, 2.5))
	await wait_frames(1)
	h = Hostiles.get_hostile(id) as HostilePlant
	var w2 := _world.get_player(2)
	_put(w2, Vector3(8.9, 0.0, 2.5)) # in the pen, 2.8 m from the plant, the east wall between them
	await wait_frames(2)
	var chased := 0
	for i in 60:
		Hostiles.tick(0.1)
		if h.state == HostilePlant.State.CHASE or h.state == HostilePlant.State.BITE:
			chased += 1
	check(chased == 0 and h.state == HostilePlant.State.ROAM, "a worker 2.8 m away behind the wall is not sensed (%s)" % h.get_state_name())
	h.global_position = Vector3(11.7, 0.0, 2.5)
	h._wander_target = Vector3.INF
	_put(w2, Vector3(15.0, 0.0, 2.5)) # in the hall with it, 3.3 m away
	await wait_frames(2)
	Hostiles.tick(0.2)
	check(h.state == HostilePlant.State.CHASE and h.get_target_index() == 2, "the same worker in the hall with it: it chases (%s)" % h.get_state_name())
	Hostiles.server_despawn_all()
	_park_everyone()
	await wait_frames(2)

	step("the plant: from the dock to a pen tray")
	var plot3 := _room.get_station("GrowPlot3") as GrowPlot
	check(plot3.server_plant(_strain.id) and plot3.server_water(1.0), "GrowPlot3 (pen) grows")
	plot3.stage_progress = 0.3
	id = Hostiles.server_spawn(_strain.id, Vector3(-3.0, 0.0, 12.5))
	await wait_frames(1)
	h = Hostiles.get_hostile(id) as HostilePlant
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.3)
	check(h.state == HostilePlant.State.ROAM and h.is_on_route() and h.get_target_plot() == plot3, "it sets off on a route %s" % [h.get_route_points()])
	var through_passage := false
	var through_gate := false
	off_plan = 0
	in_wall = 0
	waited = 0.0
	var last := h.global_position
	while h.state != HostilePlant.State.EAT and waited < 30.0:
		Hostiles.tick(0.1)
		waited += 0.1
		var p := h.global_position
		if not _room.contains_point(p):
			off_plan += 1
		if p.z > 7.5 and p.z < 8.1:
			if p.x > -7.1 + 0.3 and p.x < -2.9 - 0.3:
				through_passage = true
			else:
				in_wall += 1
		if (last.x - 3.0) * (p.x - 3.0) <= 0.0 and absf(p.z) < 2.5 - 0.3:
			through_gate = true
		last = p
	check(h.state == HostilePlant.State.EAT and h.get_target_plot() == plot3, "after %.1f s it eats GrowPlot3 (%s at %s)" % [waited, h.get_state_name(), h.global_position])
	check(through_passage and through_gate and in_wall == 0 and off_plan == 0, "by the passage and the pen gate (passage %s, gate %s), never through a wall" % [through_passage, through_gate])
	Hostiles.server_despawn_all()
	plot3.server_reset()
	await wait_frames(2)
	check(Hostiles.count() == 0, "floor cleared")


# --- the Boss ---------------------------------------------------------------------------------------------------------------

func _test_boss(b: BalanceConfig) -> void:
	step("the Boss: inspection route, head count")
	var me: Player = Game.local_player
	var route := _room.get_inspection_route()
	var inside := route.size() == 16
	for p in route:
		if _room.get_area_index(p) != 0 or absf(p.y) > 0.01:
			inside = false
	check(inside, "the inspection route: 16 points on the main room's floor")
	var exclude: Array[RID] = []
	var door := _room.get_backroom_door()
	if door != null:
		for c in door.find_children("*", "CollisionObject3D", true, false):
			exclude.append((c as CollisionObject3D).get_rid())
	var blocked := 0
	for i in range(1, route.size()):
		if not _space.intersect_ray(PhysicsRayQueryParameters3D.create(route[i - 1] + Vector3.UP, route[i] + Vector3.UP, Const.LAYER_WORLD, exclude)).is_empty():
			blocked += 1
	check(blocked == 0, "every leg of it is still clear at 1 m (the booth door excluded)")
	check(_boss != null and Events.server_start_event(Events.EVENT_INSPECTION) and Events.is_event_active(Events.EVENT_INSPECTION), "an inspection starts")
	await wait_frames(3)
	check(_boss.is_walking(), "the Boss walks his route")
	Events.server_end_event()
	await wait_until(func() -> bool: return not Events.is_event_active(), 2.0, "inspection ended")
	await wait_frames(2)
	# Head count: the host at the line, one worker in the hall, one on the dock.
	var spot := _room.get_headcount_spot()
	check(spot.distance_to(Vector3(0, 0, -3.2)) < 0.001 and _room.get_headcount_route().size() >= 2, "the line is where it was (%s)" % spot)
	me.velocity = Vector3.ZERO
	me.global_position = spot + Vector3(-0.6, 0.05, 0.4)
	_put(_world.get_player(2), Vector3(14.0, 0.0, 4.0))
	_put(_world.get_player(3), Vector3(-6.0, 0.0, 12.0))
	await wait_frames(2)
	_written.clear()
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count starts")
	Events.tick(b.headcount_sec + 0.1)
	await wait_frames(2)
	var absent: Array[int] = []
	for e in _written:
		if String(e[1]) == Const.WRITE_UP_ABSENT:
			absent.append(int(e[0]))
	absent.sort()
	check(not Events.is_event_active() and absent == [2, 3], "the worker in the hall and the one on the dock are absent, the host at the line is not %s" % [absent])
	_park_everyone()
	await wait_frames(2)


# --- helpers ------------------------------------------------------------------------------------------------------------

## The trays' bodies (the hostile plant's probe leaves them out: it walks off one tray and up to the next).
func _tray_rids() -> Array[RID]:
	var out: Array[RID] = []
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var body := n.get_node_or_null(^"Body") as CollisionObject3D
		if body != null:
			out.append(body.get_rid())
	return out


## Everybody into the main room's north-west corner: further than the sense range from every walk in this suite.
func _park_everyone() -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(PARK_A.x, 0.05, PARK_A.z)
	_put(_world.get_player(2), PARK_B)
	_put(_world.get_player(3), PARK_C)


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))
