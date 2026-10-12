extends "res://tools/tests/qa_base.gd"
## M25 runcard suite (runcard agent): THE RUN block of the round-end card (CONTRACTS "M25", "Run card"). A single
## headless host with fake workers (host-side bodies without an owning peer), the final notice moved to shift 3:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/runcard_body.gd --replay --run=B5VP --career-file=user://runcard_test_9110.cfg --port=9110 --round-sec=900
## Refuses to run without its own --career-file (a real record is never touched) and removes it at the end.
## Pins:
##   the copy     Story's lines (installed, flat: no "!", no cheer), the verdict order, at most three verdicts
##   the wire     the "run_stats" entry on receive: type-checked and clamped (shifts, peers, keys, values, names, the
##                row and key caps); an entry that is not a dictionary or a state without it keeps what is there
##   run 1        Tester + Dale + Wren; Bartholomew joins in shift 2; Wren leaves during the final notice. Shifts 1 and 2
##                are ordinary: no block. After every shift the run totals are the sum of the shift ledgers; a stat
##                booked on the end screen counts once; the worker who left keeps her row and her name (Net forgets
##                her, run_names does not); PAID IN FULL: the block with the exact totals line and the first three
##                verdicts in order; the card fits 1280x720 with four report rows, three cost lines, the job line and the
##                block; NEW RUN clears the totals
##   run 2        shift 1 paid (no block); shift 2 missed: the block on the START OVER card with the zero rules (no
##                bruised / helped-up segments, the verdicts skip what nobody did); the card fits; START OVER clears
##   rules        synthetic run totals: empty, the fixed order, three at most, ties to the lowest id, zero stats skipped,
##                the totals segments only above zero, a name the run kept
##   the menu     back to the menu clears the totals
## Every engine/script error fails the run unless announced (qa_base.gd).

const DALE := 2
const WREN := 3
const BART := 4
const NAMES := {1: "Tester", DALE: "Dale", WREN: "Wren Abernathy", BART: "Bartholomew Jone"}
const LINE_TITLE := "THE RUN"

var world: World
var hud: HUD
var re: RoundEndOverlay
var _path: String = ""
var _expected: Dictionary = {}     # peer -> {stat -> int}: the shift ledgers added up by the test
var _deposits: int = 0             # every sale with a seller, as the test saw them
var _changed: int = 0              # run_stats_changed


func _run() -> void:
	_label = "runcard"
	await get_tree().process_frame
	# Headless windows report 1280x1280; force the reference logical size (the smallest stretch "expand" allows).
	get_tree().root.size = Vector2i(1280, 720)
	var b: BalanceConfig = Config.balance
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path, "this run has its own career file (%s)" % _path):
		finish(); return
	check(Config.replay_enabled and Config.run_code == "B5VP" and not Config.lobby_enabled, "this suite runs with --replay --run=B5VP, the lobby off")
	_remove(_path)
	Career.clear_record()
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = true
	b.final_shift_by_team = [3, 3, 3, 3]   # a short run: the final notice is shift 3 for any team
	GameState.run_stats_changed.connect(func() -> void: _changed += 1)
	GameState.sale_made.connect(func(amount: int, seller: int) -> void:
		if seller > 0:
			_deposits += amount)

	_test_copy()

	step("hosting")
	Game.start_host(NAMES[1], port_arg(9110))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		_cleanup(); finish(); return
	world = Game.world
	hud = world.get_node_or_null(^"HUD") as HUD
	re = hud.round_end if hud != null else null
	if not check(re != null and re.run_card != null and re.run_card.get_parent() == re.get_node(^"%ReportCard").get_parent()
			and re.run_card.get_index() == re.get_node(^"%ReportCard").get_index() + 1, "the block sits right under the shift report on the card"):
		_cleanup(); finish(); return
	check(GameState.phase == GameState.Phase.WAITING and GameState.run_stats.is_empty() and GameState.run_shifts == 0
			and not re.is_showing_run(), "a new session: no totals, no block")

	await _test_wire()
	await _test_run_one()
	await _test_run_two()
	_test_rules()
	await _test_menu()
	_cleanup()
	finish()


# --- the copy -------------------------------------------------------------------------------------------------------

