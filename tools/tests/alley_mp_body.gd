extends "res://tools/tests/qa_base.gd"
## M15 alley multi-process suite (alley agent), driven by tools/tests/alley_mp.sh: a host, client A (joins in the alley)
## and client B (joins late, in the alley before shift 2). Every process runs with --lobby.
##   host: waits in the alley for A; A picks the ball up and throws it through the hoop (the host counts: 1); the host
##         leaves with Enter (the ball is gone), ends shift 1 paid by A, NEXT SHIFT (alley, round 2: a fresh ball, the
##         counter at 0, the board holds shift 1); A scores again, the host drops one through by hand (2); prints
##         ALLEY_MP_SCORED (the shell starts B); once B sits in the van, leaves with Enter again (the ball is gone
##         everywhere).
##   a:    sees the ball where the host put it, takes it through the interaction request, aims with its own body's
##         pose (the server throws from %BodyHandSocket along the synced look) and throws from behind the van, 8.4 m
##         out; sees the count, the ball drop below the hoop, the ball gone after the ride, the board, the reset.
##   b:    joins while the game waits for shift 2: the counter reads 2 and the board holds shift 1 without having
##         seen either happen; the ball lies where it landed; then it gets in the van (the host's cue to leave);
##         after the ride the ball is gone.
## Each process prints "ALLEY_BOARD: <the LAST SHIFT lines>" once it has them; the shell compares the three.
## Every engine/script error fails the run unless announced (qa_base.gd).

const Aim := preload("res://tools/tests/alley_aim.gd")
const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 60.0
const THROW_SPOT := Vector3(-1.2, 0.05, -1.4)   # Lobby-local: behind the van, 8.4 m from the hoop
const MAX_ATTEMPTS: int = 4

var role: String = "host"
var port: int = 7982
var _world: World
var _lobby: Lobby
var _hoop: AlleyHoop
var _board: AlleyBoard
var _items: ItemManager
var _hud: HUD
var _counts: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7982))
	_label = "alley_mp:" + role
	await get_tree().process_frame
	check(Config.lobby_enabled, "%s runs with the lobby on (--lobby)" % role)
	match role:
		"host": await _host()
		"a": await _client_a()
		"b": await _client_b()
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
	# Out of the way of the lane between the van and the hoop.
	me.velocity = Vector3.ZERO
	me.global_position = _lobby.global_position + Vector3(3.4, 0.05, 1.0)
	await wait_frames(3)
	var ball := _lobby.get_ball()
	check(ball != null and _flat(ball.global_position).distance_to(_flat(_lobby.get_ball_spot())) < 0.05, "host: one ball at the ball spot")
	check(_hoop.count == 0 and _board.report_lines.is_empty(), "host: counter 0, the board blank")
	print("ALLEY_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and _world.get_players().size() >= 2, JOIN_TIMEOUT, "A registered and spawned")
	var a_id := _other_peer()

	step("host: A throws")
	await wait_until(func() -> bool: return _hoop.count == 1, STEP_TIMEOUT, "host: A's throw went through the ring (1)")
	check(_hoop.get_count_text() == "1" and _counts == [1], "host: the label reads 1 (%s)" % [_counts])
	check(GameState.get_stat(a_id, Const.STAT_THROWS) >= 1, "host: the throw is A's (%d throws)" % GameState.get_stat(a_id, Const.STAT_THROWS))
	ball = _lobby.get_ball()
	await wait_until(func() -> bool: return ball != null and not ball.is_flying(), 4.0, "host: the ball landed")
	check(_flat(ball.global_position).distance_to(_flat(_hoop.get_drop_point())) < 0.4, "host: below the hoop")

	step("host: the ride")
	await wait_sec(1.5)
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 2.0, "host: PLAYING")
	check(_lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), "host: the ball is gone")
	await wait_sec(2.0)
	var due := GameState.quota
	GameState.server_add_sale(due, a_id)
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "host: shift 1 paid by A")
	var lines := _board.get_last_shift_lines()
	check(lines.size() >= 3 and lines[0] == "Shift 1. Paid." and lines[1] == "Deposited $%d." % due and lines[2] == "Due $%d." % due, "host: the board holds shift 1 %s" % [lines])
	var verdicts := Story.get_report_verdicts()
	var cut := PackedStringArray()
	for i in mini(verdicts.size(), 3):
		cut.append(verdicts[i])
	check(lines.slice(3) == cut and not cut.is_empty(), "host: then the first verdicts of the report %s" % [cut])
	print("ALLEY_BOARD: " + " | ".join(lines))
	await wait_sec(1.5)
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 2.0, "host: NEXT SHIFT, WAITING")
	await wait_frames(3)
	check(_lobby.get_ball() != null and _hoop.count == 0 and _hoop.get_count_text() == "0", "host: a fresh ball, the counter at 0")
	me.velocity = Vector3.ZERO
	me.global_position = _lobby.global_position + Vector3(3.4, 0.05, 1.0)

	step("host: A throws again, the host adds one")
	await wait_until(func() -> bool: return _hoop.count == 1, STEP_TIMEOUT, "host: A scored in round 2 (1)")
	ball = _lobby.get_ball()
	await wait_until(func() -> bool: return ball != null and not ball.is_flying() and not ball.is_held(), 4.0, "host: the ball is down")
	await wait_sec(0.5)
	check(_items.server_throw_item(ball, _hoop.get_ring_center() + Vector3.UP * 0.9, Vector3.DOWN * 0.5, 1), "host: lets one fall through")
	await wait_until(func() -> bool: return _hoop.count == 2, 3.0, "host: 2")
	await wait_until(func() -> bool: return not ball.is_flying(), 3.0, "host: it landed")
	print("ALLEY_MP_SCORED")

	step("host: B joins late")
	await wait_until(func() -> bool: return Net.players.size() >= 3 and _world.get_players().size() >= 3, JOIN_TIMEOUT, "B registered and spawned")
	await wait_until(func() -> bool: return _lobby.get_van().occupants >= 1, STEP_TIMEOUT, "host: B has looked around and sits in the van")
	check(_hoop.count == 2 and items_of(Const.ITEM_BALL).size() == 1, "host: still 2, still one ball")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 2.0, "host: shift 2, PLAYING")
	check(_lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), "host: the ball is gone again")
	print("ALLEY_MP_DONE")
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "host: A and B left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


