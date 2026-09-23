extends SceneTree
## Renders Blender-authored models (res://art/models/*.glb) and/or any external .glb files to PNG, so a
## modeler can LOOK at the result in the game's toon lighting without the editor (pipeline agent tool).
## Needs a real renderer; under --headless it prints a hint and exits 0. See MODELING.md.
##
##   xvfb-run -a -s "-screen 0 1280x720x24" godot --path . --rendering-driver opengl3 \
##       --rendering-method gl_compatibility -s res://tools/tests/models_preview.gd -- \
##       --out=/tmp/models_preview [--models=oil_drum,pendant_lamp] [--layout=lineup|sheet|both]
##
## Options (after --):
##   --out=DIR            output folder (default user://models_preview)
##   --models=a,b         models from res://art/models (default: every .glb there; "none" = skip them)
##   --ref=/abs/x.glb,..  extra external .glb files loaded at runtime (never imported into the project)
##   --dir=/abs/dir       every .glb in that folder, loaded at runtime (reference packs)
##   --layout=lineup      all models side by side at true scale on a concrete floor (default)
##   --layout=sheet       one auto-framed cell per model with name / tris / size, tiled into sheets
##   --layout=eye         in-game check: player camera (fov 80, eye 1.6 m) in a bare factory corner; floor
##                        models on the floor, ceiling models hung from --ceiling=6, wall models on the
##                        back wall at 1.4 m (mount detected from the bounds). Comma-separate to combine:
##                        --layout=eye,sheet ("both" = lineup,sheet)
##   --cols=6 --cell=256x256 --per-sheet=24    sheet geometry
##   --size=1600x700      lineup image size
##   --outline[=0.025]    ink outline hull on res:// models (Toonify.outline)
##   --tint=#rrggbb       tint for TINT* materials of res:// models (else they stay neutral grey)
##   --variants=N         lineup: N copies of each res:// model, cycling through --tints (default 1)
##   --tints=#a,#b,#c     tints used by --variants
##   --toon-refs          also toonify external refs (default: shown with their own materials)
##   --yaw=35 --pitch=22  camera angle (degrees; yaw 0 = straight at the front, +yaw = from the +X side)
##
## Facing: the camera looks at every model's FRONT. Stations/props face +Z; models whose manifest entry
## (res://art/models/manifest.json, written by tools/blender/build.py) says front "-z" (characters, held
## items) are turned 180 degrees for the shot. External .glb refs follow glTF (front +Z).
##   --prefix=name        output file name prefix (default "models")
##   --shadows            keep sun shadows (llvmpipe doubles the lit side with shadows; off by default)
##   --bg=#rrggbb         override the background colour
##
## Loading external .glb files prints harmless "Unable to open file: res://.godot/imported/..." errors for
## their textures (the loader tries the import cache first, then reads the PNG directly).

const MODELS_DIR := "res://art/models"
const MANIFEST := "res://art/models/manifest.json"
const LIGHTING := "res://art/env/toon_lighting.tscn"

var _out := "user://models_preview"
var _layout := "lineup"
var _cols := 6
var _cell := Vector2i(256, 256)
var _per_sheet := 24
var _size := Vector2i(1600, 700)
var _outline := 0.0
var _tint := Color(0, 0, 0, 0)
var _variants := 1
var _tints: Array[Color] = []
var _toon_refs := false
var _yaw := 35.0
var _pitch := 22.0
var _prefix := "models"
var _shadows := false
var _bg := Color(0, 0, 0, 0)
var _ceiling := 6.0

