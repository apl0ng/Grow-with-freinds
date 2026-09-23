extends SceneTree
## Station model hookup checks (3D prop/station modeler). Headless, exit code 0 = pass:
##   godot --headless --path . -s res://tools/tests/models_station_test.gd
## For each station scene that uses a Blender model (tools/blender/models/{shop_cage,deposit_chute,water_tank,
## grow_tray}.py): the model is instanced where MODELING.md section 5 says, no placeholder primitives are left
## beside it, every node the station script drives is there with the right type / pivot, the Label3Ds hang on
## the model's anchors, the colliders are untouched (layer 5, mask 0) and the model's bounds agree with them.
## Script-driven behaviour runs too: the shop tints its jars, the turn-in coin spins in place, the grow plot
## soil sits in the tray under the plant.
## Autoload names are not used directly here (a -s script compiles before the autoloads exist).

const SHOP := "res://scenes/stations/shop_counter.tscn"
const TURN_IN := "res://scenes/stations/turn_in_station.tscn"
const WELL := "res://scenes/stations/well.tscn"
const PLOT := "res://scenes/stations/grow_plot.tscn"

var _checks := 0
var _fails: PackedStringArray = []


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
	await process_frame   # autoloads are in the tree from here on
	var holder := Node3D.new()
	holder.name = "ModelsStationTest"
	root.add_child(holder)
	await _test_shop(holder)
	await _test_turn_in(holder)
	await _test_well(holder)
	await _test_plot(holder)
	holder.queue_free()
	await process_frame
	print("models_station_test: %d checks, %d failures (%d ms)" % [_checks, _fails.size(), Time.get_ticks_msec() - t0])
	quit(1 if _fails.size() > 0 else 0)


# ------------------------------------------------------------------------------------------ helpers
func _spawn(path: String, holder: Node3D) -> Node3D:
	var ps := load(path) as PackedScene
	if not _check(ps != null, "%s loads" % path):
		return null
	var n := ps.instantiate() as Node3D
	holder.add_child(n)
	for i in 3:
		await process_frame
	return n


## The model instance (a Toonify root) at `path` below `station`, instanced from res://art/models/<model>.glb.
func _model(station: Node, path: NodePath, model: String) -> Node3D:
	var m := station.get_node_or_null(path) as Node3D
	var tag := "%s: %s" % [station.name, path]
	if not _check(m != null, tag + " exists"):
		return null
	_check(m is Toonify, tag + " is a Toonify model root")
	_check(m.scene_file_path == "res://art/models/%s.glb" % model, tag + " instances art/models/%s.glb" % model,
			m.scene_file_path)
	_check(m.position.is_zero_approx() and m.basis.is_equal_approx(Basis.IDENTITY),
			tag + " sits at the station origin, unrotated (the model's front is already +Z)")
	_check((m as Toonify).outline_width > 0.0, tag + " has an ink outline")
	return m


## Every MeshInstance3D under `visual` must belong to the model (or be one of the allowed scene nodes).
func _no_placeholders(station: Node, visual: Node, allowed: Array) -> void:
	var stray: PackedStringArray = []
	for n in visual.find_children("*", "MeshInstance3D", true, false):
		if n.has_meta(&"toonify_outline"):
			continue
		var owner_path := String(station.get_path_to(n))
		var in_model := false
		var p: Node = n
		while p != null and p != station:
			if p is Toonify:
				in_model = true
				break
			p = p.get_parent()
		if not in_model and not (n.name in allowed):
			stray.append(owner_path)
	_check(stray.is_empty(), "%s: no placeholder primitives left under Visual" % station.name, ", ".join(stray))


func _body_ok(station: Node, shapes: Array) -> void:
	var body := station.get_node_or_null(^"Body") as StaticBody3D
	if not _check(body != null, "%s: StaticBody3D 'Body'" % station.name):
		return
	_check(body.collision_layer == 5 and body.collision_mask == 0, "%s: collider layer 5 / mask 0" % station.name)
	for s in shapes:
		var cs := body.get_node_or_null(NodePath(s)) as CollisionShape3D
		_check(cs != null and cs.shape != null, "%s: Body/%s kept" % [station.name, s])


