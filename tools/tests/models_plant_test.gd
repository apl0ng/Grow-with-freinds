extends SceneTree
## Plant model + hookup checks (plant modeler). Headless, exit code 0 = pass:
##   godot --headless --path . -s res://tools/tests/models_plant_test.gd
## 1. Every stage model (art/models/plant_*.glb, built by tools/blender/models/plant.py): loads, Toonify root, a
##    Leaves mesh in library greens (never TINT), tris <= 6000, height / footprint in the stage's range, standing
##    on the soil point (origin); flowering Buds is TINT (+ cream pistils), READY Buds holds one mesh per cola with
##    its origin at the cola's base; the wilted variants are lower and use toon_leaf_dry.
## 2. plant_visual.tscn instances those models as the stage nodes (+ a Dry child per growing stage), outlined,
##    and holds no dummy nodes (every MeshInstance3D has a mesh; Ready/Buds holds only the colas).
## 3. Strain tint: for every strain in data/balance.tres, every TINT_bud surface shows exactly Toon.grade(seed
##    colour), TINT_frost a lighter shade of it, the leaves stay untinted; get_tint_material() (the plot's tag card)
##    is the material the READY crown cola renders its calyxes with (graded too).
## 4. Dry: set_dry swaps in the wilted model and slumps Tilt, watering swaps back; animated, it crossfades and
##    ends with exactly one model on screen.
## 5. Through scenes/stations/grow_plot.tscn exactly like the game (synced setters + server_plant): the right stage
##    model shows, the READY colas pulse in place and stop when harvested, the plant stands in the soil.
## Autoloads are reached through /root (a -s script compiles before they exist); game classes are duck-typed.

const PLOT := "res://scenes/stations/grow_plot.tscn"
const VISUAL := "res://scenes/stations/plant_visual.tscn"
const MODELS_DIR := "res://art/models/"
const BUDGET := 6000
## name: [min height, max height, max footprint, buds ("" | "mesh" | "colas"), leaf material, dry of]
const SPECS := {
	"plant_seedling": [0.2, 0.4, 0.45, "", "toon_lime", ""],
	"plant_seedling_dry": [0.08, 0.3, 0.45, "", "toon_leaf_dry", "plant_seedling"],
	"plant_vegetative": [0.5, 0.75, 1.1, "", "toon_leaf", ""],
	"plant_vegetative_dry": [0.3, 0.7, 1.1, "", "toon_leaf_dry", "plant_vegetative"],
	"plant_flowering": [0.8, 1.05, 1.15, "mesh", "toon_leaf", ""],
	"plant_flowering_dry": [0.5, 1.0, 1.2, "mesh", "toon_leaf_dry", "plant_flowering"],
	"plant_ready": [0.95, 1.2, 1.2, "colas", "toon_leaf", ""],
}
const STAGE_NODES: Array[String] = ["", "Seedling", "Vegetative", "Flowering", "Ready"]
const GROW := "Tilt/Bouncer/Grow/"
const PULSE_META := &"_juice_pulsing" # Juice.META_PULSE
## Longer than PlantVisual.WILT_TIME (0.4 s): the dry <-> watered crossfade is over by then.
const BLEND_WAIT := 0.6

var _checks := 0
var _fails: PackedStringArray = []
var _heights := {}


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String, detail := "") -> bool:
	_checks += 1
	if not ok:
		_fails.append(what)
		print("  FAIL: ", what, ("  (" + detail + ")") if detail != "" else "")
	return ok


