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
## event_gap_max_sec] after the previous one ended; one at a time; weighted pick (inspection 26 / power cut 16 /
## audit 8 / rat 8 / head count 12 / water off 8 / shortage 6 / leak 8 / drive-by 8) that never repeats the previous kind. `tick(delta)`
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
## M14 (mayhem agent), the what-the-hell moments (the region at the end of the file):
##   leak        Well.server_set_leaking(true) on the host: a jet, a spreading puddle, the `leak` loop, the prompt
##               "Hold E · Patch the leak". A worker's finished hold (Well validates it) ends the event with nothing
##               lost. When leak_sec runs out unpatched the tank is empty: Well.server_set_pressure(false) for
##               leak_empty_sec, then the pressure returns by itself; the event ends when the leak ends either way.
##               The puddle stays puddle_sec after the event. While it lies there the HOST judges every worker's
##               speed from the synced position: faster than get_slip_speed() on the floor inside it = a slip
##               (stagger slip_stun_sec, the held item released, STAT_SLIPS), at most one per worker per 3 s.
##   driveby     driveby_warning_sec of warning (the `tires` sound outside), then driveby_sec of gunfire: every
##               DRIVEBY_SHOT_INTERVAL the HOST picks a random Room.get_gunfire_lanes() lane, cuts it at the first
##               LAYER_WORLD hit that is not glass and resolves it (server_fire_lane): a worker within DRIVEBY_WORKER_RADIUS of it who
##               is not crouching, not in the back room and not stagger-immune is knocked down (twice hit_stun_sec,
##               item released, STAT_SHOT); a growing tray within DRIVEBY_TRAY_RADIUS loses driveby_tray_loss of stage
##               progress, once per drive-by. Each shot is one cosmetic RPC. When the timer runs out the floor is
##               fined driveby_fine, as far as cash on hand goes. A force-ended drive-by bills nobody.
## Back room: on GameState.backroom_changed the host moves the body (Player.server_teleport) to the room's
## BackRoomSpot and back to its spawn on release (the input lock + overlay are the ui agent's).
## Copy: none here (Story owns every line); this file only emits signals and plays placeholder sounds.

## Every peer: an event began. params: inspection {"seconds", "speed"}, power_cut {"max_seconds"},
## audit {"raise"}, rat {"plot": int (GrowPlot index 1..6), "from": Vector3 (wall gap, global)},
## headcount {"seconds", "spot": Vector3 (the line, global), "speed"}, water_off {"seconds"},
## shortage {"seconds", "strain": StringName}, leak {"seconds"}, driveby {"seconds", "warning"} (M14 mayhem).
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
## M14 (mayhem agent): the tank springs a leak, a drive-by.
const EVENT_LEAK: StringName = &"leak"
const EVENT_DRIVEBY: StringName = &"driveby"
const KINDS: Array[StringName] = [EVENT_INSPECTION, EVENT_POWER_CUT, EVENT_AUDIT, EVENT_RAT, EVENT_HEADCOUNT, EVENT_WATER_OFF, EVENT_SHORTAGE,
		EVENT_LEAK, EVENT_DRIVEBY]
## Scheduler weights (percent, sum 100). The rat only enters the pick while RAT_ENABLED. M14 mayhem rebalanced them.
const WEIGHTS: Dictionary = {EVENT_INSPECTION: 26, EVENT_POWER_CUT: 16, EVENT_AUDIT: 8, EVENT_RAT: 8,
		EVENT_HEADCOUNT: 12, EVENT_WATER_OFF: 8, EVENT_SHORTAGE: 6, EVENT_LEAK: 8, EVENT_DRIVEBY: 8}
const RAT_ENABLED := true

