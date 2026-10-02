extends "res://tools/tests/qa_base.gd"
## M17 finale suite (finale agent): a run has an end, the final notice (CONTRACTS "M17", "Finale"; FRIENDSLOP 11.1).
## A single headless host with fake workers (host-side bodies without an owning peer):
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/finale_body.gd --replay --run=B5VP --career-file=user://finale_test.cfg --port=7993 --round-sec=900
## The run REFUSES to start without --career-file (it must never touch a real record) and removes its files at the end.
## Pins:
##   the table    final_shift_by_team: one worker 4, two 5, three 6, four 6, more 6; an empty table means no end
##   the team     the largest team seen in a run sets the last shift; it never goes down within the run; a new run
##                starts it again; once the final notice has started a worker who joins does not move it
##   the wire     the "final" entry of the state: in every snapshot, type-checked and clamped on receive, kept when
##                missing; a late joiner's full state carries cleared without run_cleared
##   run 1        shifts 1-3 plain (THIS SHIFT, one condition, NEXT SHIFT); shift 4 is the final notice: FINAL NOTICE,
##                two conditions where a plain shift 4 has one, the toast; half time under 40%: the payment due rises
##                10% through the audit's path, the toast, the Boss; the look happens once; paid: ROUND_SUCCESS with
##                cleared, run_cleared once, PAID IN FULL / "The debt is cleared. He will find another.", NEW RUN and no
##                NEXT SHIFT, paid_in_full (not the bell), the debt board, the Boss; nothing follows but a reset; the
##                record: cleared 1 in memory and on file, "Debts cleared: 1", the eyeshade issued once with its toast;
##                NEW RUN = a full reset with a new code (none typed)
##   run 2        a typed code (B5VP) deals the same run; a second worker at the end of shift 3 moves the end to 5;
##                shift 4 is plain; shift 5 is final; half time at or over 40%: one line and nothing else; a missed
##                final notice is a missed payment (START OVER, nothing cleared, nothing counted)
##   run 3        the lobby on: the alley waits for the final notice with the board's line on top of NEXT (and the
##                column fits), the title, two conditions, the SAME card as run 1 (the code's determinism); paid;
##                NEW RUN leads back to the alley
##   the record   the pause menu's Record card with seven lines and "Issued: N of 8" fits the screen
##   replay off   no last shift, nothing final, a run goes past shift 4 as before
## Every engine/script error fails the run unless announced (qa_base.gd).

const CAREER_SCRIPT := "res://scripts/core/career.gd"
const TEXT_FINAL_TOAST := "Final notice. Pay it and the debt is cleared."
const TEXT_SHORT := "Half the clock. Not half the money."
const TEXT_ON_SCHEDULE := "On schedule. Keep it there."
const TEXT_CLEARED_BOSS := "That's all of it. I'll think of something."

var world: World
var hud: HUD
var board: AlleyBoard
var me: Player
var _path: String = ""
var _looks: Array = []          # [short, raised] per final_look
var _cleared_signals: int = 0
var _final_signals: int = 0
var _issued: Array = []         # hat ids per Career.hat_issued
var _card4: Array = []          # run 1's shift 4: [conditions, market]


func _run() -> void:
	_label = "finale"
	await get_tree().process_frame
	# Headless windows report 1280x1280; force the reference logical size (the smallest stretch "expand" allows).
	get_tree().root.size = Vector2i(1280, 720)
	var b: BalanceConfig = Config.balance
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent,
			"this run has its own career file (%s)" % _path):
		finish(); return
	check(Config.replay_enabled and Config.run_code == "B5VP" and not Config.lobby_enabled, "this suite runs with --replay --run=B5VP, the lobby off")
	_remove(_path)
	Career.clear_record()
	GameState.final_look.connect(func(short: bool, raised: int) -> void: _looks.append([short, raised]))
	GameState.run_cleared.connect(func() -> void: _cleared_signals += 1)
	GameState.final_changed.connect(func() -> void: _final_signals += 1)
	Career.hat_issued.connect(func(id: StringName) -> void: _issued.append(id))

	_test_table(b)
	_test_copy()

	step("hosting")
	# Nothing turns hostile by itself; a covered payment ends the shift (this run pays with one deposit).
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = true
	Game.start_host("Tester", port_arg(7993))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		_cleanup(); finish(); return
	world = Game.world
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	board = world.get_node_or_null(^"Lobby/ReportBoard") as AlleyBoard
	if not check(hud != null and board != null, "the HUD and the alley's board exist"):
		_cleanup(); finish(); return

	await _test_team()
	await _test_wire()
	await _test_run_one(b)
	await _test_record_card()
	await _test_run_two(b)
	await _test_run_three(b)
	await _test_replay_off(b)
	_cleanup()
	finish()


