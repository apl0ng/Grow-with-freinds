extends "res://tools/tests/perf_base.gd"
## M22 perf: the windowed benchmark (lead tool, not a suite; CONTRACTS.md "M22", "Performance"; RELEASE.md R3 "60 fps
## at 1280x720 with four workers during the worst event"). The perf suite's moments (perf_base.gd: a host, Bob, Cara and
## Dan on a busy floor of the chill game; the sprinklers, a drive-by, a hostile plant chasing, a Black Damp cloud with
## two workers fogged, two radios carrying, three voice emitters, the shift report opening) staged on the real
## renderer, the camera on each one, and per moment over MEASURE_SEC: the lowest Performance.TIME_FPS reading, the
## worst single frame and the 1% low (as fps), the most draw calls / primitives / objects in a frame, and the viewport's
## measured CPU / GPU render time.
##   godot --rendering-method forward_plus --resolution 1280x720 --position 1400,800 --path . \
##       -s res://tools/tests/run_test.gd -- --body=res://tools/tests/perf_shots_body.gd \
##       --port=7986 --mute --no-mic --chill --replay --run=B5VP \
##       --career-file=user://perf_shots_career.cfg --settings-file=user://perf_shots_settings.cfg
## Vsync is switched off and the frame rate uncapped, so the numbers show the headroom over 60; --vsync keeps the
## display's vsync (then 60 is the most it can show on a 60 Hz screen). No events come on their own (the scheduler is
## off), the mouse is never captured, and a watchdog ends the run after WATCHDOG_SEC. Under --headless it stages every
## moment and prints the same table with the dummy renderer's numbers (a dry run of the staging; it exits 0).

const MEASURE_SEC := 3.0
const SETTLE_SEC := 1.0
const WATCHDOG_SEC := 150.0
## Where the camera stands for each moment and what it looks at (cover layout 0, which --run=B5VP picks).
const VIEWS: Dictionary = {
	&"idle": [Vector3(-6.5, 0.0, 2.5), Vector3(5.5, 0.9, 0.0)],
	&"sprinklers": [Vector3(-6.5, 0.0, 2.5), Vector3(5.5, 0.9, 0.0)],
	&"driveby": [Vector3(0.0, 0.0, 3.5), Vector3(0.0, 1.2, 12.0)],
	&"hostile": [Vector3(2.5, 0.0, 4.0), Vector3(-3.0, 0.6, 0.5)],
	&"spores": [Vector3(0.5, 0.0, 1.5), Vector3(5.0, 0.8, 0.0)],
	&"radios": [Vector3(-3.5, 0.0, 2.5), Vector3(-8.5, 1.0, -6.5)],
	&"voices": [Vector3(-1.0, 0.0, 4.5), Vector3(2.0, 1.2, -1.0)],
	&"report": [Vector3(-1.0, 0.0, 0.9), Vector3(5.0, 1.0, 0.0)],
}

var _windowed := false


func _process(delta: float) -> void:
	super(delta)
	if _windowed and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _run() -> void:
	_label = "perf_shots"
	get_tree().create_timer(WATCHDOG_SEC, true, false, true).timeout.connect(func() -> void:
		print("perf_shots: watchdog, quitting")
		get_tree().quit(2))
	_windowed = DisplayServer.get_name() != "headless"
	Config.lobby_enabled = false            # straight onto the floor
	Config.user_args["no-events"] = true    # nothing comes on its own: every moment is staged here
	await get_tree().process_frame
	if _windowed:
		get_window().size = Vector2i(1280, 720)
		if not Config.has_arg("vsync"):
			DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	else:
		get_tree().root.size = Vector2i(1280, 720)
		print("perf_shots: headless: a dry run of the staging (the dummy renderer's numbers mean nothing)")
	if not await host_floor(port_arg(7986), [BOB, CARA, DAN] as Array[int]):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null and Game.local_player.camera != null, 3.0, "the local camera"):
		finish(); return
	var vp_rid := get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(vp_rid, true)
	await wait_sec(2.5) # the GO banner and the first compiles out of the way
	var rows := {}
	for m in MOMENTS:
		step("moment: %s" % m)
		var started: bool = await stage(m)
		check(started, "%s: started" % m)
		var view: Array = VIEWS.get(m, VIEWS[&"idle"])
		look(view[0], view[1])
		if m != &"report":
			await hold(SETTLE_SEC)
		rows[m] = await _measure_render(m, vp_rid)
		var r: Dictionary = rows[m]
		print("    %s: min fps %d (worst frame %.1f ms, 1%% low %.0f fps, mean %.0f fps), draw calls %d, primitives %d, objects %d, render cpu %.2f / gpu %.2f ms"
				% [m, r["min_fps"], r["worst_ms"], r["low1_fps"], r["mean_fps"], r["draws"], r["prims"], r["objects"], r["cpu_ms"], r["gpu_ms"]])
		if m != &"report":
			unstage(m)
			await hold(0.8)
	print("perf_shots table (%s, %dx%d, vsync %s, four workers):\n%s" % [RenderingServer.get_video_adapter_name() if _windowed else "headless",
			get_viewport().get_visible_rect().size.x, get_viewport().get_visible_rect().size.y,
			"on" if Config.has_arg("vsync") else "off", render_table(rows)])
	finish()


