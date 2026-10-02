extends "res://tools/tests/qa_net_base.gd"
## M16 hats multi-process body (hats agent). Driven by tools/tests/hats_mp.sh; every process runs this script with
## --replay --lobby and its OWN --career-file (a temp file under user://, removed at the end):
##   --role=host                 the director (real Game.start_host), a record on file: hairnet, cone, bucket; bucket on
##   --role=client --who=a       Alpha: joins at once; on file: hairnet, yellow hard hat, cone; the cone on
##   --role=client --who=b       Bravo: joins late, nothing on file (nothing issued)
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: each peer's own hat reaches every peer and sits on that worker's body there (the own body
## shadow-only, the others drawn; the stock hard hat hidden under it); hostile strings from a client are refused and
## the old hat stays; any catalog id is taken; a client's locker changes its own hat for everyone and in its own
## file; the late joiner gets everyone's hats and has none; the end of a shift issues from each peer's own record
## (the toast only where it applies); the budget: a client's locker jams when the host would take no more, and what
## it wears stays what everyone sees; a worker who leaves takes his hat with him.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const CAREER_SCRIPT := "res://scripts/core/career.gd"
const SEED_HOST := "[career]\nshifts=9\nbest_round=2\ndeposited=1000\ncontracts=0\nburns=0\nbitten=5\nshot=0\nbackroom=3\nhat=bucket\n"
const SEED_A := "[career]\nshifts=5\nbest_round=3\ndeposited=900\ncontracts=1\nburns=0\nbitten=0\nshot=0\nbackroom=3\nhat=cone\n"

var role: String = "host"
var who: String = ""
var port: int = 7988
var _ids: Dictionary = {}
var _path: String = ""
var _issued: Array = []
var _used: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7988))
	_label = "hats_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path and Career.persistent and Config.replay_enabled and Config.lobby_enabled,
			"own career file (%s), replay and the lobby on" % _path):
		finish(); return
	# A file left by a broken run is not this run's record.
	_remove(_path)
	if role == "host":
		_write_text(_path, SEED_HOST)
	elif who == "a":
		_write_text(_path, SEED_A)
	Career.clear_record()
	Career.load_file(_path)
	Career.hat_issued.connect(func(id: StringName) -> void: _issued.append(String(id)))
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
	check(Career.get_hat() == &"bucket" and Career.get_issued_hats().size() == 3, "the host starts with a record on file: three hats, the bucket on")
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null and Game.world != null and Game.world.lobby != null, 10.0, "host world ready")
	print("HATS_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var locker := Game.world.lobby.get_locker()
	var me: Player = Game.local_player

	step("each peer's own hat reaches everyone")
	check(await wait_until_quiet(func() -> bool: return Net.get_player_hat(a) == &"cone" and _worn(a) == "cone", 8.0) and Net.get_player_hat(1) == &"bucket",
			"host: Alpha wears the cone (on file), the host the bucket: %s" % [Net.hats])
	check(_worn(1) == "bucket" and _own_hidden() and _drawn(a), "host: its own bucket is shadow-only, Alpha's cone is drawn on Alpha's head")
	var r := await run_cmd(a, "report", {"hats": {1: "bucket", a: "cone"}})
	check(bool(r.get("ok", false)) and r.get("bodies") == {1: "bucket", a: "cone"}, "Alpha sees both, on both bodies %s" % [r.get("bodies")])
	check(bool(r.get("own_hidden", false)) and bool(r.get("others_drawn", false)), "Alpha: its own cone is shadow-only, the host's bucket is drawn")
	check(String(r.get("prompt", "")) == "Locker · traffic cone" and String(r.get("hat", "")) == "cone", "Alpha's locker: '%s'" % r.get("prompt", ""))

	step("a hostile string from a client is refused")
	r = await run_cmd(a, "bad_hat")
	check(Net.get_player_hat(a) == &"cone" and _worn(a) == "cone", "host: Alpha still wears the cone after %d bad strings" % int(r.get("sent", 0)))
	r = await run_cmd(a, "report", {"hats": {1: "bucket", a: "cone"}})
	check(bool(r.get("ok", false)), "Alpha's list is unchanged as well")

	step("the locker, on a client")
	r = await run_cmd(a, "locker", {"presses": 2})
	check(bool(r.get("found", false)) and r.get("used") == ["", "hairnet"] and String(r.get("hat", "")) == "hairnet", "Alpha presses E twice: none, then the hairnet %s" % [r.get("used")])
	check(String(r.get("prompt", "")) == "Locker · hairnet" and String(r.get("file_hat", "")) == "hairnet", "its prompt and its own file follow ('%s')" % r.get("prompt", ""))
	check(await wait_until_quiet(func() -> bool: return Net.get_player_hat(a) == &"hairnet" and _worn(a) == "hairnet", 8.0), "host: Alpha wears the hairnet")
	check(Career.get_hat() == &"bucket" and _worn(1) == "bucket", "the host's own hat is untouched")
	if locker != null:
		check(absf(locker.get_door().rotation.y - deg_to_rad(Locker.DOOR_AJAR_DEG)) < 0.001, "the locker did nothing on the host: it is the client's own")

	step("the late joiner gets everyone's hats")
	print("HATS_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		return
	_ids["b"] = _peer_named("b")
	var bp: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bp) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bp, "report", {"hats": {1: "bucket", a: "hairnet", bp: ""}})
	check(bool(r.get("ok", false)) and r.get("bodies") == {1: "bucket", a: "hairnet", bp: ""}, "Bravo sees the bucket and the hairnet and wears nothing %s" % [r.get("bodies")])
	check(bool(r.get("others_drawn", false)) and String(r.get("prompt", "")) == "Locker · nothing issued", "Bravo's locker: '%s'" % r.get("prompt", ""))
	check(Net.get_player_hat(bp) == &"" and _worn(bp) == "" and _stock_shown(bp), "host: Bravo is in the stock hard hat")
	r = await run_cmd(a, "report", {"hats": {1: "bucket", a: "hairnet", bp: ""}})
	check(bool(r.get("ok", false)), "Alpha sees the same three")

	step("any catalog id is taken: the host cannot see a record")
	r = await run_cmd(bp, "raw_hat", {"id": "welding_mask"})
	check(await wait_until_quiet(func() -> bool: return Net.get_player_hat(bp) == &"welding_mask" and _worn(bp) == "welding_mask", 8.0), "host: Bravo wears a welding mask its record never issued")
	r = await run_cmd(a, "report", {"hats": {1: "bucket", a: "hairnet", bp: "welding_mask"}})
	check(bool(r.get("ok", false)) and bool(r.get("others_drawn", false)), "Alpha sees it too")
	r = await run_cmd(bp, "raw_hat", {"id": ""})
	check(await wait_until_quiet(func() -> bool: return Net.get_player_hat(bp) == &"" and _worn(bp) == "" and _stock_shown(bp), 8.0), "and \"\" takes it off again")

	step("a shift: each peer's own record issues")
	GameState.request_start_round()
	if not await wait_until(func() -> bool: return GameState.is_playing(), b.transition_fade_sec + 3.0, "host: PLAYING"):
		return
	await wait_frames(3)
	check(_worn(a) == "hairnet" and _worn(1) == "bucket", "host: the hats came along on the ride")
	GameState.server_add_sale(GameState.quota, 1)
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_SUCCESS, 3.0, "the shift ends, payment made")
	await wait_frames(3)
	check(Career.get_record("shifts") == 10 and _issued == ["paper_cap"] and toast_seen("Issued: paper cap. It is in your locker."), "host: ten shifts, the paper cap is issued, with the toast")
	r = await run_cmd(bp, "report", {"phase": GameState.Phase.ROUND_SUCCESS, "shifts": 1})
	check(bool(r.get("ok", false)) and r.get("issued") == ["hairnet"] and r.get("toasts") == ["Issued: hairnet. It is in your locker."], "Bravo: its first shift issues the hairnet, with its own toast %s" % [r.get("toasts")])
	r = await run_cmd(a, "report", {"phase": GameState.Phase.ROUND_SUCCESS, "shifts": 6})
	check(bool(r.get("ok", false)) and r.get("issued") == [] and r.get("toasts") == [], "Alpha: six shifts issue nothing, no toast")
	check(Net.hats == {1: "bucket", a: "hairnet"}, "nobody's hat changed by itself %s" % [Net.hats])
	GameState.request_next_round()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, b.transition_fade_sec + 3.0, "host: NEXT SHIFT, WAITING in the alley")
	r = await run_cmd(bp, "locker", {"presses": 1}, 30.0)
	check(bool(r.get("found", false)) and r.get("used") == ["hairnet"] and String(r.get("prompt", "")) == "Locker · hairnet", "Bravo's locker has the hairnet now: '%s'" % r.get("prompt", ""))
	check(await wait_until_quiet(func() -> bool: return Net.get_player_hat(bp) == &"hairnet" and _worn(bp) == "hairnet", 8.0), "host: Bravo wears it")
	r = await run_cmd(a, "report", {"hats": {1: "bucket", a: "hairnet", bp: "hairnet"}})
	check(bool(r.get("ok", false)), "Alpha sees Bravo's hairnet")

	step("the budget, on a client")
	r = await run_cmd(a, "spam", {}, 40.0)
	var stuck := String(r.get("hat", "?"))
	check(int(r.get("presses", 0)) > 0 and int(r.get("left", -1)) == 0 and String(r.get("prompt", "")) == "Locker · jammed" and bool(r.get("refused", false)),
			"Alpha's locker jams after %d more presses; Career refuses the next change" % int(r.get("presses", 0)))
	check(await wait_until_quiet(func() -> bool: return String(Net.get_player_hat(a)) == stuck and _worn(a) == stuck, 8.0) and int(Net._hat_changes.get(a, 0)) == Net.MAX_HAT_CHANGES,
			"host: took %d changes from Alpha; it wears what Alpha thinks it wears ('%s')" % [Net.MAX_HAT_CHANGES, stuck])
	var other := "cone" if stuck != "cone" else "hairnet"
	r = await run_cmd(a, "raw_hat", {"id": other})
	check(String(Net.get_player_hat(a)) == stuck and _worn(a) == stuck, "host: a change past the cap is dropped")
	r = await run_cmd(bp, "report", {"hats": {1: "bucket", a: stuck, bp: "hairnet"}})
	check(bool(r.get("ok", false)), "Bravo agrees")

	step("a worker who leaves takes his hat with him")
	allow_error("Unable to send packet on channel 0", 6, true)
	cmd(a, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a), 20.0, "Alpha left")
	check(Net.get_player_hat(a) == &"" and Game.world.get_player(a) == null, "host: no hat for a worker who is not here")
	check(locker != null and locker.use() == &"" and Career.get_hat() == &"", "the host takes its own hat off at the locker")
	await wait_frames(2)
	check(not Net.hats.has(a) and Net.hats == {bp: "hairnet"}, "the list that goes round has only who is here %s" % [Net.hats])
	r = await run_cmd(bp, "report", {"hats": {1: "", bp: "hairnet"}, "gone": a})
	check(bool(r.get("ok", false)) and r.get("bodies") == {1: "", bp: "hairnet"}, "Bravo: the host in the stock hat, itself in the hairnet, no Alpha %s" % [r.get("bodies")])
	check(_stock_shown(1) and me.get_hat_node() == null, "host: its stock hard hat is back")

	step("finish")
	cmd(bp, "finish")
	await wait_until(func() -> bool: return not Net.players.has(bp), 20.0, "Bravo left")


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


