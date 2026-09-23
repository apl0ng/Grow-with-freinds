extends Node
## Host and client halves of the GrowPlot replication test. Run through farm_net_test.gd.
## Both processes build /root/FarmNet/PlotA..PlotC (same paths -> path-based sync of the plots' static
## MultiplayerSynchronizer). The host sets state, then asks the client over RPC to wait until its copies match
## an expectation (synced values + client-side visuals) and report back. The client also watches every frame
## for a running wilt crossfade: the state a late joiner receives must appear instantly (no blend), while a
## live change after the sync has settled must blend.

## Emitted once with the number of failed checks.
signal finished(failures: int)

const PLOT_SCENE := "res://scenes/stations/grow_plot.tscn"
const STEP_TIMEOUT := 6.0
const GROWTH_OVERRIDE := 30.0
const PLOT_NAMES: Array[String] = ["PlotA", "PlotB", "PlotC"]
## Longer than GrowPlot.FX_SETTLE_MSEC: after it, a client animates live changes again.
const SETTLE_WAIT := 0.8

var _is_client := false
var _port := 0
var _client_pid := -1
var _client_peer := 0
var _passed := 0
var _failed := 0
var _plots: Dictionary = {}     # name -> GrowPlot
var _results: Dictionary = {}   # step -> [ok: bool, detail: String]
var _hello := false
var _done := false
var _blend_seen: Dictionary = {}   # client: plot name -> true once its PlantVisual was seen crossfading

func run() -> void:
	var args := Config.parse_user_args()
	_is_client = str(args.get("role", "host")) == "client"
	_port = int(args.get("port", 0))
	GameState.phase = GameState.Phase.MENU
	Config.growth_speed_override = GROWTH_OVERRIDE
	for i in PLOT_NAMES.size():
		var plot := (load(PLOT_SCENE) as PackedScene).instantiate() as GrowPlot
		plot.name = PLOT_NAMES[i]
		plot.position = Vector3(2.0 * i, 0.0, 0.0)
		add_child(plot)
		_plots[PLOT_NAMES[i]] = plot
	await get_tree().process_frame
	if _is_client:
		await _run_client()
	else:
		await _run_host()

# ------------------------------------------------------------------------------------------------ host

func _run_host() -> void:
	Net.is_host = true
	var peer := ENetMultiplayerPeer.new()
	var err := ERR_CANT_CREATE
	for attempt in 5:
		_port = 20000 + randi() % 20000
		err = peer.create_server(_port, 4)
		if err == OK:
			break
	if err != OK:
		_check(false, "host: create ENet server", error_string(err))
		return _finish()
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(func(id: int) -> void: _client_peer = id)

	# State that exists BEFORE the client joins (tests the late-join initial sync). Phase MENU: frozen.
	var a: GrowPlot = _plots["PlotA"]
	var b: GrowPlot = _plots["PlotB"]
	var c: GrowPlot = _plots["PlotC"]
	a.server_plant(&"purple")
	a.stage = GrowPlot.Stage.FLOWERING
	a.stage_progress = 0.4
	a.water = 0.8
	c.server_plant(&"golden")   # thirsty: wilted when the client joins
	c.stage = GrowPlot.Stage.VEGETATIVE

	var exe := OS.get_executable_path()
	var cargs := PackedStringArray(["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tools/tests/farm_net_test.gd", "--", "--role=client", "--port=%d" % _port])
	_client_pid = OS.create_process(exe, cargs)
	_check(_client_pid > 0, "host: launched client process")
	if _client_pid <= 0:
		return _finish()
	if not await _wait(func() -> bool: return _hello and _client_peer != 0, 25.0):
		_check(false, "client connected and said hello")
		return _finish()
	_check(true, "client connected and said hello")

	await _step(1, "late joiner receives the full plot state + visuals, instantly (no wilt blend)", {
		"PlotA": {"stage": GrowPlot.Stage.FLOWERING, "strain_id": "purple", "water": 0.8, "stage_progress": 0.4,
			"visual_stage": 3, "tint": "purple", "dry_indicator": false, "tag": true, "synced": true,
			"wilt": "healthy", "no_blend": true},
		"PlotB": {"stage": GrowPlot.Stage.EMPTY, "strain_id": "", "water": 0.0, "visual_stage": 0, "tag": false},
		"PlotC": {"stage": GrowPlot.Stage.VEGETATIVE, "strain_id": "golden", "water": 0.0, "visual_stage": 2,
			"tint": "golden", "dry_indicator": true, "tag": true, "wilt": "wilted", "no_blend": true},
	})
	b.server_plant(&"budget")
	await _step(2, "planting replicates (ON_CHANGE) with the DRY indicator", {
		"PlotB": {"stage": GrowPlot.Stage.SEEDLING, "strain_id": "budget", "visual_stage": 1, "dry_indicator": true, "tag": true},
	})
	b.server_water(1.0)
	await _step(3, "watering replicates (ALWAYS, 0.1 s) and clears the DRY indicator", {
		"PlotB": {"water": 1.0, "water_tol": 0.02, "dry_indicator": false},
	})
	await get_tree().create_timer(SETTLE_WAIT).timeout
	c.server_water(1.0)
	await _step(4, "a live watering after the sync settled crossfades on the client, ending healthy", {
		"PlotC": {"water": minf(1.0, Config.balance.water_per_charge), "water_tol": 0.02, "dry_indicator": false,
			"blend_seen": true, "wilt": "healthy"},
	})
	GameState.phase = GameState.Phase.PLAYING
	await _step(5, "host-only growth ticks reach READY on the client (READY model, tint)", {
		"PlotA": {"stage": GrowPlot.Stage.READY, "visual_stage": 4, "tint": "purple"},
		"PlotB": {"stage_min": GrowPlot.Stage.VEGETATIVE},
	}, 15.0)
	GameState.phase = GameState.Phase.MENU
	await get_tree().create_timer(0.4).timeout
	await _step(6, "drained water + progress mirror the (frozen) host exactly", {
		"PlotB": {"stage": b.stage, "water": b.water, "water_tol": 0.0005, "stage_progress": b.stage_progress},
	})
	a.stage_progress = 0.0
	a.stage = GrowPlot.Stage.EMPTY
	a.strain_id = &""
	await _step(7, "reset to EMPTY replicates and hides plant + tag", {
		"PlotA": {"stage": GrowPlot.Stage.EMPTY, "strain_id": "", "visual_stage": 0, "tag": false},
	})

	_rpc_bye.rpc_id(_client_peer)
	await _wait(func() -> bool: return not OS.is_process_running(_client_pid), 5.0)
	if OS.is_process_running(_client_pid):
		OS.kill(_client_pid)
	_finish()

