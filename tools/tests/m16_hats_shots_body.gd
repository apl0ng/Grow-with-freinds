extends "res://tools/tests/smoke_base.gd"
## M16 hats in-game screenshots on the REAL renderer (lead tool, not a suite): a line-up of workers in the alley,
## one in every issued hat (seven: with the host that is the spawner's limit of eight bodies), then the same row
## back in the stock hard hat, each hat close up from the front and from behind, the row from behind,
## one worker crouched, the locker, its prompt, its door mid-swing, and the pause menu's Record card.
## Needs a window (about 40 s) and the lobby and replay on (the defaults in a windowed run):
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/m16_hats_shots_body.gd --out=<abs dir> \
##       --port=7973 --mute --no-mic --career-file=<abs path of a seeded temp file>
## The workers are host-side bodies without a peer (Net.players + World.server_spawn_player) and their hats come
## through the real list (Net._rpc_hats_sync on the host), so what is drawn is what a client would draw. The locker
## prompt and the Record card read the record: without --career-file it is empty ("Locker · nothing issued", no
## issued line) and nothing is written (Career keeps a scripted run in memory); NEVER point it at the real
## user://career.cfg. Under --headless it walks through everything without saving a picture (a dry run for the
## agents, who may not open a window). The mouse is never captured; a watchdog ends the run after 120 s.

## The row, in the alley's own space: under the street lamp, facing south (towards the camera).
const ROW_Z: float = 1.5
const ROW_X0: float = -3.4
const ROW_STEP: float = 1.0
const FIRST_PEER: int = 2
## World's player spawner takes eight bodies, the host's included.
const MAX_BODIES: int = 7

var _out := "user://m16_hats_shots"
var _me: Player
var _dry: bool = false


func _process(_delta: float) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "m16_hats_shots"
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("m16_hats_shots: watchdog, quitting")
		get_tree().quit(2))
	_dry = DisplayServer.get_name() == "headless"
	if _dry:
		print("m16_hats_shots: no renderer under --headless: a dry run, no pictures")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
	if not _dry:
		DirAccess.make_dir_recursive_absolute(_out)
	await get_tree().process_frame
	Config.lobby_enabled = true
	Config.replay_enabled = true
	Game.start_host("Zay", port_arg(7973))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player")
	if Game.world == null:
		finish()
		return
	_me = Game.local_player
	var world: World = Game.world
	var lobby: Lobby = world.lobby
	if not check(lobby != null and lobby.get_locker() != null, "the alley and its locker exist"):
		finish()
		return
	var hud := world.get_node("HUD") as HUD
	var origin := lobby.global_position
	await wait_sec(1.0)

	step("the line-up")
	var wear: Array[StringName] = Hats.ids().slice(0, MAX_BODIES)
	var list := {}
	var spots: Array[Vector3] = []
	for i in wear.size():
		var peer := FIRST_PEER + i
		Net.players[peer] = {"name": Hats.display_name(wear[i]), "color": Net.PALETTE[i % Net.PALETTE.size()]}
		var body := world.server_spawn_player(peer)
		var at := origin + Vector3(ROW_X0 + ROW_STEP * i, 0.05, ROW_Z)
		spots.append(at)
		body.place_at(Transform3D(Basis(Vector3.UP, PI), at))
		list[peer] = String(wear[i])
	Net.players_changed.emit()
	Net._rpc_hats_sync(list)
	await wait_sec(1.0)
	var worn := 0
	for i in wear.size():
		if world.get_player(FIRST_PEER + i).get_hat() == wear[i]:
			worn += 1
	check(worn == wear.size(), "%d workers stand in a row, each in its hat" % wear.size())
	_look(origin + Vector3(0.1, 0.0, ROW_Z + 4.3), origin + Vector3(0.1, 1.2, ROW_Z))
	await _shot("1_row_front")
	_look(origin + Vector3(-2.2, 0.0, ROW_Z - 3.4), origin + Vector3(0.1, 1.3, ROW_Z)) # west of the van
	await _shot("2_row_back")

	step("each hat close up")
	for i in wear.size():
		var tag := String(wear[i])
		_look(spots[i] + Vector3(0.45, 0.0, 1.7), spots[i] + Vector3(0.0, 1.5, 0.0))
		await _shot("3_%d_%s_front" % [i, tag])
		_look(spots[i] + Vector3(-0.5, 0.0, -1.6), spots[i] + Vector3(0.0, 1.55, 0.0)) # behind the row: nobody stands there
		await _shot("4_%d_%s_back" % [i, tag])

	step("a crouch")
	var croucher := world.get_player(FIRST_PEER + 4)
	croucher.crouching = true
	_look(spots[4] + Vector3(0.6, 0.0, 2.0), spots[4] + Vector3(0.0, 1.1, 0.0))
	await wait_sec(0.6)
	await _shot("5_crouched")
	croucher.crouching = false

	step("the stock hard hat")
	Net._rpc_hats_sync({})
	_look(origin + Vector3(0.1, 0.0, ROW_Z + 4.3), origin + Vector3(0.1, 1.2, ROW_Z))
	await _shot("5_row_stock")
	Net._rpc_hats_sync(list)

	step("the locker")
	var locker := lobby.get_locker()
	var at_locker := locker.global_position
	_look(at_locker + Vector3(2.2, 0.0, -1.2), at_locker + Vector3(0.0, 1.0, 0.0)) # north of the row, the lamp's pole to the right
	await _shot("6_locker")
	_look(at_locker + Vector3(1.5, 0.0, 0.0), at_locker + Vector3(0.0, 1.15, 0.0))
	await wait_sec(0.4)
	await _shot("7_locker_prompt")
	if locker.can_interact(_me):
		locker.interact(_me)
		await wait_sec(0.1)
		await _shot("8_locker_door")
		await wait_sec(0.5)
		await _shot("9_locker_prompt_after")
	else:
		print("m16_hats_shots: the record has issued nothing (no --career-file?): the locker stays shut")

	step("the Record card")
	hud.pause_menu.open()
	await wait_sec(0.8)
	await _shot("10_pause_record")
	hud.pause_menu.close()
	await wait_sec(0.3)
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
	await wait_sec(0.5)
	await get_tree().process_frame
	if _dry:
		print("m16_hats_shots: (dry) %s from %s" % [shot, _me.global_position])
		return
	await RenderingServer.frame_post_draw
	var path := _out.path_join(shot + ".png")
	get_viewport().get_texture().get_image().save_png(path)
	print("m16_hats_shots: ", ProjectSettings.globalize_path(path))
