extends "res://tools/tests/qa_base.gd"
## M12 disrupt multi-process suite (disrupt agent), driven by tools/tests/disrupt_mp.sh: a host, client A (joins at
## the start) and client B (joins DURING the shortage).
##   host: shift, plants seeds[0] once (so the shortage picks it), WATER_OFF (marker DISRUPT_WATER_OFF); waits until A
##         stands at the tank (synced position) plus a beat for its refused request, ends it; SHORTAGE (marker
##         DISRUPT_SHORTAGE starts B); waits until B is in and both clients stand at the counter plus a beat, ends it;
##         waits for the clients to leave.
##   a:    sees water_off + the pressure off (two reliable packets), the prompt "No pressure", its interact request
##         refused by the host with the reason; the pressure back + event_ended; then the shortage: the synced strain,
##         the counter prompt, a buy of the short strain refused by the host ("Out of stock."), another strain sold;
##         the end. Leaves clean.
##   b:    joins during the shortage: shortage_strain + the event synced on join, the HUD banner "SHORTAGE" with the
##         strain in its hint, the well fine again (the water_off was over), the short strain refused; the end. Leaves.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0
## A client counts as "standing at" a station within this flat distance (synced positions on the host).
const NEAR := 3.0

var role: String = "host"
var port: int = 7960
var _started: Array = []
var _ended: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7960))
	_label = "disrupt_mp:" + role
	await get_tree().process_frame
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ended.append([k]))
	match role:
		"host": await _host()
		"a": await _client_a()
		"b": await _client_b()
	finish()


# --- host ------------------------------------------------------------------------------------------------------------

func _host() -> void:
	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		return
	print("DISRUPT_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_sec(0.5)
	var seed0: SeedDef = Config.balance.seeds[0]
	check(plot(1).server_plant(seed0.id), "host: planted %s once (the shortage will pick it)" % seed0.id)
	Events.tick(0.05)
	var well := _well()
	var counter := _counter()
	step("water off")
	check(Events.server_start_event(Events.EVENT_WATER_OFF), "water off started")
	check(well != null and not well.has_pressure(), "host: pressure off")
	print("DISRUPT_WATER_OFF")
	await wait_until(func() -> bool: return _clients_near(well, false), STEP_TIMEOUT, "A stands at the tank (synced position)")
	await wait_sec(2.5)   # its refused request has made the round trip by now
	Events.server_end_event()
	await wait_frames(2)
	check(well.has_pressure() and not Events.is_event_active() and _ended.back()[0] == Events.EVENT_WATER_OFF, "host: water back, event over")
	await wait_sec(0.5)
	step("shortage")
	check(Events.server_start_event(Events.EVENT_SHORTAGE), "shortage started")
	check(counter != null and counter.get_shortage_strain() == seed0.id, "host: the planted strain is the one short (%s)" % counter.get_shortage_strain())
	print("DISRUPT_SHORTAGE")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and Game.world.get_players().size() >= 3, JOIN_TIMEOUT, "client B joined during the shortage")
	await wait_until(func() -> bool: return _clients_near(counter, true), STEP_TIMEOUT, "both clients stand at the counter")
	await wait_sec(3.0)   # their buy requests have made the round trip
	check(Events.is_event_active(Events.EVENT_SHORTAGE) and counter.is_short(seed0.id), "host: still short while they shop")
	Events.server_end_event()
	await wait_frames(2)
	check(counter.get_shortage_strain() == &"" and not Events.is_event_active() and _ended.back()[0] == Events.EVENT_SHORTAGE, "host: cleared, event over")
	print("DISRUPT_DONE")
	# Both clients leave at the same moment: SceneMultiplayer may still flush a packet to a peer ENet has already
	# reset ("Unable to send packet on channel 0", no game code on the stack; see qa_mp_robust_body.gd).
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "both clients left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


## Host: a client (any, or every one when `all`) stands within NEAR of `node` by its synced position.
func _clients_near(node: Node3D, all: bool) -> bool:
	if node == null or Game.world == null:
		return false
	var any := false
	var clients := 0
	for pl in Game.world.get_players():
		if pl.peer_id == Const.SERVER_PEER_ID:
			continue
		clients += 1
		var d := Vector2(pl.global_position.x - node.global_position.x, pl.global_position.z - node.global_position.z).length()
		if d <= NEAR:
			any = true
		elif all:
			return false
	return any and clients > 0


