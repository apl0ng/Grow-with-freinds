class_name HUD
extends CanvasLayer
## In-game HUD (scenes/ui/hud.tscn, instanced as World/HUD). Owned by the game-flow/UI agent.
##
##   top-left      SHIFT n + big mm:ss timer (red + tick each second under TIMER_WARN_SEC)
##   top-centre    the payment: "PAYMENT DUE $deposited / $owed" + progress bar (punches on every deposit)
##   top-right     cash on hand (punch on change, +$/-$ floats on deposits/purchases) + WORKERS list
##   bottom-left   held item ("Carrying: Watering Can (3/4)"), polled every HELD_POLL_SEC
##   bottom-centre interaction prompt, fed by Game.local_player.get_interactor().prompt_changed
##   centre        phase banner (WAITING: host "ENTER · START SHIFT" hint; the mouse is captured while waiting so
##                 Enter is the real path and the button only reacts if the mouse is somehow free / clients wait)
##   bottom-right  toast stack (Game.toast_requested / show_toast), max MAX_TOASTS visible
##   overlays      %RoundEnd (round_end.tscn), %PauseMenu (pause_menu.tscn), %BackRoom (backroom_overlay.tscn)
## M10 (friendslop pass, ui agent):
##   WORKERS rows   a "))" speaking mark next to the name (Voice.speaking_changed + a SPEAK_POLL_SEC poll of
##                  Voice.is_speaking), "×" per strike (GameState.get_write_ups, Toon.ERROR) and a "(back room)" tag
##                  (GameState.is_in_backroom); refreshed on stats_changed / worker_written_up / backroom_changed /
##                  players_changed
##   event banner   %EventPanel under the payment bar: "INSPECTION 0:31" / "POWER CUT" + "Find the breaker." /
##                  "AUDIT" / "RAT" from Events.event_started / event_ended, countdown from Events.get_event_time_left()
##                  (the alarm sound is the events agent's)
##   write-ups      a toast for everyone ("<name> written up: skimming."), the write_up sound, and a shake of the
##                  prompt panel when it is us
##   ping           the "ping" action (MMB / X, mouse captured, no UI lock): a ray from the local camera on
##                  world | interactable | item up to PING_RAY_LENGTH (else PING_FALLBACK_DISTANCE ahead) ->
##                  Comms.ping(point); every Comms.ping_received spawns a PingMarker under Game.world (one per worker)
##   chat           %Chat (chat.tscn) bottom-left above the held item; the "chat" action (T) opens its line
## Copy is flat and joyless on purpose (STYLE.md "Mood & tone"): no "!" and no cheer.
## Null-safe before the local player spawns and when Net is offline (solo tests).

const TOAST_SCENE: PackedScene = preload("res://scenes/ui/toast.tscn")
const PING_MARKER_SCENE: PackedScene = preload("res://scenes/ui/ping_marker.tscn")
const MAX_TOASTS: int = 4
const HELD_POLL_SEC: float = 0.1
## Seconds between polls of Voice.is_speaking for the WORKERS marks (the signal is the fast path).
const SPEAK_POLL_SEC: float = 0.2
## Ping ray: how far a ping reaches, and where it lands when the ray hits nothing.
const PING_RAY_LENGTH: float = 30.0
const PING_FALLBACK_DISTANCE: float = 8.0
## The speaking mark ("))") is drawn OVER the worker's colour dot (no row width of its own, so names never lose
## room to it) at this font size; the dot pulses while the worker is heard.
const SPEAK_MARK_FONT_SIZE: int = 11
const TIMER_WARN_SEC: float = 30.0
## Last seconds that use the "countdown" blip instead of "tick" (when Sfx has it).
const COUNTDOWN_SEC: int = 5
const GO_BANNER_SEC: float = 2.0
const GO_FADE_SEC: float = 0.4
const BAR_TWEEN_SEC: float = 0.35
const FLOAT_RISE_PX: float = 40.0
const FLOAT_WIDTH: float = 160.0
const FLOAT_SEC: float = 1.1
const CROSSHAIR_RADIUS: float = 3.5
## Widest the WORKERS panel may get. It hangs right-anchored under the wallet, beside the centred WAITING banner
## (x 292..988 at the 1280 px minimum logical width): long names are trimmed with "…" (the tags stay whole) instead
## of sliding under the banner's START SHIFT button and the payment panel.
const PLAYERS_MAX_WIDTH: float = 268.0
## Font size of the player-list names and of their smaller "(host, you)" tag.
const PLAYER_NAME_FONT_SIZE: int = 20
const PLAYER_TAG_FONT_SIZE: int = 16

## Copy (kept here so tests and other UI can reuse the exact strings).
const TEXT_SHIFT := "SHIFT %d"
const TEXT_GO := "SHIFT %d — GET TO WORK"
const TEXT_PAYMENT := "PAYMENT DUE %s / %s"
const TEXT_CARRYING := "Carrying: %s"
const TEXT_HOST_TAG := "host"
const TEXT_YOU_TAG := "you"
const TEXT_JOINING_TITLE := "CLOCKING IN…"
const TEXT_JOINING := "Wait."
const TEXT_WAIT_HOST_TITLE := "CLOCK IN"
const TEXT_WAIT_HOST := "Shift starts when you press %s.\nNobody leaves until it's paid."
const TEXT_WAIT_CLIENT_TITLE := "STAND BY"
const TEXT_WAIT_CLIENT := "Waiting for the shift to start."
const TEXT_COVERED := "Payment covered. Keep depositing."
const TEXT_RESET := "Starting over. Shift 1."
## M10 copy.
const TEXT_BANNER_TIP := "Plant now. Nothing grows until the shift starts.\n%s · chat"
const TEXT_SPEAKING_MARK := "))"
const TEXT_STRIKE_MARK := "×"
const TEXT_BACKROOM_TAG := "(back room)"
const TEXT_WRITE_UP := "%s written up: %s."
const TEXT_WRITE_UP_PLAIN := "%s written up."
const TEXT_EVENT_INSPECTION := "INSPECTION"
const TEXT_EVENT_POWER_CUT := "POWER CUT"
const TEXT_EVENT_POWER_HINT := "Find the breaker."
const TEXT_EVENT_AUDIT := "AUDIT"
const TEXT_EVENT_RAT := "RAT"
# M12 disrupt: the three interruptions (title + the hint line under it; "%s" = the strain).
const TEXT_EVENT_HEADCOUNT := "HEAD COUNT"
const TEXT_EVENT_HEADCOUNT_HINT := "The line. In front of the window."
const TEXT_EVENT_WATER_OFF := "WATER OFF"
const TEXT_EVENT_WATER_OFF_HINT := "No pressure at the tank."
const TEXT_EVENT_SHORTAGE := "SHORTAGE"
const TEXT_EVENT_SHORTAGE_HINT := "%s is out of stock."

