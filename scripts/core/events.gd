extends Node
## Autoload "Events": random shift events (PLAN.md M10, events agent). Do NOT add a class_name (autoload).
##
## Server-authoritative: only the host schedules / starts / ends events and broadcasts them (call_local RPCs);
## every peer gets the signals from the RPC handlers. Story (ui agent) turns the signals into Boss lines; the
## HUD shows a banner. Events run only while GameState.is_playing() and only when are_events_enabled():
##   Config.balance.events_enabled, not `--no-events`, and (a real window or `--events`), so every existing
##   headless suite keeps its deterministic shifts. Tests that want events pass `--events`.
##
## Scheduler (host): the first event event_first_delay_sec into a shift, then a gap in [event_gap_min_sec,
## event_gap_max_sec] after the previous one ended; one at a time; weighted pick (inspection 30 / power cut 20 /
## audit 10 / rat 10 / head count 15 / water off 10 / shortage 5) that never repeats the previous kind. `tick(delta)`
## drives it (public, so tests can advance time without waiting); `_process` feeds it real time on the host.
##
## Kinds:
##   inspection  the Boss (ShopkeeperNPC) walks Room.get_inspection_route() for inspection_sec, deterministic on
##               every peer from the broadcast start. Every 0.5 s the HOST checks each worker on the floor: within
##               SIGHT_RANGE, inside a SIGHT_CONE_DEG cone in front of him, a clear LAYER_WORLD ray from his eyes to
##               the chest (1.0 m up standing, 0.6 m crouched). Holding a product -> WRITE_UP_SKIMMING + the product
##               despawned (confiscated); standing (< LOITER_MOVE m) for loiter_sec while in sight -> WRITE_UP_LOITERING.
##               A worker is written up at most once per WRITE_UP_COOLDOWN_SEC. worker_spotted fires on every peer.
##   power_cut   Room.set_power(false) on every peer (power_on synced by its own RPC so late joiners get it), growth
##               and water drain pause (GrowPlot.tick checks is_power_on()); ends when a worker resets the FuseBox
##               station (its request calls server_end_event) or after power_cut_max_sec.
##   audit       GameState.server_raise_quota(audit_raise_fraction) once; the event stays up AUDIT_BANNER_SEC.
##   rat         a Rat prop (scenes/world/props/rat.tscn) runs from a wall gap to a growing plot and eats its stage
##               progress (host, RAT_EAT_PER_SEC) until a worker comes within RAT_SCARE_RANGE or RAT_MAX_SEC passes.
## M12 (disrupt agent), the interruptions:
##   headcount   the Boss walks Room.get_headcount_route() to the line (Room.get_headcount_spot(), a Marker3D in
##               front of the pay window) and stands there (ShopkeeperNPC.walk_to) for headcount_sec; when the timer
##               ends the HOST writes up every worker on the floor further than headcount_radius from the spot (flat
##               distance; the back room is excused) with WRITE_UP_ABSENT (worker_spotted fires too), then he walks
##               back. Deterministic on every peer from the broadcast start, like the inspection.
##   water_off   Well.server_set_pressure(false) on the host (the Well syncs it and replays it to late joiners):
##               prompt "No pressure", refills refused on both sides; back on when the event ends or is force-ended.
##   shortage    ShopCounter.server_set_shortage(strain) on the host (synced + replayed likewise): that strain's card
##               reads OUT OF STOCK and server_buy_seed refuses it; cleared at the end. The strain is the one planted
##               most this shift (GrowPlot has no signal, so the host tick watches the plots turn from EMPTY), the
##               most expensive strain when nothing was planted yet.
## Back room: on GameState.backroom_changed the host moves the body (Player.server_teleport) to the room's
## BackRoomSpot and back to its spawn on release (the input lock + overlay are the ui agent's).
## Copy: none here (Story owns every line); this file only emits signals and plays placeholder sounds.

## Every peer: an event began. params: inspection {"seconds", "speed"}, power_cut {"max_seconds"},
## audit {"raise"}, rat {"plot": int (GrowPlot index 1..6), "from": Vector3 (wall gap, global)},
## headcount {"seconds", "spot": Vector3 (the line, global), "speed"}, water_off {"seconds"},
## shortage {"seconds", "strain": StringName}.
signal event_started(kind: StringName, params: Dictionary)
## Every peer: the active event is over (timer, fixed, or the shift ended).
signal event_ended(kind: StringName)
## Every peer: the room's mains power changed (power cut started / fuse box reset).
signal power_changed(on: bool)
## Every peer (cosmetic): during an inspection the Boss caught `peer_id` for `reason` (Const.WRITE_UP_SKIMMING /
## WRITE_UP_LOITERING). GameState.worker_written_up carries the strikes; this one is for flashes and sounds.
signal worker_spotted(peer_id: int, reason: String)

