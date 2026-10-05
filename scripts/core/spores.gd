class_name Spores
extends Node
## M18 spores (spores agent; CONTRACTS.md "M18", "Spores"; FRIENDSLOP.md 12.2): Black Damp's spore clouds and who is
## fogged by them. One node, World/Spores, added by World._ready on every peer, so the path (and the RPCs) match.
##
## Host (Net.is_host):
##   server_puff(plot, cause)  a READY tray of a strain with SeedDef.spores puffs: a cloud of Config.balance.spore_radius
##                             hangs over it for spore_cloud_sec. The hooks: GrowPlot.server_harvest (CAUSE_HARVEST),
##                             the plant walking off in server_tick_mutation (CAUSE_UPROOT), server_scorch (CAUSE_FIRE),
##                             a drive-by round passing over the tray (Events.server_fire_lane -> server_lane_shot,
##                             CAUSE_SHOT) and a thrown item whose flight ends on the tray (ItemManager ->
##                             server_flight_struck, CAUSE_HIT). A tray whose cloud still hangs does not puff again (the
##                             cloud is already there and catches whoever comes close).
##   breathing                 at puff time and every physics frame while a cloud hangs (tick), every worker on the floor
##                             within the radius (flat distance, the same floor, no wall between, not in the back room)
##                             breathes it: fogged for spore_fog_sec, CROUCH_FACTOR of that when crouched (a sleeve over
##                             the mouth). Standing in the cloud keeps the fog topped up (at most one packet a second);
##                             it runs down once he is out.
##   who is fogged             `_fog`: peer -> seconds left. Newly fogged: GameState stat STAT_FOGGED (the lead adds
##                             Const.STAT_FOGGED), then _rpc_fog(peer, seconds, first) to every peer; `first` is true for
##                             the first worker fogged this shift (the Boss's line). A top-up of at least RESEND_GAIN_SEC
##                             goes out again, the end goes out as 0. A late joiner gets the fog and the hanging clouds
##                             (_rpc_sync on Net.peer_registered).
## Every peer:
##   the cloud                 _rpc_cloud: `spore_puff` at the tray, a grey-olive volume of motes for the cloud's life.
##   fog counts down locally between packets; for each fogged worker a `cough` at his head every COUGH_GAP_* seconds (his
##                             own pitch, so the floor can tell who it is: COUGH_PITCHES); a faint grey haze round the
##                             head of a fogged worker seen from outside.
##   the local worker fogged   a CanvasLayer (OVERLAY_LAYER: over the view model, under the HUD) greys the screen and blurs
##                             it towards the edges, fading in over FADE_IN_SEC and out over the last FADE_OUT_SEC; it never
##                             takes input. Hearing: an AudioEffectLowPassFilter added to the Master bus on the first fogged
##                             frame, its cutoff following the overlay, and that exact instance removed again once the
##                             overlay has faded out.
##   clean air                 a reset (GameState.game_reset), the end of a shift (round_ended), the menu (phase MENU, and
##                             the World being freed: _exit_tree) and quitting clear the clouds, the fog, the haze, the
##                             overlay and the filter at once, on every peer, from its own signals.

## Every peer: a tray puffed (`cause` is one of CAUSES).
signal puffed(plot_name: String, cause: StringName)
## Every peer: `peer_id`'s fog was set to `seconds` (0 = clear air again).
signal fog_changed(peer_id: int, seconds: float)
## Every peer: `peer_id` coughed (a fogged worker, every few seconds).
signal coughed(peer_id: int)

