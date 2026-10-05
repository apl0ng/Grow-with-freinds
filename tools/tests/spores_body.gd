extends "res://tools/tests/qa_base.gd"
## M18 spores suite (spores agent; CONTRACTS.md "M18", "Spores"): Black Damp and its spore clouds on a single headless
## host with two fake workers (Bob, Cara: host-side bodies without an owning peer). Plain game (no --replay).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/spores_body.gd --port=7938 --round-sec=900
## Pins:
##   the strain     Black Damp's numbers in data/balance.tres and tools/gen_balance.gd (the same line), its one trait
##                  (SeedDef.spores, "Spores.", the SPORES tag), its colour, the Story blurb, the M18 balance fields, the
##                  two sound recipes; with replay off it is sold from shift 1 like every strain (its data says 3)
##   the node       World/Spores on the host, its overlay between the view model and the HUD, hidden, never taking input
##   the tell       motes over a ripe Black Damp tray, none over another strain's
##   each cause     harvest, uproot, fire, a drive-by round, a thrown item: one puff each, the cloud over that tray; no
##                  puff from a tray that is not ripe, not Black Damp, or whose cloud still hangs
##   who breathes   by distance (the radius, the floor, a wall but not a doorway), crouched (half), walking in while the
##                  cloud hangs, topped up while standing in it (no second count); the cloud's end, the fog's end
##   the screen     the local worker's overlay fades in and out, the Master bus low-pass comes and goes, exactly that
##                  instance, with other effects around it left in place and in order
##   coughs         at the worker's head on this peer (the local one unpositioned), each at his own pitch, every few
##                  seconds; the haze on a fogged worker seen from outside
##   the report     the Boss's line once a shift, the FOGGED column and the verdict, the column gone on a clean shift
##   clean air      the end of a shift, START OVER and the menu clear clouds, fog, haze, overlay and the bus effect
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const CARA := 3
const DAMP := &"damp"
const PARK_ME := Vector3(-3.0, 0.0, 2.0)
const PARK_BOB := Vector3(-3.0, 0.0, -2.0)
const PARK_CARA := Vector3(-1.0, 0.0, -2.0)
const FIRST_LINE := "That's the damp, %s. Cough on your own time."
const VERDICT := "%s breathed the damp. Nobody opened a window."

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var cara: Player
var spores: Spores
var hud: Node
var _puffs: Array = []        # [plot_name, cause]
var _fog_events: Array = []   # [peer, seconds]
var _coughs: Dictionary = {}  # peer -> count (signal)
var _master0: int = 0


func _run() -> void:
	_label = "spores"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	_test_data(b)
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	_master0 = AudioServer.get_bus_effect_count(Spores.MASTER_BUS)

	step("hosting")
	Game.start_host("Tester", port_arg(7938))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD")
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	Net.players[CARA] = {"name": "Cara", "color": Net.PALETTE[CARA - 1]}
	bob = world.server_spawn_player(BOB)
	cara = world.server_spawn_player(CARA)
	await wait_frames(3)
	if not check(bob != null and cara != null and world.get_players().size() == 3, "host + Bob + Cara spawned"):
		finish(); return
	spores = Spores.get_instance()
	if not check(spores != null and spores.get_parent() == world and spores.name == "Spores", "World/Spores exists on the host"):
		finish(); return
	spores.puffed.connect(func(plot_name: String, cause: StringName) -> void: _puffs.append([plot_name, cause]))
	spores.fog_changed.connect(func(peer: int, seconds: float) -> void: _fog_events.append([peer, seconds]))
	spores.coughed.connect(func(peer: int) -> void: _coughs[peer] = int(_coughs.get(peer, 0)) + 1)
	_park()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(2000)
	await wait_frames(2)

	_test_node()
	await _test_sold(b)
	await _test_tell()
	_manual(true)
	await _test_causes(b)
	await _test_breathing(b)
	await _test_screen()
	_manual(false)
	await _test_coughs()
	await _test_report_and_round_end()
	await _test_reset()
	await _test_menu()
	finish()


# --- the strain --------------------------------------------------------------------------------------------------------

