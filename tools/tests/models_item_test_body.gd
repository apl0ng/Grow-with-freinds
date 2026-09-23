extends Node
## Body of the held-item model test (item modeler), launched by tools/tests/models_item_test.gd.
## Items are built the way ItemManager._spawn_item builds them (instantiate, apply_props before the node enters the
## tree) and then changed through their synced setters (the path remote values take), without a world.
## Prints PASS/FAIL lines and quits with 0 (all passed) or 1.

const CAN_SCENE := "res://scenes/items/watering_can.tscn"
const PACKET_SCENE := "res://scenes/items/seed_packet.tscn"
const PRODUCT_SCENE := "res://scenes/items/product.tscn"
const PLAYER_SCENE := "res://scenes/player/player.tscn"
const MAX_TRIS := 3000
## Half-size of the screen-centre box (fraction of the half screen) a held item must stay out of.
const CROSSHAIR_BOX := 0.06
const SCREEN_ASPECT := 16.0 / 9.0

var _passes := 0
var _fails := 0
var _holder: Node3D


func _ready() -> void:
	_run()


func check(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
		print("PASS: " + what)
	else:
		_fails += 1
		print("FAIL: " + what)


func _run() -> void:
	await get_tree().process_frame
	Juice.enabled = false # pop_in / bounce snap to their final state: bounds are measured at rest scale
	_holder = Node3D.new()
	_holder.name = "Items"
	add_child(_holder)
	await _test_can()
	await _test_packet()
	await _test_product()
	await _test_hold_poses()
	_holder.queue_free()
	await get_tree().process_frame
	print("models_item_test: %d passed, %d failed" % [_passes, _fails])
	get_tree().quit(0 if _fails == 0 else 1)


# ----------------------------------------------------------------------------------------------- helpers
## ItemManager._spawn_item's order: props first, then into the tree (_ready -> _refresh_visuals).
func _spawn(path: String, props: Dictionary) -> Item:
	var item := (load(path) as PackedScene).instantiate() as Item
	item.apply_props(props)
	_holder.add_child(item)
	await get_tree().process_frame
	return item


static func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for n in node.find_children("*", "MeshInstance3D", true, false):
		if not n.has_meta(&"toonify_outline"):
			out.append(n as MeshInstance3D)
	return out


static func _tris(node: Node) -> int:
	var t := 0
	for mi in _meshes(node):
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			t += (idx.size() if idx.size() > 0 else verts.size()) / 3
	return t


## Bounds of every model mesh in `space`'s coordinates (visible or not).
static func _bounds(node: Node, space: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for mi in _meshes(node):
		var b := space.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


## Model vertices (in `space` coordinates) inside the xy window centre +- half.
static func _verts_near(node: Node, space: Node3D, centre: Vector2, half: Vector2) -> PackedVector3Array:
	var out := PackedVector3Array()
	for mi in _meshes(node):
		var xf := space.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			for v: Vector3 in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
				var p := xf * v
				if absf(p.x - centre.x) <= half.x and absf(p.y - centre.y) <= half.y:
					out.append(p)
	return out


## Every TINT surface Toonify handles (no material_override) shows Toonify's cached conversion for `tint`.
## Returns the number of such surfaces, or -1 if one is wrong.
static func _toonify_tint_surfaces(model: Node, tint: Color) -> int:
	var n := 0
	for mi in _meshes(model):
		if mi.material_override != null:
			continue
		for s in mi.mesh.get_surface_count():
			var src := mi.mesh.surface_get_material(s)
			if not Toonify.is_tint(src):
				continue
			if mi.get_active_material(s) != Toonify.toon_material(src, -1.0, tint):
				return -1
			n += 1
	return n


static func _single_tint_mesh(mi: MeshInstance3D) -> bool:
	return mi != null and mi.mesh != null and mi.mesh.get_surface_count() == 1 \
			and Toonify.is_tint(mi.mesh.surface_get_material(0))


static func _toon(m: Material) -> bool:
	var b := m as BaseMaterial3D
	return b != null and (b.diffuse_mode == BaseMaterial3D.DIFFUSE_TOON or b.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED)


static func _all_toon(model: Node) -> bool:
	for mi in _meshes(model):
		for s in mi.mesh.get_surface_count():
			if not _toon(mi.get_active_material(s)):
				return false
	return true


static func _has_outline(model: Node) -> bool:
	for n in model.find_children("*", "MeshInstance3D", true, false):
		if n.has_meta(&"toonify_outline"):
			return true
	return false


func _common_model_checks(item: Item, model: Node3D, tag: String) -> void:
	check(model is Toonify, "%s: the model (glb) is a Toonify root" % tag)
	var tris := _tris(model)
	check(tris > 200 and tris <= MAX_TRIS, "%s: %d tris (<= %d)" % [tag, tris, MAX_TRIS])
	var box := _bounds(model, item)
	var big := maxf(box.size.x, maxf(box.size.y, box.size.z))
	check(absf(box.position.y) < 0.01, "%s: stands on the floor (min y %.3f)" % [tag, box.position.y])
	check(big >= 0.3 and big <= 0.6, "%s: held-item size 0.3-0.6 m (largest %.2f, %s)" % [tag, big, box.size])
	check(_all_toon(model), "%s: every surface is a toon (or unshaded) material" % tag)
	check(_has_outline(model), "%s: ink outline hull built (outline_width in the scene)" % tag)
	var body := item.get_node_or_null(^"Collider") as StaticBody3D
	check(body != null and body.collision_layer == Const.LAYER_ITEM and body.collision_mask == 0,
			"%s: collider kept on the item layer" % tag)
	check(item.get_node_or_null(^"Sync") is MultiplayerSynchronizer, "%s: Sync kept" % tag)


# --------------------------------------------------------------------------------------------- watering can
func _test_can() -> void:
	var can := await _spawn(CAN_SCENE, {"charges": 2}) as WateringCan
	check(can != null, "watering can spawns from its scene")
	if can == null:
		return
	var model := can.get_node_or_null(^"Visual") as Node3D
	_common_model_checks(can, model, "watering_can")
	var fill := can.get_node_or_null(^"Visual/Gauge/Fill") as MeshInstance3D
	var water := can.get_node_or_null(^"Visual/WaterTop") as MeshInstance3D
	var label := can.get_node_or_null(^"ChargeLabel") as Label3D
	check(fill != null and water != null and label != null and can.get_node_or_null(^"Visual/Can") is MeshInstance3D,
			"watering_can: model nodes Can, WaterTop, Gauge/Fill + ChargeLabel")
	if fill == null or water == null or label == null:
		return
	var fa := fill.get_aabb()
	check(absf(fa.size.y - WateringCan.GAUGE_HEIGHT) < 0.002 and absf(fa.get_center().y) < 0.002,
			"watering_can: Fill is GAUGE_HEIGHT tall and centred on its node (%s)" % fa)
	var cap := can.get_capacity()
	var f := 2.0 / float(cap)
	check(fill.visible and is_equal_approx(fill.scale.y, f) and is_equal_approx(fill.position.y, WateringCan.GAUGE_HEIGHT * f * 0.5),
			"watering_can: gauge at 2/%d (scale %.3f, y %.3f)" % [cap, fill.scale.y, fill.position.y])
	check(absf(fill.position.y + fa.position.y * fill.scale.y) < 0.002, "watering_can: the water bar grows from the gauge bottom")
	check(water.visible and label.text == "2/%d" % cap, "watering_can: water surface shown, label '%s'" % label.text)
	can.charges = 0
	check(not fill.visible and not water.visible and label.text == "0/%d" % cap,
			"watering_can: empty -> gauge + water surface hidden, label 0/N")
	can.charges = cap
	check(fill.visible and is_equal_approx(fill.scale.y, 1.0)
			and absf(fill.position.y + fa.end.y - WateringCan.GAUGE_HEIGHT) < 0.002 and water.visible,
			"watering_can: full -> the bar fills the glass")
	# The bar sits in the glass on the back (+Z, the holder's side) and never pokes out of the frame's top.
	var gauge := can.get_node(^"Visual/Gauge") as Node3D
	var top := can.global_transform.affine_inverse() * gauge.global_transform * Vector3(0, WateringCan.GAUGE_HEIGHT, 0)
	check(gauge.position.z > 0.1 and top.y < _bounds(model, can).end.y, "watering_can: gauge on the back, inside the body height")
	check(label.position.y > _bounds(model, can).end.y + 0.05, "watering_can: ChargeLabel floats above the model")
	can.queue_free()


# ---------------------------------------------------------------------------------------------- seed packet
func _test_packet() -> void:
	var packet := await _spawn(PACKET_SCENE, {"strain_id": &"purple"}) as SeedPacket
	check(packet != null, "seed packet spawns from its scene")
	if packet == null:
		return
	var model := packet.get_node_or_null(^"Visual/Packet") as Toonify
	_common_model_checks(packet, model, "seed_packet")
	var body := packet.get_node_or_null(^"Visual/Packet/Body") as MeshInstance3D
	var name_label := packet.get_node_or_null(^"Visual/Packet/NameLabel") as Label3D
	var plate := packet.get_node_or_null(^"Visual/Packet/PlateLabel") as Label3D
	check(_single_tint_mesh(body), "seed_packet: Body is one TINT surface (the paper)")
	check(packet.get_node_or_null(^"Visual/Packet/Icon/Bud") is MeshInstance3D, "seed_packet: Icon/Bud kept")
	check(name_label != null and plate != null and "PROPERTY OF" in plate.text and "BOSS" in plate.text,
			"seed_packet: NameLabel + the PROPERTY OF THE BOSS plate label")
	if model == null or body == null or name_label == null:
		return
	var g := Toon.grade(packet.get_seed().color)
	var over := body.material_override as StandardMaterial3D
	check(model.tint.is_equal_approx(g), "seed_packet: Toonify tint == Toon.grade(seed.color)")
	check(over != null and over.albedo_color.is_equal_approx(g) and _toon(over),
			"seed_packet: Body override is a toon material in the graded strain colour")
	check(over != Toonify.toon_material(body.mesh.surface_get_material(0), -1.0, g),
			"seed_packet: Body override is a per-instance copy (Toonify's shared cache untouched)")
	var parts := _toonify_tint_surfaces(model, g)
	check(parts >= 2, "seed_packet: crimp + icon bud tinted through Toonify (%d TINT surfaces)" % parts)
	check(name_label.text == packet.get_strain_name(), "seed_packet: NameLabel shows '%s'" % name_label.text)
	# A second packet of the same strain: own Body material, shared Toonify conversions.
	var twin := await _spawn(PACKET_SCENE, {"strain_id": &"purple"}) as SeedPacket
	var twin_body := twin.get_node(^"Visual/Packet/Body") as MeshInstance3D
	check(twin_body.material_override != over and (twin_body.material_override as StandardMaterial3D).albedo_color.is_equal_approx(g),
			"seed_packet: each packet owns its Body material")
	check(_toonify_tint_surfaces(twin.get_node(^"Visual/Packet"), g) == parts, "seed_packet: same strain -> shared Toonify materials")
	twin.queue_free()
	# Strain change through the synced setter (the path a client takes).
	packet.strain_id = &"budget"
	var gb := Toon.grade(Config.balance.get_seed(&"budget").color)
	check(body.material_override == over and over.albedo_color.is_equal_approx(gb) and model.tint.is_equal_approx(gb)
			and _toonify_tint_surfaces(model, gb) == parts, "seed_packet: re-tints in place when strain_id changes")
	check(name_label.text == packet.get_strain_name(), "seed_packet: label follows the strain ('%s')" % name_label.text)
	packet.strain_id = &"no_such_strain"
	check(over.albedo_color.is_equal_approx(Toon.grade(SeedPacket.UNKNOWN_COLOR)) and name_label.text == packet.get_strain_name(),
			"seed_packet: unknown strain -> graded grey, '%s'" % name_label.text)
	# The printed text sits in front of the paper, the plate text behind it (it faces -Z).
	var lp := name_label.position
	var near_label := _verts_near(model, model, Vector2(lp.x, lp.y), Vector2(0.09, 0.04))
	var front := -1.0
	for v in near_label:
		front = maxf(front, v.z)
	check(not near_label.is_empty() and lp.z > front, "seed_packet: NameLabel in front of the label window (%.4f > %.4f)" % [lp.z, front])
	var pp := plate.position
	var near_plate := _verts_near(model, model, Vector2(pp.x, pp.y), Vector2(0.06, 0.02))
	var back := 1.0
	for v in near_plate:
		back = minf(back, v.z)
	check(not near_plate.is_empty() and pp.z < back and plate.global_basis.z.z < 0.0,
			"seed_packet: PlateLabel on the back plate, facing -Z (%.4f < %.4f)" % [pp.z, back])
	packet.queue_free()


# -------------------------------------------------------------------------------------------------- product
func _test_product() -> void:
	var product := await _spawn(PRODUCT_SCENE, {"strain_id": &"golden", "amount": 2}) as Product
	check(product != null, "product spawns from its scene")
	if product == null:
		return
	var model := product.get_node_or_null(^"Visual/Cluster") as Toonify
	_common_model_checks(product, model, "product")
	var buds := product.get_node_or_null(^"Visual/Cluster/Buds") as Node3D
	var bud := product.get_node_or_null(^"Visual/Cluster/Buds/Bud0") as MeshInstance3D
	var label := product.get_node_or_null(^"AmountLabel") as Label3D
	check(buds != null and _single_tint_mesh(bud) and label != null, "product: Cluster/Buds/Bud0 (one TINT surface) + AmountLabel")
	if model == null or bud == null or label == null:
		return
	var g := Toon.grade(product.get_seed().color)
	var over := bud.material_override as StandardMaterial3D
	check(model.tint.is_equal_approx(g), "product: Toonify tint == Toon.grade(seed.color)")
	check(over != null and over.albedo_color.is_equal_approx(g) and _toon(over), "product: buds in the graded strain colour")
	var all_buds := true
	for c in buds.get_children():
		if c is MeshInstance3D and (c as MeshInstance3D).material_override != over:
			all_buds = false
	check(all_buds, "product: every mesh under Buds shares the item's bud material")
	check(_toonify_tint_surfaces(model, g) >= 0, "product: other TINT surfaces (if any) follow the Toonify tint")
	var rest_top := _bounds(model, model).end.y
	check(is_equal_approx(model.scale.x, 1.15) and label.text == "x2", "product: amount 2 -> x1.15 bundle, 'x2'")
	check(label.position.y > rest_top * model.scale.y + 0.05, "product: label above the scaled bundle (%.2f)" % label.position.y)
	product.amount = 5
	check(is_equal_approx(model.scale.x, Product.MAX_VISUAL_SCALE) and label.text == "x5"
			and label.position.y > rest_top * model.scale.y + 0.05, "product: amount 5 -> capped scale, label still above")
	product.amount = 1
	check(is_equal_approx(model.scale.x, 1.0) and label.text == "x1", "product: amount 1 -> rest size")
	product.strain_id = &"purple"
	var gp := Toon.grade(Config.balance.get_seed(&"purple").color)
	check(bud.material_override == over and over.albedo_color.is_equal_approx(gp) and model.tint.is_equal_approx(gp),
			"product: re-tints in place when strain_id changes")
	product.queue_free()


# ---------------------------------------------------------------------------------------------- hold poses
## Every held item, placed at the local %HandSocket with its hold pose, stays in front of the near plane, on
## screen, and out of the box around the crosshair; at %BodyHandSocket it sits in front of the chest.
func _test_hold_poses() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate() as Node3D
	var cam := player.get_node_or_null(^"Head/Camera") as Camera3D
	var socket := player.get_node_or_null(^"Head/Camera/HandSocket") as Node3D
	var body_socket := player.get_node_or_null(^"BodyHandSocket") as Node3D
	check(cam != null and socket != null and body_socket != null, "player scene has Camera, HandSocket, BodyHandSocket")
	if cam == null or socket == null or body_socket == null:
		player.free()
		return
	var cases := [[CAN_SCENE, {"charges": 4}, "watering_can"], [PACKET_SCENE, {"strain_id": &"purple"}, "seed_packet"],
			[PRODUCT_SCENE, {"strain_id": &"golden", "amount": 2}, "product x2"]]
	var t := tan(deg_to_rad(cam.fov) * 0.5)
	for c: Array in cases:
		var item := await _spawn(c[0], c[1])
		var box := _bounds(item.get_node(^"Visual"), item)
		var xf := socket.transform * item._get_hold_transform()   # camera space
		var near_ok := true
		var rect := Rect2()
		for i in 8:
			var p := xf * box.get_endpoint(i)
			near_ok = near_ok and -p.z > cam.near + 0.05
			var s := Vector2(p.x / (-p.z * t * SCREEN_ASPECT), p.y / (-p.z * t))
			rect = Rect2(s, Vector2.ZERO) if i == 0 else rect.expand(s)
		var cross := Rect2(-Vector2.ONE * CROSSHAIR_BOX, Vector2.ONE * CROSSHAIR_BOX * 2.0)
		check(near_ok, "%s: held item stays beyond the camera near plane" % c[2])
		check(not rect.intersects(cross), "%s: held item clears the crosshair (screen rect %s)" % [c[2], rect])
		check(rect.intersects(Rect2(-Vector2.ONE, Vector2.ONE * 2.0)) and rect.get_center().x > 0.2 and rect.get_center().y < 0.0,
				"%s: held item visible at the bottom right" % c[2])
		var bxf := body_socket.transform * item._get_hold_transform()   # player space (third person)
		var centre := bxf * box.get_center()
		check(centre.z < -0.4 and centre.y > 0.9 and centre.y < 1.7 and centre.x > 0.0,
				"%s: others see it in front of the chest (%s)" % [c[2], centre])
		item.queue_free()
	player.free()
