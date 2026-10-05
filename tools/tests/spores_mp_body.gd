extends "res://tools/tests/qa_net_base.gd"
## M18 spores multi-process body (spores agent). Driven by tools/tests/spores_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): ripens Black Damp trays, decides who is fogged
##   --role=client --who=a       Alpha: harvests a ripe tray through the real request and reports what his peer shows
##   --role=client --who=b       Bravo: joins late, gets the hanging cloud and who is fogged, then walks in himself
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the client's harvest puffs on the host (cause harvest), the host fogs him and every peer agrees
## (who, how long, to a second); the client sees the cloud (same id, tray, place), his own overlay fading in and the
## low-pass on his own Master bus, his own unpositioned cough, the host's cough at the host's head and the haze on the
## host's body; the fog runs out on the host and the client's screen and bus clear after it; a late joiner gets the
## hanging cloud and the fog (Spores._rpc_sync) without a puff of his own, sees and hears the fogged workers, and is
## fogged himself when he walks in; the end of the shift clears all three peers. The canonical state agrees too.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const PARK_HOST := Vector3(-3.0, 0.0, 2.0)
const PARK_A := Vector3(-3.0, 0.0, -2.0)
const PARK_B := Vector3(-1.0, 0.0, -2.0)
## Seconds of slack when two peers' fog clocks are compared (packets, frames, a loaded machine).
const FOG_SLACK := 1.5

