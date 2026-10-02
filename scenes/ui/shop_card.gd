class_name ShopCard
extends PanelContainer
## One purchasable entry in the SUPPLY WINDOW: a seed strain or a team upgrade, a "favor" (owner: economy agent).
## Copy is factual and flat: "Grows in ~N s", "Deposits for $X", "Margin +$Y"; blurbs come from Story.get_blurb()
## (falls back to the data description).
## Built from Config.balance data by ShopUI: add it to the tree first, then call setup_seed() / setup_upgrade().
## refresh() re-reads GameState (money, levels, multipliers) and updates texts + the BUY button.

signal buy_pressed(card: ShopCard)

const KIND_SEED: StringName = &"seed"
const KIND_UPGRADE: StringName = &"upgrade"
const PIP_EMPTY := Color(1.0, 1.0, 1.0, 0.12)

var kind: StringName = &""
var item_id: StringName = &""
var seed_def: SeedDef = null
var upgrade_def: UpgradeDef = null
var accent: Color = Color.WHITE

var _pip_boxes: Array[StyleBoxFlat] = []

@onready var _swatch: Panel = %Swatch
@onready var _shine: Panel = %Shine
@onready var _glyph: Label = %Glyph
@onready var _name_label: Label = %NameLabel
@onready var _tag_label: Label = %TagLabel
@onready var _desc_label: Label = %DescLabel
@onready var _stat1: Label = %Stat1
@onready var _stat2: Label = %Stat2
@onready var _stat3: Label = %Stat3
@onready var _pips: HBoxContainer = %Pips
@onready var _buy: Button = %BuyButton


func _ready() -> void:
	var shine := StyleBoxFlat.new()
	shine.bg_color = Color(1.0, 1.0, 1.0, 0.55)
	shine.set_corner_radius_all(8)
	_shine.add_theme_stylebox_override(&"panel", shine)
	_buy.pressed.connect(_on_buy_pressed)


func setup_seed(def: SeedDef) -> void:
	kind = KIND_SEED
	seed_def = def
	upgrade_def = null
	item_id = def.id
	accent = def.color
	name = "Seed_%s" % String(def.id)
	_name_label.text = def.display_name
	_desc_label.text = Story.get_blurb(def.id, def.description)
	_tag_label.text = get_seed_tag(def) # M14 loop: a strain with a trait names it on the tag line ("THIRSTY")
	_glyph.text = ""
	_shine.visible = true
	_swatch.add_theme_stylebox_override(&"panel", _make_swatch_box(def.color, 32))
	_pips.visible = false
	_stat3.visible = true
	refresh(0, false)


func setup_upgrade(def: UpgradeDef) -> void:
	kind = KIND_UPGRADE
	upgrade_def = def
	seed_def = null
	item_id = def.id
	accent = ShopCounter.get_effect_color(def.effect_key)
	name = "Upgrade_%s" % String(def.id)
	_name_label.text = def.display_name
	_desc_label.text = Story.get_blurb(def.id, def.description)
	_glyph.text = def.display_name.substr(0, 1).to_upper()
	_shine.visible = false
	_swatch.add_theme_stylebox_override(&"panel", _make_swatch_box(accent, 16))
	_build_pips(def.max_level)
	_pips.visible = true
	_stat3.visible = false
	refresh(0, false)


## Re-reads the live numbers. `money` = team wallet, `hands_full` = the local player holds something.
## `out_of_stock` (M12 disrupt): the counter's shortage hit this seed; the card reads OUT OF STOCK and cannot buy.
func refresh(money: int, hands_full: bool, out_of_stock: bool = false) -> void:
	if kind == KIND_SEED and seed_def != null:
		_refresh_seed(money, hands_full, out_of_stock)
	elif kind == KIND_UPGRADE and upgrade_def != null:
		_refresh_upgrade(money)


func get_buy_button() -> Button:
	return _buy


# --- M14 loop: the trait on the tag line ---------------------------------------------------------------------------
## The small line under a seed's name. A strain with a trait (SeedDef.trait_text, "Thirsty.") shows it there in the
## tag's own caps, in place of the old words: "THIRSTY", "GROWS IN THE DARK" (beside "SEED PACKET" the longest one
## does not fit a card at its minimum width). The line was already on the card, so the card is no taller for it; a
## strain without a trait reads "SEED PACKET" as before.
const SEED_TAG := "SEED PACKET"

