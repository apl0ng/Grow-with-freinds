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
	_seed_grid.sort_children.connect(_queue_fit)
	_upgrade_grid.sort_children.connect(_queue_fit)
	get_viewport().size_changed.connect(_queue_fit)
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
	_queue_fit()
	_refresh()
	_set_lock(true)
	set_process(true)
	set_process_input(true)
	Sfx.play(&"ui_open")
	Juice.pop_in(_panel)
	_focus_default.call_deferred()
	_begin_settle()  # M15 lead: the window opens at the top row
	opened.emit()


# --- M12 strains ---
## The scene's scroll area floor (px): one row of cards plus a little of the next.
const SCROLL_MIN_HEIGHT := 340.0
## What the panel needs besides the scroll area (header, tabs, footer, separations, padding), roughly, in px.
const PANEL_CHROME_HEIGHT := 300.0
## Footer hint: the default, and the one shown while part of the seed page is below the fold (M13 visual pass).
const HINT_DEFAULT := "Arrows: select   Enter: buy   Esc / E: close"
const HINT_SCROLL := "More below: wheel or arrows   Enter: buy   Esc / E: close"

var _fit_queued := false

## Re-measures once the containers have sorted (the cards' wrapped labels only know their height after their width is
## set; measured too early they report a few lines each) and whenever the window changes size. Deferred, so a sort
## never re-enters itself; a fit that changes the scroll area queues another sort, and the sequence settles once the
## cards stop changing height.
func _queue_fit() -> void:
	if _fit_queued:
		return
	_fit_queued = true
	_fit_scroll.call_deferred()


## The seed page's content height once its cards were laid out (the tallest page: six cards in two rows). Measured
## only while the SEEDS grid is visible: a hidden grid's cards are never sized, so their wrapped labels report
## nonsense heights. Both tabs use it, so the window keeps one size when switching.
var _rows_height := 0.0

## Six strains = two rows of seed cards. The scroll area grows to show every row when the window is tall enough, so
## the second row is not hidden behind a scroll bar on a normal screen; on a short window it keeps the scene's floor
## and scrolls (follow_focus keeps the keyboard path working).
func _fit_scroll() -> void:
	_fit_queued = false
	if not is_inside_tree():
		return
	if _seed_grid.visible and _seed_grid.get_child_count() > 0:
		var pages := _scroll.get_child(0) as MarginContainer if _scroll.get_child_count() > 0 else null
		var margins := 0.0
		if pages != null:
			margins = float(pages.get_theme_constant(&"margin_top") + pages.get_theme_constant(&"margin_bottom"))
		var rows := ceili(float(_seed_grid.get_child_count()) / float(maxi(_seed_grid.columns, 1)))
		var card_h := 0.0
		for c in _seed_grid.get_children():
			if c is Control and (c as Control).visible:
				card_h = maxf(card_h, (c as Control).get_combined_minimum_size().y)
		var sep := float(_seed_grid.get_theme_constant(&"v_separation"))
		_rows_height = rows * card_h + (rows - 1) * sep + margins
	var room := get_viewport().get_visible_rect().size.y - PANEL_CHROME_HEIGHT
	var height := maxf(SCROLL_MIN_HEIGHT, minf(maxf(_rows_height, SCROLL_MIN_HEIGHT), room))
	if absf(height - _scroll.custom_minimum_size.y) > 0.5:
		_scroll.custom_minimum_size.y = height
	var hint := get_node_or_null(^"Root/Panel/VBox/Footer/Hint") as Label
	if hint != null:
		hint.text = HINT_SCROLL if _rows_height > height + 1.0 else HINT_DEFAULT
	if _settling:
		_settle_scroll.call_deferred()


# --- M15 lead: the window opens at the top row ------------------------------------------------------------------
# The first focus is taken before the cards know their height, and follow_focus scrolls for that layout: the window
# then opened half a row down, with the first row's names cut off. For a moment after opening, every fit puts the
# scroll area back at the top and then only as far down as the focused control needs.

## How long after opening the fits still re-anchor the scroll (seconds): the layout settles in a few frames, and a
## worker who turns the wheel after that keeps the place.
const SETTLE_SEC := 0.3

var _settling := false
var _settle_tween: Tween


func _begin_settle() -> void:
	_settling = true
	if _settle_tween != null and _settle_tween.is_valid():
		_settle_tween.kill()
	if not is_inside_tree():
		return
	_settle_tween = create_tween()
	_settle_tween.tween_interval(SETTLE_SEC)
	_settle_tween.tween_callback(_end_settle)


func _end_settle() -> void:
	_settle_scroll()
	_settling = false


func _settle_scroll() -> void:
	if not _open or not _settling or not is_inside_tree():
		return
	_scroll.scroll_vertical = 0
	var focused := get_viewport().gui_get_focus_owner()
	if focused != null and _scroll.is_ancestor_of(focused):
		_scroll.ensure_control_visible(focused)


## The height the scroll area was given for the current cards (tests).
func get_scroll_height() -> float:
	return _scroll.custom_minimum_size.y
# --- end M12 strains ---


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
	# M12 disrupt: the counter's shortage greys that strain's card (OUT OF STOCK); cards refresh on the UI's own timer.
	var short := counter.get_shortage_strain() if counter != null and is_instance_valid(counter) else &""
	for card: ShopCard in _cards.values():
		card.refresh(money, hands_full, card.kind == ShopCounter.KIND_SEED and short != &"" and card.item_id == short)


func _process(delta: float) -> void:
	if not _open:
		return
	if not _is_valid_node(player) or not _is_valid_node(counter) or not player.is_inside_tree():
		close()
		return
	if player.global_position.distance_to(counter.global_position) > _close_distance:
		close()
		return
	if GameState.is_in_backroom(player.peer_id):
		# M11 review: the BackRoomSpot sits 2 m from the counter, inside the walk-away distance, so the window used to
		# stay open over the back-room overlay (and the server now refuses the purchases anyway).
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
		# The level this card is priced at (cards refresh on every level change): the host refuses the press if
		# the favor moved on before it arrives, instead of selling the next, dearer level.
		counter.request_buy_upgrade(card.item_id, GameState.get_upgrade_level(card.item_id))


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