const EVENT_INSPECTION: StringName = &"inspection"
const EVENT_POWER_CUT: StringName = &"power_cut"
const EVENT_AUDIT: StringName = &"audit"
const EVENT_RAT: StringName = &"rat"
## M12 (disrupt agent): the head count, the water main, the supply shortage.
const EVENT_HEADCOUNT: StringName = &"headcount"
const EVENT_WATER_OFF: StringName = &"water_off"
const EVENT_SHORTAGE: StringName = &"shortage"
const KINDS: Array[StringName] = [EVENT_INSPECTION, EVENT_POWER_CUT, EVENT_AUDIT, EVENT_RAT, EVENT_HEADCOUNT, EVENT_WATER_OFF, EVENT_SHORTAGE]
## Scheduler weights (percent, sum 100). The rat only enters the pick while RAT_ENABLED.
const WEIGHTS: Dictionary = {EVENT_INSPECTION: 30, EVENT_POWER_CUT: 20, EVENT_AUDIT: 10, EVENT_RAT: 10,
		EVENT_HEADCOUNT: 15, EVENT_WATER_OFF: 10, EVENT_SHORTAGE: 5}
const RAT_ENABLED := true

const SIGHT_INTERVAL := 0.5
const SIGHT_RANGE := 5.0
const SIGHT_CONE_DEG := 120.0
const CHEST_STANDING := 1.0
const CHEST_CROUCHED := 0.6
const LOITER_MOVE := 0.3
const WRITE_UP_COOLDOWN_SEC := 5.0
const BOSS_WALK_SPEED := 1.6
const KEYS_INTERVAL := 0.5
const DOOR_RANGE := 1.4
const AUDIT_BANNER_SEC := 3.0
const RAT_MAX_SEC := 30.0
const RAT_EAT_PER_SEC := 0.06
const RAT_SCARE_RANGE := 1.5
const RAT_SQUEAK_MIN := 2.5
const RAT_SQUEAK_MAX := 6.0
const RAT_SCENE_PATH := "res://scenes/world/props/rat.tscn"
const RAT_NODE_NAME := "Rat"
## Where the rat comes from and flees to: a gap at the foot of the east wall, under the cot by the grow area (global).
const RAT_GAP := Vector3(9.6, 0.0, 6.6)
## M12 disrupt: the Boss must reach the head-count line by this fraction of the event (the walk speed is raised
## above BOSS_WALK_SPEED when the route would take longer).
const HEADCOUNT_ARRIVE_FRACTION := 0.5

## The running event (&"" when none). Synced.
var active_event: StringName = &""
## False during a power cut. Synced.
var power_on: bool = true

var _params: Dictionary = {}
var _time_left: float = 0.0
## Host: seconds until the scheduler starts the next event (< 0 = nothing scheduled).
var _next_in: float = -1.0
var _last_kind: StringName = &""
## Host: simulated clock for the sight bookkeeping (advanced by tick(), so tests can drive it).
var _clock: float = 0.0
var _sight_accum: float = 0.0
var _seen_since: Dictionary = {}     # peer_id -> [clock when anchored, anchor position]
var _last_write_up: Dictionary = {}  # peer_id -> clock of the last write-up
var _keys_accum: float = 0.0
var _keys_handle: int = 0            # Sfx loop handle of the walking Boss's keys (0 = silent)
## Host: peer_id -> Room back-room slot index while the worker sits there (order-independent: the lowest free slot).
var _backroom_slots: Dictionary = {}
var _forced_first_used: bool = false # `--first-event` consumed (once per process)
var _rat_squeak_left: float = 0.0
var _rng := RandomNumberGenerator.new()
## Host (M12 disrupt): plantings this shift by strain and each plot's last seen strain (&"" = empty). GrowPlot has
## no planted signal, so tick() watches the plots turn from EMPTY; the shortage picks the most-planted strain.
var _planted: Dictionary = {}       # strain_id -> plantings this shift
var _plot_strains: Dictionary = {}  # GrowPlot index 1..6 -> StringName


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rng.randomize()
	GameState.round_started.connect(_on_round_started)
	GameState.round_ended.connect(_on_round_ended)
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.game_reset.connect(_on_game_reset)
	GameState.backroom_changed.connect(_on_backroom_changed)
	Net.peer_registered.connect(_on_peer_registered)
	Net.peer_left.connect(_on_peer_left)


func _process(delta: float) -> void:
	if _is_host():
		tick(delta)
	elif active_event != &"":
		_time_left = maxf(_time_left - delta, 0.0)
	_local_tick(delta)


# ------------------------------------------------------------------------------------------------------
# Queries (any peer)
# ------------------------------------------------------------------------------------------------------

func is_power_on() -> bool:
	return power_on


## True while an event runs (`kind` &"" = any).
func is_event_active(kind: StringName = &"") -> bool:
	return active_event != &"" and (kind == &"" or active_event == kind)


## Seconds until the active event ends on its own (0 when none). Counts down locally from the broadcast value.
func get_event_time_left() -> float:
	return _time_left if active_event != &"" else 0.0


## The params the active event started with ({} when none).
func get_event_params() -> Dictionary:
	return _params.duplicate()


## Whether the host schedules random events in this session (see the header).
func are_events_enabled() -> bool:
	if not Config.balance.events_enabled or Config.has_arg("no-events"):
		return false
	return Config.has_arg("events") or DisplayServer.get_name() != "headless"


