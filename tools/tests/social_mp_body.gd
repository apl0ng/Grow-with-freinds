extends "res://tools/tests/qa_net_base.gd"
## M23 social multi-process body (social agent). Driven by tools/tests/social_mp.sh; every process runs this script:
##   --role=host                 the director (real Game.start_host): goes down, helps Alpha up, talks
##   --role=client --who=a       Alpha: helps the host up with the real E key, forges help packets, watches and talks
##   --role=client --who=b       Bravo: joins late while the host talks
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins over the wire: a client sees the host down (the prompt "[E] Help Hosty up"), E stands the host up on the host
## (early, helped_up from Alpha, STAT_HELPED for Alpha, the host's own 2D help_up sound and camera lift, Alpha's reach
## on his body) and on Alpha (his camera dips, his reach, the host up); the host helps Alpha up (his own stun ends on his
## peer, his 2D sound, the host's reach seen there, STAT_HELPED for the host); forged packets (a client's fx for its own
## body without the host's word, a client's fx for the host's body, a request on the host's body) change nothing on the
## host; the host talks: a talk mark over the host's head on Alpha, none on Alpha's own body, gone after; Alpha talks:
## the mark over Alpha's head on the host; Bravo joins while the host talks and sees the running mark, then sees it go.

const VoiceScript := preload("res://scripts/core/voice.gd")
const NAMES := {"host": "Hosty", "a": "Alpha", "b": "Bravo"}
const HOST_AT := Vector3(-3.0, 0.0, 1.8)
const ALPHA_AT := Vector3(-3.0, 0.0, 3.0)
const BRAVO_AT := Vector3(-6.0, 0.0, 5.0)
const STUN_SEC := 5.0

var role: String = "host"
var who: String = ""
var port: int = 9202
var _ids: Dictionary = {}
## Every helped_up this peer saw: [peer helped, by_peer, the helper body reaching, the last sound player, ticks].
var _helped: Array = []
var _staggered_msec: int = 0  # when our own body was last knocked down (ticks)
var _talking: bool = false   # host: the talk loop runs
var _talk_seq: int = 0


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 9202))
	_label = "social_mp:" + (role if role == "host" else who)
	await get_tree().process_frame
	if role == "host":
		await _host_main()
	else:
		await _client_main()


## Records every Player's helped_up on this peer (now and for bodies that spawn later); our own body stops dead when it
## is knocked down (the test places the helper next to it).
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
	if p.has_meta(&"social_mp_hooked"):
		return
	p.set_meta(&"social_mp_hooked", true)
	var pid := p.peer_id
	p.helped_up.connect(func(by: int) -> void:
		var helper := Game.get_player(by)
		_helped.append([pid, by, helper != null and helper.is_helping(), Sfx.get_last_voice(), Time.get_ticks_msec()]))
	if p.is_local():
		p.staggered.connect(func(_by: int) -> void:
			p.velocity = Vector3.ZERO
			_staggered_msec = Time.get_ticks_msec())


func _helped_count(peer: int, by: int) -> int:
	var n := 0
	for h: Array in _helped:
		if int(h[0]) == peer and int(h[1]) == by:
			n += 1
	return n


func _last_helped(peer: int) -> Array:
	for i in range(_helped.size() - 1, -1, -1):
		if int(_helped[i][0]) == peer:
			return _helped[i]
	return []


static func _is_help_sound(v: Variant, two_d: bool) -> bool:
	if two_d:
		return v is AudioStreamPlayer and (v as AudioStreamPlayer).stream == Sfx.get_stream(&"help_up")
	return v is AudioStreamPlayer3D and (v as AudioStreamPlayer3D).stream == Sfx.get_stream(&"help_up")


func _frame(phase: int) -> PackedByteArray:
	var s := PackedFloat32Array()
	s.resize(VoiceScript.FRAME_SAMPLES)
	for i in VoiceScript.FRAME_SAMPLES:
		s[i] = 0.4 * sin(TAU * 220.0 * float(i + phase * VoiceScript.FRAME_SAMPLES) / float(VoiceScript.SAMPLE_RATE))
	return VoiceScript.encode_mulaw(s)


## Sends voice frames through the real send path every 20 ms while _talking (started without await).
func _talk_loop() -> void:
	while _talking and Net.is_online():
		_talk_seq += 1
		Voice.debug_send_frame(_frame(_talk_seq))
		await get_tree().create_timer(0.02).timeout


