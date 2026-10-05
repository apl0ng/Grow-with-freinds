extends "res://tools/tests/qa_base.gd"
## M10 ui suite (friendslop pass): Comms, HUD marks + event banner, write-up toasts, ping markers, chat box, the
## back-room overlay with its spectator camera, the shift report, Story's new lines and the pause-menu voice controls.
## One headless process, a real solo ENet host; remote workers are faked (Net.players + world.server_spawn_player):
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/ui_m10_body.gd --port=7861
## Senders in the Comms rate-limit checks: the _rpc_* handlers are called directly (no RPC), so
## multiplayer.get_remote_sender_id() is 0 and Comms treats the packet as this peer's own (peer 1); a stranger is
## simulated by taking peer 1 out of Net.players for one call. Voice / Events are the lead's stubs: their signals are
## emitted by hand (speaking_changed, event_started / event_ended / power_changed) exactly as the real autoloads would.
## Keys go through the viewport like real presses (press + release), so GUI focus (chat line) and action routing are real.

## Default UDP port (test_all.sh passes its own).
const DEFAULT_PORT := 7861
const FAKE_WORKERS := {2: "Worker2", 3: "Worker3"}

var hud: HUD
var port: int = DEFAULT_PORT
var _chat_events: Array = []   # [peer, text]
var _ping_events: Array = []   # [peer, position]


func _run() -> void:
	_label = "ui_m10"
	await get_tree().process_frame
	port = port_arg(DEFAULT_PORT)
	Comms.chat_received.connect(func(p: int, t: String) -> void: _chat_events.append([p, t]))
	Comms.ping_received.connect(func(p: int, pos: Vector3) -> void: _ping_events.append([p, pos]))
	_section_sanitize()
	if not await _host():
		finish()
		return
	await _section_comms_limits()
	await _section_workers_marks()
	await _section_event_banner()
	await _section_ping()
	await _section_chat()
	await _section_backroom()
	await _section_report()
	await _section_pause_voice()
	step("leave")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Game.is_ui_locked(), "back in the menu, every UI lock released")
	check(get_tree().root.find_child("SpectatorCamera", true, false) == null, "no SpectatorCamera left behind")
	finish()


# --- helpers -------------------------------------------------------------------------------------------------------

func _host() -> bool:
	if get_tree().get_first_node_in_group(Game.MENU_GROUP) == null:
		get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
		await wait_frames(2)
	if not check(Game.start_host("Reviewer", port) == OK, "hosting on port %d" % port):
		return false
	if not await wait_until(func() -> bool: return Game.local_player != null, 5.0, "world + local player"):
		return false
	hud = Game.world.get_node("HUD") as HUD
	# Headless windows report 1280x1280; force the reference logical size (the smallest stretch "expand" allows).
	get_tree().root.size = Vector2i(1280, 720)
	await wait_frames(3)
	return check(hud != null and GameState.phase == GameState.Phase.WAITING, "HUD up, WAITING")


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	get_viewport().push_input(ev)


## A real key tap (press + release), then two frames for deferred reactions.
func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)
	await wait_frames(2)