## The hat on `peer`'s body on this peer ("?" without a body).
func _worn(peer: int) -> String:
	var p: Player = Game.world.get_player(peer) if Game.world != null else null
	return String(p.get_hat()) if p != null else "?"


func _stock_shown(peer: int) -> bool:
	var p: Player = Game.world.get_player(peer) if Game.world != null else null
	var stock := p.get_node_or_null(Player.STOCK_HAT_PATH) as Node3D if p != null else null
	return stock != null and stock.visible


## Every mesh of the local worker's own body, the hat and its outline too, is shadow-only.
func _own_hidden() -> bool:
	var me: Player = Game.local_player
	if me == null:
		return false
	for n in me.get_node(^"Visual").find_children("*", "GeometryInstance3D", true, false):
		if (n as GeometryInstance3D).cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			return false
	return true


## `peer`'s hat is a model on that body's head socket with at least one mesh this peer draws, the stock hat hidden.
func _drawn(peer: int) -> bool:
	var p: Player = Game.world.get_player(peer) if Game.world != null else null
	if p == null or p.get_hat_node() == null or p.get_hat_node().get_parent() != p.get_node_or_null(Player.HAT_SOCKET_PATH) or _stock_shown(peer):
		return false
	for n in p.get_hat_node().find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if not mi.has_meta(&"toonify_outline") and mi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
			return true
	return false


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if who == "a":
		check(Career.get_hat() == &"cone" and Career.get_issued_hats().size() == 3, "Alpha starts with three hats on file, the cone on")
	else:
		check(Career.get_hat() == &"" and Career.get_issued_hats().is_empty(), "%s starts with nothing issued" % my_name)
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
		"bad_hat":
			var bad := ["x".repeat(4000), "CONE", "cone ", "cone\n", "crown", "res://art/models/hat_cone.glb", "[b]cone[/b]", "hat_cone"]
			for text: String in bad:
				Net._rpc_set_hat.rpc_id(1, text)
			await sync_with_host()
			ack(seq, {"sent": bad.size()})
		"raw_hat":
			Net._rpc_set_hat.rpc_id(1, String(args.get("id", "")))
			await sync_with_host()
			ack(seq, {"ok": true})
		"locker":
			var locker := Game.world.lobby.get_locker() if Game.world != null and Game.world.lobby != null else null
			var out := {"found": false, "used": [], "hat": "?", "prompt": "", "file_hat": "?"}
			if locker != null and me != null:
				await wait_until_quiet(func() -> bool: return GameState.phase == GameState.Phase.WAITING and not GameState.is_transitioning() and Game.world.lobby.is_in_use(), 10.0)
				_used.clear()
				var note := func(id: StringName) -> void: _used.append(String(id))
				locker.used.connect(note)
				stand_near(locker, 1.4)
				await get_tree().physics_frame
				await get_tree().physics_frame
				me.get_interactor().refresh()
				out["found"] = me.get_interactor().current_target == locker
				for i in int(args.get("presses", 1)):
					locker.interact(me)
				locker.used.disconnect(note)
				await sync_with_host()
				out["used"] = _used.duplicate()
				out["hat"] = String(Career.get_hat())
				out["prompt"] = locker.get_prompt(me)
				out["file_hat"] = _file_hat()
			check(bool(out["found"]), "the locker is under the crosshair")
			ack(seq, out)
		"spam":
			var locker := Game.world.lobby.get_locker()
			var presses := 0
			while locker.can_interact(me) and presses < 200:
				locker.interact(me)
				presses += 1
			var before: StringName = Career.get_hat()
			var refused: bool = not Career.set_hat(&"" if before != &"" else &"hairnet") and Career.get_hat() == before
			await sync_with_host()
			ack(seq, {"presses": presses, "hat": String(Career.get_hat()), "left": Career.get_hat_changes_left(), "prompt": locker.get_prompt(me), "refused": refused})
		"finish":
			_remove(_path)
			_remove(_path + ".tmp")
			await super(seq, action, args)
		_:
			await super(seq, action, args)