# --- client A ------------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	_bind()
	var me: Player = Game.local_player
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and _lobby.is_in_use(), 5.0, "A: WAITING in the alley")
	await wait_until(func() -> bool: return _lobby.get_ball() != null, 5.0, "A: the ball replicated")
	var ball := _lobby.get_ball()
	check(ball is Ball and _flat(ball.global_position).distance_to(_flat(_lobby.get_ball_spot())) < 0.05, "A: it lies at the ball spot")
	check(_hoop.count == 0 and _hoop.get_count_text() == "0", "A: counter 0")
	check(_board.get_shown_text(0) == "No shift worked yet." and _board.get_next_lines()[0] == "Shift 1 is next.", "A: the board before the first shift")

	step("A: the throw")
	await _score("A", 1)
	check(_counts == [1], "A: count_changed fired once here (%s)" % [_counts])
	await wait_until(func() -> bool: return not ball.is_flying(), 4.0, "A: the ball landed")
	check(_flat(ball.global_position).distance_to(_flat(_hoop.get_drop_point())) < 0.4, "A: below the hoop")

	step("A: the ride")
	await wait_until(func() -> bool: return GameState.is_playing(), STEP_TIMEOUT, "A: PLAYING")
	var due := GameState.quota
	await wait_until(func() -> bool: return _lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), 3.0, "A: the ball is gone here too")
	check(not _hoop.is_visible_in_tree() and not _board.is_visible_in_tree(), "A: the hoop and the board are not drawn")
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, STEP_TIMEOUT, "A: ROUND_SUCCESS")
	await wait_until(func() -> bool: return _board.get_last_shift_lines().size() >= 3, 3.0, "A: the board was written")
	var lines := _board.get_last_shift_lines()
	check(lines[0] == "Shift 1. Paid." and lines[1] == "Deposited $%d." % due and lines[2] == "Due $%d." % due, "A: shift 1 as the host recorded it %s" % [lines])
	print("ALLEY_BOARD: " + " | ".join(lines))
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, STEP_TIMEOUT, "A: WAITING again")
	await wait_until(func() -> bool: return _lobby.get_ball() != null, 4.0, "A: a fresh ball")
	check(_hoop.count == 0 and _hoop.get_count_text() == "0", "A: the counter started over")
	await wait_until(func() -> bool: return _board.get_shown_text(0) == "\n".join(lines), 2.0, "A: LAST SHIFT shows it")
	check(_board.get_next_lines()[0] == "Shift 2 is next." and _board.is_visible_in_tree(), "A: NEXT says shift 2")
	await wait_until(func() -> bool: return not _hud.is_transition_showing(), 4.0, "A: the screen is back")

	step("A: again")
	await _score("A", 1)
	await wait_until(func() -> bool: return _hoop.count == 2, STEP_TIMEOUT, "A: the host's one makes 2")
	check(_hoop.get_count_text() == "2", "A: the label reads 2")
	await wait_until(func() -> bool: return GameState.is_playing(), STEP_TIMEOUT, "A: shift 2, PLAYING")
	await wait_until(func() -> bool: return _lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), 3.0, "A: the ball is gone again")
	await wait_sec(1.0)
	await _leave("A")


# --- client B (joins before shift 2) -----------------------------------------------------------------------------------

