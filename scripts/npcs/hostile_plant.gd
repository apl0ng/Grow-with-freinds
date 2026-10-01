class_name HostilePlant
extends Node3D
## The hostile plant (M12, hostile agent): a ready plant that uprooted itself. It roots for two seconds where its
## tray was, roams to the nearest growing plot and eats it, chases any worker who comes close and bites them (a
## stagger, the item knocked out of their hands). Only fire kills it. Nobody is happy about any of this.
##
## Networking (CONTRACTS.md "M12"): a plain child of World/Hostiles on EVERY peer, created and removed by the
## Hostiles autoload's reliable RPCs (never a spawned node, never reparented). The HOST owns the behaviour: Hostiles
## drives host_step() from its tick, this node moves itself and reports through the signals below, which Hostiles turns
## into RPCs. Clients get `state` through a reliable RPC and position / yaw at ~10 Hz unreliable (apply_sync) and
## smooth toward them. Every cosmetic (rise, waddle, chomp, lunge, shiver, collapse, sounds) is a pure function of
## `state` + local time, so it runs the same on every peer.
##
## Scene (scenes/npcs/hostile_plant.tscn): origin at the feet, faces -Z, about 1.1 m tall.
##   Visual                 placeholder meshes (Juice / the animation squash THIS, never the root)
##   Visual/Legs/Root1..3   root legs (library soil material)
##   Visual/Bulb            the bud pivot (nods while eating); Visual/Bulb/Mouth chomps
##   BlobShadow             flat disc, outside Visual
##   Body/Shape             StaticBody3D on Const.LAYER_WORLD (workers cannot walk through it; disabled when DEAD)
## Swapping in the strains agent's hostile_plant.glb: instance it as `Visual/Model` (a Toonify root, outline_width
## 0.025) and delete the placeholder meshes; _apply_tint() recolours any Toonify under Visual with the graded strain
## colour (TINT* parts) and any MeshInstance3D tagged `metadata/strain_tint = true`. `Visual/Bulb` and
## `Visual/Bulb/Mouth` are optional: name those parts in the model to keep the nod and the chomp.
## Groups: Const.GROUP_HOSTILES ("hostiles") + Const.GROUP_NPCS.

## HOST only: the state changed (Hostiles broadcasts it reliably).
signal state_changed(state: int)
## HOST only: this plant bit worker `peer_id` (the stagger, the released item and STAT_BITTEN already landed).
signal bit(peer_id: int)
## HOST only: the crop in GrowPlot `plot_index` was eaten to nothing (the plot is already reset).
signal ate(plot_index: int)
## HOST only: burnt down (by_peer = the shooter, 0 = nobody).
signal died(by_peer: int)

enum State { ROOT, ROAM, EAT, CHASE, BITE, BURNING, DEAD }

const STATE_NAMES: Array[String] = ["Rooting", "Roaming", "Eating", "Chasing", "Biting", "Burning", "Dead"]
## Seconds it stands where its tray was before it moves.
const ROOT_SEC := 2.0
## A worker this close gets bitten.
const BITE_RANGE := 1.7   # the plant is 2x (about 1.8 m wide): it bites from further out
## It stops a little short of the bite range so the collider does not shove the worker around.
const CHASE_STOP := 1.3
## Standing distance from a plot centre while eating (just outside the 1.3 m tray).
const EAT_DISTANCE := 1.3
const ARRIVE := 0.08
## Bites in a row before it loses interest and goes back to the trays.
const BITES_BEFORE_CALM := 2
## Seconds it ignores workers after those bites.
const CALM_SEC := 5.0
## It gives up a chase when the worker gets this many times the sense range away.
const CHASE_GIVE_UP_FACTOR := 1.4
## The lunge pose.
const BITE_SEC := 0.3
## Movement while flame is on it, and how long after the last flame it keeps flailing.
const BURNING_SPEED_FACTOR := 0.5
const BURN_FLAIL_SEC := 0.6
## Seconds a dead plant lies there before Hostiles removes the node.
const DEATH_DELAY := 1.5
## Idle wander when no plot grows.
const WANDER_RADIUS := 2.5
const WANDER_PAUSE_SEC := 1.2
const ROOM_MARGIN := 0.7
## Clients: smoothing toward the synced pose; a jump bigger than SNAP_DISTANCE snaps.
const SYNC_SMOOTHING := 12.0
const SNAP_DISTANCE := 3.0
const TURN_RATE := 10.0
## Obstacle probe (host): a ray on LAYER_WORLD at this height, this far past the step; trays and hostiles excluded.
const PROBE_HEIGHT := 0.8
const PROBE_MARGIN := 0.7
const TINT_META: StringName = &"strain_tint"