@onready var root_control: Control = %Root
@onready var stats: Control = %Stats
@onready var round_label: Label = %RoundLabel
@onready var timer_label: Label = %TimerLabel
@onready var quota_panel: Control = %QuotaPanel
@onready var quota_label: Label = %QuotaLabel
@onready var quota_bar: ProgressBar = %QuotaBar
@onready var wallet_panel: Control = %WalletPanel
@onready var money_label: Label = %MoneyLabel
@onready var players_panel: Control = %PlayersPanel
@onready var player_list: VBoxContainer = %PlayerList
@onready var held_panel: Control = %HeldPanel
@onready var held_label: Label = %HeldLabel
@onready var prompt_panel: Control = %PromptPanel
@onready var prompt_label: Label = %PromptLabel
@onready var crosshair: Control = %Crosshair
@onready var banner: Control = %Banner
@onready var banner_title: Label = %BannerTitle
@onready var banner_text: Label = %BannerText
@onready var start_button: Button = %StartButton
@onready var banner_tip: Label = %BannerTip
@onready var go_banner: Label = %GoBanner
@onready var float_layer: Control = %FloatLayer
@onready var round_end: RoundEndOverlay = %RoundEnd
@onready var pause_menu: PauseMenu = %PauseMenu
@onready var toasts: VBoxContainer = %Toasts
@onready var event_panel: Control = %EventPanel
@onready var event_label: Label = %EventLabel
@onready var event_hint: Label = %EventHint
@onready var chat: ChatBox = %Chat
@onready var back_room: BackRoomOverlay = %BackRoom

## M10: peer_id -> {"row", "name", "speak", "strikes", "backroom"} (the WORKERS rows and their marks).
var _player_rows: Dictionary = {}
## M10: peer_id -> bool from Voice.speaking_changed (OR-ed with the Voice.is_speaking poll).
var _speaking_signal: Dictionary = {}
var _speak_poll_accum: float = 0.0
## M10: the running event's kind (&"" = none) for the banner.
var _event_kind: StringName = &""
## M12 disrupt: the running event's params (the shortage names its strain in the hint).
var _event_params: Dictionary = {}
## M10: peer_id -> PingMarker (a new ping replaces the worker's previous marker).
var _ping_markers: Dictionary = {}

var _local_player: Node = null
var _has_local_player: bool = false
var _prompt_source: Object = null
var _has_prompt_source: bool = false
var _prompt_text: String = ""
var _prompt_enabled: bool = false
var _held_text: String = ""
var _held_poll_accum: float = 0.0
var _ui_locked: bool = false
## False until a real session state arrived: no juice for the initial sync / resets to MENU.
var _stats_ready: bool = false
var _last_money: int = 0
var _last_sales: int = 0
var _last_tick_second: int = -1
var _timer_danger: bool = false
var _go_tween: Tween
var _bar_tween: Tween
var _bar_done_style: StyleBox


func _ready() -> void:
	GameState.money_changed.connect(_on_money_changed)
	GameState.sales_changed.connect(_on_sales_changed)
	GameState.time_changed.connect(_on_time_changed)
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_started.connect(_on_round_started)
	GameState.sale_made.connect(_on_sale_made)
	GameState.purchase_made.connect(_on_purchase_made)
	GameState.game_reset.connect(_on_game_reset)
	Game.toast_requested.connect(show_toast)
	Game.local_player_spawned.connect(_on_local_player_spawned)
	Game.ui_lock_changed.connect(_on_ui_lock_changed)
	Net.players_changed.connect(refresh_players)
	start_button.pressed.connect(_on_start_pressed)
	crosshair.draw.connect(_on_crosshair_draw)
	pause_menu.closed.connect(_on_pause_closed)
	# M10: marks, write-ups, events, pings. Sibling autoloads are used through their contract surface only and
	# guarded, so a renamed signal degrades to a missing mark, never to a broken HUD.
	GameState.stats_changed.connect(refresh_marks)
	GameState.worker_written_up.connect(_on_worker_written_up)
	GameState.backroom_changed.connect(_on_backroom_changed)
	var voice: Node = Voice
	if voice != null and voice.has_signal(&"speaking_changed"):
		voice.connect(&"speaking_changed", _on_speaking_changed)
	var events: Node = Events
	if events != null:
		if events.has_signal(&"event_started"):
			events.connect(&"event_started", _on_event_started)
		if events.has_signal(&"event_ended"):
			events.connect(&"event_ended", _on_event_ended)
	Comms.ping_received.connect(_on_ping_received)
	_lobby_ready() # M14 lobby
	_career_ready() # M15 career: the job line under the payment bar, titles in the WORKERS list

	_ui_locked = Game.is_ui_locked()
	_stats_ready = GameState.phase != GameState.Phase.MENU
	_last_money = GameState.money
	_last_sales = GameState.round_sales
	refresh_all()
	_sync_event_banner()
	var existing: Node = Game.local_player
	if is_instance_valid(existing):
		_set_local_player(existing)


func _process(delta: float) -> void:
	_held_poll_accum += delta
	if _held_poll_accum >= HELD_POLL_SEC:
		_held_poll_accum = 0.0
		_poll_local_player()
		_update_held_item()
	_speak_poll_accum += delta
	if _speak_poll_accum >= SPEAK_POLL_SEC:
		_speak_poll_accum = 0.0
		_poll_speaking()
	if event_panel.visible:
		_update_event_countdown()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_echo():
		return
	if event.is_action_pressed(&"start_round"):
		if GameState.phase == GameState.Phase.WAITING and GameState.is_local_host() and not Game.is_ui_locked():
			get_viewport().set_input_as_handled()
			_on_start_pressed()
	elif event.is_action_pressed(&"chat"):
		if not Game.is_ui_locked() and Game.world != null and chat != null:
			get_viewport().set_input_as_handled()
			chat.open()
	elif event.is_action_pressed(&"ping"):
		if Game.is_ui_locked():
			return
		# A click that (re)captures the mouse should not also ping (same rule as the Interactor).
		if event is InputEventMouseButton and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			return
		if ping_here():
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------------------------