# --- client A -------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	var me: Player = Game.local_player
	var well := _well()
	check(well != null and well.has_pressure() and not Events.is_event_active(), "A: joined with the water on, no event")
	# The Well's pressure RPC and event_started are two reliable packets: the second may land a poll later.
	await wait_until(func() -> bool: return not well.has_pressure() and Events.is_event_active(Events.EVENT_WATER_OFF), STEP_TIMEOUT, "A: pressure off + event_started(water_off) arrived")
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_WATER_OFF and _started.back()[1].has("seconds"), "A: event_started(water_off, {seconds})")
	check(well.get_prompt(me) == "No pressure" and not well.can_interact(me) and well.get_denied_reason(me) == "No pressure", "A: the tank reads 'No pressure'")
	check(Events.get_event_time_left() > 0.0, "A: time left counts down locally (%.1f)" % Events.get_event_time_left())
	var water := well.get_node_or_null(^"Visual/Water") as Node3D
	check(water != null and not water.visible, "A: the water is gone from the tank here too")
	step("A asks the tank")
	stand_near(well, 1.3)
	await wait_sec(1.2)
	toasts.clear()
	well._rpc_request_interact.rpc_id(Const.SERVER_PEER_ID)
	await wait_until(func() -> bool: return toast_seen("No pressure"), 5.0, "A: the host refused the refill: 'No pressure'")
	await wait_until(func() -> bool: return well.has_pressure(), STEP_TIMEOUT, "A: pressure back")
	# pressure and event_ended travel as two reliable packets: the second may land a poll later.
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "A: the event is over here too")
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_WATER_OFF, "A: event_ended(water_off)")
	check(well.get_prompt(me).begins_with("Fill can") and water != null and water.visible, "A: the tank is back to normal")
	await _shortage_checks("A", false)
	await _leave("A")


# --- client B (late joiner) ---------------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	var counter := _counter()
	var well := _well()
	# The counter's shortage RPC and the event replay are two reliable packets: wait for both.
	await wait_until(func() -> bool: return counter != null and counter.get_shortage_strain() != &"" and Events.is_event_active(Events.EVENT_SHORTAGE), 6.0, "B: joined during the shortage: strain + event synced")
	var strain: StringName = counter.get_shortage_strain() if counter != null else &""
	check(_started.size() >= 1 and _started.back()[0] == Events.EVENT_SHORTAGE and StringName(str(_started.back()[1].get("strain", ""))) == strain, "B: event_started(shortage, {strain}) from the late-join replay (%s)" % strain)
	check(Events.get_event_time_left() > 0.0 and Events.get_event_time_left() <= Config.balance.shortage_sec, "B: time left synced (%.1f)" % Events.get_event_time_left())
	check(well != null and well.has_pressure() and well.get_prompt(Game.local_player).begins_with("Fill can"), "B: the tank is fine (the water_off was over before the join)")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	var def: SeedDef = Config.balance.get_seed(strain)
	var who := def.display_name if def != null else String(strain)
	check(hud != null and hud.get_event_text().begins_with("SHORTAGE"), "B: the HUD banner reads SHORTAGE (%s)" % (hud.get_event_text() if hud != null else "no HUD"))
	check(hud != null and hud.event_hint.visible and hud.event_hint.text.contains(who), "B: its hint names the strain (%s)" % (hud.event_hint.text if hud != null else ""))
	await _shortage_checks("B", true)
	await _leave("B")


# --- shared ---------------------------------------------------------------------------------------------------------

func _shortage_checks(tag: String, already_active: bool) -> void:
	step("%s shortage" % tag)
	var counter := _counter()
	var me: Player = Game.local_player
	if not already_active:
		await wait_until(func() -> bool: return counter.get_shortage_strain() != &"" and Events.is_event_active(Events.EVENT_SHORTAGE), STEP_TIMEOUT, "%s: shortage arrived (strain + event)" % tag)
	var strain: StringName = counter.get_shortage_strain()
	var def: SeedDef = Config.balance.get_seed(strain)
	check(def != null and counter.is_short(strain) and counter.get_prompt(me).contains("out of stock") and counter.get_prompt(me).contains(def.display_name), "%s: the counter prompt names %s" % [tag, strain])
	var other: SeedDef = null
	for s in Config.balance.seeds:
		if s.id != strain and (other == null or s.cost < other.cost):
			other = s
	stand_near(counter, 1.3)
	await wait_sec(1.2)
	toasts.clear()
	counter.request_buy_seed(strain)
	await wait_until(func() -> bool: return toast_seen("Out of stock"), 5.0, "%s: the host refused the short strain: 'Out of stock.'" % tag)
	check(me.get_held_item() == null, "%s: nothing in hand" % tag)
	if other != null and GameState.money >= other.cost:
		toasts.clear()
		counter.request_buy_seed(other.id)
		await wait_until(func() -> bool: return me.get_held_item() != null, 5.0, "%s: another strain (%s) still sells: packet in hand" % [tag, other.id])
	else:
		print("  (%s: skipped the other-strain buy: cash %d)" % [tag, GameState.money])
	await wait_until(func() -> bool: return counter.get_shortage_strain() == &"", STEP_TIMEOUT, "%s: shortage cleared" % tag)
	await wait_until(func() -> bool: return not Events.is_event_active(), 3.0, "%s: the event is over here too" % tag)
	check(_ended.size() >= 1 and _ended.back()[0] == Events.EVENT_SHORTAGE, "%s: event_ended(shortage)" % tag)
	check(counter.get_prompt(me) == "Buy supplies", "%s: the counter prompt is plain again" % tag)


func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not Events.is_event_active() and Events.is_power_on(), "%s: events reset locally" % tag)


func _well() -> Well:
	if Game.world == null:
		return null
	return Game.world.room.get_station("Well") as Well


func _counter() -> ShopCounter:
	if Game.world == null:
		return null
	return Game.world.room.get_station("ShopCounter") as ShopCounter