func _test_copy() -> void:
	step("the copy")
	var texts := PackedStringArray()
	for key: String in Story.RUNCARD_LINES:
		texts.append(String(Story.RUNCARD_LINES[key]))
		check(Story.line(key) == String(Story.RUNCARD_LINES[key]), "Story has the line '%s'" % key)
	var flat := true
	for t in texts:
		var low := t.to_lower()
		if t == "" or t.contains("!") or low.contains("congrat") or low.contains("great") or low.contains("well done") \
				or low.contains("thank you") or low.contains("win") or low.contains("hero") or low.contains("best"):
			flat = false
	check(flat, "flat copy: no exclamation mark, no cheer (%d lines)" % texts.size())
	check(Story.line("run_title") == LINE_TITLE and Story.RUN_VERDICT_MAX == 3, "the title is THE RUN; three verdicts at most")
	var order: Array = []
	for e: Array in Story.get_run_verdict_order():
		order.append(e[0])
	check(order == [Const.STAT_DEPOSITED, Const.STAT_HELPED, Const.STAT_BRUISED, Const.STAT_BITTEN, Const.STAT_WRITE_UPS],
			"the fixed order: deposits, helped up, bruised, bitten, written up (%s)" % [order])


# --- the wire -------------------------------------------------------------------------------------------------------

func _test_wire() -> void:
	step("the state entry on receive")
	var good: Dictionary = GameState.call(&"_snapshot")
	check(good.get("run_stats") is Dictionary and (good["run_stats"] as Dictionary).has("shifts"), "every snapshot carries run_stats")
	var s: Dictionary = good.duplicate(true)
	var long_key := "k".repeat(GameState.RUN_MAX_KEY_LENGTH + 1)
	s["run_stats"] = {
		"shifts": 5000,
		"stats": {
			1: {"deposited": 4000000000000, "planted": -4, long_key: 3, "watered": 2.5, 7: 1, "bruised": 2},
			"2": {"deposited": 10}, -3: {"deposited": 10}, 0: {"deposited": 10}, 4: "row", 5: {"helped": "1", "bitten": 1},
		},
		"names": {1: "  Ann​ie Longname-Over-Sixteen ", 2: 7, 0: "Zero", 5: &"Quill"},
	}
	_apply(s)
	check(GameState.run_shifts == GameState.RUN_MAX_SHIFTS, "a wild shift count is clamped (%d)" % GameState.run_shifts)
	check(GameState.get_run_peers() == [1, 5], "only int peers above zero with a dictionary row are kept (%s)" % [GameState.get_run_peers()])
	check(GameState.get_run_stat(1, Const.STAT_DEPOSITED) == GameState.RUN_MAX_STAT and GameState.get_run_stat(1, Const.STAT_PLANTED) == 0
			and GameState.get_run_stat(1, Const.STAT_BRUISED) == 2, "values clamped to 0..RUN_MAX_STAT")
	var row1: Dictionary = GameState.run_stats.get(1, {})
	check(row1.size() == 3 and not row1.has(StringName(long_key)) and not row1.has(Const.STAT_WATERED), "a key too long, a float value and an int key are dropped (%s)" % [row1.keys()])
	check(GameState.get_run_stat(5, Const.STAT_HELPED) == 0 and GameState.get_run_stat(5, Const.STAT_BITTEN) == 1, "a value that is not an int is dropped")
	check(GameState.get_run_name(1) == Net.sanitize_name("  Ann​ie Longname-Over-Sixteen ") and GameState.get_run_name(1).length() <= Net.MAX_NAME_LENGTH
			and GameState.get_run_name(5) == "Quill" and not GameState.run_names.has(2) and not GameState.run_names.has(0),
			"names go through Net.sanitize_name; not a string / peer 0 dropped ('%s')" % GameState.get_run_name(1))
	var many: Dictionary = {}
	for i in range(1, 60):
		var row: Dictionary = {}
		for k in 50:
			row["stat%d" % k] = k
		many[i] = row
	s["run_stats"] = {"shifts": 2.0, "stats": many, "names": {}}
	_apply(s)
	var keys_ok := true
	for id: int in GameState.run_stats:
		keys_ok = keys_ok and (GameState.run_stats[id] as Dictionary).size() <= GameState.RUN_MAX_KEYS
	check(GameState.run_stats.size() == GameState.RUN_MAX_WORKERS and keys_ok and GameState.run_shifts == 0,
			"at most %d rows of %d stats; a shift count that is not an int reads 0" % [GameState.RUN_MAX_WORKERS, GameState.RUN_MAX_KEYS])
	s["run_stats"] = {"shifts": 2, "stats": {2: {"deposited": 40}}, "names": {2: "Kept"}}
	_apply(s)
	s["run_stats"] = "junk"
	_apply(s)
	check(GameState.run_shifts == 2 and GameState.get_run_stat(2, Const.STAT_DEPOSITED) == 40 and GameState.get_run_name(2) == "Kept",
			"an entry that is not a dictionary changes nothing")
	s.erase("run_stats")
	_apply(s)
	check(GameState.run_shifts == 2 and GameState.get_run_stat(2, Const.STAT_DEPOSITED) == 40, "a state without the entry (an older host) changes nothing")
	var changed0 := _changed
	_apply(good)
	check(GameState.run_stats.is_empty() and GameState.run_names.is_empty() and GameState.run_shifts == 0 and _changed == changed0 + 1,
			"the host's own state puts it back (run_stats_changed once)")
	var again := _changed
	_apply(good)
	check(_changed == again, "the same entry again: no signal")
	await wait_frames(1)


