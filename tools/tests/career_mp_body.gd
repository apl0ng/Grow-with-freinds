extends "res://tools/tests/qa_net_base.gd"
## M15 career multi-process body (career agent). Driven by tools/tests/career_mp.sh; every process runs this script
## with --replay and its OWN --career-file (a temp file under user://, removed at the end):
##   --role=host                 the director (real Game.start_host): puts the job up, hands out bundles, ends the shift
##   --role=client --who=a       Alpha: joins at once, with a career already on file ("Lead hand")
##   --role=client --who=b       Bravo: joins in the middle of the shift (the late joiner), nothing on file ("New hire")
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: titles (each peer's own title reaches every peer and the WORKERS list; a hostile string sent
## by a client is refused; a late joiner gets everyone's; a title that moves up after a shift moves on every peer);
## the job (the same job and progress on every peer; a client's cured deposit through the real chute RPC advances it
## and a wet one does not; the late joiner gets the job as it stands, without an event; met: every peer present sees
## contract_met once, the toast, the same cash on hand, the HUD line paid); the record (each peer's file holds its
## own deposits, strains, back-room visits and the floor's job, and a second reader on the file agrees).

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const CAREER_SCRIPT := "res://scripts/core/career.gd"
## Alpha's record before this run.
const SEED_A := "[career]\nshifts=5\nbest_round=3\ndeposited=1000\ncontracts=2\nburns=1\nbitten=0\nshot=0\nbackroom=0\n\n[strains]\npurple=4\n"

var role: String = "host"
var who: String = ""
var port: int = 7986
var _ids: Dictionary = {}
var _path: String = ""
var _met: Array = []
var _failed: Array = []
var _offered: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7986))
	_label = "career_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent and Config.replay_enabled,
			"own career file (%s), replay on" % _path):
		finish(); return
	# A file left by a broken run is not this run's record.
	_remove(_path)
	if who == "a":
		_write_text(_path, SEED_A)
	Career.clear_record()
	Career.load_file(_path)
	GameState.contract_met.connect(func(c: Dictionary) -> void: _met.append(c))
	GameState.contract_failed.connect(func(c: Dictionary) -> void: _failed.append(c))
	GameState.contract_offered.connect(func(c: Dictionary, swapped: bool) -> void: _offered.append([c, swapped]))
	if role == "host":
		await _host_main()
	else:
		await _client_main()
	_remove(_path)
	_remove(_path + ".tmp")
	finish()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("CAREER_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	var items := Game.world.items
	var chute: TurnInStation = station("TurnInStation")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(6.0, 0.02, 5.0)

	step("titles: each peer's own title reaches everyone")
	check(await wait_until_quiet(func() -> bool: return Net.get_player_title(a) == "Lead hand", 8.0) and Net.get_player_title(1) == "New hire",
			"host: Alpha is a 'Lead hand' (best shift 3 on file), the host a 'New hire'")
	check(hud.get_title_text(a) == "Lead hand" and hud.get_title_text(1) == "New hire", "host: both titles in the WORKERS list")
	var r := await run_cmd(a, "report", {"titles": {1: "New hire", a: "Lead hand"}})
	check(bool(r.get("ok", false)), "Alpha sees both titles %s, in its WORKERS list too %s" % [r.get("titles"), r.get("hud_titles")])
	check(String(r.get("title", "")) == "Lead hand" and int((r.get("record", {}) as Dictionary).get("shifts", 0)) == 5, "Alpha's own record is the one on its file")

	step("titles: a hostile string from a client is refused")
	r = await run_cmd(a, "bad_title")
	check(Net.get_player_title(a) == "Lead hand" and hud.get_title_text(a) == "Lead hand", "host: Alpha is still a 'Lead hand' after %d bad strings" % int(r.get("sent", 0)))
	r = await run_cmd(a, "report", {"titles": {1: "New hire", a: "Lead hand"}})
	check(bool(r.get("ok", false)), "Alpha's list is unchanged as well")

	step("the job: the same on every peer")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_frames(2)
	check(not GameState.get_contract().is_empty(), "host: a job was rolled when the shift started ('%s')" % GameState.get_contract().get("id", ""))
	r = await run_cmd(a, "report", {"id": String(GameState.get_contract()["id"])})
	check(bool(r.get("ok", false)) and r.get("job") == GameState.get_contract(), "Alpha has the same job %s" % [r.get("job")])
	check(int(r.get("offered", 0)) == 1 and _has_toast(r.get("toasts", []), "Job: "), "Alpha heard it offered once, with the toast")
	GameState.server_set_contract(&"cured")
	var job := GameState.get_contract()
	check(String(job["text"]) == "four cured bundles" and int(job["goal"]) == 4, "host: the job is now '%s'" % job["text"])
	r = await run_cmd(a, "report", {"id": "cured"})
	check(r.get("job") == job and String(r.get("hud", "")) == "Job: four cured bundles 0 / 4", "Alpha: '%s'" % r.get("hud", ""))

	step("the job: a client's cured deposit advances it, a wet one does not")
	var money0 := GameState.money
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "purple", "amount": 1, "cured": true}, Vector3.ZERO, a)
	r = await run_cmd(a, "sell", {}, 30.0)
	check(bool(r.get("sold", false)) and String(r.get("prompt", "")).contains("cured"), "Alpha deposits a cured Purple Haze bundle through the chute ('%s')" % r.get("prompt", ""))
	var cured_value := TurnInStation.compute_sale_value(b.get_seed(&"purple"), 1, GameState.get_sale_multiplier(), true)
	check(int(GameState.get_contract()["progress"]) == 1 and GameState.money == money0 + cured_value, "host: 1 / 4, $%d deposited" % cured_value)
	r = await run_cmd(a, "report", {"progress": 1})
	check(bool(r.get("ok", false)) and String(r.get("hud", "")) == "Job: four cured bundles 1 / 4", "Alpha: '%s'" % r.get("hud", ""))
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1}, Vector3.ZERO, a)
	r = await run_cmd(a, "sell", {}, 30.0)
	check(bool(r.get("sold", false)) and int(GameState.get_contract()["progress"]) == 1, "a wet Budget Bud bundle: deposited, still 1 / 4")

	step("the late joiner gets the job and the titles")
	print("CAREER_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered (mid-shift)"):
		return
	_ids["b"] = _peer_named("b")
	var bp: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bp) != null, 10.0, "Bravo's Player node exists")
	check(await wait_until_quiet(func() -> bool: return Net.get_player_title(bp) == "New hire", 8.0), "host: Bravo is a 'New hire'")
	var all_titles := {1: "New hire", a: "Lead hand", bp: "New hire"}
	r = await run_cmd(bp, "report", {"titles": all_titles, "progress": 1})
	check(bool(r.get("ok", false)) and r.get("job") == GameState.get_contract(), "Bravo has the job as it stands: %s" % [r.get("job")])
	check(String(r.get("hud", "")) == "Job: four cured bundles 1 / 4", "Bravo's HUD: '%s'" % r.get("hud", ""))
	check(int(r.get("offered", -1)) == 0 and int(r.get("met", -1)) == 0 and not _has_toast(r.get("toasts", []), "Job"), "it arrived as state: no offer, no toast")
	check(r.get("titles") == all_titles and r.get("hud_titles") == all_titles, "Bravo sees everyone's title %s" % [r.get("titles")])
	r = await run_cmd(a, "report", {"titles": all_titles})
	check(bool(r.get("ok", false)), "Alpha sees Bravo's title")
	check(hud.get_title_text(bp) == "New hire", "host: Bravo's title in the WORKERS list")

	step("the job: met, on every peer")
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1, "cured": true}, Vector3.ZERO, bp)
	r = await run_cmd(bp, "sell", {}, 30.0)
	check(bool(r.get("sold", false)) and int(GameState.get_contract()["progress"]) == 2, "Bravo deposits a cured bundle: 2 / 4")
	items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1, "cured": true}, Vector3.ZERO, a)
	r = await run_cmd(a, "sell", {}, 30.0)
	check(bool(r.get("sold", false)) and int(GameState.get_contract()["progress"]) == 3, "Alpha another: 3 / 4")
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"progress": 3})
		check(bool(r.get("ok", false)) and String(r.get("hud", "")) == "Job: four cured bundles 3 / 4" and int(r.get("met", -1)) == 0, "%s: 3 / 4, not paid yet" % NAMES[key])
	var before := GameState.money
	var mine := items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": "budget", "amount": 1, "cured": true}, Vector3(5.0, 0.3, 5.0), 0)
	check(chute.server_sell_item(mine, 1), "the host deposits the fourth")
	await wait_frames(2)
	var budget_cured := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 1, GameState.get_sale_multiplier(), true)
	var budget_wet := TurnInStation.compute_sale_value(b.get_seed(&"budget"), 1, GameState.get_sale_multiplier(), false)
	job = GameState.get_contract()
	check(bool(job["done"]) and _met.size() == 1 and GameState.money == before + budget_cured + b.contract_reward, "host: met, $%d into cash on hand" % b.contract_reward)
	check(GameState.get_stat(1, Const.STAT_CONTRACTS) == 1, "host: STAT_CONTRACTS 1 for the floor")
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"done": true})
		check(bool(r.get("ok", false)) and r.get("job") == job and int(r.get("met", 0)) == 1, "%s: the job is met, contract_met once" % NAMES[key])
		check(int(r.get("money", -1)) == GameState.money and String(r.get("hud", "")) == "Job: four cured bundles 4 / 4 · paid" and bool(r.get("settled", false)),
				"%s: the same cash on hand ($%s), the line paid and dimmed" % [NAMES[key], r.get("money")])
		check(_has_toast(r.get("toasts", []), "Job done: four cured bundles. $%d to cash on hand." % b.contract_reward), "%s: the toast" % NAMES[key])
		check(int(r.get("floor_contracts", -1)) == 1, "%s: sees the floor's STAT_CONTRACTS" % NAMES[key])

	step("the shift ends: each peer's file holds its own numbers")
	GameState.server_add_stat(a, Const.STAT_BITTEN, 2)
	check(GameState.server_send_to_backroom(bp, 2.0), "Bravo is sent to the back room")
	await wait_until(func() -> bool: return not GameState.is_in_backroom(bp), 3.0 + 4.0, "and let out")
	GameState.server_add_sale(GameState.quota, 1)
	await wait_frames(2)
	var stats := {}
	for id: int in [1, a, bp]:
		stats[id] = {"deposited": GameState.get_stat(id, Const.STAT_DEPOSITED), "bitten": GameState.get_stat(id, Const.STAT_BITTEN)}
	check(int(stats[a]["deposited"]) == cured_value + budget_wet + budget_cured and int(stats[bp]["deposited"]) == budget_cured, "the ledger: Alpha $%d, Bravo $%d, the host $%d" % [stats[a]["deposited"], stats[bp]["deposited"], stats[1]["deposited"]])
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift ends, payment made")
	await wait_frames(3)
	_check_own_record({"shifts": 1, "best_round": 1, "deposited": int(stats[1]["deposited"]), "contracts": 1, "bitten": 0, "backroom": 0, "budget": 1, "purple": 0}, "host")
	r = await run_cmd(a, "report", {"phase": GameState.Phase.ROUND_SUCCESS, "shifts": 6})
	_check_remote_record(r, {"shifts": 6, "best_round": 3, "deposited": 1000 + int(stats[a]["deposited"]), "contracts": 3, "burns": 1, "bitten": 2, "backroom": 0, "purple": 5, "budget": 2}, "Alpha")
	check(String(r.get("report_job", "")) == "Job: four cured bundles. Done. %s paid." % HUD.format_money(b.contract_reward), "Alpha's shift report: '%s'" % r.get("report_job", ""))
	r = await run_cmd(bp, "report", {"phase": GameState.Phase.ROUND_SUCCESS, "shifts": 1})
	_check_remote_record(r, {"shifts": 1, "best_round": 1, "deposited": int(stats[bp]["deposited"]), "contracts": 1, "burns": 0, "bitten": 0, "backroom": 1, "purple": 0, "budget": 1}, "Bravo")

	step("titles move up after the shift, on every peer")
	all_titles = {1: "Floor hand", a: "Lead hand", bp: "Floor hand"}
	check(await wait_until_quiet(func() -> bool: return Net.get_player_title(bp) == "Floor hand" and Net.get_player_title(1) == "Floor hand", 8.0),
			"host: the host and Bravo are 'Floor hand' now (best shift 1), Alpha stays 'Lead hand'")
	check(hud.get_title_text(bp) == "Floor hand" and hud.get_title_text(1) == "Floor hand" and hud.get_title_text(a) == "Lead hand", "host: WORKERS list follows")
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"titles": all_titles})
		check(bool(r.get("ok", false)) and r.get("hud_titles") == all_titles, "%s sees the new titles %s" % [NAMES[key], r.get("titles")])

	step("the next shift: a new job for everyone")
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == 2, 3.0, "shift 2 running")
	await wait_frames(2)
	job = GameState.get_contract()
	check(not job.is_empty() and int(job["round"]) == 2 and String(job["id"]) != "cured" and not bool(job["done"]), "host: rolled for shift 2 ('%s')" % job.get("id", ""))
	for key in ["a", "b"]:
		r = await run_cmd(_ids[key], "report", {"id": String(job["id"]), "round": 2})
		check(bool(r.get("ok", false)) and r.get("job") == job and String(r.get("hud", "")) == Contracts.hud_text(job), "%s has it: '%s'" % [NAMES[key], r.get("hud", "")])

	step("finish")
	allow_error("Unable to send packet on channel 0", 6, true)
	cmd(a, "finish")
	cmd(bp, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bp), 20.0, "both clients left")


