extends "res://tools/tests/qa_base.gd"
## M23 fragile suite (fragile agent): bundles bruise. A single headless host with one fake worker (Bob: a host-side body
## without an owning peer), the full game with replay on (the market) at run B5VP.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/fragile_body.gd --port=7903
##       --replay --run=B5VP --career-file=user://fragile_test_7903.cfg --round-sec=900
## Pins:
##   the rule      bruise speed = a fall from 1.5 m; ADDITIVE value: 1 - bruise_share per bruise up to bruise_max
##                 (0.8, 0.6, then no lower); compute_sale_value's new argument; the bruise sound has a recipe
##   the hits      a throw onto the floor, into a wall, into a station, into a worker (staggered) each bruise once;
##                 a fall from 2 m bruises, from 1.2 m and a soft lob do not; the cap (three hard landings: two)
##   no bruise     Q (a drop at the feet), the rack (hang and take off), a worker knocked down dropping what he holds,
##                 a chute shot (clean: paid in full; bruised: paid bruised), a chute shot refused between shifts
##   shown         the synced prop and spawn props, names ("Purple Haze x1, bruised", "badly bruised"), the floating tag,
##                 darker buds, the dent (squashed, leaning), the grubby overlay on the bag, the bruise thud at the strike
##   the value     with today's market and cured: the chute's prompt and get_sale_value, the deposit (money, sale,
##                 STAT_DEPOSITED, deposit_noted for the job, the cured job's progress), the collector's pick and the
##                 cost ledger at the bruised value
##   the truck     loading keeps the bruises (cargo entry, encoding, the bag's colour), the chute's total, the raid ledger's
##                 value, unloading restores them, depositing the load pays the bruised value
##   the toast     "Bruised. It pays less." for the thrower the first time in a shift only; never for a worker without a
##                 connection; again in the next shift
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const LANE := Vector3(-3.0, 0.0, 3.0)
const FAR_BOB := Vector3(6.0, 0.0, -5.5)
const PARK_ME := Vector3(-8.0, 0.0, -5.0)

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var chute: TurnInStation
var rack1: DryingRack
var _bruised: Array = []      # [item name, bruises, thrower] from ItemManager.bundle_bruised
var _knocks: Array = []       # [item name, bruises, the last voice played the bruise stream, that voice's position]
var _sales: Array = []        # [amount, seller]
var _notes: Array = []        # [strain, amount, cured, value, seller]
var _watched: Dictionary = {} # item instance id -> bruises seen


func _run() -> void:
	_label = "fragile"
	await get_tree().process_frame
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	b.contract_reward = 0 # the money below is counted to the dollar

	step("hosting")
	Game.start_host("Tester", port_arg(7903))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	await wait_frames(3)
	if not check(bob != null and world.get_players().size() == 2, "host + Bob spawned"):
		finish(); return
	chute = room.get_station("TurnInStation") as TurnInStation
	rack1 = room.get_station("DryingRack1") as DryingRack
	check(chute != null and rack1 != null, "the chute and DryingRack1")
	items.bundle_bruised.connect(func(it: Item, n: int, thrower: int) -> void: _bruised.append([String(it.name), n, thrower]))
	GameState.sale_made.connect(func(amount: int, seller: int) -> void: _sales.append([amount, seller]))
	GameState.deposit_noted.connect(func(strain: StringName, amount: int, cured: bool, value: int, seller: int) -> void:
		_notes.append([strain, amount, cured, value, seller]))
	check(Config.replay_enabled, "replay is on (the market)")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	GameState.server_add_money(1000)
	_put(bob, FAR_BOB)
	_put_me(PARK_ME, 0.0)
	await wait_physics(3)

	_test_rules(b)
	await _test_floor()
	await _test_wall()
	await _test_station()
	await _test_worker()
	await _test_fall()
	await _test_no_bruise(b)
	await _test_cap(b)
	await _test_value(b)
	await _test_truck(b)
	await _test_toast(b)
	finish()


# --- the rule -----------------------------------------------------------------------------------------------------------

