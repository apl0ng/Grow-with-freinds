extends "res://tools/tests/perf_base.gd"
## M22 perf suite (perf agent; CONTRACTS.md "M22", "Performance"; RELEASE.md R3), on the chill game:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/perf_body.gd --port=9106 --chill --replay --run=B5VP --career-file=user://perf_test_9106.cfg --settings-file=user://perf_settings_9106.cfg
## Two passes in one host process:
##   the CPU pass      me + Bob, Cara and Dan on a busy floor; every moment of perf_base.gd measured for MEASURE_SEC at
##                     60 frames a second (one process step and one physics step per frame); the table printed.
##   the network pass  back to the menu, hosted again on the same port with one real client process (this body with
##                     --role=client, started here) + Cara and Dan; the same moments with the host's own voice going out
##                     through the real send path; ENet's statistics give the bytes the host sent to that client.
## (--measure-only: the tables and nothing else; the suite's budgets and pins are skipped, so it runs on older code.
## --cpu-only: the CPU pass alone.)
## Pins: the budgets (headless frame and network, with wide margins: a loaded machine must never fail them) and the
## M22 fixes where a counter can show them (no tray lookup or group scan per frame, the shift report refreshed in
## place, the voice tables give the very samples the old decode gave).

const MEASURE_SEC := 3.0
## Budgets (CONTRACTS "M22": generous, never flaky on a loaded machine). Milliseconds per frame: this PC measured a mean
## of 0.7 to 1.1 ms and a p95 of 0.9 to 1.5 ms in every moment, also with other test runs going; the mean budget is the R3
## bar itself (under 4 ms), the p95 one about four times the worst p95 seen.
const BUDGET_MEAN_MS := 4.0
const BUDGET_P95_MS := 6.0
## Bytes per second host -> one client (ENet payload + UDP/IP headers): the busiest moment (the host talking on the
## radio: ~24 KB/s measured) and the busiest moment without a voice (~7 KB/s measured).
const BUDGET_NET_BPS := 48 * 1024
const BUDGET_STATE_BPS := 20 * 1024
const CLIENT_NAME := "Client"

var _role := "host"
var _client_pid: int = -1
var _client_report: Dictionary = {}
var _client_finish := false


func _run() -> void:
	_role = str(Config.get_arg("role", "host"))
	_label = "perf" if _role == "host" else "perf-client"
	await get_tree().process_frame
	if _role == "client":
		await _run_client()
		return
	check(Config.chill_enabled and Config.replay_enabled, "the chill game (--chill --replay)")
	var measure_only := Config.has_arg("measure-only")
	if not await host_floor(port_arg(9106), [BOB, CARA, DAN] as Array[int]):
		finish(); return
	var fps0 := Engine.max_fps
	Engine.max_fps = 60 # one process step and one physics step per frame, as a 60 fps game runs
	await hold(1.0)
	var rows := await _cpu_pass(measure_only)
	print("perf table (ms per frame, headless host, four workers):\n" + table(rows))
	if not measure_only:
		_check_budgets(rows)
		await _check_pins()
	var net := {} if Config.has_arg("cpu-only") else await _net_pass()
	Engine.max_fps = fps0
	if not net.is_empty():
		print("network table (host -> one client, chill shift, four workers):\n" + net_table(net))
		if not measure_only:
			_check_net(net)
	finish()


# --- the CPU pass --------------------------------------------------------------------------------------------------------

func _cpu_pass(measure_only: bool) -> Dictionary:
	var rows := {}
	for m in MOMENTS:
		step("moment: %s" % m)
		var started: bool = await stage(m)
		check(started, "%s: started" % m)
		var r: Dictionary = await measure(m, MEASURE_SEC)
		rows[m] = r
		print("    %s: mean %.2f ms, p95 %.2f ms, max %.2f ms (process %.2f, physics %.2f; the engine's worst step %.2f ms; %d frames, live %.0f%%)"
				% [m, r["mean"], r["p95"], r["max"], r["proc_mean"], r["phys_mean"], r["mon_ms"], r["n"], float(r["live"]) * 100.0])
		print("      slowest: " + String(r["worst"]))
		if not measure_only:
			check(float(r["live"]) > 0.9, "%s: still going for the whole window (%.0f%%)" % [m, float(r["live"]) * 100.0])
		if m != &"report":
			unstage(m)
			await hold(1.0)
	return rows