## Host: seconds until the scheduler fires (< 0 when nothing is scheduled, e.g. between shifts or while an
## event runs). Tests read it to check the gap rule.
func get_next_event_in() -> float:
	return _next_in


## A weighted random kind that is never `previous` (rat only while RAT_ENABLED). Pure apart from the RNG.
func pick_kind(previous: StringName = &"") -> StringName:
	var total := 0
	for k in KINDS:
		if k == previous or (k == EVENT_RAT and not RAT_ENABLED):
			continue
		total += int(WEIGHTS.get(k, 0))
	if total <= 0:
		return EVENT_INSPECTION
	var roll := _rng.randi_range(1, total)
	for k in KINDS:
		if k == previous or (k == EVENT_RAT and not RAT_ENABLED):
			continue
		roll -= int(WEIGHTS.get(k, 0))
		if roll <= 0:
			return k
	return EVENT_INSPECTION


# ------------------------------------------------------------------------------------------------------
# Server API
# ------------------------------------------------------------------------------------------------------

## SERVER ONLY. Starts `kind` now (false if one is already running / not playing / unknown kind, or the rat
## finds no growing plot). Tests + the host debug menu. `params` are merged under the kind's own entries.
func server_start_event(kind: StringName, params: Dictionary = {}) -> bool:
	if not _is_host():
		push_warning("Events.server_start_event called on a non-host peer")
		return false
	if active_event != &"" or not GameState.is_playing() or not KINDS.has(kind):
		return false
	var b: BalanceConfig = Config.balance
	var p := params.duplicate(true)
	var seconds := 0.0
	match kind:
		EVENT_INSPECTION:
			seconds = maxf(b.inspection_sec, 1.0)
			p["seconds"] = seconds
			p["speed"] = _walk_speed_for(seconds)
		EVENT_POWER_CUT:
			seconds = maxf(b.power_cut_max_sec, 1.0)
			p["max_seconds"] = seconds
		EVENT_AUDIT:
			seconds = AUDIT_BANNER_SEC
			p["raise"] = b.audit_raise_fraction
		EVENT_RAT:
			if not RAT_ENABLED:
				return false
			var plot_index := _pick_rat_plot()
			if plot_index <= 0:
				return false
			seconds = RAT_MAX_SEC
			p["plot"] = plot_index
			p["from"] = RAT_GAP
		EVENT_HEADCOUNT:
			var room := _room()
			if room == null:
				return false
			seconds = maxf(b.headcount_sec, 1.0)
			p["seconds"] = seconds
			p["spot"] = room.get_headcount_spot()
			p["speed"] = _headcount_speed_for(seconds)
		EVENT_WATER_OFF:
			if _well() == null:
				return false
			seconds = maxf(b.water_off_sec, 1.0)
			p["seconds"] = seconds
		EVENT_SHORTAGE:
			if _counter() == null:
				return false
			_track_plantings()
			var strain := pick_shortage_strain()
			if strain == &"":
				return false
			seconds = maxf(b.shortage_sec, 1.0)
			p["seconds"] = seconds
			p["strain"] = strain
	_last_kind = kind
	_clock = 0.0
	_sight_accum = 0.0
	_seen_since.clear()
	_last_write_up.clear()
	_next_in = -1.0
	# The station state goes out before the event packet (same reliable channel, so it lands first).
	if kind == EVENT_POWER_CUT:
		_rpc_power.rpc(false)
	elif kind == EVENT_WATER_OFF:
		_well().server_set_pressure(false)
	elif kind == EVENT_SHORTAGE:
		_counter().server_set_shortage(StringName(p["strain"]))
	_rpc_event_started.rpc(kind, p, seconds)
	if kind == EVENT_AUDIT:
		# After the banner went out: raising the quota can end the shift at once (sales already cover it),
		# and the round_ended handler then closes this event.
		GameState.server_raise_quota(b.audit_raise_fraction)
	return true


## SERVER ONLY. Ends the running event now (restores the power) and schedules the next gap.
func server_end_event() -> void:
	if not _is_host() or active_event == &"":
		return
	var kind := active_event
	if not power_on:
		_rpc_power.rpc(true)
	_server_clear_disruption(kind)
	_rpc_event_ended.rpc(kind)
	var b: BalanceConfig = Config.balance
	_next_in = _rng.randf_range(minf(b.event_gap_min_sec, b.event_gap_max_sec), maxf(b.event_gap_min_sec, b.event_gap_max_sec))


## SERVER ONLY. Mains power on/off outside an event (the FuseBox uses it if the power is off with no event).
func server_set_power(on: bool) -> void:
	if not _is_host() or on == power_on:
		return
	_rpc_power.rpc(on)


## Host only (ignored elsewhere): start an event from the UI / debug (validated like a request).
func request_event(kind: StringName) -> void:
	if not _is_host():
		return
	server_start_event(kind)


