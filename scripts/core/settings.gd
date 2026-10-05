extends Node
## Settings (autoload, M19, owner: settings agent). The player's own preferences: controls, video, audio and the
## onboarding guidance. Kept on this machine and never synced (nothing here is an RPC: every peer reads its own file).
## CONTRACTS.md "M19" / "Settings". Do NOT add a class_name (it is an autoload).
##
## The file: `user://settings.cfg`, or the path given with `--settings-file=<path>` (tests always pass one). The main
## menu keeps name / ip / port in its own section [menu] of the same file (scenes/main_menu/main_menu.gd, ConfigFile):
## this autoload owns the sections [controls], [video], [audio] and [game] and copies every other line of the file,
## byte for byte, when it writes. WITHOUT --settings-file, a run under --headless or one started with `-s <script>`
## (the suites, the capture and preview tools) reads nothing and writes nothing (Career's rule): the values live in
## memory only, at their defaults.
##
##   [controls]  mouse_sensitivity (radians per pixel; default Config.balance.mouse_sensitivity), invert_y
##   [video]     fov (60..100: the player's camera and its view-model camera; the back room keeps its own), fullscreen,
##               window_scale (1, 1.5 or 2 times the 1280 x 720 viewport, windowed), vsync
##   [audio]     master_db, sfx_db, voice_db (-30..6 dB on the buses Master / SFX / Voice), muted (the Sound toggle)
##   [game]      guidance (the guided first shift: default on while Career has no shift worked, then off)
##
## Only values that were set are written; a key that is not in the file reads as its default. Read at start; written
## at the end of the frame in which a value changed, through "<file>.tmp" and a rename. A missing, empty, oversized or
## damaged file, an unknown key, a value of the wrong type and an out-of-range value all read as the default and never
## print an error line (a small parser of our own: ConfigFile.load prints one for a parse error; damaged lines in our
## sections are dropped by the next write, which a persistent start makes at once). set_value() clamps instead.
##
## Applied at once: the buses here (Master volume + mute; Sfx.volume_db, which Sfx puts on its SFX bus; Voice's output
## volume without writing voice.cfg); the window here (fullscreen, size, vsync). The player reads mouse_sensitivity and
## invert_y on every look and sets its camera's fov from `changed`; the onboarding guide reads guidance.
## Command-line overrides win and are never saved: `--mute` keeps the Master bus muted whatever `muted` says; the
## engine's own window arguments (--fullscreen, --windowed, --resolution, ...) keep the window as asked at start.
## Migrated once (the game with its own user://settings.cfg, never a --settings-file run; [game] migrated=true goes
## into the file with the next write): the old Sound toggle (user://audio.cfg [audio] muted) and the old voice volume
## (user://voice.cfg [voice] output_volume_db), unless the value is already set.

## Emitted after a value's effective value changed and was applied (`key` is its name, e.g. &"fov").
signal changed(key: StringName)

const DEFAULT_PATH := "user://settings.cfg"
## A file larger than this is not a settings file (read as empty).
const MAX_FILE_BYTES: int = 65536
## The sections this autoload owns, in the order they are written.
const SECTIONS: PackedStringArray = ["controls", "video", "audio", "game"]
const KEY_MIGRATED := "migrated"

const SENSITIVITY_MIN: float = 0.0005
const SENSITIVITY_MAX: float = 0.01
const FOV_MIN: float = 60.0
const FOV_MAX: float = 100.0
const VOLUME_MIN_DB: float = -30.0
const VOLUME_MAX_DB: float = 6.0
## The window sizes offered (times the project's viewport size, 1280 x 720).
const WINDOW_SCALES: Array[float] = [1.0, 1.5, 2.0]

