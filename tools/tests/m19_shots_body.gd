extends "res://tools/tests/smoke_base.gd"
## M19 readability screenshots on the REAL renderer (lead tool, not a suite): the five busiest moments at 1280x720.
##   1_raid_final_notice     the raid's sirens on the final notice, two condition chips and a job on the payment panel
##   2_sprinklers_toasts     the sprinklers with three toasts up
##   3_phone_scale           the phone ringing while the scale reads light (staged: the game runs one event at a time,
##                           so the ring is started by hand on top of the scale)
##   4_fog_driveby           a fogged worker (this one) during a drive-by's warning
##   5_report_costs          the shift report with three "what it cost" lines
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m19_shots_body.gd --out=<abs dir> \
##       --port=7976 --mute --no-mic --replay --run=B5VP --event-delay=900
## Without --career-file the record stays in memory (Career never writes in a scripted run). Under --headless it stages
## every moment and saves nothing (a dry run of the staging). The mouse is never captured; a watchdog ends the run after
## 120 s.

const FAKE_PEER := 2

var _out := "user://m19_shots"
var _me: Player
var _shots := true


func _process(_delta: float) -> void:
	if _shots and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m19_shots"
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("m19_shots: watchdog, quitting")
		get_tree().quit(2))
	_shots = DisplayServer.get_name() != "headless"
	if not _shots:
		print("m19_shots: headless: staging every moment, saving nothing (run it without --headless for the pictures)")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	if _shots:
		DirAccess.make_dir_recursive_absolute(_out)
	Config.balance.final_shift_by_team = [1, 1, 1, 1]
	Config.balance.end_round_on_quota_met = false
	Config.lobby_enabled = false
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7976))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	if not _shots:
		get_tree().root.size = Vector2i(1280, 720)
	_me = Game.local_player
	Net.players[FAKE_PEER] = {"name": "Dale", "color": Net.PALETTE[1]}
	var dale: Player = Game.world.server_spawn_player(FAKE_PEER)
	await wait_frames(3)
	if dale != null:
		dale.place_at(Transform3D(Basis.IDENTITY, Vector3(-3.0, 0.05, 10.5)))
	Net.players_changed.emit()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the shift runs")
	Events.set(&"_next_in", -1.0)
	GameState.server_add_money(800 - GameState.money)
	await wait_sec(3.0)   # the GO banner is gone

	step("1: the raid on the final notice, two chips, a job")
	check(GameState.is_final_shift(), "shift 1 is the final notice")
	GameState.server_set_conditions([ShiftConditions.ID_OVERTIME, ShiftConditions.ID_THIN_WALLS])
	GameState.server_set_contract(&"cured")
	check(Events.server_start_scheduled(Events.EVENT_RAID), "the raid's sirens")
	_look(Vector3(-2.0, 0.0, 9.5), Vector3(-2.5, 1.4, 15.0))
	await wait_sec(2.5)
	await _shot("1_raid_final_notice")
	Events.server_end_event()
	await wait_sec(3.2)   # the toasts of that one fade

	step("2: the sprinklers with three toasts")
	check(Events.server_start_scheduled(Events.EVENT_SPRINKLERS), "the sprinklers")
	Game.toast("Job: three cured bundles. $60.", &"info")
	Game.toast("Dale paid the collector $40.", &"info")
	_look(Vector3(-1.0, 0.0, 2.5), Vector3(5.0, 1.0, -1.0))
	await wait_sec(1.2)
	await _shot("2_sprinklers_toasts")
	Events.server_end_event()
	await wait_sec(3.2)

	step("3: the phone rings while the scale reads light (staged)")
	check(Events.server_start_scheduled(Events.EVENT_SCALE), "the scale goes off")
	Events.tick(3.1)   # past its tell: it reads light now
	Events.call(&"_start_phone_ring")
	Game.toast(Story.line("toast_phone"), &"error")
	_look(Vector3(-4.5, 0.0, -3.0), Vector3(-7.75, 1.4, -7.45))
	await wait_sec(1.5)
	await _shot("3_phone_scale")
	Events.call(&"_stop_phone_ring")
	Events.server_end_event()
	await wait_sec(3.2)

	step("4: fogged during a drive-by's warning")
	var spores := Game.world.get_node_or_null(^"Spores") as Spores
	check(spores != null and spores.server_catch(1, false), "this worker breathes the damp")
	check(Events.server_start_scheduled(Events.EVENT_DRIVEBY), "the tyres outside")
	_look(Vector3(0.0, 0.0, 4.0), Vector3(0.0, 1.2, 12.0))
	await wait_sec(1.6)
	await _shot("4_fog_driveby")
	Events.server_end_event()
	spores.server_clear()
	await wait_sec(3.2)

	step("5: the report with three cost lines")
	var points := Game.world.room.get_raid_points()
	var mid: Vector3 = points[2] if points.size() > 2 else Vector3.ZERO
	Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"golden", "amount": 1}, mid + Vector3(1.0, 0.3, 0.0), 0)
	Game.world.items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"purple", "amount": 1}, mid + Vector3(-1.0, 0.3, 0.5), 0)
	for i in 3:
		await get_tree().physics_frame
	check(Events.server_start_event(Events.EVENT_RAID), "a raid")
	Events.server_raid_sweep(2)
	Events.server_end_event()
	check(Events.server_start_event(Events.EVENT_COLLECTION) and Events.server_pay_collector(1), "the collector is paid")
	check(Events.server_start_event(Events.EVENT_PHONE), "the phone")
	Events.tick(Config.balance.phone_sec + 0.1)
	check(Events.server_start_scheduled(Events.EVENT_AUDIT), "an audit")
	Events.tick(8.1)
	Events.server_end_event()
	check(Story.get_shift_cost_lines().size() == 3, "three lines to say (%s)" % [Story.get_shift_cost_lines()])
	GameState.time_left = 0.2
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "the shift ends unpaid")
	await wait_sec(1.5)
	await _shot("5_report_costs")
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
	if not _shots:
		print("m19_shots: (dry run) %s staged" % shot)
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m19_shots: ", ProjectSettings.globalize_path(path))
