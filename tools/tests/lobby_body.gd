extends "res://tools/tests/qa_base.gd"
## M14 lobby suite (lobby agent): the alley, the van's head count and countdown, the ride to the floor, the way back
## after a shift (NEXT SHIFT and START OVER), the host's Enter as an override, a worker dropped during the countdown,
## where late joiners land, and the old flow with the lobby off. A single headless host with fake workers
## (Net.players + World.server_spawn_player, no owning peer).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/lobby_body.gd --lobby --port=7966
## With --no-lobby only the old-flow part runs (it also runs after the lobby part, with the switch turned off).
## Every engine/script error fails the run unless announced (qa_base.gd).

const DOCK_TOLERANCE := 1.0
const SPOT_TOLERANCE := 0.35

var _transitions: Array = []   # [kind, seconds, msec]
var _rounds: Array = []        # round numbers of round_started
var _resets: int = 0
var _world: World
var _room: Room
var _lobby: Lobby
var _van: Van
var _hud: HUD
var _port: int = 7966


func _run() -> void:
	_label = "lobby"
	_port = port_arg(7966)
	await get_tree().process_frame
	GameState.transition_started.connect(func(kind: StringName, seconds: float) -> void:
		_transitions.append([kind, seconds, Time.get_ticks_msec()]))
	GameState.round_started.connect(func(n: int) -> void: _rounds.append(n))
	GameState.game_reset.connect(func() -> void: _resets += 1)
	if Config.lobby_enabled:
		if await _host("lobby on"):
			await _test_alley()
			await _test_walk_in()
			await _test_count_and_countdown()
			await _test_ride()
			await _test_next_shift()
			await _test_override()
			await _test_retry()
			await _test_dropped_worker()
			await _test_late_joiner_places()
			await _test_cancel()
	else:
		check(Config.has_arg("no-lobby"), "the lobby is off because --no-lobby was passed (pass --lobby for the whole suite)")
	Config.lobby_enabled = false
	if await _host("lobby off"):
		await _test_old_flow()
		await _leave()
	finish()


func _host(tag: String) -> bool:
	step("hosting (%s)" % tag)
	Config.growth_speed_override = 0.0
	Game.start_host("Tester", _port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "%s: world + local player exist" % tag)
	if Game.world == null or Game.local_player == null:
		return false
	_world = Game.world
	_room = _world.room
	_lobby = _world.lobby
	_van = _lobby.get_van() if _lobby != null else null
	_hud = _world.get_node_or_null(^"HUD") as HUD
	await wait_frames(3)
	return check(_lobby != null and _van != null and _hud != null, "%s: World/Lobby, its van and the HUD exist" % tag)


func _leave() -> void:
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and Game.world == null, 5.0, "back in the menu")


# --- the alley -------------------------------------------------------------------------------------------------------