const SIGHT_INTERVAL := 0.5
const SIGHT_RANGE := 5.0
const SIGHT_CONE_DEG := 120.0
const CHEST_STANDING := 1.0
const CHEST_CROUCHED := 0.6
const LOITER_MOVE := 0.3
## Slack on the loiter clock (seconds): see _judge.
const LOITER_EPSILON := 0.001
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
## Host (M13 review): the workers who stood on the floor when the running head count began (peer_id -> true). Only
## they can be absent at the end of it.
var _headcount_roster: Dictionary = {}


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
		total += get_weight(k) # M15 replay: the weight x the conditions' event_weight:<kind>
	if total <= 0:
		return EVENT_INSPECTION
	var roll := _rng.randi_range(1, total)
	for k in KINDS:
		if k == previous or (k == EVENT_RAT and not RAT_ENABLED):
			continue
		roll -= get_weight(k) # M15 replay
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
			seconds = maxf(b.power_cut_max_sec, 1.0) * GameState.condition_value(&"power_cut_sec", 1.0) # M15 replay: * power_cut_sec
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
			# M13 review: the roster is who stands on the floor NOW. A worker let out of the back room or joining
			# the session during the count appears at a spawn point (4 m from the line) and used to be written
			# up as absent for a count they never heard called.
			_headcount_roster.clear()
			var hw: World = Game.world
			if hw != null and is_instance_valid(hw):
				for player in hw.get_players():
					if not GameState.is_in_backroom(player.peer_id):
						_headcount_roster[player.peer_id] = true
		EVENT_WATER_OFF:
			if _well() == null or _leak_empty_left > 0.0:  # M14 mayhem: an empty tank has no main to turn off
				return false
			seconds = maxf(b.water_off_sec, 1.0)
			p["seconds"] = seconds
		EVENT_LEAK, EVENT_DRIVEBY:  # M14 mayhem
			seconds = _mayhem_prepare(kind, p)
			if seconds <= 0.0:
				return false
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
	elif kind == EVENT_LEAK:  # M14 mayhem
		_well().server_set_leaking(true)
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
	_next_in = _rng.randf_range(minf(b.event_gap_min_sec, b.event_gap_max_sec), maxf(b.event_gap_min_sec, b.event_gap_max_sec)) * GameState.get_event_gap_factor() # M15 replay: gaps shrink per shift, x the conditions' event_gap


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
	_mayhem_tick(delta)  # M14 mayhem: the puddle, the slips, the empty tank (they outlive the leak event)
	if active_event != &"":
		_time_left = maxf(_time_left - delta, 0.0)
		match active_event:
			EVENT_INSPECTION:
				_tick_inspection(delta)
			EVENT_RAT:
				_tick_rat(delta)
			EVENT_LEAK:  # M14 mayhem
				_tick_leak(delta)
			EVENT_DRIVEBY:  # M14 mayhem
				_tick_driveby(delta)
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
	# M14 mayhem (flake fix): the clock is a sum of float steps, so the half-second passes can add up to a hair under
	# loiter_sec and miss it by one pass (tools/tests/events_body.gd "loitering" failed about one run in three).
	if _clock - float(entry[0]) >= Config.balance.loiter_sec - LOITER_EPSILON and _can_write_up(pid):
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
	for i in range(1, Room.GROW_PLOT_COUNT + 1): # M14 level: the hall's trays too (the gap is by the corridor door)
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
		# M13: except a flamethrower. The Boss keeps it (it used to lie at the worker's spawn with its fuel, so three
		# acts of arson could repeat after every back-room stay).
		var held := w.items.get_held_by(peer_id)
		if held != null and held.item_type == Const.ITEM_FLAMETHROWER:
			w.items.server_despawn_item(held)
			_rpc_flamethrower_kept.rpc(peer_id)
		else:
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
	_mayhem_on_started(kind, params, seconds)  # M14 mayhem
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


## Every peer (M13): the Boss kept the flamethrower of a worker he sent to the back room.
const TOAST_FLAMETHROWER_KEPT := "The Boss keeps %s's flamethrower."

@rpc("authority", "call_local", "reliable")
func _rpc_flamethrower_kept(peer_id: int) -> void:
	Sfx.play(&"confiscate")
	Game.toast(TOAST_FLAMETHROWER_KEPT % Net.get_player_name(peer_id), &"info")
	var story: Node = get_node_or_null(^"/root/Story")
	if story != null and story.has_method(&"bark_now"):
		story.call(&"bark_now", String(story.call(&"line", "confiscated")))


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
	_slip_track.erase(peer_id)  # M14 mayhem
	_last_slip.erase(peer_id)


# ------------------------------------------------------------------------------------------------------
# Shift flow
# ------------------------------------------------------------------------------------------------------

func _on_round_started(_round_number: int) -> void:
	if _is_host():
		_next_in = maxf(Config.balance.event_first_delay_sec, 0.0) * GameState.get_event_gap_factor() # M15 replay: the first delay shrinks with the gaps
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
	_mayhem_reset_local()  # M14 mayhem
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
## excused, and so is anyone who was not on the floor when the count began: M13 review, `_headcount_roster`) further
## than headcount_radius from the line (flat distance; a non-finite position counts as absent)
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
		if not _headcount_roster.has(pid):
			continue # M13 review: not on the floor when the count began (back room, joined since): excused
		var p: Vector3 = player.global_position
		var flat := Vector2(p.x - spot.x, p.z - spot.z).length()
		if not (flat <= radius):
			GameState.server_write_up(pid, Const.WRITE_UP_ABSENT)
			_rpc_spotted.rpc(pid, Const.WRITE_UP_ABSENT)
			out.append(pid)
	return out


## The strain a shortage hits: the one planted most this shift (every strain ties at zero when nothing was planted
## yet); &"" without seeds. Reads the host's planting count (see _track_plantings).
## M13 review: among the strains with the top count the pick is the dearest one the team can pay for right now (cash
## on hand), the cheapest when it can pay for none. Before, with nothing planted yet, the shortage always hit the
## dearest strain on the list: usually one nobody could afford anyway, so the event cost nothing.
func pick_shortage_strain() -> StringName:
	var top := 0
	for s in Config.balance.seeds:
		if s != null:
			top = maxi(top, int(_planted.get(s.id, 0)))
	var cash: int = GameState.money
	var best: SeedDef = null
	for s in Config.balance.seeds:
		if s == null or int(_planted.get(s.id, 0)) != top or not GameState.is_strain_unlocked(s.id): # M15 replay: never a strain that is not sold yet
			continue
		if best == null:
			best = s
			continue
		var s_ok := s.cost <= cash
		var best_ok := best.cost <= cash
		if (s_ok and not best_ok) or (s_ok and best_ok and s.cost > best.cost) or (not s_ok and not best_ok and s.cost < best.cost):
			best = s
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
		EVENT_LEAK:  # M14 mayhem: the hole closes, the puddle starts to dry
			_server_stop_leak()


