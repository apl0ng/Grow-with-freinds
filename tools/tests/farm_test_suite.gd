extends Node
## Farming test suite (GrowPlot + Well + PlantVisual). Run it through the entry script:
##   godot --headless --path . -s res://tools/tests/farm_test.gd
## (Loaded at runtime by farm_test.gd so the autoload singletons exist when this compiles.)
##
## GameState / ItemManager / items / Player may still be stubs while other agents work, so the item
## side is covered with tiny runtime test doubles (a subclass of ItemManager that records calls, an
## Item subclass carrying `charges` / `strain_id`, a bare Player). Growth math is checked against
## Config.balance, so balance tweaks do not break the tests.

## Emitted once with the number of failed checks.
signal finished(failures: int)

const PLOT_SCENE := "res://scenes/stations/grow_plot.tscn"
const WELL_SCENE := "res://scenes/stations/well.tscn"
const DT := 1.0 / 60.0
const PEER := 7

const FAKE_ITEM_MANAGER_SRC := """extends ItemManager
var spawned: Array = []
var despawned: Array = []
var held: Dictionary = {}
var made: Array = []
var refuse_spawn := false

func server_spawn_item(item_type: StringName, props: Dictionary = {}, position: Vector3 = Vector3.ZERO, holder_id: int = 0) -> Item:
	spawned.append({"type": item_type, "props": props, "position": position, "holder": holder_id})
	if refuse_spawn:
		return null
	var it := Item.new()
	it.item_type = item_type
	made.append(it)
	return it

func server_despawn_item(item: Item) -> void:
	despawned.append(item)

func get_held_by(peer_id: int) -> Item:
	return held.get(peer_id)
"""

const FAKE_ITEM_SRC := """extends Item
var strain_id: StringName = &""
var charges: int = 0
var capacity: int = 4

func get_capacity() -> int:
	return capacity
"""

var _passed := 0
var _failed := 0
var _skipped := 0
var _root3d: Node3D
var _fake_items: ItemManager      # instance of FAKE_ITEM_MANAGER_SRC (null if it could not compile)
var _fake_item_script: GDScript
var _fake_world: World
var _player: Player
var _objects: Array[Object] = []  # freed at the end
var _saved: Dictionary = {}

# ------------------------------------------------------------------------------------------------

func run() -> void:
	_root3d = Node3D.new()
	_root3d.name = "FarmTest"
	get_tree().root.add_child(_root3d)
	get_tree().current_scene = _root3d
	await get_tree().process_frame
	_saved = {
		"phase": GameState.phase, "is_host": Net.is_host, "override": Config.growth_speed_override,
		"world": Game.world,
	}
	GameState.phase = GameState.Phase.MENU
	Net.is_host = false
	Config.growth_speed_override = 1.0
	_build_doubles()

	await _test_scene_structure()
	await _test_plant_rules()
	await _test_pause_and_dry()
	await _test_drain_rate()
	await _test_growth_timing(&"budget")
	await _test_growth_timing(&"purple")
	await _test_speed_override()
	await _test_ready_is_frozen()
	await _test_server_water_clamps()
	await _test_harvest_without_world()
	await _test_visuals()
	await _test_wilt_crossfade()
	await _test_plant_hitbox()
	if _fake_items != null:
		await _test_harvest_with_items()
		await _test_plot_interactions()
		await _test_well_interactions()
		await _test_well_starting_cans()
	else:
		_skip("harvest/interaction/well tests", "test ItemManager double did not compile against item_manager.gd")
	await _test_process_authority()

	# restore globals
	GameState.phase = _saved["phase"]
	Net.is_host = _saved["is_host"]
	Config.growth_speed_override = _saved["override"]
	Game.world = _saved["world"]
	_root3d.queue_free()
	if _fake_items != null:
		_objects.append_array(_fake_items.get(&"made"))
	for o in _objects:
		if is_instance_valid(o) and not (o is RefCounted):
			o.free()
	# Let one-shot sounds / particles finish so nothing is still playing at exit.
	await get_tree().create_timer(1.2).timeout
	print("farm_test: %d passed, %d failed, %d skipped" % [_passed, _failed, _skipped])
	print("FARM TEST " + ("OK" if _failed == 0 else "FAILED"))
	finished.emit(_failed)

# ------------------------------------------------------------------------------------------------
# helpers