func _test_alley() -> void:
	step("the alley")
	var me: Player = Game.local_player
	check(GameState.phase == GameState.Phase.WAITING, "phase WAITING")
	check(_lobby.global_position.is_equal_approx(Vector3(0.0, 0.0, 80.0)), "the Lobby node sits at (0, 0, 80)")
	var bounds := _lobby.get_bounds()
	check(bounds.size.is_equal_approx(Lobby.INTERIOR_SIZE) and bounds.get_center().is_equal_approx(Vector3(0.0, 3.0, 80.0)), "get_bounds(): 10 x 6 x 15 m around the node")
	check(not bounds.intersects(_room.get_bounds().grow(20.0)), "the alley is nowhere near the room (20 m margin)")
	check(_lobby.get_spawn_points().size() == 4, "four spawn markers")
	check(_lobby.contains_point(me.global_position) and not _room.get_bounds().has_point(me.global_position), "the host spawned in the alley, not on the floor")
	check(_flat(me.global_position).distance_to(_flat(_lobby.get_spawn_transform(me.spawn_index).origin)) < SPOT_TOLERANCE, "at its alley spawn (index %d)" % me.spawn_index)
	check(_lobby.is_in_use() and _lobby.visible, "the alley is drawn while it is in use")
	var seen: Array[Vector3] = []
	var distinct := true
	for i in 8:
		var o := _lobby.get_spawn_transform(i).origin
		if not _lobby.contains_point(o):
			distinct = false
		for other in seen:
			if _flat(other).distance_to(_flat(o)) < 0.8:
				distinct = false
		seen.append(o)
	check(distinct, "eight spawn transforms: all inside the alley, none within 0.8 m of another")
	check(_lobby.get_spawn_transform(-1).origin.is_finite(), "a negative spawn index is safe")
	# Fake workers who clock in while the game waits land in the alley too.
	for id: int in [2, 3]:
		_add_worker(id)
	await wait_frames(3)
	check(_world.get_players().size() == 3, "host + 2 fake workers")
	for id: int in [2, 3]:
		var p := _world.get_player(id)
		check(p != null and _lobby.contains_point(p.global_position)
				and _flat(p.global_position).distance_to(_flat(_lobby.get_spawn_transform(p.spawn_index).origin)) < SPOT_TOLERANCE,
				"worker %d clocked in during WAITING: alley spawn %d" % [id, p.spawn_index if p != null else -1])
	# Nobody leaves: floor below, brick on four sides up to 13 m, and the van is solid.
	await get_tree().physics_frame
	var centre := _lobby.global_position + Vector3(-2.5, 1.0, 3.0)
	check(not _ray(centre, centre + Vector3.DOWN * 3.0).is_empty(), "a floor under the alley")
	var walls_ok := true
	for dir: Vector3 in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		for h: float in [1.0, 6.5, 13.0]:
			var from := _lobby.global_position + Vector3(-2.5, h, 5.5)
			var hit := _ray(from, from + dir * 20.0)
			if hit.is_empty() or not _lobby.contains_point(Vector3(hit["position"].x, 1.0, hit["position"].z)):
				walls_ok = false
				print("      no wall: dir %s height %.1f -> %s" % [dir, h, hit.get("position", "nothing")])
	check(walls_ok, "walls on all four sides at 1 m, 6.5 m and 13 m")
	# The van.
	check(_lobby.contains_point(_van.global_position), "the van stands in the alley")
	var cargo := _van.get_cargo_aabb()
	check(cargo.size.is_equal_approx(Vector3(1.8, 2.2, 2.8)), "cargo volume 1.8 x 2.2 x 2.8 m (%s)" % cargo.size)
	check(_van.is_in_cargo(_van.get_seat_transform(0).origin) and _van.is_in_cargo(_van.get_seat_transform(3).origin), "seat spots are inside the cargo volume")
	check(not _van.is_in_cargo(_van.get_entry_point()) and not _van.is_in_cargo(me.global_position), "the ground behind the doors and the spawn are not")
	check(not _van.is_in_cargo(Vector3(NAN, 0.0, 0.0)), "a NaN point is nowhere")
	var above := _van.global_transform * Vector3(0.0, 1.6, -0.6)
	var floor_hit := _ray(above, above + Vector3.DOWN * 3.0)
	check(not floor_hit.is_empty() and absf(float(floor_hit["position"].y) - 0.45) < 0.03, "the cargo floor is solid at 0.45 m (%s)" % [floor_hit.get("position", "nothing")])
	var left := _van.get_node_or_null(Van.DOOR_LEFT_PATH) as Node3D
	var right := _van.get_node_or_null(Van.DOOR_RIGHT_PATH) as Node3D
	check(left != null and right != null and _van.get_node_or_null(^"Model/Body") != null, "van.glb: Body, DoorLeft, DoorRight")
	check(left != null and is_zero_approx(left.rotation.y) and not _van.are_doors_shut(), "the rear doors stand open")


