extends "res://tools/tests/qa_base.gd"
## M15 career suite (career agent): the shift's job (contracts) and the career file on a single headless host with one
## fake worker (Bob: a host-side body without an owning peer, so the SERVER side runs directly on him).
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/career_body.gd --replay --career-file=user://career_test.cfg --port=7985 --round-sec=900
## The run REFUSES to start without --career-file (it must never touch a real record) and removes its files at the end.
## Pins:
##   catalog    nine jobs, unique ids, flat copy (no "!"), goals that grow with the team, the pool by session (event
##              jobs only with events on, "burn" only with a strain that can turn), a roll never repeats the last job
##   the file   missing / corrupt / oversized / half-valid files read as an empty or partial record without one error
##              line; the summary lines; the title ladder at every threshold; a write and a second reader
##   jobs       rolled at shift start (lobby off), in WAITING with the lobby on; every kind driven through the real
##              signals (a cured deposit counts and a wet one does not, the strain, a write-up, hostile_died with a
##              worker, a leak patched in time / late, a drive-by with nobody / somebody shot, hall trays and not pen
##              trays, the payment with a minute left, cash on hand at the end); paid once, the reward in cash on hand,
##              the toast, the Boss, the stat, the HUD line, the shift report; the half-time swap; reset; inert with
##              replay off; what a late joiner is sent (direct RPC), garbage clamped
##   the record written at shift end from the host's own stats, survives a reload, best shift and the title follow
##   titles     the host's own title reaches Net and the WORKERS list; hostile strings are refused
##   pause menu the Record card
## Every engine/script error fails the run unless announced (qa_base.gd).

const BOB := 2
const FAR_A := Vector3(-8.0, 0.0, 5.0)
const FAR_B := Vector3(-8.0, 0.0, 3.0)
const CAREER_SCRIPT := "res://scripts/core/career.gd"

var world: World
var items: ItemManager
var room: Room
var me: Player
var bob: Player
var chute: TurnInStation
var well: Well
var hud: HUD
var _path: String = ""
var _temp_files: PackedStringArray = []
var _met: Array = []       # the job, per contract_met
var _failed: Array = []    # the job, per contract_failed
var _offered: Array = []   # [job, swapped] per contract_offered
var _changed: int = 0
var _title_signals: int = 0


func _run() -> void:
	_label = "career"
	await get_tree().process_frame
	# Headless windows report 1280x1280; force the reference logical size (the smallest stretch "expand" allows).
	get_tree().root.size = Vector2i(1280, 720)
	var b: BalanceConfig = Config.balance
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent,
			"this run has its own career file (%s)" % _path):
		finish(); return
	check(Config.replay_enabled, "this suite runs with --replay")
	_remove(_path)
	Career.clear_record()
	GameState.contract_met.connect(func(c: Dictionary) -> void: _met.append(c))
	GameState.contract_failed.connect(func(c: Dictionary) -> void: _failed.append(c))
	GameState.contract_offered.connect(func(c: Dictionary, swapped: bool) -> void: _offered.append([c, swapped]))
	GameState.contract_changed.connect(func() -> void: _changed += 1)

	_test_catalog(b)
	_test_file()

	step("hosting")
	# Nothing turns hostile by itself and a covered payment does not end the shift: this run decides when things happen.
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	b.end_round_on_quota_met = false
	Game.start_host("Tester", port_arg(7985))
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player exist")
	if Game.world == null:
		_cleanup(); finish(); return
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	Net.players[BOB] = {"name": "Bob", "color": Net.PALETTE[BOB - 1]}
	bob = world.server_spawn_player(BOB)
	Net.players_changed.emit()
	await wait_frames(3)
	chute = room.get_station("TurnInStation") as TurnInStation
	well = room.get_station("Well") as Well
	if not check(bob != null and chute != null and well != null and hud != null, "Bob, the chute, the tank and the HUD exist"):
		_cleanup(); finish(); return
	_put(bob, FAR_B)
	_put_me(FAR_A)

	await _test_waiting(b)
	await _test_shift_one(b)
	await _test_shift_two(b)
	await _test_shift_three(b)
	await _test_reset_and_lobby(b)
	await _test_no_replay(b)
	await _test_wire(b)
	await _test_pause_menu()
	_cleanup()
	finish()


# --- the catalog ------------------------------------------------------------------------------------------------------