static func get_seed_tag(def: SeedDef) -> String:
	var words := def.trait_text.strip_edges().trim_suffix(".") if def != null else ""
	return SEED_TAG if words == "" else words.to_upper()


## The tag line as shown ("SEED PACKET", "HEAVY", "FAVOR  ·  LEVEL 1 / 3").
func get_tag_text() -> String:
	return _tag_label.text
# --- end M14 loop --------------------------------------------------------------------------------------------------


# --- M15 replay ----------------------------------------------------------------------------------------------------
## The supply card on a day that is not like the others (replay agent, CONTRACTS "M15", "Replay"). Three things, all
## read from GameState's synced state on every refresh, all absent with replay off:
##   the day's numbers   "Deposits for" and "Margin" come from TurnInStation.compute_sale_value, the chute's own
##                       formula (the market x the conditions are in it), so the card and the chute never differ by
##                       a rounded dollar; the BUY price is GameState.get_seed_cost (the conditions' seed_cost)
##   the value mark      a small triangle after the deposit line: up (Toon.SUCCESS) when the strain deposits for more
##                       than its plain value today, down (Toon.ERROR) when for less, none at par. Drawn, not a glyph.
##   the locked state    a strain whose SeedDef.unlock_round is still ahead: the button reads "FROM SHIFT 3" and is
##                       disabled, the card is dimmed. It wins over OUT OF STOCK and HANDS FULL.
const TEXT_LOCKED_BUTTON := "FROM SHIFT %d"
const TEXT_LOCKED := "From shift %d"
const TEXT_LOCKED_TIP := "Not sold before shift %d."
const LOCKED_ALPHA := 0.55
const MARK_SIZE := 12.0
const MARK_GAP := 8.0

var _locked: bool = false
var _value_mark: int = 0
var _mark: Control = null


## True while this seed card's strain is not sold yet.
func is_locked() -> bool:
	return _locked


## "From shift 3" while locked, "" otherwise.
func get_lock_text() -> String:
	return TEXT_LOCKED % GameState.get_unlock_round(item_id) if _locked else ""


## +1 when the strain deposits for more than its plain value today, -1 for less, 0 at par (and on a favor card).
func get_value_mark() -> int:
	return _value_mark


## The mark's node (null until a seed card was refreshed once): visible only while get_value_mark() is not 0.
func get_value_mark_node() -> Control:
	return _mark


func _replay_refresh_seed() -> void:
	_locked = not GameState.is_strain_unlocked(seed_def.id)
	if _locked:
		var from_round := GameState.get_unlock_round(seed_def.id)
		_buy.text = TEXT_LOCKED_BUTTON % from_round
		_buy.tooltip_text = TEXT_LOCKED_TIP % from_round
		_buy.disabled = true
	modulate.a = LOCKED_ALPHA if _locked else 1.0
	var factor := GameState.get_deposit_factor(seed_def.id)
	var mark := 0
	if factor > 1.0005:
		mark = 1
	elif factor < 0.9995:
		mark = -1
	if _mark == null:
		if mark == 0:
			return
		_mark = Control.new()
		_mark.name = "ValueMark"
		_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_mark.size = Vector2(MARK_SIZE, MARK_SIZE)
		_mark.draw.connect(_on_mark_draw)
		_stat2.add_child(_mark)
	_value_mark = mark
	_mark.visible = mark != 0
	var text_size := _stat2.get_minimum_size()
	_mark.position = Vector2(text_size.x + MARK_GAP, maxf((text_size.y - MARK_SIZE) * 0.5, 0.0))
	_mark.queue_redraw()


func _on_mark_draw() -> void:
	if _value_mark == 0:
		return
	var s := MARK_SIZE
	var points := PackedVector2Array([Vector2(0.0, s), Vector2(s, s), Vector2(s * 0.5, 0.0)])
	if _value_mark < 0:
		points = PackedVector2Array([Vector2(0.0, 0.0), Vector2(s, 0.0), Vector2(s * 0.5, s)])
	_mark.draw_colored_polygon(points, Toon.SUCCESS if _value_mark > 0 else Toon.ERROR)
	points.append(points[0])
	_mark.draw_polyline(points, Toon.INK, 2.0, true)
# --- end M15 replay ------------------------------------------------------------------------------------------------


func is_buy_enabled() -> bool:
	return not _buy.disabled


func get_stats_text() -> String:
	var parts := PackedStringArray([_stat1.text, _stat2.text])
	if _stat3.visible:
		parts.append(_stat3.text)
	return "\n".join(parts)