## Every key with its default. mouse_sensitivity's real default is Config.balance.mouse_sensitivity and guidance's is
## "no shift worked yet" (get_default); these are the values before the autoloads are up.
const DEFAULTS := {
	&"mouse_sensitivity": 0.0025,
	&"invert_y": false,
	&"fov": 80.0,
	&"master_db": 0.0,
	&"sfx_db": 0.0,
	&"voice_db": 0.0,
	&"muted": false,
	&"fullscreen": false,
	&"window_scale": 1.0,
	&"vsync": true,
	&"guidance": true,
}

## key -> [section, type, min, max] (min / max for floats only).
const SPECS := {
	&"mouse_sensitivity": ["controls", TYPE_FLOAT, SENSITIVITY_MIN, SENSITIVITY_MAX],
	&"invert_y": ["controls", TYPE_BOOL],
	&"fov": ["video", TYPE_FLOAT, FOV_MIN, FOV_MAX],
	&"fullscreen": ["video", TYPE_BOOL],
	&"window_scale": ["video", TYPE_FLOAT, 1.0, 2.0],
	&"vsync": ["video", TYPE_BOOL],
	&"master_db": ["audio", TYPE_FLOAT, VOLUME_MIN_DB, VOLUME_MAX_DB],
	&"sfx_db": ["audio", TYPE_FLOAT, VOLUME_MIN_DB, VOLUME_MAX_DB],
	&"voice_db": ["audio", TYPE_FLOAT, VOLUME_MIN_DB, VOLUME_MAX_DB],
	&"muted": ["audio", TYPE_BOOL],
	&"guidance": ["game", TYPE_BOOL],
}

## The order keys are written and applied in.
const KEY_ORDER: Array[StringName] = [&"mouse_sensitivity", &"invert_y", &"fov", &"fullscreen", &"window_scale",
	&"vsync", &"master_db", &"sfx_db", &"voice_db", &"muted", &"guidance"]
const DISPLAY_KEYS: Array[StringName] = [&"fullscreen", &"window_scale", &"vsync"]
## Engine arguments that set the window: with any of them the window is left as asked at start.
const ENGINE_WINDOW_ARGS: PackedStringArray = ["-f", "--fullscreen", "-w", "--windowed", "-m", "--maximized",
	"--resolution", "--position", "--screen", "-t", "--always-on-top"]

## The file this player's settings live in.
var path: String = DEFAULT_PATH
## False under --headless or `-s <script>` without --settings-file: nothing is read or written.
var persistent: bool = false

## The values that were set (key -> value); a key that is not here reads as its default.
var _values: Dictionary = {}
## The effective value of every key as last applied (changed is emitted when one moves).
var _effective: Dictionary = {}
var _migrated: bool = false
var _save_queued: bool = false
var _writes: int = 0
var _save_warned: bool = false
## `--mute` on the command line: the Master bus stays muted, and that is never saved.
var _forced_mute: bool = false
## The engine was told how to open the window: the settings do not move it at start.
var _window_locked: bool = false
## What was last asked of the window (also recorded under --headless, where nothing is done): tests and captures.
var _display: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var storage := decide_storage(Config.user_args, DisplayServer.get_name() == "headless", _is_scripted_run())
	path = String(storage["path"])
	persistent = bool(storage["persistent"])
	_forced_mute = Config.has_arg("mute")
	_window_locked = _engine_window_args()
	var rewrite := false
	if persistent:
		var parsed := parse_bytes(_read_bytes(path))
		_values = parsed["values"]
		_migrated = bool(parsed["migrated"])
		rewrite = int(parsed["junk"]) > 0
		if not _migrated and path == DEFAULT_PATH: # the player's own file only: a --settings-file run never reads them
			rewrite = migrate_legacy(Config.AUDIO_CFG, String(Voice.get(&"settings_path"))) or rewrite
	for key in KEY_ORDER:
		_effective[key] = get_value(key)
	_apply_audio()
	if persistent and not _window_locked and _has_display_values():
		_apply_window()
		_apply_vsync()
	if Career.has_signal(&"changed"):
		Career.changed.connect(_refresh)
	if rewrite:
		_queue_save()