## Host: the water main on and nothing out of stock, whatever turned them (shift end, reset). No-ops when so.
func _server_restore_stations() -> void:
	_mayhem_server_reset()  # M14 mayhem: no leak, no puddle, no empty-tank timer (the pressure is restored below)
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
	for i in range(1, Room.GROW_PLOT_COUNT + 1): # M14 level: the hall's trays too
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
		EVENT_DRIVEBY:  # M14 mayhem: the tyres outside are its sound (_mayhem_on_started), no alarm
			pass
		_:
			Sfx.play(&"alarm")


func _well() -> Well:
	var room := _room()
	return room.get_station("Well") as Well if room != null else null


func _counter() -> ShopCounter:
	var room := _room()
	return room.get_station("ShopCounter") as ShopCounter if room != null else null


# ------------------------------------------------------------------------------------------------------
# --- M14 mayhem: the tank springs a leak, a drive-by --------------------------------------------------
# ------------------------------------------------------------------------------------------------------
# Everything here is decided on the host. The other peers see the Well's synced leak state, the event packets and
# the RPCs below (the reliable ones carry what matters: who patched, who slipped, who went down, the bill; a shot's
# tracer and sounds travel unreliably). Story owns the copy: this file only emits signals and plays sounds.

## Every peer: the leak is over. patched = `by_peer` held the hole shut; not patched = it ran out, the tank is empty.
signal leak_resolved(patched: bool, by_peer: int)
## Every peer: the tank has water again after an unpatched leak.
signal tank_refilled
## Every peer: `peer_id` slipped in the puddle.
signal worker_slipped(peer_id: int)
## Every peer (cosmetic, unreliable): one round went down a lane from `from` to where it stopped, `to` (global).
signal shot_fired(from: Vector3, to: Vector3)
## Every peer: gunfire knocked `peer_id` down.
signal worker_shot(peer_id: int)
## Every peer: a growing tray took a round (`plot_name` = its node name, "GrowPlot3").
signal tray_shot(plot_name: String)
## Every peer: the drive-by ran its course and the floor was billed `fine`; cash on hand covered `taken` of it.
signal driveby_billed(fine: int, taken: int)

## Seconds between two rounds of a drive-by.
const DRIVEBY_SHOT_INTERVAL := 0.15
## A worker whose chest is within this flat distance of the lane is in it (metres).
const DRIVEBY_WORKER_RADIUS := 0.45
## A tray whose centre is within this flat distance of the lane takes the round (metres).
const DRIVEBY_TRAY_RADIUS := 0.6
## The lane must pass between a worker's feet and the top of a standing body, with this margin (metres).
const DRIVEBY_BODY_MARGIN := 0.1
## A round goes through at most this many panes of glass.
const DRIVEBY_GLASS_PANES := 3
const SHOT_FLAG_BLOCKED := 1   # stopped by LAYER_WORLD before the end of the lane
const SHOT_FLAG_GLASS := 2     # it went through a pane of glass on the way
const SHOT_FLAG_FIRST := 4     # the first round down this lane this drive-by: the pane it comes through breaks
const TRACER_SEC := 0.26
const TRACER_THICKNESS := 0.06
## Seconds a tracer stays at full brightness before it fades (M14 visual pass: 3 cm lines gone in 0.16 s were invisible).
const TRACER_HOLD_SEC := 0.07
const TRACER_MAX := 12
## Slips: the speed is averaged over this window of synced positions; one slip per worker per SLIP_COOLDOWN_SEC.
const SLIP_WINDOW_SEC := 0.25
const SLIP_COOLDOWN_SEC := 3.0
## The slip speed sits this far from walk_speed towards sprint_speed (0.4: 5.5 m/s with 4.5 / 7.0).
const SLIP_SPEED_BLEND := 0.4
## A worker higher than this above the puddle is in the air (a jump clears it).
const SLIP_FLOOR_TOLERANCE := 0.3
## A step faster than this many times sprint_speed is a teleport or a sync snap, not a run.
const SLIP_TELEPORT_FACTOR := 2.5

