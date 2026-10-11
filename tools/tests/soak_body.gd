extends "res://tools/tests/qa_m10_4p_base.gd"
## The soak (M22 soak agent, RELEASE.md R2, CONTRACTS "M22", "Soak"). A host and three clients as separate headless
## processes play the chill game for real, through tools/tests/soak.sh (two of the clients behind
## tools/tests/udp_proxy.gd in the soak_mp suite and in the long mode). Every process runs THIS script with a role:
##   --role=host                  the director AND a worker: hosts, plays, pays, compares every peer's view with its own
##   --role=client --who=a|b|c    Alpha / Bravo / Charlie: workers driven by their own bot, told what to do next by the
##                                host's commands (qa_net_base: numbered commands over a reliable RPC)
## Common args: --port=<host port> --chill --replay --lobby --run=B5VP --events --round-sec=N --growth-mult=N
##   --career-file=<own temp> --settings-file=<own temp> --soak-minutes=N (0 = the short mode) --seed=N --timeout=S;
##   clients also --join-port=<port they connect to> (the proxy's for the proxied ones).
##
## What every worker does (its bot, one bounded step at a time, walking along Room.get_route at a walking pace; a walk
## that runs out of time ends with a step to the spot, counted as walk_timeouts): buys seeds at the window, plants its
## own trays, fetches a can and waters (refills at the tank), harvests, deposits at the chute (by hand, or now and then
## a chute shot), hangs a bundle on a drying rack sometimes and deposits it cured later; Charlie loads his bundles on
## the hand truck and wheels it to the chute; every few seconds something else: a gesture (a slump now and then, then
## up again), a shove at a coworker, a few seconds of proximity voice (frames through the real send path), a power cut
## answered at the fuse box. In the alley: the ball at the hoop, gestures, shoves, voice. Once a shift two workers take
## a radio each and one talks (injected voice frames) while the other listens for it at his radio.
##
## What the host does: plays the run through the van to the final notice and pays it (PAID IN FULL), topping up the
## payment from outside when the bots fall short (the soak tests the wire, not the economy; every top-up is printed);
## Bravo leaves and joins again in the middle of a shift once a run (the first shift from 2 on still running after its
## mid-shift checkpoint); checkpoints (the alley before every ride, the middle of every shift with the bots paused and
## growth frozen, every shift report) compare the canonical state of every peer with the host's
## (qa_base.canonical_state + the run, the conditions, the job, the ledger, the write-ups, the back room, the event, the
## power, the plants that walk, the titles and hats) and every worker's health (in the play areas, not stunned or
## gesturing for ever, no stray UI lock, the host's copy of the body where the owner has it, a Player node per
## registered worker, not every request of a shift refused, no bot step running for ever). The long mode
## (SOAK_MINUTES > 0) plays runs back to back until the time box is used up, and in the second run lets shift 2 go
## unpaid on purpose (START OVER). The end: Charlie leaves, then the host leaves with Alpha and Bravo still on the floor
## (both see "Host disconnected" and a clean menu), every process exits 0.
## Fails on: a desync at a checkpoint (after CP_ATTEMPTS tries on a moving state), a stuck worker, a command that is
## never answered, a lost session, an unannounced engine error (qa_base), a crash or non-zero exit (soak.sh).

const Aim := preload("res://tools/tests/alley_aim.gd")

const SEATS := {"host": 0, "a": 1, "b": 2, "c": 3}
## Each worker's own trays (GrowPlot index); 6 and 10 are anybody's.
const PLOTS := {"host": [1, 5], "a": [2, 7], "b": [3, 8], "c": [4, 9]}
const SPARE_PLOTS: Array[int] = [6, 10]
const REJOINER := "b"
const TRUCKER := "c"
## A worker's walking pace on the floor (m/s): under the slip speed, so a wet floor is safe, as for a person.
const WALK_SPEED := 4.2
const STAND := 1.2
## Checkpoints: tries on a moving state, and how long a peer waits for the host's state each try.
const CP_ATTEMPTS := 5
const CP_WAIT := 5.0
## Health rules (seconds / metres).
const MAX_STUN_SEC := 6.0
const MAX_EMOTE_SEC := 30.0
const HOST_VIEW_TOL := 0.6
const MIN_FLOOR_SEC := 12.0
## The host pays the rest of the payment from outside this close to the end of a shift.
const TOPUP_AT_SEC := 1.5
const LEAVE_DELAY_SEC := 2.5

var _minutes: float = 0.0          # 0 = the short mode
var _seed_base: int = 7
var _join_port: int = 0
var _career_path: String = ""
var _settings_path: String = ""

# --- director (host) ---
var _ids: Dictionary = {}          # "a" / "b" / "c" -> peer id
var _t0_msec: int = 0
var _run_n: int = 0
var _shift_total: int = 0
var _topup_on: bool = false
var _skip_topup: bool = false
var _topups: Array = []            # [run, shift, amount]
var _cp_count: int = 0
var _cp_retries: int = 0
var _radio_ok: int = 0
var _radio_pairs: int = 0
var _rejoins: int = 0
var _misses: int = 0
var _runs_cleared: int = 0
var _run_lengths: Array[float] = []
var _host_job_running: bool = false
var _host_job_result: Dictionary = {}
var _events_seen: Dictionary = {}  # kind -> count (host)
var _perf: Dictionary = {}          # worker -> [[nodes, objects, orphan nodes, static MB] at every alley checkpoint]

# --- every peer ---
var _bot_on: bool = false
var _job_on: bool = false           # a command (the radio) walks the worker while the bot is off
var _radio_talking: bool = false
var _fail_stage: String = ""        # where the last action stopped (walk / seen / gone / refused)
var _fails_by: Dictionary = {}      # "fail:<step>/<stage>" -> count
var _bot_running: bool = false
var _bot_step_name: String = ""
var _bot_step_msec: int = 0
var _bot_rng := RandomNumberGenerator.new()
var _bot: Dictionary = {}          # counters for the whole session
var _shift_done: int = 0           # successful work actions this shift (confirmed by the host: the item moved, the tray changed)
var _shift_tries: int = 0          # work actions tried this shift (successful or not)
var _shift_floor_msec: int = 0     # when this worker last landed on the floor this shift
var _work_shift: int = -1
var _no_deposit: bool = false
var _hung: Array[String] = []      # names of this worker's bundles on a rack
var _next_flavor_msec: int = 0
var _stun_since: int = -1
var _cleared_seen: int = 0
var _rounds_seen: Array = []
var _selftest_done: bool = false


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = "host" if role == "host" else str(Config.get_arg("who", "a"))
	port = int(Config.get_arg("port", 9208))
	_join_port = int(Config.get_arg("join-port", port))
	_minutes = float(Config.get_arg("soak-minutes", 0.0))
	_seed_base = int(Config.get_arg("seed", 7))
	_career_path = str(Config.get_arg("career-file", ""))
	_settings_path = str(Config.get_arg("settings-file", ""))
	_label = "soak:" + who
	_t0_msec = Time.get_ticks_msec()
	_bot_rng.seed = _seed_base * 7919 + int(SEATS.get(who, 0)) * 104729
	for k in ["steps", "bought", "planted", "watered", "refilled", "harvested", "deposited", "chute_shots", "chute_in",
			"hung", "cured_sold", "truck_loads", "truck_runs", "gestures", "slumps", "shoves", "voice", "radio_talks",
			"radio_heard", "balls", "fuse", "pickups", "walk_timeouts", "fails"]:
		_bot[k] = 0
	await get_tree().process_frame
	check(Config.chill_enabled and Config.replay_enabled and Config.lobby_enabled and Events.are_events_enabled(),
			"%s: the chill game with the lobby, replay and events (--chill --replay --lobby --events)" % who)
	check(_career_path != "" and _career_path != Career.DEFAULT_PATH and Career.path == _career_path and Career.persistent,
			"%s: its own career file %s" % [who, _career_path])
	check(_settings_path != "" and Settings.path == _settings_path, "%s: its own settings file %s" % [who, _settings_path])
	_remove(_career_path)
	Career.clear_record()
	GameState.run_cleared.connect(func() -> void: _cleared_seen += 1)
	GameState.round_started.connect(func(n: int) -> void: _rounds_seen.append(n))
	if role == "host":
		Events.event_started.connect(func(k: StringName, _p: Dictionary) -> void: _events_seen[String(k)] = int(_events_seen.get(String(k), 0)) + 1)
		await _host_main()
	else:
		await _soak_client_main()
	_remove(_career_path)
	_remove(_career_path + ".tmp")
	_remove(_settings_path)
	_remove(_settings_path + ".tmp")
	finish()