## Shows a toast pill. kind: &"info" | &"error" | &"success". Same text twice in a row bumps it.
func show_toast(text: String, kind: StringName = &"info") -> void:
	if text.strip_edges() == "":
		return
	var live := _live_toasts()
	if not live.is_empty():
		var newest: HudToast = live.back()
		if newest.text == text and newest.kind == kind:
			newest.bump()
			return
	while live.size() >= MAX_TOASTS:
		var oldest: HudToast = live.pop_front()
		toasts.remove_child(oldest)
		oldest.queue_free()
	var toast := TOAST_SCENE.instantiate() as HudToast
	toast.setup(text, kind)
	toasts.add_child(toast)


## Number of toasts currently in the stack (tests).
func get_toast_count() -> int:
	return _live_toasts().size()


## Listen to `prompt_changed(text, enabled)` on this object (normally the local player's
## Interactor; tests pass a fake). null clears the prompt.
func set_prompt_source(source: Object) -> void:
	if is_instance_valid(_prompt_source) and _prompt_source.is_connected(&"prompt_changed", _on_prompt_changed):
		_prompt_source.disconnect(&"prompt_changed", _on_prompt_changed)
	_prompt_source = source
	_has_prompt_source = is_instance_valid(source) and source.has_signal(&"prompt_changed")
	if _has_prompt_source:
		source.connect(&"prompt_changed", _on_prompt_changed)
		# The Interactor keeps its last prompt for listeners that connect late.
		if &"prompt_text" in source and &"prompt_enabled" in source:
			_on_prompt_changed(str(source.get(&"prompt_text")), bool(source.get(&"prompt_enabled")))
			return
	_on_prompt_changed("", false)


## Re-reads everything from GameState / Net (no juice).
func refresh_all() -> void:
	_update_round_label()
	_apply_time(GameState.time_left, false)
	_apply_sales(GameState.round_sales, GameState.quota, false)
	money_label.text = format_money(GameState.money)
	_update_phase_ui()
	refresh_players()
	_update_held_item()
	_refresh_prompt()
	crosshair.visible = not _ui_locked


## Rebuilds the player list from Net.players (names in their colors), marks included (refresh_marks).
func refresh_players() -> void:
	for child: Node in player_list.get_children():
		player_list.remove_child(child)
		child.queue_free()
	_player_rows.clear()
	var ids: Array = Net.players.keys()
	ids.sort()
	players_panel.visible = not ids.is_empty()
	var local_id := _local_peer_id()
	for id: Variant in ids:
		var peer_id := int(id)
		var color: Color = Net.get_player_color(peer_id)
		var row := HBoxContainer.new()
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_theme_constant_override(&"separation", 8)
		var swatch := Panel.new()
		swatch.custom_minimum_size = Vector2(16, 16)
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var dot := StyleBoxFlat.new()
		dot.bg_color = color
		dot.set_corner_radius_all(8)
		dot.set_border_width_all(2)
		dot.border_color = _theme_color(&"font_outline_color", &"Label", Color.BLACK)
		swatch.add_theme_stylebox_override(&"panel", dot)
		row.add_child(swatch)
		# Speaking mark: an overlay on the dot (a Panel is not a Container, so the label costs the row no width),
		# shown by alpha while the worker is heard; the dot itself pulses.
		var speak := _player_label(TEXT_SPEAKING_MARK, Toon.TEXT, SPEAK_MARK_FONT_SIZE)
		speak.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		speak.mouse_filter = Control.MOUSE_FILTER_IGNORE
		speak.modulate.a = 0.0
		swatch.add_child(speak)
		speak.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var name_label := _player_label(Net.get_player_name(peer_id), color, PLAYER_NAME_FONT_SIZE)
		row.add_child(name_label)
		var tags: PackedStringArray = []
		if peer_id == Const.SERVER_PEER_ID:
			tags.append(TEXT_HOST_TAG)
		if peer_id == local_id:
			tags.append(TEXT_YOU_TAG)
		if not tags.is_empty():
			row.add_child(_player_label("(%s)" % ", ".join(tags), color, PLAYER_TAG_FONT_SIZE))
		var strikes := _player_label("", Toon.ERROR, PLAYER_NAME_FONT_SIZE)
		strikes.visible = false
		row.add_child(strikes)
		var backroom := _player_label(TEXT_BACKROOM_TAG, color, PLAYER_TAG_FONT_SIZE)
		backroom.visible = false
		row.add_child(backroom)
		player_list.add_child(row)
		_player_rows[peer_id] = {"row": row, "name": name_label, "speak": speak, "strikes": strikes, "backroom": backroom}
		_fit_player_name(row, name_label)
		_career_add_title(peer_id, color) # M15 career: the worker's job title on its own small line under the name
	refresh_marks()


## M10: updates every row's write-up marks, back-room tag and speaking mark from GameState / Voice (no rebuild).
func refresh_marks() -> void:
	for peer_id: int in _player_rows.keys():
		var entry: Dictionary = _player_rows[peer_id]
		var strikes: Label = entry["strikes"]
		var count := GameState.get_write_ups(peer_id)
		strikes.text = TEXT_STRIKE_MARK.repeat(count)
		var backroom: Label = entry["backroom"]
		var in_backroom := GameState.is_in_backroom(peer_id)
		var changed := strikes.visible != (count > 0) or backroom.visible != in_backroom
		strikes.visible = count > 0
		backroom.visible = in_backroom
		_apply_speaking_mark(peer_id)
		if changed:
			_fit_player_name(entry["row"], entry["name"])


## M10 (tests): true while the row's speaking mark is shown.
func is_speaking_mark_shown(peer_id: int) -> bool:
	if not _player_rows.has(peer_id):
		return false
	return (_player_rows[peer_id]["speak"] as Label).modulate.a > 0.5


## M10 (tests): the row's strike marks ("" when the worker has none).
func get_strike_marks(peer_id: int) -> String:
	if not _player_rows.has(peer_id):
		return ""
	var strikes: Label = _player_rows[peer_id]["strikes"]
	return strikes.text if strikes.visible else ""


## M10 (tests): true while the row carries the "(back room)" tag.
func is_backroom_tag_shown(peer_id: int) -> bool:
	if not _player_rows.has(peer_id):
		return false
	return (_player_rows[peer_id]["backroom"] as Label).visible


## M10 (tests): the event banner's text ("" while hidden).
func get_event_text() -> String:
	return event_label.text if event_panel.visible else ""


## M10: pings what the local camera looks at (the "ping" action). False without a local player / camera.
func ping_here() -> bool:
	var point := get_ping_point()
	if not point.is_finite():
		return false
	Comms.ping(point)
	return true


