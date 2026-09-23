extends Node
## Body of items_e2e_test.gd. Host role: hosts a real game, launches the client process, spawns a watering can
## in front of the client's player and verifies the host-side view. Client role: joins, looks at the can with
## its real Interactor, picks it up (try_interact -> Interactable RPC), checks it sits in its first-person hand
## socket, drops it (try_drop -> ItemManager RPC) and reports every check to the host over RPC.

const WAIT_SEC := 15.0

var _role := "host"
var _port := 0
var _pid := -1
var _passes := 0
var _fails := 0
# host-side state
var _client_id := 0
var _client_holding := false
var _client_dropped := false
var _client_drop_pos := Vector3.INF
var _client_done := false
# client-side state
var _can_name := ""
var _continue := false
var _finish := false

func _ready() -> void:
	_run()

func check(cond: bool, what: String) -> void:
	if cond:
		_passes += 1
	else:
		_fails += 1
	var line := "%s: [%s] %s" % ["PASS" if cond else "FAIL", _role, what]
	print(line)
	if _role == "client" and multiplayer.has_multiplayer_peer() and multiplayer.get_unique_id() != 1:
		_rpc_report.rpc_id(1, cond, what)

func frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame

func wait_until(cond: Callable, seconds: float = WAIT_SEC) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()

func _run() -> void:
	await get_tree().process_frame
	var args := Config.parse_user_args()
	_role = str(args.get("role", "host"))
	_port = int(args.get("port", 0))
	if _role == "client":
		await _run_client()
	else:
		await _run_host()

# ================================================================================================= host

func _run_host() -> void:
	_port = 28000 + randi() % 900
	var err := Game.start_host("Host", _port)
	check(err == OK, "hosting on port %d" % _port)
	if err != OK:
		_end(1)
		return
	check(await wait_until(func() -> bool: return Game.local_player != null), "host player spawned")
	var args := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
			"-s", "res://tools/tests/items_e2e_test.gd", "--", "--role=client", "--port=%d" % _port])
	_pid = OS.create_process(OS.get_executable_path(), args)
	check(_pid > 0, "launched the client process")
	check(await wait_until(func() -> bool: return Game.world.get_players().size() == 2, 20.0), "client player spawned on the host")
	for p in Game.world.get_players():
		if p.peer_id != Const.SERVER_PEER_ID:
			_client_id = p.peer_id
	var client_player := Game.get_player(_client_id)
	if client_player == null:
		_end(1)
		return
	await get_tree().create_timer(1.0).timeout # let the client land and sync its position
	var items := Game.world.items
	var spot := _free_spot_near(client_player)
	var can := items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, spot) as WateringCan
	check(can != null, "host spawned a full watering can 1.3 m from the client at %s" % spot)
	if can == null:
		_end(1)
		return
	await frames(10)
	_rpc_start.rpc_id(_client_id, String(can.name))
	# Client picks it up.
	check(await wait_until(func() -> bool: return _client_holding), "client reported holding the can")
	check(can.holder_id == _client_id and items.get_held_by(_client_id) == can, "host: can.holder_id == client")
	await frames(10)
	var socket := client_player.get_item_socket()
	check(socket == client_player.get_node("%BodyHandSocket"), "host: remote holder's socket is %BodyHandSocket")
	var expected := (socket.global_transform * can._get_hold_transform()).origin
	check(can.global_position.distance_to(expected) < 0.05, "host: can follows the client's body hand socket (%.3f m off)" % can.global_position.distance_to(expected))
	check(can.get_collider().collision_layer == 0 and can.visible, "host: held can visible, collision off")
	_rpc_continue.rpc_id(_client_id)
	# Client drops it.
	check(await wait_until(func() -> bool: return _client_dropped), "client reported the drop")
	check(can.holder_id == 0 and items.get_held_by(_client_id) == null, "host: can back on the floor")
	check(can.global_position.distance_to(_client_drop_pos) < 0.001, "host and client agree on the drop position %s" % can.global_position)
	var feet := client_player.global_position
	check(Vector2(can.global_position.x - feet.x, can.global_position.z - feet.z).length() < 1.0 and absf(can.global_position.y - feet.y) < 0.3,
			"host: dropped in front of the client's feet")
	_rpc_finish.rpc_id(_client_id)
	check(await wait_until(func() -> bool: return _client_done or not OS.is_process_running(_pid), 10.0), "client finished")
	await wait_until(func() -> bool: return not OS.is_process_running(_pid), 10.0)
	print("items_e2e_test: %d passed, %d failed" % [_passes, _fails])
	_end(1 if _fails > 0 else 0)