const NODE_NAME := "Spores"
## GameState stat: times a worker was fogged this shift (the shift report's FOGGED column). The lead adds it to Const.
const STAT_FOGGED: StringName = &"fogged"
const CAUSE_HARVEST: StringName = &"harvest"
const CAUSE_UPROOT: StringName = &"uproot"
const CAUSE_FIRE: StringName = &"fire"
const CAUSE_SHOT: StringName = &"shot"
const CAUSE_HIT: StringName = &"hit"
const CAUSES: Array[StringName] = [CAUSE_HARVEST, CAUSE_UPROOT, CAUSE_FIRE, CAUSE_SHOT, CAUSE_HIT]
## A drive-by round puffs a ripe tray when it passes this close to its centre (flat). The ripe plant's collider is a 1 m
## box on the world layer, so a round that strikes it is cut at its face, up to 0.71 m from the centre: the drive-by's
## own tray radius (0.6 m) would miss a round that grazes the plant.
const SHOT_REACH := 0.75
## A crouched worker breathing through his sleeve is fogged this share of spore_fog_sec.
const CROUCH_FACTOR := 0.5
## A worker counts as on the cloud's floor within this many metres of height.
const SAME_FLOOR_HEIGHT := 2.0
## A top-up inside a cloud is sent once it adds at least this many seconds.
const RESEND_GAIN_SEC := 1.0
## Upper bound for any fog value on receive (seconds).
const MAX_FOG_SEC := 60.0
## The first cough comes this soon after a worker is fogged; then one every COUGH_GAP_MIN_SEC .. COUGH_GAP_MAX_SEC.
const COUGH_FIRST_SEC := 0.6
const COUGH_GAP_MIN_SEC := 2.4
const COUGH_GAP_MAX_SEC := 3.8
## A cough that would land on top of another one (same mode, same instant) waits this long.
const COUGH_RETRY_SEC := 0.07
## Each worker coughs at his own pitch (by peer id), on top of the sound's own small variation.
const COUGH_PITCHES: Array[float] = [1.0, 0.86, 1.13, 0.93, 1.06, 0.8, 1.18, 0.97]
const COUGH_HEAD_HEIGHT := 1.55
## The local worker hears his own cough unpositioned, this much quieter (dB).
const COUGH_LOCAL_DB := -3.0
## Over the first-person view model (layer -1), under the HUD (layer 1).
const OVERLAY_LAYER := 0
const FADE_IN_SEC := 0.7
const FADE_OUT_SEC := 1.5
## The Master bus low-pass while fully fogged, and where it starts / ends (Hz).
const FILTER_CUTOFF_HZ := 650.0
const FILTER_OPEN_HZ := 20000.0
const MASTER_BUS := 0
## The cloud: motes alive at once, how long each drifts, the volume's share of spore_radius.
const CLOUD_MOTES := 56
const CLOUD_MOTE_SEC := 2.6
const CLOUD_FILL := 0.65
const CLOUD_HEIGHT := 0.9
const PUFF_DUST := 14
## The haze round a fogged worker's head (seen from outside).
const HAZE_MOTES := 9
const HAZE_HEIGHT := 1.62
const HAZE_NODE := "SporeHaze"

const OVERLAY_SHADER := """
shader_type canvas_item;
render_mode unshaded;
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 fog_color : source_color = vec4(0.59, 0.62, 0.65, 1.0);
void fragment() {
	vec2 d = (SCREEN_UV - vec2(0.5)) * vec2(1.0, 0.75);
	float edge = smoothstep(0.12, 0.62, length(d) * 1.35);
	vec3 col = textureLod(screen_tex, SCREEN_UV, edge * 4.5 * amount).rgb;
	float grey = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(col, vec3(grey), 0.7 * amount);
	col = mix(col, fog_color.rgb, (0.18 + 0.55 * edge) * amount);
	COLOR = vec4(col, 1.0);
}
"""

## Every peer: the hanging clouds, [{"id", "plot", "pos", "left", "node"}] (the host's are the ones that catch).
var _clouds: Array[Dictionary] = []
## Every peer: peer id -> seconds of fog left (the host's is the truth; clients count down between packets).
var _fog: Dictionary = {}
## Host: somebody was fogged this shift (the Boss has said his line).
var _shift_fogged := false
var _next_cloud_id := 1
## Every peer: seconds to each fogged worker's next cough, and the coughs played here (tests).
var _cough_left: Dictionary = {}
var _cough_counts: Dictionary = {}
var _last_cough_msec: Dictionary = {}
## Every peer: peer id -> the haze particles on that worker's body.
var _haze: Dictionary = {}
var _overlay: CanvasLayer
var _overlay_rect: ColorRect
var _overlay_material: ShaderMaterial
var _alpha := 0.0
var _filter: AudioEffectLowPassFilter = null
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	name = NODE_NAME