func _add_fake_worker(id: int, worker_name: String, spawn: bool) -> void:
	Net.players[id] = {"name": worker_name, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	Net.players_changed.emit()
	if spawn:
		Game.world.server_spawn_player(id)


## The worker leaves: registry, departed-name memory, signals and the player node, like Net's disconnect cleanup.
func _remove_fake_worker(id: int) -> void:
	var worker_name := Net.get_player_name(id)
	Net.players.erase(id)
	Net.set(&"_departed_names", {id: worker_name})
	Net.players_changed.emit()
	Net.peer_left.emit(id)
	Game.world.server_despawn_player(id)


static func _story_gap() -> void:
	Story.tick(Story.MIN_BARK_GAP_SEC + 0.1)


## A character by code point (keeps invisible characters out of this source file).
static func _u(code: int) -> String:
	return String.chr(code)


func _ping_markers_in_world() -> int:
	var n := 0
	for child: Node in Game.world.get_children():
		if child is PingMarker and not child.is_queued_for_deletion():
			n += 1
	return n


# --- Comms.sanitize_chat -------------------------------------------------------------------------------------------

func _section_sanitize() -> void:
	step("sanitize_chat")
	check(Comms.sanitize_chat("hello\u0001\u0002 world") == "hello world", "control characters dropped")
	check(Comms.sanitize_chat("he" + _u(0x200B) + "llo" + _u(0xFEFF)) == "hello", "zero-width / BOM dropped")
	check(Comms.sanitize_chat(_u(0x202E) + "abc" + _u(0x202C)) == "abc", "BiDi overrides dropped")
	check(Comms.sanitize_chat("a\t\n  b\r\n" + _u(0x00A0) + "c") == "a b c", "whitespace collapsed to single spaces")
	check(Comms.sanitize_chat("x".repeat(300)).length() == Comms.CHAT_MAX_CHARS, "300 chars clamp to %d" % Comms.CHAT_MAX_CHARS)
	check(Comms.sanitize_chat("   ") == "" and Comms.sanitize_chat("") == "" and Comms.sanitize_chat(_u(0x200B) + _u(0x07)) == "",
			"blank / invisible-only input is empty")
	check(Comms.sanitize_chat("  keep [this] ok  ") == "keep [this] ok", "trimmed, plain text kept")
	check(ChatBox.escape_bbcode("[b]x[/b]") == "[lb]b[rb]x[lb]/b[rb]", "chat lines escape bbcode brackets")


# --- Comms rate limits + validation (direct handler calls: sender 0 = this peer) --------------------------------------

func _section_comms_limits() -> void:
	step("Comms limits (handlers called directly, sender 0 -> peer 1)")
	Comms.reset_limits()
	_chat_events.clear()
	_ping_events.clear()
	Comms._rpc_chat("hi")
	check(_chat_events.size() == 1 and _chat_events[0][0] == 1 and _chat_events[0][1] == "hi", "a direct _rpc_chat lands as peer 1: %s" % [_chat_events])
	Comms._rpc_chat("again")
	check(_chat_events.size() == 1, "a second line within CHAT_MIN_GAP_SEC is dropped")
	await wait_sec(Comms.CHAT_MIN_GAP_SEC + 0.15)
	Comms._rpc_chat("  later\u0001  ")
	check(_chat_events.size() == 2 and _chat_events[1][1] == "later", "after the gap the line lands, sanitized again on receive")
	await wait_sec(Comms.CHAT_MIN_GAP_SEC + 0.15)
	Comms._rpc_chat("")
	Comms._rpc_chat(_u(0x200B) + " " + _u(0x07))
	Comms._rpc_chat("y".repeat(Comms.CHAT_MAX_RAW_CHARS + 1))
	check(_chat_events.size() == 2, "empty, invisible-only and oversized payloads are dropped")
	var saved: Dictionary = Net.players.duplicate(true)
	Net.players.erase(1)
	Comms._rpc_chat("ghost")
	Comms._rpc_ping(Game.local_player.global_position)
	Net.players = saved
	check(_chat_events.size() == 2 and _ping_events.is_empty(), "a sender that is not in Net.players is ignored")
	var me: Vector3 = Game.local_player.global_position
	Comms._rpc_ping(Vector3(NAN, 0.0, 0.0))
	Comms._rpc_ping(me + Vector3(Comms.PING_MAX_RANGE + 5.0, 0.0, 0.0))
	check(_ping_events.is_empty(), "non-finite and out-of-range pings are refused")
	var pings_before := GameState.get_stat(1, Const.STAT_PINGS)
	Comms._rpc_ping(me + Vector3(1.0, 0.0, 1.0))
	Comms._rpc_ping(me + Vector3(1.0, 0.0, 2.0))
	await wait_frames(1)
	check(_ping_events.size() == 1 and _ping_events[0][0] == 1, "one ping lands, the second within PING_MIN_GAP_SEC is dropped")
	check(GameState.get_stat(1, Const.STAT_PINGS) == pings_before + 1, "the host counts STAT_PINGS for the sender")
	await wait_sec(Comms.PING_MIN_GAP_SEC + 0.1)
	var sent := Comms.lines_sent
	Comms.say("one")
	Comms.say("two")
	check(Comms.lines_sent == sent + 1, "say() throttles locally: two lines in a row send one")
	var pinged := Comms.pings_sent
	Comms.ping(me + Vector3(0.0, 0.0, 1.0))
	Comms.ping(me + Vector3(0.0, 0.0, 1.5))
	Comms.ping(Vector3(INF, 0.0, 0.0))
	check(Comms.pings_sent == pinged + 1, "ping() throttles locally and refuses a non-finite point")
	await wait_sec(Comms.PING_MIN_GAP_SEC + 0.1)
	_ping_events.clear()
	_chat_events.clear()


# --- WORKERS rows: speaking mark, strikes, back-room tag; write-up toasts + Story lines -------------------------------

func _section_workers_marks() -> void:
	step("WORKERS marks")
	for id: int in FAKE_WORKERS:
		_add_fake_worker(id, FAKE_WORKERS[id], true)
	await wait_frames(3)
	check(hud.player_list.get_child_count() == 3 and Game.world.get_players().size() == 3, "three WORKERS rows, three player nodes")
	check(not hud.is_speaking_mark_shown(2), "silent worker: no speaking mark")
	Voice.speaking_changed.emit(2, true)
	check(hud.is_speaking_mark_shown(2), "speaking_changed(2, true) shows the mark")
	await wait_sec(HUD.SPEAK_POLL_SEC * 2.5)
	check(hud.is_speaking_mark_shown(2) and not hud.is_speaking_mark_shown(3), "the poll keeps the signalled mark, others stay silent")
	Voice.speaking_changed.emit(2, false)
	check(not hud.is_speaking_mark_shown(2), "speaking_changed(2, false) hides it")
	check(hud.banner_tip.visible and hud.banner_tip.text.contains("chat"), "WAITING tip mentions chat (%s)" % hud.banner_tip.text.c_escape())
	check(get_viewport().get_visible_rect().encloses(hud.players_panel.get_global_rect())
			and not hud.players_panel.get_global_rect().intersects(hud.banner.get_global_rect()),
			"WORKERS panel with the mark column still clear of the WAITING banner")

	step("write-ups")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 2.0, "shift running")
	Story.reset_state()
	toasts.clear()
	GameState.server_write_up(2, Const.WRITE_UP_SKIMMING)
	await wait_frames(1)
	check(hud.get_strike_marks(2) == "×", "one strike mark on the row (%s)" % hud.get_strike_marks(2))
	check(toast_seen("Worker2 written up: skimming."), "write-up toast for everyone")
	check(Story.last_bark == "Skimming, Worker2.", "Boss: '%s'" % Story.last_bark)
	GameState.server_write_up(2, Const.WRITE_UP_LOITERING)
	await wait_frames(1)
	check(hud.get_strike_marks(2) == "××", "two strike marks")
	check(Story.last_bark == "Standing around, Worker2.", "Boss: '%s'" % Story.last_bark)
	GameState.server_write_up(2, Const.WRITE_UP_SKIMMING)
	await wait_frames(1)
	check(GameState.is_in_backroom(2) and hud.is_backroom_tag_shown(2) and hud.get_strike_marks(2) == "",
			"third strike: '(back room)' tag, strikes cleared")
	check(Story.last_bark == "Worker2. Back room. Now.", "Boss says only the back-room line: '%s'" % Story.last_bark)
	check(toast_seen("Worker2 written up: skimming."), "the third write-up still toasts")
	GameState.server_write_up(1, Const.WRITE_UP_OTHER)
	await wait_frames(1)
	check(hud.get_strike_marks(1) == "×" and toast_seen("Reviewer written up."), "our own write-up: mark + plain toast")
	check(Story.last_bark == "Written up, Reviewer.", "Boss: '%s'" % Story.last_bark)
	GameState.server_release_from_backroom(2)
	await wait_frames(1)
	check(not hud.is_backroom_tag_shown(2), "release clears the tag")
	check(Story.last_bark == "Back to work, Worker2.", "Boss: '%s'" % Story.last_bark)


