extends Node
## Hostiles (autoload, M12, owner: hostile agent). Server-authoritative hostile plants: a ready plant of a strain with
## `mutation_chance` can twitch for `mutation_warning_sec`, then uproot into a HostilePlant that roams the floor, eats
## growing plots and bites workers. Only fire kills it (the flamethrower, M12 flame agent). Do NOT add a class_name.
##
## Contract (CONTRACTS.md "M12"): hostile nodes (class HostilePlant, scenes/npcs/hostile_plant.tscn) are plain children
## of World/Hostiles on EVERY peer (like the rat: not spawned nodes, never reparented); the HOST runs the behaviour
## (HostilePlant.host_step from tick()) and syncs position / yaw at about 10 Hz (unreliable, clients smooth) and every
## state change reliably; a late joiner gets the current list on Net.peer_registered (_rpc_replay). Signals fire on
## every peer from the call_local RPC handlers. Story owns every line of copy; this file only emits and plays sounds.
##
## Mutation: the host polls the GrowPlots every tick: a plot seen READY for the first time gets one
## GrowPlot.server_roll_mutation(); while it is `turning` and the shift is PLAYING, GrowPlot.server_tick_mutation(delta)
## counts the warning down and spawns the hostile at the end (the roll and the countdown live in grow_plot.gd's
## `# --- M12 hostile ---` region; this file only drives them). A turning plot that stops being READY (harvested,
## reset, scorched) has its twitch cleared here.
##
## tick(delta) is public so tests can advance the behaviour deterministically (real time sub-stepped at 30 Hz);
## _physics_process feeds it real time on the host.

## Every peer: a hostile plant exists (after its node was added under World/Hostiles).
signal hostile_spawned(id: int, strain_id: StringName, position: Vector3)
## Every peer: hostile `id` bit worker `peer_id`.
signal hostile_bit(id: int, peer_id: int)
## Every peer: hostile `id` destroyed the crop in GrowPlot `plot_index`.
signal hostile_ate(id: int, plot_index: int)
## Every peer: hostile `id` burnt down (by_peer = the shooter, 0 = the shift ended).
signal hostile_died(id: int, by_peer: int)
## Every peer (addition): hostile `id` started eating GrowPlot `plot_index` (Story: "It is eating GrowPlot 2.").
signal hostile_eating(id: int, plot_index: int)

const SCENE_PATH := "res://scenes/npcs/hostile_plant.tscn"
const CONTAINER_PATH := ^"Hostiles"
const NODE_PREFIX := "Hostile"
## Position / yaw stream interval (seconds) and the behaviour sub-step for big test deltas.
const SYNC_INTERVAL := 0.1
const STEP_MAX := 1.0 / 30.0

var _next_id: int = 1
var _sync_accum: float = 0.0
## Host: GrowPlot instance id -> true once the mutation was rolled for its current READY.
var _rolled: Dictionary = {}
var _scene: PackedScene = null
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	GameState.round_ended.connect(_on_round_ended)
	GameState.game_reset.connect(_on_game_reset)
	GameState.phase_changed.connect(_on_phase_changed)
	Net.peer_registered.connect(_on_peer_registered)


func _physics_process(delta: float) -> void:
	if _is_host():
		tick(delta)


# ------------------------------------------------------------------------------------------------------
# Server API
# ------------------------------------------------------------------------------------------------------

## SERVER. Adds a hostile plant of `strain_id` at `position` (global, floor). Returns its id, 0 when refused
## (hostile_max reached, no world).
func server_spawn(strain_id: StringName, position: Vector3) -> int:
	if not _is_host():
		push_warning("Hostiles.server_spawn called on a non-host peer")
		return 0
	if _container() == null or not position.is_finite():
		return 0
	if not has_room():
		return 0
	var id := _next_id
	_next_id += 1
	_rpc_spawn.rpc(id, strain_id, Vector3(position.x, 0.0, position.z), _rng.randf_range(-PI, PI))
	return id


## SERVER. Removes every hostile plant at once (shift end / reset), without `hostile_died` credit.
func server_despawn_all() -> void:
	if not _is_host():
		return
	if get_hostiles().is_empty():
		return
	_rpc_despawn_all.rpc()


