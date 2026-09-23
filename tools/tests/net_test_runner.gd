extends Node
## Headless network test logic for Net / Game / World / Player (driven by tools/tests/net_test.sh).
## Loaded at runtime by the thin SceneTree entry scripts (net_host.gd, net_client.gd, net_solo.gd) so that
## the autoload identifiers (Net, Game, Config...) resolve when this script compiles.
##
## User args: --role=host|client|solo  --scenario=pair|trio|full  --who=a|b|idle|reject  --port=N
## Every check prints "PASS: ..." or "FAIL: ...". The process exits 0 only if every check passed.
## Scenario handshakes use replicated positions (targets = room spawn points, so they stay walkable):
##   pair:  client -> CLIENT_TARGET (+crouch) ; host sees it -> host -> HOST_TARGET ; client sees it -> leaves.
##   trio:  like pair with client A, then late joiner B must see A/host at their CURRENT positions, B moves,
##          A sees B (client->client via server relay), A leaves, B sees A despawn, B leaves.
##   full:  host max_players=2, client "idle" fills it, client "reject" must be refused with "Server is full".
##   drop:  host leaves while a client is connected -> client returns to the menu with "Host disconnected".
##   nohost (client only, --who=nohost): joining a port nobody listens on returns to the menu with a message.

const POS_TOLERANCE: float = 0.2
const DEFAULT_TIMEOUT: float = 20.0

var role: String = "host"
var scenario: String = "pair"
var who: String = "a"
var port: int = 7799

var _passes: int = 0
var _failures: int = 0
var _tag: String = ""
var _signals: Dictionary = {}

func _ready() -> void:
	role = String(get_meta(&"role", Config.get_arg("role", "host")))
	scenario = String(Config.get_arg("scenario", "pair"))
	who = String(Config.get_arg("who", "a"))
	port = String(Config.get_arg("port", "7799")).to_int()
	_tag = role if role != "client" else "client:%s" % who
	_run.call_deferred()

func _run() -> void:
	# Safety net: never hang forever even if a wait is buggy.
	get_tree().create_timer(80.0, true).timeout.connect(func() -> void:
		_fail("global test timeout")
		_finish())
	_track_signals()
	match role:
		"solo":
			await _run_solo()
		"host":
			await _run_host()
		"client":
			await _run_client()
		_:
			_fail("unknown role " + role)
	_finish()

# --- Targets (derived from the room's spawn points so they are always walkable) --------------------------------

func _spawn_point(index: int) -> Vector3:
	if Game.world != null:
		return Game.world.get_spawn_transform(index).origin
	return Vector3.ZERO

func _host_target() -> Vector3:
	return _spawn_point(3)

func _a_target() -> Vector3:
	return _spawn_point(2)

func _b_target() -> Vector3:
	return _spawn_point(0)

# --- Roles -------------------------------------------------------------------------------------------------------

