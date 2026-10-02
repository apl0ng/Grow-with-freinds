extends "res://tools/tests/qa_base.gd"
## M13 review of milestone M12 (review agent): adversarial regression suite on a single headless host with four fake
## workers (Bob, Chloe, Dana, Eve: spawned without an owning peer, so the SERVER side runs on them directly).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_m12_body.gd --port=7963 --round-sec=900
## Server handlers are called directly (sender 0 = this peer, the host's own worker), exactly like a client's request
## would arrive. Hostiles' own physics tick is switched off: the suite advances the plants with Hostiles.tick().
## Every section pins a bug that was demonstrated on the integrated M12 commit (3151d8d) or a rule the review added:
##   R1  the flamethrower fired for a STUNNED holder (throws and shoves are refused while stunned; the flame was not),
##       and a stagger did not put the flame out. Requests from a non-holder, for a flying / just-thrown item, from the
##       back room and after the shift stay refused; a 400-request on/off burst costs no fuel and leaves a sane state.
##   R2  the arson brake had a hole: one cone pass over several workers kept igniting (and fining the team) after the
##       third write-up had already sent the shooter to the back room. The pass stops there now.
##   R3  breaking the glass, or burning the plant, during the six-second "GrowPlot 3 is moving." warning was written up
##       as misuse / arson: the correct reaction was punished. A tray that is turning counts as trouble on the floor.
##       Scorching a turning plant cancels the mutation: nothing comes out of the empty tray.
##   R4  hostile_max: a third plant that turned lost its crop silently (plot reset, nothing spawned). It keeps
##       twitching in its tray until there is room on the floor, then uproots.
##   R5  the hostile plant bit through the grow-area fence (no line of sight), stood pinned at a fence forever when its
##       target (a worker or a tray) was behind it (nobody had to fear it and the crops were safe: a free exploit), and
##       walked through workers while calm (a static body pushed into a character against a wall). Escape rules: a bite
##       needs a clear line; a chase that cannot get closer for STUCK_SEC is dropped (calm, back to the trays); a tray
##       it cannot reach sends it round by the grow-area gate (or a random point); it never steps onto a worker (it
##       walks round); after its two bites it walks away from the worker, so a corner is not a trap.
##   R6  a tray harvested or scorched under an eating plant: it stops eating, nothing is counted as eaten.
##   R7  the shortage picked a strain nobody could afford when nothing was planted yet (a free event); a worker who
##       was not on the floor when a head count began (back room, joined late) was written up as absent.
##   R8  churn: the holder disconnects while firing; the shift ends / RETRY / back to the menu with a hostile alive, a
##       flame on, a head count running and a tray turning; the back room while holding the flamethrower and while
##       being chased; two flamethrowers; the flamethrower thrown at the chute and out of bounds. BUG: anything thrown
##       past the Boss (the pay window has no collider above the 1 m counter) or lobbed over a partition came to rest
##       INSIDE the booth and was lost for the shift (the flamethrower, and both of the team's watering cans). A flight
##       never ends in the booth now (Room.is_in_booth).
##   R9  the cabinet: from across the room, five requests in one frame, two workers in one frame, cash short.
##   R10 copy audit of every M12 string (no "!", no cheer, house vocabulary); the M12 write-ups (arson / misuse /
##       absent) were toasts without a reason ("Bob written up."): named now. Cabinet denials got their full stop.
##   R11 numbers that must hold together.
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const CHLOE := 3
const DANA := 4
const EVE := 5
const WORKERS: Array[int] = [BOB, CHLOE, DANA, EVE]
const NAMES := {BOB: "Bob", CHLOE: "Chloe", DANA: "Dana", EVE: "Eve"}
const CHEER_WORDS: PackedStringArray = ["nice", "great", "awesome", "congrat", "well done", "good job", "yay", "woo", "amazing", "wonderful", "hooray", "thank"]
## Words the house vocabulary replaces (CLAUDE.md: shift / payment due / cash on hand / workers / supply window / favors).
const OFF_VOCABULARY: PackedStringArray = ["round", "quota", "money", "coins", "players", "shop", "store", "upgrade"]
## Far from the grow area and from each other: nothing senses anyone here (hostile_sense_range 5 m).
const PARKING := {1: Vector3(-8.5, 0.0, 6.0), BOB: Vector3(-8.5, 0.0, 4.0), CHLOE: Vector3(-8.5, 0.0, 2.0), DANA: Vector3(-7.0, 0.0, 6.5), EVE: Vector3(-7.0, 0.0, 4.5)}

var port: int = 7963
var world: World
var items: ItemManager
var room: Room
var me: Player
var cabinet: EmergencyCabinet
var _write_ups: Array = []    # [peer, reason, strikes after]
var _ignites: Array = []      # [victim, by_peer]
var _bites: Array = []        # [hostile id, peer, line of sight clear at that moment]
var _ate: Array = []          # [hostile id, plot]
var _spawned: Array = []      # [hostile id, strain]
var _chance: Dictionary = {}  # strain id -> the data's mutation_chance (restored at the end)


func _run() -> void:
	_label = "review_m12"
	port = port_arg(7963)
	await get_tree().process_frame
	Config.growth_speed_override = 0.0
	for s in Config.balance.seeds:
		_chance[s.id] = s.mutation_chance
	if not await _host():
		finish(); return
	await _r1_fire_requests()
	await _r2_arson_brake()
	await _r3_turning_tray()
	await _r4_hostile_max()
	await _r5_escape_rules()
	await _r6_tray_gone_under_it()
	await _r7_shortage_and_headcount()
	await _r9_cabinet()
	_r10_copy_audit()
	_r11_numbers()
	await _r8_churn() # last: it ends the shift, retries and leaves for the menu
	for s in Config.balance.seeds:
		s.mutation_chance = float(_chance[s.id])
	finish()


# =================================================================================================== helpers

func _host() -> bool:
	if get_tree().get_first_node_in_group(Game.MENU_GROUP) == null:
		get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
		await wait_frames(2)
	if not check(Game.start_host("Reviewer", port) == OK, "hosting on port %d" % port):
		return false
	if not await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, 6.0, "world, player, starting cans"):
		return false
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	cabinet = station("EmergencyCabinet") as EmergencyCabinet
	if not check(cabinet != null, "Room/Stations/EmergencyCabinet exists"):
		return false
	# The suite drives the plants itself (Hostiles.tick): no real-time steps in between.
	Hostiles.set_physics_process(false)
	for id in WORKERS:
		_add_worker(id)
	await wait_frames(3)
	if not check(world.get_players().size() == 5, "Bob, Chloe, Dana and Eve spawned (5 workers)"):
		return false
	me.ignited.connect(_on_ignited.bind(1))
	GameState.worker_written_up.connect(func(p: int, reason: String, count: int) -> void: _write_ups.append([p, reason, count]))
	Hostiles.hostile_bit.connect(_on_bit)
	Hostiles.hostile_ate.connect(func(id: int, plot_index: int) -> void: _ate.append([id, plot_index]))
	Hostiles.hostile_spawned.connect(func(id: int, strain: StringName, _pos: Vector3) -> void: _spawned.append([id, strain]))
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift running")
	await _reset_floor()
	return true


