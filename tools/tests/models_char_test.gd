extends SceneTree
## Headless checks for the two character models as the game uses them (character modeler). Exit 0 = pass.
##   godot --headless --path . -s res://tools/tests/models_char_test.gd
## Player (scenes/player/player.tscn + art/models/player.glb): contract nodes kept, the model under
##   Visual/Model with its nodes (Body, ArmL, ArmR, FacePivot), the ToonFace on the Visual/Face pitch pivot at
##   the head centre (parts findable, sad, no blush), size/front/floor, player colour -> TINT via Toonify,
##   the local player hides every mesh incl. outline hulls, remote arms swing to the held item at
##   %BodyHandSocket.
## Boss (scenes/world/shopkeeper_npc.tscn + art/models/boss.glb as Visual): every path shopkeeper_npc.gd
##   animates, pivots/rest rotations (identity where the script sets absolute values, the recorded rests
##   for arms and lids), hands resting at counter height in front of him, eyes on -Z, size, budget.
## Autoloads are reached through the root (this script compiles before they are registered).

const PLAYER := "res://scenes/player/player.tscn"
const BOSS := "res://scenes/world/shopkeeper_npc.tscn"
const PLAYER_GLB := "res://art/models/player.glb"
const BOSS_GLB := "res://art/models/boss.glb"
const BUDGET := 8000