# --- the table, the copy ------------------------------------------------------------------------------------------------

func _test_table(b: BalanceConfig) -> void:
	step("the table")
	check(str(b.final_shift_by_team) == "[4, 5, 6, 6]", "final_shift_by_team is [4, 5, 6, 6] (%s)" % [b.final_shift_by_team])
	check(GameState._final_table(1) == 4 and GameState._final_table(2) == 5 and GameState._final_table(3) == 6 and GameState._final_table(4) == 6,
			"one worker 4, two 5, three 6, four 6")
	check(GameState._final_table(5) == 6 and GameState._final_table(9) == 6 and GameState._final_table(0) == 4, "a team past the table takes its last entry; none counts as one")
	var saved: Array[int] = b.final_shift_by_team.duplicate()
	b.final_shift_by_team.clear()
	check(GameState._final_table(1) == 0 and GameState._final_table(4) == 0, "an empty table: no end")
	b.final_shift_by_team = saved
	check(GameState.get_final_shift() == 0 and not GameState.is_final_shift() and not GameState.is_run_cleared(), "in the menu: no last shift, nothing final, nothing cleared")


func _test_copy() -> void:
	step("the copy")
	var texts := PackedStringArray([RoundEndOverlay.TEXT_CLEARED_TITLE, RoundEndOverlay.TEXT_CLEARED_SUB, RoundEndOverlay.TEXT_NEW_RUN,
			AlleyBoard.TEXT_FINAL, HUD.TEXT_FINAL_TITLE, Career.TEXT_CLEARED, String(Hats.get_def(&"eyeshade").get("line", ""))])
	for key: String in Story.FINALE_LINES:
		texts.append(String(Story.FINALE_LINES[key]))
		check(Story.line(key) == String(Story.FINALE_LINES[key]), "Story has the line '%s'" % key)
	var flat := true
	for t in texts:
		if t == "" or t.contains("!") or t.to_lower().contains("congrat") or t.to_lower().contains("great") or t.to_lower().contains("win"):
			flat = false
	check(flat, "flat copy: no exclamation mark, no cheer (%d lines)" % texts.size())
	check(RoundEndOverlay.TEXT_CLEARED_TITLE == "PAID IN FULL" and RoundEndOverlay.TEXT_CLEARED_SUB == "The debt is cleared. He will find another."
			and AlleyBoard.TEXT_FINAL == "Final notice. Pay it and the debt is cleared." and HUD.TEXT_FINAL_TITLE == "FINAL NOTICE", "the contract's words")
	var row := Hats.get_def(&"eyeshade")
	check(Hats.count() == 8 and Hats.has(&"eyeshade") and String(row.get("key", "")) == "cleared" and int(row.get("threshold", 0)) == 1
			and Career.KEYS.has("cleared") and String(row.get("name", "")) == "green eyeshade", "the eighth hat: the green eyeshade, issued at one debt cleared")
	var clip := Sfx.get_stream(&"paid_in_full")
	var m: Dictionary = Sfx.measure(clip)
	check(Sfx.has_sound(&"paid_in_full") and clip != null and float(m["seconds"]) > 1.0 and int(m["clipped"]) == 0,
			"paid_in_full has a recipe of its own (%.2f s, the placeholder blip was 0.10 s; no clipping)" % float(m.get("seconds", 0.0)))


# --- the team -----------------------------------------------------------------------------------------------------------

