extends "res://tools/tests/qa_base.gd"
## M12 hostile multi-process suite (hostile agent), driven by tools/tests/hostile_mp.sh: a host and client A.
##   host: shift, plants GrowPlot2, spawns a hostile at GrowPlot1 (marker HOSTILE_SPAWNED), waits for it to walk over
##         and eat, waits for it to bite A, burns it with server_apply_fire, waits for A to leave.
##   a:    sees the HostilePlant node appear under World/Hostiles (hostile_spawned here), sees it move and reach the
##         EAT state (hostile_eating), walks up to it and gets bitten (its own player is stunned, hostile_bit names it),
##         sees hostile_died and the node go; leaves clean.
## Every engine/script error fails the run unless announced (qa_base.gd).

const JOIN_TIMEOUT := 25.0
const STEP_TIMEOUT := 45.0

var role: String = "host"
var port: int = 7956
var _spawned: Array = []
var _bit: Array = []
var _ate: Array = []
var _eating: Array = []
var _died: Array = []


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	port = int(Config.get_arg("port", 7956))
	_label = "hostile_mp:" + role
	await get_tree().process_frame
	Hostiles.hostile_spawned.connect(func(id: int, s: StringName, p: Vector3) -> void: _spawned.append([id, s, p]))
	Hostiles.hostile_bit.connect(func(id: int, peer: int) -> void: _bit.append([id, peer]))
	Hostiles.hostile_ate.connect(func(id: int, plot: int) -> void: _ate.append([id, plot]))
	Hostiles.hostile_eating.connect(func(id: int, plot: int) -> void: _eating.append([id, plot]))
	Hostiles.hostile_died.connect(func(id: int, by: int) -> void: _died.append([id, by]))
	match role:
		"host": await _host()
		"a": await _client_a()
	finish()


# --- host ------------------------------------------------------------------------------------------------------------

func _host() -> void:
	step("hosting on %d" % port)
	Config.growth_speed_override = 0.0
	Game.start_host("Host", port)
	await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 5.0, "world + local player")
	if Game.world == null:
		return
	print("HOSTILE_HOST_READY")
	await wait_until(func() -> bool: return Net.players.size() >= 2 and Game.world.get_players().size() >= 2, JOIN_TIMEOUT, "client A registered and spawned")
	GameState.request_start_round()
	await wait_until(func() -> bool: return GameState.is_playing(), 3.0, "PLAYING")
	var me: Player = Game.local_player
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(-8.0, 0.05, 6.0)
	var room := Game.world.room
	var sdef: SeedDef = Config.balance.seeds[0]
	var plot1 := room.get_station("GrowPlot1") as GrowPlot
	var plot2 := room.get_station("GrowPlot2") as GrowPlot
	check(plot2.server_plant(sdef.id) and plot2.server_water(1.0), "GrowPlot2 grows (something to walk to)")
	plot2.stage_progress = 0.95
	await wait_sec(0.5)

	step("spawn")
	var id := Hostiles.server_spawn(sdef.id, plot1.global_position)
	check(id > 0 and Hostiles.count() == 1, "hostile %d spawned at GrowPlot1" % id)
	print("HOSTILE_SPAWNED")
	var h := Hostiles.get_hostile(id) as HostilePlant
	check(h != null and _spawned.size() == 1 and _spawned[0][0] == id, "host: hostile_spawned(%d)" % id)
	await wait_until(func() -> bool: return is_instance_valid(h) and h.state == HostilePlant.State.EAT, 12.0, "host: it walked to GrowPlot2 and eats")
	check(_eating.size() >= 1 and _eating[0] == [id, 2], "host: hostile_eating(id, 2) %s" % [_eating])
	print("HOSTILE_EATING")

	step("bite")
	var a_id := _peer_a()
	check(a_id > 0, "client A's peer id %d" % a_id)
	await wait_until(func() -> bool: return _bit.any(func(e: Array) -> bool: return int(e[1]) == a_id), STEP_TIMEOUT, "host: it bit client A")
	check(GameState.get_stat(a_id, Const.STAT_BITTEN) >= 1, "host: STAT_BITTEN for A (%d)" % GameState.get_stat(a_id, Const.STAT_BITTEN))
	await wait_sec(1.0)

	step("fire")
	var burns0 := GameState.get_stat(1, Const.STAT_BURNS)
	for i in 4:
		Hostiles.server_apply_fire(id, 0.8, 1)
		await wait_frames(2)
	check(_died.size() == 1 and _died[0] == [id, 1], "host: hostile_died(id, 1) %s" % [_died])
	check(GameState.get_stat(1, Const.STAT_BURNS) == burns0 + 1, "host: STAT_BURNS for the shooter")
	await wait_until(func() -> bool: return Hostiles.count() == 0, 4.0, "host: the node is removed")
	print("HOSTILE_DEAD")
	# The client leaves: SceneMultiplayer may still flush a packet to a peer ENet has already reset (engine notice).
	allow_error("Unable to send packet on channel 0", 2, true)
	await wait_until(func() -> bool: return Net.players.size() <= 1, STEP_TIMEOUT, "client A left")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU, 5.0, "host: MENU")