func _test_data(b: BalanceConfig) -> void:
	step("the strain: Black Damp")
	var d := b.get_seed(DAMP)
	if not check(d != null and b.seeds.size() == 7 and b.seeds[6] == d, "Black Damp is the seventh strain in data/balance.tres"):
		return
	check(d.display_name == "Black Damp" and d.cost == 80 and is_equal_approx(d.grow_time_multiplier, 1.8) and d.yield_amount == 1
			and d.sale_value_per_unit == 245, "cost $80, grows x1.8 (%.0f s), one unit at $245" % b.total_grow_time(d))
	check(is_equal_approx(d.mutation_chance, 0.05) and d.unlock_round == 3, "a small mutation chance (5 in 100), sold from shift 3")
	check(d.spores and d.trait_text == "Spores." and ShopCard.get_seed_tag(d) == "SPORES", "its trait: spores ('Spores.', the card tag SPORES)")
	var others := 0
	for s: SeedDef in b.seeds:
		if s != d and s.spores:
			others += 1
	check(others == 0 and Spores.has_spores(d) and not Spores.has_spores(b.get_seed(&"budget")) and not Spores.has_spores(null), "no other strain has spores")
	check(is_equal_approx(d.thirst_multiplier, 1.0) and d.dark_growth_multiplier == 0.0 and d.spread_chance == 0.0 and not d.heavy and not d.counted,
			"no second trait")
	check(d.color.v < 0.35 and d.color.s < 0.35 and d.color.a > 0.99, "a dark, mouldy colour (%s)" % d.color.to_html(false))
	check(not d.description.contains("!") and d.description != "", "the data line is flat: '%s'" % d.description)
	var blurb := Story.get_blurb(DAMP, "")
	var digits := false
	for digit in "0123456789":
		if blurb.contains(digit):
			digits = true
	check(blurb != "" and not blurb.contains("!") and not digits, "the card blurb is flat and number-free: '%s'" % blurb)
	var gen := FileAccess.get_file_as_string("res://tools/gen_balance.gd")
	check(gen.contains('_seed(&"damp", "Black Damp", "%s", 80, 1.8, 1, 245, Color(0.26, 0.29, 0.22), 0.05,' % d.description)
			and gen.contains('{"spores": true, "trait_text": "Spores."}, 3)'), "tools/gen_balance.gd writes the same strain")
	check(is_equal_approx(d.color.r, 0.26) and is_equal_approx(d.color.g, 0.29) and is_equal_approx(d.color.b, 0.22), "the same colour in both")
	check(is_equal_approx(b.spore_radius, 2.6) and is_equal_approx(b.spore_fog_sec, 9.0) and is_equal_approx(b.spore_cloud_sec, 6.0),
			"spores: %.1f m, fogged %.0f s, the cloud hangs %.0f s" % [b.spore_radius, b.spore_fog_sec, b.spore_cloud_sec])
	for n: StringName in [&"spore_puff", &"cough"]:
		var m: Dictionary = Sfx.measure(Sfx.get_stream(n))
		check(Sfx.has_sound(n) and float(m.seconds) > 0.5 and absf(float(m.dc)) < 0.01, "%s has a recipe of its own (%.2f s, not the 0.1 s blip)" % [n, m.seconds])


func _test_node() -> void:
	step("the node: World/Spores")
	var layer := spores.get_overlay()
	var rect := spores.get_overlay_rect()
	check(layer != null and layer.layer == Spores.OVERLAY_LAYER and layer.layer > Player.VIEW_MODEL_CANVAS_LAYER and layer.layer < (hud as CanvasLayer).layer,
			"the overlay layer sits over the view model (%d) and under the HUD (%d)" % [Player.VIEW_MODEL_CANVAS_LAYER, (hud as CanvasLayer).layer])
	check(rect != null and not rect.visible and rect.mouse_filter == Control.MOUSE_FILTER_IGNORE and rect.focus_mode == Control.FOCUS_NONE
			and rect.material is ShaderMaterial, "a full-screen shader rect, hidden, never takes the mouse or focus")
	check(spores.get_filter() == null and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 and spores.get_fogged_peers().is_empty()
			and spores.get_cloud_count() == 0, "clear air: no fog, no clouds, the Master bus untouched")