## M10: the point a ping from the local camera lands on (Vector3.INF without a camera): the first hit on
## world | interactable | item within PING_RAY_LENGTH, else PING_FALLBACK_DISTANCE ahead.
func get_ping_point() -> Vector3:
	var player: Node = _local_player if is_instance_valid(_local_player) else Game.local_player
	if player == null or not is_instance_valid(player) or not player.is_inside_tree():
		return Vector3.INF
	var cam := player.get(&"camera") as Camera3D
	if cam == null or not cam.is_inside_tree():
		return Vector3.INF
	var origin := cam.global_position
	var dir := -cam.global_basis.z.normalized()
	var world_3d := cam.get_world_3d()
	if world_3d != null and world_3d.direct_space_state != null:
		var query := PhysicsRayQueryParameters3D.create(origin, origin + dir * PING_RAY_LENGTH,
				Const.LAYER_WORLD | Const.LAYER_INTERACTABLE | Const.LAYER_ITEM)
		query.collide_with_areas = true
		if player is CollisionObject3D:
			query.exclude = [(player as CollisionObject3D).get_rid()]
		var hit := world_3d.direct_space_state.intersect_ray(query)
		if not hit.is_empty() and hit.has("position"):
			return hit["position"]
	return origin + dir * PING_FALLBACK_DISTANCE


## M10 (tests): the live ping marker of a worker, or null.
func get_ping_marker(peer_id: int) -> Node:
	var marker: Variant = _ping_markers.get(peer_id) # untyped: a freed marker must not raise on assignment
	if not is_instance_valid(marker) or (marker as Node).is_queued_for_deletion():
		_ping_markers.erase(peer_id)
		return null
	return marker as Node


## "$1,234" (negative: "-$50").
static func format_money(amount: int) -> String:
	var digits := str(absi(amount))
	var grouped := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		grouped = digits[i] + grouped
		count += 1
		if count % 3 == 0 and i > 0:
			grouped = "," + grouped
	return ("-$" if amount < 0 else "$") + grouped


## Sfx.play(preferred) if the Sfx autoload knows that sound, else Sfx.play(fallback).
## (Extra sounds beyond the CONTRACTS.md set are optional; this never warns.)
static func play_sfx(preferred: StringName, fallback: StringName) -> void:
	var sfx: Node = Sfx
	if sfx.has_method(&"has_sound") and not bool(sfx.call(&"has_sound", preferred)):
		Sfx.play(fallback)
	elif sfx.has_method(&"has_sound") or preferred == fallback:
		Sfx.play(preferred)
	else:
		Sfx.play(fallback)


## Display text of the first keyboard key bound to an input action ("E", "ENTER"), or fallback.
static func action_key_text(action: StringName, fallback: String) -> String:
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


# ---------------------------------------------------------------------------------------------
# GameState listeners
# ---------------------------------------------------------------------------------------------

func _on_phase_changed(new_phase: int) -> void:
	_stats_ready = new_phase != GameState.Phase.MENU
	if new_phase != GameState.Phase.PLAYING:
		_hide_go_banner()
		_last_tick_second = -1
		_hide_event_banner() # events end with the shift (Events says so too; this is the safety net)
	_update_round_label()
	_apply_time(GameState.time_left, false)
	_update_phase_ui()
	refresh_marks()


# --- M10: write-ups, back room, voice, events, pings --------------------------------------------------------------

## Everyone sees the write-up; the worker it hit hears it and the prompt panel flinches.
func _on_worker_written_up(peer_id: int, reason: String, _count: int) -> void:
	var worker_name := Net.get_player_name(peer_id)
	var text := TEXT_WRITE_UP_PLAIN % worker_name
	# M13 review: the M12 reasons are named too ("Bob written up: arson."). They used to fall through to the plain
	# line, and the Boss only says "Written up, Bob.": nobody was told what the write-up was for.
	if reason in [Const.WRITE_UP_SKIMMING, Const.WRITE_UP_LOITERING, Const.WRITE_UP_ARSON, Const.WRITE_UP_MISUSE, Const.WRITE_UP_ABSENT]:
		text = TEXT_WRITE_UP % [worker_name, reason]
	Game.toast(text, &"error") # through Game so every toast listener (tests included) sees it; lands in show_toast
	play_sfx(&"write_up", &"error")
	if peer_id == _local_peer_id() and is_inside_tree():
		Juice.shake(prompt_panel)
	refresh_marks()


func _on_backroom_changed(_peer_id: int, _active: bool) -> void:
	refresh_marks()


func _on_speaking_changed(peer_id: int, speaking: bool) -> void:
	if speaking:
		_speaking_signal[peer_id] = true
	else:
		_speaking_signal.erase(peer_id)
	_apply_speaking_mark(peer_id)


func _poll_speaking() -> void:
	if _player_rows.is_empty():
		return
	for peer_id: int in _player_rows.keys():
		_apply_speaking_mark(peer_id)


## A worker is "speaking" when Voice said so (signal) or says so now (poll): the signal is the fast path, the poll
## covers a late join / a missed packet. Shown by alpha (the mark keeps its place in the row) with a tired pulse.
func _apply_speaking_mark(peer_id: int) -> void:
	if not _player_rows.has(peer_id):
		return
	var speak: Label = _player_rows[peer_id]["speak"]
	var speaking := bool(_speaking_signal.get(peer_id, false))
	if not speaking:
		var voice: Node = Voice
		if voice != null and voice.has_method(&"is_speaking"):
			speaking = bool(voice.call(&"is_speaking", peer_id))
	var shown := speak.modulate.a > 0.5
	if speaking == shown:
		return
	speak.modulate.a = 1.0 if speaking else 0.0
	if not is_inside_tree():
		return
	var dot := speak.get_parent() as Control # the worker's colour swatch
	if speaking:
		if dot != null:
			Juice.pulse(dot)
	elif dot != null:
		Juice.stop(dot)


func _on_event_started(kind: StringName, params: Dictionary) -> void:
	_event_kind = kind
	_event_params = params
	_show_event_banner(true)


func _on_event_ended(_kind: StringName) -> void:
	_hide_event_banner()


## Late join / HUD built mid-event: pick up the running event from Events without a pop.
func _sync_event_banner() -> void:
	var events: Node = Events
	if events == null or not events.has_method(&"is_event_active"):
		return
	if bool(events.call(&"is_event_active")):
		var kind: Variant = events.get(&"active_event")
		_event_kind = StringName(str(kind)) if kind != null else &""
		_event_params = events.call(&"get_event_params") if events.has_method(&"get_event_params") else {}
		if _event_kind != &"":
			_show_event_banner(false)


func _show_event_banner(pop: bool) -> void:
	event_label.text = _event_title()
	var hint := _event_hint()
	event_hint.text = hint
	event_hint.visible = hint != ""
	var fresh := not event_panel.visible
	event_panel.visible = true
	_update_event_countdown()
	if pop and fresh and is_inside_tree():
		Juice.pop_in(event_panel, 0.25)


