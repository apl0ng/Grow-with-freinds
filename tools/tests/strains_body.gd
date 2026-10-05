extends "res://tools/tests/qa_base.gd"
## M12 strains suite (strains agent): the seven seed strains (M18: Black Damp) in data/balance.tres (ids unique, the M12 numbers and
## mutation chances, house-tone copy, Story blurbs), every strain bought at the counter, planted, watered, grown,
## harvested and deposited through the real stations' server API on a single headless host with a fake worker, the
## SUPPLY WINDOW holding seven cards, and the three M12 GLBs (hostile_plant, emergency_cabinet, flamethrower): root,
## size, origin, facing and the rigged nodes the scenes will drive.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/strains_body.gd --port=7954
## Every engine/script error fails the run unless announced (qa_base.gd).

const MODELS_DIR := "res://art/models/"
## id -> [display_name, cost, grow mult, yield, value, mutation]
const EXPECTED := {
	"budget": ["Budget Bud", 20, 1.0, 1, 60, 0.0],
	"purple": ["Purple Haze", 45, 1.3, 1, 140, 0.05],
	"golden": ["Golden Kush", 90, 1.6, 2, 125, 0.1],
	"nightshift": ["Night Shift", 70, 1.2, 1, 210, 0.35],
	"creeper": ["Creeper", 30, 0.8, 1, 70, 0.12],
	"brick": ["Floor Brick", 120, 2.0, 3, 110, 0.2],
	"damp": ["Black Damp", 80, 1.8, 1, 245, 0.05],  # M18 spores
}
## M14 loop: id -> [thirst_multiplier, dark_growth_multiplier, spread_chance, heavy, counted, trait_text, card tag]
const TRAITS := {
	"budget": [1.0, 0.0, 0.0, false, false, "", "SEED PACKET"],
	"purple": [1.6, 0.0, 0.0, false, false, "Thirsty.", "THIRSTY"],
	"golden": [1.0, 0.0, 0.0, false, true, "Counted.", "COUNTED"],
	"nightshift": [1.0, 2.0, 0.0, false, false, "Grows in the dark.", "GROWS IN THE DARK"],
	"creeper": [1.0, 0.0, 0.33, false, false, "Spreads.", "SPREADS"],
	"brick": [1.0, 0.0, 0.0, true, false, "Heavy.", "HEAVY"],
	"damp": [1.0, 0.0, 0.0, false, false, "Spores.", "SPORES"],  # M18 spores: SeedDef.spores is its one trait
}
const WORKER := 2

var _world: World
var _room: Room
var _worker: Player


func _run() -> void:
	_label = "strains"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance

	step("data")
	_test_data(b)

	step("hosting")
	Game.start_host("Tester", port_arg(7954))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish()
		return
	_world = Game.world
	_room = _world.room
	Net.players[WORKER] = {"name": "Worker %d" % WORKER, "color": Net.PALETTE[(WORKER - 1) % Net.PALETTE.size()]}
	_worker = _world.server_spawn_player(WORKER)
	await wait_frames(3)
	check(_worker != null and _world.get_players().size() == 2, "host + 1 fake worker spawned")
	check(_room.get_station("ShopCounter") is ShopCounter and _room.get_station("TurnInStation") is TurnInStation,
			"counter + chute stations exist")
	for i in range(1, 8):  # M18 spores: seven strains, seven trays
		check(_room.get_station("GrowPlot%d" % i) is GrowPlot, "GrowPlot%d exists (one plot per strain)" % i)

	step("shift start")
	# Seven strains deposited in a row outsell a first shift's quota (the round would end PAID after the third one):
	# this run is about the stations, so the shift runs to the timer.
	b.end_round_on_quota_met = false
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(2000)
	await wait_frames(1)

	step("every strain through the stations")
	# M14 loop: Creeper spreads on one harvest in three; this loop pins "the plot is empty again", so the dice are held
	# (tools/tests/loop_body.gd covers both outcomes of the roll).
	GrowPlot.spread_force = GrowPlot.SPREAD_NEVER
	var i := 0
	for seed_def: SeedDef in b.seeds:
		i += 1
		await _test_strain_loop(b, seed_def, i)
	GrowPlot.spread_force = GrowPlot.SPREAD_ROLL

	step("supply window")
	await _test_shop_ui(b)

	step("models")
	await _test_models()
	finish()


