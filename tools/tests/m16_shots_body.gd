extends "res://tools/tests/smoke_base.gd"
## M16 in-game screenshots on the REAL renderer (lead tool, not a suite): one cover layout from six fixed viewpoints
## (dock, main room, hall), so the four layouts can be compared side by side, and with --menu the main menu's run row
## in its three states. Run it once per layout with that layout's code:
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m16_shots_body.gd --out=<abs dir> \
##       --port=7974 --mute --no-mic --replay --run=<B5VP | Z6FC | K6AX | R624> [--menu]
## It starts on the floor (the lobby is switched off here) and never starts a shift. Under --headless it prints a
## hint and exits 0. The mouse is never captured; a watchdog ends the run after 60 s. The hats have their own tool
## (m16_hats_shots_body.gd).

## Stand point (x, z) and look-at point per view; the same for every layout.
const VIEWS: Array = [
	["dock_from_passage", Vector3(-5.0, 0.0, 8.8), Vector3(-2.5, 1.0, 14.5)],
	["dock_from_east", Vector3(4.0, 0.0, 13.4), Vector3(-7.0, 0.8, 11.5)],
	["dock_from_west", Vector3(-9.2, 0.0, 9.0), Vector3(1.0, 0.9, 13.6)],
	["main_from_booth", Vector3(1.6, 0.0, -3.6), Vector3(-7.0, 0.7, 5.5)],
	["main_from_tank", Vector3(-8.6, 0.0, -5.6), Vector3(0.0, 0.7, 6.0)],
	["hall_from_door", Vector3(11.4, 0.0, 0.6), Vector3(20.5, 0.8, 0.0)],
]

var _out := "user://m16_shots"
var _me: Player


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m16_shots"
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("m16_shots: watchdog, quitting")
		get_tree().quit(2))
	if DisplayServer.get_name() == "headless":
		print("m16_shots: needs a real renderer (run it without --headless); skipping")
		finish()
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	if Config.has_arg("menu"):
		await _menu_shots()
	Config.lobby_enabled = false
	Game.start_host("Zay", port_arg(7974))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var room: Room = Game.world.room
	await wait_sec(1.0)
	var code := GameState.get_run_code()
	var layout := room.get_cover_layout()
	check(code != "", "the run has a code (%s), cover layout %d" % [code, layout])
	step("layout %d (%s)" % [layout, code])
	for view: Array in VIEWS:
		var stand: Vector3 = view[1]
		if room.is_in_cover(stand, 0.45):
			print("m16_shots: %s stands in cover in layout %d, skipped" % [view[0], layout])
			continue
		_look(stand, view[2])
		await wait_sec(0.5)
		await _shot("layout%d_%s" % [layout, view[0]])
	finish()


## The main menu's run row: blank, a good code, junk.
func _menu_shots() -> void:
	step("the menu's run row")
	var menu := (load("res://scenes/main_menu/main_menu.tscn") as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await wait_sec(0.8)
	await _shot("menu_blank")
	var edit := menu.get_node_or_null(^"%RunEdit") as LineEdit
	if check(edit != null, "the run code field exists"):
		for entry: Array in [["7k2m", "menu_code"], ["hello", "menu_junk"]]:
			edit.text = entry[0]
			edit.text_changed.emit(edit.text)
			await wait_sec(0.4)
			await _shot(entry[1])
	menu.queue_free()
	await wait_sec(0.3)


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
	print("m16_shots: ", ProjectSettings.globalize_path(path))
