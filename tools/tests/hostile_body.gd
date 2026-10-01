extends "res://tools/tests/qa_base.gd"
## M12 hostile suite (hostile agent): the mutation roll + twitch on a GrowPlot, the hostile plant's ROOT / ROAM / EAT /
## CHASE / BITE / BURNING / DEAD behaviour, fire, hostile_max, despawn_all, the late-join replay RPC, shift end and the
## menu, on a single headless host with fake workers (Net.players + World.server_spawn_player, no owning peer).
## Deterministic where it matters: time is advanced with Hostiles.tick(); the stagger immunity is real time, so the
## second bite waits on the clock.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/hostile_body.gd --port=7955 --round-sec=900
## Every engine/script error fails the run unless announced (qa_base.gd).

const FAR_WEST_A := Vector3(-8.0, 0.0, 3.0)
const FAR_WEST_B := Vector3(-8.0, 0.0, -3.0)
const HOST_PARKING := Vector3(-8.0, 0.05, 6.0)

var _spawned: Array = []   # [id, strain, position]
var _bit: Array = []       # [id, peer]
var _ate: Array = []       # [id, plot]
var _eating: Array = []    # [id, plot]
var _died: Array = []      # [id, by_peer]
var _world: World
var _room: Room
var _strain: SeedDef
var _chance0: float = 0.0


func _run() -> void:
	_label = "hostile"
	await get_tree().process_frame
	Hostiles.hostile_spawned.connect(func(id: int, s: StringName, p: Vector3) -> void: _spawned.append([id, s, p]))
	Hostiles.hostile_bit.connect(func(id: int, peer: int) -> void: _bit.append([id, peer]))
	Hostiles.hostile_ate.connect(func(id: int, plot: int) -> void: _ate.append([id, plot]))
	Hostiles.hostile_eating.connect(func(id: int, plot: int) -> void: _eating.append([id, plot]))
	Hostiles.hostile_died.connect(func(id: int, by: int) -> void: _died.append([id, by]))
	var b: BalanceConfig = Config.balance

	step("idle surface")
	check(Hostiles.count() == 0 and not Hostiles.is_any_alive() and Hostiles.get_hostiles().is_empty(), "menu: no hostiles")
	check(Hostiles.get_hostile(1) == null and Hostiles.nearest_to(Vector3.ZERO) == null, "lookups return null")
	check(Hostiles.server_spawn(&"budget", Vector3.ZERO) == 0, "server_spawn refused without a world (warning only)")
	Hostiles.server_despawn_all()
	Hostiles.server_apply_fire(1, 1.0, 1)
	check(true, "despawn_all / apply_fire are no-ops without a world")

	step("hosting")
	Config.growth_speed_override = 0.0
	Game.start_host("Tester", port_arg(7955))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	check(_world.get_node_or_null(^"Hostiles") != null, "World/Hostiles container exists")
	for id in [2, 3]:
		Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		_world.server_spawn_player(id)
	await wait_frames(3)
	check(_world.get_players().size() == 3, "host + 2 fake workers spawned")
	_put(_world.get_player(2), FAR_WEST_A)
	_put(_world.get_player(3), FAR_WEST_B)
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = HOST_PARKING
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	_strain = b.seeds[0]
	_chance0 = _strain.mutation_chance

	await _test_mutation(b)
	await _test_eat(b)
	await _test_bite(b)
	await _test_fire(b)
	await _test_limits(b)
	await _test_replay(b)
	await _test_shift_end()
	await _test_menu()
	_strain.mutation_chance = _chance0
	finish()


# --- mutation roll + twitch ------------------------------------------------------------------------------------------