func _run_solo() -> void:
	var err := Game.start_host("SoloBot", port)
	_maybe_isolate()
	_check(err == OK, "start_host returns OK (got %s)" % error_string(err))
	_check(Game.world != null and Game.world.is_inside_tree(), "world instantiated under the root")
	_check(Net.is_host and Net.is_online(), "Net.is_host and is_online after host()")
	_check(Net.players.size() == 1 and Net.players.has(1), "players dict has only the host")
	_check(Net.get_player_color(1) == Net.PALETTE[0], "host got the first palette color")
	_check(Game.local_player != null and Game.local_player.name == "1", "local player '1' set synchronously")
	_check(not _signals.has("world_ready"), "world_ready is deferred (not emitted inside start_host)")
	await _frames(3)
	_check(_signals.get("world_ready", false), "world_ready emitted after start_host")
	_check(_signals.get("world_ready_in_tree", false), "world_ready: world in tree and ready")
	_check(_signals.get("local_player_spawned", false), "local_player_spawned emitted")
	_check(_signals.get("local_player_ready", false), "local_player_spawned: player in tree and ready")
	var p: Player = Game.local_player
	if p == null:
		return
	_check(p.is_local() and p.is_multiplayer_authority(), "host player is local + authority")
	_check(p.camera.current, "local camera is current")
	_check(not p.get_node("%NameLabel").visible, "local name label hidden")
	_check(p.get_item_socket() == p.get_node("%HandSocket"), "local item socket is %HandSocket")
	_check(p.get_interactor() != null, "%Interactor present")
	_check(p.collision_layer == Const.LAYER_PLAYER and p.collision_mask == Const.LAYER_WORLD, "player layers 2 / mask 1")
	await _wait(func() -> bool: return p.is_on_floor(), 5.0)
	_check(p.is_on_floor(), "player lands on the floor")
	# Movement through the real input actions.
	var start := p.global_position
	Input.action_press(&"move_forward")
	await _seconds(0.5)
	Input.action_release(&"move_forward")
	var moved := _flat(p.global_position - start).length()
	_check(moved > 0.8, "move_forward moves the player (%.2f m)" % moved)
	# UI lock blocks input.
	var lock_events: Array[bool] = []
	var on_lock := func(locked: bool) -> void: lock_events.append(locked)
	Game.ui_lock_changed.connect(on_lock)
	Game.set_ui_lock(&"test", true)
	_check(Game.is_ui_locked(), "is_ui_locked after set_ui_lock(true)")
	await _seconds(0.3)
	start = p.global_position
	Input.action_press(&"move_forward")
	await _seconds(0.4)
	Input.action_release(&"move_forward")
	moved = _flat(p.global_position - start).length()
	_check(moved < 0.05, "no movement while UI locked (%.3f m)" % moved)
	Game.set_ui_lock(&"test", false)
	_check(not Game.is_ui_locked() and lock_events == [true, false], "ui_lock_changed emitted true/false")
	Game.ui_lock_changed.disconnect(on_lock)
	# Sprint is faster than walk.
	await _seconds(0.3)
	start = p.global_position
	Input.action_press(&"move_back")
	Input.action_press(&"sprint")
	await _seconds(0.4)
	Input.action_release(&"sprint")
	Input.action_release(&"move_back")
	moved = _flat(p.global_position - start).length()
	_check(moved > 1.6, "sprint moves faster (%.2f m in 0.4 s)" % moved)
	# Crouch shrinks the capsule and lowers the camera.
	Input.action_press(&"crouch")
	await _seconds(0.4)
	var shape := p.get_node("Collision").shape as CapsuleShape3D
	_check(p.crouching and is_equal_approx(shape.height, Player.CROUCH_HEIGHT), "crouch shrinks the capsule")
	_check(p.head.position.y < Player.STAND_CAMERA_Y - 0.3, "crouch lowers the camera")
	Input.action_release(&"crouch")
	await _seconds(0.4)
	_check(not p.crouching and is_equal_approx(shape.height, Player.STAND_HEIGHT), "releasing crouch stands up")
	# Jump.
	await _wait(func() -> bool: return p.is_on_floor(), 2.0)
	var floor_y := p.global_position.y
	Input.action_press(&"jump")
	await _seconds(0.25)
	Input.action_release(&"jump")
	_check(p.global_position.y > floor_y + 0.3, "jump leaves the ground")
	# Fall safety.
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(0.0, -25.0, 0.0)))
	await _seconds(0.2)
	_check(p.global_position.y > -2.0, "falling below -20 teleports back to spawn")
	# Mouse look: yaw on the body, pitch on the head clamped to +-89 degrees.
	var yaw_before := p.rotation.y
	p.apply_look_input(Vector2(100.0, -100000.0))
	_check(absf(p.head.rotation.x - Player.MAX_PITCH) < 0.001, "look up clamps pitch to +89 deg (%.3f rad)" % p.head.rotation.x)
	_check(not is_equal_approx(p.rotation.y, yaw_before), "horizontal look rotates the body (yaw)")
	p.apply_look_input(Vector2(0.0, 200000.0))
	_check(absf(p.head.rotation.x + Player.MAX_PITCH) < 0.001, "look down clamps pitch to -89 deg")
	p.apply_look_input(Vector2(0.0, -200.0))
	await _seconds(0.1)
	_check(is_equal_approx(p.net_pitch, p.head.rotation.x) and is_equal_approx(p.net_yaw, p.rotation.y),
		"net_pitch / net_yaw follow the local look")
	# Hosting again on a busy port fails cleanly with a menu message.
	Game.return_to_menu("Solo round done")
	await _frames(3)
	_check(Game.world == null and Game.local_player == null, "return_to_menu frees the world")
	var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	_check(menu != null and menu.call("get_status") == "Solo round done", "menu shows the return message")
	_check(not Net.is_online() and multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "offline after return_to_menu")
	var blocker := ENetMultiplayerPeer.new()
	blocker.create_server(port + 1, 1)
	print("(expected error next: ENet \"Couldn't create an ENet host\" for the busy port)")
	err = Game.start_host("SoloBot", port + 1)
	_check(err != OK and Game.world == null, "start_host on a busy port fails (%s)" % error_string(err))
	menu = get_tree().get_first_node_in_group(Game.MENU_GROUP)
	_check(menu != null and String(menu.call("get_status")).begins_with("Could not host"), "busy port message shown in menu")
	blocker.close()
	# The menu can host again after returning (port released).
	err = Game.start_host("SoloBot", port)
	_check(err == OK and Game.world != null and Game.local_player != null, "host again after returning to menu")
	await _frames(2)
	_check(get_tree().get_first_node_in_group(Game.MENU_GROUP) == null, "menu freed when hosting")
	Game.return_to_menu("")
	await _frames(3)
	_check(Game.world == null and get_tree().get_first_node_in_group(Game.MENU_GROUP) != null, "second return to menu")
	await _test_menu_settings()

