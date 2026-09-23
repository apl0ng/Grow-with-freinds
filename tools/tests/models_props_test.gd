extends SceneTree
## Headless checks for the modelled room props (props modeler). Exit code 0 = pass.
##   godot --headless --path . -s res://tools/tests/models_props_test.gd
## Per prop scene (scenes/world/props/): the Blender model is instanced (under or as `Visual`), no primitive
## placeholder meshes are left, the collider is unchanged and the model fits it, the nodes the scene scripts
## address exist with pivots/rest rotations as the scripts expect, and the scripts still animate them
## (camera pan + LED blink, clock hands, drip + puddle, sign stretching, lamp swing). In the room: the drums and
## crates get varied paint (tint_variety.gd) and every model surface is toon-converted.

const PROPS := "res://scenes/world/props/"
const ROOM_SCENE := "res://scenes/world/room.tscn"
## scene -> [model glb, model node path ("Visual" = instanced as Visual)]
const MODELS := {
	"oil_drum": ["oil_drum", "Visual/Model"],
	"pendant_lamp": ["pendant_lamp", "Visual"],
	"pendant_lamp_short": ["pendant_lamp_short", "Visual"],
	"pallet": ["pallet", "Visual/Model"],
	"crate": ["crate", "Visual/Model"],
	"cot": ["cot", "Visual/Model"],
	"security_camera": ["security_camera", "Visual"],
	"punch_clock": ["punch_clock", "Visual/Model"],
	"sign_board": ["sign_board", "Visual"],
	"wall_clock": ["wall_clock", "Visual"],
	"sad_plant": ["sad_plant", "Visual/Model"],
	"leaky_pipe": ["leaky_pipe", "Visual"],
}
## Floor props with a collider: shape type + size (the placeholders' colliders, unchanged).
const COLLIDERS := {
	"oil_drum": ["CylinderShape3D", Vector3(0.66, 0.92, 0.66), Vector3(0, 0.46, 0)],
	"pallet": ["BoxShape3D", Vector3(1.2, 0.15, 1.0), Vector3(0, 0.075, 0)],
	"crate": ["BoxShape3D", Vector3(0.9, 0.9, 0.9), Vector3(0, 0.45, 0)],
	"cot": ["BoxShape3D", Vector3(2.0, 0.6, 0.8), Vector3(0, 0.3, 0)],
}
## How far a model may poke out of its collider (m, per side / on top).
const FIT_TOLERANCE := 0.03