func _test_catalog(b: BalanceConfig) -> void:
	step("catalog")
	var ids := Contracts.ids()
	var unique: Dictionary = {}
	for id in ids:
		unique[id] = true
	check(ids.size() >= 8 and unique.size() == ids.size(), "%d jobs, every id once" % ids.size())
	for id: StringName in [&"cured", &"strain", &"clean", &"burn", &"leak", &"driveby", &"hall", &"cash"]:
		check(Contracts.has(id), "the catalog has '%s'" % id)
	var ctx := {"team": 1, "round": 1, "money": 150, "owed": 350, "reward": b.contract_reward, "strain": &"purple"}
	var copy_ok := true
	var fields_ok := true
	for id in ids:
		var c := Contracts.build(id, ctx)
		var text := String(c.get("text", ""))
		if text == "" or text.contains("!") or text.contains("%") or text != text.strip_edges():
			copy_ok = false
		for key: String in ["id", "text", "goal", "progress", "reward", "done"]:
			if not c.has(key):
				fields_ok = false
		if int(c.get("goal", 0)) < 1 or int(c.get("progress", -1)) != 0 or bool(c.get("done", true)) or int(c.get("reward", -1)) != b.contract_reward:
			fields_ok = false
		var judge := Contracts.get_judge(id)
		if judge != Contracts.JUDGE_SPOT and judge != Contracts.JUDGE_END:
			fields_ok = false
	check(copy_ok, "every job's text is filled in, flat, without an exclamation mark")
	check(fields_ok, "every job carries id, text, goal, progress 0, reward %d, done false, and says when it is judged" % b.contract_reward)
	check(Contracts.build(&"nothing", ctx).is_empty() and not Contracts.has(&"nothing"), "an unknown id builds nothing")
	check(String(Contracts.build(&"cured", ctx)["text"]) == "three cured bundles" and int(Contracts.build(&"cured", ctx)["goal"]) == 3, "solo: 'three cured bundles'")
	ctx["team"] = 4
	check(String(Contracts.build(&"cured", ctx)["text"]) == "six cured bundles" and int(Contracts.build(&"hall", ctx)["goal"]) == 6, "four workers: six")
	var strain_job := Contracts.build(&"strain", ctx)
	check(String(strain_job["text"]) == "six bundles of Purple Haze" and String(strain_job["strain"]) == "purple", "the strain job names its strain ('%s')" % strain_job["text"])
	check(Contracts.cash_goal(150, 350) == 360 and Contracts.cash_goal(205, 0) == 240 and Contracts.cash_goal(0, 0) == 30,
			"cash: on hand + 60%% of what is owed (at least $30), rounded up to $10 (%d, %d)" % [Contracts.cash_goal(150, 350), Contracts.cash_goal(205, 0)])
	check(String(Contracts.build(&"cash", ctx)["text"]) == "end the shift with more than $360 on hand" and int(Contracts.build(&"cash", ctx)["goal"]) == 360, "the cash job names its number")
	check(Contracts.number_words(3) == "three" and Contracts.number_words(12) == "twelve" and Contracts.number_words(14) == "14", "numbers in words up to twelve")
	check(Contracts.get_judge(&"clean") == Contracts.JUDGE_END and Contracts.get_judge(&"cash") == Contracts.JUDGE_END and Contracts.get_judge(&"cured") == Contracts.JUDGE_SPOT,
			"'clean' and 'cash' are judged when the shift ends, the rest on the spot")
	check(Contracts.get_need(&"burn") == &"hostile" and Contracts.get_need(&"leak") == &"leak" and Contracts.get_need(&"driveby") == &"driveby" and Contracts.get_need(&"cured") == &"",
			"'burn', 'leak' and 'driveby' need something to come")

	step("catalog: the pool and the roll")
	var plain := Contracts.pool({"events": false, "can_mutate": false})
	check(not plain.has(&"leak") and not plain.has(&"driveby") and not plain.has(&"burn") and plain.has(&"cured") and plain.has(&"cash") and plain.size() == ids.size() - 4,
			"no events, nothing that turns: only the jobs that need nothing (%d)" % plain.size())
	check(not plain.has(&"clean") and Contracts.pool({"events": true, "can_mutate": false}).has(&"clean"), "'no write-ups' is only offered on a floor the Boss walks (events on)")
	var full := Contracts.pool({"events": true, "can_mutate": true})
	check(full.size() == ids.size(), "events on and a strain that turns: every job")
	check(not Contracts.pool({"events": true, "can_mutate": false}).has(&"burn") and Contracts.pool({"events": true, "can_mutate": false}).has(&"leak"), "'burn' only with a strain that can turn hostile")
	check(not Contracts.pool({"early_ok": false}).has(&"early"), "'early' is not offered in a shift too short for it")
	var rng := RandomNumberGenerator.new()
	rng.seed = 15
	var seen: Dictionary = {}
	var repeats := 0
	var outside := 0
	var previous: StringName = &""
	for i in 400:
		var pick := Contracts.roll({"events": true, "can_mutate": true}, rng, previous)
		if pick == previous:
			repeats += 1
		if not full.has(pick):
			outside += 1
		seen[pick] = true
		previous = pick
	check(repeats == 0 and outside == 0, "400 rolls: never the last shift's job, always from the pool")
	check(seen.size() == ids.size(), "the roll reaches every job (%d of %d)" % [seen.size(), ids.size()])
	var plain_only := true
	for i in 100:
		if not plain.has(Contracts.roll({"events": false, "can_mutate": false}, rng, &"")):
			plain_only = false
	check(plain_only, "a session without events never rolls an event job")
	check(Contracts.fallback_id(false) == &"clean" and Contracts.fallback_id(true) == &"cash", "the swap: 'clean' while nobody is written up, else 'cash'")

	step("catalog: copy")
	var open := {"id": "cured", "text": "three cured bundles", "goal": 3, "progress": 1, "reward": 60, "done": false}
	check(Contracts.hud_text(open) == "Job: three cured bundles 1 / 3", "HUD: '%s'" % Contracts.hud_text(open))
	open["progress"] = 3
	open["done"] = true
	check(Contracts.hud_text(open) == "Job: three cured bundles 3 / 3 · paid", "HUD, met: '%s'" % Contracts.hud_text(open))
	check(Contracts.report_text(open) == "Job: three cured bundles. Done. $60 paid.", "report, met: '%s'" % Contracts.report_text(open))
	var failed := {"id": "clean", "text": "no write-ups this shift", "goal": 1, "progress": 0, "reward": 60, "done": false, "failed": true}
	check(Contracts.hud_text(failed) == "Job: no write-ups this shift · failed" and Contracts.report_text(failed) == "Job: no write-ups this shift. Failed.", "a failed job says so")
	failed["failed"] = false
	check(Contracts.hud_text(failed) == "Job: no write-ups this shift" and Contracts.report_text(failed) == "Job: no write-ups this shift. Not done.", "an open yes / no job has no counter")
	check(Contracts.hud_text({}) == "" and Contracts.report_text({}) == "", "no job, no line")
	var lines_ok := true
	for k: String in Story.CAREER_LINES:
		var text := String(Story.CAREER_LINES[k])
		if text.contains("!") or Story.line(k) != text:
			lines_ok = false
	check(lines_ok and Story.line("job_done") == "That was the job. %s.", "every job line is installed in Story and has no exclamation mark")
	for text: String in [Contracts.TEXT_HUD, Contracts.TEXT_HUD_COUNT, Contracts.TEXT_HUD_PAID, Contracts.TEXT_HUD_FAILED, Contracts.TEXT_REPORT_DONE,
			Contracts.TEXT_REPORT_FAILED, Contracts.TEXT_REPORT_OPEN, Career.TEXT_SHIFTS, Career.TEXT_BEST, Career.TEXT_DEPOSITED, Career.TEXT_CONTRACTS,
			Career.TEXT_BURNS, Career.TEXT_TROUBLE, PauseMenu.TEXT_RECORD_EMPTY]:
		if text.contains("!"):
			lines_ok = false
	check(lines_ok, "HUD, report and record copy without an exclamation mark")


# --- the career file --------------------------------------------------------------------------------------------------