# --- data -----------------------------------------------------------------------------------------------------------

func _test_data(b: BalanceConfig) -> void:
	check(b.seeds.size() == 7, "seven strains in data/balance.tres (%d)" % b.seeds.size())
	var ids: Dictionary = {}
	var order: PackedStringArray = []
	for s: SeedDef in b.seeds:
		if s == null:
			check(false, "a seed entry is null")
			continue
		ids[s.id] = true
		order.append(String(s.id))
	check(ids.size() == b.seeds.size(), "strain ids are unique (%s)" % [order])
	check(order == PackedStringArray(["budget", "purple", "golden", "nightshift", "creeper", "brick", "damp"]),
			"the three M12 strains follow the original three, then M18's Black Damp, in contract order (%s)" % [order])
	for id: String in EXPECTED:
		var want: Array = EXPECTED[id]
		var s: SeedDef = b.get_seed(StringName(id))
		if not check(s != null, "get_seed(%s) finds it" % id):
			continue
		check(s.display_name == want[0], "%s is '%s' (got '%s')" % [id, want[0], s.display_name])
		check(s.cost == want[1], "%s cost %d (got %d)" % [id, want[1], s.cost])
		check(is_equal_approx(s.grow_time_multiplier, want[2]), "%s grow x%.1f (got %.2f)" % [id, want[2], s.grow_time_multiplier])
		check(s.yield_amount == want[3], "%s yield %d (got %d)" % [id, want[3], s.yield_amount])
		check(s.sale_value_per_unit == want[4], "%s value $%d (got $%d)" % [id, want[4], s.sale_value_per_unit])
		check(is_equal_approx(s.mutation_chance, want[5]), "%s mutation chance %.2f (got %.2f)" % [id, want[5], s.mutation_chance])
		check(s.mutation_chance >= 0.0 and s.mutation_chance <= 1.0, "%s mutation chance within [0, 1]" % id)
		check(s.color.a > 0.99 and s.color.v > 0.2, "%s has an opaque, visible colour (%s)" % [id, s.color.to_html(false)])
		check(not s.description.contains("!") and s.description.strip_edges() != "", "%s description is flat (no '!')" % id)
		check(not s.display_name.contains("!"), "%s display name has no '!'" % id)
		var blurb := Story.get_blurb(s.id, "")
		check(blurb != "" and not blurb.contains("!"), "%s has a Story blurb without '!' ('%s')" % [id, blurb])
		for digit in "0123456789":
			if blurb.contains(digit):
				check(false, "%s blurb is number-free (cards compute the numbers): '%s'" % [id, blurb])
				break
	# The new colours stay apart from each other and from the old three (the packets, buds and product read as data).
	var colours: Array[Color] = []
	for s: SeedDef in b.seeds:
		colours.append(s.color)
	var min_dist := 10.0
	for a in colours.size():
		for c in range(a + 1, colours.size()):
			var d := Vector3(colours[a].r - colours[c].r, colours[a].g - colours[c].g, colours[a].b - colours[c].b).length()
			min_dist = minf(min_dist, d)
	check(min_dist > 0.25, "every pair of strain colours is at least 0.25 apart in RGB (closest %.2f)" % min_dist)
	check(b.get_seed(&"nightshift").color.b > b.get_seed(&"nightshift").color.g and b.get_seed(&"nightshift").color.v < 0.65,
			"Night Shift is a dark violet")
	var creeper := b.get_seed(&"creeper").color
	check(creeper.g > creeper.r and creeper.b > creeper.r, "Creeper is teal")
	var brick := b.get_seed(&"brick").color
	check(brick.r > brick.g and brick.g > brick.b, "Floor Brick is rust")
	var damp := b.get_seed(&"damp").color  # M18 spores
	check(damp.v < 0.35 and damp.s < 0.35 and damp.g >= damp.r and damp.g > damp.b, "Black Damp is a dark, mouldy grey-green (%s)" % damp.to_html(false))
	var dp := b.get_seed(&"damp")
	var best_unit := 0
	for s: SeedDef in b.seeds:
		if s != dp:
			best_unit = maxi(best_unit, s.sale_value_per_unit)
	check(dp.sale_value_per_unit > best_unit and dp.grow_time_multiplier > b.get_seed(&"golden").grow_time_multiplier and dp.spores,
			"Black Damp pays the most a unit ($%d against $%d) and grows slower than Golden Kush (x%.1f): the spores are the catch" % [dp.sale_value_per_unit, best_unit, dp.grow_time_multiplier])
	# The contract's pay-off: the strains with a temper pay better per plant than the safe ones.
	var ns := b.get_seed(&"nightshift")
	check(ns.sale_value_per_unit * ns.yield_amount - ns.cost > 60 - 20, "Night Shift margins beat Budget Bud")
	var br := b.get_seed(&"brick")
	check(br.sale_value_per_unit * br.yield_amount - br.cost == 210, "Floor Brick margin is $210 (3 x $110 - $120)")
	check(b.get_seed(&"budget").mutation_chance == 0.0, "Budget Bud never turns")
	# M16 polish: the cap. No strain's own chance is above it, and on a plain day the chance is the strain's own.
	check(is_equal_approx(b.mutation_chance_cap, 0.5), "the cap on a walking plant's chance is %.2f" % b.mutation_chance_cap)
	for s: SeedDef in b.seeds:
		check(s.mutation_chance <= b.mutation_chance_cap and is_equal_approx(GrowPlot.get_mutation_chance(s), s.mutation_chance),
				"%s: %.2f on a plain day, under the cap" % [s.id, GrowPlot.get_mutation_chance(s)])
	_test_traits(b)