var role: String = "host"
var who: String = ""
var port: int = 7939
var _ids: Dictionary = {}
var _puffs: Array = []
var _master0: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7939))
	_label = "spores_mp:" + (role if role == "host" else who)
	_master0 = AudioServer.get_bus_effect_count(Spores.MASTER_BUS)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and Spores.get_instance() != null, 10.0, "host world ready, World/Spores exists")
	var spores := Spores.get_instance()
	spores.puffed.connect(func(plot_name: String, cause: StringName) -> void: _puffs.append([plot_name, cause]))
	print("SPORES_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	_put_me(PARK_HOST)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_frames(2)
	await run_cmd(a, "stand", {"pos": PARK_A}, 20.0)
	await checkpoint("on the floor", ["a"])

	step("Alpha harvests a ripe Black Damp tray")
	var p1 := _plot(1)
	_ripe(p1)
	await wait_frames(2)
	var r := await run_cmd(a, "harvest", {"plot": "GrowPlot1", "pos": p1.global_position + Vector3(-1.2, 0.0, 0.0)}, 30.0)
	check(bool(r.get("held", false)) and p1.is_empty(), "host: Alpha's request harvested GrowPlot1 (the bundle is his)")
	check(_puffs == [["GrowPlot1", Spores.CAUSE_HARVEST]], "host: it puffed, cause harvest %s" % [_puffs])
	check(spores.is_fogged(a) and spores.get_fog(a) > b.spore_fog_sec - 1.5 and GameState.get_stat(a, Spores.STAT_FOGGED) == 1,
			"host: Alpha is fogged (%.1f s), his FOGGED stat 1" % spores.get_fog(a))
	check(not spores.is_fogged(1), "host: the host, far off, is not")
	var cloud_id := spores.get_cloud_ids()[0] if spores.get_cloud_count() == 1 else -1
	_put_me(p1.global_position + Vector3(0.0, 0.0, -1.4))
	await wait_until(func() -> bool: return spores.is_fogged(1), 3.0, "host: the host walks into the hanging cloud and is fogged")
	r = await run_cmd(a, "view", {"cloud": cloud_id, "plot": "GrowPlot1", "pos": p1.global_position, "remote": [1], "fog": _fog_table(spores)}, 30.0)
	check(bool(r.get("cloud_ok", false)), "Alpha sees the cloud over GrowPlot1 (id %d, motes)" % cloud_id)
	check(r.get("puffs", []) == [["GrowPlot1", "harvest"]], "Alpha got the puff, cause harvest %s" % [r.get("puffs", [])])
	check(bool(r.get("fog_ok", false)), "Alpha's peer agrees who is fogged and for how long (%s)" % r.get("fog", ""))
	check(bool(r.get("overlay_ok", false)), "Alpha's own screen greyed (overlay %.2f)" % float(r.get("alpha", -1.0)))
	check(bool(r.get("filter_ok", false)), "Alpha's own Master bus has the low-pass (%d effects, %.0f Hz)" % [int(r.get("effects", -1)), float(r.get("cutoff", -1.0))])
	check(bool(r.get("own_cough", false)), "Alpha coughs on his own peer, unpositioned")
	check(bool(r.get("remote_ok", false)), "Alpha hears the host cough at the host's head and sees the haze on him")
	await checkpoint("both fogged", ["a"])

	step("the fog runs out; the air clears on both peers")
	_put_me(PARK_HOST)
	await run_cmd(a, "stand", {"pos": PARK_A}, 20.0)
	await wait_until(func() -> bool: return spores.get_fogged_peers().is_empty() and spores.get_cloud_count() == 0, 15.0, "host: nobody fogged, no cloud")
	r = await run_cmd(a, "clear_check", {}, 20.0)
	check(bool(r.get("ok", false)), "Alpha: no fog, no cloud, the overlay hidden, his Master bus as it was (%s)" % r.get("why", ""))

	step("a long cloud; a late joiner")
	b.spore_cloud_sec = 40.0
	b.spore_fog_sec = 40.0
	var p2 := _plot(2)
	_ripe(p2)
	await run_cmd(a, "stand", {"pos": p2.global_position + Vector3(-1.4, 0.0, 0.0)}, 20.0)
	check(spores.server_puff(p2, Spores.CAUSE_HIT) and spores.is_fogged(a) and not spores.is_fogged(1), "host: GrowPlot2 puffs on Alpha (40 s), not on the host")
	var cloud2 := spores.get_cloud_ids()[0] if spores.get_cloud_count() == 1 else -1
	await wait_sec(0.5)
	print("SPORES_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bb, "late_check", {"cloud": cloud2, "plot": "GrowPlot2", "pos": p2.global_position, "fog": _fog_table(spores), "remote": [a]}, 30.0)
	check(bool(r.get("cloud_ok", false)) and (r.get("puffs", ["?"]) as Array).is_empty(), "Bravo has the hanging cloud over GrowPlot2, without a puff of his own")
	check(bool(r.get("fog_ok", false)), "Bravo's peer agrees: Alpha fogged, for about as long (%s)" % r.get("fog", ""))
	check(bool(r.get("remote_ok", false)), "Bravo hears Alpha cough and sees the haze on him")
	check(bool(r.get("clear_self", false)), "Bravo himself: no overlay, no low-pass")
	await checkpoint("late joiner", ["a", "b"])
	r = await run_cmd(bb, "stand", {"pos": p2.global_position + Vector3(0.0, 0.0, 1.5)}, 20.0)
	await wait_until(func() -> bool: return spores.is_fogged(bb), 3.0, "host: Bravo walks into the cloud and is fogged")
	check(GameState.get_stat(bb, Spores.STAT_FOGGED) == 1, "host: Bravo's FOGGED stat 1")
	r = await run_cmd(bb, "view", {"cloud": cloud2, "plot": "GrowPlot2", "pos": p2.global_position, "remote": [a], "fog": _fog_table(spores)}, 30.0)
	check(bool(r.get("overlay_ok", false)) and bool(r.get("filter_ok", false)), "Bravo's own screen greys and his bus is muffled")
	check(bool(r.get("fog_ok", false)), "Bravo's peer agrees on everyone's fog (%s)" % r.get("fog", ""))
	r = await run_cmd(a, "agree", {"fog": _fog_table(spores), "cloud": cloud2}, 20.0)
	check(bool(r.get("fog_ok", false)) and bool(r.get("haze_b", false)), "Alpha's peer agrees and sees the haze on Bravo (%s)" % r.get("fog", ""))

	step("the end of the shift clears all three peers")
	GameState.time_left = 0.05
	await wait_until(func() -> bool: return GameState.is_round_over(), 3.0, "host: shift over")
	await wait_frames(2)
	check(spores.get_fogged_peers().is_empty() and spores.get_cloud_count() == 0 and spores.get_filter() == null, "host: clear air")
	var sa := cmd(a, "clear_check", {})
	var sb := cmd(bb, "clear_check", {})
	var ra := await await_ack(sa, 20.0)
	var rb := await await_ack(sb, 20.0)
	check(bool(ra.get("ok", false)), "Alpha: clear air (%s)" % ra.get("why", ""))
	check(bool(rb.get("ok", false)), "Bravo: clear air (%s)" % rb.get("why", ""))
	await checkpoint("end of shift", ["a", "b"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(a, "finish")
	cmd(bb, "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bb), 20.0, "both left")
	finish()


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


func _plot(i: int) -> GrowPlot:
	return Game.world.room.get_station("GrowPlot%d" % i) as GrowPlot


func _ripe(p: GrowPlot) -> void:
	p.server_reset()
	p.server_plant(&"damp")
	p.water = 1.0
	p.stage = GrowPlot.Stage.READY


func _put_me(pos: Vector3) -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)


## {peer id: seconds} of everyone fogged on the host right now.
static func _fog_table(spores: Spores) -> Dictionary:
	var out := {}
	for pid in spores.get_fogged_peers():
		out[pid] = spores.get_fog(pid)
	return out


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null and Spores.get_instance() != null, 30.0, "%s joined, World/Spores exists" % my_name):
		finish(); return
	Spores.get_instance().puffed.connect(func(plot_name: String, cause: StringName) -> void: _puffs.append([plot_name, String(cause)]))
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var spores := Spores.get_instance()
	match action:
		"stand":
			_stand(args.get("pos", Vector3.ZERO))
			await server_sees_me()
			ack(seq, {})
		"harvest":
			var plot := Game.world.room.get_station(String(args.get("plot", ""))) as GrowPlot
			_stand(args.get("pos", Vector3.ZERO))
			await server_sees_me()
			var held := false
			if plot != null:
				check(plot.get_prompt(me) == "Harvest Black Damp x1", "my prompt on the ripe tray: '%s'" % plot.get_prompt(me))
				plot.interact(me)
				held = await wait_until_quiet(func() -> bool: return me.get_held_item() is Product, 8.0)
			await sync_with_host()
			ack(seq, {"held": held})
		"view":
			ack(seq, await _view(args, true))
		"late_check":
			var info := await _view(args, false)
			info["clear_self"] = not spores.is_fogged(me.peer_id) and not spores.get_overlay_rect().visible and spores.get_filter() == null \
					and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0
			ack(seq, info)
		"agree":
			var want: Dictionary = args.get("fog", {})
			var why := [""]
			var ok := await wait_until_quiet(func() -> bool: return _fog_agrees(want, why), 5.0)
			var bb := _bravo_id()
			var haze_ok := await wait_until_quiet(func() -> bool: return bb > 0 and spores.get_haze(bb) != null, 3.0)
			ack(seq, {"fog_ok": ok, "fog": why[0], "haze_b": haze_ok})
		"clear_check":
			var why := [""]
			var ok := await wait_until_quiet(func() -> bool:
				why[0] = "fogged %s, clouds %d, overlay %s, filter %s, effects %d (was %d)" % [spores.get_fogged_peers(), spores.get_cloud_count(),
						spores.get_overlay_rect().visible, spores.get_filter() != null, AudioServer.get_bus_effect_count(Spores.MASTER_BUS), _master0]
				var hazes := 0
				for p in Game.world.get_players():
					if spores.get_haze(p.peer_id) != null:
						hazes += 1
				return spores.get_fogged_peers().is_empty() and spores.get_cloud_count() == 0 and not spores.get_overlay_rect().visible \
						and spores.get_filter() == null and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 and hazes == 0, 15.0)
			ack(seq, {"ok": ok, "why": why[0]})
		_:
			await super(seq, action, args)


## What this peer shows: the cloud, who is fogged (against the host's table), the local worker's own overlay, filter and
## cough when he is fogged, and the coughs and haze of the remote workers listed.
func _view(args: Dictionary, self_fogged: bool) -> Dictionary:
	var me: Player = Game.local_player
	var spores := Spores.get_instance()
	var info := {"puffs": _puffs.duplicate()}
	var id := int(args.get("cloud", -1))
	var plot_name := String(args.get("plot", ""))
	var pos: Vector3 = args.get("pos", Vector3.INF)
	info["cloud_ok"] = await wait_until_quiet(func() -> bool:
		var c := spores.get_cloud(id)
		if c.is_empty() or String(c["plot"]) != plot_name or not (c["pos"] as Vector3).is_equal_approx(pos):
			return false
		var node := c.get("node") as Node3D
		return node != null and node.get_node_or_null(^"Motes") is CPUParticles3D, 5.0)
	var want: Dictionary = args.get("fog", {})
	var why := [""]
	info["fog_ok"] = await wait_until_quiet(func() -> bool: return _fog_agrees(want, why), 5.0)
	info["fog"] = why[0]
	if self_fogged:
		var mine0 := spores.get_cough_count(me.peer_id)
		info["overlay_ok"] = await wait_until_quiet(func() -> bool: return spores.get_overlay_alpha() > 0.99 and spores.get_overlay_rect().visible, 3.0)
		info["alpha"] = spores.get_overlay_alpha()
		var f := spores.get_filter()
		info["effects"] = AudioServer.get_bus_effect_count(Spores.MASTER_BUS)
		info["cutoff"] = f.cutoff_hz if f != null else -1.0
		info["filter_ok"] = f != null and spores.is_filter_installed() and AudioServer.get_bus_effect_count(Spores.MASTER_BUS) == _master0 + 1 \
				and absf(f.cutoff_hz - Spores.FILTER_CUTOFF_HZ) < 1.0
		var coughed := spores.get_cough_count(me.peer_id) > mine0 or await wait_until_quiet(func() -> bool: return spores.get_cough_count(me.peer_id) > mine0, 4.5)
		info["own_cough"] = coughed and spores.get_cough_count(me.peer_id) >= 1
	var remote_ok := true
	for pid: int in (args.get("remote", []) as Array):
		var p := Game.world.get_player(pid)
		var heard0 := spores.get_cough_count(pid)
		var got_voice := [false]
		var on_cough := func(peer: int) -> void:
			if peer != pid or p == null:
				return
			var v := Sfx.get_last_voice() as AudioStreamPlayer3D
			got_voice[0] = v != null and v.stream == Sfx.get_stream(&"cough") \
					and v.global_position.distance_to(p.global_position + Vector3.UP * Spores.COUGH_HEAD_HEIGHT) < 0.6
		spores.coughed.connect(on_cough)
		var heard := await wait_until_quiet(func() -> bool: return spores.get_cough_count(pid) > heard0 and got_voice[0], 5.0)
		spores.coughed.disconnect(on_cough)
		var haze := spores.get_haze(pid)
		var haze_ok := haze != null and p != null and haze.get_parent() == p.visual
		if not heard or not haze_ok:
			remote_ok = false
			print("      remote %d: heard %s (voice %s), haze %s" % [pid, heard, got_voice[0], haze_ok])
	info["remote_ok"] = remote_ok
	return info


## True when this peer's fog matches the host's table: the same workers, each within FOG_SLACK seconds.
func _fog_agrees(want: Dictionary, why: Array) -> bool:
	var spores := Spores.get_instance()
	var mine := spores.get_fogged_peers()
	var keys: Array[int] = []
	for k: Variant in want:
		keys.append(int(k))
	keys.sort()
	why[0] = "host %s, here %s" % [want, _here(spores)]
	if mine != keys:
		return false
	for k: Variant in want:
		if absf(spores.get_fog(int(k)) - float(want[k])) > FOG_SLACK:
			return false
	return true


func _here(spores: Spores) -> Dictionary:
	var out := {}
	for pid in spores.get_fogged_peers():
		out[pid] = snappedf(spores.get_fog(pid), 0.1)
	return out


func _bravo_id() -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES["b"]:
			return int(id)
	return 0


func _stand(pos: Vector3) -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