func _refresh_seed(money: int, hands_full: bool, out_of_stock: bool = false) -> void:
	var grow_mult := maxf(GameState.get_growth_speed_multiplier(), 0.01)
	var grow_sec := Config.balance.total_grow_time(seed_def) / grow_mult
	_stat1.text = "Grows in ~%d s" % roundi(grow_sec)
	var sale_mult := GameState.get_sale_multiplier()
	var total := TurnInStation.compute_sale_value(seed_def, seed_def.yield_amount, sale_mult) # M15 replay: the chute's own formula, so the card shows what a deposit pays today (market and conditions included)
	if seed_def.yield_amount > 1:
		var per_unit := TurnInStation.compute_sale_value(seed_def, 1, sale_mult) # M15 replay
		_stat2.text = "Deposits for $%d  (%d × $%d)" % [total, seed_def.yield_amount, per_unit]
	else:
		_stat2.text = "Deposits for $%d" % total
	var cost := GameState.get_seed_cost(seed_def) # M15 replay: today's price
	var profit := total - cost # M15 replay: cost
	_stat3.text = "Margin %s$%d" % ["+" if profit >= 0 else "-", absi(profit)]
	_stat3.theme_type_variation = &"SuccessLabel" if profit >= 0 else &"ErrorLabel"
	var affordable := money >= cost # M15 replay: cost
	if out_of_stock:
		_buy.text = "OUT OF STOCK"
		_buy.tooltip_text = "Out of stock this shift."
	elif hands_full:
		_buy.text = "HANDS FULL"
		_buy.tooltip_text = "Put down what you're carrying first."
	else:
		_buy.text = "BUY  $%d" % cost # M15 replay: cost
		_buy.tooltip_text = "" if affordable else "Not enough cash."
	_buy.disabled = out_of_stock or hands_full or not affordable
	_replay_refresh_seed() # M15 replay: the locked state ("FROM SHIFT 3") and the day's value mark


func _refresh_upgrade(money: int) -> void:
	var level := GameState.get_upgrade_level(upgrade_def.id)
	var maxed := level >= upgrade_def.max_level
	_tag_label.text = "FAVOR  ·  LEVEL %d / %d" % [mini(level, upgrade_def.max_level), upgrade_def.max_level]
	_stat1.text = "Now: %s" % (_effect_text(level) if level > 0 else "nothing")
	_stat2.text = "Maxed out." if maxed else "Next: %s" % _effect_text(level + 1)
	for i in _pip_boxes.size():
		_pip_boxes[i].bg_color = accent if i < level else PIP_EMPTY
	if maxed:
		_buy.text = "MAXED"
		_buy.tooltip_text = ""
		_buy.disabled = true
		return
	var cost := upgrade_def.cost_for_level(level + 1)
	_buy.text = "BUY  $%d" % cost
	_buy.tooltip_text = "" if money >= cost else "Not enough cash."
	_buy.disabled = money < cost


func _effect_text(level: int) -> String:
	var total := upgrade_def.effect_per_level * level
	match String(upgrade_def.effect_key):
		"growth_speed":
			return "+%d%% growth speed" % roundi(total * 100.0)
		"can_capacity":
			return "+%d can charges" % roundi(total)
		"sale_bonus":
			return "+%d%% deposit value" % roundi(total * 100.0)
		"water_retention":
			return "+%d%% water retention" % roundi(total * 100.0)
	return "+%s" % str(snappedf(total, 0.01))


func _build_pips(count: int) -> void:
	for c in _pips.get_children():
		c.queue_free()
	_pip_boxes.clear()
	for i in count:
		var pip := Panel.new()
		pip.custom_minimum_size = Vector2(22, 22)
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var box := StyleBoxFlat.new()
		box.set_corner_radius_all(11)
		box.bg_color = PIP_EMPTY
		box.border_color = Color(1.0, 1.0, 1.0, 0.75)
		box.set_border_width_all(2)
		pip.add_theme_stylebox_override(&"panel", box)
		_pips.add_child(pip)
		_pip_boxes.append(box)


static func _make_swatch_box(color: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(radius)
	box.border_color = color.darkened(0.35)
	box.set_border_width_all(4)
	box.shadow_color = Color(0.0, 0.0, 0.0, 0.2)
	box.shadow_size = 4
	box.shadow_offset = Vector2(0, 3)
	box.anti_aliasing = true
	return box


func _on_buy_pressed() -> void:
	buy_pressed.emit(self)