func _test_team() -> void:
	step("the largest team")
	check(GameState.phase == GameState.Phase.WAITING and GameState.get_team_size() == 1, "WAITING, alone")
	check(GameState.get_final_shift() == 4 and GameState.get_largest_team() == 1 and not GameState.is_final_shift() and not GameState.is_run_cleared(),
			"one worker: the last shift is 4 (%d)" % GameState.get_final_shift())
	check(hud.get_payment_title() == "THIS SHIFT" and not board.get_next_lines()[0].begins_with("Final"), "THIS SHIFT; the board's NEXT starts with the shift ('%s')" % board.get_next_lines()[0])
	var s: Dictionary = GameState.call(&"_snapshot")
	check(s.get("final") == {"shift": 4, "cleared": false}, "the state carries it: %s" % [s.get("final")])
	var f0 := _final_signals
	_add_worker(2, "Bob")
	await wait_frames(2)
	check(GameState.get_final_shift() == 5 and _final_signals > f0, "two: 5, final_changed")
	_add_worker(3, "Carl")
	await wait_frames(2)
	check(GameState.get_final_shift() == 6, "three: 6")
	_add_worker(4, "Dee")
	await wait_frames(2)
	check(GameState.get_final_shift() == 6 and GameState.get_largest_team() == 4, "four: 6")
	_remove_worker(4)
	_remove_worker(3)
	_remove_worker(2)
	await wait_frames(2)
	check(GameState.get_team_size() == 1 and GameState.get_final_shift() == 6 and GameState.get_largest_team() == 4, "they leave: still 6 (it never goes down within a run)")
	_add_worker(2, "Bob")
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_final_shift() == 5 and GameState.get_largest_team() == 2, "a new run starts from the team that is there: two, 5")
	_remove_worker(2)
	await wait_frames(2)
	check(GameState.get_final_shift() == 5, "Bob leaves: still 5")
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_final_shift() == 4 and GameState.get_largest_team() == 1, "a new run alone: 4")


# --- the wire -----------------------------------------------------------------------------------------------------------

func _test_wire() -> void:
	step("the state entry on receive")
	var s: Dictionary = GameState.call(&"_snapshot")
	s["final"] = {"shift": 500, "cleared": "yes"}
	_apply(s)
	check(GameState.get_final_shift() == GameState.MAX_FINAL_SHIFT and not GameState.is_run_cleared(), "a wild shift is clamped (%d), a cleared flag that is not a bool is false" % GameState.get_final_shift())
	s["final"] = {"shift": 4.0, "cleared": 1}
	_apply(s)
	check(GameState.get_final_shift() == 0 and not GameState.is_run_cleared(), "a shift that is not an int reads as none")
	s["final"] = {"shift": 3, "cleared": false}
	_apply(s)
	s["final"] = "junk"
	_apply(s)
	check(GameState.get_final_shift() == 3, "an entry that is not a dictionary changes nothing")
	s.erase("final")
	_apply(s)
	check(GameState.get_final_shift() == 3, "a state without the entry (an older host) changes nothing")
	var cleared0 := _cleared_signals
	s["final"] = {"shift": 4, "cleared": true}
	GameState._rpc_full_state(s)
	GameState.set(&"_authoritative", true)   # a direct call looks like a remote sender; this peer is still the host
	check(GameState.is_run_cleared() and _cleared_signals == cleared0, "a full state (a late joiner's) carries cleared without run_cleared")
	s["final"] = {"shift": 4, "cleared": false}
	_apply(s)
	GameState.server_send_full_state(1)
	await wait_frames(1)
	check(GameState.get_final_shift() == 4 and not GameState.is_run_cleared() and Career.get_record("cleared") == 0, "the host's own state puts it back; nothing was counted")


func _apply(s: Dictionary) -> void:
	GameState._rpc_state(s)
	GameState.set(&"_authoritative", true)


# --- run 1: the final notice, short at half time, paid ------------------------------------------------------------------