func check(cond: bool, what: String, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: " + what)
	else:
		_failed += 1
		print("FAIL: " + what + ("   [" + detail + "]" if detail != "" else ""))

func _skip(what: String, why: String) -> void:
	_skipped += 1
	print("SKIP: %s (%s)" % [what, why])

func approx(a: float, b: float, eps: float = 1e-4) -> bool:
	return absf(a - b) <= eps

func _new_plot(processing: bool = false) -> GrowPlot:
	var plot := (load(PLOT_SCENE) as PackedScene).instantiate() as GrowPlot
	_root3d.add_child(plot)
	plot.set_process(processing)
	await get_tree().process_frame
	return plot

func _free_node(n: Node) -> void:
	if is_instance_valid(n):
		n.queue_free()
	await get_tree().process_frame

func _build_doubles() -> void:
	var s := GDScript.new()
	s.source_code = FAKE_ITEM_MANAGER_SRC
	if s.reload() == OK:
		_fake_items = s.new() as ItemManager
		_objects.append(_fake_items)
	_fake_item_script = GDScript.new()
	_fake_item_script.source_code = FAKE_ITEM_SRC
	if _fake_item_script.reload() != OK:
		_fake_item_script = null
		_fake_items = null
	_fake_world = World.new()
	_objects.append(_fake_world)
	if _fake_items != null:
		_fake_world.items = _fake_items
	_player = Player.new()
	_player.peer_id = PEER
	_objects.append(_player)

func _make_item(item_type: StringName, props: Dictionary = {}) -> Item:
	var it := _fake_item_script.new() as Item
	it.item_type = item_type
	for k: String in props:
		it.set(k, props[k])
	_objects.append(it)
	return it

func _hold(item: Item) -> void:
	_fake_items.set(&"held", {PEER: item} if item != null else {})

func _spawned() -> Array:
	return _fake_items.get(&"spawned")

func _stage_duration_ticks(plot: GrowPlot, stage: int) -> int:
	var seconds := plot.get_stage_duration(stage) / GameState.get_growth_speed_multiplier()
	return int(ceil(seconds / DT - 1e-6))

## Ticks (keeping the plot watered) until the stage changes; returns the tick count or -1.
func _ticks_to_next_stage(plot: GrowPlot, max_ticks: int) -> int:
	var start := plot.stage
	for i in max_ticks:
		plot.water = 1.0
		plot.tick(DT)
		if plot.stage != start:
			return i + 1
	return -1

func _plant_node(plot: GrowPlot, path: String) -> Node3D:
	return plot.get_node("Plant/" + path) as Node3D

func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout

## Colours equal up to the float noise (~1e-4) of the glTF round trip of the models' neutral TINT grey.
func _near(a: Color, b: Color, eps: float = 0.003) -> bool:
	return absf(a.r - b.r) < eps and absf(a.g - b.g) < eps and absf(a.b - b.b) < eps and absf(a.a - b.a) < eps

## The material `mi` renders its surface named `mat_name` (Blender material) with, or null.
func _surface_material(mi: MeshInstance3D, mat_name: String) -> BaseMaterial3D:
	if mi == null or mi.mesh == null:
		return null
	for s in mi.mesh.get_surface_count():
		if Toonify.material_name(mi.mesh.surface_get_material(s)) == mat_name:
			return mi.get_active_material(s) as BaseMaterial3D
	return null

## The graded strain material of the READY crown cola (what the buds and the tag card show).
func _crown_material(plot: GrowPlot) -> BaseMaterial3D:
	return _surface_material(_plant_node(plot, "Tilt/Bouncer/Grow/Ready/Buds/ColaTop") as MeshInstance3D, "TINT_bud")

# ------------------------------------------------------------------------------------------------
# tests

func _test_scene_structure() -> void:
	var plot := await _new_plot()
	check(plot is Interactable and plot is Node3D, "plot root is a GrowPlot (Interactable, Node3D)")
	check(plot.is_in_group(Const.GROUP_GROW_PLOTS) and plot.is_in_group(Const.GROUP_INTERACTABLES), "plot is in grow_plots + interactables groups")
	var body := plot.get_node_or_null("Body") as StaticBody3D
	check(body != null and body.collision_layer == (Const.LAYER_WORLD | Const.LAYER_INTERACTABLE) and body.collision_mask == 0,
		"plot collider is a StaticBody3D on layer world|interactable (5), mask 0")
	var sync := plot.get_node_or_null("Sync") as MultiplayerSynchronizer
	check(sync != null, "plot has a MultiplayerSynchronizer")
	if sync != null:
		var cfg := sync.replication_config
		check(sync.root_path == NodePath(".."), "sync root_path is ..")
		check(approx(sync.replication_interval, 0.1), "sync replication_interval is 0.1")
		var modes := {
			NodePath(".:stage"): SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE,
			NodePath(".:strain_id"): SceneReplicationConfig.REPLICATION_MODE_ON_CHANGE,
			NodePath(".:water"): SceneReplicationConfig.REPLICATION_MODE_ALWAYS,
			NodePath(".:stage_progress"): SceneReplicationConfig.REPLICATION_MODE_ALWAYS,
		}
		for p: NodePath in modes:
			check(cfg != null and cfg.has_property(p) and cfg.property_get_replication_mode(p) == modes[p] and cfg.property_get_spawn(p),
				"sync replicates %s (mode %d, spawn)" % [p, modes[p]])
	check(plot.stage == GrowPlot.Stage.EMPTY and plot.strain_id == &"" and plot.water == 0.0 and plot.stage_progress == 0.0,
		"new plot starts EMPTY, no strain, dry, no progress")
	var well := (load(WELL_SCENE) as PackedScene).instantiate() as Well
	_root3d.add_child(well)
	await get_tree().process_frame
	var wbody := well.get_node_or_null("Body") as StaticBody3D
	check(wbody != null and wbody.collision_layer == 5 and wbody.collision_mask == 0, "well collider on layer 5, mask 0")
	check(well.get_can_spots().size() >= Config.balance.starting_watering_cans, "well has a CanSpot per starting can (%d spots)" % well.get_can_spots().size())
	await _free_node(well)
	await _free_node(plot)

func _test_plant_rules() -> void:
	var plot := await _new_plot()
	check(not plot.server_plant(&"no_such_strain") and plot.stage == GrowPlot.Stage.EMPTY, "planting an unknown strain fails")
	check(not plot.server_water(1.0), "server_water on an EMPTY plot fails")
	check(not plot.server_harvest(null), "server_harvest on an EMPTY plot fails")
	check(plot.server_plant(&"budget"), "server_plant(budget) succeeds")
	check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == &"budget" and plot.stage_progress == 0.0,
		"planted plot is SEEDLING with strain budget")
	check(not plot.server_plant(&"purple") and plot.strain_id == &"budget", "cannot plant into an occupied plot")
	check(not plot.server_harvest(null) and plot.stage == GrowPlot.Stage.SEEDLING, "harvest fails while not READY")
	await _free_node(plot)