## A body with the worker's capsule walks from the ground behind the doors into the back: no jump needed.
func _test_walk_in() -> void:
	step("walking in")
	var probe := CharacterBody3D.new()
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = Player.STAND_HEIGHT
	shape.shape = capsule
	shape.position.y = Player.STAND_HEIGHT * 0.5
	probe.add_child(shape)
	probe.collision_layer = 0
	probe.collision_mask = Const.LAYER_WORLD
	probe.floor_snap_length = 0.2
	_world.add_child(probe)
	probe.global_position = _van.get_entry_point() + Vector3(0.0, 0.05, 0.0)
	var forward := -_van.global_basis.z.normalized()
	var top := 0.0
	for i in 90:
		await get_tree().physics_frame
		var vy := probe.velocity.y - 9.8 / 60.0 if not probe.is_on_floor() else 0.0
		probe.velocity = forward * Config.balance.walk_speed + Vector3.UP * vy
		probe.move_and_slide()
		top = maxf(top, probe.global_position.y)
	var end := probe.global_position
	check(_van.is_in_cargo(end), "a walking body ends up in the back of the van (%s)" % [_van.global_transform.affine_inverse() * end])
	check(absf(end.y - 0.45) < 0.08 and top < 0.6, "standing on the cargo floor, never higher than a step (y %.2f, top %.2f)" % [end.y, top])
	probe.queue_free()
	await wait_frames(2)


# --- head count + countdown ------------------------------------------------------------------------------------------

func _test_count_and_countdown() -> void:
	step("head count")
	var b: BalanceConfig = Config.balance
	var me: Player = Game.local_player
	var w2 := _world.get_player(2)
	var w3 := _world.get_player(3)
	await wait_until(func() -> bool: return _van.total == 3 and _van.occupants == 0, 1.0, "the van counts 0 / 3")
	check(_van.is_lobby_on() and not _van.is_counting() and not _van.is_departing() and _van.countdown_left == -1.0, "lobby on, countdown idle (-1)")
	check(_hud.is_lobby_banner() and _hud.get_lobby_text() == "Everyone in the van. 0 / 3 in.", "HUD: '%s'" % _hud.get_lobby_text())
	check(_hud.banner.visible and _hud.banner_text.text == _hud.get_lobby_text() and not _hud.start_button.visible, "the centre banner shows it (no start button out here)")
	check(_hud.banner_tip.visible and _hud.banner_tip.text.contains("leave without the rest"), "the host's tip names Enter as the way to leave without the rest")
	_put(w2, _van.get_seat_transform(1))
	await wait_until(func() -> bool: return _van.occupants == 1, 1.0, "one worker in: 1 / 3")
	check(_hud.get_lobby_text() == "Everyone in the van. 1 / 3 in.", "HUD: '%s'" % _hud.get_lobby_text())
	_put(w3, _van.get_seat_transform(2))
	await wait_until(func() -> bool: return _van.occupants == 2, 1.0, "two in: 2 / 3")
	await wait_sec(0.6)
	check(not _van.is_counting() and _transitions.is_empty() and GameState.phase == GameState.Phase.WAITING, "no countdown while one worker is still outside")
	step("countdown")
	_put(me, _van.get_seat_transform(0))
	await wait_until(func() -> bool: return _van.is_counting(), 1.0, "everyone in: the countdown runs")
	check(_van.occupants == 3 and _van.is_everyone_in(), "3 / 3")
	check(_van.countdown_left > b.van_countdown_sec - 0.4 and _van.countdown_left <= b.van_countdown_sec, "it starts at van_countdown_sec (%.2f of %.1f)" % [_van.countdown_left, b.van_countdown_sec])
	check(_hud.get_lobby_text() == "Doors closing %d" % ceili(b.van_countdown_sec), "HUD: '%s'" % _hud.get_lobby_text())
	await wait_sec(0.5)
	_put(w3, Transform3D(Basis.IDENTITY, _van.get_entry_point()))
	await wait_until(func() -> bool: return not _van.is_counting(), 0.6, "a worker steps out: the countdown stops within one count")
	check(_van.countdown_left == -1.0 and _van.occupants == 2, "reset to idle, 2 / 3")
	check(_hud.get_lobby_text() == "Everyone in the van. 2 / 3 in.", "HUD: '%s'" % _hud.get_lobby_text())
	await wait_sec(b.van_countdown_sec + 0.3)
	check(GameState.phase == GameState.Phase.WAITING and _transitions.is_empty(), "nothing leaves while one is outside (waited longer than the countdown)")
	_put(w3, _van.get_seat_transform(2))
	await wait_until(func() -> bool: return _van.is_counting(), 1.0, "back in: the countdown runs again")
	check(_van.countdown_left > b.van_countdown_sec - 0.4, "from the top (%.2f)" % _van.countdown_left)