## A fake worker: in the registry and spawned on the host without an owning peer.
func _add_worker(id: int) -> Player:
	Net.players[id] = {"name": NAMES[id], "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	Net.players_changed.emit()
	var p := world.server_spawn_player(id)
	if p != null and not p.ignited.is_connected(_on_ignited.bind(id)):
		p.ignited.connect(_on_ignited.bind(id))
	return p


func _on_ignited(by: int, victim: int) -> void:
	_ignites.append([victim, by])


## Records every bite with whether the plant had a clear line to the worker's chest at that moment.
func _on_bit(id: int, peer: int) -> void:
	var h := Hostiles.get_hostile(id) as HostilePlant
	var p := world.get_player(peer)
	var clear := false
	if h != null and p != null:
		clear = _line_clear(h.global_position + Vector3.UP * 1.0, p.get_chest_position(), h)
	_bites.append([id, peer, clear])


## True when nothing on LAYER_WORLD (bar the hostiles' own bodies and the trays) sits between the two points.
func _line_clear(from: Vector3, to: Vector3, h: HostilePlant) -> bool:
	var exclude: Array[RID] = []
	for n in get_tree().get_nodes_in_group(Const.GROUP_HOSTILES):
		var body := n.get_node_or_null(^"Body") as CollisionObject3D
		if body != null:
			exclude.append(body.get_rid())
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var body := n.get_node_or_null(^"Body") as CollisionObject3D
		if body != null:
			exclude.append(body.get_rid())
	var query := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD, exclude)
	return h.get_world_3d().direct_space_state.intersect_ray(query).is_empty()


## The worker leaves the way Net cleans up a dropped peer (item released, body despawned, registry synced).
func _drop_worker(id: int) -> void:
	Net.call(&"_server_cleanup_departed", id, Net.get(&"_peer"))


func _worker(id: int) -> Player:
	return me if id == 1 else world.get_player(id)


## Puts a body exactly at `pos` with yaw `yaw` (0 = facing -Z) and head pitch `pitch` (negative = looking down).
func _put(id: int, pos: Vector3, yaw: float = 0.0, pitch: float = 0.0) -> void:
	var p := _worker(id)
	if p == null:
		return
	if id == 1:
		p.velocity = Vector3.ZERO
		p.global_position = pos + Vector3.UP * 0.02
		p.rotation = Vector3(0.0, yaw, 0.0)
		p.head.rotation.x = pitch
		return
	p.net_position = pos
	p.net_yaw = yaw
	p.net_pitch = pitch
	p.position = pos
	p.rotation = Vector3(0.0, yaw, 0.0)
	p.head.rotation.x = pitch
	p.velocity = Vector3.ZERO


func _park_all() -> void:
	for id: int in PARKING:
		_put(id, PARKING[id])


## A clean floor between sections: no hostiles, empty trays, no flamethrowers, nobody in the back room, no strikes,
## the cabinet stocked, no event, cash on hand topped up, everyone parked far from the grow area.
func _reset_floor() -> void:
	if Events.is_event_active():
		Events.server_end_event()
	Hostiles.server_despawn_all()
	for i in range(1, 7):
		plot(i).server_reset()
	for it in items_of(Const.ITEM_FLAMETHROWER):
		items.server_despawn_item(it)
	for it in items_of(Const.ITEM_PRODUCT):
		items.server_despawn_item(it)
	for id in GameState.get_backroom_peers():
		GameState.server_release_from_backroom(id)
	GameState.write_ups.clear()
	if cabinet.broken:
		cabinet.server_restock()
	if GameState.money < 500:
		GameState.server_add_money(500 - GameState.money)
	await wait_frames(2)
	Hostiles.tick(0.01) # the mutation watch forgets the trays it rolled for
	_park_all()
	await wait_physics(2)
	_write_ups.clear()
	_ignites.clear()
	_bites.clear()
	_ate.clear()
	_spawned.clear()
	toasts.clear()


func _flamethrower(holder: int, fuel: float = -1.0) -> Flamethrower:
	var f := fuel if fuel >= 0.0 else Config.balance.flamethrower_fuel_sec
	return items.server_spawn_item(Const.ITEM_FLAMETHROWER, {"fuel": f}, Vector3(-4.0, 0.0, 4.0), holder) as Flamethrower


func _make_ready(p: GrowPlot, strain: StringName) -> void:
	p.server_reset()
	p.server_plant(strain)
	p.stage = GrowPlot.Stage.READY


func _make_growing(p: GrowPlot, strain: StringName = &"budget", progress: float = 0.9) -> void:
	p.server_reset()
	p.server_plant(strain)
	p.server_water(1.0)
	p.stage_progress = progress


func _hostile(pos: Vector3, strain: StringName = &"budget") -> HostilePlant:
	var id := Hostiles.server_spawn(strain, pos)
	return Hostiles.get_hostile(id) as HostilePlant if id > 0 else null


## Advances the plants `seconds` in `dt` steps; stops early when `until` (optional) says so. Returns the time used.
func _tick(seconds: float, until: Callable = Callable(), dt: float = 0.05) -> float:
	var t := 0.0
	while t < seconds:
		Hostiles.tick(dt)
		t += dt
		if until.is_valid() and bool(until.call()):
			break
	return t


## Like _tick but in real time (bites wait on the real stagger-immunity clock).
func _tick_real(seconds: float, until: Callable = Callable()) -> void:
	var t0 := Time.get_ticks_msec()
	var last := t0
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		Hostiles.tick(maxf((now - last) / 1000.0, 0.001))
		last = now
		if until.is_valid() and bool(until.call()):
			return


