extends Node
## Autoload "Game": scene flow (menu <-> world), local player tracking, UI lock + mouse mode, toasts.
## See CONTRACTS.md. The World is instantiated manually under the root (no change_scene), so the
## MultiplayerSpawners exist before any spawn packet arrives.
##
## Host:   start_host()  -> Net.host() -> World added -> menu freed -> GameState.server_reset_game()
##                          -> world.server_spawn_player(1) -> world_ready.
## Client: start_join()  -> World added FIRST -> menu freed -> Net.join() -> world_ready. When connected the
##                          client registers; the server spawns its Player and sends the full GameState.
## world_ready / local_player_spawned are emitted DEFERRED (end of the current frame) once the node is in the
## tree and its _ready ran, so callers can `await Game.world_ready` right after start_host()/start_join().
## Always check Game.world / Game.local_player first if you might be late (they are set synchronously).

signal world_ready(world: World)                         ## every peer: World is in the tree and _ready ran
signal local_player_spawned(player: Player)              ## every peer: my own Player node exists and is ready
signal toast_requested(text: String, kind: StringName)   ## kind: &"info" | &"error" | &"success"
signal ui_lock_changed(locked: bool)

const WORLD_SCENE_PATH := "res://scenes/world/world.tscn"
const MENU_SCENE_PATH := "res://scenes/main_menu/main_menu.tscn"
const CONNECTING_SCENE_PATH := "res://scenes/main_menu/connecting_overlay.tscn"
const MENU_GROUP: StringName = &"main_menu"
## UI-lock source used while a client is connecting (keeps the mouse free for the Cancel button).
const LOCK_CONNECTING: StringName = &"connecting"
## Give up on a join attempt if our Player has not spawned after this many seconds.
const JOIN_TIMEOUT_SEC: float = 12.0

var world: World = null
var local_player: Player = null
## Set once the main menu consumed the --host / --join command-line auto start (so it runs only once).
var cli_auto_start_used: bool = false

var _ui_locks: Dictionary = {}          # StringName source -> true
var _connecting_overlay: Node = null
var _join_attempt: int = 0
var _menu_return_pending: bool = false
var _pending_menu_message: String = ""

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Net.peer_registered.connect(_on_peer_registered)
	Net.peer_joined.connect(_on_peer_joined)
	Net.peer_left.connect(_on_peer_left)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		refresh_mouse_mode()

# --- Scene flow -------------------------------------------------------------------------------------------

## Hosts a game on `port` and enters the world. Returns OK, or the error (the menu shows a message).
func start_host(player_name: String, port: int) -> Error:
	_cancel_pending_menu_return()
	if world != null:
		_teardown_world(false)
	Net.local_name = Net.sanitize_name(player_name)
	var err := Net.host(port)
	if err != OK:
		_show_menu_message("Could not host on port %d (%s). Is it already in use?" % [port, error_string(err)])
		return err
	_create_world()
	_free_menu()
	GameState.server_reset_game()
	world.server_spawn_player(Const.SERVER_PEER_ID)
	_emit_world_ready.call_deferred(world)
	return OK

## Creates the world, then connects to ip:port. Returns OK when the attempt started (connection result
## arrives later: local_player_spawned on success, or back to the menu with a message on failure).
func start_join(ip: String, port: int, player_name: String) -> Error:
	_cancel_pending_menu_return()
	if world != null:
		_teardown_world(false)
	Net.leave()
	Net.local_name = Net.sanitize_name(player_name)
	# World FIRST so the MultiplayerSpawners exist before any spawn packet can arrive.
	_create_world()
	_free_menu()
	var err := Net.join(ip, port)
	if err != OK:
		var why := "Could not resolve \"%s\"" % ip if err == ERR_CANT_RESOLVE else error_string(err)
		_return_to_menu_now("Could not connect to %s:%d (%s)" % [ip, port, why])
		return err
	_show_connecting_overlay("Connecting to %s:%d" % [ip, port])
	_join_attempt += 1
	get_tree().create_timer(JOIN_TIMEOUT_SEC, true).timeout.connect(
		_on_join_timeout.bind(_join_attempt, "%s:%d" % [ip, port]))
	_emit_world_ready.call_deferred(world)
	return OK

