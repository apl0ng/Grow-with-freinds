extends "res://tools/tests/qa_base.gd"
## M19 settings suite (settings agent): the Settings autoload, its consumers and the OPTIONS card, on one headless
## process with a real solo host. Always run with --settings-file (a test file in user://; the user's real
## user://settings.cfg is never read or written here):
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/settings_body.gd \
##       --port=7914 --settings-file=user://settings_test_7914.cfg --round-sec=900 --timeout=180
## Pins:
##   storage     --settings-file makes the run keep that file; without it a headless or `-s` run keeps nothing
##               (decide_storage's table); a stale test file is cleared first
##   defaults    every key's default (fov 80, sensitivity = Config.balance.mouse_sensitivity, guidance on while no
##               shift is worked), unknown keys give the caller's default
##   set / save  every key set to a non-default value reads back, is applied, emits `changed` once and is in the file
##               at the end of the frame (one write for several values, through a temp file that is gone after)
##   clamping    out-of-range numbers clamp, window_scale snaps to 1 / 1.5 / 2, ints read as bools, junk is ignored
##   junk        a damaged file (bad values, unknown keys, binary bytes, CRLF, oversized) reads as defaults without
##               an error line; the next write drops the junk and keeps the main menu's [menu] section byte for byte;
##               ConfigFile (the main menu) still reads the result
##   reset       reset_to_defaults() puts everything back and leaves only [menu] and the migration mark in the file
##   migration   the old Sound toggle (audio.cfg) and voice volume (voice.cfg) move in once, never over a set value
##   buses       Master volume + mute, the SFX bus (Sfx.volume_db), the Voice bus (Voice.output_volume_db, voice.cfg
##               untouched); `--mute` (forced) wins over `muted` and the toggles show it; Sfx's players and loops,
##               the radio's speakers and the spores' cough all play on the SFX bus
##   player      the local camera and the view-model camera take fov at once; mouse sensitivity and invert Y apply to
##               the look; the back room's spectator camera keeps its own field of view
##   OPTIONS     from the pause menu with the keyboard (OPTIONS in the ON BREAK loop, Enter opens, the card's own
##               closed loop, a slider moved with the arrows, a toggle with Enter, DEFAULTS, Escape back to the ON
##               BREAK card, then out); the ON BREAK pointer line, the key list (incl. 1-4 gestures), the card fits
##               1280 x 720; the Sound toggle and voice slider on the ON BREAK card are views of the settings
##   main menu   the version line ("v" + Game.get_version(), grey, under the title); Options with the keyboard and
##               the mouse, Escape back to the menu with the keyboard on Options

const DEFAULT_PORT := 7914

var port: int = DEFAULT_PORT
var hud: HUD = null
var _changes: Array[StringName] = []
var _scratch: PackedStringArray = []


func _run() -> void:
	_label = "settings"
	await get_tree().process_frame
	port = port_arg(DEFAULT_PORT)
	Settings.changed.connect(func(key: StringName) -> void: _changes.append(key))
	if not _section_storage():
		finish()
		return
	_section_defaults()
	await _section_set_and_save()
	_section_clamp()
	await _section_junk()
	await _section_reset()
	await _section_migration()
	await _section_buses()
	await _section_main_menu()
	if await _host():
		await _section_routing()
		await _section_player()
		await _section_pause_options()
	await _section_back_to_menu()
	_cleanup()
	finish()


# --- storage -----------------------------------------------------------------------------------------------------------

func _section_storage() -> bool:
	step("storage: --settings-file keeps that file; without it nothing is kept")
	var given := String(Config.get_arg("settings-file", ""))
	if not check(given != "" and given != Settings.DEFAULT_PATH, "run with a test --settings-file (%s)" % given):
		return false
	check(Settings.persistent and Settings.path == given, "Settings keeps %s (persistent %s)" % [Settings.path, Settings.persistent])
	var cases := [
		[{}, true, false, false, Settings.DEFAULT_PATH, "headless, no file: memory only"],
		[{}, false, true, false, Settings.DEFAULT_PATH, "-s script, no file: memory only"],
		[{}, true, true, false, Settings.DEFAULT_PATH, "headless -s, no file: memory only"],
		[{}, false, false, true, Settings.DEFAULT_PATH, "the game itself: user://settings.cfg"],
		[{"settings-file": "user://x.cfg"}, true, true, true, "user://x.cfg", "--settings-file in a suite: that file"],
		[{"settings-file": true}, true, false, false, Settings.DEFAULT_PATH, "a bare --settings-file: memory only"],
		[{"settings-file": "  "}, false, true, false, Settings.DEFAULT_PATH, "a blank --settings-file: memory only"],
	]
	for c: Array in cases:
		var d := Settings.decide_storage(c[0], c[1], c[2])
		check(bool(d["persistent"]) == bool(c[3]) and String(d["path"]) == String(c[4]), "%s (%s)" % [c[5], d])
	# A file left by an earlier run that died: start from nothing.
	_remove(Settings.path)
	_remove(Settings.path + ".tmp")
	Settings.reset_to_defaults()
	check(Settings.load_file(Settings.path) == 0 and not FileAccess.file_exists(Settings.path), "no test file: a clean start")
	return true


# --- defaults ----------------------------------------------------------------------------------------------------------

