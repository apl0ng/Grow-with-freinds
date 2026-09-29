extends "res://tools/tests/qa_net_base.gd"
## Shared half of the M10 4-player QA body (tools/tests/qa_m10_4p_body.gd extends this): per-peer signal records,
## the "report" dictionaries the host compares across peers, the client-side command set (same-frame throws /
## shoves / floods, positioning with aim + crouch, voice bursts, back-room checks, late-join checks, the fuse reset,
## leave + re-join) and the shift bot used by the full --fast shift. Every process of one run executes the same
## body script, so the RPC config on /root/TestBody matches (qa_net_base).

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo", "c": "Charlie"}
## Pushes the event scheduler out of reach while the deterministic cases run.
const FAR_AWAY := 100000.0
const LATE_JOIN_LIMIT_MS := 2000
const SPECTATOR_NAME := "SpectatorCamera"

var role: String = "host"
var who: String = ""
var port: int = 7960

# --- records (every peer) ---
var _written: Array = []       # [peer, reason, count]
var _backroom_ev: Array = []   # [peer, active]
var _staggers: Array = []      # [target peer, by peer]
var _ev_started: Array = []    # [kind, params]
var _ev_ended: Array = []      # [kind]
var _power_ev: Array = []      # [on]
var _chat: Dictionary = {}     # sender -> Array[String]
var _pings: Dictionary = {}    # sender -> int
var _speak_ev: Array = []      # [peer, speaking]
var _host_left_seen: bool = false
var _spawn_msec: int = -1
var _voice_bursting: bool = false
var _bot_done: Dictionary = {}


func _ready() -> void:
	super()
	GameState.worker_written_up.connect(func(p: int, r: String, c: int) -> void: _written.append([p, r, c]))
	GameState.backroom_changed.connect(func(p: int, a: bool) -> void: _backroom_ev.append([p, a]))
	Events.event_started.connect(func(k: StringName, p: Dictionary) -> void: _ev_started.append([k, p]))
	Events.event_ended.connect(func(k: StringName) -> void: _ev_ended.append([k]))
	Events.power_changed.connect(func(on: bool) -> void: _power_ev.append([on]))
	Comms.chat_received.connect(_on_chat)
	Comms.ping_received.connect(func(p: int, _pos: Vector3) -> void: _pings[p] = int(_pings.get(p, 0)) + 1)
	Voice.speaking_changed.connect(func(p: int, s: bool) -> void: _speak_ev.append([p, s]))
	Game.world_ready.connect(_on_world_ready)
	Game.local_player_spawned.connect(func(_p: Player) -> void: _spawn_msec = Time.get_ticks_msec())
	multiplayer.server_disconnected.connect(func() -> void: _host_left_seen = true)


func _on_chat(p: int, text: String) -> void:
	if not _chat.has(p):
		_chat[p] = []
	(_chat[p] as Array).append(text)


## Every Player node that enters this world reports its staggers (targets and who did it), late joiners included.
func _on_world_ready(w: World) -> void:
	if w == null or not is_instance_valid(w) or w.players_root == null:
		return
	for c in w.players_root.get_children():
		_hook_player(c)
	w.players_root.child_entered_tree.connect(_hook_player)


func _hook_player(node: Node) -> void:
	var p := node as Player
	if p == null or p.has_meta(&"qam10_hooked"):
		return
	p.set_meta(&"qam10_hooked", true)
	p.staggered.connect(func(by: int) -> void: _staggers.append([p.peer_id, by]))


# =================================================================================================== lookups

func _boss() -> ShopkeeperNPC:
	if Game.world == null or not is_instance_valid(Game.world) or Game.world.room == null:
		return null
	var counter := Game.world.room.get_station("ShopCounter")
	return counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC if counter != null else null


func _hud() -> HUD:
	if Game.world == null or not is_instance_valid(Game.world):
		return null
	return Game.world.get_node_or_null(^"HUD") as HUD


