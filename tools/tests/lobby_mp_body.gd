extends "res://tools/tests/qa_base.gd"
## M14 lobby multi-process suite (lobby agent), driven by tools/tests/lobby_mp.sh: a host, clients A and B (join in
## the alley) and client C (joins DURING the first shift). Every process runs with --lobby.
##   host: waits in the alley for A and B, gets in the van last (the countdown, the ride), prints LOBBY_MP_PLAYING
##         (the shell starts C), ends shift 1 paid -> NEXT SHIFT (everyone back in the alley, round 2), leaves with
##         Enter while nobody is in the van (the override), lets shift 2 fail -> START OVER (alley, round 1), gets in
##         once A, B and C are in; C drops out of the session during that countdown and the van leaves with three.
##   a, b: spawn in the alley, read the synced head count, get in, see the countdown / the fade / the doors, end up at
##         their dock arrival in PLAYING, are back in the alley after NEXT SHIFT and after START OVER with the host's
##         numbers, ride again, leave.
##   c:    joins mid-shift: lands at its dock arrival, never in the alley; follows both ways back; gets in the van
##         for the last ride and leaves the session while the doors are closing.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0
const SPOT_TOLERANCE := 0.4
const DOCK_TOLERANCE := 1.0
const SEATS := {"host": 0, "a": 1, "b": 2, "c": 3}

var role: String = "host"
var port: int = 7967
var _transitions: Array = []   # [kind, seconds]
var _seen: int = 0             # transitions this process has already waited for
var _rounds: Array = []
var _counting_seen: int = 0    # van updates that said "counting"
var _world: World
var _room: Room
var _lobby: Lobby
var _van: Van
var _hud: HUD


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7967))
	_label = "lobby_mp:" + role
	await get_tree().process_frame
	GameState.transition_started.connect(func(kind: StringName, seconds: float) -> void: _transitions.append([kind, seconds]))
	GameState.round_started.connect(func(n: int) -> void: _rounds.append(n))
	check(Config.lobby_enabled, "%s runs with the lobby on (--lobby)" % role)
	match role:
		"host": await _host()
		"a", "b": await _client()
		"c": await _late_client()
	finish()


# --- host --------------------------------------------------------------------------------------------------------------