func _test_sold(b: BalanceConfig) -> void:
	step("replay off: sold from shift 1")
	check(GameState.is_strain_unlocked(DAMP) and GameState.get_unlock_round(DAMP) == 1 and b.get_seed(DAMP).unlock_round == 3,
			"with replay off Black Damp is on sale from shift 1 like every strain (the data's shift 3 applies with replay on)")
	var counter := room.get_station("ShopCounter") as ShopCounter
	_put(bob, counter.global_position + counter.global_basis.z * 1.2)
	var money0 := GameState.money
	var r := counter.server_buy_seed(BOB, DAMP)
	await wait_frames(1)
	var packet := items.get_held_by(BOB)
	check(bool(r.get("ok", false)) and GameState.money == money0 - 80 and packet != null and GrowPlot.get_packet_strain(packet) == DAMP,
			"Bob buys a packet for $80 (%s)" % [r])
	if packet != null:
		items.server_despawn_item(packet)
	_park()


func _test_tell() -> void:
	step("the tell: motes over a ripe Black Damp tray")
	var p1 := _plot(1)
	var p2 := _plot(2)
	_ripe(p1, DAMP)
	_ripe(p2, &"budget")
	await wait_frames(1)
	var tell := p1.get_spore_tell()
	check(p1.is_spore_ripe() and tell != null and tell.visible and tell.emitting and tell.name == GrowPlot.SPORE_TELL_NODE,
			"GrowPlot1 (ripe Black Damp) lets motes drift")
	check(not p2.is_spore_ripe() and (p2.get_spore_tell() == null or not p2.get_spore_tell().visible), "GrowPlot2 (ripe Budget Bud) does not")
	p1.stage = GrowPlot.Stage.FLOWERING
	await wait_frames(1)
	check(not tell.visible and not tell.emitting, "no motes before it is ripe")
	p1.server_reset()
	p2.server_reset()


# --- each cause --------------------------------------------------------------------------------------------------------