func _apply(s: Dictionary) -> void:
	GameState._rpc_state(s)
	GameState.set(&"_authoritative", true)   # a direct call looks like a remote sender; this peer is still the host


# --- run 1 ----------------------------------------------------------------------------------------------------------

func _test_run_one() -> void:
	step("run 1: three workers")
	_add_worker(DALE)
	_add_worker(WREN)
	await wait_frames(2)
	check(GameState.get_final_shift() == 3, "the final notice is shift 3 (%d)" % GameState.get_final_shift())
	GameState.request_start_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 1, "shift 1 running")

	# Shift 1: Dale carries it, helps somebody up; Wren bruises a bundle; the host is written up once.
	GameState.server_add_stat(DALE, Const.STAT_HELPED)
	GameState.server_add_stat(WREN, Const.STAT_BRUISED)
	GameState.server_add_stat(WREN, Const.STAT_PLANTED, 3)
	GameState.server_write_up(1, Const.WRITE_UP_OTHER)
	check(GameState.run_stats.is_empty() and GameState.run_shifts == 0, "during the first shift the run has no totals yet")
	await _pay_split([[DALE, 0.7]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not GameState.is_run_cleared() and re.is_open(), "shift 1 paid: an ordinary end screen")
	check(not re.is_showing_run() and re.run_card.get_block_text() == "" and re.primary_button.text == RoundEndOverlay.TEXT_NEXT_SHIFT,
			"an ordinary shift: no block (NEXT SHIFT)")
	check(GameState.run_shifts == 1 and _ledger_matches(GameState.stats), "shift 1's totals are its ledger (one shift)")
	# A stat booked on the end screen (a bundle that lands bruised after the payment) counts, once.
	var changed0 := _changed
	GameState.server_add_stat(WREN, Const.STAT_BRUISED)
	await wait_frames(2)
	check(GameState.get_stat(WREN, Const.STAT_BRUISED) == 2 and GameState.get_run_stat(WREN, Const.STAT_BRUISED) == 2 and GameState.run_shifts == 1
			and _changed > changed0, "a bruise booked on the end screen is in the totals (2), the shift counted once")
	var snap: Dictionary = GameState.call(&"_snapshot")
	check(not GameState._stats_differ((snap["run_stats"] as Dictionary)["stats"], GameState.run_stats), "the host's next broadcast carries the same totals")
	_fold_expected(GameState.stats)

	step("run 1: shift 2 (Bartholomew joins)")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.stats.is_empty(), "shift 2 running, a fresh ledger")
	check(_totals_match() and GameState.run_shifts == 1, "the totals carried into shift 2 are shift 1's (with the late bruise)")
	_add_worker(BART)
	await wait_frames(2)
	GameState.server_add_stat(BART, Const.STAT_BITTEN, 2)
	GameState.server_add_stat(DALE, Const.STAT_HELPED)
	GameState.server_add_stat(WREN, Const.STAT_WATERED, 4)
	await _pay_split([[WREN, 0.2], [DALE, 0.6]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not re.is_showing_run() and re.run_card.get_block_text() == "", "shift 2 paid: still no block")
	_fold_expected(GameState.stats)
	check(GameState.run_shifts == 2 and _totals_match(), "after shift 2 the totals are shift 1 + shift 2 (%s)" % [GameState.run_stats])

	step("run 1: the final notice; Wren leaves")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 3 and GameState.is_final_shift(), "shift 3 is the final notice")
	GameState.server_add_stat(WREN, Const.STAT_BRUISED, 2)
	GameState.server_add_sale(int(GameState.quota * 0.05), WREN)
	await wait_frames(1)
	_remove_worker(WREN)
	Net.set(&"_departed_names", {})   # Net forgets her (a late joiner's Net never knew her)
	await wait_frames(2)
	check(not Net.players.has(WREN) and Net.get_player_name(WREN) != NAMES[WREN] and GameState.stats.has(WREN), "Wren is gone from Net, her ledger stays")
	# The worst case for the card: three cost lines, a job line, four report rows (Wren as "(left)").
	Events.server_note_cost(Events.COST_RAID, 0, 2, 0, 0, 360, "purple")
	Events.server_note_cost(Events.COST_COLLECTION, 40, 0, 0, 0, 40, "")
	Events.server_note_cost(Events.COST_PHONE, 30, 0, 0, 0, 30, "")
	if GameState.get_contract().is_empty():
		GameState.server_roll_contract()
	await wait_frames(1)
	await _pay_split([[DALE, 0.7]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.is_run_cleared() and re.is_showing_cleared(), "paid: PAID IN FULL")
	_fold_expected(GameState.stats)
	check(GameState.run_shifts == 3 and GameState.run_shifts == GameState.round_number and _totals_match(),
			"the run's totals: three shifts added up (%s)" % [GameState.run_stats])
	check(GameState.get_run_peers() == [1, DALE, WREN, BART] and GameState.get_run_name(WREN) == NAMES[WREN],
			"the worker who left keeps her row and her name ('%s')" % GameState.get_run_name(WREN))
	check(GameState.get_run_total(Const.STAT_DEPOSITED) == _deposits, "deposited in the totals = every deposit made this run ($%d)" % _deposits)
	check(re.is_showing_run() and re.primary_button.text == RoundEndOverlay.TEXT_NEW_RUN, "PAID IN FULL shows THE RUN (NEW RUN)")
	var totals := "Shifts worked: 3 · Deposited: %s · Bruised: 4 · Helped up: 2" % Story.format_money(_deposits)
	check(re.run_card.get_totals_text() == totals, "the totals line '%s'" % re.run_card.get_totals_text())
	var verdicts := PackedStringArray(["Dale carried the deposits. Nobody said so.", "Dale picked the most people up off the floor.",
			"Wren Abernathy bruised the most product. He docked it."])
	check(re.run_card.get_verdict_texts() == verdicts, "the first three verdicts in order (bitten and written up left out) %s" % [re.run_card.get_verdict_texts()])
	check(re.run_card.get_block_text() == "\n".join(PackedStringArray([LINE_TITLE, totals]) + verdicts), "the block reads title, totals, verdicts")
	check(re.report.get_row_peers() == [1, DALE, WREN, BART] and re.report.get_cost_texts().size() == 3,
			"the worst case: four report rows, three cost lines (job: '%s')" % re.report.get_job_text())
	await _check_fit("PAID IN FULL")

	step("run 1: NEW RUN clears the totals")
	_expected = {}
	_deposits = 0
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1 and not GameState.is_run_cleared(), "NEW RUN: shift 1 of a new run")
	check(GameState.run_stats.is_empty() and GameState.run_names.is_empty() and GameState.run_shifts == 0 and not re.is_showing_run(),
			"no totals, no names, no shifts, no block")