func _test_file() -> void:
	step("career file: missing")
	var reader := _reader()
	check(not reader.load_file(_path), "no file yet: nothing is read")
	check(reader.get_summary_lines().is_empty() and reader.get_title() == "New hire" and reader.get_record("shifts") == 0 and reader.get_record("purple") == 0,
			"an empty record: no lines, 'New hire', zeros")
	check(Career.get_summary_lines().is_empty() and Career.get_title() == "New hire", "the autoload starts empty too")
	check(Career._is_scripted_run() and DisplayServer.get_name() == "headless", "a headless run, or one started with -s, keeps a file only when --career-file names one")
	check(not reader.persistent and not reader.save() and not FileAccess.file_exists(_path), "a record that is not persistent writes nothing on save()")

	step("career file: the title ladder")
	var titles: PackedStringArray = Career.get_titles()
	var ladder_ok := titles.size() >= 6
	var unique: Dictionary = {}
	for t in titles:
		unique[t] = true
		if t.contains("!") or t.length() > Net.MAX_TITLE_LENGTH or Net.sanitize_title(t) != t or not Career.is_known_title(t):
			ladder_ok = false
	check(ladder_ok and unique.size() == titles.size(), "%d flat titles, each one the host accepts %s" % [titles.size(), titles])
	var expected := {0: "New hire", 1: "Floor hand", 2: "Tray hand", 3: "Lead hand", 4: "Shift lead", 5: "Shift lead", 6: "The Boss's problem", 9: "The Boss's problem"}
	var rungs_ok := true
	for best: int in expected:
		if Career.title_for(best) != String(expected[best]):
			rungs_ok = false
	check(rungs_ok, "the title at every threshold: 0 New hire, 1 Floor hand, 2 Tray hand, 3 Lead hand, 4 Shift lead, 6 The Boss's problem")

	step("career file: a good one")
	var good := _temp("good")
	_write_text(good, "[career]\nshifts=12\nbest_round=4\ndeposited=3140\ncontracts=5\nburns=2\nbitten=7\nshot=1\nbackroom=3\n\n[strains]\nbudget=9\npurple=14\n")
	check(reader.load_file(good), "read")
	var lines: Array[String] = reader.get_summary_lines()
	check(lines == ["Shifts worked: 12", "Best shift: 4", "Deposited: $3,140", "Jobs done: 5", "Plants burnt: 2", "Bitten: 7. Shot: 1. Back room: 3."],
			"the summary lines %s" % [lines])
	check(lines.size() >= 4 and lines.size() <= 6, "four to six lines")
	check(reader.get_title() == "Shift lead" and reader.get_record("best_round") == 4 and reader.get_record("purple") == 14 and reader.get_record("budget") == 9 and reader.get_record("golden") == 0,
			"the title follows the best shift; a strain id reads its deposits")
	var copy := _temp("copy")
	check(reader.save_file(copy) and FileAccess.file_exists(copy) and not FileAccess.file_exists(copy + ".tmp"), "written (through a temp file that is gone afterwards)")
	var second := _reader()
	check(second.load_file(copy) and second.get_summary_lines() == lines and second.get_strain_deposits() == reader.get_strain_deposits(), "a second reader on the copy sees the same record")
	check(reader.save_file(copy) and second.load_file(copy) and second.get_record("shifts") == 12, "written again over the old file")
	var cfg := ConfigFile.new()
	check(cfg.load(copy) == OK and int(cfg.get_value("career", "shifts", 0)) == 12 and int(cfg.get_value("strains", "purple", 0)) == 14, "the file is a plain INI (a ConfigFile reads it)")

	step("career file: corrupt")
	var bad := _temp("bad")
	var junk := PackedByteArray()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 900:
		junk.append(rng.randi_range(0, 255))
	junk.append_array(PackedByteArray([0xFF, 0xFE, 0x00, 0xC3, 0x28, 0x5B, 0x63, 0x0A]))
	_write_bytes(bad, junk)
	reader.load_file(bad)
	check(reader.get_summary_lines().is_empty() and reader.get_title() == "New hire" and reader.get_record("shifts") == 0, "random bytes read as an empty record")
	_write_text(bad, "[career]\nshifts=abc\nbest_round=-4\ndeposited=99999999999999999999999\ncontracts=3\nbogus=7\nburns==\n=5\n[strains]\npurple=2\nshifts=9\nBAD KEY=4\n[career\nbitten=1\n")
	reader.load_file(bad)
	check(reader.get_record("contracts") == 3 and reader.get_record("shifts") == 0 and reader.get_record("best_round") == 0 and reader.get_record("deposited") == 0,
			"a half-valid file: the good lines are kept, text, signs and overflowing numbers are dropped")
	check(reader.get_record("purple") == 2 and reader.get_record("bogus") == 0 and reader.get_strain_deposits().size() == 1 and reader.get_record("bitten") == 0,
			"unknown keys and a broken section header are ignored (%s)" % [reader.get_strain_deposits()])
	check(reader.get_summary_lines().is_empty(), "no shift on file: still no lines")
	_write_text(bad, "")
	check(not reader.load_file(bad) and reader.get_record("contracts") == 0, "an empty file is an empty record")
	_write_text(bad, "[career]\nshifts=3\n" + "x".repeat(Career.MAX_FILE_BYTES))
	check(not reader.load_file(bad) and reader.get_record("shifts") == 0, "an oversized file is not read")
	_write_text(bad, "[career]\nshifts=4000000000\nbest_round=2\n")
	reader.load_file(bad)
	check(reader.get_record("shifts") == Career.MAX_VALUE and reader.get_title() == "Tray hand", "a number past the cap is clamped")
	reader.free()
	second.free()


# --- WAITING ----------------------------------------------------------------------------------------------------------

func _test_waiting(_b: BalanceConfig) -> void:
	step("waiting (lobby off)")
	check(not Config.lobby_enabled and GameState.phase == GameState.Phase.WAITING, "headless: no lobby, WAITING")
	check(GameState.get_contract().is_empty() and hud.get_job_text() == "", "no job before the shift starts; the HUD line is hidden")
	check(Net.get_player_title(1) == "New hire", "the host's title is in Net's list ('%s')" % Net.get_player_title(1))
	check(hud.get_title_text(1) == "New hire" and hud.get_title_text(BOB) == "", "WORKERS: 'New hire' under the host, nothing under Bob (he sent none)")
	check(hud.player_list.get_child_count() == 3, "the title is a line of its own under the row (two rows + one title line)")
	var pm: PauseMenu = hud.pause_menu
	pm.sync_record()
	check(pm.get_record_texts() == PackedStringArray(["New hire", "Nothing on file."]), "pause menu Record: %s" % [pm.get_record_texts()])
	await wait_frames(1)


# --- shift 1: every kind ----------------------------------------------------------------------------------------------

