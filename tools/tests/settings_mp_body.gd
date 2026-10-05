extends "res://tools/tests/qa_net_base.gd"
## M19 settings multi-process body (settings agent). Driven by tools/tests/settings_mp.sh; every process runs this script:
##   --role=seed --who=host|client --settings-file=F   writes this side's settings into F through Settings (a short run)
##   --role=nofile                                     no --settings-file: sets values, nothing is ever written
##   --role=host --settings-file=F                     the director (real Game.start_host)
##   --role=client --settings-file=F                   joins, answers the host's commands
## Common args: --port=N --round-sec=900 --timeout=S. Every process prints "ok   -" / "FAIL -" lines and a final
## "RESULT: PASS|FAIL" line; unannounced engine errors fail the run (qa_base).
## Pins: each side reads its own file at start (the values the seed run wrote); host and client each apply their own
## fov (camera and view-model camera) and mouse speed / invert to their own worker only, and the other's worker keeps
## the scene's camera; a change on one side moves nothing on the other (values, cameras, files); nothing in Settings is
## an RPC; a run without --settings-file keeps everything in memory (no file written, values still applied).

const NAMES := {"host": "Hosty", "client": "Clio"}
## What each side's seed run writes (and what it must read back at start).
const SEEDS := {
	"host": {&"fov": 70.0, &"mouse_sensitivity": 0.004, &"invert_y": false, &"voice_db": -5.0},
	"client": {&"fov": 95.0, &"mouse_sensitivity": 0.0015, &"invert_y": true, &"master_db": -6.0},
}
const SCENE_FOV := 80.0

var role: String = "host"
var who: String = ""
var port: int = 7915


func _run() -> void:
	role = str(Config.get_arg("role", "host"))
	who = str(Config.get_arg("who", ""))
	port = int(Config.get_arg("port", 7915))
	_label = "settings_mp:" + (role if who == "" else "%s:%s" % [role, who])
	await get_tree().process_frame
	match role:
		"seed":
			await _seed_main()
		"nofile":
			await _nofile_main()
		"host":
			await _host_main()
		_:
			await _client_main()


# =================================================================================================== SEED

func _seed_main() -> void:
	var seeds: Dictionary = SEEDS.get(who, {})
	if not check(Settings.persistent and Settings.path == String(Config.get_arg("settings-file", "")) and not seeds.is_empty(),
			"seed run for %s keeps %s" % [who, Settings.path]):
		finish(); return
	_remove(Settings.path)
	Settings.load_file(Settings.path)
	for key: StringName in seeds:
		Settings.set_value(key, seeds[key])
	await wait_frames(2)
	var parsed := Settings.parse_bytes(FileAccess.get_file_as_bytes(Settings.path))
	check((parsed["values"] as Dictionary) == seeds, "%s's file holds its seeds (%s)" % [who, parsed["values"]])
	finish()


# =================================================================================================== NO FILE

func _nofile_main() -> void:
	check(not Settings.persistent and Settings.path == Settings.DEFAULT_PATH, "no --settings-file under -s / headless: memory only")
	for key: StringName in Settings.get_keys():
		check(not Settings.is_set(key), "%s at its default (nothing read)" % key)
	Settings.set_value(&"fov", 66.0)
	Settings.set_value(&"master_db", -3.0)
	Settings.set_value(&"muted", true)
	await wait_frames(3)
	check(is_equal_approx(float(Settings.get_value(&"fov")), 66.0) and is_equal_approx(AudioServer.get_bus_volume_db(0), -3.0),
			"values still set and applied in memory")
	check(not Settings.save_now() and Settings.get_write_count() == 0, "nothing written (save_now refuses, 0 writes)")
	Settings.reset_to_defaults()
	await wait_frames(2)
	check(Settings.get_write_count() == 0, "DEFAULTS writes nothing either")
	finish()


# =================================================================================================== HOST