func _hide_event_banner() -> void:
	_event_kind = &""
	_event_params = {}
	event_panel.visible = false


func _event_title() -> String:
	match _event_kind:
		&"inspection":
			return TEXT_EVENT_INSPECTION
		&"power_cut":
			return TEXT_EVENT_POWER_CUT
		&"audit":
			return TEXT_EVENT_AUDIT
		&"rat":
			return TEXT_EVENT_RAT
		&"headcount":
			return TEXT_EVENT_HEADCOUNT
		&"water_off":
			return TEXT_EVENT_WATER_OFF
		&"shortage":
			return TEXT_EVENT_SHORTAGE
		&"leak", &"driveby":  # M14 mayhem
			return _mayhem_event_title(_event_kind)
	return String(_event_kind).to_upper().replace("_", " ")


# --- M12 disrupt: the line under the event title ---------------------------------------------------------------

## The hint under the banner title ("" = none): the breaker for a power cut, the line for a head count, the tank
## for the water main, the strain for a shortage (its display name from balance; the raw id made readable otherwise).
func _event_hint() -> String:
	match _event_kind:
		&"power_cut":
			return TEXT_EVENT_POWER_HINT
		&"headcount":
			return TEXT_EVENT_HEADCOUNT_HINT
		&"water_off":
			return TEXT_EVENT_WATER_OFF_HINT
		&"shortage":
			var strain := StringName(str(_event_params.get("strain", "")))
			var def: SeedDef = Config.balance.get_seed(strain) if strain != &"" else null
			var who := def.display_name if def != null else (String(strain).capitalize() if strain != &"" else "Stock")
			return TEXT_EVENT_SHORTAGE_HINT % who
		&"leak", &"driveby":  # M14 mayhem
			return _mayhem_event_hint(_event_kind)
	return ""


# --- M14 mayhem: the leak and the drive-by on the banner ----------------------------------------------------------
const TEXT_EVENT_LEAK := "LEAK"
const TEXT_EVENT_LEAK_HINT := "Hold %s on the tank."
const TEXT_EVENT_DRIVEBY := "DRIVE-BY"
const TEXT_EVENT_DRIVEBY_HINT := "Get down."


func _mayhem_event_title(kind: StringName) -> String:
	return TEXT_EVENT_DRIVEBY if kind == &"driveby" else TEXT_EVENT_LEAK


func _mayhem_event_hint(kind: StringName) -> String:
	if kind == &"driveby":
		return TEXT_EVENT_DRIVEBY_HINT
	return TEXT_EVENT_LEAK_HINT % action_key_text(&"interact", "E")
# --- end M14 mayhem ----------------------------------------------------------------------------------------------


func _update_event_countdown() -> void:
	var text := _event_title()
	var events: Node = Events
	if events != null and events.has_method(&"get_event_time_left"):
		var left := float(events.call(&"get_event_time_left"))
		if left > 0.0:
			var total := ceili(left)
			@warning_ignore("integer_division")
			text += " %d:%02d" % [total / 60, total % 60]
	if event_label.text != text:
		event_label.text = text


## A ping landed: one marker per worker under Game.world (their previous one goes), a sound at the point.
func _on_ping_received(peer_id: int, position: Vector3) -> void:
	var world: Node = Game.world
	if world == null or not is_instance_valid(world) or not world.is_inside_tree():
		return
	var old: Variant = _ping_markers.get(peer_id)
	if is_instance_valid(old):
		(old as Node).queue_free()
	_ping_markers.erase(peer_id)
	var marker := PING_MARKER_SCENE.instantiate() as PingMarker
	world.add_child(marker)
	marker.place(peer_id, position)
	_ping_markers[peer_id] = marker
	Sfx.play(&"ping", position)


func _on_round_started(round_number: int) -> void:
	_last_tick_second = -1
	_update_round_label()
	go_banner.text = TEXT_GO % round_number
	go_banner.modulate.a = 1.0
	go_banner.visible = true
	play_sfx(&"round_start", &"ui_open")
	if not is_inside_tree():
		return
	Juice.pop_in(go_banner)
	if _go_tween != null:
		_go_tween.kill()
	_go_tween = create_tween()
	_go_tween.tween_interval(GO_BANNER_SEC)
	_go_tween.tween_property(go_banner, "modulate:a", 0.0, GO_FADE_SEC)
	_go_tween.tween_callback(go_banner.hide)


func _on_money_changed(money: int) -> void:
	money_label.text = format_money(money)
	if _stats_ready and money != _last_money and is_inside_tree():
		Juice.punch_ui(money_label)
	_last_money = money


func _on_sales_changed(round_sales: int, quota: int) -> void:
	var changed := round_sales != _last_sales
	_apply_sales(round_sales, quota, _stats_ready and changed)
	if _stats_ready and changed and not Config.balance.end_round_on_quota_met \
			and GameState.phase == GameState.Phase.PLAYING and _last_sales < quota and round_sales >= quota:
		show_toast(TEXT_COVERED, &"success")
	_last_sales = round_sales


func _on_time_changed(time_left: float) -> void:
	_apply_time(time_left, true)


func _on_sale_made(amount: int, _seller_peer: int) -> void:
	if amount > 0:
		_spawn_money_float("+" + format_money(amount), _theme_color(&"font_color", &"SuccessLabel", Color.PALE_GREEN), true)


func _on_purchase_made(cost: int, _buyer_peer: int, _what: String) -> void:
	if cost > 0:
		_spawn_money_float("-" + format_money(cost), _theme_color(&"font_color", &"ErrorLabel", Color.SALMON), false)


func _on_game_reset() -> void:
	show_toast(TEXT_RESET, &"info")


# --- M14 lobby --------------------------------------------------------------------------------------------------
# In the alley (phase WAITING with the lobby on: the van's synced head count says so) the centre banner reads
# "Everyone in the van. 2 / 4 in." / "Doors closing 2" / "Doors closed." instead of the Enter hint; the host's Enter
# still works (it leaves without the rest) and the tip says so. A ride (GameState.transition_started) fades the whole
# screen to black over `seconds`, holds GameState.TRANSITION_HOLD_SEC and fades back in, with the van's door at the
# start. The fade sits on its own CanvasLayer above every other UI and never takes the mouse.

