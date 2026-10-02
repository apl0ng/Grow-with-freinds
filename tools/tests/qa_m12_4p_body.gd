extends "res://tools/tests/qa_m10_4p_base.gd"
## M12 4-player stress suite (QA, milestone M13). One HOST + three CLIENTS as separate headless processes on the real
## game stack, driven by tools/tests/qa_m12_4p.sh; every process runs THIS script with a role:
##   --role=host                  the director: sends commands, compares every peer's view with its own
##   --role=client --who=a|b|c    Alpha / Bravo / Charlie (Charlie's process is launched LATE, on QAM12_LAUNCH_LATE: the
##                                fourth worker joins in the middle of the chase)
## Common args: --port=N --round-sec=900 --events --timeout=S. It reuses the M10 command set (qa_m10_4p_base.gd:
## goto / report / leave_rejoin / fuse_reset / work_loop / expect_host_leave ...) and adds the M12 ones below.
## Every scenario ends with canonical_state() equal on every peer AND the M12 state equal (sync_point): hostile ids /
## strain / state / position within POS_TOL, each plot's `turning`, the cabinet's `broken` / `restock_left`, each
## flamethrower's fuel (tenths) / firing / holder, the well pressure, the shop shortage, the active event, the power,
## the back room, the strikes, the cash and the stats ledger.
## Time is compressed on the host with Hostiles.tick / Events.tick / GameState.time_left and in-process balance
## overrides; where a scenario needs the plant to hold still the host stops Hostiles' own physics tick and steps it.
## Scenarios (host side, asserted with ok/FAIL lines):
##   (1) mutation under load: six trays of a strain forced to mutation_chance 1.0 turn READY in one tick; every peer
##       sees the twitch and the six "... is moving." lines; a client harvests one in time; Bravo joins again
##       mid-warning and sees the twitch; hostile_max holds and the trays that found the floor full wait (still
##       moving, still harvestable) and come out one by one as slots free
##   (2) the chase: the plant bites Alpha, then Bravo (stun on the victim's own process, the can out of their hands
##       on every peer, STAT_BITTEN); no bite through the fence and the chase is given up there; Alpha is sent to the
##       back room mid-chase (never bitten there, not even with the plant against the booth wall); Charlie joins
##       mid-chase and sees the plant; Bravo disconnects while targeted
##   (3) fire: Alpha breaks the glass (deposit, no write-up with a plant alive), burns the plant down (hostile_died,
##       STAT_BURNS), the tray behind it scorches, Bravo and Charlie walk into the cone (ignited once each), the third
##       arson sends Alpha to the back room while firing and the Boss keeps his flamethrower (gone on every peer); the
##       cabinet restocks, Bravo takes one (misuse), throws it while it fires, fires again and drops out of the
##       session; Alpha takes another; both fire at once, Charlie joins mid-fire, both tanks run dry; a trigger on an
##       empty tank is refused
##   (4) events on top: a head count with a plant on the Boss's route, water off while a tray dries and the plant eats
##       another, forged M12 requests from a client, a shortage, a power cut (the plant eats in the dark), an
##       inspection (a worker behind the plant is not seen; a worker pinned by a bite is not written up for loitering
##       while he cannot move)
##   (5) churn: two workers break the glass in the same frame; the shift fails with plants, flamethrowers, a broken
##       cabinet, a running event, a turning tray: RETRY resets it all; back to the menu and a fresh host on the same
##       port; a 30 s shift with the scheduler on and mutation chances raised, a client re-joining in the middle of it;
##       the host leaves with plants on the floor
## Charlie's first join is a fresh process; every later "join" is a client leaving and joining again (a new peer id,
## a fresh World, the host's late-join replays).

const CAN := Const.ITEM_WATERING_CAN
const PRODUCT := Const.ITEM_PRODUCT
const FLAME := Const.ITEM_FLAMETHROWER
## The strain forced to mutation_chance 1.0 on the host, and the one used for directly spawned plants.
const MUT_STRAIN: StringName = &"nightshift"
const SPARE_STRAIN: StringName = &"creeper"
## Hostile positions agree across peers within this (10 Hz unreliable poses, smoothed on clients).
const POS_TOL := 1.0
## Far from everything the plant can sense (5 m) or keep chasing (7 m).
const PARK := {"a": Vector3(-8.5, 0.05, 2.0), "b": Vector3(-8.5, 0.05, 3.5), "c": Vector3(-8.5, 0.05, 5.0), "host": Vector3(-8.5, 0.05, 6.5)}
## The plant starts here, west of the grow-area fence, and walks up to it; a worker at FENCE_INSIDE stands half a
## metre behind the fence: inside the bite range, no clear line.
const FENCE_OUTSIDE := Vector3(1.9, 0.0, -4.4)
const FENCE_INSIDE := Vector3(3.5, 0.05, -4.4)
## A chase across open floor: 4.5 m apart, in the sense range, nobody else within it.
const CHASE_FROM := Vector3(-4.0, 0.0, -2.0)
const CHASE_TARGET := Vector3(0.5, 0.05, -2.0)

var _ids: Dictionary = {}
## Host: the clients in the session, by key. Charlie's process is launched late (marker QAM12_LAUNCH_LATE): he is the
## fourth worker and joins in the middle of the chase.
var _all: Array = ["a", "b"]
var _t0_msec: int = 0
var _trouble: Dictionary = {}

# --- M12 records (every peer) ---
var _h_spawned: Array = []     # [id, strain, position, local msec]
var _h_bit: Array = []         # [id, peer, stunned here (1 / 0; -1 = not my bite)]
var _h_ate: Array = []         # [id, plot]
var _h_eating: Array = []      # [id, plot]
var _h_died: Array = []        # [id, by]
var _barks: Array = []         # Story lines shown on this peer
var _turn_seen: Dictionary = {}    # plot index -> true (saw `turning`)
var _twitch_seen: Dictionary = {}  # plot index -> true (saw the plant jitter while turning)
var _ignited: Array = []       # [victim, by]
var _glass: Array = []         # [by]
var _restocked: int = 0
var _scorches: Array = []      # [plot, by]
var _fire_ev: Array = []       # [flamethrower name, firing]
var _fuel_log: Dictionary = {} # flamethrower name -> Array of synced fuel values in arrival order
var _purchases: Array = []     # [cost, buyer, what]
var _pressure_ev: Array = []   # [on]
var _shortage_ev: Array = []   # [strain]


func _ready() -> void:
	super()
	Hostiles.hostile_spawned.connect(func(id: int, s: StringName, p: Vector3) -> void: _h_spawned.append([id, String(s), p, Time.get_ticks_msec()]))
	Hostiles.hostile_bit.connect(_on_hostile_bit)
	Hostiles.hostile_ate.connect(func(id: int, p: int) -> void: _h_ate.append([id, p]))
	Hostiles.hostile_eating.connect(func(id: int, p: int) -> void: _h_eating.append([id, p]))
	Hostiles.hostile_died.connect(func(id: int, by: int) -> void: _h_died.append([id, by]))
	Story.bark_shown.connect(func(text: String) -> void: _barks.append(text))
	GameState.purchase_made.connect(func(cost: int, buyer: int, what: String) -> void: _purchases.append([cost, buyer, what]))


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7965))
	_label = "m12_4p:" + (role if role == "host" else who)
	_t0_msec = Time.get_ticks_msec()
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


func _process(delta: float) -> void:
	super(delta)
	_poll_plots()


## The victim's own process records whether the stun had landed when the bite was announced (the stagger goes to the
## owner first, the broadcast right after, on the same reliable channel).
func _on_hostile_bit(id: int, peer: int) -> void:
	var mine := peer == multiplayer.get_unique_id() and Game.local_player != null
	_h_bit.append([id, peer, (1 if Game.local_player.is_stunned() else 0) if mine else -1])


func _poll_plots() -> void:
	if Game.world == null or not is_instance_valid(Game.world) or Game.world.room == null:
		return
	for i in range(1, 7):
		var p := plot(i)
		if p == null or not p.turning:
			continue
		_turn_seen[i] = true
		var plant := p.get_node_or_null(^"%Plant") as Node3D
		if plant != null and plant.rotation != Vector3.ZERO:
			_twitch_seen[i] = true


func _on_world_ready(w: World) -> void:
	super(w)
	if w == null or not is_instance_valid(w) or w.room == null:
		return
	var cab := station("EmergencyCabinet") as EmergencyCabinet
	if cab != null:
		cab.glass_broken.connect(func(by: int) -> void: _glass.append([by]))
		cab.restocked.connect(func() -> void: _restocked += 1)
	for i in range(1, 7):
		var p := plot(i)
		if p != null:
			p.scorched.connect(func(by: int) -> void: _scorches.append([i, by]))
	var well := station("Well") as Well
	if well != null:
		well.pressure_changed.connect(func(on: bool) -> void: _pressure_ev.append([on]))
	var counter := station("ShopCounter") as ShopCounter
	if counter != null:
		counter.shortage_changed.connect(func(s: StringName) -> void: _shortage_ev.append([String(s)]))
	for it in w.items.get_items():
		_hook_item(it)
	w.items.item_added.connect(_hook_item)


func _hook_player(node: Node) -> void:
	super(node)
	var p := node as Player
	if p == null or p.has_meta(&"qam12_hooked"):
		return
	p.set_meta(&"qam12_hooked", true)
	p.ignited.connect(func(by: int) -> void: _ignited.append([p.peer_id, by]))


func _hook_item(it: Item) -> void:
	var ft := it as Flamethrower
	if ft == null or ft.has_meta(&"qam12_hooked"):
		return
	ft.set_meta(&"qam12_hooked", true)
	var n := String(ft.name)
	_fuel_log[n] = [ft.fuel]
	ft.firing_changed.connect(func(on: bool) -> void: _fire_ev.append([n, on]))
	ft.props_changed.connect(func() -> void:
		var log: Array = _fuel_log[n]
		if log.is_empty() or float(log.back()) != ft.fuel:
			log.append(ft.fuel))


# =================================================================================================== M12 state

## Everything M12 added that must agree across peers, in plain types (RPC-safe).
func _m12_state() -> Dictionary:
	var hs: Array = []
	for n in Hostiles.get_hostiles():
		var h := n as HostilePlant
		hs.append([h.id, String(h.strain_id), h.state, h.global_position])
	hs.sort_custom(func(x: Array, y: Array) -> bool: return int(x[0]) < int(y[0]))
	var turning: Array = []
	for i in range(1, 7):
		var p := plot(i)
		turning.append(p != null and p.turning)
	var flames: Array = []
	for it in items_of(FLAME):
		var ft := it as Flamethrower
		flames.append([String(ft.name), int(round(ft.fuel * 10.0)), ft.firing, ft.holder_id])
	flames.sort_custom(func(x: Array, y: Array) -> bool: return String(x[0]) < String(y[0]))
	var cab := station("EmergencyCabinet") as EmergencyCabinet
	var well := station("Well") as Well
	var counter := station("ShopCounter") as ShopCounter
	var strikes: PackedStringArray = []
	for k in GameState.write_ups.keys():
		strikes.append("%d=%d" % [int(k), int(GameState.write_ups[k])])
	strikes.sort()
	return {
		"hostiles": hs,
		"turning": turning,
		"broken": cab != null and cab.broken,
		"restock": cab.restock_left if cab != null else -1,
		"flames": flames,
		"pressure": well != null and well.has_pressure(),
		"shortage": String(counter.get_shortage_strain()) if counter != null else "?",
		"event": String(Events.active_event),
		"power": Events.is_power_on(),
		"backroom": _backroom_sig(),
		"strikes": ",".join(strikes),
		"money": GameState.money,
		"stats": _stats_sig(),
	}


## "" when `theirs` matches `mine` (hostile positions within `tol`).
static func _m12_diff(mine: Dictionary, theirs: Dictionary, tol: float) -> String:
	if theirs.is_empty():
		return "no answer"
	var bad: PackedStringArray = []
	for k in ["turning", "broken", "restock", "flames", "pressure", "shortage", "event", "power", "backroom", "strikes", "money", "stats"]:
		if str(mine.get(k)) != str(theirs.get(k, "<none>")):
			bad.append("%s: host %s, peer %s" % [k, mine.get(k), theirs.get(k, "<none>")])
	var a: Array = mine.get("hostiles", [])
	var b: Array = theirs.get("hostiles", [])
	if a.size() != b.size():
		bad.append("hostiles: host %s, peer %s" % [a, b])
	else:
		for i in a.size():
			var x: Array = a[i]
			var y: Array = b[i]
			if int(x[0]) != int(y[0]) or String(x[1]) != String(y[1]) or int(x[2]) != int(y[2]):
				bad.append("hostile #%d: host %s, peer %s" % [i, x, y])
			elif not (Vector3(x[3]).distance_to(Vector3(y[3])) <= tol):
				bad.append("hostile %d is %.2f m off (host %s, peer %s)" % [int(x[0]), Vector3(x[3]).distance_to(Vector3(y[3])), x[3], y[3]])
	return "; ".join(bad)