## Set by Hostiles (every peer) before the node enters the tree.
var id: int = 0
var strain_id: StringName = &""
## Every peer. Written by the host's behaviour and by Hostiles' RPC handlers on clients.
var state: int = State.ROOT:
	set(value):
		if value == state:
			return
		var old: int = state
		state = value
		_state_time = 0.0
		_on_state_changed(old)

# Host: behaviour bookkeeping.
var _root_left: float = ROOT_SEC
var _target_plot: GrowPlot = null
var _stand_point: Vector3 = Vector3.ZERO
var _target_peer: int = 0
var _bites: int = 0
var _bite_cooldown: float = 0.0
var _bite_left: float = 0.0
var _calm_left: float = 0.0
var _burn: float = 0.0
var _burn_recent: float = 0.0
var _dead_time: float = 0.0
var _wander_target: Vector3 = Vector3.INF
var _wander_pause: float = 0.0
var _rng := RandomNumberGenerator.new()

# Every peer: synced pose (clients smooth toward it) and cosmetics.
var _net_pos: Vector3 = Vector3.ZERO
var _net_yaw: float = 0.0
var _has_net: bool = false
var _t: float = 0.0
var _state_time: float = 0.0
var _eat_loop: int = 0
var _visual: Node3D
var _bulb: Node3D
var _mouth: Node3D
## The modelled jaw (art/models/hostile_plant.glb: Visual/Jaw, rest rotation identity; -35 degrees on X drops it open).
var _jaw: Node3D
var _body: CollisionObject3D
var _shape: CollisionShape3D


func _enter_tree() -> void:
	add_to_group(Const.GROUP_HOSTILES)
	add_to_group(Const.GROUP_NPCS)


func _ready() -> void:
	_rng.randomize()
	_visual = get_node_or_null(^"Visual") as Node3D
	_bulb = get_node_or_null(^"Visual/Bulb") as Node3D
	_mouth = get_node_or_null(^"Visual/Bulb/Mouth") as Node3D
	_jaw = get_node_or_null(^"Visual/Model/Jaw") as Node3D
	_body = get_node_or_null(^"Body") as CollisionObject3D
	_shape = get_node_or_null(^"Body/Shape") as CollisionShape3D
	_apply_tint()
	if state == State.DEAD and _shape != null:
		_shape.set_deferred(&"disabled", true)


func _exit_tree() -> void:
	_stop_eat_loop()


func _process(delta: float) -> void:
	_t += delta
	_state_time += delta
	if _has_net and not Net.is_host:
		var k := 1.0 - exp(-delta * SYNC_SMOOTHING)
		if global_position.distance_to(_net_pos) > SNAP_DISTANCE:
			global_position = _net_pos
		else:
			global_position = global_position.lerp(_net_pos, k)
		rotation.y = lerp_angle(rotation.y, _net_yaw, k)
	_animate()


# --- Setup / sync (Hostiles, every peer) --------------------------------------------------------------------------

## Called by Hostiles before add_child on every peer.
func setup(new_id: int, new_strain: StringName, position_in: Vector3, yaw: float, initial_state: int) -> void:
	id = new_id
	strain_id = new_strain
	position = position_in
	rotation = Vector3(0.0, yaw, 0.0)
	_net_pos = position_in
	_net_yaw = yaw
	_has_net = true
	state = initial_state