# --- run 2 ----------------------------------------------------------------------------------------------------------

func _test_run_two() -> void:
	step("run 2: shift 1 paid")
	check(GameState.get_final_shift() == 3, "the final notice is shift 3 again")
	GameState.request_start_round()
	await wait_frames(2)
	await _pay_split([[DALE, 1.0]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not re.is_showing_run(), "shift 1 paid: no block")
	_fold_expected(GameState.stats)
	check(GameState.run_shifts == 1 and _totals_match(), "a new run counts from its own first shift")

	step("run 2: shift 2 missed")
	GameState.request_next_round()
	await wait_frames(2)
	GameState.server_add_stat(BART, Const.STAT_BITTEN)
	GameState.server_write_up(1, Const.WRITE_UP_OTHER)
	GameState.server_write_up(1, Const.WRITE_UP_OTHER)
	GameState.server_add_stat(DALE, Const.STAT_HELPED, 0)   # nothing (amount 0 books nothing)
	GameState.server_add_sale(int(GameState.quota * 0.3), DALE)
	await wait_frames(1)
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "shift 2 missed")
	await wait_frames(2)
	_fold_expected(GameState.stats)
	check(re.is_open() and re.primary_button.text == RoundEndOverlay.TEXT_START_OVER and re.is_showing_run(),
			"a missed payment ends the run: the START OVER card shows THE RUN")
	check(GameState.run_shifts == 2 and _totals_match(), "the missed shift counts as worked (2)")
	var totals := "Shifts worked: 2 · Deposited: %s" % Story.format_money(_deposits)
	check(re.run_card.get_totals_text() == totals, "no bruised / helped-up segments when nobody did either: '%s'" % re.run_card.get_totals_text())
	check(re.run_card.get_verdict_texts() == PackedStringArray(["Dale carried the deposits. Nobody said so.",
			"Bartholomew Jone got bitten the most. It is not covered.", "Tester was written up the most. It stays on file."]),
			"the verdicts skip what nobody did %s" % [re.run_card.get_verdict_texts()])
	await _check_fit("the missed payment")

	step("run 2: START OVER clears the totals")
	_expected = {}
	_deposits = 0
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.run_stats.is_empty() and GameState.run_names.is_empty()
			and GameState.run_shifts == 0 and not re.is_open(), "START OVER: no totals, the card gone")