func _process(delta: float) -> void:
	super(delta)
	var me: Player = Game.local_player
	if me != null and is_instance_valid(me) and me.is_inside_tree() and me.is_stunned():
		if _stun_since < 0:
			_stun_since = Time.get_ticks_msec()
	else:
		_stun_since = -1
	if _topup_on and role == "host":
		_topup_tick()


static func _remove(p: String) -> void:
	if p != "" and FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	var short := _minutes <= 0.0
	if short:
		# The short mode compresses the chill game's trouble into its 35-second shifts (the long mode keeps the chill
		# preset's own timing: the first event 60 s in, then every 75-140 s).
		b.event_first_delay_sec = 8.0
		b.event_gap_min_sec = 10.0
		b.event_gap_max_sec = 16.0
	print("SOAK: %s mode, round %.0f s, growth x%.1f, events first %.0f s then %.0f-%.0f s, quota x%.2f, last shift for four: %d" % [
			"short" if short else "long (%.0f min)" % _minutes, b.round_length_sec, Config.growth_speed_override,
			b.event_first_delay_sec, b.event_gap_min_sec, b.event_gap_max_sec, b.quota_multiplier,
			b.final_shift_by_team[mini(3, b.final_shift_by_team.size() - 1)]])
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		return
	await wait_until(func() -> bool: return Game.local_player != null and Game.world != null, 10.0, "host world ready")
	print("SOAK_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("b") > 0 and _peer_named("c") > 0, 60.0, "Alpha, Bravo and Charlie registered"):
		return
	for k in ["a", "b", "c"]:
		_ids[k] = _peer_named(k)
	await wait_until(func() -> bool: return Game.world.get_players().size() == 4, 10.0, "four Player nodes on the host")
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING, 5.0, "the alley waits (WAITING)")
	check(GameState.get_final_shift() == b.final_shift_by_team[mini(3, b.final_shift_by_team.size() - 1)], "the run ends at shift %d for four" % GameState.get_final_shift())
	_topup_on = true
	await _checkpoint("joined, in the alley")
	var deadline_msec := _t0_msec + int(_minutes * 60000.0)
	while true:
		_run_n += 1
		var t_run := Time.get_ticks_msec()
		var result := await _play_run()
		_run_lengths.append(float(Time.get_ticks_msec() - t_run) / 1000.0)
		if result == "abort":
			break
		if short:
			break
		var longest := 0.0
		for s in _run_lengths:
			longest = maxf(longest, s)
		var left := float(deadline_msec - Time.get_ticks_msec()) / 1000.0
		print("SOAK: run %d %s after %.0f s; %.0f s left in the time box (the longest run took %.0f s)" % [_run_n, result, _run_lengths.back(), left, longest])
		if left < longest * 0.8:
			break
		step("NEW RUN" if result == "cleared" else "the next run (after START OVER)")
		if result == "cleared":
			await _pause_all()
			GameState.request_retry()
			await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, 10.0, "NEW RUN: back in the alley, shift 1")
			await _checkpoint("run %d: NEW RUN, in the alley" % (_run_n + 1))
	_topup_on = false
	await _end_session()
	_summary()


## One run from the alley to PAID IN FULL ("cleared"), to a missed payment ("failed": START OVER done), or "abort".
func _play_run() -> String:
	var miss_shift := 2 if (_minutes > 0.0 and _run_n == 2) else -1
	var rejoined := false
	while true:
		var n := GameState.round_number
		await _alley_time()
		if not await _ride_van(n):
			return "abort"
		var want_rejoin := not rejoined and n >= 2
		var outcome := await _play_shift(n == miss_shift, want_rejoin)
		if outcome == "abort":
			return "abort"
		if outcome.contains("rejoined"):
			rejoined = true
		if GameState.phase == GameState.Phase.ROUND_FAILED:
			_misses += 1
			step("run %d: shift %d missed (on purpose: %s); START OVER" % [_run_n, n, n == miss_shift])
			check(n == miss_shift, "run %d: shift %d was missed only where the soak meant to miss it" % [_run_n, n])
			GameState.request_retry()
			await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == 1, 10.0, "START OVER: back in the alley, shift 1")
			await _checkpoint("run %d: START OVER, in the alley" % _run_n)
			return "failed"
		if GameState.is_run_cleared():
			_runs_cleared += 1
			await _check_cleared()
			return "cleared"
		GameState.request_next_round()
		if not await wait_until(func() -> bool: return GameState.phase == GameState.Phase.WAITING and GameState.round_number == n + 1, 10.0, "NEXT SHIFT: back in the alley for shift %d" % (n + 1)):
			return "abort"
		await _checkpoint("run %d: the alley before shift %d" % [_run_n, n + 1])
	return "abort"


## The workers mill about in the alley for a few seconds (ball, gestures, shoves, voice), then stop.
func _alley_time() -> void:
	await _work_all({"shift": -1})
	await wait_sec(4.0 if _minutes <= 0.0 else 12.0)
	await _pause_all()


## Everyone gets in the van; the host last. True once the shift is running.
func _ride_van(n: int) -> bool:
	step("run %d: shift %d, everyone in the van" % [_run_n, n])
	var seqs := {}
	for k in _ids:
		seqs[k] = cmd(int(_ids[k]), "van", {"seat": SEATS[k]})
	for k in _ids:
		var r := await await_ack(seqs[k], 20.0)
		if not bool(r.get("ok", false)):
			check(false, "%s got in the van %s" % [NAMES[k], r])
	var me: Player = Game.local_player
	var van := Game.world.lobby.get_van()
	me.velocity = Vector3.ZERO
	me.global_position = van.get_seat_transform(SEATS["host"]).origin
	var ok := await wait_until(func() -> bool: return GameState.is_playing() and GameState.round_number == n, Config.balance.van_countdown_sec + 15.0,
			"run %d: the van left with four, shift %d running" % [_run_n, n])
	if not ok:
		print("      van %d / %d, counting %s" % [van.occupants, van.total, van.is_counting()])
	return ok


## One shift on the floor. Returns "ok", "ok rejoined" or "abort".
func _play_shift(miss: bool, want_rejoin: bool) -> String:
	var n := GameState.round_number
	_shift_total += 1
	var shift_len := GameState.time_left
	var t_start := Time.get_ticks_msec()
	var final := GameState.is_final_shift()
	step("run %d: shift %d (%s), %.0f s, payment due $%d, conditions %s" % [_run_n, n, "FINAL NOTICE" if final else "plain",
			shift_len, GameState.quota, GameState.get_conditions()])
	_skip_topup = miss
	await _work_all({"shift": _shift_total, "no_deposit": miss})
	var radio_done := false
	var cp_done := false
	var rejoined := ""
	while GameState.is_playing() and GameState.round_number == n:
		var elapsed := float(Time.get_ticks_msec() - t_start) / 1000.0
		if not radio_done and elapsed >= shift_len * 0.2:
			radio_done = true
			await _radio_moment()
		elif not cp_done and elapsed >= shift_len * 0.45:
			cp_done = true
			await _mid_checkpoint("run %d: shift %d, mid-shift" % [_run_n, n])
			if want_rejoin and GameState.is_playing():
				if await _rejoin():
					rejoined = " rejoined"
				else:
					return "abort"
		else:
			await get_tree().process_frame
		if Net.players.size() < 4 and rejoined == "":
			check(false, "a worker dropped out of the session (%d registered)" % Net.players.size())
			return "abort"
	_skip_topup = false
	await _pause_all()
	await wait_sec(1.0)
	var paid := GameState.phase == GameState.Phase.ROUND_SUCCESS
	print("SOAK: run %d shift %d ended %s after %.1f s: $%d of $%d deposited, cash $%d" % [_run_n, n, "PAID" if paid else "MISSED",
			float(Time.get_ticks_msec() - t_start) / 1000.0, GameState.round_sales, GameState.quota, GameState.money])
	await _checkpoint("run %d: shift %d report" % [_run_n, n], true, true)
	return "ok" + rejoined


## The host pays what is missing from outside when a shift is about to run out (never on the shift the soak misses).
func _topup_tick() -> void:
	if _skip_topup or not GameState.is_playing() or GameState.time_left > TOPUP_AT_SEC:
		return
	var missing := GameState.quota - GameState.round_sales
	if missing <= 0:
		return
	_topups.append([_run_n, GameState.round_number, missing])
	print("SOAK: top-up $%d from outside (run %d, shift %d: $%d of $%d deposited by the crew)" % [missing, _run_n,
			GameState.round_number, GameState.round_sales, GameState.quota])
	GameState.server_add_sale(missing, 0)


func _work_all(args: Dictionary) -> void:
	var seqs := {}
	for k in _ids:
		seqs[k] = cmd(int(_ids[k]), "work", args)
	_work_args(args)
	_bot_start()
	for k in _ids:
		await await_ack(seqs[k], 15.0)