func _test_causes(b: BalanceConfig) -> void:
	step("cause: the harvest")
	Story.reset_state()
	var p1 := _plot(1)
	_ripe(p1, DAMP)
	_put(bob, p1.global_position + Vector3(-1.2, 0.0, 0.0))
	_put(cara, p1.global_position + Vector3(-3.0, 0.0, 0.0))
	_puffs.clear()
	p1._server_interact(bob)
	await wait_frames(2)
	var product := items.get_held_by(BOB)
	check(product != null and product.item_type == Const.ITEM_PRODUCT and p1.is_empty(), "Bob harvested it (the product in his hands, the tray empty)")
	check(_puffs == [["GrowPlot1", Spores.CAUSE_HARVEST]], "one puff over GrowPlot1, cause harvest %s" % [_puffs])
	var ids := spores.get_cloud_ids()
	var cloud := spores.get_cloud(ids[0]) if ids.size() == 1 else {}
	check(ids.size() == 1 and String(cloud.get("plot", "")) == "GrowPlot1" and (cloud["pos"] as Vector3).is_equal_approx(p1.global_position)
			and is_equal_approx(float(cloud["left"]), b.spore_cloud_sec), "the cloud hangs over the tray for %.0f s" % b.spore_cloud_sec)
	var node := cloud.get("node") as Node3D if not cloud.is_empty() else null
	var motes := node.get_node_or_null(^"Motes") as CPUParticles3D if node != null else null
	check(motes != null and motes.emitting and is_equal_approx(motes.emission_sphere_radius, b.spore_radius * Spores.CLOUD_FILL),
			"a volume of motes, %.1f m across" % (b.spore_radius * Spores.CLOUD_FILL * 2.0))
	check(is_equal_approx(spores.get_fog(BOB), 9.0) and not spores.is_fogged(CARA) and not spores.is_fogged(1),
			"Bob (1.2 m) is fogged for 9 s; Cara (3 m) and the host (far off) are not")
	check(GameState.get_stat(BOB, Spores.STAT_FOGGED) == 1 and GameState.get_stat(CARA, Spores.STAT_FOGGED) == 0, "Bob's FOGGED stat: 1")
	check(_fog_events.has([BOB, 9.0]), "fog_changed(Bob, 9)")
	var first := FIRST_LINE % "Bob"
	check(Story.last_bark == first or Story.get_pending_text() == first, "the Boss: '%s'" % first)
	if product != null:
		items.server_despawn_item(product)
	_clear()

	step("no puff: not Black Damp, not ripe")
	var p2 := _plot(2)
	_ripe(p2, &"budget")
	_put(cara, p2.global_position + Vector3(-1.2, 0.0, 0.0))
	p2._server_interact(cara)
	await wait_frames(2)
	var budget := items.get_held_by(CARA)
	check(budget != null and p2.is_empty() and _puffs.is_empty() and not spores.is_fogged(CARA), "a ripe Budget Bud harvest puffs nothing")
	if budget != null:
		items.server_despawn_item(budget)
	var p3 := _plot(3)
	p3.server_reset()
	p3.server_plant(DAMP)
	p3.stage = GrowPlot.Stage.FLOWERING
	check(not spores.server_puff(p3, Spores.CAUSE_HARVEST) and not Spores.puff_plot(p3, Spores.CAUSE_HIT) and not Spores.puff_plot(null, Spores.CAUSE_HIT)
			and spores.get_cloud_count() == 0, "a flowering Black Damp tray does not puff")
	_park()

	step("cause: the plant walks off")
	p3.stage = GrowPlot.Stage.READY
	_put(bob, p3.global_position + Vector3(-1.5, 0.0, 0.0))
	p3.turning = true
	p3.turn_left = 0.05
	var uprooted := p3.server_tick_mutation(0.1)
	await wait_frames(1)
	check(uprooted and p3.is_empty() and Hostiles.count() == 1, "GrowPlot3 uprooted and a hostile plant is on the floor")
	check(_puffs == [["GrowPlot3", Spores.CAUSE_UPROOT]] and is_equal_approx(spores.get_fog(BOB), 9.0), "it puffed on the way out (cause uproot): Bob fogged")
	Hostiles.server_despawn_all()
	await wait_frames(2)
	_clear()

	step("cause: fire")
	var p4 := _plot(4)
	_ripe(p4, DAMP)
	_put(cara, p4.global_position + Vector3(-1.5, 0.0, 0.0))
	check(p4.server_scorch(0), "the flamethrower takes GrowPlot4")
	check(_puffs == [["GrowPlot4", Spores.CAUSE_FIRE]] and is_equal_approx(spores.get_fog(CARA), 9.0), "it puffed as it burnt (cause fire): Cara fogged")
	await wait_frames(2)
	check(p4.is_empty(), "the tray is empty after the burn")
	_clear()

	step("cause: a drive-by round")
	var p5 := _plot(5)
	_ripe(p5, DAMP)
	await wait_physics(2)  # the ripe plant's collider is switched on deferred
	var c := p5.global_position
	var miss := Events.server_fire_lane({"from": c + Vector3(-1.7, 1.25, -2.3), "to": c + Vector3(-1.7, 1.25, -0.6)})
	check(not (miss["workers"] as Array).size() and _puffs.is_empty(), "a round 1.7 m off the tray does nothing")
	var shot := Events.server_fire_lane({"from": c + Vector3(0.0, 1.25, -1.3), "to": c + Vector3(0.0, 1.25, 1.3)})
	check(bool(shot["blocked"]) and _puffs == [["GrowPlot5", Spores.CAUSE_SHOT]], "a round into the ripe plant puffs it (cause shot; the plant stops the round)")
	check(p5.is_ready_to_harvest(), "the ripe tray itself is not harmed")
	Events.server_fire_lane({"from": c + Vector3(0.0, 1.25, -1.3), "to": c + Vector3(0.0, 1.25, 1.3)})
	check(_puffs.size() == 1 and spores.get_cloud_count() == 1, "a second round while its cloud hangs: no second puff")
	_clear()

	step("cause: a thrown item")
	var p6 := _plot(6)
	_ripe(p6, DAMP)
	await wait_physics(2)
	var pkt := items.server_spawn_item(Const.ITEM_SEED_PACKET, {"strain_id": "budget"}, PARK_ME + Vector3(1.0, 0.0, 0.0))
	await wait_frames(1)
	var thrown := items.server_throw_item(pkt, p6.global_position + Vector3(0.0, 1.3, -1.6), Vector3(0.0, 1.0, 7.0), BOB)
	await wait_until(func() -> bool: return not pkt.is_flying(), 2.0, "the packet lands")
	check(thrown and _puffs == [["GrowPlot6", Spores.CAUSE_HIT]], "a packet thrown into the ripe plant puffs it (cause hit) %s" % [_puffs])
	_clear()
	p3.server_reset()
	p3.server_plant(DAMP)
	await wait_frames(1)
	await wait_physics(2)
	var thrown2 := items.server_throw_item(pkt, p3.global_position + Vector3(0.0, 1.0, -1.6), Vector3(0.0, 1.0, 7.0), BOB)
	await wait_until(func() -> bool: return not pkt.is_flying(), 2.0, "the packet lands again")
	check(thrown2 and _puffs.is_empty(), "the same throw at a Black Damp seedling puffs nothing")
	items.server_despawn_item(pkt)
	for i in range(1, 7):
		_plot(i).server_reset()
	_park()
	await wait_frames(2)
	_clear()


