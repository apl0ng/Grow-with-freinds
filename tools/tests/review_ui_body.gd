extends "res://tools/tests/qa_base.gd"
## UI review regressions (PLAN task 9.3, reviewer R3): HUD, round-end overlay, pause menu, connecting overlay.
## One headless process, a real solo ENet host (plus a join attempt to a closed port):
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_ui_body.gd --port=7991
## Keys are pushed through the viewport like real presses (press + release), so GUI focus / ui_accept routing is real.
## Sections:
##   D  connecting overlay: Escape cancels the join attempt (the Cancel button had no keyboard route)
##   E  WORKERS list never slides under the WAITING banner / payment panel at 1280 px (long names are trimmed,
##      short names and the "(host, you)" tags stay whole)
##   A  pause menu on top of the round-end overlay keeps the keyboard: the overlay must not steal focus, Tab / arrows
##      stay inside the pause card, Enter acts on BACK TO WORK (never NEXT SHIFT hidden underneath); afterwards the
##      overlay gets its focus back
##   B  a jump (Space) or Enter pressed as the shift ends does not skip the round-end screen (NEXT SHIFT / START OVER =
##      full reset for everyone); the keyboard works once the screen has been up a moment
##   C  client round-end: no default focus (Space must not LEAVE the session), but Tab / arrows reach LEAVE

## Longer than any reasonable "arm" delay of the round-end overlay's default focus.
const FOCUS_SETTLE_SEC := 1.2

var hud: HUD
var port: int = 7991


func _run() -> void:
	_label = "review_ui"
	await get_tree().process_frame
	port = port_arg(7991)
	await _section_d_connecting()
	if not await _host():
		finish()
		return
	await _section_e_workers_layout()
	await _section_a_pause_over_round_end()
	await _section_b_jump_at_shift_end()
	await _section_c_client_round_end()
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and not Game.is_ui_locked(), "back in the menu, every UI lock released")
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


func _focus() -> Control:
	return get_viewport().gui_get_focus_owner()


func _focus_name() -> String:
	var f := _focus()
	return "<none>" if f == null else str(f.get_path()).get_slice("/HUD/", 1)


static func _is_under(node: Node, ancestor: Node) -> bool:
	return node != null and ancestor != null and (node == ancestor or ancestor.is_ancestor_of(node))


func _set_host(host: bool) -> void:
	Net.set(&"is_host", host)
	GameState.set(&"_authoritative", host)


## Width the label's text needs at its current font (0 if the label has no font yet).
static func _text_width(label: Label) -> float:
	var font := label.get_theme_font(&"font")
	if font == null:
		return 0.0
	return font.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, label.get_theme_font_size(&"font_size")).x


# --- D: connecting overlay ------------------------------------------------------------------------------------------

func _section_d_connecting() -> void:
	step("D: connecting overlay, Escape cancels the join attempt")
	get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
	await wait_frames(2)
	# Nobody listens on port+1: the attempt stays pending (ENet retries) until cancelled.
	var err := Game.start_join("127.0.0.1", port + 1, "Joiner")
	await wait_frames(3)
	check(err == OK and Game.world != null and Game.is_ui_locked_by(Game.LOCK_CONNECTING),
			"joining: world up, connecting overlay holds the UI lock")
	await _tap(KEY_ESCAPE)
	await wait_frames(3)
	var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	check(Game.world == null and menu != null and not Game.is_ui_locked(),
			"Escape cancelled the join attempt: back in the menu, lock released (world=%s)" % Game.world)
	check(menu != null and String(menu.call(&"get_status")) == "", "cancelled on purpose: no error message in the menu")
	if Game.world != null:
		Game.return_to_menu()
		await wait_frames(3)


# --- E: WORKERS list vs WAITING banner ------------------------------------------------------------------------------