## Host: simulated seconds since the session began (advanced by tick(), so tests can drive the slip cooldown).
var _mayhem_clock: float = 0.0
## Host: seconds until an emptied tank has pressure again (0 = it is not empty because of a leak).
var _leak_empty_left: float = 0.0
## Host: seconds until the puddle dries (counts only while the tank no longer leaks; 0 = no countdown).
var _puddle_left: float = 0.0
## Host: peer_id -> [last position, metres moved, seconds, void window, last step direction].
var _slip_track: Dictionary = {}
## Host: peer_id -> _mayhem_clock of the last slip.
var _last_slip: Dictionary = {}
## Host: gunfire seconds not yet turned into rounds.
var _shot_accum: float = 0.0
## Host: trays that already took their round this drive-by (instance id -> true).
var _driveby_trays_hit: Dictionary = {}
## Host: lanes that already carried a round this drive-by (lane index -> true).
var _driveby_lanes_used: Dictionary = {}
## Host: rounds fired this drive-by.
var _driveby_shots: int = 0
## Every peer: tracer meshes still fading.
var _tracers: Array[Node] = []


## The speed (m/s) above which a worker in the puddle slips: between walking and sprinting.
func get_slip_speed() -> float:
	var b: BalanceConfig = Config.balance
	return lerpf(b.walk_speed, maxf(b.sprint_speed, b.walk_speed), SLIP_SPEED_BLEND)


## Host: seconds until the emptied tank fills again (0 when it is not empty because of a leak).
func get_leak_empty_left() -> float:
	return _leak_empty_left


## Host: seconds until the puddle dries (0 when none is drying).
func get_puddle_left() -> float:
	return _puddle_left


## True while the drive-by's guns are going (false during its warning). Any peer.
func is_driveby_firing() -> bool:
	if active_event != EVENT_DRIVEBY:
		return false
	var total := float(_params.get("seconds", 0.0))
	return total - _time_left >= float(_params.get("warning", 0.0))


## Host: rounds fired in the running (or last) drive-by.
func get_driveby_shots() -> int:
	return _driveby_shots


## Host: fills `p` for a leak or a drive-by and returns its length in seconds (0 = it cannot start now).
func _mayhem_prepare(kind: StringName, p: Dictionary) -> float:
	var b: BalanceConfig = Config.balance
	if kind == EVENT_LEAK:
		var well := _well()
		# A tank that already leaks, has no pressure or stands empty has nothing to lose.
		if well == null or well.is_leaking() or not well.has_pressure() or _leak_empty_left > 0.0:
			return 0.0
		var leak_seconds := maxf(b.leak_sec, 1.0)
		p["seconds"] = leak_seconds
		return leak_seconds
	if kind == EVENT_DRIVEBY:
		var room := _room()
		if room == null or room.get_gunfire_lanes().is_empty():
			return 0.0
		var warning := maxf(b.driveby_warning_sec, 0.0)
		var seconds := warning + maxf(b.driveby_sec, 0.5)
		p["seconds"] = seconds
		p["warning"] = warning
		_shot_accum = 0.0
		_driveby_trays_hit.clear()
		_driveby_lanes_used.clear()
		_driveby_shots = 0
		return seconds
	return 0.0


# --- the leak ------------------------------------------------------------------------------------------------------

func _tick_leak(delta: float) -> void:
	_clock += delta
	if _time_left <= 0.0:
		_server_leak_ran_out()
		server_end_event()


## Host: nobody patched it. The tank is empty for leak_empty_sec; _mayhem_tick turns the pressure back on.
func _server_leak_ran_out() -> void:
	var well := _well()
	if well == null or not well.is_leaking():
		return
	well.server_set_leaking(false)
	well.server_set_pressure(false)
	_leak_empty_left = maxf(Config.balance.leak_empty_sec, 0.01)
	_rpc_leak_resolved.rpc(false, 0)


## SERVER ONLY. A worker's patch is on (Well.server_patch calls this after closing the hole): every peer hears who,
## the leak event ends, nothing is lost.
func server_leak_patched(by_peer: int) -> void:
	if not _is_host():
		return
	_rpc_leak_resolved.rpc(true, by_peer)
	if active_event == EVENT_LEAK:
		server_end_event()
	else:
		_server_stop_leak()


## Host: the hole is shut (whoever shut it) and the puddle starts to dry.
func _server_stop_leak() -> void:
	var well := _well()
	if well == null:
		return
	if well.is_leaking():
		well.server_set_leaking(false)
	if well.has_puddle():
		_puddle_left = maxf(Config.balance.puddle_sec, 0.01)


## Host, every tick whatever the event: the puddle spreads while the tank leaks and dries puddle_sec after, the
## emptied tank fills again, and workers running through the puddle slip.
func _mayhem_tick(delta: float) -> void:
	_mayhem_clock += delta
	var well := _well()
	if well == null:
		return
	if well.is_leaking():
		well.tick_puddle(delta)
	if _leak_empty_left > 0.0:
		_leak_empty_left -= delta
		if _leak_empty_left <= 0.0:
			_leak_empty_left = 0.0
			if not well.has_pressure():
				well.server_set_pressure(true)
				_rpc_tank_refilled.rpc()
	if _puddle_left > 0.0 and not well.is_leaking():
		_puddle_left -= delta
		if _puddle_left <= 0.0:
			_puddle_left = 0.0
			well.server_clear_puddle()
	if well.has_puddle() or is_floor_slick(): # M15 replay: the slick floor condition judges slips without a puddle
		_judge_slips(delta, well)
	elif not _slip_track.is_empty():
		_slip_track.clear()