# --- who breathes ------------------------------------------------------------------------------------------------------

func _test_breathing(b: BalanceConfig) -> void:
	step("who breathes: distance, the floor, walls, crouching")
	var p1 := _plot(1)
	var pos := p1.global_position
	_put(bob, pos + Vector3(-2.55, 0.0, 0.0))
	check(Spores.in_cloud(bob, pos, b.spore_radius), "2.55 m away: in it")
	_put(bob, pos + Vector3(-2.65, 0.0, 0.0))
	check(not Spores.in_cloud(bob, pos, b.spore_radius), "2.65 m away: out of it")
	_put(bob, pos + Vector3(-1.0, 0.0, 0.0))
	check(not Spores.in_cloud(bob, pos + Vector3(0.0, 2.5, 0.0), b.spore_radius), "a cloud 2.5 m higher up is another floor")
	_put(bob, Vector3(9.0, 0.0, -4.0))
	check(not Spores.in_cloud(bob, Vector3(11.2, 0.0, -4.0), b.spore_radius), "a wall between (main room / grow hall, 2.2 m apart): nothing")
	_put(bob, Vector3(9.0, 0.0, -1.25))
	check(Spores.in_cloud(bob, Vector3(11.2, 0.0, -1.25), b.spore_radius), "through the open doorway: in it")
	check(not Spores.in_cloud(null, pos, b.spore_radius), "nobody: no")

	_ripe(p1, DAMP)
	_put(bob, pos + Vector3(-2.4, 0.0, 0.0))
	_put(cara, pos + Vector3(0.0, 0.0, -1.8))
	cara.crouching = true
	_put_me(pos + Vector3(-2.9, 0.0, 0.3))
	await wait_physics(2)
	var me_d := Vector2(me.global_position.x - pos.x, me.global_position.z - pos.z).length()
	var bob0 := GameState.get_stat(BOB, Spores.STAT_FOGGED)
	var cara0 := GameState.get_stat(CARA, Spores.STAT_FOGGED)
	var me0 := GameState.get_stat(1, Spores.STAT_FOGGED)
	check(spores.server_puff(p1, Spores.CAUSE_HIT), "GrowPlot1 puffs")
	check(not spores.server_puff(p1, Spores.CAUSE_HARVEST), "and not again while its cloud hangs")
	check(is_equal_approx(spores.get_fog(BOB), 9.0), "Bob, standing at 2.4 m: 9 s")
	check(is_equal_approx(spores.get_fog(CARA), 4.5), "Cara, crouched at 1.8 m, breathes through her sleeve: 4.5 s")
	check(not spores.is_fogged(1) and me_d > b.spore_radius, "the host at %.2f m: clear" % me_d)
	cara.crouching = false

	step("walking in, standing in it, the cloud's end, the fog's end")
	spores.tick(2.0)
	check(is_equal_approx(spores.get_fog(BOB), 9.0) and GameState.get_stat(BOB, Spores.STAT_FOGGED) == bob0 + 1,
			"two seconds in the cloud: Bob topped up to 9 s, counted once")
	check(is_equal_approx(spores.get_fog(CARA), 9.0) and GameState.get_stat(CARA, Spores.STAT_FOGGED) == cara0 + 1,
			"Cara stood up in it: 9 s now, still counted once")
	_put_me(pos + Vector3(-1.0, 0.0, 0.0))
	await wait_physics(2)
	spores.tick(0.1)
	check(is_equal_approx(spores.get_fog(1), 9.0) and GameState.get_stat(1, Spores.STAT_FOGGED) == me0 + 1, "the host walks in while it hangs: fogged 9 s")
	spores.tick(0.5)
	check(spores.get_fog(1) > 8.0 and spores.get_fog(1) < 9.0, "a top-up under a second is not sent: %.1f s left" % spores.get_fog(1))
	var id := spores.get_cloud_ids()[0]
	var node := spores.get_cloud(id).get("node") as Node3D
	spores.tick(3.3)
	check(spores.get_cloud_count() == 1 and spores.get_fog(BOB) > 8.0, "5.9 s after the puff the cloud still hangs (Bob topped up again)")
	spores.tick(0.2)
	var motes := node.get_node_or_null(^"Motes") as CPUParticles3D if is_instance_valid(node) else null
	check(spores.get_cloud_count() == 0 and spores.get_cloud(id).is_empty() and motes != null and not motes.emitting, "then it is gone: no more motes")
	var left := spores.get_fog(BOB)
	check(left > 8.0 and left <= 9.0, "Bob leaves it with %.1f s of fog" % left)
	spores.tick(left - 0.2)
	check(spores.is_fogged(BOB) and spores.get_fogged_peers() == [1, BOB, CARA], "0.2 s before the end everybody is still fogged %s" % [spores.get_fogged_peers()])
	_fog_events.clear()
	spores.tick(1.2)
	check(spores.get_fogged_peers().is_empty() and _fog_events.has([BOB, 0.0]) and _fog_events.has([CARA, 0.0]) and _fog_events.has([1, 0.0]),
			"then the air is clear for all three (fog_changed ... 0)")
	await wait_sec(Spores.CLOUD_MOTE_SEC + 0.4)
	check(not is_instance_valid(node), "the cloud's node is freed once its last motes drifted off")
	p1.server_reset()
	_park()