func _ready() -> void:
	_rng.randomize()
	_build_overlay()
	GameState.game_reset.connect(_on_clean_air)
	GameState.round_ended.connect(_on_round_ended)
	GameState.round_started.connect(_on_round_started)
	GameState.phase_changed.connect(_on_phase_changed)
	Net.peer_registered.connect(_on_peer_registered)
	Net.peer_left.connect(_on_peer_left)


func _exit_tree() -> void:
	clear_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_remove_filter()


func _physics_process(delta: float) -> void:
	if _is_host():
		tick(delta)


func _process(delta: float) -> void:
	if not _is_host():
		_count_down_locally(delta)
	_update_coughs(delta)
	_update_haze()
	_update_local_effects(delta)


# --- queries (any peer) ------------------------------------------------------------------------------------------------

## World/Spores, or null without a world.
static func get_instance() -> Spores:
	var w: World = Game.world
	if w == null or not is_instance_valid(w) or not w.is_inside_tree():
		return null
	return w.get_node_or_null(NODE_NAME) as Spores


## True for a strain whose ripe trays puff (SeedDef.spores).
static func has_spores(s: SeedDef) -> bool:
	return s != null and s.spores


## The cloud's grey-olive (palette colours, mixed).
static func spore_color() -> Color:
	return Toon.LEAF_DRY.lerp(Toon.STONE, 0.55)


## Seconds of fog `peer_id` has left on this peer (0 = clear).
func get_fog(peer_id: int) -> float:
	return maxf(float(_fog.get(peer_id, 0.0)), 0.0)


func is_fogged(peer_id: int) -> bool:
	return get_fog(peer_id) > 0.0


## Every fogged worker on this peer, sorted.
func get_fogged_peers() -> Array[int]:
	var out: Array[int] = []
	for pid: int in _fog:
		if float(_fog[pid]) > 0.0:
			out.append(pid)
	out.sort()
	return out


## The hanging clouds' ids on this peer, oldest first.
func get_cloud_ids() -> Array[int]:
	var out: Array[int] = []
	for c: Dictionary in _clouds:
		out.append(int(c["id"]))
	return out


func get_cloud_count() -> int:
	return _clouds.size()


## The cloud (id, plot name, position, seconds left, node) for tests: {} when it is gone.
func get_cloud(id: int) -> Dictionary:
	for c: Dictionary in _clouds:
		if int(c["id"]) == id:
			return c
	return {}


## True while `plot`'s own cloud hangs.
func has_cloud_over(plot_name: String) -> bool:
	for c: Dictionary in _clouds:
		if String(c["plot"]) == plot_name:
			return true
	return false


func get_cough_count(peer_id: int) -> int:
	return int(_cough_counts.get(peer_id, 0))


## The overlay layer, its full-screen rect and how far it is faded in (0..1) on this peer.
func get_overlay() -> CanvasLayer:
	return _overlay


func get_overlay_rect() -> ColorRect:
	return _overlay_rect


func get_overlay_alpha() -> float:
	return _alpha


## The low-pass this node put on the Master bus (null when hearing is clear).
func get_filter() -> AudioEffectLowPassFilter:
	return _filter


func is_filter_installed() -> bool:
	if _filter == null:
		return false
	for i in AudioServer.get_bus_effect_count(MASTER_BUS):
		if AudioServer.get_bus_effect(MASTER_BUS, i) == _filter:
			return true
	return false


## The haze node on `peer_id`'s body on this peer (null when none).
func get_haze(peer_id: int) -> Node3D:
	var n: Variant = _haze.get(peer_id)
	return n as Node3D if n != null and is_instance_valid(n) else null


