extends "res://tools/tests/smoke_base.gd"
## QA test body base (milestone 7, owner: QA). Adds to smoke_base.gd:
##   - an engine/script error counter (OS.add_logger): every ERROR / SCRIPT ERROR logged while the body runs
##     fails the run unless it was announced with expect_error("substring") right before it happens;
##   - canonical_state(): a deterministic one-line description of the replicated game state (players,
##     player nodes, GameState, every item with holder/props/rest position, every grow plot) that must be
##     identical on every peer once the network settled (used to hunt desyncs);
##   - a toast recorder (Game.toast_requested) so tests can assert denial messages seen by this peer;
##   - "RESULT: PASS|FAIL" as the last line and exit code 0/1 (2 = watchdog timeout).
## Launch bodies through the generic launcher:
##   godot --headless --path . -s res://tools/tests/run_test.gd -- --body=res://tools/tests/<body>.gd [...]

class ErrorCounter extends Logger:
	## Unexpected errors: "code | rationale | file:line function" (+ " [script]" when GDScript frames were on the stack).
	var errors: PackedStringArray = []
	## Substrings of errors that MUST happen (consumed when matched).
	var expected: PackedStringArray = []
	var expected_seen: int = 0
	## Optional allowances: [substring, remaining count, engine_only]. engine_only = no GDScript frame on the stack.
	var allowed: Array = []
	var allowed_seen: int = 0
	var _mutex := Mutex.new()

	func _log_error(function: String, file: String, line: int, code: String, rationale: String,
			_editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
		if error_type == Logger.ERROR_TYPE_WARNING:
			return
		var from_script := false
		for bt in script_backtraces:
			if bt != null and not bt.is_empty():
				from_script = true
		var text := "%s | %s | %s:%d %s%s" % [code, rationale, file, line, function, " [script]" if from_script else ""]
		_mutex.lock()
		for i in expected.size():
			if text.contains(expected[i]):
				expected.remove_at(i)
				expected_seen += 1
				_mutex.unlock()
				return
		for a in allowed:
			if int(a[1]) > 0 and text.contains(String(a[0])) and not (bool(a[2]) and from_script):
				a[1] = int(a[1]) - 1
				allowed_seen += 1
				_mutex.unlock()
				return
		errors.append(text)
		_mutex.unlock()

	func _log_message(_message: String, _error: bool) -> void:
		pass

## Seconds before the watchdog fails the run (override per body with --timeout=N).
var watchdog_sec: float = 240.0
var errors: ErrorCounter = null
## Every toast this peer showed: [text, kind].
var toasts: Array = []

var _start_msec: int = 0

func _ready() -> void:
	_start_msec = Time.get_ticks_msec()
	watchdog_sec = float(Config.get_arg("timeout", watchdog_sec))
	errors = ErrorCounter.new()
	OS.add_logger(errors)
	Game.toast_requested.connect(func(text: String, kind: StringName) -> void: toasts.append([text, kind]))
	super()

func _process(_delta: float) -> void:
	if not _finished and Time.get_ticks_msec() - _start_msec > watchdog_sec * 1000.0:
		check(false, "watchdog: test did not finish within %.0f s" % watchdog_sec)
		_finish_with(2)

## Announce an engine/script error that the next action is expected to log (substring of code/rationale/file).
func expect_error(substring: String) -> void:
	print("  (expected error next: %s)" % substring)
	errors._mutex.lock()
	errors.expected.append(substring)
	errors._mutex.unlock()

## Tolerate up to `max_count` errors containing `substring` from now on (they may or may not happen).
## engine_only: only errors raised with no GDScript frame on the stack (i.e. not caused by game code) match.
func allow_error(substring: String, max_count: int, engine_only: bool = false) -> void:
	print("  (up to %d error(s) tolerated next: %s%s)" % [max_count, substring, ", engine-only" if engine_only else ""])
	errors._mutex.lock()
	errors.allowed.append([substring, max_count, engine_only])
	errors._mutex.unlock()

## Stops tolerating errors announced with allow_error().
func clear_allowed_errors() -> void:
	errors._mutex.lock()
	errors.allowed.clear()
	errors._mutex.unlock()

## True once every announced error was seen.
func expected_errors_seen() -> bool:
	return errors.expected.is_empty()

func toast_seen(substring: String) -> bool:
	for t in toasts:
		if String(t[0]).contains(substring):
			return true
	return false

func finish() -> void:
	_finish_with(-1)

func _finish_with(code: int) -> void:
	if _finished:
		return
	if errors != null:
		if not errors.expected.is_empty():
			check(false, "announced errors that never happened: %s" % ", ".join(errors.expected))
		if errors.errors.is_empty():
			check(true, "no unexpected engine/script errors (%d expected, %d tolerated seen)" % [errors.expected_seen, errors.allowed_seen])
		else:
			check(false, "%d unexpected engine/script error(s) logged" % errors.errors.size())
			for e in errors.errors:
				print("      error: " + e)
		OS.remove_logger(errors)
	_finished = true
	var ok := _fails == 0 and code <= 0
	print("[%s] %d passed, %d failed -> %s" % [_label, _passes, _fails, "PASS" if ok else "FAIL"])
	print("RESULT: %s [%s] %d passed, %d failed" % ["PASS" if ok else "FAIL", _label, _passes, _fails])
	if Net.is_online():
		Net.leave()
	get_tree().quit(code if code > 0 else (0 if ok else 1))

# --- State helpers ---------------------------------------------------------------------------------------------

## Deterministic description of the replicated state on THIS peer. Positions are the synced rest positions of
## floor items (identical bits on every peer), so they can be compared exactly.
static func canonical_state() -> String:
	var parts: PackedStringArray = []
	var pl: PackedStringArray = []
	for id in Net.get_peer_ids():
		pl.append("%d=%s" % [id, Net.get_player_name(id)])
	parts.append("players[%s]" % ",".join(pl))
	var ups: PackedStringArray = []
	for k in GameState.upgrades.keys():
		ups.append("%s:%d" % [k, int(GameState.upgrades[k])])
	ups.sort()
	parts.append("gs[%s r%d $%d sold%d q%d up{%s}]" % [GameState.get_phase_name(), GameState.round_number,
			GameState.money, GameState.round_sales, GameState.quota, ",".join(ups)])
	var w: World = Game.world
	if w == null or not is_instance_valid(w):
		parts.append("noworld")
		return " ".join(parts)
	var nodes: PackedStringArray = []
	for p in w.get_players():
		nodes.append(str(p.peer_id))
	parts.append("nodes[%s]" % ",".join(nodes))
	var its: PackedStringArray = []
	for it in w.items.get_items():
		its.append(item_sig(it))
	its.sort()
	parts.append("items[%s]" % ";".join(its))
	var plots: PackedStringArray = []
	for i in range(1, 7):
		var plot := w.room.get_node_or_null("Stations/GrowPlot%d" % i) as GrowPlot
		plots.append("-" if plot == null else "%d:%s" % [plot.stage, plot.strain_id])
	parts.append("plots[%s]" % ",".join(plots))
	return " ".join(parts)

static func item_sig(it: Item) -> String:
	var props := it.get_props()
	var keys := props.keys()
	keys.sort()
	var pv: PackedStringArray = []
	for k in keys:
		pv.append("%s=%s" % [k, props[k]])
	var where := "held" if it.is_held() else "%.2f,%.2f,%.2f" % [it.rest_position.x, it.rest_position.y, it.rest_position.z]
	return "%s:%s:h%d:{%s}@%s" % [it.name, it.item_type, it.holder_id, ",".join(pv), where]

## Items of a type on this peer.
static func items_of(type: StringName) -> Array[Item]:
	if Game.world == null:
		return []
	return Game.world.items.get_items_of_type(type)

static func plot(i: int) -> GrowPlot:
	if Game.world == null:
		return null
	return Game.world.room.get_node_or_null("Stations/GrowPlot%d" % i) as GrowPlot

## Moves the LOCAL player (owner-authoritative movement) to stand `distance` m in front of a station / item and
## face it. Remote peers (the server's range check) see it after the next sync packets, so wait a bit after.
func stand_near(target: Node3D, distance: float = 1.2) -> void:
	var me: Player = Game.local_player
	if me == null or target == null:
		return
	var fwd := target.global_transform.basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.BACK
	var pos := target.global_position + fwd * distance
	pos.y = 0.05
	me.velocity = Vector3.ZERO
	me.global_position = pos
	var look := Vector3(target.global_position.x, pos.y, target.global_position.z)
	if look.distance_to(pos) > 0.01:
		me.look_at(look, Vector3.UP)