# --- M14 loop: one trait per strain ---------------------------------------------------------------------------------

func _test_traits(b: BalanceConfig) -> void:
	for id: String in TRAITS:
		var want: Array = TRAITS[id]
		var s: SeedDef = b.get_seed(StringName(id))
		if s == null:
			continue
		check(is_equal_approx(s.thirst_multiplier, want[0]), "%s thirst x%.1f (got %.2f)" % [id, want[0], s.thirst_multiplier])
		check(is_equal_approx(s.dark_growth_multiplier, want[1]), "%s dark growth x%.1f (got %.2f)" % [id, want[1], s.dark_growth_multiplier])
		check(is_equal_approx(s.spread_chance, want[2]), "%s spread chance %.2f (got %.2f)" % [id, want[2], s.spread_chance])
		check(s.heavy == want[3], "%s heavy %s (got %s)" % [id, want[3], s.heavy])
		check(s.counted == want[4], "%s counted %s (got %s)" % [id, want[4], s.counted])
		check(s.trait_text == want[5], "%s trait text '%s' (got '%s')" % [id, want[5], s.trait_text])
		check(not s.trait_text.contains("!") and (s.trait_text == "" or s.trait_text.ends_with(".")), "%s trait text is flat (no '!', a full stop)" % id)
		check(ShopCard.get_seed_tag(s) == want[6], "%s card tag '%s' (got '%s')" % [id, want[6], ShopCard.get_seed_tag(s)])
		var traits := 0
		for on: bool in [not is_equal_approx(s.thirst_multiplier, 1.0), s.dark_growth_multiplier > 0.0, s.spread_chance > 0.0, s.heavy, s.counted, s.spores]:  # M18 spores
			if on:
				traits += 1
		check(traits == (0 if id == "budget" else 1), "%s carries %s (%d)" % [id, "no trait: the control group" if id == "budget" else "exactly one trait", traits])
		check((s.trait_text == "") == (traits == 0), "%s names its trait on the card exactly when it has one" % id)
	check(is_equal_approx(b.cure_sec, 45.0) and is_equal_approx(b.cure_bonus, 0.4), "drying: %.0f s on the rack for +%d%%" % [b.cure_sec, roundi(b.cure_bonus * 100.0)])
	check(is_equal_approx(b.heavy_speed_factor, 0.7) and b.counted_fine == 25, "heavy carry x%.1f, counted fine $%d" % [b.heavy_speed_factor, b.counted_fine])


# --- the loop, per strain -------------------------------------------------------------------------------------------