func _test_mutation(b: BalanceConfig) -> void:
	step("mutation roll")
	var plot1 := _plot(1)
	_strain.mutation_chance = 0.0
	_make_ready(plot1)
	Hostiles.tick(0.1)
	check(not plot1.turning and not plot1.is_turning() and plot1.get_status_text() == "Ready", "chance 0: a ready plant stays put")
	plot1.server_reset()
	Hostiles.tick(0.01)
	_strain.mutation_chance = 1.0
	_make_ready(plot1)
	Hostiles.tick(0.05)
	check(plot1.turning and plot1.is_turning(), "chance 1: the ready plant turns")
	check(absf(plot1.turn_left - b.mutation_warning_sec) < 0.2, "turn_left starts at mutation_warning_sec (%.2f)" % plot1.turn_left)
	check(plot1.get_status_text() == "Moving", "status reads Moving")
	var prompt := plot1.get_prompt(Game.local_player)
	check(prompt.begins_with("Harvest") and prompt.contains("Moving") and plot1.can_interact(Game.local_player), "prompt: harvest still allowed, says Moving (%s)" % prompt)
	var plant := plot1.get_node(^"%Plant") as Node3D
	await wait_sec(0.3)
	check(plant != null and plant.rotation != Vector3.ZERO, "the plant twitches (rotation jitter %s)" % [plant.rotation if plant != null else null])
	check(Hostiles.count() == 0, "nothing on the floor yet")
	Hostiles.tick(b.mutation_warning_sec - 1.0)
	check(plot1.turning and plot1.turn_left > 0.3 and plot1.turn_left < 1.5, "counting down (%.2f s left)" % plot1.turn_left)
	Hostiles.tick(1.2)
	await wait_frames(1)
	check(plot1.stage == GrowPlot.Stage.EMPTY and plot1.strain_id == &"" and not plot1.turning, "at zero the crop is lost (plot reset, twitch cleared)")
	check(plant != null and plant.rotation == Vector3.ZERO, "the plant stands still again")
	check(Hostiles.count() == 1 and Hostiles.is_any_alive(), "one hostile on the floor")
	check(_spawned.size() == 1 and _spawned[0][1] == _strain.id and (_spawned[0][2] as Vector3).distance_to(plot1.global_position) < 0.1, "hostile_spawned(id, strain, at the tray) %s" % [_spawned])
	if _spawned.is_empty():
		return
	var h := Hostiles.get_hostile(int(_spawned[0][0])) as HostilePlant
	check(h != null, "get_hostile(id) finds it")
	if h == null:
		return
	check(h.id == int(_spawned[0][0]) and h.strain_id == _strain.id, "id + strain on the node")
	check(h.is_in_group(Const.GROUP_HOSTILES) and h.is_in_group(Const.GROUP_NPCS), "groups hostiles + npcs")
	check(h.get_parent() == _world.get_node(^"Hostiles"), "a plain child of World/Hostiles")
	check(h.state == HostilePlant.State.ROOT and h.get_state_name() == "Rooting", "it roots first")
	var body := h.get_node_or_null(^"Body") as StaticBody3D
	check(body != null and body.collision_layer == Const.LAYER_WORLD and body.collision_mask == 0, "StaticBody3D collider on LAYER_WORLD")
	check(h.get_node_or_null(^"Visual") != null and h.get_node_or_null(^"BlobShadow") != null, "Visual + BlobShadow children")
	check(h.global_position.distance_to(plot1.global_position) < 0.1, "stands where the tray was")
	check(Hostiles.nearest_to(plot1.global_position) == h and Hostiles.get_hostiles() == [h], "nearest_to / get_hostiles")

	step("harvest while turning")
	var plot3 := _plot(3)
	_make_ready(plot3)
	Hostiles.tick(0.05)
	check(plot3.turning, "GrowPlot3 turns")
	check(plot3.server_harvest(null), "harvested in time (product on the floor)")
	Hostiles.tick(0.1)
	check(not plot3.turning and plot3.stage == GrowPlot.Stage.EMPTY and Hostiles.count() == 1, "the harvest clears the twitch; no second hostile")
	for it in _world.items.get_items_of_type(Const.ITEM_PRODUCT):
		_world.items.server_despawn_item(it)
	_strain.mutation_chance = _chance0
	await wait_frames(1)


# --- root, roam, eat --------------------------------------------------------------------------------------------------