func _count_named(root: Node, node_name: String) -> int:
	if root == null or not is_instance_valid(root):
		return 0
	var n := 0
	for c in root.find_children(node_name, "", true, false):
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _count_class(root: Node, klass: String) -> int:
	if root == null or not is_instance_valid(root):
		return 0
	var n := 0
	for c in root.find_children("*", klass, true, false):
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _voice_out_count() -> int:
	if Game.world == null or not is_instance_valid(Game.world):
		return 0
	var root := Game.world.get_node_or_null(^"VoiceOut")
	if root == null:
		return 0
	var n := 0
	for c in root.get_children():
		if not c.is_queued_for_deletion():
			n += 1
	return n


func _current_camera_name() -> String:
	var cam := get_viewport().get_camera_3d()
	return String(cam.name) if cam != null else ""


func _count_written(peer: int, reason: String) -> int:
	var n := 0
	for e in _written:
		if int(e[0]) == peer and (reason == "" or String(e[1]) == reason):
			n += 1
	return n


func _stagger_count(target: int) -> int:
	var n := 0
	for e in _staggers:
		if int(e[0]) == target:
			n += 1
	return n


## Deterministic one-line form of GameState.stats (identical bits expected on every peer).
static func _stats_sig() -> String:
	var rows: PackedStringArray = []
	for pk in GameState.stats.keys():
		var row: Dictionary = GameState.stats[pk]
		var keys := row.keys()
		keys.sort()
		var kv: PackedStringArray = []
		for k in keys:
			kv.append("%s=%d" % [k, int(row[k])])
		rows.append("%d{%s}" % [int(pk), ",".join(kv)])
	rows.sort()
	return ";".join(rows)


static func _backroom_sig() -> String:
	var rows: PackedStringArray = []
	for pk in GameState.backroom.keys():
		rows.append("%d=%.2f" % [int(pk), float(GameState.backroom[pk])])
	rows.sort()
	return ";".join(rows)


## Everything the host compares across peers, in plain types (RPC-safe).
func _report() -> Dictionary:
	var hud := _hud()
	var boss := _boss()
	var room: Room = Game.world.room if Game.world != null and is_instance_valid(Game.world) else null
	var fuse: FuseBox = room.get_station("FuseBox") as FuseBox if room != null else null
	var speaking: Array = []
	for p in Voice.get_speaking_peers():
		speaking.append(int(p))
	return {
		"power": Events.is_power_on(),
		"room_power": room.is_power_on() if room != null else true,
		"active": String(Events.active_event),
		"params": Events.get_event_params(),
		"time_left": Events.get_event_time_left(),
		"walking": boss != null and boss.is_walking(),
		"banner": hud.get_event_text() if hud != null else "",
		"backroom": _backroom_sig(),
		"stats": _stats_sig(),
		"phase": GameState.phase,
		"written": _written.duplicate(true),
		"staggers": _staggers.size(),
		"locked": Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM),
		"any_lock": Game.is_ui_locked(),
		"overlay": hud != null and hud.back_room.is_open(),
		"spectator": _count_named(Game.world, SPECTATOR_NAME),
		"voice_out": _voice_out_count(),
		"rat": room != null and room.get_node_or_null(^"Rat") != null and not room.get_node(^"Rat").is_queued_for_deletion(),
		"pings": _count_class(Game.world, "PingMarker"),
		"items": Game.world.items.get_items().size() if Game.world != null else -1,
		"voice": Voice.get_stats(),
		"speaking": speaking,
		"fuse_tripped": fuse != null and fuse.is_tripped(),
		"camera": _current_camera_name(),
		"round_end": hud != null and hud.round_end.visible,
	}


