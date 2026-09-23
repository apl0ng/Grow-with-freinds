class_name ShopUI
extends CanvasLayer
## The Boss's SUPPLY WINDOW (owner: economy agent; copy: narrative pass). One instance per ShopCounter, created
## lazily the first time the local player opens it and parented to the viewport root (freed with the counter).
##
## Tabs: SEEDS (one card per Config.balance.seeds) and FAVORS (the team upgrades, one card per
## Config.balance.upgrades: the Boss's "favors", which go on the tab). The subtitle follows the tab.
## Header shows the cash on hand (GameState.money). BUY presses are forwarded to the counter, which sends the
## server-validated RPCs; this UI never mutates game state itself and only shows the result.
##
## While open it holds Game.set_ui_lock(&"shop", true) (player input off, mouse free).
## Closes on: Close button, Esc (ui_cancel / pause), E (interact key), walking away from the counter, round end,
## the local player disappearing, and the counter leaving the tree.
## Keyboard: arrows move between buttons, Enter/Space buys, Tab switches tab, Esc/E closes.
## Layout note: %Panel is centred with centre anchors + grow both (not a CenterContainer) because Containers reset
## their children's scale whenever they re-sort, which would make Juice.pop_in flash at full size for a frame.

signal opened
signal closed

const CARD_SCENE: PackedScene = preload("res://scenes/ui/shop_card.tscn")
const TAB_SEEDS := 0
const TAB_UPGRADES := 1
## A BUY press is ignored while an earlier request is still unanswered (no accidental double purchases).
const PENDING_TIMEOUT_MSEC := 1000
## Live values (hands full, multipliers) are re-read this often while open; money/levels also update by signal.
const REFRESH_INTERVAL_SEC := 0.25
## The E key closes the shop only after this long, so the press that opened it can never close it again.
const E_CLOSE_GRACE_MSEC := 250
## Extra metres allowed beyond the opening distance before the walk-away check closes the window.
const WALK_AWAY_SLACK := 0.75
const TEXT_SUB_SEEDS := "Everything goes on your tab."
const TEXT_SUB_FAVORS := "Favors. The Boss adds them to your tab."

var counter: ShopCounter = null
var player: Player = null

var _open := false
var _tab := TAB_SEEDS
var _opened_at_msec := 0
var _close_distance := 4.0
var _pending_until_msec := 0
var _refresh_left := 0.0
var _last_money := 0
var _lock_held := false
var _cards: Dictionary = {}   # "seed:<id>" / "upgrade:<id>" -> ShopCard

@onready var _panel: Control = %Panel
@onready var _money_label: Label = %MoneyLabel
@onready var _subtitle: Label = %Subtitle
@onready var _close_button: Button = %CloseButton
@onready var _seeds_tab: Button = %SeedsTab
@onready var _upgrades_tab: Button = %UpgradesTab
@onready var _scroll: ScrollContainer = %Scroll
@onready var _seed_grid: GridContainer = %SeedGrid
@onready var _upgrade_grid: GridContainer = %UpgradeGrid
@onready var _feedback: Label = %Feedback


func _ready() -> void:
	visible = false
	set_process(false)
	set_process_input(false)
	_build_cards()
	_close_button.pressed.connect(close)
	_seeds_tab.pressed.connect(show_tab.bind(TAB_SEEDS))
	_upgrades_tab.pressed.connect(show_tab.bind(TAB_UPGRADES))
	GameState.money_changed.connect(_on_money_changed)
	GameState.upgrade_level_changed.connect(_on_upgrade_level_changed)
	GameState.round_ended.connect(_on_round_ended)
	_last_money = GameState.money
	_update_money_label(GameState.money)
	show_tab(TAB_SEEDS, false)


func _exit_tree() -> void:
	# Never leave the player input-locked if the window disappears while open (e.g. back to the menu).
	if _lock_held:
		Game.set_ui_lock(ShopCounter.UI_LOCK_SOURCE, false)
		_lock_held = false
	_open = false


# --- Public API -----------------------------------------------------------------------------------------------------