func _test_pause_and_dry() -> void:
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	plot.water = 1.0
	GameState.phase = GameState.Phase.MENU
	for i in 300:
		plot.tick(DT)
	check(plot.water == 1.0 and plot.stage_progress == 0.0, "no growth and no drain while not PLAYING")
	GameState.phase = GameState.Phase.PLAYING
	plot.water = 0.0
	for i in 600:
		plot.tick(DT)
	check(plot.stage == GrowPlot.Stage.SEEDLING and plot.stage_progress == 0.0 and plot.water == 0.0,
		"dry plot (water 0) does not grow for 10 s")
	var th := Config.balance.dry_threshold
	plot.water = th - 0.0005
	plot.tick(DT)
	check(plot.stage_progress == 0.0, "water just below dry_threshold: no growth")
	plot.water = th
	plot.tick(DT)
	check(plot.stage_progress > 0.0, "water at dry_threshold: grows")
	check(plot.needs_water() == plot.is_dry(), "needs_water() mirrors is_dry() while growing")
	GameState.phase = GameState.Phase.MENU
	await _free_node(plot)

func _test_drain_rate() -> void:
	GameState.phase = GameState.Phase.PLAYING
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	plot.water = 1.0
	var seconds := 10.0
	for i in int(seconds / DT):
		plot.tick(DT)
	var expected := maxf(0.0, 1.0 - seconds * Config.balance.water_drain_per_sec * GameState.get_water_drain_multiplier())
	check(approx(plot.water, expected, 1e-3), "water drains at water_drain_per_sec * drain multiplier",
		"got %.5f expected %.5f" % [plot.water, expected])
	# drains to zero and clamps
	for i in int(2.0 / Config.balance.water_drain_per_sec / DT):
		plot.tick(DT)
	check(plot.water == 0.0, "water drain clamps at 0")
	GameState.phase = GameState.Phase.MENU
	await _free_node(plot)

func _test_growth_timing(strain: StringName) -> void:
	GameState.phase = GameState.Phase.PLAYING
	var plot := await _new_plot()
	plot.server_plant(strain)
	var names := ["", "SEEDLING", "VEGETATIVE", "FLOWERING"]
	for st in [GrowPlot.Stage.SEEDLING, GrowPlot.Stage.VEGETATIVE, GrowPlot.Stage.FLOWERING]:
		var expected := _stage_duration_ticks(plot, st)
		var got := _ticks_to_next_stage(plot, expected * 2 + 10)
		check(absi(got - expected) <= 1 and plot.stage == st + 1,
			"%s %s lasts stage_durations[%d] * grow_time_multiplier (%d ticks)" % [strain, names[st], st - 1, expected],
			"got %d ticks, now stage %d" % [got, plot.stage])
	check(plot.stage == GrowPlot.Stage.READY and plot.is_ready_to_harvest(), "%s reaches READY" % strain)
	check(plot.get_growth_fraction() == 1.0 and plot.get_status_text() == "Ready", "READY status text / growth fraction")
	GameState.phase = GameState.Phase.MENU
	await _free_node(plot)

func _test_speed_override() -> void:
	GameState.phase = GameState.Phase.PLAYING
	Config.growth_speed_override = 10.0
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	var base_ticks := int(ceil(plot.get_stage_duration(GrowPlot.Stage.SEEDLING) / DT))
	var got := _ticks_to_next_stage(plot, base_ticks)
	var expected := _stage_duration_ticks(plot, GrowPlot.Stage.SEEDLING)
	check(absi(got - expected) <= 1 and got < base_ticks / 5, "Config.growth_speed_override = 10 makes a stage 10x shorter",
		"got %d, expected %d (base %d)" % [got, expected, base_ticks])
	Config.growth_speed_override = 1.0
	GameState.phase = GameState.Phase.MENU
	await _free_node(plot)

func _test_ready_is_frozen() -> void:
	GameState.phase = GameState.Phase.PLAYING
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	plot.stage = GrowPlot.Stage.READY
	plot.water = 0.5
	for i in 600:
		plot.tick(DT)
	check(plot.stage == GrowPlot.Stage.READY and plot.water == 0.5 and plot.stage_progress == 0.0, "READY neither drains nor grows")
	check(not plot.server_water(1.0), "server_water on a READY plant fails (nothing to grow)")
	var empty := await _new_plot()
	empty.water = 0.4
	for i in 120:
		empty.tick(DT)
	check(empty.water == 0.4, "EMPTY soil does not drain")
	GameState.phase = GameState.Phase.MENU
	await _free_node(plot)
	await _free_node(empty)

func _test_server_water_clamps() -> void:
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	var wpc := Config.balance.water_per_charge
	plot.water = 0.5
	check(plot.server_water(1.0) and approx(plot.water, minf(1.0, 0.5 + wpc)), "server_water adds water_per_charge")
	plot.water = 0.9
	plot.server_water(5.0)
	check(plot.water == 1.0, "server_water clamps at 1")
	check(not plot.server_water(1.0), "server_water on a full plot fails")
	plot.water = 0.2
	check(plot.server_water(0.25) and approx(plot.water, minf(1.0, 0.2 + wpc * 0.25)), "server_water(charges_worth) scales")
	await _free_node(plot)

func _test_harvest_without_world() -> void:
	Game.world = null
	var plot := await _new_plot()
	plot.server_plant(&"budget")
	plot.stage = GrowPlot.Stage.READY
	var ok := plot.server_harvest(null)
	check(not ok and plot.stage == GrowPlot.Stage.READY and plot.strain_id == &"budget",
		"harvest without a world/ItemManager is a null-safe no-op (plant kept)")
	await _free_node(plot)