func _test_eat(b: BalanceConfig) -> void:
	step("root, roam, eat")
	var h := Hostiles.get_hostiles()[0] as HostilePlant
	var plot2 := _plot(2)
	var tray := _plot(1).global_position
	check(plot2.server_plant(_strain.id) and plot2.server_water(1.0), "GrowPlot2 grows")
	plot2.stage_progress = 0.3
	# Real physics ticks between the awaits above add a little ROOT time of their own: the budget below has slack.
	Hostiles.tick(HostilePlant.ROOT_SEC - 0.4)
	check(h.state == HostilePlant.State.ROOT and h.global_position.distance_to(tray) < 0.05, "still rooted just before ROOT_SEC")
	Hostiles.tick(0.5)
	check(h.state == HostilePlant.State.ROAM, "after %.0f s it roams (%s)" % [HostilePlant.ROOT_SEC, h.get_state_name()])
	check(h.get_target_plot() == plot2, "toward the nearest growing tray (GrowPlot2)")
	Hostiles.tick(0.5)
	check(h.global_position.distance_to(tray) > 0.9, "it moves (%.2f m from the tray)" % h.global_position.distance_to(tray))
	Hostiles.tick(1.0)
	check(h.state == HostilePlant.State.EAT, "it reached the tray and eats (%s)" % h.get_state_name())
	check(h.global_position.distance_to(plot2.global_position) < 1.2, "next to GrowPlot2 (%.2f m)" % h.global_position.distance_to(plot2.global_position))
	check(_eating.size() == 1 and _eating[0] == [h.id, 2], "hostile_eating(id, 2) %s" % [_eating])
	check(h.get_target_index() == 2, "get_target_index() = the tray")
	var progress0 := plot2.stage_progress
	Hostiles.tick(1.0)
	check(plot2.is_growing() and plot2.stage_progress < progress0 - 0.05, "eats stage progress (%.2f -> %.2f)" % [progress0, plot2.stage_progress])
	Hostiles.tick(4.0)
	await wait_frames(1)
	check(plot2.stage == GrowPlot.Stage.EMPTY and plot2.strain_id == &"", "at zero the crop is lost")
	check(_ate.size() == 1 and _ate[0] == [h.id, 2], "hostile_ate(id, 2) %s" % [_ate])
	check(h.state == HostilePlant.State.ROAM, "back to roaming")
	Hostiles.tick(1.5)
	check(h.state == HostilePlant.State.ROAM and h.is_inside_tree() and _room.get_bounds().grow(0.1).has_point(h.global_position + Vector3.UP), "wanders inside the room with nothing to eat")


# --- chase, bite, calm --------------------------------------------------------------------------------------------------

func _test_bite(b: BalanceConfig) -> void:
	step("chase and bite")
	var h := Hostiles.get_hostiles()[0] as HostilePlant
	var w2 := _world.get_player(2)
	var can := _world.items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, w2.global_position, 2)
	await wait_frames(1)
	check(can != null and _world.items.get_held_by(2) == can, "worker 2 holds a can")
	_put(w2, h.global_position + Vector3(0.0, 0.0, 2.4))
	Hostiles.tick(0.1)
	check(h.state == HostilePlant.State.CHASE and h.get_target_index() == 2, "a worker within sense range: it chases (%s)" % h.get_state_name())
	var d0 := h.global_position.distance_to(w2.global_position)
	Hostiles.tick(0.4)
	check(h.global_position.distance_to(w2.global_position) < d0 - 0.5, "closing in (%.2f -> %.2f m)" % [d0, h.global_position.distance_to(w2.global_position)])
	await wait_until(func() -> bool: return _bit.size() >= 1, 4.0, "it bites")
	check(_bit.size() >= 1 and _bit[0] == [h.id, 2], "hostile_bit(id, 2) %s" % [_bit])
	check(w2.is_stunned(), "worker 2 is stunned")
	check(_world.items.get_held_by(2) == null and can != null and is_instance_valid(can) and can.holder_id == 0, "the can left his hands")
	check(GameState.get_stat(2, Const.STAT_BITTEN) == 1, "STAT_BITTEN for the victim")
	check(h.state == HostilePlant.State.BITE or h.state == HostilePlant.State.CHASE, "the lunge, then the chase again (%s)" % h.get_state_name())
	await wait_until(func() -> bool: return _bit.size() >= 2, 6.0, "a second bite once the cooldown and the stagger immunity pass")
	check(GameState.get_stat(2, Const.STAT_BITTEN) == 2, "STAT_BITTEN == 2")
	await wait_until(func() -> bool: return h.state == HostilePlant.State.ROAM or h.state == HostilePlant.State.EAT, 3.0, "after two bites it loses interest (%s)" % h.get_state_name())
	_put(w2, h.global_position + Vector3(0.0, 0.0, 1.5))
	Hostiles.tick(1.0)
	check(_bit.size() == 2 and h.state != HostilePlant.State.CHASE, "ignores the worker while calm (%s)" % h.get_state_name())
	_put(w2, FAR_WEST_A)
	if can != null and is_instance_valid(can):
		_world.items.server_despawn_item(can)

	step("back-room workers are not prey")
	var w3 := _world.get_player(3)
	check(GameState.server_send_to_backroom(3, 20.0), "worker 3 sent to the back room")
	await wait_frames(2)
	_put(w3, h.global_position + Vector3(0.0, 0.0, 1.5))
	Hostiles.tick(HostilePlant.CALM_SEC + 0.5)
	check(h.state != HostilePlant.State.CHASE and _bit.size() == 2, "a back-room worker next to it is ignored (%s)" % h.get_state_name())
	GameState.server_release_from_backroom(3)
	await wait_frames(2)
	_put(w3, FAR_WEST_B)