## Host time step: scheduler + the active event's rules. Public so tests can advance time; `_process` calls it
## with real time on the host. Sight checks run every SIGHT_INTERVAL of simulated time.
func tick(delta: float) -> void:
	if not _is_host() or delta <= 0.0:
		return
	_track_plantings()
	if active_event != &"":
		_time_left = maxf(_time_left - delta, 0.0)
		match active_event:
			EVENT_INSPECTION:
				_tick_inspection(delta)
			EVENT_RAT:
				_tick_rat(delta)
			EVENT_HEADCOUNT:
				_clock += delta
				if _time_left <= 0.0:
					server_headcount()
					server_end_event()
			_:
				_clock += delta
				if _time_left <= 0.0:
					server_end_event()
		return
	if not GameState.is_playing() or _next_in < 0.0 or not are_events_enabled():
		return
	_next_in -= delta
	if _next_in <= 0.0:
		_next_in = -1.0
		var kind := pick_kind(_last_kind)
		# Playtests / screenshots: `--first-event=<kind>` forces the first event of the session.
		var forced := StringName(String(Config.get_arg("first-event", "")))
		if not _forced_first_used and forced in KINDS:
			_forced_first_used = true
			kind = forced
		if not server_start_event(kind):
			# Nothing could start (e.g. no plot for a rat): try again after a short gap.
			_next_in = 5.0


## SERVER ONLY. One inspection sight pass (normally every SIGHT_INTERVAL from tick()). Public for tests.
func server_sight_check() -> void:
	if not _is_host() or active_event != EVENT_INSPECTION:
		return
	var boss := _boss()
	var w: World = Game.world
	if boss == null or w == null or not is_instance_valid(w) or not boss.is_walking():
		return
	var eye: Vector3 = boss.get_eye_position()
	var facing: Vector3 = boss.get_facing()
	var space := w.get_world_3d().direct_space_state
	var cos_half := cos(deg_to_rad(SIGHT_CONE_DEG * 0.5))
	var seen: Dictionary = {}
	for player in w.get_players():
		var pid: int = player.peer_id
		if GameState.is_in_backroom(pid) or not player.is_inside_tree():
			continue
		var chest: Vector3 = player.global_position + Vector3.UP * (CHEST_CROUCHED if player.crouching else CHEST_STANDING)
		var to := chest - eye
		if not (to.length() <= SIGHT_RANGE):
			continue
		var flat := Vector3(to.x, 0.0, to.z)
		if flat.length_squared() > 0.0001 and facing.dot(flat.normalized()) < cos_half:
			continue
		var query := PhysicsRayQueryParameters3D.create(eye, chest, Const.LAYER_WORLD)
		if not space.intersect_ray(query).is_empty():
			continue
		seen[pid] = true
		_judge(player, w)
	for pid in _seen_since.keys():
		if not seen.has(pid):
			_seen_since.erase(pid)


# ------------------------------------------------------------------------------------------------------
# Host internals
# ------------------------------------------------------------------------------------------------------

func _is_host() -> bool:
	return Net.is_host and multiplayer.has_multiplayer_peer() and multiplayer.is_server()


func _tick_inspection(delta: float) -> void:
	var remaining := delta
	while remaining > 0.0:
		var step := minf(remaining, SIGHT_INTERVAL - _sight_accum)
		_clock += step
		_sight_accum += step
		remaining -= step
		if _sight_accum >= SIGHT_INTERVAL - 0.000001:
			_sight_accum = 0.0
			server_sight_check()
			if active_event != EVENT_INSPECTION:
				return
	var boss := _boss()
	if _time_left <= 0.0 or (boss != null and not boss.is_walking()):
		server_end_event()


func _judge(player: Player, w: World) -> void:
	var pid: int = player.peer_id
	var pos: Vector3 = player.global_position
	var held: Item = w.items.get_held_by(pid) if w.items != null else null
	if held != null and held.item_type == Const.ITEM_PRODUCT:
		if _can_write_up(pid):
			_write_up(pid, Const.WRITE_UP_SKIMMING)
			w.items.server_despawn_item(held)
			_rpc_spotted.rpc(pid, Const.WRITE_UP_SKIMMING)
		_seen_since[pid] = [_clock, pos]
		return
	# M13 QA: a worker who cannot move is not loitering. While a stun runs (a bite, a shove, a thrown item, a flame:
	# the server's own view, Player.is_stunned()) the loiter clock restarts, so loiter_sec counts from the moment they
	# can walk again. Before this a worker bitten in the Boss's sight and pinned where he stood was written up for
	# standing still through the stun.
	if player.is_stunned():
		_seen_since[pid] = [_clock, pos]
		return
	if not _seen_since.has(pid):
		_seen_since[pid] = [_clock, pos]
		return
	var entry: Array = _seen_since[pid]
	if pos.distance_to(entry[1]) > LOITER_MOVE:
		_seen_since[pid] = [_clock, pos]
		return
	if _clock - float(entry[0]) >= Config.balance.loiter_sec and _can_write_up(pid):
		_write_up(pid, Const.WRITE_UP_LOITERING)
		_rpc_spotted.rpc(pid, Const.WRITE_UP_LOITERING)
		_seen_since[pid] = [_clock, pos]


func _can_write_up(pid: int) -> bool:
	return not _last_write_up.has(pid) or _clock - float(_last_write_up[pid]) >= WRITE_UP_COOLDOWN_SEC