## The pitch factor `peer_id` coughs at.
static func cough_pitch(peer_id: int) -> float:
	return COUGH_PITCHES[absi(peer_id) % COUGH_PITCHES.size()]


# --- host --------------------------------------------------------------------------------------------------------------

## Host convenience for the one-line hooks: puffs `plot` when it is a READY tray of a spore strain. False otherwise
## (also without a world, on a client, or while its cloud hangs).
static func puff_plot(plot: GrowPlot, cause: StringName) -> bool:
	var sp := get_instance()
	return sp != null and sp.server_puff(plot, cause)


## Host, from Events.server_fire_lane: every READY spore tray within `radius` (flat; at least SHOT_REACH) of the round's
## path from `from` to `end` puffs (CAUSE_SHOT). Returns how many did.
static func server_lane_shot(from: Vector3, end: Vector3, radius: float) -> int:
	var sp := get_instance()
	if sp == null or not sp._is_host():
		return 0
	radius = maxf(radius, SHOT_REACH)
	var count := 0
	var a := Vector2(from.x, from.z)
	var b := Vector2(end.x, end.z)
	for node in sp.get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var plot := node as GrowPlot
		if plot == null or not plot.is_inside_tree() or not plot.is_ready_to_harvest() or not has_spores(plot.get_seed()):
			continue
		var c := Vector2(plot.global_position.x, plot.global_position.z)
		if Geometry2D.get_closest_point_to_segment(c, a, b).distance_to(c) <= radius and sp.server_puff(plot, CAUSE_SHOT):
			count += 1
	return count


## Host, from ItemManager: a thrown item's flight ended on `collider`; when that is part of a ripe spore tray, it puffs
## (CAUSE_HIT).
static func server_flight_struck(collider: Node) -> bool:
	var n := collider
	while n != null:
		if n is GrowPlot:
			return puff_plot(n as GrowPlot, CAUSE_HIT)
		n = n.get_parent()
	return false


## SERVER. `plot` puffs a spore cloud for `cause` when it is a READY tray of a spore strain and its own cloud is not
## hanging already: every peer gets the cloud, every worker in range breathes it now. True when it puffed.
func server_puff(plot: GrowPlot, cause: StringName) -> bool:
	if not _is_host() or plot == null or not is_instance_valid(plot) or not plot.is_inside_tree():
		return false
	if not plot.is_ready_to_harvest() or not has_spores(plot.get_seed()):
		return false
	var plot_name := String(plot.name)
	if has_cloud_over(plot_name):
		return false
	var pos := plot.global_position
	var id := _next_cloud_id
	_next_cloud_id += 1
	_rpc_cloud.rpc(id, plot_name, pos, maxf(Config.balance.spore_cloud_sec, 0.0), String(cause))
	_server_breathe(pos)
	return true


## SERVER. `peer_id` breathed spores (crouched: CROUCH_FACTOR of the fog). Newly fogged: the stat and the packet; already
## fogged: a top-up only when it adds RESEND_GAIN_SEC. True when the fog was set.
func server_catch(peer_id: int, crouched: bool) -> bool:
	if not _is_host() or peer_id <= 0:
		return false
	var seconds := maxf(Config.balance.spore_fog_sec, 0.0) * (CROUCH_FACTOR if crouched else 1.0)
	if seconds <= 0.0:
		return false
	var now := float(_fog.get(peer_id, 0.0))
	var fresh := now <= 0.0
	if not fresh and seconds - now < RESEND_GAIN_SEC:
		return false
	var first := false
	if fresh:
		GameState.server_add_stat(peer_id, STAT_FOGGED)
		first = not _shift_fogged
		_shift_fogged = true
	_rpc_fog.rpc(peer_id, seconds, first)
	return true


## SERVER. Clean air now, on every peer (tests; the game clears itself from its own signals).
func server_clear() -> void:
	if _is_host():
		_rpc_clear.rpc()