func _m12_log() -> Dictionary:
	var kinds_started: Array = []
	for e in _ev_started:
		kinds_started.append(String(e[0]))
	var kinds_ended: Array = []
	for e in _ev_ended:
		kinds_ended.append(String(e[0]))
	var turn: Array = _turn_seen.keys()
	turn.sort()
	var twitch: Array = _twitch_seen.keys()
	twitch.sort()
	return {
		"spawned": _h_spawned.duplicate(true), "bit": _h_bit.duplicate(true), "ate": _h_ate.duplicate(true),
		"eating": _h_eating.duplicate(true), "died": _h_died.duplicate(true), "barks": _barks.duplicate(),
		"turn_seen": turn, "twitch_seen": twitch, "ignited": _ignited.duplicate(true), "glass": _glass.duplicate(true),
		"restocked": _restocked, "scorches": _scorches.duplicate(true), "fire_ev": _fire_ev.duplicate(true),
		"fuel_log": _fuel_log.duplicate(true), "purchases": _purchases.duplicate(true), "flame_toasts": _toasts_with("flamethrower"),
		"pressure_ev": _pressure_ev.duplicate(true), "shortage_ev": _shortage_ev.duplicate(true),
		"written": _written.duplicate(true), "ev_started": kinds_started, "ev_ended": kinds_ended,
	}


## Every toast this peer showed so far whose text contains `substring`.
func _toasts_with(substring: String) -> Array:
	var out: Array = []
	for t in toasts:
		if String(t[0]).contains(substring):
			out.append(String(t[0]))
	return out


func _clear_m12_log() -> void:
	for list in [_h_spawned, _h_bit, _h_ate, _h_eating, _h_died, _barks, _ignited, _glass, _scorches, _fire_ev,
			_purchases, _pressure_ev, _shortage_ev, _written, _ev_started, _ev_ended]:
		(list as Array).clear()
	_turn_seen.clear()
	_twitch_seen.clear()
	_restocked = 0
	for n in _fuel_log.keys():
		var ft := item_named(String(n)) as Flamethrower
		if ft == null:
			_fuel_log.erase(n)
		else:
			_fuel_log[n] = [ft.fuel]


## Rows [a, b, ...] in `rows` whose first (and second, when `b` is given) column match.
static func _rows(rows: Variant, a: Variant, b: Variant = null) -> int:
	var n := 0
	if rows is Array:
		for e in (rows as Array):
			if not (e is Array) or (e as Array).is_empty() or str(e[0]) != str(a):
				continue
			if b == null or ((e as Array).size() >= 2 and str(e[1]) == str(b)):
				n += 1
	return n


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	check(Config.has_arg("events") and Events.are_events_enabled(), "events allowed (--events)")
	# The scheduler stays quiet until the scheduled shift (5c); every event before it is started by hand.
	b.event_first_delay_sec = FAR_AWAY
	b.event_gap_min_sec = FAR_AWAY
	b.event_gap_max_sec = FAR_AWAY
	Config.growth_speed_override = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null, 10.0, "host player spawned")
	await wait_until(func() -> bool: return items_of(CAN).size() == b.starting_watering_cans, 10.0, "starting cans spawned")
	print("QAM12_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered"):
		await _abort(); return
	for k in _all:
		_ids[k] = _peer_named(k)
	await wait_until(func() -> bool: return _player("a") != null and _player("b") != null, 10.0, "their Player nodes exist")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift 1 running")
	check(Events.get_next_event_in() > 1000.0, "scheduler parked (next event in %.0f s)" % Events.get_next_event_in())
	await _park_all()
	await sync_point("joined", _all)

	await _case_mutation()
	await _case_chase()
	if int(_ids.get("c", 0)) <= 0:
		await _abort(); return
	await _case_fire()
	await _case_events()
	await _case_churn_retry()
	await _case_fresh_host()
	await _case_short_shift()
	await _case_host_leaves()
	step("done")
	finish()


# ---------------------------------------------------------------- (1) mutation under load

func _case_mutation() -> void:
	step("(1) mutation under load: six trays of %s (mutation_chance forced to 1.0) turn READY in the same tick" % MUT_STRAIN)
	var b: BalanceConfig = Config.balance
	var sdef: SeedDef = b.get_seed(MUT_STRAIN)
	if not check(sdef != null and b.hostile_max == 2, "strain %s exists, hostile_max is 2" % MUT_STRAIN):
		return
	var chance0 := sdef.mutation_chance
	sdef.mutation_chance = 1.0
	# The test steps Hostiles itself here: the six rolls and the six countdowns land in known ticks.
	_freeze_hostiles(true)
	await _clear_logs()
	var planted := true
	for i in range(1, 7):
		planted = plot(i).server_plant(MUT_STRAIN) and plot(i).server_water(1.0) and planted
	check(planted, "six trays planted and watered")
	await wait_sec(0.3)
	for i in range(1, 7):
		plot(i).stage = GrowPlot.Stage.READY
	Hostiles.tick(0.05)
	var all_turn := true
	for i in range(1, 7):
		all_turn = all_turn and plot(i).is_turning() and absf(plot(i).turn_left - b.mutation_warning_sec) < 0.2
	check(all_turn, "host: all six turn in one tick, %.0f s of warning each" % b.mutation_warning_sec)
	check(Hostiles.count() == 0, "nothing on the floor yet")
	await wait_sec(1.0) # the twitch tween steps every 0.11 s on every peer

	step("Alpha harvests GrowPlot 5 while it moves (the real interact request)")
	var r := await run_cmd(_ids["a"], "harvest", {"plot": 5})
	check(bool(r.get("ok", false)), "Alpha holds the bundle %s" % [r.get("toasts", [])])
	Hostiles.tick(0.05)
	check(plot(5).is_empty() and not plot(5).turning, "host: GrowPlot 5 harvested, its twitch cleared")
	var logs := await _logs(_all)
	var six := [1, 2, 3, 4, 5, 6]
	check(_turn_seen.keys().size() == 6 and _twitch_seen.keys().size() == 6, "host saw six trays turn and twitch")
	for k in _all:
		var lg: Dictionary = logs[k]
		check(str(lg.get("turn_seen", [])) == str(six), "%s saw `turning` on all six trays %s" % [NAMES[k], lg.get("turn_seen", [])])
		check(str(lg.get("twitch_seen", [])) == str(six), "%s saw all six plants twitch %s" % [NAMES[k], lg.get("twitch_seen", [])])
		var barks: Array = lg.get("barks", [])
		var lines := 0
		for i in six:
			if barks.has("GrowPlot %d is moving." % i):
				lines += 1
		check(lines == 6, "%s got the six '... is moving.' lines (%d)" % [NAMES[k], lines])
	await sync_point("six trays moving", _all)

	step("Bravo drops out and joins again while five trays are still moving")
	var old_b: int = _ids["b"]
	var s_b := cmd(old_b, "leave_rejoin", {"delay": 0.5})
	if not await wait_until(func() -> bool: return _peer_named("b") > 0 and _peer_named("b") != old_b, 20.0, "Bravo left and re-joined (new peer id)"):
		return
	_ids["b"] = _peer_named("b")
	await wait_until(func() -> bool: return _player("b") != null, 10.0, "the new Bravo's Player node exists")
	await await_ack(s_b, 25.0)
	r = await run_cmd(_ids["b"], "late_turning", {"count": 5}, 15.0)
	var five := [1, 2, 3, 4, 6]
	check(str(r.get("turning", [])) == str([true, true, true, true, false, true]), "Bravo (late): five trays are turning on his peer %s" % [r.get("turning", [])])
	check(str(r.get("turn_seen", [])) == str(five) and str(r.get("twitch_seen", [])) == str(five), "Bravo (late): he sees those five twitch %s" % [r.get("twitch_seen", [])])
	r = await run_cmd(_ids["b"], "goto", {"pos": PARK["b"]})
	await sync_point("Bravo joined mid-warning", _all)

	step("the warning runs out for five trays in the same tick")
	_h_spawned.clear()
	Hostiles.tick(b.mutation_warning_sec)
	await wait_frames(2)
	check(Hostiles.count() == b.hostile_max, "hostile_max holds: %d on the floor (%d)" % [b.hostile_max, Hostiles.count()])
	check(_h_spawned.size() == 2, "hostile_spawned fired twice on the host (%d)" % _h_spawned.size())
	var at_trays := _h_spawned.size() == 2
	for e in _h_spawned:
		at_trays = at_trays and String(e[1]) == String(MUT_STRAIN) and (Vector3(e[2]).distance_to(plot(1).global_position) < 0.1 or Vector3(e[2]).distance_to(plot(2).global_position) < 0.1)
	check(at_trays, "they came out of GrowPlot 1 and GrowPlot 2, strain %s" % MUT_STRAIN)
	check(plot(1).is_empty() and plot(2).is_empty(), "those two crops are lost")
	# The rule (M13 review): a tray whose warning runs out while the floor is full does not lose its crop to nothing.
	# It waits in its tray, still moving, still harvestable, and comes out when a slot frees.
	check(_waiting([3, 4, 6]) and not Hostiles.has_room(), "the three trays that found the floor full wait: READY, still moving, crop intact (%s)" % [_plot_sig()])
	Hostiles.tick(1.0)
	await wait_frames(2)
	check(Hostiles.count() == b.hostile_max and _h_spawned.size() == 2 and _waiting([3, 4, 6]), "a second later: still %d plants, the three trays still wait" % b.hostile_max)
	logs = await _logs(_all)
	for k in _all:
		check(_same_spawns(logs[k].get("spawned", []), 2), "%s saw the same two spawns (ids, strain, trays)" % NAMES[k])
		var barks: Array = logs[k].get("barks", [])
		check(barks.has("Something came out of GrowPlot 1.") and barks.has("Something came out of GrowPlot 2."), "%s got both 'Something came out of ...' lines" % NAMES[k])
	await sync_point("after the uprooting", _all)

	step("Bravo harvests GrowPlot 4 while it waits for the floor: still harvestable")
	r = await run_cmd(_ids["b"], "harvest", {"plot": 4})
	check(bool(r.get("ok", false)), "Bravo holds the bundle %s" % [r.get("toasts", [])])
	Hostiles.tick(0.05)
	check(plot(4).is_empty() and not plot(4).turning and Hostiles.count() == b.hostile_max and _waiting([3, 6]), "host: GrowPlot 4 harvested, its twitch cleared, nothing came out of it")
	await _park_all()

	step("one plant burns down (fire nobody is credited for): the slot frees and GrowPlot 3 comes out")
	var burnt := Hostiles.get_hostiles()[1] as HostilePlant
	var burnt_id := burnt.id
	_h_died.clear()
	Hostiles.server_apply_fire(burnt_id, b.hostile_burn_sec + 0.1, 0)
	check(burnt.is_dead() and _h_died.size() == 1 and int(_h_died[0][0]) == burnt_id and int(_h_died[0][1]) == 0, "host: hostile_died(id, 0) %s" % [_h_died])
	check(Hostiles.has_room(), "a burnt plant still lying there does not hold the slot")
	Hostiles.tick(0.05)
	await wait_frames(2)
	check(_h_spawned.size() == 3 and Vector3(_h_spawned[2][2]).distance_to(plot(3).global_position) < 0.1 and plot(3).is_empty() and not plot(3).turning, "GrowPlot 3 uprooted into the free slot")
	check(_waiting([6]) and not Hostiles.has_room(), "GrowPlot 6 still waits: the floor is full again")
	check(_stat_total(Const.STAT_BURNS) == 0, "no STAT_BURNS for anybody")
	Hostiles.tick(HostilePlant.DEATH_DELAY + 0.1)
	await wait_frames(2)
	check(Hostiles.count() == b.hostile_max and Hostiles.get_hostile(burnt_id) == null, "the burnt one is removed: %d plants" % b.hostile_max)
	logs = await _logs(_all)
	for k in _all:
		check(_same_spawns(logs[k].get("spawned", []), 3), "%s saw the third spawn too" % NAMES[k])
		check(_rows(logs[k].get("died", []), burnt_id, 0) == 1, "%s: hostile_died(id, 0)" % NAMES[k])
		check((logs[k].get("barks", []) as Array).has("Something came out of GrowPlot 3."), "%s got 'Something came out of GrowPlot 3.'" % NAMES[k])
	await sync_point("a freed slot", _all)
	# The last waiting tray is harvested (server side) so nothing comes out behind the next scenarios' backs.
	check(plot(6).server_harvest(null), "the last waiting tray is harvested")
	Hostiles.tick(0.05)
	check(not plot(6).turning, "its twitch cleared")
	sdef.mutation_chance = chance0
	for it in items_of(PRODUCT):
		Game.world.items.server_despawn_item(it)


# ---------------------------------------------------------------- (2) the chase