# --- Event banner + Story event lines ---------------------------------------------------------------------------------

func _section_event_banner() -> void:
	step("event banner")
	check(hud.get_event_text() == "", "no banner without an event")
	_story_gap()
	Events.event_started.emit(&"power_cut", {"max_seconds": 40.0})
	await wait_frames(1)
	check(hud.get_event_text() == "POWER CUT" and hud.event_hint.visible and hud.event_hint.text == "Find the breaker.",
			"POWER CUT banner + hint (%s)" % hud.get_event_text())
	check(Story.last_bark == "Not my problem.", "Boss: '%s'" % Story.last_bark)
	await wait_sec(0.4) # pop-in done
	var quota_rect := hud.quota_panel.get_global_rect()
	var event_rect := hud.event_panel.get_global_rect()
	check(absf(quota_rect.get_center().x - 640.0) < 2.0 and absf(event_rect.get_center().x - 640.0) < 2.0
			and event_rect.position.y >= quota_rect.end.y and event_rect.position.y < quota_rect.end.y + 24.0
			and not event_rect.intersects(hud.players_panel.get_global_rect()),
			"event banner centred right under the payment bar (payment %s, event %s)" % [quota_rect, event_rect])
	_story_gap()
	Events.power_changed.emit(true)
	check(Story.last_bark == "…Took you long enough.", "power back: '%s'" % Story.last_bark)
	Events.event_ended.emit(&"power_cut")
	await wait_frames(1)
	check(hud.get_event_text() == "", "event_ended hides the banner")
	_story_gap()
	Events.event_started.emit(&"inspection", {"seconds": 35.0})
	await wait_frames(1)
	check(hud.get_event_text() == "INSPECTION" and hud.event_hint.visible and hud.event_hint.text == HUD.TEXT_READ_INSPECTION_HINT, "INSPECTION banner with its answer (%s / %s)" % [hud.get_event_text(), hud.event_hint.text])  # M19 readability: every hint names its answer (was: no hint)
	check(Story.last_bark == "Walking the floor. Don't make me stop.", "Boss: '%s'" % Story.last_bark)
	Events.event_ended.emit(&"inspection")
	_story_gap()
	check(hud.get_event_text() == "" and Story.last_bark == "…Back to the window.", "inspection over: '%s'" % Story.last_bark)
	for kind_line: Array in [[&"audit", "AUDIT", "The number went up."], [&"rat", "RAT", "Rats. Not my problem either."]]:
		_story_gap()
		Events.event_started.emit(kind_line[0], {})
		await wait_frames(1)
		check(hud.get_event_text() == kind_line[1] and Story.last_bark == kind_line[2],
				"%s: banner '%s', Boss '%s'" % [kind_line[0], hud.get_event_text(), Story.last_bark])
		Events.event_ended.emit(kind_line[0])
	await wait_frames(1)
	check(hud.get_event_text() == "", "banner hidden again")