func _exit_tree() -> void:
	if _save_queued:
		_flush()


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## The value for `key` (`default` when the key is unknown).
func get_value(key: StringName, default: Variant = null) -> Variant:
	if not SPECS.has(key):
		return default
	if _values.has(key):
		return _values[key]
	return get_default(key)


## Sets `key` (clamped into its range; a window_scale snaps to 1, 1.5 or 2), applies it and saves at the end of the
## frame. An unknown key or a value of the wrong type is ignored.
func set_value(key: StringName, value: Variant) -> void:
	if not SPECS.has(key):
		return
	var clean: Variant = sanitize(key, value)
	if clean == null:
		return
	if _values.has(key) and _values[key] == clean:
		return
	_values[key] = clean
	_refresh()
	_queue_save()


## Every value back to its default (the file keeps only the main menu's section and the migration mark).
func reset_to_defaults() -> void:
	if _values.is_empty():
		return
	_values.clear()
	_refresh()
	_queue_save()


## The default of `key` (null when the key is unknown).
func get_default(key: StringName) -> Variant:
	match key:
		&"mouse_sensitivity":
			var b: Variant = Config.get(&"balance") if is_inside_tree() else null
			if b != null:
				return clampf(float(b.mouse_sensitivity), SENSITIVITY_MIN, SENSITIVITY_MAX)
		&"guidance":
			if is_inside_tree() and Career.has_method(&"get_record"):
				return int(Career.call(&"get_record", "shifts")) <= 0
	return DEFAULTS.get(key)


## Every key, in the order it is written.
func get_keys() -> Array[StringName]:
	return KEY_ORDER.duplicate()


## True when `key` was set (it is in the file); false when it reads as its default.
func is_set(key: StringName) -> bool:
	return _values.has(key)


## [min, max] of a float key (Vector2.ZERO for a bool or an unknown key).
func get_range(key: StringName) -> Vector2:
	var spec: Array = SPECS.get(key, [])
	if spec.size() < 4:
		return Vector2.ZERO
	return Vector2(float(spec[2]), float(spec[3]))


## True while `--mute` holds the Master bus muted (the Sound toggles show it and cannot change it).
func is_mute_forced() -> bool:
	return _forced_mute


## Writes the file now when this run keeps one. False when nothing was written.
func save_now() -> bool:
	_save_queued = false
	if not persistent:
		return false
	return _write_file()


## Reads `file_path` in place of the current values (applied, `changed` for every value that moved). Returns the
## number of damaged lines in our sections (0 for a clean, empty or missing file). Never logs an error.
func load_file(file_path: String) -> int:
	var parsed := parse_bytes(_read_bytes(file_path))
	_values = parsed["values"]
	_migrated = bool(parsed["migrated"])
	_refresh()
	return int(parsed["junk"])


## Files actually written in this run (tests: nothing is written without --settings-file).
func get_write_count() -> int:
	return _writes


## What was last asked of the window: {fullscreen, size, vsync} (empty until something was applied).
func get_display_state() -> Dictionary:
	return _display.duplicate()


## The window size for `scale` (the project's viewport size times it).
static func window_size_for(scale: float) -> Vector2i:
	var w := int(ProjectSettings.get_setting("display/window/size/viewport_width", 1280))
	var h := int(ProjectSettings.get_setting("display/window/size/viewport_height", 720))
	return Vector2i(roundi(w * scale), roundi(h * scale))


## Where the settings live and whether they are kept, from the user args (`settings-file`), a headless display and a
## `-s` run. {path, persistent}.
static func decide_storage(args: Dictionary, headless: bool, scripted: bool) -> Dictionary:
	var given: Variant = args.get("settings-file", null)
	if given is String and String(given).strip_edges() != "":
		return {"path": String(given).strip_edges(), "persistent": true}
	return {"path": DEFAULT_PATH, "persistent": not headless and not scripted}