func _test_visuals() -> void:
	var plot := await _new_plot()
	var body_plant := plot.get_node("Body/PlantShape") as CollisionShape3D
	check(body_plant.disabled, "plant hitbox disabled while EMPTY")
	check(not plot.get_node("Visual/Tag").visible, "plant tag hidden while EMPTY")
	plot.server_plant(&"purple")
	await get_tree().process_frame
	check(_plant_node(plot, "Tilt/Bouncer/Grow/Seedling").visible and not _plant_node(plot, "Tilt/Bouncer/Grow/Ready").visible,
		"SEEDLING model shown after planting")
	check(not body_plant.disabled, "plant hitbox enabled once planted")
	check(plot.get_node("Visual/Tag").visible, "plant tag shown once planted")
	check(_plant_node(plot, "DryIndicator").visible, "DRY indicator shown for a dry seedling")
	var tilt := _plant_node(plot, "Tilt")
	var purple_color := Config.balance.get_seed(&"purple").color
	var bud_mat := _crown_material(plot)
	check(bud_mat != null and _near(bud_mat.albedo_color, Toon.grade(purple_color)), "buds tinted with Toon.grade(seed colour)",
		str(bud_mat.albedo_color if bud_mat else Color.BLACK))
	var card := plot.get_node("Visual/Tag/Card") as MeshInstance3D
	var plant := plot.get_node("Plant") as PlantVisual
	check(card.material_override == bud_mat and plant.get_tint_material() == bud_mat,
		"plant tag shares the buds' graded strain material (get_tint_material())")
	check(bud_mat != null and not _near(bud_mat.albedo_color, purple_color), "tag / buds are not the raw seed colour")
	var dummies: PackedStringArray = []
	for mi in plant.find_children("*", "MeshInstance3D", true, false):
		if (mi as MeshInstance3D).mesh == null:
			dummies.append(str(plant.get_path_to(mi)))
	check(dummies.is_empty(), "PlantVisual has no mesh-less dummy MeshInstance3D", ", ".join(dummies))
	var soil := plot.get_node("Visual/SoilMound") as MeshInstance3D
	var dry_color := (soil.material_override as BaseMaterial3D).albedo_color if soil.material_override is BaseMaterial3D else Color.BLACK
	plot.server_water(1.0)
	await get_tree().process_frame
	check(not _plant_node(plot, "DryIndicator").visible, "DRY indicator hidden after watering")
	var wet_color := (soil.material_override as BaseMaterial3D).albedo_color if soil.material_override is BaseMaterial3D else Color.BLACK
	check(not wet_color.is_equal_approx(dry_color) and wet_color.v < dry_color.v, "soil darkens when watered")
	var pivot := plot.get_node("Visual/WaterGauge/FillPivot") as Node3D
	check(approx(pivot.scale.x, plot.water), "water gauge scales with water")
	plot.water = 0.0
	await get_tree().create_timer(0.6).timeout
	check(_plant_node(plot, "DryIndicator").visible and tilt.rotation.length() > 0.1, "plant droops + DRY indicator when water runs out")
	# Out-of-order property arrival (as a client might see it): stage before strain.
	var other := await _new_plot()
	other.stage = GrowPlot.Stage.READY
	other.strain_id = &"golden"
	other.water = 0.7
	await get_tree().process_frame
	var other_mat := _crown_material(other)
	check(_plant_node(other, "Tilt/Bouncer/Grow/Ready").visible and other_mat != null
		and _near(other_mat.albedo_color, Toon.grade(Config.balance.get_seed(&"golden").color))
		and (other.get_node("Visual/Tag/Card") as MeshInstance3D).material_override == other_mat,
		"setters in any order give the right model + graded tint on buds and tag (READY golden)")
	check(not _plant_node(other, "DryIndicator").visible, "no DRY indicator on a READY plant")
	other.stage_progress = 0.5
	other.stage = GrowPlot.Stage.VEGETATIVE
	await get_tree().process_frame
	var grow := _plant_node(other, "Tilt/Bouncer/Grow")
	check(_plant_node(other, "Tilt/Bouncer/Grow/Vegetative").visible and grow.scale.x > 0.8 and grow.scale.x < 1.0,
		"model swells with stage_progress")
	other.stage = GrowPlot.Stage.EMPTY
	await get_tree().process_frame
	await get_tree().process_frame
	var any_visible := false
	for n in ["Seedling", "Vegetative", "Flowering", "Ready"]:
		any_visible = any_visible or _plant_node(other, "Tilt/Bouncer/Grow/" + n).visible
	check(not any_visible and (other.get_node("Body/PlantShape") as CollisionShape3D).disabled, "EMPTY hides the plant and its hitbox")
	other.strain_id = &""
	other.server_plant(&"budget")
	var budget_mat := _crown_material(other)
	check(budget_mat != null and _near(budget_mat.albedo_color, Toon.grade(Config.balance.get_seed(&"budget").color))
		and (other.get_node("Visual/Tag/Card") as MeshInstance3D).material_override == budget_mat,
		"replanting another strain re-tints buds and tag (graded budget)")
	await _free_node(plot)
	await _free_node(other)

## Samples a running wilt crossfade once per frame until it ends (or `max_sec`):
## [{w, healthy (visible), wilted (visible), hy / wy (scale.y), tilt (rotation length)}], plus the blend time.
func _sample_blend(plant: PlantVisual, healthy: Node3D, wilted: Node3D, max_sec: float = 1.5) -> Dictionary:
	var samples: Array[Dictionary] = []
	var t0 := Time.get_ticks_msec()
	while plant.is_wilt_blending() and Time.get_ticks_msec() - t0 < int(max_sec * 1000.0):
		await get_tree().process_frame
		samples.append({"w": plant.get_wilt(), "healthy": healthy.visible, "wilted": wilted.visible,
			"hy": healthy.scale.y, "wy": wilted.scale.y, "tilt": (_plant_node(plant.get_parent() as GrowPlot, "Tilt")).rotation.length()})
	return {"samples": samples, "sec": (Time.get_ticks_msec() - t0) / 1000.0}