# --- Pings: ray from the camera, markers under the world ------------------------------------------------------------

func _section_ping() -> void:
	step("ping")
	_ping_events.clear()
	var stat_before := GameState.get_stat(1, Const.STAT_PINGS)
	var point := hud.get_ping_point()
	check(point.is_finite() and point.distance_to(Game.local_player.global_position) <= HUD.PING_RAY_LENGTH + 0.5,
			"ping point from the camera is finite and in range (%s)" % point)
	check(hud.ping_here(), "ping_here() pings")
	await wait_frames(1)
	check(_ping_events.size() == 1 and _ping_events[0][0] == 1, "our ping came back through Comms as peer 1")
	var mine: Node = hud.get_ping_marker(1)
	check(mine is PingMarker and mine.get_parent() == Game.world, "a PingMarker for us sits under Game.world")
	check(GameState.get_stat(1, Const.STAT_PINGS) == stat_before + 1, "STAT_PINGS counted this shift")
	var pos := Game.local_player.global_position + Vector3(2.0, 0.0, 0.0)
	Comms.ping_received.emit(2, pos)
	var first: Node = hud.get_ping_marker(2)
	check(first is PingMarker and is_equal_approx((first as Node3D).global_position.y, pos.y + PingMarker.HEIGHT),
			"a remote ping spawns a marker %.1f m above the point" % PingMarker.HEIGHT)
	Comms.ping_received.emit(2, pos + Vector3(0.0, 0.0, 1.0))
	var second: Node = hud.get_ping_marker(2)
	check(second != null and second != first and (first == null or not is_instance_valid(first) or first.is_queued_for_deletion()),
			"a new ping by the same worker replaces their marker")
	await wait_sec(PingMarker.LIFETIME_SEC + 0.6)
	check(hud.get_ping_marker(2) == null and hud.get_ping_marker(1) == null and _ping_markers_in_world() == 0,
			"markers freed after %.0f s" % PingMarker.LIFETIME_SEC)
	_ping_events.clear()
	await _tap(KEY_X)
	check(_ping_events.size() == 1, "the ping action (X) pings through the HUD")
	await wait_sec(PingMarker.LIFETIME_SEC + 0.6)