func _test_shift_one(b: BalanceConfig) -> void:
	step("shift 1: a job is rolled when the shift starts")
	toasts.clear()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_frames(2)
	var job := GameState.get_contract()
	var plain := Contracts.pool({"events": false, "can_mutate": false})
	check(not job.is_empty() and plain.has(StringName(String(job["id"]))), "a job that needs nothing (no events here, nothing turns): '%s'" % job.get("id", ""))
	check(int(job["reward"]) == b.contract_reward and int(job["round"]) == 1 and int(job["progress"]) == 0 and not bool(job["done"]), "reward %d, shift 1, open" % b.contract_reward)
	check(_offered.size() == 1 and not bool(_offered[0][1]), "contract_offered once")
	check(hud.get_job_text() == Contracts.hud_text(job) and hud.get_job_text().begins_with("Job: ") and not hud.is_job_settled(), "HUD: '%s'" % hud.get_job_text())
	check(toast_seen("Job: %s. $%d." % [job["text"], b.contract_reward]), "toast: the job and what it pays")
	var box := hud.quota_bar.get_parent().get_node_or_null(^"CareerBox")
	check(box != null and box.get_index() == box.get_parent().get_child_count() - 1 and box.get_node_or_null(^"JobLine") is Label,
			"the line lives in its own box under the payment bar")
	GameState.server_add_money(500)
	await wait_frames(1)

	step("shift 1: cured bundles")
	_job(&"cured")
	job = GameState.get_contract()
	check(String(job["text"]) == "four cured bundles" and int(job["goal"]) == 4, "two workers: '%s'" % job["text"])
	var met0 := _met.size()
	var money0 := GameState.money
	check(await _deposit(&"budget", false, BOB) and int(GameState.get_contract()["progress"]) == 0, "a wet bundle does not count")
	check(await _deposit(&"budget", true, BOB) and int(GameState.get_contract()["progress"]) == 1, "a cured one does (1 / 4)")
	check(hud.get_job_text() == "Job: four cured bundles 1 / 4", "HUD: '%s'" % hud.get_job_text())
	await _deposit(&"budget", true, BOB)
	await _deposit(&"purple", true, 1)
	check(int(GameState.get_contract()["progress"]) == 3 and _met.size() == met0, "3 / 4: not paid yet")
	Story.bark_log = PackedStringArray()
	toasts.clear()
	var before := GameState.money
	var value := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 1, GameState.get_sale_multiplier(), true)
	await _deposit(&"budget", true, BOB)
	job = GameState.get_contract()
	check(bool(job["done"]) and int(job["progress"]) == 4 and _met.size() == met0 + 1, "the fourth: met, contract_met once")
	check(GameState.money == before + value + b.contract_reward, "the reward lands in cash on hand (+$%d on top of the $%d deposit)" % [b.contract_reward, value])
	check(GameState.get_stat(1, Const.STAT_CONTRACTS) == 1 and GameState.get_stat(BOB, Const.STAT_CONTRACTS) == 0, "STAT_CONTRACTS +1 for peer 1, the floor")
	check(toast_seen("Job done: four cured bundles. $%d to cash on hand." % b.contract_reward), "toast: job done")
	var boss_line := Story.line("job_done") % Story.loop_amount_words(b.contract_reward)
	check(Array(Story.bark_log).has(boss_line) and (b.contract_reward != 60 or boss_line == "That was the job. Sixty."), "the Boss: '%s'" % boss_line)
	check(hud.get_job_text() == "Job: four cured bundles 4 / 4 · paid" and hud.is_job_settled(), "HUD: '%s', dimmed" % hud.get_job_text())
	before = GameState.money
	await _deposit(&"budget", true, BOB)
	check(_met.size() == met0 + 1 and GameState.money == before + value and GameState.get_stat(1, Const.STAT_CONTRACTS) == 1, "one more cured bundle: paid once only")
	check(Career.get_record("contracts") == 1, "the record counts the job at once")
	var reader := _reader()
	check(reader.load_file(_path) and reader.get_record("contracts") == 1 and reader.get_record("shifts") == 0, "and the file has it already (a second reader)")
	reader.free()
	check(money0 < GameState.money, "cash on hand grew")

	step("shift 1: bundles of one strain")
	_job(&"strain", {"strain": &"purple"})
	job = GameState.get_contract()
	check(String(job["text"]) == "four bundles of Purple Haze" and String(job["strain"]) == "purple", "'%s'" % job["text"])
	met0 = _met.size()
	check(await _deposit(&"budget", false, BOB) and int(GameState.get_contract()["progress"]) == 0, "Budget Bud does not count")
	await _deposit(&"purple", false, 1)
	await _deposit(&"purple", true, 1)
	await _deposit(&"purple", false, BOB)
	check(int(GameState.get_contract()["progress"]) == 3 and hud.get_job_text() == "Job: four bundles of Purple Haze 3 / 4", "Purple Haze does, wet or cured, whoever deposits (3 / 4)")
	await _deposit(&"purple", false, BOB)
	check(bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1 and GameState.get_stat(1, Const.STAT_CONTRACTS) == 2, "the fourth: met")

	step("shift 1: no write-ups")
	_job(&"clean")
	var failed0 := _failed.size()
	met0 = _met.size()
	toasts.clear()
	GameState.server_write_up(BOB, Const.WRITE_UP_LOITERING)
	await wait_frames(2)
	job = GameState.get_contract()
	check(bool(job["failed"]) and not bool(job["done"]) and _failed.size() == failed0 + 1 and _met.size() == met0, "a write-up fails it at once (contract_failed)")
	check(hud.get_job_text() == "Job: no write-ups this shift · failed" and hud.is_job_settled() and toast_seen("Job failed: no write-ups this shift."), "HUD and toast say so ('%s')" % hud.get_job_text())
	GameState.server_write_up(BOB, Const.WRITE_UP_LOITERING)
	await wait_frames(1)
	check(_failed.size() == failed0 + 1, "a second write-up fails nothing twice")

	step("shift 1: burn a hostile plant")
	_job(&"burn")
	met0 = _met.size()
	Hostiles._rpc_died.rpc(9999, 0)
	await wait_frames(1)
	check(not bool(GameState.get_contract()["done"]) and _met.size() == met0, "a hostile plant that died with nobody's flame on it does not count")
	var hostile_id := Hostiles.server_spawn(&"budget", Vector3(6.0, 0.0, 5.0))
	check(hostile_id > 0, "a hostile plant on the floor")
	Hostiles.server_apply_fire(hostile_id, b.hostile_burn_sec + 0.1, 1)
	await wait_frames(2)
	check(bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1 and GameState.get_stat(1, Const.STAT_BURNS) == 1, "hostile_died with a worker: met")
	Hostiles.server_despawn_all()
	await wait_frames(2)

	step("shift 1: patch a leak inside ten seconds")
	_job(&"leak")
	met0 = _met.size()
	check(Events.server_start_event(Events.EVENT_LEAK), "a leak starts")
	Events.tick(4.0)
	check(well.server_patch(BOB), "Bob patches it after four seconds")
	await wait_frames(2)
	check(bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1, "met")
	_job(&"leak")
	failed0 = _failed.size()
	check(Events.server_start_event(Events.EVENT_LEAK), "another leak")
	Events.tick(Contracts.LEAK_SECONDS + 1.0)
	check(well.server_patch(BOB), "patched after eleven seconds")
	await wait_frames(2)
	job = GameState.get_contract()
	check(bool(job["failed"]) and not bool(job["done"]) and _failed.size() == failed0 + 1 and _met.size() == met0 + 1, "too late: failed, not paid")

	step("shift 1: a drive-by with nobody knocked down")
	var lanes: Array = room.get_gunfire_lanes()
	var safe := _safe_spots(lanes, 2)
	if not check(safe.size() == 2, "two spots clear of every lane"):
		return
	_put_me(safe[0])
	_put(bob, safe[1])
	await wait_frames(2)
	_job(&"driveby")
	met0 = _met.size()
	before = GameState.money
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "a drive-by starts")
	Events.tick(b.driveby_warning_sec + b.driveby_sec * 0.5)
	check(not bool(GameState.get_contract()["done"]), "not judged while the guns go")
	Events.tick(b.driveby_sec)
	await wait_frames(2)
	check(not Events.is_event_active() and GameState.get_stat(1, Const.STAT_SHOT) == 0 and GameState.get_stat(BOB, Const.STAT_SHOT) == 0, "it ran its course, nobody was hit")
	check(bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1, "met when it ends")
	check(GameState.money == before - mini(b.driveby_fine, before) + b.contract_reward, "the bill went out, the reward came in")
	_job(&"driveby")
	failed0 = _failed.size()
	check(Events.server_start_event(Events.EVENT_DRIVEBY), "another drive-by")
	var lane: Dictionary = lanes[_open_lane(lanes)]
	_put(bob, _at(lane["from"], _lane_end(lane), 1.2))
	await wait_frames(2)
	await wait_until(func() -> bool: return bob.can_be_staggered(), 4.0, "Bob can be knocked down")
	var hit := Events.server_fire_lane(lane)
	await wait_frames(2)
	check((hit.get("workers", []) as Array).has(BOB) and GameState.get_stat(BOB, Const.STAT_SHOT) == 1, "Bob stands in a lane and goes down")
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "worker_shot fails the job")
	_put(bob, safe[1])
	Events.server_end_event()
	await wait_frames(2)
	check(not bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1, "and the end of that drive-by pays nothing")

	step("shift 1: trays in the grow hall")
	_job(&"hall")
	job = GameState.get_contract()
	check(String(job["text"]) == "harvest four trays in the grow hall" and int(job["goal"]) == 4, "'%s'" % job["text"])
	met0 = _met.size()
	check(room.get_area_index(_plot(1).global_position) == 0 and room.get_area_index(_plot(7).global_position) == Contracts.HALL_AREA_INDEX, "GrowPlot1 is in the pen, GrowPlot7 in the hall")
	check(await _harvest(1, bob) and int(GameState.get_contract()["progress"]) == 0, "a pen tray does not count")
	check(await _harvest(7, bob) and int(GameState.get_contract()["progress"]) == 1, "a hall tray does (1 / 4)")
	await _harvest(8, bob)
	await _harvest(9, bob)
	check(int(GameState.get_contract()["progress"]) == 3 and _met.size() == met0, "3 / 4")
	check(await _harvest(10, bob) and bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1, "the fourth: met")

	step("shift 1: the back room, a round and two bites (for the host's record)")
	GameState.server_add_stat(1, Const.STAT_SHOT)
	GameState.server_add_stat(1, Const.STAT_BITTEN, 2)
	check(GameState.server_send_to_backroom(1, 30.0), "the host is sent to the back room")
	await wait_frames(2)
	GameState.server_release_from_backroom(1)
	await wait_frames(2)
	_put_me(safe[0])

	step("shift 1: the half-time swap")
	_job(&"burn")
	var id0 := Hostiles.server_spawn(&"budget", Vector3(6.0, 0.0, 5.0))
	await wait_frames(1)
	GameState.time_left = 440.0
	await wait_frames(3)
	check(String(GameState.get_contract()["id"]) == "burn", "past half time with the plant on the floor: the job stays")
	Hostiles.server_despawn_all()
	check(id0 > 0, "(the plant was there)")
	GameState.time_left = 890.0
	await wait_frames(1)
	_job(&"leak")
	var offers0 := _offered.size()
	await wait_frames(3)
	check(String(GameState.get_contract()["id"]) == "leak" and _offered.size() == offers0, "before half time the leak job waits for its leak")
	toasts.clear()
	Story.bark_log = PackedStringArray()
	GameState.time_left = 449.0
	await wait_frames(3)
	job = GameState.get_contract()
	check(String(job["id"]) == "cash" and not bool(job["done"]) and not bool(job["failed"]), "half the shift gone and no leak came: swapped for '%s' (Bob was written up, so not 'clean')" % job["id"])
	check(_offered.size() == offers0 + 1 and bool(_offered.back()[1]), "contract_offered(swapped = true)")
	check(toast_seen("Job changed: %s. $%d." % [job["text"], b.contract_reward]) and (Array(Story.bark_log).has(Story.line("job_swapped")) or Story.get_pending_text() == Story.line("job_swapped")),
			"toast and the Boss say the job changed")
	check(int(job["reward"]) == b.contract_reward, "nothing lost: the same reward")
	await wait_frames(3)
	check(String(GameState.get_contract()["id"]) == "cash" and _offered.size() == offers0 + 1, "swapped once")

	step("shift 1: cash on hand, judged when the shift ends")
	GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 0) + 10, BOB)
	await wait_frames(1)
	_job(&"cash")
	job = GameState.get_contract()
	var goal := int(job["goal"])
	check(goal == Contracts.cash_goal(GameState.money, 0) and goal > GameState.money and String(job["text"]) == "end the shift with more than %s on hand" % HUD.format_money(goal),
			"the target is above what is on hand ($%d > $%d)" % [goal, GameState.money])
	GameState.server_add_money(goal - GameState.money + 1)
	await wait_frames(2)
	check(not bool(GameState.get_contract()["done"]) and hud.get_job_text() == "Job: " + String(job["text"]), "above the target, but it is judged at the end ('%s')" % hud.get_job_text())
	met0 = _met.size()
	before = GameState.money
	var contracts_before := GameState.get_stat(1, Const.STAT_CONTRACTS)
	var expect := _expected_record(1, true)
	Story.bark_log = PackedStringArray()
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift ends, payment made")
	await wait_frames(3)
	job = GameState.get_contract()
	check(bool(job["done"]) and _met.size() == met0 + 1 and GameState.money == before + b.contract_reward, "the cash job is met at the end and paid")
	check(GameState.get_stat(1, Const.STAT_CONTRACTS) == contracts_before + 1 and contracts_before == 6, "seven jobs met this shift (%d)" % GameState.get_stat(1, Const.STAT_CONTRACTS))
	check(not Array(Story.bark_log).has(Story.line("job_done") % Story.loop_amount_words(b.contract_reward)) and Story.last_bark == Story.line("paid"), "the Boss says 'paid', the report has the job")
	var report: ShiftReport = hud.round_end.report
	check(report.get_job_text() == "Job: %s. Done. %s paid." % [job["text"], HUD.format_money(b.contract_reward)], "shift report: '%s'" % report.get_job_text())
	check(get_viewport().get_visible_rect().encloses(hud.round_end.card.get_global_rect()), "the round-end card still fits the screen with the job line (%s)" % hud.round_end.card.get_global_rect())

	step("shift 1: the record")
	expect["contracts"] = 7
	_check_record(expect, "after shift 1")
	check(Career.get_record("burns") == 1 and Career.get_record("shot") == 1 and Career.get_record("bitten") == 2 and Career.get_record("backroom") == 1,
			"the host's own doings: one plant burnt, shot once, bitten twice, one back room")
	check(Career.get_record("purple") == 3 and Career.get_record("budget") == 0 and Career.get_record("deposited") > 0,
			"three Purple Haze bundles and $%d deposited: Bob's deposits are Bob's" % Career.get_record("deposited"))
	check(Career.get_summary_lines().size() == 6 and Career.get_summary_lines()[0] == "Shifts worked: 1" and Career.get_summary_lines()[1] == "Best shift: 1", "the lines: %s" % [Career.get_summary_lines()])
	check(Career.get_title() == "Floor hand" and Net.get_player_title(1) == "Floor hand" and hud.get_title_text(1) == "Floor hand", "best shift 1: 'Floor hand', in Net's list and in the WORKERS list")


