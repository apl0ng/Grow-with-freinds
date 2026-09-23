extends SceneTree
## Renders the two character models the way the game builds them (character modeler tool): the real
## scenes/player/player.tscn (model + ToonFace + tint + outline) and scenes/world/shopkeeper_npc.tscn (the Boss,
## rigged glb instanced as Visual), in a studio and/or inside the factory room. Needs a real renderer; under
## --headless it prints a hint and exits 0.
##
##   xvfb-run -a -s "-screen 0 1600x900x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1600x900 \
##       -s res://tools/tests/models_char_preview.gd -- --out=/tmp/shots/chars [--shots=studio,world]
##
## studio: players_front (4 colours), players_side, player_face, player_back, boss_front, boss_34, boss_side,
##         boss_face, boss_cheer, boss_wave, lineup (players + Boss + oil drum at true scale)
## world:  world_counter (2 players at the Boss's cage, player eye height), world_players (3 players + Boss in the
##         back), world_wide
## Autoloads are reached through the root (this script compiles before they are registered).

const PLAYER := "res://scenes/player/player.tscn"
const BOSS := "res://scenes/world/shopkeeper_npc.tscn"
const DRUM := "res://art/models/oil_drum.glb"
const LIGHTING := "res://art/env/toon_lighting.tscn"
const COLORS: Array[Color] = [Color("ff7eb6"), Color("4da8f7"), Color("ffd23f"), Color("33d1b0")]

var _out := "user://models_char_preview"
var _shots: PackedStringArray = ["studio", "world"]
var _stage: Node3D
var _cam: Camera3D


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("models_char_preview: needs a real renderer (xvfb-run + --rendering-driver opengl3); skipping")
		quit(0)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--shots="):
			_shots = a.trim_prefix("--shots=").split(",", false)
	DirAccess.make_dir_recursive_absolute(_out)
	if "studio" in _shots:
		await _studio()
	if "world" in _shots:
		await _world()
	print("models_char_preview: wrote PNGs to ", ProjectSettings.globalize_path(_out))
	quit(0)


# ------------------------------------------------------------------------------------------ studio
func _make_studio() -> void:
	_stage = Node3D.new()
	root.add_child(_stage)
	var lighting := (load(LIGHTING) as PackedScene).instantiate()
	_stage.add_child(lighting)
	var floor_mi := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(30, 0.1, 30)
	floor_mi.mesh = box
	floor_mi.position.y = -0.05
	floor_mi.material_override = Toon.lib(&"concrete")
	_stage.add_child(floor_mi)
	_cam = Camera3D.new()
	_stage.add_child(_cam)
	_cam.current = true


func _player(id: int, color: Color, pos: Vector3, yaw: float, parent: Node) -> Node3D:
	var p := (load(PLAYER) as PackedScene).instantiate() as Node3D
	p.name = str(id)                     # peer id != 1: a remote player (body visible)
	p.set("player_color", color)
	p.set("display_name", ["Alice", "Bob", "Chloe", "Dmitri", "Eve"][id % 5])
	p.position = pos
	p.rotation.y = yaw
	parent.add_child(p)
	return p


func _look(from: Vector3, at: Vector3, fov := 30.0) -> void:
	_cam.fov = fov
	_cam.global_position = from
	_cam.look_at(at)