## Clients: the host's pose (smoothed in _process; `snap` places it at once).
func apply_sync(position_in: Vector3, yaw: float, snap: bool = false) -> void:
	if not position_in.is_finite() or not is_finite(yaw):
		return
	_net_pos = position_in
	_net_yaw = yaw
	_has_net = true
	if snap:
		global_position = position_in
		rotation.y = yaw


## The lunge pose + bite sound on every peer (Hostiles' cosmetic RPC).
func play_bite_fx() -> void:
	_state_time = 0.0
	if is_inside_tree():
		Sfx.play(&"hostile_bite", global_position + Vector3.UP * 0.7)


# --- Queries (any peer) -------------------------------------------------------------------------------------------

func is_dead() -> bool:
	return state == State.DEAD


func get_state_name() -> String:
	return STATE_NAMES[state]


## Seconds of flame taken so far (host; 0 elsewhere).
func get_burn() -> float:
	return _burn


## Seconds since it died (host).
func get_death_elapsed() -> float:
	return _dead_time


## EAT: the GrowPlot index (1..6) it eats; CHASE / BITE: the worker's peer id; else 0.
func get_target_index() -> int:
	match state:
		State.EAT:
			return plot_index_of(_target_plot)
		State.CHASE, State.BITE:
			return _target_peer
	return 0


func get_target_plot() -> GrowPlot:
	return _target_plot if _plot_ok(_target_plot) else null


## 1..6 from a GrowPlot node name, 0 for anything else.
static func plot_index_of(plot: Node) -> int:
	if plot == null or not is_instance_valid(plot):
		return 0
	var n := String(plot.name)
	if not n.begins_with("GrowPlot"):
		return 0
	return n.trim_prefix("GrowPlot").to_int()


# --- Host behaviour -----------------------------------------------------------------------------------------------

## HOST. One behaviour step (Hostiles.tick sub-steps real time into these). Moves the node directly.
func host_step(delta: float) -> void:
	if delta <= 0.0 or not is_inside_tree():
		return
	_calm_left = maxf(_calm_left - delta, 0.0)
	_bite_cooldown = maxf(_bite_cooldown - delta, 0.0)
	var b: BalanceConfig = Config.balance
	match state:
		State.ROOT:
			_root_left -= delta
			if _root_left <= 0.0:
				state = State.ROAM
		State.ROAM:
			if _try_start_chase(b):
				return
			if not _plot_ok(_target_plot):
				_pick_plot()
			if _target_plot != null:
				if _move_toward(_stand_point, b.hostile_speed, delta):
					_wander_target = Vector3.INF
					state = State.EAT
			else:
				_wander(b.hostile_speed, delta)
		State.EAT:
			if _try_start_chase(b):
				return
			if not _plot_ok(_target_plot):
				_target_plot = null
				state = State.ROAM
				return
			_face_point(_target_plot.global_position, delta)
			_target_plot.stage_progress = _target_plot.stage_progress - b.hostile_eat_per_sec * delta
			if _target_plot.stage_progress <= 0.0:
				var idx := plot_index_of(_target_plot)
				_target_plot.server_reset()
				_target_plot = null
				state = State.ROAM
				ate.emit(idx)
		State.CHASE:
			var target := _chase_target(b)
			if target == null:
				_target_peer = 0
				state = State.ROAM
				return
			var flat := target.global_position - global_position
			flat.y = 0.0
			var dist := flat.length()
			if dist <= BITE_RANGE:
				_face_point(target.global_position, delta)
				if _bite_cooldown <= 0.0 and target.can_be_staggered():
					_bite(target, flat, b)
			elif dist > CHASE_STOP:
				_move_toward(target.global_position, b.hostile_speed, delta, CHASE_STOP)
			else:
				_face_point(target.global_position, delta)
		State.BITE:
			_bite_left -= delta
			if _bite_left <= 0.0:
				if _bites >= BITES_BEFORE_CALM:
					_bites = 0
					_calm_left = CALM_SEC
					_target_peer = 0
					state = State.ROAM
				else:
					state = State.CHASE
		State.BURNING:
			_burn_recent -= delta
			if _burn_recent <= 0.0:
				state = State.CHASE if _target_peer > 0 else State.ROAM
				return
			# Flailing: it keeps going where it was going, at half speed; no bites, no eating.
			var target := _chase_target(b)
			if target != null:
				_move_toward(target.global_position, b.hostile_speed * BURNING_SPEED_FACTOR, delta, CHASE_STOP)
			elif _plot_ok(_target_plot):
				_move_toward(_stand_point, b.hostile_speed * BURNING_SPEED_FACTOR, delta)
		State.DEAD:
			_dead_time += delta