## Host step: the clouds and the fog count down, whoever stands in a hanging cloud breathes it, fog that ran out is
## cleared on every peer. Called every physics frame; public so tests can drive it.
func tick(delta: float) -> void:
	if delta <= 0.0 or not _is_host():
		return
	_count_clouds(delta)
	for pid: int in _fog.keys():
		_fog[pid] = float(_fog[pid]) - delta
	for c: Dictionary in _clouds:
		_server_breathe(c["pos"])
	for pid: int in _fog.keys():
		if float(_fog[pid]) <= 0.0:
			_rpc_fog.rpc(pid, 0.0, false)


func _server_breathe(pos: Vector3) -> void:
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return
	var radius := maxf(Config.balance.spore_radius, 0.0)
	for p in w.get_players():
		if in_cloud(p, pos, radius):
			server_catch(p.peer_id, p.crouching)


## True when worker `p` breathes a cloud of `radius` over `pos`: in the tree, not in the back room, on the same floor,
## within the radius on the floor plan, no wall between (Room.is_wall_between; the pen's fence lets spores through).
static func in_cloud(p: Player, pos: Vector3, radius: float) -> bool:
	if p == null or not is_instance_valid(p) or not p.is_inside_tree() or p.is_queued_for_deletion():
		return false
	if GameState.is_in_backroom(p.peer_id):
		return false
	var at := p.global_position
	if not at.is_finite() or absf(at.y - pos.y) > SAME_FLOOR_HEIGHT:
		return false
	if Vector2(at.x - pos.x, at.z - pos.z).length() > radius:
		return false
	var w: World = Game.world
	if w != null and is_instance_valid(w) and w.room != null and w.room.is_wall_between(at, pos):
		return false
	return true


func _on_peer_registered(peer_id: int) -> void:
	if not _is_host():
		return
	var fog: Dictionary = {}
	for pid: int in _fog:
		if float(_fog[pid]) > 0.0:
			fog[pid] = float(_fog[pid])
	var clouds: Array = []
	for c: Dictionary in _clouds:
		clouds.append([int(c["id"]), String(c["plot"]), c["pos"], float(c["left"])])
	if fog.is_empty() and clouds.is_empty():
		return
	_rpc_sync.rpc_id(peer_id, fog, clouds)


# --- RPCs (host -> every peer) -----------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_cloud(id: int, plot_name: String, pos: Vector3, seconds: float, cause: String) -> void:
	if not pos.is_finite() or not is_finite(seconds):
		return
	_add_cloud(id, plot_name, pos, clampf(seconds, 0.0, MAX_FOG_SEC), true)
	puffed.emit(plot_name, StringName(cause))


