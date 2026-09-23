extends SceneTree
## Headless checks for the Blender model pipeline (pipeline agent). Exit code 0 = pass.
##   godot --headless --path . -s res://tools/tests/models_test.gd
## 1. Every res://art/models/*.glb: import settings (tools/blender/build.py defaults), a manifest entry
##    (kind / front / mount), loads, instantiates, Toonify root script, >= 1 MeshInstance3D, bounds
##    0.05-6 m, origin at the declared contact point (floor / ceiling / wall),
##    every surface has a named material, no textures / cameras / lights / animations, Toonify converts
##    every surface to a toon (or unshaded / library) material, instances share materials, TINT recolours.
## 2. Toonify rules on synthetic meshes (independent of which models exist): library swap, finish from
##    roughness, FLAT, TINT shade scaling, emission kept, hand overrides respected, caching, outline hull
##    (outwards, size-aware per part, removable).
## Quick mode (tools/blender/build.py runs it after every import): only "does the imported PackedScene root
## carry the Toonify script", one line per model ("models_test_root: <name> ok|MISSING"):
##   godot --headless --path . -s res://tools/tests/models_test.gd -- --roots-only [--models=a,b]

const MODELS_DIR := "res://art/models"
const MANIFEST := "res://art/models/manifest.json"
const TOONIFY_PATH := "res://scripts/art/toonify.gd"
const KINDS: Array[String] = ["prop", "station", "part", "character", "item"]

var _checks := 0
var _manifest: Dictionary = {}
var _fails: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("  FAIL: ", what)


## The script on the imported PackedScene's root node, read from its SceneState (no instancing, no _ready).
## A model imported with default settings (e.g. by a concurrent Godot before build.py wrote its .import)
## has none: it would render without the toon look.
static func root_script_path(ps: PackedScene) -> String:
	if ps == null:
		return ""
	var st := ps.get_state()
	if st.get_node_count() == 0:
		return ""
	for i in st.get_node_property_count(0):
		if st.get_node_property_name(0, i) == &"script":
			var scr := st.get_node_property_value(0, i) as Script
			return scr.resource_path if scr else ""
	return ""


func _roots_only(only: PackedStringArray) -> void:
	var missing := 0
	var names: PackedStringArray = []
	for f in DirAccess.get_files_at(MODELS_DIR):
		if f.get_extension() == "glb" and (only.is_empty() or f.get_basename() in only):
			names.append(f.get_basename())
	names.sort()
	for n in names:
		var ok := root_script_path(load("%s/%s.glb" % [MODELS_DIR, n]) as PackedScene) == TOONIFY_PATH
		missing += 0 if ok else 1
		print("models_test_root: %s %s" % [n, "ok" if ok else "MISSING"])
	print("models_test: roots-only, %d models, %d without the Toonify root script" % [names.size(), missing])
	quit(1 if missing > 0 else 0)