## Per-item view on this peer: name -> {exists, holder, flying, rest}.
func _items_report(names: Array) -> Dictionary:
	var out := {}
	for n in names:
		var it := item_named(String(n))
		out[String(n)] = {
			"exists": it != null,
			"holder": it.holder_id if it != null else -1,
			"flying": it.is_flying() if it != null else false,
			"rest": it.rest_position if it != null else Vector3.INF,
			"pos": it.global_position if it != null and it.is_inside_tree() else Vector3.INF,
		}
	return out


## Voice routing as seen here: speaker -> [attenuation_model, volume_db] of its emitter.
func _voice_routes() -> Dictionary:
	var out := {}
	for id in Net.players.keys():
		var node := Voice.get_output_node(int(id))
		if node != null:
			out[int(id)] = [int(node.attenuation_model), node.volume_db]
	return out


# =================================================================================================== movement

## Local player: stand at `pos`, turn towards `look` (flat) or `aim` (3D: yaw + head pitch), crouch or not.
func _place_local(pos: Vector3, look: Variant, aim: Variant, crouch: Variant) -> void:
	var me: Player = Game.local_player
	if me == null:
		return
	me.velocity = Vector3.ZERO
	me.global_position = pos
	var target: Variant = aim if aim is Vector3 else look
	if target is Vector3:
		var flat: Vector3 = target
		flat.y = me.global_position.y
		if flat.distance_to(me.global_position) > 0.01:
			me.look_at(flat, Vector3.UP)
		me.head.rotation.x = 0.0
		if aim is Vector3:
			var cam_pos: Vector3 = me.camera.global_position
			var d: Vector3 = (aim as Vector3) - cam_pos
			var horiz := Vector2(d.x, d.z).length()
			me.head.rotation.x = clampf(atan2(d.y, horiz), -Player.MAX_PITCH, Player.MAX_PITCH)
	if crouch is bool:
		if crouch:
			Input.action_press(&"crouch")
		else:
			Input.action_release(&"crouch")


## server_sees_me() without a recorded check (bots under load).
func _server_sees_me_quiet(tolerance: float = 0.4, timeout: float = 4.0) -> bool:
	var me: Player = Game.local_player
	if me == null or not Net.is_online():
		return false
	if multiplayer.is_server():
		await get_tree().process_frame # the host's own body: the server sees it at once
		return true
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout * 1000.0:
		_pos_seq += 1
		var seq := _pos_seq
		_rpc_where_am_i.rpc_id(1, seq)
		var t1 := Time.get_ticks_msec()
		while not _pos_replies.has(seq) and Time.get_ticks_msec() - t1 < 1500:
			await get_tree().process_frame
		if _pos_replies.has(seq):
			var last: Vector3 = _pos_replies[seq]
			_pos_replies.erase(seq)
			if me != null and is_instance_valid(me) and last.distance_to(me.global_position) <= tolerance:
				return true
		await get_tree().process_frame
	return false


# =================================================================================================== voice

func _voice_frame(phase: int, hz: float) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(Voice.FRAME_SAMPLES)
	for i in Voice.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * hz * float(i + phase * Voice.FRAME_SAMPLES) / float(Voice.SAMPLE_RATE))
	return Voice.encode_mulaw(s)


## Sends `rate` frames per second for `seconds` through the real send path. The backlog after a stalled frame is
## capped at 3 frames, so a sender never exceeds the receivers' 60/s window on purpose.
func _voice_burst(seconds: float, rate: float) -> int:
	_voice_bursting = true
	var sent := 0
	var acc := 0.0
	var t0 := Time.get_ticks_msec()
	var last := t0
	var hz := 220.0 + 40.0 * float(multiplayer.get_unique_id() % 5)
	while Time.get_ticks_msec() - t0 < seconds * 1000.0 and Net.is_online():
		await get_tree().process_frame
		var now := Time.get_ticks_msec()
		acc = minf(acc + float(now - last) * 0.001 * rate, 3.0)
		last = now
		while acc >= 1.0:
			acc -= 1.0
			Voice.debug_send_frame(_voice_frame(sent, hz))
			sent += 1
	_voice_bursting = false
	return sent