## [{name, path, external}]
var _entries: Array[Dictionary] = []
## name -> {kind, front, mount, ...} from the manifest
var _manifest: Dictionary = {}


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var driver := RenderingServer.get_current_rendering_driver_name()
	if DisplayServer.get_name() == "headless" or driver == "" or driver == "dummy":
		print("models_preview: needs a real renderer (run it under xvfb-run with --rendering-driver opengl3); skipping")
		quit(0)
		return
	var model_names: PackedStringArray = []
	var all_models := true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			_out = a.trim_prefix("--out=")
		elif a.begins_with("--models="):
			all_models = false
			var v := a.trim_prefix("--models=")
			if v != "none":
				model_names = v.split(",", false)
		elif a.begins_with("--ref="):
			for p in a.trim_prefix("--ref=").split(",", false):
				_entries.append({"name": p.get_file().get_basename(), "path": p, "external": true})
		elif a.begins_with("--dir="):
			var d := a.trim_prefix("--dir=")
			var files := DirAccess.get_files_at(d)
			files.sort()
			for f in files:
				if f.get_extension().to_lower() == "glb":
					_entries.append({"name": f.get_basename(), "path": d.path_join(f), "external": true})
		elif a.begins_with("--layout="):
			_layout = a.trim_prefix("--layout=")
		elif a.begins_with("--cols="):
			_cols = maxi(1, int(a.trim_prefix("--cols=")))
		elif a.begins_with("--cell="):
			var wh := a.trim_prefix("--cell=").split("x")
			_cell = Vector2i(int(wh[0]), int(wh[1]))
		elif a.begins_with("--per-sheet="):
			_per_sheet = maxi(1, int(a.trim_prefix("--per-sheet=")))
		elif a.begins_with("--size="):
			var wh2 := a.trim_prefix("--size=").split("x")
			_size = Vector2i(int(wh2[0]), int(wh2[1]))
		elif a == "--outline":
			_outline = 0.025
		elif a.begins_with("--outline="):
			_outline = float(a.trim_prefix("--outline="))
		elif a.begins_with("--tint="):
			_tint = Color(a.trim_prefix("--tint="))
		elif a.begins_with("--variants="):
			_variants = maxi(1, int(a.trim_prefix("--variants=")))
		elif a.begins_with("--tints="):
			for t in a.trim_prefix("--tints=").split(",", false):
				_tints.append(Color(t))
		elif a == "--toon-refs":
			_toon_refs = true
		elif a.begins_with("--yaw="):
			_yaw = float(a.trim_prefix("--yaw="))
		elif a.begins_with("--pitch="):
			_pitch = float(a.trim_prefix("--pitch="))
		elif a.begins_with("--prefix="):
			_prefix = a.trim_prefix("--prefix=")
		elif a == "--shadows":
			_shadows = true
		elif a.begins_with("--bg="):
			_bg = Color(a.trim_prefix("--bg="))
		elif a.begins_with("--ceiling="):
			_ceiling = float(a.trim_prefix("--ceiling="))
	if FileAccess.file_exists(MANIFEST):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
		if parsed is Dictionary:
			_manifest = parsed
	if all_models:
		var files := DirAccess.get_files_at(MODELS_DIR)
		files.sort()
		for f in files:
			if f.get_extension() == "glb":
				model_names.append(f.get_basename())
	var own: Array[Dictionary] = []
	for n in model_names:
		own.append({"name": n, "path": "%s/%s.glb" % [MODELS_DIR, n], "external": false})
	_entries = own + _entries
	if _entries.is_empty():
		print("models_preview: nothing to render")
		quit(0)
		return
	DirAccess.make_dir_recursive_absolute(_out)
	var layouts := _layout.replace("both", "lineup,sheet").split(",", false)
	if "lineup" in layouts:
		await _render_lineup()
	if "eye" in layouts:
		await _render_eye()
	if "sheet" in layouts:
		await _render_sheets()
	print("models_preview: wrote %s" % ProjectSettings.globalize_path(_out))
	quit(0)


# ------------------------------------------------------------------------------------------ loading
func _instance(entry: Dictionary, tint := Color(0, 0, 0, 0)) -> Node3D:
	var node: Node3D = null
	if entry.external:
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if doc.append_from_file(entry.path, state) != OK:
			push_error("models_preview: cannot load %s" % entry.path)
			return null
		node = doc.generate_scene(state) as Node3D
		if node and _toon_refs:
			Toonify.toonify(node)
	else:
		var ps := load(entry.path) as PackedScene
		if ps == null:
			push_error("models_preview: cannot load %s" % entry.path)
			return null
		node = ps.instantiate() as Node3D
		if node and str((_manifest.get(entry.name, {}) as Dictionary).get("front", "+z")) == "-z":
			node.rotation.y = PI # face the camera like the +Z models
		if node is Toonify:
			# The importer attached Toonify as the root script: configure it before _ready() runs.
			(node as Toonify).tint = tint
			(node as Toonify).outline_width = _outline
		elif node:
			node.ready.connect(func() -> void:
				Toonify.toonify(node, -1.0, tint)
				if _outline > 0.0:
					Toonify.outline(node, _outline))
	return node


static func _aabb(node: Node) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "VisualInstance3D", true, false) + [node]:
		var vi := n as VisualInstance3D
		if vi == null or not vi.is_visible_in_tree() or vi.has_meta(&"toonify_outline"):
			continue
		var b: AABB = vi.global_transform * vi.get_aabb()
		if first:
			box = b
			first = false
		else:
			box = box.merge(b)
	return box