@rpc("authority", "call_local", "reliable")
func _rpc_fog(peer_id: int, seconds: float, first: bool) -> void:
	if not is_finite(seconds):
		return
	seconds = clampf(seconds, 0.0, MAX_FOG_SEC)
	_set_fog(peer_id, seconds)
	if first and seconds > 0.0 and is_inside_tree():
		var story: Node = get_node_or_null(^"/root/Story")
		if story != null and story.has_method(&"spores_first_fog"):
			story.call(&"spores_first_fog", peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_clear() -> void:
	clear_all()


## A late joiner: the fog ({peer: seconds}) and the hanging clouds ([[id, plot, pos, left]]), without the puff sound.
@rpc("authority", "call_remote", "reliable")
func _rpc_sync(fog: Dictionary, clouds: Array) -> void:
	for entry: Variant in clouds:
		if not (entry is Array) or (entry as Array).size() < 4:
			continue
		var e: Array = entry
		if not (e[0] is int) or not (e[2] is Vector3) or not (e[3] is float or e[3] is int):
			continue
		var pos: Vector3 = e[2]
		var left := float(e[3])
		if not pos.is_finite() or not is_finite(left) or get_cloud(int(e[0])).size() > 0:
			continue
		_add_cloud(int(e[0]), str(e[1]), pos, clampf(left, 0.0, MAX_FOG_SEC), false)
	for key: Variant in fog:
		var value: Variant = fog[key]
		if key is int and (value is float or value is int) and is_finite(float(value)):
			_set_fog(int(key), clampf(float(value), 0.0, MAX_FOG_SEC))


# --- every peer: clouds, fog, coughs, haze -----------------------------------------------------------------------------

func _add_cloud(id: int, plot_name: String, pos: Vector3, seconds: float, puff: bool) -> void:
	var node := _make_cloud(pos)
	add_child(node)
	_clouds.append({"id": id, "plot": plot_name, "pos": pos, "left": seconds, "node": node})
	if puff:
		var top := pos + Vector3.UP * CLOUD_HEIGHT
		Sfx.play(&"spore_puff", top)
		GrowPlot.juice_fx(&"puff", top, spore_color(), PUFF_DUST)


## Counts every cloud down by `delta`; a spent cloud stops making motes and is freed once the last one has drifted off.
func _count_clouds(delta: float) -> void:
	for i in range(_clouds.size() - 1, -1, -1):
		var c: Dictionary = _clouds[i]
		c["left"] = float(c["left"]) - delta
		if float(c["left"]) <= 0.0:
			_clouds.remove_at(i)
			_retire_cloud(c.get("node"))


func _retire_cloud(node: Variant) -> void:
	if node == null or not is_instance_valid(node):
		return
	var n := node as Node
	var motes := n.get_node_or_null(^"Motes") as CPUParticles3D
	if motes == null or not n.is_inside_tree():
		n.queue_free()
		return
	motes.emitting = false
	get_tree().create_timer(CLOUD_MOTE_SEC + 0.2).timeout.connect(func() -> void:
		if is_instance_valid(n):
			n.queue_free())


## Clients between packets: the fog and the clouds run down on the local clock (the host's own end packet follows).
func _count_down_locally(delta: float) -> void:
	_count_clouds(delta)
	for pid: int in _fog.keys():
		var left := float(_fog[pid]) - delta
		if left <= 0.0:
			_set_fog(pid, 0.0)
		else:
			_fog[pid] = left


func _set_fog(peer_id: int, seconds: float) -> void:
	var was := float(_fog.get(peer_id, 0.0)) > 0.0
	if seconds <= 0.0:
		if not _fog.has(peer_id):
			return
		_fog.erase(peer_id)
		_cough_left.erase(peer_id)
		_drop_haze(peer_id)
		fog_changed.emit(peer_id, 0.0)
		return
	_fog[peer_id] = seconds
	if not was:
		_cough_left[peer_id] = COUGH_FIRST_SEC
	fog_changed.emit(peer_id, seconds)


func _update_coughs(delta: float) -> void:
	for pid: int in _fog.keys():
		if float(_fog[pid]) <= 0.0:
			continue
		var t := float(_cough_left.get(pid, COUGH_FIRST_SEC)) - delta
		if t <= 0.0:
			t = _rng.randf_range(COUGH_GAP_MIN_SEC, COUGH_GAP_MAX_SEC) if _cough(pid) else COUGH_RETRY_SEC
		_cough_left[pid] = t


## One cough of `peer_id` on this peer: unpositioned for the local worker, at the head for everyone else, at his own
## pitch. False when it has to wait a moment (another worker coughed in the same instant: Sfx would drop a retrigger
## that close, so this node keeps its own clock per mode and tries again shortly).
func _cough(peer_id: int) -> bool:
	var p: Player = Game.get_player(peer_id)
	if p == null or not is_instance_valid(p) or not p.is_inside_tree():
		return true
	var positional := not p.is_local()
	var now := Time.get_ticks_msec()
	if now - int(_last_cough_msec.get(positional, -100000)) <= Sfx.MIN_RETRIGGER_MSEC:
		return false
	_last_cough_msec[positional] = now
	var stream := Sfx.get_stream(&"cough")
	if positional:
		Sfx.play(&"cough", p.global_position + Vector3.UP * COUGH_HEAD_HEIGHT)
	else:
		Sfx.play(&"cough", Vector3.INF, COUGH_LOCAL_DB)
	var voice: Node = Sfx.get_last_voice()
	if Sfx.enabled and voice != null and stream != null and voice.get(&"stream") == stream:
		voice.set(&"pitch_scale", float(voice.get(&"pitch_scale")) * cough_pitch(peer_id))
	_cough_counts[peer_id] = get_cough_count(peer_id) + 1
	coughed.emit(peer_id)
	return true


## A faint grey haze on the body of every fogged worker this peer sees from outside (never the local one).
func _update_haze() -> void:
	for pid: int in _haze.keys():
		if not is_fogged(pid) or get_haze(pid) == null:
			_drop_haze(pid)
	for pid: int in _fog:
		if float(_fog[pid]) <= 0.0 or get_haze(pid) != null:
			continue
		var p: Player = Game.get_player(pid)
		if p == null or not is_instance_valid(p) or not p.is_inside_tree() or p.is_local():
			continue
		var parent: Node3D = p.visual if p.visual != null else p
		var haze := make_motes(HAZE_MOTES, 1.6, 0.28, 0.04, 0.3)
		haze.name = HAZE_NODE
		haze.position = Vector3(0.0, HAZE_HEIGHT, 0.0)
		haze.gravity = Vector3(0.0, 0.08, 0.0)
		parent.add_child(haze)
		_haze[pid] = haze


func _drop_haze(peer_id: int) -> void:
	var n := get_haze(peer_id)
	_haze.erase(peer_id)
	if n != null:
		n.queue_free()


func _on_peer_left(peer_id: int) -> void:
	_fog.erase(peer_id)
	_cough_left.erase(peer_id)
	_drop_haze(peer_id)


# --- every peer: the local worker's screen and ears --------------------------------------------------------------------

func _local_peer() -> int:
	var me: Player = Game.local_player
	if me != null and is_instance_valid(me):
		return me.peer_id
	if is_inside_tree() and multiplayer.has_multiplayer_peer():
		return multiplayer.get_unique_id()
	return 0


## The overlay fades towards how fogged the local worker is (full until the last FADE_OUT_SEC), the filter follows it,
## and both go away once it has faded out.
func _update_local_effects(delta: float) -> void:
	var left := get_fog(_local_peer())
	var target := clampf(left / FADE_OUT_SEC, 0.0, 1.0) if left > 0.0 else 0.0
	if _alpha < target:
		_alpha = minf(target, _alpha + delta / FADE_IN_SEC)
	else:
		_alpha = maxf(target, _alpha - delta / FADE_OUT_SEC)
	_apply_effects()


func _apply_effects() -> void:
	if _overlay_rect != null:
		_overlay_rect.visible = _alpha > 0.0
		if _overlay_material != null:
			_overlay_material.set_shader_parameter(&"amount", _alpha)
	if _alpha > 0.0:
		_install_filter()
		_filter.cutoff_hz = exp(lerpf(log(FILTER_OPEN_HZ), log(FILTER_CUTOFF_HZ), _alpha))
	else:
		_remove_filter()


func _install_filter() -> void:
	if _filter != null:
		return
	_filter = AudioEffectLowPassFilter.new()
	_filter.resource_name = "SporeMuffle"
	_filter.cutoff_hz = FILTER_OPEN_HZ
	_filter.db = AudioEffectFilter.FILTER_12DB
	AudioServer.add_bus_effect(MASTER_BUS, _filter)


## Takes exactly the filter this node added off the Master bus (wherever it sits now), nothing else.
func _remove_filter() -> void:
	if _filter == null:
		return
	for i in range(AudioServer.get_bus_effect_count(MASTER_BUS) - 1, -1, -1):
		if AudioServer.get_bus_effect(MASTER_BUS, i) == _filter:
			AudioServer.remove_bus_effect(MASTER_BUS, i)
	_filter = null


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.name = "FogOverlay"
	_overlay.layer = OVERLAY_LAYER
	_overlay_rect = ColorRect.new()
	_overlay_rect.name = "Fog"
	_overlay_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay_rect.focus_mode = Control.FOCUS_NONE
	_overlay_rect.color = Color(1.0, 1.0, 1.0, 1.0)
	var shader := Shader.new()
	shader.code = OVERLAY_SHADER
	_overlay_material = ShaderMaterial.new()
	_overlay_material.shader = shader
	_overlay_material.set_shader_parameter(&"amount", 0.0)
	_overlay_material.set_shader_parameter(&"fog_color", Toon.PEBBLE)
	_overlay_rect.material = _overlay_material
	_overlay_rect.visible = false
	_overlay.add_child(_overlay_rect)
	add_child(_overlay)


# --- clean air -----------------------------------------------------------------------------------------------------------

## Every peer, at once: no clouds, nobody fogged, no haze, the overlay gone and the Master bus as it was.
func clear_all() -> void:
	for c: Dictionary in _clouds:
		var n: Variant = c.get("node")
		if n != null and is_instance_valid(n):
			(n as Node).queue_free()
	_clouds.clear()
	var fogged := _fog.keys()
	_fog.clear()
	_cough_left.clear()
	for pid: int in _haze.keys():
		_drop_haze(pid)
	_haze.clear()
	_alpha = 0.0
	if _overlay_rect != null:
		_overlay_rect.visible = false
	if _overlay_material != null:
		_overlay_material.set_shader_parameter(&"amount", 0.0)
	_remove_filter()
	for pid: int in fogged:
		fog_changed.emit(pid, 0.0)


func _on_clean_air() -> void:
	clear_all()


func _on_round_ended(_success: bool, _round_number: int) -> void:
	clear_all()


func _on_round_started(_round_number: int) -> void:
	_shift_fogged = false
	clear_all()


func _on_phase_changed(phase: int) -> void:
	if phase == GameState.Phase.MENU:
		_shift_fogged = false
		clear_all()


# --- helpers -------------------------------------------------------------------------------------------------------------

func _is_host() -> bool:
	return Net.is_host and is_inside_tree() and GrowPlot.is_server_peer(self)


## The cloud's motes over the tray: CLOUD_FILL of spore_radius, slow, grey-olive, already a volume when it appears.
func _make_cloud(pos: Vector3) -> Node3D:
	var root := Node3D.new()
	root.name = "Cloud"
	root.position = pos
	var radius := maxf(Config.balance.spore_radius, 0.5) * CLOUD_FILL
	var motes := make_motes(CLOUD_MOTES, CLOUD_MOTE_SEC, radius, 0.07, 0.55)
	motes.name = "Motes"
	motes.position = Vector3(0.0, CLOUD_HEIGHT, 0.0)
	motes.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	motes.emission_sphere_radius = radius
	motes.preprocess = CLOUD_MOTE_SEC * 0.5
	motes.gravity = Vector3(0.0, -0.03, 0.0)
	root.add_child(motes)
	return root


## Slow grey-olive motes (unshaded, see-through spheres, no shadow) in a sphere of `radius`.
static func make_motes(amount: int, lifetime: float, radius: float, size: float, alpha: float) -> CPUParticles3D:
	var fx := CPUParticles3D.new()
	fx.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fx.amount = amount
	fx.lifetime = lifetime
	fx.randomness = 0.5
	fx.local_coords = false
	fx.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	fx.emission_sphere_radius = radius
	fx.direction = Vector3.UP
	fx.spread = 180.0
	fx.initial_velocity_min = 0.05
	fx.initial_velocity_max = 0.25
	fx.damping_min = 0.1
	fx.damping_max = 0.3
	fx.scale_amount_min = 0.6
	fx.scale_amount_max = 1.4
	var c := spore_color()
	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.25, 0.7, 1.0])
	ramp.colors = PackedColorArray([Color(c, 0.0), Color(c, alpha), Color(c.lerp(Toon.PEBBLE, 0.4), alpha * 0.7), Color(Toon.PEBBLE, 0.0)])
	fx.color_ramp = ramp
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	var mesh := SphereMesh.new()
	mesh.radius = size
	mesh.height = size * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	mesh.material = mat
	fx.mesh = mesh
	fx.emitting = true
	return fx