func _pause_all() -> void:
	var seqs := {}
	for k in _ids:
		seqs[k] = cmd(int(_ids[k]), "pause")
	await _bot_pause()
	for k in _ids:
		var r := await await_ack(seqs[k], 30.0)
		if not bool(r.get("idle", false)):
			check(false, "%s's bot stopped when told (stuck in '%s')" % [NAMES[k], r.get("step", "?")])


## Mid-shift: the bots stop, growth stops on the host (stage changes would move the target), the states are compared,
## then everything goes on.
func _mid_checkpoint(tag: String) -> void:
	await _pause_all()
	var growth := Config.growth_speed_override
	Config.growth_speed_override = 0.0
	await wait_sec(0.8)
	await _checkpoint(tag)
	Config.growth_speed_override = growth
	if GameState.is_playing():
		await _work_all({"shift": _shift_total, "no_deposit": _skip_topup})


## Every client converges to the host's soak state; up to CP_ATTEMPTS tries while the state is still moving (a live
## shift: the drying racks, an event, the clock running out). A client that answered with the host's CURRENT state
## converged too. Then every worker's health.
func _checkpoint(tag: String, ui: bool = false, end_of_shift: bool = false) -> void:
	_cp_count += 1
	var peers: Array = _ids.keys()
	var pending: Array = peers.duplicate()
	var answers := {}
	var tries := 0
	while not pending.is_empty() and tries < CP_ATTEMPTS:
		tries += 1
		var expect := _soak_state()
		var seqs := {}
		for k in pending:
			seqs[k] = cmd(int(_ids[k]), "cp_state", {"expect": expect, "timeout": CP_WAIT, "ui": ui})
		var still: Array = []
		for k in pending:
			var r := await await_ack(seqs[k], CP_WAIT + 15.0)
			answers[k] = r
			if bool(r.get("ok", false)):
				continue
			var theirs := String(r.get("state", ""))
			if theirs != "" and theirs == _soak_state():
				continue
			still.append(k)
			if tries == CP_ATTEMPTS:
				print("      [%s] host : %s" % [tag, expect])
				print("      [%s] %-5s: %s" % [tag, NAMES[k], theirs])
				print("      [%s] diff : %s" % [tag, _diff_states(expect, theirs)])
		pending = still
	_cp_retries += tries - 1
	for k in peers:
		check(not pending.has(k), "[%s] %s agrees with the host (%d %s)" % [tag, NAMES[k], tries, "try" if tries == 1 else "tries"])
		var r: Dictionary = answers.get(k, {})
		if ui and not pending.has(k):
			check(bool(r.get("ui_ok", true)), "[%s] %s: HUD agrees with the state %s" % [tag, NAMES[k], r.get("ui", "")])
		_judge_health(tag, NAMES[k], r.get("health", {}), end_of_shift)
		if end_of_shift:
			print("      [%s] %s: %d of %d requests went through this shift; session %s" % [tag, NAMES[k], int((r.get("health", {}) as Dictionary).get("shift_done", 0)), int((r.get("health", {}) as Dictionary).get("shift_tries", 0)), (r.get("health", {}) as Dictionary).get("bot", {})])
	var hh := await _health()
	_judge_health(tag, NAMES["host"], hh, end_of_shift)
	if end_of_shift:
		print("      [%s] Hosty: %d of %d requests went through this shift; session %s" % [tag, int(hh.get("shift_done", 0)), int(hh.get("shift_tries", 0)), hh.get("bot", {})])


## The stuck-worker rules, on one worker's own report.
func _judge_health(tag: String, worker: String, h: Variant, end_of_shift: bool) -> void:
	if not (h is Dictionary) or (h as Dictionary).is_empty():
		check(false, "[%s] %s sent its health" % [tag, worker])
		return
	var d: Dictionary = h
	if tag.contains("alley") and d.get("perf") is Array:
		if not _perf.has(worker):
			_perf[worker] = []
		(_perf[worker] as Array).append(d["perf"])
	var bad: PackedStringArray = []
	if not bool(d.get("spawned", false)):
		bad.append("no Player node of its own")
	else:
		if not bool(d.get("in_bounds", false)):
			bad.append("outside the play areas at %s" % d.get("pos"))
		if float(d.get("stun_sec", 0.0)) > MAX_STUN_SEC:
			bad.append("stunned for %.1f s" % float(d.get("stun_sec", 0.0)))
		if float(d.get("emote_sec", 0.0)) > MAX_EMOTE_SEC:
			bad.append("gesturing for %.1f s" % float(d.get("emote_sec", 0.0)))
		if not bool(d.get("host_view_ok", true)):
			bad.append("the host has the body elsewhere (%s)" % d.get("host_view", "?"))
		var stray: Array = d.get("stray_locks", [])
		if not stray.is_empty():
			bad.append("UI locked by %s" % [stray])
		if int(d.get("nodes", 0)) != int(d.get("registered", -1)):
			bad.append("%d Player nodes for %d registered workers" % [int(d.get("nodes", 0)), int(d.get("registered", -1))])
		# Shared cash can leave a worker with nothing to buy for a while; a worker whose every request was refused or
		# never came back is stuck (the host never applied any of them).
		if end_of_shift and float(d.get("floor_sec", 0.0)) >= MIN_FLOOR_SEC and int(d.get("shift_tries", 0)) >= 4 and int(d.get("shift_done", 0)) <= 0:
			bad.append("none of %d requests in %.0f s on the floor went through" % [int(d.get("shift_tries", 0)), float(d.get("floor_sec", 0.0))])
		if float(d.get("step_sec", 0.0)) > 30.0:
			bad.append("one bot step has run for %.0f s ('%s')" % [float(d.get("step_sec", 0.0)), d.get("step", "")])
	check(bad.is_empty(), "[%s] %s is not stuck%s" % [tag, worker, "" if bad.is_empty() else ": " + "; ".join(bad)])


## Once a shift two workers take a radio each; one talks, the other listens for it at his radio.
func _radio_moment() -> void:
	var order := ["a", "b", "c", "host"]
	var talker: String = order[_radio_pairs % 4]
	var listener: String = order[(_radio_pairs + 1) % 4]
	_radio_pairs += 1
	step("radio: %s talks, %s listens" % [NAMES[talker], NAMES[listener]])
	var tid := _pid(talker)
	var lid := _pid(listener)
	var results := {}
	var seqs := {}
	for k in [talker, listener]:
		var args := {"talk": k == talker, "other": lid if k == talker else tid, "seconds": 2.0}
		if k == "host":
			_host_job_running = true
			_host_radio(args)
		else:
			seqs[k] = cmd(_pid(k), "radio", args)
	for k in [talker, listener]:
		if k == "host":
			await wait_until_quiet(func() -> bool: return not _host_job_running, 40.0)
			results[k] = _host_job_result
		else:
			results[k] = await await_ack(seqs[k], 40.0)
	var sent := int((results[talker] as Dictionary).get("sent", 0))
	var heard := bool((results[listener] as Dictionary).get("heard", false))
	print("      radio: %s sent %d frames %s; %s heard: %s %s" % [NAMES[talker], sent, results[talker], NAMES[listener], heard, results[listener]])
	if sent > 0 and bool((results[talker] as Dictionary).get("both", false)):
		check(heard, "radio: %s heard %s at his radio" % [NAMES[listener], NAMES[talker]])
		if heard:
			_radio_ok += 1
	else:
		print("      radio: skipped (no pair of radios in hand before the shift moved on)")


func _host_radio(args: Dictionary) -> void:
	var was_on := _bot_on
	await _bot_pause()
	_host_job_result = await _radio_job(bool(args["talk"]), int(args["other"]), float(args["seconds"]))
	if was_on and GameState.is_playing():
		_bot_start()
	_host_job_running = false


## Bravo leaves the session in the middle of the shift and joins again (a new peer id; through the proxy in soak_mp:
## a new session there).
func _rejoin() -> bool:
	var k := REJOINER
	var old_id: int = _ids[k]
	step("%s leaves in the middle of the shift and comes back" % NAMES[k])
	var t_leave := Time.get_ticks_msec()
	var s := cmd(old_id, "leave_rejoin", {"delay": LEAVE_DELAY_SEC})
	if not await wait_until(func() -> bool: return not Net.players.has(old_id), 40.0, "%s's old peer is gone from the host" % NAMES[k]):
		return false
	print("SOAK: %s's old peer left the host %.2f s after he was told to leave" % [NAMES[k], float(Time.get_ticks_msec() - t_leave) / 1000.0])
	if not await wait_until(func() -> bool: return _peer_named(k) > 0 and _peer_named(k) != old_id, 40.0, "%s is back (a new peer id)" % NAMES[k]):
		return false
	_ids[k] = _peer_named(k)
	await wait_until(func() -> bool: return Game.world.get_player(int(_ids[k])) != null, 10.0, "%s's new Player node exists" % NAMES[k])
	var r := await await_ack(s, 40.0)
	check(bool(r.get("ok", false)), "%s re-joined on his side %s" % [NAMES[k], r])
	_rejoins += 1
	await _checkpoint("run %d: shift %d, %s back" % [_run_n, GameState.round_number, NAMES[k]])
	if GameState.is_playing():
		await _work_all({"shift": _shift_total, "no_deposit": _skip_topup})
	return true