func _flat(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _strikes(peer: int) -> int:
	return GameState.get_write_ups(peer)


# =================================================================================================== R1

func _r1_fire_requests() -> void:
	step("R1: fire requests from a stunned holder, for a flying item, in a burst")
	await _reset_floor()
	_put(BOB, Vector3(-3.0, 0.0, 4.0), PI) # facing +Z, at nothing
	var ft := _flamethrower(BOB)
	await wait_physics(2)
	if not check(ft != null and ft.holder_id == BOB and ft.fuel == Config.balance.flamethrower_fuel_sec, "Bob holds a full flamethrower"):
		return
	var bob := _worker(BOB)
	# A shove from the front: the worker keeps the item and stumbles (the server's own view of the stun).
	Player.server_stagger(bob, Vector3.FORWARD, false, 1, 0.6)
	check(bob.is_stunned() and ft.holder_id == BOB, "Bob is stunned (shoved from the front), still holding it")
	check(not ft.server_request_fire(BOB, true) and not ft.firing, "a stunned holder cannot start the flame (like a throw or a shove)")
	ft.server_request_fire(BOB, false)
	await wait_until(func() -> bool: return not bob.is_stunned() and bob.can_be_staggered(), 4.0, "the stun and the immunity pass")
	check(ft.server_request_fire(BOB, true) and ft.firing, "recovered: the flame starts")
	Player.server_stagger(bob, Vector3.FORWARD, false, 1, 0.6)
	check(bob.is_stunned(), "staggered again while firing")
	await wait_physics(2)
	check(not ft.firing, "a stagger puts the flame out")
	await wait_until(func() -> bool: return not bob.is_stunned() and bob.can_be_staggered(), 4.0, "recovered")

	# Thrown while firing: the flame goes out, and nothing fires an item in the air or on the floor.
	check(ft.server_request_fire(BOB, true) and ft.firing, "firing again")
	check(items.server_throw_item(ft, bob.get_chest_position() + Vector3(0.0, 0.3, 0.6), Vector3(0.0, 3.0, 4.0), BOB), "thrown while firing")
	check(not ft.server_request_fire(BOB, true), "the thrower no longer holds it: request refused")
	check(not ft.server_request_fire(0, true) and not ft.server_request_fire(-1, true), "peer 0 / -1 never match a free item")
	await wait_physics(2)
	check(not ft.firing and ft.is_flying(), "in the air: the flame is out")
	await wait_until(func() -> bool: return not ft.is_flying(), 4.0, "it lands")
	check(ft.holder_id == 0 and not ft.server_request_fire(BOB, true) and not ft.server_request_fire(1, true) and not ft.firing, "on the floor: nobody can fire it")
	ft._rpc_request_fire(true) # the raw request, sender = this host, who does not hold it
	check(not ft.firing, "the raw RPC from a non-holder does nothing")

	# A burst of 400 on/off requests between two physics ticks: no fuel spent, nothing burnt, a sane end state.
	check(items.server_give_item(ft, BOB), "Bob picks it up again")
	var p1 := plot(1)
	_make_growing(p1)
	_put(BOB, p1.global_position + Vector3(-2.0, 0.0, 0.0), -PI * 0.5, -0.3)
	await wait_physics(2)
	var fuel0 := ft.fuel
	_write_ups.clear()
	var t0 := Time.get_ticks_usec()
	for i in 200:
		ft.server_request_fire(BOB, true)
		ft.server_request_fire(BOB, false)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	check(not ft.firing and ft.fuel == fuel0 and ft._loop_handle == 0, "400 requests in one frame: flame off, fuel untouched (%.1f s)" % ft.fuel)
	check(ms < 600.0, "the burst cost %.1f ms" % ms)
	# Toggling every tick never adds up to a scorch (the exposure must be continuous) and still pays for each tick.
	for i in 40:
		ft.server_request_fire(BOB, true)
		ft._server_tick(1.0 / 60.0)
		ft.server_request_fire(BOB, false)
	check(p1.stage != GrowPlot.Stage.EMPTY and _write_ups.is_empty(), "40 one-tick bursts at a tray: no scorch (exposure is continuous)")
	check(ft.fuel < fuel0 - 0.5, "and each tick of flame was paid for (%.1f s left)" % ft.fuel)
	# The back room and the end of the shift (flame_body pins the plain cases; here the flame is already on).
	check(ft.server_request_fire(BOB, true), "firing")
	check(GameState.server_send_to_backroom(BOB, 30.0), "Bob is sent to the back room while firing")
	await wait_physics(3)
	check(not ft.firing and ft.holder_id == 0, "the flame is out and the flamethrower is back on the floor (holder %d)" % ft.holder_id)
	check(not ft.server_request_fire(BOB, true), "no fire request from the back room")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(2)


# =================================================================================================== R2

func _r2_arson_brake() -> void:
	step("R2: one cone pass over four workers stops at the third write-up (the back room)")
	await _reset_floor()
	_put(BOB, Vector3(-3.0, 0.0, 2.0), 0.0, -0.2)
	_put(1, Vector3(-3.55, 0.0, 0.2))
	_put(CHLOE, Vector3(-2.45, 0.0, 0.2))
	_put(DANA, Vector3(-3.0, 0.0, -0.5))
	_put(EVE, Vector3(-3.0, 0.0, -1.3))
	var ft := _flamethrower(BOB)
	await wait_physics(3)
	var b: BalanceConfig = Config.balance
	var bob := _worker(BOB)
	var in_cone := 0
	for id: int in [1, CHLOE, DANA, EVE]:
		if Flamethrower.point_in_cone(ft.get_cone_origin(), bob.get_look_direction(), _worker(id).get_chest_position(), b.flamethrower_range, b.flamethrower_half_angle_deg):
			in_cone += 1
	check(in_cone == 4, "four workers stand in Bob's cone (%d)" % in_cone)
	var money := GameState.money
	check(ft.server_request_fire(BOB, true), "Bob opens fire")
	ft._server_tick(1.0 / 60.0) # ONE pass of the cone
	await wait_frames(2)
	check(GameState.is_in_backroom(BOB), "three arson write-ups in one pass: Bob is in the back room")
	check(_ignites.size() == b.write_ups_to_backroom, "exactly %d workers were set on fire in that pass, not all four %s" % [b.write_ups_to_backroom, _ignites])
	check(_strikes(BOB) == 0, "no strike was booked on a worker already in the back room (strikes %d)" % _strikes(BOB))
	check(GameState.money == money - b.write_up_fine * b.write_ups_to_backroom, "the team paid %d fines, not four (cash %d -> %d)" % [b.write_ups_to_backroom, money, GameState.money])
	ft._server_tick(1.0 / 60.0)
	await wait_physics(2)
	check(not ft.firing and ft.holder_id == 0, "the flame is out, the flamethrower lies at Bob's spawn")
	var spawn: Vector3 = room.get_spawn_transform(bob.spawn_index).origin
	check(_flat(ft.global_position, spawn) < 1.0, "(%.1f m from it): the others can take it away during his 30 s" % _flat(ft.global_position, spawn))
	# The brake as a whole: a griefer gets three acts per back-room stay.
	await wait_until(func() -> bool: return not me.is_stunned() and me.can_be_staggered(), 4.0, "the host's own worker recovers")
	GameState.server_release_from_backroom(BOB)
	await wait_frames(2)


# =================================================================================================== R3

func _r3_turning_tray() -> void:
	step("R3: a turning tray is trouble on the floor (no misuse, no arson); scorching it cancels the mutation")
	await _reset_floor()
	var ns: SeedDef = Config.balance.get_seed(&"nightshift")
	ns.mutation_chance = 1.0
	var p2 := plot(2)
	_make_ready(p2, &"nightshift")
	Hostiles.tick(0.05)
	check(p2.is_turning() and p2.get_status_text() == "Moving" and not Hostiles.is_any_alive(), "GrowPlot 2 is moving, nothing is on the floor yet")
	# The worker who heard the warning runs to the cabinet.
	_put(1, cabinet.global_position + cabinet.global_basis.z * 1.2 - Vector3.UP * cabinet.global_position.y)
	await wait_physics(2)
	var money := GameState.money
	check(cabinet.server_break(me) and items.get_held_by(1) is Flamethrower, "glass broken during the warning")
	await wait_frames(1)
	check(_write_ups.is_empty(), "no misuse write-up: the tray was already moving %s" % [_write_ups])
	check(GameState.money == money - Config.balance.cabinet_deposit, "only the deposit was taken (%d -> %d)" % [money, GameState.money])
	# And burns the plant in its tray before it gets up.
	var scorched0 := GameState.get_stat(1, Const.STAT_SCORCHED)
	check(p2.server_scorch(1), "the moving plant is burnt in its tray")
	await wait_frames(3)
	check(_write_ups.is_empty(), "no arson write-up for burning a plant that was turning %s" % [_write_ups])
	check(GameState.get_stat(1, Const.STAT_SCORCHED) == scorched0 + 1, "STAT_SCORCHED still counts it")
	check(p2.stage == GrowPlot.Stage.EMPTY, "the tray is empty")
	_tick(Config.balance.mutation_warning_sec + 2.0)
	check(not p2.turning and Hostiles.count() == 0 and _spawned.is_empty(), "the mutation is cancelled: nothing came out of the empty tray")
	# Controls: with nothing moving and nothing alive both are still write-ups.
	ns.mutation_chance = 0.0
	cabinet.server_restock()
	items.server_despawn_item(items.get_held_by(1))
	await wait_frames(2)
	_write_ups.clear()
	check(cabinet.server_break(me), "glass broken with a quiet floor")
	await wait_frames(1)
	check(_write_ups.size() == 1 and _write_ups[0][1] == Const.WRITE_UP_MISUSE, "misuse write-up %s" % [_write_ups])
	check(toast_seen("Reviewer written up: misuse."), "and the floor is told what for: 'Reviewer written up: misuse.' %s" % [toasts])
	_make_ready(p2, &"nightshift")
	Hostiles.tick(0.05)
	check(not p2.turning, "a ready plant that did not turn")
	_write_ups.clear()
	check(p2.server_scorch(1), "burnt")
	await wait_frames(3)
	check(_write_ups.size() == 1 and _write_ups[0][1] == Const.WRITE_UP_ARSON, "arson write-up %s" % [_write_ups])
	check(toast_seen("Reviewer written up: arson."), "'Reviewer written up: arson.'")
	# A turning tray excuses the tray itself, not the rest of the row.
	Hostiles.tick(0.05) # the watch sees the tray empty (a new READY rolls again)
	ns.mutation_chance = 1.0
	_make_ready(p2, &"nightshift")
	Hostiles.tick(0.05)
	var p6 := plot(6)
	_make_growing(p6)
	_write_ups.clear()
	check(p2.is_turning() and p6.server_scorch(1), "another tray burnt while GrowPlot 2 is moving")
	await wait_frames(3)
	check(_write_ups.size() == 1 and _write_ups[0][1] == Const.WRITE_UP_ARSON, "that one is still arson %s" % [_write_ups])
	ns.mutation_chance = float(_chance[&"nightshift"])


# =================================================================================================== R4

func _r4_hostile_max() -> void:
	step("R4: hostile_max: the next plant that turns waits in its tray instead of vanishing")
	await _reset_floor()
	var b: BalanceConfig = Config.balance
	var ns: SeedDef = b.get_seed(&"nightshift")
	ns.mutation_chance = 1.0
	var parked: Array[HostilePlant] = []
	for i in b.hostile_max:
		parked.append(_hostile(Vector3(8.6, 0.0, 6.2 - 1.6 * i)))
	check(Hostiles.count() == b.hostile_max, "hostile_max (%d) plants on the floor" % b.hostile_max)
	var p1 := plot(1)
	_make_ready(p1, &"nightshift")
	Hostiles.tick(0.05)
	check(p1.is_turning(), "GrowPlot 1 turns")
	_spawned.clear()
	_tick(b.mutation_warning_sec + 3.0)
	check(Hostiles.count() == b.hostile_max and _spawned.is_empty(), "the floor is full: nothing new came out")
	check(p1.stage == GrowPlot.Stage.READY and p1.strain_id == &"nightshift", "the crop was not lost silently (stage %s)" % p1.get_stage_name())
	check(p1.is_turning() and p1.get_status_text() == "Moving" and p1.can_interact(me) == (items.get_held_by(1) == null), "it keeps twitching in its tray, still harvestable")
	# One of them burns: once its body is gone there is room, and the tray empties onto the floor.
	Hostiles.server_apply_fire(parked[0].id, b.hostile_burn_sec + 0.1, 1)
	check(parked[0].is_dead(), "one plant burnt down")
	_tick(HostilePlant.DEATH_DELAY + 1.0)
	await wait_frames(2)
	check(_spawned.size() == 1 and _spawned[0][1] == &"nightshift", "the waiting plant uprooted %s" % [_spawned])
	check(p1.stage == GrowPlot.Stage.EMPTY and not p1.turning and Hostiles.count() == b.hostile_max, "tray empty, %d on the floor again" % b.hostile_max)
	# Harvested while waiting: nothing comes out later.
	var p4 := plot(4)
	_make_ready(p4, &"nightshift")
	Hostiles.tick(0.05)
	_tick(b.mutation_warning_sec + 1.0)
	check(p4.is_turning() and p4.stage == GrowPlot.Stage.READY, "GrowPlot 4 waits its turn")
	_put(DANA, p4.global_position + Vector3(-1.2, 0.0, 0.0))
	check(p4.server_harvest(_worker(DANA)) and items.get_held_by(DANA) != null, "Dana harvests it while it waits")
	_spawned.clear()
	Hostiles.server_despawn_all()
	await wait_frames(1)
	_tick(2.0)
	check(_spawned.is_empty() and not p4.turning and p4.stage == GrowPlot.Stage.EMPTY, "nothing comes out of a harvested tray")
	ns.mutation_chance = float(_chance[&"nightshift"])


# =================================================================================================== R5

func _r5_escape_rules() -> void:
	step("R5a: no bite through the grow-area fence; a worker it cannot reach does not hold it off the trays")
	await _reset_floor()
	var p1 := plot(1)
	_make_growing(p1, &"budget", 0.95)
	# Fence7 is the plane x = 3 for z in [-5, -2.5]. Chloe stands 0.8 m outside it, the plant comes up inside.
	_put(CHLOE, Vector3(2.2, 0.0, -3.75))
	var h := _hostile(Vector3(3.8, 0.0, -3.75))
	check(h != null and _flat(h.global_position, _worker(CHLOE).global_position) < HostilePlant.BITE_RANGE, "a plant 1.6 m from Chloe, the fence between them")
	check(not _line_clear(h.global_position + Vector3.UP, _worker(CHLOE).get_chest_position(), h), "(the line between them is blocked)")
	_tick(HostilePlant.ROOT_SEC + 0.5)
	check(h.state == HostilePlant.State.CHASE and _bites.is_empty(), "it wants her (state %s) and cannot bite through the fence %s" % [h.get_state_name(), _bites])
	var t := _tick(8.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT and h.get_target_plot() == p1 and _bites.is_empty(), "after %.1f s it gave her up and eats GrowPlot 1 (state %s)" % [t, h.get_state_name()])
	var progress := p1.stage_progress
	_tick(3.0)
	check(h.state == HostilePlant.State.EAT and p1.stage_progress < progress - 0.15, "calm: she cannot pull it off the tray from behind the fence (%.2f -> %.2f)" % [progress, p1.stage_progress])

	step("R5b: a chase that cannot get closer is not a leash (the fence was a free safe spot)")
	await _reset_floor()
	_make_growing(p1, &"budget", 0.95)
	_put(CHLOE, Vector3(1.0, 0.0, -3.75)) # 2 m outside the fence: out of bite reach from the inside
	h = _hostile(Vector3(3.8, 0.0, -3.75))
	# Twenty seconds of her standing there: the plant used to spend all of them pressed against the fence.
	var eating := 0.0
	var total := 0.0
	while total < 20.0:
		Hostiles.tick(0.1)
		total += 0.1
		if h.state == HostilePlant.State.EAT:
			eating += 0.1
		if p1.stage == GrowPlot.Stage.EMPTY:
			break
	check(_bites.is_empty() and (p1.stage == GrowPlot.Stage.EMPTY or eating >= 9.0), "it ate for %.1f of %.1f s (tray %s), she was never in reach" % [eating, total, p1.get_stage_name()])

	step("R5c: a tray behind the fence: the plant outside finds the gate and eats")
	await _reset_floor()
	_make_growing(p1, &"budget", 0.95)
	h = _hostile(Vector3(1.5, 0.0, -3.0)) # due west of GrowPlot 1, Fence7 square in the way
	_tick(20.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT and h.get_target_plot() == p1, "it is eating GrowPlot 1 (state %s at %s)" % [h.get_state_name(), h.global_position])

	step("R5d: a calm plant does not walk through a worker")
	await _reset_floor()
	var p3 := plot(3)
	_make_growing(p3, &"budget", 0.95)
	h = _hostile(Vector3(-1.0, 0.0, 0.0))
	Hostiles.tick(HostilePlant.ROOT_SEC + 0.1)
	h._calm_left = 30.0 # as after its two bites: it ignores workers and heads for the trays
	_put(DANA, Vector3(1.2, 0.0, 0.0)) # square on its way to GrowPlot 3
	var dana := _worker(DANA)
	var nearest := [INF]
	_tick(10.0, func() -> bool:
		nearest[0] = minf(float(nearest[0]), _flat(h.global_position, dana.global_position))
		return h.state == HostilePlant.State.EAT)
	check(float(nearest[0]) >= 1.04, "it never overlapped Dana (closest %.2f m; the two bodies need 1.04)" % float(nearest[0]))
	_tick(12.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT, "and it still got to the tray (state %s at %s)" % [h.get_state_name(), h.global_position])

	step("R5e: a worker in a corner is let out after the two bites")
	await _reset_floor()
	var corner := Vector3(-9.6, 0.0, -7.1) # 0.4 m from the west and the north wall
	_put(EVE, corner)
	h = _hostile(Vector3(-7.4, 0.0, -4.9))
	await _tick_real(12.0, func() -> bool: return _bites.size() >= HostilePlant.BITES_BEFORE_CALM and h.state == HostilePlant.State.ROAM)
	check(_bites.size() == HostilePlant.BITES_BEFORE_CALM, "two bites in the corner %s" % [_bites])
	var pinned := _flat(h.global_position, corner)
	check(pinned <= HostilePlant.BITE_RANGE + 0.05, "(the plant stood %.2f m off, between her and the room)" % pinned)
	_tick(2.5)
	var after := _flat(h.global_position, corner)
	check(after >= pinned + 1.5, "calm: it walked away from her (%.2f m -> %.2f m) instead of wandering at random, the corner is open" % [pinned, after])
	check(_bites.size() == HostilePlant.BITES_BEFORE_CALM, "no third bite while calm")

	step("R5f: a plant out of the tray by the east wall gets to the far tray; nothing to eat: it wanders, never stuck")
	await _reset_floor()
	var p6 := plot(6)
	_make_growing(p6, &"budget", 0.95)
	h = _hostile(plot(2).global_position) # GrowPlot 2: the north-east tray, the wall 2.4 m behind it
	_tick(14.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT and h.get_target_plot() == p6, "it walked the east row and eats GrowPlot 6 (state %s at %s)" % [h.get_state_name(), h.global_position])
	p6.server_reset()
	# Nobody on the floor (the back room is no prey): a plant that strays near a worker would stand and wait on the
	# REAL stagger clock while this loop runs simulated minutes.
	for id: int in [1, BOB, CHLOE, DANA, EVE]:
		GameState.server_send_to_backroom(id, 600.0)
	await wait_frames(2)
	var bounds := room.get_bounds().grow(-0.3)
	var inside := true
	var travelled := 0.0
	var still := 0.0
	var longest_still := 0.0
	var last := h.global_position
	for i in 1800: # three minutes of wandering with nothing to eat and nobody near
		Hostiles.tick(0.1)
		var d := _flat(h.global_position, last)
		travelled += d
		last = h.global_position
		still = still + 0.1 if d < 0.001 else 0.0
		longest_still = maxf(longest_still, still)
		if not bounds.has_point(h.global_position + Vector3.UP):
			inside = false
	# A wander target on the far side of a fence used to hold it there for good (until a worker came near).
	check(inside and longest_still < 10.0 and travelled > 60.0, "three minutes of wandering: %.0f m walked, never still for more than %.1f s, always inside the room" % [travelled, longest_still])
	check(h.state == HostilePlant.State.ROAM and _bites.is_empty(), "(nobody on the floor: it only ever roamed)")


# =================================================================================================== R6

func _r6_tray_gone_under_it() -> void:
	step("R6: a tray harvested or scorched under an eating plant")
	await _reset_floor()
	var p3 := plot(3)
	_make_growing(p3, &"budget", 0.95)
	var h := _hostile(p3.global_position + Vector3(-2.0, 0.0, 0.0))
	_tick(8.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT, "eating GrowPlot 3")
	check(p3.server_scorch(0), "the tray is scorched under it")
	await wait_frames(3)
	_tick(0.5)
	check(h.state != HostilePlant.State.EAT and _ate.is_empty(), "it stops eating; nothing counted as eaten %s" % [_ate])
	_make_growing(p3, &"budget", 0.95)
	_tick(8.0, func() -> bool: return h.state == HostilePlant.State.EAT)
	check(h.state == HostilePlant.State.EAT, "eating the replanted tray")
	p3.stage = GrowPlot.Stage.READY # it ripened under its mouth
	_put(DANA, Vector3(-8.0, 0.0, -6.0))
	check(p3.server_harvest(null), "harvested under it (the product drops in front of the tray)")
	_tick(0.5)
	check(h.state != HostilePlant.State.EAT and _ate.is_empty() and p3.stage == GrowPlot.Stage.EMPTY, "it stops eating, the tray is simply empty")
	var loose := items_of(Const.ITEM_PRODUCT)
	check(loose.size() == 1 and int(loose[0].get_props().get("amount", 0)) == 1, "the harvest is intact")


# =================================================================================================== R7

func _r7_shortage_and_headcount() -> void:
	var b: BalanceConfig = Config.balance
	step("R7a: a shortage never hits a strain nobody could buy")
	await _reset_floor()
	Events._planted.clear()
	var dearest: SeedDef = null
	var cheapest: SeedDef = null
	for s in b.seeds:
		if dearest == null or s.cost > dearest.cost:
			dearest = s
		if cheapest == null or s.cost < cheapest.cost:
			cheapest = s
	GameState.server_add_money(50 - GameState.money)
	check(GameState.money == 50, "cash on hand $50, nothing planted this shift")
	var pick: SeedDef = b.get_seed(Events.pick_shortage_strain())
	check(pick != null and pick.cost <= GameState.money, "the shortage hits a strain the team could buy (%s, $%d), not %s ($%d)" % [pick.display_name, pick.cost, dearest.display_name, dearest.cost])
	var best_affordable := 0
	for s in b.seeds:
		if s.cost <= 50:
			best_affordable = maxi(best_affordable, s.cost)
	check(pick.cost == best_affordable, "the dearest one they could afford ($%d)" % best_affordable)
	GameState.server_add_money(-GameState.money)
	check(GameState.money == 0 and Events.pick_shortage_strain() == cheapest.id, "broke: the cheapest strain (%s), the next one they would buy" % cheapest.display_name)
	GameState.server_add_money(2000)
	check(Events.pick_shortage_strain() == dearest.id, "flush: the dearest strain, as before (%s)" % dearest.display_name)
	Events._planted = {&"budget": 2, &"brick": 1}
	GameState.server_add_money(-GameState.money)
	check(Events.pick_shortage_strain() == &"budget", "planted this shift: the most-planted strain, whatever the cash")
	Events._planted.clear()
	GameState.server_add_money(500)

	step("R7b: the head count only counts workers who were on the floor when it began")
	await _reset_floor()
	var spot := room.get_headcount_spot()
	_put(1, spot + Vector3(0.6, 0.0, 0.8))
	_put(BOB, spot + Vector3(-0.6, 0.0, 0.8))
	_put(CHLOE, Vector3(-8.0, 0.0, 5.0))            # on the floor, not on the line: absent
	check(GameState.server_send_to_backroom(DANA, 5.0), "Dana sits in the back room when the count begins")
	_drop_worker(EVE)
	await wait_frames(2)
	check(world.get_player(EVE) == null, "Eve is not in the session yet")
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "head count")
	GameState.server_release_from_backroom(DANA)   # let out mid-count: she is put at her spawn, 4 m from the line
	_add_worker(EVE)                               # joins mid-count: her body appears at a spawn point
	await wait_frames(3)
	check(not GameState.is_in_backroom(DANA) and world.get_player(EVE) != null, "Dana released, Eve joined, both off the line")
	check(_flat(_worker(DANA).global_position, spot) > b.headcount_radius and _flat(_worker(EVE).global_position, spot) > b.headcount_radius, "(both further than headcount_radius)")
	_write_ups.clear()
	var absent := Events.server_headcount()
	check(absent == [CHLOE], "only Chloe is written up as absent %s" % [absent])
	check(_write_ups.size() == 1 and _write_ups[0][0] == CHLOE and _write_ups[0][1] == Const.WRITE_UP_ABSENT, "one absent write-up %s" % [_write_ups])
	check(toast_seen("Chloe written up: absent."), "'Chloe written up: absent.'")
	Events.server_end_event()
	await wait_frames(2)
	# The next count has them on the roster like everybody else.
	check(Events.server_start_event(Events.EVENT_HEADCOUNT), "the next head count")
	absent = Events.server_headcount()
	absent.sort()
	check(absent == [CHLOE, DANA, EVE], "everyone off the line is absent this time %s" % [absent])
	Events.server_end_event()

	step("R7c: nobody can stand inside the radius behind a wall")
	# The line is in the open: every spot within headcount_radius of it that a worker's body fits on has a clear
	# line (LAYER_WORLD) to the Boss's eyes at the post. The only walls in reach are the counter front and the booth.
	var hidden := 0
	var probed := 0
	var space := world.get_world_3d().direct_space_state
	var eyes := spot + Vector3.UP * 1.6
	var shape := CapsuleShape3D.new()
	shape.radius = 0.38
	shape.height = 1.7
	var r := b.headcount_radius
	var x := -r
	while x <= r:
		var z := -r
		while z <= r:
			if Vector2(x, z).length() <= r:
				var feet := spot + Vector3(x, 0.0, z)
				var params := PhysicsShapeQueryParameters3D.new()
				params.shape = shape
				params.transform = Transform3D(Basis.IDENTITY, feet + Vector3.UP * 0.95)
				params.collision_mask = Const.LAYER_WORLD
				if space.intersect_shape(params, 1).is_empty():
					probed += 1
					var q := PhysicsRayQueryParameters3D.create(eyes, feet + Vector3.UP * 1.0, Const.LAYER_WORLD)
					if not space.intersect_ray(q).is_empty():
						hidden += 1
			z += 0.25
		x += 0.25
	check(probed > 100 and hidden == 0, "%d standing spots inside the radius, %d of them out of his sight" % [probed, hidden])
	check(_flat(room.get_backroom_transform(0).origin, spot) > r, "the back room itself is outside the radius (and excused)")