## `value` made fit for `key`: clamped into the range, window_scale snapped to the nearest size; null when it is not a
## value of the key's type (or the key is unknown).
static func sanitize(key: StringName, value: Variant) -> Variant:
	var spec: Array = SPECS.get(key, [])
	if spec.is_empty():
		return null
	if int(spec[1]) == TYPE_BOOL:
		if value is bool:
			return value
		if value is int and (int(value) == 0 or int(value) == 1):
			return int(value) == 1
		return null
	if not (value is float or value is int):
		return null
	var f := float(value)
	if not is_finite(f):
		return null
	f = clampf(f, float(spec[2]), float(spec[3]))
	if key == &"window_scale":
		var best := WINDOW_SCALES[0]
		for s in WINDOW_SCALES:
			if absf(s - f) < absf(best - f):
				best = s
		f = best
	return f


## Reads our sections out of a settings file's bytes. {values: {key: value}, junk: damaged lines in our sections,
## migrated: bool}. Lines of other sections ([menu]) are not looked at.
static func parse_bytes(bytes: PackedByteArray) -> Dictionary:
	var values := {}
	var junk := 0
	var migrated := false
	var section := ""
	for raw: PackedByteArray in _split_lines(bytes):
		var line := _ascii(raw).strip_edges()
		if line == "" or line.begins_with(";") or line.begins_with("#"):
			continue
		if line.begins_with("["):
			section = line.substr(1, line.length() - 2).strip_edges() if line.ends_with("]") else ""
			continue
		if not SECTIONS.has(section):
			continue
		var eq := line.find("=")
		if eq <= 0:
			junk += 1
			continue
		var name := line.substr(0, eq).strip_edges()
		var text := line.substr(eq + 1).strip_edges()
		if section == "game" and name == KEY_MIGRATED:
			migrated = text == "true"
			continue
		var key := StringName(name)
		var spec: Array = SPECS.get(key, [])
		if spec.is_empty() or String(spec[0]) != section:
			junk += 1
			continue
		var value: Variant = _read_value(key, text)
		if value == null:
			junk += 1
			continue
		values[key] = value
	return {"values": values, "junk": junk, "migrated": migrated}


## Text form of parse_bytes() (tests).
static func parse_text(text: String) -> Dictionary:
	return parse_bytes(text.to_utf8_buffer())


## The new file: every line of `existing` outside our sections as it was (byte for byte), then our sections with the
## set values (`values`) and the migration mark.
static func build_bytes(existing: PackedByteArray, values: Dictionary, migrated: bool) -> PackedByteArray:
	var kept: Array[PackedByteArray] = []
	var ours := false
	for raw: PackedByteArray in _split_lines(existing):
		var line := _ascii(raw).strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			ours = SECTIONS.has(line.substr(1, line.length() - 2).strip_edges())
		if not ours:
			kept.append(raw)
	while not kept.is_empty() and _ascii(kept[kept.size() - 1]).strip_edges() == "":
		kept.pop_back()
	var out := PackedByteArray()
	for i in kept.size():
		if i > 0:
			out.append(10)
		out.append_array(kept[i])
	for section in SECTIONS:
		var lines := PackedStringArray()
		for key in KEY_ORDER:
			if String(SPECS[key][0]) == section and values.has(key):
				lines.append("%s=%s" % [key, var_to_str(values[key])])
		if section == "game" and migrated:
			lines.append("%s=true" % KEY_MIGRATED)
		if lines.is_empty():
			continue
		if not out.is_empty():
			out.append_array("\n\n".to_ascii_buffer())
		out.append_array(("[%s]\n%s" % [section, "\n".join(lines)]).to_ascii_buffer())
	if not out.is_empty():
		out.append(10)
	return out


## Text form of build_bytes() (tests).
static func build_text(existing: String, values: Dictionary, migrated: bool) -> String:
	return build_bytes(existing.to_utf8_buffer(), values, migrated).get_string_from_utf8()


