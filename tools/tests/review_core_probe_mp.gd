extends "res://tools/tests/qa_net_base.gd"
## Exploratory churn probe 2: the HOST re-hosts repeatedly while clients join / cancel / fail; then converge.

var role := ""
var who := ""
var port := 8600
var rng := RandomNumberGenerator.new()

func _run() -> void:
	role = str(Config.get_arg("role", "h"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 8600))
	rng.seed = int(Config.get_arg("seed", 1)) * 7919 + who.hash()
	_label = "churn2:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host()
	else:
		await _client()

func _host() -> void:
	print("CHURN_HOST_READY")
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 12000:
		if Game.start_host("Hosty", port) != OK:
			await wait_sec(0.2)
			continue
		var t1 := Time.get_ticks_msec()
		var up := rng.randf_range(0.3, 2.5)
		while Time.get_ticks_msec() - t1 < up * 1000.0:
			await wait_sec(rng.randf_range(0.05, 0.4))
			match rng.randi() % 4:
				0: GameState.request_start_round()
				1:
					if GameState.phase == GameState.Phase.PLAYING: GameState.time_left = 0.05
				2: GameState.request_retry()
				3: GameState.request_next_round()
		Game.return_to_menu("cycle")
		await wait_frames(rng.randi_range(1, 30))
	check(Game.start_host("Hosty", port) == OK, "final host")
	var stable_since := Time.get_ticks_msec()
	var last_ids := []
	var t_wait := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t_wait < 60000:
		var ids := Net.get_peer_ids()
		if ids != last_ids or ids.size() != 4:
			last_ids = ids
			stable_since = Time.get_ticks_msec()
		elif Time.get_ticks_msec() - stable_since > 5000:
			break
		await get_tree().process_frame
	check(Net.players.size() == 4 and Game.world.get_players().size() == 4, "all three clients in, registry stable 5 s")
	var peers := []
	for id in Net.get_peer_ids():
		if id != 1: peers.append(id)
	await checkpoint_peers("settled", peers, {}, true)
	GameState.request_start_round()
	await wait_sec(1.0)
	await checkpoint_peers("after start", peers, {}, true)
	allow_error("Unable to send packet on channel 0", 6, true)
	for p in peers: cmd(p, "finish")
	await wait_sec(2.0)
	finish()

func _client() -> void:
	left_on_purpose = true
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 12000:
		Game.start_join("127.0.0.1", port, "C" + who)
		var t1 := Time.get_ticks_msec()
		var stay := rng.randf_range(0.0, 3.0)
		while Time.get_ticks_msec() - t1 < stay * 1000.0 and Game.world != null:
			await get_tree().process_frame
		if Game.world != null:
			Game.return_to_menu()
		await wait_frames(rng.randi_range(1, 20))
	# final: keep trying until in
	var ok := false
	for i in 20:
		if Game.world == null:
			Game.start_join("127.0.0.1", port, "C" + who)
		if await wait_until_quiet(func(): return Game.local_player != null or Game.world == null, 6.0) and Game.local_player != null:
			ok = true
			break
		if Game.world != null:
			Game.return_to_menu()
		await wait_frames(5)
	check(ok, "final join")
	_queue.clear()
	left_on_purpose = false
	await client_loop()
	finish()
