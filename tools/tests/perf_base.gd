extends "res://tools/tests/qa_base.gd"
## M22 perf (perf agent; CONTRACTS.md "M22", "Performance"): the staging shared by the perf suite (perf_body.gd) and the
## windowed benchmark (perf_shots_body.gd). A host with four workers on a busy floor of the chill game (`--chill
## --replay --run=B5VP`): me + Bob, Cara and Dan (host-side bodies without an owning peer, as the suites spawn them), or
## in the network pass me + one real client process + Cara and Dan. Its worst moments are started by stage() and kept
## going by drive() every frame while they are measured:
##   idle        every tray growing, the workers standing about holding things (the reference)
##   sprinklers  the sprinklers' water (a CPUParticles3D per play area) and their loop
##   driveby     the drive-by's gunfire after its warning (rounds, tracers, flashes, pocks, broken glass)
##   hostile     a hostile plant chasing Dan, who keeps walking a circle in the main room
##   spores      a Black Damp cloud over GrowPlot3, Cara and Dan fogged in it, coughing
##   radios      the radio talker (Bob; the host itself in the network pass) talks into radio A, radio B on the shelf
##               carries it (voice frames at 50 a second: injected into the receive path for a fake worker, through the
##               real send path for the host)
##   voices      the voice talkers talk at once (Bob, Cara and Dan: three voice emitters; the host in the network pass)
##   report      the end of a paid shift: the overlay and the shift report open (the frame it opens on counts)
## FrameProbe times every real frame on this peer: physics (from the physics_frame signal to the process step, so the
## physics server's own step and the network poll are in it) + process (from the process_frame signal to a tween
## callback the probe queues from the last _process of the frame: every node's _process, the deferred calls, the
## timers and the tweens are in it). It also keeps the engine's own monitors (TIME_PROCESS + TIME_PHYSICS_PROCESS: the
## worst step of the last whole second, so the first reading of a window can still cover the second before it).

const BOB := 2
const CARA := 3
const DAN := 4
const NAMES: Dictionary = {BOB: "Bob", CARA: "Cara", DAN: "Dan"}
const MOMENTS: Array[StringName] = [&"idle", &"sprinklers", &"driveby", &"hostile", &"spores", &"radios", &"voices", &"report"]
## Where everybody stands on the busy floor (main room and the trays; cover layout 0, which --run=B5VP picks).
const SPOT_ME := Vector3(-1.0, 0.02, 0.9)
const SPOTS: Dictionary = {BOB: Vector3(-6.0, 0.05, 4.0), CARA: Vector3(3.6, 0.05, -1.5), DAN: Vector3(3.6, 0.05, 1.5)}
## The hostile plant: Dan walks a circle round this point, the plant starts outside it.
const CHASE_CENTRE := Vector3(-3.0, 0.05, 0.5)
const CHASE_RADIUS := 2.6
const CHASE_SPEED := 1.4 # rad/s: about 3.6 m/s round the circle, faster than the plant
## The spore cloud's tray (Cara and Dan stand next to it).
const SPORE_PLOT := 3
const DAMP: StringName = &"damp"
const VOICE_FRAME_MS := 20
const VOICE_BANK := 8

var world: World
var items: ItemManager
var room: Room
var me: Player
var hud: HUD
## Fake workers by peer id (Player nodes on the host).
var fakes: Dictionary = {}
var probe: FrameProbe
var radios: Array[Radio] = []
var current: StringName = &""
## Who talks into radio A, and who talks in the voices moment (1 = the host: the real send path).
var radio_talker: int = BOB
var voice_talkers: Array[int] = [BOB, CARA, DAN]
var _talkers: Array[int] = []
var _talk_start_ms: int = 0
var _talk_sent: Dictionary = {}       # peer -> frames sent this moment
var _voice_bank: Array[PackedByteArray] = []
var _chase_angle: float = 0.0
var _hostile_id: int = 0