## Any peer: disconnects, frees the world and shows the main menu (with `message` in its status label).
## Runs deferred (end of frame) so it is safe to call from inside world nodes, RPCs or network callbacks.
func return_to_menu(message: String = "") -> void:
	if message != "" or _pending_menu_message == "":
		_pending_menu_message = message
	if _menu_return_pending:
		return
	_menu_return_pending = true
	_do_return_to_menu.call_deferred()

func get_player(peer_id: int) -> Player:
	if world == null or not is_instance_valid(world):
		return null
	return world.get_player(peer_id)

func get_local_peer_id() -> int:
	return multiplayer.get_unique_id()

func toast(text: String, kind: StringName = &"info") -> void:
	toast_requested.emit(text, kind)

# --- UI lock / mouse --------------------------------------------------------------------------------------

## Shop UI, pause menu, round-end screen... While any source is locked the player ignores input and the
## mouse is released. Each source must unlock itself (all locks are cleared when returning to the menu).
func set_ui_lock(source: StringName, locked: bool) -> void:
	var was := is_ui_locked()
	if locked:
		_ui_locks[source] = true
	else:
		_ui_locks.erase(source)
	var now := is_ui_locked()
	if was != now:
		ui_lock_changed.emit(now)
	refresh_mouse_mode()

func is_ui_locked() -> bool:
	return not _ui_locks.is_empty()

func is_ui_locked_by(source: StringName) -> bool:
	return _ui_locks.has(source)

## Mouse is captured only while in the world with no UI lock; visible everywhere else.
## Called automatically on lock/world changes; call it after anything else touched Input.mouse_mode.
func refresh_mouse_mode() -> void:
	var want := Input.MOUSE_MODE_CAPTURED if (world != null and not is_ui_locked()) else Input.MOUSE_MODE_VISIBLE
	if Input.mouse_mode != want:
		Input.mouse_mode = want

# --- Internals: world ---------------------------------------------------------------------------------------

func _create_world() -> void:
	var scene := load(WORLD_SCENE_PATH) as PackedScene
	world = scene.instantiate() as World
	world.name = "World"
	get_tree().root.add_child(world)
	get_tree().current_scene = world
	world.players_root.child_entered_tree.connect(_on_player_node_entered)
	world.players_root.child_exiting_tree.connect(_on_player_node_exiting)
	for child in world.players_root.get_children():
		_on_player_node_entered(child)
	refresh_mouse_mode()

func _emit_world_ready(w: World) -> void:
	if w != null and is_instance_valid(w) and w == world and w.is_inside_tree():
		world_ready.emit(w)

func _on_player_node_entered(node: Node) -> void:
	var p := node as Player
	if p == null or local_player == p:
		return
	if str(p.name) != str(multiplayer.get_unique_id()):
		return
	if p.is_node_ready():
		_set_local_player(p)
	else:
		p.ready.connect(_set_local_player.bind(p), CONNECT_ONE_SHOT)

func _on_player_node_exiting(node: Node) -> void:
	if node == local_player:
		local_player = null

func _set_local_player(p: Player) -> void:
	if not is_instance_valid(p) or not p.is_inside_tree() or world == null:
		return
	local_player = p
	_hide_connecting_overlay()
	refresh_mouse_mode()
	_emit_local_player_spawned.call_deferred(p)

func _emit_local_player_spawned(p: Player) -> void:
	if is_instance_valid(p) and p == local_player and p.is_inside_tree():
		local_player_spawned.emit(p)

## Removes the world. immediate=true frees it right away (only from deferred/idle code such as
## _do_return_to_menu, never from inside a world node's callback): a world that is merely out of the tree but
## not yet freed would still receive autoload signals (GameState ticks, Net changes) for the rest of the frame.
## immediate=false (start_host/start_join replacing a world) removes it from the tree and queue_frees it.
func _teardown_world(immediate: bool) -> void:
	var w := world
	world = null
	local_player = null
	if w != null and is_instance_valid(w):
		if w.players_root != null:
			if w.players_root.child_entered_tree.is_connected(_on_player_node_entered):
				w.players_root.child_entered_tree.disconnect(_on_player_node_entered)
			if w.players_root.child_exiting_tree.is_connected(_on_player_node_exiting):
				w.players_root.child_exiting_tree.disconnect(_on_player_node_exiting)
			# Players leave first, while the rest of the world (HUD, items...) is still inside the tree, so
			# listeners of a player's tree_exiting can still use their multiplayer API / tree.
			for p in w.players_root.get_children():
				w.players_root.remove_child(p)
				if immediate:
					p.free()
				else:
					p.queue_free()
		if w.get_parent() != null:
			w.get_parent().remove_child(w)
		if immediate:
			w.free()
		else:
			w.queue_free()
	_hide_connecting_overlay()

