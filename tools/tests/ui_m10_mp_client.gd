extends "res://tools/tests/qa_base.gd"
## Client side of the M10 ui two-process suite (tools/tests/ui_m10_mp.sh). Pairs with ui_m10_mp_host.gd.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/ui_m10_mp_client.gd --port=7862

const DEFAULT_PORT := 7862
const TEXT_FROM_HOST := "Back to work."


## Dirty on purpose: a control character and a zero-width space; the receivers must see "hello there".
static func _dirty_text() -> String:
	return "hello" + String.chr(0x01) + " " + String.chr(0x200B) + "there"

var _chat_events: Array = []   # [peer, text]
var _ping_events: Array = []   # [peer, position]


func _run() -> void:
	_label = "ui_m10_client"
	await get_tree().process_frame
	var port := port_arg(DEFAULT_PORT)
	Comms.chat_received.connect(func(p: int, t: String) -> void: _chat_events.append([p, t]))
	Comms.ping_received.connect(func(p: int, pos: Vector3) -> void: _ping_events.append([p, pos]))

	step("joining 127.0.0.1:%d" % port)
	Game.start_join("127.0.0.1", port, "Client")
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 30.0, "world + local player")
	if Game.world == null or Game.local_player == null:
		finish(); return
	var my_id := multiplayer.get_unique_id()
	check(not Net.is_host and my_id != 1, "not host (id %d)" % my_id)
	var hud: HUD = Game.world.get_node("HUD") as HUD
	await wait_until(func() -> bool: return GameState.is_playing(), 30.0, "PLAYING synced")
	await wait_sec(0.5) # let our position reach the host before it range-checks the ping

	step("say + ping")
	Comms.say(_dirty_text())
	await wait_until(func() -> bool: return _chat_events.size() >= 1, 5.0, "our own line came back locally")
	check(_chat_events.size() >= 1 and int(_chat_events[0][0]) == my_id and String(_chat_events[0][1]) == "hello there",
			"local copy is sanitized and carries our id (%s)" % [_chat_events])
	Comms.ping(Game.local_player.global_position + Vector3(1.0, 0.0, 1.0))
	await wait_until(func() -> bool: return _ping_events.size() >= 1 and int(_ping_events[0][0]) == my_id, 5.0, "our own ping came back locally")
	check(hud.get_ping_marker(my_id) is PingMarker, "our ping marker is shown here too")
	await wait_until(func() -> bool: return GameState.get_stat(my_id, Const.STAT_PINGS) == 1, 10.0, "STAT_PINGS synced back from the host")

	step("host chat")
	await wait_until(func() -> bool:
		for e in _chat_events:
			if int(e[0]) == 1 and String(e[1]) == TEXT_FROM_HOST:
				return true
		return false, 20.0, "the host's line arrived")
	check(hud.chat.get_line_count() >= 2 and hud.chat.get_last_line_text().contains(TEXT_FROM_HOST)
			and hud.chat.get_last_line_text().contains("Host"), "chat log shows 'Host: %s' (%s)" % [TEXT_FROM_HOST, hud.chat.get_last_line_text()])

	step("leave")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Game.is_ui_locked(), "world freed, no locks")
	finish()