func _section_defaults() -> void:
	step("defaults")
	check(is_equal_approx(float(Settings.get_value(&"fov")), 80.0) and is_equal_approx(float(Settings.DEFAULTS[&"fov"]), 80.0),
			"fov 80 (the player's camera as it was)")
	check(is_equal_approx(float(Settings.get_value(&"mouse_sensitivity")), Config.balance.mouse_sensitivity),
			"mouse sensitivity defaults to Config.balance.mouse_sensitivity (%.4f)" % Config.balance.mouse_sensitivity)
	check(Settings.get_value(&"invert_y") == false and Settings.get_value(&"fullscreen") == false and Settings.get_value(&"vsync") == true
			and Settings.get_value(&"muted") == false, "invert off, windowed, vsync on, sound on")
	check(is_equal_approx(float(Settings.get_value(&"window_scale")), 1.0), "window 1x")
	for key: StringName in [&"master_db", &"sfx_db", &"voice_db"]:
		check(is_equal_approx(float(Settings.get_value(key)), 0.0), "%s 0 dB" % key)
	check(Career.get_record("shifts") == 0 and Settings.get_value(&"guidance") == true, "guidance on while no shift is worked")
	check(Settings.get_value(&"no_such_key", 7) == 7 and Settings.get_value(&"no_such_key") == null, "an unknown key gives the caller's default")
	check(Settings.get_keys().size() == Settings.DEFAULTS.size() and Settings.get_keys().size() == 11, "eleven keys (%s)" % [Settings.get_keys()])
	for key: StringName in Settings.get_keys():
		check(not Settings.is_set(key), "%s not set at the start" % key)


# --- set / save ----------------------------------------------------------------------------------------------------------

## A value for every key that is not its default and is in range.
const SET_VALUES := {
	&"mouse_sensitivity": 0.004,
	&"invert_y": true,
	&"fov": 92.0,
	&"fullscreen": true,
	&"window_scale": 1.5,
	&"vsync": false,
	&"master_db": -4.0,
	&"sfx_db": -6.0,
	&"voice_db": -8.0,
	&"muted": true,
	&"guidance": false,
}


func _section_set_and_save() -> void:
	step("every value set, applied, announced and written")
	var writes0 := Settings.get_write_count()
	for key: StringName in SET_VALUES:
		_changes.clear()
		Settings.set_value(key, SET_VALUES[key])
		check(Settings.get_value(key) == SET_VALUES[key] and Settings.is_set(key), "%s reads back %s" % [key, Settings.get_value(key)])
		check(_changes == [key], "%s: changed emitted once (%s)" % [key, _changes])
	check(Settings.get_write_count() == writes0, "nothing written inside the frame")
	await wait_frames(2)
	check(Settings.get_write_count() == writes0 + 1, "one write at the end of the frame for eleven values (%d)" % (Settings.get_write_count() - writes0))
	check(FileAccess.file_exists(Settings.path) and not FileAccess.file_exists(Settings.path + ".tmp"), "the file is there, the temp file is gone")
	var parsed := Settings.parse_bytes(FileAccess.get_file_as_bytes(Settings.path))
	check(int(parsed["junk"]) == 0 and (parsed["values"] as Dictionary).size() == SET_VALUES.size(), "the file holds the eleven values, nothing damaged")
	var same := true
	for key: StringName in SET_VALUES:
		if (parsed["values"] as Dictionary).get(key) != SET_VALUES[key]:
			same = false
	check(same, "every value in the file as set")
	var text := FileAccess.get_file_as_string(Settings.path)
	check(text.contains("[controls]") and text.contains("[video]") and text.contains("[audio]") and text.contains("[game]")
			and text.contains("fov=92.0") and text.contains("invert_y=true"), "sections controls / video / audio / game, ConfigFile style lines")
	var cfg := ConfigFile.new()
	check(cfg.load(Settings.path) == OK and is_equal_approx(float(cfg.get_value("video", "fov", 0.0)), 92.0)
			and cfg.get_value("audio", "muted", false) == true, "ConfigFile reads it too (the main menu shares the file)")
	# Read at start: a fresh read of the file gives the same values.
	_changes.clear()
	check(Settings.load_file(Settings.path) == 0 and _changes.is_empty(), "reading the file back changes nothing")
	# The same value again: no signal, no write.
	var writes1 := Settings.get_write_count()
	Settings.set_value(&"fov", 92.0)
	await wait_frames(2)
	check(_changes.is_empty() and Settings.get_write_count() == writes1, "setting the same value again: no signal, no write")
	# The display was asked for (headless: recorded only).
	var d := Settings.get_display_state()
	check(d.get("fullscreen") == true and d.get("vsync") == false and d.get("size") == Vector2i(1920, 1080),
			"the window asked for: fullscreen, vsync off, 1.5x = 1920 x 1080 (%s)" % d)
	Settings.set_value(&"fullscreen", false)
	Settings.set_value(&"window_scale", 2.0)
	check(Settings.get_display_state().get("size") == Vector2i(2560, 1440) and Settings.get_display_state().get("fullscreen") == false,
			"windowed 2x asks for 2560 x 1440")
	check(Settings.window_size_for(1.0) == Vector2i(1280, 720), "1x is the 1280 x 720 viewport")


