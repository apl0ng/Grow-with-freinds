extends "res://tools/tests/smoke_base.gd"
## M11 lead suite: LAN discovery (Lan autoload + the menu's "Floors open nearby" list) on one headless process.
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/lan_body.gd --port=7851

const MENU_SCENE := "res://scenes/main_menu/main_menu.tscn"

var _changes: int = 0


func _run() -> void:
	_label = "lan"
	await get_tree().process_frame
	Lan.games_changed.connect(func() -> void: _changes += 1)

	step("listen")
	var err: Error = Lan.listen()
	check(err == OK or err == ERR_ALREADY_IN_USE or err == ERR_CANT_CREATE, "listen() returns OK or a bind error (%s)" % error_string(err))
	var can_listen := err == OK
	check(Lan.is_listening() == can_listen, "is_listening matches")
	check(Lan.get_games().is_empty(), "no games before any beacon")

	step("validation (injected beacons)")
	check(not Lan.debug_inject_beacon("10.0.0.5", "not json"), "garbage text dropped")
	check(not Lan.debug_inject_beacon("10.0.0.5", {"gwf": 2, "port": 7777}), "wrong magic dropped")
	check(not Lan.debug_inject_beacon("10.0.0.5", {"gwf": 1, "port": 80}), "port below 1024 dropped")
	check(not Lan.debug_inject_beacon("10.0.0.5", {"gwf": 1, "port": "7777"}), "string port dropped")
	check(not Lan.debug_inject_beacon("nope", {"gwf": 1, "port": 7777}), "bad ip dropped")
	check(not Lan.debug_inject_beacon("10.0.0.5", "x".repeat(600)), "oversized payload dropped")
	check(Lan.get_games().is_empty(), "nothing recorded from the garbage")
	var before := _changes
	check(Lan.debug_inject_beacon("10.0.0.5", {"gwf": 1, "port": 7777, "name": "Ma​rge\u0001!", "players": 2, "max": 4}), "valid beacon accepted")
	var games := Lan.get_games()
	check(games.size() == 1 and games[0]["ip"] == "10.0.0.5" and games[0]["port"] == 7777, "one game listed with ip + port")
	check(games.size() == 1 and games[0]["name"] == Net.sanitize_name("Ma​rge\u0001!"), "name sanitized like a player name")
	check(games.size() == 1 and games[0]["players"] == 2 and games[0]["max"] == 4, "player counts kept")
	check(_changes == before + 1, "games_changed emitted once for a new entry")
	check(Lan.debug_inject_beacon("10.0.0.5", {"gwf": 1, "port": 7777, "name": "Marge", "players": 2, "max": 4}), "refresh accepted")
	check(Lan.get_games().size() == 1, "refresh does not duplicate")
	check(Lan.debug_inject_beacon("127.0.0.1", {"gwf": 1, "port": 7777, "name": "Marge", "players": 2, "max": 4}), "loopback twin accepted")
	check(Lan.get_games().size() == 1 and Lan.get_games()[0]["ip"] == "10.0.0.5", "a loopback twin of a LAN entry is hidden from the list")
	for i in 40:
		Lan.debug_inject_beacon("10.0.1.%d" % (i + 1), {"gwf": 1, "port": 7777, "name": "H%d" % i})
	check(Lan.get_games().size() <= Lan.MAX_PEERS_LISTED, "list capped at MAX_PEERS_LISTED (%d)" % Lan.get_games().size())

	step("menu list")
	var menu: Node = (load(MENU_SCENE) as PackedScene).instantiate()
	get_tree().root.add_child(menu)
	await wait_frames(3)
	var list: ItemList = menu.get_node_or_null("%LanList")
	check(list != null, "menu has a %LanList")
	if list != null:
		await wait_until(func() -> bool: return list.item_count >= 1, 2.0, "menu lists the injected games")
		var caption: Label = menu.get_node_or_null("%LanCaption")
		check(caption != null and caption.visible, "caption shown")
		# Picking an entry fills the address fields.
		var idx := -1
		for i in list.item_count:
			if String(list.get_item_metadata(i).get("ip", "")) == "10.0.0.5":
				idx = i
		check(idx >= 0, "the injected host is in the list")
		if idx >= 0:
			list.select(idx)
			list.item_selected.emit(idx)
			await wait_frames(1)
			var ip_edit: LineEdit = menu.get_node("%IpEdit")
			var port_spin: SpinBox = menu.get_node("%PortSpin")
			check(ip_edit.text == "10.0.0.5" and int(port_spin.value) == 7777, "selecting fills ip + port")

	step("expiry")
	# Age every entry past EXPIRE_SEC by injecting nothing and skipping time: the clock only moves with frames,
	# so shorten the wait by nudging the internal clock (test-only, documented in lan.gd as _clock).
	Lan._clock += Lan.EXPIRE_SEC + 1.0
	await wait_frames(2)
	check(Lan.get_games().is_empty(), "entries expire after EXPIRE_SEC")
	if list != null:
		await wait_until(func() -> bool: return list.item_count == 0, 2.0, "menu list empties on expiry")
	menu.queue_free()
	await wait_frames(2)

	step("real beacon from a host on this machine")
	if can_listen:
		# The menu stopped the listener when it left the tree (as in the game); listen again for this part.
		check(Lan.listen() == OK, "listen again after the menu closed")
		Game.start_host("Tester", port_arg(7851))
		await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "hosting")
		await wait_until(func() -> bool:
			for g in Lan.get_games():
				if int(g["port"]) == port_arg(7851) and String(g["name"]) == "Tester":
					return true
			return false, 4.0, "the host's beacon arrives on the local listener (127.0.0.1)")
		check(int(Lan.last_beacon.get("port", 0)) == port_arg(7851) and int(Lan.last_beacon.get("players", 0)) == 1, "beacon carries the game port and the player count")
		Game.return_to_menu()
		await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 3.0, "back to MENU")
		check(Lan.last_beacon.is_empty() or not Net.is_host, "beacon stops when not hosting")
	else:
		step("skipping the real-beacon part: the discovery port is taken on this machine")
	Lan.stop_listening()
	check(not Lan.is_listening() and Lan.get_games().is_empty(), "stop_listening clears everything")
	finish()