## The menu remembers name / ip / port in user://settings.cfg (the real file is backed up and restored).
func _test_menu_settings() -> void:
	var path: String = "user://settings.cfg"
	var had_file := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_string(path) if had_file else ""
	var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	if not _check(menu != null, "menu present for the settings test"):
		return
	menu.name_edit.text = "Persisty"
	menu.ip_edit.text = "10.1.2.3"
	menu.port_spin.value = 7123
	menu._save_settings()
	menu.get_parent().remove_child(menu)
	menu.free()
	var fresh: Node = (load(Game.MENU_SCENE_PATH) as PackedScene).instantiate()
	get_tree().root.add_child(fresh)
	var saved := ConfigFile.new()
	saved.load(path)
	_check(fresh.name_edit.text == "Persisty" and fresh.ip_edit.text == "10.1.2.3"
		and int(saved.get_value("menu", "port", 0)) == 7123, "menu remembers name / ip / port")
	_check(int(fresh.port_spin.value) == port, "--port on the command line overrides the saved port")
	fresh.set_status("Hello there")
	_check(fresh.get_status() == "Hello there" and fresh.status_label.visible, "menu set_status shows the text")
	fresh.set_status("")
	_check(not fresh.status_label.visible, "empty status hides the label")
	_check(not fresh.host_button.disabled, "menu buttons enabled")
	if had_file:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _run_host() -> void:
	if scenario == "full":
		Config.balance.max_players = 2
	var connects: Array[int] = []
	var disconnects: Array[int] = []
	multiplayer.peer_connected.connect(func(id: int) -> void: connects.append(id))
	multiplayer.peer_disconnected.connect(func(id: int) -> void: disconnects.append(id))
	var err := Game.start_host("HostBot", port)
	_maybe_isolate()
	if not _check(err == OK, "host started on port %d" % port):
		return
	await _frames(2)
	print("HOST_READY")
	var world := Game.world
	if not await _wait_check(func() -> bool: return Net.players.size() >= 2, DEFAULT_TIMEOUT, "a client registered"):
		return
	var client_id := _other_ids([1])[0]
	await _wait_check(func() -> bool: return world.get_players().size() == 2, 5.0, "2 Player nodes under World/Players")
	var cp := world.get_player(client_id)
	if not _check(cp != null, "client Player node exists (name == peer id %d)" % client_id):
		return
	_check(cp.get_multiplayer_authority() == client_id and not cp.is_local(), "client player authority == client id")
	_check(not cp.camera.current, "remote camera not current on host")
	_check(cp.get_item_socket() == cp.get_node("%BodyHandSocket"), "remote item socket is %BodyHandSocket")
	_check(Net.get_player_color(client_id) == Net.PALETTE[1], "client got the second palette color")
	_check(cp.spawn_index == 1, "client uses spawn index 1")
	_check(_signals.get("peer_registered", 0) == client_id, "peer_registered emitted for the client")
	match scenario:
		"pair":
			_check(Net.get_player_name(client_id) == "ClientBot", "client name synced to host")
			await _wait_check(func() -> bool: return _near(cp, _a_target()), DEFAULT_TIMEOUT,
				"client movement replicated to host (target %s)" % _a_target())
			await _wait_check(func() -> bool: return cp.crouching, 5.0, "client crouch replicated to host")
			Game.local_player.place_at(Transform3D(Basis.IDENTITY, _host_target()))
			await _wait_check(func() -> bool: return Net.players.size() == 1, DEFAULT_TIMEOUT, "client left: players dict shrank")
			await _wait_check(func() -> bool: return world.get_player(client_id) == null, 5.0, "client Player despawned on host")
			_check(_signals.get("peer_left", 0) == client_id, "peer_left emitted on host")
			_check(world.get_players().size() == 1, "only the host player remains")
		"trio":
			await _wait_check(func() -> bool: return _near(cp, _a_target()), DEFAULT_TIMEOUT, "client A movement replicated")
			Game.local_player.place_at(Transform3D(Basis.IDENTITY, _host_target()))
			await _wait_check(func() -> bool: return Net.players.size() == 3, 30.0, "late joiner B registered")
			await _wait_check(func() -> bool: return world.get_players().size() == 3, 5.0, "3 Player nodes on host")
			var b_id := _other_ids([1, client_id])[0] if _other_ids([1, client_id]).size() > 0 else 0
			var bp := world.get_player(b_id)
			_check(bp != null and bp.spawn_index == 2, "late joiner uses spawn index 2")
			_check(Net.get_player_name(b_id) == "EarlyBot 2", "server de-duplicated the late joiner's name")
			_check(Net.get_player_color(b_id) == Net.PALETTE[2], "late joiner got the third palette color")
			await _wait_check(func() -> bool: return Net.players.size() == 1, 40.0, "both clients left")
			await _wait_check(func() -> bool: return world.get_players().size() == 1, 5.0, "all client players despawned")
		"drop":
			# The host leaves while a client is connected: the client must fall back to the menu.
			await _seconds(1.0)
			Game.return_to_menu("Host quit test")
			await _frames(3)
			_check(Game.world == null and not Net.is_online(), "host left with a client connected")
			return
		"full":
			await _wait_check(func() -> bool: return connects.size() >= 2 and disconnects.size() >= 1, 30.0,
				"an extra peer connected and was dropped")
			_check(Net.players.size() == 2 and world.get_players().size() == 2, "rejected peer never registered or spawned")
			await _wait_check(func() -> bool: return Net.players.size() == 1, 30.0, "idle client left")
	Game.return_to_menu("Host test done")
	await _frames(3)
	_check(Game.world == null and not Net.is_online(), "host returned to menu and went offline")