# --- clamping ----------------------------------------------------------------------------------------------------------

func _section_clamp() -> void:
	step("set_value clamps; junk is ignored")
	var cases := [
		[&"fov", 150.0, 100.0], [&"fov", 10, 60.0], [&"fov", 77.5, 77.5],
		[&"master_db", 50.0, 6.0], [&"sfx_db", -100.0, -30.0], [&"voice_db", 3, 3.0],
		[&"mouse_sensitivity", 1.0, Settings.SENSITIVITY_MAX], [&"mouse_sensitivity", 0.0, Settings.SENSITIVITY_MIN],
		[&"window_scale", 1.7, 1.5], [&"window_scale", 1.2, 1.0], [&"window_scale", 9, 2.0], [&"window_scale", 1.8, 2.0],
		[&"invert_y", 0, false], [&"invert_y", 1, true],
	]
	for c: Array in cases:
		Settings.set_value(c[0], c[1])
		var got: Variant = Settings.get_value(c[0])
		var ok: bool = got == c[2] if c[2] is bool else (got is float and is_equal_approx(float(got), float(c[2])))
		check(ok, "%s = %s reads %s" % [c[0], c[1], got])
	var fov0: Variant = Settings.get_value(&"fov")
	_changes.clear()
	for junk: Variant in ["95", null, Vector2(1, 2), NAN, INF, -INF, [90.0], {"fov": 90}, true]:
		Settings.set_value(&"fov", junk)
	Settings.set_value(&"invert_y", "yes")
	Settings.set_value(&"invert_y", 2)
	Settings.set_value(&"no_such_key", 1.0)
	check(Settings.get_value(&"fov") == fov0 and _changes.is_empty(), "wrong types, NaN, infinity and unknown keys change nothing")
	check(Settings.sanitize(&"fov", "80") == null and Settings.sanitize(&"nope", 1) == null and is_equal_approx(float(Settings.sanitize(&"fov", 61)), 61.0),
			"sanitize: a string is not a number, an unknown key is nothing, an int is a float")


# --- junk ----------------------------------------------------------------------------------------------------------------

func _section_junk() -> void:
	step("a damaged file reads as defaults, without an error line")
	var junk_text := "\n".join([
		"; a comment", "[menu]", "name=\"Dörte\"", "ip=\"10.0.0.7\"", "port=7123",
		"[controls]", "mouse_sensitivity=banana", "invert_y=yes", "garbage line without equals", "=5",
		"[video]", "fov=500.0", "window_scale=1.3", "vsync=false", "fullscreen=1", "fov_extra=2", "mouse_sensitivity=0.003",
		"[audio]", "master_db=-12.0\r", "sfx_db=1e400", "voice_db=\"-5\"", "muted=true",
		"[game]", "guidance=false", "migrated=true",
		"[unknown]", "fov=70.0",
		"[video", "fov=61.0",
	])
	var parsed := Settings.parse_text(junk_text)
	var v: Dictionary = parsed["values"]
	check(v.size() == 4 and v.get(&"vsync") == false and is_equal_approx(float(v.get(&"master_db", 0.0)), -12.0) and v.get(&"muted") == true
			and v.get(&"guidance") == false, "only the four good values survive (%s)" % v)
	check(int(parsed["junk"]) == 11 and bool(parsed["migrated"]), "eleven damaged lines counted, the migration mark read (%d)" % int(parsed["junk"]))
	check(Settings.parse_bytes(PackedByteArray()).get("values") == {} and Settings.parse_text("[video]\nfov=0x50\nfov=-0\n")["values"] == {},
			"an empty file and hex / negative numbers: nothing")
	var bin := PackedByteArray([0, 255, 254, 10, 91, 118, 105, 100, 101, 111, 93, 10, 102, 111, 118, 61, 57, 48, 0, 46, 48, 200, 10])
	var pb := Settings.parse_bytes(bin)
	check(is_equal_approx(float((pb["values"] as Dictionary).get(&"fov", 0.0)), 90.0), "binary bytes around a line are dropped, the line reads (%s)" % pb)
	# The same file on disk, loaded: no error line (the error counter would fail the suite), the defaults for the rest.
	var junk_path := _scratch_path("junk")
	_write_bytes(junk_path, junk_text.to_utf8_buffer())
	check(Settings.load_file(junk_path) == 11, "load_file reports eleven damaged lines")
	check(is_equal_approx(float(Settings.get_value(&"fov")), 80.0) and is_equal_approx(float(Settings.get_value(&"mouse_sensitivity")), Config.balance.mouse_sensitivity)
			and Settings.get_value(&"invert_y") == false and is_equal_approx(float(Settings.get_value(&"master_db")), -12.0),
			"the damaged ones read as defaults, the good ones as written")
	var big := PackedByteArray()
	big.resize(Settings.MAX_FILE_BYTES + 10)
	big.fill(65)
	var big_path := _scratch_path("big")
	_write_bytes(big_path, big)
	check(Settings.load_file(big_path) == 0 and not Settings.is_set(&"master_db"), "an oversized file is not a settings file")
	# The next write keeps [menu] byte for byte (the umlaut, a CRLF line) and drops the junk.
	var existing := "[menu]\r\nname=\"Dörte\"\r\nip=\"10.0.0.7\"\nport=7123\n\n[video]\nfov=junk\nfov=70.0\n\n[other]\nkeep=1\n".to_utf8_buffer()
	var built := Settings.build_bytes(existing, {&"fov": 75.0, &"muted": true}, true)
	var built_text := built.get_string_from_utf8()
	check(built_text.begins_with("[menu]\r\nname=\"Dörte\"\r\nip=\"10.0.0.7\"\nport=7123\n\n[other]\nkeep=1\n\n[video]\nfov=75.0\n\n[audio]\nmuted=true\n\n[game]\nmigrated=true\n"),
			"build: [menu] and [other] as they were, then ours, the junk gone:\n%s" % built_text)
	var menu_path := _scratch_path("menu")
	_write_bytes(menu_path, built)
	var cfg := ConfigFile.new()
	check(cfg.load(menu_path) == OK and String(cfg.get_value("menu", "name", "")) == "Dörte" and int(cfg.get_value("menu", "port", 0)) == 7123
			and is_equal_approx(float(cfg.get_value("video", "fov", 0.0)), 75.0), "ConfigFile reads the built file: the menu's name / port intact")
	check(Settings.build_text("", {}, false) == "" and Settings.build_text("[menu]\nname=\"A\"\n", {}, false) == "[menu]\nname=\"A\"\n",
			"nothing of ours to write: the file is the menu's alone")
	# Back to the test file.
	Settings.load_file(Settings.path)
	await wait_frames(1)


