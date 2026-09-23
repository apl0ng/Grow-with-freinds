extends "res://tools/tests/qa_base.gd"
## Review 9.1 REPRO (not part of tools/test_all.sh: it documents an UNFIXED issue and fails while it reproduces).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_core_slots_repro.gd --port=7977
##
## Net.host() creates the ENet server with max_players (= 4) client slots: max_players - 1 players + ONE spare
## (CONTRACTS.md "Server slots = max_players + 1"). A connection whose client vanished during the ENet handshake
## (cancelled / crashed / timed out before the host's VERIFY_CONNECT arrived: a client that is not addressable yet
## cannot send a disconnect) keeps its slot on the host until ENet times it out, 5-30 s later. Godot never reports
## such a half-open peer (no peer_connected, not in ENetConnection.get_peers()), so Net cannot drop it.
## Here: 2 players are in (raw ENet stand-ins), 2 half-open handshakes linger -> the host's last free slots are gone
## and the 3rd player (4th worker, legal) cannot even connect; the Game join attempt would time out after 12 s.
## Suggested fix (lead decision, contract text changes): more spare ENet slots, e.g. create_server(port,
## max_players + 3) - "Server is full" is still enforced at registration by _rpc_register.

func _raw_connect(port: int, timeout_ms: int) -> ENetConnection:
	var c := ENetConnection.new()
	c.create_host(1)
	c.connect_to_host("127.0.0.1", port, 3)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_ms:
		var ev: Array = c.service(0)
		if ev[0] == ENetConnection.EVENT_CONNECT:
			return c
		await get_tree().process_frame
	c.destroy()
	return null

func _run() -> void:
	_label = "slots_repro"
	await get_tree().process_frame
	var port := port_arg(7977)
	if not check(Game.start_host("Host", port) == OK, "host with max_players = %d" % Config.balance.max_players):
		finish(); return
	await wait_frames(2)
	var players: Array[ENetConnection] = []
	for i in 2:
		var p := await _raw_connect(port, 3000)
		check(p != null, "player %d connects" % (i + 2))
		if p != null:
			players.append(p)
	# Two clients vanish mid-handshake (CONNECT sent, VERIFY never acknowledged).
	for i in 2:
		var z := ENetConnection.new()
		z.create_host(1)
		z.connect_to_host("127.0.0.1", port, 3)
		z.service(0)
		z.destroy()
	await wait_sec(0.3)
	var last := await _raw_connect(port, 5000)
	check(last != null, "a legal 4th worker can connect while only 3 of %d player slots are used (blocked by 2 half-open handshakes)" % Config.balance.max_players)
	if last != null:
		last.destroy()
	for p in players:
		p.destroy()
	finish()
