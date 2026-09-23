extends SceneTree
## Environment props (environment modeler): the room's structural props built from Blender models keep their
## contracts. Headless, exit code 0 = pass:
##   godot --headless --path . -s res://tools/tests/models_env_test.gd
## Per scene: loads; the model is instanced AS `Visual` (a Toonify root) so every node path scripts and the room
## use stays valid; colliders, lights and labels are the Godot nodes they were; the bounds match the
## placeholders' footprints; each scene stays lean (the room has a node budget, world_test: <= 360); every
## surface is toon-converted. flicker_light.gd still finds and blinks `Visual/Tubes`. segment_run.gd tiles its
## model into ONE MultiMesh node with toon materials, the tint, a shared mesh and alternate flips.

const PROPS := "res://scenes/world/props/"
const WOOD := "res://art/materials/toon_wood.tres"

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
	await _fence_panel()
	await _fence_gate()
	await _roller_door()
	await _barred_window()
	await _grow_light()
	await _fluoro("fluoro_light.tscn", false)
	await _fluoro("fluoro_light_broken.tscn", true)
	await _segment_runs()
	print("models_env_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------------ helpers
func _spawn(file: String) -> Node3D:
	var ps := load(PROPS + file) as PackedScene
	if not _check(ps != null and ps.can_instantiate(), file + " loads"):
		return null
	var n := ps.instantiate() as Node3D
	root.add_child(n)
	await process_frame
	return n


func _nodes(n: Node) -> int:
	return 1 + n.find_children("*", "", true, false).size()


## Merged bounds (in `n`'s space) of the meshes and multimeshes below `n` (outline hulls skipped).
func _aabb(n: Node3D, under: Node = null) -> AABB:
	var box := AABB()
	var first := true
	for g in (under if under != null else n).find_children("*", "GeometryInstance3D", true, false):
		if not (g is MeshInstance3D or g is MultiMeshInstance3D) or g.has_meta(&"toonify_outline"):
			continue
		var gi := g as GeometryInstance3D
		var local := gi.get_aabb()
		if local.size == Vector3.ZERO and gi is MultiMeshInstance3D:
			local = _mm_aabb(gi as MultiMeshInstance3D)
		if local.size == Vector3.ZERO:
			continue
		var b: AABB = n.global_transform.affine_inverse() * gi.global_transform * local
		box = b if first else box.merge(b)
		first = false
	if under is GeometryInstance3D and not under.has_meta(&"toonify_outline"):
		var gl := (under as GeometryInstance3D).get_aabb()
		if gl.size == Vector3.ZERO and under is MultiMeshInstance3D:
			gl = _mm_aabb(under as MultiMeshInstance3D)
		var own: AABB = n.global_transform.affine_inverse() * (under as GeometryInstance3D).global_transform * gl
		box = own if first else box.merge(own)
	return box


## Bounds of a MultiMesh from its instance buffer (headless runs have a dummy renderer that computes none).
func _mm_aabb(mmi: MultiMeshInstance3D) -> AABB:
	var mm := mmi.multimesh
	if mm == null or mm.mesh == null or mm.transform_format != MultiMesh.TRANSFORM_3D:
		return AABB()
	var buf := mm.buffer
	var box := AABB()
	var first := true
	for i in range(0, buf.size() - 11, 12):
		var xf := Transform3D(Vector3(buf[i], buf[i + 4], buf[i + 8]), Vector3(buf[i + 1], buf[i + 5], buf[i + 9]),
				Vector3(buf[i + 2], buf[i + 6], buf[i + 10]), Vector3(buf[i + 3], buf[i + 7], buf[i + 11]))
		var b := xf * mm.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _toon_ok(n: Node) -> bool:
	for m in n.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		if mi.has_meta(&"toonify_outline") or mi.material_override != null or mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s) as BaseMaterial3D
			if mat == null or not (mat.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON
					or mat.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED):
				return false
	return true


func _near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol


func _visual(n: Node3D, file: String) -> Node3D:
	var v := n.get_node_or_null(^"Visual") as Node3D
	_check(v is Toonify, file + ": the model is instanced AS Visual (a Toonify root)")
	_check(v != null and _toon_ok(v), file + ": every model surface is toon-converted")
	return v