# --- reset ---------------------------------------------------------------------------------------------------------------

func _section_reset() -> void:
	step("DEFAULTS: reset_to_defaults()")
	# The main menu's section in the same file (as the menu writes it: ConfigFile).
	var cfg := ConfigFile.new()
	cfg.load(Settings.path)
	cfg.set_value("menu", "name", "Persisty")
	cfg.set_value("menu", "port", 7321)
	cfg.save(Settings.path)
	for key: StringName in SET_VALUES:
		Settings.set_value(key, SET_VALUES[key])
	await wait_frames(2)
	_changes.clear()
	Settings.reset_to_defaults()
	var all_default := true
	for key: StringName in Settings.get_keys():
		if Settings.is_set(key) or Settings.get_value(key) != Settings.get_default(key):
			all_default = false
	check(all_default, "every value back to its default")
	check(_changes.size() == SET_VALUES.size(), "changed for each value that moved (%d)" % _changes.size())
	await wait_frames(2)
	var after := ConfigFile.new()
	check(after.load(Settings.path) == OK and String(after.get_value("menu", "name", "")) == "Persisty" and int(after.get_value("menu", "port", 0)) == 7321,
			"the menu's section survives our writes")
	var parsed := Settings.parse_bytes(FileAccess.get_file_as_bytes(Settings.path))
	check((parsed["values"] as Dictionary).is_empty(), "no value of ours left in the file")
	_changes.clear()
	Settings.reset_to_defaults()
	check(_changes.is_empty(), "DEFAULTS twice: nothing moves")


# --- migration -----------------------------------------------------------------------------------------------------------

func _section_migration() -> void:
	step("migration: the old Sound toggle and voice volume move in once")
	var audio_path := _scratch_path("audio")
	var voice_path := _scratch_path("voice")
	var a := ConfigFile.new()
	a.set_value("audio", "muted", true)
	a.save(audio_path)
	var v := ConfigFile.new()
	v.set_value("voice", "enabled", true)
	v.set_value("voice", "output_volume_db", -9.0)
	v.save(voice_path)
	check(Settings.migrate_legacy(audio_path, voice_path), "something moved")
	check(Settings.get_value(&"muted") == true and is_equal_approx(float(Settings.get_value(&"voice_db")), -9.0), "muted and -9 dB voices came over")
	check(AudioServer.is_bus_mute(0) and is_equal_approx(Voice.output_volume_db, -9.0), "and are applied")
	Settings.set_value(&"muted", false)
	Settings.set_value(&"voice_db", -2.0)
	check(not Settings.migrate_legacy(audio_path, voice_path) and Settings.get_value(&"muted") == false
			and is_equal_approx(float(Settings.get_value(&"voice_db")), -2.0), "never over a value that is set")
	await wait_frames(2)
	check(FileAccess.get_file_as_string(Settings.path).contains("migrated=true"), "the mark is written with the values")
	Settings.reset_to_defaults()
	check(not Settings.migrate_legacy(_scratch_path("none_a"), _scratch_path("none_v")), "no old files: nothing")
	a.set_value("audio", "muted", false)
	a.save(audio_path)
	v.set_value("voice", "output_volume_db", 0.0)
	v.save(voice_path)
	check(not Settings.migrate_legacy(audio_path, voice_path) and not Settings.is_set(&"muted") and not Settings.is_set(&"voice_db"),
			"old files at the defaults: nothing set")
	await wait_frames(2)


# --- buses ---------------------------------------------------------------------------------------------------------------