func _test_run_one(b: BalanceConfig) -> void:
	step("run 1: three plain shifts")
	check(GameState.get_run_code() == "B5VP" and GameState.round_number == 1, "run B5VP, shift 1")
	GameState.request_start_round()
	await wait_frames(2)
	for n in range(1, 4):
		var ok := GameState.is_playing() and GameState.round_number == n and not GameState.is_final_shift() and hud.get_payment_title() == "THIS SHIFT"
		check(ok and GameState.get_conditions().size() == (0 if n == 1 else 1) and not toast_seen(TEXT_FINAL_TOAST),
				"shift %d: THIS SHIFT, %d condition(s) %s" % [n, GameState.get_conditions().size(), GameState.get_conditions()])
		await _pay()
		check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not GameState.is_run_cleared() and hud.round_end.title_label.text == RoundEndOverlay.TEXT_PAID_TITLE
				and hud.round_end.primary_button.text == RoundEndOverlay.TEXT_NEXT_SHIFT, "shift %d paid: PAYMENT ACCEPTED, NEXT SHIFT" % n)
		GameState.request_next_round()
		await wait_frames(2)

	step("run 1: shift 4 is the final notice")
	check(GameState.is_playing() and GameState.round_number == 4 and GameState.is_final_shift() and GameState.get_final_shift() == 4, "shift 4 runs, and it is final")
	check(hud.get_payment_title() == "FINAL NOTICE", "the payment panel: '%s'" % hud.get_payment_title())
	var plain := ShiftConditions.count_for_round(4, b.conditions_from_round, b.conditions_per_shift)
	check(GameState.get_conditions().size() == 2 and plain == 1, "two conditions where a plain shift 4 has %d: %s" % [plain, GameState.get_conditions()])
	_card4 = [GameState.get_conditions(), GameState.get_market()]
	check(toast_seen(TEXT_FINAL_TOAST), "the toast: '%s'" % TEXT_FINAL_TOAST)
	check(board.get_next_lines()[0] == AlleyBoard.TEXT_FINAL, "the board's NEXT column starts with the final notice")
	_add_worker(2, "Bob")
	await wait_frames(2)
	check(GameState.get_final_shift() == 4 and GameState.is_final_shift(), "a worker who joins in the middle of the final notice does not move it")
	_remove_worker(2)
	await wait_frames(2)

	step("run 1: half time, under the share")
	var q0 := GameState.quota
	GameState.server_add_sale(int(q0 * 0.3), 1)
	var shift_len := float(GameState.get(&"_final_shift_len"))
	GameState.time_left = shift_len * 0.6
	await wait_frames(3)
	check(_looks.is_empty() and GameState.quota == q0, "before half time: no look")
	GameState.time_left = shift_len * 0.5 - 0.5
	await wait_frames(3)
	var raised := maxi(int(round(float(q0) * b.final_interim_raise)), 1)
	check(_looks.size() == 1 and _looks[0] == [true, raised] and GameState.quota == q0 + raised,
			"30%% deposited: the payment due rises by a tenth, $%d -> $%d (%s)" % [q0, GameState.quota, _looks])
	check(toast_seen("Payment due up %s." % Story.format_money(raised)) and Story.bark_log.has(TEXT_SHORT), "the toast and the Boss: '%s'" % TEXT_SHORT)
	GameState.time_left = shift_len * 0.7
	await wait_frames(2)
	GameState.time_left = shift_len * 0.3
	await wait_frames(3)
	check(_looks.size() == 1 and GameState.quota == q0 + raised, "the look happens once")

	step("run 1: paid in full")
	var cleared0 := _cleared_signals
	var bell0 := int(Sfx.get(&"_last_play").get(&"round_win", -1))
	await _pay()
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.is_run_cleared() and _cleared_signals == cleared0 + 1, "ROUND_SUCCESS, the run is cleared, run_cleared once")
	var s: Dictionary = GameState.call(&"_snapshot")
	check(s.get("final") == {"shift": 4, "cleared": true}, "the state says so: %s" % [s.get("final")])
	var re := hud.round_end
	check(re.visible and re.is_showing_cleared() and re.title_label.text == "PAID IN FULL" and re.subtitle_label.text == "The debt is cleared. He will find another.",
			"the overlay: '%s' / '%s'" % [re.title_label.text, re.subtitle_label.text])
	check(re.primary_button.visible and re.primary_button.text == "NEW RUN" and not re.waiting_label.visible, "the host's button is NEW RUN; NEXT SHIFT is not offered")
	check(re.next_key.text == RoundEndOverlay.TEXT_PAID_KEY and re.next_value.text == "4", "no next payment: shifts paid 4")
	var last_play: Dictionary = Sfx.get(&"_last_play")
	check(last_play.has(&"paid_in_full") and int(last_play.get(&"round_win", -1)) == bell0, "paid_in_full, not the end-of-shift bell")
	check(Story.board_text == "PAID IN FULL" and Story.bark_log.rfind(TEXT_CLEARED_BOSS) > Story.bark_log.rfind(Story.line("paid")),
			"the debt board reads PAID IN FULL; the Boss says '%s', not the next number" % TEXT_CLEARED_BOSS)
	_check_record(1, "the clear is on file")
	var lines := Career.get_summary_lines()
	check(lines.size() == 7 and lines[6] == "Debts cleared: 1", "the summary's last line: '%s'" % (lines[6] if lines.size() > 6 else ""))
	check(_issued.count(&"eyeshade") == 1 and Career.get_issued_hats().has(&"eyeshade") and toast_seen("Issued: green eyeshade. It is in your locker."),
			"the eyeshade is issued, once, with its toast (issued this run: %s)" % [_issued])

	step("run 1: nothing follows but a reset")
	GameState.request_next_round()
	await wait_frames(2)
	GameState.server_start_round()
	GameState.server_return_to_lobby(false)
	await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.round_number == 4 and GameState.is_run_cleared(), "NEXT SHIFT, a start and the way back to the alley are refused")
	s = GameState.call(&"_snapshot")
	GameState._rpc_full_state(s)
	GameState.set(&"_authoritative", true)
	check(_cleared_signals == cleared0 + 1 and Career.get_record("cleared") == 1 and re.is_showing_cleared(), "a late joiner's full state: PAID IN FULL, no second run_cleared, nothing counted twice")

	step("run 1: NEW RUN")
	Config.run_code = ""
	var code := GameState.get_run_code()
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and not GameState.is_run_cleared() and GameState.get_final_shift() == 4,
			"a full reset: WAITING, shift 1, nothing cleared, the last shift 4")
	check(GameState.get_run_code() != "" and GameState.get_run_code() != code, "a new run code (none typed): %s -> %s" % [code, GameState.get_run_code()])
	check(not re.visible and hud.get_payment_title() == "THIS SHIFT" and Story.board_text.begins_with("OWED"), "the overlay is gone, THIS SHIFT, the board owes again")