func _run() -> void:
	var only: PackedStringArray = []
	var roots_only := false
	for a in OS.get_cmdline_user_args():
		if a == "--roots-only":
			roots_only = true
		elif a.begins_with("--models="):
			only = a.trim_prefix("--models=").split(",", false)
	if roots_only:
		_roots_only(only)
		return
	var t0 := Time.get_ticks_msec()
	var holder := Node3D.new()
	root.add_child(holder)
	var files := DirAccess.get_files_at(MODELS_DIR)
	var models: PackedStringArray = []
	for f in files:
		if f.get_extension() == "glb":
			models.append(f.get_basename())
	models.sort()
	_check(not models.is_empty(), "art/models has at least one .glb")
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST)) if FileAccess.file_exists(MANIFEST) else null
	_check(parsed is Dictionary, "art/models/manifest.json exists and parses (written by build.py)")
	if parsed is Dictionary:
		_manifest = parsed
		for k in _manifest:
			_check(k in models, "manifest entry '%s' has a .glb" % k)
	for m in models:
		await _check_model(m, holder)
	await _check_rules(holder)
	holder.queue_free()
	await process_frame
	print("models_test: %d models, %d checks, %d failures (%d ms)" % [models.size(), _checks, _fails.size(),
			Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------ per model
func _check_model(model: String, holder: Node3D) -> void:
	var path := "%s/%s.glb" % [MODELS_DIR, model]
	var tag := model + ": "
	# Import settings written by tools/blender/build.py.
	var cfg := ConfigFile.new()
	_check(cfg.load(path + ".import") == OK, tag + ".import exists")
	_check(str(cfg.get_value("params", "nodes/root_type", "")) == "Node3D", tag + "import root_type Node3D")
	var rs: Variant = cfg.get_value("params", "nodes/root_script", null)
	_check(rs is Script and (rs as Script).resource_path == TOONIFY_PATH, tag + "import root_script is toonify.gd")
	_check(cfg.get_value("params", "meshes/generate_lods", true) == false, tag + "import generate_lods off")
	_check(cfg.get_value("params", "meshes/ensure_tangents", true) == false, tag + "import ensure_tangents off")
	_check(cfg.get_value("params", "meshes/create_shadow_meshes", false) == true, tag + "import shadow meshes on")
	_check(cfg.get_value("params", "animation/import", true) == false, tag + "import animation off")
	_check(cfg.get_value("params", "nodes/use_name_suffixes", true) == false, tag + "import name suffixes off")
	_check(str(cfg.get_value("params", "import_script/path", "")) == "res://tools/blender/gwf_post_import.gd",
			tag + "import script gwf_post_import.gd")

	var ps := load(path) as PackedScene
	_check(ps != null, tag + "loads as PackedScene")
	if ps == null:
		return
	_check(root_script_path(ps) == TOONIFY_PATH, tag + "imported PackedScene root has the Toonify script "
			+ "(missing = imported with stale settings: python3 tools/blender/build.py <family> re-imports it)")
	var a := ps.instantiate() as Node3D
	var b := ps.instantiate() as Node3D
	_check(a != null, tag + "instantiates as Node3D")
	if a == null:
		return
	_check(a is Toonify, tag + "root has the Toonify script")
	var meshes := a.find_children("*", "MeshInstance3D", true, false)
	_check(meshes.size() >= 1, tag + "has >= 1 MeshInstance3D")
	_check(a.find_children("*", "Camera3D", true, false).is_empty(), tag + "no cameras")
	_check(a.find_children("*", "Light3D", true, false).is_empty(), tag + "no lights")
	_check(a.find_children("*", "AnimationPlayer", true, false).is_empty(), tag + "no AnimationPlayer")
	_check(a.find_children("*__*", "", true, false).is_empty(), tag + "no '__' left in node names (post-import ran)")
	# Source materials (before Toonify).
	var tint_count := 0
	var src_ok := true
	var names_ok := true
	var no_tex := true
	for n in meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			src_ok = false
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s)
			if mat == null:
				src_ok = false
				continue
			var nm := Toonify.material_name(mat)
			if nm == "" or nm.begins_with("Material"):
				names_ok = false
			if Toonify.is_tint(mat):
				tint_count += 1
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
				no_tex = false
	_check(src_ok, tag + "every surface has a material")
	_check(names_ok, tag + "materials are named (no Blender default 'Material')")
	_check(no_tex, tag + "flat colours only (no textures)")

	holder.add_child(a)
	holder.add_child(b)
	await process_frame
	# Manifest + bounds + origin at the declared contact point.
	var info: Dictionary = _manifest.get(model, {})
	_check(not info.is_empty(), tag + "has a manifest entry (build it with tools/blender/build.py)")
	var front := str(info.get("front", ""))
	var mount := str(info.get("mount", ""))
	_check(str(info.get("kind", "")) in KINDS and front in ["+z", "-z"], tag + "manifest kind/front valid")
	_check(front == ("-z" if str(info.get("kind", "")) in ["character", "item"] else "+z"), tag + "front matches the kind")
	var box := _aabb(a)
	var big := maxf(box.size.x, maxf(box.size.y, box.size.z))
	_check(big >= 0.05 and big <= 6.0, tag + "bounds within 0.05-6 m (largest %.2f)" % big)
	var mount_ok := true
	match mount:
		"floor":
			mount_ok = absf(box.position.y) < 0.01
		"ceiling":
			mount_ok = absf(box.end.y) < 0.01
		"wall": # back on the wall plane z = 0, body towards the front
			mount_ok = absf(box.position.z) < 0.01 if front == "+z" else absf(box.end.z) < 0.01
		"free":
			mount_ok = true
		_:
			mount_ok = false
	_check(mount_ok, tag + "origin at the %s contact point %s" % [mount, box])
	var msize: Array = info.get("size", [])
	_check(msize.size() == 3 and absf(float(msize[0]) - box.size.x) < 0.02 and absf(float(msize[1]) - box.size.y) < 0.02
			and absf(float(msize[2]) - box.size.z) < 0.02, tag + "manifest size matches the imported bounds")
	# Toonify ran in _ready (root script): every surface is toon / unshaded / library.
	var converted := true
	var shared := true
	var a_meshes := a.find_children("*", "MeshInstance3D", true, false)
	var b_meshes := b.find_children("*", "MeshInstance3D", true, false)
	for i in a_meshes.size():
		var mi := a_meshes[i] as MeshInstance3D
		var mj := b_meshes[i] as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var act := mi.get_active_material(s) as BaseMaterial3D
			if act == null or not (act.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON
					or act.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED):
				converted = false
			var src_name := Toonify.material_name(mi.mesh.surface_get_material(s))
			if src_name.begins_with("toon_") and ResourceLoader.exists("res://art/materials/%s.tres" % src_name):
				if act != load("res://art/materials/%s.tres" % src_name):
					converted = false
			if mi.get_active_material(s) != mj.get_active_material(s):
				shared = false
	_check(converted, tag + "Toonify converted every surface (toon / unshaded / library material)")
	_check(shared, tag + "two instances share the converted materials")
	# TINT: recolour, second colour, clear.
	if tint_count > 0:
		var c1 := Color(0.3, 0.45, 0.6)
		(a as Toonify).tint = c1
		_check(_tint_ok(a, c1), tag + "TINT materials take the tint (x their shade)")
		var c2 := Color(0.6, 0.3, 0.25)
		(a as Toonify).tint = c2
		_check(_tint_ok(a, c2), tag + "TINT recolours live to a second colour")
		(b as Toonify).tint = c2
		_check(_first_tint_mat(a) == _first_tint_mat(b), tag + "same tint -> shared material")
		(a as Toonify).tint = Color(0, 0, 0, 0)
		var neutral := _first_tint_mat(a) as BaseMaterial3D
		_check(neutral != null and neutral.albedo_color.r > 0.3 and is_equal_approx(neutral.albedo_color.r, neutral.albedo_color.g),
				tag + "clearing the tint restores the neutral grey")
	# Outline hull.
	(a as Toonify).outline_width = 0.025
	var hulls := 0
	for n in a_meshes:
		if (n as Node).get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) != null:
			hulls += 1
	_check(hulls >= 1, tag + "outline hull created")
	(a as Toonify).outline_width = 0.0
	await process_frame
	var left := 0
	for n in a_meshes:
		if (n as Node).get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) != null:
			left += 1
	_check(left == 0, tag + "outline hull removed with outline_width = 0")
	a.queue_free()
	b.queue_free()
	await process_frame