func _section_buses() -> void:
	step("buses: Master / SFX / Voice")
	var sfx_idx := AudioServer.get_bus_index(&"SFX")
	var voice_idx := AudioServer.get_bus_index(&"Voice")
	check(sfx_idx > 0 and AudioServer.get_bus_send(sfx_idx) == &"Master", "an SFX bus sending to Master")
	check(voice_idx > 0, "the Voice bus")
	var voice_cfg_before := String(Voice.settings_path)
	var voice_scratch := _scratch_path("voicecfg_untouched")
	Voice.settings_path = voice_scratch
	Settings.set_value(&"master_db", -7.0)
	Settings.set_value(&"sfx_db", -11.0)
	Settings.set_value(&"voice_db", -13.0)
	check(is_equal_approx(AudioServer.get_bus_volume_db(0), -7.0), "master_db on the Master bus")
	check(is_equal_approx(AudioServer.get_bus_volume_db(sfx_idx), -11.0) and is_equal_approx(Sfx.volume_db, -11.0), "sfx_db on the SFX bus (Sfx.volume_db)")
	check(is_equal_approx(AudioServer.get_bus_volume_db(voice_idx), -13.0) and is_equal_approx(Voice.output_volume_db, -13.0), "voice_db on the Voice bus")
	await wait_frames(2)
	check(not FileAccess.file_exists(voice_scratch), "voice.cfg is not written for it")
	Voice.settings_path = voice_cfg_before
	Settings.set_value(&"muted", true)
	check(AudioServer.is_bus_mute(0) and Config.is_muted(), "muted: the Master bus is muted (Config.is_muted sees it)")
	Settings.set_value(&"muted", false)
	check(not AudioServer.is_bus_mute(0) and not Config.is_muted(), "and back")
	# --mute: forced on, never saved, the toggles show it.
	Settings.set(&"_forced_mute", true)
	Settings.call(&"_apply_audio")
	Settings.set_value(&"muted", true)
	Settings.set_value(&"muted", false)
	check(AudioServer.is_bus_mute(0) and Settings.is_mute_forced(), "--mute holds the Master bus muted whatever muted says")
	await wait_frames(2)
	check(not FileAccess.get_file_as_string(Settings.path).contains("muted=true"), "--mute itself is never written")
	Settings.set(&"_forced_mute", Config.has_arg("mute"))
	Settings.call(&"_apply_audio")
	check(AudioServer.is_bus_mute(0) == Config.has_arg("mute"), "without --mute the bus follows muted again")
	Settings.reset_to_defaults()
	check(is_equal_approx(AudioServer.get_bus_volume_db(0), 0.0) and is_equal_approx(AudioServer.get_bus_volume_db(sfx_idx), 0.0)
			and is_equal_approx(AudioServer.get_bus_volume_db(voice_idx), 0.0), "DEFAULTS: every bus at 0 dB")
	# Sfx routing.
	var all_sfx := true
	for child: Node in Sfx.get_children():
		if (child is AudioStreamPlayer and (child as AudioStreamPlayer).bus != &"SFX") or (child is AudioStreamPlayer3D and (child as AudioStreamPlayer3D).bus != &"SFX"):
			all_sfx = false
	check(all_sfx and Sfx.get_child_count() >= Sfx.MAX_2D + Sfx.MAX_3D, "every Sfx voice plays on the SFX bus")
	var h2 := Sfx.play_loop(&"hum")
	var h3 := Sfx.play_loop(&"hum", Vector3(1.0, 1.0, 1.0))
	var l2 := Sfx.get_loop_player(h2)
	var l3 := Sfx.get_loop_player(h3)
	check(l2 is AudioStreamPlayer and (l2 as AudioStreamPlayer).bus == &"SFX" and l3 is AudioStreamPlayer3D and (l3 as AudioStreamPlayer3D).bus == &"SFX",
			"loops (2D and 3D) on the SFX bus")
	Sfx.stop_loop(h2, 0.0)
	Sfx.stop_loop(h3, 0.0)
	await Sfx.wait_until_ready()
	await wait_frames(2)
	Sfx.play(&"cough", Vector3.INF, -6.0)
	var last := Sfx.get_last_voice()
	check(last != null and String(last.get(&"bus")) == "SFX", "the spores' cough (Sfx.play) on the SFX bus")


# --- main menu -----------------------------------------------------------------------------------------------------------

func _menu() -> Control:
	return get_tree().get_first_node_in_group(Game.MENU_GROUP) as Control