func _case_chase() -> void:
	step("(2) the chase")
	var b: BalanceConfig = Config.balance
	var items := Game.world.items
	var hs := Hostiles.get_hostiles()
	if not check(hs.size() == 2, "two plants from scenario 1"):
		return
	var h := hs[0] as HostilePlant
	var extra := hs[1] as HostilePlant
	await _park_all()
	await _clear_logs()

	step("the second plant burns down too: no tray waits any more, nothing comes out")
	var spawns0 := _h_spawned.size()
	Hostiles.server_apply_fire(extra.id, b.hostile_burn_sec + 0.1, 0)
	check(extra.is_dead(), "host: it is dead")
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.1) # the dead one outlives DEATH_DELAY
	await wait_frames(2)
	check(Hostiles.count() == 1 and h.state == HostilePlant.State.ROAM and _h_spawned.size() == spawns0, "one plant left, roaming; no new spawn")

	step("it bites Alpha, then Bravo")
	var can := items.server_spawn_item(CAN, {"charges": 2}, Vector3.ZERO, _ids["a"])
	var can2 := items.server_spawn_item(CAN, {"charges": 2}, Vector3.ZERO, _ids["b"])
	check(can != null and can.holder_id == _ids["a"] and can2 != null and can2.holder_id == _ids["b"], "Alpha and Bravo each hold a can")
	_place_hostile(h, Vector3(1.0, 0.0, 2.0))
	_freeze_hostiles(false) # real time from here: it hunts on its own
	cmd(_ids["a"], "goto", {"pos": Vector3(2.5, 0.05, 2.0), "look": Vector3(1.0, 0.05, 2.0)})
	await wait_until(func() -> bool: return _rows(_h_bit, h.id, _ids["a"]) >= 1, 8.0, "host: it bit Alpha")
	check(GameState.get_stat(_ids["a"], Const.STAT_BITTEN) == 1, "STAT_BITTEN 1 for Alpha")
	check(can != null and can.holder_id == 0, "the can is out of Alpha's hands")
	cmd(_ids["a"], "goto", {"pos": PARK["a"]})
	cmd(_ids["b"], "goto", {"pos": Vector3(1.0, 0.05, 0.0), "look": Vector3(1.0, 0.05, 2.0)})
	await wait_until(func() -> bool: return _rows(_h_bit, h.id, _ids["b"]) >= 1, 10.0, "host: it bit Bravo")
	check(GameState.get_stat(_ids["b"], Const.STAT_BITTEN) == 1 and can2 != null and can2.holder_id == 0, "STAT_BITTEN 1 for Bravo, his can on the floor")
	var r := await run_cmd(_ids["b"], "goto", {"pos": PARK["b"]})
	_freeze_hostiles(true)
	check(GameState.get_stat(_ids["a"], Const.STAT_BITTEN) == 1, "Alpha walked away after one bite")
	var logs := await _logs(_all)
	for k in _all:
		var bit: Array = logs[k].get("bit", [])
		var bites_b := GameState.get_stat(_ids["b"], Const.STAT_BITTEN)
		check(_rows(bit, h.id, _ids["a"]) == 1 and _rows(bit, h.id, _ids["b"]) == bites_b, "%s saw hostile_bit for Alpha once and for Bravo %d time(s)" % [NAMES[k], bites_b])
	for k in ["a", "b"]:
		var stunned := true
		var mine := 0
		for e in (logs[k].get("bit", []) as Array):
			if int(e[1]) == _ids[k]:
				mine += 1
				stunned = stunned and int(e[2]) == 1
		check(mine >= 1 and stunned, "%s was stunned on his own process when his bite was announced" % NAMES[k])
	await sync_point("after two bites", _all)

	step("the fence: no bite through it, and the plant gives up after STUCK_SEC")
	# Alpha stands half a metre inside the grow-area fence, the plant comes up to it from outside: inside its bite
	# range, no clear line (M13 review). Stepped by hand: 3.5 s of plant time.
	_place_hostile(h, FENCE_OUTSIDE)
	r = await run_cmd(_ids["a"], "goto", {"pos": FENCE_INSIDE, "look": FENCE_OUTSIDE})
	var bites0 := _h_bit.size()
	var chased := false
	var closest := INF
	for i in 35:
		Hostiles.tick(0.1)
		if h.state == HostilePlant.State.CHASE and h.get_target_index() == _ids["a"]:
			chased = true
			closest = minf(closest, h.global_position.distance_to(_player("a").global_position))
	check(chased and closest <= HostilePlant.BITE_RANGE, "it chased him up to the fence, %.2f m from him (bite range %.1f)" % [closest, HostilePlant.BITE_RANGE])
	check(_h_bit.size() == bites0 and GameState.get_stat(_ids["a"], Const.STAT_BITTEN) == 1, "no bite through the fence")
	check(h.state == HostilePlant.State.ROAM and h._calm_left > 0.0, "it gave the chase up and went calm (%s, calm for %.1f s)" % [h.get_state_name(), h._calm_left])
	await sync_point("at the fence", _all)

	step("Alpha is sent to the back room mid-chase: never bitten there")
	# A slow plant (in-process override): the chase lasts as long as the test needs it, with the plant on the move.
	var speed0 := b.hostile_speed
	b.hostile_speed = 0.15
	_place_hostile(h, CHASE_FROM)
	r = await run_cmd(_ids["a"], "goto", {"pos": CHASE_TARGET, "look": CHASE_FROM})
	_freeze_hostiles(false)
	await wait_until(func() -> bool: return h.state == HostilePlant.State.CHASE and h.get_target_index() == _ids["a"], 5.0, "host: it chases Alpha across the floor")
	await wait_sec(0.6)
	var gap := h.global_position.distance_to(_player("a").global_position)
	check(h.state == HostilePlant.State.CHASE and gap > HostilePlant.BITE_RANGE and h.global_position.distance_to(CHASE_FROM) > 0.03, "it is on its way, %.2f m from him" % gap)
	await m12_checkpoint("mid-chase", _all)
	bites0 = _h_bit.size()
	check(GameState.server_send_to_backroom(_ids["a"], 20.0), "Alpha sent to the back room")
	await wait_until(func() -> bool: return _at_a_backroom_slot(_player("a")), 5.0, "host: Alpha's body in the back room")
	await wait_until(func() -> bool: return h.get_target_index() != _ids["a"], 3.0, "the plant let go of him")
	_freeze_hostiles(true)
	# Against the booth wall, 1.6 m from his cot: inside the bite range, through the wall.
	var cot := _player("a").global_position
	var at_wall := Vector3(cot.x + 1.6, 0.0, cot.z)
	chased = false
	for i in 20:
		_place_hostile(h, at_wall, false)
		Hostiles.tick(0.1)
		chased = chased or h.get_target_index() == _ids["a"]
	check(not chased and _h_bit.size() == bites0, "two seconds at the wall, 1.6 m from him: never chased, never bitten")
	h._target_peer = _ids["a"]
	h.state = HostilePlant.State.CHASE
	Hostiles.tick(0.1)
	check(h.state != HostilePlant.State.CHASE and h.state != HostilePlant.State.BITE and _h_bit.size() == bites0, "a chase forced onto a back-room worker is dropped at once (%s)" % h.get_state_name())
	check(GameState.get_stat(_ids["a"], Const.STAT_BITTEN) == 1, "STAT_BITTEN unchanged for Alpha")
	GameState.server_release_from_backroom(_ids["a"])
	await wait_until(func() -> bool: return not _at_a_backroom_slot(_player("a")), 5.0, "Alpha released, back on the floor")
	r = await run_cmd(_ids["a"], "goto", {"pos": PARK["a"]})

	step("the plant chases Bravo; Charlie, the fourth worker, joins mid-chase (a fresh process)")
	_place_hostile(h, CHASE_FROM)
	r = await run_cmd(_ids["b"], "goto", {"pos": CHASE_TARGET, "look": CHASE_FROM})
	_freeze_hostiles(false)
	await wait_until(func() -> bool: return h.state == HostilePlant.State.CHASE and h.get_target_index() == _ids["b"], 5.0, "host: it chases Bravo")
	print("QAM12_LAUNCH_LATE")
	if not await wait_until(func() -> bool: return _peer_named("c") > 0, 40.0, "Charlie registered"):
		return
	_ids["c"] = _peer_named("c")
	_all = ["a", "b", "c"]
	await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists")
	check(h.state == HostilePlant.State.CHASE and h.get_target_index() == _ids["b"], "the chase was still on when he arrived")
	r = await run_cmd(_ids["c"], "late_hostile", {}, 15.0)
	var seen: Array = r.get("hostiles", [])
	check(seen.size() == 1 and int(seen[0][0]) == h.id and String(seen[0][1]) == String(h.strain_id), "Charlie: one plant, id %d, strain %s %s" % [h.id, h.strain_id, seen])
	check(seen.size() == 1 and int(seen[0][2]) == HostilePlant.State.CHASE, "Charlie: it is in the CHASE state on his peer")
	check(seen.size() == 1 and Vector3(seen[0][3]).distance_to(h.global_position) <= POS_TOL, "Charlie: it stands where the host has it")
	check(_rows(r.get("spawned", []), h.id) == 1, "Charlie: hostile_spawned fired once, from the late-join replay")
	check(int(r.get("ms", 99999)) <= LATE_JOIN_LIMIT_MS, "Charlie saw it %d ms after spawning" % int(r.get("ms", -1)))
	r = await run_cmd(_ids["c"], "goto", {"pos": PARK["c"]})
	check(h.state == HostilePlant.State.CHASE and h.get_target_index() == _ids["b"], "still after Bravo")
	await sync_point("Charlie joined mid-chase", _all)

	step("Bravo disconnects while the plant is after him")
	var old_b: int = _ids["b"]
	var s_b := cmd(old_b, "leave_rejoin", {"delay": 2.0})
	await wait_until(func() -> bool: return not Net.players.has(old_b), 10.0, "Bravo gone from the registry")
	await wait_until(func() -> bool: return Game.world.get_player(old_b) == null, 5.0, "Bravo's Player despawned")
	await wait_until(func() -> bool: return is_instance_valid(h) and not h.is_dead() and h.get_target_index() != old_b, 3.0, "the plant let go of the worker who left")
	check(Hostiles.count() == 1, "still one plant")
	_freeze_hostiles(true)
	b.hostile_speed = speed0
	_place_hostile(h, Vector3(4.2, 0.0, 0.0))
	if not await wait_until(func() -> bool: return _peer_named("b") > 0 and _peer_named("b") != old_b, 20.0, "Bravo re-joined (new peer id)"):
		return
	_ids["b"] = _peer_named("b")
	await wait_until(func() -> bool: return _player("b") != null, 10.0, "the new Bravo's Player node exists")
	await await_ack(s_b, 25.0)
	r = await run_cmd(_ids["b"], "late_hostile", {}, 15.0)
	seen = r.get("hostiles", [])
	check(seen.size() == 1 and int(seen[0][0]) == h.id and Vector3(seen[0][3]).distance_to(h.global_position) <= POS_TOL, "the new Bravo sees the plant where it stands now %s" % [seen])
	for it in [can, can2]:
		if it != null and is_instance_valid(it):
			items.server_despawn_item(it)
	await _park_all()
	await sync_point("after the chase", _all)


# ---------------------------------------------------------------- (3) fire

