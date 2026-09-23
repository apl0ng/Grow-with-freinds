extends SceneTree
## Base for lead-owned headless smoke tests. Subclasses implement `_run()` as a coroutine.
##   godot --headless --path . -s res://tools/tests/smoke_solo.gd -- --port=7801
## Autoloads are only available from _initialize() onward (never in _init).

var _fails: int = 0
var _passes: int = 0
var _label: String = "smoke"
var _finished: bool = false

func _initialize() -> void:
	_run()

func _run() -> void:
	finish()

func check(cond: bool, msg: String) -> bool:
	if cond:
		_passes += 1
		print("  ok   - " + msg)
	else:
		_fails += 1
		print("  FAIL - " + msg)
	return cond

func step(msg: String) -> void:
	print("[%s] %s" % [_label, msg])

## Await frames until `pred` returns true or `timeout_sec` passes. Returns true on success and records a check.
func wait_until(pred: Callable, timeout_sec: float, msg: String) -> bool:
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < timeout_sec * 1000.0:
		var ok: bool = false
		var v: Variant = pred.call()
		ok = bool(v)
		if ok:
			return check(true, msg)
		await process_frame
	return check(false, msg + " (timeout %.1fs)" % timeout_sec)

func wait_frames(n: int) -> void:
	for i in n:
		await process_frame

func wait_sec(sec: float) -> void:
	await create_timer(sec).timeout

## Put a player in front of a station (stations face local +Z) or on top of an item.
func teleport(player: Node3D, target: Node3D, distance: float = 1.2) -> void:
	var pos: Vector3 = target.global_position + target.global_transform.basis.z.normalized() * distance
	pos.y = target.global_position.y + 0.05
	player.global_position = pos
	# Face the target so the interaction ray would also hit it.
	var look := target.global_position
	look.y = pos.y
	if look.distance_to(pos) > 0.01:
		player.look_at(look, Vector3.UP)
		player.rotate_y(PI) # look_at points -Z at the target; player forward conventions vary, harmless

func station(path: String) -> Node:
	if Game.world == null:
		return null
	return Game.world.room.get_node_or_null("Stations/" + path)

func find_item(type: StringName, holder: int = -1) -> Item:
	if Game.world == null:
		return null
	for it in Game.world.items.get_items():
		if it.item_type == type and (holder < 0 or it.holder_id == holder):
			return it
	return null

func port_arg(default_port: int) -> int:
	return int(Config.get_arg("port", default_port))

func finish() -> void:
	if _finished:
		return
	_finished = true
	print("[%s] %d passed, %d failed -> %s" % [_label, _passes, _fails, "PASS" if _fails == 0 else "FAIL"])
	quit(0 if _fails == 0 else 1)