const TEXT_LOBBY_TITLE := "THE VAN IS WAITING"
const TEXT_LOBBY_COUNT := "Everyone in the van. %d / %d in."
const TEXT_LOBBY_CLOSING := "Doors closing %d"
const TEXT_LOBBY_CLOSED := "Doors closed."
const TEXT_LOBBY_TIP_HOST := "%s · leave without the rest\n%s · chat"
const TEXT_LOBBY_TIP := "%s · chat"
## The fade's CanvasLayer (above the supply window on 5 and everything on the HUD's own layer).
const TRANSITION_LAYER: int = 60
## Near-black, never pure black (STYLE: the void colour).
const TRANSITION_COLOR := Color("040405")

var _fade_layer: CanvasLayer
var _fade_rect: ColorRect
var _fade_tween: Tween
var _lobby_van_ref: WeakRef
var _lobby_last_second: int = 0


func _lobby_ready() -> void:
	GameState.transition_started.connect(_on_transition_started)
	_fade_layer = CanvasLayer.new()
	_fade_layer.name = "TransitionFade"
	_fade_layer.layer = TRANSITION_LAYER
	_fade_rect = ColorRect.new()
	_fade_rect.name = "Black"
	_fade_rect.color = TRANSITION_COLOR
	_fade_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade_rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_fade_rect.modulate.a = 0.0
	_fade_rect.visible = false
	_fade_layer.add_child(_fade_rect)
	add_child(_fade_layer)
	_lobby_van()


## The alley's van (World/Lobby/Van), connected once it is found; null in a world without an alley.
func _lobby_van() -> Van:
	var cached: Object = _lobby_van_ref.get_ref() if _lobby_van_ref != null else null
	if cached != null:
		return cached as Van
	var world: World = Game.world
	if world == null or not is_instance_valid(world):
		world = get_parent() as World
	var alley: Lobby = world.lobby if world != null else null
	var van: Van = alley.get_van() if alley != null else null
	if van == null:
		return null
	_lobby_van_ref = weakref(van)
	if not van.changed.is_connected(_on_lobby_van_changed):
		van.changed.connect(_on_lobby_van_changed)
	return van


## True while this peer waits in the alley: WAITING and the host runs the lobby.
func is_lobby_banner() -> bool:
	var van := _lobby_van()
	return GameState.phase == GameState.Phase.WAITING and van != null and van.is_lobby_on()


## The line under the banner title while waiting in the alley ("" otherwise): tests and the banner itself.
func get_lobby_text() -> String:
	if not is_lobby_banner():
		return ""
	var van := _lobby_van()
	if van.is_departing():
		return TEXT_LOBBY_CLOSED
	if van.is_counting():
		return TEXT_LOBBY_CLOSING % van.get_countdown_seconds()
	return TEXT_LOBBY_COUNT % [van.occupants, van.total]


func _lobby_apply_banner(host: bool) -> void:
	if not is_lobby_banner():
		return
	banner_title.text = TEXT_LOBBY_TITLE
	banner_text.text = get_lobby_text()
	banner_tip.visible = true
	if host:
		banner_tip.text = TEXT_LOBBY_TIP_HOST % [action_key_text(&"start_round", "ENTER"), action_key_text(&"chat", "T")]
	else:
		banner_tip.text = TEXT_LOBBY_TIP % action_key_text(&"chat", "T")
	start_button.visible = false # the mouse is captured out here; Enter is the way (the tip says so)


func _on_lobby_van_changed() -> void:
	var van := _lobby_van()
	var second := van.get_countdown_seconds() if van != null else 0
	if second != _lobby_last_second:
		if second > 0 and is_lobby_banner():
			play_sfx(&"tick", &"ui_click")
		_lobby_last_second = second
	_update_phase_ui()


## True while the fade covers (part of) the screen.
func is_transition_showing() -> bool:
	return _fade_rect != null and _fade_rect.visible


## 0 = clear, 1 = black.
func get_transition_alpha() -> float:
	return _fade_rect.modulate.a if is_transition_showing() else 0.0


func _on_transition_started(_kind: StringName, seconds: float) -> void:
	play_sfx(&"van_door", &"door_slam")
	if _fade_rect == null:
		return
	if _fade_tween != null and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_rect.visible = true
	if not is_inside_tree():
		_fade_rect.modulate.a = 0.0
		_fade_rect.visible = false
		return
	_fade_tween = create_tween()
	if seconds > 0.0:
		_fade_tween.tween_property(_fade_rect, "modulate:a", 1.0, seconds).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	else:
		_fade_rect.modulate.a = 1.0
	_fade_tween.tween_interval(GameState.TRANSITION_HOLD_SEC)
	_fade_tween.tween_property(_fade_rect, "modulate:a", 0.0, maxf(seconds, 0.05)).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	_fade_tween.tween_callback(_fade_rect.hide)

# --- end M14 lobby ------------------------------------------------------------------------------------------------


# --- M15 career: the job line under the payment bar, job titles in the WORKERS list --------------------------------
# The job: one Label ("JobLine") in its own container "CareerBox", the last child of the payment panel's VBox
# (Root/Stats/QuotaColumn/QuotaPanel/VBox/CareerBox), built here so the scene file stays untouched. It reads
# "Job: three cured bundles 1 / 3" (Contracts.hud_text), dims with " · paid" / " · failed" once it is settled and is
# hidden without a job (replay off: always). Trimmed with "…" rather than widening the panel.
# The titles: Net.get_player_title(peer) in small type on a line of its own under the worker's row (a second child of
# %PlayerList per worker, only for workers who sent a title: the row itself keeps its width for the name and marks).

const JOB_FONT_SIZE: int = 16
## Alpha of the job line once it is paid or failed.
const JOB_SETTLED_ALPHA: float = 0.5
const TITLE_FONT_SIZE: int = 12
## The title starts under the name: the colour dot (16) plus the row's separation (8).
const TITLE_INDENT: float = 24.0
const TITLE_ALPHA: float = 0.75

var _career_box: VBoxContainer
var _career_job_label: Label


func _career_ready() -> void:
	_career_box = VBoxContainer.new()
	_career_box.name = "CareerBox"
	_career_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_career_box.visible = false
	_career_job_label = Label.new()
	_career_job_label.name = "JobLine"
	_career_job_label.theme_type_variation = &"HudLabel"
	_career_job_label.add_theme_font_size_override(&"font_size", JOB_FONT_SIZE)
	_career_job_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_career_job_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_career_job_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_career_box.add_child(_career_job_label)
	quota_bar.get_parent().add_child(_career_box)
	if GameState.has_signal(&"contract_changed"):
		GameState.connect(&"contract_changed", _career_refresh_job)
	if GameState.has_signal(&"contract_met"):
		GameState.connect(&"contract_met", _career_on_contract_met)
	if Net.has_signal(&"titles_changed"):
		Net.connect(&"titles_changed", refresh_players)
	_career_refresh_job()