## The host's own record, in memory and on its file.
func _check_own_record(expect: Dictionary, tag: String) -> void:
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	var file_ok: bool = reader.load_file(_path)
	var memory_ok := true
	for key: String in expect:
		if Career.get_record(key) != int(expect[key]):
			memory_ok = false
		if reader.get_record(key) != int(expect[key]):
			file_ok = false
	check(memory_ok and file_ok, "%s: its record and its file hold its own numbers %s" % [tag, expect])
	reader.free()


## A client's report: its record in memory and what a second reader found on its file.
func _check_remote_record(r: Dictionary, expect: Dictionary, tag: String) -> void:
	var record: Dictionary = r.get("record", {})
	var file: Dictionary = r.get("file", {})
	var memory_ok := bool(r.get("ok", false))
	var file_ok := bool(r.get("file_read", false))
	for key: String in expect:
		if int(record.get(key, -1)) != int(expect[key]):
			memory_ok = false
		if int(file.get(key, -1)) != int(expect[key]):
			file_ok = false
	check(memory_ok, "%s: its record holds its own numbers %s (got %s)" % [tag, expect, record])
	check(file_ok, "%s: and so does its file (a second reader: %s)" % [tag, file])


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


static func _has_toast(list: Variant, substring: String) -> bool:
	if not (list is Array):
		return false
	for t in list:
		if String(t).contains(substring):
			return true
	return false


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if who == "a":
		check(Career.get_title() == "Lead hand" and Career.get_record("shifts") == 5, "Alpha starts with a career on file")
	else:
		check(Career.get_title() == "New hire" and Career.get_summary_lines().is_empty(), "%s starts with nothing on file" % my_name)
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		return
	await client_loop()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	match action:
		"report":
			var ok := await wait_until_quiet(func() -> bool: return _report_ready(args), float(args.get("timeout", 8.0)))
			ack(seq, _report(ok))
		"sell":
			var chute: TurnInStation = station("TurnInStation")
			var out := {"prompt": "", "sold": false}
			await wait_until_quiet(func() -> bool: return me.get_held_item() != null, 8.0)
			var bundle := me.get_held_item()
			if chute != null and bundle != null:
				stand_near(chute, 1.3)
				await server_sees_me()
				out["prompt"] = chute.get_prompt(me)
				chute.interact(me)
				out["sold"] = await wait_until_quiet(func() -> bool: return not is_instance_valid(bundle) or bundle.is_queued_for_deletion() or not bundle.is_inside_tree(), 8.0)
				await sync_with_host()
				await wait_frames(2)
			check(bool(out["sold"]), "deposited through the chute")
			ack(seq, out)
		"bad_title":
			var bad := ["x".repeat(4000), "[b]The Boss[/b]", "Shift lead\n", "floor hand", "The Boss", ""]
			for text: String in bad:
				Net._rpc_set_title.rpc_id(1, text)
			await sync_with_host()
			ack(seq, {"sent": bad.size()})
		"finish":
			_remove(_path)
			_remove(_path + ".tmp")
			await super(seq, action, args)
		_:
			await super(seq, action, args)