# --- the rules on synthetic totals ----------------------------------------------------------------------------------

func _test_rules() -> void:
	step("the rules on synthetic totals")
	var saved := [GameState.run_stats, GameState.run_names, GameState.run_shifts]
	GameState.run_stats = {}
	GameState.run_names = {}
	GameState.run_shifts = 0
	check(Story.get_run_verdicts().is_empty() and Story.get_run_totals_line() == "Shifts worked: 0 · Deposited: $0", "nothing: no verdicts, the plain totals")
	GameState.run_stats = {2: {Const.STAT_WRITE_UPS: 1}}
	check(Story.get_run_verdicts() == PackedStringArray(["Dale was written up the most. It stays on file."]), "only write-ups: that one line")
	GameState.run_stats = {1: {Const.STAT_DEPOSITED: 0, Const.STAT_HELPED: 0, Const.STAT_BITTEN: 2}, 2: {Const.STAT_BRUISED: 0}}
	check(Story.get_run_verdicts() == PackedStringArray(["Tester got bitten the most. It is not covered."]), "zero stats are skipped")
	GameState.run_stats = {
		1: {Const.STAT_DEPOSITED: 100, Const.STAT_HELPED: 1, Const.STAT_BRUISED: 3, Const.STAT_BITTEN: 1, Const.STAT_WRITE_UPS: 4},
		2: {Const.STAT_DEPOSITED: 300, Const.STAT_HELPED: 1, Const.STAT_BRUISED: 3, Const.STAT_BITTEN: 5},
		4: {Const.STAT_DEPOSITED: 300, Const.STAT_HELPED: 2},
	}
	GameState.run_names = {4: "Kept Name"}
	GameState.run_shifts = 5
	check(Story.get_run_verdicts() == PackedStringArray(["Dale carried the deposits. Nobody said so.", "Kept Name picked the most people up off the floor.",
			"Tester bruised the most product. He docked it."]), "all five apply: the first three in order; ties go to the lowest id; the run's own name %s" % [Story.get_run_verdicts()])
	check(Story.get_run_totals_line() == "Shifts worked: 5 · Deposited: $700 · Bruised: 6 · Helped up: 4", "every segment above zero: '%s'" % Story.get_run_totals_line())
	GameState.run_stats = {2: {Const.STAT_BRUISED: 1}}
	check(Story.get_run_totals_line() == "Shifts worked: 5 · Deposited: $0 · Bruised: 1", "bruised without helped up: '%s'" % Story.get_run_totals_line())
	GameState.run_stats = saved[0]
	GameState.run_names = saved[1]
	GameState.run_shifts = saved[2]


# --- the menu -------------------------------------------------------------------------------------------------------

func _test_menu() -> void:
	step("back to the menu")
	GameState.request_start_round()
	await wait_frames(2)
	await _pay_split([[DALE, 1.0]])
	check(GameState.run_shifts == 1 and not GameState.run_stats.is_empty(), "a shift paid: totals")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "back in the menu")
	check(GameState.run_stats.is_empty() and GameState.run_names.is_empty() and GameState.run_shifts == 0 and not GameState.is_run_over(),
			"the menu clears the totals")