# =================================================================================================== floods

## Dirty on purpose: a control character and a zero-width space; every receiver must see "hello there".
static func _dirty_line() -> String:
	return "hello" + String.chr(0x01) + " " + String.chr(0x200B) + "there"


## 30 raw chat RPCs + 30 raw pings in one frame, hostile payloads first (bypasses the local send throttle on purpose).
func _flood() -> void:
	var me: Player = Game.local_player
	var here: Vector3 = me.global_position if me != null else Vector3.ZERO
	Comms._rpc_ping.rpc(Vector3(NAN, 0.0, 0.0))                 # never finite
	Comms._rpc_ping.rpc(here + Vector3(100.0, 0.0, 0.0))        # out of range
	var long_line := ""
	for i in 60:
		long_line += "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ!?"
	Comms._rpc_chat.rpc(long_line)                              # over CHAT_MAX_RAW_CHARS: dropped whole
	Comms._rpc_chat.rpc(String.chr(0x202E) + String.chr(0x200B) + " " + String.chr(0x2066)) # BiDi override + invisibles: sanitizes to ""
	Comms._rpc_chat.rpc(_dirty_line())                          # the one that counts: "hello there"
	for i in 29:
		Comms._rpc_chat.rpc("flood %d" % i)
	for i in 30:
		Comms._rpc_ping.rpc(here + Vector3(0.5 * float(i % 4), 0.0, 0.5))


# =================================================================================================== shift bot

## A worker's normal loop while a shift runs: buy a seed, plant `plot_index`, water it, harvest, deposit. Bounded
## waits, no recorded checks (the shift is chaos by design: write-ups, the back room, power cuts). Returns counts.
func _work_loop(plot_index: int, max_sec: float) -> Dictionary:
	var did := {"bought": 0, "planted": 0, "watered": 0, "harvested": 0, "deposited": 0, "loops": 0}
	var t_end := Time.get_ticks_msec() + int(max_sec * 1000.0)
	while GameState.is_playing() and Time.get_ticks_msec() < t_end and Game.world != null and is_instance_valid(Game.world):
		did["loops"] = int(did["loops"]) + 1
		var me: Player = Game.local_player
		if me == null or not is_instance_valid(me) or not me.is_inside_tree():
			await wait_sec(0.5)
			continue
		if GameState.is_in_backroom(me.peer_id) or me.is_stunned():
			await wait_sec(0.4)
			continue
		var p := plot(plot_index)
		var chute: TurnInStation = station("TurnInStation") as TurnInStation
		var shop: ShopCounter = station("ShopCounter") as ShopCounter
		if p == null or chute == null or shop == null:
			await wait_sec(0.5)
			continue
		var held := me.get_held_item()
		if held == null:
			if p.is_ready_to_harvest():
				if await _bot_interact(p, func() -> bool: return me.get_held_item() is Product):
					did["harvested"] = int(did["harvested"]) + 1
			elif p.is_empty():
				if GameState.money >= 20:
					stand_near(shop, 1.3)
					await _server_sees_me_quiet()
					shop.request_buy_seed(&"budget")
					if await wait_until_quiet(func() -> bool: return me.get_held_item() is SeedPacket, 2.0):
						did["bought"] = int(did["bought"]) + 1
				else:
					await wait_sec(0.6)
			elif p.is_growing() and p.water < 0.35:
				var can := _free_can()
				if can != null:
					stand_near(can, 0.7)
					await _server_sees_me_quiet()
					can.interact(me)
					await wait_until_quiet(func() -> bool: return can.holder_id == me.peer_id, 2.0)
				else:
					await wait_sec(0.6)
			else:
				await wait_sec(0.4)
		elif held is SeedPacket:
			if p.is_empty():
				if await _bot_interact(p, func() -> bool: return not p.is_empty()):
					did["planted"] = int(did["planted"]) + 1
			else:
				await _bot_drop(me)
		elif held is WateringCan:
			if p.is_growing() and p.water < 0.95 and int(held.get(&"charges")) > 0:
				var w0 := p.water
				if await _bot_interact(p, func() -> bool: return p.water > w0 + 0.01):
					did["watered"] = int(did["watered"]) + 1
			else:
				await _bot_drop(me)
		elif held is Product:
			if await _bot_interact(chute, func() -> bool: return me.get_held_item() == null):
				did["deposited"] = int(did["deposited"]) + 1
		else:
			await _bot_drop(me)
	return did


