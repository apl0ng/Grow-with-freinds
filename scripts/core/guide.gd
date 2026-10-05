class_name Guide
extends Node
## The guided first shift (M19 onboarding agent; CONTRACTS "M19" / "Onboarding", RELEASE.md L2). Story creates it as
## its child (`Story.guide`, the node /root/Story/Guide). Every peer runs its own and nothing of it is ever sent: the
## step state is read from what the host already syncs, the lines go through Story to the Boss at his window on THIS
## peer only (Story.onboarding_say), and the HUD shows the hint line (World/HUD/Root/GuideHint, hud.gd's M19 region).
##
## THE STEPS, one at a time and in order. A step is done when ANYBODY on the crew did it, and a step the crew has
## already done is skipped (its line is never said). The evidence, read on every peer:
##   buy      a seed purchase (GameState.purchase_made, "seed:<id>") or a seed packet anywhere
##   plant    a tray that is not empty, or STAT_PLANTED for anyone this shift
##   water    a growing tray with water in it (trays are planted dry), or STAT_WATERED for anyone
##   wait     a tray READY (the line is about the stages and the water)
##   harvest  a bundle anywhere (hands, floor, a rack, the hand truck) or STAT_HARVESTED for anyone
##   deposit  a deposit this shift (GameState.sale_made, round_sales, STAT_DEPOSITED)
## When the first deposit lands, the payment line (what the bar is, that the shift ends when it is paid) is the last
## thing said, its hint stays PAYMENT_HINT_SEC, and the guide is over for this run. The end of the shift ends it too
## (no line then: the Boss's paid / missed line says it).
## Each step: the Boss's line once when it becomes current (as soon as he has been quiet Story.ONBOARDING_GAP_SEC),
## once more if the step is still current `Config.balance.guide_step_timeout_sec` after that, then only the hint stays.
##
## WHO (each peer for itself), is_wanted(): the guide is enabled for this run (is_enabled(): the real game with
## Config.replay_enabled, or the --guide user arg; never with --no-guide; so no headless suite, --replay or not, and no
## `-s` capture tool sees it without --guide), guidance was not switched off in this session, and the player's record
## has no shift worked (Career.get_record("shifts") == 0) or Settings guidance is on. At the end of a shift this player
## worked (counted the way Career counts it) that was their first, or that the guide ran in, the guide switches
## guidance off: Settings.set_value(&"guidance", false) (the real autoload only in the real game, is_real_game(); a
## test's settings_override always). Settings.changed(&"guidance") is followed at once (off: the guide stops where it
## is; on: it starts at the current step).
## WHEN: the first shift of a run (round 1, PLAYING) until the payment line or the end of that shift. START OVER
## (GameState.game_reset) starts it from the top for a player who still wants it. A worker joining mid-guide reads the
## synced state for SETTLE_SEC and gets the current step.
## THE ALLEY (round 1, WAITING, the same rule): get_alley_line() heads the board's NEXT column (AlleyBoard, one hook),
## and the van (watch_van, one hook in Van._ready) shows the same line as the hint once, the first time the local worker
## comes within VAN_NEAR_M of its doors.
## Never in the way: no modal, no pause, no UI lock, no input taken; the events and their delays are untouched.

## Every peer: the current step changed (&"" = the guide is not running, STEP_PAYMENT = the last line is due).
signal step_changed(step: StringName)
## Every peer: get_hint_text() changed.
signal hint_changed(text: String)
## A guide line was said at the Boss (`step` is its step, STEP_PAYMENT for the last line).
signal line_said(step: StringName, text: String)

const STEP_BUY: StringName = &"buy"
const STEP_PLANT: StringName = &"plant"
const STEP_WATER: StringName = &"water"
const STEP_WAIT: StringName = &"wait"
const STEP_HARVEST: StringName = &"harvest"
const STEP_DEPOSIT: StringName = &"deposit"
const STEP_PAYMENT: StringName = &"payment"
const STEPS: Array[StringName] = [STEP_BUY, STEP_PLANT, STEP_WATER, STEP_WAIT, STEP_HARVEST, STEP_DEPOSIT]