# --- fire -------------------------------------------------------------------------------------------------------------

func _test_fire(b: BalanceConfig) -> void:
	step("fire")
	var h := Hostiles.get_hostiles()[0] as HostilePlant
	var burns0 := GameState.get_stat(1, Const.STAT_BURNS)
	Hostiles.server_apply_fire(h.id, 1.0, 1)
	check(h.state == HostilePlant.State.BURNING and not h.is_dead() and absf(h.get_burn() - 1.0) < 0.001, "1 s of flame: burning, not dead")
	check(Hostiles.is_any_alive(), "still alive")
	Hostiles.tick(HostilePlant.BURN_FLAIL_SEC + 0.1)
	check(h.state != HostilePlant.State.BURNING and not h.is_dead(), "no flame for a moment: it stops flailing (%s)" % h.get_state_name())
	Hostiles.server_apply_fire(h.id, 1.0, 1)
	Hostiles.server_apply_fire(h.id, b.hostile_burn_sec - 2.0 + 0.05, 1)
	await wait_frames(1)
	check(h.is_dead() and h.state == HostilePlant.State.DEAD, "hostile_burn_sec of flame in total: dead")
	check(_died.size() == 1 and _died[0] == [h.id, 1], "hostile_died(id, 1) %s" % [_died])
	check(GameState.get_stat(1, Const.STAT_BURNS) == burns0 + 1, "STAT_BURNS for the shooter")
	check(not Hostiles.is_any_alive() and Hostiles.count() == 1, "not alive; the node stays for the collapse")
	check(Hostiles.nearest_to(h.global_position) == null, "nearest_to skips the dead")
	var shape := h.get_node_or_null(^"Body/Shape") as CollisionShape3D
	await wait_frames(1)
	check(shape != null and shape.disabled, "its collider is off once dead")
	Hostiles.server_apply_fire(h.id, 5.0, 1)
	check(_died.size() == 1 and GameState.get_stat(1, Const.STAT_BURNS) == burns0 + 1, "more flame on a dead one does nothing")
	await wait_until(func() -> bool: return Hostiles.count() == 0, 3.0, "the node is removed after the delay")
	Hostiles.server_apply_fire(999, 1.0, 1)
	check(_died.size() == 1, "fire on an unknown id is ignored")


# --- hostile_max, despawn_all -------------------------------------------------------------------------------------------

func _test_limits(b: BalanceConfig) -> void:
	step("hostile_max")
	var ids: Array[int] = []
	for i in b.hostile_max:
		ids.append(Hostiles.server_spawn(_strain.id, Vector3(0.0 + i * 1.5, 0.0, 2.0)))
	var all_ok := true
	for id in ids:
		if id <= 0:
			all_ok = false
	check(all_ok and Hostiles.count() == b.hostile_max, "spawned hostile_max = %d (%s)" % [b.hostile_max, ids])
	check(Hostiles.server_spawn(_strain.id, Vector3(0.0, 0.0, 3.5)) == 0, "one more is refused")
	check(_spawned.size() == 1 + b.hostile_max, "hostile_spawned per spawn")

	step("despawn_all")
	_died.clear()
	Hostiles.server_despawn_all()
	await wait_frames(1)
	check(Hostiles.count() == 0 and _died.is_empty(), "all gone, no hostile_died credit")
	Hostiles.server_despawn_all()
	check(Hostiles.count() == 0, "idempotent")


