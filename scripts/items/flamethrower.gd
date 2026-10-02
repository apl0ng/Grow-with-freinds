class_name Flamethrower
extends Item
## The emergency flamethrower (scenes/items/flamethrower.tscn, owner: flame agent, M12). Comes out of the
## EmergencyCabinet with `fuel` seconds of flame; the only thing that kills a hostile plant. It also scorches crops
## and sets workers on fire, and the Boss writes that up as arson.
##
## Props (synced through $Sync, server authority, ON_CHANGE): `fuel: float` (seconds left, written in FUEL_STEP
## steps while it drains so the stream stays small) and `firing: bool`.
## Flow:
##   holder  _process: while the LOCAL player holds it, the `use_item` action (LMB, hold) is polled; on a change
##           request_fire(on) -> _rpc_request_fire.rpc_id(1, on). An empty flamethrower clicks "error" locally once
##           per press and sends nothing.
##   server  _rpc_request_fire(on) -> server_request_fire(sender, on): the sender must be the holder; `on` also needs
##           fuel > 0, not flying, the holder not in the back room, not stunned (M13 review) and the shift PLAYING.
##           `firing` is synced.
##   every   the `firing` setter starts / stops the flame cone (Visual/Nozzle/Flame, CPUParticles3D) and the "flame"
##   peer    loop (Sfx.play_loop, follows this node).
##   server  _physics_process while firing: fuel -= delta (at 0: firing stops, label "Flamethrower (empty)"); cone
##           test from the holder's eye (get_cone_origin: their camera, i.e. the synced yaw / pitch) along the look
##           direction (reach flamethrower_range, half-angle flamethrower_half_angle_deg, a LAYER_WORLD ray must be
##           clear; the nozzle is only where the flame is drawn): hostiles -> Hostiles.server_apply_fire(id,
##           delta, holder); GrowPlots with a plant -> after scorch_sec of CONTINUOUS exposure plot.server_scorch(
##           holder); workers -> player.server_ignite(holder) once per victim per IGNITE_COOLDOWN_SEC. Firing stops
##           by itself when the holder lets go (drop / throw / release), is staggered, goes to the back room or the
##           shift ends. One cone pass stops burning the moment its write-ups send the shooter to the back room.
## An empty flamethrower is still an item: carried, dropped and thrown like the others.
## View model: the base Item moves every GeometryInstance3D into the local holder's view-model layer; the flame
## particles are pinned back to the world layer each frame (they reach 3.5 m into the room and must be depth-tested
## against walls and plants, not drawn over them).

## Every peer: `firing` changed after spawn.
signal firing_changed(firing: bool)

## Synced fuel is written in these steps while draining (one small reliable packet per step).
const FUEL_STEP: float = 0.1
## A worker in the cone is set on fire at most once per this many seconds (per victim).
const IGNITE_COOLDOWN_SEC: float = 10.0
## Height above a plot's origin where the plant is tested against the cone.
const PLANT_POINT_HEIGHT: float = 0.8
## Height above a hostile's origin where it is tested against the cone.
const HOSTILE_POINT_HEIGHT: float = 1.0   # mid-body of the 2x plant
const STATUS_EMPTY := "empty"
const EMPTY_COLOR := Color("ff5a5f")

## Seconds of fuel left (synced, server authority).
var fuel: float = 0.0:
	set = _set_fuel
## True while the flame is on (synced, server authority).
var firing: bool = false:
	set = _set_firing

var _fuel_exact: float = 0.0          # server: the exact fuel (the synced value follows in FUEL_STEP steps)
var _exposure: Dictionary = {}        # server: GrowPlot instance id -> seconds of continuous exposure
var _ignited_at: Dictionary = {}      # server: peer id -> msec of the last ignite
var _loop_handle: int = 0
var _want_sent: bool = false          # local holder: the last request_fire(on) value sent
var _empty_click_played: bool = false

@onready var _nozzle: Node3D = get_node_or_null(^"Visual/Nozzle") as Node3D
@onready var _flame: CPUParticles3D = get_node_or_null(^"Visual/Nozzle/Flame") as CPUParticles3D
@onready var _label: Label3D = get_node_or_null(^"FuelLabel") as Label3D