## Every peer heard run_cleared once for this run and shows PAID IN FULL.
func _check_cleared() -> void:
	for k in _ids:
		var r := await run_cmd(int(_ids[k]), "final_report", {}, 15.0)
		check(bool(r.get("cleared", false)) and int(r.get("signals", 0)) >= 1 and String(r.get("title", "")) == "PAID IN FULL",
				"run %d: %s sees the run cleared (PAID IN FULL, run_cleared %d)" % [_run_n, NAMES[k], int(r.get("signals", 0))])
	check(GameState.is_run_cleared() and _cleared_seen >= _runs_cleared, "run %d: the host cleared it (run_cleared %d)" % [_run_n, _cleared_seen])


## Charlie leaves on his own, then the host leaves with Alpha and Bravo on the floor.
func _end_session() -> void:
	step("the end: Charlie leaves, then the host leaves with two workers still on")
	await _pause_all()
	var c_id: int = _ids["c"]
	cmd(c_id, "finish")
	await wait_until(func() -> bool: return not Net.players.has(c_id), 20.0, "Charlie left the session")
	_ids.erase("c")
	await wait_sec(1.0)
	for k in _ids:
		cmd(int(_ids[k]), "expect_host_leave")
	await wait_sec(1.0)
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 10.0, "host: back in the menu, offline")
	check_menu_clean("host after leaving")


func _summary() -> void:
	var secs := float(Time.get_ticks_msec() - _t0_msec) / 1000.0
	var kinds: PackedStringArray = []
	for k in _events_seen:
		kinds.append("%s x%d" % [k, int(_events_seen[k])])
	print("SOAK_SUMMARY: %.1f min, %d run(s) (%d cleared, %d missed on purpose), %d shifts, %d checkpoints (%d extra tries), %d rejoin(s), radio %d/%d, %d top-up(s) %s" % [
			secs / 60.0, _run_n, _runs_cleared, _misses, _shift_total, _cp_count, _cp_retries, _rejoins, _radio_ok, _radio_pairs,
			_topups.size(), _topups])
	print("SOAK_SUMMARY: events %s" % ", ".join(kinds))
	print("SOAK_SUMMARY: host bot %s" % _bot_report())
	for w in _perf:
		var rows: Array = _perf[w]
		print("SOAK_SUMMARY: %s nodes / objects / orphan nodes / static MB in the alley: first %s, last %s (%d checkpoints)" % [w, rows.front(), rows.back(), rows.size()])
	check(_runs_cleared >= 1, "at least one run played through to PAID IN FULL (%d)" % _runs_cleared)
	check(_rejoins >= 1, "a worker left and came back in the middle of a shift (%d)" % _rejoins)
	check(_radio_ok >= 1, "a radio carried at least once (%d of %d)" % [_radio_ok, _radio_pairs])
	print("SOAK_DONE")


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func _pid(key: String) -> int:
	return 1 if key == "host" else int(_ids.get(key, 0))


# =================================================================================================== CLIENT

func _soak_client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	port = _join_port # _leave_and_rejoin (qa_m10_4p_base) joins `port` again: the proxy for a proxied client
	var err := Game.start_join("127.0.0.1", _join_port, my_name)
	if not check(err == OK, "%s: start_join 127.0.0.1:%d" % [my_name, _join_port]):
		return
	if not await wait_until(func() -> bool: return Game.local_player != null, 40.0, "%s joined (local Player spawned)" % my_name):
		return
	check(Net.get_player_name(multiplayer.get_unique_id()) == my_name, "registered as %s" % my_name)
	await client_loop()
	_bot_on = false
	print("SOAK_CLIENT_DONE %s %s" % [who, _bot_report()])


func _execute(seq: int, action: String, args: Dictionary) -> void:
	match action:
		"work":
			_work_args(args)
			_bot_start()
			ack(seq, {"ok": true})
		"pause":
			await _bot_pause()
			ack(seq, {"idle": not _bot_running, "step": _bot_step_name, "bot": _bot_report()})
		"van":
			await _bot_pause()
			var me: Player = Game.local_player
			var ok := false
			if me != null and Game.world != null and GameState.phase == GameState.Phase.WAITING:
				var van := Game.world.lobby.get_van()
				me.velocity = Vector3.ZERO
				me.global_position = van.get_seat_transform(int(args.get("seat", 1))).origin
				ok = await _server_sees_me_quiet(0.5, 8.0)
			ack(seq, {"ok": ok})
		"cp_state":
			var expect := String(args.get("expect", ""))
			# Self-test of the checker (never in a suite): --soak-selftest=desync changes a watering can's charges on this
			# peer only, at the first mid-shift checkpoint (a synced property the host only sends again when it changes there,
			# unlike the cash, which rides on every GameState broadcast and heals at once); the host must report this peer.
			if String(Config.get_arg("soak-selftest", "")) == "desync" and not _selftest_done and GameState.is_playing():
				var cans := items_of(Const.ITEM_WATERING_CAN)
				if not cans.is_empty():
					_selftest_done = true
					print("  (self-test: %s's charges are changed on this peer only)" % cans[0].name)
					(cans[0] as WateringCan).charges += 3
			var t0 := Time.get_ticks_msec()
			var ok := await _wait_soak_state(expect, float(args.get("timeout", CP_WAIT)))
			var info := {"ok": ok, "state": _soak_state(), "ms": Time.get_ticks_msec() - t0}
			if bool(args.get("ui", false)):
				var ui := ui_report()
				info["ui_ok"] = ui == ""
				info["ui"] = ui
			info["health"] = await _health()
			ack(seq, info)
		"radio":
			var was_on := _bot_on
			await _bot_pause()
			var info := await _radio_job(bool(args.get("talk", false)), int(args.get("other", 0)), float(args.get("seconds", 2.0)))
			if was_on and GameState.is_playing():
				_bot_start()
			ack(seq, info)
		"leave_rejoin":
			await _bot_pause()
			await _leave_and_rejoin(float(args.get("delay", LEAVE_DELAY_SEC)))
			ack(seq, {"ok": Game.local_player != null, "id": multiplayer.get_unique_id()})
		"expect_host_leave":
			var t_wait := Time.get_ticks_msec()
			await super(seq, action, args)
			print("SOAK: %s was back in the menu %.2f s after the host said it would leave" % [NAMES.get(who, who), float(Time.get_ticks_msec() - t_wait) / 1000.0])
		"final_report":
			var hud := _hud()
			await wait_until_quiet(func() -> bool: return _hud() != null and _hud().round_end.visible and _hud().round_end.is_showing_cleared(), 5.0)
			hud = _hud()
			ack(seq, {"cleared": GameState.is_run_cleared(), "signals": _cleared_seen,
					"title": hud.round_end.title_label.text if hud != null else ""})
		_:
			await super(seq, action, args)