# --- the local worker's screen and ears --------------------------------------------------------------------------------

func _test_screen() -> void:
	step("the screen: overlay and muffled hearing")
	var foreign_a := AudioEffectAmplify.new()
	AudioServer.add_bus_effect(Spores.MASTER_BUS, foreign_a)
	var rect := spores.get_overlay_rect()
	var mat := rect.material as ShaderMaterial
	check(spores.server_catch(1, false) and is_equal_approx(spores.get_fog(1), 9.0), "the host is fogged")
	spores._process(0.35)
	var half := spores.get_filter()
	check(rect.visible and absf(spores.get_overlay_alpha() - 0.5) < 0.01 and half != null and half.cutoff_hz < 6000.0 and half.cutoff_hz > 2000.0,
			"halfway in: the overlay at %.2f, the low-pass at %.0f Hz" % [spores.get_overlay_alpha(), half.cutoff_hz if half != null else -1.0])
	spores._process(0.4)
	var f := spores.get_filter()
	check(is_equal_approx(spores.get_overlay_alpha(), 1.0) and is_equal_approx(float(mat.get_shader_parameter(&"amount")), 1.0), "faded in within 0.7 s")
	check(f != null and spores.is_filter_installed() and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 + 2
			and AudioServer.get_bus_effect(Spores.MASTER_BUS, _master0 + 1) == f and absf(f.cutoff_hz - Spores.FILTER_CUTOFF_HZ) < 1.0,
			"a low-pass at %.0f Hz on the Master bus, after what was there" % (f.cutoff_hz if f != null else -1.0))
	check(rect.mouse_filter == Control.MOUSE_FILTER_IGNORE and not Game.is_ui_locked(), "it takes no input and no UI lock")
	var foreign_b := AudioEffectAmplify.new()
	AudioServer.add_bus_effect(Spores.MASTER_BUS, foreign_b)
	spores.tick(7.6)
	spores._process(0.1)
	check(spores.is_fogged(1) and spores.get_overlay_alpha() < 1.0 and spores.get_overlay_alpha() > 0.8, "the last %.1f s: fading out (%.2f)" % [spores.get_fog(1), spores.get_overlay_alpha()])
	spores.tick(1.5)
	check(not spores.is_fogged(1) and spores.is_filter_installed(), "the fog is over; the fade still runs")
	for i in 20:
		spores._process(0.1)
	check(is_equal_approx(spores.get_overlay_alpha(), 0.0) and not rect.visible and spores.get_filter() == null, "faded out: overlay hidden, filter gone")
	check(AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 + 2 and AudioServer.get_bus_effect(Spores.MASTER_BUS, _master0) == foreign_a
			and AudioServer.get_bus_effect(Spores.MASTER_BUS, _master0 + 1) == foreign_b, "exactly that effect left the bus: the others stay, in order")
	AudioServer.remove_bus_effect(Spores.MASTER_BUS, _master0 + 1)
	AudioServer.remove_bus_effect(Spores.MASTER_BUS, _master0)
	check(AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0, "the Master bus as it was")


# --- coughs and the haze -----------------------------------------------------------------------------------------------

