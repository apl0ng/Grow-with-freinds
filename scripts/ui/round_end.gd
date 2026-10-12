class_name RoundEndOverlay
extends Control
## Full-screen end-of-shift overlay (scenes/ui/round_end.tscn, instanced by the HUD as %RoundEnd).
## Visible while GameState.phase is ROUND_SUCCESS or ROUND_FAILED (so late joiners see it too) and
## holds Game.set_ui_lock(&"round_end") while visible (player input off, mouse free).
##   Paid   - host: NEXT SHIFT + MAIN MENU            clients: "Waiting for the Boss's decision…" + LEAVE
##   Missed - host: START OVER (full reset) + MAIN MENU   clients: "Waiting for the Boss's decision…" + LEAVE
## Grim relief, never victory (STYLE.md "Mood & tone"): off-white title, no gold banner, no "!".
## Keyboard: the host's primary button gets focus FOCUS_DELAY_SEC after the overlay appears, so a jump (Space) or
## Enter pressed just as the shift ends cannot skip the screen (START OVER resets everyone); never while the pause
## menu sits on top (it keeps the keyboard; the HUD calls arm_focus() when it closes). Clients get no default focus
## (Space must not LEAVE the session); Tab / arrow keys focus the first button when nothing has focus.
## M10: the "SHIFT REPORT" block (%Report, shift_report.tscn: one row per worker, verdict lines from Story) sits
## under the shift stats and follows GameState.stats_changed / Net.players_changed while the overlay is up. The card
## must keep fitting 1280 x 720 with four workers (review_ui / ui_m10 check it).
## M17 finale: when the final notice was paid (GameState.is_run_cleared()) the card reads "PAID IN FULL" / "The debt
## is cleared. He will find another.", the host's button is NEW RUN (request_retry: a full reset, a new run code
## unless one was typed; with the lobby on it leads back to the alley) and NEXT SHIFT is not offered; the sound is
## paid_in_full. Clients see the waiting line as for any end of shift.

const LOCK_SOURCE: StringName = &"round_end"
## Seconds before the host's default button takes the keyboard focus (see above).
const FOCUS_DELAY_SEC: float = 0.6
## Keys that give an unfocused overlay its keyboard focus.
const NAV_ACTIONS: Array[StringName] = [&"ui_focus_next", &"ui_focus_prev", &"ui_up", &"ui_down", &"ui_left", &"ui_right"]

const TEXT_PAID_TITLE := "PAYMENT ACCEPTED…\nfor now"
const TEXT_PAID_SUB := "Shift %d paid. The Boss raises the number."
const TEXT_MISSED_TITLE := "YOU MISSED THE PAYMENT"
const TEXT_MISSED_SUB := "Nobody leaves. Start over."
const TEXT_NEXT_KEY := "Next payment"
const TEXT_PAID_KEY := "Shifts paid"
const TEXT_NEXT_SHIFT := "NEXT SHIFT"
const TEXT_START_OVER := "START OVER"
const TEXT_WAITING := "Waiting for the Boss's decision…"
const TEXT_MAIN_MENU := "MAIN MENU"
const TEXT_LEAVE := "LEAVE"
# --- M17 finale ---
const TEXT_CLEARED_TITLE := "PAID IN FULL"
const TEXT_CLEARED_SUB := "The debt is cleared. He will find another."
const TEXT_NEW_RUN := "NEW RUN"
# --- end M17 finale ---

var _locked: bool = false
var _shown_phase: int = -1
var _focus_tween: Tween