## HOST. `seconds` of flame reached it. True when this call killed it (the `died` signal fired).
func apply_fire(seconds: float, by_peer: int) -> bool:
	if state == State.DEAD or seconds <= 0.0 or not is_finite(seconds):
		return false
	_burn += seconds
	_burn_recent = BURN_FLAIL_SEC
	if _burn >= Config.balance.hostile_burn_sec:
		_die(by_peer)
		return true
	if state != State.BURNING:
		state = State.BURNING
	return false


func _die(by_peer: int) -> void:
	_dead_time = 0.0
	_target_plot = null
	_target_peer = 0
	state = State.DEAD
	died.emit(by_peer)


## The nearest worker within hostile_sense_range who is on the floor (not in the back room), unless calm.
func _try_start_chase(b: BalanceConfig) -> bool:
	if _calm_left > 0.0:
		return false
	var target := _nearest_worker(b.hostile_sense_range)
	if target == null:
		return false
	_target_peer = target.peer_id
	_bites = 0
	state = State.CHASE
	return true


func _chase_target(b: BalanceConfig) -> Player:
	if _target_peer <= 0:
		return null
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return null
	var p := w.get_player(_target_peer)
	if p == null or not p.is_inside_tree() or GameState.is_in_backroom(_target_peer):
		return null
	var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
	if not (d <= b.hostile_sense_range * CHASE_GIVE_UP_FACTOR):
		return null
	return p


func _nearest_worker(range_m: float) -> Player:
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return null
	var best: Player = null
	var best_d := range_m
	for p in w.get_players():
		if not p.is_inside_tree() or GameState.is_in_backroom(p.peer_id):
			continue
		var d := Vector2(p.global_position.x - global_position.x, p.global_position.z - global_position.z).length()
		if d <= best_d:
			best_d = d
			best = p
	return best


func _bite(target: Player, flat: Vector3, b: BalanceConfig) -> void:
	var away := flat
	if not away.is_finite() or away.length_squared() < 0.000001:
		away = target.get_flat_forward() * -1.0
	away = away.normalized()
	# The contract's call: the worker is shoved away from the plant with the bite stun, as a hit (bonk). from_behind is
	# false, so the held item is released explicitly.
	target.server_shove(target, away, false, b.hostile_bite_stun_sec, true)
	var w: World = Game.world
	if w != null and is_instance_valid(w) and w.items != null:
		w.items.server_release_holder(target.peer_id)
	GameState.server_add_stat(target.peer_id, Const.STAT_BITTEN)
	_bites += 1
	_bite_cooldown = maxf(b.hostile_bite_cooldown_sec, 0.0)
	_bite_left = BITE_SEC
	state = State.BITE
	bit.emit(target.peer_id)


func _pick_plot() -> void:
	_target_plot = null
	var best_d := INF
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var plot := n as GrowPlot
		if not _plot_ok(plot):
			continue
		var d := Vector2(plot.global_position.x - global_position.x, plot.global_position.z - global_position.z).length()
		if d < best_d:
			best_d = d
			_target_plot = plot
	if _target_plot == null:
		return
	var from := global_position - _target_plot.global_position
	from.y = 0.0
	if from.length_squared() < 0.0001:
		from = Vector3(0.0, 0.0, 1.0)
	_stand_point = _target_plot.global_position + from.normalized() * EAT_DISTANCE
	_stand_point.y = global_position.y