func _test_coughs() -> void:
	step("coughs: at the worker, his own pitch, every few seconds")
	var cough := Sfx.get_stream(&"cough")
	var pitches := {}
	for pid in [1, BOB, CARA]:
		pitches[Spores.cough_pitch(pid)] = true
	check(pitches.size() == 3, "the host, Bob and Cara cough at three pitches %s" % [pitches.keys()])
	_coughs.clear()
	_put(bob, Vector3(-4.0, 0.0, -3.0))
	spores.server_catch(BOB, false)
	await wait_until(func() -> bool: return spores.get_cough_count(BOB) >= 1, 2.0, "Bob coughs within a second")
	var v := Sfx.get_last_voice() as AudioStreamPlayer3D
	var head := bob.global_position + Vector3.UP * Spores.COUGH_HEAD_HEIGHT
	check(v != null and v.stream == cough and v.global_position.distance_to(head) < 0.01, "a 3D voice at Bob's head plays `cough`")
	if v != null:
		var want := Spores.cough_pitch(BOB)
		check(v.pitch_scale >= want * 0.91 and v.pitch_scale <= want * 1.09, "at Bob's pitch (%.2f, his %.2f)" % [v.pitch_scale, want])
	check(int(_coughs.get(BOB, 0)) == spores.get_cough_count(BOB), "coughed(Bob) on this peer")
	var haze := spores.get_haze(BOB)
	check(haze != null and haze.name == Spores.HAZE_NODE and haze.get_parent() == bob.visual and (haze as CPUParticles3D).emitting,
			"a grey haze round Bob's head")
	var n0 := spores.get_cough_count(BOB)
	await wait_sec(4.2)
	var n1 := spores.get_cough_count(BOB)
	check(n1 - n0 >= 1 and n1 - n0 <= 2, "every %.1f to %.1f s: %d more in 4.2 s" % [Spores.COUGH_GAP_MIN_SEC, Spores.COUGH_GAP_MAX_SEC, n1 - n0])
	spores.server_catch(1, false)
	var mine0 := spores.get_cough_count(1)
	await wait_until(func() -> bool: return spores.get_cough_count(1) > mine0, 2.0, "the host coughs too")
	var v2 := Sfx.get_last_voice()
	check(v2 is AudioStreamPlayer and (v2 as AudioStreamPlayer).stream == cough, "his own cough is unpositioned (a 2D voice)")
	check(spores.get_haze(1) == null, "no haze on his own body")
	spores.server_catch(CARA, true)
	await wait_until(func() -> bool: return spores.get_cough_count(CARA) >= 1 and spores.get_haze(CARA) != null, 2.0, "Cara coughs, a haze round her head")
	spores.server_clear()
	await wait_frames(2)
	check(spores.get_haze(BOB) == null and spores.get_haze(CARA) == null and spores.get_fogged_peers().is_empty(), "clear air: the hazes are gone")
	var after := spores.get_cough_count(BOB)
	await wait_sec(1.0)
	check(spores.get_cough_count(BOB) == after, "and nobody coughs")
	_park()


# --- the report, the end of the shift ----------------------------------------------------------------------------------