# =================================================================================================== R8

func _r8_churn() -> void:
	var b: BalanceConfig = Config.balance
	step("R8a: the holder disconnects while firing")
	await _reset_floor()
	_put(BOB, Vector3(-3.0, 0.0, 4.0), PI)
	var ft := _flamethrower(BOB)
	await wait_physics(2)
	check(ft.server_request_fire(BOB, true) and ft.firing, "Bob fires")
	_drop_worker(BOB)
	await wait_physics(3)
	check(is_instance_valid(ft) and not ft.firing and ft.holder_id == 0 and not ft.is_flying(), "Bob left: the flame is out, the flamethrower lies on the floor")
	check(ft.fuel > 0.0 and room.get_bounds().grow(-0.05).has_point(ft.global_position + Vector3.UP * 0.5), "inside the room, fuel kept (%.1f s)" % ft.fuel)
	_add_worker(BOB)
	await wait_frames(3)

	step("R8b: the back room while being chased / while holding the flamethrower")
	await _reset_floor()
	_put(CHLOE, Vector3(0.0, 0.0, 2.0))
	var h := _hostile(Vector3(3.0, 0.0, 2.0))
	_tick(HostilePlant.ROOT_SEC + 0.3)
	check(h.state == HostilePlant.State.CHASE and h.get_target_index() == CHLOE, "the plant chases Chloe")
	check(GameState.server_send_to_backroom(CHLOE, 30.0), "Chloe is sent to the back room mid-chase")
	await wait_frames(2)
	_tick(0.5)
	check(h.state != HostilePlant.State.CHASE and h.state != HostilePlant.State.BITE and h.get_target_index() != CHLOE, "the chase is dropped (state %s)" % h.get_state_name())
	_tick(6.0)
	check(_bites.is_empty() and _flat(h.global_position, room.get_backroom_transform(0).origin) > 2.0, "nobody in the back room is bitten")
	GameState.server_release_from_backroom(CHLOE)
	await wait_frames(2)

	step("R8c: the flamethrower thrown at the chute, at the booth and out of the room")
	await _reset_floor()
	var turnin := station("TurnInStation") as TurnInStation
	ft = _flamethrower(1)
	await wait_physics(2)
	var money := GameState.money
	var sales := GameState.round_sales
	var mouth := turnin.get_mouth_position()
	check(items.server_throw_item(ft, mouth + Vector3(0.0, 0.4, -2.0), Vector3(0.0, 0.5, 5.0), 1), "thrown into the chute")
	await wait_until(func() -> bool: return not ft.is_flying(), 4.0, "it comes down")
	check(is_instance_valid(ft) and not ft.is_queued_for_deletion() and GameState.money == money and GameState.round_sales == sales, "not sold: no cash, no sale, still an item")
	check(room.get_bounds().grow(-0.05).has_point(ft.global_position + Vector3.UP * 0.5), "it rests inside the room %s" % ft.global_position)
	check(items.server_throw_item(ft, Vector3(0.0, 1.6, -3.0), Vector3(0.0, 4.0, -9.0), 1), "thrown at the pay window")
	await wait_until(func() -> bool: return not ft.is_flying(), 4.0, "it comes down")
	var rest := ft.global_position
	check(not (absf(rest.x) < 2.06 and rest.z < -5.2), "it did not end up inside the Boss's booth %s" % rest)
	# Past the Boss, over the counter (the pay window has no collider above 1.04 m) and lobbed over the partition.
	for throw: Array in [[Vector3(1.25, 1.6, -3.0), Vector3(0.0, 4.0, -9.0)], [Vector3(-1.2, 1.6, -3.2), Vector3(0.0, 3.0, -7.0)],
			[Vector3(-4.0, 1.6, -4.0), Vector3(4.5, 8.0, -3.5)], [Vector3(0.0, 1.6, -1.0), Vector3(0.0, 8.4, -5.8)]]:
		check(items.server_throw_item(ft, throw[0], throw[1], 1), "thrown from %s at %s" % [throw[0], throw[1]])
		await wait_until(func() -> bool: return not ft.is_flying(), 5.0, "it comes down")
		rest = ft.global_position
		check(not (absf(rest.x) < 2.06 and rest.z < -5.2), "it did not end up inside the Boss's booth %s" % rest)
	var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
	check(items.server_throw_item(can, Vector3(1.25, 1.6, -3.0), Vector3(0.0, 4.0, -9.0), 1), "a watering can thrown past the Boss")
	await wait_until(func() -> bool: return not can.is_flying(), 5.0, "it comes down")
	check(not room.is_in_booth(can.global_position) and can.global_position.z > -5.0, "the can is still on the workers' side of the counter %s" % can.global_position)
	check(room.is_in_booth(room.get_backroom_transform(0).origin) and not room.is_in_booth(room.get_headcount_spot()) and not room.is_in_booth(Vector3(-3.0, 0.0, -6.9)),
			"Room.is_in_booth: the back-room spot is inside; the line and the floor west of the partition are not")
	check(items.server_throw_item(ft, Vector3(0.0, 2.0, 0.0), Vector3(40.0, 30.0, 40.0), 1), "thrown at 64 m/s into the far corner")
	await wait_until(func() -> bool: return not ft.is_flying(), 5.0, "it comes down")
	check(room.get_bounds().grow(-0.05).has_point(ft.global_position + Vector3.UP * 0.5) and ft.global_position.is_finite(), "still inside the room %s" % ft.global_position)

	step("R8d: two flamethrowers")
	await _reset_floor()
	_put(BOB, Vector3(-3.0, 0.0, 2.0), 0.0, -0.2)
	_put(DANA, Vector3(-3.0, 0.0, -2.0), PI, -0.2)
	_put(CHLOE, Vector3(-3.0, 0.0, 0.0))
	var ft_a := _flamethrower(BOB)
	var ft_b := _flamethrower(DANA)
	await wait_physics(2)
	check(ft_a.server_request_fire(BOB, true) and ft_b.server_request_fire(DANA, true), "Bob and Dana both fire at Chloe")
	ft_a._server_tick(1.0 / 60.0)
	ft_b._server_tick(1.0 / 60.0)
	await wait_frames(2)
	check(_ignites.size() == 2 and _strikes(BOB) == 1 and _strikes(DANA) == 1, "each flamethrower ignites her once, each shooter is written up %s" % [_ignites])
	for i in 30:
		ft_a._server_tick(1.0 / 60.0)
		ft_b._server_tick(1.0 / 60.0)
	check(_ignites.size() == 2, "and not again within the ten seconds")
	check(ft_a.fuel < b.flamethrower_fuel_sec and ft_b.fuel < b.flamethrower_fuel_sec and is_equal_approx(ft_a.fuel, ft_b.fuel), "both tanks drain on their own (%.1f / %.1f s)" % [ft_a.fuel, ft_b.fuel])
	ft_a.server_request_fire(BOB, false)
	ft_b.server_request_fire(DANA, false)

	step("R8e: the shift ends with a plant alive, a flame on, a head count running and a tray turning")
	await _reset_floor()
	var ns: SeedDef = b.get_seed(&"nightshift")
	ns.mutation_chance = 1.0
	var p5 := plot(5)
	_make_ready(p5, &"nightshift")
	Hostiles.tick(0.05)
	h = _hostile(Vector3(8.6, 0.0, 6.0))
	_put(BOB, Vector3(-3.0, 0.0, 4.0), PI)
	ft = _flamethrower(BOB)
	await wait_physics(2)
	check(Events.server_start_event(Events.EVENT_HEADCOUNT) and ft.server_request_fire(BOB, true) and p5.is_turning() and Hostiles.is_any_alive(), "all four at once")
	_write_ups.clear()
	_spawned.clear()
	GameState.time_left = 0.0
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "shift over")
	await wait_physics(3)
	check(Hostiles.count() == 0, "the plant is gone with the shift")
	check(not ft.firing and not ft.server_request_fire(BOB, true), "the flame is out and stays out")
	check(not Events.is_event_active() and _write_ups.is_empty(), "the head count ended, nobody was written up for a count that never finished")
	_tick(b.mutation_warning_sec + 2.0)
	check(Hostiles.count() == 0 and _spawned.is_empty(), "the turning tray does not uproot between shifts")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "RETRY -> WAITING")
	await wait_frames(4)
	Hostiles.tick(0.05)
	check(p5.stage == GrowPlot.Stage.EMPTY and not p5.turning, "RETRY: the tray is reset, the twitch is gone")
	check(items_of(Const.ITEM_FLAMETHROWER).is_empty() and not cabinet.broken, "RETRY: flamethrowers gone, cabinet stocked")
	ns.mutation_chance = float(_chance[&"nightshift"])

	step("R8f: back to the menu in the middle of all of it")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "next shift")
	ns.mutation_chance = 1.0
	_make_ready(p5, &"nightshift")
	Hostiles.tick(0.05)
	_put(CHLOE, Vector3(0.0, 0.0, 2.0))
	h = _hostile(Vector3(3.0, 0.0, 2.0))
	_tick(HostilePlant.ROOT_SEC + 0.3)
	ft = _flamethrower(BOB)
	await wait_physics(2)
	check(ft.server_request_fire(BOB, true) and h.state == HostilePlant.State.CHASE and p5.is_turning() and Events.server_start_event(Events.EVENT_SHORTAGE), "a chase, a flame, a turning tray and a shortage")
	ns.mutation_chance = float(_chance[&"nightshift"])
	Hostiles.set_physics_process(true)
	Game.return_to_menu()
	await wait_frames(5)
	check(Game.world == null and GameState.phase == GameState.Phase.MENU and not Game.is_ui_locked(), "menu: world gone, no UI lock")
	check(Hostiles.count() == 0 and not Events.is_event_active(), "menu: no hostiles, no event")
	var leftovers := []
	for n in get_tree().root.find_children("*", "", true, false):
		if (n is HostilePlant or n is Flamethrower) and not n.is_queued_for_deletion():
			leftovers.append(str(n.get_path()))
	check(leftovers.is_empty(), "menu: no hostile or flamethrower node left %s" % [leftovers])
	check(int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)) == 0, "menu: no orphan nodes")
	Hostiles.tick(1.0) # off the host: a no-op, no error
	check(Hostiles.server_spawn(&"budget", Vector3.ZERO) == 0, "menu: nothing spawns without a world")