func _run_client() -> void:
	var host_ip := "127.0.0.1"
	var my_name := {"a": "ClientBot", "b": "LateBot", "idle": "IdleBot", "reject": "NoRoomBot"}.get(who, "ClientBot") as String
	if scenario == "trio":
		my_name = "EarlyBot" # B reuses A's name on purpose: the server must de-duplicate it to "EarlyBot 2"
	var err := Game.start_join(host_ip, port, my_name)
	_maybe_isolate()
	if not _check(err == OK, "start_join returns OK"):
		return
	_check(Game.world != null and Game.world.is_inside_tree(), "world created before connecting")
	_check(not Net.is_host, "client is not host")
	if who == "nohost":
		var t0 := Time.get_ticks_msec()
		_check(get_tree().root.get_node_or_null("ConnectingOverlay") != null, "connecting overlay shown while connecting")
		await _wait_check(func() -> bool: return Game.world == null, 40.0, "failed connection returns to menu")
		var menu0 := get_tree().get_first_node_in_group(Game.MENU_GROUP)
		var status0 := String(menu0.call("get_status")) if menu0 != null else ""
		_check(status0.contains("connect"), "menu explains the failure ('%s' after %.1f s)" % [status0, (Time.get_ticks_msec() - t0) / 1000.0])
		_check(get_tree().root.get_node_or_null("ConnectingOverlay") == null and not Game.is_ui_locked(), "overlay + lock cleared")
		_check(not Net.is_online() and multiplayer.multiplayer_peer is OfflineMultiplayerPeer, "offline after failure")
		return
	if who == "reject":
		await _wait_check(func() -> bool: return Game.world == null, DEFAULT_TIMEOUT, "rejected client returned to menu")
		var menu := get_tree().get_first_node_in_group(Game.MENU_GROUP)
		var status := String(menu.call("get_status")) if menu != null else ""
		_check(status.contains("full"), "menu says the server is full ('%s')" % status)
		_check(_signals.get("peer_rejected", "") != "", "peer_rejected signal emitted")
		_check(Game.local_player == null and Net.players.is_empty(), "no local player / registry after rejection")
		await _seconds(1.5)
		_check(Game.world == null, "stays in the menu")
		return
	if not await _wait_check(func() -> bool: return Game.local_player != null, DEFAULT_TIMEOUT, "local player spawned"):
		return
	await _frames(2)
	var me: Player = Game.local_player
	var world := Game.world
	_check(str(me.name) == str(multiplayer.get_unique_id()), "local player name == my peer id")
	_check(me.is_multiplayer_authority() and me.is_local(), "local player has authority")
	_check(me.camera.current, "local camera current")
	_check(_signals.get("local_player_ready", false), "local_player_spawned emitted with a ready player")
	_check(_signals.get("world_ready_in_tree", false), "world_ready emitted on client")
	_check(get_tree().root.get_node_or_null("ConnectingOverlay") == null, "connecting overlay removed")
	_check(not Game.is_ui_locked(), "connecting UI lock released")
	var expected := {"pair": 2, "trio": 3 if who == "b" else 2, "full": 2, "drop": 2}.get(scenario, 2) as int
	await _wait_check(func() -> bool: return Net.players.size() == expected, 5.0, "players dict has %d entries" % expected)
	await _wait_check(func() -> bool: return world.get_players().size() == expected, 5.0, "%d Player nodes" % expected)
	var hp := world.get_player(1)
	if not _check(hp != null, "host Player '1' exists on client"):
		return
	_check(not hp.is_local() and hp.get_multiplayer_authority() == 1, "host player is remote with authority 1")
	_check(hp.display_name == "HostBot" and hp.player_color == Net.PALETTE[0], "host name/color on client")
	_check(me.display_name == Net.local_name and me.player_color == Net.local_color, "own name/color from registry")
	match scenario:
		"pair":
			# Real input moves the player; UI lock blocks it.
			var start := me.global_position
			Input.action_press(&"move_forward")
			await _seconds(0.5)
			Input.action_release(&"move_forward")
			_check(_flat(me.global_position - start).length() > 0.5, "input moves the client player")
			Input.action_press(&"crouch")
			await _seconds(0.1)
			me.place_at(Transform3D(Basis.IDENTITY, _a_target()))
			await _wait_check(func() -> bool: return _near(hp, _host_target()), DEFAULT_TIMEOUT,
				"host movement replicated to client (target %s)" % _host_target())
			_check(me.crouching, "still crouching (hold)")
			Input.action_release(&"crouch")
			await _seconds(0.3)
		"trio":
			if who == "a":
				me.place_at(Transform3D(Basis.IDENTITY, _a_target()))
				await _wait_check(func() -> bool: return _near(hp, _host_target()), DEFAULT_TIMEOUT, "host movement seen by A")
				print("A_READY")
				await _wait_check(func() -> bool: return Net.players.size() == 3, 30.0, "A sees late joiner in registry")
				_check(_signals.get("peer_joined", 0) != 0, "peer_joined emitted on A for the late joiner")
				var b_id := _other_ids([1, multiplayer.get_unique_id()])[0] if Net.players.size() == 3 else 0
				await _wait_check(func() -> bool: return world.get_player(b_id) != null, 5.0, "A has B's Player node")
				var bp := world.get_player(b_id)
				_check(bp != null and bp.display_name == "EarlyBot 2", "A sees B's de-duplicated name")
				if bp != null:
					await _wait_check(func() -> bool: return _near(bp, _b_target()), DEFAULT_TIMEOUT,
						"B's movement replicated to A (client->client relay)")
			else:
				var a_id := _other_ids([1, multiplayer.get_unique_id()])[0]
				var ap := world.get_player(a_id)
				_check(ap != null and ap.display_name == "EarlyBot", "late joiner sees client A (name synced)")
				_check(Net.local_name == "EarlyBot 2" and me.display_name == "EarlyBot 2", "duplicate name de-duplicated ('%s')" % me.display_name)
				_check(me.spawn_index == 2, "late joiner spawn index 2")
				if ap != null:
					await _wait_check(func() -> bool: return _near(ap, _a_target()), 5.0,
						"late joiner sees A at A's CURRENT position (not its spawn)")
				await _wait_check(func() -> bool: return _near(hp, _host_target()), 5.0,
					"late joiner sees the host at its CURRENT position")
				me.place_at(Transform3D(Basis.IDENTITY, _b_target()))
				await _wait_check(func() -> bool: return world.get_player(a_id) == null, 30.0, "A's despawn replicated to B")
				await _wait_check(func() -> bool: return Net.players.size() == 2, 5.0, "registry shrank on B")
				_check(_signals.get("peer_left", 0) == a_id, "peer_left emitted on B")
		"full":
			print("A_READY")
			await _seconds(8.0)
		"drop":
			await _wait_check(func() -> bool: return Game.world == null, DEFAULT_TIMEOUT, "host quit -> client back in menu")
			var menu1 := get_tree().get_first_node_in_group(Game.MENU_GROUP)
			var status1 := String(menu1.call("get_status")) if menu1 != null else ""
			_check(status1 == "Host disconnected", "menu says 'Host disconnected' ('%s')" % status1)
			_check(not Net.is_online() and Net.players.is_empty() and Game.local_player == null, "client state cleared")
			return
	Game.return_to_menu("Client test done")
	await _frames(3)
	_check(Game.world == null and Game.local_player == null, "client returned to menu")
	var menu2 := get_tree().get_first_node_in_group(Game.MENU_GROUP)
	_check(menu2 != null and menu2.call("get_status") == "Client test done", "client menu shows message")
	_check(not Net.is_online() and Net.players.is_empty(), "client offline, registry cleared")