# --- helpers --------------------------------------------------------------------------------------------------------

## Deposits the shares of the payment for the workers ([peer, share]), then the host pays what is still owed (a covered
## payment ends the shift).
func _pay_split(shares: Array) -> void:
	var q := GameState.quota
	for e: Array in shares:
		var amount := mini(int(q * float(e[1])), maxi(GameState.quota - GameState.round_sales, 0))
		if amount > 0 and GameState.is_playing():
			GameState.server_add_sale(amount, int(e[0]))
	await wait_frames(1)
	if GameState.is_playing():
		GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 1), 1)
	await wait_frames(2)


## The test's own sum: adds one shift's ledger to _expected.
func _fold_expected(ledger: Dictionary) -> void:
	for pk: Variant in ledger:
		var row: Dictionary = ledger[pk]
		var acc: Dictionary = _expected.get(int(pk), {})
		for k: Variant in row:
			acc[StringName(str(k))] = int(acc.get(StringName(str(k)), 0)) + int(row[k])
		_expected[int(pk)] = acc


## True when GameState's run totals equal the test's sum (every peer, every stat; a missing stat reads 0).
func _totals_match() -> bool:
	var peers: Dictionary = {}
	for k: Variant in _expected:
		peers[int(k)] = true
	for k: Variant in GameState.run_stats:
		peers[int(k)] = true
	for id: int in peers:
		var want: Dictionary = _expected.get(id, {})
		var have: Dictionary = GameState.run_stats.get(id, {})
		var keys: Dictionary = {}
		for k: Variant in want:
			keys[k] = true
		for k: Variant in have:
			keys[k] = true
		for k: Variant in keys:
			if int(want.get(k, 0)) != int(have.get(k, 0)):
				print("      mismatch: peer %d %s: want %d, have %d" % [id, k, int(want.get(k, 0)), int(have.get(k, 0))])
				return false
	return true


## True when the run totals are exactly this one ledger (the first shift of a run).
func _ledger_matches(ledger: Dictionary) -> bool:
	return not GameState._stats_differ(GameState._parse_stats(ledger), GameState.run_stats)


## The card at the end of a run fits the 1280x720 screen: inside the viewport, nothing scrolls, its minimum height fits.
func _check_fit(tag: String) -> void:
	await wait_sec(0.5)   # the card's pop-in must be over: a scaled rect would pass any fit check
	var vp := get_viewport().get_visible_rect()
	var card := re.card.get_global_rect()
	var block := re.run_card.get_global_rect()
	var scrolls := re.card.find_children("*", "ScrollContainer", true, false)
	var need := re.card.get_combined_minimum_size()
	var s := re.get_fit_scale()
	var room := vp.size - Vector2.ONE * RoundEndOverlay.FIT_MARGIN * 2.0
	var parts := PackedStringArray()
	for c: Node in re.card.get_child(0).get_children():
		if c is Control and (c as Control).visible:
			parts.append("%s %.0f" % [c.name, (c as Control).size.y])
	print("  FIT| %s: card %s (minimum %s, scale %.3f), block %s; rows: %s" % [tag, card, need, s, block, ", ".join(parts)])
	check(vp.size == Vector2(1280, 720) and vp.encloses(card) and card.encloses(block) and block.size.y > 40.0,
			"%s: the card with THE RUN is inside the 1280x720 screen (%s)" % [tag, card])
	var want := minf(1.0, minf(room.x / need.x, room.y / need.y))
	check(scrolls.is_empty() and is_equal_approx(s, maxf(want, RoundEndOverlay.FIT_MIN_SCALE)) and need.y * s <= room.y + 0.5,
			"%s: nothing scrolls; the card is scaled only as far as it must be (%.3f)" % [tag, s])


func _add_worker(id: int) -> void:
	Net.players[id] = {"name": NAMES[id], "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
	world.server_spawn_player(id)
	Net.players_changed.emit()


## The worker leaves: registry, departed-name memory, signals and the player node, like Net's disconnect cleanup.
func _remove_worker(id: int) -> void:
	var worker_name := Net.get_player_name(id)
	Net.players.erase(id)
	Net.set(&"_departed_names", {id: worker_name})
	Net.players_changed.emit()
	Net.peer_left.emit(id)
	world.server_despawn_player(id)


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