func _bot_interact(target: Interactable, done: Callable) -> bool:
	var me: Player = Game.local_player
	if me == null or target == null or not is_instance_valid(target):
		return false
	stand_near(target, 1.2)
	await _server_sees_me_quiet()
	if GameState.is_in_backroom(me.peer_id) or me.is_stunned():
		return false
	target.interact(me)
	return await wait_until_quiet(done, 2.0)


func _bot_drop(me: Player) -> void:
	if Game.world == null:
		return
	Game.world.items.request_drop()
	await wait_until_quiet(func() -> bool: return me.get_held_item() == null, 1.5)


func _free_can() -> WateringCan:
	for it in items_of(Const.ITEM_WATERING_CAN):
		var can := it as WateringCan
		if can != null and can.holder_id == 0 and not can.is_flying() and can.charges > 0:
			return can
	return null


# =================================================================================================== client

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	var err := Game.start_join("127.0.0.1", port, my_name)
	if not check(err == OK, "start_join 127.0.0.1:%d" % port):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined (local Player spawned)" % my_name):
		finish(); return
	check(Net.get_player_name(multiplayer.get_unique_id()) == my_name, "registered as %s" % my_name)
	await client_loop()
	finish()


## Same-frame actions run inside the network poll that delivered the command.
func _immediate(seq: int, action: String, args: Dictionary) -> bool:
	var t := toasts.size()
	match action:
		"throw_now":
			if Game.world != null:
				Game.world.items.request_throw()
			_queue.append([seq, "settle", {"t": t}])
			return true
		"shove_now":
			if Game.local_player != null:
				Game.local_player.request_shove(int(args.get("target", 0)))
			_queue.append([seq, "settle", {"t": t}])
			return true
		"flood":
			_flood()
			_queue.append([seq, "settle", {"t": t}])
			return true
		"say":
			Comms.say(String(args.get("text", "")))
			_queue.append([seq, "settle", {"t": t}])
			return true
		"voice_burst":
			# Fire and forget: the command queue stays free so the host can ask for reports mid-burst.
			_voice_burst(float(args.get("seconds", 4.0)), float(args.get("rate", 50.0)))
			ack(seq, {"started": true})
			return true
	return false


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	match action:
		"settle":
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(int(args.get("t", 0)))})
		"goto":
			_place_local(args.get("pos", Vector3.ZERO), args.get("look", null), args.get("aim", null), args.get("crouch", null))
			await server_sees_me()
			await wait_sec(0.3) # yaw / pitch / crouch ride on the next sync packets
			ack(seq, {"pos": me.global_position if me != null else Vector3.INF, "crouching": me != null and me.crouching})
		"report":
			ack(seq, _report())
		"wait_no_rat":
			# The flee runs on each peer's own clock: give the rat a few seconds to reach the gap and free itself.
			await wait_until_quiet(func() -> bool: return not bool(_report()["rat"]), 6.0)
			ack(seq, _report())
		"report_items":
			var rep := _report()
			rep["items_by_name"] = _items_report(args.get("names", []))
			ack(seq, rep)
		"report_player":
			var p := Game.world.get_player(int(args.get("peer", 0))) if Game.world != null else null
			var hud := _hud()
			ack(seq, {"pos": p.global_position if p != null else Vector3.INF, "exists": p != null,
					"tag": hud != null and hud.is_backroom_tag_shown(int(args.get("peer", 0)))})
		"report_voice":
			var rep := _report()
			rep["routes"] = _voice_routes()
			var hud := _hud()
			var marks := {}
			for id in Net.players.keys():
				marks[int(id)] = hud != null and hud.is_speaking_mark_shown(int(id))
			rep["marks"] = marks
			rep["speak_ev"] = _speak_ev.duplicate(true)
			ack(seq, rep)
		"report_comms":
			var hud := _hud()
			var markers := []
			for id in Net.players.keys():
				if hud != null and hud.get_ping_marker(int(id)) != null:
					markers.append(int(id))
			ack(seq, {"chat": _chat.duplicate(true), "pings": _pings.duplicate(), "markers": markers,
					"chat_lines": hud.chat.get_line_count() if hud != null else -1})
		"report_end":
			var hud := _hud()
			var rep := _report()
			var rows: Array = []
			var cells_ok := true
			if hud != null:
				for pid in hud.round_end.report.get_row_peers():
					rows.append(int(pid))
				var i := 1
				for pid in rows:
					if hud.round_end.report.get_cell_text(i, 1) != HUD.format_money(GameState.get_stat(pid, Const.STAT_DEPOSITED)):
						cells_ok = false
					if hud.round_end.report.get_cell_text(i, 5) != str(GameState.get_stat(pid, Const.STAT_WRITE_UPS)):
						cells_ok = false
					i += 1
			rep["rows"] = rows
			rep["cells_ok"] = cells_ok
			ack(seq, rep)
		"backroom_check":
			var hud := _hud()
			ack(seq, {"locked": Game.is_ui_locked_by(Const.UI_LOCK_BACKROOM), "overlay": hud != null and hud.back_room.is_open(),
					"camera": _current_camera_name(), "pos": me.global_position if me != null else Vector3.INF,
					"watching": hud.back_room.get_watched_peer() if hud != null else -1,
					"cameras": _count_named(Game.world, SPECTATOR_NAME), "own_camera": me != null and me.camera.current})
		"shove_from_behind", "shove_from_front":
			await _shove_positioned(seq, int(args.get("target", 1)), action == "shove_from_behind", 1)
		"double_shove":
			await _shove_positioned(seq, int(args.get("target", 1)), false, 2)
		"late_inspection":
			await wait_until_quiet(func() -> bool: return _spawn_msec >= 0, 5.0)
			await wait_until_quiet(func() -> bool: return Events.is_event_active(Events.EVENT_INSPECTION) and _boss() != null and _boss().is_walking(), 5.0)
			var ms := Time.get_ticks_msec() - _spawn_msec
			var rep := _report()
			rep["ms"] = ms
			check(bool(rep["walking"]), "late joiner: the Boss walks on this peer (%d ms after spawning)" % ms)
			ack(seq, rep)
		"late_power":
			await wait_until_quiet(func() -> bool: return _spawn_msec >= 0, 5.0)
			await wait_until_quiet(func() -> bool: return not Events.is_power_on() and Game.world != null and not Game.world.room.is_power_on(), 5.0)
			var ms := Time.get_ticks_msec() - _spawn_msec
			var rep := _report()
			rep["ms"] = ms
			check(not bool(rep["power"]), "late joiner: started dark (%d ms after spawning)" % ms)
			ack(seq, rep)
		"fuse_reset":
			await _fuse_reset(seq, t)
		"hostile_rpcs":
			await _hostile_rpcs(seq, int(args.get("victim", 0)), t)
		"leave_rejoin":
			await _leave_and_rejoin(float(args.get("delay", 3.0)))
			ack(seq, {"ok": Game.local_player != null})
		"work_loop":
			var did := await _work_loop(int(args.get("plot", 1)), float(args.get("max_sec", 80.0)))
			did["phase"] = GameState.phase
			ack(seq, did)
		"expect_host_leave":
			left_on_purpose = true
			await wait_until(func() -> bool: return Game.world == null, 15.0, "%s: back in the menu after the host left" % NAMES.get(who, ""))
			await wait_frames(3)
			check(_host_left_seen, "%s: server_disconnected received" % NAMES.get(who, ""))
			var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
			var status := String(menu.call("get_status")) if menu != null else ""
			check(status.contains("Host disconnected"), "%s: menu says 'Host disconnected' ('%s')" % [NAMES.get(who, ""), status])
			check_menu_clean("after the host left")
			check(not Events.is_event_active() and Events.is_power_on(), "%s: events reset after the host left" % NAMES.get(who, ""))
			check(_count_named(get_tree().root, SPECTATOR_NAME) == 0, "%s: no SpectatorCamera left" % NAMES.get(who, ""))
			_stop = true
		_:
			await super(seq, action, args)