# --- the ride --------------------------------------------------------------------------------------------------------

func _test_ride() -> void:
	step("the ride")
	var b: BalanceConfig = Config.balance
	var t0 := Time.get_ticks_msec()
	await wait_until(func() -> bool: return _transitions.size() == 1, b.van_countdown_sec + 1.0, "at zero: transition_started fires")
	if _transitions.is_empty():
		return
	var waited := (Time.get_ticks_msec() - t0) / 1000.0
	check(waited > b.van_countdown_sec - 0.6 and waited < b.van_countdown_sec + 0.4, "after the countdown (%.2f s)" % waited)
	check(_transitions[0][0] == GameState.TRANSITION_TO_FLOOR and is_equal_approx(float(_transitions[0][1]), b.transition_fade_sec), "kind to_floor, seconds = transition_fade_sec")
	check(GameState.is_transitioning() and GameState.phase == GameState.Phase.WAITING, "the host is in transit, still WAITING")
	check(_van.is_departing() and _hud.get_lobby_text() == "Doors closed.", "the van reads doors closed ('%s')" % _hud.get_lobby_text())
	check(_hud.is_transition_showing() and _van.are_doors_shut(), "the screen starts to fade, the doors swing shut")
	check(Sfx.has_sound(&"van_door"), "van_door is a sound")
	GameState.request_start_round()
	GameState.server_begin_shift_from_lobby()
	GameState.server_return_to_lobby(true)
	check(_transitions.size() == 1, "requests made during a ride are ignored")
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 1.5, "PLAYING")
	var ride := (Time.get_ticks_msec() - int(_transitions[0][2])) / 1000.0
	var expected := b.transition_fade_sec + GameState.TRANSITION_HOLD_SEC * 0.5
	check(ride > expected - 0.1 and ride < expected + 0.45, "the work happens in the dark, %.2f s after the fade began (%.2f)" % [expected, ride])
	check(_hud.get_transition_alpha() > 0.95, "the screen is black when the workers move (alpha %.2f)" % _hud.get_transition_alpha())
	check(not GameState.is_transitioning(), "the ride is over on the host")
	await wait_frames(3)
	_check_all_at_dock("after the ride")
	check(_rounds == [1] and GameState.round_number == 1 and GameState.quota == GameState.get_quota_for(1), "shift 1 started once with its payment (%s)" % [_rounds])
	check(is_equal_approx(GameState.time_left, b.round_length_sec) or GameState.time_left > b.round_length_sec - 1.0, "a full timer")
	check(not _lobby.is_in_use() and not _lobby.visible, "the alley is no longer drawn")
	await wait_until(func() -> bool: return _van.occupants == 0 and _van.countdown_left == -1.0, 1.0, "the van is empty and idle")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")
	check(_hud.get_lobby_text() == "" and not _hud.banner.visible, "no alley banner during a shift")


# --- after a shift -----------------------------------------------------------------------------------------------------