func _case_fire() -> void:
	step("(3) fire")
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var items := Game.world.items
	var cabinet := station("EmergencyCabinet") as EmergencyCabinet
	var hs := Hostiles.get_hostiles()
	if not check(hs.size() == 1 and cabinet != null and not cabinet.broken, "one plant alive, the cabinet stocked"):
		return
	var h := hs[0] as HostilePlant
	var h_id := h.id
	var restock0 := b.cabinet_restock_sec
	var fuel0 := b.flamethrower_fuel_sec
	b.cabinet_restock_sec = 6.0
	b.flamethrower_fuel_sec = 20.0
	GameState.server_add_money(600)
	_place_hostile(h, Vector3(4.2, 0.0, 0.0)) # in front of GrowPlot 3: the tray is in its shadow
	check(plot(3).is_empty() and plot(3).server_plant(&"budget") and plot(3).server_water(1.0), "GrowPlot 3, behind it, holds a fresh crop that will not turn")
	await _clear_logs()

	step("Alpha breaks the glass with a plant alive: the deposit, no write-up")
	var money0 := GameState.money
	var r := await run_cmd(_ids["a"], "break_glass", {}, 25.0)
	check(bool(r.get("ok", false)), "Alpha: the flamethrower landed in his hands")
	var ft := items.get_held_by(_ids["a"]) as Flamethrower
	if not check(ft != null and is_equal_approx(ft.fuel, 20.0) and not ft.firing, "host: Alpha holds a full flamethrower"):
		return
	var ft_name := String(ft.name)
	check(cabinet.broken and cabinet.restock_left > 0, "host: cabinet broken, restock in %d s" % cabinet.restock_left)
	check(GameState.money == money0 - b.cabinet_deposit, "the deposit was taken and nothing else ($%d -> $%d)" % [money0, GameState.money])
	check(_count_written(_ids["a"], "") == 0 and GameState.get_write_ups(_ids["a"]) == 0, "a plant is alive: no misuse write-up")
	var logs := await _logs(_all)
	for k in _all:
		check(_rows(logs[k].get("glass", []), _ids["a"]) == 1, "%s: glass_broken(Alpha)" % NAMES[k])
		check(_rows(logs[k].get("purchases", []), b.cabinet_deposit, _ids["a"]) == 1, "%s: purchase_made(deposit, Alpha)" % NAMES[k])
	await sync_point("glass broken", _all)

	step("Alpha burns the plant down (the trigger held through the real input)")
	r = await run_cmd(_ids["a"], "goto", {"pos": Vector3(2.0, 0.05, 0.0), "aim": Vector3(4.2, 1.0, 0.0)})
	var s_fire := cmd(_ids["a"], "fire", {"on": true})
	await wait_until(func() -> bool: return ft.firing, 6.0, "host: firing on")
	await wait_until(func() -> bool: return h.is_dead(), b.hostile_burn_sec + 5.0, "the plant burnt down")
	check(_h_died.size() == 1 and int(_h_died[0][0]) == h_id and int(_h_died[0][1]) == _ids["a"], "host: hostile_died(id, Alpha) %s" % [_h_died])
	check(GameState.get_stat(_ids["a"], Const.STAT_BURNS) == 1, "STAT_BURNS 1 for Alpha")
	check(not plot(3).is_empty() and _count_written(_ids["a"], "") == 0, "GrowPlot 3 stood in the plant's shadow until it fell: untouched, no write-up")
	_freeze_hostiles(false) # the real tick removes the dead node
	await wait_until(func() -> bool: return plot(3).is_empty(), 5.0, "then GrowPlot 3, behind it, scorched")
	check(GameState.get_stat(_ids["a"], Const.STAT_SCORCHED) == 1 and _rows(_scorches, 3, _ids["a"]) == 1 and plot(3).is_scorched(), "STAT_SCORCHED 1, scorched(Alpha), ash on the soil")
	check(_count_written(_ids["a"], Const.WRITE_UP_ARSON) == 1 and GameState.get_write_ups(_ids["a"]) == 1, "nothing alive within 4 m any more: arson, strike 1")
	await wait_until(func() -> bool: return Hostiles.count() == 0, 4.0, "the dead plant is removed")
	await await_ack(s_fire)

	step("Bravo walks into the cone carrying a can")
	var can := items.server_spawn_item(CAN, {"charges": 1}, Vector3.ZERO, _ids["b"])
	cmd(_ids["b"], "goto", {"pos": Vector3(3.7, 0.05, 0.45), "look": Vector3(2.0, 0.05, 0.0)})
	await wait_until(func() -> bool: return _rows(_ignited, _ids["b"], _ids["a"]) >= 1, 6.0, "host: Bravo ignited by Alpha")
	check(_count_written(_ids["a"], Const.WRITE_UP_ARSON) == 2 and GameState.get_write_ups(_ids["a"]) == 2, "arson again, strike 2")
	check(can != null and can.holder_id == 0, "Bravo dropped the can")
	await wait_sec(1.2)
	check(_rows(_ignited, _ids["b"], _ids["a"]) == 1 and _count_written(_ids["a"], "") == 2, "1.2 s in the cone: ignited once, written up once")
	check(ft.firing and ft.holder_id == _ids["a"], "Alpha is still firing")

	step("Charlie walks in too: the third arson sends Alpha to the back room while he fires")
	_backroom_ev.clear()
	cmd(_ids["c"], "goto", {"pos": Vector3(3.7, 0.05, -0.45), "look": Vector3(2.0, 0.05, 0.0)})
	await wait_until(func() -> bool: return _rows(_ignited, _ids["c"], _ids["a"]) >= 1, 6.0, "host: Charlie ignited by Alpha")
	await wait_until(func() -> bool: return GameState.is_in_backroom(_ids["a"]), 3.0, "third strike: Alpha in the back room")
	check(GameState.get_write_ups(_ids["a"]) == 0 and _count_written(_ids["a"], Const.WRITE_UP_ARSON) == 3, "three arson write-ups, strikes cleared")
	# The rule (M13 review): the Boss keeps the flamethrower of a worker he sends to the back room. It is gone on
	# every peer, not waiting at the worker's spawn with its fuel.
	await wait_until(func() -> bool: return item_named(ft_name) == null and items_of(FLAME).is_empty(), 3.0, "host: the flame is out and the flamethrower is gone (the Boss keeps it)")
	var kept_toast := Events.TOAST_FLAMETHROWER_KEPT % NAMES["a"]
	var kept_line := Story.line("confiscated")
	check(toast_seen(kept_toast) and _barks.has(kept_line), "host: '%s' and the Boss says '%s'" % [kept_toast, kept_line])
	var spawn_a := room.get_spawn_transform(_player("a").spawn_index).origin
	r = await run_cmd(_ids["a"], "fire", {"on": false})
	await wait_sec(0.4)
	logs = await _logs(_all)
	var gone := await _reports_cmd(_all, "late_flame", {"count": 0})
	for k in _all:
		check((gone[k].get("flames", ["?"]) as Array).is_empty() and (gone[k].get("fx", {"?": true}) as Dictionary).is_empty(), "%s: no flamethrower left on his peer" % NAMES[k])
		check(_has_toast(logs[k].get("flame_toasts", []), kept_toast) and (logs[k].get("barks", []) as Array).has(kept_line), "%s: the toast and the Boss's line" % NAMES[k])
	for k in _all:
		var lg: Dictionary = logs[k]
		check(_rows(lg.get("died", []), h_id, _ids["a"]) == 1 and (lg.get("died", []) as Array).size() == 1, "%s: hostile_died(id, Alpha) once" % NAMES[k])
		check(_rows(lg.get("scorches", []), 3, _ids["a"]) == 1, "%s: GrowPlot 3 scorched by Alpha" % NAMES[k])
		var ign: Array = lg.get("ignited", [])
		check(ign.size() == 2 and _rows(ign, _ids["b"], _ids["a"]) == 1 and _rows(ign, _ids["c"], _ids["a"]) == 1, "%s: Bravo and Charlie ignited once each %s" % [NAMES[k], ign])
		var fire: Array = []
		for e in (lg.get("fire_ev", []) as Array):
			if String(e[0]) == ft_name:
				fire.append(bool(e[1]))
		check(not fire.is_empty() and fire[0] == true, "%s: saw the flame go on (it went out with the flamethrower) %s" % [NAMES[k], fire])
		var arson := 0
		var counts: Array = []
		for e in (lg.get("written", []) as Array):
			if int(e[0]) == _ids["a"] and String(e[1]) == Const.WRITE_UP_ARSON:
				arson += 1
				counts.append(int(e[2]))
		check(arson == 3 and counts == [1, 2, 0], "%s: three arson write-ups for Alpha, strikes 1, 2, back room %s" % [NAMES[k], counts])
	r = await run_cmd(_ids["a"], "backroom_check")
	check(bool(r.get("locked", false)) and bool(r.get("overlay", false)), "Alpha: UI lock + overlay")
	if can != null and is_instance_valid(can):
		items.server_despawn_item(can)
	await sync_point("after the fire", _all)

	step("the cabinet restocks; Bravo takes the next one with nothing on the floor: misuse")
	await wait_until(func() -> bool: return not cabinet.broken and cabinet.restock_left == 0, 10.0, "host: restocked")
	b.cabinet_restock_sec = restock0
	b.flamethrower_fuel_sec = fuel0
	logs = await _logs(_all)
	for k in _all:
		check(int(logs[k].get("restocked", 0)) == 1, "%s: restocked fired once" % NAMES[k])
	await _clear_logs()
	money0 = GameState.money
	r = await run_cmd(_ids["b"], "break_glass", {}, 25.0)
	var ft2 := items.get_held_by(_ids["b"]) as Flamethrower
	if not check(bool(r.get("ok", false)) and ft2 != null and String(ft2.name) != ft_name and is_equal_approx(ft2.fuel, fuel0), "Bravo holds a second flamethrower, %.0f s of fuel" % fuel0):
		return
	check(GameState.money == money0 - b.cabinet_deposit - b.write_up_fine, "deposit + fine taken")
	check(_count_written(_ids["b"], Const.WRITE_UP_MISUSE) == 1 and GameState.get_write_ups(_ids["b"]) == 1, "no plant alive: misuse of emergency equipment, strike 1 for Bravo")
	check(_has_toast(r.get("toasts", []), "written up"), "Bravo saw the write-up toast %s" % [r.get("toasts", [])])

	step("Bravo throws his while it fires: the flame goes out in the air")
	r = await run_cmd(_ids["b"], "goto", {"pos": PARK["b"], "look": Vector3(-3.0, 0.05, 3.5)})
	var s_b := cmd(_ids["b"], "fire", {"on": true})
	await wait_until(func() -> bool: return ft2.firing, 6.0, "host: Bravo fires")
	await await_ack(s_b)
	await wait_until(func() -> bool: return ft2.fuel < fuel0 - 0.25, 3.0, "the tank drains")
	r = await run_cmd(_ids["b"], "throw_now")
	await wait_until(func() -> bool: return not ft2.firing and ft2.holder_id == 0 and not ft2.is_flying(), 6.0, "host: thrown, the flame out, landed")
	check(ft2.fuel > 0.0 and ft2.fuel < fuel0 and room.get_bounds().grow(0.5).has_point(ft2.global_position), "it lies on the floor with %.1f s of fuel left" % ft2.fuel)
	r = await run_cmd(_ids["b"], "fire", {"on": false})
	logs = await _logs(_all)
	for k in _all:
		var fire2: Array = []
		for e in (logs[k].get("fire_ev", []) as Array):
			if String(e[0]) == String(ft2.name):
				fire2.append(bool(e[1]))
		check(fire2 == [true, false], "%s: Bravo's flame went on, then off %s" % [NAMES[k], fire2])
	await sync_point("a thrown flamethrower", _all)

	step("Bravo picks it up, fires again and drops out of the session: the flame goes out, the flamethrower stays")
	r = await run_cmd(_ids["b"], "pickup", {"item": String(ft2.name)})
	check(bool(r.get("ok", false)) and ft2.holder_id == _ids["b"], "Bravo picks it up again")
	s_b = cmd(_ids["b"], "fire", {"on": true})
	await wait_until(func() -> bool: return ft2.firing, 6.0, "host: Bravo fires again")
	await await_ack(s_b)
	var old_b: int = _ids["b"]
	var stood := _player("b").global_position
	var s_rj := cmd(old_b, "leave_rejoin", {"delay": 1.0})
	await wait_until(func() -> bool: return not Net.players.has(old_b), 10.0, "Bravo left while firing")
	await wait_until(func() -> bool: return is_instance_valid(ft2) and not ft2.firing and ft2.holder_id == 0, 3.0, "host: the flame is out, nobody holds it")
	check(items_of(FLAME).size() == 1 and ft2.rest_position.distance_to(stood) < 2.0, "it lies where he stood (%s, he was at %s)" % [ft2.rest_position, stood])
	await wait_sec(0.3)
	logs = await _logs(["a", "c"])
	for k in ["a", "c"]:
		var fire2: Array = []
		for e in (logs[k].get("fire_ev", []) as Array):
			if String(e[0]) == String(ft2.name):
				fire2.append(bool(e[1]))
		check(fire2 == [true, false, true, false], "%s: on, off (thrown), on, off (he left) %s" % [NAMES[k], fire2])
	if not await wait_until(func() -> bool: return _peer_named("b") > 0 and _peer_named("b") != old_b, 20.0, "Bravo re-joined (new peer id)"):
		return
	_ids["b"] = _peer_named("b")
	await wait_until(func() -> bool: return _player("b") != null, 10.0, "the new Bravo's Player node exists")
	await await_ack(s_rj, 25.0)
	r = await run_cmd(_ids["b"], "fire", {"on": false}) # the trigger he was still holding when he left
	await sync_point("after Bravo dropped out mid-fire", _all)
	r = await run_cmd(_ids["b"], "pickup", {"item": String(ft2.name)})
	check(bool(r.get("ok", false)) and ft2.holder_id == _ids["b"] and not ft2.firing, "the new Bravo picks it up; it stays off")

	step("Alpha is let out and needs the cabinet again (misuse); both fire at once, Charlie joins mid-fire, both tanks run dry")
	GameState.server_release_from_backroom(_ids["a"])
	await wait_until(func() -> bool: return not _at_a_backroom_slot(_player("a")) and _player("a").global_position.distance_to(spawn_a) < 1.0, 5.0, "Alpha back at his spawn")
	check(items_of(FLAME).size() == 1 and item_named(ft_name) == null, "nothing waits for him there: Bravo's is the only flamethrower")
	cabinet.server_restock() # the ninety seconds, skipped
	await wait_frames(2)
	r = await run_cmd(_ids["a"], "break_glass", {}, 25.0)
	ft = items.get_held_by(_ids["a"]) as Flamethrower
	if not check(bool(r.get("ok", false)) and ft != null and ft != ft2, "Alpha holds a new flamethrower"):
		return
	check(_count_written(_ids["a"], Const.WRITE_UP_MISUSE) == 1 and GameState.get_write_ups(_ids["a"]) == 1, "nothing on the floor: misuse, strike 1 for Alpha")
	var s1 := cmd(_ids["a"], "goto", {"pos": PARK["a"], "look": Vector3(-3.0, 0.05, 2.0)})
	var s2 := cmd(_ids["b"], "goto", {"pos": PARK["b"], "look": Vector3(-3.0, 0.05, 3.5)})
	var s3 := cmd(_ids["c"], "goto", {"pos": PARK["c"]})
	await await_ack(s1)
	await await_ack(s2)
	await await_ack(s3)
	await _clear_logs()
	ft.server_set_fuel(7.0)
	ft2.server_set_fuel(8.0)
	await wait_sec(0.3)
	var strikes0 := _written.size()
	# Charlie drops out and comes back while both flames are on: a late joiner must see them burning.
	var old_c: int = _ids["c"]
	var s_c := cmd(old_c, "leave_rejoin", {"delay": 0.5})
	s1 = cmd(_ids["a"], "fire", {"on": true})
	s2 = cmd(_ids["b"], "fire", {"on": true})
	await wait_until(func() -> bool: return ft.firing and ft2.firing, 6.0, "host: both fire at once")
	if not await wait_until(func() -> bool: return _peer_named("c") > 0 and _peer_named("c") != old_c, 20.0, "Charlie left and re-joined mid-fire"):
		return
	_ids["c"] = _peer_named("c")
	await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists")
	check(ft.firing and ft2.firing, "both were still firing when he arrived (%.1f s and %.1f s left)" % [ft.fuel, ft2.fuel])
	await await_ack(s_c, 25.0)
	r = await run_cmd(_ids["c"], "late_flame", {"count": 2}, 15.0)
	var late: Array = r.get("flames", [])
	var late_ok := late.size() == 2
	for e in late:
		var it := item_named(String(e[0])) as Flamethrower
		late_ok = late_ok and it != null and bool(e[2]) and int(e[3]) == it.holder_id and bool((r.get("fx", {}) as Dictionary).get(String(e[0]), false))
	check(late_ok, "Charlie (late): two flamethrowers, both firing in their holders' hands, the flame drawn %s %s" % [late, r.get("fx", {})])
	check(bool(r.get("broken", false)) and int(r.get("restock", 0)) > 0, "Charlie (late): the cabinet is broken and counting down on his peer too (%d s)" % int(r.get("restock", 0)))
	r = await run_cmd(_ids["c"], "goto", {"pos": PARK["c"]})
	await wait_until(func() -> bool: return not ft.firing and not ft2.firing and ft.fuel == 0.0 and ft2.fuel == 0.0, 12.0, "host: both ran dry and stopped")
	check(ft.is_empty() and ft.get_status_text() == Flamethrower.STATUS_EMPTY and ft.holder_id == _ids["a"] and ft2.holder_id == _ids["b"], "both empty, both still carried")
	check(_written.size() == strikes0, "nobody was written up for it")
	await await_ack(s1)
	await await_ack(s2)
	await wait_sec(0.3)
	logs = await _logs(_all)
	for k in _all:
		var fl: Dictionary = logs[k].get("fuel_log", {})
		for item in [ft, ft2]:
			var n := String(item.name)
			var seq: Array = fl.get(n, [])
			var host_seq: Array = _fuel_log.get(n, [])
			var ok := seq.size() >= 3 and is_zero_approx(float(seq.back()))
			# From the refill (the highest value seen) on, it only ever goes down.
			var top := 0
			for i in seq.size():
				if float(seq[i]) > float(seq[top]):
					top = i
			for i in range(top + 1, seq.size()):
				ok = ok and float(seq[i]) < float(seq[i - 1])
			for v in seq:
				ok = ok and _has_value(host_seq, float(v))
			check(ok, "%s: %s drained in the host's steps down to 0 (%d of %d steps seen)" % [NAMES[k], n, seq.size(), host_seq.size()])
	step("a trigger pulled on an empty tank is refused by the server")
	r = await run_cmd(_ids["a"], "fire_raw", {"on": true})
	check(not ft.firing and not bool(r.get("firing", true)), "empty: still off on the host and on Alpha")
	s1 = cmd(_ids["a"], "fire", {"on": false})
	s2 = cmd(_ids["b"], "fire", {"on": false})
	await await_ack(s1)
	await await_ack(s2)
	await sync_point("both tanks dry", _all)
	s1 = cmd(_ids["a"], "drop")
	s2 = cmd(_ids["b"], "drop")
	await await_ack(s1)
	await await_ack(s2)
	check(ft.holder_id == 0 and ft2.holder_id == 0, "both put down (an empty flamethrower is still an item)")
	await sync_point("after the flamethrowers", _all)