## Stands 1.2 m behind (or in front of) `target`, faces it and shoves `presses` times in one frame.
func _shove_positioned(seq: int, target_peer: int, behind: bool, presses: int) -> void:
	var me: Player = Game.local_player
	var target: Player = Game.world.get_player(target_peer) if Game.world != null else null
	var saw := {"seen": 0, "by": -1}
	if target == null or me == null:
		check(false, "shove: no target player %d" % target_peer)
		ack(seq, {"saw": 0, "by": -1})
		return
	var cb := func(by: int) -> void:
		saw["seen"] = int(saw["seen"]) + 1
		saw["by"] = by
	target.staggered.connect(cb)
	var offset := target.get_flat_forward() * (-1.2 if behind else 1.2)
	var spot := target.global_position + offset
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(spot.x, 0.05, spot.z)
	me.look_at(Vector3(target.global_position.x, 0.05, target.global_position.z), Vector3.UP)
	me.head.rotation.x = 0.0
	await server_sees_me()
	await wait_sec(0.3)
	for i in presses:
		me.request_shove(target_peer)
	await wait_until_quiet(func() -> bool: return int(saw["seen"]) >= 1, 6.0)
	await wait_sec(0.4) # a refused second press would land in here
	await sync_with_host()
	target.staggered.disconnect(cb)
	ack(seq, {"saw": int(saw["seen"]), "by": int(saw["by"])})