func _test_rules(b: BalanceConfig) -> void:
	step("the rule: how hard, how much")
	check(is_equal_approx(b.bruise_share, 0.2) and b.bruise_max == 2, "BalanceConfig: bruise_share 0.2, bruise_max 2")
	var speed := Product.get_bruise_speed()
	check(absf(speed - sqrt(2.0 * 9.8 * 1.5)) < 0.001 and speed > 5.4 and speed < 5.45, "a strike bruises from %.2f m/s (a fall from 1.5 m)" % speed)
	check(Product.is_bruising_impact(Vector3(0.0, -5.5, 0.0)) and not Product.is_bruising_impact(Vector3(3.0, -4.0, 0.0))
			and not Product.is_bruising_impact(Vector3(NAN, 0.0, 0.0)), "5.5 m/s bruises, 5.0 m/s does not, NaN never")
	check(is_equal_approx(TurnInStation.bruise_factor(0), 1.0) and is_equal_approx(TurnInStation.bruise_factor(1), 0.8)
			and is_equal_approx(TurnInStation.bruise_factor(2), 0.6) and is_equal_approx(TurnInStation.bruise_factor(5), 0.6)
			and is_equal_approx(TurnInStation.bruise_factor(-1), 1.0), "additive: x1.0, x0.8, x0.6, and no lower past bruise_max")
	var purple := b.get_seed(&"purple")
	check(TurnInStation.compute_sale_value(purple, 1, 1.0) == 140 and TurnInStation.compute_sale_value(purple, 1, 1.0, false, 1) == 112
			and TurnInStation.compute_sale_value(purple, 1, 1.0, false, 2) == 84 and TurnInStation.compute_sale_value(purple, 2, 1.0, true, 1) == 314,
			"Purple Haze: $140 clean, $112 bruised, $84 twice; a cured pair bruised once $314")
	check(Product.bruise_tag(0) == "" and Product.bruise_tag(1) == ", bruised" and Product.bruise_tag(2) == ", badly bruised", "the tags")
	var m := Sfx.measure(Sfx.get_stream(&"bruise"))
	check(Sfx.has_sound(&"bruise") and float(m.seconds) > 0.3 and float(m.seconds) < 0.5 and absf(float(m.dc)) < 0.01,
			"the bruise thud has a recipe of its own (%.2f s, not the 0.1 s blip)" % float(m.seconds))


# --- the hits -------------------------------------------------------------------------------------------------------------