## AABB of the model's meshes in `space` coordinates (outline hulls skipped).
func _aabb(model: Node3D, space: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in model.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.has_meta(&"toonify_outline") or not mi.is_visible_in_tree():
			continue
		var b: AABB = space.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


func _label(station: Node, path: String, contains := "") -> Label3D:
	var l := station.get_node_or_null(path) as Label3D
	_check(l != null and (contains == "" or l.text.contains(contains)), "%s: Label3D %s%s" % [station.name, path,
			(" says '%s'" % contains) if contains != "" else ""], l.text if l != null else "missing")
	return l


func _has_tint_surface(mi: MeshInstance3D) -> bool:
	if mi == null or mi.mesh == null:
		return false
	for s in mi.mesh.get_surface_count():
		if Toonify.is_tint(mi.mesh.surface_get_material(s)):
			return true
	return false


# ------------------------------------------------------------------------------------------ shop
func _test_shop(holder: Node3D) -> void:
	var st := await _spawn(SHOP, holder)
	if st == null:
		return
	var model := _model(st, ^"Visual", "shop_cage")
	if model == null:
		return
	_no_placeholders(st, model, [])
	_body_ok(st, ["CounterShape", "KeeperShape"])
	_check(st.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") != null, "shop: the Boss is still behind the counter")
	var jars := st.get_node_or_null(^"Visual/Jars")
	_check(jars != null and jars.get_child_count() == 3, "shop: Visual/Jars holds exactly 3 jars (the script tints them in order)")
	for i in 3:
		var jar := "Visual/Jars/Jar%d" % (i + 1)
		var fill := st.get_node_or_null(jar + "/Fill") as MeshInstance3D
		_check(fill != null and _has_tint_surface(fill), "shop: %s/Fill is a TINT mesh" % jar)
		_check(fill != null and fill.material_override != null, "shop: the script coloured %s/Fill" % jar)
		_label(st, jar + "/PriceTag", "$")
		var face := st.get_node_or_null("Visual/Badges/Badge%d/Face" % (i + 1)) as MeshInstance3D
		_check(face != null and _has_tint_surface(face) and face.material_override != null,
				"shop: Badge%d/Face is TINT and coloured by the script" % (i + 1))
		if i > 0:
			var prev := st.get_node("Visual/Jars/Jar%d" % i) as Node3D
			_check((st.get_node(jar) as Node3D).position.x > prev.position.x, "shop: jars run left to right (price order)")
	_label(st, "Visual/Sign/Text", "SUPPLY")
	_label(st, "Visual/PriceBoard/Chalk", "NO REFUNDS")
	_label(st, "Visual/Register/ScreenText", "$")
	_label(st, "Visual/PayPlate/PayText", "PAY")
	var box := _aabb(model, st)
	_check(absf(box.size.x - 3.4) < 0.08 and box.position.y > -0.01 and box.position.y < 0.01,
			"shop: model 3.4 m wide on the floor like the counter collider", str(box))
	_check(box.end.z < 0.7 and box.end.y < 3.1, "shop: nothing pokes out past the counter front / above 3.1 m", str(box))
	# the counter top the collider promises (1.04) is where the model's slab is: jars stand on it
	var jar1 := st.get_node(^"Visual/Jars/Jar1") as Node3D
	_check(absf(jar1.position.y - 1.02) < 0.03, "shop: jars stand on the counter top (y 1.02)", str(jar1.position))
	var anchor := st.get_node(^"ShopkeeperAnchor") as Node3D
	_check(anchor.position.z < -0.5 and absf(anchor.position.y - 0.2) < 0.01, "shop: the Boss's step height/place kept")
	st.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ turn-in
func _test_turn_in(holder: Node3D) -> void:
	var st := await _spawn(TURN_IN, holder)
	if st == null:
		return
	var model := _model(st, ^"Visual", "deposit_chute")
	if model == null:
		return
	_no_placeholders(st, model, [])
	_body_ok(st, ["Shape"])
	_label(st, "SoldLabel")
	_check(st.get_node_or_null(^"SoldLabel").get_parent() == st, "turn-in: SoldLabel stays outside Visual (no squash)")
	_label(st, "Visual/Sign/Text", "NO REFUNDS")
	_label(st, "Visual/Emblem/Dollar", "$")
	_label(st, "Visual/Sign/Coin/FrontMark", "$")
	_label(st, "Visual/Sign/Coin/BackMark", "$")
	var sign := st.get_node_or_null(^"Visual/Sign") as Node3D
	var coin := st.get_node_or_null(^"Visual/Sign/Coin") as Node3D
	if _check(sign != null and coin != null, "turn-in: Visual/Sign/Coin exists (the script spins it)"):
		_check(sign.basis.is_equal_approx(Basis.IDENTITY), "turn-in: Sign is unrotated (the coin spins about the vertical)")
		var cm := coin as MeshInstance3D
		_check(cm != null and cm.get_aabb().get_center().length() < 0.01, "turn-in: the coin's pivot is its centre (spins in place)")
		var b0 := coin.basis
		var p0 := coin.global_position
		for i in 10:
			await process_frame
		_check(not coin.basis.is_equal_approx(b0) and coin.global_position.distance_to(p0) < 0.001,
				"turn-in: the script spins the coin in place")
	var box := _aabb(model, st)
	_check(absf(box.size.x - 1.6) < 0.06 and box.size.z < 1.62 and absf(box.position.y) < 0.01,
			"turn-in: model footprint ~1.6 x 1.4-1.6 on the floor", str(box))
	_check(box.end.y < 2.9, "turn-in: model stays under the floating sold label (2.95)", str(box))
	st.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ well
func _test_well(holder: Node3D) -> void:
	var st := await _spawn(WELL, holder)
	if st == null:
		return
	var model := _model(st, ^"Visual/Model", "water_tank")
	if model == null:
		return
	_no_placeholders(st, st.get_node(^"Visual"), ["Water"])
	_body_ok(st, ["RingShape", "PostLShape", "PostRShape", "RoofShape"])
	var water := st.get_node_or_null(^"%Water") as MeshInstance3D
	var bucket := st.get_node_or_null(^"%Bucket") as Node3D
	var spots := st.get_node_or_null(^"%CanSpots")
	_check(water != null and water.mesh != null, "well: %Water is a MeshInstance3D water surface")
	_check(bucket != null, "well: %Bucket exists (the script bounces it)")
	_check(spots != null and spots.get_child_count() == 4, "well: %CanSpots holds 4 markers")
	_check((st.get_node(^"Visual") as Node).unique_name_in_owner, "well: Visual keeps its %unique name")
	var box := _aabb(model, st)
	_check(box.size.x < 2.65 and box.size.z < 1.9 and absf(box.position.y) < 0.01 and box.end.y < 2.9,
			"well: model fits the roof box / ring collider envelope", str(box))
	if water != null:
		# the water disc sits inside the basin (under its rim, above its floor)
		var basin_top := 0.575
		_check(water.position.y < basin_top - 0.1 and water.position.y > 0.15 and (water.mesh as CylinderMesh).top_radius < 0.86,
				"well: %Water sits inside the basin", str(water.position))
	if bucket != null:
		var pail := bucket.get_node_or_null(^"Pail") as Node3D
		if _check(pail is Toonify and pail.scene_file_path == "res://art/models/water_tank_bucket.glb",
				"well: %Bucket holds the water_tank_bucket model"):
			var pb := _aabb(pail, bucket)
			_check(absf(pb.end.y) < 0.02, "well: the pail hangs from %Bucket's origin (its handle apex)", str(pb))
			_check(bucket.position.y - pb.size.y > 0.6, "well: the hanging pail clears the basin rim", str(bucket.position))
		for m in spots.get_children():
			var p := (m as Node3D).position
			_check(Vector2(p.x, p.z).length() > 1.05, "well: %s stays clear of the tank's footprint" % m.name, str(p))
	_label(st, "Visual/LabelWater", "WATER")
	st.queue_free()
	await process_frame


# ------------------------------------------------------------------------------------------ grow plot
func _test_plot(holder: Node3D) -> void:
	var st := await _spawn(PLOT, holder)
	if st == null:
		return
	var model := _model(st, ^"Visual/Model", "grow_tray")
	if model == null:
		return
	_no_placeholders(st, st.get_node(^"Visual"), ["SoilBed", "SoilMound", "Fill", "Stake", "Card"])
	_body_ok(st, ["Shape", "PlantShape"])
	for n in ["%SoilBed", "%SoilMound", "%Fill", "%Card"]:
		_check(st.get_node_or_null(NodePath(n)) is MeshInstance3D, "plot: %s is a MeshInstance3D" % n)
	for n in ["%FillPivot", "%Tag", "%Plant"]:
		_check(st.get_node_or_null(NodePath(n)) is Node3D, "plot: %s exists" % n)
	_check(st.get_node_or_null(^"Visual/WaterGauge/FillPivot") != null, "plot: Visual/WaterGauge/FillPivot path kept")
	var box := _aabb(model, st)
	_check(box.size.x <= 1.5 and box.size.z <= 1.52 and absf(box.position.y) < 0.01,
			"plot: tray fits the 1.46 m collider (+ drip line)", str(box))
	var bed := st.get_node(^"%SoilBed") as MeshInstance3D
	var mound := st.get_node(^"%SoilMound") as MeshInstance3D
	var plant := st.get_node(^"%Plant") as Node3D
	var bed_box: AABB = bed.transform * bed.get_aabb()
	var mound_box: AABB = mound.transform * mound.get_aabb()
	_check(bed_box.end.y > 0.42 and bed_box.end.y < 0.49 and bed_box.size.x < 1.34,
			"plot: the soil bed fills the tub inside its lip", str(bed_box))
	_check(plant.position.y > bed_box.end.y and plant.position.y < mound_box.end.y + 0.01,
			"plot: the plant stands in the soil mound", "%s vs %s" % [plant.position, mound_box])
	var fill := st.get_node(^"%Fill") as MeshInstance3D
	var fb: AABB = st.global_transform.affine_inverse() * fill.global_transform * fill.get_aabb()
	_check(fb.end.z < 0.76 and fb.position.z > 0.62, "plot: the gauge bar lies in the tray's front slot", str(fb))
	st.queue_free()
	await process_frame
