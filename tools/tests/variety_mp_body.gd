extends "res://tools/tests/qa_net_base.gd"
## M16 variety multi-process body (variety agent). Driven by tools/tests/variety_mp.sh; every process runs this script:
##   --role=host --run=7K2M      the director (real Game.start_host, --replay): hosts the run, changes its seed while
##                               the game waits, starts the shift, starts over
##   --role=client --who=a       Alpha: joins at once
##   --role=client --who=b       Bravo: joins while the shift runs (the late joiner)
## Common args: --port=N --replay --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a
## final "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the run signature (seed, code, cover layout, the layout the Room stands in, the alley board's
## run line, and the place and yaw of every one of the nineteen cover pieces) is the same text on the host and on
## every client: while the game waits, after the host changed the seed, in the running shift, for the late joiner
## (whose Room moves its cover the moment its state arrives, shift or no shift), after START OVER with a random run
## and with a code asked for. On every peer the moved crates are solid where they stand (a ray from above lands on
## them). A client that calls server_set_run_seed changes nothing anywhere.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const CODE_A := "7K2M"
const CODE_B := "QX4T"
## Pieces every layout but the scene's moves at least one of: where a ray from above has to land on them.
const PROBES: Array[NodePath] = [^"Dock/CrateMidB", ^"Dock/CrateWestB", ^"Decor/CrateA", ^"Hall/CrateNorthB"]

var role: String = "host"
var who: String = ""
var port: int = 7990
var _ids: Dictionary = {}
var _run_signals: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7990))
	_label = "variety_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	GameState.run_changed.connect(func() -> void: _run_signals += 1)
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	check(Config.replay_enabled and Config.run_code == CODE_A, "the host runs with --replay --run=%s" % CODE_A)
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	var layouts := Room.COVER_LAYOUTS.size()
	check(GameState.get_run_code() == CODE_A and GameState.get_run_cover() == int(RunSeed.stream(RunSeed.from_code(CODE_A), &"cover") % layouts) and GameState.get_run_cover() != 0,
			"host: run %s, cover layout %d (not the scene's)" % [GameState.get_run_code(), GameState.get_run_cover()])
	print("VARIETY_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	await checkpoint("joined", ["a"])

	step("WAITING: the run reaches the client")
	var r := await run_cmd(a, "run_state", {"expect": _sig()})
	_same_sig("Alpha, WAITING", r)
	check(int(r.get("layout", -1)) == GameState.get_run_cover() and bool(r.get("solid", false)) and _solid(), "Alpha's Room stands in layout %d and its crates are solid there; so are the host's" % GameState.get_run_cover())

	step("WAITING: the host changes the seed")
	var cover0 := GameState.get_run_cover()
	var other := _seed_for_cover((cover0 + 1) % layouts)
	var signals0 := int(r.get("signals", 0))
	GameState.server_set_run_seed(other)
	check(GameState.get_run_seed() == other and GameState.get_run_cover() != cover0, "host: seed %d, run %s, cover layout %d" % [other, GameState.get_run_code(), GameState.get_run_cover()])
	r = await run_cmd(a, "run_state", {"expect": _sig()})
	_same_sig("Alpha, after the change", r)
	check(int(r.get("signals", 0)) == signals0 + 1 and bool(r.get("solid", false)), "Alpha heard run_changed once and its crates moved with it")

	step("a client cannot change the run")
	var sig0 := _sig()
	r = await run_cmd(a, "try_set", {"seed": 5})
	check(int(r.get("seed", -1)) == other and _sig() == sig0, "Alpha's server_set_run_seed changed nothing, here or there")

	step("the shift starts")
	GameState.request_start_round()
	check(GameState.is_playing(), "host: PLAYING")
	GameState.server_set_run_seed(RunSeed.from_code(CODE_A))
	check(GameState.get_run_seed() == other and _sig() == sig0, "host: the seed cannot change while the shift runs")
	r = await run_cmd(a, "run_state", {"expect": _sig()})
	_same_sig("Alpha, PLAYING", r)
	print("VARIETY_SHIFT_RUNNING")

	step("the late joiner")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bravo: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bravo) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bravo, "run_state", {"expect": _sig()})
	_same_sig("Bravo, joined mid-shift", r)
	check(int(r.get("layout", -1)) == GameState.get_run_cover() and bool(r.get("solid", false)), "Bravo's Room took layout %d on arrival, shift or no shift, and its crates are solid there" % GameState.get_run_cover())
	await checkpoint("late joiner in", ["a", "b"])

	step("START OVER: a new run")
	Config.run_code = ""
	var old := GameState.get_run_seed()
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.get_run_seed() != old, 5.0, "host: WAITING, another run (%s)" % GameState.get_run_code())
	var seqs := {a: cmd(a, "run_state", {"expect": _sig()}), bravo: cmd(bravo, "run_state", {"expect": _sig()})}
	for p: int in seqs:
		r = await await_ack(seqs[p])
		_same_sig("%s, after START OVER" % Net.get_player_name(p), r)
	await checkpoint("after START OVER", ["a", "b"])

	step("START OVER with a code asked for")
	Config.run_code = CODE_B
	GameState.request_start_round()
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.get_run_code() == CODE_B, 5.0, "host: the run is %s" % CODE_B)
	seqs = {a: cmd(a, "run_state", {"expect": _sig()}), bravo: cmd(bravo, "run_state", {"expect": _sig()})}
	for p: int in seqs:
		r = await await_ack(seqs[p])
		_same_sig("%s, run %s" % [Net.get_player_name(p), CODE_B], r)
		check(bool(r.get("solid", false)), "%s's crates are solid where they stand" % Net.get_player_name(p))
	await checkpoint("run %s" % CODE_B, ["a", "b"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bravo, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bravo), 20.0, "both clients left")
	finish()