func _test_floor() -> void:
	step("the floor: a throw straight down bruises once, with the thud, on the synced prop")
	var p := _bundle(&"purple", 1, LANE)
	await wait_frames(2)
	var tint0 := _bud_color(p)
	var scale0 := (p.get_node(^"Visual/Cluster") as Node3D).scale
	check(p.bruises == 0 and p.get_props() == {"strain_id": "purple", "amount": 1} and p.get_display_name() == "Purple Haze x1",
			"a fresh bundle: no bruises, the two props it always had, '%s'" % p.get_display_name())
	check(not p.is_bruised() and p.can_bruise() and is_equal_approx(p.get_bruise_factor(), 1.0), "clean: full value")
	_bruised.clear()
	await _throw(p, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.5))
	check(p.bruises == 1 and p.is_bruised() and not p.is_flying() and absf(p.global_position.y) < 0.05, "it lands on the floor with one bruise")
	check(_bruised == [[String(p.name), 1, 1]], "bundle_bruised(it, 1, thrower 1) %s" % [_bruised])
	check(p.get_props() == {"strain_id": "purple", "amount": 1, "bruises": 1}, "props carry it %s" % [p.get_props()])
	check(p.get_display_name() == "Purple Haze x1, bruised" and p.get_prompt(me) == "Pick up Purple Haze x1, bruised", "named: '%s'" % p.get_prompt(me))
	check((p.get_node(^"AmountLabel") as Label3D).text == "x1, bruised", "the floating tag: '%s'" % (p.get_node(^"AmountLabel") as Label3D).text)
	check(_knocks.size() >= 1 and _knocks[-1][0] == String(p.name) and _knocks[-1][1] == 1 and bool(_knocks[-1][2]),
			"the bruise thud played (a 3D voice) the moment it took the bruise %s" % [_knocks.back() if not _knocks.is_empty() else []])
	if not _knocks.is_empty():
		var at: Vector3 = _knocks[-1][3]
		check(at.is_finite() and Vector2(at.x - p.global_position.x, at.z - p.global_position.z).length() < 0.6 and at.y < 0.6,
				"where it struck (%s, landed %s)" % [at, p.global_position])
	var tint1 := _bud_color(p)
	var cluster := p.get_node(^"Visual/Cluster") as Node3D
	check(tint1.get_luminance() < tint0.get_luminance() - 0.02, "the buds are darker (%.3f -> %.3f)" % [tint0.get_luminance(), tint1.get_luminance()])
	check(cluster.scale.y < scale0.y - 0.05 and cluster.scale.x > scale0.x and cluster.rotation.z > 0.05, "dented: squashed and leaning (%s, lean %.2f)" % [cluster.scale, cluster.rotation.z])
	var bags := p._get_bag_meshes()
	var grimy := not bags.is_empty()
	for mesh in bags:
		if mesh.material_overlay != Product._get_grime():
			grimy = false
	var grime := Product._get_grime()
	check(grimy and grime.blend_mode == BaseMaterial3D.BLEND_MODE_MUL and grime.albedo_color.get_luminance() < 0.8,
			"the bag (%d mesh(es)) is drawn through the grubby overlay" % bags.size())
	check(not _buds_grimed(p), "the buds and the ink outline keep their own look (no overlay)")
	items.server_despawn_item(p)
	await wait_frames(1)


func _test_wall() -> void:
	step("a wall")
	var p := _bundle(&"budget", 2, LANE)
	await wait_frames(1)
	await _throw(p, Vector3(-8.0, 1.2, 2.0), Vector3(-9.0, 1.5, 0.0))
	check(p.bruises == 1 and p.global_position.x < -9.0, "into the west wall: one bruise, down by the wall (%s)" % p.global_position)
	items.server_despawn_item(p)
	await wait_frames(1)


func _test_station() -> void:
	step("a station")
	var counter := room.get_station("ShopCounter") as Node3D
	var origin := Vector3(0.0, 0.7, -2.4)
	var dir := Vector3(0.0, 0.0, -1.0)
	var space := world.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(origin, origin + dir * 4.0, Const.LAYER_WORLD | Const.LAYER_INTERACTABLE))
	var collider := hit.get("collider") as Node
	var on_station := collider != null and counter != null and counter.is_ancestor_of(collider)
	check(on_station, "the line from %s runs into the shop counter (%s)" % [origin, collider.get_path() if collider != null else "nothing"])
	var p := _bundle(&"purple", 1, LANE)
	await wait_frames(1)
	await _throw(p, origin, dir * 8.0 + Vector3.UP * 0.4)
	check(p.bruises == 1 and p.global_position.z > -4.6, "into the counter: one bruise, it lands in front of it (%s)" % p.global_position)
	items.server_despawn_item(p)
	await wait_frames(1)


func _test_worker() -> void:
	step("a worker")
	_put(bob, Vector3(-3.0, 0.0, 0.0))
	await wait_physics(3)
	var p := _bundle(&"purple", 1, LANE + Vector3(1.0, 0.0, 1.0))
	await wait_frames(1)
	var hits0 := GameState.get_stat(1, Const.STAT_HITS)
	await _throw(p, Vector3(-3.0, 1.0, 3.0), Vector3(0.0, 1.8, -8.0))
	check(GameState.get_stat(1, Const.STAT_HITS) == hits0 + 1 and bob.is_stunned(), "it hits Bob: he goes down")
	check(p.bruises == 1 and p.global_position.distance_to(bob.global_position) < 1.5, "and the bundle takes a bruise at his feet")
	items.server_despawn_item(p)
	await wait_until(func() -> bool: return not bob.is_stunned() and bob.can_be_staggered(), 3.0, "Bob gets back up")
	_put(bob, FAR_BOB)
	await wait_physics(2)


