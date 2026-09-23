extends RefCounted
## Reference "style kit" builders (art agent). Every object in STYLE.md "Per-object guidance" has a recipe
## here built from primitive meshes + the toon library, with the exact sizes the guide quotes.
## Used by tools/tests/art_preview.gd (screenshots) and tools/gen_placeholder_art.gd, which packs the
## diorama into res://art/reference/style_kit.tscn so it can be opened in the editor.
## Other agents: copy the recipe you need into your own scene (do not instance this file at runtime).

const FACE := preload("res://art/props/face.tscn")

static func mat(name: String) -> Material:
	return load("res://art/materials/toon_%s.tres" % name)

static func outline() -> Material:
	return load("res://art/materials/toon_outline.tres")

## MeshInstance3D helper. Outline on by default (round meshes only).
static func mesh(parent: Node3D, name: String, m: Mesh, material: Material, pos: Vector3,
		scl: Vector3 = Vector3.ONE, rot_deg: Vector3 = Vector3.ZERO, with_outline: bool = true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	mi.mesh = m
	mi.material_override = material
	if with_outline:
		mi.material_overlay = outline()
	mi.position = pos
	mi.scale = scl
	mi.rotation_degrees = rot_deg
	parent.add_child(mi)
	return mi

static func sphere(r: float, segs: int = 24) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = segs
	s.rings = segs / 2
	return s

static func capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 24
	c.rings = 8
	return c

static func cylinder(top: float, bottom: float, h: float, segs: int = 24) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top
	c.bottom_radius = bottom
	c.height = h
	c.radial_segments = segs
	c.rings = 1
	return c

static func torus(inner: float, outer: float) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = 32
	t.ring_segments = 12
	return t

static func blob_shadow(parent: Node3D, radius: float) -> MeshInstance3D:
	var c := cylinder(radius, radius, 0.01, 24)
	var mi := mesh(parent, "BlobShadow", c, mat("blob_shadow"), Vector3(0, 0.006, 0), Vector3.ONE, Vector3.ZERO, false)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

static func label(parent: Node3D, text: String, pos: Vector3, color: Color, size: int = 64) -> Label3D:
	var l := Label3D.new()
	l.name = "Label_" + text.validate_node_name().left(12)
	l.text = text
	l.font_size = size
	l.outline_size = size / 4
	l.pixel_size = 0.005
	l.modulate = color
	l.outline_modulate = Toon.INK
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.position = pos
	parent.add_child(l)
	return l

# ------------------------------------------------------------------------------------------ characters

## Player "bean": capsule body in the player colour, sad face, a wilted sprout on the head, stubby feet,
## a slight slouch (MOOD: everyone is tired).
## Visual only; the collision capsule (radius 0.4, height 1.8) belongs to the player scene.
static func player(color: Color, player_name: String) -> Node3D:
	var root := Node3D.new()
	root.name = "Player_" + player_name
	var visual := Node3D.new()
	visual.name = "Visual"            # Juice.bounce() this, never the CharacterBody3D
	visual.rotation_degrees.x = -4.0  # slouch forward
	root.add_child(visual)
	blob_shadow(root, 0.48)
	mesh(visual, "Body", capsule(0.42, 1.55), Toon.material(color), Vector3(0, 0.84, 0))
	for side in [-1.0, 1.0]:
		mesh(visual, "Foot", sphere(0.14, 16), Toon.material(color.darkened(0.3)), Vector3(0.17 * side, 0.08, -0.06), Vector3(1.0, 0.6, 1.35))
	var face := FACE.instantiate() as Node3D
	face.position = Vector3(0, 1.22, -0.4)
	visual.add_child(face)
	# Sprout "hat": the farm identity, wilted. Bent stem + two drooping, dry-ish leaves.
	mesh(visual, "Stem", cylinder(0.022, 0.028, 0.16, 8), mat("leaf"), Vector3(0.02, 1.66, 0), Vector3.ONE, Vector3(0, 0, -18), false)
	mesh(visual, "LeafL", sphere(0.09, 12), mat("leaf_dry"), Vector3(-0.05, 1.7, 0), Vector3(1.4, 0.4, 0.8), Vector3(0, 0, -35))
	mesh(visual, "LeafR", sphere(0.09, 12), mat("leaf_dry"), Vector3(0.12, 1.69, 0), Vector3(1.4, 0.4, 0.8), Vector3(0, 0, 40))
	var l := label(root, player_name, Vector3(0, 2.1, 0), Toon.lighter(color, 0.35), 48)
	l.name = "NameLabel"
	return root

## Shopkeeper: a 1.3x bigger, rounder bean with a grubby apron, moustache, flat cap and a GRIM face
## (MOOD: he works for the Boss too). Idles with a slow pulse().
static func shopkeeper() -> Node3D:
	var root := Node3D.new()
	root.name = "Shopkeeper"
	var visual := Node3D.new()
	visual.name = "Visual"
	root.add_child(visual)
	blob_shadow(root, 0.62)
	mesh(visual, "Body", capsule(0.58, 1.9), mat("orange"), Vector3(0, 0.95, 0))
	mesh(visual, "Apron", sphere(0.5, 24), mat("cream"), Vector3(0, 0.62, -0.27), Vector3(0.95, 1.05, 0.5), Vector3.ZERO, false)
	var face := FACE.instantiate() as Node3D
	face.position = Vector3(0, 1.45, -0.55)
	face.scale = Vector3.ONE * 1.3
	(face as ToonFace).default_mood = &"grim"
	visual.add_child(face)
	for side in [-1.0, 1.0]:
		mesh(visual, "Moustache", capsule(0.05, 0.26), mat("brown"), Vector3(0.1 * side, 1.28, -0.56), Vector3.ONE, Vector3(0, 0, 90 + 20 * side), false)
	mesh(visual, "Cap", sphere(0.38, 24), mat("red"), Vector3(0, 1.86, 0), Vector3(1, 0.55, 1))
	mesh(visual, "Brim", cylinder(0.3, 0.3, 0.04, 24), mat("red"), Vector3(0, 1.84, -0.28), Vector3(1, 1, 1.2), Vector3.ZERO, false)
	return root

# ------------------------------------------------------------------------------------------- stations

## Grow plot: round honey-wood tub (r 0.62, 0.42 tall) with a chunky rim and a domed soil top.
## `stage` 0..4 = EMPTY, SEEDLING, VEGETATIVE, FLOWERING, READY. `wet` swaps soil -> soil_wet.
static func grow_plot(stage: int, strain_color: Color, wet: bool = false) -> Node3D:
	var root := Node3D.new()
	root.name = "GrowPlot_%d" % stage
	blob_shadow(root, 0.72)
	mesh(root, "Tub", cylinder(0.62, 0.54, 0.42, 28), mat("wood"), Vector3(0, 0.21, 0))
	mesh(root, "Rim", torus(0.56, 0.7), mat("brown"), Vector3(0, 0.42, 0), Vector3(1, 1.4, 1))
	mesh(root, "Soil", sphere(0.57, 28), mat("soil_wet" if wet else "soil"), Vector3(0, 0.4, 0), Vector3(1, 0.16, 1), Vector3.ZERO, false)
	var plant := plant_stage(stage, strain_color)
	if plant:
		plant.position = Vector3(0, 0.46, 0)
		root.add_child(plant)
	return root

## Plant visual for one stage, origin at the soil surface (so squash stays planted).
## Heights: seedling 0.22, vegetative 0.55, flowering 0.8, ready 1.0 (above the soil).
static func plant_stage(stage: int, c: Color) -> Node3D:
	if stage <= 0:
		return null
	var p := Node3D.new()
	p.name = "Plant"
	match stage:
		1:
			mesh(p, "Stem", cylinder(0.018, 0.024, 0.14, 8), mat("lime"), Vector3(0, 0.07, 0), Vector3.ONE, Vector3.ZERO, false)
			mesh(p, "LeafL", sphere(0.08, 12), mat("lime"), Vector3(-0.07, 0.15, 0), Vector3(1.3, 0.38, 0.75), Vector3(0, 0, 28))
			mesh(p, "LeafR", sphere(0.08, 12), mat("lime"), Vector3(0.07, 0.16, 0), Vector3(1.3, 0.38, 0.75), Vector3(0, 0, -28))
		2:
			mesh(p, "Stem", cylinder(0.03, 0.04, 0.4, 8), mat("leaf"), Vector3(0, 0.2, 0), Vector3.ONE, Vector3.ZERO, false)
			for i in 4:
				var a := i * TAU / 4.0 + 0.4
				mesh(p, "Leaf%d" % i, sphere(0.13, 16), mat("leaf"), Vector3(cos(a) * 0.15, 0.2 + i * 0.05, sin(a) * 0.15), Vector3(1.25, 0.45, 0.8), Vector3(0, -rad_to_deg(a), 22))
			mesh(p, "Top", sphere(0.16, 16), mat("leaf"), Vector3(0, 0.44, 0))
		3, 4:
			var big := stage == 4
			var k := 1.2 if big else 1.0
			mesh(p, "BushLow", sphere(0.26 * k, 20), mat("leaf"), Vector3(0, 0.24 * k, 0), Vector3(1.15, 0.9, 1.15))
			mesh(p, "BushMid", sphere(0.22 * k, 20), mat("leaf"), Vector3(0.04, 0.46 * k, 0.02))
			mesh(p, "BushTop", sphere(0.17 * k, 20), mat("leaf"), Vector3(-0.02, 0.64 * k, -0.02))
			var buds := 7 if big else 5
			var bud_mat := Toon.tint(c, Toon.Finish.GLOW if big else Toon.Finish.SOFT)
			for i in buds:
				var a := i * TAU / buds
				var y := (0.3 + 0.35 * float(i % 3) / 2.0) * k
				var r := (0.2 if i % 2 == 0 else 0.16) * k
				mesh(p, "Bud%d" % i, sphere((0.1 if big else 0.065), 14), bud_mat, Vector3(cos(a) * r, y, sin(a) * r))
			mesh(p, "BudCrown", sphere((0.12 if big else 0.08), 14), bud_mat, Vector3(0, 0.8 * k, 0))
	return p

## Well: chunky stone drum (r 0.75, 0.7 tall) + fat rim, glowing water disc, two posts and a red roof.
static func well() -> Node3D:
	var root := Node3D.new()
	root.name = "Well"
	blob_shadow(root, 0.95)
	mesh(root, "Drum", cylinder(0.75, 0.8, 0.62, 28), mat("stone"), Vector3(0, 0.31, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Water", cylinder(0.64, 0.64, 0.04, 28), mat("water"), Vector3(0, 0.63, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Rim", torus(0.6, 0.88), mat("stone"), Vector3(0, 0.68, 0), Vector3(1, 1.4, 1))
	for side in [-1.0, 1.0]:
		mesh(root, "Post", cylinder(0.07, 0.08, 1.7, 10), mat("wood"), Vector3(0.78 * side, 1.1, 0))
	mesh(root, "Beam", cylinder(0.05, 0.05, 1.7, 10), mat("brown"), Vector3(0, 1.75, 0), Vector3.ONE, Vector3(0, 0, 90))
	var roof := PrismMesh.new()
	roof.size = Vector3(2.1, 0.7, 1.4)
	mesh(root, "Roof", roof, mat("red"), Vector3(0, 2.25, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Rope", cylinder(0.012, 0.012, 0.6, 6), mat("cream"), Vector3(0, 1.45, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Bucket", cylinder(0.14, 0.11, 0.2, 16), mat("metal"), Vector3(0, 1.1, 0))
	return root

## Turn-in bin: fat tangerine barrel (r 0.6, 0.95 tall) with gold hoops and a big floating "$".
static func turn_in_bin() -> Node3D:
	var root := Node3D.new()
	root.name = "TurnInBin"
	blob_shadow(root, 0.75)
	var visual := Node3D.new()
	visual.name = "Visual"
	root.add_child(visual)
	mesh(visual, "Barrel", cylinder(0.6, 0.52, 0.95, 28), mat("orange"), Vector3(0, 0.475, 0))
	for y in [0.2, 0.78]:
		mesh(visual, "Hoop", torus(0.55, 0.64), mat("gold"), Vector3(0, y, 0), Vector3(1, 0.8, 1), Vector3.ZERO, false)
	mesh(visual, "Hole", cylinder(0.46, 0.46, 0.02, 24), mat("dark"), Vector3(0, 0.955, 0), Vector3.ONE, Vector3.ZERO, false)
	var sign := label(root, "$", Vector3(0, 1.55, 0), Toon.GOLD, 160)
	sign.name = "DollarSign"
	sign.outline_size = 36
	return root

## Shop counter: honey-wood counter with a cream top, candy-striped awning, shopkeeper behind.
static func shop_counter() -> Node3D:
	var root := Node3D.new()
	root.name = "ShopCounter"
	var body := BoxMesh.new()
	body.size = Vector3(2.4, 1.0, 0.8)
	mesh(root, "Counter", body, mat("wood"), Vector3(0, 0.5, 0), Vector3.ONE, Vector3.ZERO, false)
	var top := BoxMesh.new()
	top.size = Vector3(2.6, 0.12, 1.0)
	mesh(root, "Top", top, mat("cream"), Vector3(0, 1.06, 0), Vector3.ONE, Vector3.ZERO, false)
	for i in 6:
		var stripe := BoxMesh.new()
		stripe.size = Vector3(0.44, 0.08, 1.1)
		mesh(root, "Awning%d" % i, stripe, mat("red" if i % 2 == 0 else "cream"), Vector3(-1.1 + i * 0.44, 2.55, -0.1), Vector3.ONE, Vector3(-15, 0, 0), false)
	for side in [-1.0, 1.0]:
		mesh(root, "Pole", cylinder(0.05, 0.05, 1.5, 10), mat("white"), Vector3(1.2 * side, 1.8, 0.3))
	var sk := shopkeeper()
	sk.position = Vector3(0, 0, -0.9)
	sk.rotation_degrees.y = 180
	root.add_child(sk)
	label(root, "SHOP", Vector3(0, 2.95, 0.1), Toon.SUNSHINE, 96)
	return root

# ----------------------------------------------------------------------------------------------- items

## Watering can (oversized: ~0.5 m nose to handle). Body sky blue, spout forward (-Z).
static func watering_can() -> Node3D:
	var root := Node3D.new()
	root.name = "WateringCan"
	mesh(root, "Body", cylinder(0.17, 0.19, 0.26, 20), mat("blue"), Vector3(0, 0.13, 0))
	mesh(root, "Lid", sphere(0.17, 20), mat("blue"), Vector3(0, 0.26, 0), Vector3(1, 0.35, 1))
	mesh(root, "Spout", cylinder(0.03, 0.045, 0.34, 10), mat("blue"), Vector3(0, 0.22, -0.26), Vector3.ONE, Vector3(-55, 0, 0), false)
	mesh(root, "Rose", cylinder(0.07, 0.05, 0.06, 12), mat("metal"), Vector3(0, 0.33, -0.4), Vector3.ONE, Vector3(-55, 0, 0), false)
	mesh(root, "Handle", torus(0.09, 0.13), mat("blue"), Vector3(0, 0.28, 0.14), Vector3.ONE, Vector3(0, 0, 90))
	return root

## Seed packet: flat puffy stadium (0.34 wide x 0.46 tall x 0.1 deep) in the strain colour, a rolled
## crimp on top and a cream badge with a sprout on the front (-Z).
static func seed_packet(c: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "SeedPacket"
	mesh(root, "Body", capsule(0.17, 0.46), Toon.tint(c), Vector3(0, 0.23, 0), Vector3(1, 1, 0.3))
	mesh(root, "Crimp", capsule(0.035, 0.3), Toon.tint(c.darkened(0.2)), Vector3(0, 0.43, 0), Vector3.ONE, Vector3(0, 0, 90))
	mesh(root, "Badge", cylinder(0.1, 0.1, 0.02, 20), mat("cream"), Vector3(0, 0.22, -0.05), Vector3.ONE, Vector3(90, 0, 0), false)
	mesh(root, "SproutL", sphere(0.035, 10), mat("leaf"), Vector3(-0.03, 0.24, -0.062), Vector3(1.4, 0.7, 0.5), Vector3(0, 0, 25), false)
	mesh(root, "SproutR", sphere(0.035, 10), mat("leaf"), Vector3(0.03, 0.245, -0.062), Vector3(1.4, 0.7, 0.5), Vector3(0, 0, -25), false)
	mesh(root, "SproutStem", cylinder(0.008, 0.008, 0.07, 6), mat("leaf"), Vector3(0, 0.2, -0.062), Vector3.ONE, Vector3.ZERO, false)
	return root

## Product: open glass jar (r 0.15, 0.2 tall) stuffed with big glowing buds in the strain colour that
## spill over the top (first-person players look down on it), cream label band near the base.
static func product(c: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Product"
	var bud_mat := Toon.tint(c, Toon.Finish.GLOW)
	var spots := [Vector3(-0.05, 0.08, 0.02), Vector3(0.05, 0.1, -0.02), Vector3(0.0, 0.17, 0.03),
		Vector3(-0.04, 0.22, -0.03), Vector3(0.05, 0.23, 0.02), Vector3(0.0, 0.29, 0.0)]
	for i in spots.size():
		mesh(root, "Bud%d" % i, sphere(0.075 if i < 3 else 0.085, 14), bud_mat, spots[i], Vector3.ONE, Vector3.ZERO, i >= 3)
	mesh(root, "Jar", cylinder(0.15, 0.14, 0.2, 24), mat("glass"), Vector3(0, 0.1, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Lip", torus(0.13, 0.17), mat("glass"), Vector3(0, 0.2, 0), Vector3.ONE, Vector3.ZERO, false)
	mesh(root, "Label", cylinder(0.152, 0.145, 0.06, 24), mat("cream"), Vector3(0, 0.06, 0), Vector3.ONE, Vector3.ZERO, false)
	return root

# ---------------------------------------------------------------------------------------------- diorama

const STRAINS: Array[Color] = [Color(0.55, 0.85, 0.35), Color(0.7, 0.45, 0.9), Color(1, 0.8, 0.25)]
const PLAYER_COLORS: Array[Color] = [Toon.PLAYER_COLORS[0], Toon.PLAYER_COLORS[1], Toon.PLAYER_COLORS[2], Toon.PLAYER_COLORS[3]]

static func build_diorama() -> Node3D:
	var root := Node3D.new()
	root.name = "StyleKit"
	var lighting := (load("res://art/env/toon_lighting.tscn") as PackedScene).instantiate()
	root.add_child(lighting)
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(16, 0.2, 12)
	mesh(root, "Floor", floor_mesh, mat("floor"), Vector3(0, -0.1, 0), Vector3.ONE, Vector3.ZERO, false)
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(16, 3.5, 0.3)
	mesh(root, "WallBack", wall_mesh, mat("wall"), Vector3(0, 1.75, -6), Vector3.ONE, Vector3.ZERO, false)
	var trim := BoxMesh.new()
	trim.size = Vector3(16, 0.3, 0.4)
	mesh(root, "Skirting", trim, mat("wood"), Vector3(0, 0.15, -5.85), Vector3.ONE, Vector3.ZERO, false)
	# Plot row: every stage, alternating strains, last one watered.
	for s in 5:
		var plot := grow_plot(s, STRAINS[s % 3], s == 2)
		plot.position = Vector3(-4.8 + s * 1.6, 0, 1.0)
		root.add_child(plot)
	var w := well()
	w.position = Vector3(-5.5, 0, -3.5)
	root.add_child(w)
	var shop := shop_counter()
	shop.position = Vector3(0, 0, -4.2)
	root.add_child(shop)
	var bin := turn_in_bin()
	bin.position = Vector3(5.2, 0, -3.2)
	root.add_child(bin)
	var names := ["Alice", "Bob", "Cleo", "Dan"]
	for i in 4:
		var pl := player(PLAYER_COLORS[i], names[i])
		pl.position = Vector3(-2.4 + i * 1.3, 0, 3.6)
		pl.rotation_degrees.y = 180 + (i - 1.5) * 12
		root.add_child(pl)
	var items := Node3D.new()
	items.name = "Items"
	items.position = Vector3(3.6, 0, 3.2)
	root.add_child(items)
	var can := watering_can()
	can.rotation_degrees.y = 120
	items.add_child(can)
	for i in 3:
		var pk := seed_packet(STRAINS[i])
		pk.position = Vector3(0.7 + i * 0.45, 0, 0.1)
		pk.rotation_degrees.y = 160
		items.add_child(pk)
	for i in 2:
		var pr := product(STRAINS[i + 1])
		pr.position = Vector3(0.9 + i * 0.5, 0, 0.8)
		items.add_child(pr)
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 55
	root.add_child(cam)
	return root

## 0 overview, 1 plant stages, 2 players + shopkeeper, 3 items close-up, 4 juice, 5 faces close-up.
static func aim_camera(root: Node3D, view: int) -> void:
	var cam := root.get_node("Camera") as Camera3D
	var views := [
		[Vector3(0, 6.5, 10.5), Vector3(0, 0.6, -0.5), 55.0],
		[Vector3(-1.6, 2.4, 4.6), Vector3(-1.6, 0.6, 1.0), 50.0],
		[Vector3(-0.5, 2.3, 8.2), Vector3(-0.5, 1.2, 2.0), 50.0],
		[Vector3(4.5, 1.4, 5.3), Vector3(4.4, 0.2, 3.3), 45.0],
		[Vector3(0.2, 2.6, 6.2), Vector3(0.6, 1.1, 1.0), 55.0],
		[Vector3(-1.45, 1.45, 5.3), Vector3(-1.35, 1.22, 3.6), 40.0],
	]
	var v: Array = views[clampi(view, 0, views.size() - 1)]
	cam.fov = v[2]
	cam.look_at_from_position(v[0], v[1])
	cam.current = true

## Fires one of every Juice effect around the plots/bin (for the "juice" preview frames).
static func play_juice(root: Node3D) -> void:
	var juice: Node = root.get_node(^"/root/Juice")
	var plot_ready := root.get_node("GrowPlot_4") as Node3D
	var plot_veg := root.get_node("GrowPlot_2") as Node3D
	juice.burst(plot_ready.global_position + Vector3(0, 1.0, 0), STRAINS[1], 16)
	juice.float_text(plot_ready.global_position + Vector3(0, 1.6, 0), "+$120", Toon.GOLD)
	juice.bounce(plot_ready.get_node("Plant"), 0.3)
	juice.grow_to(plot_veg.get_node("Plant"), Vector3.ONE * 1.25)
	juice.splash((root.get_node("GrowPlot_1") as Node3D).global_position + Vector3(0, 0.6, 0))
	juice.puff((root.get_node("GrowPlot_0") as Node3D).global_position + Vector3(0, 0.45, 0))
	juice.sparkle(plot_ready.global_position + Vector3(0, 1.2, 0))
	juice.confetti(Vector3(0, 0.5, 2.0))
	for p in root.find_children("Player_*", "Node3D", false, false):
		juice.bounce(p.get_node("Visual"), 0.25)