# --- Chat box ----------------------------------------------------------------------------------------------------

func _section_chat() -> void:
	step("chat")
	var chat: ChatBox = hud.chat
	_chat_events.clear()
	check(not chat.is_open() and not Game.is_ui_locked(), "chat closed, no lock")
	await _tap(KEY_T)
	check(chat.is_open() and Game.is_ui_locked_by(ChatBox.LOCK_SOURCE), "T opens the chat line and takes the &\"chat\" lock")
	check(get_viewport().gui_get_focus_owner() == chat.line_edit, "the line has the keyboard")
	chat.line_edit.text = "hello there"
	await _tap(KEY_ENTER)
	check(not chat.is_open() and not Game.is_ui_locked_by(ChatBox.LOCK_SOURCE), "Enter sends and closes, lock released")
	check(_chat_events.size() == 1 and _chat_events[0][0] == 1 and _chat_events[0][1] == "hello there",
			"our line came back through Comms (%s)" % [_chat_events])
	check(chat.get_line_count() == 1 and chat.get_last_line_text().contains("hello there")
			and chat.get_last_line_text().contains("Reviewer"), "the log shows 'Reviewer: hello there' (%s)" % chat.get_last_line_text())
	await wait_sec(Comms.CHAT_MIN_GAP_SEC + 0.1)
	await _tap(KEY_T)
	check(chat.is_open(), "opened again")
	chat.line_edit.text = "never sent"
	await _tap(KEY_ESCAPE)
	check(not chat.is_open() and not Game.is_ui_locked(), "Escape closes the line and releases the lock")
	check(not hud.pause_menu.is_open(), "that Escape did not open the pause menu")
	check(_chat_events.size() == 1, "the dropped text was not sent")
	for i in 8:
		Comms.chat_received.emit(2, "line %d" % i)
	check(chat.get_line_count() == ChatBox.MAX_LINES, "log keeps at most %d lines" % ChatBox.MAX_LINES)
	await _tap(KEY_ESCAPE)
	check(hud.pause_menu.is_open(), "pause menu open (Escape with nothing else up)")
	await _tap(KEY_T)
	check(not chat.is_open(), "T does nothing while another overlay holds the lock")
	await _tap(KEY_ESCAPE)
	check(not hud.pause_menu.is_open() and not Game.is_ui_locked(), "pause menu closed again")
	var vp := get_viewport().get_visible_rect()
	check(vp.encloses(chat.get_global_rect()) and not chat.get_global_rect().intersects(hud.players_panel.get_global_rect()),
			"chat box on screen, clear of the WORKERS list (%s)" % chat.get_global_rect())


