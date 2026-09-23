extends SceneTree
## Renders PNG previews of the main menu, the connecting overlay, the players and the first-person view
## (net/player agent tool). Needs a real renderer; under --headless it prints a hint and exits 0.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/net_preview.gd -- --out=/tmp/net_preview
##
## Autoloads are reached through the root (this script compiles before they are registered).

var _out: String = "user://net_preview"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("net_preview: needs a real renderer (xvfb-run + --rendering-driver opengl3); skipping")
		quit(0)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(_out)
	var game: Node = root.get_node("Game")
	var net: Node = root.get_node("Net")

	# 1. Main menu (+ an error status).
	var menu: Node = (load("res://scenes/main_menu/main_menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await _settle(20)
	await _shot("menu")
	menu.call("set_status", "Host disconnected")
	await _settle(4)
	await _shot("menu_status")

	# 2. Connecting overlay over the world.
	var overlay: Node = (load("res://scenes/main_menu/connecting_overlay.tscn") as PackedScene).instantiate()
	root.add_child(overlay)
	overlay.call("set_text", "Connecting to 192.168.1.20:7777")
	await _settle(6)
	await _shot("connecting")
	overlay.free()

	# 3. Host a local world and add three extra (fake remote) players so all four colors show.
	game.call("start_host", "Alice", 7897)
	await _settle(10)
	var world: Node3D = game.get("world")
	var fake: Dictionary = {2: "Bob", 3: "Chloe", 4: "Dmitri"}
	for id: int in fake:
		net.get("players")[id] = {"name": fake[id], "color": net.get("PALETTE")[id - 1]}
		world.call("server_spawn_player", id)
	await _settle(30)
	var hud := world.get_node_or_null("HUD") as CanvasLayer
	if hud != null:
		hud.visible = false
	var players: Array = world.call("get_players")
	# Line the remote players up facing the camera, one crouching, one looking up.
	var i := 0
	for p: Node3D in players:
		if p.name == "1":
			continue
		var pos := Vector3(-1.5 + i * 1.5, 0.0, 0.0)
		p.set("net_position", pos)
		p.set("net_yaw", PI + (i - 1) * 0.35) # facing the camera (+Z), slightly fanned out
		p.set("net_pitch", 0.5 if i == 2 else 0.0)
		p.set("crouching", i == 1)
		p.position = pos
		i += 1
	var cam := Camera3D.new()
	world.add_child(cam)
	cam.position = Vector3(0.0, 1.7, 4.6)
	cam.look_at(Vector3(0.0, 1.0, 0.0))
	cam.current = true
	await _settle(40)
	await _shot("players")
	# Held-item socket check: a small box on each player's item socket.
	for p: Node3D in players:
		var box := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.18, 0.24, 0.12)
		box.mesh = mesh
		(p.call("get_item_socket") as Node3D).add_child(box)
	await _settle(4)
	await _shot("players_holding")

	# 4. First person (local player's camera): own body hidden, held box bottom-right.
	var local: Node3D = game.get("local_player")
	local.global_position = Vector3(0.0, 0.0, 3.2)
	local.rotation.y = 0.0
	(local.get_node("%Camera") as Camera3D).current = true
	await _settle(20)
	await _shot("first_person")
	game.call("return_to_menu", "")
	await _settle(4)
	print("net_preview: wrote PNGs to ", ProjectSettings.globalize_path(_out))
	quit(0)

func _settle(frames: int) -> void:
	for f in frames:
		await process_frame

func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := _out.path_join(shot_name + ".png")
	img.save_png(path)
	print("net_preview: ", path)