## Host: movement is owner-authoritative, so the speed is judged from where each body is, tick after tick. A window of
## SLIP_WINDOW_SEC averages it (sync packets arrive in steps); a window with a jump or a teleport in it is void.
func _judge_slips(delta: float, well: Well) -> void:
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		return
	var b: BalanceConfig = Config.balance
	var limit := get_slip_speed()
	var too_fast := maxf(b.sprint_speed, b.walk_speed) * SLIP_TELEPORT_FACTOR
	var floor_y := well.get_puddle_center().y
	for player in w.get_players():
		var pid: int = player.peer_id
		if not player.is_inside_tree():
			continue
		var pos: Vector3 = player.global_position
		if not pos.is_finite():
			_slip_track.erase(pid)
			continue
		if not _slip_track.has(pid):
			_slip_track[pid] = [pos, 0.0, 0.0, false, Vector3.ZERO]
			continue
		var e: Array = _slip_track[pid]
		var last: Vector3 = e[0]
		var step := Vector3(pos.x - last.x, 0.0, pos.z - last.z)
		var moved := step.length()
		e[0] = pos
		e[1] = float(e[1]) + moved
		e[2] = float(e[2]) + delta
		if moved > 0.0001:
			e[4] = step / moved
		if pos.y - floor_y > SLIP_FLOOR_TOLERANCE or moved / delta > too_fast:
			e[3] = true
		if float(e[2]) < SLIP_WINDOW_SEC:
			continue
		var speed := float(e[1]) / float(e[2])
		var void_window := bool(e[3])
		e[1] = 0.0
		e[2] = 0.0
		e[3] = false
		if void_window or not (speed > limit):
			continue
		if player.crouching or GameState.is_in_backroom(pid) or not (well.is_in_puddle(pos) or is_floor_slick_at(pos)): # M15 replay: or anywhere on a slick floor
			continue
		if _last_slip.has(pid) and _mayhem_clock - float(_last_slip[pid]) < SLIP_COOLDOWN_SEC:
			continue
		if not player.can_be_staggered():
			continue
		_server_slip(player, e[4])


## Host: `player` goes down in the puddle, sliding on the way they ran; whatever they carried lands in front of them.
func _server_slip(player: Player, direction: Vector3) -> void:
	var pid: int = player.peer_id
	_last_slip[pid] = _mayhem_clock
	Player.server_stagger(player, direction, true, 0, maxf(Config.balance.slip_stun_sec, 0.0), false)
	GameState.server_add_stat(pid, Const.STAT_SLIPS)
	_rpc_worker_slipped.rpc(pid, player.global_position)


# --- the drive-by --------------------------------------------------------------------------------------------------

func _tick_driveby(delta: float) -> void:
	var warning := float(_params.get("warning", 0.0))
	var total := float(_params.get("seconds", warning))
	var before := _clock
	_clock += delta
	# The part of this step that lies inside the gunfire turns into rounds, DRIVEBY_SHOT_INTERVAL apart.
	var fire_from := maxf(before, warning)
	var fire_to := minf(_clock, total)
	if fire_to > fire_from:
		_shot_accum += fire_to - fire_from
		while _shot_accum >= DRIVEBY_SHOT_INTERVAL - 0.000001:
			_shot_accum -= DRIVEBY_SHOT_INTERVAL
			server_fire_random_lane()
			if active_event != EVENT_DRIVEBY:
				return
	if _time_left <= 0.0:
		_server_driveby_bill()
		server_end_event()


## SERVER ONLY. One round down a random Room.get_gunfire_lanes() lane (see server_fire_lane). {} without lanes.
func server_fire_random_lane() -> Dictionary:
	var room := _room()
	if not _is_host() or room == null:
		return {}
	var lanes: Array = room.get_gunfire_lanes()
	if lanes.is_empty():
		return {}
	var index := _rng.randi_range(0, lanes.size() - 1)
	var lane: Variant = lanes[index]
	if not (lane is Dictionary):
		return {}
	var first := not _driveby_lanes_used.has(index)
	_driveby_lanes_used[index] = true
	return server_fire_lane(lane, first)


