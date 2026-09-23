extends SceneTree
## Renders the modelled cannabis plant in its real context (plant modeler tool; needs a renderer, so xvfb):
## scenes/stations/grow_plot.tscn instances (tray, soil, tag card, PlantVisual) in every stage, strain and dry
## state, and the six plots of the real room. Under --headless it prints a hint and exits 0.
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/models_plant_preview.gd -- --out=/tmp/shots/plant_ctx [--shot=stages,dry,...]
## Shots (default: all):
##   stages    EMPTY + the 4 stages watered, one strain, seen from further back (row overview)
##   eye       each stage (watered, then dry) alone, 3 m away at the player's eye height (1.6 m), game fov 80
##   dry       seedling / vegetative / flowering: watered next to dry
##   strains   flowering and READY in every strain of data/balance.tres
##   close     one close-up per stage (and dry), 1.7 m from the plot at eye height
##   room      the real room: the six plots at different stages / strains / dry, from two viewpoints
## Plots are driven through their synced properties (strain_id, stage, stage_progress, water), exactly like
## the network does, so this also exercises PlantVisual.

const PLOT := "res://scenes/stations/grow_plot.tscn"
const ROOM := "res://scenes/world/room.tscn"
const LIGHTING := "res://art/env/toon_lighting.tscn"
const STRAINS: Array[StringName] = [&"budget", &"purple", &"golden"]
const STAGE_NAMES: Array[String] = ["empty", "seedling", "vegetative", "flowering", "ready"]

var _out := "user://plant_preview"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("models_plant_preview: needs a real renderer (run it under xvfb-run with --rendering-driver opengl3); skipping")
		quit(0)
		return
	var shots := PackedStringArray(["stages", "eye", "dry", "strains", "close", "room"])
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--shot="):
			shots = a.trim_prefix("--shot=").split(",", false)
	DirAccess.make_dir_recursive_absolute(_out)
	await process_frame # autoloads are in the tree from here on
	for shot in shots:
		match shot:
			"stages":
				await _row("stages", [[0, &"purple", 1.0], [1, &"purple", 1.0], [2, &"purple", 1.0],
						[3, &"purple", 1.0], [4, &"purple", 1.0]])
			"eye":
				for st in range(1, 5):
					await _eye(st, &"purple", 1.0, "eye_%s" % STAGE_NAMES[st])
					if st < 4:
						await _eye(st, &"purple", 0.0, "eye_%s_dry" % STAGE_NAMES[st])
			"dry":
				await _row("dry", [[1, &"budget", 1.0], [1, &"budget", 0.0], [2, &"budget", 1.0], [2, &"budget", 0.0],
						[3, &"budget", 1.0], [3, &"budget", 0.0]])
			"strains":
				var specs: Array = []
				for st in [3, 4]:
					for s in STRAINS:
						specs.append([st, s, 1.0])
				await _row("strains", specs)
			"close":
				for st in range(1, 5):
					await _close(st, &"purple", 1.0, "close_%s" % STAGE_NAMES[st])
					if st < 4:
						await _close(st, &"purple", 0.0, "close_%s_dry" % STAGE_NAMES[st])
				await _close(3, &"budget", 1.0, "close_flowering_budget", -0.35)
				await _close(4, &"golden", 1.0, "close_ready_golden", 0.35)
				await _close(4, &"budget", 1.0, "close_ready_budget", -0.35)
			"room":
				await _room()
			_:
				print("models_plant_preview: unknown shot '%s'" % shot)
	quit(0)


# ------------------------------------------------------------------------------------------ helpers
func _stage_world() -> Node3D:
	var world := Node3D.new()
	root.add_child(world)
	var lighting := (load(LIGHTING) as PackedScene).instantiate()
	world.add_child(lighting)
	var sun := lighting.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = false # llvmpipe doubles the lit side with shadows (see world_preview.gd)
	var floor_mesh := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor_mesh.mesh = pm
	floor_mesh.material_override = load("res://art/materials/toon_concrete.tres") as Material
	world.add_child(floor_mesh)
	return world


func _plot(parent: Node3D, pos: Vector3, stage: int, strain: StringName, water: float, yaw := 0.0) -> Node3D:
	var plot := (load(PLOT) as PackedScene).instantiate() as Node3D
	plot.position = pos
	plot.rotation.y = yaw
	parent.add_child(plot)
	if stage > 0:
		plot.set(&"strain_id", strain)
	plot.set(&"stage", stage)
	plot.set(&"stage_progress", 1.0 if stage < 4 else 0.0)
	plot.set(&"water", water)
	return plot