## Shows the window for the local player `p_player` at `p_counter`. Calling it while open just refreshes.
func open(p_counter: ShopCounter, p_player: Player) -> void:
	counter = p_counter
	player = p_player
	_close_distance = _compute_close_distance()
	if _open:
		_refresh()
		return
	_open = true
	visible = true
	_opened_at_msec = Time.get_ticks_msec()
	_pending_until_msec = 0
	_refresh_left = REFRESH_INTERVAL_SEC
	_set_feedback("", true)
	_last_money = GameState.money
	_update_money_label(GameState.money)
	show_tab(_tab, false)
	_refresh()
	_set_lock(true)
	set_process(true)
	set_process_input(true)
	Sfx.play(&"ui_open")
	Juice.pop_in(_panel)
	_focus_default.call_deferred()
	opened.emit()


## Hides the window and releases the UI lock. `play_sound` = false for silent teardown.
func close(play_sound: bool = true) -> void:
	if not _open:
		return
	_open = false
	visible = false
	set_process(false)
	set_process_input(false)
	_pending_until_msec = 0
	_set_lock(false)
	if play_sound:
		Sfx.play(&"ui_close")
	closed.emit()


func is_open() -> bool:
	return _open


func get_current_tab() -> int:
	return _tab


## Switches between TAB_SEEDS and TAB_UPGRADES.
func show_tab(index: int, play_sound: bool = true) -> void:
	_tab = clampi(index, TAB_SEEDS, TAB_UPGRADES)
	_seed_grid.visible = _tab == TAB_SEEDS
	_upgrade_grid.visible = _tab == TAB_UPGRADES
	_style_tab(_seeds_tab, _tab == TAB_SEEDS)
	_style_tab(_upgrades_tab, _tab == TAB_UPGRADES)
	_subtitle.text = TEXT_SUB_SEEDS if _tab == TAB_SEEDS else TEXT_SUB_FAVORS
	_scroll.scroll_vertical = 0
	if play_sound:
		Sfx.play(&"ui_click")
	if _open:
		var focused := get_viewport().gui_get_focus_owner()
		if focused == null or not focused.is_visible_in_tree():
			_focus_default()


## The card for `kind` (&"seed" / &"upgrade") and id, or null.
func get_card(kind: StringName, id: StringName) -> ShopCard:
	return _cards.get(_card_key(kind, id)) as ShopCard


func get_cards(kind: StringName) -> Array[ShopCard]:
	var out: Array[ShopCard] = []
	for card: ShopCard in _cards.values():
		if card.kind == kind:
			out.append(card)
	return out


func get_money_text() -> String:
	return _money_label.text


func get_feedback_text() -> String:
	return _feedback.text


## Called by the counter when the server answered one of our purchase requests.
func on_purchase_result(ok: bool, message: String, kind: StringName, what_id: StringName) -> void:
	_pending_until_msec = 0
	_set_feedback(message, ok)
	var card := get_card(kind, what_id)
	if ok and card != null and _open:
		Juice.punch_ui(card)
	_refresh()


# --- Internals ------------------------------------------------------------------------------------------------------

func _build_cards() -> void:
	for seed_def: SeedDef in Config.balance.seeds:
		if seed_def == null:
			continue
		var card := CARD_SCENE.instantiate() as ShopCard
		_seed_grid.add_child(card)
		card.setup_seed(seed_def)
		card.buy_pressed.connect(_on_card_buy_pressed)
		_cards[_card_key(ShopCounter.KIND_SEED, seed_def.id)] = card
	for up_def: UpgradeDef in Config.balance.upgrades:
		if up_def == null:
			continue
		var card := CARD_SCENE.instantiate() as ShopCard
		_upgrade_grid.add_child(card)
		card.setup_upgrade(up_def)
		card.buy_pressed.connect(_on_card_buy_pressed)
		_cards[_card_key(ShopCounter.KIND_UPGRADE, up_def.id)] = card


static func _card_key(kind: StringName, id: StringName) -> String:
	return "%s:%s" % [kind, id]


func _refresh() -> void:
	var money := GameState.money
	var hands_full := _local_hands_full()
	for card: ShopCard in _cards.values():
		card.refresh(money, hands_full)


func _process(delta: float) -> void:
	if not _open:
		return
	if not _is_valid_node(player) or not _is_valid_node(counter) or not player.is_inside_tree():
		close()
		return
	if player.global_position.distance_to(counter.global_position) > _close_distance:
		close()
		return
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = REFRESH_INTERVAL_SEC
		_refresh()