## Frames with both models on screen mid-blend, and whether w moved monotonically in `dir` (+1 / -1).
func _blend_stats(samples: Array[Dictionary], dir: float) -> Dictionary:
	var both := 0
	var monotonic := true
	var prev := -INF if dir > 0.0 else INF
	for smp in samples:
		var w: float = smp["w"]
		if smp["healthy"] and smp["wilted"] and w > 0.0 and w < 1.0:
			both += 1
		monotonic = monotonic and (w >= prev - 1e-6 if dir > 0.0 else w <= prev + 1e-6)
		prev = w
	return {"both": both, "monotonic": monotonic}

func _collision_state(plot: GrowPlot) -> Array:
	var shape := plot.get_node("Body/PlantShape") as CollisionShape3D
	var body := plot.get_node("Body") as StaticBody3D
	return [shape.disabled, shape.transform, shape.shape, (shape.shape as BoxShape3D).size, body.collision_layer, body.transform]

## Dry <-> watered is a ~0.4 s crossfade driven by one PlantVisual tween: idempotent, reversible mid-blend,
## instant when not animated, never both models at rest, collision untouched.
func _test_wilt_crossfade() -> void:
	var plot := await _new_plot()
	var plant := plot.get_node("Plant") as PlantVisual
	var tilt := _plant_node(plot, "Tilt")
	var veg := _plant_node(plot, "Tilt/Bouncer/Grow/Vegetative")
	var leaves := veg.get_node("Leaves") as Node3D
	var wilted := veg.get_node("Dry") as Node3D
	var indicator := _plant_node(plot, "DryIndicator")
	var seedling := _plant_node(plot, "Tilt/Bouncer/Grow/Seedling")
	# Planting into dry soil (fx on: offline = server): nothing was on screen, so the seedling pops in wilted.
	plot.server_plant(&"budget")
	check(plant.get_wilt() == 1.0 and not plant.is_wilt_blending() and (seedling.get_node("Dry") as Node3D).visible
		and not (seedling.get_node("Leaves") as Node3D).visible, "planting into dry soil shows the wilted seedling at once (no blend from nothing)")
	plot.stage = GrowPlot.Stage.VEGETATIVE
	check(wilted.visible and not leaves.visible and not plant.is_wilt_blending() and tilt.rotation.is_equal_approx(PlantVisual.DROOP_ROTATION),
		"growing while dry shows the next stage wilted and slumped, no blend")
	await get_tree().physics_frame
	var collision := _collision_state(plot)
	# Watering: the healthy model swells up out of the wilted one, which sinks away.
	plot.server_water(1.0)
	check(plant.is_wilt_blending() and not indicator.visible, "watering starts the crossfade; the DRY drop hides at once")
	var t_start := Time.get_ticks_msec()
	var mid_w := -1.0
	while plant.is_wilt_blending() and mid_w < 0.0 and Time.get_ticks_msec() - t_start < 1000:
		await get_tree().process_frame
		if plant.get_wilt() < 0.8:
			mid_w = plant.get_wilt()
	check(mid_w > 0.0 and leaves.visible and wilted.visible and leaves.scale.y < 1.0 and wilted.scale.y < 1.0
		and tilt.rotation.length() > 0.0 and tilt.rotation.length() < PlantVisual.DROOP_ROTATION.length(),
		"mid-blend: both models on screen, both scaled, slump easing off (wilt %.2f)" % mid_w,
		"healthy %s %.2f wilted %s %.2f" % [leaves.visible, leaves.scale.y, wilted.visible, wilted.scale.y])
	var repeat_w := plant.get_wilt()
	for i in 4:
		plant.set_dry(false, true)
		plot.water = 1.0 - 0.01 * i   # drain-like updates while wet: _update_dry(false) again and again
	check(plant.is_wilt_blending() and plant.get_wilt() == repeat_w, "repeated set_dry(false) mid-blend is a no-op (no restart)")
	var res := await _sample_blend(plant, leaves, wilted)
	var elapsed := (Time.get_ticks_msec() - t_start) / 1000.0
	check(elapsed > 0.25 and elapsed < 1.0, "the watering crossfade takes about WILT_TIME (%.2f s)" % elapsed)
	check(not plant.is_wilt_blending() and plant.get_wilt() == 0.0 and leaves.visible and not wilted.visible
		and leaves.transform.is_equal_approx(Transform3D.IDENTITY) and tilt.rotation.is_zero_approx(),
		"watered: only the healthy model, at rest, upright")
	check(_collision_state(plot) == collision, "the crossfade never touches the plant hitbox")
	# Drying: sampled frame by frame.
	plot.water = 0.0
	check(plant.is_wilt_blending() and indicator.visible, "running dry starts the crossfade; the DRY drop shows at once")
	res = await _sample_blend(plant, leaves, wilted)
	var st := _blend_stats(res["samples"], 1.0)
	check(int(st["both"]) >= 3 and bool(st["monotonic"]), "drying crossfades over several frames (%d with both models), wilt rises steadily" % int(st["both"]))
	check(float(res["sec"]) > 0.25 and float(res["sec"]) < 1.0, "the drying crossfade takes about WILT_TIME (%.2f s)" % float(res["sec"]))
	check(plant.get_wilt() == 1.0 and wilted.visible and not leaves.visible and wilted.transform.is_equal_approx(Transform3D.IDENTITY)
		and tilt.rotation.is_equal_approx(PlantVisual.DROOP_ROTATION), "dry: only the wilted model, at rest, slumped")
	var ends_ok := true
	for smp: Dictionary in res["samples"]:
		if not (smp["healthy"] or smp["wilted"]):
			ends_ok = false
	check(ends_ok, "some model is on screen on every frame of the blend")
	# Reversal mid-blend: watering while it wilts turns around from the current state, no jump.
	plot.server_water(1.0)
	await _sample_blend(plant, leaves, wilted)
	plot.water = 0.0
	t_start = Time.get_ticks_msec()
	while plant.is_wilt_blending() and plant.get_wilt() < 0.3 and Time.get_ticks_msec() - t_start < 1000:
		await get_tree().process_frame
	var w_before := plant.get_wilt()
	var hy_before := leaves.scale.y
	var wy_before := wilted.scale.y
	plot.server_water(1.0)
	check(plant.is_wilt_blending() and plant.get_wilt() == w_before and leaves.scale.y == hy_before and wilted.scale.y == wy_before
		and w_before > 0.0 and w_before < 1.0, "watering mid-wilt reverses from the current blend (%.2f), no jump" % w_before)
	res = await _sample_blend(plant, leaves, wilted)
	st = _blend_stats(res["samples"], -1.0)
	check(bool(st["monotonic"]) and plant.get_wilt() == 0.0 and leaves.visible and not wilted.visible,
		"the reversed blend heads straight back to healthy and ends with one model")
	# animate = false (a late joiner's first sync, the settle window) snaps, also mid-blend.
	plot.water = 0.0
	await get_tree().process_frame
	plant.set_dry(true, false)
	check(not plant.is_wilt_blending() and plant.get_wilt() == 1.0 and wilted.visible and not leaves.visible
		and tilt.rotation.is_equal_approx(PlantVisual.DROOP_ROTATION), "set_dry(dry, false) mid-blend snaps to the end state")
	plant.set_dry(false, false)
	check(not plant.is_wilt_blending() and plant.get_wilt() == 0.0 and leaves.visible and not wilted.visible
		and leaves.transform.is_equal_approx(Transform3D.IDENTITY) and tilt.rotation.is_zero_approx(), "set_dry(false, false) is instant (no blend)")
	# Clearing the plot mid-blend (reset / harvest) leaves nothing running.
	plot.water = 0.0
	await get_tree().process_frame
	plot.server_reset()
	await get_tree().process_frame
	check(not plant.is_wilt_blending() and plant.get_wilt() == 0.0 and not veg.visible and not indicator.visible,
		"resetting the plot mid-blend snaps the plant state, nothing left blending")
	await get_tree().physics_frame
	check((plot.get_node("Body/PlantShape") as CollisionShape3D).disabled, "EMPTY after the reset: hitbox disabled")
	await _free_node(plot)