func _ready() -> void:
	super()
	_update_flame_fx()


func _exit_tree() -> void:
	_stop_loop()
	super()


func _process(delta: float) -> void:
	super(delta)
	_poll_local_fire()
	if firing and _flame != null and is_in_view_model():
		_keep_flame_in_world()


func _physics_process(delta: float) -> void:
	if not _is_authority or not firing:
		return
	_server_tick(delta)


# --- public API -----------------------------------------------------------------------------------------------------

func get_display_name() -> String:
	return "Flamethrower"


## "empty" at 0, else the whole seconds left ("6 s").
func get_status_text() -> String:
	if fuel <= 0.0:
		return STATUS_EMPTY
	return "%d s" % ceili(fuel)


func is_empty() -> bool:
	return fuel <= 0.0


func is_firing() -> bool:
	return firing


## props: {"fuel": float (seconds), "firing": bool}; a missing fuel value means a full tank.
func apply_props(props: Dictionary) -> void:
	var f: Variant = props.get("fuel", Config.balance.flamethrower_fuel_sec)
	_fuel_exact = maxf(float(f), 0.0)
	fuel = _fuel_exact
	firing = bool(props.get("firing", false))


func get_props() -> Dictionary:
	return {"fuel": fuel, "firing": firing}


## Where the flame VFX starts (world space): the nozzle, or the holder's chest when the model has none.
func get_nozzle_position() -> Vector3:
	if _nozzle != null and _nozzle.is_inside_tree():
		return _nozzle.global_position
	var holder := get_holder()
	return holder.get_chest_position() if holder != null else global_position


## Where the cone TEST starts: the holder's eye (their %Camera, which on the server carries the synced yaw and pitch).
## The nozzle is only where the flame is drawn: on a remote body it hangs a metre ahead and off to one side at the
## body socket, so a cone from there would miss what the worker is actually aiming the crosshair at.
func get_cone_origin() -> Vector3:
	var holder := get_holder()
	if holder == null:
		return get_nozzle_position()
	var cam: Camera3D = holder.camera
	if cam != null and cam.is_inside_tree():
		return cam.global_position
	return holder.get_chest_position()


## Any peer (the holder): asks the server to start (`on`) or stop the flame.
func request_fire(on: bool) -> void:
	if not is_inside_tree():
		return
	var peer := multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_rpc_request_fire.rpc_id(Const.SERVER_PEER_ID, on)


@rpc("any_peer", "call_local", "reliable")
func _rpc_request_fire(on: bool) -> void:
	if not multiplayer.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = Const.SERVER_PEER_ID
	server_request_fire(sender, on)


## SERVER. The validation behind _rpc_request_fire: `sender` must hold this item; stopping is always granted to the
## holder; starting needs fuel, a holder on the floor (not the back room), the shift PLAYING and no flight.
## Returns true when the request was granted (also when nothing had to change).
func server_request_fire(sender: int, on: bool) -> bool:
	if not _is_authority or not is_inside_tree():
		return false
	if sender <= 0 or holder_id == 0 or sender != holder_id:
		return false
	if not on:
		if firing:
			_server_stop()
		return true
	if firing:
		return true
	if _fuel_exact <= 0.0 or fuel <= 0.0 or is_flying():
		return false
	if GameState.is_in_backroom(sender) or not GameState.is_playing():
		return false
	var holder := get_holder()
	if holder == null or not holder.is_inside_tree():
		return false
	# M13 review: a stunned worker does not throw or shove (ItemManager / Player refuse both); the flame was the one
	# thing a stumbling worker could still do. The holder's poll asks again once the stun has passed.
	if holder.is_stunned():
		return false
	_exposure.clear()
	firing = true
	return true


## SERVER. Tests / the cabinet: sets the fuel (seconds).
func server_set_fuel(seconds: float) -> void:
	if not _is_authority:
		push_error("Flamethrower.server_set_fuel called on a client")
		return
	_fuel_exact = maxf(seconds, 0.0)
	fuel = _fuel_exact
	if _fuel_exact <= 0.0 and firing:
		_server_stop()