func _section_main_menu() -> void:
	step("main menu: the version line and the OPTIONS card")
	if _menu() == null:
		get_tree().root.add_child((load(Game.MENU_SCENE_PATH) as PackedScene).instantiate())
	get_tree().root.size = Vector2i(1280, 720)
	await wait_frames(3)
	var menu := _menu()
	if not check(menu != null, "the main menu is up"):
		return
	var version: Label = menu.get(&"version_label")
	var title: Label = menu.get(&"title_label")
	check(version.text == "v" + Game.get_version() and version.text == "v" + String(ProjectSettings.get_setting("application/config/version")),
			"version line '%s'" % version.text)
	check(version.text.begins_with("v0.") and version.visible and version.theme_type_variation == &"SubtleLabel"
			and version.get_theme_font_size(&"font_size") <= 16, "small and grey (SubtleLabel, %d px)" % version.get_theme_font_size(&"font_size"))
	check(version.get_global_rect().position.y > title.get_global_rect().position.y + title.size.y * 0.5
			and absf(version.get_global_rect().get_center().x - title.get_global_rect().get_center().x) < 2.0, "under the title, centred")
	var column := menu.get_node(^"Center/Column") as Control
	check(get_viewport().get_visible_rect().encloses(column.get_global_rect()), "the menu still fits 1280 x 720 (%s)" % column.get_global_rect())
	check(String(menu.call(&"_settings_file")) == Settings.path, "the menu keeps name / ip / port in the Settings file")
	var options: OptionsCard = menu.get(&"options")
	var options_button: Button = menu.get(&"options_button")
	var center := menu.get_node(^"Center") as Control
	# Keyboard: walk to Options, Enter.
	options_button.grab_focus()
	await wait_frames(1)
	await _tap(KEY_ENTER)
	await wait_frames(2)
	check(options.is_open() and not center.visible and options.get_node(^"%Dim").visible, "Enter on Options: the card is up over its own dim, the menu hidden")
	check(_focus() == options.get_focus_chain()[0], "the first control has the keyboard (%s)" % _focus_name())
	var sens0 := float(Settings.get_value(&"mouse_sensitivity"))
	await _tap(KEY_RIGHT)
	check(float(Settings.get_value(&"mouse_sensitivity")) > sens0 + 0.0001, "Right on the mouse speed slider: faster (%.5f)" % float(Settings.get_value(&"mouse_sensitivity")))
	await _tap(KEY_LEFT)
	check(is_equal_approx(float(Settings.get_value(&"mouse_sensitivity")), sens0), "Left: back")
	await _tap(KEY_ESCAPE)
	check(not options.is_open() and center.visible, "Escape: back to the menu")
	await wait_frames(2)
	check(_focus() == options_button, "the keyboard is back on Options (%s)" % _focus_name())
	# Mouse: the button, then BACK.
	options_button.pressed.emit()
	await wait_frames(2)
	check(options.is_open(), "a click on Options opens it")
	await wait_sec(0.5)
	var card_rect := options.card.get_global_rect()
	check(get_viewport().get_visible_rect().encloses(card_rect) and card_rect.size.y <= 680.0, "the card fits 1280 x 720 (%s)" % card_rect)
	options.back_button.pressed.emit()
	await wait_frames(2)
	check(not options.is_open() and center.visible, "BACK closes it")
	check(Game.world == null and not Game.is_ui_locked(), "the menu needs no lock")


# --- host ------------------------------------------------------------------------------------------------------------------

func _host() -> bool:
	step("host a floor")
	if not check(Game.start_host("Settler", port) == OK, "hosting on port %d" % port):
		return false
	if not await wait_until(func() -> bool: return Game.local_player != null, 5.0, "world + local player"):
		return false
	hud = Game.world.get_node("HUD") as HUD
	get_tree().root.size = Vector2i(1280, 720)
	await wait_frames(3)
	return check(hud != null and GameState.phase == GameState.Phase.WAITING, "HUD up, WAITING")


func _section_routing() -> void:
	step("the radio's speakers play on the SFX bus")
	GameState.request_start_round()
	await wait_frames(3)
	var radios := Game.world.items.get_items_of_type(Const.ITEM_RADIO)
	var speakers := 0
	var on_sfx := 0
	for r: Node in radios:
		for n: String in ["RadioClick", "RadioStatic"]:
			var p := r.get_node_or_null(NodePath(n)) as AudioStreamPlayer3D
			if p != null:
				speakers += 1
				if p.bus == &"SFX":
					on_sfx += 1
	check(radios.size() >= 1 and speakers == radios.size() * 2 and on_sfx == speakers, "%d radios, %d speakers on SFX of %d" % [radios.size(), on_sfx, speakers])


func _section_player() -> void:
	step("the player: field of view, mouse speed, invert Y")
	var p: Player = Game.local_player
	var vm := p.get_view_model_camera()
	check(is_equal_approx(p.camera.fov, 80.0) and vm != null and is_equal_approx(vm.fov, 80.0), "spawned with fov 80 on both cameras")
	Settings.set_value(&"fov", 95.0)
	check(is_equal_approx(p.camera.fov, 95.0) and is_equal_approx(vm.fov, 95.0), "fov 95: the camera and the view-model camera at once")
	Settings.set_value(&"fov", 61.0)
	await wait_frames(2)
	check(is_equal_approx(p.camera.fov, 61.0) and is_equal_approx(vm.fov, 61.0), "fov 61 on both, a frame later too")
	var sens := float(Settings.get_value(&"mouse_sensitivity"))
	p.rotation.y = 0.0
	p.head.rotation.x = 0.0
	p.apply_look_input(Vector2(100.0, 0.0))
	check(is_equal_approx(p.rotation.y, -100.0 * sens), "100 px right turns %.3f rad (the default speed)" % p.rotation.y)
	Settings.set_value(&"mouse_sensitivity", sens * 2.0)
	p.rotation.y = 0.0
	p.apply_look_input(Vector2(100.0, 0.0))
	check(is_equal_approx(p.rotation.y, -200.0 * sens), "twice the speed turns twice as far (%.3f)" % p.rotation.y)
	p.apply_look_input(Vector2(0.0, 50.0))
	var down := p.head.rotation.x
	check(down < -0.01, "mouse down looks down (%.3f)" % down)
	p.head.rotation.x = 0.0
	Settings.set_value(&"invert_y", true)
	p.apply_look_input(Vector2(0.0, 50.0))
	check(is_equal_approx(p.head.rotation.x, -down), "invert Y: mouse down looks up (%.3f)" % p.head.rotation.x)
	p.head.rotation.x = 0.0
	p.rotation.y = 0.0
	Settings.reset_to_defaults()
	check(is_equal_approx(p.camera.fov, 80.0), "DEFAULTS: fov 80 again")
	# The back room's spectator camera keeps its own.
	Settings.set_value(&"fov", 99.0)
	var br: Node = hud.get(&"back_room")
	var spec: Camera3D = br.call(&"get_spectator_camera") if br != null and br.has_method(&"get_spectator_camera") else null
	if spec != null:
		check(not is_equal_approx(spec.fov, 99.0), "the back room's camera keeps its own (%.0f)" % spec.fov)
	else:
		check(br != null, "the back room overlay is there (its camera is made when it opens; it sets its own fov)")
	Settings.reset_to_defaults()