# --- Helpers --------------------------------------------------------------------------------------------------------

## --isolated: strip other systems' runtime nodes (stations, HUD) from the fresh world on every peer, so only
## Net / Game / World / Player code runs and any replication error can be attributed to it. Called right after
## start_host / start_join (before any peer connects, before the deferred world_ready).
func _maybe_isolate() -> void:
	if not Config.has_arg("isolated") or Game.world == null:
		return
	for path in ["Room/Stations", "HUD"]:
		var n := Game.world.get_node_or_null(path)
		if n != null:
			n.free() # immediately: a removed-but-queued node would still get autoload signals this frame
	print("ISOLATED: removed Room/Stations and HUD")

func _track_signals() -> void:
	Game.world_ready.connect(func(w: World) -> void:
		_signals["world_ready"] = true
		_signals["world_ready_in_tree"] = w.is_inside_tree() and w.is_node_ready())
	Game.local_player_spawned.connect(func(p: Player) -> void:
		_signals["local_player_spawned"] = true
		_signals["local_player_ready"] = p.is_inside_tree() and p.is_node_ready() and p.is_local())
	Net.peer_registered.connect(func(id: int) -> void: _signals["peer_registered"] = id)
	Net.peer_left.connect(func(id: int) -> void: _signals["peer_left"] = id)
	Net.peer_joined.connect(func(id: int) -> void: _signals["peer_joined"] = id)
	Net.peer_rejected.connect(func(reason: String) -> void: _signals["peer_rejected"] = reason)