func _test_fall() -> void:
	step("a fall: from 2 m it bruises, from 1.2 m and a soft lob it does not")
	var p := _bundle(&"budget", 1, LANE)
	await wait_frames(1)
	await _throw(p, Vector3(-5.0, 2.0, 3.0), Vector3(0.3, 0.0, 0.0))
	check(p.bruises == 1, "off 2 m: bruised (%.2f m/s at the floor)" % sqrt(0.09 + 2.0 * 9.8 * 2.0))
	items.server_despawn_item(p)
	p = _bundle(&"budget", 1, LANE)
	await wait_frames(1)
	await _throw(p, Vector3(-5.0, 1.2, 3.0), Vector3(0.3, 0.0, 0.0))
	check(p.bruises == 0 and absf(p.global_position.y) < 0.05, "off 1.2 m: lands clean")
	await _throw(p, Vector3(-5.0, 0.6, 3.0), Vector3(1.0, 0.5, 0.0))
	check(p.bruises == 0, "a soft lob: clean")
	items.server_despawn_item(p)
	await wait_frames(1)


# --- no bruise ------------------------------------------------------------------------------------------------------------

func _test_no_bruise(b: BalanceConfig) -> void:
	step("no bruise: Q at the feet")
	_put_me(LANE, 0.0)
	await wait_physics(2)
	_bruised.clear()
	var p := _bundle(&"purple", 1, LANE, {}, 1)
	await wait_frames(2)
	check(p.holder_id == 1, "I hold a bundle")
	items.request_drop()
	await wait_frames(3)
	check(p.holder_id == 0 and not p.is_flying() and p.bruises == 0, "dropped (Q): clean")

	step("no bruise: the rack")
	check(items.server_give_item(p, 1), "picked up again")
	var front := rack1.global_position + rack1.global_basis.z.normalized() * 1.0
	_put_me(front, 0.0)
	me.look_at(Vector3(rack1.global_position.x, me.global_position.y, rack1.global_position.z), Vector3.UP)
	await wait_physics(3)
	check(rack1.server_hang(me), "hung on DryingRack1")
	await wait_frames(2)
	check(p.rack and p.holder_id == 0 and p.bruises == 0, "on the hook: clean")
	check(items.server_give_item(p, 1), "taken off the hook")
	await wait_frames(3)
	check(not p.rack and p.holder_id == 1 and p.bruises == 0, "in my hands again: clean")
	items.server_despawn_item(p)

	step("no bruise: a worker knocked down drops what he holds")
	_put(bob, Vector3(-3.0, 0.0, 0.0))
	_put_me(PARK_ME, 0.0)
	await wait_physics(3)
	var his := _bundle(&"budget", 1, Vector3(-3.0, 0.0, 0.0), {}, BOB)
	var can := _a_can()
	await wait_frames(2)
	check(his.holder_id == BOB and can != null, "Bob holds a bundle; a can to throw")
	if can != null:
		await _throw(can, Vector3(-3.0, 1.0, 3.0), Vector3(0.0, 1.8, -8.0))
	check(bob.is_stunned() and his.holder_id == 0 and his.bruises == 0, "the can knocks him down: his bundle drops, clean")
	check(_bruised.is_empty(), "nothing bruised so far in this step %s" % [_bruised])
	items.server_despawn_item(his)
	await wait_until(func() -> bool: return not bob.is_stunned() and bob.can_be_staggered(), 3.0, "Bob gets back up")
	_put(bob, FAR_BOB)

	step("no bruise: chute shots (paid what they are worth)")
	var clean := _bundle(&"purple", 1, LANE)
	await wait_frames(1)
	var full := chute.get_sale_value(clean)
	_sales.clear()
	await _throw(clean, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0), 1, true)
	check(_sales == [[full, 1]] and full == TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, GameState.get_sale_multiplier()),
			"a clean bundle into the chute: paid in full ($%d) %s" % [full, _sales])
	check(_bruised.is_empty(), "no bruise for a chute shot")
	var knocked := _bundle(&"purple", 1, LANE, {"bruises": 1})
	await wait_frames(1)
	var bruised_value := chute.get_sale_value(knocked)
	check(knocked.bruises == 1 and bruised_value == int(round(full * 0.8)), "a bundle spawned with a bruise prices at $%d" % bruised_value)
	_sales.clear()
	await _throw(knocked, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0), 1, true)
	check(_sales == [[bruised_value, 1]] and _bruised.is_empty(), "a bruised one into the chute: paid bruised ($%d), no second bruise %s" % [bruised_value, _sales])