func _write_up(pid: int, reason: String) -> void:
	_last_write_up[pid] = _clock
	GameState.server_write_up(pid, reason)


## Walk speed so the whole route (home -> points -> home) fits inside `seconds` with a little slack.
func _walk_speed_for(seconds: float) -> float:
	var room := _room()
	var boss := _boss()
	if room == null or boss == null:
		return BOSS_WALK_SPEED
	var length: float = boss.get_route_length(room.get_inspection_route())
	return maxf(BOSS_WALK_SPEED, length / maxf(seconds - 2.0, 1.0))


func _tick_rat(delta: float) -> void:
	_clock += delta
	var rat := _rat()
	var w: World = Game.world
	if rat != null and w != null and rat.has_method(&"is_eating") and bool(rat.call(&"is_eating")):
		var plot := _rat_target_plot()
		if plot != null and plot.is_growing():
			plot.stage_progress = maxf(plot.stage_progress - RAT_EAT_PER_SEC * delta, 0.0)
		for player in w.get_players():
			if GameState.is_in_backroom(player.peer_id):
				continue
			if player.global_position.distance_to(rat.global_position) <= RAT_SCARE_RANGE:
				server_end_event()
				return
	if _time_left <= 0.0:
		server_end_event()


## A random plot with a growing plant (1..6), 0 when none.
func _pick_rat_plot() -> int:
	var room := _room()
	if room == null:
		return 0
	var candidates: Array[int] = []
	for i in range(1, 7):
		var plot := room.get_station("GrowPlot%d" % i) as GrowPlot
		if plot != null and plot.is_growing():
			candidates.append(i)
	if candidates.is_empty():
		return 0
	return candidates[_rng.randi_range(0, candidates.size() - 1)]


func _rat_target_plot() -> GrowPlot:
	var room := _room()
	if room == null:
		return null
	return room.get_station("GrowPlot%d" % int(_params.get("plot", 0))) as GrowPlot


# ------------------------------------------------------------------------------------------------------
# Back room (host moves the body)
# ------------------------------------------------------------------------------------------------------

func _on_backroom_changed(peer_id: int, active: bool) -> void:
	if not _is_host():
		return
	var w: World = Game.world
	if w == null or not is_instance_valid(w) or w.room == null:
		return
	if not active:
		_backroom_slots.erase(peer_id)
	var player := w.get_player(peer_id)
	if player == null or not player.is_inside_tree():
		return
	var xf: Transform3D
	if active:
		xf = w.room.get_backroom_transform(_claim_backroom_slot(peer_id))
	else:
		xf = w.room.get_spawn_transform(player.spawn_index)
	_move_player(player, xf)
	if active and w.items != null:
		# Whatever they were carrying goes back to the floor at their spawn (ItemManager places a back-room
		# worker's item there): the team is never down a can for the whole stay.
		w.items.server_release_holder(peer_id)


## Host: the slot a back-room worker sits on. The lowest slot no other back-room worker holds, kept until they leave:
## the sorted-peer-index used before put the second worker onto the first one's marker whenever their peer id was
## the lower of the two (peer ids are random, so a coin flip per session).
func _claim_backroom_slot(peer_id: int) -> int:
	if _backroom_slots.has(peer_id):
		return int(_backroom_slots[peer_id])
	var used: Dictionary = {}
	for k in _backroom_slots:
		used[int(_backroom_slots[k])] = true
	var slot := 0
	while used.has(slot):
		slot += 1
	_backroom_slots[peer_id] = slot
	return slot


## Moves a player's body. Owned bodies go through Player.server_teleport (owner-authoritative movement); a body
## nobody owns (a fake worker in a headless test) is placed directly.
func _move_player(player: Player, xf: Transform3D) -> void:
	if player.is_local() or multiplayer.get_peers().has(player.peer_id):
		player.server_teleport(xf)
	else:
		player.place_at(xf)


# ------------------------------------------------------------------------------------------------------
# Sync (RPC handlers run on every peer, the host included via call_local)
# ------------------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_event_started(kind: StringName, params: Dictionary, seconds: float) -> void:
	active_event = kind
	_params = params
	_time_left = maxf(seconds, 0.0)
	_keys_accum = 0.0
	match kind:
		EVENT_INSPECTION:
			_start_inspection_visuals(params, seconds)
		EVENT_RAT:
			_spawn_rat(params, seconds)
		EVENT_HEADCOUNT:
			_start_headcount_visuals(params, seconds)
	_play_start_sound(kind)
	event_started.emit(kind, params)


@rpc("authority", "call_local", "reliable")
func _rpc_event_ended(kind: StringName) -> void:
	if active_event == &"":
		return
	var p := _params
	active_event = &""
	_time_left = 0.0
	_params = {}
	match kind:
		EVENT_INSPECTION:
			var boss := _boss()
			if boss != null:
				boss.return_home()
			var room := _room()
			if room != null:
				room.set_backroom_door_open(false)
		EVENT_RAT:
			var rat := _rat()
			if rat != null and rat.has_method(&"flee"):
				rat.call(&"flee")
		EVENT_HEADCOUNT:
			_end_headcount_visuals(p)
	event_ended.emit(kind)