## One main-loop iteration's cost on this peer, frame by frame (see the header).
class FrameProbe extends Node:
	var frames: PackedInt32Array = []   # usec: physics + process of one iteration
	var proc: PackedInt32Array = []
	var nodes: PackedInt32Array = []   # usec of proc spent up to the last node's _process (the rest: deferred calls, timers, tweens)
	var phys: PackedInt32Array = []
	var mon_proc_max: float = 0.0       # seconds: the worst TIME_PROCESS seen while recording
	var mon_phys_max: float = 0.0
	var recording: bool = false
	var _phys_start: int = -1
	var _phys_acc: int = 0
	var _proc_start: int = -1
	var _nodes_end: int = -1

	func _init() -> void:
		name = "PerfProbe"
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_priority = 1 << 30
		process_physics_priority = 1 << 30

	func _ready() -> void:
		get_tree().physics_frame.connect(_on_physics_frame)
		get_tree().process_frame.connect(_on_process_frame)

	func begin() -> void:
		frames.clear()
		proc.clear()
		nodes.clear()
		phys.clear()
		mon_proc_max = 0.0
		mon_phys_max = 0.0
		recording = true

	func end() -> Dictionary:
		recording = false
		var out := summarize(frames, proc, phys, mon_proc_max, mon_phys_max)
		out["worst"] = worst(3)
		return out

	## The `k` slowest frames of the last recording: "#index total ms (nodes / rest of process / physics)".
	func worst(k: int) -> String:
		var order: Array = range(frames.size())
		order.sort_custom(func(a: int, b: int) -> bool: return frames[a] > frames[b])
		var parts: PackedStringArray = []
		for j in mini(k, order.size()):
			var i: int = order[j]
			parts.append("#%d %.2f (%.2f / %.2f / %.2f)" % [i, frames[i] / 1000.0, nodes[i] / 1000.0, (proc[i] - nodes[i]) / 1000.0, phys[i] / 1000.0])
		return ", ".join(parts)

	func _on_physics_frame() -> void:
		var now := Time.get_ticks_usec()
		if _phys_start >= 0:
			_phys_acc += now - _phys_start # two physics steps in one iteration: the first one ends here
		_phys_start = now

	func _on_process_frame() -> void:
		var now := Time.get_ticks_usec()
		if _phys_start >= 0:
			_phys_acc += now - _phys_start
			_phys_start = -1
		_proc_start = now

	func _process(_delta: float) -> void:
		_nodes_end = Time.get_ticks_usec()
		# Timers and tweens run after every _process and the deferred flush: a tween made now is the last of them.
		create_tween().tween_callback(_end_of_frame)

	func _end_of_frame() -> void:
		if _proc_start < 0:
			return
		var p := Time.get_ticks_usec() - _proc_start
		if recording:
			proc.append(p)
			nodes.append(_nodes_end - _proc_start if _nodes_end >= _proc_start else p)
			phys.append(_phys_acc)
			frames.append(p + _phys_acc)
			mon_proc_max = maxf(mon_proc_max, Performance.get_monitor(Performance.TIME_PROCESS))
			mon_phys_max = maxf(mon_phys_max, Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
		_proc_start = -1
		_phys_acc = 0

	## {n, mean, p95, max (ms of frame), proc_mean, phys_mean, proc_max, phys_max, mon_ms (worst process + physics step
	## the engine reported)}.
	static func summarize(f: PackedInt32Array, p: PackedInt32Array, ph: PackedInt32Array, mp: float, mph: float) -> Dictionary:
		var out := {"n": f.size(), "mean": 0.0, "p95": 0.0, "max": 0.0, "proc_mean": 0.0, "phys_mean": 0.0,
				"proc_max": 0.0, "phys_max": 0.0, "mon_ms": (mp + mph) * 1000.0}
		if f.is_empty():
			return out
		var sorted := f.duplicate()
		sorted.sort()
		var total := 0
		for v in f:
			total += v
		var tp := 0
		var tph := 0
		var mxp := 0
		var mxph := 0
		for i in f.size():
			tp += p[i]
			tph += ph[i]
			mxp = maxi(mxp, p[i])
			mxph = maxi(mxph, ph[i])
		out["mean"] = float(total) / f.size() / 1000.0
		out["p95"] = float(sorted[clampi(ceili(0.95 * sorted.size()) - 1, 0, sorted.size() - 1)]) / 1000.0
		out["max"] = float(sorted[sorted.size() - 1]) / 1000.0
		out["proc_mean"] = float(tp) / f.size() / 1000.0
		out["phys_mean"] = float(tph) / f.size() / 1000.0
		out["proc_max"] = float(mxp) / 1000.0
		out["phys_max"] = float(mxph) / 1000.0
		return out


# --- the host and the busy floor ---------------------------------------------------------------------------------------

## Hosts on `port` with the fake workers `fake_ids`, calls `on_hosted` once the world is up (the caller starts its
## client processes there), waits for `clients` real client players, starts the first shift and fills the floor. False
## when anything is missing.
func host_floor(port: int, fake_ids: Array[int], clients: int = 0, client_wait_sec: float = 30.0, on_hosted: Callable = Callable()) -> bool:
	var b: BalanceConfig = Config.balance
	for s: SeedDef in b.seeds:
		s.mutation_chance = 0.0 # no plant gets up and walks unless a moment asks for one
	b.end_round_on_quota_met = false
	step("hosting: me + %d fake worker(s) + %d client(s)" % [fake_ids.size(), clients])
	Game.start_host("Tester", port)
	if not await wait_until(func() -> bool: return Game.world != null and Game.local_player != null, 8.0, "world + local player"):
		return false
	world = Game.world
	items = world.items
	room = world.room
	me = Game.local_player
	hud = world.get_node_or_null(^"HUD") as HUD
	if on_hosted.is_valid():
		on_hosted.call()
	fakes.clear()
	for id in fake_ids:
		Net.players[id] = {"name": String(NAMES.get(id, "Worker %d" % id)), "color": Net.PALETTE[(id - 1) % Net.PALETTE.size()]}
		fakes[id] = world.server_spawn_player(id)
	Net.players_changed.emit()
	await wait_frames(3)
	if not check(not fakes.values().has(null) and hud != null, "%d fake worker(s) spawned, a HUD" % fake_ids.size()):
		return false
	if clients > 0 and not await wait_until(func() -> bool: return world.get_players().size() == 1 + fake_ids.size() + clients,
			client_wait_sec, "%d client player(s) in the world" % clients):
		return false
	GameState.request_start_round()
	if not await wait_until(func() -> bool: return GameState.is_playing(), 4.0, "the first shift runs"):
		return false
	GameState.server_add_money(2000)
	await wait_frames(2)
	radios.clear()
	for it in items.get_items_of_type(Const.ITEM_RADIO):
		if it is Radio:
			radios.append(it as Radio)
	busy_floor()
	await wait_frames(3)
	_make_voice_bank()
	if probe == null:
		probe = FrameProbe.new()
		get_tree().root.add_child(probe)
	return check(radios.size() == 2 and world.get_players().size() == 4, "four workers on a busy floor: every tray growing, things in hands, two radios on the shelf")


## Every tray growing (a strain each, watered), a can and a bundle in fake hands, everybody at their spot.
func busy_floor() -> void:
	var seeds: Array = Config.balance.seeds
	var plots := grow_plots()
	for i in plots.size():
		var p := plots[i]
		p.server_reset()
		p.server_plant((seeds[i % seeds.size()] as SeedDef).id)
		p.water = 1.0
		p.stage_progress = 0.3
	var can_holder := BOB if fakes.has(BOB) else DAN
	if fakes.has(can_holder) and items.get_held_by(can_holder) == null:
		items.server_spawn_item(Const.ITEM_WATERING_CAN, {}, SPOTS[can_holder], can_holder)
	if fakes.has(CARA) and items.get_held_by(CARA) == null:
		items.server_spawn_item(Const.ITEM_PRODUCT, {"strain_id": &"budget", "amount": 2}, SPOTS[CARA], CARA)
	park()


func park() -> void:
	for id: int in fakes:
		put(fakes[id], SPOTS[id])
		(fakes[id] as Player).crouching = false
	put_me(SPOT_ME, 0.0)


func grow_plots() -> Array[GrowPlot]:
	var out: Array[GrowPlot] = []
	for s in room.get_stations():
		if s is GrowPlot:
			out.append(s as GrowPlot)
	return out


## A fake (unowned) worker: place_at writes the synced net_position too, so remote smoothing keeps him there.
func put(p: Player, pos: Vector3) -> void:
	p.place_at(Transform3D(Basis.IDENTITY, Vector3(pos.x, 0.05, pos.z)))


func put_me(pos: Vector3, yaw: float) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	me.rotation.y = yaw


# --- the moments -------------------------------------------------------------------------------------------------------

## Starts `moment` on the host (from the normal floor). False when it could not start.
func stage(moment: StringName) -> bool:
	current = moment
	_talkers.clear()
	_talk_sent.clear()
	_talk_start_ms = Time.get_ticks_msec()
	match moment:
		&"idle":
			return true
		&"sprinklers":
			return Events.server_start_event(Events.EVENT_SPRINKLERS)
		&"driveby":
			if not Events.server_start_event(Events.EVENT_DRIVEBY):
				return false
			# The warning first (nothing fires); the moment is the gunfire.
			var warn_ms := int(Config.balance.driveby_warning_sec * 1000.0) + 150
			var t0 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t0 < warn_ms:
				await get_tree().process_frame
			return Events.is_driveby_firing()
		&"hostile":
			if not fakes.has(DAN):
				return false
			_chase_angle = 0.0
			put(fakes[DAN], _chase_point(0.0))
			_hostile_id = Hostiles.server_spawn(&"budget", CHASE_CENTRE + Vector3(-CHASE_RADIUS - 1.6, 0.0, 0.0))
			if _hostile_id == 0:
				return false
			# It roots where it stands for ROOT_SEC; the moment is the chase.
			var t1 := Time.get_ticks_msec()
			while Time.get_ticks_msec() - t1 < 6000:
				drive()
				await get_tree().process_frame
				var h := Hostiles.get_hostile(_hostile_id) as HostilePlant
				if h != null and h.state == HostilePlant.State.CHASE:
					return true
			return false
		&"spores":
			if not fakes.has(CARA) or not fakes.has(DAN):
				return false
			var p := plot(SPORE_PLOT)
			p.server_reset()
			p.server_plant(DAMP)
			p.water = 1.0
			p.stage = GrowPlot.Stage.READY
			put(fakes[CARA], p.global_position + Vector3(-1.2, 0.0, -0.6))
			put(fakes[DAN], p.global_position + Vector3(-1.2, 0.0, 0.6))
			await get_tree().process_frame
			var sp := Spores.get_instance()
			return sp != null and sp.server_puff(p, Spores.CAUSE_HARVEST)
		&"radios":
			if radios.size() < 2:
				return false
			var held := items.get_held_by(radio_talker)
			if held != null:
				items.server_despawn_item(held)
			await get_tree().process_frame
			if not items.server_give_item(radios[0], radio_talker):
				return false
			await get_tree().process_frame
			_talkers = [radio_talker]
			_talk_start_ms = Time.get_ticks_msec()
			drive()
			return Voice.is_on_radio(radio_talker)
		&"voices":
			_talkers = voice_talkers.duplicate()
			_talk_start_ms = Time.get_ticks_msec()
			drive()
			for peer in _talkers:
				if peer != multiplayer.get_unique_id() and Voice.get_output_node(peer) == null:
					return false
			return true
		&"report":
			GameState.server_add_sale(maxi(GameState.quota - GameState.round_sales, 0) + 10, CARA if fakes.has(CARA) else 1)
			GameState.time_left = 0.05 # the host's own countdown ends the shift on its next frame
			return true
	return false


## Called once per frame while a moment runs: the talkers' frames, Dan's walk.
func drive() -> void:
	if not _talkers.is_empty():
		var due := int((Time.get_ticks_msec() - _talk_start_ms) / VOICE_FRAME_MS) + 1
		var me_id := multiplayer.get_unique_id()
		for peer in _talkers:
			var sent := int(_talk_sent.get(peer, 0))
			while sent < due:
				var frame: PackedByteArray = _voice_bank[(sent + peer) % _voice_bank.size()]
				if peer == me_id:
					Voice.debug_send_frame(frame) # the real send path: to every peer (and the host's radio)
				else:
					Voice.debug_inject_frame(peer, frame) # as if it had arrived from that worker
				sent += 1
			_talk_sent[peer] = sent
	if current == &"hostile" and fakes.has(DAN):
		_chase_angle += CHASE_SPEED * get_process_delta_time()
		put(fakes[DAN], _chase_point(_chase_angle))


## True while `moment` is still going.
func is_live(moment: StringName) -> bool:
	match moment:
		&"sprinklers":
			return Events.is_event_active(Events.EVENT_SPRINKLERS)
		&"driveby":
			return Events.is_driveby_firing()
		&"hostile":
			return Hostiles.get_hostile(_hostile_id) != null
		&"spores":
			var sp := Spores.get_instance()
			return sp != null and sp.get_cloud_count() > 0
		&"radios":
			return Voice.is_on_radio(radio_talker)
		&"report":
			return GameState.is_round_over()
	return true


## Ends `moment` and puts the floor back (the report is the last one: it ends the shift).
func unstage(moment: StringName) -> void:
	_talkers.clear()
	match moment:
		&"sprinklers", &"driveby":
			if Events.is_event_active():
				Events.server_end_event()
		&"hostile":
			Hostiles.server_despawn_all()
		&"spores":
			var sp := Spores.get_instance()
			if sp != null:
				sp.server_clear()
			var p := plot(SPORE_PLOT)
			p.server_reset()
			p.server_plant(&"budget")
			p.water = 1.0
		&"radios":
			if radios.size() > 0 and radios[0].holder_id == radio_talker:
				var at: Vector3 = SPOTS.get(radio_talker, SPOT_ME)
				items.server_drop_item(radios[0], at + Vector3(0.6, 0.0, 0.0))
	current = &""
	park()


func hold(seconds: float) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		drive()
		await get_tree().process_frame


## Records `seconds` of frames while `moment` runs (it is driven every frame). The probe's summary plus "live": the
## share of frames the moment was still going.
func measure(moment: StringName, seconds: float) -> Dictionary:
	var live := 0
	var total := 0
	probe.begin()
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < seconds * 1000.0:
		drive()
		await get_tree().process_frame
		total += 1
		if is_live(moment):
			live += 1
	var out := probe.end()
	out["live"] = float(live) / maxf(float(total), 1.0)
	return out


func _chase_point(angle: float) -> Vector3:
	return CHASE_CENTRE + Vector3(cos(angle), 0.0, sin(angle)) * CHASE_RADIUS


func _make_voice_bank() -> void:
	if not _voice_bank.is_empty():
		return
	var VoiceScript: GDScript = load("res://scripts/core/voice.gd")
	var n: int = VoiceScript.FRAME_SAMPLES
	var rate := float(VoiceScript.SAMPLE_RATE)
	for k in VOICE_BANK:
		var s := PackedFloat32Array()
		s.resize(n)
		for i in n:
			s[i] = 0.35 * sin(TAU * 180.0 * float(i + k * n) / rate) + 0.1 * sin(TAU * 410.0 * float(i + k * n) / rate)
		_voice_bank.append(VoiceScript.encode_mulaw(s))


## "  name         mean   p95   max  | proc  phys | engine" lines for a table of {moment: summary}.
static func table(rows: Dictionary) -> String:
	var lines: PackedStringArray = ["  %-11s %6s %6s %6s | %6s %6s | %7s %6s %4s" % ["moment", "mean", "p95", "max", "proc", "phys", "engine", "live", "n"]]
	for k: Variant in rows:
		var r: Dictionary = rows[k]
		lines.append("  %-11s %6.2f %6.2f %6.2f | %6.2f %6.2f | %7.2f %5.0f%% %4d" % [String(k), r["mean"], r["p95"], r["max"],
				r["proc_mean"], r["phys_mean"], r["mon_ms"], float(r.get("live", 1.0)) * 100.0, r["n"]])
	return "\n".join(lines)