func _camera(parent: Node3D, from: Vector3, at: Vector3, fov := 80.0) -> Camera3D:
	var cam := Camera3D.new()
	cam.fov = fov
	cam.near = 0.05
	parent.add_child(cam)
	cam.global_position = from
	cam.look_at(at, Vector3.UP)
	cam.make_current()
	return cam


func _snap(name: String, settle := 40) -> void:
	for i in settle: # pop_in / tilt tweens settle (~0.5 s at 60 fps)
		await process_frame
	await RenderingServer.frame_post_draw
	var path := _out.path_join(name + ".png")
	root.get_texture().get_image().save_png(path)
	print("models_plant_preview: ", ProjectSettings.globalize_path(path))


func _free(n: Node) -> void:
	n.queue_free()
	await process_frame
	await process_frame


# ------------------------------------------------------------------------------------------ shots
## A row of plots (spec = [stage, strain, water]) seen from the player's eye height.
func _row(name: String, specs: Array) -> void:
	var world := _stage_world()
	var gap := 1.75
	var x0 := -gap * (specs.size() - 1) * 0.5
	for i in specs.size():
		var sp: Array = specs[i]
		_plot(world, Vector3(x0 + gap * i, 0, 0), int(sp[0]), sp[1], float(sp[2]))
	var dist := 2.2 + gap * specs.size() * 0.42
	_camera(world, Vector3(0, 1.6, dist), Vector3(0, 0.75, 0), 60.0)
	await _snap(name)
	await _free(world)


func _close(stage: int, strain: StringName, water: float, name: String, side := 0.0) -> void:
	var world := _stage_world()
	_plot(world, Vector3.ZERO, stage, strain, water)
	var h := [0.0, 0.25, 0.6, 0.85, 1.0][stage] as float
	_camera(world, Vector3(side * 1.7, 1.6, 1.7), Vector3(0, 0.45 + h * 0.5, 0), 60.0)
	await _snap(name)
	await _free(world)


## One plot 3 m in front of the player's eye (1.6 m high), the game camera's fov: the readability check.
func _eye(stage: int, strain: StringName, water: float, name: String) -> void:
	var world := _stage_world()
	_plot(world, Vector3.ZERO, stage, strain, water)
	_camera(world, Vector3(0.6, 1.6, 2.94), Vector3(0, 0.75, 0), 80.0)
	await _snap(name)
	await _free(world)


func _room() -> void:
	var room := (load(ROOM) as PackedScene).instantiate() as Node3D
	root.add_child(room)
	var sun := room.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null:
		sun.shadow_enabled = false
	await process_frame
	# stage, strain, water: every stage, three strains, dry and watered
	var states := [[4, &"purple", 0.6], [3, &"golden", 0.8], [2, &"budget", 0.0], [4, &"budget", 0.5],
			[1, &"golden", 0.0], [3, &"purple", 0.0]]
	for i in 6:
		var plot := room.get_node_or_null("Stations/GrowPlot%d" % (i + 1)) as Node3D
		if plot == null:
			print("models_plant_preview: no Stations/GrowPlot%d in the room" % (i + 1))
			continue
		var sp: Array = states[i]
		plot.set(&"strain_id", sp[1])
		plot.set(&"stage", sp[0])
		plot.set(&"stage_progress", 0.9 if int(sp[0]) < 4 else 0.0)
		plot.set(&"water", sp[2])
	var cam := Camera3D.new()
	cam.fov = 80.0
	room.add_child(cam)
	cam.make_current()
	for view in [["room_plots", Vector3(1.6, 1.6, 0.6), Vector3(6.4, 0.7, 0.0)],
			["room_plots_close", Vector3(3.4, 1.6, -1.2), Vector3(6.3, 0.8, 0.9)],
			["room_overview", Vector3(-3.0, 3.2, 5.5), Vector3(6.0, 0.4, 0.0)]]:
		cam.global_position = room.global_transform * (view[1] as Vector3)
		cam.look_at(room.global_transform * (view[2] as Vector3), Vector3.UP)
		await _snap(view[0], 20)
	await _free(room)
