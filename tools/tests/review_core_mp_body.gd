extends "res://tools/tests/qa_base.gd"
## Review 9.1 (core/net/flow) multi-process regression suite, driven by tools/tests/review_core_mp.sh.
## Four processes run this body: --role=h (first host), --role=a (client, then re-hosts), --role=b (late joiner),
## --role=r (rogue client). Steps are handshaked through marker files in --sync-dir (no fixed sleeps between processes):
##   M0  a rogue (modified) client registers with a 300 000-character name: the host's main thread must not stall
##       (Net.sanitize_name used to be quadratic: seconds of frozen game for everyone) and the name is clamped;
##       then it syncs a NaN position and asks to pick up a watering can across the room: the server-side range
##       check must refuse it (a NaN distance used to pass `distance > max`)
##   M1  B joins LATE while H's shift has already failed: B's round-end overlay and its UI lock are up, the
##       connecting lock is gone, B is not the host; H's RETRY clears the overlay / lock on A and B and prices the
##       new shift for three workers on every peer
##   M2  H leaves: A and B are returned to the menu with "Host disconnected", fully clean (no lock, MENU, offline)
##   M3  re-host after a client session: A (a client until now) hosts on port+1, B and the old host H join it;
##       authority moved with the session: A's own timer ends A's shift on every peer, A is the local host and
##       H / B are not; A leaves and both are returned to the menu cleanly
## Every engine/script error fails the run unless announced (qa_base.gd).

const STEP_TIMEOUT := 30.0

var role: String = "h"
var port: int = 7990
var sync_dir: String = ""

func _run() -> void:
	role = str(Config.get_arg("role", "h"))
	port = int(Config.get_arg("port", 7990))
	sync_dir = str(Config.get_arg("sync-dir", ""))
	_label = "review_core_mp:" + role
	await get_tree().process_frame
	Config.growth_speed_override = 0.0
	match role:
		"h": await _host_h()
		"a": await _client_a()
		"b": await _client_b()
		"r": await _rogue_r()
	finish()

# --- marker files ------------------------------------------------------------------------------------------------

func mark(tag: String) -> void:
	var f := FileAccess.open(sync_dir.path_join(tag), FileAccess.WRITE)
	if f != null:
		f.store_string(str(Time.get_ticks_msec()))
		f.close()
	print("REVIEW_CORE_MARK " + tag)

func wait_mark(tag: String, timeout: float = STEP_TIMEOUT) -> bool:
	return await wait_until(func(): return FileAccess.file_exists(sync_dir.path_join(tag)), timeout, "[%s] saw marker '%s'" % [role, tag])

# --- helpers -------------------------------------------------------------------------------------------------------

func _hud() -> HUD:
	return Game.world.get_node_or_null("HUD") as HUD if Game.world != null else null

func _overlay_up() -> bool:
	var hud := _hud()
	return hud != null and hud.round_end.visible and Game.is_ui_locked_by(&"round_end")

func _menu_status() -> String:
	var m := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	return String(m.call("get_status")) if m != null else "<no menu>"

## Joins ip:port and waits for the local player; retries when an attempt ends back in the menu.
func _join(p: int, who: String) -> bool:
	for attempt in 3:
		if Game.start_join("127.0.0.1", p, who) != OK:
			continue
		if await wait_until_quiet(func(): return Game.local_player != null or Game.world == null, 15.0) and Game.local_player != null:
			return true
		if Game.world != null:
			Game.return_to_menu()
		await wait_frames(3)
	return false