## The Boss's lines (STYLE.md: flat, no "!", nobody is pleased).
const LINES: Dictionary = {
	STEP_BUY: "Window's there. Seeds cost money.",
	STEP_PLANT: "Seeds go in a tray. Any empty one.",
	STEP_WATER: "Fill a can at the tank. Pour it on the tray.",
	STEP_WAIT: "It grows in stages. Dry soil, it stops. Keep it wet.",
	STEP_HARVEST: "That one's ready. Empty hands. Pull it.",
	STEP_DEPOSIT: "Down the chute. Not in your pocket.",
	STEP_PAYMENT: "That's a deposit. The bar is what you owe. Pay it and the shift ends.",
}
## The alley: the board's first NEXT line and the van's hint, the first time.
const ALLEY_LINE: String = "Get in the back. The shift starts when everyone is in."
## The hint line under the prompt; "%s" = the interact key ("E"). The water step follows what the local worker holds.
const HINTS: Dictionary = {
	STEP_BUY: "%s · buy seeds at the window",
	STEP_PLANT: "%s · plant them in an empty tray",
	STEP_WATER: "%s · pick up a can, fill it at the tank",
	&"water_fill": "%s · fill the can at the tank",
	&"water_pour": "%s · pour it on the tray",
	STEP_WAIT: "Wait. %s · water it when it dries",
	STEP_HARVEST: "%s · harvest it with empty hands",
	STEP_DEPOSIT: "%s · deposit it at the chute",
	STEP_PAYMENT: "The bar at the top · pay it and the shift ends",
}

## A guide that just started reads the synced state this long before it shows anything (a late joiner's trays and
## items arrive a moment after the shift's state).
const SETTLE_SEC: float = 1.0
## The step is re-read this often (and at once on a purchase, a deposit or a stats change).
const POLL_SEC: float = 0.1
## The payment hint and the van's line stay this long.
const PAYMENT_HINT_SEC: float = 8.0
const VAN_HINT_SEC: float = 6.0
## The van says its line when the local worker's feet come this close (flat metres) to its doors, or are inside.
const VAN_NEAR_M: float = 4.0
## A growing tray holding more water than this has been watered (trays are planted dry; a reset empties them).
const WATER_EVIDENCE: float = 0.01
const SAID_LOG_MAX: int = 32

## Test hook: an Object with get_value(key, default) / set_value(key, value) (and optionally a `changed(key)` signal)
## used instead of the Settings autoload. Suites always set one: the guide must never write a player's real settings.
var settings_override: Object = null:
	set(value):
		if settings_override != null and is_instance_valid(settings_override) and settings_override.has_signal(&"changed") \
				and settings_override.is_connected(&"changed", _on_settings_changed):
			settings_override.disconnect(&"changed", _on_settings_changed)
		settings_override = value
		if value != null and value.has_signal(&"changed") and not value.is_connected(&"changed", _on_settings_changed):
			value.connect(&"changed", _on_settings_changed)
		if is_inside_tree():
			refresh()
## Every guide line said on this peer, oldest first (tests; cleared when the session ends).
var said_log: PackedStringArray = []

var _active: bool = false
var _finished: bool = false
## Leading steps done this run (0..STEPS.size()); it only grows until the run is reset.
var _done: int = 0
var _step: StringName = &""
var _said: int = 0
var _since_said: float = 0.0
var _settle: float = 0.0
var _poll: float = 0.0
var _latch_buy: bool = false
var _latch_sale: bool = false
var _ran_this_shift: bool = false
var _shifts_at_start: int = -1
var _session_off: bool = false
var _timed_hint: String = ""
var _timed_left: float = 0.0
var _last_hint: String = ""
var _van_ref: WeakRef = null
var _van_said: bool = false


func _ready() -> void:
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_ended.connect(_on_round_ended)
	GameState.game_reset.connect(_on_game_reset)
	GameState.purchase_made.connect(_on_purchase_made)
	GameState.sale_made.connect(_on_sale_made)
	GameState.stats_changed.connect(_on_state_moved)
	var settings: Object = Settings
	if settings != null and settings.has_signal(&"changed"):
		settings.connect(&"changed", _on_settings_changed)


func _process(delta: float) -> void:
	tick(delta)


# --- queries (any peer) ---------------------------------------------------------------------------------------------