func _host_main() -> void:
	if not _starts_with_own_file("host"):
		finish(); return
	if not check(Game.start_host(NAMES["host"], port) == OK, "host on port %d" % port):
		finish(); return
	await wait_until(func() -> bool: return Game.local_player != null, 10.0, "host world ready")
	print("SETTINGS_HOST_READY")
	var me: Player = Game.local_player
	check(is_equal_approx(me.camera.fov, 70.0) and is_equal_approx(me.get_view_model_camera().fov, 70.0), "host: my cameras at my fov 70")
	if not await wait_until(func() -> bool: return _peer_named("client") > 0, 40.0, "the client registered"):
		finish(); return
	var c := _peer_named("client")
	await wait_until(func() -> bool: return Game.world.get_player(c) != null, 10.0, "the client's worker exists here")
	var cp: Player = Game.world.get_player(c)
	check(not cp.is_local() and is_equal_approx(cp.camera.fov, SCENE_FOV) and not cp.camera.current,
			"host: the client's worker keeps the scene's camera (%.0f), not mine and not his" % cp.camera.fov)
	check(_look_turns(me, 0.004, false), "host: my look at my speed 0.004, not inverted")

	step("the client: its own values, its own cameras, its own look")
	var r := await run_cmd(c, "report", {}, 20.0)
	check(bool(r.get("own_values", false)), "client: reads its own file (%s)" % r.get("values", ""))
	check(is_equal_approx(float(r.get("fov", 0.0)), 95.0) and is_equal_approx(float(r.get("vm_fov", 0.0)), 95.0), "client: its cameras at 95")
	check(is_equal_approx(float(r.get("host_body_fov", 0.0)), SCENE_FOV), "client: my worker there keeps the scene's camera")
	check(bool(r.get("look_ok", false)), "client: its look at 0.0015, inverted")
	check(is_equal_approx(AudioServer.get_bus_volume_db(0), 0.0) and is_equal_approx(float(r.get("master", 0.0)), -6.0),
			"master volume: mine 0 dB, the client's -6 dB")

	step("a change here stays here")
	var client_file_before := String(r.get("file", ""))
	Settings.set_value(&"fov", 72.0)
	Settings.set_value(&"invert_y", true)
	await wait_frames(3)
	check(is_equal_approx(me.camera.fov, 72.0) and is_equal_approx(cp.camera.fov, SCENE_FOV), "host: my camera 72, the client's worker unchanged")
	var mine := Settings.parse_bytes(FileAccess.get_file_as_bytes(Settings.path))["values"] as Dictionary
	check(is_equal_approx(float(mine.get(&"fov", 0.0)), 72.0) and mine.get(&"invert_y") == true, "host: my file has 72 and invert")
	await wait_sec(0.5)
	r = await run_cmd(c, "report", {}, 20.0)
	check(is_equal_approx(float(r.get("fov", 0.0)), 95.0) and bool(r.get("own_values", false)), "client: still its own 95")
	check(String(r.get("file", "")) == client_file_before and client_file_before != "", "client: its file untouched")
	check(int(r.get("changes", -1)) == 0, "client: no settings change arrived from the host")

	step("a change there stays there")
	r = await run_cmd(c, "change", {"fov": 64.0, "mouse_sensitivity": 0.006}, 20.0)
	check(is_equal_approx(float(r.get("fov", 0.0)), 64.0) and bool(r.get("written", false)), "client: its camera 64, its file written")
	await wait_sec(0.5)
	check(is_equal_approx(float(Settings.get_value(&"fov")), 72.0) and is_equal_approx(float(Settings.get_value(&"mouse_sensitivity")), 0.004)
			and is_equal_approx(me.camera.fov, 72.0), "host: still 72 and 0.004")
	check(is_equal_approx(cp.camera.fov, SCENE_FOV), "host: the client's worker still on the scene's camera")
	check(_no_rpc(), "nothing in Settings is an RPC")

	step("finish")
	allow_error("Unable to send packet on channel 0", 8, true)
	cmd(c, "finish")
	await wait_until(func() -> bool: return not Net.players.has(c), 20.0, "the client left")
	_remove(Settings.path)
	Settings.set(&"persistent", false)
	finish()