static func _tri_count(node: Node) -> int:
	var tris := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			tris += (idx.size() if idx.size() > 0 else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return tris


# ------------------------------------------------------------------------------------------ stage
func _make_stage(size: Vector2i) -> SubViewport:
	var sv := SubViewport.new()
	sv.size = size
	sv.own_world_3d = true
	sv.transparent_bg = false
	sv.msaa_3d = Viewport.MSAA_4X
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(sv)
	if ResourceLoader.exists(LIGHTING):
		var lighting := (load(LIGHTING) as PackedScene).instantiate()
		sv.add_child(lighting)
		var sun := lighting.get_node_or_null("Sun") as DirectionalLight3D
		if sun and not _shadows:
			sun.shadow_enabled = false
		if _bg.a > 0.0:
			var we := lighting.get_node_or_null("WorldEnvironment") as WorldEnvironment
			if we and we.environment:
				var env := we.environment.duplicate() as Environment
				env.background_color = _bg
				we.environment = env
	else:
		var sun2 := DirectionalLight3D.new()
		sun2.rotation_degrees = Vector3(-40, 35, 0)
		sv.add_child(sun2)
	var cam := Camera3D.new()
	cam.name = "Cam"
	cam.fov = 32.0
	sv.add_child(cam)
	cam.current = true
	return sv


func _aim(cam: Camera3D, box: AABB, aspect: float, margin := 1.08) -> void:
	# Camera on the front side (+Z, see the header), looking back at the box centre; the distance is the
	# smallest one that keeps all 8 box corners inside the frustum (with `margin`).
	var c := box.get_center()
	var yaw := deg_to_rad(_yaw)
	var pitch := deg_to_rad(_pitch)
	var dir := Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)).normalized()
	var tan_v := tan(deg_to_rad(cam.fov) * 0.5) / margin
	var tan_h := tan_v * aspect
	var lo := 0.01
	var hi := maxf(box.size.length(), 0.1) * 20.0
	for i in 40:
		var mid := (lo + hi) * 0.5
		var xf := Transform3D(Basis.looking_at(-dir, Vector3.UP), c + dir * mid)
		var inv := xf.affine_inverse()
		var fits := true
		for k in 8:
			var p := inv * box.get_endpoint(k)
			if -p.z < 0.02 or absf(p.x) > -p.z * tan_h or absf(p.y) > -p.z * tan_v:
				fits = false
				break
		if fits:
			hi = mid
		else:
			lo = mid
	cam.global_transform = Transform3D(Basis.looking_at(-dir, Vector3.UP), c + dir * hi)
	cam.near = 0.02
	cam.far = hi + box.size.length() * 2.0 + 20.0


func _frames(n: int) -> void:
	for i in n:
		await process_frame
	await RenderingServer.frame_post_draw


# ------------------------------------------------------------------------------------------ lineup
func _render_lineup() -> void:
	var sv := _make_stage(_size)
	var cam := sv.get_node("Cam") as Camera3D
	cam.fov = 30.0
	var row := Node3D.new()
	sv.add_child(row)
	var x := 0.0
	var gap := 0.35
	var placed: Array[Node3D] = []
	for entry in _entries:
		var copies := 1 if entry.external else _variants
		for v in copies:
			var tint := _tint
			if not entry.external and not _tints.is_empty() and _variants > 1:
				tint = _tints[v % _tints.size()]
			var node := _instance(entry, tint)
			if node == null:
				continue
			row.add_child(node)
			await process_frame
			var b := _aabb(node)
			# Left to right along +X (the camera is on the +Z side). Everything stands on the floor
			# (ceiling models are lifted onto it).
			node.position.x += x - b.position.x
			node.position.y -= b.position.y
			x += b.size.x + gap
			placed.append(node)
			var label := Label3D.new()
			label.text = entry.name if copies == 1 else "%s %d" % [entry.name, v + 1]
			label.pixel_size = 0.0025
			label.font_size = 40
			label.outline_size = 10
			label.modulate = Color("ecebe6")
			label.outline_modulate = Color("2e2a3d")
			label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			label.no_depth_test = true
			label.position = Vector3(x - gap - b.size.x * 0.5, 0.02, b.end.z + 0.12)
			row.add_child(label)
	# Centre the row and lay a floor under it.
	row.position.x = -(x - gap) * 0.5
	var floor_mi := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(x + 4.0, 0.05, 8.0)
	floor_mi.mesh = plane
	floor_mi.position = Vector3(0, -0.025, -1.5)
	floor_mi.material_override = Toon.lib(&"concrete") if ResourceLoader.exists("res://art/materials/toon_concrete.tres") else Toon.lib(&"floor")
	sv.add_child(floor_mi)
	await process_frame
	var box := AABB()
	var first := true
	for n in placed:
		var b := _aabb(n)
		box = b if first else box.merge(b)
		first = false
	_aim(cam, box, float(_size.x) / _size.y, 1.0)
	await _frames(6)
	var path := _out.path_join(_prefix + "_lineup.png")
	sv.get_texture().get_image().save_png(path)
	print("models_preview: ", ProjectSettings.globalize_path(path))
	sv.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ eye