## SERVER ONLY. One round down `lane` ({"from": Vector3, "to": Vector3}, global): cut at the first LAYER_WORLD hit;
## every worker in it who is not crouching, not in the back room and not stagger-immune goes down (twice hit_stun_sec,
## the held item released, STAT_SHOT); every growing tray in it loses driveby_tray_loss of stage progress, once per
## drive-by (a READY plant is not harmed); one cosmetic RPC for the tracer and the sounds. Distances are flat: the
## lane passes at chest height and a tray sits on the floor. A LAYER_WORLD collider that is glass (_is_glass: named
## "...glass..." or in the group "glass") does not stop the round; it goes on to the next hit. Returns {"end": Vector3,
## "blocked": bool, "glass": bool, "workers": Array of peer ids, "trays": Array of plot names}. Public for tests
## (tick() fires the drive-by's rounds).
func server_fire_lane(lane: Dictionary, first: bool = false) -> Dictionary:
	var out := {"end": Vector3.ZERO, "blocked": false, "glass": false, "workers": [], "trays": []}
	var w: World = Game.world
	if not _is_host() or w == null or not is_instance_valid(w) or not w.is_inside_tree():
		return out
	var from_v: Variant = lane.get("from")
	var to_v: Variant = lane.get("to")
	if not (from_v is Vector3) or not (to_v is Vector3):
		return out
	var from: Vector3 = from_v
	var end: Vector3 = to_v
	if not from.is_finite() or not end.is_finite():
		return out
	var flags := SHOT_FLAG_FIRST if first else 0
	var glass_at := from
	var space := w.get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(from, end, Const.LAYER_WORLD)
	var through: Array[RID] = []
	for pane in DRIVEBY_GLASS_PANES + 1:
		query.exclude = through
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			break
		if pane < DRIVEBY_GLASS_PANES and _is_glass(hit.get("collider") as Node):
			# A pane does not stop a round: it goes on (the first one it meets is where the glass sound plays).
			if not (flags & SHOT_FLAG_GLASS):
				glass_at = hit["position"]
			flags |= SHOT_FLAG_GLASS
			through.append(hit["rid"])
			continue
		end = hit["position"]
		flags |= SHOT_FLAG_BLOCKED
		out["blocked"] = true
		break
	out["end"] = end
	out["glass"] = (flags & SHOT_FLAG_GLASS) != 0
	var b: BalanceConfig = Config.balance
	var along := Vector3(end.x - from.x, 0.0, end.z - from.z)
	var workers: Array = out["workers"]
	for player in w.get_players():
		var pid: int = player.peer_id
		if not player.is_inside_tree() or GameState.is_in_backroom(pid) or player.crouching:
			continue
		if not player.can_be_staggered():
			continue   # already down, or just got up
		var chest := player.get_chest_position()
		var near := _lane_closest(from, end, chest)
		if not (Vector2(near.x - chest.x, near.z - chest.z).length() <= DRIVEBY_WORKER_RADIUS):
			continue
		var feet_y: float = player.global_position.y
		if near.y < feet_y - DRIVEBY_BODY_MARGIN or near.y > feet_y + Player.STAND_HEIGHT + DRIVEBY_BODY_MARGIN:
			continue   # the lane passes under the floor he stands on or over his head
		Player.server_stagger(player, along, true, 0, maxf(b.hit_stun_sec, 0.0) * 2.0, true)
		GameState.server_add_stat(pid, Const.STAT_SHOT)
		_rpc_worker_shot.rpc(pid)
		workers.append(pid)
	var trays: Array = out["trays"]
	for node in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var plot := node as GrowPlot
		if plot == null or not plot.is_inside_tree() or not plot.is_growing():
			continue
		var id := plot.get_instance_id()
		if _driveby_trays_hit.has(id):
			continue
		var centre: Vector3 = plot.global_position
		var near_tray := _lane_closest(from, end, centre)
		if not (Vector2(near_tray.x - centre.x, near_tray.z - centre.z).length() <= DRIVEBY_TRAY_RADIUS):
			continue
		_driveby_trays_hit[id] = true
		plot.stage_progress = maxf(plot.stage_progress - maxf(b.driveby_tray_loss, 0.0), 0.0)
		_rpc_tray_shot.rpc(String(plot.name), centre)
		trays.append(String(plot.name))
	_driveby_shots += 1
	_rpc_shot.rpc(from, end, flags, glass_at)
	return out


## The point of the segment `from`..`end` nearest to `point` on the floor plan (x / z); its y is the lane's height there.
static func _lane_closest(from: Vector3, end: Vector3, point: Vector3) -> Vector3:
	var ab := Vector2(end.x - from.x, end.z - from.z)
	var len2 := ab.length_squared()
	var t := 0.0
	if len2 > 0.000001:
		t = clampf(Vector2(point.x - from.x, point.z - from.z).dot(ab) / len2, 0.0, 1.0)
	return from.lerp(end, t)


## True when `node` or one of its near ancestors is glass: its name contains "glass", or it is in the group "glass".
## The level marks its panes this way; anything else on LAYER_WORLD stops a round.
static func _is_glass(node: Node) -> bool:
	var n := node
	for i in 3:
		if n == null:
			return false
		if n.is_in_group(&"glass") or String(n.name).to_lower().contains("glass"):
			return true
		n = n.get_parent()
	return false


## Host: the drive-by ran its course. The floor pays driveby_fine, as far as cash on hand goes.
func _server_driveby_bill() -> void:
	var fine := maxi(Config.balance.driveby_fine, 0)
	var taken := mini(fine, maxi(GameState.money, 0))
	if taken > 0:
		GameState.server_add_money(-taken)
	_rpc_driveby_billed.rpc(fine, taken)


