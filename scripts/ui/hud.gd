class_name HUD
extends CanvasLayer
## In-game HUD (scenes/ui/hud.tscn, instanced as World/HUD). Owned by the game-flow/UI agent.
##
##   top-left      SHIFT n + big mm:ss timer (red + tick each second under TIMER_WARN_SEC)
##   top-centre    the payment: "PAYMENT DUE $deposited / $owed" + progress bar (punches on every deposit)
##   top-right     cash on hand (punch on change, +$/-$ floats on deposits/purchases) + WORKERS list
##   bottom-left   held item ("Carrying: Watering Can (3/4)"), polled every HELD_POLL_SEC
##   bottom-centre interaction prompt, fed by Game.local_player.get_interactor().prompt_changed
##   centre        phase banner (WAITING: host START SHIFT / clients wait), "SHIFT n — GET TO WORK"
##   bottom-right  toast stack (Game.toast_requested / show_toast), max MAX_TOASTS visible
##   overlays      %RoundEnd (round_end.tscn) and %PauseMenu (pause_menu.tscn)
## Copy is flat and joyless on purpose (STYLE.md "Mood & tone"): no "!" and no cheer.
## Null-safe before the local player spawns and when Net is offline (solo tests).

const TOAST_SCENE: PackedScene = preload("res://scenes/ui/toast.tscn")
const MAX_TOASTS: int = 4
const HELD_POLL_SEC: float = 0.1
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

	_ui_locked = Game.is_ui_locked()
	_stats_ready = GameState.phase != GameState.Phase.MENU
	_last_money = GameState.money
	_last_sales = GameState.round_sales
	refresh_all()
	var existing: Node = Game.local_player
	if is_instance_valid(existing):
		_set_local_player(existing)


func _process(delta: float) -> void:
	_held_poll_accum += delta
	if _held_poll_accum >= HELD_POLL_SEC:
		_held_poll_accum = 0.0
		_poll_local_player()
		_update_held_item()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"start_round") or event.is_echo():
		return
	if GameState.phase == GameState.Phase.WAITING and GameState.is_local_host() and not Game.is_ui_locked():
		get_viewport().set_input_as_handled()
		_on_start_pressed()


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


## Rebuilds the player list from Net.players (names in their colors).
func refresh_players() -> void:
	for child: Node in player_list.get_children():
		player_list.remove_child(child)
		child.queue_free()
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
		var name_label := _player_label(Net.get_player_name(peer_id), color, PLAYER_NAME_FONT_SIZE)
		row.add_child(name_label)
		var tags: PackedStringArray = []
		if peer_id == Const.SERVER_PEER_ID:
			tags.append(TEXT_HOST_TAG)
		if peer_id == local_id:
			tags.append(TEXT_YOU_TAG)
		if not tags.is_empty():
			row.add_child(_player_label("(%s)" % ", ".join(tags), color, PLAYER_TAG_FONT_SIZE))
		player_list.add_child(row)
		_fit_player_name(row, name_label)


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
	_update_round_label()
	_apply_time(GameState.time_left, false)
	_update_phase_ui()


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
			if host:
				banner_title.text = TEXT_WAIT_HOST_TITLE
				banner_text.text = TEXT_WAIT_HOST % action_key_text(&"start_round", "ENTER")
				start_button.visible = true
			else:
				banner_title.text = TEXT_WAIT_CLIENT_TITLE
				banner_text.text = TEXT_WAIT_CLIENT
				start_button.visible = false
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
	var panel_style := players_panel.get_theme_stylebox(&"panel")
	var used := panel_style.get_minimum_size().x if panel_style != null else 0.0
	var separation := float(row.get_theme_constant(&"separation"))
	for child: Node in row.get_children():
		if child != name_label:
			used += (child as Control).get_combined_minimum_size().x + separation
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