## Buys a packet of `seed_def` at the counter (server API), plants it in GrowPlot `index` through the plot's
## interaction (packet in hand), waters it, grows it with the plot's own tick, harvests into the worker's hands
## and deposits the product at the chute. Money and sales move by the data's numbers.
func _test_strain_loop(b: BalanceConfig, seed_def: SeedDef, index: int) -> void:
	var tag := "%s: " % seed_def.id
	var counter := _room.get_station("ShopCounter") as ShopCounter
	var chute := _room.get_station("TurnInStation") as TurnInStation
	var plot := _room.get_station("GrowPlot%d" % index) as GrowPlot
	if counter == null or chute == null or plot == null or _worker == null:
		check(false, tag + "stations and the worker exist")
		return
	# Buy: the worker stands at the counter with empty hands.
	teleport(_worker, counter)
	var money0 := GameState.money
	var result := counter.server_buy_seed(WORKER, seed_def.id)
	check(bool(result.get("ok", false)), tag + "server_buy_seed ok (%s)" % [result])
	check(GameState.money == money0 - seed_def.cost, tag + "costs $%d (money %d -> %d)" % [seed_def.cost, money0, GameState.money])
	var packet := _world.items.get_held_by(WORKER)
	check(packet != null and packet.item_type == Const.ITEM_SEED_PACKET and GrowPlot.get_packet_strain(packet) == seed_def.id,
			tag + "a %s packet is in the worker's hands" % seed_def.id)
	if packet == null:
		return
	# Plant through the plot's own interaction (the packet is consumed).
	teleport(_worker, plot)
	check(plot.is_empty(), tag + "GrowPlot%d is empty" % index)
	plot._server_interact(_worker)
	await wait_frames(2)
	check(plot.stage == GrowPlot.Stage.SEEDLING and plot.strain_id == seed_def.id, tag + "planted (stage %s, strain %s)" % [plot.get_stage_name(), plot.strain_id])
	check(_world.items.get_held_by(WORKER) == null, tag + "the packet was consumed")
	check(plot.get_seed() == seed_def and plot.get_strain_name() == seed_def.display_name, tag + "the plot knows its strain")
	# Water + grow: one tick per stage, re-watered before each (tick drains after it grows).
	check(plot.server_water(1.0) and plot.water > 0.5, tag + "watered")
	var grow_mult := GameState.get_growth_speed_multiplier()
	var total := 0.0
	for k in 3:
		var stage_before := plot.stage
		var duration := plot.get_stage_duration(plot.stage)
		plot.water = 1.0
		plot.tick(duration / grow_mult + 0.01)
		total += duration
		check(plot.stage != stage_before, tag + "stage %d advanced after %.1f s" % [k + 1, duration])
	check(plot.is_ready_to_harvest(), tag + "READY after %.0f s of growth (x%.1f of the base stages)" % [total, seed_def.grow_time_multiplier])
	check(is_equal_approx(total, b.total_grow_time(seed_def)), tag + "stage durations sum to total_grow_time (%.1f)" % total)
	# Harvest into the worker's hands through the interaction.
	plot._server_interact(_worker)
	await wait_frames(2)
	var product := _world.items.get_held_by(WORKER)
	check(product != null and product.item_type == Const.ITEM_PRODUCT, tag + "harvest put a product in the worker's hands")
	check(plot.is_empty() and plot.strain_id == &"", tag + "the plot is empty again")
	if product == null:
		return
	check(StringName(str(product.get(&"strain_id"))) == seed_def.id and int(product.get(&"amount")) == seed_def.yield_amount,
			tag + "product is %d x %s" % [seed_def.yield_amount, seed_def.id])
	# Deposit at the chute (server API).
	teleport(_worker, chute)
	var sales0 := GameState.round_sales
	var want := TurnInStation.compute_sale_value(seed_def, seed_def.yield_amount, GameState.get_sale_multiplier())
	check(want == seed_def.yield_amount * seed_def.sale_value_per_unit, tag + "sale value = yield x value ($%d)" % want)
	check(chute.get_sale_value(product) == want, tag + "the chute prices it at $%d" % want)
	money0 = GameState.money
	check(chute.server_sell_item(product, WORKER), tag + "server_sell_item ok")
	await wait_frames(2)
	check(GameState.money == money0 + want, tag + "paid $%d (money %d -> %d)" % [want, money0, GameState.money])
	check(GameState.round_sales == sales0 + want, tag + "round sales +$%d" % want)
	check(_world.items.get_held_by(WORKER) == null, tag + "the product left the worker's hands")
	check(GameState.get_stat(WORKER, Const.STAT_PLANTED) == index and GameState.get_stat(WORKER, Const.STAT_HARVESTED) == index,
			tag + "planted / harvested stats count the loop (%d)" % index)