## Eye-height ray like the Interactor's (world|interactable|item, bodies + areas, interact_distance long).
func _ray(from: Vector3, at: Vector3) -> Dictionary:
	var to := from + (at - from).normalized() * Config.balance.interact_distance
	var q := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM)
	q.collide_with_areas = true
	q.collide_with_bodies = true
	return _root3d.get_world_3d().direct_space_state.intersect_ray(q)

## "<Interactable name>/<shape node name>" for a ray hit ("" = nothing hit).
func _hit_name(hit: Dictionary) -> String:
	if hit.is_empty():
		return ""
	var body := hit["collider"] as CollisionObject3D
	var shape_owner := body.shape_owner_get_owner(body.shape_find_owner(int(hit["shape"]))) as Node
	var n: Node = body
	while n != null and not (n is Interactable):
		n = n.get_parent()
	return "%s/%s" % [n.name if n != null else "?", shape_owner.name]

## The READY plant is clickable from the player's eye (1.6 m) 2.5 m away, top cola and side leaves, from
## any side; an EMPTY plot is only its tray (the plant hitbox is off).
func _test_plant_hitbox() -> void:
	var plot := (load(PLOT_SCENE) as PackedScene).instantiate() as GrowPlot
	plot.name = "HitboxPlot"
	# Placed and turned like a room plot (front towards +X), away from anything else in the test world.
	plot.transform = Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(40.0, 0.0, 12.0))
	_root3d.add_child(plot)
	plot.set_process(false)
	plot.water = 0.8
	plot.server_plant(&"purple")
	plot.stage = GrowPlot.Stage.READY
	var plant := plot.get_node("Plant") as PlantVisual
	await _wait(0.6)   # pop-in / bounce / blends settle
	check(not plant.is_wilt_blending() and plant.get_wilt() == 0.0, "READY plant at rest (upright, healthy)")
	# Colas pulse around their own base while READY: judge the rest pose.
	for cola in _plant_node(plot, "Tilt/Bouncer/Grow/Ready/Buds").get_children():
		Juice.stop(cola)
	await get_tree().physics_frame
	var body := plot.get_node("Body") as StaticBody3D
	var plant_shape := plot.get_node("Body/PlantShape") as CollisionShape3D
	var box := plant_shape.shape as BoxShape3D
	var shape_aabb := AABB(plant_shape.position - box.size * 0.5, box.size)  # Body is at the plot origin, unrotated
	# Every visible READY mesh (leaves + colas, at rest) inside the hitbox, in plot space.
	var ready := _plant_node(plot, "Tilt/Bouncer/Grow/Ready")
	var model_box := AABB()
	var first := true
	for mi: MeshInstance3D in ready.find_children("*", "MeshInstance3D", true, false):
		if mi.has_meta(&"toonify_outline") or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b: AABB = plot.global_transform.affine_inverse() * mi.global_transform * mi.get_aabb()
		model_box = b if first else model_box.merge(b)
		first = false
	check(not first and shape_aabb.grow(0.01).encloses(model_box), "PlantShape %s encloses the READY model %s" % [shape_aabb, model_box])
	check(model_box.end.y > 1.5 and model_box.end.y < shape_aabb.end.y, "READY cola top %.2f m under the hitbox top %.2f m" % [model_box.end.y, shape_aabb.end.y])
	var xf := plot.global_transform
	var cola_top := xf * Vector3(0.0, model_box.end.y - 0.04, 0.0)
	var leaf_y := model_box.position.y + model_box.size.y * 0.45
	var targets := {
		"cola top": cola_top,
		"left leaves": xf * Vector3(model_box.position.x + 0.05, leaf_y, 0.0),
		"right leaves": xf * Vector3(model_box.end.x - 0.05, leaf_y, 0.0),
	}
	# Eye positions 2.5 m from the plot centre (plot-local directions), 1.6 m up.
	var eyes := {"front": Vector3(0, 0, 1), "side": Vector3(1, 0, 0), "diagonal": Vector3(-1, 0, 1).normalized(), "back": Vector3(0, 0, -1)}
	var ready_hits: PackedStringArray = []
	var ready_ok := true
	for side: String in eyes:
		var eye := xf * ((eyes[side] as Vector3) * 2.5) + Vector3.UP * 1.6
		for what: String in targets:
			var hit := _ray(eye, targets[what])
			var got := _hit_name(hit)
			if hit.is_empty() or hit["collider"] != body or got != "HitboxPlot/PlantShape":
				ready_ok = false
				ready_hits.append("%s/%s -> '%s'" % [side, what, got])
	check(ready_ok, "READY: eye-height rays from 2.5 m (front, side, diagonal, back) hit the plant at the cola top and both side leaves",
		", ".join(ready_hits))
	var front_eye := xf * Vector3(0, 0, 2.5) + Vector3.UP * 1.6
	var soil := xf * Vector3(0.0, 0.45, 0.0)
	check(_hit_name(_ray(front_eye, soil)).begins_with("HitboxPlot/"), "READY: looking at the soil still targets the plot")
	# EMPTY: the tray is what you hit; the plant box is off, so aiming where the cola was hits nothing.
	plot.server_reset()
	for i in 3:
		await get_tree().physics_frame
	check(plant_shape.disabled, "EMPTY: plant hitbox disabled")
	check(_hit_name(_ray(front_eye, soil)) == "HitboxPlot/Shape", "EMPTY: an eye-height ray from 2.5 m at the soil hits the tray",
		_hit_name(_ray(front_eye, soil)))
	check(_hit_name(_ray(front_eye, xf * Vector3(0.0, 0.3, 0.72))) == "HitboxPlot/Shape", "EMPTY: the tray's front rim is hit")
	check(_ray(front_eye, cola_top).is_empty(), "EMPTY: aiming where the READY cola stood hits nothing (no invisible plant box)",
		_hit_name(_ray(front_eye, cola_top)))
	# A growing plant turns the box back on.
	plot.server_plant(&"budget")
	for i in 3:
		await get_tree().physics_frame
	check(not plant_shape.disabled and _hit_name(_ray(front_eye, xf * Vector3(0.0, 0.7, 0.0))) == "HitboxPlot/PlantShape",
		"planted: the plant hitbox is back on")
	await _free_node(plot)