func _client_b() -> void:
	step("late join %d" % port)
	Game.start_join("127.0.0.1", port, "Bravo")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "B: joined and spawned")
	if Game.local_player == null:
		return
	_bind()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and _lobby.is_in_use(), 5.0, "B: WAITING in the alley")
	await wait_until(func() -> bool: return _hoop.count == 2, 5.0, "B: the count was synced on join (%d)" % _hoop.count)
	check(_hoop.get_count_text() == "2", "B: the label reads 2")
	await wait_until(func() -> bool: return _board.get_last_shift_lines().size() >= 3, 5.0, "B: the board was synced on join")
	var lines := _board.get_last_shift_lines()
	var due := Config.balance.quota_for_round(1, 2)
	check(lines.size() >= 4 and lines[0] == "Shift 1. Paid." and lines[1] == "Deposited $%d." % due and lines[2] == "Due $%d." % due,
			"B: shift 1, which it never saw %s" % [lines])
	print("ALLEY_BOARD: " + " | ".join(lines))
	await wait_until(func() -> bool: return _board.get_shown_text(0) == "\n".join(lines), 2.0, "B: LAST SHIFT shows it")
	check(_board.get_next_lines()[0] == "Shift 2 is next." and _board.is_visible_in_tree(), "B: NEXT says shift 2")
	await wait_until(func() -> bool: return _lobby.get_ball() != null, 5.0, "B: the ball replicated")
	var ball := _lobby.get_ball()
	check(_flat(ball.global_position).distance_to(_flat(_hoop.get_drop_point())) < 0.4 and not ball.is_held(), "B: it lies below the hoop, where it landed")
	# Seen everything: B gets in the van, which is how the host knows it can leave.
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = _lobby.get_van().get_seat_transform(0).origin
	await wait_until(func() -> bool: return GameState.is_playing(), STEP_TIMEOUT, "B: shift 2, PLAYING")
	await wait_until(func() -> bool: return _lobby.get_ball() == null and items_of(Const.ITEM_BALL).is_empty(), 3.0, "B: the ball is gone")
	await wait_sec(1.0)
	await _leave("B")


# --- shared --------------------------------------------------------------------------------------------------------------

## The local worker takes the ball, walks behind the van, aims and throws until the counter reads `want`.
func _score(tag: String, want: int) -> void:
	var me: Player = Game.local_player
	var my_id := multiplayer.get_unique_id()
	var socket := me.get_node(^"%BodyHandSocket") as Node3D
	for attempt in MAX_ATTEMPTS:
		var ball := _lobby.get_ball()
		if ball == null:
			break
		await wait_until_quiet(func() -> bool: return not ball.is_flying(), 5.0)
		me.velocity = Vector3.ZERO
		me.global_position = ball.global_position + Vector3(0.0, 0.05, -0.8)
		me.rotation = Vector3(0.0, PI, 0.0)
		me.head.rotation.x = 0.0
		await wait_sec(0.6)
		ball.interact(me)
		if not await wait_until_quiet(func() -> bool: return ball.holder_id == my_id, 6.0):
			continue
		me.velocity = Vector3.ZERO
		me.global_position = _lobby.global_position + THROW_SPOT
		await wait_sec(0.5)
		var miss := Aim.aim(me, socket, _hoop.get_ring_center())
		print("  %s: attempt %d, pitch %.1f, predicted miss %.3f m" % [tag, attempt + 1, rad_to_deg(me.head.rotation.x), miss])
		await wait_sec(1.2) # the host's copy of this body settles on the pose
		_items.request_throw()
		await wait_until_quiet(func() -> bool: return _lobby.get_ball() != null and _lobby.get_ball().holder_id == 0, 4.0)
		if await wait_until_quiet(func() -> bool: return _hoop.count >= want, 4.0):
			break
	me.head.rotation.x = 0.0
	check(_hoop.count == want and _hoop.get_count_text() == str(want), "%s: its own throw went through, the counter reads %d here" % [tag, want])


func wait_until_quiet(pred: Callable, timeout_sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_sec * 1000.0:
		if bool(pred.call()):
			return true
		await get_tree().process_frame
	return bool(pred.call())


func _bind() -> void:
	_world = Game.world
	_lobby = _world.lobby
	_hoop = _lobby.get_hoop()
	_board = _lobby.get_board()
	_items = _world.items
	_hud = _world.get_node_or_null(^"HUD") as HUD
	_hoop.count_changed.connect(func(n: int) -> void: _counts.append(n))


## The first peer in the registry that is not this one.
func _other_peer() -> int:
	for id in Net.get_peer_ids():
		if id != multiplayer.get_unique_id():
			return id
	return 0


func _leave(tag: String) -> void:
	step("%s leaves" % tag)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "%s: MENU, offline" % tag)


static func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)