# ------------------------------------------------------------------------------------------------- props
func _fence_panel() -> void:
	var f := "fence_panel.tscn"
	var n := await _spawn(f)
	if n == null:
		return
	var body := n as StaticBody3D
	_check(body != null and body.collision_layer == 1 and body.collision_mask == 0, f + ": StaticBody3D, layer 1 / mask 0")
	var shape := n.get_node_or_null(^"Shape") as CollisionShape3D
	var box := shape.shape as BoxShape3D if shape != null else null
	_check(box != null and box.size.is_equal_approx(Vector3(2.5, 2.2, 0.1)) and shape.position.is_equal_approx(Vector3(0, 1.1, 0)),
			f + ": collider is still the 2.5 x 2.2 x 0.1 box at y 1.1 (reachability depends on it)")
	var v := _visual(n, f)
	var b := _aabb(n)
	_check(absf(b.position.y) < 0.01 and b.end.y < 2.4 and b.position.x > -1.4 and b.end.x < 1.4 and b.position.z > -0.25
			and b.end.z < 0.45, f + ": visual 2.5 m wide, <= 2.4 m tall, on the floor, close to the collider (%s)" % b)
	_check(v != null and v.find_children("*", "MeshInstance3D", true, false).size() == 1, f + ": one mesh (post, rails, wire)")
	_check(_nodes(n) <= 4, f + ": lean scene (%d nodes <= 4)" % _nodes(n))
	n.queue_free()
	await process_frame


func _fence_gate() -> void:
	var f := "fence_gate.tscn"
	var n := await _spawn(f)
	if n == null:
		return
	var v := _visual(n, f)
	var north := n.get_node_or_null(^"Visual/LeafNorth") as Node3D
	var south := n.get_node_or_null(^"Visual/LeafSouth") as Node3D
	_check(north is Toonify and south is Toonify, f + ": two leaf models (Visual/LeafNorth, Visual/LeafSouth)")
	if north != null and south != null:
		var bn := _aabb(n, north)
		var bs := _aabb(n, south)
		_check(bn.end.x < -2.3 and bs.position.x > 2.3, f + ": both leaves hang open outside the 5 m opening (%s / %s)" % [bn, bs])
		_check(bn.position.z > 0.0 and bs.position.z > 0.0, f + ": the leaves fold back on the front (room) side")
	if v != null:
		var bg := _aabb(n, v.get_node_or_null(^"Gate"))
		_check(_near(bg.size.x, 5.28, 0.1) and bg.end.y > 3.2 and bg.end.y < 3.45 and absf(bg.position.y) < 0.01,
				f + ": frame 5.3 m wide (posts at +-2.5), sign plate on top at ~3.3 m (%s)" % bg)
	var text := n.get_node_or_null(^"Text") as Label3D
	_check(text != null and "GROW AREA" in text.text and "AUTHORIZED WORKERS ONLY" in text.text and not text.double_sided,
			f + ": the plate's words are a one-sided Label3D")
	_check(text != null and _near(text.position.y, 2.95, 0.05) and text.position.z > 0.02, f + ": text sits on the plate's front")
	_check(n.find_children("*", "CollisionObject3D", true, false).is_empty(), f + ": visual only (fence colliders do the blocking)")
	_check(_nodes(n) <= 8, f + ": lean scene (%d nodes <= 8)" % _nodes(n))
	n.queue_free()
	await process_frame


func _roller_door() -> void:
	var f := "roller_door.tscn"
	var n := await _spawn(f)
	if n == null:
		return
	_visual(n, f)
	for p in ["Shutter", "Beam", "Chain", "PadlockBody", "PadlockShackle"]:
		_check(n.get_node_or_null(NodePath("Visual/" + p)) is MeshInstance3D, f + ": Visual/%s is its own mesh node" % p)
	var b := _aabb(n)
	_check(_near(b.size.x, 4.8, 0.05) and _near(b.size.y, 4.23, 0.05) and b.size.z < 0.7 and absf(b.position.y) < 0.01
			and b.position.z > -0.02, f + ": 4.8 x 4.2 x <=0.7 m, on the floor, back on the wall plane (%s)" % b)
	var beam := n.get_node_or_null(^"Visual/Beam") as MeshInstance3D
	if beam != null:
		var bb := _aabb(n, beam)
		_check(_near(beam.position.x, 0.0, 0.01) and _near(beam.position.y, 1.33, 0.06) and _near(beam.position.z, 0.245, 0.02),
				f + ": Beam's origin is its centre, chest high in front of the shutter (%s)" % beam.position)
		_check(_near(bb.size.x, 4.8, 0.05) and bb.size.y < 0.25 and bb.position.z > 0.15,
				f + ": the beam is a skinny 4.8 m plank clear of the curtain (%s)" % bb)
		var wood := false
		for s in beam.mesh.get_surface_count():
			wood = wood or beam.get_active_material(s) == load(WOOD)
		_check(wood, f + ": the beam is wood (toon_wood)")
		var stencil := beam.get_node_or_null(^"BeamStencil") as Label3D
		_check(stencil != null and stencil.text == "DO NOT REMOVE", f + ": the beam is stencilled DO NOT REMOVE")
	var lock := n.get_node_or_null(^"Visual/PadlockBody") as Node3D
	var shackle := n.get_node_or_null(^"Visual/PadlockShackle") as Node3D
	_check(lock != null and shackle != null and lock.position.y < 0.6 and lock.position.is_equal_approx(shackle.position),
			f + ": padlock hangs low on the hasp; body and shackle share the hang point")
	_check(_nodes(n) <= 13, f + ": lean scene (%d nodes <= 13: 8 + 5 ink outline hulls)" % _nodes(n))
	n.queue_free()
	await process_frame


