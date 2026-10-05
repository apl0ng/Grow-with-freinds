extends "res://tools/tests/qa_net_base.gd"
## M18 emotes multi-process body (emotes agent). Driven by tools/tests/emotes_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): gestures itself, watches the clients' bodies
##   --role=client --who=a       Alpha: gestures with the real keys, forges requests, walks off
##   --role=client --who=b       Bravo: joins late while Alpha sits, gestures once
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: a client's gesture (the real key) plays on the host with the sound at the body and on the client
## itself (its first-person arm, its own 2D sound); the point follows the client's look on the host (pitch up, pitch
## down) and the glove points where he looks; the host's gesture plays on a client; a request for another player's body,
## a relay sent by a client and a kind that does not exist are dropped; two requests inside the cooldown start one;
## a slump lowers the client's own camera; a late joiner sees a running slump (posed); the late joiner's gesture plays on
## the other client; walking off ends the slump everywhere, and so does a shove from the host.

const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const ALPHA_AT := Vector3(-2.0, 0.0, 3.0)
const BRAVO_AT := Vector3(-2.0, 0.0, 6.0)
const HOST_AT := Vector3(4.0, 0.0, 3.0)

var role: String = "host"
var who: String = ""
var port: int = 7949
var _ids: Dictionary = {}
## Every gesture start this peer saw: [peer, kind, voice node right after its sound].
var _seen: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7949))
	_label = "emotes_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


## Records every Player's emote_started on this peer, now and for bodies that spawn later.
func _hook_players() -> void:
	var w := Game.world
	if w == null:
		return
	for p in w.get_players():
		_hook(p)
	if not w.players_root.child_entered_tree.is_connected(_on_player_node):
		w.players_root.child_entered_tree.connect(_on_player_node)


func _on_player_node(node: Node) -> void:
	if node is Player:
		_hook(node as Player)


func _hook(p: Player) -> void:
	if p.has_meta(&"emotes_mp_hooked"):
		return
	p.set_meta(&"emotes_mp_hooked", true)
	var pid := p.peer_id
	p.emote_started.connect(func(kind: int) -> void: _seen.append([pid, kind, Sfx.get_last_voice()]))


func _starts(peer: int) -> Array:
	var out := []
	for s: Array in _seen:
		if int(s[0]) == peer:
			out.append(int(s[1]))
	return out


## The 3D emote voice at `p`'s chest was the sound of its last start on this peer.
func _sound_at(p: Player) -> bool:
	for i in range(_seen.size() - 1, -1, -1):
		var s: Array = _seen[i]
		if int(s[0]) != p.peer_id:
			continue
		var v := s[2] as AudioStreamPlayer3D
		return v != null and v.stream == Sfx.get_stream(&"emote") and v.global_position.distance_to(p.get_chest_position()) < 0.3
	return false