@onready var card: Control = %Card
@onready var title_label: Label = %Title
@onready var subtitle_label: Label = %Subtitle
@onready var round_value: Label = %RoundValue
@onready var sold_value: Label = %SoldValue
@onready var time_key: Label = %TimeKey
@onready var time_value: Label = %TimeValue
@onready var wallet_value: Label = %WalletValue
@onready var next_key: Label = %NextKey
@onready var next_value: Label = %NextValue
@onready var waiting_label: Label = %WaitingLabel
@onready var primary_button: Button = %PrimaryButton
@onready var menu_button: Button = %MenuButton
@onready var report: ShiftReport = %Report


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_ended.connect(_on_round_ended)
	GameState.money_changed.connect(_on_money_changed)
	GameState.sales_changed.connect(_on_sales_changed)
	GameState.stats_changed.connect(_on_stats_changed) # M10: the shift report follows the ledger
	Net.players_changed.connect(_on_players_changed) # the next payment scales with the team (+ report rows)
	primary_button.pressed.connect(_on_primary_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	_runcard_ready() # M25 runcard: THE RUN block under the shift report (region below)
	_sync_to_phase(GameState.phase)


func _exit_tree() -> void:
	_set_locked(false)


func _unhandled_input(event: InputEvent) -> void:
	if not visible or event.is_echo() or not event.is_pressed():
		return
	var vp := get_viewport()
	if vp == null or vp.gui_get_focus_owner() != null or Game.is_ui_locked_by(PauseMenu.LOCK_SOURCE):
		return
	for action: StringName in NAV_ACTIONS:
		if InputMap.has_action(action) and event.is_action_pressed(action):
			_cancel_focus()
			(primary_button if primary_button.visible else menu_button).grab_focus()
			vp.set_input_as_handled()
			return


## True while the overlay is up (ROUND_SUCCESS / ROUND_FAILED).
func is_open() -> bool:
	return visible


func _on_phase_changed(new_phase: int) -> void:
	_sync_to_phase(new_phase)


func _sync_to_phase(new_phase: int) -> void:
	var over := new_phase == GameState.Phase.ROUND_SUCCESS or new_phase == GameState.Phase.ROUND_FAILED
	if not over:
		_shown_phase = -1
		_cancel_focus()
		visible = false
		_set_locked(false)
		return
	var fresh := not visible or _shown_phase != new_phase
	_shown_phase = new_phase
	refresh()
	visible = true
	_set_locked(true)
	if fresh:
		if is_inside_tree():
			Juice.pop_in(card)
		arm_focus()


## Host: gives the primary button the keyboard focus FOCUS_DELAY_SEC from now (restarts a pending one).
func arm_focus() -> void:
	_cancel_focus()
	if not is_inside_tree() or not visible:
		return
	_focus_tween = create_tween()
	_focus_tween.tween_interval(FOCUS_DELAY_SEC)
	_focus_tween.tween_callback(focus_default)


## Host: focuses the primary button now, unless the overlay is hidden, the pause menu sits on top of it, or one of
## its buttons already has the focus (the player navigated there).
func focus_default() -> void:
	if not visible or not is_inside_tree() or not primary_button.visible:
		return
	if Game.is_ui_locked_by(PauseMenu.LOCK_SOURCE):
		return
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and is_ancestor_of(focused):
		return
	primary_button.grab_focus()


func _cancel_focus() -> void:
	if _focus_tween != null:
		_focus_tween.kill()
		_focus_tween = null


func _on_round_ended(success: bool, _round_number: int) -> void:
	if success and _is_cleared(): # M17 finale: the ledger closes, no bell
		Sfx.play(&"paid_in_full") # M17 finale
		return # M17 finale
	Sfx.play(&"round_win" if success else &"round_lose")


func _on_money_changed(_money: int) -> void:
	if visible:
		refresh()


func _on_sales_changed(_sales: int, _quota: int) -> void:
	if visible:
		refresh()


func _on_players_changed() -> void:
	if visible:
		refresh()


func _on_stats_changed() -> void:
	if visible:
		report.refresh()


## Rebuilds every text/button from GameState (public so tests / the HUD can force it).
func refresh() -> void:
	var success := GameState.phase == GameState.Phase.ROUND_SUCCESS
	var host := GameState.is_local_host()
	var round_number := GameState.round_number
	var cleared := success and _is_cleared() # M17 finale

	title_label.theme_type_variation = &"TitleLabel"
	if cleared: # M17 finale: the run is over
		title_label.text = TEXT_CLEARED_TITLE # M17 finale
		title_label.remove_theme_color_override(&"font_color") # M17 finale
		subtitle_label.text = TEXT_CLEARED_SUB # M17 finale
	elif success:
		title_label.text = TEXT_PAID_TITLE
		title_label.remove_theme_color_override(&"font_color")
		subtitle_label.text = TEXT_PAID_SUB % round_number
	else:
		title_label.text = TEXT_MISSED_TITLE
		var red := get_theme_color(&"font_color", &"ErrorLabel") if has_theme_color(&"font_color", &"ErrorLabel") else Color.TOMATO
		title_label.add_theme_color_override(&"font_color", red)
		subtitle_label.text = TEXT_MISSED_SUB

	round_value.text = str(round_number)
	sold_value.text = "%s / %s" % [HUD.format_money(GameState.round_sales), HUD.format_money(GameState.quota)]
	wallet_value.text = HUD.format_money(GameState.money)
	time_key.visible = success
	time_value.visible = success
	time_value.text = GameState.get_time_string()
	if cleared: # M17 finale: there is no next payment; the row counts the shifts the run took
		next_key.text = TEXT_PAID_KEY # M17 finale
		next_value.text = str(round_number) # M17 finale
	elif success:
		next_key.text = TEXT_NEXT_KEY
		next_value.text = HUD.format_money(GameState.get_quota_for(round_number + 1))
	else:
		next_key.text = TEXT_PAID_KEY
		next_value.text = str(maxi(round_number - 1, 0))

	report.refresh()
	if run_card != null: run_card.refresh() # M25 runcard: shown only when the run ends (PAID IN FULL / a missed payment)

	primary_button.visible = host
	primary_button.text = TEXT_NEXT_SHIFT if success else TEXT_START_OVER
	primary_button.theme_type_variation = &"BigButton" if success else &"GoldButton"
	if cleared: # M17 finale: NEXT SHIFT is not offered, the one way on is a new run
		primary_button.text = TEXT_NEW_RUN # M17 finale
	waiting_label.visible = not host
	waiting_label.text = TEXT_WAITING
	menu_button.text = TEXT_MAIN_MENU if host else TEXT_LEAVE


func _on_primary_pressed() -> void:
	Sfx.play(&"ui_click")
	if GameState.phase == GameState.Phase.ROUND_SUCCESS and _is_cleared(): # M17 finale: NEW RUN
		GameState.request_retry() # M17 finale: a full reset (a new run code unless one was typed; the alley with the lobby on)
	elif GameState.phase == GameState.Phase.ROUND_SUCCESS:
		GameState.request_next_round()
	elif GameState.phase == GameState.Phase.ROUND_FAILED:
		GameState.request_retry()


func _on_menu_pressed() -> void:
	Sfx.play(&"ui_click")
	Game.return_to_menu()


# --- M25 runcard ---
# "THE RUN" (RunCard, scripts/ui/run_card.gd): made here once and put right under the shift report (%ReportCard), above
# the waiting line and the buttons. refresh() shows it when the run ends (GameState.is_run_over(): PAID IN FULL, or a
# missed payment: the card that offers START OVER) and hides it after an ordinary shift; while the card is up it
# follows GameState.run_stats_changed (a stat booked on the end screen, a late joiner's first state).
# The fit: the card never runs off the screen and nothing scrolls. When its minimum size is larger than the screen less
# FIT_MARGIN on every side (four workers at PAID IN FULL with cost lines, a job line and THE RUN is about 900 px tall;
# the same card without THE RUN could already pass 720), the card's centring container (Center) is scaled down around
# the screen's centre until the card fits; a card that fits keeps scale 1. While the overlay is up, every frame compares
# the card's minimum size (cached by the engine) and the screen with the last fit and fits again when either moved
# (the engine's minimum_size_changed does not fire for texts set while the overlay was hidden). Juice's pop-in scales
# the card itself, not Center.

## Pixels kept free between the card and every screen edge.
const FIT_MARGIN: float = 16.0
## The card is never drawn smaller than this.
const FIT_MIN_SCALE: float = 0.5

var run_card: RunCard
var _runcard_fit_need: Vector2 = Vector2.ZERO
var _runcard_fit_room: Vector2 = Vector2.ZERO


func _runcard_ready() -> void:
	run_card = RunCard.new()
	(get_node(^"%ReportCard") as Control).add_sibling(run_card)
	GameState.run_stats_changed.connect(_runcard_on_changed)
	visibility_changed.connect(_runcard_on_visibility)
	set_process(visible)


func _runcard_on_changed() -> void:
	if visible:
		run_card.refresh()


func _runcard_on_visibility() -> void:
	set_process(visible)
	if visible:
		_runcard_fit()


func _process(_delta: float) -> void:
	if card.get_combined_minimum_size() != _runcard_fit_need or get_viewport_rect().size != _runcard_fit_room:
		_runcard_fit()


## Scales Center so the card fits the screen (see the region header). The room is the viewport, not Center: a container
## is never smaller than its child, so Center grows past the screen (both ways, staying centred) with a tall card.
func _runcard_fit() -> void:
	var center := card.get_parent() as Control
	if center == null or not is_inside_tree():
		return
	var need := card.get_combined_minimum_size()
	_runcard_fit_need = need
	_runcard_fit_room = get_viewport_rect().size
	var avail := _runcard_fit_room - Vector2(FIT_MARGIN, FIT_MARGIN) * 2.0
	var s := 1.0
	if need.x > 0.0 and need.y > 0.0 and avail.x > 0.0 and avail.y > 0.0:
		s = clampf(minf(avail.x / need.x, avail.y / need.y), FIT_MIN_SCALE, 1.0)
	center.pivot_offset_ratio = Vector2(0.5, 0.5)
	if not is_equal_approx(center.scale.x, s):
		center.scale = Vector2(s, s)


## True while the card shows THE RUN block (tests, capture tools).
func is_showing_run() -> bool:
	return visible and run_card != null and run_card.is_shown()


## The scale the fit gives the card (1 when it fits the screen as it is).
func get_fit_scale() -> float:
	return (card.get_parent() as Control).scale.x
# --- end M25 runcard ---


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	Game.set_ui_lock(LOCK_SOURCE, locked)


# --- M17 finale ---
## True when the end screen is the end of the run: the final notice was paid (GameState.is_run_cleared(), synced).
func _is_cleared() -> bool:
	return GameState.phase == GameState.Phase.ROUND_SUCCESS and GameState.is_run_cleared()


## True while the card reads PAID IN FULL (tests, capture tools).
func is_showing_cleared() -> bool:
	return visible and _is_cleared() and title_label.text == TEXT_CLEARED_TITLE
# --- end M17 finale ---
