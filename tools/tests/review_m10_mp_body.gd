extends "res://tools/tests/qa_net_base.gd"
## M11 review of M10 (review agent): two-process regression test with a ROGUE client (a modified build) on the real
## ENet stack. The host picks a random port and launches the rogue process itself (same body, --role=rogue); the
## rogue's checks / error counts are reported back before it leaves. Driven by tools/tests/review_m10_mp.sh.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_m10_mp_body.gd
## What it pins (the sender checks of every new M10 request path, over the wire):
##   S1  spoofed cosmetics / owner RPCs on the HOST's Player node: _rpc_stagger_fx (only the server or the owner),
##       _rpc_staggered (only the server), _rpc_request_shove (only the node's owner) do nothing when the rogue sends them
##   S2  authority-only broadcasts (Events._rpc_event_started / _rpc_power) from a client are refused by the engine
##       (expected ERROR lines on the host), nothing changes
##   S3  a voice frame of 5000 bytes and a 200-frame burst from the rogue: dropped (too_big / rate), bounded cost;
##       a 40-line chat flood in one frame lands at most twice; a ping at 1e30 is refused
##   S4  the back-room cheat over the wire: the host sends the rogue to the back room, the rogue walks back onto the
##       floor (owner-authoritative movement) and sends the REAL requests (pick-up, buy, fuse reset, drop, throw,
##       shove): every one refused with "You're in the back room.", nothing changes; released, the pick-up works
##   S0  (on the way in) the rogue joins DURING an inspection: the Boss is already out walking on the joiner, resumed
##       mid-route with the host's remaining seconds, not restarted from the booth
## Every engine/script error fails the run unless announced (qa_base.gd).

const REASON_BACKROOM_TEXT := "You're in the back room."