## The conditions a "report" waits for (all optional): id, round, progress, done, phase, shifts, titles {peer: title}.
func _report_ready(args: Dictionary) -> bool:
	var job := GameState.get_contract()
	if args.has("id") and String(job.get("id", "")) != String(args["id"]):
		return false
	if args.has("round") and int(job.get("round", 0)) != int(args["round"]):
		return false
	if args.has("progress") and int(job.get("progress", -1)) != int(args["progress"]):
		return false
	if args.has("done") and bool(job.get("done", false)) != bool(args["done"]):
		return false
	if args.has("phase") and GameState.phase != int(args["phase"]):
		return false
	if args.has("shifts") and Career.get_record("shifts") != int(args["shifts"]):
		return false
	if args.has("titles"):
		var hud: HUD = Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
		var want: Dictionary = args["titles"]
		for id: Variant in want:
			if Net.get_player_title(int(id)) != String(want[id]):
				return false
			if hud == null or hud.get_title_text(int(id)) != String(want[id]):
				return false
	return true


func _report(ok: bool) -> Dictionary:
	var hud: HUD = Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
	var titles := {}
	var hud_titles := {}
	for id in Net.get_peer_ids():
		titles[id] = Net.get_player_title(id)
		hud_titles[id] = hud.get_title_text(id) if hud != null else ""
	var keys: Array[String] = ["shifts", "best_round", "deposited", "contracts", "burns", "bitten", "shot", "backroom", "budget", "purple"]
	var record := {}
	var file := {}
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	var file_read: bool = reader.load_file(_path)
	for key in keys:
		record[key] = Career.get_record(key)
		file[key] = reader.get_record(key)
	reader.free()
	var job_toasts := []
	for t in toasts:
		if String(t[0]).begins_with("Job"):
			job_toasts.append(String(t[0]))
	return {
		"ok": ok, "job": GameState.get_contract(), "hud": hud.get_job_text() if hud != null else "", "settled": hud != null and hud.is_job_settled(),
		"titles": titles, "hud_titles": hud_titles, "title": Career.get_title(), "met": _met.size(), "offered": _offered.size(), "failed": _failed.size(),
		"toasts": job_toasts, "money": GameState.money, "floor_contracts": GameState.get_stat(1, Const.STAT_CONTRACTS),
		"record": record, "file": file, "file_read": file_read, "lines": Career.get_summary_lines(),
		"report_job": hud.round_end.report.get_job_text() if hud != null else "",
	}


func _write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