func wait_until_quiet(pred: Callable, timeout_sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_sec * 1000.0:
		if bool(pred.call()):
			return true
		await get_tree().process_frame
	return bool(pred.call())

func _check_menu_clean(tag: String, status: String) -> void:
	check(Game.world == null and Game.local_player == null and not Game.is_ui_locked(), "%s: world freed, no UI lock" % tag)
	check(GameState.phase == GameState.Phase.MENU and not GameState.is_local_host(), "%s: GameState back to MENU" % tag)
	check(not Net.is_online() and Net.players.is_empty(), "%s: offline, registry empty" % tag)
	check(_menu_status() == status, "%s: menu says '%s' (got '%s')" % [tag, status, _menu_status()])

# ============================================================================================================ H

func _host_h() -> void:
	check(Game.start_host("Hosty", port) == OK, "H hosts on %d" % port)
	await wait_until(func(): return Game.local_player != null, 10.0, "H world ready")
	mark("h_ready")
	# M0: the rogue registers with a huge name; measure the host's longest frame meanwhile.
	var worst_ms := 0.0
	var last := Time.get_ticks_usec()
	var t_rogue := Time.get_ticks_msec()
	while Net.players.size() < 2 and Time.get_ticks_msec() - t_rogue < STEP_TIMEOUT * 1000.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		worst_ms = maxf(worst_ms, (now - last) / 1000.0)
		last = now
	if not check(Net.players.size() == 2, "rogue registered"):
		return
	var rogue_id: int = Net.get_peer_ids()[1]
	check(worst_ms < 1000.0, "H: no main-thread stall while a peer registered with a 300k-character name (worst frame %.0f ms)" % worst_ms)
	check(Net.get_player_name(rogue_id).length() <= Net.MAX_NAME_LENGTH, "H: the rogue's name is clamped (%d chars)" % Net.get_player_name(rogue_id).length())
	# M0b: the rogue's synced position becomes NaN (the engine complains about the non-finite transform of our
	# copy of its Player every frame until it leaves: player.gd does not validate synced values).
	allow_error("!v.is_finite()", 1000000)
	mark("h_nan_ready")
	if await wait_mark("r_nan_done"):
		var rogue_player := Game.world.get_player(rogue_id)
		# Informational (player.gd accepts non-finite synced values today; if it ever rejects them the range check
		# below still has to hold, just for a finite far position).
		print("  (note: host copy of the rogue at %s)" % (rogue_player.global_position if rogue_player != null else "<gone>"))
		check(Game.world.items.get_held_by(rogue_id) == null and items_of(Const.ITEM_WATERING_CAN).all(func(it: Item) -> bool: return it.holder_id == 0),
			"H: a peer at a NaN position cannot pick up a can from across the room")
	mark("h_saw_rogue")
	await wait_until(func(): return Net.players.size() == 1 and Game.world.get_players().size() == 1, STEP_TIMEOUT, "rogue left")
	await wait_frames(2)
	clear_allowed_errors()
	mark("rogue_gone")
	if not await wait_until(func(): return Net.players.size() == 2, STEP_TIMEOUT, "A registered"):
		return
	GameState.request_start_round()
	await wait_sec(0.5)
	GameState.time_left = 0.2
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "H: shift missed by the timer")
	mark("h_failed")
	if not await wait_mark("b_saw_failed"):
		return
	check(Net.players.size() == 3 and Game.world.get_players().size() == 3, "H: B registered and spawned during ROUND_FAILED")
	GameState.request_retry()
	check(GameState.phase == GameState.Phase.WAITING and GameState.quota == Config.balance.quota_for_round(1, 3), "H: RETRY -> WAITING, shift 1 priced for 3 workers (%d)" % GameState.quota)
	mark("h_retried")
	await wait_mark("a_saw_retry")
	await wait_mark("b_saw_retry")
	# M2: the host leaves.
	Game.return_to_menu("done")
	await wait_frames(3)
	_check_menu_clean("H after leaving", "done")
	# M3: join A's new session.
	if not await wait_mark("a_hosting"):
		return
	check(await _join(port + 1, "Hosty"), "H joined A's session (the old host is now a client)")
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, STEP_TIMEOUT, "H sees A's shift end (A's timer)")
	check(not GameState.is_local_host() and not Net.is_host, "H is a client now (not the local host)")
	check(_overlay_up() and _hud().round_end.primary_button.visible == false, "H: overlay up without the host-only button")
	mark("h_saw_a_failed")
	await wait_until(func(): return Game.world == null, STEP_TIMEOUT, "H returned to the menu when A left")
	await wait_frames(2)
	_check_menu_clean("H after A left", "Host disconnected")

# ============================================================================================================ A