# --- Back room overlay + spectator camera -------------------------------------------------------------------------

func _section_backroom() -> void:
	step("back room")
	var br: BackRoomOverlay = hud.back_room
	var my_cam: Camera3D = Game.local_player.camera
	check(not br.is_open() and my_cam.current, "overlay hidden, our camera current")
	Story.reset_state()
	check(GameState.server_send_to_backroom(1, 6.0), "sent to the back room for 6 s")
	await wait_frames(2)
	check(br.is_open() and br.visible, "overlay shown")
	check(Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), "UI_LOCK_BACKROOM held")
	var cam := br.get_spectator_camera()
	check(cam != null and cam.current and cam.name == "SpectatorCamera" and cam.get_parent() == Game.world
			and get_viewport().get_camera_3d() == cam, "SpectatorCamera under Game.world is current")
	check(not my_cam.current, "our own camera is not current while spectating")
	check(br.title_label.text == "BACK ROOM" and br.body_label.text == "He's talking at you. Don't answer.", "copy")
	check(br.timer_label.text.begins_with("0:0"), "countdown '%s'" % br.timer_label.text)
	check(br.get_watched_peer() == 2 and br.watching_label.text.begins_with("Watching: Worker2"),
			"watching the first worker on the floor (%s)" % br.watching_label.text)
	check(Story.last_bark == "Reviewer. Back room. Now.", "Boss: '%s'" % Story.last_bark)
	await _tap(KEY_D)
	check(br.get_watched_peer() == 3, "D -> next worker (3)")
	var target: Player = Game.world.get_player(3)
	var head: Vector3 = target.head.global_position
	var d := cam.global_position.distance_to(head)
	check(d > 1.8 and d < 3.0 and cam.global_position.y > head.y, "camera behind and above the head (%.2f m)" % d)
	await _tap(KEY_D)
	check(br.get_watched_peer() == 2, "D again wraps to 2")
	await _tap(KEY_A)
	check(br.get_watched_peer() == 3, "A -> previous (3)")
	GameState.server_send_to_backroom(3, 6.0)
	await wait_frames(2)
	check(br.get_watched_peer() == 2 and hud.is_backroom_tag_shown(3), "a worker sent to the back room leaves the targets")
	await wait_sec(0.4) # pop-in over
	check(get_viewport().get_visible_rect().encloses(br.column.get_global_rect()) and br.column.get_global_rect().size.y > 100.0,
			"overlay column on screen (%s)" % br.column.get_global_rect())
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	check(not br.is_open() and not br.visible, "released: overlay hidden")
	check(not Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM) and not Game.is_ui_locked(), "lock released")
	check(br.get_spectator_camera() == null and my_cam.current and get_viewport().get_camera_3d() == my_cam,
			"camera freed, our camera current again")
	await wait_frames(1)
	check(Game.world.get_node_or_null("SpectatorCamera") == null, "no SpectatorCamera node left under the world")
	check(Story.last_bark == "Back to work, Reviewer.", "Boss: '%s'" % Story.last_bark)
	GameState.server_release_from_backroom(3)
	await wait_frames(1)


# --- Shift report ------------------------------------------------------------------------------------------------

