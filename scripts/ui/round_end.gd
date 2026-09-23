class_name RoundEndOverlay
extends Control
## Full-screen end-of-shift overlay (scenes/ui/round_end.tscn, instanced by the HUD as %RoundEnd).
## Visible while GameState.phase is ROUND_SUCCESS or ROUND_FAILED (so late joiners see it too) and
## holds Game.set_ui_lock(&"round_end") while visible (player input off, mouse free).
##   Paid   - host: NEXT SHIFT + MAIN MENU            clients: "Waiting for the Boss's decision…" + LEAVE
##   Missed - host: START OVER (full reset) + MAIN MENU   clients: "Waiting for the Boss's decision…" + LEAVE
## Grim relief, never victory (STYLE.md "Mood & tone"): off-white title, no gold banner, no "!".

const LOCK_SOURCE: StringName = &"round_end"

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

var _locked: bool = false
var _shown_phase: int = -1

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


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	GameState.phase_changed.connect(_on_phase_changed)
	GameState.round_ended.connect(_on_round_ended)
	GameState.money_changed.connect(_on_money_changed)
	GameState.sales_changed.connect(_on_sales_changed)
	Net.players_changed.connect(_on_players_changed) # the next payment scales with the team
	primary_button.pressed.connect(_on_primary_pressed)
	menu_button.pressed.connect(_on_menu_pressed)
	_sync_to_phase(GameState.phase)


func _exit_tree() -> void:
	_set_locked(false)


## True while the overlay is up (ROUND_SUCCESS / ROUND_FAILED).
func is_open() -> bool:
	return visible


func _on_phase_changed(new_phase: int) -> void:
	_sync_to_phase(new_phase)


func _sync_to_phase(new_phase: int) -> void:
	var over := new_phase == GameState.Phase.ROUND_SUCCESS or new_phase == GameState.Phase.ROUND_FAILED
	if not over:
		_shown_phase = -1
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
		if primary_button.visible and is_inside_tree():
			primary_button.grab_focus.call_deferred()


func _on_round_ended(success: bool, _round_number: int) -> void:
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


## Rebuilds every text/button from GameState (public so tests / the HUD can force it).
func refresh() -> void:
	var success := GameState.phase == GameState.Phase.ROUND_SUCCESS
	var host := GameState.is_local_host()
	var round_number := GameState.round_number

	title_label.theme_type_variation = &"TitleLabel"
	if success:
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
	if success:
		next_key.text = TEXT_NEXT_KEY
		next_value.text = HUD.format_money(GameState.get_quota_for(round_number + 1))
	else:
		next_key.text = TEXT_PAID_KEY
		next_value.text = str(maxi(round_number - 1, 0))

	primary_button.visible = host
	primary_button.text = TEXT_NEXT_SHIFT if success else TEXT_START_OVER
	primary_button.theme_type_variation = &"BigButton" if success else &"GoldButton"
	waiting_label.visible = not host
	waiting_label.text = TEXT_WAITING
	menu_button.text = TEXT_MAIN_MENU if host else TEXT_LEAVE


func _on_primary_pressed() -> void:
	Sfx.play(&"ui_click")
	if GameState.phase == GameState.Phase.ROUND_SUCCESS:
		GameState.request_next_round()
	elif GameState.phase == GameState.Phase.ROUND_FAILED:
		GameState.request_retry()


func _on_menu_pressed() -> void:
	Sfx.play(&"ui_click")
	Game.return_to_menu()


func _set_locked(locked: bool) -> void:
	if locked == _locked:
		return
	_locked = locked
	Game.set_ui_lock(LOCK_SOURCE, locked)