func _client_a() -> void:
	if not await wait_mark("rogue_gone"):
		return
	if not check(await _join(port, "Alpha"), "A joined H"):
		return
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, STEP_TIMEOUT, "A sees H's shift missed")
	await wait_mark("h_retried")
	await wait_until(func(): return GameState.phase == GameState.Phase.WAITING, STEP_TIMEOUT, "A sees the RETRY")
	check(not _overlay_up() and not Game.is_ui_locked(), "A: overlay and lock cleared by the RETRY")
	check(GameState.quota == Config.balance.quota_for_round(1, 3), "A: shift 1 priced for 3 workers (%d)" % GameState.quota)
	mark("a_saw_retry")
	await wait_until(func(): return Game.world == null, STEP_TIMEOUT, "A returned to the menu when H left")
	await wait_frames(2)
	_check_menu_clean("A after H left", "Host disconnected")
	# M3: the former client hosts.
	check(Game.start_host("Alpha", port + 1) == OK, "A hosts on %d (re-host after a client session)" % (port + 1))
	await wait_until(func(): return Game.local_player != null, 10.0, "A's world ready")
	check(GameState.is_local_host() and Net.is_host and GameState.phase == GameState.Phase.WAITING, "A is the local host, WAITING")
	check(Net.players.size() == 1 and GameState.quota == Config.balance.quota_for_round(1, 1), "A: fresh registry, solo price (%d)" % GameState.quota)
	mark("a_hosting")
	if not await wait_until(func(): return Net.players.size() == 3 and Game.world.get_players().size() == 3, STEP_TIMEOUT, "B and H joined A"):
		return
	await wait_sec(0.5)
	GameState.request_start_round()
	check(GameState.is_playing() and GameState.quota == Config.balance.quota_for_round(1, 3), "A started the shift for 3 workers")
	await wait_sec(0.5)
	GameState.time_left = 0.2
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "A's own timer ends A's shift")
	await wait_mark("h_saw_a_failed")
	await wait_mark("b_saw_a_failed")
	Game.return_to_menu("bye")
	await wait_frames(3)
	_check_menu_clean("A after leaving", "bye")

# ============================================================================================================ B

func _client_b() -> void:
	if not await wait_mark("h_failed"):
		return
	if not check(await _join(port, "Bravo"), "B joined H late (shift already missed)"):
		return
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED and _overlay_up(), 10.0, "B: late joiner sees ROUND_FAILED with the round-end overlay + lock")
	check(not Game.is_ui_locked_by(Game.LOCK_CONNECTING), "B: connecting lock released")
	check(not GameState.is_local_host() and not _hud().round_end.primary_button.visible, "B: not the host, no host-only button")
	mark("b_saw_failed")
	await wait_until(func(): return GameState.phase == GameState.Phase.WAITING, STEP_TIMEOUT, "B sees the RETRY")
	check(not _overlay_up() and not Game.is_ui_locked(), "B: overlay and lock cleared by the RETRY")
	check(GameState.quota == Config.balance.quota_for_round(1, 3) and GameState.round_number == 1, "B: shift 1 priced for 3 workers (%d)" % GameState.quota)
	mark("b_saw_retry")
	await wait_until(func(): return Game.world == null, STEP_TIMEOUT, "B returned to the menu when H left")
	await wait_frames(2)
	_check_menu_clean("B after H left", "Host disconnected")
	if not await wait_mark("a_hosting"):
		return
	check(await _join(port + 1, "Bravo"), "B joined A's session")
	await wait_until(func(): return GameState.phase == GameState.Phase.ROUND_FAILED, STEP_TIMEOUT, "B sees A's shift end (A's timer)")
	check(_overlay_up() and not GameState.is_local_host(), "B: overlay up, not the host")
	mark("b_saw_a_failed")
	await wait_until(func(): return Game.world == null, STEP_TIMEOUT, "B returned to the menu when A left")
	await wait_frames(2)
	_check_menu_clean("B after A left", "Host disconnected")


# ============================================================================================================ R

func _rogue_r() -> void:
	if not await wait_mark("h_ready"):
		return
	if not check(Game.start_join("127.0.0.1", port, "Rogue") == OK, "rogue started joining"):
		return
	# A modified client: the name sent on connect is not the sanitized one (Net.join already ran its own copy).
	Net.local_name = "R".repeat(300000)
	await wait_until(func(): return Game.local_player != null, STEP_TIMEOUT, "rogue registered and spawned")
	check(Net.local_name.length() <= Net.MAX_NAME_LENGTH, "rogue: the host assigned a clamped name (%d chars)" % Net.local_name.length())
	if await wait_mark("h_nan_ready"):
		var me: Player = Game.local_player
		me.set_physics_process(false) # stop writing the real position; $Sync keeps sending net_position
		me.net_position = Vector3(NAN, NAN, NAN)
		await wait_sec(0.4)
		var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
		var t := toasts.size()
		can.interact(me)
		await wait_until_quiet(func(): return can.holder_id != 0 or toasts.size() > t, 5.0)
		check(can.holder_id == 0, "rogue: the pickup from across the room was refused")
		check(toast_seen("Too far."), "rogue: told 'Too far.'")
		mark("r_nan_done")
	await wait_mark("h_saw_rogue")
	Game.return_to_menu("rogue done")
	await wait_frames(3)
	_check_menu_clean("rogue after leaving", "rogue done")