## True when `point` (world) lies in the flame cone from `origin` along `direction`.
static func point_in_cone(origin: Vector3, direction: Vector3, point: Vector3, reach: float, half_angle_deg: float) -> bool:
	var v := point - origin
	var d := v.length()
	if not (d <= reach) or d < 0.001:
		return false
	var dir := direction.normalized()
	if not dir.is_finite() or dir.length_squared() < 0.5:
		return false
	return v.dot(dir) / d >= cos(deg_to_rad(clampf(half_angle_deg, 0.0, 89.0)))


# --- server tick ----------------------------------------------------------------------------------------------------

func _server_tick(delta: float) -> void:
	var holder := get_holder()
	# M13 review: a stagger (a shove from the front leaves the item in the hands) puts the flame out as well.
	if holder == null or not holder.is_inside_tree() or is_flying() or holder.is_stunned() \
			or GameState.is_in_backroom(holder_id) or not GameState.is_playing():
		_server_stop()
		return
	_fuel_exact = maxf(_fuel_exact - delta, 0.0)
	_server_cone(holder, delta)
	if _fuel_exact <= 0.0:
		fuel = 0.0
		_server_stop()
		return
	var stepped := snappedf(_fuel_exact, FUEL_STEP)
	if stepped != fuel:
		fuel = stepped


func _server_stop() -> void:
	_exposure.clear()
	if firing:
		firing = false


func _server_cone(holder: Player, delta: float) -> void:
	var b: BalanceConfig = Config.balance
	var origin := get_cone_origin()
	var dir := holder.get_look_direction()
	if not dir.is_finite() or dir.length_squared() < 0.0001:
		dir = holder.get_flat_forward()
	dir = dir.normalized()
	var reach: float = b.flamethrower_range
	var half: float = b.flamethrower_half_angle_deg
	var shooter := holder_id
	var exclude_base: Array[RID] = [holder.get_rid()]
	# Hostile plants (the stub returns none until the hostile branch merges).
	for h in Hostiles.get_hostiles():
		if h == null or not is_instance_valid(h) or not h.is_inside_tree():
			continue
		var id_v: Variant = h.get(&"id")
		if id_v == null:
			continue
		var point := h.global_position + Vector3.UP * HOSTILE_POINT_HEIGHT
		if not point_in_cone(origin, dir, point, reach, half):
			continue
		if not _line_clear(origin, point, _with(exclude_base, _colliders_of(h))):
			continue
		Hostiles.server_apply_fire(int(id_v), delta, shooter)
	# Crops: continuous exposure for scorch_sec.
	var seen := {}
	for n in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		# M13 review: the third write-up of this pass has sent the shooter to the back room: the pass ends there. It
		# used to go on burning (a strike and a fine per tray / worker booked on a worker already in the back room).
		if GameState.is_in_backroom(shooter):
			return
		var plot := n as GrowPlot
		if plot == null or not plot.is_inside_tree() or plot.stage == GrowPlot.Stage.EMPTY:
			continue
		var point := plot.global_position + Vector3.UP * PLANT_POINT_HEIGHT
		if not point_in_cone(origin, dir, point, reach, half):
			continue
		if not _line_clear(origin, point, _with(exclude_base, _colliders_of(plot))):
			continue
		var key := plot.get_instance_id()
		var exposure: float = float(_exposure.get(key, 0.0)) + delta
		seen[key] = true
		if exposure >= maxf(b.scorch_sec, 0.0):
			if plot.server_scorch(shooter):
				exposure = 0.0
		_exposure[key] = exposure
	for key in _exposure.keys():
		if not seen.has(key):
			_exposure.erase(key)
	# Workers: once per victim per IGNITE_COOLDOWN_SEC.
	var now := Time.get_ticks_msec()
	for n in get_tree().get_nodes_in_group(Const.GROUP_PLAYERS):
		if GameState.is_in_backroom(shooter):
			return # M13 review: see the crops loop above
		var p := n as Player
		if p == null or p == holder or not p.is_inside_tree() or p.is_queued_for_deletion():
			continue
		if GameState.is_in_backroom(p.peer_id):
			continue
		var point := p.get_chest_position()
		if not point_in_cone(origin, dir, point, reach, half):
			continue
		var only_them: Array[RID] = [p.get_rid()]
		if not _line_clear(origin, point, _with(exclude_base, only_them)):
			continue
		var last: float = float(_ignited_at.get(p.peer_id, -INF))
		if now - last < IGNITE_COOLDOWN_SEC * 1000.0:
			continue
		_ignited_at[p.peer_id] = now
		p.server_ignite(shooter)