func _step(step: int, what: String, expect: Dictionary, timeout: float = STEP_TIMEOUT) -> void:
	_results.erase(step)
	_rpc_expect.rpc_id(_client_peer, step, expect, timeout)
	if not await _wait(func() -> bool: return _results.has(step), timeout + 3.0):
		_check(false, "net step %d: %s" % [step, what], "no answer from the client")
		return
	var r: Array = _results[step]
	_check(r[0], "net step %d: %s" % [step, what], r[1])

func _finish() -> void:
	if not _is_client:
		print("farm_net_test: %d passed, %d failed" % [_passed, _failed])
		print("FARM NET TEST " + ("OK" if _failed == 0 else "FAILED"))
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	await get_tree().create_timer(0.5).timeout
	finished.emit(_failed)

# ------------------------------------------------------------------------------------------------ client

func _run_client() -> void:
	Net.is_host = false
	# PLAYING on the client too, so only the Net.is_host / is_server guard keeps its plots from ticking.
	GameState.phase = GameState.Phase.PLAYING
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client("127.0.0.1", _port)
	if err != OK:
		print("[client] create_client failed: ", error_string(err))
		_failed += 1
		return _finish()
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(func() -> void: _rpc_hello.rpc_id(1))
	multiplayer.server_disconnected.connect(func() -> void: _done = true)
	multiplayer.connection_failed.connect(func() -> void: _done = true)
	await _wait(func() -> bool: return _done, 55.0)
	_finish()

func _mismatch(expect: Dictionary) -> String:
	for plot_name: String in expect:
		var plot: GrowPlot = _plots[plot_name]
		var e: Dictionary = expect[plot_name]
		var who := "%s:" % plot_name
		if e.has("stage") and plot.stage != int(e["stage"]):
			return "%s stage %d != %d" % [who, plot.stage, e["stage"]]
		if e.has("stage_min") and plot.stage < int(e["stage_min"]):
			return "%s stage %d < %d" % [who, plot.stage, e["stage_min"]]
		if e.has("strain_id") and plot.strain_id != StringName(e["strain_id"]):
			return "%s strain '%s' != '%s'" % [who, plot.strain_id, e["strain_id"]]
		if e.has("water") and absf(plot.water - float(e["water"])) > float(e.get("water_tol", 0.0005)):
			return "%s water %.4f != %.4f" % [who, plot.water, e["water"]]
		if e.has("stage_progress") and absf(plot.stage_progress - float(e["stage_progress"])) > 0.0005:
			return "%s progress %.4f != %.4f" % [who, plot.stage_progress, e["stage_progress"]]
		if e.has("visual_stage") and _visible_stage(plot) != int(e["visual_stage"]):
			return "%s visible model %d != %d" % [who, _visible_stage(plot), e["visual_stage"]]
		if e.has("tint"):
			var mat := _crown_material(plot)
			var card := plot.get_node("Visual/Tag/Card") as MeshInstance3D
			var want := Toon.grade(Config.balance.get_seed(StringName(e["tint"])).color)
			if mat == null or not _near(mat.albedo_color, want) or card.material_override != mat:
				return "%s bud/tag tint %s != graded %s (tag shares it: %s)" % [who, mat.albedo_color if mat else Color.BLACK,
					want, card.material_override == mat]
		if e.has("wilt") and _wilt_state(plot) != str(e["wilt"]):
			return "%s wilt state '%s' != '%s'" % [who, _wilt_state(plot), e["wilt"]]
		if e.has("no_blend") and _blend_seen.get(plot_name, false):
			return "%s crossfaded while applying the initial sync (must be instant)" % who
		if e.has("blend_seen") and not _blend_seen.get(plot_name, false):
			return "%s never crossfaded on the client" % who
		if e.has("dry_indicator") and (plot.get_node("Plant/DryIndicator") as Node3D).visible != bool(e["dry_indicator"]):
			return "%s DRY indicator visible != %s" % [who, e["dry_indicator"]]
		if e.has("tag") and (plot.get_node("Visual/Tag") as Node3D).visible != bool(e["tag"]):
			return "%s tag visible != %s" % [who, e["tag"]]
		if e.has("synced") and int(plot.get(&"_first_sync_msec")) < 0:
			return "%s synchronized/delta_synchronized never fired" % who
	return ""