# --- the SUPPLY WINDOW ----------------------------------------------------------------------------------------------

func _test_shop_ui(b: BalanceConfig) -> void:
	var counter := _room.get_station("ShopCounter") as ShopCounter
	var me: Player = Game.local_player
	if counter == null or me == null:
		check(false, "counter + local player for the shop UI")
		return
	teleport(me, counter)
	counter.interact(me)
	await wait_frames(6)   # the scroll fit settles over a few deferred sorts
	var ui := counter.get_shop_ui()
	if not check(ui != null and ui.is_open(), "the counter opens the SUPPLY WINDOW locally"):
		return
	var cards := ui.get_cards(ShopCounter.KIND_SEED)
	check(cards.size() == 7, "seven seed cards (%d)" % cards.size())
	for seed_def: SeedDef in b.seeds:
		var card := ui.get_card(ShopCounter.KIND_SEED, seed_def.id)
		if not check(card != null, "card for %s" % seed_def.id):
			continue
		var stats := card.get_stats_text()
		var sells := seed_def.yield_amount * seed_def.sale_value_per_unit
		check(stats.contains("Deposits for $%d" % sells) and not stats.contains("!"), "%s card deposits for $%d, no '!'" % [seed_def.id, sells])
		check(card.is_buy_enabled(), "%s card is buyable with the cash on hand" % seed_def.id)
		# M14 loop: the trait sits on the tag line that was already there, whole (no ellipsis), and the blurb names it.
		var want_tag: String = TRAITS[String(seed_def.id)][6]
		check(card.get_tag_text() == want_tag, "%s card tag reads '%s' (got '%s')" % [seed_def.id, want_tag, card.get_tag_text()])
		var tag := card.find_child("TagLabel", true, false) as Label
		if check(tag != null, "%s card has its tag label" % seed_def.id):
			var need := tag.get_theme_font(&"font").get_string_size(tag.text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, tag.get_theme_font_size(&"font_size")).x
			check(need <= tag.size.x + 0.5, "%s tag fits its line (%.0f px of %.0f)" % [seed_def.id, need, tag.size.x])
		var desc := card.find_child("DescLabel", true, false) as Label
		check(desc != null and desc.get_line_count() <= 2, "%s blurb still fits two lines (%d)" % [seed_def.id, desc.get_line_count() if desc != null else -1])
	var grid := ui.find_child("SeedGrid", true, false) as GridContainer
	check(grid != null and grid.columns == 3 and grid.get_child_count() == 7, "seed grid: 3 columns, 3 rows of cards (M18: the seventh starts the third row)")
	var panel := ui.find_child("Panel", true, false) as Control
	var viewport_size := ui.get_viewport().get_visible_rect().size
	var scroll_h: float = ui.get_scroll_height()
	check(scroll_h >= 340.0, "the scroll area keeps its 340 px floor (%.0f)" % scroll_h)
	if panel != null:
		var need := panel.get_combined_minimum_size()
		check(need.y <= viewport_size.y and need.x <= viewport_size.x,
				"the window fits the %s viewport (needs %s)" % [viewport_size, need])
	var card_h := 0.0
	for c in cards:
		card_h = maxf(card_h, c.get_combined_minimum_size().y)
	var rows := ceili(cards.size() / 3.0)  # M18 spores: three rows with the seventh card
	var all_rows := rows * card_h + (rows - 1) * 14.0 + 14.0
	var room := viewport_size.y - ShopUI.PANEL_CHROME_HEIGHT
	var want_h := maxf(ShopUI.SCROLL_MIN_HEIGHT, minf(all_rows, room))
	check(absf(scroll_h - want_h) <= 1.0,
			"the scroll area shows as many of the %d rows as the screen allows (cards %.0f px, scroll %.0f px, want %.0f)" % [rows, card_h, scroll_h, want_h])
	var hint := ui.get_node_or_null(^"Root/Panel/VBox/Footer/Hint") as Label
	check(hint != null and hint.text == (ShopUI.HINT_SCROLL if all_rows > scroll_h + 1.0 else ShopUI.HINT_DEFAULT),
			"the footer says whether a row is below the fold ('%s')" % (hint.text if hint != null else "?"))
	check(scroll_h > ShopUI.SCROLL_MIN_HEIGHT, "on a %s window it shows more than the one-row floor" % viewport_size)
	ui.close(false)
	await wait_frames(1)
	check(not ui.is_open() and not Game.is_ui_locked_by(ShopCounter.UI_LOCK_SOURCE), "closed again, the shop's UI lock released")