func _fuse_reset(seq: int, t: int) -> void:
	var me: Player = Game.local_player
	var fuse: FuseBox = station("FuseBox") as FuseBox
	if fuse == null or me == null:
		ack(seq, {"power": Events.is_power_on(), "attempts": 0})
		return
	var spot: Vector3 = Game.world.room.get_station_access_point("FuseBox", 1.3)
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(spot.x, 0.05, spot.z)
	me.look_at(Vector3(fuse.global_position.x, 0.05, fuse.global_position.z), Vector3.UP)
	me.head.rotation.x = 0.0
	await server_sees_me()
	check(fuse.is_tripped(), "%s: the breaker is tripped" % NAMES.get(who, ""))
	var attempts := 0
	while not Events.is_power_on() and attempts < 6:
		attempts += 1
		fuse.request_reset()
		var t0 := Time.get_ticks_msec()
		while not Events.is_power_on() and Time.get_ticks_msec() - t0 < 2500:
			await get_tree().process_frame
	await wait_until_quiet(func() -> bool: return not Events.is_event_active(), 3.0)
	ack(seq, {"power": Events.is_power_on(), "attempts": attempts, "toasts": toasts_since(t),
			"ended": not _ev_ended.is_empty() and _ev_ended.back()[0] == Events.EVENT_POWER_CUT,
			"room_power": Game.world.room.is_power_on(), "tripped": fuse.is_tripped()})