func _studio() -> void:
	_make_studio()
	var players: Array[Node3D] = []
	for i in 4:
		players.append(_player(i + 2, COLORS[i], Vector3(-1.8 + i * 1.2, 0, 0), PI, _stage))
	await _settle(20)
	_look(Vector3(1.6, 1.5, 6.2), Vector3(0, 0.95, 0), 32.0)
	await _shot("players_front")
	_look(Vector3(-7.0, 1.3, 0.0), Vector3(0, 0.9, 0), 32.0)
	await _shot("players_side")
	_look(Vector3(0.5, 1.45, 2.3), Vector3(-0.6, 1.2, 0), 22.0)
	await _shot("player_face")
	_look(Vector3(-2.4, 1.9, -4.8), Vector3(-0.6, 0.9, 0), 32.0)
	await _shot("player_back")
	# Crouch + look-up + a held box on the item socket (what other players see).
	players[1].set("crouching", true)
	players[2].set("net_pitch", 0.6)
	for p in players:
		var held := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.3, 0.36, 0.12)
		held.mesh = bm
		held.material_override = Toon.lib(&"cream")
		(p.call("get_item_socket") as Node3D).add_child(held)
		p.set("_holding", true)            # no ItemManager here: pose the arms as if an Item were held
		p.set("_hold_check_left", 1e9)
	await _settle(30)
	_look(Vector3(1.6, 1.5, 6.2), Vector3(0, 0.95, 0), 32.0)
	await _shot("players_holding")
	for p in players:
		p.queue_free()
	await _settle(2)

	var boss := (load(BOSS) as PackedScene).instantiate() as Node3D
	boss.set("look_at_players", false)
	boss.set("auto_bark", false)
	_stage.add_child(boss)
	boss.rotation.y = PI                 # the Boss faces -Z: turn him to the camera side (+Z)
	await _settle(20)
	_look(Vector3(0, 1.5, 5.2), Vector3(0, 1.05, 0), 30.0)
	await _shot("boss_front")
	_look(Vector3(3.4, 1.9, 3.8), Vector3(0, 1.05, 0), 30.0)
	await _shot("boss_34")
	_look(Vector3(5.0, 1.3, 0.0), Vector3(0, 1.0, 0), 30.0)
	await _shot("boss_side")
	_look(Vector3(0.5, 1.75, 2.1), Vector3(0, 1.62, 0), 20.0)
	await _shot("boss_face")
	boss.call("cheer")
	await create_timer(0.32).timeout
	_look(Vector3(1.2, 1.7, 3.6), Vector3(0, 1.2, 0), 28.0)
	await _shot("boss_cheer")
	await create_timer(1.6).timeout
	boss.call("wave")
	await create_timer(0.5).timeout
	await _shot("boss_wave")
	await create_timer(1.8).timeout
	# True-scale lineup: players, the Boss and the worked-example oil drum.
	boss.position = Vector3(0.6, 0, 0)
	var lineup: Array[Node3D] = []
	lineup.append(_player(7, COLORS[0], Vector3(-1.4, 0, 0), PI, _stage))
	lineup.append(_player(8, COLORS[1], Vector3(-0.4, 0, 0.1), PI - 0.3, _stage))
	var drum := (load(DRUM) as PackedScene).instantiate() as Node3D
	drum.set("tint", Color(0.31, 0.43, 0.56))
	drum.position = Vector3(1.8, 0, 0.1)
	_stage.add_child(drum)
	await _settle(20)
	_look(Vector3(0.6, 1.6, 7.0), Vector3(0.2, 0.95, 0), 30.0)
	await _shot("lineup")
	_stage.queue_free()
	await _settle(4)


# ------------------------------------------------------------------------------------------ world
func _world() -> void:
	var game: Node = root.get_node("Game")
	var net: Node = root.get_node("Net")
	game.call("start_host", "Alice", 7898)
	await _settle(10)
	var world: Node3D = game.get("world")
	for id: int in [2, 3, 4]:
		net.get("players")[id] = {"name": ["", "", "Bob", "Chloe", "Dmitri"][id], "color": COLORS[id - 1]}
		world.call("server_spawn_player", id)
	await _settle(20)
	var hud := world.get_node_or_null("HUD") as CanvasLayer
	if hud != null:
		hud.visible = false
	var local: Node3D = game.get("local_player")
	var others: Array[Node3D] = []
	for p: Node3D in world.call("get_players"):
		if p != local:
			others.append(p)
	# 1. Two players waiting at the Boss's cage, seen from a third player's eyes a few metres back.
	var spots := [Vector3(-0.75, 0, -2.2), Vector3(0.7, 0, -2.35), Vector3(2.2, 0, -1.2)]
	var yaws := [0.25, -0.35, 0.9]
	for i in others.size():
		_place(others[i], spots[i], yaws[i])
	local.global_position = Vector3(0.6, 0, 1.4)
	local.rotation.y = 0.12
	_cam = local.get_node("%Camera") as Camera3D
	_cam.current = true
	await _settle(40)
	await _shot("world_counter")
	# 2. The players turn round (facing the camera), the Boss glares behind them.
	for i in others.size():
		_place(others[i], [Vector3(-1.0, 0, -1.2), Vector3(0.35, 0, -1.0), Vector3(1.6, 0, -1.5)][i],
				[PI - 0.3, PI + 0.1, PI + 0.5][i])
	local.global_position = Vector3(0.2, 0, 2.6)
	local.rotation.y = 0.0
	(local.get_node("Head") as Node3D).rotation.x = -0.12
	await _settle(40)
	await _shot("world_players")
	# 3. Wide view from the entrance side.
	var wide := Camera3D.new()
	world.add_child(wide)
	wide.fov = 70.0
	wide.global_position = Vector3(4.5, 2.6, 3.5)
	wide.look_at(Vector3(0.0, 1.0, -2.5))
	wide.current = true
	await _settle(10)
	await _shot("world_wide")
	game.call("return_to_menu", "")
	await _settle(4)


func _place(p: Node3D, pos: Vector3, yaw: float) -> void:
	p.set("net_position", pos)
	p.set("net_yaw", yaw)
	p.position = pos
	p.rotation.y = yaw


# ------------------------------------------------------------------------------------------ helpers
func _settle(frames: int) -> void:
	for f in frames:
		await process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := _out.path_join(shot_name + ".png")
	img.save_png(path)
	print("models_char_preview: ", path)
