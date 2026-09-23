extends "res://tools/tests/qa_base.gd"
## Multi-process QA test base: a host "director" sends numbered commands to client processes and waits for their
## answers. Every process of one test must run the SAME body script (RPCs are matched by the node's RPC config on
## /root/TestBody). Used by qa_4p_body.gd and qa_mp_robust_body.gd.
##   host:   var info := await run_cmd(peer_id, "action", {args})     (or cmd() + await_ack() to overlap commands)
##   client: await client_loop()  -> executes queued commands through _execute() until "finish" / the host is gone
## Actions implemented here (subclasses add more by overriding _execute / _immediate and calling super):
##   state {expect, timeout, ui}   wait until canonical_state() == expect; answers {ok, state, ms[, ui_ok, ui]}
##   goto_item {item} / goto_station {station}     stand next to it (owner-authoritative move) and let it sync
##   interact {station}            station.interact(local player); answers {toasts}
##   buy {seed}                    walk to the shop, request_buy_seed(seed); answers {ok, toasts}
##   finish                        return_to_menu, check the menu state, stop the loop

const CHECK_TIMEOUT := 8.0
const ACK_TIMEOUT := 20.0

# --- host ---
var _seq: int = 0
var _acks: Dictionary = {}          # seq -> Dictionary

# --- client ---
var _pos_seq: int = 0
var _pos_replies: Dictionary = {}   # seq -> Vector3 (host's view of our Player)
var _queue: Array = []              # [seq, action, args]
var _stop: bool = false
## True while this client is intentionally out of a session (leaving, re-joining): the loop does not fail.
var left_on_purpose: bool = false

# =================================================================================================== host side

func cmd(peer: int, action: String, args: Dictionary = {}) -> int:
	_seq += 1
	_rpc_cmd.rpc_id(peer, _seq, action, args)
	return _seq

func await_ack(seq: int, timeout: float = ACK_TIMEOUT) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while not _acks.has(seq) and Time.get_ticks_msec() - t0 < timeout * 1000.0:
		await get_tree().process_frame
	if not _acks.has(seq):
		check(false, "no answer to command #%d within %.0f s" % [seq, timeout])
		return {}
	return _acks[seq]

func run_cmd(peer: int, action: String, args: Dictionary = {}, timeout: float = ACK_TIMEOUT) -> Dictionary:
	return await await_ack(cmd(peer, action, args), timeout)

## Every listed peer must converge to the host's canonical state (ui=true: HUD / overlays must agree too).
## `names` maps peer id -> label for messages.
func checkpoint_peers(tag: String, peers: Array, names: Dictionary = {}, ui: bool = false) -> void:
	var expect := canonical_state()
	var seqs := {}
	for p in peers:
		seqs[p] = cmd(int(p), "state", {"expect": expect, "timeout": CHECK_TIMEOUT, "ui": ui})
	for p in peers:
		var r := await await_ack(seqs[p], CHECK_TIMEOUT + 4.0)
		var who: String = str(names.get(p, p))
		var ok := bool(r.get("ok", false))
		check(ok, "[%s] %s sees the host state (%d ms)" % [tag, who, int(r.get("ms", -1))])
		if ui and ok:
			check(bool(r.get("ui_ok", true)), "[%s] %s UI consistent with GameState %s" % [tag, who, r.get("ui", "")])
		if not ok:
			print("      host : " + expect)
			print("      %-5s: %s" % [who, str(r.get("state", "<no answer>"))])

@rpc("any_peer", "call_remote", "reliable")
func _rpc_ack(seq: int, info: Dictionary) -> void:
	if not multiplayer.is_server():
		return
	_acks[seq] = info

# =================================================================================================== client side