# --- shift 2: the next roll, a job that runs out of time, "clean" at the end ------------------------------------------

func _test_shift_two(b: BalanceConfig) -> void:
	step("shift 2: a new job")
	var offers0 := _offered.size()
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	await wait_frames(2)
	var job := GameState.get_contract()
	check(not job.is_empty() and int(job["round"]) == 2 and not bool(job["done"]) and not bool(job["failed"]) and _offered.size() == offers0 + 1, "rolled for shift 2: '%s'" % job.get("id", ""))
	check(String(job["id"]) != "cash", "never the kind of the shift before")
	check(GameState.get_stat(1, Const.STAT_CONTRACTS) == 0 and hud.get_job_text() == Contracts.hud_text(job) and not hud.is_job_settled(), "a fresh ledger, a fresh line")

	step("shift 2: the swap on a floor with no write-ups")
	_job(&"driveby")
	GameState.time_left = 449.0
	await wait_frames(3)
	job = GameState.get_contract()
	check(String(job["id"]) == "clean" and bool(_offered.back()[1]) and not bool(job["failed"]), "no drive-by by half time and nobody written up: swapped for '%s'" % job["text"])
	GameState.time_left = 890.0
	await wait_frames(1)

	step("shift 2: the payment with a minute on the clock")
	_job(&"early")
	var met0 := _met.size()
	GameState.server_add_sale(GameState.quota - 1, BOB)
	await wait_frames(1)
	check(not bool(GameState.get_contract()["done"]), "a dollar short: not yet")
	GameState.server_add_sale(1, BOB)
	await wait_frames(1)
	check(GameState.round_sales >= GameState.quota and bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1, "covered with %.0f s left: met on the spot" % GameState.time_left)

	step("shift 2: no write-ups, judged at the end")
	_job(&"clean")
	met0 = _met.size()
	await wait_frames(2)
	check(not bool(GameState.get_contract()["done"]), "not judged before the end")
	var expect := _expected_record(2, true)
	var before := GameState.money
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift ends, payment made")
	await wait_frames(3)
	check(bool(GameState.get_contract()["done"]) and _met.size() == met0 + 1 and GameState.money == before + b.contract_reward, "nobody was written up: met and paid")
	expect["contracts"] = int(expect["contracts"]) + 1
	_check_record(expect, "after shift 2")
	check(Career.get_record("shifts") == 2 and Career.get_record("best_round") == 2, "two shifts worked, best shift 2")
	check(Career.get_title() == "Tray hand" and Net.get_player_title(1) == "Tray hand" and hud.get_title_text(1) == "Tray hand", "the title moved up: 'Tray hand' everywhere")