func _test_cap(b: BalanceConfig) -> void:
	step("the cap: three hard landings, two bruises")
	_put_me(PARK_ME, 0.0)
	await wait_physics(2)
	_bruised.clear()
	var p := _bundle(&"purple", 1, LANE)
	await wait_frames(1)
	for i in 3:
		await _throw(p, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.0))
	check(p.bruises == b.bruise_max and not p.can_bruise() and _bruised.size() == 2, "two bruises (bruise_max), bundle_bruised twice %s" % [_bruised])
	check(p.get_display_name() == "Purple Haze x1, badly bruised" and chute.get_sale_value(p) == TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, GameState.get_sale_multiplier(), false, 2),
			"'%s': $%d (x0.6)" % [p.get_display_name(), chute.get_sale_value(p)])
	check(not items.server_bruise_bundle(p, 1) and p.bruises == 2, "server_bruise_bundle refuses a third")
	items.server_despawn_item(p)
	await wait_frames(1)


# --- the value ------------------------------------------------------------------------------------------------------------

func _test_value(b: BalanceConfig) -> void:
	step("the value: today's market, cured, bruised, at the chute")
	GameState.server_set_market({&"purple": 1.2})
	await wait_frames(2)
	check(is_equal_approx(GameState.get_market_multiplier(&"purple"), 1.2), "Purple Haze pays x1.2 today")
	GameState.server_set_contract(Contracts.ID_CURED)
	await wait_frames(2)
	var progress0 := int(GameState.get_contract().get("progress", -1))
	var p := _bundle(&"purple", 1, LANE, {"cured": true})
	await wait_frames(1)
	await _throw(p, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.0))
	check(p.bruises == 1 and p.cured, "a cured bundle took a bruise")
	var mult := GameState.get_sale_multiplier()
	var want := int(round(140.0 * mult * (1.0 + b.cure_bonus) * 0.8 * GameState.get_deposit_factor(&"purple", true)))
	var value := chute.get_sale_value(p)
	check(value == want and value == TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, mult, true, 1) and value == 188,
			"the chute prices it at $%d (140 x1.2 market x1.4 cured x0.8 bruised)" % value)
	check(items.server_give_item(p, 1), "I pick it up")
	await stand_near(chute, 1.3)
	await wait_physics(3)
	check(chute.get_prompt(me) == "Deposit Purple Haze x1, cured, bruised (+$%d)" % value, "the chute's prompt: '%s'" % chute.get_prompt(me))
	check(p.get_label_text() == "Purple Haze x1, bruised (Cured)", "what I carry: '%s'" % p.get_label_text())
	var money0 := GameState.money
	var dep0 := GameState.get_stat(1, Const.STAT_DEPOSITED)
	_sales.clear()
	_notes.clear()
	chute.interact(me)
	await wait_until(_gone(p), 3.0, "deposited (E)")
	await wait_frames(2)
	check(GameState.money == money0 + value and _sales == [[value, 1]], "+$%d cash on hand, one sale %s" % [value, _sales])
	check(GameState.get_stat(1, Const.STAT_DEPOSITED) == dep0 + value, "STAT_DEPOSITED +%d" % value)
	check(_notes == [[&"purple", 1, true, value, 1]], "the job hook hears the bruised value %s" % [_notes])
	check(int(GameState.get_contract().get("progress", -1)) == progress0 + 1, "a bruised cured bundle still counts for the cured job")
	GameState.server_set_contract(&"")

	step("the value: the collector and the cost ledger")
	_put_me(PARK_ME, 0.0)
	for i in range(1, Room.GROW_PLOT_COUNT + 1):
		var plot := room.get_station("GrowPlot%d" % i) as GrowPlot
		if plot != null:
			plot.server_reset()
	var whole := _bundle(&"budget", 2, LANE + Vector3(0.0, 0.0, -1.0))
	var dented := _bundle(&"budget", 2, LANE + Vector3(1.0, 0.0, -1.0), {"bruises": 2})
	await wait_frames(2)
	var whole_value := chute.get_sale_value(whole)
	var dented_value := chute.get_sale_value(dented)
	var whole_name := String(whole.name)
	var dented_name := String(dented.name)
	check(dented_value < whole_value and dented_value == int(round(whole_value * 0.6)), "the same bundle: $%d clean, $%d badly bruised" % [whole_value, dented_value])
	var c0 := _ledger_value(Events.COST_COLLECTION)
	var took := Events.server_collect_unpaid()
	await wait_frames(2)
	check(took["what"] == Events.COLLECT_BUNDLE and took["where"] == whole_name, "unpaid, he takes the dearest: the clean one (%s)" % [took])
	check(_ledger_value(Events.COST_COLLECTION) == c0 + whole_value, "booked at $%d" % whole_value)
	took = Events.server_collect_unpaid()
	await wait_frames(2)
	check(took["where"] == dented_name and _ledger_value(Events.COST_COLLECTION) == c0 + whole_value + dented_value,
			"then the bruised one, booked at its bruised $%d" % dented_value)
	GameState.server_set_market({})
	await wait_frames(2)


