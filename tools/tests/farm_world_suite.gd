extends Node
## End-to-end farming test on the real game stack (owner: farming agent). Run through farm_world_test.gd.
## Hosts a real session (Game.start_host -> World/Room/ItemManager/items/Player) and plays the farming loop
## through the public Interactable.interact() path (local check -> RPC to the server -> distance +
## can_interact validation -> _server_interact): starting cans, plant, water, refill, grow, harvest, reset.
## In the real room the player's own camera + Interactor ray (eye height 1.6 m, 2.5 m from the plot, down the
## aisle) targets the READY plant at its top cola and side leaves, and the EMPTY plot by its tray only.

## Emitted once with the number of failed checks.
signal finished(failures: int)

const GROWTH_OVERRIDE := 40.0

var _passed := 0
var _failed := 0

func run() -> void:
	Config.growth_speed_override = GROWTH_OVERRIDE
	var port := 22000 + randi() % 20000
	var err: Error = Game.start_host("FarmTester", port)
	_check(err == OK, "Game.start_host", error_string(err))
	if err != OK:
		return _finish()
	var world: World = await Game.world_ready
	await _frames(5)
	var items := world.items
	var room := world.room
	var well := room.get_node("Stations/Well") as Well
	var plot := room.get_node("Stations/GrowPlot1") as GrowPlot
	var plot2 := room.get_node("Stations/GrowPlot2") as GrowPlot
	var player := Game.get_player(Const.SERVER_PEER_ID)
	_check(well != null and plot != null and plot2 != null and player != null, "room has Well + GrowPlots, host player spawned")
	if well == null or plot == null or player == null:
		return _finish()
	var cap := GameState.get_can_capacity()

	# --- starting cans
	var cans := _cans(items)
	var at_spots := true
	var spots := well.get_can_spots()
	for c in cans:
		var near := false
		for s in spots:
			near = near or c.global_position.distance_to(s.global_position) < 0.05
		at_spots = at_spots and near and int(c.get(&"charges")) == cap and not c.is_held()
	_check(cans.size() == Config.balance.starting_watering_cans and at_spots,
		"%d full watering cans spawned at the well's CanSpots" % Config.balance.starting_watering_cans, "%d cans" % cans.size())
	if cans.is_empty():
		return _finish()
	var can: Item = cans[0]

	# --- plant (real SeedPacket in hands)
	var packet := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"}, player.global_position, player.peer_id)
	await _frames(2)
	_stand_at(player, plot)
	_check(player.get_held_item() == packet and plot.get_prompt(player) == "Plant Budget Bud" and plot.can_interact(player),
		"holding a real seed packet: prompt 'Plant Budget Bud'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	_check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == &"budget", "interact() plants the seed (server validated)")
	_check(player.get_held_item() == null and not is_instance_valid(packet), "the seed packet is consumed")

	# --- water with a real WateringCan
	items.server_give_item(can, player.peer_id)
	await _frames(2)
	_check(plot.get_prompt(player) == "Water plant (dry)", "holding a can at a dry plant: 'Water plant (dry)'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	_check(is_equal_approx(plot.water, minf(1.0, Config.balance.water_per_charge)) and int(can.get(&"charges")) == cap - 1,
		"interact() waters the plant and spends one charge", "water %.3f charges %d" % [plot.water, int(can.get(&"charges"))])
	plot.interact(player)   # already full -> denied locally, nothing changes
	await _frames(3)
	_check(int(can.get(&"charges")) == cap - 1 and plot.get_denied_reason(player) == "Already watered.", "watering a full plot is denied")

	# --- refill at the well
	_stand_at(player, well)
	_check(well.get_prompt(player) == "Fill can (%d/%d)" % [cap - 1, cap] and well.can_interact(player),
		"well prompt with a part-empty can", well.get_prompt(player))
	well.interact(player)
	await _frames(3)
	_check(int(can.get(&"charges")) == cap and well.get_denied_reason(player) == "Can's full.", "interact() at the well refills the can")

	# --- grow during a round
	GameState.server_start_round()
	await _frames(2)
	_check(GameState.is_playing(), "round started (PLAYING)")
	var deadline := Time.get_ticks_msec() + 15000
	while plot.stage != GrowPlot.Stage.READY and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_check(plot.stage == GrowPlot.Stage.READY, "plant grows to READY on the host's tick (growth x%d)" % int(GROWTH_OVERRIDE))
	var water_at_ready := plot.water
	await _frames(20)
	_check(plot.water == water_at_ready and plot.stage == GrowPlot.Stage.READY, "READY plant stops drinking")
	await _check_ready_targeting(player, plot)

	# --- harvest
	_stand_at(player, plot)
	_check(not plot.can_interact(player) and plot.get_denied_reason(player) == "Hands full.", "harvest denied while holding the can")
	items.server_drop_item(can, player.global_position + Vector3(0.0, 0.0, 0.8))
	await _frames(2)
	_check(plot.get_prompt(player) == "Harvest Budget Bud x1", "empty hands at READY: 'Harvest Budget Bud x1'", plot.get_prompt(player))
	plot.interact(player)
	await _frames(3)
	var product := player.get_held_item()
	_check(product != null and product.item_type == Const.ITEM_PRODUCT and StringName(product.get(&"strain_id")) == &"budget"
		and int(product.get(&"amount")) == Config.balance.get_seed(&"budget").yield_amount,
		"harvest puts a Budget Bud product (amount = yield) in the player's hands")
	_check(plot.stage == GrowPlot.Stage.EMPTY and plot.strain_id == &"", "plot is EMPTY after the harvest")
	await _check_empty_targeting(player, plot)

	# --- full game reset: plots cleared, cans back at the well
	plot2.server_plant(&"purple")
	plot2.water = 0.7
	items.server_despawn_item(product)
	await _frames(2)
	items.server_give_item(can, player.peer_id)
	can.set(&"charges", 1)
	await _frames(2)
	GameState.server_reset_game()
	await _frames(6)
	_check(plot2.stage == GrowPlot.Stage.EMPTY and plot2.water == 0.0 and plot2.strain_id == &"", "GameState.game_reset clears the grow plots")
	cans = _cans(items)
	var reset_ok := cans.size() == Config.balance.starting_watering_cans
	for c in cans:
		var near := false
		for s in spots:
			near = near or c.global_position.distance_to(s.global_position) < 0.05
		reset_ok = reset_ok and near and not c.is_held() and int(c.get(&"charges")) == GameState.get_can_capacity()
	_check(reset_ok, "GameState.game_reset puts every watering can back at the well, full", "%d cans" % cans.size())
	_finish()

## Plot-local directions (local +Z = the plot's front, towards the gate) of free floor spots EYE_DISTANCE m from
## GrowPlot1 inside the fenced grow area: the aisle in front of the plot column (by the gate) and the aisle
## between the two plot columns, clear of the neighbouring trays. From outside the fence the fence blocks.
const AISLE_SPOTS := {"front aisle": Vector3(2.07, 0.0, 1.4), "middle aisle": Vector3(2.135, 0.0, -1.3)}
const EYE_DISTANCE := 2.5

## Stands the player with its eye EYE_DISTANCE m (horizontally) from the plot along `local_dir`, looks at
## `target` and returns what the real Interactor ray targets now.
func _look_from(player: Player, plot: GrowPlot, local_dir: Vector3, target: Vector3) -> Interactable:
	player.global_position = plot.global_position + plot.global_basis * (local_dir.normalized() * EYE_DISTANCE)
	player.velocity = Vector3.ZERO
	var eye := (player.get_node(^"%Camera") as Camera3D).global_position
	var d := (target - eye).normalized()
	player.rotation.y = atan2(-d.x, -d.z)
	player.head.rotation.x = asin(d.y)
	var interactor := player.get_interactor()
	interactor.refresh()
	return interactor.current_target

func _check_ready_targeting(player: Player, plot: GrowPlot) -> void:
	await get_tree().create_timer(0.5).timeout   # the READY pop-in / bounce settle
	var ready := plot.get_node("Plant/Tilt/Bouncer/Grow/Ready") as Node3D
	var box := AABB()
	var first := true
	for mi: MeshInstance3D in ready.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta(&"toonify_outline") or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b: AABB = plot.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	var xf := plot.global_transform
	var leaf_y := box.position.y + box.size.y * 0.45
	var misses: PackedStringArray = []
	var eye_y := 0.0
	for spot: String in AISLE_SPOTS:
		for what: String in ["cola top", "left leaves", "right leaves"]:
			var local: Vector3 = {"cola top": Vector3(0.0, box.end.y - 0.04, 0.0),
				"left leaves": Vector3(box.position.x + 0.05, leaf_y, 0.0), "right leaves": Vector3(box.end.x - 0.05, leaf_y, 0.0)}[what]
			var got := _look_from(player, plot, AISLE_SPOTS[spot], xf * local)
			eye_y = (player.get_node(^"%Camera") as Camera3D).global_position.y
			if got != plot:
				misses.append("%s, %s -> %s" % [spot, what, got.name if got != null else "nothing"])
	_check(misses.is_empty() and absf(eye_y - 1.6) < 0.05, "real room: the player's Interactor ray (eye %.2f m, %.1f m away, both aisles) targets the READY plant at its top cola (%.2f m) and side leaves" % [
		eye_y, EYE_DISTANCE, box.end.y], ", ".join(misses))

func _check_empty_targeting(player: Player, plot: GrowPlot) -> void:
	for i in 3:
		await get_tree().physics_frame   # the plant hitbox is switched off deferred
	var shape := plot.get_node("Body/PlantShape") as CollisionShape3D
	var xf := plot.global_transform
	var bad: PackedStringArray = []
	for spot: String in AISLE_SPOTS:
		var tray := _look_from(player, plot, AISLE_SPOTS[spot], xf * Vector3(0.0, 0.45, 0.0))
		var above := _look_from(player, plot, AISLE_SPOTS[spot], xf * Vector3(0.0, 1.5, 0.0))
		if tray != plot or above == plot:
			bad.append("%s: tray -> %s, where the cola was -> %s" % [spot, tray.name if tray else "nothing", above.name if above else "nothing"])
	_check(shape.disabled and bad.is_empty(), "real room: an EMPTY plot is targeted by its tray only (plant hitbox off)",
		"disabled %s; %s" % [shape.disabled, ", ".join(bad)])

func _cans(items: ItemManager) -> Array[Item]:
	var out: Array[Item] = []
	for it in items.get_items():
		if it.item_type == Const.ITEM_WATERING_CAN and not it.is_queued_for_deletion():
			out.append(it)
	return out

## Puts the player 1.6 m in front of a station (fronts face local +Z).
func _stand_at(player: Player, station: Node3D) -> void:
	player.global_position = station.global_position + station.global_basis.z * 1.6 + Vector3.UP * 0.05
	player.velocity = Vector3.ZERO

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func _finish() -> void:
	print("farm_world_test: %d passed, %d failed" % [_passed, _failed])
	print("FARM WORLD TEST " + ("OK" if _failed == 0 else "FAILED"))
	Config.growth_speed_override = 1.0
	# Tear the session down the normal way before quitting (quitting with a live world is noisier).
	if Game.world != null:
		Game.return_to_menu()
	await get_tree().create_timer(1.0).timeout
	finished.emit(_failed)

func _check(cond: bool, what: String, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: " + what)
	else:
		_failed += 1
		print("FAIL: " + what + ("   [" + detail + "]" if detail != "" else ""))