# --- the Record card ----------------------------------------------------------------------------------------------------

func _test_record_card() -> void:
	step("the pause menu's Record card")
	var pm: PauseMenu = hud.pause_menu
	pm.open()
	await wait_sec(0.5)
	var texts := pm.get_record_texts()
	check(texts.size() == 8 and texts[7] == "Debts cleared: 1", "the title and seven lines, the last 'Debts cleared: 1' (%s)" % [texts])
	check(pm.get_record_issued_text() == "Issued: %d of 8" % Career.get_issued_hats().size(), "'%s'" % pm.get_record_issued_text())
	var screen := get_viewport().get_visible_rect()
	var rect := pm.record_card.get_global_rect()
	check(screen.encloses(rect) and not pm.card.get_global_rect().intersects(rect), "the card fits the screen beside ON BREAK (%s)" % rect)
	pm.close()
	await wait_frames(2)


# --- run 2: a typed code, a bigger team, on schedule, missed --------------------------------------------------------------

func _test_run_two(_b: BalanceConfig) -> void:
	step("run 2: the typed code again")
	Config.run_code = "B5VP"
	GameState.server_reset_game()
	await wait_frames(2)
	check(GameState.get_run_code() == "B5VP" and GameState.get_final_shift() == 4, "run B5VP, the last shift 4")
	GameState.request_start_round()
	await wait_frames(2)
	for n in range(1, 4):
		await _pay()
		if n < 3:
			GameState.request_next_round()
			await wait_frames(2)
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.round_number == 3, "shift 3 paid")
	_add_worker(2, "Bob")
	await wait_frames(2)
	check(GameState.get_final_shift() == 5 and GameState.get_largest_team() == 2, "Bob clocks in before the last shift started: it moves to 5")
	_remove_worker(2)
	await wait_frames(2)
	check(GameState.get_final_shift() == 5, "and stays 5 when he goes")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.round_number == 4 and not GameState.is_final_shift() and hud.get_payment_title() == "THIS SHIFT" and GameState.get_conditions().size() == 1,
			"shift 4 is a plain shift now (one condition)")
	await _pay()
	check(not GameState.is_run_cleared(), "paying it clears nothing")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.round_number == 5 and GameState.is_final_shift() and hud.get_payment_title() == "FINAL NOTICE" and GameState.get_conditions().size() == 2,
			"shift 5 is the final notice (two conditions)")

	step("run 2: half time, on schedule")
	toasts.clear()
	var q0 := GameState.quota
	GameState.server_add_sale(int(q0 * 0.5), 1)
	var looks0 := _looks.size()
	var shift_len := float(GameState.get(&"_final_shift_len"))
	GameState.time_left = shift_len * 0.5 - 0.5
	await wait_frames(3)
	check(_looks.size() == looks0 + 1 and _looks.back() == [false, 0] and GameState.quota == q0, "50%% deposited: the look, nothing raised")
	check(Story.bark_log.has(TEXT_ON_SCHEDULE) and not toast_seen("Payment due up"), "one line and nothing else: '%s'" % TEXT_ON_SCHEDULE)

	step("run 2: missed")
	var cleared0 := _cleared_signals
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "the clock runs out")
	await wait_frames(2)
	var re := hud.round_end
	check(not GameState.is_run_cleared() and _cleared_signals == cleared0 and re.title_label.text == RoundEndOverlay.TEXT_MISSED_TITLE
			and re.primary_button.text == RoundEndOverlay.TEXT_START_OVER, "a missed final notice is a missed payment: START OVER")
	_check_record(1, "nothing more on file")
	check(_issued.count(&"eyeshade") == 1, "no second eyeshade")
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and GameState.get_final_shift() == 4, "START OVER: shift 1, alone again, the last shift 4")


