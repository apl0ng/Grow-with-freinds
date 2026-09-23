extends SceneTree
## Close-up renders of the modelled room props IN the room (props modeler tool; complements world_preview.gd,
## which frames the gameplay views). Needs a real renderer; under --headless it prints a hint and exits 0.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/models_props_preview.gd -- --out=/tmp/props_preview [--shot=pallets,pipe] [--fov=60]
##
## Sun shadows are off unless --shadows (llvmpipe doubles the lit side with shadows, see world_preview.gd).

const ROOM_SCENE := "res://scenes/world/room.tscn"
## name -> [camera position, look-at target] (Room space)
const VIEWS := {
	"pallets": [Vector3(0.6, 1.6, 4.3), Vector3(2.2, 0.55, 6.8)],
	"drums_south": [Vector3(-0.6, 1.5, 4.9), Vector3(-1.8, 0.5, 6.6)],
	"punch_clock": [Vector3(-1.5, 1.6, 5.7), Vector3(-2.2, 1.45, 7.5)],
	"cot_plant": [Vector3(4.4, 1.7, 5.6), Vector3(7.6, 0.55, 6.9)],
	"cot": [Vector3(9.7, 1.5, 5.3), Vector3(8.2, 0.35, 6.8)],
	"plant": [Vector3(5.7, 1.45, 5.75), Vector3(6.3, 1.05, 6.75)],
	"leaky_pipe": [Vector3(-7.6, 1.7, 3.6), Vector3(-9.9, 1.3, 4.9)],
	"pipe_joint": [Vector3(-8.9, 1.9, 4.4), Vector3(-9.85, 2.1, 4.9)],
	"clock_camera": [Vector3(-3.0, 2.2, -3.2), Vector3(-2.6, 4.2, -7.5)],
	"security_camera": [Vector3(-8.0, 2.4, -5.6), Vector3(-9.6, 4.5, -7.4)],
	"debt_board": [Vector3(-3.4, 1.7, -3.9), Vector3(-4.7, 2.5, -7.5)],
	"drums_north": [Vector3(7.2, 1.6, -4.6), Vector3(8.6, 0.5, -6.9)],
	"crate_north": [Vector3(3.0, 1.6, -4.9), Vector3(4.2, 0.5, -6.9)],
}

var _out := "user://props_preview"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("models_props_preview: needs a real renderer (xvfb-run + --rendering-driver opengl3); skipping")
		quit(0)
		return
	var shots: PackedStringArray = PackedStringArray(VIEWS.keys())
	var shadows := false
	var fov := 62.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--shot="):
			shots = a.trim_prefix("--shot=").split(",")
		elif a.begins_with("--fov="):
			fov = a.trim_prefix("--fov=").to_float()
		elif a == "--shadows":
			shadows = true
	DirAccess.make_dir_recursive_absolute(_out)
	var room := (load(ROOM_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(room)
	var sun := room.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null and not shadows:
		sun.shadow_enabled = false
	var cam := Camera3D.new()
	cam.fov = fov
	root.add_child(cam)
	cam.make_current()
	for shot in shots:
		if not VIEWS.has(shot):
			print("models_props_preview: unknown shot '%s' (have %s)" % [shot, ", ".join(PackedStringArray(VIEWS.keys()))])
			continue
		var v: Array = VIEWS[shot]
		cam.global_position = room.global_transform * (v[0] as Vector3)
		cam.look_at(room.global_transform * (v[1] as Vector3), Vector3.UP)
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := _out.path_join(shot + ".png")
		root.get_texture().get_image().save_png(path)
		print("models_props_preview: ", ProjectSettings.globalize_path(path))
	quit(0)