var role: String = "host"
var _pid: int = -1
var _rogue: int = 0
var _host_staggers: Array = []   # host: by_peer of every staggered() on the host's own node
var _chat_lines: Array = []      # host: [peer, text]
var _pings: Array = []           # host: [peer, position]


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	_label = "review_m10_mp:" + role
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _rogue_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var port := 0
	var err: Error = ERR_CANT_CREATE
	for attempt in 6:
		port = 31000 + randi() % 9000
		err = Game.start_host("Boss's Pet", port)
		if err == OK:
			break
	if not check(err == OK, "host on a random port (%d)" % port):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 10.0, "host world ready"):
		finish(); return
	# S0: the shift and an inspection are already running when the rogue joins (late-join sync of a walking Boss).
	GameState.request_start_round()
	check(GameState.is_playing() and Events.server_start_event(Events.EVENT_INSPECTION), "shift running, inspection started before the join")
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/run_test.gd", "--", "--body=res://tools/tests/review_m10_mp_body.gd",
			"--role=rogue", "--port=%d" % port, "--timeout=110"])
	_pid = OS.create_process(OS.get_executable_path(), args)
	if not check(_pid > 0, "launched the rogue process"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.world.get_players().size() == 2, 30.0, "rogue joined (Player node on the host)"):
		_end(); return
	for p in Game.world.get_players():
		if p.peer_id != Const.SERVER_PEER_ID:
			_rogue = p.peer_id
	var me: Player = Game.local_player
	var items := Game.world.items
	me.staggered.connect(func(by: int) -> void: _host_staggers.append(by))
	Comms.chat_received.connect(func(p: int, t: String) -> void: _chat_lines.append([p, t]))
	Comms.ping_received.connect(func(p: int, pos: Vector3) -> void: _pings.append([p, pos]))
	step("S0: the rogue joined during the inspection")
	var r := await run_cmd(_rogue, "late_join_report")
	check(bool(r.get("active", false)) and bool(r.get("walking", false)), "rogue: inspection active on join, the Boss walks there too")
	check(float(r.get("progress", 0.0)) > 0.02 and float(r.get("progress", 0.0)) < 0.9, "rogue: the walk resumed mid-route (progress %.2f), not from the booth" % float(r.get("progress", 0.0)))
	check(float(r.get("left", 99.0)) < Config.balance.inspection_sec - 1.0 and float(r.get("left", 0.0)) > 0.0, "rogue: the host's remaining seconds came with the event (%.1f s)" % float(r.get("left", 0.0)))
	check(bool(r.get("seconds_ok", false)), "rogue: params carry the full seconds + speed")
	Events.server_end_event()
	await wait_frames(2)
	check(GameState.is_playing() and not Events.is_event_active(), "shift running, inspection over")
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(0.0, 0.02, 0.0)
	me.rotation = Vector3.ZERO
	await wait_sec(0.5)
	var rogue_player: Player = Game.world.get_player(_rogue)

	step("S1: spoofed owner / cosmetic RPCs on the host's own Player node")
	_host_staggers.clear()
	var shoves0 := GameState.get_stat(1, Const.STAT_SHOVES)
	r = await run_cmd(_rogue, "spoof_player_rpcs")
	check(bool(r.get("sent", false)), "rogue sent _rpc_stagger_fx / _rpc_staggered / _rpc_request_shove on World/Players/1")
	await wait_frames(2)
	check(_host_staggers.is_empty(), "no staggered() on the host's node from a non-owner's fx broadcast %s" % [_host_staggers])
	check(not me.is_stunned() and me.velocity.length() < 0.5, "no stun, no impulse from a non-server _rpc_staggered (v=%s)" % me.velocity)
	check(GameState.get_stat(1, Const.STAT_SHOVES) == shoves0 and rogue_player != null and not rogue_player.is_stunned(),
			"a shove request on another worker's node is ignored (STAT_SHOVES %d, rogue unstunned)" % GameState.get_stat(1, Const.STAT_SHOVES))

	step("S2: authority-only Events broadcasts from a client")
	# The engine refuses them on the host before any game code runs.
	allow_error("RPC '_rpc_event_started' is not allowed on node /root/Events", 1, true)
	allow_error("RPC '_rpc_power' is not allowed on node /root/Events", 1, true)
	r = await run_cmd(_rogue, "spoof_events")
	await wait_frames(2)
	check(not Events.is_event_active() and Events.is_power_on() and Game.world.room.is_power_on(), "host: no event, power on")
	clear_allowed_errors()

	step("S3: voice / chat / ping floods from the rogue")
	var vs0: Dictionary = Voice.get_stats()
	_chat_lines.clear()
	_pings.clear()
	r = await run_cmd(_rogue, "floods", {}, 20.0)
	await wait_sec(0.6)
	var vs: Dictionary = Voice.get_stats()
	var d0: Dictionary = vs0["dropped"]
	var d1: Dictionary = vs["dropped"]
	check(int(d1.get("too_big", 0)) >= int(d0.get("too_big", 0)) + 1, "the 5000-byte voice frame was dropped (too_big)")
	var got_frames := int(vs["received"]) - int(vs0["received"])
	check(got_frames <= Voice.MAX_FRAMES_PER_SEC + 4 and int(d1.get("rate", 0)) > int(d0.get("rate", 0)),
			"200 frames in a burst: %d accepted (<= %d), the rest dropped by rate" % [got_frames, Voice.MAX_FRAMES_PER_SEC])
	var rogue_lines := 0
	for e in _chat_lines:
		if int(e[0]) == _rogue:
			rogue_lines += 1
	check(rogue_lines >= 1 and rogue_lines <= 2, "a 40-line chat flood landed %d time(s)" % rogue_lines)
	var far_pings := 0
	for e in _pings:
		if int(e[0]) == _rogue and not ((e[1] as Vector3).length() < 100.0):
			far_pings += 1
	check(far_pings == 0, "no ping from the rogue further than the room (%d)" % far_pings)

	step("S4: the back-room cheat over the wire")
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 2}, Vector3(-3.0, 0.0, 3.0)) as Item
	var held := items.server_spawn_item(Const.ITEM_WATERING_CAN, {"charges": 1}, Vector3(-4.0, 0.0, 3.0), _rogue) as Item
	check(can != null and held != null and held.holder_id == _rogue, "a can on the floor, one in the rogue's hands")
	check(GameState.server_send_to_backroom(_rogue, 60.0), "rogue sent to the back room")
	check(Events.server_start_event(Events.EVENT_POWER_CUT), "and the power is cut (fuse box tripped)")
	var money := GameState.money
	var sales := GameState.round_sales
	shoves0 = GameState.get_stat(1, Const.STAT_SHOVES) + GameState.get_stat(_rogue, Const.STAT_SHOVES)
	_host_staggers.clear()
	r = await run_cmd(_rogue, "cheat_from_backroom", {"can": String(can.name)}, 30.0)
	check(bool(r.get("walked_out", false)), "rogue walked out of the booth (host saw it %.1f m from the can)" % float(r.get("dist", -1.0)))
	check(can.holder_id == 0, "pick-up refused (holder %d)" % can.holder_id)
	check(GameState.money == money and GameState.round_sales == sales and items_of(Const.ITEM_SEED_PACKET).is_empty(), "no purchase, no sale")
	check(not Events.is_power_on() and Events.is_event_active(Events.EVENT_POWER_CUT), "fuse-box reset refused: still dark")
	check(held.holder_id == 0 and not held.is_flying(), "drop and throw refused; the can it carried was left at its spawn on entry (holder %d)" % held.holder_id)
	check(_host_staggers.is_empty() and GameState.get_stat(1, Const.STAT_SHOVES) + GameState.get_stat(_rogue, Const.STAT_SHOVES) == shoves0, "shove refused")
	var denials := 0
	for t in r.get("toasts", []):
		if String(t).contains(REASON_BACKROOM_TEXT):
			denials += 1
	check(denials >= 3, "rogue was told '%s' %d times %s" % [REASON_BACKROOM_TEXT, denials, r.get("toasts", [])])
	Events.server_end_event()
	GameState.server_release_from_backroom(_rogue)
	await wait_frames(2)
	r = await run_cmd(_rogue, "pickup", {"can": String(can.name)}, 20.0)
	check(can.holder_id == _rogue and held.holder_id == 0 and not bool(r.get("hands_full_seen", false)), "released: the same pick-up answers on its merits (picked up: the hands were emptied on entry)")
	_end()


