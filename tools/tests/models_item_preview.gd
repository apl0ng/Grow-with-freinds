extends SceneTree
## Renders the held items (watering can, seed packet, product) the way players see them, in the real world
## scene, to PNG (item modeler tool, see MODELING.md). Needs a real renderer; under --headless it exits 0.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/models_item_preview.gd -- --out=/tmp/shots/items_fp
##
## Options (after --): --out=DIR · --items=watering_can,seed_packet,product · --only=fp,tp,floor
## Shots per item: fp_<item>.png (local %Camera, HUD + crosshair visible, level gaze), fp_<item>_down.png
## (looking down 50 deg, e.g. at a plot), fp_<item>_up.png (looking up 40 deg: near-plane clipping check),
## tp_<item>.png (another player holding it, %BodyHandSocket), plus floor.png (all three on the floor at
## eye level) and floor_close.png.
## Autoloads are reached through the root (this script compiles before they are registered).

const ITEMS: Array[String] = ["watering_can", "seed_packet", "product"]
const PROPS := {
	"watering_can": {"charges": 3},
	"seed_packet": {"strain_id": &"purple"},
	"product": {"strain_id": &"golden", "amount": 2},
}

var _out := "user://models_item_preview"
var _items: Array[String] = ITEMS.duplicate()
var _only: PackedStringArray = ["fp", "tp", "floor"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("models_item_preview: needs a real renderer (xvfb-run + --rendering-driver opengl3); skipping")
		quit(0)
		return
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.substr(6)
		elif a.begins_with("--items="):
			_items.assign(a.substr(8).split(",", false))
		elif a.begins_with("--only="):
			_only = a.substr(7).split(",", false)
	DirAccess.make_dir_recursive_absolute(_out)
	var game: Node = root.get_node("Game")
	var net: Node = root.get_node("Net")
	game.call("start_host", "Alice", 7911)
	await _settle(12)
	var world: Node3D = game.get("world")
	var mgr: Node = world.get("items")
	# A second (fake remote) player to show the %BodyHandSocket pose.
	net.get("players")[2] = {"name": "Bob", "color": net.get("PALETTE")[1]}
	world.call("server_spawn_player", 2)
	await _settle(20)
	var local: Node3D = game.get("local_player")
	var bob: Node3D = game.call("get_player", 2)
	var cam: Camera3D = local.get_node("%Camera")
	var head: Node3D = local.get_node("Head")
	# Stand in the open middle of the room looking towards the grow area (+X), so the background is busy.
	local.call("place_at", Transform3D(Basis(Vector3.UP, -PI / 2.0), Vector3(-0.5, 0.0, 1.2)))
	bob.position = Vector3(1.6, 0.0, -1.2)
	bob.set("net_position", bob.position)
	bob.set("net_yaw", deg_to_rad(-200.0))
	bob.rotation.y = deg_to_rad(-200.0)
	var tp_cam := Camera3D.new()
	tp_cam.fov = 60.0
	world.add_child(tp_cam)

	for item_type in _items:
		for it: Node in (mgr.call("get_items") as Array):
			if int(it.get("holder_id")) != 0:
				mgr.call("server_despawn_item", it)
		await _settle(2)
		var props: Dictionary = PROPS.get(item_type, {})
		mgr.call("server_spawn_item", StringName(item_type), props, Vector3.ZERO, 1)
		mgr.call("server_spawn_item", StringName(item_type), props, Vector3.ZERO, 2)
		await _settle(30) # pop_in finishes
		if "fp" in _only:
			cam.current = true
			for view: Array in [["", -0.12], ["_down", -0.87], ["_up", 0.7]]:
				head.rotation.x = float(view[1])
				local.set("net_pitch", head.rotation.x)
				await _settle(4)
				await _shot("fp_%s%s" % [item_type, view[0]])
			head.rotation.x = -0.12
		if "tp" in _only:
			var socket: Node3D = bob.call("get_item_socket")
			var focus := socket.global_position + Vector3(0, 0.15, 0)
			var front := -bob.global_basis.z
			tp_cam.global_position = focus + front * 1.9 + bob.global_basis.x * 0.9 + Vector3(0, 0.25, 0)
			tp_cam.look_at(focus + Vector3(0, -0.1, 0))
			tp_cam.current = true
			await _settle(4)
			await _shot("tp_%s" % item_type)

	if "floor" in _only:
		for it: Node in (mgr.call("get_items") as Array):
			if int(it.get("holder_id")) != 0:
				mgr.call("server_despawn_item", it)
		await _settle(2)
		var base := Vector3(-3.0, 0.0, 3.2)
		var i := 0
		for item_type in _items:
			mgr.call("server_spawn_item", StringName(item_type), PROPS.get(item_type, {}), base + Vector3(-0.55 + i * 0.55, 0, 0))
			i += 1
		await _settle(30)
		tp_cam.global_position = base + Vector3(0.0, 1.6, 1.9)
		tp_cam.look_at(base + Vector3(0, 0.15, 0))
		tp_cam.current = true
		await _settle(4)
		await _shot("floor")
		tp_cam.fov = 40.0
		tp_cam.global_position = base + Vector3(0.35, 0.75, 1.25)
		tp_cam.look_at(base + Vector3(0, 0.18, 0))
		await _settle(4)
		await _shot("floor_close")
	game.call("return_to_menu", "")
	await _settle(4)
	print("models_item_preview: wrote PNGs to ", ProjectSettings.globalize_path(_out))
	quit(0)


func _settle(frames: int) -> void:
	for f in frames:
		await process_frame


func _shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_viewport().get_texture().get_image()
	var path := _out.path_join(shot_name + ".png")
	img.save_png(path)
	print("models_item_preview: ", path)
