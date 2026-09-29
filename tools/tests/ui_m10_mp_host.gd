extends "res://tools/tests/qa_base.gd"
## Host side of the M10 ui two-process suite (tools/tests/ui_m10_mp.sh). Pairs with ui_m10_mp_client.gd.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/ui_m10_mp_host.gd --port=7862
## Checks that a client's chat line reaches the host's Comms.chat_received sanitized and with the client's id, that a
## client ping reaches the host (marker + STAT_PINGS on the host), and that the host's own line goes out to the client.

const DEFAULT_PORT := 7862
const TEXT_TO_CLIENT := "Back to work."

var _chat_events: Array = []   # [peer, text]
var _ping_events: Array = []   # [peer, position]


func _run() -> void:
	_label = "ui_m10_host"
	await get_tree().process_frame
	var port := port_arg(DEFAULT_PORT)
	Comms.chat_received.connect(func(p: int, t: String) -> void: _chat_events.append([p, t]))
	Comms.ping_received.connect(func(p: int, pos: Vector3) -> void: _ping_events.append([p, pos]))

	step("hosting on %d" % port)
	check(Game.start_host("Host", port) == OK, "hosting")
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		finish(); return
	var hud: HUD = Game.world.get_node("HUD") as HUD

	step("waiting for the client")
	await wait_until(func() -> bool: return Net.players.size() == 2, 40.0, "client registered")
	var client_id := 0
	for id in Net.players:
		if id != 1:
			client_id = int(id)
	check(client_id != 0, "client id known (%d)" % client_id)
	await wait_until(func() -> bool: return Game.world.get_player(client_id) != null, 10.0, "client Player node spawned on host")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "PLAYING")

	step("client chat")
	await wait_until(func() -> bool:
		for e in _chat_events:
			if int(e[0]) == client_id:
				return true
		return false, 20.0, "a chat line from the client arrived")
	var from_client: Array = []
	for e in _chat_events:
		if int(e[0]) == client_id:
			from_client.append(e[1])
	check(from_client == ["hello there"], "the client's line arrived sanitized (%s)" % [from_client])
	check(hud.chat.get_line_count() >= 1 and hud.chat.get_last_line_text().contains("hello there")
			and hud.chat.get_last_line_text().contains("Client"), "host chat log shows 'Client: hello there' (%s)" % hud.chat.get_last_line_text())

	step("client ping")
	await wait_until(func() -> bool:
		for e in _ping_events:
			if int(e[0]) == client_id:
				return true
		return false, 20.0, "a ping from the client arrived")
	await wait_frames(1)
	check(GameState.get_stat(client_id, Const.STAT_PINGS) == 1, "STAT_PINGS of the client incremented on the host (%d)" % GameState.get_stat(client_id, Const.STAT_PINGS))
	var marker: Node = hud.get_ping_marker(client_id)
	check(marker is PingMarker and marker.get_parent() == Game.world, "host shows the client's ping marker")
	var client_player: Player = Game.world.get_player(client_id)
	var ping_pos: Vector3 = _ping_events.back()[1]
	check(client_player != null and ping_pos.distance_to(client_player.global_position) <= Comms.PING_MAX_RANGE, "ping within range of the client's player")

	step("host chat to the client")
	Comms.say(TEXT_TO_CLIENT)
	await wait_until(func() -> bool:
		for e in _chat_events:
			if int(e[0]) == 1 and String(e[1]) == TEXT_TO_CLIENT:
				return true
		return false, 5.0, "our own line landed locally (call_local)")

	step("waiting for the client to leave")
	await wait_until(func() -> bool: return Net.players.size() == 1, 60.0, "client left")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Game.is_ui_locked(), "world freed, no locks")
	finish()