## Client: after moving the local Player (owner-authoritative, streamed unreliably), wait until the HOST's copy is
## within `tolerance` m of where we stand, so the server-side range checks see the move. A fixed delay is not
## enough when the machine is loaded (observed: the host applying no position update for > 1 s under CPU
## contention). Returns false (and records a FAIL) on timeout.
func server_sees_me(tolerance: float = 0.3, timeout: float = 8.0) -> bool:
	var me: Player = Game.local_player
	if me == null or not Net.is_online():
		return false
	var t0 := Time.get_ticks_msec()
	var last := Vector3.INF
	while Time.get_ticks_msec() - t0 < timeout * 1000.0:
		_pos_seq += 1
		var seq := _pos_seq
		_rpc_where_am_i.rpc_id(1, seq)
		var t1 := Time.get_ticks_msec()
		while not _pos_replies.has(seq) and Time.get_ticks_msec() - t1 < 2000:
			await get_tree().process_frame
		if _pos_replies.has(seq):
			last = _pos_replies[seq]
			_pos_replies.erase(seq)
			if last.distance_to(me.global_position) <= tolerance:
				return true
		await get_tree().process_frame
	check(false, "the host saw our move within %.0f s (host view %s, local %s)" % [timeout, last, me.global_position])
	return false

## Client: reliable ping round trip to the host. Reliable RPCs share ENet channel 0 and arrive in order, so once the
## pong is here every answer the server sent while handling our earlier requests (denial toasts, purchase results)
## has arrived as well - no fixed sleeps that break on a loaded machine.
func sync_with_host(timeout: float = 8.0) -> bool:
	if not Net.is_online():
		return false
	_pos_seq += 1
	var seq := _pos_seq
	_rpc_where_am_i.rpc_id(1, seq)
	var t0 := Time.get_ticks_msec()
	while not _pos_replies.has(seq) and Time.get_ticks_msec() - t0 < timeout * 1000.0:
		await get_tree().process_frame
	var ok := _pos_replies.has(seq)
	_pos_replies.erase(seq)
	await wait_frames(2)
	return ok

