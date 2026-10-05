extends "res://tools/tests/qa_net_base.gd"
## M18 radio multi-process body (radio agent). Driven by tools/tests/radio_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): starts the shift, checks the server side
##   --role=client --who=a       Alpha: takes radio A off the shelf and talks into it (frames through the real send path)
##   --role=client --who=b       Bravo: takes radio B off the shelf and listens
##   --role=client --who=c       Carol: joins late, while Alpha is talking
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: the two radios on the shelf on every peer; both clients' pick-ups through the real request;
## Alpha's transmission (Voice.debug_send_frame: the real send path and the server relay) puts him on the radio on the
## host's word, everywhere: the host and Bravo each get one output at radio B (in Bravo's hands) and none at radio A,
## frames queued there, radio_on / radio_off at both radios, the static at radio B, RADIO in Alpha's row; Alpha's own
## peer has no radio output at all (he never hears himself) but the tag in his own row; RADIO_GAP_MS after his last
## frame it ends on every peer. Carol, joining while he talks, has both radios in the right hands, hears from the host
## that Alpha is on the radio (the late-join replay), gets her own output at radio B, the static and the tag; when he
## stops she hears it end. The canonical state agrees on every peer at every checkpoint.

const VoiceScript := preload("res://scripts/core/voice.gd")
const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo", "c": "Carol"}
const SPOTS := {"a": Vector3(-3.0, 0.0, 3.0), "b": Vector3(-6.0, 0.0, -3.0), "c": Vector3(1.0, 0.0, 2.0)}
const SHORT_TALK := 60
const LONG_TALK := 1500

var role: String = "host"
var who: String = ""
var port: int = 7937
var _ids: Dictionary = {}
var _changes: Array = []
var _talking: bool = false
var _talk_running: bool = false
var _talk_sent: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7937))
	_label = "radio_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	Voice.radio_changed.connect(func(p: int, on: bool) -> void: _changes.append([p, on]))
	if role == "host":
		await _host_main()
	else:
		await _client_main()


# =================================================================================================== HOST