func _check_budgets(rows: Dictionary) -> void:
	step("the headless budget (CONTRACTS M22: under 4 ms a frame on this PC; asserted with room for a loaded machine)")
	for m: StringName in rows:
		var r: Dictionary = rows[m]
		check(int(r["n"]) >= 60, "%s: %d frames measured" % [m, int(r["n"])])
		check(float(r["mean"]) < BUDGET_MEAN_MS, "%s: mean frame %.2f ms < %.1f ms" % [m, float(r["mean"]), BUDGET_MEAN_MS])
		check(float(r["p95"]) < BUDGET_P95_MS, "%s: p95 frame %.2f ms < %.1f ms" % [m, float(r["p95"]), BUDGET_P95_MS])


## The M22 fixes, by their counters (the report moment just ran: the card is open).
func _check_pins() -> void:
	step("pins: the M22 fixes")
	# Events: the trays are not looked up by name every frame.
	var lookups0: int = Events.perf_plot_lookups
	await hold(0.5)
	check(Events.perf_plot_lookups == lookups0, "Events: no tray looked up by name in half a second of frames (%d in all)" % lookups0)
	# Hostiles: the tray group is not read every physics frame.
	var scans0: int = Hostiles.perf_group_scans
	var p0 := Engine.get_physics_frames()
	await hold(0.5)
	check(Engine.get_physics_frames() - p0 >= 10 and Hostiles.perf_group_scans == scans0,
			"Hostiles: the tray group not read once in %d physics frames (%d reads in all)" % [Engine.get_physics_frames() - p0, scans0])
	# The shift report: refreshed in place while it keeps its shape.
	var report := hud.round_end.report
	var built: int = report.perf_rebuilds
	var kept: int = report.perf_in_place
	var cell0 := report.get_cell_text(1, 0)
	report.refresh()
	check(report.perf_rebuilds == built and report.perf_in_place == kept + 1 and report.get_cell_text(1, 0) == cell0,
			"the shift report: a refresh with nothing new updates the labels in place (%s)" % cell0)
	var label0 := report.grid.get_child(report.grid.columns) as Label
	GameState.server_add_stat(BOB, Const.STAT_PLANTED, 2)
	await wait_frames(2)
	var row := report.get_row_peers().find(BOB) + 1
	check(row > 0 and report.get_cell_text(row, 2) == str(GameState.get_stat(BOB, Const.STAT_PLANTED)) and is_instance_valid(label0)
			and report.grid.get_child(report.grid.columns) == label0, "a stat change while it is open: the new number, the same labels (%s)" % report.get_cell_text(row, 2))
	# Voice: the tables give exactly what the old per-sample decode gave.
	var VoiceScript: GDScript = load("res://scripts/core/voice.gd")
	var all := PackedByteArray()
	all.resize(256)
	for b in 256:
		all[b] = b
	var mono: PackedFloat32Array = VoiceScript.decode_mulaw(all)
	var stereo: PackedVector2Array = VoiceScript.perf_decode_stereo(all)
	var same := mono.size() == 256 and stereo.size() == 256
	for b in 256:
		var want: float = VoiceScript._decode_mulaw_byte(b)
		if mono[b] != want or stereo[b] != Vector2(want, want):
			same = false
	check(same, "Voice: decode_mulaw and perf_decode_stereo give _decode_mulaw_byte's samples for all 256 bytes")


# --- the network pass ----------------------------------------------------------------------------------------------------

## Back to the menu, hosted again with a client process + Cara and Dan; per moment {sent B/s, packets/s, wire B/s,
## received B/s}. {} when the client never came.
func _net_pass() -> Dictionary:
	step("the network pass: hosting again with a client process")
	Game.return_to_menu()
	await wait_frames(10)
	var port := port_arg(9106)
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"), "-s", "res://tools/tests/run_test.gd",
			"--", "--body=res://tools/tests/perf_body.gd", "--role=client", "--port=%d" % port, "--chill", "--replay", "--run=B5VP",
			"--career-file=user://perf_client_%d.cfg" % port, "--settings-file=user://perf_client_settings_%d.cfg" % port, "--timeout=150"])
	radio_talker = 1
	voice_talkers = [1] as Array[int]
	var launch := func() -> void: _client_pid = OS.create_process(OS.get_executable_path(), args)
	var hosted: bool = await host_floor(port, [CARA, DAN] as Array[int], 1, 45.0, launch)
	check(_client_pid > 0, "started the client process")
	if not hosted:
		_stop_client()
		return {}
	var enet := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if not check(enet != null and enet.host != null, "an ENet host"):
		_stop_client()
		return {}
	await hold(1.0)
	var rows := {}
	for m in MOMENTS:
		var started: bool = await stage(m)
		check(started, "network pass, %s: started" % m)
		enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
		enet.host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
		var t0 := Time.get_ticks_usec()
		var r: Dictionary = await measure(m, MEASURE_SEC)
		var sec := float(Time.get_ticks_usec() - t0) / 1000000.0
		var sent := enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_DATA)
		var packets := enet.host.pop_statistic(ENetConnection.HOST_TOTAL_SENT_PACKETS)
		var received := enet.host.pop_statistic(ENetConnection.HOST_TOTAL_RECEIVED_DATA)
		rows[m] = {"bps": sent / sec, "pps": packets / sec, "wire": (sent + packets * 28.0) / sec, "rx": received / sec,
				"frame_mean": r["mean"], "frame_p95": r["p95"]}
		print("    %s: %.0f B/s in %.0f packets/s (%.0f B/s with UDP/IP headers), %.0f B/s back; host frame mean %.2f ms"
				% [m, sent / sec, packets / sec, (sent + packets * 28.0) / sec, received / sec, r["mean"]])
		if m != &"report":
			unstage(m)
			await hold(0.5)
	_rpc_client_finish.rpc_id(_client_peer())
	var reported := await wait_until(func() -> bool: return not _client_report.is_empty(), 15.0, "the client reported back")
	if reported:
		check(int(_client_report.get("fails", 1)) == 0 and (_client_report.get("errors", []) as Array).is_empty(),
				"the client: %d checks passed, none failed, no engine/script error %s" % [int(_client_report.get("passes", 0)), _client_report.get("errors", [])])
	await wait_until(func() -> bool: return not OS.is_process_running(_client_pid), 15.0, "the client process exited")
	_stop_client()
	return rows