# --- the hand truck -------------------------------------------------------------------------------------------------------

func _test_truck(b: BalanceConfig) -> void:
	step("the hand truck keeps the bruises")
	var trucks := items.get_items_of_type(Const.ITEM_HAND_TRUCK)
	var truck: HandTruck = trucks[0] as HandTruck if trucks.size() == 1 else null
	if not check(truck != null and truck.get_load_count() == 0, "the dock's hand truck, empty"):
		return
	var at := truck.global_position + Vector3(1.2, 0.0, 0.0)
	var p := _bundle(&"purple", 2, at, {"bruises": 1})
	var q := _bundle(&"budget", 1, at + Vector3(0.0, 0.0, 0.8))
	await wait_frames(2)
	check(truck.server_load(q, 0) and truck.server_load(p, 0), "a clean bundle, then a bruised one, go on the truck")
	await wait_frames(2)
	var entries := truck.get_load()
	check(entries.size() == 2 and not entries[0].has("bruises") and int(entries[1].get("bruises", 0)) == 1,
			"the load: the clean entry has no bruises key, the bruised one 'bruises': 1 %s" % [entries])
	check(HandTruck.encode_cargo(truck.cargo) == "budget|1|0|0.00;purple|2|0|0.00|1", "encoded: '%s'" % HandTruck.encode_cargo(truck.cargo))
	check(HandTruck.decode_cargo("purple|2|0|0.00|1;budget|1|0|0.00") == [{"strain_id": "purple", "amount": 2, "cured": false, "dry_left": 0.0, "bruises": 1},
			{"strain_id": "budget", "amount": 1, "cured": false, "dry_left": 0.0}], "decoded back (the old four-field form still reads)")
	check(HandTruck.clean_entry({"strain_id": "budget", "bruises": 99}).get("bruises", 0) == Product.BRUISE_WIRE_MAX
			and not HandTruck.clean_entry({"strain_id": "budget", "bruises": -1}).has("bruises")
			and not HandTruck.clean_entry({"strain_id": "budget", "bruises": NAN}).has("bruises"), "clean_entry clamps what arrives")
	var bag2 := truck.get_node(^"Visual/Load/Bag2") as Toonify
	var bag_clean := HandTruck.bag_color({"strain_id": "purple"})
	check(bag2 != null and bag2.tint.is_equal_approx(Product.bruised_color(bag_clean, 1)) and bag2.tint.get_luminance() < bag_clean.get_luminance(),
			"the bruised bag on the truck is darker")
	var mult := GameState.get_sale_multiplier() * Events.get_scale_factor()
	var v_p := TurnInStation.compute_sale_value(b.get_seed(&"purple"), 2, mult, false, 1)
	var v_q := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 1, mult)
	var purple_factor := GameState.get_deposit_factor(&"purple")
	check(chute.get_load_value(truck) == v_p + v_q and v_p == int(round(280.0 * mult * purple_factor * 0.8)),
			"the chute's total for the load: $%d ($%d bruised + $%d; x%.2f, market x%.2f)" % [chute.get_load_value(truck), v_p, v_q, mult, purple_factor])
	Events._read_note_trucks()
	var noted: Array = Events._read_truck_values.get(String(truck.name), [])
	check(noted.size() == 2 and int(noted[1][0]) == v_p, "a raid would book the bruised bundle at $%d %s" % [v_p, noted])
	Events._read_truck_values.clear()

	step("unloading restores them; depositing pays the bruised value")
	var off := truck.server_unload(0)
	await wait_frames(2)
	check(off is Product and (off as Product).bruises == 1 and off.get_props() == {"strain_id": "purple", "amount": 2, "bruises": 1}
			and truck.get_load_count() == 1, "the top bundle comes off with its bruise %s" % [off.get_props() if off != null else {}])
	check(truck.server_load(off, 0) and truck.get_load_count() == 2, "and goes back on")
	check(items.server_give_item(truck, 1), "I take the truck")
	await stand_near(chute, 1.4)
	await wait_physics(3)
	check(chute.get_prompt(me) == "Deposit 2 bundles (+$%d)" % (v_p + v_q), "the chute's prompt: '%s'" % chute.get_prompt(me))
	_sales.clear()
	check(chute.server_deposit_truck(truck, 1) == 2, "deposited both")
	await wait_frames(2)
	check(_sales == [[v_p, 1], [v_q, 1]], "one sale each, the bruised one at $%d %s" % [v_p, _sales])
	items.server_release_holder(1)
	_put_me(PARK_ME, 0.0)
	await wait_frames(2)