func _input(event: InputEvent) -> void:
	if not _open or event.is_echo():
		return
	if _is_action_pressed(event, &"ui_cancel") or _is_action_pressed(event, &"pause"):
		_consume_input()
		close()
		return
	if event is InputEventKey and _is_action_pressed(event, &"interact") \
			and Time.get_ticks_msec() - _opened_at_msec >= E_CLOSE_GRACE_MSEC:
		_consume_input()
		close()
		return
	if _is_action_pressed(event, &"ui_focus_next") or _is_action_pressed(event, &"ui_focus_prev"):
		_consume_input()
		show_tab(TAB_UPGRADES if _tab == TAB_SEEDS else TAB_SEEDS)


func _consume_input() -> void:
	var vp := get_viewport()
	if vp != null:
		vp.set_input_as_handled()


static func _is_action_pressed(event: InputEvent, action: StringName) -> bool:
	return InputMap.has_action(action) and event.is_action_pressed(action)


func _on_card_buy_pressed(card: ShopCard) -> void:
	if not _open or not _is_valid_node(counter):
		return
	if Time.get_ticks_msec() < _pending_until_msec:
		return
	_pending_until_msec = Time.get_ticks_msec() + PENDING_TIMEOUT_MSEC
	Sfx.play(&"ui_click")
	if card.kind == ShopCounter.KIND_SEED:
		counter.request_buy_seed(card.item_id)
	else:
		counter.request_buy_upgrade(card.item_id)


func _on_money_changed(money: int) -> void:
	_update_money_label(money)
	if _open and money != _last_money:
		Juice.punch_ui(_money_label)
	_last_money = money
	_refresh()


func _on_upgrade_level_changed(upgrade_id: StringName, _level: int) -> void:
	_refresh()
	if _open:
		var card := get_card(ShopCounter.KIND_UPGRADE, upgrade_id)
		if card != null:
			Juice.punch_ui(card)


func _on_round_ended(_success: bool, _round_number: int) -> void:
	# Let the round-end overlay take over the screen (and the UI lock).
	close()


func _update_money_label(money: int) -> void:
	_money_label.text = "$%d" % money


func _set_feedback(text: String, ok: bool) -> void:
	_feedback.text = text
	_feedback.theme_type_variation = &"SuccessLabel" if ok else &"ErrorLabel"


## Active tab = green BigButton, inactive = plain (blue) Button, so the selected page is obvious at a glance.
static func _style_tab(button: Button, active: bool) -> void:
	button.set_pressed_no_signal(active)
	button.theme_type_variation = &"BigButton" if active else &"Button"


func _set_lock(locked: bool) -> void:
	if locked == _lock_held:
		return
	_lock_held = locked
	Game.set_ui_lock(ShopCounter.UI_LOCK_SOURCE, locked)


func _local_hands_full() -> bool:
	if not _is_valid_node(player):
		return false
	return player.get_held_item() != null


## Walk-away distance: at least counter.ui_close_distance, a bit more than the distance the shop was opened from,
## but always inside the server's purchase range so an open window never offers purchases that would be refused.
func _compute_close_distance() -> float:
	if not _is_valid_node(counter) or not _is_valid_node(player) or not player.is_inside_tree():
		return 4.0
	var opened_from := player.global_position.distance_to(counter.global_position)
	var d := maxf(counter.ui_close_distance, opened_from + WALK_AWAY_SLACK)
	return maxf(minf(d, counter.get_server_range() - 0.1), 1.0)


func _focus_default() -> void:
	if not _open:
		return
	var grid: GridContainer = _seed_grid if _tab == TAB_SEEDS else _upgrade_grid
	for child in grid.get_children():
		var card := child as ShopCard
		if card != null and card.is_buy_enabled():
			card.get_buy_button().grab_focus()
			return
	(_seeds_tab if _tab == TAB_SEEDS else _upgrades_tab).grab_focus()


## Untyped on purpose: passing a freed instance to a typed Node parameter is itself a runtime error.
static func _is_valid_node(node: Variant) -> bool:
	return is_instance_valid(node)