func _career_refresh_job() -> void:
	if _career_job_label == null:
		return
	var job: Dictionary = GameState.get_contract() if GameState.has_method(&"get_contract") else {}
	var text := Contracts.hud_text(job)
	_career_job_label.text = text
	var settled := bool(job.get("done", false)) or bool(job.get("failed", false))
	_career_job_label.modulate.a = JOB_SETTLED_ALPHA if settled else 1.0
	_career_box.visible = text != ""


func _career_on_contract_met(_contract: Dictionary) -> void:
	play_sfx(&"contract", &"coin")
	if is_inside_tree() and _career_job_label != null and _career_box.visible:
		Juice.punch_ui(_career_job_label)


## The job line as shown ("" while hidden).
func get_job_text() -> String:
	return _career_job_label.text if _career_job_label != null and _career_box.visible else ""


## True while the job line is dimmed (paid or failed).
func is_job_settled() -> bool:
	return get_job_text() != "" and _career_job_label.modulate.a < 0.99


## The job title shown under a worker's name ("" when they have none).
func get_title_text(peer_id: int) -> String:
	if not _player_rows.has(peer_id):
		return ""
	var label: Variant = (_player_rows[peer_id] as Dictionary).get("title")
	return (label as Label).text if label is Label and is_instance_valid(label) else ""


func _career_add_title(peer_id: int, color: Color) -> void:
	var title := Net.get_player_title(peer_id) if Net.has_method(&"get_player_title") else ""
	if title == "" or not _player_rows.has(peer_id):
		return
	var line := HBoxContainer.new()
	line.name = "Title%d" % peer_id
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override(&"separation", 0)
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(TITLE_INDENT, 0.0)
	pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_child(pad)
	var label := _player_label(title, color, TITLE_FONT_SIZE)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.modulate.a = TITLE_ALPHA
	line.add_child(label)
	player_list.add_child(line)
	(_player_rows[peer_id] as Dictionary)["title"] = label

# --- end M15 career ------------------------------------------------------------------------------------------------


# ---------------------------------------------------------------------------------------------
# Game / player listeners
# ---------------------------------------------------------------------------------------------

func _on_local_player_spawned(player: Node) -> void:
	_set_local_player(player)


func _on_ui_lock_changed(locked: bool) -> void:
	_ui_locked = locked
	crosshair.visible = not locked
	_refresh_prompt()
	_update_phase_ui()


func _on_prompt_changed(text: String, enabled: bool) -> void:
	_prompt_text = text
	_prompt_enabled = enabled
	_refresh_prompt()


func _on_start_pressed() -> void:
	Sfx.play(&"ui_click")
	GameState.request_start_round()


## The pause menu closed: if the round-end overlay is up underneath, it gets the keyboard back (armed, not at once).
func _on_pause_closed() -> void:
	if round_end.is_open():
		round_end.arm_focus()


func _on_crosshair_draw() -> void:
	var center := crosshair.size * 0.5
	crosshair.draw_circle(center, CROSSHAIR_RADIUS + 1.5, _theme_color(&"font_outline_color", &"Label", Color.BLACK))
	crosshair.draw_circle(center, CROSSHAIR_RADIUS, _theme_color(&"font_color", &"Label", Color.WHITE))


# ---------------------------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------------------------

func _set_local_player(player: Node) -> void:
	if player == _local_player and is_instance_valid(player):
		return
	if is_instance_valid(_local_player) and _local_player.tree_exiting.is_connected(_on_local_player_exiting):
		_local_player.tree_exiting.disconnect(_on_local_player_exiting)
	_local_player = player if is_instance_valid(player) else null
	_has_local_player = _local_player != null
	var interactor: Object = null
	if _local_player != null:
		_local_player.tree_exiting.connect(_on_local_player_exiting)
		if _local_player.has_method(&"get_interactor"):
			interactor = _local_player.call(&"get_interactor")
	set_prompt_source(interactor)
	_update_held_item()
	if is_inside_tree(): # at shutdown the HUD may leave the tree before the player does
		refresh_players()


## The local player node is leaving (despawn / back to menu): drop prompt + held item right away.
func _on_local_player_exiting() -> void:
	_set_local_player(null)


## Picks up Game.local_player if it appeared without the signal (or was replaced / freed), and
## notices a freed interactor. (A freed Object compares equal to null, hence the _has_* flags.)
func _poll_local_player() -> void:
	var current: Node = Game.local_player
	if not is_instance_valid(current) or current.is_queued_for_deletion():
		current = null
	var mine: Node = _local_player if is_instance_valid(_local_player) else null
	if current != mine or (mine == null and _has_local_player):
		_set_local_player(current)
		return
	if _has_prompt_source and not is_instance_valid(_prompt_source):
		set_prompt_source(null)
	if mine != null and not _has_prompt_source and mine.has_method(&"get_interactor"):
		# The interactor may appear after the player node: retry until it exists.
		var interactor: Object = mine.call(&"get_interactor")
		if is_instance_valid(interactor):
			set_prompt_source(interactor)


func _update_held_item() -> void:
	var text := ""
	var player: Node = _local_player if is_instance_valid(_local_player) else null
	if player != null and player.is_inside_tree() and player.has_method(&"get_held_item"):
		var item: Object = player.call(&"get_held_item")
		if is_instance_valid(item):
			var item_name := str(item)
			if item.has_method(&"get_label_text"): # "Watering Can (3/4)"
				item_name = str(item.call(&"get_label_text"))
			elif item.has_method(&"get_display_name"):
				item_name = str(item.call(&"get_display_name"))
			text = TEXT_CARRYING % item_name
	if text == _held_text:
		return
	_held_text = text
	held_label.text = text
	held_panel.visible = text != ""
	if text != "" and is_inside_tree():
		Juice.bounce(held_panel)


func _refresh_prompt() -> void:
	var show_it := _prompt_text != "" and not _ui_locked
	prompt_panel.visible = show_it
	if not show_it:
		return
	if _prompt_enabled:
		var text := _prompt_text
		if not text.begins_with("["):
			text = "[%s] %s" % [action_key_text(&"interact", "E"), text]
		prompt_label.text = text
		prompt_label.theme_type_variation = &"HudLabel"
		prompt_panel.modulate = Color.WHITE
	else:
		prompt_label.text = _prompt_text
		prompt_label.theme_type_variation = &"SubtleLabel"
		prompt_panel.modulate = Color(1.0, 1.0, 1.0, 0.8)


func _update_round_label() -> void:
	round_label.text = TEXT_SHIFT % GameState.round_number