@rpc("any_peer", "call_remote", "reliable")
func _rpc_where_am_i(seq: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var p := Game.get_player(sender)
	_rpc_you_are.rpc_id(sender, seq, p.global_position if p != null else Vector3.INF)

@rpc("authority", "call_remote", "reliable")
func _rpc_you_are(seq: int, pos: Vector3) -> void:
	_pos_replies[seq] = pos

@rpc("authority", "call_remote", "reliable")
func _rpc_cmd(seq: int, action: String, args: Dictionary) -> void:
	# Actions that must leave in the same frame as the host's command run right here, inside the network poll.
	if _immediate(seq, action, args):
		return
	_queue.append([seq, action, args])

## Override for same-frame actions: return true if handled (usually after queueing a follow-up action).
func _immediate(_seq_id: int, _action: String, _args: Dictionary) -> bool:
	return false

func client_loop() -> void:
	while not _stop:
		if _queue.is_empty():
			if Game.world == null and not left_on_purpose:
				check(false, "lost the session unexpectedly")
				break
			await get_tree().process_frame
			continue
		var c: Array = _queue.pop_front()
		await _execute(int(c[0]), String(c[1]), c[2])

func ack(seq: int, info: Dictionary) -> void:
	if Net.is_online():
		_rpc_ack.rpc_id(1, seq, info)

## Executes one command. Subclasses: handle your own actions, else `await super(seq, action, args)`.
func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	var t := toasts.size()
	match action:
		"state":
			var expect := String(args.get("expect", ""))
			var t0 := Time.get_ticks_msec()
			var ok := await wait_state(expect, float(args.get("timeout", CHECK_TIMEOUT)))
			var info := {"ok": ok, "state": canonical_state(), "ms": Time.get_ticks_msec() - t0}
			if bool(args.get("ui", false)):
				var ui := ui_report()
				info["ui_ok"] = ui == ""
				info["ui"] = ui
			if not ok:
				check(false, "state mismatch with the host")
			ack(seq, info)
		"goto_item":
			var it := item_named(String(args.get("item", "")))
			if it != null:
				stand_near(it, 0.7)
			await server_sees_me()
			ack(seq, {"ok": it != null})
		"goto_station":
			stand_near(station(String(args.get("station", ""))), float(args.get("distance", 1.2)))
			await server_sees_me()
			ack(seq, {"ok": true})
		"interact":
			var st: Interactable = station(String(args.get("station", "")))
			if st != null and me != null:
				st.interact(me)
			await sync_with_host()
			ack(seq, {"toasts": toasts_since(t)})
		"buy":
			var shop: ShopCounter = station("ShopCounter")
			stand_near(shop, 1.3)
			await server_sees_me()
			shop.request_buy_seed(StringName(String(args.get("seed", ""))))
			var got := await wait_until_quiet(func():
				var h := me.get_held_item()
				return h is SeedPacket and String(h.strain_id) == String(args.get("seed", "")), 8.0)
			ack(seq, {"ok": got, "toasts": toasts_since(t)})
		"finish":
			left_on_purpose = true
			Game.return_to_menu()
			await wait_frames(3)
			check_menu_clean("after finish")
			_stop = true
		_:
			ack(seq, {"ok": false, "error": "unknown action " + action})

func wait_state(expect: String, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout * 1000.0:
		if canonical_state() == expect:
			return true
		await get_tree().process_frame
	return canonical_state() == expect

## Like wait_until() but records no check.
func wait_until_quiet(pred: Callable, timeout_sec: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < timeout_sec * 1000.0:
		if bool(pred.call()):
			return true
		await get_tree().process_frame
	return bool(pred.call())

func item_named(item_name: String) -> Item:
	if Game.world == null or item_name == "":
		return null
	return Game.world.items.get_node_or_null(NodePath(item_name)) as Item

func toasts_since(t: int) -> Array:
	var out := []
	for i in range(t, toasts.size()):
		out.append(String(toasts[i][0]))
	return out

## "" when the HUD / overlays agree with GameState on this peer.
func ui_report() -> String:
	var bad: PackedStringArray = []
	var hud: HUD = Game.world.get_node_or_null("HUD") as HUD if Game.world != null else null
	if hud == null:
		return "no HUD"
	if hud.money_label.text != HUD.format_money(GameState.money):
		bad.append("money label '%s'" % hud.money_label.text)
	if hud.round_label.text != "ROUND %d" % GameState.round_number:
		bad.append("round label '%s'" % hud.round_label.text)
	var want_quota := "SOLD %s / %s" % [HUD.format_money(GameState.round_sales), HUD.format_money(GameState.quota)]
	if hud.quota_label.text != want_quota:
		bad.append("quota label '%s' != '%s'" % [hud.quota_label.text, want_quota])
	var over := GameState.is_round_over()
	if hud.round_end.visible != over:
		bad.append("round-end overlay visible=%s in %s" % [hud.round_end.visible, GameState.get_phase_name()])
	if Game.is_ui_locked_by(&"round_end") != over:
		bad.append("round_end ui lock=%s" % Game.is_ui_locked_by(&"round_end"))
	if over and hud.round_end.primary_button.visible != GameState.is_local_host():
		bad.append("host-only button visible=%s" % hud.round_end.primary_button.visible)
	return "; ".join(bad)

## Menu state after leaving a session. (Headless cannot observe the real mouse mode; Game's rule is: captured
## only with a world and no UI lock, so no world == mouse released.)
func check_menu_clean(tag: String) -> void:
	check(Game.world == null and Game.local_player == null, "%s: world freed" % tag)
	check(GameState.phase == GameState.Phase.MENU and GameState.money == 0, "%s: GameState back to MENU" % tag)
	check(Net.players.is_empty() and not Net.is_online(), "%s: offline, registry empty" % tag)
	check(not Game.is_ui_locked(), "%s: no UI lock left" % tag)
	var stray := []
	for c in get_tree().root.get_children():
		if (c is ShopUI or c is CanvasLayer) and not c.is_queued_for_deletion():
			stray.append(str(c.name))
	check(stray.is_empty(), "%s: no stray UI layers under the root %s" % [tag, stray])
	check(get_tree().get_first_node_in_group(Game.MENU_GROUP) != null, "%s: main menu shown" % tag)