func _other_ids(exclude: Array) -> Array[int]:
	var out: Array[int] = []
	for id in Net.get_peer_ids():
		if not id in exclude:
			out.append(id)
	return out

func _near(p: Player, target: Vector3) -> bool:
	return p != null and is_instance_valid(p) and _flat(p.global_position - target).length() < POS_TOLERANCE

func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)

func _check(cond: bool, what: String) -> bool:
	if cond:
		_passes += 1
		print("PASS: [%s] %s" % [_tag, what])
	else:
		_fail(what)
	return cond

func _fail(what: String) -> void:
	_failures += 1
	print("FAIL: [%s] %s" % [_tag, what])

func _wait(cond: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return true
		await get_tree().create_timer(0.05, true).timeout
	return bool(cond.call())

func _wait_check(cond: Callable, timeout: float, what: String) -> bool:
	var ok: bool = await _wait(cond, timeout)
	return _check(ok, what)

func _seconds(t: float) -> void:
	await get_tree().create_timer(t, true).timeout

func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

var _finished: bool = false

func _finish() -> void:
	if _finished:
		return
	_finished = true
	for action in [&"move_forward", &"move_back", &"sprint", &"crouch", &"jump"]:
		Input.action_release(action)
	if Game.world != null:
		Net.leave()
	var ok := _failures == 0 and _passes > 0
	print("RESULT: %s [%s] %d passed, %d failed" % ["PASS" if ok else "FAIL", _tag, _passes, _failures])
	get_tree().quit(0 if ok else 1)