func _test_report_and_round_end() -> void:
	step("the report: the Boss once a shift, FOGGED, the verdict")
	var first := FIRST_LINE % "Bob"
	check(Story.bark_log.count(first) <= 1 and Story.get_pending_text() != first, "the Boss said it once this shift, whatever came after")
	for pid in [BOB, CARA, 1]:
		print("      fogged %d: %d" % [pid, GameState.get_stat(pid, Spores.STAT_FOGGED)])
	check(GameState.get_stat(BOB, Spores.STAT_FOGGED) > GameState.get_stat(CARA, Spores.STAT_FOGGED) and GameState.get_stat(BOB, Spores.STAT_FOGGED) > GameState.get_stat(1, Spores.STAT_FOGGED),
			"Bob was fogged the most (%d)" % GameState.get_stat(BOB, Spores.STAT_FOGGED))
	check(Story.get_report_verdicts().has(VERDICT % "Bob"), "the verdict: '%s'" % (VERDICT % "Bob"))

	step("the end of the shift clears the air")
	var p1 := _plot(1)
	_ripe(p1, DAMP)
	_put(bob, p1.global_position + Vector3(-1.2, 0.0, 0.0))
	spores.server_puff(p1, Spores.CAUSE_HIT)
	spores.server_catch(1, false)
	await wait_frames(3)
	check(spores.get_cloud_count() == 1 and spores.is_fogged(BOB) and spores.is_fogged(1) and spores.is_filter_installed() and spores.get_haze(BOB) != null,
			"a cloud, Bob and the host fogged, the filter on, Bob's haze")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "the buzzer: shift over (payment missed)")
	await wait_frames(2)
	check(spores.get_cloud_count() == 0 and spores.get_fogged_peers().is_empty() and spores.get_filter() == null
			and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 and not spores.get_overlay_rect().visible and spores.get_haze(BOB) == null,
			"no cloud, no fog, no filter, no overlay, no haze")
	var report: Node = hud.get(&"round_end").get(&"report")
	report.call(&"refresh")
	var row := (report.call(&"get_row_peers") as Array).find(BOB) + 1
	check(bool(report.call(&"has_fogged_column")) and report.call(&"get_cell_text", 0, 7) == "FOGGED" and report.call(&"get_cell_text", 0, 6) == "THROWS/HITS",
			"the shift report has a FOGGED column after THROWS/HITS")
	check(row > 0 and report.call(&"get_cell_text", row, 7) == str(GameState.get_stat(BOB, Spores.STAT_FOGGED)) and report.call(&"get_cell_text", row, 0) == "Bob",
			"Bob's row: fogged %s" % report.call(&"get_cell_text", row, 7))
	check((report.call(&"get_verdict_texts") as PackedStringArray).has(VERDICT % "Bob"), "the report shows the verdict")


func _test_reset() -> void:
	step("START OVER clears the air; a clean shift has no FOGGED column")
	var p2 := _plot(2)
	_ripe(p2, DAMP)
	_put(cara, p2.global_position + Vector3(-1.2, 0.0, 0.0))
	spores.server_puff(p2, Spores.CAUSE_HIT)
	spores.server_catch(1, false)
	await wait_frames(3)
	check(spores.get_cloud_count() == 1 and spores.is_fogged(CARA) and spores.is_filter_installed(), "a cloud on the end screen, Cara and the host fogged")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "START OVER: waiting again")
	await wait_frames(2)
	check(spores.get_cloud_count() == 0 and spores.get_fogged_peers().is_empty() and spores.get_filter() == null
			and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 and not spores.get_overlay_rect().visible, "the reset cleared everything")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "a new shift")
	var report: Node = hud.get(&"round_end").get(&"report")
	report.call(&"refresh")
	check(not bool(report.call(&"has_fogged_column")) and report.call(&"get_cell_text", 0, 6) == "THROWS/HITS" and report.call(&"get_cell_text", 0, 7) != "FOGGED",
			"nobody fogged this shift: the seven columns it always had")
	Story.reset_state()
	_put(bob, Vector3(-4.0, 0.0, -3.0))
	spores.server_catch(BOB, false)
	var first := FIRST_LINE % "Bob"
	check(Story.last_bark == first or Story.get_pending_text() == first, "the first fog of the new shift: the Boss says it again")


func _test_menu() -> void:
	step("the menu clears the air")
	spores.server_catch(1, false)
	await wait_frames(3)
	check(spores.is_filter_installed() and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 + 1, "the host fogged, the filter on")
	Game.return_to_menu()
	await wait_frames(4)
	check(Game.world == null and Spores.get_instance() == null, "back in the menu: no world, no Spores")
	check(AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0, "the Master bus as it was before the session")


# --- helpers -----------------------------------------------------------------------------------------------------------

func _plot(i: int) -> GrowPlot:
	return room.get_station("GrowPlot%d" % i) as GrowPlot


## A ripe tray of `strain` (host).
func _ripe(p: GrowPlot, strain: StringName) -> void:
	p.server_reset()
	p.server_plant(strain)
	p.water = 1.0
	p.stage = GrowPlot.Stage.READY


## Fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)


func _park() -> void:
	_put(bob, PARK_BOB)
	_put(cara, PARK_CARA)
	_put_me(PARK_ME)
	if cara != null:
		cara.crouching = false


## Clean air on every peer, and a fresh record of puffs.
func _clear() -> void:
	spores.server_clear()
	_puffs.clear()
	_park()


## On: the host's step and the local effects run only when the test calls them (tick / _process).
func _manual(on: bool) -> void:
	spores.set_physics_process(not on)
	spores.set_process(not on)


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