# =================================================================================================== R9

func _r9_cabinet() -> void:
	var b: BalanceConfig = Config.balance
	step("R9: the cabinet under hostile inputs")
	await _reset_floor()
	# From across the room (15 m): the base Interactable range check stands in front of server_break.
	_put(1, Vector3(8.0, 0.0, 5.0))
	await wait_physics(2)
	var money := GameState.money
	cabinet._rpc_request_interact()
	await wait_frames(1)
	check(not cabinet.broken and GameState.money == money and items_of(Const.ITEM_FLAMETHROWER).is_empty() and toast_seen("Too far."), "a request from 18 m away is refused: 'Too far.' %s" % [toasts])
	# Five requests in one frame from a worker standing at it: one flamethrower, one deposit.
	_put(1, cabinet.global_position + cabinet.global_basis.z * 1.2 - Vector3.UP * cabinet.global_position.y)
	await wait_physics(2)
	var h := _hostile(Vector3(8.6, 0.0, 6.0)) # something alive: breaking the glass is not misuse
	toasts.clear()
	for i in 5:
		cabinet._rpc_request_interact()
	await wait_frames(2)
	check(items_of(Const.ITEM_FLAMETHROWER).size() == 1 and GameState.money == money - b.cabinet_deposit, "five requests in a frame: one flamethrower, one deposit (%d -> %d)" % [money, GameState.money])
	check(_write_ups.is_empty() and h != null, "no write-up with a plant alive")
	# Two workers in the same frame on a stocked cabinet: one wins, the other is told why.
	cabinet.server_restock()
	items.server_despawn_item(items.get_held_by(1))
	await wait_frames(2)
	_put(BOB, cabinet.global_position + cabinet.global_basis.z * 1.2 + Vector3(0.0, -cabinet.global_position.y, 0.8))
	money = GameState.money
	var got_me := cabinet.server_break(me)
	var got_bob := cabinet.server_break(_worker(BOB))
	check(got_me and not got_bob and items_of(Const.ITEM_FLAMETHROWER).size() == 1 and GameState.money == money - b.cabinet_deposit, "two workers in one frame: one flamethrower, one deposit")
	check(cabinet.restock_left == ceili(b.cabinet_restock_sec), "restock countdown armed (%d s)" % cabinet.restock_left)
	# Cash short by one: refused, nothing taken.
	cabinet.server_restock()
	items.server_despawn_item(items.get_held_by(1))
	await wait_frames(2)
	GameState.server_add_money(b.cabinet_deposit - 1 - GameState.money)
	toasts.clear()
	cabinet._rpc_request_interact()
	await wait_frames(1)
	check(not cabinet.broken and GameState.money == b.cabinet_deposit - 1 and toast_seen(EmergencyCabinet.REASON_CASH_SHORT), "one dollar short: refused, cash untouched %s" % [toasts])
	GameState.server_add_money(500)