func _section_e_workers_layout() -> void:
	step("E: WORKERS list vs the WAITING banner and the payment panel (1280 px wide)")
	var saved: Dictionary = Net.players.duplicate(true)
	check(get_viewport().get_visible_rect().size.x <= 1280.0, "logical width %d (the narrowest the stretch mode allows)"
			% int(get_viewport().get_visible_rect().size.x))
	var cases := [
		["realistic names", {1: "Stephanie", 2: "Christopher", 3: "Bartholomew", 4: "Maximilian 2"}],
		["16-character names", {1: "MMMMMMMMMMMMMMMM", 2: "WWWWWWWWWWWWWWWW", 3: "WWWWWWWWWWWWWW 2", 4: "Bartholomew Jr.."}],
	]
	for c: Array in cases:
		var next: Dictionary = {}
		for id: int in c[1]:
			next[id] = {"name": c[1][id], "color": Net.PALETTE[id - 1]}
		Net.call(&"_apply_players", next)
		await wait_sec(0.6) # banner pop-in finished, list rebuilt
		check(hud.banner.visible and hud.players_panel.visible, "[%s] banner + WORKERS visible in WAITING" % c[0])
		var banner := hud.banner.get_global_rect()
		var players := hud.players_panel.get_global_rect()
		var quota := hud.quota_panel.get_global_rect()
		check(not players.intersects(banner), "[%s] WORKERS %s does not slide under the WAITING banner %s"
				% [c[0], players, banner])
		check(not players.intersects(quota), "[%s] WORKERS %s clear of the payment panel %s" % [c[0], players, quota])
		check(get_viewport().get_visible_rect().encloses(players), "[%s] WORKERS panel on screen" % c[0])
		# Every tag stays whole; the host's row still says who is host / you.
		var tags_whole := true
		var seen_tag := false
		for row: Node in hud.player_list.get_children():
			for child: Node in row.get_children():
				var l := child as Label
				if l != null and (l.text.contains("(host") or l.text.contains("you)")):
					seen_tag = true
					if l.size.x + 0.5 < _text_width(l):
						tags_whole = false
		check(seen_tag and tags_whole, "[%s] '(host, you)' tags shown in full" % c[0])
	# Short names are never trimmed.
	Net.call(&"_apply_players", {1: {"name": "Dale", "color": Net.PALETTE[0]}, 2: {"name": "Gus", "color": Net.PALETTE[1]}})
	await wait_frames(3)
	var all_fit := true
	for row: Node in hud.player_list.get_children():
		for child: Node in row.get_children():
			var l := child as Label
			if l != null and l.size.x + 0.5 < _text_width(l):
				all_fit = false
	check(all_fit and hud.player_list.get_child_count() == 2, "short names shown in full")
	Net.call(&"_apply_players", saved)
	await wait_frames(2)


# --- A: pause menu on top of the round-end overlay ------------------------------------------------------------------

func _section_a_pause_over_round_end() -> void:
	step("A: pause menu open when the shift ends (host)")
	var pm := hud.pause_menu
	var re := hud.round_end
	GameState.request_start_round()
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.PLAYING, "shift 1 running")
	await _tap(KEY_ESCAPE)
	check(pm.is_open() and _is_under(_focus(), pm.card), "pause open, BACK TO WORK focused (%s)" % _focus_name())
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(3)
	await wait_sec(FOCUS_SETTLE_SEC)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and re.is_open() and pm.is_open(),
			"shift paid while on break: round-end overlay up, pause menu still on top")
	check(_is_under(_focus(), pm.card), "the round-end overlay underneath did not steal the keyboard focus (%s)" % _focus_name())
	for key: Key in [KEY_DOWN, KEY_DOWN, KEY_DOWN, KEY_TAB, KEY_TAB, KEY_TAB, KEY_UP, KEY_UP, KEY_LEFT, KEY_RIGHT]:
		await _tap(key)
		if not _is_under(_focus(), pm.card):
			break
	check(_is_under(_focus(), pm.card), "Tab / arrows stay inside the pause card (%s)" % _focus_name())
	if _is_under(_focus(), pm.card):
		pm.resume_button.grab_focus() # (a stolen focus stays where it is: Enter then shows the harm)
	await wait_frames(1)
	await _tap(KEY_ENTER)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.round_number == 1,
			"Enter on the visible BACK TO WORK did not start the next shift underneath (phase %s, shift %d)"
			% [GameState.get_phase_name(), GameState.round_number])
	check(not pm.is_open() and re.is_open() and Game.is_ui_locked_by(RoundEndOverlay.LOCK_SOURCE),
			"Enter closed the pause menu; the round-end overlay stays")
	await wait_until(func() -> bool: return _focus() == re.primary_button, FOCUS_SETTLE_SEC + 1.0,
			"after the break the round-end overlay gets the keyboard (NEXT SHIFT focused)")