@rpc("authority", "call_local", "reliable")
func _rpc_power(on: bool) -> void:
	var changed := on != power_on
	power_on = on
	var room := _room()
	if room != null:
		room.set_power(on)
	if changed:
		Sfx.play(&"power_up" if on else &"power_down")
		power_changed.emit(on)


@rpc("authority", "call_local", "reliable")
func _rpc_spotted(peer_id: int, reason: String) -> void:
	if reason == Const.WRITE_UP_SKIMMING:
		var player := Game.get_player(peer_id)
		if player != null and player.is_inside_tree():
			Sfx.play(&"confiscate", player.global_position + Vector3.UP * 1.0)
		else:
			Sfx.play(&"confiscate")
	worker_spotted.emit(peer_id, reason)


## Host: a late joiner gets the current power state and the running event (with the seconds left).
func _on_peer_registered(peer_id: int) -> void:
	if not _is_host():
		return
	if not power_on:
		_rpc_power.rpc_id(peer_id, false)
	if active_event != &"":
		_rpc_event_started.rpc_id(peer_id, active_event, _params, _time_left)


func _on_peer_left(peer_id: int) -> void:
	_seen_since.erase(peer_id)
	_last_write_up.erase(peer_id)
	_backroom_slots.erase(peer_id)


# ------------------------------------------------------------------------------------------------------
# Shift flow
# ------------------------------------------------------------------------------------------------------

func _on_round_started(_round_number: int) -> void:
	if _is_host():
		_next_in = maxf(Config.balance.event_first_delay_sec, 0.0)
		# Playtests / screenshots: `--event-delay=<sec>` overrides the first delay of every shift.
		var raw: Variant = Config.get_arg("event-delay", null)
		if raw is String and String(raw).is_valid_float():
			_next_in = maxf(float(raw), 0.0)
		_last_kind = &""
		# M12 disrupt: plantings count per shift; plants that persist from the last shift are the baseline.
		_planted.clear()
		_plot_strains.clear()
		_track_plantings(false)


func _on_round_ended(_success: bool, _round_number: int) -> void:
	_host_close_shift()


func _on_game_reset() -> void:
	_host_close_shift()


func _on_phase_changed(phase: int) -> void:
	if phase == GameState.Phase.MENU:
		_reset_local()
	elif phase != GameState.Phase.PLAYING:
		_host_close_shift()


## Host: the shift is over (or never started): end the running event, restore the power, stop scheduling.
func _host_close_shift() -> void:
	if not _is_host():
		return
	_next_in = -1.0
	_backroom_slots.clear() # the shift end lets everyone out (GameState clears `backroom`)
	if active_event != &"":
		server_end_event()
	if not power_on:
		_rpc_power.rpc(true)
	_server_restore_stations()  # M12 disrupt: the water main on, nothing out of stock, whatever turned them
	_next_in = -1.0


## Any peer, back to the menu: forget the session's events (the world is about to go).
func _reset_local() -> void:
	_next_in = -1.0
	_last_kind = &""
	_seen_since.clear()
	_last_write_up.clear()
	_backroom_slots.clear()
	var was_active := active_event
	active_event = &""
	_params = {}
	_time_left = 0.0
	var room := _room()
	if was_active == EVENT_RAT:
		var rat := _rat()
		if rat != null:
			rat.queue_free()
	elif was_active == EVENT_HEADCOUNT:
		var boss := _boss()
		if boss != null:
			boss.return_home()
	_planted.clear()
	_plot_strains.clear()
	if not power_on:
		power_on = true
		if room != null:
			room.set_power(true)
		power_changed.emit(true)
	if was_active != &"":
		event_ended.emit(was_active)


# ------------------------------------------------------------------------------------------------------
# Cosmetics on every peer
# ------------------------------------------------------------------------------------------------------

func _local_tick(delta: float) -> void:
	# The keys loop and the booth door follow the Boss on any walk: the inspection, the head count (M12 disrupt) and
	# his way back from the line after it. He only ever walks for an event.
	var boss := _boss()
	var room := _room()
	if boss != null and room != null and boss.is_walking():
		_set_keys_loop(true, boss)
		room.set_backroom_door_open(boss.global_position.distance_to(room.get_backroom_door_position()) < DOOR_RANGE)
	else:
		_set_keys_loop(false, null)
		if room != null and room.is_backroom_door_open():
			room.set_backroom_door_open(false)
	if active_event == EVENT_RAT:
		var rat := _rat()
		if rat == null:
			return
		_rat_squeak_left -= delta
		if _rat_squeak_left <= 0.0:
			_rat_squeak_left = _rng.randf_range(RAT_SQUEAK_MIN, RAT_SQUEAK_MAX)
			Sfx.play(&"rat", rat.global_position + Vector3.UP * 0.1)


## The keys-on-a-belt loop (Sfx `keys`, follows the Boss) runs exactly while he walks; idempotent.
func _set_keys_loop(on: bool, boss: Node3D) -> void:
	if on:
		if _keys_handle == 0 and boss != null and Sfx.has_method(&"play_loop"):
			_keys_handle = int(Sfx.call(&"play_loop", &"keys", boss))
	elif _keys_handle != 0:
		if Sfx.has_method(&"stop_loop"):
			Sfx.call(&"stop_loop", _keys_handle)
		_keys_handle = 0


