extends "res://tools/tests/smoke_base.gd"
## M17 in-game screenshots on the REAL renderer (lead tool, not a suite): the final notice on the payment panel, the
## hand truck empty, loaded and held, the wall phone ringing, the scale banner at the chute, a worker in the green
## eyeshade, the Boss's half-time look and the PAID IN FULL card. With --board instead: the alley board with the final
## notice line (the lobby on). Shift 1 is made the final notice (final_shift_by_team = 1 for every team size).
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m17_shots_body.gd --out=<abs dir> \
##       --port=7975 --mute --no-mic --replay --run=B5VP --event-delay=900 [--board]
## Without --career-file the record stays in memory (Career never writes in a scripted run). Under --headless it prints
## a hint and exits 0. The mouse is never captured; a watchdog ends the run after 90 s.

const FAKE_PEER := 2
const TRUCK_CARGO := "purple|1|1|0.00;golden|2|0|0.00;budget|1|0|0.00;brick|3|1|0.00"

var _out := "user://m17_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m17_shots"
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("m17_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m17_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	var board_only := Config.has_arg("board")
	Config.balance.final_shift_by_team = [1, 1, 1, 1]
	Config.lobby_enabled = board_only
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7975))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	await wait_sec(1.0)
	check(GameState.get_final_shift() == 1 and GameState.is_final_shift(), "shift 1 is the final notice (%d)" % GameState.get_final_shift())
	if board_only:
		step("the alley board")
		_look(Vector3(1.9, 0.0, 85.3), Vector3(4.94, 2.05, 85.3))
		await wait_sec(0.8)
		await _shot("1_board_final")
		finish()
		return

	step("the final notice")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(3.0, 1.2, -3.0))
	await wait_sec(0.5)
	await _shot("2_waiting_final_notice")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the final notice runs")
	await wait_sec(1.5)
	await _shot("3_playing_final_notice")

	step("the hand truck")
	var trucks: Array[Item] = Game.world.items.get_items_of_type(Const.ITEM_HAND_TRUCK)
	if check(not trucks.is_empty(), "a hand truck stands on the dock"):
		var truck: Item = trucks[0]
		_look(Vector3(-6.4, 0.0, 10.6), Vector3(-8.0, 0.55, 8.65))
		await wait_sec(0.6)
		await _shot("4_truck_empty")
		truck.apply_props({"cargo": TRUCK_CARGO})
		_look(Vector3(-7.1, 0.0, 9.9), Vector3(-8.0, 0.5, 8.7))
		await wait_sec(0.6)
		await _shot("5_truck_loaded")
		_look(Vector3(-2.0, 0.0, 12.5), Vector3(-2.0, 1.0, 4.0))
		Game.world.items.server_give_item(truck, 1)
		_me.head.rotation.x = -0.35
		await wait_sec(0.8)
		await _shot("6_truck_held")
		_look(Vector3(0.9, 0.0, 3.2), Vector3(0.0, 0.7, 5.8))
		await wait_sec(0.6)
		await _shot("7_truck_at_chute")

	step("the scale")
	check(Events.server_start_event(Events.EVENT_SCALE), "the scale reads light")
	await wait_sec(1.2)
	await _shot("8_scale_off")
	Events.server_end_event()
	await wait_sec(0.4)

	step("the phone")
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone rings")
	_look(Vector3(-6.6, 0.0, -5.4), Vector3(-7.75, 1.4, -7.45))
	await wait_sec(1.5)
	await _shot("9_phone_ringing")
	Events.server_end_event()
	await wait_sec(0.4)

	step("the eyeshade")
	Net.players[FAKE_PEER] = {"name": "Dale", "color": Net.PALETTE[1]}
	var dale: Player = Game.world.server_spawn_player(FAKE_PEER)
	await wait_frames(3)
	if check(dale != null, "a second worker"):
		var w := Vector3(-3.0, 0.05, 1.0)
		dale.place_at(Transform3D(Basis(Vector3.UP, PI), w))
		Net.players_changed.emit()
		Net._rpc_hats_sync({FAKE_PEER: "eyeshade"})
		await wait_sec(1.0)
		check(dale.get_hat() == &"eyeshade", "Dale wears the eyeshade")
		_look(w + Vector3(0.45, 0.0, 1.7), w + Vector3(0.0, 1.5, 0.0))
		await wait_sec(0.6)
		await _shot("10_eyeshade")

	step("the half-time look and the clear")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(3.0, 1.2, -3.0))
	var shift_len := float(GameState.get("_final_shift_len"))
	GameState.time_left = shift_len * 0.5 - 0.5
	await wait_sec(1.5)
	await _shot("11_half_time")
	Config.balance.end_round_on_quota_met = true
	GameState.server_add_sale(GameState.quota, 1)
	await wait_sec(2.0)
	check(GameState.is_run_cleared(), "the run is cleared")
	await _shot("12_paid_in_full")
	finish()


## Puts the local player at `pos` (x / z; the height stays) looking at `target` (world space).
func _look(pos: Vector3, target: Vector3) -> void:
	_me.velocity = Vector3.ZERO
	_me.global_position = Vector3(pos.x, _me.global_position.y, pos.z)
	var eye := _me.global_position + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	_me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	_me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


func _shot(shot: String) -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m17_shots: ", ProjectSettings.globalize_path(path))
