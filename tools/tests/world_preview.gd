extends SceneTree
## Renders the room from the key gameplay viewpoints to PNG (world/level agent tool). Needs a real renderer;
## under --headless it prints a hint and exits 0.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility --resolution 1280x720 \
##       -s res://tools/tests/world_preview.gd -- --out=/tmp/world_preview [--shot=spawn_north,east_plots] [--shadows]
##
## Note: the preview uses the Compatibility renderer (llvmpipe), which roughly doubles the lit side of surfaces
## when the sun casts shadows, so sun shadows are off unless --shadows is passed (see art_preview.gd).
## The game itself renders with Forward+.

const ROOM_SCENE := "res://scenes/world/room.tscn"
## name -> [camera position, look-at target] (Room space; eye height ~1.6 m)
const VIEWS := {
	"spawn_north": [Vector3(0.9, 1.6, 0.6), Vector3(0.0, 1.3, -4.0)],
	"spawn_south": [Vector3(0.0, 1.6, 0.0), Vector3(0.0, 1.1, 6.0)],
	"east_plots": [Vector3(-0.5, 1.6, 1.0), Vector3(5.0, 0.6, 0.0)],
	"west_well": [Vector3(0.5, 1.6, 0.5), Vector3(-6.0, 0.9, 0.0)],
	"shop_close": [Vector3(0.0, 1.7, -2.3), Vector3(0.0, 1.45, -5.0)],
	"overview_sw": [Vector3(-7.4, 3.7, 5.6), Vector3(0.5, 0.0, -1.0)],
	"overview_ne": [Vector3(7.4, 3.7, -5.6), Vector3(-1.0, 0.0, 1.0)],
}

var _out := "user://world_preview"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("world_preview: needs a real renderer (run it under xvfb-run with --rendering-driver opengl3); skipping")
		quit(0)
		return
	var shots: PackedStringArray = PackedStringArray(VIEWS.keys())
	var shadows := false
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--shot="):
			shots = a.trim_prefix("--shot=").split(",")
		elif a == "--shadows":
			shadows = true
	DirAccess.make_dir_recursive_absolute(_out)
	var room := (load(ROOM_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(room)
	var sun := room.get_node_or_null("Sun") as DirectionalLight3D
	if sun != null and not shadows:
		sun.shadow_enabled = false
	var cam := Camera3D.new()
	cam.fov = 75.0
	root.add_child(cam)
	cam.make_current()
	for shot in shots:
		if not VIEWS.has(shot):
			print("world_preview: unknown shot '%s' (have %s)" % [shot, ", ".join(PackedStringArray(VIEWS.keys()))])
			continue
		var v: Array = VIEWS[shot]
		cam.global_position = room.global_transform * (v[0] as Vector3)
		cam.look_at(room.global_transform * (v[1] as Vector3), Vector3.UP)
		for i in 6:
			await process_frame
		await RenderingServer.frame_post_draw
		var path := _out.path_join(shot + ".png")
		root.get_texture().get_image().save_png(path)
		print("world_preview: ", ProjectSettings.globalize_path(path))
	quit(0)