## Forged / misdirected M10 requests: a shove request on someone else's node, a stagger not sent by the server, a
## cosmetic stagger from a third peer, authority-only Events / GameState RPCs, oversized and empty voice frames, a
## throw with empty hands, a fuse reset from across the room. Nothing may change; the host announces the engine's
## rejections of the authority-only calls.
func _hostile_rpcs(seq: int, victim_id: int, t: int) -> void:
	var me: Player = Game.local_player
	var victim: Player = Game.world.get_player(victim_id) if Game.world != null else null
	var host_player: Player = Game.world.get_player(1) if Game.world != null else null
	var staggers0 := _staggers.size()
	if victim != null:
		victim._rpc_request_shove.rpc_id(1, 1)                                   # not my node: ignored
		victim._rpc_stagger_fx.rpc(me.peer_id, 3.0, true)                        # I am neither the server nor the owner
	if host_player != null:
		host_player._rpc_staggered.rpc_id(1, Vector3(9.0, 0.0, 0.0), 3.0, me.peer_id, true)  # sender is not the server
	Events._rpc_power.rpc_id(1, true)                                            # authority only: rejected by the engine
	Events._rpc_event_ended.rpc_id(1, Events.EVENT_POWER_CUT)                    # authority only
	GameState._rpc_written_up.rpc_id(1, {"money": 999999}, victim_id, Const.WRITE_UP_OTHER, 1)  # authority only
	var big := PackedByteArray()
	big.resize(Voice.MAX_FRAME_BYTES + 1)
	Voice._rpc_voice.rpc(1, big)                                                 # too big: dropped on every receiver
	Voice._rpc_voice.rpc(2, PackedByteArray())                                   # empty: dropped
	Game.world.items._rpc_request_throw.rpc_id(1)                                # empty hands: ignored
	Game.world.items._rpc_request_drop.rpc_id(1)                                 # empty hands: ignored
	var fuse: FuseBox = station("FuseBox") as FuseBox
	if fuse != null:
		fuse._rpc_request_reset.rpc_id(1)                                        # across the room: "Too far."
	await sync_with_host()
	await wait_sec(0.4)
	check(not Events.is_power_on(), "%s: the power is still off here (my power RPC went nowhere)" % NAMES.get(who, ""))
	check(GameState.money < 999999, "%s: no forged cash" % NAMES.get(who, ""))
	# Even the call_local copy of the forged cosmetic stagger is refused (the sender id is mine, not the owner's).
	ack(seq, {"toasts": toasts_since(t), "local_staggers": _staggers.size() - staggers0})


func _leave_and_rejoin(delay: float) -> void:
	var my_name: String = NAMES.get(who, "Client")
	var old_id := multiplayer.get_unique_id()
	var was_in_backroom := GameState.is_in_backroom(old_id)
	left_on_purpose = true
	Game.return_to_menu()
	await wait_frames(3)
	check_menu_clean("after leaving")
	check(not Events.is_event_active() and Events.is_power_on(), "after leaving: events reset locally")
	check(_count_named(get_tree().root, SPECTATOR_NAME) == 0, "after leaving: no SpectatorCamera left (was in the back room: %s)" % was_in_backroom)
	check(int(Voice.get_stats()["peers"]) == 0 and Voice.get_speaking_peers().is_empty(), "after leaving: voice state cleared")
	await wait_sec(delay)
	left_on_purpose = false
	_spawn_msec = -1
	var err := Game.start_join("127.0.0.1", port, my_name)
	check(err == OK, "re-join started")
	if await wait_until(func() -> bool: return Game.local_player != null, 20.0, "re-joined (local Player spawned)"):
		check(multiplayer.get_unique_id() != old_id, "new peer id %d" % multiplayer.get_unique_id())
		await wait_until(func() -> bool: return Net.get_player_name(multiplayer.get_unique_id()) == my_name, 5.0, "kept my name '%s'" % my_name)
		check(not GameState.is_in_backroom(multiplayer.get_unique_id()), "re-joined on the floor, not in the back room")