func _run() -> void:
	var t0 := Time.get_ticks_msec()
	await process_frame # autoloads are in the tree from here on
	var holder := Node3D.new()
	holder.name = "ModelsPlantTest"
	root.add_child(holder)
	for m in SPECS:
		await _test_model(m, holder)
	await _test_scene(holder)
	await _test_tint(holder)
	await _test_dry(holder)
	await _test_plot(holder)
	holder.queue_free()
	# The plot played its plant / grow / water sounds: stop them and let a few frames pass (STYLE.md section 7),
	# else quitting mid-sound reports leaked instances.
	var sfx := root.get_node_or_null(^"/root/Sfx")
	if sfx != null:
		sfx.call(&"stop_all")
	await create_timer(0.25).timeout # the audio thread releases the stopped playbacks
	for i in 6:
		await process_frame
	print("models_plant_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------ helpers
static func _meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and not n.has_meta(&"toonify_outline"):
		out.append(n)
	for c in n.find_children("*", "MeshInstance3D", true, false):
		if not c.has_meta(&"toonify_outline"):
			out.append(c as MeshInstance3D)
	return out


static func _tris(n: Node) -> int:
	var t := 0
	for mi in _meshes(n):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX]
			t += (idx.size() if not idx.is_empty() else (arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return t


## AABB of the visible meshes of `n` in `space` coordinates.
static func _aabb(n: Node3D, space: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(n):
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b: AABB = space.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## Source (Blender) material names of a mesh's surfaces.
static func _mat_names(mi: MeshInstance3D) -> PackedStringArray:
	var out: PackedStringArray = []
	if mi.mesh != null:
		for s in mi.mesh.get_surface_count():
			out.append(Toonify.material_name(mi.mesh.surface_get_material(s)))
	return out


static func _grade(c: Color) -> Color:
	return Toon.grade(c)


## Colours equal up to the float noise of the glTF round trip of the neutral TINT grey (~1e-4).
static func _near(a: Color, b: Color, eps := 0.003) -> bool:
	return absf(a.r - b.r) < eps and absf(a.g - b.g) < eps and absf(a.b - b.b) < eps and absf(a.a - b.a) < eps


func _spawn(path: String, holder: Node3D) -> Node3D:
	var ps := load(path) as PackedScene
	if not _check(ps != null, "%s loads" % path):
		return null
	var n := ps.instantiate() as Node3D
	holder.add_child(n)
	for i in 2:
		await process_frame
	return n


func _free(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ 1. models
func _test_model(model: String, holder: Node3D) -> void:
	var spec: Array = SPECS[model]
	var tag := model + ": "
	var inst := await _spawn(MODELS_DIR + model + ".glb", holder)
	if inst == null:
		return
	_check(inst is Toonify, tag + "root is a Toonify node")
	var leaves := inst.get_node_or_null(^"Leaves") as MeshInstance3D
	if _check(leaves != null, tag + "has a Leaves mesh"):
		var names := _mat_names(leaves)
		var tinted := false
		for nm in names:
			tinted = tinted or nm.begins_with("TINT")
		_check(not tinted, tag + "Leaves never use a TINT material (leaves stay green)", ", ".join(names))
		_check(spec[4] in names, tag + "Leaves use %s" % spec[4], ", ".join(names))
		if model.ends_with("_dry"):
			_check(not ("toon_leaf" in names), tag + "no healthy green leaves when wilted (stems stay lime)",
					", ".join(names))
	var tris := _tris(inst)
	_check(tris > 300 and tris <= BUDGET, tag + "tris %d within the %d budget" % [tris, BUDGET])
	var box := _aabb(inst, inst)
	_heights[model] = box.end.y
	_check(absf(box.position.y) < 0.012, tag + "stands on the soil point (lowest y ~ 0)", str(box))
	_check(box.end.y >= spec[0] and box.end.y <= spec[1], tag + "height %.2f in %.2f..%.2f" % [box.end.y, spec[0], spec[1]])
	_check(maxf(box.size.x, box.size.z) <= spec[2], tag + "footprint %.2f x %.2f fits the tray" % [box.size.x, box.size.z])
	var c := box.get_center()
	_check(Vector2(c.x, c.z).length() < 0.25 * maxf(box.size.x, box.size.z) + 0.03, tag + "footprint centred on the stem",
			str(c))
	var dry_of: String = spec[5]
	if dry_of != "" and _heights.has(dry_of):
		_check(box.end.y < _heights[dry_of], tag + "wilted plant is lower than the healthy one (%.2f < %.2f)" % [
				box.end.y, _heights[dry_of]])
	match spec[3]:
		"mesh":
			var buds := inst.get_node_or_null(^"Buds") as MeshInstance3D
			if _check(buds != null, tag + "Buds mesh"):
				var names := _mat_names(buds)
				_check("TINT_bud" in names and "toon_cream" in names, tag + "Buds = TINT_bud calyxes + cream pistils",
						", ".join(names))
		"colas":
			var buds := inst.get_node_or_null(^"Buds") as Node3D
			if _check(buds != null and not (buds is MeshInstance3D), tag + "Buds node (one child mesh per cola)"):
				var colas := buds.get_children().filter(func(x: Node) -> bool: return x is MeshInstance3D)
				_check(colas.size() >= 5 and buds.get_node_or_null(^"ColaTop") != null,
						tag + "Buds holds ColaTop + branch colas (%d)" % colas.size())
				for cola: MeshInstance3D in colas:
					var names := _mat_names(cola)
					_check("TINT_bud" in names and "TINT_frost" in names and "toon_rust" in names,
							tag + "%s = TINT_bud + TINT_frost + rust pistils" % cola.name, ", ".join(names))
					# origin at the cola's base: the mesh grows away from its own origin (pulses in place)
					var b := cola.get_aabb()
					_check(b.has_point(Vector3.ZERO) or b.grow(0.03).has_point(Vector3.ZERO) or b.position.y > -0.03,
							tag + "%s origin sits at its base" % cola.name, str(b))
					_check(cola.position.y > 0.4, tag + "%s hangs high on the plant" % cola.name, str(cola.position))
		_:
			_check(inst.get_node_or_null(^"Buds") == null, tag + "no buds before flowering")
	await _free(inst)


# ------------------------------------------------------------------------------------------ 2. scene
func _test_scene(holder: Node3D) -> void:
	var pv := await _spawn(VISUAL, holder)
	if pv == null:
		return
	_check(pv.get_script() != null and pv.get_script().resource_path == "res://scripts/stations/plant_visual.gd",
			"plant_visual.tscn root runs plant_visual.gd (PlantVisual)")
	for i in range(1, 5):
		var st := pv.get_node_or_null(GROW + STAGE_NODES[i]) as Node3D
		var model := "plant_" + STAGE_NODES[i].to_lower()
		if not _check(st is Toonify and st.scene_file_path == MODELS_DIR + model + ".glb",
				"%s instances %s.glb" % [STAGE_NODES[i], model], st.scene_file_path if st else "missing"):
			continue
		_check((st as Toonify).outline_width > 0.0, "%s has an ink outline" % STAGE_NODES[i])
		_check(st.position.is_zero_approx() and st.basis.is_equal_approx(Basis.IDENTITY),
				"%s sits unrotated at the plant origin (front already +Z)" % STAGE_NODES[i])
		var dry := st.get_node_or_null(^"Dry") as Node3D
		if i < 4:
			_check(dry is Toonify and dry.scene_file_path == MODELS_DIR + model + "_dry.glb",
					"%s/Dry instances %s_dry.glb" % [STAGE_NODES[i], model])
		else:
			_check(dry == null, "Ready has no wilted variant (READY never drinks)")
	var dummies: PackedStringArray = []
	for mi in pv.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh == null:
			dummies.append(str(pv.get_path_to(mi)))
	_check(dummies.is_empty(), "no mesh-less dummy MeshInstance3D in plant_visual.tscn", ", ".join(dummies))
	var ready_buds := pv.get_node(GROW + "Ready/Buds")
	var not_colas := ready_buds.get_children().filter(func(x: Node) -> bool:
		return not (x is MeshInstance3D and (x as MeshInstance3D).mesh != null))
	_check(ready_buds.get_node_or_null(^"BudTop") == null and not_colas.is_empty(), "Ready/Buds holds only cola meshes (no BudTop carrier)")
	for n in ["%Tilt", "%Bouncer", "%Grow", "%DryIndicator", "%Bob"]:
		_check(pv.get_node_or_null(NodePath(n)) is Node3D, "PlantVisual keeps %s" % n)
	for f in ["set_stage", "set_growth", "set_tint", "get_tint", "get_tint_material", "set_dry", "is_dry", "bounce",
			"get_top_global_position", "get_wilt", "is_wilt_blending"]:
		_check(pv.has_method(f), "PlantVisual API keeps %s()" % f)
	await _free(pv)


# ------------------------------------------------------------------------------------------ 3. tint
func _test_tint(holder: Node3D) -> void:
	var pv := await _spawn(VISUAL, holder)
	if pv == null:
		return
	var config := root.get_node_or_null(^"/root/Config")
	var seeds: Array = config.get(&"balance").get(&"seeds") if config != null else []
	_check(seeds.size() >= 3, "data/balance.tres has strains to test (%d)" % seeds.size())
	var crown := pv.get_node(GROW + "Ready/Buds/ColaTop") as MeshInstance3D
	var crown_surface := -1
	for s in crown.mesh.get_surface_count():
		if Toonify.material_name(crown.mesh.surface_get_material(s)) == "TINT_bud":
			crown_surface = s
	_check(crown_surface >= 0, "the READY crown cola has a TINT_bud surface")
	for sd in seeds:
		var col: Color = sd.get(&"color")
		var want := _grade(col)
		pv.call(&"set_tint", col)
		var bud_ok := true
		var frost_ok := true
		var leaf_ok := true
		var bud_count := 0
		var detail := ""
		for mi in _meshes(pv):
			if mi.mesh == null:
				continue
			for s in mi.mesh.get_surface_count():
				var nm := Toonify.material_name(mi.mesh.surface_get_material(s))
				var m := mi.get_active_material(s) as BaseMaterial3D
				if m == null:
					continue
				if nm == "TINT_bud":
					bud_count += 1
					if not _near(m.albedo_color, want):
						bud_ok = false
						detail = "%s %s != %s" % [mi.name, m.albedo_color, want]
				elif nm == "TINT_frost":
					# a lighter shade of the same colour (Toonify: tint x luminance ratio, clamped)
					var lighter := m.albedo_color.r >= want.r - 0.002 and m.albedo_color.g >= want.g - 0.002 \
							and m.albedo_color.b >= want.b - 0.002 and m.albedo_color.v > want.v
					frost_ok = frost_ok and lighter
				elif nm.begins_with("toon_leaf") or nm == "toon_lime":
					leaf_ok = leaf_ok and m.resource_path.begins_with("res://art/materials/toon_")
		var sid := String(sd.get(&"id"))
		_check(bud_count >= 7, "%s: flowering (+ wilted) buds and every READY cola have TINT_bud surfaces (%d)" % [
				sid, bud_count])
		_check(bud_ok, "%s: every TINT_bud surface shows Toon.grade(seed colour)" % sid, detail)
		_check(frost_ok, "%s: TINT_frost is a lighter shade of the same strain colour" % sid)
		_check(leaf_ok, "%s: leaves keep their library materials (untinted)" % sid)
		var tm := pv.call(&"get_tint_material") as BaseMaterial3D
		_check(tm != null and _near(tm.albedo_color, want) and crown_surface >= 0 and crown.get_active_material(crown_surface) == tm,
				"%s: get_tint_material() (tag card) is the crown cola's graded TINT_bud material" % sid,
				str(tm.albedo_color if tm else Color.BLACK))
	await _free(pv)


# ------------------------------------------------------------------------------------------ 4. dry
func _test_dry(holder: Node3D) -> void:
	var pv := await _spawn(VISUAL, holder)
	if pv == null:
		return
	var tilt := pv.get_node(^"%Tilt") as Node3D
	for i in range(1, 4):
		var st := pv.get_node(GROW + STAGE_NODES[i]) as Node3D
		pv.call(&"set_stage", i, false)
		pv.call(&"set_dry", false, false)
		var leaves := st.get_node(^"Leaves") as Node3D
		var dry := st.get_node(^"Dry") as Node3D
		_check(st.visible and leaves.visible and not dry.visible, "%s watered: healthy model shown" % STAGE_NODES[i])
		var healthy_box := _aabb(st, st) # model space: no growth scale, no slump
		pv.call(&"set_dry", true, false)
		_check(not leaves.visible and dry.visible, "%s dry: the wilted model replaces the healthy one" % STAGE_NODES[i])
		var buds := st.get_node_or_null(^"Buds") as Node3D
		if buds != null:
			_check(not buds.visible, "%s dry: the healthy buds hide too (the wilted model has its own)" % STAGE_NODES[i])
		_check(tilt.rotation.length() > 0.1, "%s dry: the plant slumps (Tilt %s)" % [STAGE_NODES[i], tilt.rotation])
		_check((pv.get_node(^"%DryIndicator") as Node3D).visible, "%s dry: DRY indicator shown" % STAGE_NODES[i])
		var dry_box := _aabb(st, st)
		_check(dry_box.end.y < healthy_box.end.y, "%s dry: visibly lower (%.2f < %.2f)" % [STAGE_NODES[i], dry_box.end.y,
				healthy_box.end.y])
		pv.call(&"set_dry", false, false)
		_check(leaves.visible and not dry.visible and tilt.rotation.is_zero_approx() and not bool(pv.call(&"is_wilt_blending")),
				"%s watered again: healthy model back, upright, nothing blending" % STAGE_NODES[i])
	# Animated (a live change): a crossfade that ends with exactly one model, both directions.
	var fl := pv.get_node(GROW + "Flowering") as Node3D
	var fl_parts: Array[Node3D] = [fl.get_node(^"Leaves") as Node3D, fl.get_node(^"Buds") as Node3D]
	var fl_dry := fl.get_node(^"Dry") as Node3D
	pv.call(&"set_stage", 3, false)
	for to_dry in [true, false]:
		pv.call(&"set_dry", to_dry, true)
		var both := false
		var t0 := Time.get_ticks_msec()
		while bool(pv.call(&"is_wilt_blending")) and Time.get_ticks_msec() - t0 < 1500:
			await process_frame
			both = both or (fl_parts[0].visible and fl_dry.visible)
		var healthy_on := fl_parts[0].visible and fl_parts[1].visible
		_check(both and not bool(pv.call(&"is_wilt_blending")) and fl_dry.visible == to_dry and healthy_on != to_dry,
				"Flowering %s animated: crossfade, then only the %s model" % ["drying" if to_dry else "watering",
				"wilted" if to_dry else "healthy"])
		var rest := fl_dry if to_dry else fl_parts[0]
		_check(rest.transform.is_equal_approx(Transform3D.IDENTITY), "Flowering: the shown model ends at its rest transform")
	await _free(pv)


# ------------------------------------------------------------------------------------------ 5. through the plot
func _visible_stage(plant: Node) -> int:
	var v := 0
	for i in range(1, 5):
		if (plant.get_node(GROW + STAGE_NODES[i]) as Node3D).visible:
			v = i if v == 0 else -1
	return v


func _test_plot(holder: Node3D) -> void:
	var plot := await _spawn(PLOT, holder)
	if plot == null:
		return
	plot.set_process(false)
	var plant := plot.get_node(^"%Plant") as Node3D
	_check(plant.get_script() != null and plant.scene_file_path == VISUAL, "grow_plot's %Plant is plant_visual.tscn")
	_check(plant.position.is_equal_approx(Vector3(0, 0.49, 0)), "the plant stands on the soil (0, 0.49, 0)",
			str(plant.position))
	_check(_visible_stage(plant) == 0, "EMPTY plot shows no plant")
	_check(bool(plot.call(&"server_plant", &"purple")), "server_plant(purple) on an empty plot")
	await process_frame
	_check(_visible_stage(plant) == 1, "planting shows the seedling model")
	var card := plot.get_node(^"%Card") as MeshInstance3D
	var tint_mat := plant.call(&"get_tint_material") as Material
	var config := root.get_node(^"/root/Config")
	var purple: Color = config.get(&"balance").call(&"get_seed", &"purple").get(&"color")
	_check(tint_mat != null and card.material_override == tint_mat and _near((tint_mat as BaseMaterial3D).albedo_color, _grade(purple)),
			"the plot's tag card shares the plant's graded strain material")
	var seedling := plant.get_node(GROW + "Seedling") as Toonify
	_check(_near(seedling.tint, _grade(purple)), "stage models tinted with Toon.grade(purple)")
	for st in [2, 3, 4]:
		plot.set(&"stage", st)
		await process_frame
		_check(_visible_stage(plant) == st, "stage %d via the synced setter shows %s" % [st, STAGE_NODES[st]])
	# READY: every cola pulses in place (its own origin at its base), the carrier does not
	var juice := root.get_node(^"/root/Juice")
	var buds := plant.get_node(GROW + "Ready/Buds") as Node3D
	var colas := buds.get_children().filter(func(x: Node) -> bool: return x is MeshInstance3D)
	var pulsing := 0
	for cola: Node3D in colas:
		pulsing += 1 if cola.has_meta(PULSE_META) else 0
	_check(colas.size() >= 5 and pulsing == colas.size() and colas.size() == buds.get_child_count(),
			"READY: every child of Ready/Buds is a cola and pulses (%d / %d)" % [pulsing, colas.size()])
	_check((buds.get_node(^"ColaTop") as Node3D).is_visible_in_tree(), "READY: the crown cola whose material the tag uses is on screen")
	await create_timer(0.3).timeout
	var moved := false
	for cola: Node3D in colas:
		moved = moved or not cola.scale.is_equal_approx(Vector3.ONE)
	_check(moved, "READY: the colas breathe (scale changes)")
	var top: Vector3 = plant.call(&"get_top_global_position")
	_check(top.y > plot.global_position.y + 1.3, "READY top position for bursts is above the colas (%.2f)" % top.y)
	plot.set(&"stage", 0)
	await process_frame
	var still := true
	for cola: Node3D in colas:
		still = still and cola.scale.is_equal_approx(Vector3.ONE)
	_check(_visible_stage(plant) == 0 and still, "harvest (EMPTY): plant hidden, colas stopped at rest scale")
	# dry through the plot: a growing plant without water wilts, watering revives it
	plot.call(&"server_plant", &"golden")
	plot.set(&"stage", 2)
	plot.set(&"water", 0.0)
	await process_frame
	var veg := plant.get_node(GROW + "Vegetative") as Node3D
	_check((veg.get_node(^"Dry") as Node3D).visible and not (veg.get_node(^"Leaves") as Node3D).visible,
			"a thirsty vegetative plant shows its wilted model")
	plot.call(&"server_water", 1.0)
	await process_frame
	_check(bool(plant.call(&"is_wilt_blending")) and (veg.get_node(^"Leaves") as Node3D).visible,
			"watering crossfades: the healthy model is already swelling back in")
	await create_timer(BLEND_WAIT).timeout
	_check(not (veg.get_node(^"Dry") as Node3D).visible and (veg.get_node(^"Leaves") as Node3D).visible,
			"watering brings the healthy model back (only it, once the blend is over)")
	if juice != null:
		juice.call(&"stop", plant)
	await _free(plot)