func _peer_a() -> int:
	for pid in Net.players:
		if int(pid) != Const.SERVER_PEER_ID:
			return int(pid)
	return 0


# --- client A -------------------------------------------------------------------------------------------------------

func _client_a() -> void:
	step("joining %d" % port)
	Game.start_join("127.0.0.1", port, "Alpha")
	await wait_until(func() -> bool: return Game.local_player != null and Net.is_online(), JOIN_TIMEOUT, "A: joined and spawned")
	if Game.local_player == null:
		return
	await wait_until(func() -> bool: return Hostiles.count() >= 1, STEP_TIMEOUT, "A: the hostile node appeared")
	if Hostiles.count() == 0:
		await _leave()
		return
	var h := Hostiles.get_hostiles()[0] as HostilePlant
	check(h != null and h.id > 0 and h.strain_id == Config.balance.seeds[0].id, "A: HostilePlant %d, strain %s" % [h.id, h.strain_id])
	check(h.get_parent() == Game.world.get_node(^"Hostiles") and h.is_in_group(&"hostiles") and h.is_in_group(Const.GROUP_NPCS), "A: under World/Hostiles, in the groups")
	check(_spawned.size() == 1 and _spawned[0][0] == h.id and _spawned[0][1] == h.strain_id, "A: hostile_spawned here %s" % [_spawned])
	check(h.get_node_or_null(^"Visual") != null, "A: Visual child")
	var p0 := h.global_position
	await wait_until(func() -> bool: return is_instance_valid(h) and h.global_position.distance_to(p0) > 0.8, 15.0, "A: it moves here too")
	await wait_until(func() -> bool: return is_instance_valid(h) and h.state == HostilePlant.State.EAT, 15.0, "A: sees the EAT state")
	check(_eating.size() >= 1 and _eating.back()[0] == h.id and _eating.back()[1] == 2, "A: hostile_eating(id, 2) %s" % [_eating])

	step("A walks up to it")
	var me: Player = Game.local_player
	var my_id := multiplayer.get_unique_id()
	me.velocity = Vector3.ZERO
	me.global_position = h.global_position + Vector3(0.0, 0.05, 1.3)
	await wait_until(func() -> bool: return me.is_stunned(), STEP_TIMEOUT, "A: bitten (my player is stunned)")
	# The stagger goes to the owner first and the hostile_bit broadcast right after: two reliable packets, so the
	# second may land a poll later.
	await wait_until(func() -> bool: return _bit.size() >= 1, 3.0, "A: hostile_bit arrived")
	check(_bit.size() >= 1 and _bit[0][0] == h.id and _bit[0][1] == my_id, "A: hostile_bit(id, me) %s" % [_bit])
	await wait_until(func() -> bool: return GameState.get_stat(my_id, Const.STAT_BITTEN) >= 1, 5.0, "A: STAT_BITTEN synced")
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(0.0, 0.05, 3.0)

	step("A sees the death")
	await wait_until(func() -> bool: return _died.size() >= 1, STEP_TIMEOUT, "A: hostile_died arrived")
	check(_died.size() >= 1 and _died[0][0] == h.id and _died[0][1] == Const.SERVER_PEER_ID, "A: hostile_died(id, host) %s" % [_died])
	check(not is_instance_valid(h) or h.is_dead(), "A: the node is dead")
	await wait_until(func() -> bool: return Hostiles.count() == 0, 5.0, "A: the node is removed")
	await _leave()


func _leave() -> void:
	step("A leaves")
	Game.return_to_menu()
	await wait_until(func() -> bool: return GameState.phase == GameState.Phase.MENU and not Net.is_online(), 5.0, "A: MENU, offline")
	check(Hostiles.count() == 0, "A: nothing left")