# --- late-join replay -------------------------------------------------------------------------------------------------

func _test_replay(b: BalanceConfig) -> void:
	step("late-join replay")
	var other: StringName = b.seeds[1].id if b.seeds.size() > 1 else _strain.id
	var id_a := Hostiles.server_spawn(_strain.id, Vector3(0.0, 0.0, 2.0))
	var id_b := Hostiles.server_spawn(other, Vector3(1.5, 0.0, 2.0))
	check(id_a > 0 and id_b > id_a, "two on the floor (%d, %d)" % [id_a, id_b])
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.5)
	var entries := Hostiles.get_replay_entries()
	check(entries.size() == 2, "two replay entries")
	if entries.size() < 2:
		return
	var e_a: Dictionary = entries[0]
	var pos_a: Vector3 = e_a["pos"]
	var state_a := int(e_a["state"])
	check(int(e_a["id"]) == id_a and e_a["strain"] == _strain.id and state_a == HostilePlant.State.ROAM, "entry: id, strain, state %s" % [e_a])
	_spawned.clear()
	Hostiles.server_despawn_all()
	await wait_frames(1)
	check(Hostiles.count() == 0, "cleared")
	Hostiles._rpc_replay(entries)
	check(Hostiles.count() == 2, "a direct call of the replay RPC recreated both")
	var ra := Hostiles.get_hostile(id_a) as HostilePlant
	var rb := Hostiles.get_hostile(id_b) as HostilePlant
	check(ra != null and rb != null and ra.strain_id == _strain.id and rb.strain_id == other, "same ids and strains")
	check(ra != null and ra.global_position.distance_to(pos_a) < 0.01 and ra.state == state_a, "same pose and state")
	check(_spawned.size() == 2, "hostile_spawned for both")
	Hostiles._rpc_replay(entries)
	check(Hostiles.count() == 2 and _spawned.size() == 2, "replaying the same list again changes nothing")
	Hostiles._rpc_replay([entries[0]])
	await wait_frames(1)
	check(Hostiles.count() == 1 and Hostiles.get_hostile(id_b) == null and Hostiles.get_hostile(id_a) != null, "an entry missing from the list is removed")
	var id_c := Hostiles.server_spawn(_strain.id, Vector3(3.0, 0.0, 2.0))
	check(id_c > id_b, "ids keep counting up after a replay (%d)" % id_c)
	Hostiles.server_despawn_all()
	await wait_frames(1)


# --- shift end / reset / menu ---------------------------------------------------------------------------------------

func _test_shift_end() -> void:
	step("shift end")
	check(Hostiles.server_spawn(_strain.id, Vector3(0.0, 0.0, 2.0)) > 0, "one on the floor before the end")
	_died.clear()
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_frames(1)
	check(Hostiles.count() == 0 and _died.is_empty(), "the shift end despawns every hostile, no credit")

	step("game reset")
	check(Hostiles.server_spawn(_strain.id, Vector3(0.0, 0.0, 2.0)) > 0, "one on the floor between shifts")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "WAITING after retry")
	await wait_frames(1)
	check(Hostiles.count() == 0, "game_reset despawns every hostile")


func _test_menu() -> void:
	step("return to menu")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING again")
	check(Hostiles.server_spawn(_strain.id, Vector3(0.0, 0.0, 2.0)) > 0, "one on the floor before leaving")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "MENU")
	await wait_frames(2)
	check(Hostiles.count() == 0 and Hostiles.get_hostiles().is_empty() and not Hostiles.is_any_alive(), "menu: no world, no hostiles")


# --- helpers --------------------------------------------------------------------------------------------------------

func _plot(i: int) -> GrowPlot:
	return _room.get_station("GrowPlot%d" % i) as GrowPlot


## Plants the test strain and jumps the plot to READY (the host sets synced state directly, like the farm tests).
func _make_ready(p: GrowPlot) -> void:
	p.server_plant(_strain.id)
	p.server_water(1.0)
	p.stage = GrowPlot.Stage.READY


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))