static func _points_at_look(p: Player) -> bool:
	return p.get_emote_arm_direction().dot(p.get_look_direction()) > cos(0.25)


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null, 10.0, "host world ready")
	_hook_players()
	print("EMOTES_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(HOST_AT.x, 0.02, HOST_AT.z)
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_sec(0.5)
	var alpha: Player = Game.world.get_player(a)

	step("Alpha points (key 1) looking up: it plays here, following his look")
	var r := await run_cmd(a, "press", {"action": "emote_1", "at": ALPHA_AT, "pitch": 0.55}, 20.0)
	await wait_until(func() -> bool: return alpha.get_emote() == Player.EMOTE_POINT, 5.0, "host: Alpha points")
	check(_sound_at(alpha), "host: the emote sound played at Alpha's body")
	check(int(r.get("own", -1)) == Player.EMOTE_POINT and bool(r.get("sound2d", false)), "Alpha points on his own peer, his own sound 2D")
	check(bool(r.get("fp", false)), "Alpha sees his own point arm (view model, in view)")
	await wait_sec(0.5)
	var want := 0.55 + PI * 0.5 - Player.ARM_REST_FORWARD
	check(absf(alpha.arm_r.rotation.x - want) < 0.05 and _points_at_look(alpha), "host: the arm follows his pitch up (%.2f, want %.2f)" % [alpha.arm_r.rotation.x, want])
	await wait_until(func() -> bool: return alpha.get_emote() == Player.EMOTE_NONE, b.emote_sec + 1.0, "host: Alpha's point ends")
	await wait_sec(b.emote_cooldown_sec)
	r = await run_cmd(a, "press", {"action": "emote_1", "at": ALPHA_AT, "pitch": -0.35}, 20.0)
	await wait_until(func() -> bool: return alpha.get_emote() == Player.EMOTE_POINT, 5.0, "host: Alpha points again, looking down")
	await wait_sec(0.5)
	want = -0.35 + PI * 0.5 - Player.ARM_REST_FORWARD
	check(absf(alpha.arm_r.rotation.x - want) < 0.05 and _points_at_look(alpha), "host: the arm follows his pitch down (%.2f, want %.2f)" % [alpha.arm_r.rotation.x, want])
	await wait_until(func() -> bool: return alpha.get_emote() == Player.EMOTE_NONE, b.emote_sec + 1.0, "host: it ends")
	r = await run_cmd(a, "ended", {}, 20.0)
	check(bool(r.get("ended", false)) and not bool(r.get("fp", true)), "Alpha: ended on his peer, the arm gone")

	step("the host shrugs (key 3): it plays on Alpha")
	await _press(&"emote_3")
	check(me.get_emote() == Player.EMOTE_SHRUG, "host: I shrug")
	r = await run_cmd(a, "watch", {"peer": 1, "kind": Player.EMOTE_SHRUG}, 20.0)
	check(bool(r.get("seen", false)) and bool(r.get("sound", false)), "Alpha sees the host shrug, with the sound at the host's body")
	check(bool(r.get("posed", false)), "Alpha sees both hands out on the host's body")
	await wait_until(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, b.emote_sec + 0.5, "host: the shrug ends")

	step("forged requests are dropped")
	var host_starts := _starts(1).size()
	var alpha_starts := _starts(a).size()
	r = await run_cmd(a, "forge", {}, 20.0)
	await wait_sec(0.4)
	check(me.get_emote() == Player.EMOTE_NONE and _starts(1).size() == host_starts, "a request from Alpha for the host's body: nothing")
	check(alpha.get_emote() == Player.EMOTE_NONE and _starts(a).size() == alpha_starts, "a relay sent by Alpha and a kind that does not exist: nothing on his body here")
	check(int(r.get("own", -1)) == Player.EMOTE_NONE and int(r.get("starts", -1)) == 0, "Alpha's own peer refused his own fake relay too")

	step("two requests inside the cooldown start one")
	await wait_sec(b.emote_cooldown_sec)
	alpha_starts = _starts(a).size()
	r = await run_cmd(a, "flood", {}, 20.0)
	await wait_sec(0.4)
	check(_starts(a).size() == alpha_starts + 1 and alpha.get_emote() == Player.EMOTE_WAVE, "host: one start (a wave), the shrug dropped (%s)" % [_starts(a)])
	check(int(r.get("own", -1)) == Player.EMOTE_WAVE, "Alpha waves on his own peer")
	await wait_until(func() -> bool: return alpha.get_emote() == Player.EMOTE_NONE, b.emote_sec + 0.5, "host: the wave ends")

	step("Alpha slumps (key 4); a late joiner sees him sitting")
	await wait_sec(b.emote_cooldown_sec)
	r = await run_cmd(a, "press", {"action": "emote_4", "at": ALPHA_AT, "pitch": 0.0, "settle": 0.8}, 20.0)
	await wait_until(func() -> bool: return alpha.is_slumped(), 5.0, "host: Alpha sits down")
	check(absf(float(r.get("camera_y", 0.0)) - Player.SIT_CAMERA_Y) < 0.02, "Alpha's camera at sitting height (%.2f)" % float(r.get("camera_y", 0.0)))
	await wait_sec(b.emote_sec)
	check(alpha.is_slumped() and alpha.body_model.scale.y < 0.7, "host: still sitting after emote_sec (posed)")
	print("EMOTES_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	var bravo: Player = Game.world.get_player(bb)
	r = await run_cmd(bb, "watch", {"peer": a, "kind": Player.EMOTE_SLUMP}, 20.0)
	check(bool(r.get("seen", false)) and bool(r.get("posed", false)), "Bravo (late) sees Alpha sitting, posed")
	check(not bool(r.get("sound", true)), "the replay is silent")
	check(int(r.get("host_emote", -1)) == Player.EMOTE_NONE, "Bravo: the host is not gesturing")

	step("Bravo waves (key 2): it plays on Alpha")
	r = await run_cmd(bb, "press", {"action": "emote_2", "at": BRAVO_AT, "pitch": 0.0}, 20.0)
	await wait_until(func() -> bool: return bravo.get_emote() == Player.EMOTE_WAVE, 5.0, "host: Bravo waves")
	r = await run_cmd(a, "watch", {"peer": bb, "kind": Player.EMOTE_WAVE}, 20.0)
	check(bool(r.get("seen", false)) and bool(r.get("sound", false)) and bool(r.get("posed", false)), "Alpha sees Bravo wave (arm up, the sound at his body)")
	check(alpha.is_slumped(), "host: Alpha is still sitting")

	step("Alpha walks off: the slump ends on all three")
	r = await run_cmd(a, "walk", {}, 20.0)
	check(bool(r.get("ended_at_once", false)), "Alpha: W ends it at once on his peer")
	await wait_until(func() -> bool: return not alpha.is_slumped(), 5.0, "host: Alpha stood up")
	r = await run_cmd(bb, "watch_end", {"peer": a}, 20.0)
	check(bool(r.get("ended", false)), "Bravo: Alpha stood up")
	await wait_sec(0.5)
	check(alpha.body_model.transform.is_equal_approx(Transform3D.IDENTITY), "host: Alpha's body is back up")

	step("a shove from the host ends the next slump everywhere")
	await wait_sec(b.emote_cooldown_sec)
	r = await run_cmd(a, "press", {"action": "emote_4", "at": ALPHA_AT, "pitch": 0.0}, 20.0)
	await wait_until(func() -> bool: return alpha.is_slumped(), 5.0, "host: Alpha sits again")
	r = await run_cmd(bb, "watch", {"peer": a, "kind": Player.EMOTE_SLUMP}, 20.0)
	check(bool(r.get("seen", false)) and bool(r.get("sound", false)), "Bravo sees this one live, with the sound")
	Player.server_stagger(alpha, Vector3.RIGHT, false, 1)
	await wait_until(func() -> bool: return not alpha.is_slumped(), 5.0, "host: the shove ends it")
	r = await run_cmd(a, "ended", {}, 20.0)
	check(bool(r.get("ended", false)), "Alpha: ended on his peer")
	r = await run_cmd(bb, "watch_end", {"peer": a}, 20.0)
	check(bool(r.get("ended", false)), "Bravo: ended there too")

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


# =================================================================================================== CLIENT

func _client_main() -> void:
	var my_name: String = NAMES.get(who, "Client")
	if not check(Game.start_join("127.0.0.1", port, my_name) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "%s joined" % my_name):
		finish(); return
	_hook_players()
	await client_loop()
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	match action:
		"press":
			var at: Vector3 = args.get("at", me.global_position)
			me.velocity = Vector3.ZERO
			me.global_position = Vector3(at.x, 0.02, at.z)
			me.rotation = Vector3(0.0, 0.0, 0.0)
			me.head.rotation.x = float(args.get("pitch", 0.0))
			await server_sees_me()
			await wait_sec(0.15)
			var n := _starts(me.peer_id).size()
			await _press(StringName(String(args.get("action", ""))))
			var got := await wait_until_quiet(func() -> bool: return _starts(me.peer_id).size() > n, 5.0)
			check(got, "my gesture came back from the host")
			var voice := (_seen.back()[2] as Node) if got else null
			await wait_sec(float(args.get("settle", 0.4)))
			var arm := me.get_first_person_arm()
			var fp := arm != null and me.is_view_model_active() and me.camera.is_position_in_frustum((arm.get_node(^"Mitt") as Node3D).global_position)
			ack(seq, {"own": me.get_emote(), "sound2d": voice is AudioStreamPlayer and (voice as AudioStreamPlayer).stream == Sfx.get_stream(&"emote"),
					"fp": fp, "camera_y": me.head.position.y})
		"ended":
			var ended := await wait_until_quiet(func() -> bool: return me.get_emote() == Player.EMOTE_NONE, 5.0)
			await wait_sec(0.5)
			ack(seq, {"ended": ended, "fp": me.get_first_person_arm() != null})
		"watch":
			var peer := int(args.get("peer", 0))
			var kind := int(args.get("kind", 0))
			var body := Game.world.get_player(peer)
			var seen := body != null and await wait_until_quiet(func() -> bool: return body.get_emote() == kind, 6.0)
			await wait_sec(0.6)
			var posed := false
			if body != null:
				match kind:
					Player.EMOTE_SHRUG:
						posed = body.arm_r.rotation.z > 0.4 and body.arm_l.rotation.z < -0.4
					Player.EMOTE_WAVE:
						posed = body.arm_r.rotation.x > 1.8
					Player.EMOTE_SLUMP:
						posed = body.body_model.scale.y < 0.7 and body.name_label.position.y < 1.6
			var host := Game.world.get_player(1)
			ack(seq, {"seen": seen, "posed": posed, "sound": body != null and _sound_at(body), "host_emote": host.get_emote() if host != null else -1})
		"watch_end":
			var body := Game.world.get_player(int(args.get("peer", 0)))
			var ended := body != null and await wait_until_quiet(func() -> bool: return body.get_emote() == Player.EMOTE_NONE, 6.0)
			ack(seq, {"ended": ended})
		"forge":
			var n0 := _starts(me.peer_id).size()
			var host := Game.world.get_player(1)
			if host != null:
				host._rpc_request_emote.rpc_id(1, Player.EMOTE_WAVE)  # somebody else's body
			me._rpc_emote.rpc(Player.EMOTE_SLUMP, 0.0)              # a relay from a client (call_local: here too)
			me._rpc_request_emote.rpc_id(1, 99)                      # no such gesture
			await sync_with_host()
			await wait_sec(0.3)
			ack(seq, {"own": me.get_emote(), "starts": _starts(me.peer_id).size() - n0})
		"flood":
			me._rpc_request_emote.rpc_id(1, Player.EMOTE_WAVE)
			me._rpc_request_emote.rpc_id(1, Player.EMOTE_SHRUG)
			await sync_with_host()
			await wait_sec(0.3)
			ack(seq, {"own": me.get_emote()})
		"walk":
			Input.action_press(&"move_forward")
			for i in 2:
				await get_tree().physics_frame
			var at_once := not me.is_slumped()
			for i in 12:
				await get_tree().physics_frame
			Input.action_release(&"move_forward")
			await sync_with_host()
			ack(seq, {"ended_at_once": at_once})
		_:
			await super(seq, action, args)


## Taps an input action for the local simulation (seen by one physics frame as just pressed).
func _press(action: StringName) -> void:
	Input.action_press(action)
	for i in 2:
		await get_tree().physics_frame
	Input.action_release(action)
	await get_tree().physics_frame