## True when nothing on LAYER_WORLD sits between `from` and `to` (walls, partitions, the fence).
func _line_clear(from: Vector3, to: Vector3, exclude: Array[RID]) -> bool:
	var world := get_world_3d()
	if world == null:
		return true
	var space := world.direct_space_state
	if space == null:
		return true
	var query := PhysicsRayQueryParameters3D.create(from, to, Const.LAYER_WORLD, exclude)
	return space.intersect_ray(query).is_empty()


## `base` plus `extra`, kept typed (a `+` with an untyped literal would hand _line_clear a plain Array).
static func _with(base: Array[RID], extra: Array[RID]) -> Array[RID]:
	var out: Array[RID] = base.duplicate()
	out.append_array(extra)
	return out


static func _colliders_of(node: Node) -> Array[RID]:
	var out: Array[RID] = []
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	for c in node.find_children("*", "CollisionObject3D", true, false):
		out.append((c as CollisionObject3D).get_rid())
	return out


# --- local holder input ---------------------------------------------------------------------------------------------

func _poll_local_fire() -> void:
	var holder := get_holder()
	var local := holder != null and holder.is_local() and not is_flying()
	if not local:
		_want_sent = false
		_empty_click_played = false
		return
	var pressed := Input.is_action_pressed(&"use_item") and not Game.is_ui_locked()
	if pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and DisplayServer.get_name() != "headless":
		pressed = false # a click that recaptures the mouse is not a trigger pull
	if holder.is_stunned():
		pressed = false # M13 review: the server refuses a stunned holder; holding the button resumes after the stun
	var want := pressed
	if want and fuel <= 0.0:
		want = false
		if not _empty_click_played:
			_empty_click_played = true
			Sfx.play(&"error")
	if not Input.is_action_pressed(&"use_item"):
		_empty_click_played = false
	if want != _want_sent:
		_want_sent = want
		request_fire(want)


# --- setters / presentation (every peer) ----------------------------------------------------------------------------

func _set_fuel(value: float) -> void:
	if not is_finite(value):
		return
	value = maxf(value, 0.0)
	if value == fuel:
		return
	fuel = value
	_notify_props_changed()


func _set_firing(value: bool) -> void:
	if value == firing:
		return
	firing = value
	if not is_node_ready():
		return
	_update_flame_fx()
	_notify_props_changed()
	firing_changed.emit(firing)


func _refresh_visuals() -> void:
	if _label != null:
		_label.text = get_status_text()
		_label.modulate = EMPTY_COLOR if fuel <= 0.0 else Color.WHITE
		_label.visible = not is_held() and not is_flying()


func _update_flame_fx() -> void:
	if _flame != null:
		_flame.emitting = firing
	if firing:
		if _loop_handle == 0 and is_inside_tree():
			_loop_handle = Sfx.play_loop(&"flame", self)
	else:
		_stop_loop()


func _stop_loop() -> void:
	if _loop_handle != 0:
		Sfx.stop_loop(_loop_handle)
		_loop_handle = 0


## The base Item draws the whole held item in the local view-model pass; the flame stays in the world pass.
func _keep_flame_in_world() -> void:
	if _flame.layers != Player.WORLD_RENDER_LAYER:
		_flame.layers = Player.WORLD_RENDER_LAYER
	if _flame.has_meta(META_WORLD_LAYERS):
		_flame.remove_meta(META_WORLD_LAYERS)