func _section_pause_options() -> void:
	step("OPTIONS from the pause menu, keyboard only")
	var pm: PauseMenu = hud.pause_menu
	var options: OptionsCard = pm.options
	check(pm.controls_label.text == PauseMenu.TEXT_CONTROLS_POINTER and pm.controls_label.text == "Keys, mouse, screen and sound: OPTIONS.",
			"the ON BREAK card points at OPTIONS ('%s')" % pm.controls_label.text)
	var keys := options.get_key_texts()
	check(keys.has("1-4 gestures") and keys.has("WASD move") and keys.has("RMB throw") and keys.has("V talk") and keys.has("ESC break")
			and keys.size() == OptionsCard.KEY_ROWS.size(), "the key list (%s)" % ", ".join(keys))
	for t: String in keys:
		check(not t.contains("!"), "flat: '%s'" % t)
	await _tap(KEY_ESCAPE)
	check(pm.is_open() and _focus() == pm.resume_button, "Escape: ON BREAK, BACK TO WORK focused (%s)" % _focus_name())
	await _tap(KEY_DOWN)
	check(_focus() == pm.options_button, "Down: OPTIONS (%s)" % _focus_name())
	await _tap(KEY_DOWN)
	check(_focus() == pm.leave_button, "Down: CLOCK OUT (%s)" % _focus_name())
	await _tap(KEY_DOWN)
	check(_focus() == pm.resume_button, "Down wraps to BACK TO WORK (%s)" % _focus_name())
	for key: Key in [KEY_TAB, KEY_TAB, KEY_TAB, KEY_UP, KEY_LEFT, KEY_RIGHT]:
		await _tap(key)
		if not _is_under(_focus(), pm.card):
			break
	check(_is_under(_focus(), pm.card), "Tab / arrows stay inside the ON BREAK card (%s)" % _focus_name())
	pm.options_button.grab_focus()
	await wait_frames(1)
	await _tap(KEY_ENTER)
	await wait_frames(2)
	check(options.is_open() and pm.is_open() and not pm.card.is_visible_in_tree() and not pm.record_card.visible, "Enter: the OPTIONS card, the ON BREAK card hidden")
	check(not options.get_node(^"%Dim").visible and Game.is_ui_locked_by(PauseMenu.LOCK_SOURCE), "no second dim; the break still holds the lock")
	check(_focus() == options.get_focus_chain()[0], "mouse speed has the keyboard (%s)" % _focus_name())
	await wait_sec(0.5)
	var card_rect := options.card.get_global_rect()
	check(get_viewport().get_visible_rect().encloses(card_rect) and card_rect.size.y <= 680.0, "the card fits 1280 x 720 (%s)" % card_rect)
	# The whole loop: Tab visits every control once and comes back; nothing outside the card.
	var chain := options.get_focus_chain()
	var visited: Array[Control] = []
	for i in chain.size():
		await _tap(KEY_TAB)
		visited.append(_focus())
	check(visited.back() == chain[0] and _all_under(visited, options.card), "Tab walks the %d controls and wraps, inside the card" % chain.size())
	var in_order := true
	for i in chain.size() - 1:
		if visited[i] != chain[i + 1]:
			in_order = false
	check(in_order, "in order: left column, right column, DEFAULTS, BACK")
	await _tap(KEY_UP)
	check(_focus() == options.back_button, "Up from the first: BACK (%s)" % _focus_name())
	await _tap(KEY_LEFT)
	check(_focus() == options.defaults_button, "Left: DEFAULTS (%s)" % _focus_name())
	# fov with the arrows: down twice from the top.
	chain[0].grab_focus()
	await wait_frames(1)
	await _tap(KEY_DOWN)
	await _tap(KEY_DOWN)
	check(_focus() == options.fov_slider, "Down, Down: field of view (%s)" % _focus_name())
	await _tap(KEY_RIGHT)
	await _tap(KEY_RIGHT)
	check(is_equal_approx(float(Settings.get_value(&"fov")), 82.0) and is_equal_approx(Game.local_player.camera.fov, 82.0)
			and options.get_value_texts()["fov"] == "82", "Right, Right: fov 82, the camera follows at once")
	# A toggle with Enter.
	await _tap(KEY_UP)
	check(_focus() == options.invert_toggle, "Up: invert (%s)" % _focus_name())
	await _tap(KEY_ENTER)
	check(Settings.get_value(&"invert_y") == true and options.invert_toggle.button_pressed, "Enter turns invert Y on")
	# The window-size buttons with left / right.
	options.scale_buttons[0].grab_focus()
	await wait_frames(1)
	await _tap(KEY_RIGHT)
	check(_focus() == options.scale_buttons[1], "Right walks the window sizes (%s)" % _focus_name())
	await _tap(KEY_ENTER)
	check(is_equal_approx(float(Settings.get_value(&"window_scale")), 1.5) and options.get_value_texts()["window"] == "1920 x 1080", "Enter on 1.5x: 1920 x 1080")
	options.fullscreen_toggle.button_pressed = true
	await wait_frames(1)
	check(Settings.get_value(&"fullscreen") == true and options.scale_buttons[0].disabled and options.get_value_texts()["window"] == "", "fullscreen: no window sizes")
	# A volume slider and the ON BREAK card's own voice slider: two views of one value.
	options.voice_slider.grab_focus()
	await wait_frames(1)
	await _tap(KEY_LEFT)
	check(is_equal_approx(float(Settings.get_value(&"voice_db")), -1.0) and is_equal_approx(Voice.output_volume_db, -1.0), "Left on Voices: -1 dB on the Voice bus")
	# DEFAULTS with the keyboard.
	options.defaults_button.grab_focus()
	await wait_frames(1)
	await _tap(KEY_ENTER)
	var all_default := true
	for key: StringName in Settings.get_keys():
		if Settings.is_set(key):
			all_default = false
	check(all_default and is_equal_approx(options.fov_slider.value, 80.0) and not options.invert_toggle.button_pressed
			and options.scale_buttons[0].button_pressed and not options.scale_buttons[0].disabled, "DEFAULTS: every value and widget back")
	check(is_equal_approx(Game.local_player.camera.fov, 80.0), "the camera too")
	# Escape: back to the ON BREAK card with OPTIONS focused; the pause menu stays.
	await _tap(KEY_ESCAPE)
	check(not options.is_open() and pm.is_open() and pm.card.is_visible_in_tree(), "Escape: back to ON BREAK")
	await wait_frames(2)
	check(_focus() == pm.options_button, "the keyboard is on OPTIONS (%s)" % _focus_name())
	check(pm.record_card.visible == Config.replay_enabled, "the Record card as before (replay %s)" % Config.replay_enabled)
	# The ON BREAK card's Sound toggle and voice slider are views of the settings.
	Settings.set_value(&"voice_db", -8.0)
	Settings.set_value(&"muted", true)
	pm.sync_voice_controls()
	check(is_equal_approx(pm.volume_slider.value, -8.0) and not pm.sound_toggle.button_pressed, "ON BREAK shows -8 dB and Sound off")
	pm.volume_slider.value = -3.0
	pm.sound_toggle.button_pressed = true
	check(is_equal_approx(float(Settings.get_value(&"voice_db")), -3.0) and Settings.get_value(&"muted") == false and not AudioServer.is_bus_mute(0),
			"and write them back")
	Settings.reset_to_defaults()
	# Closing the menu takes the card with it.
	pm.open_options()
	await wait_frames(1)
	check(options.is_open(), "OPTIONS open again")
	pm.close()
	await wait_frames(2)
	check(not options.is_open() and not pm.is_open() and not Game.is_ui_locked(), "closing the break closes the card and frees the lock")
	await _tap(KEY_ESCAPE)
	check(pm.is_open() and not options.is_open() and pm.card.is_visible_in_tree(), "the next Escape opens ON BREAK, not the card")
	await _tap(KEY_ESCAPE)
	check(not pm.is_open() and not Game.is_ui_locked(), "and Escape closes it")