func _wait_soak_state(expect: String, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout * 1000.0:
		if _soak_state() == expect:
			return true
		await get_tree().process_frame
	return _soak_state() == expect


# =================================================================================================== STATE + HEALTH

## canonical_state() (qa_base: registry, GameState, Player nodes, every item with holder / props / rest spot, every
## tray) plus what the chill game adds that must agree on every peer.
func _soak_state() -> String:
	var parts: PackedStringArray = [canonical_state()]
	var cond: PackedStringArray = []
	for id in GameState.get_conditions():
		cond.append(String(id))
	parts.append("run[%s final%d cleared%s cond{%s}]" % [GameState.get_run_code(), GameState.get_final_shift(),
			GameState.is_run_cleared(), ",".join(cond)])
	var job := GameState.get_contract()
	var jk := job.keys()
	jk.sort()
	var jv: PackedStringArray = []
	for k in jk:
		jv.append("%s=%s" % [k, job[k]])
	parts.append("job{%s}" % ",".join(jv))
	var wu: PackedStringArray = []
	for k in GameState.write_ups.keys():
		wu.append("%d=%d" % [int(k), int(GameState.write_ups[k])])
	wu.sort()
	var br: PackedStringArray = []
	for k in GameState.backroom.keys():
		br.append(str(int(k)))
	br.sort()
	parts.append("wu{%s} br{%s} stats{%s}" % [",".join(wu), ",".join(br), _stats_sig()])
	parts.append("ev[%s power%s hostiles%d]" % [String(Events.active_event), Events.is_power_on(), Hostiles.get_hostiles().size()])
	var reg: PackedStringArray = []
	for id in Net.get_peer_ids():
		reg.append("%d=%s/%s" % [id, Net.get_player_title(id), Net.get_player_hat(id)])
	parts.append("titles{%s}" % ",".join(reg))
	return " ".join(parts)


## "the first token that differs" between two soak states (for the log).
static func _diff_states(a: String, b: String) -> String:
	var ta := a.split(" ")
	var tb := b.split(" ")
	var out: PackedStringArray = []
	for i in maxi(ta.size(), tb.size()):
		var x := ta[i] if i < ta.size() else "<none>"
		var y := tb[i] if i < tb.size() else "<none>"
		if x != y:
			# Inside a long token (the items, the plots) name the first entry that differs.
			var ex := x.split(";")
			var ey := y.split(";")
			for j in maxi(ex.size(), ey.size()):
				var u := ex[j] if j < ex.size() else "<none>"
				var v := ey[j] if j < ey.size() else "<none>"
				if u != v:
					x = u
					y = v
					break
			out.append("host '%s' / peer '%s'" % [x.left(300), y.left(300)])
			if out.size() >= 3:
				break
	return "; ".join(out)


## This worker's own view of itself (the host judges it: _judge_health).
func _health() -> Dictionary:
	var me: Player = Game.local_player
	# The soak's leak watch: node, object and orphan node counts and static memory of this process.
	var perf := [int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)), int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)), int(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0)]
	var d := {"spawned": me != null and is_instance_valid(me) and me.is_inside_tree(), "registered": Net.players.size(),
			"perf": perf,
			"nodes": Game.world.get_players().size() if Game.world != null else 0, "step": _bot_step_name, "bot": _bot_report(),
			"step_sec": float(Time.get_ticks_msec() - _bot_step_msec) / 1000.0 if _bot_running and _bot_step_name != "" else 0.0,
			"shift_done": _shift_done, "shift_tries": _shift_tries, "floor_sec": float(Time.get_ticks_msec() - _shift_floor_msec) / 1000.0 if _shift_floor_msec > 0 else 0.0}
	if not bool(d["spawned"]):
		return d
	var pos := me.global_position
	d["pos"] = pos
	var room: Room = Game.world.room
	var lobby: Lobby = Game.world.lobby
	var van := lobby.get_van() if lobby != null else null
	# A body pressed against a wall stands a little outside the area box: 0.4 m of slack towards the inside.
	var near_room := room.contains_point(pos)
	for off: Vector3 in [Vector3(0.4, 0.0, 0.0), Vector3(-0.4, 0.0, 0.0), Vector3(0.0, 0.0, 0.4), Vector3(0.0, 0.0, -0.4)]:
		near_room = near_room or room.contains_point(pos + off)
	d["in_bounds"] = pos.is_finite() and pos.y > -1.0 and pos.y < 4.0 and (near_room or room.is_in_booth(pos)
			or (lobby != null and lobby.contains_point(pos)) or (van != null and van.is_in_cargo(pos)))
	d["stun_sec"] = float(Time.get_ticks_msec() - _stun_since) / 1000.0 if _stun_since >= 0 else 0.0
	d["emote_sec"] = me.get_emote_time() if me.is_emoting() else 0.0
	var stray: Array = []
	for src in Game.get_ui_lock_sources():
		if src == Const.UI_LOCK_BACKROOM and GameState.is_in_backroom(me.peer_id):
			continue
		if src == &"round_end" and GameState.is_round_over():
			continue
		stray.append(String(src))
	d["stray_locks"] = stray
	var seen := await _server_sees_me_quiet(HOST_VIEW_TOL, 5.0)
	d["host_view_ok"] = seen
	if not seen:
		d["host_view"] = "local %s" % me.global_position if Game.local_player != null else "gone"
	return d


# =================================================================================================== THE BOT

func _work_args(args: Dictionary) -> void:
	var shift := int(args.get("shift", -1))
	_no_deposit = bool(args.get("no_deposit", false))
	if shift != _work_shift:
		_work_shift = shift
		_shift_done = 0
		_shift_tries = 0
		_shift_floor_msec = Time.get_ticks_msec() if shift >= 0 else 0
	elif shift >= 0 and _shift_floor_msec <= 0:
		_shift_floor_msec = Time.get_ticks_msec()


func _bot_start() -> void:
	_bot_on = true
	if not _bot_running:
		_bot_loop()


func _bot_pause() -> void:
	_bot_on = false
	await wait_until_quiet(func() -> bool: return not _bot_running, 25.0)


func _bot_loop() -> void:
	_bot_running = true
	while _bot_on and not _finished and Game.world != null and is_instance_valid(Game.world):
		_bot_step_msec = Time.get_ticks_msec()
		_bot["steps"] = int(_bot["steps"]) + 1
		await _bot_step()
		_bot_step_name = ""
		await get_tree().process_frame
	_bot_running = false


## The counters with the failure reasons and without the zeros (for the log).
func _bot_report() -> Dictionary:
	var out := {}
	for k in _bot:
		if int(_bot[k]) != 0:
			out[k] = _bot[k]
	out.merge(_fails_by)
	return out


func _note(key: String, work: bool = true) -> void:
	_bot[key] = int(_bot.get(key, 0)) + 1
	if work:
		_shift_done += 1
		_shift_tries += 1


func _fail() -> void:
	if _fail_stage == "stopped":
		return
	_bot["fails"] = int(_bot["fails"]) + 1
	_shift_tries += 1
	# Why, for the log: the step (its first word) and where it stopped (walk / seen / gone / refused).
	var key := "fail:%s/%s" % [_bot_step_name.get_slice(" ", 0), _fail_stage]
	_fails_by[key] = int(_fails_by.get(key, 0)) + 1


func _bot_step() -> void:
	var me: Player = Game.local_player
	if me == null or not is_instance_valid(me) or not me.is_inside_tree() or not Net.is_online():
		_bot_step_name = "no body"
		await wait_sec(0.3)
		return
	if GameState.is_in_backroom(me.peer_id) or me.is_stunned() or GameState.is_transitioning():
		_bot_step_name = "waiting (back room / stunned / fading)"
		await wait_sec(0.3)
		return
	match GameState.phase:
		GameState.Phase.WAITING:
			await _alley_step()
		GameState.Phase.PLAYING:
			await _floor_step()
		_:
			_bot_step_name = "between shifts"
			await wait_sec(0.3)


# --- walking -------------------------------------------------------------------------------------------------------

## Walks the local worker to `dest` (on the floor: along Room.get_route, at WALK_SPEED), then faces `face`. Stops when
## the worker is sent to the back room, the shift ends or the bot is told to stop; waits out a stagger. The body walks
## with its collision mask off (the bot steers no capsule round the trays and the pen gate; the host and the other
## peers only ever see an owner-authoritative body walking at a person's pace) and gets it back on arrival, so the
## physics settles it where it stands. A walk that takes longer than it could finishes with a step to the spot
## (counted: walk_timeouts). False when it stopped early.
func _walk_to(dest: Vector3, face: Variant = null) -> bool:
	var me: Player = Game.local_player
	if me == null or Game.world == null:
		return false
	var phase := GameState.phase
	dest.y = 0.05
	var room: Room = Game.world.room
	var pts := PackedVector3Array()
	if room.contains_point(me.global_position) and room.contains_point(dest):
		pts = room.get_route(me.global_position, dest)
	if pts.is_empty():
		pts.append(dest)
	var t0 := Time.get_ticks_msec()
	var limit_msec := int((_route_length(me.global_position, pts) / WALK_SPEED + 4.0) * 1000.0)
	var mask := Const.LAYER_WORLD | Const.LAYER_PLAYER
	for p in pts:
		var target := Vector3(p.x, 0.05, p.z)
		while true:
			if not (_bot_on or _job_on) or me == null or not is_instance_valid(me) or not me.is_inside_tree() or GameState.phase != phase \
					or GameState.is_in_backroom(me.peer_id) or GameState.is_transitioning():
				if me != null and is_instance_valid(me):
					me.collision_mask = mask
				# Told to stop or the shift moved on: not a failure of the request. The back room is one (the Boss).
				_fail_stage = "backroom" if me != null and is_instance_valid(me) and GameState.is_in_backroom(me.peer_id) else "stopped"
				return false
			if me.is_stunned():
				me.collision_mask = mask # a stagger carries the body: walls stop it as for anyone
				await get_tree().physics_frame
				continue
			var here := me.global_position
			var flat := Vector3(target.x - here.x, 0.0, target.z - here.z)
			var dist := flat.length()
			if dist < 0.05:
				break
			if Time.get_ticks_msec() - t0 > limit_msec:
				_note("walk_timeouts", false)
				if int(_bot["walk_timeouts"]) <= 4:
					print("  (%s: a walk to %s ran out of time at %s, route %s, step '%s')" % [who, dest, here, pts, _bot_step_name])
				me.velocity = Vector3.ZERO
				me.global_position = dest
				me.collision_mask = mask
				return await _face_and_settle(face)
			me.collision_mask = 0
			var dt := get_physics_process_delta_time()
			var stride := minf(WALK_SPEED * dt, dist)
			var dir := flat / dist
			me.velocity = Vector3.ZERO
			me.global_position = Vector3(here.x + dir.x * stride, 0.05, here.z + dir.z * stride)
			me.look_at(me.global_position + dir, Vector3.UP)
			me.head.rotation.x = 0.0
			await get_tree().physics_frame
	if me != null and is_instance_valid(me):
		me.collision_mask = mask
	return await _face_and_settle(face)