# ---------------------------------------------------------------- (4) events on top

func _case_events() -> void:
	step("(4a) a head count with a plant standing on the Boss's way to the line")
	var b: BalanceConfig = Config.balance
	var room: Room = Game.world.room
	var items := Game.world.items
	var boss := _boss()
	_freeze_hostiles(true)
	var id := Hostiles.server_spawn(SPARE_STRAIN, Vector3(-2.2, 0.0, -3.6))
	var h2 := Hostiles.get_hostile(id) as HostilePlant
	if not check(h2 != null and boss != null, "a %s plant on the head-count route" % SPARE_STRAIN):
		return
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.05)
	_place_hostile(h2, Vector3(-2.2, 0.0, -3.6))
	check(GameState.server_send_to_backroom(_ids["c"], 30.0), "Charlie sits in the back room (excused)")
	var s1 := cmd(_ids["a"], "goto", {"pos": Vector3(-0.8, 0.05, -2.2), "look": Vector3(0.0, 0.05, -5.0)})
	var s2 := cmd(_ids["b"], "goto", {"pos": PARK["b"]})
	_put_me(Vector3(0.8, 0.05, -2.2), Vector3(0.0, 0.05, -5.0))
	await await_ack(s1)
	await await_ack(s2)
	await _clear_logs()
	var hc0 := b.headcount_sec
	var strikes_b := GameState.get_write_ups(_ids["b"])
	b.headcount_sec = 6.0
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count started")
	check(boss.is_walking(), "host: the Boss sets off")
	await wait_sec(1.5) # he walks through the plant on every peer
	var reps := await _reports(_all)
	for k in _all:
		check(String(reps[k].get("active", "")) == String(Events.EVENT_HEADCOUNT) and String(reps[k].get("banner", "")).begins_with(HUD.TEXT_EVENT_HEADCOUNT), "%s: head count active, banner up" % NAMES[k])
	Events.tick(b.headcount_sec)
	await wait_frames(2)
	b.headcount_sec = hc0
	check(not Events.is_event_active(), "host: the count is over")
	check(_count_written(_ids["b"], Const.WRITE_UP_ABSENT) == 1 and _written.size() == 1, "Bravo (absent) is the only one written up %s" % [_written])
	check(GameState.get_write_ups(_ids["b"]) == strikes_b + 1, "one more strike for Bravo (%d)" % (strikes_b + 1))
	await wait_sec(0.3)
	var logs := await _logs(_all)
	for k in _all:
		var wr: Array = logs[k].get("written", [])
		check(wr.size() == 1 and int(wr[0][0]) == _ids["b"] and String(wr[0][1]) == Const.WRITE_UP_ABSENT and int(wr[0][2]) == strikes_b + 1, "%s: worker_written_up(Bravo, absent, %d) and nothing else %s" % [NAMES[k], strikes_b + 1, wr])
		check(str(logs[k].get("ev_started", [])) == str(["headcount"]) and str(logs[k].get("ev_ended", [])) == str(["headcount"]), "%s: the event came and went" % NAMES[k])
	GameState.server_release_from_backroom(_ids["c"])
	await wait_until(func() -> bool: return not _at_a_backroom_slot(_player("c")), 5.0, "Charlie released")
	await _park_all()
	await sync_point("after the head count", _all)

	step("(4b) water off while a tray dries and the plant eats another")
	var p1 := plot(1)
	var p2 := plot(2)
	check(p1.server_plant(&"budget") and p2.server_plant(&"budget") and p2.server_water(1.0), "GrowPlot 1 and 2 planted")
	p1.water = b.dry_threshold + 0.02 # a second from dry
	p1.stage_progress = 0.9
	p2.stage_progress = 0.5
	var can := items.server_spawn_item(CAN, {"charges": 0}, Vector3.ZERO, _ids["a"])
	await _clear_logs()
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off started")
	var r := await run_cmd(_ids["a"], "well_try", {})
	check(String(r.get("prompt", "")) == Well.PROMPT_NO_PRESSURE and not bool(r.get("can", true)) and not bool(r.get("pressure", true)), "Alpha at the tank: 'No pressure' (%s)" % r.get("prompt", ""))
	check(_has_toast(r.get("toasts", []), Well.PROMPT_NO_PRESSURE) and int(r.get("charges", -1)) == 0, "the host refused his refill; the can stays empty %s" % [r.get("toasts", [])])
	_place_hostile(h2, Vector3(7.6, 0.0, -1.0))
	for i in 40:
		Hostiles.tick(0.1)
		if h2.state == HostilePlant.State.EAT:
			break
	check(h2.state == HostilePlant.State.EAT and h2.get_target_index() == 2 and _rows(_h_eating, id, 2) == 1, "host: the plant walked to GrowPlot 2 and eats")
	await wait_sec(0.3)
	for i in 40:
		Hostiles.tick(0.25)
		if not _h_ate.is_empty():
			break
	check(_rows(_h_ate, id, 2) == 1 and p2.is_empty(), "host: GrowPlot 2 eaten to nothing")
	await wait_until(func() -> bool: return p1.needs_water(), 3.0, "GrowPlot 1 went dry meanwhile, and there is no water to be had")
	await wait_sec(0.3)
	logs = await _logs(_all)
	reps = await _reports(_all)
	for k in _all:
		check(_rows(logs[k].get("eating", []), id, 2) == 1 and _rows(logs[k].get("ate", []), id, 2) == 1, "%s: hostile_eating + hostile_ate for GrowPlot 2" % NAMES[k])
		check(str(logs[k].get("pressure_ev", [])) == str([[false]]) and String(reps[k].get("banner", "")).begins_with(HUD.TEXT_EVENT_WATER_OFF), "%s: pressure off, banner WATER OFF" % NAMES[k])
	await sync_point("water off", _all)
	await _case_forged(id)
	Events.tick(b.water_off_sec)
	await wait_frames(2)
	check(not Events.is_event_active() and (station("Well") as Well).has_pressure(), "host: the water is back")
	r = await run_cmd(_ids["a"], "well_try", {"expect_full": true})
	check(can != null and can.charges == GameState.get_can_capacity() and bool(r.get("pressure", false)), "Alpha fills the can now (%d charges)" % (can.charges if can != null else -1))
	if can != null:
		items.server_despawn_item(can)

	step("(4c) a shortage on top, the plant still at the trays")
	check(Events.server_start_event(Events.EVENT_SHORTAGE), "shortage started")
	var counter := station("ShopCounter") as ShopCounter
	check(counter.get_shortage_strain() == MUT_STRAIN, "the strain planted most this shift is short: %s" % counter.get_shortage_strain())
	r = await run_cmd(_ids["b"], "buy_try", {"seed": String(MUT_STRAIN)})
	check(not bool(r.get("held", true)) and _has_toast(r.get("toasts", []), "Out of stock"), "Bravo is refused the short strain %s" % [r.get("toasts", [])])
	r = await run_cmd(_ids["b"], "buy_try", {"seed": "budget"})
	var packet := items.get_held_by(_ids["b"])
	check(bool(r.get("held", false)) and packet is SeedPacket, "another strain still sells")
	for i in 40:
		Hostiles.tick(0.1)
		if h2.state == HostilePlant.State.EAT:
			break
	check(h2.state == HostilePlant.State.EAT and h2.get_target_index() == 1, "meanwhile the plant moved on to GrowPlot 1")
	await sync_point("shortage", _all)
	Events.tick(b.shortage_sec)
	await wait_frames(2)
	check(not Events.is_event_active() and counter.get_shortage_strain() == &"", "host: shortage over")
	if packet != null:
		items.server_despawn_item(packet)

	step("(4d) a power cut with the plant alive: nothing grows, the plant eats in the dark")
	check(p2.server_plant(&"budget") and p2.server_water(1.0), "GrowPlot 2 replanted")
	Config.growth_speed_override = 5.0
	await wait_sec(0.4)
	check(p2.stage_progress > 0.0, "it grows (%.3f)" % p2.stage_progress)
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "power cut started")
	var grow0 := p2.stage_progress
	var eat0 := p1.stage_progress
	await wait_sec(0.5)
	Hostiles.tick(1.0)
	check(p2.stage_progress == grow0, "growth frozen while the power is off")
	check(p1.stage_progress < eat0 - 0.05, "the plant kept eating GrowPlot 1 (%.2f -> %.2f)" % [eat0, p1.stage_progress])
	reps = await _reports(_all)
	for k in _all:
		check(not bool(reps[k].get("power", true)) and not bool(reps[k].get("room_power", true)) and bool(reps[k].get("fuse_tripped", false)), "%s: dark, breaker tripped" % NAMES[k])
	await sync_point("power cut", _all)
	r = await run_cmd(_ids["a"], "fuse_reset", {}, 25.0)
	check(bool(r.get("power", false)) and Events.is_power_on() and not Events.is_event_active(), "Alpha's reset restored the power (%d attempt(s))" % int(r.get("attempts", 0)))
	Config.growth_speed_override = 0.0

	step("(4e) an inspection with two plants on the floor")
	var id3 := Hostiles.server_spawn(SPARE_STRAIN, Vector3(6.0, 0.0, 4.0))
	var h3 := Hostiles.get_hostile(id3) as HostilePlant
	if not check(h3 != null and Hostiles.count() == 2, "a second plant"):
		return
	await _park_all()
	await _clear_logs()
	check(Events.server_start_event(Events.EVENT_INSPECTION), "inspection started")
	var speed := float(Events.get_event_params().get("speed", 1.6))
	# Freeze the host's Boss 6 s into the route: deterministic sight checks (clients keep walking him for real).
	boss.walk_route(room.get_inspection_route(), speed, 6.0)
	boss.set_process(false)
	await wait_frames(2)
	var eye := boss.get_eye_position()
	var facing := boss.get_facing()
	var floor_eye := Vector3(eye.x, 0.05, eye.z)
	var side := facing.cross(Vector3.UP).normalized()
	print("  (Boss frozen at %s facing %s)" % [floor_eye, facing])
	# One plant 2.2 m in front of him, Charlie 1.3 m behind it; the host and Alpha in the open on either side.
	_place_hostile(h2, floor_eye + facing * 2.2)
	var alpha_spot := floor_eye + facing * 3.0 - side * 2.0
	s1 = cmd(_ids["c"], "goto", {"pos": floor_eye + facing * 3.5, "look": floor_eye})
	s2 = cmd(_ids["a"], "goto", {"pos": alpha_spot, "look": floor_eye})
	_put_me(floor_eye + facing * 3.0 + side * 2.0, floor_eye)
	await await_ack(s1)
	await await_ack(s2)
	await wait_sec(0.3)
	# The loiter clocks start now for everybody (whatever the real-time passes anchored while they walked up).
	Events._seen_since.clear()
	Events._sight_accum = 0.0
	_written.clear()
	Events.tick(2.0)
	check(_written.is_empty(), "two seconds in his sight: nobody written up yet")
	# The other plant bites Alpha where he stands. shove_impulse 0 on the host stands in for a worker pinned in a
	# corner: the bite stuns him and does not move him.
	var impulse0 := b.shove_impulse
	b.shove_impulse = 0.0
	_place_hostile(h3, alpha_spot + facing * 1.5)
	var bites0 := _h_bit.size()
	for i in 20:
		h3.host_step(0.05)
		if _h_bit.size() > bites0:
			break
	b.shove_impulse = impulse0
	check(_rows(_h_bit, id3, _ids["a"]) == 1 and _player("a").is_stunned(), "the second plant bit Alpha: stunned where he stands")
	# 4.1 s in all: sight passes every 0.5 s, the first one anchors, so the pass 3.5 s after it is past loiter_sec by
	# a clear half second (3.0 s after it sits on a float boundary).
	Events.tick(2.1)
	# Decided (M13 QA): a worker who cannot move is not loitering; his three seconds start when the stun ends.
	check(_count_written(_ids["a"], "") == 0, "Alpha, 4.1 s in sight but bitten and unable to move for the last of it, is not written up %s" % [_written])
	check(_count_written(1, Const.WRITE_UP_LOITERING) == 1, "the host, standing in the open just as long, is written up for loitering (the sight pass ran)")
	check(_count_written(_ids["c"], "") == 0, "Charlie, behind the plant, was never seen: it blocks the Boss's view like a crate")
	_put_me(PARK["host"], Vector3(0.0, 0.05, 0.0))
	await wait_until(func() -> bool: return not _player("a").is_stunned(), 3.0, "Alpha's stun ends")
	Events.tick(b.loiter_sec + 0.6)
	check(_count_written(_ids["a"], Const.WRITE_UP_LOITERING) == 1, "three more seconds without moving, able to: now Alpha is written up")
	check(_count_written(_ids["c"], "") == 0 and _count_written(1, "") == 1, "Charlie still unseen, the host still on one write-up")
	boss.set_process(true)
	Events.server_end_event()
	await wait_frames(2)
	check(not Events.is_event_active(), "host: inspection over")
	await wait_sec(0.3)
	logs = await _logs(_all)
	for k in _all:
		var wr: Array = logs[k].get("written", [])
		check(wr.size() == 2 and _rows(wr, 1, Const.WRITE_UP_LOITERING) == 1 and _rows(wr, _ids["a"], Const.WRITE_UP_LOITERING) == 1, "%s: the same two write-ups %s" % [NAMES[k], wr])
		check(_rows(logs[k].get("bit", []), id3, _ids["a"]) == 1, "%s: hostile_bit(Alpha)" % NAMES[k])
	await _park_all()
	await sync_point("after the events", _all)