func _host() -> void:
	var b: BalanceConfig = Config.balance
	step("hosting on %d" % port)
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		return
	_bind()
	var me: Player = Game.local_player
	check(_lobby.contains_point(me.global_position), "host: spawned in the alley")
	print("LOBBY_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and _world.get_players().size() >= 3, JOIN_TIMEOUT, "A and B registered and spawned")
	await wait_until(func() -> bool: return _everyone(_in_alley), 3.0, "host: every body is in the alley")
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and _van.total == 3, 2.0, "host: WAITING, the van counts three workers")
	step("host: the clients get in first")
	await wait_until(func() -> bool: return _van.occupants == 2, STEP_TIMEOUT, "host: A and B are in (2 / 3)")
	await wait_sec(0.6)
	check(not _van.is_counting() and _transitions.is_empty() and _hud.get_lobby_text() == "Everyone in the van. 2 / 3 in.", "host: no countdown while the host is outside ('%s')" % _hud.get_lobby_text())
	_get_in()
	await wait_until(func() -> bool: return _van.is_counting(), 2.0, "host: everyone in, the countdown runs")
	await _await_transition(GameState.TRANSITION_TO_FLOOR, "host", b.van_countdown_sec + 1.5)
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "host: PLAYING")
	await wait_until(func() -> bool: return _everyone(_at_dock), 3.0, "host: all three stand at their dock arrival")
	check(_rounds == [1] and GameState.round_number == 1, "host: shift 1 started once")
	print("LOBBY_MP_PLAYING")

	step("host: C joins during the shift")
	await wait_until(func() -> bool: return Net.players.size() >= 4 and _world.get_players().size() >= 4, JOIN_TIMEOUT, "C registered and spawned")
	await wait_until(func() -> bool: return _everyone(_at_dock), 3.0, "host: C's body is at the dock too")
	await wait_sec(1.5)
	GameState.server_add_sale(GameState.quota, 1)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "host: shift 1 paid")
	await wait_sec(0.8)
	var money := GameState.money
	GameState.request_next_round()
	await _await_transition(GameState.TRANSITION_TO_LOBBY, "host", 1.0)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "host: WAITING")
	check(GameState.round_number == 2 and GameState.money == money and GameState.quota == GameState.get_quota_for(2), "host: round 2, the money kept, the next payment")
	await wait_until(func() -> bool: return _everyone(_in_alley_spot), 4.0, "host: all four are back at their alley spawn")
	await wait_until(func() -> bool: return _van.total == 4 and _van.occupants == 0, 2.0, "host: the van counts 0 / 4")

	step("host: Enter with nobody in the van")
	await wait_sec(1.5)
	GameState.request_start_round()
	await _await_transition(GameState.TRANSITION_TO_FLOOR, "host", 1.0)
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "host: PLAYING")
	check(_rounds == [1, 2] and GameState.round_number == 2, "host: shift 2")
	await wait_until(func() -> bool: return _everyone(_at_dock), 4.0, "host: all four at the dock, stragglers included")

	step("host: shift 2 fails, start over")
	await wait_sec(1.5)
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "host: ROUND_FAILED")
	await wait_sec(0.8)
	GameState.request_retry()
	await _await_transition(GameState.TRANSITION_TO_LOBBY, "host", 1.0)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 3.0, "host: WAITING")
	check(GameState.round_number == 1 and GameState.money == b.starting_money and GameState.upgrades.is_empty(), "host: round 1, starting money")
	await wait_until(func() -> bool: return _everyone(_in_alley), 4.0, "host: all four are in the alley again")

	step("host: the last ride, C drops out during the countdown")
	await wait_until(func() -> bool: return _van.total == 4 and _van.occupants == 3, STEP_TIMEOUT, "host: A, B and C are in (3 / 4)")
	_get_in()
	await wait_until(func() -> bool: return _van.is_counting(), 2.0, "host: the countdown runs")
	var t0 := Time.get_ticks_msec()
	# C leaves on its own when it sees the countdown; ENet may still flush a packet to it.
	allow_error("Unable to send packet on channel 0", 2, true)
	await _await_transition(GameState.TRANSITION_TO_FLOOR, "host", b.van_countdown_sec + 2.0)
	var waited := (Time.get_ticks_msec() - t0) / 1000.0
	check(waited < b.van_countdown_sec + 0.5, "host: the countdown was not restarted by the departure (%.2f s)" % waited)
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "host: PLAYING")
	await wait_until(func() -> bool: return Net.players.size() == 3 and _world.get_players().size() == 3, 5.0, "host: three workers left in the session")
	await wait_until(func() -> bool: return _everyone(_at_dock), 4.0, "host: the three who stayed stand at the dock")
	check(_van.total <= 3 and _van.occupants == 0, "host: the van is empty (total %d)" % _van.total)
	print("LOBBY_MP_DONE")
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "host: A and B left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


# --- clients A and B ---------------------------------------------------------------------------------------------------