# --- run 3: the lobby, the board, the same card ---------------------------------------------------------------------------

func _test_run_three(b: BalanceConfig) -> void:
	step("run 3: through the alley")
	Config.lobby_enabled = true
	Config.run_code = "B5VP"
	GameState.server_reset_game()
	await wait_frames(2)
	for n in range(1, 4):
		await _ride_to_floor(b, n)
		await _pay()
		GameState.request_next_round()
		if not await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and not GameState.is_transitioning(), b.transition_fade_sec * 2.0 + 3.0,
				"shift %d paid, back in the alley" % n):
			Config.lobby_enabled = false
			return
	check(GameState.round_number == 4 and GameState.is_final_shift() and hud.get_payment_title() == "FINAL NOTICE", "the alley waits for the final notice: FINAL NOTICE")
	board.refresh()
	var next := board.get_next_lines()
	check(next[0] == AlleyBoard.TEXT_FINAL and board.get_shown_text(1).begins_with(AlleyBoard.TEXT_FINAL), "the board's NEXT column starts with '%s'" % next[0])
	check(_column_fits(board.get_shown_text(1), board.get_font_size()), "and the column fits the board (%d px type)" % board.get_font_size())
	check(_same(GameState.get_conditions(), _card4[0]) and GameState.get_market() == _card4[1],
			"the same code, the same card: %s as in run 1 (rolled in the alley this time)" % [GameState.get_conditions()])
	await _ride_to_floor(b, 4)
	await _pay()
	check(GameState.is_run_cleared() and hud.round_end.is_showing_cleared(), "paid: PAID IN FULL")
	_check_record(2, "two debts cleared")
	check(_issued.count(&"eyeshade") == 1, "the eyeshade is not issued twice")

	step("run 3: NEW RUN leads back to the alley")
	hud.round_end.primary_button.pressed.emit()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and not GameState.is_transitioning(), b.transition_fade_sec * 2.0 + 3.0, "the reset happens in the dark")
	await wait_frames(3)
	check(GameState.round_number == 1 and not GameState.is_run_cleared() and GameState.get_run_code() == "B5VP", "shift 1 of a new run (the typed code again)")
	check(me.global_position.z > world.lobby.global_position.z - 20.0, "the host wakes up in the alley (z %.1f)" % me.global_position.z)
	Config.lobby_enabled = false