# =================================================================================================== R10

func _r10_copy_audit() -> void:
	step("R10: copy tone of every M12 string")
	var checked := 0
	var bad: PackedStringArray = []
	for dict: Dictionary in [Story.HOSTILE_LINES, Story.FLAME_LINES, Story.DISRUPT_LINES]:
		for key: Variant in dict:
			checked += 1
			_audit(String(dict[key]), "Story.%s" % key, bad)
			if not Story.lines.has(key):
				bad.append("Story.lines lacks '%s'" % key)
	for id: String in ["nightshift", "creeper", "brick"]:
		checked += 2
		_audit(String(Story.blurbs.get(id, "")), "blurb %s" % id, bad)
		var def: SeedDef = Config.balance.get_seed(StringName(id))
		_audit(def.description, "description %s" % id, bad)
		_audit(def.display_name, "name %s" % id, bad)
		if String(Story.blurbs.get(id, "")) == "":
			bad.append("no blurb for %s" % id)
	# Whole files: the M12-only ones get the vocabulary check too; the shared ones (their older strings were audited by
	# the M11 review) are checked for "!" and cheer, plus the vocabulary on the M12 banner texts (TEXT_EVENT_*).
	var scripts := {
		"cabinet": ["res://scripts/stations/emergency_cabinet.gd", true], "flamethrower": ["res://scripts/items/flamethrower.gd", true],
		"hostile": ["res://scripts/npcs/hostile_plant.gd", true], "well": ["res://scripts/stations/well.gd", false],
		"shop": ["res://scripts/stations/shop_counter.gd", false], "grow_plot": ["res://scripts/stations/grow_plot.gd", false],
		"hud": ["res://scripts/ui/hud.gd", false], "story": ["res://scripts/core/story.gd", false],
	}
	for tag: String in scripts:
		var s := load(scripts[tag][0]) as GDScript
		var consts := s.get_script_constant_map()
		for key: Variant in consts:
			var v: Variant = consts[key]
			var vocab: bool = bool(scripts[tag][1]) or String(key).begins_with("TEXT_EVENT_")
			if v is String:
				checked += 1
				_audit(String(v), "%s.%s" % [tag, key], bad, vocab)
			elif v is Array:
				for e: Variant in v:
					if e is String:
						checked += 1
						_audit(String(e), "%s.%s" % [tag, key], bad, vocab)
	# Prompts as the worker reads them.
	var ft := _flamethrower(0, 0.0)
	var prompts: Array[String] = [
		cabinet.get_prompt(me), EmergencyCabinet.PROMPT_RESTOCKING % 42, ft.get_label_text(), ft.get_prompt(me),
		(station("Well") as Well).get_prompt(me), Well.PROMPT_NO_PRESSURE, ShopCounter.REASON_OUT_OF_STOCK,
		HUD.TEXT_EVENT_SHORTAGE_HINT % "Night Shift", "Buy supplies · %s out of stock" % "Night Shift",
	]
	for text in prompts:
		checked += 1
		_audit(text, "prompt", bad)
	items.server_despawn_item(ft)
	check(checked > 60 and bad.is_empty(), "%d strings: no exclamation marks, no cheer, house vocabulary %s" % [checked, bad])
	# Denials read like the rest of the game: a full stop on every toast. (Well.PROMPT_NO_PRESSURE is the exception
	# the disrupt suites pin literally; see the review report.)
	var toasts_m12: Array[String] = [EmergencyCabinet.REASON_CASH_SHORT, EmergencyCabinet.REASON_HANDS_FULL, EmergencyCabinet.REASON_UNAVAILABLE,
			ShopCounter.REASON_OUT_OF_STOCK]
	var unstopped: PackedStringArray = []
	for text in toasts_m12:
		if not text.ends_with("."):
			unstopped.append(text)
	check(unstopped.is_empty(), "every M12 denial toast ends with a full stop like the M1-M11 ones %s" % [unstopped])