# --- shift 3: a missed payment ----------------------------------------------------------------------------------------

func _test_shift_three(_b: BalanceConfig) -> void:
	step("shift 3: the payment is missed")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 3, 3.0, "shift 3 running")
	await wait_frames(2)
	_job(&"early")
	var failed0 := _failed.size()
	GameState.time_left = Contracts.EARLY_SECONDS + 5.0
	await wait_frames(3)
	check(not bool(GameState.get_contract()["failed"]), "the payment with a minute on the clock, 65 s left: still open")
	GameState.time_left = Contracts.EARLY_SECONDS - 1.0
	await wait_frames(3)
	check(bool(GameState.get_contract()["failed"]) and _failed.size() == failed0 + 1, "59 s left and the payment is not covered: failed")
	_job(&"clean")
	var met0 := _met.size()
	failed0 = _failed.size()
	var expect := _expected_record(3, false)
	var before := GameState.money
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 3.0, "the shift ends, payment missed")
	await wait_frames(3)
	var job := GameState.get_contract()
	check(bool(job["failed"]) and not bool(job["done"]) and _met.size() == met0 and _failed.size() == failed0 + 1 and GameState.money == before,
			"a job judged at the end needs the payment: failed, nothing paid")
	check(hud.round_end.report.get_job_text() == "Job: no write-ups this shift. Failed.", "shift report: '%s'" % hud.round_end.report.get_job_text())
	_check_record(expect, "after shift 3")
	check(Career.get_record("shifts") == 3 and Career.get_record("best_round") == 2 and Career.get_title() == "Tray hand", "three shifts worked, best shift still 2")


# --- reset, the lobby roll ----------------------------------------------------------------------------------------------

func _test_reset_and_lobby(_b: BalanceConfig) -> void:
	step("reset")
	GameState.request_retry()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, 3.0, "START OVER: WAITING, shift 1")
	await wait_frames(3)
	check(GameState.get_contract().is_empty() and hud.get_job_text() == "", "the old job is gone; with the lobby off the next one comes at the start")
	var shifts := Career.get_record("shifts")

	step("the lobby: rolled when the game waits for the shift")
	Config.lobby_enabled = true
	var offers0 := _offered.size()
	GameState.server_reset_game()
	await wait_frames(3)
	var job := GameState.get_contract()
	check(GameState.phase == GameState.Phase.WAITING and not job.is_empty() and int(job["round"]) == 1 and _offered.size() == offers0 + 1,
			"with the lobby on the job is up while WAITING, once ('%s')" % job.get("id", ""))
	check(hud.get_job_text() == Contracts.hud_text(job), "and on the HUD already")
	GameState.server_send_full_state(1)
	await wait_frames(3)
	check(_offered.size() == offers0 + 1 and GameState.get_contract() == job, "a full resync rolls nothing new")
	GameState.server_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "the shift starts")
	await wait_frames(3)
	check(GameState.get_contract() == job and _offered.size() == offers0 + 1, "the job put up in the alley is the shift's job")
	Config.lobby_enabled = false
	GameState.server_reset_game()
	await wait_frames(3)
	check(GameState.get_contract().is_empty() and Career.get_record("shifts") == shifts, "reset mid-shift: no job, and a shift that never ended is not on the record")