static func _plot_ok(plot: GrowPlot) -> bool:
	return plot != null and is_instance_valid(plot) and plot.is_inside_tree() and plot.is_growing()


## No tray grows: short walks to random points nearby, a pause between them.
func _wander(speed: float, delta: float) -> void:
	if _wander_pause > 0.0:
		_wander_pause -= delta
		return
	if not _wander_target.is_finite():
		var angle := _rng.randf_range(-PI, PI)
		var r := _rng.randf_range(1.0, WANDER_RADIUS)
		var p := global_position + Vector3(cos(angle), 0.0, sin(angle)) * r
		var w: World = Game.world
		if w != null and is_instance_valid(w) and w.room != null:
			var bounds: AABB = w.room.get_bounds()
			p.x = clampf(p.x, bounds.position.x + ROOM_MARGIN, bounds.end.x - ROOM_MARGIN)
			p.z = clampf(p.z, bounds.position.z + ROOM_MARGIN, bounds.end.z - ROOM_MARGIN)
		_wander_target = Vector3(p.x, global_position.y, p.z)
	if _move_toward(_wander_target, speed, delta):
		_wander_target = Vector3.INF
		_wander_pause = WANDER_PAUSE_SEC


## Walks toward `point` (flat), facing the way it goes, never through LAYER_WORLD (slides along it when it can).
## Returns true once within `stop` of the point.
func _move_toward(point: Vector3, speed: float, delta: float, stop: float = ARRIVE) -> bool:
	var to := point - global_position
	to.y = 0.0
	var dist := to.length()
	if dist <= stop:
		return true
	var dir := to / dist
	_face(dir, delta)
	var step := minf(dist - stop, speed * delta)
	var hit := _probe(dir, step + PROBE_MARGIN)
	if not hit.is_empty():
		var n: Vector3 = hit.get("normal", Vector3.ZERO)
		n.y = 0.0
		var slide := dir - n * dir.dot(n) if n.length_squared() > 0.0001 else Vector3.ZERO
		if slide.length_squared() < 0.01:
			return false
		slide = slide.normalized()
		if not _probe(slide, step + PROBE_MARGIN).is_empty():
			return false
		dir = slide
	global_position += dir * step
	return dist - step <= stop


func _probe(dir: Vector3, length: float) -> Dictionary:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	if space == null:
		return {}
	var from := global_position + Vector3.UP * PROBE_HEIGHT
	var query := PhysicsRayQueryParameters3D.create(from, from + dir * length, Const.LAYER_WORLD, _probe_excludes())
	return space.intersect_ray(query)


## Its own collider, the other hostiles and every tray: it walks off the tray it came from and up to the next one.
func _probe_excludes() -> Array[RID]:
	var out: Array[RID] = []
	if _body != null:
		out.append(_body.get_rid())
	for n in get_tree().get_nodes_in_group(Const.GROUP_HOSTILES):
		if n == self:
			continue
		var body := n.get_node_or_null(^"Body") as CollisionObject3D
		if body != null:
			out.append(body.get_rid())
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var body := n.get_node_or_null(^"Body") as CollisionObject3D
		if body != null:
			out.append(body.get_rid())
	return out