## "healthy" / "wilted" at rest (exactly one model on screen, Tilt at its end pose), else "blending" / "mixed".
func _wilt_state(plot: GrowPlot) -> String:
	var plant := plot.get_node("Plant") as PlantVisual
	var stage_node := plot.get_node_or_null("Plant/Tilt/Bouncer/Grow/" + ["", "Seedling", "Vegetative", "Flowering", "Ready"][plot.stage]) as Node3D
	if plant.is_wilt_blending():
		return "blending"
	var tilt := (plot.get_node("Plant/Tilt") as Node3D).rotation
	var dry_model := stage_node.get_node_or_null(^"Dry") as Node3D if stage_node != null else null
	var leaves := stage_node.get_node_or_null(^"Leaves") as Node3D if stage_node != null else null
	if plant.get_wilt() == 0.0 and tilt.is_zero_approx() and (dry_model == null or not dry_model.visible) and (leaves == null or leaves.visible):
		return "healthy"
	if plant.get_wilt() == 1.0 and tilt.is_equal_approx(PlantVisual.DROOP_ROTATION) and dry_model != null and dry_model.visible \
			and leaves != null and not leaves.visible:
		return "wilted"
	return "mixed"

func _crown_material(plot: GrowPlot) -> BaseMaterial3D:
	var crown := plot.get_node("Plant/Tilt/Bouncer/Grow/Ready/Buds/ColaTop") as MeshInstance3D
	for s in crown.mesh.get_surface_count():
		if Toonify.material_name(crown.mesh.surface_get_material(s)) == "TINT_bud":
			return crown.get_active_material(s) as BaseMaterial3D
	return null

## Colours equal up to the float noise (~1e-4) of the glTF round trip of the models' neutral TINT grey.
static func _near(x: Color, y: Color, eps: float = 0.003) -> bool:
	return absf(x.r - y.r) < eps and absf(x.g - y.g) < eps and absf(x.b - y.b) < eps and absf(x.a - y.a) < eps

func _process(_delta: float) -> void:
	if not _is_client:
		return
	for plot_name: String in _plots:
		if (_plots[plot_name] as GrowPlot).get_node("Plant").call(&"is_wilt_blending"):
			_blend_seen[plot_name] = true

func _visible_stage(plot: GrowPlot) -> int:
	var names: Array[String] = ["Seedling", "Vegetative", "Flowering", "Ready"]
	for i in names.size():
		if (plot.get_node("Plant/Tilt/Bouncer/Grow/" + names[i]) as Node3D).visible:
			return i + 1
	return 0

# ------------------------------------------------------------------------------------------------ RPCs

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello() -> void:
	_hello = true

@rpc("authority", "call_remote", "reliable")
func _rpc_expect(step: int, expect: Dictionary, timeout: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	var detail := _mismatch(expect)
	while detail != "" and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		detail = _mismatch(expect)
	print("[client] step %d: %s" % [step, "ok" if detail == "" else detail])
	_rpc_result.rpc_id(1, step, detail == "", detail)

@rpc("any_peer", "call_remote", "reliable")
func _rpc_result(step: int, ok: bool, detail: String) -> void:
	_results[step] = [ok, detail]

@rpc("authority", "call_remote", "reliable")
func _rpc_bye() -> void:
	_done = true

# ------------------------------------------------------------------------------------------------ utils

func _wait(cond: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while not cond.call():
		if Time.get_ticks_msec() > deadline:
			return false
		await get_tree().process_frame
	return true

func _check(cond: bool, what: String, detail: String = "") -> void:
	if cond:
		_passed += 1
		print("PASS: " + what)
	else:
		_failed += 1
		print("FAIL: " + what + ("   [" + detail + "]" if detail != "" else ""))