func _section_back_to_menu() -> void:
	step("back to the menu")
	if Game.world != null:
		Game.return_to_menu()
		await wait_frames(3)
	check(Game.world == null and not Game.is_ui_locked(), "in the menu, no lock")
	check(Settings.persistent and Settings.get_write_count() > 0, "this run wrote only its test file (%d writes to %s)" % [Settings.get_write_count(), Settings.path])


# --- helpers -----------------------------------------------------------------------------------------------------------

func _scratch_path(tag: String) -> String:
	var p := "user://settings_test_%d_%s.cfg" % [port, tag]
	_scratch.append(p)
	return p


func _write_bytes(path: String, bytes: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)
		f.close()


func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _cleanup() -> void:
	for p in _scratch:
		_remove(p)
	Settings.set(&"persistent", false) # nothing more is written to the test file
	_remove(Settings.path)
	_remove(Settings.path + ".tmp")


func _key(code: Key, pressed: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = pressed
	get_viewport().push_input(ev)


func _tap(code: Key) -> void:
	_key(code, true)
	_key(code, false)
	await wait_frames(2)


func _focus() -> Control:
	return get_viewport().gui_get_focus_owner()


func _focus_name() -> String:
	var f := _focus()
	return "<none>" if f == null else String(f.name)


static func _is_under(node: Node, ancestor: Node) -> bool:
	return node != null and ancestor != null and (node == ancestor or ancestor.is_ancestor_of(node))


static func _all_under(nodes: Array[Control], ancestor: Node) -> bool:
	for n in nodes:
		if not _is_under(n, ancestor):
			return false
	return true