func _test_next_shift() -> void:
	step("next shift: back to the alley")
	var b: BalanceConfig = Config.balance
	var me: Player = Game.local_player
	GameState.server_add_money(500)
	var up: UpgradeDef = b.upgrades[0]
	check(GameState.server_buy_upgrade(up.id, 1) and GameState.get_upgrade_level(up.id) == 1, "a favor bought during the shift")
	var can := find_item(Const.ITEM_WATERING_CAN)
	check(can != null and _world.items.server_give_item(can, 1) and me.get_held_item() == can, "the host carries a watering can")
	var stood := me.global_position
	GameState.server_add_sale(GameState.quota, 1)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 2.0, "payment met: ROUND_SUCCESS")
	var money := GameState.money
	var round_n := GameState.round_number
	var expected_money := money if b.carry_over_money else b.starting_money
	GameState.request_next_round()
	check(_transitions.size() == 2 and _transitions[1][0] == GameState.TRANSITION_TO_LOBBY, "NEXT SHIFT: transition to_lobby")
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "the report stays up while the screen fades")
	GameState.request_next_round()
	check(_transitions.size() == 2, "a second press is ignored")
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "WAITING")
	check(_hud.get_transition_alpha() > 0.95, "black when it happens")
	check(GameState.round_number == round_n + 1, "round number %d (was %d)" % [GameState.round_number, round_n])
	check(GameState.money == expected_money, "cash on hand as the old path leaves it ($%d)" % GameState.money)
	check(GameState.quota == GameState.get_quota_for(round_n + 1) and GameState.round_sales == 0, "the next payment, nothing deposited")
	check(is_equal_approx(GameState.time_left, b.round_length_sec), "a full timer")
	check(GameState.get_upgrade_level(up.id) == 1 and GameState.upgrades.size() == 1, "favors kept")
	check(GameState.stats.is_empty() and GameState.write_ups.is_empty() and GameState.backroom.is_empty(), "a fresh ledger")
	check(_rounds == [1], "no shift started yet")
	await wait_frames(3)
	_check_all_in_alley("after NEXT SHIFT")
	check(can.holder_id == 0 and not _lobby.contains_point(can.global_position) and _flat(can.global_position).distance_to(_flat(stood)) < 3.0,
			"what the host carried stayed on the floor where they stood (%s)" % can.global_position)
	check(_lobby.is_in_use() and _lobby.visible and not _van.are_doors_shut(), "the alley is drawn again, the doors are open")
	await wait_until(func() -> bool: return _hud.get_lobby_text() == "Everyone in the van. 0 / 3 in.", 1.0, "HUD: 0 / 3 in")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_override() -> void:
	step("the host's Enter")
	var b: BalanceConfig = Config.balance
	_put(_world.get_player(2), _van.get_seat_transform(1))
	await wait_until(func() -> bool: return _van.occupants == 1, 1.0, "one worker in the van, two outside")
	GameState.request_start_round()
	check(_transitions.size() == 3 and _transitions[2][0] == GameState.TRANSITION_TO_FLOOR, "request_start_round: transition to_floor without the stragglers")
	await wait_until(func() -> bool: return _van.is_departing(), 0.5, "the van reads doors closed")
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 1.5, "PLAYING")
	await wait_frames(3)
	_check_all_at_dock("after the override")
	check(_rounds == [1, 2] and GameState.round_number == 2 and GameState.quota == GameState.get_quota_for(2), "shift 2 with its payment (%s)" % [_rounds])
	check(GameState.round_sales == 0 and GameState.time_left > b.round_length_sec - 1.0, "nothing deposited, a full timer")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_retry() -> void:
	step("start over: back to the alley")
	var b: BalanceConfig = Config.balance
	GameState.time_left = 0.01
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 2.0, "payment missed: ROUND_FAILED")
	GameState.request_next_round()
	check(_transitions.size() == 3, "NEXT SHIFT does nothing after a missed payment")
	var resets := _resets
	GameState.request_retry()
	check(_transitions.size() == 4 and _transitions[3][0] == GameState.TRANSITION_TO_LOBBY, "START OVER: transition to_lobby")
	check(GameState.phase == GameState.Phase.ROUND_FAILED and _resets == resets, "the reset waits for the dark")
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 1.5, "WAITING")
	check(_resets == resets + 1, "game_reset emitted once")
	check(GameState.round_number == 1 and GameState.money == b.starting_money and GameState.upgrades.is_empty(), "round 1, starting money, no favors")
	check(GameState.quota == GameState.get_quota_for(1) and GameState.round_sales == 0 and is_equal_approx(GameState.time_left, b.round_length_sec), "payment of shift 1, a full timer")
	await wait_frames(3)
	_check_all_in_alley("after START OVER")
	await wait_until(func() -> bool: return _hud.get_lobby_text() == "Everyone in the van. 0 / 3 in.", 1.0, "HUD: 0 / 3 in")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_dropped_worker() -> void:
	step("a worker drops out during the countdown")
	var b: BalanceConfig = Config.balance
	_put(Game.local_player, _van.get_seat_transform(0))
	_put(_world.get_player(2), _van.get_seat_transform(1))
	_put(_world.get_player(3), _van.get_seat_transform(2))
	await wait_until(func() -> bool: return _van.is_counting() and _van.total == 3, 1.5, "three in, the countdown runs")
	await wait_sec(0.4)
	var left_before := _van.countdown_left
	var n := _transitions.size()
	Net.players.erase(3)
	Net.players_changed.emit()
	_world.server_despawn_player(3)
	Net.peer_left.emit(3)
	await wait_until(func() -> bool: return _van.total == 2, 0.6, "the one who left is no longer counted")
	check(_van.occupants == 2 and _van.is_counting(), "2 / 2, still counting")
	check(_van.countdown_left <= left_before and _van.countdown_left > 0.0, "the countdown went on (%.2f -> %.2f)" % [left_before, _van.countdown_left])
	await wait_until(func() -> bool: return _transitions.size() == n + 1, b.van_countdown_sec + 0.5, "the van leaves with the two who stayed")
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 1.5, "PLAYING")
	await wait_frames(3)
	_check_all_at_dock("the two who stayed")
	check(_world.get_players().size() == 2 and GameState.quota == GameState.get_quota_for(1), "two workers, the payment priced for two")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), b.transition_fade_sec + 1.5, "the screen fades back in")