## The conditions a "report" waits for (all optional): hats {peer: id} (the list AND the bodies), phase, shifts, gone.
func _report_ready(args: Dictionary) -> bool:
	if args.has("phase") and GameState.phase != int(args["phase"]):
		return false
	if args.has("shifts") and Career.get_record("shifts") != int(args["shifts"]):
		return false
	if args.has("gone") and (Net.players.has(int(args["gone"])) or Game.world.get_player(int(args["gone"])) != null):
		return false
	if args.has("hats"):
		var want: Dictionary = args["hats"]
		for id: Variant in want:
			if String(Net.get_player_hat(int(id))) != String(want[id]) or _worn(int(id)) != String(want[id]):
				return false
	return true


func _report(ok: bool) -> Dictionary:
	var hats := {}
	var bodies := {}
	var others_drawn := true
	for id in Net.get_peer_ids():
		hats[id] = String(Net.get_player_hat(id))
		bodies[id] = _worn(id)
		if id != multiplayer.get_unique_id() and String(hats[id]) != "" and not _drawn(id):
			others_drawn = false
	var issue_toasts := []
	for t in toasts:
		if String(t[0]).begins_with("Issued"):
			issue_toasts.append(String(t[0]))
	var locker := Game.world.lobby.get_locker() if Game.world != null and Game.world.lobby != null else null
	return {
		"ok": ok, "hats": hats, "bodies": bodies, "own_hidden": _own_hidden(), "others_drawn": others_drawn,
		"hat": String(Career.get_hat()), "issued": _issued.duplicate(), "toasts": issue_toasts,
		"prompt": locker.get_prompt(Game.local_player) if locker != null else "", "file_hat": _file_hat(),
		"left": Career.get_hat_changes_left(), "shifts": Career.get_record("shifts"),
	}


## The hat a second reader finds on this peer's file.
func _file_hat() -> String:
	var reader: Node = (load(CAREER_SCRIPT) as GDScript).new()
	var out := "?"
	if reader.load_file(_path):
		out = String(reader.get_hat())
	reader.free()
	return out


func _write_text(p: String, text: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