## Puts the local player at `pos` (x / z) looking at `target` (world space).
func look(pos: Vector3, target: Vector3) -> void:
	me.velocity = Vector3.ZERO
	me.global_position = Vector3(pos.x, 0.02, pos.z)
	var eye := me.global_position + Vector3.UP * 1.6
	var dir := (target - eye).normalized()
	me.rotation = Vector3(0.0, atan2(-dir.x, -dir.z), 0.0)
	me.head.rotation.x = asin(clampf(dir.y, -1.0, 1.0))


## MEASURE_SEC of frames while `moment` runs: the lowest TIME_FPS reading, the worst frame and the 1% low, the mean fps,
## the most draw calls / primitives / objects in a frame, the mean measured render time (CPU and GPU, ms).
func _measure_render(moment: StringName, vp_rid: RID) -> Dictionary:
	var deltas := PackedFloat32Array()
	var min_fps := 1000000.0
	var draws := 0
	var prims := 0
	var objects := 0
	var cpu := 0.0
	var gpu := 0.0
	var t0 := Time.get_ticks_msec()
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() - t0 < MEASURE_SEC * 1000.0:
		drive()
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		deltas.append(float(now - last) / 1000.0)
		last = now
		if Time.get_ticks_msec() - t0 > 1100: # TIME_FPS counts whole seconds: the first reading still covers the staging
			min_fps = minf(min_fps, Performance.get_monitor(Performance.TIME_FPS))
		draws = maxi(draws, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
		prims = maxi(prims, int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)))
		objects = maxi(objects, int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp_rid)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp_rid)
	var n := maxi(deltas.size(), 1)
	var sorted := deltas.duplicate()
	sorted.sort()
	var worst := sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0
	var low1 := sorted[clampi(ceili(0.99 * sorted.size()) - 1, 0, maxi(sorted.size() - 1, 0))] if not sorted.is_empty() else 0.0
	var total := 0.0
	for d in deltas:
		total += d
	return {"min_fps": int(min_fps) if min_fps < 1000000.0 else 0, "worst_ms": worst, "low1_fps": 1000.0 / maxf(low1, 0.001),
			"mean_fps": 1000.0 * n / maxf(total, 0.001), "draws": draws, "prims": prims, "objects": objects,
			"cpu_ms": cpu / n, "gpu_ms": gpu / n, "live": is_live(moment)}


static func render_table(rows: Dictionary) -> String:
	var lines: PackedStringArray = ["  %-11s %7s %8s %7s %8s | %6s %10s %7s | %7s %7s" % ["moment", "min fps", "worst ms", "1% low", "mean fps",
			"draws", "primitives", "objects", "cpu ms", "gpu ms"]]
	for k: Variant in rows:
		var r: Dictionary = rows[k]
		lines.append("  %-11s %7d %8.1f %7.0f %8.0f | %6d %10d %7d | %7.2f %7.2f" % [String(k), r["min_fps"], r["worst_ms"], r["low1_fps"],
				r["mean_fps"], r["draws"], r["prims"], r["objects"], r["cpu_ms"], r["gpu_ms"]])
	return "\n".join(lines)