func _host_main() -> void:
	Config.growth_speed_override = 0.0
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == b.starting_watering_cans, 10.0, "host world ready")
	print("RADIO_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0 and _peer_named("b") > 0, 40.0, "Alpha and Bravo registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	_ids["b"] = _peer_named("b")
	var a: int = _ids["a"]
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null and Game.world.get_player(bb) != null, 10.0, "their Player nodes exist")
	var room := Game.world.room
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(2.0, 0.02, 4.0)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_frames(2)
	var radios := items_of(Const.ITEM_RADIO)
	if not check(radios.size() == 2, "host: two radios"):
		finish(); return
	var ra := radios[0] as Radio
	var rb := radios[1] as Radio
	check(ra.global_position.distance_to(room.get_radio_slot(0, 2).origin) < 0.001 and rb.global_position.distance_to(room.get_radio_slot(1, 2).origin) < 0.001,
			"host: both on the shelf, at their slots")
	await wait_sec(0.3)
	await checkpoint("the radios on the shelf", ["a", "b"])
	var r := await run_cmd(a, "shelf_check", {"radios": [String(ra.name), String(rb.name)]}, 20.0)
	check(bool(r.get("ok", false)), "Alpha sees both radios at the slots, facing the room")

	step("Alpha and Bravo take a radio each (the real request)")
	r = await run_cmd(a, "pickup", {"radio": String(ra.name)}, 30.0)
	check(ra.holder_id == a and String(r.get("prompt", "")) == "Pick up Radio", "host: Alpha holds radio A ('%s')" % r.get("prompt", ""))
	check(String(r.get("held", "")) == "Carrying: Radio", "Alpha's HUD: '%s'" % r.get("held", ""))
	r = await run_cmd(bb, "pickup", {"radio": String(rb.name)}, 30.0)
	check(rb.holder_id == bb, "host: Bravo holds radio B")
	await checkpoint("a radio each", ["a", "b"])

	step("Alpha talks (the real send path): the host and Bravo play him at radio B")
	_changes.clear()
	var host_c0 := [ra.get_click_count(true), rb.get_click_count(true), ra.get_click_count(false), rb.get_click_count(false)]
	r = await run_cmd(a, "talk", {"frames": SHORT_TALK}, 10.0)
	check(bool(r.get("started", false)), "Alpha starts talking")
	var seq_self := cmd(a, "self_report", {"on": true})
	var seq_b := cmd(bb, "report", {"sender": a, "radio": String(rb.name), "other": String(ra.name), "on": true})
	await wait_until(func() -> bool: return Voice.is_on_radio(a) and Voice.get_radio_output_node(a, rb) != null, 10.0, "host: Alpha is on the radio, an output at radio B")
	var out := Voice.get_radio_output_node(a, rb)
	check(out != null and out.get_parent() == rb and Voice.get_radio_output_node(a, ra) == null and Voice.get_radio_output_count() == 1,
			"host: one output, a child of radio B, none at Alpha's radio")
	check(_changes.size() >= 1 and _changes[0] == [a, true], "host: radio_changed(Alpha, on) %s" % [_changes])
	check(ra.get_click_count(true) == int(host_c0[0]) + 1 and rb.get_click_count(true) == int(host_c0[1]) + 1 and rb.is_static_playing() and ra.is_sending(),
			"host: radio_on at both radios, static at B, A's lamp")
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	check(hud != null and hud.has_radio_tag(a) and not hud.has_radio_tag(bb), "host's HUD: RADIO in Alpha's row")
	var rb_report := await await_ack(seq_b, 20.0)
	check(bool(rb_report.get("on", false)) and bool(rb_report.get("out_ok", false)) and int(rb_report.get("outputs", -1)) == 1,
			"Bravo: Alpha on the radio, one output, at radio B in his hands %s" % [rb_report])
	check(int(rb_report.get("queued", 0)) > 0 and bool(rb_report.get("static_mine", false)) and not bool(rb_report.get("static_other", true)),
			"Bravo: frames queued at radio B (%d), static there, none at Alpha's" % int(rb_report.get("queued", 0)))
	check(int(rb_report.get("clicks_on_mine", 0)) == 1 and int(rb_report.get("clicks_on_other", 0)) == 1 and bool(rb_report.get("tag", false)),
			"Bravo: radio_on at both radios, RADIO in Alpha's row")
	var self_report := await await_ack(seq_self, 20.0)
	check(bool(self_report.get("on", false)) and int(self_report.get("outputs", -1)) == 0 and int(self_report.get("queued", -1)) == 0,
			"Alpha: on the radio, no radio output on his own peer (he never hears himself) %s" % [self_report])
	check(bool(self_report.get("tag", false)) and bool(self_report.get("sending", false)) and bool(self_report.get("static_other", false)),
			"Alpha: RADIO in his own row, his lamp lit, the static at Bravo's radio")
	await wait_until(func() -> bool: return not Voice.is_on_radio(a), 15.0, "host: the transmission ends after his last frame")
	await wait_frames(2)
	check(Voice.get_radio_output_count() == 0 and _changes.size() >= 2 and _changes[-1] == [a, false]
			and ra.get_click_count(false) == int(host_c0[2]) + 1 and rb.get_click_count(false) == int(host_c0[3]) + 1 and not rb.is_static_playing(),
			"host: off, radio_off at both radios, the output freed, the static stops")
	r = await run_cmd(bb, "report", {"sender": a, "radio": String(rb.name), "other": String(ra.name), "on": false}, 20.0)
	check(not bool(r.get("on", true)) and int(r.get("outputs", -1)) == 0 and int(r.get("clicks_off_mine", 0)) == 1 and not bool(r.get("static_mine", true))
			and not bool(r.get("tag", true)), "Bravo: it ended there too %s" % [r])
	r = await run_cmd(a, "self_report", {"on": false}, 20.0)
	check(not bool(r.get("on", true)) and not bool(r.get("tag", true)) and int(r.get("sent", 0)) == SHORT_TALK, "Alpha: off, no tag, %d frames sent" % int(r.get("sent", 0)))
	await checkpoint("after the transmission", ["a", "b"])

	step("a late joiner while Alpha talks")
	r = await run_cmd(a, "talk", {"frames": LONG_TALK}, 10.0)
	await wait_until(func() -> bool: return Voice.is_on_radio(a), 10.0, "host: Alpha on the radio again")
	print("RADIO_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("c") > 0, 60.0, "Carol registered"):
		cmd(a, "talk_stop")
		finish(); return
	_ids["c"] = _peer_named("c")
	var c: int = _ids["c"]
	await wait_until(func() -> bool: return Game.world.get_player(c) != null, 10.0, "Carol's Player node exists")
	r = await run_cmd(c, "late_check", {"radios": [String(ra.name), String(rb.name)], "holders": [a, bb], "sender": a}, 40.0)
	check(bool(r.get("radios_ok", false)), "Carol has both radios, A in Alpha's hands, B in Bravo's %s" % [r])
	check(bool(r.get("on", false)), "Carol hears from the host that Alpha is on the radio")
	check(bool(r.get("out_ok", false)) and int(r.get("outputs", -1)) == 1 and int(r.get("queued", 0)) > 0, "Carol plays him at radio B (one output, %d frames)" % int(r.get("queued", 0)))
	check(bool(r.get("static_b", false)) and bool(r.get("lamp_a", false)) and bool(r.get("tag", false)), "Carol: the static at B, A's lamp, RADIO in Alpha's row")
	r = await run_cmd(a, "talk_stop", {}, 30.0)
	check(int(r.get("sent", 0)) > 0, "Alpha stops talking (%d frames)" % int(r.get("sent", 0)))
	r = await run_cmd(c, "report", {"sender": a, "radio": String(rb.name), "other": String(ra.name), "on": false}, 20.0)
	check(not bool(r.get("on", true)) and int(r.get("outputs", -1)) == 0 and not bool(r.get("static_mine", true)) and not bool(r.get("tag", true)),
			"Carol: it ends there too")
	await wait_until(func() -> bool: return not Voice.is_on_radio(a), 10.0, "host: off")
	await checkpoint("the late joiner", ["a", "b", "c"])

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	for k in ["a", "b", "c"]:
		cmd(_ids[k], "finish")
	await wait_until(func() -> bool: return not Net.players.has(a) and not Net.players.has(bb) and not Net.players.has(c), 20.0, "everybody left")
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


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		finish(); return
	_stand(SPOTS.get(who, Vector3.ZERO), Vector3(0.0, 0.0, -7.0))
	await client_loop()
	_talking = false
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	match action:
		"shelf_check":
			var ok := true
			var names: Array = args.get("radios", [])
			for i in names.size():
				var r := item_named(String(names[i])) as Radio
				ok = ok and r != null and r.global_position.distance_to(Game.world.room.get_radio_slot(i, names.size()).origin) < 0.001 \
						and absf(angle_difference(r.rotation.y, PI)) < 0.001 and not r.is_held()
			ack(seq, {"ok": ok})
		"pickup":
			var r := item_named(String(args.get("radio", ""))) as Radio
			var info := {"prompt": "", "held": ""}
			if r != null:
				var at := r.global_position + Vector3(0.0, 0.0, 1.1)
				_stand(Vector3(at.x, 0.0, at.z), r.global_position)
				await server_sees_me()
				info["prompt"] = r.get_prompt(me) if r.can_interact(me) else "denied: " + r.get_denied_reason(me)
				r.interact(me)
				check(await wait_until_quiet(func() -> bool: return r.holder_id == me.peer_id, 8.0), "I hold %s" % r.name)
				var hud := Game.world.get_node_or_null(^"HUD") as HUD
				await wait_until_quiet(func() -> bool: return hud != null and hud.held_label.text == "Carrying: Radio", 3.0)
				info["held"] = hud.held_label.text if hud != null else ""
				_stand(SPOTS.get(who, Vector3.ZERO), Vector3(0.0, 0.0, -7.0))
				await server_sees_me()
			await sync_with_host()
			ack(seq, info)
		"talk":
			_talking = true
			_talk_sent = 0
			if not _talk_running:
				_talk_loop(int(args.get("frames", SHORT_TALK)))
			ack(seq, {"started": true})
		"talk_stop":
			_talking = false
			await wait_until_quiet(func() -> bool: return not _talk_running, 5.0)
			ack(seq, {"sent": _talk_sent})
		"self_report":
			var want := bool(args.get("on", true))
			var my_id := multiplayer.get_unique_id()
			if want:
				await wait_until_quiet(func() -> bool: return Voice.is_on_radio(my_id) and _talk_sent >= 15, 10.0)
			else:
				await wait_until_quiet(func() -> bool: return not _talk_running and not Voice.is_on_radio(my_id), 15.0)
			var hud := Game.world.get_node_or_null(^"HUD") as HUD
			await wait_frames(3)
			var mine := me.get_held_item() as Radio
			var other: Radio = null
			for it in items_of(Const.ITEM_RADIO):
				if it != mine:
					other = it as Radio
			ack(seq, {"on": Voice.is_on_radio(my_id), "outputs": Voice.get_radio_output_count(), "queued": int(Voice.get_radio_stats()["queued"]),
					"tag": hud != null and hud.has_radio_tag(my_id), "sending": mine != null and mine.is_sending(),
					"static_other": other != null and other.is_static_playing(), "sent": _talk_sent})
		"report":
			ack(seq, await _report(args))
		"late_check":
			var info := {"radios_ok": false, "on": false, "out_ok": false, "outputs": -1, "queued": 0, "static_b": false, "lamp_a": false, "tag": false}
			var names: Array = args.get("radios", [])
			var holders: Array = args.get("holders", [])
			var sender := int(args.get("sender", 0))
			var ok := await wait_until_quiet(func() -> bool:
				for i in names.size():
					var it := item_named(String(names[i]))
					if it == null or it.holder_id != int(holders[i]):
						return false
				return items_of(Const.ITEM_RADIO).size() == names.size(), 15.0)
			info["radios_ok"] = ok
			var ra := item_named(String(names[0])) as Radio if names.size() > 0 else null
			var rb := item_named(String(names[1])) as Radio if names.size() > 1 else null
			info["on"] = await wait_until_quiet(func() -> bool: return Voice.is_on_radio(sender), 10.0)
			if rb != null:
				await wait_until_quiet(func() -> bool: return Voice.get_radio_output_node(sender, rb) != null and int(Voice.get_radio_stats()["queued"]) > 5, 10.0)
				var out := Voice.get_radio_output_node(sender, rb)
				info["out_ok"] = out != null and out.get_parent() == rb and (ra == null or Voice.get_radio_output_node(sender, ra) == null)
				info["static_b"] = rb.is_static_playing()
			info["outputs"] = Voice.get_radio_output_count()
			info["queued"] = int(Voice.get_radio_stats()["queued"])
			info["lamp_a"] = ra != null and ra.is_sending() and ra.is_lit()
			var hud := Game.world.get_node_or_null(^"HUD") as HUD
			await wait_until_quiet(func() -> bool: return hud != null and hud.has_radio_tag(sender), 3.0)
			info["tag"] = hud != null and hud.has_radio_tag(sender)
			ack(seq, info)
		_:
			await super(seq, action, args)


## Client: what this peer sees of `sender`'s transmission at its radio `radio` (and `other`), once it is on / off.
func _report(args: Dictionary) -> Dictionary:
	var sender := int(args.get("sender", 0))
	var want := bool(args.get("on", true))
	var mine := item_named(String(args.get("radio", ""))) as Radio
	var other := item_named(String(args.get("other", ""))) as Radio
	if want:
		await wait_until_quiet(func() -> bool:
			return Voice.is_on_radio(sender) and mine != null and Voice.get_radio_output_node(sender, mine) != null and int(Voice.get_radio_stats()["queued"]) > 5, 12.0)
	else:
		await wait_until_quiet(func() -> bool: return not Voice.is_on_radio(sender) and Voice.get_radio_output_count() == 0, 15.0)
	await wait_frames(3)
	var hud := Game.world.get_node_or_null(^"HUD") as HUD
	var out := Voice.get_radio_output_node(sender, mine) if mine != null else null
	return {
		"on": Voice.is_on_radio(sender),
		"outputs": Voice.get_radio_output_count(),
		"out_ok": out != null and out.get_parent() == mine and (other == null or Voice.get_radio_output_node(sender, other) == null),
		"queued": int(Voice.get_radio_stats()["queued"]),
		"static_mine": mine != null and mine.is_static_playing(),
		"static_other": other != null and other.is_static_playing(),
		"clicks_on_mine": mine.get_click_count(true) if mine != null else -1,
		"clicks_on_other": other.get_click_count(true) if other != null else -1,
		"clicks_off_mine": mine.get_click_count(false) if mine != null else -1,
		"tag": hud != null and hud.has_radio_tag(sender),
	}


## Client: frames through the real send path every 20 ms until `frames` are out or talk_stop.
func _talk_loop(frames: int) -> void:
	_talk_running = true
	var i := 0
	while _talking and i < frames and Net.is_online():
		Voice.debug_send_frame(_frame(i))
		_talk_sent += 1
		i += 1
		await wait_sec(0.02)
	_talking = false
	_talk_running = false


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	for i in VoiceScript.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 330.0 * float(i + phase * VoiceScript.FRAME_SAMPLES) / float(VoiceScript.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)


## Client: stand at `pos` facing `look`.
func _stand(pos: Vector3, look: Vector3) -> void:
	var me: Player = Game.local_player
	if me == null:
		return
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, atan2(-(look.x - pos.x), -(look.z - pos.z)), 0.0)
	me.head.rotation.x = 0.0
