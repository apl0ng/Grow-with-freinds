extends "res://tools/tests/qa_net_base.gd"
## M25 runcard multi-process body (runcard agent). Driven by tools/tests/runcard_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): books the stats, pays and misses the shifts
##   --role=client --who=a       Alpha: there from the start
##   --role=client --who=b       Bravo: joins late, on the START OVER card of run 1
## Common args: --port=N --round-sec=900 --replay --run=B5VP --career-file=<own temp file> --timeout=S. Every process
## prints "ok   -" / "FAIL -" lines and a final "RESULT: PASS|FAIL" line; unannounced engine errors fail the run.
## The host moves the final notice to shift 2 (its table; the last shift is the host's and synced).
## Pins over the wire:
##   run 1   Ghost (a host-side worker no client's registry ever lists) carries shift 1 and leaves during shift 2, the
##           final notice, which is missed: the host and Alpha read the same THE RUN block on the START OVER card, with
##           Ghost's name (the synced run_names); Bravo joins on that card and reads the same block from his first full
##           state; after shift 1 (an ordinary shift) nobody shows a block; START OVER clears the totals on every peer
##   run 2   shift 1 ordinary (no block anywhere); the final notice is paid with four rows on the shift report (Dot, a
##           host-side worker, is the fourth): PAID IN FULL on every peer, the same block, and the card fits 1280x720
##           on every peer (the clients' card has the waiting line instead of the buttons)
##   every checkpoint: the canonical state on every peer

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const GHOST := 9
const GHOST_NAME := "Ghost Okafor"
const DOT := 10
const DOT_NAME := "Dot"