# =================================================================================================== CLIENT

var _changes: int = 0


func _client_main() -> void:
	if not _starts_with_own_file("client"):
		finish(); return
	Settings.changed.connect(func(_k: StringName) -> void: _changes += 1)
	if not check(Game.start_join("127.0.0.1", port, NAMES["client"]) == OK, "start_join"):
		finish(); return
	if not await wait_until(func() -> bool: return Game.local_player != null, 30.0, "joined"):
		finish(); return
	await client_loop()
	_remove(Settings.path)
	Settings.set(&"persistent", false)
	finish()


func _execute(seq: int, action: String, args: Dictionary) -> void:
	var me: Player = Game.local_player
	match action:
		"report":
			var host_body: Player = Game.world.get_player(1) if Game.world != null else null
			var seeds: Dictionary = SEEDS["client"]
			var own := true
			for key: StringName in seeds:
				if Settings.get_value(key) != seeds[key]:
					own = false
			ack(seq, {"own_values": own, "values": str(_values_of(seeds.keys())),
				"fov": me.camera.fov, "vm_fov": me.get_view_model_camera().fov,
				"host_body_fov": host_body.camera.fov if host_body != null else -1.0,
				"look_ok": _look_turns(me, 0.0015, true), "master": AudioServer.get_bus_volume_db(0),
				"file": FileAccess.get_file_as_string(Settings.path), "changes": _changes})
		"change":
			var writes := Settings.get_write_count()
			for key: String in args:
				Settings.set_value(StringName(key), args[key])
			await wait_frames(3)
			ack(seq, {"fov": me.camera.fov, "written": Settings.get_write_count() > writes})
		_:
			await super(seq, action, args)


# =================================================================================================== helpers

## This side started with the values its seed run wrote (read at start, before anything here touched Settings).
func _starts_with_own_file(side: String) -> bool:
	var seeds: Dictionary = SEEDS[side]
	var ok := Settings.persistent and Settings.path == String(Config.get_arg("settings-file", ""))
	for key: StringName in seeds:
		if Settings.get_value(key) != seeds[key]:
			ok = false
	return check(ok, "%s: read its own file at start (%s)" % [side, _values_of(seeds.keys())])


func _values_of(keys: Array) -> Dictionary:
	var out := {}
	for k: Variant in keys:
		out[k] = Settings.get_value(StringName(k))
	return out


## 100 px right and 40 px down on `p`: turns by `sens` per pixel, and down looks down unless inverted. Restores the look.
func _look_turns(p: Player, sens: float, inverted: bool) -> bool:
	var yaw0 := p.rotation.y
	var pitch0 := p.head.rotation.x
	p.rotation.y = 0.0
	p.head.rotation.x = 0.0
	p.apply_look_input(Vector2(100.0, 40.0))
	var yaw_ok := is_equal_approx(p.rotation.y, -100.0 * sens)
	var pitch_ok := is_equal_approx(p.head.rotation.x, (40.0 if inverted else -40.0) * sens)
	p.rotation.y = yaw0
	p.head.rotation.x = pitch0
	return yaw_ok and pitch_ok


func _no_rpc() -> bool:
	var cfg: Variant = (Settings.get_script() as Script).get_rpc_config()
	return cfg == null or (cfg is Dictionary and (cfg as Dictionary).is_empty())


func _peer_named(key: String) -> int:
	for id in Net.players:
		if Net.get_player_name(id) == NAMES[key]:
			return int(id)
	return 0


func _remove(path: String) -> void:
	if path != "" and path != Settings.DEFAULT_PATH and FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