func _test_late_joiner_places() -> void:
	step("where a late joiner lands")
	_add_worker(4)
	await wait_frames(3)
	var p := _world.get_player(4)
	check(p != null and not _lobby.contains_point(p.global_position), "a worker who joins during a shift is not put in the alley")
	check(p != null and _flat(p.global_position).distance_to(_flat(_room.get_arrival_transform(p.spawn_index).origin)) < SPOT_TOLERANCE, "they land at the dock arrival of their index")


func _test_cancel() -> void:
	step("back to the menu during a ride")
	GameState.request_retry()
	check(GameState.is_transitioning(), "a ride is under way")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and Game.world == null, 5.0, "menu")
	check(not GameState.is_transitioning(), "the ride was cancelled with the session")
	await wait_sec(Config.balance.transition_fade_sec + 0.5)
	check(GameState.phase == GameState.Phase.MENU and not GameState.is_transitioning(), "its timer fired into nothing")


# --- lobby off -------------------------------------------------------------------------------------------------------

func _test_old_flow() -> void:
	step("lobby off: the old flow")
	var b: BalanceConfig = Config.balance
	var me: Player = Game.local_player
	var n := _transitions.size()
	check(not Config.lobby_enabled and GameState.phase == GameState.Phase.WAITING, "lobby off, WAITING")
	check(_room.get_bounds().has_point(me.global_position) and not _lobby.contains_point(me.global_position), "the host spawned on the floor")
	check(_flat(me.global_position).distance_to(_flat(_room.get_spawn_transform(me.spawn_index).origin)) < SPOT_TOLERANCE, "at its room spawn")
	check(not _lobby.is_in_use() and not _lobby.visible, "the alley is not drawn")
	_add_worker(2)
	await wait_frames(3)
	var w2 := _world.get_player(2)
	check(w2 != null and _flat(w2.global_position).distance_to(_flat(_room.get_spawn_transform(w2.spawn_index).origin)) < SPOT_TOLERANCE, "a worker who clocks in spawns on the floor")
	check(not _hud.is_lobby_banner() and _hud.get_lobby_text() == "", "no alley banner")
	check(_hud.banner_title.text == HUD.TEXT_WAIT_HOST_TITLE and _hud.start_button.visible, "the banner is the old one (CLOCK IN + the start button)")
	# Even a worker standing in the van counts for nothing.
	_put(w2, _van.get_seat_transform(0))
	await wait_sec(0.7)
	check(_van.total == 0 and _van.occupants == 0 and _van.countdown_left == -1.0 and not _van.is_lobby_on(), "the van counts nobody")
	check(GameState.phase == GameState.Phase.WAITING, "still WAITING")
	_put(w2, _room.get_spawn_transform(w2.spawn_index))
	var host_pos := me.global_position
	GameState.request_start_round()
	check(GameState.is_playing() and _transitions.size() == n and not GameState.is_transitioning(), "Enter starts the shift at once, no ride")
	await wait_frames(3)
	check(me.global_position.distance_to(host_pos) < 0.3 and not _hud.is_transition_showing(), "nobody is moved, nothing fades")
	_add_worker(5)
	await wait_frames(3)
	var w5 := _world.get_player(5)
	check(w5 != null and _flat(w5.global_position).distance_to(_flat(_room.get_spawn_transform(w5.spawn_index).origin)) < SPOT_TOLERANCE, "a late joiner spawns at a room spawn")
	GameState.server_add_sale(GameState.quota, 1)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "ROUND_SUCCESS")
	var money := GameState.money
	GameState.request_next_round()
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.money == (money if b.carry_over_money else b.starting_money), "NEXT SHIFT: shift 2 at once")
	GameState.time_left = 0.01
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 2.0, "ROUND_FAILED")
	GameState.request_retry()
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == b.starting_money, "START OVER: WAITING, round 1, at once")
	await wait_frames(3)
	check(_transitions.size() == n and _room.get_bounds().has_point(me.global_position), "no ride at all, the host never left the floor")