# --- replay off -------------------------------------------------------------------------------------------------------

func _test_no_replay(b: BalanceConfig) -> void:
	step("replay off: nothing is offered")
	Config.replay_enabled = false
	var offers0 := _offered.size()
	var met0 := _met.size()
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_frames(3)
	check(GameState.get_contract().is_empty() and _offered.size() == offers0 and hud.get_job_text() == "", "no job, no line")
	var before := GameState.money
	var value := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 1, GameState.get_sale_multiplier(), true)
	for i in 5:
		await _deposit(&"budget", true, BOB)
	check(GameState.money == before + 5 * value and _met.size() == met0 and GameState.get_stat(1, Const.STAT_CONTRACTS) == 0, "five cured bundles pay their own value and nothing else")
	GameState.time_left = 400.0
	await wait_frames(3)
	check(GameState.get_contract().is_empty(), "nothing appears at half time either")
	Config.lobby_enabled = true
	GameState.server_reset_game()
	await wait_frames(3)
	check(GameState.get_contract().is_empty() and _offered.size() == offers0, "nor in WAITING with the lobby on")
	Config.lobby_enabled = false
	Config.replay_enabled = true
	GameState.server_reset_game()
	await wait_frames(3)


# --- what travels -----------------------------------------------------------------------------------------------------

func _test_wire(b: BalanceConfig) -> void:
	step("late join: the job as a late joiner is sent it (direct RPC)")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	await wait_frames(2)
	var met0 := _met.size()
	var offers0 := _offered.size()
	var jobs0 := Career.get_record("contracts")
	var before := GameState.money
	toasts.clear()
	GameState._rpc_contract({"id": "cured", "text": "four cured bundles", "goal": 4, "progress": 4, "reward": 60, "done": true, "round": 1}, GameState.CONTRACT_EVENT_NONE)
	await wait_frames(1)
	var job := GameState.get_contract()
	check(bool(job["done"]) and int(job["progress"]) == 4 and hud.get_job_text() == "Job: four cured bundles 4 / 4 · paid" and hud.is_job_settled(), "a met job arrives as state: the HUD shows it paid")
	check(_met.size() == met0 and _offered.size() == offers0 and Career.get_record("contracts") == jobs0 and GameState.money == before and not toast_seen("Job done"),
			"no event rides on it: no toast, nothing paid, nothing on the record of somebody who was not there")
	GameState._rpc_contract({"id": 5, "text": "x".repeat(500) + "\n", "goal": -3, "progress": 99, "reward": -8, "done": 1, "strain": "y".repeat(90)}, GameState.CONTRACT_EVENT_NONE)
	job = GameState.get_contract()
	check(String(job["text"]).length() == Contracts.TEXT_MAX and int(job["goal"]) == 1 and int(job["progress"]) == 1 and int(job["reward"]) == 0 and String(job["strain"]).length() == 24,
			"garbage is clamped (text %d characters, goal %d, progress %d, reward %d)" % [String(job["text"]).length(), job["goal"], job["progress"], job["reward"]])
	GameState._rpc_contract({"text": "", "id": ""}, GameState.CONTRACT_EVENT_MET)
	check(GameState.get_contract().is_empty() and _met.size() == met0, "a job without an id or a text is no job, whatever event it claims")
	GameState._career_on_peer_registered(BOB)
	GameState._career_on_peer_registered(1)
	await wait_frames(1)
	GameState.server_set_contract(&"nothing")
	check(GameState.get_contract().is_empty(), "server_set_contract with an unknown id sets nothing (a warning)")
	_job(&"cured")
	check(not GameState.get_contract().is_empty(), "server_set_contract puts a job up")
	GameState.server_set_contract(&"")
	await wait_frames(1)
	check(GameState.get_contract().is_empty() and hud.get_job_text() == "", "and &\"\" takes it down")
	check(b.contract_reward > 0, "the reward is real money ($%d)" % b.contract_reward)

	step("titles on the wire")
	_title_signals = 0
	var counter := func() -> void: _title_signals += 1
	Net.titles_changed.connect(counter)
	check(Net.get_player_title(1) == "Tray hand", "the host's title: 'Tray hand'")
	Net._rpc_set_title("x".repeat(500))
	Net._rpc_set_title("[b]The Boss[/b]")
	Net._rpc_set_title("Shift lead\n")
	Net._rpc_set_title("")
	Net._rpc_set_title("new hire")
	check(Net.get_player_title(1) == "Tray hand" and _title_signals == 0, "strings that are not on the ladder are refused: the title stays")
	check(Net.sanitize_title("x".repeat(500)) == "" and Net.sanitize_title("Lead hand") == "Lead hand" and Net.sanitize_title("Lead hand ") == "", "sanitize_title: the ladder or nothing")
	Net._rpc_set_title("Lead hand")
	check(Net.get_player_title(1) == "Lead hand" and _title_signals == 1 and hud.get_title_text(1) == "Lead hand", "a ladder title is taken and shown")
	Net._rpc_set_title("Lead hand")
	check(_title_signals == 1, "the same title again is not sent round")
	Net._rpc_titles_sync({1: "Tray hand", BOB: "Floor hand", 7: "<nobody>", "x": "New hire", 9: 4, 11: "Shift lead"})
	check(Net.get_player_title(1) == "Tray hand" and Net.get_player_title(BOB) == "Floor hand" and Net.get_player_title(7) == "" and Net.get_player_title(11) == "",
			"a synced list is checked again: ladder titles of registered workers only")
	check(hud.get_title_text(BOB) == "Floor hand" and hud.get_title_text(1) == "Tray hand" and hud.player_list.get_child_count() == 4, "WORKERS: Bob has a title line now")
	var ladder: PackedStringArray = Career.get_titles()
	for i in Net.MAX_TITLE_CHANGES + 6:
		Net._rpc_set_title(ladder[i % 2])
	var stuck := Net.get_player_title(1)
	Net._rpc_set_title("Shift lead")
	check(_title_signals <= 2 + Net.MAX_TITLE_CHANGES and Net.get_player_title(1) == stuck,
			"a peer flipping its title is cut off after %d changes a session (%d went round)" % [Net.MAX_TITLE_CHANGES, _title_signals])
	Net.titles_changed.disconnect(counter)
	Net.server_send_titles(BOB)
	Net.server_send_titles(1)
	await wait_frames(1)


# --- the pause menu ---------------------------------------------------------------------------------------------------