func _client() -> void:
	var b: BalanceConfig = Config.balance
	var tag := role.to_upper()
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha" if role == "a" else "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "%s: joined and spawned" % tag)
	if Game.local_player == null:
		return
	_bind()
	var me: Player = Game.local_player
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "%s: WAITING" % tag)
	check(_in_alley_spot(me), "%s: spawned at its alley spawn (index %d)" % [tag, me.spawn_index])
	await wait_until(func() -> bool: return _van.is_lobby_on(), 5.0, "%s: the head count was synced on join (total %d)" % [tag, _van.total])
	check(_lobby.is_in_use() and _lobby.visible, "%s: the alley is drawn" % tag)
	check(_hud.is_lobby_banner() and _hud.get_lobby_text().begins_with("Everyone in the van."), "%s: HUD '%s'" % [tag, _hud.get_lobby_text()])
	check(not _hud.start_button.visible and not _hud.banner_tip.text.contains("leave without"), "%s: no start button, no Enter tip for a worker" % tag)
	await wait_until(func() -> bool: return Net.players.size() >= 3 and _van.total == 3, JOIN_TIMEOUT, "%s: three workers, the van counts three" % tag)
	await wait_until(func() -> bool: return _everyone(_in_alley), 3.0, "%s: every body is in the alley here" % tag)
	GameState.request_start_round()
	check(_transitions.is_empty() and GameState.phase == GameState.Phase.WAITING, "%s: a worker's Enter does nothing" % tag)
	_get_in()
	await wait_until(func() -> bool: return _van.occupants >= 2 or _van.is_counting() or _van.is_departing(), STEP_TIMEOUT, "%s: the host counted us in" % tag)
	await wait_until(func() -> bool: return _van.is_counting() or _van.is_departing() or not _transitions.is_empty(), STEP_TIMEOUT, "%s: the countdown is synced" % tag)
	if _van.is_counting():
		check(_hud.get_lobby_text().begins_with("Doors closing"), "%s: HUD '%s'" % [tag, _hud.get_lobby_text()])
		check(_van.countdown_left > 0.0 and _van.countdown_left <= b.van_countdown_sec, "%s: it ticks down locally (%.2f)" % [tag, _van.countdown_left])
	await _await_transition(GameState.TRANSITION_TO_FLOOR, tag, STEP_TIMEOUT)
	check(_counting_seen > 0, "%s: saw the countdown before the ride (%d updates)" % [tag, _counting_seen])
	check(_hud.is_transition_showing() and _van.are_doors_shut(), "%s: the screen fades, the doors swing shut" % tag)
	await _expect_floor(tag, 1)
	GameState.request_start_round()
	GameState.request_next_round()
	GameState.request_retry()
	check(GameState.is_playing() and _transitions.size() == _seen, "%s: a worker's requests do nothing during a shift" % tag)
	await _follow_back_and_forth(tag)
	step("%s: the last ride" % tag)
	_get_in()
	await _await_transition(GameState.TRANSITION_TO_FLOOR, tag, STEP_TIMEOUT)
	await _expect_floor(tag, 1)
	await wait_until(func() -> bool: return Net.players.size() == 3, 6.0, "%s: C is gone from the registry" % tag)
	await wait_sec(1.0)
	await _leave(tag)


# --- client C (joins during shift 1) ------------------------------------------------------------------------------------

func _late_client() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Charlie")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "C: joined and spawned")
	if Game.local_player == null:
		return
	_bind()
	var me: Player = Game.local_player
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "C: PLAYING synced on join")
	check(not _lobby.contains_point(me.global_position) and _at_dock(me), "C: landed at its dock arrival (index %d), not in the alley" % me.spawn_index)
	await wait_until(func() -> bool: return _world.get_players().size() >= 4 and _everyone(_at_dock), 4.0, "C: everyone else stands at the dock here")
	check(not _lobby.is_in_use() and not _lobby.visible, "C: the alley is not drawn during a shift")
	check(_hud.get_lobby_text() == "" and not _van.is_counting(), "C: no alley banner")
	await _follow_back_and_forth("C")
	step("C: gets in, then drops out while the doors are closing")
	_get_in()
	await wait_until(func() -> bool: return _van.is_counting(), STEP_TIMEOUT, "C: the countdown runs")
	await wait_sec(0.9)
	await _leave("C")


# --- shared --------------------------------------------------------------------------------------------------------------