func _first_tint_mat(node: Node) -> Material:
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			if Toonify.is_tint(mi.mesh.surface_get_material(s)):
				return mi.get_active_material(s)
	return null


func _tint_ok(node: Node, c: Color) -> bool:
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if src == null or not Toonify.is_tint(src):
				continue
			var act := mi.get_active_material(s) as BaseMaterial3D
			var k := src.albedo_color.get_luminance() / Toonify.TINT_NEUTRAL.get_luminance()
			var want := Color(clampf(c.r * k, 0, 1), clampf(c.g * k, 0, 1), clampf(c.b * k, 0, 1))
			if act == null or act == src or act.diffuse_mode != BaseMaterial3D.DIFFUSE_TOON:
				return false
			if absf(act.albedo_color.r - want.r) > 0.02 or absf(act.albedo_color.g - want.g) > 0.02 \
					or absf(act.albedo_color.b - want.b) > 0.02:
				return false
	return true


static func _aabb(node: Node) -> AABB:
	var box := AABB()
	var first := true
	for n in node.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.has_meta(&"toonify_outline"):
			continue
		var b: AABB = (node as Node3D).global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


# ------------------------------------------------------------------------------------------ rules
func _mat(name: String, color: Color, roughness := 0.45) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = name
	m.albedo_color = color
	m.roughness = roughness
	return m


func _mesh_node(mat: Material, size := 0.5) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = size * 0.5
	sm.height = size
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sm.get_mesh_arrays())
	am.surface_set_material(0, mat)
	mi.mesh = am
	return mi