func _face(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	var target_yaw := atan2(-dir.x, -dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 1.0 - exp(-delta * TURN_RATE))


func _face_point(point: Vector3, delta: float) -> void:
	var dir := point - global_position
	dir.y = 0.0
	_face(dir, delta)


# --- Presentation (every peer; a function of `state` + local time) ------------------------------------------------

func _on_state_changed(old: int) -> void:
	if is_node_ready():
		_apply_state_fx(old)
	state_changed.emit(state)


func _apply_state_fx(_old: int) -> void:
	if state == State.EAT:
		_start_eat_loop()
	else:
		_stop_eat_loop()
	_apply_tint()
	if _shape != null:
		_shape.set_deferred(&"disabled", state == State.DEAD)
	if state == State.DEAD and is_inside_tree():
		var pos := global_position + Vector3.UP * 0.6
		Sfx.play(&"hostile_die", pos)
		GrowPlot.juice_fx(&"puff", pos, Juice.GLOOM, 6)


func _start_eat_loop() -> void:
	if _eat_loop == 0 and is_inside_tree():
		_eat_loop = Sfx.play_loop(&"hostile_eat", self)


func _stop_eat_loop() -> void:
	if _eat_loop != 0:
		Sfx.stop_loop(_eat_loop)
		_eat_loop = 0


## Strain colour on the bud: graded (Toon.grade) for data colours; darker while burning, ash when dead.
func _apply_tint() -> void:
	if _visual == null:
		return
	var sdef: SeedDef = Config.balance.get_seed(strain_id) if strain_id != &"" else null
	var base := Toon.grade(sdef.color) if sdef != null else Toon.BUD
	var color := base
	match state:
		State.BURNING:
			color = Toon.darker(base, 0.55)
		State.DEAD:
			color = Toon.darker(Toon.PEBBLE, 0.4)
	for n in _visual.find_children("*", "Node3D", true, false):
		if n is Toonify:
			(n as Toonify).tint = color
		elif n is MeshInstance3D and n.has_meta(TINT_META):
			(n as MeshInstance3D).material_override = Toon.material(color)
	if _visual is Toonify:
		(_visual as Toonify).tint = color


func _animate() -> void:
	if _visual == null:
		return
	var v := _visual
	var mouth_open := 0.0
	var nod := 0.0
	match state:
		State.ROOT:
			var k := clampf(_state_time / ROOT_SEC, 0.0, 1.0)
			v.scale = Vector3(1.0, lerpf(0.25, 1.0, ease(k, 0.5)), 1.0)
			v.rotation = Vector3(0.0, 0.0, sin(_t * 31.0) * 0.05 * (1.0 - k))
			v.position = Vector3.ZERO
		State.ROAM, State.CHASE:
			var hz := 3.4 if state == State.CHASE else 2.2
			var ph := _t * TAU * hz
			v.rotation = Vector3(0.0, 0.0, sin(ph * 0.5) * 0.09)
			v.scale = Vector3(1.0, 1.0 + 0.04 * absf(sin(ph)), 1.0)
			v.position = Vector3(0.0, 0.03 * absf(sin(ph)), 0.0)
		State.EAT:
			var ph := _t * TAU * 2.5
			v.rotation = Vector3.ZERO
			v.position = Vector3.ZERO
			v.scale = Vector3(1.0, 1.0 + 0.05 * sin(ph), 1.0)
			nod = -0.22 + 0.18 * sin(ph)
			mouth_open = 0.5 + 0.5 * sin(ph)
		State.BITE:
			var k := clampf(_state_time / BITE_SEC, 0.0, 1.0)
			v.rotation = Vector3.ZERO
			v.scale = Vector3.ONE
			v.position = Vector3(0.0, 0.0, -0.22 * sin(k * PI))
			nod = -0.35 * sin(k * PI)
			mouth_open = 1.0 - k
		State.BURNING:
			v.rotation = Vector3(0.0, 0.0, sin(_t * 47.0) * 0.12)
			v.scale = Vector3(1.0, 1.0 + 0.06 * sin(_t * 53.0), 1.0)
			v.position = Vector3.ZERO
			mouth_open = 0.5 + 0.5 * sin(_t * 23.0)
		State.DEAD:
			var k := clampf(_state_time / 0.6, 0.0, 1.0)
			var e := ease(k, 2.0)
			v.scale = Vector3(1.0 + 0.3 * e, lerpf(1.0, 0.12, e), 1.0 + 0.3 * e)
			v.rotation = Vector3(0.0, 0.0, 0.25 * e)
			v.position = Vector3.ZERO
	if _bulb != null:
		_bulb.rotation = Vector3(nod, 0.0, 0.0)
	if _mouth != null:
		_mouth.scale = Vector3(1.0, lerpf(0.35, 1.0, mouth_open), 1.0)
	if _jaw != null:
		_jaw.rotation = Vector3(deg_to_rad(-35.0) * mouth_open, 0.0, 0.0)