## Puts the local body at `pos` facing `yaw` (0 = -Z), a level look.
func _place_me(pos: Vector3, yaw: float) -> void:
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation = Vector3(0.0, yaw, 0.0)
	me.head.rotation.x = 0.0


## E through the input pipeline (the Interactor's _unhandled_input), after a fresh look under the crosshair.
func _press_interact() -> void:
	Game.local_player.get_interactor().refresh()
	for pressed: bool in [true, false]:
		var ev := InputEventAction.new()
		ev.action = &"interact"
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await get_tree().process_frame
	await get_tree().process_frame


# =================================================================================================== HOST

func _host_main() -> void:
	var b: BalanceConfig = Config.balance
	b.end_round_on_quota_met = false
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null, 10.0, "host world ready")
	_hook_players()
	print("SOCIAL_HOST_READY")
	if not await wait_until(func() -> bool: return _peer_named("a") > 0, 40.0, "Alpha registered"):
		finish(); return
	_ids["a"] = _peer_named("a")
	var a: int = _ids["a"]
	await wait_until(func() -> bool: return Game.world.get_player(a) != null, 10.0, "Alpha's Player node exists")
	GameState.request_start_round()
	check(GameState.is_playing(), "shift running")
	await wait_sec(0.8)
	var me: Player = Game.local_player
	var alpha: Player = Game.world.get_player(a)

	step("Alpha helps the host up (E)")
	_place_me(HOST_AT, PI)
	await run_cmd(a, "goto", {"at": ALPHA_AT, "yaw": 0.0}, 20.0)
	await wait_sec(0.3)
	Player.server_stagger(me, Vector3.FORWARD, false, 0, STUN_SEC)
	var t0 := Time.get_ticks_msec()
	check(me.is_stunned(), "host: I am down")
	var r := await run_cmd(a, "help", {"peer": 1}, 20.0)
	check(String(r.get("prompt", "")) == "[E] Help Hosty up" and bool(r.get("enabled", false)), "Alpha's prompt: '%s'" % r.get("prompt", ""))
	check(bool(r.get("slumped", false)) and bool(r.get("stood", false)), "Alpha saw the host slumped while down, and back on his feet after E")
	await wait_until(func() -> bool: return not me.is_stunned(), 4.0, "host: I am up")
	check(Time.get_ticks_msec() - t0 < int(STUN_SEC * 1000.0) - 1000, "long before the stun ran out (%d ms)" % (Time.get_ticks_msec() - t0))
	check(_helped_count(1, a) == 1, "host: helped_up(Alpha) on my body %s" % [_helped])
	var h := _last_helped(1)
	check(not h.is_empty() and bool(h[2]) and _is_help_sound(h[3], true), "host: Alpha's body reaches, my own help_up is 2D")
	check(GameState.get_stat(a, Const.STAT_HELPED) == 1 and GameState.get_stat(1, Const.STAT_HELPED) == 0, "STAT_HELPED: Alpha 1, the host 0")
	await wait_sec(0.15)
	check(me.camera.rotation.x > 0.02, "host: my camera lifts (%.3f)" % me.camera.rotation.x)
	check(bool(r.get("up", false)) and bool(r.get("helped", false)), "Alpha: the host is up on his peer, helped_up(Alpha) there")
	check(bool(r.get("reach", false)) and bool(r.get("dip", false)) and bool(r.get("sound", false)), "Alpha: his reach, his camera dip, the help_up sound at the host's body")
	await wait_sec(b.help_up_cooldown_sec)

	step("the host helps Alpha up (E)")
	await wait_until(func() -> bool: return alpha.can_be_staggered(), 8.0, "Alpha can go down")
	r = await run_cmd(a, "goto", {"at": ALPHA_AT, "yaw": 0.0}, 20.0)
	_place_me(ALPHA_AT + Vector3(0.0, 0.0, -1.2), PI)
	await wait_sec(0.3)
	var helped0 := GameState.get_stat(1, Const.STAT_HELPED)
	Player.server_stagger(alpha, Vector3.BACK, false, 1, STUN_SEC)
	t0 = Time.get_ticks_msec()
	await wait_until(func() -> bool: return alpha.is_stunned(), 3.0, "host: Alpha is down")
	await wait_sec(0.25)
	check(alpha.get_slump() >= 1.0 and alpha.visual.position.y < -0.3, "host: Alpha's body is slumped here")
	await wait_physics(2)
	var it := me.get_interactor()
	it.refresh()
	check(it.prompt_text == "[E] Help Alpha up" and it.prompt_enabled, "host: the prompt '%s'" % it.prompt_text)
	await _press_interact()
	check(GameState.get_stat(1, Const.STAT_HELPED) == helped0 + 1, "host: STAT_HELPED for the host at once")
	await wait_until(func() -> bool: return not alpha.is_stunned() and _helped_count(a, 1) == 1, 3.0, "host: Alpha's body is up here (his fx came back)")
	h = _last_helped(a)
	check(not h.is_empty() and bool(h[2]) and _is_help_sound(h[3], false), "host: my reach, the help_up sound at Alpha's body")
	r = await run_cmd(a, "helped", {"by": 1}, 20.0)
	check(bool(r.get("up", false)) and int(r.get("ms", 99999)) < int(STUN_SEC * 1000.0) - 1000, "Alpha: up on his own peer, early (%d ms after the stun)" % int(r.get("ms", -1)))
	check(bool(r.get("helped", false)) and bool(r.get("sound", false)) and bool(r.get("lift", false)), "Alpha: helped_up(host), his own help_up 2D, his camera lifts")
	check(bool(r.get("reach", false)), "Alpha: the host's body reaches on his peer")

	step("forged help packets change nothing on the host")
	await wait_sec(b.help_up_cooldown_sec)
	var n_helped := _helped.size()
	var stats := [GameState.get_stat(a, Const.STAT_HELPED), GameState.get_stat(1, Const.STAT_HELPED)]
	await wait_until(func() -> bool: return me.can_be_staggered(), 8.0, "host: I can go down again")
	Player.server_stagger(me, Vector3.FORWARD, false, 0, 2.0)
	check(me.is_stunned(), "host: I am down")
	r = await run_cmd(a, "forge", {}, 20.0)
	await wait_sec(0.3)
	check(me.is_stunned(), "host: a client's fx for my body does not stand me up")
	check(_helped.size() == n_helped, "host: no helped_up from forged fx %s" % [_helped.slice(n_helped)])
	check([GameState.get_stat(a, Const.STAT_HELPED), GameState.get_stat(1, Const.STAT_HELPED)] == stats, "host: no stat moved")
	await wait_until(func() -> bool: return not me.is_stunned(), 3.0, "host: my stun runs out on its own")

	step("the host talks: the mark over the host's head on Alpha")
	var seq := cmd(a, "watch_talk", {"peer": 1})
	_talking = true
	_talk_loop()
	await wait_sec(1.2)
	_talking = false
	r = await await_ack(seq, 15.0)
	check(bool(r.get("shown", false)) and bool(r.get("hidden", false)), "Alpha: the host's mark shows while he talks and goes after")
	check(bool(r.get("own_none", false)), "Alpha: none on his own body")
	check(me.get_talk_mark() == null, "host: no mark on my own body")

	step("Alpha talks: the mark over Alpha's head on the host")
	seq = cmd(a, "talk", {"frames": 50})
	await wait_until(func() -> bool: return alpha.is_talk_mark_shown(), 5.0, "host: Alpha's mark shows")
	await await_ack(seq, 15.0)
	await wait_until(func() -> bool: return not alpha.is_talk_mark_shown(), 3.0, "host: and goes with the silence")

	step("a late joiner sees the host talking")
	_talking = true
	_talk_loop()
	await wait_sec(0.3)
	print("SOCIAL_LATE_GO")
	if not await wait_until(func() -> bool: return _peer_named("b") > 0, 60.0, "Bravo registered"):
		_talking = false
		finish(); return
	_ids["b"] = _peer_named("b")
	var bb: int = _ids["b"]
	await wait_until(func() -> bool: return Game.world.get_player(bb) != null, 10.0, "Bravo's Player node exists")
	r = await run_cmd(bb, "watch_on", {"peer": 1}, 20.0)
	check(bool(r.get("shown", false)), "Bravo (late): the host's mark is up while the host talks")
	check(bool(r.get("own_none", false)) and not bool(r.get("alpha_shown", true)), "Bravo: none on his own body, Alpha's down (Alpha is quiet)")
	_talking = false
	r = await run_cmd(bb, "watch_off", {"peer": 1}, 20.0)
	check(bool(r.get("hidden", false)), "Bravo: and it goes when the host stops")

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


