extends "res://tools/tests/smoke_base.gd"
## M23 fragile in-game screenshots on the REAL renderer (a capture tool for the lead, not a suite): bruised bundles side by
## side with a clean one, a throw that bruises (the toast), a bruised cured bundle in hand at the chute (the HUD line and
## the prompt), and the hand truck with a clean, a bruised and a badly bruised bag.
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m23_fragile_shots_body.gd --out=<abs dir> \
##       --port=7976 --mute --no-mic --event-delay=900
## Under --headless it stages everything the same way and saves nothing (a dry run: the staging is checked, the shots
## are skipped). The lobby is switched off (the floor is staged directly); the mouse is never captured; a watchdog ends
## the run after 90 s.

const ROW_Z := 3.0
const ROW_X: Array[float] = [-3.6, -2.8, -2.0, -1.2]
## Props of the four bundles in the row: clean, one bruise, two bruises, cured with one bruise.
const ROW_EXTRA: Array[Dictionary] = [{}, {"bruises": 1}, {"bruises": 2}, {"cured": true, "bruises": 1}]
const TRUCK_CARGO := "purple|2|0|0.00;purple|2|0|0.00|1;purple|2|0|0.00|2"

var _out := "user://m23_fragile_shots"
var _me: Player
var _dry := false


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m23_fragile_shots"
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("m23_fragile_shots: watchdog, quitting")
		get_tree().quit(2))
	_dry = DisplayServer.get_name() == "headless"
	if _dry:
		print("m23_fragile_shots: headless, a dry run (staging only, no images); run it without --headless for the shots")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	if not _dry:
		DirAccess.make_dir_recursive_absolute(_out)
	Config.lobby_enabled = false
	await get_tree().process_frame
	Game.start_host("Zay", port_arg(7976))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var items := Game.world.items
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "the shift runs")
	await wait_sec(1.0)

	step("four Purple Haze x2 bundles: clean, bruised, badly bruised, cured and bruised")
	for i in ROW_X.size():
		var props := {"strain_id": "purple", "amount": 2}
		props.merge(ROW_EXTRA[i], true)
		var p := items.server_spawn_item(Const.ITEM_PRODUCT, props, Vector3(ROW_X[i], 0.0, ROW_Z)) as Product
		check(p != null and p.bruises == int(ROW_EXTRA[i].get("bruises", 0)), "bundle %d: '%s'" % [i, p.get_tag_text() if p != null else "-"])
	_look(Vector3(-2.4, 0.0, 5.0), Vector3(-2.4, 0.15, ROW_Z))
	await wait_sec(0.6)
	await _shot("1_bundles_row")
	_look(Vector3(-2.4, 0.0, 4.1), Vector3(-2.4, 0.1, ROW_Z))
	await wait_sec(0.4)
	await _shot("2_bundles_close")

	step("a throw that bruises: the toast, the dust")
	_look(Vector3(-6.0, 0.0, 5.5), Vector3(-6.0, 0.0, 2.5))
	await wait_sec(0.3)
	var thrown := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 2}, Vector3(-6.0, 0.0, 6.5)) as Product
	await wait_frames(2)
	check(thrown != null and items.server_throw_item(thrown, Vector3(-6.0, 1.3, 4.9), Vector3(0.0, -2.0, -5.0), 1), "thrown at the floor")
	await wait_until(func() -> bool: return thrown != null and not thrown.is_flying(), 3.0, "down")
	check(thrown != null and thrown.bruises == 1, "bruised")
	await wait_sec(0.2)
	await _shot("3_thrown_toast")

	step("a bruised cured bundle in hand at the chute")
	var held := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 2, "cured": true, "bruises": 1}, Vector3(0.0, 0.0, 4.0), 1) as Product
	_look(Vector3(0.0, 0.0, 4.4), Vector3(0.0, 0.7, 5.8))
	await wait_sec(0.8)
	var chute := Game.world.room.get_station("TurnInStation") as TurnInStation
	check(held != null and held.holder_id == 1 and chute != null, "in hand: '%s'; the chute says '%s'" % [held.get_label_text() if held != null else "-",
			chute.get_prompt(_me) if chute != null else "-"])
	await _shot("4_held_at_chute")
	items.server_release_holder(1)
	await wait_frames(2)

	step("the hand truck: a clean, a bruised and a badly bruised bag")
	var trucks: Array[Item] = items.get_items_of_type(Const.ITEM_HAND_TRUCK)
	if check(not trucks.is_empty(), "a hand truck stands on the dock"):
		trucks[0].apply_props({"cargo": TRUCK_CARGO})
		_look(Vector3(-7.1, 0.0, 9.9), Vector3(-8.0, 0.5, 8.7))
		await wait_sec(0.6)
		await _shot("5_truck_bags")
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
	if _dry:
		print("m23_fragile_shots: (dry run) %s" % shot)
		return
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m23_fragile_shots: ", ProjectSettings.globalize_path(path))