func _same_sig(tag: String, r: Dictionary) -> void:
	var ok := bool(r.get("ok", false))
	check(ok, "[%s] the same seed, code, cover layout, board line and nineteen cover transforms as the host" % tag)
	if not ok:
		print("      host : " + _sig())
		print("      peer : " + String(r.get("sig", "<no answer>")))


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func checkpoint(tag: String, keys: Array) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names)


## The first seed whose cover is layout `index`.
func _seed_for_cover(index: int) -> int:
	var s := 1
	while int(RunSeed.stream(s, &"cover") % Room.COVER_LAYOUTS.size()) != index:
		s += 1
	return s


# =================================================================================================== EVERY PEER

## Everything the run shows on this peer, as one line: it must read the same on the host and on every client.
func _sig() -> String:
	var room: Room = Game.world.room if Game.world != null else null
	if room == null:
		return "<no room>"
	var board: AlleyBoard = Game.world.lobby.get_board() if Game.world.lobby != null else null
	var parts := PackedStringArray()
	for node in room.get_cover_nodes():
		var p := node.global_position
		parts.append("%s %.3f %.3f %.3f %.2f" % [node.name, p.x, p.y, p.z, rad_to_deg(node.global_rotation.y)])
	return "seed=%d code=%s cover=%d layout=%d board='%s' | %s" % [GameState.get_run_seed(), GameState.get_run_code(), GameState.get_run_cover(), room.get_cover_layout(),
			board.get_run_line() if board != null else "-", "; ".join(parts)]


## True when a ray from above lands on each of the PROBES where it stands: the colliders moved with the models.
func _solid() -> bool:
	var room: Room = Game.world.room
	var space := room.get_world_3d().direct_space_state
	var ok := true
	for path in PROBES:
		var node := room.get_node(path) as Node3D
		var top := node.global_position + Vector3.UP * 2.0
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, node.global_position + Vector3.UP * 0.4, Const.LAYER_WORLD))
		if hit.is_empty() or hit.get("collider") != node:
			ok = false
			print("      %s: a ray from above lands on %s" % [node.name, (hit["collider"] as Node).name if not hit.is_empty() else "nothing"])
	return ok


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	check(Config.run_code == "", "the client was started without a run code")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		finish(); return
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	match action:
		"run_state":
			var expect := String(args.get("expect", ""))
			var ok := await wait_until_quiet(func() -> bool: return _sig() == expect, float(args.get("timeout", CHECK_TIMEOUT)))
			check(ok, "the run matches the host's (%s, layout %d)" % [GameState.get_run_code(), Game.world.room.get_cover_layout()])
			if not ok:
				print("      host : " + expect)
				print("      here : " + _sig())
			for i in 3:
				await get_tree().physics_frame
			var solid := _solid()
			check(solid, "the crates are solid where they stand")
			ack(seq, {"ok": ok, "sig": _sig(), "signals": _run_signals, "layout": Game.world.room.get_cover_layout(), "solid": solid})
		"try_set":
			expect_error("server_set_run_seed called on a non-server peer")
			GameState.server_set_run_seed(int(args.get("seed", 1)))
			await sync_with_host()
			check(expected_errors_seen(), "the call was refused on this peer")
			ack(seq, {"seed": GameState.get_run_seed()})
		_:
			await super(seq, action, args)