## Every peer: start (or resume, for a late joiner) the Boss's deterministic walk.
func _start_inspection_visuals(params: Dictionary, seconds_left: float) -> void:
	var room := _room()
	var boss := _boss()
	if room == null or boss == null:
		return
	var total := float(params.get("seconds", seconds_left))
	var elapsed := maxf(total - seconds_left, 0.0)
	var speed := float(params.get("speed", BOSS_WALK_SPEED))
	boss.walk_route(room.get_inspection_route(), speed, elapsed)


## Every peer: the rat prop, a plain child of the Room (not a spawned node). A late joiner replays the event with
## the seconds left: he is placed where he already is by now (part-way along his run, or at the tray), not at the gap.
func _spawn_rat(params: Dictionary, seconds_left: float = RAT_MAX_SEC) -> void:
	var room := _room()
	if room == null:
		return
	var old := _rat()
	if old != null:
		old.name = RAT_NODE_NAME + "_gone"
		old.queue_free()
	var scene := load(RAT_SCENE_PATH) as PackedScene
	if scene == null:
		return
	var rat := scene.instantiate() as Node3D
	if rat == null:
		return
	rat.name = RAT_NODE_NAME
	room.add_child(rat)
	var from: Vector3 = params.get("from", RAT_GAP)
	rat.global_position = from
	_rat_squeak_left = 0.6
	var plot := room.get_station("GrowPlot%d" % int(params.get("plot", 0))) as Node3D
	if plot == null or not rat.has_method(&"run_to"):
		return
	var target: Vector3 = plot.global_position + plot.global_basis.z.normalized() * 0.55
	rat.call(&"run_to", target)
	var elapsed := RAT_MAX_SEC - seconds_left
	if elapsed <= 0.0:
		return
	# Resume: he left the gap `elapsed` seconds ago at run_speed. Arriving exactly at the target makes him eat next frame.
	var run := Vector3(target.x - from.x, 0.0, target.z - from.z)
	var speed_v: Variant = rat.get(&"run_speed")
	var speed := float(speed_v) if speed_v != null else 2.6
	var t := clampf(elapsed / maxf(run.length() / maxf(speed, 0.01), 0.001), 0.0, 1.0)
	rat.global_position = Vector3(lerpf(from.x, target.x, t), from.y, lerpf(from.z, target.z, t))
	if run.length_squared() > 0.0001:
		rat.global_rotation.y = atan2(-run.x, -run.z)


func _room() -> Room:
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return null
	return w.room


func _boss() -> ShopkeeperNPC:
	var room := _room()
	if room == null:
		return null
	var counter := room.get_station("ShopCounter")
	if counter != null:
		var keeper := counter.get_node_or_null(^"ShopkeeperAnchor/Shopkeeper") as ShopkeeperNPC
		if keeper != null:
			return keeper
	for n in get_tree().get_nodes_in_group(Const.GROUP_NPCS):
		if n is ShopkeeperNPC:
			return n as ShopkeeperNPC
	return null


func _rat() -> Node3D:
	var room := _room()
	if room == null:
		return null
	var rat := room.get_node_or_null(NodePath(RAT_NODE_NAME)) as Node3D
	if rat != null and rat.is_queued_for_deletion():
		return null
	return rat


# ------------------------------------------------------------------------------------------------------
# M12 disrupt: the head count, the water main, the supply shortage
# ------------------------------------------------------------------------------------------------------

## SERVER ONLY. The count at the end of a head count: every worker with a body on the floor (the back room is
## excused) further than headcount_radius from the line (flat distance; a non-finite position counts as absent)
## gets WRITE_UP_ABSENT, and worker_spotted(peer, absent) fires on every peer. Returns the peers written up.
## Public for tests (normally called by tick() when the timer runs out).
func server_headcount() -> Array[int]:
	var out: Array[int] = []
	if not _is_host() or active_event != EVENT_HEADCOUNT:
		return out
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return out
	var spot: Vector3 = _params.get("spot", _room().get_headcount_spot() if _room() != null else Vector3.ZERO)
	var radius := maxf(Config.balance.headcount_radius, 0.0)
	for player in w.get_players():
		var pid: int = player.peer_id
		if GameState.is_in_backroom(pid) or not player.is_inside_tree():
			continue
		var p: Vector3 = player.global_position
		var flat := Vector2(p.x - spot.x, p.z - spot.z).length()
		if not (flat <= radius):
			GameState.server_write_up(pid, Const.WRITE_UP_ABSENT)
			_rpc_spotted.rpc(pid, Const.WRITE_UP_ABSENT)
			out.append(pid)
	return out