## Moves the old preferences in once: the Sound toggle's mute (`audio_cfg`, [audio] muted) and the voice volume
## (`voice_cfg`, [voice] output_volume_db), unless the value is already set here. True when something moved.
func migrate_legacy(audio_cfg: String, voice_cfg: String) -> bool:
	var moved := false
	if audio_cfg != "" and FileAccess.file_exists(audio_cfg) and not _values.has(&"muted"):
		var cfg := ConfigFile.new()
		if cfg.load(audio_cfg) == OK and cfg.get_value("audio", "muted", false) is bool and bool(cfg.get_value("audio", "muted", false)):
			_values[&"muted"] = true
			moved = true
	if voice_cfg != "" and FileAccess.file_exists(voice_cfg) and not _values.has(&"voice_db"):
		var cfg := ConfigFile.new()
		if cfg.load(voice_cfg) == OK and cfg.has_section_key("voice", "output_volume_db"):
			var db: Variant = sanitize(&"voice_db", cfg.get_value("voice", "output_volume_db", 0.0))
			if db != null and not is_equal_approx(float(db), float(DEFAULTS[&"voice_db"])):
				_values[&"voice_db"] = db
				moved = true
	_migrated = true
	if moved and is_inside_tree() and not _effective.is_empty():
		_refresh()
	return moved


# ---------------------------------------------------------------------------------------------
# Applying
# ---------------------------------------------------------------------------------------------

## Re-reads every effective value; each one that moved is applied, then announced with `changed`.
func _refresh() -> void:
	var moved: Array[StringName] = []
	for key in KEY_ORDER:
		var now: Variant = get_value(key)
		if _effective.has(key) and _effective[key] == now:
			continue
		_effective[key] = now
		moved.append(key)
	if moved.is_empty():
		return
	var audio := false
	var window := false
	for key in moved:
		match key:
			&"master_db", &"muted", &"sfx_db", &"voice_db":
				audio = true
			&"fullscreen", &"window_scale":
				window = true
			&"vsync":
				_apply_vsync()
	if audio:
		_apply_audio()
	if window:
		_apply_window()
	for key in moved:
		changed.emit(key)


func _apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, float(get_value(&"master_db")))
	AudioServer.set_bus_mute(0, bool(get_value(&"muted")) or _forced_mute)
	Sfx.volume_db = float(get_value(&"sfx_db")) # Sfx puts it on its SFX bus (or on each player without one)
	if Voice.has_method(&"apply_settings_volume"):
		Voice.call(&"apply_settings_volume", float(get_value(&"voice_db")))


func _apply_window() -> void:
	var fullscreen := bool(get_value(&"fullscreen"))
	var size := window_size_for(float(get_value(&"window_scale")))
	_display["fullscreen"] = fullscreen
	_display["size"] = size
	if DisplayServer.get_name() == "headless":
		return
	var mode := DisplayServer.window_get_mode()
	if fullscreen:
		if mode != DisplayServer.WINDOW_MODE_FULLSCREEN and mode != DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		return
	if mode != DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	# Fit the window and its frame inside the screen's usable area (a 2x window on a 1080p screen comes out smaller).
	var usable := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
	var frame := DisplayServer.window_get_size_with_decorations() - DisplayServer.window_get_size()
	frame = Vector2i(maxi(frame.x, 0), maxi(frame.y, 0))
	if usable.size.x > frame.x and usable.size.y > frame.y:
		var room := usable.size - frame
		var k := minf(1.0, minf(float(room.x) / size.x, float(room.y) / size.y))
		size = Vector2i(floori(size.x * k), floori(size.y * k))
	DisplayServer.window_set_size(size)
	_display["size"] = size
	if usable.size.x > 0 and usable.size.y > 0:
		var client_offset := DisplayServer.window_get_position() - DisplayServer.window_get_position_with_decorations()
		var outer := size + frame
		DisplayServer.window_set_position(usable.position + (usable.size - outer) / 2 + client_offset)