func _test_harvest_with_items() -> void:
	Game.world = _fake_world
	_hold(null)
	var plot := await _new_plot()
	plot.server_plant(&"golden")
	plot.water = 0.6
	plot.stage = GrowPlot.Stage.READY
	_fake_items.set(&"refuse_spawn", true)
	check(not plot.server_harvest(_player) and plot.stage == GrowPlot.Stage.READY, "harvest keeps the plant if the product spawn fails")
	_fake_items.set(&"refuse_spawn", false)
	var blocker := _make_item(Const.ITEM_PRODUCT)
	_hold(blocker)
	var before := _spawned().size()
	check(not plot.server_harvest(_player) and _spawned().size() == before, "harvest refused with full hands")
	_hold(null)
	check(plot.server_harvest(_player), "harvest succeeds with empty hands")
	var last: Dictionary = _spawned().back()
	var golden := Config.balance.get_seed(&"golden")
	check(last["type"] == Const.ITEM_PRODUCT and last["holder"] == PEER and last["props"].get("strain_id") == &"golden"
		and last["props"].get("amount") == golden.yield_amount,
		"harvest spawns product {strain_id, amount = yield_amount} in the player's hands", str(last))
	check(plot.stage == GrowPlot.Stage.EMPTY and plot.strain_id == &"" and plot.stage_progress == 0.0 and approx(plot.water, 0.6),
		"harvest resets the plot to EMPTY (soil keeps its water)")
	# null player -> product dropped in front of the plot
	plot.server_plant(&"budget")
	plot.stage = GrowPlot.Stage.READY
	check(plot.server_harvest(null) and (_spawned().back() as Dictionary)["holder"] == 0, "harvest with no player drops the product on the floor")
	Game.world = null
	await _free_node(plot)