func _apply_time(time_left: float, allow_tick: bool) -> void:
	timer_label.text = GameState.get_time_string()
	var danger := GameState.phase == GameState.Phase.PLAYING and time_left < TIMER_WARN_SEC
	if danger != _timer_danger:
		_timer_danger = danger
		if danger:
			timer_label.add_theme_color_override(&"font_color", _theme_color(&"font_color", &"ErrorLabel", Color.TOMATO))
		else:
			timer_label.remove_theme_color_override(&"font_color")
	if not danger:
		return
	var second := ceili(time_left)
	if second <= 0:
		return
	if _last_tick_second < 0 or second < _last_tick_second:
		_last_tick_second = second
		if allow_tick:
			play_sfx(&"countdown" if second <= COUNTDOWN_SEC else &"tick", &"tick")
			if is_inside_tree():
				Juice.punch_ui(timer_label)


func _apply_sales(round_sales: int, quota: int, juicy: bool) -> void:
	quota_label.text = TEXT_PAYMENT % [format_money(round_sales), format_money(quota)]
	quota_bar.max_value = float(maxi(quota, 1))
	var target := float(clampi(round_sales, 0, maxi(quota, 1)))
	if _bar_tween != null:
		_bar_tween.kill()
		_bar_tween = null
	if juicy and is_inside_tree():
		_bar_tween = create_tween()
		_bar_tween.tween_property(quota_bar, "value", target, BAR_TWEEN_SEC).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		Juice.punch_ui(quota_label)
	else:
		quota_bar.value = target
	var done := quota > 0 and round_sales >= quota
	if done:
		if _bar_done_style == null:
			var base := quota_bar.get_theme_stylebox(&"fill")
			if base is StyleBoxFlat:
				var style := (base as StyleBoxFlat).duplicate() as StyleBoxFlat
				style.bg_color = _theme_color(&"font_color", &"SuccessLabel", Color.LIME_GREEN)
				style.border_color = style.bg_color.darkened(0.3)
				_bar_done_style = style
		if _bar_done_style != null:
			quota_bar.add_theme_stylebox_override(&"fill", _bar_done_style)
	else:
		quota_bar.remove_theme_stylebox_override(&"fill")


func _update_phase_ui() -> void:
	var phase := GameState.phase
	stats.visible = phase != GameState.Phase.MENU
	var host := GameState.is_local_host()
	match phase:
		GameState.Phase.MENU:
			banner_title.text = TEXT_JOINING_TITLE
			banner_text.text = TEXT_JOINING
			start_button.visible = false
			banner_tip.visible = false
		GameState.Phase.WAITING:
			banner_tip.visible = true
			banner_tip.text = TEXT_BANNER_TIP % action_key_text(&"chat", "T")
			if host:
				banner_title.text = TEXT_WAIT_HOST_TITLE
				banner_text.text = TEXT_WAIT_HOST % action_key_text(&"start_round", "ENTER")
				start_button.visible = true
			else:
				banner_title.text = TEXT_WAIT_CLIENT_TITLE
				banner_text.text = TEXT_WAIT_CLIENT
				start_button.visible = false
	_lobby_apply_banner(host) # M14 lobby: in the alley the banner counts heads instead
	var want_banner := (phase == GameState.Phase.MENU or phase == GameState.Phase.WAITING) and not _ui_locked
	if want_banner and not banner.visible and is_inside_tree():
		banner.visible = true
		Juice.pop_in(banner)
	banner.visible = want_banner


func _hide_go_banner() -> void:
	if _go_tween != null:
		_go_tween.kill()
		_go_tween = null
	go_banner.visible = false


func _spawn_money_float(text: String, color: Color, gain: bool) -> void:
	if not is_inside_tree() or not wallet_panel.is_visible_in_tree():
		return
	var rect := wallet_panel.get_global_rect()
	var label := Label.new()
	label.theme_type_variation = &"MoneyLabel"
	label.add_theme_font_size_override(&"font_size", 28)
	label.add_theme_color_override(&"font_color", color)
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.size = Vector2(FLOAT_WIDTH, 40.0)
	# Just left of the wallet: gains rise into it, costs drop out of it.
	var drift := FLOAT_RISE_PX * 0.5
	var start_y := rect.get_center().y - label.size.y * 0.5 + (drift if gain else -drift)
	label.position = Vector2(rect.position.x - FLOAT_WIDTH - 8.0, start_y)
	float_layer.add_child(label)
	Juice.punch_ui(label)
	var end_y := start_y - FLOAT_RISE_PX if gain else start_y + FLOAT_RISE_PX
	var tween := label.create_tween().set_parallel(true)
	tween.tween_property(label, "position:y", end_y, FLOAT_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(label, "modulate:a", 0.0, FLOAT_SEC).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(label.queue_free)


func _player_label(text: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.theme_type_variation = &"HudLabel"
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", color)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.text = text
	return label


## Trims a long name with "…" so the row (and the WORKERS panel) stays within PLAYERS_MAX_WIDTH. Needs the theme,
## so only once the row is in the tree (an off-tree HUD is about to be freed anyway).
func _fit_player_name(row: HBoxContainer, name_label: Label) -> void:
	if not name_label.is_inside_tree():
		return
	# Marks come and go (refresh_marks): start from the whole name again, then trim if the row needs it.
	name_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	name_label.custom_minimum_size.x = 0.0
	var panel_style := players_panel.get_theme_stylebox(&"panel")
	var used := panel_style.get_minimum_size().x if panel_style != null else 0.0
	var separation := float(row.get_theme_constant(&"separation"))
	for child: Node in row.get_children():
		var control := child as Control
		if control != name_label and control != null and control.visible:
			used += control.get_combined_minimum_size().x + separation
	var room := floorf(PLAYERS_MAX_WIDTH - used)
	if name_label.get_minimum_size().x > room:
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.custom_minimum_size.x = maxf(room, 0.0)


## Color of `item` in theme type `type` (e.g. a variation), or `fallback` if the theme lacks it.
func _theme_color(item: StringName, type: StringName, fallback: Color) -> Color:
	if root_control.has_theme_color(item, type):
		return root_control.get_theme_color(item, type)
	return fallback


func _live_toasts() -> Array[HudToast]:
	var out: Array[HudToast] = []
	for child: Node in toasts.get_children():
		var toast := child as HudToast
		if toast != null and not toast.is_queued_for_deletion() and not toast.is_dismissing():
			out.append(toast)
	return out


func _local_peer_id() -> int:
	var mp: MultiplayerAPI = multiplayer if is_inside_tree() else null
	if mp == null or not mp.has_multiplayer_peer():
		return 0
	return mp.get_unique_id()