func _barred_window() -> void:
	var f := "barred_window.tscn"
	var n := await _spawn(f)
	if n == null:
		return
	var v := _visual(n, f)
	var model_mesh: MeshInstance3D = null
	if v != null:
		for c in v.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).material_override == null:
				model_mesh = c
	_check(model_mesh != null, f + ": the window model mesh")
	if model_mesh != null:
		var b := _aabb(n, model_mesh)
		_check(absf(b.position.z) < 0.01 and b.size.z < 0.3 and _near(b.size.x, 1.84, 0.03) and b.end.y > 0.6 and b.position.y < -1.1,
				f + ": wall mount 1.84 m wide, back on the wall, sill + streak below (%s)" % b)
		var glass := false
		for s in model_mesh.mesh.get_surface_count():
			var m := model_mesh.get_active_material(s) as BaseMaterial3D
			glass = glass or (m != null and m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED)
		_check(glass, f + ": the panes are see-through (the night sky shows behind them)")
	for p in ["Sky", "Moon", "Stars"]:
		var g := n.get_node_or_null(NodePath("Visual/" + p)) as GeometryInstance3D
		if _check(g != null, f + ": Visual/%s kept" % p):
			var b := _aabb(n, g)
			_check(b.position.z > 0.0 and b.end.z < 0.05, f + ": %s sits behind the glass inside the opening (z %.3f..%.3f)" % [p, b.position.z, b.end.z])
	_check(_nodes(n) <= 7, f + ": lean scene (%d nodes <= 7: 6 + the frame's ink outline hull)" % _nodes(n))
	n.queue_free()
	await process_frame


func _grow_light() -> void:
	var f := "grow_light.tscn"
	var n := await _spawn(f)
	if n == null:
		return
	_visual(n, f)
	for p in ["Visual/Housing", "Visual/Tube", "Visual/HalfB/Housing", "Visual/HalfB/Tube"]:
		_check(n.get_node_or_null(NodePath(p)) is MeshInstance3D, f + ": %s exists" % p)
	for p in ["Visual/Tube", "Visual/HalfB/Tube"]:
		var t := n.get_node_or_null(NodePath(p)) as MeshInstance3D
		var lit := t != null
		if t != null:
			for s in t.mesh.get_surface_count():
				var m := t.get_active_material(s) as BaseMaterial3D
				lit = lit and m != null and (m.emission_enabled or m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED)
		_check(lit, f + ": %s glows (emissive, its own node)" % p)
	var b := _aabb(n)
	_check(_near(b.size.z, 7.44, 0.08) and b.size.x < 0.45 and _near(b.end.y, 2.8, 0.03) and b.position.y > -0.3,
			f + ": 7.4 m bar along Z, chains up to the ceiling 2.8 m above (%s)" % b)
	_check(_nodes(n) <= 7, f + ": lean scene (%d nodes <= 7)" % _nodes(n))
	n.queue_free()
	await process_frame


func _fluoro(f: String, broken: bool) -> void:
	var n := await _spawn(f)
	if n == null:
		return
	_visual(n, f)
	_check((n.get_script() as Script).resource_path == PROPS + "flicker_light.gd", f + ": root keeps flicker_light.gd")
	var tubes := n.get_node_or_null(^"Visual/Tubes") as MeshInstance3D
	var light := n.get_node_or_null(^"Light") as OmniLight3D
	_check(tubes != null, f + ": Visual/Tubes is its own mesh node")
	_check(light != null and _near(light.position.y, -1.98, 0.01), f + ": the OmniLight stays under the tubes")
	_check(n.get_node_or_null(^"Visual/Fixture") is MeshInstance3D, f + ": Visual/Fixture (housing + chains)")
	if tubes != null and light != null:
		var neon := load("res://art/materials/toon_neon_green.tres")
		var ok := true
		for s in tubes.mesh.get_surface_count():
			ok = ok and tubes.get_active_material(s) == neon
		_check(ok, f + ": tubes are toon_neon_green")
		var e := light.light_energy
		n.call(&"_set_on", false)
		_check(not tubes.visible and light.light_energy < e, f + ": flicker off hides the tubes and dims the light")
		n.call(&"_set_on", true)
		_check(tubes.visible and _near(light.light_energy, e, 0.001), f + ": flicker on restores them")
		var bt := _aabb(n, tubes)
		if broken:
			_check(bool(n.get(&"flicker")), f + ": flickers by default")
			_check(bt.position.y < -2.5, f + ": one tube dangles well below the housing (lowest %.2f)" % bt.position.y)
		else:
			_check(bt.position.y > -1.9 and bt.size.y < 0.1, f + ": tubes sit level in the housing (%s)" % bt)
	var b := _aabb(n)
	_check(absf(b.end.y) < 0.01 and b.size.x < 1.8, f + ": hangs from the ceiling mount at its origin (%s)" % b)
	_check(_nodes(n) <= 5, f + ": lean scene (%d nodes <= 5)" % _nodes(n))
	n.queue_free()
	await process_frame