## True when the guide exists in this run at all: --guide forces it on and --no-guide off; otherwise it is on in the
## real game with replay on (Config.replay_enabled, a windowed run that is not a `-s` tool). So no suite (headless,
## with or without --replay) and no capture tool sees a guide line unless it asks for one with --guide.
func is_enabled() -> bool:
	if Config.has_arg("no-guide"):
		return false
	if Config.has_arg("guide"):
		return true
	return Config.replay_enabled and is_real_game()


## True in the game a player runs: a window, and not a `-s <script>` tool (a suite body, a capture tool). Only then is
## the real Settings autoload ever written (Career's rule for its file, kept the same here).
static func is_real_game() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	for arg in OS.get_cmdline_args():
		if arg == "-s" or arg == "--script":
			return false
	return true


## True when this player gets the guide (see the header): enabled, not switched off in this session, and no shift on
## file or guidance on.
func is_wanted() -> bool:
	if not is_enabled() or _session_off:
		return false
	return _career_shifts() == 0 or _guidance_on()


## True while the guide runs for this peer (the first shift of a run, not done yet).
func is_active() -> bool:
	return _active


## True once the guide is over for this run (the payment line was said, or the first shift ended).
func is_finished() -> bool:
	return _finished


## The current step (STEPS, STEP_PAYMENT while the last line is due; &"" when the guide is not running).
func get_step() -> StringName:
	return _step


## How many times the current step's line has been said (0, 1 or 2).
func get_said_count() -> int:
	return _said


## Leading steps the crew has done this run (0..6).
func get_done_count() -> int:
	return _done


## The Boss's line for a step ("" for an unknown one).
static func get_line(step: StringName) -> String:
	return String(LINES.get(step, ""))


## What the hint line shows right now ("" = hidden): the van's or the payment's line while their time runs, else the
## current step with its key.
func get_hint_text() -> String:
	if _timed_left > 0.0 and _timed_hint != "":
		return _timed_hint
	if _active and _settle <= 0.0 and _step != &"" and _step != STEP_PAYMENT:
		return _step_hint(_step)
	return ""


## The alley board's first NEXT line for this player ("" when there is none): round 1, waiting, and is_wanted().
func get_alley_line() -> String:
	if _finished or GameState.phase != GameState.Phase.WAITING or GameState.round_number != 1:
		return ""
	return ALLEY_LINE if is_wanted() else ""


## Van._ready hands its node over: the line is shown once when the local worker comes near its doors.
func watch_van(van: Node3D) -> void:
	_van_ref = weakref(van) if van != null else null


## True once the van's line was shown in this session.
func is_van_said() -> bool:
	return _van_said


# --- the clock ------------------------------------------------------------------------------------------------------

## Advances the guide's clock by `delta` seconds (every frame; tests call it to skip time) and re-reads the step every
## POLL_SEC.
func tick(delta: float) -> void:
	delta = maxf(delta, 0.0)
	if _timed_left > 0.0:
		_timed_left = maxf(_timed_left - delta, 0.0)
	if _active:
		if _settle > 0.0:
			_settle = maxf(_settle - delta, 0.0)
		elif _said > 0:
			_since_said += delta
	_poll += delta
	if _poll >= POLL_SEC:
		_poll = 0.0
		refresh()
	else:
		_emit_hint()


## Re-reads everything now: whether the guide runs, the step, a line that is due, the van, the hint.
func refresh() -> void:
	if not is_enabled():
		if _active:
			_stop()
		_emit_hint()
		return
	var run := _should_run()
	if run and not _active:
		_start()
	elif not run and _active:
		_stop()
	if _active:
		_advance()
		_maybe_say()
	_check_van()
	_emit_hint()


# --- the steps ------------------------------------------------------------------------------------------------------

func _should_run() -> bool:
	if _finished or GameState.phase != GameState.Phase.PLAYING or GameState.round_number != 1:
		return false
	var world: Node = Game.world
	if world == null or not is_instance_valid(world) or not world.is_inside_tree():
		return false
	var me := _local_id()
	if me <= 0 or not Net.players.has(me):
		return false
	return is_wanted()


func _start() -> void:
	_active = true
	_ran_this_shift = true
	_settle = SETTLE_SEC
	_step = &""
	_said = 0
	_since_said = 0.0


