extends "res://tools/tests/qa_base.gd"
## Review 9.1 (core/net/flow) regression suite, single process on a real ENet host:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/review_core_body.gd --port=7974
## Pins behaviour the other suites do not cover:
##   R1  MENU state is inert: host-only requests, Game lookups and the UI lock with no session
##   R2  Game.return_to_menu() message precedence inside one frame ("A" then "" keeps "A"; "" then "B" shows "B"),
##       and a start_host() issued in the same frame cancels a pending return (the new session survives)
##   R3  session lifecycle: host -> shift running -> local player holding a can with the supply window open ->
##       return_to_menu, three times: no leaked nodes / objects / orphans, no stray root children, stable signal
##       connection counts on the autoloads, no UI lock left, GameState back to MENU, Net offline, registry empty
##   R4  Net.sanitize_name (applied by the host to every name a peer registers with): invisible / formatting /
##       line-break characters are removed (no blank names, no look-alike duplicates that dodge "Bob 2", no BiDi
##       overrides flipping everyone's toasts, no multi-line names), ordinary names are unchanged, and the cost is
##       bounded for huge inputs (it used to be quadratic: a 200k-character name took seconds on the host)
## Every engine/script error fails the run unless announced (qa_base.gd).

const CYCLES := 3

var port: int = 7974

func _run() -> void:
	_label = "review_core"
	port = port_arg(7974)
	await get_tree().process_frame
	Config.growth_speed_override = 0.0
	await _r1_menu_inert()
	await _r2_menu_messages()
	await _r3_lifecycle()
	_r4_names()
	finish()

# ================================================================================================= R1

func _r1_menu_inert() -> void:
	step("R1: MENU state is inert")
	check(GameState.phase == GameState.Phase.MENU and not Net.is_online(), "starts in MENU, offline")
	GameState.request_start_round()
	GameState.request_next_round()
	GameState.request_retry()
	check(GameState.phase == GameState.Phase.MENU and not GameState.is_local_host(), "host-only requests do nothing without a session")
	check(Game.world == null and Game.local_player == null and Game.get_player(1) == null, "no world, no players")
	check(not Game.is_ui_locked(), "no UI lock in the menu")

# ================================================================================================= R2

func _menu_status() -> String:
	var m := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	return String(m.call("get_status")) if m != null else "<no menu>"

func _r2_menu_messages() -> void:
	step("R2: return_to_menu message precedence, start_host cancels a pending return")
	check(Game.start_host("Reviewer", port) == OK, "host")
	await wait_frames(3)
	Game.return_to_menu("Host disconnected")
	Game.return_to_menu("")
	await wait_frames(3)
	check(Game.world == null and _menu_status() == "Host disconnected", "'A' then '' in one frame -> menu shows 'A' (%s)" % _menu_status())
	check(Game.start_host("Reviewer", port) == OK, "host again")
	await wait_frames(3)
	Game.return_to_menu("")
	Game.return_to_menu("Server is full")
	await wait_frames(3)
	check(Game.world == null and _menu_status() == "Server is full", "'' then 'B' in one frame -> menu shows 'B' (%s)" % _menu_status())
	check(Game.start_host("Reviewer", port) == OK, "host a third time")
	await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 5.0, "world, player, starting cans")
	Game.return_to_menu("should be cancelled")
	# A world is live, so start_host tears it down itself (no menu involved) and must cancel the queued return.
	check(Game.start_host("Reviewer", port + 1) == OK, "start_host in the same frame as a pending return")
	await wait_until(func(): return Game.local_player != null, 5.0, "new session's player")
	await wait_frames(6) # past the deferred return and the Well's two-frame can reset
	check(Game.world != null and Net.is_host and GameState.phase == GameState.Phase.WAITING, "the pending return was cancelled: still hosting, WAITING")
	check(items_of(Const.ITEM_WATERING_CAN).size() == Config.balance.starting_watering_cans, "exactly %d starting cans (no double spawn)" % Config.balance.starting_watering_cans)
	check(GameState.is_local_host() and Net.players.size() == 1, "local host, registry of one")
	Game.return_to_menu()
	await wait_frames(3)
	check(Game.world == null and GameState.phase == GameState.Phase.MENU, "back in the menu")

# ================================================================================================= R3

func _counts() -> Dictionary:
	return {
		"nodes": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"objects": int(Performance.get_monitor(Performance.OBJECT_COUNT)),
		"orphans": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	}

func _connection_counts() -> Dictionary:
	var out := {}
	for a: Object in [Net, Game, GameState, Story, multiplayer]:
		var n := 0
		for sig in a.get_signal_list():
			n += a.get_signal_connection_list(sig["name"]).size()
		out[str(a.get(&"name")) if a is Node else "multiplayer"] = n
	return out

func _root_children() -> Array:
	var out := []
	for c in get_tree().root.get_children():
		if not c.is_queued_for_deletion():
			out.append(str(c.name))
	return out