## Forged / misdirected M12 requests from Charlie while the water is off: the engine rejects the authority-only ones
## on the host (announced), the validated ones change nothing, no other error line.
func _case_forged(hostile_id: int) -> void:
	step("(4b') forged M12 requests from Charlie")
	var before := _m12_state()
	var canon := canonical_state()
	var ignited0 := _ignited.size()
	var loose := ""
	for it in items_of(FLAME):
		if it.holder_id == 0:
			loose = String(it.name)
	for s in ["RPC '_rpc_spawn' is not allowed on node /root/Hostiles", "RPC '_rpc_despawn_all' is not allowed on node /root/Hostiles",
			"RPC '_rpc_died' is not allowed on node /root/Hostiles", "RPC '_rpc_set_pressure' is not allowed on node",
			"RPC '_rpc_set_shortage' is not allowed on node", "RPC '_rpc_glass_break' is not allowed on node",
			"RPC '_rpc_scorched' is not allowed on node"]:
		expect_error(s)
	var r := await run_cmd(_ids["c"], "forged_m12", {"victim": _ids["a"], "hostile": hostile_id, "flame": loose}, 20.0)
	await wait_until(func() -> bool: return expected_errors_seen(), 5.0, "the engine rejected every authority-only M12 RPC")
	var diff := _m12_diff(before, _m12_state(), 0.01)
	check(diff == "" and canonical_state() == canon, "nothing changed on the host %s" % diff)
	check(_ignited.size() == ignited0 and int(r.get("local_ignites", -1)) == 0, "the forged ignite ran nowhere, not even on Charlie's own screen")
	check(_has_toast(r.get("toasts", []), "Too far"), "breaking the glass from across the room got 'Too far.' %s" % [r.get("toasts", [])])
	check(not bool(r.get("pressure", true)) and int(r.get("hostiles", -1)) == Hostiles.count(), "Charlie's own copy is untouched too")
	await sync_point("after the forged requests", _all)


# ---------------------------------------------------------------- (5a) the shift fails under everything, RETRY

func _case_churn_retry() -> void:
	step("(5a) the shift fails with plants, flamethrowers, a broken cabinet, a running event and a turning tray")
	var b: BalanceConfig = Config.balance
	var items := Game.world.items
	var cabinet := station("EmergencyCabinet") as EmergencyCabinet
	var well := station("Well") as Well
	var sdef: SeedDef = b.get_seed(MUT_STRAIN)
	check(Hostiles.count() == 2 and items_of(FLAME).size() == 2, "two plants alive, two empty flamethrowers on the floor")
	check(cabinet.broken and cabinet.restock_left > 0, "the cabinet is still empty after Bravo (restock in %d s)" % cabinet.restock_left)
	cabinet.server_restock() # the long wait, skipped
	await wait_frames(2)

	step("Alpha and Charlie reach for the glass in the same frame: one flamethrower, one deposit")
	var flat := Vector3(cabinet.global_position.x, 0.05, cabinet.global_position.z)
	var s1 := cmd(_ids["a"], "goto", {"pos": Vector3(-8.8, 0.05, -2.0), "look": flat})
	var s2 := cmd(_ids["c"], "goto", {"pos": Vector3(-8.8, 0.05, -3.0), "look": flat})
	await await_ack(s1)
	await await_ack(s2)
	var money0 := GameState.money
	var strikes0 := _written.size()
	s1 = cmd(_ids["a"], "break_now")
	s2 = cmd(_ids["c"], "break_now")
	var r1 := await await_ack(s1)
	var r2 := await await_ack(s2)
	var wk := "a" if bool(r1.get("held", false)) else "c"
	var loser: Dictionary = r2 if wk == "a" else r1
	check(bool(r1.get("held", false)) != bool(r2.get("held", false)) and items_of(FLAME).size() == 3, "exactly one of them got it (%s)" % NAMES[wk])
	check(GameState.money == money0 - b.cabinet_deposit, "one deposit taken ($%d -> $%d)" % [money0, GameState.money])
	check(_has_toast(loser.get("toasts", []), "Restocking"), "the other was told it is restocking %s" % [loser.get("toasts", [])])
	var ft3 := items.get_held_by(_ids[wk]) as Flamethrower
	check(ft3 != null and cabinet.broken and cabinet.restock_left > 30, "%s holds a third flamethrower; the cabinet restocks in %d s" % [NAMES[wk], cabinet.restock_left])
	check(_written.size() == strikes0, "plants alive: no misuse write-up")
	var r := await run_cmd(_ids[wk], "goto", {"pos": PARK[wk], "look": Vector3(-3.0, 0.05, PARK[wk].z)})
	r = await run_cmd(_ids["c" if wk == "a" else "a"], "goto", {"pos": PARK["c" if wk == "a" else "a"]})
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off running")
	check(GameState.server_send_to_backroom(_ids["b"], 25.0), "Bravo in the back room")
	var chance0 := sdef.mutation_chance
	sdef.mutation_chance = 1.0
	check(plot(4).is_empty() and plot(4).server_plant(MUT_STRAIN) and plot(4).server_water(1.0), "GrowPlot 4 replanted with %s" % MUT_STRAIN)
	plot(4).stage = GrowPlot.Stage.READY
	check(plot(4).server_roll_mutation() and plot(4).is_turning(), "GrowPlot 4 starts to turn")
	sdef.mutation_chance = chance0
	await sync_point("before the shift fails", _all)
	var s_fire := cmd(_ids[wk], "fire", {"on": true})
	await wait_until(func() -> bool: return ft3 != null and ft3.firing, 6.0, "%s fires at nothing" % NAMES[wk])
	await await_ack(s_fire)
	_freeze_hostiles(false) # the real tick from here on: the plants roam, the tray counts down
	await wait_sec(0.4)
	check(Hostiles.count() == 2 and Hostiles.is_any_alive() and ft3.firing and plot(4).is_turning(), "all of it is live when the timer runs out")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "ROUND_FAILED on the host")
	await wait_frames(3)
	check(Hostiles.count() == 0, "shift end: no plants")
	await wait_until(func() -> bool: return ft3 != null and not ft3.firing, 3.0, "shift end: the flame is out")
	check(not Events.is_event_active() and Events.is_power_on() and well.has_pressure(), "shift end: no event, the water back")
	check(GameState.backroom.is_empty(), "shift end: everyone out of the back room")
	check(items_of(FLAME).size() == 3 and cabinet.broken, "the flamethrowers and the broken cabinet stay for the report")
	await sync_point("shift failed", _all, true)
	r = await run_cmd(_ids[wk], "fire", {"on": false})
	GameState.request_retry()
	await wait_frames(8)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == b.starting_money, "RETRY: WAITING, shift 1, $%d" % b.starting_money)
	check(GameState.stats.is_empty() and GameState.backroom.is_empty() and GameState.write_ups.is_empty(), "RETRY: ledger, back room, strikes cleared")
	check(items_of(FLAME).is_empty(), "RETRY: no flamethrower left anywhere")
	check(not cabinet.broken and cabinet.restock_left == 0, "RETRY: the cabinet is stocked")
	await wait_until(func() -> bool:
		for i in range(1, 7):
			if not plot(i).is_empty() or plot(i).turning:
				return false
		return true, 3.0, "RETRY: every tray empty, none turning")
	print("  (trays: %s)" % _plot_sig())
	check(Hostiles.count() == 0 and well.has_pressure() and (station("ShopCounter") as ShopCounter).get_shortage_strain() == &"", "RETRY: no plants, water on, nothing short")
	await wait_until(func() -> bool: return items_of(CAN).size() == b.starting_watering_cans and _none_flying(), 3.0, "RETRY: the cans are back at the well")
	check(items_of(PRODUCT).is_empty() and items_of(Const.ITEM_SEED_PACKET).is_empty(), "RETRY: no bundles, no packets")
	var reps := await _reports(_all)
	for k in _all:
		check(not bool(reps[k].get("locked", true)) and not bool(reps[k].get("round_end", true)) and String(reps[k].get("active", "?")) == "", "%s: no lock, no round-end overlay, no event" % NAMES[k])
	await sync_point("after RETRY", _all, true)


# ---------------------------------------------------------------- (5b) back to the menu, a fresh host on the same port

func _case_fresh_host() -> void:
	step("(5b) the host goes back to the menu and hosts again on the same port")
	var b: BalanceConfig = Config.balance
	var seqs := {}
	for k in _all:
		seqs[k] = cmd(_ids[k], "host_restart", {"delay": 2.5})
	await wait_sec(0.5)
	Game.return_to_menu()
	await wait_frames(3)
	check_menu_clean("host: after leaving")
	check(Hostiles.count() == 0 and not Events.is_event_active() and Events.is_power_on(), "host: nothing left of the session")
	await wait_sec(0.8)
	if not check(Game.start_host(NAMES["host"], port) == OK, "host again on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(CAN).size() == b.starting_watering_cans, 10.0, "fresh world, cans at the well")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("b") > 0 and _peer_named("c") > 0, 30.0, "all three joined the fresh host"):
		return
	for k in _all:
		_ids[k] = _peer_named(k)
	await wait_until(func() -> bool: return _player("a") != null and _player("b") != null and _player("c") != null, 10.0, "their Player nodes exist")
	for k in _all:
		var r := await await_ack(seqs[k], 30.0)
		check(bool(r.get("ok", false)), "%s: menu clean after the host left, joined again" % NAMES[k])
	var cabinet := station("EmergencyCabinet") as EmergencyCabinet
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.money == b.starting_money, "fresh session: WAITING, shift 1, $%d" % b.starting_money)
	check(Hostiles.count() == 0 and items_of(FLAME).is_empty() and cabinet != null and not cabinet.broken, "fresh session: no plants, no flamethrowers, the cabinet stocked")
	await sync_point("fresh host", _all, true)