func _section_report() -> void:
	step("shift report")
	var re: RoundEndOverlay = hud.round_end
	_add_fake_worker(4, "Worker4", false)
	GameState.server_add_stat(1, Const.STAT_PLANTED, 2)
	GameState.server_add_stat(2, Const.STAT_WATERED, 3)
	GameState.server_add_stat(3, Const.STAT_HARVESTED, 1)
	GameState.server_add_stat(3, Const.STAT_THROWS, 2)
	GameState.server_add_stat(3, Const.STAT_HITS, 1)
	GameState.server_add_sale(60, 2)
	GameState.server_add_sale(100, 1)
	await wait_frames(1)
	# Worker 3 leaves before the shift ends: the report still lists them from the ledger.
	_remove_fake_worker(3)
	await wait_frames(2)
	check(not Net.players.has(3) and GameState.stats.has(3) and Net.get_player_name(3) == "Worker3", "departed worker: gone from Net, kept in the ledger")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and re.is_open(), "shift paid: round-end overlay up")
	var report: ShiftReport = re.report
	check(report.get_row_peers() == [1, 2, 3, 4], "rows: every worker + the one that left (%s)" % [report.get_row_peers()])
	check(report.get_cell_text(0, 0) == "WORKER" and report.get_cell_text(0, 6) == "THROWS/HITS", "header row")
	check(report.get_cell_text(1, 0) == "Reviewer" and report.get_cell_text(3, 0) == "Worker3 (left)",
			"names ('%s', '%s')" % [report.get_cell_text(1, 0), report.get_cell_text(3, 0)])
	check(report.get_cell_text(2, 1) == "$60" and report.get_cell_text(2, 3) == "3" and report.get_cell_text(2, 5) == "3",
			"Worker2: deposited $60, watered 3, write-ups 3")
	check(report.get_cell_text(3, 4) == "1" and report.get_cell_text(3, 6) == "2/1", "Worker3: harvested 1, throws/hits 2/1")
	check(report.get_cell_text(1, 5) == "1" and report.get_cell_text(4, 1) == "$0", "Reviewer 1 write-up, Worker4 nothing")
	var verdicts := report.get_verdict_texts()
	check(verdicts == PackedStringArray(["Least useful: Worker2.", "He noticed: Reviewer.", "Worst behaved: Worker2."]),
			"verdicts %s" % [verdicts])
	check(verdicts == Story.get_report_verdicts(), "verdicts come from Story.get_report_verdicts()")
	var vp := get_viewport().get_visible_rect()
	await wait_sec(0.5) # the card's pop-in must be over: a scaled rect would pass any fit check
	check(vp.encloses(re.card.get_global_rect()) and re.card.get_global_rect().size.y > 400.0,
			"round-end card with 4 report rows fits 1280x720 (%s)" % re.card.get_global_rect())
	GameState.server_add_stat(2, Const.STAT_PLANTED, 5)
	await wait_frames(1)
	check(report.get_cell_text(2, 2) == "5", "stats_changed refreshes the open report")
	# Verdict rules on synthetic ledgers (host-local: the state is restored right after).
	var saved_players: Dictionary = Net.players.duplicate(true)
	var saved_stats: Dictionary = GameState.stats.duplicate(true)
	Net.players = {1: saved_players[1]}
	GameState.stats = {}
	check(Story.get_report_verdicts() == PackedStringArray(["Least useful: Reviewer."]), "single worker, nothing deposited: only 'Least useful'")
	GameState.stats = {1: {Const.STAT_DEPOSITED: 40}}
	check(Story.get_report_verdicts() == PackedStringArray(["He noticed: Reviewer."]), "single worker who deposited: only 'He noticed'")
	Net.players = {1: saved_players[1], 2: saved_players[2]}
	GameState.stats = {}
	check(Story.get_report_verdicts() == PackedStringArray(["Least useful: Reviewer."]), "two idle workers: ties go to the lowest id, no other verdicts")
	GameState.stats = {1: {Const.STAT_WRITE_UPS: 1}, 2: {Const.STAT_PLANTED: 1}}
	check(Story.get_report_verdicts() == PackedStringArray(["Least useful: Reviewer.", "Worst behaved: Reviewer."]),
			"write-ups drag the score down; 'He noticed' needs a deposit")
	Net.players = saved_players
	GameState.stats = saved_stats
	Net.players_changed.emit()
	await wait_frames(1)
	# Missed shift: the report shows on the failure screen too (fresh ledger, live workers only).
	re.primary_button.pressed.emit()
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 2, "shift 2 running")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "shift 2 missed")
	await wait_frames(2)
	check(re.is_open() and report.get_row_peers() == [1, 2, 4], "failure screen: report rows for the live workers (%s)" % [report.get_row_peers()])
	check(report.get_verdict_texts() == PackedStringArray(["Least useful: Reviewer."]), "nobody did anything: %s" % [report.get_verdict_texts()])
	await wait_sec(0.5)
	check(vp.encloses(re.card.get_global_rect()) and re.card.get_global_rect().size.y > 400.0, "failure card fits 1280x720 (%s)" % re.card.get_global_rect())
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and not re.is_open(), "START OVER -> WAITING, overlay gone")