func _segment_runs() -> void:
	# A 3-segment pipe run: one node, 3 copies 2 m apart, toon materials, tinted paint.
	var ps := load(PROPS + "pipe_segment.tscn") as PackedScene
	if not _check(ps != null, "pipe_segment.tscn loads"):
		return
	var run := ps.instantiate() as MultiMeshInstance3D
	run.set(&"count", 3)
	var tint := Color(0.49, 0.53, 0.4)
	run.set(&"tint", tint)
	var run2 := ps.instantiate() as MultiMeshInstance3D
	run2.set(&"count", 5)
	run2.set(&"tint", tint)
	root.add_child(run)
	root.add_child(run2)
	await process_frame
	_check(run.multimesh != null and run.multimesh.instance_count == 3, "segment_run: count 3 -> 3 instances in one MultiMesh")
	_check(run.get_child_count(true) == 0 and run.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
			"segment_run: a single node, no shadow (safe under the Ceiling body)")
	var b: AABB = run.call(&"get_run_aabb")
	_check(_near(b.position.x, -1.0, 0.02) and _near(b.size.x, 6.0, 0.02) and _near(b.get_center().y, 0.0, 0.01),
			"segment_run: 3 x 2 m run from x -1 to 5 on the pipe axis (%s)" % b)
	if run.multimesh != null:
		var mesh := run.multimesh.mesh
		var toon := true
		var tinted := false
		for s in mesh.get_surface_count():
			var m := mesh.surface_get_material(s) as BaseMaterial3D
			toon = toon and m != null and (m.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON or m.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED)
			if m != null and m.resource_name.begins_with("TINT"):
				tinted = tinted or (absf(m.albedo_color.r - tint.r) < 0.02 and absf(m.albedo_color.g - tint.g) < 0.02
						and absf(m.albedo_color.b - tint.b) < 0.02)
		_check(toon, "segment_run: every surface is a toon material")
		_check(tinted, "segment_run: the TINT paint takes the run's tint")
		_check(run2.multimesh != null and run2.multimesh.mesh == mesh, "segment_run: runs of the same model + tint share one mesh")
		var t0: Transform3D = run.call(&"copy_transform", 0)
		var t1: Transform3D = run.call(&"copy_transform", 1)
		_check(t0.basis.x.is_equal_approx(Vector3.RIGHT) and t1.basis.x.is_equal_approx(Vector3.LEFT)
				and t1.origin.is_equal_approx(Vector3(2, 0, 0)), "segment_run: copy 1 sits 2 m on, flipped (flip_alternate)")
	run.queue_free()
	run2.queue_free()
	# The other tilers: tray (ceiling mount), elbow, valve, 1 m straight, hangers.
	var expect := {
		"cable_tray.tscn": [2.0, -1.09, 0.0],
		"pipe_segment_1m.tscn": [1.0, -0.16, 0.16],
		"pipe_elbow.tscn": [0.555, -0.16, 0.41],
		"pipe_valve.tscn": [0.5, -0.17, 0.5],
		"pipe_hanger.tscn": [0.04, -0.13, 1.28],
	}
	for file: String in expect:
		var s := load(PROPS + file) as PackedScene
		if not _check(s != null, file + " loads"):
			continue
		var r := s.instantiate() as MultiMeshInstance3D
		root.add_child(r)
		await process_frame
		var e: Array = expect[file]
		var bb: AABB = r.call(&"get_run_aabb")
		_check(r.multimesh != null and r.multimesh.instance_count == 1 and _near(bb.size.x, e[0], 0.03)
				and _near(bb.position.y, e[1], 0.02) and _near(bb.end.y, e[2], 0.02),
				"%s: one copy, %.2f m along X, y %.2f..%.2f (%s)" % [file, e[0], e[1], e[2], bb])
		r.queue_free()
	await process_frame