func _test_plot_interactions() -> void:
	Game.world = _fake_world
	var plot := await _new_plot()
	var packet := _make_item(Const.ITEM_SEED_PACKET, {"strain_id": &"budget"})
	var bad_packet := _make_item(Const.ITEM_SEED_PACKET, {"strain_id": &"nope"})
	var can := _make_item(Const.ITEM_WATERING_CAN, {"charges": 2, "capacity": 4})
	var product := _make_item(Const.ITEM_PRODUCT)
	# EMPTY
	_hold(null)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Needs seeds." and plot.get_prompt(_player) == "Empty tray",
		"EMPTY + empty hands: denied 'Needs seeds.'")
	_hold(can)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Needs seeds.", "EMPTY + can: denied 'Needs seeds.'")
	_hold(bad_packet)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Unknown seed.", "EMPTY + unknown packet: denied")
	_hold(packet)
	check(plot.can_interact(_player) and plot.get_prompt(_player) == "Plant Budget Bud", "EMPTY + packet: 'Plant Budget Bud'", plot.get_prompt(_player))
	plot._server_interact(_player)
	check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == &"budget", "interact with packet plants the strain")
	check((_fake_items.get(&"despawned") as Array).has(packet), "planting despawns the seed packet")
	# growing
	_hold(null)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Dry. Needs water.", "growing + dry + empty hands: 'Dry. Needs water.'")
	check(plot.get_prompt(_player).begins_with("Budget Bud"), "growing prompt shows strain + status", plot.get_prompt(_player))
	_hold(packet)
	check(plot.get_denied_reason(_player) == "Already planted.", "growing + packet: 'Already planted.'")
	_hold(can)
	check(plot.can_interact(_player) and plot.get_prompt(_player) == "Water plant (dry)", "growing + can: 'Water plant (dry)'", plot.get_prompt(_player))
	plot._server_interact(_player)
	check(approx(plot.water, minf(1.0, Config.balance.water_per_charge)) and can.get(&"charges") == 1, "watering uses one charge and adds water_per_charge")
	plot.water = 1.0
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Already watered.", "full plot: 'Already watered.'")
	plot.water = 0.5
	can.set(&"charges", 0)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Can's empty.", "empty can: 'Can's empty.'")
	_hold(null)
	check(plot.get_denied_reason(_player).begins_with("Not ready. ") and plot.get_denied_reason(_player).ends_with("%"),
		"watered + empty hands: 'Not ready. N%'", plot.get_denied_reason(_player))
	# READY
	plot.stage = GrowPlot.Stage.READY
	_hold(product)
	check(not plot.can_interact(_player) and plot.get_denied_reason(_player) == "Hands full.", "READY + item: 'Hands full.'")
	_hold(null)
	check(plot.can_interact(_player) and plot.get_prompt(_player) == "Harvest Budget Bud x1", "READY + empty hands: 'Harvest Budget Bud x1'", plot.get_prompt(_player))
	var before := _spawned().size()
	plot._server_interact(_player)
	check(plot.stage == GrowPlot.Stage.EMPTY and _spawned().size() == before + 1, "interact on READY harvests")
	check(not plot.can_interact(null) and plot.get_prompt(null) == "Empty tray", "null player is handled")
	Game.world = null
	await _free_node(plot)

func _test_well_interactions() -> void:
	Game.world = _fake_world
	var well := (load(WELL_SCENE) as PackedScene).instantiate() as Well
	_root3d.add_child(well)
	await get_tree().process_frame
	var can := _make_item(Const.ITEM_WATERING_CAN, {"charges": 1, "capacity": 4})
	var product := _make_item(Const.ITEM_PRODUCT)
	_hold(null)
	check(not well.can_interact(_player) and well.get_denied_reason(_player) == "Needs a can.", "well + empty hands: 'Needs a can.'")
	_hold(product)
	check(not well.can_interact(_player) and well.get_denied_reason(_player) == "Needs a can.", "well + product: denied")
	_hold(can)
	check(well.can_interact(_player) and well.get_prompt(_player) == "Fill can (1/4)", "well + part-empty can: 'Fill can (1/4)'", well.get_prompt(_player))
	well._server_interact(_player)
	check(can.get(&"charges") == 4, "well fills the can to get_capacity()")
	check(not well.can_interact(_player) and well.get_denied_reason(_player) == "Can's full.", "well + full can: 'Can's full.'")
	check(not well.server_fill_can(product) and not well.server_fill_can(null), "server_fill_can rejects non-cans")
	Game.world = null
	await _free_node(well)

func _test_well_starting_cans() -> void:
	var spawned_before := _spawned().size()
	# Client: never spawns.
	Net.is_host = false
	var well := (load(WELL_SCENE) as PackedScene).instantiate() as Well
	_root3d.add_child(well)
	await get_tree().process_frame
	Game.world_ready.emit(_fake_world)
	await get_tree().process_frame
	check(_spawned().size() == spawned_before, "well does not spawn cans on a client")
	await _free_node(well)
	# Host: spawns starting_watering_cans full cans at the CanSpots, once.
	Net.is_host = true
	well = (load(WELL_SCENE) as PackedScene).instantiate() as Well
	_root3d.add_child(well)
	await get_tree().process_frame
	check(_spawned().size() == spawned_before, "well does not spawn from _ready (waits for world_ready)")
	Game.world_ready.emit(_fake_world)
	await get_tree().process_frame
	var n: int = Config.balance.starting_watering_cans
	var new_spawns := _spawned().slice(spawned_before)
	var spots := well.get_can_spots()
	var all_ok := new_spawns.size() == n
	for i in new_spawns.size():
		var e: Dictionary = new_spawns[i]
		all_ok = all_ok and e["type"] == Const.ITEM_WATERING_CAN and e["props"].get("charges") == GameState.get_can_capacity() and e["holder"] == 0
		if i < spots.size():
			all_ok = all_ok and (e["position"] as Vector3).is_equal_approx(spots[i].global_position)
	check(all_ok, "host spawns %d full watering cans at the CanSpots on world_ready" % n, str(new_spawns))
	Game.world_ready.emit(_fake_world)
	await get_tree().process_frame
	check(_spawned().size() == spawned_before + n, "starting cans spawn only once")
	Net.is_host = false
	await _free_node(well)

func _test_process_authority() -> void:
	GameState.phase = GameState.Phase.PLAYING
	var plot := await _new_plot(true)
	plot.server_plant(&"budget")
	plot.water = 1.0
	Net.is_host = false
	for i in 20:
		await get_tree().process_frame
	check(plot.water == 1.0 and plot.stage_progress == 0.0, "_process does not tick when Net.is_host is false")
	Net.is_host = true
	for i in 20:
		await get_tree().process_frame
	check(plot.water < 1.0 and plot.stage_progress > 0.0, "_process ticks on the host while PLAYING")
	GameState.phase = GameState.Phase.MENU
	var w := plot.water
	for i in 10:
		await get_tree().process_frame
	check(plot.water == w, "_process stops ticking outside PLAYING")
	Net.is_host = false
	await _free_node(plot)