## SERVER. `seconds` of flame reached hostile `id` (the flamethrower calls this every physics tick it is in the cone);
## after Config.balance.hostile_burn_sec in total it dies and `by_peer` gets Const.STAT_BURNS.
func server_apply_fire(id: int, seconds: float, by_peer: int) -> void:
	if not _is_host():
		return
	var h := get_hostile(id) as HostilePlant
	if h == null or h.is_dead():
		return
	h.apply_fire(seconds, by_peer)


## Host time step: the mutation watch, every hostile's behaviour (sub-stepped), dead ones removed after their delay,
## the pose stream. Public so tests can advance time; _physics_process calls it with real time on the host.
func tick(delta: float) -> void:
	if not _is_host() or delta <= 0.0:
		return
	# The list first: a hostile the mutation watch spawns during this tick starts stepping next tick (it stands at
	# its tray for the whole ROOT_SEC even when a test advances time in big steps).
	var hostiles := get_hostiles()
	_tick_mutations(delta)
	if hostiles.is_empty():
		return
	var remaining := delta
	while remaining > 0.000001: # (not > 0: 0.1 s in 1/30 s steps leaves a float residue, a fourth step of ~1e-9 s)
		var step := minf(remaining, STEP_MAX)
		remaining -= step
		for n in hostiles:
			var h := n as HostilePlant
			if h != null and is_instance_valid(h) and h.is_inside_tree():
				h.host_step(step)
	for n in hostiles:
		var h := n as HostilePlant
		if h != null and is_instance_valid(h) and h.is_dead() and h.get_death_elapsed() >= HostilePlant.DEATH_DELAY:
			_rpc_despawn.rpc(h.id)
	_sync_accum += delta
	if _sync_accum >= SYNC_INTERVAL:
		_sync_accum = 0.0
		_broadcast_poses()


# ------------------------------------------------------------------------------------------------------
# Queries (any peer)
# ------------------------------------------------------------------------------------------------------

## Every peer: the live hostile nodes (class HostilePlant, group "hostiles"), children of World/Hostiles. A dead one
## stays in the list until its node is removed (HostilePlant.is_dead()).
func get_hostiles() -> Array[Node3D]:
	var out: Array[Node3D] = []
	var container := _container()
	if container == null:
		return out
	for c in container.get_children():
		var h := c as HostilePlant
		if h != null and not h.is_queued_for_deletion():
			out.append(h)
	return out


func get_hostile(id: int) -> Node3D:
	for n in get_hostiles():
		if (n as HostilePlant).id == id:
			return n
	return null


func count() -> int:
	return get_hostiles().size()


func is_any_alive() -> bool:
	for n in get_hostiles():
		if not (n as HostilePlant).is_dead():
			return true
	return false


## M13 review: true while fewer than Config.balance.hostile_max plants are alive on the floor (a burnt one still
## lying there does not count). server_spawn refuses without room; a turning tray waits for it (GrowPlot.
## server_tick_mutation), so its crop is not lost for a plant that could never come out.
func has_room() -> bool:
	var alive := 0
	for n in get_hostiles():
		if not (n as HostilePlant).is_dead():
			alive += 1
	return alive < Config.balance.hostile_max