func _audit(text: String, where: String, bad: PackedStringArray, vocabulary: bool = true) -> void:
	if text.contains("!"):
		bad.append("%s has '!': %s" % [where, text])
	var lower := text.to_lower()
	for w in CHEER_WORDS:
		if lower.contains(w):
			bad.append("%s cheers (%s): %s" % [where, w, text])
	# Vocabulary: whole words in real copy only (paths and identifiers are not copy).
	if not vocabulary or text.contains("/") or text.contains("_"):
		return
	var re := RegEx.new()
	for w in OFF_VOCABULARY:
		re.compile("\\b%ss?\\b" % w)
		if re.search(lower) != null:
			bad.append("%s says '%s': %s" % [where, w, text])


# =================================================================================================== R11

func _r11_numbers() -> void:
	step("R11: the M12 numbers hold together (structure, not tuning)")
	var b: BalanceConfig = Config.balance
	var ids := {}
	var ok := true
	for s in b.seeds:
		ids[s.id] = true
		var gross := s.yield_amount * s.sale_value_per_unit
		var grow := b.total_grow_time(s)
		# Even after its mutation risk a strain must pay for its own seed, and it must ripen inside one shift.
		if not (s.mutation_chance >= 0.0 and s.mutation_chance <= 1.0 and gross * (1.0 - s.mutation_chance) > s.cost and grow < b.round_length_sec):
			ok = false
			print("      strain %s: cost %d gross %d mutation %.2f grow %.0f s" % [s.id, s.cost, gross, s.mutation_chance, grow])
	check(ids.size() == b.seeds.size() and ok, "%d strains: unique ids, expected return above the seed's cost, ripe within a shift" % b.seeds.size())
	check(b.flamethrower_fuel_sec >= b.hostile_burn_sec * b.hostile_max, "one tank (%.0f s) can burn hostile_max plants (%d x %.0f s)" % [b.flamethrower_fuel_sec, b.hostile_max, b.hostile_burn_sec])
	check(b.cabinet_deposit + b.write_up_fine <= b.starting_money and b.cabinet_restock_sec < b.round_length_sec, "the deposit (+ one fine) fits the starting cash; the cabinet restocks within a shift")
	check(b.hostile_speed < b.walk_speed and b.hostile_sense_range > HostilePlant.BITE_RANGE and HostilePlant.BITE_RANGE > HostilePlant.CHASE_STOP, "a walking worker outruns the plant (%.1f < %.1f m/s); sense > bite > stop distance" % [b.hostile_speed, b.walk_speed])
	check(HostilePlant.CHASE_STOP > 0.64 + 0.4, "the plant stops short of its target's body (%.2f m > 1.04 m)" % HostilePlant.CHASE_STOP)
	var far := maxf(room.get_headcount_spot().distance_to(Vector3(10.0, 0.0, 7.5)), room.get_headcount_spot().distance_to(Vector3(-10.0, 0.0, 7.5)))
	check(far / b.walk_speed < b.headcount_sec * 0.5, "the line is a %.1f s walk from the far corner, the head count gives %.0f s" % [far / b.walk_speed, b.headcount_sec])
	check(b.water_off_sec < (1.0 - b.dry_threshold) / b.water_drain_per_sec, "a watered tray outlasts one water-off (%.0f s < %.0f s)" % [b.water_off_sec, (1.0 - b.dry_threshold) / b.water_drain_per_sec])
	check(b.mutation_warning_sec >= 4.0 and b.scorch_sec < b.mutation_warning_sec, "the warning (%.0f s) leaves time to harvest or burn the plant" % b.mutation_warning_sec)
	var weights := 0
	for k: Variant in Events.WEIGHTS:
		weights += int(Events.WEIGHTS[k])
	check(weights == 100 and Events.KINDS.size() == Events.WEIGHTS.size(), "event weights sum to 100 over %d kinds" % Events.KINDS.size())