func _apply_vsync() -> void:
	var on := bool(get_value(&"vsync"))
	_display["vsync"] = on
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if on else DisplayServer.VSYNC_DISABLED)


func _has_display_values() -> bool:
	for key in DISPLAY_KEYS:
		if _values.has(key):
			return true
	return false


static func _engine_window_args() -> bool:
	for arg in OS.get_cmdline_args():
		if ENGINE_WINDOW_ARGS.has(arg):
			return true
	return false


## True when the engine was started with a main-loop script (`-s` / `--script`): a test body or a tool, not the game.
static func _is_scripted_run() -> bool:
	for arg in OS.get_cmdline_args():
		if arg == "-s" or arg == "--script":
			return true
	return false


# ---------------------------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------------------------

func _queue_save() -> void:
	if not persistent or _save_queued:
		return
	_save_queued = true
	_flush.call_deferred()


func _flush() -> void:
	if not _save_queued:
		return
	_save_queued = false
	if persistent:
		_write_file()


## Writes our sections into `path` (the rest of the file as it is on disk now) through "<file>.tmp" and a rename.
func _write_file() -> bool:
	var data := build_bytes(_read_bytes(path), _values, _migrated)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_warn_save("could not write %s (%s)" % [tmp, error_string(FileAccess.get_open_error())])
		return false
	f.store_buffer(data)
	f.close()
	if DirAccess.rename_absolute(tmp, path) != OK:
		# The rename did not go through (a locked file): write in place and drop the temp file.
		var direct := FileAccess.open(path, FileAccess.WRITE)
		if direct == null:
			_warn_save("could not write %s" % path)
			DirAccess.remove_absolute(tmp)
			return false
		direct.store_buffer(data)
		direct.close()
		DirAccess.remove_absolute(tmp)
	_writes += 1
	return true


func _warn_save(text: String) -> void:
	if not _save_warned:
		_save_warned = true
		push_warning("Settings: " + text)


static func _read_bytes(file_path: String) -> PackedByteArray:
	if file_path == "" or not FileAccess.file_exists(file_path):
		return PackedByteArray()
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var length := f.get_length()
	if length <= 0 or length > MAX_FILE_BYTES:
		f.close()
		return PackedByteArray()
	var bytes := f.get_buffer(length)
	f.close()
	return bytes


static func _split_lines(bytes: PackedByteArray) -> Array[PackedByteArray]:
	var out: Array[PackedByteArray] = []
	if bytes.is_empty():
		return out
	var start := 0
	for i in bytes.size():
		if bytes[i] == 10:
			out.append(bytes.slice(start, i))
			start = i + 1
	if start < bytes.size():
		out.append(bytes.slice(start))
	return out


## The printable ASCII of a line (a tab reads as a space; anything else is dropped): never a decode error.
static func _ascii(line: PackedByteArray) -> String:
	var chars := PackedStringArray()
	for b: int in line:
		if b >= 32 and b < 127:
			chars.append(String.chr(b))
		elif b == 9:
			chars.append(" ")
	return "".join(chars)


## A float or bool from the file, or null when it is not one, is out of range (a window_scale must be one of the
## sizes) or is not finite.
static func _read_value(key: StringName, text: String) -> Variant:
	var spec: Array = SPECS[key]
	if int(spec[1]) == TYPE_BOOL:
		if text == "true":
			return true
		if text == "false":
			return false
		return null
	if text.length() > 24 or not (text.is_valid_float() or text.is_valid_int()):
		return null
	var f := text.to_float()
	if not is_finite(f) or f < float(spec[2]) or f > float(spec[3]):
		return null
	if key == &"window_scale":
		for s in WINDOW_SCALES:
			if absf(s - f) < 0.001:
				return s
		return null
	return f