func _face_and_settle(face: Variant) -> bool:
	var me: Player = Game.local_player
	if me == null or not is_instance_valid(me):
		return false
	me.velocity = Vector3.ZERO
	if face is Vector3:
		var f: Vector3 = face
		var flat := Vector3(f.x, me.global_position.y, f.z)
		if flat.distance_to(me.global_position) > 0.01:
			me.look_at(flat, Vector3.UP)
		me.head.rotation.x = 0.0
	await get_tree().physics_frame
	return true


static func _route_length(from: Vector3, pts: PackedVector3Array) -> float:
	var total := 0.0
	var at := from
	for p in pts:
		total += Vector2(p.x - at.x, p.z - at.z).length()
		at = p
	return total


## Walks to STAND m in front of an interactable (stations face local +Z) and lets the host see the worker there.
func _go_to(target: Object, distance: float = STAND) -> bool:
	_fail_stage = "gone"
	var t := target as Node3D if is_instance_valid(target) else null
	if t == null or not t.is_inside_tree():
		return false
	var fwd := t.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.BACK
	var spot := t.global_position + fwd * distance
	if not await _walk_to(spot, t.global_position):
		return false
	_fail_stage = "seen"
	return await _server_sees_me_quiet(0.4, 5.0)


## Walks up to an item lying on the floor (from the side of the worker).
func _go_to_item(item: Object, distance: float = 0.8) -> bool:
	_fail_stage = "gone"
	var me: Player = Game.local_player
	var it := item as Item if is_instance_valid(item) else null
	if it == null or me == null or not it.is_inside_tree():
		return false
	var from := me.global_position - it.global_position
	from.y = 0.0
	from = from.normalized() if from.length_squared() > 0.0001 else Vector3.BACK
	if not await _walk_to(it.global_position + from * distance, it.global_position):
		return false
	_fail_stage = "seen"
	return await _server_sees_me_quiet(0.4, 5.0)


## interact() on `target` once the worker stands there, then waits for `done`. Any of them may be gone by now (sold,
## eaten, picked up by someone else): false then.
func _use(target: Object, done: Callable, wait: float = 3.0) -> bool:
	var me: Player = Game.local_player
	var t := target as Interactable if is_instance_valid(target) else null
	if me == null or not is_instance_valid(me) or t == null or not t.is_inside_tree() or GameState.is_in_backroom(me.peer_id) or me.is_stunned():
		_fail_stage = "gone"
		return false
	_fail_stage = "refused"
	t.interact(me)
	return await wait_until_quiet(done, wait)


# --- references that survive the object (lambdas capture ids, never nodes that can be freed meanwhile) ---------------

static func _obj(iid: int) -> Object:
	var o := instance_from_id(iid) if iid != 0 else null
	return o if is_instance_valid(o) else null


## Instance id of what the local worker holds (0 = nothing).
func _held_iid() -> int:
	var me: Player = Game.local_player
	if me == null or not is_instance_valid(me):
		return 0
	var h := me.get_held_item()
	return h.get_instance_id() if h != null else 0


func _held_type() -> StringName:
	var h := _obj(_held_iid()) as Item
	return h.item_type if h != null else &""


## The holder of the item behind `iid` (-1 when it is gone).
static func _holder_of(iid: int) -> int:
	var it := _obj(iid) as Item
	return it.holder_id if it != null else -1


static func _gone(iid: int) -> bool:
	var n := _obj(iid) as Node
	return n == null or n.is_queued_for_deletion() or not n.is_inside_tree()


# --- the floor -------------------------------------------------------------------------------------------------------

func _floor_step() -> void:
	var me: Player = Game.local_player
	var now := Time.get_ticks_msec()
	if _shift_floor_msec <= 0:
		_shift_floor_msec = now
	if now >= _next_flavor_msec:
		_next_flavor_msec = now + _bot_rng.randi_range(5000, 11000)
		await _flavor(false)
		return
	var held := me.get_held_item()
	if held == null:
		await _empty_hands()
	elif held is SeedPacket:
		await _with_seed(held.get_instance_id())
	elif held is WateringCan:
		await _with_can(held.get_instance_id())
	elif held is Product:
		await _with_product(held.get_instance_id())
	elif held is HandTruck:
		await _with_truck(held.get_instance_id())
	else:
		_bot_step_name = "dropping a %s" % held.item_type
		await _drop_held()


func _my_plots() -> Array[GrowPlot]:
	var out: Array[GrowPlot] = []
	for i in (PLOTS.get(who, []) as Array):
		var p := plot(int(i))
		if p != null:
			out.append(p)
	return out


func _empty_hands() -> void:
	var me_id := multiplayer.get_unique_id()
	# 1. a bundle of mine that finished curing on a rack
	for n in _hung.duplicate():
		var it := item_named(n) as Product
		if it == null or it.is_held():
			_hung.erase(n)
			continue
		if it.cured:
			_bot_step_name = "taking a cured bundle off the rack"
			var iid := it.get_instance_id()
			if await _go_to_item(it, 0.8) and await _use(_obj(iid), func() -> bool: return _held_iid() == iid):
				_hung.erase(n)
				_note("pickups")
			else:
				_fail()
			return
	# 2. my ripe trays
	for p in _my_plots():
		if p.is_ready_to_harvest():
			_bot_step_name = "harvesting %s" % p.name
			if await _go_to(p) and await _use(p, func() -> bool: return _held_type() == Const.ITEM_PRODUCT):
				_note("harvested")
			else:
				_fail()
			return
	# 3. a bundle lying loose on the floor (dropped by a stagger, a missed chute shot)
	var loose := _loose_product()
	if loose != null:
		_bot_step_name = "picking up a loose bundle"
		var iid := loose.get_instance_id()
		if await _go_to_item(loose, 0.8) and await _use(_obj(iid), func() -> bool: return _held_iid() == iid):
			_note("pickups")
		else:
			_fail()
		return
	# 4. the trucker takes a loaded truck to the chute
	if who == TRUCKER:
		var truck := _truck()
		if truck != null and not truck.is_held() and not truck.is_flying() and truck.get_load_count() >= 2:
			_bot_step_name = "picking up the hand truck"
			var tid := truck.get_instance_id()
			# Head level, facing the truck: the crosshair passes over the load, so E picks the truck up.
			if await _go_to_item(truck, 1.3) and await _use(_obj(tid), func() -> bool: return _holder_of(tid) == me_id):
				_note("truck_runs")
			else:
				_fail()
			return
	# 5. a tray of mine needs water
	for p in _my_plots():
		if p.is_growing() and p.water < 0.45:
			var can := _free_can_any()
			if can == null:
				_note("no_can", false)
				break
			_bot_step_name = "fetching a can"
			var cid := can.get_instance_id()
			if await _go_to_item(can, 0.7) and await _use(_obj(cid), func() -> bool: return _holder_of(cid) == me_id):
				_note("pickups")
			else:
				_fail()
			return
	# 6. an empty tray of mine (or a spare one) and the cash for a seed
	var empty := _empty_plot()
	if empty != null:
		var strain := _pick_strain()
		var shop: ShopCounter = station("ShopCounter") as ShopCounter
		if strain != &"" and shop != null:
			_bot_step_name = "buying %s" % strain
			if await _go_to(shop, 1.3) and is_instance_valid(shop):
				shop.request_buy_seed(strain)
				if await wait_until_quiet(func() -> bool: return _held_type() == Const.ITEM_SEED_PACKET, 3.0):
					_note("bought")
				else:
					_fail()
			return
		_note("no_cash", false)
	# 7. the power is off: the fuse box
	var fuse: FuseBox = station("FuseBox") as FuseBox
	if fuse != null and not Events.is_power_on() and fuse.is_tripped() and _bot_rng.randf() < 0.6:
		_bot_step_name = "resetting the breaker"
		var spot: Vector3 = Game.world.room.get_station_access_point("FuseBox", 1.3)
		if await _walk_to(spot, fuse.global_position) and await _server_sees_me_quiet(0.4, 5.0) and is_instance_valid(fuse) \
				and Game.local_player != null:
			fuse.interact(Game.local_player)
			await wait_sec(Config.balance.fuse_reset_sec + 0.1) # the hold
			if is_instance_valid(fuse) and fuse.is_inside_tree():
				fuse.request_reset()
				if await wait_until_quiet(func() -> bool: return Events.is_power_on(), 3.0):
					_note("fuse")
		return
	# 8. nothing to do right now
	await _flavor(false)