func _r3_lifecycle() -> void:
	step("R3: session lifecycle leaves nothing behind (%d cycles)" % CYCLES)
	var base_counts := {}
	var base_conns := {}
	var base_children := []
	for cycle in CYCLES:
		check(Game.start_host("Reviewer", port) == OK, "cycle %d: host" % cycle)
		if not await wait_until(func(): return Game.local_player != null and items_of(Const.ITEM_WATERING_CAN).size() == 2, 5.0, "cycle %d: world ready" % cycle):
			return
		GameState.request_start_round()
		var can: Item = items_of(Const.ITEM_WATERING_CAN)[0]
		Game.world.items.server_give_item(can, 1)
		var shop: ShopCounter = station("ShopCounter")
		stand_near(shop, 1.2)
		await wait_frames(3)
		shop.open_shop_for(Game.local_player)
		await wait_frames(3)
		check(GameState.is_playing() and Game.local_player.get_held_item() == can and Game.is_ui_locked(), "cycle %d: shift running, can in hand, supply window open" % cycle)
		Game.return_to_menu("cycle %d over" % cycle)
		await wait_frames(4)
		check(Game.world == null and Game.local_player == null and not Game.is_ui_locked(), "cycle %d: world gone, no UI lock" % cycle)
		check(GameState.phase == GameState.Phase.MENU and GameState.money == 0 and not GameState.is_local_host(), "cycle %d: GameState back to MENU" % cycle)
		check(not Net.is_online() and Net.players.is_empty() and not Net.is_host, "cycle %d: Net offline, registry empty" % cycle)
		check(_menu_status() == "cycle %d over" % cycle, "cycle %d: menu shows the message" % cycle)
		var counts := _counts()
		var conns := _connection_counts()
		var children := _root_children()
		if cycle == 0:
			base_counts = counts
			base_conns = conns
			base_children = children
			check(counts["orphans"] == 0, "cycle 0: no orphan nodes (%d)" % counts["orphans"])
		else:
			check(counts["nodes"] == base_counts["nodes"] and counts["orphans"] == 0, "cycle %d: node count stable (%d vs %d), no orphans" % [cycle, counts["nodes"], base_counts["nodes"]])
			# A handful of engine-internal objects (cached resources, RIDs) may come and go; a leak grows every cycle.
			check(absi(counts["objects"] - base_counts["objects"]) <= 8, "cycle %d: object count stable (%d vs %d)" % [cycle, counts["objects"], base_counts["objects"]])
			check(conns == base_conns, "cycle %d: autoload signal connections stable %s" % [cycle, conns])
			check(children == base_children, "cycle %d: root children unchanged %s" % [cycle, children])

# ================================================================================================= R4

static func u(code: int) -> String:
	return String.chr(code)

static func codes(s: String) -> String:
	var out: PackedStringArray = []
	for ch in s:
		out.append("U+%04X" % ch.unicode_at(0))
	return " ".join(out)

func _r4_names() -> void:
	step("R4: Net.sanitize_name strips invisible characters and has a bounded cost")
	# Ordinary names are unchanged (trim + clamp to MAX_NAME_LENGTH, fallback "Worker").
	var same := {"  Alice  ": "Alice", "Zo" + u(0xEB): "Zo" + u(0xEB), "E" + u(0x301) + "mile": "E" + u(0x301) + "mile",
		u(0x5C71) + u(0x7530): u(0x5C71) + u(0x7530), "Bob Smith": "Bob Smith", "x".repeat(40): "x".repeat(Net.MAX_NAME_LENGTH),
		u(0x1F331) + "Bud": u(0x1F331) + "Bud", "": "Worker", "   ": "Worker", "Bob\tthe\nBuilder": "BobtheBuilder"}
	for raw: String in same:
		check(Net.sanitize_name(raw) == same[raw], "ordinary name %s -> %s (got %s)" % [raw.c_escape(), String(same[raw]).c_escape(), Net.sanitize_name(raw).c_escape()])
	# Names that render as nothing fall back to "Worker".
	for raw: String in [u(0x200B) + u(0x200B), u(0xA0) + u(0x3000), u(0xFEFF), u(0x2066) + u(0x2069), u(0x202E), u(0x85) + u(0x2028)]:
		var got := Net.sanitize_name(raw)
		check(got == "Worker", "invisible-only name [%s] -> 'Worker' (got [%s])" % [codes(raw), codes(got)])
	# Formatting / line-break characters inside a name are removed.
	for raw: String in [u(0x202E) + "Bob", "Bo" + u(0x2028) + "b", "Bo" + u(0x85) + "b", "Bob" + u(0x200B), u(0x2067) + "Bob" + u(0x2069),
			"B" + u(0xAD) + "ob", u(0xE0042) + "Bob"]:
		var got2 := Net.sanitize_name(raw)
		check(got2 == "Bob", "[%s] -> 'Bob' (got [%s])" % [codes(raw), codes(got2)])
	check(Net.sanitize_name("Bob" + u(0xA0) + "Smith") == "Bob Smith" and Net.sanitize_name(u(0x3000) + "Bob" + u(0x2003)) == "Bob",
		"Unicode spaces become plain spaces (and are trimmed at the edges)")
	# Look-alike duplicates no longer dodge the uniqueness rule.
	var taken := {1: {"name": "Bob"}}
	check(Net._unique_name(Net.sanitize_name("Bob" + u(0x200B)), taken) == "Bob 2", "'Bob'+ZWSP next to 'Bob' becomes 'Bob 2'")
	# Bounded cost: the host runs this on the first registration any connected peer sends.
	for raw: String in ["a".repeat(200000), u(0x200B).repeat(200000), " ".repeat(200000) + "Bob"]:
		var t0 := Time.get_ticks_usec()
		var got3 := Net.sanitize_name(raw)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		check(ms < 50.0 and got3.length() <= Net.MAX_NAME_LENGTH, "200k-character name [%s...] sanitized in %.1f ms (< 50 ms) -> %s" % [codes(raw.left(1)), ms, got3.c_escape()])