## The nearest live hostile to `position`, or null.
func nearest_to(position: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	for n in get_hostiles():
		if (n as HostilePlant).is_dead() or not n.is_inside_tree():
			continue
		var d := n.global_position.distance_to(position)
		if d < best_d:
			best_d = d
			best = n
	return best


## The late-join payload: one entry per live hostile ({id, strain, pos, yaw, state}). _rpc_replay takes it.
func get_replay_entries() -> Array:
	var out: Array = []
	for n in get_hostiles():
		var h := n as HostilePlant
		if h.is_dead() or not h.is_inside_tree():
			continue
		out.append({"id": h.id, "strain": h.strain_id, "pos": h.global_position, "yaw": h.rotation.y, "state": h.state})
	return out


# ------------------------------------------------------------------------------------------------------
# Host internals
# ------------------------------------------------------------------------------------------------------

func _is_host() -> bool:
	return Net.is_host and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


## The mutation watch (see the header).
func _tick_mutations(delta: float) -> void:
	if Game.world == null or not is_instance_valid(Game.world):
		_rolled.clear()
		return
	var playing := GameState.is_playing()
	var seen: Dictionary = {}
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var plot := n as GrowPlot
		if plot == null or not plot.is_inside_tree():
			continue
		var key := plot.get_instance_id()
		if plot.stage == GrowPlot.Stage.READY:
			seen[key] = true
			if not _rolled.has(key):
				_rolled[key] = true
				plot.server_roll_mutation()
			elif plot.turning and playing:
				plot.server_tick_mutation(delta)
		elif plot.turning:
			plot.turning = false
	for key in _rolled.keys():
		if not seen.has(key):
			_rolled.erase(key)


## Host: position / yaw of every live hostile to every client (unreliable, ~10 Hz).
func _broadcast_poses() -> void:
	if multiplayer.get_peers().is_empty():
		return
	var poses: Array = []
	for n in get_hostiles():
		var h := n as HostilePlant
		if h.is_dead() or not h.is_inside_tree():
			continue
		poses.append([h.id, h.global_position, h.rotation.y])
	if not poses.is_empty():
		_rpc_poses.rpc(poses)


## Host: the node's behaviour signals become RPCs.
func _connect_host_signals(h: HostilePlant) -> void:
	h.state_changed.connect(func(s: int) -> void:
		if is_instance_valid(h) and h.is_inside_tree():
			_rpc_state.rpc(h.id, s, h.global_position, h.rotation.y, h.get_target_index()))
	h.bit.connect(func(peer_id: int) -> void:
		if is_instance_valid(h):
			_rpc_bit.rpc(h.id, peer_id))
	h.ate.connect(func(plot_index: int) -> void:
		if is_instance_valid(h):
			_rpc_ate.rpc(h.id, plot_index))
	h.died.connect(func(by_peer: int) -> void:
		if is_instance_valid(h):
			_rpc_died.rpc(h.id, by_peer)
		if by_peer > 0:
			GameState.server_add_stat(by_peer, Const.STAT_BURNS))


# ------------------------------------------------------------------------------------------------------
# Sync (RPC handlers run on every peer, the host included via call_local)
# ------------------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_spawn(id: int, strain_id: StringName, position: Vector3, yaw: float) -> void:
	var h := _create(id, strain_id, position, yaw, HostilePlant.State.ROOT)
	if h == null:
		return
	Sfx.play(&"hostile_rise", position + Vector3.UP * 0.5)
	hostile_spawned.emit(id, strain_id, position)


## A state change (reliable). Clients snap the pose that came with it; the host already holds the state.
@rpc("authority", "call_local", "reliable")
func _rpc_state(id: int, state: int, position: Vector3, yaw: float, target_index: int) -> void:
	var h := get_hostile(id) as HostilePlant
	if h == null:
		return
	if not _is_host():
		h.apply_sync(position, yaw, true)
	h.state = state
	if state == HostilePlant.State.EAT and target_index > 0:
		hostile_eating.emit(id, target_index)


@rpc("authority", "call_remote", "unreliable")
func _rpc_poses(poses: Array) -> void:
	if _is_host():
		return
	for entry in poses:
		if not (entry is Array) or (entry as Array).size() < 3:
			continue
		var e: Array = entry
		if not (e[0] is int) or not (e[1] is Vector3) or not (e[2] is float):
			continue
		var h := get_hostile(int(e[0])) as HostilePlant
		if h != null and not h.is_dead():
			h.apply_sync(e[1], float(e[2]))


@rpc("authority", "call_local", "reliable")
func _rpc_bit(id: int, peer_id: int) -> void:
	var h := get_hostile(id) as HostilePlant
	if h != null:
		h.play_bite_fx()
	hostile_bit.emit(id, peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_ate(id: int, plot_index: int) -> void:
	hostile_ate.emit(id, plot_index)


@rpc("authority", "call_local", "reliable")
func _rpc_died(id: int, by_peer: int) -> void:
	var h := get_hostile(id) as HostilePlant
	if h != null:
		h.state = HostilePlant.State.DEAD
	hostile_died.emit(id, by_peer)


@rpc("authority", "call_local", "reliable")
func _rpc_despawn(id: int) -> void:
	var h := get_hostile(id) as HostilePlant
	if h != null:
		_free_node(h)


@rpc("authority", "call_local", "reliable")
func _rpc_despawn_all() -> void:
	for n in get_hostiles():
		_free_node(n as HostilePlant)


## The late-join list (also idempotent on a peer that already has some of them): entries from get_replay_entries().
## Missing hostiles are created in their current state (no rise sound), known ones are snapped, unlisted ones freed.
@rpc("authority", "call_local", "reliable")
func _rpc_replay(entries: Array) -> void:
	var keep: Dictionary = {}
	for entry in entries:
		if not (entry is Dictionary):
			continue
		var e: Dictionary = entry
		var id := int(e.get("id", 0))
		var pos: Variant = e.get("pos", Vector3.INF)
		if id <= 0 or not (pos is Vector3) or not (pos as Vector3).is_finite():
			continue
		keep[id] = true
		var yaw := float(e.get("yaw", 0.0))
		var state := clampi(int(e.get("state", HostilePlant.State.ROAM)), HostilePlant.State.ROOT, HostilePlant.State.DEAD)
		var h := get_hostile(id) as HostilePlant
		if h == null:
			h = _create(id, StringName(e.get("strain", &"")), pos, yaw, state)
			if h != null:
				hostile_spawned.emit(id, h.strain_id, pos)
		else:
			if not _is_host():
				h.apply_sync(pos, yaw, true)
			h.state = state
	for n in get_hostiles():
		var h := n as HostilePlant
		if not keep.has(h.id):
			_free_node(h)


## Host: a late joiner gets the current list.
func _on_peer_registered(peer_id: int) -> void:
	if not _is_host():
		return
	var entries := get_replay_entries()
	if not entries.is_empty():
		_rpc_replay.rpc_id(peer_id, entries)


# ------------------------------------------------------------------------------------------------------
# Nodes (every peer)
# ------------------------------------------------------------------------------------------------------

func _container() -> Node3D:
	var w: World = Game.world
	if w == null or not is_instance_valid(w) or not w.is_inside_tree():
		return null
	return w.get_node_or_null(CONTAINER_PATH) as Node3D


func _create(id: int, strain_id: StringName, position: Vector3, yaw: float, state: int) -> HostilePlant:
	var container := _container()
	if container == null:
		return null
	if _scene == null:
		_scene = load(SCENE_PATH) as PackedScene
	if _scene == null:
		push_error("Hostiles: cannot load %s" % SCENE_PATH)
		return null
	var h := _scene.instantiate() as HostilePlant
	if h == null:
		push_error("Hostiles: %s is not a HostilePlant scene" % SCENE_PATH)
		return null
	h.name = "%s%d" % [NODE_PREFIX, id]
	h.setup(id, strain_id, position, yaw, state)
	container.add_child(h)
	if _is_host():
		_next_id = maxi(_next_id, id + 1)
		_connect_host_signals(h)
	return h


func _free_node(h: HostilePlant) -> void:
	if h == null or not is_instance_valid(h) or h.is_queued_for_deletion():
		return
	h.name = String(h.name) + "_gone"
	h.queue_free()


# ------------------------------------------------------------------------------------------------------
# Shift flow
# ------------------------------------------------------------------------------------------------------

func _on_round_ended(_success: bool, _round_number: int) -> void:
	server_despawn_all()


func _on_game_reset() -> void:
	server_despawn_all()
	_rolled.clear()


func _on_phase_changed(phase: int) -> void:
	if phase == GameState.Phase.MENU:
		# The world is about to go (and its hostiles with it): forget the session's bookkeeping.
		_rolled.clear()
		_sync_accum = 0.0


# --- M16 variety: the run's dice ---------------------------------------------------------------------------------

## SERVER ONLY. Reseeds this autoload's dice (the way a new hostile plant faces) from `seed_value`. With replay on
## the host calls it once per shift with RunSeed.stream(run seed, "hostiles:<shift>") (GameState's `M16 variety`
## region). Which plant turns is rolled in grow_plot.gd; where one wanders is each plant's own dice.
func server_seed(seed_value: int) -> void:
	if not _is_host():
		push_warning("Hostiles.server_seed called on a non-host peer")
		return
	_rng.seed = RunSeed.stream(seed_value, &"spawn")

# --- end M16 variety -----------------------------------------------------------------------------------------------