func _with_seed(packet_iid: int) -> void:
	var p := _empty_plot()
	if p == null:
		_bot_step_name = "dropping a seed packet (no tray free)"
		await _drop_held()
		return
	_bot_step_name = "planting %s" % p.name
	var pid := p.get_instance_id()
	if await _go_to(p) and await _use(_obj(pid), func() -> bool:
			var q := _obj(pid) as GrowPlot
			return q == null or not q.is_empty() or _held_iid() != packet_iid):
		_note("planted")
	else:
		_fail()


func _with_can(can_iid: int) -> void:
	var can := _obj(can_iid) as WateringCan
	if can == null:
		return
	if can.charges <= 0:
		var well: Well = station("Well") as Well
		if well != null and well.has_pressure():
			_bot_step_name = "refilling the can"
			if await _go_to(well, 1.3) and await _use(well, func() -> bool:
					var c := _obj(can_iid) as WateringCan
					return c == null or c.charges > 0):
				_note("refilled")
			else:
				_fail()
				await _drop_held()
		else:
			_bot_step_name = "dropping an empty can (no pressure)"
			await _drop_held()
		return
	for p in _my_plots():
		if p.is_growing() and p.water < 0.9:
			var w0 := p.water
			var pid := p.get_instance_id()
			_bot_step_name = "watering %s" % p.name
			if await _go_to(p) and await _use(_obj(pid), func() -> bool:
					var q := _obj(pid) as GrowPlot
					var c := _obj(can_iid) as WateringCan
					return q == null or c == null or q.water > w0 + 0.01 or c.charges <= 0):
				_note("watered")
			else:
				_fail()
			return
	_bot_step_name = "putting the can down"
	await _drop_held()


func _with_product(bundle_iid: int) -> void:
	var bundle := _obj(bundle_iid) as Product
	if bundle == null:
		return
	var roll := _bot_rng.randf()
	# The trucker stacks his bundles on the standing truck.
	if who == TRUCKER and not _no_deposit:
		var truck := _truck()
		if truck != null and not truck.is_held() and not truck.is_flying() and not truck.is_full() and roll < 0.7:
			_bot_step_name = "loading the hand truck"
			var count := truck.get_load_count()
			var tid := truck.get_instance_id()
			if await _go_to_item(truck, 1.3) and await _use(_obj(tid), func() -> bool:
					var t := _obj(tid) as HandTruck
					return t == null or (t.get_load_count() > count and _held_iid() == 0)):
				_note("truck_loads")
			else:
				_fail()
			return
	# Hang it to cure now and then (always on the shift the soak misses on purpose).
	var rack := _free_rack()
	if rack != null and not bundle.cured and (roll < 0.25 or _no_deposit):
		_bot_step_name = "hanging a bundle on %s" % rack.name
		var name_of := String(bundle.name)
		if await _go_to(rack) and await _use(rack, func() -> bool: return _held_iid() == 0):
			_hung.append(name_of)
			_note("hung")
		else:
			_fail()
		return
	if _no_deposit:
		_bot_step_name = "holding a bundle (the shift is missed on purpose)"
		await _flavor(false)
		return
	var chute: TurnInStation = station("TurnInStation") as TurnInStation
	if chute == null:
		await wait_sec(0.3)
		return
	if roll > 0.82:
		await _chute_shot(chute, bundle_iid)
		return
	_bot_step_name = "depositing"
	var cured := bundle.cured
	if await _go_to(chute, 1.2) and await _use(chute, func() -> bool: return _held_iid() == 0):
		_note("deposited")
		if cured:
			_note("cured_sold", false)
	else:
		_fail()


## A lob into the chute from a couple of metres (the host's own ItemManager rules decide; a miss lands on the floor
## and is picked up again as a loose bundle).
func _chute_shot(chute: TurnInStation, bundle_iid: int) -> void:
	_bot_step_name = "a chute shot"
	var fwd := chute.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.BACK
	if not await _walk_to(chute.global_position + fwd * 2.2, chute.global_position):
		return
	var me: Player = Game.local_player
	if me == null or not is_instance_valid(chute) or _held_iid() != bundle_iid:
		return
	var socket := me.get_item_socket()
	var miss := Aim.aim(me, socket, chute.get_mouth_position(), 5.0, 70.0) if socket != null else INF
	if not is_finite(miss):
		me.head.rotation.x = 0.0
		return
	await wait_sec(0.4) # the pose rides on the next sync packets
	await _server_sees_me_quiet(0.4, 4.0)
	if _held_iid() != bundle_iid:
		return
	_note("chute_shots", false)
	Game.world.items.request_throw()
	var sold := await wait_until_quiet(func() -> bool: return _gone(bundle_iid), 2.5)
	if Game.local_player != null:
		Game.local_player.head.rotation.x = 0.0
	if sold:
		_note("chute_in")
		_note("deposited")
	else:
		await wait_until_quiet(func() -> bool:
			var b := _obj(bundle_iid) as Item
			return b == null or not b.is_flying(), 2.0)


func _with_truck(truck_iid: int) -> void:
	var truck := _obj(truck_iid) as HandTruck
	if truck == null:
		return
	if truck.get_load_count() > 0 and not _no_deposit:
		var chute: TurnInStation = station("TurnInStation") as TurnInStation
		_bot_step_name = "wheeling the truck to the chute"
		if chute != null and await _go_to(chute, 1.4) and await _use(chute, func() -> bool:
				var t := _obj(truck_iid) as HandTruck
				return t == null or t.get_load_count() == 0, 4.0):
			_note("deposited")
		else:
			_fail()
	_bot_step_name = "letting go of the truck"
	await _drop_held()


func _drop_held() -> void:
	if _held_iid() == 0 or Game.world == null:
		return
	Game.world.items.request_drop()
	await wait_until_quiet(func() -> bool: return _held_iid() == 0, 2.5)


# --- lookups ---------------------------------------------------------------------------------------------------------

func _loose_product() -> Product:
	var me: Player = Game.local_player
	var best: Product = null
	var best_d := INF
	for it in items_of(Const.ITEM_PRODUCT):
		var pr := it as Product
		if pr == null or pr.is_held() or pr.is_flying() or pr.rack or pr.is_queued_for_deletion():
			continue
		if not Game.world.room.contains_point(pr.global_position, 0.3):
			continue
		var d := pr.global_position.distance_to(me.global_position)
		if d < best_d:
			best_d = d
			best = pr
	return best


func _free_can_any() -> WateringCan:
	var me: Player = Game.local_player
	var best: WateringCan = null
	var best_d := INF
	for it in items_of(Const.ITEM_WATERING_CAN):
		var can := it as WateringCan
		if can == null or can.is_held() or can.is_flying() or not Game.world.room.contains_point(can.global_position, 0.3):
			continue
		var d := can.global_position.distance_to(me.global_position) + (0.0 if can.charges > 0 else 6.0)
		if d < best_d:
			best_d = d
			best = can
	return best


func _empty_plot() -> GrowPlot:
	for p in _my_plots():
		if p.is_empty() and not p.turning:
			return p
	for i in SPARE_PLOTS:
		var p := plot(i)
		if p != null and p.is_empty() and not p.turning and _bot_rng.randf() < 0.3:
			return p
	return null


func _pick_strain() -> StringName:
	var b: BalanceConfig = Config.balance
	var shop: ShopCounter = station("ShopCounter") as ShopCounter
	var options: Array[StringName] = []
	var cheapest: StringName = &""
	var cheapest_cost := 1 << 30
	for s: SeedDef in b.seeds:
		if s == null or not GameState.is_strain_unlocked(s.id) or (shop != null and shop.is_short(s.id)):
			continue
		var cost := GameState.get_seed_cost(s)
		if cost > GameState.money:
			continue
		options.append(s.id)
		if cost < cheapest_cost:
			cheapest_cost = cost
			cheapest = s.id
	if options.is_empty():
		return &""
	return options[_bot_rng.randi_range(0, options.size() - 1)] if _bot_rng.randf() < 0.35 else cheapest


func _free_rack() -> DryingRack:
	for n in ["DryingRack1", "DryingRack2"]:
		var r := station(n) as DryingRack
		if r != null and not r.is_full():
			return r
	return null


func _truck() -> HandTruck:
	for it in items_of(Const.ITEM_HAND_TRUCK):
		return it as HandTruck
	return null