## A floor spot ~1.3 m from the player with a clear line of sight (tries 8 directions).
func _free_spot_near(player: Player) -> Vector3:
	var space := player.get_world_3d().direct_space_state
	var feet := player.global_position
	for i in 8:
		var angle := TAU * float(i) / 8.0
		var dir := Vector3(sin(angle), 0.0, -cos(angle))
		var eye := feet + Vector3.UP * 1.0
		var q := PhysicsRayQueryParameters3D.create(eye, eye + dir * 1.8,
				Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM, [player.get_rid()])
		if not space.intersect_ray(q).is_empty():
			continue
		var spot := feet + dir * 1.3
		var down := PhysicsRayQueryParameters3D.create(spot + Vector3.UP * 0.5, spot + Vector3.DOWN * 2.0, Const.LAYER_WORLD)
		var hit := space.intersect_ray(down)
		if not hit.is_empty():
			return hit["position"]
	return feet + Vector3(0, 0, -1.3)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_report(ok: bool, what: String) -> void:
	# Client checks are counted on the host too, so the host's exit code covers both processes.
	if ok:
		_passes += 1
	else:
		_fails += 1

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_holding() -> void:
	_client_holding = true

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_dropped(pos: Vector3) -> void:
	_client_drop_pos = pos
	_client_dropped = true

@rpc("any_peer", "call_remote", "reliable")
func _rpc_client_done() -> void:
	_client_done = true

# ================================================================================================= client

func _run_client() -> void:
	var err := Game.start_join("127.0.0.1", _port, "Client")
	if err != OK or not await wait_until(func() -> bool: return Game.local_player != null, 20.0):
		print("FAIL: [client] could not join (err %s)" % error_string(err))
		_end(1)
		return
	var me := Game.local_player
	var my_id := multiplayer.get_unique_id()
	check(me.is_local() and me.peer_id == my_id, "joined as peer %d with a local Player" % my_id)
	check(await wait_until(func() -> bool: return _can_name != ""), "host announced the test can")
	var items := Game.world.items
	check(await wait_until(func() -> bool: return items.get_node_or_null(NodePath(_can_name)) != null), "can replicated to the client")
	var can := items.get_node(NodePath(_can_name)) as WateringCan
	var interactor := me.get_interactor()
	var cam := me.get_node("%Camera") as Camera3D
	# Face the can (body yaw, synced) and look down at it (camera pitch, local).
	me.look_at(Vector3(can.global_position.x, me.global_position.y, can.global_position.z), Vector3.UP)
	await frames(3)
	cam.look_at(can.global_position + Vector3(0, 0.2, 0), Vector3.UP)
	var expected_prompt := "Pick up Watering Can (%d/%d)" % [can.get_capacity(), can.get_capacity()]
	check(await wait_until(func() -> bool: return interactor.current_target == can and interactor.prompt_text == expected_prompt and interactor.prompt_enabled, 5.0),
			"client Interactor targets the can: '%s' (enabled=%s)" % [interactor.prompt_text, interactor.prompt_enabled])
	interactor.try_interact()
	check(await wait_until(func() -> bool: return can.holder_id == my_id, 5.0), "try_interact() -> server -> client holds the can")
	await frames(5)
	var socket := me.get_item_socket()
	check(socket == me.get_node("%HandSocket"), "client: own socket is the first-person %HandSocket")
	var expected := (socket.global_transform * can._get_hold_transform()).origin
	check(can.global_position.distance_to(expected) < 0.02, "client: can follows the first-person hand socket")
	check(not (can.get_node("ChargeLabel") as Label3D).visible and can.get_collider().collision_layer == 0,
			"client: held can hides its label, collision off")
	check(await wait_until(func() -> bool: return interactor.current_target != can, 2.0), "client: held can is not a ray target")
	_rpc_client_holding.rpc_id(1)
	check(await wait_until(func() -> bool: return _continue), "host checked the held state")
	interactor.try_drop()
	check(await wait_until(func() -> bool: return can.holder_id == 0, 5.0), "try_drop() -> server -> can on the floor")
	await frames(10)
	check(can.get_collider().collision_layer == Const.LAYER_ITEM and (can.get_node("ChargeLabel") as Label3D).visible,
			"client: dropped can collidable, label back")
	_rpc_client_dropped.rpc_id(1, can.global_position)
	await wait_until(func() -> bool: return _finish, 10.0)
	_rpc_client_done.rpc_id(1)
	await frames(10)
	_end(1 if _fails > 0 else 0)

@rpc("authority", "call_remote", "reliable")
func _rpc_start(can_name: String) -> void:
	_can_name = can_name

@rpc("authority", "call_remote", "reliable")
func _rpc_continue() -> void:
	_continue = true

@rpc("authority", "call_remote", "reliable")
func _rpc_finish() -> void:
	_finish = true

# ================================================================================================= common

func _end(code: int) -> void:
	if _role == "host" and _pid > 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	Net.leave()
	get_tree().quit(code)