## The strain a shortage hits: the one planted most this shift (ties go to the dearer one), the most expensive
## strain when nothing was planted yet; &"" without seeds. Reads the host's planting count (see _track_plantings).
func pick_shortage_strain() -> StringName:
	var best: SeedDef = null
	var best_count := 0
	for s in Config.balance.seeds:
		if s == null:
			continue
		var n := int(_planted.get(s.id, 0))
		if best == null or n > best_count or (n == best_count and s.cost > best.cost):
			best = s
			best_count = n
	return best.id if best != null else &""


## Host: plantings this shift by strain (a copy; empty off the host). Tests read it.
func get_planted_counts() -> Dictionary:
	return _planted.duplicate()


## Walk speed so the Boss reaches the line by HEADCOUNT_ARRIVE_FRACTION of the event.
func _headcount_speed_for(seconds: float) -> float:
	var room := _room()
	var boss := _boss()
	if room == null or boss == null:
		return BOSS_WALK_SPEED
	var points := room.get_headcount_route()
	# get_route_length() measures home -> points -> home; the way there is that minus the last leg back.
	var there: float = boss.get_route_length(points) - points[points.size() - 1].distance_to(boss.global_position)
	return maxf(BOSS_WALK_SPEED, maxf(there, 0.0) / maxf(seconds * HEADCOUNT_ARRIVE_FRACTION, 1.0))


## The route every peer walks the Boss along: the room's way to the line, its last point replaced by the broadcast
## spot (so every peer agrees on it even if a room differs).
func _headcount_route(params: Dictionary) -> PackedVector3Array:
	var room := _room()
	if room == null:
		return PackedVector3Array()
	var points := room.get_headcount_route()
	var spot: Variant = params.get("spot", null)
	if spot is Vector3 and not points.is_empty():
		points[points.size() - 1] = spot
	return points


## Every peer: the Boss sets off for the line (or resumes part-way, for a late joiner) and stands there facing the room.
func _start_headcount_visuals(params: Dictionary, seconds_left: float) -> void:
	var room := _room()
	var boss := _boss()
	if room == null or boss == null:
		return
	var total := float(params.get("seconds", seconds_left))
	var elapsed := maxf(total - seconds_left, 0.0)
	var speed := float(params.get("speed", BOSS_WALK_SPEED))
	var points := _headcount_route(params)
	if points.is_empty():
		return
	boss.walk_to(points, speed, elapsed, room.global_position)


## Every peer: the count is over. From the line he walks back the way he came (the full home -> line -> home route
## resumed at the line); cut short before he got there, he just goes home.
func _end_headcount_visuals(params: Dictionary) -> void:
	var boss := _boss()
	if boss == null:
		return
	var points := _headcount_route(params)
	if boss.is_at_post() and not points.is_empty():
		var speed := float(params.get("speed", BOSS_WALK_SPEED))
		var there := boss.get_walk_length()
		boss.walk_route(points, speed, there / maxf(speed, 0.05))
	else:
		boss.return_home()


## Host: the ending event's station state goes back to normal.
func _server_clear_disruption(kind: StringName) -> void:
	match kind:
		EVENT_WATER_OFF:
			var well := _well()
			if well != null:
				well.server_set_pressure(true)
		EVENT_SHORTAGE:
			var counter := _counter()
			if counter != null:
				counter.server_set_shortage(&"")


## Host: the water main on and nothing out of stock, whatever turned them (shift end, reset). No-ops when so.
func _server_restore_stations() -> void:
	var well := _well()
	if well != null and not well.has_pressure():
		well.server_set_pressure(true)
	var counter := _counter()
	if counter != null and counter.get_shortage_strain() != &"":
		counter.server_set_shortage(&"")


## Host: a plot that was EMPTY last time and holds a strain now was planted (counted unless `count` is false:
## the shift-start baseline). Cheap (six plots), run from tick().
func _track_plantings(count: bool = true) -> void:
	var room := _room()
	if room == null:
		return
	for i in range(1, 7):
		var plot := room.get_station("GrowPlot%d" % i) as GrowPlot
		if plot == null:
			continue
		var now: StringName = plot.strain_id if plot.stage != GrowPlot.Stage.EMPTY else &""
		var before: StringName = _plot_strains.get(i, &"")
		if count and now != &"" and before == &"":
			_planted[now] = int(_planted.get(now, 0)) + 1
		_plot_strains[i] = now


## Every peer: the event's own sound (the registered M12 names for the interruptions, the alarm for the rest).
func _play_start_sound(kind: StringName) -> void:
	match kind:
		EVENT_HEADCOUNT:
			Sfx.play(&"headcount")
		EVENT_WATER_OFF:
			var well := _well()
			if well != null and well.is_inside_tree():
				Sfx.play(&"water_off", well.global_position + Vector3.UP * 1.0)
			else:
				Sfx.play(&"water_off")
		EVENT_SHORTAGE:
			var counter := _counter()
			if counter != null and counter.is_inside_tree():
				Sfx.play(&"shortage", counter.global_position + Vector3.UP * 1.2)
			else:
				Sfx.play(&"shortage")
		_:
			Sfx.play(&"alarm")


func _well() -> Well:
	var room := _room()
	return room.get_station("Well") as Well if room != null else null


func _counter() -> ShopCounter:
	var room := _room()
	return room.get_station("ShopCounter") as ShopCounter if room != null else null