func _do_return_to_menu() -> void:
	if not _menu_return_pending:
		return # cancelled by a start_host / start_join issued in the same frame
	var message := _pending_menu_message
	_cancel_pending_menu_return()
	_return_to_menu_now(message)

func _cancel_pending_menu_return() -> void:
	_menu_return_pending = false
	_pending_menu_message = ""

## Order matters: disconnect first (no more packets touch the world), then let everything that listens to
## GameState / ui locks react while the world is still intact, then free the world and show the menu.
func _return_to_menu_now(message: String) -> void:
	_join_attempt += 1 # invalidates any pending join timeout
	Net.leave()
	if GameState.has_method("reset_local"):
		GameState.call("reset_local")
	var had_locks := is_ui_locked()
	_ui_locks.clear()
	if had_locks:
		ui_lock_changed.emit(false)
	_teardown_world(true)
	var menu := _find_menu()
	if menu == null:
		var scene := load(MENU_SCENE_PATH) as PackedScene
		menu = scene.instantiate()
		get_tree().root.add_child(menu)
	get_tree().current_scene = menu
	if menu.has_method("set_status"):
		menu.call("set_status", message)
	refresh_mouse_mode()

# --- Internals: menu / overlay --------------------------------------------------------------------------------

func _find_menu() -> Node:
	var menu := get_tree().get_first_node_in_group(MENU_GROUP)
	if menu != null and not menu.is_queued_for_deletion():
		return menu
	return null

func _free_menu() -> void:
	for menu in get_tree().get_nodes_in_group(MENU_GROUP):
		menu.remove_from_group(MENU_GROUP)
		if menu.get_parent() != null:
			menu.get_parent().remove_child(menu)
		menu.queue_free()

func _show_menu_message(message: String) -> void:
	var menu := _find_menu()
	if menu != null and menu.has_method("set_status"):
		menu.call("set_status", message)
	else:
		push_warning("Game: " + message)
		toast(message, &"error")

func _show_connecting_overlay(text: String) -> void:
	_hide_connecting_overlay()
	var scene := load(CONNECTING_SCENE_PATH) as PackedScene
	if scene == null:
		return
	_connecting_overlay = scene.instantiate()
	get_tree().root.add_child(_connecting_overlay)
	if _connecting_overlay.has_method("set_text"):
		_connecting_overlay.call("set_text", text)
	set_ui_lock(LOCK_CONNECTING, true)

func _hide_connecting_overlay() -> void:
	if _connecting_overlay != null and is_instance_valid(_connecting_overlay):
		if _connecting_overlay.get_parent() != null:
			_connecting_overlay.get_parent().remove_child(_connecting_overlay)
		_connecting_overlay.queue_free()
	_connecting_overlay = null
	if is_ui_locked_by(LOCK_CONNECTING):
		set_ui_lock(LOCK_CONNECTING, false)

func _on_join_timeout(attempt: int, address: String) -> void:
	if attempt != _join_attempt or world == null or local_player != null or Net.is_host:
		return
	return_to_menu("Could not connect to %s (timed out). Is the host running and the port open?" % address)

# --- Net callbacks ----------------------------------------------------------------------------------------------

## SERVER: a peer registered its name -> spawn its Player and send it the whole game state.
func _on_peer_registered(peer_id: int) -> void:
	if world == null or not is_instance_valid(world):
		return
	world.server_spawn_player(peer_id)
	GameState.server_send_full_state(peer_id)

func _on_peer_joined(peer_id: int) -> void:
	if world != null:
		toast("%s joined the farm!" % Net.get_player_name(peer_id), &"info")

func _on_peer_left(peer_id: int) -> void:
	if world != null and peer_id != multiplayer.get_unique_id():
		toast("%s left" % Net.get_player_name(peer_id), &"info")