# --- Pause menu voice controls -------------------------------------------------------------------------------------

func _section_pause_voice() -> void:
	step("pause menu voice settings")
	var pm: PauseMenu = hud.pause_menu
	var enabled0: bool = Voice.enabled
	var ptt0: bool = Voice.push_to_talk
	var vol0: float = Voice.output_volume_db
	await _tap(KEY_ESCAPE)
	check(pm.is_open(), "pause menu open")
	check(pm.mic_toggle.button_pressed == enabled0 and pm.ptt_toggle.button_pressed == ptt0
			and is_equal_approx(pm.volume_slider.value, clampf(vol0, PauseMenu.VOLUME_MIN_DB, PauseMenu.VOLUME_MAX_DB)),
			"controls reflect Voice (mic %s, ptt %s, %.0f dB)" % [enabled0, ptt0, vol0])
	check(pm.no_mic_label.visible == (not Voice.is_mic_available()), "'No microphone found.' follows Voice.is_mic_available()")
	# M19 settings: the keys moved onto the OPTIONS card; the ON BREAK card keeps one line pointing there.
	check(pm.controls_label.text == "Keys, mouse, screen and sound: OPTIONS.", "controls: the ON BREAK pointer line ('%s')" % pm.controls_label.text)
	var keys := pm.options.get_key_texts()
	check(keys.has("RMB throw") and keys.has("F shove") and keys.has("MMB ping") and keys.has("T chat") and keys.has("V talk")
			and keys.has("1-4 gestures"), "the M10 keys (+ the M18 gesture keys) on the OPTIONS card (%s)" % ", ".join(keys))
	pm.mic_toggle.button_pressed = not enabled0
	check(Voice.enabled == (not enabled0), "Microphone toggle writes Voice.enabled")
	pm.ptt_toggle.button_pressed = not ptt0
	check(Voice.push_to_talk == (not ptt0), "Push to talk toggle writes Voice.push_to_talk")
	pm.volume_slider.value = -12.0
	check(is_equal_approx(Voice.output_volume_db, -12.0) and pm.volume_value.text == "-12 dB", "volume slider writes Voice.output_volume_db (%s)" % pm.volume_value.text)
	Voice.input_level_changed.emit(0.5)
	check(is_equal_approx(pm.input_meter.value, 0.5), "input meter follows Voice.input_level_changed")
	check(pm.meter_row.visible == Voice.is_mic_available(), "the meter row shows only with a microphone")
	await wait_sec(0.5) # pop-in over before measuring
	var pause_rect := pm.card.get_global_rect()
	check(get_viewport().get_visible_rect().encloses(pause_rect) and pause_rect.size.y > 300.0 and pause_rect.size.y <= 660.0,
			"pause card with the voice section fits 1280x720 with margin (%s)" % pause_rect)
	Voice.enabled = enabled0
	Voice.push_to_talk = ptt0
	Settings.set_value(&"voice_db", vol0) # M19 settings: the voice volume is a setting (it applies the Voice bus)
	pm.sync_voice_controls()
	check(pm.mic_toggle.button_pressed == enabled0 and is_equal_approx(pm.volume_slider.value, vol0) and is_equal_approx(Voice.output_volume_db, vol0),
			"sync_voice_controls re-reads Voice and the voice volume setting")
	await _tap(KEY_ESCAPE)
	check(not pm.is_open() and not Game.is_ui_locked(), "pause menu closed")