## The guide stops showing anything (the shift ended, the run was reset, guidance went off). Not "finished" by itself.
func _stop() -> void:
	_active = false
	_settle = 0.0
	_said = 0
	_since_said = 0.0
	if _step != &"":
		_step = &""
		step_changed.emit(_step)


func _advance() -> void:
	if _settle > 0.0:
		return
	var level := maxi(_done, _evidence_level())
	if _step != &"" and level == _done:
		return
	_done = level
	if level >= STEPS.size():
		_set_step(STEP_PAYMENT)
		_timed_hint = _step_hint(STEP_PAYMENT)
		_timed_left = PAYMENT_HINT_SEC
	else:
		_set_step(STEPS[level])


func _set_step(step: StringName) -> void:
	_step = step
	_said = 0
	_since_said = 0.0
	step_changed.emit(step)


func _maybe_say() -> void:
	if _step == &"" or _settle > 0.0:
		return
	var due := _said == 0 or (_said == 1 and _step != STEP_PAYMENT and _since_said >= _timeout())
	if not due or not _boss_free():
		return
	var step := _step
	var text := get_line(step)
	_said += 1
	_since_said = 0.0
	said_log.append(text)
	if said_log.size() > SAID_LOG_MAX:
		said_log.remove_at(0)
	Story.onboarding_say(text)
	line_said.emit(step, text)
	if step == STEP_PAYMENT:
		_finished = true
		_stop()


## How many leading steps the synced state shows done (0..6), whoever did them.
func _evidence_level() -> int:
	if _latch_sale or GameState.round_sales > 0 or _any_stat(Const.STAT_DEPOSITED):
		return 6
	if _any_stat(Const.STAT_HARVESTED) or _bundle_exists():
		return 5
	var planted := false
	var watered := false
	for node in get_tree().get_nodes_in_group(Const.GROUP_GROW_PLOTS):
		var plot := node as GrowPlot
		if plot == null:
			continue
		if plot.stage == GrowPlot.Stage.READY:
			return 4
		if plot.stage != GrowPlot.Stage.EMPTY:
			planted = true
			if plot.water > WATER_EVIDENCE:
				watered = true
	if watered or _any_stat(Const.STAT_WATERED):
		return 3
	if planted or _any_stat(Const.STAT_PLANTED):
		return 2
	if _latch_buy or not _items_of(Const.ITEM_SEED_PACKET).is_empty():
		return 1
	return 0


func _any_stat(key: StringName) -> bool:
	for row: Variant in GameState.stats.values():
		if row is Dictionary and int((row as Dictionary).get(key, 0)) > 0:
			return true
	return false


func _bundle_exists() -> bool:
	if not _items_of(Const.ITEM_PRODUCT).is_empty():
		return true
	for truck in _items_of(Const.ITEM_HAND_TRUCK):
		if truck.has_method(&"get_load_count") and int(truck.call(&"get_load_count")) > 0:
			return true
	return false


func _items_of(item_type: StringName) -> Array[Item]:
	var none: Array[Item] = []
	var world: Node = Game.world
	if world == null or not is_instance_valid(world):
		return none
	var items := world.get(&"items") as ItemManager
	return items.get_items_of_type(item_type) if items != null else none


func _step_hint(step: StringName) -> String:
	var key := _key_text(&"interact", "E")
	var hint_key: StringName = step
	if step == STEP_WATER:
		var me: Node = Game.local_player
		var held: Item = (me as Player).get_held_item() if me != null and is_instance_valid(me) and me.is_inside_tree() else null
		if GrowPlot.item_is(held, Const.ITEM_WATERING_CAN):
			hint_key = &"water_pour" if GrowPlot.get_can_charges(held) > 0 else &"water_fill"
	var fmt := String(HINTS.get(hint_key, ""))
	return fmt % key if fmt.contains("%s") else fmt


func _timeout() -> float:
	return maxf(Config.balance.guide_step_timeout_sec, 1.0)


func _boss_free() -> bool:
	return Story.onboarding_boss_free()


# --- the alley ------------------------------------------------------------------------------------------------------