func wait_physics(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


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
		"goto":
			_place_me(args.get("at", me.global_position), float(args.get("yaw", 0.0)))
			await server_sees_me()
			ack(seq, {"ok": true})
		"help":
			var body := Game.world.get_player(int(args.get("peer", 0)))
			var down := body != null and await wait_until_quiet(func() -> bool: return body.is_stunned(), 5.0)
			check(down, "the worker is down on my peer")
			await wait_sec(0.25)
			var slumped := body != null and body.get_slump() >= 1.0 and body.visual.position.y < -0.3
			var it := me.get_interactor()
			it.refresh()
			var prompt := it.prompt_text
			var enabled := it.prompt_enabled
			var n := _helped.size()
			await _press_interact()
			var helped := body != null and await wait_until_quiet(func() -> bool: return _helped_count(body.peer_id, me.peer_id) >= 1, 3.0)
			var up := body != null and not body.is_stunned()
			var reach := false
			var sound := false
			for i in range(n, _helped.size()):
				reach = reach or bool(_helped[i][2])
				sound = sound or _is_help_sound(_helped[i][3], false)
			await wait_sec(0.12)
			var dip := me.camera.rotation.x < -0.02
			var stood := body != null and await wait_until_quiet(func() -> bool: return is_zero_approx(body.get_slump()), 1.0)
			ack(seq, {"prompt": prompt, "enabled": enabled, "slumped": slumped, "stood": stood, "up": up, "helped": helped, "reach": reach, "dip": dip, "sound": sound})
		"helped":
			var by := int(args.get("by", 0))
			var got := await wait_until_quiet(func() -> bool: return _helped_count(me.peer_id, by) >= 1, 5.0)
			var h := _last_helped(me.peer_id)
			var up := not me.is_stunned()
			await wait_sec(0.12)
			ack(seq, {"up": up, "ms": int(h[4]) - _staggered_msec if not h.is_empty() else 99999, "helped": got,
					"sound": not h.is_empty() and _is_help_sound(h[3], true), "reach": not h.is_empty() and bool(h[2]),
					"lift": me.camera.rotation.x > 0.02})
		"forge":
			var host := Game.world.get_player(1)
			me._rpc_help_up_fx.rpc(me.peer_id)               # my own body, without the host's word
			if host != null:
				host._rpc_help_up_fx.rpc(me.peer_id)         # the host's body: not mine
				host._rpc_request_help_up.rpc_id(1, me.peer_id)  # a request on the host's body
			await sync_with_host()
			ack(seq, {})
		"watch_talk":
			var body := Game.world.get_player(int(args.get("peer", 0)))
			var shown := body != null and await wait_until_quiet(func() -> bool: return body.is_talk_mark_shown(), 6.0)
			var hidden := body != null and await wait_until_quiet(func() -> bool: return not body.is_talk_mark_shown(), 6.0)
			ack(seq, {"shown": shown, "hidden": hidden, "own_none": me.get_talk_mark() == null})
		"talk":
			for i in int(args.get("frames", 40)):
				Voice.debug_send_frame(_frame(i))
				await get_tree().create_timer(0.02).timeout
			ack(seq, {})
		"watch_on":
			var body := Game.world.get_player(int(args.get("peer", 0)))
			var shown := body != null and await wait_until_quiet(func() -> bool: return body.is_talk_mark_shown(), 8.0)
			var alpha_shown := false
			for p in Game.world.get_players():
				if p.peer_id != 1 and p != me:
					alpha_shown = alpha_shown or p.is_talk_mark_shown()
			ack(seq, {"shown": shown, "own_none": me.get_talk_mark() == null, "alpha_shown": alpha_shown})
		"watch_off":
			var body := Game.world.get_player(int(args.get("peer", 0)))
			var hidden := body != null and await wait_until_quiet(func() -> bool: return not body.is_talk_mark_shown(), 6.0)
			ack(seq, {"hidden": hidden})
		_:
			await super(seq, action, args)