var _checks := 0
var _fails: Array[String] = []


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
	await _test_player_model()
	await _test_player_scene()
	await _test_boss()
	await process_frame
	print("models_char_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------ helpers
static func _aabb(node: Node3D, skip_hulls := true) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if skip_hulls and mi.has_meta(&"toonify_outline"):
			continue
		var b: AABB = node.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


static func _tris(node: Node) -> int:
	var tris := 0
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.has_meta(&"toonify_outline"):
			continue
		for s in mi.mesh.get_surface_count():
			var idx: PackedInt32Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			tris += idx.size() / 3
	return tris


static func _deg(v: Vector3) -> Vector3:
	return Vector3(rad_to_deg(v.x), rad_to_deg(v.y), rad_to_deg(v.z))


func _rot_is(node: Node3D, want_deg: Vector3, what: String, tol := 0.6) -> void:
	var got := _deg(node.rotation) if node != null else Vector3.INF
	_check(node != null and got.distance_to(want_deg) < tol, "%s rest rotation %s deg (got %s)" % [what, want_deg, got])


static func _surface_materials(node: Node) -> Array[String]:
	var out: Array[String] = []
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var m := mi.get_active_material(s)
			out.append(m.resource_path if m != null and m.resource_path != "" else (Toonify.material_name(mi.mesh.surface_get_material(s)) if mi.mesh.surface_get_material(s) else ""))
	return out


# ------------------------------------------------------------------------------------------ player
func _test_player_model() -> void:
	var ps := load(PLAYER_GLB) as PackedScene
	if not _check(ps != null, "player.glb loads"):
		return
	var m := ps.instantiate() as Node3D
	root.add_child(m)
	await process_frame
	_check(m is Toonify, "player.glb root is a Toonify node")
	for nm in ["Body", "ArmL", "ArmR", "FacePivot"]:
		_check(m.get_node_or_null(nm) != null, "player model has node %s" % nm)
	for nm in ["ArmL", "ArmR"]:
		var a := m.get_node_or_null(nm) as Node3D
		_check(a != null and a.rotation.is_zero_approx(), "player %s rest rotation is identity (script swings it)" % nm)
	var arm_l := m.get_node_or_null("ArmL") as Node3D
	_check(arm_l != null and arm_l.position.x < -0.2, "ArmL is on the character's left (-X; front is -Z)")
	var box := _aabb(m)
	_check(absf(box.position.y) < 0.01, "player model stands on y = 0 (%.3f)" % box.position.y)
	_check(box.end.y > 1.7 and box.end.y < 1.9, "player model ~1.8 m tall with the hard hat (%.2f)" % box.end.y)
	_check(box.size.x < 1.0 and box.size.z < 1.0, "player model fits ~0.8 m (W %.2f D %.2f)" % [box.size.x, box.size.z])
	var tris := _tris(m)
	_check(tris <= BUDGET, "player model within the %d tri budget (%d)" % [BUDGET, tris])
	var tint_surfaces := 0
	for n in m.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			if Toonify.is_tint(mi.mesh.surface_get_material(s)):
				tint_surfaces += 1
	_check(tint_surfaces >= 3, "player body, legs and arms are TINT (player colour) surfaces (%d)" % tint_surfaces)
	m.queue_free()
	await process_frame


func _spawn_player(peer_name: String, color: Color) -> Node3D:
	var p := (load(PLAYER) as PackedScene).instantiate() as Node3D
	p.name = peer_name
	p.set("player_color", color)
	root.add_child(p)
	return p


func _test_player_scene() -> void:
	var packed := load(PLAYER) as PackedScene
	if not _check(packed != null and packed.can_instantiate(), "player.tscn loads"):
		return
	var color := Color("4da8f7")
	var p := _spawn_player("2", color)          # peer 2: a remote player (body visible)
	await process_frame
	await process_frame
	for path in ["Collision", "Visual", "Visual/Model", "Visual/Face", "Visual/Face/ToonFace", "Head/Camera",
			"Head/Camera/HandSocket", "BodyHandSocket", "NameLabel", "Interactor", "Sync", "BlobShadow"]:
		_check(p.get_node_or_null(path) != null, "player has %s" % path)
	for u in ["%Camera", "%HandSocket", "%BodyHandSocket", "%Interactor", "%NameLabel"]:
		_check(p.get_node_or_null(u) != null, "player unique node %s" % u)
	_check(p.get_node_or_null("Visual/BodyMesh") == null, "primitive BodyMesh replaced by the model")
	var model := p.get_node_or_null("Visual/Model") as Toonify
	var face := p.get_node_or_null("Visual/Face") as Node3D
	var toon_face := p.get_node_or_null("Visual/Face/ToonFace")
	if not _check(model != null and face != null and toon_face != null, "player visual nodes typed right"):
		p.queue_free()
		return
	_check(toon_face is ToonFace, "Visual/Face/ToonFace is the art agent's ToonFace (face.tscn)")
	var pivot := model.get_node_or_null("FacePivot") as Node3D
	_check(pivot != null and face.position.distance_to(pivot.position) < 0.01,
			"Visual/Face pivot sits on the model's head centre (%s vs %s)" % [face.position, pivot.position if pivot else Vector3.INF])
	var tf := toon_face as Node3D
	_check(tf.position.z < -0.25 and tf.position.z > -0.36, "ToonFace on the head's front surface (-Z, %.3f m)" % tf.position.z)
	for part in ["EyeL", "EyeR", "EyeBagL", "EyeBagR", "MouthL", "MouthR"]:
		_check(toon_face.find_child(part, true, false) != null, "ToonFace part %s findable" % part)
	for eye in ["EyeL", "EyeR"]:
		var e := toon_face.find_child(eye, true, false)
		_check(e != null and e.find_child("Pupil", true, false) != null and e.find_child("Lid", true, false) != null,
				"%s has Pupil + Lid" % eye)
	_check(StringName(toon_face.get("mood")) in [&"sad", &"tired"], "player face is sad/tired (%s)" % toon_face.get("mood"))
	var eye_l := toon_face.find_child("EyeL", true, false) as Node3D
	_check(eye_l != null and eye_l.global_position.x < p.global_position.x and eye_l.global_position.z < p.global_position.z - 0.25,
			"player faces -Z (eyes in front) with EyeL on its left")
	var head_box := _aabb(model)
	_check(eye_l != null and eye_l.global_position.y < head_box.end.y - 0.3 and eye_l.global_position.y > 1.1,
			"eyes sit on the head under the hard hat (y %.2f)" % (eye_l.global_position.y if eye_l else 0.0))
	var mats := _surface_materials(p)
	var blush := false
	for m in mats:
		if m.contains("blush"):
			blush = true
	_check(not blush, "no blush anywhere on the player")
	# Player colour -> the model's TINT parts (graded).
	var body := model.get_node_or_null("Body") as MeshInstance3D
	var tinted := false
	if body != null:
		for s in body.mesh.get_surface_count():
			if Toonify.is_tint(body.mesh.surface_get_material(s)):
				var act := body.get_active_material(s) as BaseMaterial3D
				var src_l := (body.mesh.surface_get_material(s) as BaseMaterial3D).albedo_color.get_luminance()
				var k := src_l / Toonify.TINT_NEUTRAL.get_luminance()
				var want := Toon.grade(color)
				if act != null and absf(act.albedo_color.r - want.r * k) < 0.02 and absf(act.albedo_color.b - want.b * k) < 0.02:
					tinted = true
	_check(tinted, "player colour tints the body (Toonify tint = Toon.grade(player_color))")
	_check(model.outline_width > 0.0 and body != null and body.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) != null,
			"player model has the ink outline hull")
	# The held-item socket sits in front of the chest, at hand/chest height.
	var socket := p.get_node("%BodyHandSocket") as Node3D
	_check(socket.position.y > 0.8 and socket.position.y < 1.2 and socket.position.z < -0.4 and absf(socket.position.x) < 0.4,
			"BodyHandSocket in front of the chest (%s)" % socket.position)
	# Remote arms: pose for a held item (the right glove comes up to the socket), back when empty.
	var arm_r := model.get_node_or_null("ArmR") as Node3D
	p.set("_holding", true)
	p.set("_hold_check_left", 1e9)
	for i in 40:
		await process_frame
	var glove := _aabb_global(arm_r)
	var reach := glove.get_center()
	var sock := socket.global_position
	_check(arm_r != null and arm_r.rotation.x > 0.6, "holding: the right arm swings forward (x %.2f rad)" % (arm_r.rotation.x if arm_r else 0.0))
	_check(Vector2(reach.x - sock.x, reach.z - sock.z).length() < 0.35 and glove.end.y > sock.y - 0.25,
			"holding: the right arm reaches the item socket (arm box %s, socket %s)" % [glove, sock])
	p.set("_holding", false)
	for i in 40:
		await process_frame
	_check(arm_r != null and absf(arm_r.rotation.x) < 0.05, "empty hands: the arm hangs again")
	p.queue_free()
	await process_frame
	# Local player (peer 1 == this process): every mesh under Visual, outline hulls too, is shadow-only.
	var local := _spawn_player("1", color)
	await process_frame
	await process_frame
	var visible_left := 0
	var total := 0
	for n in local.get_node("Visual").find_children("*", "GeometryInstance3D", true, false):
		total += 1
		if (n as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			visible_left += 1
	_check(total > 10 and visible_left == 0, "local player: all %d body/face/hull meshes are shadow-only (%d visible)" % [total, visible_left])
	local.queue_free()
	await process_frame


static func _aabb_global(node: Node3D) -> AABB:
	if node == null:
		return AABB()
	var box := AABB()
	var first := true
	var list: Array = [node]
	list.append_array(node.find_children("*", "MeshInstance3D", true, false))
	for n in list:
		var mi := n as MeshInstance3D
		if mi == null or mi.has_meta(&"toonify_outline"):
			continue
		var b: AABB = mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


# ------------------------------------------------------------------------------------------ boss
func _test_boss() -> void:
	var packed := load(BOSS) as PackedScene
	if not _check(packed != null and packed.can_instantiate(), "shopkeeper_npc.tscn loads"):
		return
	var npc := packed.instantiate() as Node3D
	npc.set("animate", false)                     # read the rest pose
	root.add_child(npc)
	await process_frame
	var visual := npc.get_node_or_null("Visual")
	_check(visual is Toonify and (visual as Node).scene_file_path == BOSS_GLB, "the Boss model is instanced AS Visual")
	var paths := ["Visual/Torso", "Visual/Torso/HeadPivot", "Visual/Torso/HeadPivot/EyeLeft",
		"Visual/Torso/HeadPivot/EyeRight", "Visual/Torso/HeadPivot/EyeLeft/LidLeft",
		"Visual/Torso/HeadPivot/EyeRight/LidRight", "Visual/Torso/HeadPivot/EyeLeft/Pupil",
		"Visual/Torso/HeadPivot/EyeRight/Pupil", "Visual/Torso/HeadPivot/Sunglasses", "Visual/Torso/HeadPivot/Hat",
		"Visual/Torso/HeadPivot/Cigar", "Visual/Torso/ArmLeft", "Visual/Torso/ArmRight",
		"Visual/Torso/ArmLeft/Hand", "Visual/Torso/ArmRight/Hand", "Visual/Torso/ArmRight/Hand/Fingers",
		"Visual/Torso/ArmLeft/Hand/Cash", "Visual/Torso/ArmLeft/Hand/Cash/TopBill", "Visual/FootLeft",
		"Visual/FootRight", "BarkLabel", "BlobShadow"]
	for path in paths:
		_check(npc.get_node_or_null(path) != null, "Boss has %s" % path)
	var fingers := npc.get_node_or_null("Visual/Torso/ArmRight/Hand/Fingers")
	var names: Array[String] = []
	if fingers != null:
		for c in fingers.get_children():
			names.append(String(c.name))
	_check(names == ["Finger1", "Finger2", "Finger3", "Finger4"], "Fingers has exactly Finger1..4 (%s)" % [names])
	# Rest pose: identity where shopkeeper_npc.gd writes absolute values, the designed rests elsewhere.
	var torso := npc.get_node_or_null("Visual/Torso") as Node3D
	_check(torso != null and torso.position.is_zero_approx() and torso.rotation.is_zero_approx(),
			"Torso: origin at the floor, rest rotation identity (the breathing bob returns to y 0)")
	var head := npc.get_node_or_null("Visual/Torso/HeadPivot") as Node3D
	_rot_is(head, Vector3.ZERO, "HeadPivot")
	_check(head != null and absf(head.position.y - 1.2) < 0.02, "HeadPivot at the neck (y %.2f)" % (head.position.y if head else 0.0))
	if fingers != null:
		for c in fingers.get_children():
			_rot_is(c as Node3D, Vector3.ZERO, "Fingers/" + String(c.name))
	_rot_is(npc.get_node_or_null("Visual/Torso/ArmLeft/Hand/Cash/TopBill") as Node3D, Vector3.ZERO, "TopBill")
	_rot_is(npc.get_node_or_null("Visual/Torso/ArmRight") as Node3D, Vector3(72, 12, 0), "ArmRight (on the counter)")
	_rot_is(npc.get_node_or_null("Visual/Torso/ArmLeft") as Node3D, Vector3(72, -12, 0), "ArmLeft (on the counter)")
	_rot_is(npc.get_node_or_null("Visual/Torso/ArmRight/Hand") as Node3D, Vector3(-72, 0, 0), "ArmRight/Hand (level)")
	_rot_is(npc.get_node_or_null("Visual/Torso/HeadPivot/EyeLeft/LidLeft") as Node3D, Vector3(-4, 0, -17), "LidLeft (scowl)")
	_rot_is(npc.get_node_or_null("Visual/Torso/HeadPivot/EyeRight/LidRight") as Node3D, Vector3(-4, 0, 17), "LidRight (scowl)")
	for path in ["Visual/Torso/HeadPivot/Hat", "Visual/Torso/HeadPivot/Sunglasses", "Visual/Torso/HeadPivot/Cigar",
			"Visual/FootLeft", "Visual/FootRight"]:
		var n := npc.get_node_or_null(path) as Node3D
		_check(n != null and n.scale.is_equal_approx(Vector3.ONE), "%s has no node scale" % path)
	# Hands rest on the counter (top ~0.84 m above his feet), in front of the belly; right = +X.
	var hand_r := npc.get_node_or_null("Visual/Torso/ArmRight/Hand") as Node3D
	var hand_l := npc.get_node_or_null("Visual/Torso/ArmLeft/Hand") as Node3D
	if hand_r != null and hand_l != null:
		for pair in [[hand_r, "right", 1.0], [hand_l, "left", -1.0]]:
			var h := pair[0] as Node3D
			var gp := h.global_position
			_check(absf(gp.y - 0.86) < 0.08 and gp.z < -0.45 and gp.x * float(pair[2]) > 0.2,
					"%s hand rests on the counter in front of him (%s)" % [pair[1], gp])
	var eye_l := npc.get_node_or_null("Visual/Torso/HeadPivot/EyeLeft") as Node3D
	var eye_r := npc.get_node_or_null("Visual/Torso/HeadPivot/EyeRight") as Node3D
	_check(eye_l != null and eye_r != null and eye_l.global_position.x < 0.0 and eye_r.global_position.x > 0.0
			and eye_l.global_position.z < -0.25, "Boss faces -Z, EyeLeft on his left (-X)")
	var box := _aabb(npc.get_node("Visual") as Node3D)
	_check(absf(box.position.y) < 0.01, "Boss feet at y 0 (%.3f)" % box.position.y)
	_check(box.end.y > 1.85 and box.end.y < 2.12, "Boss ~2 m at the hat (%.2f)" % box.end.y)
	_check(box.size.x > 1.0 and box.size.x < 1.35, "Boss is heavy-set (W %.2f)" % box.size.x)
	var tris := _tris(npc.get_node("Visual"))
	_check(tris <= BUDGET, "Boss within the %d tri budget (%d)" % [BUDGET, tris])
	var cash := npc.get_node_or_null("Visual/Torso/ArmLeft/Hand/Cash") as Node3D
	_check(cash != null and not cash.visible, "the cash wad is hidden at rest (cheer() shows it)")
	# A blink closes the lid over the eye: at x -88 deg the lid's box covers the eye's front.
	var lid := npc.get_node_or_null("Visual/Torso/HeadPivot/EyeLeft/LidLeft") as MeshInstance3D
	if lid != null and eye_l != null:
		lid.rotation.x = deg_to_rad(-88.0)
		var lb := lid.global_transform * lid.get_aabb()
		var eb := (eye_l as MeshInstance3D).global_transform * (eye_l as MeshInstance3D).get_aabb()
		_check(lb.position.z <= eb.position.z + 0.005 and lb.position.y <= eb.get_center().y - 0.03,
				"a blink (-88 deg) swings the lid down over the eye (lid %s, eye %s)" % [lb, eb])
	npc.queue_free()
	await process_frame
