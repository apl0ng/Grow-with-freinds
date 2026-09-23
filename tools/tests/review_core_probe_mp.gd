extends "res://tools/tests/qa_net_base.gd"
## Exploratory churn probe: clients join/cancel/leave randomly while the host cycles phases; then converge.

var role := ""
var who := ""
var port := 8600
var rng := RandomNumberGenerator.new()

func _run() -> void:
	role = str(Config.get_arg("role", "h"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 8600))
	rng.seed = int(Config.get_arg("seed", 1)) * 7919 + who.hash()
	_label = "churn:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host()
	else:
		await _client()

func _host() -> void:
	check(Game.start_host("Hosty", port) == OK, "host")
	print("CHURN_HOST_READY")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 14000:
		await wait_sec(rng.randf_range(0.05, 0.6))
		match rng.randi() % 6:
			0: GameState.request_start_round()
			1:
				if GameState.phase == GameState.Phase.PLAYING: GameState.time_left = 0.05
			2: GameState.request_retry()
			3: GameState.request_next_round()
			4:
				if GameState.phase == GameState.Phase.PLAYING: GameState.server_add_sale(rng.randi_range(1, 200), 1)
			5: GameState.server_try_spend(rng.randi_range(0, 30), 1, "x")
	print("CHURN_HOST_SETTLE players=", Net.players.keys())
	_dump_slots.call_deferred()
	await wait_until(func(): return Net.players.size() == 4 and Game.world.get_players().size() == 4, 40.0, "all three clients in")
	await wait_sec(2.0)
	var peers := []
	for id in Net.get_peer_ids():
		if id != 1: peers.append(id)
	await checkpoint_peers("settled", peers, {}, true)
	GameState.request_start_round()
	GameState.request_next_round()
	await wait_sec(1.0)
	await checkpoint_peers("after start", peers, {}, true)
	allow_error("Unable to send packet on channel 0", 6, true)
	for p in peers: cmd(p, "finish")
	await wait_sec(2.0)
	finish()

func _dump_slots() -> void:
	for i in 45:
		var e := Net._peer as ENetMultiplayerPeer
		if e == null or not is_inside_tree():
			return
		var states := []
		for pp in e.host.get_peers():
			if pp.get_state() != ENetPacketPeer.STATE_DISCONNECTED:
				states.append("%d" % pp.get_state())
		print("t=%d mp_peers=%s players=%s enet_states=%s" % [Time.get_ticks_msec(), multiplayer.get_peers(), Net.players.keys(), states])
		await get_tree().create_timer(1.0).timeout

func _client() -> void:
	left_on_purpose = true
	for i in int(Config.get_arg("loops", 6)):
		if Game.start_join("127.0.0.1", port, "C" + who) != OK:
			check(false, "join %d started" % i)
		await wait_sec(rng.randf_range(0.0, 1.5))
		print("t=%d client leaves attempt %d (local_player=%s, online=%s status=%d)" % [Time.get_ticks_msec(), i, Game.local_player != null, Net.is_online(), Net._peer.get_connection_status() if Net._peer else -1])
		Game.return_to_menu()
		await wait_frames(rng.randi_range(1, 20))
	check(Game.start_join("127.0.0.1", port, "C" + who) == OK, "final join")
	print("t=%d final join" % Time.get_ticks_msec())
	await wait_until(func(): return Game.local_player != null, 30.0, "final spawn")
	var m := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	print("t=%d menu status: %s" % [Time.get_ticks_msec(), m.call("get_status") if m else "-"])
	left_on_purpose = false
	await client_loop()
	finish()