## Where the cars are: the middle of the lanes' outer ends (Vector3.INF without lanes).
func _driveby_origin() -> Vector3:
	var room := _room()
	if room == null:
		return Vector3.INF
	var sum := Vector3.ZERO
	var count := 0
	for lane: Variant in room.get_gunfire_lanes():
		if lane is Dictionary and (lane as Dictionary).get("from") is Vector3:
			sum += (lane as Dictionary)["from"]
			count += 1
	return sum / float(count) if count > 0 else Vector3.INF


## Every peer, from _rpc_event_started: a drive-by announces itself with tyres outside. A late joiner who lands in
## the gunfire hears no tyres.
func _mayhem_on_started(kind: StringName, params: Dictionary, seconds_left: float) -> void:
	if kind != EVENT_DRIVEBY:
		return
	var total := float(params.get("seconds", seconds_left))
	if total - seconds_left >= float(params.get("warning", 0.0)):
		return
	var origin := _driveby_origin()
	if origin.is_finite():
		Sfx.play(&"tires", origin)
	else:
		Sfx.play(&"tires")


# --- every peer ----------------------------------------------------------------------------------------------------

@rpc("authority", "call_local", "reliable")
func _rpc_leak_resolved(patched: bool, by_peer: int) -> void:
	leak_resolved.emit(patched, by_peer)


@rpc("authority", "call_local", "reliable")
func _rpc_tank_refilled() -> void:
	var well := _well()
	if well != null and well.is_inside_tree():
		Sfx.play(&"refill", well.global_position + Vector3.UP * 0.6)
	tank_refilled.emit()


@rpc("authority", "call_local", "reliable")
func _rpc_worker_slipped(peer_id: int, position: Vector3) -> void:
	if position.is_finite() and _room() != null:
		var local := multiplayer.has_multiplayer_peer() and peer_id == multiplayer.get_unique_id()
		if local:
			Sfx.play(&"slip")
		else:
			Sfx.play(&"slip", position + Vector3.UP * 0.2)
		GrowPlot.juice_fx(&"splash", position + Vector3.UP * 0.05, Toon.WATER, 10)
	worker_slipped.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_worker_shot(peer_id: int) -> void:
	worker_shot.emit(peer_id)


@rpc("authority", "call_local", "reliable")
func _rpc_tray_shot(plot_name: String, position: Vector3) -> void:
	if position.is_finite() and _room() != null:
		GrowPlot.juice_fx(&"burst", position + Vector3.UP * 0.6, Toon.LEAF, 8)
	tray_shot.emit(plot_name)


@rpc("authority", "call_local", "reliable")
func _rpc_driveby_billed(fine: int, taken: int) -> void:
	driveby_billed.emit(fine, taken)


## Cosmetic, every peer: the tracer and the sounds of one round. Unreliable on purpose (forty of them in six seconds;
## a lost one is a shot nobody saw).
## The first round down a lane breaks the pane it comes through (`glass_shot` at the pane when the level has one,
## at the lane's start otherwise); every round ends in a `ricochet` where it stops.
@rpc("authority", "call_local", "unreliable")
func _rpc_shot(from: Vector3, to: Vector3, flags: int, glass_at: Vector3) -> void:
	# A peer still loading the floor (a late joiner in the middle of a drive-by) has nothing to draw it on.
	if not from.is_finite() or not to.is_finite() or _room() == null:
		return
	Sfx.play(&"gunshot", from)
	if flags & SHOT_FLAG_FIRST:
		Sfx.play(&"glass_shot", glass_at if (flags & SHOT_FLAG_GLASS) and glass_at.is_finite() else from)
	Sfx.play(&"ricochet", to)
	GrowPlot.juice_fx(&"puff", to, Toon.PEBBLE, 4)
	_spawn_tracer(from, to)
	_spawn_shot_fx(from, to)
	shot_fired.emit(from, to)


## A thin pale line from `from` to `to` that fades in TRACER_SEC (a plain child of the Room; at most TRACER_MAX alive).
func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var room := _room()
	if room == null or not room.is_inside_tree():
		return
	var length := from.distance_to(to)
	if not (length > 0.05):
		return
	var alive: Array[Node] = []
	for t in _tracers:
		if is_instance_valid(t) and not t.is_queued_for_deletion():
			alive.append(t)
	_tracers = alive
	while _tracers.size() >= TRACER_MAX:
		var old: Node = _tracers.pop_front()
		old.queue_free()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(Toon.lighter(Toon.SUNSHINE, 0.5), 1.0)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(TRACER_THICKNESS, TRACER_THICKNESS, length)
	mesh.material = mat
	var tracer := MeshInstance3D.new()
	tracer.name = "Tracer"
	tracer.mesh = mesh
	tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	room.add_child(tracer)
	var dir := (to - from) / length
	var up := Vector3.UP if absf(dir.y) < 0.99 else Vector3.RIGHT
	tracer.global_transform = Transform3D(Basis.looking_at(dir, up), (from + to) * 0.5)
	_tracers.append(tracer)
	var tw := tracer.create_tween()
	tw.tween_interval(TRACER_HOLD_SEC)
	tw.tween_property(mat, ^"albedo_color:a", 0.0, TRACER_SEC)
	tw.tween_callback(tracer.queue_free)