func _test_pause_menu() -> void:
	step("pause menu: the Record card")
	var pm: PauseMenu = hud.pause_menu
	pm.open()
	await wait_sec(0.5) # pop-in over before measuring
	var texts := pm.get_record_texts()
	var lines: Array[String] = Career.get_summary_lines()
	check(pm.record_card.visible and texts.size() == lines.size() + 1 and texts[0] == Career.get_title(), "the title on top ('%s')" % (texts[0] if texts.size() > 0 else ""))
	var same := texts.size() == lines.size() + 1
	for i in lines.size():
		if same and texts[i + 1] != lines[i]:
			same = false
	check(same and lines.size() == 6, "then the %d lines of the record" % lines.size())
	var card_rect := pm.card.get_global_rect()
	var record_rect := pm.record_card.get_global_rect()
	var screen := get_viewport().get_visible_rect()
	check(screen.encloses(record_rect) and not card_rect.intersects(record_rect) and record_rect.position.x >= card_rect.end.x,
			"right of the ON BREAK card, on the screen (%s beside %s)" % [record_rect, card_rect])
	check(absf(record_rect.get_center().y - card_rect.get_center().y) < 2.0, "level with its middle")
	check(absf(card_rect.get_center().x - screen.get_center().x) < 1.0, "the ON BREAK card keeps its place")
	Config.replay_enabled = false
	pm.sync_record()
	check(not pm.record_card.visible and pm.get_record_texts().is_empty(), "replay off: no Record card")
	Config.replay_enabled = true
	pm.sync_record()
	pm.close()
	await wait_frames(2)


# --- helpers ----------------------------------------------------------------------------------------------------------

func _job(id: StringName, overrides: Dictionary = {}) -> void:
	GameState.server_set_contract(id, overrides)


## A bundle on the floor, sold through the chute's one sale path as if `seller` deposited it.
func _deposit(strain: StringName, cured: bool, seller: int) -> bool:
	var product := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": strain, "amount": 1, "cured": cured}, FAR_A + Vector3(1.0, 0.0, 0.0), 0)
	if product == null:
		return false
	var ok := chute.server_sell_item(product, seller)
	await wait_frames(1)
	return ok


## GrowPlot<i> made ready and harvested by `who` through the tray's server interaction; the bundle is thrown away.
func _harvest(i: int, who: Player) -> bool:
	var p := _plot(i)
	if p == null:
		return false
	if p.stage != GrowPlot.Stage.EMPTY:
		p.server_reset()
	p.server_plant(&"budget")
	p.server_water(1.0)
	p.stage = GrowPlot.Stage.READY
	var before := GameState.get_stat(who.peer_id, Const.STAT_HARVESTED)
	p._server_interact(who)
	await wait_frames(1)
	var held := items.get_held_by(who.peer_id)
	if held != null:
		items.server_despawn_item(held)
	await wait_frames(1)
	return GameState.get_stat(who.peer_id, Const.STAT_HARVESTED) == before + 1


## What the host's record must read once the running shift has ended (jobs are added by the caller).
func _expected_record(round_number: int, success: bool) -> Dictionary:
	return {
		"shifts": Career.get_record("shifts") + 1,
		"best_round": maxi(Career.get_record("best_round"), round_number) if success else Career.get_record("best_round"),
		"deposited": Career.get_record("deposited") + GameState.get_stat(1, Const.STAT_DEPOSITED),
		"contracts": Career.get_record("contracts"),
		"burns": Career.get_record("burns") + GameState.get_stat(1, Const.STAT_BURNS),
		"bitten": Career.get_record("bitten") + GameState.get_stat(1, Const.STAT_BITTEN),
		"shot": Career.get_record("shot") + GameState.get_stat(1, Const.STAT_SHOT),
	}


## The autoload's record AND the file (a second reader) hold `expect`.
func _check_record(expect: Dictionary, tag: String) -> void:
	var reader := _reader()
	var file_ok: bool = reader.load_file(_path)
	var memory_ok := true
	for key: String in expect:
		if Career.get_record(key) != int(expect[key]):
			memory_ok = false
		if reader.get_record(key) != int(expect[key]):
			file_ok = false
	check(memory_ok, "%s: the record has the host's own numbers %s" % [tag, expect])
	check(file_ok and reader.get_strain_deposits() == Career.get_strain_deposits() and reader.get_summary_lines() == Career.get_summary_lines() and reader.get_title() == Career.get_title(),
			"%s: the file was written and a second reader sees the same" % tag)
	reader.free()


func _reader() -> Node:
	var script: GDScript = load(CAREER_SCRIPT)
	return script.new()


func _temp(tag: String) -> String:
	var p := "%s.%s" % [_path, tag]
	_temp_files.append(p)
	return p


func _write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _write_bytes(p: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_buffer(bytes)
	f.close()


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	for p in _temp_files:
		_remove(p)
		_remove(p + ".tmp")
	_remove(_path)
	_remove(_path + ".tmp")


func _plot(i: int) -> GrowPlot:
	return room.get_station("GrowPlot%d" % i) as GrowPlot


## Places a fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func _put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func _put_me(pos: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.05, pos.z)


func _flat(a: Vector3, c: Vector3) -> float:
	return Vector2(a.x - c.x, a.z - c.z).length()


## The floor point `metres` down the lane.
func _at(from: Vector3, end: Vector3, metres: float) -> Vector3:
	var d := Vector3(end.x - from.x, 0.0, end.z - from.z).normalized()
	return Vector3(from.x, 0.0, from.z) + d * metres


## Where a lane stops: its first LAYER_WORLD hit, or its end.
func _lane_end(lane: Dictionary) -> Vector3:
	var space := world.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(lane["from"], lane["to"], Const.LAYER_WORLD))
	return hit["position"] if not hit.is_empty() else lane["to"]


## The index of the lane with the longest open stretch.
func _open_lane(lanes: Array) -> int:
	var best := 0
	var open := -1.0
	for i in lanes.size():
		var l: Dictionary = lanes[i]
		var d := _flat(l["from"], _lane_end(l))
		if d > open:
			open = d
			best = i
	return best


## Up to `count` floor points inside the main room at least 2 m (flat) from every lane and 1.5 m from each other.
func _safe_spots(lanes: Array, count: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var bounds := room.get_bounds()
	var x := bounds.position.x + 1.0
	while x < bounds.end.x - 0.9 and out.size() < count:
		var z := bounds.position.z + 3.5
		while z < bounds.end.z - 0.9 and out.size() < count:
			var p := Vector3(x, 0.0, z)
			var ok := true
			for l: Dictionary in lanes:
				var near: Vector3 = Events._lane_closest(l["from"], l["to"], p)
				if _flat(near, p) < 2.0:
					ok = false
			for o in out:
				if _flat(o, p) < 1.5:
					ok = false
			if ok:
				out.append(p)
			z += 0.5
		x += 0.5
	return out