# ---------------------------------------------------------------- (5c) a short shift with everything on

func _case_short_shift() -> void:
	step("(5c) a 30 s shift: scheduler on, mutation chances raised, three bots, the host breaks the glass")
	var b: BalanceConfig = Config.balance
	var saved := {"len": b.round_length_sec, "quota": b.base_quota, "insp": b.inspection_sec, "cut": b.power_cut_max_sec,
			"hc": b.headcount_sec, "water": b.water_off_sec, "short": b.shortage_sec, "warn": b.mutation_warning_sec, "max": b.hostile_max}
	var chances := {}
	for s in b.seeds:
		chances[s.id] = s.mutation_chance
		s.mutation_chance = 1.0 if s.id == MUT_STRAIN else 0.6
	b.round_length_sec = 30.0
	b.base_quota = 5000 # out of reach: the shift runs its full length under the timer
	b.inspection_sec = 6.0
	b.power_cut_max_sec = 4.0
	b.headcount_sec = 5.0
	b.water_off_sec = 5.0
	b.shortage_sec = 5.0
	b.mutation_warning_sec = 0.3 # the bots harvest within half a second: shorter than that, or nothing ever uproots
	b.hostile_max = 3
	b.event_gap_min_sec = 2.0
	b.event_gap_max_sec = 3.0
	Config.user_args["event-delay"] = "3"
	Config.growth_speed_override = 30.0
	_freeze_hostiles(false)
	GameState.server_add_money(500)
	await _clear_logs()
	GameState.request_start_round()
	check(GameState.is_playing() and absf(GameState.time_left - 30.0) < 1.0, "30 s shift running (payment due $%d)" % GameState.quota)
	check(absf(Events.get_next_event_in() - 3.0) < 0.5, "first event in %.1f s" % Events.get_next_event_in())
	var shift_t0 := Time.get_ticks_msec()
	Events.event_started.connect(func(k: StringName, _p: Dictionary) -> void: print("  (event %s at %.1f s)" % [k, float(Time.get_ticks_msec() - shift_t0) / 1000.0]))
	Hostiles.hostile_spawned.connect(func(id: int, s: StringName, _p: Vector3) -> void: print("  (plant %d, %s, at %.1f s)" % [id, s, float(Time.get_ticks_msec() - shift_t0) / 1000.0]))
	var seqs := {}
	var plots := {"a": 1, "b": 2, "c": 3}
	for k in _all:
		seqs[k] = cmd(_ids[k], "work_loop", {"plot": plots[k], "max_sec": 10.0 if k == "c" else 45.0})
	_host_trouble()
	# Charlie works ten seconds, drops out, and joins again in the middle of whatever is going on by then.
	var first := await await_ack(seqs["c"], 20.0)
	print("  (Charlie, first ten seconds: %s)" % [first])
	var old_c: int = _ids["c"]
	var s_c := cmd(old_c, "leave_rejoin", {"delay": 1.0})
	if await wait_until(func() -> bool: return _peer_named("c") > 0 and _peer_named("c") != old_c, 20.0, "Charlie left and re-joined mid-shift"):
		_ids["c"] = _peer_named("c")
		await wait_until(func() -> bool: return _player("c") != null, 10.0, "Charlie's Player node exists")
		await await_ack(s_c, 25.0)
		print("  (he walked into: %d plant(s), event '%s', %d flamethrower(s), cabinet %s)" % [Hostiles.count(), Events.active_event, items_of(FLAME).size(), "broken" if (station("EmergencyCabinet") as EmergencyCabinet).broken else "stocked"])
		if GameState.is_playing():
			await m12_checkpoint("Charlie joined mid-shift", ["c"], 1.5, 8.0)
		seqs["c"] = cmd(_ids["c"], "work_loop", {"plot": plots["c"], "max_sec": 45.0})
	await wait_until(func() -> bool: return GameState.is_round_over(), 45.0, "the shift ended (%s)" % GameState.get_phase_name())
	var acked := 0
	for k in _all:
		var r := await await_ack(seqs[k], 15.0)
		if not r.is_empty():
			acked += 1
			print("  (%s: %s)" % [NAMES[k], r])
	check(acked == 3, "every bot reported back")
	print("  (host: %s)" % [_trouble])
	var kinds := []
	for e in _ev_started:
		kinds.append(String(e[0]))
	check(_ev_started.size() >= 2, "the scheduler fired %d events %s" % [_ev_started.size(), kinds])
	check(_h_spawned.size() >= 1, "%d plant(s) uprooted during the shift" % _h_spawned.size())
	check(_stat_total(Const.STAT_PLANTED) >= 2, "the team planted %d time(s)" % _stat_total(Const.STAT_PLANTED))
	check(Hostiles.count() == 0 and not Events.is_event_active() and Events.is_power_on() and GameState.backroom.is_empty(), "shift end: no plants, no event, power on, back room empty")
	var burning := false
	for it in items_of(FLAME):
		burning = burning or (it as Flamethrower).firing
	check(not burning and (station("Well") as Well).has_pressure() and (station("ShopCounter") as ShopCounter).get_shortage_strain() == &"", "shift end: no flame, water on, nothing short")
	await wait_sec(0.6)
	var hud := _hud()
	var rows := hud.round_end.report.get_row_peers()
	check(hud.round_end.visible and rows == Story.get_report_peers(), "host: shift report rows %s" % [rows])
	for k in _all:
		var r := await run_cmd(_ids[k], "report_end")
		check(String(r.get("stats", "?")) == _stats_sig(), "%s: GameState.stats identical to the host" % NAMES[k])
		var crow: Array = r.get("rows", [])
		var same_rows := crow.size() == rows.size()
		for i in mini(crow.size(), rows.size()):
			same_rows = same_rows and int(crow[i]) == int(rows[i])
		check(same_rows and bool(r.get("cells_ok", false)) and bool(r.get("round_end", false)), "%s: shift report rows %s match, cells match its GameState" % [NAMES[k], crow])
	await sync_point("short shift over", _all, true)
	Config.user_args.erase("event-delay")
	Config.growth_speed_override = 0.0
	b.event_first_delay_sec = FAR_AWAY
	b.event_gap_min_sec = FAR_AWAY
	b.event_gap_max_sec = FAR_AWAY
	b.round_length_sec = saved["len"]
	b.base_quota = saved["quota"]
	b.inspection_sec = saved["insp"]
	b.power_cut_max_sec = saved["cut"]
	b.headcount_sec = saved["hc"]
	b.water_off_sec = saved["water"]
	b.shortage_sec = saved["short"]
	b.mutation_warning_sec = saved["warn"]
	b.hostile_max = saved["max"]
	for s in b.seeds:
		s.mutation_chance = chances[s.id]


## The host's part in the short shift: two untended trays turn at once, then it breaks the glass, walks up to the
## nearest plant and holds the trigger. No assertions in here: the shift is chaos by design, the checks come after.
func _host_trouble() -> void:
	var b: BalanceConfig = Config.balance
	var me: Player = Game.local_player
	_trouble = {"turned": 0, "flamethrower": false, "burns": 0}
	await wait_sec(5.0)
	if not GameState.is_playing():
		return
	for i in [5, 6]:
		var p := plot(i)
		if p != null and p.is_empty() and p.server_plant(MUT_STRAIN):
			p.server_water(1.0)
			p.stage = GrowPlot.Stage.READY
			_trouble["turned"] = int(_trouble["turned"]) + 1
	await wait_sec(b.mutation_warning_sec + HostilePlant.ROOT_SEC + 0.5)
	if not GameState.is_playing() or me == null or not is_instance_valid(me):
		return
	var cab := station("EmergencyCabinet") as EmergencyCabinet
	stand_near(cab, 1.2)
	await wait_frames(2)
	cab.interact(me)
	await wait_until_quiet(func() -> bool: return me.get_held_item() is Flamethrower, 2.0)
	var ft := me.get_held_item() as Flamethrower
	_trouble["flamethrower"] = ft != null
	if ft == null:
		return
	var t_end := Time.get_ticks_msec() + 9000
	while GameState.is_playing() and Time.get_ticks_msec() < t_end and is_instance_valid(ft) and ft.holder_id == 1 and ft.fuel > 0.0:
		var h := Hostiles.nearest_to(me.global_position)
		if h == null:
			break
		var hp := h.global_position
		_place_local(Vector3(hp.x - 2.6, 0.05, hp.z), null, hp + Vector3.UP * Flamethrower.HOSTILE_POINT_HEIGHT, null)
		if not ft.firing:
			ft.request_fire(true)
		await wait_sec(0.25)
	if is_instance_valid(ft) and ft.firing:
		ft.request_fire(false)
	_trouble["burns"] = GameState.get_stat(1, Const.STAT_BURNS)
	if GameState.is_playing() and me.get_held_item() != null:
		Game.world.items.request_drop()
	_put_me(PARK["host"], Vector3(0.0, 0.05, 0.0))


# ---------------------------------------------------------------- (5d) the host leaves with plants on the floor

func _case_host_leaves() -> void:
	step("(5d) the host leaves in the middle of a shift with plants on the floor")
	GameState.request_retry()
	await wait_frames(8)
	GameState.request_start_round()
	check(GameState.is_playing(), "a fresh shift")
	_freeze_hostiles(false)
	check(Hostiles.server_spawn(SPARE_STRAIN, Vector3(5.0, 0.0, 1.5)) > 0 and Hostiles.server_spawn(MUT_STRAIN, Vector3(6.0, 0.0, -1.5)) > 0, "two plants on the floor")
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "a head count running")
	await sync_point("before the host leaves", _all)
	for k in _all:
		cmd(_ids[k], "host_leaves")
	await wait_sec(0.6)
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Net.is_online() and GameState.phase == GameState.Phase.MENU, "host in the menu")
	check(Hostiles.count() == 0 and not Events.is_event_active() and Events.is_power_on() and not Game.is_ui_locked(), "host: no plants, events reset, no UI lock")
	await wait_sec(1.5) # the clients finish their menu checks before the runner collects


# ---------------------------------------------------------------- host helpers

func step(msg: String) -> void:
	print("[%s] [%5.1f s] %s" % [_label, float(Time.get_ticks_msec() - _t0_msec) / 1000.0, msg])


func _abort() -> void:
	for k in _ids:
		if Net.players.has(_ids[k]):
			cmd(_ids[k], "finish", {})
	await wait_sec(1.0)
	finish()


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func _pid(key: String) -> int:
	return 1 if key == "host" else int(_ids.get(key, 0))


func _player(key: String) -> Player:
	return Game.world.get_player(_pid(key)) if Game.world != null else null


func _put_me(pos: Vector3, look: Vector3) -> void:
	_place_local(pos, look, null, null)


## Everyone to their parking spot, out of reach of every plant.
func _park_all() -> void:
	var seqs := {}
	for k in _all:
		seqs[k] = cmd(_ids[k], "goto", {"pos": PARK[k], "crouch": false})
	_put_me(PARK["host"], Vector3(0.0, 0.05, 0.0))
	for k in _all:
		await await_ack(seqs[k])


## Stops (or resumes) Hostiles' own physics tick on the host; while stopped the test steps it with Hostiles.tick().
func _freeze_hostiles(on: bool) -> void:
	Hostiles.set_physics_process(not on)


## Host: puts a plant somewhere with a clean slate (no target, no calm, no cooldown) and tells every client where it
## is now through the reliable state broadcast (clients snap to the pose that comes with it).
func _place_hostile(h: HostilePlant, pos: Vector3, announce: bool = true) -> void:
	if h == null or not is_instance_valid(h):
		return
	h.global_position = Vector3(pos.x, 0.0, pos.z)
	h._target_plot = null
	h._target_peer = 0
	h._wander_target = Vector3.INF
	h._wander_pause = 0.0
	h._calm_left = 0.0
	h._bites = 0
	h._bite_cooldown = 0.0
	h._stuck = 0.0
	h._detour = Vector3.INF
	h._detour_left = 0.0
	h._detour_random = false
	if h.state != HostilePlant.State.ROAM:
		h.state = HostilePlant.State.ROAM
	elif announce:
		h.state_changed.emit(h.state)


## True when every listed tray holds a READY crop of MUT_STRAIN that is still turning (waiting for the floor).
func _waiting(indices: Array) -> bool:
	for i in indices:
		var p := plot(int(i))
		if p == null or p.stage != GrowPlot.Stage.READY or not p.is_turning() or p.strain_id != MUT_STRAIN:
			return false
	return true


## A client's hostile_spawned log has the host's first `n` rows (ids, strain, where).
func _same_spawns(sp: Variant, n: int) -> bool:
	if not (sp is Array) or (sp as Array).size() != n or _h_spawned.size() < n:
		return false
	for i in n:
		var mine: Array = _h_spawned[i]
		var theirs: Array = (sp as Array)[i]
		if int(theirs[0]) != int(mine[0]) or String(theirs[1]) != String(mine[1]) or Vector3(theirs[2]).distance_to(Vector3(mine[2])) > 0.01:
			return false
	return true