# --- the toast ------------------------------------------------------------------------------------------------------------

func _test_toast(b: BalanceConfig) -> void:
	step("the toast: once a shift for the thrower")
	var told := _toast_count()
	check(told == 1 and toast_seen(Product.TOAST_BRUISED), "after every bruise this shift: '%s' once (%d)" % [Product.TOAST_BRUISED, told])
	check(items.was_told_bruise(1), "the host was told")
	var p := _bundle(&"budget", 1, LANE)
	await wait_frames(1)
	_bruised.clear()
	await _throw(p, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.0), BOB)
	check(_bruised.size() == 1 and _bruised[0][2] == BOB and items.was_told_bruise(BOB), "Bob's throw bruises it: Bob counts as told")
	check(_toast_count() == told, "no toast here for Bob's (he has no connection, and nothing went wrong)")
	items.server_despawn_item(p)

	step("between shifts: a chute shot is refused and lands clean")
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 0), 1)
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift is paid")
	var late := _bundle(&"purple", 1, LANE)
	await wait_frames(1)
	var money0 := GameState.money
	await _throw(late, Vector3(0.0, 1.3, 3.0), Vector3(0.0, 2.0, 6.0))
	check(is_instance_valid(late) and GameState.money == money0 and late.bruises == 0, "not sold, not bruised (it went into the chute, not onto the floor)")
	items.server_despawn_item(late)

	step("the next shift: told again")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	check(not items.was_told_bruise(1) and not items.was_told_bruise(BOB), "a new shift: nobody told yet")
	var q := _bundle(&"budget", 1, LANE)
	await wait_frames(1)
	await _throw(q, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.0))
	check(q.bruises == 1 and _toast_count() == told + 1, "the first bruise of shift 2 brings the toast again")
	await _throw(q, LANE + Vector3(0.0, 1.2, 0.0), Vector3(0.0, -5.0, 1.0))
	check(q.bruises == 2 and _toast_count() == told + 1, "the second does not")
	var kinds := {}
	for t in toasts:
		if String(t[0]) == Product.TOAST_BRUISED:
			kinds[t[1]] = true
	check(kinds.keys() == [&"info"], "a flat info toast")
	items.server_despawn_item(q)
	check(b.bruise_max == 2, "bruise_max untouched")