func _ride_to_floor(b: BalanceConfig, n: int) -> void:
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == n and not GameState.is_transitioning(), b.transition_fade_sec * 2.0 + 3.0,
			"the van: shift %d runs" % n)


# --- replay off -----------------------------------------------------------------------------------------------------------

func _test_replay_off(_b: BalanceConfig) -> void:
	step("replay off: no end")
	Config.replay_enabled = false
	GameState.server_reset_game()
	await wait_frames(2)
	var s: Dictionary = GameState.call(&"_snapshot")
	check(GameState.get_final_shift() == 0 and s.get("final") == {"shift": 0, "cleared": false}, "no last shift: %s" % [s.get("final")])
	var looks0 := _looks.size()
	var cleared0 := _cleared_signals
	var plain := true
	GameState.request_start_round()
	await wait_frames(2)
	for n in range(1, 7):
		if not (GameState.is_playing() and GameState.round_number == n and not GameState.is_final_shift() and hud.get_payment_title() == "THIS SHIFT"
				and GameState.get_conditions().is_empty()):
			plain = false
		GameState.time_left = GameState.time_left * 0.4
		await wait_frames(2)
		await _pay()
		if GameState.is_run_cleared() or hud.round_end.primary_button.text != RoundEndOverlay.TEXT_NEXT_SHIFT:
			plain = false
		GameState.request_next_round()
		await wait_frames(2)
	check(plain and GameState.round_number == 7 and _looks.size() == looks0 and _cleared_signals == cleared0, "six plain shifts in a row and the seventh starts: nothing final, no look, nothing cleared")
	Config.replay_enabled = true


# --- helpers --------------------------------------------------------------------------------------------------------------

## The host deposits what is still owed (a covered payment ends the shift).
func _pay() -> void:
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
	await wait_frames(2)


func _add_worker(id: int, worker_name: String) -> void:
	Net.players[id] = {"name": worker_name, "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	world.server_spawn_player(id)
	Net.players_changed.emit()


func _remove_worker(id: int) -> void:
	world.server_despawn_player(id)
	Net.players.erase(id)
	Net.players_changed.emit()


## The record in memory and on its file: `cleared` debts.
func _check_record(cleared: int, tag: String) -> void:
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	var file_ok: bool = reader.load_file(_path)
	check(Career.get_record("cleared") == cleared and file_ok and reader.get_record("cleared") == cleared and reader.get_summary_lines() == Career.get_summary_lines(),
			"%s: cleared %d in memory and on the file (a second reader: %d)" % [tag, cleared, reader.get_record("cleared")])
	reader.free()


## The NEXT column at `size` fits the board's height (what AlleyBoard._fit_font_size aims for).
func _column_fits(text: String, size: int) -> bool:
	var font: Font = ThemeDB.fallback_font
	if font == null:
		return true
	var width_px := board._column_width() / AlleyBoard.PIXEL_SIZE
	var room := AlleyBoard.BOARD_SIZE.y - 2.0 * AlleyBoard.MARGIN - AlleyBoard.HEAD_HEIGHT
	return font.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, width_px, size).y * AlleyBoard.PIXEL_SIZE <= room + 0.001


static func _same(a: Array, c: Array) -> bool:
	if a.size() != c.size():
		return false
	for i in a.size():
		if StringName(str(a[i])) != StringName(str(c[i])):
			return false
	return true


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