func _check_rules(holder: Node3D) -> void:
	var node := Node3D.new()
	holder.add_child(node)
	# Finish from roughness.
	var matte := _mesh_node(_mat("custom_matte", Color(0.5, 0.4, 0.3), 0.8))
	var soft := _mesh_node(_mat("custom_soft", Color(0.2, 0.4, 0.6), 0.45))
	var glossy := _mesh_node(_mat("custom_glossy", Color(0.6, 0.6, 0.6), 0.2))
	var rough1 := _mesh_node(_mat("custom_rough", Color(0.6, 0.6, 0.6), 1.0))
	var em_src := _mat("custom_glow", Color(0.5, 0.7, 0.3), 0.45)
	em_src.emission_enabled = true
	em_src.emission = Color(0.1, 0.2, 0.05)
	em_src.emission_energy_multiplier = 0.7
	var glow := _mesh_node(em_src)
	var flat := _mesh_node(_mat("FLAT_sign", Color(0.9, 0.8, 0.2)))
	var tint := _mesh_node(_mat("TINT_body", Toonify.TINT_NEUTRAL))
	var tint_dark := _mesh_node(_mat("TINT_dark.001", Color(Toonify.TINT_NEUTRAL.r * 0.5, Toonify.TINT_NEUTRAL.g * 0.5, Toonify.TINT_NEUTRAL.b * 0.5)))
	var libm := _mesh_node(_mat("toon_rust.002", Color(1, 0, 1)))
	var missing_lib := _mesh_node(_mat("toon_no_such_material", Color(0.3, 0.3, 0.3), 0.8))
	var glass_src := _mat("custom_glass", Color(0.7, 0.8, 0.9, 0.4), 0.2)
	glass_src.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_src.cull_mode = BaseMaterial3D.CULL_DISABLED
	var glass := _mesh_node(glass_src)
	var overridden := _mesh_node(_mat("custom_over", Color(0.1, 0.1, 0.1)))
	var hand := StandardMaterial3D.new()
	overridden.material_override = hand
	var surf_hand := _mesh_node(_mat("custom_surf", Color(0.1, 0.1, 0.1)))
	surf_hand.set_surface_override_material(0, hand)
	for n in [matte, soft, glossy, rough1, glow, flat, tint, tint_dark, libm, missing_lib, glass, overridden, surf_hand]:
		node.add_child(n)
	Toonify.toonify(node)

	var m := matte.get_active_material(0) as StandardMaterial3D
	_check(m.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON and m.specular_mode == BaseMaterial3D.SPECULAR_TOON and m.rim_enabled,
			"rules: converted material is DIFFUSE_TOON + SPECULAR_TOON + rim")
	_check(is_equal_approx(m.roughness, 0.8) and m.albedo_color.is_equal_approx(Color(0.5, 0.4, 0.3)),
			"rules: roughness and albedo kept")
	var ref_matte := Toon.make(Color(0.5, 0.4, 0.3), Toon.Finish.MATTE)
	_check(is_equal_approx(m.metallic_specular, ref_matte.metallic_specular) and is_equal_approx(m.rim, ref_matte.rim),
			"rules: roughness >= 0.65 -> Toon MATTE finish")
	var s_m := soft.get_active_material(0) as StandardMaterial3D
	_check(is_equal_approx(s_m.metallic_specular, Toon.make(Color.WHITE, Toon.Finish.SOFT).metallic_specular),
			"rules: mid roughness -> Toon SOFT finish")
	var g_m := glossy.get_active_material(0) as StandardMaterial3D
	_check(is_equal_approx(g_m.metallic_specular, Toon.make(Color.WHITE, Toon.Finish.GLOSSY).metallic_specular),
			"rules: roughness <= 0.3 -> Toon GLOSSY finish")
	_check((rough1.get_active_material(0) as StandardMaterial3D).roughness <= Toonify.MAX_ROUGHNESS + 0.001,
			"rules: roughness capped below 0.95 (rim wash-out)")
	var e := glow.get_active_material(0) as StandardMaterial3D
	_check(e.emission_enabled and e.emission.is_equal_approx(em_src.emission) and is_equal_approx(e.emission_energy_multiplier, 0.7),
			"rules: emission kept")
	_check((flat.get_active_material(0) as BaseMaterial3D).shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED,
			"rules: FLAT* -> unshaded")
	if ResourceLoader.exists("res://art/materials/toon_rust.tres"):
		_check(libm.get_active_material(0) == load("res://art/materials/toon_rust.tres"),
				"rules: toon_rust(.002) -> the library material itself")
	_check((missing_lib.get_active_material(0) as BaseMaterial3D).diffuse_mode == BaseMaterial3D.DIFFUSE_TOON,
			"rules: unknown toon_* name falls back to a conversion")
	var gl := glass.get_active_material(0) as StandardMaterial3D
	_check(gl.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA and is_equal_approx(gl.albedo_color.a, 0.4)
			and gl.cull_mode == BaseMaterial3D.CULL_DISABLED, "rules: alpha + cull mode kept")
	_check(overridden.get_surface_override_material(0) == null and overridden.material_override == hand,
			"rules: material_override meshes are left alone")
	_check(surf_hand.get_surface_override_material(0) == hand, "rules: hand-set surface overrides are left alone")
	var neutral := tint.get_active_material(0) as StandardMaterial3D
	_check(neutral.albedo_color.is_equal_approx(Toonify.TINT_NEUTRAL), "rules: TINT without a tint stays neutral grey")
	# Tint + shade scaling + cache.
	var c := Color(0.2, 0.5, 0.3)
	Toonify.toonify(node, -1.0, c)
	var t1 := tint.get_active_material(0) as StandardMaterial3D
	_check(t1.albedo_color.is_equal_approx(c), "rules: TINT neutral grey -> exactly the tint")
	var t2 := tint_dark.get_active_material(0) as StandardMaterial3D
	_check(absf(t2.albedo_color.g - c.g * 0.5) < 0.01, "rules: darker TINT grey -> darker shade of the tint")
	_check((matte.get_active_material(0)) == m, "rules: non-TINT surfaces unchanged by a tint")
	Toonify.toonify(node, -1.0, c)
	_check(tint.get_active_material(0) == t1, "rules: repeated toonify is idempotent (cached material)")
	var copy := _mesh_node(tint.mesh.surface_get_material(0))
	node.add_child(copy)
	Toonify.toonify(copy, -1.0, c)
	_check(copy.get_active_material(0) == t1, "rules: same source + tint -> shared material")
	Toonify.toonify(node, 0.5)
	_check(is_equal_approx((matte.get_active_material(0) as StandardMaterial3D).rim, 0.5), "rules: rim override")

	# Outline hull: outwards, size-aware, removable.
	var big := _mesh_node(_mat("custom_big", Color.GRAY), 0.6)
	var small := _mesh_node(_mat("custom_small", Color.GRAY), 0.05)
	node.add_child(big)
	node.add_child(small)
	Toonify.toonify(node)
	Toonify.outline(node, 0.025)
	var hull_node := big.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) as MeshInstance3D
	_check(hull_node != null and hull_node.mesh != null, "outline: hull child on a 0.6 m sphere")
	if hull_node and hull_node.mesh:
		var hv: PackedVector3Array = hull_node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var ok := hv.size() > 0
		for v in hv:
			if absf(v.length() - (0.3 + 0.025)) > 0.004:
				ok = false
				break
		_check(ok, "outline: hull pushed outwards by the thickness")
		_check(hull_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "outline: hull casts no shadow")
		var ink := hull_node.material_override as BaseMaterial3D
		_check(ink != null and ink.cull_mode == BaseMaterial3D.CULL_FRONT and ink.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED
				and not ink.grow, "outline: ink is unshaded, front-culled, no grow")
		# Internal child: hidden from get_children() (and never saved), but find_children() still sees it,
		# so code walking meshes must skip nodes with the "toonify_outline" meta.
		_check(not big.get_children().has(hull_node) and big.get_children(true).has(hull_node)
				and hull_node.has_meta(&"toonify_outline"), "outline: hull is an internal child with the toonify_outline meta")
	_check(small.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) == null, "outline: parts < 0.1 m get no outline")
	_check(glass.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) == null, "outline: transparent surfaces skipped")
	_check(flat.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) == null, "outline: unshaded surfaces skipped")
	_check(is_equal_approx(Toonify.part_outline_factor(0.3), 1.0) and is_equal_approx(Toonify.part_outline_factor(0.15), 0.48)
			and is_equal_approx(Toonify.part_outline_factor(0.05), 0.0), "outline: STYLE size thresholds")
	Toonify.outline(node, 0.0)
	await process_frame
	_check(big.get_node_or_null(NodePath(Toonify.OUTLINE_NODE)) == null, "outline: thickness 0 removes the hull")
	node.queue_free()
	await process_frame