# --- B: Space / Enter right as the shift ends -----------------------------------------------------------------------

func _section_b_jump_at_shift_end() -> void:
	step("B: jumping (Space) / Enter as the shift ends")
	var re := hud.round_end
	# Success screen: a jump must not press NEXT SHIFT.
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 2, "shift 2 running")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(2) # overlay up, its deferred work done
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and re.is_open(), "shift 2 paid: overlay up")
	await _tap(KEY_SPACE)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.round_number == 2,
			"a jump (Space) as the shift ended did not press NEXT SHIFT (phase %s, shift %d)"
			% [GameState.get_phase_name(), GameState.round_number])
	GameState.request_next_round()
	await wait_frames(2)
	# Missed payment: a jump / Enter must not press START OVER (full reset for everyone).
	check(GameState.phase == GameState.Phase.PLAYING and GameState.round_number == 3, "shift 3 running")
	var money_before := GameState.money
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "shift 3 missed")
	await wait_frames(2)
	await _tap(KEY_SPACE)
	await _tap(KEY_ENTER)
	check(GameState.phase == GameState.Phase.ROUND_FAILED and GameState.round_number == 3 and GameState.money == money_before,
			"Space / Enter as the shift was missed did not press START OVER (phase %s, shift %d)"
			% [GameState.get_phase_name(), GameState.round_number])
	# The keyboard still works once the screen has been up for a moment.
	await wait_until(func() -> bool: return _focus() == re.primary_button, FOCUS_SETTLE_SEC + 1.0,
			"START OVER gets the keyboard focus after a moment")
	await _tap(KEY_ENTER)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, "Enter on START OVER then resets")


# --- C: client round-end keyboard -----------------------------------------------------------------------------------

func _section_c_client_round_end() -> void:
	step("C: round-end overlay as a client (LEAVE by keyboard, but never by accident)")
	var re := hud.round_end
	_set_host(false)
	GameState.server_start_round() # this process is still the ENet server; the UI thinks it is a client
	GameState.set(&"_authoritative", false)
	await wait_frames(2)
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(3)
	check(re.is_open() and not re.primary_button.visible and re.menu_button.visible and re.menu_button.text == "LEAVE",
			"client view: waiting + LEAVE")
	await wait_sec(FOCUS_SETTLE_SEC)
	check(_focus() == null, "client: no default focus (%s)" % _focus_name())
	await _tap(KEY_SPACE)
	await wait_frames(3)
	check(Game.world != null and re.is_open(), "client: a jump (Space) does not LEAVE the session")
	await _tap(KEY_TAB)
	check(_focus() == re.menu_button, "client: Tab reaches LEAVE (%s)" % _focus_name())
	get_viewport().gui_release_focus()
	await wait_frames(1)
	await _tap(KEY_DOWN)
	check(_focus() == re.menu_button, "client: an arrow key reaches LEAVE too (%s)" % _focus_name())
	get_viewport().gui_release_focus()
	_set_host(true)
	re.refresh()
	await wait_frames(1)