# --- the models -----------------------------------------------------------------------------------------------------

static func _model_meshes(n: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if n is MeshInstance3D and not n.has_meta(&"toonify_outline"):
		out.append(n as MeshInstance3D)
	for m in n.find_children("*", "MeshInstance3D", true, false):
		if not m.has_meta(&"toonify_outline"):
			out.append(m as MeshInstance3D)
	return out


static func _rel(n: Node, space: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var p := n
	while p != null and p != space:
		if p is Node3D:
			t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


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


static func _tris(node: Node) -> int:
	var tris := 0
	for mi in _model_meshes(node):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(s)
			var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			tris += (idx.size() if idx.size() > 0 else verts.size()) / 3
	return tris


## Mean position (in `space`) of every vertex drawn with the source material `mat_name`.
static func _surface_mean(node: Node, space: Node, mat_name: String) -> Vector3:
	var sum := Vector3.ZERO
	var n := 0
	for mi in _model_meshes(node):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			if Toonify.material_name(mi.mesh.surface_get_material(s)) != mat_name:
				continue
			var t := _rel(mi, space)
			for v in (mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX] as PackedVector3Array):
				sum += t * v
				n += 1
	return sum / maxf(n, 1.0) if n > 0 else Vector3(NAN, NAN, NAN)


static func _material_names(node: Node) -> PackedStringArray:
	var out: PackedStringArray = []
	for mi in _model_meshes(node):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var nm := Toonify.material_name(mi.mesh.surface_get_material(s))
			if not out.has(nm):
				out.append(nm)
	return out


func _load_model(name: String, holder: Node3D, lo: Vector3, hi: Vector3, budget: int) -> Node3D:
	var tag := name + ": "
	var ps := load(MODELS_DIR + name + ".glb") as PackedScene
	if not check(ps != null and ps.can_instantiate(), tag + "art/models/%s.glb loads" % name):
		return null
	var n := ps.instantiate() as Node3D
	holder.add_child(n)
	await get_tree().process_frame
	check(n is Toonify, tag + "root is a Toonify node")
	var b := _bounds(n, n)
	check(b.size.x >= lo.x and b.size.x <= hi.x and b.size.y >= lo.y and b.size.y <= hi.y and b.size.z >= lo.z
			and b.size.z <= hi.z, tag + "size %s within %s..%s" % [b.size, lo, hi])
	var tris := _tris(n)
	check(tris <= budget, tag + "within the %d tri budget (%d)" % [budget, tris])
	var names := _material_names(n)
	var bad := false
	for nm in names:
		if nm == "" or nm.begins_with("Material"):
			bad = true
	check(not bad and names.size() >= 3, tag + "named materials (%s)" % [names])
	var cfg := ConfigFile.new()
	check(cfg.load(MODELS_DIR + name + ".glb.import") == OK, tag + ".import sidecar exists (commit it)")
	return n


func _rig(root: Node3D, part: String) -> Node3D:
	var tag := String(root.scene_file_path.get_file().get_basename()) + ": "
	var n := root.get_node_or_null(NodePath(part)) as Node3D
	if not check(n != null, tag + "has the rigged node %s (a direct child of the root)" % part):
		return null
	check(n.rotation.is_zero_approx(), tag + "%s rest rotation is identity (got %s)" % [part, n.rotation])
	check(n.scale.is_equal_approx(Vector3.ONE), tag + "%s has no node scale" % part)
	return n


func _test_models() -> void:
	var holder := Node3D.new()
	holder.name = "Models"
	add_child(holder)
	# hostile_plant (character, mouth -Z): feet on the floor, about 1.1 m tall, the mouth (void) on the -Z side, the bud
	# recoloured by the strain tint, the Jaw a rigged child that drops open on rotation.x < 0.
	var hp := await _load_model("hostile_plant", holder, Vector3(0.6, 0.95, 0.6), Vector3(1.25, 1.25, 1.25), 8000)
	if hp != null:
		var b := _bounds(hp, hp)
		check(absf(b.position.y) < 0.01, "hostile_plant: stands on y = 0 (%.3f)" % b.position.y)
		check(b.end.y > 1.0 and b.end.y < 1.2, "hostile_plant: about 1.1 m tall (%.2f)" % b.end.y)
		check(absf(b.get_center().x) < 0.1 and absf(b.get_center().z) < 0.15, "hostile_plant: footprint centred on the origin (%s)" % b.get_center())
		var mouth := _surface_mean(hp, hp, "toon_void")
		check(mouth.z < -0.12 and mouth.y > 0.5 and mouth.y < 0.75, "hostile_plant: the mouth faces -Z at chest height (%s)" % mouth)
		var eyes := _surface_mean(hp, hp, "toon_eye_black")
		check(eyes.z < -0.1 and eyes.y > mouth.y, "hostile_plant: the eyes sit above the mouth on the -Z side (%s)" % eyes)
		var tinted := 0
		for mi in _model_meshes(hp):
			for s in mi.mesh.get_surface_count():
				if Toonify.is_tint(mi.mesh.surface_get_material(s)):
					tinted += 1
		check(tinted >= 2, "hostile_plant: the bud and its lips are TINT surfaces for the strain colour (%d)" % tinted)
		check(hp.get_node_or_null(^"Body") is MeshInstance3D, "hostile_plant: Body mesh exists (static)")
		var jaw := _rig(hp, "Jaw")
		if jaw != null:
			check(jaw.position.z < -0.15 and jaw.position.y > 0.5 and jaw.position.y < 0.7,
					"hostile_plant: the Jaw pivots on the mouth hinge (%s)" % jaw.position)
			var jb := _bounds(jaw, hp)
			check(jb.position.z < mouth.z and jb.get_center().y < mouth.y + 0.02, "hostile_plant: the chin hangs under the mouth at rest (%s)" % jb)
			jaw.rotation.x = deg_to_rad(-35.0)
			var jb2 := _bounds(jaw, hp)
			check(jb2.position.y < jb.position.y - 0.03, "hostile_plant: Jaw.rotation.x = -35 deg drops the chin (y %.2f -> %.2f)" % [jb.position.y, jb2.position.y])
		var roots := _surface_mean(hp, hp, "root")
		check(roots.y < 0.35, "hostile_plant: the root legs are low (%s)" % roots)
		hp.queue_free()
	# emergency_cabinet (prop, front +Z, wall): back on the wall plane, origin at the back centre, 0.45 x 0.6 x 0.2,
	# the Glass pane its own mesh, the Stock socket inside.
	var ec := await _load_model("emergency_cabinet", holder, Vector3(0.43, 0.58, 0.19), Vector3(0.5, 0.68, 0.27), 3000)
	if ec != null:
		var b := _bounds(ec, ec)
		check(absf(b.position.z) < 0.01, "emergency_cabinet: back on the wall plane (z %.3f)" % b.position.z)
		check(absf(b.position.y + 0.30) < 0.06 and absf(b.end.y - 0.30) < 0.02, "emergency_cabinet: origin at the back centre (y %.2f..%.2f)" % [b.position.y, b.end.y])
		check(absf(b.position.x + b.end.x) < 0.06, "emergency_cabinet: centred on x (%.2f..%.2f)" % [b.position.x, b.end.x])
		check(b.end.z >= 0.19 and b.end.z <= 0.22, "emergency_cabinet: 0.2 m deep (%.3f)" % b.end.z)
		var glass := ec.get_node_or_null(^"Glass") as MeshInstance3D
		if check(glass != null, "emergency_cabinet: Glass pane is its own mesh node"):
			var gb := _bounds(glass, ec)
			check(gb.size.x > 0.3 and gb.size.y > 0.3 and gb.size.z < 0.01 and gb.position.z > 0.17,
					"emergency_cabinet: the pane covers the opening at the front (%s)" % gb)
			var names := _material_names(glass)
			check(names.size() == 1 and names[0] == "toon_glass", "emergency_cabinet: the pane is toon_glass (%s)" % [names])
		var stock := ec.get_node_or_null(^"Stock") as Node3D
		check(stock != null and absf(stock.position.x) < 0.01 and absf(stock.position.y) < 0.01 and absf(stock.position.z - 0.10) < 0.01,
				"emergency_cabinet: Stock socket at the interior centre (0, 0, 0.10) (%s)" % (stock.position if stock else Vector3.INF))
		check(ec.get_node_or_null(^"Box") is MeshInstance3D, "emergency_cabinet: Box mesh exists (static)")
		var plate := _surface_mean(ec, ec, "toon_caution")
		check(plate.y > 0.2 and plate.z > 0.15, "emergency_cabinet: the caution plate sits above the glass on the front (%s)" % plate)
		var red := _surface_mean(ec, ec, "toon_red")
		check(not is_nan(red.x), "emergency_cabinet: it is a red box")
		ec.queue_free()
	# flamethrower (item, nozzle -Z, mount free): about 0.6 m long with the origin inside the grip; the Gauge/Fill rig
	# on the holder's side (+Z).
	var ft := await _load_model("flamethrower", holder, Vector3(0.1, 0.2, 0.55), Vector3(0.2, 0.3, 0.7), 2500)
	if ft != null:
		var b := _bounds(ft, ft)
		check(b.position.z < -0.28 and b.end.z > 0.25, "flamethrower: nozzle towards -Z, tank towards +Z (z %.2f..%.2f)" % [b.position.z, b.end.z])
		check(b.position.y < -0.05 and b.position.y > -0.1 and b.end.y > 0.15, "flamethrower: hangs around the grip origin (y %.2f..%.2f)" % [b.position.y, b.end.y])
		var grip := _surface_mean(ft, ft, "toon_dark")
		check(not is_nan(grip.x) and absf(grip.x) < 0.03, "flamethrower: the rubber parts are on the centre line (%s)" % grip)
		var soot := _surface_mean(ft, ft, "toon_void")
		check(soot.z < -0.25 or is_nan(soot.z), "flamethrower: the soot is at the nozzle (%s)" % soot)
		var red := _surface_mean(ft, ft, "toon_red")
		check(red.z > 0.1, "flamethrower: the red tank sits behind the grip (%s)" % red)
		check(ft.get_node_or_null(^"Gun") is MeshInstance3D, "flamethrower: Gun mesh exists (static)")
		var gauge := _rig(ft, "Gauge")
		var fill := ft.get_node_or_null(^"Gauge/Fill") as MeshInstance3D
		if gauge != null and check(fill != null, "flamethrower: Gauge/Fill mesh exists"):
			check(gauge.position.z > 0.2, "flamethrower: the gauge is on the holder's side (+Z) (%s)" % gauge.position)
			check(absf(fill.position.y - 0.04) < 0.005 and absf(fill.position.x) < 0.001, "flamethrower: Fill is centred 0.04 above the Gauge (%s)" % fill.position)
			var fb := fill.get_aabb()
			check(absf(fb.size.y - 0.08) < 0.005 and absf(fb.get_center().y) < 0.003, "flamethrower: Fill is 0.08 tall and centred on its node (%s)" % fb)
			fill.scale.y = 0.5
			fill.position.y = 0.08 * 0.5 / 2.0
			var half := _bounds(fill, ft)
			var full_bottom := gauge.position.y
			check(absf(half.position.y - full_bottom) < 0.005 and absf(half.size.y - 0.04) < 0.003,
					"flamethrower: scaling Fill like the watering can keeps the bar growing from the Gauge bottom (%s)" % half)
		ft.queue_free()
	await get_tree().process_frame
	holder.queue_free()