func _plot_sig() -> String:
	var out: PackedStringArray = []
	for i in range(1, 7):
		var p := plot(i)
		out.append("%d:%s%s" % [i, p.get_stage_name(), " turning" if p.turning else ""])
	return ", ".join(out)


func _at_a_backroom_slot(p: Player) -> bool:
	if p == null or not is_instance_valid(p) or Game.world == null:
		return false
	for slot in Room.BACKROOM_SLOTS.size():
		if p.global_position.distance_to(Game.world.room.get_backroom_transform(slot).origin) < 0.4:
			return true
	return false


func _none_flying() -> bool:
	for it in Game.world.items.get_items():
		if it.is_flying():
			return false
	return true


func _stat_total(key: StringName) -> int:
	var n := 0
	for id in Net.players:
		n += GameState.get_stat(int(id), key)
	return n


static func _has_toast(list: Variant, substring: String) -> bool:
	if not (list is Array):
		return false
	for t in (list as Array):
		if String(t).to_lower().contains(substring.to_lower()):
			return true
	return false


static func _has_value(list: Array, v: float) -> bool:
	for x in list:
		if is_equal_approx(float(x), v):
			return true
	return false


func _reports(keys: Array) -> Dictionary:
	var seqs := {}
	for k in keys:
		seqs[k] = cmd(_ids[k], "report")
	var out := {}
	for k in keys:
		out[k] = await await_ack(seqs[k])
	return out


## One command to every listed client at once; their answers by key.
func _reports_cmd(keys: Array, action: String, args: Dictionary = {}) -> Dictionary:
	var seqs := {}
	for k in keys:
		seqs[k] = cmd(_ids[k], action, args)
	var out := {}
	for k in keys:
		out[k] = await await_ack(seqs[k])
	return out


func _logs(keys: Array) -> Dictionary:
	var seqs := {}
	for k in keys:
		seqs[k] = cmd(_ids[k], "m12_log")
	var out := {}
	for k in keys:
		out[k] = await await_ack(seqs[k])
	return out


## Empties the M12 records on every peer (the host's too).
func _clear_logs() -> void:
	var seqs := {}
	for k in _all:
		seqs[k] = cmd(_ids[k], "m12_log", {"clear": true})
	for k in _all:
		await await_ack(seqs[k])
	_clear_m12_log()


func checkpoint(tag: String, keys: Array, ui: bool = false) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names, ui)


## Every listed peer's M12 state must converge to the host's (asked again until it does or `timeout` passes: poses
## stream at 10 Hz, the cabinet countdown ticks once a second).
func m12_checkpoint(tag: String, keys: Array, tol: float = POS_TOL, timeout: float = 6.0) -> void:
	var t0 := Time.get_ticks_msec()
	var diffs := {}
	var first_diff := ""
	while true:
		var seqs := {}
		for k in keys:
			seqs[k] = cmd(_ids[k], "m12")
		var reps := {}
		for k in keys:
			reps[k] = await await_ack(seqs[k], 8.0)
		var mine := _m12_state()
		diffs.clear()
		for k in keys:
			var d := _m12_diff(mine, reps[k], tol)
			if d != "":
				diffs[k] = d
				if first_diff == "":
					first_diff = "%s: %s" % [NAMES[k], d]
		if diffs.is_empty() or Time.get_ticks_msec() - t0 > timeout * 1000.0:
			break
		await wait_sec(0.15)
	if diffs.is_empty() and Time.get_ticks_msec() - t0 > 500:
		print("  ([%s] settled after %d ms; first difference: %s)" % [tag, Time.get_ticks_msec() - t0, first_diff])
	for k in keys:
		check(not diffs.has(k), "[%s] %s: M12 state matches the host (%d ms)%s" % [tag, NAMES[k], Time.get_ticks_msec() - t0, (" " + String(diffs[k])) if diffs.has(k) else ""])


## canonical_state() and the M12 state equal on every peer.
func sync_point(tag: String, keys: Array, ui: bool = false) -> void:
	await checkpoint(tag, keys, ui)
	await m12_checkpoint(tag, keys)


# =================================================================================================== CLIENT

## Same-frame actions run inside the network poll that delivered the command.
func _immediate(seq: int, action: String, args: Dictionary) -> bool:
	if action == "break_now":
		var cab := station("EmergencyCabinet") as EmergencyCabinet
		var t := toasts.size()
		if cab != null and Game.local_player != null:
			cab.interact(Game.local_player)
		_queue.append([seq, "break_settle", {"t": t}])
		return true
	return super(seq, action, args)


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	var my_name: String = NAMES.get(who, "Client")
	match action:
		"break_settle":
			var t_press := int(args.get("t", 0))
			await wait_until_quiet(func() -> bool: return me.get_held_item() is Flamethrower or _has_toast(toasts_since(t_press), "Restocking"), 6.0)
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"held": me.get_held_item() is Flamethrower, "toasts": toasts_since(t_press)})
		"m12":
			ack(seq, _m12_state())
		"m12_log":
			var log := _m12_log()
			if bool(args.get("clear", false)):
				_clear_m12_log()
			ack(seq, log)
		"harvest":
			var p := plot(int(args.get("plot", 1)))
			stand_near(p, 1.2)
			await server_sees_me()
			check(p.get_prompt(me).contains("Moving") and p.can_interact(me), "%s: the prompt says Moving and still offers the harvest" % my_name)
			p.interact(me)
			var ok := await wait_until_quiet(func() -> bool: return me.get_held_item() is Product, 6.0)
			await sync_with_host()
			ack(seq, {"ok": ok, "toasts": toasts_since(t)})
		"break_glass":
			var cab := station("EmergencyCabinet") as EmergencyCabinet
			var ok := cab != null and me != null
			if ok:
				stand_near(cab, 1.2)
				await server_sees_me()
				cab.interact(me)
				ok = await wait_until_quiet(func() -> bool: return me.get_held_item() is Flamethrower, 8.0)
				check(ok, "%s: the flamethrower arrived in my hands" % my_name)
				await sync_with_host()
				await wait_frames(2)
			ack(seq, {"ok": ok, "broken": cab.broken if cab != null else false, "toasts": toasts_since(t)})
		"fire":
			# The real input path: the held `use_item` action is polled by the flamethrower in the local holder's hands.
			var on := bool(args.get("on", true))
			var ft := me.get_held_item() as Flamethrower if me != null else null
			if on:
				Input.action_press(&"use_item")
			else:
				Input.action_release(&"use_item")
			var seen := false
			if ft != null:
				seen = await wait_until_quiet(func() -> bool: return not is_instance_valid(ft) or ft.firing == on, 6.0)
			ack(seq, {"held": ft != null, "seen": seen})
		"fire_raw":
			# Straight to the server, past the client's own "tank is empty" gate.
			var ft := me.get_held_item() as Flamethrower if me != null else null
			if ft != null:
				ft.request_fire(bool(args.get("on", true)))
			await sync_with_host()
			await wait_frames(3)
			ack(seq, {"held": ft != null, "firing": ft != null and ft.firing})
		"pickup":
			var it := item_named(String(args.get("item", "")))
			var ok := it != null and me != null
			if ok:
				stand_near(it, 0.7)
				await server_sees_me()
				it.interact(me)
				ok = await wait_until_quiet(func() -> bool: return it.holder_id == me.peer_id, 6.0)
			ack(seq, {"ok": ok, "toasts": toasts_since(t)})
		"drop":
			if Game.world != null:
				Game.world.items.request_drop()
			var ok := await wait_until_quiet(func() -> bool: return me.get_held_item() == null, 6.0)
			ack(seq, {"ok": ok})
		"well_try":
			var well := station("Well") as Well
			var held := me.get_held_item()
			stand_near(well, 1.3)
			await server_sees_me()
			var prompt := well.get_prompt(me)
			var can_local := well.can_interact(me)
			well._rpc_request_interact.rpc_id(Const.SERVER_PEER_ID) # the raw request: the HOST refuses or grants it
			if bool(args.get("expect_full", false)):
				await wait_until_quiet(func() -> bool: return GrowPlot.get_can_charges(held) >= GrowPlot.get_can_capacity(held), 5.0)
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"prompt": prompt, "can": can_local, "toasts": toasts_since(t), "charges": GrowPlot.get_can_charges(held), "pressure": well.has_pressure()})
		"buy_try":
			var shop := station("ShopCounter") as ShopCounter
			var seed_id := StringName(String(args.get("seed", "")))
			stand_near(shop, 1.3)
			await server_sees_me()
			shop.request_buy_seed(seed_id)
			# The packet in hand, or the counter's refusal (other toasts may pass by: "GrowPlot 4 is moving.").
			await wait_until_quiet(func() -> bool: return me.get_held_item() is SeedPacket or _has_toast(toasts_since(t), "Out of stock"), 6.0)
			await sync_with_host()
			await wait_frames(2)
			var got := me.get_held_item()
			ack(seq, {"held": got is SeedPacket and String(got.get(&"strain_id")) == String(seed_id), "toasts": toasts_since(t)})
		"late_hostile":
			await wait_until_quiet(func() -> bool: return _spawn_msec >= 0, 5.0)
			var seen := await wait_until_quiet(func() -> bool: return Hostiles.count() >= 1 and not _h_spawned.is_empty(), 5.0)
			check(seen, "%s (late joiner): the hostile plant is here" % my_name)
			var rep := _m12_state()
			rep["ms"] = (int(_h_spawned.back()[3]) - _spawn_msec) if seen else 99999
			rep["spawned"] = _h_spawned.duplicate(true)
			ack(seq, rep)
		"late_turning":
			var want := int(args.get("count", 1))
			await wait_until_quiet(func() -> bool:
				var n := 0
				for i in range(1, 7):
					if plot(i) != null and plot(i).is_turning():
						n += 1
				return _spawn_msec >= 0 and n >= want, 5.0)
			_turn_seen.clear()
			_twitch_seen.clear()
			await wait_sec(0.5)
			var rep := _m12_state()
			var turn: Array = _turn_seen.keys()
			turn.sort()
			var twitch: Array = _twitch_seen.keys()
			twitch.sort()
			rep["turn_seen"] = turn
			rep["twitch_seen"] = twitch
			ack(seq, rep)
		"forged_m12":
			var victim: Player = Game.world.get_player(int(args.get("victim", 0))) if Game.world != null else null
			var ignited0 := _ignited.size()
			var well := station("Well") as Well
			var cab := station("EmergencyCabinet") as EmergencyCabinet
			# Authority-only: the engine refuses them on the host.
			Hostiles._rpc_spawn.rpc_id(1, 99, &"budget", Vector3(0.0, 0.0, 0.0), 0.0)
			Hostiles._rpc_despawn_all.rpc_id(1)
			Hostiles._rpc_died.rpc_id(1, int(args.get("hostile", 0)), me.peer_id)
			well._rpc_set_pressure.rpc_id(1, true)
			(station("ShopCounter") as ShopCounter)._rpc_set_shortage.rpc_id(1, &"budget")
			cab._rpc_glass_break.rpc_id(1, me.peer_id)
			plot(1)._rpc_scorched.rpc_id(1, me.peer_id)
			# any_peer: validated by the game code.
			var loose := item_named(String(args.get("flame", ""))) as Flamethrower
			if loose != null:
				loose._rpc_request_fire.rpc_id(1, true)                 # nobody holds it, least of all me
			if victim != null:
				victim._rpc_ignited.rpc(me.peer_id)                     # only the server may set a worker on fire
			cab._rpc_request_interact.rpc_id(1)                         # from the parking spot: too far
			await sync_with_host()
			await wait_sec(0.4)
			ack(seq, {"toasts": toasts_since(t), "local_ignites": _ignited.size() - ignited0, "pressure": well.has_pressure(), "hostiles": Hostiles.count()})
		"late_flame":
			await wait_until_quiet(func() -> bool: return _spawn_msec >= 0 and items_of(FLAME).size() >= int(args.get("count", 1)), 5.0)
			var rep := _m12_state()
			var fx := {}
			for it in items_of(FLAME):
				var flame := it.get_node_or_null(^"Visual/Nozzle/Flame") as CPUParticles3D
				fx[String(it.name)] = flame != null and flame.emitting
			rep["fx"] = fx
			ack(seq, rep)
		"host_restart":
			left_on_purpose = true
			var ok := await wait_until(func() -> bool: return Game.world == null, 15.0, "%s: back in the menu after the host left" % my_name)
			await wait_frames(3)
			check(_host_left_seen, "%s: server_disconnected received" % my_name)
			check_menu_clean("%s after the host left" % my_name)
			check(Hostiles.count() == 0 and not Events.is_event_active() and Events.is_power_on(), "%s: nothing left of the session" % my_name)
			await wait_sec(float(args.get("delay", 2.5)))
			_spawn_msec = -1
			_host_left_seen = false
			var joined := false
			for attempt in 3:
				if Game.start_join("127.0.0.1", port, my_name) == OK and await wait_until_quiet(func() -> bool: return Game.local_player != null, 9.0):
					joined = true
					break
				await wait_sec(1.0)
			check(joined, "%s: joined the fresh host on port %d" % [my_name, port])
			left_on_purpose = false
			ack(seq, {"ok": ok and joined})
		"host_leaves":
			await super(seq, "expect_host_leave", args)
			check(Hostiles.count() == 0, "%s: no hostile plant left after the host left" % my_name)
		_:
			await super(seq, action, args)