var _checks := 0
var _fails: PackedStringArray = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> bool:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("  FAIL: ", what)
	return ok


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	var holder := Node3D.new()
	root.add_child(holder)
	for scene_name: String in MODELS:
		_check_scene(scene_name)
	await _check_security_camera(holder)
	await _check_wall_clock(holder)
	await _check_drip(holder)
	_check_sign_board(holder)
	await _check_pendant(holder)
	await _check_room()
	holder.queue_free()
	await process_frame
	print("models_props_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


func _load(scene_name: String) -> Node3D:
	var ps := load(PROPS + scene_name + ".tscn") as PackedScene
	return ps.instantiate() as Node3D if ps != null else null


## `n` itself (if it is a mesh) and every mesh below it, without Toonify's outline hulls.
static func _model_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and not n.has_meta(&"toonify_outline"):
		out.append(n as MeshInstance3D)
	for m in n.find_children("*", "MeshInstance3D", true, false):
		if not m.has_meta(&"toonify_outline"):
			out.append(m as MeshInstance3D)
	return out


## Transform of `n` relative to its ancestor `space` (works outside the tree too).
static func _rel(n: Node, space: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p := n
	while p != null and p != space:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## Mesh bounds of `n` in the space of its ancestor `space` (outline hulls skipped).
static func _bounds(n: Node, space: Node) -> AABB:
	var box := AABB()
	var first := true
	for mi in _model_meshes(n):
		if mi.mesh == null:
			continue
		var b: AABB = _rel(mi, space) * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


# ------------------------------------------------------------------------------------------ static checks
func _check_scene(scene_name: String) -> void:
	var tag := scene_name + ": "
	var inst := _load(scene_name)
	if not _check(inst != null, tag + "scene loads and instantiates"):
		return
	var spec: Array = MODELS[scene_name]
	var model := inst.get_node_or_null(NodePath(spec[1])) as Node3D
	_check(model != null and model.scene_file_path == "res://art/models/%s.glb" % spec[0],
			tag + "%s is an instance of art/models/%s.glb" % [spec[1], spec[0]])
	_check(model is Toonify, tag + "the model root is a Toonify node")
	var visual := inst.get_node_or_null(^"Visual") as Node3D
	_check(visual != null, tag + "has a Visual node")
	if visual != null:
		var placeholders := 0
		for n in visual.find_children("*", "GeometryInstance3D", true, false):
			if n is MultiMeshInstance3D or (n is MeshInstance3D and (n as MeshInstance3D).mesh is PrimitiveMesh):
				placeholders += 1
		_check(placeholders == 0, tag + "no primitive placeholder meshes left under Visual (%d)" % placeholders)
		_check(_model_meshes(visual).size() >= 1, tag + "Visual holds the model's meshes")
		_check(visual.transform.is_equal_approx(Transform3D.IDENTITY), tag + "Visual sits at the prop origin (identity)")
	if COLLIDERS.has(scene_name):
		var want: Array = COLLIDERS[scene_name]
		var shape_node := inst.get_node_or_null(^"Shape") as CollisionShape3D
		var ok: bool = shape_node != null and shape_node.shape != null and shape_node.shape.get_class() == want[0]
		_check(ok and shape_node.position.is_equal_approx(want[2]), tag + "collider %s kept at %s" % [want[0], want[2]])
		if ok:
			var size := Vector3.ZERO
			if shape_node.shape is BoxShape3D:
				size = (shape_node.shape as BoxShape3D).size
			elif shape_node.shape is CylinderShape3D:
				var c := shape_node.shape as CylinderShape3D
				size = Vector3(c.radius * 2.0, c.height, c.radius * 2.0)
			_check(size.is_equal_approx(want[1]), tag + "collider size unchanged %s (got %s)" % [want[1], size])
			# The model fills its collider and does not grow past it (walking paths stay as they were).
			var b := _bounds(visual, inst)
			var col := AABB(shape_node.position - size * 0.5, size)
			var grown := col.grow(FIT_TOLERANCE)
			_check(grown.encloses(b), tag + "model %s fits the collider %s (+%.2f m)" % [b, col, FIT_TOLERANCE])
			_check(absf(b.position.y) < 0.01 and b.size.x > size.x * 0.9 and b.size.z > size.z * 0.9
					and b.end.y > size.y * 0.85, tag + "model stands on the floor and fills the collider (%s)" % b)
	# Contract nodes the scene scripts / room code use.
	match scene_name:
		"security_camera":
			for p in ["Visual/Bracket", "Visual/Pan", "Visual/Pan/Tilt", "Visual/Pan/Tilt/Led"]:
				_check(inst.get_node_or_null(p) is Node3D, tag + p + " exists")
			var pan := inst.get_node_or_null(^"Visual/Pan") as Node3D
			var tilt := inst.get_node_or_null(^"Visual/Pan/Tilt") as Node3D
			if pan != null and tilt != null:
				_check(pan.basis.is_equal_approx(Basis.IDENTITY) and tilt.basis.is_equal_approx(Basis.IDENTITY),
						tag + "Pan / Tilt rest rotation is identity (the script sets absolute angles)")
				_check(pan.position.z > 0.2 and pan.position.z < 0.4, tag + "the pan pivot stands off the wall (z %.2f)" % pan.position.z)
				var body := _bounds(tilt, inst)
				_check(body.get_center().z > pan.position.z and body.position.y < pan.position.y,
						tag + "the housing hangs below and in front of the pan pivot")
		"wall_clock":
			for p in ["Visual/HourHand", "Visual/MinuteHand", "Visual/SecondHand"]:
				var h := inst.get_node_or_null(p) as Node3D
				if _check(h is MeshInstance3D, tag + p + " exists (a mesh)"):
					_check(h.position.is_equal_approx(Vector3.ZERO), tag + p + " pivots at the clock centre")
					_check((h as MeshInstance3D).get_aabb().end.y > 0.15 and absf((h as MeshInstance3D).get_aabb().get_center().x) < 0.05,
							tag + p + " points at 12 when its rotation is 0 (the scene sets the resting time)")
			var sec := inst.get_node_or_null(^"Visual/SecondHand") as Node3D
			_check(sec != null and sec.basis.is_equal_approx(Basis.IDENTITY), tag + "SecondHand rest rotation is identity")
		"sign_board":
			_check(inst.get_node_or_null(^"Visual/Board") is MeshInstance3D and inst.get_node_or_null(^"Visual/Frame") is MeshInstance3D,
					tag + "Visual/Board + Visual/Frame are meshes (sign_board.gd stretches them)")
			_check(inst.get_node_or_null(^"Text") is Label3D, tag + "the Text Label3D stays")
		"leaky_pipe":
			_check(inst.get_node_or_null(^"Visual/Drop") is Node3D and inst.get_node_or_null(^"Visual/Puddle") is Node3D,
					tag + "Visual/Drop + Visual/Puddle exist (drip.gd)")
			var puddle := inst.get_node_or_null(^"Visual/Puddle") as Node3D
			var drop := inst.get_node_or_null(^"Visual/Drop") as Node3D
			if puddle != null and drop != null:
				_check(absf(puddle.position.y) < 0.001, tag + "Puddle origin on the floor (drip.gd's landing height)")
				var pb := _bounds(puddle, inst)
				_check(pb.has_point(Vector3(drop.position.x, pb.get_center().y, drop.position.z)),
						tag + "the drop falls into the puddle")
				_check(drop.position.y > 1.5, tag + "the drop hangs at the leaking joint (y %.2f)" % drop.position.y)
		"pendant_lamp", "pendant_lamp_short":
			_check(inst.get_node_or_null(^"Visual/Lamp") is MeshInstance3D and inst.get_node_or_null(^"Visual/Bulb") is MeshInstance3D,
					tag + "Visual/Lamp + Visual/Bulb exist")
			var light := inst.get_node_or_null(^"Light") as SpotLight3D
			var bulb := inst.get_node_or_null(^"Visual/Bulb") as Node3D
			_check(light != null and bulb != null and absf(light.position.y - bulb.position.y) < 0.1
					and not light.shadow_enabled, tag + "the SpotLight hangs at the bulb (y %.2f), no shadows" % (light.position.y if light else 0.0))
			if scene_name == "pendant_lamp":
				_check(light != null and absf(light.position.y + 2.86) < 0.01, tag + "the room lamp's SpotLight stays at y -2.86")
		"punch_clock":
			var label := inst.get_node_or_null(^"Label") as Label3D
			_check(label != null and label.text == "CLOCK IN", tag + "the CLOCK IN Label3D stays")
	inst.free()


# ------------------------------------------------------------------------------------------ behaviour
func _check_security_camera(holder: Node3D) -> void:
	var cam := _load("security_camera")
	holder.add_child(cam)
	var pan := cam.get_node(^"Visual/Pan") as Node3D
	var led := cam.get_node(^"Visual/Pan/Tilt/Led") as Node3D
	var yaws: Array[float] = []
	var seen_on := false
	var seen_off := false
	for i in 18:
		await create_timer(0.1).timeout
		yaws.append(pan.rotation.y)
		seen_on = seen_on or led.visible
		seen_off = seen_off or not led.visible
	_check(absf(yaws[0] - yaws[yaws.size() - 1]) > 0.005, "security_camera: security_camera.gd pans the modelled Pan")
	_check(seen_on and seen_off, "security_camera: the Led blinks")
	cam.queue_free()


func _check_wall_clock(holder: Node3D) -> void:
	var clock := _load("wall_clock")
	holder.add_child(clock)
	var sec := clock.get_node(^"Visual/SecondHand") as Node3D
	var minute := clock.get_node(^"Visual/MinuteHand") as Node3D
	var hour := clock.get_node(^"Visual/HourHand") as Node3D
	_check(absf(rad_to_deg(hour.rotation.z) - 122.0) < 0.5, "wall_clock: the scene sets the hour hand (7-ish, %.1f deg)" % rad_to_deg(hour.rotation.z))
	var s0 := sec.rotation.z
	var m0 := minute.rotation.z
	await create_timer(1.15).timeout
	_check(not is_equal_approx(sec.rotation.z, s0), "wall_clock: wall_clock.gd ticks the modelled SecondHand")
	_check(minute.rotation.z < m0 and minute.rotation.z > m0 - 0.01, "wall_clock: the MinuteHand creeps on from its rest")
	clock.queue_free()


func _check_drip(holder: Node3D) -> void:
	var pipe := _load("leaky_pipe")
	pipe.set(&"interval", 1.2)
	pipe.set(&"swell_time", 0.3)
	holder.add_child(pipe)
	var drop := pipe.get_node(^"Visual/Drop") as Node3D
	var start := drop.position.y
	var lowest := start
	var hidden := false
	for i in 30:
		await create_timer(0.05).timeout
		lowest = minf(lowest, drop.position.y)
		hidden = hidden or not drop.visible
	_check(lowest < start - 0.5, "leaky_pipe: drip.gd drops the modelled Drop (lowest y %.2f from %.2f)" % [lowest, start])
	_check(hidden, "leaky_pipe: the drop vanishes into the puddle")
	pipe.queue_free()


func _check_sign_board(holder: Node3D) -> void:
	var sign := _load("sign_board")
	holder.add_child(sign)
	sign.set(&"board_size", Vector2(3.2, 1.9))
	sign.set(&"frame_width", 0.08)
	var board := sign.get_node(^"Visual/Board") as Node3D
	var frame := sign.get_node(^"Visual/Frame") as Node3D
	var bb := _bounds(board, sign)
	var fb := _bounds(frame, sign)
	_check(absf(bb.size.x - 3.2) < 0.03 and absf(bb.size.y - 1.9) < 0.03, "sign_board: the Board stretches to board_size (%s)" % bb.size)
	_check(absf(fb.size.x - 3.36) < 0.03 and absf(fb.size.y - 2.06) < 0.03, "sign_board: the Frame stretches to board + 2 x frame_width (%s)" % fb.size)
	_check(fb.position.z > -0.005 and bb.end.z < 0.075, "sign_board: board and frame stay between the wall and the Text (z %.3f..%.3f)" % [fb.position.z, bb.end.z])
	var label := sign.get_node(^"Text") as Label3D
	sign.set(&"text", "OWED: $400 / SHIFT 1")
	_check(label.text == "OWED: $400 / SHIFT 1", "sign_board: text still goes to the Text Label3D")
	sign.queue_free()


func _check_pendant(holder: Node3D) -> void:
	var lamp := _load("pendant_lamp")
	lamp.set(&"swing_degrees", 6.0)
	lamp.set(&"swing_period", 2.0)
	holder.add_child(lamp)
	var r0 := lamp.rotation
	await create_timer(0.3).timeout
	_check(not lamp.rotation.is_equal_approx(r0), "pendant_lamp: pendant_lamp.gd swings the lamp about its ceiling mount")
	var shade := _bounds(lamp.get_node(^"Visual/Lamp"), lamp)
	_check(shade.end.y <= 0.01 and shade.position.y < -2.5, "pendant_lamp: hangs from the mount (y %.2f..%.2f)" % [shade.position.y, shade.end.y])
	lamp.queue_free()


# ------------------------------------------------------------------------------------------ in the room
func _check_room() -> void:
	var room := (load(ROOM_SCENE) as PackedScene).instantiate() as Node3D
	root.add_child(room)
	await process_frame
	var decor := room.get_node(^"Decor")
	var drum_tints := {}
	var crate_tints := {}
	for n in decor.get_children():
		var model := n.get_node_or_null(^"Visual/Model") as Toonify
		if model == null:
			continue
		if n.scene_file_path.ends_with("oil_drum.tscn"):
			drum_tints[model.tint.to_html()] = true
		elif n.scene_file_path.ends_with("crate.tscn"):
			crate_tints[model.tint.to_html()] = true
	_check(drum_tints.size() >= 3, "room: the oil drums get varied paint (%d colours: %s)" % [drum_tints.size(), drum_tints.keys()])
	_check(crate_tints.size() >= 3, "room: the crates get varied bands (%d colours: %s)" % [crate_tints.size(), crate_tints.keys()])
	var unconverted: PackedStringArray = []
	var mine := 0
	for mi in _model_meshes(decor):
		var owner_scene := mi.owner.scene_file_path if mi.owner != null else ""
		if not owner_scene.begins_with("res://art/models/") or mi.material_override != null:
			continue
		var glb := owner_scene.get_file().get_basename()
		if not glb in ["oil_drum", "pendant_lamp", "pallet", "crate", "cot", "security_camera", "punch_clock",
				"sign_board", "wall_clock", "sad_plant", "leaky_pipe"]:
			continue
		mine += 1
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s) as BaseMaterial3D
			if m == null or not (m.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON or m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED):
				unconverted.append("%s/%d" % [room.get_path_to(mi), s])
	_check(mine >= 20, "room: the prop models are in the room (%d model meshes)" % mine)
	_check(unconverted.is_empty(), "room: every prop model surface is toon-shaded %s" % [unconverted])
	room.queue_free()
	await process_frame