var role: String = "host"
var who: String = ""
var port: int = 8118
var _ids: Dictionary = {}
var _path: String = ""
var _deposits: int = 0
var re: RoundEndOverlay


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 8118))
	_label = "runcard_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	# Headless windows report 1280x1280; force the reference logical size (the smallest stretch "expand" allows).
	get_tree().root.size = Vector2i(1280, 720)
	_path = str(Config.get_arg("career-file", ""))
	if not check(_path != "" and _path != Career.DEFAULT_PATH and Career.path == _path, "this process has its own career file (%s)" % _path):
		finish(); return
	_remove(_path)
	Career.clear_record()
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	Config.growth_speed_override = 0.0
	b.end_round_on_quota_met = true
	b.final_shift_by_team = [2, 2, 2, 2]
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		_cleanup(); finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and Game.world.get_node_or_null(^"HUD") != null, 10.0, "host world ready")
	re = (Game.world.get_node(^"HUD") as HUD).round_end
	GameState.sale_made.connect(func(amount: int, seller: int) -> void:
		if seller > 0:
			_deposits += amount)
	print("RUNCARD_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		_cleanup(); finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")

	step("run 1, shift 1: Ghost carries it (an ordinary shift)")
	_add_host_worker(GHOST, GHOST_NAME)
	GameState.request_start_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 1 and GameState.get_final_shift() == 2, "shift 1 running; the final notice is shift 2")
	GameState.server_add_stat(a, Const.STAT_HELPED)
	GameState.server_add_stat(GHOST, Const.STAT_BRUISED)
	await _pay_split([[GHOST, 0.7], [a, 0.1]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not GameState.is_run_cleared() and re.is_open() and not re.is_showing_run(),
			"host: an ordinary end screen, no block")
	await _ask_cards("shift 1 paid", ["a"], "", false)

	step("run 1, shift 2: the final notice; Ghost leaves; missed")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.is_final_shift(), "shift 2 is the final notice")
	_remove_host_worker(GHOST)
	GameState.server_add_stat(a, Const.STAT_BITTEN)
	GameState.server_write_up(1, Const.WRITE_UP_OTHER)
	await wait_frames(1)
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.ROUND_FAILED, 5.0, "the final notice is missed")
	await wait_frames(2)
	var h1 := re.run_card.get_block_text()
	var want1 := "\n".join(PackedStringArray(["THE RUN", "Shifts worked: 2 · Deposited: %s · Bruised: 1 · Helped up: 1" % Story.format_money(_deposits),
			"%s carried the deposits. Nobody said so." % GHOST_NAME, "Alpha picked the most people up off the floor.",
			"%s bruised the most product. He docked it." % GHOST_NAME]))
	check(re.is_showing_run() and re.primary_button.text == RoundEndOverlay.TEXT_START_OVER and h1 == want1,
			"host: the START OVER card shows THE RUN, Ghost under his own name:\n%s" % h1)
	await _host_fits("the missed final notice")
	await _ask_cards("the missed final notice", ["a"], h1, false)
	await checkpoint("missed", ["a"])

	print("RUNCARD_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		_cleanup(); finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	check(GameState.phase == GameState.Phase.ROUND_FAILED and re.run_card.get_block_text() == h1, "host: still the same card")
	await _ask_cards("Bravo joins on the START OVER card", ["b"], h1, false)
	await checkpoint("late joiner", ["a", "b"])

	step("START OVER clears the totals on every peer")
	_deposits = 0
	re.primary_button.pressed.emit()
	await wait_frames(3)
	check(GameState.phase == GameState.Phase.WAITING and GameState.run_stats.is_empty() and GameState.run_names.is_empty() and GameState.run_shifts == 0
			and not re.is_open(), "host: WAITING, no totals, the card gone")
	await _ask_cleared(["a", "b"])

	step("run 2, shift 1: Bravo puts half down (an ordinary shift)")
	GameState.request_start_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 1 and GameState.get_final_shift() == 2, "run 2: shift 1 running")
	GameState.server_add_stat(bb, Const.STAT_BRUISED, 3)
	GameState.server_add_stat(a, Const.STAT_HELPED, 2)
	await _pay_split([[bb, 0.5]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and not re.is_showing_run(), "host: an ordinary end screen, no block")
	await _ask_cards("run 2, shift 1 paid", ["a", "b"], "", false)

	step("run 2, shift 2: the final notice paid, four rows on the report")
	GameState.request_next_round()
	await wait_frames(2)
	check(GameState.is_playing() and GameState.round_number == 2 and GameState.is_final_shift(), "the final notice")
	_add_host_worker(DOT, DOT_NAME)
	GameState.server_add_stat(DOT, Const.STAT_PLANTED, 2)
	GameState.server_add_stat(bb, Const.STAT_WATERED)
	await _pay_split([[a, 1.0]])
	check(GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.is_run_cleared() and re.is_showing_cleared(), "host: PAID IN FULL")
	var h2 := re.run_card.get_block_text()
	var want2 := "\n".join(PackedStringArray(["THE RUN", "Shifts worked: 2 · Deposited: %s · Bruised: 3 · Helped up: 2" % Story.format_money(_deposits),
			"Alpha carried the deposits. Nobody said so.", "Alpha picked the most people up off the floor.", "Bravo bruised the most product. He docked it."]))
	check(re.is_showing_run() and h2 == want2 and re.report.get_row_peers().size() == 4, "host: THE RUN on PAID IN FULL, four report rows:\n%s" % h2)
	await _host_fits("PAID IN FULL")
	await _ask_cards("PAID IN FULL", ["a", "b"], h2, true)
	_remove_host_worker(DOT)   # before the clients leave: a departure broadcasts the registry
	await checkpoint("paid in full", ["a", "b"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bb, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bb), 20.0, "both left")
	_cleanup()
	finish()


## Every client in `keys` waits until its card shows `want` as THE RUN block ("" = no block), then reports.
func _ask_cards(tag: String, keys: Array, want: String, cleared: bool) -> void:
	var seqs := {}
	for k: String in keys:
		seqs[k] = cmd(int(_ids[k]), "card", {"expect": want})
	for k: String in keys:
		var r := await await_ack(int(seqs[k]), 30.0)
		var who_name: String = NAMES[k]
		var same := bool(r.get("ok", false)) and String(r.get("block", "?")) == want
		check(same, "[%s] %s reads the same block%s" % [tag, who_name, "" if want != "" else " (none: an ordinary shift)"])
		if not same:
			print("      host : %s" % want.replace("\n", " | "))
			print("      %-5s: %s" % [who_name, String(r.get("block", "<no answer>")).replace("\n", " | ")])
		check(bool(r.get("open", false)) and bool(r.get("waiting", false)) and not bool(r.get("button", true)),
				"[%s] %s: the card is up with the waiting line, no button" % [tag, who_name])
		check(bool(r.get("run", true)) == (want != "") and bool(r.get("cleared", false)) == cleared,
				"[%s] %s: THE RUN %s; PAID IN FULL %s" % [tag, who_name, "shown" if want != "" else "hidden", "yes" if cleared else "no"])
		if want != "":
			check(bool(r.get("fits", false)) and int(r.get("scrolls", 1)) == 0, "[%s] %s: the card fits 1280x720, nothing scrolls (%s rows, scale %.3f)"
					% [tag, who_name, r.get("rows", "?"), float(r.get("scale", 0.0))])


func _ask_cleared(keys: Array) -> void:
	var seqs := {}
	for k: String in keys:
		seqs[k] = cmd(int(_ids[k]), "cleared", {})
	for k: String in keys:
		var r := await await_ack(int(seqs[k]), 30.0)
		check(bool(r.get("ok", false)) and not bool(r.get("open", true)) and int(r.get("names", -1)) == 0,
				"%s: WAITING, no totals, no names, the card gone" % NAMES[k])


func _host_fits(tag: String) -> void:
	await wait_sec(0.6)   # the card's pop-in must be over: a scaled rect would pass any fit check
	var vp := get_viewport().get_visible_rect()
	check(vp.size == Vector2(1280, 720) and vp.encloses(re.card.get_global_rect()) and re.card.find_children("*", "ScrollContainer", true, false).is_empty(),
			"[%s] host: the card fits 1280x720, nothing scrolls (scale %.3f)" % [tag, re.get_fit_scale()])


## Deposits the shares of the payment for the workers ([peer, share]), then the host pays what is still owed.
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


## A worker only the host's registry lists (no body, never broadcast): their stats and name travel only in GameState.
func _add_host_worker(id: int, worker_name: String) -> void:
	Net.players[id] = {"name": worker_name, "color": Net.PALETTE[id % Net.PALETTE.size()]}
	Net.players_changed.emit()


func _remove_host_worker(id: int) -> void:
	var departed: Dictionary = Net.get(&"_departed_names")
	departed[id] = Net.get_player_name(id)
	Net.players.erase(id)
	Net.players_changed.emit()
	Net.peer_left.emit(id)


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func checkpoint(tag: String, keys: Array) -> void:
	var peers := []
	var names := {}
	for k in keys:
		peers.append(_ids[k])
		names[_ids[k]] = NAMES[k]
	await checkpoint_peers(tag, peers, names)


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		_cleanup(); finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		_cleanup(); finish(); return
	await client_loop()
	_cleanup()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	match action:
		"card":
			var want := String(args.get("expect", ""))
			var hud := Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
			var overlay: RoundEndOverlay = hud.round_end if hud != null else null
			var info := {"ok": false, "block": "<no card>"}
			if overlay != null:
				var ok := await wait_until_quiet(func() -> bool: return overlay.is_open() and overlay.run_card.get_block_text() == want, 10.0)
				await wait_sec(0.6)   # the pop-in is over before the fit is measured
				var vp := get_viewport().get_visible_rect()
				info = {"ok": ok, "block": overlay.run_card.get_block_text(), "open": overlay.is_open(), "run": overlay.is_showing_run(),
						"cleared": overlay.is_showing_cleared(), "waiting": overlay.waiting_label.visible, "button": overlay.primary_button.visible,
						"fits": vp.size == Vector2(1280, 720) and vp.encloses(overlay.card.get_global_rect()),
						"scrolls": overlay.card.find_children("*", "ScrollContainer", true, false).size(), "scale": overlay.get_fit_scale(),
						"rows": overlay.report.get_row_peers().size()}
			ack(seq, info)
		"cleared":
			var ok := await wait_until_quiet(func() -> bool:
				return GameState.phase == GameState.Phase.WAITING and GameState.run_stats.is_empty() and GameState.run_shifts == 0, 10.0)
			var hud := Game.world.get_node_or_null(^"HUD") as HUD if Game.world != null else null
			ack(seq, {"ok": ok, "open": hud.round_end.is_open() if hud != null else true, "names": GameState.run_names.size()})
		_:
			await super(seq, action, args)


func _remove(p: String) -> void:
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


func _cleanup() -> void:
	_remove(_path)
	_remove(_path + ".tmp")