## "floor" | "ceiling" | "wall" | "free": the manifest's mount, else guessed from the unplaced bounds.
func _mount_of(entry: Dictionary, b: AABB) -> String:
	var m := str((_manifest.get(entry.name, {}) as Dictionary).get("mount", ""))
	if m != "":
		return m
	if absf(b.position.y) < 0.02:
		return "floor"
	if absf(b.end.y) < 0.02:
		return "ceiling"
	if absf(b.position.z) < 0.02:
		return "wall"
	return "free"


func _render_eye() -> void:
	const WALL_Z := 1.3
	var sv := _make_stage(_size)
	var cam := sv.get_node("Cam") as Camera3D
	cam.fov = 80.0 # the player's camera (scenes/player/player.tscn)
	var row := Node3D.new()
	sv.add_child(row)
	var x := 0.0
	var gap := 0.5
	for entry in _entries:
		var copies := 1 if entry.external else _variants
		for v in copies:
			var tint := _tint
			if not entry.external and not _tints.is_empty() and _variants > 1:
				tint = _tints[v % _tints.size()]
			var node := _instance(entry, tint)
			if node == null:
				continue
			row.add_child(node)
			await process_frame
			var b := _aabb(node)
			node.position.x += x - b.position.x
			match _mount_of(entry, b):
				"ceiling":
					node.position.y += _ceiling
				"wall":
					node.position += Vector3(0, 1.4 - b.position.y, -WALL_Z - b.position.z)
				"floor":
					pass
				_:
					node.position.y -= b.position.y
			x += b.size.x + gap
	row.position.x = -(x - gap) * 0.5
	var floor_mi := MeshInstance3D.new()
	var plane := BoxMesh.new()
	plane.size = Vector3(40, 0.1, 20)
	floor_mi.mesh = plane
	floor_mi.position = Vector3(0, -0.05, 0)
	floor_mi.material_override = Toon.lib(&"concrete")
	sv.add_child(floor_mi)
	var wall := MeshInstance3D.new()
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(40, _ceiling + 1.0, 0.2)
	wall.mesh = wall_mesh
	wall.position = Vector3(0, (_ceiling + 1.0) * 0.5, -WALL_Z - 0.1)
	wall.material_override = Toon.lib(&"olive")
	sv.add_child(wall)
	var half_h := atan(tan(deg_to_rad(cam.fov) * 0.5) * float(_size.x) / _size.y)
	var dist := maxf(3.2, (x - gap) * 0.5 / tan(half_h) * 1.1 + 0.4)
	cam.position = Vector3(0, 1.6, dist)
	cam.look_at(Vector3(0, 1.9, -WALL_Z * 0.5), Vector3.UP)
	await _frames(6)
	var path := _out.path_join(_prefix + "_eye.png")
	sv.get_texture().get_image().save_png(path)
	print("models_preview: ", ProjectSettings.globalize_path(path))
	sv.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ sheets
func _render_sheets() -> void:
	var sv := _make_stage(_cell)
	var cam := sv.get_node("Cam") as Camera3D
	var label := Label.new()
	label.theme_type_variation = &"SubtleLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.size = Vector2(_cell.x, _cell.y - 4)
	label.add_theme_font_size_override(&"font_size", 13)
	sv.add_child(label)
	var sheet_index := 0
	var sheet: Image = null
	var in_sheet := 0
	for i in _entries.size():
		var entry: Dictionary = _entries[i]
		var node := _instance(entry, _tint)
		if node == null:
			continue
		sv.add_child(node)
		await process_frame
		var b := _aabb(node)
		_aim(cam, b, float(_cell.x) / _cell.y, 1.12)
		label.text = "%s\n%d tris  %.2f x %.2f x %.2f m" % [entry.name, _tri_count(node), b.size.x, b.size.y, b.size.z]
		await _frames(3)
		var img := sv.get_texture().get_image()
		img.convert(Image.FORMAT_RGBA8)
		if sheet == null:
			var count := mini(_per_sheet, _entries.size() - i)
			var cols := mini(_cols, count)
			var rows := ceili(float(count) / cols)
			sheet = Image.create(cols * _cell.x, rows * _cell.y, false, Image.FORMAT_RGBA8)
			sheet.fill(Color(0.1, 0.1, 0.12))
			in_sheet = 0
		var cell_pos := Vector2i((in_sheet % _cols) * _cell.x, (in_sheet / _cols) * _cell.y)
		sheet.blit_rect(img, Rect2i(Vector2i.ZERO, _cell), cell_pos)
		in_sheet += 1
		node.queue_free()
		await process_frame
		if in_sheet >= _per_sheet or i == _entries.size() - 1:
			sheet_index += 1
			var path := _out.path_join("%s_sheet_%d.png" % [_prefix, sheet_index])
			sheet.save_png(path)
			print("models_preview: ", ProjectSettings.globalize_path(path))
			sheet = null
	sv.queue_free()
	await process_frame