func _others() -> Array[Player]:
	var out: Array[Player] = []
	if Game.world == null:
		return out
	for p in Game.world.get_players():
		if p != Game.local_player and not GameState.is_in_backroom(p.peer_id):
			out.append(p)
	return out


# --- flavour: gestures, shoves, voice, the ball ----------------------------------------------------------------------

## Something a person does between jobs. `alley`: in the alley (the ball instead of the floor's idle).
func _flavor(alley: bool) -> void:
	var roll := _bot_rng.randf()
	if alley and roll < 0.35:
		await _ball()
	elif roll < 0.6:
		await _gesture()
	elif roll < 0.8:
		await _shove()
	elif roll < 0.92:
		await _talk_nearby()
	else:
		_bot_step_name = "standing about"
		await wait_sec(_bot_rng.randf_range(0.4, 1.0))


static func _my_emote() -> int:
	var me: Player = Game.local_player
	return me.get_emote() if me != null and is_instance_valid(me) else Player.EMOTE_NONE


func _gesture() -> void:
	var me: Player = Game.local_player
	if me.is_carrying_heavy():
		await wait_sec(0.3)
		return
	await get_tree().physics_frame
	var slump := _bot_rng.randf() < 0.15
	var kind := Player.EMOTE_SLUMP if slump else _bot_rng.randi_range(Player.EMOTE_POINT, Player.EMOTE_SHRUG)
	_bot_step_name = "gesture %s" % Player.emote_name(kind)
	if me.request_emote(kind):
		_note("gestures", false)
		if slump:
			_note("slumps", false)
			await wait_until_quiet(func() -> bool: return _my_emote() == Player.EMOTE_SLUMP, 2.0)
			await wait_sec(1.2)
			if Game.local_player != null and is_instance_valid(Game.local_player):
				Game.local_player.request_emote(Player.EMOTE_SLUMP) # a slumped worker stands up
			await wait_until_quiet(func() -> bool: return _my_emote() == Player.EMOTE_NONE, 2.0)
		else:
			await wait_sec(1.0)
	else:
		await wait_sec(0.3)


func _shove() -> void:
	var me: Player = Game.local_player
	var others := _others()
	if others.is_empty():
		await wait_sec(0.3)
		return
	var target: Player = others[_bot_rng.randi_range(0, others.size() - 1)]
	var tid := target.peer_id
	_bot_step_name = "shoving %s" % Net.get_player_name(tid)
	var same_area := (Game.world.room.contains_point(me.global_position) and Game.world.room.contains_point(target.global_position)) \
			or (Game.world.lobby.contains_point(me.global_position) and Game.world.lobby.contains_point(target.global_position))
	if not same_area:
		await wait_sec(0.3)
		return
	var behind := target.global_position - target.get_flat_forward() * 1.0
	if not await _walk_to(behind, target.global_position):
		return
	me = Game.local_player
	var t2: Player = Game.world.get_player(tid) if Game.world != null else null
	if t2 == null or me == null:
		return
	var at := t2.global_position
	if me.global_position.distance_to(at) > 1.6:
		return # it walked off meanwhile
	me.look_at(Vector3(at.x, me.global_position.y, at.z), Vector3.UP)
	await _server_sees_me_quiet(0.4, 3.0)
	if Game.local_player == null or Game.world == null or Game.world.get_player(tid) == null:
		return
	Game.local_player.request_shove(tid)
	_note("shoves", false)
	await wait_sec(0.5)


func _talk_nearby() -> void:
	_bot_step_name = "talking"
	_note("voice", false)
	await _voice_burst(_bot_rng.randf_range(0.8, 1.6), 50.0)


func _ball() -> void:
	var me_id := multiplayer.get_unique_id()
	var lobby: Lobby = Game.world.lobby
	var ball := lobby.get_ball() if lobby != null else null
	if ball == null or ball.is_held() or ball.is_flying() or not lobby.contains_point(ball.global_position):
		await _gesture()
		return
	_bot_step_name = "the ball"
	var bid := ball.get_instance_id()
	if not await _go_to_item(ball, 0.7) or not await _use(_obj(bid), func() -> bool: return _holder_of(bid) == me_id):
		return
	var hoop := lobby.get_hoop() if is_instance_valid(lobby) else null
	if hoop == null or not await _walk_to(lobby.global_position + Vector3(-1.2, 0.05, -1.4), hoop.get_ring_center()):
		await _drop_held()
		return
	var me: Player = Game.local_player
	if me == null or _holder_of(bid) != me_id:
		return
	var socket := me.get_node_or_null(^"%BodyHandSocket") as Node3D
	if socket == null:
		socket = me.get_item_socket()
	Aim.aim(me, socket, hoop.get_ring_center())
	await wait_sec(0.6)
	await _server_sees_me_quiet(0.4, 3.0)
	if _holder_of(bid) != me_id:
		return
	Game.world.items.request_throw()
	_note("balls", false)
	await wait_until_quiet(func() -> bool:
		var b := _obj(bid) as Item
		return b == null or (not b.is_flying() and not b.is_held()), 3.0)
	if Game.local_player != null:
		Game.local_player.head.rotation.x = 0.0


func _alley_step() -> void:
	var held := _obj(_held_iid()) as Item
	if held != null:
		_bot_step_name = "putting the %s down in the alley" % held.item_type
		await _drop_held()
		return
	await _flavor(true)


# --- the radio ---------------------------------------------------------------------------------------------------------

## Takes a free radio; the talker waits until `other` holds the other one, talks `seconds` (frames through the real
## send path every 20 ms) and lets go; the listener waits to hear `other` on the radio at his own radio. Then down.
func _radio_job(talk: bool, other: int, seconds: float) -> Dictionary:
	var me_id := multiplayer.get_unique_id()
	var info := {"got": false, "both": false, "sent": 0, "heard": false, "output": false}
	_radio_talking = talk
	if Game.local_player == null or Game.world == null or not GameState.is_playing():
		return info
	var held := _obj(_held_iid()) as Item
	if held != null and not (held is Radio):
		_bot_step_name = "radio: hands free first"
		await _drop_held()
	_job_on = true
	var radio_iid := held.get_instance_id() if held is Radio else 0
	# Both workers may walk to the same radio: whoever loses it takes the other one.
	var tries := 0
	while radio_iid == 0 and tries < 4 and GameState.is_playing():
		tries += 1
		var r := _free_radio(tries)
		if r == null:
			await wait_sec(0.5)
			continue
		_bot_step_name = "radio: taking %s" % r.name
		var rid := r.get_instance_id()
		if await _go_to_item(r, 0.8) and await _use(_obj(rid), func() -> bool: return _holder_of(rid) != 0, 4.0) and _holder_of(rid) == me_id:
			radio_iid = rid
	if radio_iid == 0 or _holder_of(radio_iid) != me_id:
		_job_on = false
		return info
	info["got"] = true
	if talk:
		info["both"] = await wait_until_quiet(func() -> bool: return _radio_held_by(other) != null, 15.0)
		if info["both"]:
			_bot_step_name = "radio: talking"
			var frames := int(seconds * 50.0)
			var sent := 0
			for i in frames:
				if not Net.is_online():
					break
				Voice.debug_send_frame(_voice_frame(i, 330.0))
				sent += 1
				await wait_sec(0.02)
			info["sent"] = sent
			_note("radio_talks", false)
			await wait_sec(0.4)
	else:
		info["both"] = true
		_bot_step_name = "radio: listening"
		info["heard"] = await wait_until_quiet(func() -> bool: return Voice.is_on_radio(other), seconds + 15.0)
		if info["heard"]:
			var mine := _obj(radio_iid) as Radio
			info["output"] = mine != null and Voice.get_radio_output_node(other, mine) != null
			_note("radio_heard", false)
			await wait_until_quiet(func() -> bool: return not Voice.is_on_radio(other), 6.0)
	_bot_step_name = "radio: putting it down"
	await _drop_held()
	_job_on = false
	return info


## The nearest free radio; on the first try the talker and the listener aim for different ones (by name order).
func _free_radio(attempt: int) -> Radio:
	var me: Player = Game.local_player
	var best: Radio = null
	var best_d := INF
	var radios := items_of(Const.ITEM_RADIO)
	radios.sort_custom(func(x: Item, y: Item) -> bool: return String(x.name) < String(y.name))
	for i in radios.size():
		var r := radios[i] as Radio
		if r == null or r.is_held() or r.is_flying() or not Game.world.room.contains_point(r.global_position):
			continue
		var d := r.global_position.distance_to(me.global_position)
		if attempt == 1 and i % 2 != (1 if _radio_talking else 0):
			d += 100.0
		if d < best_d:
			best_d = d
			best = r
	return best


func _radio_held_by(peer: int) -> Radio:
	for it in items_of(Const.ITEM_RADIO):
		if it.holder_id == peer:
			return it as Radio
	return null