## M14 lead (visual pass): a muzzle flash where the round comes from and a dark pock where it stops, so the gunfire
## reads in a still frame and leaves marks for a while. Plain children of the Room, capped; cosmetic only.
const FLASH_SEC := 0.09
const POCK_SEC := 25.0
const POCK_MAX := 36
var _pocks: Array[Node] = []

func _spawn_shot_fx(from: Vector3, to: Vector3) -> void:
	var room := _room()
	if room == null or not room.is_inside_tree():
		return
	var flash := OmniLight3D.new()
	flash.light_color = Toon.lighter(Toon.SUNSHINE, 0.2)
	flash.light_energy = 2.4
	flash.omni_range = 5.0
	flash.shadow_enabled = false
	room.add_child(flash)
	flash.global_position = from
	var ft := flash.create_tween()
	ft.tween_property(flash, ^"light_energy", 0.0, FLASH_SEC)
	ft.tween_callback(flash.queue_free)
	var alive: Array[Node] = []
	for p in _pocks:
		if is_instance_valid(p) and not p.is_queued_for_deletion():
			alive.append(p)
	_pocks = alive
	while _pocks.size() >= POCK_MAX:
		var old: Node = _pocks.pop_front()
		old.queue_free()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Toon.darker(Toon.PEBBLE, 0.75)
	var mesh := SphereMesh.new()
	mesh.radius = 0.07
	mesh.height = 0.14
	mesh.radial_segments = 8
	mesh.rings = 4
	mesh.material = mat
	var pock := MeshInstance3D.new()
	pock.name = "Pock"
	pock.mesh = mesh
	pock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	room.add_child(pock)
	pock.global_position = to
	_pocks.append(pock)
	# A tween on the pock itself: it dies with the node (a scene-tree timer with the node captured in a lambda logged
	# "Lambda capture was freed" whenever the floor was reset before the 25 s were up).
	var pt := pock.create_tween()
	pt.tween_interval(POCK_SEC)
	pt.tween_callback(pock.queue_free)


# --- resets --------------------------------------------------------------------------------------------------------

## Host (shift end, game reset): no leak, no puddle, no plate, no empty-tank timer, nobody tracked. The pressure
## itself is restored by _server_restore_stations right after.
func _mayhem_server_reset() -> void:
	_leak_empty_left = 0.0
	_puddle_left = 0.0
	_slip_track.clear()
	_last_slip.clear()
	_shot_accum = 0.0
	_driveby_trays_hit.clear()
	_driveby_lanes_used.clear()
	var well := _well()
	if well != null:
		well.server_reset_leak()


## Any peer, back to the menu: forget it all (the world, the Well and the tracers go with the scene).
func _mayhem_reset_local() -> void:
	_mayhem_clock = 0.0
	_leak_empty_left = 0.0
	_puddle_left = 0.0
	_slip_track.clear()
	_last_slip.clear()
	_shot_accum = 0.0
	_driveby_trays_hit.clear()
	_driveby_lanes_used.clear()
	_driveby_shots = 0
	for t in _tracers:
		if is_instance_valid(t):
			t.queue_free()
	_tracers.clear()


# ------------------------------------------------------------------------------------------------------
# --- M15 replay: shift conditions in the scheduler and the slip judge ---------------------------------
# ------------------------------------------------------------------------------------------------------
# GameState owns the conditions (CONTRACTS "M15", "Replay"); this file reads them through one-line hooks tagged
# "# M15 replay": the picker's weights (get_weight), the gap and the first delay (GameState.get_event_gap_factor),
# the length of a power cut (`power_cut_sec`), the shortage's strain (never one that is not sold yet) and the slip
# judge (`floor_wet`). With replay off every one of them multiplies by 1.0 or is false.

## The scheduler's weight of `kind` right now: WEIGHTS x the active conditions' `event_weight:<kind>` (looked up by
## the kind's name, so it works for every kind in WEIGHTS, whoever added it). 0 for an unknown kind.
func get_weight(kind: StringName) -> int:
	var base := int(WEIGHTS.get(kind, 0))
	if base <= 0:
		return 0
	return maxi(int(round(float(base) * GameState.condition_value(StringName("event_weight:%s" % kind), 1.0))), 0)


## True while the "slick floor" condition makes the whole floor wet: a running shift with `floor_wet` above 0. The
## slip judge then runs without a puddle and counts every point of the floor plan as wet.
func is_floor_slick() -> bool:
	return GameState.is_playing() and GameState.condition_value(&"floor_wet", 0.0) > 0.0


## True when `pos` is wet because of the slick floor (anywhere on the floor plan; the alley is not the floor).
func is_floor_slick_at(pos: Vector3) -> bool:
	if not is_floor_slick():
		return false
	var room := _room()
	return room != null and room.contains_point(pos)