func _check_van() -> void:
	if _van_said or _van_ref == null:
		return
	var van := _van_ref.get_ref() as Node3D
	if van == null or not van.is_inside_tree() or get_alley_line() == "":
		return
	var me: Node = Game.local_player
	if me == null or not is_instance_valid(me) or not me.is_inside_tree():
		return
	var feet := (me as Node3D).global_position
	var entry: Vector3 = van.call(&"get_entry_point") if van.has_method(&"get_entry_point") else van.global_position
	var inside := van.has_method(&"is_in_cargo") and bool(van.call(&"is_in_cargo", feet))
	if not inside and Vector2(feet.x - entry.x, feet.z - entry.z).length() > VAN_NEAR_M:
		return
	_van_said = true
	_timed_hint = ALLEY_LINE
	_timed_left = VAN_HINT_SEC


# --- who gets it ----------------------------------------------------------------------------------------------------

func _settings() -> Object:
	if settings_override != null and is_instance_valid(settings_override):
		return settings_override
	return Settings


func _guidance_on() -> bool:
	var s := _settings()
	if s == null or not s.has_method(&"get_value"):
		return true
	return bool(s.call(&"get_value", &"guidance", true))


func _career_shifts() -> int:
	var career: Object = Career
	if career == null or not career.has_method(&"get_record"):
		return 0
	return int(career.call(&"get_record", "shifts"))


## After a worked shift (see the header): guidance off in the settings and for the rest of this session. The real
## Settings autoload is written only in the real game (is_real_game()); a suite's or a tool's stand-in always is.
func _turn_guidance_off() -> void:
	var s := _settings()
	var writable := s != null and (s == settings_override or is_real_game())
	if writable and s.has_method(&"set_value") and _guidance_on():
		s.call(&"set_value", &"guidance", false)
	_session_off = true


func _local_id() -> int:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return 0
	return multiplayer.get_unique_id()


# --- signals --------------------------------------------------------------------------------------------------------

func _on_phase_changed(phase: int) -> void:
	if phase == GameState.Phase.MENU:
		_reset_run()
		_van_said = false
		said_log = PackedStringArray()
		return
	if phase == GameState.Phase.PLAYING:
		_shifts_at_start = _career_shifts()
	refresh()


func _on_round_ended(_success: bool, round_number: int) -> void:
	if round_number == 1:
		_finished = true
	if _active:
		_stop()
	var me := _local_id()
	if is_enabled() and me > 0 and Net.players.has(me) and (_ran_this_shift or _shifts_at_start == 0):
		_turn_guidance_off()
	_ran_this_shift = false
	_timed_left = 0.0
	_emit_hint()


func _on_game_reset() -> void:
	_reset_run()
	refresh()


func _reset_run() -> void:
	if _active:
		_stop()
	_active = false
	_finished = false
	_done = 0
	_step = &""
	_said = 0
	_since_said = 0.0
	_settle = 0.0
	_latch_buy = false
	_latch_sale = false
	_ran_this_shift = false
	_timed_hint = ""
	_timed_left = 0.0
	_emit_hint()


func _on_purchase_made(_cost: int, _buyer_peer: int, what: String) -> void:
	if what.begins_with("seed:"):
		_latch_buy = true
		refresh()


func _on_sale_made(amount: int, _seller_peer: int) -> void:
	if amount > 0 and GameState.phase == GameState.Phase.PLAYING:
		_latch_sale = true
		refresh()


func _on_state_moved() -> void:
	if _active:
		refresh()


func _on_settings_changed(key: StringName) -> void:
	if key != &"guidance":
		return
	_session_off = not _guidance_on()
	refresh()


func _emit_hint() -> void:
	var text := get_hint_text()
	if text == _last_hint:
		return
	_last_hint = text
	hint_changed.emit(text)


## Display text of the first keyboard key bound to `action` ("E"), or `fallback` (HUD.action_key_text's rule, kept
## here so this core script does not load UI scripts).
static func _key_text(action: StringName, fallback: String) -> String:
	if not InputMap.has_action(action):
		return fallback
	for ev: InputEvent in InputMap.action_get_events(action):
		var key := ev as InputEventKey
		if key == null:
			continue
		var code: Key = key.keycode
		if key.physical_keycode != KEY_NONE:
			code = key.physical_keycode
			if DisplayServer.get_name() != "headless":
				code = DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
		if code == KEY_NONE:
			continue
		var text := OS.get_keycode_string(code)
		if text != "":
			return text.to_upper()
	return fallback