func _check_net(rows: Dictionary) -> void:
	step("the network budget (host -> one client; target: a busy shift with one voice under 32 KB/s, the game state alone under 16 KB/s)")
	var worst := 0.0
	var worst_m := ""
	var worst_state := 0.0
	var worst_state_m := ""
	for m: Variant in rows:
		var wire := float(rows[m]["wire"])
		if wire > worst:
			worst = wire
			worst_m = String(m)
		if m != &"radios" and m != &"voices" and wire > worst_state:
			worst_state = wire
			worst_state_m = String(m)
	check(worst > 0.0 and worst < BUDGET_NET_BPS, "the busiest moment (%s, the host talking) sends %.1f KB/s < %.0f KB/s" % [worst_m, worst / 1024.0, BUDGET_NET_BPS / 1024.0])
	check(worst_state > 0.0 and worst_state < BUDGET_STATE_BPS, "without a voice the busiest moment (%s) sends %.1f KB/s < %.0f KB/s"
			% [worst_state_m, worst_state / 1024.0, BUDGET_STATE_BPS / 1024.0])
	var voice := float(rows.get(&"voices", {}).get("wire", 0.0)) - float(rows.get(&"idle", {}).get("wire", 0.0))
	check(voice > 8 * 1024 and voice < 32 * 1024, "one voice adds %.1f KB/s (G.711 at 16 kHz: 320 bytes, 50 frames a second)" % (voice / 1024.0))


func _client_peer() -> int:
	for p in world.get_players():
		if p.peer_id != 1 and not fakes.has(p.peer_id):
			return p.peer_id
	return 0


func _stop_client() -> void:
	if _client_pid > 0 and OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
	_client_pid = -1


static func net_table(rows: Dictionary) -> String:
	var lines: PackedStringArray = ["  %-11s %9s %9s %10s %9s | %6s" % ["moment", "KB/s", "packets", "wire KB/s", "back KB/s", "frame"]]
	for k: Variant in rows:
		var r: Dictionary = rows[k]
		lines.append("  %-11s %9.2f %9.0f %10.2f %9.2f | %6.2f" % [String(k), float(r["bps"]) / 1024.0, r["pps"], float(r["wire"]) / 1024.0,
				float(r["rx"]) / 1024.0, r["frame_mean"]])
	return "\n".join(lines)


# --- the client process --------------------------------------------------------------------------------------------------

func _run_client() -> void:
	Game.start_join("127.0.0.1", port_arg(9106), CLIENT_NAME)
	if not await wait_until(func() -> bool: return Game.local_player != null, 20.0, "joined the host and spawned"):
		finish(); return
	while not _client_finish and Game.world != null:
		await get_tree().process_frame
	check(_client_finish, "the host finished the session (not lost)")
	var errs: Array = []
	if errors != null:
		errs = Array(errors.errors)
	_rpc_client_report.rpc_id(1, {"passes": _passes, "fails": _fails, "errors": errs})
	await wait_frames(10)
	finish()


@rpc("authority", "call_remote", "reliable")
func _rpc_client_finish() -> void:
	_client_finish = true


@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_report(report: Dictionary) -> void:
	if multiplayer.is_server():
		_client_report = report