# --- helpers ----------------------------------------------------------------------------------------------------------------

func _bundle(strain: StringName, amount: int, at: Vector3, extra: Dictionary = {}, holder: int = 0) -> Product:
	var props := {"strain_id": strain, "amount": amount}
	props.merge(extra, true)
	var p := items.server_spawn_item(Const.ITEM_PRODUCT, props, at, holder) as Product
	if p != null:
		_watch(p)
	return p


## Records, the moment a watched bundle's bruise count goes up, whether the last Sfx voice is the bruise thud and where.
func _watch(p: Product) -> void:
	_watched[p.get_instance_id()] = p.bruises
	p.props_changed.connect(func() -> void:
		if not is_instance_valid(p):
			return
		var was := int(_watched.get(p.get_instance_id(), 0))
		if p.bruises > was:
			var v := Sfx.get_last_voice()
			var is_bruise: bool = v != null and v.get(&"stream") == Sfx.get_stream(&"bruise")
			var where: Vector3 = (v as Node3D).global_position if v is Node3D else Vector3.INF
			_knocks.append([String(p.name), p.bruises, is_bruise, where])
		_watched[p.get_instance_id()] = p.bruises)


## Throws `it` and waits until it is down (or sold: gone). `sold` = a chute shot (waits for the despawn).
func _throw(it: Item, origin: Vector3, velocity: Vector3, thrower: int = 1, sold: bool = false) -> void:
	if not check(items.server_throw_item(it, origin, velocity, thrower), "thrown from %s at %s" % [origin, velocity]):
		return
	if sold:
		await wait_until(_gone(it), 3.5, "into the chute: sold")
		await wait_frames(2)
	else:
		var id := it.get_instance_id()
		await wait_until(func() -> bool:
			var o := instance_from_id(id) as Item
			return o == null or not o.is_flying(), 3.5, "down")
		await wait_frames(1)


## A predicate (no capture of the node itself: it may be freed while waited on): `it` is despawned.
func _gone(it: Item) -> Callable:
	var id := it.get_instance_id()
	return func() -> bool:
		var o := instance_from_id(id) as Item
		return o == null or o.is_queued_for_deletion()


func _bud_color(p: Product) -> Color:
	var bud := p.get_node(^"Visual/Cluster/Buds").get_child(0) as MeshInstance3D
	var mat := bud.material_override as StandardMaterial3D if bud != null else null
	return mat.albedo_color if mat != null else Color.BLACK


func _buds_grimed(p: Product) -> bool:
	for n in p.get_node(^"Visual/Cluster").find_children("*", "MeshInstance3D", true, false):
		var mesh := n as MeshInstance3D
		var is_bud := p.get_node(^"Visual/Cluster/Buds").is_ancestor_of(mesh)
		if (is_bud or mesh.has_meta(&"toonify_outline")) and mesh.material_overlay != null:
			return true
	return false


func _a_can() -> Item:
	for it in items.get_items_of_type(Const.ITEM_WATERING_CAN):
		if not it.is_held() and not it.is_flying():
			return it
	return null


func _ledger_value(source: String) -> int:
	var e: Dictionary = Events.get_shift_costs().get(source, {})
	return int(e.get("value", 0))


func _toast_count() -> int:
	var n := 0
	for t in toasts:
		if String(t[0]) == Product.TOAST_BRUISED:
			n += 1
	return n


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