## Collects the rogue's own result, lets it leave, waits for its process, then finishes the host.
func _end() -> void:
	if _rogue > 0 and _rogue in multiplayer.get_peers():
		var rep := await run_cmd(_rogue, "report", {}, 10.0)
		check(int(rep.get("fails", -1)) == 0 and int(rep.get("errors", -1)) == 0,
				"rogue process: %s checks failed, %s unexpected errors" % [rep.get("fails", "?"), rep.get("errors", "?")])
		cmd(_rogue, "finish")
	if _pid > 0:
		var t0 := Time.get_ticks_msec()
		while OS.is_process_running(_pid) and Time.get_ticks_msec() - t0 < 15000:
			await get_tree().process_frame
		check(not OS.is_process_running(_pid), "rogue process exited")
		if OS.is_process_running(_pid):
			OS.kill(_pid)
	finish()


# =================================================================================================== ROGUE

func _rogue_main() -> void:
	var port := port_arg(0)
	if not check(Game.start_join("127.0.0.1", port, "Rogue") == OK, "start_join on port %d" % port):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "rogue joined"):
		finish(); return
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	match action:
		"late_join_report":
			var counter := Game.world.room.get_station("ShopCounter")
			var boss := counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC if counter != null else null
			var params := Events.get_event_params()
			ack(seq, {"active": Events.is_event_active(Events.EVENT_INSPECTION), "walking": boss != null and boss.is_walking(),
					"progress": boss.get_walk_progress() if boss != null else -1.0, "left": Events.get_event_time_left(),
					"seconds_ok": is_equal_approx(float(params.get("seconds", 0.0)), Config.balance.inspection_sec) and params.has("speed")})
		"spoof_player_rpcs":
			var host_node: Player = Game.world.get_player(1)
			var sent := host_node != null
			if sent:
				host_node._rpc_stagger_fx.rpc_id(1, me.peer_id, 5.0, true)                       # not the owner, not the server
				host_node._rpc_staggered.rpc_id(1, Vector3(50.0, 0.0, 0.0), 5.0, me.peer_id, false)  # not the server
				host_node._rpc_request_shove.rpc_id(1, me.peer_id)                             # not the node's owner
			await sync_with_host()
			ack(seq, {"sent": sent})
		"spoof_events":
			# call_local: these also run here, on the rogue (its own screen goes dark); the host must refuse them.
			Events._rpc_event_started.rpc(Events.EVENT_POWER_CUT, {"max_seconds": 40.0}, 40.0)
			Events._rpc_power.rpc(false)
			await sync_with_host()
			ack(seq, {"ok": true})
		"floods":
			var big := PackedByteArray()
			big.resize(5000)
			Voice._rpc_voice.rpc(1, big)
			var frame := PackedByteArray()
			frame.resize(Voice.FRAME_SAMPLES)
			frame.fill(0xFF)
			for i in 200:
				Voice._rpc_voice.rpc(i + 2, frame)
			for i in 40:
				Comms._rpc_chat.rpc("flood %d" % i)
			Comms._rpc_ping.rpc(Vector3(1e30, 1e30, 1e30))
			Comms._rpc_ping.rpc(Vector3(-1e12, 0.0, 0.0))
			await sync_with_host()
			ack(seq, {"ok": true})
		"cheat_from_backroom":
			# The honest part of the build applied the teleport; the cheat is to walk straight back out.
			await wait_until_quiet(func() -> bool: return GameState.is_in_backroom(me.peer_id), 8.0)
			var can := item_named(String(args.get("can", "")))
			var walked := false
			var dist := -1.0
			if can != null:
				stand_near(can, 0.7)
				walked = await server_sees_me()
				dist = me.global_position.distance_to(can.global_position)
				can.interact(me)                                        # real Interactable path (prediction + RPC)
				can._rpc_request_interact.rpc_id(1)                     # and the raw request
			var shop: ShopCounter = station("ShopCounter")
			shop.request_buy_seed(&"budget")
			var fuse: FuseBox = station("FuseBox")
			fuse.request_reset()
			Game.world.items.request_drop()
			Game.world.items.request_throw()
			me.request_shove(1)
			var host_node: Player = Game.world.get_player(1)
			if host_node != null:
				stand_near(host_node, 1.0)
				await server_sees_me()
				me.request_shove(1)
			await sync_with_host()
			await wait_frames(2)
			ack(seq, {"walked_out": walked, "dist": dist, "toasts": toasts_since(t)})
		"pickup":
			var can := item_named(String(args.get("can", "")))
			if can != null:
				stand_near(can, 0.7)
				await server_sees_me()
				can._rpc_request_interact.rpc_id(1)
			await sync_with_host()
			await wait_frames(2)
			var seen := false
			for s in toasts_since(t):
				if String(s).contains("Hands full."):
					seen = true
			ack(seq, {"hands_full_seen": seen, "toasts": toasts_since(t)})
		"report":
			ack(seq, {"fails": _fails, "errors": errors.errors.size()})
		_:
			await super(seq, action, args)