## NEXT SHIFT (alley, round 2) -> the host's Enter (dock, shift 2) -> START OVER (alley, round 1), as a client sees it.
func _follow_back_and_forth(tag: String) -> void:
	var b: BalanceConfig = Config.balance
	step("%s: shift 1 paid, back to the alley" % tag)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, STEP_TIMEOUT, "%s: ROUND_SUCCESS" % tag)
	var money := GameState.money
	await _await_transition(GameState.TRANSITION_TO_LOBBY, tag, STEP_TIMEOUT)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS, "%s: the report stays while the screen fades" % tag)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "%s: WAITING" % tag)
	check(GameState.round_number == 2 and GameState.money == money and GameState.round_sales == 0, "%s: round 2, the money kept ($%d)" % [tag, GameState.money])
	check(GameState.quota == GameState.get_quota_for(2), "%s: the next payment ($%d)" % [tag, GameState.quota])
	var me: Player = Game.local_player
	await wait_until(func() -> bool: return _in_alley_spot(me), 3.0, "%s: back at its alley spawn" % tag)
	await wait_until(func() -> bool: return _world.get_players().size() >= 4 and _everyone(_in_alley), 4.0, "%s: all four are in the alley here" % tag)
	check(_lobby.is_in_use() and _lobby.visible and not _van.are_doors_shut(), "%s: the alley is drawn, the doors are open" % tag)
	await wait_until(func() -> bool: return _hud.get_lobby_text() == "Everyone in the van. 0 / 4 in.", 4.0, "%s: HUD 0 / 4 in ('%s')" % [tag, _hud.get_lobby_text()])
	check(_rounds.size() <= 1, "%s: no new shift started by the way back" % tag)

	step("%s: the host leaves without anyone in the van" % tag)
	await _await_transition(GameState.TRANSITION_TO_FLOOR, tag, STEP_TIMEOUT)
	await _expect_floor(tag, 2)

	step("%s: shift 2 missed, start over" % tag)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, STEP_TIMEOUT, "%s: ROUND_FAILED" % tag)
	await _await_transition(GameState.TRANSITION_TO_LOBBY, tag, STEP_TIMEOUT)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "%s: WAITING" % tag)
	check(GameState.round_number == 1 and GameState.money == b.starting_money and GameState.upgrades.is_empty(), "%s: round 1, starting money" % tag)
	await wait_until(func() -> bool: return _in_alley_spot(me), 3.0, "%s: back at its alley spawn" % tag)
	await wait_until(func() -> bool: return _everyone(_in_alley), 4.0, "%s: all four are in the alley here" % tag)


## PLAYING in round `round_n`, this worker at its dock arrival, everybody else at theirs.
func _expect_floor(tag: String, round_n: int) -> void:
	var me: Player = Game.local_player
	await wait_until(func() -> bool: return GameState.is_playing(), 5.0, "%s: PLAYING" % tag)
	check(GameState.round_number == round_n, "%s: shift %d" % [tag, round_n])
	await wait_until(func() -> bool: return _at_dock(me), 3.0, "%s: stands at its dock arrival" % tag)
	await wait_until(func() -> bool: return _everyone(_at_dock), 4.0, "%s: everyone stands at the dock here" % tag)
	check(not _lobby.is_in_use() and not _lobby.visible, "%s: the alley is not drawn" % tag)
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), 4.0, "%s: the screen fades back in" % tag)


## Waits for the next transition this process has not looked at yet and checks its kind.
func _await_transition(kind: StringName, tag: String, timeout_sec: float) -> void:
	var want := _seen + 1
	await wait_until(func() -> bool: return _transitions.size() >= want, timeout_sec, "%s: transition_started (%s)" % [tag, kind])
	if _transitions.size() >= want:
		check(_transitions[want - 1][0] == kind and is_equal_approx(float(_transitions[want - 1][1]), Config.balance.transition_fade_sec),
				"%s: kind %s, seconds = transition_fade_sec" % [tag, _transitions[want - 1][0]])
		_seen = want


func _bind() -> void:
	_world = Game.world
	_room = _world.room
	_lobby = _world.lobby
	_van = _lobby.get_van()
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_van.changed.connect(func() -> void:
		if _van.is_counting():
			_counting_seen += 1)


## The local worker walks (well: is put) into the back of the van, on the seat of its role.
func _get_in() -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = _van.get_seat_transform(int(SEATS[role])).origin


func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)
	check(not GameState.is_transitioning(), "%s: nothing left running" % tag)


func _everyone(pred: Callable) -> bool:
	for p in _world.get_players():
		if not bool(pred.call(p)):
			return false
	return true


func _in_alley(p: Player) -> bool:
	return _lobby.contains_point(p.global_position)


func _in_alley_spot(p: Player) -> bool:
	return _lobby.contains_point(p.global_position) \
			and _flat(p.global_position).distance_to(_flat(_lobby.get_spawn_transform(p.spawn_index).origin)) < SPOT_TOLERANCE


func _at_dock(p: Player) -> bool:
	return not _lobby.contains_point(p.global_position) \
			and _flat(p.global_position).distance_to(_flat(_room.get_arrival_transform(p.spawn_index).origin)) < DOCK_TOLERANCE


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