# --- helpers -----------------------------------------------------------------------------------------------------------

func _add_worker(id: int) -> void:
	Net.players[id] = {"name": "Worker %d" % id, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	Net.players_changed.emit()
	_world.server_spawn_player(id)


## Puts a body somewhere: the local one moves itself (owner-authoritative), a body nobody owns is placed.
func _put(p: Player, xf: Transform3D) -> void:
	if p == null:
		return
	if p.is_local():
		p.velocity = Vector3.ZERO
		p.global_position = xf.origin
	else:
		p.place_at(xf)


func _check_all_at_dock(tag: String) -> void:
	for p in _world.get_players():
		var want := _room.get_arrival_transform(p.spawn_index).origin
		check(_flat(p.global_position).distance_to(_flat(want)) < DOCK_TOLERANCE and not _lobby.contains_point(p.global_position),
				"%s: worker %d stands at dock arrival %d" % [tag, p.peer_id, p.spawn_index])


func _check_all_in_alley(tag: String) -> void:
	for p in _world.get_players():
		var want := _lobby.get_spawn_transform(p.spawn_index).origin
		check(_flat(p.global_position).distance_to(_flat(want)) < SPOT_TOLERANCE and _lobby.contains_point(p.global_position),
				"%s: worker %d is back at alley spawn %d" % [tag, p.peer_id, p.spawn_index])


func _ray(from: Vector3, to: Vector3) -> Dictionary:
	var query := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD)
	return _world.get_world_3d().direct_space_state.intersect_ray(query)


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
